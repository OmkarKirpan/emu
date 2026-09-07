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
  implementation, not one entry point. **Nametable mirroring belongs to
  `mapper.zig`, not `rom.zig` or `Ppu`** — as of M7a the cartridge answers
  `Mapper.mirroring()` per access, because MMC1 rewrites it at runtime and
  can select single-screen modes the iNES header cannot express; the header
  now supplies only a power-on value. `Mapper.tick()` runs every CPU cycle
  from `Cpu.tick` for the same reason MMC1 needs it (telling a
  read-modify-write's two writes apart) and MMC3 will (its scanline IRQ).
  See `docs/adr/0003-mapper-owns-mirroring-and-gets-a-per-cycle-tick.md`.
  **The audio ring buffer
  (`audio_ring.zig`) used to sit on the wasm-only side of that line; as of
  M6 it does not.** `Apu` is a shared subsystem ticked from `Cpu.tick`
  like `Ppu`, and it writes finished samples into the ring every CPU
  cycle, so the ring is part of the shared graph and runs during native
  tests too (where nothing drains it). Only its pointer-exposing exports
  (`get_audio_ring_ptr` and friends) stay wasm-only. See
  `docs/adr/0002-apu-mixing-and-filtering.md`.
- **`web/`** — the host app. `src/wasm/core.ts` wraps `wasm.zig`'s raw
  exports in a typed, memory-safety-aware `NesCore` class (framebuffer
  views go stale across `memory.grow`; every fallible call maps its
  status code to a real exception). `src/wasm/controller.ts` /
  `src/wasm/gamepad.ts` read input. `scripts/sync-core.mjs` runs `zig
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
per-cycle `tick`. M7c (CNROM, mapper 3) is also done, landed ahead of M7b
in build order: fixed PRG exactly like NROM, switchable 8KB-window CHR-ROM
selected by any $8000-$FFFF write. M7b (UxROM) is still next. See
`docs/adr/0001-audio-playback-no-howler.md` for the threaded-audio pipeline
decision, `docs/adr/0002-apu-mixing-and-filtering.md` for the mixer/filter
decisions and the deferred DMC-DMA-stealing gap, and
`docs/adr/0003-mapper-owns-mirroring-and-gets-a-per-cycle-tick.md` for the
two interface changes MMC1 forced.

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
