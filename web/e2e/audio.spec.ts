import type { Page } from '@playwright/test'
import { expect, test } from './fixtures'

/** Mirrors `AudioOutput.tsx`'s `Window.__audioDebug__` shape. Not shared
 * via import: `e2e/`'s own `tsconfig.e2e.json` project doesn't include
 * `src/`, so the ambient `declare global` there isn't visible here -- this
 * is a debug/test-only contract, not application logic, so a second,
 * narrow copy of the shape is a reasonable place to stop rather than
 * wiring the two tsconfig projects together for it. */
type AudioDebugWindow = { __audioDebug__?: () => { fill: number; underrunCount: number } | null }

function readAudioDebug(page: Page) {
  return page.evaluate(() => (window as unknown as AudioDebugWindow).__audioDebug__?.() ?? null)
}

/** Polls until the underrun counter holds the same value across two
 * consecutive samples, and returns it. Throws if it never settles -- which
 * is the signature of a genuinely broken pipeline (continuously starved),
 * as opposed to a brief startup blip. */
async function waitForUnderrunsToSettle(page: Page): Promise<number> {
  let previous: number | null = null
  for (let attempt = 0; attempt < 20; attempt++) {
    await page.waitForTimeout(300)
    const current = (await readAudioDebug(page))?.underrunCount
    if (current === undefined) continue
    if (current === previous) return current
    previous = current
  }
  throw new Error(`underrun count never stopped climbing (last saw ${previous}) -- the ring is being starved continuously`)
}

/**
 * Exercises the real ENG-62 pipeline end to end -- COOP/COEP cross-origin
 * isolation, a shared-memory wasm instance in a dedicated Worker, an
 * AudioWorkletNode reading the ring via `Atomics` on the real-time audio
 * thread -- against the actual production build (this suite runs against
 * `vite preview`, not `vite dev`; see `playwright.config.ts`). There's no
 * real speaker to listen to in CI, so this asserts on the shared control
 * block's own numbers instead: a healthy, bounded ring fill and no
 * *further* underruns once already past startup is exactly ENG-70's "no
 * underrun/desync glitches" acceptance criterion, made machine-checkable.
 */
test('audio output reaches a stable ring fill with no steady-state underruns', async ({ page }) => {
  const button = page.locator('.audio-output button')
  await button.click() // a real Playwright click is a trusted gesture, satisfying the autoplay policy `AudioContext` needs
  await expect(button).toHaveText('Audio playing')

  // The Worker only starts pushing stats once its wasm instance is up and
  // the handshake with the worklet has completed -- poll rather than a
  // fixed wait so this isn't racing that startup.
  await expect
    .poll(() => readAudioDebug(page), {
      message: 'no audio debug stats ever arrived from the Worker',
      timeout: 5000,
    })
    .not.toBeNull()

  // Wait for the counter to *stop moving* before treating it as a
  // baseline, rather than sampling at some fixed point and hoping startup
  // is over. Two things make that necessary. The Worker holds the worklet
  // out of the audio graph until the ring reaches target fill (see
  // `emulatorWorker.ts`'s `awaitAudioPrimed`), so there should be no
  // startup burst at all now -- but "should be none" is exactly the kind of
  // claim that shouldn't be assumed, and on a loaded CI box the priming
  // window can still slip. Waiting for stability covers both, and is
  // strictly stronger than a fixed sample: if underruns never stopped
  // accruing -- the actual regression this guards -- this throws instead of
  // quietly baselining a moving number.
  const baselineUnderruns = await waitForUnderrunsToSettle(page)

  // DRC deliberately corrects drift slowly (see `audio_ring.zig`'s
  // `fill_ema_alpha`) -- give it real wall-clock time to settle out of its
  // cold-start ramp before asserting steady state, rather than reading a
  // meaningless mid-ramp snapshot.
  await page.waitForTimeout(2000)

  const settled = await readAudioDebug(page)
  expect(settled).not.toBeNull()
  // Neither starved nor pinned at capacity -- the same "actually stable,
  // not just riding one clamp" claim `audio_ring_test.zig`'s "DRC keeps the
  // ring stable" test makes natively, now confirmed through the real
  // Worker/worklet/Atomics plumbing instead of a simulated consumer.
  expect(settled!.fill).toBeGreaterThan(0)
  expect(settled!.fill).toBeLessThan(8192)
  expect(settled!.underrunCount).toBe(baselineUnderruns)
})
