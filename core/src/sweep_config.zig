//! Compile-time configuration for the ENG-78 CPU sweep, read off the root
//! source file of whatever is being compiled.
//!
//! `SingleStepTests/65x02` assumes a flat 64KB RAM address space, which is
//! not this machine's memory map. Running it needs `Bus` to stop being the
//! NES's bus and start being 64KB of RAM with a log -- for one build, and
//! never for the one a browser runs.
//!
//! **Why a root declaration rather than a `build_options` import.** The flag
//! has to be visible inside `bus.zig` and `cpu.zig`, which every module in
//! the tree reaches: the library module, the wasm module, the debugger
//! executable and the test binary. A `build_options` import would have to be
//! wired into all four in `build.zig` purely so a constant they all set to
//! `false` resolves. `@import("root")` needs no wiring at all -- the sweep
//! executable declares `pub const nes_flat_bus = true` in its own root file
//! (`cpu_sweep.zig`), every other root says nothing, and `@hasDecl` returns
//! `false` there. It is the same mechanism `std.options` uses.
//!
//! Either way the branch is comptime-known, so the production `Bus.read`/
//! `Bus.write` hot path carries no test-only branch at all: Zig never
//! analyzes the untaken side.
//!
//! The one thing this cannot configure is the *test* binary -- `zig build
//! test`'s root is Zig's own test runner, not a file here -- which is the
//! intended answer anyway. The sweep is opt-in, fetches 1.08GB, and must
//! never join `zig build test`.

const root = @import("root");

/// True only in the `zig build test-cpu-sweep` executable. See the file's
/// doc comment.
pub const flat_bus: bool = if (@hasDecl(root, "nes_flat_bus")) root.nes_flat_bus else false;

/// One entry of the per-cycle bus log the sweep compares against the data
/// set's `cycles` array. `write` distinguishes its `"read"`/`"write"` tag.
pub const FlatOp = struct { addr: u16, value: u8, write: bool };

/// The log itself, filled by `Bus.read`/`Bus.write` under `flat_bus`.
///
/// Fixed capacity, no allocator: the longest thing a single `Cpu.step` can
/// emit is a 7-cycle instruction or interrupt sequence. The headroom is for
/// the JAM opcodes, whose data-set entries run 11 cycles (see
/// `cpu_sweep.zig` on why they are skipped by default). `overflowed` makes a
/// miscount loud rather than silently truncating into a passing comparison.
pub const FlatLog = struct {
    ops: [32]FlatOp = undefined,
    len: usize = 0,
    overflowed: bool = false,

    pub fn reset(self: *FlatLog) void {
        self.len = 0;
        self.overflowed = false;
    }

    pub fn record(self: *FlatLog, addr: u16, value: u8, write: bool) void {
        if (self.len == self.ops.len) {
            self.overflowed = true;
            return;
        }
        self.ops[self.len] = .{ .addr = addr, .value = value, .write = write };
        self.len += 1;
    }

    pub fn slice(self: *const FlatLog) []const FlatOp {
        return self.ops[0..self.len];
    }
};
