//! nestest correctness gate for the CPU core.
//!
//! nestest (Kevin Horton, 2004) documents two pass/fail protocols. Only the
//! first is a real gate here; the second is reduced to a tripwire, for the
//! measured reason spelled out below.
//!
//!  1. **Log diff — the gate.** Started in "automation" mode — PC forced to `$C000`, which
//!     the ROM's author added specifically so the suite runs without a PPU or
//!     controllers — nestest executes 8991 instructions in a fixed sequence.
//!     `nestest.log` is a known-good Nintendulator trace of exactly that run.
//!     We compare our own pre-instruction state against it field by field, so
//!     a divergence is reported at the *first* instruction that differs, with
//!     the offending field named. That catches wrong flags, wrong cycle counts
//!     and wrong dummy-read behavior at the moment they happen, rather than
//!     thousands of instructions later when control flow finally diverges.
//!
//!  2. **Result codes — a tripwire, not a second gate.** nestest also reports
//!     verdicts in zero page: `$02` holds the last failing test's code for the
//!     documented opcodes and `$03` the same for the undocumented ones
//!     (`nestest.txt` lists every code). That protocol is real on hardware,
//!     but this harness cannot reach it, and treating it as an independent
//!     check would be self-deception. Two things were measured:
//!
//!       * On a *correct* CPU, `$02` and `$03` are never written at all —
//!         not during the 8991 logged instructions, and not afterwards. The
//!         log stops at `C66E RTS`, before nestest's epilogue, and with no PPU
//!         (M2) the ROM then runs off into open bus and JAMs ~95 instructions
//!         later at `$0068`. `Bus.wram` is zero-initialized, so an
//!         `expect($02 == $00)` on those bytes is an assertion that *cannot
//!         fail*, no matter what the CPU did.
//!
//!       * `$00` is not even a reliable pass value. With a deliberate BIT
//!         V-flag bug injected, control flow diverged, the ROM *did* reach a
//!         store path within the logged run, and wrote `$02 = $00` — the
//!         "tests completed successfully" code — on a demonstrably broken CPU.
//!
//!     So what is asserted below is the only honest thing available: a
//!     poisoned sentinel in those two bytes must *survive* the run. That is a
//!     genuine (if weak) tripwire — it fires if a future change lets the ROM
//!     reach its store path — and nothing more. Protocol (1) is the gate.
//!
//! The log's `PPU:` column is deliberately not compared: with no PPU yet
//! (M2), those numbers are a pure function of the CPU cycle count
//! (`dot = cycles * 3`), so checking them would only restate the `CYC:` check.

const std = @import("std");
const testing = std.testing;

const rom_mod = @import("rom.zig");
const bus_mod = @import("bus.zig");
const cpu_mod = @import("cpu.zig");

/// Vendored fixtures, wired in as anonymous imports by `build.zig` so they are
/// only ever pulled into the native test binary.
const nestest_rom = @embedFile("nestest_rom");
const nestest_log = @embedFile("nestest_log");

/// nestest.txt: "set your program counter to 0c000h" to run every test in
/// sequence without any PPU/controller dependency.
const automation_entry: u16 = 0xC000;

/// One parsed line of `nestest.log`, i.e. the architectural state *before* the
/// listed instruction executes.
const Expected = struct {
    pc: u16,
    bytes: [3]u8,
    length: usize,
    a: u8,
    x: u8,
    y: u8,
    p: u8,
    s: u8,
    cycles: u64,
};

const ParseError = error{ BadHexDigit, ShortLine, MissingField };

fn hexDigit(c: u8) ParseError!u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'A'...'F' => c - 'A' + 10,
        'a'...'f' => c - 'a' + 10,
        else => ParseError.BadHexDigit,
    };
}

fn parseHex(text: []const u8) ParseError!u32 {
    var value: u32 = 0;
    for (text) |c| value = (value << 4) | try hexDigit(c);
    return value;
}

/// Read a two-hex-digit field introduced by `marker` (e.g. `" A:"`). Every
/// marker carries its leading space so it cannot collide with the disassembly
/// column or with a longer marker (`" P:"` vs `"SP:"`).
fn hexField(line: []const u8, marker: []const u8) ParseError!u8 {
    const at = std.mem.indexOf(u8, line, marker) orelse return ParseError.MissingField;
    const start = at + marker.len;
    if (start + 2 > line.len) return ParseError.ShortLine;
    return @intCast(try parseHex(line[start .. start + 2]));
}

/// Nintendulator's trace format has a fixed prefix:
///
///     C5F7  86 00     STX $00 = 00   ...   A:00 X:00 ... CYC:12
///     ^0    ^6 ^9 ^12 ^16
///
/// so PC and the 1-3 opcode bytes come from fixed columns, while the register
/// block is located by marker search (its column shifts with the disassembly).
fn parseLine(line: []const u8) !Expected {
    if (line.len < 16) return ParseError.ShortLine;

    var e: Expected = undefined;
    e.pc = @intCast(try parseHex(line[0..4]));
    e.bytes = .{ 0, 0, 0 };
    e.bytes[0] = @intCast(try parseHex(line[6..8]));
    e.length = 1;
    if (line[9] != ' ') {
        e.bytes[1] = @intCast(try parseHex(line[9..11]));
        e.length = 2;
    }
    if (line[12] != ' ') {
        e.bytes[2] = @intCast(try parseHex(line[12..14]));
        e.length = 3;
    }

    e.a = try hexField(line, " A:");
    e.x = try hexField(line, " X:");
    e.y = try hexField(line, " Y:");
    e.p = try hexField(line, " P:");
    e.s = try hexField(line, " SP:");

    const cyc_at = std.mem.indexOf(u8, line, "CYC:") orelse return ParseError.MissingField;
    e.cycles = try std.fmt.parseInt(u64, line[cyc_at + 4 ..], 10);
    return e;
}

fn reportMismatch(instruction: usize, expected: Expected, actual: cpu_mod.Cpu.Trace) void {
    const entry = cpu_mod.opcodes[actual.opcode];
    std.debug.print(
        \\
        \\nestest divergence at instruction #{d} (nestest.log line {d})
        \\  instruction: {s} ({s}), opcode ${X:0>2}
        \\                 PC    A  X  Y  P SP        CYC
        \\  expected:    {X:0>4}   {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {d:>10}
        \\  actual:      {X:0>4}   {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {d:>10}
        \\
    , .{
        instruction,
        instruction + 1,
        entry.mnemonic,
        @tagName(entry.mode),
        actual.opcode,
        expected.pc,
        expected.a,
        expected.x,
        expected.y,
        expected.p,
        expected.s,
        expected.cycles,
        actual.pc,
        actual.a,
        actual.x,
        actual.y,
        actual.p,
        actual.s,
        actual.cycles,
    });

    var differing: [8][]const u8 = undefined;
    var n: usize = 0;
    if (expected.pc != actual.pc) {
        differing[n] = "PC";
        n += 1;
    }
    if (expected.a != actual.a) {
        differing[n] = "A";
        n += 1;
    }
    if (expected.x != actual.x) {
        differing[n] = "X";
        n += 1;
    }
    if (expected.y != actual.y) {
        differing[n] = "Y";
        n += 1;
    }
    if (expected.p != actual.p) {
        differing[n] = "P";
        n += 1;
    }
    if (expected.s != actual.s) {
        differing[n] = "SP";
        n += 1;
    }
    if (expected.cycles != actual.cycles) {
        differing[n] = "CYC";
        n += 1;
    }
    std.debug.print("  first differing field(s):", .{});
    for (differing[0..n]) |name| std.debug.print(" {s}", .{name});
    std.debug.print("\n", .{});

    if (expected.p != actual.p) {
        std.debug.print("  P bits (NV-BDIZC): expected {b:0>8}, actual {b:0>8}\n", .{ expected.p, actual.p });
    }
}

test "nestest automation run matches nestest.log instruction for instruction" {
    const rom = try rom_mod.Rom.load(nestest_rom);
    var bus = bus_mod.Bus.init(try rom_mod.createMapper(rom), rom.header.mirroring);
    var cpu = cpu_mod.Cpu.init(&bus);

    // A real RESET first (7 cycles, S = $FD, I set), then jump to the
    // automation entry point. This is what produces the log's opening
    // `A:00 X:00 Y:00 P:24 SP:FD CYC:7`.
    cpu.reset();
    cpu.pc = automation_entry;

    // Poison the two result-code bytes. See the file docstring: a correct run
    // never reaches nestest's store path, so these must still hold their
    // sentinels at the end. Any other value means control flow diverged.
    const sentinel_02: u8 = 0xA5;
    const sentinel_03: u8 = 0x5A;
    bus.wram[0x02] = sentinel_02;
    bus.wram[0x03] = sentinel_03;

    var lines = std.mem.splitScalar(u8, nestest_log, '\n');
    var instruction: usize = 0;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r \t");
        if (line.len == 0) continue;

        const expected = try parseLine(line);
        const actual = cpu.trace();

        const state_ok = expected.pc == actual.pc and
            expected.a == actual.a and
            expected.x == actual.x and
            expected.y == actual.y and
            expected.p == actual.p and
            expected.s == actual.s and
            expected.cycles == actual.cycles;

        var bytes_ok = expected.length == actual.length;
        if (bytes_ok) {
            for (0..expected.length) |i| {
                const got = switch (i) {
                    0 => actual.opcode,
                    1 => actual.operands[0],
                    else => actual.operands[1],
                };
                if (expected.bytes[i] != got) bytes_ok = false;
            }
        }

        if (!state_ok or !bytes_ok) {
            reportMismatch(instruction, expected, actual);
            if (!bytes_ok) {
                std.debug.print(
                    "  opcode bytes: expected {d} byte(s), decoded {d}\n",
                    .{ expected.length, actual.length },
                );
            }
            std.debug.print("  {d} instruction(s) matched before this one\n", .{instruction});
            return error.NestestDivergence;
        }

        cpu.step();
        instruction += 1;
    }

    // nestest.log is exactly 8991 lines; a different count means the log or
    // the parser changed, not the CPU.
    try testing.expectEqual(@as(usize, 8991), instruction);

    // Protocol 2, as a tripwire only (see the file docstring). Note the sense:
    // we require the sentinels to be *untouched*. `$00` here would be a
    // failure, not a pass — nestest writing anything at all means the run took
    // a path a correct CPU does not take.
    if (bus.wram[0x02] != sentinel_02 or bus.wram[0x03] != sentinel_03) {
        std.debug.print(
            \\
            \\nestest stored a zero-page result code during the logged run.
            \\  $02 = ${X:0>2} (sentinel ${X:0>2}), $03 = ${X:0>2} (sentinel ${X:0>2})
            \\A correct CPU never reaches nestest's store path inside these 8991
            \\instructions, so control flow diverged. nestest.txt lists what each
            \\code means -- but the log diff above is the authoritative signal,
            \\and `$00` here is NOT a pass.
            \\
        , .{ bus.wram[0x02], sentinel_02, bus.wram[0x03], sentinel_03 });
    }
    try testing.expectEqual(sentinel_02, bus.wram[0x02]);
    try testing.expectEqual(sentinel_03, bus.wram[0x03]);
}

test "the log parser reads a known line correctly" {
    const line = "C5F7  86 00     STX $00 = 00                    A:01 X:02 Y:03 P:26 SP:FD PPU:  0, 36 CYC:12";
    const e = try parseLine(line);
    try testing.expectEqual(@as(u16, 0xC5F7), e.pc);
    try testing.expectEqual(@as(usize, 2), e.length);
    try testing.expectEqual(@as(u8, 0x86), e.bytes[0]);
    try testing.expectEqual(@as(u8, 0x00), e.bytes[1]);
    try testing.expectEqual(@as(u8, 0x01), e.a);
    try testing.expectEqual(@as(u8, 0x02), e.x);
    try testing.expectEqual(@as(u8, 0x03), e.y);
    try testing.expectEqual(@as(u8, 0x26), e.p);
    try testing.expectEqual(@as(u8, 0xFD), e.s);
    try testing.expectEqual(@as(u64, 12), e.cycles);
}

test "the log parser handles one- and three-byte instructions" {
    const one = "C72D  EA        NOP                             A:00 X:00 Y:00 P:26 SP:FB PPU:  0, 81 CYC:27";
    const e1 = try parseLine(one);
    try testing.expectEqual(@as(usize, 1), e1.length);
    try testing.expectEqual(@as(u8, 0xEA), e1.bytes[0]);

    const three = "C000  4C F5 C5  JMP $C5F5                       A:00 X:00 Y:00 P:24 SP:FD PPU:  0, 21 CYC:7";
    const e3 = try parseLine(three);
    try testing.expectEqual(@as(usize, 3), e3.length);
    try testing.expectEqual(@as(u8, 0x4C), e3.bytes[0]);
    try testing.expectEqual(@as(u8, 0xF5), e3.bytes[1]);
    try testing.expectEqual(@as(u8, 0xC5), e3.bytes[2]);
    try testing.expectEqual(@as(u64, 7), e3.cycles);
}
