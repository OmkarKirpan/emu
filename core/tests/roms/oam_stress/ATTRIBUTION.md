# Third-party test ROM: Blargg's `oam_stress`

Source: **`oam_stress`**, one of the standard Blargg (Shay Green,
`gblargg@gmail.com`) NES PPU diagnostic suites, via the NESdev-wiki-endorsed
mirror [`christopherpow/nes-test-roms`](https://github.com/christopherpow/nes-test-roms).

Confirmed mapper 0/NROM via its iNES header (`flags6 = 0x01`, `flags7 =
0x00`; 32KB PRG + 8KB CHR-ROM, 40,976 bytes) before vendoring here.

Downloaded, unmodified, from
`https://raw.githubusercontent.com/christopherpow/nes-test-roms/master/oam_stress/oam_stress.nes`.

**No explicit license or copyright statement accompanies this file** — same
posture as every other vendored Blargg/Kevtris ROM in this tree; see
[`core/tests/roms/nestest/ATTRIBUTION.md`](../nestest/ATTRIBUTION.md) and
[`docs/research/test-rom-licensing.md`](../../../../docs/research/test-rom-licensing.md)
(ENG-59).

**How it is used:** `core/src/ppu_sprites_test.zig` embeds this ROM at build
time and runs it against the standard Blargg `$6000` status-byte protocol,
exactly like `ppu_vbl_nmi`'s fixtures. Randomly stress-tests OAMADDR
($2003)/OAMDATA ($2004) read/write semantics for tens of seconds of emulated
NES time; the harness's cycle budget is sized generously for that. Native
test binary only — `zig build wasm` never sees this data.
