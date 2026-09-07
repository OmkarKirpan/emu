//! CNROM (mapper 3) conformance stage — M7c (ENG-74), per ENG-64's staged
//! test-ROM architecture.
//!
//! One ROM, unlike MMC1's three: CNROM has one shape worth gating on (a
//! fixed 32KB PRG board with the maximum 32KB of switchable CHR-ROM) rather
//! than several boards to distinguish, so `M3_P32K_C32K_H` — 32KB PRG, 32KB
//! CHR-ROM, horizontal mirroring — is the whole suite. See
//! `mapperel_harness.zig` for how the result is read off the screen and
//! `core/tests/roms/holy_mapperel/ATTRIBUTION.md` for the vendoring record.
//!
//! ## The $6000-$7FFF WRAM question, and why the result is still 0
//!
//! `Bus` maps $6000-$7FFF as unconditional 8KB WRAM by an explicit decision
//! (see `bus.zig`'s type doc comment) regardless of what a given cartridge
//! board actually wires up there. Real CNROM boards have **no PRG-RAM at
//! all**, so it was reasonable to expect this ROM's WRAM probe to flag
//! memory a real CNROM cartridge would not have -- the same shape of gap
//! ENG-79 already tracks for MMC1, just on a board with no disable register
//! at all rather than one whose disable bit goes unhonored.
//!
//! That did not happen. Run against this core the ROM reports:
//!
//!     003 CNROM
//!     32K PRG ROM
//!     8K PRG RAM OK
//!     32K CHR ROM OK
//!     DETAILED TEST RESULT: 0000
//!
//! It measures and exercises 8KB of WRAM ("OK" = it read back what it wrote)
//! but the detailed WRAM digit stays 0. Unlike the MMC1 ROMs -- which know a
//! specific disable *bit* exists and specifically test whether asserting it
//! actually stops WRAM from responding -- CNROM has no such register for
//! the ROM to probe in the first place, so its WRAM test has nothing to
//! compare "present" against and simply confirms the RAM it finds behaves
//! like RAM. `Bus`'s unconditional $6000-$7FFF window satisfies that
//! completely, because real hardware would too if this board happened to
//! have WRAM wired up -- iNES/NES 2.0 carry a separate PRG-RAM-size field
//! for exactly that per-board variability (see `bus.zig`), and this test
//! ROM does not encode an expectation either way for CNROM specifically.
//! So the ENG-79 gap is real and unresolved, but this particular ROM is not
//! the instrument that would catch it on a CNROM board; a CNROM ROM relying
//! on $6000-$7FFF being *absent* (open bus, not RAM) would need a different
//! test to surface the difference.
//!
//! PRG, IRQ, and CHR are 0 too: fixed-PRG banking, no IRQ line, and 8KB-
//! window CHR-ROM bank switching all check out across every bank this 32KB
//! board can select. The full detailed code is `0000` -- read directly off
//! the harness's screen dump above, not assumed, and still asserted
//! (instead of just checked for board detection) so a future regression
//! cannot go silent.

const mapperel = @import("mapperel_harness.zig");

const expected_M3_P32K_C32K_H: u16 = 0x0000;

test "holy-mapperel M3_P32K_C32K_H (32KB PRG, 32KB CHR-ROM, horizontal mirroring)" {
    try mapperel.expectResult(
        "M3_P32K_C32K_H",
        @embedFile("mapperel_M3_P32K_C32K_H"),
        "003 CNROM",
        expected_M3_P32K_C32K_H,
    );
}
