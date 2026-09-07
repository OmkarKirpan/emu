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

    // `self` is `*Nrom`, not `*const Nrom`, even though this variant never
    // mutates anything -- see `Mapper.chrRead`'s doc comment for why the
    // interface-wide signature had to widen for M7d's MMC3.
    pub fn chrRead(self: *Nrom, addr: u16) u8 {
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

    pub fn chrRead(self: *TestStub, addr: u16) u8 {
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

    pub fn chrRead(self: *Mmc1, addr: u16) u8 {
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

/// MMC3 (mapper 4): the first cartridge here with an IRQ that actually
/// fires, and the reason `Mapper.chrRead` had to become mutable. See
/// `docs/adr/0004-mmc3-a12-from-chrread-not-a-new-hook.md`.
///
/// **Registers**, selected by address parity rather than MMC1's serial
/// shift protocol -- every write here lands immediately, so unlike `Mmc1`
/// there is no read-modify-write rule to drop and no cycle-spacing
/// requirement on the register writes themselves (the IRQ counter's A12
/// clocking is a different matter -- see below):
///
///     $8000, even  bank select  [7] CHR A12 invert  [6] PRG mode  [2:0] target register
///     $8001, odd   bank data    -> `bank_data[target register]`
///     $A000, even  mirroring    [0] 0=vertical 1=horizontal -- **opposite polarity from MMC1**
///     $A001, odd   PRG-RAM protect -- **not implemented, see below**
///     $C000, even  IRQ latch    reload value for the scanline counter
///     $C001, odd   IRQ reload   force a reload at the next qualifying A12 rise
///     $E000, even  IRQ disable  + acknowledges any pending IRQ
///     $E001, odd   IRQ enable
///
/// **Bank data** (`R0`-`R7`, `bank_data[0..8]`) means different things by
/// index: `R0`/`R1` are 2KB CHR banks (their low bit is ignored -- the
/// register can only select an even 1KB unit), `R2`-`R5` are 1KB CHR banks,
/// `R6`/`R7` are 8KB PRG banks. Which 8KB PRG window and which CHR range
/// each register drives depends on the bank-select mode/invert bits — see
/// `prgOffset`/`chrOffset`.
///
/// **PRG-RAM protect ($A001) is deliberately not implemented**, on the same
/// footing as MMC1's PRG-RAM disable bit (ENG-79): `Bus` maps $6000-$7FFF as
/// unconditional WRAM, and honoring per-cartridge write protection means
/// routing that window through `Mapper`, which is out of scope here. The
/// write itself is accepted and otherwise ignored rather than causing a
/// crash; holy-mapperel's WRAM digit reports this the same way it reports
/// MMC1's gap. See `core/tests/roms/holy_mapperel/ATTRIBUTION.md`.
///
/// **The scanline IRQ counts qualifying rises of PPU address line A12**
/// (bit 12 of the CHR address, i.e. whether the fetch targets $0000-$0FFF or
/// $1000-$1FFF), not scanlines directly -- background and sprite pattern
/// fetches alternate which half of pattern space they read roughly once per
/// scanline, which is what makes that alternation a usable scanline clock at
/// all. `observeA12`, called from both `chrRead` and `chrWrite`, is the
/// entire mechanism: no separate per-PPU-cycle hook was added (see the ADR).
pub const Mmc3 = struct {
    prg_rom: []const u8,
    /// Empty on a CHR-RAM board, in which case `chr_ram` is live instead --
    /// same convention as `Mmc1`.
    chr_rom: []const u8,
    chr_ram: [0x2000]u8 = [_]u8{0} ** 0x2000,

    /// R0-R7. Raw as written; `prgOffset`/`chrOffset` apply the low-bit mask
    /// for R0/R1 and the modulo-by-bank-count wrap.
    bank_data: [8]u8 = [_]u8{0} ** 8,
    /// The last value written to $8000: bit 7 CHR A12 invert, bit 6 PRG
    /// mode, bits 2:0 select which `bank_data` slot $8001 writes to.
    bank_select: u8 = 0,
    /// $A000 bit 0. Power-on state is unspecified on real hardware; `false`
    /// (vertical) is an arbitrary but harmless choice -- every game sets
    /// this before turning rendering on, and the vendored conformance ROMs
    /// (`mmc3_test.zig`) set it explicitly as part of mapper detection.
    mirror_horizontal: bool = false,

    /// Reload value for the scanline counter, written through $C000.
    irq_latch: u8 = 0,
    /// The scanline counter itself.
    irq_counter: u8 = 0,
    /// Set by a $C001 write; forces a reload (regardless of the counter's
    /// current value) on the next qualifying A12 rise, then clears itself.
    irq_reload_pending: bool = false,
    irq_enabled: bool = false,
    /// The cartridge IRQ line, wire-ORed into the CPU's /IRQ input by
    /// `Cpu.irqAsserted` -- same protocol `TestStub` exists to exercise.
    irq_pending: bool = false,

    /// The PPU address line this cartridge actually watches. Reflects the
    /// most recent CHR address's bit 12, updated by `observeA12` from both
    /// `chrRead` and `chrWrite` -- real hardware doesn't care whether the
    /// PPU is reading or writing, only what address it drove.
    a12: bool = false,
    /// How many `tick()` calls (the CPU/M2-cycle chokepoint ADR 0003 added
    /// for MMC1's RMW rule) have elapsed since A12 was last observed to go
    /// low. See `observeA12` for how this implements the real filter.
    a12_low_ticks: u32 = 0,

    /// Real hardware requires A12 to have been low for roughly 3 PPU cycles
    /// (an M2-based filter -- "M2" is the 2A03's own clock, one CPU cycle,
    /// which is 3 PPU dots at NTSC's fixed ratio) before a rise counts, so
    /// that a handful of closely-spaced pattern fetches that all land on the
    /// same half of CHR space don't each look like their own scanline.
    /// `tick()` only gives this mapper CPU-cycle resolution -- coarser than
    /// the spec's ~3-PPU-cycle number, but it is the finest clock the
    /// interface exposes today, and 1 is the smallest interval it can even
    /// represent: requiring "held low across at least one `tick()`" rejects
    /// exactly the case the real filter targets in this emulator's own
    /// fetch model -- multiple pattern reads issued within a single
    /// `Ppu.tick`/`Cpu.tick` call (e.g. `fetchSpriteUnits` fetching several
    /// 8x16 sprites from alternating pattern tables in one pass) with no
    /// `tick()` call between them.
    const a12_filter_min_ticks: u32 = 1;

    pub fn init(prg_rom: []const u8, chr_rom: []const u8) Mmc3 {
        return .{ .prg_rom = prg_rom, .chr_rom = chr_rom };
    }

    fn chrIsRam(self: *const Mmc3) bool {
        return self.chr_rom.len == 0;
    }

    fn chrInvert(self: *const Mmc3) bool {
        return (self.bank_select & 0x80) != 0;
    }

    fn prgModeB(self: *const Mmc3) bool {
        return (self.bank_select & 0x40) != 0;
    }

    fn prgBankCount(self: *const Mmc3) usize {
        return @max(self.prg_rom.len / 0x2000, 1);
    }

    /// Which 8KB PRG bank shows at each of the four $8000-$FFFF windows.
    /// `window`: 0 = $8000, 1 = $A000, 2 = $C000, 3 = $E000.
    fn prgBank(self: *const Mmc3, window: u2) usize {
        const total = self.prgBankCount();
        const second_last = if (total >= 2) total - 2 else 0;
        const last = total - 1;
        const r6 = self.bank_data[6] % total;
        const r7 = self.bank_data[7] % total;
        return switch (window) {
            // $A000 is always R7, and $E000 is always the last bank,
            // regardless of PRG mode -- only $8000 and $C000 trade places.
            0 => if (self.prgModeB()) second_last else r6,
            1 => r7,
            2 => if (self.prgModeB()) r6 else second_last,
            3 => last,
        };
    }

    pub fn prgRead(self: *const Mmc3, addr: u16) u8 {
        const window: u2 = @intCast((addr >> 13) & 0x03);
        const bank = self.prgBank(window);
        const offset = bank * 0x2000 + (addr & 0x1FFF);
        return self.prg_rom[offset % self.prg_rom.len];
    }

    pub fn prgWrite(self: *Mmc3, addr: u16, value: u8) void {
        const even = (addr & 1) == 0;
        switch (addr) {
            0x8000...0x9FFF => if (even) {
                self.bank_select = value;
            } else {
                self.bank_data[self.bank_select & 0x07] = value;
            },
            0xA000...0xBFFF => if (even) {
                self.mirror_horizontal = (value & 0x01) != 0;
            } else {
                // $A001, PRG-RAM protect: accepted and otherwise ignored.
                // See the type doc comment -- write protection for
                // $6000-$7FFF is out of scope (ENG-79's MMC1 gap, same
                // shape here).
            },
            0xC000...0xDFFF => if (even) {
                self.irq_latch = value;
            } else {
                self.irq_reload_pending = true;
            },
            else => if (even) {
                self.irq_enabled = false;
                self.irq_pending = false; // $E000 also acknowledges
            } else {
                self.irq_enabled = true;
            },
        }
    }

    fn chrBankCount1k(self: *const Mmc3) usize {
        const bytes = if (self.chrIsRam()) self.chr_ram.len else self.chr_rom.len;
        return @max(bytes / 0x400, 1);
    }

    /// Offset of `addr` (0x0000-0x1FFF) within CHR memory, after banking.
    ///
    /// Non-inverted, the 8KB window is six independent 1KB slots: $0000 and
    /// $0800 are each the base of a 2KB bank (`R0`, `R1` -- their register's
    /// low bit is forced off, since a 2KB bank can only start on an even 1KB
    /// unit), and $1000/$1400/$1800/$1C00 are 1KB banks `R2`-`R5`. CHR A12
    /// invert (bank-select bit 7) swaps which half holds the 2KB pair and
    /// which holds the four 1KB banks -- implemented by flipping address bit
    /// 12 before classifying it, since that bit is exactly the half select.
    fn chrOffset(self: *const Mmc3, addr: u16) usize {
        const total1k = self.chrBankCount1k();
        const a: u16 = if (self.chrInvert()) addr ^ 0x1000 else addr;
        const slot: struct { reg: u8, within: u16 } = switch ((a >> 10) & 0x7) {
            0, 1 => .{ .reg = self.bank_data[0] & 0xFE, .within = a & 0x7FF },
            2, 3 => .{ .reg = self.bank_data[1] & 0xFE, .within = a & 0x7FF },
            4 => .{ .reg = self.bank_data[2], .within = a & 0x3FF },
            5 => .{ .reg = self.bank_data[3], .within = a & 0x3FF },
            6 => .{ .reg = self.bank_data[4], .within = a & 0x3FF },
            else => .{ .reg = self.bank_data[5], .within = a & 0x3FF },
        };
        return (@as(usize, slot.reg) * 0x400 + slot.within) % (total1k * 0x400);
    }

    pub fn chrRead(self: *Mmc3, addr: u16) u8 {
        self.observeA12(addr);
        if (self.chrIsRam()) return self.chr_ram[self.chrOffset(addr)];
        return self.chr_rom[self.chrOffset(addr)];
    }

    pub fn chrWrite(self: *Mmc3, addr: u16, value: u8) void {
        self.observeA12(addr);
        if (self.chrIsRam()) self.chr_ram[self.chrOffset(addr)] = value;
    }

    /// Update the A12 edge/filter state from a CHR address, clocking the
    /// scanline counter on a qualifying rise. See the type doc comment and
    /// `a12_filter_min_ticks` for the filter itself.
    fn observeA12(self: *Mmc3, addr: u16) void {
        const level = (addr & 0x1000) != 0;
        if (level and !self.a12 and self.a12_low_ticks >= a12_filter_min_ticks) {
            self.clockIrqCounter();
        }
        if (!level and self.a12) self.a12_low_ticks = 0; // just went low: (re)start the timer
        self.a12 = level;
    }

    /// One qualifying A12 rise. Mainstream MMC3 behavior (matched here, and
    /// by most emulators and games): the IRQ fires whenever the counter
    /// value *after* this clock -- whether it got there by reload or by
    /// decrement -- is zero and IRQs are enabled, including a reload whose
    /// latch value is itself zero. A documented minority of early MMC3
    /// silicon only fires on decrement, never on a reload landing on zero;
    /// that revision is not modeled.
    fn clockIrqCounter(self: *Mmc3) void {
        if (self.irq_counter == 0 or self.irq_reload_pending) {
            self.irq_counter = self.irq_latch;
            self.irq_reload_pending = false;
        } else {
            self.irq_counter -= 1;
        }
        if (self.irq_counter == 0 and self.irq_enabled) self.irq_pending = true;
    }

    pub fn irqPending(self: *const Mmc3) bool {
        return self.irq_pending;
    }

    pub fn irqAcknowledge(self: *Mmc3) void {
        self.irq_pending = false;
    }

    pub fn mirroring(self: *const Mmc3) Mirroring {
        // Four-screen boards wire mirroring in hardware and ignore this bit
        // entirely; not modeled here (no vendored four-screen MMC3 ROM).
        return if (self.mirror_horizontal) .horizontal else .vertical;
    }

    pub fn tick(self: *Mmc3) void {
        if (!self.a12) self.a12_low_ticks +|= 1;
    }
};

// ------------------------------------------------------------ MMC3 tests

/// PRG where byte 0 of each 8KB bank is that bank's own number -- MMC3's
/// banking granularity, distinct from `taggedPrg`'s 16KB (MMC1's).
fn taggedPrg8k(comptime banks: usize) [banks * 0x2000]u8 {
    var prg = [_]u8{0} ** (banks * 0x2000);
    for (0..banks) |b| prg[b * 0x2000] = @intCast(b);
    return prg;
}

/// CHR where byte 0 of each 1KB bank is that bank's own number -- MMC3's
/// finest CHR banking granularity.
fn taggedChr1k(comptime banks: usize) [banks * 0x400]u8 {
    var chr = [_]u8{0} ** (banks * 0x400);
    for (0..banks) |b| chr[b * 0x400] = @intCast(b);
    return chr;
}

/// Drive one qualifying A12 rise the way `Ppu` actually does: a CHR read
/// below $1000 (A12 low), held low across at least one `tick()` (the
/// interval `observeA12`'s filter measures), then a CHR read at/above $1000
/// (A12 rises already having been low long enough).
fn mmc3ClockA12(m: *Mapper) void {
    _ = m.chrRead(0x0000);
    m.tick();
    m.tick();
    _ = m.chrRead(0x1000);
}

test "Mmc3 bank-data writes route to whichever register bank-select last chose, for all 8 registers" {
    var prg = taggedPrg8k(8);
    var m = Mapper{ .mmc3 = Mmc3.init(&prg, &.{}) };
    for (0..8) |r| {
        m.prgWrite(0x8000, @intCast(r)); // select register r
        m.prgWrite(0x8001, @intCast(0x10 + r)); // a distinct value per register
    }
    for (0..8) |r| {
        try testing.expectEqual(@as(u8, @intCast(0x10 + r)), m.mmc3.bank_data[r]);
    }
}

test "Mmc3 PRG mode 0: $8000 switches via R6, $C000 fixed to the second-to-last bank, $E000 always the last" {
    var prg = taggedPrg8k(8); // banks 0-7; second-to-last = 6, last = 7
    var m = Mapper{ .mmc3 = Mmc3.init(&prg, &.{}) };
    m.prgWrite(0x8000, 0x06); // select R6, mode bit (6) clear
    m.prgWrite(0x8001, 3);
    try testing.expectEqual(@as(u8, 3), m.prgRead(0x8000));
    try testing.expectEqual(@as(u8, 6), m.prgRead(0xC000));
    try testing.expectEqual(@as(u8, 7), m.prgRead(0xE000));
}

test "Mmc3 PRG mode 1 (bank-select bit 6) swaps the fixed and switchable halves" {
    var prg = taggedPrg8k(8);
    var m = Mapper{ .mmc3 = Mmc3.init(&prg, &.{}) };
    m.prgWrite(0x8000, 0x46); // select R6, mode bit 6 set
    m.prgWrite(0x8001, 3);
    try testing.expectEqual(@as(u8, 6), m.prgRead(0x8000)); // now fixed second-to-last
    try testing.expectEqual(@as(u8, 3), m.prgRead(0xC000)); // now switchable via R6
    try testing.expectEqual(@as(u8, 7), m.prgRead(0xE000)); // unaffected by PRG mode
}

test "Mmc3 $A000 (R7) is always the switchable window regardless of PRG mode" {
    var prg = taggedPrg8k(8);
    var m = Mapper{ .mmc3 = Mmc3.init(&prg, &.{}) };
    m.prgWrite(0x8000, 0x07);
    m.prgWrite(0x8001, 5);
    try testing.expectEqual(@as(u8, 5), m.prgRead(0xA000));
    m.prgWrite(0x8000, 0x47); // flip PRG mode: R7/$A000 is unaffected either way
    try testing.expectEqual(@as(u8, 5), m.prgRead(0xA000));
}

test "Mmc3 CHR mode 0 (bank-select bit 7 clear): 2KB banks at $0000, 1KB banks at $1000" {
    var chr = taggedChr1k(16);
    var prg = taggedPrg8k(2);
    var m = Mapper{ .mmc3 = Mmc3.init(&prg, &chr) };
    m.prgWrite(0x8000, 0);
    m.prgWrite(0x8001, 4); // R0 = 4 -> 2KB @ $0000
    m.prgWrite(0x8000, 1);
    m.prgWrite(0x8001, 6); // R1 = 6 -> 2KB @ $0800
    m.prgWrite(0x8000, 2);
    m.prgWrite(0x8001, 10); // R2 = 10 -> 1KB @ $1000
    m.prgWrite(0x8000, 5);
    m.prgWrite(0x8001, 15); // R5 = 15 -> 1KB @ $1C00
    try testing.expectEqual(@as(u8, 4), m.chrRead(0x0000));
    try testing.expectEqual(@as(u8, 6), m.chrRead(0x0800));
    try testing.expectEqual(@as(u8, 10), m.chrRead(0x1000));
    try testing.expectEqual(@as(u8, 15), m.chrRead(0x1C00));
}

test "Mmc3 CHR mode 1 (bank-select bit 7 set) swaps the 2KB/1KB halves" {
    var chr = taggedChr1k(16);
    var prg = taggedPrg8k(2);
    var m = Mapper{ .mmc3 = Mmc3.init(&prg, &chr) };
    m.prgWrite(0x8000, 0x80); // select R0, CHR invert set
    m.prgWrite(0x8001, 4); // R0 = 4, now 2KB @ $1000
    m.prgWrite(0x8000, 0x82); // select R2, CHR invert set
    m.prgWrite(0x8001, 10); // R2 = 10, now 1KB @ $0000
    try testing.expectEqual(@as(u8, 10), m.chrRead(0x0000));
    try testing.expectEqual(@as(u8, 4), m.chrRead(0x1000));
}

test "Mmc3 2KB CHR banks (R0/R1) ignore the register's low bit" {
    var chr = taggedChr1k(8);
    var prg = taggedPrg8k(2);
    var m = Mapper{ .mmc3 = Mmc3.init(&prg, &chr) };
    m.prgWrite(0x8000, 0);
    m.prgWrite(0x8001, 5); // odd: the low bit is forced off, selecting bank 4
    try testing.expectEqual(@as(u8, 4), m.chrRead(0x0000));
}

test "Mmc3 $A000 bit 0 selects vertical/horizontal mirroring (opposite polarity from MMC1)" {
    var prg = taggedPrg8k(2);
    var m = Mapper{ .mmc3 = Mmc3.init(&prg, &.{}) };
    m.prgWrite(0xA000, 0);
    try testing.expectEqual(Mirroring.vertical, m.mirroring());
    m.prgWrite(0xA000, 1);
    try testing.expectEqual(Mirroring.horizontal, m.mirroring());
}

test "Mmc3 does not count an A12 rise unless the line was held low across a full tick" {
    var prg = taggedPrg8k(2);
    var m = Mapper{ .mmc3 = Mmc3.init(&prg, &.{}) };
    m.prgWrite(0xC000, 1);
    m.prgWrite(0xC001, 0);
    // No `tick()` between the low and high reads -- the filter this is meant
    // to model (see `Mmc3.a12_filter_min_ticks`) must reject it.
    _ = m.chrRead(0x0000);
    _ = m.chrRead(0x1000);
    try testing.expectEqual(@as(u8, 0), m.mmc3.irq_counter); // never reloaded
    try testing.expect(!m.irqPending());
}

test "Mmc3 IRQ counter reloads from the latch on a forced reload, then decrements on each further rise" {
    var prg = taggedPrg8k(2);
    var m = Mapper{ .mmc3 = Mmc3.init(&prg, &.{}) };
    m.prgWrite(0xC000, 4); // latch = 4
    m.prgWrite(0xC001, 0); // force reload on the next qualifying rise
    mmc3ClockA12(&m);
    try testing.expectEqual(@as(u8, 4), m.mmc3.irq_counter);
    mmc3ClockA12(&m);
    try testing.expectEqual(@as(u8, 3), m.mmc3.irq_counter);
    mmc3ClockA12(&m);
    mmc3ClockA12(&m);
    mmc3ClockA12(&m);
    try testing.expectEqual(@as(u8, 0), m.mmc3.irq_counter);
}

test "Mmc3 asserts the cartridge IRQ line when the counter reaches zero and IRQs are enabled" {
    var prg = taggedPrg8k(2);
    var m = Mapper{ .mmc3 = Mmc3.init(&prg, &.{}) };
    m.prgWrite(0xC000, 1); // latch = 1
    m.prgWrite(0xC001, 0);
    m.prgWrite(0xE001, 0); // enable
    mmc3ClockA12(&m); // reload to 1
    try testing.expect(!m.irqPending());
    mmc3ClockA12(&m); // decrement to 0
    try testing.expect(m.irqPending());
}

test "Mmc3 does not assert the IRQ line while IRQs are disabled, even when the counter reaches zero" {
    var prg = taggedPrg8k(2);
    var m = Mapper{ .mmc3 = Mmc3.init(&prg, &.{}) };
    m.prgWrite(0xC000, 0); // latch = 0: the reload itself lands on zero
    m.prgWrite(0xC001, 0);
    mmc3ClockA12(&m); // would fire immediately if enabled
    try testing.expect(!m.irqPending());
}

test "Mmc3 $E000 disables IRQs and acknowledges a pending one; $E001 re-enables" {
    var prg = taggedPrg8k(2);
    var m = Mapper{ .mmc3 = Mmc3.init(&prg, &.{}) };
    m.prgWrite(0xC000, 0);
    m.prgWrite(0xC001, 0);
    m.prgWrite(0xE001, 0); // enable
    mmc3ClockA12(&m); // reload to latch 0 -> fires immediately
    try testing.expect(m.irqPending());

    m.prgWrite(0xE000, 0); // disable + acknowledge
    try testing.expect(!m.irqPending());

    mmc3ClockA12(&m); // reload to 0 again, but disabled: no IRQ
    try testing.expect(!m.irqPending());

    m.prgWrite(0xE001, 0); // re-enable
    mmc3ClockA12(&m); // reload to 0 again, now enabled: fires
    try testing.expect(m.irqPending());
}

test "Mmc3.irqAcknowledge clears a pending IRQ without touching the enable state" {
    var prg = taggedPrg8k(2);
    var m = Mapper{ .mmc3 = Mmc3.init(&prg, &.{}) };
    m.prgWrite(0xC000, 0);
    m.prgWrite(0xC001, 0);
    m.prgWrite(0xE001, 0);
    mmc3ClockA12(&m);
    try testing.expect(m.irqPending());
    m.irqAcknowledge();
    try testing.expect(!m.irqPending());
    // Not re-enabled or re-armed by acknowledge alone: another rise reloads
    // (latch is still 0) and fires again, exactly as real $E000 behaves
    // differently from a plain acknowledge-without-disable would.
    mmc3ClockA12(&m);
    try testing.expect(m.irqPending());
}

/// UxROM (mapper 2): 16KB switchable bank at $8000-$BFFF, 16KB **fixed
/// last bank** at $C000-$FFFF, always 8KB CHR-RAM (unbanked), no IRQ. This
/// is M7b, the "does the `Mapper` interface generalize?" milestone rather
/// than a hard one -- one register, no shift sequence, mirroring fixed from
/// the header exactly like `Nrom`. `tick` is empty for the same reason
/// `Nrom`'s is: nothing here needs to tell cycles apart.
///
/// **Bus conflicts are deliberately not modeled.** Real UNROM boards (bare
/// pull-down resistors, no bus-isolating logic between the CPU data bus and
/// the ROM's output during a write) AND the written value with whatever byte
/// the ROM itself is driving at that address; UOROM boards add a 74HC32 OR
/// gate that removes the conflict entirely, and holy-mapperel's own README
/// lists mapper 2 as covering both ("UNROM, UOROM (7432)") under one printed
/// board name ("U*ROM") with no separate detailed-result digit for which
/// variant is attached. The vendored ROM's PRG digit reads 0 without
/// conflict emulation (see `uxrom_test.zig`), so modeling it would add state
/// that nothing here exercises -- if a future ROM (a real UNROM game
/// depending on the conflict, rather than the more common UOROM-safe
/// convention of writing a byte matching what's already in ROM there) needs
/// it, `prgWrite` is the one place to add the AND.
pub const Uxrom = struct {
    prg_rom: []const u8,
    chr_ram: [0x2000]u8 = [_]u8{0} ** 0x2000,
    /// Selects the 16KB bank shown at $8000-$BFFF. Written by a store to
    /// *any* address in $8000-$FFFF -- there is only one register, and real
    /// boards don't decode the address further. $C000-$FFFF never consults
    /// this: see `prgRead`.
    prg_bank: u8 = 0,
    /// Fixed for the life of the cartridge, exactly like `Nrom`'s: mapper 2
    /// has no mirroring control of its own, so this is the iNES header
    /// value and nothing here ever changes it.
    mirroring_mode: Mirroring,

    pub fn init(prg_rom: []const u8, header_mirroring: Mirroring) Uxrom {
        return .{ .prg_rom = prg_rom, .mirroring_mode = header_mirroring };
    }

    fn bankCount(self: *const Uxrom) usize {
        return @max(self.prg_rom.len / 0x4000, 1);
    }

    /// $8000-$BFFF shows `prg_bank` (masked to the ROM's actual bank count,
    /// the same "wrap rather than trust an out-of-range register" approach
    /// `Mmc1.prgBanks` uses); $C000-$FFFF always shows the last bank,
    /// unconditionally, in every PRG mode there is -- UxROM has only the one
    /// mode, unlike MMC1's four.
    pub fn prgRead(self: *const Uxrom, addr: u16) u8 {
        const banks = self.bankCount();
        const bank = if (addr < 0xC000) @as(usize, self.prg_bank) % banks else banks - 1;
        const offset = bank * 0x4000 + (addr & 0x3FFF);
        return self.prg_rom[offset];
    }

    pub fn prgWrite(self: *Uxrom, addr: u16, value: u8) void {
        _ = addr; // one register, mapped across the whole $8000-$FFFF window
        self.prg_bank = value;
    }

    pub fn chrRead(self: *const Uxrom, addr: u16) u8 {
        return self.chr_ram[addr];
    }

    /// Unconditional, unlike `Nrom.chrWrite`: UxROM is always CHR-RAM, never
    /// CHR-ROM, so there is no `chr_is_ram` branch to take.
    pub fn chrWrite(self: *Uxrom, addr: u16, value: u8) void {
        self.chr_ram[addr] = value;
    }

    pub fn irqPending(self: *const Uxrom) bool {
        _ = self;
        return false;
    }

    pub fn irqAcknowledge(self: *Uxrom) void {
        _ = self;
    }

    pub fn mirroring(self: *const Uxrom) Mirroring {
        return self.mirroring_mode;
    }

    pub fn tick(self: *Uxrom) void {
        _ = self;
    }
};

// ------------------------------------------------------------ UxROM tests

test "Uxrom powers on with bank 0 at $8000 and the last bank fixed at $C000" {
    var prg = taggedPrg(8);
    var m = Mapper{ .uxrom = Uxrom.init(&prg, .horizontal) };
    try testing.expectEqual(@as(u8, 0), m.prgRead(0x8000));
    try testing.expectEqual(@as(u8, 7), m.prgRead(0xC000));
}

test "Uxrom.prgWrite selects the $8000-$BFFF bank, from any address in range" {
    // taggedPrg tags only byte 0 of each 16KB bank, so the check must land
    // on a bank boundary -- $8000, not $BFFF (offset $3FFF into the bank).
    var prg = taggedPrg(8);
    var m = Mapper{ .uxrom = Uxrom.init(&prg, .horizontal) };
    m.prgWrite(0xC123, 5); // not $8000 itself -- the register spans the window
    try testing.expectEqual(@as(u8, 5), m.prgRead(0x8000));
}

test "Uxrom fixes the last bank at $C000-$FFFF regardless of what's selected" {
    var prg = taggedPrg(8);
    var m = Mapper{ .uxrom = Uxrom.init(&prg, .horizontal) };
    m.prgWrite(0x8000, 3);
    try testing.expectEqual(@as(u8, 7), m.prgRead(0xC000));
    m.prgWrite(0x8000, 7); // even selecting the last bank into the low window...
    try testing.expectEqual(@as(u8, 7), m.prgRead(0x8000));
    try testing.expectEqual(@as(u8, 7), m.prgRead(0xC000)); // ...doesn't move the fixed one
}

test "Uxrom wraps a bank number past the ROM's actual bank count" {
    var prg = taggedPrg(8); // 8 banks: 0-7
    var m = Mapper{ .uxrom = Uxrom.init(&prg, .horizontal) };
    m.prgWrite(0x8000, 0xFF); // 255 % 8 = 7
    try testing.expectEqual(@as(u8, 7), m.prgRead(0x8000));
}

test "Uxrom.chrWrite is always honored -- CHR is always RAM" {
    var prg = taggedPrg(2);
    var m = Mapper{ .uxrom = Uxrom.init(&prg, .horizontal) };
    m.chrWrite(0x0100, 0xAB);
    try testing.expectEqual(@as(u8, 0xAB), m.chrRead(0x0100));
}

test "Uxrom.mirroring returns the header value and never changes" {
    var prg = taggedPrg(2);
    var m = Mapper{ .uxrom = Uxrom.init(&prg, .vertical) };
    try testing.expectEqual(Mirroring.vertical, m.mirroring());
    m.prgWrite(0x8000, 1); // banking activity must not perturb it
    m.chrWrite(0, 0xFF);
    try testing.expectEqual(Mirroring.vertical, m.mirroring());
}

test "Uxrom reports no IRQ" {
    var prg = taggedPrg(2);
    var m = Mapper{ .uxrom = Uxrom.init(&prg, .horizontal) };
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
    mmc3: Mmc3,
    uxrom: Uxrom,
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

    /// **`self` is mutable, unlike every other read-side method here.** Every
    /// CHR fetch already crosses this boundary carrying its address (`Ppu`'s
    /// nametable/pattern fetches, all of them), which is also the only signal
    /// MMC3 (M7d) has for PPU address line A12 -- see
    /// `docs/adr/0004-mmc3-a12-from-chrread-not-a-new-hook.md`. Counting A12
    /// rises for the scanline IRQ is unavoidably stateful, so the interface
    /// widened from `*const Mapper` rather than adding a parallel method.
    /// `Nrom`/`Mmc1`/`TestStub` take the same wider `self` and ignore it.
    pub fn chrRead(self: *Mapper, addr: u16) u8 {
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
