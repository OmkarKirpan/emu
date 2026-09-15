import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { RomLibrary } from './RomLibrary'
import type { EmulatorWorkerOutbound } from './emulator/protocol'

// See `RomPicker.test.tsx`'s matching comment: automatic cleanup only
// engages under Vitest's `globals: true`, which this project doesn't enable.
afterEach(cleanup)

/** Same fake as `RomPicker.test.tsx`'s: a real `EventTarget` standing in for
 * the emulator Worker, so `addEventListener`/`removeEventListener` are
 * genuinely exercised rather than mocked. */
function fakeWorker() {
  const target = new EventTarget()
  const postMessage = vi.fn()
  const worker = Object.assign(target, { postMessage }) as unknown as Worker
  return {
    worker,
    postMessage,
    reply(message: EmulatorWorkerOutbound) {
      target.dispatchEvent(Object.assign(new Event('message'), { data: message }))
    },
  }
}

const entry = (romHash: string, name: string, lastPlayedAt = 1) => ({ romHash, name, lastPlayedAt, size: 4 })

describe('the empty library', () => {
  it('shows the vendored demo as a placeholder rather than an empty list', () => {
    const { worker } = fakeWorker()
    render(<RomLibrary worker={worker} enabled={false} />)

    expect(screen.getByText(/sprite_input_demo\.nes/)).toBeTruthy()
    expect(screen.queryByRole('button', { name: /resume/i })).toBeNull()
  })
})

describe('a populated library', () => {
  it('asks the Worker for a listing on mount', () => {
    const { worker, postMessage } = fakeWorker()
    render(<RomLibrary worker={worker} enabled />)
    expect(postMessage).toHaveBeenCalledWith({ type: 'list-library' })
  })

  it('renders every entry the Worker reports, replacing the placeholder', async () => {
    const { worker, reply } = fakeWorker()
    render(<RomLibrary worker={worker} enabled />)

    reply({ type: 'library', roms: [entry('a'.repeat(64), 'zelda.nes'), entry('b'.repeat(64), 'metroid.nes')] })

    expect(await screen.findByText('zelda.nes')).toBeTruthy()
    expect(screen.getByText('metroid.nes')).toBeTruthy()
    expect(screen.queryByText(/sprite_input_demo\.nes/)).toBeNull()
  })

  it('posts resume-rom for the clicked entry\'s hash', async () => {
    const { worker, postMessage, reply } = fakeWorker()
    render(<RomLibrary worker={worker} enabled />)
    const hash = 'a'.repeat(64)
    reply({ type: 'library', roms: [entry(hash, 'zelda.nes')] })
    await screen.findByText('zelda.nes')

    fireEvent.click(screen.getByRole('button', { name: /resume/i }))

    expect(postMessage).toHaveBeenCalledWith({ type: 'resume-rom', romHash: hash })
  })

  it('posts remove-rom for the clicked entry\'s hash', async () => {
    const { worker, postMessage, reply } = fakeWorker()
    render(<RomLibrary worker={worker} enabled />)
    const hash = 'a'.repeat(64)
    reply({ type: 'library', roms: [entry(hash, 'zelda.nes')] })
    await screen.findByText('zelda.nes')

    fireEvent.click(screen.getByRole('button', { name: /remove zelda\.nes/i }))

    expect(postMessage).toHaveBeenCalledWith({ type: 'remove-rom', romHash: hash })
  })

  it('shows a library-error as an alert', async () => {
    const { worker, reply } = fakeWorker()
    render(<RomLibrary worker={worker} enabled />)

    reply({ type: 'library-error', message: 'That ROM is no longer in the library.' })

    expect((await screen.findByRole('alert')).textContent).toContain('no longer in the library')
  })
})

describe('the resume autosave (useResumeAutosave)', () => {
  it('saves to the reserved resume slot when the tab becomes hidden', async () => {
    const { worker, postMessage } = fakeWorker()
    render(<RomLibrary worker={worker} enabled />)
    postMessage.mockClear() // drop the mount-time 'list-library' call

    Object.defineProperty(document, 'visibilityState', { value: 'hidden', configurable: true })
    document.dispatchEvent(new Event('visibilitychange'))

    await waitFor(() => expect(postMessage).toHaveBeenCalledWith({ type: 'save-state', slot: 'resume' }))
  })

  it('also saves on pagehide, as a best-effort second attempt', async () => {
    const { worker, postMessage } = fakeWorker()
    render(<RomLibrary worker={worker} enabled />)
    postMessage.mockClear()

    window.dispatchEvent(new Event('pagehide'))

    await waitFor(() => expect(postMessage).toHaveBeenCalledWith({ type: 'save-state', slot: 'resume' }))
  })

  it('does nothing while not enabled -- there is no running game to save', async () => {
    const { worker, postMessage } = fakeWorker()
    render(<RomLibrary worker={worker} enabled={false} />)
    postMessage.mockClear()

    Object.defineProperty(document, 'visibilityState', { value: 'hidden', configurable: true })
    document.dispatchEvent(new Event('visibilitychange'))
    window.dispatchEvent(new Event('pagehide'))

    await new Promise((resolve) => setTimeout(resolve, 0))
    expect(postMessage).not.toHaveBeenCalled()
  })
})
