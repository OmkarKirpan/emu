# 5. The cartridge owns its memory

## Status

Accepted (2026-09-08). Implemented as
[ENG-82](https://linear.app/okirpan/issue/ENG-82/nes-2-0-header-parsing)
(NES 2.0 header parsing), then
[ENG-79](https://linear.app/okirpan/issue/ENG-79/mmc1-prg-ram-disable-bit-route-dollar6000-dollar7fff-through-the)
(PRG-RAM through `Mapper`) and
[ENG-80](https://linear.app/okirpan/issue/ENG-80/four-screen-nametable-vram)
(four-screen nametable VRAM), as one branch.

## Context

Three things a real NES cartridge owns were hard-coded into `Bus` or `Ppu`
instead, each because the milestone that needed the interface to say more
hadn't arrived yet:

1. **How much memory the cartridge has.** `rom.zig`'s `parseHeader` read
   only the plain-iNES header — PRG/CHR ROM sizes in 8-bit bank counts, one
   mirroring bit, battery and trainer flags. iNES has no field for PRG-RAM or
   CHR-RAM *size* at all; NES 2.0 (a backward-compatible extension using
   bytes 8-15, which plain iNES leaves as padding) does, and this parser
   never looked at them. Every vendored holy-mapperel ROM turned out to
   carry an NES 2.0 header already (see `ATTRIBUTION.md`'s "A note on
   headers") and parsed correctly *by accident*, because the mapper-number
   computation happens to skip the exact bits that mark the format.
2. **PRG-RAM at $6000-$7FFF.** `Bus` mapped this window as an unconditional
   8KB array, full stop, regardless of what mapper was installed.
3. **Four-screen nametable VRAM.** `Ppu.physicalNametable` folded
   `.four_screen` mirroring in with `.vertical`, silently collapsing all
   four logical nametables onto the console's two physical VRAM banks.

None of these were oversights. `bus.zig`'s own doc comment named the
PRG-RAM decision explicitly and gave a real reason for it at the time (see
below), and `ppu.zig`'s doc comment carried a `TODO(M7 or later)` pointing
at exactly this gap. Both were flagged so the gap would read as known rather
than accidental — this ADR is that "later."

**Why they are one decision, not three.** All three are instances of the
same shape: a real cartridge feature with nowhere to live because the
interface that reached `Mapper` was sized for M0's NROM, which needs none of
them. `Mapper.mirroring()` (ADR 0003) and MMC3's A12-via-`chrRead` (ADR
0004) already moved two other cartridge concerns onto this interface for
exactly that reason — this is the same move, applied to memory instead of
signals, and it needed one coherent pass rather than three uncoordinated
ones because ENG-79 and ENG-80 both needed ENG-82's header data to size what
they were adding, and both needed a design opinion about *how* a mapper
exposes storage it owns, which only needed deciding once.

### Engaging with `bus.zig`'s reasoning directly

The old doc comment said, in full:

> Despite the mapper-0 name, "NROM" says nothing about whether a given
> cartridge board wires up PRG-RAM at $6000 — that varies per board, which
> is exactly why the iNES/NES 2.0 header carries a separate PRG-RAM size
> field rather than deriving it from the mapper number. Concretely: the
> vendored Blargg `ppu_vbl_nmi` test ROMs (mapper 0) require exactly this
> RAM to exist... Giving every cartridge this RAM unconditionally is a
> deliberate simplification (no battery-backed persistence, no
> mapper-specific enable/disable), on the same "known, named gap" footing as
> the rest of this doc comment: real MMC1/MMC3 boards (M7) may also
> bank-switch or battery-back this window, which `Mapper` still has no entry
> point for and isn't needed until then.

That comment is not wrong; it was right for M0-M6. Two things changed:

- **"Isn't needed until then" arrived.** M7 shipped MMC1 and MMC3, and both
  are now in the vendored conformance suite with real, tested PRG-RAM
  registers (MMC1's `$E000` bit 4 and SNROM's `$A000` variant; MMC3's
  `$A001` write-protect bit). The gap stopped being hypothetical the moment
  holy-mapperel's WRAM digit started reporting it by name.
- **The risk the old comment doesn't mention, but which is the real reason
  this stayed its own decision rather than riding in with M7a or M7d: every
  vendored Blargg ROM's `$6000` status-byte protocol depends on that RAM
  unconditionally existing**, and `blargg_harness.zig` polls it via
  `bus.peek($6000)` on every one of them — nestest doesn't touch it, but
  every `ppu_vbl_nmi` single, `oam_read`/`oam_stress`, and the combined MMC1
  ROM do. Gating PRG-RAM incorrectly is the kind of bug that looks exactly
  like a mapper regression across dozens of unrelated tests. That risk is
  why ADR 0003 and ADR 0004 both explicitly deferred this rather than folding
  it in, and why closing it gets a dedicated verification pass (see
  `mmc1_test.zig`/`mmc3_test.zig`'s updated doc comments) instead of a
  one-line fix.

The resolution is not "the old decision was a mistake" — it is "the
interface it depended on (a `Mapper` with nowhere to put memory) has since
grown one, the same way mirroring and CHR access did."

## Decision

### ENG-82: parse NES 2.0 headers

A header is NES 2.0 exactly when `flags7 & 0x0C == 0x08`; every other value
(including "both bits already zero," the common case, and "both bits set,"
an archive artifact some tools produce) is plain iNES. When the marker is
present, `parseHeader` additionally reads:

- **Byte 8**: submapper (high nibble) and mapper bits 8-11 (low nibble).
  `Header.mapper` widened from `u8` to `u16` to hold this; every mapper this
  core supports (0-4) is unaffected.
- **Byte 9**: high nibbles extending the PRG/CHR ROM bank-count bytes.
- **Bytes 10-11**: PRG-RAM and CHR-RAM sizes, each split into a
  non-battery-backed low nibble and a battery-backed high nibble, each a
  *shift count*: `0` means none, nonzero `n` means `64 << n` bytes. Verified
  against `M1_P512K_CR8K_S8K.nes` (byte 10 = `$70` → `64 << 7 = 8192`,
  matching its documented 8KB battery-backed WRAM) rather than trusted in
  isolation.

A plain-iNES header parses exactly as before, with one explicit default:
`prg_ram_size` becomes `0x2000` (8KB) rather than `0`, matching the size
`Bus` gave every cartridge unconditionally pre-ENG-79 — old ROMs' behavior
does not change. `chr_ram_size`/`chr_nvram_size` are parsed for
completeness but not yet wired into any mapper's storage (see "Deliberately
out of scope" below).

### ENG-79: route $6000-$7FFF through `Mapper`

`Mapper` gains `prgRamRead(addr: u16) ?u8` and `prgRamWrite(addr: u16, value:
u8) void`. `Bus.read`/`peek`/`write` call these instead of owning a
`prg_ram` array; `null` from a read means the cartridge isn't driving the
bus (disabled, or the board never had any), and falls back to `open_bus` —
the same convention `Bus` already uses for every other unmapped region, so
no new concept was needed at the `Bus` layer.

Each variant answers differently:

- **`Nrom` and `TestStub` stay unconditional 8KB**, ignoring the header
  entirely, per this ADR's explicit instruction to preserve their exact
  current behavior — this is what keeps every Blargg ROM's `$6000` protocol
  working unchanged.
- **`Uxrom` and `Cnrom` also stay unconditional 8KB.** Neither board has a
  PRG-RAM register of its own on real hardware to gate with, and changing
  their behavior risked nothing being caught by a test while still being an
  unrequested behavior change — `cnrom_test.zig` already documents that its
  ROM measures and exercises this RAM and expects it to behave like RAM.
  Preserving it is the conservative choice; real CNROM/UxROM boards having
  no PRG-RAM at all remains a known, named gap, same footing as before.
- **`Mmc1` honors two real gates**: `$E000` bit 4 (every MMC1B board) and,
  on the specific board shape where nothing else claims that pin —
  `chr_bank0` bit 4, only when CHR totals 8KB or less (no real CHR bank
  needs the bit) and PRG-ROM is 256KB or less (SUROM/SXROM's own use of the
  same bit, PRG-A18, needs a board that large to exist at all) — the
  SNROM-specific extra WRAM disable. This condition is derived from
  geometry already on hand (`Mmc1.isSnromWramGate`), not a submapper
  number the vendored ROMs don't carry. `Mmc1.prg_ram_size` (set by
  `Rom.createMapper` from the header, defaulting to 8KB when the header
  declares none) and 8KB-unit banking through `chr_bank0` bits 2-3
  (`prgRamOffset`) give SOROM/SXROM's larger boards real banked WRAM, sized
  from ENG-82's data.
- **`Mmc3` honors `$A001` bit 6** (write-protect, holy-mapperel's "read-only
  mode"). Bit 7 (chip enable) is deliberately not modeled — see
  "Deliberately out of scope."

**Real-world default when the header under-declares.** Several vendored
NES 2.0 ROMs (the SNROM/SKROM/SUROM boards) declare byte 10 as `$00` — no
PRG-RAM at all — despite genuinely carrying 8KB of WRAM their own self-test
measures and exercises. `Rom.createMapper` falls back to the historical 8KB
default for MMC1 whenever the header's declared PRG-RAM total is zero,
rather than trusting "none" literally; a header that *does* declare a size
(S8K, S32K) is honored as-is. This is what makes those boards' WRAM work at
all under an NES 2.0-aware parser, and it is the standard convention other
NES 2.0-aware emulators follow for exactly this reason.

### ENG-80: four-screen nametable VRAM

**The interface-shape question.** A `u1` physical bank index cannot express
"which of four independently-writable banks, in which of two memories" —
four-screen mirroring means no mirroring at all, and needs a cartridge-owned
extra 2KB VRAM chip alongside the console's own.

**Decision: widen `physicalNametable`'s return to name the memory, not just
the bank.** `Ppu.physicalNametable` now returns a small struct,
`{ source: Mapper.NametableSource, bank: u1 }`, where `NametableSource` is
`.console` or `.cartridge`. For `.four_screen`, logical nametables 0-1
resolve to `.console` (banks 0-1, same as today) and logical 2-3 resolve to
`.cartridge` (also banks 0-1, but the *other* chip). Every other mirroring
mode always resolves to `.console`, unchanged. `Mapper` gains
`nametableRead(addr: u11) u8` / `nametableWrite(addr: u11, value: u8) void`
— the pre-resolved 11-bit index into whichever 2KB chip `source` named —
mirroring the `chrRead`/`chrWrite` shape exactly. `Ppu.vramRead`/`vramWrite`
dispatch on `source` before touching either `Ppu.vram` or the mapper.

Every mapper variant carries an inline `cart_nametable: [0x800]u8` for this,
even though none of the five currently ever *selects* `.four_screen` from
their own register logic (`Mmc1`/`Mmc3` derive mirroring from bits that
never produce it; `Nrom`/`Uxrom`/`Cnrom` pass the header's mirroring through
unchanged, and a header *can* set the four-screen bit on any of them) — this
is the same "one signature for every union variant" reasoning ADR 0004 used
for widening `chrRead`'s mutability across every mapper, not only MMC3.

## Consequences

- **`Bus.prg_ram` is gone.** `determinism.zig`'s `hashState` moved PRG-RAM
  hashing out of its own top-level `hasher.update(&bus.prg_ram)` and into
  `hashMapper`, per-variant — the storage moved, so does the hash, on the
  same "state that can make two runs diverge must be covered" basis every
  other section of that file already follows. `cart_nametable` is hashed on
  every variant too, unconditionally, for the same reason `Nrom.chr` is
  hashed whenever it's CHR-RAM: live mutable storage, even on boards that
  can't currently reach it.
- **holy-mapperel's WRAM digit: MMC1 reaches `0000` on all four boards
  (SNROM, SKROM, SUROM, SXROM).** This is the headline result — every
  previously-nonzero WRAM digit this project has carried for MMC1 is gone.
  **MMC3 drops from `2000` to `1000`, not `0000`** — see "Deliberately out
  of scope" for why the remaining `1` digit is understood and intentional,
  not a bug.
- **`M1_P512K_CR8K_S32K.nes` (SXROM, 32KB banked WRAM) is now vendored** and
  passes cleanly (`0000`) — previously unusable because `rom.zig` didn't
  parse the header field that says how big its WRAM is. See
  `ATTRIBUTION.md`.
- **`Ppu.vram` is no longer "all the nametable storage that exists."** Its
  doc comment said so before ENG-80; a four-screen board's extra chip lives
  on `Mapper` instead, reached through `vramRead`/`vramWrite`'s dispatch on
  `PhysicalNametable.source`.
- `mapperel_harness.zig`'s `screenText` now asserts `source == .console`
  when resolving logical nametable 0 — true for every currently-vendored
  ROM (none sets the four-screen header bit), and documents the assumption
  instead of leaving it implicit.
- No vendored ROM exercises `.four_screen` end-to-end; ENG-80's coverage is
  unit tests in `ppu.zig` driving a header-declared four-screen `Nrom`
  directly. This is named, not hidden — see "Deliberately out of scope."

## Alternatives considered

**PRG-RAM: keep `Bus` owning the storage, ask the mapper only "is it
enabled?"** (e.g. `Mapper.prgRamEnabled() bool`, with `Bus.prg_ram` still a
flat array). Rejected: it solves the disable-bit problem but not the sizing
one — SXROM's 32KB banked WRAM still has nowhere to live, since `Bus` would
still own one undifferentiated 8KB block. It also splits one cartridge
feature (PRG-RAM) across two owners (`Bus` for storage, `Mapper` for
policy), the same anti-pattern ADR 0003 rejected for mirroring ("two copies
of one fact").

**PRG-RAM: widen `Mapper.prgRead`/`prgWrite` to cover $6000-$FFFF instead of
adding new methods.** Rejected: PRG-ROM and PRG-RAM are different kinds of
memory with different mutability (`prgRead`/`prgWrite` model a mix of fixed
and bank-switched *read-only* ROM windows; PRG-RAM is genuinely
read-write storage that can also be entirely absent) and different
enable semantics (a PRG-ROM read never "fails"; a PRG-RAM read can find
nothing driving the bus). Folding them into one address range would mean
every `prgRead` implementation gains a return type it doesn't need
(`Nrom`/`Uxrom`/`Cnrom`'s PRG-ROM can never be absent) just to serve the two
mappers that do need it. This mirrors the CHR precedent directly:
`chrRead`/`chrWrite` already exist as their own pair, separate from
`prgRead`/`prgWrite`, for exactly this "different memory, different
interface" reason — PRG-RAM getting its own pair keeps that symmetry rather
than breaking it.

**Four-screen: the mapper serves nametable reads/writes fully**, the way
`chrRead` serves the *entire* CHR address space today (i.e., `Ppu` calls
`mapper.nametableRead(logicalAddr)` and the mapper resolves mirroring
itself, console-VRAM fallback included). Rejected: mirroring resolution
(`physicalNametable`) is shared logic reused by `Ppu` and
`mapperel_harness.zig` alike; moving it into every mapper variant would
duplicate that four-way switch six times over instead of once, and the
mapper would need a way to reach the console's own VRAM for the
`.console`-source case, which means giving it a `Ppu` reference — inverting
the dependency direction ADR 0003 already rejected for the same reason
("today PPU → Mapper", not the other way).

**Four-screen: grow `Ppu.vram` to `[0x1000]u8` (4KB) unconditionally**,
giving every cartridge four independent banks whether or not it's
four-screen. Rejected: gives every ROM — plain NROM included — 2KB of
nametable storage real hardware doesn't have, and more importantly
misattributes ownership: that extra memory belongs to the *cartridge*, not
the console, which is the entire premise this ADR is built on. It would
also mean `determinism.zig` hashing cartridge-owned bytes as part of `Ppu`
rather than `Mapper`, the same layering violation PRG-RAM had before
ENG-79.

**Header parsing: leave the NES 2.0 marker unread indefinitely**, keeping
`rom.zig` strictly iNES-only and treating every ROM's bytes 8-15 as padding
forever. Rejected: this is the status quo ADR 0003/0004 both explicitly
deferred (see their "Deliberately not decided here" sections), and it is
what made SXROM's banked WRAM unvendorable — the header genuinely has no
other way to say "32KB," and guessing a size from board-name conventions
alone (rather than reading what the file says) is exactly the kind of
silent inference this project avoids elsewhere.

## Deliberately out of scope

**MMC3 `$A001` bit 7 (PRG-RAM chip enable).** Real MMC3 silicon's chip
enable is functional but, per nesdev.org's MMC3 page, "many emulators
choose not to implement them as part of iNES Mapper 4 to avoid an
incompatibility with the MMC6" — a genuine board-compatibility hazard, not
an oversight. `Mmc3.prgRamRead` never returns `null` for this reason.
holy-mapperel's WRAM digit reports this as `1`, the same digit position
MMC1 uses for its own (implemented) disable-bit gap, on the same
"documented and asserted, not silently tolerated" footing as every other
digit this project's mapper tests track. `mmc3_test.zig` asserts it
exactly.

**CHR-RAM sizing from the header.** `chr_ram_size`/`chr_nvram_size` are
parsed (ENG-82 asks for every field iNES has no room for, not only the ones
a mapper reads yet) but not wired into any mapper's storage — every
CHR-RAM-capable variant still uses a fixed inline 8KB array and infers
*presence* from `chr_rom.len == 0`, exactly as before this ADR. No vendored
ROM needs anything but 8KB of CHR-RAM, so there was nothing to drive this
design decision yet.

**Battery-backed persistence.** PRG-RAM (battery-backed or not) still isn't
written to any external store; `has_battery`/`prg_nvram_size` say a board
*would* persist across power cycles on real hardware, not that this
emulator does. Unchanged from `bus.zig`'s original stated simplification —
this ADR moved the memory's owner, not its persistence model.

**Four-screen VRAM without a vendored end-to-end ROM.** No test ROM in this
project's suite sets the four-screen header bit, so ENG-80's coverage is
unit-level (`ppu.zig`'s tests drive a header-declared four-screen `Nrom`
directly through `vramRead`/`vramWrite`) rather than a full boot-and-run
conformance test. The interface is real and exercised; a genuine four-screen
cartridge run through this core end-to-end remains future work if one is
ever vendored.

**Submapper-driven board identification.** `Header.submapper` is parsed and
carried but nothing reads it — `Mmc1`'s SNROM-quirk detection
(`isSnromWramGate`) and every other board-shape decision in this codebase
derive from ROM geometry already on hand (PRG/CHR/PRG-RAM sizes) rather than
the submapper number, which the vendored ROMs don't set meaningfully anyway.
