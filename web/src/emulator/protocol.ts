/**
 * Message shapes crossing the `emulatorWorker.ts` boundary. A type-only
 * module -- no runtime globals of its own -- so it's safe to import from
 * both the Worker (`WebWorker` lib, `tsconfig.worker.json`) and its main-
 * thread callers (`DOM` lib, `tsconfig.app.json`) without either project's
 * lib conflicting with the other's (see `tsconfig.worker.json`'s own
 * comment for why those two libs can't both be active in one project).
 */
import type { SaveSlot, SlotSummary } from '../persistence/saveStore'

// Re-exported so the Worker and its callers can name a slot without either
// of them reaching into the persistence layer directly.
export type { SaveSlot, SlotSummary }

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
  | { type: 'load-rom'; romBytes: ArrayBuffer }
  // Save-states (M8, ENG-76). The Worker owns both the wasm instance and
  // the IndexedDB store, so these carry a slot number and nothing else --
  // no state bytes ever cross this boundary in either direction.
  | { type: 'save-state'; slot: SaveSlot }
  | { type: 'load-state'; slot: SaveSlot }
  | { type: 'delete-state'; slot: SaveSlot }
  | { type: 'list-states' }
  | { type: 'audio-start'; sampleRate: number; port: MessagePort }
  | { type: 'audio-resync' }

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
