# emu

A cycle-accurate NES emulator, written from scratch in Zig and compiled to WebAssembly, with a React/TypeScript/Vite host shell rendering via WebGPU (Canvas 2D fallback). Learning project — depth over shortcuts.

Planning is tracked as a wayfinder map on Linear (workspace: OmkarKirpan, team: Engineering) — see `docs/agents/issue-tracker.md`. The map is complete; implementation follows the milestone roadmap it produced, starting from `core/` (Zig, native + wasm32) and `web/` (React+TS+Vite).
