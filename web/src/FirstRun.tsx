/**
 * ENG-93's first-run surface, in two pieces because it occupies two
 * different moments and can't be one element rendered continuously:
 *
 * - `FirstRunLoading` replaces the bare "Loading…" text inside
 *   `EmulatorScreen.tsx`'s `.screen-overlay` for as long as boot takes --
 *   the very first thing a first-time visitor's eyes land on, before there
 *   is even a frame to look at.
 * - `FirstRunBanner` takes over once the emulator is actually running (the
 *   demo, playing itself, is a better argument for "cycle-accurate NES
 *   emulator" than any sentence could be) and stays -- dismissible, not
 *   timed out -- until `useFirstRun.ts` retires it. It sits above the
 *   screen rather than over it: unlike the loading state, there is now a
 *   game worth seeing underneath, and a scrim across it would undercut the
 *   very point of showing it.
 *
 * Both read from `useFirstRun.ts` rather than deciding anything themselves
 * -- this file is presentation only.
 */
import type { FirstRun } from './useFirstRun'

/** Same tagline in both -- what this *is* has to land before "how do I load
 * my own game" does, and it has to survive on its own in the loading state,
 * where there's nothing else on screen yet to give it context. */
function Tagline() {
  return <p className="first-run-tagline">A cycle-accurate NES emulator, running in this browser tab.</p>
}

export function FirstRunLoading() {
  return (
    <div className="screen-overlay first-run-loading">
      <Tagline />
      <p>Loading&#8230;</p>
    </div>
  )
}

export function FirstRunBanner({ firstRun }: { firstRun: FirstRun }) {
  if (!firstRun.active) return null
  return (
    <div className="first-run-banner" role="note">
      <div className="first-run-copy">
        <Tagline />
        <p>
          Playing the built-in demo. Bring your own game with <kbd>--rom</kbd> above, or drop a .nes file onto the
          screen.
        </p>
      </div>
      <button type="button" className="first-run-dismiss" onClick={firstRun.dismiss} aria-label="Dismiss">
        ×
      </button>
    </div>
  )
}
