/**
 * NTSC's true frame rate: 1,789,773 CPU cycles/sec ÷ 29,780.5 cycles/frame.
 * Deliberately not a round 60 -- the core is cycle-accurate, so pacing
 * anything against it at 60.0 runs 0.16% slow against a wall clock.
 *
 * Shared between `EmulatorScreen.tsx`'s video pacing and
 * `audio/audioWorker.ts`'s tick pacing: both need the same real-world frame
 * period, and a milestone that ever moves video into that same Worker (see
 * ENG-70's still-open acceptance criteria) will want them already agreeing.
 */
export const NTSC_FRAME_MS = 1000 / 60.0988
