# Third-party test ROM: Blargg's `oam_read`

Source: **`oam_read`**, one of the standard Blargg (Shay Green,
`gblargg@gmail.com`) NES PPU diagnostic suites, via the NESdev-wiki-endorsed
mirror [`christopherpow/nes-test-roms`](https://github.com/christopherpow/nes-test-roms).

Confirmed mapper 0/NROM via its iNES header (`flags6 = 0x01`: mapper low
nibble 0, vertical mirroring; `flags7 = 0x00`; 32KB PRG + 8KB CHR-ROM,
40,976 bytes) before vendoring here.

Downloaded, unmodified, from
`https://raw.githubusercontent.com/christopherpow/nes-test-roms/master/oam_read/oam_read.nes`.

**No explicit license or copyright statement accompanies this file**, same
posture as every other vendored Blargg/Kevtris ROM in this tree (see
[`core/tests/roms/nestest/ATTRIBUTION.md`](../nestest/ATTRIBUTION.md) and the
research backing all of them:
[`docs/research/test-rom-licensing.md`](../../../../docs/research/test-rom-licensing.md),
ENG-59). Vendored on that same **"no formal grant found; believed freely
redistributable per longstanding NES-emulator-community practice"** posture.

**How it is used:** `core/src/ppu_sprites_test.zig` embeds this ROM at build
time (via an anonymous import declared in `core/build.zig`) and runs it
against the standard Blargg `$6000` status-byte protocol (documented in
`docs/research/test-rom-licensing.md`), exactly like `ppu_vbl_nmi`'s
fixtures. Tests OAMDATA ($2004) reading back the byte at OAMADDR's current
address across all 256 OAM bytes. Native test binary only — `zig build wasm`
never sees this data.
