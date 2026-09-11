# dmc_dma_during_read4 — attribution

Source: [christopherpow/nes-test-roms](https://github.com/christopherpow/nes-test-roms), `dmc_dma_during_read4/`.
Author: Shay Green ("Blargg") <gblargg@gmail.com>.

No formal license is stated by the author or the hosting repository (`license:
null` via GitHub's API). Per `docs/research/test-rom-licensing.md` (ENG-59),
this is treated the same as every other Blargg suite already vendored here
(`ppu_vbl_nmi`, `oam_read`, `oam_stress`, `apu_test`, `apu_mixer`): believed
freely redistributable per 20+ years of unchallenged community practice, no
copyleft/non-commercial/no-redistribution terms present.

All 5 ROMs confirmed mapper 0 (NROM), 32,784 bytes each — 32KB PRG-ROM and
**no CHR-ROM**, vertical mirroring. The shell loads its ASCII font into CHR-RAM
at reset (`CHR_RAM=1` in the suite's `common.inc`), which is why these are the
first vendored fixtures here with a zero CHR-ROM count.

Files: `dma_2007_read.nes`, `dma_2007_write.nes`, `dma_4016_read.nes`,
`double_2007_read.nes`, `read_write_2007.nes`.

## Result protocol

Not the `$6000` status-byte protocol. These use the older console-text
convention: the ROM prints to a 30x30 text console whose font is loaded so
each tile ID *is* the character's ASCII code, so `"Passed"` / `"Failed"` /
`"Error <n>"` can be read directly out of nametable 0. See
`core/src/blargg_harness.zig`'s `runToNametableOutcome` and
`core/src/dmc_dma_test.zig`.

Note the wording differs from `sprite_hit_tests_2005.10.05` /
`sprite_overflow_tests`, which say `"PASSED"` / `"FAILED #n"`. Same idea,
a later revision of Blargg's shell.

## What they measure

Each ROM synchronizes precisely to the DMC timer, starts a sample, delays a
measured number of clocks, and then runs a short piece of code with the DMC
DMA landing inside it — repeated five times, the DMA one clock later each
time. Every printed value feeds a running CRC-32 that the ROM checks at the
end, so one wrong cycle anywhere fails the whole run.

`dma_4016_read` is the clearest of the five: its own source comments read
"DMC DMA during $4016 read causes extra $4016 read", and it counts controller
bits, expecting `08 08 07 08 08` — exactly one alignment out of five loses a
bit to the duplicated read. The four `2007` ROMs apply the same duplicated
read to the PPU data port and its read buffer.
