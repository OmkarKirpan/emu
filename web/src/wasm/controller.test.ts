import { afterEach, describe, expect, it } from 'vitest'
import { Button, KeyboardController } from './controller'

/** Dispatches a real `KeyboardEvent` on `window`, exactly as a browser would
 * for a physical key press -- `KeyboardController` listens there, not on any
 * element, so this is the right level to drive it at rather than calling its
 * private handlers directly. */
function press(code: string): void {
  window.dispatchEvent(new KeyboardEvent('keydown', { code, cancelable: true }))
}
function release(code: string): void {
  window.dispatchEvent(new KeyboardEvent('keyup', { code, cancelable: true }))
}

describe('KeyboardController', () => {
  let controller: KeyboardController

  afterEach(() => {
    controller.dispose()
  })

  it('starts with no buttons held', () => {
    controller = new KeyboardController()
    expect(controller.read()).toBe(0)
  })

  it('maps the four arrow keys to the D-pad, matching controller.zig bit order', () => {
    controller = new KeyboardController()
    press('ArrowUp')
    expect(controller.read()).toBe(Button.Up)
    press('ArrowRight')
    expect(controller.read()).toBe(Button.Up | Button.Right)
  })

  it('maps Z/X to B/A and Enter/Shift to Start/Select', () => {
    controller = new KeyboardController()
    press('KeyZ')
    press('KeyX')
    press('Enter')
    press('ShiftLeft')
    expect(controller.read()).toBe(Button.B | Button.A | Button.Start | Button.Select)
  })

  it('either shift key sets the same Select bit', () => {
    controller = new KeyboardController()
    press('ShiftRight')
    expect(controller.read()).toBe(Button.Select)
  })

  it('releasing a key clears only that bit, leaving others held', () => {
    controller = new KeyboardController()
    press('ArrowLeft')
    press('ArrowDown')
    release('ArrowLeft')
    expect(controller.read()).toBe(Button.Down)
  })

  it('ignores keys with no NES mapping', () => {
    controller = new KeyboardController()
    press('KeyQ')
    press('Space')
    expect(controller.read()).toBe(0)
  })

  it('preventDefault is called only for mapped keys', () => {
    controller = new KeyboardController()
    const mapped = new KeyboardEvent('keydown', { code: 'ArrowUp', cancelable: true })
    const unmapped = new KeyboardEvent('keydown', { code: 'KeyQ', cancelable: true })
    window.dispatchEvent(mapped)
    window.dispatchEvent(unmapped)
    expect(mapped.defaultPrevented).toBe(true)
    expect(unmapped.defaultPrevented).toBe(false)
  })

  it('dispose stops the controller from tracking further key events', () => {
    controller = new KeyboardController()
    press('ArrowUp')
    controller.dispose()
    press('ArrowRight')
    // Only the state from before dispose survives; the second press never landed.
    expect(controller.read()).toBe(Button.Up)
  })
})

/** Keys pressed while a page control has focus: a radio group and a slider
 * both use the arrow keys themselves, and keyboard-only players need them. */
describe('KeyboardController with a focused control', () => {
  let controller: KeyboardController
  let control: HTMLInputElement

  afterEach(() => {
    controller.dispose()
    control.remove()
  })

  function setup(type: string): void {
    controller = new KeyboardController()
    control = Object.assign(document.createElement('input'), { type })
    document.body.append(control)
  }

  /** Dispatched on the control and bubbled up to `window`, the way a key
   * press on a focused element reaches `KeyboardController`. */
  function keyOn(target: EventTarget, type: 'keydown' | 'keyup', code: string): KeyboardEvent {
    const event = new KeyboardEvent(type, { code, cancelable: true, bubbles: true })
    target.dispatchEvent(event)
    return event
  }

  it.each(['radio', 'range'])('leaves arrow keys to a %s the player tabbed to', (type) => {
    setup(type)
    press('Tab')
    const event = keyOn(control, 'keydown', 'ArrowDown')
    expect(event.defaultPrevented).toBe(false)
    expect(controller.read()).toBe(0)
  })

  it('still plays the game when the control was last clicked rather than tabbed to', () => {
    setup('radio')
    press('Tab')
    control.dispatchEvent(new Event('pointerdown', { bubbles: true }))
    const event = keyOn(control, 'keydown', 'ArrowDown')
    expect(event.defaultPrevented).toBe(true)
    expect(controller.read()).toBe(Button.Down)
  })

  it('only gives up the arrows -- other game keys still play', () => {
    setup('radio')
    press('Tab')
    keyOn(control, 'keydown', 'KeyX')
    expect(controller.read()).toBe(Button.A)
  })

  it('a checkbox has no use for arrows, so they still play', () => {
    setup('checkbox')
    press('Tab')
    keyOn(control, 'keydown', 'ArrowLeft')
    expect(controller.read()).toBe(Button.Left)
  })

  it('a release on a tabbed-to control still lets go of a button held from play', () => {
    setup('radio')
    press('ArrowDown')
    press('Tab')
    keyOn(control, 'keyup', 'ArrowDown')
    expect(controller.read()).toBe(0)
  })
})
