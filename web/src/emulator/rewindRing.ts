// ENG-91's bounded history of save-states for rewind: a plain,
// dependency-free module (no wasm, no Worker globals) following
// `pauseReason.ts`'s own precedent, so the eviction/bounding policy is
// unit-testable on its own rather than only reachable through a real
// `NesCore` in `emulatorWorker.ts`.
//
// **Why a stack, not a circular buffer with a separate "current position"
// cursor.** The ticket's own acceptance criteria collapse into one another
// once captures are modeled as a LIFO: "rewind walks backwards" is `pop()`,
// "bounded memory, oldest evicted" is a capped `push()`, and "releasing
// rewind resumes forward play from where it stopped, [and future captures
// start again from there]" falls out for free -- the entries a rewind hold
// popped are already gone, so there is nothing left to explicitly discard
// on release, and nothing to reconcile with the fresh captures forward play
// starts pushing again. A circular buffer with a live read cursor would
// need that reconciliation spelled out by hand (what happens to the
// "future" frames still sitting past the cursor once play diverges from
// them); the stack has no such frames to begin with.
import { NTSC_FRAME_MS } from '../timing'

/** Every 10th frame -- ENG-91's chosen ~6Hz capture cadence (60.0988fps /
 * 10 ≈ 6.01Hz). Coarse enough that a `saveState()` (a ~20KB serialize) per
 * capture costs nothing next to a 16.6ms frame budget -- see
 * `emulatorWorker.ts`'s tick loop, where this interval gates the capture
 * call -- while still finer than a human can perceive as choppy once
 * `REWIND_SPEED_MULTIPLIER` (that file) plays them back. */
export const CAPTURE_INTERVAL_FRAMES = 10

/** How much rewind history to keep, wall-clock. The ticket's own budgeting:
 * a snapshot is ~20KB, so 60s of history (at the capture cadence above) is
 * ~7MB -- a fixed, bounded cost per running session regardless of how long
 * it has been open, never growing further once the cap is reached. */
const REWIND_HISTORY_SECONDS = 60

/** `REWIND_HISTORY_SECONDS` of captures at one every `CAPTURE_INTERVAL_
 * FRAMES` frames, computed rather than hand-rounded so the two constants
 * above stay the actual source of truth for this number. */
export const MAX_REWIND_SNAPSHOTS = Math.round(
  (REWIND_HISTORY_SECONDS * 1000) / (NTSC_FRAME_MS * CAPTURE_INTERVAL_FRAMES),
)

/**
 * A capped LIFO of save-state blobs. `push` is what the normal-forward tick
 * loop calls every `CAPTURE_INTERVAL_FRAMES`th frame; `pop` is what a
 * rewind hold calls once per rewind tick to step one capture back in time.
 */
export class RewindRing {
  private readonly maxSnapshots: number
  private snapshots: Uint8Array[] = []

  constructor(maxSnapshots: number = MAX_REWIND_SNAPSHOTS) {
    this.maxSnapshots = maxSnapshots
  }

  /** Appends the newest capture, evicting the single oldest one if that
   * pushes the ring past its cap -- one `shift()` per call at steady state,
   * not a batch trim, and cheap regardless: `maxSnapshots` is a few hundred
   * entries at most. */
  push(snapshot: Uint8Array): void {
    this.snapshots.push(snapshot)
    if (this.snapshots.length > this.maxSnapshots) this.snapshots.shift()
  }

  /** Pops the most recent capture -- the caller's next step back in time --
   * or `undefined` once the ring is empty. Bounded by construction: nothing
   * further back than the oldest surviving capture is ever known, so a
   * rewind hold that outlasts the ring's history simply stops popping and
   * holds on the oldest frame rather than underflowing into anything. */
  pop(): Uint8Array | undefined {
    return this.snapshots.pop()
  }

  /** Drops every capture -- ENG-91: the ring is per-cartridge, cleared by
   * `emulatorWorker.ts`'s `adoptRom` on every ROM swap (a previous
   * cartridge's save-states are meaningless, and often outright rejected,
   * against a different `rom_hash`/mapper -- see `wasm.zig`'s
   * `load_state`). */
  clear(): void {
    this.snapshots = []
  }

  get length(): number {
    return this.snapshots.length
  }
}
