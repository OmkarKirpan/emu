import { describe, expect, it } from 'vitest'
import { initialPauseReasonState, isPaused, pauseReasonReducer } from './pauseReason'

describe('pauseReason', () => {
  it('starts unpaused when the tab starts visible', () => {
    const state = initialPauseReasonState(false)
    expect(isPaused(state)).toBe(false)
  })

  it('starts paused when the tab starts hidden', () => {
    const state = initialPauseReasonState(true)
    expect(isPaused(state)).toBe(true)
  })

  it('a user pause takes effect on its own', () => {
    const state = pauseReasonReducer(initialPauseReasonState(false), { kind: 'user', paused: true })
    expect(isPaused(state)).toBe(true)
  })

  it('a hidden tab takes effect on its own', () => {
    const state = pauseReasonReducer(initialPauseReasonState(false), { kind: 'hidden', paused: true })
    expect(isPaused(state)).toBe(true)
  })

  it('coming back from hidden does not resume a game the user paused manually', () => {
    let state = initialPauseReasonState(false)
    state = pauseReasonReducer(state, { kind: 'user', paused: true })
    state = pauseReasonReducer(state, { kind: 'hidden', paused: true }) // tab backgrounded while user-paused
    state = pauseReasonReducer(state, { kind: 'hidden', paused: false }) // tab foregrounded again
    expect(isPaused(state)).toBe(true) // still paused -- the user never un-paused it
  })

  it('coming back from hidden resumes a game that was only hidden-paused', () => {
    let state = initialPauseReasonState(false)
    state = pauseReasonReducer(state, { kind: 'hidden', paused: true })
    state = pauseReasonReducer(state, { kind: 'hidden', paused: false })
    expect(isPaused(state)).toBe(false)
  })

  it('the user can resume while the tab is still hidden, and it stays paused until visible again', () => {
    let state = initialPauseReasonState(false)
    state = pauseReasonReducer(state, { kind: 'user', paused: true })
    state = pauseReasonReducer(state, { kind: 'hidden', paused: true })
    state = pauseReasonReducer(state, { kind: 'user', paused: false }) // user un-pauses mid-background
    expect(isPaused(state)).toBe(true) // the tab is still hidden
    state = pauseReasonReducer(state, { kind: 'hidden', paused: false })
    expect(isPaused(state)).toBe(false)
  })

  it('returns the same reference on a redundant dispatch', () => {
    const state = initialPauseReasonState(false)
    expect(pauseReasonReducer(state, { kind: 'user', paused: false })).toBe(state)
    expect(pauseReasonReducer(state, { kind: 'hidden', paused: false })).toBe(state)
  })
})
