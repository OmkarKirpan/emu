import type { Page } from '@playwright/test'
import { expect, test } from './fixtures'
import { BACKDROP_RGBA, findSpriteCol, readFramebuffer, SPRITE_ROW } from './helpers'

/**
 * ENG-91's speed control (0.5x/1x/2x), measured the same way
 * `pacing.spec.ts` measures the base 1x rate: real wall-clock time against
 * the demo ROM's exactly-one-pixel-per-frame sprite movement. A real-clock
 * measurement is a measurement of the host machine as much as of the
 * emulator, so -- same reasoning as `pacing.spec.ts`/`audio.spec.ts` -- this
 * runs in `playwright.config.ts`'s `timing` project, alone, after the rest
 * of the suite (ENG-85): several parallel Chromium instances each running a
 * wasm emulator at up to 2x would push the measured rate below tolerance
 * for no reason the emulator itself is responsible for.
 */
const NES_FPS = 60.0988
/** Looser than `pacing.spec.ts`'s +/-6fps absolute tolerance: a 2x/0.5x
 * measurement's *target* itself scales, so a fixed absolute tolerance would
 * be proportionally tighter at 2x and looser at 0.5x for no reason. A
 * relative tolerance keeps the same real-world slack (CI scheduling jitter,
 * `InputBridge`'s own `requestAnimationFrame` cadence for publishing the
 * held key) at either speed -- and that fixed one-rAF-ish latency at both
 * the keydown and the keyup matters proportionally more the shorter the
 * hold, which is why `measureFps`'s callers use a hold of a full second or
 * more rather than `pacing.spec.ts`'s own (also ~1s) window. */
const TOLERANCE_FRACTION = 0.15

async function measureFps(page: Page, holdMs: number): Promise<number> {
  const before = findSpriteCol(await readFramebuffer(page), SPRITE_ROW, BACKDROP_RGBA)
  await page.keyboard.down('ArrowRight')
  const t0 = Date.now()
  await page.waitForTimeout(holdMs)
  const elapsedMs = Date.now() - t0
  await page.keyboard.up('ArrowRight')
  const after = findSpriteCol(await readFramebuffer(page), SPRITE_ROW, BACKDROP_RGBA)
  return ((after - before) / elapsedMs) * 1000
}

test('2x speed plays back at roughly double the real NES frame rate', async ({ page }) => {
  await page.keyboard.press('Equal')
  await expect(page.locator('.flag.speed')).toHaveText('--speed 2x')

  const fps = await measureFps(page, 1000)
  const target = NES_FPS * 2
  expect(fps).toBeGreaterThan(target * (1 - TOLERANCE_FRACTION))
  expect(fps).toBeLessThan(target * (1 + TOLERANCE_FRACTION))
})

test('0.5x speed plays back at roughly half the real NES frame rate', async ({ page }) => {
  await page.keyboard.press('Minus')
  await expect(page.locator('.flag.speed')).toHaveText('--speed 0.5x')

  const fps = await measureFps(page, 1200)
  const target = NES_FPS * 0.5
  expect(fps).toBeGreaterThan(target * (1 - TOLERANCE_FRACTION))
  expect(fps).toBeLessThan(target * (1 + TOLERANCE_FRACTION))
})

/**
 * ENG-91's own acceptance criterion, stated for speed rather than pause:
 * "speed changes don't desync audio from video... never left to underrun/
 * overflow". There's no speaker in CI (same limitation `audio.spec.ts`
 * notes), so this asserts on the shared control block's fill exactly the
 * way that file's pause test does -- a ring a live worklet is still
 * draining holds near target; one nobody is reading either sits wherever
 * `syncAudioMute`'s mute left it (which is what "muted, not left to
 * overflow" cashes out to: bounded, not silently corrupted) or, once 1x
 * returns, is freshly re-primed to target by `beginAudioReprime`.
 */
type AudioDebugWindow = {
  __audioDebug__?: () => { fill: number; underrunCount: number; peak: number; rms: number } | null
}

function readAudioDebug(page: Page) {
  return page.evaluate(() => (window as unknown as AudioDebugWindow).__audioDebug__?.() ?? null)
}

test('2x speed mutes audio cleanly and re-primes it without a burst on return to 1x', async ({ page }) => {
  const audioButton = page.locator('.audio-enable')
  await audioButton.click()
  await expect(audioButton).toHaveText('Audio playing')
  await expect
    .poll(() => readAudioDebug(page), { message: 'no audio debug stats ever arrived from the Worker', timeout: 5000 })
    .not.toBeNull()

  let previous: number | null = null
  for (let attempt = 0; attempt < 20 && previous === null; attempt++) {
    await page.waitForTimeout(300)
    const current = (await readAudioDebug(page))?.underrunCount
    if (current === previous) break
    previous = current ?? null
  }
  const baseline = (await readAudioDebug(page))!.underrunCount

  await page.keyboard.press('Equal') // 1x -> 2x
  await expect(page.locator('.flag.speed')).toHaveText('--speed 2x')
  await page.waitForTimeout(1500)

  const at2x = await readAudioDebug(page)
  expect(at2x).not.toBeNull()
  // Muted, not starving: a live worklet drained by a producer running at
  // half its expected rate would otherwise be racking up underruns for the
  // whole 1.5s wait.
  expect(
    at2x!.underrunCount,
    `2x speed should mute the worklet, not starve it (baseline ${baseline}, now ${at2x!.underrunCount})`,
  ).toBe(baseline)

  await page.keyboard.press('Minus') // 2x -> 1x
  await expect(page.locator('.flag.speed')).toHaveText('--speed 1x')
  await page.waitForTimeout(1000)

  const backAt1x = await readAudioDebug(page)
  expect(backAt1x).not.toBeNull()
  expect(
    backAt1x!.underrunCount,
    `returning to 1x should re-prime cleanly, not crackle (baseline ${baseline}, now ${backAt1x!.underrunCount})`,
  ).toBe(baseline)
  expect(backAt1x!.rms).toBeGreaterThan(0.005)
})
