import react from '@vitejs/plugin-react'
// `vitest/config`'s `defineConfig` is a superset of Vite's own (adds the
// `test` field's types) and remains a valid `vite.config.ts` for `vite dev`/
// `vite build` -- one config file for both, per Vitest's own recommendation
// for projects that already use Vite.
import { defineConfig } from 'vitest/config'

// ENG-58 (M5): `SharedArrayBuffer` -- and the shared-memory wasm module the
// audio ring buffer (ENG-62) needs -- only exist in a cross-origin-isolated
// context, which requires both these headers together (COOP alone or COEP
// alone isn't enough; see MDN's `crossOriginIsolated` docs). `server.headers`
// and `preview.headers` are separate, non-inherited options (vite.dev/config/
// server-options#server-headers, vite.dev/config/preview-options#preview-headers)
// -- `vite preview` needs its own copy, not just `vite dev`'s. Production
// hosting is a separate, host-specific concern this doesn't cover (no static
// host has been chosen yet -- see ENG-70's own acceptance criteria).
const crossOriginIsolationHeaders = {
  'Cross-Origin-Opener-Policy': 'same-origin',
  'Cross-Origin-Embedder-Policy': 'require-corp',
}

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  server: { headers: crossOriginIsolationHeaders },
  preview: { headers: crossOriginIsolationHeaders },
  test: {
    // Unit tests only -- anything needing the real wasm module or a real
    // browser (the ABI wrapper, the rAF loop, frame pacing) lives in
    // `e2e/` under Playwright instead, run against the actual compiled
    // module rather than a hand-maintained mock of its exports.
    include: ['src/**/*.test.ts'],
    environment: 'jsdom',
  },
})
