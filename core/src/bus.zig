const std = @import("std");
const testing = std.testing;

const mapper_mod = @import("mapper.zig");
const rom_mod = @import("rom.zig");
const Mapper = mapper_mod.Mapper;
const Nrom = mapper_mod.Nrom;

/// The 2A03's CPU-visible address space.
///
/// The CPU has a flat 16-bit address space that the console decodes into four
/// regions. `Bus` owns the two things the CPU can actually talk to today —
/// internal WRAM and the cartridge (`Mapper`) — and models the rest as open
/// bus until the PPU (M2) and APU/controllers (M6) exist.
///
///     $0000-$07FF  2KB internal WRAM
///     $0800-$1FFF  mirrors of WRAM (A11/A12 are not decoded)
///     $2000-$2007  PPU registers            -- not implemented (M2)
///     $2008-$3FFF  mirrors of PPU registers -- not implemented (M2)
///     $4000-$4017  APU + controller ports    -- not implemented (M6)
///     $4018-$401F  CPU test registers (disabled on retail hardware)
///     $4020-$5FFF  cartridge expansion       -- unmapped on NROM
///     $6000-$7FFF  cartridge PRG-RAM         -- absent on NROM
///     $8000-$FFFF  cartridge PRG-ROM         -- `Mapper.prgRead`/`prgWrite`
///
/// **Known interface gap (M7).** `$4020-$7FFF` currently folds into the
/// open-bus arm. That is correct for NROM, which populates neither cartridge
/// expansion space nor PRG-RAM — but it is *only* correct for NROM. MMC1 and
/// MMC3 put battery-backed PRG-RAM at `$6000-$7FFF`, and `Mapper` has no entry
/// point for it: `prgRead`/`prgWrite` are documented as requiring
/// `0x8000..=0xFFFF`, so this bus cannot route a `$6000` access to the
/// cartridge even if a mapper wanted it. Adding that entry point is M7's call
/// (it decides the shape, and whether save-RAM persistence rides along), not
/// something to speculate on here. Flagged so the omission reads as known
/// rather than as an oversight.
///
/// **Open-bus convention.** Every region that is not backed by real storage
/// reads back `open_bus`: the last value the CPU actually drove onto or
/// latched off the data bus. This is what the hardware does — the bus
/// capacitance holds the previous value when nothing drives it — and it is
/// strictly more accurate than returning a constant. `open_bus` is updated on
/// every read (with the value read) and every write (with the value written),
/// including reads that hit real storage, so the latch tracks the true last
/// bus value rather than only unmapped accesses.
///
/// nestest's automation mode (PC forced to $C000) is documented by its author
/// as running the whole CPU test suite without needing a PPU, and it does
/// *write* to $2000-$401F in a few places (e.g. `STA $4006`) without ever
/// branching on what it reads back — so open bus is sufficient here, and the
/// log-diff harness confirms it empirically.
pub const Bus = struct {
    /// $0000-$07FF, mirrored through $1FFF.
    wram: [0x0800]u8 = [_]u8{0} ** 0x0800,
    mapper: Mapper,
    /// Last value driven on the data bus; see the open-bus note above.
    open_bus: u8 = 0,

    pub fn init(m: Mapper) Bus {
        return .{ .mapper = m };
    }

    pub fn read(self: *Bus, addr: u16) u8 {
        const value: u8 = switch (addr) {
            0x0000...0x1FFF => self.wram[addr & 0x07FF],
            // PPU (M2), APU/IO (M6), and unmapped cartridge space. NROM has
            // neither expansion ROM nor PRG-RAM, so $4020-$7FFF is open too.
            0x2000...0x7FFF => self.open_bus,
            0x8000...0xFFFF => self.mapper.prgRead(addr),
        };
        self.open_bus = value;
        return value;
    }

    pub fn write(self: *Bus, addr: u16, value: u8) void {
        self.open_bus = value;
        switch (addr) {
            0x0000...0x1FFF => self.wram[addr & 0x07FF] = value,
            0x2000...0x7FFF => {},
            0x8000...0xFFFF => self.mapper.prgWrite(addr, value),
        }
    }

    /// Side-effect-free read, for tracing/disassembly/debugger use. Does not
    /// touch `open_bus` and never advances any device state — reading through
    /// `peek` must never be observable by the emulated program.
    pub fn peek(self: *const Bus, addr: u16) u8 {
        return switch (addr) {
            0x0000...0x1FFF => self.wram[addr & 0x07FF],
            0x2000...0x7FFF => self.open_bus,
            0x8000...0xFFFF => self.mapper.prgRead(addr),
        };
    }
};

fn testBus(prg: []const u8) Bus {
    return Bus.init(Mapper{ .nrom = Nrom.init(prg, &.{}) });
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
    try testing.expectEqual(@as(u8, 0x5A), bus.read(0x2002));
    bus.write(0x4016, 0xC3);
    try testing.expectEqual(@as(u8, 0xC3), bus.read(0x6000));
}

test "Bus.peek does not disturb the open-bus latch" {
    const prg = [_]u8{0} ** 0x4000;
    var bus = testBus(&prg);
    bus.write(0x0000, 0x11);
    _ = bus.peek(0x8000);
    try testing.expectEqual(@as(u8, 0x11), bus.read(0x2000));
}
