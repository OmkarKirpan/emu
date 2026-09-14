//! The DMC-DMA conformance stage (ENG-81), per ENG-64's staged test-ROM
//! harness -- the gap `apu.zig` and
//! `docs/adr/0002-apu-mixing-and-filtering.md` carried as explicitly
//! deferred from M6, now modeled in `Cpu.read` and measured here.
//!
//!   * `dmc_dma_during_read4` -- a DMA landing in the middle of a CPU
//!     read, stepped one clock later on each of five iterations. A halted
//!     6502 re-issues its read on every no-operation DMA cycle, so on
//!     `$2007` the DMA costs two or three extra reads through the PPU's
//!     read buffer, and on `$4016` the contiguous run clocks the
//!     controller once where an uninterrupted read would have clocked it
//!     once too -- except that the DMA's own get cycle breaks the run in
//!     the middle, so the sequence pays one extra clock and loses a bit.
//!   * `sprdma_and_dmc_dma` -- a DMC DMA colliding with an OAM DMA already
//!     in progress, swept one cycle at a time across the copy's edges.
//!     `Cpu.runDma` arbitrates the two against each other cycle by cycle
//!     (`docs/adr/0008-one-dma-unit-with-arbitration.md`), and the ROMs
//!     time the result against the DMC's own playback -- which made them
//!     as much a test of `Dmc`'s DMA scheduling as of the DMA unit. See
//!     the long comment above those two tests.
//!
//! Both suites predate the `$6000` protocol and report as console text in
//! nametable 0 (see `blargg_harness.runToNametableOutcome`). This
//! generation of Blargg's shell words its verdict `"Passed"` / `"Failed"`
//! / `"Error <n>"`, not the `"PASSED"` / `"FAILED #n"` that
//! `ppu_sprites_test.zig`'s 2005-vintage suites use.
//!
//! **Two of these ROMs have no verdict at all.** `dma_2007_read` and
//! `double_2007_read` end in `print_crc`, not `check_crc` -- they print a
//! CRC-32 over everything they emitted and exit silently, because the
//! right answer depends on the CPU-PPU alignment the console powered up
//! with and there is more than one. Their sources list the acceptable
//! checksums, so `expectOneOfCrc` below asserts against that list rather
//! than against a pass marker.

const std = @import("std");
const testing = std.testing;

const Machine = @import("machine.zig").Machine;
const harness = @import("blargg_harness.zig");

/// `"Error "` is checked before `"Failed"`: the shell prints one or the
/// other, never both, but `print_filename` follows either, so scanning for
/// the more specific marker first keeps a numbered error from being
/// reported as a bare failure.
fn match(text: []const u8) ?harness.NametableOutcome {
    if (std.mem.indexOf(u8, text, "Passed")) |_| return .passed;
    if (std.mem.indexOf(u8, text, "Error ")) |idx| {
        return .{ .failed = parseDecimal(text, idx + "Error ".len) orelse 0 };
    }
    if (std.mem.indexOf(u8, text, "Failed")) |_| return .{ .failed = 1 };
    return null;
}

fn parseDecimal(text: []const u8, start: usize) ?u32 {
    var i = start;
    var value: u32 = 0;
    var seen = false;
    while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) {
        value = value * 10 + (text[i] - '0');
        seen = true;
    }
    return if (seen) value else null;
}

fn expectPass(name: []const u8, rom_bytes: []const u8) !void {
    var m: Machine = undefined;
    try m.init(rom_bytes);
    switch (try harness.runToNametableOutcome(&m, match)) {
        .passed => {},
        .failed => |code| {
            std.debug.print("\n{s}: failed with code {d}\n", .{ name, code });
            return error.TestUnexpectedResult;
        },
    }
}

/// Poll for one of several accepted CRC-32 strings, for the two ROMs that
/// print a checksum instead of a verdict (see the module doc comment). The
/// checksums come from each ROM's own source comment.
fn expectOneOfCrc(name: []const u8, rom_bytes: []const u8, accepted: []const []const u8) !void {
    var m: Machine = undefined;
    try m.init(rom_bytes);
    var buf: [960]u8 = undefined;
    while (m.cpu.cycles < 40_000_000) {
        const target = m.cpu.cycles + 100_000;
        while (m.cpu.cycles < target) m.cpu.step();
        const text = harness.nametableText(&m, &buf);
        for (accepted) |crc| {
            if (std.mem.indexOf(u8, text, crc)) |_| return;
        }
    }
    std.debug.print("\n{s}: none of the accepted checksums appeared\n", .{name});
    return error.TestUnexpectedResult;
}


test "dmc_dma_during_read4 dma_2007_write" {
    try expectPass("dmc_dma/dma_2007_write", @embedFile("dmc_dma_dma_2007_write"));
}
test "dmc_dma_during_read4 read_write_2007" {
    try expectPass("dmc_dma/read_write_2007", @embedFile("dmc_dma_read_write_2007"));
}

// The headline one: a DMA landing inside `LDA $4016` costs the controller
// one shift, and on exactly one of the five alignments it sweeps. Its own
// source says so -- "DMC DMA during $4016 read causes extra $4016 read",
// expecting `08 08 07 08 08` from a routine that counts bits until the
// controller returns 1.
test "dmc_dma_during_read4 dma_4016_read" {
    try expectPass("dmc_dma/dma_4016_read", @embedFile("dmc_dma_dma_4016_read"));
}

// "DMC DMA during $2007 read causes 2-3 extra $2007 reads before real
// read. Number of extra reads depends on CPU-PPU synchronization at
// reset." -- hence two accepted checksums, for the 2-extra and 3-extra
// alignments. This core lands on the 3-extra one.
test "dmc_dma_during_read4 dma_2007_read" {
    try expectOneOfCrc(
        "dmc_dma/dma_2007_read",
        @embedFile("dmc_dma_dma_2007_read"),
        &.{ "159A7A8F", "5E3DF9C4" },
    );
}

// Not a DMC DMA test at all despite living in this suite -- see ENG-87 and
// `Ppu.read_buffer_pending`. It measures what a page-crossing double read
// does to the PPU's read buffer: `lda $20F7,x` with X of `$10` puts the
// 6502's discarded dummy read and the real read on consecutive cycles, and
// the second one sees the buffer as it stood before the first fetch landed.
// Four accepted checksums, one per power-on CPU-PPU alignment.
test "dmc_dma_during_read4 double_2007_read" {
    try expectOneOfCrc(
        "dmc_dma/double_2007_read",
        @embedFile("dmc_dma_double_2007_read"),
        &.{ "85CFD627", "F018C287", "440EF923", "E52F41A5" },
    );
}
// ---------------------------------------------------------------------
// `sprdma_and_dmc_dma` (ENG-81, ENG-86)
//
// Each of the two ROMs sweeps a DMC DMA across sixteen one-cycle offsets
// relative to an OAM DMA and prints how long the block took, as
// `523 + (offset & 1) + cost` -- a 523-clock baseline, the copy's own
// 513/514 alternation, and what the collision cost on top. Hardware's rule
// set for that last term (https://www.nesdev.org/wiki/DMA and the nesdev
// "DMC/DMA timing and quirks" thread):
//
//     4   normally
//     3   landing on a CPU write
//     2   landing on the $4014 write, or anywhere inside the copy
//     1   on the copy's next-to-next-to-last cycle
//     3   on the copy's last cycle
//
// None of those numbers is computed anywhere in this core. They fall out
// of `Cpu.runDma` arbitrating one DMA unit cycle by cycle -- see
// `docs/adr/0008-one-dma-unit-with-arbitration.md`, which is what got the
// block durations right. What these two ROMs then took, on top of that,
// was `Dmc.load_pending`: see the "what was actually wrong" section below.
//
// Where each row comes from, since none of them is written down anywhere:
//
//   * **4 normally.** A reload request goes up on a get cycle, so halt,
//     dummy, alignment and get are four cycles. `Dmc.load_pending`'s doc
//     comment has the phase argument; `cpu.zig`'s
//     "a DMC load DMA costs 3 cycles..." test pins it.
//   * **3 landing on a CPU write.** `Cpu.read` is the only place that
//     tests `halt_pending`, so a request the CPU cannot halt on waits a
//     cycle for the next read -- and that cycle does the alignment's job,
//     paid by an instruction cycle the CPU was going to spend anyway. The
//     `$4015` write that starts a sample is itself this case, which is why
//     a load costs 3 and why the same test pins it; `_512`'s offsets
//     0A-0B are the ROM measurement of it.
//   * **2 landing on the `$4014` write, or anywhere inside the copy.**
//     `retireRunUp` spends the run-up on whatever cycle the DMA unit is
//     taking, so a request raised while a copy is already running has its
//     halt and dummy absorbed and pays only the get plus the put the copy
//     spends realigning. A request landing on the `$4014` write is the
//     same case one cycle earlier: the copy has not started, but neither
//     unit can halt on that write and both take the same next read, so
//     they share the run-up from its first cycle. `sprdma`'s offsets
//     05-0F are the eleven measurements of the in-copy form.
//   * **1 on the copy's next-to-next-to-last cycle (`_512` offsets
//     04-05), 3 on its last (06-07).** The loop keeps running after
//     `oam_dma_pending` clears, for whatever the DMC still owes, so a
//     request the copy's final cycles raise pays the remainder of its
//     run-up in real time while one raised a cycle earlier has it
//     absorbed.
//
// **What the ROMs expect, and how to re-derive it.** They check a CRC-32
// over everything they print and report only pass/fail, so the expected
// tables had to be recovered from the ROM images. Write the expected
// printed value as `523 + (offset & 1) + cost`; a complete 4^16
// enumeration over `cost` in 1..4 leaves `sprdma` exactly one solution and
// `_512` one structured solution:
//
//     sprdma      cost = 4 4 4 4 4  2 2 2 2 2 2 2 2 2 2 2
//     sprdma_512  cost = 2 2 2 2 1 1  3 3  4 4 3 3  4 4 4 4
//
// which is to say the sixteen printed values are
//
//     sprdma      527 528 527 528 527 526 525 526 525 526 525 526 525 526 525 526
//     sprdma_512  525 526 525 526 524 525 526 527 527 528 526 527 527 528 527 528
//
// and this core now prints exactly those. None of that machinery needs
// rebuilding, but if a regression ever needs it again:
//
//   * The CRC routine is at `$E78A` (`reset` at `$E77B`), found by its
//     inner-loop opcode signature -- this suite ships no source. Logging
//     the accumulator at `$E78E`, one instruction past the enable check so
//     disabled calls exclude themselves, captures the hashed byte stream;
//     dropping the last 24 bytes, fed while the checksum is frozen, makes
//     `zlib.crc32` of it equal the value the ROM prints, for both ROMs.
//   * The stream is 4179 bytes: a 20-byte header, then sixteen 260-byte
//     blocks of filler, three ASCII digits and a separator. The filler is
//     a fixed point of `$E4EB`'s `update_crc`-then-`AND #$E3` loop (`$8F`
//     then 255 `$83`), identical in every block of both ROMs, so the only
//     content the checksum varies over is the sixteen clock counts.
//   * `$E4D8` loads `$0E/$0F` with `$EE13` and calls `check_crc` at
//     `$E84B`, which walks `$E7D1` (`LDA ($0E),Y / SEC / ADC $0012,Y` for
//     Y=3..0), so the stored dword is the ones' complement of the running
//     CRC -- the same complement `print_crc` at `$E7BF` applies. The four
//     bytes at `$EE13` are therefore the printed checksum verbatim, MSB
//     last, and they are the only bytes besides two delay constants
//     (`$E381`, `$E3A5`) in which the two ROM images differ:
//
//         sprdma_and_dmc_dma       $EE13: 8d a4 ad fb   ->  FBADA48D
//         sprdma_and_dmc_dma_512   $EE13: 55 8f a5 f1   ->  F1A58F55
//
//   * CRC-32 is affine -- for equal-length streams
//     `crc(S^D) = crc(S) ^ crc(D) ^ crc(0)` -- so a candidate table costs
//     a handful of XORs rather than rehashing 4179 bytes, which is what
//     makes the enumeration above instant.
//
// **What was actually wrong, and why it took this long to see.** The DMA
// costs were right well before the ROMs passed: instrumenting the block
// these ROMs time (`$E36C` to the `JSR $E280` at `$E38C`) showed all 32
// durations already equal to the expected printed values plus a constant.
// The defect was in the *measurement*, not in what was being measured.
//
// `$E280` times the block against the DMC's own playback: a 16-cycle
// coarse loop counts `Y` down while the DMC is active, then a vernier at
// `$E296` -- whose 3423-cycle loop beats against the DMC's 3424-cycle byte
// period, one cycle per iteration -- resolves the remainder into `X`, and
// the routine returns `Y*16 + X`. That is a single-cycle clock, and it was
// coming back quantized to two: every value this core printed was even.
//
// The culprit was the alignment cycle of the very first DMC DMA `$E280`
// starts, at its `$4015` write. A DMA that pays an alignment cycle when
// the CPU is on one half of the APU clock and not when it is on the other
// *absorbs* that phase: both alignments come out of the stall on the same
// half, and the one-cycle difference the whole block was measuring is
// gone. nesdev's DMA page says hardware does not do that -- "load and
// reload DMAs schedule on different cycle types, [so] load DMAs take 3
// cycles and reload DMAs take 4 unless the halt is delayed by an odd
// number of cycles" -- so a load costs 3 whichever half the write landed
// on. `Dmc.load_pending` is that rule; `cpu.zig` has a unit test pinning
// both costs.
//
// Two things this cost several rounds to establish, worth not redoing:
//
//   * **Four alignment variants of the *OAM* DMA leave all sixteen of
//     `sprdma`'s printed values byte-identical**, and so did the whole
//     ADR 0008 rewrite. The parity term was never an OAM-DMA effect, and
//     hunting for it in `runDma` could not have found it.
//   * **Clocking `dmc.tickTimer` at the CPU rate with the unhalved
//     `dmc_rate_table`** keeps `apu_test` green but hangs three `dmc_dma`
//     ROMs, and nesdev's framing of the rate table says the timer is
//     APU-clocked anyway. Do not retry it.
// ---------------------------------------------------------------------

test "sprdma_and_dmc_dma" {
    try expectPass("sprdma_and_dmc_dma", @embedFile("sprdma_dmc_sprdma_and_dmc_dma"));
}
test "sprdma_and_dmc_dma_512" {
    try expectPass("sprdma_and_dmc_dma_512", @embedFile("sprdma_dmc_sprdma_and_dmc_dma_512"));
}
