//! Native-test-only determinism gate for ENG-65: boot the same ROM twice
//! from power-on, run both for the same number of cycles, and assert the
//! two machines are bit-identical.
//!
//! **What "bit-identical" means is not decided here.** It is exactly
//! `savestate.zig`'s ENG-61 save-state blob, hashed. ENG-61 specified that
//! from the start ("this format's serializer is the hashing mechanism
//! `assert_deterministic()` uses in the native test suite from day one"),
//! and until M8 this file carried a hand-written stand-in for it -- one
//! `hashCpu`/`hashPpu`/`hashApu`/`hashMapper` field list that had to be
//! extended by hand at every milestone, in lockstep with a serializer that
//! did not exist yet. Now there is only the serializer, and this file is
//! the two-runs-and-compare harness on top of it.
//!
//! The practical consequence is that the *state enumeration* -- what counts
//! as state, what is excluded as re-derivable (PRG/CHR-ROM, the APU's RC
//! filter cascade, the framebuffer), and why -- is documented in
//! `savestate.zig`'s module doc comment, not here. A field added to the
//! serializer is covered by this gate automatically, which is the drift
//! this collapse exists to make impossible.
//!
//! **Still no input log.** `assertDeterministic`'s two runs never drive any
//! controller input, so ENG-65's "given identical inputs" stays trivially
//! satisfied by there being no inputs in either run. A recorded
//! input-log/replay harness remains future work; the controllers'
//! architectural register state is hashed regardless, because the
//! serializer carries it.

const std = @import("std");
const testing = std.testing;

const savestate = @import("savestate.zig");
const Machine = @import("machine.zig").Machine;

pub const Digest = savestate.RomHash;

/// Scratch space for the serialized blob a digest is taken over. File-scope
/// rather than a local so a `hashState` call costs no 64KB stack frame, and
/// safe as a shared buffer because Zig's test runner is single-threaded and
/// nothing here retains a reference past the `Sha256` it feeds.
var scratch: [savestate.max_state_bytes]u8 = undefined;

/// Boot two independent machines from power-on against the same ROM bytes,
/// run each for exactly `cycles` CPU cycles, and assert their save-states
/// hash identically.
pub fn assertDeterministic(rom_bytes: []const u8, cycles: u64) !void {
    const a = try runAndHash(rom_bytes, cycles);
    const b = try runAndHash(rom_bytes, cycles);
    try testing.expectEqualSlices(u8, &a, &b);
}

fn runAndHash(rom_bytes: []const u8, cycles: u64) !Digest {
    var m: Machine = undefined;
    try m.init(rom_bytes);
    while (m.cpu.cycles < cycles) m.cpu.step();
    return hashState(&m);
}

/// Factored out of `runAndHash` so tests can hash two independently-built
/// machines directly -- e.g. to prove a specific field (PRG-RAM, CHR-RAM,
/// an APU latch) actually moves the digest, without needing two full
/// power-on runs that would otherwise stay bit-for-bit identical.
fn hashState(m: *const Machine) Digest {
    // The only failure mode is `NoSpace`, and `scratch` is `max_state_bytes`
    // -- the size the format is defined not to exceed.
    return savestate.hash(m, &scratch) catch unreachable;
}

test "assertDeterministic passes for a trivial NROM ROM run for a few thousand cycles" {
    var buf = [_]u8{0} ** (16 + 0x4000);
    buf[0] = 'N';
    buf[1] = 'E';
    buf[2] = 'S';
    buf[3] = 0x1A;
    buf[4] = 1; // 16KB PRG
    buf[5] = 0; // CHR-RAM
    // Reset vector -> $8000, an infinite NOP sled.
    buf[16 + 0x3FFC] = 0x00;
    buf[16 + 0x3FFD] = 0x80;
    try assertDeterministic(&buf, 10_000);
}

test "runAndHash produces different hashes for genuinely different runs" {
    var buf = [_]u8{0} ** (16 + 0x4000);
    buf[0] = 'N';
    buf[1] = 'E';
    buf[2] = 'S';
    buf[3] = 0x1A;
    buf[4] = 1;
    buf[5] = 0;
    buf[16 + 0x3FFC] = 0x00;
    buf[16 + 0x3FFD] = 0x80;
    // LDA #$42 at $8000, so A differs from an untouched NOP sled.
    buf[16] = 0xA9;
    buf[17] = 0x42;

    const short = try runAndHash(&buf, 10);
    const long = try runAndHash(&buf, 10_000);
    try testing.expect(!std.mem.eql(u8, &short, &long));
}

fn minimalNromBuf() [16 + 0x4000]u8 {
    var buf = [_]u8{0} ** (16 + 0x4000);
    buf[0] = 'N';
    buf[1] = 'E';
    buf[2] = 'S';
    buf[3] = 0x1A;
    buf[4] = 1; // 16KB PRG
    buf[5] = 0; // CHR-RAM
    buf[16 + 0x3FFC] = 0x00;
    buf[16 + 0x3FFD] = 0x80; // reset vector -> $8000, an infinite NOP sled
    return buf;
}

test "the hash changes if the cartridge's PRG-RAM (the vendored ROMs' \\$6000 result-code RAM) differs" {
    // ENG-79 moved the *addressing* of $6000-$7FFF onto the mapper while
    // leaving the bytes in `Bus.prg_ram`; `savestate.zig` carries the bytes
    // in its `sram` section and the mapper's own addressing registers in
    // its mapper section, so poking a byte here still has to move the
    // digest.
    const buf = minimalNromBuf();
    var a_machine: Machine = undefined;
    try a_machine.init(&buf);

    var b_machine: Machine = undefined;
    try b_machine.init(&buf);
    b_machine.bus.prg_ram[0] = 0xFF; // the only difference from a_machine

    const a = hashState(&a_machine);
    const b = hashState(&b_machine);
    try testing.expect(!std.mem.eql(u8, &a, &b));
}

test "the hash changes if a CHR-RAM cartridge's CHR contents differ" {
    const buf = minimalNromBuf(); // CHR size 0 -> CHR-RAM, per rom.zig
    var a_machine: Machine = undefined;
    try a_machine.init(&buf);

    var b_machine: Machine = undefined;
    try b_machine.init(&buf);
    b_machine.bus.mapper.nrom.chr[0] = 0xFF; // the only difference from a_machine

    const a = hashState(&a_machine);
    const b = hashState(&b_machine);
    try testing.expect(!std.mem.eql(u8, &a, &b));
}

test "the hash does NOT change if a CHR-ROM cartridge's CHR contents differ (ENG-61: CHR-ROM is not serialized)" {
    var buf = minimalNromBuf();
    buf[5] = 1; // 8KB CHR-ROM instead of CHR-RAM
    var full: [16 + 0x4000 + 0x2000]u8 = [_]u8{0} ** (16 + 0x4000 + 0x2000);
    @memcpy(full[0 .. 16 + 0x4000], &buf);
    var a_machine: Machine = undefined;
    try a_machine.init(&full);

    var b_machine: Machine = undefined;
    try b_machine.init(&full);
    b_machine.bus.mapper.nrom.chr[0] = 0xFF; // CHR-ROM: mutating the copy must not move the hash

    const a = hashState(&a_machine);
    const b = hashState(&b_machine);
    try testing.expect(std.mem.eql(u8, &a, &b));
}

test "the hash changes if controller state (ENG-68) differs" {
    const buf = minimalNromBuf();
    var a_machine: Machine = undefined;
    try a_machine.init(&buf);

    var b_machine: Machine = undefined;
    try b_machine.init(&buf);
    b_machine.bus.controllers[0].setButtons(0x01); // the only difference from a_machine

    const a = hashState(&a_machine);
    const b = hashState(&b_machine);
    try testing.expect(!std.mem.eql(u8, &a, &b));
}

test "the hash changes if APU channel state (ENG-71) differs" {
    const buf = minimalNromBuf();
    var a_machine: Machine = undefined;
    try a_machine.init(&buf);

    var b_machine: Machine = undefined;
    try b_machine.init(&buf);
    b_machine.bus.apu.pulse1.envelope.volume_or_period = 5; // the only difference

    const a = hashState(&a_machine);
    const b = hashState(&b_machine);
    try testing.expect(!std.mem.eql(u8, &a, &b));
}

test "the APU hash covers sweep configuration, not just the sweep divider (ENG-71)" {
    const buf = minimalNromBuf();
    var a_machine: Machine = undefined;
    try a_machine.init(&buf);

    var b_machine: Machine = undefined;
    try b_machine.init(&buf);
    b_machine.bus.apu.pulse1.sweep_shift = 3; // decides the next target period

    const a = hashState(&a_machine);
    const b = hashState(&b_machine);
    try testing.expect(!std.mem.eql(u8, &a, &b));
}

test "the APU hash distinguishes an empty DMC sample buffer from one holding 0x00" {
    const buf = minimalNromBuf();
    var a_machine: Machine = undefined;
    try a_machine.init(&buf);

    var b_machine: Machine = undefined;
    try b_machine.init(&buf);
    b_machine.bus.apu.dmc.sample_buffer = 0x00; // was null

    const a = hashState(&a_machine);
    const b = hashState(&b_machine);
    try testing.expect(!std.mem.eql(u8, &a, &b));
}

test "the APU hash covers the frame sequencer's pending-reset and deferred-half-frame latches" {
    const buf = minimalNromBuf();
    var a_machine: Machine = undefined;
    try a_machine.init(&buf);

    var b_machine: Machine = undefined;
    try b_machine.init(&buf);
    b_machine.bus.apu.frame.half_frame_pending = true;

    const a = hashState(&a_machine);
    const b = hashState(&b_machine);
    try testing.expect(!std.mem.eql(u8, &a, &b));

    var c_machine: Machine = undefined;
    try c_machine.init(&buf);
    c_machine.bus.apu.frame.reset_delay = 3;
    const c = hashState(&c_machine);
    try testing.expect(!std.mem.eql(u8, &a, &c));
}

test "the hash does NOT change if only the APU's RC filter state differs (savestate.zig's one deliberate omission)" {
    const buf = minimalNromBuf();
    var a_machine: Machine = undefined;
    try a_machine.init(&buf);

    var b_machine: Machine = undefined;
    try b_machine.init(&buf);
    // A pure function of the mixed channel output both machines already
    // agree on -- see `savestate.zig`'s module doc comment for why keeping
    // `f32`s out of the digest is the point, not an oversight.
    b_machine.bus.apu.lpf.prev_out = 0.25;
    b_machine.bus.apu.output_sample = 0.5;

    const a = hashState(&a_machine);
    const b = hashState(&b_machine);
    try testing.expect(std.mem.eql(u8, &a, &b));
}
