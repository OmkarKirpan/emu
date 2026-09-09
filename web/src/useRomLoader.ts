import { useCallback, useEffect, useRef, useState, type DragEvent } from 'react'
import type { EmulatorWorkerOutbound } from './emulator/protocol'

/**
 * ENG-77's runtime ROM loading: turns a picked or dropped `File` into a
 * `'load-rom'` message, and tracks what came back.
 *
 * **The chosen file never leaves this tab.** It goes `File` ->
 * `ArrayBuffer` -> Worker -> wasm and is then dropped: never fetched from
 * the server, never written anywhere, never persisted across a reload.
 * That is precisely what lets a real commercial game reach the emulator
 * without the repo's ROM policy being involved at all -- the file is chosen
 * at runtime by the person running it. See `docs/research/test-rom-
 * licensing.md` (ENG-59) for why the distinction matters here.
 *
 * Split out of `EmulatorScreen.tsx` rather than added to it: that file
 * already carries the session-caching and StrictMode-remount reasoning,
 * and file handling has nothing to do with either. Split out of
 * `RomPicker.tsx` in turn because a `.tsx` that exports anything besides
 * components breaks React Fast Refresh for the whole module.
 */

/** The last load attempt, successful or not. `error` absent means the ROM
 * is what's currently playing. */
export interface RomLoad {
  name: string
  error?: string
}

/** What `useRomLoader` hands back. `dropHandlers` is spread onto whatever
 * element should accept a dragged file (the canvas wrapper), while
 * `loadFile` is what `RomPicker`'s `<input>` calls -- one loading path,
 * two ways to reach it. */
interface RomLoader {
  romLoad: RomLoad | null
  dismiss: () => void
  loadFile: (file: File) => void
  dragging: boolean
  dropHandlers: {
    onDragOver: (event: DragEvent) => void
    onDragLeave: () => void
    onDrop: (event: DragEvent) => void
  }
}

function isRomFilename(name: string): boolean {
  return name.toLowerCase().endsWith('.nes')
}

export function useRomLoader(worker: Worker | null): RomLoader {
  const [romLoad, setRomLoad] = useState<RomLoad | null>(null)
  const [dragging, setDragging] = useState(false)
  /** The filename of the load currently in flight. A ref, not state: it's
   * correlation data for the Worker's reply, not something rendered, and
   * only one load can be outstanding in practice (the reply arrives within
   * a frame of the post). */
  const pendingName = useRef<string | null>(null)

  // Its own listener rather than a branch in `EmulatorScreen`'s handler:
  // `addEventListener` composes, and this keeps every part of ROM loading
  // -- the post, the reply, the state it produces -- in one file.
  useEffect(() => {
    if (!worker) return
    const handleMessage = (event: MessageEvent<EmulatorWorkerOutbound>) => {
      const message = event.data
      if (message.type !== 'rom-loaded') return
      const name = pendingName.current ?? ''
      setRomLoad(message.ok ? { name } : { name, error: message.message })
    }
    worker.addEventListener('message', handleMessage)
    return () => worker.removeEventListener('message', handleMessage)
  }, [worker])

  const loadFile = useCallback(
    (file: File) => {
      if (!worker) return
      if (!isRomFilename(file.name)) {
        // Rejected here rather than in the core: the core would report it
        // as `InvalidHeader`, which is true but says nothing about the
        // actual mistake (dropping a screenshot on the canvas).
        setRomLoad({ name: file.name, error: 'Not a .nes file.' })
        return
      }
      pendingName.current = file.name
      void (async () => {
        const romBytes = await file.arrayBuffer()
        // Transferred, not copied -- a ROM is up to a few hundred KB and
        // this side has no further use for the bytes.
        worker.postMessage({ type: 'load-rom', romBytes }, [romBytes])
      })()
    },
    [worker],
  )

  const dropHandlers = {
    // `preventDefault` on *both*: without it on dragover the drop event
    // never fires at all, and without it on drop the browser navigates
    // away to the dropped file.
    onDragOver: (event: DragEvent) => {
      event.preventDefault()
      setDragging(true)
    },
    onDragLeave: () => setDragging(false),
    onDrop: (event: DragEvent) => {
      event.preventDefault()
      setDragging(false)
      const file = event.dataTransfer.files[0]
      if (file) loadFile(file)
    },
  }

  return { romLoad, dismiss: () => setRomLoad(null), loadFile, dragging, dropHandlers }
}

