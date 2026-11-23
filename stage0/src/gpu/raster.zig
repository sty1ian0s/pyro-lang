//! Vertex and fragment stage signatures (§11.3.1, §11.3.2, §11.4.4).
//!
//! `check` runs on the stage functions classified by `stages.check` and
//! adds the rules local to one raster stage:
//!
//! - the vertex input and the `@instance` input are plain structs of
//!   scalars, vectors and arrays of them, not nested structs (**E1008**);
//! - `@instance` belongs to a vertex stage and `@per_primitive` to a
//!   fragment stage, each at most once (**E1008**);
//! - a vertex stage returns a *varyings* struct, and a fragment input is
//!   one: exactly one `@position` field of type `vec4<f32>`; other fields
//!   `f32`, `i32`, `u32` or vectors of them; integer fields `@flat`;
//!   `@linear` only on float fields that are not `@flat` (**E1009**);
//! - a fragment stage returns `vec4<f32>` or a struct whose fields are
//!   `@target(n)` (n = 0..7, distinct) plus at most one `@depth f32`
//!   (**E1009**).
//!
//! The errors of a struct are reported once, at the struct, however many
//! stages use it. Matching a fragment input against the varyings of the
//! stage before it, and color targets against the pipeline's formats, are
//! pipeline checks (§11.6.1, T190).

const std = @import("std");
const Ast = @import("../ast/Ast.zig");
const attr_table = @import("../attr_table.zig");
const module_graph = @import("../resolve/module_graph.zig");
const Types = @import("../sema/types.zig");
const items_mod = @import("../sema/items.zig");
const attrs = @import("../sema/attrs.zig");
const stages = @import("stages.zig");

const Items = items_mod.Items;
const Node = Ast.Node;
const TypeId = Types.TypeId;
const ModuleId = module_graph.ModuleId;
const Error = std.mem.Allocator.Error;

/// The number of fragment color targets (§11.3.2).
pub const max_targets = 8;

/// Checks the vertex and fragment stages of `fns` (see the file comment).
/// Run after `stages.check`, which returned `fns`.
pub fn check(it: *Items, fns: []const stages.StageFn) Error!void {
    var seen: Seen = .{};
    for (fns) |sf| {
        const a = it.im.graph.modules[sf.module].ast;
        const decl = a.data(sf.f.node).fn_decl;
        try stageAttrs(it, sf, decl.params);
        // A wrong return type is reported at the function name.
        const ret: Site = .{ .m = sf.module, .tok = a.mainToken(sf.f.node) + 1 };
        switch (sf.stage) {
            .vertex => {
                for (sf.f.params, decl.params, sf.params, 0..) |p, pn, c, i| {
                    if (c.class == .stage_specific and (i == 0 or items_mod.hasAttr(a, paramAttrs(a, pn), .instance)))
                        try vertexInput(it, p);
                }
                if (sf.f.ret != .err) try varyings(it, &seen, sf.f.ret, ret);
            },
            .fragment => {
                // `stages` puts a struct first parameter in the fragment-input slot.
                if (sf.params.len > 0 and sf.params[0].class == .stage_specific)
                    try varyings(it, &seen, sf.f.params[0].type, ret);
                if (sf.f.ret != .err) try fragmentOutput(it, &seen, sf.f.ret, ret);
            },
            else => {},
        }
    }
}

/// Struct types already checked, so that each is reported once.
const Seen = struct {
    varyings: std.AutoHashMapUnmanaged(TypeId, void) = .empty,
    outputs: std.AutoHashMapUnmanaged(TypeId, void) = .empty,

    fn first(it: *Items, set: *std.AutoHashMapUnmanaged(TypeId, void), t: TypeId) Error!bool {
        return !(try set.getOrPut(it.arena.allocator(), t)).found_existing;
    }
};

/// A token of module `m`, for reports.
const Site = struct { m: ModuleId, tok: Ast.TokenIndex };

fn paramAttrs(a: *const Ast, pn: Node.Index) []const Node.Index {
    return if (a.kind(pn) == .attributed) a.data(pn).attributed.attrs else &.{};
}

/// `@instance` outside a vertex stage and `@per_primitive` outside a
/// fragment stage, or either twice (E1008). `pns` are the parameter nodes.
fn stageAttrs(it: *Items, sf: stages.StageFn, pns: []const Node.Index) Error!void {
    const a = it.im.graph.modules[sf.module].ast;
    const rules = [_]struct { attr_table.Attr, stages.Stage }{ .{ .instance, .vertex }, .{ .per_primitive, .fragment } };
    for (rules) |r| {
        const attr, const stage = r;
        var count: u32 = 0;
        for (sf.f.params, pns) |p, pn| {
            if (!items_mod.hasAttr(a, paramAttrs(a, pn), attr)) continue;
            count += 1;
            const tok = a.mainToken(p.node);
            if (sf.stage != stage)
                try it.report(sf.module, tok, .E1008, &.{}, "`@{t}` parameter `{s}` of {t} stage `{s}`: only a {t} stage takes one", .{ attr, p.name, sf.stage, sf.f.name, stage })
            else if (count == 2)
                try it.report(sf.module, tok, .E1008, &.{}, "{t} stage `{s}` has a second `@{t}` parameter `{s}`", .{ sf.stage, sf.f.name, attr, p.name });
        }
    }
}

/// A vertex or instance input: its fields are scalars, vectors or arrays
/// of them (§11.3.1). `stages` checked the rest of the plain-struct rule.
fn vertexInput(it: *Items, p: items_mod.Param) Error!void {
    const s = it.structOf(p.type) orelse return;
    const m = it.declRef(p.type).?.module;
    for (s.fields) |fd| {
        var t = fd.type;
        while (it.types.get(t) == .array) t = it.types.get(t).array.elem;
        if (it.structOf(t) == null) continue;
        try it.report(m, it.im.graph.modules[m].ast.mainToken(fd.node), .E1008, &.{"vertex attributes are scalars, vectors or arrays of them"}, "field `{s}: {s}` of vertex input `{s}` (parameter `{s}`) is a struct", .{ fd.name, try it.tyName(fd.type), try it.tyName(p.type), p.name });
    }
}

const Component = enum { float, int };

/// The component kind of `t` if it is `f32`, `i32`, `u32` or a vector of them.
fn component(it: *Items, t: TypeId) ?Component {
    const e = switch (it.types.get(t)) {
        .vec => |v| v.elem,
        else => t,
    };
    if (e == .f32) return .float;
    if (e == TypeId.int(.signed, 32) or e == TypeId.int(.unsigned, 32)) return .int;
    return null;
}

fn isVec4F32(it: *Items, t: TypeId) bool {
    return switch (it.types.get(t)) {
        .vec => |v| v.len == 4 and v.elem == .f32,
        else => false,
    };
}

/// Checks that `t`, a vertex stage's return type or a fragment stage's
/// input, is a varyings struct (§11.3.1, E1009). `ret` is the stage's
/// function name, where a vertex stage returning no struct is reported.
fn varyings(it: *Items, seen: *Seen, t: TypeId, ret: Site) Error!void {
    const s = it.structOf(t) orelse
        return it.report(ret.m, ret.tok, .E1009, &.{"return a struct with one `@position clip: vec4<f32>` field"}, "a vertex stage returns a varyings struct, not `{s}`", .{try it.tyName(t)});
    if (!try Seen.first(it, &seen.varyings, t)) return;
    const ref = it.declRef(t).?;
    const a = it.im.graph.modules[ref.module].ast;
    const name = try it.tyName(t);
    var position = false;
    for (s.fields) |fd| {
        if (fd.type == .err) continue;
        const tok = a.mainToken(fd.node);
        if (items_mod.hasAttr(a, fd.attrs, .position)) {
            if (position)
                try it.report(ref.module, tok, .E1009, &.{}, "varyings struct `{s}` has a second `@position` field `{s}`", .{ name, fd.name })
            else if (!isVec4F32(it, fd.type))
                try it.report(ref.module, tok, .E1009, &.{}, "`@position` field `{s}` of varyings struct `{s}` has type `{s}`, but clip-space position is `vec4<f32>`", .{ fd.name, name, try it.tyName(fd.type) });
            position = true;
            continue;
        }
        const flat = items_mod.hasAttr(a, fd.attrs, .flat);
        const linear = items_mod.hasAttr(a, fd.attrs, .linear);
        const c = component(it, fd.type) orelse {
            try it.report(ref.module, tok, .E1009, &.{}, "field `{s}: {s}` of varyings struct `{s}` is not `f32`, `i32`, `u32` or a vector of them", .{ fd.name, try it.tyName(fd.type), name });
            continue;
        };
        if (c == .int and !flat)
            try it.report(ref.module, tok, .E1009, &.{"integers are not interpolated: mark the field `@flat`"}, "integer field `{s}: {s}` of varyings struct `{s}` is not `@flat`", .{ fd.name, try it.tyName(fd.type), name })
        else if (linear and flat)
            try it.report(ref.module, tok, .E1009, &.{}, "field `{s}` of varyings struct `{s}` is both `@flat` and `@linear`", .{ fd.name, name })
        else if (linear and c == .int)
            try it.report(ref.module, tok, .E1009, &.{}, "integer field `{s}` of varyings struct `{s}` is `@linear`; integers are `@flat`", .{ fd.name, name });
    }
    if (!position) {
        const node = it.im.graph.modules[ref.module].items[ref.item].node;
        try it.report(ref.module, a.mainToken(node) + 1, .E1009, &.{"add exactly one `@position clip: vec4<f32>` field"}, "varyings struct `{s}` has no `@position` field", .{name});
    }
}

/// Checks that `t`, a fragment stage's return type, is `vec4<f32>`
/// or a struct of `@target(n)` fields and at most one `@depth f32` field
/// (§11.3.2, E1009).
fn fragmentOutput(it: *Items, seen: *Seen, t: TypeId, ret: Site) Error!void {
    if (isVec4F32(it, t)) return;
    const s = it.structOf(t) orelse
        return it.report(ret.m, ret.tok, .E1009, &.{"return `vec4<f32>` for one color target, or a struct of `@target(n)` fields"}, "a fragment stage returns `vec4<f32>` or a struct of color targets, not `{s}`", .{try it.tyName(t)});
    if (!try Seen.first(it, &seen.outputs, t)) return;
    const m = it.declRef(t).?.module;
    const a = it.im.graph.modules[m].ast;
    const name = try it.tyName(t);
    var targets: std.StaticBitSet(max_targets) = .empty;
    var depth = false;
    for (s.fields) |fd| {
        if (fd.type == .err) continue;
        const tok = a.mainToken(fd.node);
        const target = for (fd.attrs) |n| {
            if (attrs.attrOf(a, n) == .target) break n;
        } else null;
        const is_depth = items_mod.hasAttr(a, fd.attrs, .depth);
        if (is_depth and target != null) {
            try it.report(m, tok, .E1009, &.{}, "field `{s}` of fragment output `{s}` is both `@target` and `@depth`", .{ fd.name, name });
        } else if (is_depth) {
            if (depth)
                try it.report(m, tok, .E1009, &.{"a fragment stage writes at most one depth value"}, "fragment output `{s}` has a second `@depth` field `{s}`", .{ name, fd.name })
            else if (fd.type != .f32)
                try it.report(m, tok, .E1009, &.{}, "`@depth` field `{s}` of fragment output `{s}` has type `{s}`, but depth is `f32`", .{ fd.name, name, try it.tyName(fd.type) });
            depth = true;
        } else if (target) |at| {
            const v = attrs.arg(a, at, "n") orelse continue;
            // Null when not a comptime integer, which `attrs.check` reports.
            const n = attrs.intValue(it, try attrs.argValue(it, m, v)) orelse continue;
            if (n >= max_targets)
                try it.report(m, a.mainToken(v), .E1009, &.{}, "`@target({d})` on field `{s}`: color targets are 0 to {d}", .{ n, fd.name, max_targets - 1 })
            else if (targets.isSet(n))
                try it.report(m, tok, .E1009, &.{}, "fragment output `{s}` has a second field `{s}` for `@target({d})`", .{ name, fd.name, n })
            else
                targets.set(n);
        } else {
            try it.report(m, tok, .E1009, &.{"mark it `@target(n)` for color target n, or `@depth` for the depth output"}, "field `{s}` of fragment output `{s}` is neither `@target(n)` nor `@depth`", .{ fd.name, name });
        }
    }
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const emit_tir = @import("../sema/emit_tir.zig");
const layout = @import("../sema/layout.zig");
const diag = @import("../diag/diag.zig");

/// Checks the stage functions of `src` and expects the diagnostics `want`
/// (code, source text at the primary span).
fn expectRaster(src: []const u8, want: []const struct { ?diag.DiagCode, []const u8 }) !void {
    var f: emit_tir.Fixture = undefined;
    try f.init(src);
    defer f.deinit();
    var lay: layout.Engine = .init(testing.allocator, &f.items);
    defer lay.deinit();
    try check(&f.items, try stages.check(&f.items, &lay));
    try f.expectDiags(want);
}

test "§11.3 vertex and fragment stages are accepted" {
    try expectRaster(
        \\@soa struct MeshVertex { pos: vec3<f32>, normal: vec3<f32>, uv: vec2<f32> }
        \\struct Instance { model: [4]vec4<f32>, tint: vec4<f32> }
        \\struct Camera { view_proj: [4]vec4<f32> }
        \\struct VsOut { @position clip: vec4<f32>, world_normal: vec3<f32>, @linear uv: vec2<f32>, @flat tint_id: u32, @flat k: vec2<i32> }
        \\struct GBuffer { @target(0) albedo: vec4<f32>, @target(1) normal: vec4<f32>, @target(7) id: u32, @depth z: f32 }
        \\struct Prim { material: u32 }
        \\@gpu_vertex fn vs(v: MeshVertex, @instance inst: Instance, cam: Camera) -> VsOut { loop {} }
        \\@gpu_fragment fn fs(i: VsOut, cam: Camera) -> vec4<f32> { loop {} }
        \\@gpu_fragment fn gb(i: VsOut, @per_primitive p: Prim) -> GBuffer { loop {} }
        \\@gpu_fragment fn no_input() -> vec4<f32> { loop {} }
    , &.{});
}

test "varyings: missing or doubled @position, integers without @flat (E1009)" {
    try expectRaster(
        \\struct V { pos: vec3<f32> }
        \\struct NoPos { uv: vec2<f32> }
        \\struct Ints { @position clip: vec4<f32>, id: u32, @flat ok: vec3<i32>, @linear @flat both: f32, @flat @linear lin: u32 }
        \\struct TwoPos { @position a: vec4<f32>, @position b: vec4<f32> }
        \\struct BadTypes { @position p: vec3<f32>, b: bool, d: f64 }
        \\@gpu_vertex fn v1(v: V) -> NoPos { loop {} }
        \\@gpu_vertex fn v2(v: V) -> Ints { loop {} }
        \\@gpu_vertex fn v3(v: V) -> TwoPos { loop {} }
        \\@gpu_vertex fn v4(v: V) -> BadTypes { loop {} }
        \\@gpu_vertex fn v5(v: V) -> NoPos { loop {} }
        \\@gpu_vertex fn v6(v: V) -> vec4<f32> { loop {} }
        \\@gpu_vertex fn v7(v: V) {}
    , &.{
        .{ .E1009, "NoPos" },
        .{ .E1009, "id" },
        .{ .E1009, "both" },
        .{ .E1009, "lin" },
        .{ .E1009, "b" },
        .{ .E1009, "p" },
        .{ .E1009, "b" },
        .{ .E1009, "d" },
        .{ .E1009, "v6" },
        .{ .E1009, "v7" },
    });
}

test "fragment input is a varyings struct (E1009)" {
    try expectRaster(
        \\struct Material { light_dir: vec3<f32>, ambient: f32 }
        \\@gpu_fragment fn fs(m: Material) -> vec4<f32> { loop {} }
    , &.{.{ .E1009, "Material" }});
}

test "fragment outputs: targets and depth (E1009)" {
    try expectRaster(
        \\struct In { @position clip: vec4<f32> }
        \\struct TwoDepth { @target(0) c: vec4<f32>, @depth z: f32, @depth w: f32 }
        \\struct Bad { @target(0) a: vec4<f32>, @target(0) b: vec4<f32>, @target(8) c: vec4<f32>, @depth d: f64, plain: f32, @target(1) @depth both: f32 }
        \\@gpu_fragment fn f1(i: In) -> TwoDepth { loop {} }
        \\@gpu_fragment fn f2(i: In) -> Bad { loop {} }
        \\@gpu_fragment fn f3(i: In) -> TwoDepth { loop {} }
        \\@gpu_fragment fn f4(i: In) -> vec3<f32> { loop {} }
    , &.{
        .{ .E1009, "w" },
        .{ .E1009, "b" },
        .{ .E1009, "8" },
        .{ .E1009, "d" },
        .{ .E1009, "plain" },
        .{ .E1009, "both" },
        .{ .E1009, "f4" },
    });
}

test "vertex inputs and stage-specific parameter attributes (E1008)" {
    try expectRaster(
        \\struct Inner { a: f32 }
        \\struct Nested { pos: vec3<f32>, inner: Inner, arr: [2]Inner }
        \\struct Inst { m: [4]vec4<f32> }
        \\struct Out { @position clip: vec4<f32> }
        \\@gpu_vertex fn vs(v: Nested, @instance a: Inst, @instance b: Inst) -> Out { loop {} }
        \\@gpu_fragment fn fs(i: Out, @instance x: Inst, @per_primitive p: Inst, @per_primitive q: Inst) -> vec4<f32> { loop {} }
        \\@gpu_vertex fn vp(v: Inst, @per_primitive p: Inst) -> Out { loop {} }
    , &.{
        .{ .E1008, "inner" },
        .{ .E1008, "arr" },
        .{ .E1008, "b" },
        .{ .E1008, "x" },
        .{ .E1008, "q" },
        .{ .E1008, "p" },
    });
}
