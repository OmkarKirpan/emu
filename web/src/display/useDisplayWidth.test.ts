import { cleanup, renderHook } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { useDisplayWidth } from './useDisplayWidth'

afterEach(cleanup)

/** jsdom has no `ResizeObserver`, so the hook is driven through this
 * stand-in: it records what was observed and lets a test deliver entries
 * the way a browser would. `rejectDevicePixelBox` plays Safari, which
 * throws on the `device-pixel-content-box` box type. */
class FakeResizeObserver {
  static instances: FakeResizeObserver[] = []
  static rejectDevicePixelBox = false
  readonly observed: (ResizeObserverOptions | undefined)[] = []
  disconnected = false
  private readonly callback: ResizeObserverCallback

  constructor(callback: ResizeObserverCallback) {
    this.callback = callback
    FakeResizeObserver.instances.push(this)
  }

  observe(_target: Element, options?: ResizeObserverOptions): void {
    if (options?.box === 'device-pixel-content-box' && FakeResizeObserver.rejectDevicePixelBox) {
      throw new TypeError("'device-pixel-content-box' is not a valid value for enumeration ResizeObserverBoxOptions")
    }
    this.observed.push(options)
  }

  disconnect(): void {
    this.disconnected = true
  }

  deliver(entry: { cssWidth: number; devicePixelWidth?: number }): void {
    const size = (inlineSize: number) => [{ inlineSize, blockSize: 0 }]
    this.callback(
      [
        {
          contentBoxSize: size(entry.cssWidth),
          devicePixelContentBoxSize: entry.devicePixelWidth === undefined ? undefined : size(entry.devicePixelWidth),
        } as unknown as ResizeObserverEntry,
      ],
      this as unknown as ResizeObserver,
    )
  }
}

describe('useDisplayWidth', () => {
  const canvasRef = { current: document.createElement('canvas') }
  let postMessage: ReturnType<typeof vi.fn>
  let worker: Worker

  beforeEach(() => {
    FakeResizeObserver.instances = []
    FakeResizeObserver.rejectDevicePixelBox = false
    vi.stubGlobal('ResizeObserver', FakeResizeObserver)
    postMessage = vi.fn()
    worker = { postMessage } as unknown as Worker
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  const observer = () => FakeResizeObserver.instances[0]

  it("reports the canvas's width in device pixels where the browser measures it directly", () => {
    renderHook(() => useDisplayWidth(canvasRef, worker))
    expect(observer().observed).toEqual([{ box: 'device-pixel-content-box' }])
    observer().deliver({ cssWidth: 736, devicePixelWidth: 920 })
    expect(postMessage).toHaveBeenCalledWith({ type: 'set-display-width', width: 920 })
  })

  it('falls back to CSS width times devicePixelRatio where that box type is rejected (Safari)', () => {
    FakeResizeObserver.rejectDevicePixelBox = true
    vi.stubGlobal('devicePixelRatio', 1.25)
    renderHook(() => useDisplayWidth(canvasRef, worker))
    expect(observer().observed).toEqual([undefined])
    observer().deliver({ cssWidth: 736 })
    expect(postMessage).toHaveBeenCalledWith({ type: 'set-display-width', width: 920 })
  })

  it('sends a width only when it changes, and never a zero one', () => {
    renderHook(() => useDisplayWidth(canvasRef, worker))
    observer().deliver({ cssWidth: 0, devicePixelWidth: 0 })
    observer().deliver({ cssWidth: 736, devicePixelWidth: 920 })
    observer().deliver({ cssWidth: 736, devicePixelWidth: 920 })
    observer().deliver({ cssWidth: 800, devicePixelWidth: 1000 })
    expect(postMessage.mock.calls.map(([message]) => message.width)).toEqual([920, 1000])
  })

  it('stops observing on unmount', () => {
    const { unmount } = renderHook(() => useDisplayWidth(canvasRef, worker))
    unmount()
    expect(observer().disconnected).toBe(true)
  })

  it('does nothing until there is a Worker to tell', () => {
    renderHook(() => useDisplayWidth(canvasRef, null))
    expect(FakeResizeObserver.instances).toHaveLength(0)
  })

  it('rounds CSS widths at fractional pixel ratios and deduplicates the resulting device width', () => {
    vi.stubGlobal('devicePixelRatio', 1.25)
    renderHook(() => useDisplayWidth(canvasRef, worker))
    // The browser can accept the box option and still omit its measurement.
    observer().deliver({ cssWidth: 100.1 })
    observer().deliver({ cssWidth: 100.2 })
    observer().deliver({ cssWidth: 100.4 })
    expect(postMessage.mock.calls.map(([message]) => message.width)).toEqual([125, 126])
  })

  it('does not replace the last useful size when a measured canvas becomes hidden', () => {
    renderHook(() => useDisplayWidth(canvasRef, worker))
    observer().deliver({ cssWidth: 736, devicePixelWidth: 920 })
    observer().deliver({ cssWidth: 0, devicePixelWidth: 0 })
    observer().deliver({ cssWidth: 736, devicePixelWidth: 920 })
    expect(postMessage).toHaveBeenCalledExactlyOnceWith({ type: 'set-display-width', width: 920 })
  })

  it('starts observing when a Worker appears after mount', () => {
    const { rerender } = renderHook(({ w }) => useDisplayWidth(canvasRef, w), {
      initialProps: { w: null as Worker | null },
    })
    rerender({ w: worker })
    expect(FakeResizeObserver.instances).toHaveLength(1)
    observer().deliver({ cssWidth: 736, devicePixelWidth: 920 })
    expect(postMessage).toHaveBeenCalledWith({ type: 'set-display-width', width: 920 })
  })

  it('disconnects an old Worker and sends the same size to its replacement', () => {
    const { rerender } = renderHook(({ w }) => useDisplayWidth(canvasRef, w), {
      initialProps: { w: worker as Worker | null },
    })
    const first = observer()
    first.deliver({ cssWidth: 736, devicePixelWidth: 920 })
    const nextPostMessage = vi.fn()
    rerender({ w: { postMessage: nextPostMessage } as unknown as Worker })
    expect(first.disconnected).toBe(true)
    expect(FakeResizeObserver.instances).toHaveLength(2)
    FakeResizeObserver.instances[1].deliver({ cssWidth: 736, devicePixelWidth: 920 })
    expect(nextPostMessage).toHaveBeenCalledExactlyOnceWith({ type: 'set-display-width', width: 920 })
    expect(postMessage).toHaveBeenCalledTimes(1)
    rerender({ w: null })
    expect(FakeResizeObserver.instances[1].disconnected).toBe(true)
  })

  it('does nothing when the canvas has not mounted', () => {
    renderHook(() => useDisplayWidth({ current: null }, worker))
    expect(FakeResizeObserver.instances).toHaveLength(0)
    expect(postMessage).not.toHaveBeenCalled()
  })

  it('does nothing when ResizeObserver is unavailable', () => {
    vi.stubGlobal('ResizeObserver', undefined)
    renderHook(() => useDisplayWidth(canvasRef, worker))
    expect(postMessage).not.toHaveBeenCalled()
  })
})
