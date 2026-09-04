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

/// The 2C02 PPU: registers, VRAM/OAM/palette storage, the dot/scanline
/// timing state machine, and the background tile+attribute pipeline.
///
/// **No sprites yet.** OAM storage and the OAMDATA/OAMADDR registers exist
/// (a later milestone's sprite evaluation and the DMA-fed pixel pipeline
/// need them to already be architecturally present), but nothing reads OAM
/// to produce pixels this milestone -- `mask.show_sprites` is stored and
/// contributes to timing (odd-frame skip cares about "rendering enabled",
/// which is bg-or-sprites on real hardware) but never puts a sprite pixel on
/// screen. `secondary_oam` likewise exists only so `assert_deterministic`
/// (ENG-65) can already hash "genuinely mid-scanline-resumable state" per
/// its spec, ahead of the evaluation logic that will populate it.
///
/// **Driven entirely by `tick`.** Every PPU dot -- background fetch, shift,
/// pixel output, VBL edge, the odd-frame skip -- happens inside `tick`,
/// called exactly 3 times per CPU cycle from `Cpu.tick`'s chokepoint. There
/// is no other path that advances PPU state, mirroring the CPU core's own
/// single-chokepoint discipline.
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
    /// See the type doc comment: unused until sprite evaluation exists.
    secondary_oam: [32]u8 = [_]u8{0} ** 32,

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
    /// cleared; PPUSTATUS (the VBL flag included), OAMADDR, OAM, VRAM,
    /// palette RAM, and the v/t/x scroll registers all survive untouched.
    pub fn reset(self: *Ppu) void {
        self.ctrl = .{};
        self.mask = .{};
        self.w = false;
        self.read_buffer = 0;
    }

    pub fn nmiSignal(self: *const Ppu) bool {
        return self.status.vblank and self.ctrl.nmi_enable;
    }

    fn renderingEnabled(self: *const Ppu) bool {
        return self.mask.show_bg or self.mask.show_sprites;
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
            0x2004 => result = self.oam[self.oam_addr],
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
            0x2004 => self.oam[self.oam_addr],
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
                self.ctrl = @bitCast(value);
                self.t = (self.t & ~@as(u15, 0x0C00)) | (@as(u15, self.ctrl.nametable) << 10);
            },
            0x2001 => self.mask = @bitCast(value),
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
    /// doesn't snoop the PPU bus mid-fetch), so 256 dots fetch exactly the
    /// 32 tiles a scanline needs, and dots 321-336 prefetch the first two
    /// tiles of the *next* scanline into the pipeline ahead of time.
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

    fn outputPixel(self: *Ppu) void {
        const col = self.dot - 1;
        const row = self.scanline;
        var color_index: u8 = self.palette[0] & 0x3F;

        if (self.mask.show_bg and (self.mask.show_bg_left or col >= 8)) {
            const bit_mux: u16 = @as(u16, 0x8000) >> self.fine_x;
            const p0: u8 = @intFromBool((self.bg_shift_pattern_lo & bit_mux) != 0);
            const p1: u8 = @intFromBool((self.bg_shift_pattern_hi & bit_mux) != 0);
            const pixel: u8 = (p1 << 1) | p0;
            if (pixel != 0) {
                const a0: u8 = @intFromBool((self.bg_shift_attr_lo & bit_mux) != 0);
                const a1: u8 = @intFromBool((self.bg_shift_attr_hi & bit_mux) != 0);
                const group: u8 = (a1 << 1) | a0;
                color_index = self.palette[paletteIndex(0x3F00 | (@as(u16, group) << 2) | pixel)] & 0x3F;
            }
        }
        if (self.mask.greyscale) color_index &= 0x30;
        self.framebuffer[@as(usize, row) * 256 + col] = color_index;
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

test "Ppu.reset clears PPUCTRL/PPUMASK/the write toggle/the read buffer, nothing else" {
    var ppu = testPpu(.horizontal);
    ppu.ctrl.nmi_enable = true;
    ppu.mask.show_bg = true;
    ppu.w = true;
    ppu.read_buffer = 0x42;
    ppu.status.vblank = true;
    ppu.oam_addr = 0x10;
    ppu.v = 0x2000;
    ppu.reset();
    try testing.expect(!ppu.ctrl.nmi_enable);
    try testing.expect(!ppu.mask.show_bg);
    try testing.expect(!ppu.w);
    try testing.expectEqual(@as(u8, 0), ppu.read_buffer);
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
