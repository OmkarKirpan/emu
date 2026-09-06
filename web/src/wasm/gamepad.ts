import { Button } from './controller'

/**
 * Standard Gamepad layout (https://w3c.github.io/gamepad/#remapping) button
 * indices -> NES button. Bottom/south face button -> B, right/east -> A
 * (mirrors the common NES-emulator convention of putting the "weak" action on
 * the button in B's relative position and the "strong" one in A's, same
 * logic `controller.ts` used picking Z/X for keyboard); indices 12-15 are the
 * standard mapping's own d-pad, so no axis fallback is needed for a gamepad
 * that actually reports `mapping === 'standard'`.
 */
const BUTTON_MAP: Readonly<Record<number, number>> = {
  0: Button.B,
  1: Button.A,
  8: Button.Select,
  9: Button.Start,
  12: Button.Up,
  13: Button.Down,
  14: Button.Left,
  15: Button.Right,
}

/**
 * Polls `navigator.getGamepads()` for the live packed byte `NesCore.setInput`
 * wants, in the same bit layout `KeyboardController` produces -- the two are
 * meant to be OR'd together (see `EmulatorScreen.tsx`).
 *
 * Unlike `KeyboardController`, this has no event stream to listen on: the
 * Gamepad API exposes button state only as a snapshot (`Gamepad.buttons[i]
 * .pressed`), so `read()` re-polls `navigator.getGamepads()` every call
 * rather than caching state pushed by a listener. That also means there's
 * nothing to tear down -- no `dispose()` needed, unlike `KeyboardController`.
 */
export class GamepadController {
  /**
   * Only gamepads reporting the W3C "standard" layout are read: that's the
   * mapping `BUTTON_MAP`'s indices assume, and a non-standard gamepad
   * reporting arbitrary indices would silently produce wrong input rather
   * than an obvious failure. Non-standard pads simply contribute nothing,
   * same as no gamepad being connected at all.
   */
  read(): number {
    if (typeof navigator === 'undefined' || !navigator.getGamepads) return 0

    let buttons = 0
    for (const pad of navigator.getGamepads()) {
      if (!pad || !pad.connected || pad.mapping !== 'standard') continue
      for (const [index, bit] of Object.entries(BUTTON_MAP)) {
        if (pad.buttons[Number(index)]?.pressed) buttons |= bit
      }
    }
    return buttons
  }
}
