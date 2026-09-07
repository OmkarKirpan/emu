# 3. The mapper owns mirroring, and gets a per-cycle tick

## Status

Accepted (2026-09-07). Implemented as part of
[ENG-72](https://linear.app/okirpan/issue/ENG-72/m7a-mmc1-mapper) (M7a).

## Context

Through M6 the `Mapper` interface described a cartridge with no state:
`prgRead`/`prgWrite`/`chrRead`/`chrWrite`/`irqPending`/`irqAcknowledge`, with
NROM implementing all six as pure functions of fixed data. Two properties of
that world were baked into code elsewhere:

1. **Nametable mirroring was a constant.** `Bus.init` read it from the iNES
   header and handed it to `Ppu.init`, which stored it in a field and
   consulted it on every nametable access.
2. **The mapper had no notion of time.** Nothing called into it except bus
   accesses.

MMC1 breaks both.

Its control register sets mirroring, and the running program rewrites it
whenever it likes — so a value cached in `Ppu` at construction is wrong the
moment a game scrolls between one-screen and horizontal mirroring. MMC1 also
offers two *single-screen* modes that the iNES header cannot express at all,
so the enum itself was short two variants.

Separately, MMC1 latches its shift register on the **first** of a 6502
read-modify-write's two writes and ignores the second. An NMOS RMW writes the
unmodified value and then the modified one on consecutive cycles; hardware
takes the first. `mapper.zig`'s `TestStub` doc comment already anticipated
this — it exists partly because "an NMOS read-modify-write emits *two* writes
… and real hardware registers latch on the first," which NROM could never
demonstrate. Telling the two writes apart requires knowing what cycle it is,
and nothing in the interface carried that.

## Decision

**Mirroring moves onto the `Mapper` interface as `mirroring()`.** `Ppu` drops
its field and calls `physicalNametable(mapper.mirroring(), logical)` — it
already receives `mapper` on every nametable path. `Ppu.init` and `Bus.init`
lose their mirroring parameters. `Nrom` stores the header value and returns
it unchanged forever; `Mmc1` derives it from control bits 0-1.

`Mirroring` itself moves from `rom.zig` to `mapper.zig` (re-exported from
`rom.zig`, since `Header` still carries the parsed power-on value) and gains
`single_screen_lower` and `single_screen_upper`. Header parsing never
produces those; only a mapper can select them.

**`Mapper` gains `tick()`**, called from `Cpu.tick` immediately after
`bus.apu.tick(&bus.mapper)` — the core's existing single per-cycle
chokepoint. `Nrom`'s is empty and inlines away. `Mmc1` counts cycles with it
and drops any PRG write landing exactly one cycle after the previous one.

## Consequences

- One source of truth for mirroring. There is no sync step to forget, which
  matters for M8's save-state restore and for any future debugger poke: both
  mutate the mapper without going through `Bus.write`.
- Per-access indirection on the PPU's nametable path — a union switch that
  returns a field. Not a measured cost; the same "dispatched millions of
  times a second" argument that made `Mapper` a tagged union rather than a
  vtable applies here, and the switch captures by pointer, so nothing copies.
- ~31 call sites across 8 files updated mechanically for the signature
  changes. `Ppu`'s own mirroring tests now build a mapper reporting the mode
  under test rather than passing it to `Ppu.init`.
- `determinism.zig`'s `hashMapper` gained an MMC1 case. Bank registers are as
  much emulation state as CHR-RAM is: two runs differing only in which bank
  is mapped would otherwise hash identically. `shift` and `last_write_cycle`
  are hashed too, since a half-completed 5-write sequence and the
  consecutive-write rule's memory both survive into the next instruction.
- `physicalNametable` became `pub` so `mapperel_harness.zig` can resolve
  logical nametable 0 to a physical bank the same way the PPU does. A harness
  that assumed bank 0 would read the wrong 1KB whenever a ROM selected
  one-screen-upper.
- M7d gets the per-cycle hook MMC3's scanline IRQ needs for free, which is
  why `tick()` is not speculative generality.

## Alternatives considered

**Bus refreshes a cached `Ppu.mirroring` after every $8000-$FFFF write.** One
line, no PPU changes, no per-access indirection. Rejected: it keeps two
copies of one fact, and any path that mutates the mapper outside `Bus.write`
desyncs silently. Silent desync in nametable mapping presents as subtly wrong
scrolling, which is expensive to diagnose.

**The mapper pushes mirroring into the PPU on register writes.** Rejected
outright: the mapper holds no PPU reference, and giving it one inverts the
dependency direction (today PPU → Mapper) and contradicts `mapper.zig`'s
stated design that "the mapper interface trusts its caller."

**Widen `prgWrite` to take a cycle number** instead of adding `tick()`.
Rejected: `Bus.write` has no clock — `Cpu.cycles` is the only one — so the
count would have to be threaded down through `Bus` as a second copy of the
CPU clock, and every call site would change to carry it.

## Deliberately not decided here

MMC1's **PRG-RAM disable bit** and **SXROM's banked WRAM** are out of scope
for M7a and filed as
[ENG-79](https://linear.app/okirpan/issue/ENG-79/mmc1-prg-ram-disable-bit-route-dollar6000-dollar7fff-through-the).
Honoring the disable bit means routing $6000-$7FFF through `Mapper`, which
reverses the explicit decision documented in `bus.zig` and puts the `$6000`
status protocol the entire vendored-ROM harness depends on at risk. That is
its own ADR when it happens.

The gap is not hidden: holy-mapperel tests the disable bit directly, and
`mmc1_test.zig` asserts the exact result code including the nonzero WRAM
digit it produces. See
`core/tests/roms/holy_mapperel/ATTRIBUTION.md`.
