// ENG-70 (M5)'s dedicated audio Worker: hosts one wasm instance whose only
// job is `core/src/audio_ring.zig`'s ring buffer + test-tone generator (see
// that file's module doc comment for the producer/consumer protocol this
// forwards to the worklet). Deliberately a *second*, independent wasm
// instance from `EmulatorScreen.tsx`'s main-thread one: this slice adds
// audio plumbing alongside the existing M4 video/game host rather than
// migrating video into this Worker too (see `docs/adr/0001-audio-playback-
// no-howler.md`'s "Consequences" and ENG-70's still-open acceptance
// criteria for what that follow-up work is).
//
// Runs the handshake ENG-62 designed: the main thread creates the
// `AudioContext` (needs a user gesture) and transfers its
// `AudioWorkletNode`'s `MessagePort` here (see `AudioTestTone.tsx`); this
// Worker instantiates wasm, tells it the device's real sample rate, and
// forwards the wasm memory's `SharedArrayBuffer` plus the ring's byte
// offsets and capacity down that port so the worklet can build its own
// views directly over shared memory. In steady state there is no more
// messaging at all -- only shared-memory reads/writes on both sides, plus
// the occasional `resync` (see below).
import initCore from '../wasm/nes_core.wasm?init'
import { CONTROL_INT32_LENGTH, READ_INDEX, UNDERRUN_COUNT, WRITE_INDEX } from './ringLayout'
import { NTSC_FRAME_MS } from '../timing'

/** The subset of `wasm.zig`'s ABI this Worker actually calls -- the audio-
 * ring exports added for ENG-62/M5, none of `core.ts`'s game-oriented
 * surface (this instance never loads a ROM or steps CPU/PPU frames). */
interface AudioExports {
  memory: WebAssembly.Memory
  init(sampleRate: number): void
  get_audio_ring_ptr(): number
  get_audio_ring_control_ptr(): number
  get_audio_ring_capacity(): number
  step_audio_frame(): void
}

/** What the worklet needs to build its own views over the shared ring --
 * posted down the transferred port, and separately to the main thread
 * (debug/test hook only) via this Worker's own implicit reply channel. */
interface RingHandshake {
  type: 'init'
  sab: SharedArrayBuffer
  ringByteOffset: number
  controlByteOffset: number
  capacity: number
}

type InboundMessage = { type: 'start'; sampleRate: number; port: MessagePort } | { type: 'resync' } | { type: 'stop' }

/**
 * A stall longer than this (a backgrounded tab resuming, a slow GC pause,
 * etc.) is resynced to "now" rather than caught up frame-by-frame. See
 * `EmulatorScreen.tsx`'s `MAX_CATCHUP_FRAMES` for why the *video* host
 * instead bounds a catch-up burst to a handful of frames -- a valid choice
 * there, but ENG-62 is explicit that audio must never fast-forward through
 * a real backlog. The two together cover both cases this loop can hit:
 * brief scheduling jitter (the next tick just runs a little late, no
 * special handling needed) and "the tab was gone for a while" (this
 * resync).
 */
const RESYNC_THRESHOLD_MS = 250

/** How often to push `{ type: 'stats' }` to the main thread -- a debug/test
 * hook (see `AudioTestTone.tsx`'s `getDebugInfo`), not anything the steady-
 * state audio path depends on, so this can be coarse. */
const STATS_INTERVAL_MS = 200

/** Set once `start` completes; used to forward a `resync` message from the
 * main thread to the worklet, and to stop the tick loop and stats push on
 * `stop`. */
let workletPort: MessagePort | null = null
let stopLoop: (() => void) | null = null
let stopStats: (() => void) | null = null

self.onmessage = (event: MessageEvent<InboundMessage>) => {
  const message = event.data
  switch (message.type) {
    case 'start':
      void start(message.sampleRate, message.port)
      break
    case 'resync':
      // Forwarded, not handled here: `read_index` is the worklet's own
      // field (see `audio_ring.zig`'s module doc comment on ownership), so
      // only it can actually perform the resync.
      workletPort?.postMessage({ type: 'resync' })
      break
    case 'stop':
      stopLoop?.()
      stopLoop = null
      stopStats?.()
      stopStats = null
      break
  }
}

async function start(sampleRate: number, port: MessagePort): Promise<void> {
  workletPort = port

  const instance = await initCore()
  const exports = instance.exports as unknown as AudioExports
  exports.init(sampleRate)

  const handshake: RingHandshake = {
    type: 'init',
    // `WebAssembly.Memory.buffer`'s TS type is plain `ArrayBuffer`, but
    // `shared_memory = true` (ENG-56) means it's actually a
    // `SharedArrayBuffer` at runtime -- TS has no way to express "this
    // memory is shared" on the type itself.
    sab: exports.memory.buffer as unknown as SharedArrayBuffer,
    ringByteOffset: exports.get_audio_ring_ptr(),
    controlByteOffset: exports.get_audio_ring_control_ptr(),
    capacity: exports.get_audio_ring_capacity(),
  }
  port.postMessage(handshake)
  // Debug/test hook only (see `AudioTestTone.tsx`'s `getDebugInfo`) -- a
  // `SharedArrayBuffer` is shared by structured clone, never transferred,
  // so this and the worklet's view above are two independent windows onto
  // the exact same bytes, not copies.
  self.postMessage({ ...handshake, type: 'ready' })

  stopLoop = scheduleLoop(() => exports.step_audio_frame(), NTSC_FRAME_MS)
  stopStats = scheduleStats(exports.memory.buffer, handshake.controlByteOffset)
}

/** Periodically reads the shared control block and pushes a summary to the
 * main thread -- see `STATS_INTERVAL_MS`'s comment. A separate `Int32Array`
 * view from the worklet's own, but backed by the exact same bytes. */
function scheduleStats(memory: ArrayBuffer, controlByteOffset: number): () => void {
  const control = new Int32Array(memory, controlByteOffset, CONTROL_INT32_LENGTH)
  const id = setInterval(() => {
    const write = Atomics.load(control, WRITE_INDEX)
    const read = Atomics.load(control, READ_INDEX)
    const fill = (write - read) >>> 0
    const underrunCount = Atomics.load(control, UNDERRUN_COUNT)
    self.postMessage({ type: 'stats', fill, underrunCount })
  }, STATS_INTERVAL_MS)
  return () => clearInterval(id)
}

/**
 * Self-correcting `setTimeout` loop: calls `step` once per nominal tick,
 * tracking an absolute `nextTick` time rather than always waiting a fixed
 * delay, so the long-run average rate stays correct even though individual
 * `setTimeout` firings are never exact. `requestAnimationFrame` (what
 * `EmulatorScreen.tsx` uses) isn't an option here -- it doesn't exist in a
 * dedicated Worker's global scope.
 */
function scheduleLoop(step: () => void, frameMs: number): () => void {
  let nextTick = performance.now()
  let timeoutId: ReturnType<typeof setTimeout>

  const tick = () => {
    const now = performance.now()
    if (now - nextTick > RESYNC_THRESHOLD_MS) nextTick = now // see RESYNC_THRESHOLD_MS's own comment
    step()
    nextTick += frameMs
    timeoutId = setTimeout(tick, Math.max(0, nextTick - performance.now()))
  }
  timeoutId = setTimeout(tick, 0)
  return () => clearTimeout(timeoutId)
}
