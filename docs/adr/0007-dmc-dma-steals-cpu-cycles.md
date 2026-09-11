# 7. DMC DMA steals CPU cycles, through `Cpu.read`

## Status

Accepted (2026-09-11). Implemented as part of [ENG-81](https://linear.app/okirpan/issue/ENG-81/dmc-dma-does-not-steal-cpu-cycles).
Supersedes the "DMC DMA stealing: not modeled" decision in
[ADR 0002](0002-apu-mixing-and-filtering.md) (ENG-71, M6).

## Context

M6 shipped the APU with `Dmc.tickTimer` reading its sample byte straight
through the mapper: correct data, zero cost to the CPU. ADR 0002 named that
a scoped gap and said what would close it -- a conformance ROM that measures
the stolen cycles, and a second DMA mechanism in `Cpu` alongside
`runOamDma`. Both arrived here.

The cycles matter because they are observable, not merely because they are
real. A DMC sample fetch freezes the 6502 for a few cycles, and the cycle it
freezes on is a read that then happens twice -- which perturbs `$4016`
controller reads and `$2007` PPU-data reads, and shifts instruction timing
for any game whose loops are counted in cycles.

## Decision

**The DMC requests; the CPU stalls.** `Dmc.tickTimer` no longer touches the
mapper at all. When its one-byte sample buffer runs dry with bytes left to
play it raises `dma_pending`, and `Cpu` -- the only thing that can halt the
CPU -- services it. `Apu.tick` consequently takes no `mapper` argument any
more.

**The halt lives in `Cpu.read`, and only there.** The DMA unit can halt the
6502 only on a read cycle; on a write the halt is ignored and it retries.
That is modeled structurally rather than with a flag: `Cpu.write` has no
halt check, so a request landing mid-`STA`, mid-RMW (two consecutive
writes) or mid-interrupt (three) is delayed by 1-3 cycles until the next
read, exactly as hardware delays it.

**The halted read happens twice.** The cycle the halt takes still performs
its read -- the address is already on the bus -- and the CPU, not having
advanced, re-issues the identical read when the DMA finishes, keeping that
second value. On a register with read side effects both accesses are real,
which is the glitch these ROMs exist to measure.

**The stall is halt, dummy, optional alignment, get**, per
https://www.nesdev.org/wiki/DMA -- three or four cycles, the alignment
cycle present only when the fetch would otherwise land on a put cycle.
Every cycle runs through `idleCycle`/`tick`, the precedent `runOamDma` set,
so the PPU keeps advancing and NMI keeps being polled while the CPU is
frozen. Hardware halts the 6502, never the rest of the console.

**A collision with OAM DMA costs two cycles, not four.** `runOamDma`
services a pending DMC request itself (one get cycle, then one cycle to
realign) rather than going through `Cpu.read`'s halt sequence, because the
CPU is already halted and there is no halt or dummy cycle left to pay for.
An `oam_dma_active` flag keeps `Cpu.read` out of the way for the duration.

**Which APU half is the "get" cycle was settled empirically.** Hardware
does not fix it -- the CPU and APU power into either of two alignments --
and the two polarities differ by one stall cycle. The polarity in
`nextIsGetCycle` is the one that yields four, which is what
`dmc_dma_during_read4`'s own synchronization loop is written around
("3421+4 clocks per iter", in its `sync_dmc.s`). With the other polarity
that loop never converges and the ROMs hang.

## Conformance status

Seven ROMs vendored across two suites (see `core/src/dmc_dma_test.zig` and
each directory's `ATTRIBUTION.md`). Both suites predate Blargg's `$6000`
protocol and report as console text in nametable 0, so this also grew
`blargg_harness.zig` a shared nametable-text runner that
`ppu_sprites_test.zig`'s two 2005-vintage suites now use as well.

`dma_2007_write` and `read_write_2007` pass. The remaining five do not yet,
and are wired up and marked as a measured gap rather than left out --
`dmc_dma_test.zig` records exactly what each one reports. The residue is a
one-clock offset in the shape of the stall, not a missing mechanism:
`dma_4016_read` loses exactly one controller bit on exactly one of its five
alignments, as hardware does, one alignment later than hardware does it.

## Consequences

- `Cpu` now has two DMA mechanisms. They are deliberately not unified:
  OAM DMA is a 513-514-cycle block copy the CPU itself initiates with a
  `$4014` write, DMC DMA is a 3-4-cycle steal an unrelated subsystem
  imposes, and the only thing they share is `idleCycle`.
- `Dmc.dma_pending` is save-state state, so the format version went to 2.
  A fetch requested and not yet serviced has to survive a save.
- `Apu` no longer reads the cartridge. Everything that touches the bus now
  does so through `Cpu`, which is what made the double read expressible at
  all.
- Games whose timing depends on DMC sample playback -- the sample-heavy
  titles -- now drift the way hardware drifts rather than not at all. No
  regression appeared in any previously passing suite.
