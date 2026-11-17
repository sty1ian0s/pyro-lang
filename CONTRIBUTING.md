# Contributing

Work is planned in [tasks.md](tasks.md). Read "Using this with ultracode" there first.

## Toolchain

- Zig 0.17.1 exactly (pinned in `build.zig.zon` as `minimum_zig_version`).
- LLVM is optional. Only `-Dllvm=true` links it (through `llvm-config` on `PATH`).
  The front end, `zig build test` and CI never need LLVM.

## Build steps

| Command | What it does |
|---|---|
| `zig build` | builds `zig-out/bin/pyro` (entry: `stage0/src/main.zig`) |
| `zig build run -- <args>` | builds and runs `pyro` |
| `zig build test` | runs every unit test in `stage0/src/`, `runtime/` and `tools/` |
| `zig build conformance` | runs `tools/conformance/main.zig <pyro> <conformance-dir> [args...]`; prints a note and succeeds until that file exists |
| `zig build -Dllvm=true` | also links LLVM; code can test `@import("build_options").llvm` |

## Adding tests: no build.zig edit needed

`zig build test` discovers tests itself:

1. Each test tree (`stage0/src`, `runtime`, `tools`) is walked when the build is
   configured. Every `.zig` file in it is collected, except files under a directory
   named `testdata`.
2. The tree is copied into the build cache next to a generated `pyro_test_root.zig`,
   which `@import`s every collected file inside one `comptime {}` block (so the root
   adds no test of its own and the summary counts only real tests). The whole tree is
   one module rooted at the tree, so any file can import any other file of the same
   tree by relative path (`@import("../diag/Diagnostic.zig")`).
3. One test binary is built and run per tree (`test-stage0-src`, `test-runtime`,
   `test-tools`). A tree with no `.zig` files is skipped.

So to add tests, add a `.zig` file with `test` blocks anywhere in a tree. Adding,
removing or renaming a file re-runs discovery automatically.

Consequences:

- Every `.zig` file in a tree must compile in test mode. Put non-compiling fixtures
  under a `testdata/` directory.
- One file that fails to compile fails its whole tree's test binary.
- Error locations point at the cached copy, for example
  `.zig-cache/o/<hash>/lex/token.zig:10:5`. The part after `<hash>/` is the path
  inside the tree (`stage0/src/lex/token.zig`).
- Files cannot import across trees (for example `stage0/src` cannot import
  `runtime/`). Ask the owner of `build.zig` for a named module if you need that.

## Directory ownership

Rules from tasks.md ("Using this with ultracode" and each task's Conflicts line):

- One task = one agent; a task owns only the files named in its Deliverable; commit
  directly to `main` (single contributor, no branches).
- Shared files listed under a task's Conflicts are append-only for other tasks, or
  their edits go through the owning task.
- GATE tasks freeze an interface when they merge. Later changes go through the
  owning file only:
  - `stage0/src/lex/token.zig` (TokenKind): T005.
  - `stage0/src/diag/` core files and the generated `DiagCode` enum: T003. T017
    (renderers) and T027 (levels) add their own files and never edit core files.
  - `stage0/src/pir/` opcode enum: T006.
  - AST NodeKind, TIR opcodes, attribute and builtin tables, memo table: their GATE
    tasks (see tasks.md).
  - `tools/conformance/`: T004. Other tasks add one file and one mode switch.
  - `stage0/src/cli/` dispatch tables: T024. Each command owns its own
    `cli/cmd_*.zig`; others append one line to dispatch.
- Conformance cases (`conformance/NN-*/`): append-only, one file per case. Each
  error code gets one passing and one failing case (B.9).
- `build.zig` belongs to T001. Other tasks edit it only at these points, and must
  keep the front end LLVM-free:
  - `addCommonImports` (applied to the `pyro` executable and every test tree):
    T003 adds one `m.addImport("diag_codes", ...)` line that calls its generator in
    a T003-owned file under `stage0/build/`. `@embedFile` cannot reach
    `spec/A-diagnostics.md` from `stage0/src`, so the generator must run in the build.
  - `addTreeOptions` (per test tree): the `runtime` tree already links libc; T010
    adds its C harness wiring (C sources, helper executable) to the `runtime` branch.
  - The `zig build conformance` block: T004 may adjust the harness arguments.
  Only one task edits each point; tasks.md lists `build.zig` in their Conflicts.
- A task is done when its Acceptance tests pass in `zig build test` or
  `zig build conformance`. Merge each finished task of a wave into `main`, run CI,
  then start the next wave.

## Cross-cutting rules

- Output is deterministic: diagnostics sort by (file, offset); no layout or cache key
  depends on hash-map iteration order.
- No optimization may change trap behaviour.
- Use only Zig 0.17.1 APIs. Check `lib/std` of the installed toolchain before using
  one; many older names are gone (`std.Io`, Reader/Writer, build API).
