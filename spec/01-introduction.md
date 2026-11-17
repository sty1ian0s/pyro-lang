# 1. Introduction

## 1.1 Scope

This specification defines:

- the source text format and grammar of Pyro programs (chapters 2–3);
- the static semantics: types, name resolution, mutability, resource and view rules,
  compile-time evaluation (chapters 4, 5, 7, 8);
- the dynamic semantics: evaluation, traps, concurrency, GPU dispatch (chapters 6, 9–11);
- the package, build and tool interface (chapter 13);
- the minimum standard library every conforming implementation provides (chapter 14);
- the diagnostic codes a conforming compiler reports (appendix A).

It does not define machine-code generation algorithms, optimization passes or the
internal data structures of a compiler. Appendix B describes the reference architecture
informatively.

## 1.2 Conformance

The key words **must**, **must not**, **should**, **should not** and **may** are used as in
RFC 2119.

- A **conforming program** obeys every static rule in this specification.
- A **conforming implementation**:
  1. accepts every conforming program for each target it claims to support;
  2. rejects every program that violates a static rule marked with an error code
     (`Exxxx`), reporting that code (appendix A);
  3. executes accepted programs with the dynamic semantics defined here;
  4. traps (§9.4) in every situation this specification defines as a trap. It never
     continues with undefined behaviour, except inside `unsafe` code (chapter 12).

**Undefined behaviour** exists only inside `unsafe` blocks and `extern` calls. Safe Pyro
code (code outside `unsafe`) has no undefined behaviour. Every runtime fault is a
defined trap.

**Implementation-defined** behaviour is listed explicitly. Where it occurs, an
implementation must document its choice.

## 1.3 Notation

Grammar is written in EBNF:

| Form | Meaning |
|------|---------|
| `rule ::= ...` | production |
| `"text"` | terminal token, spelled exactly |
| `UPPER` | token class from chapter 2 (`IDENT`, `INT_LIT`, …) |
| `a b` | sequence |
| `a \| b` | alternative |
| `a?` | optional |
| `a*` / `a+` | zero or more / one or more |
| `( ... )` | grouping |

Code examples are Pyro unless marked otherwise. Examples are informative: if an example
contradicts a rule, the rule wins.

Diagnostic references look like **E0332**. Each one names the error a compiler reports
when the rule is broken.

## 1.4 Design principles

These principles come from the design conversation and decide ambiguous cases. When two
readings of a rule are possible, the reading that better satisfies the earlier principle
wins.

1. **Memory safety without annotations.** Safe code cannot cause use-after-free, double
   free, out-of-bounds access, data races or uninitialized reads. The programmer never
   writes lifetime annotations, and no global borrow checker is involved. Long-lived
   relationships use generational handles. Short-lived references (*views*) are checked
   locally inside one function (chapter 5).
2. **No hidden control flow and no hidden allocation.** Every allocation, call, loop and
   cleanup in the running program is visible in the source, or in its `--expand` output
   (§13.7). Pyro has no exceptions, no implicit destructors, no garbage collector, no
   operator overloading that allocates, no implicit copies of owning values and no
   runtime type information.
3. **Data-oriented by default where it matters.** Structure-of-arrays layout, dense
   storage, swap-back deletion, index-based relationships and bulk processing are the path
   of least resistance. Opting into SoA is one keyword (`soa`) or one attribute (`@soa`),
   and SoA data is read and written with ordinary field syntax.
4. **One obvious way.** Each construct has one syntax. Sugar exists only when it expands
   mechanically into ordinary Pyro (§6.12).
5. **Fast, simple compilation.** The grammar is context-free and parses deterministically
   with at most two tokens of lookahead, without backtracking. Every token lies within one
   source line, so lexing parallelizes trivially. Name resolution never needs type
   information.
6. **Low footguns.** Implicit conversions never lose information. Operator precedence
   follows the shape of the math, and there is no C-style bitwise/comparison trap.
   Results must be handled. Integer overflow traps in checked builds.
7. **Explicit mutability.** Values are immutable unless declared `mut`. A function can
   mutate an argument only if its parameter is declared `mut`, and the caller must write
   `mut` at the call site.
8. **Hardware sovereignty.** First-class SIMD vectors, sub-byte integers, cache-line
   alignment, CPU and GPU kernels from one source, and direct targeting of x86-64,
   AArch64, RISC-V and WebAssembly.
9. **Strings are for humans.** Text exists for people: UI, logs, files. Internal
   identifiers are integers or enums, and `@hash` turns a name into an integer at compile
   time (§8.6).

## 1.5 Design goals (non-normative)

These targets come from the design conversation. They guide implementers and are not
conformance requirements:

- Front end: hundreds of thousands of lines per second per core; incremental rebuilds of
  a single changed function under 15 ms.
- Source size: about 30–50 % of equivalent idiomatic Rust or C for data-processing code.
- Runtime: parity with hand-optimized C; faster than typical C on memory-bound workloads
  thanks to SoA, sub-byte packing and no-alias guarantees.
- Predictable latency: no GC pauses, and arena reset in O(1).

## 1.6 Terminology

- **Place:** an expression that denotes storage: a local, a parameter, a field of a
  place, an index of a place, or a dereferenced pointer (unsafe only).
- **Plain type:** a type whose values may be copied bit-for-bit (§5.2).
- **Resource type:** a type that owns memory or an external resource and must be
  explicitly consumed (§5.3).
- **View:** a non-owning reference to storage owned elsewhere (§5.4).
- **Origin:** the place that owns the storage a view refers to (§5.4).
- **Comptime:** evaluated by the compiler during compilation (chapter 8).
- **Checked build:** a build whose environment has `debug_assertions = true` (§13.3).
- **Trap:** an immediate, defined, non-recoverable termination of the program (§9.4).
