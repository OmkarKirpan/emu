import { useCallback, useEffect, useState } from 'react'
import { RESUME_SLOT, SAVE_SLOTS, SRAM_SLOT, type SaveSlot, type SlotSummary } from './persistence/saveStore'
import type { EmulatorWorkerOutbound } from './emulator/protocol'
import { formatWhen } from './formatWhen'

/**
 * ENG-76 (M8)'s save-state slot browser.
 *
 * This component holds no state bytes and talks to no database: the
 * emulator Worker owns both the wasm instance and IndexedDB (see
 * `persistence/saveStore.ts` for why), so everything here is a slot number
 * going out and a listing coming back. That is what keeps a 20KB save off
 * this thread entirely -- React never sees more than a timestamp and a byte
 * count per slot.
 *
 * The battery row is deliberately not a button pair. `"sram"` is a reserved
 * slot ENG-61 auto-loads on boot and auto-saves as the cartridge's RAM
 * changes; offering "save"/"load" for it would invite the user to fight the
 * mechanism that is already doing it. It is shown, not driven -- so "is my
 * progress actually being kept?" has a visible answer. The resume row below
 * it is the ENG-89 counterpart for the same reason: `"resume"` is written by
 * `useResumeAutosave.ts` (on `visibilitychange`/`pagehide`) and
 * `emulatorWorker.ts`'s periodic backstop, and auto-loaded on every ROM
 * adopt -- never something the numbered Save/Load/Delete controls should
 * touch, so it does not appear in `SAVE_SLOTS` at all.
 *
 * The ticket also names a settings panel. Nothing this milestone produced
 * belongs in one (the renderer override is a query parameter, audio is a
 * single gesture-gated button), so it is deliberately not built rather than
 * invented as an empty shell.
 */
interface SaveStatesProps {
  worker: Worker | null
  /** False until the ROM is actually running -- there is no machine to
   * snapshot before then, and the Worker would answer with a `'slot-error'`. */
  enabled: boolean
}

export function SaveStates({ worker, enabled }: SaveStatesProps) {
  const [slots, setSlots] = useState<SlotSummary[]>([])
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (!worker) return
    const handleMessage = (event: MessageEvent<EmulatorWorkerOutbound>) => {
      const message = event.data
      if (message.type === 'slots') {
        setSlots(message.slots)
        setError(null)
      } else if (message.type === 'slot-error') {
        setError(message.message)
      }
    }
    worker.addEventListener('message', handleMessage)
    // Asked for explicitly rather than assumed: this component can mount
    // after the Worker already published its listing on boot, and a
    // listener added afterwards would never have seen it.
    worker.postMessage({ type: 'list-states' })
    return () => worker.removeEventListener('message', handleMessage)
  }, [worker])

  const send = useCallback(
    (type: 'save-state' | 'load-state' | 'delete-state', slot: SaveSlot) => {
      worker?.postMessage({ type, slot })
    },
    [worker],
  )

  const battery = slots.find((s) => s.slot === SRAM_SLOT)
  const resume = slots.find((s) => s.slot === RESUME_SLOT)

  return (
    <section className="save-states" aria-label="Save states">
      <h2>Save states</h2>
      <ul className="slot-list">
        {SAVE_SLOTS.map((slot) => {
          const saved = slots.find((s) => s.slot === slot)
          return (
            <li key={slot} className="slot" data-slot={slot} data-occupied={saved ? 'yes' : 'no'}>
              <span className="slot-name">Slot {slot}</span>
              <span className="slot-when">{saved ? formatWhen(saved.savedAt) : 'empty'}</span>
              {/* Grouped rather than three loose grid children: below the
                  narrow breakpoint the row has to break between the labels
                  and the controls, and a wrapper is what lets the three of
                  them move to a second line together instead of the grid
                  shrinking each tap target to fit. */}
              <span className="slot-actions">
                <button type="button" onClick={() => send('save-state', slot)} disabled={!enabled}>
                  Save
                </button>
                <button type="button" onClick={() => send('load-state', slot)} disabled={!enabled || !saved}>
                  Load
                </button>
                <button
                  type="button"
                  className="slot-delete"
                  aria-label={`Delete slot ${slot}`}
                  onClick={() => send('delete-state', slot)}
                  disabled={!enabled || !saved}
                >
                  ×
                </button>
              </span>
            </li>
          )
        })}
      </ul>
      <p className="battery" data-saved={battery ? 'yes' : 'no'}>
        {/* Named "battery", not "SRAM": it is the cartridge behavior the
            user recognizes, and the acronym explains nothing to them. */}
        Battery save:{' '}
        {battery ? `kept automatically, last written ${formatWhen(battery.savedAt)}` : 'nothing written yet'}
      </p>
      <p className="resume-point" data-saved={resume ? 'yes' : 'no'}>
        {/* Read-only for the same reason the battery row is: ENG-89's
            resume point is auto-saved on hide/pagehide and auto-loaded on
            boot, not a slot the user picks. */}
        Resume point:{' '}
        {resume ? `kept automatically, last written ${formatWhen(resume.savedAt)}` : 'nothing written yet'}
      </p>
      {error && (
        <p className="slot-error" role="alert">
          {error}
        </p>
      )}
    </section>
  )
}
