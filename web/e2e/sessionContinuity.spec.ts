import { resolve } from 'node:path'
import type { Page } from '@playwright/test'
import { expect, test } from './fixtures'
import { BACKDROP_RGBA, readSpriteCol, SPRITE_INITIAL_COL, SPRITE_ROW } from './helpers'

/**
 * ENG-89's session continuity, end to end: the ROM library, the Worker's
 * `RESUME_SLOT` autosave/auto-load, and IndexedDB, against the real
 * compiled core.
 *
 * The observable is the same one `savestates.spec.ts` uses -- the demo
 * ROM's sprite column -- for the same reason: it is a genuine read of
 * emulated machine state (WRAM/OAM), not a debug hook standing in for one.
 * Note that this is deliberately *not* a duplicate of `savestates.spec.ts`'s
 * own "a saved slot survives a reload" case: that one drives a numbered
 * slot's explicit Save/Load buttons, while every test here drives no
 * Save/Load control at all -- the whole point of ENG-89 is that reopening
 * the tab alone is what restores the session.
 */

/** Holds `key` for ~400ms, several NES frames' worth of movement -- the same
 * budget `savestates.spec.ts` and `emulator.spec.ts` use for the same ROM. */
async function nudge(page: Page, key: string): Promise<void> {
  await page.keyboard.down(key)
  await page.waitForTimeout(400)
  await page.keyboard.up(key)
}

function spriteCol(page: Page): Promise<number> {
  return readSpriteCol(page, SPRITE_ROW, BACKDROP_RGBA)
}

/** Mirrors `savestates.spec.ts`'s `settledCol`: waits for `InputBridge`'s
 * `requestAnimationFrame`-delayed keyup to actually reach the sprite before
 * reading its position, so a save captures a stable column rather than one
 * still mid-drift. */
async function settledCol(page: Page): Promise<number> {
  let previous = -1
  await expect
    .poll(
      async () => {
        const current = await spriteCol(page)
        const stable = current === previous && current >= 0
        previous = current
        return stable
      },
      { message: 'the sprite never stopped moving' },
    )
    .toBe(true)
  return previous
}

/** Fires the same `visibilitychange` -> `hidden` transition
 * `useResumeAutosave.ts` listens for, without actually backgrounding the
 * Playwright-driven tab (which stays the foreground window throughout the
 * run). `document.visibilityState` has no public setter, so the getter is
 * overridden the same way `RomLibrary.test.tsx`'s unit tests do it. */
async function hideTab(page: Page): Promise<void> {
  await page.evaluate(() => {
    Object.defineProperty(document, 'visibilityState', { value: 'hidden', configurable: true })
    document.dispatchEvent(new Event('visibilitychange'))
  })
}

/** A round trip through IndexedDB and back over `postMessage`, same
 * generous budget `savestates.spec.ts` gives the numbered slots and for the
 * same reason (this suite runs several emulators in parallel). */
const RESUME_UPDATE_TIMEOUT = { timeout: 15_000 }

test('hiding the tab autosaves the resume point, and a reload restores position with zero clicks', async ({
  page,
}) => {
  await nudge(page, 'ArrowRight')
  const saved = await settledCol(page)
  expect(saved).not.toBe(SPRITE_INITIAL_COL)

  await hideTab(page)
  // The resume row is read-only (no Load button to poll via) -- its
  // `data-saved` flip is the write actually landing in IndexedDB, same
  // proof-of-commit role `data-occupied` plays for a numbered slot.
  await expect(page.locator('.resume-point')).toHaveAttribute('data-saved', 'yes', RESUME_UPDATE_TIMEOUT)

  await page.reload()

  // No `waitUntilRunning` here on purpose: that helper only asserts the
  // sprite appears *somewhere*, which the power-on column would also
  // satisfy. Polling straight for the saved column is what proves the
  // resume state -- not just the cartridge -- came back with no click at
  // all, numbered Load button included.
  await expect
    .poll(() => spriteCol(page), { ...RESUME_UPDATE_TIMEOUT, message: 'the session did not resume its saved position' })
    .toBe(saved)
})

/** Same second-cartridge trick `savestates.spec.ts` uses for its ROM-swap
 * case: a structurally valid NROM ROM whose bytes (and therefore whose
 * `rom_hash`) differ from the demo's, built rather than vendored because the
 * point is the identity, not 24KB of near-zero PRG. */
function otherNromRom(): Buffer {
  const header = Buffer.alloc(16)
  header.write('NES', 0, 'latin1')
  header[4] = 1 // 16KB PRG
  header[5] = 1 // 8KB CHR-ROM
  const prg = Buffer.alloc(0x4000)
  prg[0] = 0x4c // JMP $8000 -- an infinite self-loop, enough to load and idle
  prg[1] = 0x00
  prg[2] = 0x80
  prg[0x3ffc] = 0x00 // reset vector -> $8000
  prg[0x3ffd] = 0x80
  return Buffer.concat([header, prg, Buffer.alloc(0x2000)])
}

const DEMO_ROM_PATH = resolve(import.meta.dirname, '../../core/tests/roms/nrom_demo/sprite_input_demo.nes')

function pickRom(page: Page, file: string | { name: string; mimeType: string; buffer: Buffer }): Promise<void> {
  return page.locator('.rom-picker input[type=file]').setInputFiles(file)
}

test('the library survives a hard reload and lists more than one ROM', async ({ page }) => {
  await expect(page.locator('.rom-library-item')).toHaveCount(0) // nothing picked yet this test

  await pickRom(page, DEMO_ROM_PATH)
  await expect(page.locator('.rom-library-item')).toHaveCount(1, RESUME_UPDATE_TIMEOUT)

  await pickRom(page, { name: 'other.nes', mimeType: 'application/octet-stream', buffer: otherNromRom() })
  await expect(page.locator('.rom-library-item')).toHaveCount(2, RESUME_UPDATE_TIMEOUT)
  await expect(page.locator('.rom-library-name')).toContainText(['other.nes', 'sprite_input_demo.nes'])

  await page.reload()

  // A fresh wasm instance, a fresh Worker, a fresh React tree -- and the
  // library listing is still there, the same proof `savestates.spec.ts`
  // already relies on for numbered slots.
  await expect(page.locator('.rom-library-item')).toHaveCount(2, RESUME_UPDATE_TIMEOUT)
})

test('resuming a library entry switches the running cartridge and names it', async ({ page }) => {
  await pickRom(page, { name: 'other.nes', mimeType: 'application/octet-stream', buffer: otherNromRom() })
  await expect(page.locator('.rom-readout')).toContainText('other.nes')

  await pickRom(page, DEMO_ROM_PATH)
  await expect(page.locator('.rom-readout')).toContainText('sprite_input_demo.nes')
  await expect(page.locator('.rom-library-item')).toHaveCount(2, RESUME_UPDATE_TIMEOUT)

  await page
    .locator('.rom-library-item', { hasText: 'other.nes' })
    .getByRole('button', { name: 'Resume' })
    .click()

  // `resumeRom` posts the same `'rom-loaded'` a picker swap does, plus a
  // `'boot-rom'` naming the cartridge -- proving the readout updates even
  // though nothing here went through the file picker for this swap.
  await expect(page.locator('.rom-readout')).toContainText('other.nes', RESUME_UPDATE_TIMEOUT)
})

test('removing a library entry drops it from the list without touching the running game', async ({ page }) => {
  await pickRom(page, { name: 'other.nes', mimeType: 'application/octet-stream', buffer: otherNromRom() })
  await pickRom(page, DEMO_ROM_PATH)
  await expect(page.locator('.rom-library-item')).toHaveCount(2, RESUME_UPDATE_TIMEOUT)

  await page.locator('.rom-library-item', { hasText: 'other.nes' }).getByRole('button', { name: /remove/i }).click()

  await expect(page.locator('.rom-library-item')).toHaveCount(1, RESUME_UPDATE_TIMEOUT)
  await expect(page.locator('.rom-library-name')).toHaveText('sprite_input_demo.nes')
  // The demo is still the running, responsive cartridge underneath the
  // library panel -- removing an entry is scoped to the library, never the
  // live session (see `deleteRom`'s own comment in `saveStore.ts`).
  await expect(page.locator('.screen-overlay')).toHaveCount(0)
})
