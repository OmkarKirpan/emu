# ENG-77 — Load-ROM file picker in the web host

Design doc. Ticket:
[Load-ROM file picker in the web host](https://linear.app/okirpan/issue/ENG-77/load-rom-file-picker-in-the-web-host).

## Problem

`EmulatorScreen.tsx` imports one ROM through Vite's asset graph
(`./roms/sprite_input_demo.nes?url`), copied there from `core/` by
`scripts/sync-core.mjs`. There is no runtime way to load anything else:
running a different game means overwriting that file and restarting the
dev server, which is what M6's in-browser audio verification had to do.

This is also the only route by which a real commercial game can reach the
emulator without the repo's ROM policy being involved: the file is chosen
at runtime by the person running it, and is never stored, committed, or
served from the repo. See `docs/research/test-rom-licensing.md` (ENG-59)
for why that distinction matters.

## The ticket's stated constraint does not hold

ENG-77's scope says to feed the existing Worker `'start'` message and add
no new protocol. That is not possible. `'start'` carries the
`OffscreenCanvas`, and `transferControlToOffscreen` is one-shot and
irreversible per canvas element (ENG-57) — the transferred handle is
detached after the first `postMessage`, so a second `'start'` throws.

Three properties of the code as it stands make a small new message the
cheap answer instead:

- `wasm.zig`'s `load_rom` parses and mapper-checks into a throwaway
  `validate` pass *before* it touches `rom_storage`. A rejected ROM cannot
  partially overwrite an already-running machine. The non-destructive
  failure path is a designed-in property, not an accident.
- `Machine.init` rebuilds bus, mapper and CPU wholesale, so a *successful*
  `load_rom` on a live core is a full cold boot rather than a RESET.
- The audio ring is a module-level global in `audio_ring.zig`, outside
  `Machine`, and `init(sample_rate)` is explicitly independent of
  `g_loaded`. Sample production survives a ROM swap, so there is no second
  handshake and no second user gesture.

Decision: **add one inbound and one outbound Worker message.** Rejected
alternatives:

- *Tear down and rebuild the session* (terminate the Worker, remount the
  canvas via a React `key`, re-run `'start'`). Zero protocol change, but it
  discards the wasm instance, the renderer and the ENG-62 audio handshake
  on every ROM pick, and needs a fresh user gesture to get audio back.
- *Defer first boot until a ROM is chosen.* Smallest protocol surface, but
  it breaks the ticket's "keep the demo ROM as default boot" requirement
  and every existing e2e spec, which all start from a booted demo.

## Protocol

In `emulator/protocol.ts`:

```ts
// EmulatorWorkerInbound
| { type: 'load-rom'; romBytes: ArrayBuffer }

// EmulatorWorkerOutbound
| { type: 'rom-loaded'; ok: true }
| { type: 'rom-loaded'; ok: false; message: string }
```

`romBytes` is transferred, not copied. The Worker's handler calls
`core.loadRom(new Uint8Array(romBytes))` on the live core, catches
`RomLoadError` exactly as `start` already does, and posts the result.

Deliberately a separate outbound message rather than reusing
`{ type: 'status', status: 'error' }`: that one means "the emulator never
came up" and puts a permanent overlay over a dead screen. A failed ROM pick
leaves a working emulator running, and must not read as a fatal error.

After a successful load the Worker posts `audio-resync` to the worklet, so
the roughly 50ms of the previous game's samples still queued in the ring are
dropped rather than played over the new game's first frames.

Unchanged: the canvas, the renderer, the input `SharedArrayBuffer`, and
`'start'` itself. A fresh page load still boots the vendored demo ROM.

## Main thread

A new `web/src/RomPicker.tsx`, not more code inside `EmulatorScreen` —
that file already carries the session-caching and StrictMode remount
reasoning and should not also grow file handling. It takes the `worker`
and reports results upward, and owns:

- a `<label>`-wrapped `<input type="file" accept=".nes">`, styled as a
  button beside Reset (a real focusable input, so the control stays
  keyboard-reachable — which is why drag-and-drop alone was rejected);
- `dragover`/`drop` handlers on the `.screen` wrapper, with a
  `.screen-dragging` outline while a file is over the canvas;
- `file.arrayBuffer()` → `postMessage({ type: 'load-rom', romBytes },
  [romBytes])`.

`EmulatorScreen` gains one piece of state:

```ts
romLoad: { name: string } | { name: string; error: string } | null
```

Success renders `now playing: <filename>`. Failure renders a `.rom-error`
line with a dismiss button, styled distinctly from `.screen-overlay-error`.
`handleReset`, the fatal-error path and the renderer readout are untouched.

The file goes `File` → `ArrayBuffer` → Worker → wasm and is then dropped:
never fetched, stored, or persisted. That is the property ENG-59's
licensing position depends on, and it gets a comment saying so.

### One in-scope correction

`RomLoadError.describe`'s `UnsupportedMapper` arm still reads
*"only NROM/mapper 0 is supported so far"*. True when written; M7 added
MMC1, UxROM, CNROM and MMC3. This ticket exists to put that string in front
of a user, so it is corrected here to name the mappers actually supported.

## Testing

**Unit** — `RomPicker.test.tsx` (vitest): a picked file posts `'load-rom'`
carrying the file's bytes; a dropped non-`.nes` file is ignored.

**e2e** — `e2e/romPicker.spec.ts`, all driven through `setInputFiles`:

1. *Unsupported mapper, non-fatal.* An in-test-crafted 16-byte iNES header
   declaring mapper 99. Asserts the inline error names mapper 99, **and**
   that the demo's sprite is still animating afterward. This is the test
   that proves `load_rom`'s validate-first guarantee end to end.
2. *Garbage bytes.* Asserts the "Not a valid iNES ROM file" message.
3. *Happy path, proving a real re-init.* Drive the demo's sprite away from
   its start column with arrow keys, then load
   `core/tests/roms/nrom_demo/sprite_input_demo.nes` from disk and assert
   the sprite snaps back to `SPRITE_INITIAL_COL`. Reusing the same ROM
   needs no new vendored fixture, and the position reset is explicable only
   by a genuine `Machine.init`.

## Out of scope

The ticket's "Also worth deciding here" — a second Playwright project
against `vite dev` to catch StrictMode-only failures — is filed separately.
It roughly doubles e2e CI time and is a CI-infrastructure trade-off in its
own right, not a rider on a UI feature.

Work branches off `main`: this is web-only and independent of the
in-flight ENG-82/ENG-79/ENG-80 cartridge-memory commits.
