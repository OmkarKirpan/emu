/** NES bit order for a packed controller-buttons byte -- bit0 to bit7 is A,
 * B, Select, Start, Up, Down, Left, Right. Mirrors `core/src/controller.zig`
 * exactly (that file locked this layout in for the `set_input` export this
 * maps to; see its own module doc comment). */
export const Button = {
  A: 0x01,
  B: 0x02,
  Select: 0x04,
  Start: 0x08,
  Up: 0x10,
  Down: 0x20,
  Left: 0x40,
  Right: 0x80,
} as const

/** `KeyboardEvent.code` (physical-key, layout-independent) -> NES button.
 * Arrow keys for the D-pad; Z/X for B/A (the common NES-emulator
 * convention); Enter/Shift for Start/Select. */
const KEY_MAP: Readonly<Record<string, number>> = {
  ArrowUp: Button.Up,
  ArrowDown: Button.Down,
  ArrowLeft: Button.Left,
  ArrowRight: Button.Right,
  KeyZ: Button.B,
  KeyX: Button.A,
  Enter: Button.Start,
  ShiftLeft: Button.Select,
  ShiftRight: Button.Select,
}

/**
 * Tracks which mapped keys are currently held and exposes the live packed
 * byte `NesCore.setInput` wants for controller 0. Listens on `window`
 * (rather than requiring focus on the canvas) so the demo is playable the
 * instant the page loads.
 */
export class KeyboardController {
  private buttons = 0

  constructor() {
    window.addEventListener('keydown', this.handleKeyDown)
    window.addEventListener('keyup', this.handleKeyUp)
  }

  /** Current controller-0 byte, in the exact bit layout `set_input` and
   * real NES hardware both expect. */
  read(): number {
    return this.buttons
  }

  dispose(): void {
    window.removeEventListener('keydown', this.handleKeyDown)
    window.removeEventListener('keyup', this.handleKeyUp)
  }

  private handleKeyDown = (event: KeyboardEvent): void => {
    const bit = KEY_MAP[event.code]
    if (bit === undefined) return
    event.preventDefault() // mapped keys (esp. arrows) shouldn't scroll the page
    this.buttons |= bit
  }

  private handleKeyUp = (event: KeyboardEvent): void => {
    const bit = KEY_MAP[event.code]
    if (bit === undefined) return
    event.preventDefault()
    this.buttons &= ~bit
  }
}
