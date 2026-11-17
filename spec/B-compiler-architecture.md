# Appendix B. Reference Compiler Architecture (informative)

This appendix describes how the reference implementation is built. It is not required
for conformance, but it records the design decisions from the language discussion (a
data-oriented compiler, parallel lexing, a custom IR, LLVM first and a native backend
later) at a level a team can implement directly.

## B.1 Pipeline

| Stage | Input → Output | Parallel over |
|-------|----------------|---------------|
| 1. Load & lex | files → `TokenBuffer` per file | files and line ranges (B.2) |
| 2. Parse | tokens → `Ast` per file | files |
| 3. Collect & resolve | ASTs → module graph, symbol tables, resolved names (§7.10) | modules in topological layers |
| 4. Comptime & check | resolved AST → typed IR (TIR): types, instantiations, view/resource checks | functions |
| 5. Lower & optimize | TIR → P-IR (B.5), then optimization passes | functions |
| 6. Codegen & link | P-IR → machine code / shaders → executable | functions, then link |

`--expand` stops after stage 4 and pretty-prints the TIR as Pyro (§13.7). `pyro check`
stops after stage 4.

All compiler data lives in arenas, one per stage and thread, plus a global interning
table. Nodes refer to each other by `u32` index, never by pointer. Every stage's
output is a set of flat SoA arrays, so it can be cached to disk and memory-mapped back
for incremental builds (B.7).

## B.2 Lexing

The lexical grammar guarantees that **no token spans a line** (§2.1.1). Parallel lexing
is therefore simple and needs no boundary repair:

1. Memory-map the file. Use a SIMD scan (`pcmpeqb`/`vceqq_u8`, 32–64 bytes per step) to
   build the array of LF offsets.
2. Split the file into W pieces of about `size / W` bytes each, moving every split point
   forward to the byte after the next LF. Each piece starts at the beginning of a line,
   so no token, string or comment is ever cut.
3. Each worker lexes its piece into a thread-local `TokenBuffer`:

```pyro
@soa
struct Token {
    kind: TokenKind,   // u8 enum
    start: u32,        // byte offset in file
    len: u32,          // byte length (u32: no upper limit on string-literal length)
}
```

4. Concatenate the buffers with prefix sums of their lengths. Line and column numbers
   are computed only when a diagnostic needs them: binary-search the LF array, then
   count UTF-8 scalar values in the line.

Keywords are recognized with a perfect hash over identifier bytes, generated at the
compiler's own build time.

Design rationale, from the discussion about "64-byte chunks cutting a word in half":
backward scanning to a delimiter is unsound when a chunk starts inside a string literal
or block comment. Rather than add a quote and comment pre-scan, the language removed the
problem: Pyro has no block comments and no multi-line string tokens.

## B.3 Parsing and the AST

The reference parser is recursive descent with a Pratt loop (§3.9.1). The AST is a
single SoA table per file:

```pyro
@soa
struct Node {
    kind: NodeKind,      // u8/u16 enum: FnDecl, StructDecl, Let, If, Binary, Call, ...
    main_token: u32,     // token index for diagnostics
    a: u32,              // meaning depends on kind (child index, or extra index)
    b: u32,
}
struct Ast {
    nodes: List<Node>,       // root at index 0
    extra: List<u32>,        // variable-length child lists: [count, child0, child1, ...]
    tokens: TokenBuffer,
}
```

Examples: `Binary { a = lhs, b = rhs }` (operator from `main_token`);
`Call { a = callee, b = extra index of argument list }`; `If { a = cond, b = extra
index of [then, else] }`. Parent links are not stored, because passes walk top-down
with an explicit stack. A typical node is 13–16 bytes, and parsing performs no
per-node allocation.

## B.4 Semantic analysis

- **Interning:** identifiers are interned to `u32` symbol ids. Types are interned to
  `TypeId: u32` in a global table (structural types hash-consed, nominal types by
  declaration plus instantiation arguments).
- **Name resolution:** one flat hash table per module from symbol id to item index.
  Scopes inside functions are a stack of `(symbol, local index)` pairs.
- **Comptime evaluation:** a register-based interpreter over TIR. Values carry their
  `TypeId`. Types are values of type `type`, and memoization tables key type functions
  by (function, argument values).
- **View and resource checking (§5):** runs on the function's TIR control-flow graph:
  1. compute for each view-typed local its origin set (a forward dataflow over
     assignments);
  2. compute liveness of view values (a backward dataflow);
  3. for each access to a place, report E0332 if a live view's origin overlaps that
     place and the access conflicts;
  4. definite-move analysis for resources (a forward dataflow with states unmoved,
     moved and maybe-moved).

  All are standard bit-vector dataflow problems, linear in function size in practice.
  No constraint solving and no cross-function inference are needed.
- **Exhaustiveness:** the usual pattern-matrix algorithm over enum variants, booleans
  and integer ranges.

## B.5 P-IR: Pyro Intermediate Representation

P-IR is a typed SSA IR shared by all backends: LLVM, native, and GPU shader emitters.
It is lower-level than Pyro (no views, no generics, no SoA syntax) but keeps the facts
optimizers need: no-alias guarantees, SoA column structure, and vector types.

### B.5.1 Structure

```
module    := (global | function)*
global    := "global" @name ":" type "=" const ("align" N)? ("readonly")?
function  := "fn" @name "(" (%arg ":" type attrs)* ")" "->" type fnattrs "{" block+ "}"
block     := ^name ("(" (%param ":" type)* ")")? ":" inst* terminator
inst      := (%v ":" type "=")? opcode operands
```

- Blocks take **block parameters** instead of φ-nodes. A branch passes arguments:
  `br ^loop(%i1)`. This is equivalent to SSA with φ, and simpler for the native
  backend's register allocator.
- Every value is defined once and dominates all its uses (the verifier checks this).
- Types: `i1`, `i8`, `i16`, `i32`, `i64`, `f32`, `f64`, `ptr`, `vec<N x T>`, `void`.
  Sub-byte Pyro integers are lowered to their storage type, with explicit masking where
  semantics require it.
- Parameter attributes: `noalias` (every `mut` parameter and every view parameter whose
  origin cannot overlap another parameter, as guaranteed by §5.4.3), `readonly`,
  `align(N)`, `dereferenceable(N)`.

### B.5.2 Instructions

| Group | Opcodes | Notes |
|-------|---------|-------|
| Integer | `add sub mul udiv sdiv urem srem and or xor shl lshr ashr` | flags: `nuw`, `nsw` only when proven |
| Checked | `add.trap sub.trap mul.trap` | trap on signed or unsigned overflow per type |
| Float | `fadd fsub fmul fdiv frem fneg fma` | `fast` flag only under `@fast_math` |
| Compare | `icmp eq/ne/ult/ule/ugt/uge/slt/sle/sgt/sge`, `fcmp oeq/one/olt/ole/ogt/oge/uno/ord` | |
| Convert | `trunc zext sext fptrunc fpext fptoui.sat fptosi.sat uitofp sitofp bitcast ptrtoint inttoptr` | |
| Memory | `alloca T, align`, `load T, ptr, align`, `store v, ptr, align`, `gep ptr, idx, stride`, `memcpy`, `memset` | `load`/`store` carry `volatile` and `atomic(order)` flags |
| SoA | `soa.col base, field_index` → column pointer; `soa.load base, i, field`; `soa.store base, i, field, v` | lowered to `gep` + `load`/`store` before codegen, but kept until then so vectorization knows the columns cannot alias |
| Bit fields | `bf.extract unit, offset, width, signed`; `bf.insert unit, v, offset, width` | |
| Vector | `splat`, `extract`, `insert`, `shuffle`, `select`, `reduce.add/mul/min/max/and/or`, `load.masked`, `store.masked` | lane-wise arithmetic uses the scalar opcodes on vector types |
| Checks | `bounds i, len` (traps if `i >= len`), `trap kind, msg_id` | `bounds` is removed only by proof (range analysis, loop induction) |
| Handles | `handle.lookup pool_slots, h` → `(dense_index, ok: i1)` | expands to load slot, compare generation |
| Calls | `call @f(args)`, `call.indirect %p(args)`, `call.tail @f(args)` | `call.tail` must become a jump, or the frontend reports E0363 |
| Concurrency | `nursery.begin`, `spawn @f(args)`, `nursery.end` (join), `pfor.begin range, chunk`, `pfor.end` | lowered to runtime-library calls with task frames in per-worker arenas |
| Atomics | `atomic.rmw op, ptr, v, order`, `cmpxchg ptr, exp, new, s, f`, `fence order` | |
| Terminators | `br ^b(args)`, `cond_br c, ^t(args), ^f(args)`, `switch v, default ^d, [k: ^b]`, `ret v`, `unreachable` | |

### B.5.3 Required passes, in order

1. **Lowering:** desugared TIR is turned into P-IR. Bounds checks and overflow checks
   (`*.trap` in checked builds) are inserted explicitly.
2. **Canonicalize:** SSA construction (Braun et al., directly from the CFG), constant
   folding, dead-code elimination.
3. **O1 and above:** inlining of small and `@inline` functions, SROA, global value
   numbering, sparse conditional constant propagation.
4. **O2 and above:** loop canonicalization, induction-variable analysis, bounds-check
   elimination from range facts, loop-invariant code motion, **SoA-aware
   vectorization** (columns are `noalias`, so the dependence test is trivial; tails are
   handled with masked operations or a scalar epilogue), unrolling.
5. **O3:** aggressive inlining, cross-module optimization when `lto = true`.

Every pass must preserve the verifier invariants and the observable trap behaviour.

## B.6 Backends

### B.6.1 Bootstrap plan

The plan is to get correctness first and speed second:

1. **Stage 0:** a compiler written in Zig (memory-safe practices, data-oriented as
   above) that emits P-IR and lowers it to **LLVM IR**. This is the first backend. It
   provides every LLVM target immediately and a reference for testing.
2. **Stage 1:** the compiler rewritten in Pyro, compiled by stage 0 (self-hosting).
3. **Stage 2:** the **native backend** in Pyro, for x86-64, AArch64, RISC-V 64 and
   wasm32. It becomes the default for `dev` builds, where compile speed matters most,
   and later for all builds once its code quality is good enough.
4. LLVM remains an **optional** backend (`backend = "llvm"`) for targets the native
   backend lacks and for comparison. The language never depends on LLVM features.

### B.6.2 P-IR → LLVM mapping

Each P-IR opcode maps to one LLVM instruction or intrinsic: `*.trap` maps to
`llvm.*.with.overflow` plus a branch to a cold trap block; `fptoui.sat` maps to
`llvm.fptoui.sat`; `reduce.*` maps to `llvm.vector.reduce.*`; masked operations map to
`llvm.masked.load/store`; `noalias` maps to `noalias`. Block parameters become φ-nodes.
`call.tail` uses `musttail`. Float operations get no fast-math flags unless `fast` is
set. This preserves strict IEEE semantics (§6.4.4).

### B.6.3 Native backend design

- **Instruction selection:** maximal-munch tree tiling per basic block, over the
  expression DAG of P-IR values. The pattern tables per ISA are generated from a Pyro
  description file at the compiler's build time.
- **Register allocation:** linear scan over live intervals in block order, with
  interval splitting at block boundaries and spill slots 16-byte aligned. Calling
  conventions per §12.7. Pyro-to-Pyro calls use the same conventions (simplest), but
  SoA slices are passed as k+1 registers when available.
- **Encoding:** direct binary encoders per ISA (x86-64 with REX/VEX/EVEX prefixes,
  AArch64 32-bit words, RISC-V 32/16-bit with RVV for vectors, wasm32 bytecode).
- **Object files:** ELF64, Mach-O 64, COFF/PE32+, Wasm modules, written straight to
  memory buffers.
- **Linker:** the built-in parallel linker memory-maps the inputs, builds a global
  symbol table (open addressing, filled in parallel), lays out sections, and applies
  relocations in parallel. It supports the relocation types the native backend emits,
  plus those that C objects from `build.pr` commonly need. For unsupported inputs it
  falls back to the system linker.

## B.7 Incremental builds and hot reload

- The cache key per module is the hash of its tokens plus the interfaces (signatures,
  layouts) of the modules it imports, plus the environment and target. Changing a
  function body invalidates only that module's stage 4–6 outputs, not its importers.
- Per-function machine code is cached by the hash of its P-IR. Relinking incrementally
  patches only changed functions in `dev` builds.
- **Hot reload (dev only, optional feature):** the linker reserves a jump table for
  every function. A rebuilt function is loaded into fresh executable memory and its
  jump-table entry swapped at a safe point (between frames of `main`'s loop, signalled
  by `std.debug.hot_reload_point()`). Layout changes to types that are live in memory
  are refused, and a restart is requested.

## B.8 GPU compilation

Kernel P-IR is lowered to SPIR-V 1.5 by structured control-flow reconstruction (P-IR
CFGs from Pyro are always reducible, and loops are single-entry), to MSL by
pretty-printing, and to WGSL likewise. Bindings follow §11.2.2. The CPU
form is generated from the same P-IR by wrapping it in workgroup and invocation loops
and splitting at barriers (§11.2.1).

## B.9 Conformance test suite layout

```
conformance/
  02-lexical/  03-syntax/  04-types/  05-memory/  ...  14-std/
    <case>.pr        # source; expected diagnostics as trailing comments: `//~ E0332`
    <case>.out       # expected stdout for run-pass tests
```

Each rule with an error code has at least one passing and one failing case. Run-pass
tests are executed in every environment (`dev`, `test`, `prod`). Their output must be
identical, except for tests marked as depending on `debug_assertions`.
