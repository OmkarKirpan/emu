//! Blargg's `ppu_vbl_nmi` conformance suite (ENG-66 acceptance criterion 1).
//!
//! The combined `ppu_vbl_nmi.nes` is mapper 1 (MMC1), which this codebase
//! cannot run (only mapper 0/NROM exists). Instead this vendors the 10
//! individual `rom_singles/NN-*.nes` ROMs, each independently confirmed
//! mapper 0 -- 32KB PRG, 8KB CHR-ROM, vertical mirroring, 40,976 bytes. See
//! `core/tests/roms/ppu_vbl_nmi/ATTRIBUTION.md`.
//!
//! **Protocol** (Blargg's standard `$6000` convention, common to every suite
//! of his; see `docs/research/test-rom-licensing.md`, researched for ENG-59):
//! a live test first writes the signature `$DE $B0 $61` to `$6001-$6003`
//! (the readme's own `$G1` is a documented typo for `$61`). `$6000` then
//! carries status: `$80` = still running, `$81` = "needs the reset button
//! pressed, but delayed by at least 100 msec from now", `$00`-`$7F` = done,
//! with that value as the result code (`$00` = pass). Null-terminated ASCII
//! detail text starts at `$6004`.
//!
//! **Why `$6000` even works on NROM.** See `bus.zig`'s doc comment: these
//! ROMs need real, writable RAM at `$6000-$7FFF` to hand back a result at
//! all, which is why `Bus` gives every cartridge unconditional 8KB PRG-RAM
//! there rather than gating it behind a mapper capability NROM doesn't have.
//!
//! **Why all 10 are in scope, not just VBL-flag ones.** `09-even_odd_frames`
//! and `10-even_odd_timing` test the odd-frame dot skip, which sounds
//! sprite-adjacent but is not: it is purely a function of the PPU's own
//! dot/scanline counter and whether *background* rendering is enabled, and
//! it is exactly the mechanism that lets `06-suppression` and its neighbors
//! probe "one PPU clock later" timings at all (see `ppu.zig`'s
//! `advanceDot` and its test coverage) -- none of the 10 sub-tests here
//! depend on sprite rendering (ENG-68, M3), which was not implemented yet
//! when this suite was first wired up.
//!
//! **All 10 sub-tests pass.** `07-nmi_on_timing` and `10-even_odd_timing`
//! were documented, asserted gaps through M2 and M3 -- both fixed by giving
//! PPUCTRL/PPUMASK writes the one-dot latch delay real hardware has; see
//! `Ppu.applyPendingLatches` and `Cpu.write`.
//!
//! The shared `$6000`-protocol polling/reset-handling logic (`Machine`,
//! `expectPass`, `expectKnownGap`) lives in `blargg_harness.zig`,
//! factored out here when `ppu_sprites_test.zig` (ENG-68) needed the exact
//! same logic for `oam_read`/`oam_stress`.

const determinism = @import("determinism.zig");
const harness = @import("blargg_harness.zig");
const expectPass = harness.expectPass;

test "ppu_vbl_nmi 01-vbl_basics" {
    try expectPass("ppu_vbl_nmi/01-vbl_basics", @embedFile("01-vbl_basics"));
}
test "ppu_vbl_nmi 02-vbl_set_time" {
    try expectPass("ppu_vbl_nmi/02-vbl_set_time", @embedFile("02-vbl_set_time"));
}
test "ppu_vbl_nmi 03-vbl_clear_time" {
    try expectPass("ppu_vbl_nmi/03-vbl_clear_time", @embedFile("03-vbl_clear_time"));
}
test "ppu_vbl_nmi 04-nmi_control" {
    try expectPass("ppu_vbl_nmi/04-nmi_control", @embedFile("04-nmi_control"));
}
test "ppu_vbl_nmi 05-nmi_timing" {
    try expectPass("ppu_vbl_nmi/05-nmi_timing", @embedFile("05-nmi_timing"));
}
test "ppu_vbl_nmi 06-suppression" {
    try expectPass("ppu_vbl_nmi/06-suppression", @embedFile("06-suppression"));
}
// 07 and 08 are mirror images: 08 disables NMI near the VBL flag's *set*,
// 07 enables it near the VBL flag's *clear*. Both now pass, but only
// together, and only because of the one-dot PPUCTRL/PPUMASK latch delay
// modeled in `Ppu.applyPendingLatches` plus its `Cpu.write` counterpart
// (no NMI poll at the end of a write cycle) -- see both doc comments. 07
// was a documented, asserted gap through M2 and M3: with the write landing
// a dot too early, its row 5 fired where hardware does not.
test "ppu_vbl_nmi 07-nmi_on_timing" {
    try expectPass("ppu_vbl_nmi/07-nmi_on_timing", @embedFile("07-nmi_on_timing"));
}
test "ppu_vbl_nmi 08-nmi_off_timing" {
    try expectPass("ppu_vbl_nmi/08-nmi_off_timing", @embedFile("08-nmi_off_timing"));
}
test "ppu_vbl_nmi 09-even_odd_frames" {
    try expectPass("ppu_vbl_nmi/09-even_odd_frames", @embedFile("09-even_odd_frames"));
}

// 10-even_odd_timing probes the same one-dot write-visibility question as
// 07, but through PPUMASK rather than PPUCTRL: exactly when a write
// enabling/disabling background rendering becomes visible to the odd-frame
// dot-skip decision (`Ppu.advanceDot`, scanline 261 dot 339). That is a
// plain level check, with no NMI edge involved at all, which is what makes
// it the cleaner of the two demonstrations that the fix is really about
// *when the PPU latches the written byte* and not about NMI polling: it
// passes on the latch delay alone.
test "ppu_vbl_nmi 10-even_odd_timing" {
    try expectPass("ppu_vbl_nmi/10-even_odd_timing", @embedFile("10-even_odd_timing"));
}

// `assert_deterministic` (ENG-65), wired into this stage per ENG-66's
// acceptance criterion 3: two power-on runs of the same ROM, for the same
// fixed cycle budget, must hash identically. See `determinism.zig` for what
// the hash actually covers and why.
test "assertDeterministic: two power-on runs of vbl_basics hash identically" {
    try determinism.assertDeterministic(@embedFile("01-vbl_basics"), 200_000);
}
