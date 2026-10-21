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

const STORED_CRT = {
  filter: 'crt',
  crt: { scanlines: true, curvature: true, chromaticAberration: true, vignette: true },
}

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

/** Whether this browser can stand up WebGPU at all -- asked of the browser
 * directly, not inferred from which renderer the app chose, so a filter
 * shader that fails to compile shows up as a failure rather than a skip. */
function hasWebGpu(page: Page): Promise<boolean> {
  return page.evaluate(async () => {
    const gpu = (navigator as Navigator & { gpu?: { requestAdapter(): Promise<unknown> } }).gpu
    return (await gpu?.requestAdapter()) != null
  })
}

/** Moves focus onto `target` with a real Tab press, the way a keyboard-only
 * player arrives -- `KeyboardController` hands arrow keys to a radio group
 * only when it was reached by keyboard. */
async function tabTo(page: Page, target: ReturnType<Page['getByRole']>): Promise<void> {
  await target.focus()
  await page.keyboard.press('Shift+Tab')
  await page.keyboard.press('Tab')
  await expect(target).toBeFocused()
}

test('on the Canvas 2D fallback the filter setting is disabled, and says why', async ({ page }) => {
  const errors = collectErrors(page)
  await page.goto('/?renderer=canvas2d')
  await waitUntilRunning(page)

  await expect(page.getByRole('radio', { name: 'CRT' })).toBeDisabled()
  await expect(page.locator('.display-note')).toHaveText('Not available in this browser: CRT.')
  await expect(page.locator('.screen-canvas')).toHaveAttribute('data-filter', 'none')
  await expectSpriteIntact(page)
  expect(errors).toEqual([])
})

// The case `data-filter`'s guard in `EmulatorScreen.tsx` exists for: CRT
// chosen on a machine that can run it, then a visit where it can't. The
// canvas must keep the `pixelated` upscale, not the smooth one meant for a
// filtered picture.
test('a stored CRT setting is kept but not applied on the Canvas 2D fallback', async ({ page }) => {
  const errors = collectErrors(page)
  await page.addInitScript((stored) => localStorage.setItem('emu.display.filter', stored), JSON.stringify(STORED_CRT))
  await page.goto('/?renderer=canvas2d')
  await waitUntilRunning(page)

  await expect(page.getByRole('radio', { name: 'CRT' })).toBeChecked()
  await expect(page.getByRole('radio', { name: 'CRT' })).toBeDisabled()
  await expect(page.getByRole('checkbox', { name: 'Scanlines' })).toBeDisabled()
  await expect(page.locator('.screen-canvas')).toHaveAttribute('data-filter', 'none')
  await expectSpriteIntact(page)
  expect(errors).toEqual([])
})

test('arrow keys still play the game after a filter radio is clicked', async ({ page }) => {
  const errors = collectErrors(page)
  await page.goto('/?renderer=canvas2d')
  await waitUntilRunning(page)

  await page.getByRole('radio', { name: 'Off' }).click()
  const before = findSpriteCol(await readFramebuffer(page), SPRITE_ROW, BACKDROP_RGBA)
  await page.keyboard.down('ArrowRight')
  await page.waitForTimeout(400)
  await page.keyboard.up('ArrowRight')
  expect(findSpriteCol(await readFramebuffer(page), SPRITE_ROW, BACKDROP_RGBA)).toBeGreaterThan(before)
  await expect(page.getByRole('radio', { name: 'Off' })).toBeChecked()
  expect(errors).toEqual([])
})

// The tests below need a WebGPU adapter. CI's runners have none, and
// Playwright's bundled Chromium doesn't expose one either (see
// `shader.test.ts`), so there they skip. They run with `PW_CHROMIUM_PATH`
// pointed at a real Chrome on a machine with a GPU.
test.describe('with WebGPU', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/?debug')
    await waitUntilRunning(page)
    test.skip(!(await hasWebGpu(page)), 'no WebGPU adapter in this browser')
    // An adapter exists, so anything short of every filter being offered
    // is a regression -- most likely a filter shader that didn't compile.
    await expect(page.locator('.renderer-readout')).toHaveAttribute('data-renderer', 'webgpu')
    await expect(page.locator('.display-note')).toHaveCount(0)
  })

  test('CRT can be switched on, fine-tuned, and survives a reload', async ({ page }) => {
    const errors = collectErrors(page)
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

  test('a keyboard-only player can switch CRT on', async ({ page }) => {
    await tabTo(page, page.getByRole('radio', { name: 'Off' }))
    await page.keyboard.press('ArrowDown')
    await expect(page.getByRole('radio', { name: 'CRT' })).toBeChecked()
    await expect(page.locator('.screen-canvas')).toHaveAttribute('data-filter', 'crt')
  })
})
