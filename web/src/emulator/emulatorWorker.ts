// ENG-70 (M5)'s dedicated Worker: hosts the *one* wasm instance for the
// whole pipeline -- video (`step_frame`/`load_rom`/`set_input`, ENG-60) and
// audio (the ENG-62 ring buffer + test-tone generator, `audio_ring.zig`)
// alike -- closing the gap the audio-plumbing slice left open (that PR ran
// two independent instances, one per thread, specifically to land audio
// without touching the video path; see `docs/adr/0001-audio-playback-no-
// howler.md`'s "Consequences"). `EmulatorScreen.tsx` transfers the
// `<canvas>` here via `OffscreenCanvas`, and `renderer.ts` decides what
// paints it -- WebGPU where it's actually available, Canvas 2D otherwise
// (ENG-57); input arrives over a shared
// `Int32Array` `Atomics`-published from the main thread (`InputBridge.ts`)
// rather than message-passed, so a keypress reaches `set_input` with no
// postMessage round trip. Audio starts later and separately (needs a user
// gesture on the main thread -- see `AudioOutput.tsx`), following the
// exact ENG-62 handshake the previous slice already built: the
// `AudioWorkletNode`'s `MessagePort` is transferred here, and this Worker
// forwards the wasm memory's `SharedArrayBuffer` plus the ring's byte
// offsets and capacity down it.
import { NesCore, FRAMEBUFFER_HEIGHT, FRAMEBUFFER_WIDTH } from '../wasm/core'
import { CONTROL_INT32_LENGTH, READ_INDEX, targetFillSamples, UNDERRUN_COUNT, WRITE_INDEX } from '../audio/ringLayout'
import { NTSC_FRAME_MS } from '../timing'
import { createRenderer } from './renderer'
import { deleteSlot, getSlot, listSlots, putSlot, SRAM_SLOT, type SaveSlot } from '../persistence/saveStore'
import type { EmulatorWorkerInbound, EmulatorWorkerOutbound, RendererKind, RingHandshake } from './protocol'

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
 * hook (see `AudioOutput.tsx`), not anything the steady-state audio path
 * depends on, so this can be coarse. */
const STATS_INTERVAL_MS = 200

/** Cap on how long `startAudio` will wait for the ring to fill before
 * telling the main thread to connect the worklet anyway (~half a second at
 * 60Hz). A ring that never reaches target means something is wrong
 * upstream, and silent audio forever is a worse answer than audio that
 * starts rough. */
const MAX_PRIME_TICKS = 30

/** How often the cartridge's battery-backed RAM is checked for changes and
 * written out (M8, ENG-76). A real battery holds its charge continuously;
 * polling stands in for the write-detect hook the core doesn't have, and
 * two seconds is short enough that a crash loses no meaningful progress
 * while being long enough that an 8KB compare-and-maybe-write is nothing
 * next to 120 emulated frames. */
const SRAM_AUTOSAVE_INTERVAL_MS = 2_000

let nesCore: NesCore | null = null
let audioPort: MessagePort | null = null
let audioReady = false
let pendingAudioStart: { sampleRate: number; port: MessagePort } | null = null
/** Set while the ring is filling toward target after `startAudio`; called
 * once per tick until it announces `'audio-ready'` and clears itself. */
let awaitAudioPrimed: (() => void) | null = null

/** ENG-61's `(rom_hash, slot)` key, minus the slot -- the identity of the
 * cartridge this Worker is running, computed by the core. Empty until a ROM
 * loads, which is what every save-state handler below checks. */
let romHash = ''

/** The SRAM bytes most recently written to IndexedDB, so the autosave below
 * writes only on an actual change rather than every two seconds forever. */
let persistedSram: Uint8Array | null = null

/** True from the instant a ROM swap replaces the running cartridge until
 * its battery has been restored. See the tick loop's guard. */
let swapPending = false

self.onmessage = (event: MessageEvent<EmulatorWorkerInbound>) => {
  const message = event.data
  switch (message.type) {
    case 'start':
      void start(message.canvas, message.romBytes, message.inputSab, message.preferredRenderer)
      break
    case 'reset':
      nesCore?.reset()
      break
    case 'load-rom':
      loadRom(message.romBytes)
      break
    case 'save-state':
      void saveToSlot(message.slot)
      break
    case 'load-state':
      void loadFromSlot(message.slot)
      break
    case 'delete-state':
      void withSlotErrors(message.slot, () => deleteSlot(romHash, message.slot))
      break
    case 'list-states':
      void publishSlots()
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

/**
 * ENG-77's runtime ROM swap: re-loads the *running* core in place.
 *
 * Safe to call on a live machine because `wasm.zig`'s `load_rom` parses
 * and mapper-checks into a throwaway `validate` pass before it touches
 * `rom_storage` -- a rejected ROM cannot partially overwrite the cartridge
 * currently playing, which is what lets the main thread report the failure
 * as a dismissible line instead of a fatal overlay. A *successful* one
 * runs `Machine.init`, so it is a genuine cold boot (fresh bus, mapper,
 * WRAM and CPU), not the RESET line `'reset'` drives.
 *
 * Nothing else is torn down: the renderer, the transferred canvas and the
 * input SAB all belong to the session rather than the ROM, and the audio
 * ring lives outside `Machine` (see `audio_ring.zig`), so `stepAudioFrame`
 * keeps feeding the same ring the worklet is already reading.
 */
function loadRom(romBytes: ArrayBuffer): void {
  if (!nesCore) {
    // Only reachable by picking a file before the Worker finished booting;
    // an honest "not yet" beats silently dropping the message.
    post({ type: 'rom-loaded', ok: false, message: 'The emulator is still starting up -- try again in a moment.' })
    return
  }

  // Set before the call, not after: the moment `load_rom` succeeds the core
  // is running a different cartridge, and the tick loop must not advance it
  // until that cartridge's battery has been restored (M8).
  swapPending = true
  try {
    nesCore.loadRom(new Uint8Array(romBytes))
  } catch (err: unknown) {
    swapPending = false
    // `RomLoadError extends Error`, so one check covers both.
    const message = err instanceof Error ? err.message : String(err)
    post({ type: 'rom-loaded', ok: false, message })
    return
  }

  // The ring still holds ~50ms of the *previous* game's samples, primed
  // ahead of the worklet's read index. Without this they play over the new
  // game's first frames. Same forward-to-the-worklet path `'audio-resync'`
  // uses, and for the same reason: `read_index` is the worklet's own field.
  audioPort?.postMessage({ type: 'resync' })
  post({ type: 'rom-loaded', ok: true })
  // The save-state identity changed with the cartridge: a different
  // `rom_hash` means a different set of slots, and the old ROM's battery
  // must not follow the new one. Not awaited -- `'rom-loaded'` reports that
  // the *ROM* loaded, which it did; `swapPending` is what holds emulation
  // until the rest of the swap has landed.
  void adoptRom(nesCore)
}

async function start(
  canvas: OffscreenCanvas,
  romBytes: ArrayBuffer,
  inputSab: SharedArrayBuffer,
  preferredRenderer?: RendererKind,
): Promise<void> {
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

  let renderer
  try {
    renderer = await createRenderer(canvas, FRAMEBUFFER_WIDTH, FRAMEBUFFER_HEIGHT, preferredRenderer)
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err)
    post({ type: 'status', status: 'error', message })
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
  await adoptRom(core)

  post({ type: 'status', status: 'running', renderer: renderer.kind })
  scheduleSramAutosave(core)
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
    // Held across a ROM swap until the new cartridge's battery is back in
    // place -- see `adoptRom`. Skipping ticks for the length of one
    // IndexedDB read is invisible; letting the new game boot against a
    // blank save file it should have had would not be.
    if (swapPending) return
    renderer.draw(core.stepFrame())
    // Skipped until a user gesture creates the `AudioContext` and this
    // Worker's `startAudio` runs -- no point producing test-tone samples
    // (with the wrong, still-default sample rate) that nothing will ever
    // consume.
    if (audioReady) {
      core.stepAudioFrame()
      awaitAudioPrimed?.()
    }
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
  // A separate `Int32Array` view from the worklet's own, backed by the exact
  // same bytes. Shared by the prime check and the stats push.
  const control = new Int32Array(nesCore.memory.buffer, handshake.controlByteOffset, CONTROL_INT32_LENGTH)

  audioReady = true // the tick loop starts producing samples from here on

  // Nothing is handed to the worklet until the ring has ENG-62's target
  // fill in it -- neither the ring itself nor the main thread's cue to
  // connect the node.
  //
  // Both halves matter, and the second one is the non-obvious one.
  // Chrome calls `process()` on an `AudioWorkletNode` that exists in a
  // running context even before it's connected to anything, so a worklet
  // holding a still-empty ring spends that whole window counting underruns
  // on a stream that hasn't started. Measured here: ~11-13 render quanta
  // (~35ms) of them, and *deferring only the connect made it worse*, since
  // that lengthens the window. Withholding the handshake instead lands the
  // worklet in its own pre-init path, which outputs silence and counts
  // nothing (see `audioRingProcessor.js`'s `process`) -- so the underrun
  // counter means what it should: "we were playing and starved", never
  // "we hadn't started yet".
  const primeTarget = targetFillSamples(sampleRate)
  let ticksWaited = 0
  awaitAudioPrimed = () => {
    ticksWaited += 1
    const fill = (Atomics.load(control, WRITE_INDEX) - Atomics.load(control, READ_INDEX)) >>> 0
    if (fill < primeTarget && ticksWaited < MAX_PRIME_TICKS) return
    awaitAudioPrimed = null

    port.postMessage({ type: 'init', ...handshake })
    // Debug/test hook aside (see `AudioOutput.tsx`), this is the cue to
    // connect the node -- a `SharedArrayBuffer` is shared by structured
    // clone, never transferred, so this and the worklet's view are two
    // independent windows onto the exact same bytes, not copies.
    post({ type: 'audio-ready', ...handshake })
  }

  // A second view over the same shared bytes the worklet reads from --
  // see the handshake above; `SharedArrayBuffer`s are shared, not moved.
  const ring = new Float32Array(nesCore.memory.buffer, handshake.ringByteOffset, handshake.capacity)
  scheduleStats(control, ring) // no stop handle kept -- see `start`'s matching comment
}

/** Periodically reads the shared control block and pushes a summary to the
 * main thread -- see `STATS_INTERVAL_MS`'s comment. No stop handle: see
 * `start`'s comment on why nothing here manages subsystem lifecycles
 * independently of the whole Worker's. */
function scheduleStats(control: Int32Array, ring: Float32Array): void {
  setInterval(() => {
    const write = Atomics.load(control, WRITE_INDEX)
    const read = Atomics.load(control, READ_INDEX)
    const fill = (write - read) >>> 0
    const underrunCount = Atomics.load(control, UNDERRUN_COUNT)
    const { peak, rms } = measureRing(ring, write, fill)
    post({ type: 'stats', fill, underrunCount, peak, rms })
  }, STATS_INTERVAL_MS)
}

/** How many of the most recently written samples `measureRing` summarizes
 * -- ~21ms at 48kHz, comfortably more than one period of anything in the
 * audible band, and small enough to stay cheap at `STATS_INTERVAL_MS`. */
const CONTENT_WINDOW_SAMPLES = 1024

/**
 * Peak and RMS of the samples most recently published to the ring.
 *
 * Fill and underrun counts (the only things this Worker used to report)
 * describe the *plumbing*: they look identical whether the ring is
 * carrying a game's audio or a steady stream of zeroes. Through M5 that
 * was the whole story, because the producer was a test tone that could
 * not be silent. Now that real APU output crosses this ring (ENG-71), the
 * difference between "working" and "silently shipping nothing" is exactly
 * what a test needs to see -- hence measuring content, not just flow.
 *
 * Reads without `Atomics`: these are plain sample slots, not the control
 * block, and a torn read of one f32 slot cannot meaningfully skew a
 * 1024-sample summary. Debug/test hook only -- no production path reads it.
 */
function measureRing(ring: Float32Array, write: number, fill: number): { peak: number; rms: number } {
  const count = Math.min(CONTENT_WINDOW_SAMPLES, fill)
  if (count === 0) return { peak: 0, rms: 0 }
  const mask = ring.length - 1
  let peak = 0
  let sumSquares = 0
  for (let i = 0; i < count; i++) {
    const sample = ring[(write - count + i) & mask]
    const magnitude = Math.abs(sample)
    if (magnitude > peak) peak = magnitude
    sumSquares += sample * sample
  }
  return { peak, rms: Math.sqrt(sumSquares / count) }
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


// ---------------------------------------------- save-states & SRAM (M8)

/** Pushes the current slot listing to the main thread. A full snapshot
 * after every mutation -- see `protocol.ts`'s `'slots'` for why not deltas. */
async function publishSlots(): Promise<void> {
  if (!romHash) return
  post({ type: 'slots', slots: await listSlots(romHash) })
}

/**
 * Runs one slot operation, republishes the listing, and turns any failure
 * into a `'slot-error'` message.
 *
 * Deliberately *not* left to reject: an unhandled rejection in a Worker
 * surfaces on the main thread as `worker.onerror`, which
 * `EmulatorScreen.tsx` treats as "the emulator died" and blanks the screen
 * behind an error overlay. A save that failed because the disk is full
 * should cost the user a message, not their running game.
 */
async function withSlotErrors(slot: SaveSlot, run: (core: NesCore) => Promise<unknown>): Promise<void> {
  const core = nesCore
  if (!core || !romHash) {
    post({ type: 'slot-error', slot, message: 'No ROM is loaded yet.' })
    return
  }
  try {
    await run(core)
    await publishSlots()
  } catch (err: unknown) {
    // `SaveStateError` (a rejected blob) and a raw IndexedDB failure read
    // the same way from here, and both are `Error`s.
    post({ type: 'slot-error', slot, message: err instanceof Error ? err.message : String(err) })
  }
}

function saveToSlot(slot: SaveSlot): Promise<void> {
  return withSlotErrors(slot, (core) => putSlot(romHash, slot, core.saveState()))
}

function loadFromSlot(slot: SaveSlot): Promise<void> {
  return withSlotErrors(slot, async (core) => {
    const blob = await getSlot(romHash, slot)
    // An empty slot is a message, not a silent no-op: the click did
    // something as far as the user is concerned, so it has to report back.
    if (!blob) throw new Error(`Slot ${slot} is empty.`)
    core.loadState(blob)
    // The restored machine's SRAM is now whatever the state carried, which
    // is not what the battery file holds -- rebaselining here stops the
    // autosave from either writing it back immediately or, worse, deciding
    // nothing changed and leaving the battery stale.
    persistedSram = core.sram()
  })
}

/**
 * Takes on a newly-loaded cartridge's save-state identity: its `rom_hash`
 * (which keys every slot), its battery, and its slot listing.
 *
 * Called from both places a ROM can arrive -- the initial boot and ENG-77's
 * runtime file picker -- because a swap changes every one of those. Without
 * it the slot browser would keep showing the previous game's saves, and the
 * next save would be filed under the wrong cartridge.
 *
 * The battery goes back *before* the first emulated frame of the new ROM
 * (`swapPending` is what enforces that): a real cartridge's RAM is already
 * holding its contents at power-on, and most games read their save file
 * during boot.
 */
async function adoptRom(core: NesCore): Promise<void> {
  romHash = core.romHash()
  // Cleared, not carried over: it is the previous cartridge's RAM, and
  // leaving it would let the autosave decide "nothing changed" and never
  // write the new game's battery at all.
  persistedSram = null
  try {
    await restoreSram(core)
  } finally {
    swapPending = false
  }
  await publishSlots()
}

/** Loads the reserved `"sram"` slot into the cartridge, if this ROM has one
 * stored. A stored record the core rejects (wrong length, e.g. written by
 * an older build) is reported and skipped rather than fatal -- the game
 * still runs, it just starts from a blank battery. */
async function restoreSram(core: NesCore): Promise<void> {
  try {
    const stored = await getSlot(romHash, SRAM_SLOT)
    if (stored) core.loadSram(stored)
    persistedSram = core.sram()
  } catch (err: unknown) {
    post({
      type: 'slot-error',
      slot: SRAM_SLOT,
      message: err instanceof Error ? err.message : String(err),
    })
  }
}

/** Polls the cartridge's RAM and writes it out when it actually changes --
 * ENG-61's "auto-saved on write", approximated by a poll because the core
 * exposes the bytes but not a write hook. See
 * `SRAM_AUTOSAVE_INTERVAL_MS`. No stop handle, like every other timer here:
 * this Worker's lifecycle is the emulator's. */
function scheduleSramAutosave(core: NesCore): void {
  setInterval(() => {
    const current = core.sram()
    // A cartridge whose RAM is still entirely zero has never written a save
    // file, and storing 8KB of nothing for every ROM the user merely opens
    // is pure noise in the slot browser. Once *something* has been
    // persisted, though, later changes are written unconditionally --
    // including a game deliberately clearing its save back to zeroes, which
    // this guard must not swallow.
    if (persistedSram === null && current.every((b) => b === 0)) return
    if (persistedSram !== null && equalBytes(current, persistedSram)) return
    persistedSram = current
    void withSlotErrors(SRAM_SLOT, () => putSlot(romHash, SRAM_SLOT, current))
  }, SRAM_AUTOSAVE_INTERVAL_MS)
}

function equalBytes(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false
  return true
}
