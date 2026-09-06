import { KeyboardController } from '../wasm/controller'
import { GamepadController } from '../wasm/gamepad'

/**
 * Publishes the merged keyboard | gamepad button byte into a shared
 * `Int32Array` via `Atomics.store`, polled once per `requestAnimationFrame`
 * tick on the main thread -- the same lock-free-shared-memory idiom the
 * audio ring buffer uses (ENG-62), reused here so a keypress reaches
 * `emulatorWorker.ts`'s `set_input` call with no `postMessage` round trip.
 * Gamepad state has no event stream to hook (see `GamepadController`), so
 * this has to poll regardless; keyboard just rides along on the same tick
 * rather than needing a separate path of its own.
 *
 * A single shared slot, not per-controller: this app only ever drives
 * controller 0.
 */
export class InputBridge {
  private readonly keyboard = new KeyboardController()
  private readonly gamepad = new GamepadController()
  private readonly shared: Int32Array
  private rafHandle: number

  // A plain field + assignment, not a constructor parameter property: this
  // project's tsconfig enables `erasableSyntaxOnly` (see `errors.ts`'s own
  // comment on the same constraint), which rejects parameter properties --
  // they desugar to a runtime `this.shared = shared` assignment, which
  // isn't purely type-level/erasable.
  constructor(shared: Int32Array) {
    this.shared = shared
    const tick = () => {
      Atomics.store(this.shared, 0, this.keyboard.read() | this.gamepad.read())
      this.rafHandle = requestAnimationFrame(tick)
    }
    this.rafHandle = requestAnimationFrame(tick)
  }

  dispose(): void {
    cancelAnimationFrame(this.rafHandle)
    this.keyboard.dispose()
  }
}
