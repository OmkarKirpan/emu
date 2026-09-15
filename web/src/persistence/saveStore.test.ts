// `fake-indexeddb/auto` installs a real, spec-compliant IndexedDB
// implementation onto `globalThis` -- jsdom ships none. It is the actual
// IndexedDB algorithms (key ordering, compound keys, transaction
// lifecycles), not a stub with `get`/`put` methods, which is what makes it
// worth a devDependency here: the two things most worth testing in this
// module are the compound-key range query and the "resolved means
// committed" transaction handling, and a hand-written stub would simply
// agree with whatever this file asserted.
import 'fake-indexeddb/auto'
import { beforeEach, describe, expect, it } from 'vitest'
import { deleteRom, deleteSlot, getRom, getSlot, listRoms, listSlots, putRom, putSlot, SRAM_SLOT, touchRom } from './saveStore'

const ROM_A = 'a'.repeat(64)
const ROM_B = 'b'.repeat(64)

function bytes(...values: number[]): Uint8Array {
  return new Uint8Array(values)
}

/**
 * ENG-89's migration case, run before anything else in this file: every
 * other `it` below reaches the module through its own exported functions,
 * which memoize `open()`'s promise (and, with it, whichever database
 * version first opened) for the rest of the process. This one instead
 * builds the exact database ENG-61 shipped *by hand*, with a raw
 * `indexedDB.open` at version 1 -- a stand-in for a real returning user's
 * browser -- so that the module's own `open()` is what has to perform a
 * genuine v1 -> v2 upgrade the first time anything here calls it, rather
 * than creating a fresh v2 database that happens to already have both
 * stores. Declared first in the file specifically so it runs first (Vitest
 * executes a file's tests in declaration order by default): once any other
 * test's `beforeEach` opens the module at v2, there is no way back to v1 to
 * demonstrate the upgrade against.
 */
describe('migrating an existing v1 database', () => {
  const LEGACY_ROM = 'c'.repeat(64)

  it('keeps existing slot records intact and adds the library store', async () => {
    await new Promise<void>((resolve, reject) => {
      const req = indexedDB.open('nes-emulator', 1)
      req.onupgradeneeded = () => {
        // Exactly what v1's `open()` did: one store, one compound key.
        req.result.createObjectStore('slots', { keyPath: ['romHash', 'slot'] })
      }
      req.onsuccess = () => {
        const db = req.result
        const tx = db.transaction('slots', 'readwrite')
        tx.objectStore('slots').put({ romHash: LEGACY_ROM, slot: 1, data: bytes(7, 7), savedAt: 111, bytes: 2 })
        tx.oncomplete = () => {
          // Must close before the module's own `open()` can run an upgrade
          // transaction against this same database -- an open connection
          // otherwise blocks a version change indefinitely.
          db.close()
          resolve()
        }
        tx.onerror = () => reject(tx.error)
      }
      req.onerror = () => reject(req.error)
    })

    // The first call into the module for this test file: this is what
    // actually drives `open()`'s `onupgradeneeded` through the v1 -> v2
    // path, against the hand-built database above rather than a fresh one.
    expect(await listSlots(LEGACY_ROM)).toEqual([{ slot: 1, savedAt: 111, bytes: 2 }])
    expect(await getSlot(LEGACY_ROM, 1)).toEqual(bytes(7, 7))

    // And the new store the upgrade added is genuinely present and usable,
    // not merely absent-but-not-crashing.
    expect(await listRoms()).toEqual([])
    await putRom(LEGACY_ROM, 'legacy.nes', bytes(1, 2, 3))
    expect(await getRom(LEGACY_ROM)).toEqual(bytes(1, 2, 3))
    await deleteRom(LEGACY_ROM) // leaves the shared database clean for every test after this one
  })
})

describe('saveStore', () => {
  beforeEach(async () => {
    // The module memoizes its `open()` promise, so the database has to be
    // reset rather than reopened -- deleting it leaves the memoized handle
    // pointing at a deleted database. Clearing the records instead keeps
    // that handle valid and each test isolated.
    for (const romHash of [ROM_A, ROM_B]) {
      for (const summary of await listSlots(romHash)) await deleteSlot(romHash, summary.slot)
      await deleteRom(romHash)
    }
  })

  it(`round-trips a slot's bytes`, async () => {
    await putSlot(ROM_A, 1, bytes(1, 2, 3))
    expect(await getSlot(ROM_A, 1)).toEqual(bytes(1, 2, 3))
  })

  it('returns null for a slot that was never written', async () => {
    // The Worker turns this into a "Slot 2 is empty." message rather than a
    // silent no-op, so the distinction from a stored empty array matters.
    expect(await getSlot(ROM_A, 2)).toBeNull()
  })

  it('overwrites a slot rather than accumulating records', async () => {
    await putSlot(ROM_A, 1, bytes(1))
    await putSlot(ROM_A, 1, bytes(9, 9))
    expect(await getSlot(ROM_A, 1)).toEqual(bytes(9, 9))
    expect(await listSlots(ROM_A)).toHaveLength(1)
  })

  it('keeps different ROMs\' saves apart, even in the same slot number', async () => {
    // The whole reason the key is `(romHash, slot)` and not `slot`: two
    // cartridges must not share slot 1.
    await putSlot(ROM_A, 1, bytes(0xaa))
    await putSlot(ROM_B, 1, bytes(0xbb))
    expect(await getSlot(ROM_A, 1)).toEqual(bytes(0xaa))
    expect(await getSlot(ROM_B, 1)).toEqual(bytes(0xbb))
  })

  it('lists only the requested ROM\'s slots', async () => {
    await putSlot(ROM_A, 1, bytes(1))
    await putSlot(ROM_A, 3, bytes(1, 2))
    await putSlot(ROM_B, 1, bytes(1))

    const listed = await listSlots(ROM_A)
    expect(listed.map((s) => s.slot).sort()).toEqual([1, 3])
    expect(listed.find((s) => s.slot === 3)?.bytes).toBe(2)
  })

  it('lists the reserved sram slot alongside numbered ones', async () => {
    // A string slot key sorts differently from a number in IndexedDB's key
    // ordering, so the range query in `listSlots` has to cover both -- this
    // is the case that catches an upper bound written as `[romHash, 999]`.
    await putSlot(ROM_A, 1, bytes(1))
    await putSlot(ROM_A, SRAM_SLOT, bytes(2))
    expect((await listSlots(ROM_A)).map((s) => s.slot).sort()).toEqual([1, SRAM_SLOT])
  })

  it('stamps a save with the time it was written', async () => {
    const before = Date.now()
    const summary = await putSlot(ROM_A, 1, bytes(1))
    expect(summary.savedAt).toBeGreaterThanOrEqual(before)
    expect(summary.bytes).toBe(1)
    expect((await listSlots(ROM_A))[0].savedAt).toBe(summary.savedAt)
  })

  it('deletes a slot without disturbing its neighbours', async () => {
    await putSlot(ROM_A, 1, bytes(1))
    await putSlot(ROM_A, 2, bytes(2))
    await deleteSlot(ROM_A, 1)
    expect(await getSlot(ROM_A, 1)).toBeNull()
    expect(await getSlot(ROM_A, 2)).toEqual(bytes(2))
  })

  it('deleting a slot that does not exist is not an error', async () => {
    // The UI withholds the delete button for an empty slot, but two tabs
    // open on the same ROM can still race each other to the same record.
    await expect(deleteSlot(ROM_A, 4)).resolves.toBeUndefined()
  })

  it('hands back an independent copy, not a live view of stored bytes', async () => {
    // `loadState` is handed this array straight from `getSlot`; a caller
    // mutating it must not corrupt what a later read returns.
    await putSlot(ROM_A, 1, bytes(1, 2, 3))
    const first = await getSlot(ROM_A, 1)
    first![0] = 0xff
    expect(await getSlot(ROM_A, 1)).toEqual(bytes(1, 2, 3))
  })
})

describe('the ROM library (ENG-89)', () => {
  beforeEach(async () => {
    for (const romHash of [ROM_A, ROM_B]) await deleteRom(romHash)
  })

  it('round-trips a ROM\'s bytes and metadata', async () => {
    const entry = await putRom(ROM_A, 'game.nes', bytes(1, 2, 3))
    expect(entry).toMatchObject({ romHash: ROM_A, name: 'game.nes', size: 3 })
    expect(await getRom(ROM_A)).toEqual(bytes(1, 2, 3))
  })

  it('returns null for a ROM never stored', async () => {
    expect(await getRom(ROM_A)).toBeNull()
  })

  it('re-storing the same ROM overwrites it rather than accumulating records', async () => {
    await putRom(ROM_A, 'game.nes', bytes(1))
    await putRom(ROM_A, 'game.nes', bytes(9, 9))
    expect(await getRom(ROM_A)).toEqual(bytes(9, 9))
    expect(await listRoms()).toHaveLength(1)
  })

  it('lists every stored ROM', async () => {
    await putRom(ROM_A, 'a.nes', bytes(1))
    await putRom(ROM_B, 'b.nes', bytes(2))
    expect((await listRoms()).map((r) => r.romHash).sort()).toEqual([ROM_A, ROM_B].sort())
  })

  it('bumps lastPlayedAt without touching the stored bytes', async () => {
    const first = await putRom(ROM_A, 'game.nes', bytes(1, 2, 3))
    await touchRom(ROM_A)
    const entries = await listRoms()
    expect(entries[0].lastPlayedAt).toBeGreaterThanOrEqual(first.lastPlayedAt)
    // The whole point of `touchRom` over `putRom`: a boot-time resume must
    // not pay to rewrite bytes it just read back out of this same store.
    expect(await getRom(ROM_A)).toEqual(bytes(1, 2, 3))
  })

  it('touching a ROM that was never stored is not an error', async () => {
    // A tab that removed an entry mid-swap in another tab is the real case
    // this covers -- see `resumeRom`'s own comment in `emulatorWorker.ts`.
    await expect(touchRom(ROM_A)).resolves.toBeUndefined()
  })

  it('removes a ROM from the library without disturbing its save-state slots', async () => {
    await putRom(ROM_A, 'game.nes', bytes(1, 2, 3))
    await putSlot(ROM_A, 1, bytes(9))
    await deleteRom(ROM_A)
    expect(await getRom(ROM_A)).toBeNull()
    // Removal is "stop offering to resume this", not "forget this cartridge
    // ever existed" -- see `deleteRom`'s own comment.
    expect(await getSlot(ROM_A, 1)).toEqual(bytes(9))
    await deleteSlot(ROM_A, 1)
  })

  it('deleting a ROM that was never stored is not an error', async () => {
    await expect(deleteRom(ROM_A)).resolves.toBeUndefined()
  })
})
