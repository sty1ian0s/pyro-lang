# Appendix C. Design Decisions and Their Sources (informative)

This specification was distilled from a long design conversation (133 exchanges). The
conversation revised itself many times and left many contradictions. This appendix
records, for each contested point, what was said and what this draft chose, so the
choices can be reviewed. "T*n*" is the turn number in the conversation, counted from 0.

Legend:
- **=** the user decided this explicitly in the conversation;
- **≈** proposed in the conversation and not objected to;
- **★** this draft deviates from or goes beyond the conversation. **Please review these
  rows.**

## C.1 Syntax and lexing

| ID | Topic | Conversation | Decision | |
|----|-------|--------------|----------|---|
| D-01 | Surface syntax | T2 floated assembly-like syntax; T4 onward used Rust/Zig-like code | Braces, `fn`, `let`, Rust/Zig-flavoured, rigid grammar | ≈ |
| D-02 | Block comments, multi-line strings | Nested `/* */` (T85, T87); chunked SIMD lexing had a word-split problem (T118) | **No block comments.** Multi-line strings use `\\` lines. Every token is on one line, so parallel lexing is trivially correct (§2.1.1, B.2) | ★ |
| D-03 | Semicolons | Examples were inconsistent | Required after statements; not after block-like statements | ★ |
| D-04 | Mutable locals | `var x` (T47–T59), `mut x = …` (T84, T93), `let mut` (T94, PIS v3) | `let` / `let mut` only. `var` is reserved | ★ |
| D-05 | In-place marker | `!` suffix (T33) → `@inplace` (T59) → inferred from `mut` parameters (T64) | A function mutates in place exactly when it has `mut` parameters | = |
| D-06 | `!` | Was the in-place suffix; T60 user: use it for boolean NOT | `!` is only logical/mask NOT. `not` dropped. No `name!` macros | = |
| D-07 | Call-site `mut` | v2.1 (T90) `foo(mut x)`; chaining without markers (T64) | `mut` required on arguments, receivers exempt | ≈ |
| D-08 | Chaining | T65 user: return the mutated reference | `-> mut Self` + `return self;` | = |
| D-09 | Attribute sigils | `#[soa]` vs `@gpu_kernel` (T120); T121 user prefers `@` | `@` for every attribute and builtin | = |
| D-10 | Paths | `.` and `::` both used | `.` only. `::` removed | ★ |
| D-11 | Precedence | PIS tables put bitwise *below* comparison (C footgun), assignment as an operator | Bitwise above comparison, comparisons non-associative, assignment is a statement (§3.9). Follows the user's "low footguns for every feature" (T89) | ★ |
| D-12 | Generic syntax | `Pool<T>` everywhere; T91 Zig-style comptime type functions; T94 `FieldId<T>` vs T96 `FieldId(T)` | `<…>` in types and declarations, defined as sugar for comptime type functions (§7.6.2). Expressions never contain `<…>` (no turbofish); use inferred members `.init()` | ★ |
| D-13 | Struct update `..default` | T47 proposal; follow-up: user wants ergonomics but worried about forgotten new fields | Rest marker `..` (no keyword). Without it every field must be listed, so new fields surface as errors; with it defaults fill in deliberately (§6.2.1) | = |
| D-14 | Walrus `:=` | T31, with an example inconsistent with its own syntax | Dropped. `if let` / `guard let` cover it | ★ |
| D-15 | Labels | not discussed | `name: for …`, `break :name` | ★ |
| D-16 | Generic application in expressions | not discussed | `Pool(T)` in expressions (≡ `Pool<T>` in types). Expression generic args in types use braces: `Channel<M, {N*2}>`. Avoids turbofish and backtracking | ★ |
| D-17 | Discard | `_ =` used in examples, never defined | `_ = e;` statement (§6.11.1) | ★ |

## C.2 Memory model

| ID | Topic | Conversation | Decision | |
|----|-------|--------------|----------|---|
| D-20 | Safety mechanism | "Arenas + generational handles, no borrow checker" (T3, T26, T68). Never explained how slices into an arena stay valid after `reset` | Four mechanisms: plain values, **resources** with checked consumption, **second-class views** with a local exclusivity rule, handles (chapter 5). No annotations, no cross-function inference. This is the minimum needed for the "memory-safe" requirement to actually hold | ★ |
| D-21 | Destructors | "No hidden destructors / RAII" (T16) | Resources are released explicitly (`defer x.deinit()`). The compiler checks every resource is consumed exactly once | ★ |
| D-22 | Moves | `move`/`isolate` named in v2.1 without semantics | Explicit `move` for resources. `isolate` dropped | ★ |
| D-23 | Arena vs containers | Thread-affine arenas everywhere (T28) | Arenas hand out only views (scratch memory). Owning containers use a per-thread general allocator. Thread affinity follows from exclusivity, not a separate rule | ★ |
| D-24 | Containers of resources | not discussed | Containers and fixed arrays hold plain data only; ownership graphs use handles. Enum payloads may be resources (`Result<File, E>`), consumed by `match move` | ★ |
| D-25 | Mutable globals | `modvar` (T19) | No mutable globals in safe code (§5.9) | ★ |
| D-26 | Pool | freelist (T14) vs swap-back (T15) | Slot map: dense storage with swap-back removal plus generational slot table; generations retire instead of wrapping (§14.4.2) | = (T15) |
| D-27 | Handle layout | 32-bit index + 32-bit generation (T76, T85); `Handle::NULL` (PIS v3) | Kept. No null handle: `Option<Handle<T>>` uses generation 0 as `.none` and has the same size as `Handle` | ★ |
| D-28 | Raw pointers | `*raw T`, `*mut T`, `*const T`, `*T` all appeared | `*T` and `*const T`. Dereferencing only in `unsafe` (new keyword) | ★ |
| D-28b | Atomics | `@atomic` field attribute (T62) and atomics in v2.1 | `Atomic<T>` type, a "shared cell" kind: non-copyable, no release needed, shareable read-only between tasks | ★ |
| D-29 | `uninit` | appeared in `--expand` output (T109) | Removed. Zero-initialization always; uninitialized memory only through `@unsafe` APIs | ★ |

## C.3 Types and data layout

| ID | Topic | Conversation | Decision | |
|----|-------|--------------|----------|---|
| D-30 | SoA opt-in | Automatic SoA (T3) → explicit `soa [N]T` (T14) → `#[soa]` struct attribute proposal (T120) | `soa [N]T`, `soa []T` and `@soa struct` (§4.11.5). No automatic AoS→SoA rewrite; warning W0401 instead (T120) | = (T69) |
| D-31 | Bit packing | User wants it (T6). Packing chosen by access patterns (T6) vs deterministic ABI (T18) | Deterministic algorithm (§4.11.2). Packing happens in structs only; SoA columns use whole bytes for SIMD | ★ |
| D-32 | `bool` vs `u1` | both used | `bool` exists. It occupies one bit inside packed structs | ★ |
| D-33 | Vector type | `vec2<T>`, `simd<T, N>`, `vec<N, T>` | `vec<N, T>` plus `vec2/3/4` aliases. `simd<T, N>` dropped | ★ |
| D-34 | Floats | Default allows FMA; `@strict_fp` opt-in (T28) | **Strict by default**, `@fast_math` opt-in. Reproducibility first, matching the low-footgun rule | ★ |
| D-35 | Distinct types | `Distinct<u32, "PlayerId">` (T91) | `type PlayerId = distinct u32;` | ★ |
| D-36 | Opaque/domain types | `opaque struct` (T19) | Field visibility `pub` (read) / `pub mut` (write) gives the same effect without a keyword (§7.3.3) | ★ |
| D-37 | Hot/cold splitting | Wanted (T10); no syntax given | `@cold` on fields, honoured by containers | ★ |

## C.4 Semantics

| ID | Topic | Conversation | Decision | |
|----|-------|--------------|----------|---|
| D-40 | Error handling | `Result` + `?` (T5, T8); v2.1 also mentioned `try` | `?` only. `try` reserved | ≈ |
| D-41 | `@todo_err` | T5 user: warning while present, error in release | W0601. Error E0604 in environments with `allow_todo_err = false` (default in `prod`) | = |
| D-42 | Overflow | wrap in release, panic in debug (T28) | Same, keyed to `debug_assertions`, plus explicit wrapping/saturating/checked builtins | ≈ |
| D-43 | Bounds checks | Active "at O0" (T115); follow-up: user doubts an opt-out is safe enough | Always on in every build. Removed only when proven redundant. Per-site opt-out only via `unsafe` accessors (§12.3). No global switch | = |
| D-44 | Contracts | `comptime requires` (T48); `@requires/@ensures/@invariant` (T132) | Attributes. Statically refuted at compile time when possible; runtime checks controlled per environment | = (T129) |
| D-45 | Laws (Bend-inspired) | T131: laws also feed the optimizer | Laws are verified by `pyro test` (exhaustive for small domains, otherwise property-based) and are **never** optimizer assumptions: a wrong law would silently miscompile | ★ |
| D-46 | Closures | Discarded (T31); `\|m\| m.threat_level` used later (T95–T102); "monomorphized only" (T113) | Capturing lambdas only as arguments to `comptime` function parameters (inlined). Non-capturing lambdas convert to function pointers | ≈ |
| D-47 | Comprehensions | Discarded (T31), revived with a preallocated destination (T46) | Only into `[N]T` or `Bounded<T, N>` (§6.2.5) | = (T46) |
| D-48 | Main loop idiom | T100–T101 user: `for p in particles { p.x += … }` front and centre | Primary SoA idiom. The loop variable's mutability comes from the iterable | = |
| D-49 | Tail calls | `return tail f()` (T48) | Kept, with a compile error if the frame cannot be reused | ≈ |
| D-50 | Memoization `@cached(arena)` | T48 | Dropped: semantics (key space, eviction) undefined. Write it as library code | ★ |

## C.5 Items, modules, metaprogramming

| ID | Topic | Conversation | Decision | |
|----|-------|--------------|----------|---|
| D-55 | Protocols | T66 user asked for traits. `impl P for T` (T66) vs `struct S impl P` (T84) vs implicit structural conformance (T85) | Explicit `impl P for T` only, static dispatch only. Inherent methods live inside the struct body | ★ |
| D-56 | Imports | `use a.b.{X}` (T19) vs `import "path"` (PIS v3) | `use` with dotted paths | ≈ |
| D-57 | Import cycles | Allowed via two-pass (T19); forbidden, DAG (T114, PIS v3) | Forbidden (E0902), latest position | ≈ |
| D-58 | Macros | No token macros (T91); `table!` macro capturing token blocks (T106) | No macros. Beginner sugar is comptime functions and types (`Table(T, .{ sorted_by: .f, .. })`) plus `for … where`. Satisfies T109: "no hidden control flow, but looks hidden" | ★ |
| D-59 | Comptime I/O | Pure tier + `comptime io` tier (T49) | Comptime is pure except `@embed_file`, `@env`, `@target`. Arbitrary I/O only in `build.pr` | ★ |
| D-60 | Runtime sort keys | Comptime field (T94) → runtime key (T98) → multi-view (T96); T97: structure is independent of the key | `Table` keeps one comptime-chosen order incrementally; `sort_view` builds additional orders at runtime | ≈ |
| D-61 | Modding | `@overridable` jump slots, `modvar` (T19) | Dropped from the core language. Use structs of function pointers and `SparseMap<Entity, ModData>` | ★ |
| D-62 | First-class ECS | T50 user requested `ecs archetype` / `ecs system` keywords; follow-up: library acceptable | Fully specified `std.ecs` (§14.15): archetypes, generational entities, tuple-destructuring queries, command buffers, normative complexity. Built with comptime, so it is as ergonomic as keywords, with no grammar growth | = |
| D-63 | Actors | User likes data-oriented actors (T13); no syntax ever given | Library type `std.actors.Actors(S, M)` with batched mailboxes | ★ |

## C.6 Concurrency, SIMD, GPU

| ID | Topic | Conversation | Decision | |
|----|-------|--------------|----------|---|
| D-70 | async/await | Rejected (T30) | Not in the language. `async`/`await` reserved | = |
| D-71 | Structured concurrency | `nursery`/`task_group` (v2.1) | `nursery { spawn …; }` | ★ (name) |
| D-72 | Deadlock freedom | "deadlocks impossible" (T30, T89) | No locks; fork-join cannot deadlock; `Sender` endpoints are resources, so a channel always closes; W0501 warns on cyclic channel graphs (acyclic implies no deadlock); runtime detection traps in all builds (§10.4.1) | ★ |
| D-73 | Dynamic ("Jai-like") SIMD | T89 user | `@vector_width(T)` with width-generic code, plus `@simd` loops that must vectorize | ★ |
| D-74 | GPU code | `gpu {}` blocks / `compute fn` / `render fn` (T38) → `@gpu_kernel` + `launch gpu` (T114–T121) | `@gpu_kernel` + `launch gpu` / `launch cpu`. Synchronous launch with explicit resident buffers, so every transfer is visible | ≈ |
| D-75 | "Zero-copy" GPU | claimed for discrete GPUs (T119) | Not physically possible over PCIe. Exact only on unified memory; otherwise staging copies at `launch`, or explicit `gpu.Buffer` | ★ |
| D-76 | Render pipelines, SDF UI | T8, T38, T18; follow-up: user wants all stages with a zero-cost layer and an optimizer | Vertex, fragment, compute, task/mesh and ray-tracing stages as attributed functions. Pipelines are comptime types, optimized across stages (§11.6). Stages are referenced as `FnRef` values in typed descriptors. Geometry and tessellation omitted (absent in Metal and WebGPU, superseded by mesh shaders). `std.gfx` builds the high-level layer | = |
| D-78 | Traps in GPU code | not discussed | Device-side trap record, re-raised as a process trap at the next host synchronization point (§11.7). Keeps "bounds checks everywhere" true on the GPU | ★ |
| D-79 | Mesh and ray tracing detail | follow-up: user asked for full specification | Execution model, exact signatures, portable limits, automatic SBT from comptime pipelines, ray queries, acceleration-structure lifetime safety, Vulkan and Metal lowering, zombie-invocation trap semantics, uniform-control-flow rule, per-stage race rules (§11.1, §11.4–11.5, §11.7) | = |
| D-77 | GPU backend dependence | T41 user: third-party APIs first, own drivers maybe later | Vulkan, Metal and WebGPU through the runtime. Shaders generated by Pyro's own compiler | = |

## C.7 Toolchain

| ID | Topic | Conversation | Decision | |
|----|-------|--------------|----------|---|
| D-80 | Backend | T71 user: ditch LLVM; T73 user: LLVM first as a bootstrap, then native, LLVM optional | Exactly that (B.6.1) | = |
| D-81 | Build configuration | `build.pr`, no manifest (T50–T51) → `pyro.toml` with environments (T115) | Both: `pyro.toml` for declarative data, optional `build.pr` for logic | = |
| D-82 | Package manager | `ppm` (T51) | Part of the single `pyro` binary | ★ |
| D-83 | Environments | T115 user: dev/test/prod at compile time, debug only in dev/test | `[env.*]` with reserved keys (§13.3) | = |
| D-84 | `--expand` | T110–T111 user: never edit the source, print to stdout | As specified (§13.7), plus a round-trip requirement | = |
| D-85 | JIT / lenient mode | T104 proposal, replaced by the comptime-sugar approach (T105) | AOT only | = |
| D-86 | Time-travel debugger `pyro trace` | T71 | Dropped (not specifiable now). Standard DWARF/PDB debug information | ★ |
| D-87 | Inline assembly | not discussed | Not in this edition. Use `.S` files via `build.pr` | ★ |
| D-88 | Lexer chunk boundaries | T118 user | Solved by line locality (D-02) | ★ |

## C.8 Questions resolved after the first draft

| Question | Resolution |
|----------|-----------|
| ECS keywords | Library `std.ecs` (§14.15). See D-62 |
| Graphics pipelines | All modern stages with a cross-stage optimizer (§11.6). See D-76 |
| Optional bounds-check removal | No global switch. See D-43 |
| `..default` | Rest marker `..`, explicit per construction site. See D-13 |
| Channel deadlocks | Sender endpoints, static cycle warning, runtime detection. See D-72 |
| Embedded script interpreter | Left out of the language. Mods are compiled Pyro (dynamic libraries or WebAssembly). A sandboxed WebAssembly host may come as a library later; a second execution model in the core would break principle 2 |
