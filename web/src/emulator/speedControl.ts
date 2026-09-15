/**
 * ENG-91's speed levels: 0.5x/1x/2x, as a plain, dependency-free module
 * (no React, no Worker) following `pauseReason.ts`'s own precedent -- the
 * *policy* of what the next speed is lives here, testable on its own,
 * while `EmulatorScreen.tsx`'s `-`/`=` key handlers and its app-bar button
 * just call into it, and `emulatorWorker.ts` applies whatever it returns to
 * `scheduleLoop`'s period.
 *
 * A `Speed` is the multiplier on `NTSC_FRAME_MS` directly (not an index or
 * an enum) so every consumer -- the worker's period calculation, the app
 * bar's `${speed}x` label, the canvas indicator -- reads it without a
 * lookup table of its own.
 */
export const SPEED_LEVELS = [0.5, 1, 2] as const

export type Speed = (typeof SPEED_LEVELS)[number]

export const DEFAULT_SPEED: Speed = 1

/** `-`/`=` (`Minus`/`Equal`): step one level down/up, clamped at either end
 * rather than wrapping -- these are literally "slower"/"faster" keys, and a
 * wraparound from 2x straight to 0.5x on one more `=` press would read as
 * the key doing nothing, or the opposite of what it says. */
export function stepSpeed(current: Speed, direction: -1 | 1): Speed {
  const index = SPEED_LEVELS.indexOf(current)
  const next = Math.min(SPEED_LEVELS.length - 1, Math.max(0, index + direction))
  return SPEED_LEVELS[next]
}

/** The app-bar speed control's own click behaviour: a single button showing
 * the current speed cycles forward through every level, wrapping 2x back to
 * 0.5x. Wrapping is fine here (unlike `stepSpeed`) because a button with one
 * label and no up/down affordance reads as "next", not "faster" -- the same
 * distinction `--pause`/`--resume` draws between a toggle and a stepper. */
export function cycleSpeed(current: Speed): Speed {
  const index = SPEED_LEVELS.indexOf(current)
  return SPEED_LEVELS[(index + 1) % SPEED_LEVELS.length]
}
