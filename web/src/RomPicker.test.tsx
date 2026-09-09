import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { RomLoadReadout, RomPicker } from './RomPicker'
import { useRomLoader } from './useRomLoader'
import type { EmulatorWorkerOutbound } from './emulator/protocol'

// `@testing-library/react`'s automatic cleanup only engages under
// Vitest's `globals: true`, which this project doesn't enable (every other
// spec imports from `vitest` explicitly). Wired by hand instead.
afterEach(cleanup)

/**
 * A stand-in for the emulator Worker: a real `EventTarget`, so the hook's
 * `addEventListener`/`removeEventListener` are exercised rather than
 * mocked, with `postMessage` spied and a `reply` helper for pushing the
 * Worker's side of the exchange back.
 *
 * Deliberately not `vi.mock`ing the Worker constructor: nothing here needs
 * a Worker to exist, only something that speaks its message interface.
 */
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

/** The same wiring `EmulatorScreen` does -- hook, picker, drop target and
 * readout -- so these tests exercise the seam between them rather than any
 * one piece in isolation. */
function Harness({ worker }: { worker: Worker | null }) {
  const { romLoad, dismiss, loadFile, dragging, dropHandlers } = useRomLoader(worker)
  return (
    <>
      <div data-testid="screen" className={dragging ? 'screen screen-dragging' : 'screen'} {...dropHandlers} />
      <RomPicker onPick={loadFile} disabled={false} />
      <RomLoadReadout romLoad={romLoad} onDismiss={dismiss} />
    </>
  )
}

const romFile = (name: string, bytes: number[]) => new File([new Uint8Array(bytes)], name)

/** The file input, reached the way a user would reach it -- through the
 * label -- rather than by class name. */
const pickerInput = () => screen.getByLabelText(/load rom/i)

describe('picking a file', () => {
  it('posts the file bytes to the Worker as a transferable load-rom', async () => {
    const { worker, postMessage } = fakeWorker()
    render(<Harness worker={worker} />)

    fireEvent.change(pickerInput(), { target: { files: [romFile('game.nes', [0x4e, 0x45, 0x53, 0x1a])] } })

    await waitFor(() => expect(postMessage).toHaveBeenCalledTimes(1))
    const [message, transfer] = postMessage.mock.calls[0]
    expect(message.type).toBe('load-rom')
    expect(Array.from(new Uint8Array(message.romBytes))).toEqual([0x4e, 0x45, 0x53, 0x1a])
    // Transferred rather than structured-cloned -- the same buffer object,
    // listed in the transfer list.
    expect(transfer).toEqual([message.romBytes])
  })

  it('clears the input value so the same file can be picked twice', async () => {
    const { worker, postMessage } = fakeWorker()
    render(<Harness worker={worker} />)
    const input = pickerInput() as HTMLInputElement

    fireEvent.change(input, { target: { files: [romFile('game.nes', [1])] } })

    await waitFor(() => expect(postMessage).toHaveBeenCalled())
    // Without this, `change` never fires again for an identical selection
    // and "load it again to restart it" silently does nothing.
    expect(input.value).toBe('')
  })

  it('rejects a file that is not a .nes without bothering the Worker', async () => {
    const { worker, postMessage } = fakeWorker()
    render(<Harness worker={worker} />)

    fireEvent.change(pickerInput(), { target: { files: [romFile('screenshot.png', [0x89, 0x50])] } })

    // Caught here rather than in the core, which would report it as
    // `InvalidHeader` -- true, but silent about the actual mistake.
    expect((await screen.findByRole('alert')).textContent).toContain('screenshot.png: Not a .nes file.')
    expect(postMessage).not.toHaveBeenCalled()
  })
})

describe('the Worker reply', () => {
  it('names the loaded ROM on success', async () => {
    const { worker, reply } = fakeWorker()
    render(<Harness worker={worker} />)

    fireEvent.change(pickerInput(), { target: { files: [romFile('zelda.nes', [1])] } })
    reply({ type: 'rom-loaded', ok: true })

    expect(await screen.findByText('now playing: zelda.nes')).toBeTruthy()
    expect(screen.queryByRole('alert')).toBeNull()
  })

  it('shows a failure against the filename, and dismisses it', async () => {
    const { worker, reply } = fakeWorker()
    render(<Harness worker={worker} />)

    fireEvent.change(pickerInput(), { target: { files: [romFile('vrc6.nes', [1])] } })
    reply({ type: 'rom-loaded', ok: false, message: 'Unsupported mapper 24 (supported: 0 NROM, ...).' })

    const alert = await screen.findByRole('alert')
    expect(alert.textContent).toContain('vrc6.nes: Unsupported mapper 24')
    // Dismissible on purpose: the previous ROM is still running, so this
    // must not be a state the UI is stuck in.
    fireEvent.click(screen.getByRole('button', { name: /dismiss/i }))
    await waitFor(() => expect(screen.queryByRole('alert')).toBeNull())
  })

  it('ignores messages that are not rom-loaded', async () => {
    const { worker, reply } = fakeWorker()
    render(<Harness worker={worker} />)

    reply({ type: 'stats', fill: 1024, underrunCount: 0, peak: 0.5, rms: 0.2 })

    await waitFor(() => {
      expect(screen.queryByRole('alert')).toBeNull()
      expect(screen.queryByText(/now playing/)).toBeNull()
    })
  })
})

describe('dropping a file on the screen', () => {
  /** jsdom's `DragEvent` carries no `dataTransfer`, so `fireEvent.drop`'s
   * init object supplies one -- only `files` is read. */
  const withFiles = (files: File[]) => ({ dataTransfer: { files } })

  it('loads a dropped ROM through the same path as the picker', async () => {
    const { worker, postMessage } = fakeWorker()
    render(<Harness worker={worker} />)

    fireEvent.drop(screen.getByTestId('screen'), withFiles([romFile('dropped.nes', [0x4e])]))

    await waitFor(() => expect(postMessage).toHaveBeenCalledTimes(1))
    expect(postMessage.mock.calls[0][0].type).toBe('load-rom')
  })

  it('highlights the screen while a file is over it, and stops on leave', () => {
    const { worker } = fakeWorker()
    render(<Harness worker={worker} />)
    const target = screen.getByTestId('screen')

    fireEvent.dragOver(target)
    expect(target.className).toContain('screen-dragging')

    fireEvent.dragLeave(target)
    expect(target.className).not.toContain('screen-dragging')
  })

  it('clears the highlight on drop, even for a rejected file', () => {
    const { worker } = fakeWorker()
    render(<Harness worker={worker} />)
    const target = screen.getByTestId('screen')

    fireEvent.dragOver(target)
    fireEvent.drop(target, withFiles([romFile('screenshot.png', [1])]))

    expect(target.className).not.toContain('screen-dragging')
  })
})

it('does nothing at all before the Worker exists', () => {
  render(<Harness worker={null} />)

  fireEvent.change(pickerInput(), { target: { files: [romFile('game.nes', [1])] } })

  // No throw, and no error shown: the picker is disabled in the real UI
  // until `status` is `'running'`, so this is belt-and-braces.
  expect(screen.queryByRole('alert')).toBeNull()
})
