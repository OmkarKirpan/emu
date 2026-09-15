import { useCallback, useEffect, useState } from 'react'
import type { EmulatorWorkerOutbound } from './emulator/protocol'

/**
 * ENG-93's "first run" definition. A returning visitor resumes straight into
 * their game (ENG-89's library, or just the demo they've already seen) and
 * must not be greeted with an intro every time -- so this is a *dismissed*
 * flag, persisted once and read back on every mount, not a per-session
 * banner that would reappear on every reload.
 *
 * What retires it, deliberately wider than an explicit close click:
 *   - the dismiss button on `FirstRun.tsx`'s banner, obviously;
 *   - a `'rom-loaded'` success -- the visitor just did the one thing the
 *     banner exists to teach ("bring your own ROM"), so it has nothing left
 *     to say;
 *   - a `'boot-rom'` message -- ENG-89's boot-time library resume. Nobody
 *     picked a file *this* session, but a library entry existing at all
 *     means this browser has been here before, which is a stronger, more
 *     durable signal than any flag this code could have written itself
 *     (e.g. a build that shipped before this flag existed, or storage
 *     cleared by hand but IndexedDB left alone).
 * A bare `'library'` listing arriving non-empty is *not* included: that
 * message is requested by `RomLibrary.tsx` on every mount regardless of
 * whether anything is enabled yet, so treating it as a dismiss signal would
 * fire before the boot sequence even resolves which ROM is playing.
 *
 * `localStorage` access is wrapped in try/catch throughout, per ENG-93's own
 * requirement -- same posture as `audio/volumeStore.ts`'s
 * `loadVolumeSettings`/`saveVolumeSettings`: blocked storage costs the flag
 * surviving reload, never a crash.
 */
const STORAGE_KEY = 'emu.firstRun.dismissed'

function readDismissed(): boolean {
  try {
    return localStorage.getItem(STORAGE_KEY) === 'true'
  } catch {
    return false
  }
}

function writeDismissed(): void {
  try {
    localStorage.setItem(STORAGE_KEY, 'true')
  } catch {
    // Blocked storage -- the banner just reappears next visit, which is a
    // fallback this hook already has to support (a first-ever visit looks
    // identical from here).
  }
}

export interface FirstRun {
  /** True until dismissed, one way or another. Never flips back to `true`. */
  active: boolean
  dismiss: () => void
}

export function useFirstRun(worker: Worker | null): FirstRun {
  const [dismissed, setDismissed] = useState(readDismissed)

  const dismiss = useCallback(() => {
    writeDismissed()
    setDismissed(true)
  }, [])

  useEffect(() => {
    if (!worker || dismissed) return
    const handleMessage = (event: MessageEvent<EmulatorWorkerOutbound>) => {
      const message = event.data
      if ((message.type === 'rom-loaded' && message.ok) || message.type === 'boot-rom') {
        dismiss()
      }
    }
    worker.addEventListener('message', handleMessage)
    return () => worker.removeEventListener('message', handleMessage)
  }, [worker, dismissed, dismiss])

  return { active: !dismissed, dismiss }
}
