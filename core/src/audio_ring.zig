//! ENG-62's lock-free single-producer/single-consumer audio ring buffer,
//! plus the M5 (ENG-70) stand-in producer: a wasm-side sine test-tone
//! generator with dynamic rate control (DRC). Real APU output (mixing,
//! anti-aliasing, decimation) is M6/ENG-71's job -- this module's whole
//! purpose is to prove the ring-buffer/worklet/atomics plumbing with a
//! signal that has no relationship to the emulated machine, so a plumbing
//! bug here can never be confused with an audio-content bug later.
//!
//! ## Producer/consumer split
//! This module is the *producer*: it owns `write_index` (only this file
//! writes it) and only ever reads `read_index` (never writes it). The
//! consumer -- `web/src/audio/testToneProcessor.js`, a pure-JS
//! `AudioWorkletProcessor` that never instantiates wasm -- is the mirror
//! image: owns `read_index`, only reads `write_index`, and owns
//! `underrun_count` outright (this module never touches it). See that
//! file for the consumer side of the protocol implemented here.
//!
//! Everything the producer touches (`write_index`'s plain reads,
//! `sample_accumulator`, `phase`, `fill_ema`) is safe as plain (non-atomic)
//! state precisely because `stepFrame` is only ever called synchronously,
//! from one thread (the Worker that owns this wasm instance) -- it is
//! never re-entrant and never runs concurrently with itself. Only the two
//! fields the *other* real OS thread (the browser's audio-rendering
//! thread, running the worklet) touches need actual atomic operations:
//! `read_index` (acquire-loaded here, release-stored there) and
//! `write_index` (release-stored here, acquire-loaded there).
//!
//! ## Control-block layout
//! `ControlBlock` is `extern struct` so its layout is exactly what a JS
//! `Int32Array` view over `get_audio_ring_control_ptr()` sees: `read_index`
//! at byte offset 0, `write_index` at `cache_line_bytes`, `underrun_count`
//! at `2 * cache_line_bytes`. Each field is pinned to its own cache line so
//! the producer's writes to `write_index` and the consumer's writes to
//! `read_index` never false-share one. Deliberately a protocol constant of
//! this file, not `std.atomic.cache_line` (which can vary by target/Zig
//! version): the JS side hardcodes the same number, and an ABI the two
//! sides silently disagree on because a stdlib constant moved under them is
//! exactly the kind of bug this comment exists to prevent.
const std = @import("std");

pub const cache_line_bytes = 64;

pub const ControlBlock = extern struct {
    read_index: i32 align(cache_line_bytes) = 0,
    write_index: i32 align(cache_line_bytes) = 0,
    underrun_count: i32 align(cache_line_bytes) = 0,
};

/// Power-of-two capacity so the slot index is `counter & (capacity - 1)`
/// instead of a modulo -- ENG-62's chosen geometry: ~171ms @ 48kHz, 32KiB.
pub const capacity: u32 = 8192;
comptime {
    std.debug.assert(std.math.isPowerOfTwo(capacity));
}

var ring: [capacity]f32 = [_]f32{0} ** capacity;
var control: ControlBlock = .{};

/// Test tone frequency (A4). Arbitrary but audible and easy to recognize
/// by ear -- there's no "correct" value since this signal has no
/// relationship to any emulated hardware.
const tone_hz: f32 = 440.0;
/// `std.math.tau` isn't relied on here so this file's numeric constants
/// stay independently checkable without the stdlib in front of you.
const tau: f32 = 6.283185307179586;

var device_sample_rate: f32 = 48000.0;
var phase: f32 = 0.0;

/// NTSC's true frame rate -- matches `EmulatorScreen.tsx`'s `NTSC_FRAME_MS`
/// exactly (deliberately not a round 60; see that file's comment). One
/// `stepFrame` call is defined to cover exactly one of these.
const nes_frames_per_sec: f32 = 60.0988;

/// Fractional accumulator for "samples per tick" -- mirrors
/// `EmulatorScreen.tsx`'s `pendingFrames` pattern for the same reason: the
/// nominal rate (e.g. 48000/60.0988 = ~798.7) isn't an integer, and
/// truncating it every tick instead of carrying the remainder forward
/// would systematically under-produce and drift the ring toward empty.
/// Invariant: always in `[0, 1)` after `stepFrame` returns, and never
/// negative going in -- `drcRatio` can only scale `nominal_per_tick` by a
/// small positive factor, so what's added here is always positive.
var sample_accumulator: f32 = 0.0;

/// EMA-smoothed ring fill, in samples -- feeds `drcRatio` below. Smoothing
/// (rather than reacting to the raw instantaneous fill every tick) is what
/// keeps the ratio's own clamp from being hit on ordinary scheduling
/// jitter that would otherwise self-correct a tick later anyway.
var fill_ema: f32 = 0.0;
const fill_ema_alpha: f32 = 0.1;

/// Target steady-state fill: ENG-62's chosen ~64ms of headroom, scaled to
/// whatever sample rate the host's `AudioContext` actually reports (ENG-62
/// specified this in time, ~64ms, not as a fixed sample count -- 3072
/// samples is that figure only at the 48kHz it was quoted against).
fn targetFill() f32 {
    return 3072.0 * (device_sample_rate / 48000.0);
}

/// DRC gain and hard clamp, per ENG-62: "an unclamped loop hunts and
/// produces audible pitch wobble, which is the main way DRC goes wrong."
const drc_k: f32 = 0.5;
const drc_clamp: f32 = 0.005; // ±0.5%

/// Resample ratio for this tick: 1.0 plus a small, clamped correction
/// toward `targetFill()`. Above target (e.g. right after a stall, once the
/// consumer catches up) -> ratio < 1, produce slightly fewer samples so the
/// backlog works itself down; below target -> ratio > 1, produce slightly
/// more to refill.
fn drcRatio() f32 {
    const target = targetFill();
    const deviation = (fill_ema - target) / target;
    const correction = std.math.clamp(drc_k * deviation, -drc_clamp, drc_clamp);
    return 1.0 - correction;
}

/// Resets all audio-subsystem state -- called once by `wasm.zig`'s `init`
/// export. Deliberately touches nothing outside this module (not
/// `g_machine`): the audio ring is its own subsystem, independent of
/// whatever ROM is or isn't loaded, per this file's module doc comment.
pub fn init(sample_rate: f32) void {
    device_sample_rate = sample_rate;
    phase = 0.0;
    sample_accumulator = 0.0;
    fill_ema = targetFill();
    control = .{};
    ring = [_]f32{0} ** capacity;
}

pub fn ringPtr() [*]f32 {
    return &ring;
}

pub fn controlPtr() *ControlBlock {
    return &control;
}

/// Advances the test tone by exactly one nominal NES frame's worth of
/// (DRC-adjusted) samples and publishes them. Called once per Worker tick
/// (~60Hz, timer-driven -- see `audioWorker.ts`) -- deliberately always
/// "one frame" per call, never a multi-frame catch-up burst: ENG-62 calls
/// for *resetting* the ring on a large scheduling gap (background-tab
/// throttling, `AudioContext` suspend/resume) rather than fast-forwarding
/// through it, and that reset is the consumer's job (it owns `read_index`)
/// -- see `testToneProcessor.js`.
pub fn stepFrame() void {
    const read = @atomicLoad(i32, &control.read_index, .acquire);
    const write = control.write_index; // producer-owned; plain load is fine (see module doc comment)
    const filled: u32 = @bitCast(write -% read);
    fill_ema += fill_ema_alpha * (@as(f32, @floatFromInt(filled)) - fill_ema);

    const nominal_per_tick = device_sample_rate / nes_frames_per_sec;
    sample_accumulator += nominal_per_tick * drcRatio();
    var n: u32 = @intFromFloat(@floor(sample_accumulator));
    sample_accumulator -= @floatFromInt(n);

    // Defensive belt, not the primary mechanism (DRC is): never advance
    // past the consumer and overwrite samples it hasn't read yet, even if
    // fill_ema hasn't caught up to a sudden change yet (e.g. right after
    // `init`, or right after the consumer's own resync).
    const free_space = if (filled >= capacity) 0 else capacity - filled;
    if (n > free_space) n = free_space;

    const phase_step = tau * tone_hz / device_sample_rate;
    const base: u32 = @bitCast(write);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        ring[(base +% i) & (capacity - 1)] = @sin(phase);
        phase += phase_step;
        if (phase >= tau) phase -= tau;
    }

    @atomicStore(i32, &control.write_index, write +% @as(i32, @bitCast(n)), .release);
}

const testing = std.testing;

/// Test-only stand-in for the consumer side of the protocol: advances
/// `read_index` by `n`, exactly as `testToneProcessor.js`'s `process()`
/// does after copying `n` samples out.
fn simulateConsumerRead(n: u32) void {
    const current = @atomicLoad(i32, &control.read_index, .acquire);
    @atomicStore(i32, &control.read_index, current +% @as(i32, @bitCast(n)), .release);
}

test "init resets the ring to empty with no underruns recorded" {
    init(48000.0);
    try testing.expectEqual(@as(i32, 0), control.read_index);
    try testing.expectEqual(@as(i32, 0), control.write_index);
    try testing.expectEqual(@as(i32, 0), control.underrun_count);
}

test "wraparound-safe unsigned difference across the i32/u32 boundary" {
    // `write` has just rolled over one step past `read` -- a plain signed
    // subtraction here would either trap (Debug/ReleaseSafe) or hand back
    // a nonsensical value; the `-%` + `@bitCast(u32)` idiom this mirrors
    // (matching the JS side's `(write - read) >>> 0`) must read this as
    // "1 sample apart", not as a huge negative or positive garbage value.
    const write: i32 = std.math.minInt(i32);
    const read: i32 = std.math.maxInt(i32);
    const filled: u32 = @bitCast(write -% read);
    try testing.expectEqual(@as(u32, 1), filled);
}

test "drcRatio never exceeds its documented ±0.5% clamp" {
    init(48000.0);
    fill_ema = 0.0; // maximally underfilled
    try testing.expect(drcRatio() <= 1.0 + drc_clamp);
    try testing.expect(drcRatio() >= 1.0 - drc_clamp);
    fill_ema = 1_000_000.0; // wildly overfull -- still must not exceed the clamp
    try testing.expect(drcRatio() <= 1.0 + drc_clamp);
    try testing.expect(drcRatio() >= 1.0 - drc_clamp);
}

test "production saturates at capacity rather than overwriting unread data" {
    init(48000.0);
    // 30 ticks at ~800 samples/tick is comfortably more than the 8192-sample
    // capacity with nothing ever draining it.
    var tick: u32 = 0;
    while (tick < 30) : (tick += 1) {
        stepFrame();
        const filled: u32 = @bitCast(control.write_index -% control.read_index);
        try testing.expect(filled <= capacity);
    }
    const filled: u32 = @bitCast(control.write_index -% control.read_index);
    try testing.expectEqual(capacity, filled);
}

test "DRC keeps the ring stable near target fill under a fixed-rate consumer" {
    init(48000.0);
    const fixed_drain: i32 = 798; // a fixed approximation of nominal, like a real device clock
    var tick: u32 = 0;
    while (tick < 500) : (tick += 1) {
        stepFrame();
        const filled_before_drain: u32 = @bitCast(control.write_index -% control.read_index);
        try testing.expect(filled_before_drain <= capacity);
        const drain = @min(fixed_drain, @as(i32, @bitCast(filled_before_drain)));
        simulateConsumerRead(@bitCast(drain));
    }
    // After 500 ticks (~8.3s) to settle, the ring should be neither empty
    // nor pinned at capacity -- proof DRC is actually correcting drift
    // toward target rather than just riding one clamp permanently.
    const settled_fill: u32 = @bitCast(control.write_index -% control.read_index);
    try testing.expect(settled_fill > 0 and settled_fill < capacity);
}
