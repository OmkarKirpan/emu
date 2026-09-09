# emu — context

Single-context doc per `docs/agents/domain.md`. This is the orientation
layer: what the system is, how its pieces fit together, and where the
point-in-time decisions live. Point decisions themselves go in
`docs/adr/`, not here — this file stays a stable map, ADRs are the
append-only log of *why*.

## What this is

A cycle-accurate NES emulator core written in Zig, compiled to
`wasm32-freestanding`, hosted by a React + TypeScript + Vite web app. See
[NES Emulator — Implementation-Ready Spec](https://linear.app/okirpan/issue/ENG-54/nes-emulator-implementation-ready-spec)
(ENG-54) for the full decision record and
[Milestone roadmap & build sequencing](https://linear.app/okirpan/issue/ENG-63/milestone-roadmap-and-build-sequencing)
(ENG-63) for the build sequence this codebase follows.

## Layout

- **`core/`** — the emulator itself, in Zig. `src/root.zig` is the native
  library/test root (CPU, PPU, bus, mapper, controller); correctness is
  established *only* against the native build (`zig build test`), run
  against vendored test ROMs under `core/tests/roms/`. `src/wasm.zig` is a
  separate `wasm32-freestanding` entry point — the actual delivery
  artifact (`zig build wasm`) — exporting a small, explicit ABI (an
  implicit global-singleton `Machine`, free functions, `i32` status codes
  in place of exceptions). Wasm-only concerns (the `alloc`/`free` staging
  surface, the palette→RGBA8 resolve) live in `wasm.zig` and must never
  leak into `root.zig`; native-only concerns (`Cpu.trace`, the
  vendored-ROM test suite) must never leak into `wasm.zig`. Both share one
  implementation, not one entry point. `src/debugger.zig` is a *third*
  root, native-only: `zig build debug -- path/to.nes` gives an interactive
  CPU/PPU inspector (breakpoints, single-step, memory/VRAM/OAM/palette
  viewers) for the author's own debugging, built on the side-effect-free
  `Cpu.trace`/`Bus.peek`/`Ppu.peekRegister` entry points. It deliberately
  adds nothing to the wasm ABI (ENG-67), and its tests ride in `root.zig`'s
  test block rather than a module of their own — a separate `addTest` can't
  compile, because `rom.zig`'s tests `@embedFile` fixtures that exist only as
  `build.zig`'s `test_mod` anonymous imports. **Nametable mirroring belongs to
  `mapper.zig`, not `rom.zig` or `Ppu`** — as of M7a the cartridge answers
  `Mapper.mirroring()` per access, because MMC1 rewrites it at runtime and
  can select single-screen modes the iNES header cannot express; the header
  now supplies only a power-on value. `Mapper.tick()` runs every CPU cycle
  from `Cpu.tick` for the same reason MMC1 needs it (telling a
  read-modify-write's two writes apart) and MMC3 (M7d) needs it too, as the
  clock for its scanline IRQ's A12 low-time filter. `Mapper.chrRead` is
  mutable (not `*const`) as of M7d, since MMC3 tracks PPU address line A12
  from every CHR access; see
  `docs/adr/0003-mapper-owns-mirroring-and-gets-a-per-cycle-tick.md` and
  `docs/adr/0004-mmc3-a12-from-chrread-not-a-new-hook.md`. **The cartridge
  owns its own memory** as of the ENG-82/ENG-79/ENG-80 follow-on to M7:
  `rom.zig` parses NES 2.0 headers (submapper, mapper bits 8-11, PRG/CHR
  size extensions, and PRG-RAM/CHR-RAM sizes) where plain iNES has no room
  to say more; `Mapper.prgRamMap` decides where $6000-$7FFF lands (`Bus` still holds the
  bytes -- storing them per-variant cost a measured 5x, see the ADR) (MMC1 honors its `$E000`/SNROM-`$A000` disable bits and banks
  SXROM's 32KB WRAM, MMC3 honors its `$A001` write-protect bit, NROM/
  TestStub/UxROM/CNROM stay unconditional 8KB); and `Ppu.cart_vram` gives a four-screen board's extra 2KB VRAM chip a home,
  with `Ppu.physicalNametable` now naming which physical memory a logical
  nametable resolves to, not just which bank. See
  `docs/adr/0005-cartridge-owns-its-memory.md`.
  **The audio ring buffer
  (`audio_ring.zig`) used to sit on the wasm-only side of that line; as of
  M6 it does not.** `Apu` is a shared subsystem ticked from `Cpu.tick`
  like `Ppu`, and it writes finished samples into the ring every CPU
  cycle, so the ring is part of the shared graph and runs during native
  tests too (where nothing drains it). Only its pointer-exposing exports
  (`get_audio_ring_ptr` and friends) stay wasm-only. See
  `docs/adr/0002-apu-mixing-and-filtering.md`.
  **`savestate.zig` (M8) is the one definition of "what is machine
  state"** — ENG-61's TLV save-state format, written as a single
  direction-generic codec so each field is named once and the writer and
  reader cannot drift apart. `determinism.zig` no longer keeps its own
  field lists: the determinism digest is SHA-256 over exactly this
  serializer's output, which is what ENG-61 specified from the start. What
  the format excludes (PRG/CHR-ROM, the APU's RC filter cascade, the
  framebuffer) and why is in
  `docs/adr/0006-save-state-format-doubles-as-the-determinism-hash.md`.
- **`web/`** — the host app. `src/wasm/core.ts` wraps `wasm.zig`'s raw
  exports in a typed, memory-safety-aware `NesCore` class (framebuffer
  views go stale across `memory.grow`; every fallible call maps its
  status code to a real exception). `src/wasm/controller.ts` /
  `src/wasm/gamepad.ts` read input. `useRomLoader.ts` / `RomPicker.tsx`
  load a ROM at runtime (ENG-77) over a `'load-rom'` Worker message rather
  than a second `'start'` -- `'start'` carries the one-shot
  `OffscreenCanvas`, while `wasm.zig`'s `load_rom` is safely re-entrant on a
  live core and the audio ring lives outside `Machine`, so a swap needs
  neither a new canvas nor a second audio handshake. The picked file is
  never fetched, stored or served: that is what keeps a real commercial
  game outside the repo's ROM policy entirely (see
  `docs/research/test-rom-licensing.md`). `scripts/sync-core.mjs` runs `zig
  build wasm` and copies its output (plus the vendored demo ROM) into
  `web/` before `dev`/`build` — nothing under `web/src/wasm/*.wasm` is
  committed; `core/` stays the single source of truth.
- **`docs/adr/`** — one file per architecture decision that's reached
  code, numbered in decision order. `docs/reference/external-resources.md`
  indexes the outside material this project builds against (reference
  emulators, test-ROM suites, test-data sets, toolchains) and states the
  licensing rule that governs reading them — most NES emulators are GPL,
  this repo is MIT, and the difference decides which ones may be read and
  which may only be run. `docs/research/` holds the
  longer-form wayfinder research findings an ADR's "Decision" section
  summarizes; ADRs cite them rather than restating them.

## Current state (see ENG-63's roadmap for what "M*" means)

M0–M6 done: repo scaffolding, CPU, PPU (background + sprites), input, the
full threaded pipeline (Worker + SharedArrayBuffer + WebGPU/Canvas2D +
AudioWorklet), and the APU (all 5 channels, frame sequencer, mixer + RC
filter cascade, real game audio replacing M5's test tone). M7a (MMC1) is
done too: the first cartridge here with registers, which is why mirroring
now lives on the mapper rather than the PPU and why `Mapper` has a
per-cycle `tick`. M7b (UxROM), M7c (CNROM) and M7d (MMC3 + scanline IRQ)
followed, built in parallel. M7b and M7c are the quiet results, and are
mirror images of each other: UxROM switches PRG with fixed CHR-RAM, CNROM
switches CHR-ROM with fixed PRG, and both take mirroring from the header and
leave `tick` empty. Neither needed any interface change, which is the
evidence that the shape MMC1 forced generalizes rather than being
MMC1-specific. M7d is the loud one: the first cartridge here with a working
IRQ, and the first mapper that watches PPU bus activity (address line A12)
rather than only reacting to accesses aimed at it — which is why
`Mapper.chrRead` is now mutable, and which caught a real, pre-existing PPU
gap (`Ppu.fetchSpriteUnits` skipping sprite pattern fetches on scanlines
with no sprites in range — invisible until a mapper depended on the bus
activity itself, not just its visible effect). A follow-on to M7
(ENG-82/ENG-79/ENG-80) then closed the three gaps ADR 0003 and ADR 0004 had
each explicitly deferred: `rom.zig` parses NES 2.0 headers, `Mapper` owns
$6000-$7FFF PRG-RAM instead of `Bus` (MMC1's disable bits and SXROM's banked
WRAM, MMC3's write-protect bit), and `Mapper` owns a four-screen board's
extra nametable VRAM instead of `Ppu` silently folding it into vertical
mirroring. holy-mapperel's MMC1 WRAM digit reached `0000` on all four
vendored boards (SNROM, SKROM, SUROM, and the newly-vendorable SXROM); MMC3's
dropped from `2` to `1`, the remaining digit being a real, documented,
deliberately-unmodeled hardware ambiguity (MMC3 `$A001` bit 7's
MMC6-incompatibility problem), not a bug. See
`docs/adr/0001-audio-playback-no-howler.md` for the threaded-audio pipeline
decision, `docs/adr/0002-apu-mixing-and-filtering.md` for the mixer/filter
decisions and the deferred DMC-DMA-stealing gap,
`docs/adr/0003-mapper-owns-mirroring-and-gets-a-per-cycle-tick.md` for the
two interface changes MMC1 forced,
`docs/adr/0004-mmc3-a12-from-chrread-not-a-new-hook.md` for MMC3's A12
design and the PPU fix it forced, and
`docs/adr/0005-cartridge-owns-its-memory.md` for the cartridge-memory
follow-on.

M2b (ENG-67, the native CLI debugger described under `core/` above) landed
after all of the above rather than at its scheduled PPU-milestone slot. It
needed nothing that wasn't already there — the introspection entry points it
is built on (`Cpu.trace`, `Bus.peek`, `Ppu.peekRegister`) had existed since
M1/M2 with no caller outside the tests, which is the whole reason the tool
was a small job by the time it was written.

M8 (ENG-76) is in progress. `savestate.zig` and the ABI it needs
(`save_state`/`load_state`/`get_rom_hash_ptr`/`load_sram` and friends, plus
`NesCore`'s typed wrapper for them) exist and round-trip against every M7
mapper's vendored cartridge; the IndexedDB persistence keyed on
`(rom_hash, slot)` and the save-state slot browser in `web/` are the
remaining half. See
`docs/adr/0006-save-state-format-doubles-as-the-determinism-hash.md` for
why that format is also the determinism hash.

## Conventions worth knowing before touching either side

- **The wasm/JS ABI is the contract.** Any change to `wasm.zig`'s export
  surface needs both sides updated together, and the bit layouts it
  defines (controller buttons, palette indices, the audio ring buffer's
  control-block byte offsets) are cross-referenced by comment between
  the Zig and TypeScript sides rather than shared through a generated
  binding — there's no wasm-bindgen-style tooling here, it's hand-wired
  by design.
- **Zig version is pinned** (see `.github/workflows/ci.yml` and
  `docs/research/zig-wasm32-atomics.md`) precisely because its wasm32
  atomics/threading support is young enough to shift between releases.
- **Correctness lives in the native build's tests, never the wasm one.**
  `zig build wasm` is delivery-only compilation with no test step of its
  own; if a change needs a new behavioral test, it goes in `root.zig`'s
  graph and runs under `zig build test`.
