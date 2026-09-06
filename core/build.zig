const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The published native module, for anything that wants to depend on the
    // core as a library. Per "Test-ROM harness architecture" (ENG-64),
    // correctness is established ONLY on the native target — the wasm32 build
    // below is pure delivery.
    _ = b.addModule("nes_core", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // A separate module for the test binary, sharing the same root source but
    // carrying the vendored nestest fixtures as anonymous imports. Keeping
    // them off the published module means it stays a pure code dependency,
    // and — more importantly — the wasm build below never sees the ~900KB of
    // test data.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addAnonymousImport("nestest_rom", .{
        .root_source_file = b.path("tests/roms/nestest/nestest.nes"),
    });
    test_mod.addAnonymousImport("nestest_log", .{
        .root_source_file = b.path("tests/roms/nestest/nestest.log"),
    });

    // The 10 individual `ppu_vbl_nmi` sub-tests (each independently confirmed
    // mapper 0/NROM -- the combined multi-test ROM is mapper 1/MMC1, which
    // this codebase cannot run). Same native-test-only treatment as nestest's
    // fixtures above.
    const ppu_vbl_nmi_names = [_][]const u8{
        "01-vbl_basics",
        "02-vbl_set_time",
        "03-vbl_clear_time",
        "04-nmi_control",
        "05-nmi_timing",
        "06-suppression",
        "07-nmi_on_timing",
        "08-nmi_off_timing",
        "09-even_odd_frames",
        "10-even_odd_timing",
    };
    for (ppu_vbl_nmi_names) |name| {
        test_mod.addAnonymousImport(name, .{
            .root_source_file = b.path(b.fmt("tests/roms/ppu_vbl_nmi/rom_singles/{s}.nes", .{name})),
        });
    }

    // ENG-68 (M3): the sprite/OAM conformance stage. `oam_read`/`oam_stress`
    // use the standard `$6000` protocol like `ppu_vbl_nmi` above;
    // `sprite_hit_tests_2005.10.05`/`sprite_overflow_tests` predate that
    // convention and report via nametable text instead -- see each
    // directory's `ATTRIBUTION.md`. All confirmed mapper 0/NROM.
    test_mod.addAnonymousImport("oam_read", .{
        .root_source_file = b.path("tests/roms/oam_read/oam_read.nes"),
    });
    test_mod.addAnonymousImport("oam_stress", .{
        .root_source_file = b.path("tests/roms/oam_stress/oam_stress.nes"),
    });
    const sprite_hit_names = [_][]const u8{
        "01.basics",
        "02.alignment",
        "03.corners",
        "04.flip",
        "05.left_clip",
        "06.right_edge",
        "07.screen_bottom",
        "08.double_height",
        "09.timing_basics",
        "10.timing_order",
        "11.edge_timing",
    };
    for (sprite_hit_names) |name| {
        test_mod.addAnonymousImport(b.fmt("sprite_hit_{s}", .{name}), .{
            .root_source_file = b.path(b.fmt("tests/roms/sprite_hit_tests_2005.10.05/{s}.nes", .{name})),
        });
    }
    const sprite_overflow_names = [_][]const u8{
        "1.Basics", "2.Details", "3.Timing", "4.Obscure", "5.Emulator",
    };
    for (sprite_overflow_names) |name| {
        test_mod.addAnonymousImport(b.fmt("sprite_overflow_{s}", .{name}), .{
            .root_source_file = b.path(b.fmt("tests/roms/sprite_overflow_tests/{s}.nes", .{name})),
        });
    }

    // ENG-68's native NROM sprite+input integration fixture. An original,
    // hand-written ROM (not a vendored third-party fixture -- no
    // ATTRIBUTION.md needed), assembled with cc65; see
    // tests/roms/nrom_demo/README.md for why (copyright: no real commercial
    // game is vendored here) and how to reproduce the build.
    test_mod.addAnonymousImport("sprite_input_demo", .{
        .root_source_file = b.path("tests/roms/nrom_demo/sprite_input_demo.nes"),
    });

    // ENG-71 (M6): the APU conformance stage. All 8 confirmed mapper 0/NROM,
    // same $6000-protocol treatment as ppu_vbl_nmi/oam_read above -- see
    // tests/roms/apu_test/ATTRIBUTION.md.
    const apu_test_names = [_][]const u8{
        "1-len_ctr", "2-len_table", "3-irq_flag", "4-jitter",
        "5-len_timing", "6-irq_flag_timing", "7-dmc_basics", "8-dmc_rates",
    };
    for (apu_test_names) |name| {
        test_mod.addAnonymousImport(b.fmt("apu_test_{s}", .{name}), .{
            .root_source_file = b.path(b.fmt("tests/roms/apu_test/rom_singles/{s}.nes", .{name})),
        });
    }

    const mod_tests = b.addTest(.{ .root_module = test_mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    // The wasm32-freestanding build: `src/wasm.zig` (not `root.zig` — see
    // its own doc comment) is the actual delivery artifact as of ENG-69
    // (M4), exporting the ABI ENG-60 designed. Still no shared_memory/
    // atomics (that's ENG-56, M5).
    //
    // Its optimize mode is deliberately *its own* option rather than the
    // shared `-Doptimize` above, and defaults to ReleaseFast: this is the
    // build a browser runs at 60fps, where a Debug core pays for bounds and
    // overflow checks on every one of ~89,000 `Ppu.tick`s and ~29,780 CPU
    // cycles per frame. Sharing `-Doptimize` would have meant either
    // shipping that Debug core (what happens when nobody passes the flag)
    // or optimizing the native tests, which want those checks precisely
    // because correctness is established there. `-Dwasm-optimize=Debug`
    // when debugging the delivered module itself.
    const wasm_optimize = b.option(
        std.builtin.OptimizeMode,
        "wasm-optimize",
        "Optimize mode for the wasm32 delivery build (default: ReleaseFast)",
    ) orelse .ReleaseFast;
    // ENG-56 (M5): `atomics` + `bulk_memory` on top of the `generic` baseline
    // -- Zig's default wasm CPU model doesn't include either, and the audio
    // ring buffer's lock-free protocol (ENG-62) needs real wasm atomic
    // instructions rather than LLVM silently lowering `@atomicLoad`/
    // `@atomicStore` to plain non-atomic ops. Equivalent to
    // `-mcpu=generic+atomics+bulk_memory`.
    var wasm_target_query: std.Target.Query = .{ .cpu_arch = .wasm32, .os_tag = .freestanding };
    wasm_target_query.cpu_features_add.addFeatureSet(std.Target.wasm.featureSet(&.{ .atomics, .bulk_memory }));
    const wasm_target = b.resolveTargetQuery(wasm_target_query);
    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/wasm.zig"),
        .target = wasm_target,
        .optimize = wasm_optimize,
    });
    const wasm_exe = b.addExecutable(.{ .name = "nes_core", .root_module = wasm_mod });
    wasm_exe.entry = .disabled;
    wasm_exe.rdynamic = true;
    // ENG-56/ENG-62 (M5): growable *shared* linear memory, so `memory.buffer`
    // is a `SharedArrayBuffer` on the JS side and can be handed to an
    // `AudioWorkletProcessor` directly. The WebAssembly threads proposal
    // requires a shared memory to declare a fixed max -- `max_memory` is
    // mandatory the moment `shared_memory` is true, not just a tuning knob.
    // 64 MiB (page-aligned: 1024 * 64KiB pages) is generous headroom over
    // today's static footprint (the 512KiB ROM staging buffer, the 245,760-
    // byte RGBA framebuffer, the 32KiB audio ring, `Machine`'s CPU/PPU/bus
    // state, and the `wasm_allocator` heap for ROM-load staging) -- revisit
    // if a future milestone's static data grows enough to approach it.
    wasm_exe.shared_memory = true;
    wasm_exe.max_memory = 64 * 1024 * 1024;
    const wasm_step = b.step("wasm", "Build the wasm32-freestanding module");
    wasm_step.dependOn(&b.addInstallArtifact(wasm_exe, .{}).step);
}
