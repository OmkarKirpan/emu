import { useCallback, useEffect, useRef, useState } from 'react'

type Status = { kind: 'idle' } | { kind: 'starting' } | { kind: 'running' } | { kind: 'error'; message: string }

interface DebugInfo {
  fill: number
  underrunCount: number
}

/** Debug/test hook only: `web/e2e/audio.spec.ts` reads this to assert the
 * real pipeline (COOP/COEP + shared-memory wasm + Worker + AudioWorklet +
 * Atomics) is actually moving samples end to end, without needing a real
 * audio output device to listen to. No production code path reads it. */
declare global {
  interface Window {
    __audioDebug__?: () => DebugInfo | null
  }
}

/**
 * ENG-70 (M5)'s audio-plumbing acceptance criterion made visible and
 * user-triggerable: a button that stands up the whole ENG-62 pipeline --
 * an `AudioContext` (created here, on this click, satisfying the browser's
 * autoplay-gesture requirement -- audio, unlike `EmulatorScreen`'s video,
 * cannot just start playing on mount), the worklet module, the dedicated
 * Worker (`audioWorker.ts`) and its wasm instance, and the handshake that
 * connects them -- and plays the resulting test tone.
 *
 * Deliberately its own component rather than wired into `EmulatorScreen`:
 * this slice keeps the M4 video/game host and the new audio plumbing as two
 * independent pieces (see `audioWorker.ts`'s module doc comment for why).
 */
export function AudioTestTone() {
  const [status, setStatus] = useState<Status>({ kind: 'idle' })
  const [debugInfo, setDebugInfo] = useState<DebugInfo | null>(null)
  const workerRef = useRef<Worker | null>(null)
  const audioContextRef = useRef<AudioContext | null>(null)
  const debugInfoRef = useRef<DebugInfo | null>(null)

  useEffect(() => {
    window.__audioDebug__ = () => debugInfoRef.current
    return () => {
      delete window.__audioDebug__
      workerRef.current?.postMessage({ type: 'stop' })
      workerRef.current?.terminate()
      void audioContextRef.current?.close()
    }
  }, [])

  const start = useCallback(() => {
    if (status.kind === 'starting' || status.kind === 'running') return
    setStatus({ kind: 'starting' })

    void (async () => {
      try {
        const audioContext = new AudioContext()
        audioContextRef.current = audioContext
        await audioContext.audioWorklet.addModule(new URL('./testToneProcessor.js', import.meta.url))
        await audioContext.resume()

        const node = new AudioWorkletNode(audioContext, 'test-tone-processor', {
          numberOfInputs: 0,
          numberOfOutputs: 1,
          outputChannelCount: [1],
        })
        // Deliberately not connected yet -- see the `'ready'` case below.

        const worker = new Worker(new URL('./audioWorker.ts', import.meta.url), { type: 'module' })
        workerRef.current = worker
        worker.onmessage = (event: MessageEvent) => {
          const data: unknown = event.data
          if (!data || typeof data !== 'object' || !('type' in data)) return
          if (data.type === 'ready') {
            // Only now -- not the instant `node` was constructed -- does
            // connecting it start pulling render quanta: connecting earlier
            // would have the worklet's `process()` reading an empty ring
            // for as long as the Worker's async wasm instantiate + first
            // tick takes, counting each as an underrun for a startup gap
            // that has nothing to do with the steady-state pipeline health
            // `web/e2e/audio.spec.ts` actually cares about.
            node.connect(audioContext.destination)
          } else if (data.type === 'stats') {
            const { fill, underrunCount } = data as DebugInfo & { type: 'stats' }
            debugInfoRef.current = { fill, underrunCount }
            setDebugInfo(debugInfoRef.current)
          }
        }
        // The port, not `node` itself, is what crosses to the Worker (ENG-62's
        // handshake) -- `node`'s only other job from here is staying connected
        // to `audioContext.destination` for as long as this component lives.
        worker.postMessage({ type: 'start', sampleRate: audioContext.sampleRate, port: node.port }, [node.port])

        // ENG-62's "pathological desync" handling: a suspend/resume cycle
        // (backgrounded tab, etc.) means whatever the ring settled to while
        // suspended is stale, so resync to target fill on the way back to
        // 'running' rather than let the worklet drain (or overrun) it.
        // Skipped on the very first transition into 'running' -- `init()`
        // already started the ring fresh; there's nothing stale yet to fix.
        let sawRunning = false
        audioContext.onstatechange = () => {
          if (audioContext.state !== 'running') return
          if (sawRunning) worker.postMessage({ type: 'resync' })
          sawRunning = true
        }

        setStatus({ kind: 'running' })
      } catch (err: unknown) {
        const message = err instanceof Error ? err.message : String(err)
        setStatus({ kind: 'error', message })
      }
    })()
  }, [status.kind])

  return (
    <div className="audio-test-tone">
      <button type="button" onClick={start} disabled={status.kind === 'starting' || status.kind === 'running'}>
        {status.kind === 'running' ? 'Test tone playing' : 'Enable test tone'}
      </button>
      {status.kind === 'error' && <p className="audio-error">{status.message}</p>}
      {status.kind === 'running' && debugInfo && (
        <p className="audio-debug">
          ring fill: {debugInfo.fill} samples · underruns: {debugInfo.underrunCount}
        </p>
      )}
    </div>
  )
}
