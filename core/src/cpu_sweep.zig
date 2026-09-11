//! ENG-78: the opt-in per-cycle CPU sweep against
//! [SingleStepTests/65x02](https://github.com/SingleStepTests/65x02)'s
//! `nes6502/v1` data set -- 256 JSON files, one per opcode, 10,000 scenarios
//! each, 2.56 million in total. MIT licensed, and the `nes6502` variant is
//! the 2A03 specifically (BCD disabled), which is exactly this core's CPU.
//! Cite that repository, not its unlicensed parent `ProcessorTests`.
//!
//! Each scenario carries the full initial processor and memory state, the
//! full expected final state, and **a per-cycle list of bus operations** as
//! `[address, value, "read"|"write"]`. That last part is why this exists:
//! `nestest` establishes that instructions produce the right *results*, this
//! establishes that they produce the right *bus activity, cycle by cycle* --
//! dummy reads, the NMOS read-modify-write double write, and the
//! undocumented opcodes included. `Cpu.tick` is deliberately the single
//! chokepoint every bus cycle flows through; this asserts that property
//! across all 256 opcodes rather than the handful `nestest` reaches.
//!
//! **Never part of `zig build test`, never in CI.** The data set is 1.08GB
//! and is never vendored -- it is fetched into a gitignored cache directory
//! by `tools/fetch-65x02.sh`. This file is its own executable root (like
//! `debugger.zig`), which is also what makes the flat-bus switch work: see
//! `sweep_config.zig`.
//!
//!     zig build test-cpu-sweep                    # every opcode but the JAMs
//!     zig build test-cpu-sweep -- --opcodes 1e,a9 # two opcodes, ~10MB of data
//!     zig build test-cpu-sweep -- --limit 100     # 100 scenarios per opcode
//!
//! Exit code is 0 when every selected scenario passed, 1 on any mismatch,
//! 2 on a usage or data-availability problem.

/// Switches `Bus` to the flat 64KB RAM + bus log the data set assumes, and
/// `Cpu.tick` to not advancing a console that isn't there. Read at comptime
/// off this root file -- see `sweep_config.zig` for the whole mechanism and
/// why the production build gains no branch from it.
pub const nes_flat_bus = true;

const std = @import("std");
// Submodules directly rather than `root.zig`, for the reason `debugger.zig`
// spells out at length: `root.zig`'s `test {}` block reaches vendored-ROM
// fixtures that only `build.zig`'s test module carries.
const bus_mod = @import("bus.zig");
const cpu_mod = @import("cpu.zig");
const mapper_mod = @import("mapper.zig");

const Bus = bus_mod.Bus;
const Cpu = cpu_mod.Cpu;

const base_url = "https://raw.githubusercontent.com/SingleStepTests/65x02/main/nes6502/v1";
const default_data_dir = ".cache/65x02/nes6502/v1";

/// The twelve opcodes that lock up an NMOS 6502. The data set does cover
/// them, as an 11-cycle sequence in which the core fetches, reads both
/// interrupt vectors and then re-reads $FFFF/$FFFE forever. This core models
/// JAM as "burn one cycle per `step`, PC frozen" (see `Cpu.jammed`), which
/// is deliberately not that sequence, so they are skipped unless `--jam`
/// asks for them. Naming them here reports the difference rather than hiding
/// it: what `--jam` shows is filed as ENG-88, which is also where the case
/// for leaving the model alone is written down.
const jam_opcodes = [_]u8{ 0x02, 0x12, 0x22, 0x32, 0x42, 0x52, 0x62, 0x72, 0x92, 0xB2, 0xD2, 0xF2 };

// ------------------------------------------------------------ the data set

/// `[address, value]`.
const RamEntry = struct { u16, u8 };
/// `[address, value, "read"|"write"]`.
const CycleEntry = struct { u16, u8, []const u8 };

const State = struct {
    pc: u16,
    s: u8,
    a: u8,
    x: u8,
    y: u8,
    p: u8,
    ram: []const RamEntry,
};

const Scenario = struct {
    name: []const u8,
    initial: State,
    final: State,
    cycles: []const CycleEntry,
};

// ----------------------------------------------------------------- the run

const Options = struct {
    data_dir: []const u8 = default_data_dir,
    /// Which of the 256 opcode files to run, in opcode order.
    selected: [256]bool = [_]bool{true} ** 256,
    /// Scenarios per opcode, for a quick smoke run.
    limit: usize = std.math.maxInt(usize),
    /// Stop the whole sweep once this many scenarios have failed. A genuine
    /// CPU bug fails hundreds of thousands of scenarios; printing them all
    /// helps nobody.
    max_failures: usize = 20,
};

const usage =
    \\usage: test-cpu-sweep [options]
    \\
    \\  --data <dir>       where the nes6502/v1 JSON lives (default: .cache/65x02/nes6502/v1)
    \\  --opcodes <list>   comma-separated hex opcodes, e.g. 1e,a9,00 (default: all but JAM)
    \\  --jam              also run the twelve JAM opcodes (expected to fail: see the source)
    \\  --limit <n>        run only the first n scenarios of each opcode
    \\  --max-failures <n> stop after n failing scenarios (default: 20)
    \\
;

pub fn main(init: std.process.Init) u8 {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const argv = init.minimal.args.toSlice(arena) catch |err| {
        std.debug.print("could not read command line: {t}\n", .{err});
        return 2;
    };

    var opts = Options{};
    var include_jam = false;
    var explicit_opcodes = false;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--jam")) {
            include_jam = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("{s}", .{usage});
            return 0;
        } else if (i + 1 >= argv.len) {
            std.debug.print("{s} takes a value\n\n{s}", .{ arg, usage });
            return 2;
        } else if (std.mem.eql(u8, arg, "--data")) {
            i += 1;
            opts.data_dir = argv[i];
        } else if (std.mem.eql(u8, arg, "--opcodes")) {
            i += 1;
            explicit_opcodes = true;
            opts.selected = [_]bool{false} ** 256;
            var it = std.mem.splitScalar(u8, argv[i], ',');
            while (it.next()) |tok| {
                const trimmed = std.mem.trim(u8, tok, " ");
                if (trimmed.len == 0) continue;
                const code = std.fmt.parseInt(u8, trimmed, 16) catch {
                    std.debug.print("not a hex opcode: '{s}'\n", .{trimmed});
                    return 2;
                };
                opts.selected[code] = true;
            }
        } else if (std.mem.eql(u8, arg, "--limit")) {
            i += 1;
            opts.limit = std.fmt.parseInt(usize, argv[i], 10) catch {
                std.debug.print("not a number: '{s}'\n", .{argv[i]});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--max-failures")) {
            i += 1;
            opts.max_failures = std.fmt.parseInt(usize, argv[i], 10) catch {
                std.debug.print("not a number: '{s}'\n", .{argv[i]});
                return 2;
            };
        } else {
            std.debug.print("unknown option: '{s}'\n\n{s}", .{ arg, usage });
            return 2;
        }
    }
    // `--opcodes 02` means "run 02", not "run 02 unless it is a JAM".
    if (!include_jam and !explicit_opcodes) {
        for (jam_opcodes) |code| opts.selected[code] = false;
    }

    // `Bus` carries a 64KB flat array on top of everything it already owns,
    // and `Cpu` borrows it, so it lives on the heap rather than blowing a
    // default stack.
    const prg = [_]u8{0} ** 0x4000; // never read: the flat bus answers everything
    const bus = gpa.create(Bus) catch return 2;
    defer gpa.destroy(bus);
    bus.* = Bus.init(.{ .test_stub = mapper_mod.TestStub.init(&prg) });
    var cpu = Cpu.init(bus);

    var total_run: usize = 0;
    var total_failed: usize = 0;
    var opcodes_missing: usize = 0;

    for (0..256) |code_usize| {
        const code: u8 = @intCast(code_usize);
        if (!opts.selected[code]) continue;

        const path = std.fmt.allocPrint(arena, "{s}/{x:0>2}.json", .{ opts.data_dir, code }) catch return 2;
        defer arena.free(path);
        // 32MB: the largest file in the set is about 6MB.
        const json = std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(32 * 1024 * 1024)) catch |err| {
            opcodes_missing += 1;
            std.debug.print(
                \\{x:0>2}: cannot read {s} ({t})
                \\    fetch the set with tools/fetch-65x02.sh, or this one file with
                \\    curl -fsSL {s}/{x:0>2}.json -o {s}
                \\
            , .{ code, path, err, base_url, code, path });
            continue;
        };
        defer gpa.free(json);

        const parsed = std.json.parseFromSlice([]const Scenario, gpa, json, .{}) catch |err| {
            std.debug.print("{x:0>2}: {s} is not the expected JSON ({t})\n", .{ code, path, err });
            opcodes_missing += 1;
            continue;
        };
        defer parsed.deinit();

        const scenarios = parsed.value;
        const count = @min(scenarios.len, opts.limit);
        var failed_here: usize = 0;
        for (scenarios[0..count]) |scenario| {
            total_run += 1;
            if (!runScenario(bus, &cpu, scenario, code)) {
                failed_here += 1;
                total_failed += 1;
                if (total_failed >= opts.max_failures) break;
            }
        }

        const decoded = cpu_mod.opcodes[code];
        std.debug.print("{x:0>2} {s} {s: <17} {d: >6} run, {d} failed\n", .{
            code,
            decoded.mnemonic,
            @tagName(decoded.mode),
            count,
            failed_here,
        });
        if (total_failed >= opts.max_failures) {
            std.debug.print("\nstopping: {d} failures reached (--max-failures)\n", .{total_failed});
            break;
        }
    }

    std.debug.print("\n{d} scenarios run, {d} failed\n", .{ total_run, total_failed });
    if (opcodes_missing > 0) {
        std.debug.print("{d} opcode files were unreadable and were not run\n", .{opcodes_missing});
        return 2;
    }
    if (total_run == 0) {
        std.debug.print("nothing ran\n", .{});
        return 2;
    }
    return if (total_failed == 0) 0 else 1;
}

/// Run one scenario and report it. Returns true on a pass.
///
/// The flat RAM is left holding only zeros afterwards: every address this
/// scenario could have touched is cleared on the way out, so a later
/// scenario cannot pass on a byte an earlier one happened to leave behind.
/// That is three orders of magnitude cheaper than zeroing all 64KB 2.56
/// million times.
fn runScenario(bus: *Bus, cpu: *Cpu, scenario: Scenario, code: u8) bool {
    for (scenario.initial.ram) |entry| bus.flat[entry[0]] = entry[1];
    defer {
        for (scenario.initial.ram) |entry| bus.flat[entry[0]] = 0;
        for (scenario.final.ram) |entry| bus.flat[entry[0]] = 0;
        for (scenario.cycles) |entry| bus.flat[entry[0]] = 0;
    }

    cpu.* = Cpu.init(bus);
    cpu.pc = scenario.initial.pc;
    cpu.s = scenario.initial.s;
    cpu.a = scenario.initial.a;
    cpu.x = scenario.initial.x;
    cpu.y = scenario.initial.y;
    cpu.p = cpu_mod.Flags.fromByte(scenario.initial.p);
    bus.flat_log.reset();

    cpu.step();

    var header_printed = false;
    var ok = true;

    // Registers. The status byte is compared with bits 4 and 5 masked off:
    // neither exists as a flip-flop on an NMOS 6502, so this core keeps the
    // canonical in-register form (`b` clear, `u` set) while the data set
    // carries forward whatever the scenario's random initial P had there.
    // Nothing is lost by masking -- B and U are only ever observable in a
    // *pushed* copy of P, and a pushed byte is a bus write, which the
    // per-cycle comparison below checks exactly.
    const regs = [_]struct { name: []const u8, want: u16, got: u16 }{
        .{ .name = "pc", .want = scenario.final.pc, .got = cpu.pc },
        .{ .name = "s", .want = scenario.final.s, .got = cpu.s },
        .{ .name = "a", .want = scenario.final.a, .got = cpu.a },
        .{ .name = "x", .want = scenario.final.x, .got = cpu.x },
        .{ .name = "y", .want = scenario.final.y, .got = cpu.y },
        .{ .name = "p", .want = scenario.final.p & 0xCF, .got = cpu.p.toByte() & 0xCF },
    };
    for (regs) |r| {
        if (r.want == r.got) continue;
        ok = false;
        openFailure(&header_printed, code, scenario.name);
        std.debug.print("  {s}: expected ${X:0>4}, got ${X:0>4}\n", .{ r.name, r.want, r.got });
    }

    for (scenario.final.ram) |entry| {
        const actual = bus.flat[entry[0]];
        if (actual == entry[1]) continue;
        ok = false;
        openFailure(&header_printed, code, scenario.name);
        std.debug.print("  ram ${X:0>4}: expected ${X:0>2}, got ${X:0>2}\n", .{ entry[0], entry[1], actual });
    }

    // The per-cycle bus trace, reported at the first divergence: past that
    // point every later cycle is downstream of the same mistake, and a
    // hundred lines of consequence buries the one line of cause.
    const ops = bus.flat_log.slice();
    if (bus.flat_log.overflowed) {
        ok = false;
        openFailure(&header_printed, code, scenario.name);
        std.debug.print("  bus log overflowed: more than {d} cycles in one step\n", .{ops.len});
        return ok;
    }
    for (scenario.cycles, 0..) |expected, index| {
        if (index >= ops.len) {
            ok = false;
            openFailure(&header_printed, code, scenario.name);
            std.debug.print("  cycle {d}: expected {s} ${X:0>4}=${X:0>2}, but the instruction ended after {d} cycles\n", .{
                index, expected[2], expected[0], expected[1], ops.len,
            });
            return ok;
        }
        const actual = ops[index];
        const actual_kind: []const u8 = if (actual.write) "write" else "read";
        if (actual.addr == expected[0] and actual.value == expected[1] and
            std.mem.eql(u8, actual_kind, expected[2])) continue;
        ok = false;
        openFailure(&header_printed, code, scenario.name);
        std.debug.print("  cycle {d}: expected {s} ${X:0>4}=${X:0>2}, got {s} ${X:0>4}=${X:0>2}\n", .{
            index,       expected[2], expected[0], expected[1],
            actual_kind, actual.addr, actual.value,
        });
        return ok;
    }
    if (ops.len > scenario.cycles.len) {
        ok = false;
        openFailure(&header_printed, code, scenario.name);
        const extra = ops[scenario.cycles.len];
        std.debug.print("  cycle {d}: instruction should have ended, got {s} ${X:0>4}=${X:0>2}\n", .{
            scenario.cycles.len, if (extra.write) "write" else "read", extra.addr, extra.value,
        });
    }

    return ok;
}

/// Print a failing scenario's header once, however many of its registers,
/// memory locations and cycles turn out to disagree.
fn openFailure(printed: *bool, code: u8, name: []const u8) void {
    if (printed.*) return;
    printed.* = true;
    std.debug.print("\nFAIL {x:0>2} \"{s}\"\n", .{ code, name });
}
