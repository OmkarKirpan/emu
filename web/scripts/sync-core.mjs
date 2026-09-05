#!/usr/bin/env node
// Builds the Zig core for wasm32 and copies its output — plus the one
// original, license-clean demo ROM the app boots (see
// `core/tests/roms/nrom_demo/README.md` for why it, and not a real
// commercial game, is what's vendored here) — into `web/`. Runs
// automatically before `dev`/`build` (see package.json's `predev`/
// `prebuild`) so `core/` stays the single source of truth: nothing under
// `web/src/wasm/nes_core.wasm` or `web/public/roms/` is committed, both are
// generated here and gitignored.

import { execFileSync } from 'node:child_process'
import { copyFileSync, mkdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const webRoot = dirname(dirname(fileURLToPath(import.meta.url)))
const coreRoot = join(webRoot, '..', 'core')

console.log('[sync-core] zig build wasm (core/)...')
try {
  execFileSync('zig', ['build', 'wasm'], { cwd: coreRoot, stdio: 'inherit' })
} catch (err) {
  console.error(
    '[sync-core] `zig build wasm` failed -- is Zig 0.16.0 installed and on PATH? ' +
      '(see .github/workflows/ci.yml for the version this repo builds against)',
  )
  throw err
}

const wasmDestDir = join(webRoot, 'src', 'wasm')
mkdirSync(wasmDestDir, { recursive: true })
copyFileSync(join(coreRoot, 'zig-out', 'bin', 'nes_core.wasm'), join(wasmDestDir, 'nes_core.wasm'))
console.log('[sync-core] copied nes_core.wasm -> web/src/wasm/')

// Into `src/`, not `public/`: the app imports this through Vite's asset
// graph (`?url`), so a missing ROM is a build error rather than a runtime
// 404, and the served file is content-hashed like any other asset.
const romsDestDir = join(webRoot, 'src', 'roms')
mkdirSync(romsDestDir, { recursive: true })
copyFileSync(
  join(coreRoot, 'tests', 'roms', 'nrom_demo', 'sprite_input_demo.nes'),
  join(romsDestDir, 'sprite_input_demo.nes'),
)
console.log('[sync-core] copied sprite_input_demo.nes -> web/src/roms/')
