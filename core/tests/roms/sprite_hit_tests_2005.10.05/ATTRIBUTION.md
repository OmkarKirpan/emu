# Third-party test ROMs: Blargg's `sprite_hit_tests_2005.10.05`

Source: **`sprite_hit_tests_2005.10.05`**, one of the standard Blargg (Shay
Green, `gblargg@gmail.com`) NES PPU diagnostic suites, via the
NESdev-wiki-endorsed mirror
[`christopherpow/nes-test-roms`](https://github.com/christopherpow/nes-test-roms).
Tests sprite-0 hit behavior — the specific target of this suite among
ENG-68's acceptance criteria ("PPU sprite/OAM conformance stage").

All 11 ROMs confirmed mapper 0/NROM via their iNES headers (`flags6 =
0x00`, `flags7 = 0x00`; 16KB PRG, 0 CHR banks — CHR-RAM, populated by the
ROM's own code at boot; 16,400 bytes each) before vendoring here.

| File | Source URL |
|---|---|
| `01.basics.nes` | `.../sprite_hit_tests_2005.10.05/01.basics.nes` |
| `02.alignment.nes` | `.../sprite_hit_tests_2005.10.05/02.alignment.nes` |
| `03.corners.nes` | `.../sprite_hit_tests_2005.10.05/03.corners.nes` |
| `04.flip.nes` | `.../sprite_hit_tests_2005.10.05/04.flip.nes` |
| `05.left_clip.nes` | `.../sprite_hit_tests_2005.10.05/05.left_clip.nes` |
| `06.right_edge.nes` | `.../sprite_hit_tests_2005.10.05/06.right_edge.nes` |
| `07.screen_bottom.nes` | `.../sprite_hit_tests_2005.10.05/07.screen_bottom.nes` |
| `08.double_height.nes` | `.../sprite_hit_tests_2005.10.05/08.double_height.nes` |
| `09.timing_basics.nes` | `.../sprite_hit_tests_2005.10.05/09.timing_basics.nes` |
| `10.timing_order.nes` | `.../sprite_hit_tests_2005.10.05/10.timing_order.nes` |
| `11.edge_timing.nes` | `.../sprite_hit_tests_2005.10.05/11.edge_timing.nes` |

(each `...` is `https://raw.githubusercontent.com/christopherpow/nes-test-roms/master`)

**No explicit license or copyright statement accompanies any of these
files**, same posture as every other vendored Blargg/Kevtris ROM in this
tree; see
[`core/tests/roms/nestest/ATTRIBUTION.md`](../nestest/ATTRIBUTION.md) and
[`docs/research/test-rom-licensing.md`](../../../../docs/research/test-rom-licensing.md)
(ENG-59).

**Result protocol — not the `$6000` convention.** Unlike `ppu_vbl_nmi`,
`oam_read`, and `oam_stress`, this (older, 2005-vintage) suite predates
Blargg's `$6000`-status-byte convention: no `$DE $B0 $61` signature appears
anywhere in these binaries (confirmed by searching each file's raw bytes).
Instead, each ROM writes its result as plain, human-readable ASCII text
directly into nametable 0 via ordinary `$2007` writes — confirmed by running
one of these ROMs against this codebase's own (already-correct, from M2)
background-rendering pipeline and observing literal `"PASSED"` /
`"FAILED #<code>"` text land byte-for-byte in `Ppu.vram`, with tile ID
equal to ASCII code. `core/src/ppu_sprites_test.zig`'s harness scans
`Ppu.vram` for these two literal substrings instead of polling `$6000`.

**Why this suite is in scope for ENG-68 despite testing sprites, which the
`$6000` protocol suites (`oam_read`/`oam_stress`) do not.** This is the
suite ENG-68's own acceptance criterion ("PPU sprite/OAM conformance stage")
names sprite-0 hit as covering.
