//! UxROM (mapper 2) conformance stage — M7b (ENG-73), per ENG-64's staged
//! test-ROM architecture.
//!
//! One holy-mapperel ROM, unlike MMC1's three: UxROM has one register, one
//! PRG mode, and CHR that is always 8KB unbanked RAM, so there is no
//! CHR-ROM-vs-CHR-RAM split or oversized-board path to cover separately.
//! See `core/tests/roms/holy_mapperel/ATTRIBUTION.md` for why this
//! particular file (of the two `M2_*` ROMs in the release archive) is the
//! one vendored, and `mapperel_harness.zig` for the shared harness this
//! reuses verbatim from M7a.

const std = @import("std");

const mapperel = @import("mapperel_harness.zig");

// The four digits are WRAM, PRG ROM, IRQ, CHR.
//
//   * **WRAM is 0**: UxROM carries no WRAM at all, and the ROM's own WRAM
//     test only runs when it detects $6000-$7FFF as RAM -- `Bus` maps that
//     range unconditionally (see its doc comment), but nothing on a UxROM
//     board reads or writes there, so the detection finds nothing to fault.
//   * **PRG is 0**: every bank number lands in the right window, in the
//     board's one PRG mode, and the fixed bank at $C000 never moves. This is
//     also the answer to whether UxROM needs bus-conflict emulation --
//     see `Uxrom`'s doc comment in `mapper.zig` for the reasoning, and this
//     0 for the evidence: the vendored ROM's own bank-select writes already
//     tolerate this core's conflict-free implementation.
//   * **IRQ is 0**: UxROM has no IRQ line, same as NROM and MMC1.
//   * **CHR is 0**: the 8KB CHR-RAM read/write/pattern test passes -- there
//     is no bank register to get wrong, unlike MMC1's CHR windows.
const expected_M2_P128K_CR8K_V: u16 = 0x0000;

test "holy-mapperel M2_P128K_CR8K_V (128KB PRG, 8KB CHR-RAM, UNROM/UOROM)" {
    try mapperel.expectResult(
        "M2_P128K_CR8K_V",
        @embedFile("mapperel_M2_P128K_CR8K_V"),
        "U*ROM",
        expected_M2_P128K_CR8K_V,
    );
}
