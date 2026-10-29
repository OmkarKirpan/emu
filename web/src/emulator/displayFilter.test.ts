import { describe, expect, it } from 'vitest'
import { CRT_OPTIONS, DEFAULT_DISPLAY_FILTER, filteredCanvasSize, sanitizeDisplayFilter } from './displayFilter'

describe('DEFAULT_DISPLAY_FILTER', () => {
  it('is off, so a first visit sees the picture exactly as it has always looked', () => {
    expect(DEFAULT_DISPLAY_FILTER.filter).toBe('none')
  })

  it('has every CRT option on, so switching CRT on shows the whole effect at once', () => {
    expect(DEFAULT_DISPLAY_FILTER.crt).toEqual({
      scanlines: true,
      curvature: true,
      chromaticAberration: true,
      vignette: true,
    })
  })
})

describe('sanitizeDisplayFilter', () => {
  it('passes a well-formed value through unchanged', () => {
    const settings = {
      filter: 'crt',
      crt: { scanlines: false, curvature: true, chromaticAberration: false, vignette: true },
    }
    expect(sanitizeDisplayFilter(settings)).toEqual(settings)
  })

  it('falls back to the defaults for something that is not an object', () => {
    expect(sanitizeDisplayFilter('crt')).toEqual(DEFAULT_DISPLAY_FILTER)
    expect(sanitizeDisplayFilter(null)).toEqual(DEFAULT_DISPLAY_FILTER)
  })

  it('treats an unknown filter kind -- say, one a newer build added -- as off', () => {
    expect(sanitizeDisplayFilter({ filter: 'ntsc', crt: DEFAULT_DISPLAY_FILTER.crt }).filter).toBe('none')
  })

  it('fills each missing or mistyped CRT option from the defaults, independently', () => {
    const settings = sanitizeDisplayFilter({ filter: 'crt', crt: { scanlines: false, vignette: 'yes' } })
    expect(settings.crt).toEqual({ scanlines: false, curvature: true, chromaticAberration: true, vignette: true })
  })

  it('never hands back the shared default object itself', () => {
    const settings = sanitizeDisplayFilter(undefined)
    expect(settings).not.toBe(DEFAULT_DISPLAY_FILTER)
    expect(settings.crt).not.toBe(DEFAULT_DISPLAY_FILTER.crt)
  })

  it.each([undefined, false, 0, 42, [], {}])('defaults safely for %j', (value) => {
    expect(sanitizeDisplayFilter(value)).toEqual(DEFAULT_DISPLAY_FILTER)
  })

  it.each([null, 'off', false, 0, []])('keeps the chosen filter when CRT options are malformed: %j', (crt) => {
    expect(sanitizeDisplayFilter({ filter: 'crt', crt })).toEqual({ ...DEFAULT_DISPLAY_FILTER, filter: 'crt' })
  })

  it.each(CRT_OPTIONS)('preserves false for %s while defaulting the other options', (option) => {
    expect(sanitizeDisplayFilter({ filter: 'crt', crt: { [option]: false } })).toEqual({
      filter: 'crt',
      crt: { ...DEFAULT_DISPLAY_FILTER.crt, [option]: false },
    })
  })

  it('preserves CRT preferences for an unknown filter and discards extra fields', () => {
    const crt = { scanlines: false, curvature: false, chromaticAberration: false, vignette: false }
    expect(sanitizeDisplayFilter({ filter: 'ntsc', crt: { ...crt, brightness: 0.5 }, version: 2 }))
      .toEqual({ filter: 'none', crt })
  })

  it('returns independent settings without mutating or retaining the input options', () => {
    const crt = Object.freeze({ scanlines: false, curvature: true, chromaticAberration: false, vignette: true })
    const input = Object.freeze({ filter: 'crt', crt })
    const first = sanitizeDisplayFilter(input)
    const second = sanitizeDisplayFilter(input)
    expect(first).toEqual(input)
    expect(first.crt).not.toBe(crt)
    first.crt.curvature = false
    expect(second.crt.curvature).toBe(true)
    expect(crt.curvature).toBe(true)
  })
})

describe('filteredCanvasSize', () => {
  it('matches the on-screen width and keeps the NES aspect for the height', () => {
    expect(filteredCanvasSize(1024, 256, 240, 8192)).toEqual({ width: 1024, height: 960 })
  })

  it('rounds a fractional device-pixel width', () => {
    expect(filteredCanvasSize(919.6, 256, 240, 8192)).toEqual({ width: 920, height: 863 })
  })

  it('never goes below the framebuffer itself', () => {
    expect(filteredCanvasSize(100, 256, 240, 8192)).toEqual({ width: 256, height: 240 })
  })

  it("never exceeds the GPU's texture limit", () => {
    expect(filteredCanvasSize(20000, 256, 240, 4096)).toEqual({ width: 4096, height: 3840 })
  })

  it('treats a missing or nonsense width as four times the framebuffer', () => {
    expect(filteredCanvasSize(null, 256, 240, 8192)).toEqual({ width: 1024, height: 960 })
    expect(filteredCanvasSize(NaN, 256, 240, 8192)).toEqual({ width: 1024, height: 960 })
  })

  it.each([Infinity, -Infinity])('uses the fallback for a non-finite width of %s', (width) => {
    expect(filteredCanvasSize(width, 256, 240, 8192)).toEqual({ width: 1024, height: 960 })
  })

  it.each([0, -100, 255.49, 256])('keeps the source resolution at a width of %s', (width) => {
    expect(filteredCanvasSize(width, 256, 240, 8192)).toEqual({ width: 256, height: 240 })
  })

  it('rounds half a device pixel up and derives height from the rounded width', () => {
    expect(filteredCanvasSize(256.5, 256, 240, 8192)).toEqual({ width: 257, height: 241 })
  })

  it('caps the fallback size at the GPU limit too', () => {
    expect(filteredCanvasSize(null, 256, 240, 512)).toEqual({ width: 512, height: 480 })
  })

  it('derives scale and aspect ratio from the provided source dimensions', () => {
    expect(filteredCanvasSize(null, 320, 200, 8192)).toEqual({ width: 1280, height: 800 })
  })
})
