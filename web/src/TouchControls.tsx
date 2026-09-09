import { useCallback, useEffect, useRef } from 'react'
import { Button } from './wasm/controller'
import { directionFromOffset, type TouchController } from './wasm/touch'

/**
 * The on-screen gamepad -- the piece that makes this thing playable on a
 * phone at all. Until it existed the page rendered fine on iOS and there was
 * simply no way to press A.
 *
 * Rendered only where a coarse pointer exists (see `.touchpad`'s media query
 * in `App.css`); a laptop gets nothing, because a laptop already has a
 * keyboard. It writes into the same `Int32Array` slot the keyboard and
 * Gamepad API paths write into, via `InputBridge`'s `TouchController`, so
 * from the Worker's side there is one controller and it does not care which
 * of the three moved it.
 *
 * Nothing here is React state. A frame of input latency is the whole budget
 * for a control that has to feel like hardware, and a `setState` per pointer
 * move would spend it re-rendering; instead the handlers write straight into
 * the controller (read by `InputBridge`'s rAF tick) and toggle a class on
 * the DOM node for the visual press. React owns the structure, not the
 * frame-by-frame state.
 */
interface TouchControlsProps {
  touch: TouchController | null
}

/** Face buttons, in DOM order. `Button` values come from `wasm/controller.ts`
 * -- the same NES bit layout the core expects. */
const FACE_BUTTONS = [
  { mask: Button.B, label: 'B', className: 'pad-face-b' },
  { mask: Button.A, label: 'A', className: 'pad-face-a' },
] as const

const MENU_BUTTONS = [
  { mask: Button.Select, label: 'Select' },
  { mask: Button.Start, label: 'Start' },
] as const

/** The direction mask as space-separated tokens, so CSS can light one arm
 * with `[data-dir~='up']` instead of the stylesheet enumerating all nine
 * numeric states. */
function directionTokens(mask: number): string {
  const names: string[] = []
  if (mask & Button.Up) names.push('up')
  if (mask & Button.Down) names.push('down')
  if (mask & Button.Left) names.push('left')
  if (mask & Button.Right) names.push('right')
  return names.join(' ')
}

/**
 * Bind the pointer to the element it started on, so a thumb that slides
 * outside the control keeps driving it.
 *
 * Best-effort, and called *after* the input has already been applied:
 * `setPointerCapture` throws `NotFoundError` for a pointer the UA no longer
 * considers active, and doing it first meant that throw aborted the handler
 * and swallowed the press entirely. Capture is an enhancement -- losing it
 * costs off-element tracking, which is a much smaller failure than a button
 * that does nothing.
 */
function capture(element: Element, pointerId: number): void {
  try {
    element.setPointerCapture(pointerId)
  } catch {
    /* pointer already gone; the press still registered above */
  }
}

/** A short tick on press where the platform offers one. Absent on iOS
 * Safari, which exposes no vibration API at all -- hence the guard rather
 * than a polyfill; a button that feels like a button on Android and merely
 * looks like one on iPhone is the honest ceiling here. */
function tick(): void {
  navigator.vibrate?.(8)
}

export function TouchControls({ touch }: TouchControlsProps) {
  const dpadRef = useRef<HTMLDivElement>(null)

  // A pointer that disappears while the page is backgrounded (app switch,
  // incoming call, screen lock) never delivers its `pointerup`. Without
  // this, coming back to the tab finds the game still holding Right.
  useEffect(() => {
    if (!touch) return
    const release = () => {
      if (document.visibilityState === 'hidden') touch.clear()
    }
    document.addEventListener('visibilitychange', release)
    return () => {
      document.removeEventListener('visibilitychange', release)
      touch.clear()
    }
  }, [touch])

  const readDpad = useCallback(
    (event: React.PointerEvent<HTMLDivElement>) => {
      const pad = dpadRef.current
      if (!pad || !touch) return
      const box = pad.getBoundingClientRect()
      // Normalised to the pad's half-size, so the corner is (±1, ±1) and the
      // geometry in `directionFromOffset` is resolution-independent.
      const dx = (event.clientX - (box.left + box.width / 2)) / (box.width / 2)
      const dy = (event.clientY - (box.top + box.height / 2)) / (box.height / 2)
      const mask = directionFromOffset(dx, dy)
      touch.setDirection(mask)
      // Drives the lit arm purely through an attribute, so the visual state
      // and the emulated state can never disagree -- they are set on the
      // same line.
      pad.dataset.dir = directionTokens(mask)
    },
    [touch],
  )

  const startDpad = useCallback(
    (event: React.PointerEvent<HTMLDivElement>) => {
      readDpad(event)
      // Capture so a thumb that slides off the pad mid-swipe keeps steering
      // it, instead of the direction sticking at whatever it was when the
      // pointer crossed the edge. After the read, never before -- see
      // `capture`.
      capture(event.currentTarget, event.pointerId)
      tick()
    },
    [readDpad],
  )

  const moveDpad = useCallback(
    (event: React.PointerEvent<HTMLDivElement>) => {
      // Only a pointer this pad has captured steers it. Without the guard a
      // mouse merely passing over the pad on a hybrid device would drive the
      // game.
      if (!event.currentTarget.hasPointerCapture(event.pointerId)) return
      readDpad(event)
    },
    [readDpad],
  )

  const endDpad = useCallback(
    (event: React.PointerEvent<HTMLDivElement>) => {
      touch?.setDirection(0)
      if (dpadRef.current) dpadRef.current.dataset.dir = ''
      try {
        event.currentTarget.releasePointerCapture(event.pointerId)
      } catch {
        /* never captured, or already released */
      }
    },
    [touch],
  )

  const press = useCallback(
    (mask: number) => (event: React.PointerEvent<HTMLButtonElement>) => {
      touch?.setButton(mask, true)
      event.currentTarget.dataset.pressed = 'yes'
      // Per-button capture, not a shared handler on the parent: A and B have
      // to be holdable simultaneously by two different thumbs, and each
      // pointer needs to stay bound to the button it started on.
      capture(event.currentTarget, event.pointerId)
      tick()
    },
    [touch],
  )

  const release = useCallback(
    (mask: number) => (event: React.PointerEvent<HTMLButtonElement>) => {
      touch?.setButton(mask, false)
      event.currentTarget.dataset.pressed = 'no'
    },
    [touch],
  )

  return (
    // `onContextMenu` suppressed across the whole pad: a long press on a
    // button -- which is just "holding a direction" -- otherwise raises the
    // OS text-selection menu over the game.
    <div className="touchpad" onContextMenu={(event) => event.preventDefault()}>
      <div
        ref={dpadRef}
        className="pad-dpad"
        data-dir=""
        role="group"
        aria-label="D-pad"
        onPointerDown={startDpad}
        onPointerMove={moveDpad}
        onPointerUp={endDpad}
        onPointerCancel={endDpad}
      >
        {/* Four arms, drawn not hit-tested: the pad is one pointer target
            and `directionFromOffset` decides what was meant. These exist to
            show the shape and to light up. */}
        <span className="pad-arm pad-arm-up" aria-hidden="true" />
        <span className="pad-arm pad-arm-down" aria-hidden="true" />
        <span className="pad-arm pad-arm-left" aria-hidden="true" />
        <span className="pad-arm pad-arm-right" aria-hidden="true" />
        <span className="pad-hub" aria-hidden="true" />
      </div>

      <div className="pad-menu">
        {MENU_BUTTONS.map(({ mask, label }) => (
          <button
            key={label}
            type="button"
            className="pad-pill"
            data-pressed="no"
            onPointerDown={press(mask)}
            onPointerUp={release(mask)}
            onPointerCancel={release(mask)}
          >
            {label}
          </button>
        ))}
      </div>

      <div className="pad-faces">
        {FACE_BUTTONS.map(({ mask, label, className }) => (
          <button
            key={label}
            type="button"
            className={`pad-face ${className}`}
            data-pressed="no"
            aria-label={`${label} button`}
            onPointerDown={press(mask)}
            onPointerUp={release(mask)}
            onPointerCancel={release(mask)}
          >
            {label}
          </button>
        ))}
      </div>
    </div>
  )
}
