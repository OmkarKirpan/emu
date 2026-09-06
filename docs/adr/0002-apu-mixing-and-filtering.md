# 2. APU output mixing, RC filter cascade, and deferred DMC DMA stealing

## Status

Accepted (2026-09-06). Implemented as part of [ENG-71](https://linear.app/okirpan/issue/ENG-71/m6-apu) (M6).

## Context

[ENG-62](https://linear.app/okirpan/issue/ENG-62/audio-ring-buffer-protocol-sharedarraybuffer-layout-sample-format)
decided *where* audio mixing/filtering/decimation happens (inside Zig,
before the ring buffer) but not the specific formulas -- that was left for
whoever built the real APU. Three concrete decisions had no prior ticket:

1. Exactly which non-linear mixing formula and lookup constants to use.
2. What output filtering (if any) to apply before decimating to the host's
   sample rate.
3. Whether to model the CPU-cycle-stealing DMA that real DMC sample
   fetches cause.

## Decision

**Mixer**: the standard formula from https://www.nesdev.org/wiki/APU_Mixer --
`pulse_out = 95.88 / (8128/(pulse1+pulse2) + 100)`,
`tnd_out = 159.79 / (1/(triangle/8227 + noise/12241 + dmc/22638) + 100)`,
computed by direct division each CPU cycle rather than a precomputed lookup
table (31/203 entries) -- simpler to write correctly, and a division per
cycle is not a measured bottleneck at this milestone. Revisit only if
profiling says otherwise.

**Filtering**: a cascade of three one-pole RC filters, applied at the full
CPU rate (1,789,773 Hz) before `audio_ring.zig`'s decimation -- high-pass
90 Hz, high-pass 440 Hz, low-pass 14 kHz. This is the documented NTSC NES
hardware filter chain (the Famicom's differs -- a single 37 Hz high-pass --
but this project targets NTSC throughout, matching every timing constant
already in `cpu.zig`/`ppu.zig`). The 14 kHz low-pass doubles as anti-
aliasing ahead of decimation to a ~44.1-48 kHz device rate, which is well
above its cutoff.

**DMC DMA stealing: not modeled.** Real hardware stalls the CPU 1-4 cycles
per DMC sample fetch -- `Apu`'s `Dmc.tickTimer` instead reads straight
through the mapper with no CPU-side effect. This is a scoped, named gap:
none of the vendored `apu_test/rom_singles` ROMs (`7-dmc_basics`,
`8-dmc_rates`) exercise cycle-stealing (that requires the separate,
un-vendored `dmc_dma_during_read4`-style tests), and modeling it correctly
would mean `Cpu.tick`'s bus-access chokepoint growing a second DMA
mechanism alongside OAMDMA's -- real complexity with no conformance ROM in
this milestone's scope to validate it against. Revisit if a future
milestone vendors a DMC-DMA-timing conformance ROM.

## Frame-sequencer and channel-timer corner cases found via the conformance ROMs

Task 13's native conformance stage (all 8 vendored `apu_test/rom_singles`
ROMs, `core/src/apu_test.zig`) surfaced four genuine timing bugs beyond
what this plan anticipated, all fixed in `apu.zig` and left with inline
doc comments at their fix sites:

- **`dmc_rate_table`/`noise_period_table` need halving.** Both tables are
  documented on nesdev in full CPU cycles ("these periods are all even
  numbers because there are 2 CPU cycles in an APU cycle"), but
  `Dmc.tickTimer`/`Noise.tickTimer` run once per *APU* cycle. Loading the
  raw table value as the countdown reload doubled every DMC/noise period.
  Caught by `8-dmc_rates`: "Rate 0's period is too long".
- **Check-then-reload off-by-one.** This codebase's `if (timer == 0) {
  reload; act } else { timer -= 1 }` structure takes `period + 1` ticks
  between actions for a reload value of `period`, not `period` ticks --
  so the halved table value also needs `- 1`. Confirmed by measuring the
  real CPU-cycle gap between DMC output-level changes directly (a
  temporary diagnostic test, not committed) against `dmc_rate_table[0]`
  (428) until it matched exactly.
- **The last frame-sequencer step splits its "quarter + half" clock across
  two CPU cycles.** `5-len_timing`'s length-counter clock at the final
  step and `6-irq_flag_timing`'s frame-IRQ-flag set at that *same* nominal
  step disagreed by exactly one CPU cycle when driven by a single combined
  event -- the quarter part (envelope/linear-counter clock) and the IRQ
  flag fire immediately, but the half part (length-counter/sweep clock)
  needs to land one CPU cycle later. `FrameSequencer.half_frame_pending`
  implements this as a one-tick-deferred event that itself doesn't advance
  `cycle` (so a second, later lap's own thresholds land correctly too --
  this needed its own fix once multi-lap `5-len_timing` sub-tests started
  exercising it).
- **The frame IRQ flag is asserted on three consecutive CPU cycles around
  the wraparound, not one.** `6-irq_flag_timing`'s `#4`/`#5` sub-tests
  clear the flag by reading `$4015` immediately after the first assertion
  and expect it re-armed on each of the next two cycles, but no further --
  `FrameSequencer.irq_reassert_remaining` re-fires the flag-set for the two
  ticks following the main event.
- **A `$4017` write that changes mode within 6 CPU cycles of the prior
  write needs one extra cycle of reset delay** beyond the plain
  write-parity rule (`FrameSequencer.write`'s `old_mode != self.mode`
  check). This is exactly the shape of `5-len_timing`'s own `test` macro
  (`setb SNDMODE,clk*$C0` immediately followed by the real mode, 6 cycles
  later) -- deliberately scoped to an actual mode *change* rather than
  "any two close writes", because `sync_apu`'s own internal back-to-back
  `$4017` writes never change mode and broadening the rule to catch them
  too regressed `3-irq_flag`/`4-jitter`/`6-irq_flag_timing`, all of which
  call it.

None of these were independently re-derived from first principles against
the nesdev wiki's prose -- each was pinned down empirically, per this
plan's own "let the test decide" instruction for exactly this kind of
corner case, using the conformance ROMs (and, where the ROMs' own failure
text wasn't specific enough, a temporary instrumented diagnostic test
driving the real ROM through `Machine`/`Cpu.step` and logging register
writes and state transitions against real CPU-cycle counts) as the
oracle.

## Consequences

- `Apu` is a normal, shared (native + wasm) subsystem exported from
  `root.zig`, the same tier as `Ppu` -- not a wasm-only concern. This is
  what let `audio_ring.zig`'s ring/DRC machinery graduate from "reachable
  only from root.zig's native test block" (M5) to a real dependency of the
  shared graph, with zero new wasm exports needed for M6.
- A future, more obscure DMC-DMA-timing conformance ROM would require
  giving `Cpu` a second DMA-stealing mechanism alongside `runOamDma` --
  flagged here so that need reads as anticipated, not as an oversight.
- The frame-sequencer corner cases above are exactly the kind of thing a
  future mapper with its own IRQ (MMC3, M7) needs to be aware co-exists
  with `Apu.irqPending()`'s OR of frame-IRQ and DMC-IRQ in
  `Cpu.irqAsserted` -- no interaction bug is known today, but the
  precedent (register writes with cycle-precise, non-obvious side effects)
  is worth remembering when that IRQ source is added.
