import { useCallback, useEffect, useRef, useState } from 'react'
import { AudioTestTone } from './audio/AudioTestTone'
import { InputBridge } from './emulator/InputBridge'
import type { EmulatorWorkerOutbound, RendererKind } from './emulator/protocol'
import { FRAMEBUFFER_HEIGHT, FRAMEBUFFER_WIDTH } from './wasm/core'
// The one original, license-clean NROM ROM this repo vendors -- see
// `core/tests/roms/nrom_demo/README.md` for why it stands in for a real
// commercial game. Imported through Vite's asset graph (`?url`) rather than
// hand-built from `BASE_URL`, so a missing ROM fails the build instead of
// 404ing at runtime, and the file gets content-hashed like every other asset.
// `scripts/sync-core.mjs` copies it here from `core/`.
import demoRomUrl from './roms/sprite_input_demo.nes?url'

type Status =
  | { kind: 'loading' }
  | { kind: 'running'; renderer: RendererKind }
  | { kind: 'error'; message: string }

/** Reads `?renderer=webgpu|canvas2d`, the manual override that makes
 * ENG-70's "force Canvas2D fallback and confirm it still works" something
 * you can actually do on a machine where WebGPU *is* available -- by hand,
 * or from `e2e/renderer.spec.ts`. Anything else in the parameter is ignored
 * rather than treated as an error: it's a debugging affordance, not an API.
 */
function preferredRendererFromQuery(): RendererKind | undefined {
  const requested = new URLSearchParams(window.location.search).get('renderer')
  return requested === 'webgpu' || requested === 'canvas2d' ? requested : undefined
}

/** Debug/test hook only: `web/e2e/helpers.ts`'s `readFramebuffer` reads this
 * instead of the canvas's own 2D context -- once `transferControlToOffscreen`
 * hands the canvas to the Worker, the placeholder element left behind
 * refuses `getContext('2d')` entirely (ENG-57), so this is a live shared-
 * memory view onto the wasm-side framebuffer instead, built from the
 * `'video-ready'` handshake below. No production code path reads it. */
declare global {
  interface Window {
    __frameDebug__?: () => number[]
  }
}

/**
 * The M5 (ENG-70) wasm host: transfers its `<canvas>` to a dedicated Worker
 * (`emulator/emulatorWorker.ts`) via `OffscreenCanvas`, which owns the one
 * wasm instance for the whole pipeline -- video, and (once `AudioTestTone`
 * enables it) audio -- and paints via `putImageData` on its own ~60Hz timer.
 * No more `requestAnimationFrame`-driven stepping on this thread; see
 * `emulatorWorker.ts`'s `scheduleLoop` for why that's not a loss. Keyboard
 * and Gamepad input still originate here (`InputBridge`), published into
 * shared memory rather than message-passed. Still Canvas 2D only -- a
 * WebGPU renderer (ENG-57) is unimplemented follow-up work.
 */
export function EmulatorScreen() {
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const [status, setStatus] = useState<Status>({ kind: 'loading' })
  const [worker, setWorker] = useState<Worker | null>(null)

  /** Drives the ABI's `reset` export -- the emulated console's RESET line,
   * not a reload: WRAM, VRAM and palette survive it exactly as they do on
   * hardware (see `Ppu.reset`). */
  const handleReset = useCallback(() => {
    worker?.postMessage({ type: 'reset' })
    canvasRef.current?.focus()
  }, [worker])

  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return

    let cancelled = false
    // One-shot and irreversible per canvas (ENG-57): after this, the
    // `<canvas>` element left in the DOM is an inert placeholder -- CSS
    // sizing still applies to it, but its own `getContext` is gone for good.
    const offscreen = canvas.transferControlToOffscreen()
    const emulatorWorker = new Worker(new URL('./emulator/emulatorWorker.ts', import.meta.url), { type: 'module' })
    const inputSab = new SharedArrayBuffer(4)
    const inputBridge = new InputBridge(new Int32Array(inputSab))

    const handleMessage = (event: MessageEvent<EmulatorWorkerOutbound>) => {
      const message = event.data
      if (message.type === 'video-ready') {
        const view = new Uint8ClampedArray(message.sab, message.framebufferPtr, message.width * message.height * 4)
        window.__frameDebug__ = () => Array.from(view)
      } else if (message.type === 'status') {
        setStatus(
          message.status === 'running'
            ? { kind: 'running', renderer: message.renderer }
            : { kind: 'error', message: message.message },
        )
      }
    }
    emulatorWorker.addEventListener('message', handleMessage)
    // An uncaught exception inside the Worker doesn't otherwise reach this
    // page at all (it's a separate global scope, and nothing here relays
    // it) -- surfacing it here, `console.error` included, is what lets a
    // real crash still show up as a visible error state instead of a
    // silent "stuck on Loading…", and keeps it inside what `fixtures.ts`'s
    // e2e suite already asserts against ("no console/page errors").
    emulatorWorker.onerror = (event: ErrorEvent) => {
      console.error('emulatorWorker error:', event.message)
      setStatus({ kind: 'error', message: event.message })
    }

    // Set eagerly (not once `'status'` confirms the ROM booted): `worker`
    // only needs to exist for `AudioTestTone`'s button to work, and
    // `startAudio`'s message queue on the Worker side (see
    // `emulatorWorker.ts`) already covers a click racing the boot sequence.
    setWorker(emulatorWorker)

    void (async () => {
      try {
        const romResponse = await fetch(demoRomUrl)
        if (!romResponse.ok) {
          throw new Error(`Failed to fetch demo ROM: HTTP ${romResponse.status}`)
        }
        const romBytes = await romResponse.arrayBuffer()
        if (cancelled) return
        emulatorWorker.postMessage(
          { type: 'start', canvas: offscreen, romBytes, inputSab, preferredRenderer: preferredRendererFromQuery() },
          [offscreen, romBytes],
        )
      } catch (err: unknown) {
        if (cancelled) return
        // `RomLoadError` can't actually reach here (loading now happens
        // inside the Worker, which reports it as a plain `'status'`
        // message), but a fetch failure is exactly as much "the emulator
        // didn't come up" from this component's point of view.
        const message = err instanceof Error ? err.message : String(err)
        setStatus({ kind: 'error', message })
      }
    })()

    return () => {
      cancelled = true
      delete window.__frameDebug__
      emulatorWorker.removeEventListener('message', handleMessage)
      inputBridge.dispose()
      emulatorWorker.terminate()
    }
  }, [])

  return (
    <>
      <div className="screen">
        <canvas
          ref={canvasRef}
          width={FRAMEBUFFER_WIDTH}
          height={FRAMEBUFFER_HEIGHT}
          className="screen-canvas"
          aria-label="NES output"
        />
        {status.kind === 'loading' && <p className="screen-overlay">Loading…</p>}
        {status.kind === 'error' && <p className="screen-overlay screen-overlay-error">{status.message}</p>}
      </div>
      <button type="button" className="reset" onClick={handleReset} disabled={status.kind !== 'running'}>
        Reset
      </button>
      {/* Which backend actually engaged isn't inferable from the browser
          (WebGPU is gated by OS and GPU too, per ENG-57), so it's stated.
          `data-renderer` is what `e2e/renderer.spec.ts` asserts on. */}
      {status.kind === 'running' && (
        <p className="renderer-readout" data-renderer={status.renderer}>
          renderer: {status.renderer === 'webgpu' ? 'WebGPU' : 'Canvas 2D'}
        </p>
      )}
      <AudioTestTone worker={worker} />
    </>
  )
}
