# 13. Packages, Build Configuration and Tooling

All tools ship as one executable, `pyro`. It contains the compiler, linker, package
manager, test runner, formatter, documentation generator, language server and
profiler.

## 13.1 Packages

A **package** is a directory containing `pyro.toml`:

```
my_game/
├── pyro.toml          # manifest (§13.2)
├── pyro.lock          # exact dependency versions and hashes (§13.4), generated
├── build.pr           # optional build script (§13.5)
├── src/
│   ├── main.pr        # executable root module   (or lib.pr for a library)
│   └── physics/
│       └── rigid_body.pr   # module physics.rigid_body
├── tests/             # integration tests: each file is a module that sees only pub API
└── assets/            # free-form; reachable by @embed_file
```

A package is an executable if `src/main.pr` exists, a library if `src/lib.pr` exists.
Having both or neither is an error (**E0908**). A **workspace** is a directory whose
`pyro.toml` has a `[workspace]` table listing member package directories. Members share
one `pyro.lock` and one build cache.

## 13.2 `pyro.toml`

TOML v1.0. Unknown top-level tables or keys are errors (**E0909**), except inside
`[env.*]` (user keys) and `[metadata]` (free-form).

```toml
[package]
name = "engine_core"          # required; [a-z][a-z0-9_]*, ≤ 64 chars
version = "0.4.2"             # required; Semantic Versioning 2.0
edition = "2026"              # required
description = "..."           # optional
license = "MIT OR Apache-2.0" # optional, SPDX expression
no_std = false                # optional; true = core prelude only (§14.1.1)

[dependencies]
math = "1.2"                                   # registry, caret requirement ^1.2
net = { version = "0.9", registry = "internal" }
gfx = { git = "https://example.com/gfx.git", tag = "v2.0.1" }
local_util = { path = "../util" }

[dev-dependencies]                             # only for tests, laws, benches
proptest_extras = "0.3"

[build]
targets = ["x86_64-linux-gnu", "aarch64-macos"]   # default: host
backend = "llvm"                                  # "llvm" | "native" (appendix B.6)
trusted_build_scripts = ["gfx"]                   # dependencies whose build.pr may run

[gpu]
backends = ["vulkan", "metal", "webgpu"]          # which shader forms to embed
fallback = true                                   # CPU fallback when no device (§11.2.3)

[link]
mode = "static"                                   # "static" | "dynamic"

[env.dev]
db_url = "sqlite://dev.db"                        # user key
log_level = "trace"

[env.prod]
opt_level = "O3"
db_url = "postgres://db.internal:5432/core"
log_level = "error"
```

### 13.2.1 Target triples

Format: `arch-os[-abi]`. Each implementation documents the triples it supports. The
reference implementation supports at least:

| Arch | OS / ABI |
|------|----------|
| `x86_64` | `linux-gnu`, `linux-musl`, `windows-msvc`, `macos`, `freestanding` |
| `aarch64` | `linux-gnu`, `linux-musl`, `windows-msvc`, `macos`, `ios`, `android`, `freestanding` |
| `riscv64` | `linux-gnu`, `freestanding` |
| `wasm32` | `wasi`, `freestanding` (browser) |

With `backend = "llvm"`, every target that LLVM supports may be offered.

## 13.3 Build environments

An **environment** is a named set of compile-time settings. Three always exist (`dev`,
`test`, `prod`), and users may add more (`[env.staging]`). `pyro build`/`run` use `dev`.
`pyro test`/`bench` use `test`. `--env <name>` overrides, and `--release` means
`--env prod`.

Reserved keys and their defaults:

| Key | Type | `dev` | `test` | `prod` | Meaning |
|-----|------|-------|--------|--------|---------|
| `opt_level` | `"O0"`…`"O3"`, `"Oz"` | `"O0"` | `"O1"` | `"O3"` | optimization (§13.9) |
| `debug_assertions` | bool | true | true | false | checked build: overflow and shift traps (§6.4) |
| `contracts` | bool | true | true | false | runtime contract checks (§9.5) |
| `allow_todo_err` | bool | true | true | false | `@todo_err` allowed (§9.2) |
| `debug_info` | `"full"`, `"lines"`, `"none"` | `"full"` | `"full"` | `"lines"` | debug information |
| `sanitize` | bool | false | false | false | instrument unsafe code (§12.8) |
| `lto` | bool | false | false | true | cross-module optimization |
| `hash_names` | bool | true | true | false | keep the `@hash` name table (§8.6.1) |

Any other key is a **user key**. It must be a TOML string, boolean, integer or float,
and is read with `@env("key")` (§8.6). Values are merged in this order: built-in
defaults, then `[env.<name>]`, then `--set key=value` command-line overrides. The
environment's full contents are part of the build cache key.

Code selects behaviour per environment with `comptime if`:

```pyro
const DB_URL: str = @env_or("db_url", "sqlite://:memory:");
fn log(comptime level: Level, msg: str) {
    comptime if level as u8 >= level_from_str(@env_or("log_level", "warn")) as u8 {
        eprint("{}\n", msg);
    }
}
```

Reserved keys are readable the same way (`@env("debug_assertions")`) and always
exist, because they have defaults.

## 13.4 Dependencies and `pyro.lock`

- **Sources.** A registry (versioned archives), git (`tag`, `rev` or `branch`), or a
  local `path`.
- **Requirements.** `"1.2"` and `"^1.2"` mean ≥1.2.0 and <2.0.0. `"~1.2.3"`, `"=1.2.3"`,
  `">=1.2, <1.5"` follow Cargo semantics.
- **Resolution.** For each package name, the resolver picks one version per
  semver-compatible line (a major version, or a minor version for `0.x`): the highest
  version satisfying every requirement on that line. Two incompatible lines of the same
  package may coexist. Their types are distinct, and code that mixes them gets ordinary
  type errors that name both versions. Unsatisfiable requirements fail with a report
  showing the conflicting requirement chains (**E0910**).
- **Package graph.** Dependency cycles between packages are an error (**E0906**).
  Diamonds are shared: each resolved package version is compiled once per environment
  and target.
- **`pyro.lock`** (TOML, generated, committed to version control) records, per package,
  name, version, source and the SHA-256 of the source archive or git tree. Builds
  verify every hash (**E0911** on mismatch). `pyro update` re-resolves. `--locked`
  fails if the lock file would change. `--offline` uses only the local cache.
- Fetched sources live in a global content-addressed cache and are never modified.

## 13.5 Build scripts (`build.pr`)

`build.pr` is an optional Pyro module. Before compiling the package, the toolchain
compiles it for the host and runs its `build` function:

```pyro
use std.build.{Builder};

const VERSION_MODULE: str = "pub const VERSION: str = \"0.4.2\";";

pub fn build(mut b: Builder) -> Result<void, std.build.Error> {
    b.generate_module("version", VERSION_MODULE)?;      // becomes module gen.version
    b.add_c_source("vendor/miniz.c", flags: ["-O2"])?;
    b.add_asm_source("src/boot.S")?;
    b.link_system_library("pthread");
    return .ok();
}
```

- Build scripts have full access to `std` including file I/O and processes. This is the
  one place where the build may depend on the outside world. Every file a script reads
  through `b.read_file` is recorded as a build dependency.
- The `Builder` API (§14.12) can generate Pyro modules (under the module prefix `gen.`),
  compile C and assembly sources with the bundled C toolchain or a configured one, add
  link libraries and flags, and add extra executables.
- A dependency's `build.pr` runs only if the dependency is listed in
  `[build] trusted_build_scripts`, or the command line has `--trust-build-scripts`.
  Otherwise the build fails (**E0907**) with a message showing the script path.
- `build.pr` is never part of the compiled package itself.

`pyro.toml` holds declarative data (identity, dependencies, environments, targets).
`build.pr` holds build *logic*. Most packages need no `build.pr`.

## 13.6 Tests and benchmarks

```pyro
@test
fn ring_wraps() {
    let mut r: Ring<u8, 4> = .init();
    for i in 0..6 { r.push(i as u8); }
    assert(r.len() == 4, "ring keeps capacity");
}

@test(traps: .bounds)
fn index_past_end_traps() { let xs = [1, 2, 3]; let i: usize = 3; _ = xs[i]; }

@test @no_alloc
fn hot_path_does_not_allocate() { ... }
```

- A test is a function marked `@test` with no parameters, returning `void` or
  `Result<void, E>` (an `.err` fails the test). `@test(traps: kind)` passes only if the
  body traps with that kind. Such tests run in a child process.
- Tests and laws are compiled only by `pyro test`, in the `test` environment. Unit
  tests may live in any module and see its private items. Files in `tests/` see only
  `pub` API.
- `pyro test [pattern]` runs every test and law whose path (`module.fn`) contains
  `pattern`, in parallel. Output: one line per failure with location and message,
  followed by a summary. The exit status is non-zero if anything failed.
- `@bench fn name(mut b: std.testing.Bench)` defines a benchmark run by `pyro bench`.
  The runner measures wall time, instructions and cache misses where the OS exposes
  hardware counters.

## 13.7 `--expand`

`pyro build --expand [module.path]` performs name resolution, comptime evaluation,
generic instantiation and the desugarings of §6.12 for the given module (default: the
root module). It then prints the result to **standard output** as Pyro source and exits
without generating code. Source files are never modified. Redirect the output to save
it: `pyro build --expand > expanded.pr`.

Requirements on the output:

1. It is valid Pyro and contains no construct marked as sugar in §6.12: no `?`, no
   `if let`/`guard let`/`while let`, no `for` (only `while`), no `where`, no
   comprehensions, no default or named arguments.
2. Generic instantiations and type-function results appear as explicit top-level
   declarations named per §8.3.2. Comptime constants appear as literals.
3. `defer`/`errdefer` are kept by default. `--expand=full` additionally inlines them at
   every scope exit.
4. Compiling the expanded output gives a program with the same observable behaviour.

`--expand` is how "no hidden control flow" is checked: everything convenient in the
source is visibly plain in the expansion.

## 13.8 Command-line interface

| Command | Purpose |
|---------|---------|
| `pyro new <name> [--lib]` / `pyro init` | create a package |
| `pyro build` | compile (default env `dev`) |
| `pyro run [-- args]` | build and run the executable |
| `pyro check` | parse, resolve and type-check only; no code generation |
| `pyro test [pattern] [--seed n]` | run tests and laws (env `test`) |
| `pyro bench [pattern]` | run benchmarks (env `test`, `opt_level` from `[env.test]`) |
| `pyro fmt [--check]` | format in the single canonical style; not configurable |
| `pyro doc [--open]` | generate HTML docs from `///` comments |
| `pyro lsp` | language server over stdio (§13.10) |
| `pyro profile [-- args]` | run with the sampling profiler and write a flame graph (§13.11) |
| `pyro add <dep> [--dev]`, `pyro remove <dep>` | edit `[dependencies]` |
| `pyro update [dep]`, `pyro fetch` | re-resolve, or download into the cache |
| `pyro publish` | upload to a registry |
| `pyro clean` | delete build outputs |

Common flags: `--env <name>`, `--release` (= `--env prod`), `--target <triple>`,
`--backend llvm|native`, `--set key=value`, `--jobs n`, `--offline`, `--locked`,
`--expand[=full]`, `--trust-build-scripts`, `--color auto|always|never`,
`--message-format human|json`.

Exit status: 0 success, 1 compile errors or test failures, 2 invalid usage, 3 internal
compiler error.

## 13.9 Optimization levels (informative, apart from the guarantees)

| Level | Intent |
|-------|--------|
| `O0` | no optimization, fastest compile, best debugging |
| `O1` | local optimizations: constant folding, dead-code elimination, register allocation, simple inlining |
| `O2` | full SSA optimizations, loop-invariant code motion, auto-vectorization, bounds-check elimination |
| `O3` | `O2` plus aggressive inlining and unrolling, and cross-module optimization with `lto` |
| `Oz` | minimize size: no unrolling, cold-path outlining |

No optimization level changes observable behaviour. Traps, bounds checks and handle
checks are removed only when proven redundant. The settings that change semantics are
the environment keys in §13.3, never `opt_level`.

## 13.10 Language server

`pyro lsp` implements the Language Server Protocol 3.17 over stdio. It must support:
diagnostics (the same codes and text as the compiler), go-to-definition,
find-references, rename (workspace-wide, including fields and SoA column uses), hover
with types and doc comments, completion after `.` (fields, methods, UFCS candidates),
signature help with parameter modes, formatting (`pyro fmt`), and an "expand" code
action showing the §13.7 expansion of the selected function. It reuses the compiler's
front end and caches.

## 13.11 Profiling and debugging

- Debug information is DWARF 5 on ELF and Mach-O, and CodeView/PDB on Windows, with the
  level set by `debug_info`. Generated (`--expand`) types get debug names per §8.3.2.
  Handles display as `Handle<T>(slot, gen)` and SoA elements display as structs in
  conforming debugger extensions.
- `pyro profile` samples the call stack at 1 kHz by default (`--freq`). In checked
  builds it also records every allocation by call site. It writes a folded-stack text
  file and a self-contained SVG flame graph.
