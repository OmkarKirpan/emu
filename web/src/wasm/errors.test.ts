import { describe, expect, it } from 'vitest'
import { RomLoadError, RomStatus } from './errors'

// `NesCore` itself wraps a real wasm module and is deliberately not
// unit-tested against a hand-maintained mock of `CoreExports` here -- a mock
// can drift silently from the real ABI in `core/src/wasm.zig` in a way a
// type-check alone wouldn't catch. It's covered by `e2e/emulator.spec.ts`
// instead, against the actual compiled module. `RomLoadError`'s message
// formatting is pure logic with no wasm dependency, so it belongs here --
// imported from `./errors` directly (not re-exported through `./core`) so
// this test needs no `?init` import, and therefore no compiled
// `nes_core.wasm`, to even resolve its module graph.
describe('RomLoadError', () => {
  it('describes InvalidHeader without needing the context number', () => {
    const err = new RomLoadError(RomStatus.InvalidHeader, 0)
    expect(err.message).toMatch(/not a valid iNES/i)
    expect(err.status).toBe(RomStatus.InvalidHeader)
  })

  it('folds the mapper id into the UnsupportedMapper message', () => {
    const err = new RomLoadError(RomStatus.UnsupportedMapper, 105)
    expect(err.message).toContain('105')
    expect(err.context).toBe(105)
  })

  it('folds the byte count into the TruncatedData message', () => {
    const err = new RomLoadError(RomStatus.TruncatedData, 12)
    expect(err.message).toContain('12')
  })

  it('folds the cap into the RomTooLarge message', () => {
    const err = new RomLoadError(RomStatus.RomTooLarge, 524288)
    expect(err.message).toContain('524288')
  })

  it('is a real Error, so a single instanceof Error check covers it', () => {
    const err = new RomLoadError(RomStatus.InvalidHeader, 0)
    expect(err).toBeInstanceOf(Error)
    expect(err.name).toBe('RomLoadError')
  })

  it('falls back to a generic, honest message for a status code it does not recognize', () => {
    // Simulates the Zig side adding a status this TS hasn't caught up to yet
    // -- see `RomLoadError.describe`'s `default` arm.
    const unknownStatus = -99 as RomStatus
    const err = new RomLoadError(unknownStatus, 0)
    expect(err.message).toContain('-99')
  })
})
