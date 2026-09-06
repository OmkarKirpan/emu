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
        return `Unsupported mapper ${context} (only NROM/mapper 0 is supported so far).`
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
