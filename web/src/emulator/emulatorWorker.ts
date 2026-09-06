// ENG-70 (M5)'s dedicated Worker: hosts the *one* wasm instance for the
// whole pipeline -- video (`step_frame`/`load_rom`/`set_input`, ENG-60) and
// audio (the ENG-62 ring buffer + test-tone generator, `audio_ring.zig`)
// alike -- closing the gap the audio-plumbing slice left open (that PR ran
// two independent instances, one per thread, specifically to land audio
// without touching the video path; see `docs/adr/0001-audio-playback-no-
// howler.md`'s "Consequences"). `EmulatorScreen.tsx` transfers the
// `<canvas>` here via `OffscreenCanvas`; input arrives over a shared
// `Int32Array` `Atomics`-published from the main thread (`InputBridge.ts`)
// rather than message-passed, so a keypress reaches `set_input` with no
// postMessage round trip. Audio starts later and separately (needs a user
// gesture on the main thread -- see `AudioTestTone.tsx`), following the
// exact ENG-62 handshake the previous slice already built: the
// `AudioWorkletNode`'s `MessagePort` is transferred here, and this Worker
// forwards the wasm memory's `SharedArrayBuffer` plus the ring's byte
// offsets and capacity down it.
import { NesCore, FRAMEBUFFER_HEIGHT, FRAMEBUFFER_WIDTH } from '../wasm/core'
import { CONTROL_INT32_LENGTH, READ_INDEX, UNDERRUN_COUNT, WRITE_INDEX } from '../audio/ringLayout'
import { NTSC_FRAME_MS } from '../timing'
import type { EmulatorWorkerInbound, EmulatorWorkerOutbound, RingHandshake } from './protocol'

/** Typed wrapper over `self.postMessage` for messages to the main thread,
 * so a shape drifting out of sync with `protocol.ts` is a compile error
 * here rather than something only `EmulatorScreen.tsx`'s handler notices at
 * runtime. */
function post(message: EmulatorWorkerOutbound): void {
  self.postMessage(message)
}

/** A stall longer than this (a backgrounded tab resuming, a slow GC pause,
 * etc.) is resynced to "now" rather than caught up frame-by-frame -- one
 * tick's worth of video and audio are both just skipped ahead, deliberately
 * symmetric now that one loop drives both (see `scheduleLoop`'s doc
 * comment). ENG-62 is explicit that audio must never fast-forward through a
 * real backlog; treating video the same way trades a little responsiveness
 * after a rare stall for one pacing policy instead of two. */
const RESYNC_THRESHOLD_MS = 250

/** How often to push `{ type: 'stats' }` to the main thread -- a debug/test
 * hook (see `AudioTestTone.tsx`), not anything the steady-state audio path
 * depends on, so this can be coarse. */
const STATS_INTERVAL_MS = 200

let nesCore: NesCore | null = null
let audioPort: MessagePort | null = null
let audioReady = false
let pendingAudioStart: { sampleRate: number; port: MessagePort } | null = null

self.onmessage = (event: MessageEvent<EmulatorWorkerInbound>) => {
  const message = event.data
  switch (message.type) {
    case 'start':
      void start(message.canvas, message.romBytes, message.inputSab)
      break
    case 'reset':
      nesCore?.reset()
      break
    case 'audio-start':
      // `nesCore` not existing yet is a real (if narrow) race -- a click
      // fast enough to beat this Worker's own async boot -- not a bug to
      // paper over with a dropped message; queue it for `start` to pick up.
      if (nesCore) startAudio(message.sampleRate, message.port)
      else pendingAudioStart = { sampleRate: message.sampleRate, port: message.port }
      break
    case 'audio-resync':
      // Forwarded, not handled here: `read_index` is the worklet's own
      // field (see `audio_ring.zig`'s module doc comment on ownership), so
      // only it can actually perform the resync.
      audioPort?.postMessage({ type: 'resync' })
      break
  }
}

async function start(canvas: OffscreenCanvas, romBytes: ArrayBuffer, inputSab: SharedArrayBuffer): Promise<void> {
  const core = await NesCore.create()
  const input = new Int32Array(inputSab)

  // Video debug hook (see `e2e/helpers.ts`'s `readFramebuffer`) -- posted
  // immediately, not gated on a ROM loading successfully: the framebuffer
  // is a static buffer that's valid (if blank) the instant the module
  // exists. Reading it while `stepFrame` is mid-write can observe a torn
  // frame (plain stores, no synchronization -- the ENG-62 treatment is
  // reserved for the audio ring, which actually needs it); harmless for a
  // debug/test accessor polling for a settled shape, same as real screen
  // tearing being a non-issue for a human glancing at a monitor.
  post({
    type: 'video-ready',
    // See `startAudio`'s matching comment: `memory.buffer`'s TS type is
    // plain `ArrayBuffer`, but `shared_memory = true` (ENG-56) makes it a
    // `SharedArrayBuffer` at runtime.
    sab: core.memory.buffer as unknown as SharedArrayBuffer,
    framebufferPtr: core.getFramebufferPtr(),
    width: FRAMEBUFFER_WIDTH,
    height: FRAMEBUFFER_HEIGHT,
  })

  const ctx = canvas.getContext('2d')
  if (!ctx) {
    post({ type: 'status', status: 'error', message: 'Canvas 2D is not available in this browser.' })
    return
  }

  try {
    core.loadRom(new Uint8Array(romBytes))
  } catch (err: unknown) {
    // `RomLoadError extends Error`, so one check covers both.
    const message = err instanceof Error ? err.message : String(err)
    post({ type: 'status', status: 'error', message })
    return
  }

  nesCore = core
  post({ type: 'status', status: 'running' })
  if (pendingAudioStart) {
    startAudio(pendingAudioStart.sampleRate, pendingAudioStart.port)
    pendingAudioStart = null
  }

  // No stop handle kept: this Worker's whole lifecycle is the emulator's --
  // `EmulatorScreen.tsx`'s cleanup terminates the Worker outright rather
  // than trying to gracefully stop timers one subsystem at a time.
  scheduleLoop(() => {
    // A single shared counter, not per-controller: this app only ever
    // drives controller 0 (see `InputBridge.ts`), so there's nothing a
    // second slot would add yet.
    const buttons = Atomics.load(input, 0)
    core.setInput(0, buttons)
    const framebuffer = core.stepFrame()
    ctx.putImageData(new ImageData(framebuffer, FRAMEBUFFER_WIDTH, FRAMEBUFFER_HEIGHT), 0, 0)
    // Skipped until a user gesture creates the `AudioContext` and this
    // Worker's `startAudio` runs -- no point producing test-tone samples
    // (with the wrong, still-default sample rate) that nothing will ever
    // consume.
    if (audioReady) core.stepAudioFrame()
  }, NTSC_FRAME_MS)
}

function startAudio(sampleRate: number, port: MessagePort): void {
  if (!nesCore) return // guarded by the `pendingAudioStart` queue above; unreachable otherwise
  audioPort = port
  nesCore.initAudio(sampleRate)

  const handshake: RingHandshake = {
    // `WebAssembly.Memory.buffer`'s TS type is plain `ArrayBuffer`, but
    // `shared_memory = true` (ENG-56) means it's actually a
    // `SharedArrayBuffer` at runtime -- TS has no way to express "this
    // memory is shared" on the type itself.
    sab: nesCore.memory.buffer as unknown as SharedArrayBuffer,
    ringByteOffset: nesCore.getAudioRingPtr(),
    controlByteOffset: nesCore.getAudioRingControlPtr(),
    capacity: nesCore.getAudioRingCapacity(),
  }
  port.postMessage({ type: 'init', ...handshake })
  // Debug/test hook only (see `AudioTestTone.tsx`) -- a `SharedArrayBuffer`
  // is shared by structured clone, never transferred, so this and the
  // worklet's view above are two independent windows onto the exact same
  // bytes, not copies.
  post({ type: 'audio-ready', ...handshake })

  audioReady = true
  scheduleStats(nesCore.memory, handshake.controlByteOffset) // no stop handle kept -- see `start`'s matching comment
}

/** Periodically reads the shared control block and pushes a summary to the
 * main thread -- see `STATS_INTERVAL_MS`'s comment. A separate `Int32Array`
 * view from the worklet's own, but backed by the exact same bytes. No stop
 * handle: see `start`'s comment on why nothing here manages subsystem
 * lifecycles independently of the whole Worker's. */
function scheduleStats(memory: WebAssembly.Memory, controlByteOffset: number): void {
  const control = new Int32Array(memory.buffer, controlByteOffset, CONTROL_INT32_LENGTH)
  setInterval(() => {
    const write = Atomics.load(control, WRITE_INDEX)
    const read = Atomics.load(control, READ_INDEX)
    const fill = (write - read) >>> 0
    const underrunCount = Atomics.load(control, UNDERRUN_COUNT)
    post({ type: 'stats', fill, underrunCount })
  }, STATS_INTERVAL_MS)
}

/**
 * Self-correcting `setTimeout` loop: calls `step` once per nominal tick,
 * tracking an absolute `nextTick` time rather than always waiting a fixed
 * delay, so the long-run average rate stays correct even though individual
 * `setTimeout` firings are never exact. `requestAnimationFrame` (what M4's
 * single-threaded host used) isn't an option here -- it doesn't exist in a
 * dedicated Worker's global scope -- which turns out not to cost anything:
 * unlike `requestAnimationFrame`, `setTimeout` was never coupled to the
 * display's refresh rate in the first place, so the multi-frame catch-up
 * burst that coupling used to require (see the old `EmulatorScreen.tsx`'s
 * `MAX_CATCHUP_FRAMES`) has no equivalent problem to solve here. No stop
 * handle: see this function's only caller for why.
 */
function scheduleLoop(step: () => void, frameMs: number): void {
  let nextTick = performance.now()

  const tick = () => {
    const now = performance.now()
    if (now - nextTick > RESYNC_THRESHOLD_MS) nextTick = now // see RESYNC_THRESHOLD_MS's own comment
    step()
    nextTick += frameMs
    setTimeout(tick, Math.max(0, nextTick - performance.now()))
  }
  setTimeout(tick, 0)
}
