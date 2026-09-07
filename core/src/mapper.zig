const std = @import("std");
const testing = std.testing;

/// How the cartridge wires the console's two physical 1KB nametable banks to
/// the four logical ones. **Defined here, not in `rom.zig`, because the
/// cartridge owns this at runtime, not the file header.** The iNES header
/// only supplies a power-on value (and cannot express the single-screen
/// modes at all); MMC1 rewrites it whenever its control register is written.
/// `rom.zig` re-exports this name, since `Header` still carries the parsed
/// initial value.
///
/// See https://www.nesdev.org/wiki/Mirroring.
pub const Mirroring = enum {
    horizontal,
    vertical,
    four_screen,
    /// Both physical banks show the *first* 1KB. MMC1 control bits 0-1 = 0.
    single_screen_lower,
    /// Both physical banks show the *second* 1KB. MMC1 control bits 0-1 = 1.
    single_screen_upper,
};

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
    /// Fixed for the life of the cartridge -- NROM has no mirroring control,
    /// so this is exactly what the iNES header said and never changes.
    mirroring_mode: Mirroring,

    /// PRG-ROM is borrowed, not copied: `prg_rom` is a slice into the
    /// caller-owned ROM file bytes, so the caller must keep the original ROM
    /// buffer (whatever `Rom.load` sliced from) alive for as long as this
    /// `Mapper` is in use. CHR, in contrast, is always copied into `chr`
    /// (owned inline storage) — this keeps CHR-RAM writes safe without a
    /// second lifetime to track, at the cost of an 8KB copy at init time.
    pub fn init(prg_rom: []const u8, chr_rom: []const u8, header_mirroring: Mirroring) Nrom {
        var self = Nrom{
            .prg_rom = prg_rom,
            .chr_is_ram = chr_rom.len == 0,
            .mirroring_mode = header_mirroring,
        };
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

    pub fn mirroring(self: *const Nrom) Mirroring {
        return self.mirroring_mode;
    }

    pub fn tick(self: *Nrom) void {
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
    /// Reported through `mirroring()`; settable so a test can drive the
    /// PPU's nametable mapping without standing up a real cartridge.
    mirroring_mode: Mirroring = .horizontal,
    ticks: u64 = 0,

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

    pub fn mirroring(self: *const TestStub) Mirroring {
        return self.mirroring_mode;
    }

    /// Counts `tick`s so a test can assert the CPU actually drives the
    /// per-cycle hook -- the thing MMC1's consecutive-write rule and MMC3's
    /// scanline IRQ both depend on.
    pub fn tick(self: *TestStub) void {
        self.ticks += 1;
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
    var m = Mapper{ .nrom = Nrom.init(&prg, &.{}, .horizontal) };
    try testing.expectEqual(@as(u8, 0x11), m.prgRead(0x8000));
    try testing.expectEqual(@as(u8, 0x11), m.prgRead(0xC000)); // mirrored copy
}

test "Nrom.prgRead does not mirror a full 32KB bank" {
    var prg = [_]u8{0xAA} ** 0x8000;
    prg[0] = 0x11;
    prg[0x4000] = 0x33;
    var m = Mapper{ .nrom = Nrom.init(&prg, &.{}, .horizontal) };
    try testing.expectEqual(@as(u8, 0x11), m.prgRead(0x8000));
    try testing.expectEqual(@as(u8, 0x33), m.prgRead(0xC000));
}

test "Nrom.prgWrite is a no-op" {
    var prg = [_]u8{0x11} ** 0x4000;
    var m = Mapper{ .nrom = Nrom.init(&prg, &.{}, .horizontal) };
    m.prgWrite(0x8000, 0xFF);
    try testing.expectEqual(@as(u8, 0x11), m.prgRead(0x8000));
}

test "Nrom.chrWrite is a no-op for CHR-ROM but honored for CHR-RAM" {
    const chr = [_]u8{0x42} ** 0x2000;
    var m_rom = Mapper{ .nrom = Nrom.init(&.{}, &chr, .horizontal) };
    m_rom.chrWrite(0, 0xFF);
    try testing.expectEqual(@as(u8, 0x42), m_rom.chrRead(0)); // unchanged: real CHR-ROM

    var m_ram = Mapper{ .nrom = Nrom.init(&.{}, &.{}, .horizontal) }; // no CHR-ROM => CHR-RAM
    m_ram.chrWrite(0, 0xFF);
    try testing.expectEqual(@as(u8, 0xFF), m_ram.chrRead(0)); // honored: CHR-RAM
}

test "prgRead(0xFFFF) returns the last byte of a 32KB PRG ROM" {
    var prg = [_]u8{0xAA} ** 0x8000;
    prg[0x7FFF] = 0x99; // last byte of the 32KB bank, mapped to addr 0xFFFF
    var m = Mapper{ .nrom = Nrom.init(&prg, &.{}, .horizontal) };
    try testing.expectEqual(@as(u8, 0x99), m.prgRead(0xFFFF));
}

test "chrRead(0x1FFF) returns the last byte of an 8KB CHR" {
    var chr = [_]u8{0xAA} ** 0x2000;
    chr[0x1FFF] = 0x77; // last byte of the 8KB CHR window
    var m = Mapper{ .nrom = Nrom.init(&.{}, &chr, .horizontal) };
    try testing.expectEqual(@as(u8, 0x77), m.chrRead(0x1FFF));
}

test "Nrom never raises an IRQ" {
    var m = Mapper{ .nrom = Nrom.init(&.{}, &.{}, .horizontal) };
    try testing.expect(!m.irqPending());
    m.irqAcknowledge(); // must not panic
}

/// MMC1 (mapper 1): the first cartridge here with state.
///
/// Every register is written one bit at a time. The CPU writes bit 0 of the
/// value five times; a write with bit 7 set resets the sequence and ORs
/// `control` with $0C (restoring PRG mode 3, which is also the power-on
/// value, so the reset vector at $FFFC is reachable before the ROM has
/// configured anything). The fifth write commits all five collected bits to
/// whichever register the *last* write's address selected:
///
///     $8000-$9FFF  control    [4] CHR mode  [3:2] PRG mode  [1:0] mirroring
///     $A000-$BFFF  chr_bank0  (+ PRG A18 in bit 4 on 512KB boards)
///     $C000-$DFFF  chr_bank1
///     $E000-$FFFF  prg_bank   (bit 4 is PRG-RAM disable -- see below)
///
/// **PRG and CHR are both borrowed slices, unlike `Nrom`'s inline CHR copy.**
/// MMC1 allows 128KB of CHR; copying it inline would put 128KB in *every*
/// `Mapper` value, NROM's included, since a union is as large as its largest
/// variant. So the lifetime rule `Nrom` documents for PRG ("the caller must
/// keep the original ROM buffer alive") extends to CHR here. `chr_ram` stays
/// inline because a CHR-RAM board has nothing to borrow from.
///
/// **Deliberately not implemented**, both filed as ENG-79:
///   * `prg_bank` bit 4, PRG-RAM disable. `Bus` maps $6000-$7FFF as
///     unconditional WRAM by an explicit decision (see its doc comment), and
///     the vendored ROM harness's `$6000` status protocol depends on that.
///   * SXROM's banked 32KB PRG-RAM, which additionally needs the NES 2.0
///     PRG-RAM size field `rom.zig` does not parse.
/// holy-mapperel's MMC1 ROMs test the first of these and report it in the
/// WRAM digit of their result code; `mmc1_test.zig` asserts those digits
/// rather than skipping them, so the gap stays visible.
pub const Mmc1 = struct {
    prg_rom: []const u8,
    /// Empty on a CHR-RAM board, in which case `chr_ram` is live instead.
    chr_rom: []const u8,
    chr_ram: [0x2000]u8 = [_]u8{0} ** 0x2000,

    /// Load register. The initial $10 is a walking sentinel bit: it reaches
    /// bit 0 after four writes, which is how the fifth write knows it is the
    /// fifth without a separate counter.
    shift: u8 = 0x10,
    /// Power-on value per https://www.nesdev.org/wiki/MMC1: PRG mode 3, so
    /// the last 16KB bank is fixed at $C000 and $FFFC is readable.
    control: u5 = 0x0C,
    chr_bank0: u5 = 0,
    chr_bank1: u5 = 0,
    prg_bank: u5 = 0,

    /// Free-running CPU cycle count, advanced by `tick`. Only differences
    /// matter, so it never needs resetting.
    cycle: u64 = 0,
    last_write_cycle: ?u64 = null,

    pub fn init(prg_rom: []const u8, chr_rom: []const u8) Mmc1 {
        return .{ .prg_rom = prg_rom, .chr_rom = chr_rom };
    }

    fn chrIsRam(self: *const Mmc1) bool {
        return self.chr_rom.len == 0;
    }

    fn prgMode(self: *const Mmc1) u2 {
        return @intCast((self.control >> 2) & 0x03);
    }

    fn chrMode4k(self: *const Mmc1) bool {
        return (self.control & 0x10) != 0;
    }

    /// SUROM: on boards larger than 256KB, bit 4 of the CHR bank register
    /// drives PRG A18, selecting which 256KB half every PRG window lives in
    /// -- *including* the "fixed" one, which is why the fixed bank below is
    /// the last bank of the selected half rather than of the whole ROM.
    ///
    /// In 4KB CHR mode the two CHR registers each carry an A18 bit for their
    /// own half of CHR space; real 512KB boards are CHR-RAM, so those bits
    /// are pure bank-selection there and software keeps them equal. `chr_bank0`
    /// is used for both, which is standard practice.
    fn prgBlockBase(self: *const Mmc1) usize {
        if (self.prg_rom.len <= 0x40000) return 0;
        return @as(usize, (self.chr_bank0 >> 4) & 1) * 16;
    }

    /// Which 16KB PRG bank each half of $8000-$FFFF currently shows.
    fn prgBanks(self: *const Mmc1) struct { lo: usize, hi: usize } {
        const total = @max(self.prg_rom.len / 0x4000, 1);
        const base = self.prgBlockBase();
        const b: usize = self.prg_bank & 0x0F;
        const pair: struct { lo: usize, hi: usize } = switch (self.prgMode()) {
            // 32KB switchable: the low bit of the bank number is ignored.
            0, 1 => .{ .lo = base + (b & 0x0E), .hi = base + (b & 0x0E) + 1 },
            // First bank fixed at $8000, switchable at $C000.
            2 => .{ .lo = base, .hi = base + b },
            // Switchable at $8000, last bank of the block fixed at $C000.
            3 => .{ .lo = base + b, .hi = base + 15 },
        };
        return .{ .lo = pair.lo % total, .hi = pair.hi % total };
    }

    pub fn prgRead(self: *const Mmc1, addr: u16) u8 {
        const banks = self.prgBanks();
        const bank = if (addr < 0xC000) banks.lo else banks.hi;
        const offset = bank * 0x4000 + (addr & 0x3FFF);
        return self.prg_rom[offset % self.prg_rom.len];
    }

    pub fn prgWrite(self: *Mmc1, addr: u16, value: u8) void {
        // An NMOS read-modify-write emits two writes on consecutive cycles;
        // the hardware latches the first and ignores the second. See
        // `TestStub`'s doc comment, which anticipated exactly this.
        if (self.last_write_cycle) |last| {
            if (self.cycle == last +| 1) return;
        }
        self.last_write_cycle = self.cycle;

        if (value & 0x80 != 0) {
            self.shift = 0x10;
            self.control |= 0x0C;
            return;
        }

        const is_fifth = (self.shift & 1) != 0;
        const shifted: u8 = (self.shift >> 1) | ((value & 1) << 4);
        if (!is_fifth) {
            self.shift = shifted;
            return;
        }

        const data: u5 = @intCast(shifted & 0x1F);
        self.shift = 0x10;
        switch (addr) {
            0x8000...0x9FFF => self.control = data,
            0xA000...0xBFFF => self.chr_bank0 = data,
            0xC000...0xDFFF => self.chr_bank1 = data,
            else => self.prg_bank = data,
        }
    }

    /// Offset of `addr` within CHR memory, after banking.
    ///
    /// **CHR-RAM is banked too.** It is tempting to treat an 8KB CHR-RAM
    /// board as unbanked, since 8KB is the whole address space -- but in
    /// 4KB mode the two bank registers still choose which 4KB *half* each
    /// window shows, so writing bank 1 into `chr_bank0` swaps the halves.
    /// holy-mapperel'''s detailed CHR test exercises exactly that, and
    /// reported CHR digit 3 until this used one path for both memories.
    fn chrOffset(self: *const Mmc1, addr: u16) usize {
        const total = @max(if (self.chrIsRam()) self.chr_ram.len else self.chr_rom.len, 1);
        const raw = if (self.chrMode4k()) blk: {
            const bank: usize = if (addr < 0x1000) self.chr_bank0 else self.chr_bank1;
            break :blk bank * 0x1000 + (addr & 0x0FFF);
        } else blk: {
            break :blk @as(usize, self.chr_bank0 >> 1) * 0x2000 + (addr & 0x1FFF);
        };
        return raw % total;
    }

    pub fn chrRead(self: *const Mmc1, addr: u16) u8 {
        if (self.chrIsRam()) return self.chr_ram[self.chrOffset(addr)];
        return self.chr_rom[self.chrOffset(addr)];
    }

    pub fn chrWrite(self: *Mmc1, addr: u16, value: u8) void {
        if (self.chrIsRam()) self.chr_ram[self.chrOffset(addr)] = value;
    }

    pub fn irqPending(self: *const Mmc1) bool {
        _ = self;
        return false;
    }

    pub fn irqAcknowledge(self: *Mmc1) void {
        _ = self;
    }

    pub fn mirroring(self: *const Mmc1) Mirroring {
        return switch (self.control & 0x03) {
            0 => .single_screen_lower,
            1 => .single_screen_upper,
            2 => .vertical,
            else => .horizontal,
        };
    }

    pub fn tick(self: *Mmc1) void {
        self.cycle +|= 1;
    }
};

// ------------------------------------------------------------ MMC1 tests

/// Advance two CPU cycles -- the minimum spacing between two writes the
/// mapper will both accept, since writes exactly one cycle apart are the
/// read-modify-write pattern it drops.
fn m_tick2(m: *Mapper) void {
    m.tick();
    m.tick();
}

/// Write `value` into an MMC1 register the way a real program does: five
/// writes, LSB first, to any address in the target register's range.
fn mmc1Write(m: *Mapper, addr: u16, value: u5) void {
    for (0..5) |i| {
        // *Two* cycles between writes, not one. A real program stores these
        // bits with separate instructions, which are at least four cycles
        // apart; writes exactly one cycle apart are the read-modify-write
        // pattern the mapper is required to drop, so ticking once here would
        // make the helper test the opposite of what it means to.
        m.tick();
        m.tick();
        m.prgWrite(addr, @intCast((value >> @intCast(i)) & 1));
    }
}

/// PRG where byte 0 of each 16KB bank is that bank's own number, so a read
/// at $8000/$C000 names whichever bank is mapped there.
fn taggedPrg(comptime banks: usize) [banks * 0x4000]u8 {
    var prg = [_]u8{0} ** (banks * 0x4000);
    for (0..banks) |b| prg[b * 0x4000] = @intCast(b);
    return prg;
}

test "Mmc1 powers on in PRG mode 3, with the last bank fixed at $C000" {
    // Matters before anything else: the reset vector lives at $FFFC, so a
    // wrong power-on mode means the CPU cannot even start.
    var prg = taggedPrg(8);
    var m = Mapper{ .mmc1 = Mmc1.init(&prg, &.{}) };
    try testing.expectEqual(@as(u8, 0), m.prgRead(0x8000));
    try testing.expectEqual(@as(u8, 7), m.prgRead(0xC000));
}

test "Mmc1 commits a register only on the fifth write" {
    var prg = taggedPrg(8);
    var m = Mapper{ .mmc1 = Mmc1.init(&prg, &.{}) };
    // Four writes of bank 3 (00011): nothing should move yet.
    for (0..4) |i| {
        m.tick();
        m.tick();
        m.prgWrite(0xE000, @intCast((@as(u8, 3) >> @intCast(i)) & 1));
    }
    try testing.expectEqual(@as(u8, 0), m.prgRead(0x8000));
    m.tick();
    m.tick();
    m.prgWrite(0xE000, 0);
    try testing.expectEqual(@as(u8, 3), m.prgRead(0x8000));
}

test "Mmc1 bit 7 resets the shift register and restores PRG mode 3" {
    var prg = taggedPrg(8);
    var m = Mapper{ .mmc1 = Mmc1.init(&prg, &.{}) };
    mmc1Write(&m, 0x8000, 0b0_00_00); // 32KB PRG mode, single-screen lower
    try testing.expectEqual(Mirroring.single_screen_lower, m.mirroring());

    m_tick2(&m); // two cycles on, or the reset write is itself dropped as an RMW
    m.prgWrite(0x8000, 0x80); // reset: control |= $0C
    try testing.expectEqual(@as(u8, 7), m.prgRead(0xC000)); // mode 3 again
    // Mirroring bits are not touched by the reset: only $0C is ORed in.
    try testing.expectEqual(Mirroring.single_screen_lower, m.mirroring());
}

test "Mmc1 PRG mode 2 fixes the first bank and switches $C000" {
    var prg = taggedPrg(8);
    var m = Mapper{ .mmc1 = Mmc1.init(&prg, &.{}) };
    mmc1Write(&m, 0x8000, 0b0_10_11); // PRG mode 2, horizontal
    mmc1Write(&m, 0xE000, 5);
    try testing.expectEqual(@as(u8, 0), m.prgRead(0x8000));
    try testing.expectEqual(@as(u8, 5), m.prgRead(0xC000));
}

test "Mmc1 PRG mode 3 switches $8000 and fixes the last bank" {
    var prg = taggedPrg(8);
    var m = Mapper{ .mmc1 = Mmc1.init(&prg, &.{}) };
    mmc1Write(&m, 0x8000, 0b0_11_11); // PRG mode 3, horizontal
    mmc1Write(&m, 0xE000, 5);
    try testing.expectEqual(@as(u8, 5), m.prgRead(0x8000));
    try testing.expectEqual(@as(u8, 7), m.prgRead(0xC000));
}

test "Mmc1 32KB PRG mode ignores the bank number's low bit" {
    var prg = taggedPrg(8);
    var m = Mapper{ .mmc1 = Mmc1.init(&prg, &.{}) };
    mmc1Write(&m, 0x8000, 0b0_00_11); // PRG mode 0 (32KB), horizontal
    mmc1Write(&m, 0xE000, 5); // odd: selects the 32KB pair starting at bank 4
    try testing.expectEqual(@as(u8, 4), m.prgRead(0x8000));
    try testing.expectEqual(@as(u8, 5), m.prgRead(0xC000));
}

test "Mmc1 SUROM drives PRG A18 from the CHR bank register" {
    // 512KB: 32 banks, two 256KB halves. The fixed bank in mode 3 is the
    // last bank *of the selected half* (15 or 31), not of the whole ROM.
    // Getting that wrong is the classic SUROM bug, and holy-mapperel's `SU`
    // Morse code exists for exactly it.
    var prg = taggedPrg(32);
    var m = Mapper{ .mmc1 = Mmc1.init(&prg, &.{}) };
    mmc1Write(&m, 0x8000, 0b0_11_11); // PRG mode 3
    mmc1Write(&m, 0xE000, 2);
    try testing.expectEqual(@as(u8, 2), m.prgRead(0x8000));
    try testing.expectEqual(@as(u8, 15), m.prgRead(0xC000));

    mmc1Write(&m, 0xA000, 0b10000); // CHR bank bit 4 -> PRG A18 -> upper half
    try testing.expectEqual(@as(u8, 16 + 2), m.prgRead(0x8000));
    try testing.expectEqual(@as(u8, 31), m.prgRead(0xC000));
}

test "Mmc1 does not apply PRG A18 on boards of 256KB or less" {
    var prg = taggedPrg(16); // 256KB: no A18 line on the board at all
    var m = Mapper{ .mmc1 = Mmc1.init(&prg, &.{}) };
    mmc1Write(&m, 0x8000, 0b0_11_11);
    mmc1Write(&m, 0xE000, 2);
    mmc1Write(&m, 0xA000, 0b10000);
    try testing.expectEqual(@as(u8, 2), m.prgRead(0x8000));
    try testing.expectEqual(@as(u8, 15), m.prgRead(0xC000));
}

test "Mmc1 switches 8KB and 4KB CHR-ROM banks" {
    // 32KB CHR: byte 0 of each 4KB bank is that bank's number.
    var chr = [_]u8{0} ** 0x8000;
    for (0..8) |b| chr[b * 0x1000] = @intCast(b);
    var prg = taggedPrg(2);
    var m = Mapper{ .mmc1 = Mmc1.init(&prg, &chr) };

    mmc1Write(&m, 0x8000, 0b0_11_11); // 8KB CHR mode
    mmc1Write(&m, 0xA000, 2); // 8KB mode uses bank>>1: selects 4KB banks 2,3
    try testing.expectEqual(@as(u8, 2), m.chrRead(0x0000));
    try testing.expectEqual(@as(u8, 3), m.chrRead(0x1000));

    mmc1Write(&m, 0x8000, 0b1_11_11); // 4KB CHR mode
    mmc1Write(&m, 0xA000, 6);
    mmc1Write(&m, 0xC000, 1);
    try testing.expectEqual(@as(u8, 6), m.chrRead(0x0000));
    try testing.expectEqual(@as(u8, 1), m.chrRead(0x1000));
}

test "Mmc1 CHR-RAM is writable, and banked in 4KB mode" {
    // 8KB of CHR-RAM is the whole address space, which makes it tempting to
    // treat as unbanked -- but in 4KB mode the bank registers still choose
    // which half each window shows. holy-mapperel'''s detailed CHR test
    // caught this; the first implementation here got it wrong.
    var prg = taggedPrg(2);
    var m = Mapper{ .mmc1 = Mmc1.init(&prg, &.{}) }; // no CHR-ROM => 8KB CHR-RAM
    mmc1Write(&m, 0x8000, 0b1_11_11); // 4KB CHR mode
    m.chrWrite(0x0100, 0xAB); // into RAM half 0, via $0000-$0FFF
    try testing.expectEqual(@as(u8, 0xAB), m.chrRead(0x0100));

    mmc1Write(&m, 0xA000, 1); // now half 1 shows at $0000
    try testing.expectEqual(@as(u8, 0x00), m.chrRead(0x0100));
    mmc1Write(&m, 0xC000, 0); // ... and half 0 at $1000
    try testing.expectEqual(@as(u8, 0xAB), m.chrRead(0x1100));

    // 8KB mode ignores the bank registers entirely: half 0 is back at $0000.
    mmc1Write(&m, 0x8000, 0b0_11_11);
    try testing.expectEqual(@as(u8, 0xAB), m.chrRead(0x0100));
}

test "Mmc1 maps control bits 0-1 onto all four mirroring modes" {
    var prg = taggedPrg(2);
    var m = Mapper{ .mmc1 = Mmc1.init(&prg, &.{}) };
    const cases = [_]struct { bits: u5, want: Mirroring }{
        .{ .bits = 0b0_11_00, .want = .single_screen_lower },
        .{ .bits = 0b0_11_01, .want = .single_screen_upper },
        .{ .bits = 0b0_11_10, .want = .vertical },
        .{ .bits = 0b0_11_11, .want = .horizontal },
    };
    for (cases) |c| {
        mmc1Write(&m, 0x8000, c.bits);
        try testing.expectEqual(c.want, m.mirroring());
    }
}

test "Mmc1 ignores the second write of a read-modify-write" {
    // The behavior `TestStub`'s doc comment anticipated: an NMOS RMW emits
    // the unmodified value and then the modified one on consecutive cycles,
    // and the hardware latches only the first. Without this, a game that
    // INCs a mapper register (Bill & Ted's is the usual example) shifts in
    // twice the bits it means to.
    //
    // Stated as an equivalence, which is what the rule actually claims: five
    // RMW *pairs* must leave the register exactly where five plain writes
    // would. If the second write of each pair were taken, ten bits would go
    // in and the register would commit on the wrong one.
    var prg = taggedPrg(8);

    var rmw = Mapper{ .mmc1 = Mmc1.init(&prg, &.{}) };
    for (0..5) |_| {
        m_tick2(&rmw);
        rmw.prgWrite(0xE000, 1); // the dummy write hardware latches
        rmw.tick();
        rmw.prgWrite(0xE000, 0); // one cycle later: the modified value, dropped
    }

    var plain = Mapper{ .mmc1 = Mmc1.init(&prg, &.{}) };
    mmc1Write(&plain, 0xE000, 0b11111);

    // Bank $1F, masked to 4 bits and wrapped into an 8-bank ROM: bank 7.
    try testing.expectEqual(@as(u8, 7), plain.prgRead(0x8000));
    try testing.expectEqual(plain.prgRead(0x8000), rmw.prgRead(0x8000));
}


test "Mmc1 reports no IRQ" {
    var prg = taggedPrg(2);
    var m = Mapper{ .mmc1 = Mmc1.init(&prg, &.{}) };
    try testing.expect(!m.irqPending());
    m.irqAcknowledge(); // must not panic
}

/// CNROM (mapper 3): the mirror image of UxROM (M7b) -- fixed PRG exactly
/// like `Nrom`, switchable CHR instead of fixed. A write to *anywhere* in
/// $8000-$FFFF selects the whole 8KB CHR-ROM bank; real CNROM boards decode
/// no address lines in that range at all, only the data bus, so `prgWrite`
/// ignores `addr` entirely.
///
/// **Only the low 2 bits of the written value are decoded.** Real CNROM
/// boards route just two data-bus lines into the bank-select latch (2 bits
/// = 4 banks = 32KB CHR-ROM, the largest a CNROM board ever shipped), so
/// `chr_bank` is a `u2` and assigning into it truncates for free. The
/// vendored ROM (`M3_P32K_C32K_H.nes`, exactly 32KB CHR-ROM = 4 banks)
/// never asks for a bank past 3, so a 2-bit mask is both what real hardware
/// does and everything this gate exercises -- see `cnrom_test.zig`.
///
/// **No bus-conflict modeling.** Real CNROM ties the bank register's input
/// to the raw CPU data bus with no gating logic, so a `STA` whose operand
/// byte disagrees with the ROM byte already sitting at that PRG address can
/// corrupt the write (the two outputs fight on the bus; the winner is
/// board- and byte-dependent, not architecturally defined). holy-mapperel's
/// CNROM bank-select routine, like every well-behaved CNROM game, writes
/// through a table whose bytes are chosen to avoid this, so nothing in
/// scope here distinguishes "modeled" from "not modeled" -- there is no
/// vendored ROM to validate a bus-conflict model against. Deferred rather
/// than guessed at.
///
/// **PRG is fixed** -- identical banking to `Nrom`: 16KB mirrored across
/// $8000-$FFFF, or 32KB unmirrored, no PRG bank-switch register at all.
///
/// **CHR-ROM is borrowed, not copied**, like `Mmc1.chr_rom` and unlike
/// `Nrom.chr`'s inline 8KB array. CNROM allows up to 32KB CHR; inlining
/// that would put 32KB in *every* `Mapper` value, `Nrom`'s and `TestStub`'s
/// included, since a union is as large as its largest variant -- see
/// `Mmc1`'s doc comment for the same argument in more detail. CNROM has no
/// CHR-RAM board variant (switching between CHR-ROM banks is the entire
/// point of the design), so there is no inline-RAM fallback field to
/// mirror `Mmc1.chr_ram` either.
///
/// **No IRQ.** `tick()` is empty, like `Nrom`'s.
pub const Cnrom = struct {
    prg_rom: []const u8,
    chr_rom: []const u8,
    chr_bank: u2 = 0,
    /// Fixed for the life of the cartridge -- CNROM has no mirroring
    /// control, exactly like `Nrom`: this is exactly what the iNES header
    /// said and never changes.
    mirroring_mode: Mirroring,

    /// See the type doc comment for why `prg_rom`/`chr_rom` are borrowed
    /// slices rather than copied, unlike `Nrom.chr`.
    pub fn init(prg_rom: []const u8, chr_rom: []const u8, header_mirroring: Mirroring) Cnrom {
        return .{ .prg_rom = prg_rom, .chr_rom = chr_rom, .mirroring_mode = header_mirroring };
    }

    pub fn prgRead(self: *const Cnrom, addr: u16) u8 {
        const offset = (addr - 0x8000) % @as(u16, @intCast(self.prg_rom.len));
        return self.prg_rom[offset];
    }

    pub fn prgWrite(self: *Cnrom, addr: u16, value: u8) void {
        // No PRG bank-switch register exists: any write anywhere in
        // $8000-$FFFF selects the CHR bank instead. `addr` genuinely
        // doesn't matter here -- see the type doc comment.
        _ = addr;
        self.chr_bank = @truncate(value);
    }

    pub fn chrRead(self: *const Cnrom, addr: u16) u8 {
        const offset = @as(usize, self.chr_bank) * 0x2000 + addr;
        return self.chr_rom[offset % self.chr_rom.len];
    }

    pub fn chrWrite(self: *Cnrom, addr: u16, value: u8) void {
        // CHR-ROM: writes are no-ops, same as Nrom's CHR-ROM path.
        _ = self;
        _ = addr;
        _ = value;
    }

    pub fn irqPending(self: *const Cnrom) bool {
        _ = self;
        return false;
    }

    pub fn irqAcknowledge(self: *Cnrom) void {
        _ = self;
    }

    pub fn mirroring(self: *const Cnrom) Mirroring {
        return self.mirroring_mode;
    }

    pub fn tick(self: *Cnrom) void {
        _ = self;
    }
};

// ------------------------------------------------------------ CNROM tests

/// CHR where byte 0 of each 8KB bank is that bank's own number, so a read
/// at the start of the CHR window names whichever bank is mapped there.
fn taggedChr(comptime banks: usize) [banks * 0x2000]u8 {
    var chr = [_]u8{0} ** (banks * 0x2000);
    for (0..banks) |b| chr[b * 0x2000] = @intCast(b);
    return chr;
}

test "Cnrom.prgRead mirrors a 16KB bank across the full $8000-$FFFF window" {
    var prg = [_]u8{0xAA} ** 0x4000;
    prg[0] = 0x11;
    var chr = taggedChr(1);
    var m = Mapper{ .cnrom = Cnrom.init(&prg, &chr, .horizontal) };
    try testing.expectEqual(@as(u8, 0x11), m.prgRead(0x8000));
    try testing.expectEqual(@as(u8, 0x11), m.prgRead(0xC000)); // mirrored copy
}

test "Cnrom.prgRead does not mirror a full 32KB bank" {
    var prg = [_]u8{0xAA} ** 0x8000;
    prg[0] = 0x11;
    prg[0x4000] = 0x33;
    var chr = taggedChr(1);
    var m = Mapper{ .cnrom = Cnrom.init(&prg, &chr, .horizontal) };
    try testing.expectEqual(@as(u8, 0x11), m.prgRead(0x8000));
    try testing.expectEqual(@as(u8, 0x33), m.prgRead(0xC000));
}

test "Cnrom.prgWrite selects a CHR bank rather than writing PRG" {
    var prg = [_]u8{0x11} ** 0x4000;
    var chr = taggedChr(4);
    var m = Mapper{ .cnrom = Cnrom.init(&prg, &chr, .horizontal) };
    m.prgWrite(0x8000, 2);
    try testing.expectEqual(@as(u8, 0x11), m.prgRead(0x8000)); // PRG untouched
    try testing.expectEqual(@as(u8, 2), m.chrRead(0)); // CHR bank 2 now mapped
}

test "Cnrom selects every one of the 4 CHR banks a 32KB board can address" {
    var prg = [_]u8{0x11} ** 0x4000;
    var chr = taggedChr(4);
    var m = Mapper{ .cnrom = Cnrom.init(&prg, &chr, .horizontal) };
    for (0..4) |b| {
        m.prgWrite(0x8000, @intCast(b));
        try testing.expectEqual(@as(u8, @intCast(b)), m.chrRead(0));
        try testing.expectEqual(@as(u8, 0), m.chrRead(0x1FFF)); // whole bank swings, not just byte 0
    }
}

test "Cnrom.prgWrite masks the bank number to its low 2 bits" {
    var prg = [_]u8{0x11} ** 0x4000;
    var chr = taggedChr(4);
    var m = Mapper{ .cnrom = Cnrom.init(&prg, &chr, .horizontal) };
    m.prgWrite(0x8000, 0xFD); // 0b1111_1101 -> low 2 bits = 01 = bank 1
    try testing.expectEqual(@as(u8, 1), m.chrRead(0));
}

test "Cnrom.chrWrite is a no-op: CHR-ROM only, no CHR-RAM variant" {
    var prg = [_]u8{0x11} ** 0x4000;
    var chr = taggedChr(1);
    chr[0] = 0x42;
    var m = Mapper{ .cnrom = Cnrom.init(&prg, &chr, .horizontal) };
    m.chrWrite(0, 0xFF);
    try testing.expectEqual(@as(u8, 0x42), m.chrRead(0));
}

test "Cnrom.mirroring passes the header value through unchanged, like Nrom" {
    var prg = [_]u8{0x11} ** 0x4000;
    var chr = taggedChr(1);
    var m_h = Mapper{ .cnrom = Cnrom.init(&prg, &chr, .horizontal) };
    try testing.expectEqual(Mirroring.horizontal, m_h.mirroring());
    var m_v = Mapper{ .cnrom = Cnrom.init(&prg, &chr, .vertical) };
    try testing.expectEqual(Mirroring.vertical, m_v.mirroring());
    m_v.prgWrite(0x8000, 3); // banking activity must not disturb mirroring
    try testing.expectEqual(Mirroring.vertical, m_v.mirroring());
}

test "Cnrom never raises an IRQ" {
    var prg = [_]u8{0x11} ** 0x4000;
    var chr = taggedChr(1);
    var m = Mapper{ .cnrom = Cnrom.init(&prg, &chr, .horizontal) };
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
    mmc1: Mmc1,
    cnrom: Cnrom,
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

    /// The cartridge's *current* nametable wiring — the single source of
    /// truth, which is why `Ppu` no longer keeps a copy. NROM answers with
    /// the header value it was built from and never changes; MMC1 answers
    /// from its control register, which the running program rewrites.
    pub fn mirroring(self: *const Mapper) Mirroring {
        switch (self.*) {
            inline else => |*m| return m.mirroring(),
        }
    }

    /// One CPU cycle. Called from `Cpu.tick`, the core's single per-cycle
    /// chokepoint, beside the APU's own tick. NROM's is empty and inlines
    /// away; MMC1 needs it to tell an RMW's two writes apart, and MMC3's
    /// scanline IRQ (M7d) will need it too.
    pub fn tick(self: *Mapper) void {
        switch (self.*) {
            inline else => |*m| m.tick(),
        }
    }
};
