/**
 * Display-filter persistence. Main-thread-only, for the same reason and in
 * the same shape as `audio/volumeStore.ts`: a few small, ROM-independent
 * values, read once on mount and written on every change, which is what
 * `localStorage`'s synchronous API suits (IndexedDB is for the per-ROM
 * blobs `persistence/saveStore.ts` holds).
 *
 * What counts as a valid value is `sanitizeDisplayFilter`'s call, not this
 * file's -- it lives beside the type in `emulator/displayFilter.ts`.
 */
import { DEFAULT_DISPLAY_FILTER, sanitizeDisplayFilter, type DisplayFilterSettings } from '../emulator/displayFilter'

const STORAGE_KEY = 'emu.display.filter'

/** Reads the persisted filter, falling back to `DEFAULT_DISPLAY_FILTER` for
 * a first visit, an unreadable value, or a `localStorage` that throws
 * outright (blocked site data, some in-app browser previews). */
export function loadDisplayFilter(): DisplayFilterSettings {
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    return sanitizeDisplayFilter(raw ? JSON.parse(raw) : undefined)
  } catch {
    return sanitizeDisplayFilter(DEFAULT_DISPLAY_FILTER)
  }
}

/** A failure here costs the setting surviving a reload, never the running
 * session -- the caller's state, and the Worker, already have the new value. */
export function saveDisplayFilter(settings: DisplayFilterSettings): void {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(settings))
  } catch {
    // Blocked storage -- nothing to recover, and nothing the user can act
    // on from here.
  }
}
