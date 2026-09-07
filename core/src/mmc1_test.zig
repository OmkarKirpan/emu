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
//! ## Why the expected codes are not all zero
//!
//! holy-mapperel's result is four hex digits — WRAM, PRG, IRQ, CHR — and it
//! tests two things M7a deliberately does not implement:
//!
//!   * MMC1's **PRG-RAM disable bit** ($E000 bit 4, and the SNROM $A000
//!     variant). `Bus` maps $6000-$7FFF as unconditional WRAM by an explicit
//!     decision, and the vendored ROM harness's `$6000` status protocol
//!     depends on that. Filed as ENG-79.
//!   * **SXROM's banked 32KB WRAM**, which additionally needs the NES 2.0
//!     PRG-RAM size field `rom.zig` does not parse.
//!
//! So the WRAM digit is expected to be nonzero, and the exact value is
//! asserted rather than skipped: a digit nobody asserts is a digit that can
//! regress in silence. Closing ENG-79 should lower these codes, and that is
//! the point — the expectation is a live record of a known gap, not a
//! tolerance.

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
// The four digits are WRAM, PRG ROM, IRQ, CHR.
//
//   * **PRG is 0 on all three**, 512KB SUROM included: every banking mode
//     maps every bank where it should.
//   * **IRQ is 0**: MMC1 has no IRQ line.
//   * **CHR is 0**: 8KB and 4KB modes over both CHR-ROM and CHR-RAM. It read
//     3 on the CHR-RAM boards until `Mmc1.chrOffset` stopped treating 8KB
//     CHR-RAM as unbanked -- in 4KB mode the bank registers still pick which
//     half each window shows.
//   * **WRAM is nonzero, deliberately.** It is the PRG-RAM disable bit,
//     deferred to ENG-79 because honoring it means routing $6000-$7FFF
//     through `Mapper`. Per holy-mapperel's README, 1 means "$E000 bit 4
//     does not disable WRAM" and 4 means the SNROM "$A000 bit 4" case -- so
//     the SNROM board reports 5 (= 1|4) and the other two report 1.
//
// Closing ENG-79 should drop all three to 0. These values are a live record
// of a known gap, not a tolerance for one: asserting the whole code means
// the gap cannot silently widen.
const expected_M1_P128K_CR8K: u16 = 0x5000;
const expected_M1_P128K_C128K: u16 = 0x1000;
const expected_M1_P512K_CR8K_S8K: u16 = 0x1000;

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

// ------------------------------------------- combined ppu_vbl_nmi (secondary)

test "ppu_vbl_nmi combined ROM (mapper 1, 256KB PRG)" {
    try blargg.expectPass("ppu_vbl_nmi (combined)", @embedFile("ppu_vbl_nmi_combined"));
}
