/**
 * ENG-93's first-run surface: a dismissible card ahead of the screen that
 * says what this is and how to bring your own game. `useFirstRun.ts` decides
 * when it shows; this file is presentation only.
 *
 * It renders from the very first paint, not only once the emulator reports
 * `running`. Mounting it late pushed `.screen` (and, on a phone, the whole
 * touch pad) down mid-boot -- the same late reflow `SaveStates.tsx` is
 * rendered unconditionally to avoid -- and on a short phone that was enough
 * to shove the pad's lower buttons off the bottom of the viewport. The
 * loading overlay underneath stays a plain "Loading…": with this card
 * already on screen above it, repeating the tagline there said it twice.
 *
 * It sits above the screen rather than over it: once the demo is playing,
 * the demo itself is the best argument for "cycle-accurate NES emulator",
 * and a scrim across it would undercut the point of showing it.
 */
import type { FirstRun } from './useFirstRun'

export function FirstRunBanner({ firstRun }: { firstRun: FirstRun }) {
  if (!firstRun.active) return null
  return (
    <div className="first-run-banner" role="note">
      <div className="first-run-copy">
        <p className="first-run-tagline">A cycle-accurate NES emulator, running in this browser tab.</p>
        <p>
          It starts on a built-in demo. Bring your own game with <kbd>--rom</kbd> above
          {/* Drag-and-drop has no touch equivalent, so on a phone this clause
              only adds lines to a card already competing with the touch pad
              for the viewport. See `.first-run-drop` in `App.css`. */}
          <span className="first-run-drop">, or drop a .nes file onto the screen</span>.
        </p>
      </div>
      <button type="button" className="first-run-dismiss" onClick={firstRun.dismiss} aria-label="Dismiss">
        ×
      </button>
    </div>
  )
}
