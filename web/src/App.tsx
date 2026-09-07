import { EmulatorScreen } from './EmulatorScreen'
import './App.css'

function App() {
  return (
    <main id="center">
      <h1>NES emulator</h1>
      {/* Renders its own `AudioOutput` control -- see `EmulatorScreen.tsx`'s
          module doc comment: video and audio now share one Worker/wasm
          instance, so audio setup needs the same worker reference video
          does, not a sibling of its own. */}
      <EmulatorScreen />
      <p className="controls">
        <kbd>&larr;&uarr;&darr;&rarr;</kbd> D-pad &nbsp;·&nbsp; <kbd>Z</kbd> B &nbsp;·&nbsp; <kbd>X</kbd> A
        &nbsp;·&nbsp; <kbd>Enter</kbd> Start &nbsp;·&nbsp; <kbd>Shift</kbd> Select &nbsp;·&nbsp; gamepad supported
      </p>
    </main>
  )
}

export default App
