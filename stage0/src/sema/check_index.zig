//! Indexing, slicing and ranges (§6.5): `e[i]`, `e[a..b]` and `a..b`, the
//! places they name and whether those may be written (§5.5.1, §6.5.4), and
//! array-to-slice views (§4.9.1).
//!
//! Places are `mutability.Place`s: an element or slice of a mutable place
//! is mutable, of anything else read-only. Values that are not places
//! (calls, literals) are spilled to a read-only temporary when indexed.

const std = @import("std");
const Ast = @import("../ast/Ast.zig");
const Types = @import("types.zig");
const emit_tir = @import("emit_tir.zig");
const check_expr = @import("check_expr.zig");
const check_call = @import("check_call.zig");
const unsafe = @import("unsafe.zig");
const builtins = @import("builtins.zig");
const mutability = @import("mutability.zig");
const tir = @import("../tir/tir.zig");

const Node = Ast.Node;
const Place = mutability.Place;
const TypeId = Types.TypeId;
const Checker = emit_tir.Checker;
const Typed = emit_tir.Typed;
const Error = emit_tir.Error;

/// `e[i]` (§6.5.2) or `e[a..b]` (§6.5.4) as a value.
pub fn index(c: *Checker, n: Node.Index, _: TypeId) Error!Typed {
    if (isSlice(c.ast, n)) return (try sliceOf(c, n, .read)).value;
    const p = try elemPlace(c, n, .read);
    if (p.bad()) return .{ .ty = p.ty };
    return .{ .ty = p.ty, .ref = try c.emit(p.ty, .{ .load = .{ .place = p.ref } }) };
}

/// `a..b` / `a..=b` outside index brackets (§6.5.1): a `Range<T>` /
/// `RangeInclusive<T>` value with integer `T`, `usize` for two untyped
/// constants unless `expected` is a range type.
pub fn range(c: *Checker, n: Node.Index, expected: TypeId) Error!Typed {
    const d = c.ast.data(n).range;
    const lo_node = d.lo orelse return openRange(c, n);
    const hi_node = d.hi orelse return openRange(c, n);
    const name = if (isInclusive(c.ast, n)) "RangeInclusive" else "Range";
    const want = rangeElem(c, expected, name);
    var lo = try check_expr.check(c, lo_node, want);
    var hi = try check_expr.check(c, hi_node, if (want != .none or lo.isUntyped()) want else lo.ty);
    if (lo.ty == .err or hi.ty == .err) return .err;
    if (lo.ty == .noreturn or hi.ty == .noreturn) return .never;
    const t: TypeId = if (want != .none) want else if (!lo.isUntyped()) lo.ty else if (!hi.isUntyped()) hi.ty else .usize;
    if (!(t == .usize or t == .isize or c.types.get(t) == .int)) {
        try c.report(n, .E0310, "range bounds must be integers, found `{s}`", .{try c.tyName(t)});
        return .err;
    }
    lo = try c.coerce(lo, t, lo_node);
    hi = try c.coerce(hi, t, hi_node);
    if (lo.ty == .err or hi.ty == .err) return .err;
    const ty = try c.items.preludeInstance(name, &.{.{ .type = t }});
    // Fields `start`, `end` (§14.1.3).
    return .{ .ty = ty, .ref = try c.emit(ty, .{ .aggregate = .{ .elems = &.{ lo.ref, hi.ref } } }) };
}

fn openRange(c: *Checker, n: Node.Index) Error!Typed {
    try c.reportAt(c.ast.mainToken(n), null, &.{"give both bounds, or use the open range inside `[...]` to slice"}, "an open range is only allowed inside index brackets", .{});
    return .err;
}

/// `T` of an expected `Range<T>` (or `RangeInclusive<T>`, per `name`), or `.none`.
fn rangeElem(c: *Checker, expected: TypeId, name: []const u8) TypeId {
    if (expected == .none or expected == .err) return .none;
    return switch (c.types.get(expected)) {
        .nominal => |nm| if (std.mem.eql(u8, c.types.strings.get(nm.name), name) and nm.args.len == 1 and nm.args[0] == .type) nm.args[0].type else .none,
        else => .none,
    };
}

/// Array (or SoA array) place `v`, a `load`, viewed as slice type `to`
/// (§4.9.1): a read-only view of the place it was loaded from.
pub fn arrayToSlice(c: *Checker, v: Typed, to: TypeId) Error!Typed {
    return .{ .ty = to, .ref = try c.emit(to, .{ .view = .{ .place = c.b.data(v.ref).load.place } }) };
}

/// Whether index expression `n` is a slice `e[a..b]`.
pub fn isSlice(ast: *const Ast, n: Node.Index) bool {
    return ast.kind(ast.data(n).index.index) == .range;
}

fn isInclusive(ast: *const Ast, n: Node.Index) bool {
    return ast.tokens.items(.kind)[ast.mainToken(n)] == .dot_dot_eq;
}

/// Element `e[i]` (§6.5.2) of the place `e` names, used by `access`: `i`
/// is a `usize`; arrays, slices, SoA, `vec` and `str` (bytes, read-only)
/// can be indexed. The element keeps the root, mutability and
/// addressability of `e`.
pub fn elemPlace(c: *Checker, n: Node.Index, access: mutability.Access) Error!Place {
    const saved = c.b.node;
    c.b.node = n;
    defer c.b.node = saved;
    const d = c.ast.data(n).index;
    const base = try mutability.basePlace(c, d.lhs, access);
    if (base.bad()) return base;
    const u = c.underlying(base.ty);
    const elem: TypeId = if (u == .str) .int(.unsigned, 8) else switch (c.types.get(u)) {
        inline .array, .soa_array, .slice, .soa_slice, .vec => |x| x.elem,
        .ptr => |x| return ptrElem(c, n, base, x.elem, !x.is_const),
        else => return notIndexable(c, n, base.ty, "indexed"),
    };
    const i = try check_expr.checkAs(c, d.index, .usize);
    if (i.ty == .err or i.ty == .noreturn) return .{ .ty = i.ty };
    return .{
        .ref = try c.emit(elem, .{ .index = .{ .base = base.ref, .index = i.ref } }),
        .ty = elem,
        .root = base.root,
        .mutable = base.mutable and u != .str,
        .through_ptr = base.through_ptr,
        .unaddressable = base.unaddressable,
    };
}

/// `p[i]` for a raw pointer `p` (§12.2): `*@ptr_add(p, i)`, unchecked,
/// only inside `unsafe`.
fn ptrElem(c: *Checker, n: Node.Index, base: Place, elem: TypeId, mutable: bool) Error!Place {
    const ok = try unsafe.require(c, n, "indexing a raw pointer");
    const i = try check_expr.checkAs(c, c.ast.data(n).index.index, .isize);
    if (i.ty == .err or i.ty == .noreturn) return .{ .ty = i.ty };
    if (!ok) {
        c.failed = true;
        return .{ .ty = .err };
    }
    const p = try c.emit(base.ty, .{ .load = .{ .place = base.ref } });
    const args = try c.arena.dupe(tir.Ref, &.{ p, i.ref });
    const moved = try c.emit(base.ty, .{ .builtin = .{ .builtin = builtins.Builtin.ptr_add.id(), .args = args } });
    return .{ .ref = try c.emit(elem, .{ .deref = .{ .ptr = moved } }), .ty = elem, .mutable = mutable, .through_ptr = true };
}

/// A slice value and the place it views.
pub const Slice = struct { value: Typed, base: Place };

/// `e[a..b]` (§6.5.4): a slice of an array or slice, a SoA slice of SoA
/// storage, or a `str` of a `str`. Missing bounds default to 0 and `len`.
/// A bit field or `@packed` field cannot be viewed (E0308, §4.11.3).
pub fn sliceOf(c: *Checker, n: Node.Index, access: mutability.Access) Error!Slice {
    const d = c.ast.data(n).index;
    const base = try mutability.basePlace(c, d.lhs, access);
    if (base.bad()) return .{ .value = .{ .ty = base.ty }, .base = base };
    if (base.unaddressable) {
        try c.reportAt(mutability.rootToken(c.ast, d.lhs), .E0308, &.{"copy it out and slice the copy (§4.11.3)"}, "a field of a `@packed` struct has no address: it cannot be sliced", .{});
        return .{ .value = .err, .base = .{ .ty = .err } };
    }
    const u = c.underlying(base.ty);
    const ty: TypeId = if (u == .str) .str else switch (c.types.get(u)) {
        inline .array, .slice => |x| try c.types.intern(.{ .slice = .{ .elem = x.elem } }),
        inline .soa_array, .soa_slice => |x| try c.types.intern(.{ .soa_slice = .{ .elem = x.elem } }),
        else => return .{ .value = .{ .ty = (try notIndexable(c, n, base.ty, "sliced")).ty }, .base = base },
    };
    const r = c.ast.data(d.index).range;
    if (isInclusive(c.ast, d.index)) { // §6.5.4 defines only `a..b` and its open forms
        try c.report(d.index, .E0310, "an inclusive range `..=` cannot slice; use `a..b`", .{});
        return .{ .value = .{ .ty = .err }, .base = base };
    }
    const lo = try bound(c, r.lo);
    const hi = try bound(c, r.hi);
    for ([_]?Typed{ lo, hi }) |b| if (b) |v| if (v.ty == .err or v.ty == .noreturn) return .{ .value = .{ .ty = v.ty }, .base = base };
    const ref = try c.emit(ty, .{ .slice = .{ .base = base.ref, .lo = if (lo) |v| v.ref else null, .hi = if (hi) |v| v.ref else null } });
    return .{ .value = .{ .ty = ty, .ref = ref }, .base = base };
}

fn bound(c: *Checker, b: ?Node.Index) Error!?Typed {
    return if (b) |x| try check_expr.checkAs(c, x, .usize) else null;
}

fn notIndexable(c: *Checker, n: Node.Index, ty: TypeId, what: []const u8) Error!Place {
    if (c.types.get(ty) == .nominal) return .{ .ty = c.unsupported(n, "indexing through `Indexable` (T163)").ty };
    try c.report(n, .E0310, "`{s}` cannot be {s}", .{ try c.tyName(ty), what });
    return .{ .ty = .err };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const Fixture = emit_tir.Fixture;

test "§12.2 `p[i]` on a raw pointer: unsafe only, writable through `*T` only" {
    var f: Fixture = undefined;
    try f.init(
        \\fn ok(p: *u32, q: *const u32) -> u32 { unsafe { p[1] = 2; p[0] + q[1] } }
        \\fn bad(p: *u32, q: *const u32) -> u32 { unsafe { q[0] = 3; } p[0] }
    );
    defer f.deinit();
    try f.expectDiags(&.{ .{ .E0337, "q" }, .{ .E1202, "[" } });
}

test "`s[0]` on `str` is `u8`; elements of arrays, slices and `vec`s" {
    var f: Fixture = undefined;
    try f.init(
        \\fn byte(s: str) -> u8 { s[0] }
        \\fn rows(a: [4]u32, s: []f32, v: vec<4, f32>, i: usize) -> f32 {
        \\    let x: u32 = a[3] + a[i];
        \\    s[i] + v[1]
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    try f.expectDump("byte",
        \\fn byte(l0 s: str) -> u8 {
        \\b0:
        \\  %0: str = local l0
        \\  %1: usize = int 0
        \\  %2: u8 = index %0, %1
        \\  %3: u8 = load %2
        \\  ret %3
        \\}
        \\
    );
    _ = try f.func("rows");
}

test "`0..10` is `Range<usize>`; bounds take the expected or a bound's type" {
    var f: Fixture = undefined;
    try f.init(
        \\fn r() { let a = 0..10; }
        \\fn typed(n: u32) { let b = 0..n; let c: RangeInclusive<u8> = 1..=9; }
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    try f.expectDump("r",
        \\fn r() -> void {
        \\  l0 a: Range<usize>
        \\b0:
        \\  %0: usize = int 0
        \\  %1: usize = int 10
        \\  %2: Range<usize> = aggregate [%0, %1]
        \\  %3: Range<usize> = local l0
        \\  store %3, %2
        \\  ret _
        \\}
        \\
    );
    _ = try f.func("typed");
}

test "range errors: open range outside brackets, non-integer bounds" {
    var f: Fixture = undefined;
    try f.init(
        \\fn open() { let a = 0..; }
        \\fn all() { let b = ..; }
        \\fn float(x: f32) { let c = x..2.0; }
    );
    defer f.deinit();
    try f.expectDiags(&.{ .{ null, ".." }, .{ null, ".." }, .{ .E0310, ".." } });
}

test "slices: views of arrays, slices, `str` and SoA; open bounds" {
    var f: Fixture = undefined;
    try f.init(
        \\struct P { x: f32 }
        \\fn sum(xs: []u32) -> u32 { xs[0] }
        \\fn views(a: [4]u32, s: str, ps: soa [8]P, i: usize) {
        \\    let x: []u32 = a[1..3];
        \\    let y: []u32 = a[..];
        \\    let t: str = s[i..];
        \\    let q: soa []P = ps[..i];
        \\    let total = sum(a) + sum(x[..2]);
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    _ = try f.func("views");
}

test "slice of an immutable place is read-only: E0337, E0338" {
    var f: Fixture = undefined;
    try f.init(
        \\fn fill(mut xs: []u8) {}
        \\fn bump(mut x: u8) {}
        \\fn ok(mut a: [4]u8) {
        \\    fill(mut a[1..]);
        \\    bump(mut a[0]);
        \\    a[0..2][1] = 3;
        \\    a[2] += 1;
        \\}
        \\fn bad(a: [4]u8, s: str) {
        \\    let b = [1u8, 2, 3];
        \\    let mut t = s;
        \\    fill(mut a[1..]);
        \\    bump(mut b[0]);
        \\    a[0..2][1] = 3;
        \\    b[1] = 0;
        \\    t[0] = 65;
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{
        .{ .E0338, "mut" }, .{ .E0337, "mut" }, .{ .E0338, "a" }, .{ .E0337, "b" }, .{ .E0207, "t" },
    });
    _ = try f.func("ok");
}

test "E0207: a slice is not an assignment target; a diverging index diverges" {
    var f: Fixture = undefined;
    try f.init(
        \\fn die() -> noreturn { loop {} }
        \\fn f(mut a: [4]u8, b: []u8) {
        \\    a[0..2] = b;
        \\    (a[..]) += b;
        \\}
        \\fn g(mut a: [2]u8) -> u8 { a[die()] = 0; }
    );
    defer f.deinit();
    try f.expectDiags(&.{ .{ .E0207, "[" }, .{ .E0207, "[" } });
}

test "indexing errors: E0310 for non-indexable bases and non-`usize` indices" {
    var f: Fixture = undefined;
    try f.init(
        \\fn bad(x: u32, a: [4]u8, i: i32, v: vec<4, f32>) {
        \\    let p = x[0];
        \\    let q = a[i];
        \\    let r = v[0..2];
        \\    let s = a[0..=2];
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{ .{ .E0310, "[" }, .{ .E0310, "i" }, .{ .E0310, "[" }, .{ .E0310, "..=" } });
}

test "E0303: `vec` element type and length" {
    var f: Fixture = undefined;
    try f.init(
        \\type Wide = vec<65, f32>;
        \\type Empty = vec<0, u32>;
        \\type Texts = vec<4, str>;
        \\type Big = vec3<P>;
        \\struct P { x: u8 }
        \\type Fine = vec<64, u64>;
        \\fn f(v: vec4<bool>, w: vec<8, usize>) {}
    );
    defer f.deinit();
    try f.expectDiags(&.{ .{ .E0303, "vec" }, .{ .E0303, "vec" }, .{ .E0303, "vec" }, .{ .E0303, "vec3" } });
}
