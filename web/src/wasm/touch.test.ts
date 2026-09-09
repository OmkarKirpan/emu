import { describe, expect, it } from 'vitest'
import { Button } from './controller'
import { TouchController, directionFromOffset } from './touch'

describe('TouchController', () => {
  it('latches face buttons independently', () => {
    const touch = new TouchController()
    touch.setButton(Button.A, true)
    touch.setButton(Button.Start, true)
    expect(touch.read()).toBe(Button.A | Button.Start)

    touch.setButton(Button.A, false)
    expect(touch.read()).toBe(Button.Start)
  })

  it('replaces the whole direction field rather than OR-ing into it', () => {
    const touch = new TouchController()
    touch.setDirection(Button.Left)
    touch.setDirection(Button.Right)
    // The point of `setDirection`: Left|Right is not a state real hardware
    // can report, so sliding a thumb across the pad must never produce it.
    expect(touch.read()).toBe(Button.Right)
  })

  it('keeps face buttons held across a direction change', () => {
    const touch = new TouchController()
    touch.setButton(Button.B, true)
    touch.setDirection(Button.Up | Button.Right)
    expect(touch.read()).toBe(Button.B | Button.Up | Button.Right)

    touch.setDirection(0)
    expect(touch.read()).toBe(Button.B)
  })

  it('ignores non-direction bits handed to setDirection', () => {
    const touch = new TouchController()
    touch.setDirection(Button.A | Button.Up)
    expect(touch.read()).toBe(Button.Up)
  })

  it('clears everything', () => {
    const touch = new TouchController()
    touch.setButton(Button.A, true)
    touch.setDirection(Button.Down)
    touch.clear()
    expect(touch.read()).toBe(0)
  })
})

describe('directionFromOffset', () => {
  it('reads centre as no direction', () => {
    expect(directionFromOffset(0, 0)).toBe(0)
    expect(directionFromOffset(0.1, 0.1)).toBe(0)
  })

  it('reads the four cardinals', () => {
    // `dy` is screen-space: negative is up.
    expect(directionFromOffset(0, -1)).toBe(Button.Up)
    expect(directionFromOffset(0, 1)).toBe(Button.Down)
    expect(directionFromOffset(-1, 0)).toBe(Button.Left)
    expect(directionFromOffset(1, 0)).toBe(Button.Right)
  })

  it('reads the four diagonals', () => {
    expect(directionFromOffset(1, -1)).toBe(Button.Up | Button.Right)
    expect(directionFromOffset(-1, -1)).toBe(Button.Up | Button.Left)
    expect(directionFromOffset(1, 1)).toBe(Button.Down | Button.Right)
    expect(directionFromOffset(-1, 1)).toBe(Button.Down | Button.Left)
  })

  it('biases toward cardinals near the axes', () => {
    // ~15deg off horizontal still reads as a clean Right, not a diagonal:
    // an unintended diagonal is worse than an unintended cardinal.
    expect(directionFromOffset(1, -0.26)).toBe(Button.Right)
    expect(directionFromOffset(-1, 0.26)).toBe(Button.Left)
  })

  it('never reports two opposing directions', () => {
    for (let angle = 0; angle < Math.PI * 2; angle += Math.PI / 60) {
      const mask = directionFromOffset(Math.cos(angle), Math.sin(angle))
      expect(mask & Button.Left && mask & Button.Right).toBeFalsy()
      expect(mask & Button.Up && mask & Button.Down).toBeFalsy()
    }
  })
})
