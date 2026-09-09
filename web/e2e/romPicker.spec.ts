import { resolve } from 'node:path'
import type { Page } from '@playwright/test'
import { BACKDROP_RGBA, findSpriteCol, readFramebuffer, SPRITE_INITIAL_COL, SPRITE_ROW } from './helpers'
import { expect, test } from './fixtures'

/**
 * ENG-77's runtime ROM picker, driven through the real `<input
 * type="file">` (`setInputFiles` reaches it because the input is laid over
 * its label at zero opacity rather than hidden -- see `App.css`).
 *
 * Every test here starts from the booted demo, per `fixtures.ts`.
 */

/** The one ROM this repo vendors, read straight from `core/` rather than
 * from `web/src/roms/` -- the latter is a build artifact `sync-core.mjs`
 * copies in and `.gitignore`s, so it may not exist before a build. */
const DEMO_ROM_PATH = resolve(import.meta.dirname, '../../core/tests/roms/nrom_demo/sprite_input_demo.nes')

/**
 * A structurally valid iNES ROM that declares mapper 99, which
 * `core/src/rom.zig`'s `createMapper` does not implement.
 *
 * Built here rather than vendored: the point is the *header*, and 24KB of
 * zeroes is not worth a file in the repo. Mapper number 99 = `0x63` is
 * split across two header bytes, low nibble in byte 6's high nibble and
 * high nibble in byte 7's -- and byte 7's bits 2-3 stay `0b00`, which is
 * what keeps `rom.zig` parsing this as plain iNES rather than NES 2.0.
 */
function unsupportedMapperRom(): Buffer {
  const prgBanks = 1 // 16KB
  const chrBanks = 1 // 8KB
  const header = Buffer.alloc(16)
  header.write('NES\x1a', 0, 'latin1')
  header[4] = prgBanks
  header[5] = chrBanks
  header[6] = 0x30 // mapper low nibble = 3
  header[7] = 0x60 // mapper high nibble = 6  ->  0x63 = 99
  return Buffer.concat([header, Buffer.alloc(prgBanks * 0x4000 + chrBanks * 0x2000)])
}

function pickRom(page: Page, file: string | { name: string; mimeType: string; buffer: Buffer }): Promise<void> {
  return page.locator('.rom-picker input[type=file]').setInputFiles(file)
}

test('an unsupported mapper is reported inline and leaves the running game alone', async ({ page }) => {
  await pickRom(page, { name: 'mapper99.nes', mimeType: 'application/octet-stream', buffer: unsupportedMapperRom() })

  const error = page.locator('.rom-error')
  await expect(error).toContainText('mapper99.nes')
  await expect(error).toContainText('Unsupported mapper 99')

  // The whole point of the non-fatal treatment: `load_rom` validates into
  // a throwaway parse before touching `rom_storage`, so the demo is still
  // running underneath the message -- not merely still painted, but still
  // *responding to input*.
  await expect(page.locator('.screen-overlay')).toHaveCount(0)
  const before = findSpriteCol(await readFramebuffer(page), SPRITE_ROW, BACKDROP_RGBA)
  await page.keyboard.down('ArrowRight')
  await page.waitForTimeout(400)
  await page.keyboard.up('ArrowRight')
  const after = findSpriteCol(await readFramebuffer(page), SPRITE_ROW, BACKDROP_RGBA)
  expect(after).toBeGreaterThan(before)

  await page.click('.rom-error-dismiss')
  await expect(error).toHaveCount(0)
})

test('a file that is not a ROM at all reports a bad header', async ({ page }) => {
  await pickRom(page, {
    name: 'not-a-rom.nes',
    mimeType: 'application/octet-stream',
    buffer: Buffer.from('this is not a cartridge'),
  })

  await expect(page.locator('.rom-error')).toContainText('Not a valid iNES ROM file.')
  await expect(page.locator('.screen-overlay')).toHaveCount(0)
})

test('loading a ROM cold-boots the machine rather than resetting it', async ({ page }) => {
  // Move the sprite off its start column first, so "back at the start" is
  // a real observation rather than something that was already true.
  await page.keyboard.down('ArrowRight')
  await page.waitForTimeout(400)
  await page.keyboard.up('ArrowRight')
  expect(findSpriteCol(await readFramebuffer(page), SPRITE_ROW, BACKDROP_RGBA)).toBeGreaterThan(SPRITE_INITIAL_COL)

  await pickRom(page, DEMO_ROM_PATH)
  await expect(page.locator('.rom-readout')).toContainText('sprite_input_demo.nes')
  await expect(page.locator('.rom-error')).toHaveCount(0)

  // Polled, not sampled once: the freshly booted ROM waits two VBLANKs
  // before it turns rendering on (see `waitUntilRunning`'s comment), so
  // the frame right after the load is legitimately blank.
  await expect
    .poll(async () => findSpriteCol(await readFramebuffer(page), SPRITE_ROW, BACKDROP_RGBA), {
      message: 'the sprite never returned to its power-on column after the ROM load',
    })
    .toBe(SPRITE_INITIAL_COL)
})
