import { expect, type Page } from '@playwright/test'

/** The sprite's initial screen position and color in `sprite_input_demo.nes`
 * (see `core/tests/roms/nrom_demo/README.md` and `sprite_input_demo.s`):
 * an 8x8 solid block at OAM (X=$80, Y=$70), which -- Y is "top row minus 1"
 * (`Ppu.evaluateSprites`) -- first appears on screen row 113. Row 116 is
 * comfortably inside that 8px-tall block regardless of which direction it
 * has since moved. */
export const SPRITE_ROW = 116
export const SPRITE_INITIAL_COL = 128
export const SPRITE_RGBA = [100, 176, 255, 255]
export const BACKDROP_RGBA = [0, 0, 0, 255]

/**
 * Waits until the demo is actually visible on screen, not just "loaded".
 *
 * The Reset button's enabled state (`EmulatorScreen`'s `status.kind ===
 * 'running'`) flips the instant `core.loadRom()` returns -- synchronously,
 * before the rAF loop has drawn a single frame. The ROM's *own* boot then
 * needs a few more real NES frames after that (two VBLANK waits before it
 * even turns rendering on -- see `sprite_input_demo.s`), the same settling
 * window the native test suite accounts for with its own `settle_frames`.
 * Polling for the sprite's actual pixels rather than a fixed `waitForTimeout`
 * is what makes every other test in this suite safe to run in parallel:
 * a fixed delay that happens to be long enough on an idle machine can
 * still lose the race under load with several workers competing for CPU.
 */
export async function waitUntilRunning(page: Page): Promise<void> {
  await page.waitForSelector('.reset:not([disabled])')
  await expect
    .poll(async () => findSpriteCol(await readFramebuffer(page), SPRITE_ROW, BACKDROP_RGBA), {
      message: 'sprite never appeared in the rendered framebuffer',
    })
    .toBeGreaterThanOrEqual(0)
}

/** Reads the whole 256x240 RGBA framebuffer straight off the canvas's own
 * backing store -- not a screenshot, so this is exact pixel data with no
 * compositing, scaling, or PNG-encoding in the way. */
export function readFramebuffer(page: Page): Promise<number[]> {
  return page.evaluate(() => {
    const canvas = document.querySelector('canvas')
    if (!canvas) throw new Error('canvas not found')
    const ctx = canvas.getContext('2d')
    if (!ctx) throw new Error('2d context not found')
    return Array.from(ctx.getImageData(0, 0, 256, 240).data)
  })
}

export function pixelAt(framebuffer: number[], row: number, col: number): number[] {
  const o = (row * 256 + col) * 4
  return framebuffer.slice(o, o + 4)
}

function isBackground(pixel: number[], background: readonly number[]): boolean {
  return pixel[0] === background[0] && pixel[1] === background[1] && pixel[2] === background[2]
}

/** Scans `row` left-to-right for the first pixel that isn't `background`,
 * i.e. the sprite's current leftmost column. Returns -1 if the row is
 * entirely background (the sprite has moved off it, or hasn't rendered). */
export function findSpriteCol(framebuffer: number[], row: number, background: readonly number[]): number {
  for (let col = 0; col < 256; col++) {
    if (!isBackground(pixelAt(framebuffer, row, col), background)) return col
  }
  return -1
}

/** `findSpriteCol`'s column-scan counterpart, for asserting vertical
 * movement: scans `col` top-to-bottom for the sprite's current topmost row. */
export function findSpriteRow(framebuffer: number[], col: number, background: readonly number[]): number {
  for (let row = 0; row < 240; row++) {
    if (!isBackground(pixelAt(framebuffer, row, col), background)) return row
  }
  return -1
}
