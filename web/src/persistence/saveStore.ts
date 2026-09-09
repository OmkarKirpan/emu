/**
 * ENG-61's persistence layer: one IndexedDB object store holding both
 * numbered save-state slots and the reserved `"sram"` slot, keyed by
 * `(romHash, slot)`.
 *
 * **Why IndexedDB and not `localStorage`** (ENG-61's own reasoning, restated
 * where it's implemented): it's asynchronous, so nothing here can block the
 * emulator Worker's tick loop; it stores binary directly, with no base64
 * inflation; and its quota scales with disk rather than sharing
 * `localStorage`'s ~5MB origin-wide ceiling across every ROM x slot pair.
 * A single state is a little over 20KB (see `savestate.zig`), so a handful
 * of ROMs would already be uncomfortable in the alternative.
 *
 * **Why `romHash` and not a filename**: a renamed ROM file still resolves to
 * its own saves, and two differently-named copies of one ROM share them. The
 * hash itself is computed in the core (`NesCore.romHash`), not here, so
 * exactly one definition of "which ROM is this" exists across Zig, the wasm
 * ABI and this database.
 *
 * This module is imported by the emulator Worker, not the main thread:
 * IndexedDB is available in both, and keeping it Worker-side means a save or
 * load never crosses a `postMessage` boundary carrying 20KB of state, and
 * never competes with React rendering. The main thread only ever sees
 * `SlotSummary` metadata.
 */

/** Numbered save-state slots offered in the UI. Four rather than an
 * unbounded list: the slot browser is a fixed grid, and a growable list
 * needs naming/renaming affordances this milestone doesn't call for. */
export const SAVE_SLOTS = [1, 2, 3, 4] as const

/** `"sram"` is reserved (ENG-61): auto-loaded on ROM load and auto-saved as
 * the cartridge's RAM changes, mirroring how a battery-backed cartridge
 * behaves, rather than being a slot the user picks. */
export const SRAM_SLOT = 'sram'

export type SaveSlot = (typeof SAVE_SLOTS)[number] | typeof SRAM_SLOT

/** What the main thread is told about a stored slot -- deliberately not the
 * bytes. The UI needs "is there something here, and how old is it"; shipping
 * 20KB per slot across `postMessage` to answer that would be silly. */
export interface SlotSummary {
  slot: SaveSlot
  /** `Date.now()` at the moment it was written. */
  savedAt: number
  bytes: number
}

interface SlotRecord extends SlotSummary {
  romHash: string
  data: Uint8Array
}

const DB_NAME = 'nes-emulator'
const DB_VERSION = 1
const STORE = 'slots'

let dbPromise: Promise<IDBDatabase> | null = null

/** Wraps an `IDBRequest` as a promise. IndexedDB predates promises and
 * every call here is a one-shot request, so this one adapter covers the
 * whole module. */
function request<T>(req: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    req.onsuccess = () => resolve(req.result)
    req.onerror = () => reject(req.error ?? new Error('IndexedDB request failed'))
  })
}

/** Opened lazily and memoized: the first save or load pays for the open,
 * and nothing pays for it in a session that never touches persistence. */
function open(): Promise<IDBDatabase> {
  dbPromise ??= new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, DB_VERSION)
    req.onupgradeneeded = () => {
      // A compound `keyPath` rather than a synthesized `"hash:slot"` string
      // key: it keeps both halves inspectable in devtools, and it makes
      // `listSlots`'s "every slot for this ROM" a bounded range query
      // instead of a full scan with string parsing.
      req.result.createObjectStore(STORE, { keyPath: ['romHash', 'slot'] })
    }
    req.onsuccess = () => resolve(req.result)
    req.onerror = () => reject(req.error ?? new Error('failed to open the save database'))
  })
  return dbPromise
}

async function transact<T>(mode: IDBTransactionMode, run: (store: IDBObjectStore) => Promise<T>): Promise<T> {
  const db = await open()
  const tx = db.transaction(STORE, mode)
  const result = await run(tx.objectStore(STORE))
  // Waiting for `complete` rather than resolving on the request means a
  // `putSlot` that resolves has genuinely been committed -- which is what
  // "SRAM survives a reload" depends on.
  if (mode === 'readwrite') {
    await new Promise<void>((resolve, reject) => {
      tx.oncomplete = () => resolve()
      tx.onerror = () => reject(tx.error ?? new Error('IndexedDB transaction failed'))
      tx.onabort = () => reject(tx.error ?? new Error('IndexedDB transaction aborted'))
    })
  }
  return result
}

export async function putSlot(romHash: string, slot: SaveSlot, data: Uint8Array): Promise<SlotSummary> {
  const record: SlotRecord = { romHash, slot, data, savedAt: Date.now(), bytes: data.length }
  await transact('readwrite', (store) => request(store.put(record)))
  return { slot, savedAt: record.savedAt, bytes: record.bytes }
}

export async function getSlot(romHash: string, slot: SaveSlot): Promise<Uint8Array | null> {
  const record = await transact('readonly', (store) => request<SlotRecord | undefined>(store.get([romHash, slot])))
  return record ? new Uint8Array(record.data) : null
}

export async function deleteSlot(romHash: string, slot: SaveSlot): Promise<void> {
  await transact('readwrite', (store) => request(store.delete([romHash, slot])))
}

/** Every slot stored for one ROM, metadata only, newest slot number first
 * left to the caller to order. Uses a key range over the compound key so a
 * database holding many ROMs' saves still only reads this one's. */
export async function listSlots(romHash: string): Promise<SlotSummary[]> {
  const records = await transact('readonly', (store) =>
    // The compound key sorts by `romHash` first, so every key for this ROM
    // lies between `[hash]` and `[hash, []]` -- `[]` sorts above every
    // number and string in IndexedDB's key ordering, making it the standard
    // upper bound for "any second component".
    request<SlotRecord[]>(store.getAll(IDBKeyRange.bound([romHash], [romHash, []]))),
  )
  return records.map(({ slot, savedAt, bytes }) => ({ slot, savedAt, bytes }))
}
