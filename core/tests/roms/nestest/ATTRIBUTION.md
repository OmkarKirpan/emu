# Third-party test ROM: nestest

## `nestest.nes`, `nestest.log`, `nestest.txt`

Source: **nestest**, "The ultimate NES CPU test ROM", v1.00 (2004-09-06), by
**Kevin Horton** ("Kevtris"). `nestest.txt` is the ROM's own bundled
documentation (usage instructions and the full failure-code tables);
`nestest.log` is the published known-good Nintendulator execution trace of the
ROM's automation run, which emulator authors diff their own trace against.

Downloaded, unmodified, from the URLs the NESdev wiki's
[Emulator tests](https://www.nesdev.org/wiki/Emulator_tests) page points to:

| File | Source URL | Size |
|---|---|---|
| `nestest.nes` | `http://nickmass.com/images/nestest.nes` | 24,592 bytes |
| `nestest.log` | `https://www.qmtpro.com/~nes/misc/nestest.log` | 868,158 bytes |
| `nestest.txt` | `https://www.qmtpro.com/~nes/misc/nestest.txt` | 17,774 bytes |

**No explicit license or copyright statement accompanies any of these files.**
`nestest.txt` credits the author and documents behavior, but carries no
copyright or license line anywhere. Per the research in
[`docs/research/test-rom-licensing.md`](../../../../docs/research/test-rom-licensing.md)
(ENG-59): there is no copyleft, non-commercial, or no-redistribution term to
conflict with this repo's MIT license — the issue is the *absence* of a grant,
not a restrictive one. These files are vendored here under the same posture as
the 64doc CPU reference: **no formal grant found; believed freely
redistributable per longstanding NES-emulator-community practice** (20+ years
of unchallenged mirroring by essentially every emulator project — Mesen,
FCEUX, puNES, and the NESdev-endorsed `christopherpow/nes-test-roms` mirror).

**How they are used:** `core/src/nestest_test.zig` embeds the ROM and the
reference log at build time (via anonymous imports declared in
`core/build.zig`) and runs both of nestest's documented pass/fail protocols —
the instruction-by-instruction log diff, and the zero-page `$02`/`$03` result
codes. They are pulled into the **native test binary only**; the
`zig build wasm` delivery target never sees them.

`nestest.txt` is kept alongside the binaries because it is the authoritative
list of what each failure code means — needed to interpret a nonzero `$02`
or `$03`.
