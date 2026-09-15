import type { Page } from '@playwright/test'
import { expect, test } from './fixtures'
import { BACKDROP_RGBA, findSpriteCol, readFramebuffer, SPRITE_ROW, waitUntilRunning } from './helpers'

/**
 * Gamepad input end to end: `GamepadController` polling -> `InputBridge`'s
 * shared slot -> the Worker's `set_input` -> the demo ROM's sprite moving.
 * Drives the real pipeline with only `navigator.getGamepads` faked, since
 * headless Chromium has no device to read.
 *
 * The left-stick case is the regression test for "gamepad not working" on an
 * Xbox One S in Chrome: the pad reported the standard mapping and its d-pad
 * worked, but the left stick -- where an Xbox player's thumb actually goes --
 * was never read. The slot-1 case pins that pads outside slot 0 count too
 * (that Xbox pad sat in slot 2).
 */

/** The shape of fake pad a test installs: which slot of `getGamepads()` it
 * sits in, what `mapping` it reports, which button indices are held, and its
 * axes. Headless Chromium has no real Gamepad API device, so
 * `navigator.getGamepads` is replaced before the app's first script runs. */
interface FakePad {
  index: number
  mapping: '' | 'standard'
  pressed: number[]
  axes: number[]
}

async function installFakePad(page: Page, pad: FakePad): Promise<void> {
  await page.addInitScript((spec: FakePad) => {
    const gamepad = {
      id: 'fake-pad',
      index: spec.index,
      connected: true,
      mapping: spec.mapping,
      timestamp: 0,
      axes: spec.axes,
      buttons: Array.from({ length: 17 }, (_, i) => ({
        pressed: spec.pressed.includes(i),
        touched: spec.pressed.includes(i),
        value: spec.pressed.includes(i) ? 1 : 0,
      })),
    }
    // Held only while `__padHeld` is true, so the test controls when the
    // "press" starts and ends, like `keyboard.down`/`up` in emulator.spec.ts.
    ;(window as unknown as { __padHeld: boolean }).__padHeld = false
    const idle = { ...gamepad, axes: spec.axes.map(() => 0), buttons: gamepad.buttons.map(() => ({ pressed: false, touched: false, value: 0 })) }
    navigator.getGamepads = () => {
      const slots: (typeof gamepad | null)[] = [null, null, null, null]
      slots[spec.index] = (window as unknown as { __padHeld: boolean }).__padHeld ? gamepad : idle
      return slots as unknown as (Gamepad | null)[]
    }
  }, pad)
  await page.reload()
  await waitUntilRunning(page)
}

async function holdPad(page: Page, ms: number): Promise<void> {
  await page.evaluate(() => ((window as unknown as { __padHeld: boolean }).__padHeld = true))
  await page.waitForTimeout(ms)
  await page.evaluate(() => ((window as unknown as { __padHeld: boolean }).__padHeld = false))
}

const cases: [string, FakePad][] = [
  ['standard pad, d-pad right (button 15)', { index: 0, mapping: 'standard', pressed: [15], axes: [0, 0, 0, 0] }],
  ['standard pad in slot 1, d-pad right', { index: 1, mapping: 'standard', pressed: [15], axes: [0, 0, 0, 0] }],
  ['standard pad, left stick pushed right (axes[0] = 1)', { index: 0, mapping: 'standard', pressed: [], axes: [1, 0, 0, 0] }],
]

for (const [name, pad] of cases) {
  test(`gamepad moves the sprite right: ${name}`, async ({ page }) => {
    await installFakePad(page, pad)
    const before = findSpriteCol(await readFramebuffer(page), SPRITE_ROW, BACKDROP_RGBA)

    await holdPad(page, 400)

    const after = findSpriteCol(await readFramebuffer(page), SPRITE_ROW, BACKDROP_RGBA)
    expect(after, `sprite col before=${before} after=${after}`).toBeGreaterThan(before)
  })
}
