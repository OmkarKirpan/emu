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

**The halted read repeats on every no-operation DMA cycle.** A halted 6502
repeats its last read cycle indefinitely, and on a 2A03 those repeats are
externally visible. So the cycle the halt takes performs the read, the
dummy cycle performs it again, the alignment cycle performs it again if
there is one, and the CPU performs it once more when it resumes -- with
only the DMA's own get cycle, fetching from $8000-$FFFF, breaking the run.
This is the whole observable effect, and modeling the no-op cycles as idle
rather than as reads was wrong: `dma_2007_read`'s own source says the DMA
"causes 2-3 extra $2007 reads", and idling produced one.

**Controllers clock once per contiguous run of reads, not once per read.**
The joypad ports are not on the address bus at all; they hang off two
dedicated output-enable lines that stay asserted across adjacent cycles
reading the same register (`Bus.joy_oe`). Without that rule the repeats
above would shift the controller three or four bits instead of the one
hardware loses. With it, the count comes out right for the same reason it
does on hardware: the get cycle in the middle splits one contiguous run
into two, so the sequence pays exactly one extra clock.

**A load DMA raises its request on the write cycle; a reload raises it on
an APU tick.** When a `$4015` write starts a sample, the request goes up
immediately, on that write's own cycle. When the timer empties the sample
buffer, it goes up on the APU's own clock. That asymmetry is what makes the
two cost different numbers of cycles: a write can land on either half of
the APU clock, so a load's alignment cycle is there or not depending on
when the game wrote, while a reload always starts from the same half and so
always costs the same. Modeling both the same way is what left every ROM's
result one alignment late, and it was the last thing wrong.

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

Four of the seven pass: `dma_4016_read`, `dma_2007_read`,
`dma_2007_write` and `read_write_2007`.

`dma_2007_read` and `double_2007_read` have no verdict of their own -- they
end in `print_crc` rather than `check_crc`, printing a checksum and exiting
silently, because the right answer depends on the CPU-PPU alignment the
console powered into and there is more than one. Their sources list the
acceptable checksums and the tests assert against that list. This core
lands on `dma_2007_read`'s three-extra-reads variant, `5E3DF9C4`.

Three remain open, and one of them does not belong to this ADR at all:

* Both `sprdma_and_dmc_dma` ROMs sweep a DMC DMA across sixteen one-cycle
  offsets around an OAM DMA. Hardware charges 4 cycles normally, 3 landing
  on a CPU write, 2 landing on the `$4014` write or anywhere inside the
  copy, 1 on the copy's next-to-next-to-last cycle and 3 on its last. Only
  the 2 is implemented here. `sprdma`'s shape already comes out right --
  the first five offsets land before the copy at 4, the rest inside it at
  2 -- but `_512` sweeps the copy's *end*, where the 1 and 3 live, and a
  request raised by the copy's own final cycles currently falls out of
  `runOamDma` and gets charged the full 4. A tail case for it was tried
  and not kept; `dmc_dma_test.zig` records why.
* `double_2007_read` is **not a DMC DMA test**. It includes `shell.inc`
  directly rather than the suite's `common.inc`, never synchronizes to the
  DMC and never starts a sample. It reads `lda $20F7,x` with X of `$00`
  and `$10`; the second crosses a page, so the 6502's discarded dummy read
  hits `$2007` and the real read hits it again. It measures what a double
  read does to the PPU's read buffer, and the fix belongs in the PPU.

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
