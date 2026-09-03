# Issue tracker: Linear

Issues for this repo live in Linear.

- **Workspace:** OmkarKirpan (https://linear.app/okirpan)
- **Team:** Engineering (only team in the workspace — no ambiguity, no per-issue team prompt needed)
- **Project:** [NES Emulator (WebAssembly)](https://linear.app/okirpan/project/nes-emulator-webassembly-ce94d622c29f) — assign every issue for this effort to it (`save_issue`'s `project` param)
- **PRs as a request surface:** off (default)
- **Custom views:** not manageable via this MCP tool (no `save_view`/`create_view` in its surface — Linear views are UI-only here). If a saved filter would help, describe the filter criteria to the user and have them create it in the Linear UI; the project board/timeline above already gives most of what a view would.

## Wayfinding operations

Used by `/wayfinder`. Linear's native data model maps directly onto wayfinder's — no local-file fallback needed.

- **Map:** a Linear issue labeled `wayfinder:map`. Current map: [NES Emulator — Implementation-Ready Spec](https://linear.app/okirpan/issue/ENG-54/nes-emulator-implementation-ready-spec) (ENG-54).
- **Child ticket:** a sub-issue (`parentId` = the map's issue id) labeled `wayfinder:research` / `wayfinder:prototype` / `wayfinder:grilling` / `wayfinder:task`. The question lives under a `## Question` heading in the issue description.
- **Blocking:** Linear's native `blockedBy` / `blocks` issue relations (set via `save_issue`'s `blockedBy`/`blocks` params). A ticket is unblocked when every issue in its `blockedBy` list has state type `completed` (or `canceled`, if it turned out to be out of scope).
- **Frontier:** `list_issues` with `parentId` = the map's id, `state` a non-completed/non-canceled type, and `assignee` empty; fetch relations (`get_issue` with `includeRelations: true`) to confirm each candidate has no open blocker. First created (lowest issue number) wins when order matters.
- **Claim:** `save_issue` with `assignee: "me"` on the ticket, before any work.
- **Resolve:** append the answer under the ticket's `## Answer` heading (`save_issue` with `patch`, or `description`), set `state` to a completed status (e.g. `"Done"`), post a `save_comment` noting the resolution, then append a one-line gist + link to the map's `## Decisions so far` section (`save_issue` with `patch` against the map issue).
- **Labels:** `wayfinder:map`, `wayfinder:research`, `wayfinder:prototype`, `wayfinder:grilling`, `wayfinder:task` already exist as workspace-level labels — reuse them, don't recreate.

## When a skill says "publish to the issue tracker"

Create a Linear issue via `save_issue` (team: Engineering).

## When a skill says "fetch the relevant ticket"

`get_issue` with the Linear identifier (e.g. `ENG-60`) the user or map gives you.
