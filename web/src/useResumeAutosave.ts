import { useEffect } from 'react'
import { RESUME_SLOT } from './persistence/saveStore'

/**
 * ENG-89's session-continuity autosave: writes the running game's exact
 * position into the reserved `RESUME_SLOT` the moment the tab is about to
 * stop being visible, so "close the tab, reopen it" means picking up
 * exactly where play stopped, not just "the right cartridge, from
 * power-on".
 *
 * **`visibilitychange` -> `hidden` is the primary trigger, not `pagehide`.**
 * It fires earlier (a tab switch, an app switch on mobile, and in practice
 * ahead of `pagehide` on an actual close or navigation too) and, critically,
 * does not race the page's own teardown the way `pagehide` can -- by the
 * time `pagehide` fires, `EmulatorScreen.tsx`'s Worker may already be on its
 * way out. `pagehide` is still wired up as a second, best-effort attempt for
 * the paths that skip straight to it without an intervening
 * `visibilitychange` (some mobile back-swipe gestures), on the explicit
 * understanding that it can still lose that race -- which is exactly why
 * `emulatorWorker.ts` also carries its own periodic backstop
 * (`scheduleResumeAutosave`) as the last line of defense against a session
 * that closes without either browser event landing in time.
 *
 * **Deliberately main-thread, and deliberately not tied to `scheduleLoop`'s
 * tick.** The other ENG-90 work pauses that loop the instant the tab hides;
 * an autosave that depended on the loop still advancing to notice its own
 * trigger would race the very thing it's reacting to. The `'save-state'`
 * message posted below reaches `emulatorWorker.ts`'s `saveToSlot` --
 * the exact same handler a manual Save-button click uses -- which runs
 * entirely off the arrival of that message, never off a tick.
 *
 * Lives in its own hook rather than inline in `EmulatorScreen.tsx`: ENG-90
 * owns that file's app bar, pause overlay and its own (differently-purposed)
 * `visibilitychange` listener, and a second, independent listener for a
 * second, independent reason is easiest to keep conflict-free -- and easiest
 * to reason about -- filed on its own. `RomLibrary.tsx` calls this rather
 * than `EmulatorScreen.tsx` itself, since it already receives `worker` and
 * an `enabled` flag for its own purposes.
 */
export function useResumeAutosave(worker: Worker | null, enabled: boolean): void {
  useEffect(() => {
    if (!worker || !enabled) return

    const save = () => worker.postMessage({ type: 'save-state', slot: RESUME_SLOT })
    const handleVisibility = () => {
      if (document.visibilityState === 'hidden') save()
    }

    document.addEventListener('visibilitychange', handleVisibility)
    window.addEventListener('pagehide', save)
    return () => {
      document.removeEventListener('visibilitychange', handleVisibility)
      window.removeEventListener('pagehide', save)
    }
  }, [worker, enabled])
}
