import { resolve } from 'node:path'
import type { Page } from '@playwright/test'
import { expect, test } from './fixtures'
import { BACKDROP_RGBA, readSpriteCol, SPRITE_ROW, waitUntilRunning } from './helpers'

/**
 * ENG-76 (M8)'s host half, end to end: the slot browser, the emulator
 * Worker's save/load handlers, and IndexedDB, against the real compiled
 * core.
 *
 * The observable used throughout is the demo ROM's sprite column, exactly
 * as in `emulator.spec.ts`. It is a genuine read of emulated machine state
 * -- the sprite's position lives in WRAM and OAM, both of which the
 * save-state carries -- so "load restored the machine" and "the picture
 * went back" are the same assertion here, with no debug hook in between.
 *
 * `core/src/savestate_mapper_test.zig` is what proves the *format* is
 * complete (across every mapper, digest-exact). These specs deliberately
 * do not re-prove that through a browser; they prove the plumbing around
 * it, which is the only part a native test cannot reach.
 */

/** Holds `key` for ~400ms, several NES frames' worth of movement -- the
 * same budget `emulator.spec.ts` uses for the same ROM. */
async function nudge(page: Page, key: string): Promise<void> {
  await page.keyboard.down(key)
  await page.waitForTimeout(400)
  await page.keyboard.up(key)
}

function spriteCol(page: Page): Promise<number> {
  return readSpriteCol(page, SPRITE_ROW, BACKDROP_RGBA)
}

/**
 * Reads the sprite's column once it has stopped moving.
 *
 * The sprite is not immediately still after a keyup, and the reason is the
 * harness rather than the emulator: `InputBridge` republishes the merged
 * button byte on `requestAnimationFrame`, on the main thread, so a keyup
 * only reaches shared memory on the page's next animation frame -- while
 * the Worker has been advancing emulated frames the whole time. The sprite
 * therefore drifts a few pixels past wherever it was when the key came up.
 *
 * `emulator.spec.ts` never noticed because it only asserts the sign of the
 * movement. A save-state test asserts an exact position on both sides of a
 * round trip, so it has to wait for the machine to actually be still.
 */
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

const slot1 = '.slot[data-slot="1"]'

/** A save round-trips through IndexedDB and back over `postMessage` before
 * the row updates. Given more headroom than the 5s default because this
 * suite runs four emulators in parallel and the machine it runs on may not
 * have four cores to spare -- a slow save is not a failed one. */
const SLOT_UPDATE_TIMEOUT = { timeout: 15_000 }

test('the slot browser starts empty, with save offered and load withheld', async ({ page }) => {
  await expect(page.locator('.slot')).toHaveCount(4)
  await expect(page.locator(`${slot1} .slot-when`)).toHaveText('empty')
  await expect(page.locator(`${slot1} button`, { hasText: 'Save' })).toBeEnabled()
  // Nothing stored: loading an empty slot is not an error the user should
  // have to discover by clicking.
  await expect(page.locator(`${slot1} button`, { hasText: 'Load' })).toBeDisabled()
})

test('saving then loading a slot restores the machine to where it was saved', async ({ page }) => {
  await nudge(page, 'ArrowRight')
  const saved = await settledCol(page)

  await page.locator(`${slot1} button`, { hasText: 'Save' }).click()
  // The listing round-trips through IndexedDB and back over postMessage, so
  // the row filling in is also the proof the write committed.
  await expect(page.locator(`${slot1}`)).toHaveAttribute('data-occupied', 'yes', SLOT_UPDATE_TIMEOUT)

  await nudge(page, 'ArrowRight')
  const moved = await settledCol(page)
  expect(moved).toBeGreaterThan(saved)

  await page.locator(`${slot1} button`, { hasText: 'Load' }).click()
  // Polled rather than read once: the load lands on the Worker's own tick
  // boundary, and the next painted frame is what the framebuffer shows.
  await expect.poll(() => spriteCol(page), SLOT_UPDATE_TIMEOUT).toBe(saved)
})

test('a saved slot survives a page reload, and still restores', async ({ page }) => {
  await nudge(page, 'ArrowRight')
  const saved = await settledCol(page)
  await page.locator(`${slot1} button`, { hasText: 'Save' }).click()
  await expect(page.locator(slot1)).toHaveAttribute('data-occupied', 'yes', SLOT_UPDATE_TIMEOUT)

  await page.reload()
  await waitUntilRunning(page)

  // A fresh wasm instance, a fresh Worker, a fresh React tree -- and the
  // slot is still there, which is the whole point of IndexedDB over
  // in-memory state.
  await expect(page.locator(slot1)).toHaveAttribute('data-occupied', 'yes', SLOT_UPDATE_TIMEOUT)
  await expect(page.locator(`${slot1} .slot-when`)).not.toHaveText('empty')

  await page.locator(`${slot1} button`, { hasText: 'Load' }).click()
  await expect.poll(() => spriteCol(page), SLOT_UPDATE_TIMEOUT).toBe(saved)
})

test('deleting a slot empties it and withdraws the load button', async ({ page }) => {
  await page.locator(`${slot1} button`, { hasText: 'Save' }).click()
  await expect(page.locator(slot1)).toHaveAttribute('data-occupied', 'yes', SLOT_UPDATE_TIMEOUT)

  await page.locator(`${slot1} .slot-delete`).click()
  await expect(page.locator(slot1)).toHaveAttribute('data-occupied', 'no', SLOT_UPDATE_TIMEOUT)
  await expect(page.locator(`${slot1} .slot-when`)).toHaveText('empty')
  await expect(page.locator(`${slot1} button`, { hasText: 'Load' })).toBeDisabled()
})

test('slots are independent of one another', async ({ page }) => {
  const first = await settledCol(page)
  await page.locator(`${slot1} button`, { hasText: 'Save' }).click()
  await expect(page.locator(slot1)).toHaveAttribute('data-occupied', 'yes', SLOT_UPDATE_TIMEOUT)

  await nudge(page, 'ArrowRight')
  await page.locator('.slot[data-slot="2"] button', { hasText: 'Save' }).click()
  await expect(page.locator('.slot[data-slot="2"]')).toHaveAttribute('data-occupied', 'yes', SLOT_UPDATE_TIMEOUT)

  await nudge(page, 'ArrowRight')
  await page.locator(`${slot1} button`, { hasText: 'Load' }).click()
  await expect.poll(() => spriteCol(page), SLOT_UPDATE_TIMEOUT).toBe(first)
})

test('the battery row reports that nothing has been written for a ROM that never uses SRAM', async ({ page }) => {
  // The vendored demo ROM never touches $6000-$7FFF, so its cartridge RAM
  // stays all zeroes and the Worker deliberately declines to store 8KB of
  // nothing (see `scheduleSramAutosave`). Asserting the *stated* outcome
  // rather than skipping: "nothing written yet" is the correct, visible
  // answer for this cartridge, and a regression that started persisting
  // blank batteries for every ROM would fail here.
  await expect(page.locator('.battery')).toHaveAttribute('data-saved', 'no')
  await expect(page.locator('.battery')).toContainText('nothing written yet')
})


/** Same path `romPicker.spec.ts` uses -- read from `core/` rather than the
 * `web/src/roms/` copy, which is a gitignored build artifact. */
const DEMO_ROM_PATH = resolve(import.meta.dirname, '../../core/tests/roms/nrom_demo/sprite_input_demo.nes')

/**
 * A second, structurally valid NROM cartridge whose bytes differ from the
 * demo's, so `savestate.zig`'s SHA-256 of the file -- the `rom_hash` half of
 * every slot key -- differs too. Built here rather than vendored for the
 * same reason `romPicker.spec.ts` builds its mapper-99 ROM: the point is the
 * identity, and 24KB of near-zeroes is not worth a file in the repo.
 *
 * The reset vector points at $8000, where an infinite `JMP` self-loop keeps
 * the CPU somewhere valid -- this cartridge only has to *load*, not draw.
 */
function otherNromRom(): Buffer {
  const header = Buffer.alloc(16)
  header.write('NES', 0, 'latin1')
  header[4] = 1 // 16KB PRG
  header[5] = 1 // 8KB CHR-ROM
  const prg = Buffer.alloc(0x4000)
  prg[0] = 0x4c // JMP $8000
  prg[1] = 0x00
  prg[2] = 0x80
  prg[0x3ffc] = 0x00 // reset vector -> $8000
  prg[0x3ffd] = 0x80
  return Buffer.concat([header, prg, Buffer.alloc(0x2000)])
}

function pickRom(page: Page, file: string | { name: string; mimeType: string; buffer: Buffer }): Promise<void> {
  return page.locator('.rom-picker input[type=file]').setInputFiles(file)
}

test('slots follow the cartridge across a ROM swap (ENG-77)', async ({ page }) => {
  // Slots are keyed `(rom_hash, slot)`, so swapping the cartridge has to
  // re-key the whole browser. Getting this wrong is not cosmetic: the next
  // save would be filed under the previous game.
  await page.locator(`${slot1} button`, { hasText: 'Save' }).click()
  await expect(page.locator(slot1)).toHaveAttribute('data-occupied', 'yes', SLOT_UPDATE_TIMEOUT)

  await pickRom(page, { name: 'other.nes', mimeType: 'application/octet-stream', buffer: otherNromRom() })
  await expect(page.locator('.rom-readout')).toContainText('other.nes')

  // A different cartridge: its own, empty set of slots.
  await expect(page.locator(slot1)).toHaveAttribute('data-occupied', 'no', SLOT_UPDATE_TIMEOUT)
  await expect(page.locator(`${slot1} button`, { hasText: 'Load' })).toBeDisabled()

  // ...and swapping back brings the demo's save back into view, rather than
  // it having been overwritten or orphaned.
  await pickRom(page, DEMO_ROM_PATH)
  await expect(page.locator('.rom-readout')).toContainText('sprite_input_demo.nes')
  await expect(page.locator(slot1)).toHaveAttribute('data-occupied', 'yes', SLOT_UPDATE_TIMEOUT)
})
