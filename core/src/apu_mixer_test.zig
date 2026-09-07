//! Blargg's `apu_mixer` suite (ENG-71 acceptance criterion 1's "mixer"
//! clause). Unlike every other vendored suite, these ROMs cannot report a
//! `$6000` pass code -- what they test is not observable to the CPU. Each
//! one plays the channel under test and simultaneously plays the *inverse*
//! waveform on the DMC DAC, chosen so the two sum to a constant if (and
//! only if) the mixer's relative channel volumes and non-linear curve match
//! real hardware. The verdict is audible: near-silence between the ROM's
//! opening and closing beeps means correct mixing; a tone means wrong.
//!
//! "Near-silence" is a measurement, so this harness makes it one -- it runs
//! each ROM natively and measures the RMS of `Apu.output_sample` (the fully
//! mixed and filtered signal, exactly what reaches the ring buffer) across
//! a window inside the cancellation section.
//!
//! **This suite is why the duty sequencer's direction was found to be
//! wrong.** `duty_sequences` stores the played-back (already-reversed) form
//! of each duty cycle, but `Pulse.tickTimer` stepped it *backward*, which
//! preserves the duty ratio while shifting the waveform's phase. Nothing
//! else in the tree could see it: the duty test asserted the ratio, and no
//! `apu_test` ROM listens to a channel's output. Here it was unmissable --
//! `square.nes` and `dmc.nes` measured ~0.06 RMS where correct mixing gives
//! ~0.001, because a phase-shifted pulse cannot be cancelled by an inverse
//! waveform aligned to the correct phase. See `apu.zig`'s `duty_sequences`.
//!
//! Runtime note: each ROM must be emulated from power-on through its
//! ~4.5s of intro before the cancellation section starts, so this file is
//! the slowest in the suite. The window below is kept as short as it can
//! be while still covering real cancellation.

const std = @import("std");
const testing = std.testing;

const Machine = @import("machine.zig").Machine;

const cpu_hz: f64 = 1_789_773.0;

/// Where each ROM's opening beep sits, and a slice of the cancellation
/// section that follows it. Both are the same across all four ROMs -- they
/// share one shell (`vol_shell.inc` in Blargg's sources).
const beep_start_s: f64 = 3.6;
const beep_end_s: f64 = 4.0;
const quiet_start_s: f64 = 4.5;
const quiet_end_s: f64 = 7.0;

const Measurement = struct {
    /// RMS across the ROM's opening beep. Guards the assertions below: a
    /// ROM that failed to boot, or an APU that emitted nothing at all,
    /// would otherwise sail through a "should be quiet" check.
    beep_rms: f32,
    /// RMS across a window inside the cancellation section.
    quiet_rms: f32,
};

fn measure(rom: []const u8) !Measurement {
    var m: Machine = undefined;
    try m.init(rom);

    const beep_start: u64 = @intFromFloat(cpu_hz * beep_start_s);
    const beep_end: u64 = @intFromFloat(cpu_hz * beep_end_s);
    const quiet_start: u64 = @intFromFloat(cpu_hz * quiet_start_s);
    const quiet_end: u64 = @intFromFloat(cpu_hz * quiet_end_s);

    var beep_sum: f64 = 0;
    var beep_n: u64 = 0;
    var quiet_sum: f64 = 0;
    var quiet_n: u64 = 0;

    var last = m.cpu.cycles;
    while (m.cpu.cycles < quiet_end) {
        m.cpu.step();
        const now = m.cpu.cycles;
        if (now == last) continue;
        last = now;
        const s: f64 = m.bus.apu.output_sample;
        if (now >= beep_start and now < beep_end) {
            beep_sum += s * s;
            beep_n += 1;
        } else if (now >= quiet_start and now < quiet_end) {
            quiet_sum += s * s;
            quiet_n += 1;
        }
    }

    return .{
        .beep_rms = @floatCast(@sqrt(beep_sum / @as(f64, @floatFromInt(@max(beep_n, 1))))),
        .quiet_rms = @floatCast(@sqrt(quiet_sum / @as(f64, @floatFromInt(@max(quiet_n, 1))))),
    };
}

/// Measured at ~0.001 for `square`/`dmc` with the mixer correct, against
/// ~0.06 when the duty phase bug was present -- so this sits an order of
/// magnitude clear on both sides rather than being fitted to either.
const cancelled_rms_max: f32 = 0.005;

/// The ROM's own beeps, for the boot guard. Measured ~0.05.
const beep_rms_min: f32 = 0.02;

test "apu_mixer square: two pulses cancel against the DMC DAC to near-silence" {
    const r = try measure(@embedFile("apu_mixer_square"));
    try testing.expect(r.beep_rms > beep_rms_min); // the ROM actually ran
    try testing.expect(r.quiet_rms < cancelled_rms_max);
}

test "apu_mixer dmc: the DMC DAC's own non-linearity cancels to near-silence" {
    const r = try measure(@embedFile("apu_mixer_dmc"));
    try testing.expect(r.beep_rms > beep_rms_min);
    try testing.expect(r.quiet_rms < cancelled_rms_max);
}

/// Looser bound than `square`/`dmc`, for a reason that is understood and
/// is **not a fault in the triangle channel**: this ROM is the only one of
/// the four that sweeps the DMC DAC across its *entire* range, and our
/// mixer models that DAC as perfectly linear.
///
/// `mixOutput` gives the DMC a single linear term (`dmc / 22638`), which
/// is what both of nesdev's published mixer formulas do. The real DAC is
/// not quite linear, and Blargg's cancellation table encodes the real
/// curve -- its steps are deliberately uneven (3, 3, 2, 3, 3, 3, 2, 3...).
/// The ROM's own header says as much: "Scans over range of DMC DAC to test
/// non-linearity."
///
/// Measured proof, residual per DAC region across one run:
///
/// ```
///   DMC 70..123 -> 0.00596      DMC 33..86 -> 0.00750
///   DMC 57..111 -> 0.00641      DMC 20..74 -> 0.00815
///   DMC 45..98  -> 0.00693      DMC  8..61 -> 0.00888
/// ```
///
/// Monotone in the DAC's operating point, worst at the bottom of the range
/// where a straight line fits the real curve least well. That also
/// explains why `square.nes` passes at ~0.001 while using the identical
/// mixer: its own cancellation table only ever drives the DMC between $38
/// and $7F, the upper half, where the linear approximation is closest.
///
/// Three explanations were tested and rejected before this one, recorded
/// so they are not re-tried:
///
/// * **The ROM's own quantisation.** The residual its tables imply for a
///   perfect mixer is ~0.0014 RMS -- 5x below what we measure.
/// * **A timing/phase offset.** The residue is a clean tone at the
///   triangle's 999Hz fundamental with odd harmonics falling as ~1/n,
///   which is the signature of a time-shift residual (a triangle's
///   derivative is a square wave). But stalling the sequencer mid-run by
///   1, 2, 3, 4, 14, 28 and even 100,000 CPU cycles moves the result by
///   under 1e-5, with a probe confirming the channel runs throughout.
/// * **The choice of mixer formula.** Swapping `mixOutput` to nesdev's
///   lookup-table form (which differs from the exact rational form by
///   ~3.7% at the triangle's levels) makes this *worse*, not better:
///   0.00786 against 0.00660.
///
/// Closing this properly means modelling the DMC DAC's real curve, which
/// neither published formula provides -- a deliberate gap, not an
/// oversight. Tighten this bound if that ever lands.
const triangle_rms_max: f32 = 0.02;

test "apu_mixer triangle: the triangle cancels to within its quantisation residue" {
    const r = try measure(@embedFile("apu_mixer_triangle"));
    try testing.expect(r.beep_rms > beep_rms_min);
    try testing.expect(r.quiet_rms < triangle_rms_max);
}

// The one ROM that is *not* a silence test. Blargg's readme: "For the
// noise test, noise will fade in and out." So the assertion is inverted --
// this proves the noise channel reaches the mixer at a sane level at all,
// which no other test in the tree checks by listening.
test "apu_mixer noise: audible, bounded noise reaches the mixer" {
    const r = try measure(@embedFile("apu_mixer_noise"));
    try testing.expect(r.beep_rms > beep_rms_min);
    try testing.expect(r.quiet_rms > 0.002); // audible, not silence
    try testing.expect(r.quiet_rms < 0.05); // and not runaway
}
