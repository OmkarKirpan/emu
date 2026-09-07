# apu_mixer — attribution

Source: [christopherpow/nes-test-roms](https://github.com/christopherpow/nes-test-roms), `apu_mixer/`.
Author: Shay Green ("Blargg") <gblargg@gmail.com>.

Same licensing situation as every other Blargg suite vendored here
(`apu_test`, `ppu_vbl_nmi`, `oam_read`, `oam_stress`): no formal license is
stated by the author or the hosting repository, and per
`docs/research/test-rom-licensing.md` (ENG-59) these are treated as freely
redistributable per longstanding community practice.

All 4 confirmed mapper 0 (NROM), 40,976 bytes each.

## What makes these different from every other suite here

These are **listen tests**. They cannot report a `$6000` result code,
because what they check is not observable to the CPU: each ROM plays the
channel under test while playing the inverse waveform on the DMC DAC, so
correct relative volumes and correct non-linear mixing cancel to near
silence. From the author's readme:

> "All tests beep, play a test sound, then beep again. For all but the
> noise test, there should be near silence between the beeps. For the
> noise test, noise will fade in and out."

`core/src/apu_mixer_test.zig` turns that into an automated check by
measuring the RMS of the emulator's own mixed-and-filtered output across a
window inside the cancellation section. Files: `square.nes`,
`triangle.nes`, `noise.nes`, `dmc.nes`.
