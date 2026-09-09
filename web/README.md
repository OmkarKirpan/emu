# web — the host shell

The React/TypeScript/Vite front end for the Zig emulator core. It owns the
browser side of the machine: the canvas, the audio graph, the controllers,
ROM loading, and save states. It owns none of the emulation — that all
lives in `core/` and reaches this side as a wasm module.

## How the pieces fit

One Worker holds the one wasm instance, and both video and audio come off
it. Nothing steps the emulator on the main thread.

```
main thread                    emulator Worker                 audio thread
-----------                    ---------------                 ------------
EmulatorScreen ──OffscreenCanvas──▶ wasm core ──ring buffer──▶ AudioWorklet
InputBridge  ──SharedArrayBuffer──▶ set_input
SaveStates   ──────postMessage────▶ IndexedDB
```

- **Video.** The `<canvas>` is transferred to the Worker with
  `transferControlToOffscreen`, which paints on its own ~60 Hz timer.
  The transfer is one-shot per element, which is why `EmulatorScreen`
  caches its session across React remounts — see the comment there.
- **Audio.** A lock-free ring in shared memory, drained by an
  `AudioWorklet`. It needs a user gesture to start, hence the button.
- **Input.** The merged controller byte is published into a shared
  `Int32Array` with `Atomics.store`, polled once per animation frame. No
  `postMessage` sits between a keypress and `set_input`.
- **Saves.** The Worker owns IndexedDB as well as the wasm instance, so a
  20 KB snapshot never crosses onto the main thread. React sees a
  timestamp and a byte count per slot, nothing more.

All of this requires `SharedArrayBuffer`, which requires cross-origin
isolation. See the root [README](../README.md) for the headers and why the
host choice is constrained rather than preferred.

## Controls

Three input paths merge into one controller byte; any of them can drive the
machine, and they can be used interchangeably mid-game.

| | D-pad | B | A | Start | Select |
|---|---|---|---|---|---|
| **Keyboard** | arrow keys | <kbd>Z</kbd> | <kbd>X</kbd> | <kbd>Enter</kbd> | <kbd>Shift</kbd> |
| **Gamepad** | d-pad | south | east | start | select |
| **Touch** | on-screen pad | B | A | Start | Select |

Keyboard listens on `window`, so the demo is playable the moment the page
loads — no click-to-focus. Gamepads must report the W3C `"standard"`
mapping; a pad that reports arbitrary indices contributes nothing rather
than producing silently wrong input.

The on-screen pad appears only where a coarse pointer exists. Its D-pad is
a single pointer target read by angle, not four arrow buttons: that is what
lets a thumb slide from Left through Down-Left to Down without lifting, and
what makes diagonals reachable at all. See `src/wasm/touch.ts`.

## Loading a ROM

`--rom` in the app bar opens a file picker; a `.nes` file can also be
dropped onto the screen. Neither is a fallback for the other — the picker
is a real `<input type="file">` under a `<label>` so the control stays
keyboard-reachable and announces itself, and drag-and-drop is the addition.

The app boots an original, license-clean NROM demo ROM. It is generated
from `core/`, not committed here — see below.

## Save states

Four numbered slots, plus a reserved `sram` slot for the cartridge's
battery-backed RAM. The battery row is shown, not driven: `sram` is loaded
on boot and written as cartridge RAM changes, so offering Save/Load buttons
for it would invite you to fight the mechanism already doing it.

## Running it

```bash
npm run dev
```

`predev` and `prebuild` both run `sync-core`, which builds the Zig core for
wasm32 and copies the module and the demo ROM into `web/`. **Zig 0.16.0
must be on PATH** — see `.github/workflows/ci.yml` for the version this
repo builds against. Neither `src/wasm/nes_core.wasm` nor the vendored ROM
is committed; `core/` is the single source of truth and both are generated.

| Script | What it does |
|---|---|
| `npm run dev` | Vite dev server, with the isolation headers applied |
| `npm run build` | Type-check, then build to `dist/` |
| `npm run preview` | Serve the production build, headers included |
| `npm test` | Unit tests (Vitest, jsdom) |
| `npm run test:e2e` | Playwright, against a real production build |
| `npm run lint` | Oxlint |
| `npm run check-headers <url>` | Assert isolation headers on a deployment |

Unit tests cover anything that needs neither the real wasm module nor a
real browser. Everything else — the ABI wrapper, frame pacing, the audio
pipeline end to end — lives in `e2e/` under Playwright, run against the
actual compiled module rather than a hand-maintained mock of its exports.

> **Note on the e2e suite.** It runs `fullyParallel`, which puts several
> wasm emulators in contention on one machine; the framebuffer polls can
> time out under that load and the failing set shifts between runs. If you
> see scattered failures, re-run with `--workers=1` before treating them as
> real.

## Debugging affordances

- `?renderer=webgpu` or `?renderer=canvas2d` forces a backend, so the
  Canvas 2D fallback can be exercised on a machine where WebGPU works.
  Anything else in the parameter is ignored rather than treated as an
  error.
- The rail states which backend actually engaged. That is not inferable
  from the browser alone — WebGPU is gated by OS and GPU too.

## Design

The interface follows a token system in `src/tokens.css`; every colour,
size, duration and easing in `App.css` and `index.css` resolves through a
name declared there. If you need a value that has no token, add the token
first.

Fonts are self-hosted through `@fontsource` rather than pulled from a CDN.
That is a consequence of COEP `require-corp`, not a preference: under that
policy a cross-origin subresource without CORP fails silently, and
`scripts/check-headers.mjs` walks subresources for exactly this reason.
