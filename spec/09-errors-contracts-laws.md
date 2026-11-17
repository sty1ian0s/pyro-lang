# 9. Errors, Traps, Contracts and Laws

Pyro handles failure in three tiers:

1. **Recoverable errors** are values: `Result<T, E>` and `Option<T>`. They are
   propagated explicitly with `?`.
2. **Bugs** (broken assumptions) **trap**: the program stops immediately with a
   diagnostic. Traps cannot be caught.
3. **Specifications**: contracts (`@requires`, `@ensures`, `@invariant`) and laws
   (`@law`) state what correct code must satisfy. They are checked by the compiler, at
   runtime in checked builds, and by `pyro test`.

There are no exceptions, no stack unwinding and no hidden error paths.

## 9.1 `Result` and `Option`

```pyro
pub enum Result<T, E> { ok(T), err(E) }
pub enum Option<T> { some(T), none }
```

Both are ordinary prelude enums (§14.1). Errors are usually payload-free or small
payload enums:

```pyro
pub enum ConfigError { missing_key(u64), bad_value(u64), io(fs.IoError) }
impl From<fs.IoError> for ConfigError { fn from(e: fs.IoError) -> Self { .io(e) } }

pub fn load(path: str, mut buf: []u8) -> Result<Config, ConfigError> {
    let n = fs.read_into(path, mut buf)?;           // IoError converts via From
    guard let .some(port) = parse_u16(buf[..n]) else {
        return .err(.bad_value(@hash("port")));
    }
    return .ok(Config { port });
}
```

### 9.1.1 Must-use rule

An expression statement whose type is `Result<T, E>` is an error (**E0603**). Handle it
with `?`, `match`, `if let`, or discard it explicitly with `_ = expr;`. Discarding an
`Option` or any other value is allowed.

### 9.1.2 Propagation

`?` is defined by desugaring (§6.12.1). It is the only implicit control flow in
expressions, and it is marked by a visible operator.

## 9.2 Deferred handling: `@todo_err`

`@todo_err(e)` takes `e: Result<T, E>` and evaluates to the `T` in `.ok`. On `.err(x)` it
**traps** with `unhandled error at <location>`, plus `x` formatted if `E` implements
`std.fmt.Debug`. It marks code where error handling has not been written yet:

- every use produces warning **W0601**;
- in an environment with `allow_todo_err = false` (the default for `prod`, §13.3), every
  use is an error (**E0604**). Unfinished error handling cannot ship.

## 9.3 Assertions

`assert(cond, msg)` (prelude, §14.1) traps with `msg` when `cond` is false. Assertions
are checked in **all** builds. For checks that should exist only in checked builds, use:

```pyro
comptime if @env_or("debug_assertions", false) { assert(expensive_invariant(xs), "..."); }
```

## 9.4 Traps

A **trap** ends the program immediately:

1. It writes a diagnostic to the process's standard error, or to the trap handler's
   sink on freestanding targets. The diagnostic contains the trap kind, the message, the
   source location, and in checked builds a symbolized stack trace.
2. It terminates the process with exit status 134 on hosted targets. On freestanding
   targets it calls the package's trap handler.

`defer` and `errdefer` blocks do **not** run on a trap. A trap in any task of a
`nursery`, a `parallel_for` body or a GPU-fallback kernel terminates the whole process.
There is no recovery mechanism inside a process. Fault isolation is done with child
processes (`std.process.Command`, §14.7).

**Freestanding trap handler.** A `no_std` package must provide exactly one function:

```pyro
@trap_handler
pub fn on_trap(kind: TrapKind, msg: str, file: str, line: u32) -> noreturn { ... }
```

(**E0605** if it is missing or duplicated.) Hosted packages may provide one to override
the default output. It must still not return.

`TrapKind` is a prelude enum: `bounds`, `overflow`, `div_zero`, `shift`, `assert`,
`todo_err`, `contract`, `unreachable`, `explicit`, `stack_overflow`, `capacity`,
`deadlock`, `out_of_memory`, `ray_recursion`, `gpu_limit` (§11.7).

**Allocation failure.** When the general-purpose allocator cannot satisfy a request
made by a standard container, the program traps with kind `out_of_memory`. Code that
must survive allocation failure uses the `try_` variants of growing operations, which
return `Result<_, AllocError>` (§14.3).

## 9.5 Contracts

Contracts are attributes on functions and structs:

```pyro
@requires(lo <= hi, "range is inverted")
@ensures(result >= lo && result <= hi)
pub fn clamp(x: i32, lo: i32, hi: i32) -> i32 { ... }

@invariant(self.len <= CAP)
pub struct Stack<T, CAP: usize> {
    items: [CAP]T,
    len: usize = 0,

    @requires(self.len < CAP, "stack is full")
    @ensures(self.len == @old(self.len) + 1)
    pub fn push(mut self, item: T) { self.items[self.len] = item; self.len += 1; }
}
```

### 9.5.1 Contract expressions

- A contract condition is a `bool` expression. It may use the function's parameters,
  `self`, constants and `@pure` functions. In `@ensures` it may also use `result` (the
  return value) and `@old(e)`, the value of `e` on entry, which must be a plain type.
- A contract must not write anything, call functions with `mut` parameters, or move
  resources (**E0702**).
- `msg` is an optional comptime `str`.

### 9.5.2 When contracts are checked

| Contract | Checked |
|----------|---------|
| `@requires` | on entry, before the body |
| `@ensures` | at every normal return, after defers have run, with `result` bound |
| `@invariant(c)` on struct `T` | when any `pub` function **of `T`'s module** returns, for every `T` reachable as a `mut`/`mut self` argument or as the returned value. Private functions may break the invariant temporarily |

### 9.5.3 Enforcement levels

1. **Compile time (always).** If every input of a contract condition is comptime-known at
   a call site and the condition evaluates to `false`, the call is an error
   (**E0701**).
2. **Runtime.** When the build environment has `contracts = true` (default for `dev` and
   `test`, §13.3), each contract is checked as above. A failure **traps** with kind
   `contract`, the message and the failing expression's source text.
3. With `contracts = false` (default for `prod`), runtime contract checks are not
   compiled. The compiler must not assume a contract holds when it is not checked:
   contracts are never optimization assumptions.

Implementations may omit a runtime check that they prove always holds.

## 9.6 Laws

A **law** states a property that must hold for all inputs, in the spirit of algebraic
laws in Bend and property-based testing:

```pyro
@law
fn encode_roundtrip(p: PacketHeader) -> bool {
    decode(encode(p)) == .ok(p)
}

@law(cases: 5000)
fn sort_is_ordered(xs: Bounded<i32, 128>) -> bool {
    let mut sorted = xs;
    sorted.sort();
    let ys = sorted;                       // immutable: the loop below only reads
    for y, i in ys where i > 0 { if ys[i - 1] > y { return false; } }
    true
}
```

### 9.6.1 Rules

- A law is a function marked `@law` that returns `bool`. Its parameters must have no
  mode and types implementing `std.testing.Arbitrary` (**E0703**). The standard library
  implements `Arbitrary` for primitives, `vec`, `Handle`, `Bounded<T, N>`, `[N]T`, and,
  via comptime derivation, for every plain struct, tuple and enum whose parts are
  `Arbitrary`.
- Laws must not be called by non-test code (**E0704**). They are never compiled into
  non-test builds.

### 9.6.2 Verification by `pyro test`

For each law, `pyro test`:

1. **Exhaustive proof.** If the product of the parameter domain sizes is at most 2²⁰
   (for example two `u8`s, or a `bool` and an enum), it evaluates the law for every
   input. If all hold, the law is reported as **proved**.
2. **Edge cases.** Otherwise it first runs `Arbitrary.edge_cases()`. For integers: 0, 1,
   −1, MIN, MAX, MIN+1, MAX−1. For floats: ±0, ±1, NaN, ±Inf, smallest subnormal, MAX.
   For collections: lengths 0, 1, 7, 8, 15, 16, 63, 64 and 65, which exercise SIMD tail
   handling. Combinations are taken pairwise, not as a full cross product.
3. **Random cases.** It then runs `cases` random inputs (default 1000) from a seeded
   generator. The seed is printed and can be replayed with `pyro test --seed <n>`.
4. **Shrinking.** On failure it shrinks the counterexample (integers toward 0, floats
   toward simpler values, collections toward shorter) and reports the smallest failing
   input. The run fails.

A law that evaluates `false`, traps, or exceeds 1 second on a single input fails.

### 9.6.3 Laws and optimization

Laws are **never** used as optimization assumptions. A tested law is evidence, not
proof, and treating it as an axiom would make a wrong law silently miscompile code. To
let the optimizer reorder floating-point reductions, use `@fast_math` or the explicit
reduction builtins (§10.6.3).

### 9.6.4 CPU/GPU equivalence laws

Laws may call `@gpu_kernel` functions through `launch cpu` and `launch gpu` (§11.2.3). This
is the recommended way to state that a kernel's GPU and CPU results agree within a
tolerance:

```pyro
@law(cases: 200)
fn integrate_cpu_gpu_agree(ps: [256]Particle) -> bool {   // Particle is @soa
    let mut a = ps;
    let mut b = ps;
    launch cpu integrate(mut a, 0.016);
    launch gpu integrate(mut b, 0.016);
    for p, i in a { if math.abs(p.x - b[i].x) > 1e-5 { return false; } }
    true
}
```

## 9.7 Contracts versus tests (informative)

Contracts catch misuse at function boundaries and state corruption, close to the cause.
Laws catch classes of bugs that example-based tests miss: round-trips, ordering,
SIMD tail lengths, CPU/GPU divergence. Neither checks whether the specification itself
matches what users need. `@test` functions (§13.6) and integration tests are still
required for that.
