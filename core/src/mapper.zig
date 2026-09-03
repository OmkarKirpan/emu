const std = @import("std");
const testing = std.testing;

/// NROM (mapper 0): fixed PRG banking (16KB mirrored to fill $8000-$FFFF, or
/// 32KB unmirrored), fixed CHR banking (8KB CHR-ROM, or 8KB CHR-RAM when the
/// cartridge has no CHR-ROM). No bank-switch registers, no IRQ — the simplest
/// possible implementation of the Mapper interface, but the interface itself
/// is shaped for MMC1/UxROM/CNROM/MMC3 (M7), which do have bank switching and
/// (MMC3) an IRQ.
pub const Nrom = struct {
    prg_rom: []const u8,
    chr: [0x2000]u8 = [_]u8{0} ** 0x2000,
    chr_is_ram: bool,

    pub fn init(prg_rom: []const u8, chr_rom: []const u8) Nrom {
        var self = Nrom{ .prg_rom = prg_rom, .chr_is_ram = chr_rom.len == 0 };
        if (!self.chr_is_ram) @memcpy(self.chr[0..chr_rom.len], chr_rom);
        return self;
    }

    pub fn prgRead(self: *const Nrom, addr: u16) u8 {
        const offset = (addr - 0x8000) % @as(u16, @intCast(self.prg_rom.len));
        return self.prg_rom[offset];
    }

    pub fn prgWrite(self: *Nrom, addr: u16, value: u8) void {
        // NROM has no bank-switch registers: writes to PRG space are no-ops,
        // matching real hardware (there's no PRG-RAM on the base cartridge).
        _ = self;
        _ = addr;
        _ = value;
    }

    pub fn chrRead(self: *const Nrom, addr: u16) u8 {
        return self.chr[addr];
    }

    pub fn chrWrite(self: *Nrom, addr: u16, value: u8) void {
        if (self.chr_is_ram) self.chr[addr] = value;
    }

    pub fn irqPending(self: *const Nrom) bool {
        _ = self;
        return false;
    }

    pub fn irqAcknowledge(self: *Nrom) void {
        _ = self;
    }
};

test "Nrom.prgRead mirrors a 16KB bank across the full $8000-$FFFF window" {
    var prg = [_]u8{0xAA} ** 0x4000;
    prg[0] = 0x11;
    var m = Mapper{ .nrom = Nrom.init(&prg, &.{}) };
    try testing.expectEqual(@as(u8, 0x11), m.prgRead(0x8000));
    try testing.expectEqual(@as(u8, 0x11), m.prgRead(0xC000)); // mirrored copy
}

test "Nrom.prgRead does not mirror a full 32KB bank" {
    var prg = [_]u8{0xAA} ** 0x8000;
    prg[0] = 0x11;
    prg[0x4000] = 0x33;
    var m = Mapper{ .nrom = Nrom.init(&prg, &.{}) };
    try testing.expectEqual(@as(u8, 0x11), m.prgRead(0x8000));
    try testing.expectEqual(@as(u8, 0x33), m.prgRead(0xC000));
}

test "Nrom.prgWrite is a no-op" {
    var prg = [_]u8{0x11} ** 0x4000;
    var m = Mapper{ .nrom = Nrom.init(&prg, &.{}) };
    m.prgWrite(0x8000, 0xFF);
    try testing.expectEqual(@as(u8, 0x11), m.prgRead(0x8000));
}

test "Nrom.chrWrite is a no-op for CHR-ROM but honored for CHR-RAM" {
    const chr = [_]u8{0x42} ** 0x2000;
    var m_rom = Mapper{ .nrom = Nrom.init(&.{}, &chr) };
    m_rom.chrWrite(0, 0xFF);
    try testing.expectEqual(@as(u8, 0x42), m_rom.chrRead(0)); // unchanged: real CHR-ROM

    var m_ram = Mapper{ .nrom = Nrom.init(&.{}, &.{}) }; // no CHR-ROM => CHR-RAM
    m_ram.chrWrite(0, 0xFF);
    try testing.expectEqual(@as(u8, 0xFF), m_ram.chrRead(0)); // honored: CHR-RAM
}

test "Nrom never raises an IRQ" {
    var m = Mapper{ .nrom = Nrom.init(&.{}, &.{}) };
    try testing.expect(!m.irqPending());
    m.irqAcknowledge(); // must not panic
}

/// Closed set of NES mappers (see the map's "Out of scope": coverage is
/// capped at NROM/MMC1/UxROM/CNROM/MMC3). A tagged union dispatched via
/// `switch (self.*) { inline else => |*m| ... }` rather than a vtable: the
/// switch operates on `self.*`, a place expression, and captures by pointer
/// (`|*m|`), so this does NOT copy the union's payload on every call — it
/// gets a pointer straight into the active variant. That matters once a
/// variant holds real state (MMC1/MMC3 bank-switch registers) and matters a
/// lot in a cycle-accurate core dispatching this millions of times/sec.
pub const Mapper = union(enum) {
    nrom: Nrom,

    pub fn prgRead(self: *const Mapper, addr: u16) u8 {
        switch (self.*) {
            inline else => |*m| return m.prgRead(addr),
        }
    }

    pub fn prgWrite(self: *Mapper, addr: u16, value: u8) void {
        switch (self.*) {
            inline else => |*m| m.prgWrite(addr, value),
        }
    }

    pub fn chrRead(self: *const Mapper, addr: u16) u8 {
        switch (self.*) {
            inline else => |*m| return m.chrRead(addr),
        }
    }

    pub fn chrWrite(self: *Mapper, addr: u16, value: u8) void {
        switch (self.*) {
            inline else => |*m| m.chrWrite(addr, value),
        }
    }

    pub fn irqPending(self: *const Mapper) bool {
        switch (self.*) {
            inline else => |*m| return m.irqPending(),
        }
    }

    pub fn irqAcknowledge(self: *Mapper) void {
        switch (self.*) {
            inline else => |*m| m.irqAcknowledge(),
        }
    }
};
