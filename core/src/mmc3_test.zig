//! MMC3 (mapper 4) conformance stage — M7d (ENG-75), per ENG-64's staged
//! test-ROM architecture. Structured exactly like `mmc1_test.zig`; see that
//! file's doc comment for why holy-mapperel is the primary gate here and
//! what its four-digit result code means.
//!
//! Only holy-mapperel runs for MMC3 -- there is no MMC3-banked
//! `ppu_vbl_nmi` combined ROM the way M7a had for MMC1, so the "real
//! workload" secondary gate that file describes has no MMC3 counterpart.
//!
//! ## Why the expected codes are not all zero
//!
//! Same shape as MMC1's gap (ENG-79), different register: MMC3's PRG-RAM
//! protect bit ($A001, out of `Mmc3`'s scope -- see its doc comment in
//! `mapper.zig`) is not honored, because honoring it means routing
//! $6000-$7FFF through `Mapper`, which `Bus` maps as unconditional WRAM by
//! an explicit decision the vendored ROM harness's own `$6000` status
//! protocol depends on. So the WRAM digit is expected to be nonzero here
//! too, and asserted exactly rather than skipped. holy-mapperel's own
//! README documents this exact code (`Mapper 004 2xxx: Read-only mode not
//! present`) and separately warns that "in iNES format environments that
//! don't support NES 2.0" -- which is what `rom.zig` is, deliberately, per
//! `core/tests/roms/holy_mapperel/ATTRIBUTION.md` -- "the MMC3 test will
//! return a warning about lack of write protection on WRAM." That is
//! precisely what digit `2` is: not a bug, the documented iNES-vs-NES-2.0
//! gap this suite's own author anticipated.
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
//   * **WRAM is `2`, deliberately** -- the PRG-RAM protect bit ($A001),
//     deferred alongside ENG-79 for the reason `Mmc3`'s doc comment gives.
//     Per holy-mapperel's README this is "Mapper 004 2xxx: Read-only mode
//     not present," and separately documented as the expected result in an
//     iNES-only (non-NES-2.0) environment, which this one is.
const expected_M4_P256K_C256K: u16 = 0x2000;
const expected_M4_P128K_CR8K: u16 = 0x2000;

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
