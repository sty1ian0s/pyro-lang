# 11. GPU Compute and Graphics

Pyro compiles CPU and GPU code from one source. Every GPU stage is an ordinary Pyro
function marked with a stage attribute: compute, vertex, fragment, task, mesh and the
ray-tracing stages. Stages share types with the rest of the program, and SoA data maps
directly to GPU buffers. There is no separate shader language and no shader text
compiled at runtime.

Structure of this chapter:

- §11.1: rules common to every stage;
- §11.2: compute kernels and `launch`;
- §11.3: vertex and fragment stages;
- §11.4: task and mesh stages;
- §11.5: ray tracing;
- §11.6: pipelines, submission and resource lifetime;
- §11.7: traps in GPU code;
- §11.8: compilation and backends.

Backends: **Vulkan 1.3** (SPIR-V 1.6), **Metal 3** (MSL 3.0) and **WebGPU** (WGSL).
`pyro.toml [gpu] backends` selects which are embedded (§13.2).

## 11.1 Rules common to all stages

### 11.1.1 Stages

| Attribute | Stage | Availability (device feature) |
|-----------|-------|-------------------------------|
| `@gpu_kernel(workgroup)` | compute | core |
| `@gpu_vertex` | vertex | core |
| `@gpu_fragment` | fragment | core |
| `@gpu_task(workgroup)` | task (amplification) | `.mesh_shaders` |
| `@gpu_mesh(workgroup, max_vertices, max_primitives)` | mesh | `.mesh_shaders` |
| `@gpu_ray_gen`, `@gpu_miss`, `@gpu_closest_hit`, `@gpu_any_hit`, `@gpu_intersection` | ray tracing | `.ray_tracing` |
| (`gpu.RayQuery` inside any stage) | inline ray queries | `.ray_query` |

"Core" means every backend supports it. If every configured backend lacks a feature
that a stage used by the program needs, it is a compile error (**E1004**). Otherwise,
creating the pipeline on a device without the feature returns `.err(.unsupported)`.

Geometry and tessellation stages are deliberately absent. Metal and WebGPU lack them,
and mesh shaders supersede them (appendix C, D-76).

`workgroup` is a comptime `u32` or a 3-tuple `(x, y, z)`. Its default is 64. The product
must be ≤ 1024 for compute and ≤ 128 (portable) for task and mesh stages (**E1002**).

### 11.1.2 Parameters

Every parameter of a stage function belongs to exactly one class:

| Class | Allowed types | Mode | Bound as |
|-------|---------------|------|----------|
| **uniform** | scalar, `vec`, plain struct without bit fields or pointers | read-only | member of the stage's uniform block |
| **storage** | `[]T`, `soa []T` (with `T` a uniform-class type or `Atomic<u32>`/`Atomic<i32>`) | read-only or `mut` | one storage buffer, or one per SoA column |
| **texture / sampler** | `gpu.Texture2D<F>`, `Texture3D<F>`, `TextureCube<F>`, `Texture2DArray<F>`, `DepthTexture2D`, `StorageTexture2D<F>`, `Sampler` | read-only (`mut` for storage textures) | texture/sampler binding |
| **acceleration structure** | `gpu.Tlas` | read-only | acceleration-structure binding |
| **stage-specific** | listed per stage: vertex input, `@instance`, fragment input, `@per_primitive`, task `mut payload`, mesh `mut out`, `@task_payload`, ray-tracing `payload`/`ray`/`hit`/`prim` | per stage | per stage |

Any other parameter is **E1001** in compute kernels and **E1008** in other stages.

**Pipeline-wide unification.** In a pipeline (§11.6), parameters of different stages
with the same name denote one binding. They must have the same type and class
(**E1009** otherwise). For example, `cam: Camera` in both a task and a mesh stage is one
uniform member.

**Argument order.** The `uniforms:` and `bindings:` arguments of submission calls
(§11.6.3) list the unified uniform-class and binding-class parameters, each in order of
first appearance. Stages are visited in pipeline order (task, mesh or vertex, fragment;
ray generation, miss stages in list order, hit groups in list order with intersection →
any-hit → closest-hit), and parameters left to right.

### 11.1.3 Body restrictions

In a stage function and everything it calls (*stage-reachable code*):

- no allocation, no `Arena`, no containers, no `Channel`, no I/O (**E1003**);
- no `nursery`, `spawn`, `parallel_for`, `launch` (**E1003**);
- no recursion, no function pointers, no `extern` calls, no `unsafe` (**E1003**);
- **binding resources** (textures, samplers, `Tlas`, storage slices) may appear only
  as read-only or `mut` parameters and arguments. They cannot be `move`d, deinitialized,
  stored or returned (**E1003**);
- **GPU-local types** `gpu.RayQuery` and `gpu.MeshOut` are neither plain, resource nor
  view. They are non-copyable values that exist only as locals or `mut` parameters of
  stage-reachable functions, and cannot be stored, returned or copied (**E1012**);
- `f64` arithmetic and 64-bit integers require device features `.shader_f64` /
  `.shader_i64`. Storage element columns of 1 or 2 bytes require `.storage_8bit` /
  `.storage_16bit` (**E1004**, by the rule of §11.1.1).

Ordinary functions satisfying these rules are callable from stages. They are compiled
for every stage and target that uses them.

### 11.1.4 Workgroup memory and barriers

Compute, task and mesh stages may declare **workgroup variables**:

```pyro
@workgroup let mut tile: [256]f32 = [0.0; 256];
@workgroup let mut count: Atomic<u32> = .init(0);
```

The type is a plain type, `Atomic<T>`, or a fixed array of either. The initializer is
executed by local invocation 0 and followed by an implicit barrier.
`@workgroup_barrier()` synchronizes all invocations of the workgroup. Every write to
workgroup memory before the barrier is visible to every invocation after it.

### 11.1.5 Uniform control flow

Barriers and the mesh/task synchronization points (`out.set_counts`, task emission)
must be reached by **all** invocations of a workgroup together. The compiler enforces a
simple, conservative rule (**E1013**):

1. `@workgroup_barrier()` and `out.set_counts(...)` may appear only as statements at
   the **top level** of the stage function body. That includes nested plain blocks and
   `inline for` / `comptime if`, but no `if`, `while`, `for` or `match` bodies, and no
   helper functions.
2. A stage function that contains any such statement, and every task stage, must not
   contain `return`, `?`, `break` or `continue` that leaves the stage body before the
   last such statement. Loops wholly between two barriers are fine.
3. A task stage has no `return` at all. Its result is the body's final expression
   (§11.4.2).

Traps never break uniformity, because a trapped invocation keeps participating (§11.7).

### 11.1.6 Storage writes and races

Writes to `mut` storage are allowed in every stage except vertex. Fragment-stage writes
require feature `.fragment_stores`, and vertex-stage writes are always **E1006**. Within
one dispatch or draw, the compiler accepts a write to a `mut` storage element only if
one of these holds, and otherwise reports **E1006**:

| Stage | Accepted non-atomic write index |
|-------|---------------------------------|
| compute | `@global_invocation_id.x as usize` (+ comptime `c`), or a local proven equal to it |
| task; mesh **without** task stage | same as compute |
| mesh **with** task stage | none: ids are relative to the emitting task workgroup (§11.4.3), so only atomic writes are allowed |
| ray generation | `gpu.linear_id(@launch_id, @launch_size) as usize` (+ comptime `c`) |
| miss, closest hit, any hit, intersection, fragment | none: atomic writes only |

**Atomic writes** are operations on `Atomic<T>` elements of a storage slice. They are
always allowed. Storage-texture stores follow the same table, with the 2-D index
`@global_invocation_id.xy` or `@launch_id.xy`.

**Workgroup memory** (between two barriers): a non-atomic write to a workgroup array is
accepted if its index is `@local_invocation_id.x as usize` (+ comptime `c`), or the
result of `count.fetch_add(k)` for a `@workgroup` atomic `count`. In the latter case
`k` must be a comptime integer ≥ 1, and `count` must receive no operation other than
`fetch_add` and `load` between the same two barriers (**E1006** otherwise). Reading
workgroup memory written by another invocation without an intervening barrier is a race
the compiler rejects by the same index rule. The same rule covers writes to a task
stage's `payload`.

### 11.1.7 Builtin variables

Builtin variables are written without parentheses (§3.8). Using one outside the
stages listed is **E1005**.

| Builtin | Type | Stages |
|---------|------|--------|
| `@global_invocation_id`, `@local_invocation_id`, `@workgroup_id`, `@num_workgroups` | `vec3<u32>` | compute, task, mesh |
| `@vertex_index`, `@instance_index` | `u32` | vertex |
| `@frag_coord` | `vec4<f32>` | fragment |
| `@front_facing` | `bool` | fragment |
| `@sample_index` | `u32` | fragment |
| `@launch_id`, `@launch_size` | `vec3<u32>` | ray tracing |

Builtin functions: `@workgroup_barrier()` (compute, task, mesh), and fragment-only
`@discard() -> noreturn`, `@dpdx(v)`, `@dpdy(v)`, `@fwidth(v)`.

## 11.2 Compute kernels and `launch`

```pyro
@soa
pub struct Particle { x: f32, y: f32, vx: f32, vy: f32 }

@gpu_kernel(workgroup: 64)
pub fn integrate(mut ps: []Particle, dt: f32) {
    let i = @global_invocation_id.x as usize;
    if i >= ps.len() { return; }
    ps[i].x += ps[i].vx * dt;
    ps[i].y += ps[i].vy * dt;
}
```

A kernel's return type is `void` (**E1001**). Kernels may take every parameter class
of §11.1.2 when dispatched through a `gpu.ComputePipeline` (§11.6.3). Through `launch`,
only uniform and storage parameters are allowed (**E1001**).

### 11.2.1 Dual compilation

Each kernel reachable from a `launch` is compiled twice:

1. **GPU form:** lowered from P-IR (appendix B) for each configured backend, validated
   at build time, and embedded in read-only data.
2. **CPU form:** the body is wrapped in loops over workgroups and local invocation ids
   and run as a `parallel_for` over workgroups, with the inner loop vectorized.
   `@workgroup_barrier()` splits the body into phases, each executed for all lanes
   before the next (loop fission). Workgroup memory becomes a per-task array.

Both forms must agree up to floating-point differences the device permits. `@law`
(§9.6.4) states tolerances.

### 11.2.2 Buffer layout

- Each `[]T` storage parameter is one buffer, laid out with std430 / WGSL storage
  rules. If `T`'s Pyro layout (§4.11.2) differs, `launch` converts through a staging
  copy. `@c_layout` with natural alignment, or SoA, avoids that.
- Each `soa []T` parameter, or `[]T` with `@soa` `T`, binds **one buffer per column**,
  in field order. Columns of 4- and 8-byte scalars match exactly, with no conversion.
- Uniform-class parameters form one uniform block (std140 / WGSL uniform rules).
- Binding numbers: set (bind group) 0 holds storage buffers in parameter order and then
  column order. Set 1, binding 0 holds the uniform block. Set 2 holds textures,
  samplers and acceleration structures in parameter order.

### 11.2.3 `launch`

```
launch gpu kernel(args) over n;
launch cpu kernel(args) over n;
launch gpu kernel(args);           // over = length of the first slice or Buffer argument
```

- `n: u32` (or `vec3<u32>` / `(u32, u32, u32)`) is the invocation count per axis.
  ⌈n / workgroup⌉ workgroups are dispatched per axis. Omitting `over` requires a slice
  or `Buffer` argument, whose length must fit in `u32` (it traps otherwise). Without one
  it is **E1007**.
- `mut` is written for `mut` parameters (§5.5.2).
- **Synchronous.** `launch gpu`:
  1. uploads slice arguments (a staging copy, or zero-copy on unified memory);
  2. dispatches;
  3. waits for completion and checks the trap record (§11.7);
  4. copies `mut` slice arguments back.
- With no suitable device, `launch gpu` runs the CPU form. A checked build warns once
  on stderr. `[gpu] fallback = false` makes it trap instead. `launch cpu` always runs
  the CPU form.
- **Resident buffers.** At a `launch`, an argument of type `gpu.Buffer<T>` binds to a
  `[]T` / `soa []T` parameter of the same mode. No copies occur. Data moves only through
  explicit `upload`/`download` (§14.11).

```pyro
let mut dev = gpu.Device.default()?;
defer dev.deinit();
let mut pos: gpu.Buffer<Particle> = .init(mut dev, particles.len())?;
defer pos.deinit();
pos.upload(particles);
for _ in 0..1000 { launch gpu integrate(mut pos, 0.016); }
pos.download(mut particles);
```

Device loss or device out-of-memory during `launch` traps with kind `explicit`. Programs
that must survive it use the `Result`-returning `std.gpu` API (§14.11) and
`dev.is_lost()`.

## 11.3 Vertex and fragment stages

### 11.3.1 Vertex stage

```pyro
@soa
pub struct MeshVertex { pos: vec3<f32>, normal: vec3<f32>, uv: vec2<f32> }
pub struct Instance { model: [4]vec4<f32>, tint: vec4<f32> }
pub struct Camera { view_proj: [4]vec4<f32> }

pub struct VsOut {
    @position clip: vec4<f32>,           // required, exactly one
    world_normal: vec3<f32>,             // interpolated, perspective-correct
    uv: vec2<f32>,
    @flat tint_id: u32,                  // integers must be @flat
}

fn mat4_mul_vec(m: [4]vec4<f32>, v: vec4<f32>) -> vec4<f32> {   // ordinary helper, inlined
    m[0] * v.x + m[1] * v.y + m[2] * v.z + m[3] * v.w
}

@gpu_vertex
fn vs_mesh(v: MeshVertex, @instance inst: Instance, cam: Camera) -> VsOut {
    let world = mat4_mul_vec(inst.model, vec4(v.pos.x, v.pos.y, v.pos.z, 1.0));
    VsOut { clip: mat4_mul_vec(cam.view_proj, world), world_normal: v.normal, uv: v.uv, tint_id: 0 }
}
```

- The first parameter is the **vertex input**: a plain struct of scalars and vectors.
  An `@soa` struct means one vertex stream per field. Otherwise it is one interleaved
  stream.
- An optional `@instance` parameter is the per-instance input (same rules).
- The return type is the **varyings** struct. It has exactly one `@position` field of
  type `vec4<f32>` (clip space). Other fields are `f32`, `i32` or `u32`, or vectors of
  them. Integer fields need `@flat`. Float fields may be `@flat` or `@linear` (no
  perspective correction).

### 11.3.2 Fragment stage

```pyro
pub struct Material { light_dir: vec3<f32>, ambient: f32 }

@gpu_fragment
fn fs_lit(i: VsOut, mat: Material, albedo: gpu.Texture2D<vec4<f32>>, smp: gpu.Sampler) -> vec4<f32> {
    let base = albedo.sample(smp, i.uv);
    if base.w < 0.01 { @discard(); }
    let n_dot_l = math.max(simd.dot(simd.normalize(i.world_normal), mat.light_dir), 0.0);
    base * (mat.ambient + n_dot_l)
}
```

- The first parameter is the **fragment input**. Its type equals the varyings type of
  the preceding vertex or mesh stage (**E1009**). With a mesh stage, an optional
  parameter marked `@per_primitive` receives the per-primitive struct (§11.4.3).
- The return type is `vec4<f32>` (one color target), or a struct whose fields are
  marked `@target(n)` (n = 0..7), plus at most one `@depth f32` field.
- Texture methods:
  - `sample(s, uv)` and `sample_bias(s, uv, b)`: implicit level of detail, fragment
    only (**E1008**);
  - `sample_level(s, uv, lod)` and `sample_grad(s, uv, ddx, ddy)`: any stage;
  - `sample_compare(s, uv, ref)`: depth textures;
  - `load(coord, mip)` and `dims(mip)`: any stage;
  - `store(coord, v)`: storage textures, subject to §11.1.6.

## 11.4 Task and mesh stages

These map to `VK_EXT_mesh_shader` on Vulkan and to object/mesh functions on Metal 3,
and require feature `.mesh_shaders`. They are not available on WebGPU.

### 11.4.1 Execution model

`pass.draw_mesh_tasks(pipeline, …, groups: vec3<u32>)` (§11.6.3) runs:

1. **Task stage (optional):** `groups.x·y·z` task workgroups. Each one produces a
   payload and a mesh-grid size.
2. **Mesh stage:** for each task workgroup, the mesh workgroups it requested.
   Without a task stage, `groups` mesh workgroups run directly. Each mesh workgroup
   emits up to `max_vertices` vertices and `max_primitives` primitives.
3. Non-culled primitives are rasterized and shaded by the fragment stage (§11.4.4).

Workgroups run concurrently, in unspecified order.

### 11.4.2 Task stage

```pyro
pub struct Meshlet {
    center: vec3<f32>, radius: f32,
    vertex_offset: u32, vertex_count: u32,     // ≤ 64
    index_offset: u32, triangle_count: u32,    // ≤ 124
    material: u32,
}
pub struct CullPayload { visible: [32]u32 }

fn sphere_visible(center: vec3<f32>, radius: f32, cam: Camera) -> bool { ... }

@gpu_task(workgroup: 32)
fn ts_cull(mut payload: CullPayload, meshlets: []Meshlet, cam: Camera) -> vec3<u32> {
    @workgroup let mut count: Atomic<u32> = .init(0);
    let i = @global_invocation_id.x as usize;
    if i < meshlets.len() && sphere_visible(meshlets[i].center, meshlets[i].radius, cam) {
        let slot = count.fetch_add(1);
        payload.visible[slot as usize] = i as u32;
    }
    @workgroup_barrier();
    vec3(count.load(), 1, 1)                 // mesh workgroups to launch
}
```

- Signature: the first parameter is `mut payload: P`, where `P` is a plain struct. The
  payload is workgroup-shared and zero-initialized. Writes to it follow the
  workgroup-memory rule of §11.1.6. The remaining parameters are uniform or binding
  class. The return type is `vec3<u32>`, given by the body's final expression
  (§11.1.5 rule 3).
- **Emission.** After the body, the compiler inserts a barrier. The grid size is the
  value computed by **local invocation 0**, and the values of other invocations are
  ignored. If invocation 0 trapped, the grid is (0, 0, 0). A zero component launches
  nothing.
- Limits: §11.4.5. A grid above the limits is a device trap of kind `gpu_limit`
  (§11.7).

### 11.4.3 Mesh stage

```pyro
pub struct MeshletPrim { material: u32 }

fn project(v: MeshVertex, cam: Camera) -> VsOut { ... }

@gpu_mesh(workgroup: 64, max_vertices: 64, max_primitives: 124)
fn ms_meshlet(
    mut out: gpu.MeshOut<VsOut, MeshletPrim, 64, 124>,
    @task_payload payload: CullPayload,
    meshlets: []Meshlet, vertices: soa []MeshVertex, indices: []u32, cam: Camera,
) {
    let m = meshlets[payload.visible[@workgroup_id.x as usize] as usize];
    out.set_counts(m.vertex_count, m.triangle_count);
    let t = @local_invocation_id.x;
    if t < m.vertex_count {
        out.vertex(t, project(vertices[(m.vertex_offset + t) as usize], cam));
    }
    inline for k in 0..2 {                               // 124 primitives, 64 invocations
        let p = t + 64 * k;
        if p < m.triangle_count {
            let b = (m.index_offset + 3 * p) as usize;
            out.triangle(p, vec3(indices[b], indices[b + 1], indices[b + 2]));
            out.primitive(p, MeshletPrim { material: m.material });
        }
    }
}
```

- Attribute: `@gpu_mesh(workgroup: n, max_vertices: VM, max_primitives: PM)`.
- First parameter: `mut out: gpu.MeshOut<V, Prim, VM, PM>`. Its generic arguments must
  equal the attribute values (**E1010**).
  - `V` follows the varyings rules (§11.3.1).
  - `Prim` is a plain struct, or `void`. Its fields are implicitly `@flat`, and may be
    the builtins `@primitive_id: u32`, `@layer: u32`, `@viewport_index: u32` and
    `@cull_primitive: bool` (true discards the primitive before rasterization).
- If the pipeline has a task stage, exactly one parameter marked `@task_payload` has the
  task stage's payload type (**E1009**). If it has no task stage, a `@task_payload`
  parameter is **E1010**.
- **IDs.** With a task stage, `@workgroup_id`, `@num_workgroups` and
  `@global_invocation_id` are relative to the mesh grid emitted by the *current task
  workgroup*. They are not globally unique (hence §11.1.6).
- **Topology** comes from the pipeline: `.triangle_list` (`out.triangle(i, vec3<u32>)`),
  `.line_list` (`out.line(i, vec2<u32>)`) or `.point_list` (`out.point(i, u32)`). A
  method that doesn't match the topology is **E1010**.
- **`out.set_counts(nv: u32, np: u32)`** is called exactly once, as a top-level
  statement (§11.1.5), before any other `out` call in program order (**E1010**,
  **E1013**). All invocations evaluate it, the value of local invocation 0 is used, and
  it implies a barrier.
- `out.vertex(i, v)`, `out.triangle/line/point(i, idx)` and `out.primitive(i, p)` write
  slot `i`. Requirements:
  - `i < nv` for vertices and `i < np` for primitives;
  - every vertex index in `idx` is `< nv`;
  - `nv ≤ VM` and `np ≤ PM`.

  Violations are device traps of kind `bounds` (§11.7), and the write is suppressed.
  The slot index must satisfy the workgroup race rule of §11.1.6, with
  `@local_invocation_id.x` (+ comptime `c`). Every slot below the counts must be written
  on every path. Unwritten counted slots have unspecified contents and are still
  rasterized. The compiler warns when it cannot prove full coverage (**W1002**).

### 11.4.4 Fragment stage of mesh pipelines

As in §11.3.2, with the input type `V`, plus an optional `@per_primitive prim: Prim`
parameter.

### 11.4.5 Limits

Portable minimums. Larger values exist on many devices and are queried with
`dev.limits()`. A pipeline exceeding a minimum compiles with warning **W1001**, and
`init` returns `.err(.limits)` on devices that lack it.

| Limit | Portable minimum |
|-------|-----------------:|
| task / mesh workgroup invocations | 128 |
| `max_vertices` / `max_primitives` | 256 / 256 |
| task payload size | 16 384 B |
| task payload + task `@workgroup` memory | 32 768 B |
| mesh `@workgroup` memory + task payload | 28 672 B |
| mesh output size (`VM·sizeof(V) + PM·sizeof(Prim)`, after varying elimination) | 32 768 B |
| mesh grid emitted by one task workgroup (product) | 1 024 |
| `draw_mesh_tasks` groups per dimension / product | 65 535 / 4 194 304 |

## 11.5 Ray tracing

Ray tracing maps to `VK_KHR_ray_tracing_pipeline`, `VK_KHR_acceleration_structure` and
`VK_KHR_ray_query` on Vulkan, and to Metal's ray-tracing API on Metal (§11.5.7). It is
not available on WebGPU. Features: `.ray_tracing` (pipelines), `.ray_query` (inline
queries), `.ray_primitive_culling` (the `skip_triangles`/`skip_aabbs` flags).

### 11.5.1 Acceleration structures

Two levels, both device-resident resources:

```pyro
pub enum Geometry { triangles(TriangleGeometry), aabbs(AabbGeometry) }

pub struct TriangleGeometry {
    pub mut vertices: gpu.BufferRef<vec3<f32>>,    // stride 16 bytes (vec3 layout, §4.3.1)
    pub mut vertex_count: u32,
    pub mut indices: Option<gpu.BufferRef<u32>> = .none,   // triples; .none = non-indexed
    pub mut index_count: u32 = 0,
    pub mut opaque_: bool = true,                  // false: any-hit stages run
}
pub struct AabbGeometry {
    pub mut boxes: gpu.BufferRef<gpu.Aabb>,        // Aabb { min: vec3<f32>, max: vec3<f32> }
    pub mut count: u32,
    pub mut opaque_: bool = true,
}
pub struct Instance {
    pub mut blas: gpu.BlasRef,
    pub mut transform: [3]vec4<f32>,               // row-major 3×4, object → world
    pub mut custom_index: u24 = 0,
    pub mut mask: u8 = 0xFF,
    pub mut hit_group_offset: u24 = 0,
    pub mut flags: InstanceFlags = .{ .. },
}
pub struct InstanceFlags {
    pub mut disable_culling: bool = false,
    pub mut flip_facing: bool = false,
    pub mut force_opaque: bool = false,            // at most one of these two
    pub mut force_no_opaque: bool = false,
}
pub enum BuildPreference { fast_trace, fast_build }
pub struct BuildOptions {
    pub mut prefer: BuildPreference = .fast_trace,
    pub mut allow_update: bool = false,
    pub mut allow_compaction: bool = false,
}
```

`gpu.BufferRef<T>` (from `buf.ref()`) and `gpu.BlasRef` (from `blas.ref()`) are plain,
generation-checked references, so geometry descriptors are plain data.

| Operation | Semantics |
|-----------|-----------|
| `gpu.Blas.build(mut dev, geometry: []Geometry, opts: BuildOptions) -> Result<Blas, GpuError>` | builds and waits. Inputs may change afterwards. Errors: `.stale_buffer`, `.bad_geometry` (index out of range, count mismatch, mixed geometry kinds in one Blas), `.limits` |
| `gpu.Tlas.build(mut dev, instances: []Instance, opts: BuildOptions) -> Result<Tlas, GpuError>` | errors: `.stale_blas`, `.invalid_instance` (both force flags set), `.limits` |
| `Blas.refit(mut self, mut dev, geometry: []Geometry) -> Result<void, GpuError>`; `Tlas.refit(mut self, mut dev, instances: []Instance) -> Result<void, GpuError>` | fast update. Needs `allow_update` and identical counts, kinds and Blas set, else `.err(.bad_geometry)` |
| `Blas.compact(move self, mut dev) -> Result<Blas, (Blas, GpuError)>`, same for `Tlas` | needs `allow_compaction`. On error the original is returned |
| `Blas.ref(self) -> BlasRef` | |
| `deinit(move self)` | deferred (§11.6.4) |

Limits (portable minimums): 2²⁴ geometries per Blas, 2²⁹ primitives per Blas, 2²⁴
instances per Tlas.

**Lifetime.** A Tlas keeps the Blases it was built (or refit) from alive. Every GPU
resource's `deinit` is **deferred** until all submitted GPU work referencing it has
completed (§11.6.4). So a trace can never reach freed geometry or buffers.

### 11.5.2 Ray-tracing pipelines

A pipeline is described by comptime data. Stage functions are referenced as
`std.meta.FnRef` values: a function name converts implicitly to `FnRef` where one is
expected (§4.9.1 rule 9).

```pyro
pub struct Shade { color: vec3<f32>, shadowed: bool }

const RtPipeline = gpu.RayPipeline(.{
    ray_gen: rg_camera,
    miss: [miss_sky, miss_shadow],                                       // miss indices 0, 1
    hit_groups: [
        .{ closest: hit_lambert, .. },                                   // 0: opaque triangles
        .{ closest: hit_lambert, any: any_alpha, .. },                   // 1: alpha-tested
        .{ closest: hit_sphere, intersection: isect_sphere, .. },        // 2: procedural spheres
    ],
    max_recursion: 2,
    ..
});
```

`gpu.RayPipeline(comptime d: RayPipelineDesc) -> type`, with:

```pyro
pub struct RayPipelineDesc {
    pub mut ray_gen: FnRef,
    pub mut miss: []FnRef = [],
    pub mut hit_groups: []HitGroup = [],
    pub mut max_recursion: u8 = 1,
}
pub struct HitGroup {
    pub mut closest: Option<FnRef> = .none,
    pub mut any: Option<FnRef> = .none,
    pub mut intersection: Option<FnRef> = .none,   // present = procedural group
}
```

Comptime checks (**E1009** unless noted):

- every referenced function has the stage attribute matching its role;
- every miss, closest-hit and any-hit stage has the same payload type `P`, a plain struct
  of at most 256 bytes (**E1011**);
- a triangle group's attribute type `A` is `gpu.Barycentrics` (`vec2<f32>`), and a
  procedural group's `A` is its intersection stage's attribute type. Within a group,
  `closest` and `any` use that `A`, which must be plain and at most 32 bytes
  (**E1011**);
- `max_recursion` is in 1..=31 (**E1011**). Values above 1 exceed the portable minimum
  (**W1001**) and need `dev.limits().max_ray_recursion`;
- at most 2¹⁶ miss stages and 2²⁴ hit groups (**E1011**).

The shader binding table is generated at `init` from the pipeline type. Users never lay
out SBT records.

### 11.5.3 Stage signatures

| Stage | Signature |
|-------|-----------|
| ray generation | `@gpu_ray_gen fn (params…)` |
| miss | `@gpu_miss fn (mut payload: P, ray: gpu.RayInfo, params…)` |
| closest hit | `@gpu_closest_hit fn (mut payload: P, hit: gpu.Hit<A>, params…)` |
| any hit | `@gpu_any_hit fn (mut payload: P, hit: gpu.Hit<A>, params…) -> gpu.AnyHit` |
| intersection | `@gpu_intersection fn (ray: gpu.RayInfo, prim: gpu.PrimitiveInfo, params…) -> Option<(f32, A)>` |

`params…` are uniform- and binding-class parameters (§11.1.2), unified across the whole
pipeline. All stages have `@launch_id` and `@launch_size`.

```pyro
pub struct RayInfo {
    pub origin: vec3<f32>, pub direction: vec3<f32>,     // world space
    pub t_min: f32, pub t_max: f32,                      // t_max = current closest t
    pub flags: RayFlags,
}
pub struct PrimitiveInfo {
    pub instance_index: u32, pub instance_custom_index: u32,
    pub geometry_index: u32, pub primitive_index: u32,
    pub object_to_world: [3]vec4<f32>, pub world_to_object: [3]vec4<f32>,
    pub object_origin: vec3<f32>, pub object_direction: vec3<f32>,
}
pub enum HitKind { front_face, back_face, procedural }
pub struct Hit<A> { pub t: f32, pub attributes: A, pub kind: HitKind, pub prim: PrimitiveInfo, pub ray: RayInfo }
pub enum AnyHit { accept, ignore, accept_and_end }
```

Example stages for the pipeline above:

```pyro
const SUN_DIR: vec3<f32> = .{ 0.3, 0.9, 0.3 };

@gpu_ray_gen
fn rg_camera(scene: gpu.Tlas, cam: Camera, mut image: []vec4<f32>) {
    let mut s = Shade { color: vec3(0.0, 0.0, 0.0), shadowed: false };
    gpu.trace_ray(scene, camera_ray(cam, @launch_id.xy, @launch_size.xy), mut s, .{ .. });
    image[gpu.linear_id(@launch_id, @launch_size) as usize] = vec4(s.color.x, s.color.y, s.color.z, 1.0);
}

@gpu_miss fn miss_sky(mut s: Shade, ray: gpu.RayInfo) { s.color = sky(ray.direction); }
@gpu_miss fn miss_shadow(mut s: Shade, ray: gpu.RayInfo) { s.shadowed = false; }

@gpu_closest_hit
fn hit_lambert(mut s: Shade, hit: gpu.Hit<gpu.Barycentrics>, scene: gpu.Tlas) {
    let p = hit.ray.origin + hit.ray.direction * hit.t;
    s.shadowed = true;                                 // the shadow ray's miss stage resets it
    gpu.trace_ray(scene, .{ origin: p, t_min: 0.001, direction: SUN_DIR, t_max: 1.0e30 }, mut s,
                  .{ miss: 1, flags: .{ terminate_on_first_hit: true, skip_closest_hit: true, .. }, .. });
    s.color = if s.shadowed { vec3(0.1, 0.1, 0.1) } else { vec3(0.9, 0.9, 0.9) };
}
// any_alpha, hit_sphere, isect_sphere, camera_ray and sky are ordinary definitions, omitted
```

Stage behaviour:

- **Intersection:** called for AABBs reached by traversal in procedural groups. It
  reports at most one candidate per call: `.some((t, attrs))`, accepted only if
  `ray.t_min ≤ t ≤ ray.t_max`. To report several intersections, return the nearest one
  in range. This is the portable subset of Vulkan and Metal.
- **Any hit:** called for candidate hits on non-opaque geometry, in unspecified order,
  possibly more than once per primitive. `.accept` commits the hit (narrowing `t_max`),
  `.ignore` discards it, and `.accept_and_end` commits it and ends traversal. Payload
  writes are visible to later stages of the same trace.
- **Closest hit:** runs once with the closest committed hit, unless
  `skip_closest_hit` is set. **Miss:** runs once if nothing was committed.
- `gpu.trace_ray` may be called only from ray-generation, closest-hit and miss stages
  (**E1012**).

### 11.5.4 `trace_ray`

```pyro
pub fn trace_ray<P>(tlas: gpu.Tlas, ray: gpu.Ray, mut payload: P, opts: TraceOptions = .{ .. })

pub struct Ray { pub mut origin: vec3<f32>, pub mut t_min: f32, pub mut direction: vec3<f32>, pub mut t_max: f32 }
pub struct TraceOptions {
    pub mut flags: RayFlags = .{ .. },
    pub mut cull_mask: u8 = 0xFF,
    pub mut hit_group: u4 = 0,          // SBT offset
    pub mut geometry_stride: u4 = 0,    // SBT stride
    pub mut miss: u16 = 0,              // index into the miss list
}
pub struct RayFlags {
    pub mut force_opaque: bool = false,  pub mut force_no_opaque: bool = false,
    pub mut cull_opaque: bool = false,   pub mut cull_no_opaque: bool = false,
    pub mut terminate_on_first_hit: bool = false, pub mut skip_closest_hit: bool = false,
    pub mut cull_back_facing: bool = false, pub mut cull_front_facing: bool = false,
    pub mut skip_triangles: bool = false, pub mut skip_aabbs: bool = false,
}
```

- **Synchronous** within the invocation. When it returns, the selected stages have run
  and `payload` holds their writes. The nesting depth is checked against
  `max_recursion` (trap kind `ray_recursion`).
- An instance is considered only if `(instance.mask & opts.cull_mask) != 0`.
- **Hit group** = `instance.hit_group_offset + opts.hit_group + opts.geometry_stride ×
  geometry_index`. **Miss** = `opts.miss`. A miss index outside the miss list is a
  device trap of kind `bounds`. The hit-group index is computed by fixed-function
  traversal, so the runtime pads the shader binding table at dispatch up to the largest
  index reachable from the bound Tlas: the maximum over instances of
  `hit_group_offset + 15 + 15 × (geometry_count − 1)`. The Tlas caches this value at
  build. Padding records run a built-in stage that raises a `bounds` device trap. No
  out-of-range table access can occur.
- **Flag rules.** At most one of {`force_opaque`, `force_no_opaque`, `cull_opaque`,
  `cull_no_opaque`}, at most one of the two cull-facing flags, and at most one of the
  two skip flags. A violation is **E1012** when comptime-known, otherwise a device trap
  of kind `gpu_limit`. `skip_triangles`/`skip_aabbs` require `.ray_primitive_culling`.
- **Ray validity.** `t_max = +inf` is treated as `f32.MAX`. A ray is *invalid* if
  `origin` or `direction` has a non-finite component, `t_min` is NaN or negative, or
  `t_min > t_max`. An invalid ray hits nothing: the selected miss stage runs (a `bounds`
  device trap if `opts.miss` is out of range) with the original values in `RayInfo`.
  The compiler lowers this check to a branch that issues a finite dummy ray with
  `cull_mask = 0`, so no backend ever sees non-finite inputs.
- `t` values are in units of `|direction|`, which need not be normalized.

### 11.5.5 Ray queries

With feature `.ray_query`, compute, fragment and ray-tracing stages can trace inline:

```pyro
fn in_shadow(scene: gpu.Tlas, p: vec3<f32>, to_light: vec3<f32>) -> bool {
    let mut q: gpu.RayQuery = .init(scene, .{ origin: p, t_min: 0.001, direction: to_light, t_max: 1.0 },
                                    .{ flags: .{ terminate_on_first_hit: true, .. }, .. });
    while q.proceed() {
        match q.candidate() {
            .triangle(_) => q.commit_triangle(),
            .aabb(info) => { if let .some(t) = sphere_t(info) { q.commit_aabb(t); } },
        }
    }
    q.committed().is_some()
}
```

| Method | Semantics |
|--------|-----------|
| `RayQuery.init(tlas, ray: Ray, opts: TraceOptions) -> RayQuery` | starts traversal. `hit_group`, `geometry_stride` and `miss` are ignored. Invalid rays (§11.5.4) produce no candidates |
| `proceed(mut self) -> bool` | advance. `false` when traversal is complete |
| `candidate(self) -> Candidate` | `enum Candidate { triangle(Hit<Barycentrics>), aabb(PrimitiveInfo) }`: non-opaque triangles and AABBs |
| `commit_triangle(mut self)` | accept the current triangle candidate |
| `commit_aabb(mut self, t: f32)` | accept an AABB hit at `t` (ignored outside `[t_min, t_max]`) |
| `abort(mut self)` | end traversal |
| `committed(self) -> Option<Committed>` | `enum Committed { triangle(Hit<Barycentrics>), aabb(Hit<void>) }` |

Opaque triangles are committed automatically and never appear as candidates.
`RayQuery` is a GPU-local type (§11.1.3). Calling `candidate`/`commit_*` after
`proceed` returned `false`, or `commit_triangle` on an AABB candidate, is a device trap
of kind `bounds`.

### 11.5.6 Dispatch

`encoder.trace_rays(pipeline, uniforms: .{…}, bindings: .{…}, size: vec3<u32>)` launches
`size.x·y·z` ray-generation invocations. Portable limits: 65 535 per dimension, 2³⁰ in
total. Ray tracing has no CPU fallback: `RayPipeline.init` returns `.err(.no_device)` or
`.err(.unsupported)`.

### 11.5.7 Lowering

- **Vulkan:** one SPIR-V entry point per stage (`RayGenerationKHR`, `MissKHR`,
  `ClosestHitKHR`, `AnyHitKHR`, `IntersectionKHR`). `trace_ray` lowers to
  `OpTraceRayKHR`, with `hit_group`/`geometry_stride` as SBT offset/stride (4 bits) and
  `miss` as miss index (16 bits). The payload is a `RayPayloadKHR` variable. The SBT has
  one record per group plus padding (§11.5.4).
- **Metal:** ray generation becomes a compute kernel. Intersection and any-hit stages
  become intersection functions in an intersection function table indexed by hit
  group. Because the pipeline is known at compile time, `trace_ray` becomes an
  `intersector` call followed by a **static `switch`** over hit group / miss index that
  calls the closest-hit or miss stage. For `max_recursion ≤ 2`, nested levels are
  inlined. Above that, closest-hit and miss stages become visible functions called
  through a visible-function table, with the call-stack depth set from
  `max_recursion`.
- On every backend, the same stages run for the same hits with the same payload results,
  up to floating-point differences in traversal.

## 11.6 Pipelines, submission and resource lifetime

### 11.6.1 Pipelines are comptime types

```pyro
const LitPipeline = gpu.RenderPipeline(.{
    vertex: vs_mesh,
    fragment: fs_lit,
    topology: .triangle_list,
    cull: .back,
    depth: .{ format: .depth32f, compare: .less, write: true },
    color: [.{ format: .bgra8_srgb, blend: .alpha, .. }],
    ..
});
const MeshletPipeline = gpu.RenderPipeline(.{ task: ts_cull, mesh: ms_meshlet, fragment: fs_meshlet, .. });
const Integrate = gpu.ComputePipeline(integrate);
```

`gpu.RenderPipeline(comptime d: RenderPipelineDesc) -> type`:

```pyro
pub struct RenderPipelineDesc {
    pub mut vertex: Option<FnRef> = .none,       // exactly one of vertex / mesh
    pub mut task: Option<FnRef> = .none,         // requires mesh
    pub mut mesh: Option<FnRef> = .none,
    pub mut fragment: Option<FnRef> = .none,     // .none = depth-only pipeline
    pub mut topology: Topology = .triangle_list, // triangle_list | triangle_strip | line_list | line_strip | point_list
    pub mut cull: CullMode = .none,              // none | front | back
    pub mut front_face: FrontFace = .ccw,        // ccw | cw
    pub mut depth: Option<DepthState> = .none,   // DepthState { format, compare, write: bool }
    pub mut color: []ColorTarget = [],           // ColorTarget { format, blend: Blend = .replace, write_mask: u4 = 0xF }
    pub mut samples: u8 = 1,
    pub mut specialize: []SpecConst = [],        // SpecConst { name: str, value: ConstValue }
}
```

The comptime checks (**E1009**) cover: stage roles, fragment input type, color target
count and formats against the fragment return type, depth output needing a depth
format, strip topologies being illegal with mesh stages, unified parameters (§11.1.2),
and feature availability (§11.1.1). Each pipeline type has
`init(mut dev: Device) -> Result<Self, GpuError>`, which creates the driver pipeline from
the embedded shaders and caches it per device. `gpu.ComputePipeline(kernel)` and
`gpu.RayPipeline(desc)` work the same way.

### 11.6.2 Specialization

A `specialize` entry `.{ name: "N", value: .u32(8) }` substitutes the comptime constant
`N` in every stage that declares `const N: u32 = @spec("N", 4);` (the default applies
when the pipeline gives no value). Each distinct combination is one embedded shader
variant. `pyro build --gpu-report` lists all variants.

### 11.6.3 Recording and submission

```pyro
let mut frame = surface.next_frame(mut dev)?;
let mut pass = frame.begin_pass(.{ clear: .some(vec4(0.0, 0.0, 0.0, 1.0)), depth_clear: .some(1.0), .. });
pass.draw(lit, vertices: mesh_vb, instances: .some(inst_buf),
          uniforms: .{ cam, mat }, bindings: .{ albedo_tex, sampler },
          vertex_count: mesh_vb.len() as u32, instance_count: inst_buf.len() as u32);
pass.end();
frame.present();
```

Submission calls are generic over the comptime pipeline type, and their argument types
are checked against the unified stage parameters at compile time (**E1009**):

```
RenderPass.draw<Pl, V, I, U, B>(mut self, p: Pl, vertices: gpu.Buffer<V>,
    instances: Option<gpu.Buffer<I>> = .none, uniforms: U, bindings: B,
    vertex_count: u32, instance_count: u32 = 1, first_vertex: u32 = 0)
RenderPass.draw_indexed<Pl, V, I, U, B>(mut self, p: Pl, vertices: gpu.Buffer<V>,
    indices: gpu.Buffer<u32>, instances: Option<gpu.Buffer<I>> = .none, uniforms: U,
    bindings: B, index_count: u32, instance_count: u32 = 1, first_index: u32 = 0)
RenderPass.draw_mesh_tasks<Pl, U, B>(mut self, p: Pl, uniforms: U, bindings: B, groups: vec3<u32>)
Encoder.dispatch<Pl, U, B>(mut self, p: Pl, uniforms: U, bindings: B, groups: vec3<u32>)
Encoder.trace_rays<Pl, U, B>(mut self, p: Pl, uniforms: U, bindings: B, size: vec3<u32>)
```

`U` and `B` are tuples in the order defined in §11.1.2. A `gpu.Buffer` of an `@soa` type
binds one stream or storage buffer per column. Storage-class arguments are
`gpu.Buffer<T>` values. Encoders come from `dev.encoder() -> Encoder` and are submitted
with `submit(move self)`.

### 11.6.4 Ordering, completion and lifetime

- Commands execute on the device queue in submission order. `Buffer.upload`,
  `Texture.upload` and acceleration-structure builds are ordered on the same queue, so
  a CPU upload after a submission never races with it.
- **Completion points** (the host waits for prior work): `launch` returning, `download`
  calls, `Blas`/`Tlas` builds, `refit`, `compact`, `Surface.next_frame` (waits for the
  frame that last used the same swap-chain image), `dev.wait_idle()` and
  `dev.is_lost()`.
- **Deferred destruction.** Every GPU resource's `deinit` releases host ownership
  immediately but frees device memory only after all submitted work referencing it has
  completed. Premature destruction is therefore impossible.

### 11.6.5 Cross-stage optimizer (zero-cost layer)

A whole pipeline is known at compile time, so stages are optimized **together**:

1. **Varying elimination.** Outputs not read by the fragment stage are removed, along
   with their computation. Mesh output size (§11.4.5) is measured after this step.
2. **Dead stream elimination.** Vertex-input fields no stage reads are neither fetched
   nor bound. With `@soa` vertex data, their buffers are not bound at all.
3. **Specialization folding** of `@spec` constants (§11.6.2).
4. **Uniform packing.** Unused uniforms are dropped, and the block is laid out once
   per pipeline.
5. **Helper inlining and comptime folding** of shared ordinary functions.
6. **Build-time validation.** Generated SPIR-V/MSL/WGSL is validated during the build,
   and failures are reported as Pyro errors at Pyro source locations.

`std.gfx` builds 2-D shapes and SDF vector graphics, text, sprites, an instanced 3-D
renderer and UI primitives from ordinary pipelines and buffers. It is therefore
zero-cost relative to hand-written pipelines, and `--expand` shows what it generates.

## 11.7 Traps in GPU code

Bounds checks, overflow checks (checked builds), `assert`, `@trap` and the device traps
of this chapter also apply on the GPU. A device cannot stop the process, so:

1. An invocation that hits a trap condition records `(kind, source location)` in the
   device's trap record. The first writer wins, via an atomic compare-exchange.
2. The invocation becomes a **zombie**. It performs no further side effects (storage,
   texture and workgroup writes, atomics, mesh outputs, payload writes, `trace_ray`
   calls are suppressed), but it still takes part in every barrier, `set_counts` and
   task emission, so uniform control flow is preserved. A zombie task invocation 0
   emits a (0, 0, 0) grid. A zombie invocation 0 of a mesh workgroup contributes counts
   (0, 0). Writes made before the trap remain.
3. A trap inside a miss, hit or intersection stage marks the whole trace as trapped.
   `trace_ray` returns, and the calling invocation becomes a zombie.
4. At the next **completion point** (§11.6.4) that covers the work, the runtime reads the
   trap record. If it is set, the process traps (§9.4) with the recorded kind, the
   location, and the suffix `" (on GPU)"`.

Trap kinds used on the GPU: `bounds` (indices, slots, miss/hit routing, ray-query
misuse), `overflow`, `div_zero`, `shift`, `assert`, `explicit`, `ray_recursion`, and
`gpu_limit` (grid and count limits, invalid runtime ray flags). In unchecked builds,
overflow and shift checks are absent. Bounds checks and device traps remain.

The trap record is one small buffer per device. Recording costs one atomic operation
on the failing path, and the zombie flag is one register.

## 11.8 Compilation and backends

- Stages reachable from `launch`, pipeline types or `std.gfx` are compiled at build
  time from P-IR to SPIR-V 1.6 (Vulkan), MSL 3.0 (Metal) and WGSL (WebGPU), as
  configured. Each is validated and embedded. Driver pipeline creation happens at
  `init` and is cached per device.
- Floating point follows the device's IEEE conformance. `@fast_math` on a stage permits
  the device's fast instructions.
- Stages that a backend cannot express (mesh and ray tracing on WebGPU) are not emitted
  for that backend. Their pipelines' `init` returns `.err(.unsupported)` there.
