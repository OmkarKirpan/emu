import { describe, expect, it } from 'vitest'
import { RomLoadError, RomStatus, SaveStateError, StateStatus } from './errors'

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

describe('SaveStateError', () => {
  it('names the mapper the state was made on, not the one loaded', () => {
    // The useful half of the mismatch: the host can already see which
    // cartridge it loaded, so the state's own claim is the new information.
    const err = new SaveStateError(StateStatus.MapperMismatch, 4)
    expect(err.message).toContain('4')
    expect(err.context).toBe(4)
  })

  it('describes a foreign-ROM state without needing a context number', () => {
    const err = new SaveStateError(StateStatus.RomMismatch, 0)
    expect(err.message).toMatch(/different ROM/i)
  })

  it('describes a call made before any ROM was loaded', () => {
    const err = new SaveStateError(StateStatus.NoRom, 0)
    expect(err.message).toMatch(/no ROM/i)
  })

  it('folds the expected record size into the BadState message', () => {
    // `load_sram` reuses this status for a wrong-length record, with the
    // expected length as context -- see `wasm.zig`.
    const err = new SaveStateError(StateStatus.BadState, 8192)
    expect(err.message).toContain('8192')
  })

  it('is a real Error, distinguishable from RomLoadError by name', () => {
    const err = new SaveStateError(StateStatus.BadState, 0)
    expect(err).toBeInstanceOf(Error)
    expect(err.name).toBe('SaveStateError')
  })

  it('falls back to a generic, honest message for a status code it does not recognize', () => {
    const err = new SaveStateError(-99 as StateStatus, 0)
    expect(err.message).toContain('-99')
  })
})
