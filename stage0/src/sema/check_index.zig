//! Indexing, slicing and ranges (§6.5): `e[i]`, `e[a..b]` and `a..b`, the
//! places they name and whether those may be written (§5.5.1, §6.5.4), and
//! array-to-slice views (§4.9.1).
//!
//! A place keeps the binding it belongs to (its root) and whether it is
//! mutable: an element or slice of a mutable place is mutable, of anything
//! else read-only. Values that are not places (calls, literals) are spilled
//! to a read-only temporary when indexed.

const std = @import("std");
const Ast = @import("../ast/Ast.zig");
const Types = @import("types.zig");
const emit_tir = @import("emit_tir.zig");
const check_expr = @import("check_expr.zig");
const check_call = @import("check_call.zig");
const tir = @import("../tir/tir.zig");

const Node = Ast.Node;
const TypeId = Types.TypeId;
const Checker = emit_tir.Checker;
const Typed = emit_tir.Typed;
const Error = emit_tir.Error;

/// The storage a place expression names.
pub const Place = struct {
    /// The place instruction; `.none` when `ty` is `.err` or `.noreturn`.
    ref: tir.Ref = .none,
    /// The type of the storage; `.err` after a diagnostic, `.noreturn` in
    /// dead code.
    ty: TypeId,
    /// The binding the storage belongs to; `.none` for a temporary.
    root: tir.Local = .none,
    /// Whether the storage may be written (§5.5.1, §6.5.4).
    mutable: bool = false,

    fn bad(p: Place) bool {
        return p.ty == .err or p.ty == .noreturn;
    }
};

/// `e[i]` (§6.5.2) or `e[a..b]` (§6.5.4) as a value.
pub fn index(c: *Checker, n: Node.Index, _: TypeId) Error!Typed {
    if (isSlice(c.ast, n)) return (try sliceOf(c, n)).value;
    const p = try elemPlace(c, n);
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

/// The storage expression `n` names: a binding, `self`, or an element of
/// a place. Any other expression, and a slice, is evaluated and stored in
/// a temporary; a slice keeps the root and mutability of what it views.
pub fn place(c: *Checker, n: Node.Index) Error!Place {
    switch (c.ast.kind(n)) {
        .paren => return place(c, c.ast.data(n).paren.inner),
        .index => if (!isSlice(c.ast, n)) return elemPlace(c, n),
        else => if (check_call.localOf(c, n)) |l| {
            const info = c.b.locals.get(l.int());
            return .{
                .ref = try c.emit(info.ty, .{ .local = .{ .local = l } }),
                .ty = info.ty,
                .root = l,
                .mutable = switch (info.kind) {
                    .let_mut, .param_mut, .temp => true,
                    .let, .param, .param_move => false,
                },
            };
        },
    }
    if (c.ast.kind(n) == .index) {
        const s = try sliceOf(c, n);
        return spill(c, s.value, n, s.base.root, s.base.mutable);
    }
    return spill(c, try check_expr.check(c, n, .none), n, .none, false);
}

/// Assignment target `e[i]` (§3.5): its place, or null after E0337, E0338
/// or E0207 if it may not be written.
pub fn writable(c: *Checker, n: Node.Index) Error!?Place {
    const p = try place(c, n);
    if (p.bad()) return null;
    if (p.mutable) return p;
    var root = n; // the diagnostic points at the indexed binding
    while (c.ast.kind(root) == .index or c.ast.kind(root) == .paren)
        root = if (c.ast.kind(root) == .index) c.ast.data(root).index.lhs else c.ast.data(root).paren.inner;
    const tok = c.ast.mainToken(root);
    if (p.root != .none) {
        const info = c.b.locals.get(p.root.int());
        const name = c.types.strings.get(info.name);
        switch (info.kind) {
            .let => {
                try c.reportAt(tok, .E0337, &.{"declare it with `let mut` to allow writes"}, "cannot assign to an element of `{s}`: it is an immutable binding", .{name});
                return null;
            },
            .param, .param_move => {
                try c.reportAt(tok, .E0338, &.{"declare the parameter `mut` to write through it"}, "cannot assign to an element of parameter `{s}`: it is not `mut`", .{name});
                return null;
            },
            .let_mut, .param_mut, .temp => {},
        }
    }
    try c.reportAt(tok, .E0207, &.{"only elements of a mutable binding or `mut` parameter can be assigned; `str` bytes are read-only"}, "cannot assign to this element: it is not a mutable place", .{});
    return null;
}

/// Array (or SoA array) place `v`, a `load`, viewed as slice type `to`
/// (§4.9.1): a read-only view of the place it was loaded from.
pub fn arrayToSlice(c: *Checker, v: Typed, to: TypeId) Error!Typed {
    return .{ .ty = to, .ref = try c.emit(to, .{ .view = .{ .place = c.b.data(v.ref).load.place } }) };
}

/// `v` stored in a fresh temporary.
fn spill(c: *Checker, value: Typed, at: Node.Index, root: tir.Local, mutable: bool) Error!Place {
    const v = try c.materialize(value, at);
    if (v.ty == .err or v.ty == .noreturn) return .{ .ty = v.ty };
    const l = try c.b.addLocal(.{ .ty = v.ty, .name = .none, .kind = .temp, .node = at });
    const p = try c.emit(v.ty, .{ .local = .{ .local = l } });
    _ = try c.emit(.void, .{ .store = .{ .place = p, .value = v.ref } });
    return .{ .ref = p, .ty = v.ty, .root = root, .mutable = mutable };
}

fn isSlice(ast: *const Ast, n: Node.Index) bool {
    return ast.kind(ast.data(n).index.index) == .range;
}

fn isInclusive(ast: *const Ast, n: Node.Index) bool {
    return ast.tokens.items(.kind)[ast.mainToken(n)] == .dot_dot_eq;
}

/// The place of `base`, through a `mut T` view to the storage it refers to.
fn basePlace(c: *Checker, base: Node.Index) Error!Place {
    var p = try place(c, base);
    if (p.bad()) return p;
    switch (c.types.get(p.ty)) {
        .mut_view => |v| {
            const view = try c.emit(p.ty, .{ .load = .{ .place = p.ref } });
            p = .{ .ref = try c.emit(v.elem, .{ .deref = .{ .ptr = view } }), .ty = v.elem, .root = p.root, .mutable = true };
        },
        else => {},
    }
    return p;
}

/// Element `e[i]` (§6.5.2): `i` is a `usize`; arrays, slices, SoA, `vec`
/// and `str` (bytes, read-only) can be indexed.
fn elemPlace(c: *Checker, n: Node.Index) Error!Place {
    const saved = c.b.node;
    c.b.node = n;
    defer c.b.node = saved;
    const d = c.ast.data(n).index;
    const base = try basePlace(c, d.lhs);
    if (base.bad()) return base;
    const u = c.underlying(base.ty);
    const elem: TypeId = if (u == .str) .int(.unsigned, 8) else switch (c.types.get(u)) {
        inline .array, .soa_array, .slice, .soa_slice, .vec => |x| x.elem,
        else => return notIndexable(c, n, base.ty, "indexed"),
    };
    const i = try check_expr.checkAs(c, d.index, .usize);
    if (i.ty == .err or i.ty == .noreturn) return .{ .ty = i.ty };
    return .{
        .ref = try c.emit(elem, .{ .index = .{ .base = base.ref, .index = i.ref } }),
        .ty = elem,
        .root = base.root,
        .mutable = base.mutable and u != .str,
    };
}

const Slice = struct { value: Typed, base: Place };

/// `e[a..b]` (§6.5.4): a slice of an array or slice, a SoA slice of SoA
/// storage, or a `str` of a `str`. Missing bounds default to 0 and `len`.
fn sliceOf(c: *Checker, n: Node.Index) Error!Slice {
    const d = c.ast.data(n).index;
    const base = try basePlace(c, d.lhs);
    if (base.bad()) return .{ .value = .{ .ty = base.ty }, .base = base };
    const u = c.underlying(base.ty);
    const ty: TypeId = if (u == .str) .str else switch (c.types.get(u)) {
        inline .array, .slice => |x| try c.types.intern(.{ .slice = .{ .elem = x.elem } }),
        inline .soa_array, .soa_slice => |x| try c.types.intern(.{ .soa_slice = .{ .elem = x.elem } }),
        else => return .{ .value = .{ .ty = (try notIndexable(c, n, base.ty, "sliced")).ty }, .base = base },
    };
    const r = c.ast.data(d.index).range;
    const lo = try bound(c, r.lo);
    var hi = try bound(c, r.hi);
    for ([_]?Typed{ lo, hi }) |b| if (b) |v| if (v.ty == .err or v.ty == .noreturn) return .{ .value = .{ .ty = v.ty }, .base = base };
    if (hi != null and isInclusive(c.ast, d.index)) {
        const one = try c.constant(.{ .type = .usize, .bits = 1 });
        hi = .{ .ty = .usize, .ref = try c.emit(.usize, .{ .add = .{ .lhs = hi.?.ref, .rhs = one.ref } }) };
    }
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
        \\    let q: soa []P = ps[..=i];
        \\    let total = sum(a) + sum(x[..2]);
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    _ = try f.func("views");
}

test "slice of an immutable place is read-only: E0336, E0337, E0338" {
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
        .{ .E0336, "mut" }, .{ .E0336, "mut" }, .{ .E0338, "a" }, .{ .E0337, "b" }, .{ .E0207, "t" },
    });
    _ = try f.func("ok");
}

test "indexing errors: E0310 for non-indexable bases and non-`usize` indices" {
    var f: Fixture = undefined;
    try f.init(
        \\fn bad(x: u32, a: [4]u8, i: i32, v: vec<4, f32>) {
        \\    let p = x[0];
        \\    let q = a[i];
        \\    let r = v[0..2];
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{ .{ .E0310, "[" }, .{ .E0310, "i" }, .{ .E0310, "[" } });
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
