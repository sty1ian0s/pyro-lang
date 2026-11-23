//! GPU buffer and uniform layout, and binding numbering (§11.2.2).
//!
//! - Storage buffers use std430 (WGSL storage) rules, the uniform block
//!   std140 (WGSL uniform) rules. Both keep declaration order:
//!   * a scalar has its Pyro size and alignment (`layout.zig`), except
//!     `bool`, which is 4 bytes as in GLSL (WGSL has no host-shareable
//!     `bool`; backends store it as `u32`);
//!   * `vec<2, T>` has size and alignment 2·s; `vec<3, T>` size 3·s and
//!     alignment 4·s; `vec<4, T>` size and alignment 4·s (s = scalar size);
//!   * `[N]T` has T's alignment and stride `T.size` rounded up to it;
//!   * a struct has its largest member alignment, members placed in order,
//!     size rounded up to the alignment;
//!   * std140 additionally rounds array strides and array and struct
//!     alignments up to 16.
//! - Binding numbers: set 0 holds the storage buffers in parameter order,
//!   one per SoA column in field order; set 1, binding 0 the uniform block
//!   (the uniform-class parameters as members, in parameter order); set 2
//!   the textures, samplers and acceleration structures in parameter order.
//!
//! `matchesPyro` says whether a buffer element's std430 bytes equal its
//! Pyro layout (§4.11.2), so that `launch` can skip the staging copy.

const std = @import("std");
const Types = @import("../sema/types.zig");
const items_mod = @import("../sema/items.zig");
const layout = @import("../sema/layout.zig");
const soa = @import("../sema/layout_soa.zig");
const stages = @import("stages.zig");

const Items = items_mod.Items;
const Layout = layout.Layout;
const Place = layout.Place;
const TypeId = Types.TypeId;
const Error = std.mem.Allocator.Error;

/// A buffer layout standard.
pub const Rules = enum {
    /// Storage buffers (std430 / WGSL storage).
    std430,
    /// Uniform blocks (std140 / WGSL uniform).
    std140,
};

/// The layout of `t` under `rules`, with one place per field for structs,
/// allocated in `lay`'s arena. Null for types without a GPU layout: those
/// without a Pyro layout, and vectors of more than 4 lanes.
pub fn layoutOf(lay: *layout.Engine, t: TypeId, rules: Rules) Error!?Layout {
    const it = lay.items;
    if (t == .bool) return .{ .size = 4, .@"align" = 4 };
    switch (it.types.get(t)) {
        .vec => |v| {
            const s = (try layoutOf(lay, v.elem, rules) orelse return null).size;
            return switch (v.len) {
                1 => .{ .size = s, .@"align" = @intCast(s) },
                2 => .{ .size = 2 * s, .@"align" = @intCast(2 * s) },
                3 => .{ .size = 3 * s, .@"align" = @intCast(4 * s) },
                4 => .{ .size = 4 * s, .@"align" = @intCast(4 * s) },
                else => null,
            };
        },
        .array => |a| {
            const e = try layoutOf(lay, a.elem, rules) orelse return null;
            const al = round(rules, e.@"align");
            return .{ .size = a.len *| stride(rules, e), .@"align" = al };
        },
        .nominal => |n| {
            if (n.lang == .atomic) return if (n.args.len == 1 and n.args[0] == .type) layoutOf(lay, n.args[0].type, rules) else null;
            const s = it.structOf(t) orelse return lay.layoutOf(t);
            // A struct that contains itself has no Pyro layout (E0376): stop.
            _ = try lay.layoutOf(t) orelse return null;
            const places = try lay.arena.allocator().alloc(Place, s.fields.len);
            var end: u64 = 0;
            var al: u32 = 1;
            for (s.fields, places) |f, *p| {
                const fl = try layoutOf(lay, try it.subst(f.type, n.decl, n.args), rules) orelse return null;
                p.* = .{ .offset = layout.alignUp(end, fl.@"align") };
                end = p.offset +| fl.size;
                al = @max(al, fl.@"align");
            }
            al = round(rules, al);
            return .{ .size = layout.alignUp(end, al), .@"align" = al, .fields = places };
        },
        else => return lay.layoutOf(t),
    }
}

/// std140 raises array and struct alignments to 16.
fn round(rules: Rules, a: u32) u32 {
    return if (rules == .std140) @max(a, 16) else a;
}

/// The array stride of elements laid out as `l`.
fn stride(rules: Rules, l: Layout) u64 {
    return layout.alignUp(l.size, round(rules, l.@"align"));
}

/// Whether an array of `t` has the same bytes in std430 as in its Pyro
/// layout (§4.11.2), so a buffer needs no staging copy (§11.2.2). Padding
/// may differ; data bytes may not.
pub fn matchesPyro(lay: *layout.Engine, t: TypeId) Error!bool {
    // `Atomic<T>` is stored as its `T` (§10.3).
    switch (lay.items.types.get(t)) {
        .nominal => |n| if (n.lang == .atomic) return n.args.len == 1 and n.args[0] == .type and try matchesPyro(lay, n.args[0].type),
        else => {},
    }
    const p = try lay.layoutOf(t) orelse return false;
    const g = try layoutOf(lay, t, .std430) orelse return false;
    return layout.alignUp(p.size, p.@"align") == stride(.std430, g) and try sameBytes(lay, t, p, g);
}

fn sameBytes(lay: *layout.Engine, t: TypeId, p: Layout, g: Layout) Error!bool {
    const it = lay.items;
    if (t == .bool) return false;
    switch (it.types.get(t)) {
        .vec => |v| return matchesPyro(lay, v.elem),
        .array => |a| return matchesPyro(lay, a.elem),
        .nominal => |n| {
            const s = it.structOf(t) orelse return p.size == g.size;
            if (p.size != g.size) return false;
            for (s.fields, p.fields, g.fields) |f, pp, gp| {
                const ft = try it.subst(f.type, n.decl, n.args);
                if (pp.offset != gp.offset or pp.width != 0) return false;
                const fp = try lay.layoutOf(ft) orelse return false;
                const fg = try layoutOf(lay, ft, .std430) orelse return false;
                if (!try sameBytes(lay, ft, fp, fg)) return false;
            }
            return true;
        },
        else => return p.size == g.size,
    }
}

/// One binding of a stage function (§11.2.2).
pub const Binding = struct {
    set: u32,
    binding: u32,
    /// Index of the parameter in the function.
    param: u32,
    /// `.storage`, `.texture_sampler` or `.acceleration_structure`.
    class: stages.Class,
    /// Storage buffers of SoA parameters: the field index of the column.
    column: ?u32 = null,
    /// Storage buffers: the element type (the column's field type for SoA).
    elem: TypeId = .err,
    /// Storage buffers: the std430 element stride; 0 if `elem` has no GPU
    /// layout.
    stride: u64 = 0,
    /// Storage buffers: whether `launch` converts through a staging copy
    /// because the element's Pyro layout differs (§11.2.2).
    converts: bool = false,
};

/// The uniform block: set 1, binding 0.
pub const Block = struct {
    /// Indices of the uniform-class parameters, in parameter order.
    params: []const u32,
    /// std140 layout of the block, one place per member of `params`.
    layout: Layout,
};

/// The bindings of one stage function.
pub const Map = struct {
    /// Sets 0 and 2, in binding order.
    bindings: []const Binding,
    /// Null if the function has no uniform-class parameter.
    uniform: ?Block,
};

/// Set (bind group) numbers (§11.2.2).
pub const storage_set = 0;
pub const uniform_set = 1;
pub const resource_set = 2;

/// Numbers the bindings of `sf` (§11.2.2). Parameters outside the four
/// binding classes, and uniform members without a GPU layout, get none.
pub fn bindings(lay: *layout.Engine, sf: stages.StageFn) Error!Map {
    const it = lay.items;
    const gpa = lay.arena.allocator();
    var storage: std.ArrayList(Binding) = .empty;
    var resources: std.ArrayList(Binding) = .empty;
    var uniforms: std.ArrayList(u32) = .empty;
    var places: std.ArrayList(Place) = .empty;
    var end: u64 = 0;
    var al: u32 = 16;
    for (sf.params, sf.f.params, 0..) |p, fp, i| {
        const pi: u32 = @intCast(i);
        switch (p.class orelse continue) {
            .storage => {
                const elem, const by_column = switch (it.types.get(fp.type)) {
                    .slice => |s| .{ s.elem, soa.isSoa(lay, s.elem) },
                    .soa_slice => |s| .{ s.elem, true },
                    else => unreachable,
                };
                const s = if (by_column) it.structOf(elem) else null;
                if (s) |st| {
                    const n = it.types.get(elem).nominal;
                    for (st.fields, 0..) |f, c| try storage.append(gpa, try buffer(lay, pi, @intCast(storage.items.len), try it.subst(f.type, n.decl, n.args), @intCast(c)));
                } else try storage.append(gpa, try buffer(lay, pi, @intCast(storage.items.len), elem, null));
            },
            .uniform => {
                const l = try layoutOf(lay, fp.type, .std140) orelse continue;
                const off = layout.alignUp(end, l.@"align");
                try uniforms.append(gpa, pi);
                try places.append(gpa, .{ .offset = off });
                end = off + l.size;
                al = @max(al, l.@"align");
            },
            .texture_sampler, .acceleration_structure => |c| try resources.append(gpa, .{
                .set = resource_set,
                .binding = @intCast(resources.items.len),
                .param = pi,
                .class = c,
            }),
            .stage_specific => {},
        }
    }
    try storage.appendSlice(gpa, resources.items);
    return .{
        .bindings = storage.items,
        .uniform = if (uniforms.items.len == 0) null else .{
            .params = uniforms.items,
            .layout = .{ .size = layout.alignUp(end, al), .@"align" = al, .fields = places.items },
        },
    };
}

fn buffer(lay: *layout.Engine, param: u32, binding: u32, elem: TypeId, column: ?u32) Error!Binding {
    const g = try layoutOf(lay, elem, .std430);
    return .{
        .set = storage_set,
        .binding = binding,
        .param = param,
        .class = .storage,
        .column = column,
        .elem = elem,
        .stride = if (g) |l| stride(.std430, l) else 0,
        .converts = !try matchesPyro(lay, elem),
    };
}

// ---------------------------------------------------------------------------
// Tests
//
// Expected offsets are the reference values of the GLSL 4.60 specification
// (§7.6.2.2, the std140 example) and the WGSL specification (§13.4.3, the
// structure layout example), not computed by this file.

const testing = std.testing;
const emit_tir = @import("../sema/emit_tir.zig");

const Env = struct {
    f: emit_tir.Fixture,
    lay: layout.Engine,
    fns: []const stages.StageFn,

    fn init(env: *Env, src: []const u8) !void {
        try env.f.init(src);
        env.lay = .init(testing.allocator, &env.f.items);
        env.fns = try stages.check(&env.f.items, &env.lay);
        try env.f.expectDiags(&.{});
    }

    fn deinit(env: *Env) void {
        env.lay.deinit();
        env.f.deinit();
    }

    /// The type of parameter `i` of stage function `func`, or its element
    /// for a slice.
    fn elem(env: *Env, func: usize, i: usize) TypeId {
        const t = env.fns[func].f.params[i].type;
        return switch (env.f.items.types.get(t)) {
            .slice => |s| s.elem,
            else => t,
        };
    }

    /// The `rules` layout of `elem(func, i)`.
    fn param(env: *Env, func: usize, i: usize, rules: Rules) !Layout {
        return (try layoutOf(&env.lay, env.elem(func, i), rules)).?;
    }
};

fn expectOffsets(want: []const u64, l: Layout) !void {
    try testing.expectEqual(want.len, l.fields.len);
    for (want, l.fields) |w, p| try testing.expectEqual(w, p.offset);
}

test "std430: the WGSL structure layout example" {
    var env: Env = undefined;
    try env.init(
        \\struct A { u: f32, v: f32, w: vec2<f32>, x: f32 }
        \\struct B { a: vec2<f32>, b: vec3<f32>, c: f32, d: f32, e: A, f: vec3<f32>, g: [3]A, h: i32 }
        \\@gpu_kernel fn k(xs: []A, ys: []B) {}
    );
    defer env.deinit();
    const a = try env.param(0, 0, .std430);
    try layout.expectLayout(24, 8, a);
    try expectOffsets(&.{ 0, 4, 8, 16 }, a);
    const b = try env.param(0, 1, .std430);
    try layout.expectLayout(160, 16, b);
    try expectOffsets(&.{ 0, 16, 28, 32, 40, 64, 80, 152 }, b);
}

test "std140: the GLSL std140 example" {
    var env: Env = undefined;
    try env.init(
        \\struct F { d: i32, e: vec2<bool> }
        \\struct Example { a: f32, b: vec2<f32>, c: vec3<f32>, f: F, g: f32, h: [2]f32, after: f32 }
        \\@gpu_kernel fn k(x: Example) {}
    );
    defer env.deinit();
    const e = try env.param(0, 0, .std140);
    try expectOffsets(&.{ 0, 8, 16, 32, 48, 64, 96 }, e);
    try layout.expectLayout(112, 16, e);
    // std430 of the same struct: no 16-byte rounding of `f` and `h`.
    try expectOffsets(&.{ 0, 8, 16, 32, 48, 52, 60 }, try env.param(0, 0, .std430));
}

test "§11.2 binding map: storage, SoA columns, uniform block, resources" {
    var env: Env = undefined;
    try env.init(
        \\use std.gpu;
        \\@soa struct P { x: f32, y: f32, alive: bool }
        \\struct Cam { pos: vec3<f32>, fov: f32 }
        \\struct Pad { v: vec3<f32>, n: u32, w: f32 }
        \\@gpu_kernel fn k(mut out: []f32, s: f32, mut ps: []P, cam: Cam, t: gpu.Texture2D<vec4<f32>>, d: vec2<f32>, pads: []Pad, smp: gpu.Sampler, scene: gpu.Tlas, at: []Atomic<u32>) {}
        \\@gpu_kernel fn none(xs: []i32) {}
    );
    defer env.deinit();
    const map = try bindings(&env.lay, env.fns[0]);
    const want = [_]struct { u32, u32, u32, ?u32, stages.Class, u64, bool }{
        .{ 0, 0, 0, null, .storage, 4, false },
        .{ 0, 1, 2, 0, .storage, 4, false },
        .{ 0, 2, 2, 1, .storage, 4, false },
        .{ 0, 3, 2, 2, .storage, 4, true },
        .{ 0, 4, 6, null, .storage, 32, true },
        .{ 0, 5, 9, null, .storage, 4, false },
        .{ 2, 0, 4, null, .texture_sampler, 0, false },
        .{ 2, 1, 7, null, .texture_sampler, 0, false },
        .{ 2, 2, 8, null, .acceleration_structure, 0, false },
    };
    try testing.expectEqual(want.len, map.bindings.len);
    for (want, map.bindings) |w, b| {
        try testing.expectEqual(w[0], b.set);
        try testing.expectEqual(w[1], b.binding);
        try testing.expectEqual(w[2], b.param);
        try testing.expectEqual(w[3], b.column);
        try testing.expectEqual(w[4], b.class);
        try testing.expectEqual(w[5], b.stride);
        if (b.class == .storage) try testing.expectEqual(w[6], b.converts);
    }
    // Uniform block (std140): s at 0, cam (align 16, size 16) at 16, d at 32.
    const u = map.uniform.?;
    try testing.expectEqualSlices(u32, &.{ 1, 3, 5 }, u.params);
    try expectOffsets(&.{ 0, 16, 32 }, u.layout);
    try layout.expectLayout(48, 16, u.layout);
    try testing.expectEqual(null, (try bindings(&env.lay, env.fns[1])).uniform);
}

test "Pyro layout vs std430: when `launch` needs a staging copy" {
    var env: Env = undefined;
    try env.init(
        \\@c_layout struct C { a: f32, b: u32, c: vec2<f32> }
        \\struct Sorted { a: f32, b: vec2<f32> }
        \\struct V3 { v: vec3<f32>, s: f32 }
        \\@gpu_kernel fn k(c: []C, s: []Sorted, v: []V3, f: []f64, b: []bool, w: []vec4<u32>) {}
    );
    defer env.deinit();
    const want = [_]bool{ false, true, true, false, true, false };
    for (want, 0..) |w, i| try testing.expectEqual(w, !try matchesPyro(&env.lay, env.elem(0, i)));
}
