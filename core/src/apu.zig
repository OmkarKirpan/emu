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
