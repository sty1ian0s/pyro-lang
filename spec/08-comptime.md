# 8. Compile-Time Execution

Pyro's metaprogramming is Zig-style: ordinary Pyro code runs inside the compiler. It
uses the same syntax and type checker as runtime code. There is no separate macro
language and no token or AST rewriting: comptime code produces values and types, never
syntax.

## 8.1 Comptime contexts

An expression is evaluated at compile time when it is:

- the initializer of a `const`;
- inside a `comptime { ... }` block, or prefixed with `comptime`;
- an argument to a `comptime` parameter, including generic arguments;
- an array length, a `vec` lane count, or a field default;
- an attribute argument;
- a type expression;
- the condition or iterable of an `inline for`.

The result of a comptime evaluation is a **comptime value**. It is embedded in the
program as a constant (in read-only data if it is an array). Comptime evaluation never
leaves runtime side effects.

## 8.2 Comptime parameters

`fn f(comptime n: usize, x: f32)` requires `n` to be comptime-known at each call
(**E0801**). Each distinct value of `n` produces a separate instantiation of `f`
(memoized). Inside `f`, `n` is a constant, so it may size arrays, select branches with
`comptime if`, and drive `inline for`.

A `comptime` parameter of function type accepts a function name, a non-capturing lambda,
or a capturing lambda (§6.10). The lambda is inlined into each instantiation.

```pyro
pub fn retain<T>(mut items: List<T>, comptime keep: fn(T) -> bool) { ... }
let min_hp = 10;
monsters.retain(|m| m.health > min_hp);      // captures min_hp, inlined
```

## 8.3 Types as values

`type` is the type of types. Values of type `type` exist only at comptime (**E0802** if
one reaches runtime).

### 8.3.1 Type functions

A function that returns `type` is a **type function**. It may build and return
`struct { ... }` expressions that use its comptime parameters (anonymous `enum`
expressions are reserved for a future edition):

```pyro
pub fn SortedSoA(comptime T: type, comptime CAP: usize) -> type {
    return struct {
        len: usize = 0,
        cols: soa [CAP]T,
        order: [CAP]u32 = [0; CAP],
        // methods ...
    };
}
const MonsterTable = SortedSoA(Monster, 512);
```

Type functions are memoized: equal arguments (types by identity, values by equality)
return the identical type.

### 8.3.2 Names of generated types

A type returned by a type function is named `F(args)` in diagnostics and `--expand`
output, for example `SortedSoA(Monster, 512)`. When it is bound to a `const`, the
const's name is used as an alias in messages. `--expand` prints each generated type
once, as a top-level `struct` declaration named `F__a1__a2…`. Each argument is
rendered as follows: types by their (mangled) name, integers in decimal (`m` prefix for
negatives), `bool` as `t`/`f`, `FieldId` by field name, and struct values as
`field_value` pairs joined by `_` (fields at their default value are omitted). Example:
`Table(Monster, .{ sorted_by: .threat, .. })` → `Table__Monster__sorted_by_threat`.

## 8.4 Reflection

Reflection is read-only and comptime-only. No reflection data exists at runtime.

`@type_info(T)` returns a `std.meta.TypeInfo` value (§14.8):

```pyro
pub enum TypeInfo {
    int(IntInfo),            // .{ signed: bool, bits: u8 }
    float(FloatInfo),        // .{ bits: u8 }
    bool_, void_, noreturn_, type_,
    vector(VectorInfo),      // .{ len: usize, child: type }
    array(ArrayInfo),        // .{ len: usize, child: type, soa: bool }
    slice(SliceInfo),        // .{ child: type, soa: bool }
    pointer(PointerInfo),    // .{ child: type, is_const: bool }
    struct_(StructInfo),     // .{ fields: []FieldInfo, is_soa: bool, is_resource: bool, size: usize, align: usize }
    enum_(EnumInfo),         // .{ variants: []VariantInfo, backing: type }
    tuple(TupleInfo),        // .{ fields: []type }
    function(FnInfo),        // .{ params: []ParamInfo, ret: type }
    handle(type),
}
pub struct FieldInfo {
    pub name: str, pub ty: type, pub offset: usize,
    pub bit_offset: u8, pub bit_width: u8,       // bit_width 0 for non-bit fields
    pub is_pub: bool, pub is_pub_mut: bool, pub has_default: bool,
}
```

Other reflection builtins: `@size_of(T)`, `@align_of(T)`, `@type_name(T) -> str`,
`@has_field(T, name) -> bool`, `@has_method(T, name) -> bool`,
`@fn_info(f) -> std.meta.FnInfo` (parameters with names, modes, types and attributes;
return type; attributes of `f`, for a function or `FnRef`),
`@implements(T, P) -> bool`, `@field_type(T, name) -> type`.

### 8.4.1 Function references

`std.meta.FnRef` is a comptime-only type whose values name a non-generic function.
Where a `FnRef` is expected, a function name converts implicitly (§4.9.1 rule 9). Code
that receives one inspects it with `@fn_info` and calls it with `@call(f, args…)`, which
type-checks like a direct call. GPU pipeline descriptors use this (§11.5.2, §11.6.1).

### 8.4.2 Field identifiers

`FieldId<T>` is a comptime-only type whose values name a field of struct `T`. An inferred
member literal `.name` converts to `FieldId<T>` when the expected type is `FieldId<T>`,
and is checked against `T`'s fields at that point. A non-existent field is an error at
the literal (**E0803**). This makes field names typed instead of stringly typed.

`@field(x, f)` accesses field `f` of `x`, where `f` is a `FieldId<T>` or a comptime
`str`. It is a place if `x` is a place. On a SoA value, `@field(xs, f)` is the column.

```pyro
fn sort_key<T>(xs: soa []T, comptime f: FieldId<T>, i: usize) -> @field_type(T, f) {
    @field(xs, f)[i]
}
```

## 8.5 Comptime control flow and diagnostics

- `comptime if cond { A } else { B }` inside a runtime function: `cond` is evaluated at
  compile time, and only the chosen branch is type-checked and compiled. This is the
  normative form of conditional compilation.
- `inline for` (§6.7.3) unrolls over comptime sequences.
- `@compile_error(msg)` aborts compilation with `msg` (**E0804**) if it is evaluated.
  A `@compile_error` in the untaken branch of a `comptime if` is not evaluated.
- `@compile_log(args...)` prints during compilation. A build that contains it emits
  warning **W0801**, so it is not left in by accident.

```pyro
comptime {
    if @size_of(HotParticle) > 64 {
        @compile_error("HotParticle exceeds one 64-byte cache line");
    }
}
```

## 8.6 Comptime capabilities and limits

Comptime code may run any Pyro code except:

- `unsafe` blocks, `extern` calls, raw-pointer operations (**E0805**);
- concurrency (`nursery`, `spawn`, `parallel_for`, `launch`) (**E0805**);
- I/O, except the deterministic inputs below.

Deterministic inputs:

- `@embed_file(path) -> [N]u8`: the bytes of a file, path relative to the package root
  and confined to it (**E0806**). The file becomes a build dependency.
- `@env(key)`: a value from the selected build environment (§13.3). The result type
  follows the TOML type (`str`, `bool`, `i64`, `f64`). A missing key is an error
  (**E0807**). `@env_or(key, default)` does not fail.
- `@target()`: a `std.meta.Target` value (`.arch`, `.os`, `.abi`, `.pointer_bits`,
  `.has_feature(.avx2)`), §14.8.
- `@hash(s)`: see §8.6.1.

**Memory.** Comptime code allocates from a compiler-managed arena that is freed after
evaluation. Comptime values that reach runtime must be plain, `str`, or arrays/slices of
plain values (**E0802**).

**Budget.** Each top-level comptime evaluation has a budget of 10 000 000 executed
backward branches and calls (loop iterations plus calls). Exceeding it is an error
(**E0808**) with the comptime stack trace. `@set_eval_quota(n)` inside the evaluation
raises its budget.

**Determinism.** Comptime evaluation must produce the same result on every host for the
same target and environment. Floating point at comptime is strict IEEE (§6.4.4) and
evaluated as on the target. Integer widths are the target's (`usize` = target width).

Build scripts (`build.pr`, §13.5) are the only place where comptime-like code may do
arbitrary I/O.

### 8.6.1 `@hash`

`@hash(s: str) -> u64` computes the 64-bit FNV-1a hash of the UTF-8 bytes of `s` at
compile time. `s` must be comptime-known (**E0801**). The compiler records every distinct
string hashed in a program. Two distinct strings with the same hash are a compile error
(**E0811**), so `@hash` values are collision-free within a program. In checked builds the
compiler emits a debug table that maps hash to string, used by debuggers and by
`std.debug.name_of(h)`. Unchecked builds omit it. This implements the zero-string
policy: identifiers for events, components and config keys are `u64` values (principle
9).

## 8.7 Builtin functions (complete list)

| Builtin | Signature / meaning | Context |
|---------|--------------------|---------|
| `@size_of(T)`, `@align_of(T)` | `usize` | comptime |
| `@type_info(T)`, `@type_name(T)` | §8.4 | comptime |
| `@has_field`, `@has_method`, `@implements`, `@field_type` | §8.4 | comptime |
| `@field(x, f)` | field access by `FieldId` / comptime `str` | any |
| `@call(f, args…)` | call through a comptime `FnRef` (§8.4.1) | any |
| `@variant_count(E)` | `usize` | comptime |
| `@enum_from_int(E, x)` | `Option<E>` | any |
| `@compile_error(msg)`, `@compile_log(...)` | §8.5 | comptime |
| `@set_eval_quota(n)` | §8.6 | comptime |
| `@embed_file(path)` | `[N]u8` | comptime |
| `@env(key)`, `@env_or(key, d)` | §13.3 | comptime |
| `@target()` | `std.meta.Target` | comptime |
| `@hash(s)` | `u64`, §8.6.1 | comptime arg |
| `@zero(T)` | the all-zero value of plain type `T` | any |
| `@splat(N, x)` | `vec<N, T>` with every lane `x`; `T` from the expected type, else from `x` | any |
| `@select(m, a, b)`, `@any(m)`, `@all(m)`, `@count(m)` | §10.6 | any |
| `@reduce_add(v)`, `@reduce_mul(v)`, `@reduce_min(v)`, `@reduce_max(v)`, `@reduce_and(v)`, `@reduce_or(v)` | horizontal reductions, §10.6 | any |
| `@shuffle(v, comptime idx)` | lane permutation | any |
| `@vector_width(T)` | comptime `usize`: preferred native lane count for `T` on the target | comptime |
| `@fma(a, b, c)` | fused multiply-add (exactly one rounding) | any |
| `@add_wrap`, `@sub_wrap`, `@mul_wrap`, `@add_sat`, `@sub_sat`, `@mul_sat`, `@add_checked`, `@sub_checked`, `@mul_checked`, `@shl_checked` | §6.4.2 | any |
| `@clz(x)`, `@ctz(x)`, `@popcount(x)`, `@bswap(x)`, `@bit_reverse(x)` | bit operations | any |
| `@bit_cast(T, x)` | reinterpret plain `x` as plain `T` of equal size; `T` must have no invalid bit patterns (no `bool`, enums, handles) or the call must be in `unsafe` | any |
| `@todo_err(e)` | §9.2 | any |
| `@trap(msg)`, `@unreachable()` | trap, §9.4 | any |
| `@old(e)` | §9.5 | `@ensures` only |
| `@global_invocation_id`, `@local_invocation_id`, `@workgroup_id`, `@num_workgroups` | builtin **variables**, written without parentheses (§11.1.7) | compute, task, mesh |
| `@workgroup_barrier()` | §11.1.4–11.1.5 | compute, task, mesh |
| `@vertex_index`, `@instance_index`, `@frag_coord`, `@front_facing`, `@sample_index`, `@launch_id`, `@launch_size` | builtin variables (§11.1.7) | matching stages |
| `@discard()`, `@dpdx(v)`, `@dpdy(v)`, `@fwidth(v)` | §11.1.7 | fragment |
| `@spec(name, default)` | pipeline specialization constant (§11.6.2) | GPU stages |
| `@fn_info(f)` | `std.meta.FnInfo` of a function or `FnRef` (§8.4) | comptime |
| `@volatile_read(p)`, `@volatile_write(p, v)`, `@ptr_from_int(T, a)`, `@ptr_add(p, n)` | §12 | unsafe |
| `@int_from_ptr(p)` | §12.2 | any (safe) |
| `@atomic_fence(order)` | §10.5 | any |
| `@prefetch(p, .read \| .write)` | cache hint; no semantic effect | any |
| `@likely(b)`, `@unlikely(b)` | branch hint; returns `b` | any |
Builtins, and the prelude formatting intrinsics `print`, `eprint` and `format`
(§14.6), are the only variadic functions in Pyro. The formatting intrinsics are ordinary
identifiers (not `@` builtins) because they are the most common calls in beginner code.
They cannot be shadowed (**E0301**).

## 8.8 Attributes (complete list)

| Attribute | Applies to | Meaning |
|-----------|-----------|---------|
| `@soa` | struct | containers of this type use SoA layout (§4.11.5) |
| `@align(n)` | struct, field | minimum alignment `n` (power of two, ≤ 4096) |
| `@packed` | struct | no reordering or padding (§4.11.3) |
| `@c_layout` | struct, enum | C ABI layout (§12.5) |
| `@cold` | field | stored apart in containers (§4.11.6) |
| `@resource` | struct | resource type (§5.3) |
| `@test(traps: kind?)` | fn | test function (§13.6) |
| `@bench` | fn | benchmark (§13.6) |
| `@trap_handler` | pub fn | the package's trap handler (§9.4) |
| `@law(cases: n?)` | fn | algebraic law (§9.6) |
| `@requires(cond, msg?)` | fn | precondition (§9.5) |
| `@ensures(cond, msg?)` | fn | postcondition (§9.5) |
| `@invariant(cond, msg?)` | struct | type invariant (§9.5) |
| `@no_alloc` | fn, test | the function and everything it calls must not allocate (§10.7) |
| `@allocates` | fn | marks an allocating primitive; used by the standard library (§10.7) |
| `@append_only` | `mut self` method | unsafe promise: does not invalidate existing views of the receiver (§5.4.2) |
| `@pure` | fn | no `mut` params, no `Atomic`/`Channel` access, no I/O, no `extern` calls; checked (**E0809**) |
| `@inline`, `@no_inline` | fn | inlining requirement / prohibition |
| `@fast_math` | fn | allow FMA contraction, reassociation, no-NaN/Inf assumptions (§6.4.4) |
| `@simd` | `for` loop | the loop must be vectorized, or compilation fails (§10.6.4) |
| `@gpu_kernel(workgroup: n)` | fn | GPU/CPU compute kernel (§11.2) |
| `@gpu_vertex`, `@gpu_fragment`, `@gpu_task(workgroup)`, `@gpu_mesh(workgroup, max_vertices, max_primitives)`, `@gpu_ray_gen`, `@gpu_miss`, `@gpu_closest_hit`, `@gpu_any_hit`, `@gpu_intersection` | fn | graphics and ray-tracing stages (§11.1.1, §11.3–11.5) |
| `@position`, `@flat`, `@linear`, `@target(n)`, `@depth` | field of a varyings/output struct | stage interface (§11.3) |
| `@instance`, `@task_payload`, `@per_primitive` | stage parameter | per-instance input / task payload / per-primitive fragment input (§11.3–11.4) |
| `@primitive_id`, `@layer`, `@viewport_index`, `@cull_primitive` | field of a mesh per-primitive struct | primitive builtins (§11.4.3) |
| `@export(name?)` | pub fn | export with C ABI under `name` (§12.6) |
| `@unsafe` | fn | callers must use `unsafe` (§12.1) |
| `@workgroup` | `let` in compute, task or mesh stage | workgroup-shared variable (§11.1.4) |
| `@link(name)` | extern block | link against library `name` (§12.6) |
| `@deprecated(msg)` | any item | warning **W0802** on use |
| `@doc_hidden` | any item | omit from `pyro doc` |
| `@allow(code)`, `@deny(code)` | any item | adjust a warning's level for that item |
