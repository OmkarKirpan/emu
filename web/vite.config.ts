import react from '@vitejs/plugin-react'
// `vitest/config`'s `defineConfig` is a superset of Vite's own (adds the
// `test` field's types) and remains a valid `vite.config.ts` for `vite dev`/
// `vite build` -- one config file for both, per Vitest's own recommendation
// for projects that already use Vite.
import { defineConfig } from 'vitest/config'

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  test: {
    // Unit tests only -- anything needing the real wasm module or a real
    // browser (the ABI wrapper, the rAF loop, frame pacing) lives in
    // `e2e/` under Playwright instead, run against the actual compiled
    // module rather than a hand-maintained mock of its exports.
    include: ['src/**/*.test.ts'],
    environment: 'jsdom',
  },
})
