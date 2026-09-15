/**
 * ENG-90's volume/mute persistence. Main-thread-only and orthogonal to the
 * `AudioWorkletNode`/ring pipeline entirely: this is the `GainNode`
 * `AudioOutput.tsx` inserts between the worklet and `destination`, and
 * nothing here crosses `postMessage` or touches the Worker.
 *
 * `localStorage`, not IndexedDB: `saveStore.ts`'s reasoning for IndexedDB
 * (ENG-61's per-`(rom_hash, slot)` blobs blowing past `localStorage`'s
 * ~5MB origin-wide ceiling) doesn't apply to two small, ROM-independent
 * scalars, and `localStorage`'s synchronous API is a better fit for a
 * value read once on mount and written on every slider tick.
 */

const STORAGE_KEY = 'emu.audio.volume'

/** The default a first-ever visit gets: full volume, unmuted -- silence
 * should always be something the user chose, never the out-of-the-box
 * state of a brand new install. */
const DEFAULT_SETTINGS: VolumeSettings = { volume: 1, muted: false }

export interface VolumeSettings {
  /** 0..1. The level mute recovers *to* -- deliberately never overwritten
   * by muting itself, which is what makes mute "recoverable to the
   * previous level" rather than a second, competing volume control. */
  volume: number
  muted: boolean
}

/** Clamps to the `GainNode.gain`-legal `[0, 1]` range this app exposes
 * (the AudioParam itself allows more, but nothing here should ever ask for
 * louder-than-unity or negative gain), and folds `NaN`/`Infinity` -- e.g. a
 * hand-edited or corrupted `localStorage` value -- back to the default
 * rather than propagating a value that would silently mute the graph. */
export function clampVolume(value: number): number {
  if (!Number.isFinite(value)) return DEFAULT_SETTINGS.volume
  return Math.min(1, Math.max(0, value))
}

/** The actual gain to apply for a given settings pair. A tiny function,
 * but it's the one place "muted always wins, and unmuting reads back
 * `volume` rather than some separately-tracked last-gain" is stated once
 * instead of re-derived at every call site. */
export function effectiveGain(settings: VolumeSettings): number {
  return settings.muted ? 0 : settings.volume
}

/**
 * Reads persisted volume/mute, falling back to `DEFAULT_SETTINGS` for a
 * first visit, a value from an older/incompatible build, or a
 * `localStorage` that throws outright (blocked site data, some in-app
 * browser previews -- ENG-90's own guidance is explicit that this must not
 * crash the app either way).
 */
export function loadVolumeSettings(): VolumeSettings {
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    if (!raw) return { ...DEFAULT_SETTINGS }
    const parsed: unknown = JSON.parse(raw)
    if (!parsed || typeof parsed !== 'object') return { ...DEFAULT_SETTINGS }
    const { volume, muted } = parsed as Partial<VolumeSettings>
    return {
      volume: clampVolume(typeof volume === 'number' ? volume : DEFAULT_SETTINGS.volume),
      muted: typeof muted === 'boolean' ? muted : DEFAULT_SETTINGS.muted,
    }
  } catch {
    return { ...DEFAULT_SETTINGS }
  }
}

/** Writes back on every change. A failure here (same causes as
 * `loadVolumeSettings`'s) costs the setting surviving reload, never the
 * running session -- the caller's own state (and thus the live
 * `GainNode`) already has the new value regardless of whether it lands in
 * storage. */
export function saveVolumeSettings(settings: VolumeSettings): void {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ volume: clampVolume(settings.volume), muted: settings.muted }))
  } catch {
    // Blocked storage -- nothing to recover, and nothing the user can act
    // on from here.
  }
}
