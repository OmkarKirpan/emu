//! MMC1 (mapper 1) conformance stage — M7a (ENG-72), per ENG-64's staged
//! test-ROM architecture.
//!
//! Two gates, deliberately different in kind:
//!
//!   * **holy-mapperel** (`mapperel_harness.zig`) is the purpose-built mapper
//!     test: it detects which mapper it is running on by writing to mirroring
//!     ports, measures PRG/CHR/WRAM sizes from bank tags, and steps every
//!     bank number through every window in every banking mode. Three ROMs
//!     cover the CHR-RAM baseline, CHR-ROM banking at maximum size, and the
//!     512KB SUROM PRG-A18 path. **zlib licensed**, unlike every other
//!     vendored suite here.
//!   * **The combined `ppu_vbl_nmi.nes`** is the real workload: a 256KB MMC1
//!     ROM that banks in each of ten PPU sub-tests. It speaks Blargg's
//!     `$6000` protocol, so it runs on the existing harness with no new code,
//!     and because all ten sub-tests already pass individually as NROM
//!     singles (`ppu_vbl_nmi_test.zig`), a failure here can only be the
//!     mapper.
//!
//! ## ENG-79/ENG-82: the WRAM digit dropped to 0000, all three boards
//!
//! Through M7a, all three ROMs reported a nonzero WRAM digit: MMC1's
//! PRG-RAM disable bit ($E000 bit 4, and the SNROM-specific $A000 variant)
//! was accepted and ignored, because honoring it meant routing $6000-$7FFF
//! through `Mapper`, which `Bus` mapped as unconditional WRAM by an explicit
//! decision (see its old doc comment, now superseded). As of ENG-79/ENG-82
//! (`docs/adr/0005-cartridge-owns-its-memory.md`), `Mmc1` owns that window
//! itself and honors both gates -- see `Mmc1.prgRamEnabled` and
//! `isSnromWramGate` in `mapper.zig` for exactly which board gets which
//! gate, and why SUROM/SKROM don't get the SNROM-only one. **All three ROMs
//! now report `0000`.** SXROM's banked 32KB WRAM (`Mmc1.prgRamOffset`,
//! selected through $A000 bits 2-3, sized from the NES 2.0 header's
//! PRG-RAM field) is also implemented, exercised below by the vendored
//! `M1_P512K_CR8K_S32K` ROM.

const std = @import("std");

const blargg = @import("blargg_harness.zig");
const mapperel = @import("mapperel_harness.zig");

// ------------------------------------------------- holy-mapperel (primary)

// Each test asserts the *board* name the ROM prints, not just "MMC1": the
// ROM narrows S*ROM down by what it finds attached (CHR-RAM plus WRAM =
// SNROM, CHR-ROM = SKROM, 512KB PRG = SUROM). That catches a detailed code
// that happens to be right because the ROM concluded it was running on
// something else entirely -- detection works by writing to mirroring ports
// and watching where nametable reads land, so it is a real assertion about
// this core, not a formality.
//
// The four digits are WRAM, PRG ROM, IRQ, CHR -- **all 0000, on all three
// boards.**
//
//   * **PRG is 0 on all three**, 512KB SUROM included: every banking mode
//     maps every bank where it should.
//   * **IRQ is 0**: MMC1 has no IRQ line.
//   * **CHR is 0**: 8KB and 4KB modes over both CHR-ROM and CHR-RAM. It read
//     3 on the CHR-RAM boards until `Mmc1.chrOffset` stopped treating 8KB
//     CHR-RAM as unbanked -- in 4KB mode the bank registers still pick which
//     half each window shows.
//   * **WRAM is 0.** Before ENG-79 this was nonzero on all three: 1 meant
//     "$E000 bit 4 does not disable WRAM" (every board) and 4 meant the
//     SNROM-specific "$A000 bit 4" case (SNROM only, so it alone reported
//     `5 = 1|4`). `Mmc1.prgRamEnabled` now honors both, and
//     `isSnromWramGate` derives exactly which boards get the SNROM-only
//     gate from existing geometry (CHR total, PRG size, PRG-RAM size)
//     rather than a submapper number the vendored ROMs don't carry -- see
//     `mapper.zig`.
const expected_M1_P128K_CR8K: u16 = 0x0000;
const expected_M1_P128K_C128K: u16 = 0x0000;
const expected_M1_P512K_CR8K_S8K: u16 = 0x0000;

test "holy-mapperel M1_P128K_CR8K (128KB PRG, 8KB CHR-RAM)" {
    try mapperel.expectResult(
        "M1_P128K_CR8K",
        @embedFile("mapperel_M1_P128K_CR8K"),
        "SNROM (MMC1)",
        expected_M1_P128K_CR8K,
    );
}

test "holy-mapperel M1_P128K_C128K (128KB PRG, 128KB CHR-ROM)" {
    try mapperel.expectResult(
        "M1_P128K_C128K",
        @embedFile("mapperel_M1_P128K_C128K"),
        "SKROM (MMC1)",
        expected_M1_P128K_C128K,
    );
}

test "holy-mapperel M1_P512K_CR8K_S8K (512KB SUROM, 8KB battery WRAM)" {
    try mapperel.expectResult(
        "M1_P512K_CR8K_S8K",
        @embedFile("mapperel_M1_P512K_CR8K_S8K"),
        "SUROM (MMC1)",
        expected_M1_P512K_CR8K_S8K,
    );
}

// SXROM: 512KB PRG (the same SUROM PRG-A18 path as the S8K board above) plus
// 32KB of *banked* battery WRAM -- byte 10 of this ROM's header is $90 (high
// nibble 9, `64 << 9 = 32768`), decoded by `Rom.parseHeader` (ENG-82) and
// wired into `Mmc1.prg_ram_size` by `Rom.createMapper`. Unvendorable before
// ENG-79/ENG-82 (`rom.zig` didn't parse bytes 10-11 at all, and `Mmc1` had
// no bank-select math for PRG-RAM) -- see `ATTRIBUTION.md`'s "A note on
// headers". WRAM is 0: both the standard $E000 disable and the four
// 8KB banks selected through $A000 bits 2-3 all check out.
const expected_M1_P512K_CR8K_S32K: u16 = 0x0000;

test "holy-mapperel M1_P512K_CR8K_S32K (512KB SXROM, 32KB banked WRAM)" {
    try mapperel.expectResult(
        "M1_P512K_CR8K_S32K",
        @embedFile("mapperel_M1_P512K_CR8K_S32K"),
        "SXROM (MMC1)",
        expected_M1_P512K_CR8K_S32K,
    );
}

// ------------------------------------------- combined ppu_vbl_nmi (secondary)

test "ppu_vbl_nmi combined ROM (mapper 1, 256KB PRG)" {
    try blargg.expectPass("ppu_vbl_nmi (combined)", @embedFile("ppu_vbl_nmi_combined"));
}
