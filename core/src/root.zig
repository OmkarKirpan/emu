pub const rom = @import("rom.zig");
pub const mapper = @import("mapper.zig");
pub const bus = @import("bus.zig");
pub const cpu = @import("cpu.zig");
pub const ppu = @import("ppu.zig");

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

// Force analysis + codegen of the public surface in non-test builds
// (notably `zig build wasm`), which otherwise compiles an empty module
// due to Zig's lazy analysis never reaching unreferenced declarations.
comptime {
    _ = &parseHeader;
    _ = &createMapper;
    _ = &Rom.load;
    _ = &Mapper.prgRead;
    _ = &Mapper.prgWrite;
    _ = &Mapper.chrRead;
    _ = &Mapper.chrWrite;
    _ = &Mapper.irqPending;
    _ = &Mapper.irqAcknowledge;
    _ = &Bus.read;
    _ = &Bus.write;
    _ = &Bus.peek;
    _ = &Cpu.reset;
    _ = &Cpu.step;
    _ = &Cpu.trace;
    _ = &Cpu.setNmiLine;
    _ = &Cpu.setIrqLine;
    _ = &Ppu.init;
    _ = &Ppu.reset;
    _ = &Ppu.tick;
    _ = &Ppu.nmiSignal;
    _ = &Ppu.readRegister;
    _ = &Ppu.writeRegister;
    _ = &Ppu.peekRegister;
}

test {
    _ = rom;
    _ = mapper;
    _ = bus;
    _ = cpu;
    _ = ppu;
    // Native-only: pulls in the vendored nestest/ppu_vbl_nmi fixtures via
    // anonymous imports declared in build.zig. Deliberately reachable only
    // from this test block so `zig build wasm` never has to embed the
    // vendored test-ROM data.
    _ = @import("nestest_test.zig");
    _ = @import("ppu_vbl_nmi_test.zig");
    _ = @import("ppu_background_test.zig");
}
