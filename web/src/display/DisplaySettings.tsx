import { DISPLAY_FILTERS, type CrtOptions, type DisplayFilterKind, type DisplayFilterSettings } from '../emulator/displayFilter'
import type { RendererKind } from '../emulator/protocol'

const FILTER_LABELS: Record<DisplayFilterKind, string> = {
  none: 'Off',
  crt: 'CRT',
}

/** In the order they're listed. Keyed by `CrtOptions`, so a new option
 * without a label here is a type error. */
const CRT_OPTION_LABELS: Record<keyof CrtOptions, string> = {
  scanlines: 'Scanlines',
  curvature: 'Screen curvature',
  chromaticAberration: 'Chromatic aberration',
  vignette: 'Vignette',
}
const CRT_OPTIONS = Object.keys(CRT_OPTION_LABELS) as (keyof CrtOptions)[]

interface DisplaySettingsProps {
  settings: DisplayFilterSettings
  onChange: (next: DisplayFilterSettings) => void
  /** Which renderer the emulator stood up, or `null` until it says. */
  renderer: RendererKind | null
}

/**
 * The rail's Display panel: which filter the picture is drawn through, and
 * the selected filter's own options.
 *
 * Only the selected filter's options are shown. With one filter that's a
 * small saving; with several it's what keeps this panel from listing every
 * filter's controls at once. Switching filter therefore grows or shrinks
 * the panel -- but only below the radio that was just clicked, so nothing
 * moves under the pointer.
 *
 * Filters only exist on the WebGPU renderer (see `renderer.ts`'s Canvas 2D
 * `setDisplay`), so on Canvas 2D the panel stays visible but disabled, with
 * a line saying why. That line names no backend: ENG-93 keeps renderer
 * names out of the UI except behind `?debug`.
 */
export function DisplaySettings({ settings, onChange, renderer }: DisplaySettingsProps) {
  const enabled = renderer === 'webgpu'

  return (
    <section className="display-settings" aria-label="Display">
      <h2>Display</h2>
      <fieldset className="display-filter" disabled={!enabled}>
        <legend>Filter</legend>
        {DISPLAY_FILTERS.map((filter) => (
          <label key={filter}>
            <input
              type="radio"
              name="display-filter"
              value={filter}
              checked={settings.filter === filter}
              onChange={() => onChange({ ...settings, filter })}
            />
            {FILTER_LABELS[filter]}
          </label>
        ))}
      </fieldset>
      {settings.filter === 'crt' && (
        <fieldset className="display-options" disabled={!enabled}>
          <legend>CRT</legend>
          {CRT_OPTIONS.map((option) => (
            <label key={option}>
              <input
                type="checkbox"
                checked={settings.crt[option]}
                onChange={(event) => onChange({ ...settings, crt: { ...settings.crt, [option]: event.target.checked } })}
              />
              {CRT_OPTION_LABELS[option]}
            </label>
          ))}
        </fieldset>
      )}
      {renderer === 'canvas2d' && <p className="display-note">Filters are not available in this browser.</p>}
    </section>
  )
}
