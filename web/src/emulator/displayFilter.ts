/**
 * Display filters: post-processing the WebGPU renderer applies to the
 * finished NES frame on its way to the screen. Purely presentational -- the
 * framebuffer in wasm memory (and everything that reads it: rewind, save
 * states, `e2e/helpers.ts`'s `readFramebuffer`) is the unfiltered picture
 * either way.
 *
 * Global-free on purpose, like `protocol.ts`: the Worker (`renderer.ts`)
 * and the main thread (`display/DisplaySettings.tsx`) both import it, and
 * `tsconfig.worker.json`'s `WebWorker` lib and `tsconfig.app.json`'s `DOM`
 * lib can't both be active in one file. Persistence lives in
 * `display/displayFilterStore.ts`, on the `localStorage` side of that line.
 */

/** Every filter kind, `'none'` included. Adding a filter means a new entry
 * here, a fragment entry point in `shader.ts` (its `SHADER_INTERFACE` is
 * typed against this list, so forgetting one is a type error), and a label
 * in `DisplaySettings.tsx`. */
export const DISPLAY_FILTERS = ['none', 'crt'] as const
export type DisplayFilterKind = (typeof DISPLAY_FILTERS)[number]

/** The CRT filter's four independently switchable effects. Booleans for
 * now; `shader.ts` already treats each as a 0..1 strength, so turning one
 * into a slider later changes this type and the UI, not the shader. */
export interface CrtOptions {
  scanlines: boolean
  curvature: boolean
  chromaticAberration: boolean
  vignette: boolean
}

export interface DisplayFilterSettings {
  filter: DisplayFilterKind
  /** Kept while another filter (or none) is selected, so switching CRT off
   * and back on returns to the same fine-tuning rather than resetting it. */
  crt: CrtOptions
}

/** Off on a first visit -- the picture looks exactly as it did before this
 * setting existed -- but with every CRT effect on, so the first time someone
 * selects CRT they see the whole effect and can switch parts of it off. */
export const DEFAULT_DISPLAY_FILTER: DisplayFilterSettings = {
  filter: 'none',
  crt: { scanlines: true, curvature: true, chromaticAberration: true, vignette: true },
}

/**
 * Folds anything -- a stored value from an older or newer build, a hand-
 * edited one, garbage -- into valid settings, field by field. An unknown
 * filter kind becomes `'none'` rather than the default CRT options being
 * thrown away with it, and each CRT option falls back independently.
 */
export function sanitizeDisplayFilter(value: unknown): DisplayFilterSettings {
  const defaults = DEFAULT_DISPLAY_FILTER
  const raw = value && typeof value === 'object' ? (value as Partial<Record<keyof DisplayFilterSettings, unknown>>) : {}
  const crt = raw.crt && typeof raw.crt === 'object' ? (raw.crt as Partial<Record<keyof CrtOptions, unknown>>) : {}
  const flag = (key: keyof CrtOptions) => (typeof crt[key] === 'boolean' ? crt[key] : defaults.crt[key])
  return {
    filter: DISPLAY_FILTERS.includes(raw.filter as DisplayFilterKind) ? (raw.filter as DisplayFilterKind) : 'none',
    crt: {
      scanlines: flag('scanlines'),
      curvature: flag('curvature'),
      chromaticAberration: flag('chromaticAberration'),
      vignette: flag('vignette'),
    },
  }
}

/** Used until the main thread has measured the canvas (`useDisplayWidth`). */
const FALLBACK_SCALE = 4

/**
 * The canvas backing-store size while a filter is on.
 *
 * Unfiltered, the canvas stays at the framebuffer's own 256x240 and CSS
 * scales it up with `image-rendering: pixelated`. That can't work for a CRT
 * effect: a scanline is *less* than one NES row tall, and curvature and
 * colour fringing move the picture by fractions of a pixel, so the shader
 * has to run once per pixel actually on screen. Hence the backing store is
 * matched to the canvas's displayed width in device pixels -- one shader
 * invocation per physical pixel, nothing for the browser to rescale, and so
 * no moire between the scanlines and a resampling grid.
 *
 * The height comes from the framebuffer's aspect rather than being measured
 * separately, so the canvas's own aspect (and the CSS height derived from
 * it) can't drift by a rounding step on every resize.
 */
export function filteredCanvasSize(
  displayWidth: number | null,
  sourceWidth: number,
  sourceHeight: number,
  maxDimension: number,
): { width: number; height: number } {
  const wanted = displayWidth !== null && Number.isFinite(displayWidth) ? displayWidth : sourceWidth * FALLBACK_SCALE
  const width = Math.min(maxDimension, Math.max(sourceWidth, Math.round(wanted)))
  return { width, height: Math.round((width * sourceHeight) / sourceWidth) }
}
