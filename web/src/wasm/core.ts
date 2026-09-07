// The JS side of ENG-60's wasm/JS ABI, wired up for ENG-69 (M4) and extended
// for ENG-62/M5's audio ring buffer. One hidden `Emulator` per instantiated
// module (per ENG-60's "implicit global singleton" design) — `NesCore` just
// wraps that instance's raw exports in a typed, memory-safety-aware
// surface.
import initCore from './nes_core.wasm?init'
import { RomLoadError, RomStatus } from './errors'

export { RomLoadError, RomStatus }

/** Framebuffer dimensions `get_framebuffer_ptr` (ENG-60) always describes. */
export const FRAMEBUFFER_WIDTH = 256
export const FRAMEBUFFER_HEIGHT = 240

/** The exact free-function surface `wasm.zig` exports — see that file's own
 * doc comment for the full ABI contract this mirrors. The `init`/
 * `get_audio_ring_*`/`step_audio_frame` group is the ENG-62 audio ring
 * buffer subsystem (see `audio_ring.zig`) -- independent of everything
 * above it (loading a ROM, stepping video frames), and unconditionally
 * present regardless of whether a caller ever touches it. */
interface CoreExports {
  memory: WebAssembly.Memory
  alloc(size: number): number
  free(ptr: number, size: number): void
  load_rom(ptr: number, len: number): number
  reset(): void
  step_frame(): void
  get_framebuffer_ptr(): number
  set_input(controller: number, buttons: number): void
  get_last_error_context(): number
  init(sampleRate: number): void
  get_audio_ring_ptr(): number
  get_audio_ring_control_ptr(): number
  get_audio_ring_capacity(): number
  step_audio_frame(): void
}

/**
 * One instantiated core module, wrapping ENG-60's raw ABI. Two things this
 * class exists to get right that the raw exports alone don't:
 *
 * 1. **A framebuffer view can go stale.** A `memory.grow` (which `alloc`
 *    can trigger, so every `loadRom` can) detaches every existing
 *    typed-array view over that memory — ENG-60 flags this explicitly, and
 *    a detached view silently reads as empty rather than throwing. So
 *    `stepFrame` hands back a freshly-built view every time instead of
 *    caching one: unconditionally correct, and a view object per frame is
 *    nothing next to the 16.67ms it is handed out for.
 * 2. **Every fallible call maps its `i32` status to a real exception**,
 *    with `get_last_error_context()` folded in, so callers never have to
 *    remember to check a magic number themselves.
 */
export class NesCore {
  private readonly exports: CoreExports

  private constructor(exports: CoreExports) {
    this.exports = exports
  }

  static async create(): Promise<NesCore> {
    const instance = await initCore()
    return new NesCore(instance.exports as unknown as CoreExports)
  }

  /** Stages `bytes` across the wasm boundary via `alloc`/`free` (ENG-60)
   * and calls `load_rom`. Throws `RomLoadError` on any non-`Ok` status;
   * the previously-loaded ROM (if any) is left running untouched in that
   * case — see `wasm.zig`'s `validate`. */
  loadRom(bytes: Uint8Array): void {
    const ptr = this.exports.alloc(bytes.length)
    if (ptr === 0) throw new Error('wasm alloc() failed (out of memory)')
    try {
      new Uint8Array(this.exports.memory.buffer, ptr, bytes.length).set(bytes)
      const status = this.exports.load_rom(ptr, bytes.length) as RomStatus
      if (status !== RomStatus.Ok) {
        throw new RomLoadError(status, this.exports.get_last_error_context())
      }
    } finally {
      this.exports.free(ptr, bytes.length)
    }
  }

  reset(): void {
    this.exports.reset()
  }

  /** Advances exactly one NTSC video frame and returns a copy of the
   * resolved RGBA8 framebuffer (ENG-60) — safe to hand straight to
   * `ImageData`, and deliberately raw rather than pre-wrapped, so the
   * WebGPU texture-upload path this same buffer is designed to feed later
   * isn't forced through a Canvas-2D-shaped type. */
  stepFrame(): Uint8ClampedArray<ArrayBuffer> {
    this.exports.step_frame()
    return this.viewFramebuffer()
  }

  /** One packed byte per controller, NES bit order — see
   * `web/src/wasm/controller.ts`'s `Button` map, which mirrors
   * `core/src/controller.zig`'s documented layout exactly. */
  setInput(controller: 0 | 1, buttons: number): void {
    this.exports.set_input(controller, buttons)
  }

  /** Resets the audio-ring subsystem and tells it the host's real
   * `AudioContext` sample rate (ENG-62's handshake: the device rate is
   * only known at runtime). Independent of `loadRom`/`reset` -- it
   * doesn't touch the emulated machine at all, see `audio_ring.zig`'s
   * module doc comment. Call once, before the first `stepAudioFrame`. */
  initAudio(sampleRate: number): void {
    this.exports.init(sampleRate)
  }

  /** Advances the test-tone generator by one nominal NES frame's worth of
   * (DRC-adjusted) samples -- call once per tick, alongside `stepFrame`
   * (see `emulator/emulatorWorker.ts`), after `initAudio`. */
  stepAudioFrame(): void {
    this.exports.step_audio_frame()
  }

  /** Ring buffer byte offset into `memory` -- call once, after `initAudio`,
   * and build one `Float32Array` view over `[ptr, ptr +
   * getAudioRingCapacity() * 4)`. Forwarded to the `AudioWorkletProcessor`
   * (see `audio/audioRingProcessor.js`) as part of ENG-62's handshake. */
  getAudioRingPtr(): number {
    return this.exports.get_audio_ring_ptr()
  }

  /** Control-block byte offset into `memory` -- see `audio_ring.zig`'s
   * `ControlBlock` doc comment for the field layout this points at. */
  getAudioRingControlPtr(): number {
    return this.exports.get_audio_ring_control_ptr()
  }

  getAudioRingCapacity(): number {
    return this.exports.get_audio_ring_capacity()
  }

  /** The framebuffer's byte offset into `memory` -- exposed for a
   * shared-memory *debug* view only (see `emulator/emulatorWorker.ts`'s
   * `'ready'` message and `e2e/helpers.ts`'s `readFramebuffer`);
   * `stepFrame`'s returned copy is the one production code should use. */
  getFramebufferPtr(): number {
    return this.exports.get_framebuffer_ptr()
  }

  /** The wasm instance's own linear memory -- a `SharedArrayBuffer` as of
   * ENG-56/ENG-62 (M5), since the module is built with `shared_memory =
   * true` for the audio ring buffer's sake. Exposed so a host holding this
   * `NesCore` (the Worker `emulatorWorker.ts` instantiates) can forward it
   * to the worklet and to the main thread's debug views, without either of
   * them needing their own copy of the wasm export surface. */
  get memory(): WebAssembly.Memory {
    return this.exports.memory
  }

  /** A copy, not a live view, of the wasm-side framebuffer -- for two
   * independent reasons. First, the original one: a `memory.grow` (which
   * `alloc` can trigger, so every `loadRom` can) detaches every existing
   * typed-array view over that memory, so a cached view would eventually go
   * stale. Second, as of ENG-56/ENG-62 (M5): `memory.buffer` is now a
   * `SharedArrayBuffer` (the wasm module is built with `shared_memory =
   * true` for the audio ring buffer's sake, and as of the video-in-Worker
   * migration this instance's memory genuinely is shared, with the audio
   * worklet), and browsers refuse to construct `ImageData` from a
   * shared-buffer-backed typed array ("must not be shared"). `new
   * Uint8ClampedArray(typedArray)` always allocates a fresh, plain
   * `ArrayBuffer` for the copy regardless of the source's buffer type,
   * which fixes both problems in one call -- a plain copy can't be
   * detached either. 245,760 bytes at 60fps is nothing next to the frame
   * of emulation it's copied out of, or next to the copy `putImageData`
   * itself already makes into the canvas's backing store. */
  private viewFramebuffer(): Uint8ClampedArray<ArrayBuffer> {
    const ptr = this.exports.get_framebuffer_ptr()
    const live = new Uint8ClampedArray(this.exports.memory.buffer, ptr, FRAMEBUFFER_WIDTH * FRAMEBUFFER_HEIGHT * 4)
    return new Uint8ClampedArray(live)
  }
}
