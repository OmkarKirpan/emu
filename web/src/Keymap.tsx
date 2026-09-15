/**
 * ENG-93: the keyboard control map, factored out of the footer colophon so
 * the rail's `.controls-panel` (visible above the fold, not "buried" the way
 * the footer alone was) and the footer's own Ft2 line render the exact same
 * list rather than two hand-kept copies that can drift apart. `R`, `K` and
 * `-`/`=` are ENG-91's rewind/frame-step/speed controls.
 *
 * Data first, markup second, because the two homes lay the same list out
 * differently: the footer runs it as one `·`-separated line, while the rail
 * is too narrow for that -- it wrapped mid-binding, stranding a key at the
 * end of one line and its action at the start of the next -- so there each
 * binding gets its own row, keys in one column and the action in the other
 * (see `.controls-panel .keymap` in `App.css`). Each binding is its own
 * element either way, which is what lets the footer wrap *between* bindings
 * instead of inside one.
 *
 * Hidden on any coarse pointer via `.keymap`'s own media query in `App.css`
 * (unchanged from before this ticket): a touchscreen has no keyboard, and
 * `TouchControls.tsx`'s on-screen pad is the actual answer to "how do I play
 * this" there -- a keyboard legend would just send the reader looking for a
 * keyboard that isn't there.
 */
const BINDINGS: ReadonlyArray<{ keys: readonly string[]; joiner?: string; action: string }> = [
  { keys: ['←', '↑', '↓', '→'], action: 'move' },
  { keys: ['Z'], action: 'B' },
  { keys: ['X'], action: 'A' },
  { keys: ['Enter'], action: 'start' },
  { keys: ['Shift'], action: 'select' },
  { keys: ['P'], action: 'pause' },
  { keys: ['R'], action: 'hold to rewind' },
  { keys: ['K'], action: 'frame-step (while paused)' },
  { keys: ['-', '='], joiner: '/', action: 'slower / faster' },
]

export function Keymap() {
  return (
    <p className="keymap">
      {BINDINGS.map(({ keys, joiner, action }, i) => (
        <span key={action} className="keymap-binding">
          {i > 0 && (
            <span className="sep" aria-hidden="true">
              &middot;
            </span>
          )}
          <span className="keymap-keys">
            {keys.map((key, k) => (
              <span key={key}>
                {k > 0 && joiner}
                <kbd>{key}</kbd>
              </span>
            ))}
          </span>
          <span className="keymap-action">{action}</span>
        </span>
      ))}
    </p>
  )
}
