# 4. MMC3's A12 signal comes from `chrRead`/`chrWrite`, not a new hook

## Status

Accepted (2026-09-07). Implemented as part of
[ENG-75](https://linear.app/okirpan/issue/ENG-75/m7d-mmc3-mapper-and-scanline-irq-mapper-4)
(M7d).

## Context

MMC3's scanline IRQ does not count scanlines. It counts qualifying rises of
PPU address line A12 — the address bit that is high when the PPU fetches a
pattern byte from $1000-$1FFF and low when it fetches from $0000-$0FFF.
Background and sprite pattern fetches select their own, independently
configurable half of pattern space, and in the overwhelmingly common
configuration (one layer's table at $0000, the other's at $1000) that
alternation produces almost exactly one A12 rise per rendered scanline —
which is the entire mechanism. Nothing about "scanline" is special to the
hardware; the cartridge is just watching a bus line.

`Mapper` had no notion of PPU addresses before this. `Ppu.vramRead` already
called `mapper.chrRead(addr)` for every pattern fetch — background and
sprite alike, per `docs/adr/0003-mapper-owns-mirroring-and-gets-a-per-cycle-tick.md`'s
"every CHR fetch already goes through the mapper" — and `addr & 0x1000` is
exactly A12. The information was already crossing the interface boundary on
every single fetch. The problem was not *access* to A12; it was that nothing
receiving it could remember anything.

`Mapper.chrRead` was declared `fn chrRead(self: *const Mapper, addr: u16) u8`.
Every implementation to date (`Nrom`, `Mmc1`) is a pure function of its
banking registers and the address, so `*const self` cost nothing — CHR reads
never had a reason to mutate anything. MMC3 does: to detect a *rise*, not
just a level, it has to remember the previous level and how long it has held
low, and clocking the scanline counter on a qualifying rise mutates the
counter itself. `*const self` made that impossible to implement inside
`chrRead` as declared.

Real hardware also does not accept every rise. A12 briefly glitches high
during ordinary rendering (for instance, a background tile's own fetch
sequence can transiently address the wrong half depending on exact PPU
internals), and without filtering, MMC3 would count scanlines that never
happened. The documented behavior is that A12 must have been low for a
minimum time — commonly described as an M2-based filter, "M2" being the
2A03's own clock (one CPU cycle, 3 PPU dots at NTSC) — before a rise
qualifies. That filter needs its own clock, separate from the address
stream itself.

## Decision

**`Mapper.chrRead` (and every variant's `chrRead`) becomes `*Mapper`/`*Nrom`/
`*Mmc1`/`*TestStub` instead of the `*const` forms.** No new method was added
to the interface. `Mmc3.chrRead` and `Mmc3.chrWrite` both call a private
`observeA12(addr)` that:

1. Computes `addr & 0x1000 != 0` as the new A12 level.
2. On a 0→1 transition, clocks the scanline counter (reload-or-decrement,
   fire if enabled and the result is zero) **only if** A12 has been
   continuously low for at least `a12_filter_min_ticks` calls to `Mmc3.tick()`
   — the per-cycle chokepoint ADR 0003 added, called once per CPU/M2 cycle
   from `Cpu.tick`. `tick()` increments a running "ticks held low" counter
   whenever A12 is currently low; a 1→0 transition resets it.
3. Updates the stored level either way.

`tick()` is the filter's clock, `chrRead`/`chrWrite` are its address input;
between them they implement the M2-based filter using exactly the two hooks
that already existed for MMC1's read-modify-write rule, at one-CPU-cycle
resolution — coarser than the spec's "~3 PPU cycles," but the finest grain
`tick()` offers, and `a12_filter_min_ticks = 1` (the smallest interval it can
represent) is enough to reject the specific case this emulator's own fetch
model can produce: several CHR reads issued within a single `Ppu.tick`/
`Cpu.tick` call (see the `Ppu.fetchSpriteUnits` note below) with no `tick()`
call between them.

`chrWrite` is hooked too, on the same reasoning ADR 0003 used for
`prgWrite`: real hardware doesn't care whether the PPU is reading or
writing, only what address it drove. `chrWrite` was already `*Mapper`
(CHR-RAM writes always mutated), so this cost nothing new.

## Consequences

- **The only interface change is a mutability widening, not a new method.**
  `Nrom.chrRead`/`Mmc1.chrRead`/`TestStub.chrRead` all changed their `self`
  type and nothing else — none of them mutate anything, they simply accept
  the wider access now required by the union's single dispatch signature
  (`Mapper.chrRead` switches on `self.*` and must have one signature for
  every variant). `Ppu.vramRead`'s `mapper` parameter and
  `Ppu.fetchAttributeByte`'s `mapper` parameter widened the same way, since
  they sit between `Ppu.tick`'s already-mutable `mapper: *Mapper` and
  `chrRead`. No caller anywhere in the tree held a mapper reference that was
  *only* const at the point it reached `chrRead` — every path traces back to
  `Cpu.tick`'s `&self.bus.mapper` — so this is a pure widening with no
  narrowing anywhere and no behavior change for `Nrom`/`Mmc1`.
- **This milestone found and fixed a real, pre-existing PPU gap.**
  `Ppu.fetchSpriteUnits` only fetched pattern bytes for sprites
  `evaluateSprites` actually found in range that scanline, skipping the
  fetch (and therefore the CHR access, and therefore any A12 rise) on a
  scanline with none. That was invisible to every test before this
  milestone — nothing reads a discarded pixel — but real hardware always
  performs exactly 8 sprite pattern-fetch pairs a scanline regardless of how
  many are visible, and MMC3's IRQ depends on that constant bus activity to
  fire reliably even on scanlines with no sprites, which is the common case.
  holy-mapperel's own MMC3 IRQ test enables only the background layer (zero
  sprites in range on every scanline), and its detailed result's IRQ digit
  read nonzero until `fetchSpriteUnits` was fixed to always fetch all 8
  slots (discarding the padding slots' pixels, keeping their bus reads).
  This is the clearest illustration of the "information was already crossing
  the boundary" premise cutting both ways: once a mapper actually listens to
  every CHR access, gaps in *which* accesses happen stop being purely
  cosmetic.
- `determinism.zig`'s `hashMapper` gained an `.mmc3` case: the bank
  registers, IRQ latch/counter/reload-pending/enabled/pending, and the A12
  level and low-tick count are all state a mid-scanline resume would need,
  on the same footing ADR 0003 established for MMC1's registers.
- `mapper.zig`'s MMC3 unit tests drive A12 through the real public path
  (`chrRead` + `tick()`, never poking `irq_counter` directly), so the filter
  itself is under test, not just the counter arithmetic behind it — see
  `mmc3ClockA12` and "Mmc3 does not count an A12 rise unless the line was
  held low across a full tick".

## Alternatives considered

**An explicit A12/PPU-cycle hook on the interface** (e.g.
`Mapper.notifyAddress(addr: u16)`, called from `Ppu` alongside but separately
from `chrRead`). Rejected: it duplicates information `chrRead` already
carries on every call, doubles the call sites `Ppu` has to update for every
future mapper, and — unlike the mutability widening actually shipped —
every existing variant would need a new no-op method rather than an
unchanged one. Nothing about A12 is separable from "the address of the CHR
access that just happened"; a second method carrying the same address is a
parallel notification channel for a single fact, not a new capability.

**Something driven from `Mapper.tick()` alone**, inferring pattern-fetch
timing from the PPU's dot/scanline counters mirrored into the mapper somehow.
Rejected for the same reason ADR 0003 rejected widening `prgWrite` to carry a
cycle number: `tick()` has no address, and giving it one means threading
`Ppu`'s scanline/dot state (or the CHR address) down through a second path
that duplicates what `chrRead` already receives directly. It would also
decouple the IRQ counter from what actually happened on the CHR bus — a
mapper that infers "the PPU is probably fetching sprites now" from timing
alone cannot notice a bug like the `fetchSpriteUnits` gap above, because it
was never told the fetch didn't happen.

**Keep `chrRead` `*const` and route A12 through `chrWrite`-only or a side
channel written before the read.** Considered and rejected quickly: CHR
reads are the overwhelming majority of PPU pattern-table traffic (writes are
$2007-only, essentially never issued during rendering), so a scheme that
only sees writes would miss nearly every real A12 transition. A pre-read
side channel (e.g. `Ppu` calling a separate "here is the address I am about
to read" method before `chrRead`) is exactly the rejected "explicit hook"
option again, just ordered differently.

## Deliberately not decided here

**MMC3's PRG-RAM protect bit** ($A001) is out of scope, on the same footing
ADR 0003 put MMC1's PRG-RAM disable bit (ENG-79): honoring it means routing
$6000-$7FFF through `Mapper`, which `Bus` maps as unconditional WRAM by an
explicit decision the vendored ROM harness's `$6000` protocol depends on.
The write is accepted and ignored. holy-mapperel's WRAM digit reports this
the same way it reports MMC1's gap; see
`core/tests/roms/holy_mapperel/ATTRIBUTION.md` and `mmc3_test.zig`.

**The "alternate revision" MMC3 IRQ behavior** — a documented minority of
early MMC3 silicon that fires the IRQ only on a decrement to zero, never on
a reload that lands on zero — is not modeled. `Mmc3.clockIrqCounter`
implements the mainstream behavior (fire whenever the counter's value after
either reload or decrement is zero and IRQs are enabled), which is what
holy-mapperel's test and the overwhelming majority of MMC3 games assume.
