import { afterEach, describe, expect, it } from 'vitest'
import { Button } from './controller'
import { GamepadController } from './gamepad'

/** Builds a fake `Gamepad` with only the fields `GamepadController` reads,
 * standard-mapping button indices pressed per `pressed`. `jsdom` has no real
 * Gamepad API, so `navigator.getGamepads` is stubbed directly rather than
 * driving this through any browser event -- there isn't one; the API is
 * poll-only. */
function fakeGamepad(pressed: readonly number[], mapping: GamepadMappingType | '' = 'standard'): Gamepad {
  const buttons: GamepadButton[] = Array.from({ length: 17 }, (_, i) => ({
    pressed: pressed.includes(i),
    touched: pressed.includes(i),
    value: pressed.includes(i) ? 1 : 0,
  }))
  return { connected: true, mapping, buttons, axes: [], id: 'fake', index: 0, timestamp: 0, vibrationActuator: null } as unknown as Gamepad
}

function stubGamepads(...pads: (Gamepad | null)[]): void {
  navigator.getGamepads = () => pads
}

describe('GamepadController', () => {
  const originalGetGamepads = navigator.getGamepads?.bind(navigator)

  afterEach(() => {
    if (originalGetGamepads) navigator.getGamepads = originalGetGamepads
  })

  it('reads no buttons when no gamepad is connected', () => {
    stubGamepads(null)
    expect(new GamepadController().read()).toBe(0)
  })

  it('maps the standard mapping d-pad indices (12-15) to the D-pad', () => {
    stubGamepads(fakeGamepad([12, 15]))
    expect(new GamepadController().read()).toBe(Button.Up | Button.Right)
  })

  it('maps face buttons 0/1 to B/A and 8/9 to Select/Start', () => {
    stubGamepads(fakeGamepad([0, 1, 8, 9]))
    expect(new GamepadController().read()).toBe(Button.B | Button.A | Button.Select | Button.Start)
  })

  it('ignores a gamepad that is not using the standard mapping', () => {
    stubGamepads(fakeGamepad([0, 1], ''))
    expect(new GamepadController().read()).toBe(0)
  })

  it('combines button state across multiple connected gamepads', () => {
    stubGamepads(fakeGamepad([12]), fakeGamepad([0]))
    expect(new GamepadController().read()).toBe(Button.Up | Button.B)
  })

  it('returns 0 when navigator.getGamepads is unavailable', () => {
    // @ts-expect-error -- simulating an environment without the Gamepad API
    navigator.getGamepads = undefined
    expect(new GamepadController().read()).toBe(0)
  })
})
