# 4. Types

## 4.1 Overview

Every expression has exactly one static type, fixed at compile time. Pyro has no runtime
type information, no subtyping and no implicit boxing.

| Category | Types | Copy semantics (§5) |
|----------|-------|---------------------|
| Primitive | `bool`, `iN`, `uN`, `isize`, `usize`, `f32`, `f64`, `void`, `noreturn` | plain |
| SIMD | `vec<N, T>`, `mask<N>` | plain |
| Compound value | `[N]T`, `soa [N]T`, tuples, structs, enums | plain if all parts are plain, else resource |
| View | `[]T`, `soa []T`, `str`, `mut` returns, structs with view fields | view |
| Handle | `Handle<T>` | plain |
| Pointer | `*T`, `*const T`, `fn(...) -> R` | plain |
| Comptime-only | `type`, `FieldId<T>`, untyped constants | comptime |

Type names such as `bool`, `u8`, `f32`, `str`, `void` and `noreturn` are identifiers
predeclared in the prelude (§14.1). They are not keywords. Shadowing a prelude **type**
name or formatting intrinsic is an error (**E0301**). Shadowing other prelude names is
a warning (W0301).

## 4.2 Primitive types

### 4.2.1 `bool`

Values `true` and `false`. Size 1 byte, alignment 1, bit pattern `0x00` or `0x01`. Any
other bit pattern can only arise through `unsafe` code, and reading it is undefined
behaviour. Inside a struct, a `bool` field takes part in bit packing with width 1
(§4.11.2).

### 4.2.2 Integer types

- `uN` for N in 1..=64: unsigned, range 0 ..= 2ᴺ − 1.
- `iN` for N in 1..=64: two's complement, range −2ᴺ⁻¹ ..= 2ᴺ⁻¹ − 1.
- `usize` / `isize`: the same width as a target pointer (32 or 64 bits). They are
  distinct types: `usize` is not `u64` even on 64-bit targets.

**Storage size** of `uN`/`iN` when stored alone (variable, array element, SoA column):
the smallest of 1, 2, 4 or 8 bytes that holds N bits. Alignment equals the size. The
unused high bits are always zero for `uN` and copies of the sign bit for `iN`. This
invariant holds for every value safe code can observe.

Arithmetic on `uN`/`iN` is performed modulo the declared width N, not the storage width.
Overflow is defined in §6.4.2.

### 4.2.3 Floating-point types

`f32` and `f64` are IEEE 754-2008 binary32 and binary64. Default semantics are
**strict** (§6.4.4): round-to-nearest-even, no fused contraction, no reassociation, NaN
and signed zeros preserved. `@fast_math` (§8.8) relaxes this per function.

### 4.2.4 `void` and `noreturn`

- `void` has exactly one value and size 0. A function without `->` returns `void`. An
  enum payload of type `void` is written with empty parentheses: `.ok()`.
- `noreturn` has no values. An expression of type `noreturn` (a call to a function that
  returns `noreturn`, `return`, `break`, `continue`, a trap) converts implicitly to every
  type. A function declared `-> noreturn` must not return normally (**E0302**).

## 4.3 SIMD types

### 4.3.1 `vec<N, T>`

A fixed-length hardware vector. Constraints: `T` is an integer type with storage size
1, 2, 4 or 8 bytes, or `f32`, `f64`, `bool`; `1 ≤ N ≤ 64` (**E0303**).

- Size: `N × sizeof(T)` rounded up to a power of two. Alignment: `min(size, 64)`.
  `vec<3, f32>` has size 16 and alignment 16.
- Arithmetic, bitwise and comparison operators apply lane-wise (§10.6). Comparisons
  produce `mask<N>`.
- A scalar operand is broadcast implicitly in a binary operator: `v * 2.0`.
- Lanes are read and written with `v[i]` (bounds-checked) or swizzles (§10.6.2).
- Prelude aliases: `vec2<T> = vec<2, T>`, `vec3<T> = vec<3, T>`, `vec4<T> = vec<4, T>`.
- Construction: `vec3<f32>.{1.0, 2.0, 3.0}` is not allowed, because expressions cannot
  contain generic arguments. Use `let v: vec3<f32> = .{ 1.0, 2.0, 3.0 }`, the splat
  builtin `@splat(N, x)`, or the prelude constructors `vec2(x, y)`, `vec3(x, y, z)` and
  `vec4(x, y, z, w)`, which infer `T` from their arguments.

Anonymous literals with positional elements (`.{ a, b, c }`) are valid only when the
target type is a `vec` or a tuple (§6.2.2).

### 4.3.2 `mask<N>`

The result of a lane-wise comparison. It supports `&`, `|`, `^`, `!`, and the builtins
`@any(m)`, `@all(m)`, `@select(m, a, b)` and `@count(m)` (§10.6). Its in-memory layout is
implementation-defined. A `mask<N>` cannot be stored in a struct field or array
(**E0304**): masks live only in locals and registers.

## 4.4 Compound value types

### 4.4.1 Fixed arrays `[N]T`

`N` is a comptime constant of type `usize`. Elements are laid out contiguously with
stride `sizeof(T)` rounded up to `alignof(T)`. `[0]T` is valid and has size 0. Indexing
is bounds-checked (§6.5.3).

### 4.4.2 SoA arrays `soa [N]T`

`T` must be a struct type (**E0305**). The value holds one column per top-level field of
`T` (§4.11.5). Reading and writing use ordinary syntax:

- `a[i]` has type `T` when read (a gather of the columns) and is assignable as a whole
  (a scatter to all columns);
- `a[i].f` and `a.f[i]` both mean element *i* of column *f*. `a.f` is a view of type
  `[]F` (§4.5.1) over that column.

### 4.4.3 Tuples

`(A, B, …)` with two or more elements. They are laid out like a struct with fields `0`,
`1`, … in declaration order. Fields are accessed as `t.0`, `t.1`. Tuples are structural:
two tuple types are equal if their element types are equal.

### 4.4.4 Structs, enums

User-defined nominal types (§7.3, §7.4). `Option<T>` and `Result<T, E>` are ordinary
prelude enums (§14.1).

### 4.4.5 `Handle<T>`

A 64-bit generational reference into a `Pool<T>` or `Table`-family container (§14.4):
bits 0–31 hold the slot index (`u32`) and bits 32–63 hold the generation (`u32`).
No valid handle ever has generation 0. Pyro has no "null handle": an optional
reference is `Option<Handle<T>>`, which has the same size as a handle (§4.11.4). Handles
are plain values: copying one is cheap, and a stale handle is detected rather than
dereferenced.

## 4.5 View types

Views are non-owning. The rules restricting where they may be stored are in §5.4.

### 4.5.1 Slices `[]T`

A pair (pointer to the first element, length `usize`). It refers to a contiguous run of
`T`. Indexing and sub-slicing are bounds-checked.

### 4.5.2 SoA slices `soa []T`

One pointer per column of `T` plus a shared length (§4.11.5). Element access works as
for `soa [N]T`. A `soa [N]T` place coerces implicitly to `soa []T` (§4.9.1).

### 4.5.3 `mut T` views

`mut T` is a mutable view of a `T` stored somewhere else. It can be the result type of
a function (`-> mut Self`), a payload of `Option`/`Result` (`Option<mut T>`), or the
type of a local bound from such a result. It cannot be a parameter type: parameters use
the `mut` mode instead (§5.5.2, **E0339**). A `mut T` result is derived from one of the
function's `mut` arguments (§5.4.3). It is used for chaining (`pool.compact().sort()`)
and for element access (`pool.get_mut(h)`). A mutable view can be read, written through,
passed on as a `mut` argument, or used as a method receiver. Reading a `mut T` where a
`T` is expected copies the value (plain `T` only).

A `mut T` view of an element of SoA storage refers to one index across all columns. Its
representation (column pointers plus index) is implementation-defined.

### 4.5.4 `str`

`str` is a view of UTF-8 text: a pointer plus a byte length. Every `str` value safe code
can produce is valid UTF-8. String literals are `str` with static origin. `str` has no
NUL terminator. Indexing a `str` yields bytes (`u8`). Character iteration is a library
function (§14.6). Equality compares bytes.

## 4.6 Raw pointers

`*T` (read-write) and `*const T` (read-only) are addresses with no lifetime or bounds.
Creating, copying and comparing them is safe. Dereferencing, offsetting and converting
them from integers requires `unsafe` (chapter 12). Size and alignment equal `usize`.

`fn(A, B) -> R` is a pointer to a function with Pyro calling convention and no captured
environment. Calling it is safe. Size equals `usize`. Lambdas without captures coerce to
it (§6.10).

## 4.7 Type aliases and distinct types

- `type Name = T;` is an alias: `Name` and `T` are the same type.
- `type Name = distinct T;` is a new nominal type with the same layout as `T` and the
  same operators, but no implicit conversion to or from `T`. Convert explicitly with
  `x as Name` and `n as T`. Distinct types make domain units zero-cost:

```pyro
type Meters = distinct f32;
type Seconds = distinct f32;
let d: Meters = 100.0;          // untyped constants convert to distinct types
let t: Seconds = 9.58;
// let bad = d + t;             // E0310: mismatched types Meters and Seconds
let speed = (d as f32) / (t as f32);
```

Untyped constants (§4.8) convert implicitly to a distinct type whose underlying type
accepts them.

## 4.8 Untyped constants and inference

- Integer and character literals without a suffix are *untyped integer constants* with
  arbitrary precision. Float literals without a suffix are *untyped float constants*,
  represented exactly as rationals at comptime.
- Constant expressions built only from untyped constants stay untyped.
- When an untyped constant meets a typed context (annotation, parameter, operand of a
  typed value, return type), it converts to that type. If the value does not fit, that
  is an error (**E0306**). An untyped float converting to `f32`/`f64` rounds to nearest
  even. An untyped float cannot convert to an integer type (**E0306**).
- With no context, an untyped integer defaults to `i64` and an untyped float to `f64`.
- **Local inference:** `let x = expr;` gives `x` the type of `expr`. Inference never
  crosses function boundaries: parameter and return types are always written out (except
  `self`). Generic arguments of a call are inferred from argument types only (§7.6.3).

## 4.9 Conversions

### 4.9.1 Implicit conversions (complete list)

Only these conversions happen without `as`:

1. Untyped constant to a type that can represent it (§4.8).
2. `uN` to `uM` where M > N; `iN` to `iM` where M > N; `uN` to `iM` where M > N.
3. `f32` to `f64`.
4. `noreturn` to any type.
5. `[N]T` place to `[]T` view; `soa [N]T` place to `soa []T`; `[]T` / `soa []T` with a
   mutable origin used where a read-only view is expected.
6. `*T` to `*const T`.
7. Non-capturing lambda to `fn(...) -> R` (§6.10).
8. `T` to `Option<T>` when the expected type is `Option<T>` (a `.some` wrapper is
   inserted). This includes anonymous literals: `.{ … }` with expected type `Option<U>`
   constructs a `U` and wraps it.
9. A non-generic function name to `std.meta.FnRef` (comptime only, §8.4.1).

There is no implicit integer-to-float, float-to-integer, signed-to-unsigned, narrowing
or bool/integer conversion.

### 4.9.2 Explicit conversions with `as`

| From | To | Semantics |
|------|----|-----------|
| integer | integer | truncate to target width, or zero/sign-extend from source signedness |
| integer | float | round to nearest even |
| float | integer | round toward zero; saturate at target min/max; NaN → 0 |
| float | float | round to nearest even (`f64` to `f32`) |
| `bool` | integer | `false` → 0, `true` → 1 |
| enum without payloads | its backing integer type or wider | discriminant value |
| `distinct D` (underlying T) | T, and T to D | identity |
| `vec<N, A>` | `vec<N, B>` | lane-wise, per the scalar rules above |
| `*T` / `*const T` | `usize`, other pointer types | address unchanged (safe) |
| `usize` | `*T` | **unsafe only** (§12.2) |

Integer to `bool` is not a cast: write `x != 0`. Integer to enum uses
`@enum_from_int(E, x) -> Option<E>`. Any other cast is an error (**E0307**).

## 4.10 Type equality

- Structs, enums, protocols and distinct types are **nominal**: each declaration (and
  each distinct instantiation of a generic declaration, §7.6) is a different type.
- Arrays, slices, SoA types, tuples, vectors, pointers and function-pointer types are
  **structural**.
- Generic instances `G<A1..An>` and `G<B1..Bn>` are equal iff every `Ai` equals `Bi`
  (types by type equality, values by value equality).

## 4.11 Memory layout

Layout is deterministic. A given compiler version, target and type always produce the
same layout, so incremental builds and the debugger can rely on it. The Pyro layout of
non-`@c_layout` types may change between language **editions**, but not between compiler
versions within an edition.

### 4.11.1 Primitive layout

| Type | Size | Align |
|------|------|-------|
| `bool`, `u1`..`u8`, `i1`..`i8` | 1 | 1 |
| `u9`..`u16`, `i9`..`i16` | 2 | 2 |
| `u17`..`u32`, `i17`..`i32`, `f32` | 4 | 4 |
| `u33`..`u64`, `i33`..`i64`, `f64` | 8 | 8 |
| `usize`, `isize`, `*T`, `fn(..)` | pointer width | pointer width |
| `Handle<T>` | 8 | 8 |
| `void` | 0 | 1 |

### 4.11.2 Struct layout (default "Pyro layout")

Given fields f₁ … fₖ in declaration order:

1. **Bit-field runs.** A *bit field* is a field of type `uN`/`iN` with N not in
   {8, 16, 32, 64}, `bool`, or a payload-free enum without an explicit backing type.
   The enum's width is the number of bits needed for its largest discriminant, at least
   1. A 4-variant enum numbered 0–3 takes 2 bits. Each maximal run of consecutive bit
   fields is packed least-significant-bit first into *units* by the algorithm below. A
   field never straddles two units.
2. **Members.** Each unit and each non-bit field is a *member* with the size and
   alignment of its type (a unit of 3 bits is a 1-byte member).
3. **Ordering.** Members are stably sorted by alignment, descending. Ties keep
   declaration order.
4. **Placement.** Each member goes at the next offset that is a multiple of its
   alignment. Struct alignment = max member alignment (at least 1, raised by
   `@align(n)`). Struct size = end of the last member, rounded up to the struct
   alignment.

Unit packing algorithm (normative). A run is packed greedily into one unit as long as
the total fits in 64 bits. The unit is then sized to the total bits:

```
units = []
current_bits = 0
for each field f in a bit-field run:
    if current_bits + width(f) > 64:
        units.push(size_for(current_bits)); current_bits = 0
    offset_in_unit(f) = current_bits
    current_bits += width(f)
units.push(size_for(current_bits))
size_for(b) = 1 if b ≤ 8, 2 if b ≤ 16, 4 if b ≤ 32, else 8   (bytes)
```

Example:

```pyro
struct PlayerState {
    health: u7,          // unit 0, bits 0..=6
    is_crouching: bool,  // unit 0, bit 7
    weapon_slot: u3,     // unit 0, bits 8..=10  (11 bits total, so unit 0 is a u16)
    score: u32,
}
// Members after sorting: score (size 4, align 4) at offset 0, unit 0 (size 2) at offset 4.
// sizeof(PlayerState) = 8, alignof = 4.
```

Bit fields are not addressable. A bit field cannot be passed as a `mut` argument,
bound as a `mut` view, or be the origin of a view (**E0308**). Read it, compute, and
assign it back (`s.f = v`, `s.f += 1` are fine). A view of the whole struct is
unaffected.

Reading a bit field compiles to a load, shift and mask. Writing compiles to a
read-modify-write of its unit. Writes to two bit fields of the same unit are therefore
**not independent across threads**. The concurrency rules (§10.2) treat a whole unit as
one place for exclusivity, so this cannot race.

### 4.11.3 `@packed` and `@c_layout`

- `@packed` on a struct disables step 3 (no reordering) and sets every alignment to 1
  (no padding). Fields of a packed struct cannot be passed as `mut` arguments or viewed
  (**E0308**): copy them out, modify, and write them back.
- `@c_layout` on a struct uses the target C ABI layout: declaration order, natural
  alignment, no bit-field packing. Sub-byte integer fields are stored in their storage
  size (§4.2.2). `bool` is 1 byte. Only types with a defined C representation may appear
  (**E1201**, chapter 12).
- `@soa` structs never bit-pack: in SoA layout each field is its own column
  (§4.11.5), so the bit-field rules of §4.11.2 do not apply to them.

### 4.11.4 Enum layout

- **Payload-free enum** `enum E: B { ... }`: represented as the backing integer `B`.
  Without `: B`, the backing type is the smallest of `u8`/`u16`/`u32` that holds all
  discriminants. Discriminants default to 0, 1, 2, … in declaration order. An explicit
  `= expr` sets one (a comptime integer), and later variants continue from it.
  Duplicate discriminants are an error (**E0309**).
- **Enum with payloads**: laid out as a struct with two members, `payload` (a byte
  array of size and alignment equal to the largest variant payload, each payload laid
  out as a tuple) and `tag` (the discriminant, as above). Struct layout rules then apply.
- **Option of a handle**: `Option<Handle<T>>` has the same size as `Handle<T>`. `.none`
  is represented by generation 0, which no valid handle uses. Implementations must apply this one niche
  optimization. Others are allowed but not required.

### 4.11.5 SoA layout

For `soa [N]T` where `T` has top-level fields f₁ … fₖ (in declaration order, no
reordering) with storage sizes s₁ … sₖ:

- Column *i* is an array `[N]Fᵢ` where `Fᵢ` is the field type. Sub-byte integers and
  `bool` use their storage size (§4.11.1). They are **not** bit-packed in columns, which
  keeps every column directly SIMD-addressable.
- Column offsets: `base₁ = 0`, `baseᵢ₊₁ = align_up(baseᵢ + N·sᵢ, 64)`. Each column starts
  on a 64-byte boundary relative to the start of the value, and the value itself has
  alignment 64.
- Size: `align_up(baseₖ + N·sₖ, 64)`.
- Element *j* of field *i* is at `baseᵢ + j·sᵢ`.

`soa []T` is passed and stored as `k` column pointers followed by one `usize` length:
`(ptr₁, …, ptrₖ, len)`. Slicing a `soa []T` adjusts every pointer. Sub-slices start
mid-column, so only the full-length view of a `soa [N]T`, or a container that guarantees
it (§14.4), carries the 64-byte alignment guarantee. The compiler's vectorizer must
handle unaligned heads and tails (§10.6.4).

A field of struct type is a single column of that struct type, laid out AoS within the
column. SoA does not recurse automatically. Write `@soa` on the inner struct and store
it in its own container if nested SoA is needed.

`@soa` on a struct declaration makes `[N]T`, `[]T`, and the std containers
(`List<T>`, `Pool<T>`, `Table`) use SoA layout for that `T`, exactly as if `soa` were
written. Code using `[N]T` with an `@soa` struct is identical to code using
`soa [N]T`.

### 4.11.6 Cold fields

`@cold` on a field of a struct stored in `Pool<T>`, `List<T>` or a `Table` causes the
container to store all `@cold` fields of `T` in a separate parallel AoS array. Element
access syntax is unchanged. `@cold` has no effect on `T` stored elsewhere.

## 4.12 Limits

- Maximum type size: 2⁴⁸ − 1 bytes (**E0311**). Arrays may not exceed it.
- Maximum fields per struct and variants per enum: 65 535 (**E0311**).
- Maximum generic-instantiation depth: 256 (**E0812**).
