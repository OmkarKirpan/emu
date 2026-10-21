import { useEffect, type RefObject } from 'react'

/**
 * Tells the emulator Worker how wide the canvas is on screen, in device
 * pixels, whenever that changes: a window resize, fullscreen, a page zoom,
 * the window moving to a display with a different pixel ratio.
 *
 * Only the main thread can measure this -- the Worker holds the
 * `OffscreenCanvas`, which has no layout -- and a display filter needs it
 * to render one canvas pixel per screen pixel (see
 * `emulator/displayFilter.ts`'s `filteredCanvasSize`). Sent whether or not
 * a filter is on: the Worker keeps the latest value, so switching one on
 * later doesn't have to wait for the next resize.
 *
 * `device-pixel-content-box` is the exact answer where it exists (Chrome,
 * Edge, Firefox). Safari rejects that box type outright, so there it falls
 * back to the CSS width times `devicePixelRatio`, which is the same number
 * up to rounding but isn't re-reported when only the pixel ratio changes.
 *
 * Skips zero and repeated widths. Does nothing without a canvas, Worker,
 * or `ResizeObserver`, and disconnects the observer on cleanup.
 */
export function useDisplayWidth(canvasRef: RefObject<HTMLCanvasElement | null>, worker: Worker | null): void {
  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas || !worker || typeof ResizeObserver === 'undefined') return

    let reported = 0
    const observer = new ResizeObserver(([entry]) => {
      const width =
        entry.devicePixelContentBoxSize?.[0]?.inlineSize ??
        Math.round(entry.contentBoxSize[0].inlineSize * window.devicePixelRatio)
      // Zero while the canvas isn't laid out (e.g. `display: none`), which
      // is no size to render a picture at.
      if (width === 0 || width === reported) return
      reported = width
      worker.postMessage({ type: 'set-display-width', width })
    })
    try {
      observer.observe(canvas, { box: 'device-pixel-content-box' })
    } catch {
      observer.observe(canvas)
    }
    return () => observer.disconnect()
  }, [canvasRef, worker])
}
