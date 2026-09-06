/**
 * Message shapes crossing the `emulatorWorker.ts` boundary. A type-only
 * module -- no runtime globals of its own -- so it's safe to import from
 * both the Worker (`WebWorker` lib, `tsconfig.worker.json`) and its main-
 * thread callers (`DOM` lib, `tsconfig.app.json`) without either project's
 * lib conflicting with the other's (see `tsconfig.worker.json`'s own
 * comment for why those two libs can't both be active in one project).
 */

/** Main thread -> Worker. */
export type EmulatorWorkerInbound =
  | { type: 'start'; canvas: OffscreenCanvas; romBytes: ArrayBuffer; inputSab: SharedArrayBuffer }
  | { type: 'reset' }
  | { type: 'audio-start'; sampleRate: number; port: MessagePort }
  | { type: 'audio-resync' }

/** The ENG-62 ring handshake: forwarded down the transferred worklet port
 * as-is, and posted to the main thread (debug/test hook only, see
 * `AudioTestTone.tsx`) with an `'audio-ready'` discriminant added. */
export interface RingHandshake {
  sab: SharedArrayBuffer
  ringByteOffset: number
  controlByteOffset: number
  capacity: number
}

/** Worker -> main thread. */
export type EmulatorWorkerOutbound =
  | { type: 'video-ready'; sab: SharedArrayBuffer; framebufferPtr: number; width: number; height: number }
  | { type: 'status'; status: 'running' }
  | { type: 'status'; status: 'error'; message: string }
  | ({ type: 'audio-ready' } & RingHandshake)
  | { type: 'stats'; fill: number; underrunCount: number }
