//! GPU stage functions (§11.1.1, §11.1.2, §11.2).
//!
//! A function with a stage attribute (`@gpu_kernel`, `@gpu_vertex`, ...) is
//! a stage function. `check` finds every one, after item checking and
//! `attrs.check` (which validates the shape of attribute arguments), and:
//!
//! - evaluates its workgroup size (compute, task, mesh; default 64) and
//!   checks the product: at most 1024 for compute, 128 for task and mesh,
//!   and not zero (**E1002**);
//! - puts each parameter in its §11.1.2 class: uniform, storage,
//!   texture/sampler, acceleration structure or stage-specific. Any other
//!   parameter is **E1001** in a compute kernel and **E1008** elsewhere;
//! - checks that a compute kernel returns `void` (**E1001**, §11.2).
//!
//! Stage-specific slots are recognised by position and attribute with a
//! structural check of their type. The full per-stage rules (varyings,
//! `MeshOut` arguments, payload matching across stages) belong to the
//! stage tasks (raster, mesh, ray tracing), which read the classification
//! returned here. Which parameters `launch` accepts is checked at `launch`.

const std = @import("std");
const Writer = std.Io.Writer;
const Ast = @import("../ast/Ast.zig");
const attr_table = @import("../attr_table.zig");
const diag = @import("../diag/diag.zig");
const module_graph = @import("../resolve/module_graph.zig");
const Types = @import("../sema/types.zig");
const items_mod = @import("../sema/items.zig");
const attrs = @import("../sema/attrs.zig");
const kinds = @import("../sema/kinds.zig");
const layout = @import("../sema/layout.zig");
const builtins = @import("../sema/builtins.zig");

const Items = items_mod.Items;
const Node = Ast.Node;
const TypeId = Types.TypeId;
const ModuleId = module_graph.ModuleId;
const Error = std.mem.Allocator.Error;

pub const Stage = builtins.Stage;

/// The default workgroup size (§11.1.1).
pub const default_workgroup = 64;

/// A parameter class (§11.1.2).
pub const Class = enum { uniform, storage, texture_sampler, acceleration_structure, stage_specific };

/// One classified parameter of a stage function.
pub const Param = struct {
    name: []const u8,
    mode: items_mod.Mode,
    /// Null for a parameter in no class (reported) or of a failed type.
    class: ?Class,
};

/// A stage function and its classified parameters.
pub const StageFn = struct {
    module: ModuleId,
    f: items_mod.Fn,
    stage: Stage,
    /// `(x, y, z)`, a single `u32` written as `(n, 1, 1)`. Null for stages
    /// without a workgroup and for invalid attribute arguments.
    workgroup: ?[3]u32,
    params: []const Param,
};

/// Checks every stage function of `it` (see the file comment) and returns
/// them in declaration order, allocated in the items arena. Run after
/// `attrs.check`; `lay` gives the bit-field rule of §4.11.2.
pub fn check(it: *Items, lay: *layout.Engine) Error![]const StageFn {
    var out: std.ArrayList(StageFn) = .empty;
    for (it.im.graph.modules, 0..) |cm, mi| {
        const m: ModuleId = @intCast(mi);
        for (0..cm.items.len) |i| switch ((try it.info(.{ .module = m, .item = @intCast(i) })).*) {
            .@"fn" => |f| try checkFn(it, lay, m, f, &out),
            .@"struct" => |s| for (s.methods) |f| try checkFn(it, lay, m, f, &out),
            .@"enum" => |e| for (e.methods) |f| try checkFn(it, lay, m, f, &out),
            else => {},
        };
    }
    return out.items;
}

fn checkFn(it: *Items, lay: *layout.Engine, m: ModuleId, f: items_mod.Fn, out: *std.ArrayList(StageFn)) Error!void {
    const a = it.im.graph.modules[m].ast;
    const stage = builtins.stageOf(a, f.attrs) orelse return;
    const gpa = it.arena.allocator();
    const code: diag.DiagCode = if (stage == .compute) .E1001 else .E1008;
    const decl = a.data(f.node).fn_decl;
    const params = try gpa.alloc(Param, f.params.len);
    for (f.params, decl.params, params, 0..) |p, pn, *o, i| {
        const pattrs: []const Node.Index = if (a.kind(pn) == .attributed) a.data(pn).attributed.attrs else &.{};
        const class: ?Class = if (p.type == .err) null else try classify(it, lay, a, stage, p, i, pattrs);
        o.* = .{ .name = p.name, .mode = p.mode, .class = class };
        if (class == null and p.type != .err) try it.report(m, a.mainToken(p.node), code, &.{
            "stage parameters are uniform (scalars, vectors, plain structs), storage (`[]T`, `soa []T`), textures, samplers or `gpu.Tlas` (§11.1.2)",
        }, "parameter `{s}{s}: {s}` of {t} stage `{s}` is in no GPU parameter class", .{ modeText(p.mode), p.name, try it.tyName(p.type), stage, f.name });
    }
    if (stage == .compute and f.ret != .void and f.ret != .err)
        try it.report(m, a.mainToken(decl.ret.?), .E1001, &.{"write results to a `mut` storage parameter"}, "kernel `{s}` returns `{s}`, but a kernel returns `void`", .{ f.name, try it.tyName(f.ret) });
    try out.append(gpa, .{ .module = m, .f = f, .stage = stage, .workgroup = try workgroup(it, m, f.attrs, stage), .params = params });
}

fn modeText(mode: items_mod.Mode) []const u8 {
    return switch (mode) {
        .value => "",
        .mut => "mut ",
        .move => "move ",
        .@"comptime" => "comptime ",
    };
}

/// The workgroup size of a stage with attributes `fattrs`, checked against
/// its stage limit (E1002). Null for stages without one, or if `attrs.check`
/// rejected the argument.
fn workgroup(it: *Items, m: ModuleId, fattrs: []const Node.Index, stage: Stage) Error!?[3]u32 {
    const attr: attr_table.Attr, const limit: u64 = switch (stage) {
        .compute => .{ .gpu_kernel, 1024 },
        .task => .{ .gpu_task, 128 },
        .mesh => .{ .gpu_mesh, 128 },
        else => return null,
    };
    const a = it.im.graph.modules[m].ast;
    const at = for (fattrs) |n| {
        if (attrs.attrOf(a, n) == attr) break n;
    } else return null;
    const v = attrs.arg(a, at, "workgroup") orelse return .{ default_workgroup, 1, 1 };
    const dims: []const Node.Index = if (a.kind(v) == .tuple) a.data(v).tuple.elems else &.{v};
    if (dims.len != 1 and dims.len != 3) return null;
    var size: [3]u32 = @splat(1);
    for (dims, size[0..dims.len]) |d, *s| s.* = std.math.cast(u32, attrs.intValue(it, try attrs.argValue(it, m, d)) orelse return null) orelse return null;
    const product = @as(u128, size[0]) * size[1] * size[2];
    if (product == 0)
        try it.report(m, a.mainToken(v), .E1002, &.{}, "workgroup size ({d}, {d}, {d}) has no invocations", .{ size[0], size[1], size[2] })
    else if (product > limit)
        try it.report(m, a.mainToken(v), .E1002, &.{}, "workgroup size ({d}, {d}, {d}) has {d} invocations, more than the {d} allowed in a {t} stage", .{ size[0], size[1], size[2], product, limit, stage });
    return size;
}

/// The class of parameter `p`, the `index`-th of a `stage` function, with
/// attribute nodes `pattrs` of `a`; null if it is in none.
fn classify(it: *Items, lay: *layout.Engine, a: *const Ast, stage: Stage, p: items_mod.Param, index: usize, pattrs: []const Node.Index) Error!?Class {
    if (try stageSpecific(it, lay, a, stage, p, index, pattrs)) return .stage_specific;
    const t = p.type;
    switch (it.types.get(t)) {
        inline .slice, .soa_slice => |s| return if (p.mode != .move and p.mode != .@"comptime" and try storageElem(it, lay, s.elem)) .storage else null,
        else => {},
    }
    if (resource(it, t)) |r| return switch (r) {
        .storage_texture => if (p.mode == .value or p.mode == .mut) .texture_sampler else null,
        .texture, .sampler => if (p.mode == .value) .texture_sampler else null,
        .tlas => if (p.mode == .value) .acceleration_structure else null,
    };
    return if (p.mode == .value and try uniform(it, lay, t)) .uniform else null;
}

/// Whether `p` fills a stage-specific slot of `stage` (§11.1.2, §11.3,
/// §11.4, §11.5.2).
fn stageSpecific(it: *Items, lay: *layout.Engine, a: *const Ast, stage: Stage, p: items_mod.Param, index: usize, pattrs: []const Node.Index) Error!bool {
    const mutable = p.mode == .mut;
    const value = p.mode == .value;
    return switch (stage) {
        .compute, .ray_gen => false,
        // Vertex input and `@instance`: a plain struct of scalars and vectors.
        .vertex => value and (index == 0 or items_mod.hasAttr(a, pattrs, .instance)) and try uniformStruct(it, lay, p.type, 0),
        // Fragment input, and the `@per_primitive` input of mesh pipelines.
        .fragment => value and (if (index == 0) try uniformStruct(it, lay, p.type, 0) else items_mod.hasAttr(a, pattrs, .per_primitive) and try plainStruct(it, p.type)),
        .task => mutable and index == 0 and try plainStruct(it, p.type),
        .mesh => if (index == 0) mutable and stdNamed(it, p.type, .mesh_out, "MeshOut") else value and items_mod.hasAttr(a, pattrs, .task_payload) and try plainStruct(it, p.type),
        .miss => if (index == 0) mutable and try plainStruct(it, p.type) else index == 1 and value and stdNamed(it, p.type, .none, "RayInfo"),
        .closest_hit, .any_hit => if (index == 0) mutable and try plainStruct(it, p.type) else index == 1 and value and stdNamed(it, p.type, .none, "Hit"),
        .intersection => value and (if (index == 0) stdNamed(it, p.type, .none, "RayInfo") else index == 1 and stdNamed(it, p.type, .none, "PrimitiveInfo")),
    };
}

/// Whether `t` is a uniform-class type: a scalar, a `vec` or a plain struct
/// without bit fields or pointers.
fn uniform(it: *Items, lay: *layout.Engine, t: TypeId) Error!bool {
    if (scalar(it, t)) return true;
    return switch (it.types.get(t)) {
        .vec => true,
        .nominal => uniformStruct(it, lay, t, 0),
        else => false,
    };
}

fn scalar(it: *Items, t: TypeId) bool {
    return switch (t) {
        .bool, .f32, .f64, .usize, .isize => true,
        else => it.types.get(t) == .int,
    };
}

/// Whether `t` is a struct of this package whose fields are scalars that
/// are not bit fields (§4.11.2), vectors, arrays of them, or such structs.
/// `@c_layout` and `@soa` structs have no bit fields (§4.11.3).
fn uniformStruct(it: *Items, lay: *layout.Engine, t: TypeId, depth: u32) Error!bool {
    const s = it.structOf(t) orelse return false;
    // A struct that contains itself is E0376 (layout); stop rather than recurse.
    if (depth > 64) return false;
    const m = it.declRef(t).?.module;
    const bit_packed = lay.attr(m, s.attrs, .c_layout) == null and lay.attr(m, s.attrs, .soa) == null;
    for (s.fields) |fd| if (!try uniformField(it, lay, fd.type, bit_packed, depth + 1)) return false;
    return true;
}

fn uniformField(it: *Items, lay: *layout.Engine, t: TypeId, bit_packed: bool, depth: u32) Error!bool {
    if (t == .err) return true;
    if (bit_packed and lay.bitWidth(t) != null) return false;
    if (scalar(it, t)) return true;
    return switch (it.types.get(t)) {
        .vec => true,
        .array => |x| uniformField(it, lay, x.elem, bit_packed, depth),
        .nominal => uniformStruct(it, lay, t, depth),
        // shortcut: fields of a generic struct are judged as declared, a type
        // parameter counting as uniform; substitute the arguments once
        // generic instances carry their field types.
        .param => true,
        else => false,
    };
}

/// The element of a storage buffer: a uniform-class type, `Atomic<u32>` or
/// `Atomic<i32>`.
fn storageElem(it: *Items, lay: *layout.Engine, t: TypeId) Error!bool {
    if (t == .err) return true;
    switch (it.types.get(t)) {
        .nominal => |n| if (n.lang == .atomic) return n.args.len == 1 and n.args[0] == .type and
            (n.args[0].type == TypeId.int(.unsigned, 32) or n.args[0].type == TypeId.int(.signed, 32)),
        else => {},
    }
    return uniform(it, lay, t);
}

/// A plain struct (§5.1), as task and ray-tracing payloads need.
fn plainStruct(it: *Items, t: TypeId) Error!bool {
    return switch (it.types.get(t)) {
        .nominal => |n| n.kind == .@"struct" and n.lang == .none and try kinds.kind(it, t) == .plain,
        else => false,
    };
}

/// Whether `t` is the standard-library type tagged `lang`, or named `name`
/// in the standard library when `lang` is `.none` or the type is untagged.
fn stdNamed(it: *Items, t: TypeId, lang: Types.Lang, name: []const u8) bool {
    const n = switch (it.types.get(t)) {
        .nominal => |n| n,
        else => return false,
    };
    if (lang != .none and n.lang == lang) return true;
    // shortcut: the standard library is not loaded (T163), so `std.gpu` types
    // are untagged and recognised by name; drop this once they carry `Lang` tags.
    return n.lang == .none and std.meta.eql(n.decl.package, it.std_pkg) and std.mem.eql(u8, it.types.strings.get(n.name), name);
}

const Resource = enum { texture, storage_texture, sampler, tlas };

/// The binding resource (§11.1.2) `t` is, if any.
fn resource(it: *Items, t: TypeId) ?Resource {
    const n = switch (it.types.get(t)) {
        .nominal => |n| n,
        else => return null,
    };
    return switch (n.lang) {
        .texture_2d, .texture_3d, .texture_cube, .texture_2d_array, .depth_texture_2d => .texture,
        .storage_texture_2d => .storage_texture,
        .sampler => .sampler,
        .tlas => .tlas,
        .none => {
            const by_name = std.StaticStringMap(Resource).initComptime(.{
                .{ "Texture2D", .texture },      .{ "Texture3D", .texture },
                .{ "TextureCube", .texture },    .{ "Texture2DArray", .texture },
                .{ "DepthTexture2D", .texture }, .{ "StorageTexture2D", .storage_texture },
                .{ "Sampler", .sampler },        .{ "Tlas", .tlas },
            });
            if (!std.meta.eql(n.decl.package, it.std_pkg)) return null;
            return by_name.get(it.types.strings.get(n.name)); // see `stdNamed`
        },
        else => null,
    };
}

/// Writes the classification of `fns`: one line per stage function
/// (stage, name, workgroup size), then one per parameter.
pub fn dump(fns: []const StageFn, w: *Writer) Writer.Error!void {
    for (fns) |sf| {
        try w.print("{t} {s}", .{ sf.stage, sf.f.name });
        if (sf.workgroup) |g| try w.print(" workgroup({d}, {d}, {d})", .{ g[0], g[1], g[2] });
        try w.writeByte('\n');
        for (sf.params) |p| try w.print("  {s}{s}: {s}\n", .{ modeText(p.mode), p.name, if (p.class) |c| @tagName(c) else "invalid" });
    }
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const emit_tir = @import("../sema/emit_tir.zig");

/// Item-checks `src`, classifies its stage functions and expects the
/// diagnostics `want` (code, source text at the primary span) and, if
/// given, the classification dump `want_dump`.
fn expectStages(src: []const u8, want: []const struct { ?diag.DiagCode, []const u8 }, want_dump: ?[]const u8) !void {
    var f: emit_tir.Fixture = undefined;
    try f.init(src);
    defer f.deinit();
    var lay: layout.Engine = .init(testing.allocator, &f.items);
    defer lay.deinit();
    const fns = try check(&f.items, &lay);
    try f.expectDiags(want);
    if (want_dump) |d| {
        var out: Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try dump(fns, &out.writer);
        try testing.expectEqualStrings(d, out.written());
    }
}

test "kernel parameters: uniform and storage classes, dumped (§11.2)" {
    try expectStages(
        \\struct Params { scale: f32, offset: vec2<f32>, m: [4]vec4<f32>, n: u32 }
        \\@soa struct Body { x: f32, vx: f32 }
        \\@gpu_kernel(workgroup: 64)
        \\fn k(mut out: []f32, xs: []f32, p: Params, s: f32, d: vec3<f32>, b: bool) {}
        \\@gpu_kernel
        \\fn columns(mut bodies: soa []Body, bins: []Atomic<u32>, ps: []Params) {}
        \\@gpu_kernel(workgroup: (8, 8, 2))
        \\fn cube(xs: []i32) {}
        \\fn not_a_stage(xs: List<u32>) -> u32 { 0 }
    , &.{},
        \\compute k workgroup(64, 1, 1)
        \\  mut out: storage
        \\  xs: storage
        \\  p: uniform
        \\  s: uniform
        \\  d: uniform
        \\  b: uniform
        \\compute columns workgroup(64, 1, 1)
        \\  mut bodies: storage
        \\  bins: storage
        \\  ps: storage
        \\compute cube workgroup(8, 8, 2)
        \\  xs: storage
        \\
    );
}

test "invalid kernel parameters and return type (E1001)" {
    try expectStages(
        \\struct WithPointer { p: *u32, n: u32 }
        \\struct Bits { a: u7, b: bool }
        \\@gpu_kernel fn r(xs: []f32) -> f32 { 0.0 }
        \\@gpu_kernel fn a(xs: List<f32>, p: *u32, w: WithPointer, s: str, n: [][]f32) {}
        \\@gpu_kernel fn b(bits: Bits, mut k: f32, arr: [4]f32, at: []Atomic<u64>, m: mask<4>) {}
    , &.{
        .{ .E1001, "f32" },
        .{ .E1001, "xs" },
        .{ .E1001, "p" },
        .{ .E1001, "w" },
        .{ .E1001, "s" },
        .{ .E1001, "n" },
        .{ .E1001, "bits" },
        .{ .E1001, "k" },
        .{ .E1001, "arr" },
        .{ .E1001, "at" },
        .{ .E1001, "m" },
    }, null);
}

test "`@c_layout` and `@soa` structs have no bit fields (§4.11.3)" {
    try expectStages(
        \\@c_layout struct C { a: u32, ok: bool }
        \\@soa struct B { x: f32, alive: bool, tag: u7 }
        \\@packed struct P { a: u32, ok: bool }
        \\@gpu_kernel fn k1(c: C) {}
        \\@gpu_kernel fn k2(mut bs: soa []B) {}
        \\@gpu_kernel fn k3(p: P) {}
    , &.{.{ .E1001, "p" }}, null);
}

test "workgroup size limits (E1002)" {
    try expectStages(
        \\struct P { n: u32 }
        \\@gpu_kernel(workgroup: 1024) fn a() {}
        \\@gpu_kernel(workgroup: (32, 32, 1)) fn b() {}
        \\@gpu_kernel(workgroup: 2048) fn c() {}
        \\@gpu_kernel(workgroup: (32, 32, 2)) fn d() {}
        \\@gpu_kernel(workgroup: 0) fn e() {}
        \\@gpu_task(workgroup: 128) fn t(mut p: P) -> vec3<u32> { vec3(1, 1, 1) }
        \\@gpu_task(workgroup: (8, 8, 4)) fn u(mut p: P) -> vec3<u32> { vec3(1, 1, 1) }
        \\@gpu_task fn v(mut p: P) -> vec3<u32> { vec3(1, 1, 1) }
        \\@gpu_kernel(workgroup: (4294967295, 4294967295, 4294967295)) fn huge() {}
    , &.{
        .{ .E1002, "2048" },
        .{ .E1002, "(" },
        .{ .E1002, "0" },
        .{ .E1002, "(" },
        .{ .E1002, "(" },
    },
        \\compute a workgroup(1024, 1, 1)
        \\compute b workgroup(32, 32, 1)
        \\compute c workgroup(2048, 1, 1)
        \\compute d workgroup(32, 32, 2)
        \\compute e workgroup(0, 1, 1)
        \\task t workgroup(128, 1, 1)
        \\  mut p: stage_specific
        \\task u workgroup(8, 8, 4)
        \\  mut p: stage_specific
        \\task v workgroup(64, 1, 1)
        \\  mut p: stage_specific
        \\compute huge workgroup(4294967295, 4294967295, 4294967295)
        \\
    );
}

test "non-compute stage parameters: stage-specific slots, E1008" {
    try expectStages(
        \\use std.gpu;
        \\struct Vertex { pos: vec3<f32>, uv: vec2<f32> }
        \\struct Inst { model: [4]vec4<f32> }
        \\struct VsOut { @position clip: vec4<f32>, uv: vec2<f32> }
        \\struct Shade { color: vec3<f32>, shadowed: bool }
        \\@gpu_vertex fn vs(v: Vertex, @instance i: Inst, cam: Inst, extra: List<u32>) -> VsOut { VsOut { clip: vec4(1.0, 1.0, 1.0, 1.0), uv: vec2(0.0, 0.0) } }
        \\@gpu_fragment fn fs(i: VsOut, t: gpu.Texture2D<vec4<f32>>, s: gpu.Sampler, p: *const f32) -> vec4<f32> { vec4(0.0, 0.0, 0.0, 1.0) }
        \\@gpu_miss fn miss(mut s: Shade, ray: gpu.RayInfo, scene: gpu.Tlas, name: str) {}
        \\@gpu_ray_gen fn rg(s: Shade) {}
    , &.{
        .{ .E1008, "extra" },
        .{ .E1008, "p" },
        .{ .E1008, "name" },
        .{ .E1008, "s" },
    },
        \\vertex vs
        \\  v: stage_specific
        \\  i: stage_specific
        \\  cam: uniform
        \\  extra: invalid
        \\fragment fs
        \\  i: stage_specific
        \\  t: texture_sampler
        \\  s: texture_sampler
        \\  p: invalid
        \\miss miss
        \\  mut s: stage_specific
        \\  ray: stage_specific
        \\  scene: acceleration_structure
        \\  name: invalid
        \\ray_gen rg
        \\  s: invalid
        \\
    );
}
