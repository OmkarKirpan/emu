//! Native-test-only determinism gate for ENG-65.
//!
//! The *full* save-state format (ENG-61) and IndexedDB persistence (M8) are
//! both out of scope here. What this hashes is deliberately just "the
//! currently-implemented slice of the ENG-61 state enumeration": CPU
//! architectural + interrupt-latch state, all of WRAM, and the PPU state a
//! mid-scanline resume would actually need -- registers, loopy `v`/`t`/`x`/
//! `w`, OAM + secondary OAM, nametables, palette RAM, and the background
//! shift-register/fetch-latch pipeline. Per ENG-65 itself: "the hash is
//! mostly CPU+WRAM ... naturally growing to cover more" as later milestones
//! add state -- this is that first, deliberately narrow slice, not an
//! oversight.
//!
//! **APU section (M6, ENG-71)**: `hashApu` covers every field of every
//! channel and of the frame sequencer that a mid-stream resume would have
//! to restore to keep producing bit-identical audio -- each channel's
//! enable bit, timer/period, length counter and full envelope state; both
//! pulses' complete sweep configuration; the triangle's linear counter and
//! reload latch; the noise LFSR and mode; the DMC's playback position,
//! output level, sample buffer and IRQ configuration; and the frame
//! sequencer's mode, cycle, pending-reset/deferred-half-frame latches and
//! IRQ state.
//!
//! Two deliberate omissions, both named rather than silent. **The RC
//! filter cascade's state** (`Apu.hpf1`/`hpf2`/`lpf`, and `output_sample`)
//! is not hashed: it is a pure function of the mixed channel outputs this
//! section already covers, so two runs that agree here cannot disagree
//! there, and hashing three `f32` pairs would make the digest sensitive to
//! floating-point rounding across targets for no gain in what it proves.
//! **`FrameSequencer.total_cycles`** is likewise skipped -- it only ever
//! feeds the even/odd parity of the next `$4017` write, and `cycle`
//! (hashed) already moves in lockstep with it. **Mapper section is CHR-RAM
//! only**: NROM has no bank-switch registers or IRQ counter, but per ENG-61
//! ("CHR-RAM contents where the mapper provides writable CHR (mutable;
//! CHR-ROM is not serialized -- static, reloadable from the ROM file)") its
//! CHR *is* mutable when the cartridge shipped no CHR-ROM (`Nrom.chr_is_ram`)
//! -- `Ppu.writeRegister`'s PPUDATA path can write pattern-table bytes into
//! it via `Mapper.chrWrite`. Hashed only in that case; CHR-ROM is skipped, as
//! ENG-61 specifies. A future mapper with bank-switch/IRQ state (MMC1/MMC3,
//! M7) will need its own section here too.
//!
//! **Controller state (ENG-68, M3)**: `hashControllers` now covers each
//! port's shift-register/strobe/latched-buttons state, on the same
//! "grows to cover more" basis. There is still no recorded input-log/replay
//! harness -- `assertDeterministic`'s two power-on runs never drive any
//! controller input, so "given identical inputs" stays trivially satisfied
//! by there being no inputs at all in either run. Building an event-log
//! replay mechanism remains future work this milestone doesn't need; what's
//! hashed here is just the architectural register state itself.

const std = @import("std");
const testing = std.testing;

const bus_mod = @import("bus.zig");
const cpu_mod = @import("cpu.zig");
const ppu_mod = @import("ppu.zig");
const apu_mod = @import("apu.zig");
const mapper_mod = @import("mapper.zig");
const controller_mod = @import("controller.zig");
const Machine = @import("machine.zig").Machine;

const Sha256 = std.crypto.hash.sha2.Sha256;
pub const Digest = [Sha256.digest_length]u8;

/// Boot two independent `Bus`+`Cpu` pairs from power-on against the same ROM
/// bytes, run each for exactly `cycles` CPU cycles, hash the state slice
/// described above, and assert the two hashes match.
pub fn assertDeterministic(rom_bytes: []const u8, cycles: u64) !void {
    const a = try runAndHash(rom_bytes, cycles);
    const b = try runAndHash(rom_bytes, cycles);
    try testing.expectEqualSlices(u8, &a, &b);
}

fn runAndHash(rom_bytes: []const u8, cycles: u64) !Digest {
    var m: Machine = undefined;
    try m.init(rom_bytes);
    while (m.cpu.cycles < cycles) m.cpu.step();
    return hashState(&m.cpu, &m.bus);
}

/// Factored out of `runAndHash` so tests can hash two independently-built
/// `Cpu`+`Bus` pairs directly -- e.g. to prove a specific field (PRG-RAM,
/// CHR-RAM) actually changes the digest, without needing two full power-on
/// runs that would otherwise stay bit-for-bit identical.
fn hashState(cpu: *const cpu_mod.Cpu, bus: *const bus_mod.Bus) Digest {
    var hasher = Sha256.init(.{});
    hashCpu(&hasher, cpu);
    hasher.update(&bus.wram);
    hasher.update(&bus.prg_ram);
    hashPpu(&hasher, &bus.ppu);
    hashMapper(&hasher, &bus.mapper);
    hashControllers(&hasher, &bus.controllers);
    hashApu(&hasher, &bus.apu);

    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

fn hashCpu(hasher: *Sha256, cpu: *const cpu_mod.Cpu) void {
    hasher.update(&[_]u8{ cpu.a, cpu.x, cpu.y, cpu.s, cpu.p.toByte() });
    hasher.update(std.mem.asBytes(&cpu.pc));
    hasher.update(&[_]u8{
        @intFromBool(cpu.nmi_line),
        @intFromBool(cpu.nmi_pending),
        @intFromBool(cpu.irq_line),
        @intFromBool(cpu.jammed),
        @intFromBool(cpu.irq_ready),
    });
}

fn hashPpu(hasher: *Sha256, p: *const ppu_mod.Ppu) void {
    hasher.update(&[_]u8{
        @as(u8, @bitCast(p.ctrl)),
        @as(u8, @bitCast(p.mask)),
        p.status.toByte(),
        p.oam_addr,
        @intFromBool(p.w),
        @as(u8, p.fine_x),
        @intFromBool(p.suppress_vbl_this_frame),
        p.read_buffer,
        p.data_bus,
        p.bg_next_tile_id,
        p.bg_next_tile_attr,
        p.bg_next_tile_lo,
        p.bg_next_tile_hi,
    });
    // The one-dot PPUCTRL/PPUMASK latch delay (`Ppu.applyPendingLatches`)
    // is real mid-cycle state a resume would have to restore: `$FF` here
    // stands for "nothing pending", distinct from a pending write of any
    // real byte value.
    hasher.update(&[_]u8{
        p.pending_ctrl orelse 0xFF,
        @intFromBool(p.pending_ctrl != null),
        p.pending_mask orelse 0xFF,
        @intFromBool(p.pending_mask != null),
    });
    hasher.update(std.mem.asBytes(&p.v));
    hasher.update(std.mem.asBytes(&p.t));
    hasher.update(std.mem.asBytes(&p.bg_shift_pattern_lo));
    hasher.update(std.mem.asBytes(&p.bg_shift_pattern_hi));
    hasher.update(std.mem.asBytes(&p.bg_shift_attr_lo));
    hasher.update(std.mem.asBytes(&p.bg_shift_attr_hi));
    hasher.update(std.mem.asBytes(&p.scanline));
    hasher.update(std.mem.asBytes(&p.dot));
    hasher.update(std.mem.asBytes(&p.frame));
    hasher.update(&p.vram);
    hasher.update(&p.palette);
    hasher.update(&p.oam);
    hasher.update(&p.secondary_oam);
    // ENG-68 (M3): the sprite pipeline's per-scanline derived state. Purely
    // a deterministic function of OAM+registers+scanline, so two power-on
    // runs would already hash identically without this -- included anyway
    // for ENG-61's "mid-scanline-resumable state" completeness, same spirit
    // as `secondary_oam` above.
    hasher.update(&[_]u8{
        p.sprite_count,
        p.secondary_count,
        @intFromBool(p.secondary_has_sprite0),
        @intFromBool(p.overflow_dot != null),
    });
    hasher.update(std.mem.asBytes(&(p.overflow_dot orelse @as(u16, 0))));
    for (p.sprite_units[0..p.sprite_count]) |su| {
        hasher.update(&[_]u8{
            su.x,
            su.pattern_lo,
            su.pattern_hi,
            @as(u8, su.palette),
            @intFromBool(su.behind_bg),
            @intFromBool(su.is_sprite0),
        });
    }
}

/// ENG-68 (M3): controller shift-register state. Per `determinism.zig`'s
/// own module doc comment, there is still no recorded input-log/replay
/// harness (that remains future work) -- `assertDeterministic`'s two
/// power-on runs never drive controller input, so `buttons` stays 0 in
/// both -- but the architectural *register* state introduced this
/// milestone belongs in the hash on the same "grows to cover more as later
/// milestones add state" basis every other section here does.
fn hashControllers(hasher: *Sha256, controllers: *const [2]controller_mod.Controller) void {
    for (controllers) |c| {
        hasher.update(&[_]u8{ c.buttons, c.shift, @intFromBool(c.strobe) });
    }
}

/// ENG-71 (M6): APU channel/frame-sequencer state. See the module doc
/// comment for the two deliberate omissions (filter state, `total_cycles`).
fn hashApu(hasher: *Sha256, a: *const apu_mod.Apu) void {
    hashPulse(hasher, &a.pulse1);
    hashPulse(hasher, &a.pulse2);

    hasher.update(&[_]u8{
        @intFromBool(a.triangle.enabled),       a.triangle.length_counter,
        a.triangle.linear_counter,              a.triangle.linear_reload_value,
        @intFromBool(a.triangle.linear_reload_flag), @intFromBool(a.triangle.control_flag),
        @as(u8, a.triangle.sequence_pos),
    });
    hasher.update(std.mem.asBytes(&a.triangle.timer_period));
    hasher.update(std.mem.asBytes(&a.triangle.timer));

    hasher.update(&[_]u8{ @intFromBool(a.noise.enabled), a.noise.length_counter });
    hashEnvelope(hasher, &a.noise.envelope);
    hasher.update(&[_]u8{ @intFromBool(a.noise.mode), a.noise.period_index });
    hasher.update(std.mem.asBytes(&a.noise.shift_register));
    hasher.update(std.mem.asBytes(&a.noise.timer));

    hasher.update(&[_]u8{
        @intFromBool(a.dmc.enabled),     @intFromBool(a.dmc.irq_enabled),
        @intFromBool(a.dmc.loop),        a.dmc.rate_index,
        a.dmc.output_level,              @intFromBool(a.dmc.silence),
        a.dmc.bits_remaining,            a.dmc.shift_register,
        @intFromBool(a.dmc.irq_flag),
        // `?u8`: a byte waiting in the 1-byte sample buffer is real
        // resume-critical state, and "empty" has to hash differently from
        // "holding $00" -- hence the presence flag alongside the value.
        @intFromBool(a.dmc.sample_buffer != null), a.dmc.sample_buffer orelse 0,
    });
    hasher.update(std.mem.asBytes(&a.dmc.sample_address));
    hasher.update(std.mem.asBytes(&a.dmc.sample_length));
    hasher.update(std.mem.asBytes(&a.dmc.current_address));
    hasher.update(std.mem.asBytes(&a.dmc.bytes_remaining));
    hasher.update(std.mem.asBytes(&a.dmc.timer));

    hasher.update(&[_]u8{
        a.frame.mode,                              @intFromBool(a.frame.irq_inhibit),
        @intFromBool(a.frame.irq_flag),            @intFromBool(a.frame.half_frame_pending),
        @intFromBool(a.even_cycle),
    });
    hasher.update(std.mem.asBytes(&a.frame.cycle));
    hasher.update(std.mem.asBytes(&a.frame.reset_delay));
    hasher.update(std.mem.asBytes(&a.frame.irq_reassert_remaining));
}

/// Shared by the two pulses and the noise channel -- all three carry the
/// identical envelope unit (`apu.zig`'s `Envelope`), and a resume that
/// restored only its decay level would resume at the wrong point in the
/// decay ramp.
fn hashEnvelope(hasher: *Sha256, e: *const apu_mod.Envelope) void {
    hasher.update(&[_]u8{
        @intFromBool(e.start),           @intFromBool(e.loop_flag),
        @intFromBool(e.constant_volume), e.volume_or_period,
        e.divider,                       e.decay,
    });
}

fn hashPulse(hasher: *Sha256, p: *const apu_mod.Pulse) void {
    hasher.update(&[_]u8{
        @intFromBool(p.enabled), p.length_counter,
        p.duty,                  @as(u8, p.sequence_pos),
    });
    hashEnvelope(hasher, &p.envelope);
    // The whole sweep unit, not just its divider: the shift/negate/period
    // fields decide the next target period, so a resume missing them
    // resumes onto a different pitch slide.
    hasher.update(&[_]u8{
        @intFromBool(p.sweep_enabled), p.sweep_period,
        @intFromBool(p.sweep_negate),  p.sweep_shift,
        p.sweep_divider,               @intFromBool(p.sweep_reload),
    });
    hasher.update(std.mem.asBytes(&p.timer_period));
    hasher.update(std.mem.asBytes(&p.timer));
}

/// See the module doc comment: only CHR-RAM is mutable state worth hashing.
/// `TestStub` is a CPU-test-only double (see `mapper.zig`), never reachable
/// from a real ROM, so it isn't handled here.
fn hashMapper(hasher: *Sha256, mapper: *const mapper_mod.Mapper) void {
    switch (mapper.*) {
        .nrom => |*n| if (n.chr_is_ram) hasher.update(&n.chr),
        // MMC1 adds the first *registers* any cartridge here has had. They
        // are as much emulation state as CHR-RAM is: two runs that diverge
        // only in which bank is mapped would otherwise hash identically.
        // `shift` and `last_write_cycle` are included because a
        // half-completed 5-write sequence, and the consecutive-write rule's
        // memory of the last write, both survive into the next instruction.
        .mmc1 => |*m| {
            if (m.chr_rom.len == 0) hasher.update(&m.chr_ram);
            hasher.update(&[_]u8{ m.shift, m.control, m.chr_bank0, m.chr_bank1, m.prg_bank });
            hasher.update(std.mem.asBytes(&m.cycle));
            hasher.update(std.mem.asBytes(&m.last_write_cycle));
        },
        .test_stub => {},
    }
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

test "the hash changes if bus.prg_ram (the vendored ROMs' \\$6000 result-code RAM) differs" {
    const buf = minimalNromBuf();
    var a_machine: Machine = undefined;
    try a_machine.init(&buf);

    var b_machine: Machine = undefined;
    try b_machine.init(&buf);
    b_machine.bus.prg_ram[0] = 0xFF; // the only difference from a_machine

    const a = hashState(&a_machine.cpu, &a_machine.bus);
    const b = hashState(&b_machine.cpu, &b_machine.bus);
    try testing.expect(!std.mem.eql(u8, &a, &b));
}

test "the hash changes if a CHR-RAM cartridge's CHR contents differ" {
    const buf = minimalNromBuf(); // CHR size 0 -> CHR-RAM, per rom.zig
    var a_machine: Machine = undefined;
    try a_machine.init(&buf);

    var b_machine: Machine = undefined;
    try b_machine.init(&buf);
    b_machine.bus.mapper.nrom.chr[0] = 0xFF; // the only difference from a_machine

    const a = hashState(&a_machine.cpu, &a_machine.bus);
    const b = hashState(&b_machine.cpu, &b_machine.bus);
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

    const a = hashState(&a_machine.cpu, &a_machine.bus);
    const b = hashState(&b_machine.cpu, &b_machine.bus);
    try testing.expect(std.mem.eql(u8, &a, &b));
}

test "the hash changes if controller state (ENG-68) differs" {
    const buf = minimalNromBuf();
    var a_machine: Machine = undefined;
    try a_machine.init(&buf);

    var b_machine: Machine = undefined;
    try b_machine.init(&buf);
    b_machine.bus.controllers[0].setButtons(0x01); // the only difference from a_machine

    const a = hashState(&a_machine.cpu, &a_machine.bus);
    const b = hashState(&b_machine.cpu, &b_machine.bus);
    try testing.expect(!std.mem.eql(u8, &a, &b));
}

test "the hash changes if APU channel state (ENG-71) differs" {
    const buf = minimalNromBuf();
    var a_machine: Machine = undefined;
    try a_machine.init(&buf);

    var b_machine: Machine = undefined;
    try b_machine.init(&buf);
    b_machine.bus.apu.pulse1.envelope.volume_or_period = 5; // the only difference

    const a = hashState(&a_machine.cpu, &a_machine.bus);
    const b = hashState(&b_machine.cpu, &b_machine.bus);
    try testing.expect(!std.mem.eql(u8, &a, &b));
}

test "the APU hash covers sweep configuration, not just the sweep divider (ENG-71)" {
    const buf = minimalNromBuf();
    var a_machine: Machine = undefined;
    try a_machine.init(&buf);

    var b_machine: Machine = undefined;
    try b_machine.init(&buf);
    b_machine.bus.apu.pulse1.sweep_shift = 3; // decides the next target period

    const a = hashState(&a_machine.cpu, &a_machine.bus);
    const b = hashState(&b_machine.cpu, &b_machine.bus);
    try testing.expect(!std.mem.eql(u8, &a, &b));
}

test "the APU hash distinguishes an empty DMC sample buffer from one holding 0x00" {
    const buf = minimalNromBuf();
    var a_machine: Machine = undefined;
    try a_machine.init(&buf);

    var b_machine: Machine = undefined;
    try b_machine.init(&buf);
    b_machine.bus.apu.dmc.sample_buffer = 0x00; // was null

    const a = hashState(&a_machine.cpu, &a_machine.bus);
    const b = hashState(&b_machine.cpu, &b_machine.bus);
    try testing.expect(!std.mem.eql(u8, &a, &b));
}

test "the APU hash covers the frame sequencer's pending-reset and deferred-half-frame latches" {
    const buf = minimalNromBuf();
    var a_machine: Machine = undefined;
    try a_machine.init(&buf);

    var b_machine: Machine = undefined;
    try b_machine.init(&buf);
    b_machine.bus.apu.frame.half_frame_pending = true;

    const a = hashState(&a_machine.cpu, &a_machine.bus);
    const b = hashState(&b_machine.cpu, &b_machine.bus);
    try testing.expect(!std.mem.eql(u8, &a, &b));

    var c_machine: Machine = undefined;
    try c_machine.init(&buf);
    c_machine.bus.apu.frame.reset_delay = 3;
    const c = hashState(&c_machine.cpu, &c_machine.bus);
    try testing.expect(!std.mem.eql(u8, &a, &c));
}
