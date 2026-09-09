//! ENG-76 (M8)'s first acceptance criterion, against real cartridges:
//! "save/load round-trips byte-identical state across all M7 mapper types
//! (NROM, MMC1, UxROM, CNROM, MMC3)".
//!
//! `savestate.zig`'s own tests establish the format's mechanics on a
//! synthetic NROM sled -- header framing, rejection paths, unknown-section
//! skipping. What they cannot establish is that the *field list* is
//! complete for a cartridge that actually banks, mirrors and interrupts:
//! an MMC3 state missing `a12_low_ticks` round-trips perfectly on a ROM
//! that never touches the PPU. So this file runs each mapper's vendored
//! conformance ROM far enough to have exercised its registers, and checks
//! two different things:
//!
//! 1. **The digest matches immediately after a load** -- every serialized
//!    field came back.
//! 2. **The two machines still agree after running on** -- nothing *not*
//!    serialized was load-bearing. This is the half that catches an
//!    omission, because an unrestored bank register or IRQ counter shows up
//!    as divergence a few frames later, not at the moment of the load.
//!
//! ROM choices mirror `mapperel_harness.zig`'s: holy-mapperel's per-mapper
//! conformance ROMs (zlib licensed, see
//! `tests/roms/holy_mapperel/ATTRIBUTION.md`), plus this repo's own
//! original NROM demo. `M1_P128K_CR8K` and `M4_P128K_CR8K` are the CHR-RAM
//! variants, so the mapper section's CHR-RAM branch is covered too, not
//! just the CHR-ROM one.

const std = @import("std");
const testing = std.testing;

const savestate = @import("savestate.zig");
const Machine = @import("machine.zig").Machine;

/// See `determinism.zig`'s matching comment: file-scope so no caller pays a
/// 64KB stack frame, safe because Zig's test runner is single-threaded.
var scratch: [savestate.max_state_bytes]u8 = undefined;
var blob: [savestate.max_state_bytes]u8 = undefined;

fn hashOf(m: *const Machine) savestate.RomHash {
    return savestate.hash(m, &scratch) catch unreachable;
}

/// Run `rom_bytes` for `frames`, snapshot it, restore that snapshot into a
/// machine aged differently (so a missed field cannot be masked by both
/// sides already agreeing), and assert both properties above.
fn expectRoundTrip(rom_bytes: []const u8, frames: u32) !void {
    var source: Machine = undefined;
    try source.init(rom_bytes);
    source.runFrames(frames);

    const n = try savestate.save(&source, savestate.romHash(rom_bytes), &blob);
    const expected = hashOf(&source);

    var target: Machine = undefined;
    try target.init(rom_bytes);
    target.runFrames(frames / 2 + 1);
    try testing.expect(!std.mem.eql(u8, &expected, &hashOf(&target)));

    try savestate.load(&target, rom_bytes, blob[0..n]);
    try testing.expectEqualSlices(u8, &expected, &hashOf(&target));

    // The half that actually finds omissions -- see this file's doc comment.
    source.runFrames(3);
    target.runFrames(3);
    try testing.expectEqualSlices(u8, &hashOf(&source), &hashOf(&target));
}

test "save/load round-trips an NROM cartridge" {
    try expectRoundTrip(@embedFile("sprite_input_demo"), 8);
}

test "save/load round-trips an MMC1 cartridge (CHR-RAM)" {
    try expectRoundTrip(@embedFile("mapperel_M1_P128K_CR8K"), 8);
}

test "save/load round-trips an MMC1 cartridge (CHR-ROM banking)" {
    try expectRoundTrip(@embedFile("mapperel_M1_P128K_C128K"), 8);
}

test "save/load round-trips a UxROM cartridge" {
    try expectRoundTrip(@embedFile("mapperel_M2_P128K_CR8K_V"), 8);
}

test "save/load round-trips a CNROM cartridge" {
    try expectRoundTrip(@embedFile("mapperel_M3_P32K_C32K_H"), 8);
}

test "save/load round-trips an MMC3 cartridge (CHR-ROM, scanline IRQ)" {
    try expectRoundTrip(@embedFile("mapperel_M4_P256K_C256K"), 8);
}

test "save/load round-trips an MMC3 cartridge (CHR-RAM)" {
    try expectRoundTrip(@embedFile("mapperel_M4_P128K_CR8K"), 8);
}

test "a state saved from one cartridge is rejected against another" {
    const mmc1 = @embedFile("mapperel_M1_P128K_CR8K");
    const mmc3 = @embedFile("mapperel_M4_P128K_CR8K");

    var source: Machine = undefined;
    try source.init(mmc1);
    source.runFrames(4);
    const n = try savestate.save(&source, savestate.romHash(mmc1), &blob);

    // The ROM-hash check fires first: it is the stronger of the two, since
    // two different cartridges usually share a mapper.
    var target: Machine = undefined;
    try target.init(mmc3);
    try testing.expectError(error.RomMismatch, savestate.load(&target, mmc3, blob[0..n]));

    // ...and with the hash forced to match, the mapper id still rejects it.
    var forged = blob;
    @memcpy(forged[12..44], &savestate.romHash(mmc3));
    try testing.expectError(error.MapperMismatch, savestate.load(&target, mmc3, forged[0..n]));
}

test "a cartridge's SRAM survives a round-trip" {
    const rom = @embedFile("mapperel_M1_P512K_CR8K_S8K"); // the battery-backed one
    var source: Machine = undefined;
    try source.init(rom);
    source.runFrames(4);
    source.bus.prg_ram[0x100] = 0x5A; // stand-in for a game's save data

    const n = try savestate.save(&source, savestate.romHash(rom), &blob);

    var target: Machine = undefined;
    try target.init(rom);
    try savestate.load(&target, rom, blob[0..n]);
    try testing.expectEqual(@as(u8, 0x5A), target.bus.prg_ram[0x100]);
}
