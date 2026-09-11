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

const bus_mod = @import("bus.zig");
const Machine = @import("machine.zig").Machine;

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

/// Run `m` until `$6000` reports a terminal result code, and return it.
///
/// Polls `$6000` via `bus.peek` (side-effect-free -- the ROM itself owns
/// that address's real read/write through `Bus.read`/`Bus.write` as part
/// of `cpu.step`; polling separately must not perturb anything). Handles
/// the `$81` "needs a reset, delayed >=100ms" code by running out that
/// delay in emulated NES time and then calling `cpu.reset()`, exactly per
/// the documented protocol. Bounded by `max_cycles` so a ROM that spins
/// forever fails the test instead of hanging CI.
///
/// A free function taking `*Machine` rather than a method: the booted
/// console itself is shared (`machine.zig`), and this protocol is one
/// particular thing to do with one, not part of what a machine is.
pub fn runToTerminalStatus(m: *Machine) !u8 {
    var resets: u32 = 0;
    while (true) {
        if (m.cpu.cycles > max_cycles) return HarnessError.Timeout;
        m.cpu.step();
        if (m.bus.peek(0x6001) != 0xDE or
            m.bus.peek(0x6002) != 0xB0 or
            m.bus.peek(0x6003) != 0x61) continue;
        const s = m.bus.peek(0x6000);
        if (s == 0x80) continue;
        if (s == 0x81) {
            resets += 1;
            if (resets > max_resets) return HarnessError.TooManyResets;
            const target = m.cpu.cycles + min_reset_delay_cycles;
            while (m.cpu.cycles < target) {
                if (m.cpu.cycles > max_cycles) return HarnessError.Timeout;
                m.cpu.step();
            }
            m.cpu.reset();
            continue;
        }
        return s;
    }
}

/// Run one Blargg-protocol ROM, asserting its result code is `$00` (pass).
pub fn expectPass(name: []const u8, rom_bytes: []const u8) !void {
    var m: Machine = undefined;
    try m.init(rom_bytes);
    const status = try runToTerminalStatus(&m);

    if (status != 0) {
        var buf: [256]u8 = undefined;
        std.debug.print(
            "\n{s}: result code ${X:0>2}\n  detail: {s}\n",
            .{ name, status, statusText(&m.bus, &buf) },
        );
    }
    try testing.expectEqual(@as(u8, 0), status);
}

// ------------------------------------------- the nametable-text protocol

/// Blargg's *other* result convention, older than `$6000`: the ROM prints
/// its verdict to the screen through a text console whose font is loaded so
/// that every tile ID is the character's own ASCII code, so the verdict can
/// be read straight out of `Ppu.vram` with no rendering involved.
///
/// Two generations of it are vendored here and they word things
/// differently -- `sprite_hit_tests_2005.10.05`/`sprite_overflow_tests` say
/// `"PASSED"`/`"FAILED #n"`, while `dmc_dma_during_read4`/
/// `sprdma_and_dmc_dma` say `"Passed"`/`"Failed"`/`"Error n"` -- so the
/// marker matching stays with each suite's own test file and only the
/// polling loop is shared. See `ppu_sprites_test.zig` and
/// `dmc_dma_test.zig`.
pub const NametableOutcome = union(enum) { passed, failed: u32 };

/// Generous ceiling on total emulated CPU cycles (roughly 45 seconds of NES
/// time). Every ROM using this protocol reports in well under a second of
/// NES time in practice; this exists purely so a genuine hang fails the
/// test instead of hanging CI.
const max_text_cycles: u64 = 80_000_000;
const text_poll_interval: u64 = 20_000;

/// Nametable 0's tile grid always lives at `Ppu.vram` offset 0 regardless
/// of mirroring mode (`physicalNametable` maps logical nametable 0 to
/// physical bank 0 either way), so reading the first 960 bytes (32x30
/// tiles, before the 64-byte attribute table at $3C0-$3FF) is valid for any
/// of these ROMs' mirroring header.
pub fn nametableText(m: *const Machine, buf: *[960]u8) []const u8 {
    @memcpy(buf, m.bus.ppu.vram[0..960]);
    return buf[0..960];
}

/// Step `m` until `match` reads a verdict out of nametable 0. `match`
/// returns null for "still running".
pub fn runToNametableOutcome(
    m: *Machine,
    match: *const fn ([]const u8) ?NametableOutcome,
) !NametableOutcome {
    var buf: [960]u8 = undefined;
    while (m.cpu.cycles < max_text_cycles) {
        const target = m.cpu.cycles + text_poll_interval;
        while (m.cpu.cycles < target) m.cpu.step();
        if (match(nametableText(m, &buf))) |outcome| return outcome;
    }
    return HarnessError.Timeout;
}
