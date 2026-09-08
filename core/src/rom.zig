const std = @import("std");
const testing = std.testing;

const mapper_mod = @import("mapper.zig");
const Mapper = mapper_mod.Mapper;
const Nrom = mapper_mod.Nrom;
const Mmc1 = mapper_mod.Mmc1;
const Mmc3 = mapper_mod.Mmc3;
const Uxrom = mapper_mod.Uxrom;
const Cnrom = mapper_mod.Cnrom;

/// Re-exported from `mapper.zig`, which owns it: the cartridge decides
/// mirroring at runtime, and this header field is only the power-on value.
/// `parseHeader` never produces the single-screen variants -- iNES cannot
/// express them; only a mapper (MMC1) can select them.
pub const Mirroring = mapper_mod.Mirroring;

pub const Header = struct {
    prg_rom_size: usize,
    chr_rom_size: usize,
    /// 12 bits wide in NES 2.0 (bytes 6/7's nibbles, plus byte 8's low
    /// nibble); every mapper this core supports (0-4) fits in the low 8, so
    /// widening costs nothing at any existing call site.
    mapper: u16,
    /// Byte 8's high nibble. Zero on plain iNES (the byte doesn't exist) and
    /// on every NES 2.0 ROM vendored here -- parsed because ENG-82 asks for
    /// every field iNES has no room for, not only the ones a mapper here
    /// currently reads. No mapper consults it yet.
    submapper: u8 = 0,
    mirroring: Mirroring,
    has_battery: bool,
    has_trainer: bool,
    /// Whether this header parsed as NES 2.0 (`flags7 & 0x0C == 0x08`)
    /// rather than plain iNES. See `parseHeader`.
    is_nes20: bool = false,
    /// Bytes of *non-battery-backed* PRG-RAM ($6000-$7FFF volatile WRAM) the
    /// header declares. Plain iNES has no field for this, so it defaults to
    /// `0x2000` (8KB) -- exactly the size `Bus` gave every cartridge
    /// unconditionally before ENG-79, preserved here so an old-format ROM's
    /// behavior does not change. NES 2.0 (byte 10's low nibble, a shift
    /// count: `n` -> `64 << n` bytes, `0` -> none) can say otherwise.
    prg_ram_size: usize = 0x2000,
    /// Bytes of *battery-backed* PRG-RAM (byte 10's high nibble, same shift
    /// encoding). Always 0 on a plain iNES header -- `has_battery` says
    /// *whether* $6000-$7FFF is battery-backed, iNES has no room to say how
    /// big it is.
    prg_nvram_size: usize = 0,
    /// Bytes of non-battery CHR-RAM the header declares (byte 11's low
    /// nibble). Informational only this milestone: every mapper here still
    /// infers CHR-RAM *presence* from `chr_rom.len == 0` and sizes it with a
    /// fixed inline 8KB array, the same as before ENG-82 -- parsed for
    /// completeness, not yet wired to any mapper's storage.
    chr_ram_size: usize = 0,
    /// Bytes of battery-backed CHR-RAM (byte 11's high nibble). Same
    /// informational status as `chr_ram_size`.
    chr_nvram_size: usize = 0,
};

pub const ParseError = error{ TooShort, BadMagic };

/// Decode an NES 2.0 byte 10/11-style nibble: `0` means "none present", a
/// nonzero `n` means `64 << n` bytes. Verified against
/// `core/tests/roms/holy_mapperel/M1_P512K_CR8K_S8K.nes`, whose byte 10 is
/// `$70` (high nibble 7, `64 << 7 = 8192`) for its documented 8KB
/// battery-backed WRAM -- see `parseHeader NES 2.0 PRG-RAM/CHR-RAM shift
/// counts` below and the ROM's `ATTRIBUTION.md` entry.
fn shiftCountSize(nibble: u4) usize {
    if (nibble == 0) return 0;
    return @as(usize, 64) << nibble;
}

/// Parse a 16-byte iNES/NES 2.0 header. A header is NES 2.0 when
/// `flags7 & 0x0C == 0x08`; every other value (including the historically
/// common "both bits zero" and the archive-artifact "both bits set" cases)
/// is treated as plain iNES, matching every emulator's convention. NES 2.0
/// adds four bytes iNES has no room for -- mapper bits 8-11 and the
/// submapper (byte 8), PRG/CHR ROM size extension nibbles (byte 9), and
/// PRG-RAM/CHR-RAM sizes (bytes 10-11) -- read only when the marker is
/// present; a plain-iNES header gets the exact values it always has, plus
/// the `prg_ram_size` default documented on `Header` above. This keeps every
/// already-vendored ROM parsing identically to before ENG-82, including the
/// ones `ATTRIBUTION.md` notes are secretly NES 2.0 but "work by accident"
/// today -- accidental no longer, since this parser now reads their marker
/// on purpose.
pub fn parseHeader(data: []const u8) ParseError!Header {
    if (data.len < 16) return ParseError.TooShort;
    if (!std.mem.eql(u8, data[0..4], &[_]u8{ 'N', 'E', 'S', 0x1A })) return ParseError.BadMagic;

    const flags6 = data[6];
    const flags7 = data[7];
    const is_nes20 = (flags7 & 0x0C) == 0x08;

    const four_screen = (flags6 & 0x08) != 0;
    const mirroring: Mirroring = if (four_screen)
        .four_screen
    else if ((flags6 & 0x01) != 0)
        .vertical
    else
        .horizontal;

    var mapper: u16 = (@as(u16, flags6) >> 4) | (@as(u16, flags7) & 0xF0);
    var submapper: u8 = 0;
    var prg_rom_size: usize = @as(usize, data[4]) * 16384;
    var chr_rom_size: usize = @as(usize, data[5]) * 8192;
    var prg_ram_size: usize = 0x2000;
    var prg_nvram_size: usize = 0;
    var chr_ram_size: usize = 0;
    var chr_nvram_size: usize = 0;

    if (is_nes20) {
        const byte8 = data[8];
        mapper |= @as(u16, byte8 & 0x0F) << 8;
        submapper = byte8 >> 4;

        // Byte 9: high nibbles extending the PRG/CHR bank-count bytes.
        const byte9 = data[9];
        prg_rom_size = (@as(usize, data[4]) | (@as(usize, byte9 & 0x0F) << 8)) * 16384;
        chr_rom_size = (@as(usize, data[5]) | (@as(usize, (byte9 >> 4) & 0x0F) << 8)) * 8192;

        // Byte 10: PRG-RAM sizes, low nibble non-battery / high battery.
        const byte10 = data[10];
        prg_ram_size = shiftCountSize(@intCast(byte10 & 0x0F));
        prg_nvram_size = shiftCountSize(@intCast(byte10 >> 4));

        // Byte 11: CHR-RAM sizes, same split.
        const byte11 = data[11];
        chr_ram_size = shiftCountSize(@intCast(byte11 & 0x0F));
        chr_nvram_size = shiftCountSize(@intCast(byte11 >> 4));
    }

    return Header{
        .prg_rom_size = prg_rom_size,
        .chr_rom_size = chr_rom_size,
        .mapper = mapper,
        .submapper = submapper,
        .mirroring = mirroring,
        .has_battery = (flags6 & 0x02) != 0,
        .has_trainer = (flags6 & 0x04) != 0,
        .is_nes20 = is_nes20,
        .prg_ram_size = prg_ram_size,
        .prg_nvram_size = prg_nvram_size,
        .chr_ram_size = chr_ram_size,
        .chr_nvram_size = chr_nvram_size,
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
        3 => blk: {
            // CNROM: 16KB or 32KB PRG (fixed, exactly like NROM), and 8KB-
            // 32KB switchable CHR-ROM in 8KB units. CNROM has no CHR-RAM
            // variant -- switching between CHR-ROM banks is the entire
            // point of the board -- so unlike NROM's `chr_rom.len == 0`
            // case, empty CHR is invalid geometry here rather than "use
            // CHR-RAM".
            if (rom.prg_rom.len != 0x4000 and rom.prg_rom.len != 0x8000)
                return MapperError.InvalidRomGeometry;
            if (rom.chr_rom.len == 0 or rom.chr_rom.len > 0x8000 or rom.chr_rom.len % 0x2000 != 0)
                return MapperError.InvalidRomGeometry;
            break :blk Mapper{ .cnrom = Cnrom.init(rom.prg_rom, rom.chr_rom, rom.header.mirroring) };
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
    try testing.expectEqual(@as(u16, 33), h.mapper);
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
    try testing.expectEqual(@as(u16, 0), rom.header.mapper);
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

test "createMapper builds a CNROM for mapper 3" {
    var buf = buildMinimalNrom(2, 4); // 32KB PRG, 32KB CHR-ROM
    buf[6] = 0x30; // mapper number 3 (CNROM), implemented as of M7c
    const rom = try Rom.load(&buf);
    const m = try createMapper(rom);
    try testing.expect(m == .cnrom);
}

test "createMapper rejects CNROM geometry with no CHR-ROM at all" {
    // Unlike NROM, CNROM has no CHR-RAM fallback: switching CHR-ROM banks
    // is the whole point of the board, so 0 CHR banks is invalid, not "use
    // CHR-RAM".
    var buf = buildMinimalNrom(2, 0);
    buf[6] = 0x30;
    const rom = try Rom.load(&buf);
    try testing.expectError(MapperError.InvalidRomGeometry, createMapper(rom));
}

test "createMapper rejects CNROM geometry past the 32KB CHR ceiling" {
    var too_big = buildMinimalNrom(2, 5); // 40KB CHR-ROM: past CNROM's 32KB (4-bank) ceiling
    too_big[6] = 0x30;
    const rom = try Rom.load(&too_big);
    try testing.expectError(MapperError.InvalidRomGeometry, createMapper(rom));
}

test "createMapper rejects a CNROM ROM with 3 PRG banks (48KB, neither 16 nor 32KB)" {
    var buf = buildMinimalNrom(3, 1);
    buf[6] = 0x30;
    const rom = try Rom.load(&buf);
    try testing.expectError(MapperError.InvalidRomGeometry, createMapper(rom));
}

test "createMapper wires a CNROM ROM's bytes through to the Mapper interface" {
    var buf = buildMinimalNrom(1, 2); // 16KB PRG, 16KB CHR-ROM (2 banks)
    buf[6] = 0x30;
    buf[16] = 0x11; // first PRG byte
    buf[16 + 16384 + 0x2000] = 0x22; // first byte of CHR bank 1
    const rom = try Rom.load(&buf);
    var m = try createMapper(rom);
    try testing.expectEqual(@as(u8, 0x11), m.prgRead(0x8000));
    m.prgWrite(0x8000, 1); // select CHR bank 1
    try testing.expectEqual(@as(u8, 0x22), m.chrRead(0));
}

// ------------------------------------------------- ENG-82: NES 2.0 headers

test "parseHeader treats flags7 bits 2-3 == 0b10 as the NES 2.0 marker" {
    var buf = buildMinimalNrom(2, 1);
    buf[7] = 0x08; // bits 2-3 = 0b10
    const h = try parseHeader(&buf);
    try testing.expect(h.is_nes20);
}

test "parseHeader treats every other flags7 bits 2-3 value as plain iNES" {
    for ([_]u8{ 0x00, 0x04, 0x0C }) |bits| {
        var buf = buildMinimalNrom(2, 1);
        buf[7] = bits;
        const h = try parseHeader(&buf);
        try testing.expect(!h.is_nes20);
    }
}

test "parseHeader NES 2.0 splits the mapper number across bytes 6, 7, and 8's low nibble" {
    var buf = buildMinimalNrom(2, 1);
    buf[6] = 0x10; // mapper low nibble = 1
    buf[7] = 0x28; // mapper high nibble = 2, NES 2.0 marker set -> (2<<4)|1 = 33
    buf[8] = 0x05; // mapper bits 8-11 = 5 -> 33 | (5 << 8) = 1313; submapper = 0
    const h = try parseHeader(&buf);
    try testing.expect(h.is_nes20);
    try testing.expectEqual(@as(u16, 1313), h.mapper);
}

test "parseHeader NES 2.0 reads the submapper from byte 8's high nibble" {
    var buf = buildMinimalNrom(2, 1);
    buf[7] = 0x08;
    buf[8] = 0x50; // submapper 5, mapper bits 8-11 = 0
    const h = try parseHeader(&buf);
    try testing.expectEqual(@as(u8, 5), h.submapper);
}

test "parseHeader NES 2.0 extends PRG/CHR size with byte 9's nibbles" {
    var buf = buildMinimalNrom(1, 1); // 16KB PRG, 8KB CHR in the plain iNES bytes
    buf[7] = 0x08;
    buf[9] = 0x12; // PRG high nibble 2, CHR high nibble 1
    const h = try parseHeader(&buf);
    // PRG: data[4]=1 | (2<<8) = 513 banks * 16KB; CHR: data[5]=1 | (1<<8) = 257 banks * 8KB.
    try testing.expectEqual(@as(usize, 513 * 16384), h.prg_rom_size);
    try testing.expectEqual(@as(usize, 257 * 8192), h.chr_rom_size);
}

test "parseHeader NES 2.0 byte 10 shift-counts decode to 64 << n bytes, 0 meaning none" {
    var buf = buildMinimalNrom(2, 1);
    buf[7] = 0x08;
    buf[10] = 0x00;
    var h = try parseHeader(&buf);
    try testing.expectEqual(@as(usize, 0), h.prg_ram_size);
    try testing.expectEqual(@as(usize, 0), h.prg_nvram_size);

    buf[10] = 0x70; // low nibble 0 (no non-battery), high nibble 7 -> 64<<7 = 8192
    h = try parseHeader(&buf);
    try testing.expectEqual(@as(usize, 0), h.prg_ram_size);
    try testing.expectEqual(@as(usize, 8192), h.prg_nvram_size);
}

test "parseHeader byte 10 = $70 matches holy-mapperel's vendored 8KB battery-backed WRAM ROM" {
    // Cross-check against the real file rather than trusting the decoding
    // in isolation, per ENG-82's own instruction: byte 10 of
    // M1_P512K_CR8K_S8K.nes is $70, documented as 8KB battery-backed WRAM.
    const rom_bytes = @embedFile("mapperel_M1_P512K_CR8K_S8K");
    try testing.expectEqual(@as(u8, 0x70), rom_bytes[10]);
    const h = try parseHeader(rom_bytes);
    try testing.expect(h.is_nes20);
    try testing.expectEqual(@as(usize, 0), h.prg_ram_size);
    try testing.expectEqual(@as(usize, 8192), h.prg_nvram_size);
}

test "parseHeader NES 2.0 byte 11 decodes CHR-RAM sizes the same way as byte 10" {
    var buf = buildMinimalNrom(2, 0); // CHR-RAM board
    buf[7] = 0x08;
    buf[11] = 0x08; // low nibble 8 -> 64<<8 = 16384, high nibble 0 -> 0
    const h = try parseHeader(&buf);
    try testing.expectEqual(@as(usize, 16384), h.chr_ram_size);
    try testing.expectEqual(@as(usize, 0), h.chr_nvram_size);
}

test "parseHeader plain iNES defaults prg_ram_size to 8KB, matching Bus's historical unconditional window" {
    const buf = buildMinimalNrom(2, 1); // flags7 = 0, not NES 2.0
    const h = try parseHeader(&buf);
    try testing.expect(!h.is_nes20);
    try testing.expectEqual(@as(usize, 0x2000), h.prg_ram_size);
    try testing.expectEqual(@as(usize, 0), h.prg_nvram_size);
}

