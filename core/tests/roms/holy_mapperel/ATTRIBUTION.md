# Third-party test ROMs: Holy Mapperel

## What these are

Eight ROMs from **Holy Mapperel**, an NES cartridge PCB manufacturing test
by Damian Yerrick (tepples):
[`pinobatch/holy-mapperel`](https://github.com/pinobatch/holy-mapperel),
release **v0.02** (2018-09-29), extracted unmodified from that release's
`holy-mapperel-bin-0.02.7z` archive. Four are MMC1 (three from M7a/ENG-72,
plus `M1_P512K_CR8K_S32K` vendored later for ENG-79/ENG-82's banked-WRAM
path), one is UxROM (M7b, ENG-73), one is CNROM (M7c, ENG-74), and two are
MMC3 (M7d, ENG-75).

| File | Size | Board | What it reaches here |
|---|---|---|---|
| `M1_P128K_CR8K.nes` | 131,088 | SNROM | 128KB PRG, 8KB CHR-**RAM** — the common MMC1 shape |
| `M1_P128K_C128K.nes` | 262,160 | SKROM | 128KB PRG, 128KB CHR-**ROM** — CHR bank switching at maximum size |
| `M1_P512K_CR8K_S8K.nes` | 524,304 | SUROM | 512KB PRG — the PRG-A18 path, plus 8KB battery-backed WRAM |
| `M1_P512K_CR8K_S32K.nes` | 524,304 | SXROM | 512KB PRG (the SUROM PRG-A18 path again) plus 32KB of *banked* battery WRAM, selected through $A000 bits 2-3. Vendored as of ENG-79/ENG-82, once `rom.zig` parsed NES 2.0's PRG-RAM size field and `Mmc1` learned to bank it — see below and `mmc1_test.zig` |
| `M2_P128K_CR8K_V.nes` | 131,088 | U*ROM (UNROM/UOROM) | 128KB PRG, 8KB CHR-RAM — the only shape UxROM has |
| `M3_P32K_C32K_H.nes` | 65,552 | CNROM | 32KB PRG (fixed), 32KB CHR-**ROM** (switchable, all 4 banks), horizontal mirroring |
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

Each mapper milestone's test file — `core/src/mmc1_test.zig`,
`uxrom_test.zig`, `cnrom_test.zig`, `mmc3_test.zig` — embeds its ROMs at
build time (anonymous imports declared in `core/build.zig`, from one shared
`mapperel_names` list) and runs them through the one shared
`core/src/mapperel_harness.zig`, which differs from the two existing (pre-M7)
harnesses in three ways:

- there is no `$6000` status protocol to poll, so it runs to a result screen
  under a cycle ceiling;
- tile IDs are not ASCII (the ROM writes `ASCII & $3F` to `PPUDATA` against a
  64-tile font), so they are folded back;
- logical nametable 0 is resolved to a physical VRAM bank through
  `Mapper.mirroring()` rather than assumed to be bank 0 — MMC1 can select
  one-screen-upper, and this ROM writes to mirroring ports on purpose (UxROM
  itself never moves off the header's mirroring, but the harness is shared
  code, so this still applies when it runs the M2 ROM).

Each test asserts the **exact** four-digit code, and every nonzero digit is
explained rather than tolerated:

- **MMC1 reports `0000` on all four boards** (SNROM, SKROM, SUROM, and the
  banked-WRAM SXROM). Through M7a its PRG-RAM disable bit went unhonored,
  reporting a nonzero WRAM digit; as of ENG-79/ENG-82
  (`docs/adr/0005-cartridge-owns-its-memory.md`), `Mmc1` owns $6000-$7FFF
  itself and honors both the standard `$E000` disable bit and the
  SNROM-specific `$A000` one, and banks SXROM's 32KB WRAM through `$A000`
  bits 2-3. See `mmc1_test.zig`.
- **MMC3 reports `1000` on both boards**, down from `2000`. Its `$A001`
  write-protect bit (bit 6, holy-mapperel's "read-only mode") is now
  honored the same way; the remaining `1` is `$A001` bit 7 (PRG-RAM chip
  enable), left deliberately unmodeled — nesdev.org's MMC3 page notes many
  emulators skip it to avoid a documented MMC6 incompatibility. See
  `mmc3_test.zig`.
- **UxROM and CNROM** both report `0000` outright: no bank-switch register
  either one owns can be got wrong without the PRG or CHR digit saying so,
  and neither board has an IRQ.

Worth knowing about the CNROM `0000`: real CNROM boards have no PRG-RAM,
while `Mapper.prgRamRead`/`prgRamWrite` (formerly `Bus`) still give it
unconditional $6000-$7FFF WRAM, same as before ENG-79 — `Cnrom` has no
disable register of its own to gate that with, and this particular ROM
never probes for one anyway; it only confirms that whatever RAM it finds
behaves like RAM. See `cnrom_test.zig`.

The MMC3 ROMs' IRQ digit is worth reading `mmc3_test.zig`'s doc comment for
on its own: it started nonzero, and the cause was a pre-existing PPU gap
(`Ppu.fetchSpriteUnits` skipping sprite pattern fetches on a scanline with
no sprites in range) that no earlier milestone's tests could see, because
MMC3 is the first mapper here that watches PPU bus activity itself rather
than only its visible effect.

Native test binary only — `zig build wasm` never sees this data, exactly like
every other vendored ROM here.

## Reproducing the download

```bash
gh release download v0.02 --repo pinobatch/holy-mapperel
```

```bash
7z e holy-mapperel-bin-0.02.7z testroms/M1_P128K_CR8K.nes testroms/M1_P128K_C128K.nes testroms/M1_P512K_CR8K_S8K.nes testroms/M1_P512K_CR8K_S32K.nes testroms/M2_P128K_CR8K_V.nes testroms/M3_P32K_C32K_H.nes testroms/M4_P256K_C256K.nes testroms/M4_P128K_CR8K.nes
```

The archive also contains a second mapper-2 ROM this milestone did not
vendor (see above), a third MMC3 ROM it did not vendor (`M4_P128K_CR32K`,
32KB CHR-RAM — CHR-ROM already exercises the 1KB/2KB banking that is MMC3's
distinguishing feature over MMC1's coarser CHR granularity), and many
out-of-scope mappers. Each milestone vendors only what it gates on.

## A note on headers

Every holy-mapperel ROM carries an **NES 2.0** header (`flags7` bits 2-3 =
`0b10`), not plain iNES. Before ENG-82, `core/src/rom.zig` parsed iNES only
and read these correctly *by accident*: the mapper number is
`(flags6 >> 4) | (flags7 & 0xF0)`, which never looks at the NES 2.0 marker
bits at all, and every size here fits the 8-bit iNES bank-count fields. What
was lost was NES 2.0 bytes 10-11, the PRG-RAM and CHR-RAM *sizes* — which is
why the `_S32K` (SXROM, 32KB banked WRAM) ROM was not vendored originally.

As of ENG-82, `parseHeader` reads the NES 2.0 marker on purpose and decodes
bytes 8-11 (submapper, mapper bits 8-11, PRG/CHR size extensions, and the
PRG-RAM/CHR-RAM shift-count sizes) when it is present. `M1_P512K_CR8K_S32K`
is vendored as of ENG-79/ENG-82: its byte 10 is `$90` (high nibble 9,
`64 << 9 = 32768` bytes of *battery-backed* PRG-RAM), which `Rom.createMapper`
now reads and wires into `Mmc1.prg_ram_size` — see `mmc1_test.zig`.
`M1_P512K_CR8K_S8K`'s byte 10 (`$70`, `64 << 7 = 8192` battery-backed) is the
worked example in `rom.zig`'s own header-parsing tests. Interestingly, most
of the *other* boards here (SNROM, SKROM, SUROM) declare byte 10 as `$00` --
no PRG-RAM at all -- despite genuinely carrying 8KB of WRAM their own
self-test measures and exercises; `Rom.createMapper` falls back to the
historical 8KB default for MMC1 whenever the header says "none" rather than
trusting that literally, which is what makes their WRAM work at all (see
`createMapper`'s comment for the MMC1 case). The mapper-034 and mapper-078.3
ROMs in the archive remain unusable here regardless — neither mapper is in
this project's scope.
