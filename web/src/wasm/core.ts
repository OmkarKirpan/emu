// The JS side of ENG-60's wasm/JS ABI, wired up for ENG-69 (M4). One hidden
// `Emulator` per instantiated module (per ENG-60's "implicit global
// singleton" design) — `NesCore` just wraps that instance's raw exports in
// a typed, memory-safety-aware surface.
import initCore from './nes_core.wasm?init'

/** Framebuffer dimensions `get_framebuffer_ptr` (ENG-60) always describes. */
export const FRAMEBUFFER_WIDTH = 256
export const FRAMEBUFFER_HEIGHT = 240

/**
 * `load_rom`'s `i32` status codes — see `core/src/wasm.zig`'s doc comment,
 * which is this table's source of truth. `Ok` is success; JS owns the
 * code -> message lookup (ENG-60), which is exactly what `RomLoadError`
 * below is.
 *
 * A plain object rather than a TS `enum`: this project's tsconfig enables
 * `erasableSyntaxOnly`, which (like Node's own type-stripping) rejects any
 * construct that isn't pure-type and erasable at compile time -- `enum`
 * (const or not) compiles to a real runtime object, so it doesn't qualify.
 */
export const RomStatus = {
  Ok: 0,
  InvalidHeader: -1,
  UnsupportedMapper: -2,
  TruncatedData: -3,
  RomTooLarge: -4,
} as const
export type RomStatus = (typeof RomStatus)[keyof typeof RomStatus]

/** Thrown by `NesCore.loadRom` for any non-`Ok` status, carrying both the
 * raw code and `get_last_error_context()`'s reading at the time of failure
 * (see `wasm.zig` for what that number means per status). */
export class RomLoadError extends Error {
  readonly status: RomStatus
  readonly context: number

  constructor(status: RomStatus, context: number) {
    super(RomLoadError.describe(status, context))
    this.name = 'RomLoadError'
    this.status = status
    this.context = context
  }

  private static describe(status: RomStatus, context: number): string {
    switch (status) {
      case RomStatus.InvalidHeader:
        return 'Not a valid iNES ROM file.'
      case RomStatus.UnsupportedMapper:
        return `Unsupported mapper ${context} (only NROM/mapper 0 is supported so far).`
      case RomStatus.TruncatedData:
        return `ROM file is truncated (only ${context} bytes were readable).`
      case RomStatus.RomTooLarge:
        return `ROM file is too large (the core's cap is ${context} bytes).`
      default:
        // Unreachable for the codes above, and `loadRom` never constructs
        // this for `Ok` -- but a `default` (rather than an `Ok` arm that
        // returns a lie) means a status code added on the Zig side reads as
        // an honest unknown here instead of falling out of the switch as
        // `undefined`.
        return `ROM load failed (status ${status}).`
    }
  }
}

/** The exact free-function surface `wasm.zig` exports — see that file's own
 * doc comment for the full ABI contract this mirrors. */
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

  /** Advances exactly one NTSC video frame and returns a live view onto the
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

  private viewFramebuffer(): Uint8ClampedArray<ArrayBuffer> {
    const ptr = this.exports.get_framebuffer_ptr()
    return new Uint8ClampedArray(this.exports.memory.buffer, ptr, FRAMEBUFFER_WIDTH * FRAMEBUFFER_HEIGHT * 4)
  }
}
