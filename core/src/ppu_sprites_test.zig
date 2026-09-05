//! PPU sprite/OAM conformance stage (ENG-68 acceptance criterion 1), per
//! ENG-64's staged test-ROM harness.
//!
//! Four suites, two different result protocols:
//!
//!   * `oam_read`/`oam_stress` speak the standard Blargg `$6000` protocol
//!     (see `blargg_harness.zig`) -- straightforward OAMADDR/OAMDATA
//!     read/write semantics, no sprite rendering involved.
//!   * `sprite_hit_tests_2005.10.05`/`sprite_overflow_tests` predate that
//!     convention (2005 vintage) and instead write plain ASCII `"PASSED"` /
//!     `"FAILED #<code>"` (or `"FAILED: #<code>"`) text directly into
//!     nametable 0 -- confirmed by running one of these ROMs against this
//!     codebase's own background-rendering pipeline and observing the text
//!     land byte-for-byte in `Ppu.vram` (tile ID = ASCII code). See
//!     `core/tests/roms/sprite_hit_tests_2005.10.05/ATTRIBUTION.md` for the
//!     full derivation. `NametableMachine`/`runToResult` below implement
//!     that detection instead of polling `$6000`.
//!
//! All four suites pass in full. `oam_stress` and
//! `sprite_overflow_tests/3.Timing` were documented, asserted gaps when
//! this stage first landed: the former needed OAM byte 2's three
//! non-existent bits masked (`Ppu.writeRegister`'s $2004 case), the latter
//! needed sprite evaluation moved onto hardware's real schedule -- one
//! scanline ahead, over dots 65-256, costing two dots per OAM byte so the
//! overflow flag lands on the right dot (`Ppu.evaluateSprites`).

const std = @import("std");
const testing = std.testing;

const rom_mod = @import("rom.zig");
const bus_mod = @import("bus.zig");
const cpu_mod = @import("cpu.zig");
const determinism = @import("determinism.zig");
const harness = @import("blargg_harness.zig");

// ------------------------------------------------- $6000-protocol suites

test "oam_read" {
    try harness.expectPass("oam_read", @embedFile("oam_read"));
}

// oam_stress writes random bytes across all 256 OAM addresses and reads
// every one back, so it is the test that catches OAM byte 2's three
// non-existent bits (see `Ppu.writeRegister`'s $2004 case): miss that mask
// and it reports exactly every fourth byte from offset 2 as wrong. It was
// a documented gap through M3 on a mistaken reading of its readme's
// "passes only for one of the four random PPU-CPU synchronizations"
// caveat -- that caveat is about $2004 access timing during rendering, not
// about the analog OAM decay it was first attributed to, and the actual
// failure was this plain digital one.
test "oam_stress" {
    try harness.expectPass("oam_stress", @embedFile("oam_stress"));
}

// ------------------------------------------- nametable-text-protocol suites

/// See the module doc comment: nametable 0's tile grid always lives at
/// `Ppu.vram` offset 0 regardless of mirroring mode (`physicalNametable`
/// maps logical nametable 0 to physical bank 0 either way), so reading the
/// first 960 bytes (32x30 tiles, before the 64-byte attribute table at
/// $3C0-$3FF) directly is valid for any of these ROMs' mirroring header.
const NametableMachine = struct {
    bus: bus_mod.Bus,
    cpu: cpu_mod.Cpu,

    fn init(self: *NametableMachine, rom_bytes: []const u8) !void {
        const rom = try rom_mod.Rom.load(rom_bytes);
        self.bus = bus_mod.Bus.init(try rom_mod.createMapper(rom), rom.header.mirroring);
        self.cpu = cpu_mod.Cpu.init(&self.bus);
        self.cpu.reset();
    }

    fn nametableText(self: *const NametableMachine, buf: *[960]u8) []const u8 {
        @memcpy(buf, self.bus.ppu.vram[0..960]);
        return buf[0..960];
    }
};

/// Generous ceiling on total emulated CPU cycles (roughly 45 seconds of NES
/// time). Every ROM in these two suites reports a result in well under a
/// second of NES time in practice; this exists purely so a genuine hang
/// fails the test instead of hanging CI.
const max_cycles: u64 = 80_000_000;
const poll_interval_cycles: u64 = 20_000;

const NametableResult = union(enum) { passed, failed: u32 };

/// Parse the digits immediately following a `"FAILED"` match (works for
/// both `"FAILED #2"` and `"FAILED: #2"` -- the two suites format this
/// differently, see each `ATTRIBUTION.md`).
fn failureCode(text: []const u8, failed_at: usize) ?u32 {
    var i = failed_at;
    while (i < text.len and !(text[i] >= '0' and text[i] <= '9')) : (i += 1) {}
    if (i >= text.len) return null;
    var code: u32 = 0;
    while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) {
        code = code * 10 + (text[i] - '0');
    }
    return code;
}

fn runToResult(m: *NametableMachine) !NametableResult {
    var buf: [960]u8 = undefined;
    while (m.cpu.cycles < max_cycles) {
        const target = m.cpu.cycles + poll_interval_cycles;
        while (m.cpu.cycles < target) m.cpu.step();
        const text = m.nametableText(&buf);
        if (std.mem.indexOf(u8, text, "PASSED")) |_| return .passed;
        if (std.mem.indexOf(u8, text, "FAILED")) |idx| {
            if (failureCode(text, idx)) |code| return .{ .failed = code };
        }
    }
    return error.Timeout;
}

fn expectPassText(name: []const u8, rom_bytes: []const u8) !void {
    var m: NametableMachine = undefined;
    try m.init(rom_bytes);
    switch (try runToResult(&m)) {
        .passed => {},
        .failed => |code| {
            std.debug.print("\n{s}: FAILED #{d}\n", .{ name, code });
            return error.TestUnexpectedResult;
        },
    }
}

test "sprite_hit 01.basics" {
    try expectPassText("sprite_hit/01.basics", @embedFile("sprite_hit_01.basics"));
}
test "sprite_hit 02.alignment" {
    try expectPassText("sprite_hit/02.alignment", @embedFile("sprite_hit_02.alignment"));
}
test "sprite_hit 03.corners" {
    try expectPassText("sprite_hit/03.corners", @embedFile("sprite_hit_03.corners"));
}
test "sprite_hit 04.flip" {
    try expectPassText("sprite_hit/04.flip", @embedFile("sprite_hit_04.flip"));
}
test "sprite_hit 05.left_clip" {
    try expectPassText("sprite_hit/05.left_clip", @embedFile("sprite_hit_05.left_clip"));
}
test "sprite_hit 06.right_edge" {
    try expectPassText("sprite_hit/06.right_edge", @embedFile("sprite_hit_06.right_edge"));
}
test "sprite_hit 07.screen_bottom" {
    try expectPassText("sprite_hit/07.screen_bottom", @embedFile("sprite_hit_07.screen_bottom"));
}
test "sprite_hit 08.double_height" {
    try expectPassText("sprite_hit/08.double_height", @embedFile("sprite_hit_08.double_height"));
}
test "sprite_hit 09.timing_basics" {
    try expectPassText("sprite_hit/09.timing_basics", @embedFile("sprite_hit_09.timing_basics"));
}
test "sprite_hit 10.timing_order" {
    try expectPassText("sprite_hit/10.timing_order", @embedFile("sprite_hit_10.timing_order"));
}
test "sprite_hit 11.edge_timing" {
    try expectPassText("sprite_hit/11.edge_timing", @embedFile("sprite_hit_11.edge_timing"));
}

test "sprite_overflow 1.Basics" {
    try expectPassText("sprite_overflow/1.Basics", @embedFile("sprite_overflow_1.Basics"));
}
test "sprite_overflow 2.Details" {
    try expectPassText("sprite_overflow/2.Details", @embedFile("sprite_overflow_2.Details"));
}
// 3.Timing measures *when* in the frame the overflow flag fires, to within
// a CPU clock or two. It was a documented, asserted gap through M3, failing
// at sub-test #5 ("set too late for first scanline"), because evaluation
// used to run at the dot 1 of the scanline being drawn rather than one
// scanline ahead on hardware's dots 65-256 schedule. Both halves of that --
// the lookahead and the two-dots-per-OAM-byte accounting that places the
// flag's dot -- are what `Ppu.evaluateSprites` now does.
test "sprite_overflow 3.Timing" {
    try expectPassText("sprite_overflow/3.Timing", @embedFile("sprite_overflow_3.Timing"));
}
test "sprite_overflow 4.Obscure" {
    try expectPassText("sprite_overflow/4.Obscure", @embedFile("sprite_overflow_4.Obscure"));
}
test "sprite_overflow 5.Emulator" {
    try expectPassText("sprite_overflow/5.Emulator", @embedFile("sprite_overflow_5.Emulator"));
}

// `assert_deterministic` (ENG-65), wired into this stage per ENG-66's
// precedent for each conformance stage: two power-on runs of the same ROM,
// for the same fixed cycle budget, must hash identically -- now covering
// the sprite-pipeline and controller state `determinism.zig` added for this
// milestone. `oam_stress` is a good fixture here specifically because it
// exercises OAM writes (and therefore the sprite pipeline's inputs) far
// more than a static test screen would.
test "assertDeterministic: two power-on runs of oam_stress hash identically" {
    try determinism.assertDeterministic(@embedFile("oam_stress"), 200_000);
}
