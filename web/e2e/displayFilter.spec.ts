import { expect, test, type Page } from '@playwright/test'
import { BACKDROP_RGBA, findSpriteCol, pixelAt, readFramebuffer, SPRITE_RGBA, SPRITE_ROW, waitUntilRunning } from './helpers'

/**
 * The display filter setting (`src/display/DisplaySettings.tsx`).
 *
 * Not using `./fixtures`, for the same reason `renderer.spec.ts` doesn't:
 * these navigate with their own query strings. Console errors are collected
 * here instead.
 *
 * What this can and can't see: the canvas is transferred to the Worker, so
 * its filtered pixels can't be read back from the page -- `readFramebuffer`
 * reads the *unfiltered* framebuffer in wasm memory. So these check the
 * setting's behaviour (applied, persisted, disabled where unsupported) and
 * that filtering never touches the emulated picture itself. Whether the CRT
 * effect looks right needs eyes on a GPU, the same limit `shader.test.ts`
 * states.
 */

function collectErrors(page: Page): string[] {
  const errors: string[] = []
  page.on('pageerror', (err) => errors.push(err.message))
  page.on('console', (msg) => {
    if (msg.type() === 'error') errors.push(msg.text())
  })
  return errors
}

async function expectSpriteIntact(page: Page): Promise<void> {
  const framebuffer = await readFramebuffer(page)
  const col = findSpriteCol(framebuffer, SPRITE_ROW, BACKDROP_RGBA)
  expect(col).toBeGreaterThanOrEqual(0)
  expect(pixelAt(framebuffer, SPRITE_ROW, col)).toEqual(SPRITE_RGBA)
}

test('on the Canvas 2D fallback the filter setting is disabled, and says why', async ({ page }) => {
  const errors = collectErrors(page)
  await page.goto('/?renderer=canvas2d')
  await waitUntilRunning(page)

  await expect(page.getByRole('radio', { name: 'CRT' })).toBeDisabled()
  await expect(page.locator('.display-note')).toHaveText('Filters are not available in this browser.')
  await expect(page.locator('.screen-canvas')).toHaveAttribute('data-filter', 'none')
  await expectSpriteIntact(page)
  expect(errors).toEqual([])
})

// Needs a machine where WebGPU actually engages. CI runners have no GPU (see
// `renderer.spec.ts`'s caveat), so there this skips rather than passes.
test('CRT can be switched on, fine-tuned, and survives a reload', async ({ page }) => {
  const errors = collectErrors(page)
  await page.goto('/?debug')
  await waitUntilRunning(page)
  const renderer = await page.locator('.renderer-readout').getAttribute('data-renderer')
  test.skip(renderer !== 'webgpu', 'display filters need WebGPU, which this machine did not stand up')

  const crt = page.getByRole('radio', { name: 'CRT' })
  await expect(crt).toBeEnabled()
  await crt.check()
  await expect(page.locator('.screen-canvas')).toHaveAttribute('data-filter', 'crt')
  for (const option of ['Scanlines', 'Screen curvature', 'Chromatic aberration', 'Vignette']) {
    await expect(page.getByRole('checkbox', { name: option })).toBeChecked()
  }
  await page.getByRole('checkbox', { name: 'Vignette' }).uncheck()

  // Presentational only: the emulated frame underneath is untouched.
  await expectSpriteIntact(page)

  await page.reload()
  await waitUntilRunning(page)
  await expect(page.getByRole('radio', { name: 'CRT' })).toBeChecked()
  await expect(page.getByRole('checkbox', { name: 'Scanlines' })).toBeChecked()
  await expect(page.getByRole('checkbox', { name: 'Vignette' })).not.toBeChecked()
  await expect(page.locator('.screen-canvas')).toHaveAttribute('data-filter', 'crt')

  await page.getByRole('radio', { name: 'Off' }).check()
  await expect(page.locator('.screen-canvas')).toHaveAttribute('data-filter', 'none')
  await expect(page.getByRole('checkbox')).toHaveCount(0)
  expect(errors).toEqual([])
})
