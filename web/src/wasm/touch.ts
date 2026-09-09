import { Button } from './controller'

/** The four direction bits, as one mask. The D-pad replaces all four at
 * once (see `setDirection`) rather than toggling them individually. */
const DIRECTIONS = Button.Up | Button.Down | Button.Left | Button.Right

/**
 * The on-screen gamepad's contribution to controller 0, in the same packed
 * bit layout `KeyboardController` and `GamepadController` produce -- the
 * three are OR'd together by `InputBridge`.
 *
 * Unlike its two siblings this class listens to nothing: it holds state that
 * React pushes into it from `TouchControls.tsx`'s pointer handlers. The
 * split exists so the bit arithmetic -- which is the part that can be wrong
 * in a way nobody notices until a game walks diagonally into a wall -- is
 * testable without a DOM.
 *
 * Face buttons and direction are set through different methods on purpose.
 * A face button is a latch: A is down or it isn't, and B being down says
 * nothing about it. A direction is a *position*: one pointer on one pad
 * reports exactly one of nine states (centre, four cardinals, four
 * diagonals), so publishing it as a whole-mask replacement makes the
 * impossible states -- Left and Right held together, which real hardware
 * cannot produce and some games behave badly on -- unrepresentable rather
 * than merely unlikely.
 */
export class TouchController {
  private buttons = 0

  /** Current controller-0 byte from touch alone. */
  read(): number {
    return this.buttons
  }

  /** Press or release one face button (A, B, Start, Select). */
  setButton(mask: number, pressed: boolean): void {
    this.buttons = pressed ? this.buttons | mask : this.buttons & ~mask
  }

  /**
   * Replace the whole direction field. `mask` is any OR of Up/Down/Left/
   * Right (0 for centred); anything outside `DIRECTIONS` is ignored, so a
   * caller can't smuggle a face button in through the D-pad.
   */
  setDirection(mask: number): void {
    this.buttons = (this.buttons & ~DIRECTIONS) | (mask & DIRECTIONS)
  }

  /**
   * Release everything. Called when the controls unmount, and when the
   * document is hidden: a pointer that goes away while the page is
   * backgrounded (app switch, incoming call) never delivers its `pointerup`,
   * and the alternative is coming back to a game holding Right forever.
   */
  clear(): void {
    this.buttons = 0
  }
}

/** Deadzone as a fraction of the pad's half-width. Below this the pad reads
 * as centred -- a thumb resting dead-centre shouldn't pick a direction out
 * of sub-pixel jitter. */
const DEADZONE = 0.22

/** Half-angle, in radians, of each cardinal's wedge. `Math.PI / 8` is the
 * even eight-way split (45deg per direction, 22.5deg either side of centre);
 * widening it past that biases the pad toward cardinals, which is what you
 * want on a D-pad -- diagonals are for movement, cardinals are for aiming,
 * and an accidental diagonal is the more annoying of the two errors. */
const CARDINAL_HALF_ANGLE = Math.PI / 7

/**
 * Map a pointer offset from the pad's centre to a direction mask.
 *
 * `dx`/`dy` are normalised to the pad's half-size, so (-1, -1) is the
 * top-left corner and (0, 0) is dead centre. `dy` is screen-space --
 * positive is *down*, matching `clientY`.
 *
 * Geometry rather than four hit-boxed arrow buttons, because four buttons
 * cannot express a diagonal (no game that needs one is playable) and cannot
 * be slid between (every direction change costs a lift-and-retap). One pad,
 * one pointer, an angle.
 */
export function directionFromOffset(dx: number, dy: number): number {
  if (Math.hypot(dx, dy) < DEADZONE) return 0

  // 0 = right, and increasing counter-clockwise in maths convention; `dy` is
  // negated so that "up" on screen is a positive angle.
  const angle = Math.atan2(-dy, dx)
  const near = (target: number) => {
    // Wrapped into [0, 2pi) before recentring, because JS `%` keeps the sign
    // of its left operand: `atan2` returns -pi (not pi) for a pure-Left
    // offset, since `-dy` of a zero `dy` is negative zero, and a plain
    // `% (2 * Math.PI)` leaves that negative -- which read as 2pi away from
    // Left and sent the pad diagonal on a dead-horizontal push.
    const tau = 2 * Math.PI
    const delta = Math.abs((((angle - target + Math.PI) % tau) + tau) % tau - Math.PI)
    return delta <= CARDINAL_HALF_ANGLE
  }

  if (near(0)) return Button.Right
  if (near(Math.PI / 2)) return Button.Up
  if (near(Math.PI)) return Button.Left
  if (near(-Math.PI / 2)) return Button.Down

  // Outside every cardinal wedge: a diagonal, named by which quadrant the
  // offset falls in.
  return (dy < 0 ? Button.Up : Button.Down) | (dx < 0 ? Button.Left : Button.Right)
}
