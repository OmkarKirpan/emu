import { act, renderHook } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { useFirstRun } from './useFirstRun'
import type { EmulatorWorkerOutbound } from './emulator/protocol'

const STORAGE_KEY = 'emu.firstRun.dismissed'

/** Same fake as `RomLibrary.test.tsx`'s: a real `EventTarget` standing in for
 * the emulator Worker, so `addEventListener`/`removeEventListener` are
 * genuinely exercised. */
function fakeWorker() {
  const target = new EventTarget()
  const postMessage = vi.fn()
  const worker = Object.assign(target, { postMessage }) as unknown as Worker
  return {
    worker,
    reply(message: EmulatorWorkerOutbound) {
      target.dispatchEvent(Object.assign(new Event('message'), { data: message }))
    },
  }
}

beforeEach(() => localStorage.clear())
afterEach(() => localStorage.clear())

describe('a fresh browser', () => {
  it('starts active', () => {
    const { result } = renderHook(() => useFirstRun(null))
    expect(result.current.active).toBe(true)
  })

  it('reads a previously dismissed flag back as inactive', () => {
    localStorage.setItem(STORAGE_KEY, 'true')
    const { result } = renderHook(() => useFirstRun(null))
    expect(result.current.active).toBe(false)
  })
})

describe('dismiss()', () => {
  it('flips active and persists, surviving a fresh mount', () => {
    const { result, unmount } = renderHook(() => useFirstRun(null))
    act(() => result.current.dismiss())
    expect(result.current.active).toBe(false)
    unmount()

    const { result: second } = renderHook(() => useFirstRun(null))
    expect(second.current.active).toBe(false)
  })

  it('does not crash when localStorage throws (blocked storage)', () => {
    const spy = vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => {
      throw new Error('blocked')
    })
    const { result } = renderHook(() => useFirstRun(null))
    expect(() => act(() => result.current.dismiss())).not.toThrow()
    expect(result.current.active).toBe(false) // in-memory state still flips
    spy.mockRestore()
  })
})

describe('worker-driven dismissal', () => {
  it('a successful rom-loaded retires it', () => {
    const { worker, reply } = fakeWorker()
    const { result } = renderHook(() => useFirstRun(worker))
    expect(result.current.active).toBe(true)

    act(() => reply({ type: 'rom-loaded', ok: true }))

    expect(result.current.active).toBe(false)
    expect(localStorage.getItem(STORAGE_KEY)).toBe('true')
  })

  it('a failed rom-loaded leaves it active -- nothing was learned', () => {
    const { worker, reply } = fakeWorker()
    const { result } = renderHook(() => useFirstRun(worker))

    act(() => reply({ type: 'rom-loaded', ok: false, message: 'Not a valid iNES ROM file.' }))

    expect(result.current.active).toBe(true)
  })

  it('a boot-rom message (ENG-89 library resume) retires it', () => {
    const { worker, reply } = fakeWorker()
    const { result } = renderHook(() => useFirstRun(worker))

    act(() => reply({ type: 'boot-rom', name: 'metroid.nes' }))

    expect(result.current.active).toBe(false)
  })

  it('ignores unrelated messages', () => {
    const { worker, reply } = fakeWorker()
    const { result } = renderHook(() => useFirstRun(worker))

    act(() => reply({ type: 'stats', fill: 1024, underrunCount: 0, peak: 0.5, rms: 0.2 }))

    expect(result.current.active).toBe(true)
  })

  it('does nothing before the Worker exists', () => {
    const { result } = renderHook(() => useFirstRun(null))
    expect(() => result.current.dismiss()).not.toThrow()
  })
})
