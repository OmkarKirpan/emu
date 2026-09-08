//! MMC3 (mapper 4) conformance stage — M7d (ENG-75), per ENG-64's staged
//! test-ROM architecture. Structured exactly like `mmc1_test.zig`; see that
//! file's doc comment for why holy-mapperel is the primary gate here and
//! what its four-digit result code means.
//!
//! Only holy-mapperel runs for MMC3 -- there is no MMC3-banked
//! `ppu_vbl_nmi` combined ROM the way M7a had for MMC1, so the "real
//! workload" secondary gate that file describes has no MMC3 counterpart.
//!
//! ## ENG-79: the WRAM digit dropped from 2 to 1, and stops there
//!
//! Through M7d, this reported `2xxx`: MMC3's PRG-RAM protect bit ($A001 bit
//! 6, holy-mapperel's own README: `Mapper 004 2xxx: Read-only mode not
//! present`) was accepted and ignored, because honoring it meant routing
//! $6000-$7FFF through `Mapper`, which `Bus` mapped as unconditional WRAM by
//! an explicit decision. As of ENG-79
//! (`docs/adr/0005-cartridge-owns-its-memory.md`), `Mmc3` owns that window
//! and honors bit 6 (`Mmc3.prgRamWrite`'s write-protect check) -- **the `2`
//! bit is gone.**
//!
//! **A `1` remains, and it is not the same gap.** Bit 7 of $A001 is PRG-RAM
//! chip *enable* -- a second, independent capability from the write-protect
//! bit 6 this milestone implements. It is deliberately not modeled: per
//! nesdev.org's MMC3 page, "though these bits are functional on the MMC3,
//! their main purpose is to write-protect save RAM during power-off. Many
//! emulators choose not to implement them as part of iNES Mapper 4 to avoid
//! an incompatibility with the MMC6" -- a real board-compatibility hazard,
//! not an oversight here. holy-mapperel's WRAM test evidently probes this
//! bit the same way it probes MMC1's $E000 disable bit (both report as the
//! `1` position), and `Mmc3.prgRamRead` never returns `null` because of it
//! -- see `mapper.zig`'s `Mmc3` doc comment. `2` is fixed; `1` is a
//! documented, deliberate non-goal, same footing as the "alternate
//! revision" MMC3 IRQ behavior ADR 0004 already declined to model.
//!
//! **The IRQ digit is 0 on both ROMs, but it did not start that way.** MMC3
//! is the first mapper in this project whose IRQ digit can be anything
//! other than zero for a real reason, and the first run against these two
//! ROMs came back `2010` -- IRQ nonzero. The cause was not `Mmc3` itself:
//! `Ppu.fetchSpriteUnits` only fetched pattern bytes for sprites
//! `evaluateSprites` actually found in range, skipping the fetch entirely
//! on a scanline with none. That was invisible to every test before this
//! milestone (nothing reads a discarded pixel), but holy-mapperel's MMC3 IRQ
//! test enables only the background layer, so its scanlines have zero
//! sprites in range -- meaning A12 never rose at all, and the counter never
//! moved. Real hardware always performs exactly 8 sprite pattern-fetch
//! pairs a scanline, sprites present or not; `fetchSpriteUnits` now does the
//! same (see its doc comment in `ppu.zig`), and the IRQ digit reads 0.

const std = @import("std");

const mapperel = @import("mapperel_harness.zig");

// The four digits are WRAM, PRG ROM, IRQ, CHR.
//
//   * **PRG is 0 on both**: every PRG banking mode maps every 8KB window
//     where it should.
//   * **IRQ is 0 on both**: the scanline counter reloads, decrements, and
//     fires at the documented times -- see the module doc comment for the
//     `Ppu.fetchSpriteUnits` bug this digit caught before it was 0.
//   * **CHR is 0 on the CHR-ROM board** (1KB/2KB banking in both CHR-A12
//     modes, the whole point of vendoring this ROM over a CHR-RAM-only one)
//     **and 0 on the CHR-RAM board** too.
//   * **WRAM is `1`, deliberately** -- $A001 bit 7 (PRG-RAM chip enable),
//     not the write-protect bit ENG-79 implemented. See the module doc
//     comment for why this one stays unmodeled (the documented MMC6
//     incompatibility real emulators cite for skipping it).
const expected_M4_P256K_C256K: u16 = 0x1000;
const expected_M4_P128K_CR8K: u16 = 0x1000;

test "holy-mapperel M4_P256K_C256K (256KB PRG, 256KB CHR-ROM)" {
    try mapperel.expectResult(
        "M4_P256K_C256K",
        @embedFile("mapperel_M4_P256K_C256K"),
        "TSROM (MMC3)",
        expected_M4_P256K_C256K,
    );
}

test "holy-mapperel M4_P128K_CR8K (128KB PRG, 8KB CHR-RAM)" {
    try mapperel.expectResult(
        "M4_P128K_CR8K",
        @embedFile("mapperel_M4_P128K_CR8K"),
        "TNROM (MMC3)",
        expected_M4_P128K_CR8K,
    );
}
