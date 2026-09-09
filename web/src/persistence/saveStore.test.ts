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
import { deleteSlot, getSlot, listSlots, putSlot, SRAM_SLOT } from './saveStore'

const ROM_A = 'a'.repeat(64)
const ROM_B = 'b'.repeat(64)

function bytes(...values: number[]): Uint8Array {
  return new Uint8Array(values)
}

describe('saveStore', () => {
  beforeEach(async () => {
    // The module memoizes its `open()` promise, so the database has to be
    // reset rather than reopened -- deleting it leaves the memoized handle
    // pointing at a deleted database. Clearing the records instead keeps
    // that handle valid and each test isolated.
    for (const romHash of [ROM_A, ROM_B]) {
      for (const summary of await listSlots(romHash)) await deleteSlot(romHash, summary.slot)
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
