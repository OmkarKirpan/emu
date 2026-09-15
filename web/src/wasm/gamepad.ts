import { Button } from './controller'

/**
 * Standard Gamepad layout (https://w3c.github.io/gamepad/#remapping) button
 * indices -> NES button. Bottom/south face button -> B, right/east -> A
 * (mirrors the common NES-emulator convention of putting the "weak" action on
 * the button in B's relative position and the "strong" one in A's, same
 * logic `controller.ts` used picking Z/X for keyboard); indices 12-15 are the
 * standard mapping's own d-pad.
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
 * How far the left stick has to lean before it counts as a D-pad press. The
 * stick was originally not read at all, on the reasoning that a standard pad
 * already reports a real d-pad on buttons 12-15 -- true, but on an Xbox
 * controller the left stick is where a player's thumb actually goes, and
 * that pad looked dead. A probe of an Xbox One S in Chrome confirmed it: the
 * d-pad moved the sprite, the stick (which is what got used) did nothing.
 *
 * Half deflection, per axis: far enough out that resting drift (real pads
 * rarely read exactly 0) never walks the player, and each axis thresholded
 * on its own so a diagonal holds both directions, which is what an NES d-pad
 * diagonal is. Only the left stick, standard mapping's axes 0 (x, +right)
 * and 1 (y, +down); the right stick has nothing on an NES pad to stand for.
 */
const STICK_THRESHOLD = 0.5

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
      const [x = 0, y = 0] = pad.axes
      if (x <= -STICK_THRESHOLD) buttons |= Button.Left
      if (x >= STICK_THRESHOLD) buttons |= Button.Right
      if (y <= -STICK_THRESHOLD) buttons |= Button.Up
      if (y >= STICK_THRESHOLD) buttons |= Button.Down
    }
    return buttons
  }
}
