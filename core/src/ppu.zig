const std = @import("std");
const testing = std.testing;

const rom_mod = @import("rom.zig");
const mapper_mod = @import("mapper.zig");
const Mapper = mapper_mod.Mapper;
const Nrom = mapper_mod.Nrom;
const Mirroring = rom_mod.Mirroring;

/// $2000 PPUCTRL. Write-only on real hardware; reads of it (and every other
/// write-only register) return the PPU's internal data-bus latch, not these
/// fields -- see `Ppu.data_bus`.
///
/// Field order is bit0->bit7, exactly like `cpu.Flags`, so this declaration
/// order *is* the "VPHB SINN" hardware bit order read right-to-left.
pub const Ctrl = packed struct(u8) {
    nametable: u2 = 0,
    increment32: bool = false,
    sprite_table: bool = false,
    bg_table: bool = false,
    sprite_height16: bool = false,
    /// PPU master/slave select. Meaningless on a stock NES (no second PPU to
    /// arbitrate with) and not read anywhere in this milestone; kept only so
    /// a byte written to $2000 round-trips through the data-bus latch bit
    /// for bit-exact.
    master_slave: bool = false,
    nmi_enable: bool = false,
};

/// $2001 PPUMASK. "BGRs bMmG" bit order.
pub const Mask = packed struct(u8) {
    greyscale: bool = false,
    show_bg_left: bool = false,
    show_sprites_left: bool = false,
    show_bg: bool = false,
    show_sprites: bool = false,
    emphasize_red: bool = false,
    emphasize_green: bool = false,
    emphasize_blue: bool = false,
};

/// $2002 PPUSTATUS. Bits 4-0 are not physical flip-flops -- a read returns
/// whatever was last latched onto the PPU's internal data bus in those
/// positions (`Ppu.data_bus`), which is why `Status` itself only models the
/// three real bits.
pub const Status = packed struct(u8) {
    unused: u5 = 0,
    sprite_overflow: bool = false,
    sprite0_hit: bool = false,
    vblank: bool = false,

    pub fn toByte(self: Status) u8 {
        return @bitCast(self);
    }
};

/// Fold a raw $3F00-$3FFF palette address into its 32-byte storage index,
/// applying the well-known "background color" mirror: $3F10/$14/$18/$1C
/// alias $3F00/$04/$08/$0C (sprite palette 0's backdrop entries aren't
/// separate storage -- there is only one universal background color).
fn paletteIndex(addr: u16) u5 {
    var a: u16 = addr & 0x1F;
    if (a >= 0x10 and (a & 0x03) == 0) a -= 0x10;
    return @intCast(a);
}

/// Map one of the four *logical* 1KB nametables ($2000/$2400/$2800/$2C00,
/// `logical` = 0-3) onto one of the console's two *physical* 1KB VRAM banks,
/// per the cartridge's mirroring wiring. See
/// https://www.nesdev.org/wiki/Mirroring -- horizontal mirroring ties the
/// two nametables in each row together (0=0,1=0,2=1,3=1: A11 selects),
/// vertical ties each column together (0=0,1=1,2=0,3=1: A10 selects).
///
/// `four_screen` implies a cartridge-supplied extra 2KB VRAM chip wired to a
/// mapper pin this milestone's `Mapper` interface has no entry point for
/// (the same class of gap `bus.zig` documents for $6000-$7FFF PRG-RAM: a
/// real feature with no home in the M0-era interface, not an oversight).
/// NROM cartridges essentially never set the four-screen header bit, so this
/// degrades to vertical mirroring -- a named, deliberate fallback rather
/// than a silent mishandling. TODO(M7 or later): give `Mapper` a hook for
/// cartridge-supplied nametable VRAM and route four_screen through it.
fn physicalNametable(mirroring: Mirroring, logical: u2) u1 {
    return switch (mirroring) {
        .horizontal => @intCast(logical >> 1),
        .vertical, .four_screen => @intCast(logical & 1),
    };
}

/// One fetched, screen-ready sprite for the scanline currently being drawn.
/// Deliberately *not* a shift register the way the background pipeline's
/// `bg_shift_pattern_lo`/`hi` are: since evaluation+fetch already happen in
/// one shot at dot 1 (see `Ppu`'s type doc comment), `x` just stays a plain
/// static column and `outputPixel` computes `col - x` directly each dot,
/// which is behaviorally identical to shifting for a value nothing re-reads
/// mid-scanline.
const SpriteUnit = struct {
    /// Screen column of the sprite's leftmost pixel.
    x: u8 = 0,
    /// This sprite's two pattern-table bitplanes for the current scanline's
    /// row through it, already bit-reversed at fetch time if the
    /// horizontal-flip attribute bit was set -- see `fetchSpriteUnits`.
    pattern_lo: u8 = 0,
    pattern_hi: u8 = 0,
    /// Which of the 4 sprite palettes ($3F10/$14/$18/$1C-relative) this
    /// sprite's pixel values 1-3 resolve through.
    palette: u2 = 0,
    /// OAM attribute byte bit 5: true = this sprite draws *behind* opaque
    /// background pixels rather than in front of them. Does not affect
    /// sprite-0 hit, which fires regardless of priority (see
    /// `outputPixel`).
    behind_bg: bool = false,
    /// Whether this unit is OAM's own index-0 sprite (see `sprite0_in_range`
    /// on `Ppu`).
    is_sprite0: bool = false,
};

/// Reverse the bit order of one byte -- used to pre-flip a horizontally-
/// flipped sprite's fetched pattern bytes once, at fetch time, rather than
/// making `outputPixel` branch on the flip attribute for every pixel.
fn reverseBits(b: u8) u8 {
    var result: u8 = 0;
    var v: u8 = b;
    var i: u8 = 0;
    while (i < 8) : (i += 1) {
        result <<= 1;
        result |= (v & 1);
        v >>= 1;
    }
    return result;
}

/// The 2C02 PPU: registers, VRAM/OAM/palette storage, the dot/scanline
/// timing state machine, and the background tile+attribute pipeline plus
/// (ENG-68/M3) sprite evaluation, priority muxing, sprite-0 hit, and the
/// sprite-overflow flag (including its documented hardware bug).
///
/// **Sprite evaluation is dot-collapsed, unlike the background pipeline.**
/// Real hardware spreads this across three phases -- clear secondary OAM
/// (dots 1-64), evaluate up to 8 in-range sprites plus the overflow-bug scan
/// (dots 65-256), fetch each found sprite's pattern bytes (dots 257-320) --
/// each gated by the *previous* scanline's evaluation feeding the *next*
/// scanline's sprite render units. `evaluateSprites`/`fetchSpriteUnits`
/// instead do all of this in one shot at dot 1 of the scanline being drawn,
/// directly for that same scanline (no one-scanline lookahead). This is a
/// deliberately coarser approximation than `renderCycle`'s still-8-dot-
/// accurate background fetches: unlike CHR-bus fetch timing (which MMC3's
/// scanline counter, M7, will care about), sprite evaluation's *dot-level*
/// timing has no effect any NROM game or this milestone's conformance
/// suites depend on for correctness of *what* gets drawn -- only the
/// overflow flag's *cycle-of-the-frame* timing does, which is exactly where
/// `sprite_overflow_tests/3.Timing` is expected to show this gap (see that
/// test's call site in `ppu_sprites_test.zig`).
///
/// **Why evaluation also runs for `scanline == 240`.** A sprite with OAM
/// Y=239 first becomes visible on screen row 240 (see `evaluateSprites`'s
/// "+1" derivation) -- a row that is never drawn (only 0-239 call
/// `outputPixel`), but real hardware still runs that sprite through
/// evaluation (during scanline 239's own dots 65-256, one scanline ahead of
/// this codebase's collapsed model) and *can* set the overflow flag from
/// it. `sprite_overflow_tests/2.Details` checks exactly this ("Y=239
/// should set overflow, Y=240/255 should not"), so evaluation runs for
/// `scanline` 0 through 240 inclusive even though only 0-239 ever produce a
/// pixel.
///
/// **Driven entirely by `tick`.** Every PPU dot -- background fetch, shift,
/// pixel output, VBL edge, the odd-frame skip, and now sprite evaluation --
/// happens inside `tick`, called exactly 3 times per CPU cycle from
/// `Cpu.tick`'s chokepoint. There is no other path that advances PPU state,
/// mirroring the CPU core's own single-chokepoint discipline.
pub const Ppu = struct {
    ctrl: Ctrl = .{},
    mask: Mask = .{},
    status: Status = .{},
    oam_addr: u8 = 0,

    /// Loopy's scroll model: `v` is the address the PPU is currently
    /// fetching through (and the scroll position, outside rendering); `t`
    /// is the staging register writes land in; `x` is fine-X (not part of
    /// the 15-bit address); `w` is the shared write-toggle for $2005/$2006.
    /// See https://www.nesdev.org/wiki/PPU_scrolling for the bit layout and
    /// every algorithm below (`incrementCoarseX`, `incrementY`,
    /// `transferAddressX`, `transferAddressY`) -- transcribed directly from
    /// its pseudocode.
    v: u15 = 0,
    t: u15 = 0,
    fine_x: u3 = 0,
    w: bool = false,

    /// PPUDATA's one-read-deep prefetch buffer. Palette reads bypass it
    /// (see `readRegister`), but still refresh it from the nametable byte
    /// that sits "underneath" the palette mirror, per hardware.
    read_buffer: u8 = 0,

    /// The PPU's own internal data-bus latch: the last byte driven onto the
    /// 8-bit CPU<->PPU data bus by *any* register access, read or write.
    /// This is what a read of a write-only register (or PPUSTATUS's bottom
    /// 5 bits) actually returns -- not a stored "value", since none of
    /// those registers have read-back storage on real hardware. Modeled
    /// with no time decay, the same deliberate simplification `Bus.open_bus`
    /// already makes for the CPU-side latch.
    data_bus: u8 = 0,

    /// 2KB of console-side nametable VRAM, addressed through
    /// `physicalNametable`'s mirroring math -- NROM carts add no VRAM of
    /// their own, so this is *all* the nametable storage that exists.
    vram: [0x0800]u8 = [_]u8{0} ** 0x0800,
    /// 32 bytes, background+sprite palettes; see `paletteIndex` for the
    /// $3F10-family mirror.
    palette: [0x20]u8 = [_]u8{0} ** 0x20,
    oam: [256]u8 = [_]u8{0} ** 256,
    /// Up to 8 sprites (4 bytes each) found in range for the scanline
    /// currently being evaluated. Filled by `evaluateSprites`, consumed by
    /// `fetchSpriteUnits`.
    secondary_oam: [32]u8 = [_]u8{0} ** 32,
    /// How many of `secondary_oam`'s 8 slots (and `sprite_units`) hold a
    /// real sprite for the scanline currently being drawn -- `outputPixel`
    /// only ever looks at `sprite_units[0..sprite_count]`.
    sprite_count: u8 = 0,
    /// Whether OAM index 0 was one of the sprites found this scanline.
    /// Original-OAM-index-0, if present, is always copied into
    /// `secondary_oam` slot 0 first (evaluation scans OAM in ascending
    /// index order) -- so `sprite_units[0].is_sprite0` is equivalent to
    /// this flag, kept as its own field only for readability at the one
    /// call site (`evaluateSprites`) that sets it.
    sprite0_in_range: bool = false,
    /// One fetched, ready-to-mux render unit per sprite in `secondary_oam`,
    /// same order (ascending original OAM index = display priority, highest
    /// first). Pattern bytes are already flipped horizontally at fetch time
    /// (see `fetchSpriteUnits`), so `outputPixel` never branches on the
    /// flip-X attribute bit itself.
    sprite_units: [8]SpriteUnit = [_]SpriteUnit{.{}} ** 8,

    mirroring: Mirroring,

    // ------------------------------------------------------- dot/scanline
    /// 0-261; 0-239 visible, 240 idle ("post-render"), 241-260 vblank, 261
    /// pre-render (fills the shifters for scanline 0 exactly like a visible
    /// scanline does, but writes no pixels).
    scanline: u16 = 0,
    /// 0-340.
    dot: u16 = 0,
    /// Frames completed since power-on/construction. Only its parity
    /// matters (the odd-frame dot skip); kept as a full counter because
    /// that parity check reads more clearly as `frame % 2` than as a
    /// hand-rolled bool that some other path could forget to flip.
    frame: u64 = 0,
    /// See `readRegister`'s $2002 case: latched by a status read that lands
    /// exactly one PPU clock before the VBL flag would be set, and consumed
    /// (whether true or not) the instant that dot is reached.
    suppress_vbl_this_frame: bool = false,

    /// A written-but-not-yet-latched PPUCTRL/PPUMASK byte. See
    /// `applyPendingLatches`: the PPU picks these two control registers up
    /// one dot after the CPU's write cycle ends, which is what
    /// `ppu_vbl_nmi/07-nmi_on_timing` and `/10-even_odd_timing` measure.
    pending_ctrl: ?u8 = null,
    pending_mask: ?u8 = null,

    // ------------------------------------------------------ bg pipeline
    // "next" latches hold data already fetched, awaiting the next reload;
    // "shift" registers are what pixels are actually read out of. Loading
    // only ever touches the low byte -- the high byte is mid-shift-out data
    // from the *previous* tile, which is exactly what gives the pipeline
    // its one-tile lookahead (the pre-render line's dots 321-336 prime it
    // with the first two tiles of scanline 0 before any pixel is output).
    bg_next_tile_id: u8 = 0,
    bg_next_tile_attr: u8 = 0,
    bg_next_tile_lo: u8 = 0,
    bg_next_tile_hi: u8 = 0,
    bg_shift_pattern_lo: u16 = 0,
    bg_shift_pattern_hi: u16 = 0,
    bg_shift_attr_lo: u16 = 0,
    bg_shift_attr_hi: u16 = 0,

    /// One entry per pixel, row-major, holding a 6-bit NES palette index
    /// (0-63) -- not an RGB color. Turning that index into a displayable
    /// color is a delivery-layer concern (M4+); what this milestone commits
    /// to is that the *index* is the one the background pipeline decoded.
    framebuffer: [256 * 240]u8 = [_]u8{0} ** (256 * 240),

    pub fn init(mirroring: Mirroring) Ppu {
        return .{ .mirroring = mirroring };
    }

    /// What survives a CPU /RESET vs. what a fresh `Ppu.init` gives you.
    /// Per https://www.nesdev.org/wiki/PPU_power_up_state: PPUCTRL, PPUMASK,
    /// the $2005/$2006 write toggle, and the PPUDATA read buffer are
    /// cleared; PPUSTATUS (the VBL flag included), OAMADDR, OAM, VRAM, and
    /// palette RAM survive untouched. The same page is explicit that `t`
    /// (the "VRAM address latch") and fine X *also* clear -- only `v` (the
    /// actual current VRAM address) survives -- so PPUSCROLL/PPUADDR's
    /// pending-write state resets right along with the toggle that gates it.
    pub fn reset(self: *Ppu) void {
        self.ctrl = .{};
        self.mask = .{};
        self.pending_ctrl = null;
        self.pending_mask = null;
        self.w = false;
        self.read_buffer = 0;
        self.t = 0;
        self.fine_x = 0;
    }

    pub fn nmiSignal(self: *const Ppu) bool {
        return self.status.vblank and self.ctrl.nmi_enable;
    }

    fn renderingEnabled(self: *const Ppu) bool {
        return self.mask.show_bg or self.mask.show_sprites;
    }

    /// Latch any pending PPUCTRL/PPUMASK write into the live registers.
    ///
    /// **Why these two registers land a dot late.** A CPU write completes at
    /// the end of its own CPU cycle -- after the third of that cycle's three
    /// PPU dots -- but the byte is not visible to the PPU logic that reads
    /// it back as a *level* (the NMI output; the rendering-enabled input to
    /// `advanceDot`'s odd-frame skip) until a dot later, the 2C02 having
    /// sampled the CPU-facing write on its own next clock edge. Called at
    /// the end of every `tick`, so a write landing at the end of CPU cycle N
    /// is live from the *second* dot of cycle N+1 onward, and from that
    /// cycle's own mid-`tick` NMI poll.
    ///
    /// The one-dot figure is what four of Blargg's NMI/timing sub-tests
    /// agree on, not a datasheet number: it was found by sweeping the
    /// write's effective position across every dot offset from -3 to +3 and
    /// keeping the only one at which `04`, `05`, `06`, `07`, `08` and `10`
    /// are simultaneously green. Every other offset breaks at least one of
    /// them, which is the strongest evidence available without silicon.
    ///
    /// This is the single dot that separates `ppu_vbl_nmi/07-nmi_on_timing`
    /// (a $2000 write racing the VBL flag's clear) and `/10-even_odd_timing`
    /// (a $2001 write racing the odd-frame dot skip) from passing: both were
    /// documented, asserted gaps through M2/M3 precisely because the write
    /// used to become visible a dot too early. Deliberately scoped to these
    /// two registers rather than every PPU write: they are the only ones the
    /// PPU re-reads as a *level* on later dots, and deferring the rest would
    /// desynchronize the register file from `Bus`'s own immediate writes
    /// (OAMDMA's $2004 stream, $2007's VRAM writes) for no modeled gain.
    fn applyPendingLatches(self: *Ppu) void {
        if (self.pending_ctrl) |v| {
            self.ctrl = @bitCast(v);
            self.pending_ctrl = null;
        }
        if (self.pending_mask) |v| {
            self.mask = @bitCast(v);
            self.pending_mask = null;
        }
    }

    /// OAMDATA ($2004) read value. Normally just the byte at OAMADDR, but
    /// real hardware exposes its internal sprite-evaluation machinery
    /// during dots 1-64 of a rendering scanline: that's the "clear
    /// secondary OAM to $FF" phase (see `evaluateSprites`'s doc comment --
    /// collapsed to a single dot-1 pass in this codebase, but the *value a
    /// read would see* during hardware's real dots 1-64 window is still
    /// worth modeling on its own, since `oam_stress` exercises exactly
    /// this), so a read landing there always returns $FF regardless of
    /// OAMADDR. See https://www.nesdev.org/wiki/PPU_sprite_evaluation.
    fn oamDataRead(self: *const Ppu) u8 {
        const on_render_line = self.scanline <= 239 or self.scanline == 261;
        if (self.renderingEnabled() and on_render_line and self.dot >= 1 and self.dot <= 64) {
            return 0xFF;
        }
        return self.oam[self.oam_addr];
    }

    // ------------------------------------------------------------- memory

    fn vramAddress(self: *const Ppu, addr: u16) u11 {
        // $3000-$3EFF mirrors $2000-$2EFF before the per-cartridge mirroring
        // math ever sees it.
        const folded: u16 = if (addr >= 0x3000) addr - 0x1000 else addr;
        const offset: u16 = folded & 0x0FFF;
        const logical: u2 = @intCast(offset >> 10);
        const physical: u1 = physicalNametable(self.mirroring, logical);
        return (@as(u11, physical) << 10) | @as(u11, @intCast(offset & 0x03FF));
    }

    fn vramRead(self: *const Ppu, addr: u16, mapper: *const Mapper) u8 {
        const a = addr & 0x3FFF;
        return switch (a) {
            0x0000...0x1FFF => mapper.chrRead(a),
            0x2000...0x3EFF => self.vram[self.vramAddress(a)],
            0x3F00...0x3FFF => self.palette[paletteIndex(a)],
            else => unreachable,
        };
    }

    fn vramWrite(self: *Ppu, addr: u16, value: u8, mapper: *Mapper) void {
        const a = addr & 0x3FFF;
        switch (a) {
            0x0000...0x1FFF => mapper.chrWrite(a, value),
            0x2000...0x3EFF => self.vram[self.vramAddress(a)] = value,
            0x3F00...0x3FFF => self.palette[paletteIndex(a)] = value,
            else => unreachable,
        }
    }

    fn incrementV(self: *Ppu) void {
        self.v +%= if (self.ctrl.increment32) @as(u15, 32) else @as(u15, 1);
    }

    // --------------------------------------------------------- registers

    /// `addr` must already be folded to $2000-$2007 (the mirroring-every-8
    /// step is `Bus`'s job, exactly like it masks WRAM's mirrors).
    pub fn readRegister(self: *Ppu, addr: u16, mapper: *Mapper) u8 {
        var result: u8 = self.data_bus;
        switch (addr) {
            0x2002 => {
                result = (self.status.toByte() & 0xE0) | (self.data_bus & 0x1F);
                // Race condition around the exact dot the VBL flag is set
                // (scanline 241, dot 1). A read landing one PPU clock
                // *before* that dot suppresses the flag for the rest of
                // this vblank entirely (handled here, before it would ever
                // be set); a read on the same dot or one after reads it as
                // already set and clears it in the same PPU cycle it was
                // set, which starves the CPU's NMI edge-detector of ever
                // observing it high (handled implicitly: `Cpu` re-polls
                // `nmiSignal` only *after* this access completes). See
                // https://www.nesdev.org/wiki/PPU_frame_timing's "NMI and
                // the VBL flag" timing table.
                if (self.scanline == 241 and self.dot == 1) {
                    self.suppress_vbl_this_frame = true;
                }
                self.status.vblank = false;
                self.w = false;
            },
            0x2004 => result = self.oamDataRead(),
            0x2007 => {
                const a = self.v & 0x3FFF;
                if (a >= 0x3F00) {
                    result = self.palette[paletteIndex(a)];
                    // Still refresh the buffer, from the nametable byte
                    // that the palette mirror sits on top of.
                    self.read_buffer = self.vramRead(a - 0x1000, mapper);
                } else {
                    result = self.read_buffer;
                    self.read_buffer = self.vramRead(a, mapper);
                }
                self.incrementV();
            },
            // $2000/$2001/$2003/$2005/$2006 are write-only: reading them
            // returns whatever is already latched, i.e. `result` as
            // initialized above.
            else => {},
        }
        self.data_bus = result;
        return result;
    }

    /// Side-effect-free counterpart to `readRegister`, for `Bus.peek`.
    /// Never clears the VBL flag, never tickles the write-toggle, never
    /// advances the read buffer, and never mutates `data_bus`.
    pub fn peekRegister(self: *const Ppu, addr: u16) u8 {
        return switch (addr) {
            0x2002 => (self.status.toByte() & 0xE0) | (self.data_bus & 0x1F),
            0x2004 => self.oamDataRead(),
            0x2007 => if ((self.v & 0x3FFF) >= 0x3F00)
                self.palette[paletteIndex(self.v)]
            else
                self.read_buffer,
            else => self.data_bus,
        };
    }

    pub fn writeRegister(self: *Ppu, addr: u16, value: u8, mapper: *Mapper) void {
        self.data_bus = value;
        switch (addr) {
            0x2000 => {
                // The control-bit latch is deferred by one dot (see
                // `applyPendingLatches`); `t`'s nametable-select bits are
                // not -- they are part of the scroll address latch, on the
                // PPU's CPU-facing side, and take the *written* value
                // directly rather than reading back through `ctrl`.
                self.applyPendingLatches();
                self.pending_ctrl = value;
                self.t = (self.t & ~@as(u15, 0x0C00)) | (@as(u15, @as(u2, @truncate(value))) << 10);
            },
            0x2001 => {
                self.applyPendingLatches();
                self.pending_mask = value;
            },
            0x2002 => {}, // read-only; the data-bus latch update above is all that happens
            0x2003 => self.oam_addr = value,
            0x2004 => {
                self.oam[self.oam_addr] = value;
                self.oam_addr +%= 1;
            },
            0x2005 => {
                if (!self.w) {
                    self.fine_x = @intCast(value & 0x07);
                    self.t = (self.t & ~@as(u15, 0x001F)) | (value >> 3);
                } else {
                    self.t = (self.t & ~@as(u15, 0x73E0)) |
                        (@as(u15, value & 0x07) << 12) |
                        (@as(u15, value >> 3) << 5);
                }
                self.w = !self.w;
            },
            0x2006 => {
                if (!self.w) {
                    self.t = (self.t & 0x00FF) | (@as(u15, value & 0x3F) << 8);
                } else {
                    self.t = (self.t & 0x7F00) | value;
                    self.v = self.t;
                }
                self.w = !self.w;
            },
            0x2007 => {
                self.vramWrite(self.v & 0x3FFF, value, mapper);
                self.incrementV();
            },
            else => unreachable,
        }
    }

    // --------------------------------------------------- scroll algorithms
    // Transcribed from https://www.nesdev.org/wiki/PPU_scrolling's
    // pseudocode; see the `v`/`t` doc comment above for the bit layout.

    fn incrementCoarseX(self: *Ppu) void {
        if ((self.v & 0x001F) == 31) {
            self.v &= ~@as(u15, 0x001F);
            self.v ^= 0x0400;
        } else {
            self.v += 1;
        }
    }

    fn incrementY(self: *Ppu) void {
        if ((self.v & 0x7000) != 0x7000) {
            self.v += 0x1000;
        } else {
            self.v &= ~@as(u15, 0x7000);
            var y: u15 = (self.v & 0x03E0) >> 5;
            if (y == 29) {
                y = 0;
                self.v ^= 0x0800;
            } else if (y == 31) {
                y = 0;
            } else {
                y += 1;
            }
            self.v = (self.v & ~@as(u15, 0x03E0)) | (y << 5);
        }
    }

    fn transferAddressX(self: *Ppu) void {
        self.v = (self.v & 0x7BE0) | (self.t & 0x041F);
    }

    fn transferAddressY(self: *Ppu) void {
        self.v = (self.v & 0x041F) | (self.t & 0x7BE0);
    }

    // ------------------------------------------------------ background fetch

    fn patternAddr(self: *const Ppu, plane_hi: bool) u16 {
        const table: u16 = if (self.ctrl.bg_table) 0x1000 else 0x0000;
        const fine_y: u16 = (self.v >> 12) & 0x7;
        const tile: u16 = self.bg_next_tile_id;
        return table + tile * 16 + fine_y + (if (plane_hi) @as(u16, 8) else 0);
    }

    fn fetchAttributeByte(self: *Ppu, mapper: *const Mapper) void {
        const nt: u16 = 0x2000 | (@as(u16, self.v) & 0x0C00);
        const coarse_x: u16 = self.v & 0x001F;
        const coarse_y: u16 = (self.v >> 5) & 0x001F;
        const attr_addr: u16 = nt | 0x03C0 | ((coarse_y >> 2) << 3) | (coarse_x >> 2);
        var byte = self.vramRead(attr_addr, mapper);
        // Each attribute byte covers a 4x4-tile (32x32-pixel) cell as four
        // 2-bit fields, one per 2x2-tile quadrant: bits 1:0 top-left, 3:2
        // top-right, 5:4 bottom-left, 7:6 bottom-right. `coarse_x`/`coarse_y`
        // bit 1 selects which half of the cell this tile is in, in each axis.
        if ((coarse_y & 0x02) != 0) byte >>= 4;
        if ((coarse_x & 0x02) != 0) byte >>= 2;
        self.bg_next_tile_attr = byte & 0x03;
    }

    fn loadBackgroundShifters(self: *Ppu) void {
        self.bg_shift_pattern_lo = (self.bg_shift_pattern_lo & 0xFF00) | self.bg_next_tile_lo;
        self.bg_shift_pattern_hi = (self.bg_shift_pattern_hi & 0xFF00) | self.bg_next_tile_hi;
        self.bg_shift_attr_lo = (self.bg_shift_attr_lo & 0xFF00) |
            (if ((self.bg_next_tile_attr & 0x01) != 0) @as(u16, 0xFF) else 0);
        self.bg_shift_attr_hi = (self.bg_shift_attr_hi & 0xFF00) |
            (if ((self.bg_next_tile_attr & 0x02) != 0) @as(u16, 0xFF) else 0);
    }

    fn shiftBackground(self: *Ppu) void {
        self.bg_shift_pattern_lo <<= 1;
        self.bg_shift_pattern_hi <<= 1;
        self.bg_shift_attr_lo <<= 1;
        self.bg_shift_attr_hi <<= 1;
    }

    /// The fetch+shift pipeline shared by every visible scanline and the
    /// pre-render scanline. Each tile costs 8 dots (NT byte, attribute
    /// byte, pattern low, pattern high -- 2 dots each on real hardware; we
    /// perform each fetch's actual bus read on its *second* dot and treat
    /// the first as address setup, which is invisible to anything that
    /// doesn't snoop the PPU bus mid-fetch), so dots 1-256 fetch exactly the
    /// 32 tiles a scanline needs, and dots 321-336 prefetch the first two
    /// tiles of the *next* scanline into the pipeline ahead of time. Dot 257
    /// also falls in `fetching`'s range below (it re-runs case 0's NT fetch
    /// using the pre-`transferAddressX` `v`), but that value is dead: dot
    /// 321's real fetch overwrites it before anything reads it, so this is
    /// inert, not a 33rd tile.
    fn renderCycle(self: *Ppu, mapper: *Mapper) void {
        const d = self.dot;
        const fetching = (d >= 1 and d <= 257) or (d >= 321 and d <= 337);
        const shifting = (d >= 2 and d <= 257) or (d >= 322 and d <= 337);

        if (shifting) self.shiftBackground();

        if (fetching) {
            switch ((d - 1) % 8) {
                0 => {
                    self.loadBackgroundShifters();
                    self.bg_next_tile_id = self.vramRead(0x2000 | (@as(u16, self.v) & 0x0FFF), mapper);
                },
                2 => self.fetchAttributeByte(mapper),
                4 => self.bg_next_tile_lo = self.vramRead(self.patternAddr(false), mapper),
                6 => {
                    self.bg_next_tile_hi = self.vramRead(self.patternAddr(true), mapper);
                    self.incrementCoarseX();
                },
                else => {},
            }
        }

        if (d == 256) self.incrementY();
        if (d == 257) {
            self.loadBackgroundShifters();
            self.transferAddressX();
        }
        if (self.scanline == 261 and d >= 280 and d <= 304) self.transferAddressY();

        // Two nametable fetches whose "purpose is unknown" per
        // https://www.nesdev.org/wiki/PPU_rendering (some mappers, e.g.
        // MMC5, use them for scanline counting). Harmless here: the result
        // is overwritten by the real fetch at dot 1 of the next scanline
        // before anything reads it.
        if (d == 338 or d == 340) {
            self.bg_next_tile_id = self.vramRead(0x2000 | (@as(u16, self.v) & 0x0FFF), mapper);
        }
    }

    /// **Known gap**: real hardware, while rendering is disabled, shows
    /// whichever palette entry `v` currently points to (if `v` happens to
    /// address `$3F00-$3FFF`) instead of always the universal backdrop
    /// (`palette[0]`) -- see https://www.nesdev.org/wiki/PPU_palettes. That
    /// lets a program flash the whole screen a chosen color by parking `v`
    /// there via `$2006`. Not modeled: `bg_color` below is unconditionally
    /// `palette[0]` regardless of `v`. Harmless for this milestone's own
    /// tests (none park `v` in palette space while rendering is off), flagged
    /// so it reads as known rather than as an oversight for whoever next
    /// touches this function.
    fn outputPixel(self: *Ppu) void {
        const col = self.dot - 1;
        const row = self.scanline;

        var bg_pixel: u8 = 0; // raw 2-bit pattern value, 0 = transparent
        var bg_color: u8 = self.palette[0] & 0x3F;
        if (self.mask.show_bg and (self.mask.show_bg_left or col >= 8)) {
            const bit_mux: u16 = @as(u16, 0x8000) >> self.fine_x;
            const p0: u8 = @intFromBool((self.bg_shift_pattern_lo & bit_mux) != 0);
            const p1: u8 = @intFromBool((self.bg_shift_pattern_hi & bit_mux) != 0);
            bg_pixel = (p1 << 1) | p0;
            if (bg_pixel != 0) {
                const a0: u8 = @intFromBool((self.bg_shift_attr_lo & bit_mux) != 0);
                const a1: u8 = @intFromBool((self.bg_shift_attr_hi & bit_mux) != 0);
                const group: u8 = (a1 << 1) | a0;
                bg_color = self.palette[paletteIndex(0x3F00 | (@as(u16, group) << 2) | bg_pixel)] & 0x3F;
            }
        }

        var final_color = bg_color;
        if (self.mask.show_sprites and (self.mask.show_sprites_left or col >= 8)) {
            var i: u8 = 0;
            while (i < self.sprite_count) : (i += 1) {
                const su = self.sprite_units[i];
                const x: u16 = su.x;
                if (col < x or col - x >= 8) continue;
                const shift: u3 = @intCast(7 - (col - x));
                const p0: u8 = (su.pattern_lo >> shift) & 1;
                const p1: u8 = (su.pattern_hi >> shift) & 1;
                const sprite_pixel = (p1 << 1) | p0;
                if (sprite_pixel == 0) continue;

                // Sprite-0 hit fires whenever OAM sprite 0's own pixel here
                // is opaque and so is the background's, regardless of this
                // sprite's priority bit (real hardware hits "even when
                // completely behind background" -- one of
                // `sprite_hit_tests_2005.10.05/01.basics`'s own checks) and
                // regardless of which sprite ends up drawn at this pixel.
                // The `col != 255` exclusion is a documented hardware quirk:
                // https://www.nesdev.org/wiki/PPU_OAM#Sprite_zero_hits.
                if (su.is_sprite0 and bg_pixel != 0 and col != 255) {
                    self.status.sprite0_hit = true;
                }

                if (!(su.behind_bg and bg_pixel != 0)) {
                    final_color = self.palette[paletteIndex(0x3F10 | (@as(u16, su.palette) << 2) | sprite_pixel)] & 0x3F;
                }
                break; // ascending OAM index = priority; first opaque wins
            }
        }

        if (self.mask.greyscale) final_color &= 0x30;
        self.framebuffer[@as(usize, row) * 256 + col] = final_color;
    }

    // -------------------------------------------------------- sprite pipeline

    /// Populate `secondary_oam`/`sprite_count`/`sprite0_in_range` for
    /// whichever scanline is about to be evaluated (`self.scanline`
    /// directly -- see `Ppu`'s type doc comment for why this codebase does
    /// not use real hardware's one-scanline evaluate-ahead pipeline).
    ///
    /// **The "+1".** A sprite's OAM Y byte is documented (see
    /// https://www.nesdev.org/wiki/PPU_OAM) as "the sprite's desired row,
    /// minus 1" -- i.e. writing Y=R-1 makes the sprite's first row appear on
    /// screen row R. So the in-range test for screen row `scanline` is
    /// `0 <= scanline - y - 1 < height`, not a direct `scanline - y`.
    ///
    /// **The overflow-flag hardware bug.** Once 8 in-range sprites are found,
    /// real hardware does not stop looking -- it keeps scanning OAM for a
    /// 9th, but a wiring bug means the byte it reads is no longer always a
    /// Y-coordinate: on a *miss* it advances its internal byte-within-sprite
    /// index too (not just the sprite index), so subsequent "Y" reads walk
    /// diagonally through OAM, occasionally testing a tile/attribute/X byte
    /// as if it were a Y-coordinate. `sprite_overflow_tests/4.Obscure`
    /// probes exactly this and passes against this implementation, per
    /// https://www.nesdev.org/wiki/PPU_sprite_evaluation#Sprite_overflow_bug.
    fn evaluateSprites(self: *Ppu) void {
        self.secondary_oam = [_]u8{0xFF} ** 32;
        self.sprite_count = 0;
        self.sprite0_in_range = false;

        const height: i32 = if (self.ctrl.sprite_height16) 16 else 8;
        var n: u16 = 0;
        var found: u8 = 0;
        while (n < 64) : (n += 1) {
            const y = self.oam[n * 4];
            const row = @as(i32, self.scanline) - @as(i32, y) - 1;
            if (row < 0 or row >= height) continue;
            if (n == 0) self.sprite0_in_range = true;
            @memcpy(self.secondary_oam[@as(usize, found) * 4 ..][0..4], self.oam[n * 4 ..][0..4]);
            found += 1;
            if (found == 8) {
                n += 1; // evaluation continues from the *next* sprite
                break;
            }
        }
        self.sprite_count = found;

        // The buggy overflow-detection phase, only reachable when all 8
        // slots filled before OAM was exhausted.
        if (found == 8 and n < 64) {
            var m: u16 = 0;
            while (n < 64) {
                const y = self.oam[n * 4 + m];
                const row = @as(i32, self.scanline) - @as(i32, y) - 1;
                if (row >= 0 and row < height) {
                    self.status.sprite_overflow = true;
                }
                // The bug: `m` advances on every step, hit or miss alike, so
                // it never resets to 0 for the next sprite -- only `n`
                // wrapping past 3 increments does that, "diagonally"
                // walking off each sprite's Y byte onto its neighbors'.
                m += 1;
                if (m == 4) {
                    m = 0;
                    n += 1;
                } else {
                    n += 1;
                }
            }
        }
    }

    /// Fetch pattern bytes for the sprites `evaluateSprites` just found,
    /// building `sprite_units[0..sprite_count]`. Only meaningful for
    /// `scanline <= 239` (see `tick`) -- scanline 240's evaluation exists
    /// purely for the overflow flag and is never fetched or drawn.
    fn fetchSpriteUnits(self: *Ppu, mapper: *Mapper) void {
        const height16 = self.ctrl.sprite_height16;
        const height: i32 = if (height16) 16 else 8;

        var i: u8 = 0;
        while (i < self.sprite_count) : (i += 1) {
            const base = @as(usize, i) * 4;
            const y = self.secondary_oam[base];
            const tile = self.secondary_oam[base + 1];
            const attr = self.secondary_oam[base + 2];
            const x = self.secondary_oam[base + 3];

            const flip_h = (attr & 0x40) != 0;
            const flip_v = (attr & 0x80) != 0;

            // In range by construction (this sprite came straight out of
            // `evaluateSprites`' own in-range check for this same scanline).
            var row: u16 = @intCast(@as(i32, self.scanline) - @as(i32, y) - 1);
            if (flip_v) row = @as(u16, @intCast(height - 1)) - row;

            var table: u16 = undefined;
            var tile_id: u16 = undefined;
            var fine_y: u16 = undefined;
            if (height16) {
                table = if ((tile & 0x01) != 0) 0x1000 else 0x0000;
                tile_id = @as(u16, tile & 0xFE) + (row >> 3);
                fine_y = row & 0x07;
            } else {
                table = if (self.ctrl.sprite_table) 0x1000 else 0x0000;
                tile_id = tile;
                fine_y = row;
            }
            const addr_lo = table + tile_id * 16 + fine_y;
            var lo = self.vramRead(addr_lo, mapper);
            var hi = self.vramRead(addr_lo + 8, mapper);
            if (flip_h) {
                lo = reverseBits(lo);
                hi = reverseBits(hi);
            }

            self.sprite_units[i] = .{
                .x = x,
                .pattern_lo = lo,
                .pattern_hi = hi,
                .palette = @intCast(attr & 0x03),
                .behind_bg = (attr & 0x20) != 0,
                .is_sprite0 = i == 0 and self.sprite0_in_range,
            };
        }
    }

    // ------------------------------------------------------------- tick

    fn advanceDot(self: *Ppu) void {
        // Odd-frame skip: dropping dot 340 of the pre-render scanline
        // shortens whichever frame that scanline belongs to -- i.e. the
        // frame now finishing, `self.frame` (not yet incremented). That
        // frame is shortened exactly when it is itself odd. Skipping lands
        // directly on (scanline 0, dot 0) one dot early -- the same event
        // https://www.nesdev.org/wiki/PPU_frame_timing describes from the
        // other end ("skipping the first idle tick on the first visible
        // scanline"). Only happens with rendering enabled.
        const skip_last_dot = self.scanline == 261 and self.dot == 339 and
            self.renderingEnabled() and (self.frame % 2 == 1);

        self.dot += 1;
        if (skip_last_dot) self.dot += 1;

        if (self.dot > 340) {
            self.dot = 0;
            self.scanline += 1;
            if (self.scanline > 261) {
                self.scanline = 0;
                self.frame += 1;
            }
        }
    }

    pub fn tick(self: *Ppu, mapper: *Mapper) void {
        const on_render_line = self.scanline <= 239 or self.scanline == 261;
        if (on_render_line and self.renderingEnabled()) self.renderCycle(mapper);

        // Sprite evaluation+fetch, collapsed to dot 1 -- see `Ppu`'s and
        // `evaluateSprites`'s doc comments for why this covers scanline 240
        // (never drawn) as well as 0-239, and why it does not spread across
        // real hardware's dots 65-256/257-320 the way `renderCycle` still
        // does for backgrounds.
        if (self.scanline <= 240 and self.renderingEnabled() and self.dot == 1) {
            self.evaluateSprites();
            if (self.scanline <= 239) self.fetchSpriteUnits(mapper);
        }

        if (self.scanline <= 239 and self.dot >= 1 and self.dot <= 256) {
            self.outputPixel();
        }

        if (self.scanline == 241 and self.dot == 1) {
            if (!self.suppress_vbl_this_frame) self.status.vblank = true;
            self.suppress_vbl_this_frame = false;
        }
        if (self.scanline == 261 and self.dot == 1) {
            self.status.vblank = false;
            self.status.sprite0_hit = false;
            self.status.sprite_overflow = false;
        }

        self.advanceDot();
        self.applyPendingLatches();
    }
};

// ============================== tests ==============================

fn testPpu(mirroring: Mirroring) Ppu {
    return Ppu.init(mirroring);
}

fn testMapper() Mapper {
    return Mapper{ .nrom = Nrom.init(&.{}, &.{}) }; // CHR-RAM, 8KB
}

test "PPUSTATUS read clears the VBL flag and the write-toggle" {
    var ppu = testPpu(.horizontal);
    var m = testMapper();
    ppu.status.vblank = true;
    ppu.w = true;
    const v = ppu.readRegister(0x2002, &m);
    try testing.expect((v & 0x80) != 0);
    try testing.expect(!ppu.status.vblank);
    try testing.expect(!ppu.w);
}

test "PPUSTATUS read returns open-bus bits from the data-bus latch" {
    var ppu = testPpu(.horizontal);
    var m = testMapper();
    ppu.writeRegister(0x2000, 0b0001_0101, &m); // arbitrary, lands in data_bus
    const v = ppu.readRegister(0x2002, &m);
    try testing.expectEqual(@as(u8, 0b0001_0101 & 0x1F), v & 0x1F);
}

test "writing PPUSTATUS is a no-op besides driving the data bus" {
    var ppu = testPpu(.horizontal);
    var m = testMapper();
    ppu.status.vblank = true;
    ppu.writeRegister(0x2002, 0xFF, &m);
    try testing.expect(ppu.status.vblank); // unaffected
}

test "PPUADDR is written high byte first, then low, then v=t" {
    var ppu = testPpu(.horizontal);
    var m = testMapper();
    ppu.writeRegister(0x2006, 0x21, &m); // high byte (top 2 bits dropped: 6 bits kept)
    try testing.expect(ppu.w);
    try testing.expectEqual(@as(u15, 0), ppu.v); // v not updated until 2nd write
    ppu.writeRegister(0x2006, 0x08, &m); // low byte
    try testing.expect(!ppu.w);
    try testing.expectEqual(@as(u15, 0x2108), ppu.v);
    try testing.expectEqual(@as(u15, 0x2108), ppu.t);
}

test "a PPUSTATUS read clears the write toggle mid-PPUADDR-write" {
    var ppu = testPpu(.horizontal);
    var m = testMapper();
    ppu.writeRegister(0x2006, 0x21, &m); // first write, w=1
    _ = ppu.readRegister(0x2002, &m); // clears w
    ppu.writeRegister(0x2006, 0x08, &m); // now treated as a *first* write again
    try testing.expect(ppu.w);
    try testing.expectEqual(@as(u15, 0x0800), ppu.t & 0x3F00);
}

test "PPUDATA reads are buffered by one access, except for palette addresses" {
    var ppu = testPpu(.horizontal);
    var m = testMapper();
    // Prime nametable byte at $2000 via a direct VRAM write.
    ppu.vram[0] = 0xAB;
    ppu.v = 0x2000;
    const primer = ppu.readRegister(0x2007, &m); // returns stale buffer (0), latches 0xAB
    try testing.expectEqual(@as(u8, 0x00), primer);
    const real = ppu.readRegister(0x2007, &m); // now at $2001 (buffer's turn)
    // v auto-incremented by 1 (PPUCTRL bit2 clear) between reads.
    try testing.expectEqual(@as(u15, 0x2002), ppu.v);
    try testing.expectEqual(@as(u8, 0xAB), real);

    // Palette reads return immediately, no priming needed.
    ppu.v = 0x3F05;
    ppu.palette[5] = 0x30;
    const pal = ppu.readRegister(0x2007, &m);
    try testing.expectEqual(@as(u8, 0x30), pal);
}

test "PPUDATA increments v by 1 or 32 depending on PPUCTRL bit 2" {
    var ppu = testPpu(.horizontal);
    var m = testMapper();
    ppu.v = 0x2000;
    ppu.writeRegister(0x2007, 0x11, &m);
    try testing.expectEqual(@as(u15, 0x2001), ppu.v);

    ppu.writeRegister(0x2000, 0x04, &m); // set increment32
    // PPUCTRL latches one dot after the write (see `applyPendingLatches`),
    // so give it that dot before relying on the new bit. A real CPU cannot
    // issue two register writes closer together than two whole CPU cycles
    // (6 dots) anyway -- this tick is what that gap looks like at the
    // smallest scale that still matters.
    ppu.tick(&m);
    ppu.v = 0x2000;
    ppu.writeRegister(0x2007, 0x22, &m);
    try testing.expectEqual(@as(u15, 0x2020), ppu.v);
}

test "PPUDATA writes reach CHR-RAM and nametable VRAM through the mapper" {
    var ppu = testPpu(.horizontal);
    var m = testMapper(); // CHR-RAM
    ppu.v = 0x0010;
    ppu.writeRegister(0x2007, 0x77, &m);
    try testing.expectEqual(@as(u8, 0x77), m.chrRead(0x0010));

    ppu.v = 0x2005;
    ppu.writeRegister(0x2007, 0x99, &m);
    try testing.expectEqual(@as(u8, 0x99), ppu.vram[5]);
}

test "OAMDATA writes auto-increment OAMADDR; reads do not" {
    var ppu = testPpu(.horizontal);
    var m = testMapper();
    ppu.writeRegister(0x2003, 0x10, &m);
    ppu.writeRegister(0x2004, 0xAA, &m);
    try testing.expectEqual(@as(u8, 0x11), ppu.oam_addr);
    try testing.expectEqual(@as(u8, 0xAA), ppu.oam[0x10]);

    ppu.oam_addr = 0x10;
    _ = ppu.readRegister(0x2004, &m);
    try testing.expectEqual(@as(u8, 0x10), ppu.oam_addr); // unchanged
}

test "PPUSCROLL's two writes set fine-X, coarse X, coarse Y, and fine Y" {
    var ppu = testPpu(.horizontal);
    var m = testMapper();
    ppu.writeRegister(0x2005, 0b0101_1011, &m); // coarse X=0b01011=11, fine X=0b011=3
    try testing.expectEqual(@as(u3, 0b011), ppu.fine_x);
    try testing.expectEqual(@as(u15, 11), ppu.t & 0x1F);

    ppu.writeRegister(0x2005, 0b0101_0110, &m); // coarse Y=0b01010=10, fine Y=0b110=6
    try testing.expectEqual(@as(u15, 10), (ppu.t >> 5) & 0x1F);
    try testing.expectEqual(@as(u15, 6), (ppu.t >> 12) & 0x7);
}

test "PPUCTRL and PPUMASK writes latch one dot late; everything else is immediate" {
    var ppu = testPpu(.horizontal);
    var m = testMapper();

    // PPUMASK: `advanceDot`'s odd-frame skip and `renderingEnabled` read
    // this as a *level* on later dots, so the one-dot delay is observable.
    // `ppu_vbl_nmi/10-even_odd_timing` is the conformance ROM that measures
    // it; this pins the same behavior without a 40KB fixture.
    ppu.writeRegister(0x2001, 0b0000_1000, &m); // show_bg
    try testing.expect(!ppu.mask.show_bg); // not yet -- still pending
    ppu.tick(&m);
    try testing.expect(ppu.mask.show_bg); // latched by the end of that dot

    // PPUCTRL, same: this is the delay `07-nmi_on_timing`/`08-nmi_off_timing`
    // measure through the NMI output level.
    ppu.status.vblank = true;
    ppu.writeRegister(0x2000, 0x80, &m); // nmi_enable
    try testing.expect(!ppu.ctrl.nmi_enable);
    try testing.expect(!ppu.nmiSignal()); // the whole point: still low
    ppu.tick(&m);
    try testing.expect(ppu.ctrl.nmi_enable);
    try testing.expect(ppu.nmiSignal());

    // Not deferred: `t`'s nametable-select bits, written straight from the
    // $2000 byte rather than read back through `ctrl`.
    ppu.writeRegister(0x2000, 0b10, &m);
    try testing.expectEqual(@as(u15, 0x0800), ppu.t & 0x0C00);
}

test "a second PPUCTRL write does not swallow the first one's pending latch" {
    var ppu = testPpu(.horizontal);
    var m = testMapper();
    ppu.writeRegister(0x2000, 0x80, &m); // nmi_enable, pending
    ppu.writeRegister(0x2000, 0x04, &m); // increment32; flushes the first
    try testing.expect(ppu.ctrl.nmi_enable); // the first write did land
    try testing.expect(!ppu.ctrl.increment32); // the second is still pending
    ppu.tick(&m);
    try testing.expect(ppu.ctrl.increment32);
    try testing.expect(!ppu.ctrl.nmi_enable); // fully replaced by the 2nd byte
}

test "Ppu.reset drops a pending PPUCTRL/PPUMASK latch instead of letting it apply after" {
    var ppu = testPpu(.horizontal);
    var m = testMapper();
    ppu.writeRegister(0x2000, 0x80, &m);
    ppu.writeRegister(0x2001, 0x1E, &m);
    ppu.reset();
    ppu.tick(&m);
    try testing.expect(!ppu.ctrl.nmi_enable);
    try testing.expect(!ppu.mask.show_bg);
}

test "PPUCTRL's nametable bits land in t bits 10-11" {
    var ppu = testPpu(.horizontal);
    var m = testMapper();
    ppu.writeRegister(0x2000, 0b10, &m);
    try testing.expectEqual(@as(u15, 0x0800), ppu.t & 0x0C00);
}

test "$2002/register mirroring: Bus is responsible for the every-8-bytes fold, not Ppu" {
    // Ppu.readRegister/writeRegister take an already-folded $2000-$2007
    // address -- this test just documents that expectation exists at the
    // Ppu level (Bus's own mirroring test lives in bus.zig).
    var ppu = testPpu(.horizontal);
    var m = testMapper();
    ppu.status.vblank = true;
    const a = ppu.readRegister(0x2002, &m);
    try testing.expect((a & 0x80) != 0);
}

test "horizontal mirroring ties $2000/$2400 together and $2800/$2C00 together" {
    var ppu = testPpu(.horizontal);
    var m = testMapper();
    ppu.v = 0x2000;
    ppu.writeRegister(0x2007, 0x11, &m);
    ppu.v = 0x2400;
    try testing.expectEqual(@as(u8, 0x11), ppu.vramRead(0x2400, &m));
    ppu.v = 0x2800;
    ppu.writeRegister(0x2007, 0x22, &m);
    ppu.v = 0x2C00;
    try testing.expectEqual(@as(u8, 0x22), ppu.vramRead(0x2C00, &m));
    try testing.expectEqual(@as(u8, 0x11), ppu.vramRead(0x2000, &m)); // untouched by the $2800 write
}

test "vertical mirroring ties $2000/$2800 together and $2400/$2C00 together" {
    var ppu = testPpu(.vertical);
    var m = testMapper();
    ppu.v = 0x2000;
    ppu.writeRegister(0x2007, 0x33, &m);
    ppu.v = 0x2800;
    try testing.expectEqual(@as(u8, 0x33), ppu.vramRead(0x2800, &m));
    try testing.expectEqual(@as(u8, 0x00), ppu.vramRead(0x2400, &m));
}

test "$3000-$3EFF mirrors $2000-$2EFF" {
    var ppu = testPpu(.horizontal);
    var m = testMapper();
    ppu.v = 0x2001;
    ppu.writeRegister(0x2007, 0x44, &m);
    try testing.expectEqual(@as(u8, 0x44), ppu.vramRead(0x3001, &m));
}

test "palette writes mirror $3F10/$14/$18/$1C onto $3F00/$04/$08/$0C" {
    var ppu = testPpu(.horizontal);
    var m = testMapper();
    ppu.v = 0x3F10;
    ppu.writeRegister(0x2007, 0x0F, &m);
    try testing.expectEqual(@as(u8, 0x0F), ppu.palette[0]);
    ppu.v = 0x3F00;
    ppu.writeRegister(0x2007, 0x2A, &m);
    try testing.expectEqual(@as(u8, 0x2A), ppu.palette[0x10 & 0x1F & ~@as(u16, 0x10)]); // = palette[0]
}

test "Ppu.reset clears PPUCTRL/PPUMASK/the write toggle/the read buffer/t/fine_x, but not v or PPUSTATUS/OAM" {
    var ppu = testPpu(.horizontal);
    ppu.ctrl.nmi_enable = true;
    ppu.mask.show_bg = true;
    ppu.w = true;
    ppu.read_buffer = 0x42;
    ppu.status.vblank = true;
    ppu.oam_addr = 0x10;
    ppu.v = 0x2000;
    ppu.t = 0x2000;
    ppu.fine_x = 0x5;
    ppu.reset();
    try testing.expect(!ppu.ctrl.nmi_enable);
    try testing.expect(!ppu.mask.show_bg);
    try testing.expect(!ppu.w);
    try testing.expectEqual(@as(u8, 0), ppu.read_buffer);
    // Per https://www.nesdev.org/wiki/PPU_power_up_state: reset clears `t`
    // (the "VRAM address latch") and fine X along with the toggle that
    // gates them -- only `v`, the actual current VRAM address, survives.
    try testing.expectEqual(@as(u15, 0), ppu.t);
    try testing.expectEqual(@as(u3, 0), ppu.fine_x);
    try testing.expect(ppu.status.vblank); // survives reset
    try testing.expectEqual(@as(u8, 0x10), ppu.oam_addr); // survives reset
    try testing.expectEqual(@as(u15, 0x2000), ppu.v); // survives reset
}

test "the dot/scanline counter advances 341 dots per scanline, 262 scanlines per frame" {
    var ppu = testPpu(.horizontal);
    var m = testMapper();
    // Rendering disabled: no odd-frame skip, so exactly 341*262 ticks
    // returns to (0,0) of the next frame.
    const total: u32 = 341 * 262;
    for (0..total) |_| ppu.tick(&m);
    try testing.expectEqual(@as(u16, 0), ppu.scanline);
    try testing.expectEqual(@as(u16, 0), ppu.dot);
    try testing.expectEqual(@as(u64, 1), ppu.frame);
}

test "the VBL flag sets at scanline 241 dot 1 and clears at scanline 261 dot 1" {
    var ppu = testPpu(.horizontal);
    var m = testMapper();
    // `tick` processes whatever (scanline, dot) is *current* and then
    // advances -- so after N calls, the fields hold the dot *about to be*
    // processed by call N+1, not the one `tick` #N just finished. Landing
    // the fields on (241, 1) therefore means dot 1's effects (setting the
    // flag) have not run yet; one more `tick` call is what actually
    // processes it.
    for (0..241 * 341 + 1) |_| ppu.tick(&m);
    try testing.expectEqual(@as(u16, 241), ppu.scanline);
    try testing.expectEqual(@as(u16, 1), ppu.dot);
    try testing.expect(!ppu.status.vblank); // not processed yet

    ppu.tick(&m); // processes (241, 1): sets the flag
    try testing.expect(ppu.status.vblank);
    try testing.expectEqual(@as(u16, 241), ppu.scanline);
    try testing.expectEqual(@as(u16, 2), ppu.dot);

    // Same reasoning for the pre-render line's clear at (261, 1): land the
    // fields there first (still not yet processed), then process it.
    for (0..20 * 341 - 1) |_| ppu.tick(&m);
    try testing.expectEqual(@as(u16, 261), ppu.scanline);
    try testing.expectEqual(@as(u16, 1), ppu.dot);
    try testing.expect(ppu.status.vblank); // still set, not processed yet

    ppu.tick(&m); // processes (261, 1): clears the flag
    try testing.expect(!ppu.status.vblank);
    try testing.expectEqual(@as(u16, 261), ppu.scanline);
    try testing.expectEqual(@as(u16, 2), ppu.dot);
}

test "nmiSignal is the AND of the VBL flag and PPUCTRL's NMI-enable bit" {
    var ppu = testPpu(.horizontal);
    try testing.expect(!ppu.nmiSignal());
    ppu.status.vblank = true;
    try testing.expect(!ppu.nmiSignal());
    ppu.ctrl.nmi_enable = true;
    try testing.expect(ppu.nmiSignal());
    ppu.status.vblank = false;
    try testing.expect(!ppu.nmiSignal());
}

test "odd-frame skip drops one dot from the pre-render scanline only when rendering is enabled and only every other frame" {
    var ppu = testPpu(.horizontal);
    var m = testMapper();
    ppu.mask.show_bg = true; // rendering enabled

    // Frame 0 (even) is full-length: 341*262 ticks lands exactly on (0,0).
    for (0..341 * 262) |_| ppu.tick(&m);
    try testing.expectEqual(@as(u16, 0), ppu.scanline);
    try testing.expectEqual(@as(u16, 0), ppu.dot);
    try testing.expectEqual(@as(u64, 1), ppu.frame);

    // Frame 1 (odd) is one dot short: only 341*262 - 1 ticks are needed to
    // reach (0,0) of frame 2.
    for (0..341 * 262 - 1) |_| ppu.tick(&m);
    try testing.expectEqual(@as(u16, 0), ppu.scanline);
    try testing.expectEqual(@as(u16, 0), ppu.dot);
    try testing.expectEqual(@as(u64, 2), ppu.frame);
}

test "a $2002 read one PPU clock before the VBL flag sets suppresses it for the frame" {
    var ppu = testPpu(.horizontal);
    var m = testMapper();
    // Land the fields on (241, 1) -- i.e. dot 1's effects (setting the
    // flag) have not run yet, so a read landing here is "one PPU clock
    // before" the set from the read's point of view.
    for (0..241 * 341 + 1) |_| ppu.tick(&m);
    try testing.expectEqual(@as(u16, 241), ppu.scanline);
    try testing.expectEqual(@as(u16, 1), ppu.dot);

    const v = ppu.readRegister(0x2002, &m);
    try testing.expectEqual(@as(u8, 0), v & 0x80); // reads clear -- not set yet

    ppu.tick(&m); // processes (241, 1), where the flag would normally set
    try testing.expect(!ppu.status.vblank); // suppressed for the rest of this vblank
}
