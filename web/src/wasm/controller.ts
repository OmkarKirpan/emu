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

/** Page controls whose arrow keys change their own value: a radio group's
 * selection (the Display panel's filter) and a range slider (volume). */
function usesArrowKeys(target: EventTarget | null): boolean {
  return target instanceof HTMLInputElement && (target.type === 'radio' || target.type === 'range')
}

/**
 * Tracks which mapped keys are currently held and exposes the live packed
 * byte `NesCore.setInput` wants for controller 0. Listens on `window`
 * (rather than requiring focus on the canvas) so the demo is playable the
 * instant the page loads.
 */
export class KeyboardController {
  private buttons = 0

  /** Whether the player last moved focus with the keyboard (Tab) rather than
   * a pointer. See `apply` for what it decides. */
  private tabbing = false

  constructor() {
    window.addEventListener('keydown', this.handleKeyDown)
    window.addEventListener('keyup', this.handleKeyUp)
    window.addEventListener('pointerdown', this.handlePointerDown)
  }

  /** Current controller-0 byte, in the exact bit layout `set_input` and
   * real NES hardware both expect. */
  read(): number {
    return this.buttons
  }

  dispose(): void {
    window.removeEventListener('keydown', this.handleKeyDown)
    window.removeEventListener('keyup', this.handleKeyUp)
    window.removeEventListener('pointerdown', this.handlePointerDown)
  }

  // Arrow properties, not methods: `removeEventListener` needs the same
  // function identity `addEventListener` was given.
  private handleKeyDown = (event: KeyboardEvent): void => {
    if (event.code === 'Tab') this.tabbing = true
    this.apply(event, true)
  }
  private handleKeyUp = (event: KeyboardEvent): void => this.apply(event, false)
  private handlePointerDown = (): void => {
    this.tabbing = false
  }

  /** Both directions differ only in which way the bit moves, so the mapped-key
   * policy (what counts as mapped, and that mapped keys are swallowed) lives
   * in one place rather than being kept in sync across two handlers. */
  private apply(event: KeyboardEvent, pressed: boolean): void {
    const bit = KEY_MAP[event.code]
    if (bit === undefined) return
    // A radio group or slider the player tabbed to moves its own value with
    // the arrows -- for a radio group that is the *only* keyboard way to
    // change the selection -- so those presses are left to it. Only when
    // tabbed to: after a click, the control keeps focus and the arrows have
    // to keep reaching the game. Releases always go through, so a button
    // held from play can't stick.
    if (pressed && this.tabbing && event.code.startsWith('Arrow') && usesArrowKeys(event.target)) return
    event.preventDefault() // mapped keys (esp. arrows) shouldn't scroll the page
    this.buttons = pressed ? this.buttons | bit : this.buttons & ~bit
  }
}
