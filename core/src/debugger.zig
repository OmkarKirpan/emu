//! A native, interactive CLI debugger -- ENG-67 (M2b): author-facing
//! introspection tooling. Not a wasm-exported API and not reachable from
//! `zig build wasm`: this file is its own executable root (`zig build
//! debug`), entirely separate from `wasm.zig`'s delivery ABI, per that
//! file's own doc comment on the wasm/native split and ENG-67's acceptance
//! criteria ("does not touch or extend the wasm export ABI -- that surface
//! is M4's job").
//!
//! Loads a ROM from disk, single-steps or runs to breakpoints, and prints
//! CPU/PPU state through the same peek-based, side-effect-free entry points
//! `Cpu.trace`/`Bus.peek`/`Ppu.peekRegister` that `root.zig`'s doc comment
//! already names as existing for exactly this purpose -- this file is their
//! first caller.

const std = @import("std");
// Submodules directly, not `root.zig` -- same convention every other native
// test/harness file here follows (`nestest_test.zig`, `determinism.zig`,
// `mapperel_harness.zig`). Matters more than style here: `root.zig`'s own
// `test {}` block pulls in every vendored-ROM test file via anonymous
// imports declared only on `build.zig`'s `test_mod`, and `zig build test`
// discovers `test {}` blocks transitively through whatever a module
// imports -- routing through `root.zig` would make this file's own
// `addTest` (which carries none of those anonymous imports) fail to
// compile them.
const Machine = @import("machine.zig").Machine;
const cpu_mod = @import("cpu.zig");

/// Returns an exit code rather than an error union: a bad ROM path is a
/// user's typo, and returning the error would make Zig print its own
/// `error: FileNotFound` plus a stack trace *underneath* the readable
/// message already printed here -- twice the output, none of the extra half
/// useful to someone who just misspelled a filename.
pub fn main(init: std.process.Init) u8 {
    const gpa = init.gpa;
    const argv = init.minimal.args.toSlice(init.arena.allocator()) catch |err| {
        std.debug.print("could not read command line: {t}\n", .{err});
        return 1;
    };
    if (argv.len < 2) {
        std.debug.print("usage: {s} <rom.nes>\n", .{if (argv.len > 0) argv[0] else "nes-debugger"});
        return 2;
    }
    const rom_path = argv[1];

    // 16MB comfortably covers every NES cartridge this core supports (M7d's
    // largest vendored fixture is 512KB PRG + 256KB CHR); a real oversized
    // file still fails cleanly via `Machine.init`'s own header/geometry
    // checks rather than silently truncating.
    const rom_bytes = std.Io.Dir.cwd().readFileAlloc(init.io, rom_path, gpa, .limited(16 * 1024 * 1024)) catch |err| {
        std.debug.print("could not read '{s}': {t}\n", .{ rom_path, err });
        return 1;
    };
    defer gpa.free(rom_bytes);

    var machine: Machine = undefined;
    machine.init(rom_bytes) catch |err| {
        std.debug.print("could not load '{s}' as an iNES ROM: {t}\n", .{ rom_path, err });
        return 1;
    };

    var dbg = Debugger{ .machine = &machine };
    dbg.run(init.io) catch |err| {
        std.debug.print("input error: {t}\n", .{err});
        return 1;
    };
    return 0;
}

/// Bounded rather than growable: a handful of breakpoints is the realistic
/// ceiling for one debugging session, and a fixed array keeps `Debugger`
/// allocator-free -- there's nothing here an author would need to persist or
/// grow without limit.
const max_breakpoints = 32;

/// Sprites in OAM. `Ppu.oam` is 256 bytes = 64 sprites x 4 bytes.
const sprite_count = 64;

/// Console-side nametable VRAM: 2KB (`Ppu.vram`).
const vram_size = 0x0800;

const Debugger = struct {
    machine: *Machine,
    breakpoints: [max_breakpoints]?u16 = @splat(null),

    fn cpu(self: *Debugger) *cpu_mod.Cpu {
        return &self.machine.cpu;
    }

    fn addBreakpoint(self: *Debugger, addr: u16) void {
        for (self.breakpoints) |slot| {
            if (slot == addr) {
                std.debug.print("breakpoint already set at ${X:0>4}\n", .{addr});
                return;
            }
        }
        for (&self.breakpoints) |*slot| {
            if (slot.* == null) {
                slot.* = addr;
                std.debug.print("breakpoint set at ${X:0>4}\n", .{addr});
                return;
            }
        }
        std.debug.print("breakpoint table full ({d} max); remove one first\n", .{max_breakpoints});
    }

    fn removeBreakpoint(self: *Debugger, addr: u16) void {
        var removed = false;
        for (&self.breakpoints) |*slot| {
            if (slot.* == addr) {
                slot.* = null;
                removed = true;
            }
        }
        // Silence here read as success, which is the wrong thing to believe
        // about a breakpoint you think you just cleared.
        if (removed) {
            std.debug.print("breakpoint cleared at ${X:0>4}\n", .{addr});
        } else {
            std.debug.print("no breakpoint at ${X:0>4}\n", .{addr});
        }
    }

    fn hasBreakpoint(self: *const Debugger, addr: u16) bool {
        for (self.breakpoints) |slot| {
            if (slot == addr) return true;
        }
        return false;
    }

    fn hasAnyBreakpoint(self: *const Debugger) bool {
        for (self.breakpoints) |slot| {
            if (slot != null) return true;
        }
        return false;
    }

    fn listBreakpoints(self: *const Debugger) void {
        var any = false;
        for (self.breakpoints) |slot| {
            if (slot) |addr| {
                std.debug.print("  ${X:0>4}\n", .{addr});
                any = true;
            }
        }
        if (!any) std.debug.print("  (none)\n", .{});
    }

    /// Single-step exactly one instruction and print the state it landed on
    /// -- the "at a breakpoint or single-step" half of ENG-67's acceptance
    /// criteria.
    fn stepOnce(self: *Debugger) void {
        self.cpu().step();
        self.printTraceLine();
    }

    /// Run until a set breakpoint's PC is reached. Always steps at least once
    /// first, so `continue` from a PC that is itself a breakpoint makes
    /// forward progress instead of reporting immediately.
    ///
    /// Deliberately unbounded otherwise (Ctrl-C is the way out), the same as
    /// any other debugger's `continue` -- a breakpoint on an address the ROM
    /// never reaches is a question about the ROM, not an error here. The one
    /// exception is a JAM: one of the twelve opcodes that halt the core with
    /// PC frozen (see `Cpu.jammed`), after which no breakpoint can ever be
    /// reached, so spinning would be a hang with nothing to report.
    fn continueRun(self: *Debugger) void {
        if (!self.hasAnyBreakpoint()) {
            std.debug.print("no breakpoints set -- use 'b <addr>' first, or 's' to single-step\n", .{});
            return;
        }
        self.cpu().step();
        while (!self.hasBreakpoint(self.cpu().pc)) {
            if (self.cpu().jammed) {
                std.debug.print("CPU jammed at ${X:0>4} -- only a reset recovers; breakpoint unreachable\n", .{self.cpu().pc});
                self.printTraceLine();
                return;
            }
            self.cpu().step();
        }
        std.debug.print("hit breakpoint ${X:0>4}\n", .{self.cpu().pc});
        self.printTraceLine();
    }

    fn printTraceLine(self: *Debugger) void {
        const t = self.cpu().trace();
        const mnemonic = cpu_mod.opcodes[t.opcode].mnemonic;
        std.debug.print(
            "${X:0>4}  {X:0>2} {s}   A:{X:0>2} X:{X:0>2} Y:{X:0>2} P:{X:0>2} SP:{X:0>2}  PPU:{d:>3},{d:>3}  CYC:{d}\n",
            .{
                t.pc,                          t.opcode,                 mnemonic, t.a, t.x, t.y, t.p, t.s,
                self.machine.bus.ppu.scanline, self.machine.bus.ppu.dot, t.cycles,
            },
        );
    }

    /// CPU registers and processor-status flags, decoded bit-by-bit --
    /// acceptance criteria's "CPU registers/flags".
    fn printRegs(self: *Debugger) void {
        const c = self.cpu();
        std.debug.print(
            "PC:${X:0>4}  A:${X:0>2} X:${X:0>2} Y:${X:0>2} SP:${X:0>2}  P:${X:0>2} [{b:0>8}]\n",
            .{ c.pc, c.a, c.x, c.y, c.s, c.p.toByte(), c.p.toByte() },
        );
        std.debug.print(
            "  flags: N={d} V={d} B={d} D={d} I={d} Z={d} C={d}\n",
            .{
                @intFromBool(c.p.n), @intFromBool(c.p.v), @intFromBool(c.p.b), @intFromBool(c.p.d),
                @intFromBool(c.p.i), @intFromBool(c.p.z), @intFromBool(c.p.c),
            },
        );
        std.debug.print("  cycles: {d}\n", .{c.cycles});
    }

    /// PPU register file plus the internal scroll/scanline/dot state that
    /// the wasm ABI never exposes -- acceptance criteria's "PPU register ...
    /// state".
    fn printPpuRegs(self: *Debugger) void {
        const p = &self.machine.bus.ppu;
        std.debug.print(
            "CTRL:${X:0>2} MASK:${X:0>2} STATUS:${X:0>2} OAMADDR:${X:0>2}\n",
            .{ @as(u8, @bitCast(p.ctrl)), @as(u8, @bitCast(p.mask)), p.status.toByte(), p.oam_addr },
        );
        std.debug.print(
            "  v:${X:0>4} t:${X:0>4} fine_x:{d} w:{}\n",
            .{ p.v, p.t, p.fine_x, p.w },
        );
        std.debug.print(
            "  scanline:{d} dot:{d} frame:{d}\n",
            .{ p.scanline, p.dot, p.frame },
        );
    }

    /// CPU-address-space memory viewer, through `Bus.peek` -- never
    /// perturbs PPU/controller state the way a live read would.
    ///
    /// A range running past $FFFF **wraps to $0000** rather than stopping or
    /// erroring, because that is what the address it is showing you actually
    /// means: the 6502 has a 16-bit address bus and no address above $FFFF
    /// exists. `m ff00 200` is the ordinary way to look at the interrupt
    /// vectors ($FFFA-$FFFF), so this range is the common case, not an edge
    /// one -- an earlier version of this function computed the end address in
    /// `u32` and panicked (`integer does not fit in destination type`)
    /// casting back down.
    fn printMem(self: *Debugger, start: u16, len: u16) void {
        var addr: u16 = start;
        var remaining: u32 = len;
        while (remaining > 0) {
            const row = @min(remaining, 16);
            std.debug.print("${X:0>4}: ", .{addr});
            for (0..row) |_| {
                std.debug.print("{X:0>2} ", .{self.machine.bus.peek(addr)});
                addr +%= 1;
            }
            std.debug.print("\n", .{});
            remaining -= row;
        }
    }

    /// Raw nametable VRAM viewer -- acceptance criteria's "VRAM ... state".
    /// This is `Ppu.vram`'s own 2KB storage (unmirrored, unlike CPU-space
    /// $2000-$3EFF reads through `Bus.peek`), so it shows exactly what the
    /// PPU physically holds regardless of the cartridge's mirroring mode.
    fn printVram(self: *Debugger, start: u16, len: u16) void {
        const vram = &self.machine.bus.ppu.vram;
        // Out of range says so rather than printing nothing: a silent empty
        // response to `vram 800` is indistinguishable from "this region is
        // all zeroes", which is a real and different answer.
        if (start >= vram.len) {
            std.debug.print("VRAM offset out of range: ${X:0>4} (2KB, $0000-${X:0>4})\n", .{ start, vram.len - 1 });
            return;
        }
        const end = @min(@as(u32, start) + len, vram.len);
        var addr: u32 = start;
        while (addr < end) {
            std.debug.print("${X:0>4}: ", .{addr});
            const row_end = @min(addr + 16, end);
            var col = addr;
            while (col < row_end) : (col += 1) {
                std.debug.print("{X:0>2} ", .{vram[col]});
            }
            std.debug.print("\n", .{});
            addr = row_end;
        }
    }

    /// OAM (sprite RAM) viewer -- acceptance criteria's "OAM ... state".
    /// With no index, tabulates all 64 sprites decoded into Y/tile/attr/X;
    /// with one, dumps that single sprite's 4 raw bytes plus its decode.
    fn printOam(self: *Debugger, index: ?u16) void {
        const oam = &self.machine.bus.ppu.oam;
        if (index) |i| {
            // OAM holds exactly 64 sprites. Unchecked, an index past that ran
            // off the end of the 256-byte array and panicked outright.
            if (i >= sprite_count) {
                std.debug.print("sprite index out of range: {d} (OAM holds {d}, 0-{d})\n", .{ i, sprite_count, sprite_count - 1 });
                return;
            }
            const base = i * 4;
            std.debug.print(
                "sprite {d}: Y:{d} tile:${X:0>2} attr:${X:0>2} X:{d}\n",
                .{ i, oam[base], oam[base + 1], oam[base + 2], oam[base + 3] },
            );
            return;
        }
        std.debug.print(" # Y   tile attr X\n", .{});
        var i: u16 = 0;
        while (i < sprite_count) : (i += 1) {
            const base = i * 4;
            std.debug.print(
                "{d:>2} {d:>3} ${X:0>2}  ${X:0>2}  {d:>3}\n",
                .{ i, oam[base], oam[base + 1], oam[base + 2], oam[base + 3] },
            );
        }
    }

    /// Palette RAM -- background (row 1) and sprite (row 2) palettes, 16
    /// entries each, per https://www.nesdev.org/wiki/PPU_palettes.
    fn printPalette(self: *Debugger) void {
        const pal = &self.machine.bus.ppu.palette;
        std.debug.print("  bg: ", .{});
        for (pal[0..16]) |v| std.debug.print("{X:0>2} ", .{v});
        std.debug.print("\n  sp: ", .{});
        for (pal[16..32]) |v| std.debug.print("{X:0>2} ", .{v});
        std.debug.print("\n", .{});
    }

    fn printHelp() void {
        std.debug.print(
            \\commands:
            \\  s [n]        single-step n instructions (default 1)
            \\  c            run until a breakpoint is hit
            \\  b <addr>     set a breakpoint at addr (e.g. b c000)
            \\  d <addr>     delete the breakpoint at addr
            \\  bl           list breakpoints
            \\  r            print CPU registers/flags
            \\  pr           print PPU registers + scroll/scanline/dot state
            \\  m <addr> [len]     dump CPU-space memory (default len 64)
            \\  vram [off] [len]   dump raw nametable VRAM (default whole 2KB)
            \\  oam [index]        dump OAM, all 64 sprites or just one
            \\  pal          dump palette RAM
            \\  h            this help
            \\  q            quit
            \\
            \\addresses are hex, counts are decimal; prefix either with
            \\'$' or '0x' to force hex ($40 = 64).
            \\
        , .{});
    }

    fn run(self: *Debugger, io: std.Io) !void {
        std.debug.print("nes-debugger -- ENG-67. 'h' for help, 'q' to quit.\n", .{});
        self.printRegs();

        var stdin_buf: [4096]u8 = undefined;
        var stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buf);
        while (true) {
            std.debug.print("(nesdbg) ", .{});
            const raw_line = stdin_reader.interface.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    std.debug.print("command too long\n", .{});
                    continue;
                },
                error.ReadFailed => return err,
            } orelse break; // EOF (Ctrl-D / piped input exhausted)
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;

            var it = std.mem.tokenizeScalar(u8, line, ' ');
            const command = it.next() orelse continue;

            if (std.mem.eql(u8, command, "q") or std.mem.eql(u8, command, "quit")) {
                break;
            } else if (std.mem.eql(u8, command, "h") or std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "?")) {
                printHelp();
            } else if (std.mem.eql(u8, command, "s") or std.mem.eql(u8, command, "step")) {
                const n = countOr(u32, &it, 1) orelse continue;
                var i: u32 = 0;
                while (i < n) : (i += 1) self.stepOnce();
            } else if (std.mem.eql(u8, command, "c") or std.mem.eql(u8, command, "continue")) {
                self.continueRun();
            } else if (std.mem.eql(u8, command, "b") or std.mem.eql(u8, command, "break")) {
                self.addBreakpoint(requiredAddr(&it) orelse continue);
            } else if (std.mem.eql(u8, command, "d") or std.mem.eql(u8, command, "delete")) {
                self.removeBreakpoint(requiredAddr(&it) orelse continue);
            } else if (std.mem.eql(u8, command, "bl")) {
                self.listBreakpoints();
            } else if (std.mem.eql(u8, command, "r") or std.mem.eql(u8, command, "regs")) {
                self.printRegs();
            } else if (std.mem.eql(u8, command, "pr") or std.mem.eql(u8, command, "ppuregs")) {
                self.printPpuRegs();
            } else if (std.mem.eql(u8, command, "m") or std.mem.eql(u8, command, "mem")) {
                const addr = requiredAddr(&it) orelse continue;
                const len = countOr(u16, &it, 64) orelse continue;
                self.printMem(addr, len);
            } else if (std.mem.eql(u8, command, "vram")) {
                // Both optional here: bare `vram` dumps the whole 2KB.
                const addr = (optionalArg(u16, &it, hex_radix) catch {
                    std.debug.print("not a valid VRAM offset -- hex, e.g. '400'\n", .{});
                    continue;
                }) orelse 0;
                const len = countOr(u16, &it, vram_size) orelse continue;
                self.printVram(addr, len);
            } else if (std.mem.eql(u8, command, "oam")) {
                const index = optionalArg(u16, &it, dec_radix) catch {
                    std.debug.print("not a valid sprite index -- decimal 0-{d}\n", .{sprite_count - 1});
                    continue;
                };
                self.printOam(index);
            } else if (std.mem.eql(u8, command, "pal") or std.mem.eql(u8, command, "palette")) {
                self.printPalette();
            } else {
                std.debug.print("unknown command '{s}' -- 'h' for help\n", .{command});
            }
        }
    }
};

const TokenIt = std.mem.TokenIterator(u8, .scalar);

/// **Addresses are hex, counts are decimal.** Both are what a 6502 debugger's
/// user expects (`b c000` addresses a location; `s 10` means ten steps, the
/// way `gdb`'s own count arguments read), and getting this backwards is not a
/// cosmetic problem: every argument here used to parse as hex, so `s 10`
/// silently ran *sixteen* instructions. An explicit `$`/`0x` prefix forces
/// hex either way, so a count can still be written `$40` when that reads
/// better.
const hex_radix = 16;
const dec_radix = 10;

/// Strips an optional `$`/`0x` prefix, reporting the radix it implies. Both
/// spellings show up across NES tooling.
fn splitRadix(token: []const u8, default_radix: u8) struct { []const u8, u8 } {
    if (std.mem.startsWith(u8, token, "$")) return .{ token[1..], hex_radix };
    if (std.mem.startsWith(u8, token, "0x") or std.mem.startsWith(u8, token, "0X")) {
        return .{ token[2..], hex_radix };
    }
    return .{ token, default_radix };
}

/// Absent -> `null`, so the caller's default applies. Present but
/// unparseable -> `error.BadArg`.
///
/// That error case is the point of this function existing rather than a
/// `catch null`: a typo used to be indistinguishable from an omitted
/// argument, so `s xyz` stepped once and `oam zz` dumped all 64 sprites,
/// neither saying anything was wrong.
fn optionalArg(comptime T: type, it: *TokenIt, default_radix: u8) error{BadArg}!?T {
    const token = it.next() orelse return null;
    const stripped, const radix = splitRadix(token, default_radix);
    if (stripped.len == 0) return error.BadArg;
    return std.fmt.parseInt(T, stripped, radix) catch error.BadArg;
}

/// An address argument the command cannot run without. Returns null once it
/// has reported why (absent, or unparseable), so callers just skip the
/// command.
fn requiredAddr(it: *TokenIt) ?u16 {
    const parsed = optionalArg(u16, it, hex_radix) catch {
        std.debug.print("not a valid address -- hex, e.g. 'c000' or '$C000'\n", .{});
        return null;
    };
    return parsed orelse {
        std.debug.print("this command needs an address, e.g. 'b c000'\n", .{});
        return null;
    };
}

/// An optional count/length. Returns null once it has reported a bad value;
/// an *absent* value yields `default`, which is not an error.
fn countOr(comptime T: type, it: *TokenIt, default: T) ?T {
    const parsed = optionalArg(T, it, dec_radix) catch {
        std.debug.print("not a valid count -- decimal, or '$'/'0x' prefixed for hex\n", .{});
        return null;
    };
    return parsed orelse default;
}

// ============================== tests ==============================

const testing = std.testing;

/// A minimal 32KB-PRG NROM iNES image whose reset vector points at an
/// infinite `JMP $C000` loop -- $C000 is both where the CPU always starts
/// (matching `cpu.zig`'s own `TestHarness` convention: code at $C000, exactly
/// like nestest's automation entry) and the one PC value it can ever be at,
/// which is what makes it a deterministic target for `continueRun` tests
/// below: a breakpoint on $C000 is guaranteed to be hit on the very next
/// step, never "run forever" the way an arbitrary guessed address could.
/// **Static storage, deliberately.** `Nrom` borrows its PRG-ROM rather than
/// copying it (`mapper.zig`: "the caller must keep the original ROM buffer
/// alive for as long as this `Mapper` is in use"), so a `Machine` outlives
/// the buffer it was booted from only if that buffer outlives it too. This
/// used to be a local inside the helper below, which returned -- leaving
/// every mapper read pointed at a dead stack frame. The tests passed anyway,
/// which is exactly what makes that shape worth naming: nothing had
/// overwritten the frame yet.
const test_rom: [16 + 0x8000]u8 = buildTestRom();

fn buildTestRom() [16 + 0x8000]u8 {
    var bytes: [16 + 0x8000]u8 = [_]u8{0} ** (16 + 0x8000);
    bytes[0] = 'N';
    bytes[1] = 'E';
    bytes[2] = 'S';
    bytes[3] = 0x1A;
    bytes[4] = 2; // 32KB PRG
    bytes[5] = 0; // CHR-RAM
    // flags6/flags7 left at 0: mapper 0 (NROM), horizontal mirroring.
    const prg = bytes[16..];
    prg[0x4000] = 0x4C; // JMP
    prg[0x4001] = 0x00;
    prg[0x4002] = 0xC0; // -> $C000
    prg[0x7FFC] = 0x00; // reset vector low
    prg[0x7FFD] = 0xC0; // reset vector high ($C000)
    return bytes;
}

fn testDebugger(m: *Machine) !Debugger {
    try m.init(&test_rom);
    return Debugger{ .machine = m };
}

test "stepOnce executes exactly one instruction" {
    var m: Machine = undefined;
    var dbg = try testDebugger(&m);
    const cycles_before = dbg.cpu().cycles;
    try testing.expectEqual(@as(u16, 0xC000), dbg.cpu().pc);
    dbg.stepOnce();
    // JMP $C000 always lands back on itself -- PC is unchanged, but a real
    // instruction (3 cycles) ran.
    try testing.expectEqual(@as(u16, 0xC000), dbg.cpu().pc);
    try testing.expectEqual(cycles_before + 3, dbg.cpu().cycles);
}

test "breakpoints: add is idempotent, remove clears, list reflects both" {
    var m: Machine = undefined;
    var dbg = try testDebugger(&m);

    try testing.expect(!dbg.hasAnyBreakpoint());
    dbg.addBreakpoint(0xC000);
    dbg.addBreakpoint(0xC000); // duplicate -- must not consume a second slot
    try testing.expect(dbg.hasBreakpoint(0xC000));

    var count: usize = 0;
    for (dbg.breakpoints) |slot| {
        if (slot != null) count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);

    dbg.removeBreakpoint(0xC000);
    try testing.expect(!dbg.hasAnyBreakpoint());
}

test "breakpoints: a full table reports rather than overflowing" {
    var m: Machine = undefined;
    var dbg = try testDebugger(&m);

    var addr: u16 = 0;
    while (addr < max_breakpoints) : (addr += 1) dbg.addBreakpoint(addr);
    dbg.addBreakpoint(max_breakpoints); // table full -- must be silently dropped, not overwrite slot 0

    var count: usize = 0;
    for (dbg.breakpoints) |slot| {
        if (slot != null) count += 1;
    }
    try testing.expectEqual(@as(usize, max_breakpoints), count);
    try testing.expect(!dbg.hasBreakpoint(max_breakpoints));
    try testing.expect(dbg.hasBreakpoint(0)); // slot 0 survived, unclobbered
}

test "continueRun stops exactly on a hit breakpoint" {
    var m: Machine = undefined;
    var dbg = try testDebugger(&m);
    dbg.addBreakpoint(0xC000);
    dbg.continueRun();
    try testing.expectEqual(@as(u16, 0xC000), dbg.cpu().pc);
}

test "continueRun with no breakpoints set is a no-op" {
    var m: Machine = undefined;
    var dbg = try testDebugger(&m);
    const cycles_before = dbg.cpu().cycles;
    dbg.continueRun();
    try testing.expectEqual(cycles_before, dbg.cpu().cycles);
}

// The two tests below assert absence of a panic, not printed output (these
// viewers write through `std.debug.print`). That is the exact property that
// was broken: both inputs are ordinary things to type, and both crashed the
// debugger outright.

test "printMem wraps at \\$FFFF instead of panicking on a range that runs past it" {
    var m: Machine = undefined;
    var dbg = try testDebugger(&m);
    // Two rows: $FFF0-$FFFF (the interrupt vectors, and the reason this range
    // is routine rather than exotic) then the wrap into $0000. Kept
    // deliberately small -- these viewers print, and a test dumping thousands
    // of rows into the build log floods the test runner's pipe.
    dbg.printMem(0xFFF0, 0x20);
    dbg.printMem(0xFFFF, 1); // single byte at the very top
    dbg.printMem(0, 0); // empty range prints nothing and terminates
}

test "printVram reports an out-of-range offset rather than printing nothing" {
    var m: Machine = undefined;
    var dbg = try testDebugger(&m);
    dbg.printVram(vram_size - 16, 16); // last row, in range
    dbg.printVram(vram_size, 16); // past the end -- used to print nothing at all
    dbg.printVram(0, 16);
    dbg.printVram(vram_size - 8, 0xFFFF); // length clamps to the end of VRAM
}

test "printOam rejects an out-of-range sprite index instead of reading past OAM" {
    var m: Machine = undefined;
    var dbg = try testDebugger(&m);
    dbg.printOam(63); // last valid sprite
    dbg.printOam(64); // first invalid one -- used to index byte 256 of a 256-byte array
    dbg.printOam(0xFFFF);
    // `printOam(null)` (the full 64-row table) is deliberately not exercised
    // here: it is the same indexing path, and 64 rows per test run is log
    // noise for no extra coverage.
}

fn tokens(s: []const u8) TokenIt {
    return std.mem.tokenizeScalar(u8, s, ' ');
}

test "splitRadix honours '$' and '0x'/'0X', and otherwise keeps the caller's radix" {
    {
        const text, const radix = splitRadix("$C000", dec_radix);
        try testing.expectEqualStrings("C000", text);
        try testing.expectEqual(@as(u8, hex_radix), radix);
    }
    {
        const text, const radix = splitRadix("0xc000", dec_radix);
        try testing.expectEqualStrings("c000", text);
        try testing.expectEqual(@as(u8, hex_radix), radix);
    }
    {
        const text, const radix = splitRadix("0XC000", dec_radix);
        try testing.expectEqualStrings("C000", text);
        try testing.expectEqual(@as(u8, hex_radix), radix);
    }
    {
        // Unprefixed: the caller's default decides, which is the whole point.
        const text, const radix = splitRadix("10", dec_radix);
        try testing.expectEqualStrings("10", text);
        try testing.expectEqual(@as(u8, dec_radix), radix);
    }
}

test "counts read as decimal, addresses as hex, and '$' overrides either" {
    // `s 10` means ten steps, not sixteen. This is the regression: every
    // argument used to parse as hex.
    var count = tokens("10");
    try testing.expectEqual(@as(?u32, 10), try optionalArg(u32, &count, dec_radix));

    var addr = tokens("10");
    try testing.expectEqual(@as(?u16, 0x10), try optionalArg(u16, &addr, hex_radix));

    var forced_hex = tokens("$10");
    try testing.expectEqual(@as(?u32, 0x10), try optionalArg(u32, &forced_hex, dec_radix));
}

test "an absent argument is null, but an unparseable one is an error rather than the default" {
    var absent = tokens("");
    try testing.expectEqual(@as(?u32, null), try optionalArg(u32, &absent, dec_radix));

    // The bug this pins: `s xyz` stepped once and `oam zz` dumped all 64
    // sprites, because a failed parse was indistinguishable from no argument.
    var garbage = tokens("xyz");
    try testing.expectError(error.BadArg, optionalArg(u32, &garbage, dec_radix));

    // Decimal-by-default means hex letters are a typo, not a silent value.
    var hex_letters_in_a_count = tokens("ff");
    try testing.expectError(error.BadArg, optionalArg(u32, &hex_letters_in_a_count, dec_radix));

    // Out of the type's range is a bad argument too, not a wrap.
    var too_big = tokens("70000");
    try testing.expectError(error.BadArg, optionalArg(u16, &too_big, dec_radix));

    // A bare prefix has no digits after it.
    var bare_prefix = tokens("$");
    try testing.expectError(error.BadArg, optionalArg(u16, &bare_prefix, hex_radix));
}
