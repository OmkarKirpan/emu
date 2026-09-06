//! ENG-62's lock-free single-producer/single-consumer audio ring buffer.
//! Through M5 (ENG-70) the producer was a wasm-side sine test-tone
//! generator with dynamic rate control (DRC), proving the ring-buffer/
//! worklet/atomics plumbing with a signal that had no relationship to the
//! emulated machine. As of M6 (ENG-71) the producer is the real `Apu`:
//! `pushSample` is called once per CPU cycle from `Apu.tick` with that
//! cycle's fully mixed-and-filtered sample, decimates it down to the
//! device's sample rate via the same fractional-accumulator technique the
//! old sine generator used per-frame (just at per-cycle granularity now),
//! and pushes the result into the ring. `updateDrc` keeps the once-per-
//! frame DRC bookkeeping (`fill_ema`/`current_ratio`) that `pushSample`
//! reads.
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
//! `sample_accumulator`, `fill_ema`, `current_ratio`) is safe as plain
//! (non-atomic) state precisely because `pushSample`/`updateDrc` are only
//! ever called synchronously, from one thread (the Worker that owns this
//! wasm instance) -- never re-entrant, never running concurrently with
//! itself. Only the two fields the *other* real OS thread (the browser's
//! audio-rendering thread, running the worklet) touches need actual atomic
//! operations: `read_index` (acquire-loaded here, release-stored there) and
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

/// NTSC CPU clock -- matches `blargg_harness.zig`'s `cpu_hz` exactly (kept
/// as an independent, locally-checkable constant per this file's existing
/// convention -- see this file's module doc comment history for why
/// `tau` used to be duplicated the same way).
const cpu_hz: f32 = 1_789_773.0;

var device_sample_rate: f32 = 48000.0;

/// Cached once by `init`/`recomputeNominal`, so `pushSample` (called
/// ~1.79M times/sec) does one multiply instead of a division every call.
var nominal_per_cycle: f32 = 0;
var current_ratio: f32 = 1.0;

/// Re-derives `nominal_per_cycle` for the (possibly just-changed) device
/// sample rate -- called by `init`.
fn recomputeNominal() void {
    nominal_per_cycle = device_sample_rate / cpu_hz;
}

/// Fractional accumulator for "samples per CPU cycle" -- mirrors
/// `EmulatorScreen.tsx`'s `pendingFrames` pattern for the same reason: the
/// nominal rate isn't an integer, and truncating it every cycle instead of
/// carrying the remainder forward would systematically under-produce and
/// drift the ring toward empty. Invariant: always in `[0, 1)` after
/// `pushSample` returns, and never negative going in -- `drcRatio` can
/// only scale `nominal_per_cycle` by a small positive factor, so what's
/// added here is always positive.
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
    recomputeNominal();
    current_ratio = 1.0;
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

/// Called once per CPU cycle from `Apu.tick`, with that cycle's fully
/// mixed-and-filtered sample. Decimates via a fractional-accumulator
/// technique (mirroring the old per-frame sine generator, just at
/// per-cycle granularity now) -- `current_ratio` (refreshed once per video
/// frame by `updateDrc`, not recomputed here) is what DRC actually adjusts.
pub fn pushSample(raw: f32) void {
    sample_accumulator += nominal_per_cycle * current_ratio;
    if (sample_accumulator < 1.0) return;
    sample_accumulator -= 1.0;

    const read = @atomicLoad(i32, &control.read_index, .acquire);
    const write = control.write_index; // producer-owned; plain load is fine (see module doc comment)
    const filled: u32 = @bitCast(write -% read);
    if (filled >= capacity) return; // defensive belt, same as before

    ring[@as(u32, @bitCast(write)) & (capacity - 1)] = raw;
    @atomicStore(i32, &control.write_index, write +% 1, .release);
}

/// Called once per JS tick (~60Hz, via `wasm.zig`'s `step_audio_frame`
/// export -- name kept for ABI-comment continuity even though this no
/// longer produces samples itself, see `pushSample`). Refreshes
/// `fill_ema`/`current_ratio` for the *upcoming* frame's `pushSample`
/// calls -- a one-frame lag that's negligible against this loop's
/// multi-frame EMA time constant.
pub fn updateDrc() void {
    const read = @atomicLoad(i32, &control.read_index, .acquire);
    const write = control.write_index;
    const filled: u32 = @bitCast(write -% read);
    fill_ema += fill_ema_alpha * (@as(f32, @floatFromInt(filled)) - fill_ema);
    current_ratio = drcRatio();
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

test "pushSample saturates at capacity rather than overwriting unread data" {
    init(48000.0);
    var i: u32 = 0;
    // ~37 CPU cycles per output sample at 48kHz -- comfortably more than
    // capacity/nominal_per_cycle iterations overproduces past 8192 with
    // nothing draining it.
    while (i < capacity * 40) : (i += 1) pushSample(1.0);
    const filled: u32 = @bitCast(control.write_index -% control.read_index);
    try testing.expectEqual(capacity, filled);
}

test "pushSample produces roughly nominal_per_frame samples per simulated video frame" {
    init(48000.0);
    const cpu_cycles_per_frame = 29781; // ~1,789,773 / 60.0988
    var i: u32 = 0;
    while (i < cpu_cycles_per_frame) : (i += 1) pushSample(0.5);
    const filled: u32 = @bitCast(control.write_index -% control.read_index);
    // 48000/60.0988 ~= 798.7 -- allow slack for the fractional accumulator.
    try testing.expect(filled > 780 and filled < 820);
}

test "updateDrc's fill_ema/ratio still keeps a continuously-produced ring stable near target" {
    init(48000.0);
    const cpu_cycles_per_frame = 29781;
    const drain: i32 = 798;
    var frame: u32 = 0;
    while (frame < 500) : (frame += 1) {
        updateDrc();
        var i: u32 = 0;
        while (i < cpu_cycles_per_frame) : (i += 1) pushSample(0.5);
        const filled_before_drain: u32 = @bitCast(control.write_index -% control.read_index);
        try testing.expect(filled_before_drain <= capacity);
        const d = @min(drain, @as(i32, @bitCast(filled_before_drain)));
        simulateConsumerRead(@bitCast(d));
    }
    const settled: u32 = @bitCast(control.write_index -% control.read_index);
    try testing.expect(settled > 0 and settled < capacity);
}
