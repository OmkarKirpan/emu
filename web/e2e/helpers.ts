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
 * 'running'`) flips the instant the Worker's `'status'` message reports the
 * ROM loaded -- before its own tick loop has drawn a single frame. The
 * ROM's *own* boot then needs a few more real NES frames after that (two
 * VBLANK waits before it even turns rendering on -- see
 * `sprite_input_demo.s`), the same settling window the native test suite
 * accounts for with its own `settle_frames`.
 * Polling for the sprite's actual pixels rather than a fixed `waitForTimeout`
 * is what makes every other test in this suite safe to run in parallel:
 * a fixed delay that happens to be long enough on an idle machine can
 * still lose the race under load with several workers competing for CPU.
 *
 * Polls with `readSpriteCol`, never `readFramebuffer`: this runs in
 * `fixtures.ts`'s auto fixture, so it is the one piece of this suite every
 * single test pays for, and a whole-framebuffer round trip per poll
 * iteration is what made the suite collapse under `fullyParallel` (ENG-99).
 * See `readFramebuffer`'s own comment for the numbers.
 */
export async function waitUntilRunning(page: Page): Promise<void> {
  await page.waitForSelector('.reset:not([disabled])')
  await expect
    .poll(() => readSpriteCol(page, SPRITE_ROW, BACKDROP_RGBA), {
      message: 'sprite never appeared in the rendered framebuffer',
    })
    .toBeGreaterThanOrEqual(0)
}

/** Mirrors `EmulatorScreen.tsx`'s `Window.__frameDebug__` shape. Not shared
 * via import: `e2e/`'s own `tsconfig.e2e.json` project doesn't include
 * `src/`, so the ambient `declare global` there isn't visible here -- same
 * reasoning as `audio.spec.ts`'s `AudioDebugWindow`. */
type FrameDebugWindow = { __frameDebug__?: () => Uint8Array }

/**
 * Reads the whole 256x240 RGBA framebuffer via `EmulatorScreen.tsx`'s
 * `__frameDebug__` debug hook -- a copy of a live shared-memory view onto
 * the wasm-side framebuffer, not the canvas's own 2D context: once the
 * canvas is transferred to the emulator Worker (`OffscreenCanvas`, ENG-57),
 * the placeholder element left in the DOM refuses `getContext('2d')`
 * entirely. Exact pixel data either way, no compositing/PNG-encoding in the
 * way.
 *
 * `Uint8Array`, not `number[]`, and the difference is worth ~1.2 seconds a
 * call (ENG-99). Playwright serializes a typed array as a single base64
 * blob, but a plain array as one protocol value *per element* -- 245,760 of
 * them here, which measured at ~1229ms per call on an idle machine with a
 * single page open, and 4.5-7s once several Chromium instances were
 * competing for the CPU. The same read as a typed array measures ~34ms.
 *
 * Even so this is still a whole-frame read, several times the cost of
 * `readSpriteCol` -- so it is for specs that want to assert several things
 * about one frame, and `readSpriteCol` is for anything that polls.
 */
export function readFramebuffer(page: Page): Promise<Uint8Array> {
  return page.evaluate(() => {
    const read = (window as unknown as FrameDebugWindow).__frameDebug__
    if (!read) throw new Error('__frameDebug__ not installed yet -- the video-ready message never arrived')
    return read()
  })
}

/**
 * `findSpriteCol` computed *inside the page*, returning one number instead
 * of a framebuffer.
 *
 * Even with the typed-array transfer above, `readFramebuffer` still ships
 * 240KB across the CDP boundary per call. Scanning in the page and
 * returning a single integer is a constant few milliseconds instead, which
 * is what makes polling -- `waitUntilRunning` on every test, or "wait until
 * the sprite stops moving" (see `savestates.spec.ts`) -- a practical thing
 * to do.
 */
export function readSpriteCol(page: Page, row: number, background: readonly number[]): Promise<number> {
  return page.evaluate(
    ({ row, background }) => {
      const read = (window as unknown as FrameDebugWindow).__frameDebug__
      if (!read) throw new Error('__frameDebug__ not installed yet -- the video-ready message never arrived')
      const framebuffer = read()
      for (let col = 0; col < 256; col++) {
        const o = (row * 256 + col) * 4
        if (
          framebuffer[o] !== background[0] ||
          framebuffer[o + 1] !== background[1] ||
          framebuffer[o + 2] !== background[2]
        ) {
          return col
        }
      }
      return -1
    },
    { row, background: [...background] },
  )
}

/** One pixel's RGBA components, as a plain array so `toEqual` compares it
 * against the `SPRITE_RGBA`/`BACKDROP_RGBA` literals above rather than
 * against a typed array of the same numbers. */
export function pixelAt(framebuffer: Uint8Array, row: number, col: number): number[] {
  const o = (row * 256 + col) * 4
  return Array.from(framebuffer.subarray(o, o + 4))
}

function isBackground(pixel: number[], background: readonly number[]): boolean {
  return pixel[0] === background[0] && pixel[1] === background[1] && pixel[2] === background[2]
}

/** Scans `row` left-to-right for the first pixel that isn't `background`,
 * i.e. the sprite's current leftmost column. Returns -1 if the row is
 * entirely background (the sprite has moved off it, or hasn't rendered). */
export function findSpriteCol(framebuffer: Uint8Array, row: number, background: readonly number[]): number {
  for (let col = 0; col < 256; col++) {
    if (!isBackground(pixelAt(framebuffer, row, col), background)) return col
  }
  return -1
}

/** `findSpriteCol`'s column-scan counterpart, for asserting vertical
 * movement: scans `col` top-to-bottom for the sprite's current topmost row. */
export function findSpriteRow(framebuffer: Uint8Array, col: number, background: readonly number[]): number {
  for (let row = 0; row < 240; row++) {
    if (!isBackground(pixelAt(framebuffer, row, col), background)) return row
  }
  return -1
}
