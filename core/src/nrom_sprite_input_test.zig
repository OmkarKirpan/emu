//! ENG-68 acceptance criterion 2: "A real NROM game (e.g. Donkey Kong)
//! renders correctly with sprites and responds to input in a native
//! test/debug harness."
//!
//! No commercial game is vendored here -- see
//! `core/tests/roms/nrom_demo/README.md` for why (copyright: this repo's
//! own licensing research, ENG-59, and `ppu_background_test.zig`'s
//! precedent both say not to). `sprite_input_demo.nes` is an original,
//! hand-written NROM ROM exercising the identical end-to-end pipeline the
//! criterion actually cares about: boot -> OAMDMA -> sprite rendering ->
//! controller input -> visible on-screen movement, all driven through the
//! real `Cpu`/`Bus`/`Ppu`/`Controller` stack rather than direct
//! register pokes (which `ppu_background_test.zig` and `ppu.zig`'s own
//! unit tests already cover for the decode pipeline in isolation).

const std = @import("std");
const testing = std.testing;

const rom_mod = @import("rom.zig");
const bus_mod = @import("bus.zig");
const cpu_mod = @import("cpu.zig");
const controller_mod = @import("controller.zig");

const Machine = struct {
    bus: bus_mod.Bus,
    cpu: cpu_mod.Cpu,

    fn init(self: *Machine, rom_bytes: []const u8) !void {
        const rom = try rom_mod.Rom.load(rom_bytes);
        self.bus = bus_mod.Bus.init(try rom_mod.createMapper(rom), rom.header.mirroring);
        self.cpu = cpu_mod.Cpu.init(&self.bus);
        self.cpu.reset();
    }

    /// Run until `Ppu.frame` has advanced by exactly `n` -- keyed off the
    /// PPU's own frame counter rather than a guessed CPU-cycle budget, so
    /// this is exact regardless of the odd-frame dot skip or of exactly
    /// where in a frame the ROM's own per-frame (NMI-driven) work happens.
    /// `frame` incrementing at all also guarantees at least one full VBLANK
    /// -- and therefore at least one opportunity for this ROM's NMI handler
    /// to fire -- has occurred.
    fn runFrames(self: *Machine, n: u32) void {
        const target = self.bus.ppu.frame + n;
        while (self.bus.ppu.frame < target) self.cpu.step();
    }

    /// Screen column of the sprite's leftmost pixel, read back from live
    /// OAM (not the CPU's own zero-page mirror) -- proof the value actually
    /// made it through OAMDMA into the PPU, not just into WRAM.
    fn spriteX(self: *const Machine) u8 {
        return self.bus.ppu.oam[3];
    }
    fn spriteY(self: *const Machine) u8 {
        return self.bus.ppu.oam[0];
    }
};

// Every test below waits out this many frames before its first check. Boot
// (2 vblank-polled waits) plus the NMI-driven main loop's own first OAMDMA
// take a few frames to land; measured empirically: raw OAM (`spriteX`/`Y`,
// which reads live PPU OAM, updated the instant an OAMDMA runs) is correct
// from frame 3 on, but the *rendered framebuffer* lags one further frame
// behind that -- a scanline's pixels for frame N are produced *before* that
// same frame's own end-of-frame NMI/OAMDMA runs, so a freshly-written OAM
// value is only visible in the framebuffer starting the *next* frame after
// the one that wrote it. `settle_frames` covers both with margin to spare.
const settle_frames = 5;

test "sprite_input_demo: boots, DMAs OAM, and renders the sprite at its initial position" {
    var m: Machine = undefined;
    try m.init(@embedFile("sprite_input_demo"));
    m.runFrames(settle_frames);

    try testing.expectEqual(@as(u8, 0x70), m.spriteY());
    try testing.expectEqual(@as(u8, 0x80), m.spriteX());

    // Tile 1 is a solid 8x8 block of pixel value 3, sprite palette group 0
    // -> palette RAM index $3F13 (sprite palettes start at $3F10, *not*
    // $3F00-$3F0F, which is the background's). Sprite Y is "top row minus
    // 1" (see `Ppu.evaluateSprites`'s doc comment), so Y=$70=112 first
    // appears on screen row 113.
    const sprite_color = m.bus.ppu.palette[0x13] & 0x3F;
    const backdrop = m.bus.ppu.palette[0] & 0x3F;
    try testing.expect(sprite_color != backdrop); // the fixture wouldn't prove anything otherwise

    var row: usize = 113;
    while (row < 113 + 8) : (row += 1) {
        var col: usize = 128;
        while (col < 128 + 8) : (col += 1) {
            try testing.expectEqual(sprite_color, m.bus.ppu.framebuffer[row * 256 + col]);
        }
    }
    // One row above and one column left of the sprite: still backdrop.
    try testing.expectEqual(backdrop, m.bus.ppu.framebuffer[112 * 256 + 128]);
    try testing.expectEqual(backdrop, m.bus.ppu.framebuffer[113 * 256 + 127]);
}

test "sprite_input_demo: holding no buttons leaves the sprite exactly where it started" {
    var m: Machine = undefined;
    try m.init(@embedFile("sprite_input_demo"));
    m.runFrames(settle_frames);
    const x0 = m.spriteX();
    const y0 = m.spriteY();

    m.runFrames(5);
    try testing.expectEqual(x0, m.spriteX());
    try testing.expectEqual(y0, m.spriteY());
}

test "sprite_input_demo: holding Right moves the sprite right, frame by frame, through real controller input" {
    var m: Machine = undefined;
    try m.init(@embedFile("sprite_input_demo"));
    m.runFrames(settle_frames);
    const x0 = m.spriteX();

    m.bus.controllers[0].setButtons(controller_mod.button_right);
    m.runFrames(8);

    try testing.expect(m.spriteX() > x0);
    try testing.expect(@as(u16, m.spriteX()) <= @as(u16, x0) + 8);
}

test "sprite_input_demo: holding Left moves the sprite left" {
    var m: Machine = undefined;
    try m.init(@embedFile("sprite_input_demo"));
    m.runFrames(settle_frames);
    const x0 = m.spriteX();

    m.bus.controllers[0].setButtons(controller_mod.button_left);
    m.runFrames(8);

    try testing.expect(m.spriteX() < x0);
}

test "sprite_input_demo: holding Up then Down moves the sprite vertically both ways" {
    var m: Machine = undefined;
    try m.init(@embedFile("sprite_input_demo"));
    m.runFrames(settle_frames);
    const y0 = m.spriteY();

    m.bus.controllers[0].setButtons(controller_mod.button_up);
    m.runFrames(8);
    const y1 = m.spriteY();
    try testing.expect(y1 < y0); // up = smaller Y = higher on screen

    m.bus.controllers[0].setButtons(controller_mod.button_down);
    m.runFrames(8);
    try testing.expect(m.spriteY() > y1);
}

test "sprite_input_demo: releasing all buttons stops further movement" {
    var m: Machine = undefined;
    try m.init(@embedFile("sprite_input_demo"));
    m.runFrames(settle_frames);

    m.bus.controllers[0].setButtons(controller_mod.button_right);
    m.runFrames(8);

    // Release, then let a couple of frames' worth of any already-in-flight
    // NMI reads of the pre-release state finish landing before taking the
    // "settled" reading -- the exact number of frames a `setButtons` call
    // needs to be reliably visible to the *very next* NMI isn't load-bearing
    // for what this test is proving (that movement genuinely stops), so
    // this stays generous rather than pinned to a specific frame count.
    m.bus.controllers[0].setButtons(0);
    m.runFrames(3);
    const settled = m.spriteX();

    m.runFrames(5);
    try testing.expectEqual(settled, m.spriteX());
}
