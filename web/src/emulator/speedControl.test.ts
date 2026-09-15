import { describe, expect, it } from 'vitest'
import { cycleSpeed, SPEED_LEVELS, stepSpeed } from './speedControl'

describe('speedControl', () => {
  it('steps up through every level', () => {
    expect(stepSpeed(0.5, 1)).toBe(1)
    expect(stepSpeed(1, 1)).toBe(2)
  })

  it('steps down through every level', () => {
    expect(stepSpeed(2, -1)).toBe(1)
    expect(stepSpeed(1, -1)).toBe(0.5)
  })

  it('clamps at the top instead of wrapping', () => {
    expect(stepSpeed(2, 1)).toBe(2)
  })

  it('clamps at the bottom instead of wrapping', () => {
    expect(stepSpeed(0.5, -1)).toBe(0.5)
  })

  it('cycles forward through every level, wrapping back to the slowest', () => {
    expect(cycleSpeed(0.5)).toBe(1)
    expect(cycleSpeed(1)).toBe(2)
    expect(cycleSpeed(2)).toBe(0.5)
  })

  it('SPEED_LEVELS is exactly 0.5x/1x/2x, in order', () => {
    expect(SPEED_LEVELS).toEqual([0.5, 1, 2])
  })
})
