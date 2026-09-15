import type { Page } from '@playwright/test'
import { expect, test } from './fixtures'
import { BACKDROP_RGBA, findSpriteCol, readFramebuffer, SPRITE_ROW } from './helpers'

/**
 * ENG-91's rewind, frame-step and speed control, end to end against the
 * real Worker (`emulatorWorker.ts`'s `rewinding`/`speedMultiplier`
 * machinery) -- not unit tests of `rewindRing.ts`/`speedControl.ts` (see
 * their own `.test.ts` files for the eviction/stepping policy in
 * isolation), but confirmation that the actual keys and app-bar controls
 * drive that machinery correctly through a real emulated machine.
 *
 * The observable is the same one `pause.spec.ts`/`pacing.spec.ts`/
 * `savestates.spec.ts` use: the demo ROM's sprite moves one pixel per
 * emulated frame while a direction is held (see those files' own comments).
 */

const pauseButton = '.flag.pause'
const rewindButton = '.flag.rewind'
const stepButton = '.flag.step'
const speedButton = '.flag.speed'

function spriteCol(page: Page): Promise<number> {
  return readFramebuffer(page).then((fb) => findSpriteCol(fb, SPRITE_ROW, BACKDROP_RGBA))
}

test('holding R rewinds the picture backward, and releasing resumes forward play', async ({ page }) => {
  await expect(page.locator('.screen-indicator-rewind')).toHaveCount(0)

  // Build some forward history to rewind through.
  await page.keyboard.down('ArrowRight')
  await page.waitForTimeout(1000)
  await page.keyboard.up('ArrowRight')
  const before = await spriteCol(page)

  await page.keyboard.down('KeyR')
  await expect(page.locator('.screen-indicator-rewind')).toHaveText('Rewinding')
  await expect(page.locator(rewindButton)).toHaveAttribute('aria-pressed', 'true')

  // Two reads while held: the picture must keep walking backward, not just
  // freeze at one earlier frame.
  await expect.poll(() => spriteCol(page)).toBeLessThan(before)
  const midRewind = await spriteCol(page)
  await expect.poll(() => spriteCol(page)).toBeLessThanOrEqual(midRewind)

  await page.keyboard.up('KeyR')
  await expect(page.locator('.screen-indicator-rewind')).toHaveCount(0)
  await expect(page.locator(rewindButton)).toHaveAttribute('aria-pressed', 'false')
  const afterRelease = await spriteCol(page)

  // Forward play resumes from wherever rewind stopped -- not a burst of
  // catch-up frames, not stuck.
  await page.keyboard.down('ArrowRight')
  await expect.poll(() => spriteCol(page)).toBeGreaterThan(afterRelease)
  await page.keyboard.up('ArrowRight')
})

test('rewind while paused leaves the game paused on release', async ({ page }) => {
  await page.locator(pauseButton).click()
  await expect(page.locator(pauseButton)).toHaveText('--resume')

  await page.keyboard.down('KeyR')
  await page.waitForTimeout(200)
  await page.keyboard.up('KeyR')

  await expect(page.locator(pauseButton)).toHaveText('--resume')
  await expect(page.locator('.screen-overlay-paused')).toHaveText('Paused')
  await expect(page.locator('.screen-indicator-rewind')).toHaveCount(0)
})

test('rewind while running resumes running on release', async ({ page }) => {
  await page.keyboard.down('KeyR')
  await page.waitForTimeout(200)
  await page.keyboard.up('KeyR')

  await expect(page.locator(pauseButton)).toHaveText('--pause')
  await expect(page.locator('.screen-overlay-paused')).toHaveCount(0)

  const col = await spriteCol(page)
  await page.keyboard.down('ArrowRight')
  await expect.poll(() => spriteCol(page)).toBeGreaterThan(col)
  await page.keyboard.up('ArrowRight')
})

test('K frame-steps exactly one frame while paused, and leaves it paused', async ({ page }) => {
  await page.keyboard.down('ArrowRight')
  await page.locator(pauseButton).click()
  await expect(page.locator(pauseButton)).toHaveText('--resume')

  const before = await spriteCol(page)
  await page.keyboard.press('KeyK')
  await expect.poll(() => spriteCol(page)).toBe(before + 1)
  await expect(page.locator(pauseButton)).toHaveText('--resume')
  await expect(page.locator('.screen-overlay-paused')).toHaveText('Paused')

  await page.keyboard.press('KeyK')
  await expect.poll(() => spriteCol(page)).toBe(before + 2)
  // Holding K down (key-repeat) must not turn into a burst of steps -- only
  // an actual second press does.
  await page.waitForTimeout(300)
  expect(await spriteCol(page)).toBe(before + 2)

  await page.keyboard.up('ArrowRight')
})

test('the --step button is disabled while running and enabled while paused', async ({ page }) => {
  await expect(page.locator(stepButton)).toBeDisabled()
  await page.locator(pauseButton).click()
  await expect(page.locator(stepButton)).toBeEnabled()
  await page.locator(pauseButton).click()
  await expect(page.locator(stepButton)).toBeDisabled()
})

test('the speed control cycles through every level, and -/= step it directly', async ({ page }) => {
  const speed = page.locator(speedButton)
  await expect(speed).toHaveText('--speed 1x')
  await expect(page.locator('.screen-indicator-speed')).toHaveCount(0)

  await speed.click()
  await expect(speed).toHaveText('--speed 2x')
  await expect(page.locator('.screen-indicator-speed')).toHaveText('2x')

  await speed.click() // wraps 2x -> 0.5x
  await expect(speed).toHaveText('--speed 0.5x')
  await expect(page.locator('.screen-indicator-speed')).toHaveText('0.5x')

  await speed.click()
  await expect(speed).toHaveText('--speed 1x')
  await expect(page.locator('.screen-indicator-speed')).toHaveCount(0)

  await page.keyboard.press('Minus')
  await expect(speed).toHaveText('--speed 0.5x')
  await page.keyboard.press('Minus') // clamps at the bottom, does not wrap
  await expect(speed).toHaveText('--speed 0.5x')

  await page.keyboard.press('Equal')
  await expect(speed).toHaveText('--speed 1x')
  await page.keyboard.press('Equal')
  await expect(speed).toHaveText('--speed 2x')
  await page.keyboard.press('Equal') // clamps at the top, does not wrap
  await expect(speed).toHaveText('--speed 2x')

  // Leave the session at 1x -- `sessionContinuity`/`savestates` share the
  // same webServer instance's worker only within a single test's page, so
  // this isn't load-bearing across tests, but it keeps this file's own
  // remaining tests unsurprising if more are added below.
  await page.keyboard.press('Minus')
})
