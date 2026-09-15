/**
 * Shared "when" formatter for the rail's small machine-written timestamps --
 * `SaveStates.tsx`'s slot/battery/resume rows and `RomLibrary.tsx`'s
 * last-played column all read the same way. Split out from `SaveStates.tsx`
 * (where it first lived, ENG-76) by ENG-89 once a second component needed
 * the identical rule, rather than each carrying its own copy that could
 * drift apart.
 *
 * Today's timestamps read as a time, older ones as a date: "3:41 PM" stops
 * being useful information the moment the day it happened on ends, and
 * "Sep 12" stops being useful information on the day it happened.
 */
export function formatWhen(when: number): string {
  const date = new Date(when)
  const today = new Date().toDateString() === date.toDateString()
  return today
    ? date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
    : date.toLocaleDateString([], { month: 'short', day: 'numeric' })
}
