pub const rom = @import("rom.zig");
pub const mapper = @import("mapper.zig");
pub const bus = @import("bus.zig");
pub const cpu = @import("cpu.zig");
pub const ppu = @import("ppu.zig");
pub const controller = @import("controller.zig");
pub const palette = @import("palette.zig");
pub const machine = @import("machine.zig");

pub const Rom = rom.Rom;
pub const Header = rom.Header;
pub const Mirroring = rom.Mirroring;
pub const parseHeader = rom.parseHeader;
pub const createMapper = rom.createMapper;
pub const Mapper = mapper.Mapper;
pub const Nrom = mapper.Nrom;
pub const Bus = bus.Bus;
pub const Cpu = cpu.Cpu;
pub const Flags = cpu.Flags;
pub const Ppu = ppu.Ppu;
pub const Ctrl = ppu.Ctrl;
pub const Mask = ppu.Mask;
pub const Status = ppu.Status;
pub const Controller = controller.Controller;
pub const Machine = machine.Machine;

// No force-analysis block here, deliberately. One used to live at this spot,
// forcing codegen of the whole public surface because `root.zig` was itself
// the `zig build wasm` root and had no `export fn` to anchor Zig's lazy
// analysis -- without it that build compiled an empty module and caught
// nothing. As of ENG-69 (M4) the wasm root is `wasm.zig`, whose exports
// anchor analysis and transitively pull in exactly the surface the delivered
// module actually uses; `zig build test`'s own `test` block below still
// reaches every module natively. Reinstating the block would only re-add
// what it used to hide: `Cpu.trace`, `Bus.peek`, `Ppu.peekRegister` and
// `Controller.peek` are debug/test-only entry points that nothing in the
// wasm build can reach, and force-referencing them here shipped all four
// into the browser's binary.

test {
    _ = rom;
    _ = mapper;
    _ = bus;
    _ = cpu;
    _ = ppu;
    _ = controller;
    _ = palette;
    _ = @import("apu.zig");
    // Wasm-only subsystem (ENG-62, M5), but its ring-buffer/DRC logic is
    // plain Zig with no wasm-specific codegen -- reachable only from this
    // test block (not the `pub const` graph above) so it's exercised
    // natively without becoming part of this file's public library surface.
    _ = @import("audio_ring.zig");
    // Native-only: pulls in the vendored nestest/ppu_vbl_nmi/sprite fixtures
    // via anonymous imports declared in build.zig. Deliberately reachable
    // only from this test block so `zig build wasm` never has to embed the
    // vendored test-ROM data.
    _ = @import("nestest_test.zig");
    _ = @import("ppu_vbl_nmi_test.zig");
    _ = @import("ppu_background_test.zig");
    _ = @import("ppu_sprites_test.zig");
    _ = @import("nrom_sprite_input_test.zig");
}
