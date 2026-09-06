import react from '@vitejs/plugin-react'
import type { Plugin } from 'vite'
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
// -- `vite preview` needs its own copy, not just `vite dev`'s -- and
// production needs a third, host-specific copy, which is what the plugin
// below generates rather than leaving to be hand-maintained.
const crossOriginIsolationHeaders = {
  'Cross-Origin-Opener-Policy': 'same-origin',
  'Cross-Origin-Embedder-Policy': 'require-corp',
}

/**
 * Emits Cloudflare Pages' `_headers` file into the build output, generated
 * from the exact same object the dev and preview servers use.
 *
 * Generated rather than checked in as `public/_headers` specifically so the
 * three copies can't drift: ENG-58 established that Vite's build has no
 * header pipeline at all and production headers are entirely the host's
 * concern, which makes "someone edits `preview.headers` and forgets the
 * production file" a live failure mode -- and one whose symptom only shows
 * up *after* a deploy, as a wasm module that refuses to instantiate because
 * `crossOriginIsolated` came back false. `scripts/check-headers.mjs` is the
 * other half of that guard, asserting the headers are actually on the wire.
 *
 * Format and placement per Cloudflare's own docs
 * (developers.cloudflare.com/pages/configuration/headers/): a `_headers`
 * file at the root of the deployed output, rules indented under a path
 * pattern.
 */
function cloudflarePagesHeaders(): Plugin {
  return {
    name: 'emu:cloudflare-pages-headers',
    apply: 'build',
    generateBundle() {
      const rules = Object.entries(crossOriginIsolationHeaders)
        .map(([name, value]) => `  ${name}: ${value}`)
        .join('\n')
      this.emitFile({ type: 'asset', fileName: '_headers', source: `/*\n${rules}\n` })
    },
  }
}

// https://vite.dev/config/
export default defineConfig({
  plugins: [react(), cloudflarePagesHeaders()],
  server: { headers: crossOriginIsolationHeaders },
  preview: { headers: crossOriginIsolationHeaders },
  test: {
    // Unit tests only -- anything needing the real wasm module or a real
    // browser (the ABI wrapper, the rAF loop, frame pacing) lives in
    // `e2e/` under Playwright instead, run against the actual compiled
    // module rather than a hand-maintained mock of its exports.
    include: ['src/**/*.test.ts'],
    environment: 'jsdom',
    alias: {
      // `wgsl_reflect` (used by `shader.test.ts`) is mis-packaged: its
      // package.json declares `"type": "module"` but points `main` at a
      // CommonJS build with a `.js` extension, so resolving it the normal
      // way loads CJS source as ESM and dies on `exports is not defined`.
      // Point straight at the ESM build instead. Aliased only for tests --
      // nothing in the shipped app imports it -- and only at runtime, so
      // `tsc` still resolves the package's own types off the bare specifier.
      wgsl_reflect: 'wgsl_reflect/wgsl_reflect.module.js',
    },
  },
})
