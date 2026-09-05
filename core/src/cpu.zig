const std = @import("std");
const testing = std.testing;

const bus_mod = @import("bus.zig");
const mapper_mod = @import("mapper.zig");
const Bus = bus_mod.Bus;
const Mapper = mapper_mod.Mapper;
const Nrom = mapper_mod.Nrom;
const TestStub = mapper_mod.TestStub;

/// The processor status register.
///
/// Zig lays a `packed struct(u8)` out least-significant-field-first, so this
/// declaration order *is* the hardware bit order: C=bit0 ... N=bit7.
///
/// Bits 4 (B) and 5 (U) do not physically exist as flip-flops. `b` is only
/// ever meaningful in a *pushed* copy of P — it distinguishes BRK/PHP (pushed
/// with B=1) from a hardware IRQ/NMI (pushed with B=0) — and `u` reads back as
/// 1 in every pushed copy. We therefore keep the canonical in-register form as
/// `b = false, u = true`, and OR the right bits in at push time (`pushP`).
/// `fromByte` re-normalizes on the way back, which is exactly what PLP and RTI
/// do on hardware: they ignore bits 4 and 5.
pub const Flags = packed struct(u8) {
    c: bool = false,
    z: bool = false,
    i: bool = false,
    d: bool = false,
    b: bool = false,
    u: bool = true,
    v: bool = false,
    n: bool = false,

    pub fn toByte(self: Flags) u8 {
        return @bitCast(self);
    }

    pub fn fromByte(value: u8) Flags {
        var f: Flags = @bitCast(value);
        f.b = false;
        f.u = true;
        return f;
    }
};

/// Addressing modes, in the vocabulary the reference timing tables use.
pub const AddrMode = enum {
    implied,
    accumulator,
    immediate,
    zero_page,
    zero_page_x,
    zero_page_y,
    absolute,
    absolute_x,
    absolute_y,
    /// Only JMP ($nnnn).
    indirect,
    /// ($nn,X)
    indexed_indirect,
    /// ($nn),Y
    indirect_indexed,
    relative,

    /// Total instruction length in bytes, opcode included.
    pub fn length(self: AddrMode) u2 {
        return switch (self) {
            .implied, .accumulator => 1,
            .immediate, .zero_page, .zero_page_x, .zero_page_y, .relative, .indexed_indirect, .indirect_indexed => 2,
            .absolute, .absolute_x, .absolute_y, .indirect => 3,
        };
    }
};

pub const Op = struct {
    /// Every 6502 mnemonic — official and undocumented alike — is exactly
    /// three characters, so this is a pointer to a fixed-size array rather
    /// than a slice. A `[]const u8` would make each of the 256 table entries
    /// carry a redundant 8-byte length field and, in the wasm build, a
    /// relocation to go with it. Coerces to `[]const u8` wherever a slice is
    /// wanted (see `Trace.mnemonic`).
    mnemonic: *const [3]u8,
    mode: AddrMode,
};

fn op(mnemonic: *const [3]u8, mode: AddrMode) Op {
    return .{ .mnemonic = mnemonic, .mode = mode };
}

/// Decode table for all 256 opcodes, transcribed from the reference doc's
/// "6510 Instructions by Addressing Modes" matrix. Undocumented opcodes are
/// spelled with their community-standard mnemonics (the matrix's `*` and `**`
/// entries); `JAM` covers the twelve `t`/`*t` opcodes that lock up the CPU.
///
/// This table is *decode metadata only* — it drives instruction length for the
/// tracer/disassembler and produces readable names in failure messages. The
/// actual execution is the explicit `switch` in `execute`, so a typo here
/// cannot silently change emulated behavior.
///
/// **BRK is two bytes, not one.** The reference doc's own BRK timing table
/// (cycle 2: "read next instruction byte (and throw it away), increment PC")
/// is unambiguous — the CPU skips a signature byte and pushes PC+2, which is
/// what `execute` does. It is listed under the matrix's `Impl/immed` column,
/// and `.immediate` is the entry that makes `AddrMode.length()` agree with
/// that PC advance. Marking it `.implied` made `Trace.length` report 1 while
/// the core consumed 2, which would desync any disassembler that steps by
/// `length` and would show up as a byte-count mismatch in a future log diff.
/// nestest never executes BRK, so nothing here catches it.
pub const opcodes: [256]Op = .{
    // $00
    op("BRK", .immediate),   op("ORA", .indexed_indirect), op("JAM", .implied),     op("SLO", .indexed_indirect),
    op("NOP", .zero_page),   op("ORA", .zero_page),        op("ASL", .zero_page),   op("SLO", .zero_page),
    op("PHP", .implied),     op("ORA", .immediate),        op("ASL", .accumulator), op("ANC", .immediate),
    op("NOP", .absolute),    op("ORA", .absolute),         op("ASL", .absolute),    op("SLO", .absolute),
    // $10
    op("BPL", .relative),    op("ORA", .indirect_indexed), op("JAM", .implied),     op("SLO", .indirect_indexed),
    op("NOP", .zero_page_x), op("ORA", .zero_page_x),      op("ASL", .zero_page_x), op("SLO", .zero_page_x),
    op("CLC", .implied),     op("ORA", .absolute_y),       op("NOP", .implied),     op("SLO", .absolute_y),
    op("NOP", .absolute_x),  op("ORA", .absolute_x),       op("ASL", .absolute_x),  op("SLO", .absolute_x),
    // $20
    op("JSR", .absolute),    op("AND", .indexed_indirect), op("JAM", .implied),     op("RLA", .indexed_indirect),
    op("BIT", .zero_page),   op("AND", .zero_page),        op("ROL", .zero_page),   op("RLA", .zero_page),
    op("PLP", .implied),     op("AND", .immediate),        op("ROL", .accumulator), op("ANC", .immediate),
    op("BIT", .absolute),    op("AND", .absolute),         op("ROL", .absolute),    op("RLA", .absolute),
    // $30
    op("BMI", .relative),    op("AND", .indirect_indexed), op("JAM", .implied),     op("RLA", .indirect_indexed),
    op("NOP", .zero_page_x), op("AND", .zero_page_x),      op("ROL", .zero_page_x), op("RLA", .zero_page_x),
    op("SEC", .implied),     op("AND", .absolute_y),       op("NOP", .implied),     op("RLA", .absolute_y),
    op("NOP", .absolute_x),  op("AND", .absolute_x),       op("ROL", .absolute_x),  op("RLA", .absolute_x),
    // $40
    op("RTI", .implied),     op("EOR", .indexed_indirect), op("JAM", .implied),     op("SRE", .indexed_indirect),
    op("NOP", .zero_page),   op("EOR", .zero_page),        op("LSR", .zero_page),   op("SRE", .zero_page),
    op("PHA", .implied),     op("EOR", .immediate),        op("LSR", .accumulator), op("ASR", .immediate),
    op("JMP", .absolute),    op("EOR", .absolute),         op("LSR", .absolute),    op("SRE", .absolute),
    // $50
    op("BVC", .relative),    op("EOR", .indirect_indexed), op("JAM", .implied),     op("SRE", .indirect_indexed),
    op("NOP", .zero_page_x), op("EOR", .zero_page_x),      op("LSR", .zero_page_x), op("SRE", .zero_page_x),
    op("CLI", .implied),     op("EOR", .absolute_y),       op("NOP", .implied),     op("SRE", .absolute_y),
    op("NOP", .absolute_x),  op("EOR", .absolute_x),       op("LSR", .absolute_x),  op("SRE", .absolute_x),
    // $60
    op("RTS", .implied),     op("ADC", .indexed_indirect), op("JAM", .implied),     op("RRA", .indexed_indirect),
    op("NOP", .zero_page),   op("ADC", .zero_page),        op("ROR", .zero_page),   op("RRA", .zero_page),
    op("PLA", .implied),     op("ADC", .immediate),        op("ROR", .accumulator), op("ARR", .immediate),
    op("JMP", .indirect),    op("ADC", .absolute),         op("ROR", .absolute),    op("RRA", .absolute),
    // $70
    op("BVS", .relative),    op("ADC", .indirect_indexed), op("JAM", .implied),     op("RRA", .indirect_indexed),
    op("NOP", .zero_page_x), op("ADC", .zero_page_x),      op("ROR", .zero_page_x), op("RRA", .zero_page_x),
    op("SEI", .implied),     op("ADC", .absolute_y),       op("NOP", .implied),     op("RRA", .absolute_y),
    op("NOP", .absolute_x),  op("ADC", .absolute_x),       op("ROR", .absolute_x),  op("RRA", .absolute_x),
    // $80
    op("NOP", .immediate),   op("STA", .indexed_indirect), op("NOP", .immediate),   op("SAX", .indexed_indirect),
    op("STY", .zero_page),   op("STA", .zero_page),        op("STX", .zero_page),   op("SAX", .zero_page),
    op("DEY", .implied),     op("NOP", .immediate),        op("TXA", .implied),     op("ANE", .immediate),
    op("STY", .absolute),    op("STA", .absolute),         op("STX", .absolute),    op("SAX", .absolute),
    // $90
    op("BCC", .relative),    op("STA", .indirect_indexed), op("JAM", .implied),     op("SHA", .indirect_indexed),
    op("STY", .zero_page_x), op("STA", .zero_page_x),      op("STX", .zero_page_y), op("SAX", .zero_page_y),
    op("TYA", .implied),     op("STA", .absolute_y),       op("TXS", .implied),     op("SHS", .absolute_y),
    op("SHY", .absolute_x),  op("STA", .absolute_x),       op("SHX", .absolute_y),  op("SHA", .absolute_y),
    // $A0
    op("LDY", .immediate),   op("LDA", .indexed_indirect), op("LDX", .immediate),   op("LAX", .indexed_indirect),
    op("LDY", .zero_page),   op("LDA", .zero_page),        op("LDX", .zero_page),   op("LAX", .zero_page),
    op("TAY", .implied),     op("LDA", .immediate),        op("TAX", .implied),     op("LXA", .immediate),
    op("LDY", .absolute),    op("LDA", .absolute),         op("LDX", .absolute),    op("LAX", .absolute),
    // $B0
    op("BCS", .relative),    op("LDA", .indirect_indexed), op("JAM", .implied),     op("LAX", .indirect_indexed),
    op("LDY", .zero_page_x), op("LDA", .zero_page_x),      op("LDX", .zero_page_y), op("LAX", .zero_page_y),
    op("CLV", .implied),     op("LDA", .absolute_y),       op("TSX", .implied),     op("LAS", .absolute_y),
    op("LDY", .absolute_x),  op("LDA", .absolute_x),       op("LDX", .absolute_y),  op("LAX", .absolute_y),
    // $C0
    op("CPY", .immediate),   op("CMP", .indexed_indirect), op("NOP", .immediate),   op("DCP", .indexed_indirect),
    op("CPY", .zero_page),   op("CMP", .zero_page),        op("DEC", .zero_page),   op("DCP", .zero_page),
    op("INY", .implied),     op("CMP", .immediate),        op("DEX", .implied),     op("SBX", .immediate),
    op("CPY", .absolute),    op("CMP", .absolute),         op("DEC", .absolute),    op("DCP", .absolute),
    // $D0
    op("BNE", .relative),    op("CMP", .indirect_indexed), op("JAM", .implied),     op("DCP", .indirect_indexed),
    op("NOP", .zero_page_x), op("CMP", .zero_page_x),      op("DEC", .zero_page_x), op("DCP", .zero_page_x),
    op("CLD", .implied),     op("CMP", .absolute_y),       op("NOP", .implied),     op("DCP", .absolute_y),
    op("NOP", .absolute_x),  op("CMP", .absolute_x),       op("DEC", .absolute_x),  op("DCP", .absolute_x),
    // $E0
    op("CPX", .immediate),   op("SBC", .indexed_indirect), op("NOP", .immediate),   op("ISB", .indexed_indirect),
    op("CPX", .zero_page),   op("SBC", .zero_page),        op("INC", .zero_page),   op("ISB", .zero_page),
    op("INX", .implied),     op("SBC", .immediate),        op("NOP", .implied),     op("SBC", .immediate),
    op("CPX", .absolute),    op("SBC", .absolute),         op("INC", .absolute),    op("ISB", .absolute),
    // $F0
    op("BEQ", .relative),    op("SBC", .indirect_indexed), op("JAM", .implied),     op("ISB", .indirect_indexed),
    op("NOP", .zero_page_x), op("SBC", .zero_page_x),      op("INC", .zero_page_x), op("ISB", .zero_page_x),
    op("SED", .implied),     op("SBC", .absolute_y),       op("NOP", .implied),     op("ISB", .absolute_y),
    op("NOP", .absolute_x),  op("SBC", .absolute_x),       op("INC", .absolute_x),  op("ISB", .absolute_x),
};

/// How an addressing mode's effective address is going to be used. This
/// selects between the three different dummy-read behaviors the NMOS core has
/// for indexed modes (see the reference doc's "Absolute indexed addressing"
/// and "Indirect indexed addressing" tables):
///
///   * `.read`  — the extra read only happens when the index carried into the
///                high byte, i.e. the famous "+1 cycle on page cross".
///   * `.write` — the CPU cannot un-write a wrong address, so it *always*
///                performs the read at the un-fixed address first. No page-
///                cross bonus: the cycle count is constant.
///   * `.rmw`   — same as `.write` (always reads at the un-fixed address),
///                and then the read-modify-write triple follows.
const Access = enum { read, write, rmw };

/// Interrupt vectors.
pub const nmi_vector: u16 = 0xFFFA;
pub const reset_vector: u16 = 0xFFFC;
pub const irq_vector: u16 = 0xFFFE;

/// The NMOS 6502 core as it appears in the NES's 2A03.
///
/// **Cycle accuracy.** Every emulated bus cycle goes through `read`/`write`,
/// which tick `cycles` exactly once. Instructions are written as the literal
/// sequence of bus accesses from the reference doc's timing tables — including
/// the accesses that discard their result (dummy reads at un-fixed indexed
/// addresses, the opcode pre-fetch on a taken branch) and the NMOS
/// read-modify-write double write. Cycle counts therefore *fall out of* the
/// bus sequence rather than being looked up in a table, which is what makes
/// them trustworthy for the dummy-read-sensitive test ROMs.
///
/// **No decimal mode.** The 2A03 has BCD disabled in silicon. `SED`/`CLD`
/// still toggle `p.d` (so `PHP`/`PLP` round-trip it), but `ADC`/`SBC` — and
/// their undocumented derivatives `RRA`/`ISB`/`ARR` — are always pure binary.
/// The reference doc's decimal-mode chapter is C64-specific and deliberately
/// not implemented.
pub const Cpu = struct {
    a: u8 = 0,
    x: u8 = 0,
    y: u8 = 0,
    /// Stack pointer; the stack lives at $0100 + S.
    s: u8 = 0,
    pc: u16 = 0,
    p: Flags = .{},

    /// Total elapsed CPU cycles since power-on. 64-bit: at 1.79 MHz this does
    /// not wrap for ~325,000 years, so no wraparound handling is needed.
    cycles: u64 = 0,

    bus: *Bus,

    /// NMI is edge-triggered: `setNmiLine` latches `nmi_pending` on the rising
    /// edge, and it stays latched until serviced. `nmi_line` tracks the raw
    /// level so the edge detector can find the transition on hardware's
    /// active-low line — modeled here as a rising edge of "asserted".
    nmi_line: bool = false,
    nmi_pending: bool = false,

    /// IRQ is level-triggered. This is the CPU's own /IRQ input; the mapper's
    /// IRQ (MMC3 scanline counter, M7) is OR-ed in by `irqAsserted`, so the
    /// interrupt logic here never has to know which mapper is installed.
    irq_line: bool = false,

    /// Set by one of the twelve `JAM` opcodes. A real NMOS core in this state
    /// halts with the address bus floating and only a RESET recovers it; we
    /// model it as "burn one cycle per step, PC frozen" and leave it to the
    /// caller to notice. See `jammed` handling in `step`.
    jammed: bool = false,

    /// Latched result of the interrupt poll performed at the end of the
    /// previous instruction. Hardware polls the interrupt lines during an
    /// instruction's *penultimate* cycle, which is why `CLI`/`SEI`/`PLP` are
    /// "one instruction late": they write the I flag on their final cycle,
    /// after the poll has already read the old value. `poll_i_override`
    /// carries that pre-instruction I value for exactly those three opcodes.
    /// `RTI` deliberately does *not* set it — its I flag change is visible to
    /// the poll immediately, which is the documented asymmetry.
    irq_ready: bool = false,
    poll_i_override: ?bool = null,

    /// The NMI analogue of `irq_ready`/`poll_i_override`, but general rather
    /// than opcode-specific: `nmi_pending` (the raw, continuously-updated
    /// edge latch) can be set by *any* cycle's bus access, not just three
    /// named opcodes, since it's driven by writes to $2000 as easily as by
    /// the PPU's own timing. Re-derived every single cycle (see `read`/
    /// `write`) as a snapshot of `nmi_pending` taken *before* that cycle's
    /// own tick+access, `nmi_ready` is what `step` actually dispatches on.
    ///
    /// This reproduces Blargg's `ppu_vbl_nmi/04-nmi_control` test 11
    /// ("immediate occurrence should be after [the] NEXT instruction"): an
    /// edge that lands on an instruction's own *last* cycle (e.g. the write
    /// half of `STA $2000` enabling NMI while VBL is already set) updates
    /// `nmi_pending` only *after* `nmi_ready` was already snapshotted for
    /// that cycle, so it isn't visible to `step`'s dispatch check until the
    /// *following* instruction has run its own first cycle and re-snapshotted.
    /// An edge landing on any *earlier* cycle of a multi-cycle instruction,
    /// by contrast, gets caught by that same instruction's next snapshot and
    /// dispatches with no extra delay — exactly the cycle-precise variation
    /// `05-nmi_timing` exercises.
    nmi_ready: bool = false,

    pub fn init(bus: *Bus) Cpu {
        return .{ .bus = bus };
    }

    // ---------------------------------------------------------------- bus

    /// Advance the emulated clock by one CPU cycle, stepping the PPU 3 dots
    /// (the fixed NTSC ratio) to match.
    ///
    /// **This is the only place `cycles` is incremented, deliberately.** Every
    /// cycle the core spends — bus accesses and the idle cycle a jammed CPU
    /// burns alike — funnels through here, so a jammed CPU still advances
    /// video instead of freezing the picture, which is not what hardware
    /// does.
    ///
    /// **Why there's a poll wedged between the first and second PPU dot.**
    /// `read`/`write` poll NMI once more, *after* this returns and after the
    /// bus access completes — so within one CPU cycle there are two poll
    /// points straddling three PPU dots. Blargg's `ppu_vbl_nmi/06-suppression`
    /// (VBL flag set at scanline 241 dot 1) needs exactly this split to match
    /// its documented window: a read landing so that the flag-setting dot is
    /// the *first* of this cycle's three must see the edge fire normally
    /// (the flag was already true for two whole PPU dots before this read's
    /// own clear could suppress anything), while a read landing so that the
    /// flag-setting dot is the *second or third* must suppress it (the read
    /// clears the flag before either poll ever observes it high). Polling
    /// only after all 3 dots — the first thing tried here — suppressed all
    /// three alignments instead of two out of three, which is exactly the
    /// off-by-one-dot failure `06-suppression` (and `05`/`07`/`08-nmi_*_timing`,
    /// which share the same underlying edge-timing logic) caught.
    fn tick(self: *Cpu) void {
        self.cycles += 1;
        self.bus.ppu.tick(&self.bus.mapper);
        self.pollNmi();
        self.bus.ppu.tick(&self.bus.mapper);
        self.bus.ppu.tick(&self.bus.mapper);
    }

    /// Re-latch the CPU's edge-triggered NMI input from the PPU's current
    /// (vblank_flag AND nmi_enable) output level. Called mid-`tick` (after
    /// the first of this cycle's 3 PPU dots), after every bus access, and
    /// after the idle cycle a jammed CPU burns — see `tick`'s doc comment
    /// for why the split timing matters.
    fn pollNmi(self: *Cpu) void {
        self.setNmiLine(self.bus.ppu.nmiSignal());
    }

    /// Snapshot `nmi_ready` from `nmi_pending` as it stands *after* this
    /// cycle's 3 PPU dots (`tick`, mid-`tick` poll included) but *before*
    /// this cycle's own bus access. Called by every `read`/`write` (and the
    /// jammed-CPU idle cycle) right after `tick` returns — see `nmi_ready`'s
    /// doc comment for why this ordering is what gives `step` the right
    /// dispatch timing: an edge already visible by the time this cycle's 3
    /// dots have ticked (whether latched earlier or by `tick`'s own
    /// mid-point poll) is ready to dispatch as soon as *this* instruction
    /// finishes, while an edge this cycle's own *access* produces (e.g. a
    /// write enabling NMI) is deliberately one snapshot too late to affect
    /// this instruction's dispatch decision, only the next one's.
    fn snapshotNmiReady(self: *Cpu) void {
        self.nmi_ready = self.nmi_pending;
    }

    fn read(self: *Cpu, addr: u16) u8 {
        self.tick();
        self.snapshotNmiReady();
        const value = self.bus.read(addr);
        self.pollNmi();
        return value;
    }

    /// **Why there is no `pollNmi()` at the end of a write, unlike `read`.**
    /// A write's effect on the PPU is not visible to the PPU's own logic
    /// until one dot later -- see `Ppu.applyPendingLatches` for PPUCTRL and
    /// PPUMASK specifically. Sampling the NMI line here, in between the
    /// write and the dot that latches it, would let this cycle observe an
    /// NMI edge that the very byte being written is about to cancel: the
    /// concrete case is Blargg's `ppu_vbl_nmi/08-nmi_off_timing`, where a
    /// $2000 write disabling NMI races the VBL flag's set. With a poll
    /// here, the edge latches first and the interrupt fires one row earlier
    /// than hardware. Dropping it defers this cycle's sample to the next
    /// cycle's mid-`tick` poll -- which is *after* the latch, so the write
    /// and the sample resolve in hardware's order. Nothing is lost: every
    /// cycle, `tick` still polls after its first dot, so no edge goes
    /// unlatched, only up to two dots later than a write cycle used to see
    /// it. `07`/`08`/`10-even_odd_timing` all pass only with this and the
    /// latch delay together; `04`/`05`/`06` stay passing.
    fn write(self: *Cpu, addr: u16, value: u8) void {
        self.tick();
        self.snapshotNmiReady();
        self.bus.write(addr, value);
        // OAMDMA. `Bus` cannot handle $4014 itself -- see its doc comment --
        // because the 513-514 CPU cycles this burns have to flow through
        // this exact chokepoint (PPU ticking, NMI polling) like any other
        // cycle. Checked after the ordinary write above so `open_bus` still
        // updates first, same as every other write to this address.
        if (addr == 0x4014) self.runOamDma(value);
    }

    /// Advance the clock by one CPU cycle with no bus access: `tick` plus
    /// the same NMI re-snapshot/re-poll pair `read`/`write` perform around
    /// their own access, minus the access itself. Used for `step`'s jammed-
    /// CPU idle cycle and for `runOamDma`'s halt/alignment cycles, both of
    /// which burn CPU time with nothing semantically observable happening.
    fn idleCycle(self: *Cpu) void {
        self.tick();
        self.snapshotNmiReady();
        self.pollNmi();
    }

    /// OAMDMA ($4014): copy 256 bytes from $(page)00-$(page)FF into OAM
    /// through OAMDATA ($2004), exactly as if the CPU had done 256
    /// individual `STA $2004` writes -- so it honors and advances OAMADDR
    /// (`Ppu.writeRegister`'s existing $2004 case) as if it were still doing
    /// so, just far faster than any real game would loop it by hand. Costs
    /// 513 CPU cycles (1 halt cycle + 256 read/write pairs), or 514 if the
    /// triggering write landed on an odd CPU cycle (one extra alignment
    /// cycle before the first read) -- see https://www.nesdev.org/wiki/DMA.
    ///
    /// Driven entirely through `idleCycle`/`read`/`write`, so every cycle
    /// this burns still ticks the PPU 3 dots and polls NMI exactly like
    /// ordinary instruction execution -- a VBL NMI raised mid-DMA is
    /// serviced the moment `step` is next called, matching real hardware
    /// (which halts only the CPU's own bus activity, never the rest of the
    /// console).
    fn runOamDma(self: *Cpu, page: u8) void {
        // The alignment cycle comes *before* the halt cycle: it exists to
        // land the halt cycle itself on an even CPU cycle, which is what
        // lets the 256 read/write pairs that follow fall on the same
        // even/odd phase every time regardless of when $4014 was written.
        if (self.cycles % 2 == 1) self.idleCycle();
        self.idleCycle(); // the halt/"get" cycle -- always happens
        var i: u16 = 0;
        while (i < 256) : (i += 1) {
            const value = self.read((@as(u16, page) << 8) | i);
            self.write(0x2004, value);
        }
    }

    fn fetch(self: *Cpu) u8 {
        const v = self.read(self.pc);
        self.pc +%= 1;
        return v;
    }

    fn fetchWord(self: *Cpu) u16 {
        const lo = self.fetch();
        const hi = self.fetch();
        return (@as(u16, hi) << 8) | lo;
    }

    fn push(self: *Cpu, value: u8) void {
        self.write(0x0100 | @as(u16, self.s), value);
        self.s -%= 1;
    }

    fn pull(self: *Cpu) u8 {
        self.s +%= 1;
        return self.read(0x0100 | @as(u16, self.s));
    }

    /// Push P with the B flag forced to `b`. Bit 5 is always pushed as 1.
    fn pushP(self: *Cpu, b: bool) void {
        self.push(self.p.toByte() | (if (b) @as(u8, 0x30) else @as(u8, 0x20)));
    }

    // ----------------------------------------------------------- interrupts

    /// Drive the /NMI input. NMI is edge-triggered, so only the transition
    /// from de-asserted to asserted latches a pending interrupt.
    pub fn setNmiLine(self: *Cpu, asserted: bool) void {
        if (asserted and !self.nmi_line) self.nmi_pending = true;
        self.nmi_line = asserted;
    }

    /// Drive the CPU's own /IRQ input (level-triggered).
    pub fn setIrqLine(self: *Cpu, asserted: bool) void {
        self.irq_line = asserted;
    }

    /// The IRQ line as the CPU sees it: the wire-OR of every IRQ source on the
    /// bus. Today that is the CPU's own input plus the cartridge's — NROM
    /// never asserts, but MMC3's scanline IRQ (M7) will, and this is the only
    /// place that needs to change.
    fn irqAsserted(self: *const Cpu) bool {
        return self.irq_line or self.bus.mapper.irqPending();
    }

    const InterruptKind = enum { nmi, irq };

    /// The shared 7-cycle hardware interrupt sequence. Identical to BRK's
    /// except that (a) PC is not incremented past a signature byte and (b) P
    /// is pushed with B clear, which is the *only* way an interrupt handler
    /// can tell IRQ from BRK.
    fn serviceInterrupt(self: *Cpu, kind: InterruptKind) void {
        _ = self.read(self.pc); // 1: fetch opcode (discarded)
        _ = self.read(self.pc); // 2: read next byte (discarded), PC not incremented
        self.push(@truncate(self.pc >> 8)); // 3
        self.push(@truncate(self.pc)); // 4
        self.pushP(false); // 5: B clear — this is a hardware interrupt

        // Vector hijacking: the vector address is not decided until the fetch,
        // so an NMI that arrives during an IRQ sequence steals the vector.
        //
        // As of M1 this branch is unreachable, exactly like BRK's twin of it:
        // `step` clears `nmi_pending` before calling us with `.nmi`, and tests
        // it before ever reaching the `.irq` call, so it cannot be set here.
        // Interrupts are only dispatched at instruction boundaries. The logic
        // is written out so it is already correct in M2, when a cycle-stepped
        // core lets an NMI arrive part-way through this sequence.
        var vector: u16 = if (kind == .nmi) nmi_vector else irq_vector;
        if (self.nmi_pending) {
            vector = nmi_vector;
            self.nmi_pending = false;
        }

        // Deliberate deviation from the reference doc, which claims (in its
        // interrupt section) that NMI "does not affect" the I flag. That is
        // wrong for real 65xx silicon: the interrupt sequence sets I for NMI
        // just as it does for IRQ and BRK, and NES software relies on it --
        // an NMI handler that does not want to be re-entered by an IRQ would
        // otherwise have to set I itself. Keep this line.
        self.p.i = true;
        const lo = self.read(vector); // 6
        const hi = self.read(vector + 1); // 7
        self.pc = (@as(u16, hi) << 8) | lo;
    }

    /// The RESET sequence: 7 cycles, no writes. The three "pushes" are read
    /// cycles on a real chip (the write line is held inactive during reset),
    /// but S is still decremented three times — which is why a freshly reset
    /// NES has S = $FD rather than $00. Every register except PC survives.
    pub fn reset(self: *Cpu) void {
        // The PPU's own reset-cleared registers (PPUCTRL/PPUMASK/the $2005-
        // $2006 write toggle/the PPUDATA read buffer) take effect as soon as
        // /RESET is asserted on real hardware, before the CPU's own 7-cycle
        // sequence even begins -- see `Ppu.reset`'s doc comment for exactly
        // what does and does not survive.
        self.bus.ppu.reset();
        _ = self.read(self.pc); // 1
        _ = self.read(self.pc); // 2
        _ = self.read(0x0100 | @as(u16, self.s)); // 3
        self.s -%= 1;
        _ = self.read(0x0100 | @as(u16, self.s)); // 4
        self.s -%= 1;
        _ = self.read(0x0100 | @as(u16, self.s)); // 5
        self.s -%= 1;
        const lo = self.read(reset_vector); // 6
        const hi = self.read(reset_vector + 1); // 7
        self.pc = (@as(u16, hi) << 8) | lo;
        self.p.i = true;
        self.jammed = false;
        self.nmi_pending = false;
        self.nmi_ready = false;
        self.irq_ready = false;
        self.poll_i_override = null;
    }

    // ------------------------------------------------------------- stepping

    /// Run one instruction, or one interrupt sequence if one is due.
    ///
    /// IRQ is dispatched using the poll latched at the end of the previous
    /// instruction (see `irq_ready`), reproducing the one-instruction delay
    /// of `CLI`/`SEI`/`PLP`. NMI is dispatched from `nmi_ready`, which is
    /// re-derived every single *cycle* rather than once per instruction (see
    /// its doc comment) — since M2 the PPU can raise NMI from a write to
    /// $2000 on literally any cycle of any instruction, not just three named
    /// opcodes' final cycle, so a per-instruction-only latch can't cover it.
    /// What is still not modeled: an interrupt being *taken* mid-instruction
    /// (both kinds are only ever dispatched between whole instructions);
    /// that requires a fully cycle-stepped instruction interior, which
    /// nothing exercised by this milestone's test ROMs needs.
    pub fn step(self: *Cpu) void {
        if (self.jammed) {
            // A jammed core still consumes bus cycles, so this must go
            // through `tick` like every other cycle -- see `idleCycle`'s
            // doc comment. No bus access happens this cycle, but NMI state
            // is still re-derived for consistency with every other path (a
            // jammed CPU can never service it anyway -- only RESET
            // recovers from JAM).
            self.idleCycle();
            return;
        }

        if (self.nmi_ready) {
            self.nmi_ready = false;
            self.nmi_pending = false;
            self.serviceInterrupt(.nmi);
            self.latchInterruptPoll();
            return;
        }
        if (self.irq_ready) {
            self.serviceInterrupt(.irq);
            self.latchInterruptPoll();
            return;
        }

        const opcode = self.fetch();
        self.execute(opcode);
        self.latchInterruptPoll();
    }

    fn latchInterruptPoll(self: *Cpu) void {
        const i_at_poll = self.poll_i_override orelse self.p.i;
        self.poll_i_override = null;
        self.irq_ready = self.irqAsserted() and !i_at_poll;
    }

    // ------------------------------------------------------- addressing modes

    fn addrZeroPage(self: *Cpu) u16 {
        return self.fetch();
    }

    /// Zero-page indexed never leaves the zero page: the adder's carry out is
    /// discarded, so `$FF,X` with X=1 lands on `$0000`, not `$0100`. The
    /// discarded read at the un-indexed address is a real bus cycle.
    fn addrZeroPageIndexed(self: *Cpu, index: u8) u16 {
        const base = self.fetch();
        _ = self.read(base);
        return base +% index;
    }

    fn addrAbsolute(self: *Cpu) u16 {
        return self.fetchWord();
    }

    fn addrAbsoluteIndexed(self: *Cpu, index: u8, access: Access) u16 {
        const base = self.fetchWord();
        const eff = base +% index;
        const crossed = (base & 0xFF00) != (eff & 0xFF00);
        if (crossed or access != .read) {
            // The high byte of the address has not been fixed up yet, so this
            // read goes to the wrong page when the index carried.
            _ = self.read((base & 0xFF00) | (eff & 0x00FF));
        }
        return eff;
    }

    /// ($nn,X): the pointer is formed entirely inside the zero page — both the
    /// +X and the +1 for the high byte wrap at $FF.
    fn addrIndexedIndirect(self: *Cpu) u16 {
        const ptr = self.fetch();
        _ = self.read(ptr);
        const lo = self.read(ptr +% self.x);
        const hi = self.read(ptr +% self.x +% 1);
        return (@as(u16, hi) << 8) | lo;
    }

    /// ($nn),Y: the pointer read also wraps inside the zero page.
    fn addrIndirectIndexed(self: *Cpu, access: Access) u16 {
        const ptr = self.fetch();
        const lo = self.read(ptr);
        const hi = self.read(ptr +% 1);
        const base = (@as(u16, hi) << 8) | lo;
        const eff = base +% self.y;
        const crossed = (base & 0xFF00) != (eff & 0xFF00);
        if (crossed or access != .read) {
            _ = self.read((base & 0xFF00) | (eff & 0x00FF));
        }
        return eff;
    }

    const IndexedTarget = struct { base: u16, eff: u16, crossed: bool };

    /// Absolute,I for the unstable SH* stores, which need the *base* address's
    /// high byte (the value they AND with is `ADDR_HI + 1`).
    fn addrAbsoluteIndexedRaw(self: *Cpu, index: u8) IndexedTarget {
        const base = self.fetchWord();
        const eff = base +% index;
        const crossed = (base & 0xFF00) != (eff & 0xFF00);
        _ = self.read((base & 0xFF00) | (eff & 0x00FF));
        return .{ .base = base, .eff = eff, .crossed = crossed };
    }

    fn addrIndirectIndexedRaw(self: *Cpu) IndexedTarget {
        const ptr = self.fetch();
        const lo = self.read(ptr);
        const hi = self.read(ptr +% 1);
        const base = (@as(u16, hi) << 8) | lo;
        const eff = base +% self.y;
        const crossed = (base & 0xFF00) != (eff & 0xFF00);
        _ = self.read((base & 0xFF00) | (eff & 0x00FF));
        return .{ .base = base, .eff = eff, .crossed = crossed };
    }

    // --------------------------------------------------------------- helpers

    fn setZN(self: *Cpu, value: u8) void {
        self.p.z = value == 0;
        self.p.n = (value & 0x80) != 0;
    }

    /// Binary add-with-carry. Never decimal — see the type-level note.
    fn adc(self: *Cpu, value: u8) void {
        const sum: u16 = @as(u16, self.a) + @as(u16, value) + @intFromBool(self.p.c);
        const result: u8 = @truncate(sum);
        self.p.c = sum > 0xFF;
        // Signed overflow: both operands agreed on sign and the result didn't.
        self.p.v = ((self.a ^ result) & (value ^ result) & 0x80) != 0;
        self.a = result;
        self.setZN(result);
    }

    /// SBC is ADC of the one's complement — literally how the chip does it,
    /// with C acting as "no borrow".
    fn sbc(self: *Cpu, value: u8) void {
        self.adc(~value);
    }

    fn compare(self: *Cpu, reg: u8, value: u8) void {
        self.p.c = reg >= value;
        self.setZN(reg -% value);
    }

    fn bitTest(self: *Cpu, value: u8) void {
        self.p.z = (self.a & value) == 0;
        self.p.n = (value & 0x80) != 0;
        self.p.v = (value & 0x40) != 0;
    }

    fn branch(self: *Cpu, take: bool) void {
        const offset: i8 = @bitCast(self.fetch());
        if (!take) return;
        // Taken branches pre-fetch the next opcode before adjusting PC...
        _ = self.read(self.pc);
        const target = self.pc +% @as(u16, @bitCast(@as(i16, offset)));
        if ((target & 0xFF00) != (self.pc & 0xFF00)) {
            // ...and when only PCL was fixed, fetch again from the wrong page.
            _ = self.read((self.pc & 0xFF00) | (target & 0x00FF));
        }
        self.pc = target;
    }

    // ------------------------------------------------------ read-modify-write

    /// The NMOS read-modify-write bus signature: read, write the *unmodified*
    /// value back, then write the modified value. The middle write is not an
    /// optimization artifact — hardware registers latch on it (that is how
    /// `LSR $D019` acknowledges an interrupt on a C64, and how `INC $2007`
    /// double-writes on a NES).
    fn rmw(self: *Cpu, addr: u16, comptime operation: fn (*Cpu, u8) u8) void {
        const value = self.read(addr);
        self.write(addr, value);
        self.write(addr, operation(self, value));
    }

    fn opAsl(self: *Cpu, value: u8) u8 {
        self.p.c = (value & 0x80) != 0;
        const result = value << 1;
        self.setZN(result);
        return result;
    }

    fn opLsr(self: *Cpu, value: u8) u8 {
        self.p.c = (value & 0x01) != 0;
        const result = value >> 1;
        self.setZN(result);
        return result;
    }

    fn opRol(self: *Cpu, value: u8) u8 {
        const carry_in: u8 = @intFromBool(self.p.c);
        self.p.c = (value & 0x80) != 0;
        const result = (value << 1) | carry_in;
        self.setZN(result);
        return result;
    }

    fn opRor(self: *Cpu, value: u8) u8 {
        const carry_in: u8 = if (self.p.c) 0x80 else 0x00;
        self.p.c = (value & 0x01) != 0;
        const result = (value >> 1) | carry_in;
        self.setZN(result);
        return result;
    }

    fn opInc(self: *Cpu, value: u8) u8 {
        const result = value +% 1;
        self.setZN(result);
        return result;
    }

    fn opDec(self: *Cpu, value: u8) u8 {
        const result = value -% 1;
        self.setZN(result);
        return result;
    }

    // The six "combo" undocumented RMWs: an official RMW on memory, followed
    // by an official ALU op against A, both driven by the same bus sequence.
    fn opSlo(self: *Cpu, value: u8) u8 {
        const result = self.opAsl(value);
        self.a |= result;
        self.setZN(self.a);
        return result;
    }

    fn opRla(self: *Cpu, value: u8) u8 {
        const result = self.opRol(value);
        self.a &= result;
        self.setZN(self.a);
        return result;
    }

    fn opSre(self: *Cpu, value: u8) u8 {
        const result = self.opLsr(value);
        self.a ^= result;
        self.setZN(self.a);
        return result;
    }

    fn opRra(self: *Cpu, value: u8) u8 {
        const result = self.opRor(value);
        self.adc(result);
        return result;
    }

    fn opDcp(self: *Cpu, value: u8) u8 {
        const result = value -% 1;
        self.compare(self.a, result);
        return result;
    }

    fn opIsb(self: *Cpu, value: u8) u8 {
        const result = value +% 1;
        self.sbc(result);
        return result;
    }

    // ------------------------------------------------------------- execution

    /// Magic constant for the two unstable "immediate + X" opcodes ANE ($8B)
    /// and LXA ($AB). On real silicon the value ORed into A depends on the
    /// chip, its temperature, and what the video chip left on the bus; the
    /// reference doc gives $EE as the usual case on a 6510 and that is the
    /// value essentially every emulator settles on. Neither opcode is
    /// exercised by nestest.
    const unstable_magic: u8 = 0xEE;

    fn execute(self: *Cpu, opcode: u8) void {
        switch (opcode) {
            // ------------------------------------------------- control flow
            0x00 => { // BRK
                _ = self.fetch(); // signature byte, read and discarded
                self.push(@truncate(self.pc >> 8));
                self.push(@truncate(self.pc));
                self.pushP(true); // B set — this is a software interrupt
                var vector: u16 = irq_vector;
                // M2: this test is in the wrong place, and only harmlessly so
                // while interrupts are dispatched at instruction boundaries.
                // The doc puts the hijack window *before* the flags-saving
                // cycle ("if a hardware interrupt occurs before the fourth
                // (flags saving) cycle of BRK, the BRK instruction will be
                // skipped"), i.e. the decision must be latched before the
                // `pushP` above, not read after it. Today `nmi_pending` cannot
                // change across those two statements, so the two orderings are
                // equivalent; once a cycle-stepped core lets an NMI land
                // mid-instruction, an NMI arriving between `pushP` and here
                // would hijack when hardware would not. Move the latch above
                // `pushP` when making `step` cycle-accurate.
                if (self.nmi_pending) {
                    // NMI hijacks BRK's vector; the pushed B flag is the only
                    // trace left that a BRK ever happened. Note this branch is
                    // currently only reachable by calling `execute` directly:
                    // `step` polls at instruction boundaries, so an NMI that is
                    // already pending gets serviced before BRK is even fetched.
                    // The logic is here so it is already right when a
                    // cycle-stepped core (M2, once the PPU can raise NMI
                    // mid-instruction) makes the case real.
                    vector = nmi_vector;
                    self.nmi_pending = false;
                }
                self.p.i = true;
                const lo = self.read(vector);
                const hi = self.read(vector + 1);
                self.pc = (@as(u16, hi) << 8) | lo;
            },
            0x20 => { // JSR abs
                const lo = self.fetch();
                _ = self.read(0x0100 | @as(u16, self.s)); // internal, predecrement S
                // PC currently points at the high operand byte, which is
                // exactly the "return address minus one" RTS expects.
                self.push(@truncate(self.pc >> 8));
                self.push(@truncate(self.pc));
                const hi = self.read(self.pc);
                self.pc = (@as(u16, hi) << 8) | lo;
            },
            0x40 => { // RTI
                _ = self.read(self.pc);
                _ = self.read(0x0100 | @as(u16, self.s));
                self.p = Flags.fromByte(self.pull());
                const lo = self.pull();
                const hi = self.pull();
                self.pc = (@as(u16, hi) << 8) | lo;
                // Note: unlike PLP, RTI's I-flag change *is* visible to the
                // interrupt poll immediately, so no poll_i_override here.
            },
            0x60 => { // RTS
                _ = self.read(self.pc);
                _ = self.read(0x0100 | @as(u16, self.s));
                const lo = self.pull();
                const hi = self.pull();
                self.pc = (@as(u16, hi) << 8) | lo;
                _ = self.read(self.pc);
                self.pc +%= 1;
            },
            0x4C => self.pc = self.addrAbsolute(), // JMP abs
            0x6C => { // JMP (abs) — the NMOS indirect page bug
                const ptr = self.fetchWord();
                const lo = self.read(ptr);
                // The pointer increment never carries into the high byte, so
                // JMP ($10FF) reads its high byte from $1000, not $1100.
                const hi = self.read((ptr & 0xFF00) | ((ptr +% 1) & 0x00FF));
                self.pc = (@as(u16, hi) << 8) | lo;
            },

            // -------------------------------------------------------- branches
            0x10 => self.branch(!self.p.n), // BPL
            0x30 => self.branch(self.p.n), // BMI
            0x50 => self.branch(!self.p.v), // BVC
            0x70 => self.branch(self.p.v), // BVS
            0x90 => self.branch(!self.p.c), // BCC
            0xB0 => self.branch(self.p.c), // BCS
            0xD0 => self.branch(!self.p.z), // BNE
            0xF0 => self.branch(self.p.z), // BEQ

            // ----------------------------------------------------------- stack
            0x08 => { // PHP — always pushes B set
                _ = self.read(self.pc);
                self.pushP(true);
            },
            0x28 => { // PLP
                _ = self.read(self.pc);
                _ = self.read(0x0100 | @as(u16, self.s));
                self.poll_i_override = self.p.i; // I change lands after the poll
                self.p = Flags.fromByte(self.pull());
            },
            0x48 => { // PHA
                _ = self.read(self.pc);
                self.push(self.a);
            },
            0x68 => { // PLA
                _ = self.read(self.pc);
                _ = self.read(0x0100 | @as(u16, self.s));
                self.a = self.pull();
                self.setZN(self.a);
            },

            // -------------------------------------------------- flag set/clear
            0x18 => {
                _ = self.read(self.pc);
                self.p.c = false;
            }, // CLC
            0x38 => {
                _ = self.read(self.pc);
                self.p.c = true;
            }, // SEC
            0x58 => { // CLI
                _ = self.read(self.pc);
                self.poll_i_override = self.p.i;
                self.p.i = false;
            },
            0x78 => { // SEI
                _ = self.read(self.pc);
                self.poll_i_override = self.p.i;
                self.p.i = true;
            },
            0xB8 => {
                _ = self.read(self.pc);
                self.p.v = false;
            }, // CLV
            0xD8 => {
                _ = self.read(self.pc);
                self.p.d = false;
            }, // CLD — D still toggles, it just has no effect on the 2A03
            0xF8 => {
                _ = self.read(self.pc);
                self.p.d = true;
            }, // SED

            // ------------------------------------------------------ transfers
            0xAA => {
                _ = self.read(self.pc);
                self.x = self.a;
                self.setZN(self.x);
            }, // TAX
            0xA8 => {
                _ = self.read(self.pc);
                self.y = self.a;
                self.setZN(self.y);
            }, // TAY
            0x8A => {
                _ = self.read(self.pc);
                self.a = self.x;
                self.setZN(self.a);
            }, // TXA
            0x98 => {
                _ = self.read(self.pc);
                self.a = self.y;
                self.setZN(self.a);
            }, // TYA
            0xBA => {
                _ = self.read(self.pc);
                self.x = self.s;
                self.setZN(self.x);
            }, // TSX
            0x9A => {
                _ = self.read(self.pc);
                self.s = self.x; // TXS is not an arithmetic op: no flags
            },

            // ------------------------------------------------- inc/dec on regs
            0xE8 => {
                _ = self.read(self.pc);
                self.x +%= 1;
                self.setZN(self.x);
            }, // INX
            0xC8 => {
                _ = self.read(self.pc);
                self.y +%= 1;
                self.setZN(self.y);
            }, // INY
            0xCA => {
                _ = self.read(self.pc);
                self.x -%= 1;
                self.setZN(self.x);
            }, // DEX
            0x88 => {
                _ = self.read(self.pc);
                self.y -%= 1;
                self.setZN(self.y);
            }, // DEY

            // ------------------------------------------------------------ NOPs
            // Official NOP plus the seven undocumented implied NOPs.
            0xEA, 0x1A, 0x3A, 0x5A, 0x7A, 0xDA, 0xFA => _ = self.read(self.pc),
            // Undocumented immediate NOPs (two bytes, operand discarded).
            0x80, 0x82, 0x89, 0xC2, 0xE2 => _ = self.fetch(),
            // Undocumented NOPs that still perform their memory read — the
            // read is externally visible (it can hit a PPU register), so it
            // must actually happen.
            0x04, 0x44, 0x64 => _ = self.read(self.addrZeroPage()),
            0x14, 0x34, 0x54, 0x74, 0xD4, 0xF4 => _ = self.read(self.addrZeroPageIndexed(self.x)),
            0x0C => _ = self.read(self.addrAbsolute()),
            0x1C, 0x3C, 0x5C, 0x7C, 0xDC, 0xFC => _ = self.read(self.addrAbsoluteIndexed(self.x, .read)),

            // ------------------------------------------------------------- ORA
            0x09 => {
                self.a |= self.fetch();
                self.setZN(self.a);
            },
            0x05, 0x15, 0x0D, 0x1D, 0x19, 0x01, 0x11 => {
                const addr = self.loadAddr(opcode, .read);
                self.a |= self.read(addr);
                self.setZN(self.a);
            },

            // ------------------------------------------------------------- AND
            0x29 => {
                self.a &= self.fetch();
                self.setZN(self.a);
            },
            0x25, 0x35, 0x2D, 0x3D, 0x39, 0x21, 0x31 => {
                const addr = self.loadAddr(opcode, .read);
                self.a &= self.read(addr);
                self.setZN(self.a);
            },

            // ------------------------------------------------------------- EOR
            0x49 => {
                self.a ^= self.fetch();
                self.setZN(self.a);
            },
            0x45, 0x55, 0x4D, 0x5D, 0x59, 0x41, 0x51 => {
                const addr = self.loadAddr(opcode, .read);
                self.a ^= self.read(addr);
                self.setZN(self.a);
            },

            // ------------------------------------------------------------- ADC
            0x69 => self.adc(self.fetch()),
            0x65, 0x75, 0x6D, 0x7D, 0x79, 0x61, 0x71 => {
                const addr = self.loadAddr(opcode, .read);
                self.adc(self.read(addr));
            },

            // ------------------------------------------------ SBC ($EB is the
            // undocumented duplicate; on the NMOS core it is bit-identical)
            0xE9, 0xEB => self.sbc(self.fetch()),
            0xE5, 0xF5, 0xED, 0xFD, 0xF9, 0xE1, 0xF1 => {
                const addr = self.loadAddr(opcode, .read);
                self.sbc(self.read(addr));
            },

            // ------------------------------------------------------------- CMP
            0xC9 => self.compare(self.a, self.fetch()),
            0xC5, 0xD5, 0xCD, 0xDD, 0xD9, 0xC1, 0xD1 => {
                const addr = self.loadAddr(opcode, .read);
                self.compare(self.a, self.read(addr));
            },
            0xE0 => self.compare(self.x, self.fetch()), // CPX #
            0xE4 => self.compare(self.x, self.read(self.addrZeroPage())),
            0xEC => self.compare(self.x, self.read(self.addrAbsolute())),
            0xC0 => self.compare(self.y, self.fetch()), // CPY #
            0xC4 => self.compare(self.y, self.read(self.addrZeroPage())),
            0xCC => self.compare(self.y, self.read(self.addrAbsolute())),

            // ------------------------------------------------------------- BIT
            0x24 => self.bitTest(self.read(self.addrZeroPage())),
            0x2C => self.bitTest(self.read(self.addrAbsolute())),

            // ------------------------------------------------------------- LDA
            0xA9 => {
                self.a = self.fetch();
                self.setZN(self.a);
            },
            0xA5, 0xB5, 0xAD, 0xBD, 0xB9, 0xA1, 0xB1 => {
                const addr = self.loadAddr(opcode, .read);
                self.a = self.read(addr);
                self.setZN(self.a);
            },

            // ------------------------------------------------------------- LDX
            0xA2 => {
                self.x = self.fetch();
                self.setZN(self.x);
            },
            0xA6 => {
                self.x = self.read(self.addrZeroPage());
                self.setZN(self.x);
            },
            0xB6 => {
                self.x = self.read(self.addrZeroPageIndexed(self.y));
                self.setZN(self.x);
            },
            0xAE => {
                self.x = self.read(self.addrAbsolute());
                self.setZN(self.x);
            },
            0xBE => {
                self.x = self.read(self.addrAbsoluteIndexed(self.y, .read));
                self.setZN(self.x);
            },

            // ------------------------------------------------------------- LDY
            0xA0 => {
                self.y = self.fetch();
                self.setZN(self.y);
            },
            0xA4 => {
                self.y = self.read(self.addrZeroPage());
                self.setZN(self.y);
            },
            0xB4 => {
                self.y = self.read(self.addrZeroPageIndexed(self.x));
                self.setZN(self.y);
            },
            0xAC => {
                self.y = self.read(self.addrAbsolute());
                self.setZN(self.y);
            },
            0xBC => {
                self.y = self.read(self.addrAbsoluteIndexed(self.x, .read));
                self.setZN(self.y);
            },

            // ------------------------------------------------------------ STA
            0x85, 0x95, 0x8D, 0x9D, 0x99, 0x81, 0x91 => {
                const addr = self.loadAddr(opcode, .write);
                self.write(addr, self.a);
            },
            // ------------------------------------------------------------ STX
            0x86 => self.write(self.addrZeroPage(), self.x),
            0x96 => self.write(self.addrZeroPageIndexed(self.y), self.x),
            0x8E => self.write(self.addrAbsolute(), self.x),
            // ------------------------------------------------------------ STY
            0x84 => self.write(self.addrZeroPage(), self.y),
            0x94 => self.write(self.addrZeroPageIndexed(self.x), self.y),
            0x8C => self.write(self.addrAbsolute(), self.y),

            // ------------------------------------------- shifts/rotates on A
            0x0A => {
                _ = self.read(self.pc);
                self.a = self.opAsl(self.a);
            },
            0x2A => {
                _ = self.read(self.pc);
                self.a = self.opRol(self.a);
            },
            0x4A => {
                _ = self.read(self.pc);
                self.a = self.opLsr(self.a);
            },
            0x6A => {
                _ = self.read(self.pc);
                self.a = self.opRor(self.a);
            },

            // ------------------------------------------ shifts/rotates on mem
            0x06 => self.rmw(self.addrZeroPage(), opAsl),
            0x16 => self.rmw(self.addrZeroPageIndexed(self.x), opAsl),
            0x0E => self.rmw(self.addrAbsolute(), opAsl),
            0x1E => self.rmw(self.addrAbsoluteIndexed(self.x, .rmw), opAsl),

            0x26 => self.rmw(self.addrZeroPage(), opRol),
            0x36 => self.rmw(self.addrZeroPageIndexed(self.x), opRol),
            0x2E => self.rmw(self.addrAbsolute(), opRol),
            0x3E => self.rmw(self.addrAbsoluteIndexed(self.x, .rmw), opRol),

            0x46 => self.rmw(self.addrZeroPage(), opLsr),
            0x56 => self.rmw(self.addrZeroPageIndexed(self.x), opLsr),
            0x4E => self.rmw(self.addrAbsolute(), opLsr),
            0x5E => self.rmw(self.addrAbsoluteIndexed(self.x, .rmw), opLsr),

            0x66 => self.rmw(self.addrZeroPage(), opRor),
            0x76 => self.rmw(self.addrZeroPageIndexed(self.x), opRor),
            0x6E => self.rmw(self.addrAbsolute(), opRor),
            0x7E => self.rmw(self.addrAbsoluteIndexed(self.x, .rmw), opRor),

            // ------------------------------------------------------- INC/DEC
            0xE6 => self.rmw(self.addrZeroPage(), opInc),
            0xF6 => self.rmw(self.addrZeroPageIndexed(self.x), opInc),
            0xEE => self.rmw(self.addrAbsolute(), opInc),
            0xFE => self.rmw(self.addrAbsoluteIndexed(self.x, .rmw), opInc),

            0xC6 => self.rmw(self.addrZeroPage(), opDec),
            0xD6 => self.rmw(self.addrZeroPageIndexed(self.x), opDec),
            0xCE => self.rmw(self.addrAbsolute(), opDec),
            0xDE => self.rmw(self.addrAbsoluteIndexed(self.x, .rmw), opDec),

            // ============================ undocumented ============================

            // LAX: load A and X from the same bus cycle.
            0xA7 => self.lax(self.read(self.addrZeroPage())),
            0xB7 => self.lax(self.read(self.addrZeroPageIndexed(self.y))),
            0xAF => self.lax(self.read(self.addrAbsolute())),
            0xBF => self.lax(self.read(self.addrAbsoluteIndexed(self.y, .read))),
            0xA3 => self.lax(self.read(self.addrIndexedIndirect())),
            0xB3 => self.lax(self.read(self.addrIndirectIndexed(.read))),

            // SAX: store A AND X, done by the open-collector drivers, so no
            // flags are touched.
            0x87 => self.write(self.addrZeroPage(), self.a & self.x),
            0x97 => self.write(self.addrZeroPageIndexed(self.y), self.a & self.x),
            0x8F => self.write(self.addrAbsolute(), self.a & self.x),
            0x83 => self.write(self.addrIndexedIndirect(), self.a & self.x),

            // SLO / RLA / SRE / RRA / DCP / ISB: RMW + ALU combos.
            0x07 => self.rmw(self.addrZeroPage(), opSlo),
            0x17 => self.rmw(self.addrZeroPageIndexed(self.x), opSlo),
            0x0F => self.rmw(self.addrAbsolute(), opSlo),
            0x1F => self.rmw(self.addrAbsoluteIndexed(self.x, .rmw), opSlo),
            0x1B => self.rmw(self.addrAbsoluteIndexed(self.y, .rmw), opSlo),
            0x03 => self.rmw(self.addrIndexedIndirect(), opSlo),
            0x13 => self.rmw(self.addrIndirectIndexed(.rmw), opSlo),

            0x27 => self.rmw(self.addrZeroPage(), opRla),
            0x37 => self.rmw(self.addrZeroPageIndexed(self.x), opRla),
            0x2F => self.rmw(self.addrAbsolute(), opRla),
            0x3F => self.rmw(self.addrAbsoluteIndexed(self.x, .rmw), opRla),
            0x3B => self.rmw(self.addrAbsoluteIndexed(self.y, .rmw), opRla),
            0x23 => self.rmw(self.addrIndexedIndirect(), opRla),
            0x33 => self.rmw(self.addrIndirectIndexed(.rmw), opRla),

            0x47 => self.rmw(self.addrZeroPage(), opSre),
            0x57 => self.rmw(self.addrZeroPageIndexed(self.x), opSre),
            0x4F => self.rmw(self.addrAbsolute(), opSre),
            0x5F => self.rmw(self.addrAbsoluteIndexed(self.x, .rmw), opSre),
            0x5B => self.rmw(self.addrAbsoluteIndexed(self.y, .rmw), opSre),
            0x43 => self.rmw(self.addrIndexedIndirect(), opSre),
            0x53 => self.rmw(self.addrIndirectIndexed(.rmw), opSre),

            0x67 => self.rmw(self.addrZeroPage(), opRra),
            0x77 => self.rmw(self.addrZeroPageIndexed(self.x), opRra),
            0x6F => self.rmw(self.addrAbsolute(), opRra),
            0x7F => self.rmw(self.addrAbsoluteIndexed(self.x, .rmw), opRra),
            0x7B => self.rmw(self.addrAbsoluteIndexed(self.y, .rmw), opRra),
            0x63 => self.rmw(self.addrIndexedIndirect(), opRra),
            0x73 => self.rmw(self.addrIndirectIndexed(.rmw), opRra),

            0xC7 => self.rmw(self.addrZeroPage(), opDcp),
            0xD7 => self.rmw(self.addrZeroPageIndexed(self.x), opDcp),
            0xCF => self.rmw(self.addrAbsolute(), opDcp),
            0xDF => self.rmw(self.addrAbsoluteIndexed(self.x, .rmw), opDcp),
            0xDB => self.rmw(self.addrAbsoluteIndexed(self.y, .rmw), opDcp),
            0xC3 => self.rmw(self.addrIndexedIndirect(), opDcp),
            0xD3 => self.rmw(self.addrIndirectIndexed(.rmw), opDcp),

            0xE7 => self.rmw(self.addrZeroPage(), opIsb),
            0xF7 => self.rmw(self.addrZeroPageIndexed(self.x), opIsb),
            0xEF => self.rmw(self.addrAbsolute(), opIsb),
            0xFF => self.rmw(self.addrAbsoluteIndexed(self.x, .rmw), opIsb),
            0xFB => self.rmw(self.addrAbsoluteIndexed(self.y, .rmw), opIsb),
            0xE3 => self.rmw(self.addrIndexedIndirect(), opIsb),
            0xF3 => self.rmw(self.addrIndirectIndexed(.rmw), opIsb),

            // ANC: AND #imm, then copy bit 7 of the result into C. The ALU's
            // carry output happens to be wired to the same net as N here.
            0x0B, 0x2B => {
                self.a &= self.fetch();
                self.setZN(self.a);
                self.p.c = self.p.n;
            },

            // ASR (a.k.a. ALR): AND #imm, then LSR A.
            0x4B => {
                self.a &= self.fetch();
                self.a = self.opLsr(self.a);
            },

            // ARR: AND #imm, then ROR A — but the ADC half of the chip is
            // still connected, so C and V come out of the *adder*, not the
            // shifter. C is bit 6 of the result and V is bit6 XOR bit5.
            // (Binary mode only; the doc's decimal-mode ARR fixup does not
            // apply on the 2A03.)
            0x6B => {
                self.a &= self.fetch();
                const carry_in: u8 = if (self.p.c) 0x80 else 0x00;
                self.a = (self.a >> 1) | carry_in;
                self.setZN(self.a);
                self.p.c = (self.a & 0x40) != 0;
                self.p.v = (((self.a >> 6) ^ (self.a >> 5)) & 0x01) != 0;
            },

            // SBX: X = (A & X) - #imm, using the *comparison* datapath — so
            // the incoming carry is ignored, C is set like CMP, and V is
            // untouched.
            0xCB => {
                const operand = self.fetch();
                const lhs = self.a & self.x;
                self.p.c = lhs >= operand;
                self.x = lhs -% operand;
                self.setZN(self.x);
            },

            // ANE / LXA: genuinely unstable. See `unstable_magic`.
            0x8B => { // ANE: A = (A | $EE) & X & imm, the doc's usual case.
                self.a = (self.a | unstable_magic) & self.x & self.fetch();
                self.setZN(self.a);
            },
            0xAB => { // LXA
                // Deliberate deviation from the reference doc. The doc gives
                // $AB's usual case as "A = X = ANE", i.e. including `& X`
                // (see its ANE/LXA section: "the most usual operation is to
                // store ((A | #$ee) & X & #$nn)"), and lists `A = X = A & imm`
                // as the other observed behavior. We implement
                // `A = X = (A | $EE) & imm` -- no `& X` -- which is the
                // convention essentially every NES emulator settles on, and
                // which sits between the doc's two variants.
                //
                // The opcode is unstable on real silicon regardless (the OR
                // value depends on chip revision, temperature, and what the
                // video chip left on the bus), no NES software depends on it,
                // and nestest never executes it. Do not "fix" this back to
                // match the doc without a test ROM that actually pins it down.
                self.a = (self.a | unstable_magic) & self.fetch();
                self.x = self.a;
                self.setZN(self.a);
            },

            // LAS: A = X = S = memory AND S.
            0xBB => {
                const value = self.read(self.addrAbsoluteIndexed(self.y, .read)) & self.s;
                self.a = value;
                self.x = value;
                self.s = value;
                self.setZN(value);
            },

            // SHA / SHX / SHY / SHS: store `reg & (high byte of base + 1)`.
            // When the index carries into the high byte the AND result also
            // replaces the address's high byte — the same internal bus that
            // computes the value is feeding the address latch. Unstable on
            // hardware (a DMA at the wrong moment drops the AND); this is the
            // commonly-emulated deterministic model.
            0x9F => { // SHA abs,Y
                const t = self.addrAbsoluteIndexedRaw(self.y);
                self.storeHigh(t, self.a & self.x);
            },
            0x93 => { // SHA (ind),Y
                const t = self.addrIndirectIndexedRaw();
                self.storeHigh(t, self.a & self.x);
            },
            0x9E => { // SHX abs,Y
                const t = self.addrAbsoluteIndexedRaw(self.y);
                self.storeHigh(t, self.x);
            },
            0x9C => { // SHY abs,X
                const t = self.addrAbsoluteIndexedRaw(self.x);
                self.storeHigh(t, self.y);
            },
            0x9B => { // SHS (a.k.a. TAS): S = A & X, then SHA
                const t = self.addrAbsoluteIndexedRaw(self.y);
                self.s = self.a & self.x;
                self.storeHigh(t, self.s);
            },

            // JAM: the twelve opcodes that halt the CPU with the address bus
            // floating. Only RESET recovers. Modeled as a sticky halt rather
            // than a panic so a misbehaving ROM does not take the emulator
            // down with it; nestest never executes one.
            0x02, 0x12, 0x22, 0x32, 0x42, 0x52, 0x62, 0x72, 0x92, 0xB2, 0xD2, 0xF2 => {
                _ = self.read(self.pc);
                self.pc -%= 1; // the opcode fetch is retried forever
                self.jammed = true;
            },
        }
    }

    fn lax(self: *Cpu, value: u8) void {
        self.a = value;
        self.x = value;
        self.setZN(value);
    }

    /// Final store step shared by SHA/SHX/SHY/SHS.
    fn storeHigh(self: *Cpu, target: IndexedTarget, value_reg: u8) void {
        const value = value_reg & (@as(u8, @truncate(target.base >> 8)) +% 1);
        const addr = if (target.crossed)
            (@as(u16, value) << 8) | (target.eff & 0x00FF)
        else
            target.eff;
        self.write(addr, value);
    }

    /// Resolve the addressing mode for the "ALU column" opcodes, whose low
    /// nibble encodes the mode uniformly across the whole matrix
    /// (ORA/AND/EOR/ADC/STA/LDA/CMP/SBC).
    fn loadAddr(self: *Cpu, opcode: u8, access: Access) u16 {
        return switch (opcode & 0x1F) {
            0x01 => self.addrIndexedIndirect(),
            0x05 => self.addrZeroPage(),
            0x0D => self.addrAbsolute(),
            0x11 => self.addrIndirectIndexed(access),
            0x15 => self.addrZeroPageIndexed(self.x),
            0x19 => self.addrAbsoluteIndexed(self.y, access),
            0x1D => self.addrAbsoluteIndexed(self.x, access),
            else => unreachable,
        };
    }

    // ---------------------------------------------------------------- tracing

    /// A snapshot of everything the Nintendulator-format trace log records,
    /// taken *before* an instruction executes.
    pub const Trace = struct {
        pc: u16,
        opcode: u8,
        operands: [2]u8,
        length: u2,
        a: u8,
        x: u8,
        y: u8,
        p: u8,
        s: u8,
        cycles: u64,

        pub fn mnemonic(self: Trace) []const u8 {
            return opcodes[self.opcode].mnemonic;
        }
    };

    /// Capture the current architectural state without perturbing it. Uses
    /// `Bus.peek`, so tracing is free of side effects even when PC happens to
    /// point at a hardware register.
    pub fn trace(self: *const Cpu) Trace {
        const opcode = self.bus.peek(self.pc);
        const len = opcodes[opcode].mode.length();
        return .{
            .pc = self.pc,
            .opcode = opcode,
            .operands = .{
                if (len > 1) self.bus.peek(self.pc +% 1) else 0,
                if (len > 2) self.bus.peek(self.pc +% 2) else 0,
            },
            .length = len,
            .a = self.a,
            .x = self.x,
            .y = self.y,
            .p = self.p.toByte(),
            .s = self.s,
            .cycles = self.cycles,
        };
    }
};

// ============================== tests ==============================

const TestHarness = struct {
    prg: [0x8000]u8,
    bus: Bus,
    cpu: Cpu,

    /// Assemble `code` at $C000 (mid-PRG) with the reset vector pointing at
    /// it, then run reset so the CPU starts in a realistic post-boot state.
    fn init(self: *TestHarness, code: []const u8) void {
        self.initWith(code, .nrom);
    }

    /// Same, but installs `mapper.TestStub` instead of NROM, so a test can
    /// drive the cartridge IRQ line or read back the exact PRG writes an
    /// instruction emitted. Everything else is identical.
    fn initStub(self: *TestHarness, code: []const u8) void {
        self.initWith(code, .test_stub);
    }

    fn initWith(self: *TestHarness, code: []const u8, comptime which: enum { nrom, test_stub }) void {
        self.prg = [_]u8{0} ** 0x8000;
        @memcpy(self.prg[0x4000..][0..code.len], code); // $C000
        self.prg[0x7FFC] = 0x00; // reset vector low  ($FFFC)
        self.prg[0x7FFD] = 0xC0; // reset vector high ($FFFD)
        self.bus = Bus.init(switch (which) {
            .nrom => Mapper{ .nrom = Nrom.init(&self.prg, &.{}) },
            .test_stub => Mapper{ .test_stub = TestStub.init(&self.prg) },
        }, .horizontal);
        self.cpu = Cpu.init(&self.bus);
        self.cpu.reset();
        self.cpu.cycles = 0;
    }

    fn stepN(self: *TestHarness, n: usize) void {
        for (0..n) |_| self.cpu.step();
    }
};

test "reset takes 7 cycles, leaves S at $FD, and loads the reset vector" {
    var h: TestHarness = undefined;
    h.init(&[_]u8{0xEA});
    // init() zeroes `cycles` after reset, so re-run reset to measure it.
    h.cpu.s = 0x00;
    h.cpu.cycles = 0;
    h.cpu.reset();
    try testing.expectEqual(@as(u64, 7), h.cpu.cycles);
    try testing.expectEqual(@as(u8, 0xFD), h.cpu.s);
    try testing.expectEqual(@as(u16, 0xC000), h.cpu.pc);
    try testing.expect(h.cpu.p.i);
}

test "implied and immediate instructions take 2 cycles" {
    var h: TestHarness = undefined;
    h.init(&[_]u8{ 0xEA, 0xA9, 0x42 }); // NOP ; LDA #$42
    h.stepN(2);
    try testing.expectEqual(@as(u64, 4), h.cpu.cycles);
    try testing.expectEqual(@as(u8, 0x42), h.cpu.a);
}

test "absolute,X read costs an extra cycle only when the page is crossed" {
    var h: TestHarness = undefined;
    // LDA $C0FF,X with X=$01 crosses; with X=$00 it does not.
    h.init(&[_]u8{ 0xBD, 0xFF, 0xC0 });
    h.cpu.x = 0x00;
    h.cpu.step();
    try testing.expectEqual(@as(u64, 4), h.cpu.cycles);

    h.init(&[_]u8{ 0xBD, 0xFF, 0xC0 });
    h.cpu.x = 0x01;
    h.cpu.step();
    try testing.expectEqual(@as(u64, 5), h.cpu.cycles);
}

test "absolute,X write always costs 5 cycles, page cross or not" {
    var h: TestHarness = undefined;
    h.init(&[_]u8{ 0x9D, 0x00, 0x02 }); // STA $0200,X
    h.cpu.x = 0x00;
    h.cpu.a = 0x5A;
    h.cpu.step();
    try testing.expectEqual(@as(u64, 5), h.cpu.cycles);
    try testing.expectEqual(@as(u8, 0x5A), h.bus.wram[0x0200]);

    // The half that matters: a write cannot be un-done, so the CPU always
    // performs the dummy read at the un-fixed address and the cost stays 5
    // even when the index carries. (A read would have paid 4 vs 5 here.)
    h.init(&[_]u8{ 0x9D, 0xFF, 0x02 }); // STA $02FF,X
    h.cpu.x = 0x01; // -> $0300, page crossed
    h.cpu.a = 0xA5;
    h.cpu.step();
    try testing.expectEqual(@as(u64, 5), h.cpu.cycles);
    try testing.expectEqual(@as(u8, 0xA5), h.bus.wram[0x0300]);
    try testing.expectEqual(@as(u8, 0x00), h.bus.wram[0x0200]); // not the un-fixed address
}

test "zero-page indexed addressing wraps inside the zero page" {
    var h: TestHarness = undefined;
    h.init(&[_]u8{ 0xB5, 0xFF }); // LDA $FF,X
    h.cpu.x = 0x02;
    h.bus.wram[0x0001] = 0x5A; // $FF + 2 wraps to $01, not $0101
    h.bus.wram[0x0101] = 0xA5;
    h.cpu.step();
    try testing.expectEqual(@as(u8, 0x5A), h.cpu.a);
    try testing.expectEqual(@as(u64, 4), h.cpu.cycles);
}

test "(indirect,X) builds its pointer entirely inside the zero page" {
    var h: TestHarness = undefined;
    h.init(&[_]u8{ 0xA1, 0xFF }); // LDA ($FF,X)
    h.cpu.x = 0x01;
    h.bus.wram[0x0000] = 0x34; // pointer low  at $00 ($FF + 1)
    h.bus.wram[0x0001] = 0x02; // pointer high at $01
    h.bus.wram[0x0234] = 0x77;
    h.cpu.step();
    try testing.expectEqual(@as(u8, 0x77), h.cpu.a);
    try testing.expectEqual(@as(u64, 6), h.cpu.cycles);
}

test "(indirect),Y reads its pointer with zero-page wraparound" {
    var h: TestHarness = undefined;
    h.init(&[_]u8{ 0xB1, 0xFF }); // LDA ($FF),Y
    h.cpu.y = 0x01;
    h.bus.wram[0x00FF] = 0x00; // pointer low  at $FF
    h.bus.wram[0x0000] = 0x03; // pointer high wraps to $00
    h.bus.wram[0x0301] = 0x99;
    h.cpu.step();
    try testing.expectEqual(@as(u8, 0x99), h.cpu.a);
    try testing.expectEqual(@as(u64, 5), h.cpu.cycles);
}

test "JMP (indirect) does not carry the pointer into the next page" {
    var h: TestHarness = undefined;
    var code = [_]u8{ 0x6C, 0xFF, 0xC1 }; // JMP ($C1FF)
    h.init(&code);
    h.prg[0x41FF] = 0x34; // $C1FF -> PCL
    h.prg[0x4100] = 0x12; // $C100 -> PCH (the bug: not $C200)
    h.cpu.step();
    try testing.expectEqual(@as(u16, 0x1234), h.cpu.pc);
    try testing.expectEqual(@as(u64, 5), h.cpu.cycles);
}

test "taken branches cost +1, and +2 when they cross a page" {
    var h: TestHarness = undefined;
    h.init(&[_]u8{ 0xB0, 0x02, 0xEA, 0xEA }); // BCS +2
    h.cpu.p.c = false;
    h.cpu.step();
    try testing.expectEqual(@as(u64, 2), h.cpu.cycles); // not taken

    h.init(&[_]u8{ 0xB0, 0x02 });
    h.cpu.p.c = true;
    h.cpu.step();
    try testing.expectEqual(@as(u64, 3), h.cpu.cycles); // taken, same page
    try testing.expectEqual(@as(u16, 0xC004), h.cpu.pc);

    // The crossing case the name promises. Place the branch at $C0FD so the
    // target lands in the next page: the CPU fixes PCL first, pre-fetches from
    // the wrong page, and only then fixes PCH -- a fourth cycle.
    h.init(&[_]u8{});
    h.prg[0x40FD] = 0xB0; // BCS at $C0FD
    h.prg[0x40FE] = 0x7F; // +127
    h.cpu.pc = 0xC0FD;
    h.cpu.cycles = 0;
    h.cpu.p.c = true;
    h.cpu.step();
    try testing.expectEqual(@as(u64, 4), h.cpu.cycles); // taken, page crossed
    try testing.expectEqual(@as(u16, 0xC17E), h.cpu.pc); // $C0FF + $7F

    // ...and a not-taken branch pays nothing extra even at the same spot.
    h.init(&[_]u8{});
    h.prg[0x40FD] = 0xB0;
    h.prg[0x40FE] = 0x7F;
    h.cpu.pc = 0xC0FD;
    h.cpu.cycles = 0;
    h.cpu.p.c = false;
    h.cpu.step();
    try testing.expectEqual(@as(u64, 2), h.cpu.cycles);
    try testing.expectEqual(@as(u16, 0xC0FF), h.cpu.pc);
}

test "RMW writes the unmodified value back before the modified one" {
    var h: TestHarness = undefined;
    h.init(&[_]u8{ 0xE6, 0x10 }); // INC $10
    h.bus.wram[0x0010] = 0x41;
    h.cpu.step();
    try testing.expectEqual(@as(u8, 0x42), h.bus.wram[0x0010]);
    try testing.expectEqual(@as(u64, 5), h.cpu.cycles);
}

test "the RMW dummy write carries the unmodified value, not the modified one" {
    // The cycle count above proves a middle write *happened*; it cannot prove
    // what that write carried. An implementation that wrote the modified value
    // twice would pass it — and would silently break every hardware register
    // that latches on the first write (the `LSR $D019` interrupt-acknowledge
    // trick on a C64, `INC $2007` on a NES). WRAM cannot show the difference,
    // since both writes land on the same byte, so drive the RMW at PRG space
    // and read the log off the test-double mapper.
    var h: TestHarness = undefined;
    h.initStub(&[_]u8{ 0xEE, 0x00, 0x80 }); // INC $8000
    h.prg[0x0000] = 0x41; // $8000 reads back $41
    h.cpu.step();

    const stub = &h.bus.mapper.test_stub;
    try testing.expectEqual(@as(usize, 2), stub.write_count);
    try testing.expectEqual(@as(u16, 0x8000), stub.writes[0].addr);
    try testing.expectEqual(@as(u8, 0x41), stub.writes[0].value); // unmodified
    try testing.expectEqual(@as(u16, 0x8000), stub.writes[1].addr);
    try testing.expectEqual(@as(u8, 0x42), stub.writes[1].value); // modified
    try testing.expectEqual(@as(u64, 6), h.cpu.cycles);
}

test "ADC sets carry and signed overflow, and never uses decimal mode" {
    var h: TestHarness = undefined;
    h.init(&[_]u8{ 0x69, 0x01 }); // ADC #$01
    h.cpu.a = 0x7F;
    h.cpu.p.d = true; // 2A03: D is set but has no arithmetic effect
    h.cpu.step();
    try testing.expectEqual(@as(u8, 0x80), h.cpu.a); // binary, not $85
    try testing.expect(h.cpu.p.v);
    try testing.expect(h.cpu.p.n);
    try testing.expect(!h.cpu.p.c);
}

test "SBC borrows through the carry flag" {
    var h: TestHarness = undefined;
    h.init(&[_]u8{ 0xE9, 0x01 }); // SBC #$01
    h.cpu.a = 0x00;
    h.cpu.p.c = true; // no borrow in
    h.cpu.step();
    try testing.expectEqual(@as(u8, 0xFF), h.cpu.a);
    try testing.expect(!h.cpu.p.c); // borrow occurred
}

test "PHP pushes B set, but an IRQ pushes it clear" {
    var h: TestHarness = undefined;
    h.init(&[_]u8{0x08}); // PHP
    h.cpu.step();
    try testing.expectEqual(@as(u8, 0x30), h.bus.wram[0x01FD] & 0x30);

    h.init(&[_]u8{0xEA});
    h.cpu.p.i = false;
    h.cpu.setIrqLine(true);
    h.cpu.step(); // NOP; latches the poll
    h.cpu.step(); // IRQ sequence: PCH, PCL, then P
    try testing.expectEqual(@as(u8, 0x20), h.bus.wram[0x01FB] & 0x30);
    try testing.expect(h.cpu.p.i);
}

test "BRK pushes PC+2, sets B and I, and vectors through $FFFE" {
    var h: TestHarness = undefined;
    h.init(&[_]u8{ 0x00, 0x00 });
    h.prg[0x7FFE] = 0x00;
    h.prg[0x7FFF] = 0xD0; // IRQ vector -> $D000
    // The decode table must agree with the PC advance below: BRK consumes a
    // signature byte, so a tracer stepping by `length` has to skip 2.
    try testing.expectEqual(@as(u2, 2), opcodes[0x00].mode.length());
    const before = h.cpu.trace();
    try testing.expectEqual(@as(u2, 2), before.length);
    h.cpu.step();
    try testing.expectEqual(@as(u16, 0xD000), h.cpu.pc);
    try testing.expectEqual(@as(u64, 7), h.cpu.cycles);
    try testing.expect(h.cpu.p.i);
    try testing.expectEqual(@as(u8, 0xC0), h.bus.wram[0x01FD]); // PCH
    try testing.expectEqual(@as(u8, 0x02), h.bus.wram[0x01FC]); // PCL = C000+2
    try testing.expectEqual(@as(u8, 0x30), h.bus.wram[0x01FB] & 0x30); // B set
}

test "NMI is edge-triggered, ignores the I flag, and dispatches after the instruction that observes it" {
    var h: TestHarness = undefined;
    h.init(&[_]u8{ 0xEA, 0xEA });
    h.prg[0x7FFA] = 0x00;
    h.prg[0x7FFB] = 0xE0; // NMI vector -> $E000
    h.cpu.p.i = true;
    h.cpu.setNmiLine(true); // latches nmi_pending directly, bypassing nmi_ready's snapshot

    // `nmi_ready` -- what `step` actually dispatches on -- is only
    // re-snapshotted from `nmi_pending` at the start of each cycle (see its
    // doc comment), so a line asserted *between* steps is not visible to
    // dispatch until the NOP that's already in flight runs its own cycle
    // and re-snapshots. This is the same timing `ppu_vbl_nmi/04-nmi_control`
    // test 11 checks for the $2000-driven case.
    h.cpu.step(); // NOP runs normally; its own cycle snapshots nmi_ready=true
    try testing.expectEqual(@as(u16, 0xC001), h.cpu.pc);

    h.cpu.step(); // dispatches NMI instead of the second NOP
    try testing.expectEqual(@as(u16, 0xE000), h.cpu.pc);
    try testing.expectEqual(@as(u64, 2 + 7), h.cpu.cycles);

    // Holding the line asserted must not retrigger.
    h.cpu.pc = 0xC000;
    h.cpu.step();
    try testing.expectEqual(@as(u16, 0xC001), h.cpu.pc);
}

test "SEI defers its I-flag change past the interrupt poll" {
    var h: TestHarness = undefined;
    h.init(&[_]u8{ 0x78, 0xEA }); // SEI ; NOP
    h.prg[0x7FFE] = 0x00;
    h.prg[0x7FFF] = 0xD0;
    h.cpu.p.i = false;
    h.cpu.setIrqLine(true);
    h.cpu.step(); // SEI — poll sees I still clear
    try testing.expect(h.cpu.p.i);
    h.cpu.step(); // ...so this IRQ is still taken
    try testing.expectEqual(@as(u16, 0xD000), h.cpu.pc);
}

// The interrupt poll happens during an instruction's penultimate cycle, so an
// instruction that writes the I flag on its *final* cycle is "one instruction
// late": CLI/SEI/PLP defer, RTI does not. nestest never executes $58 (CLI) at
// all and never runs PLP with an IRQ pending, so the log diff says nothing
// about any of this. RTI's exemption is the asymmetry the whole design rests
// on, and the one M2's NMI timing will build on.

test "CLI defers its I-flag change past the interrupt poll" {
    var h: TestHarness = undefined;
    h.init(&[_]u8{ 0x58, 0xEA, 0xEA }); // CLI ; NOP ; NOP
    h.prg[0x7FFE] = 0x00;
    h.prg[0x7FFF] = 0xD0; // IRQ vector -> $D000
    h.cpu.p.i = true;
    h.cpu.setIrqLine(true);

    h.cpu.step(); // CLI — the poll at its end still sees I *set*
    try testing.expect(!h.cpu.p.i); // the flag itself did change...
    try testing.expect(!h.cpu.irq_ready); // ...but the poll missed it

    h.cpu.step(); // so the next instruction runs normally
    try testing.expectEqual(@as(u16, 0xC002), h.cpu.pc);
    try testing.expect(h.cpu.irq_ready); // *its* poll sees I clear

    h.cpu.step(); // and only now is the IRQ taken
    try testing.expectEqual(@as(u16, 0xD000), h.cpu.pc);
}

test "PLP defers its I-flag change past the interrupt poll, exactly like CLI" {
    var h: TestHarness = undefined;
    h.init(&[_]u8{ 0x28, 0xEA, 0xEA }); // PLP ; NOP ; NOP
    h.prg[0x7FFE] = 0x00;
    h.prg[0x7FFF] = 0xD0;
    h.cpu.p.i = true;
    h.cpu.s = 0xFC;
    h.bus.wram[0x01FD] = 0x20; // pulled P: I clear (bit 5 always reads back set)
    h.cpu.setIrqLine(true);

    h.cpu.step(); // PLP
    try testing.expect(!h.cpu.p.i);
    try testing.expect(!h.cpu.irq_ready); // deferred, same as CLI

    h.cpu.step();
    try testing.expectEqual(@as(u16, 0xC002), h.cpu.pc);
    try testing.expect(h.cpu.irq_ready);

    h.cpu.step();
    try testing.expectEqual(@as(u16, 0xD000), h.cpu.pc);
}

test "RTI's I-flag change is visible to the poll immediately, unlike PLP" {
    var h: TestHarness = undefined;
    h.init(&[_]u8{0x40}); // RTI
    h.prg[0x7FFE] = 0x00;
    h.prg[0x7FFF] = 0xD0;
    h.cpu.p.i = true;
    h.cpu.s = 0xFA;
    h.bus.wram[0x01FB] = 0x20; // pulled P: I clear
    h.bus.wram[0x01FC] = 0x00; // PCL
    h.bus.wram[0x01FD] = 0xC0; // PCH -> return to $C000
    h.cpu.setIrqLine(true);

    h.cpu.step(); // RTI
    try testing.expectEqual(@as(u16, 0xC000), h.cpu.pc);
    try testing.expect(!h.cpu.p.i);
    // The asymmetry: no `poll_i_override`, so this poll saw the *new* I.
    // PLP above needed one extra instruction to reach this state.
    try testing.expect(h.cpu.irq_ready);

    h.cpu.step(); // IRQ taken on the very next step, with no delay instruction
    try testing.expectEqual(@as(u16, 0xD000), h.cpu.pc);
}

test "RTI restores P without B/U and returns to the pushed address" {
    var h: TestHarness = undefined;
    h.init(&[_]u8{0x40}); // RTI
    h.cpu.s = 0xFA;
    h.bus.wram[0x01FB] = 0xFF; // P (all bits set on the stack)
    h.bus.wram[0x01FC] = 0x34; // PCL
    h.bus.wram[0x01FD] = 0x12; // PCH
    h.cpu.step();
    try testing.expectEqual(@as(u16, 0x1234), h.cpu.pc);
    try testing.expectEqual(@as(u8, 0xEF), h.cpu.p.toByte()); // B cleared, U set
    try testing.expectEqual(@as(u64, 6), h.cpu.cycles);
}

test "JSR/RTS round-trip through the stack" {
    var h: TestHarness = undefined;
    h.init(&[_]u8{ 0x20, 0x10, 0xC0 }); // JSR $C010
    h.prg[0x4010] = 0x60; // RTS at $C010
    h.cpu.step();
    try testing.expectEqual(@as(u16, 0xC010), h.cpu.pc);
    try testing.expectEqual(@as(u64, 6), h.cpu.cycles);
    h.cpu.step();
    try testing.expectEqual(@as(u16, 0xC003), h.cpu.pc);
    try testing.expectEqual(@as(u64, 12), h.cpu.cycles);
}

test "LAX loads A and X together; SAX stores their AND" {
    var h: TestHarness = undefined;
    h.init(&[_]u8{ 0xA7, 0x10 }); // LAX $10
    h.bus.wram[0x0010] = 0x80;
    h.cpu.step();
    try testing.expectEqual(@as(u8, 0x80), h.cpu.a);
    try testing.expectEqual(@as(u8, 0x80), h.cpu.x);
    try testing.expect(h.cpu.p.n);

    h.init(&[_]u8{ 0x87, 0x20 }); // SAX $20
    h.cpu.a = 0xF0;
    h.cpu.x = 0x3C;
    const p_before = h.cpu.p.toByte();
    h.cpu.step();
    try testing.expectEqual(@as(u8, 0x30), h.bus.wram[0x0020]);
    try testing.expectEqual(p_before, h.cpu.p.toByte()); // no flags touched
}

test "SLO shifts memory then ORs it into A, in 5 cycles on the zero page" {
    var h: TestHarness = undefined;
    h.init(&[_]u8{ 0x07, 0x10 }); // SLO $10
    h.bus.wram[0x0010] = 0x81;
    h.cpu.a = 0x01;
    h.cpu.step();
    try testing.expectEqual(@as(u8, 0x02), h.bus.wram[0x0010]); // $81 << 1
    try testing.expectEqual(@as(u8, 0x03), h.cpu.a); // $01 | $02
    try testing.expect(h.cpu.p.c); // bit 7 shifted out
    try testing.expectEqual(@as(u64, 5), h.cpu.cycles);
}

test "ANC copies bit 7 of the AND result into carry" {
    var h: TestHarness = undefined;
    h.init(&[_]u8{ 0x0B, 0xFF }); // ANC #$FF
    h.cpu.a = 0x80;
    h.cpu.step();
    try testing.expectEqual(@as(u8, 0x80), h.cpu.a);
    try testing.expect(h.cpu.p.c);
    try testing.expect(h.cpu.p.n);
}

test "ARR takes C from bit 6 and V from bit6 XOR bit5" {
    var h: TestHarness = undefined;
    h.init(&[_]u8{ 0x6B, 0xFF }); // ARR #$FF
    h.cpu.a = 0x80;
    h.cpu.p.c = false;
    h.cpu.step();
    try testing.expectEqual(@as(u8, 0x40), h.cpu.a); // $80 >> 1
    try testing.expect(h.cpu.p.c); // bit 6 of $40 is set
    try testing.expect(h.cpu.p.v); // bit6(1) ^ bit5(0)

    // ...and with bits 6 and 5 agreeing, V comes out clear.
    h.init(&[_]u8{ 0x6B, 0xFF });
    h.cpu.a = 0xC0;
    h.cpu.p.c = false;
    h.cpu.step();
    try testing.expectEqual(@as(u8, 0x60), h.cpu.a);
    try testing.expect(h.cpu.p.c);
    try testing.expect(!h.cpu.p.v); // bit6(1) ^ bit5(1)
}

test "SBX subtracts from A&X into X with CMP-style carry" {
    var h: TestHarness = undefined;
    h.init(&[_]u8{ 0xCB, 0x05 }); // SBX #$05
    h.cpu.a = 0xFF;
    h.cpu.x = 0x08;
    h.cpu.p.c = false; // ignored
    h.cpu.step();
    try testing.expectEqual(@as(u8, 0x03), h.cpu.x); // ($FF & $08) - 5
    try testing.expect(h.cpu.p.c); // 8 >= 5
}

// The opcodes below are the ones nestest never executes (its documented test
// list stops at NOP/LAX/SAX/SBC/DCP/ISB/SLO/RLA/SRE/RRA), so the log diff says
// nothing about them. These tests are the only coverage they have.

test "ASR ANDs then shifts right, taking carry from the pre-shift bit 0" {
    var h: TestHarness = undefined;
    h.init(&[_]u8{ 0x4B, 0x03 }); // ASR #$03
    h.cpu.a = 0xFF;
    h.cpu.step();
    try testing.expectEqual(@as(u8, 0x01), h.cpu.a); // ($FF & $03) >> 1
    try testing.expect(h.cpu.p.c); // bit 0 of $03
    try testing.expectEqual(@as(u64, 2), h.cpu.cycles);
}

test "LAS ANDs memory with S into A, X and S alike" {
    var h: TestHarness = undefined;
    h.init(&[_]u8{ 0xBB, 0x10, 0x02 }); // LAS $0210,Y
    h.cpu.y = 0x01;
    h.cpu.s = 0x3C;
    h.bus.wram[0x0211] = 0xF0;
    h.cpu.step();
    try testing.expectEqual(@as(u8, 0x30), h.cpu.a); // $F0 & $3C
    try testing.expectEqual(@as(u8, 0x30), h.cpu.x);
    try testing.expectEqual(@as(u8, 0x30), h.cpu.s);
}

test "SHY stores Y AND (base high byte + 1)" {
    var h: TestHarness = undefined;
    h.init(&[_]u8{ 0x9C, 0x10, 0x02 }); // SHY $0210,X
    h.cpu.x = 0x01;
    h.cpu.y = 0xFF;
    h.cpu.step();
    try testing.expectEqual(@as(u8, 0x03), h.bus.wram[0x0211]); // $FF & ($02+1)
    try testing.expectEqual(@as(u64, 5), h.cpu.cycles);
}

test "SHY on a page cross also drops the ANDed value into the address high byte" {
    var h: TestHarness = undefined;
    h.init(&[_]u8{ 0x9C, 0xFF, 0x01 }); // SHY $01FF,X
    h.cpu.x = 0x01; // -> $0200, page crossed
    h.cpu.y = 0xFF;
    h.cpu.step();
    // value = $FF & ($01 + 1) = $02, and the target becomes $0200.
    try testing.expectEqual(@as(u8, 0x02), h.bus.wram[0x0200]);
}

test "SHX and SHA use X and A&X respectively" {
    var h: TestHarness = undefined;
    h.init(&[_]u8{ 0x9E, 0x10, 0x02 }); // SHX $0210,Y
    h.cpu.y = 0x01;
    h.cpu.x = 0xFF;
    h.cpu.step();
    try testing.expectEqual(@as(u8, 0x03), h.bus.wram[0x0211]);

    h.init(&[_]u8{ 0x9F, 0x10, 0x02 }); // SHA $0210,Y
    h.cpu.y = 0x01;
    h.cpu.a = 0xF1;
    h.cpu.x = 0x0F;
    h.cpu.step();
    try testing.expectEqual(@as(u8, 0x01), h.bus.wram[0x0211]); // ($F1 & $0F) & $03
}

// $93 is the only opcode routed through `addrIndirectIndexedRaw`; the SHA test
// above covers $9F, which goes through the *absolute* raw helper instead. So
// without this test that helper's pointer read, `base` and `crossed` flag are
// exercised by nothing at all.

test "SHA (indirect),Y ANDs with the pointer's high byte, not the pointer's address" {
    var h: TestHarness = undefined;
    h.init(&[_]u8{ 0x93, 0x40 }); // SHA ($40),Y
    h.bus.wram[0x0040] = 0x10; // pointer low
    h.bus.wram[0x0041] = 0x02; // pointer high -> base $0210
    h.cpu.y = 0x01; // -> $0211, no page cross
    h.cpu.a = 0xFF;
    h.cpu.x = 0x0F;
    h.cpu.step();
    // value = ($FF & $0F) & ($02 + 1) = $0F & $03 = $03
    try testing.expectEqual(@as(u8, 0x03), h.bus.wram[0x0211]);
    // 6 cycles: opcode, pointer operand, two pointer reads, the unconditional
    // dummy read at the un-fixed address, then the store.
    try testing.expectEqual(@as(u64, 6), h.cpu.cycles);

    // On a page cross the ANDed value also replaces the address's high byte,
    // so the store lands somewhere else entirely.
    h.init(&[_]u8{ 0x93, 0x40 });
    h.bus.wram[0x0040] = 0xFE; // pointer low
    h.bus.wram[0x0041] = 0x02; // pointer high -> base $02FE
    h.cpu.y = 0x03; // -> $0301, page crossed
    h.cpu.a = 0x0D;
    h.cpu.x = 0x07;
    h.cpu.step();
    // value = ($0D & $07) & ($02 + 1) = $05 & $03 = $01,
    // so the target becomes ($01 << 8) | $01 = $0101, *not* $0301.
    try testing.expectEqual(@as(u8, 0x01), h.bus.wram[0x0101]);
    try testing.expectEqual(@as(u8, 0x00), h.bus.wram[0x0301]);
    try testing.expectEqual(@as(u64, 6), h.cpu.cycles);
}

test "SHS loads S with A AND X before storing" {
    var h: TestHarness = undefined;
    h.init(&[_]u8{ 0x9B, 0x10, 0x02 }); // SHS $0210,Y
    h.cpu.y = 0x01;
    h.cpu.a = 0xFF;
    h.cpu.x = 0x3F;
    h.cpu.step();
    try testing.expectEqual(@as(u8, 0x3F), h.cpu.s);
    try testing.expectEqual(@as(u8, 0x03), h.bus.wram[0x0211]); // $3F & ($02+1)
}

test "ANE and LXA use the documented $EE magic constant" {
    var h: TestHarness = undefined;
    h.init(&[_]u8{ 0x8B, 0x0F }); // ANE #$0F
    h.cpu.a = 0x00;
    h.cpu.x = 0xFF;
    h.cpu.step();
    try testing.expectEqual(@as(u8, 0x0E), h.cpu.a); // (($00|$EE) & $FF) & $0F

    h.init(&[_]u8{ 0xAB, 0xFF }); // LXA #$FF
    h.cpu.a = 0x01;
    h.cpu.step();
    try testing.expectEqual(@as(u8, 0xEF), h.cpu.a); // ($01|$EE) & $FF
    try testing.expectEqual(@as(u8, 0xEF), h.cpu.x);
}

test "undocumented NOPs still perform their memory read and pay for page crosses" {
    var h: TestHarness = undefined;
    h.init(&[_]u8{ 0x1C, 0xFF, 0x02 }); // NOP $02FF,X
    h.cpu.x = 0x01; // crosses into $0300
    const a_before = h.cpu.a;
    h.cpu.step();
    try testing.expectEqual(@as(u64, 5), h.cpu.cycles);
    try testing.expectEqual(a_before, h.cpu.a); // no register or flag effect
    try testing.expectEqual(@as(u16, 0xC003), h.cpu.pc);

    h.init(&[_]u8{ 0x04, 0x10 }); // NOP $10 (zero page)
    h.cpu.step();
    try testing.expectEqual(@as(u64, 3), h.cpu.cycles);
    try testing.expectEqual(@as(u16, 0xC002), h.cpu.pc);
}

test "a pending NMI hijacks BRK's vector but the pushed B flag stays set" {
    var h: TestHarness = undefined;
    h.init(&[_]u8{ 0x00, 0x00 }); // BRK
    h.prg[0x7FFA] = 0x00;
    h.prg[0x7FFB] = 0xE0; // NMI vector -> $E000
    h.prg[0x7FFE] = 0x00;
    h.prg[0x7FFF] = 0xD0; // IRQ vector -> $D000
    h.cpu.setNmiLine(true);
    h.cpu.nmi_pending = true;
    // step() would service the NMI first; call execute directly to exercise
    // the hijack path inside BRK itself.
    _ = h.cpu.fetch();
    h.cpu.execute(0x00);
    try testing.expectEqual(@as(u16, 0xE000), h.cpu.pc);
    try testing.expectEqual(@as(u8, 0x30), h.bus.wram[0x01FB] & 0x30);
    try testing.expect(!h.cpu.nmi_pending);
}

test "JAM halts the CPU without advancing PC" {
    var h: TestHarness = undefined;
    h.init(&[_]u8{0x02});
    h.cpu.step();
    try testing.expect(h.cpu.jammed);
    try testing.expectEqual(@as(u16, 0xC000), h.cpu.pc);
    const cycles = h.cpu.cycles;
    h.cpu.step();
    try testing.expect(h.cpu.cycles > cycles);
    try testing.expectEqual(@as(u16, 0xC000), h.cpu.pc);
}

test "a mapper-asserted IRQ is seen by the CPU without mapper-specific code" {
    var h: TestHarness = undefined;
    h.initStub(&[_]u8{ 0xEA, 0xEA, 0xEA });
    h.prg[0x7FFE] = 0x00;
    h.prg[0x7FFF] = 0xD0; // IRQ vector -> $D000
    h.cpu.p.i = false;

    // Baseline: nothing asserting.
    h.cpu.step();
    try testing.expect(!h.cpu.irq_ready);

    // Now the *cartridge* alone pulls the line down. The CPU's own /IRQ input
    // is untouched, so the only thing that can carry this into the interrupt
    // logic is the OR in `irqAsserted` — the single line MMC3's scanline IRQ
    // (M7) will depend on, and the reason no mapper-specific code belongs in
    // this file.
    h.bus.mapper.test_stub.irq = true;
    try testing.expect(!h.cpu.irq_line);
    try testing.expect(h.bus.mapper.irqPending());

    h.cpu.step(); // NOP, whose poll now sees the cartridge line
    try testing.expect(h.cpu.irq_ready);
    h.cpu.step();
    try testing.expectEqual(@as(u16, 0xD000), h.cpu.pc);
    try testing.expect(h.cpu.p.i);
    try testing.expectEqual(@as(u8, 0x20), h.bus.wram[0x01FB] & 0x30); // B clear

    // Acknowledging through the same interface drops it again.
    h.bus.mapper.irqAcknowledge();
    try testing.expect(!h.bus.mapper.irqPending());
}

test "OAMDMA copies 256 bytes from the given page into OAM, honoring and advancing OAMADDR" {
    var h: TestHarness = undefined;
    h.init(&[_]u8{
        0xA9, 0x40, // LDA #$40
        0x8D, 0x03, 0x20, // STA $2003 (OAMADDR = $40)
        0xA9, 0x02, // LDA #$02 (source page)
        0x8D, 0x14, 0x40, // STA $4014 (trigger OAMDMA from $0200-$02FF)
    });
    for (0..256) |i| h.bus.wram[0x0200 + i] = @intCast(i ^ 0xA5); // recognizable pattern
    h.stepN(4);

    for (0..256) |i| {
        const expected: u8 = @intCast(i ^ 0xA5);
        const oam_index: u8 = @truncate(0x40 +% i);
        try testing.expectEqual(expected, h.bus.ppu.oam[oam_index]);
    }
    // 256 writes through OAMDATA auto-increment OAMADDR 256 times, wrapping
    // a full u8 cycle back to where it started.
    try testing.expectEqual(@as(u8, 0x40), h.bus.ppu.oam_addr);
}

test "OAMDMA costs 513 CPU cycles when triggered on an even cycle, 514 on odd" {
    // NOP implied (2 cycles) + STA $4014 (4 cycles): the write lands on
    // cycle 6 (even) -> 513-cycle DMA.
    {
        var h: TestHarness = undefined;
        h.init(&[_]u8{ 0xEA, 0x8D, 0x14, 0x40 });
        h.stepN(2);
        try testing.expectEqual(@as(u64, 6 + 513), h.cpu.cycles);
    }
    // NOP $00 zero-page (3 cycles) + STA $4014 (4 cycles): the write lands
    // on cycle 7 (odd) -> 514-cycle DMA.
    {
        var h: TestHarness = undefined;
        h.init(&[_]u8{ 0x04, 0x00, 0x8D, 0x14, 0x40 });
        h.stepN(2);
        try testing.expectEqual(@as(u64, 7 + 514), h.cpu.cycles);
    }
}

test "OAMDMA still ticks the PPU 3 dots/cycle throughout, not just for ordinary instructions" {
    var h: TestHarness = undefined;
    h.init(&[_]u8{ 0x8D, 0x14, 0x40 }); // STA $4014, page $00
    // `init()` zeroes `cpu.cycles` after `reset()` (whose own 7 cycles
    // already ticked the PPU 21 dots), so the dot position right after
    // `init()` -- not (0,0) -- is the correct zero point for this check.
    const dot_before: u64 = h.bus.ppu.frame * 341 * 262 +
        @as(u64, h.bus.ppu.scanline) * 341 + h.bus.ppu.dot;

    h.stepN(1); // the whole DMA runs inside this single `step` call
    const dot_after: u64 = h.bus.ppu.frame * 341 * 262 +
        @as(u64, h.bus.ppu.scanline) * 341 + h.bus.ppu.dot;
    try testing.expectEqual(h.cpu.cycles * 3, dot_after - dot_before);
}

test "the decode table covers all 256 opcodes with sane lengths" {
    for (opcodes) |entry| {
        // `mnemonic`'s type pins the length to 3 at compile time, so all that
        // is left to check at runtime is that the three bytes are a plausible
        // mnemonic rather than punctuation or padding.
        for (entry.mnemonic) |c| try testing.expect(c >= 'A' and c <= 'Z');
        const len = entry.mode.length();
        try testing.expect(len >= 1 and len <= 3);
    }
}
