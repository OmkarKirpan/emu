# sprdma_and_dmc_dma — attribution

Source: [christopherpow/nes-test-roms](https://github.com/christopherpow/nes-test-roms), `sprdma_and_dmc_dma/`.
Author: Shay Green ("Blargg") <gblargg@gmail.com>.

No formal license is stated by the author or the hosting repository (`license:
null` via GitHub's API). Same posture as every other Blargg suite vendored
here — see `docs/research/test-rom-licensing.md` (ENG-59) and
`../apu_test/ATTRIBUTION.md`.

Both ROMs confirmed mapper 0 (NROM), 40,976 bytes each (32KB PRG-ROM + 8KB
CHR-ROM), vertical mirroring. The suite ships no `source/` directory upstream,
unlike `dmc_dma_during_read4`.

Files: `sprdma_and_dmc_dma.nes`, `sprdma_and_dmc_dma_512.nes`.

## Result protocol

The same console-text convention as `../dmc_dma_during_read4/` —
`"Passed"` / `"Failed"` / `"Error <n>"` read out of nametable 0. See
`core/src/dmc_dma_test.zig`.

## What they measure

A DMC DMA colliding with an OAM DMA that is already running. Hardware lets
the DMC take the cycle and pauses the sprite copy, which then needs a cycle
to realign to a get cycle — two cycles, not the three or four a standalone
DMC DMA costs, because the CPU is already halted. The ROM's own strings name
what it checks: `"Clocks (decimal)"` and `"OAM differed"`.

The `_512` variant runs the same test with the 512-byte-per-frame DMA
arrangement its name refers to. Both are vendored: they exercise different
alignments of the same collision.
