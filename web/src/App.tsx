import { AudioTestTone } from './audio/AudioTestTone'
import { EmulatorScreen } from './EmulatorScreen'
import './App.css'

function App() {
  return (
    <main id="center">
      <h1>NES emulator</h1>
      <EmulatorScreen />
      <p className="controls">
        <kbd>&larr;&uarr;&darr;&rarr;</kbd> D-pad &nbsp;·&nbsp; <kbd>Z</kbd> B &nbsp;·&nbsp; <kbd>X</kbd> A
        &nbsp;·&nbsp; <kbd>Enter</kbd> Start &nbsp;·&nbsp; <kbd>Shift</kbd> Select &nbsp;·&nbsp; gamepad supported
      </p>
      {/* ENG-70 (M5): the audio-plumbing slice, independent of the game
          above it -- see `audio/audioWorker.ts`'s module doc comment for
          why this is a separate wasm instance/Worker rather than folded
          into `EmulatorScreen`. */}
      <AudioTestTone />
    </main>
  )
}

export default App
