import { useCallback, useEffect, useRef, useState } from 'react'
import { KeyboardController } from './wasm/controller'
import { FRAMEBUFFER_HEIGHT, FRAMEBUFFER_WIDTH, NesCore } from './wasm/core'
import { GamepadController } from './wasm/gamepad'
// The one original, license-clean NROM ROM this repo vendors -- see
// `core/tests/roms/nrom_demo/README.md` for why it stands in for a real
// commercial game. Imported through Vite's asset graph (`?url`) rather than
// hand-built from `BASE_URL`, so a missing ROM fails the build instead of
// 404ing at runtime, and the file gets content-hashed like every other asset.
// `scripts/sync-core.mjs` copies it here from `core/`.
import demoRomUrl from './roms/sprite_input_demo.nes?url'
import { NTSC_FRAME_MS } from './timing'

type Status = { kind: 'loading' } | { kind: 'running' } | { kind: 'error'; message: string }

/**
 * Ceiling on how many frames one animation frame may catch up. A backgrounded
 * tab hands back a multi-second delta on return; without a cap the loop would
 * try to emulate all of it in a single blocking burst. Dropping that time is
 * the right trade -- an emulator that skips ahead beats one that freezes the
 * page.
 */
const MAX_CATCHUP_FRAMES = 4

/**
 * The M4 (ENG-69) wasm host: a plain `<canvas>`, `putImageData` on a
 * `requestAnimationFrame` loop -- deliberately no Worker/SharedArrayBuffer/
 * WebGPU for *this* pipeline yet (that's the rest of M5/ENG-70; the audio
 * ring buffer's own Worker is separate, see `web/src/audio/`), so this still
 * proves the wasm/JS ABI boundary (ENG-60) in isolation. Gamepad input
 * (ENG-70) was added alongside the original keyboard-only input.
 */
export function EmulatorScreen() {
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const coreRef = useRef<NesCore | null>(null)
  const [status, setStatus] = useState<Status>({ kind: 'loading' })

  /** Drives the ABI's `reset` export -- the emulated console's RESET line,
   * not a reload: WRAM, VRAM and palette survive it exactly as they do on
   * hardware (see `Ppu.reset`). */
  const handleReset = useCallback(() => {
    coreRef.current?.reset()
    canvasRef.current?.focus()
  }, [])

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
    const gamepad = new GamepadController()

    // An arrow rather than a hoisted `function`: TypeScript won't carry the
    // `if (!ctx) return` narrowing above into a hoisted declaration's body
    // (it could in principle be called before the narrowing runs), which
    // would force a `ctx!` assertion inside the per-frame loop below --
    // exactly where an assertion would keep compiling if that guard ever
    // moved.
    const boot = async () => {
      const [core, romResponse] = await Promise.all([NesCore.create(), fetch(demoRomUrl)])
      if (!romResponse.ok) {
        throw new Error(`Failed to fetch demo ROM: HTTP ${romResponse.status}`)
      }
      const romBytes = new Uint8Array(await romResponse.arrayBuffer())
      core.loadRom(romBytes)
      if (cancelled) return

      coreRef.current = core
      setStatus({ kind: 'running' })

      // `requestAnimationFrame` fires at the *display's* refresh rate, which
      // is not the NES's. Stepping one frame per callback would run the
      // emulator at double speed on a 120Hz panel and at 2.4x on a 144Hz one,
      // so frames are paced against wall-clock time and rAF is used only as
      // the paint/vsync signal.
      let pendingFrames = 0
      let lastTick = performance.now()

      const loop = (now: number) => {
        rafHandle = requestAnimationFrame(loop)

        pendingFrames = Math.min(
          pendingFrames + (now - lastTick) / NTSC_FRAME_MS,
          MAX_CATCHUP_FRAMES,
        )
        lastTick = now
        if (pendingFrames < 1) return // display is ahead of the NES; nothing to draw yet

        // `do`/`while` rather than `while`: the guard above already proved at
        // least one frame is due, which is also what lets `framebuffer` be
        // definitely assigned without a non-null assertion.
        let framebuffer: Uint8ClampedArray<ArrayBuffer>
        do {
          pendingFrames -= 1
          // Gamepad state is polled fresh (not event-driven, see
          // `GamepadController`) and OR'd with the keyboard's -- both are
          // controller 0, matching a NES's single canonical input per port
          // rather than modeling keyboard and gamepad as separate ports.
          core.setInput(0, keyboard.read() | gamepad.read())
          framebuffer = core.stepFrame()
        } while (pendingFrames >= 1)

        ctx.putImageData(new ImageData(framebuffer, FRAMEBUFFER_WIDTH, FRAMEBUFFER_HEIGHT), 0, 0)
      }
      rafHandle = requestAnimationFrame(loop)
    }

    boot().catch((err: unknown) => {
      if (cancelled) return
      // `RomLoadError extends Error`, so one check covers both.
      const message = err instanceof Error ? err.message : String(err)
      setStatus({ kind: 'error', message })
    })

    return () => {
      cancelled = true
      cancelAnimationFrame(rafHandle)
      keyboard.dispose()
      coreRef.current = null
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
    </>
  )
}
