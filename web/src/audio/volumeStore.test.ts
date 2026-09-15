import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { clampVolume, effectiveGain, loadVolumeSettings, saveVolumeSettings } from './volumeStore'

describe('clampVolume', () => {
  it('passes through values already in [0, 1]', () => {
    expect(clampVolume(0.42)).toBe(0.42)
  })

  it('clamps above 1 down to 1', () => {
    expect(clampVolume(1.5)).toBe(1)
  })

  it('clamps below 0 up to 0', () => {
    expect(clampVolume(-0.3)).toBe(0)
  })

  it('folds NaN and Infinity back to the default (1)', () => {
    expect(clampVolume(NaN)).toBe(1)
    expect(clampVolume(Infinity)).toBe(1)
    expect(clampVolume(-Infinity)).toBe(1)
  })
})

describe('effectiveGain', () => {
  it('is the stored volume when unmuted', () => {
    expect(effectiveGain({ volume: 0.6, muted: false })).toBe(0.6)
  })

  it('is zero when muted, regardless of the stored volume', () => {
    expect(effectiveGain({ volume: 0.6, muted: true })).toBe(0)
  })

  it('mute never overwrites the recoverable volume', () => {
    const muted = { volume: 0.75, muted: true }
    expect(effectiveGain(muted)).toBe(0)
    expect(effectiveGain({ ...muted, muted: false })).toBe(0.75)
  })
})

describe('loadVolumeSettings / saveVolumeSettings', () => {
  beforeEach(() => {
    localStorage.clear()
  })

  it('defaults to full volume, unmuted, with nothing stored', () => {
    expect(loadVolumeSettings()).toEqual({ volume: 1, muted: false })
  })

  it('round-trips a saved value', () => {
    saveVolumeSettings({ volume: 0.33, muted: true })
    expect(loadVolumeSettings()).toEqual({ volume: 0.33, muted: true })
  })

  it('clamps an out-of-range value on the way back out', () => {
    localStorage.setItem('emu.audio.volume', JSON.stringify({ volume: 4, muted: false }))
    expect(loadVolumeSettings()).toEqual({ volume: 1, muted: false })
  })

  it('falls back to defaults for garbage JSON', () => {
    localStorage.setItem('emu.audio.volume', '{not json')
    expect(loadVolumeSettings()).toEqual({ volume: 1, muted: false })
  })

  it('falls back to defaults for a value of the wrong shape', () => {
    localStorage.setItem('emu.audio.volume', JSON.stringify('nope'))
    expect(loadVolumeSettings()).toEqual({ volume: 1, muted: false })
  })

  it('fills in a missing field from an older build with the default', () => {
    localStorage.setItem('emu.audio.volume', JSON.stringify({ muted: true }))
    expect(loadVolumeSettings()).toEqual({ volume: 1, muted: true })
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

    it('loadVolumeSettings falls back to defaults instead of throwing', () => {
      expect(loadVolumeSettings()).toEqual({ volume: 1, muted: false })
    })

    it('saveVolumeSettings does not throw', () => {
      expect(() => saveVolumeSettings({ volume: 0.5, muted: false })).not.toThrow()
    })
  })
})
