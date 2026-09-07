// ENG-62's `AudioWorkletProcessor` -- the consumer half of the lock-free
// ring-buffer protocol whose producer half is `core/src/audio_ring.zig`,
// fed by the real APU as of ENG-71 (M6) rather than M5's sine test tone
// (see that file's module doc comment for the full picture and the
// division of ownership between the two sides).
//
// Deliberately plain JS with zero imports and zero wasm: `addModule()`
// loads this as a worklet module in `AudioWorkletGlobalScope`, which has no
// `fetch` and (per ENG-56) no clean story for a *second* wasm instance
// sharing one memory with the Worker's without manual per-thread stack
// partitioning -- sidestepped entirely by keeping this side of the boundary
// pure JS doing nothing but `Atomics` index bookkeeping and a `memcpy` into
// the output buffer. Loaded via `new URL('./audioRingProcessor.js',
// import.meta.url)` + `audioWorklet.addModule()` from the main thread (see
// `AudioOutput.tsx`) -- Vite's generic asset-URL handling, not its
// Worker-specific `?worker` import, since this isn't a Worker.
//
// ## Control-block layout
// Mirrors `audio_ring.zig`'s `ControlBlock` byte-for-byte: three `i32`
// fields, each pinned to its own `CACHE_LINE_BYTES`-byte line to avoid
// false sharing between this thread (owns `read_index`, writes
// `underrun_count`) and the Worker's wasm instance (owns `write_index`).
// Hardcoded here (rather than imported from `ringLayout.ts`, which states
// the same constants for the JS-side code that *can* import them) because
// this file runs as an `AudioWorkletProcessor` module with no bundler
// transform applied -- there's no import to make. This crosses the
// wasm/JS boundary the same way `controller.ts`'s button bit-layout does,
// by a comment cross-reference to the Zig source of truth, not a shared
// binding.
const CACHE_LINE_BYTES = 64
const INT32S_PER_LINE = CACHE_LINE_BYTES / 4
const READ_INDEX = 0
const WRITE_INDEX = INT32S_PER_LINE
const UNDERRUN_COUNT = INT32S_PER_LINE * 2
const CONTROL_INT32_LENGTH = INT32S_PER_LINE * 3

/** Same formula as `audio_ring.zig`'s `targetFill()`: ENG-62's ~64ms/3072-
 * sample target, scaled to whatever this `AudioContext`'s real `sampleRate`
 * is (the `sampleRate` global is provided by `AudioWorkletGlobalScope`). */
function targetFillSamples() {
  return Math.round(3072 * (sampleRate / 48000))
}

class AudioRingProcessor extends AudioWorkletProcessor {
  constructor() {
    super()
    /** @type {Float32Array | null} */
    this.ring = null
    /** @type {Int32Array | null} */
    this.control = null
    this.capacity = 0
    this.port.onmessage = (event) => this.handleMessage(event.data)
  }

  handleMessage(message) {
    switch (message.type) {
      case 'init':
        // The `SharedArrayBuffer` isn't transferred (SABs can't be --
        // they're shared, not moved); the Worker posts it as a plain,
        // structured-clone-shared argument, so this view and the Worker's
        // wasm instance's own view of `memory.buffer` back the same bytes.
        this.ring = new Float32Array(message.sab, message.ringByteOffset, message.capacity)
        this.control = new Int32Array(message.sab, message.controlByteOffset, CONTROL_INT32_LENGTH)
        this.capacity = message.capacity
        break
      case 'resync':
        this.resync()
        break
      default:
        break
    }
  }

  /**
   * ENG-62's "pathological desync" handling: on an `AudioContext`
   * suspend/resume (background tab, etc.), reset straight to target fill
   * rather than draining whatever stale backlog piled up -- refocusing a
   * tab must never produce a burst of sped-up audio. This is the
   * consumer's call to make (it owns `read_index`), triggered by
   * `AudioOutput.tsx`'s `onstatechange` handler via the Worker.
   */
  resync() {
    if (!this.control) return
    const write = Atomics.load(this.control, WRITE_INDEX)
    Atomics.store(this.control, READ_INDEX, (write - targetFillSamples()) | 0)
  }

  process(_inputs, outputs) {
    const channel = outputs[0]?.[0]
    if (!channel) return true

    if (!this.ring || !this.control) {
      channel.fill(0) // no `init` message yet -- silence, not garbage/uninitialized memory
      copyToRemainingChannels(outputs[0], channel)
      return true
    }

    const write = Atomics.load(this.control, WRITE_INDEX) // acquire: must see the producer's just-published samples
    const read = Atomics.load(this.control, READ_INDEX) // this thread's own last-published value
    const available = (write - read) >>> 0 // wraparound-safe unsigned distance, mirroring audio_ring.zig's `stepFrame`
    const need = channel.length
    const take = Math.min(available, need)
    const mask = this.capacity - 1

    for (let i = 0; i < take; i++) {
      channel[i] = this.ring[(read + i) & mask]
    }

    if (take < need) {
      // Underrun: ramp the last real sample (or silence, if `take` is 0)
      // down to zero across the shortfall instead of leaving whatever was
      // last in `channel` -- a hard discontinuity there is an audible
      // click; a short ramp isn't.
      const rampFrom = take > 0 ? channel[take - 1] : 0
      const shortfall = need - take
      for (let i = 0; i < shortfall; i++) {
        channel[take + i] = rampFrom * (1 - (i + 1) / shortfall)
      }
      Atomics.add(this.control, UNDERRUN_COUNT, 1)
    }

    Atomics.store(this.control, READ_INDEX, (read + take) | 0) // release: publish before the next producer tick reads it

    copyToRemainingChannels(outputs[0], channel)
    return true // keep this node alive indefinitely -- it has no natural end
  }
}

/** Mono source duplicated across every requested output channel, if the
 * node was ever given more than one (it isn't today -- `AudioOutput.tsx`
 * requests `outputChannelCount: [1]` -- but this keeps `process()` correct
 * if that ever changes without anyone remembering to revisit this file). */
function copyToRemainingChannels(outputChannels, channel0) {
  for (let c = 1; c < outputChannels.length; c++) {
    outputChannels[c].set(channel0)
  }
}

registerProcessor('audio-ring-processor', AudioRingProcessor)
