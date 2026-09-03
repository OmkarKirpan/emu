# Zig wasm32-freestanding: threading/atomics feasibility + version to pin

Research for ENG-56 (parent: ENG-54, lock core architecture & tech stack).

## Bottom line

**Feasible.** Zig's `wasm32-freestanding` target can produce a module with growable
*shared* linear memory and real WebAssembly atomic instructions (`i32.atomic.rmw*`,
`memory.atomic.wait32`/`notify`, etc.), which is exactly what's needed to synchronize a
lock-free `SharedArrayBuffer` ring buffer between a Web Worker and an `AudioWorkletProcessor`.
This requires explicitly opting in to the `atomics` (+ usually `bulk-memory`) CPU features
and setting the `shared_memory` / `max_memory` linker options in `build.zig` — none of this
is the default. `std.atomic.Value(T)` (plain atomic load/store/RMW) is architecture-agnostic
and works fine under freestanding with no OS. Zig even ships a wasm-specific futex
implementation using `memory.atomic.wait32`/`notify`, gated on the `atomics` CPU feature and
selected by CPU architecture (not OS), so it *is* reachable from `wasm32-freestanding` too —
though the ring buffer itself likely only needs plain atomics, not wait/notify.

**Recommended version to pin: Zig 0.16.0** (current stable, released 2026-04-13). Use the
default LLVM-backed codegen (do not pass `-fno-llvm`/`use_llvm = false`) — Zig's self-hosted
backend has an open, unresolved bug that corrupts wasm data segments, and LLVM remains the
documented/default code generator for wasm targets in 0.16.0. Re-evaluate before adopting
0.17.x, since 0.16.0 already renamed `std.Thread.Futex` to `std.Io.Futex` as part of an
in-progress `std.Io` interface overhaul — avoid depending on that API directly and build the
ring buffer on the lower-level atomic builtins instead, which sidesteps the churn.

---

## 1. Compiler flags / build.zig options for shared memory + atomics on wasm32-freestanding

Zig's wasm CPU-feature enum (`std.Target.wasm.Feature`, mirroring LLVM's WebAssembly target
features) includes `atomics`, `bulk_memory`, `bulk_memory_opt`, `multimemory`, `simd128`,
etc. ([`lib/std/Target/wasm.zig`, ziglang/zig `master`](https://github.com/ziglang/zig/blob/master/lib/std/Target/wasm.zig)).

Critically, **the `generic` CPU model Zig uses by default for wasm does *not* include
`atomics`** — only enables `bulk_memory`, `multivalue`, `mutable_globals`,
`nontrapping_fptoint`, `reference_types`, `sign_ext`. The only built-in CPU model that
includes `atomics` is `bleeding_edge` (`atomics`, `bulk_memory`, `exception_handling`,
`extended_const`, `fp16`, `multimemory`, `multivalue`, `mutable_globals`,
`nontrapping_fptoint`, `reference_types`, `relaxed_simd`, `sign_ext`, `simd128`, `tail_call`)
([same source](https://github.com/ziglang/zig/blob/master/lib/std/Target/wasm.zig)). So you
must either pass `-mcpu=bleeding_edge` or explicitly add the feature on top of a baseline
CPU, e.g. `-mcpu=generic+atomics+bulk_memory` on the CLI, or in `build.zig` via
`cpu_features_add` on the `std.Target.Query` (`.cpu_arch = .wasm32, .os_tag = .freestanding`)
([Ziggit thread: "Wasm32-freestanding in Zig build system"](https://ziggit.dev/t/wasm32-freestanding-in-zig-build-system/6340)).

For the linker side, `std.Build.Step.Compile` exposes the relevant fields directly
(confirmed by reading `lib/std/Build/Step/Compile.zig` on `ziglang/zig` `master`,
[github.com/ziglang/zig/blob/master/lib/std/Build/Step/Compile.zig](https://github.com/ziglang/zig/blob/master/lib/std/Build/Step/Compile.zig)):

```zig
import_memory: bool = false,
export_memory: bool = false,
initial_memory: ?u64 = null,
max_memory: ?u64 = null,
shared_memory: bool = false,
stack_size: ?u64 = null,
```

These map to Zig's internal `wasm-ld` invocation, equivalent to passing `--import-memory`,
`--export-memory`, `--initial-memory=`, `--max-memory=`, and `--shared-memory` directly to
`wasm-ld`. Typical usage reported in the community
([0xkiire.com Zig 0.16.0 wasm tutorial](https://0xkiire.com/wasm-with-zig/), corroborated by
the `build.zig` field names above):

```zig
exe.shared_memory = true;
exe.initial_memory = 2 * 65536;    // pages are 64 KiB
exe.max_memory     = 256 * 65536;  // required — see below
```

**`max_memory` is not optional when `shared_memory = true`.** The WebAssembly threads/atomics
proposal itself mandates this: "shared linear memory without an explicit maximum size is not
permitted. This allows the embedder to reserve enough virtual memory for the maximum size..."
([WebAssembly/threads proposal, `Overview.md`](https://github.com/WebAssembly/threads/blob/main/proposals/threads/Overview.md)).
Omitting `max_memory` on a `shared_memory = true` build will fail validation. Note also that
per the same proposal, atomic instructions themselves are legal on *both* shared and
unshared memories — the `shared` flag is what changes wait/notify semantics and what the host
(browser) requires to back the memory with a `SharedArrayBuffer`.

Also needed on the entry-point/executable side for a freestanding "library" module: disable
the entry point and enable dynamic exports, e.g.

```zig
const wasm = b.addExecutable(.{
    .name = "core",
    .root_source_file = b.path("src/root.zig"),
    .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
    .optimize = optimize,
});
wasm.entry = .disabled;
wasm.rdynamic = true;
```
([Ziggit thread cited above](https://ziggit.dev/t/wasm32-freestanding-in-zig-build-system/6340)).

## 2. Does std.atomic lower correctly with no OS (freestanding)?

Yes, for plain atomics. `std.atomic.Value(T)` (source read from
[`lib/std/atomic.zig` on `ziglang/zig` `master`](https://raw.githubusercontent.com/ziglang/zig/master/lib/std/atomic.zig))
is a thin, architecture-agnostic wrapper over Zig's `@atomicLoad`/`@atomicStore`/`@atomicRmw`/
`@cmpxchgWeak`/`@cmpxchgStrong` builtins — `load`, `store`, `swap`, `cmpxchgWeak/Strong`,
`fetchAdd/Sub/Min/Max/And/Nand/Xor/Or`, `bitSet/Reset/Toggle`, plus `spinLoopHint` and a
`cache_line` constant. Nothing in this file is OS-gated; it compiles for any target LLVM can
lower atomics for, including `wasm32-freestanding`, provided the target CPU has the
`atomics` feature enabled (see below for what happens if it doesn't).

Zig's std lib goes further and ships a genuine WebAssembly futex, using inline `memory.atomic.wait32`/`memory.atomic.notify` wasm instructions, in `std.Thread.Futex`
(read from [`lib/std/Thread/Futex.zig` on `master`](https://raw.githubusercontent.com/ziglang/zig/master/lib/std/Thread/Futex.zig)).
Its top-level `Impl` selection is:

```zig
const Impl = if (builtin.single_threaded)
    SingleThreadedImpl
else if (builtin.os.tag == .windows)
    WindowsImpl
else if (builtin.os.tag.isDarwin())
    DarwinImpl
else if (builtin.os.tag == .linux)
    LinuxImpl
...
else if (builtin.target.cpu.arch.isWasm())
    WasmImpl
else if (std.Thread.use_pthreads)
    PosixImpl
else
    UnsupportedImpl;
```

`WasmImpl` is selected by **CPU architecture**, not OS tag, so it applies to
`wasm32-freestanding` as well as `wasm32-wasi` — as long as the build is not
`single_threaded` (freestanding wasm may default to `single_threaded = true`; this must be
explicitly overridden). `WasmImpl.wait` itself hard-requires the `atomics` feature:

```zig
if (!comptime builtin.cpu.has(.wasm, .atomics)) @compileError("WASI target missing cpu feature 'atomics'");
```

and its `wake`/notify path notes the wake count "can be 0 when linker flag 'shared-memory'
is not enabled" — i.e. it compiles either way, but only actually functions cross-context when
`shared_memory` is turned on. For a **lock-free SPSC ring buffer** (the described use case),
plain `std.atomic.Value` load/store with acquire/release ordering is normally sufficient and
avoids depending on Futex/`std.Io` entirely — recommended, since Futex's home namespace is
mid-refactor (see version discussion below).

**Caveat worth flagging:** LLVM's WebAssembly backend silently lowers atomic RMW/cmpxchg
builtins to *non-atomic* instruction sequences when the `atomics` target feature is not
enabled, and marks the resulting object as "no longer thread-safe." `wasm-ld` then refuses to
link such an object into a module that also requests `--shared-memory`
([LLVM code review D59281, "\[WebAssembly\] 'atomics' feature requires shared memory"](https://reviews.llvm.org/D59281);
corroborating LLVM WebAssembly backend behavior discussion). Practically this means: forgetting
`+atomics` on any object doesn't silently produce a racy binary — the link step fails loudly —
but it does mean every compilation unit that participates in the shared module must be built
with the feature turned on consistently.

## 3. Which Zig version to pin

Checked directly against [ziglang.org/download](https://ziglang.org/download/) (fetched
2026-09-03): current stable is **0.16.0** (released 2026-04-13); previous stable is 0.15.2
(2025-10-11); `master` is pre-0.17 dev.

Recommend pinning **0.16.0**:

- It's the actively-maintained stable release (LLVM upgraded to LLVM 21 per
  [0.16.0 release notes](https://ziglang.org/download/0.16.0/release-notes.html)).
- The release notes' target-support table lists `wasm32-wasi` as Tier 2 with LLVM-based code
  gen (🖥️🛠️); `wasm32-freestanding` isn't in the tiered table but is listed under
  "Additional Platforms" as supported — same LLVM backend applies since Zig's self-hosted
  backend is not the default for wasm.
- LLVM stays the default codegen path for wasm targets in 0.16.0. This matters because the
  self-hosted backend has an **open, unresolved bug corrupting wasm data segments**
  (`invalid data segment flags: 0x8`) when a threadlocal is combined with `std.debug.print`,
  reproduced by a user who had `use_llvm = false` set
  ([ziglang/zig issue #25888, open](https://github.com/ziglang/zig/issues/25888)). Do not set
  `use_llvm = false` / `-fno-llvm` for this target.
- Risk to track: 0.16.0's release notes list `std.Thread.Futex ➡️ std.Io.Futex`,
  `std.Thread.Mutex ➡️ std.Io.Mutex`, etc. as part of a new `std.Io` interface
  ([0.16.0 release notes](https://ziglang.org/download/0.16.0/release-notes.html)) — i.e. the
  concurrency-primitive namespace is actively being restructured release-to-release. Building
  directly on `std.atomic.Value` and raw `@atomicLoad`/`@atomicRmw` (stable, low-level,
  unaffected by the `std.Io` churn) rather than on `std.Thread.Futex`/`std.Io.Futex` avoids
  taking on that instability for the ring-buffer synchronization itself.
- 0.15.2 is a reasonable fallback if 0.16.0-specific regressions surface, but has no
  particular advantage here: the `shared_memory`/`max_memory`/`atomics`-feature mechanics
  described above are long-standing, not new to 0.16.0.

## 4. Known open issues / limitations worth flagging as risk

- **wasm self-hosted backend wasm data-segment corruption** — open, `ziglang/zig` **#25888**,
  reproduces with `use_llvm = false` and a threadlocal + `std.debug.print`; not shared-memory
  specific but confirms the self-hosted wasm backend is not yet trustworthy — stick to the
  LLVM default. https://github.com/ziglang/zig/issues/25888
- **`@memcpy` panicked on shared-memory wasm** — `ziglang/zig` **#15920**, filed against a
  0.11.0-dev snapshot, root-caused to the `@memcpy` lowering and fixed via PR #16345, now
  **closed**. Included here as a reminder that shared-memory-specific miscompilations have
  happened before in this exact area (bulk-memory/memcpy on shared wasm memory); worth a
  regression check against whatever version is ultimately pinned.
  https://github.com/ziglang/zig/issues/15920
- **No general-purpose multi-thread stack management for `wasm32-freestanding`** — if the
  design ever grows beyond "two independent wasm instances communicating via a shared,
  lock-free ring buffer" into "one wasm module, multiple logical threads spawned via
  `std.Thread.spawn` sharing one instance," Zig has no built-in per-thread stack allocator for
  freestanding wasm (unlike Emscripten's pthread emulation) — a Ziggit user notes "workers
  sharing the same wasm memory will end up stepping on each other's toes as they all use the
  same stack" absent manual stack partitioning
  ([Ziggit: "State of concurrency support on wasm32-freestanding?"](https://ziggit.dev/t/state-of-concurrency-support-on-wasm32-freestanding/1465)).
  Not a blocker for the ring-buffer design as scoped (each JS execution context — Worker,
  AudioWorkletProcessor — gets its own wasm instance/stack; they only share the linear memory
  region used for the ring buffer), but worth keeping the scope boundary explicit in the
  architecture doc so nobody later assumes `std.Thread.spawn` "just works" inside one
  freestanding instance.
- **`std.Thread.Futex` → `std.Io.Futex` rename** in 0.16.0 release notes — API churn risk
  noted above; avoid depending on it for the ring buffer, or pin tightly and budget time to
  follow the rename if a future upgrade is needed.
  https://ziglang.org/download/0.16.0/release-notes.html

## Sources consulted (primary)

- ziglang.org: [download page](https://ziglang.org/download/), [0.16.0 release notes](https://ziglang.org/download/0.16.0/release-notes.html)
- ziglang/zig GitHub source (master, read directly): `lib/std/Target/wasm.zig`, `lib/std/Build/Step/Compile.zig`, `lib/std/atomic.zig`, `lib/std/Thread/Futex.zig`
- ziglang/zig GitHub issues: [#25888](https://github.com/ziglang/zig/issues/25888) (open), [#15920](https://github.com/ziglang/zig/issues/15920) (closed)
- WebAssembly/threads proposal spec: [Overview.md](https://github.com/WebAssembly/threads/blob/main/proposals/threads/Overview.md)
- LLVM code review: [D59281 "[WebAssembly] 'atomics' feature requires shared memory"](https://reviews.llvm.org/D59281)
- Zig community (used only as pointers to the above, not as authority): [Ziggit — "Wasm32-freestanding in Zig build system"](https://ziggit.dev/t/wasm32-freestanding-in-zig-build-system/6340), [Ziggit — "State of concurrency support on wasm32-freestanding?"](https://ziggit.dev/t/state-of-concurrency-support-on-wasm32-freestanding/1465)
