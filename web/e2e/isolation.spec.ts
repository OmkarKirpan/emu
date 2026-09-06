import { expect, test } from '@playwright/test'

/**
 * Guards cross-origin isolation itself, separately from anything that
 * depends on it.
 *
 * Deliberately not using `./fixtures` (which boots the whole emulator and
 * waits for a sprite): if isolation regresses, *every* other spec in this
 * suite fails at once with some downstream symptom -- a wasm module that
 * won't instantiate, a blank canvas -- and none of them say why. This one
 * says why, in one assertion, without booting anything.
 *
 * The production counterpart is `scripts/check-headers.mjs`, run against
 * the real deployment URL by `.github/workflows/deploy.yml`: this spec
 * covers `vite preview`, that covers the host, and ENG-58's answer is
 * explicit that those are two genuinely separate configurations rather than
 * one checked twice.
 */
test('the app is served cross-origin isolated', async ({ page, baseURL }) => {
  const response = await page.goto(baseURL ?? '/')
  const headers = response?.headers() ?? {}

  expect(headers['cross-origin-opener-policy']).toBe('same-origin')
  expect(headers['cross-origin-embedder-policy']).toBe('require-corp')

  // The headers are the mechanism; these two are what the app actually
  // needs out of them (ENG-56/ENG-62 -- the wasm module is built with
  // `shared_memory = true` and simply won't instantiate without them).
  expect(await page.evaluate(() => window.crossOriginIsolated)).toBe(true)
  expect(await page.evaluate(() => typeof SharedArrayBuffer)).toBe('function')
})
