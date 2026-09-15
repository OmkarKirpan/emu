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
import { createRenderer, type FrameRenderer } from './renderer'
import { CAPTURE_INTERVAL_FRAMES, RewindRing } from './rewindRing'
import { DEFAULT_SPEED, type Speed } from './speedControl'
import {
  deleteRom,
  deleteSlot,
  getRom,
  getSlot,
  listRoms,
  listSlots,
  putRom,
  putSlot,
  RESUME_SLOT,
  SRAM_SLOT,
  touchRom,
  type RomLibraryEntry,
  type SaveSlot,
} from '../persistence/saveStore'
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

/** How often the running game's exact position is autosaved into the
 * reserved `RESUME_SLOT` (ENG-89), independent of the main-thread
 * `visibilitychange`/`pagehide` triggers (`useResumeAutosave.ts`) that are
 * this feature's *primary* save path. Those are best-effort: `pagehide` in
 * particular can lose the race against this very Worker being terminated
 * mid-write (`EmulatorScreen.tsx`'s cleanup calls `worker.terminate()`), and
 * a tab that's simply killed by the OS (mobile, especially) may fire
 * neither event at all. This interval is the backstop that bounds how much
 * of a session that scenario can cost. Coarser than `SRAM_AUTOSAVE_
 * INTERVAL_MS`: a full save-state is a bigger serialize (~20KB of CPU/
 * PPU/APU/mapper state, see `savestate.zig`) than an 8KB RAM compare, and
 * losing up to this long of unsaved play to a hard crash -- a rare event --
 * is a reasonable trade against paying that serialize cost every two
 * seconds for the length of every session. */
const RESUME_AUTOSAVE_INTERVAL_MS = 15_000

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

/** The `RESUME_SLOT` save-state bytes most recently written to IndexedDB
 * (by either path -- the explicit `'save-state'` a hide/pagehide triggers,
 * or `scheduleResumeAutosave`'s periodic backstop below), so the backstop
 * writes only when the position has actually changed. Reset to `null` on
 * every ROM adoption; see `restoreResume`. */
let persistedResumeState: Uint8Array | null = null

/** True from the instant a ROM swap replaces the running cartridge until
 * its battery has been restored. See the tick loop's guard. */
let swapPending = false

/**
 * ENG-90's transport pause. Guards only the tick loop's `stepFrame`/
 * `stepAudioFrame` calls, not the loop's own `setTimeout` schedule -- see
 * `scheduleLoop`'s doc comment for why leaving the timer running is what
 * keeps a resume from ever looking like a stall. Message handlers
 * (`'reset'`, `'load-rom'`, save-states) are untouched by this flag: they
 * run off the message, not the loop, so `--reset` and a ROM swap both keep
 * working while paused (the new state just doesn't get *drawn* until the
 * loop steps again), and a save/load round-trip is exactly as safe paused
 * as running.
 */
let paused = false

/**
 * ENG-91's rewind gate, parallel to `paused` above but independent of it --
 * see `protocol.ts`'s `'rewind-start'`/`'rewind-end'` doc comment for why
 * two flags (checked together, `if (paused || rewinding) return`, in the
 * tick loop below) is what lets a rewind hold work identically whether the
 * transport was running or already user-paused, with no third message
 * needed to say which one to return to on release. Never touched by
 * `'pause'`/`'resume'` themselves.
 */
let rewinding = false

/** setInterval handle for the active rewind hold's own stepping loop
 * (`startRewind`), or `null` when no hold is in progress. Distinct from
 * `scheduleLoop`'s timer, which keeps running (and skipped) throughout the
 * hold exactly as it does under `paused` -- see that function's own
 * comment. */
let rewindTimer: ReturnType<typeof setInterval> | null = null

/** ENG-91's per-cartridge rewind history -- cleared in `adoptRom`, appended
 * to every `CAPTURE_INTERVAL_FRAMES`th forward frame by
 * `advanceAndMaybeCapture`, and walked backwards by `startRewind`. See
 * `rewindRing.ts`'s own module comment for why this is a plain capped stack
 * rather than a circular buffer with a cursor. */
const rewindRing = new RewindRing()

/** Counts forward frames (normal play *and* frame-step -- anything that
 * calls `advanceAndMaybeCapture`) since the last rewind capture, wrapping
 * at `CAPTURE_INTERVAL_FRAMES`. Reset alongside the ring itself in
 * `adoptRom`, and after a manual slot load (`loadFromSlot`) re-baselines
 * the ring's top -- see that function's own comment. */
let framesSinceCapture = 0

/** ENG-91's speed multiplier, applied to `NTSC_FRAME_MS` by `scheduleLoop`'s
 * period getter -- see `setSpeed` for the audio-muting side of a change. */
let speedMultiplier: Speed = DEFAULT_SPEED

/**
 * The renderer `start()` stands up, hoisted to module scope (rather than
 * kept as a local inside `start()`, as it was before ENG-91) so
 * `handleFrameStep` and `startRewind` -- both driven by a plain
 * `self.onmessage` case, not the tick loop's own closure -- can paint a
 * frame outside of `scheduleLoop`'s regular cadence. `null` until `start()`
 * resolves; every reader below already guards on `nesCore` existing at the
 * same point in the boot sequence, so the two are checked together.
 */
let renderer: FrameRenderer | null = null

/**
 * Rewind holds and non-1x speeds mute the worklet by reusing ENG-90's own
 * `paused` bypass (`audioRingProcessor.js`'s `paused` branch) rather than
 * inventing a second silence path -- see this file's ENG-91 message
 * handlers. `audioMuted` is *this file's* record of which state the
 * worklet was last told to be in, independent of `paused`/`rewinding`/
 * `speedMultiplier` individually, so `syncAudioMute` sends a message only on
 * an actual transition -- exactly the redundant-call guard `'resume'`
 * already had one-off (`if (!paused) break`), generalized to cover every
 * reason the worklet might need muting now that there is more than one.
 */
let audioMuted = false

/** ENG-91's chosen rewind rate: fast enough to be worth holding a key for,
 * slow enough to track visually. Stepping back one `CAPTURE_INTERVAL_
 * FRAMES`-frame capture on every real video-frame tick (~16.6ms) would
 * consume ~166ms of game time per 16.6ms of wall time -- a ~10x rewind,
 * too fast to see anything at. Instead `startRewind`'s own timer ticks
 * every `REWIND_TICK_MS`, chosen so one capture (166ms of game time) plays
 * back over roughly `REWIND_SPEED_MULTIPLIER` times less wall time than it
 * took to play forward -- i.e. a visibly-controllable ~2.5x rewind, not a
 * blur and not a slideshow. */
const REWIND_SPEED_MULTIPLIER = 2.5
const REWIND_TICK_MS = (CAPTURE_INTERVAL_FRAMES * NTSC_FRAME_MS) / REWIND_SPEED_MULTIPLIER

/** The audio ring's shared control-block view and this session's target
 * fill, captured once in `startAudio` so `beginAudioReprime` (run from an
 * unrelated `'resume'` message, long after `startAudio`'s own locals have
 * gone out of scope) can still reach them. */
let audioControl: Int32Array | null = null
let audioPrimeTarget = 0

/** Whether `startAudio`'s cold-start priming has finished -- i.e. the
 * worklet has its `'init'` and the main thread has its `'audio-ready'`.
 * Distinct from `audioReady`, which flips the moment `startAudio` runs,
 * long before either message goes out.
 *
 * Pause/resume must not touch the audio side until this is true. Before
 * it, the worklet is still in its pre-init path (no ring, silence, nothing
 * counted) and the only thing that will ever send it `'init'` is the
 * cold-start hook in `awaitAudioPrimed`. A `'resume'` that installed
 * `beginAudioReprime`'s hook over it would drop that handshake for good --
 * the node never connects and the session stays silent until reload -- and
 * a `'pause'` forwarded to a worklet that then receives `'init'` with no
 * matching `'resume'` would leave it paused forever. Pausing the loop
 * alone is enough pre-handshake: the cold-start hook only advances on a
 * real tick, so it simply waits out the pause and completes afterwards. */
let audioHandshakeDone = false

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
      loadRom(message.romBytes, message.name)
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
    case 'list-library':
      void publishLibrary()
      break
    case 'resume-rom':
      void resumeRom(message.romHash)
      break
    case 'remove-rom':
      void removeRom(message.romHash)
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
    case 'pause':
      paused = true
      // The audio side is now `syncAudioMute`'s job -- see that function's
      // doc comment for why muting is centralized there as of ENG-91
      // (rewind and non-1x speed need the exact same worklet bypass this
      // used to reach for directly).
      syncAudioMute()
      break
    case 'resume':
      // Idempotent: `EmulatorScreen` posts `'resume'` on mount as well as
      // on real transitions, and a reprime against a ring that was never
      // frozen would resync a playing stream for no reason.
      if (!paused) break
      paused = false
      // Video just resumes drawing on the very next tick. Audio only
      // actually un-mutes if nothing else (a rewind hold, a non-1x speed)
      // still wants it muted -- `syncAudioMute` is what checks that.
      syncAudioMute()
      break
    case 'rewind-start':
      startRewind()
      break
    case 'rewind-end':
      endRewind()
      break
    case 'frame-step':
      handleFrameStep()
      break
    case 'set-speed':
      setSpeed(message.multiplier)
      break
  }
}

/**
 * ENG-77's runtime ROM swap: re-loads the *running* core in place. Common
 * tail of both ways that can happen -- a fresh file pick (`loadRom`) and an
 * ENG-89 library resume (`resumeRom`) -- differing only in what `persist`
 * says to do about the library: `{ name, bytes }` for a fresh pick (write
 * the bytes), `{ name }` alone for a resume whose bytes are already stored
 * (touch the timestamp only, see `adoptRom`).
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
function swapRom(romBytes: Uint8Array, persist: { name: string; bytes?: Uint8Array }): void {
  if (!nesCore) {
    // Only reachable by picking a file before the Worker finished booting;
    // an honest "not yet" beats silently dropping the message.
    post({ type: 'rom-loaded', ok: false, message: 'The emulator is still starting up -- try again in a moment.' })
    return
  }

  // The outgoing cartridge's exact position, captured while it is still the
  // one in the machine -- `load_rom` below replaces it. Without this,
  // switching games through the library silently throws away everything
  // since the outgoing game's last autosave (up to
  // `RESUME_AUTOSAVE_INTERVAL_MS`), and "switch to B, switch back to A"
  // lands A somewhere earlier than where it was left. Skipped mid-swap for
  // the same half-adopted-machine reason `scheduleResumeAutosave` skips.
  const outgoing = romHash && !swapPending ? { hash: romHash, state: nesCore.saveState() } : null

  // Set before the call, not after: the moment `load_rom` succeeds the core
  // is running a different cartridge, and the tick loop must not advance it
  // until that cartridge's battery has been restored (M8).
  swapPending = true
  try {
    nesCore.loadRom(romBytes)
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
  // Written only once the new ROM has actually loaded (a rejected pick
  // leaves the old cartridge running, with nothing to save), and not when a
  // fresh pick re-inserts the *same* cartridge: that is the user restarting
  // it (see `RomPicker.tsx`'s "load it again to restart it"), and
  // recording the position they are walking away from as the one to resume
  // would undo the restart on the next reload.
  if (outgoing && !(persist.bytes && nesCore.romHash() === outgoing.hash)) {
    putSlot(outgoing.hash, RESUME_SLOT, outgoing.state).catch((err: unknown) => {
      post({ type: 'slot-error', slot: RESUME_SLOT, message: err instanceof Error ? err.message : String(err) })
    })
  }
  // `persist.bytes` absent means this swap came from the library
  // (`resumeRom`), not a fresh pick (`loadRom`) -- the main thread's own
  // `pendingName` correlation (`useRomLoader.ts`) has nothing to go on for
  // that case, since nobody there picked a file, so the name is handed
  // over explicitly instead. See `'boot-rom'`'s own comment in
  // `protocol.ts`.
  if (!persist.bytes) post({ type: 'boot-rom', name: persist.name })
  // The save-state identity changed with the cartridge: a different
  // `rom_hash` means a different set of slots, and the old ROM's battery
  // must not follow the new one. Not awaited -- `'rom-loaded'` reports that
  // the *ROM* loaded, which it did; `swapPending` is what holds emulation
  // until the rest of the swap has landed.
  void adoptRom(nesCore, persist)
}

/** ENG-77's runtime ROM swap, now also ENG-89's library write: a freshly
 * picked file's bytes are stored under its `rom_hash` (once `adoptRom`
 * computes it) the same way every load has always gone into `rom_storage`,
 * just persisted this time too. */
function loadRom(romBytes: ArrayBuffer, name: string): void {
  const bytes = new Uint8Array(romBytes)
  swapRom(bytes, { name, bytes })
}

/**
 * ENG-89: re-plays a cartridge already in the library, chosen from
 * `RomLibrary.tsx`'s listing. Reads the stored bytes back out of
 * `LIBRARY_STORE` and swaps them in exactly like a fresh pick, except the
 * library write on the other end of `swapRom` is a `touchRom` (bump
 * `lastPlayedAt`) rather than a `putRom` (rewrite the bytes) -- the whole
 * point of storing the ROM in the first place was so this moment doesn't
 * need the file again.
 */
async function resumeRom(targetHash: string): Promise<void> {
  if (!nesCore) {
    post({ type: 'library-error', message: 'The emulator is still starting up -- try again in a moment.' })
    return
  }
  const [entry, bytes] = await Promise.all([findRomEntry(targetHash), getRom(targetHash)])
  if (!entry || !bytes) {
    // A tab that removed this entry (or never had it -- two tabs can race
    // a delete) leaves a stale row in another tab's still-open listing.
    post({ type: 'library-error', message: 'That ROM is no longer in the library.' })
    return
  }
  swapRom(bytes, { name: entry.name })
}

/** ENG-89: drops a ROM from the library. Runtime state (the currently
 * loaded cartridge, its save-state slots) is untouched -- see `deleteRom`'s
 * own comment for why removal doesn't cascade. */
async function removeRom(targetHash: string): Promise<void> {
  try {
    await deleteRom(targetHash)
    await publishLibrary()
  } catch (err: unknown) {
    post({ type: 'library-error', message: err instanceof Error ? err.message : String(err) })
  }
}

async function findRomEntry(targetHash: string): Promise<RomLibraryEntry | undefined> {
  return (await listRoms()).find((entry) => entry.romHash === targetHash)
}

/** Pushes the full library listing to the main thread, most recently played
 * first -- the order `RomLibrary.tsx` renders it in, decided here rather
 * than in the component so every caller (not just the UI) sees the same
 * ordering. */
async function publishLibrary(): Promise<void> {
  const roms = await listRoms()
  roms.sort((a, b) => b.lastPlayedAt - a.lastPlayedAt)
  post({ type: 'library', roms })
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

  // Assigned to the module-level `renderer` (not a local) as of ENG-91: the
  // rewind and frame-step handlers paint outside `scheduleLoop`'s own
  // closure, from a plain `self.onmessage` case, and need the same instance.
  try {
    renderer = await createRenderer(canvas, FRAMEBUFFER_WIDTH, FRAMEBUFFER_HEIGHT, preferredRenderer)
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err)
    post({ type: 'status', status: 'error', message })
    return
  }

  // ENG-89: boot the last-played library entry instead of unconditionally
  // booting the vendored demo. `romBytes` (the demo, fetched by
  // `EmulatorScreen.tsx` before this message was even sent) stays the
  // fallback for a genuinely empty library -- first visit ever, or every
  // library entry having been removed -- so a `start()` never has nothing
  // to boot. This is a *read*, not a network fetch or a picker click, so it
  // costs nothing on the path that never has a library yet.
  //
  // Every failure on the library path falls back to the demo rather than
  // to an error status, and that is load-bearing, not politeness: boot
  // always picks the most recently played entry, so a stored ROM that no
  // longer loads (bytes corrupted, or a mapper a future build drops) would
  // otherwise fail *every* boot identically -- a console bricked until the
  // user finds out how to clear site data. The same goes for an IndexedDB
  // that can't be opened at all (some private-browsing modes): before
  // ENG-89 boot never depended on it, and it still mustn't.
  let mostRecent: RomLibraryEntry | null = null
  let resumed: Uint8Array | null = null
  try {
    const library = await listRoms()
    mostRecent = library.reduce<RomLibraryEntry | null>(
      (latest, entry) => (latest === null || entry.lastPlayedAt > latest.lastPlayedAt ? entry : latest),
      null,
    )
    resumed = mostRecent ? await getRom(mostRecent.romHash) : null
  } catch (err: unknown) {
    console.warn('ROM library unreadable; booting the demo instead:', err)
  }
  if (resumed) {
    try {
      core.loadRom(resumed)
    } catch (err: unknown) {
      console.warn(`Stored ROM "${mostRecent?.name}" failed to load; booting the demo instead:`, err)
      resumed = null
    }
  }

  try {
    if (!resumed) core.loadRom(new Uint8Array(romBytes))
  } catch (err: unknown) {
    // `RomLoadError extends Error`, so one check covers both.
    const message = err instanceof Error ? err.message : String(err)
    post({ type: 'status', status: 'error', message })
    return
  }

  nesCore = core
  // `resumed`'s bytes are already in the library (that's where they came
  // from) -- `touchRom` bumps `lastPlayedAt`, `putRom` is not needed and
  // would just rewrite what's already stored. The demo-fallback path passes
  // no `persist` at all: the demo is the empty-library placeholder, not a
  // cartridge that belongs *in* the library (see `RomLibrary.tsx`).
  await adoptRom(core, resumed && mostRecent ? { name: mostRecent.name } : undefined)
  if (resumed && mostRecent) post({ type: 'boot-rom', name: mostRecent.name })

  post({ type: 'status', status: 'running', renderer: renderer.kind })
  scheduleSramAutosave(core)
  scheduleResumeAutosave(core)
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
    // ENG-90: freezes the picture and stops sample production in one place.
    // ENG-91 adds `rewinding` alongside it, for the same reason -- see that
    // flag's own doc comment. `nextTick` above keeps advancing at the real
    // frame period regardless (this `return` is inside `step`, never
    // touching `scheduleLoop`'s own bookkeeping), so an arbitrarily long
    // pause or rewind hold never reads as the kind of stall `RESYNC_
    // THRESHOLD_MS` exists to correct -- there is no backlog to resync
    // away, because nothing fell behind in the first place.
    if (paused || rewinding) return
    renderer!.draw(advanceAndMaybeCapture(core))
    // Skipped until a user gesture creates the `AudioContext` and this
    // Worker's `startAudio` runs -- no point producing test-tone samples
    // (with the wrong, still-default sample rate) that nothing will ever
    // consume.
    if (audioReady) {
      core.stepAudioFrame()
      awaitAudioPrimed?.()
    }
  }, () => NTSC_FRAME_MS / speedMultiplier)
}

/**
 * Advances one video frame and, every `CAPTURE_INTERVAL_FRAMES`th one,
 * pushes a fresh rewind capture -- the one path both the normal tick loop
 * and `handleFrameStep` advance a frame through, so "every 10th forward
 * frame is captured" means the same thing regardless of whether those
 * frames came from real-time play or manual single-stepping while paused.
 *
 * Deliberately *not* called from `startRewind`'s own stepping -- loading a
 * historical snapshot and re-rendering it (see that function) is not new
 * forward progress, and capturing it would let a rewind hold quietly graft
 * captures from the timeline it is currently walking backward through onto
 * the ring it is popping from.
 *
 * `core.saveState()` is a ~20KB serialize, called here at most once every
 * ten frames (~166ms) -- `pacing.spec.ts` (real-time fps) is the
 * regression test for this staying cheap enough to not show up as dropped
 * frames at 1x.
 */
function advanceAndMaybeCapture(core: NesCore): Uint8ClampedArray<ArrayBuffer> {
  const frame = core.stepFrame()
  framesSinceCapture += 1
  if (framesSinceCapture >= CAPTURE_INTERVAL_FRAMES) {
    framesSinceCapture = 0
    rewindRing.push(core.saveState())
  }
  return frame
}

/**
 * ENG-91: single-step while paused (`K`). Re-checks `paused` itself (not
 * just trusting the main thread's own `disabled` button/no-op key guard --
 * see `EmulatorScreen.tsx`) because this runs off a plain message, the same
 * way `'reset'` does, and a frame-step racing a `'resume'` that already
 * landed must not double-advance the machine from two directions at once.
 * Also refuses during a rewind hold or a pending ROM swap, for the same
 * "don't mutate the machine from two places at once" reason.
 *
 * Draws exactly one frame and leaves `paused` untouched -- the tick loop's
 * own gate is what keeps the machine from advancing again on its own.
 */
function handleFrameStep(): void {
  if (!nesCore || !renderer || !paused || rewinding || swapPending) return
  renderer.draw(advanceAndMaybeCapture(nesCore))
}

/**
 * ENG-91: starts a rewind hold. Its own `setInterval`, independent of
 * `scheduleLoop`'s timer (which keeps running throughout, skipped by the
 * `rewinding` gate above) -- rewind is a human-scale interaction, not a
 * frame-accurate playback path, so the small jitter a plain `setInterval`
 * carries is not worth `scheduleLoop`'s self-correcting bookkeeping.
 *
 * Each tick pops one capture off `rewindRing` -- one step back in time --
 * loads it, and steps *one frame forward* from it purely to render:
 * ADR 0006 excludes `Ppu.framebuffer` from the save-state format (it is
 * redrawn from the dot the state resumes at, same as a numbered slot load),
 * so a `loadState` alone leaves nothing new on screen. That render frame
 * also pushes real APU samples into the ring via `Apu.tick` regardless of
 * `stepAudioFrame` ever being called (see `audio_ring.zig`'s module
 * comment -- `pushSample` runs inside `step_frame`'s `runFrames`, not
 * inside `step_audio_frame`, which only refreshes the DRC ratio) --
 * harmless here because the worklet is muted for the whole hold
 * (`syncAudioMute`) and `pushSample`'s own capacity check simply stops
 * accepting samples once the ring is full rather than corrupting anything;
 * whatever is sitting in it gets discarded wholesale by `beginAudioReprime`
 * resyncing straight to target fill when normal play resumes.
 *
 * Once the ring is empty, `pop()` returns `undefined` and this simply holds
 * the oldest frame already on screen rather than underflowing -- see
 * `RewindRing.pop`'s own comment.
 */
function startRewind(): void {
  if (rewinding || !nesCore || !renderer) return
  rewinding = true
  syncAudioMute()
  const core = nesCore
  rewindTimer = setInterval(() => {
    const snapshot = rewindRing.pop()
    if (!snapshot) return
    core.loadState(snapshot)
    renderer!.draw(core.stepFrame())
  }, REWIND_TICK_MS)
}

/**
 * ENG-91: ends a rewind hold. Clearing `rewinding` alone is what makes
 * release behave correctly whether the transport was running or
 * user-paused when the hold started -- see `rewinding`'s own doc comment:
 * if `paused` is still `true`, the tick loop's `if (paused || rewinding)`
 * gate keeps it frozen exactly where rewind left it ("stay paused on
 * release"); if not, the very next scheduled tick steps forward from there
 * ("resume running on release"), with no bookkeeping here about which case
 * applied.
 */
function endRewind(): void {
  if (!rewinding) return
  rewinding = false
  if (rewindTimer !== null) {
    clearInterval(rewindTimer)
    rewindTimer = null
  }
  syncAudioMute()
}

/**
 * ENG-91: applies a speed change. `scheduleLoop`'s period getter reads
 * `speedMultiplier` fresh on every tick, so this needs no coordination with
 * the loop itself -- the very next `setTimeout` callback just uses the new
 * period, and `RESYNC_THRESHOLD_MS`'s drift check is untouched by the
 * change (see `scheduleLoop`'s own doc comment for why a period change
 * can't produce a catch-up burst regardless of when it lands).
 */
function setSpeed(multiplier: Speed): void {
  if (multiplier === speedMultiplier) return
  speedMultiplier = multiplier
  syncAudioMute()
}

/**
 * Centralizes every reason the worklet should be muted right now --
 * ENG-90's user/hidden pause, ENG-91's rewind hold, and ENG-91's non-1x
 * speed -- into one send-on-transition call, reusing exactly
 * `audioRingProcessor.js`'s existing `paused` bypass (silence, nothing
 * counted) rather than adding a second one. A non-1x speed needs this for
 * a different reason than pause/rewind do: at 0.5x the ring is fed at half
 * the real-time rate a live worklet expects and would starve continuously,
 * while at 2x it's fed faster than the worklet drains it and
 * `pushSample`'s capacity check would start silently dropping samples --
 * "the audio either follows or is muted deliberately, never left to
 * underrun/overflow" is satisfied by choosing mute, uniformly, for every
 * speed but 1x.
 *
 * Skipped entirely pre-handshake (`audioHandshakeDone`) for the same reason
 * `'pause'` always was -- see that flag's own doc comment -- and re-applied
 * the instant the handshake *does* complete (`startAudio`'s `awaitAudioPrimed`
 * calls this too), so a speed change or rewind hold that happened to occur
 * during the cold-start priming window is not silently dropped once the
 * worklet actually comes alive.
 */
function syncAudioMute(): void {
  if (!audioHandshakeDone) return
  const shouldMute = paused || rewinding || speedMultiplier !== 1
  if (shouldMute === audioMuted) return
  audioMuted = shouldMute
  if (shouldMute) audioPort?.postMessage({ type: 'pause' })
  else beginAudioReprime()
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
  // Stashed at module scope so `beginAudioReprime` -- run from a later,
  // unrelated `'resume'` message -- can re-run this same priming wait
  // without `startAudio`'s locals still being in scope.
  audioControl = control
  audioPrimeTarget = primeTarget
  let ticksWaited = 0
  awaitAudioPrimed = () => {
    ticksWaited += 1
    const fill = (Atomics.load(control, WRITE_INDEX) - Atomics.load(control, READ_INDEX)) >>> 0
    if (fill < primeTarget && ticksWaited < MAX_PRIME_TICKS) return
    awaitAudioPrimed = null
    audioHandshakeDone = true
    // ENG-91: applies whatever mute state (rewind/non-1x speed/pause) was
    // already requested during the priming window this closure just
    // finished waiting out -- see `syncAudioMute`'s own doc comment.
    syncAudioMute()

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

/**
 * ENG-90's resume-side counterpart to `startAudio`'s own priming wait.
 *
 * By the time `'resume'` arrives, `'pause'` has already told the worklet to
 * hold `read_index` still and stop touching `underrun_count` (see
 * `audioRingProcessor.js`), and the tick loop above has just gone back to
 * calling `stepAudioFrame`, which resumes advancing `write_index` from
 * exactly where it froze. Telling the worklet to resume *immediately* would
 * have it resync to `write - targetFill` before any of those fresh samples
 * exist -- landing on whatever stale, already-played audio still sits that
 * far back in the circular buffer, which is a rewind-and-repeat glitch, not
 * silence and not new. Waiting for a full target's worth of samples
 * produced *since* the freeze point is what makes the eventual resync land
 * exactly on fresh audio -- the same reasoning `startAudio`'s own comment
 * gives for withholding the handshake on cold start, reapplied here because
 * pause is a cold start in every way that matters to the ring.
 */
function beginAudioReprime(): void {
  if (!audioControl || !audioPort) return // audio never enabled this session -- nothing to reprime
  const control = audioControl
  const port = audioPort
  const primeTarget = audioPrimeTarget
  const writeAtResume = Atomics.load(control, WRITE_INDEX)
  let ticksWaited = 0
  awaitAudioPrimed = () => {
    ticksWaited += 1
    const freshSamples = (Atomics.load(control, WRITE_INDEX) - writeAtResume) >>> 0
    if (freshSamples < primeTarget && ticksWaited < MAX_PRIME_TICKS) return
    awaitAudioPrimed = null
    // The worklet's own `resume` handler resyncs `read_index` to `write -
    // targetFill` and clears its `paused` flag in one step -- see that
    // file's `handleMessage`.
    port.postMessage({ type: 'resume' })
  }
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
 *
 * `frameMs` is a getter, not a fixed number, so ENG-91's speed control can
 * change the period mid-run (`setSpeed` just mutates `speedMultiplier`,
 * read fresh here every tick) without this function knowing speed exists.
 * That live change is exactly as safe as any other tick-to-tick jitter this
 * loop already tolerates: `step()` is called at most once per `tick()`
 * regardless of how far `now` and `nextTick` have drifted, so there is no
 * multi-step "catch up to the new rate" burst to produce in the first
 * place -- the same property the module comment above already leans on for
 * the ordinary resync case, unaffected by *why* a gap between them opened.
 */
function scheduleLoop(step: () => void, frameMs: () => number): void {
  let nextTick = performance.now()

  const tick = () => {
    const now = performance.now()
    if (now - nextTick > RESYNC_THRESHOLD_MS) nextTick = now // see RESYNC_THRESHOLD_MS's own comment
    step()
    nextTick += frameMs()
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
  return withSlotErrors(slot, async (core) => {
    const data = core.saveState()
    await putSlot(romHash, slot, data)
    // Rebaselines the ENG-89 backstop (`scheduleResumeAutosave`) so it
    // doesn't immediately rewrite the identical bytes this call -- whether
    // triggered by `useResumeAutosave.ts`'s hide/pagehide handlers or, in
    // principle, a future manual control -- just wrote.
    if (slot === RESUME_SLOT) persistedResumeState = data
  })
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
    // ENG-91: a manual slot load is a deliberate jump to a different point
    // in this cartridge's history, same in kind as what rewind itself does
    // -- so it gets folded into the same ring rather than invalidating it.
    // Pushing `blob` (already in hand, no second `saveState()` call) keeps
    // the ring's top consistent with what is now actually running, and
    // deliberately does *not* clear the rest of the history below it:
    // rewinding right after this load walks back into the pre-load past,
    // which reads as "undo the load" -- a reasonable thing to want, and no
    // worse than what loading the slot already did to "now".
    rewindRing.push(blob)
    framesSinceCapture = 0
  })
}

/**
 * Takes on a newly-loaded cartridge's save-state identity: its `rom_hash`
 * (which keys every slot and the library entry alike), its battery, its
 * ENG-89 resume point, its slot listing, and -- if `persist` says so -- its
 * place in the library.
 *
 * Called from every place a ROM can arrive -- the initial boot, ENG-77's
 * runtime file picker, and ENG-89's library resume -- because a swap
 * changes every one of those. Without it the slot browser would keep
 * showing the previous game's saves, and the next save would be filed under
 * the wrong cartridge.
 *
 * `persist` is `undefined` only for the demo-fallback boot (see `start`):
 * every other caller passes it, `bytes` present for a fresh pick (`putRom`,
 * a real write) or absent for a library-sourced boot/resume (`touchRom`, a
 * timestamp bump only).
 *
 * The battery and resume-state restores both happen *before* the first
 * emulated frame of the new ROM (`swapPending` is what enforces that): a
 * real cartridge's RAM is already holding its contents at power-on, and
 * most games read their save file during boot -- and a resumed session
 * should look, from the very first frame, like it never stopped.
 */
async function adoptRom(core: NesCore, persist?: { name: string; bytes?: Uint8Array }): Promise<void> {
  romHash = core.romHash()
  // Cleared, not carried over: it is the previous cartridge's RAM/position,
  // and leaving either would let an autosave decide "nothing changed" and
  // never write the new game's battery or resume point at all.
  persistedSram = null
  persistedResumeState = null
  // ENG-91: the rewind ring is per-cartridge. A previous game's captures
  // are meaningless against a different `rom_hash`/mapper -- `wasm.zig`'s
  // `load_state` would likely just reject them outright -- and even a
  // same-ROM re-adoption (a fresh pick re-inserting the identical cartridge,
  // see `swapRom`'s "load it again to restart it") is a genuine power-on,
  // which real rewind hardware has nothing to rewind past either.
  rewindRing.clear()
  framesSinceCapture = 0
  const hash = romHash
  try {
    await restoreSram(core)
    // Only a *continuation* resumes: the boot path and a library pick. A
    // fresh file pick is inserting a cartridge and powering on -- which is
    // what the picker has always meant, "load it again to restart it"
    // included (`RomPicker.tsx`) -- so it restores the battery, as a real
    // cartridge would, but not a mid-game position. `persist.bytes` is
    // exactly "this came from the picker"; see this function's doc comment.
    if (!persist?.bytes) await restoreResume(core)
  } finally {
    swapPending = false
  }
  // After the restores and outside `swapPending`, deliberately. Before
  // them, a failed library write -- a quota error on a large ROM is the
  // realistic one -- threw straight past `restoreSram`, booting the game
  // with a blank battery that the SRAM autosave would then write over the
  // real one. And a ROM-sized IndexedDB write has no business holding
  // emulation frozen in the meantime. A cartridge that plays but didn't
  // make it into the library is a recoverable annoyance; say so and move on.
  if (persist) {
    try {
      if (persist.bytes) await putRom(hash, persist.name, persist.bytes)
      else await touchRom(hash)
    } catch (err: unknown) {
      post({
        type: 'library-error',
        message: `Couldn't save "${persist.name}" to the library: ${err instanceof Error ? err.message : String(err)}`,
      })
    }
  }
  await publishSlots()
  await publishLibrary()
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

/**
 * ENG-89: loads the reserved `RESUME_SLOT` into the cartridge, if this ROM
 * has one stored -- the auto-resume half of session continuity, mirroring
 * `restoreSram` immediately above it. Runs *after* `restoreSram` in
 * `adoptRom`: a resume state is a full machine snapshot and so carries its
 * own point-in-time SRAM, overwriting whatever `restoreSram` just loaded --
 * correct, since the fuller record should win -- which is why
 * `persistedSram` is rebaselined here too, the same reasoning
 * `loadFromSlot` already uses for a manual load. A cartridge with no resume
 * point yet (never played before, or its save-state was written by an
 * older, incompatible build and rejected) simply boots from power-on, same
 * as before ENG-89.
 */
async function restoreResume(core: NesCore): Promise<void> {
  try {
    const blob = await getSlot(romHash, RESUME_SLOT)
    if (blob) {
      core.loadState(blob)
      persistedResumeState = blob
      persistedSram = core.sram()
    }
  } catch (err: unknown) {
    post({
      type: 'slot-error',
      slot: RESUME_SLOT,
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
    // ENG-91: a rewind hold has `core` sitting on a historical snapshot for
    // the interval's whole duration -- reading its SRAM here would risk
    // writing the player's *past* battery contents over their real,
    // current save. Same "half-adopted/in-flux machine" reasoning
    // `scheduleResumeAutosave` already applied to `swapPending`.
    if (rewinding) return
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

/**
 * ENG-89's periodic backstop for `RESUME_SLOT` -- see
 * `RESUME_AUTOSAVE_INTERVAL_MS`'s comment for why this exists alongside the
 * main-thread `visibilitychange`/`pagehide` triggers rather than instead of
 * them. Mirrors `scheduleSramAutosave`'s "only write on an actual change"
 * shape, compared against `persistedResumeState` instead of
 * `persistedSram` -- but *without* that function's "all zero means never
 * saved, skip" carve-out, since a fresh save-state is never all zero (it
 * always carries real CPU/PPU register state) and there is no equivalent
 * "hasn't happened yet" case to distinguish from "genuinely empty".
 * Skipped entirely mid-swap (`swapPending`): `core.saveState()` against a
 * cartridge whose battery/resume restore hasn't landed yet would capture a
 * half-adopted machine.
 */
function scheduleResumeAutosave(core: NesCore): void {
  setInterval(() => {
    // ENG-91: `rewinding` added alongside `swapPending` for the same
    // reason -- see `scheduleSramAutosave`'s matching guard.
    if (swapPending || rewinding || !romHash) return
    const current = core.saveState()
    if (persistedResumeState !== null && equalBytes(current, persistedResumeState)) return
    persistedResumeState = current
    void withSlotErrors(RESUME_SLOT, () => putSlot(romHash, RESUME_SLOT, current))
  }, RESUME_AUTOSAVE_INTERVAL_MS)
}

function equalBytes(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false
  return true
}
