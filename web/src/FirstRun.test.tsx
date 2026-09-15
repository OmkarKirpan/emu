import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { FirstRunBanner, FirstRunLoading } from './FirstRun'
import type { FirstRun } from './useFirstRun'

// See `RomPicker.test.tsx`'s matching comment: automatic cleanup only
// engages under Vitest's `globals: true`, which this project doesn't enable.
afterEach(cleanup)

describe('FirstRunLoading', () => {
  it('says what this is, and that it is loading', () => {
    render(<FirstRunLoading />)
    expect(screen.getByText(/cycle-accurate NES emulator/i)).toBeTruthy()
    expect(screen.getByText(/Loading/)).toBeTruthy()
  })
})

describe('FirstRunBanner', () => {
  const active = (dismiss = vi.fn()): FirstRun => ({ active: true, dismiss })

  it('renders nothing once retired', () => {
    render(<FirstRunBanner firstRun={{ active: false, dismiss: vi.fn() }} />)
    expect(screen.queryByRole('note')).toBeNull()
  })

  it('explains what the app is and how to bring a ROM', () => {
    render(<FirstRunBanner firstRun={active()} />)
    expect(screen.getByText(/cycle-accurate NES emulator/i)).toBeTruthy()
    expect(screen.getByText(/--rom/)).toBeTruthy()
    expect(screen.getByText(/drop a \.nes file/i)).toBeTruthy()
  })

  it('calls dismiss when closed', () => {
    const dismiss = vi.fn()
    render(<FirstRunBanner firstRun={active(dismiss)} />)

    fireEvent.click(screen.getByRole('button', { name: /dismiss/i }))

    expect(dismiss).toHaveBeenCalledTimes(1)
  })
})
