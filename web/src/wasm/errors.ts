// Split out of `core.ts` deliberately: this file has no dependency on the
// wasm module (no `?init` import anywhere in its graph), which is what lets
// `errors.test.ts` be a genuinely fast, wasm-free unit test rather than one
// that accidentally needs `nes_core.wasm` to already be built just because
// it lives next to the class that imports it.

/**
 * `load_rom`'s `i32` status codes — see `core/src/wasm.zig`'s doc comment,
 * which is this table's source of truth. `Ok` is success; JS owns the
 * code -> message lookup (ENG-60), which is exactly what `RomLoadError`
 * below is.
 *
 * A plain object rather than a TS `enum`: this project's tsconfig enables
 * `erasableSyntaxOnly`, which (like Node's own type-stripping) rejects any
 * construct that isn't pure-type and erasable at compile time -- `enum`
 * (const or not) compiles to a real runtime object, so it doesn't qualify.
 */
export const RomStatus = {
  Ok: 0,
  InvalidHeader: -1,
  UnsupportedMapper: -2,
  TruncatedData: -3,
  RomTooLarge: -4,
} as const
export type RomStatus = (typeof RomStatus)[keyof typeof RomStatus]

/** Thrown by `NesCore.loadRom` for any non-`Ok` status, carrying both the
 * raw code and `get_last_error_context()`'s reading at the time of failure
 * (see `wasm.zig` for what that number means per status). */
export class RomLoadError extends Error {
  readonly status: RomStatus
  readonly context: number

  constructor(status: RomStatus, context: number) {
    super(RomLoadError.describe(status, context))
    this.name = 'RomLoadError'
    this.status = status
    this.context = context
  }

  private static describe(status: RomStatus, context: number): string {
    switch (status) {
      case RomStatus.InvalidHeader:
        return 'Not a valid iNES ROM file.'
      case RomStatus.UnsupportedMapper:
        // Kept in step with `core/src/rom.zig`'s `createMapper` switch,
        // which is the closed set this message describes. It said "only
        // NROM/mapper 0" until M7 added the other four; ENG-77 is what put
        // this string in front of an actual user, since an unsupported
        // mapper is the expected outcome for plenty of real ROMs.
        return `Unsupported mapper ${context} (supported: 0 NROM, 1 MMC1, 2 UxROM, 3 CNROM, 4 MMC3).`
      case RomStatus.TruncatedData:
        return `ROM file is truncated (only ${context} bytes were readable).`
      case RomStatus.RomTooLarge:
        return `ROM file is too large (the core's cap is ${context} bytes).`
      default:
        // Unreachable for the codes above, and `loadRom` never constructs
        // this for `Ok` -- but a `default` (rather than an `Ok` arm that
        // returns a lie) means a status code added on the Zig side reads as
        // an honest unknown here instead of falling out of the switch as
        // `undefined`.
        return `ROM load failed (status ${status}).`
    }
  }
}

/**
 * The save-state and SRAM half of the same `i32` status table (M8, ENG-76)
 * -- `core/src/wasm.zig`'s doc comment remains the source of truth for both.
 *
 * Kept separate from `RomStatus` rather than merged into one union because
 * the two describe different operations: nothing that loads a ROM can
 * return `StateMapperMismatch`, and nothing that loads a state can return
 * `UnsupportedMapper`. A single table would let a caller `switch` on a code
 * the call it made cannot produce.
 */
export const StateStatus = {
  Ok: 0,
  /** A save-state or SRAM call arrived before any ROM was loaded. */
  NoRom: -5,
  /** Wrong magic, a `format_version` from the future, or truncated. */
  BadState: -6,
  /** Saved under a different mapper than the loaded ROM uses; `context` is
   * the mapper id the *state* named. */
  MapperMismatch: -7,
  /** Saved against a different ROM entirely. */
  RomMismatch: -8,
  /** The state exceeded the core's static buffer -- unreachable for any
   * cartridge this core supports; `context` is the cap. */
  TooLarge: -9,
} as const
export type StateStatus = (typeof StateStatus)[keyof typeof StateStatus]

/** Thrown by `NesCore.saveState`/`loadState`/`loadSram` for any non-`Ok`
 * status, carrying the raw code and `get_last_error_context()`'s reading,
 * exactly like `RomLoadError` does for ROM loading. */
export class SaveStateError extends Error {
  readonly status: StateStatus
  readonly context: number

  constructor(status: StateStatus, context: number) {
    super(SaveStateError.describe(status, context))
    this.name = 'SaveStateError'
    this.status = status
    this.context = context
  }

  private static describe(status: StateStatus, context: number): string {
    switch (status) {
      case StateStatus.NoRom:
        return 'No ROM is loaded, so there is no machine to save or restore.'
      case StateStatus.BadState:
        return `Not a save-state this build can read (or a ${context}-byte record was expected).`
      case StateStatus.MapperMismatch:
        return `This save-state was made on a mapper-${context} cartridge, which is not the one loaded.`
      case StateStatus.RomMismatch:
        return 'This save-state belongs to a different ROM.'
      case StateStatus.TooLarge:
        return `The machine state exceeded the core's ${context}-byte buffer.`
      default:
        // See `RomLoadError.describe`'s matching comment.
        return `Save-state operation failed (status ${status}).`
    }
  }
}
