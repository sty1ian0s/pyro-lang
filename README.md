# Pyro

Pyro is a statically typed, ahead-of-time compiled, data-oriented systems programming
language. It aims for code about as short as Python, speed of C or better, control of Zig
or better, and memory safety comparable to Rust, without lifetime annotations or a global
borrow checker.

Highlights:

- **Memory safety without lifetimes:** resources with checked moves, second-class views,
  generational handles, always-on bounds checks.
- **Data-oriented layout in the language:** `soa` arrays, `@soa` structs, deterministic
  bit-field packing.
- **CPU and GPU in one language:** compute, graphics, mesh and ray-tracing stages, with
  laws that check CPU and GPU results agree.
- **Comptime instead of macros:** Zig-style compile-time execution and reflection.
- **Explicit errors:** `Result`/`Option` with `?`, traps instead of undefined behavior,
  contracts and property-tested laws.

## Status

Draft 0.1 of the specification. There is no compiler yet.

## Specification

Start at [spec/README.md](spec/README.md) for the document index and reading order.

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).
