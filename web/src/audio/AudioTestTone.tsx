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

interface AudioTestToneProps {
  /** The already-running `emulatorWorker.ts` instance (or `null` before
   * `EmulatorScreen` has finished spawning it) -- shared with the video
   * path, not a worker of this component's own. See that worker's module
   * doc comment for why audio and video are one Worker/one wasm instance
   * now, rather than the two independent ones the previous slice used. */
  worker: Worker | null
}

/**
 * ENG-70 (M5)'s audio-plumbing acceptance criterion made visible and
 * user-triggerable: a button that stands up the ENG-62 pipeline -- an
 * `AudioContext` (created here, on this click, satisfying the browser's
 * autoplay-gesture requirement -- audio, unlike `EmulatorScreen`'s video,
 * cannot just start playing on mount), the worklet module, and the
 * handshake that connects them to the shared Worker's wasm instance -- and
 * plays the resulting test tone.
 */
export function AudioTestTone({ worker }: AudioTestToneProps) {
  const [status, setStatus] = useState<Status>({ kind: 'idle' })
  const [debugInfo, setDebugInfo] = useState<DebugInfo | null>(null)
  const audioContextRef = useRef<AudioContext | null>(null)
  const debugInfoRef = useRef<DebugInfo | null>(null)
  /** The node built in `start`, connected once the Worker's `'audio-ready'`
   * confirms the ring handshake is in place -- see the message effect
   * below. Two separate `useEffect`s (this one keyed on `worker`, the other
   * mount-only) can't share a plain closure variable, hence the ref. */
  const pendingNodeRef = useRef<AudioWorkletNode | null>(null)

  useEffect(() => {
    window.__audioDebug__ = () => debugInfoRef.current
    return () => {
      delete window.__audioDebug__
      void audioContextRef.current?.close()
    }
  }, [])

  useEffect(() => {
    if (!worker) return
    // `addEventListener`, not `worker.onmessage =`: `EmulatorScreen.tsx`
    // has its own listener on this same Worker for its own message types
    // (`'video-ready'`/`'status'`), and `onmessage` is a single slot that
    // the second assignment would silently clobber.
    const handleMessage = (event: MessageEvent) => {
      const data: unknown = event.data
      if (!data || typeof data !== 'object' || !('type' in data)) return
      if (data.type === 'audio-ready') {
        // Only now -- not the instant the node was constructed in `start`
        // -- does connecting it start pulling render quanta: connecting
        // earlier would have the worklet's `process()` reading an empty
        // ring for as long as the Worker's handshake takes, counting each
        // as an underrun for a startup gap that has nothing to do with the
        // steady-state pipeline health `web/e2e/audio.spec.ts` cares about.
        const node = pendingNodeRef.current
        const audioContext = audioContextRef.current
        pendingNodeRef.current = null
        if (node && audioContext) node.connect(audioContext.destination)
      } else if (data.type === 'stats') {
        const { fill, underrunCount } = data as DebugInfo & { type: 'stats' }
        debugInfoRef.current = { fill, underrunCount }
        setDebugInfo(debugInfoRef.current)
      }
    }
    worker.addEventListener('message', handleMessage)
    return () => worker.removeEventListener('message', handleMessage)
  }, [worker])

  const start = useCallback(() => {
    if (!worker || status.kind === 'starting' || status.kind === 'running') return
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
        // Deliberately not connected yet -- see the `'audio-ready'` case above.
        pendingNodeRef.current = node

        // The port, not `node` itself, is what crosses to the Worker
        // (ENG-62's handshake) -- `node`'s only other job from here is
        // staying connected to `audioContext.destination` for as long as
        // this component lives.
        worker.postMessage({ type: 'audio-start', sampleRate: audioContext.sampleRate, port: node.port }, [node.port])

        // ENG-62's "pathological desync" handling: a suspend/resume cycle
        // (backgrounded tab, etc.) means whatever the ring settled to while
        // suspended is stale, so resync to target fill on the way back to
        // 'running' rather than let the worklet drain (or overrun) it.
        // Skipped on the very first transition into 'running' -- `initAudio`
        // already started the ring fresh; there's nothing stale yet to fix.
        let sawRunning = false
        audioContext.onstatechange = () => {
          if (audioContext.state !== 'running') return
          if (sawRunning) worker.postMessage({ type: 'audio-resync' })
          sawRunning = true
        }

        setStatus({ kind: 'running' })
      } catch (err: unknown) {
        const message = err instanceof Error ? err.message : String(err)
        setStatus({ kind: 'error', message })
      }
    })()
  }, [worker, status.kind])

  return (
    <div className="audio-test-tone">
      <button type="button" onClick={start} disabled={!worker || status.kind === 'starting' || status.kind === 'running'}>
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
