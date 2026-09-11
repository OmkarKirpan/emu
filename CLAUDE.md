# emu

## Agent skills

### Issue tracker

Linear (workspace: OmkarKirpan, team: Engineering, project: [NES Emulator (WebAssembly)](https://linear.app/okirpan/project/nes-emulator-webassembly-ce94d622c29f)). See [docs/agents/issue-tracker.md](docs/agents/issue-tracker.md).

### Triage labels

Default vocabulary (needs-triage, needs-info, ready-for-agent, ready-for-human, wontfix). See [docs/agents/triage-labels.md](docs/agents/triage-labels.md).

### Domain docs

Single-context (one `CONTEXT.md` + `docs/adr/` at the repo root). See [CONTEXT.md](CONTEXT.md) and [docs/agents/domain.md](docs/agents/domain.md).

## Planning status

Planning is complete — see [NES Emulator — Implementation-Ready Spec](https://linear.app/okirpan/issue/ENG-54/nes-emulator-implementation-ready-spec) (ENG-54) on Linear for the full decision record.

Execution has reached the end of the roadmap in [Milestone roadmap & build sequencing](https://linear.app/okirpan/issue/ENG-63/milestone-roadmap-and-build-sequencing) (ENG-63). **M0 through M8 are all done** — repo scaffolding, the CPU, PPU background and sprites, the single-threaded wasm host, the threaded Worker/SharedArrayBuffer pipeline, the APU, the MMC1/UxROM/CNROM/MMC3 mappers, and save-states/SRAM. M9 is deliberately unscoped polish, and the roadmap treats the destination as reached without it.

What is left is individual issues rather than milestones. **Do not trust a list of them here** — it will go stale. Check the [project board](https://linear.app/okirpan/project/nes-emulator-webassembly-ce94d622c29f) for live status.
