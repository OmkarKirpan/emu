//! ENG-61's save-state binary format (M8, ENG-76): the whole emulated
//! machine, minus what the ROM file already carries, as one tagged
//! (magic + version + TLV sections) little-endian blob.
//!
//! ## Why one direction-generic codec instead of a writer and a reader
//!
//! Every field below is named exactly once, in a function that runs in both
//! directions (`Dir.save` writes it, `Dir.load` reads it back into the same
//! place). The alternative -- a `writeCpu`/`readCpu` pair per component --
//! is the classic way to ship a serializer whose two halves disagree about
//! field order by one `u8`, which corrupts every field after it and does so
//! silently, since a byte stream has no shape to check against. Here that
//! bug is not possible to write: there is only one field list.
//!
//! ## What is in the state, and what deliberately is not
//!
//! ENG-61 fixes the enumeration -- CPU (architectural registers *and* the
//! interrupt latches cycle-accurate timing depends on), WRAM, cartridge
//! PRG-RAM/SRAM, the PPU's mid-scanline pipeline, the APU's channels and
//! frame sequencer, the controllers' shift registers, and one opaque
//! per-mapper section. Three exclusions, all deliberate:
//!
//! * **PRG-ROM and CHR-ROM.** Static; re-derived from the ROM file, which
//!   is why `load` re-boots the machine from `rom_bytes` before applying
//!   any section (see its doc comment) rather than carrying ~40-512KB of
//!   cartridge in every slot. CHR-*RAM* is mutable and is serialized, in
//!   the mapper section, exactly where the mapper knows it has any.
//!
//! * **The APU's RC filter cascade** (`Apu.hpf1`/`hpf2`/`lpf` and
//!   `output_sample`) -- the one place this format knowingly loses
//!   information rather than merely re-deriving it. Those three one-pole
//!   filters are a pure function of the mixed channel output this format
//!   *does* carry, with time constants of 90Hz/440Hz/14kHz: a resumed
//!   state re-converges on the correct filter state in well under a
//!   millisecond, which is inaudible. Serializing them would put six `f32`s
//!   into the blob, and this blob is also `determinism.zig`'s hash input
//!   (below) -- which would make the determinism digest sensitive to
//!   floating-point rounding differences across targets, in exchange for
//!   nothing anyone can hear. See
//!   `docs/adr/0006-save-state-format-doubles-as-the-determinism-hash.md`.
//!
//! * **`Ppu.framebuffer`.** 61,440 bytes of *output*, not state: the
//!   in-progress frame is redrawn from the dot the state resumes at, and
//!   ENG-61's enumeration does not list it. Including it would roughly
//!   quadruple a state for one frame's worth of already-stale pixels.
//!
//! ## This is also the determinism hash
//!
//! Per ENG-61 ("the serializer doubles as test infrastructure"),
//! `determinism.zig` hashes exactly this blob rather than keeping a second,
//! hand-maintained field list that could drift out of sync with this one.
//! That is why nothing here writes padding or uninitialized bytes: every
//! byte of the output is a field, so two runs that agree on the machine
//! agree on the digest. `?T` fields cost a presence byte plus a
//! *zero-filled* payload when absent, never `undefined`, for the same
//! reason.
//!
//! ## Forward compatibility
//!
//! A reader skips section ids it does not know (`Section._`), so a state
//! written by a later version that added a component still loads, with that
//! component left at its power-on default -- which falls out of `load`'s
//! re-boot-then-apply order for free. `format_version` is reserved for a
//! change this scheme cannot absorb (a *reinterpreted* section, not a new
//! one); adding a component is not one, and must not bump it.

const std = @import("std");
const testing = std.testing;

const machine_mod = @import("machine.zig");
const Machine = machine_mod.Machine;
const cpu_mod = @import("cpu.zig");
const ppu_mod = @import("ppu.zig");
const apu_mod = @import("apu.zig");
const mapper_mod = @import("mapper.zig");
const controller_mod = @import("controller.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const magic = [4]u8{ 'N', 'E', 'S', 'S' };

/// Bumped only for a change that reinterprets bytes an older reader would
/// misread -- see the module doc comment. Adding a section is not that.
pub const format_version: u32 = 2;

pub const rom_hash_len = Sha256.digest_length;
pub const RomHash = [rom_hash_len]u8;

/// magic(4) + version(4) + mapper id(1) + reserved(3) + rom hash(32).
/// The three reserved bytes exist so the hash lands 4-byte aligned and so a
/// future single-byte header field costs no layout change.
pub const header_bytes = 4 + 4 + 1 + 3 + rom_hash_len;

/// Comfortably above the worst case this core can produce: WRAM 2K + SRAM
/// 8K + PPU (2K VRAM + OAM + latches) + CHR-RAM 8K + everything scalar is
/// a shade over 20KB, matching ENG-61's own "well under 20 KB with this
/// layout" estimate. Sized as one fixed buffer rather than an allocation
/// because `wasm.zig` wants a static home for it anyway (same shape as the
/// framebuffer and the audio ring).
pub const max_state_bytes = 64 * 1024;

/// Section ids. Non-exhaustive on purpose: an unrecognized id is data from
/// a newer writer, not a corrupt file -- see the module doc comment.
pub const Section = enum(u16) {
    cpu = 1,
    wram = 2,
    /// Cartridge PRG-RAM at $6000-$7FFF -- the battery-backed SRAM the host
    /// also persists on its own under ENG-61's reserved `"sram"` slot.
    sram = 3,
    ppu = 4,
    apu = 5,
    controllers = 6,
    /// Opaque, per-mapper. Its contents are defined by whichever mapper the
    /// header's id names; a state saved under a different mapper is
    /// rejected outright rather than reinterpreted.
    mapper = 7,
    /// The CPU-side open-bus latch. Its own section rather than a CPU field
    /// because it belongs to `Bus`, and sections are per-component.
    bus = 8,
    _,
};

const all_sections = [_]Section{ .cpu, .wram, .sram, .ppu, .apu, .controllers, .mapper, .bus };

pub const SaveError = error{
    /// The destination buffer was smaller than the state -- see
    /// `max_state_bytes`.
    NoSpace,
};

pub const LoadError = error{
    BadMagic,
    UnsupportedVersion,
    /// A length field ran past the end of the blob, or a section body was
    /// shorter than the fields it declares.
    Truncated,
    /// The state was saved under a different mapper than the currently
    /// loaded ROM uses. Its `mapper` section is opaque and per-mapper, so
    /// applying it would silently produce nonsense.
    MapperMismatch,
    /// The state was saved against a different ROM. PRG/CHR-ROM are not in
    /// the state; loading it against another cartridge would resume a CPU
    /// into unrelated code.
    RomMismatch,
};

/// The identity ENG-61 keys persistence on (`(rom_hash, slot)`), computed
/// here rather than host-side so exactly one definition of "which ROM is
/// this" exists across the Zig core, the wasm ABI and IndexedDB.
pub fn romHash(rom_bytes: []const u8) RomHash {
    var out: RomHash = undefined;
    Sha256.hash(rom_bytes, &out, .{});
    return out;
}

/// The id recorded in the header and checked on load. These are the iNES
/// mapper numbers, so the value is meaningful in a hex dump; `test_stub` is
/// not a cartridge and can never appear in a state saved from a real ROM.
fn mapperId(m: *const mapper_mod.Mapper) u8 {
    return switch (m.*) {
        .nrom => 0,
        .mmc1 => 1,
        .uxrom => 2,
        .cnrom => 3,
        .mmc3 => 4,
        .test_stub => 0xFF,
    };
}

// ------------------------------------------------------------- public API

/// Serialize `m` into `out`, returning the number of bytes written.
///
/// `m` is `*const`: the save direction only ever reads through it. The
/// single `@constCast` below is what lets one field list serve both
/// directions -- see the module doc comment for why that matters more than
/// the cast costs.
pub fn save(m: *const Machine, rom_hash: RomHash, out: []u8) SaveError!usize {
    var c = Codec(.save){ .buf = out };
    const mutable = @constCast(m);

    c.header(rom_hash, mapperId(&m.bus.mapper)) catch return error.NoSpace;
    inline for (all_sections) |id| {
        const start = c.beginSection(id) catch return error.NoSpace;
        sectionBody(.save, &c, mutable, id) catch return error.NoSpace;
        c.endSection(start);
    }
    return c.pos;
}

/// Restore `blob` into `m`, which is re-booted from `rom_bytes` first.
///
/// **The re-boot is load-bearing, not belt-and-braces.** It is what puts
/// PRG-ROM/CHR-ROM back (the state does not carry them), and it is what
/// gives ENG-65's "a component this state does not mention is left at its
/// power-on default" semantics for free -- an older state simply doesn't
/// overwrite the newer component that was booted to its default a moment
/// ago.
///
/// `rom_bytes` must be the same buffer the caller keeps alive for the
/// machine's lifetime (`Machine.init` borrows PRG-ROM out of it), and must
/// be the ROM the state was saved against -- checked, not assumed.
/// The error set is inferred rather than written as `LoadError!void`: the
/// re-boot below can also fail with `Machine.init`'s own `Rom.LoadError` /
/// `MapperError`, which a caller handing over a ROM this core already
/// accepted will never see, but which is not this function's to swallow.
pub fn load(m: *Machine, rom_bytes: []const u8, blob: []const u8) !void {
    var c = Codec(.load){ .buf = blob };
    const head = try c.readHeader();
    if (!std.mem.eql(u8, &head.rom_hash, &romHash(rom_bytes))) return error.RomMismatch;

    try m.init(rom_bytes);
    if (head.mapper_id != mapperId(&m.bus.mapper)) return error.MapperMismatch;

    while (c.remaining() > 0) {
        const raw_id = try c.sectionId();
        const len = try c.sectionLen();
        const body = try c.take(len);
        inline for (all_sections) |id| {
            if (raw_id == id) {
                var sub = Codec(.load){ .buf = body };
                try sectionBody(.load, &sub, m, id);
            }
        }
        // Unrecognized id: skipped, per the module doc comment. `take`
        // already advanced past it.
    }
}

/// `save` into a caller-provided scratch buffer and hash the result --
/// ENG-61's "the serializer doubles as the hashing mechanism". Lives here
/// rather than in `determinism.zig` so the blob and its digest can never be
/// computed over two different field lists.
pub fn hash(m: *const Machine, scratch: []u8) SaveError!RomHash {
    const n = try save(m, [_]u8{0} ** rom_hash_len, scratch);
    var out: RomHash = undefined;
    Sha256.hash(scratch[0..n], &out, .{});
    return out;
}

// ----------------------------------------------------------------- codec

const Dir = enum { save, load };

const CodecError = error{ NoSpace, Truncated, BadMagic, UnsupportedVersion };

const Header = struct {
    mapper_id: u8,
    rom_hash: RomHash,
};

/// How many bytes a field of type `T` occupies on the wire: its bit width
/// rounded up to the next whole 1/2/4/8-byte machine integer. Fixed per
/// type, never per value -- a `u15` is always 2 bytes even when it holds 3,
/// so the layout is a property of the field list alone.
fn StorageInt(comptime T: type) type {
    const bits: u16 = switch (@typeInfo(T)) {
        .bool => 1,
        .int => |i| i.bits,
        // Packed structs (`Flags`, `Ctrl`, `Mask`, `Status`) travel as their
        // declared backing integer, which is exactly the byte a real
        // register holds.
        .@"struct" => |s| @typeInfo(s.backing_integer.?).int.bits,
        else => @compileError("savestate: unsupported field type " ++ @typeName(T)),
    };
    return std.meta.Int(.unsigned, if (bits <= 8) 8 else if (bits <= 16) 16 else if (bits <= 32) 32 else 64);
}

fn toStorage(value: anytype) StorageInt(@TypeOf(value)) {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .bool => @intFromBool(value),
        .int => @intCast(value),
        .@"struct" => @as(std.meta.Int(.unsigned, @bitSizeOf(T)), @bitCast(value)),
        else => unreachable,
    };
}

fn fromStorage(comptime T: type, raw: StorageInt(T)) T {
    return switch (@typeInfo(T)) {
        .bool => raw != 0,
        // Truncating, not `@intCast`: a corrupt or hand-edited blob must not
        // panic the core. A `u3` field can only ever mean one of 8 values,
        // and the high bits of its byte carry nothing.
        .int => @truncate(raw),
        .@"struct" => @bitCast(@as(std.meta.Int(.unsigned, @bitSizeOf(T)), @truncate(raw))),
        else => unreachable,
    };
}

/// The one cursor both directions share. `dir` decides whether `scalar`
/// stores or fetches; every caller below is written once and compiled
/// twice.
fn Codec(comptime dir: Dir) type {
    return struct {
        const Self = @This();
        const Slice = if (dir == .save) []u8 else []const u8;

        buf: Slice,
        pos: usize = 0,

        fn remaining(self: *const Self) usize {
            return self.buf.len - self.pos;
        }

        fn take(self: *Self, n: usize) CodecError!Slice {
            if (self.remaining() < n) return if (dir == .save) error.NoSpace else error.Truncated;
            defer self.pos += n;
            return self.buf[self.pos..][0..n];
        }

        fn scalar(self: *Self, ptr: anytype) CodecError!void {
            const T = @TypeOf(ptr.*);
            if (@typeInfo(T) == .optional) return self.optional(ptr);
            const U = StorageInt(T);
            const region = try self.take(@sizeOf(U));
            if (dir == .save) {
                std.mem.writeInt(U, region[0..@sizeOf(U)], toStorage(ptr.*), .little);
            } else {
                ptr.* = fromStorage(T, std.mem.readInt(U, region[0..@sizeOf(U)], .little));
            }
        }

        /// Presence byte + a payload that is always present on the wire --
        /// zero-filled when the value is `null`, never `undefined`, so
        /// "absent" hashes reproducibly and so `null` stays distinguishable
        /// from a real zero (which `determinism.zig`'s DMC sample-buffer
        /// test asserts directly).
        fn optional(self: *Self, ptr: anytype) CodecError!void {
            const Payload = @typeInfo(@TypeOf(ptr.*)).optional.child;
            var present: bool = if (dir == .save) ptr.* != null else undefined;
            try self.scalar(&present);
            var payload: Payload = if (dir == .save) (ptr.* orelse std.mem.zeroes(Payload)) else undefined;
            try self.scalar(&payload);
            if (dir == .load) ptr.* = if (present) payload else null;
        }

        fn bytes(self: *Self, slice: []u8) CodecError!void {
            const region = try self.take(slice.len);
            if (dir == .save) @memcpy(region, slice) else @memcpy(slice, region);
        }

        // -- header / section framing (each direction uses its own half) --

        fn header(self: *Self, rom_hash: RomHash, mapper_id: u8) CodecError!void {
            comptime std.debug.assert(dir == .save);
            @memcpy(try self.take(magic.len), &magic);
            var version = format_version;
            try self.scalar(&version);
            var id = mapper_id;
            try self.scalar(&id);
            @memset(try self.take(3), 0); // reserved; zeroed so the digest is stable
            var digest = rom_hash;
            try self.bytes(&digest);
        }

        fn readHeader(self: *Self) CodecError!Header {
            comptime std.debug.assert(dir == .load);
            const got = try self.take(magic.len);
            if (!std.mem.eql(u8, got, &magic)) return error.BadMagic;
            var version: u32 = undefined;
            try self.scalar(&version);
            if (version != format_version) return error.UnsupportedVersion;
            var mapper_id: u8 = undefined;
            try self.scalar(&mapper_id);
            _ = try self.take(3); // reserved
            var rom_hash: RomHash = undefined;
            try self.bytes(&rom_hash);
            return .{ .mapper_id = mapper_id, .rom_hash = rom_hash };
        }

        /// Writes `(id, placeholder length)` and returns where the length
        /// went, for `endSection` to backfill once the body's real size is
        /// known. Cheaper and simpler than measuring every section twice.
        fn beginSection(self: *Self, id: Section) CodecError!usize {
            comptime std.debug.assert(dir == .save);
            var raw_id: u16 = @intFromEnum(id);
            try self.scalar(&raw_id);
            const at = self.pos;
            var placeholder: u32 = 0;
            try self.scalar(&placeholder);
            return at;
        }

        fn endSection(self: *Self, length_at: usize) void {
            comptime std.debug.assert(dir == .save);
            const body_len: u32 = @intCast(self.pos - (length_at + @sizeOf(u32)));
            std.mem.writeInt(u32, self.buf[length_at..][0..4], body_len, .little);
        }

        fn sectionId(self: *Self) CodecError!Section {
            comptime std.debug.assert(dir == .load);
            var raw_id: u16 = undefined;
            try self.scalar(&raw_id);
            return @enumFromInt(raw_id);
        }

        fn sectionLen(self: *Self) CodecError!usize {
            comptime std.debug.assert(dir == .load);
            var len: u32 = undefined;
            try self.scalar(&len);
            return len;
        }
    };
}

// -------------------------------------------------------- section bodies

fn sectionBody(comptime dir: Dir, c: *Codec(dir), m: *Machine, comptime id: Section) CodecError!void {
    switch (id) {
        .cpu => try cpuBody(dir, c, &m.cpu),
        .wram => try c.bytes(&m.bus.wram),
        .sram => try sramBody(dir, c, m),
        .ppu => try ppuBody(dir, c, &m.bus.ppu),
        .apu => try apuBody(dir, c, &m.bus.apu),
        .controllers => for (&m.bus.controllers) |*ctrl| {
            try c.scalar(&ctrl.buttons);
            try c.scalar(&ctrl.shift);
            try c.scalar(&ctrl.strobe);
        },
        .mapper => try mapperBody(dir, c, &m.bus.mapper),
        .bus => try c.scalar(&m.bus.open_bus),
        else => unreachable,
    }
}

/// Cartridge PRG-RAM, length-prefixed rather than written whole.
///
/// ENG-79 sized `Bus.prg_ram` at a flat 32KB so the common access needs no
/// indirection, but only MMC1's SOROM/SXROM boards actually carry more than
/// 8KB -- every other cartridge here would otherwise contribute 24KB of
/// guaranteed zeroes to every save-state. Writing the size into the section
/// keeps a typical state near 20KB *and* keeps this section self-describing:
/// a reader recovers the length from the blob, not from mapper state
/// restored by a later section, so section order stays a layout detail
/// rather than a correctness dependency.
///
/// The read is clamped to the buffer, so a hand-edited size cannot walk past
/// it -- the same posture as `fromStorage`'s truncation.
fn sramBody(comptime dir: Dir, c: *Codec(dir), m: *Machine) CodecError!void {
    var size: u32 = @intCast(prgRamBytes(&m.bus.mapper));
    try c.scalar(&size);
    try c.bytes(m.bus.prg_ram[0..@min(@as(usize, size), m.bus.prg_ram.len)]);
}

/// How much of `Bus.prg_ram` this cartridge can actually address. Derived
/// here rather than added to `Mapper`'s interface: MMC1 is the only board
/// this core supports whose PRG-RAM is not a flat 8KB, and one `switch` is
/// a smaller change than a method every mapper has to answer.
pub fn prgRamBytes(m: *const mapper_mod.Mapper) usize {
    return switch (m.*) {
        .mmc1 => |*x| @max(x.prg_ram_size, 0x2000),
        else => 0x2000,
    };
}

/// `bus` is deliberately absent: it is a `*Bus` back-reference `Machine.init`
/// re-establishes, not state. `cycles` is present even though nothing in the
/// CPU's own behavior reads it -- MMC1 dates its consecutive-write rule off
/// it (`Mmc1.last_write_cycle`), so a resumed CPU whose clock jumped
/// backwards would mis-handle the next register write.
fn cpuBody(comptime dir: Dir, c: *Codec(dir), cpu: *cpu_mod.Cpu) CodecError!void {
    try c.scalar(&cpu.a);
    try c.scalar(&cpu.x);
    try c.scalar(&cpu.y);
    try c.scalar(&cpu.s);
    try c.scalar(&cpu.pc);
    try c.scalar(&cpu.p);
    try c.scalar(&cpu.cycles);
    // The interrupt latches ENG-61 calls out explicitly: interrupt timing
    // here is cycle-accurate *because* of these, so a state that restored
    // only the architectural registers would resume onto a different
    // interrupt schedule than the one it was saved from.
    try c.scalar(&cpu.nmi_line);
    try c.scalar(&cpu.nmi_pending);
    try c.scalar(&cpu.nmi_ready);
    try c.scalar(&cpu.irq_line);
    try c.scalar(&cpu.irq_ready);
    try c.scalar(&cpu.poll_i_override);
    try c.scalar(&cpu.jammed);
}

/// Everything a mid-scanline resume needs, per ENG-61 -- including the
/// background/sprite pipeline latches, which are re-derived within a
/// scanline but not *at* the dot a state resumes on. `framebuffer` is
/// excluded (see the module doc comment).
fn ppuBody(comptime dir: Dir, c: *Codec(dir), p: *ppu_mod.Ppu) CodecError!void {
    try c.scalar(&p.ctrl);
    try c.scalar(&p.mask);
    try c.scalar(&p.status);
    try c.scalar(&p.oam_addr);
    try c.scalar(&p.v);
    try c.scalar(&p.t);
    try c.scalar(&p.fine_x);
    try c.scalar(&p.w);
    try c.scalar(&p.read_buffer);
    try c.scalar(&p.data_bus);
    try c.scalar(&p.suppress_vbl_this_frame);
    // The one-dot PPUCTRL/PPUMASK write delay (`Ppu.applyPendingLatches`):
    // real in-flight state, and "nothing pending" has to survive as
    // something other than a pending write of $00.
    try c.scalar(&p.pending_ctrl);
    try c.scalar(&p.pending_mask);
    try c.scalar(&p.scanline);
    try c.scalar(&p.dot);
    try c.scalar(&p.frame);
    try c.bytes(&p.vram);
    try c.bytes(&p.palette);
    try c.bytes(&p.oam);
    try c.bytes(&p.secondary_oam);
    try c.scalar(&p.bg_next_tile_id);
    try c.scalar(&p.bg_next_tile_attr);
    try c.scalar(&p.bg_next_tile_lo);
    try c.scalar(&p.bg_next_tile_hi);
    try c.scalar(&p.bg_shift_pattern_lo);
    try c.scalar(&p.bg_shift_pattern_hi);
    try c.scalar(&p.bg_shift_attr_lo);
    try c.scalar(&p.bg_shift_attr_hi);
    try c.scalar(&p.sprite_count);
    try c.scalar(&p.secondary_count);
    try c.scalar(&p.secondary_has_sprite0);
    try c.scalar(&p.overflow_dot);
    // All eight units, not just the `sprite_count` live ones: a fixed-size
    // section is what keeps the wire layout a property of the field list
    // rather than of the machine's current contents, and the stale units
    // are as deterministic as the live ones.
    for (&p.sprite_units) |*su| {
        try c.scalar(&su.x);
        try c.scalar(&su.pattern_lo);
        try c.scalar(&su.pattern_hi);
        try c.scalar(&su.palette);
        try c.scalar(&su.behind_bg);
        try c.scalar(&su.is_sprite0);
    }
}

/// All five channels and the frame sequencer. The RC filter cascade and
/// `output_sample` are excluded -- see the module doc comment for why that
/// exclusion is deliberate and what it costs.
fn apuBody(comptime dir: Dir, c: *Codec(dir), a: *apu_mod.Apu) CodecError!void {
    try pulseBody(dir, c, &a.pulse1);
    try pulseBody(dir, c, &a.pulse2);

    try c.scalar(&a.triangle.enabled);
    try c.scalar(&a.triangle.length_counter);
    try c.scalar(&a.triangle.control_flag);
    try c.scalar(&a.triangle.timer_period);
    try c.scalar(&a.triangle.timer);
    try c.scalar(&a.triangle.sequence_pos);
    try c.scalar(&a.triangle.linear_counter);
    try c.scalar(&a.triangle.linear_reload_value);
    try c.scalar(&a.triangle.linear_reload_flag);

    try c.scalar(&a.noise.enabled);
    try c.scalar(&a.noise.length_counter);
    try envelopeBody(dir, c, &a.noise.envelope);
    try c.scalar(&a.noise.mode);
    try c.scalar(&a.noise.period_index);
    try c.scalar(&a.noise.timer);
    try c.scalar(&a.noise.shift_register);

    try c.scalar(&a.dmc.enabled);
    try c.scalar(&a.dmc.irq_enabled);
    try c.scalar(&a.dmc.loop);
    try c.scalar(&a.dmc.rate_index);
    try c.scalar(&a.dmc.timer);
    try c.scalar(&a.dmc.output_level);
    try c.scalar(&a.dmc.sample_address);
    try c.scalar(&a.dmc.sample_length);
    try c.scalar(&a.dmc.current_address);
    try c.scalar(&a.dmc.bytes_remaining);
    try c.scalar(&a.dmc.sample_buffer);
    try c.scalar(&a.dmc.shift_register);
    try c.scalar(&a.dmc.bits_remaining);
    try c.scalar(&a.dmc.silence);
    try c.scalar(&a.dmc.irq_flag);
    // ENG-81: the DMC's sample fetch is a CPU-halting DMA, so "a fetch has
    // been requested and not yet serviced" is real state. Saving mid-stall
    // and reloading must resume the stall, not drop the fetch.
    try c.scalar(&a.dmc.dma_pending);

    try c.scalar(&a.frame.mode);
    try c.scalar(&a.frame.irq_inhibit);
    try c.scalar(&a.frame.irq_flag);
    try c.scalar(&a.frame.cycle);
    try c.scalar(&a.frame.reset_delay);
    try c.scalar(&a.frame.irq_reassert_remaining);
    try c.scalar(&a.frame.half_frame_pending);
    // Only ever consulted for its parity (which `cycle` moves in lockstep
    // with), so `determinism.zig` used to skip it. A save-state is not a
    // digest, though: this is real state, it costs 8 bytes, and restoring
    // it means the next `$4017` write lands on the same parity it would
    // have without the save.
    try c.scalar(&a.frame.total_cycles);
    try c.scalar(&a.even_cycle);
}

fn pulseBody(comptime dir: Dir, c: *Codec(dir), p: *apu_mod.Pulse) CodecError!void {
    // `is_pulse1` is not written: it is wiring (which sweep-negate behavior
    // this channel has), fixed at construction, not state.
    try c.scalar(&p.enabled);
    try c.scalar(&p.length_counter);
    try c.scalar(&p.duty);
    try c.scalar(&p.sequence_pos);
    try envelopeBody(dir, c, &p.envelope);
    try c.scalar(&p.timer_period);
    try c.scalar(&p.timer);
    // The whole sweep unit: shift/negate/period decide the *next* target
    // period, so a state missing them resumes onto a different pitch slide.
    try c.scalar(&p.sweep_enabled);
    try c.scalar(&p.sweep_period);
    try c.scalar(&p.sweep_negate);
    try c.scalar(&p.sweep_shift);
    try c.scalar(&p.sweep_divider);
    try c.scalar(&p.sweep_reload);
}

fn envelopeBody(comptime dir: Dir, c: *Codec(dir), e: *apu_mod.Envelope) CodecError!void {
    try c.scalar(&e.start);
    try c.scalar(&e.loop_flag);
    try c.scalar(&e.constant_volume);
    try c.scalar(&e.volume_or_period);
    try c.scalar(&e.divider);
    try c.scalar(&e.decay);
}

/// ENG-61's opaque per-mapper section: each arm defines its own layout, and
/// the header's mapper id (checked before any of this runs) is what makes
/// that safe. CHR is written only where the cartridge's CHR is *RAM* --
/// CHR-ROM comes back from the ROM file, per the module doc comment.
fn mapperBody(comptime dir: Dir, c: *Codec(dir), m: *mapper_mod.Mapper) CodecError!void {
    switch (m.*) {
        .nrom => |*n| if (n.chr_is_ram) try c.bytes(&n.chr),
        .mmc1 => |*x| {
            if (x.chr_rom.len == 0) try c.bytes(&x.chr_ram);
            try c.scalar(&x.shift);
            try c.scalar(&x.control);
            try c.scalar(&x.chr_bank0);
            try c.scalar(&x.chr_bank1);
            try c.scalar(&x.prg_bank);
            // A half-completed 5-write sequence and the consecutive-write
            // rule's memory of the last write both survive into the next
            // instruction, so both are part of the state.
            try c.scalar(&x.cycle);
            try c.scalar(&x.last_write_cycle);
            // ENG-79: how much PRG-RAM this board carries decides how
            // `prgRamMap` banks $6000-$7FFF, so it is addressing state, not
            // geometry the re-boot can be trusted to restore identically.
            //
            // Mirrored through a fixed `u32` rather than written as the
            // `usize` it is: `usize` is 32-bit on wasm32 and 64-bit
            // natively, so serializing it directly would give the same
            // machine two different blob layouts -- and two different
            // determinism digests -- depending on the target. Assigning the
            // mirror back is a no-op when saving and the actual restore when
            // loading, which is what keeps this one field list serving both
            // directions.
            var prg_ram_size: u32 = @intCast(x.prg_ram_size);
            try c.scalar(&prg_ram_size);
            x.prg_ram_size = prg_ram_size;
        },
        .mmc3 => |*x| {
            if (x.chr_rom.len == 0) try c.bytes(&x.chr_ram);
            try c.bytes(&x.bank_data);
            try c.scalar(&x.bank_select);
            try c.scalar(&x.mirror_horizontal);
            try c.scalar(&x.irq_latch);
            try c.scalar(&x.irq_counter);
            try c.scalar(&x.irq_reload_pending);
            try c.scalar(&x.irq_enabled);
            try c.scalar(&x.irq_pending);
            // A12 and its low-time filter: the scanline IRQ's phase lives
            // here, not just in the counter (ADR 0004).
            try c.scalar(&x.a12);
            try c.scalar(&x.a12_low_ticks);
            // ENG-79: MMC3's $A001 bit 6. A restored cartridge whose RAM is
            // write-protected must stay protected, or the game's next save
            // write silently succeeds where the hardware would drop it.
            try c.scalar(&x.prg_ram_write_protect);
        },
        .uxrom => |*x| {
            try c.bytes(&x.chr_ram); // UxROM boards are always CHR-RAM
            try c.scalar(&x.prg_bank);
        },
        .cnrom => |*x| try c.scalar(&x.chr_bank),
        // Never reachable from a real ROM (see `mapperId`); an empty body
        // rather than `unreachable` so a CPU-test machine can still be
        // hashed by `determinism.zig`.
        .test_stub => {},
    }
}

// ------------------------------------------------------------------ tests

fn minimalNromBuf() [16 + 0x4000]u8 {
    var buf = [_]u8{0} ** (16 + 0x4000);
    buf[0] = 'N';
    buf[1] = 'E';
    buf[2] = 'S';
    buf[3] = 0x1A;
    buf[4] = 1; // 16KB PRG
    buf[5] = 0; // CHR-RAM
    buf[16 + 0x3FFC] = 0x00;
    buf[16 + 0x3FFD] = 0x80; // reset vector -> $8000, an infinite NOP sled
    return buf;
}

test "a saved state round-trips into an identical machine" {
    const rom = minimalNromBuf();
    var scratch: [max_state_bytes]u8 = undefined;
    var blob: [max_state_bytes]u8 = undefined;

    var source: Machine = undefined;
    try source.init(&rom);
    while (source.cpu.cycles < 20_000) source.cpu.step();
    const n = try save(&source, romHash(&rom), &blob);
    const expected = try hash(&source, &scratch);

    // A *differently aged* machine, so a field the codec forgot to restore
    // shows up as a digest mismatch rather than being masked by both sides
    // already agreeing.
    var target: Machine = undefined;
    try target.init(&rom);
    while (target.cpu.cycles < 5_000) target.cpu.step();
    try testing.expect(!std.mem.eql(u8, &expected, &(try hash(&target, &scratch))));

    try load(&target, &rom, blob[0..n]);
    try testing.expectEqualSlices(u8, &expected, &(try hash(&target, &scratch)));
}

test "a restored machine keeps producing the same cycles as the one it was saved from" {
    const rom = minimalNromBuf();
    var scratch: [max_state_bytes]u8 = undefined;
    var blob: [max_state_bytes]u8 = undefined;

    var source: Machine = undefined;
    try source.init(&rom);
    while (source.cpu.cycles < 20_000) source.cpu.step();
    const n = try save(&source, romHash(&rom), &blob);

    var target: Machine = undefined;
    try target.init(&rom);
    try load(&target, &rom, blob[0..n]);

    // Round-tripping proves the bytes match *now*; running both on proves
    // the state is complete enough to keep matching, which is the property
    // a save-state actually promises.
    source.runFrames(2);
    target.runFrames(2);
    try testing.expectEqualSlices(u8, &(try hash(&source, &scratch)), &(try hash(&target, &scratch)));
}

test "the header records the format's magic, version and mapper id" {
    const rom = minimalNromBuf();
    var blob: [max_state_bytes]u8 = undefined;
    var m: Machine = undefined;
    try m.init(&rom);

    const n = try save(&m, romHash(&rom), &blob);
    try testing.expect(n > header_bytes);
    try testing.expectEqualSlices(u8, &magic, blob[0..4]);
    try testing.expectEqual(format_version, std.mem.readInt(u32, blob[4..8], .little));
    try testing.expectEqual(@as(u8, 0), blob[8]); // NROM
    try testing.expectEqualSlices(u8, &romHash(&rom), blob[12..44]);
}

test "loading rejects a corrupt magic, an unknown version, and a truncated blob" {
    const rom = minimalNromBuf();
    var blob: [max_state_bytes]u8 = undefined;
    var m: Machine = undefined;
    try m.init(&rom);
    const n = try save(&m, romHash(&rom), &blob);

    var bad_magic = blob;
    bad_magic[1] = 'X';
    try testing.expectError(error.BadMagic, load(&m, &rom, bad_magic[0..n]));

    var bad_version = blob;
    std.mem.writeInt(u32, bad_version[4..8], format_version + 1, .little);
    try testing.expectError(error.UnsupportedVersion, load(&m, &rom, bad_version[0..n]));

    try testing.expectError(error.Truncated, load(&m, &rom, blob[0 .. n - 1]));
}

test "loading a state saved against a different ROM is rejected, not silently applied" {
    const rom = minimalNromBuf();
    var other = minimalNromBuf();
    other[16] = 0xEA; // one different PRG byte -> a different hash

    var blob: [max_state_bytes]u8 = undefined;
    var m: Machine = undefined;
    try m.init(&rom);
    const n = try save(&m, romHash(&rom), &blob);

    var target: Machine = undefined;
    try target.init(&other);
    try testing.expectError(error.RomMismatch, load(&target, &other, blob[0..n]));
}

test "loading a state saved under a different mapper is rejected" {
    const rom = minimalNromBuf();
    var blob: [max_state_bytes]u8 = undefined;
    var m: Machine = undefined;
    try m.init(&rom);
    const n = try save(&m, romHash(&rom), &blob);

    blob[8] = 4; // claim MMC3 while the loaded ROM is NROM
    try testing.expectError(error.MapperMismatch, load(&m, &rom, blob[0..n]));
}

test "an unrecognized section is skipped, leaving that component at its power-on default" {
    const rom = minimalNromBuf();
    var m: Machine = undefined;
    try m.init(&rom);
    while (m.cpu.cycles < 5_000) m.cpu.step();

    var blob: [max_state_bytes]u8 = undefined;
    const n = try save(&m, romHash(&rom), &blob);
    // Renumber the CPU section to an id no reader knows. Everything after
    // it must still load, and the CPU must come back at power-on state.
    try testing.expectEqual(@intFromEnum(Section.cpu), std.mem.readInt(u16, blob[header_bytes..][0..2], .little));
    std.mem.writeInt(u16, blob[header_bytes..][0..2], 0xBEEF, .little);

    var target: Machine = undefined;
    try target.init(&rom);
    var fresh: Machine = undefined;
    try fresh.init(&rom);

    try load(&target, &rom, blob[0..n]);
    try testing.expectEqual(fresh.cpu.pc, target.cpu.pc);
    // `Machine.init` resets the CPU, which costs 7 cycles -- so "power-on
    // default" here is `fresh`'s clock, not zero.
    try testing.expectEqual(fresh.cpu.cycles, target.cpu.cycles);
    try testing.expect(target.cpu.cycles != m.cpu.cycles);
    // ...while a section the reader *does* know still applied.
    try testing.expectEqual(m.bus.ppu.frame, target.bus.ppu.frame);
}

test "save reports NoSpace rather than overrunning a short buffer" {
    const rom = minimalNromBuf();
    var m: Machine = undefined;
    try m.init(&rom);
    var tiny: [64]u8 = undefined;
    try testing.expectError(error.NoSpace, save(&m, romHash(&rom), &tiny));
}

// ENG-61 estimated "well under 20 KB with this layout" when it chose
// IndexedDB over `localStorage`. The real figure for the worst case this
// core can produce is a little *over* that -- 8KB SRAM and 8KB CHR-RAM on
// the same cartridge, plus 2KB WRAM and 2KB VRAM, is already 20KB before
// anything else -- so the bound asserted here is what the format actually
// costs rather than the estimate it was sized against. It changes nothing
// about that decision: the reasons for IndexedDB were asynchrony and binary
// storage, "regardless of any single state's actual size".
test "a state stays within a slot budget IndexedDB is comfortable with" {
    const rom = minimalNromBuf();
    var blob: [max_state_bytes]u8 = undefined;
    var m: Machine = undefined;
    try m.init(&rom);
    const n = try save(&m, romHash(&rom), &blob);
    try testing.expect(n < 24 * 1024);
}
