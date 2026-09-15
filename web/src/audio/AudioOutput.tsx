import { useCallback, useEffect, useRef, useState } from 'react'
import { clampVolume, effectiveGain, loadVolumeSettings, saveVolumeSettings, type VolumeSettings } from './volumeStore'

type Status = { kind: 'idle' } | { kind: 'starting' } | { kind: 'running' } | { kind: 'error'; message: string }

interface DebugInfo {
  fill: number
  underrunCount: number
  /** Peak magnitude of the samples most recently written to the ring, and
   * their RMS -- how `e2e/audio.spec.ts` tells real audio from a pipeline
   * that is dutifully moving silence. See `emulatorWorker.ts`'s
   * `measureRing`. */
  peak: number
  rms: number
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

interface AudioOutputProps {
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
 * plays the real APU audio (ENG-71, M6) the emulated game itself produces,
 * not a test tone.
 */
export function AudioOutput({ worker }: AudioOutputProps) {
  const [status, setStatus] = useState<Status>({ kind: 'idle' })
  const [debugInfo, setDebugInfo] = useState<DebugInfo | null>(null)
  const audioContextRef = useRef<AudioContext | null>(null)
  const debugInfoRef = useRef<DebugInfo | null>(null)
  /** The node built in `start`, connected once the Worker's `'audio-ready'`
   * confirms the ring handshake is in place -- see the message effect
   * below. Two separate `useEffect`s (this one keyed on `worker`, the other
   * mount-only) can't share a plain closure variable, hence the ref. */
  const pendingNodeRef = useRef<AudioWorkletNode | null>(null)
  /** ENG-90: the `GainNode` inserted between the worklet and
   * `audioContext.destination`. Lives in a ref (not the graph edges React
   * itself tracks) because it's built imperatively inside `start`, same as
   * `audioContextRef`. */
  const gainNodeRef = useRef<GainNode | null>(null)
  /** Read once, synchronously, on mount -- `loadVolumeSettings` is what
   * makes "volume and mute survive a reload" true, and the initial
   * `GainNode.gain.value` set in `start` reads this same state rather than
   * a hardcoded default. */
  const [volumeSettings, setVolumeSettings] = useState<VolumeSettings>(() => loadVolumeSettings())
  /** Mirrors `volumeSettings` for `start` (a `useCallback` keyed on
   * `worker`/`status.kind`, not on every slider tick) to read the *current*
   * setting without needing to be rebuilt every time it changes. */
  const volumeSettingsRef = useRef(volumeSettings)

  useEffect(() => {
    window.__audioDebug__ = () => debugInfoRef.current
    return () => {
      delete window.__audioDebug__
      void audioContextRef.current?.close()
    }
  }, [])

  // ENG-90: a real gain change, not a mute toggle in disguise -- `muted`
  // and `volume` are tracked separately (see `volumeStore.ts`'s
  // `effectiveGain`) precisely so this single effect can apply either kind
  // of change the same way, and so unmuting recovers the exact prior level
  // rather than some remembered last-applied gain. Persisted on every
  // change (not just on unmount) so a crash or a hard reload never loses
  // it -- `saveVolumeSettings` itself is the try/catch boundary.
  useEffect(() => {
    volumeSettingsRef.current = volumeSettings
    if (gainNodeRef.current) gainNodeRef.current.gain.value = effectiveGain(volumeSettings)
    saveVolumeSettings(volumeSettings)
  }, [volumeSettings])

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
        // The Worker sends this only once the ring holds a full cushion of
        // samples (see `emulatorWorker.ts`'s `awaitAudioPrimed`), so the
        // tone starts already primed rather than fading in out of an empty
        // buffer. Connecting the node at construction time instead cost a
        // measured ~35ms of counted underruns at every start. `node` is
        // already connected to `gainNode` (done synchronously in `start`,
        // since that edge carries no sound on its own) -- what's withheld
        // until now is `gainNode -> destination`, the edge that actually
        // makes the graph audible.
        const gainNode = gainNodeRef.current
        const audioContext = audioContextRef.current
        pendingNodeRef.current = null
        if (gainNode && audioContext) gainNode.connect(audioContext.destination)
      } else if (data.type === 'stats') {
        const { fill, underrunCount, peak, rms } = data as DebugInfo & { type: 'stats' }
        debugInfoRef.current = { fill, underrunCount, peak, rms }
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
        await audioContext.audioWorklet.addModule(new URL('./audioRingProcessor.js', import.meta.url))
        await audioContext.resume()

        const node = new AudioWorkletNode(audioContext, 'audio-ring-processor', {
          numberOfInputs: 0,
          numberOfOutputs: 1,
          outputChannelCount: [1],
        })
        // Deliberately not connected yet -- see the `'audio-ready'` case above.
        pendingNodeRef.current = node

        // ENG-90's `GainNode`, seeded from whatever was last persisted
        // (`volumeSettingsRef`, not the `volumeSettings` state directly --
        // see that ref's own comment for why). `node -> gainNode` is safe
        // to wire up immediately: it carries no sound until `gainNode` is
        // itself connected to `destination`, which stays withheld until
        // `'audio-ready'` for the same startup-underrun reason the node
        // itself was.
        const gainNode = audioContext.createGain()
        gainNode.gain.value = effectiveGain(volumeSettingsRef.current)
        gainNodeRef.current = gainNode
        node.connect(gainNode)

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
    <div className="audio-output">
      {/* `audio-enable`: ENG-90 added a second `<button>` to `.audio-output`
          below (the mute toggle), so `e2e/audio.spec.ts` needs a selector
          more specific than "the button in `.audio-output`" to keep
          addressing this one. */}
      <button
        type="button"
        className="audio-enable"
        onClick={start}
        disabled={!worker || status.kind === 'starting' || status.kind === 'running'}
      >
        {status.kind === 'running' ? 'Audio playing' : 'Enable audio'}
      </button>

      {/* ENG-90: volume + mute. Rendered unconditionally, not gated on
          `status.kind === 'running'` -- the setting is meaningful (and
          persists) whether or not audio has been enabled yet this session,
          same as the volume knob on a muted TV still being turned before
          the picture comes on. */}
      <div className="audio-volume">
        <label>
          volume
          <input
            type="range"
            min={0}
            max={1}
            step={0.01}
            value={volumeSettings.volume}
            onChange={(event) => {
              const volume = clampVolume(event.target.valueAsNumber)
              // Adjusting the slider is not "unmute" on its own -- ENG-90's
              // acceptance criterion is that volume is a real gain change,
              // never a mute toggle in disguise, so a muted user dragging
              // the slider stays muted (silent) until they explicitly
              // unmute, and simply has a new level waiting for them there.
              setVolumeSettings((prev) => ({ ...prev, volume }))
            }}
            aria-label="Volume"
          />
        </label>
        <button
          type="button"
          aria-pressed={volumeSettings.muted}
          onClick={() => setVolumeSettings((prev) => ({ ...prev, muted: !prev.muted }))}
        >
          {volumeSettings.muted ? '--unmute' : '--mute'}
        </button>
      </div>

      {status.kind === 'error' && <p className="audio-error">{status.message}</p>}
      {status.kind === 'running' && debugInfo && (
        <p className="audio-debug">
          ring fill: {debugInfo.fill} samples · underruns: {debugInfo.underrunCount} · peak:{' '}
          {debugInfo.peak.toFixed(3)}
        </p>
      )}
    </div>
  )
}
