# M0 — Repo Scaffolding & Mapper Interface Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the `core/` (Zig) and `web/` (React+TS+Vite) halves of the monorepo, with a `build.zig` that builds both a native and a wasm32-freestanding target, an iNES ROM-header parser, a mapper interface shaped for future switchable-bank mappers, an NROM implementation of it, and CI running the native test suite on every push/PR — so M1 (CPU core) has a repo, a test harness, and a way to load a ROM to start from.

**Architecture:** `core/` is a Zig package exposing one module (`nes_core`) whose root file re-exports `rom.zig` (iNES parsing + `Rom.load`) and `mapper.zig` (the `Mapper` tagged union + `Nrom`). The mapper set is closed and small (5 mappers total across the whole project, per the map's "Out of scope" — NROM/MMC1/UxROM/CNROM/MMC3), so `Mapper` is a `union(enum)` dispatched with `inline else => |*m| ...` rather than a vtable: this is zero-cost (no heap allocation, no indirect call) and — critically — because the switch operates on the dereferenced pointer (a place expression) with a pointer capture, it does **not** copy the union's payload (which will eventually hold each mapper's bank-switching state) on every dispatch. `web/` is a bare Vite scaffold for now; the wasm-loading/worker/COOP-COEP wiring from "Vite: bundling the Worker + wasm asset" is M4/M5's job, not M0's.

**Tech Stack:** Zig 0.16.0 (pinned, already installed locally and matches `zig version`), Zig's built-in `std.testing` (no third-party test framework), GitHub Actions, Vite + React + TypeScript (scaffolded via `npm create vite@latest`, not hand-configured).

## Global Constraints

- Zig version: **0.16.0** exactly (`minimum_zig_version` in `build.zig.zon`; matches the locally installed `zig version` output).
- Correctness is established **only** by the native target (`zig build test`); the wasm32 target is pure delivery and is never where a test runs — per "Test-ROM harness architecture" (ENG-64). `zig build wasm` must succeed but has no test step of its own.
- Repo layout: single monorepo, `core/` (Zig) + `web/` (React+TS+Vite), MIT licensed — per "Lock core architecture & tech stack" (ENG-55).
- Mapper set is closed: only NROM (mapper 0) is implemented in M0. `createMapper` must return `error.UnsupportedMapper` for every other mapper number rather than silently misbehaving — MMC1/UxROM/CNROM/MMC3 arrive in M7, gated per-mapper.
- No CPU, no PPU, no wasm export ABI (`alloc`/`load_rom`/`step_frame`/etc. — that's ENG-60, M4), no threading/SharedArrayBuffer (ENG-56, M5), no save-states (M8). Do not build any of these now, even as stubs — YAGNI.
- Repo is currently on `main` (the default branch). Do not commit scaffolding directly to `main` — branch first.
- GitHub repo already exists: `github.com/OmkarKirpan/emu`, default branch `main`, `gh` authenticated as `OmkarKirpan`.

---

## File Structure

```
core/
  build.zig            # native module + test step; wasm32-freestanding build step
  build.zig.zon         # package manifest, pinned to Zig 0.16.0
  src/
    root.zig            # module entry point; re-exports rom.zig and mapper.zig; pulls their tests in
    rom.zig              # iNES header parsing, Rom.load, createMapper
    mapper.zig           # Mapper tagged union interface + Nrom implementation
.github/
  workflows/
    ci.yml               # zig build test + zig build wasm on push/PR to main
web/                     # npm create vite@latest scaffold (react-ts template), untouched beyond default
.gitignore               # root-level: zig-cache/zig-out under core/, node_modules/dist under web/
```

No existing files are modified except `CLAUDE.md` and `README.md` (Task 7, to drop the "no emulator code yet" planning-phase framing now that M0 lands code) and the repo root gaining a `.gitignore` (currently absent).

---

### Task 1: Branch, root `.gitignore`, and the Zig project skeleton

**Files:**
- Create: `.gitignore`
- Create: `core/build.zig`
- Create: `core/build.zig.zon`
- Create: `core/src/root.zig`

**Interfaces:**
- Produces: a `nes_core` Zig module buildable for native (`zig build test`, from `core/`) and wasm32-freestanding (`zig build wasm`, from `core/`). Later tasks add files that `root.zig` imports.

- [ ] **Step 1: Create the feature branch**

```bash
cd C:/Users/okirp/projects/emu
git checkout -b m0-repo-scaffolding
```

- [ ] **Step 2: Add the root `.gitignore`**

```gitignore
# Zig
.zig-cache/
zig-out/

# Node / Vite
node_modules/
dist/
dist-ssr/
*.local
```

- [ ] **Step 3: Create `core/build.zig.zon`**

```zig
.{
    .name = .nes_core,
    .version = "0.0.0",
    .fingerprint = 0x4f17384b8528942,
    .minimum_zig_version = "0.16.0",
    .dependencies = .{},
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
    },
}
```

The `fingerprint` value above was generated by running `zig build` against this exact package name (`nes_core`) — it is a real, stable identifier for this package, not a placeholder. Leave it as-is.

- [ ] **Step 4: Create `core/build.zig`**

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The native module: this is what `zig build test` compiles and runs.
    // Per "Test-ROM harness architecture" (ENG-64), correctness is established
    // ONLY on the native target — the wasm32 build below is pure delivery.
    const mod = b.addModule("nes_core", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    // The wasm32-freestanding build: proves the module compiles for the
    // delivery target. No shared_memory/atomics yet (that's ENG-56, M5) and
    // no exported ABI functions yet (that's ENG-60, M4) — this step exists
    // purely so a wasm regression is caught before those milestones need it.
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });
    const wasm_exe = b.addExecutable(.{ .name = "nes_core", .root_module = wasm_mod });
    wasm_exe.entry = .disabled;
    wasm_exe.rdynamic = true;
    const wasm_step = b.step("wasm", "Build the wasm32-freestanding module");
    wasm_step.dependOn(&b.addInstallArtifact(wasm_exe, .{}).step);
}
```

- [ ] **Step 5: Create `core/src/root.zig`**

```zig
test {
    // Later tasks add `_ = @import("rom.zig");` and `_ = @import("mapper.zig");`
    // here so their test blocks are pulled into `zig build test`.
}
```

- [ ] **Step 6: Verify both build targets succeed**

Run: `cd core && zig build test --summary all`
Expected: `Build Summary: ... steps succeeded; 1/1 tests passed` (the lone test is `root.zig`'s own empty `test { }` block — Zig counts it even though it has no assertions; this just proves the module compiles and the test runner wires up).

Run: `zig build wasm`
Expected: exits 0, and `core/zig-out/bin/nes_core.wasm` exists.

- [ ] **Step 7: Commit**

```bash
git add .gitignore core/build.zig core/build.zig.zon core/src/root.zig
git commit -m "chore(core): scaffold Zig package with native+wasm32 build targets"
```

---

### Task 2: iNES header parser

**Files:**
- Create: `core/src/rom.zig`
- Modify: `core/src/root.zig`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces (for Task 3 and Task 4 to consume):
  - `pub const Mirroring = enum { horizontal, vertical, four_screen };`
  - `pub const Header = struct { prg_rom_size: usize, chr_rom_size: usize, mapper: u8, mirroring: Mirroring, has_battery: bool, has_trainer: bool };`
  - `pub const ParseError = error{ TooShort, BadMagic };`
  - `pub fn parseHeader(data: []const u8) ParseError!Header`

- [ ] **Step 1: Write the failing tests**

Create `core/src/rom.zig`:

```zig
const std = @import("std");
const testing = std.testing;

pub const Mirroring = enum { horizontal, vertical, four_screen };

pub const Header = struct {
    prg_rom_size: usize,
    chr_rom_size: usize,
    mapper: u8,
    mirroring: Mirroring,
    has_battery: bool,
    has_trainer: bool,
};

pub const ParseError = error{ TooShort, BadMagic };

fn buildMinimalNrom(comptime prg_banks: u8, comptime chr_banks: u8) [16 + @as(usize, prg_banks) * 16384 + @as(usize, chr_banks) * 8192]u8 {
    var buf: [16 + @as(usize, prg_banks) * 16384 + @as(usize, chr_banks) * 8192]u8 =
        [_]u8{0} ** (16 + @as(usize, prg_banks) * 16384 + @as(usize, chr_banks) * 8192);
    buf[0] = 'N';
    buf[1] = 'E';
    buf[2] = 'S';
    buf[3] = 0x1A;
    buf[4] = prg_banks;
    buf[5] = chr_banks;
    buf[6] = 0x00;
    buf[7] = 0x00;
    return buf;
}

test "parseHeader rejects buffers shorter than 16 bytes" {
    try testing.expectError(ParseError.TooShort, parseHeader(&[_]u8{ 'N', 'E', 'S' }));
}

test "parseHeader rejects a bad magic number" {
    var bad = buildMinimalNrom(2, 1);
    bad[0] = 'X';
    try testing.expectError(ParseError.BadMagic, parseHeader(&bad));
}

test "parseHeader reads PRG/CHR sizes in bank units" {
    const buf = buildMinimalNrom(2, 1);
    const h = try parseHeader(&buf);
    try testing.expectEqual(@as(usize, 32768), h.prg_rom_size);
    try testing.expectEqual(@as(usize, 8192), h.chr_rom_size);
}

test "parseHeader splits the mapper number across flags 6 and 7" {
    var buf = buildMinimalNrom(2, 1);
    buf[6] = 0x10; // mapper low nibble = 1
    buf[7] = 0x20; // mapper high nibble = 2 -> mapper (2<<4)|1 = 33
    const h = try parseHeader(&buf);
    try testing.expectEqual(@as(u8, 33), h.mapper);
}

test "parseHeader reads mirroring, battery, and trainer flags" {
    var buf = buildMinimalNrom(2, 1);
    buf[6] = 0b0000_0111; // vertical(bit0) + battery(bit1) + trainer(bit2)
    const h = try parseHeader(&buf);
    try testing.expectEqual(Mirroring.vertical, h.mirroring);
    try testing.expect(h.has_battery);
    try testing.expect(h.has_trainer);
}

test "parseHeader four-screen flag overrides the horizontal/vertical bit" {
    var buf = buildMinimalNrom(2, 1);
    buf[6] = 0b0000_1001; // vertical bit set AND four-screen bit set
    const h = try parseHeader(&buf);
    try testing.expectEqual(Mirroring.four_screen, h.mirroring);
}
```

- [ ] **Step 2: Wire the test into `root.zig` and confirm it fails to compile**

Update `core/src/root.zig`:

```zig
const rom = @import("rom.zig");

test {
    _ = rom;
}
```

Run: `cd core && zig build test`
Expected: **compile error** — `parseHeader` is not defined. This is the RED state (Zig TDD's equivalent of a failing test is a compile error when the function under test doesn't exist yet).

- [ ] **Step 3: Implement `parseHeader`**

Append to `core/src/rom.zig` (after `ParseError`, before the `buildMinimalNrom` test helper):

```zig
pub fn parseHeader(data: []const u8) ParseError!Header {
    if (data.len < 16) return ParseError.TooShort;
    if (!std.mem.eql(u8, data[0..4], &[_]u8{ 'N', 'E', 'S', 0x1A })) return ParseError.BadMagic;

    const flags6 = data[6];
    const flags7 = data[7];
    const mapper: u8 = (flags6 >> 4) | (flags7 & 0xF0);
    const four_screen = (flags6 & 0x08) != 0;
    const mirroring: Mirroring = if (four_screen)
        .four_screen
    else if ((flags6 & 0x01) != 0)
        .vertical
    else
        .horizontal;

    return Header{
        .prg_rom_size = @as(usize, data[4]) * 16384,
        .chr_rom_size = @as(usize, data[5]) * 8192,
        .mapper = mapper,
        .mirroring = mirroring,
        .has_battery = (flags6 & 0x02) != 0,
        .has_trainer = (flags6 & 0x04) != 0,
    };
}
```

Note: NES 2.0 header extensions (the `flags7 & 0x0C == 0x08` signature, PRG/CHR-RAM size bytes 10-11, etc.) are deliberately **not** handled — iNES 1.0 is sufficient to identify NROM and extract PRG/CHR banks, which is all M0's exit criteria requires. Flag as a fog item if a future ROM needs NES 2.0-only fields.

- [ ] **Step 4: Run tests, confirm all pass**

Run: `zig build test --summary all`
Expected: `7/7 tests passed` (root's own empty test block + the 6 new ones).

- [ ] **Step 5: Commit**

```bash
git add core/src/rom.zig core/src/root.zig
git commit -m "feat(core): parse iNES ROM headers"
```

---

### Task 3: Mapper interface + NROM

**Files:**
- Create: `core/src/mapper.zig`
- Modify: `core/src/root.zig`

**Interfaces:**
- Consumes: nothing from Task 2 (mapper.zig is standalone; `rom.zig` will depend on it in Task 4, not the other way around).
- Produces (for Task 4 to consume):
  - `pub const Nrom = struct { ... pub fn init(prg_rom: []const u8, chr_rom: []const u8) Nrom ... }`
  - `pub const Mapper = union(enum) { nrom: Nrom, pub fn prgRead(self: *const Mapper, addr: u16) u8, pub fn prgWrite(self: *Mapper, addr: u16, value: u8) void, pub fn chrRead(self: *const Mapper, addr: u16) u8, pub fn chrWrite(self: *Mapper, addr: u16, value: u8) void, pub fn irqPending(self: *const Mapper) bool, pub fn irqAcknowledge(self: *Mapper) void };`

- [ ] **Step 1: Write the failing tests**

Create `core/src/mapper.zig`:

```zig
const std = @import("std");
const testing = std.testing;

/// NROM (mapper 0): fixed PRG banking (16KB mirrored to fill $8000-$FFFF, or
/// 32KB unmirrored), fixed CHR banking (8KB CHR-ROM, or 8KB CHR-RAM when the
/// cartridge has no CHR-ROM). No bank-switch registers, no IRQ — the simplest
/// possible implementation of the Mapper interface, but the interface itself
/// is shaped for MMC1/UxROM/CNROM/MMC3 (M7), which do have bank switching and
/// (MMC3) an IRQ.
pub const Nrom = struct {
    prg_rom: []const u8,
    chr: [0x2000]u8 = [_]u8{0} ** 0x2000,
    chr_is_ram: bool,

    pub fn init(prg_rom: []const u8, chr_rom: []const u8) Nrom {
        var self = Nrom{ .prg_rom = prg_rom, .chr_is_ram = chr_rom.len == 0 };
        if (!self.chr_is_ram) @memcpy(self.chr[0..chr_rom.len], chr_rom);
        return self;
    }

    pub fn prgRead(self: *const Nrom, addr: u16) u8 {
        const offset = (addr - 0x8000) % @as(u16, @intCast(self.prg_rom.len));
        return self.prg_rom[offset];
    }

    pub fn prgWrite(self: *Nrom, addr: u16, value: u8) void {
        // NROM has no bank-switch registers: writes to PRG space are no-ops,
        // matching real hardware (there's no PRG-RAM on the base cartridge).
        _ = self;
        _ = addr;
        _ = value;
    }

    pub fn chrRead(self: *const Nrom, addr: u16) u8 {
        return self.chr[addr];
    }

    pub fn chrWrite(self: *Nrom, addr: u16, value: u8) void {
        if (self.chr_is_ram) self.chr[addr] = value;
    }

    pub fn irqPending(self: *const Nrom) bool {
        _ = self;
        return false;
    }

    pub fn irqAcknowledge(self: *Nrom) void {
        _ = self;
    }
};

test "Nrom.prgRead mirrors a 16KB bank across the full $8000-$FFFF window" {
    var prg = [_]u8{0xAA} ** 0x4000;
    prg[0] = 0x11;
    var m = Mapper{ .nrom = Nrom.init(&prg, &.{}) };
    try testing.expectEqual(@as(u8, 0x11), m.prgRead(0x8000));
    try testing.expectEqual(@as(u8, 0x11), m.prgRead(0xC000)); // mirrored copy
}

test "Nrom.prgRead does not mirror a full 32KB bank" {
    var prg = [_]u8{0xAA} ** 0x8000;
    prg[0] = 0x11;
    prg[0x4000] = 0x33;
    var m = Mapper{ .nrom = Nrom.init(&prg, &.{}) };
    try testing.expectEqual(@as(u8, 0x11), m.prgRead(0x8000));
    try testing.expectEqual(@as(u8, 0x33), m.prgRead(0xC000));
}

test "Nrom.prgWrite is a no-op" {
    var prg = [_]u8{0x11} ** 0x4000;
    var m = Mapper{ .nrom = Nrom.init(&prg, &.{}) };
    m.prgWrite(0x8000, 0xFF);
    try testing.expectEqual(@as(u8, 0x11), m.prgRead(0x8000));
}

test "Nrom.chrWrite is a no-op for CHR-ROM but honored for CHR-RAM" {
    const chr = [_]u8{0x42} ** 0x2000;
    var m_rom = Mapper{ .nrom = Nrom.init(&.{}, &chr) };
    m_rom.chrWrite(0, 0xFF);
    try testing.expectEqual(@as(u8, 0x42), m_rom.chrRead(0)); // unchanged: real CHR-ROM

    var m_ram = Mapper{ .nrom = Nrom.init(&.{}, &.{}) }; // no CHR-ROM => CHR-RAM
    m_ram.chrWrite(0, 0xFF);
    try testing.expectEqual(@as(u8, 0xFF), m_ram.chrRead(0)); // honored: CHR-RAM
}

test "Nrom never raises an IRQ" {
    var m = Mapper{ .nrom = Nrom.init(&.{}, &.{}) };
    try testing.expect(!m.irqPending());
    m.irqAcknowledge(); // must not panic
}
```

- [ ] **Step 2: Wire the test into `root.zig` and confirm it fails to compile**

Update `core/src/root.zig`:

```zig
const rom = @import("rom.zig");
const mapper = @import("mapper.zig");

test {
    _ = rom;
    _ = mapper;
}
```

Run: `zig build test`
Expected: compile error — `Mapper` is not defined (the tests above reference it, but only `Nrom` exists so far).

- [ ] **Step 3: Implement the `Mapper` tagged union**

Append to `core/src/mapper.zig`, after the `Nrom` struct and before its tests:

```zig
/// Closed set of NES mappers (see the map's "Out of scope": coverage is
/// capped at NROM/MMC1/UxROM/CNROM/MMC3). A tagged union dispatched via
/// `switch (self.*) { inline else => |*m| ... }` rather than a vtable: the
/// switch operates on `self.*`, a place expression, and captures by pointer
/// (`|*m|`), so this does NOT copy the union's payload on every call — it
/// gets a pointer straight into the active variant. That matters once a
/// variant holds real state (MMC1/MMC3 bank-switch registers) and matters a
/// lot in a cycle-accurate core dispatching this millions of times/sec.
pub const Mapper = union(enum) {
    nrom: Nrom,

    pub fn prgRead(self: *const Mapper, addr: u16) u8 {
        switch (self.*) {
            inline else => |*m| return m.prgRead(addr),
        }
    }

    pub fn prgWrite(self: *Mapper, addr: u16, value: u8) void {
        switch (self.*) {
            inline else => |*m| m.prgWrite(addr, value),
        }
    }

    pub fn chrRead(self: *const Mapper, addr: u16) u8 {
        switch (self.*) {
            inline else => |*m| return m.chrRead(addr),
        }
    }

    pub fn chrWrite(self: *Mapper, addr: u16, value: u8) void {
        switch (self.*) {
            inline else => |*m| m.chrWrite(addr, value),
        }
    }

    pub fn irqPending(self: *const Mapper) bool {
        switch (self.*) {
            inline else => |*m| return m.irqPending(),
        }
    }

    pub fn irqAcknowledge(self: *Mapper) void {
        switch (self.*) {
            inline else => |*m| m.irqAcknowledge(),
        }
    }
};
```

- [ ] **Step 4: Run tests, confirm all pass**

Run: `zig build test --summary all`
Expected: `12/12 tests passed` (7 from Task 2 + 5 new).

- [ ] **Step 5: Commit**

```bash
git add core/src/mapper.zig core/src/root.zig
git commit -m "feat(core): add the Mapper interface and an NROM implementation"
```

---

### Task 4: `Rom.load` + `createMapper` — the end-to-end path

**Files:**
- Modify: `core/src/rom.zig`

**Interfaces:**
- Consumes: `mapper.Mapper`, `mapper.Nrom` from Task 3.
- Produces: `pub const Rom = struct { header: Header, prg_rom: []const u8, chr_rom: []const u8, pub const LoadError = ParseError || error{Truncated}; pub fn load(data: []const u8) LoadError!Rom }`, `pub const MapperError = error{UnsupportedMapper}; pub fn createMapper(rom: Rom) MapperError!Mapper`. This is the pair of functions M0's exit criteria ("NROM ROM addressable through the interface") is checked against, and what M1's CPU memory bus will call.

- [ ] **Step 1: Write the failing tests**

Add to the bottom of `core/src/rom.zig` (the `buildMinimalNrom` helper already there is reused):

```zig
test "Rom.load slices PRG/CHR out of the file, after the header" {
    const buf = buildMinimalNrom(2, 1); // 32KB PRG, 8KB CHR
    const rom = try Rom.load(&buf);
    try testing.expectEqual(@as(u8, 0), rom.header.mapper);
    try testing.expectEqual(@as(usize, 32768), rom.prg_rom.len);
    try testing.expectEqual(@as(usize, 8192), rom.chr_rom.len);
}

test "Rom.load skips a 512-byte trainer when present" {
    var buf = buildMinimalNrom(2, 1);
    buf[6] |= 0b0000_0100; // trainer flag
    // buildMinimalNrom didn't reserve trainer space, so grow the buffer by
    // hand: allocate a fresh array with 512 extra bytes and shift PRG/CHR.
    var full: [16 + 512 + 32768 + 8192]u8 = [_]u8{0} ** (16 + 512 + 32768 + 8192);
    @memcpy(full[0..16], buf[0..16]);
    full[16 + 512] = 0xAB; // first PRG byte, after the trainer
    const rom = try Rom.load(&full);
    try testing.expectEqual(@as(u8, 0xAB), rom.prg_rom[0]);
}

test "Rom.load reports Truncated when the file is shorter than the header promises" {
    const buf = buildMinimalNrom(2, 1);
    try testing.expectError(Rom.LoadError.Truncated, Rom.load(buf[0 .. buf.len - 1]));
}

test "createMapper returns UnsupportedMapper for anything but mapper 0" {
    var buf = buildMinimalNrom(2, 1);
    buf[6] = 0x10; // mapper number 1 (MMC1) — not implemented until M7
    const rom = try Rom.load(&buf);
    try testing.expectError(MapperError.UnsupportedMapper, createMapper(rom));
}

test "createMapper wires an NROM ROM's bytes through to the Mapper interface" {
    var buf = buildMinimalNrom(2, 1);
    buf[16] = 0x11; // first PRG byte
    buf[16 + 32768] = 0x22; // first CHR byte
    const rom = try Rom.load(&buf);
    var m = try createMapper(rom);
    try testing.expectEqual(@as(u8, 0x11), m.prgRead(0x8000));
    try testing.expectEqual(@as(u8, 0x22), m.chrRead(0));
}
```

- [ ] **Step 2: Confirm it fails to compile**

Run: `zig build test`
Expected: compile error — `Rom`, `createMapper` are not defined, and `mapper_mod` is not imported yet.

- [ ] **Step 3: Implement `Rom.load` and `createMapper`**

Add near the top of `core/src/rom.zig`, after the existing `const std = @import("std");` / `const testing = std.testing;` lines:

```zig
const mapper_mod = @import("mapper.zig");
const Mapper = mapper_mod.Mapper;
const Nrom = mapper_mod.Nrom;
```

Then append, after `parseHeader` and before the test block:

```zig
pub const Rom = struct {
    header: Header,
    prg_rom: []const u8,
    chr_rom: []const u8,

    pub const LoadError = ParseError || error{Truncated};

    pub fn load(data: []const u8) LoadError!Rom {
        const header = try parseHeader(data);
        var offset: usize = 16;
        if (header.has_trainer) offset += 512;

        const prg_end = offset + header.prg_rom_size;
        if (data.len < prg_end) return LoadError.Truncated;
        const prg_rom = data[offset..prg_end];

        const chr_end = prg_end + header.chr_rom_size;
        if (data.len < chr_end) return LoadError.Truncated;
        const chr_rom = data[prg_end..chr_end];

        return Rom{ .header = header, .prg_rom = prg_rom, .chr_rom = chr_rom };
    }
};

pub const MapperError = error{UnsupportedMapper};

pub fn createMapper(rom: Rom) MapperError!Mapper {
    return switch (rom.header.mapper) {
        0 => Mapper{ .nrom = Nrom.init(rom.prg_rom, rom.chr_rom) },
        else => MapperError.UnsupportedMapper,
    };
}
```

- [ ] **Step 4: Run tests, confirm all pass**

Run: `zig build test --summary all`
Expected: `17/17 tests passed` (12 from Task 3 + 5 new).

Run: `zig build wasm`
Expected: exits 0 — confirms the added `rom.zig`/`mapper.zig` code still compiles for wasm32-freestanding (no accidental use of anything OS-gated).

- [ ] **Step 5: Commit**

```bash
git add core/src/rom.zig
git commit -m "feat(core): load ROMs end-to-end into the Mapper interface"
```

This closes M0's exit criteria: `zig build test` runs (17 tests, all passing), and an NROM ROM is addressable through the interface (the last test in this task is exactly that, byte-for-byte).

---

### Task 5: CI — GitHub Actions running the native test suite

**Files:**
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `core/build.zig`'s `test` and `wasm` steps (Task 1).
- Produces: nothing later tasks import — this is the "CI wired in here" fog item from the milestone roadmap, resolved.

- [ ] **Step 1: Create the workflow**

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  core:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: mlugg/setup-zig@v2.2.1
        with:
          version: 0.16.0
      - name: zig build test (native — this is where correctness is checked)
        working-directory: core
        run: zig build test --summary all
      - name: zig build wasm (delivery target — compiles only, no test)
        working-directory: core
        run: zig build wasm
```

`mlugg/setup-zig` is the community-standard action for pinning a specific Zig version in CI (no official `actions/setup-zig` exists); pinning `0.16.0` matches `core/build.zig.zon`'s `minimum_zig_version` and the locally installed toolchain. Pin the exact tag `v2.2.1`, not `@v1` — `v1`'s official-fallback path (`https://ziglang.org/builds`) is dev-build-only and 404s for stable releases like 0.16.0; this was fixed in v2 (confirmed by reading both versions' source), which correctly splits `/builds` (dev) from `/download/<version>` (stable).

- [ ] **Step 2: Validate the YAML locally**

Run: `python -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml'))" 2>&1 || cat .github/workflows/ci.yml`

(If `python`/`pyyaml` isn't available, visually re-check the indentation instead — GitHub will reject genuinely malformed YAML when the workflow file is pushed, which Step 4 below will surface.)

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: run zig build test + zig build wasm on push/PR to main"
```

- [ ] **Step 4: Defer full verification to the PR**

This workflow can only be fully verified once pushed (Task 7 opens the PR) — note this explicitly rather than claiming CI is "verified" before that happens.

---

### Task 6: `web/` scaffold

**Files:**
- Create: `web/` (entire directory tree, via the Vite scaffolding tool — not hand-written)

**Interfaces:**
- Produces: a buildable Vite + React + TypeScript app at `web/`, with no emulator-specific code yet. M4 is the first milestone that touches this directory again (adding the `?init` wasm import and the `<canvas>` host).

- [ ] **Step 1: Scaffold with Vite's React-TS template**

Run (from the repo root):

```bash
npm create vite@latest web -- --template react-ts
```

Expected: creates `web/` with `package.json`, `src/`, `index.html`, `vite.config.ts`, `tsconfig*.json`, and its own `.gitignore` (which the root `.gitignore` from Task 1 already covers, so it's fine if it's redundant).

- [ ] **Step 2: Install and verify it builds**

```bash
cd web
npm install
npm run build
```

Expected: `npm run build` exits 0 and produces `web/dist/`.

- [ ] **Step 3: Commit**

```bash
cd ..
git add web
git commit -m "chore(web): scaffold Vite + React + TypeScript app"
```

---

### Task 7: Docs, PR, and the M0 exit-criteria checklist

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: nothing new — this is a documentation-and-handoff task.

- [ ] **Step 1: Update `CLAUDE.md`'s "Planning status" section**

The current text says "This project is in the wayfinder planning phase — no emulator code yet." That's now false. Replace the `## Planning status` section:

```markdown
## Planning status

Planning is complete — see [NES Emulator — Implementation-Ready Spec](https://linear.app/okirpan/issue/ENG-54/nes-emulator-implementation-ready-spec) (ENG-54) on Linear for the full decision record. Execution is underway per the milestone roadmap in [Milestone roadmap & build sequencing](https://linear.app/okirpan/issue/ENG-63/milestone-roadmap-and-build-sequencing) (ENG-63): `core/` (Zig) and `web/` (React+TS+Vite) exist; M0 (repo scaffolding & mapper interface) is done.
```

- [ ] **Step 2: Update `README.md`**

Replace the second paragraph (currently: "Planning for this project is tracked as a wayfinder map on Linear ... No implementation yet; the map is where remaining decisions live.") with:

```markdown
Planning is tracked as a wayfinder map on Linear (workspace: OmkarKirpan, team: Engineering) — see `docs/agents/issue-tracker.md`. The map is complete; implementation follows the milestone roadmap it produced, starting from `core/` (Zig, native + wasm32) and `web/` (React+TS+Vite).
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "docs: mark planning phase complete, point at the milestone roadmap"
```

- [ ] **Step 4: Push and open the PR**

```bash
git push -u origin m0-repo-scaffolding
gh pr create --title "M0: repo scaffolding & mapper interface" --body "Implements M0 per the milestone roadmap (ENG-63): core/ Zig package (native + wasm32 build targets), iNES header parsing, the Mapper interface + NROM, CI running the native test suite, and a bare web/ Vite scaffold.

Exit criteria (per ENG-63):
- [x] \`zig build test\` runs (17 tests, all passing)
- [x] An NROM ROM is addressable through the Mapper interface (see the last test in rom.zig)"
```

- [ ] **Step 5: Confirm CI is green on the PR**

Run: `gh pr checks --watch`
Expected: the `core` job passes. If it fails, fix the underlying issue (do not disable the check) and push a follow-up commit.

- [ ] **Step 6: Final M0 exit-criteria checklist**

- [ ] `core/` exists (Zig, native + wasm32 build targets defined in `build.zig`)
- [ ] `web/` exists (Vite + React + TS, builds via `npm run build`)
- [ ] Zig pinned to 0.16.0 (`build.zig.zon` `minimum_zig_version`, matches installed toolchain)
- [ ] iNES header parsing implemented and tested (`rom.zig`)
- [ ] Mapper interface defined (`prgRead`/`prgWrite`/`chrRead`/`chrWrite`/`irqPending`/`irqAcknowledge`) with NROM as its only implementation
- [ ] `zig build test` runs and passes (17/17)
- [ ] An NROM ROM is addressable through the interface end-to-end (parsed header → sliced PRG/CHR → `Mapper.prgRead`/`chrRead`)
- [ ] CI (`.github/workflows/ci.yml`) runs `zig build test` + `zig build wasm` on push/PR to `main`
- [ ] PR opened, CI green

M0 is done when every box above is checked. M1 (CPU core, native, targeting `nestest`) starts from this branch's merge into `main`.
