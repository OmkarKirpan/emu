import { useCallback, useEffect, useState } from 'react'
import type { DisplayFilterSettings } from '../emulator/displayFilter'
import { loadDisplayFilter, saveDisplayFilter } from './displayFilterStore'

/**
 * The display-filter setting: restored from `localStorage` on mount, sent
 * to the emulator Worker whenever it (or the Worker) changes, and written
 * back on every change.
 *
 * Held up in `EmulatorScreen` rather than inside `DisplaySettings`, because
 * the canvas needs it too -- see the `data-filter` attribute there.
 */
export function useDisplayFilter(
  worker: Worker | null,
): [DisplayFilterSettings, (next: DisplayFilterSettings) => void] {
  const [settings, setSettings] = useState(loadDisplayFilter)

  // Keyed on `worker` as well: a restored non-default setting has to reach
  // a freshly created Worker without anyone touching the controls.
  useEffect(() => {
    worker?.postMessage({ type: 'set-display-filter', settings })
  }, [worker, settings])

  const update = useCallback((next: DisplayFilterSettings) => {
    setSettings(next)
    saveDisplayFilter(next)
  }, [])

  return [settings, update]
}
