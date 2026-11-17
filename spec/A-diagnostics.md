# Appendix A. Diagnostics

## A.1 Requirements

The user requirement is plain-language diagnostics that a beginner can act on. Every
diagnostic a conforming compiler emits for a rule in this specification:

1. carries the code listed below (`E` = error, `W` = warning);
2. names the source location (file, 1-based line and column) and shows the source line
   with the offending span marked;
3. states the problem in plain language, without internal compiler terms (say "the
   value `tmp` is still used here" rather than "live range");
4. where a fix is known, gives a concrete **help** line, and a machine-applicable edit
   in `--message-format json` mode;
5. for errors inside generic instantiations, comptime evaluation or `--expand`ed sugar,
   adds an instantiation or expansion trace that ends at the user's own code (§7.6.4).

The compiler should continue after errors and report as many independent errors as it
can, but never more than one error caused by another.

## A.2 Format

```
error[E0332]: `arena` is changed while a slice from it is still in use
  --> src/frame.pr:4:5
   |
 3 |     let tmp = arena.alloc_slice(u32, 64);
   |               ----- `tmp` points into `arena` here
 4 |     arena.reset();
   |     ^^^^^^^^^^^^^ `arena` is reset here
 5 |     tmp[0] = 1;
   |     --- ...but `tmp` is still used here
   |
help: finish using `tmp` before calling `reset`, or move `arena.reset()` into a `defer`
```

The JSON format (`--message-format json`) emits one object per line with fields
`code`, `severity`, `message`, `spans[] {file, line, column, end_line, end_column,
label, primary}`, `help[]`, `fixes[] {file, range, replacement}` and `trace[]`.

Warnings may be configured per item with `@allow(W....)` / `@deny(W....)`. Errors cannot
be suppressed.

## A.3 Registry

### Lexical (E01xx)

| Code | Meaning | § |
|------|---------|---|
| E0101 | invalid UTF-8 in source | 2.1 |
| E0102 | stray carriage return | 2.1 |
| E0103 | source file too large | 2.1 |
| E0104 | forbidden control character or unused symbol | 2.1, 2.7 |
| E0105 | identifier longer than 255 bytes | 2.3 |
| E0106 | reserved future keyword used as identifier | 2.4.2 |
| E0107 | misplaced `_` in numeric literal | 2.6.1 |
| E0108 | literal does not fit its suffix type | 2.6.1 |
| E0109 | invalid escape in string or char literal | 2.6.4 |
| E0110 | lone `@` | 2.7 |

### Syntax (E02xx)

| Code | Meaning | § |
|------|---------|---|
| E0201 | `pub` not allowed here | 3.2 |
| E0202 | unknown attribute | 3.3 |
| E0203 | attribute not allowed in this position | 3.3 |
| E0204 | function without body outside a protocol | 3.4 |
| E0205 | misplaced `self` | 3.4 |
| E0206 | default parameter before a non-default one | 3.4 |
| E0207 | assignment target is not a place | 3.5 |
| E0208 | `spawn` / `launch` / `return tail` needs a call | 3.5 |
| E0209 | `launch` target must be `gpu` or `cpu` | 3.5 |
| E0210 | unknown loop label | 3.5 |
| E0211 | alternative patterns bind different names | 3.7 |
| E0212 | struct pattern misses fields (add `..`) | 3.7 |
| E0213 | `mut`/`move` in a position that does not allow it | 3.8.2 |
| E0214 | chained comparison | 3.9 |
| E0215 | mixed named and positional elements in `.{…}` | 3.8 |

### Types and items (E03xx)

| Code | Meaning | § |
|------|---------|---|
| E0301 | shadowing a prelude type or intrinsic | 4.1 |
| E0302 | `noreturn` function returns | 4.2.4 |
| E0303 | invalid `vec` element type or length | 4.3.1 |
| E0304 | `mask` stored in memory | 4.3.2 |
| E0305 | `soa` of a non-struct type | 4.4.2 |
| E0306 | constant does not fit / invalid constant conversion | 4.8 |
| E0307 | invalid `as` cast | 4.9.2 |
| E0308 | view or `mut` of a bit field or `@packed` field | 4.11.2, 4.11.3 |
| E0309 | duplicate enum discriminant | 4.11.4 |
| E0310 | type mismatch | 4.7, 6.4 |
| E0311 | type too large / too many fields | 4.12 |
| E0320 | resource used without `move` | 5.3.2 |
| E0321 | `move` of something other than a local or `move` parameter | 5.3.2 |
| E0322 | resource not released on some path | 5.3.3 |
| E0323 | use after move | 5.3.3 |
| E0324 | resource moved on only some branches | 5.3.3 |
| E0325 | resource in a fixed array or container | 5.3.1 |
| E0326 | `move` parameter of plain type | 5.5.2 |
| E0327 | resource discarded (temporary or `_ =`) | 5.3.3, 6.11.1 |
| E0328 | shared cell (`Atomic`) used as a value | 5.1 |
| E0329 | type argument violates the `plain` bound | 7.6.1 |
| E0330 | view stored where it could outlive its origin | 5.4.1 |
| E0331 | returning a view of a local or `move` parameter | 5.4.3 |
| E0332 | conflicting access while a view is live (exclusivity) | 5.4.2 |
| E0333 | the same place passed as `mut` and again in one call | 5.4.3 |
| E0334 | missing `mut` at call site | 5.5.2 |
| E0335 | `mut` at call site for a non-`mut` parameter | 5.5.2 |
| E0336 | `mut` argument is not a mutable place | 5.5.2 |
| E0337 | write through an immutable binding | 5.5.1 |
| E0338 | write to a non-`mut` parameter | 5.5.2 |
| E0339 | `mut T` used as a parameter type | 4.5.3 |
| E0340 | missing struct field | 5.8, 6.2.1 |
| E0341 | invalid type for a `const` | 5.9 |
| E0342 | `@append_only` on a method without `unsafe` | 5.4.2 |
| E0350 | anonymous literal without expected type | 6.2.2 |
| E0351 | field given twice | 6.2.1 |
| E0352 | struct cannot be constructed outside its module | 6.2.1 |
| E0353 | inferred member `.name` not found | 6.2.3 |
| E0354 | comprehension in an unsupported position | 6.2.5 |
| E0355 | ambiguous method from two protocols | 6.3.3 |
| E0356 | `guard` else-block does not diverge | 6.6.2 |
| E0357 | non-exhaustive `match` | 6.6.3 |
| E0360 | control flow leaves a `defer` block | 6.8.1 |
| E0361 | lambda writes a captured variable | 6.10 |
| E0362 | `errdefer` in a function not returning `Result` | 6.8.2 |
| E0363 | `return tail` cannot reuse the frame | 6.9 |
| E0370 | default value is not a comptime constant | 7.2.3 |
| E0371 | missing return value | 7.2.1 |
| E0372 | cannot infer generic parameter | 7.6.3 |
| E0373 | argument type does not satisfy bound | 7.5.2 |
| E0374 | invalid named-argument order or duplicate | 7.2.4 |
| E0375 | protocol used as a type | 7.5 |
| E0376 | recursive value type | 7.3.1 |
| E0377 | backing type on enum with payloads | 7.4 |
| E0378 | `impl` signature mismatch or missing method | 7.5.1 |
| E0379 | incoherent or duplicate `impl` | 7.5.1 |

### Concurrency and SIMD (E05xx)

| Code | Meaning | § |
|------|---------|---|
| E0501 | `spawn` outside a `nursery` | 3.5 |
| E0502 | spawned function returns a value | 10.2 |
| E0503 | invalid `parallel_for` iterable | 10.3 |
| E0504 | outer write or early exit in `parallel_for` | 10.3 |
| E0505 | non-plain channel message type | 10.4 |
| E0506 | `@simd` loop cannot be vectorized | 10.6.4 |
| E0507 | allocation reachable from `@no_alloc` | 10.7 |
| E0508 | mixed swizzle alphabets | 10.6.2 |

### Errors and contracts (E06xx, E07xx)

| Code | Meaning | § |
|------|---------|---|
| E0601 | `?` error type has no `From` conversion | 6.12.1 |
| E0602 | `?` in a function with an incompatible return type | 6.12.1 |
| E0603 | unused `Result` | 9.1.1 |
| E0604 | `@todo_err` in an environment that forbids it | 9.2 |
| E0605 | missing or duplicate trap handler | 9.4 |
| E0701 | contract statically violated | 9.5.3 |
| E0702 | contract expression has side effects | 9.5.1 |
| E0703 | invalid law signature | 9.6.1 |
| E0704 | law called from non-test code | 9.6.1 |

### Comptime (E08xx)

| Code | Meaning | § |
|------|---------|---|
| E0801 | value is not comptime-known | 5.5.2, 8.2 |
| E0802 | comptime-only value reaches runtime | 8.3, 8.6 |
| E0803 | unknown field in `FieldId` literal | 8.4.1 |
| E0804 | `@compile_error` reached | 8.5 |
| E0805 | operation not allowed at comptime | 8.6 |
| E0806 | `@embed_file` path outside the package | 8.6 |
| E0807 | missing build-environment key | 8.6 |
| E0808 | comptime evaluation budget exceeded | 8.6 |
| E0809 | `@pure` function has effects | 8.8 |
| E0811 | `@hash` collision | 8.6.1 |
| E0812 | generic instantiation too deep | 4.12 |

### Modules and packages (E09xx)

| Code | Meaning | § |
|------|---------|---|
| E0901 | module path segment is not an identifier | 7.8.1 |
| E0902 | cyclic module imports | 7.8.3 |
| E0903 | name collision between imports or items | 7.8.2 |
| E0904 | local module shadows a dependency | 7.8.2 |
| E0905 | importing a private item | 7.8.2 |
| E0906 | cyclic package dependencies | 13.4 |
| E0907 | untrusted dependency build script | 13.5 |
| E0908 | package has both or neither of `main.pr`/`lib.pr` | 13.1 |
| E0909 | unknown key in `pyro.toml` | 13.2 |
| E0910 | unsatisfiable dependency requirements | 13.4 |
| E0911 | lock-file hash mismatch | 13.4 |
| E0912 | hosted-only module in a `no_std` package | 14.1.1 |
| E0913 | `std.build` used outside `build.pr` | 14.12 |

### GPU (E10xx), FFI (E12xx), library (E14xx)

| Code | Meaning | § |
|------|---------|---|
| E1001 | invalid compute-kernel parameter or return type | 11.1.2, 11.2 |
| E1002 | invalid workgroup size | 11.1.1 |
| E1003 | forbidden operation in stage-reachable code | 11.1.3 |
| E1004 | feature not supported by any configured backend | 11.1.1, 11.1.3 |
| E1005 | stage builtin used outside its stages | 11.1.7 |
| E1006 | possibly racing GPU write (storage, workgroup memory, payload) | 11.1.6 |
| E1007 | `launch` without `over` and without slice argument | 11.2.3 |
| E1008 | invalid graphics/ray-tracing stage parameter or fragment-only texture call elsewhere | 11.1.2, 11.3.2 |
| E1009 | pipeline stages, targets, unified parameters or submission arguments do not match | 11.1.2, 11.3–11.6 |
| E1010 | invalid `MeshOut` use, or `@task_payload` without task stage | 11.4.3 |
| E1011 | ray payload, hit attributes, `max_recursion` or pipeline counts out of range | 11.5.2 |
| E1012 | `trace_ray` in a wrong stage, GPU-local type misuse, or conflicting comptime ray flags | 11.1.3, 11.5 |
| E1013 | barrier or mesh/task synchronization not in uniform control flow | 11.1.5 |
| E1201 | type is not C-compatible | 12.5 |
| E1202 | unsafe operation outside `unsafe` | 12.1 |
| E1203 | unsupported extern ABI string | 12.6 |
| E1204 | non-exported function used as C callback | 12.6 |
| E1205 | invalid volatile access type | 12.9 |
| E1401 | format string does not match arguments | 14.6 |

### Warnings

| Code | Meaning | § |
|------|---------|---|
| W0101 | doc comment documents nothing | 2.8 |
| W0201 | shift mixed with `+`/`-` without parentheses | 3.9 |
| W0301 | local shadows a module item or prelude name | 6.3.1 |
| W0302 | unreachable `match` arm | 6.6.3 |
| W0401 | array-of-structs data in a SIMD loop or kernel | 10.6.4 |
| W0501 | cyclic channel topology in a `nursery` | 10.4.1 |
| W0601 | `@todo_err` present | 9.2 |
| W0801 | `@compile_log` present | 8.5 |
| W0802 | use of a deprecated item | 8.8 |
| W1001 | GPU stage limit above the portable minimum | 11.4.5, 11.5.2 |
| W1002 | mesh output slots possibly left unwritten | 11.4.3 |

Implementations may add warnings with codes `W9xxx`. They must not add errors that
reject conforming programs.
