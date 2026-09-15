/**
 * Message shapes crossing the `emulatorWorker.ts` boundary. A type-only
 * module -- no runtime globals of its own -- so it's safe to import from
 * both the Worker (`WebWorker` lib, `tsconfig.worker.json`) and its main-
 * thread callers (`DOM` lib, `tsconfig.app.json`) without either project's
 * lib conflicting with the other's (see `tsconfig.worker.json`'s own
 * comment for why those two libs can't both be active in one project).
 */
import type { RomLibraryEntry, SaveSlot, SlotSummary } from '../persistence/saveStore'
import type { Speed } from './speedControl'

// Re-exported so the Worker and its callers can name a slot, or describe a
// library entry, without either of them reaching into the persistence layer
// directly.
export type { RomLibraryEntry, SaveSlot, SlotSummary }
// Re-exported for the same reason: `EmulatorScreen.tsx` names a `Speed` when
// posting `'set-speed'` without importing `speedControl.ts` under a second
// path.
export type { Speed }

/** Which backend `renderer.ts` stood up. Reported back so the UI (and
 * `e2e/renderer.spec.ts`) can state it rather than infer it -- WebGPU
 * availability varies by browser, OS *and* GPU (ENG-57), so "which one am I
 * actually on?" isn't answerable from the user agent. */
export type RendererKind = 'webgpu' | 'canvas2d'

/** Main thread -> Worker. */
export type EmulatorWorkerInbound =
  | {
      type: 'start'
      canvas: OffscreenCanvas
      romBytes: ArrayBuffer
      inputSab: SharedArrayBuffer
      /** Forces a backend instead of preferring WebGPU. Set from the
       * `?renderer=` query parameter, which exists so ENG-70's "force
       * Canvas2D fallback and confirm it still works" is a thing you can
       * actually do -- by hand or from an e2e spec -- on a machine where
       * WebGPU *is* available. */
      preferredRenderer?: RendererKind
    }
  | { type: 'reset' }
  /** Swap the ROM in the *already running* core (ENG-77's file picker).
   * Deliberately not a second `'start'`: that message carries the
   * `OffscreenCanvas`, and `transferControlToOffscreen` is one-shot and
   * irreversible per canvas element (ENG-57), so the handle is detached
   * after the first send. Nothing else about the session needs rebuilding
   * anyway -- `wasm.zig`'s `load_rom` re-inits the whole `Machine`, the
   * renderer and input SAB are bound to the session rather than the ROM,
   * and the audio ring is a module-level global outside `Machine`, so
   * samples keep flowing across the swap with no second handshake. */
  // `name` travels alongside the bytes as of ENG-89: the Worker persists a
  // freshly-picked ROM into the library (`putRom`), and a library record
  // needs a name to show in `RomLibrary.tsx` -- the file's own `File.name`
  // is the only place that name exists, and it never otherwise reaches the
  // Worker (the main thread's own copy lives in `useRomLoader`'s
  // `pendingName` ref, purely for correlating the `'rom-loaded'` reply).
  | { type: 'load-rom'; romBytes: ArrayBuffer; name: string }
  // Save-states (M8, ENG-76). The Worker owns both the wasm instance and
  // the IndexedDB store, so these carry a slot number and nothing else --
  // no state bytes ever cross this boundary in either direction. `slot` can
  // be `RESUME_SLOT` here too (ENG-89): `useResumeAutosave.ts` posts a plain
  // `'save-state'` on `visibilitychange`/`pagehide`, reusing this exact
  // handler rather than inventing a parallel one.
  | { type: 'save-state'; slot: SaveSlot }
  | { type: 'load-state'; slot: SaveSlot }
  | { type: 'delete-state'; slot: SaveSlot }
  | { type: 'list-states' }
  | { type: 'audio-start'; sampleRate: number; port: MessagePort }
  | { type: 'audio-resync' }
  // ENG-90's transport surface (pause/resume is also the plumbing ENG-91's
  // rewind reuses). The timer inside `scheduleLoop` keeps running either
  // way -- only the step it drives is skipped -- so a stall this causes
  // never trips `RESYNC_THRESHOLD_MS`'s catch-up path on resume. Owns no
  // reply: `EmulatorScreen.tsx` tracks its own pause intent locally (the
  // "user paused" vs. "tab hidden" reasons) and this message is fire-and-
  // forget, the same way `'reset'` is.
  | { type: 'pause' }
  | { type: 'resume' }
  // ENG-91's transport additions -- rewind, frame-step, speed.
  //
  // Hold-to-rewind: `'rewind-start'` on keydown/pointerdown, `'rewind-end'`
  // on keyup/pointerup (or a pointer leaving the button mid-hold -- see
  // `EmulatorScreen.tsx`). Independent of `'pause'`/`'resume'`: the Worker
  // gates its tick loop on `rewinding` the same way it already gates on
  // `paused` (see `emulatorWorker.ts`'s two-flag comment), so rewind works
  // whether the transport was running or already paused, and releasing it
  // leaves the loop exactly where `paused` already said it should be --
  // no third message needed to say "resume" or "stay paused".
  | { type: 'rewind-start' }
  | { type: 'rewind-end' }
  // Single-step while paused (`K`) -- a no-op main-thread-side otherwise
  // (see `EmulatorScreen.tsx`'s key handler), but the Worker re-checks
  // `paused` itself too, the same defense-in-depth `'reset'` doesn't need
  // (nothing about `reset` is unsafe while running) but a manual single
  // frame-advance racing a resume genuinely is.
  | { type: 'frame-step' }
  // 0.5x/1x/2x, applied to `scheduleLoop`'s period -- see that function's
  // own doc comment for why a live period change mid-run needs no special
  // handling to avoid a catch-up burst.
  | { type: 'set-speed'; multiplier: Speed }
  // ROM library (ENG-89). The Worker owns IndexedDB, so -- same shape of
  // division as the save-state messages above -- these carry only a hash,
  // never ROM bytes; the bytes for a `'resume-rom'` are already sitting in
  // `LIBRARY_STORE` from when the ROM was first picked.
  | { type: 'list-library' }
  | { type: 'resume-rom'; romHash: string }
  | { type: 'remove-rom'; romHash: string }

/** The ENG-62 ring handshake: forwarded down the transferred worklet port
 * as-is, and posted to the main thread (debug/test hook only, see
 * `AudioOutput.tsx`) with an `'audio-ready'` discriminant added. */
export interface RingHandshake {
  sab: SharedArrayBuffer
  ringByteOffset: number
  controlByteOffset: number
  capacity: number
}

/** Worker -> main thread. */
export type EmulatorWorkerOutbound =
  | { type: 'video-ready'; sab: SharedArrayBuffer; framebufferPtr: number; width: number; height: number }
  | { type: 'status'; status: 'running'; renderer: RendererKind }
  | { type: 'status'; status: 'error'; message: string }
  /** Result of a `'load-rom'`. Deliberately *not* folded into the
   * `'status'` error above: that one means "the emulator never came up"
   * and earns a permanent overlay over a dead screen. A rejected ROM pick
   * leaves a working emulator running -- `load_rom` validates into a
   * throwaway parse before it touches `rom_storage`, so the previous
   * cartridge is genuinely untouched -- and must not read as fatal. */
  | { type: 'rom-loaded'; ok: true }
  | { type: 'rom-loaded'; ok: false; message: string }
  /** ENG-89: names a ROM the main thread didn't itself supply the name for
   * -- either `start()` resolving a boot ROM from the library instead of
   * falling back to the vendored demo, or a `'resume-rom'` swap triggered
   * from `RomLibrary.tsx`. Both land here rather than folding into
   * `'rom-loaded'`: that message's `ok: true` case carries no name at all,
   * relying on the *picker's* own `pendingName` ref
   * (`useRomLoader.ts`) for correlation -- which has nothing to correlate
   * against when nobody on this side picked a file. Lets `useRomLoader.ts`
   * show "cartridge · <name>" for either case the same way it does for a
   * picked one, with no separate readout to build. Not sent for the demo
   * fallback boot: that path is unchanged from before ENG-89, and inventing
   * a name for it here would be new UI surface the ticket didn't ask for. */
  | { type: 'boot-rom'; name: string }
  | ({ type: 'audio-ready' } & RingHandshake)
  | { type: 'stats'; fill: number; underrunCount: number; peak: number; rms: number }
  /** The full slot listing for the loaded ROM, pushed after every save,
   * load, delete and explicit `'list-states'`. A full listing rather than a
   * delta: it is a handful of small records, and a self-correcting snapshot
   * cannot drift out of sync with the database the way applied deltas can. */
  | { type: 'slots'; slots: SlotSummary[] }
  /** A save-state operation that failed -- a rejected blob, a full disk, a
   * slot the user cleared in another tab. Reported rather than thrown into
   * the Worker's `onerror`, which `EmulatorScreen` treats as "the emulator
   * died" and would blank the screen over a failed save. */
  | { type: 'slot-error'; slot: SaveSlot; message: string }
  /** The full library listing, pushed after every load, resume, remove and
   * explicit `'list-library'` -- same "full snapshot, not a delta" reasoning
   * as `'slots'` above. */
  | { type: 'library'; roms: RomLibraryEntry[] }
  /** A library operation that failed -- e.g. a `'resume-rom'` naming a
   * `romHash` no longer in the store (removed from another tab). Reported
   * rather than thrown, for the same "don't blank the screen over this"
   * reason as `'slot-error'`. */
  | { type: 'library-error'; message: string }
