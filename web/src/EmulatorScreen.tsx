import { useEffect, useRef, useState } from 'react'
import { KeyboardController } from './wasm/controller'
import { FRAMEBUFFER_HEIGHT, FRAMEBUFFER_WIDTH, NesCore, RomLoadError } from './wasm/core'

/** The one original, license-clean NROM ROM this repo vendors -- see
 * `core/tests/roms/nrom_demo/README.md` for why it stands in for a real
 * commercial game -- copied into `public/roms/` by `scripts/sync-core.mjs`. */
const DEMO_ROM_URL = `${import.meta.env.BASE_URL}roms/sprite_input_demo.nes`

type Status = { kind: 'loading' } | { kind: 'running' } | { kind: 'error'; message: string }

/**
 * The M4 (ENG-69) wasm host: a plain `<canvas>`, `putImageData` on a
 * `requestAnimationFrame` loop, and keyboard input only -- deliberately no
 * Worker/SharedArrayBuffer/WebGPU yet (that's M5), so this proves the
 * wasm/JS ABI boundary (ENG-60) in isolation.
 */
export function EmulatorScreen() {
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const [status, setStatus] = useState<Status>({ kind: 'loading' })

  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return
    const ctx = canvas.getContext('2d')
    if (!ctx) {
      setStatus({ kind: 'error', message: 'Canvas 2D is not available in this browser.' })
      return
    }

    let cancelled = false
    let rafHandle = 0
    const keyboard = new KeyboardController()

    async function boot() {
      const [core, romResponse] = await Promise.all([NesCore.create(), fetch(DEMO_ROM_URL)])
      if (!romResponse.ok) {
        throw new Error(`Failed to fetch demo ROM: HTTP ${romResponse.status}`)
      }
      const romBytes = new Uint8Array(await romResponse.arrayBuffer())
      core.loadRom(romBytes)
      if (cancelled) return

      setStatus({ kind: 'running' })

      const loop = () => {
        core.setInput(0, keyboard.read())
        const framebuffer = core.stepFrame()
        ctx!.putImageData(new ImageData(framebuffer, FRAMEBUFFER_WIDTH, FRAMEBUFFER_HEIGHT), 0, 0)
        rafHandle = requestAnimationFrame(loop)
      }
      rafHandle = requestAnimationFrame(loop)
    }

    boot().catch((err: unknown) => {
      if (cancelled) return
      const message = err instanceof RomLoadError || err instanceof Error ? err.message : String(err)
      setStatus({ kind: 'error', message })
    })

    return () => {
      cancelled = true
      cancelAnimationFrame(rafHandle)
      keyboard.dispose()
    }
  }, [])

  return (
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
  )
}
