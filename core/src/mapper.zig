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

    /// PRG-ROM is borrowed, not copied: `prg_rom` is a slice into the
    /// caller-owned ROM file bytes, so the caller must keep the original ROM
    /// buffer (whatever `Rom.load` sliced from) alive for as long as this
    /// `Mapper` is in use. CHR, in contrast, is always copied into `chr`
    /// (owned inline storage) — this keeps CHR-RAM writes safe without a
    /// second lifetime to track, at the cost of an 8KB copy at init time.
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

/// A test double, not a cartridge — the only non-hardware `Mapper` variant.
///
/// It exists because NROM can never reach two parts of this interface, so
/// without it nothing in the tree exercises them at all:
///
///   * **`irqPending` returning true.** The CPU wire-ORs the cartridge IRQ into
///     its own /IRQ input (`Cpu.irqAsserted`); that OR is the single line
///     MMC3's scanline IRQ (M7) depends on. With only NROM installed, a test
///     can assert nothing stronger than "false stays false", which is exactly
///     what the CPU test used to do while reading as if it covered the OR.
///   * **`prgWrite` as an observable event.** An NMOS read-modify-write emits
///     *two* writes — the unmodified value, then the modified one — and real
///     hardware registers latch on the first. WRAM cannot show the difference,
///     because both writes land on the same byte; a write log can.
///
/// This is deliberately not a step toward M7's real variants: it models no
/// cartridge, and M7 should add MMC1/MMC3 alongside it rather than growing it.
/// It costs the union nothing (Nrom's inline 8KB CHR dominates the size) and
/// adds no state to any shipping code path.
pub const TestStub = struct {
    pub const Write = struct { addr: u16, value: u8 };

    prg_rom: []const u8,
    /// Drive the cartridge IRQ line. `irqAcknowledge` clears it.
    irq: bool = false,
    /// Ring-free write log: entries past `writes.len` are counted but not
    /// stored, so `write_count` is always the true total.
    writes: [8]Write = undefined,
    write_count: usize = 0,

    pub fn init(prg_rom: []const u8) TestStub {
        return .{ .prg_rom = prg_rom };
    }

    pub fn prgRead(self: *const TestStub, addr: u16) u8 {
        const offset = (addr - 0x8000) % @as(u16, @intCast(self.prg_rom.len));
        return self.prg_rom[offset];
    }

    pub fn prgWrite(self: *TestStub, addr: u16, value: u8) void {
        if (self.write_count < self.writes.len) {
            self.writes[self.write_count] = .{ .addr = addr, .value = value };
        }
        self.write_count += 1;
    }

    pub fn chrRead(self: *const TestStub, addr: u16) u8 {
        _ = self;
        _ = addr;
        return 0;
    }

    pub fn chrWrite(self: *TestStub, addr: u16, value: u8) void {
        _ = self;
        _ = addr;
        _ = value;
    }

    pub fn irqPending(self: *const TestStub) bool {
        return self.irq;
    }

    pub fn irqAcknowledge(self: *TestStub) void {
        self.irq = false;
    }
};

test "TestStub logs PRG writes and drives the IRQ line through the interface" {
    var prg = [_]u8{0x11} ** 0x8000;
    var m = Mapper{ .test_stub = TestStub.init(&prg) };
    try testing.expect(!m.irqPending());

    m.test_stub.irq = true;
    try testing.expect(m.irqPending()); // visible through the union, not the variant
    m.irqAcknowledge();
    try testing.expect(!m.irqPending());

    m.prgWrite(0x8000, 0xAA);
    m.prgWrite(0x8000, 0xBB);
    try testing.expectEqual(@as(usize, 2), m.test_stub.write_count);
    try testing.expectEqual(@as(u8, 0xAA), m.test_stub.writes[0].value);
    try testing.expectEqual(@as(u8, 0xBB), m.test_stub.writes[1].value);
}

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

test "prgRead(0xFFFF) returns the last byte of a 32KB PRG ROM" {
    var prg = [_]u8{0xAA} ** 0x8000;
    prg[0x7FFF] = 0x99; // last byte of the 32KB bank, mapped to addr 0xFFFF
    var m = Mapper{ .nrom = Nrom.init(&prg, &.{}) };
    try testing.expectEqual(@as(u8, 0x99), m.prgRead(0xFFFF));
}

test "chrRead(0x1FFF) returns the last byte of an 8KB CHR" {
    var chr = [_]u8{0xAA} ** 0x2000;
    chr[0x1FFF] = 0x77; // last byte of the 8KB CHR window
    var m = Mapper{ .nrom = Nrom.init(&.{}, &chr) };
    try testing.expectEqual(@as(u8, 0x77), m.chrRead(0x1FFF));
}

test "Nrom never raises an IRQ" {
    var m = Mapper{ .nrom = Nrom.init(&.{}, &.{}) };
    try testing.expect(!m.irqPending());
    m.irqAcknowledge(); // must not panic
}

/// Closed set of NES mappers (see the map's "Out of scope": coverage is
/// capped at NROM/MMC1/UxROM/CNROM/MMC3), plus one test double (`TestStub`).
/// A tagged union dispatched via
/// `switch (self.*) { inline else => |*m| ... }` rather than a vtable: the
/// switch operates on `self.*`, a place expression, and captures by pointer
/// (`|*m|`), so this does NOT copy the union's payload on every call — it
/// gets a pointer straight into the active variant. That matters once a
/// variant holds real state (MMC1/MMC3 bank-switch registers) and matters a
/// lot in a cycle-accurate core dispatching this millions of times/sec.
///
/// Callers (the future CPU memory bus and PPU) are responsible for
/// masking/routing addresses into range before calling: `prgRead`/`prgWrite`
/// require `addr` in `0x8000..=0xFFFF`; `chrRead`/`chrWrite` require `addr`
/// in `0x0000..=0x1FFF`. Out-of-range addresses panic rather than wrapping
/// or returning an error — the mapper interface trusts its caller.
pub const Mapper = union(enum) {
    nrom: Nrom,
    /// Not a cartridge — a test double for the parts of this interface NROM
    /// cannot reach. See `TestStub`.
    test_stub: TestStub,

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
