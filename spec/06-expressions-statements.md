# 6. Expressions and Statements

## 6.1 Evaluation order

- Operands, call arguments, array elements, tuple elements and struct-literal fields
  are evaluated **left to right, in source order**. For struct literals this means the
  order of the `field_init`s as written, not declaration order.
- In an assignment `place op= value`, the place's sub-expressions (indices, receivers)
  are evaluated first, then `value`, then the store happens.
- `&&` and `||` evaluate their right operand only when needed.
- A trap (§9.4) aborts evaluation immediately.

## 6.2 Literals and constructors

### 6.2.1 Struct literals

`Path { f1: e1, f2: e2 }` constructs the struct named by `Path`. Naming a field twice is
an error (**E0351**). `x` alone is shorthand for `x: x`.

- **Without `..`**, every field must be listed, including fields that have defaults
  (**E0340**). Adding a field to a struct therefore turns every such construction site
  into a compile error that names the new field. Nothing gets a value silently.
- **With the rest marker `..`** (`Player { health: 80, .. }`), unlisted fields take their
  declared defaults (`field: T = expr`), evaluated at the construction site. An
  unlisted field without a default is still an error (**E0340**). A site with `..`
  deliberately accepts future defaulted fields.

`pyro lsp` offers a code action that expands `..` into the explicit field list, and
the reverse.

Outside the defining module, a literal may name only fields declared `pub mut`. A
struct with any field that is not `pub mut` and has no default cannot be constructed
outside its module (**E0352**). This is how parse-don't-validate domain types are made
(§7.3.3).

### 6.2.2 Anonymous literals `.{ ... }`

`.{ f: e, ... }` (optionally ending in `..`, as in §6.2.1) is a struct literal whose
type is the **expected type** at that point
(annotation, parameter type, field type, return type). Without an expected type it is an
error (**E0350**). With positional elements (`.{ a, b }`) it constructs a tuple or `vec`
of the expected type (§3.8 element rules). When the expected type is a generic type
parameter still being inferred, or there is no expected type, a positional literal
forms a **tuple of its elements' types**. A literal of types (`.{ Position, Velocity }`)
is a comptime tuple of `type` values. A named literal still requires an expected type.

### 6.2.3 Inferred members `.name`

`.name` and `.name(args)` are resolved in the expected type `T` in this order:

1. an enum variant of `T` (`.idle`, `.some(x)`, `.ok()`);
2. a `const` member of `T` whose type is `T` (`.ZERO`, `.IDENTITY`);
3. a function member of `T` without `self` whose return type is `T`, `Option<T>` or
   `Result<T, E>` (`.init()`, `.from_bytes(b)`).

For the operands of a binary operator, the type of the other operand is the expected
type: `state == .playing`, `r.pop() == .some(2)`.

If the expected type is `Option<U>` and steps 1–3 find no member of `Option`, the
lookup is repeated in `U`, and the result is wrapped in `.some` (§4.9.1 rule 8). The
same applies to `FieldId<T>` (§8.4.1), so `sorted_by: .threat_level` works where an
`Option<FieldId<T>>` is expected. Without an expected type, or with no match, it is an
error (**E0353**).

```pyro
let mut state: GameState = .playing;
let mut pool: Pool<Particle> = .init();
let target: Option<Handle<Particle>> = .none;
```

### 6.2.4 Arrays

- `[a, b, c]` has type `[3]T`, where `T` is the expected element type, or else the type
  of `a`. All elements convert to `T`.
- `[v; N]` repeats the plain value `v` `N` times. `N` must be comptime.
- `[]` is an empty array `[0]T`. It requires an expected type.

### 6.2.5 Comprehensions

`[e for p in src where cond]` fills a destination **without allocating**. It may only
appear as:

1. the initializer or assigned value for a destination of type `[N]T`. `where` is not
   allowed (**E0354**). The source must have exactly `N` elements: checked at compile
   time when the length is comptime, otherwise it traps;
2. the initializer or assigned value for a destination of type `Bounded<T, N>` (§14.4.5),
   with or without `where`. Overflowing `N` traps;
3. an argument to a parameter of type `Bounded<T, N>` or `[N]T`, with the same rules.

Anywhere else it is an error (**E0354**). The expansion is a plain loop (§6.12.6).

```pyro
let doubled: [4]f32 = [x * 2.0 for x in quad];
let mut fast: Bounded<f32, 256> = [v for v in particles.vx where v > 10.0];
```

### 6.2.6 Tuples

`(a, b)` constructs a tuple. A single parenthesized expression `(a)` is just grouping.
Tuples are destructured with patterns: `let (q, r) = divmod(a, b);`.

## 6.3 Names, fields and methods

### 6.3.1 Name lookup

An unqualified identifier is resolved in this order: local bindings (innermost scope
first), then items of the current module (including `use` imports), then the prelude
(§14.1). Name resolution is independent of types (§7.10). A local that shadows another
local is allowed. A local that shadows a module item, or a prelude name that is not a
type or intrinsic, gets warning **W0301**. Shadowing prelude types and intrinsics is
**E0301** (§4.1).

### 6.3.2 Field access

`e.f` accesses field `f` of a struct value, view or SoA element proxy. On a SoA array or
slice, `e.f` is the column view (§4.4.2). Tuple fields are `e.0`, `e.1`, …. Private
fields are visible only inside the defining module (§7.3.3).

### 6.3.3 Method calls and UFCS

`e.m(args)` resolves `m` in this order:

1. a function member named `m` declared in the body of `e`'s type (§7.3), or in an
   `impl P for T` where both `P` and `T` are nameable at the call site (§7.9);
2. **UFCS:** a free function `m` visible by name lookup (§6.3.1) whose first parameter
   accepts `e`. The call is then `m(e, args)`, with `e` passed according to that
   parameter's mode, and no call-site marker needed for it.

If both 1 and 2 apply, step 1 wins. If two protocol `impl`s provide `m`, that is an
error (**E0355**), and the caller must write `Protocol.m(e, args)`.

A member function with no `self` is called on the type: `Arena.init()`,
`Particle.default()`, or via an inferred member (§6.2.3).

## 6.4 Operators

### 6.4.1 Operand types

- Arithmetic `+ - * / %`: both operands have the same numeric or `vec` type after
  implicit conversions (§4.9.1). A scalar paired with a `vec` is broadcast. A mismatch
  is an error (**E0310**).
- Bitwise `& | ^ ~ << >>`: integer types and integer/bool vecs. For shifts the right
  operand may be any unsigned integer type.
- Logical `! && ||`: `bool`. `!` also applies to `mask<N>`.
- Comparison: `== !=` are defined for primitives, `str`, handles, payload-free enums,
  pointers, and field-wise for plain structs, tuples, arrays and enums whose parts all
  support `==`. `< > <= >=` are defined for integers, floats, `str` (byte-wise
  lexicographic) and payload-free enums (by discriminant). On `vec`s, comparisons are
  lane-wise and produce `mask<N>`.
- There is no operator overloading. Generic numeric code uses the `std.ops.Num`
  protocol (§14.2) through explicit method calls.

### 6.4.2 Integer overflow

For `+ - *`, unary `-`, and `as`-free arithmetic on `uN`/`iN`:

- **checked build** (`debug_assertions = true`): a result outside the type's range
  **traps** (`integer overflow`);
- **unchecked build**: the result wraps modulo 2ᴺ.

Explicit behaviour that is the same in every build is available through builtins:
`@add_wrap`, `@sub_wrap`, `@mul_wrap`, `@add_sat`, `@sub_sat`, `@mul_sat`, and
`@add_checked`/`@sub_checked`/`@mul_checked`, which return `Option<T>` (§8.7).

### 6.4.3 Division and shifts

- Integer `/` and `%` by zero **trap** in every build. `iN.MIN / -1` traps in checked
  builds and wraps otherwise.
- `%` takes the sign of the dividend (truncated division).
- `x << n` and `x >> n` with `n ≥ N` (the bit width) trap in checked builds. In
  unchecked builds `n` is reduced modulo N. `>>` is arithmetic on signed types and
  logical on unsigned types.

### 6.4.4 Floating point

Operations follow IEEE 754 with round-to-nearest-even. The compiler must not contract
`a * b + c` into a fused multiply-add, reassociate, or assume the absence of NaN/Inf,
unless the enclosing function has `@fast_math` (§8.8) or the code calls `@fma`
explicitly. Float division by zero produces ±Inf or NaN and does not trap.

## 6.5 Indexing, slicing, ranges

### 6.5.1 Ranges

`a..b` (half-open) and `a..=b` (closed) have type `Range<T>` / `RangeInclusive<T>`
(§14.1), where `T` is an integer type. They are plain values. If both bounds are
untyped constants and there is no expected type, `T` is `usize` (ranges are mostly
used for indexing). An open end (`a..`, `..b`,
`..`) is allowed only inside index brackets.

### 6.5.2 Indexing

`e[i]` requires `i: usize` (an untyped constant converts). It is defined for arrays,
slices, SoA arrays and slices, `vec`s, `str` (yields `u8`), and types implementing
`Indexable` (§14.2).

### 6.5.3 Bounds checks

Every index and slice operation is bounds-checked and **traps** on failure, in every
build mode. Implementations should remove checks they can prove redundant, for example
in `for i in 0..xs.len()` loops that only index `xs[i]`. Removing a check that can fail
is non-conforming. To skip checks explicitly, use the `unsafe` accessors in §12.3.

### 6.5.4 Slicing

`e[a..b]` is a view of elements `a` up to (not including) `b`. It traps unless
`a ≤ b ≤ len`. The view is mutable if `e` is a mutable place or mutable view, and
read-only otherwise. `e[a..]`, `e[..b]` and `e[..]` default the missing bound to 0 and `len`.
Slicing a SoA value yields `soa []T`. Slicing a `str` traps if a bound is not on a UTF-8
character boundary.

## 6.6 Conditionals

### 6.6.1 `if`

`if cond { a } else { b }` evaluates to `a` or `b`, which must have a common type. Without
`else`, the then-block must have type `void` (or `noreturn`), and so does the whole
expression. `cond` must be `bool` (**E0310**). Pyro has no truthiness.

### 6.6.2 `if let`, `while let`, `guard let`

- `if let P = e { A } else { B }` evaluates `e`. If it matches the refutable pattern
  `P`, it runs `A` with `P`'s bindings, otherwise `B`.
- `while let P = e { A }` repeats while `e` matches `P`.
- `guard let P = e else { B }` evaluates `e`. If it does not match, it runs `B`, which
  must have type `noreturn`, i.e. end in `return`, `break`, `continue` or a trap
  (**E0356**). If it matches, `P`'s bindings are in scope for the **rest of the
  enclosing block**.
- Bindings follow the `match` binding rules below (§6.6.3).

```pyro
fn process_chunk(chunks: Pool<Chunk>, h: Handle<Chunk>) {
    guard let .some(data) = chunks.get(h) else { return; }
    mesh(data);
}
```

### 6.6.3 `match`

`match e { P1 => a, P2 if g => b, _ => c }` tests arms top to bottom and evaluates the
first arm whose pattern matches and whose guard (if any) is `true`.

- **Exhaustiveness.** The arms together must cover every value of `e`'s type
  (**E0357**). Guards count as possibly failing. Integer types need a `_` or binding arm
  unless every value is listed (feasible for small `uN`).
- **Unreachable arms** get warning **W0302**.
- **Bindings.** If `e` is a place of plain type, bindings are copies. If `e` is a
  mutable place and the pattern binds `mut x`, then `x` is a `mut` view of that part of
  `e`. A payload of type `mut T` binds as a mutable view (§5.5.3). If `e` is a place of
  view or resource type, bindings are read-only views and nothing moves. If the
  scrutinee is `move x` or a resource temporary, resource payloads move into the
  bindings, which must be consumed in that arm (§5.3.3).
- All arm results must have a common type.

## 6.7 Loops

### 6.7.1 `loop`, `while`

`loop { ... }` repeats until `break`. `break v` makes the `loop` expression evaluate to
`v`. All `break`s of one `loop` must agree on the type. A `loop` without a value-carrying
`break` has type `void`, or `noreturn` if it has no `break` at all. `while c { ... }`
checks `c` before each iteration and has type `void`.

### 6.7.2 `for`

```
for x in iterable { body }
for x, i in iterable { body }          // i: usize is the element index
for x in iterable where cond { body }  // skips elements where cond is false
```

The iterable must be one of:

| Iterable | Element binding `x` |
|----------|---------------------|
| `Range<T>`, `RangeInclusive<T>`, `StepRange<T>`, `RevRange<T>` | `T` value |
| `[N]T`, `[]T` | `T` copy if the iterable is immutable; `mut T` view if it is a mutable place or mutable view |
| `soa [N]T`, `soa []T` | element proxy: reads gather fields, writes (`x.f = …`) go to columns; mutable under the same rule |
| a type implementing `Indexable<E>` (§14.2): containers, `chunks(n)` (yields `[]T`), `chunks_mut(n)` (yields `mut []T` with disjoint sub-origins, §5.4.4) | `E` via `at(i)`; `mut E` via `at_mut(i)` if it also implements `IndexableMut<E>`, under the same rule |

No `mut` is written on the loop variable. Its mutability comes from the iterable, so
`for p in particles { p.x += p.vx * dt; }` mutates `particles` exactly when `particles`
is mutable.

The iterable is evaluated once. Its length is read once before the first iteration. The
iterable is a live view for the whole loop (§5.4.2), so the body cannot change the
collection's length or move it (**E0332**). Element writes go through `x`.

### 6.7.3 `inline for`

`inline for x in E { body }` requires `E` to be comptime-known: a comptime array,
slice or tuple, a range with comptime bounds, or a comptime value such as
`std.meta.fields(T)` (a comptime `[]FieldInfo`). The loop is unrolled at
compile time, and `x` is a comptime value in each copy. Each copy of the body is
type-checked separately. `break` and `continue` are allowed and act on the unrolled
sequence.

### 6.7.4 Labels

`outer: for ... { for ... { break :outer; } }`: `break :label` / `continue :label` target
the labelled loop.

## 6.8 `defer` and `errdefer`

### 6.8.1 `defer`

`defer S` registers `S` (a block or expression statement) to run when control leaves the
enclosing block by any route: end of block, `return`, `break`, `continue`, or `?`. Defers
run in reverse registration order (LIFO). A `defer` registered inside a loop body runs
at the end of each iteration. Traps do not run defers.

`S` must not contain `return`, `break`, `continue`, `?` or `guard` that would leave `S`
(**E0360**). `S` must not register further defers.

### 6.8.2 `errdefer`

`errdefer S` is like `defer`, but `S` runs only when the enclosing **function** returns
an `.err(..)` value. This covers both `return .err(e)` and a `?` that propagates an
error. The function must return `Result<T, E>` (**E0362**). On a successful return,
pending `errdefer`s are discarded. For the resource rules (§5.3.3), an `errdefer x.f()`
that consumes `x` counts as consumption on error paths only.

## 6.9 Functions, calls and tail calls

- **Argument binding.** Positional arguments bind in order, then named arguments by name
  (§7.2.4). Missing parameters take their default values, evaluated at the call site in
  parameter order after the explicit arguments.
- **`return tail f(args);`** The call must be in tail position, and `f`'s return type
  must equal the current function's. The implementation must reuse the current stack
  frame. If it cannot (for example because a `defer` or `errdefer` is pending, or a
  view argument refers to the current frame's locals), compilation fails (**E0363**).
  Without `tail`, no tail-call elimination is promised.
- Recursion is allowed. Stack overflow **traps** (guard pages or stack probes are
  required on hosted targets).

## 6.10 Lambdas

`|a, b| expr` is an anonymous function. Parameter types may be omitted when the expected
type is a function type. Lambdas have no name and no `self`.

- A lambda that **captures nothing** may be converted to a function pointer
  `fn(A) -> R` and stored or passed anywhere.
- A lambda that **captures** local variables may only be passed directly as an argument
  to a `comptime` parameter of function type (§8.2). The callee is then instantiated for
  that lambda, and the lambda body is inlined. Captures are read-only views of the
  captured locals. Writing to a captured variable is an error (**E0361**). Storing,
  returning or converting a capturing lambda is an error (**E0330**).

Lambdas never allocate.

## 6.11 Blocks and statement values

A block `{ s1; s2; e }` evaluates its statements in order and takes the value of the
final expression `e`. Without a final expression its type is `void`, or `noreturn` if it
always diverges. A `comptime { ... }` block is evaluated by the compiler (chapter 8), and
its value becomes a constant. An `unsafe { ... }` block enables the operations of
chapter 12.

### 6.11.1 Discard

`_ = e;` evaluates `e` and drops the value. It is the way to ignore a `Result`
(§9.1.1). It is an error if `e` has resource type (**E0327**).

## 6.12 Normative desugarings

Every construct below is defined by its expansion into simpler Pyro. `pyro build
--expand` (§13.7) prints these expansions. Fresh names (`__t1`, …) cannot collide with
user names.

### 6.12.1 `?`

Inside a function returning `Result<U, F>`, with `e: Result<T, E>`:

```
e?   ⇒   match e { .ok(__v) => __v, .err(__e) => return .err(F.from(__e)), }
```

`F.from` is required only when `E ≠ F`, and then `F` must implement `From<E>` (§14.2),
otherwise **E0601**. With `e: Option<T>` inside a function returning `Option<U>`:
`.none => return .none`. Using `?` in a function that returns something else is
**E0602**.

### 6.12.2 `if let` / `guard let` / `while let`

```
if let P = e { A } else { B }   ⇒  match e { P => { A }, _ => { B }, }
guard let P = e else { B }; R   ⇒  match e { P => { R }, _ => { B }, }   // R = rest of block
while let P = e { A }           ⇒  loop { match e { P => { A }, _ => break, } }
```

### 6.12.3 `for` over ranges and arrays

```
for x, i in xs { B }    ⇒   { let __s = xs[..]; let __n: usize = __s.len();
                              let mut i: usize = 0;
                              while i < __n { let x = __s[i]; B'; i += 1; } }
```

When `xs` is mutable, the binding is `let x: mut T = __s[i];` (a mutable view, §5.5.3).
`B'` is `B` with every `continue` targeting this loop replaced by `{ i += 1; continue; }`. For a range `a..b`, `x` takes the values `a, a+1, …, b−1` without
overflow: the loop stops before computing `b`.

For an `Indexable` iterable that is a place `c` (containers), the expansion uses the
place directly instead of `__s`: `let __n = c.len(); … let x = c.at(i);` (or
`let x: mut E = c.at_mut(i);`).

### 6.12.4 `for` over SoA

```
for p in ps { B }   ⇒   { let __s = ps[..]; let __n: usize = __s.len(); let mut __i: usize = 0;
                          while __i < __n { let p: mut T = __s[__i]; B'; __i += 1; } }
```

(`let p = __s[__i];` when `ps` is immutable.) `p` is an element proxy (§4.4.2), so
`p.f` reads and writes column `f` at index `__i`. Implementations lower `p.f` directly
to `__s.f[__i]`. Reading `p` as a whole value gathers all columns. Assigning `p = v`
scatters into all columns. `B'` is as in §6.12.3.

### 6.12.5 `where`

```
for x in xs where C { B }   ⇒   for x in xs { if !(C) { continue; } B }
```

When the body is vectorized (§10.6.4) the implementation may evaluate `C` as a lane mask
and use masked stores. Observable behaviour must equal the expansion above.

### 6.12.6 Comprehensions

```
let mut out: Bounded<T, N> = [e for x in xs where C];
    ⇒  let mut out: Bounded<T, N> = .empty();
       for x in xs where C { out.push(e); }          // push traps when full

let out: [N]T = [e for x in xs];
    ⇒  let __s = xs[..]; assert(__s.len() == N, "comprehension length mismatch");
       let mut out: [N]T = [@zero(T); N];            // @zero: §8.7
       for x, __i in __s { out[__i] = e; }
```

### 6.12.7 Defaults and named arguments

```
f(a, z: c)   where fn f(x: X, y: Y = dy, z: Z)   ⇒   { let __x = a; let __z = c; f(__x, dy, __z) }
```

Explicit arguments are evaluated left to right in source order before any default.

## 6.13 Traps raised by expressions (summary)

| Condition | Build modes |
|-----------|-------------|
| index or slice out of bounds | all |
| integer division or remainder by zero | all |
| integer overflow, invalid shift amount | checked builds |
| comprehension length mismatch or overflow | all |
| `Bounded.push` when full, `assert` failure | all |
| `@todo_err` on an error value | all (§9.2) |
| failed contract check | when contracts are enabled (§9.5) |
| stack overflow | all |
| `@trap`, `@unreachable` reached | all |
