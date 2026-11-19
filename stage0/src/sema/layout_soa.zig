//! Non-default layouts (§4.11.3, §4.11.5, §4.11.6), extending `layout.zig`'s
//! `Engine`:
//!
//! - `@packed` structs: declaration order, every alignment 1, bit-field runs
//!   still packed into units;
//! - `@c_layout` structs: the target C ABI order (declaration order, natural
//!   alignment, no bit fields), and their fields' C representation (E1201);
//! - `soa [N]T` and `soa []T`, and `[N]T`/`[]T` of an `@soa` struct: one
//!   64-aligned column per field, or one pointer per column plus a length;
//!   `T` must be a struct (E0305);
//! - `@cold` fields, which containers store apart (metadata only: the
//!   struct's own layout is unchanged).

const std = @import("std");
const Ast = @import("../ast/Ast.zig");
const module_graph = @import("../resolve/module_graph.zig");
const Types = @import("types.zig");
const items_mod = @import("items.zig");
const layout = @import("layout.zig");
const ctype = @import("ctype.zig");

const Items = items_mod.Items;
const Engine = layout.Engine;
const Layout = layout.Layout;
const Place = layout.Place;
const TypeId = Types.TypeId;
const Node = Ast.Node;
const ModuleId = module_graph.ModuleId;
const Error = std.mem.Allocator.Error;

/// Alignment of SoA columns and of a `soa [N]T` value (§4.11.5).
pub const column_align = 64;

/// A struct layout that keeps declaration order (§4.11.3).
pub const Mode = enum {
    /// `@packed`: every alignment 1, bit-field runs packed as in §4.11.2.
    @"packed",
    /// `@c_layout`: natural alignment, sub-byte integers in their storage
    /// size, no bit fields.
    c,
};

/// Lays out fields `tys` in declaration order (§4.11.3). `aligns` holds each
/// field's `@align(n)` (0 if none), which `@packed` ignores; `min_align` is
/// the struct's `@align(n)`.
pub fn ordered(e: *Engine, tys: []const TypeId, aligns: []const u32, min_align: u32, mode: Mode) Error!?Layout {
    const places = try e.arena.allocator().alloc(Place, tys.len);
    var off: u64 = 0;
    var al: u32 = @max(1, min_align);
    // The open bit-field unit: its offset and bits used.
    var unit: ?u64 = null;
    var bits: u32 = 0;
    var units: u32 = 0;
    for (tys, aligns, places) |t, forced, *p| {
        if (if (mode == .@"packed") e.bitWidth(t) else null) |w| {
            if (unit == null or bits + w > 64) {
                if (unit) |u| off = u + layout.storage(bits).size;
                unit = off;
                bits = 0;
                units += 1;
            }
            p.* = .{ .offset = unit.?, .unit = units - 1, .bit_offset = @intCast(bits), .width = w };
            bits += w;
        } else {
            if (unit) |u| off = u + layout.storage(bits).size;
            unit = null;
            const l = try e.layoutOf(t) orelse return null;
            const a: u32 = if (mode == .@"packed") 1 else @max(l.@"align", forced);
            off = layout.alignUp(off, a);
            p.* = .{ .offset = off };
            off +|= l.size;
            al = @max(al, a);
        }
    }
    if (unit) |u| off = u + layout.storage(bits).size;
    return .{ .size = layout.alignUp(off, al), .@"align" = al, .fields = places };
}

/// Whether `ty` is an `@soa` struct, whose arrays and slices use SoA layout
/// (§4.11.5).
pub fn isSoa(e: *Engine, ty: TypeId) bool {
    const s = e.items.structOf(ty) orelse return false;
    return e.attr(e.items.declRef(ty).?.module, s.attrs, .soa) != null;
}

/// The field types of struct `ty`, in declaration order, or null if `ty` is
/// not a checked struct.
fn fieldTypes(e: *Engine, ty: TypeId) Error!?[]const TypeId {
    const s = e.items.structOf(ty) orelse return null;
    const n = e.items.types.get(ty).nominal;
    const tys = try e.arena.allocator().alloc(TypeId, s.fields.len);
    for (s.fields, tys) |f, *t| t.* = try e.items.subst(f.type, n.decl, n.args);
    return tys;
}

/// `soa [len]elem` (§4.11.5): one place per field, the base of its column.
/// Column i holds `len` elements of the field's storage size; each column
/// starts on a 64-byte boundary. Null unless `elem` is a struct.
pub fn soaArray(e: *Engine, len: u64, elem: TypeId) Error!?Layout {
    const tys = try fieldTypes(e, elem) orelse return null;
    const places = try e.arena.allocator().alloc(Place, tys.len);
    var end: u64 = 0;
    for (tys, places) |t, *p| {
        const l = try e.layoutOf(t) orelse return null;
        p.* = .{ .offset = layout.alignUp(end, column_align) };
        end = p.offset +| len *| layout.alignUp(l.size, l.@"align");
    }
    return .{ .size = layout.alignUp(end, column_align), .@"align" = column_align, .fields = places };
}

/// `soa []elem` (§4.11.5): one column pointer per field, then a `usize`
/// length. One place per field, its column pointer. Null unless `elem` is a
/// struct.
pub fn soaSlice(e: *Engine, elem: TypeId) Error!?Layout {
    const s = e.items.structOf(elem) orelse return null;
    const ptr: u32 = e.items.options.ptr_bits / 8;
    const places = try e.arena.allocator().alloc(Place, s.fields.len);
    for (places, 0..) |*p, i| p.* = .{ .offset = i * ptr };
    return .{ .size = (s.fields.len + 1) * ptr, .@"align" = ptr, .fields = places };
}

/// Indices of the `@cold` fields of struct `ty`, in declaration order
/// (§4.11.6). `Pool<T>`, `List<T>` and `Table` store them in a separate
/// parallel array; elsewhere they are ordinary fields.
pub fn coldFields(e: *Engine, ty: TypeId) Error![]const u32 {
    const s = e.items.structOf(ty) orelse return &.{};
    const m = e.items.declRef(ty).?.module;
    var out: std.ArrayList(u32) = .empty;
    for (s.fields, 0..) |f, i| if (e.attr(m, f.attrs, .cold) != null) try out.append(e.arena.allocator(), @intCast(i));
    return out.items;
}

/// Reports E1201 on each field of `@c_layout` struct `s` (module `m`) whose
/// type has no C representation (§4.11.3, §12.5).
pub fn checkCFields(e: *Engine, m: ModuleId, s: items_mod.Struct) Error!void {
    const a = e.items.im.graph.modules[m].ast;
    for (s.fields) |f| {
        if (ctype.isCompatible(e.items.types, f.type, .{ .pos = .field }, e)) continue;
        try e.items.report(m, items_mod.typeToken(a, a.data(f.node).field_decl.ty), .E1201, &.{}, "field `{s}` of a `@c_layout` struct has type `{s}`, which is not C-compatible", .{ f.name, try e.items.tyName(f.type) });
    }
}

/// Resolves the element type `n` of a `soa [N]T` or `soa []T` type
/// expression and reports E0305 unless it is a struct (§4.4.2). Generic
/// parameters are checked at instantiation.
pub fn elemType(it: *Items, m: ModuleId, n: Node.Index, self_ty: TypeId) Error!TypeId {
    const t = try it.resolveType(m, n, self_ty);
    const ok = t == .err or switch (it.types.get(t)) {
        .param => true,
        .nominal => |nom| nom.kind == .@"struct",
        else => false,
    };
    if (!ok) try it.report(m, items_mod.typeToken(it.im.graph.modules[m].ast, n), .E0305, &.{}, "`soa` element type `{s}` is not a struct", .{try it.tyName(t)});
    return t;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const Fixture = layout.Fixture;
const expectLayout = layout.expectLayout;

/// The layout of the type that alias `name` denotes.
fn aliasLayout(f: *Fixture, name: []const u8) !Layout {
    return (try f.e.layoutOf((try f.info(name)).alias)).?;
}

test "§4.11.5 soa [10]{a: u8, b: f32}: base_b 64, size 128; @soa arrays match" {
    var f: Fixture = undefined;
    try f.init(
        \\struct E { a: u8, b: f32 }
        \\@soa struct S { a: u8, b: f32 }
        \\struct Bits { a: u3, b: bool, c: E }
        \\struct Empty {}
        \\type A = soa [10]E;
        \\type B = [10]S;
        \\type C = soa [100]Bits;
        \\type D = soa [0]E;
        \\type Z = soa [5]Empty;
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    for ([_][]const u8{ "A", "B" }) |name| {
        const l = try aliasLayout(&f, name);
        try expectLayout(128, 64, l);
        try testing.expectEqualSlices(Place, &.{ .{ .offset = 0 }, .{ .offset = 64 } }, l.fields);
    }
    // Sub-byte and bool columns use storage size; a struct field is one AoS column.
    const c = try aliasLayout(&f, "C");
    try expectLayout(1088, 64, c);
    try testing.expectEqualSlices(Place, &.{ .{ .offset = 0 }, .{ .offset = 128 }, .{ .offset = 256 } }, c.fields);
    try expectLayout(0, 64, try aliasLayout(&f, "D"));
    try expectLayout(0, 64, try aliasLayout(&f, "Z"));
}

test "§4.11.5 soa []T and []T of an @soa struct: column pointers then length" {
    var f: Fixture = undefined;
    try f.init(
        \\struct E { a: u8, b: f32, c: u64 }
        \\@soa struct S { a: u8, b: f32 }
        \\type A = soa []E;
        \\type B = []S;
        \\type C = []E;
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    const a = try aliasLayout(&f, "A");
    try expectLayout(32, 8, a);
    try testing.expectEqualSlices(Place, &.{ .{ .offset = 0 }, .{ .offset = 8 }, .{ .offset = 16 } }, a.fields);
    try expectLayout(24, 8, try aliasLayout(&f, "B"));
    try expectLayout(16, 8, try aliasLayout(&f, "C"));
    try testing.expect(isSoa(&f.e, try f.typeOf("S")));
    try testing.expect(!isSoa(&f.e, try f.typeOf("E")));
}

test "§4.11.3 @soa structs never bit-pack" {
    var f: Fixture = undefined;
    try f.init(
        \\@soa struct S { a: u3, b: bool, c: u32 }
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    const s = try f.of("S");
    for (s.fields) |p| try testing.expectEqual(0, p.width);
    try expectLayout(8, 4, s);
}

test "§4.11.3 @packed: declaration order, align 1, bit fields still packed" {
    var f: Fixture = undefined;
    try f.init(
        \\@packed struct P { a: u8, b: u32 }
        \\@packed struct Q { a: u3, b: u5, c: u32, d: bool, @align(8) e: u16 }
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    const p = try f.of("P");
    try expectLayout(5, 1, p);
    try testing.expectEqualSlices(Place, &.{ .{ .offset = 0 }, .{ .offset = 1 } }, p.fields);
    const q = try f.of("Q");
    try expectLayout(8, 1, q);
    try testing.expectEqualSlices(Place, &.{
        .{ .offset = 0, .unit = 0, .width = 3 },
        .{ .offset = 0, .unit = 0, .bit_offset = 3, .width = 5 },
        .{ .offset = 1 },
        .{ .offset = 5, .unit = 1, .width = 1 },
        .{ .offset = 6 },
    }, q.fields);
}

test "§4.11.3 @c_layout: C order, natural alignment, storage-size integers" {
    var f: Fixture = undefined;
    try f.init(
        \\@c_layout struct C { a: bool, b: u3, c: u32 }
        \\@c_layout struct D { a: u8, b: f64, c: u16, d: [3]u8 }
        \\@align(16) @c_layout struct E { a: u8 }
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    const c = try f.of("C");
    try expectLayout(8, 4, c);
    try testing.expectEqualSlices(Place, &.{ .{ .offset = 0 }, .{ .offset = 1 }, .{ .offset = 4 } }, c.fields);
    const d = try f.of("D");
    try expectLayout(24, 8, d);
    try testing.expectEqualSlices(Place, &.{ .{ .offset = 0 }, .{ .offset = 8 }, .{ .offset = 16 }, .{ .offset = 18 } }, d.fields);
    try expectLayout(16, 16, try f.of("E"));
}

test "E1201: @c_layout fields must be C-compatible" {
    var f: Fixture = undefined;
    try f.init(
        \\@c_layout struct Inner { x: i32 }
        \\struct Plain { x: i32 }
        \\@c_layout struct Header {
        \\    tag: u32, name: str, items: []u8, counts: [4]u16, inner: Inner, plain: Plain, p: *const Plain,
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{ .{ .E1201, "str" }, .{ .E1201, "[" }, .{ .E1201, "Plain" } });
}

test "E1201: generic @c_layout fields are not checked at the declaration" {
    var f: Fixture = undefined;
    try f.init(
        \\@c_layout struct G<T> { x: T }
    );
    defer f.deinit();
    try f.expectDiags(&.{});
}

test "E0305: soa of a non-struct type" {
    var f: Fixture = undefined;
    try f.init(
        \\struct P { x: f32 }
        \\enum K { a }
        \\type Ok = soa [4]P;
        \\type Bad = soa [4]u32;
        \\type BadEnum = soa [2]K;
        \\fn total(xs: soa []f32, ps: soa []P) -> usize { 0 }
        \\fn generic<T>(xs: soa []T) {}
    );
    defer f.deinit();
    try f.expectDiags(&.{ .{ .E0305, "u32" }, .{ .E0305, "K" }, .{ .E0305, "f32" } });
    try testing.expectEqual(@as(?Layout, null), try f.e.layoutOf((try f.info("Bad")).alias));
}

test "§4.11.6 @cold fields are metadata only" {
    var f: Fixture = undefined;
    try f.init(
        \\struct T { hot: u32, @cold name: [16]u8, x: f32, @cold notes: u64 }
        \\struct H { a: u32 }
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    try testing.expectEqualSlices(u32, &.{ 1, 3 }, try coldFields(&f.e, try f.typeOf("T")));
    try testing.expectEqual(0, (try coldFields(&f.e, try f.typeOf("H"))).len);
    try expectLayout(32, 8, try f.of("T"));
}
