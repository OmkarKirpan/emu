import type { ComponentType } from 'react'
import {
  CRT_OPTIONS,
  DISPLAY_FILTERS,
  type CrtOptions,
  type DisplayFilterKind,
  type DisplayFilterSettings,
} from '../emulator/displayFilter'

const FILTER_LABELS: Record<DisplayFilterKind, string> = {
  none: 'Off',
  crt: 'CRT',
}

const CRT_OPTION_LABELS: Record<keyof CrtOptions, string> = {
  scanlines: 'Scanlines',
  curvature: 'Screen curvature',
  chromaticAberration: 'Chromatic aberration',
  vignette: 'Vignette',
}

interface OptionsPanelProps {
  settings: DisplayFilterSettings
  onChange: (next: DisplayFilterSettings) => void
  disabled: boolean
}

function CrtOptionsPanel({ settings, onChange, disabled }: OptionsPanelProps) {
  return (
    <fieldset className="display-options" disabled={disabled}>
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
  )
}

/** Each filter's own options, shown while it is selected. Keyed by every
 * filter kind, so a new filter has to say whether it has any. */
const OPTIONS_PANELS: Record<DisplayFilterKind, ComponentType<OptionsPanelProps> | null> = {
  none: null,
  crt: CrtOptionsPanel,
}

interface DisplaySettingsProps {
  settings: DisplayFilterSettings
  onChange: (next: DisplayFilterSettings) => void
  /** The filters the emulator reported it can apply (`FrameRenderer.
   * filters`), or `null` until it has said. */
  filters: readonly DisplayFilterKind[] | null
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
 * Everything is disabled, with no explanation, until the emulator reports
 * which filters it can apply -- a moment during boot. After that, a filter
 * it can't apply (all of them on Canvas 2D; one whose shader didn't compile
 * on this GPU) stays visible but disabled, with a line naming it. That line
 * names no backend: ENG-93 keeps renderer names out of the UI except behind
 * `?debug`.
 */
export function DisplaySettings({ settings, onChange, filters }: DisplaySettingsProps) {
  const available = (filter: DisplayFilterKind) => filters?.includes(filter) ?? false
  const unavailable = filters ? DISPLAY_FILTERS.filter((filter) => !available(filter)) : []
  const OptionsPanel = OPTIONS_PANELS[settings.filter]

  return (
    <section className="display-settings" aria-label="Display">
      <h2>Display</h2>
      <fieldset className="display-filter">
        <legend>Filter</legend>
        {DISPLAY_FILTERS.map((filter) => (
          <label key={filter}>
            <input
              type="radio"
              name="display-filter"
              value={filter}
              checked={settings.filter === filter}
              disabled={!available(filter)}
              onChange={() => onChange({ ...settings, filter })}
            />
            {FILTER_LABELS[filter]}
          </label>
        ))}
      </fieldset>
      {OptionsPanel && (
        <OptionsPanel settings={settings} onChange={onChange} disabled={!available(settings.filter)} />
      )}
      {unavailable.length > 0 && (
        <p className="display-note">
          Not available in this browser: {unavailable.map((filter) => FILTER_LABELS[filter]).join(', ')}.
        </p>
      )}
    </section>
  )
}
