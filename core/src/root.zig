pub const rom = @import("rom.zig");
pub const mapper = @import("mapper.zig");

pub const Rom = rom.Rom;
pub const Header = rom.Header;
pub const Mirroring = rom.Mirroring;
pub const parseHeader = rom.parseHeader;
pub const createMapper = rom.createMapper;
pub const Mapper = mapper.Mapper;
pub const Nrom = mapper.Nrom;

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
}

test {
    _ = rom;
    _ = mapper;
}
