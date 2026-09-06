import { expect, test } from '@playwright/test'
import { BACKDROP_RGBA, findSpriteCol, pixelAt, readFramebuffer, SPRITE_RGBA, SPRITE_ROW, waitUntilRunning } from './helpers'

/**
 * ENG-70's "both renderer paths verified (force Canvas2D fallback and
 * confirm it still works)".
 *
 * Not using `./fixtures`: these navigate with their own query strings, and
 * the fixture's auto-`goto('/')` would race that.
 *
 * A caveat worth stating plainly, since it bounds what these prove: which
 * backend the *unforced* case picks depends on the machine. WebGPU is gated
 * by browser, OS and GPU (ENG-57), and CI runners generally have no GPU at
 * all -- so in CI both tests below almost certainly exercise Canvas 2D, and
 * the first one only asserts that *whichever* backend was chosen is
 * reported honestly and renders correctly. On a machine with working
 * WebGPU, the same test covers the WebGPU path for real. That asymmetry is
 * why the readout exists at all: it turns "which one am I on?" into
 * something a human or a test can read rather than infer.
 */
test('reports whichever renderer it stood up, and renders correctly on it', async ({ page }) => {
  await page.goto('/')
  await waitUntilRunning(page)

  const readout = page.locator('.renderer-readout')
  await expect(readout).toBeVisible()
  const kind = await readout.getAttribute('data-renderer')
  expect(kind, 'renderer readout should name a known backend').toMatch(/^(webgpu|canvas2d)$/)

  // Whatever backend that is, the picture has to be right on it.
  const framebuffer = await readFramebuffer(page)
  const col = findSpriteCol(framebuffer, SPRITE_ROW, BACKDROP_RGBA)
  expect(col).toBeGreaterThanOrEqual(0)
  expect(pixelAt(framebuffer, SPRITE_ROW, col)).toEqual(SPRITE_RGBA)
})

test('?renderer=canvas2d forces the Canvas 2D fallback and it still works', async ({ page }) => {
  await page.goto('/?renderer=canvas2d')
  await waitUntilRunning(page)

  await expect(page.locator('.renderer-readout')).toHaveAttribute('data-renderer', 'canvas2d')

  const framebuffer = await readFramebuffer(page)
  const col = findSpriteCol(framebuffer, SPRITE_ROW, BACKDROP_RGBA)
  expect(col).toBeGreaterThanOrEqual(0)
  expect(pixelAt(framebuffer, SPRITE_ROW, col)).toEqual(SPRITE_RGBA)

  // Still a live emulator on the fallback path, not just a correct first
  // frame: input has to move the sprite too.
  await page.keyboard.down('ArrowRight')
  await page.waitForTimeout(400)
  await page.keyboard.up('ArrowRight')
  const after = findSpriteCol(await readFramebuffer(page), SPRITE_ROW, BACKDROP_RGBA)
  expect(after).toBeGreaterThan(col)
})
