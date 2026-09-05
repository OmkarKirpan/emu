# Third-party test ROMs: Blargg's `sprite_overflow_tests`

Source: **`sprite_overflow_tests`**, one of the standard Blargg (Shay Green,
`gblargg@gmail.com`) NES PPU diagnostic suites, via the NESdev-wiki-endorsed
mirror
[`christopherpow/nes-test-roms`](https://github.com/christopherpow/nes-test-roms).
Tests the sprite-overflow flag (bit 5 of $2002), including its documented
hardware "diagonal read" bug — see `Ppu.evaluateSprites`'s doc comment.

All 5 ROMs confirmed mapper 0/NROM via their iNES headers (`flags6 = 0x00`,
`flags7 = 0x00`; 16KB PRG, 0 CHR banks — CHR-RAM, populated by the ROM's own
code at boot; 16,400 bytes each) before vendoring here.

| File | Source URL |
|---|---|
| `1.Basics.nes` | `.../sprite_overflow_tests/1.Basics.nes` |
| `2.Details.nes` | `.../sprite_overflow_tests/2.Details.nes` |
| `3.Timing.nes` | `.../sprite_overflow_tests/3.Timing.nes` |
| `4.Obscure.nes` | `.../sprite_overflow_tests/4.Obscure.nes` |
| `5.Emulator.nes` | `.../sprite_overflow_tests/5.Emulator.nes` |

(each `...` is `https://raw.githubusercontent.com/christopherpow/nes-test-roms/master`)

**No explicit license or copyright statement accompanies any of these
files**, same posture as every other vendored Blargg/Kevtris ROM in this
tree; see
[`core/tests/roms/nestest/ATTRIBUTION.md`](../nestest/ATTRIBUTION.md) and
[`docs/research/test-rom-licensing.md`](../../../../docs/research/test-rom-licensing.md)
(ENG-59).

**Result protocol — not the `$6000` convention.** Like
`sprite_hit_tests_2005.10.05` (same 2005-era vintage), these ROMs predate
Blargg's `$6000`-status-byte convention and instead write plain ASCII
`"PASSED"` / `"FAILED: #<code>"` text directly into nametable 0. See that
suite's `ATTRIBUTION.md` for how this was confirmed and how the harness
(`core/src/ppu_sprites_test.zig`) detects it.

**Must run in order.** The suite's own `readme.txt` states later ROMs
assume earlier ones already pass — `3.Timing`, `4.Obscure`, and
`5.Emulator` in particular probe increasingly fine-grained edge cases of
the same overflow-detection logic `1.Basics`/`2.Details` establish. All
five pass. `3.Timing` was a documented, asserted gap when this stage first
landed, because sprite evaluation ran at the dot 1 of the scanline being
drawn instead of one scanline ahead on hardware's dots 65-256 schedule;
`Ppu.evaluateSprites` now does the latter, and costs out two dots per OAM
byte so the overflow flag lands on the dot hardware lands it on.
