const std = @import("std");
const testing = std.testing;

pub const Mirroring = enum { horizontal, vertical, four_screen };

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
