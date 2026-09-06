# 1. Audio playback: hand-rolled AudioWorklet + ring buffer, not Howler.js

## Status

Accepted (2026-09-06). Implemented as part of [ENG-70](https://linear.app/okirpan/issue/ENG-70/m5-migrate-to-full-threaded-pipeline-video-audio-plumbing) (M5's audio-plumbing slice).

## Context

[ENG-62](https://linear.app/okirpan/issue/ENG-62/audio-ring-buffer-protocol-sharedarraybuffer-layout-sample-format)
already locked the audio architecture before any of it reached code:
the emulator core (one wasm instance, running in a dedicated Worker)
writes finished, mixed, decimated `f32` PCM samples into a lock-free
single-producer/single-consumer ring buffer living in the wasm module's
own `SharedArrayBuffer`-backed linear memory. A pure-JS
`AudioWorkletProcessor` — which never instantiates wasm itself — does
nothing but `Atomics`-synchronized index bookkeeping and a `memcpy` into
its output buffer on the real-time audio thread. Dynamic rate control
(resample ratio nudged by up to ±0.5% based on ring fill) absorbs the
drift between the NES's 60.0988 Hz frame clock and the audio device's
crystal, running *inside* the Zig core by having it load the consumer's
read index directly — zero extra exports, zero per-frame JS↔wasm calls
for the control loop itself.

Before writing that pipeline, the question was raised: could
[Howler.js](https://howlerjs.com/) — a well-established, widely-used
Web Audio wrapper — replace some or all of this hand-rolled machinery
and save the implementation effort?

## Decision

**No. Howler is not used anywhere in the emulator's audio-output path.**
The ENG-62 architecture and Howler solve different problems:

- **Howler's unit of work is a `Sound`**: a discrete, named audio asset
  (a file URL or an `AudioBuffer`) that gets played, paused, faded,
  sprite-sliced, or spatially positioned. Its API and internal Web Audio
  graph (per-sound gain/panner nodes, an HTML5-`<audio>` fallback path
  when Web Audio is unavailable, playback pooling for overlapping one-
  shots) are all built around *managing a library of clips*.
- **What M5 needs is one continuous, indefinite-duration stream of
  synthesized samples**, produced in real time by wasm running off the
  main thread and consumed by a custom `AudioWorkletNode` reading
  directly out of shared memory. There is no clip, no URL, no fixed
  duration, and nothing to fade, pool, or spatialize.
- Howler has no public hook for "drive this `AudioWorkletProcessor`'s
  `process()` from a `SharedArrayBuffer` I already own" — that's not a
  supported source type. Using it here would mean instantiating Howler
  purely to get an `AudioContext` from it and then reaching past its API
  to attach a custom node anyway, which buys nothing over creating the
  `AudioContext` directly (one line) and loses control over exactly when
  and how it's created — ENG-62's handshake requires the `AudioContext`
  be created synchronously inside a user-gesture handler and its
  worklet's `MessagePort` transferred to the Worker untouched; a
  library that manages the context's lifecycle internally is friction
  here, not help.
- Howler's HTML5-`<audio>` fallback — a meaningful part of its value
  proposition for broad compatibility — is moot: `AudioWorklet` itself
  requires the Web Audio API to exist in the first place, so the
  scenario that fallback exists for (no Web Audio API) already means no
  audio pipeline at all, worklet or Howler.
- Every piece of real engineering ENG-62 calls for — the lock-free
  index protocol, the underrun silence-ramp, the pathological-desync
  resync, the DRC loop — is bespoke regardless of what plays the sound
  at the very end. Adding Howler would add a dependency and an
  abstraction layer with no seam that any of that plugs into, for zero
  reduction in code written.

**Where Howler would fit, if a need for it ever shows up:** decorative,
non-emulation UI sound — a boot chime, a button click, menu music — for
the surrounding shell chrome, as ordinary asset-based playback
completely separate from the APU/test-tone ring buffer. Nothing in the
current scope (M5's test tone, or M6/ENG-71's real APU output) is that
kind of sound, so this ADR takes no position on it beyond "not
precluded."

## Consequences

- No new runtime dependency added to `web/package.json` for audio.
- The audio path stays entirely hand-written JS/TS + Zig, matching this
  project's existing "hand-wired ABI, no generated bindings" convention
  (see `CONTEXT.md`).
- If a future milestone wants asset-based UI/menu sound, that's a
  separate, small decision to make then — evaluate Howler (or just the
  Web Audio API directly, given how little surface a handful of one-shot
  clips actually needs) on its own merits at that point, independent of
  this ADR.
