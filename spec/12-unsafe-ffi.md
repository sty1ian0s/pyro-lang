# 12. Unsafe Code and Foreign Function Interface

Safe Pyro has no undefined behaviour (§1.2). This chapter defines the escape hatch
needed for drivers, memory-mapped I/O, the standard library's own internals and C
interoperability. Every unsafe operation must appear lexically inside an
`unsafe { ... }` block, so audits can find them with a text search.

## 12.1 `unsafe` blocks and `@unsafe` functions

`unsafe { ... }` is an expression (§6.11). Inside it, and only there:

- raw-pointer dereference, address-of, pointer arithmetic and integer-to-pointer
  conversion are allowed (§12.2);
- `extern` functions may be called (§12.6);
- functions marked `@unsafe` may be called;
- `@bit_cast` to types with invalid bit patterns is allowed (§8.7).

Using any of these outside `unsafe` is an error (**E1202**).

`@unsafe` on a function means callers must call it inside `unsafe` and uphold the
preconditions in its documentation. The body of an `@unsafe` function is **not**
implicitly an unsafe block: it needs its own `unsafe { }` for unsafe operations.

Comptime code cannot use `unsafe` (§8.6).

## 12.2 Raw pointers

For `p: *T` / `p: *const T` and a place `x: T`:

| Operation | Syntax | Result | Requires |
|-----------|--------|--------|----------|
| address of | `&x` | `*T` if `x` is a mutable place, else `*const T` | `unsafe` |
| dereference | `*p` | place of type `T` (assignable only for `*T`) | `unsafe` |
| index | `p[i]` | `*@ptr_add(p, i)` with no bounds check | `unsafe` |
| offset | `@ptr_add(p, n: isize)` | pointer moved by `n` elements | `unsafe` |
| from integer | `@ptr_from_int(T, a: usize)` | `*T` | `unsafe` |
| to integer | `@int_from_ptr(p)` or `p as usize` | `usize` | safe |
| compare | `==`, `!=`, `<` … | `bool` | safe |
| null | `@ptr_from_int(T, 0)` | null pointer | `unsafe` |

Taking `&x` of a local creates a pointer the view checker does not track. The unsafe
code is responsible for not using it after `x` goes out of scope, and for not writing
through it while a safe view of `x` is live (§12.8).

## 12.3 Unchecked operations

The standard library provides `@unsafe` variants that skip runtime checks:
`xs.get_unchecked(i)`, `xs.slice_unchecked(a, b)`, `std.mem.from_raw_parts(p, len)`
(builds a `[]T` from a pointer), `std.mem.from_raw_parts_mut`, and
`std.mem.uninit_slice(mut arena, T, n)`, which returns uninitialized memory that must
be fully written before it is read.

## 12.4 Uninitialized memory

Safe code never sees uninitialized memory (§5.8). Reading memory obtained from
`uninit_slice` before writing it, or reading padding bytes through `@bit_cast`, is
undefined behaviour.

## 12.5 C-compatible types

`@c_layout` structs and enums (§4.11.3) and the following types are **C-compatible**:

| Pyro | C |
|------|---|
| `bool` | `_Bool` |
| `i8`/`u8` … `i64`/`u64` | `int8_t`/`uint8_t` … `int64_t`/`uint64_t` |
| `isize` / `usize` | `ptrdiff_t` / `size_t` (and `intptr_t`/`uintptr_t`) |
| `f32` / `f64` | `float` / `double` |
| `*T` / `*const T` | `T *` / `const T *` |
| `void` (return only) | `void` |
| `@c_layout struct` | `struct` with the same field order |
| `@c_layout enum: iN/uN` (payload-free) | integer of that type |
| `[N]T` (as a struct field only) | `T[N]` |
| `fn(...)` declared inside an `extern` block | C function pointer |

`std.c` provides aliases `c_char`, `c_int`, `c_uint`, `c_long`, `c_ulong`,
`c_longlong`, `c_size_t`, which map to the target's C types.

`str` and slices are not C-compatible. Convert them explicitly with `s.ptr()` and
`s.len()`, or with `std.c.to_cstr(mut arena, s) -> *const c_char`, which copies and
NUL-terminates. For SoA, `xs.columns()` returns a `@c_layout` struct
`std.c.SoaParts(T)` holding one `*T_i` per column and `len: usize`. That is the
documented C ABI for passing SoA data, so no marshalling happens.

## 12.6 Extern blocks and exports

```pyro
@link("m")
extern "C" {
    pub fn cos(x: f64) -> f64;
    pub fn qsort(base: *u8, n: usize, size: usize, cmp: fn(*const u8, *const u8) -> c_int);
}

pub fn cosine(x: f64) -> f64 { unsafe { cos(x) } }

@export("pyro_add")
pub fn add(a: i32, b: i32) -> i32 { a + b }
```

- The ABI string must be `"C"` in this edition (**E1203**). It selects the target's
  standard C calling convention (§12.7).
- Every parameter and return type in an `extern` block, or of an `@export` function,
  must be C-compatible (**E1201**).
- Calling an `extern` function requires `unsafe`.
- C variadic functions cannot be declared in this edition. Call them through a C shim.
- `@export(name)` gives the function external linkage under `name` (default: the Pyro
  name) with the C calling convention. Only `@export` functions may be converted to a
  function-pointer parameter type declared in an `extern` block (**E1204**).
- `@link(name)` asks the linker to link library `name`. Static or dynamic linking is
  chosen by `[link]` in `pyro.toml` (§13.2).
- Any trap or panic must not unwind into C: Pyro never unwinds, so this holds
  automatically.

## 12.7 Calling conventions

Normative for `extern` calls and `@export` functions:

| Target | Convention |
|--------|-----------|
| x86-64 Linux, BSD, macOS | System V AMD64 psABI |
| x86-64 Windows | Microsoft x64 |
| AArch64 Linux, Windows | AAPCS64 (Windows: Microsoft ARM64 variant) |
| AArch64 macOS/iOS | Apple ARM64 ABI |
| RISC-V 64 | RISC-V psABI, LP64D |
| wasm32 | WebAssembly basic C ABI (tool-conventions) |

The Pyro-to-Pyro calling convention is **implementation-defined and unstable**. Pyro
functions are visible to C only through `@export`. Separately compiled Pyro packages
are linked by the same compiler, which guarantees consistency.

## 12.8 Obligations of unsafe code

Unsafe code must keep every guarantee of §5.10 intact for the safe code around it. In
particular it must not:

1. read uninitialized memory or invalid bit patterns (`bool` other than 0/1, enum
   discriminants without a variant, generation 0 in a non-null handle);
2. access memory outside an allocation, or after it is freed;
3. write to, or read from, a place while a safe mutable view of an overlapping place is
   live, or write while a safe read-only view is live;
4. create two overlapping `mut` views (for example by building slices with
   `from_raw_parts_mut`);
5. access memory concurrently with another thread unless every access is atomic
   (§10.5);
6. violate an `extern` function's documented contract.

Violating them is undefined behaviour. Checked builds should instrument raw-pointer
dereferences with bounds and liveness checks where the implementation can (for
example address-sanitizer style shadow memory, enabled by `[env.*] sanitize = true`).

## 12.9 Memory-mapped I/O

```pyro
const UART_DR: usize = 0x3F20_1000;

pub fn uart_write(byte: u8) {
    unsafe { @volatile_write(@ptr_from_int(u32, UART_DR), byte as u32); }
}
```

`@volatile_read(p: *const T) -> T` and `@volatile_write(p: *T, v: T)` perform exactly
one access of `sizeof(T)` bytes, which is never merged, split, reordered with other
volatile accesses, or removed. `T` must be an integer of storage size 1, 2, 4 or 8
(**E1205**). Volatile accesses are not atomic and do not order non-volatile memory. Use
`@atomic_fence` for that.

## 12.10 Assembly

Inline assembly is not part of this edition. Assembly source files (`.S`) are assembled
and linked through `build.pr` (§13.5) and called through `extern "C"`.
