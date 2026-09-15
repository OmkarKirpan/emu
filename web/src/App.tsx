import { EmulatorScreen } from './EmulatorScreen'
import { Keymap } from './Keymap'
import './App.css'

/**
 * The page shell. Deliberately thin: `EmulatorScreen` owns the Worker, the
 * wasm instance and every control that talks to them (see its module doc
 * comment -- video and audio share one Worker, so the audio button needs
 * the same worker reference video does), and it emits the app bar, the
 * stage and the rail as siblings of this layout's grid. What is left here
 * is the frame around them and the colophon.
 *
 * ENG-93: the keymap this footer prints is no longer the *only* place it
 * lives -- `EmulatorScreen.tsx`'s rail now carries the same list (via
 * `Keymap.tsx`) above the fold, on the reasoning that a control map only the
 * footer states is a control map most players never scroll to. This line
 * stays anyway: a colophon is the conventional place a page states what it
 * is one last time, and removing it would have made the rail's copy the
 * *only* one, one component away from being buried again.
 */
function App() {
  return (
    <div className="app">
      <EmulatorScreen />

      {/* Ft2 -- one line, hairline above, no columns. An emulator has no
          sitemap to catalogue; the only thing worth closing the page with
          is the control map, and even that is worth saying once. */}
      <footer className="colophon">
        <Keymap />
        <p className="colophon-note">Gamepads work too &mdash; plug one in and press a button.</p>
      </footer>
    </div>
  )
}

export default App
