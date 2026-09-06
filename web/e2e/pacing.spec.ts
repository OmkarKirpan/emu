import { expect, test } from './fixtures'
import { BACKDROP_RGBA, findSpriteCol, readFramebuffer, SPRITE_ROW } from './helpers'

/** NTSC's true frame rate (see `timing.ts`'s `NTSC_FRAME_MS`).
 * `sprite_input_demo.nes` moves its sprite exactly 1px per NES frame while a
 * direction is held, which is what turns "pixels moved / wall-clock time"
 * into a direct fps measurement below. */
const NES_FPS = 60.0988
const TOLERANCE_FPS = 6 // generous: this is a real-clock measurement, not a mock timer

/**
 * Confirms the emulator plays at the NES's real frame rate.
 *
 * This used to need its own Chromium launch with vsync-unclamping flags,
 * standing in for a 120/144Hz display, to prove emulation speed didn't
 * couple to `requestAnimationFrame`'s rate (`MAX_CATCHUP_FRAMES`'s reason
 * for existing, back when the wasm host ran on the main thread). As of the
 * M5 Worker migration that coupling has nothing left to test:
 * `emulatorWorker.ts` paces itself with a `setTimeout` schedule that was
 * never tied to display refresh in the first place (see that file's
 * `scheduleLoop`), so there's no fast-display scenario left to simulate --
 * a plain real-time measurement against the standard fixture is now the
 * whole test.
 */
test('emulation runs at the real NES frame rate', async ({ page }) => {
  const before = findSpriteCol(await readFramebuffer(page), SPRITE_ROW, BACKDROP_RGBA)
  await page.keyboard.down('ArrowRight')
  const t0 = Date.now()
  await page.waitForTimeout(1000)
  const elapsedMs = Date.now() - t0
  await page.keyboard.up('ArrowRight')
  const after = findSpriteCol(await readFramebuffer(page), SPRITE_ROW, BACKDROP_RGBA)

  const measuredFps = ((after - before) / elapsedMs) * 1000
  expect(measuredFps).toBeGreaterThan(NES_FPS - TOLERANCE_FPS)
  expect(measuredFps).toBeLessThan(NES_FPS + TOLERANCE_FPS)
})
