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
