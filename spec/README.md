# The Pyro Programming Language — Specification

**Version:** Draft 0.1 · **Date:** 2026-11-17 · **Status:** working draft for implementers

Pyro is a statically typed, ahead-of-time compiled, data-oriented systems programming
language. It aims for code about as short as Python, speed of C or better, control of Zig
or better, and memory safety comparable to Rust, without lifetime annotations or a global
borrow checker.

This directory is the normative specification. A team should be able to write a conforming
compiler and standard library from these documents alone, without the design conversation
they were derived from.

## Documents

| # | File | Contents | Status |
|---|------|----------|--------|
| 1 | [01-introduction.md](01-introduction.md) | Scope, conformance, notation, design principles | normative |
| 2 | [02-lexical-structure.md](02-lexical-structure.md) | Source text, tokens, keywords, literals | normative |
| 3 | [03-syntax.md](03-syntax.md) | Complete grammar (EBNF), precedence, parsing rules | normative |
| 4 | [04-types.md](04-types.md) | Type system, conversions, memory layout | normative |
| 5 | [05-memory-model.md](05-memory-model.md) | Values, resources, views, exclusivity, safety | normative |
| 6 | [06-expressions-statements.md](06-expressions-statements.md) | Evaluation semantics, control flow, desugarings | normative |
| 7 | [07-items-modules.md](07-items-modules.md) | Functions, structs, enums, protocols, generics, modules | normative |
| 8 | [08-comptime.md](08-comptime.md) | Compile-time execution, reflection, builtins | normative |
| 9 | [09-errors-contracts-laws.md](09-errors-contracts-laws.md) | Result, `?`, traps, contracts, laws | normative |
| 10 | [10-concurrency-simd.md](10-concurrency-simd.md) | Structured concurrency, parallel loops, SIMD | normative |
| 11 | [11-gpu.md](11-gpu.md) | GPU compute, graphics, mesh and ray-tracing stages | normative |
| 12 | [12-unsafe-ffi.md](12-unsafe-ffi.md) | `unsafe`, raw pointers, C interop, MMIO | normative |
| 13 | [13-packages-build-tooling.md](13-packages-build-tooling.md) | `pyro.toml`, environments, `build.pr`, CLI, `--expand` | normative |
| 14 | [14-standard-library.md](14-standard-library.md) | Prelude and core library API | normative (API surface) |
| A | [A-diagnostics.md](A-diagnostics.md) | Diagnostic format and code registry | normative |
| B | [B-compiler-architecture.md](B-compiler-architecture.md) | Reference compiler design, P-IR, backends | informative |
| C | [C-design-decisions.md](C-design-decisions.md) | How the conversation's contradictions were resolved | informative |
| D | [D-examples.md](D-examples.md) | Complete example programs | informative |

## Reading order

- **Compiler implementers:** 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8, then the rest, then B.
- **Library authors:** 1, 4, 5, 7, 14.
- **Reviewing design choices:** C lists every place where the source conversation was
  ambiguous or contradictory, and what this draft chose.

## Versioning

The specification is versioned `MAJOR.MINOR`. Each source package declares the edition it
targets in `pyro.toml` (`edition = "2026"`). Breaking changes to the language land only in
a new edition. A conforming compiler must compile every edition it claims to support.
