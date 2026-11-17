# 7. Items, Generics and Modules

## 7.1 Items and visibility

Items are `use`, `const`, `type`, `fn`, `struct`, `enum`, `protocol`, `impl`, `extern`
blocks, and top-level `comptime` blocks. Inside a module, item order does not matter:
every item may refer to every other (§7.10).

Visibility has two levels:

- **private** (default): visible only inside the declaring module (file);
- **`pub`**: visible to every module that can name the declaring module, including other
  packages.

Struct fields additionally distinguish `pub` (readable outside) from `pub mut`
(readable and writable outside), §7.3.3.

## 7.2 Functions

### 7.2.1 Declaration

```pyro
pub fn clamp(x: f32, lo: f32 = 0.0, hi: f32 = 1.0) -> f32 {
    if x < lo { lo } else if x > hi { hi } else { x }
}
```

- Every parameter has an explicit type, except `self`.
- The return type defaults to `void`.
- The body's final expression, or a `return`, provides the result. Reaching the end of
  a non-`void` function without a value is an error (**E0371**).
- Parameter modes (`mut`, `move`, `comptime`) are described in §5.5.2.

### 7.2.2 `self`

Inside a struct, enum or `impl` body, a first parameter `self`, `mut self` or
`move self` makes the function a method. `self` has type `Self`, the enclosing type. A
member function without `self` is an associated function, called as `Type.f(...)` or via
an inferred member `.f(...)`.

### 7.2.3 Defaults

Default values must be comptime constant expressions (**E0370**). They are inserted at
call sites (§6.12.7).

### 7.2.4 Named arguments

Any parameter may be passed by name: `spawn_actor(position: p, scale: 2.0)`.

- Positional arguments come first. After the first named argument, every following
  argument must be named (**E0374**).
- Each parameter is given at most once (**E0374**).
- Parameter names are therefore part of a `pub` function's API.
- Named arguments are allowed in calls to functions, methods and comptime type
  functions. They are not allowed for function pointers, whose parameters have no names.

### 7.2.5 Function pointers

Naming a non-generic function without calling it gives a value of type `fn(...) -> R`.
Generic functions must be instantiated first, for example by assigning to a typed
variable: `let f: fn(f32) -> f32 = clamp;`. Default and named arguments do not apply
through function pointers.

### 7.2.6 Entry point

An executable package's root module (§13.1) defines exactly one of:

- `pub fn main()`
- `pub fn main() -> Result<void, E>` where `E` implements `std.fmt.Display`. On
  `.err(e)`, the runtime prints `e` to stderr and exits with status 1.
- `pub fn main() -> u8`: the value is the exit status.

Command-line arguments and environment variables come from `std.process` (§14.7).

## 7.3 Structs

### 7.3.1 Declaration

```pyro
pub struct Player {
    pub health: u8 = 100,
    pub mut speed: f32 = 5.0,
    team_id: u2 = 0,

    pub fn is_alive(self) -> bool { self.health > 0 }
    pub fn heal(mut self, amount: u8) -> mut Self {
        self.health = @add_sat(self.health, amount);
        return self;
    }
    pub const MAX_HEALTH: u8 = 100;
}
```

- Field defaults must be comptime constants (**E0370**).
- `Self` names the enclosing type inside its body.
- `const` members are associated constants: `Player.MAX_HEALTH`.
- A struct may be empty. Recursive containment by value (A holds B holds A) is an error
  (**E0376**). Use a `Handle` or an index instead.

### 7.3.2 Anonymous structs

`struct { ... }` written as an expression (only in comptime contexts, §8.3) creates a new
nominal type each time it is evaluated with different comptime inputs. Its name, for
diagnostics and `--expand`, is derived from the enclosing comptime function and its
arguments (§8.3.2).

### 7.3.3 Field visibility and domain types

| Field marker | Read outside module | Write outside module | Literal outside module |
|--------------|--------------------|----------------------|------------------------|
| (none) | no | no | must have a default |
| `pub` | yes | no | must have a default |
| `pub mut` | yes | yes | yes |

So a type whose fields are `pub` but not `pub mut`, and lack defaults, can only be
created by functions in its own module. That is the parse-don't-validate pattern:

```pyro
pub struct Port { pub value: u16 }

pub fn parse_port(raw: u32) -> Result<Port, ParseError> {
    if raw == 0 || raw > 65535 { return .err(.out_of_range); }
    return .ok(Port { value: raw as u16 });
}
```

Code elsewhere can read `port.value` but can only obtain a `Port` from `parse_port`.
Hot loops that accept `Port` need no revalidation.

## 7.4 Enums

```pyro
pub enum Shape {
    circle(f32),
    rect(f32, f32),
    empty,

    pub fn area(self) -> f32 {
        match self {
            .circle(r) => 3.14159265 * r * r,
            .rect(w, h) => w * h,
            .empty => 0.0,
        }
    }
}

pub enum Opcode: u8 { nop = 0, load = 1, store = 2, halt = 0xFF }
```

- Variants are referenced as `Shape.circle(1.0)` or, with an expected type,
  `.circle(1.0)`.
- An explicit backing type `: uN`/`: iN` is allowed only for payload-free enums
  (**E0377**).
- `@enum_from_int(E, x) -> Option<E>` converts an integer back to an enum. `e as uN`
  gives the discriminant (§4.9.2).
- `@variant_count(E)` gives the number of variants.

## 7.5 Protocols

A protocol is a named set of method signatures, checked at compile time. Pyro has no
protocol objects and no dynamic dispatch through protocols (principle 2): a protocol is
not a type (**E0375**).

### 7.5.1 Declaration and implementation

```pyro
pub protocol Renderable {
    fn bounds(self) -> BBox;
    fn draw(self, mut canvas: Canvas);
    fn is_visible(self) -> bool { true }          // default method
}

impl Renderable for MeshInstance {
    fn bounds(self) -> BBox { self.bounds }
    fn draw(self, mut canvas: Canvas) { canvas.submit_mesh(self.mesh, self.transform); }
}
```

- An `impl P for T` must define every required method of `P` with the exact signature,
  where `Self` = `T`: same parameter modes, types and return type (**E0378**). It may
  override default methods.
- **Coherence.** An `impl P for T` must be in the module that declares `P` or the module
  that declares `T` (**E0379**). Two impls of the same `P` for the same `T` are an error
  (**E0379**).
- Protocols may be generic: `protocol From<E> { fn from(e: E) -> Self; }`.
- Methods from an `impl P for T` are callable with method syntax wherever both `P` and
  `T` are nameable (§7.9, §6.3.3).
- Conformance is always explicit, through an `impl`. Pyro does not use structural
  conformance.

### 7.5.2 Bounds

`fn draw_all<T: Renderable>(items: []T, mut c: Canvas)` accepts any `T` with
`impl Renderable for T`. Multiple bounds are written `T: A + B`. A call whose argument
type does not satisfy the bound is an error at the call site (**E0373**).

### 7.5.3 Runtime polymorphism without vtables

When different kinds of objects must be handled at runtime, use one of:

1. an `enum` with payload variants, and `match`. This is the default and is
   data-oriented when stored as SoA per variant (a `Table` per kind);
2. a struct of function pointers (`fn(...) -> R` fields) for plugin and modding
   boundaries. The indirection is visible in the source.

## 7.6 Generics

### 7.6.1 Generic declarations

```pyro
pub struct Pair<A, B> { pub mut first: A, pub mut second: B }
pub fn max<T: Ord>(a: T, b: T) -> T { if a.cmp(b) == .greater { a } else { b } }
pub struct Ring<T, CAP: usize> { items: [CAP]T, head: usize = 0, len: usize = 0 }
```

A generic parameter with no bound, or with protocol bounds, is a **type parameter**. A
generic parameter bounded by a non-protocol type (`CAP: usize`) is a **value
parameter**, and its argument must be comptime-known.

The built-in bound **`plain`** (a contextual name, valid only in bound position)
restricts a type parameter to plain types (§5.1): `fn copy_all<T: plain>(...)`. An
instantiation with a non-plain type is an error (**E0329**). The standard containers
declare their element parameter as `T: plain`.

### 7.6.2 Generics are comptime functions

A generic struct or enum declaration is exactly equivalent to a comptime type function:

```pyro
pub struct Ring<T, CAP: usize> { ... }
// is the same as
pub fn Ring(comptime T: type, comptime CAP: usize) -> type { return struct { ... }; }
```

except that the generic form may be applied with angle brackets in type position
(`Ring<u32, 64>`), and the type's diagnostic name is `Ring<u32, 64>`. In expression
position it is applied with parentheses: `Ring(u32, 64).init()` (§3.6). A comptime type
function may be applied in type position with parentheses (`SortedSoA(Monster, 512)`)
or called in expression position. Both kinds are memoized: applying the same function
to equal arguments yields the same type (§8.3.1).

A generic function `fn f<T: B>(x: T)` is equivalent to `fn f(comptime T: type, x: T)`
where `T` is supplied by inference rather than by an argument.

### 7.6.3 Inference of generic function arguments

At a call `f(args)` to a generic function, each type parameter is inferred by unifying
the parameter types with the argument types, left to right. Untyped constants unify only
after typed arguments have fixed the parameter. A type parameter that cannot be inferred
is an error (**E0372**). Because expressions never contain `<…>`, functions whose type
parameter cannot be inferred from arguments must declare it as an explicit
`comptime T: type` parameter instead: `arena.alloc_slice(u32, 64)`.

### 7.6.4 Checking generic bodies

A generic body is type-checked once per distinct instantiation, after substituting the
arguments (as in Zig). An error inside an instantiation is reported at the offending line
of the generic body, with an *instantiation trace* naming the user call site that caused
it (§A.2). Implementations should cache identical instantiations across modules.

## 7.7 Constants

`const NAME: T = expr;` at module, struct or function level. `expr` is evaluated at
compile time (chapter 8). The type annotation may be omitted when `expr` has a typed
result. A `const` of untyped-constant value keeps the untyped constant (useful for
`const PI = 3.14159265358979;`). The allowed types are listed in §5.9.

## 7.8 Modules

### 7.8.1 Files are modules

Each `.pr` file is one module. A package (§13.1) has a source root directory `src/`. The
module path of a file is its path relative to `src/`, without the extension, with `/`
replaced by `.`. `src/physics/rigid_body.pr` is module `physics.rigid_body`. Module path
segments must be valid identifiers (**E0901**). The package root module is `src/main.pr`
for executables and `src/lib.pr` for libraries.

### 7.8.2 `use`

```pyro
use std.math;                                   // binds `math`
use std.math as m;                              // binds `m`
use physics.rigid_body.{RigidBody, step as physics_step};
pub use geometry.{Vec2, Rect};                  // re-export
```

- The first path segment selects the package: `std`, the name of a dependency declared
  in `pyro.toml`, or otherwise the current package. A local top-level module named the
  same as a dependency is an error (**E0904**).
- `use a.b;` binds the module `a.b` under its last segment. `use a.b.{X, Y as Z}` binds
  items from it. `use a.b as c` binds the module as `c`.
- You can only import a module, or `pub` items from a module (**E0905**). Private items
  are invisible.
- Two imports binding the same name, or an import colliding with a local item, are
  errors (**E0903**). Rename one with `as`.
- `pub use` re-exports: other modules can import the re-exported names from this module.

### 7.8.3 The module graph

Imports form a directed graph between modules. **The graph must be acyclic** across
both `use` and `pub use` edges. Every cycle is reported with the full chain
(`a → b → c → a`, **E0902**). Shared types belong in a lower-level module that both
sides import. Importing a module several times, directly or transitively (diamond
dependencies), is harmless: each module is compiled exactly once per build
configuration.

### 7.8.4 Prelude

Every module implicitly imports the prelude (§14.1). There is no way to opt out, except
`no_std` packages, which get the reduced core prelude (§14.1.1).

## 7.9 `impl` placement and method visibility

Methods declared in a struct or enum body are visible wherever the type is visible,
subject to their own `pub`. Methods from `impl P for T` blocks are visible wherever both
`P` and `T` are nameable (imported, or reachable by path). This is the single rule
used by §6.3.3 and §7.5.1.

## 7.10 Name resolution (normative procedure)

Compilation of a package proceeds in phases, so no declaration-order constraints arise:

1. **Collect.** Parse every module. Record every item name and its kind per module.
   Build the import graph and reject cycles (**E0902**).
2. **Resolve imports.** In topological order of the module graph, bind every `use`.
3. **Resolve names in bodies.** Resolve identifiers by the order in §6.3.1. `a.b` where
   `a` resolves to a module is a member lookup in that module. Otherwise it stays a
   field or method access, to be resolved by type checking.
4. **Comptime and type checking** (chapter 8): evaluate constants, instantiate
   generics, and check function bodies. Bodies of independent modules may be checked in
   parallel.

Steps 1–3 never need type information, which keeps the front end parallel and
incremental.
