const std = @import("std");
const testing = std.testing;

const mapper_mod = @import("mapper.zig");
const rom_mod = @import("rom.zig");
const ppu_mod = @import("ppu.zig");
const apu_mod = @import("apu.zig");
const controller_mod = @import("controller.zig");
const Mapper = mapper_mod.Mapper;
const Nrom = mapper_mod.Nrom;
const Mirroring = rom_mod.Mirroring;
const Ppu = ppu_mod.Ppu;
const Controller = controller_mod.Controller;

/// The 2A03's CPU-visible address space.
///
/// The CPU has a flat 16-bit address space that the console decodes into four
/// regions. `Bus` owns the two things the CPU can actually talk to today —
/// internal WRAM and the cartridge (`Mapper`) — and models the rest as open
/// bus until the PPU (M2) and APU/controllers (M6) exist.
///
///     $0000-$07FF  2KB internal WRAM
///     $0800-$1FFF  mirrors of WRAM (A11/A12 are not decoded)
///     $2000-$2007  PPU registers, decoded through `Ppu.readRegister`/`writeRegister`
///     $2008-$3FFF  mirrors of $2000-$2007 every 8 bytes
///     $4000-$4013  APU registers             -- decoded through `Apu.writeRegister` (M6)
///     $4014        OAMDMA                    -- handled by `Cpu.write`, not here (see below)
///     $4015        APU status (read) / channel enable (write) -- `Apu.readStatus`/`writeRegister`
///     $4016        controller strobe (write) / port 0 data (read)
///     $4017        APU frame counter (write, `Apu.writeRegister`) / port 1 data (read)
///     $4018-$401F  remaining CPU-test registers -- not implemented: open bus
///     $4020-$5FFF  cartridge expansion       -- unmapped on NROM
///     $6000-$7FFF  cartridge PRG-RAM         -- `Bus.prg_ram`, unconditional
///     $8000-$FFFF  cartridge PRG-ROM         -- `Mapper.prgRead`/`prgWrite`
///
/// **$4014 (OAMDMA) is not decoded by `Bus` at all.** Copying 256 bytes into
/// OAM costs 513-514 *CPU* cycles (see https://www.nesdev.org/wiki/DMA) --
/// time that has to flow through `Cpu.tick`'s chokepoint so the PPU keeps
/// advancing and NMI keeps getting polled while it happens, exactly like
/// every other cycle the CPU spends. `Bus` has no access to `Cpu` (`Cpu`
/// borrows `*Bus`, not the other way around), so `Cpu.write` special-cases
/// $4014 itself, immediately after the ordinary bus write above completes
/// (which still updates `open_bus`, same as any other write to this
/// unmapped-by-`Bus` address).
///
/// **Controller reads/writes.** $4016 write sets the strobe latch shared by
/// *both* controller shift registers (see `Controller`'s doc comment); reads
/// of $4016/$4017 pull that port's next serial bit into bit 0, with every
/// other bit falling to `open_bus` -- the same "only the bits hardware
/// actually drives are real, the rest reads back the bus's last value"
/// convention as `Ppu.data_bus` and this type's own open-bus handling below.
/// Writing $4017 is the APU frame-counter register, not a controller
/// input -- decoded through `Apu.writeRegister` (M6).
/// **$6000-$7FFF is plain 8KB WRAM, unconditionally, not routed through
/// `Mapper`.** Despite the mapper-0 name, "NROM" says nothing about whether a
/// given cartridge board wires up PRG-RAM at $6000 -- that varies per board,
/// which is exactly why the iNES/NES 2.0 header carries a separate PRG-RAM
/// size field rather than deriving it from the mapper number. Concretely: the
/// vendored Blargg `ppu_vbl_nmi` test ROMs (mapper 0) require exactly this
/// RAM to exist, to hand back their `$6000` result-code protocol at all — see
/// `docs/research/test-rom-licensing.md` and `ppu_vbl_nmi_test.zig`. Giving
/// every cartridge this RAM unconditionally is a deliberate simplification
/// (no battery-backed persistence, no mapper-specific enable/disable), on the
/// same "known, named gap" footing as the rest of this doc comment: real
/// MMC1/MMC3 boards (M7) may also bank-switch or battery-back this window,
/// which `Mapper` still has no entry point for and isn't needed until then.
/// Flagged so the omission reads as known rather than as an oversight.
///
/// **Open-bus convention.** Every region that is not backed by real storage
/// reads back `open_bus`: the last value the CPU actually drove onto or
/// latched off the data bus. This is what the hardware does — the bus
/// capacitance holds the previous value when nothing drives it — and it is
/// strictly more accurate than returning a constant. `open_bus` is updated on
/// every read (with the value read) and every write (with the value written),
/// including reads that hit real storage, so the latch tracks the true last
/// bus value rather than only unmapped accesses. The PPU register file has
/// its own, separate open-bus latch (`Ppu.data_bus`) for the same reason a
/// real 2C02 does: it sits behind its own 8-bit data bus, distinct from the
/// CPU's.
///
/// nestest's automation mode (PC forced to $C000) is documented by its author
/// as running the whole CPU test suite without needing a PPU, and it does
/// *write* to $2000-$401F in a few places (e.g. `STA $4006`) without ever
/// branching on what it reads back — so open bus is sufficient for the
/// still-unmapped $4000-$7FFF range, and the log-diff harness confirms it
/// empirically.
pub const Bus = struct {
    /// $0000-$07FF, mirrored through $1FFF.
    wram: [0x0800]u8 = [_]u8{0} ** 0x0800,
    mapper: Mapper,
    ppu: Ppu,
    apu: apu_mod.Apu = .{},
    /// Port 0 ($4016) and port 1 ($4017). See `Controller`'s doc comment for
    /// the shift-register model and the shared-strobe wiring.
    controllers: [2]Controller = [_]Controller{.{}} ** 2,
    /// $6000-$7FFF. See the type doc comment for why this is unconditional
    /// rather than mapper-gated.
    prg_ram: [0x2000]u8 = [_]u8{0} ** 0x2000,
    /// Last value driven on the data bus; see the open-bus note above.
    open_bus: u8 = 0,

    pub fn init(m: Mapper, mirroring: Mirroring) Bus {
        return .{ .mapper = m, .ppu = Ppu.init(mirroring) };
    }

    pub fn read(self: *Bus, addr: u16) u8 {
        const value: u8 = switch (addr) {
            0x0000...0x1FFF => self.wram[addr & 0x07FF],
            0x2000...0x3FFF => self.ppu.readRegister(0x2000 | (addr & 0x0007), &self.mapper),
            0x4000...0x4014 => self.open_bus, // APU write-only regs + OAMDMA: open bus on read
            0x4015 => self.apu.readStatus(),
            0x4016 => (self.open_bus & 0xFE) | self.controllers[0].read(),
            0x4017 => (self.open_bus & 0xFE) | self.controllers[1].read(),
            0x4018...0x5FFF => self.open_bus, // CPU test regs + cartridge expansion
            0x6000...0x7FFF => self.prg_ram[addr & 0x1FFF],
            0x8000...0xFFFF => self.mapper.prgRead(addr),
        };
        self.open_bus = value;
        return value;
    }

    pub fn write(self: *Bus, addr: u16, value: u8) void {
        self.open_bus = value;
        switch (addr) {
            0x0000...0x1FFF => self.wram[addr & 0x07FF] = value,
            0x2000...0x3FFF => self.ppu.writeRegister(0x2000 | (addr & 0x0007), value, &self.mapper),
            0x4000...0x4013 => self.apu.writeRegister(addr, value),
            // $4014 (OAMDMA) is handled by `Cpu.write`, not here -- see the
            // type doc comment. It still falls through to this no-op case
            // (the `open_bus` update above already happened).
            0x4014 => {},
            0x4015 => self.apu.writeRegister(addr, value),
            0x4016 => {
                const strobe = (value & 0x01) != 0;
                self.controllers[0].setStrobe(strobe);
                self.controllers[1].setStrobe(strobe);
            },
            // $4017 here is the APU frame counter (M6), not a controller
            // port -- controller *writes* both go through $4016 only.
            0x4017 => self.apu.writeRegister(addr, value),
            0x4018...0x5FFF => {},
            0x6000...0x7FFF => self.prg_ram[addr & 0x1FFF] = value,
            0x8000...0xFFFF => self.mapper.prgWrite(addr, value),
        }
    }

    /// Side-effect-free read, for tracing/disassembly/debugger use. Does not
    /// touch `open_bus`, never advances any device state, and reaches the PPU
    /// through `peekRegister` rather than `readRegister` for the same reason
    /// — reading through `peek` must never be observable by the emulated
    /// program (no VBL-flag clear, no write-toggle flip, no buffered-read
    /// advance, no controller shift-register advance).
    pub fn peek(self: *const Bus, addr: u16) u8 {
        return switch (addr) {
            0x0000...0x1FFF => self.wram[addr & 0x07FF],
            0x2000...0x3FFF => self.ppu.peekRegister(0x2000 | (addr & 0x0007)),
            0x4000...0x4014 => self.open_bus,
            // Not side-effect-free ($4015 clears the frame IRQ flag on
            // read), but `peek` has no APU-side "peek" variant and no
            // existing caller depends on this bit -- accepted as-is; flag
            // for revisit if a debugger UI ever reads $4015 through peek.
            0x4015 => self.open_bus,
            0x4016 => (self.open_bus & 0xFE) | self.controllers[0].peek(),
            0x4017 => (self.open_bus & 0xFE) | self.controllers[1].peek(),
            0x4018...0x5FFF => self.open_bus,
            0x6000...0x7FFF => self.prg_ram[addr & 0x1FFF],
            0x8000...0xFFFF => self.mapper.prgRead(addr),
        };
    }
};

fn testBus(prg: []const u8) Bus {
    return Bus.init(Mapper{ .nrom = Nrom.init(prg, &.{}) }, .horizontal);
}

test "Bus mirrors WRAM every 2KB through $1FFF" {
    const prg = [_]u8{0} ** 0x4000;
    var bus = testBus(&prg);
    bus.write(0x0000, 0x42);
    try testing.expectEqual(@as(u8, 0x42), bus.read(0x0800));
    try testing.expectEqual(@as(u8, 0x42), bus.read(0x1000));
    try testing.expectEqual(@as(u8, 0x42), bus.read(0x1800));
    bus.write(0x1FFF, 0x99);
    try testing.expectEqual(@as(u8, 0x99), bus.read(0x07FF));
}

test "Bus routes $8000-$FFFF to the mapper" {
    var prg = [_]u8{0} ** 0x4000;
    prg[0] = 0xAB;
    prg[0x3FFF] = 0xCD;
    var bus = testBus(&prg);
    try testing.expectEqual(@as(u8, 0xAB), bus.read(0x8000));
    try testing.expectEqual(@as(u8, 0xCD), bus.read(0xFFFF)); // 16KB mirror
}

test "Bus reads back the last bus value in unmapped regions" {
    const prg = [_]u8{0} ** 0x4000;
    var bus = testBus(&prg);
    bus.write(0x0000, 0x5A);
    try testing.expectEqual(@as(u8, 0x5A), bus.read(0x4010));
    bus.write(0x4016, 0xC3);
    try testing.expectEqual(@as(u8, 0xC3), bus.read(0x4020));
}

test "Bus routes $6000-$7FFF to unconditional PRG-RAM" {
    const prg = [_]u8{0} ** 0x4000;
    var bus = testBus(&prg);
    bus.write(0x6000, 0x80); // Blargg's $6000 status-byte protocol
    try testing.expectEqual(@as(u8, 0x80), bus.read(0x6000));
    // Mirrored across the whole 8KB window, not aliased to a smaller size.
    bus.write(0x7FFF, 0x42);
    try testing.expectEqual(@as(u8, 0x42), bus.read(0x7FFF));
    try testing.expectEqual(@as(u8, 0x80), bus.read(0x6000)); // untouched by the $7FFF write
}

test "Bus.peek does not disturb the open-bus latch" {
    const prg = [_]u8{0} ** 0x4000;
    var bus = testBus(&prg);
    bus.write(0x0000, 0x11);
    _ = bus.peek(0x8000);
    try testing.expectEqual(@as(u8, 0x11), bus.read(0x4010));
}

test "Bus routes $2000-$3FFF to the PPU, mirrored every 8 bytes" {
    const prg = [_]u8{0} ** 0x4000;
    var bus = testBus(&prg);
    bus.write(0x2003, 0x10); // OAMADDR
    bus.write(0x2004, 0x42); // OAMDATA
    try testing.expectEqual(@as(u8, 0x42), bus.ppu.oam[0x10]);
    // $2004 mirrors every 8 bytes: $200C is the same register.
    bus.ppu.oam_addr = 0x10;
    try testing.expectEqual(@as(u8, 0x42), bus.read(0x200C));
    // ...all the way through $3FFF.
    try testing.expectEqual(@as(u8, 0x42), bus.read(0x3FFC));
}

test "Bus.peek reaches the PPU without clearing the VBL flag" {
    const prg = [_]u8{0} ** 0x4000;
    var bus = testBus(&prg);
    bus.ppu.status.vblank = true;
    const peeked = bus.peek(0x2002);
    try testing.expect((peeked & 0x80) != 0);
    try testing.expect(bus.ppu.status.vblank); // still set: peek must not clear it
}

test "$4016 write strobes both controller ports; $4016/$4017 reads carry each port's own data" {
    const prg = [_]u8{0} ** 0x4000;
    var bus = testBus(&prg);
    bus.controllers[0].setButtons(controller_mod.button_a);
    bus.controllers[1].setButtons(controller_mod.button_b);
    bus.write(0x4016, 0x01); // strobe high on both ports
    bus.write(0x4016, 0x00); // strobe low: latches each port's own buttons
    try testing.expectEqual(@as(u8, 1), bus.read(0x4016) & 0x01); // port 0: A
    try testing.expectEqual(@as(u8, 0), bus.read(0x4017) & 0x01); // port 1: A is not held
}

test "$4016/$4017 reads carry open-bus bits everywhere but bit 0" {
    const prg = [_]u8{0} ** 0x4000;
    var bus = testBus(&prg);
    bus.write(0x4016, 0x00); // strobe low; both ports' shift regs start at 0
    bus.write(0x0000, 0xFF); // *after* the $4016 write, so open_bus = 0xFF here
    try testing.expectEqual(@as(u8, 0xFE), bus.read(0x4016) & 0xFE);
}

test "$4017 write is the APU frame counter, not controller port 1 -- it does not strobe anything" {
    const prg = [_]u8{0} ** 0x4000;
    var bus = testBus(&prg);
    bus.controllers[1].setButtons(controller_mod.button_a);
    bus.write(0x4017, 0x01); // would strobe if this were mistakenly wired to Controller
    try testing.expect(!bus.controllers[1].strobe);
}

test "Bus routes $4000-$4013 writes to the APU, not open bus" {
    const prg = [_]u8{0} ** 0x4000;
    var bus = testBus(&prg);
    bus.write(0x4000, 0b00_0_1_1010);
    try testing.expectEqual(@as(u4, 10), bus.apu.pulse1.envelope.volume_or_period);
}

test "Bus routes $4015 read/write to the APU status/enable register" {
    const prg = [_]u8{0} ** 0x4000;
    var bus = testBus(&prg);
    bus.write(0x4015, 0x01); // enable pulse1
    try testing.expect(bus.apu.pulse1.enabled);
    bus.write(0x4003, 0b00001_000); // load length now that pulse1 is enabled
    try testing.expect((bus.read(0x4015) & 0x01) != 0);
}

test "Bus routes $4017 writes to the APU frame counter, not the controller (that's $4016 only)" {
    const prg = [_]u8{0} ** 0x4000;
    var bus = testBus(&prg);
    bus.write(0x4017, 0x40); // IRQ inhibit
    try testing.expect(bus.apu.frame.irq_inhibit);
    try testing.expect(!bus.controllers[1].strobe); // unaffected -- see the pre-existing test above this one
}
