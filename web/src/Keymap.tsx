/**
 * ENG-93: the keyboard control map, factored out of the footer colophon so
 * the rail's `.controls-panel` (visible above the fold, not "buried" the way
 * the footer alone was) and the footer's own Ft2 line render the exact same
 * list rather than two hand-kept copies that can drift apart. `R`, `K` and
 * `-`/`=` are ENG-91's rewind/frame-step/speed controls -- built out in a
 * parallel worktree while this was written -- named here because the
 * control map has to be right the moment both branches land, not patched in
 * afterwards.
 *
 * Hidden on any coarse pointer via `.keymap`'s own media query in `App.css`
 * (unchanged from before this ticket): a touchscreen has no keyboard, and
 * `TouchControls.tsx`'s on-screen pad is the actual answer to "how do I play
 * this" there -- a keyboard legend would just send the reader looking for a
 * keyboard that isn't there.
 */
export function Keymap() {
  return (
    <p className="keymap">
      <kbd>&larr;</kbd>
      <kbd>&uarr;</kbd>
      <kbd>&darr;</kbd>
      <kbd>&rarr;</kbd> move <span className="sep">&middot;</span> <kbd>Z</kbd> B{' '}
      <span className="sep">&middot;</span> <kbd>X</kbd> A <span className="sep">&middot;</span>{' '}
      <kbd>Enter</kbd> start <span className="sep">&middot;</span> <kbd>Shift</kbd> select{' '}
      <span className="sep">&middot;</span> <kbd>P</kbd> pause <span className="sep">&middot;</span>{' '}
      <kbd>R</kbd> hold to rewind <span className="sep">&middot;</span> <kbd>K</kbd> frame-step (while paused){' '}
      <span className="sep">&middot;</span> <kbd>-</kbd>/<kbd>=</kbd> slower/faster
    </p>
  )
}
