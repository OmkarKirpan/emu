/**
 * ENG-61's persistence layer: one IndexedDB database holding both the
 * numbered/reserved save-state store (`slots`, keyed by `(romHash, slot)`)
 * and, as of ENG-89, a second object store (`romLibrary`, keyed by
 * `romHash`) that holds the ROM bytes themselves.
 *
 * **Why IndexedDB and not `localStorage`** (ENG-61's own reasoning, restated
 * where it's implemented): it's asynchronous, so nothing here can block the
 * emulator Worker's tick loop; it stores binary directly, with no base64
 * inflation; and its quota scales with disk rather than sharing
 * `localStorage`'s ~5MB origin-wide ceiling across every ROM x slot pair.
 * A single state is a little over 20KB (see `savestate.zig`), and a ROM
 * itself can run to a few hundred KB, so a handful of cartridges would
 * already be uncomfortable in the alternative.
 *
 * **Why `romHash` and not a filename**: a renamed ROM file still resolves to
 * its own saves, and two differently-named copies of one ROM share them. The
 * hash itself is computed in the core (`NesCore.romHash`), not here, so
 * exactly one definition of "which ROM is this" exists across Zig, the wasm
 * ABI and this database -- and it's what lets the library and the save-state
 * store agree on identity without either referencing the other.
 *
 * **Why a second store and not a second database**: one `indexedDB.open`
 * call, one upgrade transaction, and (the part that actually matters) one
 * place where "does an existing v1 database survive this change" has to be
 * gotten right -- see `open`'s `onupgradeneeded` and `saveStore.test.ts`'s
 * migration case. A second database would need its own version and its own
 * open lifecycle for no benefit: nothing here ever needs a transaction that
 * spans both stores.
 *
 * This module is imported by the emulator Worker, not the main thread:
 * IndexedDB is available in both, and keeping it Worker-side means a save,
 * load or ROM byte round-trip never crosses a `postMessage` boundary
 * carrying tens or hundreds of KB, and never competes with React rendering.
 * The main thread only ever sees `SlotSummary`/`RomLibraryEntry` metadata.
 */

/** Numbered save-state slots offered in the UI. Four rather than an
 * unbounded list: the slot browser is a fixed grid, and a growable list
 * needs naming/renaming affordances this milestone doesn't call for. */
export const SAVE_SLOTS = [1, 2, 3, 4] as const

/** `"sram"` is reserved (ENG-61): auto-loaded on ROM load and auto-saved as
 * the cartridge's RAM changes, mirroring how a battery-backed cartridge
 * behaves, rather than being a slot the user picks. */
export const SRAM_SLOT = 'sram'

/** `"resume"` is reserved (ENG-89), the same way `SRAM_SLOT` is: a full
 * save-state auto-written when the tab is hidden (see `emulatorWorker.ts`'s
 * `saveToSlot`/`scheduleResumeAutosave` and `useResumeAutosave.ts`) and
 * auto-loaded the moment its cartridge is adopted (`adoptRom`), so reopening
 * the tab lands exactly where the session left off rather than merely
 * re-booting the right game. It lives in the same `slots` store and under
 * the same `(romHash, slot)` key as everything else here -- it is a
 * save-state like any other, just one the machine drives instead of the
 * user -- which is also why it rides `listSlots`/`putSlot`/`getSlot`
 * unmodified instead of needing its own accessors.  */
export const RESUME_SLOT = 'resume'

export type SaveSlot = (typeof SAVE_SLOTS)[number] | typeof SRAM_SLOT | typeof RESUME_SLOT

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

/** What the main thread (`RomLibrary.tsx`) is told about a stored ROM --
 * deliberately not the bytes, for the same reason `SlotSummary` withholds
 * save-state bytes: the UI needs "what's in the library, and when was it
 * last played", not a few hundred KB round-tripped over `postMessage` to
 * answer that. */
export interface RomLibraryEntry {
  romHash: string
  name: string
  lastPlayedAt: number
  size: number
}

interface RomLibraryRecord extends RomLibraryEntry {
  data: Uint8Array
}

const DB_NAME = 'nes-emulator'
/** Bumped from 1 to 2 by ENG-89 to add `LIBRARY_STORE`. See `open`'s
 * `onupgradeneeded` for the migration that keeps this safe for a browser
 * that already has a v1 database with real save-state/SRAM records in it. */
const DB_VERSION = 2
const STORE = 'slots'
const LIBRARY_STORE = 'romLibrary'

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
    // `event.oldVersion` is what makes this a migration rather than a
    // from-scratch schema: a browser with no database yet reports 0 and
    // gets both stores, while a browser holding a real ENG-61 v1 database
    // reports 1 and gets *only* `LIBRARY_STORE` added -- `STORE` and every
    // record in it are left completely alone, because `createObjectStore`
    // is never called on a name that already exists. `saveStore.test.ts`
    // exercises exactly this path against a v1 database seeded by hand.
    req.onupgradeneeded = (event) => {
      const db = req.result
      if (event.oldVersion < 1) {
        // A compound `keyPath` rather than a synthesized `"hash:slot"`
        // string key: it keeps both halves inspectable in devtools, and it
        // makes `listSlots`'s "every slot for this ROM" a bounded range
        // query instead of a full scan with string parsing.
        db.createObjectStore(STORE, { keyPath: ['romHash', 'slot'] })
      }
      if (event.oldVersion < 2) {
        // A plain (non-compound) key: unlike a save-state, a ROM has no
        // "which slot" axis, just "which cartridge".
        db.createObjectStore(LIBRARY_STORE, { keyPath: 'romHash' })
      }
    }
    req.onsuccess = () => resolve(req.result)
    req.onerror = () => reject(req.error ?? new Error('failed to open the save database'))
  })
  return dbPromise
}

async function transact<T>(
  storeName: string,
  mode: IDBTransactionMode,
  run: (store: IDBObjectStore) => Promise<T>,
): Promise<T> {
  const db = await open()
  const tx = db.transaction(storeName, mode)
  const result = await run(tx.objectStore(storeName))
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
  await transact(STORE, 'readwrite', (store) => request(store.put(record)))
  return { slot, savedAt: record.savedAt, bytes: record.bytes }
}

export async function getSlot(romHash: string, slot: SaveSlot): Promise<Uint8Array | null> {
  const record = await transact(STORE, 'readonly', (store) =>
    request<SlotRecord | undefined>(store.get([romHash, slot])),
  )
  return record ? new Uint8Array(record.data) : null
}

export async function deleteSlot(romHash: string, slot: SaveSlot): Promise<void> {
  await transact(STORE, 'readwrite', (store) => request(store.delete([romHash, slot])))
}

/** Every slot stored for one ROM, metadata only, newest slot number first
 * left to the caller to order. Uses a key range over the compound key so a
 * database holding many ROMs' saves still only reads this one's. */
export async function listSlots(romHash: string): Promise<SlotSummary[]> {
  const records = await transact(STORE, 'readonly', (store) =>
    // The compound key sorts by `romHash` first, so every key for this ROM
    // lies between `[hash]` and `[hash, []]` -- `[]` sorts above every
    // number and string in IndexedDB's key ordering, making it the standard
    // upper bound for "any second component".
    request<SlotRecord[]>(store.getAll(IDBKeyRange.bound([romHash], [romHash, []]))),
  )
  return records.map(({ slot, savedAt, bytes }) => ({ slot, savedAt, bytes }))
}

// ---------------------------------------------- ROM library (ENG-89)

/** Stores (or re-stores) a ROM's bytes under its own hash, stamping
 * `lastPlayedAt` to now. Called for every `'load-rom'` pick -- including
 * re-picking a ROM already in the library -- so "last played" always means
 * what it says, and a duplicate write of identical bytes is harmless. */
export async function putRom(romHash: string, name: string, data: Uint8Array): Promise<RomLibraryEntry> {
  const record: RomLibraryRecord = { romHash, name, data, lastPlayedAt: Date.now(), size: data.length }
  await transact(LIBRARY_STORE, 'readwrite', (store) => request(store.put(record)))
  return { romHash, name, lastPlayedAt: record.lastPlayedAt, size: record.size }
}

/** Bumps `lastPlayedAt` without rewriting the stored bytes -- used when the
 * ROM being adopted came *from* the library (a boot-time resume, or an
 * explicit `'resume-rom'`) rather than a fresh file pick, so replaying a
 * game already on disk here doesn't cost a redundant write of its own
 * bytes back to itself. A no-op if the entry is somehow gone (e.g. removed
 * from another tab mid-swap) -- there is nothing to bump. */
export async function touchRom(romHash: string): Promise<void> {
  await transact(LIBRARY_STORE, 'readwrite', async (store) => {
    const record = await request<RomLibraryRecord | undefined>(store.get(romHash))
    if (!record) return
    record.lastPlayedAt = Date.now()
    await request(store.put(record))
  })
}

export async function getRom(romHash: string): Promise<Uint8Array | null> {
  const record = await transact(LIBRARY_STORE, 'readonly', (store) =>
    request<RomLibraryRecord | undefined>(store.get(romHash)),
  )
  return record ? new Uint8Array(record.data) : null
}

/** Every ROM ever loaded, metadata only -- ordering (most recently played
 * first) is the caller's job, same division of labour as `listSlots`. */
export async function listRoms(): Promise<RomLibraryEntry[]> {
  const records = await transact(LIBRARY_STORE, 'readonly', (store) => request<RomLibraryRecord[]>(store.getAll()))
  return records.map(({ romHash, name, lastPlayedAt, size }) => ({ romHash, name, lastPlayedAt, size }))
}

/** Removes a ROM from the library. Deliberately leaves its save-state slots
 * (numbered, SRAM, resume) untouched: they are keyed on the same `romHash`,
 * so re-adding the identical file later (or picking it again by hand) finds
 * its saves waiting exactly as `listSlots` already guarantees across a
 * runtime ROM swap -- "removed from the library" reads as "stop offering to
 * resume this", not "forget this cartridge ever existed". */
export async function deleteRom(romHash: string): Promise<void> {
  await transact(LIBRARY_STORE, 'readwrite', (store) => request(store.delete(romHash)))
}
