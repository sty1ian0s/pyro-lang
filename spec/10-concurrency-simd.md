# 10. Concurrency and SIMD

## 10.1 Model

Pyro concurrency is **structured**. Every concurrent task is started inside a lexical
scope and finishes before that scope ends. The language provides:

- `nursery { spawn f(...); ... }`: fork-join task groups (§10.2);
- `parallel_for x in xs { ... }`: data-parallel loops (§10.3);
- `Channel<T, N>`: bounded message queues between tasks (§10.4);
- `Atomic<T>`: atomic shared counters and flags (§10.5);
- `launch gpu` / `launch cpu`: compute kernels (chapter 11).

Pyro has no `async`/`await`, no futures and no detached threads. A long-running service
is a `nursery` in `main` that runs until shutdown. Event-driven state machines are
written as data: an enum state per entity, processed in batches (§14.5, actors).

**Data-race freedom** follows from the exclusivity rule (§5.4.2). Task arguments stay
live until the end of their nursery, so two tasks can never hold conflicting views of
the same place. The only shared mutable state is `Atomic<T>` and `Channel`, whose
methods synchronize internally.

## 10.2 `nursery` and `spawn`

```pyro
nursery {
    spawn decode_audio(move audio_file, mut audio_out);
    spawn decode_video(move video_file, mut video_out);
    update_ui(mut ui);             // runs concurrently with the spawned tasks
}                                  // waits here for both tasks
```

Semantics:

1. `spawn f(args);` evaluates `f` and `args` in the spawning task, then schedules the
   call to run concurrently. It must appear lexically inside a `nursery` body (§3.5).
2. The spawned function must return `void` (**E0502**). Results are written through
   `mut` arguments. Errors are reported through a `mut` `Result` slot or a channel.
3. The end of the `nursery` block waits until every task spawned in it has finished.
   Then the block's defers run. A `return`, `break`, `?` or `continue` that leaves the
   nursery body first waits for all of its tasks.
4. **Arguments.** Every argument view of a `spawn` stays live until the end of the
   `nursery` (§5.4.2). So, for the whole nursery:
   - a place passed as `mut` to one task cannot be used by any other task or by the
     nursery body (**E0332**/**E0333**);
   - a place passed read-only may be shared by many tasks, but nobody may write it;
   - resources are transferred with `move` and belong to the task.
5. Views produced by disjoint-splitting functions (§5.4.4) have pairwise-disjoint
   origins. Spawning one task per chunk is therefore allowed:

   ```pyro
   nursery {
       for chunk in pixels.chunks_mut(4096) { spawn shade(mut chunk, palette); }
   }
   ```

6. **Scheduling.** Tasks run on a runtime-managed pool of worker threads, one per
   hardware thread by default (§14.5). The spawning thread may run tasks itself while
   it waits. The order of execution is unspecified. `spawn` never allocates per task on
   the heap: task frames come from per-worker task arenas sized at nursery entry.
7. A trap in any task terminates the process (§9.4).

## 10.3 `parallel_for`

```pyro
parallel_for p in particles {          // particles: mut soa []Particle
    p.vx *= 0.99;
    p.x += p.vx * dt;                  // dt captured read-only
}
```

- The iterable must be a range, an array or slice (including SoA), or an
  `IndexableMut` type whose elements are disjoint per index by contract:
  `xs.chunks_mut(n)`, `std.ecs` queries (**E0503**).
- Iterations may run concurrently, in any order. The runtime partitions the iteration
  space into contiguous chunks whose size is implementation-defined, but at least 64
  elements unless the space is smaller. Within a chunk, iterations run in order and may
  be vectorized.
- The element binding has the same mutability rule as in `for` (§6.7.2). Each iteration
  may write only through its element binding and locals declared inside the body.
  Variables from outside are read-only inside the body (**E0504**), except `Atomic` and
  `Channel` values, which are used through their synchronized methods.
- `break`, `return`, `?` and labelled `continue` are not allowed in the body
  (**E0504**). Unlabelled `continue` is allowed.
- The loop finishes after all iterations complete.

Reductions use `std.par.reduce` (§14.5), which combines per-chunk partial results in a
deterministic tree order. With the same input and thread count it gives the same
floating-point result every run.

## 10.4 Channels

`Channel<T, CAP>` is a bounded, multi-producer, multi-consumer FIFO queue for plain
messages (**E0505**). There are two sides:

- **Receiving.** The `Channel` value itself. It is a resource, and its receive methods
  take `self` (read-only), so any number of consumer tasks may share it.
- **Sending.** `Sender<T>` endpoints, obtained with `ch.sender()`. A `Sender` is a
  resource: every sender must be released exactly once (§5.3.3), with `close(move self)`
  or by moving it on.

| Method | Behaviour |
|--------|-----------|
| `Channel<T, CAP>.init()` (via `.init()`) | create; `CAP ≥ 1` comptime |
| `sender(self) -> Sender<T>` | new send endpoint; the channel is open while ≥ 1 sender is alive |
| `recv(self) -> Option<T>` | waits while empty and open; `.none` once every sender is released and the queue is drained |
| `try_recv(self) -> Option<T>` | never waits |
| `deinit(move self)` | release the receiving side (§5.4.2 ensures no live views) |
| `Sender.send(self, v: T) -> Result<void, Closed>` | waits while full; `.err(.closed)` if the channel was deinitialized |
| `Sender.try_send(self, v: T) -> Result<void, SendError>` | `.full` or `.closed`; never waits |
| `Sender.close(move self)` | release this endpoint |

The channel's storage is freed when the `Channel` and every `Sender` have been released.
An internal atomic count, visible in this specification and in `--expand` as calls to
`close`/`deinit`, tracks this.

A `recv` on a channel with no live senders and an empty queue returns `.none`
immediately. So create senders *before* spawning the consumers that depend on them.

Transfer ownership of bulk data by sending a `Handle` or an index into a container the
receiver owns.

### 10.4.1 Progress guarantees

Pyro has no locks, so lock-ordering deadlocks cannot happen. `nursery`, `parallel_for`
and `launch` cannot deadlock. For channels, three rules work together:

1. **No forgotten close.** Senders are resources, so the compiler rejects any path on
   which a producer ends without releasing its sender (E0322). When the last producer
   finishes, even through an early `return` or `?`, consumers' `recv` returns `.none`
   and their loops end.
2. **Static cycle warning.** Within one `nursery`, the compiler builds a graph: an edge
   from task A to task B when A receives a `Sender` of a channel that B receives from.
   The nursery body counts as a task. A cycle produces warning **W0501**, naming the
   tasks and channels involved. **Theorem (informative):** if this graph is acyclic and
   tasks block only on `send`/`recv` of those channels, every task terminates or makes
   progress. A pipeline cannot deadlock.
3. **Runtime detection, all builds.** If every task of the process is blocked in
   `send`/`recv` and none can proceed, the runtime traps with kind `deadlock` and lists
   the blocked tasks and channels. Detection costs nothing until all workers are idle.

## 10.5 Atomics

`Atomic<T>` where `T` is an integer type of storage size 1, 2, 4 or 8, `bool`, `usize`,
`isize`, `*T` or `Handle<U>`:

```
init(v: T) -> Atomic<T>                       // e.g. `let n: Atomic<u64> = .init(0);`
load(self, order: MemOrder = .seq_cst) -> T
store(self, v: T, order: MemOrder = .seq_cst)
swap(self, v: T, order: MemOrder = .seq_cst) -> T
compare_exchange(self, expected: T, new: T, success: MemOrder = .seq_cst,
                 failure: MemOrder = .seq_cst) -> Result<T, T>
fetch_add / fetch_sub / fetch_and / fetch_or / fetch_xor / fetch_min / fetch_max
    (self, v: T, order: MemOrder = .seq_cst) -> T          // integers only
```

`MemOrder` is `.relaxed`, `.acquire`, `.release`, `.acq_rel` or `.seq_cst`, with the
semantics of the C11/C++20 memory model. That model is normative for atomic operations
and `@atomic_fence(order)`. Non-atomic accesses cannot race in safe code, so the model
never needs to define racing non-atomic accesses.

`Atomic<T>` is a **shared cell** (§5.1): it is never copied implicitly, needs no
release, may be stored in fixed arrays and slices (`[]Atomic<u32>`), and is passed to
read-only parameters as a view. Its methods take `self` (read-only), which is why
atomics may be shared among tasks. `Atomic` and `Channel` are the only types in safe Pyro with interior mutability.
Both are implemented in the standard library with `unsafe` code.

## 10.6 SIMD

### 10.6.1 Vector operations

On `vec<N, T>` (§4.3): `+ - * / %`, bitwise operators and shifts apply lane-wise, with the
scalar rules applied per lane, including overflow traps in checked builds. A scalar
operand is broadcast. Comparisons produce `mask<N>`.

```pyro
let a: vec4<f32> = .{ 1.0, 2.0, 3.0, 4.0 };
let b = a * 2.0 + vec4(0.5, 0.5, 0.5, 0.5);
let m = b > 4.0;                       // mask<4>
let c = @select(m, b, @splat(4, 0.0)); // lane-wise choose
let total = @reduce_add(c);            // f32
```

### 10.6.2 Swizzles

For `N ≤ 4`, field names `x y z w` (and the aliases `r g b a`) select lanes. Swizzles
of 1–4 letters produce a scalar (one letter) or a `vec` of that length, and may repeat
lanes: `v.xy`, `v.zyx`, `c.rgba`, `v.xxxx`. A swizzle without repeated lanes is an
assignable place: `v.xy = .{ 1.0, 2.0 }`. Mixing the two alphabets in one swizzle is an
error (**E0508**). For any `N`, `@shuffle(v, comptime [..]u32)` permutes lanes.

### 10.6.3 Reductions

`@reduce_add` and `@reduce_mul` on integer vectors are exact. On float vectors they
reduce in a fixed, documented tree order: pairwise halves, lane 0 leftmost. The result
is therefore deterministic but may differ from a left-to-right scalar sum. The
`std.simd.reduce_add_ordered(v)` function gives the strict left-to-right result.

### 10.6.4 Loop vectorization

Implementations should vectorize loops over slices and SoA data. A `for` loop marked
`@simd` **must** be vectorized, or compilation fails (**E0506**) with the reason (for
example a call to a non-inlinable function, a `break`, or a loop-carried dependency).
Vectorized loops behave exactly like their scalar expansion (§6.12). Remainder elements
that do not fill a vector (*tail peeling*) and unaligned heads are handled by the
compiler, never by the user.

A `@simd` loop, or a kernel argument, over a non-SoA slice of structs gets warning
**W0401**: "array-of-structs layout prevents efficient vectorization or GPU coalescing;
mark the struct `@soa` or use `soa []T`". The compiler never changes a declared layout
on its own.

```pyro
@simd
for p in particles where p.alive {
    p.x += p.vx * dt;
}
```

### 10.6.5 Width-agnostic SIMD

`@vector_width(T)` is the preferred native lane count for `T` on the compile target
(for example 16 for `f32` with AVX-512). Code written against it adapts per target:

```pyro
const W = @vector_width(f32);
fn scale(mut xs: []f32, k: f32) {
    let mut i: usize = 0;
    while i + W <= xs.len() {
        let v = simd.load(xs, i, W);           // vec<W, f32>
        simd.store(mut xs, i, v * k);
        i += W;
    }
    for x in xs[i..] { x *= k; }               // tail
}
```

`std.simd` provides `load`/`store` (bounds-checked), `load_masked` and `store_masked`
(§14.10).

## 10.7 `@no_alloc`

A function marked `@no_alloc` must not allocate, directly or through any function it
calls. Standard-library functions that allocate are marked `@allocates` (a
library-internal attribute, §14.3). The compiler checks the static call graph of the
`@no_alloc` function. Calling any function that is `@allocates` or not provably
non-allocating is an error (**E0507**), and so is calling through a function pointer.
`@no_alloc` on a `@test` makes the check part of the test.
