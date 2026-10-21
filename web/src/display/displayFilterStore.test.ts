import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { DEFAULT_DISPLAY_FILTER } from '../emulator/displayFilter'
import { loadDisplayFilter, saveDisplayFilter } from './displayFilterStore'

const CRT_SOME_OFF = {
  filter: 'crt',
  crt: { scanlines: true, curvature: false, chromaticAberration: false, vignette: true },
} as const

describe('loadDisplayFilter / saveDisplayFilter', () => {
  beforeEach(() => {
    localStorage.clear()
  })

  it('defaults to no filter with nothing stored', () => {
    expect(loadDisplayFilter()).toEqual(DEFAULT_DISPLAY_FILTER)
  })

  it('round-trips a saved value', () => {
    saveDisplayFilter(CRT_SOME_OFF)
    expect(loadDisplayFilter()).toEqual(CRT_SOME_OFF)
  })

  it('falls back to defaults for garbage JSON', () => {
    localStorage.setItem('emu.display.filter', '{not json')
    expect(loadDisplayFilter()).toEqual(DEFAULT_DISPLAY_FILTER)
  })

  it('sanitizes a stored value of the wrong shape', () => {
    localStorage.setItem('emu.display.filter', JSON.stringify({ filter: 'crt', crt: { curvature: 0 } }))
    expect(loadDisplayFilter()).toEqual({ filter: 'crt', crt: DEFAULT_DISPLAY_FILTER.crt })
  })

  it('keeps customized CRT options across an Off-to-CRT round trip', () => {
    saveDisplayFilter({ ...CRT_SOME_OFF, filter: 'none' })
    const off = loadDisplayFilter()
    expect(off).toEqual({ ...CRT_SOME_OFF, filter: 'none' })
    saveDisplayFilter({ ...off, filter: 'crt' })
    expect(loadDisplayFilter()).toEqual(CRT_SOME_OFF)
  })

  it('retains known options when a newer stored filter is unavailable', () => {
    localStorage.setItem('emu.display.filter', JSON.stringify({ ...CRT_SOME_OFF, filter: 'ntsc' }))
    expect(loadDisplayFilter()).toEqual({ ...CRT_SOME_OFF, filter: 'none' })
  })

  it('does not rewrite an unreadable stored value during loading', () => {
    localStorage.setItem('emu.display.filter', '{broken')
    expect(loadDisplayFilter()).toEqual(DEFAULT_DISPLAY_FILTER)
    expect(localStorage.getItem('emu.display.filter')).toBe('{broken')
  })

  it('does not share default options between independent loads', () => {
    const first = loadDisplayFilter()
    first.crt.scanlines = false
    expect(loadDisplayFilter()).toEqual(DEFAULT_DISPLAY_FILTER)
    expect(DEFAULT_DISPLAY_FILTER.crt.scanlines).toBe(true)
  })

  describe('when localStorage throws', () => {
    beforeEach(() => {
      vi.spyOn(Storage.prototype, 'getItem').mockImplementation(() => {
        throw new Error('blocked')
      })
      vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => {
        throw new Error('blocked')
      })
    })

    afterEach(() => {
      vi.restoreAllMocks()
    })

    it('loadDisplayFilter falls back to defaults instead of throwing', () => {
      expect(loadDisplayFilter()).toEqual(DEFAULT_DISPLAY_FILTER)
    })

    it('saveDisplayFilter does not throw', () => {
      expect(() => saveDisplayFilter(CRT_SOME_OFF)).not.toThrow()
    })
  })
})
