# 6. The save-state format is the determinism hash, and excludes the APU's filter state to stay one

## Status

Accepted (2026-09-09). Implemented as part of
[ENG-76](https://linear.app/okirpan/issue/ENG-76/m8-save-states-and-sram)
(M8), realizing the format
[ENG-61](https://linear.app/okirpan/issue/ENG-61/save-state-binary-format-and-versioning)
designed.

## Context

ENG-61 decided the save-state format up front and made one further claim
about it: "this format's serializer is the hashing mechanism
`assert_deterministic()` uses in the native test suite from day one — not a
late feature, continuously exercised as each hardware component comes
online." That was aspirational at the time, because M1 needed a determinism
gate and M8 was seven milestones away. What actually shipped from M1 to M7d
was `determinism.zig`'s hand-written `hashCpu`/`hashPpu`/`hashApu`/
`hashMapper` — a second, parallel enumeration of machine state, extended by
hand at every milestone.

It worked, and it did drift-check itself in one direction (a mapper added
without a hash arm makes two runs hash identically when they shouldn't,
which a test notices). But it was still two lists of the same fields, and
only one of them was going to become the save-state.

Collapsing them at M8 raised one genuine conflict. The hand-written hash
deliberately excluded the APU's RC filter cascade (`Apu.hpf1`/`hpf2`/`lpf`
and `output_sample`) — six `f32` values — on the grounds that they are a
pure function of the mixed channel output the hash already covers, so no two
runs can agree on the channels and disagree on the filters, and that hashing
floats would make the digest sensitive to floating-point rounding across
targets for no gain in what it proves. A *save-state*, though, has a
different job from a digest: it is not asking "did these two runs agree", it
is asking "can this machine be resumed". Filter state is real, resumable
state by that standard.

So either the two artifacts diverge (the serializer writes a section the
digest skips), or the save-state accepts a known, bounded loss.

## Decision

**One serializer, `core/src/savestate.zig`, and the determinism digest is
SHA-256 over exactly its output.** `determinism.zig` keeps only the
two-runs-and-compare harness; its field lists are deleted. Adding a field to
the serializer extends the determinism gate automatically, which is the
drift this collapse exists to make impossible.

**The APU's RC filter cascade and `output_sample` are excluded from the
format**, not merely from the digest. The three one-pole filters have
90Hz/440Hz/14kHz time constants against a 1.79MHz clock: a resumed state
re-converges on the correct filter state in well under a millisecond, which
is inaudible. That is the whole cost, and it buys a digest that contains no
floating-point values at all.

Two further exclusions follow ENG-61 directly and are restated here because
they are the same kind of judgment: **PRG-ROM and CHR-ROM** (static,
re-derived by re-booting from the ROM file, which is why `savestate.load`
re-boots before applying any section), and **`Ppu.framebuffer`** (61,440
bytes of output, redrawn from the dot the state resumes at).

The serializer is written as **one direction-generic codec**: every field is
named exactly once, in a function compiled twice — once to write, once to
read. A `writeCpu`/`readCpu` pair is the standard way to ship a serializer
whose halves disagree about field order by one byte, corrupting everything
after it silently, since a byte stream has no shape to check against. That
bug is not expressible here.

## Consequences

* The determinism gate now covers strictly more than it did (`cpu.cycles`,
  `frame.total_cycles`, `bus.open_bus`, all eight sprite units rather than
  the live ones) simply because a save-state needs those. Nothing that was
  covered before is uncovered now.

* A save-state resumed mid-note has audibly correct channel output and
  microscopically wrong filter output for under a millisecond. If that ever
  turns out to matter — it should not — the fix is a separate `apu_filter`
  section that the digest skips, at the cost of this ADR's central claim.

* The digest is portable across targets by construction, not by luck: there
  are no floats in it.

* The cartridge PRG-RAM section is length-prefixed rather than written
  whole. ADR 0005 sized `Bus.prg_ram` at a flat 32KB so the common access
  needs no indirection, but only MMC1's SOROM/SXROM boards carry more than
  8KB — writing the buffer would put 24KB of guaranteed zeroes in every
  other cartridge's every save. The length lives *in the section*, not in
  mapper state a later section restores, so section order stays a layout
  detail rather than a correctness dependency.

* ENG-61 estimated a state at "well under 20 KB". The real worst case is a
  little over 20KB (8KB SRAM and 8KB CHR-RAM on the same cartridge, plus 2KB
  WRAM and 2KB VRAM, is already 20KB before anything else). That does not
  disturb the IndexedDB decision, which ENG-61 explicitly took "regardless of
  any single state's actual size", but the number is restated where it is
  asserted rather than quietly rounded to fit.

* Adding a component later (a new mapper's registers, an input log) adds a
  TLV section and does **not** bump `format_version`: readers skip unknown
  section ids, and `savestate.load`'s re-boot-then-apply order leaves an
  unmentioned component at its power-on default, which is exactly
  [ENG-65](https://linear.app/okirpan/issue/ENG-65/determinism-invariant-power-on-state-input-log-and-exclusions)'s
  rule. The version field is reserved for a change that *reinterprets*
  existing bytes.

* Every existing determinism digest changes value. Nothing stores one, so
  this costs nothing; it is noted because "the hash changed" is otherwise an
  alarming thing to see in a diff.
