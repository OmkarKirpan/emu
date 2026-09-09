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
// Checks the document itself plus subresources *discovered from that
// deployment* -- the wasm module above all -- because COEP applies
// per-response, so an isolated document that pulls a non-isolated
// subresource is still broken. Discovery reads the deployment rather than
// the local `dist/` so this is correct against a URL this machine didn't
// build; see `discoverAssetPaths` for why that distinction bites.
//
// Two failure modes, deliberately kept apart -- see `checkResponse`. A
// missing header means the host isn't applying `dist/_headers` and the app
// will not start. A 404 means the asset isn't being served, which says
// nothing about headers at all. Reporting the second as the first is how
// this check twice told us cross-origin isolation was broken when it was
// perfectly fine (see `PROPAGATION_RETRIES`).

import { readdirSync } from 'node:fs'
import { join } from 'node:path'

const REQUIRED = {
  'cross-origin-opener-policy': 'same-origin',
  'cross-origin-embedder-policy': 'require-corp',
}

/**
 * `wrangler deploy` returns once the Worker *version* exists, but
 * Cloudflare's static-asset store is eventually consistent: for a few
 * seconds afterwards an edge PoP can serve the new document while still
 * 404ing an asset that document references. The deploy workflow runs this
 * check immediately, so it kept losing that race -- twice in one day, on a
 * different asset each time (the JS on one deploy, the CSS on the next),
 * with the very same build passing minutes later.
 *
 * Retried, not slept-on unconditionally: a healthy deployment never enters
 * this path, so `ci.yml`'s run against `wrangler dev` -- where there is no
 * propagation delay -- pays nothing for it.
 */
const PROPAGATION_RETRIES = 5
const PROPAGATION_BACKOFF_MS = 1500

/** Exit codes. `2` is a usage error (see the argv check below). `1` stays
 * reserved for the thing this script is named for -- headers -- so that a
 * red deploy always means what its failure message says it means, and a
 * missing asset gets a code of its own rather than borrowing that one. */
const EXIT_HEADERS_WRONG = 1
const EXIT_ASSET_MISSING = 3

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

const baseUrl = process.argv[2]
if (!baseUrl) {
  console.error('usage: node scripts/check-headers.mjs <base-url>')
  process.exit(2)
}

/** Response header names are case-insensitive; `Headers.get` already
 * normalizes, so this only has to normalize the expectation side. */
function checkResponse(url, response) {
  // Checked first and returned on, rather than folded in with the header
  // failures below: a response that isn't there has no headers to be wrong
  // about, and calling that a cross-origin-isolation failure is a
  // confidently incorrect diagnosis of a completely different problem.
  if (!response.ok) {
    console.error(`FAIL ${url}`)
    console.error(`  - HTTP ${response.status} -- not served`)
    return 'missing'
  }
  const failures = []
  for (const [name, expected] of Object.entries(REQUIRED)) {
    const actual = response.headers.get(name)
    if (actual !== expected) {
      failures.push(`${name}: expected "${expected}", got ${actual === null ? '(absent)' : `"${actual}"`}`)
    }
  }
  if (failures.length > 0) {
    console.error(`FAIL ${url}`)
    for (const failure of failures) console.error(`  - ${failure}`)
    return 'headers'
  }
  console.log(`ok   ${url}`)
  return 'ok'
}

/** Same-origin build assets referenced by a document or script body. Assets
 * are content-hashed, so their names can only be discovered, never
 * predicted. */
function extractAssetPaths(body) {
  return new Set([...body.matchAll(/assets\/[A-Za-z0-9_.-]+\.[A-Za-z0-9]+/g)].map((match) => `/${match[0]}`))
}

/** Last resort only -- see `discoverAssetPaths`. Reading the *local* build to
 * decide which *remote* URL to request is only sound when the two are the
 * same build, which is true in CI and routinely false by hand. */
function findLocalWasmPath() {
  try {
    const assets = readdirSync(join(import.meta.dirname, '..', 'dist', 'assets'))
    const wasm = assets.find((name) => name.endsWith('.wasm'))
    return wasm ? `/assets/${wasm}` : null
  } catch {
    return null // no local dist/ -- fine, the document check still stands
  }
}

/**
 * Finds subresources to check by reading the *deployment itself* rather than
 * the local `dist/`: fetch the document, take the assets it references, then
 * follow its scripts one level down, which is where the wasm module is named
 * (nothing in the HTML mentions it -- the Worker chunk imports it).
 *
 * This exists because deriving remote URLs from a local build is a trap. Run
 * by hand against a deployment this machine didn't build -- the exact usage
 * README documents -- a stale `dist/` makes the check request an asset that
 * was never deployed, and a 404 then gets reported as "cross-origin
 * isolation is NOT correctly configured". That message is confidently wrong:
 * nothing was learned about headers at all. Discovering from the deployment
 * makes the check mean what it says, and work against any URL.
 */
async function discoverAssetPaths(documentBody) {
  const discovered = new Set(extractAssetPaths(documentBody))
  const crawled = new Set()

  // Iterative, not one pass over the document's own scripts: the wasm is two
  // hops out (document -> entry chunk -> emulator Worker chunk -> `.wasm`),
  // so a single level finds the entry chunk and stops one short of the file
  // this check most wants to see.
  for (let depth = 0; depth < MAX_CRAWL_DEPTH; depth++) {
    const pending = [...discovered].filter((path) => path.endsWith('.js') && !crawled.has(path))
    if (pending.length === 0) break

    for (const path of pending.slice(0, MAX_SCRIPTS_CRAWLED)) {
      crawled.add(path)
      try {
        const response = await fetch(new URL(path, baseUrl))
        if (!response.ok) continue
        for (const nested of extractAssetPaths(await response.text())) discovered.add(nested)
      } catch {
        // A script that won't fetch is the document check's problem, not
        // this function's -- it only gathers candidates.
      }
    }
  }
  return discovered
}

/** Enough to reach the wasm without turning a header check into a crawler. */
const MAX_SCRIPTS_CRAWLED = 4
const MAX_CRAWL_DEPTH = 3
/** Checking every hashed chunk would add noise, not confidence: COEP applies
 * per response, so a couple of subresources demonstrate it as well as ten. */
const MAX_OTHER_ASSETS_CHECKED = 2

let headersWrong = false
let assetMissing = false

/**
 * @param allowMissing  A 404 is reported and tolerated rather than failing
 *   the run. For locally-derived paths only, where a miss means this
 *   machine's `dist/` is stale -- see `findLocalWasmPath`.
 * @param retryMissing  A 404 is retried before being believed. For paths
 *   discovered from the deployment itself, where a miss is far more likely
 *   to be the propagation race than a genuinely absent file.
 */
async function check(url, { allowMissing = false, retryMissing = false } = {}) {
  let response = null

  for (let attempt = 0; ; attempt++) {
    try {
      // `redirect: 'manual'`: a host that redirects (e.g. to a canonical
      // domain) would otherwise have its *final* response checked while the
      // browser-visible one goes unchecked.
      response = await fetch(url, { redirect: 'manual' })
    } catch (err) {
      console.error(`FAIL ${url}`)
      console.error(`  - request failed: ${err instanceof Error ? err.message : String(err)}`)
      headersWrong = true
      return null
    }

    const isLastAttempt = attempt >= PROPAGATION_RETRIES
    if (response.status !== 404 || !retryMissing || isLastAttempt) break

    // Only a 404 waits, and only on a discovered path. A wrong header is
    // wrong immediately and for good -- retrying it would just make a real
    // failure take longer to report.
    console.log(`...  ${url}`)
    console.log(`  - HTTP 404; retrying in ${PROPAGATION_BACKOFF_MS}ms (${attempt + 1}/${PROPAGATION_RETRIES})`)
    await sleep(PROPAGATION_BACKOFF_MS)
  }

  // A locally-derived path that isn't on the deployment says nothing about
  // headers -- it says this machine's `dist/` is stale. Report that as
  // itself rather than as an isolation failure.
  if (allowMissing && response.status === 404) {
    console.log(`skip ${url}`)
    console.log('  - not on this deployment (stale local build?) -- not a header problem')
    return response
  }

  const verdict = checkResponse(url, response)
  if (verdict === 'headers') headersWrong = true
  if (verdict === 'missing') assetMissing = true
  return response
}

const documentUrl = new URL('/', baseUrl).toString()
const documentResponse = await check(documentUrl)

const discovered = documentResponse ? await discoverAssetPaths(await documentResponse.text().catch(() => '')) : new Set()

// The wasm module first: it's the asset whose failure this whole check
// exists to prevent, since a non-isolated response makes it un-instantiable.
const wasmPaths = [...discovered].filter((path) => path.endsWith('.wasm'))
const otherPaths = [...discovered].filter((path) => !path.endsWith('.wasm')).slice(0, MAX_OTHER_ASSETS_CHECKED)

for (const path of [...wasmPaths, ...otherPaths]) {
  // Discovered from the live deployment moments ago, so a 404 here means the
  // asset went missing between the document naming it and this request --
  // which is the propagation race, not a broken build.
  await check(new URL(path, baseUrl).toString(), { retryMissing: true })
}

if (discovered.size === 0) {
  // Nothing discoverable (an empty/redirecting document, or a build whose
  // asset naming this doesn't recognise). Fall back to the local build, and
  // tolerate a miss -- see `findLocalWasmPath`.
  const localWasm = findLocalWasmPath()
  if (localWasm) await check(new URL(localWasm, baseUrl).toString(), { allowMissing: true })
  else console.log('note: no subresources discovered and no local dist/ -- checked the document only')
}

// Order matters: a wrong header is the more serious diagnosis and the one
// this script is named for, so it wins the exit code when both are true.
if (headersWrong) {
  console.error('\ncross-origin isolation is NOT correctly configured -- SharedArrayBuffer will be unavailable')
  console.error('and the shared-memory wasm module will fail to instantiate. See web/vite.config.ts.')
  process.exit(EXIT_HEADERS_WRONG)
}

if (assetMissing) {
  console.error(`\nan asset this deployment references is not being served, after ${PROPAGATION_RETRIES} retries.`)
  console.error('cross-origin isolation itself checked out on everything that DID respond -- this is not a')
  console.error('header problem, and re-running the deploy is likelier to help than editing vite.config.ts.')
  process.exit(EXIT_ASSET_MISSING)
}

console.log('\ncross-origin isolation headers verified')
