//! Shared native-test harness for every vendored ROM that speaks Blargg's
//! standard `$6000` status-byte protocol: a live test first writes the
//! signature `$DE $B0 $61` to `$6001-$6003` (the readme's own `$G1` is a
//! documented typo for `$61`), then `$6000` carries status -- `$80` = still
//! running, `$81` = "needs the reset button pressed, but delayed by at
//! least 100 msec from now", `$00`-`$7F` = done, with that value as the
//! result code (`$00` = pass). Null-terminated ASCII detail text starts at
//! `$6004`. See `docs/research/test-rom-licensing.md` (ENG-59) for the full
//! protocol writeup.
//!
//! Extracted from `ppu_vbl_nmi_test.zig` (ENG-66) when `ppu_sprites_test.zig`
//! (ENG-68) needed the identical polling/reset-handling logic for
//! `oam_read`/`oam_stress` -- both of which speak this same protocol, unlike
//! `sprite_hit_tests_2005.10.05`/`sprite_overflow_tests`, which predate it
//! (see `ppu_sprites_test.zig`'s own nametable-text harness for those).

const std = @import("std");
const testing = std.testing;

const rom_mod = @import("rom.zig");
const bus_mod = @import("bus.zig");
const cpu_mod = @import("cpu.zig");

/// NTSC CPU clock, Hz. Used only to convert Blargg's "at least 100 msec"
/// reset-delay requirement into a cycle count.
const cpu_hz: u64 = 1_789_773;

/// Generous ceiling on total emulated CPU cycles per sub-test (roughly 60
/// seconds of NES time). Every ROM this harness runs completes in a small
/// fraction of a second of NES time; this exists purely so a genuine hang
/// (a bug that makes the ROM spin forever) fails the test instead of
/// hanging CI.
const max_cycles: u64 = 60 * cpu_hz;

/// >=100ms of emulated NES time, rounded up, per the `$81` protocol.
const min_reset_delay_cycles: u64 = (100 * cpu_hz) / 1000 + 1;

const max_resets: u32 = 10;

const HarnessError = error{ Timeout, TooManyResets };

/// Grab the null-terminated ASCII detail text at $6004, for failure output.
fn statusText(bus: *const bus_mod.Bus, buf: []u8) []const u8 {
    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        const c = bus.peek(@intCast(0x6004 + i));
        if (c == 0) break;
        buf[i] = c;
    }
    return buf[0..i];
}

/// One booted machine, kept as a struct so `cpu`'s pointer to `bus` stays
/// valid: `Cpu` borrows `*Bus`, so the pair has to reach its final address
/// before being wired together. Two-phase init (`var m: Machine = undefined;
/// try m.init(rom)`) is the same shape `cpu.zig`'s own `TestHarness` uses.
pub const Machine = struct {
    bus: bus_mod.Bus,
    cpu: cpu_mod.Cpu,

    pub fn init(self: *Machine, rom_bytes: []const u8) !void {
        const rom = try rom_mod.Rom.load(rom_bytes);
        self.bus = bus_mod.Bus.init(try rom_mod.createMapper(rom), rom.header.mirroring);
        self.cpu = cpu_mod.Cpu.init(&self.bus);
        self.cpu.reset();
    }

    /// Run until `$6000` reports a terminal result code, and return it.
    ///
    /// Polls `$6000` via `bus.peek` (side-effect-free -- the ROM itself owns
    /// that address's real read/write through `Bus.read`/`Bus.write` as part
    /// of `cpu.step`; polling separately must not perturb anything). Handles
    /// the `$81` "needs a reset, delayed >=100ms" code by running out that
    /// delay in emulated NES time and then calling `cpu.reset()`, exactly per
    /// the documented protocol. Bounded by `max_cycles` so a ROM that spins
    /// forever fails the test instead of hanging CI.
    pub fn runToTerminalStatus(self: *Machine) !u8 {
        var resets: u32 = 0;
        while (true) {
            if (self.cpu.cycles > max_cycles) return HarnessError.Timeout;
            self.cpu.step();
            if (self.bus.peek(0x6001) != 0xDE or
                self.bus.peek(0x6002) != 0xB0 or
                self.bus.peek(0x6003) != 0x61) continue;
            const s = self.bus.peek(0x6000);
            if (s == 0x80) continue;
            if (s == 0x81) {
                resets += 1;
                if (resets > max_resets) return HarnessError.TooManyResets;
                const target = self.cpu.cycles + min_reset_delay_cycles;
                while (self.cpu.cycles < target) {
                    if (self.cpu.cycles > max_cycles) return HarnessError.Timeout;
                    self.cpu.step();
                }
                self.cpu.reset();
                continue;
            }
            return s;
        }
    }
};

/// Run one Blargg-protocol ROM, asserting its result code is `$00` (pass).
pub fn expectPass(name: []const u8, rom_bytes: []const u8) !void {
    var m: Machine = undefined;
    try m.init(rom_bytes);
    const status = try m.runToTerminalStatus();

    if (status != 0) {
        var buf: [256]u8 = undefined;
        std.debug.print(
            "\n{s}: result code ${X:0>2}\n  detail: {s}\n",
            .{ name, status, statusText(&m.bus, &buf) },
        );
    }
    try testing.expectEqual(@as(u8, 0), status);
}
