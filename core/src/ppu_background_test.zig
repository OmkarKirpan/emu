//! Background tile+attribute+palette decode correctness (ENG-66 acceptance
//! criterion 2).
//!
//! Deliberately not a real game ROM (copyright risk, no licensing research
//! backs one) and not even a hand-assembled 6502 program: the CPU executes
//! nothing here. What is under test is the pattern/attribute/palette decode
//! pipeline (`Ppu.renderCycle`/`outputPixel`), so this drives `Ppu` directly
//! through its public register interface ($2006/$2007) -- exactly as
//! `ppu.zig`'s own register tests do -- to load one recognizable non-blank
//! tile into an otherwise-blank 32x30 nametable, then checks *every* pixel
//! of a full rendered frame against a hand-derived expected value. Every
//! byte written below has its derivation spelled out in a comment; nothing
//! here is a hash with no traceable origin.
//!
//! Four fixtures, each isolating one decode axis: the full-frame single-tile
//! check (pattern bitplanes, one attribute quadrant, palette lookup); the
//! PPUMASK left-column mask; all four attribute quadrants of one cell, which
//! is what pins `fetchAttributeByte`'s two quadrant shifts to the right axes;
//! and fine-X scroll, the only test in the tree that reaches `outputPixel`'s
//! `0x8000 >> fine_x` mux with a non-zero shift.

const std = @import("std");
const testing = std.testing;

const ppu_mod = @import("ppu.zig");
const mapper_mod = @import("mapper.zig");
const Ppu = ppu_mod.Ppu;
const Mapper = mapper_mod.Mapper;
const Nrom = mapper_mod.Nrom;

fn setAddr(ppu: *Ppu, mapper: *Mapper, addr: u16) void {
    ppu.writeRegister(0x2006, @intCast(addr >> 8), mapper);
    ppu.writeRegister(0x2006, @intCast(addr & 0x00FF), mapper);
}

fn writeSequential(ppu: *Ppu, mapper: *Mapper, start_addr: u16, bytes: []const u8) void {
    setAddr(ppu, mapper, start_addr);
    for (bytes) |b| ppu.writeRegister(0x2007, b, mapper);
}

test "background pipeline decodes one tile's pattern+attribute+palette correctly across a full frame" {
    // CHR-RAM (0 CHR banks in the header), written through $2006/$2007 --
    // exactly the fixture shape ENG-66 asks for.
    var mapper = Mapper{ .nrom = Nrom.init(&.{}, &.{}) };
    var ppu = Ppu.init(.horizontal);

    // ---- Pattern table: tile #1, all 8 rows identical.
    //
    // A pattern-table tile is two 8-byte bitplanes; pixel value at column c
    // (0 = leftmost, matching bit 7) is (hi_bit(c) << 1) | lo_bit(c). Row
    // wants pixel values [0,1,2,3,0,1,2,3] across columns 0-7:
    //   lo bits, col0..col7: 0,1,0,1,0,1,0,1 -> 0b0101_0101 = 0x55
    //   hi bits, col0..col7: 0,0,1,1,0,0,1,1 -> 0b0011_0011 = 0x33
    // Tile 1 occupies pattern-table bytes $0010-$001F: low plane at
    // $0010-$0017 (one byte per row), high plane at $0018-$001F.
    writeSequential(&ppu, &mapper, 0x0010, &([_]u8{0x55} ** 8));
    writeSequential(&ppu, &mapper, 0x0018, &([_]u8{0x33} ** 8));
    // Tile #0 is left untouched: CHR-RAM starts zeroed, so it's all pixel
    // value 0 (transparent -- shows the backdrop color everywhere).

    // ---- Nametable 0 ($2000-$23BF): tile #0 everywhere except (col=5,
    // row=3), which gets tile #1. Nametable address = $2000 + row*32 + col.
    setAddr(&ppu, &mapper, 0x2000 + 3 * 32 + 5);
    ppu.writeRegister(0x2007, 1, &mapper);

    // ---- Attribute table ($23C0-$23FF): one byte per 4x4-tile (32x32px)
    // cell, its four 2-bit fields selecting the palette group for each
    // 2x2-tile quadrant (bits 1:0 top-left, 3:2 top-right, 5:4 bottom-left,
    // 7:6 bottom-right -- see `Ppu.fetchAttributeByte`). Tile (5,3) is in
    // cell (5>>2, 3>>2) = (1, 0), at attribute address
    // $23C0 + (3>>2)*8 + (5>>2) = $23C0 + 0 + 1 = $23C1. Within that cell,
    // tile (5,3)'s quadrant is selected by (col&2, row&2) = (5&2, 3&2) =
    // (0, 2): row&2 != 0 (bottom half), col&2 == 0 (left half) -> bottom-
    // left quadrant -> bits 5:4. Set that field to palette group 2 (0b10),
    // every other quadrant to group 0: byte = 0b00_10_00_00 = 0x20.
    setAddr(&ppu, &mapper, 0x23C1);
    ppu.writeRegister(0x2007, 0x20, &mapper);

    // ---- Palette RAM: the universal backdrop (pixel value 0, whichever
    // group) plus palette group 2's three real entries (pixel values 1-3).
    // Group g's non-zero entries live at $3F00 + g*4 + {1,2,3}.
    setAddr(&ppu, &mapper, 0x3F00);
    ppu.writeRegister(0x2007, 0x0F, &mapper); // backdrop
    setAddr(&ppu, &mapper, 0x3F09); // group 2, pixel value 1 ($3F00 + 2*4 + 1)
    ppu.writeRegister(0x2007, 0x16, &mapper);
    setAddr(&ppu, &mapper, 0x3F0A); // group 2, pixel value 2
    ppu.writeRegister(0x2007, 0x27, &mapper);
    setAddr(&ppu, &mapper, 0x3F0B); // group 2, pixel value 3
    ppu.writeRegister(0x2007, 0x30, &mapper);

    // The $2006/$2007 sequences above leave `v`/`t` pointing wherever the
    // last one left off (palette RAM). Point them back at nametable 0 --
    // but note $2006=$2000 alone does NOT give fine Y = 0: `t`/`v` are
    // addressed and scrolled through the *same* 15 bits (see the `v`/`t`
    // doc comment in ppu.zig), and $2006's first write drops its data
    // byte's bits straight into t's bits 8-13 with no reinterpretation --
    // so $2006=$20,$00 sets bit 13, which is fine Y's middle bit, to 1
    // (fine Y = 2). This is real, documented NES scroll/address aliasing,
    // not a bug: it's why games avoid depending on $2006 for scroll reset.
    // Clear fine Y (and re-zero coarse X/Y for good measure) the way a real
    // boot sequence does: two $2005 (PPUSCROLL) writes of 0. Unlike $2006,
    // $2005 doesn't touch the nametable-select bits, so nametable 0 (already
    // set above) survives.
    setAddr(&ppu, &mapper, 0x2000);
    ppu.writeRegister(0x2005, 0, &mapper);
    ppu.writeRegister(0x2005, 0, &mapper);

    // Enable background rendering, including its leftmost 8 columns (so
    // there's no left-column special case to reason about -- irrelevant to
    // this test's tile position, but keeps the fixture uniform).
    ppu.writeRegister(0x2001, 0b0000_1010, &mapper); // show_bg | show_bg_left

    // Two full frames: the first primes the fetch pipeline (scanline 0 has
    // no preceding pre-render scanline within this run to have prefetched
    // its first two tiles), the second is the one actually checked below.
    while (ppu.frame < 2) ppu.tick(&mapper);

    // Tile (col=5, row=3) covers screen pixels columns 40-47, rows 24-31.
    // Every row of the tile is identical (see the pattern derivation
    // above), cycling pixel values [0,1,2,3,0,1,2,3] through palette group
    // 2 -> colors [backdrop, 0x16, 0x27, 0x30, backdrop, 0x16, 0x27, 0x30].
    const backdrop: u8 = 0x0F;
    const tile_row_colors = [_]u8{ backdrop, 0x16, 0x27, 0x30, backdrop, 0x16, 0x27, 0x30 };

    var row: usize = 0;
    while (row < 240) : (row += 1) {
        var col: usize = 0;
        while (col < 256) : (col += 1) {
            const in_tile = row >= 24 and row < 32 and col >= 40 and col < 48;
            const expected = if (in_tile) tile_row_colors[col - 40] else backdrop;
            const actual = ppu.framebuffer[row * 256 + col];
            if (actual != expected) {
                std.debug.print(
                    "pixel mismatch at row {d} col {d}: expected ${X:0>2}, got ${X:0>2}\n",
                    .{ row, col, expected, actual },
                );
            }
            try testing.expectEqual(expected, actual);
        }
    }
}

test "background pipeline hides the leftmost 8 columns when PPUMASK's show_bg_left is clear" {
    var mapper = Mapper{ .nrom = Nrom.init(&.{}, &.{}) };
    var ppu = Ppu.init(.horizontal);

    // Tile #1 solid pixel-value-3 (both planes all 1s), placed at nametable
    // tile (0, 0) -- screen columns 0-7 -- so it would be visible at the
    // very left edge if not masked.
    writeSequential(&ppu, &mapper, 0x0010, &([_]u8{0xFF} ** 8)); // low plane
    writeSequential(&ppu, &mapper, 0x0018, &([_]u8{0xFF} ** 8)); // high plane
    setAddr(&ppu, &mapper, 0x2000);
    ppu.writeRegister(0x2007, 1, &mapper);
    setAddr(&ppu, &mapper, 0x3F00);
    ppu.writeRegister(0x2007, 0x0F, &mapper); // backdrop
    setAddr(&ppu, &mapper, 0x3F03); // group 0, pixel value 3
    ppu.writeRegister(0x2007, 0x21, &mapper);

    // show_bg set, show_bg_left clear.
    ppu.writeRegister(0x2001, 0b0000_1000, &mapper);

    while (ppu.frame < 2) ppu.tick(&mapper);

    // Columns 0-7 of row 0 read back as the backdrop despite tile #1 being
    // solid pixel-value 3 there; column 8 onward (still within the same
    // 32x32 tile's neighbor, tile (1,0) = tile #0, blank) is backdrop too,
    // so this only proves the *masking*, not an absence of the tile.
    for (0..8) |col| {
        try testing.expectEqual(@as(u8, 0x0F), ppu.framebuffer[0 * 256 + col]);
    }
}

test "attribute-table quadrant selection: all four 2x2-tile quadrants of one cell" {
    var mapper = Mapper{ .nrom = Nrom.init(&.{}, &.{}) };
    var ppu = Ppu.init(.horizontal);

    // Tile #1, solid pixel value 1: low plane all 1s, high plane all 0s, so
    // every pixel is (0 << 1) | 1 = 1 -- palette entry 1 of whichever group
    // the attribute table selects. That makes the rendered color a direct
    // readout of "which group did this quadrant resolve to".
    writeSequential(&ppu, &mapper, 0x0010, &([_]u8{0xFF} ** 8)); // low plane
    writeSequential(&ppu, &mapper, 0x0018, &([_]u8{0x00} ** 8)); // high plane

    // One tile per quadrant of attribute cell (0,0), which covers nametable
    // tiles (0..3, 0..3): top-left, top-right, bottom-left, bottom-right.
    const spots = [_][2]u16{ .{ 0, 0 }, .{ 2, 0 }, .{ 0, 2 }, .{ 2, 2 } };
    for (spots) |spot| {
        setAddr(&ppu, &mapper, 0x2000 + spot[1] * 32 + spot[0]);
        ppu.writeRegister(0x2007, 1, &mapper);
    }

    // $23C0 is cell (0,0). Bits 1:0 top-left, 3:2 top-right, 5:4 bottom-left,
    // 7:6 bottom-right -- give each quadrant a *different* group (0,1,2,3),
    // so swapping the two shifts in `fetchAttributeByte` (coarse_y's >>4 with
    // coarse_x's >>2) shows up as top-right and bottom-left trading colors.
    // 0b11_10_01_00 = 0xE4.
    setAddr(&ppu, &mapper, 0x23C0);
    ppu.writeRegister(0x2007, 0xE4, &mapper);

    // Palette entry 1 of group g lives at $3F00 + g*4 + 1.
    const group_colors = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    for (group_colors, 0..) |color, g| {
        setAddr(&ppu, &mapper, @intCast(0x3F01 + g * 4));
        ppu.writeRegister(0x2007, color, &mapper);
    }

    setAddr(&ppu, &mapper, 0x2000);
    // Two $2005 writes of 0 -- see the first test in this file for why $2006
    // alone leaves fine Y at 2 rather than 0.
    ppu.writeRegister(0x2005, 0, &mapper);
    ppu.writeRegister(0x2005, 0, &mapper);
    ppu.writeRegister(0x2001, 0b0000_1010, &mapper); // show_bg | show_bg_left
    while (ppu.frame < 2) ppu.tick(&mapper);

    // Each placed tile's top-left pixel: nametable tile (col,row) starts at
    // screen pixel (col*8, row*8).
    for (spots, group_colors) |spot, expected| {
        const px = @as(usize, spot[1]) * 8 * 256 + @as(usize, spot[0]) * 8;
        const actual = ppu.framebuffer[px];
        if (actual != expected) {
            std.debug.print(
                "quadrant at tile ({d},{d}): expected palette group color ${X:0>2}, got ${X:0>2}\n",
                .{ spot[0], spot[1], expected, actual },
            );
        }
        try testing.expectEqual(expected, actual);
    }
}

test "fine-X scroll shifts the rendered background left by fine_x pixels" {
    var mapper = Mapper{ .nrom = Nrom.init(&.{}, &.{}) };
    var ppu = Ppu.init(.horizontal);

    // Solid pixel-value-1 tile at nametable tile (1,0) -- screen columns 8-15
    // with no scroll at all.
    writeSequential(&ppu, &mapper, 0x0010, &([_]u8{0xFF} ** 8));
    writeSequential(&ppu, &mapper, 0x0018, &([_]u8{0x00} ** 8));
    setAddr(&ppu, &mapper, 0x2000 + 1);
    ppu.writeRegister(0x2007, 1, &mapper);
    setAddr(&ppu, &mapper, 0x3F00);
    ppu.writeRegister(0x2007, 0x0F, &mapper); // backdrop
    setAddr(&ppu, &mapper, 0x3F01);
    ppu.writeRegister(0x2007, 0x21, &mapper); // group 0, pixel value 1

    setAddr(&ppu, &mapper, 0x2000);
    // PPUSCROLL's first write splits into fine X (value & 7) and coarse X
    // (value >> 3): 3 means three pixels of fine-X scroll, no coarse scroll.
    ppu.writeRegister(0x2005, 3, &mapper);
    ppu.writeRegister(0x2005, 0, &mapper); // fine Y = 0, coarse Y = 0
    try testing.expectEqual(@as(u3, 3), ppu.fine_x);

    ppu.writeRegister(0x2001, 0b0000_1010, &mapper);
    while (ppu.frame < 2) ppu.tick(&mapper);

    // Scrolling the camera right by 3 pixels moves the image left by 3, so
    // the tile that would cover columns 8-15 now covers 5-12. This is the
    // only test that reaches `outputPixel`'s `0x8000 >> fine_x` mux with a
    // non-zero shift; without it, fine X is exercised as a stored register
    // value and nothing more.
    for (0..256) |col| {
        const expected: u8 = if (col >= 5 and col < 13) 0x21 else 0x0F;
        const actual = ppu.framebuffer[col];
        if (actual != expected) {
            std.debug.print(
                "fine-X mismatch at row 0 col {d}: expected ${X:0>2}, got ${X:0>2}\n",
                .{ col, expected, actual },
            );
        }
        try testing.expectEqual(expected, actual);
    }
}
