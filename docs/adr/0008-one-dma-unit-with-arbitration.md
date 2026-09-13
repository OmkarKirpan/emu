# 8. One DMA unit, arbitrated per cycle

## Status

Accepted (2026-09-13). Implemented as part of
[ENG-86](https://linear.app/okirpan/issue/ENG-86/dmc-dma-cost-at-the-oam-dma-boundary-sprdma-and-dmc-dma).
Supersedes the "they are deliberately not unified" consequence in
[ADR 0007](0007-dmc-dma-steals-cpu-cycles.md).

## Context

ADR 0007 gave `Cpu` two DMA mechanisms and said so on purpose: OAM DMA is a
513-514 cycle block copy the CPU starts with a `$4014` write, DMC DMA is a
3-4 cycle steal an unrelated subsystem imposes, and the only thing they
shared was `idleCycle`. Each computed its own cost, and their collision was
a third case written by hand inside `runOamDma` -- a flat two cycles
mid-copy, plus `dmcTailPrepCycles`, a small table for what a request raised
by the copy's own last cycles still owed.

That shape cannot produce what hardware does at the boundary.
`sprdma_and_dmc_dma_512` sweeps a DMC DMA across the end of a copy, and
hardware charges 1 on the copy's next-to-next-to-last cycle and 3 on its
last. ENG-86 recovered both ROMs' expected checksums and, from them, the
cost table each ROM is actually asking for (see `dmc_dma_test.zig`). This
core got `_512`'s offsets 04-05 and 0A-0B wrong, and both are boundary
cases that a computed cost gets wrong by construction.

Mesen2 passes both ROMs. Its `NesCpu::ProcessPendingDma` is one loop over
both units, and it contains no cost arithmetic at all.

## Decision

**One loop, `Cpu.runDma`, arbitrating both DMAs cycle by cycle.** Every
cost hardware charges is emergent:

**Only a get cycle may read.** The other half of the APU clock is a put, and
the only thing that can happen on one is OAM DMA's write to `$2004`, which
must follow a read it already did.

**DMC wins a get-cycle collision, once its run-up is paid.** OAM DMA's read
simply does not happen that cycle; its address and step counter are
untouched, so it re-issues the same byte on its next get cycle. That costs
the copy the DMC's get plus one put spent realigning -- the two cycles a
mid-copy collision costs, now a consequence rather than a constant.

**Any DMA cycle retires the run-up.** `retireRunUp` drops one of
`halt_pending`/`dmc_dummy_pending` per cycle no matter what that cycle is
doing, so a DMC request raised while a copy is already running has its halt
and dummy absorbed by cycles the copy was going to spend anyway. This is
the whole reason a collision costs 2 inside a copy and 3 or 4 outside one,
and it is the rule the two mechanisms could not share.

**The boundary needs no special case.** When the copy's last cycle retires
`oam_dma_pending` the loop keeps running for whatever the DMC still owes,
so a request the copy's final cycles raise pays the remainder of its run-up
in real time while one raised earlier has it absorbed. `dmcTailPrepCycles`
is deleted.

**A `$4014` write only requests the copy.** A DMA halts the 6502 on a read
cycle; `STA $4014` ends on a write, so the copy begins on the CPU's next
read, like every other DMA halt. Running it inline from `write` started it a
cycle early and on the wrong half of the get/put clock.

**The halt is tested before a read cycle, not after.** A request that goes
up during a read cannot be halted by that same cycle -- the read has already
happened. Testing afterwards consumed the halt a cycle early; with that
fixed, `nextIsGetCycle` flips to `!apu.even_cycle`, which is the literal
translation of Mesen2's `(CycleCount & 1) == 0` and is what makes OAM DMA's
513/514 come out on the parity nesdev documents.

## Conformance status

All four `dmc_dma_during_read4` ROMs that passed under ADR 0007 still pass,
and the full suite is green. `_512`'s offset 04 now matches the expected
table, which is one of the two boundary cases ADR 0007's shape could not
reach.

**Both `sprdma_and_dmc_dma` ROMs still fail, and this ADR does not claim to
fix them.** Their remaining error is not arbitration: their printed values
are parity-blind here, uniformly one cycle high on even offsets, and four
different alignment variants leave the sixteen values byte-identical. The
copy's 513/514 alternation is real and measured, but the ROM's own timing
routine cannot see it in this emulator and plainly can on hardware. See
`dmc_dma_test.zig` for the expected tables and the evidence.

## Consequences

- `runOamDma`, `runDmcDma` and `dmcTailPrepCycles` are gone, along with
  `oam_dma_active` and the unit test that pinned the tail table.
- The DMA unit's state (`halt_pending`, `dmc_dummy_pending`,
  `oam_dma_pending`, `oam_dma_page`, `dmc_pending_prev`) is save-state
  state, because a requested-but-not-started copy outlives the instruction
  that requested it. Format version goes to 4.
- `idleCycle` is now only `step`'s jammed-CPU path. The DMA unit never
  idles: a halted 6502 re-issues its read, so spare DMA cycles go through
  `readCycle`, which is what makes the repeats externally visible.
- OAM DMA's cost is no longer attributable to the `STA $4014` instruction;
  it lands on the instruction that follows. Anything measuring per-
  instruction cycles across a DMA has to account for that.
