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
//! **No APU section**: it doesn't exist yet (M6). **No mapper section**:
//! NROM -- the only cartridge type implemented so far -- carries no mutable
//! state (fixed PRG/CHR banking, no bank-switch registers, no IRQ counter),
//! so there is nothing to hash there either; a future mapper with real state
//! (MMC1/MMC3, M7) will need one.
//!
//! There is no controller input to log yet (M3), so "given identical
//! inputs" is trivially satisfied by there being no inputs at all --
//! deferred intentionally rather than building event-log machinery this
//! milestone doesn't need.

const std = @import("std");
const testing = std.testing;

const rom_mod = @import("rom.zig");
const bus_mod = @import("bus.zig");
const cpu_mod = @import("cpu.zig");
const ppu_mod = @import("ppu.zig");

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
    const rom = try rom_mod.Rom.load(rom_bytes);
    var bus = bus_mod.Bus.init(try rom_mod.createMapper(rom), rom.header.mirroring);
    var cpu = cpu_mod.Cpu.init(&bus);
    cpu.reset();
    while (cpu.cycles < cycles) cpu.step();

    var hasher = Sha256.init(.{});
    hashCpu(&hasher, &cpu);
    hasher.update(&bus.wram);
    hashPpu(&hasher, &bus.ppu);

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
