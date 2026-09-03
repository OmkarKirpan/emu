# Test-ROM sourcing & licensing: nestest and Blargg suites

Research for ENG-59 (parent: ENG-54, wayfinder map). Answers: (1) licensing/
redistribution terms, (2) documented pass/fail signaling protocol, (3) canonical
live download sources, for `nestest.nes` and the Blargg-authored NES test-ROM
suites cited on the NESdev wiki as the standard correctness gate.

## Bottom line

**Safe to commit into this MIT-licensed public repo, with one caveat to flag rather than a blocker.**

- None of these ROMs carries copyleft, non-commercial, or no-redistribution terms.
  Nothing here would conflict with an MIT-licensed repo's own terms, because there
  is no restrictive license to conflict with in the first place.
- **But**: none of them carries an *explicit* license grant either. `nestest.nes`
  (Kevin Horton/"Kevtris") ships with a plain-text README that documents usage and
  contains no copyright or license statement at all. Blargg's (Shay Green's) suites
  (`instr_test`, `instr_timing`, `ppu_vbl_nmi`, `apu_test`, and siblings like
  `cpu_interrupts_v2`, `cpu_reset`, `cpu_dummy_reads`, `oam_read`) are likewise
  undocumented on the license front — their `readme.txt` files describe test
  behavior and end with only an email signature ("Shay Green <gblargg@gmail.com>"),
  no copyright/license line. The community mirror that hosts nearly all of them,
  [christopherpow/nes-test-roms](https://github.com/christopherpow/nes-test-roms),
  itself carries **no LICENSE file and no license declared in GitHub's repo
  metadata** (`license: None` via the GitHub API), and its maintainer has stated on
  the NESdev forum that the ROMs are mirrored "with the author's permission"
  (implying informal, not formally licensed, permission) — see
  [Legal ROMs thread](https://forums.nesdev.org/viewtopic.php?t=8943).
- Community consensus, and 20+ years of unchallenged practice, treats these
  homebrew/diagnostic ROMs as unrestricted, freely-redistributable community
  artifacts (unlike copyrighted commercial game ROMs, which the same forum thread
  explicitly discusses as illegal to redistribute). Practically every emulator
  project (Mesen, FCEUX, Nintendulator forks, puNES, etc.) vendors or links these
  same files without incident.
- **Recommendation**: it is reasonable to commit these ROMs into this repo, but
  since there's no formal grant, treat them the way most emulator projects do —
  either (a) vendor the binaries with a short `THIRD_PARTY_NOTICES` note
  attributing Kevin Horton and Shay Green and stating "no formal license found;
  believed freely redistributable per longstanding community practice," or
  (b) don't commit the binaries at all and instead have the build/test step fetch
  them from the canonical URLs below at test time (keeps the repo's own MIT scope
  unambiguous and avoids bundling someone else's un-licensed binary under an MIT
  banner). Either is defensible; (b) is the more conservative choice if the project
  wants to avoid any ambiguity about what "MIT-licensed" covers in the repo tree.
- One suite explicitly *does* carry a clean, explicit permissive license and could
  be used as a drop-in supplement or replacement where coverage overlaps:
  [bbbradsmith/nes-audio-tests](https://github.com/bbbradsmith/nes-audio-tests)
  states verbatim: "These files may be freely redistributed and modified for any
  purpose. Credit to the original author and/or a link to the original source
  would be appreciated, but is not required." That's an easy, zero-ambiguity
  citation if the team wants at least one suite with unambiguous terms alongside
  the Blargg/Kevtris ROMs.

No suite found here is "restrictive" (no GPL, no non-commercial clause, no
no-redistribution clause). The only issue is *absence* of a license, not a
*conflicting* one.

---

## Per-suite detail

### nestest.nes

| | |
|---|---|
| **Author** | Kevin Horton ("Kevtris"), v1.00, 2004-09-06 |
| **License** | None stated. `nestest.txt` (the bundled documentation) has no copyright/license line anywhere — confirmed by fetching the full text. It only credits the author and describes usage. |
| **Pass/fail protocol** | Two independent, both documented in `nestest.txt`: (1) **Log-diff method** (the one almost universally used by emulator test harnesses): set PC to `$C000` ("automation" mode) and run; compare the emulator's own per-instruction execution trace against the published known-good reference log `nestest.log` (generated with Nintendulator, whose CPU core the test author treated as verified-correct). A harness diffs its own log format (PC, opcode, registers, cycle count) line-for-line against `nestest.log`. (2) **In-memory result method**: the same automation run at `$C000` also writes results directly to zero-page **`$02`/`$03`** — `$02 == $00` means all tests in that page passed ("OK"); a nonzero 2-digit hex value is a failure code (documented list of ~60+ codes in `nestest.txt`, e.g. `$00` = success, others map to specific opcode/flag failures). Note this is **not** the `$6000`-style protocol Blargg's suites use — nestest predates and does not follow that convention. |
| **Canonical source** | ROM: `http://nickmass.com/images/nestest.nes` (linked from the NESdev wiki's [Emulator tests](https://www.nesdev.org/wiki/Emulator_tests) page; verified live, HTTP 200, 24,592 bytes). Documentation: `https://www.qmtpro.com/~nes/misc/nestest.txt` (verified live, HTTP 200). Reference log: `https://www.qmtpro.com/~nes/misc/nestest.log` (verified live, HTTP 200, ~868 KB). All three are the links the NESdev wiki itself points to and endorses. |

### Blargg (Shay Green) suites — common `$6000` protocol

All of the following suites share one documented protocol, quoted verbatim from
the `readme.txt` bundled with each (identical wording across `instr_test-v5`,
`instr_timing`, `ppu_vbl_nmi`, and `apu_test`, confirmed by direct diff of the
raw files):

> "The test status is written to $6000. $80 means the test is running, $81
> means the test needs the reset button pressed, but delayed by at least
> 100 msec from now. $00-$7F means the test has completed and given that
> result code."
>
> "To allow an emulator to know when one of these tests is running and the
> data at $6000+ is valid, as opposed to some other NES program, $DE $B0
> $G1 is written to $6001-$6003."
>
> "All text output is written starting at $6004, with a zero-byte
> terminator at the end."

**Note on the signature bytes**: the readme's own text literally reads `$DE $B0
$G1` — `G1` is not valid hex (confirmed byte-for-byte via the raw GitHub file,
not a rendering artifact). This is a long-standing typo in Blargg's original
readme; NESdev forum posts and secondary references uniformly cite the actual
byte value as **`$61`** (i.e. the true signature is `$DE $B0 $61` at
`$6001-$6003`), and that is the value real emulators check for. A harness should
implement the check as `$6001==$DE, $6002==$B0, $6003==$61` — treat `$G1` in the
readme as a known documentation typo, not as instruction to write a literal
non-hex value.

Result code `$00` at `$6000` = passed; `$01` = failed; `$02+` = suite-specific
error code (see each suite's source for the meaning of codes ≥2). A parallel
"audible" (beep-tone) encoding of the same result exists for use in NSF-player
or PPU-less test builds; not relevant to a native/headless test harness reading
memory directly.

| Suite | Author / attribution | License | Canonical source |
|---|---|---|---|
| `instr_test` (v3 and v5) | Shay Green \<gblargg@gmail.com\> (per readme signature) | None stated in readme or source; no LICENSE file in the hosting repo | `https://github.com/christopherpow/nes-test-roms/tree/master/instr_test-v5` (readme: `.../instr_test-v5/readme.txt`) |
| `instr_timing` | Shay Green | None stated | `https://github.com/christopherpow/nes-test-roms/raw/master/instr_timing/instr_timing.nes` |
| `ppu_vbl_nmi` | Shay Green | None stated | `https://github.com/christopherpow/nes-test-roms/raw/master/ppu_vbl_nmi/ppu_vbl_nmi.nes` |
| `apu_test` | Shay Green | None stated | `https://github.com/christopherpow/nes-test-roms/raw/master/apu_test/apu_test.nes` |
| `cpu_interrupts_v2`, `cpu_reset`, `cpu_dummy_reads`, `oam_read`, `oam_stress`, `ppu_open_bus`, `cpu_timing_test6` and other Blargg-attributed diagnostic ROMs also referenced from the wiki's [Emulator tests](https://www.nesdev.org/wiki/Emulator_tests) page | Shay Green (readmes follow the same template/signature) | None stated | Same repo, respective subdirectories, e.g. `.../cpu_interrupts_v2/cpu_interrupts.nes`, `.../cpu_dummy_reads/cpu_dummy_reads.nes` |

**On the hosting repo**: The NESdev wiki's own [Emulator tests](https://www.nesdev.org/wiki/Emulator_tests)
page states plainly: "Some of the download links below are currently dead, but
many have been archived at https://github.com/christopherpow/nes-test-roms" —
i.e. the wiki itself endorses this GitHub mirror as the current canonical source
now that Blargg's original site (`blargg.parodius.com` / similar) is gone. The
repo (`christopherpow/nes-test-roms`) has **no LICENSE file** (confirmed: `GET
/LICENSE`, `/LICENSE.md`, `/LICENSE.txt`, `/license.txt` all 404) and GitHub's
own repo-metadata API reports `"license": null`. On the NESdev forum's
["Legal ROMs"](https://forums.nesdev.org/viewtopic.php?t=8943) thread, the
maintainer (forum handle `cpow`) describes the collection as "test ROMs put
together by blargg or other NES RE geniuses," distributed with the original
author's permission — informal permission to mirror, not a written open-source
license.

### Suite with an explicit, unambiguous license (supplementary option)

[`bbbradsmith/nes-audio-tests`](https://github.com/bbbradsmith/nes-audio-tests)
(Brad Smith, not Blargg — a newer/alternate APU-focused suite sometimes cited
alongside Blargg's `apu_test`) states in its readme, verbatim:

> "These files may be freely redistributed and modified for any purpose. Credit
> to the original author and/or a link to the original source would be
> appreciated, but is not required."

This is the one suite in this research with a clean, explicit permissive grant
and no ambiguity — worth knowing about if the team wants at least one ROM in the
gate with zero-question provenance.

---

## Sources consulted

- NESdev wiki, [Emulator tests](https://www.nesdev.org/wiki/Emulator_tests) — canonical list of test ROMs, current/dead links, and the GitHub-mirror endorsement.
- `https://www.qmtpro.com/~nes/misc/nestest.txt` — nestest's own documentation (fetched and read in full).
- `https://www.qmtpro.com/~nes/misc/nestest.log` and `http://nickmass.com/images/nestest.nes` — canonical nestest artifacts (liveness verified).
- [christopherpow/nes-test-roms](https://github.com/christopherpow/nes-test-roms) — GitHub mirror endorsed by the NESdev wiki; `readme.txt` files for `instr_test-v5`, `instr_timing`, `ppu_vbl_nmi`, `apu_test` fetched and diffed directly from raw GitHub content.
- GitHub REST API (`api.github.com/repos/christopherpow/nes-test-roms`) — confirms `license: null`, no declared license.
- NESdev forum, [Legal ROMs](https://forums.nesdev.org/viewtopic.php?t=8943) — community discussion distinguishing homebrew/test-ROM distribution (author-permitted) from commercial-ROM piracy.
- NESdev forum, [Blargg's test roms](https://forums.nesdev.org/viewtopic.php?t=9872) and [blargg's instruction tests issue](https://forums.nesdev.org/viewtopic.php?t=12002) — background on distribution history.
- [bbbradsmith/nes-audio-tests](https://github.com/bbbradsmith/nes-audio-tests) — explicit permissive-license comparator suite.
