import type { Page } from '@playwright/test'
import { expect, test } from './fixtures'
import { BACKDROP_RGBA, findSpriteCol, readFramebuffer, SPRITE_ROW } from './helpers'

/**
 * ENG-90's pause/resume, end to end against the real Worker tick loop
 * (`emulatorWorker.ts`'s `paused` flag) -- not a unit test of
 * `pauseReason.ts` (see `src/emulator/pauseReason.test.ts` for that), but
 * confirmation that toggling it through the actual UI actually freezes and
 * un-freezes emulation.
 *
 * The observable is the same one `pacing.spec.ts` and `savestates.spec.ts`
 * use: the demo ROM's sprite moves one pixel per emulated frame while a
 * direction is held. A frozen framebuffer under a held key is a much
 * stronger claim than a frozen framebuffer with no input at all -- the
 * latter could just mean the sprite reached a wall.
 */

const pauseButton = '.flag.pause'

function spriteCol(page: Page): Promise<number> {
  return readFramebuffer(page).then((fb) => findSpriteCol(fb, SPRITE_ROW, BACKDROP_RGBA))
}

test('the --pause button freezes the picture and --resume continues it', async ({ page }) => {
  await expect(page.locator(pauseButton)).toHaveText('--pause')
  await expect(page.locator('.screen-overlay-paused')).toHaveCount(0)

  await page.keyboard.down('ArrowRight')

  await page.locator(pauseButton).click()
  await expect(page.locator(pauseButton)).toHaveText('--resume')
  await expect(page.locator(pauseButton)).toHaveAttribute('aria-pressed', 'true')
  // ENG-90's canvas-visible pause state, not just the button.
  await expect(page.locator('.screen-overlay-paused')).toHaveText('Paused')

  // Two reads with the direction still held: a genuinely frozen picture
  // must not move between them, even though the input that would move it
  // is still active.
  const frozen1 = await spriteCol(page)
  await page.waitForTimeout(300)
  const frozen2 = await spriteCol(page)
  expect(frozen2).toBe(frozen1)

  await page.locator(pauseButton).click()
  await expect(page.locator(pauseButton)).toHaveText('--pause')
  await expect(page.locator('.screen-overlay-paused')).toHaveCount(0)

  // Resuming must not replay a burst of catch-up frames (ENG-90's own
  // acceptance criterion) -- polling for "eventually greater" rather than
  // asserting a specific delta is what makes this robust to exactly how
  // much wall-clock time the assertions above took.
  await expect.poll(() => spriteCol(page)).toBeGreaterThan(frozen2)

  await page.keyboard.up('ArrowRight')
})

test('the P key toggles pause the same way the button does', async ({ page }) => {
  await page.keyboard.down('ArrowRight')

  await page.keyboard.press('KeyP')
  await expect(page.locator(pauseButton)).toHaveText('--resume')
  const frozen = await spriteCol(page)
  await page.waitForTimeout(300)
  expect(await spriteCol(page)).toBe(frozen)

  await page.keyboard.press('KeyP')
  await expect(page.locator(pauseButton)).toHaveText('--pause')
  await expect.poll(() => spriteCol(page)).toBeGreaterThan(frozen)

  await page.keyboard.up('ArrowRight')
})

test('--reset works while paused, and the game stays paused afterward', async ({ page }) => {
  await page.locator(pauseButton).click()
  await expect(page.locator(pauseButton)).toHaveText('--resume')

  // `--reset` must stay enabled and effective while paused (see
  // `emulatorWorker.ts`'s `paused` doc comment: message handlers run off
  // the message, not the frozen tick loop) -- and must not itself resume
  // the game.
  await expect(page.locator('.reset')).toBeEnabled()
  await page.locator('.reset').click()
  await expect(page.locator(pauseButton)).toHaveText('--resume')
  await expect(page.locator('.screen-overlay-paused')).toHaveText('Paused')
})
