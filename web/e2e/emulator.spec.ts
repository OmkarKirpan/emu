import { expect, test } from './fixtures'
import { BACKDROP_RGBA, findSpriteCol, findSpriteRow, pixelAt, readFramebuffer, SPRITE_RGBA, SPRITE_ROW } from './helpers'

test('boots the demo ROM with no loading/error overlay left showing', async ({ page }) => {
  await expect(page.locator('.screen-overlay')).toHaveCount(0)
})

test('renders the sprite in its correct color against the backdrop', async ({ page }) => {
  const fb = await readFramebuffer(page)
  const col = findSpriteCol(fb, SPRITE_ROW, BACKDROP_RGBA)
  expect(col).toBeGreaterThanOrEqual(0)
  expect(pixelAt(fb, SPRITE_ROW, col)).toEqual(SPRITE_RGBA)
  // A pixel just outside the 8x8 block should still be plain backdrop.
  expect(pixelAt(fb, SPRITE_ROW, col - 1)).toEqual(BACKDROP_RGBA)
})

for (const [key, axis, direction] of [
  ['ArrowRight', 'col', 1],
  ['ArrowLeft', 'col', -1],
  ['ArrowDown', 'row', 1],
  ['ArrowUp', 'row', -1],
] as const) {
  test(`holding ${key} moves the sprite ${direction > 0 ? 'forward' : 'backward'} along its ${axis} axis`, async ({
    page,
  }) => {
    const before = findSpriteCol(await readFramebuffer(page), SPRITE_ROW, BACKDROP_RGBA)

    await page.keyboard.down(key)
    await page.waitForTimeout(400) // several NES frames at 60fps
    await page.keyboard.up(key)

    if (axis === 'col') {
      const after = findSpriteCol(await readFramebuffer(page), SPRITE_ROW, BACKDROP_RGBA)
      expect(Math.sign(after - before)).toBe(direction)
    } else {
      // Vertical movement doesn't change the sprite's column, so scan a
      // fixed column (its known starting one, still inside the 8px-wide
      // block regardless of which row it's now on) for its current row.
      const after = findSpriteRow(await readFramebuffer(page), before, BACKDROP_RGBA)
      expect(after).toBeGreaterThanOrEqual(0)
      expect(Math.sign(after - SPRITE_ROW)).toBe(direction)
    }
  })
}

test('the Reset button reboots the console and the demo resumes rendering', async ({ page }) => {
  await page.keyboard.down('ArrowRight')
  await page.waitForTimeout(400)
  await page.keyboard.up('ArrowRight')

  await page.click('.reset')
  // Give the fresh boot a moment, then confirm the sprite is back and
  // rendering normally rather than the canvas going blank or throwing.
  await page.waitForTimeout(200)
  const fb = await readFramebuffer(page)
  expect(findSpriteCol(fb, SPRITE_ROW, BACKDROP_RGBA)).toBeGreaterThanOrEqual(0)
})
