const std = @import("std");
const testing = std.testing;

const mapper_mod = @import("mapper.zig");
const Mapper = mapper_mod.Mapper;
const Nrom = mapper_mod.Nrom;
const Mmc1 = mapper_mod.Mmc1;
const Mmc3 = mapper_mod.Mmc3;
const Uxrom = mapper_mod.Uxrom;

/// Re-exported from `mapper.zig`, which owns it: the cartridge decides
/// mirroring at runtime, and this header field is only the power-on value.
/// `parseHeader` never produces the single-screen variants -- iNES cannot
/// express them; only a mapper (MMC1) can select them.
pub const Mirroring = mapper_mod.Mirroring;

pub const Header = struct {
    prg_rom_size: usize,
    chr_rom_size: usize,
    mapper: u8,
    mirroring: Mirroring,
    has_battery: bool,
    has_trainer: bool,
};

pub const ParseError = error{ TooShort, BadMagic };

pub fn parseHeader(data: []const u8) ParseError!Header {
    if (data.len < 16) return ParseError.TooShort;
    if (!std.mem.eql(u8, data[0..4], &[_]u8{ 'N', 'E', 'S', 0x1A })) return ParseError.BadMagic;

    const flags6 = data[6];
    const flags7 = data[7];
    const mapper: u8 = (flags6 >> 4) | (flags7 & 0xF0);
    const four_screen = (flags6 & 0x08) != 0;
    const mirroring: Mirroring = if (four_screen)
        .four_screen
    else if ((flags6 & 0x01) != 0)
        .vertical
    else
        .horizontal;

    return Header{
        .prg_rom_size = @as(usize, data[4]) * 16384,
        .chr_rom_size = @as(usize, data[5]) * 8192,
        .mapper = mapper,
        .mirroring = mirroring,
        .has_battery = (flags6 & 0x02) != 0,
        .has_trainer = (flags6 & 0x04) != 0,
    };
}

pub const Rom = struct {
    header: Header,
    prg_rom: []const u8,
    chr_rom: []const u8,

    pub const LoadError = ParseError || error{Truncated};

    pub fn load(data: []const u8) LoadError!Rom {
        const header = try parseHeader(data);
        var offset: usize = 16;
        if (header.has_trainer) offset += 512;

        const prg_end = offset + header.prg_rom_size;
        if (data.len < prg_end) return LoadError.Truncated;
        const prg_rom = data[offset..prg_end];

        const chr_end = prg_end + header.chr_rom_size;
        if (data.len < chr_end) return LoadError.Truncated;
        const chr_rom = data[prg_end..chr_end];

        return Rom{ .header = header, .prg_rom = prg_rom, .chr_rom = chr_rom };
    }
};

pub const MapperError = error{ UnsupportedMapper, InvalidRomGeometry };

pub fn createMapper(rom: Rom) MapperError!Mapper {
    return switch (rom.header.mapper) {
        0 => blk: {
            // NROM: 16KB or 32KB PRG, and 0 (CHR-RAM) or 8KB CHR-ROM.
            if (rom.prg_rom.len != 0x4000 and rom.prg_rom.len != 0x8000)
                return MapperError.InvalidRomGeometry;
            if (rom.chr_rom.len != 0 and rom.chr_rom.len != 0x2000)
                return MapperError.InvalidRomGeometry;
            break :blk Mapper{ .nrom = Nrom.init(rom.prg_rom, rom.chr_rom, rom.header.mirroring) };
        },
        1 => blk: {
            // MMC1: 16KB-512KB PRG in 16KB units, and either CHR-RAM (no
            // CHR-ROM) or 8KB-128KB CHR-ROM in 8KB units. The header's
            // mirroring is ignored -- MMC1 powers on with control = $0C and
            // drives mirroring from its own register from then on.
            if (rom.prg_rom.len < 0x4000 or rom.prg_rom.len > 0x80000 or rom.prg_rom.len % 0x4000 != 0)
                return MapperError.InvalidRomGeometry;
            if (rom.chr_rom.len > 0x20000 or rom.chr_rom.len % 0x2000 != 0)
                return MapperError.InvalidRomGeometry;
            break :blk Mapper{ .mmc1 = Mmc1.init(rom.prg_rom, rom.chr_rom) };
        },
        4 => blk: {
            // MMC3: PRG-ROM in 8KB units (its banking granularity), 16KB to
            // 512KB. CHR is either CHR-RAM (no CHR-ROM) or CHR-ROM in
            // 8KB-header-unit multiples up to 256KB -- the largest vendored
            // holy-mapperel MMC3 ROM. The header's mirroring is ignored, same
            // as MMC1: MMC3 drives it from its own $A000 register from the
            // moment the game writes it, and the register's power-on state
            // is unspecified (see `Mmc3`'s doc comment).
            if (rom.prg_rom.len < 0x4000 or rom.prg_rom.len > 0x80000 or rom.prg_rom.len % 0x2000 != 0)
                return MapperError.InvalidRomGeometry;
            if (rom.chr_rom.len > 0x40000 or rom.chr_rom.len % 0x2000 != 0)
                return MapperError.InvalidRomGeometry;
            break :blk Mapper{ .mmc3 = Mmc3.init(rom.prg_rom, rom.chr_rom) };
        },
        2 => blk: {
            // UxROM: 32KB-512KB PRG in 16KB units, always CHR-RAM (no
            // CHR-ROM at all -- unlike NROM and MMC1, UxROM boards never
            // carry CHR-ROM, so anything other than 0 is a malformed ROM
            // rather than a variant this mapper supports). The header's
            // mirroring is used as-is: UxROM has no mirroring register.
            if (rom.prg_rom.len < 0x8000 or rom.prg_rom.len > 0x80000 or rom.prg_rom.len % 0x4000 != 0)
                return MapperError.InvalidRomGeometry;
            if (rom.chr_rom.len != 0)
                return MapperError.InvalidRomGeometry;
            break :blk Mapper{ .uxrom = Uxrom.init(rom.prg_rom, rom.header.mirroring) };
        },
        else => MapperError.UnsupportedMapper,
    };
}

fn buildMinimalNrom(comptime prg_banks: u8, comptime chr_banks: u8) [16 + @as(usize, prg_banks) * 16384 + @as(usize, chr_banks) * 8192]u8 {
    var buf: [16 + @as(usize, prg_banks) * 16384 + @as(usize, chr_banks) * 8192]u8 =
        [_]u8{0} ** (16 + @as(usize, prg_banks) * 16384 + @as(usize, chr_banks) * 8192);
    buf[0] = 'N';
    buf[1] = 'E';
    buf[2] = 'S';
    buf[3] = 0x1A;
    buf[4] = prg_banks;
    buf[5] = chr_banks;
    buf[6] = 0x00;
    buf[7] = 0x00;
    return buf;
}

test "parseHeader rejects buffers shorter than 16 bytes" {
    try testing.expectError(ParseError.TooShort, parseHeader(&[_]u8{ 'N', 'E', 'S' }));
}

test "parseHeader rejects a bad magic number" {
    var bad = buildMinimalNrom(2, 1);
    bad[0] = 'X';
    try testing.expectError(ParseError.BadMagic, parseHeader(&bad));
}

test "parseHeader reads PRG/CHR sizes in bank units" {
    const buf = buildMinimalNrom(2, 1);
    const h = try parseHeader(&buf);
    try testing.expectEqual(@as(usize, 32768), h.prg_rom_size);
    try testing.expectEqual(@as(usize, 8192), h.chr_rom_size);
}

test "parseHeader splits the mapper number across flags 6 and 7" {
    var buf = buildMinimalNrom(2, 1);
    buf[6] = 0x10; // mapper low nibble = 1
    buf[7] = 0x20; // mapper high nibble = 2 -> mapper (2<<4)|1 = 33
    const h = try parseHeader(&buf);
    try testing.expectEqual(@as(u8, 33), h.mapper);
}

test "parseHeader reads mirroring, battery, and trainer flags" {
    var buf = buildMinimalNrom(2, 1);
    buf[6] = 0b0000_0111; // vertical(bit0) + battery(bit1) + trainer(bit2)
    const h = try parseHeader(&buf);
    try testing.expectEqual(Mirroring.vertical, h.mirroring);
    try testing.expect(h.has_battery);
    try testing.expect(h.has_trainer);
}

test "parseHeader four-screen flag overrides the horizontal/vertical bit" {
    var buf = buildMinimalNrom(2, 1);
    buf[6] = 0b0000_1001; // vertical bit set AND four-screen bit set
    const h = try parseHeader(&buf);
    try testing.expectEqual(Mirroring.four_screen, h.mirroring);
}

test "Rom.load slices PRG/CHR out of the file, after the header" {
    const buf = buildMinimalNrom(2, 1); // 32KB PRG, 8KB CHR
    const rom = try Rom.load(&buf);
    try testing.expectEqual(@as(u8, 0), rom.header.mapper);
    try testing.expectEqual(@as(usize, 32768), rom.prg_rom.len);
    try testing.expectEqual(@as(usize, 8192), rom.chr_rom.len);
}

test "Rom.load skips a 512-byte trainer when present" {
    var buf = buildMinimalNrom(2, 1);
    buf[6] |= 0b0000_0100; // trainer flag
    // buildMinimalNrom didn't reserve trainer space, so grow the buffer by
    // hand: allocate a fresh array with 512 extra bytes and shift PRG/CHR.
    var full: [16 + 512 + 32768 + 8192]u8 = [_]u8{0} ** (16 + 512 + 32768 + 8192);
    @memcpy(full[0..16], buf[0..16]);
    full[16 + 512] = 0xAB; // first PRG byte, after the trainer
    const rom = try Rom.load(&full);
    try testing.expectEqual(@as(u8, 0xAB), rom.prg_rom[0]);
}

test "Rom.load reports Truncated when the file is shorter than the header promises" {
    const buf = buildMinimalNrom(2, 1);
    try testing.expectError(Rom.LoadError.Truncated, Rom.load(buf[0 .. buf.len - 1]));
}

test "createMapper builds an MMC1 for mapper 1" {
    var buf = buildMinimalNrom(2, 1);
    buf[6] = 0x10; // mapper number 1 (MMC1), implemented as of M7a
    const rom = try Rom.load(&buf);
    const m = try createMapper(rom);
    try testing.expect(m == .mmc1);
}

test "createMapper returns UnsupportedMapper for a mapper outside the closed set" {
    var buf = buildMinimalNrom(2, 1);
    buf[6] = 0x50; // mapper number 5 (MMC5) — never in scope
    const rom = try Rom.load(&buf);
    try testing.expectError(MapperError.UnsupportedMapper, createMapper(rom));
}

test "createMapper rejects MMC1 geometry it cannot map" {
    var too_big = buildMinimalNrom(2, 1);
    too_big[5] = 17; // 136KB CHR-ROM: past MMC1's 128KB ceiling
    var padded = [_]u8{0} ** (16 + 2 * 16384 + 17 * 8192);
    @memcpy(padded[0..16], too_big[0..16]);
    padded[6] = 0x10;
    const rom = try Rom.load(&padded);
    try testing.expectError(MapperError.InvalidRomGeometry, createMapper(rom));
}

test "createMapper builds a Uxrom for mapper 2" {
    var buf = buildMinimalNrom(2, 0); // 32KB PRG, CHR-RAM
    buf[6] = 0x20; // mapper number 2 (UxROM)
    const rom = try Rom.load(&buf);
    const m = try createMapper(rom);
    try testing.expect(m == .uxrom);
}

test "createMapper rejects UxROM CHR-ROM -- the board never carries any" {
    var buf = buildMinimalNrom(2, 1); // 8KB CHR-ROM: not a shape UxROM has
    buf[6] = 0x20;
    const rom = try Rom.load(&buf);
    try testing.expectError(MapperError.InvalidRomGeometry, createMapper(rom));
}

test "createMapper rejects a UxROM PRG size below the 32KB floor" {
    var buf = buildMinimalNrom(1, 0); // 16KB PRG: below UxROM's 32KB minimum
    buf[6] = 0x20;
    const rom = try Rom.load(&buf);
    try testing.expectError(MapperError.InvalidRomGeometry, createMapper(rom));
}

test "createMapper rejects a ROM with 0 PRG banks" {
    const buf = buildMinimalNrom(0, 1);
    const rom = try Rom.load(&buf);
    try testing.expectError(MapperError.InvalidRomGeometry, createMapper(rom));
}

test "createMapper rejects a ROM with 3 PRG banks (48KB, neither 16 nor 32KB)" {
    const buf = buildMinimalNrom(3, 1);
    const rom = try Rom.load(&buf);
    try testing.expectError(MapperError.InvalidRomGeometry, createMapper(rom));
}

test "createMapper builds an MMC3 for mapper 4" {
    var buf = buildMinimalNrom(2, 1);
    buf[6] = 0x40; // mapper number 4 (MMC3)
    const rom = try Rom.load(&buf);
    const m = try createMapper(rom);
    try testing.expect(m == .mmc3);
}

test "createMapper rejects MMC3 geometry it cannot map" {
    var too_big = buildMinimalNrom(2, 1);
    too_big[5] = 33; // 264KB CHR-ROM: past MMC3's 256KB ceiling
    var padded = [_]u8{0} ** (16 + 2 * 16384 + 33 * 8192);
    @memcpy(padded[0..16], too_big[0..16]);
    padded[6] = 0x40;
    const rom = try Rom.load(&padded);
    try testing.expectError(MapperError.InvalidRomGeometry, createMapper(rom));
}

test "createMapper rejects an MMC3 ROM with 0 PRG banks" {
    var buf = buildMinimalNrom(0, 1);
    buf[6] = 0x40;
    const rom = try Rom.load(&buf);
    try testing.expectError(MapperError.InvalidRomGeometry, createMapper(rom));
}

test "createMapper wires an MMC3 ROM's bytes through to the Mapper interface" {
    var buf = buildMinimalNrom(2, 1);
    buf[6] = 0x40;
    buf[16] = 0x11; // first PRG byte
    buf[16 + 32768] = 0x22; // first CHR byte
    const rom = try Rom.load(&buf);
    var m = try createMapper(rom);
    // Power-on state: PRG mode 0, R6=R7=0 -> $8000 and $A000 both show bank
    // 0, the first byte of PRG.
    try testing.expectEqual(@as(u8, 0x11), m.prgRead(0x8000));
    try testing.expectEqual(@as(u8, 0x22), m.chrRead(0));
}

test "createMapper rejects a ROM with 2 CHR banks (16KB, not 0 or 8KB)" {
    const buf = buildMinimalNrom(2, 2);
    const rom = try Rom.load(&buf);
    try testing.expectError(MapperError.InvalidRomGeometry, createMapper(rom));
}

test "createMapper wires an NROM ROM's bytes through to the Mapper interface" {
    var buf = buildMinimalNrom(2, 1);
    buf[16] = 0x11; // first PRG byte
    buf[16 + 32768] = 0x22; // first CHR byte
    const rom = try Rom.load(&buf);
    var m = try createMapper(rom);
    try testing.expectEqual(@as(u8, 0x11), m.prgRead(0x8000));
    try testing.expectEqual(@as(u8, 0x22), m.chrRead(0));
}
