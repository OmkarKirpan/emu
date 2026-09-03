pub const rom = @import("rom.zig");
pub const mapper = @import("mapper.zig");
pub const bus = @import("bus.zig");
pub const cpu = @import("cpu.zig");

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
}

test {
    _ = rom;
    _ = mapper;
    _ = bus;
    _ = cpu;
    // Native-only: pulls in the vendored nestest fixtures via anonymous
    // imports declared in build.zig. Deliberately reachable only from this
    // test block so `zig build wasm` never has to embed ~900KB of test data.
    _ = @import("nestest_test.zig");
}
