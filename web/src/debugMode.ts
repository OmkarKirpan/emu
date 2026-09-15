/**
 * ENG-93: `?debug` is the one switch that brings back every piece of author-
 * facing instrumentation the rest of this module removed from a first-time
 * visitor's view -- the renderer backend name (`EmulatorScreen.tsx`'s
 * `.renderer-readout`) and the audio ring/underrun telemetry
 * (`AudioOutput.tsx`'s `.audio-debug`). Presence-only, like
 * `EmulatorScreen.tsx`'s own `?renderer=` convention (see
 * `preferredRendererFromQuery`): `?debug`, `?debug=1` and `?debug=false` all
 * count, because this is a debugging affordance a person types by hand, not
 * an API with a value worth validating.
 *
 * Deliberately does not gate `window.__audioDebug__` / `window.__frameDebug__`
 * -- those are test hooks `e2e/helpers.ts` and `e2e/audio.spec.ts` depend on
 * unconditionally, not UI, and stay installed regardless of this flag.
 */
export function isDebugMode(): boolean {
  return new URLSearchParams(window.location.search).has('debug')
}
