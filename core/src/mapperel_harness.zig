//! Shared native-test harness for the vendored holy-mapperel ROMs
//! (`core/tests/roms/holy_mapperel/`), the M7 mapper conformance gate.
//!
//! Three ways this differs from the two harnesses that already exist, which
//! is why it is its own file rather than a case inside either:
//!
//!   * **No result protocol to poll.** Blargg's ROMs hand back a status byte
//!     at `$6000` (`blargg_harness.zig`); holy-mapperel draws its findings on
//!     screen and then beeps them in Morse. So this harness runs until the
//!     result *text* appears, with a cycle ceiling so a hang fails instead of
//!     hanging CI.
//!   * **Tile IDs are not ASCII.** The 2005-vintage Blargg suites
//!     (`ppu_sprites_test.zig`) write plain ASCII into the nametable, so tile
//!     ID = ASCII code. holy-mapperel's `puts` does `lda #char / and #$3F /
//!     sta PPUDATA` against a 64-tile font, so `$40-$5F` (which is most
//!     letters) folds down to `$00-$1F` and has to be folded back.
//!   * **Nametable 0 is not necessarily physical bank 0.** The existing
//!     nametable-text harness reads `Ppu.vram[0..960]` directly, which holds
//!     under fixed horizontal or vertical mirroring. holy-mapperel identifies
//!     the mapper *by writing to its mirroring ports*, and MMC1 can select
//!     one-screen-upper, which puts logical nametable 0 in physical bank 1.
//!     So this resolves the bank through `Mapper.mirroring()` at read time.
//!
//! ## The result line
//!
//! The ROM prints the detected board name, the measured PRG/CHR/WRAM sizes,
//! and then a line reading `DETAILED TEST RESULT: WPIC` — four hex digits
//! covering **W**RAM, **P**RG ROM, **I**RQ, and **C**HR, in that order, where
//! zero means "nothing unexpected". `expectResult` asserts all four against a
//! caller-supplied value rather than only the ones currently expected to be
//! zero: a digit nobody asserts is a digit that can regress in silence, and
//! precise reporting is this suite's whole reason for being here.
//!
//! See `core/tests/roms/holy_mapperel/ATTRIBUTION.md` (zlib licensed, unlike
//! every other vendored suite here) and
//! `docs/reference/external-resources.md`.

const std = @import("std");
const testing = std.testing;

const ppu_mod = @import("ppu.zig");
const Machine = @import("machine.zig").Machine;

/// Roughly 85 seconds of NES time. The CHR-RAM and WRAM tests write and
/// verify pseudorandom patterns over the whole of each memory eight times
/// (buzzing the speaker so a human knows it hasn't frozen), so these ROMs
/// take far longer to report than a Blargg test does -- but still a small
/// fraction of this. The ceiling exists so a genuine hang fails the test.
const max_cycles: u64 = 150_000_000;
const poll_interval_cycles: u64 = 500_000;

const anchor = "DETAILED TEST RESULT: ";

/// Fold one nametable tile ID back into the character the ROM meant. `puts`
/// masks every character with `$3F` before writing it, so `A`-`_` ($41-$5F)
/// arrive as $01-$1F while space-`@` ($20-$40) arrive unchanged. `puthex`
/// produces digits the same way.
fn tileToChar(tile: u8) u8 {
    return if (tile < 0x20) tile + 0x40 else tile;
}

/// The 960 tiles (32x30, stopping before the attribute table) of *logical*
/// nametable 0, decoded to characters. Resolves to a physical VRAM bank
/// through the cartridge's current mirroring rather than assuming bank 0.
fn screenText(m: *const Machine, buf: *[960]u8) []const u8 {
    const bank = ppu_mod.physicalNametable(m.bus.mapper.mirroring(), 0);
    const base = @as(usize, bank) * 0x400;
    for (m.bus.ppu.vram[base..][0..960], 0..) |tile, i| buf[i] = tileToChar(tile);
    return buf[0..960];
}

fn hexDigit(c: u8) ?u16 {
    return switch (c) {
        '0'...'9' => c - '0',
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// The four hex digits following the anchor, as one value: `$WPIC`.
fn parseDetailed(text: []const u8) ?u16 {
    const at = std.mem.indexOf(u8, text, anchor) orelse return null;
    const digits = text[at + anchor.len ..];
    if (digits.len < 4) return null;
    var value: u16 = 0;
    for (digits[0..4]) |c| value = (value << 4) | (hexDigit(c) orelse return null);
    return value;
}

pub const Result = struct {
    detailed: u16,
    /// The full decoded screen, for failure output: it carries the detected
    /// board name and the measured sizes, which is what makes a failure
    /// diagnosable rather than just red.
    screen: [960]u8,
};

fn runToResult(m: *Machine, screen: *[960]u8) !Result {
    while (m.cpu.cycles < max_cycles) {
        const target = m.cpu.cycles + poll_interval_cycles;
        while (m.cpu.cycles < target) m.cpu.step();
        if (parseDetailed(screenText(m, screen))) |detailed| {
            return .{ .detailed = detailed, .screen = screen.* };
        }
    }
    return error.Timeout;
}

/// Print the screen as 30 lines of 32 characters, trailing spaces trimmed.
fn dumpScreen(name: []const u8, screen: *const [960]u8) void {
    std.debug.print("\n{s} screen:\n", .{name});
    var row: usize = 0;
    while (row < 30) : (row += 1) {
        const line = screen[row * 32 ..][0..32];
        var end: usize = line.len;
        while (end > 0 and (line[end - 1] == ' ' or line[end - 1] == 0)) end -= 1;
        if (end > 0) std.debug.print("  |{s}\n", .{line[0..end]});
    }
}

/// Run `rom_bytes` to its result screen and assert the exact detailed code.
///
/// `expected_board` is the board name the ROM's own mapper detection printed
/// (e.g. `"S*ROM (MMC1)"`); asserting it catches the case where the detailed
/// code is right by accident because the ROM decided it was running on some
/// other mapper entirely -- detection happens by writing to mirroring ports,
/// so it is a real assertion about this core, not a formality.
pub fn expectResult(
    name: []const u8,
    rom_bytes: []const u8,
    expected_board: []const u8,
    expected_detailed: u16,
) !void {
    var m: Machine = undefined;
    try m.init(rom_bytes);
    var screen: [960]u8 = undefined;
    const result = try runToResult(&m, &screen);

    if (std.mem.indexOf(u8, &result.screen, expected_board) == null) {
        std.debug.print("\n{s}: expected board {s}, not detected\n", .{ name, expected_board });
        dumpScreen(name, &result.screen);
        return error.TestUnexpectedResult;
    }
    if (result.detailed != expected_detailed) {
        std.debug.print(
            "\n{s}: detailed result {X:0>4}, expected {X:0>4} (digits: WRAM PRG IRQ CHR)\n",
            .{ name, result.detailed, expected_detailed },
        );
        dumpScreen(name, &result.screen);
        return error.TestUnexpectedResult;
    }
}

test "tileToChar folds the ROM's 6-bit font back to ASCII" {
    try testing.expectEqual(@as(u8, 'A'), tileToChar('A' & 0x3F));
    try testing.expectEqual(@as(u8, 'Z'), tileToChar('Z' & 0x3F));
    try testing.expectEqual(@as(u8, ' '), tileToChar(' ')); // $20-$3F unchanged
    try testing.expectEqual(@as(u8, '7'), tileToChar('7'));
}

test "parseDetailed reads the four hex digits after the anchor" {
    var text = [_]u8{' '} ** 64;
    @memcpy(text[8..][0..anchor.len], anchor);
    @memcpy(text[8 + anchor.len ..][0..4], "10A3");
    try testing.expectEqual(@as(?u16, 0x10A3), parseDetailed(&text));
}

test "parseDetailed yields null before the ROM has drawn its result" {
    const blank = [_]u8{' '} ** 64;
    try testing.expectEqual(@as(?u16, null), parseDetailed(&blank));
}
