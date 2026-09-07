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

const controller_mod = @import("controller.zig");
const Machine = @import("machine.zig").Machine;

/// Screen column of the sprite's leftmost pixel, read back from live OAM
/// (not the CPU's own zero-page mirror) -- proof the value actually made it
/// through OAMDMA into the PPU, not just into WRAM.
fn spriteX(m: *const Machine) u8 {
    return m.bus.ppu.oam[3];
}
fn spriteY(m: *const Machine) u8 {
    return m.bus.ppu.oam[0];
}

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

    try testing.expectEqual(@as(u8, 0x70), spriteY(&m));
    try testing.expectEqual(@as(u8, 0x80), spriteX(&m));

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
    const x0 = spriteX(&m);
    const y0 = spriteY(&m);

    m.runFrames(5);
    try testing.expectEqual(x0, spriteX(&m));
    try testing.expectEqual(y0, spriteY(&m));
}

test "sprite_input_demo: holding Right moves the sprite right, frame by frame, through real controller input" {
    var m: Machine = undefined;
    try m.init(@embedFile("sprite_input_demo"));
    m.runFrames(settle_frames);
    const x0 = spriteX(&m);

    m.bus.controllers[0].setButtons(controller_mod.button_right);
    m.runFrames(8);

    try testing.expect(spriteX(&m) > x0);
    try testing.expect(@as(u16, spriteX(&m)) <= @as(u16, x0) + 8);
}

test "sprite_input_demo: holding Left moves the sprite left" {
    var m: Machine = undefined;
    try m.init(@embedFile("sprite_input_demo"));
    m.runFrames(settle_frames);
    const x0 = spriteX(&m);

    m.bus.controllers[0].setButtons(controller_mod.button_left);
    m.runFrames(8);

    try testing.expect(spriteX(&m) < x0);
}

test "sprite_input_demo: holding Up then Down moves the sprite vertically both ways" {
    var m: Machine = undefined;
    try m.init(@embedFile("sprite_input_demo"));
    m.runFrames(settle_frames);
    const y0 = spriteY(&m);

    m.bus.controllers[0].setButtons(controller_mod.button_up);
    m.runFrames(8);
    const y1 = spriteY(&m);
    try testing.expect(y1 < y0); // up = smaller Y = higher on screen

    m.bus.controllers[0].setButtons(controller_mod.button_down);
    m.runFrames(8);
    try testing.expect(spriteY(&m) > y1);
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
    const settled = spriteX(&m);

    m.runFrames(5);
    try testing.expectEqual(settled, spriteX(&m));
}

test "sprite_input_demo: the APU tone it programs reaches the mixer as a real, swinging signal (ENG-71)" {
    // ENG-71's second acceptance criterion is about audio coming out of
    // the browser, which no native test can observe directly. What a
    // native test *can* pin down is the half that everything downstream
    // depends on: that this ROM programs the APU at all, and that what the
    // core produces for it is a genuine waveform rather than silence or a
    // stuck DC level. Until M6 this fixture never touched an APU register,
    // so the entire audio pipeline could have been wired up backwards and
    // every test in the tree would still have passed.
    var m: Machine = undefined;
    try m.init(@embedFile("sprite_input_demo"));
    m.runFrames(settle_frames);

    // The ROM's own init, read back through the emulated registers.
    try testing.expect(m.bus.apu.pulse1.enabled);
    try testing.expect(m.bus.apu.pulse1.length_counter > 0);
    try testing.expect(!m.bus.apu.pulse1.muted());
    try testing.expectEqual(@as(u4, 15), m.bus.apu.pulse1.envelope.output());

    // Sample the filtered signal the APU hands to the ring, across a few
    // frames -- comfortably more than one period of the ~219Hz tone.
    var min_sample: f32 = 1.0;
    var max_sample: f32 = -1.0;
    const target_frame = m.bus.ppu.frame + 3;
    while (m.bus.ppu.frame < target_frame) {
        m.cpu.step();
        min_sample = @min(min_sample, m.bus.apu.output_sample);
        max_sample = @max(max_sample, m.bus.apu.output_sample);
    }

    // A square wave at full volume on one pulse channel is ~0.13
    // peak-to-peak out of the mixer's non-linear curve.
    try testing.expect(max_sample - min_sample > 0.05);
    // ...centred, not riding the DC offset the triangle's held DAC level
    // parks on the mixer (see `apu.zig`'s own filter test).
    try testing.expect(min_sample < 0 and max_sample > 0);
}

test "sprite_input_demo: moving the sprite retunes the pulse channel (ENG-71)" {
    // The ROM writes the sprite's Y position into the pulse timer's low
    // byte every frame, so input -> pitch is observable end to end. This
    // is what keeps the audio path exercised by the *input* tests above
    // rather than only by a static boot state.
    var m: Machine = undefined;
    try m.init(@embedFile("sprite_input_demo"));
    m.runFrames(settle_frames);
    const period_at_rest = m.bus.apu.pulse1.timer_period;

    m.bus.controllers[0].setButtons(controller_mod.button_up);
    m.runFrames(4);
    const period_after_up = m.bus.apu.pulse1.timer_period;

    try testing.expect(period_after_up != period_at_rest);
    // Up decrements Y, and Y is the timer's low byte: a shorter period.
    try testing.expect(period_after_up < period_at_rest);
    try testing.expect(!m.bus.apu.pulse1.muted()); // still audible at the new pitch
}
