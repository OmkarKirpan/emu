/**
 * ENG-93: `?debug` is the one switch that brings back every piece of author-
 * facing instrumentation the rest of this module removed from a first-time
 * visitor's view -- the renderer backend name (`EmulatorScreen.tsx`'s
 * `.renderer-readout`) and the audio ring/underrun telemetry
 * (`AudioOutput.tsx`'s `.audio-debug`). A query parameter, like
 * `EmulatorScreen.tsx`'s `?renderer=` override (see
 * `preferredRendererFromQuery`), but unlike that one it is presence-only:
 * `?debug`, `?debug=1` and `?debug=false` all count. `?renderer=` has
 * two meaningful values to choose between; this is an on/off debugging
 * affordance a person types by hand, with no value worth validating.
 *
 * Deliberately does not gate `window.__audioDebug__` / `window.__frameDebug__`
 * -- those are test hooks `e2e/helpers.ts` and `e2e/audio.spec.ts` depend on
 * unconditionally, not UI, and stay installed regardless of this flag.
 */
export function isDebugMode(): boolean {
  return new URLSearchParams(window.location.search).has('debug')
}
