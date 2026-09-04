# Third-party test ROMs: Blargg's `ppu_vbl_nmi`

## `rom_singles/*.nes` (10 files)

Source: **`ppu_vbl_nmi`**, one of the standard Blargg (Shay Green,
`gblargg@gmail.com`) NES PPU diagnostic suites, via the NESdev-wiki-endorsed
mirror [`christopherpow/nes-test-roms`](https://github.com/christopherpow/nes-test-roms).

The suite's combined `ppu_vbl_nmi/ppu_vbl_nmi.nes` (an interactive, all-10-in-
one ROM for running under a real console or full-featured emulator) is
**mapper 1 (MMC1)** — confirmed by its iNES header (`flags6 = 0x11`, 256KB
PRG) — which this codebase cannot run (only mapper 0/NROM exists through
M2). The suite also ships each of its 10 individual checks as a **standalone
mapper-0/NROM ROM** under `rom_singles/`, each independently confirmed via
its iNES header (`flags6 = 0x01`: mapper low nibble 0, vertical mirroring;
`flags7 = 0x00`; 32KB PRG + 8KB CHR-ROM, 40,976 bytes) before vendoring here.
These are what this milestone gates on.

Downloaded, unmodified, from:

| File | Source URL | Size |
|---|---|---|
| `01-vbl_basics.nes` | `.../ppu_vbl_nmi/rom_singles/01-vbl_basics.nes` | 40,976 bytes |
| `02-vbl_set_time.nes` | `.../ppu_vbl_nmi/rom_singles/02-vbl_set_time.nes` | 40,976 bytes |
| `03-vbl_clear_time.nes` | `.../ppu_vbl_nmi/rom_singles/03-vbl_clear_time.nes` | 40,976 bytes |
| `04-nmi_control.nes` | `.../ppu_vbl_nmi/rom_singles/04-nmi_control.nes` | 40,976 bytes |
| `05-nmi_timing.nes` | `.../ppu_vbl_nmi/rom_singles/05-nmi_timing.nes` | 40,976 bytes |
| `06-suppression.nes` | `.../ppu_vbl_nmi/rom_singles/06-suppression.nes` | 40,976 bytes |
| `07-nmi_on_timing.nes` | `.../ppu_vbl_nmi/rom_singles/07-nmi_on_timing.nes` | 40,976 bytes |
| `08-nmi_off_timing.nes` | `.../ppu_vbl_nmi/rom_singles/08-nmi_off_timing.nes` | 40,976 bytes |
| `09-even_odd_frames.nes` | `.../ppu_vbl_nmi/rom_singles/09-even_odd_frames.nes` | 40,976 bytes |
| `10-even_odd_timing.nes` | `.../ppu_vbl_nmi/rom_singles/10-even_odd_timing.nes` | 40,976 bytes |

(each `...` is `https://raw.githubusercontent.com/christopherpow/nes-test-roms/master`)

**No explicit license or copyright statement accompanies any of these
files**, same posture as nestest (see
[`core/tests/roms/nestest/ATTRIBUTION.md`](../nestest/ATTRIBUTION.md)) and
the research backing both:
[`docs/research/test-rom-licensing.md`](../../../../docs/research/test-rom-licensing.md)
(ENG-59). Blargg's suites ship a `readme.txt` that documents behavior and
credits the author (`Shay Green <gblargg@gmail.com>`) but states no
copyright or license line; the hosting mirror itself has no `LICENSE` file
and GitHub reports `license: null`. There is no copyleft, non-commercial, or
no-redistribution term to conflict with this repo's MIT license — the issue
is the *absence* of a grant, not a restrictive one — and 20+ years of
unchallenged mirroring by essentially every emulator project (Mesen, FCEUX,
puNES, and this very mirror) supports treating it as freely redistributable
community practice. Vendored here on that same **"no formal grant found;
believed freely redistributable per longstanding NES-emulator-community
practice"** posture, not a stronger claim.

**How they are used:** `core/src/ppu_vbl_nmi_test.zig` embeds each ROM at
build time (via anonymous imports declared in `core/build.zig`) and runs it
against the standard Blargg `$6000` status-byte protocol (documented in
`docs/research/test-rom-licensing.md`: status at `$6000`, signature `$DE
$B0 $61` at `$6001-$6003`, null-terminated ASCII status text from `$6004`),
including the `$81` ("needs a reset, delayed ≥100ms") reset-and-continue
step some sub-tests require. Native test binary only — `zig build wasm`
never sees this data, exactly like nestest's fixtures.

8 of the 10 sub-tests pass outright. The remaining 2
(`07-nmi_on_timing`, `10-even_odd_timing`) hit the same documented,
understood architectural gap — see the doc comments directly above each of
their `test` blocks in `ppu_vbl_nmi_test.zig` for the full derivation — and
are asserted against their known (non-`$00`) result code rather than
silently skipped, so a change to their failure shape fails the suite for
real instead of masking a regression.
