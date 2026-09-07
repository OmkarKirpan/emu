# Third-party test ROMs: Holy Mapperel

## What these are

Six ROMs from **Holy Mapperel**, an NES cartridge PCB manufacturing test by
Damian Yerrick (tepples):
[`pinobatch/holy-mapperel`](https://github.com/pinobatch/holy-mapperel),
release **v0.02** (2018-09-29), extracted unmodified from that release's
`holy-mapperel-bin-0.02.7z` archive. Three are MMC1 (M7a, ENG-72), one is
UxROM (M7b, ENG-73), and two are MMC3 (M7d, ENG-75).

| File | Size | Board | What it reaches here |
|---|---|---|---|
| `M1_P128K_CR8K.nes` | 131,088 | SNROM | 128KB PRG, 8KB CHR-**RAM** — the common MMC1 shape |
| `M1_P128K_C128K.nes` | 262,160 | SKROM | 128KB PRG, 128KB CHR-**ROM** — CHR bank switching at maximum size |
| `M1_P512K_CR8K_S8K.nes` | 524,304 | SUROM | 512KB PRG — the PRG-A18 path, plus 8KB battery-backed WRAM |
| `M2_P128K_CR8K_V.nes` | 131,088 | U*ROM (UNROM/UOROM) | 128KB PRG, 8KB CHR-RAM — the only shape UxROM has |
| `M4_P256K_C256K.nes` | 524,304 | TSROM | 256KB PRG, 256KB CHR-**ROM** — MMC3's 1KB/2KB CHR banking in both CHR-A12 modes, at maximum size |
| `M4_P128K_CR8K.nes` | 131,088 | TNROM | 128KB PRG, 8KB CHR-**RAM** — the common MMC3 shape, plus the scanline IRQ |

### Why `M2_P128K_CR8K_V.nes`, not `M2_P128K_V.nes`

The archive's `testroms/` directory has *two* mapper-2 ROMs. Both parse as
128KB PRG with an NES 2.0 header declaring 8KB of CHR-RAM (byte 11 = `$07`,
i.e. `64 << 7` bytes) — on paper, either would do. Two things broke the tie
toward `_CR8K_V`:

- Every other CHR-RAM board in this release names that shape explicitly —
  `M1_P128K_CR8K.nes`, `M4_P128K_CR8K.nes`, `M7_P128K_CR8K.nes` — so
  `M2_P128K_CR8K_V.nes` is the name consistent with the rest of the set;
  `M2_P128K_V.nes` (no `CR8K`) is the odd one out.
- The archive's own directory listing timestamps `M2_P128K_V.nes` at
  `2017-11-20 06:45:18`, roughly 28 minutes before every other ROM in the
  release (all stamped `07:13:15`, the batch `make_roms.py` produced last).
  That strongly suggests it is a stale artifact left over from before the
  final build, not a deliberately-distinct variant — `cmp` confirms the two
  files' PRG data differs, so it is not simply a duplicate.

`M2_P128K_CR8K_V.nes` matches this milestone's target board (UNROM/UOROM,
8KB CHR-RAM) and the current, consistently-named generation of the release;
it is the one vendored.

## License: zlib — an actual grant

**This is the only vendored suite in this repo that carries a real license.**
Every other one (nestest, `ppu_vbl_nmi`, `oam_read`/`oam_stress`, the sprite
suites, `apu_test`, `apu_mixer`) rests on the *absence* of a grant — see
[`docs/research/test-rom-licensing.md`](../../../../docs/research/test-rom-licensing.md)
(ENG-59) and the sibling `ATTRIBUTION.md` files, all of which vendor on a
"no formal grant found; believed freely redistributable per longstanding
NES-emulator-community practice" posture.

holy-mapperel ships a `LICENSE` file with the zlib License, © 2017 Damian
Yerrick: permission to use, alter, and redistribute freely, subject to three
conditions. Two apply to redistribution and are satisfied here:

1. *"The origin of this software must not be misrepresented"* — this file is
   that acknowledgment, and the ROMs are attributed to Damian Yerrick above.
2. *"Altered source versions must be plainly marked as such"* — these files
   are unaltered, byte-for-byte, from the upstream release archive.

zlib carries no copyleft, so nothing here conflicts with this repo's MIT
license. Preferring a suite with an explicit grant over one without is
precisely why these are the M7 gate; see
[`docs/reference/external-resources.md`](../../../../docs/reference/external-resources.md).

## What the ROMs do

Each detects which mapper it is running on by writing to the supported
boards' nametable-mirroring ports and watching where reads land, narrows the
result with basic bank switching, then copies a per-mapper driver into RAM
that steps every PRG and CHR bank number through every window in every
banking mode, and tests WRAM, CHR memory, and (where the mapper has one) the
IRQ. It measures PRG/CHR/WRAM sizes from "bank tags" — increasing numbers
placed at a fixed offset in every bank.

Results are drawn on screen: the detected board name, the measured sizes,
and a line reading `DETAILED TEST RESULT: WPIC` — four hex digits for WRAM,
PRG ROM, IRQ, and CHR, where zero means nothing unexpected.

The suite's own README is explicit that it verifies a mapper is "mostly
working" and is "no substitute for an exhaustive mapper-specific test" — it
is a board-assembly test that happens to be an excellent emulator test, not
a conformance suite in the Blargg sense.

## How they are used

Each test asserts the **exact** four-digit code, and every nonzero digit is
explained rather than tolerated:

- **MMC1** reports a nonzero WRAM digit because its PRG-RAM disable bit is
  deliberately deferred (ENG-79). **MMC3** reports one for the same
  underlying reason — its `$A001` PRG-RAM protect bit is out of scope on the
  same `Bus`-owns-`$6000-$7FFF` grounds, and holy-mapperel's README
  separately confirms that code is expected in an iNES-only environment,
  which this repo's parser deliberately is.
- **UxROM** reports `0000` outright: no WRAM, no IRQ, one PRG mode that
  always maps correctly, and CHR that is always plain unbanked RAM.

See each milestone's test file for the per-ROM values. The MMC3 ROMs' IRQ
digit is worth reading `mmc3_test.zig`'s doc comment for on its own: it
started nonzero, and the cause was a pre-existing PPU gap
(`Ppu.fetchSpriteUnits` skipping sprite pattern fetches on a scanline with
no sprites in range) that no earlier milestone's tests could see, because
MMC3 is the first mapper here that watches PPU bus activity itself rather
than only its visible effect.

- there is no `$6000` status protocol to poll, so it runs to a result screen
  under a cycle ceiling;
- tile IDs are not ASCII (the ROM writes `ASCII & $3F` to `PPUDATA` against a
  64-tile font), so they are folded back;
- logical nametable 0 is resolved to a physical VRAM bank through
  `Mapper.mirroring()` rather than assumed to be bank 0 — MMC1 can select
  one-screen-upper, and this ROM writes to mirroring ports on purpose (UxROM
  itself never moves off the header's mirroring, but the harness is shared
  code, so this still applies when it runs the M2 ROM).

7z e holy-mapperel-bin-0.02.7z testroms/M1_P128K_CR8K.nes testroms/M1_P128K_C128K.nes testroms/M1_P512K_CR8K_S8K.nes testroms/M2_P128K_CR8K_V.nes testroms/M4_P256K_C256K.nes testroms/M4_P128K_CR8K.nes
```

The archive also contains a second mapper-2 ROM this milestone did not
vendor (see above), a third MMC3 ROM it did not vendor (`M4_P128K_CR32K`,
32KB CHR-RAM — CHR-ROM already exercises the 1KB/2KB banking that is MMC3's
distinguishing feature over MMC1's coarser CHR granularity), and many
out-of-scope mappers. Each milestone vendors only what it gates on.

Native test binary only — `zig build wasm` never sees this data, exactly like
every other vendored ROM here.

## Reproducing the download

```bash
gh release download v0.02 --repo pinobatch/holy-mapperel
```

```bash
7z e holy-mapperel-bin-0.02.7z testroms/M1_P128K_CR8K.nes testroms/M1_P128K_C128K.nes testroms/M1_P512K_CR8K_S8K.nes testroms/M2_P128K_CR8K_V.nes testroms/M4_P256K_C256K.nes testroms/M4_P128K_CR8K.nes
```

The archive also contains a second mapper-2 ROM this milestone did not
vendor (see above), a third MMC3 ROM it did not vendor (`M4_P128K_CR32K`,
32KB CHR-RAM — CHR-ROM already exercises the 1KB/2KB banking that is MMC3's
distinguishing feature over MMC1's coarser CHR granularity), ROMs for
mapper 3 (M7c), and many out-of-scope mappers. Each milestone vendors only
what it gates on.

## A note on headers

Every holy-mapperel ROM carries an **NES 2.0** header (`flags7` bit 3 set),
not plain iNES. `core/src/rom.zig` parses iNES only and reads these correctly
regardless: the mapper number is `(flags6 >> 4) | (flags7 & 0xF0)`, which
masks the NES 2.0 marker off, and every size here fits the 8-bit iNES
bank-count fields. What is lost is NES 2.0 bytes 10-11, the PRG-RAM and
CHR-RAM *sizes* — which is why the `_S32K` (SXROM, 32KB banked WRAM) ROM is
not vendored, and why the mapper-034 and mapper-078.3 ROMs in the archive are
unusable here. None of those is in this project's mapper scope.
