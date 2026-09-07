# M7a — MMC1 mapper (ENG-72)

Design for [M7a: MMC1 mapper](https://linear.app/okirpan/issue/ENG-72/m7a-mmc1-mapper),
first of the four staged mapper sub-tickets sliced from
[ENG-63](https://linear.app/okirpan/issue/ENG-63/milestone-roadmap-and-build-sequencing).
Blocked by M6 (ENG-71), which is done.

## What this milestone is really about

Adding a second real cartridge to a codebase that has only ever had one, and
that one has no registers at all. NROM is fixed PRG, fixed CHR, no state. MMC1
is a serial shift register driving four internal registers that repartition
both address spaces and *change nametable mirroring at runtime*.

Two consequences reach past `mapper.zig`, and they are the actual content of
this milestone:

1. **Mirroring stops being a constant.** It is currently read from the iNES
   header once and stored in `Ppu`. MMC1 changes it whenever it likes, and it
   can select two single-screen modes that the header cannot even express.
2. **The mapper needs to know what cycle it is.** MMC1 latches on the *first*
   of a 6502 read-modify-write's two writes and ignores the second. Nothing in
   the current interface can tell those apart.

## Component 1: the `Mmc1` variant

New variant in `core/src/mapper.zig`:

```zig
pub const Mmc1 = struct {
    prg_rom: []const u8,        // borrowed, like Nrom's
    chr_rom: []const u8,        // borrowed; empty => CHR-RAM board
    chr_ram: [0x2000]u8,        // live only when chr_rom.len == 0
    mirroring_mode: Mirroring,  // derived from control bits 0-1
    shift: u8 = 0x10,           // load register; the walking sentinel marks write #5
    control: u5 = 0x0C,         // power-on: PRG mode 3, last bank fixed at $C000
    chr_bank0: u5 = 0,
    chr_bank1: u5 = 0,
    prg_bank: u5 = 0,
    cycle: u64 = 0,
    last_write_cycle: ?u64 = null,
};
```

**CHR is borrowed here, not copied.** `Nrom` copies CHR into an inline 8KB
array, which is affordable because NROM's CHR is *always* 8KB. MMC1 allows
128KB, so an inline copy would put 128KB in every `Mapper` value including the
NROM ones — the union is as big as its largest variant. Borrowing extends the
lifetime rule `Nrom` already documents for PRG ("the caller must keep the
original ROM buffer alive") to CHR as well. The 8KB inline `chr_ram` stays,
because CHR-RAM boards have nothing to borrow from — and those are the boards
two of the three gate ROMs use.

### In scope

- 5-write shift register, LSB first; bit 7 set resets it and ORs `control`
  with `$0C`
- All four PRG modes: 32K switchable; 16K fixed-first + switchable-last; 16K
  switchable-first + fixed-last (modes 2 and 3 being the two 16K cases)
- 4K and 8K CHR modes, over CHR-ROM or CHR-RAM
- All four mirroring modes: one-screen lower, one-screen upper, vertical,
  horizontal
- Power-on `control = $0C`, so the reset vector is reachable before the ROM
  writes anything
- **512KB PRG (SUROM):** PRG A18 comes from bit 4 of the active CHR bank
  register. In 8K CHR mode that is `chr_bank0`; in 4K mode the two registers
  select A18 for their respective halves, and every real 512K board is
  CHR-RAM, so the CHR registers are pure bank-selection bits there.
- The consecutive-cycle write rule (component 3)

### Out of scope, deliberately

- **PRG-RAM disable bit** ($E000 bit 4, and the SNROM $A000 variant). Filed as
  [ENG-79](https://linear.app/okirpan/issue/ENG-79/mmc1-prg-ram-disable-bit-route-dollar6000-dollar7fff-through-the).
  Honoring it means routing `$6000-$7FFF` through `Mapper`, reversing a
  documented `Bus` decision and putting the `$6000` status protocol that the
  entire Blargg harness depends on at risk. That deserves its own ADR.
- **SXROM banked WRAM.** Needs ENG-79's routing *and* NES 2.0 header parsing
  for the PRG-RAM size field, which `rom.zig` does not read.

### Geometry validation

`rom.createMapper` gains case `1`: PRG must be 16K–512K in 16K units, CHR must
be 0 (RAM) or 8K–128K in 8K units, else `MapperError.InvalidRomGeometry` —
matching how case `0` already rejects malformed NROM.

## Component 2: mirroring moves to the mapper

The mapper becomes the single source of truth. `Mapper` gains
`mirroring() Mirroring`; `Ppu` drops its `mirroring` field and calls
`physicalNametable(mapper.mirroring(), logical)` — it already receives
`mapper` on every nametable path (`vramRead`/`vramWrite`, and every
`renderCycle` fetch).

`rom.Mirroring` grows `single_screen_lower` and `single_screen_upper`. Header
parsing never produces them; only MMC1 does. `physicalNametable` returns `u1`
already, so both map cleanly (all four logical nametables to physical bank 0
or bank 1 respectively).

Ripple: `Nrom.init` takes the header mirroring, `Ppu.init` and `Bus.init` lose
their parameter, and roughly 31 call sites across 8 files update
mechanically.

**Why not the cheaper option.** Keeping `Ppu.mirroring` as a field and having
`Bus.write` refresh it after every `$8000-$FFFF` write is one line and touches
nothing else. It was rejected because it creates two copies of one fact: any
path that mutates the mapper outside `Bus.write` — M8's save-state restore, a
future debugger poke — desyncs silently. Mapper-pushes-into-PPU was rejected
outright; the mapper has no PPU reference, and giving it one inverts the
current dependency direction and contradicts `mapper.zig`'s stated "the mapper
interface trusts its caller" design.

## Component 3: `Mapper.tick()` and the RMW rule

`Mapper` gains `tick()`, called from `Cpu.tick` beside the existing
`bus.apu.tick(&bus.mapper)`. Every variant but MMC1 implements it as a no-op
that inlines away.

MMC1 increments `cycle` in `tick` and, in `prgWrite`, drops any write landing
exactly one cycle after the previous one:

```zig
if (self.last_write_cycle) |last| {
    if (self.cycle == last + 1) return;   // second write of an RMW: ignored
}
self.last_write_cycle = self.cycle;
```

This is the behavior `TestStub`'s doc comment in `mapper.zig` already
anticipates — it exists partly because "an NMOS read-modify-write emits *two*
writes … and real hardware registers latch on the first," which NROM could
never demonstrate. `TestStub`'s write log is what proves the drop in a unit
test.

The alternative — widening `prgWrite` to take a cycle — was rejected because
`Bus.write` has no clock (`Cpu.cycles` is the only one), so the count would
have to be threaded down through `Bus` as a second copy of the CPU clock.

M7d's MMC3 scanline IRQ needs a per-cycle hook regardless, so this is not
speculative generality.

## Component 4: the gate

### Primary — holy-mapperel

Three ROMs vendored from
[pinobatch/holy-mapperel](https://github.com/pinobatch/holy-mapperel) v0.02
(**zlib licensed**, extracted from `holy-mapperel-bin-0.02.7z`), into
`core/tests/roms/holy_mapperel/` with an `ATTRIBUTION.md` per the existing
per-suite pattern:

| ROM | Size | Why this one |
|---|---|---|
| `M1_P128K_CR8K.nes` | 131 KB | CHR-RAM baseline, the common SNROM shape |
| `M1_P128K_C128K.nes` | 262 KB | CHR-ROM bank switching at maximum size |
| `M1_P512K_CR8K_S8K.nes` | 524 KB | SUROM — the PRG-A18 path |

`_S32K` is skipped: its unique coverage is SXROM WRAM banking, which is out of
scope, so vendoring it would mean committing a binary whose expected result is
"fails the part we care about." `C32K` and the `_W8K` variants are
size/RAM-flavor duplicates of what these three already cover.

**Assert the exact 4-digit result code** (WRAM, PRG, IRQ, CHR; zero is normal)
per ROM against a documented expected value. The WRAM digit will be nonzero by
construction — holy-mapperel tests the PRG-RAM disable bit that ENG-79 defers
— and that digit gets named in a comment as a deliberate gap rather than
skipped. An unasserted digit is one that can regress in silence, and this
suite's entire value is that it reports precisely.

### Secondary — real workload

The combined `ppu_vbl_nmi/ppu_vbl_nmi.nes` (mapper 1, 256KB PRG — the ROM
`core/build.zig` already names as one "this codebase cannot run"). It speaks
Blargg's `$6000` protocol, so `blargg_harness.zig` runs it with **zero new
harness code**, and because all ten of its sub-tests already pass individually
as NROM singles, a failure is unambiguously an MMC1 bug.

### Unit tests

In `mapper.zig`, covering what the gate ROMs localize poorly: shift-register
sequencing and bit-7 reset, each PRG mode's window math, PRG-A18 at 512K, 4K
and 8K CHR banking over CHR-ROM, CHR-RAM write-through, all four mirroring
modes, the consecutive-write drop, and `createMapper`'s geometry rejections.

## Component 5: `mapperel_harness.zig`

New `core/src/mapperel_harness.zig`, sibling to `blargg_harness.zig`. It needs
three things no existing harness does:

- **Run to a stable screen.** No `$6000` protocol, no `$81` reset handshake.
  Bounded by a cycle ceiling like `blargg_harness`'s, so a hang fails instead
  of hanging CI.
- **Tile → char decoding** as `if (tile < 0x20) tile + 0x40 else tile`. The
  ROM writes every character as `ASCII & $3F` straight to `PPUDATA`, so unlike
  Blargg's ROMs, tile ID is not ASCII.
- **Logical → physical nametable resolution through `mapper.mirroring()`.**
  `ppu_sprites_test.zig`'s harness reads `Ppu.vram[0..960]` assuming logical
  nametable 0 is physical bank 0 — true under fixed H/V mirroring, false the
  moment MMC1 selects one-screen-upper. holy-mapperel identifies mappers *by
  writing to their mirroring ports*, so this is not a hypothetical.

Extracted up front rather than at the second consumer: `blargg_harness.zig`
was pulled out of `ppu_vbl_nmi_test.zig` when `ppu_sprites_test.zig` needed
it, and this one has three known consumers (M7b, M7c, M7d) before a line is
written.

## Documentation

- **ADR 0003** — mapper owns `mirroring()`, and `Mapper.tick()`. Both are
  architecture decisions that reach code, which is what `docs/adr/` is for.
  Records the rejected alternatives above and the MMC1 gaps (ENG-79, SXROM).
- `core/tests/roms/holy_mapperel/ATTRIBUTION.md` — note the **zlib grant**
  explicitly, since it differs from every other vendored suite's
  absence-of-grant posture.
- `ppu_vbl_nmi/ATTRIBUTION.md` — add the combined ROM; its existing text says
  the codebase "cannot run" it, which stops being true here.
- `CONTEXT.md` — current-state paragraph, and the mapper bullet.

## Notes on NES 2.0

Every holy-mapperel ROM carries an NES 2.0 header (`flags7 |= 0x08`).
`rom.zig` parses iNES only and reads them correctly anyway: the mapper number
is `(flags6 >> 4) | (flags7 & 0xF0)`, which masks the NES 2.0 marker off, and
every size in the set fits the 8-bit iNES bank-count fields. What is lost is
NES 2.0 bytes 10-11 — the PRG-RAM and CHR-RAM *sizes* — which is precisely
why `_S32K` is out of scope. No NES 2.0 work is needed in this milestone.
