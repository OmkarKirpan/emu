import { EmulatorScreen } from './EmulatorScreen'
import './App.css'

function App() {
  return (
    <main id="center">
      <h1>NES emulator</h1>
      <EmulatorScreen />
      <p className="controls">
        <kbd>&larr;&uarr;&darr;&rarr;</kbd> D-pad &nbsp;·&nbsp; <kbd>Z</kbd> B &nbsp;·&nbsp; <kbd>X</kbd> A
        &nbsp;·&nbsp; <kbd>Enter</kbd> Start &nbsp;·&nbsp; <kbd>Shift</kbd> Select
      </p>
    </main>
  )
}

export default App
