const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The native module: this is what `zig build test` compiles and runs.
    // Per "Test-ROM harness architecture" (ENG-64), correctness is established
    // ONLY on the native target — the wasm32 build below is pure delivery.
    const mod = b.addModule("nes_core", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    // The wasm32-freestanding build: proves the module compiles for the
    // delivery target. No shared_memory/atomics yet (that's ENG-56, M5) and
    // no exported ABI functions yet (that's ENG-60, M4) — this step exists
    // purely so a wasm regression is caught before those milestones need it.
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });
    const wasm_exe = b.addExecutable(.{ .name = "nes_core", .root_module = wasm_mod });
    wasm_exe.entry = .disabled;
    wasm_exe.rdynamic = true;
    const wasm_step = b.step("wasm", "Build the wasm32-freestanding module");
    wasm_step.dependOn(&b.addInstallArtifact(wasm_exe, .{}).step);
}
