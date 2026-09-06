/**
 * The audio ring's control-block byte layout, as a shared constant for the
 * JS-side code that's actually able to import it. Mirrors
 * `core/src/audio_ring.zig`'s `ControlBlock` `extern struct` exactly: three
 * `i32` fields, each pinned to its own `CACHE_LINE_BYTES`-byte line so the
 * producer's and consumer's writes never false-share a cache line.
 *
 * `testToneProcessor.js` -- the actual consumer -- can't import this: it
 * runs as an `AudioWorkletProcessor` module with no bundler transform
 * applied (see that file's own module comment for why it's plain JS), so it
 * hardcodes its own literal copy instead, cross-referenced by comment back
 * to this file and to `audio_ring.zig`. Everything else on the JS side
 * (this Worker's own debug/stats reads) should import from here rather
 * than adding a third hand-copied literal.
 */
export const CACHE_LINE_BYTES = 64
const INT32S_PER_LINE = CACHE_LINE_BYTES / 4

export const READ_INDEX = 0
export const WRITE_INDEX = INT32S_PER_LINE
export const UNDERRUN_COUNT = INT32S_PER_LINE * 2
export const CONTROL_INT32_LENGTH = INT32S_PER_LINE * 3
