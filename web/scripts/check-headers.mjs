#!/usr/bin/env node
// Asserts that a deployed (or locally previewed) build actually serves the
// two headers cross-origin isolation requires. This is the automatable half
// of ENG-70's "COOP/COEP verified against the real production build (not
// just `vite preview`)" acceptance criterion: point it at the real
// deployment URL and it fails loudly if the host isn't applying
// `dist/_headers`.
//
// Why this exists as a check at all: ENG-58 established that Vite's build
// emits static files with no header pipeline, so production headers are
// entirely the host's concern. A misconfigured host doesn't fail the build,
// doesn't fail any test, and doesn't even look broken on the surface -- it
// just quietly makes `crossOriginIsolated` false, at which point
// `SharedArrayBuffer` is gone and the shared-memory wasm module refuses to
// instantiate. That is a deploy-only failure mode, so it needs a deploy-time
// check.
//
// Usage:
//   node scripts/check-headers.mjs https://emu.pages.dev
//   node scripts/check-headers.mjs http://localhost:4173
//
// Checks the document itself and, if the build manifest points at one, the
// `.wasm` asset -- COEP applies per-response, so an isolated document that
// pulls a non-isolated subresource is still broken.

import { readdirSync } from 'node:fs'
import { join } from 'node:path'

const REQUIRED = {
  'cross-origin-opener-policy': 'same-origin',
  'cross-origin-embedder-policy': 'require-corp',
}

const baseUrl = process.argv[2]
if (!baseUrl) {
  console.error('usage: node scripts/check-headers.mjs <base-url>')
  process.exit(2)
}

/** Response header names are case-insensitive; `Headers.get` already
 * normalizes, so this only has to normalize the expectation side. */
function checkResponse(url, response) {
  const failures = []
  if (!response.ok) failures.push(`HTTP ${response.status}`)
  for (const [name, expected] of Object.entries(REQUIRED)) {
    const actual = response.headers.get(name)
    if (actual !== expected) {
      failures.push(`${name}: expected "${expected}", got ${actual === null ? '(absent)' : `"${actual}"`}`)
    }
  }
  if (failures.length > 0) {
    console.error(`FAIL ${url}`)
    for (const failure of failures) console.error(`  - ${failure}`)
    return false
  }
  console.log(`ok   ${url}`)
  return true
}

/** The wasm asset is content-hashed, so its name isn't knowable up front --
 * read it off the local build output when one is present. Absent (checking
 * a deployment from a machine that didn't build it), the document check
 * alone still catches a host that's ignoring `_headers` entirely. */
function findWasmAssetPath() {
  try {
    const assets = readdirSync(join(import.meta.dirname, '..', 'dist', 'assets'))
    const wasm = assets.find((name) => name.endsWith('.wasm'))
    return wasm ? `/assets/${wasm}` : null
  } catch {
    return null // no local dist/ -- fine, see this function's doc comment
  }
}

const paths = ['/']
const wasmPath = findWasmAssetPath()
if (wasmPath) paths.push(wasmPath)

let allPassed = true
for (const path of paths) {
  const url = new URL(path, baseUrl).toString()
  try {
    // `redirect: 'manual'`: a host that redirects (e.g. to a canonical
    // domain) would otherwise have its *final* response checked while the
    // browser-visible one goes unchecked.
    const response = await fetch(url, { redirect: 'manual' })
    allPassed = checkResponse(url, response) && allPassed
  } catch (err) {
    console.error(`FAIL ${url}`)
    console.error(`  - request failed: ${err instanceof Error ? err.message : String(err)}`)
    allPassed = false
  }
}

if (!allPassed) {
  console.error('\ncross-origin isolation is NOT correctly configured -- SharedArrayBuffer will be unavailable')
  console.error('and the shared-memory wasm module will fail to instantiate. See web/vite.config.ts.')
  process.exit(1)
}
console.log('\ncross-origin isolation headers verified')
