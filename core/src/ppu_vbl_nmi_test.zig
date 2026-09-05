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
//! The shared `$6000`-protocol polling/reset-handling logic (`Machine`,
//! `expectPass`, `expectKnownGap`) now lives in `blargg_harness.zig`,
//! factored out here when `ppu_sprites_test.zig` (ENG-68) needed the exact
//! same logic for `oam_read`/`oam_stress`.

const determinism = @import("determinism.zig");
const harness = @import("blargg_harness.zig");
const expectPass = harness.expectPass;
const expectKnownGap = harness.expectKnownGap;

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
// 07-nmi_on_timing: a documented, understood gap -- see the doc comment
// below. 08-nmi_off_timing, its mirror-image test (disabling NMI near the
// VBL *set* rather than enabling it near the VBL *clear*), passes outright,
// which is what pins the gap down to this specific direction rather than to
// NMI edge-timing in general.
//
// `Cpu.read` and `Cpu.write` are structurally identical in their access
// ordering -- both call `tick()` (3 PPU dots per cycle, with a single NMI
// poll wedged after the first of the 3) *before* touching the bus, then poll
// once more *after* the access -- see the doc comments on `Cpu.tick`,
// `Cpu.read`/`Cpu.write`, and `Cpu.nmi_ready`. That single mid-tick poll
// point is what gives `06-suppression`, `08-nmi_off_timing`, and the
// dispatch-delay behavior `04-nmi_control`/`05-nmi_timing` check real
// single-PPU-dot precision for the *level* they each sample there (the VBL
// flag, gated by PPUCTRL's NMI-enable bit) -- verified by writing out the
// R-vs-D (read-dot vs. set-dot) case analysis for all three within-a-cycle
// alignments and confirming each matches the NESdev-documented suppression
// window exactly.
//
// `07-nmi_on_timing` needs the *opposite* comparison: whether a WRITE
// (enabling NMI) landed before or after the VBL flag's *clear* at
// (scanline 261, dot 1). Because a write's own bus effect in this milestone
// always applies only after that cycle's 3 PPU dots have already run, a
// clear landing on *any* of those 3 dots is indistinguishable from the
// write's point of view -- all three collapse to "the clear already
// happened", one PPU-dot-alignment more than Blargg's ROM expects (it wants
// exactly one of those three to still read as "before the clear"). This was
// confirmed empirically, not assumed: forcing the write to apply *before*
// its cycle's own dots (so it can plainly see whichever PPU state came
// immediately before) makes every row fire instead of the expected 5-of-9,
// and forcing it to apply after only the first dot shifts the boundary the
// wrong way and regresses 08. Resolving this for real needs a write's bus
// effect to be positionable at a specific *sub-cycle* (single-PPU-dot)
// point relative to the PPU's own event -- i.e. genuinely interleaved
// per-dot CPU/PPU co-simulation, not "3 ticks, then one bus access" -- which
// is a real architectural step up, not a local bug fix, and is deliberately
// out of scope for M2's "drive the PPU off the CPU's existing tick
// chokepoint" integration. Measured: rows 0-4 read "N" (fires) as expected;
// row 5 also reads "N" where Blargg's ROM expects "-" (does not fire) --
// exactly the one-row/one-PPU-dot shift this analysis predicts, and no
// wider than that.
test "ppu_vbl_nmi 07-nmi_on_timing (documented gap: write-vs-VBL-clear needs sub-CPU-cycle precision this milestone's CPU/PPU integration does not have)" {
    try expectKnownGap("ppu_vbl_nmi/07-nmi_on_timing", @embedFile("07-nmi_on_timing"), 0x01);
}
test "ppu_vbl_nmi 08-nmi_off_timing" {
    try expectPass("ppu_vbl_nmi/08-nmi_off_timing", @embedFile("08-nmi_off_timing"));
}
test "ppu_vbl_nmi 09-even_odd_frames" {
    try expectPass("ppu_vbl_nmi/09-even_odd_frames", @embedFile("09-even_odd_frames"));
}

// 10-even_odd_timing: the same underlying gap as 07, applied to PPUMASK
// instead of PPUCTRL -- it probes exactly when a write enabling/disabling
// background rendering becomes visible to the odd-frame dot-skip decision
// (`Ppu.advanceDot`, scanline 261 dot 339), which is a plain level check,
// not edge-triggered, so the NMI-specific mid-cycle poll that fixes
// `06`/`08` has no analogue here. Same root cause, same fix needed
// (sub-CPU-cycle write timing); see 07's doc comment for the full
// derivation. Measured: the ROM's own first two sub-checks (dot-skip count
// for a sequence of enable/disable transitions) pass; it fails specifically
// at "Clock is skipped too late, relative to enabling BG" -- the identical
// one-PPU-dot-late shape as 07, not a different or wider divergence.
test "ppu_vbl_nmi 10-even_odd_timing (documented gap: same root cause as 07, for PPUMASK/odd-frame-skip)" {
    try expectKnownGap("ppu_vbl_nmi/10-even_odd_timing", @embedFile("10-even_odd_timing"), 0x03);
}

// `assert_deterministic` (ENG-65), wired into this stage per ENG-66's
// acceptance criterion 3: two power-on runs of the same ROM, for the same
// fixed cycle budget, must hash identically. See `determinism.zig` for what
// the hash actually covers and why.
test "assertDeterministic: two power-on runs of vbl_basics hash identically" {
    try determinism.assertDeterministic(@embedFile("01-vbl_basics"), 200_000);
}
