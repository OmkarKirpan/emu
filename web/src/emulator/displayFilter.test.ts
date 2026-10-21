import { describe, expect, it } from 'vitest'
import { DEFAULT_DISPLAY_FILTER, filteredCanvasSize, sanitizeDisplayFilter } from './displayFilter'

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
})
