//! One booted console: a `Bus` and the `Cpu` driving it, wired together.
//!
//! Every consumer of this core -- the wasm delivery module, and each native
//! test harness -- needs the identical five-step boot (parse the iNES file,
//! build its mapper, wire the bus with the cartridge's mirroring, point a
//! CPU at that bus, reset it). This is that sequence, in one place.
//!
//! **Why two-phase init** (`var m: Machine = undefined; try m.init(bytes)`)
//! rather than a `Machine.init(bytes) !Machine` that returns a value: `Cpu`
//! borrows a `*Bus`, so the bus has to already be at its final address when
//! the CPU is pointed at it. A returning constructor would take the address
//! of a temporary and hand back a struct whose `cpu.bus` dangles into it.
//! The same constraint is why a `Machine` must not be copied or moved after
//! `init` -- `cpu.bus` would still point at the original.
//!
//! `cpu.zig`'s own `TestHarness` deliberately does *not* use this: it builds
//! a machine from a bare PRG array with a hand-installed reset vector and no
//! iNES header at all, which is a different job from booting a ROM file.

const rom_mod = @import("rom.zig");
const bus_mod = @import("bus.zig");
const cpu_mod = @import("cpu.zig");

pub const Machine = struct {
    bus: bus_mod.Bus,
    cpu: cpu_mod.Cpu,

    /// Boot `rom_bytes` (a complete iNES file) from power-on. Fails with
    /// `Rom.LoadError` for a malformed file or `MapperError` for a cartridge
    /// this core can't emulate.
    pub fn init(self: *Machine, rom_bytes: []const u8) !void {
        const rom = try rom_mod.Rom.load(rom_bytes);
        self.bus = bus_mod.Bus.init(try rom_mod.createMapper(rom), rom.header.mirroring);
        self.cpu = cpu_mod.Cpu.init(&self.bus);
        self.cpu.reset();
    }

    /// Run until `Ppu.frame` has advanced by exactly `n` -- keyed off the
    /// PPU's own frame counter rather than a guessed CPU-cycle budget, so
    /// this is exact regardless of the odd-frame dot skip or of exactly
    /// where in a frame a ROM's own per-frame (NMI-driven) work happens.
    /// `frame` incrementing at all also guarantees at least one full VBLANK
    /// -- and therefore at least one opportunity for an NMI handler to fire
    /// -- has occurred.
    pub fn runFrames(self: *Machine, n: u32) void {
        const target = self.bus.ppu.frame + n;
        while (self.bus.ppu.frame < target) self.cpu.step();
    }
};
