import type { Page } from '@playwright/test'
import { expect, test } from './fixtures'

/** Mirrors `AudioTestTone.tsx`'s `Window.__audioDebug__` shape. Not shared
 * via import: `e2e/`'s own `tsconfig.e2e.json` project doesn't include
 * `src/`, so the ambient `declare global` there isn't visible here -- this
 * is a debug/test-only contract, not application logic, so a second,
 * narrow copy of the shape is a reasonable place to stop rather than
 * wiring the two tsconfig projects together for it. */
type AudioDebugWindow = { __audioDebug__?: () => { fill: number; underrunCount: number } | null }

function readAudioDebug(page: Page) {
  return page.evaluate(() => (window as unknown as AudioDebugWindow).__audioDebug__?.() ?? null)
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
test('the audio test tone reaches a stable ring fill with no steady-state underruns', async ({ page }) => {
  const button = page.locator('.audio-test-tone button')
  await button.click() // a real Playwright click is a trusted gesture, satisfying the autoplay policy `AudioContext` needs
  await expect(button).toHaveText('Test tone playing')

  // The Worker only starts pushing stats once its wasm instance is up and
  // the handshake with the worklet has completed -- poll rather than a
  // fixed wait so this isn't racing that startup.
  await expect
    .poll(() => readAudioDebug(page), {
      message: 'no audio debug stats ever arrived from the Worker',
      timeout: 5000,
    })
    .not.toBeNull()

  // A handful of underruns before this point is expected and harmless: the
  // worklet only connects (see `AudioTestTone.tsx`'s `'ready'` handler)
  // once the Worker's wasm instance exists, but there's still one tick's
  // worth of gap before the very first samples land. What ENG-62's "no
  // underrun/desync glitches" actually means is a steady-state claim, so
  // this baseline is the number to hold *flat*, not zero from time zero.
  const baseline = await readAudioDebug(page)

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
  expect(settled!.underrunCount).toBe(baseline!.underrunCount)
})
