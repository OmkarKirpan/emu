import { defineConfig, devices } from '@playwright/test'

const PORT = 4173

export default defineConfig({
  testDir: './e2e',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  reporter: 'list',
  use: {
    baseURL: `http://localhost:${PORT}`,
    trace: 'on-first-retry',
  },
  // Against the production build (`vite preview` serving `dist/`), not
  // `vite dev`: `predev`/`prebuild` both regenerate the wasm binary and demo
  // ROM from `core/` either way, so this is testing exactly what a real
  // deploy would ship, at no extra cost.
  webServer: {
    command: `npm run build && npm run preview -- --port ${PORT} --strictPort`,
    url: `http://localhost:${PORT}`,
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
  },
  projects: [
    {
      name: 'chromium',
      use: {
        ...devices['Desktop Chrome'],
        // Normally unset: Playwright resolves Chromium from its own managed
        // install (`npx playwright install chromium`, run once per machine/
        // CI image). Some sandboxed environments pre-install a Chromium
        // outside that cache and can't run the installer; PW_CHROMIUM_PATH
        // is an escape hatch for exactly that case, not the default path.
        launchOptions: process.env.PW_CHROMIUM_PATH
          ? { executablePath: process.env.PW_CHROMIUM_PATH }
          : {},
      },
    },
  ],
})
