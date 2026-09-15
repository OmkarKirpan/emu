import { describe, expect, it } from 'vitest'
import { MAX_REWIND_SNAPSHOTS, RewindRing } from './rewindRing'

/** A distinct, easily-recognizable "blob" for each capture index, so a test
 * can assert *which* one came back rather than merely that something did. */
function blob(n: number): Uint8Array {
  return new Uint8Array([n])
}

describe('RewindRing', () => {
  it('pops the most recent capture first', () => {
    const ring = new RewindRing(10)
    ring.push(blob(1))
    ring.push(blob(2))
    ring.push(blob(3))
    expect(ring.pop()).toEqual(blob(3))
    expect(ring.pop()).toEqual(blob(2))
    expect(ring.pop()).toEqual(blob(1))
  })

  it('returns undefined once empty, without underflowing', () => {
    const ring = new RewindRing(10)
    expect(ring.pop()).toBeUndefined()
    ring.push(blob(1))
    ring.pop()
    expect(ring.pop()).toBeUndefined()
  })

  it('evicts the oldest capture once the cap is exceeded -- fixed memory budget', () => {
    const ring = new RewindRing(3)
    ring.push(blob(1))
    ring.push(blob(2))
    ring.push(blob(3))
    ring.push(blob(4)) // evicts blob(1)
    expect(ring.length).toBe(3)
    expect(ring.pop()).toEqual(blob(4))
    expect(ring.pop()).toEqual(blob(3))
    expect(ring.pop()).toEqual(blob(2))
    expect(ring.pop()).toBeUndefined() // blob(1) is gone -- never grows past the cap
  })

  it('never grows past its cap no matter how many captures arrive', () => {
    const ring = new RewindRing(5)
    for (let i = 0; i < 1000; i++) ring.push(blob(i))
    expect(ring.length).toBe(5)
  })

  it('clear drops every capture -- ENG-91: cleared per-cartridge on a ROM swap', () => {
    const ring = new RewindRing(10)
    ring.push(blob(1))
    ring.push(blob(2))
    ring.clear()
    expect(ring.length).toBe(0)
    expect(ring.pop()).toBeUndefined()
  })

  it('defaults to a budget of roughly 60s of history at the ~6Hz capture cadence', () => {
    // ~360 at 60.0988fps / 10 -- see the module comment's derivation. Not
    // pinned to an exact number here (that would just restate the formula),
    // but bounded to the ballpark the ticket itself gives ("60s of history
    // is ~7MB").
    expect(MAX_REWIND_SNAPSHOTS).toBeGreaterThan(300)
    expect(MAX_REWIND_SNAPSHOTS).toBeLessThan(420)
  })
})
