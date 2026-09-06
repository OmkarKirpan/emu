#!/usr/bin/env node
// Runs `check-headers.mjs` against `wrangler dev` -- Cloudflare's own local
// emulator, running this repo's actual `wrangler.jsonc`, `_headers`
// processing included -- instead of against a live deployment. That closes
// most of the gap between "`vite preview` applies the same header *config*"
// (which `e2e/isolation.spec.ts` already covers, cheaply, in every test
// run) and "the actual Cloudflare _headers file, parsed by Cloudflare's own
// logic, produces the right response headers for the real asset paths,
// including the content-hashed wasm one" -- without needing the account or
// secrets `deploy.yml` does.
//
// `wrangler dev`, not `wrangler pages dev`: this app deploys as a Worker
// serving static assets (see `wrangler.jsonc` for why), so this runs the
// same runtime path production does rather than the Pages one.
//
// This is why it can run in CI on every PR (`ci.yml`), unlike
// `deploy.yml`'s post-deploy check: that check verifies the one thing this
// script structurally can't -- that the real Cloudflare-side project is
// actually serving this repo's `dist/` -- and stays the final word on that.
// This script is the regression guard for everything else, running long
// before a deploy is even possible.
//
// Requires `dist/` already built (`npm run build`).

import { existsSync } from 'node:fs'
import { spawn, spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const WEB_ROOT = fileURLToPath(new URL('..', import.meta.url))
const PORT = 8788
const BASE_URL = `http://localhost:${PORT}`
const READY_TIMEOUT_MS = 30_000
const isWindows = process.platform === 'win32'

if (!existsSync(new URL('../dist', import.meta.url))) {
  console.error('dist/ not found -- run `npm run build` first')
  process.exit(2)
}

// `shell: true` so `npx` resolves on Windows (where it's `npx.cmd`) the same
// way it does on POSIX. That means `wrangler.pid` is the shell's pid, not
// wrangler's own -- which is exactly why killing the tree, not just that one
// pid, matters below.
const wrangler = spawn('npx', ['wrangler', 'dev', '--port', String(PORT)], {
  cwd: WEB_ROOT,
  shell: true,
  stdio: ['ignore', 'pipe', 'pipe'],
  // Its own process group on POSIX, so `killTree` can signal the whole
  // shell-npx-wrangler chain at once instead of just the shell.
  detached: !isWindows,
})

let wranglerOutput = ''
wrangler.stdout.on('data', (chunk) => { wranglerOutput += chunk })
wrangler.stderr.on('data', (chunk) => { wranglerOutput += chunk })

let killed = false
function killTree() {
  if (killed || wrangler.pid === undefined) return
  killed = true
  if (isWindows) {
    // `taskkill /T` walks the process tree Windows tracks by parent pid --
    // but `wrangler dev` runs the actual server as Cloudflare's
    // `workerd.exe`, which in testing here doesn't stay attached to that
    // tree (observed as a leaked `workerd.exe` still holding PORT after
    // `taskkill /T` returned). Free the port directly as the reliable path,
    // with `taskkill /T` first as a best-effort pass at everything else
    // (npx/node) it spawned.
    spawnSync('taskkill', ['/pid', String(wrangler.pid), '/t', '/f'])
    spawnSync('powershell', [
      '-NoProfile',
      '-Command',
      `Get-NetTCPConnection -LocalPort ${PORT} -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }`,
    ])
  } else {
    try {
      process.kill(-wrangler.pid, 'SIGTERM')
    } catch {
      // Already gone.
    }
  }
}
process.on('exit', killTree)
process.on('SIGINT', () => { killTree(); process.exit(130) })
process.on('SIGTERM', () => { killTree(); process.exit(143) })

async function waitUntilReady() {
  const deadline = Date.now() + READY_TIMEOUT_MS
  while (Date.now() < deadline) {
    if (wrangler.exitCode !== null) {
      throw new Error(`wrangler dev exited early (code ${wrangler.exitCode})\n${wranglerOutput}`)
    }
    try {
      // A per-attempt timeout, not just the overall deadline: a `fetch` to a
      // port that's open but not yet answering can hang well past 300ms,
      // and without this the outer `while` never gets to re-check the
      // deadline or `wrangler.exitCode` in the meantime.
      await fetch(BASE_URL, { signal: AbortSignal.timeout(2_000) })
      return
    } catch {
      // Not listening yet (or that one attempt timed out) -- keep polling.
    }
    await new Promise((resolve) => setTimeout(resolve, 300))
  }
  throw new Error(`wrangler dev did not become ready within ${READY_TIMEOUT_MS}ms\n${wranglerOutput}`)
}

try {
  await waitUntilReady()
} catch (err) {
  console.error(String(err instanceof Error ? err.message : err))
  process.exit(1)
}

const check = spawnSync(process.execPath, ['scripts/check-headers.mjs', BASE_URL], {
  cwd: WEB_ROOT,
  stdio: 'inherit',
})
process.exit(check.status ?? 1)
