import { expect, test as base } from '@playwright/test'
import { waitUntilRunning } from './helpers'

/**
 * Every spec in this suite navigates to the running app and wants console/
 * page errors asserted against -- a `?init`/COOP-COEP regression (the M4
 * acceptance criterion this whole suite exists to guard) surfaces as exactly
 * that kind of error, not as an assertion failure in the test body. This
 * fixture does the navigation and the wait before the test body runs, then
 * asserts the collected errors after it -- Playwright's fixture teardown
 * (the code after `await use(...)`) runs once the test finishes regardless
 * of outcome, so every spec gets this check for free without a matching
 * `test.afterEach` of its own.
 */
export const test = base.extend<{ bootedApp: void }>({
  // `{ auto: true }`: applies to every test in files that import `test` from
  // here without needing to be named in each test's parameter list, which
  // is what lets every spec below just start from "the demo is already
  // running, and will fail if it logged anything".
  bootedApp: [
    async ({ page }, use) => {
      const errors: string[] = []
      page.on('pageerror', (err) => errors.push(err.message))
      page.on('console', (msg) => {
        if (msg.type() === 'error') errors.push(msg.text())
      })

      await page.goto('/')
      await waitUntilRunning(page)

      await use()

      expect(errors, `unexpected console/page errors: ${errors.join('; ')}`).toEqual([])
    },
    { auto: true },
  ],
})

export { expect } from '@playwright/test'
