import { defineConfig, devices } from '@playwright/test'

const PORT = 4173

/** Shared by both projects below -- they differ only in *which* specs they
 * run and how much of the machine those specs get to themselves, never in
 * what browser they run against. */
const chromium = {
  ...devices['Desktop Chrome'],
  // Normally unset: Playwright resolves Chromium from its own managed
  // install (`npx playwright install chromium`, run once per machine/
  // CI image). Some sandboxed environments pre-install a Chromium
  // outside that cache and can't run the installer; PW_CHROMIUM_PATH
  // is an escape hatch for exactly that case, not the default path.
  launchOptions: process.env.PW_CHROMIUM_PATH ? { executablePath: process.env.PW_CHROMIUM_PATH } : {},
}

/**
 * Specs whose assertions are measurements of the host machine as much as of
 * the emulator: `audio.spec.ts` asserts the AudioWorklet never starves in
 * steady state, `pacing.spec.ts` measures real frames-per-second off the
 * wall clock. Neither has a code-dependent failure mode under CPU pressure
 * -- they fail because several other Chromium instances, each running a
 * wasm emulator at 60Hz, were busy eating the CPU headroom the measurement
 * needs (ENG-85).
 *
 * The bounds themselves are deliberately *not* loosened to absorb that. A
 * steady-state underrun count that is exactly zero is a real property of
 * the ENG-62 ring design, guaranteed by `emulatorWorker.ts`'s priming
 * handshake (see `awaitAudioPrimed`), and these tests exist to protect it;
 * an "allow a couple" bound would quietly stop noticing the regression it
 * was written to catch. Giving the measurement a quiet machine is the fix,
 * so these run in their own project below instead.
 */
const TIMING_SENSITIVE = [/audio\.spec\.ts/, /pacing\.spec\.ts/]

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
      testIgnore: TIMING_SENSITIVE,
      use: chromium,
    },
    {
      // Runs alone, one test at a time, on an otherwise idle machine -- the
      // condition `TIMING_SENSITIVE` explains these measurements need.
      //
      // Both settings are load-bearing and neither substitutes for the
      // other. `workers: 1` bounds only *this* project's own concurrency,
      // so on its own it would still leave these specs racing the other
      // project's twenty for the same four cores; `dependencies` is what
      // holds the rest of the suite off the CPU, by not starting this
      // project until every `chromium` test has finished.
      //
      // The cost of `dependencies` is worth naming: Playwright skips a
      // project whose dependency had any failure, so a broken spec anywhere
      // in `chromium` leaves these reported as skipped rather than run.
      // `npx playwright test --project=timing --no-deps` runs them anyway
      // (and is what you want locally while iterating on the audio path).
      name: 'timing',
      testMatch: TIMING_SENSITIVE,
      dependencies: ['chromium'],
      workers: 1,
      use: chromium,
    },
  ],
})
