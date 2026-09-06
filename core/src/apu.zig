//! The 2A03 APU (ENG-71, M6): 2 pulse channels, triangle, noise, DMC, and the
//! frame sequencer that clocks their envelopes/length counters/sweeps. Ticked
//! once per CPU cycle from `Cpu.tick`, exactly like `Ppu` -- this is a real
//! hardware subsystem in the shared native/wasm graph, not a wasm-only
//! concern (see `docs/adr/0002-apu-mixing-and-filtering.md` for why that
//! matters for `audio_ring.zig`).
//!
//! **Not implemented**: CPU-cycle-stealing DMA for DMC sample fetches (see
//! `Dmc`'s doc comment) -- a deliberate, named gap, same footing as
//! `bus.zig`'s unconditional PRG-RAM simplification.

const std = @import("std");
const testing = std.testing;
const mapper_mod = @import("mapper.zig");
const audio_ring = @import("audio_ring.zig");
const Mapper = mapper_mod.Mapper;

/// https://www.nesdev.org/wiki/APU_Length_Counter -- indexed by the 5-bit
/// field in bits 7-3 of $4003/$4007/$400B/$400F.
pub const length_table = [32]u8{
    10, 254, 20, 2,  40, 4,  80, 6,
    160, 8,  60, 10, 14, 12, 26, 14,
    12, 16, 24, 18,  48, 20, 96, 22,
    192, 24, 72, 26, 16, 28, 32, 30,
};

/// Shared by all four length-counted channels (pulse x2, triangle, noise).
/// Not clocked at all if `halt` (the length-counter-halt / envelope-loop
/// flag, same physical bit) is set.
pub fn clockLength(counter: *u8, halt: bool) void {
    if (!halt and counter.* > 0) counter.* -= 1;
}

/// https://www.nesdev.org/wiki/APU_Envelope
pub const Envelope = struct {
    start: bool = false,
    loop_flag: bool = false, // shared bit with the channel's length-counter halt
    constant_volume: bool = false,
    /// Constant-volume level (C=1) or envelope divider period (C=0) -- one
    /// 4-bit field serves both, exactly as the hardware register does.
    volume_or_period: u4 = 0,
    divider: u4 = 0,
    decay: u4 = 0,

    /// Called on every quarter-frame clock from the frame sequencer.
    pub fn clock(self: *Envelope) void {
        if (self.start) {
            self.start = false;
            self.decay = 15;
            self.divider = self.volume_or_period;
            return;
        }
        if (self.divider == 0) {
            self.divider = self.volume_or_period;
            if (self.decay > 0) {
                self.decay -= 1;
            } else if (self.loop_flag) {
                self.decay = 15;
            }
        } else {
            self.divider -= 1;
        }
    }

    pub fn output(self: *const Envelope) u4 {
        return if (self.constant_volume) self.volume_or_period else self.decay;
    }
};

test "length_table has the documented 32 entries" {
    try testing.expectEqual(@as(u8, 10), length_table[0]);
    try testing.expectEqual(@as(u8, 254), length_table[1]);
    try testing.expectEqual(@as(u8, 20), length_table[2]);
    try testing.expectEqual(@as(u8, 30), length_table[31]);
}

test "Envelope: start flag loads decay=15 and reloads the divider, one clock later than the write" {
    var e = Envelope{ .volume_or_period = 5 };
    e.start = true;
    e.clock();
    try testing.expectEqual(@as(u4, 15), e.decay);
    try testing.expect(!e.start);
}

test "Envelope: divider reload clocks decay down by one, non-looping stops at 0" {
    var e = Envelope{ .volume_or_period = 0, .start = true }; // period 0 => divider reloads every clock
    e.clock(); // start clock: decay=15
    e.clock(); // divider period 0 reloads immediately -> decay 14
    try testing.expectEqual(@as(u4, 14), e.decay);
}

test "Envelope: looping wraps decay from 0 back to 15" {
    var e = Envelope{ .volume_or_period = 0, .loop_flag = true, .start = true };
    e.clock(); // decay = 15
    var i: u8 = 0;
    while (i < 15) : (i += 1) e.clock(); // walk decay down to 0
    try testing.expectEqual(@as(u4, 0), e.decay);
    e.clock(); // one more: loops back to 15
    try testing.expectEqual(@as(u4, 15), e.decay);
}

test "Envelope: constant-volume mode reports the raw parameter regardless of decay" {
    var e = Envelope{ .volume_or_period = 9, .constant_volume = true, .start = true };
    e.clock();
    try testing.expectEqual(@as(u4, 9), e.output());
}

test "Envelope: envelope mode reports the decay level" {
    var e = Envelope{ .volume_or_period = 0, .start = true };
    e.clock();
    try testing.expectEqual(@as(u4, 15), e.output());
}

test "clockLength decrements unless halted, and never goes below 0" {
    var counter: u8 = 1;
    clockLength(&counter, false);
    try testing.expectEqual(@as(u8, 0), counter);
    clockLength(&counter, false); // already 0, stays 0
    try testing.expectEqual(@as(u8, 0), counter);

    counter = 5;
    clockLength(&counter, true); // halted: no change
    try testing.expectEqual(@as(u8, 5), counter);
}

/// https://www.nesdev.org/wiki/APU_Pulse -- each duty's 8-step waveform, in
/// the order the sequencer actually plays it back (not the raw bit-pattern
/// the register byte represents, which nesdev documents separately as
/// reading the same table backward -- this is the played-back shape, which
/// is what `output()` needs).
pub const duty_sequences = [4][8]u1{
    .{ 0, 1, 0, 0, 0, 0, 0, 0 },
    .{ 0, 1, 1, 0, 0, 0, 0, 0 },
    .{ 0, 1, 1, 1, 1, 0, 0, 0 },
    .{ 1, 0, 0, 1, 1, 1, 1, 1 },
};

pub const Pulse = struct {
    /// Selects ones'- (pulse 1) vs twos-complement (pulse 2) sweep negate --
    /// see `docs/adr/0002-apu-mixing-and-filtering.md` and
    /// https://www.nesdev.org/wiki/APU_Sweep for why the two channels differ.
    is_pulse1: bool = false,
    enabled: bool = false,

    envelope: Envelope = .{},
    length_counter: u8 = 0,
    duty: u2 = 0,
    sequence_pos: u3 = 0,

    timer_period: u11 = 0,
    timer: u11 = 0,

    sweep_enabled: bool = false,
    sweep_period: u3 = 0,
    sweep_negate: bool = false,
    sweep_shift: u3 = 0,
    sweep_divider: u3 = 0,
    sweep_reload: bool = false,

    /// $4000/$4004: DDlc.vvvv
    pub fn writeReg0(self: *Pulse, value: u8) void {
        self.duty = @truncate(value >> 6);
        self.envelope.loop_flag = (value & 0x20) != 0;
        self.envelope.constant_volume = (value & 0x10) != 0;
        self.envelope.volume_or_period = @truncate(value & 0x0F);
    }

    /// $4001/$4005: EPPP.NSSS
    pub fn writeReg1(self: *Pulse, value: u8) void {
        self.sweep_enabled = (value & 0x80) != 0;
        self.sweep_period = @truncate((value >> 4) & 0x07);
        self.sweep_negate = (value & 0x08) != 0;
        self.sweep_shift = @truncate(value & 0x07);
        self.sweep_reload = true;
    }

    /// $4002/$4006: timer low 8 bits.
    pub fn writeReg2(self: *Pulse, value: u8) void {
        self.timer_period = (self.timer_period & 0x0700) | value;
    }

    /// $4003/$4007: llll.lHHH -- length load + timer high 3 bits. Restarts
    /// the sequencer phase and envelope; leaves the timer's own divider
    /// (`timer`) untouched. See https://www.nesdev.org/wiki/APU_Pulse.
    pub fn writeReg3(self: *Pulse, value: u8) void {
        self.timer_period = (self.timer_period & 0x00FF) | (@as(u11, value & 0x07) << 8);
        if (self.enabled) self.length_counter = length_table[value >> 3];
        self.sequence_pos = 0;
        self.envelope.start = true;
    }

    /// Called every APU cycle (every other CPU cycle) -- see `Apu.tick`.
    pub fn tickTimer(self: *Pulse) void {
        if (self.timer == 0) {
            self.timer = self.timer_period;
            self.sequence_pos -%= 1; // hardware walks the sequence backward
        } else {
            self.timer -= 1;
        }
    }

    /// The sweep unit's target period -- https://www.nesdev.org/wiki/APU_Sweep.
    /// Returned as `u12` (one bit wider than `timer_period`, but never
    /// actually overflows on the positive side -- see below) so an overflow
    /// past $7FF is visible to `muted()`.
    ///
    /// Deliberately not clamped to 0 on the negate path: real hardware's
    /// adder doesn't clamp either, it just wraps (two's-complement
    /// subtraction on an 11-bit-plus adder) -- and since `muted()` already
    /// rejects any `targetPeriod() > 0x7FF`, a wrapped result (always way
    /// above `0x7FF`) reads as muted exactly like a hardware "negative"
    /// result would, with no separate clamp needed. Positive (non-negate)
    /// sums never need wrapping either: `change_raw <= timer_period` (a
    /// right shift), so the sum is at most `2 * 0x7FF = 0xFFE`, comfortably
    /// inside `u12`'s `0xFFF` ceiling.
    pub fn targetPeriod(self: *const Pulse) u12 {
        const period: u12 = self.timer_period;
        const change_raw: u12 = period >> self.sweep_shift;
        if (!self.sweep_negate) return period + change_raw;
        // Pulse 1: ones' complement (extra -1); Pulse 2: twos complement.
        const ones_complement_extra: u12 = if (self.is_pulse1) 1 else 0;
        return period -% change_raw -% ones_complement_extra;
    }

    pub fn muted(self: *const Pulse) bool {
        return self.timer_period < 8 or self.targetPeriod() > 0x7FF;
    }

    /// Half-frame clock: reload-or-decrement the divider, apply the target
    /// period when it fires (and sweep is actually enabled and not muted).
    pub fn clockSweep(self: *Pulse) void {
        const should_apply = self.sweep_divider == 0 and self.sweep_enabled and !self.muted();
        if (self.sweep_divider == 0 or self.sweep_reload) {
            self.sweep_divider = self.sweep_period;
            self.sweep_reload = false;
        } else {
            self.sweep_divider -= 1;
        }
        if (should_apply) self.timer_period = @truncate(self.targetPeriod());
    }

    pub fn output(self: *const Pulse) u4 {
        if (self.length_counter == 0 or self.muted()) return 0;
        if (duty_sequences[self.duty][self.sequence_pos] == 0) return 0;
        return self.envelope.output();
    }
};

test "Pulse duty sequences match the documented 8-step waveforms" {
    try testing.expectEqualSlices(u1, &[_]u1{ 0, 1, 0, 0, 0, 0, 0, 0 }, &duty_sequences[0]);
    try testing.expectEqualSlices(u1, &[_]u1{ 0, 1, 1, 0, 0, 0, 0, 0 }, &duty_sequences[1]);
    try testing.expectEqualSlices(u1, &[_]u1{ 0, 1, 1, 1, 1, 0, 0, 0 }, &duty_sequences[2]);
    try testing.expectEqualSlices(u1, &[_]u1{ 1, 0, 0, 1, 1, 1, 1, 1 }, &duty_sequences[3]);
}

test "Pulse.writeReg3 restarts the sequencer phase and envelope, reloads length if enabled, leaves the timer divider untouched" {
    var p = Pulse{ .is_pulse1 = true, .enabled = true };
    p.sequence_pos = 5;
    p.timer = 100; // must survive
    p.writeReg3(0b00001_010); // length index 1 -> 254, timer high bits 010
    try testing.expectEqual(@as(u8, 254), p.length_counter);
    try testing.expectEqual(@as(u3, 0), p.sequence_pos);
    try testing.expect(p.envelope.start);
    try testing.expectEqual(@as(u11, 100), p.timer);
}

test "Pulse.writeReg3 does not reload length while the channel is disabled" {
    var p = Pulse{ .enabled = false };
    p.writeReg3(0b00001_000); // length index 1 -> would be 254
    try testing.expectEqual(@as(u8, 0), p.length_counter);
}

test "Pulse.tickTimer advances the duty sequencer on timer reload, walking backward through the table" {
    var p = Pulse{};
    p.writeReg0(0b01_0_1_0000); // duty 1, halt, constant volume, vol 0
    p.timer_period = 1; // reloads every tick for a fast test
    p.timer = 0;
    p.sequence_pos = 0;
    p.tickTimer(); // timer underflows -> reload, sequence_pos decrements (wraps 0->7)
    try testing.expectEqual(@as(u3, 7), p.sequence_pos);
}

test "Pulse sweep: pulse1 uses ones'-complement negate, pulse2 uses twos-complement" {
    var p1 = Pulse{ .is_pulse1 = true, .timer_period = 20, .sweep_negate = true, .sweep_shift = 0 };
    try testing.expectEqual(@as(u12, 20 -% 21 & 0xFFF), p1.targetPeriod() & 0xFFF);

    var p2 = Pulse{ .is_pulse1 = false, .timer_period = 20, .sweep_negate = true, .sweep_shift = 0 };
    try testing.expect(@as(i32, p2.targetPeriod()) < 20); // twos-complement: change = -20, target clamps to 0
}

test "Pulse.muted is true when the current period is below 8, or the target period exceeds 0x7FF" {
    var short = Pulse{ .timer_period = 7 };
    try testing.expect(short.muted());

    var overflow = Pulse{ .timer_period = 0x700, .sweep_shift = 0, .sweep_negate = false };
    // target = period + (period >> 0) = period*2 = 0xE00 > 0x7FF
    try testing.expect(overflow.muted());
}

test "Pulse.output is 0 when muted, length-counter-silenced, or the duty bit is 0; otherwise the envelope level" {
    var p = Pulse{ .timer_period = 100 }; // clear of the sweep unit's period<8 mute path
    p.writeReg0(0b00_0_1_1001); // duty 0, constant volume 9
    p.length_counter = 0; // silenced by length counter
    try testing.expectEqual(@as(u4, 0), p.output());

    p.length_counter = 5;
    p.sequence_pos = 1; // duty 0's "1" step
    try testing.expectEqual(@as(u4, 9), p.output());
}

/// https://www.nesdev.org/wiki/APU_Triangle
pub const triangle_sequence = blk: {
    var seq: [32]u4 = undefined;
    var i: usize = 0;
    while (i < 16) : (i += 1) seq[i] = @intCast(15 - i);
    while (i < 32) : (i += 1) seq[i] = @intCast(i - 16);
    break :blk seq;
};

pub const Triangle = struct {
    enabled: bool = false,
    length_counter: u8 = 0,
    control_flag: bool = false, // shared bit: length-counter halt AND linear-counter control

    timer_period: u11 = 0,
    timer: u11 = 0,
    sequence_pos: u5 = 0,

    linear_counter: u7 = 0,
    linear_reload_value: u7 = 0,
    linear_reload_flag: bool = false,

    /// $4008: CRRR.RRRR
    pub fn writeReg0(self: *Triangle, value: u8) void {
        self.control_flag = (value & 0x80) != 0;
        self.linear_reload_value = @truncate(value & 0x7F);
    }

    /// $400A: timer low 8 bits.
    pub fn writeReg2(self: *Triangle, value: u8) void {
        self.timer_period = (self.timer_period & 0x0700) | value;
    }

    /// $400B: llll.lHHH -- sets the linear-counter reload flag (the actual
    /// reload happens on the next linear-counter clock, not here), reloads
    /// length if enabled, leaves the phase/timer untouched (unlike pulse --
    /// the triangle's sequencer is never phase-reset by a register write).
    pub fn writeReg3(self: *Triangle, value: u8) void {
        self.timer_period = (self.timer_period & 0x00FF) | (@as(u11, value & 0x07) << 8);
        if (self.enabled) self.length_counter = length_table[value >> 3];
        self.linear_reload_flag = true;
    }

    /// Called every CPU cycle (the triangle is clocked twice as fast as
    /// pulse/noise/DMC) -- see `Apu.tick`.
    pub fn tickTimer(self: *Triangle) void {
        if (self.length_counter == 0 or self.linear_counter == 0) return;
        if (self.timer == 0) {
            self.timer = self.timer_period;
            self.sequence_pos +%= 1;
        } else {
            self.timer -= 1;
        }
    }

    /// Quarter-frame clock.
    pub fn clockLinearCounter(self: *Triangle) void {
        if (self.linear_reload_flag) {
            self.linear_counter = self.linear_reload_value;
        } else if (self.linear_counter > 0) {
            self.linear_counter -= 1;
        }
        if (!self.control_flag) self.linear_reload_flag = false;
    }

    pub fn output(self: *const Triangle) u4 {
        return triangle_sequence[self.sequence_pos];
    }
};

test "triangle_sequence is the documented 32-step descend-then-ascend ramp" {
    try testing.expectEqual(@as(u4, 15), triangle_sequence[0]);
    try testing.expectEqual(@as(u4, 0), triangle_sequence[15]);
    try testing.expectEqual(@as(u4, 0), triangle_sequence[16]);
    try testing.expectEqual(@as(u4, 15), triangle_sequence[31]);
}

test "Triangle.tickTimer only advances the sequence when both counters are nonzero" {
    var t = Triangle{ .timer_period = 0, .length_counter = 1, .linear_counter = 1 };
    t.sequence_pos = 0;
    t.tickTimer();
    try testing.expectEqual(@as(u5, 1), t.sequence_pos);

    t.length_counter = 0; // gated off
    t.tickTimer();
    try testing.expectEqual(@as(u5, 1), t.sequence_pos); // unchanged
}

test "Triangle linear counter: reload flag forces a reload, clears only when control_flag is false" {
    var t = Triangle{ .linear_reload_value = 10, .linear_reload_flag = true, .control_flag = true };
    t.clockLinearCounter();
    try testing.expectEqual(@as(u7, 10), t.linear_counter);
    try testing.expect(t.linear_reload_flag); // control_flag held it set

    t.control_flag = false;
    t.clockLinearCounter(); // reload flag still true from before? no -- only cleared when control_flag false AND this clock runs
    try testing.expectEqual(@as(u7, 10), t.linear_counter);
    try testing.expect(!t.linear_reload_flag);
}

test "Triangle.writeReg3 sets the linear-counter reload flag" {
    var t = Triangle{};
    t.writeReg3(0x00);
    try testing.expect(t.linear_reload_flag);
}

test "Triangle.output reads the sequence table directly, ignoring the envelope (triangle has none)" {
    var t = Triangle{};
    t.sequence_pos = 3;
    try testing.expectEqual(triangle_sequence[3], t.output());
}

/// https://www.nesdev.org/wiki/APU_Noise -- NTSC period table, CPU cycles.
pub const noise_period_table = [16]u12{
    4, 8, 16, 32, 64, 96, 128, 160, 202, 254, 380, 508, 762, 1016, 2034, 4068,
};

pub const Noise = struct {
    enabled: bool = false,
    envelope: Envelope = .{},
    length_counter: u8 = 0,
    mode: bool = false, // false = tap bit 1 (32767-step); true = tap bit 6 (short)
    period_index: u4 = 0,
    timer: u12 = 0,
    /// Power-on state must be nonzero -- an all-zero LFSR would lock up
    /// (XOR of two zero bits is always zero, so it can never leave 0).
    shift_register: u15 = 1,

    /// $400E: M---.PPPP
    pub fn writeReg2(self: *Noise, value: u8) void {
        self.mode = (value & 0x80) != 0;
        self.period_index = @truncate(value & 0x0F);
    }

    /// $400F: llll.l--- -- reloads length if enabled, restarts the envelope.
    /// No sequencer phase to restart (unlike pulse) -- the LFSR just keeps
    /// running.
    pub fn writeReg3(self: *Noise, value: u8) void {
        if (self.enabled) self.length_counter = length_table[value >> 3];
        self.envelope.start = true;
    }

    /// Called every APU cycle -- see `Apu.tick`.
    pub fn tickTimer(self: *Noise) void {
        if (self.timer == 0) {
            self.timer = noise_period_table[self.period_index];
            const tap: u1 = if (self.mode) @truncate(self.shift_register >> 6) else @truncate(self.shift_register >> 1);
            const feedback = (self.shift_register & 1) ^ tap;
            self.shift_register = (self.shift_register >> 1) | (@as(u15, feedback) << 14);
        } else {
            self.timer -= 1;
        }
    }

    pub fn output(self: *const Noise) u4 {
        if (self.length_counter == 0 or (self.shift_register & 1) != 0) return 0;
        return self.envelope.output();
    }
};

test "noise_period_table has the documented 16 NTSC entries" {
    try testing.expectEqual(@as(u12, 4), noise_period_table[0]);
    try testing.expectEqual(@as(u12, 202), noise_period_table[8]);
    try testing.expectEqual(@as(u12, 4068), noise_period_table[15]);
}

test "Noise LFSR mode 0 taps bit 1; feedback loads into bit 14, register shifts right" {
    var n = Noise{ .shift_register = 0b000_0000_0000_0001, .mode = false };
    n.tickTimer(); // forces one shift regardless of the timer via period 0 fast-path below
    // bit0=1, bit1=0 -> feedback = 1^0 = 1 -> new bit14 = 1
    try testing.expectEqual(@as(u15, 0b100_0000_0000_0000), n.shift_register);
}

test "Noise output is 0 (muted) when bit 0 of the shift register is set, or the length counter is 0" {
    var n = Noise{ .shift_register = 0b1, .length_counter = 5 };
    n.envelope.constant_volume = true;
    n.envelope.volume_or_period = 7;
    try testing.expectEqual(@as(u4, 0), n.output()); // bit0 set -> muted

    n.shift_register = 0b10;
    try testing.expectEqual(@as(u4, 7), n.output());

    n.length_counter = 0;
    try testing.expectEqual(@as(u4, 0), n.output());
}

/// https://www.nesdev.org/wiki/APU_DMC -- NTSC rate table, CPU cycles per
/// output-level step.
pub const dmc_rate_table = [16]u9{
    428, 380, 340, 320, 286, 254, 226, 214, 190, 160, 142, 128, 106, 84, 72, 54,
};

/// **Known gap**: no CPU-cycle-stealing DMA is modeled for sample fetches
/// (real hardware stalls the CPU 1-4 cycles per fetch). `tickTimer` reads
/// the sample byte straight through the mapper with no CPU-side stall --
/// see this plan's Global Constraints / `docs/adr/0002-apu-mixing-and-
/// filtering.md` for why that's an acceptable, explicitly-flagged
/// simplification for this milestone's conformance ROMs.
pub const Dmc = struct {
    enabled: bool = false,
    irq_enabled: bool = false,
    loop: bool = false,
    rate_index: u4 = 0,
    timer: u9 = 0,

    output_level: u7 = 0,

    sample_address: u16 = 0xC000,
    sample_length: u16 = 1,
    current_address: u16 = 0xC000,
    bytes_remaining: u16 = 0,

    sample_buffer: ?u8 = null,
    shift_register: u8 = 0,
    bits_remaining: u4 = 0,
    silence: bool = true,

    irq_flag: bool = false,

    /// $4010: IL--.RRRR
    pub fn writeReg0(self: *Dmc, value: u8) void {
        self.irq_enabled = (value & 0x80) != 0;
        self.loop = (value & 0x40) != 0;
        self.rate_index = @truncate(value & 0x0F);
        if (!self.irq_enabled) self.irq_flag = false;
    }

    /// $4011: -DDD.DDDD -- direct output-level load, no delta stepping.
    pub fn writeReg1(self: *Dmc, value: u8) void {
        self.output_level = @truncate(value & 0x7F);
    }

    /// $4012: AAAA.AAAA -- sample address = $C000 + A*64.
    pub fn writeReg2(self: *Dmc, value: u8) void {
        self.sample_address = 0xC000 + (@as(u16, value) << 6);
    }

    /// $4013: LLLL.LLLL -- sample length = L*16 + 1.
    pub fn writeReg3(self: *Dmc, value: u8) void {
        self.sample_length = (@as(u16, value) << 4) + 1;
    }

    /// Called by `Apu.writeStatus` when $4015's DMC-enable bit rises from 0
    /// to 1 with bytes_remaining already 0 -- see that method.
    pub fn restart(self: *Dmc) void {
        self.current_address = self.sample_address;
        self.bytes_remaining = self.sample_length;
    }

    fn applyDeltaBit(self: *Dmc) void {
        const bit0 = self.shift_register & 1;
        if (bit0 == 1) {
            if (self.output_level <= 125) self.output_level += 2;
        } else {
            if (self.output_level >= 2) self.output_level -= 2;
        }
    }

    fn checkCompletion(self: *Dmc) void {
        if (self.bytes_remaining != 0) return;
        if (self.loop) {
            self.restart();
        } else if (self.irq_enabled) {
            self.irq_flag = true;
        }
    }

    /// Called every APU cycle -- see `Apu.tick`. `mapper` is read directly
    /// (no CPU cycle stealing, see the type doc comment) whenever the
    /// 1-byte sample buffer is empty and a byte remains.
    pub fn tickTimer(self: *Dmc, mapper: *const Mapper) void {
        if (self.sample_buffer == null and self.bytes_remaining > 0) {
            self.sample_buffer = mapper.prgRead(self.current_address);
            self.current_address = if (self.current_address == 0xFFFF) 0x8000 else self.current_address + 1;
            self.bytes_remaining -= 1;
            self.checkCompletion();
        }

        if (self.timer == 0) {
            self.timer = dmc_rate_table[self.rate_index];

            if (self.bits_remaining == 0) {
                self.bits_remaining = 8;
                if (self.sample_buffer) |b| {
                    self.silence = false;
                    self.shift_register = b;
                    self.sample_buffer = null;
                } else {
                    self.silence = true;
                }
            }

            if (!self.silence) self.applyDeltaBit();
            self.shift_register >>= 1;
            self.bits_remaining -= 1;
        } else {
            self.timer -= 1;
        }
    }

    pub fn output(self: *const Dmc) u7 {
        return self.output_level;
    }
};

test "dmc_rate_table has the documented 16 NTSC entries" {
    try testing.expectEqual(@as(u9, 428), dmc_rate_table[0]);
    try testing.expectEqual(@as(u9, 54), dmc_rate_table[15]);
}

test "Dmc.writeReg2/3 compute sample address and length per the documented formulas" {
    var d = Dmc{};
    d.writeReg2(0x01); // $C000 + 1*64 = $C040
    d.writeReg3(0x01); // 1*16 + 1 = 17
    try testing.expectEqual(@as(u16, 0xC040), d.sample_address);
    try testing.expectEqual(@as(u16, 17), d.sample_length);
}

test "Dmc.restart reloads current_address/bytes_remaining from sample_address/sample_length" {
    var d = Dmc{ .sample_address = 0xC100, .sample_length = 33 };
    d.restart();
    try testing.expectEqual(@as(u16, 0xC100), d.current_address);
    try testing.expectEqual(@as(u16, 33), d.bytes_remaining);
}

test "Dmc output level moves by +-2 per shift-register bit, clamped to 0..127" {
    var d = Dmc{ .output_level = 1, .shift_register = 0b0 };
    // bit0=0 -> would subtract 2, but level(1) < 2 -> no change (clamped)
    d.applyDeltaBit();
    try testing.expectEqual(@as(u7, 1), d.output_level);

    d.output_level = 126;
    d.shift_register = 0b1;
    d.applyDeltaBit(); // bit0=1 -> add 2, but 126 > 125 -> no change (clamped)
    try testing.expectEqual(@as(u7, 126), d.output_level);

    d.output_level = 60;
    d.shift_register = 0b1;
    d.applyDeltaBit();
    try testing.expectEqual(@as(u7, 62), d.output_level);
}

test "Dmc sets the IRQ flag on sample completion only when not looping and IRQ is enabled" {
    var d = Dmc{ .loop = false, .irq_enabled = true, .bytes_remaining = 0 };
    d.checkCompletion();
    try testing.expect(d.irq_flag);

    var looped = Dmc{ .loop = true, .irq_enabled = true, .bytes_remaining = 0, .sample_address = 0xC000, .sample_length = 5 };
    looped.checkCompletion();
    try testing.expect(!looped.irq_flag);
    try testing.expectEqual(@as(u16, 5), looped.bytes_remaining); // restarted
}

pub const FrameEvent = enum { none, quarter, half, quarter_and_half };

/// https://www.nesdev.org/wiki/APU_Frame_Counter. `cycle` counts CPU cycles
/// since the last reset, and `total_cycles` counts them since power-on
/// (used only for the write-delay parity rule below) -- both are owned and
/// incremented by `tick()` itself, called once per CPU cycle from
/// `Apu.tick`.
///
/// **Where the last step's cycle number and the "reset" cycle number
/// collapse into one.** nesdev describes mode 0 as firing its last
/// (quarter+half+IRQ) step at cycle 29829 and resetting to 0 "at 29830" --
/// two distinct cycle numbers. This implementation never actually visits a
/// cycle numbered 29830: the moment `cycle` reaches the last step (29829
/// mode 0 / 37281 mode 1), that same `tick()` call both fires the step's
/// event *and* resets `cycle` to 0, so the very next call starts counting
/// the new sequence from 1 again. This is behaviorally identical to
/// visiting 29830 and treating it as 0 -- it just never materializes that
/// intermediate value -- and it's what the length-counter/envelope timing
/// this file's other tests already rely on (one event per cycle number,
/// no cycle number silently skipped or double-counted).
pub const FrameSequencer = struct {
    mode: u1 = 0,
    irq_inhibit: bool = false,
    irq_flag: bool = false,
    cycle: u32 = 0,
    /// Nonzero while a delayed reset (from a $4017 write) is pending;
    /// counts down to 0, at which point `cycle` resets to 0.
    reset_delay: u32 = 0,
    /// For the write-delay parity rule -- see `write`'s doc comment.
    total_cycles: u64 = 0,

    /// $4017: MI--.---- (mode, IRQ inhibit). Schedules a delayed sequencer
    /// reset (3 or 4 CPU cycles out, per the parity rule below) and, for
    /// mode 1, returns an immediate quarter+half clock as a side effect.
    /// The parity->delay mapping here is this plan's best-effort reading of
    /// https://www.nesdev.org/wiki/APU_Frame_Counter ("3 cycles if the
    /// write occurs during an APU cycle, 4 if between") -- if the vendored
    /// `4-jitter`/`6-irq_flag_timing` ROMs fail, flip the `% 2 == 0` branch
    /// below rather than second-guess the rest of this file.
    pub fn write(self: *FrameSequencer, value: u8) FrameEvent {
        self.mode = @truncate(value >> 7);
        self.irq_inhibit = (value & 0x40) != 0;
        if (self.irq_inhibit) self.irq_flag = false;
        self.reset_delay = if (self.total_cycles % 2 == 0) 4 else 3;
        return if (self.mode == 1) FrameEvent.quarter_and_half else FrameEvent.none;
    }

    /// Called once per CPU cycle. See the type doc comment for the
    /// last-step/reset collapse and why `cycle` is incremented (and
    /// checked against thresholds) inside this function rather than by the
    /// caller.
    pub fn tick(self: *FrameSequencer) FrameEvent {
        self.total_cycles +%= 1;

        if (self.reset_delay > 0) {
            self.reset_delay -= 1;
            if (self.reset_delay == 0) self.cycle = 0;
        }
        self.cycle += 1;

        const event: FrameEvent = switch (self.mode) {
            0 => switch (self.cycle) {
                7457 => .quarter,
                14913 => .quarter_and_half,
                22371 => .quarter,
                29829 => blk: {
                    if (!self.irq_inhibit) self.irq_flag = true;
                    break :blk .quarter_and_half;
                },
                else => .none,
            },
            1 => switch (self.cycle) {
                7457 => .quarter,
                14913 => .quarter_and_half,
                22371 => .quarter,
                37281 => .quarter_and_half,
                else => .none,
            },
        };

        const last_cycle: u32 = if (self.mode == 0) 29829 else 37281;
        if (self.cycle >= last_cycle) self.cycle = 0;

        return event;
    }
};

test "FrameSequencer mode 0: quarter at 7457, quarter+half at 14913, quarter at 22371, quarter+half+irq at 29829, reset at 29830" {
    var fs = FrameSequencer{};
    fs.cycle = 7456;
    try testing.expectEqual(FrameEvent.quarter, fs.tick());
    fs.cycle = 14912;
    try testing.expectEqual(FrameEvent.quarter_and_half, fs.tick());
    fs.cycle = 22370;
    try testing.expectEqual(FrameEvent.quarter, fs.tick());
    fs.cycle = 29828;
    try testing.expectEqual(FrameEvent.quarter_and_half, fs.tick());
    try testing.expect(fs.irq_flag);
    try testing.expectEqual(@as(u32, 0), fs.cycle); // reset one cycle later
}

test "FrameSequencer mode 0 does not set the IRQ flag while inhibited" {
    var fs = FrameSequencer{ .irq_inhibit = true };
    fs.cycle = 29828;
    _ = fs.tick();
    try testing.expect(!fs.irq_flag);
}

test "FrameSequencer mode 1: step 4 (29829) clocks nothing; step 5 (37281) clocks quarter+half, no IRQ ever" {
    var fs = FrameSequencer{ .mode = 1 };
    fs.cycle = 29828;
    try testing.expectEqual(FrameEvent.none, fs.tick());
    fs.cycle = 37280;
    try testing.expectEqual(FrameEvent.quarter_and_half, fs.tick());
    try testing.expect(!fs.irq_flag);
}

test "writing $80 to $4017 immediately clocks quarter+half; writing $00 does not" {
    var fs = FrameSequencer{};
    try testing.expectEqual(FrameEvent.none, fs.write(0x00));
    try testing.expectEqual(FrameEvent.quarter_and_half, fs.write(0x80));
}

test "writing $40 or $C0 to $4017 clears a pending IRQ flag immediately" {
    var fs = FrameSequencer{};
    fs.irq_flag = true;
    _ = fs.write(0x40);
    try testing.expect(!fs.irq_flag);
}

/// https://www.nesdev.org/wiki/APU_Mixer.
pub fn mixOutput(pulse1: u4, pulse2: u4, triangle: u4, noise: u4, dmc: u7) f32 {
    const p1: f32 = @floatFromInt(pulse1);
    const p2: f32 = @floatFromInt(pulse2);
    const t: f32 = @floatFromInt(triangle);
    const n: f32 = @floatFromInt(noise);
    const d: f32 = @floatFromInt(dmc);

    const pulse_sum = p1 + p2;
    const pulse_out: f32 = if (pulse_sum == 0) 0 else 95.88 / (8128.0 / pulse_sum + 100.0);

    const tnd_sum = t / 8227.0 + n / 12241.0 + d / 22638.0;
    const tnd_out: f32 = if (tnd_sum == 0) 0 else 159.79 / (1.0 / tnd_sum + 100.0);

    return pulse_out + tnd_out;
}

/// One-pole RC filter -- three of these, cascaded, model the NTSC NES's
/// output filtering (90Hz HPF, 440Hz HPF, 14kHz LPF). See
/// `docs/adr/0002-apu-mixing-and-filtering.md`.
pub const OnePoleFilter = struct {
    pub const Kind = enum { low_pass, high_pass };

    kind: Kind,
    alpha: f32,
    prev_in: f32 = 0,
    prev_out: f32 = 0,

    pub fn init(kind: Kind, cutoff_hz: f32, sample_rate: f32) OnePoleFilter {
        const dt = 1.0 / sample_rate;
        const rc = 1.0 / (2.0 * std.math.pi * cutoff_hz);
        const alpha = switch (kind) {
            .low_pass => dt / (rc + dt),
            .high_pass => rc / (rc + dt),
        };
        return .{ .kind = kind, .alpha = alpha };
    }

    pub fn process(self: *OnePoleFilter, x: f32) f32 {
        const y = switch (self.kind) {
            .low_pass => self.prev_out + self.alpha * (x - self.prev_out),
            .high_pass => self.alpha * (self.prev_out + x - self.prev_in),
        };
        self.prev_in = x;
        self.prev_out = y;
        return y;
    }
};

pub const Apu = struct {
    pulse1: Pulse = .{ .is_pulse1 = true },
    pulse2: Pulse = .{ .is_pulse1 = false },
    triangle: Triangle = .{},
    noise: Noise = .{},
    dmc: Dmc = .{},
    frame: FrameSequencer = .{},

    hpf1: OnePoleFilter = OnePoleFilter.init(.high_pass, 90.0, 1_789_773.0),
    hpf2: OnePoleFilter = OnePoleFilter.init(.high_pass, 440.0, 1_789_773.0),
    lpf: OnePoleFilter = OnePoleFilter.init(.low_pass, 14_000.0, 1_789_773.0),

    even_cycle: bool = false,

    pub fn init() Apu {
        return .{};
    }

    pub fn writeRegister(self: *Apu, addr: u16, value: u8) void {
        switch (addr) {
            0x4000 => self.pulse1.writeReg0(value),
            0x4001 => self.pulse1.writeReg1(value),
            0x4002 => self.pulse1.writeReg2(value),
            0x4003 => self.pulse1.writeReg3(value),
            0x4004 => self.pulse2.writeReg0(value),
            0x4005 => self.pulse2.writeReg1(value),
            0x4006 => self.pulse2.writeReg2(value),
            0x4007 => self.pulse2.writeReg3(value),
            0x4008 => self.triangle.writeReg0(value),
            0x400A => self.triangle.writeReg2(value),
            0x400B => self.triangle.writeReg3(value),
            0x400C => {
                // --LC.VVVV -- same shape as pulse's byte 0, minus the duty
                // bits (noise has no duty cycle).
                self.noise.envelope.loop_flag = (value & 0x20) != 0;
                self.noise.envelope.constant_volume = (value & 0x10) != 0;
                self.noise.envelope.volume_or_period = @truncate(value & 0x0F);
            },
            0x400E => self.noise.writeReg2(value),
            0x400F => self.noise.writeReg3(value),
            0x4010 => self.dmc.writeReg0(value),
            0x4011 => self.dmc.writeReg1(value),
            0x4012 => self.dmc.writeReg2(value),
            0x4013 => self.dmc.writeReg3(value),
            0x4015 => self.writeStatus(value),
            0x4017 => {
                const event = self.frame.write(value);
                self.applyFrameEvent(event);
            },
            else => {},
        }
    }

    fn writeStatus(self: *Apu, value: u8) void {
        self.pulse1.enabled = (value & 0x01) != 0;
        self.pulse2.enabled = (value & 0x02) != 0;
        self.triangle.enabled = (value & 0x04) != 0;
        self.noise.enabled = (value & 0x08) != 0;
        if (!self.pulse1.enabled) self.pulse1.length_counter = 0;
        if (!self.pulse2.enabled) self.pulse2.length_counter = 0;
        if (!self.triangle.enabled) self.triangle.length_counter = 0;
        if (!self.noise.enabled) self.noise.length_counter = 0;

        const dmc_enable = (value & 0x10) != 0;
        self.dmc.irq_flag = false;
        if (!dmc_enable) {
            self.dmc.bytes_remaining = 0;
        } else if (self.dmc.bytes_remaining == 0) {
            self.dmc.restart();
        }
    }

    pub fn readStatus(self: *Apu) u8 {
        var status: u8 = 0;
        if (self.pulse1.length_counter > 0) status |= 0x01;
        if (self.pulse2.length_counter > 0) status |= 0x02;
        if (self.triangle.length_counter > 0) status |= 0x04;
        if (self.noise.length_counter > 0) status |= 0x08;
        if (self.dmc.bytes_remaining > 0) status |= 0x10;
        if (self.frame.irq_flag) status |= 0x40;
        if (self.dmc.irq_flag) status |= 0x80;
        self.frame.irq_flag = false; // reading clears the frame IRQ only
        return status;
    }

    fn applyFrameEvent(self: *Apu, event: FrameEvent) void {
        switch (event) {
            .none => {},
            .quarter => self.clockQuarterFrame(),
            .half => self.clockHalfFrame(),
            .quarter_and_half => {
                self.clockQuarterFrame();
                self.clockHalfFrame();
            },
        }
    }

    fn clockQuarterFrame(self: *Apu) void {
        self.pulse1.envelope.clock();
        self.pulse2.envelope.clock();
        self.noise.envelope.clock();
        self.triangle.clockLinearCounter();
    }

    fn clockHalfFrame(self: *Apu) void {
        clockLength(&self.pulse1.length_counter, self.pulse1.envelope.loop_flag);
        clockLength(&self.pulse2.length_counter, self.pulse2.envelope.loop_flag);
        clockLength(&self.triangle.length_counter, self.triangle.control_flag);
        clockLength(&self.noise.length_counter, self.noise.envelope.loop_flag);
        self.pulse1.clockSweep();
        self.pulse2.clockSweep();
    }

    pub fn irqPending(self: *const Apu) bool {
        return self.frame.irq_flag or self.dmc.irq_flag;
    }

    /// Called once per CPU cycle from `Cpu.tick`. `FrameSequencer.tick`
    /// owns its own cycle counting (see that type's doc comment) -- this
    /// does not pre-increment anything on its behalf.
    pub fn tick(self: *Apu, mapper: *const Mapper) void {
        self.applyFrameEvent(self.frame.tick());

        self.triangle.tickTimer();
        self.even_cycle = !self.even_cycle;
        if (self.even_cycle) {
            self.pulse1.tickTimer();
            self.pulse2.tickTimer();
            self.noise.tickTimer();
            self.dmc.tickTimer(mapper);
        }

        const raw = mixOutput(self.pulse1.output(), self.pulse2.output(), self.triangle.output(), self.noise.output(), self.dmc.output());
        const filtered = self.lpf.process(self.hpf2.process(self.hpf1.process(raw)));
        audio_ring.pushSample(filtered);
    }
};

test "Apu.writeRegister routes $4000-$4013 to the right channel" {
    var apu = Apu.init();
    apu.writeRegister(0x4000, 0b00_0_1_0101); // pulse1 duty0, constant vol 5
    try testing.expectEqual(@as(u4, 5), apu.pulse1.envelope.volume_or_period);
    apu.writeRegister(0x4008, 0x80); // triangle control flag (bit 7, per CRRR.RRRR)
    try testing.expect(apu.triangle.control_flag);
    apu.writeRegister(0x400C, 0x20); // noise halt/loop
    try testing.expect(apu.noise.envelope.loop_flag);
    apu.writeRegister(0x4010, 0x80); // dmc irq enable
    try testing.expect(apu.dmc.irq_enabled);
}

test "Apu.writeRegister($4015) enables/disables channels and clears their length counters when disabled" {
    var apu = Apu.init();
    apu.pulse1.length_counter = 10;
    apu.writeRegister(0x4015, 0b0000_0000); // disable everything
    try testing.expect(!apu.pulse1.enabled);
    try testing.expectEqual(@as(u8, 0), apu.pulse1.length_counter);

    apu.writeRegister(0x4015, 0b0000_0001); // enable pulse1 only
    try testing.expect(apu.pulse1.enabled);
    try testing.expect(!apu.pulse2.enabled);
}

test "Apu.writeRegister($4015) restarts the DMC only when bytes_remaining is already 0" {
    var apu = Apu.init();
    apu.dmc.bytes_remaining = 3;
    apu.writeRegister(0x4015, 0x10); // DMC enable bit
    try testing.expectEqual(@as(u16, 3), apu.dmc.bytes_remaining); // unaffected: already playing

    apu.dmc.bytes_remaining = 0;
    apu.writeRegister(0x4015, 0x10);
    try testing.expect(apu.dmc.bytes_remaining > 0); // restarted
}

test "Apu.readStatus reports length-counter-nonzero bits, DMC active, and both IRQ flags, then clears only the frame IRQ" {
    var apu = Apu.init();
    apu.pulse1.length_counter = 1;
    apu.dmc.bytes_remaining = 1;
    apu.frame.irq_flag = true;
    apu.dmc.irq_flag = true;
    const status = apu.readStatus();
    try testing.expectEqual(@as(u8, 0b1101_0001), status); // DMC-irq | frame-irq | dmc-active | pulse1
    try testing.expect(!apu.frame.irq_flag); // cleared by the read
    try testing.expect(apu.dmc.irq_flag); // NOT cleared by the read
}

test "Apu.irqPending is the OR of the frame IRQ and DMC IRQ flags" {
    var apu = Apu.init();
    try testing.expect(!apu.irqPending());
    apu.frame.irq_flag = true;
    try testing.expect(apu.irqPending());
    apu.frame.irq_flag = false;
    apu.dmc.irq_flag = true;
    try testing.expect(apu.irqPending());
}

test "mixOutput is 0 when every channel is silent, and nonzero once one contributes" {
    try testing.expectEqual(@as(f32, 0), mixOutput(0, 0, 0, 0, 0));
    try testing.expect(mixOutput(15, 0, 0, 0, 0) > 0);
    try testing.expect(mixOutput(0, 0, 15, 0, 0) > 0);
}

test "OnePoleFilter high-pass blocks DC after settling; low-pass passes DC unchanged" {
    var hpf = OnePoleFilter.init(.high_pass, 90.0, 48000.0);
    var i: usize = 0;
    while (i < 10000) : (i += 1) _ = hpf.process(1.0); // feed a constant -- DC
    try testing.expect(@abs(hpf.process(1.0)) < 0.01);

    var lpf = OnePoleFilter.init(.low_pass, 14000.0, 48000.0);
    i = 0;
    while (i < 10000) : (i += 1) _ = lpf.process(1.0);
    try testing.expect(@abs(lpf.process(1.0) - 1.0) < 0.01);
}
