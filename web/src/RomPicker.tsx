import type { RomLoad } from './useRomLoader'

/**
 * ENG-77's ROM-loading controls: the picker button and the result
 * readout. The loading itself lives in `useRomLoader.ts`.
 */

/**
 * The picker button: a real `<input type="file">` under a `<label>`, so it
 * stays keyboard-reachable and announces itself -- which is why
 * drag-and-drop alone was never an option, only an addition. The input is
 * laid over the label at full size with `opacity: 0` rather than
 * `display: none` (see `.rom-picker input` in `App.css`): a zero-size
 * element is unreachable by Playwright's `setInputFiles` too.
 */
export function RomPicker({ onPick, disabled }: { onPick: (file: File) => void; disabled: boolean }) {
  return (
    <label className="rom-picker flag">
      --rom
      <input
        type="file"
        accept=".nes"
        // The visible label is the CLI flag the app bar is typeset around;
        // `--rom` read aloud is not a label. The accessible name says what
        // the control does, the visible text says where it lives.
        aria-label="Load ROM"
        disabled={disabled}
        onChange={(event) => {
          const file = event.target.files?.[0]
          if (file) onPick(file)
          // Cleared so picking the *same* file twice still fires `change`
          // -- otherwise "load it again to restart it" silently does
          // nothing, which reads as a broken button.
          event.target.value = ''
        }}
      />
    </label>
  )
}

/** The load readout: what's playing, or why the last pick didn't take. */
export function RomLoadReadout({ romLoad, onDismiss }: { romLoad: RomLoad | null; onDismiss: () => void }) {
  if (!romLoad) return null
  if (!romLoad.error) return <p className="rom-readout">cartridge &#183; {romLoad.name}</p>
  return (
    <p className="rom-error" role="alert">
      <span>
        {romLoad.name}: {romLoad.error}
      </span>
      <button type="button" className="rom-error-dismiss" onClick={onDismiss} aria-label="Dismiss">
        ×
      </button>
    </p>
  )
}
