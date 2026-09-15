import { useCallback, useEffect, useState } from 'react'
import type { EmulatorWorkerOutbound, RomLibraryEntry } from './emulator/protocol'
import { formatWhen } from './formatWhen'
import { useResumeAutosave } from './useResumeAutosave'

/**
 * ENG-89's library surface: every ROM this browser has ever loaded, most
 * recently played first, with a one-click way to resume one or remove it.
 * Replaces "boot the vendored demo unconditionally" -- the demo is now the
 * placeholder shown *while* the library is empty (see the empty-state
 * branch below), not a hardcoded boot target `EmulatorScreen.tsx` reaches
 * for regardless of history.
 *
 * Holds no ROM bytes and talks to no database, for the same reason
 * `SaveStates.tsx` doesn't: the emulator Worker owns IndexedDB
 * (`persistence/saveStore.ts`), so everything here is a `romHash` going out
 * and a listing coming back over `postMessage`. That is what keeps a ROM
 * that can run to a few hundred KB off this thread entirely.
 *
 * Also owns wiring up `useResumeAutosave` (see that hook's own doc comment
 * for why it lives off `EmulatorScreen.tsx`'s own `visibilitychange`
 * listener, which ENG-90 owns for a different purpose): this component
 * already receives `worker` and `enabled` for its own listing, and the
 * autosave that keeps this library's resume points current is exactly the
 * kind of thing a library-scoped component should be responsible for.
 */
interface RomLibraryProps {
  worker: Worker | null
  /** False until the ROM is actually running -- mirrors `SaveStates`'
   * `enabled`: there's no point offering to resume a different cartridge
   * before this one has finished booting, and the autosave this component
   * also drives has nothing to save yet either. */
  enabled: boolean
}

/** The vendored demo's filename (see `EmulatorScreen.tsx`'s `demoRomUrl`
 * import), spelled out here rather than imported: this component has to
 * render its empty-library placeholder correctly even though it never
 * touches the actual asset, and pulling Vite's `?url` asset graph into a
 * metadata-only listing panel for one string would be backwards. */
const DEMO_ROM_NAME = 'sprite_input_demo.nes'

export function RomLibrary({ worker, enabled }: RomLibraryProps) {
  const [roms, setRoms] = useState<RomLibraryEntry[]>([])
  const [error, setError] = useState<string | null>(null)

  useResumeAutosave(worker, enabled)

  useEffect(() => {
    if (!worker) return
    const handleMessage = (event: MessageEvent<EmulatorWorkerOutbound>) => {
      const message = event.data
      if (message.type === 'library') {
        setRoms(message.roms)
        setError(null)
      } else if (message.type === 'library-error') {
        setError(message.message)
      }
    }
    worker.addEventListener('message', handleMessage)
    // Asked for explicitly, same reasoning as `SaveStates`' `'list-states'`:
    // the Worker may have already published its boot-time listing before
    // this component mounted, and a listener added afterwards would have
    // missed it.
    worker.postMessage({ type: 'list-library' })
    return () => worker.removeEventListener('message', handleMessage)
  }, [worker])

  const resume = useCallback(
    (romHash: string) => worker?.postMessage({ type: 'resume-rom', romHash }),
    [worker],
  )
  const remove = useCallback(
    (romHash: string) => worker?.postMessage({ type: 'remove-rom', romHash }),
    [worker],
  )

  return (
    <section className="rom-library" aria-label="ROM library">
      <h2>Library</h2>
      {roms.length === 0 ? (
        <p className="rom-library-empty">
          {DEMO_ROM_NAME} <span className="rom-library-tag">built-in</span> -- pick a ROM above to start a library.
        </p>
      ) : (
        <ul className="rom-library-list">
          {roms.map((rom) => (
            <li key={rom.romHash} className="rom-library-item">
              <span className="rom-library-name">{rom.name}</span>
              <span className="rom-library-when">{formatWhen(rom.lastPlayedAt)}</span>
              <span className="rom-library-actions">
                <button type="button" disabled={!enabled} onClick={() => resume(rom.romHash)}>
                  Resume
                </button>
                <button
                  type="button"
                  className="rom-library-remove"
                  aria-label={`Remove ${rom.name}`}
                  onClick={() => remove(rom.romHash)}
                >
                  ×
                </button>
              </span>
            </li>
          ))}
        </ul>
      )}
      {error && (
        <p className="rom-library-error" role="alert">
          {error}
        </p>
      )}
    </section>
  )
}
