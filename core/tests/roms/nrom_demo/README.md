# `sprite_input_demo` — an original, hand-written NROM test ROM

Not a vendored third-party fixture (no `ATTRIBUTION.md` needed) — this is
original 6502 assembly written for this milestone (ENG-68), assembled with
[cc65](https://cc65.github.io/)'s `ca65`/`ld65`.

## Why this exists instead of a real commercial game

ENG-68's acceptance criteria ask for "a real NROM game (e.g. Donkey Kong)
render[ing] correctly with sprites and respond[ing] to input in a native
test/debug harness." Donkey Kong (and any other commercial NES game) is
copyrighted, unlicensed for redistribution, and not covered by the
licensing research this repo already did for its vendored test ROMs (see
`docs/research/test-rom-licensing.md`, ENG-59, and
`ppu_background_test.zig`'s own doc comment: "Deliberately not a real game
ROM (copyright risk, no licensing research backs one)") — vendoring one
here would be exactly the mistake that research and precedent both warn
against. This ROM exercises the same end-to-end pipeline the acceptance
criterion cares about (OAM DMA -> sprite rendering -> controller input ->
visible on-screen movement, all through the real CPU/Bus/PPU/Controller
stack, not a direct-register-poke unit test) without that risk.

## What it does

1. Waits for the first VBLANK, clears OAM (all 64 sprites parked
   off-screen), sets up sprite 0 at (X=$80, Y=$70, tile 1, palette 0).
2. Writes tile #1 into CHR-RAM as a solid 8x8 block (both bitplanes all
   1s -> pixel value 3).
3. Writes a palette: universal backdrop plus sprite palette 0's pixel-value-3
   entry.
4. Waits for a second VBLANK, then turns on background and sprite
   rendering (`$2001 = $1E`).
5. Every frame thereafter: waits for VBLANK, triggers OAMDMA from page
   `$02`, strobes both controllers, reads controller 1's 8 bits in NES bit
   order (A, B, Select, Start, Up, Down, Left, Right), and moves the sprite
   one pixel per frame in whichever D-pad direction(s) are held.

No NMI is used — `PPUCTRL`'s NMI-enable bit stays clear throughout, and the
frame loop polls `PPUSTATUS` bit 7 directly, which is what the harness
(`core/src/nrom_sprite_input_test.zig`) synchronizes against too.

## Reproducing the build

```sh
ca65 sprite_input_demo.s -o sprite_input_demo.o
ld65 -C sprite_input_demo.cfg -o sprite_input_demo.nes sprite_input_demo.o
```

`sprite_input_demo.nes` (32,784 bytes: 16-byte iNES header + 32KB PRG,
0 CHR banks = CHR-RAM, mapper 0/NROM, horizontal mirroring) is committed
alongside the source so `zig build test` needs no assembler installed.
