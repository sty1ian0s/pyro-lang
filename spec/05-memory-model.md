# 5. Memory Model and Safety

Pyro gets memory safety from four mechanisms. None of them needs lifetime annotations.

1. **Value semantics.** Every variable owns its storage. Assignment copies plain data.
2. **Explicit resources.** A value that owns heap memory or an OS object must be moved or
   released explicitly. The compiler checks that it is consumed exactly once (§5.3).
3. **Local views.** References that do not own their storage (slices, `str`, `mut`
   parameters, element proxies) cannot be stored long-term. They are checked inside one
   function by a simple exclusivity rule (§5.4).
4. **Generational handles.** Long-lived relationships between objects use `Handle<T>`.
   A handle is checked on every lookup and cannot dangle (§5.7).

## 5.1 Kinds of types

Every type is exactly one of:

| Kind | Definition | May be copied | Must be consumed | May be stored anywhere |
|------|------------|---------------|------------------|------------------------|
| **plain** | contains no resource and no view | yes, implicitly | no | yes |
| **resource** | marked `@resource`, or has a resource field or payload | no, only `move` | yes, exactly once | yes, except views can't be inside |
| **shared cell** | `Atomic<T>`, and fixed arrays of it | no | no | yes; used through read-only views (§10.5) |
| **view** | `[]T`, `soa []T`, `str`, a `-> mut T` result, or any type with a view inside | yes (copies the reference) | no | no, see §5.4.1 |

A type cannot contain both a resource and a view (**E0330**). A struct that contains a
shared cell is itself a shared cell (unless it also contains a resource, in which case it
is a resource). Using a shared-cell place as a value (copy) is an error (**E0328**).
Passing it to a read-only parameter passes a view.

GPU-local types (`gpu.RayQuery`, `gpu.MeshOut`) exist only inside GPU stage code and
follow the restrictions in §11.1.3.

The kind of a generic type is computed after instantiation. `Option<[]u8>` is a view type
and `Option<u32>` is plain.

## 5.2 Plain types

Primitives, vectors, handles, raw pointers, function pointers, and arrays, tuples,
structs and enums made only of plain types are plain. Using a plain value copies its
bits. Plain values never need cleanup.

## 5.3 Resource types

### 5.3.1 Declaring resources

A struct marked `@resource` is a resource type. So is any struct with a field of resource
type. Standard-library examples: `Arena`, `List<T>`, `Pool<T>`, `Table`, `Map<K, V>`,
`Channel<T, N>`, `fs.File`, `gpu.Buffer<T>`.

```pyro
@resource
pub struct File {
    fd: i32,
    pub fn close(move self) { unsafe { sys.close(self.fd); } }
}
```

Resource types may appear in locals, parameters, return values, struct fields, tuples
and enum payloads (so `Result<File, IoError>` is a resource). They may **not** be
elements of fixed arrays or of standard containers (**E0325**). Model ownership of many resources with a container of plain
data plus handles. This is the data-oriented approach and keeps destruction order
explicit.

### 5.3.2 Moving

- A resource value is transferred with `move place`. `place` must be a local variable
  or a `move` parameter (**E0321**). A resource-typed *temporary* (a call result, a
  literal) is moved implicitly and needs no `move`. To take a resource out of a field, use
  `std.mem.replace(mut place, move new_value)`, which returns the old value.
- Without `move`, using a resource place as a value is an error (**E0320**). The only
  exception is `return x;` where `x` is a local or `move` parameter: returning moves
  implicitly, because the variable ends there anyway.
- Passing a resource to a parameter without a mode passes a **read-only view** of it.
  Passing it to a `mut` parameter passes a mutable view. Neither moves it.

### 5.3.3 Consumption

Every resource-typed local variable and `move` parameter must be **consumed** exactly
once on every path out of its scope. Consumption is one of:

- `move x` (into a call argument, a `let`, a struct field, a `return`, a `spawn`);
- calling a method that takes `move self` (`x.deinit()`, `f.close()`);
- an implicit-move `return x;`;
- a pending `defer` that consumes `x` (runs at scope exit, §6.8.1);
- destructuring with `let S { a, b } = move x;`, which consumes `x` and creates new
  locals `a` and `b` that must each be consumed;
- matching with `match move x { … }` (or matching a resource temporary). This consumes
  `x`, and resource payloads are moved into the arm's bindings, which must be consumed
  in that arm.
- **Owner's release.** Inside the module that declares resource type `R`, a `move`
  parameter or local of type `R` counts as consumed at the end of its scope once all its
  resource fields have been consumed. If `R` has no resource fields, that is trivially
  true. This is how a base resource like `File` ends: its `close(move self)` simply
  returns. Outside the declaring module, this rule does not apply, so only the owner's
  API can destroy a resource.

Errors:

- not consumed on some path (**E0322**). The diagnostic suggests
  `defer x.deinit();`;
- used after consumption (**E0323**);
- consumed on one branch but not on another (**E0324**);
- a resource-typed temporary whose value is discarded, e.g. `make_list().len()`
  (**E0327**). Bind it first.

A `move self` method of a resource struct must consume every resource field of `self`
(**E0322**). Usually it does this by destructuring.

This is the whole ownership system. There is no implicit destructor: the code that
releases a resource is always visible at the point where it runs (`defer`/`errdefer`
put it at scope exit in source order, §6.8).

### 5.3.4 Intentional leaking

`std.mem.leak(move x)` consumes a resource without releasing it. Use it for
process-lifetime objects.

## 5.4 Views

A **view** is a non-owning reference. Its **origin** is the place that owns the
referenced storage, identified by a *root* (a local variable, a parameter, or `static`)
and a field path. Views are cheap to create: a slice is two words.

How views come into existence, and their origins:

| Expression | Result | Origin |
|------------|--------|--------|
| place `a` of type `[N]T` used as `[]T` | slice | `a` |
| `a[lo..hi]` | slice | origin of `a` (or `a` itself if `a` is a place) |
| `s.f` where `s: soa []T` or `soa [N]T` | column slice `[]F` | `s.f` |
| string literal, `const` array used as slice | slice / `str` | `static` |
| `for x in coll` over a slice/SoA/container | element proxy | `coll` |
| passing place `p` as a read-only or `mut` argument | view param | `p` |
| call returning a view type | view | union of the origins of all non-plain arguments (§5.4.3) |
| `arena.alloc_slice(T, n)` | slice | `arena` (from the rule above) |

### 5.4.1 Storage restriction (second-class views)

A value of view type may be held only in:

- local variables (`let`), parameters, function results (§5.4.3);
- fields of other view types, i.e. struct types that themselves contain a view field
  and are therefore view types;
- tuples and enum payloads, which then become view types.

It may **not** be stored in a `const`, a resource, an element of a standard container,
a channel message, or captured by a lambda passed to a non-`comptime` parameter
(**E0330**). Exception: views with `static` origin (string literals, `const` arrays)
may be stored in `const`s (§5.9).

Because views never outlive the function that created them, except by being returned to
a caller that owns the origin, dangling views are impossible.

### 5.4.2 Exclusivity rule

The compiler performs intraprocedural liveness analysis on view-typed values. A view is
**live** from its creation to its last use. A view passed to a `spawn` stays live until
the end of the enclosing `nursery` (§10.2).

Two places **overlap** if they have the same root and one field path is a prefix of the
other. `a.x` and `a.y` do not overlap. `a` and `a.x` do. Any two indexings of the same
array or slice (`a[i]`, `a[j]`) overlap, because indices are not compared. All bit fields
of one packed unit count as one place (§4.11.2).

An **access** to a place is a *read*, a *write* (assignment, compound assignment, being
passed as a `mut` argument or `mut self` receiver), or a *consume* (§5.3.3).

**Rule.** While a view with origin `O` is live, no access that conflicts with it may be
made to any place overlapping `O`, except through the view itself:

- a live **read-only** view conflicts with writes and consumes of `O`;
- a live **mutable** view conflicts with reads, writes and consumes of `O`.

Violation: **E0332**. The diagnostic shows where the view was created, the conflicting
access, and the view's later use that keeps it live.

Refinements:

- **Deferred statements** are analyzed at the points where they run (every exit of
  their scope, §6.8), not where they are written. So `defer arena.reset();` at the top
  of a function does not conflict with views used later in the body.
- **Append-only methods.** A call to a `mut self` method marked `@append_only` requires
  a mutable place, but it does **not** conflict with live views whose origin is the
  receiver (or part of it). The view it returns gets a fresh *sub-origin*
  `receiver.⟨k⟩`, disjoint from every other sub-origin. Writing through one arena slice
  therefore does not conflict with another, while `reset()` (an ordinary write of the
  whole receiver) overlaps all of them. Such a method may change only bookkeeping that
  no view can reach. It must never move,
  free or overwrite storage that existing views refer to. `Arena.alloc_slice` is the
  canonical example: allocating more does not disturb earlier allocations, so several
  arena slices may be live at once. Because the promise cannot be checked, applying
  `@append_only` is an unsafe assertion. It is allowed only on methods whose body
  contains an `unsafe` block (**E0342**), and breaking the promise is undefined
  behaviour. Growable containers such as `List.push` may reallocate and are therefore
  *not* append-only.

```pyro
fn bad(mut arena: Arena) {
    let mut tmp = arena.alloc_slice(u32, 64);   // view with origin `arena`
    arena.reset();                          // E0332: `arena` is written while `tmp` is live
    tmp[0] = 1;                             //   ... because `tmp` is used here
}
```

### 5.4.3 Views across calls

- **Arguments.** All arguments of one call are evaluated first, then are live together
  for the duration of the call. A `mut` argument must not overlap any other argument of
  the same call, including the receiver (**E0333**). Passing the same place to two
  read-only parameters is fine.
- **Results.** A call whose result type is a view has, as the result's origin, the union
  of the origins of every argument whose type is a view or resource, or that is passed
  as `mut`. Plain arguments contribute nothing.
- **Callee check.** Inside a function returning a view type, every returned value's
  origins must be parameters that are not `move` parameters, or `static`. Returning a
  view of a local, or of a `move` parameter, is an error (**E0331**).
- A result declared `-> mut T` may only be derived from `mut` parameters (**E0331**).

These rules are the only interprocedural assumptions the checker makes. No annotations
exist, and none are inferred across function boundaries.

### 5.4.4 Disjoint splitting

Indices are never compared, so mutating two parts of one array at the same time requires
functions that are defined to return disjoint views:

- `s.split_at_mut(i) -> (mut []T, mut []T)`
- `s.chunks_mut(n)`: an iterable of disjoint `mut []T` (§10.3)
- SoA columns `s.f` and `s.g` with different field names are separate places, so they
  are always disjoint.

Each view these functions produce gets a fresh sub-origin of the split place,
disjoint from its siblings, so they may be live and mutable at the same time. These
standard-library functions are implemented with `unsafe` code that guarantees
disjointness.

## 5.5 Mutability

### 5.5.1 Bindings

- `let x = e;` creates an **immutable** binding. Nothing reachable through `x` may be
  written: no assignment to `x`, its fields or elements, no `mut` argument, no
  `mut self` call (**E0337**).
- `let mut x = e;` creates a mutable binding.
- Mutability is deep and belongs to the binding, not the type. There are no "mutable
  types".

### 5.5.2 Parameter modes

| Declared as | Callee may | Caller writes | Caller's place |
|-------------|-----------|---------------|----------------|
| `x: T` | read `x` | `f(e)` | any expression; resources and views are passed as read-only views |
| `mut x: T` | read and write `x` in place | `f(mut p)` | must be a mutable place (**E0336**) |
| `move x: T` | own `x` and must consume it | `f(move v)` | a local or `move` parameter of resource type |
| `comptime x: T` | use `x` at compile time | `f(e)` | `e` must be comptime-known (**E0801**) |

- Writing to a parameter not declared `mut` is an error (**E0338**).
- Omitting `mut` at the call site for a `mut` parameter, or writing it for a non-`mut`
  parameter, is an error (**E0334**, **E0335**).
- `move` on a parameter of a concrete plain type is an error (**E0326**): plain values
  are always copied. In generic functions, a `move` parameter instantiated with a plain
  type simply copies.
- **Receivers** are exempt from call-site markers. `x.m()` passes `x` as `mut` if `m`
  declares `mut self`, and `x` must then be a mutable place. Method names carry the
  intent, and chaining stays clean.
- **In-place versus functional.** A function mutates its inputs in place exactly when it
  declares `mut` parameters. No other marker exists, and none is inferred. A function
  with no `mut` parameters cannot change any caller-visible state except through
  `Atomic` and `Channel` values (§10.4–10.5), `extern` calls, or raw pointers in
  `unsafe` code.

### 5.5.3 Binding views to locals

A local whose declared type is `mut T`, initialized from a mutable place (or a `mut T`
result), is a **mutable view** of that place, not a copy:

```pyro
let p: mut Particle = particles[i];   // p.x = 1.0 writes into particles
```

Without the `mut T` annotation, `let` copies a plain value or a view (a view copy refers
to the same storage). A resource place cannot be bound by `let` without `move`
(**E0320**). Refer to it through its own place instead. A pattern binding of an `Option<mut T>`/`Result<mut T, E>`
payload (`if let .some(p) = pool.get_mut(h)`), or of a tuple element of type `mut T`
(`for (pos, vel) in w.query(...)`), is a mutable view as well.

### 5.5.4 Chaining with `-> mut Self`

A method that mutates and wants to be chainable returns its receiver:

```pyro
pub fn filter_active(mut self) -> mut Self {
    self.items.retain(|p| p.active);
    return self;
}
pool.filter_active().sort_by_depth().normalize();
```

The result is a mutable view whose origin is the receiver (§5.4.3), so no copy is made.

## 5.6 Arenas

`Arena` (§14.3) is a resource that owns a growable region of memory. Its allocation
methods return views whose origin is the arena:

```pyro
fn frame(mut scratch: Arena, entities: soa []Entity) {
    defer scratch.reset();                       // runs at scope exit
    let mut grid = scratch.alloc_slice(i32, 4096);   // zero-initialized []i32
    grid.fill(-1);
    // ... use grid ...
}                                                // grid's last use is before reset
```

The allocation methods are `@append_only` (§5.4.2), so any number of allocations may
be live together. `reset()` and `deinit()` need ordinary `mut`/`move` access to the
arena. The exclusivity rule therefore guarantees that no view into the arena is still
live when it is reset or destroyed. The compiler needs no arena-specific rule.

Owning containers (`List`, `Pool`, `Table`, `Map`) never allocate from an arena. They
allocate from the thread's general-purpose allocator (§14.3). This is what lets them be
resources that live arbitrarily long.

## 5.7 Pools and handles

`Pool<T>` (§14.4) stores `T` values densely and hands out `Handle<T>` values.

- `pool.insert(value) -> Handle<T>` (needs `mut self`).
- `pool.get(h) -> Option<T>` (a copy) and `pool.get_mut(h) -> Option<mut T>` (a
  mutable view of the element, §4.5.3, bound as in §5.5.3). Both check that the handle's generation matches
  its slot. A stale or null handle yields
  `.none`. This check is part of the language-level safety guarantee and is never
  removed in any build mode.
- `pool.remove(h) -> bool` increments the slot's generation, so every copy of `h`
  becomes stale.
- When a slot's generation reaches `0xFFFF_FFFF`, the slot is retired permanently instead
  of wrapping. This rules out ABA collisions.

Handles are plain values. They can be stored anywhere, sent across threads and
serialized. A handle never keeps its target alive, and it can never reach freed memory.

## 5.8 Initialization

Every variable is initialized when declared. Struct literals must supply every field
without a default (**E0340**). `Arena.alloc_slice` and container growth zero-initialize
memory. Safe code cannot observe uninitialized memory. `unsafe` code can obtain it
explicitly (§12.4). Implementations should eliminate redundant zeroing.

## 5.9 Global state

Module-level declarations are `const` only (no mutable `static`s). A `const` is evaluated at compile time and
is immutable. Its type must be plain, `str`, an array or slice of plain values with static origin,
or a comptime-only type such as `type` or `FieldId<T>` (such consts are usable only in
comptime contexts) (**E0341**). Safe Pyro has no mutable global variables. Program state is
created in `main` and passed explicitly. This makes data flow visible and eliminates a
whole class of data races. `unsafe` code can reach mutable C globals through `extern`
(chapter 12).

## 5.10 Guarantees

For programs without `unsafe` blocks, a conforming implementation guarantees:

- no use-after-free, double free or dangling reference (§5.3, §5.4, §5.7);
- no out-of-bounds access: indexing traps instead (§6.5.3);
- no uninitialized reads (§5.8);
- no data races (§5.4, chapter 10);
- every resource is released exactly once, or explicitly leaked (§5.3.3);
- no null dereference: Pyro has no null references, and `Option` must be matched.

Not guaranteed: absence of deadlock in cyclic channel protocols (§10.4), absence of
logical errors, and absence of traps.
