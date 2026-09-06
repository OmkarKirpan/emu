# apu_test — attribution

Source: [christopherpow/nes-test-roms](https://github.com/christopherpow/nes-test-roms), `apu_test/rom_singles/`.
Author: Shay Green ("Blargg") <gblargg@gmail.com>.

No formal license is stated by the author or the hosting repository (`license:
null` via GitHub's API). Per `docs/research/test-rom-licensing.md` (ENG-59),
this is treated the same as every other Blargg suite already vendored here
(`ppu_vbl_nmi`, `oam_read`, `oam_stress`): believed freely redistributable per
20+ years of unchallenged community practice, no copyleft/non-commercial/
no-redistribution terms present.

All 8 ROMs confirmed mapper 0 (NROM), 40,976 bytes each (32KB PRG-ROM + 8KB
CHR-ROM), speaking the standard `$6000` status-byte protocol common to every
Blargg suite (see `core/src/blargg_harness.zig`).

Files: `1-len_ctr.nes`, `2-len_table.nes`, `3-irq_flag.nes`, `4-jitter.nes`,
`5-len_timing.nes`, `6-irq_flag_timing.nes`, `7-dmc_basics.nes`, `8-dmc_rates.nes`.
