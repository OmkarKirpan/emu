const std = @import("std");
const testing = std.testing;

/// The 2C02 PPU's 64-entry palette, resolved to display RGB for the wasm
/// host's RGBA8 framebuffer (see `wasm.zig`'s `resolveFramebuffer`).
///
/// Real NTSC composite output has no single "correct" RGB palette -- it
/// varies by console revision, TV, and calibration; see
/// https://www.nesdev.org/wiki/PPU_palettes. The table below is one of the
/// most widely republished default approximations across NES emulators
/// (commonly labeled "2C02G"/"FCEUX default"). Indices the real hardware
/// never actually outputs ($0D and every "column 14/15" cell -- see the
/// palette wiki page's own grid) are conventionally black, matching every
/// other emulator using this table.
///
/// Index by a raw 6-bit `Ppu.palette`/`Ppu.framebuffer` value; each entry is
/// one R,G,B triple.
pub const rgb: [64][3]u8 = .{
    .{ 0x66, 0x66, 0x66 }, .{ 0x00, 0x2A, 0x88 }, .{ 0x14, 0x12, 0xA7 }, .{ 0x3B, 0x00, 0xA4 },
    .{ 0x5C, 0x00, 0x7E }, .{ 0x6E, 0x00, 0x40 }, .{ 0x6C, 0x06, 0x00 }, .{ 0x56, 0x1D, 0x00 },
    .{ 0x33, 0x35, 0x00 }, .{ 0x0B, 0x48, 0x00 }, .{ 0x00, 0x52, 0x00 }, .{ 0x00, 0x4F, 0x08 },
    .{ 0x00, 0x40, 0x4D }, .{ 0x00, 0x00, 0x00 }, .{ 0x00, 0x00, 0x00 }, .{ 0x00, 0x00, 0x00 },

    .{ 0xAD, 0xAD, 0xAD }, .{ 0x15, 0x5F, 0xD9 }, .{ 0x42, 0x40, 0xFF }, .{ 0x75, 0x27, 0xFE },
    .{ 0xA0, 0x1A, 0xCC }, .{ 0xB7, 0x1E, 0x7B }, .{ 0xB5, 0x31, 0x20 }, .{ 0x99, 0x4E, 0x00 },
    .{ 0x6B, 0x6D, 0x00 }, .{ 0x38, 0x87, 0x00 }, .{ 0x0C, 0x93, 0x00 }, .{ 0x00, 0x8F, 0x32 },
    .{ 0x00, 0x7C, 0x8D }, .{ 0x00, 0x00, 0x00 }, .{ 0x00, 0x00, 0x00 }, .{ 0x00, 0x00, 0x00 },

    .{ 0xFF, 0xFE, 0xFF }, .{ 0x64, 0xB0, 0xFF }, .{ 0x92, 0x90, 0xFF }, .{ 0xC6, 0x76, 0xFF },
    .{ 0xF3, 0x6A, 0xFF }, .{ 0xFE, 0x6E, 0xCC }, .{ 0xFE, 0x81, 0x70 }, .{ 0xEA, 0x9E, 0x22 },
    .{ 0xBC, 0xBE, 0x00 }, .{ 0x88, 0xD8, 0x00 }, .{ 0x5C, 0xE4, 0x30 }, .{ 0x45, 0xE0, 0x82 },
    .{ 0x48, 0xCD, 0xDE }, .{ 0x4F, 0x4F, 0x4F }, .{ 0x00, 0x00, 0x00 }, .{ 0x00, 0x00, 0x00 },

    .{ 0xFF, 0xFE, 0xFF }, .{ 0xC0, 0xDF, 0xFF }, .{ 0xD3, 0xD2, 0xFF }, .{ 0xE8, 0xC8, 0xFF },
    .{ 0xFB, 0xC2, 0xFF }, .{ 0xFE, 0xC4, 0xEA }, .{ 0xFE, 0xCC, 0xC5 }, .{ 0xF7, 0xD8, 0xA5 },
    .{ 0xE4, 0xE5, 0x94 }, .{ 0xCF, 0xEF, 0x96 }, .{ 0xBD, 0xF4, 0xAB }, .{ 0xB3, 0xF3, 0xCC },
    .{ 0xB5, 0xEB, 0xF2 }, .{ 0xB8, 0xB8, 0xB8 }, .{ 0x00, 0x00, 0x00 }, .{ 0x00, 0x00, 0x00 },
};

/// `rgb`, pre-packed into the exact little-endian byte order an RGBA8
/// framebuffer wants (R at the lowest address, then G, B, and an opaque
/// alpha) -- so resolving a pixel is one `u32` load and one `u32` store
/// rather than three byte loads, three byte stores, and a constant alpha
/// store (see `wasm.zig`'s `resolveFramebuffer`, which runs this 61,440
/// times per frame at 60fps). Derived from `rgb` at comptime rather than
/// written out a second time: `rgb` above stays the single, readable,
/// greppable source of truth, and the two can never drift.
///
/// wasm is little-endian, so byte 0 of each `u32` is its low byte.
pub const rgba: [64]u32 = blk: {
    var packed_table: [64]u32 = undefined;
    for (rgb, &packed_table) |color, *entry| {
        entry.* = @as(u32, color[0]) |
            (@as(u32, color[1]) << 8) |
            (@as(u32, color[2]) << 16) |
            0xFF00_0000;
    }
    break :blk packed_table;
};

test "rgb has exactly 64 entries, one per 6-bit palette index" {
    try testing.expectEqual(@as(usize, 64), rgb.len);
}

test "index $0F -- the universal backdrop most ROMs park in palette[0] -- is black" {
    try testing.expectEqual([3]u8{ 0x00, 0x00, 0x00 }, rgb[0x0F]);
}

test "index $30 is the palette's brightest whitish entry" {
    try testing.expectEqual([3]u8{ 0xFF, 0xFE, 0xFF }, rgb[0x30]);
}

test "rgba packs every rgb entry into little-endian R,G,B,255 byte order" {
    for (rgb, rgba) |color, entry| {
        const bytes: [4]u8 = @bitCast(std.mem.nativeToLittle(u32, entry));
        try testing.expectEqual(color[0], bytes[0]);
        try testing.expectEqual(color[1], bytes[1]);
        try testing.expectEqual(color[2], bytes[2]);
        try testing.expectEqual(@as(u8, 0xFF), bytes[3]);
    }
}
