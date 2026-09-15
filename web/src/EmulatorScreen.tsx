import { useCallback, useEffect, useReducer, useRef, useState } from 'react'
import { AudioOutput } from './audio/AudioOutput'
import { isDebugMode } from './debugMode'
import { InputBridge } from './emulator/InputBridge'
import { initialPauseReasonState, isPaused, pauseReasonReducer } from './emulator/pauseReason'
import { cycleSpeed, DEFAULT_SPEED, stepSpeed, type Speed } from './emulator/speedControl'
import { FirstRunBanner } from './FirstRun'
import { Keymap } from './Keymap'
import { RomLibrary } from './RomLibrary'
import { SaveStates } from './SaveStates'
import { TouchControls } from './TouchControls'
import { useFirstRun } from './useFirstRun'
import type { TouchController } from './wasm/touch'
import type { EmulatorWorkerOutbound, RendererKind } from './emulator/protocol'
import { RomLoadReadout, RomPicker } from './RomPicker'
import { useRomLoader } from './useRomLoader'
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

/** Everything that can only be built once per `<canvas>` element, kept
 * together so a remount can reuse it wholesale. `offscreen` is transferred
 * to the Worker on the first `'start'` message and is detached afterwards
 * -- it is retained only so the shape stays honest about what was built. */
interface EmulatorSession {
  worker: Worker
  offscreen: OffscreenCanvas
  inputSab: SharedArrayBuffer
  inputBridge: InputBridge
  romStarted: boolean
}

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
 * refuses `getContext('2d')` entirely (ENG-57), so this reads the live
 * shared-memory view onto the wasm-side framebuffer instead, built from the
 * `'video-ready'` handshake below. No production code path reads it.
 *
 * Returns a `Uint8Array` rather than a plain `number[]`, and that is not a
 * cosmetic choice (ENG-99): Playwright serializes a typed array as one
 * base64 blob, but a `number[]` as 245,760 individual protocol values --
 * which measured at ~1.2s per call on an *idle* machine and several seconds
 * under load, against `waitUntilRunning`'s 5s poll budget. See
 * `e2e/helpers.ts`'s `readFramebuffer`. */
declare global {
  interface Window {
    __frameDebug__?: () => Uint8Array
  }
}

/**
 * The M5 (ENG-70) wasm host: transfers its `<canvas>` to a dedicated Worker
 * (`emulator/emulatorWorker.ts`) via `OffscreenCanvas`, which owns the one
 * wasm instance for the whole pipeline -- video, and (once `AudioOutput`
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
  /** The session's touch controller, surfaced as state (not read off
   * `sessionRef`) so `TouchControls` re-renders once it exists -- a ref
   * mutation wouldn't. */
  const [touch, setTouch] = useState<TouchController | null>(null)
  /** The element that goes fullscreen: the stage, so the on-screen pad
   * comes with the canvas rather than being left behind outside it. */
  const stageRef = useRef<HTMLDivElement>(null)
  /** ENG-77's runtime ROM loading. Owns its own Worker listener and state
   * (see `useRomLoader.ts`); this component only places the controls and
   * hands the drop handlers to the canvas wrapper. */
  const { romLoad, dismiss, loadFile, dragging, dropHandlers } = useRomLoader(worker)
  /** ENG-93's first-run banner/loading copy -- see `useFirstRun.ts` for what
   * "first run" means and what retires it. Kept here rather than inside
   * `FirstRun.tsx` itself so both the loading-overlay swap-in below and the
   * `FirstRunBanner` placed in the stage read the same `active` flag; two
   * independent hook calls would each keep (and could disagree on) their
   * own `dismissed` state. */
  const firstRun = useFirstRun(worker)
  /** The one emulator session for this canvas, held across remounts --
   * see the effect below for why it cannot simply be rebuilt. */
  const sessionRef = useRef<EmulatorSession | null>(null)
  /** Pending deferred teardown, if a cleanup has run and no remount has
   * cancelled it yet. */
  const teardownTimerRef = useRef<number | null>(null)

  /**
   * ENG-90's transport pause. Two independent reasons (`pauseReason.ts`)
   * rather than one boolean: a hidden tab must never be the thing that
   * un-pauses a game the user paused on purpose. Deliberately *not*
   * persisted across a reload -- unlike volume/mute, a fresh load always
   * starts running, per the ticket.
   *
   * `document.hidden` seeds the initial state (rather than always `false`)
   * for the edge case of a session's very first mount happening in a
   * background tab -- e.g. a link opened into a new background tab.
   */
  const [pauseState, dispatchPause] = useReducer(pauseReasonReducer, document.hidden, initialPauseReasonState)
  const paused = isPaused(pauseState)

  /**
   * ENG-91's rewind hold. A ref, not just the mirrored `rewinding` state
   * below, because the keydown/keyup and pointerdown/pointerup handlers
   * that drive it need a synchronous "is a hold already in progress?"
   * check to swallow both key-repeat and a duplicate pointer event (a
   * `pointerdown` that fires again before React re-renders with the state
   * this same handler just set) -- reading `rewinding` state directly here
   * could still observe the pre-update value. The state exists purely to
   * re-render the canvas indicator and the button's `aria-pressed`.
   */
  const rewindHeldRef = useRef(false)
  const [rewinding, setRewinding] = useState(false)

  const startRewind = useCallback(() => {
    if (rewindHeldRef.current) return
    rewindHeldRef.current = true
    setRewinding(true)
    worker?.postMessage({ type: 'rewind-start' })
  }, [worker])

  const stopRewind = useCallback(() => {
    if (!rewindHeldRef.current) return
    rewindHeldRef.current = false
    setRewinding(false)
    worker?.postMessage({ type: 'rewind-end' })
  }, [worker])

  /** ENG-91's speed control: 0.5x/1x/2x. Always starts at 1x on a fresh
   * mount -- like `paused`, this is transport state a reload should not
   * remember (unlike, say, volume/mute). */
  const [speed, setSpeed] = useState<Speed>(DEFAULT_SPEED)

  const applySpeed = useCallback(
    (next: Speed) => {
      setSpeed(next)
      worker?.postMessage({ type: 'set-speed', multiplier: next })
    },
    [worker],
  )

  /** The app-bar button's own click behaviour -- cycling forward, not the
   * `-`/`=` keys' up/down stepping. See `speedControl.ts`'s `cycleSpeed` for
   * why a single button reads correctly wrapping where the keys should not. */
  const handleSpeedCycle = useCallback(() => {
    applySpeed(cycleSpeed(speed))
    canvasRef.current?.focus()
  }, [applySpeed, speed])

  /** ENG-91's frame-step (`K`): a no-op unless the transport is actually
   * paused, matching the ticket's own "only while paused" rule and the
   * app-bar button's `disabled` state below -- re-checked worker-side too
   * (`handleFrameStep` in `emulatorWorker.ts`), because a frame-advance
   * racing a resume is the one transport message where acting on this
   * thread's possibly-stale `paused` would be wrong (see `protocol.ts`'s
   * `'frame-step'` note). */
  const handleFrameStep = useCallback(() => {
    if (!paused) return
    worker?.postMessage({ type: 'frame-step' })
    canvasRef.current?.focus()
  }, [paused, worker])

  /** Drives the ABI's `reset` export -- the emulated console's RESET line,
   * not a reload: WRAM, VRAM and palette survive it exactly as they do on
   * hardware (see `Ppu.reset`). Works, and stays paused, while paused: it
   * posts straight to the Worker's message handler, which runs off the
   * message rather than the (frozen) tick loop -- see
   * `emulatorWorker.ts`'s `paused` doc comment. The new state is real
   * immediately; it's just not *drawn* until the next real step. */
  const handleReset = useCallback(() => {
    worker?.postMessage({ type: 'reset' })
    canvasRef.current?.focus()
  }, [worker])

  /** Toggles the *user*'s own pause intent -- the app-bar button and the
   * `P` key binding both call this. Never touches the `hidden` reason, so
   * a manual pause/resume mid-background just changes what the tab
   * resumes to once it's visible again (see `pauseReason.ts`'s own tests
   * for that interaction). */
  const handlePauseToggle = useCallback(() => {
    dispatchPause({ kind: 'user', paused: !pauseState.user })
    canvasRef.current?.focus()
  }, [pauseState.user])

  // Tells the Worker whenever the *effective* pause state changes -- one
  // message per real transition, regardless of which reason caused it or
  // whether both are true at once (`pauseReasonReducer` already collapses
  // a redundant dispatch into the same object reference, so this effect
  // doesn't even re-run for those). Fire-and-forget, like `'reset'`: see
  // `protocol.ts`'s doc comment on why there's no reply to wait for.
  useEffect(() => {
    worker?.postMessage({ type: paused ? 'pause' : 'resume' })
  }, [worker, paused])

  // Auto-pause while hidden (ENG-90's own acceptance note: a backgrounded
  // tab must stop burning CPU, not just stop being seen). Independent of
  // the user's own reason -- see `pauseReason.ts`. `document.hidden` at
  // the moment the event fires is the correct read either way: the
  // `visibilitychange` event itself doesn't carry the new state.
  useEffect(() => {
    const handleVisibilityChange = () => {
      dispatchPause({ kind: 'hidden', paused: document.hidden })
    }
    document.addEventListener('visibilitychange', handleVisibilityChange)
    return () => document.removeEventListener('visibilitychange', handleVisibilityChange)
  }, [])

  // The `P` key binding. Not part of `KeyboardController` (`wasm/
  // controller.ts`) on purpose -- that maps physical NES-pad buttons, and
  // `P` is deliberately outside `KEY_MAP` (see that file) so the two
  // listeners can never fight over the same key. Ignored while a form
  // control has focus (just the ROM-file `<input>` today) so a future text
  // field typing the letter P can't accidentally pause the game.
  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      // `repeat` ignored: holding the key would otherwise flicker the
      // game in and out of pause at the OS key-repeat rate.
      if (event.code !== 'KeyP' || event.repeat) return
      const target = event.target
      if (target instanceof HTMLElement && (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA')) return
      handlePauseToggle()
    }
    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [handlePauseToggle])

  /**
   * ENG-91's key bindings: `R` (held) rewinds, `K` frame-steps, `-`/`=`
   * (`Minus`/`Equal`, not `KeyMinus`/`KeyEqual` -- neither exists) step the
   * speed down/up. None of these are in `KEY_MAP` (`wasm/controller.ts`) or
   * `P`'s own binding, and stay that way; the control map that tells the
   * player about them lives in `Keymap.tsx`. Ignored the same way `P` is
   * while a form control has focus.
   *
   * `blur` also ends a rewind hold: alt-tabbing (or anything else that
   * steals focus) away mid-hold fires no `keyup` at all, and without this
   * the game would stay frozen and muted until some *other* key event
   * happened to arrive on `KeyR`.
   */
  useEffect(() => {
    const isFormTarget = (target: EventTarget | null): boolean =>
      target instanceof HTMLElement && (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA')

    const handleKeyDown = (event: KeyboardEvent) => {
      if (isFormTarget(event.target)) return
      switch (event.code) {
        case 'KeyR':
          if (event.repeat) return
          event.preventDefault()
          startRewind()
          break
        case 'KeyK':
          if (event.repeat) return
          handleFrameStep()
          break
        case 'Minus':
          if (event.repeat) return
          applySpeed(stepSpeed(speed, -1))
          break
        case 'Equal':
          if (event.repeat) return
          applySpeed(stepSpeed(speed, 1))
          break
      }
    }
    const handleKeyUp = (event: KeyboardEvent) => {
      if (event.code === 'KeyR') stopRewind()
    }
    window.addEventListener('keydown', handleKeyDown)
    window.addEventListener('keyup', handleKeyUp)
    window.addEventListener('blur', stopRewind)
    return () => {
      window.removeEventListener('keydown', handleKeyDown)
      window.removeEventListener('keyup', handleKeyUp)
      window.removeEventListener('blur', stopRewind)
    }
  }, [startRewind, stopRewind, handleFrameStep, applySpeed, speed])

  /** Fullscreen the stage, or leave it. Rendered conditionally on
   * `document.fullscreenEnabled` rather than offered-and-failing: iPhone
   * Safari supports the Fullscreen API on no element at all, so on the
   * device that would benefit most the honest move is to not show a button
   * that cannot work, and let the layout fill the viewport instead. */
  const toggleFullscreen = useCallback(() => {
    if (document.fullscreenElement) void document.exitFullscreen()
    else void stageRef.current?.requestFullscreen()
  }, [])

  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return

    // A teardown scheduled by the cleanup below, still pending. Its
    // presence means this run is a *remount of the same canvas*, not a
    // fresh mount -- cancel the teardown and reuse what it was about to
    // destroy. See `scheduleTeardown` for why teardown is deferred at all.
    if (teardownTimerRef.current !== null) {
      clearTimeout(teardownTimerRef.current)
      teardownTimerRef.current = null
    }

    // **Why this is cached across mounts rather than built per-effect.**
    // `transferControlToOffscreen` is one-shot and irreversible *per
    // canvas element* (ENG-57): after it, the `<canvas>` left in the DOM
    // is an inert placeholder -- CSS sizing still applies, but its own
    // `getContext` is gone for good, and a second transfer call on it
    // throws `InvalidStateError`.
    //
    // React's StrictMode deliberately mounts, unmounts and remounts every
    // component once in development, reusing the same DOM node -- so the
    // second mount hit exactly that throw and the app died before painting
    // a frame. Production builds don't double-invoke, and the e2e suite
    // runs against `vite preview` (a production build), so nothing in CI
    // could see it; it only appeared in `npm run dev`.
    //
    // Caching the session fixes the immediate crash and makes the
    // component genuinely remount-safe, which StrictMode was right to be
    // probing for: any future conditional render or Fast Refresh of this
    // component would have broken it the same way.
    let session = sessionRef.current
    if (session === null) {
      const offscreen = canvas.transferControlToOffscreen()
      const worker = new Worker(new URL('./emulator/emulatorWorker.ts', import.meta.url), { type: 'module' })
      const sab = new SharedArrayBuffer(4)
      session = {
        worker,
        offscreen,
        inputSab: sab,
        inputBridge: new InputBridge(new Int32Array(sab)),
        romStarted: false,
      }
      sessionRef.current = session
    }
    const { worker: emulatorWorker, offscreen, inputSab } = session

    const handleMessage = (event: MessageEvent<EmulatorWorkerOutbound>) => {
      const message = event.data
      if (message.type === 'video-ready') {
        const view = new Uint8ClampedArray(message.sab, message.framebufferPtr, message.width * message.height * 4)
        // Copied out of the shared view on every call, not aliased: the
        // copy is what makes it a plain (non-shared) buffer, which is what
        // lets Playwright hand it across as a single base64 blob.
        window.__frameDebug__ = () => new Uint8Array(view)
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
    // only needs to exist for `AudioOutput`'s button to work, and
    // `startAudio`'s message queue on the Worker side (see
    // `emulatorWorker.ts`) already covers a click racing the boot sequence.
    setWorker(emulatorWorker)
    setTouch(session.inputBridge.touch)

    // Guarded because a StrictMode remount re-runs this effect against a
    // Worker that already has the ROM: sending `'start'` twice would
    // transfer an already-detached `OffscreenCanvas` and throw.
    if (!session.romStarted) {
      session.romStarted = true
      void (async () => {
      try {
        const romResponse = await fetch(demoRomUrl)
        if (!romResponse.ok) {
          throw new Error(`Failed to fetch demo ROM: HTTP ${romResponse.status}`)
        }
        const romBytes = await romResponse.arrayBuffer()
        // Not an effect-scoped `cancelled` flag: a StrictMode unmount runs
        // this effect's cleanup while the session it started deliberately
        // survives, and aborting here would leave that surviving session
        // with a Worker that never receives its ROM. The question that
        // actually matters is whether *this session* is still the live
        // one, which only a real teardown changes.
        if (sessionRef.current !== session) return
        emulatorWorker.postMessage(
          { type: 'start', canvas: offscreen, romBytes, inputSab, preferredRenderer: preferredRendererFromQuery() },
          [offscreen, romBytes],
        )
      } catch (err: unknown) {
        if (sessionRef.current !== session) return
        // `RomLoadError` can't actually reach here (loading now happens
        // inside the Worker, which reports it as a plain `'status'`
        // message), but a fetch failure is exactly as much "the emulator
        // didn't come up" from this component's point of view.
        const message = err instanceof Error ? err.message : String(err)
        setStatus({ kind: 'error', message })
      }
      })()
    }

    return () => {
      emulatorWorker.removeEventListener('message', handleMessage)
      // Deferred, not immediate. StrictMode's unmount/remount pair runs
      // synchronously within one tick, so a timeout scheduled here is
      // cancelled by the remount above before it can fire -- while a real
      // unmount lets it through and tears the session down for good. The
      // Worker, the transferred canvas and the keyboard listeners all
      // survive the fake unmount, which is precisely what makes the
      // remount able to reuse them.
      teardownTimerRef.current = window.setTimeout(() => {
        teardownTimerRef.current = null
        sessionRef.current = null
        delete window.__frameDebug__
        session.inputBridge.dispose()
        session.worker.terminate()
      }, 0)
    }
  }, [])

  return (
    <>
      {/* N8 terminal-command nav. The flags are real controls, not links
          styled to look like a CLI: `--rom` is the file input, `--reset`
          drives the RESET line. Typeset as a command because this *is* a
          developer tool and the vocabulary is honest here; the hit targets
          underneath are ordinary buttons, sized for a thumb. */}
      <header className="appbar">
        <p className="appbar-line">
          <span className="appbar-prompt" aria-hidden="true">&gt;</span>
          <span className="appbar-name">nes</span>
          <RomPicker onPick={loadFile} disabled={status.kind !== 'running'} />
          <button type="button" className="flag reset" onClick={handleReset} disabled={status.kind !== 'running'}>
            --reset
          </button>
          <button
            type="button"
            className="flag pause"
            onClick={handlePauseToggle}
            disabled={status.kind !== 'running'}
            aria-pressed={paused}
          >
            {paused ? '--resume' : '--pause'}
          </button>
          {/* ENG-91: hold-to-rewind. Pointer events, not `onClick` --
              `onPointerDown`/`onPointerUp` are what let this work as a
              press-and-hold on touch the same way the keyboard's `R`
              keydown/keyup does; `onPointerLeave`/`onPointerCancel` end the
              hold too, so a drag off the button (or the OS interrupting the
              gesture) can't leave rewind stuck on the way a missed `keyup`
              could -- see the `blur` listener alongside the keyboard
              handler for that same failure mode. */}
          <button
            type="button"
            className="flag rewind"
            onPointerDown={(event) => {
              event.preventDefault()
              startRewind()
            }}
            onPointerUp={stopRewind}
            onPointerLeave={stopRewind}
            onPointerCancel={stopRewind}
            disabled={status.kind !== 'running'}
            aria-pressed={rewinding}
          >
            --rewind
          </button>
          <button
            type="button"
            className="flag step"
            onClick={handleFrameStep}
            disabled={status.kind !== 'running' || !paused}
          >
            --step
          </button>
          {/* ENG-91's speed control: one button, cycling forward through
              every level on click (`cycleSpeed`) -- `-`/`=` are the
              up/down steppers, this is the "next" affordance for a mouse or
              a thumb. */}
          <button type="button" className="flag speed" onClick={handleSpeedCycle} disabled={status.kind !== 'running'}>
            --speed {speed}x
          </button>
          {document.fullscreenEnabled && (
            <button type="button" className="flag" onClick={toggleFullscreen}>
              --fullscreen
            </button>
          )}
          <span className="appbar-caret" aria-hidden="true">
            &#9612;
          </span>
        </p>
      </header>

      {/* The drop target is the canvas wrapper, not the canvas itself:
          the canvas is an inert placeholder once transferred to the Worker
          (ENG-57), and a wrapper-level highlight can outline the whole
          screen without fighting the canvas's own border. */}
      <div className="stage" ref={stageRef}>
        {/* ENG-93: the first-run card, from first paint rather than once
            `running` -- see `FirstRun.tsx` for the reflow that mounting it
            late caused. */}
        <FirstRunBanner firstRun={firstRun} />
        <div className={dragging ? 'screen screen-dragging' : 'screen'} {...dropHandlers}>
          <canvas
            ref={canvasRef}
            width={FRAMEBUFFER_WIDTH}
            height={FRAMEBUFFER_HEIGHT}
            className="screen-canvas"
            aria-label="NES output"
          />
          {status.kind === 'loading' && <p className="screen-overlay">Loading&#8230;</p>}
          {status.kind === 'error' && <p className="screen-overlay screen-overlay-error">{status.message}</p>}
          {/* ENG-90: pause has to be visible on the canvas itself, not only
              in the app-bar button -- a frozen picture with no label reads
              as "the emulator hung", not "paused on purpose". Gated on
              `status.kind === 'running'` so it can never appear stacked
              over the loading/error overlays above. */}
          {status.kind === 'running' && paused && <p className="screen-overlay screen-overlay-paused">Paused</p>}
          {/* ENG-91: a small, non-covering readout -- deliberately not the
              full-screen `.screen-overlay` treatment above, since both of
              these describe the picture still actively changing underneath
              them (a rewind hold visibly plays frames backward; a non-1x
              speed visibly plays them forward faster/slower), unlike
              Paused/Loading/error which describe a frozen or absent one.
              Rewind wins when both are true: `speedMultiplier` doesn't even
              apply while `rewinding` gates the tick loop worker-side (see
              `emulatorWorker.ts`), so showing "2x" during a hold would be
              stating something not currently in effect. */}
          {status.kind === 'running' && rewinding && (
            <p className="screen-indicator screen-indicator-rewind">Rewinding</p>
          )}
          {status.kind === 'running' && !rewinding && speed !== 1 && (
            <p className="screen-indicator screen-indicator-speed">{speed}x</p>
          )}
        </div>
        <TouchControls touch={touch} />
      </div>

      <aside className="rail">
        {/* Audio leads the rail because on a phone it is a required
            gesture, not a preference -- iOS will not start an AudioContext
            without one, so the button has to be somewhere a thumb lands. */}
        <AudioOutput worker={worker} />

        <div className="status">
          <RomLoadReadout romLoad={romLoad} onDismiss={dismiss} />
          {/* ENG-93: which backend actually engaged isn't inferable from the
              browser (WebGPU is gated by OS and GPU too, per ENG-57), so it's
              stated -- but only behind `?debug` now, per ENG-93's "nothing in
              the UI names a renderer backend" acceptance criterion. Naming
              WebGPU vs. Canvas 2D reads as "this is a dev tool" to everyone
              who isn't debugging ENG-57's fallback path, which is almost
              everyone. `data-renderer` is still emitted whenever this
              renders, so `e2e/renderer.spec.ts` (now navigating with
              `?debug`) has something to assert on. */}
          {status.kind === 'running' && isDebugMode() && (
            <p className="renderer-readout" data-renderer={status.renderer}>
              renderer &#183; {status.renderer === 'webgpu' ? 'WebGPU' : 'Canvas 2D'}
            </p>
          )}
        </div>

        {/* ENG-93: the control map's other home. The footer (`App.tsx`)
            still states it once, but a footer nobody scrolls to is not
            "discoverable" -- this is the same list (`Keymap.tsx`, so the two
            can't drift), placed above the fold like every other rail panel.
            Hidden on touch by `.controls-panel`'s own media query in
            `App.css`, same reasoning as `.keymap`'s: `TouchControls.tsx`'s
            on-screen pad is the real answer there, not a keyboard legend. */}
        <section className="controls-panel" aria-label="Controls">
          <h2>Controls</h2>
          <Keymap />
          <p className="colophon-note">Gamepads work too.</p>
        </section>

        {/* Rendered unconditionally, enabled only once the ROM is running:
            the panel is part of the page's shape, and having it appear late
            would reflow everything below it mid-boot. */}
        <SaveStates worker={worker} enabled={status.kind === 'running'} />

        {/* ENG-89's library surface -- placed below the per-ROM save states
            rather than above them, so this milestone's addition doesn't
            reflow anything the rail already had above the fold. Also owns
            wiring up the resume-on-hide autosave (see its own doc comment),
            which is why it needs `enabled` too. */}
        <RomLibrary worker={worker} enabled={status.kind === 'running'} />
      </aside>
    </>
  )
}
