# External resources

An index of the outside material this project builds against: reference
implementations, test-ROM suites, test *data* sets, and toolchains. It is a
working document for the execution phase, not a link dump — every entry says
what it is good for **here**, and what it costs to use.

Every fact in the tables below (license, activity, size) was verified with
`gh` on **2026-09-07**. Re-verify before acting on any of them; see
[Re-checking](#re-checking).

## The licensing rule, first

This repo is MIT, and it has already done the work of establishing a careful
posture on third-party material — see
[`docs/research/test-rom-licensing.md`](../research/test-rom-licensing.md)
(ENG-59) and the per-directory `ATTRIBUTION.md` files under
`core/tests/roms/`. That posture extends to *source code you read*, and the
extension is not obvious, so state it plainly:

**Almost every well-known NES emulator is GPL.** Mesen, FCEUX, Nestopia,
puNES, and SimpleNES are all GPL-2.0 or GPL-3.0. Reading one of those to
learn *how the hardware behaves* is fine. Reading one and then writing the
same structure, the same tables, or the same code in `core/` is how an MIT
repo acquires a copyleft obligation it never declared. The risk is not
theoretical for a project like this one: mapper bank-math and APU mixing
tables are exactly the kind of small, distinctive code that survives
translation between languages.

So, in strict order of preference:

1. **Specifications.** The NESdev Wiki (<https://www.nesdev.org/wiki>) is the
   primary source and is already what this codebase's doc comments cite.
   `docs/reference/6502_cpu.txt` is the vendored CPU reference.
2. **Test ROMs and test data.** Behavior stated as a *pass/fail oracle* —
   these tell you what's wrong without telling you anyone else's
   implementation. Best value per hour by a wide margin.
3. **Permissively licensed implementations** (table below). Safe to read
   closely and safe to borrow from with attribution.
4. **GPL implementations, as a black-box oracle by default.** Run the ROM in
   Mesen, watch its debugger, compare against this core's behavior.

The fourth rule has a deliberate escape hatch, because a rule people quietly
break is worse than one that says what to do. **Reading GPL source to
*diagnose* is allowed.** Some bugs — subtle PPU timing, an APU edge case —
are realistically only findable by seeing how a mature emulator handles them.
When that happens:

- Say so in the issue: which project, which file, what it told you.
- Write the fix from the NESdev spec, not from what you read. If the spec
  doesn't state the behavior, the issue should say that too — that's a
  finding about the spec, and it's the point at which "independently derived"
  stops being a phrase and starts needing thought.

What is never OK is transcription: porting a table, a structure, or a
routine. The line is between *learning what the hardware does* — which is not
Mesen's to own — and *copying how Mesen does it*, which is.

## Reference implementations

### Permissive — safe to read and borrow from

| Project | License | Lang | Last push | Consult for |
|---|---|---|---|---|
| [LaiNES](https://github.com/AndreaOrru/LaiNES) | BSD-2-Clause | C++ | 2025-11-06 | Compact cycle-accurate design — the closest analogue to this core's size and ambitions. |
| [fogleman/nes](https://github.com/fogleman/nes) | MIT | Go | 2024-08-17 | Readable end-to-end architecture; its mapper set (NROM/MMC1/UxROM/CNROM/MMC3) matches M7's scope exactly. |
| [jsnes](https://github.com/bfirsh/jsnes) | Apache-2.0 | JS | 2026-09-01 | Host-side concerns: how a JS host drives a core, framebuffer/audio handoff. |
| [pinky](https://github.com/koute/pinky) | Apache-2.0 | Rust | 2023-11-27 | The closest prior art to this project's *shape*: systems language → wasm → browser host. |
| [cfxnes](https://github.com/jpikl/cfxnes) | MIT | JS | 2024-05-19 | Browser host packaging; less active than jsnes. |

### Copyleft — black-box oracle only, per the rule above

| Project | License | Status | Use as |
|---|---|---|---|
| [Mesen2](https://github.com/SourMesen/Mesen2) | GPL-3.0 | **Archived** on GitHub (last push 2026-06-04); check upstream before assuming it is maintained | The accuracy benchmark and the best debugger. Run ROMs in it; compare against `Cpu.trace`. |
| [FCEUX](https://github.com/TASEmulators/fceux) | GPL-2.0 | Active (2026-05-30) | Widely-deployed behavior; useful for "what do real emulators actually do here?" Note its documented NES-2.0 gaps (see holy-mapperel below). |
| [Nestopia](https://github.com/0ldsk00l/nestopia) | GPL-2.0 | Active (2026-09-05) | Accuracy cross-check. |
| [puNES](https://github.com/punesemu/puNES) | GPL-2.0 | Active (2026-09-01) | Accuracy cross-check; strong APU/NSF side. |
| [SimpleNES](https://github.com/amhndu/SimpleNES) | GPL-3.0 | Active (2025-10-05) | Small enough to read in an afternoon — which is exactly why it is the most tempting to copy from. Don't. |
| [Nintendulator](https://github.com/quietust/nintendulator) | **None** | Active (2025-12-27) | No license at all, which is more restrictive than GPL, not less. Oracle only. |

## Test ROMs and test data

### Vendored today

`core/tests/roms/` holds nestest, `ppu_vbl_nmi` (10 NROM singles), `oam_read`,
`oam_stress`, `sprite_hit_tests_2005.10.05`, `sprite_overflow_tests`,
`apu_test`, `apu_mixer`, and the in-house `nrom_demo`. Every third-party one
comes from
[christopherpow/nes-test-roms](https://github.com/christopherpow/nes-test-roms)
(no license; 612 stars; last push 2022-03-02) on the documented "no formal
grant found; believed freely redistributable per longstanding community
practice" posture.

### holy-mapperel — the mapper gate M7 was missing

[pinobatch/holy-mapperel](https://github.com/pinobatch/holy-mapperel) —
**zlib licensed**, by Damian Yerrick (tepples). An NES cartridge
manufacturing test that detects which mapper it is running on, measures
PRG/CHR/WRAM sizes from bank tags, and runs a per-mapper driver stepping
every bank number through every window in every banking mode, plus IRQ and
WRAM-protection checks.

Why this matters more than anything else on this page:

- **It covers the entire M7 arc in one suite.** The release ships per-board
  ROMs including `M1_*` (SxROM/MMC1 — M7a), `M2_P128K_V` (UNROM — M7b),
  `M3_P32K_C32K_H` (CNROM — M7c), and `M4_*` (TxROM/MMC3, IRQ included —
  M7d). ENG-72's acceptance criterion — "MMC1 conformance test-ROM(s) pass
  natively" — has an answer that isn't improvised.
- **It has an actual license.** zlib: permissive, explicit, and granted.
  Every other test ROM in this repo rests on the *absence* of a grant. That
  distinction is worth preferring it for.
- **Its result is readable from a native test.** The ROM draws its findings
  on screen and this repo already reads screens: `ppu_sprites_test.zig` has a
  nametable-text harness for the pre-`$6000` Blargg suites. The headline is a
  4-digit code — **WRAM, PRG, IRQ, CHR; zero is normal** — alongside the
  detected mapper number and measured PRG/CHR/WRAM sizes.
- **Its hard-failure Morse codes are targeted.** `SU` means "switching to the
  second half of a 4 Mbit SUROM failed" — a direct 512KB-PRG MMC1 check.

The eleven MMC1 ROMs decode by suffix — `C` = CHR-ROM, `CR` = CHR-RAM,
`S` = battery-backed SRAM, `W` = plain WRAM:

| ROM | Size | Covers |
|---|---|---|
| `M1_P128K_CR8K.nes` | 131 KB | CHR-RAM baseline, the common SNROM shape |
| `M1_P128K_C32K{,_S8K,_W8K}.nes` | 164 KB | CHR-ROM banking, 4 banks |
| `M1_P128K_C128K{,_S8K,_W8K}.nes` | 262 KB | CHR-ROM banking at maximum size |
| `M1_P512K_CR8K_S8K.nes` | 524 KB | SUROM — the PRG-A18 path |
| `M1_P512K_CR8K_S32K.nes` | 524 KB | SXROM — 32K banked WRAM |

Costs and cautions:

- Distributed as one prebuilt archive (`holy-mapperel-bin-0.02.7z`, release
  v0.02, 2018-09-29 — 18 KB, since the ROMs are mostly repeated banks), or
  built from source with **cc65 + GNU Make + Python 3 + Pillow**. cc65 is
  already this repo's in-house ROM toolchain (`core/tests/roms/nrom_demo`),
  though it is not currently installed on the dev machine — the release
  archive is the practical path.
- **Every ROM in the set carries an NES 2.0 header**, not iNES
  (`tools/make_roms.py` builds them with `flags7 |= 0x08`). This repo's
  iNES-only parser reads them correctly anyway: `rom.zig` computes the mapper
  as `(flags6 >> 4) | (flags7 & 0xF0)`, which masks the NES 2.0 marker bit
  off, and every size in the set fits the 8-bit iNES bank-count fields. What
  is lost is NES 2.0 bytes 10-11 — the **PRG-RAM and CHR-RAM sizes** —
  which `rom.zig` ignores entirely. That is why the `_S32K` (SXROM, 32K
  banked WRAM) and 32K-CHR-RAM ROMs cannot fully pass against a fixed 8K
  `Bus.prg_ram`, and why the mapper-034 and mapper-078.3 ROMs (which need
  submapper semantics) are unusable here. None of those mappers is in scope.
- The README notes the MMC3 ROM warns about missing WRAM write protection in
  iNES-only environments (FCEUX among them) — expect that warning here too.
- It verifies a mapper is "mostly working"; the README says outright it is
  "no substitute for an exhaustive mapper-specific test."

### SingleStepTests/65x02 — exhaustive CPU verification

[SingleStepTests/65x02](https://github.com/SingleStepTests/65x02) — **MIT
licensed**, and its `nes6502/v1/` set is the 2A03 variant specifically (BCD
disabled), which is exactly this core's CPU.

256 JSON files, one per opcode, **10,000 scenarios each** — 2.56 million
tests. Each carries the full initial processor and memory state, the full
expected final state, and **a per-cycle list of bus operations** as
`[address, value, "read"|"write"]`.

That last part is the point. This core's design rests on `Cpu.tick` being the
single chokepoint every bus access flows through, and `TestStub` exists in
`mapper.zig` precisely because an NMOS read-modify-write emits two writes and
nothing else in the tree could observe it. This data set asserts that
cycle-by-cycle bus behavior for every opcode, undocumented ones and dummy
reads/writes included — coverage nestest cannot approach.

Costs:

- **1.08 GB** (~5 MB per opcode file). Not vendorable. It has to be fetched
  on demand into a scratch directory, or vendored per-opcode for a chosen
  subset.
- Tests assume **a flat 64 KB RAM address space**, which is not this
  machine's memory map. Running them needs a test-only flat-memory bus
  standing in for `Bus`, which `Cpu` currently borrows as a concrete `*Bus`.
  A real (small) refactor, not a drop-in.
- The parent repo
  [SingleStepTests/ProcessorTests](https://github.com/SingleStepTests/ProcessorTests)
  carries **no license** — cite and use the MIT `65x02` repo, not the parent.

### Others worth knowing

| Suite | License | Use |
|---|---|---|
| [240p-test-mini](https://github.com/pinobatch/240p-test-mini) | GPL-2.0 | PPU timing and video-output correctness. Runnable and redistributable, but vendoring it would make this repo's ROM tree non-uniformly licensed — that needs an ADR, not a quiet `git add`. |
| [Klaus2m5/6502_65C02_functional_tests](https://github.com/Klaus2m5/6502_65C02_functional_tests) | GPL-3.0 | The classic exhaustive 6502 functional test. Largely superseded here by 65x02's per-cycle data, which is MIT and NES-specific. |
| `MMC1_A12/` in nes-test-roms | None | An MMC1 test, but it ships `joypad.asm` and `alphabet.chr`, so it appears interactive/visual rather than self-checking. Verify before relying on it. |
| [pinobatch/little-things-nes](https://github.com/pinobatch/little-things-nes) | No license file | One-off tech demos and test ROMs; check individual READMEs for terms. |

## Toolchains for in-house ROMs

`core/tests/roms/nrom_demo` established the pattern: original 6502 assembled
with [cc65](https://cc65.github.io/)'s `ca65`/`ld65`, with `.s`, `.cfg`, and
the built `.nes` all committed so CI never needs the assembler.

For the mapper milestones,
[pinobatch/snrom-template](https://github.com/pinobatch/snrom-template) is the
matching ca65 template for UNROM / UOROM / SGROM / **SNROM** (MMC1) boards —
the fastest path to a hand-written MMC1 ROM if one is ever wanted beyond
holy-mapperel. Its sibling
[nrom-template](https://github.com/pinobatch/nrom-template) is what
holy-mapperel's README points at for toolchain setup. **Neither repo has a
license file**, so both fall under the same "absence of a grant" posture as
the Blargg ROMs — read their READMEs for terms before deriving anything from
them.

## What this changes about how the project is built

Three process changes follow from the above, listed here so they don't get
lost as prose:

1. **Mapper milestones get a real conformance gate.** M7a–M7d
   (ENG-72/73/74/75) gate on holy-mapperel's per-board ROMs, read through a
   shared `core/src/mapperel_harness.zig`, rather than on improvised
   substitutes. Its zlib license is a strict improvement over the posture
   every currently-vendored ROM rests on. Decided for M7a and to be followed
   by the rest:

   - Each milestone vendors only the ROMs it gates on — M7a takes three
     (`M1_P128K_CR8K`, `M1_P128K_C128K`, `M1_P512K_CR8K_S8K`: CHR-RAM
     baseline, CHR-ROM banking at maximum size, SUROM), each as an extracted
     `.nes` committed like every other vendored ROM, under a
     `core/tests/roms/holy_mapperel/ATTRIBUTION.md`.
   - **Assert the exact 4-digit code** against a documented expected value
     per ROM, rather than asserting only the digits currently expected to be
     zero. Digits that are nonzero because a feature is deliberately out of
     scope (MMC1's PRG-RAM disable bit; SXROM's banked WRAM) get named in a
     comment next to the expectation. An unasserted digit is one that can
     regress in silence, and this suite's whole value is that it reports
     precisely.
   - The harness resolves logical nametable 0 to its physical bank through
     `mapper.mirroring()`. `ppu_sprites_test.zig`'s harness assumes physical
     bank 0, which holds under fixed H/V mirroring and breaks the moment
     MMC1 selects one-screen-upper — which holy-mapperel does on purpose,
     since it identifies mappers by writing to their mirroring ports.
   - Tile IDs decode as `tile < $20 ? tile + $40 : tile`; the ROM writes
     every character as `ASCII & $3F` straight to `PPUDATA`.

   The MMC1 gap this exposes — the PRG-RAM disable bit, which holy-mapperel
   tests and M7a scopes out — is filed as
   [ENG-79](https://linear.app/okirpan/issue/ENG-79/mmc1-prg-ram-disable-bit-route-dollar6000-dollar7fff-through-the),
   not left as a comment.
2. **CPU correctness has a much higher ceiling available.** A `65x02` sweep —
   opt-in, not part of `zig build test`, given the 1.08 GB fetch and the
   flat-bus shim it needs — verifies per-cycle bus behavior across all 256
   opcodes. Filed as
   [ENG-78](https://linear.app/okirpan/issue/ENG-78/opt-in-per-cycle-cpu-sweep-against-singlesteptests65x02-nes6502):
   a CPU-milestone improvement arriving after the CPU milestone, which is the
   normal way this happens. **Built:** `zig build test-cpu-sweep`, with
   `core/tools/fetch-65x02.sh` to populate the gitignored cache and
   `core/src/cpu_sweep.zig` for how the flat bus is switched in without the
   production build gaining a branch.
3. **"Which emulator do I look at?" has a defensible answer** instead of a
   habit. LaiNES and fogleman/nes for reading; Mesen for running. That line
   is a licensing boundary, not a taste preference.

## Re-checking

The facts above were gathered with the GitHub CLI; the same commands
re-verify them:

```bash
gh api repos/pinobatch/holy-mapperel --jq '[.full_name, .license.spdx_id, .pushed_at, (.archived|tostring)] | join(" | ")'
```

```bash
gh api repos/SingleStepTests/65x02/contents/nes6502/v1 --jq '[.[] | .size] | add'
```

Anything vendored into `core/tests/roms/` needs its own `ATTRIBUTION.md`
recording source URL, file sizes, license posture, and how the ROM is used —
the existing files under that tree are the template.
