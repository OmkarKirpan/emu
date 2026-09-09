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
//!   * `-5` -- `NoRom` (a save-state or SRAM call arrived before any
//!     successful `load_rom` -- `get_last_error_context()` is `0`)
//!   * `-6` -- `BadState` (the blob is not a save-state this build can
//!     read: wrong magic, a `format_version` from the future, or truncated
//!     -- `get_last_error_context()` is `0`)
//!   * `-7` -- `StateMapperMismatch` (the state was saved under a different
//!     mapper than the loaded ROM uses -- `get_last_error_context()` is the
//!     mapper id the *state* named)
//!   * `-8` -- `StateRomMismatch` (the state was saved against a different
//!     ROM; PRG/CHR-ROM are not in the state, so applying it would resume a
//!     CPU into unrelated code -- `get_last_error_context()` is `0`)
//!   * `-9` -- `StateTooLarge` (a state did not fit `savestate.max_state_bytes`;
//!     unreachable for any cartridge this core supports, returned rather
//!     than asserted so a future oversized mapper is a host-visible error
//!     instead of a trap -- `get_last_error_context()` is the cap)
//!
//! ## Save-states and SRAM (M8, ENG-76)
//! `save_state`/`get_state_ptr`/`get_state_len`/`load_state` move ENG-61's
//! TLV blob across the boundary through one static buffer, the same shape
//! as the framebuffer: the host never sizes anything, it reads
//! `(ptr, len)` after a successful `save_state`. `get_rom_hash_ptr` exposes
//! the SHA-256 of the currently-loaded ROM -- ENG-61 keys IndexedDB on
//! `(rom_hash, slot)`, and computing it here rather than in JS keeps one
//! definition of ROM identity across the Zig core, this ABI and the host's
//! database. `get_sram_ptr`/`get_sram_len`/`load_sram` are the battery-
//! backed cartridge RAM on its own, for the reserved `"sram"` slot, which
//! is persisted on a different schedule from a whole save-state.

const std = @import("std");
const core = @import("root.zig");
const savestate = @import("savestate.zig");
const palette = @import("palette.zig");
const audio_ring = @import("audio_ring.zig");

const status_ok: i32 = 0;
const status_invalid_header: i32 = -1;
const status_unsupported_mapper: i32 = -2;
const status_truncated_data: i32 = -3;
const status_rom_too_large: i32 = -4;
const status_no_rom: i32 = -5;
const status_bad_state: i32 = -6;
const status_state_mapper_mismatch: i32 = -7;
const status_state_rom_mismatch: i32 = -8;
const status_state_too_large: i32 = -9;

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

/// How much of `rom_storage` the loaded ROM occupies. `savestate.load`
/// re-boots the machine from these exact bytes (that is how PRG/CHR-ROM come
/// back), so the slice has to be recoverable, not just the buffer.
var g_rom_len: u32 = 0;

/// SHA-256 of the loaded ROM -- ENG-61's persistence key half. Refreshed by
/// `load_rom`, read by the host through `get_rom_hash_ptr`.
var g_rom_hash: savestate.RomHash = [_]u8{0} ** savestate.rom_hash_len;

/// The one staging buffer save-states cross the boundary in, in both
/// directions. Static rather than `alloc`'d for the same reason
/// `rgba_framebuffer` is: the host reads `(get_state_ptr, get_state_len)`
/// after a successful `save_state` and never has to size anything itself.
var g_state: [savestate.max_state_bytes]u8 = undefined;
var g_state_len: u32 = 0;

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
    g_rom_len = len;
    g_rom_hash = savestate.romHash(rom_storage[0..len]);
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
/// Independent of `load_rom`/`g_loaded`: the audio ring is its own
/// subsystem, and calling this doesn't touch `g_machine` at all -- see
/// `audio_ring.zig`'s module doc comment.
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

/// Refreshes DRC (fill_ema/current_ratio) for the real APU-fed audio ring
/// -- see `audio_ring.zig`'s `updateDrc` for the full contract (in
/// particular: always call this once per Worker tick, never batched as a
/// multi-frame catch-up). The actual samples are produced continuously by
/// `Apu.tick` via `audio_ring.pushSample`, not by this call.
export fn step_audio_frame() void {
    audio_ring.updateDrc();
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

// ------------------------------------------- save-states & SRAM (M8)

/// Serializes the whole machine into this module's static state buffer.
/// On success the host reads the blob at `(get_state_ptr, get_state_len)`
/// and persists it under `(get_rom_hash_ptr, slot)` -- see ENG-61.
///
/// The buffer is overwritten by the next `save_state`, so a host that wants
/// two states at once copies the first out before asking for the second.
export fn save_state() i32 {
    if (!g_loaded) {
        g_last_error_context = 0;
        return status_no_rom;
    }
    const n = savestate.save(&g_machine, g_rom_hash, &g_state) catch {
        g_state_len = 0;
        g_last_error_context = savestate.max_state_bytes;
        return status_state_too_large;
    };
    g_state_len = @intCast(n);
    return status_ok;
}

export fn get_state_ptr() u32 {
    return @intCast(@intFromPtr(&g_state));
}

/// Valid only after a `save_state` that returned `0`; zero otherwise.
export fn get_state_len() u32 {
    return g_state_len;
}

/// Restores a previously-saved blob, staged in via `alloc` like `load_rom`.
///
/// **A rejected state does not leave the machine half-restored, but a
/// rejected-late one does leave it power-on reset.** `savestate.load`
/// checks the ROM hash before touching anything, then re-boots from
/// `rom_storage` (that is what puts PRG/CHR-ROM back) before applying
/// sections -- so the two failures that can still occur past that point, a
/// forged mapper id and a truncated body, land on a freshly-booted console
/// rather than a corrupted one. Documented rather than papered over: the
/// alternative (snapshotting the live machine first, to roll back to) costs
/// a second `Machine` in linear memory to defend against a blob no honest
/// host produces.
export fn load_state(ptr: u32, len: u32) i32 {
    if (!g_loaded) {
        g_last_error_context = 0;
        return status_no_rom;
    }
    const blob = @as([*]const u8, @ptrFromInt(ptr))[0..len];
    savestate.load(&g_machine, rom_storage[0..g_rom_len], blob) catch |err| switch (err) {
        error.MapperMismatch => {
            // The id the *state* named -- the useful half of the mismatch,
            // since the host can already see which ROM it loaded.
            g_last_error_context = if (len > 8) blob[8] else 0;
            return status_state_mapper_mismatch;
        },
        error.RomMismatch => {
            g_last_error_context = 0;
            return status_state_rom_mismatch;
        },
        // `BadMagic`, `UnsupportedVersion`, `Truncated`, and `Machine.init`'s
        // own errors -- which cannot fire here, since `rom_storage` already
        // parsed cleanly in `load_rom`. All of them mean the same thing to a
        // host: this blob is not a state this build can apply.
        else => {
            g_last_error_context = 0;
            return status_bad_state;
        },
    };
    return status_ok;
}

/// SHA-256 of the loaded ROM: 32 bytes, the `rom_hash` half of ENG-61's
/// `(rom_hash, slot)` persistence key. Zero-filled before the first
/// successful `load_rom`.
export fn get_rom_hash_ptr() u32 {
    return @intCast(@intFromPtr(&g_rom_hash));
}

/// Battery-backed cartridge RAM ($6000-$7FFF), exposed directly rather than
/// copied: the host reads these bytes to persist ENG-61's reserved `"sram"`
/// slot, on its own schedule, without serializing a whole machine. `0`
/// before any ROM is loaded, since there is no cartridge to have RAM.
export fn get_sram_ptr() u32 {
    if (!g_loaded) return 0;
    return @intCast(@intFromPtr(&g_machine.bus.prg_ram));
}

/// The *addressable* size, not the whole `Bus.prg_ram` buffer: ENG-79 sized
/// that at a flat 32KB for access speed, while all but MMC1's SOROM/SXROM
/// boards carry 8KB. Persisting the buffer would store 24KB of guaranteed
/// zeroes per cartridge. `0` before any ROM is loaded, matching
/// `get_sram_ptr`.
export fn get_sram_len() u32 {
    if (!g_loaded) return 0;
    return @intCast(savestate.prgRamBytes(&g_machine.bus.mapper));
}

/// Restores previously-persisted SRAM, staged in via `alloc`. Called right
/// after `load_rom` and before the first `step_frame`, mirroring a real
/// cartridge's battery being present from power-on.
///
/// A `len` other than the full 8KB is rejected rather than partially
/// applied: a short record means the stored data is not this cartridge's
/// SRAM, and half-restoring a save file is worse than not restoring it.
export fn load_sram(ptr: u32, len: u32) i32 {
    if (!g_loaded) {
        g_last_error_context = 0;
        return status_no_rom;
    }
    const expected = get_sram_len();
    if (len != expected) {
        g_last_error_context = expected;
        return status_bad_state;
    }
    const src = @as([*]const u8, @ptrFromInt(ptr))[0..len];
    @memcpy(&g_machine.bus.prg_ram, src);
    return status_ok;
}
