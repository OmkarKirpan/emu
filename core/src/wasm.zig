//! The wasm32-freestanding export surface (ENG-69, M4) -- the actual root
//! module `zig build wasm` compiles. Implements the ABI ENG-60 designed: an
//! implicit global-singleton emulator (`g_machine` below), free
//! functions operating on it directly, and `i32` status codes in place of
//! exceptions (Zig has none to hand across a wasm boundary).
//!
//! Deliberately separate from `root.zig` (the native library/test root):
//! wasm-only concerns -- this file's globals, the `alloc`/`free` surface,
//! and the palette-to-RGBA8 resolve `step_frame` performs -- must never
//! reach the native build, and native-only concerns (`Cpu.trace`, the
//! vendored-ROM native test suite `root.zig`'s own `test {}` block pulls
//! in) must never reach this one. `root.zig` is still imported for its
//! types: the two builds share one implementation, just not one entry
//! point.
//!
//! ## Audio ring buffer (ENG-62, M5)
//! `init`/`get_audio_ring_ptr`/`get_audio_ring_control_ptr`/
//! `get_audio_ring_capacity`/`step_audio_frame` are purely additive to the
//! ABI above -- none of them can fail, so none returns a status code. Their
//! actual logic lives in `audio_ring.zig`; see that file's module doc
//! comment for the producer/consumer protocol and why the ring is its own
//! subsystem, independent of `g_machine`/the loaded ROM.
//!
//! ## Status codes
//! Every fallible export returns one of these (`0` = success); nothing else
//! exported here can fail, so nothing else returns a status.
//!
//!   *  `0` -- ok
//!   * `-1` -- `InvalidHeader` (too short, bad magic, or a mapper-specific
//!     bank-count check failed -- `get_last_error_context()` is `0`)
//!   * `-2` -- `UnsupportedMapper` (`get_last_error_context()` is the
//!     mapper id the header named)
//!   * `-3` -- `TruncatedData` (declared PRG/CHR size ran past the data the
//!     host actually supplied -- `get_last_error_context()` is how many
//!     bytes were actually supplied)
//!   * `-4` -- `RomTooLarge` (`get_last_error_context()` is `max_rom_bytes`,
//!     the cap that was exceeded)

const std = @import("std");
const core = @import("root.zig");
const palette = @import("palette.zig");
const audio_ring = @import("audio_ring.zig");

const status_ok: i32 = 0;
const status_invalid_header: i32 = -1;
const status_unsupported_mapper: i32 = -2;
const status_truncated_data: i32 = -3;
const status_rom_too_large: i32 = -4;

/// Generously above NROM's own ~40KB ceiling (16-byte header + 32KB PRG +
/// 8KB CHR) to leave headroom for M7's MMC1/UxROM/CNROM/MMC3 without this
/// ABI needing to change again. Oversized input is rejected with
/// `RomTooLarge`, never silently truncated.
const max_rom_bytes = 512 * 1024;

/// Backs the currently-loaded ROM. `Mapper.Nrom.prg_rom` borrows a slice of
/// whatever buffer it was built from (see that type's own doc comment) --
/// this is that buffer's permanent home, so it stays valid for the lifetime
/// of `g_machine.bus.mapper`, unlike the transient `alloc`'d buffer used to
/// carry the bytes across the boundary in the first place (see `load_rom`).
var rom_storage: [max_rom_bytes]u8 = undefined;

/// ENG-60's "implicit global singleton": the one console this module ever
/// runs, booted by `machine.zig`'s shared five-step sequence like every
/// native harness. A package-level global never moves, which is exactly what
/// `Machine`'s "must not be copied after `init`" rule needs (`cpu` borrows
/// `&self.bus`).
var g_machine: core.Machine = undefined;

/// Whether `g_machine` has been booted. Everything that would touch it is a
/// no-op until then -- see `step_frame`.
var g_loaded: bool = false;

var g_last_error_context: u32 = 0;

const pixel_count = @typeInfo(@FieldType(core.Ppu, "framebuffer")).array.len;

/// Fixed static RGBA8 buffer `get_framebuffer_ptr` points at -- one 32-bit
/// color per `Ppu.framebuffer` palette-index entry, refreshed at the end of
/// every `step_frame`. See `resolveFramebuffer`'s doc comment for why the
/// resolve happens here rather than inside `Ppu.outputPixel` itself.
///
/// Typed `u32` rather than `[N * 4]u8` so a pixel is one store, and sized
/// off `Ppu.framebuffer`'s own length rather than restating 256x240: that
/// makes `resolveFramebuffer`'s two-object `for` a compile-time length
/// check, so a future change to the PPU's framebuffer dimensions fails the
/// build here instead of silently writing past this buffer. The host still
/// sees plain RGBA8 bytes -- `u32` is 4-byte aligned, which is exactly what
/// a `Uint8ClampedArray` view (and `putImageData`) wants.
var rgba_framebuffer: [pixel_count]u32 = [_]u32{0} ** pixel_count;

/// Generic byte-buffer staging (ENG-60): the host allocates, copies a
/// `Uint8Array` view in, then passes `(ptr, len)` to whichever export
/// consumes it -- `load_rom` today, anything else arbitrary-length later.
/// Backed by `std.heap.wasm_allocator`, the standard-library allocator
/// built for exactly this (freestanding wasm32, `@wasmMemoryGrow`-backed,
/// real per-allocation free/reuse) -- no hand-rolled bump allocator needed.
export fn alloc(size: u32) u32 {
    const mem = std.heap.wasm_allocator.alloc(u8, size) catch return 0;
    return @intCast(@intFromPtr(mem.ptr));
}

export fn free(ptr: u32, size: u32) void {
    if (ptr == 0) return;
    const slice = @as([*]u8, @ptrFromInt(ptr))[0..size];
    std.heap.wasm_allocator.free(slice);
}

/// Parses and mapper-checks `data` purely to validate it, touching no
/// persistent state, and returns the status code above for the first
/// failure found (or `null` on success). Split out of `load_rom` so a
/// malformed ROM can never partially overwrite `rom_storage` and corrupt an
/// already-running machine -- see `load_rom`.
fn validate(data: []const u8) ?i32 {
    const rom = core.Rom.load(data) catch |err| switch (err) {
        error.TooShort, error.BadMagic => {
            g_last_error_context = 0;
            return status_invalid_header;
        },
        error.Truncated => {
            g_last_error_context = @intCast(data.len);
            return status_truncated_data;
        },
    };
    _ = core.createMapper(rom) catch |err| switch (err) {
        error.UnsupportedMapper => {
            g_last_error_context = rom.header.mapper;
            return status_unsupported_mapper;
        },
        error.InvalidRomGeometry => {
            g_last_error_context = 0;
            return status_invalid_header;
        },
    };
    return null;
}

/// `data[ptr..ptr+len]` is only ever borrowed for the duration of this call
/// -- typically the host's `alloc`'d staging buffer, freed right after this
/// returns (per the ABI's `alloc`/`free` contract). `validate` never keeps a
/// reference to it, and the persistent copy this makes into `rom_storage`
/// is what `g_machine.bus.mapper` actually ends up pointing into afterward.
export fn load_rom(ptr: u32, len: u32) i32 {
    if (len > max_rom_bytes) {
        g_last_error_context = max_rom_bytes;
        return status_rom_too_large;
    }

    const src = @as([*]const u8, @ptrFromInt(ptr))[0..len];
    if (validate(src)) |err_status| return err_status;

    @memcpy(rom_storage[0..len], src);
    // Byte-identical to what `validate` just proved parses cleanly.
    g_machine.init(rom_storage[0..len]) catch unreachable;
    g_loaded = true;
    return status_ok;
}

export fn reset() void {
    if (!g_loaded) return;
    g_machine.cpu.reset();
}

/// One full NTSC video frame's worth of cycle-accurate CPU/PPU interleaving
/// -- the primary playback call. A no-op before the first successful
/// `load_rom`, rather than undefined behavior on an unloaded `g_machine`,
/// so a host that races `step_frame` against `load_rom` (e.g. an
/// `requestAnimationFrame` loop already ticking before the ROM fetch lands)
/// degrades to "nothing happened yet" instead of crashing the module.
export fn step_frame() void {
    if (!g_loaded) return;
    g_machine.runFrames(1);
    resolveFramebuffer();
}

/// Called once, after instantiation -- not per-frame (ENG-60). The host
/// builds one `Uint8ClampedArray` view over `[ptr, ptr + 256*240*4)` and
/// reuses it; `step_frame` refreshes the bytes underneath in place.
export fn get_framebuffer_ptr() u32 {
    return @intCast(@intFromPtr(&rgba_framebuffer));
}

/// One packed byte per controller, NES bit order (A/B/Select/Start/
/// Up/Down/Left/Right) -- see `controller.zig`'s module doc comment, which
/// already locked this exact layout in anticipation of this export. Two
/// ports (`0`/`1`); anything else, or a call before any ROM is loaded, is
/// silently ignored rather than an error -- input arriving slightly early
/// or for a port nothing uses is not a failure the host needs to handle.
export fn set_input(controller: u8, buttons: u8) void {
    if (!g_loaded or controller > 1) return;
    g_machine.bus.controllers[controller].setButtons(buttons);
}

/// Valid to call after any non-zero `load_rom` status; see the status-code
/// table in this file's doc comment for what the number means per code.
export fn get_last_error_context() u32 {
    return g_last_error_context;
}

/// One instance's whole audio subsystem is reset by one call to this --
/// called once by the host right after instantiation, before the first
/// `step_audio_frame` (ENG-62's handshake: the device's real `AudioContext`
/// sample rate is only known at runtime, so the core has to be told it).
/// Independent of `load_rom`/`g_loaded`: the audio ring produces its test
/// tone whether or not a ROM is loaded, and calling this doesn't touch
/// `g_machine` at all -- see `audio_ring.zig`'s module doc comment.
export fn init(sample_rate: f32) void {
    audio_ring.init(sample_rate);
}

/// Called once, after `init` -- not per-frame, same convention as
/// `get_framebuffer_ptr`. The host builds one `Float32Array` view over
/// `[ptr, ptr + get_audio_ring_capacity() * 4)` and reuses it.
export fn get_audio_ring_ptr() u32 {
    return @intCast(@intFromPtr(audio_ring.ringPtr()));
}

/// Called once, after `init`. The host builds one `Int32Array` view over
/// `[ptr, ptr + 3 * audio_ring.cache_line_bytes)` -- see `audio_ring.zig`'s
/// `ControlBlock` doc comment for the exact field offsets that layout
/// implies.
export fn get_audio_ring_control_ptr() u32 {
    return @intCast(@intFromPtr(audio_ring.controlPtr()));
}

export fn get_audio_ring_capacity() u32 {
    return audio_ring.capacity;
}

/// Advances the test tone by one nominal NES frame's worth of samples and
/// updates DRC -- see `audio_ring.zig`'s `stepFrame` for the full contract
/// (in particular: always call this once per Worker tick, never batched as
/// a multi-frame catch-up).
export fn step_audio_frame() void {
    audio_ring.stepFrame();
}

/// Palette-to-color resolve: `Ppu.framebuffer` stores raw 6-bit NES palette
/// indices (see that field's own doc comment), but both consumers this ABI
/// is designed for -- Canvas 2D's `putImageData` today, a WebGPU
/// `rgba8unorm` texture upload later -- want RGBA8 with zero conversion left
/// for either to do (ENG-60). Doing that resolve here, once per frame,
/// rather than inline in `Ppu.outputPixel` per-pixel, keeps that hot
/// native/wasm-shared path free of a wasm-only concern and free of
/// `palette.zig`'s color-table dependency -- `Ppu`'s own tests assert
/// palette *indices*, which would otherwise all need rewriting to assert
/// RGB triples instead.
///
/// The `& 0x3F` is not defensive: `outputPixel` already masks every value it
/// writes, but restating it here keeps the index a provable `u6` into a
/// 64-entry table, so the bounds check folds away instead of becoming a
/// branch and a panic path in every non-ReleaseFast build.
fn resolveFramebuffer() void {
    for (&g_machine.bus.ppu.framebuffer, &rgba_framebuffer) |index, *out| {
        out.* = palette.rgba[index & 0x3F];
    }
}
