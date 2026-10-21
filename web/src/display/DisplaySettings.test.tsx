import { act, cleanup, fireEvent, render, renderHook, screen } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { DEFAULT_DISPLAY_FILTER, type DisplayFilterKind, type DisplayFilterSettings } from '../emulator/displayFilter'
import { DisplaySettings } from './DisplaySettings'
import { loadDisplayFilter } from './displayFilterStore'
import { useDisplayFilter } from './useDisplayFilter'

// Same reasoning as `RomPicker.test.tsx`: no `globals: true`, so cleanup is
// wired by hand.
afterEach(cleanup)

/** Plain-DOM stand-ins for jest-dom's matchers, which this project doesn't
 * pull in. `:disabled` rather than `.disabled`: the CRT options are disabled
 * through their `<fieldset>`, which the property doesn't reflect. */
const checked = (el: HTMLElement) => (el as HTMLInputElement).checked
const disabled = (el: HTMLElement) => el.matches(':disabled')

const CRT_ALL_ON: DisplayFilterSettings = { ...DEFAULT_DISPLAY_FILTER, filter: 'crt' }
/** What the Worker reports on WebGPU with every shader compiled. */
const ALL: DisplayFilterKind[] = ['none', 'crt']
/** What it reports on Canvas 2D, or when the CRT shader didn't compile. */
const PLAIN_ONLY: DisplayFilterKind[] = ['none']

describe('DisplaySettings', () => {
  it('offers Off and CRT, with the current filter selected', () => {
    render(<DisplaySettings settings={DEFAULT_DISPLAY_FILTER} onChange={vi.fn()} filters={ALL} />)
    expect(checked(screen.getByRole('radio', { name: 'Off' }))).toBe(true)
    expect(checked(screen.getByRole('radio', { name: 'CRT' }))).toBe(false)
  })

  it("hides CRT's options while the filter is off", () => {
    render(<DisplaySettings settings={DEFAULT_DISPLAY_FILTER} onChange={vi.fn()} filters={ALL} />)
    expect(screen.queryByRole('checkbox')).toBeNull()
  })

  it('selecting CRT reports the change and keeps the stored CRT options', () => {
    const onChange = vi.fn()
    const settings: DisplayFilterSettings = {
      filter: 'none',
      crt: { scanlines: false, curvature: true, chromaticAberration: false, vignette: true },
    }
    render(<DisplaySettings settings={settings} onChange={onChange} filters={ALL} />)
    fireEvent.click(screen.getByRole('radio', { name: 'CRT' }))
    expect(onChange).toHaveBeenCalledWith({ ...settings, filter: 'crt' })
  })

  it('shows the four CRT options, each reflecting its own setting', () => {
    const settings: DisplayFilterSettings = {
      filter: 'crt',
      crt: { scanlines: true, curvature: false, chromaticAberration: true, vignette: false },
    }
    render(<DisplaySettings settings={settings} onChange={vi.fn()} filters={ALL} />)
    expect(checked(screen.getByRole('checkbox', { name: 'Scanlines' }))).toBe(true)
    expect(checked(screen.getByRole('checkbox', { name: 'Screen curvature' }))).toBe(false)
    expect(checked(screen.getByRole('checkbox', { name: 'Chromatic aberration' }))).toBe(true)
    expect(checked(screen.getByRole('checkbox', { name: 'Vignette' }))).toBe(false)
  })

  it('toggling one option changes that option and nothing else', () => {
    const onChange = vi.fn()
    render(<DisplaySettings settings={CRT_ALL_ON} onChange={onChange} filters={ALL} />)
    fireEvent.click(screen.getByRole('checkbox', { name: 'Chromatic aberration' }))
    expect(onChange).toHaveBeenCalledWith({ ...CRT_ALL_ON, crt: { ...CRT_ALL_ON.crt, chromaticAberration: false } })
  })

  it('is disabled, with no note, until the emulator reports which filters it can apply', () => {
    render(<DisplaySettings settings={CRT_ALL_ON} onChange={vi.fn()} filters={null} />)
    expect(disabled(screen.getByRole('radio', { name: 'CRT' }))).toBe(true)
    expect(disabled(screen.getByRole('checkbox', { name: 'Scanlines' }))).toBe(true)
    expect(screen.queryByText(/not available/i)).toBeNull()
  })

  it('disables a filter the emulator cannot apply, and names it', () => {
    render(<DisplaySettings settings={CRT_ALL_ON} onChange={vi.fn()} filters={PLAIN_ONLY} />)
    expect(disabled(screen.getByRole('radio', { name: 'CRT' }))).toBe(true)
    expect(disabled(screen.getByRole('checkbox', { name: 'Vignette' }))).toBe(true)
    expect(disabled(screen.getByRole('radio', { name: 'Off' }))).toBe(false)
    screen.getByText('Not available in this browser: CRT.')
  })

  it('says nothing about availability when everything is available', () => {
    render(<DisplaySettings settings={CRT_ALL_ON} onChange={vi.fn()} filters={ALL} />)
    expect(screen.queryByText(/not available/i)).toBeNull()
  })

  it('never names a renderer backend (ENG-93)', () => {
    render(<DisplaySettings settings={CRT_ALL_ON} onChange={vi.fn()} filters={PLAIN_ONLY} />)
    expect(document.body.textContent).not.toMatch(/webgpu|canvas ?2d/i)
  })

  it.each([
    ['Scanlines', 'scanlines'],
    ['Screen curvature', 'curvature'],
    ['Chromatic aberration', 'chromaticAberration'],
    ['Vignette', 'vignette'],
  ] as const)('can enable %s without changing the other preferences', (label, option) => {
    const onChange = vi.fn()
    const settings: DisplayFilterSettings = {
      filter: 'crt',
      crt: { scanlines: false, curvature: false, chromaticAberration: false, vignette: false },
    }
    render(<DisplaySettings settings={settings} onChange={onChange} filters={ALL} />)
    fireEvent.click(screen.getByRole('checkbox', { name: label }))
    expect(onChange).toHaveBeenCalledExactlyOnceWith({
      filter: 'crt', crt: { ...settings.crt, [option]: true },
    })
    expect(settings.crt[option]).toBe(false)
  })

  it('can switch a stored unavailable CRT filter off without losing its preferences', () => {
    const onChange = vi.fn()
    render(<DisplaySettings settings={CRT_ALL_ON} onChange={onChange} filters={PLAIN_ONLY} />)
    fireEvent.click(screen.getByRole('radio', { name: 'Off' }))
    expect(onChange).toHaveBeenCalledExactlyOnceWith({ ...CRT_ALL_ON, filter: 'none' })
  })

  it('enables a stored selection when capabilities arrive without changing the preference', () => {
    const onChange = vi.fn()
    const { rerender } = render(
      <DisplaySettings settings={CRT_ALL_ON} onChange={onChange} filters={null} />,
    )
    expect(disabled(screen.getByRole('radio', { name: 'Off' }))).toBe(true)
    rerender(<DisplaySettings settings={CRT_ALL_ON} onChange={onChange} filters={PLAIN_ONLY} />)
    expect(checked(screen.getByRole('radio', { name: 'CRT' }))).toBe(true)
    screen.getByText('Not available in this browser: CRT.')
    rerender(<DisplaySettings settings={CRT_ALL_ON} onChange={onChange} filters={ALL} />)
    expect(disabled(screen.getByRole('radio', { name: 'CRT' }))).toBe(false)
    expect(disabled(screen.getByRole('checkbox', { name: 'Scanlines' }))).toBe(false)
    expect(screen.queryByText(/not available/i)).toBeNull()
    expect(onChange).not.toHaveBeenCalled()
  })
})

describe('useDisplayFilter', () => {
  beforeEach(() => {
    localStorage.clear()
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  function fakeWorker() {
    const postMessage = vi.fn()
    return { worker: { postMessage } as unknown as Worker, postMessage }
  }

  it('starts from what was stored last time', () => {
    localStorage.setItem('emu.display.filter', JSON.stringify(CRT_ALL_ON))
    const { result } = renderHook(() => useDisplayFilter(null))
    expect(result.current[0]).toEqual(CRT_ALL_ON)
  })

  it('sends the current settings to the Worker as soon as there is one', () => {
    const { worker, postMessage } = fakeWorker()
    renderHook(() => useDisplayFilter(worker))
    expect(postMessage).toHaveBeenCalledWith({ type: 'set-display-filter', settings: DEFAULT_DISPLAY_FILTER })
  })

  // How `EmulatorScreen` actually uses it: `worker` is null on the first
  // render and only set once the session exists. A stored setting has to
  // reach the Worker then, with nobody touching the controls.
  it('sends a restored setting to a Worker that only appears after mount', () => {
    localStorage.setItem('emu.display.filter', JSON.stringify(CRT_ALL_ON))
    const { worker, postMessage } = fakeWorker()
    const { rerender } = renderHook(({ w }) => useDisplayFilter(w), { initialProps: { w: null as Worker | null } })
    expect(postMessage).not.toHaveBeenCalled()
    rerender({ w: worker })
    expect(postMessage).toHaveBeenCalledWith({ type: 'set-display-filter', settings: CRT_ALL_ON })
  })

  it('a change is both sent to the Worker and persisted', () => {
    const { worker, postMessage } = fakeWorker()
    const { result } = renderHook(() => useDisplayFilter(worker))
    act(() => result.current[1](CRT_ALL_ON))
    expect(postMessage).toHaveBeenLastCalledWith({ type: 'set-display-filter', settings: CRT_ALL_ON })
    expect(loadDisplayFilter()).toEqual(CRT_ALL_ON)
  })

  it('persists a change made before a Worker exists, then sends only the latest settings', () => {
    const { worker, postMessage } = fakeWorker()
    const { result, rerender } = renderHook(({ w }) => useDisplayFilter(w), {
      initialProps: { w: null as Worker | null },
    })
    const settings = { ...CRT_ALL_ON, crt: { ...CRT_ALL_ON.crt, vignette: false } }
    act(() => result.current[1](settings))
    expect(loadDisplayFilter()).toEqual(settings)
    expect(postMessage).not.toHaveBeenCalled()
    rerender({ w: worker })
    expect(postMessage).toHaveBeenCalledExactlyOnceWith({ type: 'set-display-filter', settings })
  })

  it('sends current preferences to a replacement Worker without notifying the previous one', () => {
    const first = fakeWorker()
    const second = fakeWorker()
    const { result, rerender } = renderHook(({ w }) => useDisplayFilter(w), {
      initialProps: { w: first.worker },
    })
    act(() => result.current[1](CRT_ALL_ON))
    first.postMessage.mockClear()
    rerender({ w: second.worker })
    expect(second.postMessage).toHaveBeenCalledExactlyOnceWith({
      type: 'set-display-filter', settings: CRT_ALL_ON,
    })
    expect(first.postMessage).not.toHaveBeenCalled()
  })

  it('does not resend settings on an unrelated rerender or reload storage after mounting', () => {
    const { worker, postMessage } = fakeWorker()
    const { result, rerender } = renderHook(() => useDisplayFilter(worker))
    localStorage.setItem('emu.display.filter', JSON.stringify(CRT_ALL_ON))
    rerender()
    expect(result.current[0]).toEqual(DEFAULT_DISPLAY_FILTER)
    expect(postMessage).toHaveBeenCalledTimes(1)
  })

  it('keeps updating the active session if persistence is blocked', () => {
    const { worker, postMessage } = fakeWorker()
    const { result } = renderHook(() => useDisplayFilter(worker))
    vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => {
      throw new Error('blocked')
    })
    act(() => result.current[1](CRT_ALL_ON))
    expect(result.current[0]).toEqual(CRT_ALL_ON)
    expect(postMessage).toHaveBeenLastCalledWith({ type: 'set-display-filter', settings: CRT_ALL_ON })
  })
})
