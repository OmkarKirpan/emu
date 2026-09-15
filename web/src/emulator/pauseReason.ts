/**
 * ENG-90's pause-reason state: two independent flags rather than one
 * boolean, because the two sources that can want the emulator paused --
 * the user's own button/key press, and the tab going `document.hidden` --
 * must not be able to clobber each other. A single `paused` boolean can't
 * tell "the user paused, then the tab was hidden, then it came back" from
 * "the tab was hidden, then it came back" -- the first must still be
 * paused afterward, the second must not. Kept as a plain, dependency-free
 * module (no React) so it's testable on its own, following the pattern of
 * `web/src/wasm/*.test.ts`; `EmulatorScreen.tsx` drives it with
 * `useReducer`.
 */
export interface PauseReasonState {
  /** Set by the app-bar button or the `P` key binding. Only ever changed by
   * a deliberate user action. */
  readonly user: boolean
  /** Set by a `visibilitychange` listener. Never survives past the next
   * visibility flip, and never something a user action alone can clear --
   * see `isPaused`. */
  readonly hidden: boolean
}

export type PauseReasonAction =
  | { kind: 'user'; paused: boolean }
  | { kind: 'hidden'; paused: boolean }

/** `hidden` defaults to `document.hidden` at the call site (not read here,
 * to keep this module DOM-free) for the rare case a session's very first
 * mount happens to be in a background tab. */
export function initialPauseReasonState(hidden: boolean): PauseReasonState {
  return { user: false, hidden }
}

/** Effective pause = either reason, exactly the "never un-pause a game the
 * user paused manually" rule from ENG-90's design notes: coming back from
 * hidden clears only the `hidden` flag, so a `user`-paused game stays
 * paused, and a merely `hidden`-paused one resumes. */
export function isPaused(state: PauseReasonState): boolean {
  return state.user || state.hidden
}

/** Same value in, same reference out -- lets a `useReducer` caller skip a
 * re-render (and the `'pause'`/`'resume'` postMessage effect keyed on it)
 * on a redundant dispatch, e.g. two `visibilitychange` events in a row that
 * agree. */
export function pauseReasonReducer(state: PauseReasonState, action: PauseReasonAction): PauseReasonState {
  switch (action.kind) {
    case 'user':
      return state.user === action.paused ? state : { ...state, user: action.paused }
    case 'hidden':
      return state.hidden === action.paused ? state : { ...state, hidden: action.paused }
  }
}
