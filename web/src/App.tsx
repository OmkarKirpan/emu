import { EmulatorScreen } from './EmulatorScreen'
import './App.css'

/**
 * The page shell. Deliberately thin: `EmulatorScreen` owns the Worker, the
 * wasm instance and every control that talks to them (see its module doc
 * comment -- video and audio share one Worker, so the audio button needs
 * the same worker reference video does), and it emits the app bar, the
 * stage and the rail as siblings of this layout's grid. What is left here
 * is the frame around them and the colophon.
 */
function App() {
  return (
    <div className="app">
      <EmulatorScreen />

      {/* Ft2 -- one line, hairline above, no columns. An emulator has no
          sitemap to catalogue; the only thing worth closing the page with
          is the control map, and even that is worth saying once. */}
      <footer className="colophon">
        <p className="keymap">
          <kbd>&larr;</kbd>
          <kbd>&uarr;</kbd>
          <kbd>&darr;</kbd>
          <kbd>&rarr;</kbd> move <span className="sep">&middot;</span> <kbd>Z</kbd> B{' '}
          <span className="sep">&middot;</span> <kbd>X</kbd> A <span className="sep">&middot;</span>{' '}
          <kbd>Enter</kbd> start <span className="sep">&middot;</span> <kbd>Shift</kbd> select
        </p>
        <p className="colophon-note">Gamepads work too &mdash; plug one in and press a button.</p>
      </footer>
    </div>
  )
}

export default App
