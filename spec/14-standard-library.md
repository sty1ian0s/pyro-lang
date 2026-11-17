# 14. Standard Library

This chapter fixes the **API surface** every conforming implementation provides: names,
signatures and semantics. Implementation strategies are free unless stated. Signatures
use Pyro syntax. `T: plain` is the built-in bound of §7.6.1 (**E0329**).

The standard library is the package `std`. Its modules are imported with `use std.x;`.
Functions that may allocate are marked `@allocates` (§10.7). Their `try_` variants
return `Result<_, AllocError>` instead of trapping with `out_of_memory`.

## 14.1 Prelude

Implicitly visible in every module:

- **Types:** `bool`, `i1`…`i64`, `u1`…`u64`, `isize`, `usize`, `f32`, `f64`, `void`,
  `noreturn`, `str`, `vec`, `vec2`, `vec3`, `vec4`, `mask`, `Handle`, `FieldId`,
  `Option`, `Result`, `Range`, `RangeInclusive`, `Order`, `TrapKind`, `Bounded`, `List`,
  `Pool`, `Arena`, `Channel`, `Sender`, `Atomic`, `MemOrder`, `StepRange`, `RevRange`.
- **Protocols:** `Ord`, `From`, `Hash`, `Display`, `Debug`, `Indexable`, `IndexableMut`.
- **Functions:** `print`, `eprint`, `format` (§14.6), `assert(cond: bool, msg: str)`,
  `vec2(x, y)`, `vec3(x, y, z)`, `vec4(x, y, z, w)`.
- **Modules:** `std` itself, so `std.math.sqrt(x)` works without `use`.

### 14.1.1 Core prelude (`no_std`)

Packages with `no_std = true` get the prelude without `List`, `Pool`, `Arena`,
`Channel` and `print`/`eprint`. They also cannot import `std.fs`, `std.process`,
`std.net`, `std.gpu` or `std.time` (**E0912**). `std.mem.FixedArena`, `Bounded`,
`std.math`, `std.simd` and `std.meta` remain available.

### 14.1.2 `Option<T>` and `Result<T, E>`

```pyro
pub enum Option<T> { some(T), none }
// methods:
fn is_some(self) -> bool;          fn is_none(self) -> bool;
fn unwrap_or(self, default: T) -> T;
fn expect(self, msg: str) -> T;    // traps (kind .explicit) on .none
fn map<U>(self, comptime f: fn(T) -> U) -> Option<U>;
fn ok_or<E>(self, e: E) -> Result<T, E>;

pub enum Result<T, E> { ok(T), err(E) }
// methods:
fn is_ok(self) -> bool;            fn is_err(self) -> bool;
fn unwrap_or(self, default: T) -> T;
fn expect(self, msg: str) -> T;    // traps (kind .explicit) on .err
fn map<U>(self, comptime f: fn(T) -> U) -> Result<U, E>;
fn map_err<F>(self, comptime f: fn(E) -> F) -> Result<T, F>;
fn ok(self) -> Option<T>;
```

`expect` exists so that unhandled cases are explicit at the call site. There is no
`unwrap()` without a message.

### 14.1.3 Ranges

`Range<T>` (`a..b`) and `RangeInclusive<T>` (`a..=b`) for integer `T` have fields
`start`, `end` and methods `len() -> usize`, `contains(x) -> bool`,
`step(n: T) -> StepRange<T>` (iterable with stride `n > 0`), `rev() -> RevRange<T>`.

## 14.2 Protocols

```pyro
pub enum Order { less, equal, greater }

pub protocol Ord        { fn cmp(self, other: Self) -> Order; }
pub protocol From<E>    { fn from(e: E) -> Self; }
pub protocol Hash       { fn hash(self, mut h: std.hash.Hasher); }
pub protocol Display    { fn fmt(self, mut w: std.fmt.Writer); }
pub protocol Debug      { fn debug(self, mut w: std.fmt.Writer); }
pub protocol Indexable<E> {
    fn len(self) -> usize;
    fn at(self, i: usize) -> E;                  // must trap if i >= len
}
pub protocol IndexableMut<E> {                   // types with Indexable and IndexableMut
    fn at_mut(mut self, i: usize) -> mut E;      //   are mutable iterables (§6.7.2)
}
```

The standard library implements these for all primitive types where they make sense.
For user types, `std.derive` provides reflection-based helpers, so an implementation is
a one-liner and conformance stays explicit (§7.5.1):

```pyro
impl Ord for Point { fn cmp(self, other: Self) -> Order { std.derive.cmp(self, other) } }
impl Hash for Point { fn hash(self, mut h: std.hash.Hasher) { std.derive.hash(self, mut h); } }
```

`std.derive.cmp` compares fields lexicographically in declaration order.
`std.derive.hash` and `std.derive.debug` visit every field.

`std.ops` provides `Num`, a protocol implemented by all integer and float types
(`zero()`, `one()`, `add`, `sub`, `mul`, `div`), for generic numeric code. Operators
are not overloadable.

## 14.3 Memory: `std.mem`, `Arena`

| API | Semantics |
|-----|-----------|
| `Arena.init() -> Arena` `@allocates` | growable bump allocator; chunks from the general allocator |
| `Arena.with_capacity(bytes: usize) -> Arena` `@allocates` | |
| `alloc_slice(mut self, comptime T: type, n: usize) -> mut []T` `@allocates` `@append_only` | zeroed; origin = the arena (§5.6) |
| `alloc(mut self, comptime T: type) -> mut T` `@allocates` `@append_only` | one zeroed `T` |
| `reset(mut self)` | O(1); keeps the largest chunk, frees the others |
| `used(self) -> usize`, `capacity(self) -> usize` | bytes |
| `deinit(move self)` | free all memory |
| `mem.FixedArena.init(mut buf: []u8) -> FixedArena` | a view type over caller-provided memory (for `no_std`); `alloc_slice` returns `Result<mut []T, AllocError>` |
| `mem.replace<T>(mut place: T, move new: T) -> T` | swap a value (also for resources) |
| `mem.swap<T>(mut a: T, mut b: T)` | |
| `mem.leak<T>(move x: T)` | consume without releasing (§5.3.4) |
| `mem.copy<T: plain>(mut dst: []T, src: []T)` | traps if lengths differ |
| `mem.fill<T: plain>(mut dst: []T, v: T)`, `mem.eql<T: plain>(a: []T, b: []T) -> bool` | |
| `mem.heap_stats() -> HeapStats` | bytes allocated and freed by the general allocator on this thread |

**General-purpose allocator.** Each worker thread has a size-class allocator. Memory
freed on another thread is returned to its owning thread's free list through a
lock-free queue. The allocator is internal to `std` and has no user-visible handle.

## 14.4 Containers

`List`, `Pool`, `SparseMap`, `Map` and growable `Table`s are resources (deinitialize
with `deinit(move self)`). `Bounded`, `BitSet` and fixed-capacity `Table`s are plain
when their elements are. All containers require plain element types (`T: plain`),
implement `Indexable` (except `Map`), and respect `@soa` and `@cold` on `T`
(§4.11.5–6). `List`, `Pool` and `Bounded` are in the prelude. `SparseMap`, `Map` and
`BitSet` are in `std.collections`, and `Table` is in `std.data`.

### 14.4.1 `List<T>`

A dense growable array.

```
init() -> List<T>                       with_capacity(n: usize) -> List<T>   @allocates
len(self) -> usize   capacity(self) -> usize   is_empty(self) -> bool
push(mut self, v: T)            @allocates      try_push(mut self, v: T) -> Result<void, AllocError>
pop(mut self) -> Option<T>
insert(mut self, i: usize, v: T) @allocates     // shifts tail right, O(n)
remove(mut self, i: usize) -> T                 // shifts tail left, O(n), keeps order
swap_remove(mut self, i: usize) -> T            // moves last element into i, O(1)
retain(mut self, comptime keep: fn(T) -> bool)  // order-preserving
retain_unordered(mut self, comptime keep: fn(T) -> bool)   // swap-back, fastest
sort(mut self)                     where T: Ord, stable
sort_by_key<K: Ord>(mut self, comptime key: fn(T) -> K)    stable
clear(mut self)   reserve(mut self, n: usize) @allocates
extend(mut self, src: []T) @allocates
as_slice(self) -> []T   as_mut_slice(mut self) -> mut []T    // also via list[..]
chunks(self, n: usize) -> Chunks<T>                // Indexable<[]T>; last chunk may be shorter
chunks_mut(mut self, n: usize) -> ChunksMut<T>      // Indexable + IndexableMut<[]T>; disjoint sub-origins (§5.4.4)
split_at_mut(mut self, i: usize) -> (mut []T, mut []T)
deinit(move self)
```

The same slice methods (`len`, `sort`, `sort_by_key`, `chunks`, `chunks_mut`,
`split_at_mut`, `fill`, `index_of`, `contains`, `binary_search_by_key`, `shift_left`,
`shift_right`, `reverse`) exist on `[]T` and `soa []T` views where meaningful.

### 14.4.2 `Pool<T>`: generational slot map

Dense storage with stable handles. Representation (normative, so performance is
predictable): `dense: List<T>` (SoA if `@soa`), `dense_to_slot: List<u32>`, and
`slots: List<Slot>` with `Slot { dense_index: u32, generation: u32 }`, plus a free list
of slot indices.

```
init() -> Pool<T>
insert(mut self, v: T) -> Handle<T>  @allocates   // O(1) amortized
remove(mut self, h: Handle<T>) -> bool            // O(1): swap-back in dense, generation += 1
get(self, h: Handle<T>) -> Option<T>              // O(1), generation-checked
get_mut(mut self, h: Handle<T>) -> Option<mut T>
contains(self, h: Handle<T>) -> bool
len(self) -> usize
handle_at(self, dense_index: usize) -> Handle<T>  // for `for x, i in pool` loops
clear(mut self)                                   // all handles become stale
deinit(move self)
```

`for x in pool` iterates densely (unordered), with `x` an element view.
`for x, i in pool` gives the dense index, and `pool.handle_at(i)` gives its handle.

### 14.4.3 `SparseMap<K, V>`

Associates data with handles from another pool (component data, mod data). It is keyed
by `Handle<K>`: `insert(mut self, k: Handle<K>, v: V)`, `get`, `get_mut`,
`remove(mut self, k) -> bool`, `len`, dense iteration (`for v, i in m`, and
`m.key_at(i)`). A stale key (generation mismatch) behaves as absent.

### 14.4.4 `Map<K: Hash, V>`

An open-addressing hash map with a per-process random seed. Methods:
`insert(mut self, k, v) -> Option<V>` (previous value) `@allocates`, `get`, `get_mut`,
`remove`, `contains`, `len`, `clear`. Iteration (`for e in map.entries()`) has
unspecified order. Prefer `Pool`, `SparseMap` or `@hash` keys with `Map<u64, V>` over
string keys (principle 9).

### 14.4.5 `Bounded<T, N>`

Fixed-capacity inline storage `[N]T` plus a `len: usize`. It is plain when `T` is plain:
no heap, no `deinit`. API: `empty()`, `push` (traps with kind `capacity` when full),
`try_push -> Result<void, Full>`, `pop`, `len`, `capacity`, `clear`, `as_slice`,
`as_mut_slice`, `sort`, `sort_by_key`, `retain`, `retain_unordered`, `swap_remove`.
Comprehensions write into it (§6.2.5).

### 14.4.6 `BitSet<N>`

Fixed `N`-bit set: `set`, `clear`, `get`, `count`, `and`, `or`, `xor`, `not`,
`iter_ones` (Indexable over the set bit positions).

### 14.4.7 Tables: `std.data.Table`

`Table(T, opts)` is a comptime type function. It builds a dense, SoA-friendly
collection with stable handles and an optional maintained sort order. It is the
data-oriented replacement for a list of objects, and for the beginner "table" layer.

```pyro
pub struct TableOptions<T> {
    pub mut sorted_by: Option<FieldId<T>> = .none,   // maintained ascending order
    pub mut capacity: usize = 0,                     // 0 = growable (heap); >0 = fixed, inline
}
pub fn Table(comptime T: type, comptime opts: TableOptions<T>) -> type
```

Semantics:

- **Storage.** Like `Pool<T>` (dense columns, handles, swap-back removal). With
  `capacity > 0`, all storage is inline arrays: the table is then plain (no `deinit`)
  when `T` is plain, and `add` traps with kind `capacity` when full.
- **Order index.** When `sorted_by` is set, the table also keeps `order: [..]u32`,
  dense indices sorted ascending by the field (stable for equal keys). `add` inserts
  by binary search plus shift, O(log n + n). `remove` deletes the entry plus shift and
  patches the moved element's index, O(n). These costs are part of the specification.
- **API:** `init()`, `add(mut self, v: T) -> Handle<T>`, `remove(mut self, h) -> bool`,
  `get`, `get_mut`, `len`, dense iteration (`for m in t`), and `sorted(self)`, an
  `Indexable` view in sort order (only when `sorted_by` is set, **E0804** otherwise).
  `deinit` exists only for growable tables.
- **Runtime re-sorting (UI columns).**
  `sort_view<K: Ord>(self, mut out: List<u32>, comptime key: fn(T) -> K)` fills `out`
  with dense indices ordered by any key, O(n log n). The table's maintained order is
  unchanged. Several views can coexist.

```pyro
use std.data.{Table};
const Monsters = Table(Monster, .{ sorted_by: .threat_level, .. });   // FieldId → Option (§6.2.3)

let mut monsters: Monsters = .init();
defer monsters.deinit();
_ = monsters.add(.{ health: 100.0, threat_level: 3, name_hash: @hash("orc") });
_ = monsters.add(.{ health: 50.0,  threat_level: 8, name_hash: @hash("troll") });
for m in monsters where m.health > 75.0 { print("{}\n", m.threat_level); }
for m in monsters.sorted() { print("{}\n", m.threat_level); }   // ascending threat
```

## 14.5 Concurrency support

- `Channel<T: plain, CAP: usize>`, `Sender<T>`, and `Atomic<T>`: §10.4, §10.5. The atomic memory
  ordering enum is `MemOrder { relaxed, acquire, release, acq_rel, seq_cst }`.
- `std.par`:
  - `threads() -> usize`;
  - `set_threads(n: usize)` (only before the first nursery, else traps);
  - `reduce<T: plain>(xs: []T, init: T, comptime combine: fn(T, T) -> T) -> T`, which
    combines in a deterministic tree;
  - `sum`, `min`, `max` built on `reduce`.
- `std.actors.Actors(S, M, MAILBOX: usize = 64)`: a comptime type function for
  data-oriented actors. All actor states `S` are stored in one `Pool<S>` (SoA if
  `@soa`), and messages `M` (plain) are queued per actor in one dense mailbox array.
  Supporting types: `Envelope<S, M> { to: Handle<S>, msg: M }`,
  `Outbox<S, M> = Bounded<Envelope<S, M>, 16>`, and `enum SendError { mailbox_full, no_such_actor }`.
  - `add(mut self, s: S) -> Handle<S>` creates an actor;
  - `send(self, to: Handle<S>, m: M) -> Result<void, SendError>` (callable from any
    task);
  - `run_batch(mut self, comptime handle: fn(mut S, M, mut Outbox<S, M>))` delivers
    every queued message in mailbox order per actor, processing different actors in
    parallel. Messages a handler puts into its outbox are delivered in the next batch.

  Waiting states are encoded as enum fields of `S` ("state-tag continuations"). There is
  no async machinery.

## 14.6 Text and formatting: `std.text`, `std.fmt`

**`str` methods:** `len() -> usize` (bytes), `is_empty`, `bytes() -> []u8`,
`eql(other) -> bool`, `starts_with`, `ends_with`, `find(sub) -> Option<usize>`,
`split_once(sep: str) -> Option<(str, str)>`, `trim`, `trim_start`, `trim_end`,
`parse_int(comptime T: type) -> Option<T>`, `parse_float(comptime T: type) -> Option<T>`.
`text.next_char(s: str, at: usize) -> Option<(u32, usize)>` decodes one scalar value and
returns it with the next offset. `text.validate(bytes: []u8) -> Option<str>` checks
UTF-8.

**`text.Builder`** (resource): `init()`, `append(mut self, s: str)` `@allocates`,
`as_str(self) -> str`, `clear`, `deinit`. To append formatted text, `format` into a
stack buffer first, then `append`.

**`fmt.Writer`** (passed to `Display.fmt` / `Debug.debug`): `write(mut self, s: str)`,
`write_byte(mut self, b: u8)`, `write_int(mut self, v: i64)`,
`write_uint(mut self, v: u64)`, `write_float(mut self, v: f64, precision: u8 = 6)`.

**Formatting intrinsics** (prelude):

```
print(comptime fmt: str, args...)                         // stdout, unbuffered per call
eprint(comptime fmt: str, args...)                        // stderr
format(mut out: []u8, comptime fmt: str, args...) -> Result<str, fmt.Overflow>
```

Format string grammar: literal text, `{{` and `}}` for literal braces, and placeholders
`{` [`:` spec] `}` consumed by arguments in order. `spec ::= [fill align] [width]
['.' precision] [type]` with `align ∈ {<, ^, >}` and `type ∈ {"" (Display), "?" (Debug),
"x", "X", "b", "o", "e"}`. The format string is parsed at compile time. The argument
count must match, and each argument must implement the needed protocol (**E1401**).
Formatting never allocates. `print`/`eprint` format into a per-thread fixed buffer and
issue the write when the call finishes, or earlier when the buffer fills, so the output
of one call is never interleaved with other threads unless it exceeds the buffer (at
least 4 KiB).

## 14.7 Operating system: `std.fs`, `std.process`, `std.time`, `std.net`

| API | Notes |
|-----|-------|
| `fs.File` (resource) | `open(path: str, mode: OpenMode) -> Result<File, IoError>`, `read(self, mut buf: []u8) -> Result<usize, IoError>`, `write(self, bytes: []u8) -> Result<usize, IoError>`, `write_all`, `seek`, `size`, `close(move self)` |
| `fs.read_into(path, mut buf: []u8) -> Result<usize, IoError>` | reads up to `buf.len()` |
| `fs.read_all(path, mut out: List<u8>) -> Result<void, IoError>` `@allocates` | |
| `fs.write_file(path, bytes) -> Result<void, IoError>` | |
| `fs.Dir`, `fs.exists`, `fs.remove`, `fs.rename`, `fs.create_dir_all` | |
| `process.args(mut arena: Arena) -> []str` | |
| `process.env_var(name: str, mut arena: Arena) -> Option<str>` | runtime environment, not build environments |
| `process.exit(code: u8) -> noreturn` | does not run defers |
| `process.Command` (resource) | `init(program: str)`, `arg(mut self, a: str) -> mut Self`, `start(move self) -> Result<Child, IoError>`; `Child` (resource): `wait(move self) -> Result<u8, IoError>`, pipes for stdin/stdout/stderr |
| `time.Instant.now()`, `.elapsed() -> Duration` | monotonic clock |
| `time.Duration` | nanoseconds `u64`, `as_secs_f64()` |
| `time.sleep(d: Duration)` | |
| `net.TcpListener`, `net.TcpStream`, `net.UdpSocket` (resources) | blocking I/O. Concurrency through `nursery` tasks |

`IoError` is a payload-free enum: `not_found`, `permission_denied`, `already_exists`,
`interrupted`, `would_block`, `invalid_input`, `unexpected_eof`, `no_space`, `other`.

## 14.8 Reflection: `std.meta`

`TypeInfo` and `FieldInfo` (§8.4). `Target` has fields `arch: Arch`, `os: Os`,
`abi: Abi`, `pointer_bits: u8`, `endian: Endian` and the method
`has_feature(f: CpuFeature) -> bool`. The enums list every arch/OS/feature the
implementation supports. `meta.fields(T) -> []FieldInfo` is shorthand for the struct
case.

## 14.9 Hashing and debugging: `std.hash`, `std.debug`

- `hash.fnv1a64(bytes: []u8) -> u64`: the same function as `@hash` (§8.6.1), at
  runtime.
- `hash.Hasher`: the default keyed hasher used by `Map`. The algorithm is
  implementation-defined, with at least 64-bit output, and is seeded per process.
- `debug.name_of(h: u64) -> Option<str>`: looks up the `@hash` name table, which exists
  only when `hash_names = true`.
- `debug.stack_trace(mut out: []u8) -> str`: available in checked builds.

## 14.10 SIMD: `std.simd`

```
load<T>(xs: []T, i: usize, comptime W: usize) -> vec<W, T>          // traps if i+W > len
store<T, W: usize>(mut xs: []T, i: usize, v: vec<W, T>)
load_masked<T>(xs: []T, i: usize, comptime W: usize, m: mask<W>, fill: T) -> vec<W, T>
store_masked<T, W: usize>(mut xs: []T, i: usize, v: vec<W, T>, m: mask<W>)
iota(comptime W: usize, comptime T: type) -> vec<W, T>              // 0, 1, 2, ...
reduce_add_ordered<T, W: usize>(v: vec<W, T>) -> T                  // T: f32 or f64; left-to-right
dot, cross (vec3), length, normalize, min, max, abs, sqrt (lane-wise)
```

`load_masked`/`store_masked` handle tails without traps: masked-off lanes outside the
slice are never accessed.

## 14.11 GPU: `std.gpu`

| API | Notes |
|-----|-------|
| `gpu.Device.default() -> Result<Device, GpuError>`, `gpu.Device.select(comptime required: Features) -> Result<Device, GpuError>` | first suitable adapter |
| `Device.is_lost(self) -> bool`, `wait_idle(self)`, `encoder(mut self) -> Encoder`, `limits(self) -> Limits`, `features(self) -> Features`, `deinit(move self)` | |
| `gpu.Buffer<T: plain>`: `init(mut dev: Device, n: usize) -> Result<Buffer<T>, GpuError>` | device-resident (§11.2.3) |
| `Buffer.upload(mut self, src: []T)`, `download(self, mut dst: []T)`, `len(self)`, `deinit(move self)` | lengths must match (trap) |

`launch gpu` uses `Device.default()` implicitly when no resident buffer argument
determines the device.

Graphics (§11.6):

| API | Notes |
|-----|-------|
| `gpu.Surface` (resource) | `init(mut dev: Device, window: WindowHandle) -> Result<Surface, GpuError>`, `next_frame(mut self, mut dev: Device) -> Result<Frame, GpuError>`, `resize(mut self, w: u32, h: u32)` |
| `gpu.Frame` (resource) | `begin_pass(mut self, opts: PassOptions) -> RenderPass`, `present(move self)` |
| `gpu.RenderPass` (resource) | `draw`, `draw_indexed`, `draw_mesh_tasks`, `set_viewport`, `set_scissor`, `end(move self)` |
| `gpu.Encoder` (resource) | from `dev.encoder()`: `begin_pass(mut self, targets: …, opts: PassOptions) -> RenderPass` (off-screen), `dispatch`, `trace_rays` (signatures §11.6.3), `submit(move self)` |
| `gpu.RenderPipeline(desc)`, `gpu.ComputePipeline(kernel)`, `gpu.RayPipeline(desc)` | comptime type functions (§11.6.1, §11.5.2) |
| `gpu.Texture2D<F>`, `Texture3D<F>`, `TextureCube<F>`, `Texture2DArray<F>`, `DepthTexture2D`, `StorageTexture2D<F>` (resources) | `init(mut dev, desc) -> Result<…, GpuError>`, `upload(…)`, `download(…)`, `deinit` |
| `gpu.Sampler` (resource) | `init(mut dev, desc: SamplerDesc) -> Result<Sampler, GpuError>` |
| `gpu.Buffer<T>.ref(self) -> BufferRef<T>` | plain, generation-checked reference used in geometry descriptors |
| `gpu.Blas`, `gpu.Tlas` (resources), `BlasRef`, `Geometry`, `TriangleGeometry`, `AabbGeometry`, `Aabb`, `Instance`, `InstanceFlags`, `BuildOptions`, `BuildPreference` | §11.5.1 |
| `RayPipelineDesc`, `HitGroup`, `trace_ray`, `Ray`, `RayInfo`, `PrimitiveInfo`, `Hit<A>`, `HitKind`, `AnyHit`, `TraceOptions`, `RayFlags`, `Barycentrics` | §11.5.2–11.5.4 |
| `gpu.RayQuery`, `Candidate`, `Committed` | §11.5.5 (GPU-local type) |
| `gpu.MeshOut<V, Prim, VM, PM>` | `set_counts`, `vertex`, `triangle`/`line`/`point`, `primitive` (mesh stage only, GPU-local type, §11.4.3) |
| `RenderPipelineDesc`, `Topology`, `CullMode`, `FrontFace`, `DepthState`, `ColorTarget`, `Blend`, `SpecConst`, `ConstValue`, `PassOptions` | §11.6.1–11.6.3 |
| `gpu.linear_id(id: vec3<u32>, size: vec3<u32>) -> u32` | `id.x + size.x·(id.y + size.y·id.z)` |

```pyro
pub enum GpuError {
    no_device, unsupported, limits, device_lost, out_of_memory,
    stale_buffer, stale_blas, bad_geometry, invalid_instance, surface_lost,
}
pub struct Features {              // all fields bool
    pub mesh_shaders: bool, pub ray_tracing: bool, pub ray_query: bool,
    pub ray_primitive_culling: bool, pub fragment_stores: bool,
    pub shader_f64: bool, pub shader_i64: bool, pub storage_8bit: bool, pub storage_16bit: bool,
}
pub struct Limits {                // all u32; portable minimums in §11.1.1, §11.4.5, §11.5
    pub max_compute_invocations: u32, pub max_task_invocations: u32, pub max_mesh_invocations: u32,
    pub max_mesh_vertices: u32, pub max_mesh_primitives: u32, pub max_task_payload: u32,
    pub max_mesh_output_bytes: u32, pub max_task_mesh_grid: u32, pub max_ray_recursion: u32,
    pub max_ray_payload: u32, pub max_hit_attributes: u32, pub max_tlas_instances: u32,
    pub max_dispatch_per_dim: u32, pub max_color_targets: u32,
}
```

Windowing is not part of `std`. `WindowHandle` is a `@c_layout` struct wrapping the
platform's native handle, supplied by a windowing library.

## 14.12 Build API: `std.build`

Available only to `build.pr` (**E0913** elsewhere). `Builder` methods:
`read_file(path) -> Result<List<u8>, Error>` (records a dependency),
`generate_module(name: str, source: str) -> Result<void, Error>`,
`add_c_source(path, flags: []str = []) -> Result<void, Error>`,
`add_asm_source(path) -> Result<void, Error>`, `link_system_library(name)`,
`add_link_arg(arg)`, `add_executable(name, root: str) -> Result<void, Error>`, `env(key) -> Option<str>` (the selected build
environment), `target() -> meta.Target`, `run(cmd: process.Command) -> Result<u8, Error>`.

## 14.13 Math: `std.math`

Constants `PI`, `TAU`, `E`, `INF`, `NAN`, and the integer limits as associated
constants (`u32.MAX`, `i8.MIN`). Functions are generic over `f32`/`f64`, and lane-wise
on `vec`: `abs`, `min`, `max`, `clamp`, `sqrt`, `cbrt`, `sin`, `cos`, `tan`, `asin`,
`acos`, `atan`, `atan2`, `exp`, `exp2`, `log`, `log2`, `log10`, `pow`, `floor`, `ceil`,
`round`, `trunc`, `fract`, `lerp`, `is_nan`, `is_inf`, `copysign`. Results are
correctly rounded for `sqrt` and within 1 ulp for the others on every target, so CPU
results are reproducible across targets. Integer: `abs`, `min`, `max`, `clamp`, `pow`,
`isqrt`, `gcd`, `div_floor`, `rem_euclid`.

## 14.14 Testing: `std.testing`

`Arbitrary` protocol: `fn arbitrary(mut g: Gen) -> Self` and
`fn edge_cases() -> []Self`. It is derived automatically for plain structs, tuples,
enums and arrays (§9.6.1). `Gen` provides `int_in`, `float_in`, `bool`, `choose`.
`Bench` provides `iter(mut self, comptime body: fn())` and `black_box<T>(x: T) -> T`.

## 14.15 Entity-component-system: `std.ecs`

`Table` covers one kind of object. An ECS covers entities whose set of components
changes at runtime, and queries across component combinations. `std.ecs` provides one
with the ergonomics of built-in syntax. It is comptime code over `Table`-style SoA
storage, so `--expand` shows everything it does.

```pyro
use std.ecs;

@soa pub struct Position { pub mut x: f32, pub mut y: f32 }
@soa pub struct Velocity { pub mut x: f32, pub mut y: f32 }
pub struct Health { pub mut hp: u16 }

const World = ecs.World(.{ Position, Velocity, Health });      // the component universe

fn movement(mut w: World, dt: f32) {
    for (pos, vel) in w.query(.{ Position, Velocity }) {        // every entity having both
        pos.x += vel.x * dt;
        pos.y += vel.y * dt;
    }
}

pub fn main() {
    let mut w: World = .init();
    defer w.deinit();
    let player = w.create(.{ Position { x: 0.0, y: 0.0 }, Velocity { x: 1.0, y: 0.0 }, Health { hp: 100 } });
    let rock   = w.create(.{ Position { x: 5.0, y: 5.0 } });
    w.add(rock, Velocity { x: 0.0, y: -1.0 });                  // moves rock to another archetype
    movement(mut w, 0.016);
    w.remove(player, Health);
    w.destroy(rock);
}
```

### 14.15.1 API

| API | Semantics |
|-----|-----------|
| `ecs.World(comptime components)` | comptime type function; `components` is a tuple of up to 64 plain struct types (**E0804** otherwise) |
| `init() -> W`, `deinit(move self)` | resource |
| `create<T>(mut self, comps: T) -> Entity` | `T` must be a tuple of distinct component types (checked at comptime); returns a generational `Entity` handle |
| `destroy(mut self, e: Entity) -> bool` | `false` if `e` is stale |
| `add<C>(mut self, e: Entity, c: C) -> bool` | add or overwrite component `C` |
| `remove(mut self, e: Entity, comptime C: type) -> bool` | |
| `has(self, e: Entity, comptime C: type) -> bool` | |
| `get(self, e: Entity, comptime C: type) -> Option<C>` / `get_mut(mut self, e: Entity, comptime C: type) -> Option<mut C>` | per-entity access |
| `query(self, comptime with: T, comptime without: U = .{})` and the same on a mutable world | `with`/`without` are comptime tuples of component types. The result is an iterable whose elements are tuples of component views in `with` order, mutable when the world place is mutable (§6.7.2). `without` excludes entities having those components |
| `query_entities(...)` | the same, with the `Entity` prepended to each tuple |
| `ecs.Commands(W)` | a resource buffer of deferred `create`/`destroy`/`add`/`remove` operations, recorded during a query loop and applied with `w.apply(move cmds)` |
| `count(self) -> usize` | live entities |

A positional literal such as `.{ Position { … }, Velocity { … } }` or
`.{ Position, Velocity }` passed to a generic parameter forms a tuple of its elements
(§6.2.2).

### 14.15.2 Storage and complexity (normative)

- **Archetypes.** Each distinct set of components (a 64-bit mask over the universe) is
  an archetype table. Each component is a column, laid out SoA per field when the
  component is `@soa`, otherwise AoS. Archetype tables are created on first use and
  never destroyed before `deinit`.
- **Entities.** `Entity` is `Handle<EntityTag>`, a 64-bit generational handle into a
  slot map from entity to (archetype, row).
- `create`, `destroy`: O(1) amortized. Removal is swap-back within the archetype, and
  the moved entity's slot is patched.
- `add`, `remove`: O(k), where k is the number of components of the entity. The row
  moves to the target archetype (swap-back in the source). Archetype transitions are
  cached per (archetype, component) edge.
- `query`: iterates every archetype whose mask contains `with` and excludes `without`.
  The matching archetype list is cached and updated when archetypes are created. Within
  an archetype, iteration is a dense SoA sweep and is eligible for `@simd` and
  `parallel_for` (`for` → `parallel_for` over `w.query(...)` works, giving each task
  disjoint rows).
- **Structural changes during iteration.** A query loop keeps a live view of the world
  (§6.7.2). So `create`/`destroy`/`add`/`remove` inside the loop are compile errors
  (**E0332**). Record them in an `ecs.Commands(W)` and apply after the loop. Iterator
  invalidation is therefore impossible.

Systems are ordinary functions taking `mut w: World` (or read-only `w: World`), and
scheduling is ordinary code. Systems that touch disjoint component sets can run in one
`nursery` by passing disjoint query views to different tasks.
