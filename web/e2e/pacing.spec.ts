import { chromium, expect, test } from '@playwright/test'
import { BACKDROP_RGBA, findSpriteCol, readFramebuffer, SPRITE_ROW, waitUntilRunning } from './helpers'

/** NTSC's true frame rate (see `EmulatorScreen.tsx`'s `NTSC_FRAME_MS`).
 * `demo.spec.ts`'s ROM moves its sprite exactly 1px per NES frame while a
 * direction is held, which is what turns "pixels moved / wall-clock time"
 * into a direct fps measurement below. */
const NES_FPS = 60.0988
const TOLERANCE_FPS = 6 // generous: this is a real-clock measurement, not a mock timer

/**
 * Not part of the shared `test`/`fixtures.ts` setup: this spec needs its own
 * browser launched with flags that unclamp `requestAnimationFrame` from
 * vsync, standing in for a fast (120/144Hz) display -- more extreme than
 * either, deliberately, so an unpaced loop is unmistakable rather than a
 * borderline pass. See `EmulatorScreen.tsx`'s `NTSC_FRAME_MS`/
 * `MAX_CATCHUP_FRAMES` for the fix this guards.
 */
test('emulation speed is independent of the display refresh rate', async ({ baseURL }) => {
  const browser = await chromium.launch({
    args: ['--disable-gpu-vsync', '--disable-frame-rate-limit'],
    // A manual `chromium.launch()` bypasses `playwright.config.ts` entirely
    // (that config only governs the `page`/`browser` fixtures), so the same
    // escape hatch has to be repeated here -- see the config's own comment.
    executablePath: process.env.PW_CHROMIUM_PATH,
  })
  try {
    const page = await browser.newPage()
    await page.goto(baseURL ?? 'http://localhost:4173')
    await waitUntilRunning(page)

    // Confirm the unclamp actually worked -- if this comes back near 60,
    // the flags didn't take effect on this platform and the test below
    // wouldn't be exercising anything.
    const rafHz = await page.evaluate(
      () =>
        new Promise<number>((resolve) => {
          let n = 0
          const t0 = performance.now()
          const tick = () => {
            n++
            if (performance.now() - t0 < 500) requestAnimationFrame(tick)
            else resolve(n * 2)
          }
          requestAnimationFrame(tick)
        }),
    )
    test.skip(rafHz < 90, `rAF only reached ${rafHz.toFixed(0)}Hz on this runner -- can't exercise fast-display pacing here`)

    const before = findSpriteCol(await readFramebuffer(page), SPRITE_ROW, BACKDROP_RGBA)
    await page.keyboard.down('ArrowRight')
    const t0 = Date.now()
    await page.waitForTimeout(1000)
    const elapsedMs = Date.now() - t0
    await page.keyboard.up('ArrowRight')
    const after = findSpriteCol(await readFramebuffer(page), SPRITE_ROW, BACKDROP_RGBA)

    const measuredFps = ((after - before) / elapsedMs) * 1000
    expect(measuredFps, `rAF ran at ~${rafHz.toFixed(0)}Hz`).toBeGreaterThan(NES_FPS - TOLERANCE_FPS)
    expect(measuredFps, `rAF ran at ~${rafHz.toFixed(0)}Hz`).toBeLessThan(NES_FPS + TOLERANCE_FPS)
  } finally {
    await browser.close()
  }
})
