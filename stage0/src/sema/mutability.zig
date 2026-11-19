//! Places, mutability and addressability (§1.6, §5.5.1, §5.5.3, §5.5.4,
//! §4.5.3, §4.11.2, §4.11.3).
//!
//! One place model serves reads, assignments, `mut` arguments, `mut self`
//! receivers and `mut T` views:
//!
//! - `operand` walks a place expression: a binding or `self`, a field of a
//!   place (`check_member.fieldPlace`), an element or slice of one
//!   (`check_index.elemPlace`), or `*p` (§12.2), in any mix. A `mut T` view
//!   on the way is followed to the storage it refers to. Each step keeps
//!   the binding the storage belongs to (its root), whether it may be
//!   written, and whether it is addressable.
//! - `require` checks that a place may be written by a use: E0337 through
//!   an immutable binding or a `*const` pointer, E0338 through a parameter
//!   without `mut`, E0308 for a `mut` use of a bit field or `@packed` field,
//!   else E0207 (assignment) or E0336.
//! - `mutArg` and `viewMut` give the place of a `mut` argument and a
//!   `mut T` view of a mutable place (`let p: mut T = place;`,
//!   `return self;` from `-> mut Self`).

const std = @import("std");
const Ast = @import("../ast/Ast.zig");
const Types = @import("types.zig");
const emit_tir = @import("emit_tir.zig");
const check_expr = @import("check_expr.zig");
const check_call = @import("check_call.zig");
const check_member = @import("check_member.zig");
const check_index = @import("check_index.zig");
const unsafe = @import("unsafe.zig");
const layout = @import("layout.zig");
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
    /// The binding the storage belongs to; `.none` for a temporary or
    /// storage reached through a raw pointer.
    root: tir.Local = .none,
    /// Whether the storage may be written (§5.5.1, §6.5.4).
    mutable: bool = false,
    /// Reached through a raw pointer (§12.2).
    through_ptr: bool = false,
    /// A bit field or a field of a `@packed` struct, or part of one: it can
    /// be read and assigned but not viewed or passed as `mut` (§4.11.2,
    /// §4.11.3).
    unaddressable: bool = false,

    /// After a diagnostic or in dead code.
    pub fn bad(p: Place) bool {
        return p.ty == .err or p.ty == .noreturn;
    }
};

/// How a place is used while walking it.
pub const Access = enum {
    read,
    /// Written: fields must be writable here (`pub mut` outside their
    /// module, §7.3.3).
    write,
};

/// An expression checked as a place if it is one, else as a value.
pub const Operand = union(enum) { place: Place, value: Typed };

/// What a place is needed for, for `require`'s diagnostics.
pub const Use = union(enum) {
    assign,
    /// A `mut` argument; the payload is the `mut_arg` node.
    mut_arg: Node.Index,
    /// The receiver of a `mut self` method.
    receiver,
    /// The origin of a `mut T` view.
    view,
};

/// `n` as a place (§1.6): a local, `self`, a field or element of a place,
/// or `*p`, followed through `mut T` views. A field of a value is the
/// field's value; an element of a value is an element of a read-only
/// temporary. Anything else is checked as a value.
pub fn operand(c: *Checker, n: Node.Index, access: Access) Error!Operand {
    const ast = c.ast;
    const p: Place = switch (ast.kind(n)) {
        .paren => return operand(c, ast.data(n).paren.inner, access),
        .ident, .self_value => if (check_call.localOf(c, n)) |l| try local(c, l) else return asValue(c, n),
        .field_access => blk: {
            const lhs = ast.data(n).field_access.lhs;
            // A module member or a member of a type is a name, not a place.
            if (c.items.names.get(c.m, n) != null or try check_member.typePath(c, lhs) != null) return asValue(c, n);
            const base = switch (try operand(c, lhs, access)) {
                .place => |b| b,
                .value => |v| if (v.ty != .err and c.types.get(v.ty) == .mut_view)
                    try viewPlace(c, v)
                else
                    return .{ .value = try check_member.fieldOfValue(c, n, v) },
            };
            if (base.bad()) return .{ .place = base };
            break :blk try check_member.fieldPlace(c, n, base, access);
        },
        .index => if (check_index.isSlice(ast, n)) blk: {
            // A slice is a view value; indexing it keeps its origin's root
            // and mutability (§6.5.4).
            const s = try check_index.sliceOf(c, n, access);
            break :blk try spill(c, s.value, n, s.base.root, s.base.mutable);
        } else try check_index.elemPlace(c, n, access),
        .prefix => if (ast.tokens.items(.kind)[ast.mainToken(n)] == .star) blk: {
            const a = try unsafe.pointee(c, n) orelse {
                c.failed = true;
                break :blk .{ .ty = .err };
            };
            break :blk .{ .ref = a.ref, .ty = a.ty, .mutable = a.mutable, .through_ptr = true };
        } else return asValue(c, n),
        else => return asValue(c, n),
    };
    return .{ .place = try through(c, p) };
}

/// The place of `n`, the base of a field or element: a value is stored in a
/// read-only temporary, a `mut T` view value is followed.
pub fn basePlace(c: *Checker, n: Node.Index, access: Access) Error!Place {
    return switch (try operand(c, n, access)) {
        .place => |p| p,
        .value => |v| if (v.ty != .err and v.ty != .noreturn and c.types.get(v.ty) == .mut_view)
            viewPlace(c, v)
        else
            spill(c, v, n, .none, false),
    };
}

/// Checks that place `p` of expression `n` may be written by `use`,
/// reporting E0337, E0338, E0308, E0207 or E0336 if not.
pub fn require(c: *Checker, p: Place, n: Node.Index, use: Use) Error!bool {
    const tok = switch (use) {
        .mut_arg => |a| c.ast.mainToken(a),
        else => rootToken(c.ast, n),
    };
    if (!p.mutable) {
        try notMutable(c, p, n, tok, use);
        return false;
    }
    if (p.unaddressable and use != .assign) {
        const what = switch (use) {
            .assign => unreachable,
            .mut_arg => "be a `mut` argument",
            .receiver => "be the receiver of a `mut self` method",
            .view => "be viewed as `mut`",
        };
        try c.reportAt(tok, .E0308, &.{"copy it out, change it, and assign it back (§4.11.2)"}, "a bit field or a field of a `@packed` struct has no address: it cannot {s}", .{what});
        return false;
    }
    return true;
}

fn notMutable(c: *Checker, p: Place, n: Node.Index, tok: Ast.TokenIndex, use: Use) Error!void {
    if (p.through_ptr) {
        try c.reportAt(tok, .E0337, &.{"use a `*T` pointer to write through it"}, "cannot write through a `*const` pointer", .{});
        return;
    }
    if (p.root != .none) {
        const info = c.b.locals.get(p.root.int());
        const name = c.types.strings.get(info.name);
        const part = switch (c.ast.kind(unparen(c.ast, n))) {
            .field_access => "a field of ",
            .index => "an element of ",
            else => "",
        };
        switch (info.kind) {
            .let => {
                const help: []const []const u8 = &.{"declare it with `let mut` to allow writes"};
                return switch (use) {
                    .assign => c.reportAt(tok, .E0337, help, "cannot assign to {s}`{s}`: it is an immutable binding", .{ part, name }),
                    .mut_arg => c.reportAt(tok, .E0337, help, "`mut` argument writes through `{s}`: it is an immutable binding", .{name}),
                    .receiver => c.reportAt(tok, .E0337, help, "cannot call a `mut self` method on {s}`{s}`: it is an immutable binding", .{ part, name }),
                    .view => c.reportAt(tok, .E0337, help, "cannot view {s}`{s}` as `mut`: it is an immutable binding", .{ part, name }),
                };
            },
            .param, .param_move => {
                const help: []const []const u8 = &.{"declare the parameter `mut` to write through it"};
                return switch (use) {
                    .assign => c.reportAt(tok, .E0338, help, "cannot assign to {s}parameter `{s}`: it is not `mut`", .{ part, name }),
                    .mut_arg => c.reportAt(tok, .E0338, help, "`mut` argument writes through parameter `{s}`: it is not `mut`", .{name}),
                    .receiver => c.reportAt(tok, .E0338, help, "cannot call a `mut self` method on {s}parameter `{s}`: it is not `mut`", .{ part, name }),
                    .view => c.reportAt(tok, .E0338, help, "cannot view {s}parameter `{s}` as `mut`: it is not `mut`", .{ part, name }),
                };
            },
            .let_mut, .param_mut, .temp => {},
        }
    }
    // A temporary, or a read-only part of a mutable place (`str` bytes).
    return switch (use) {
        .assign => c.reportAt(tok, .E0207, &.{"only parts of a mutable binding or `mut` parameter can be assigned; `str` bytes are read-only"}, "cannot assign to this place: it is not mutable", .{}),
        .mut_arg => c.reportAt(tok, .E0336, &.{mut_arg_help}, "`mut` argument is not a mutable place", .{}),
        .receiver => c.reportAt(tok, .E0336, &.{"bind the value with `let mut` first"}, "receiver of a `mut` parameter is not a mutable place", .{}),
        .view => c.reportAt(tok, .E0336, &.{"view a `let mut` binding, a `mut` parameter, or a part of one"}, "a `mut` view needs a mutable place", .{}),
    };
}

const mut_arg_help = "pass a `let mut` binding, a `mut` parameter, or a field or element of one";

/// The mutable place `value` of `mut` argument `a` names (§5.5.2): a part
/// of a `let mut` binding, a `mut` parameter or `mut self`, a `mut T` view,
/// or `*p` for `p: *T` (§12.2). Null after a diagnostic (E0336 for a value
/// that is not a place); a place of type `.noreturn` if it diverges.
pub fn mutArg(c: *Checker, a: Node.Index, value: Node.Index) Error!?Place {
    const root = unparen(c.ast, rootOf(c.ast, value));
    switch (c.ast.kind(root)) {
        .self_value, .call => {},
        .prefix => if (c.ast.tokens.items(.kind)[c.ast.mainToken(root)] != .star) return notPlace(c, a),
        .ident => if (check_call.localOf(c, root) == null) {
            // A constant or function is not a place; an unknown name is reported.
            if (c.items.names.get(c.m, root) != null) return notPlace(c, a);
            _ = try check_expr.check(c, root, .none);
            return null;
        },
        // Literals and operators are values; they are not checked.
        else => return notPlace(c, a),
    }
    const p = switch (try operand(c, value, .write)) {
        .place => |p| p,
        .value => |v| if (v.ty == .err or v.ty == .noreturn)
            return if (v.ty == .noreturn) .{ .ty = .noreturn } else null
        else if (c.types.get(v.ty) == .mut_view)
            try viewPlace(c, v)
        else
            return notPlace(c, a),
    };
    if (p.ty == .err) return null;
    if (p.ty == .noreturn) return p;
    return if (try require(c, p, value, .{ .mut_arg = a })) p else null;
}

fn notPlace(c: *Checker, a: Node.Index) Error!?Place {
    try c.reportAt(c.ast.mainToken(a), .E0336, &.{mut_arg_help}, "`mut` argument is not a mutable place", .{});
    return null;
}

/// `n` as a value of view type `to` (`mut T`, §5.5.3): a `mut T` view of
/// the mutable place `n` names, or a value of type `to` (a `mut T` result).
pub fn viewMut(c: *Checker, n: Node.Index, to: TypeId) Error!Typed {
    const elem = c.types.get(to).mut_view.elem;
    const root = unparen(c.ast, rootOf(c.ast, n));
    const is_place = switch (c.ast.kind(root)) {
        .self_value => true,
        .ident => check_call.localOf(c, root) != null,
        .prefix => c.ast.tokens.items(.kind)[c.ast.mainToken(root)] == .star,
        else => false,
    };
    if (!is_place) return c.coerce(try check_expr.check(c, n, to), to, n);
    const p = switch (try operand(c, n, .write)) {
        .place => |p| p,
        .value => |v| return c.coerce(v, to, n),
    };
    if (p.bad()) return .{ .ty = p.ty };
    if (!try require(c, p, n, .view)) return .err;
    if (p.ty != elem) {
        try c.mismatch(n, to, p.ty);
        return .err;
    }
    return .{ .ty = to, .ref = try c.emit(to, .{ .view_mut = .{ .place = p.ref } }) };
}

/// Whether field `i` of `owner` (a struct or tuple) is not addressable: a
/// bit field (§4.11.2) or a field of a `@packed` struct (§4.11.3).
pub fn unaddressableField(c: *Checker, owner: TypeId, i: u32) bool {
    // `bitWidth` and `attr` only read the items: nothing is allocated.
    var lay: layout.Engine = .init(c.arena, c.items);
    switch (c.types.get(owner)) {
        .tuple => |t| return lay.bitWidth(t.elems[i]) != null,
        .nominal => {},
        else => return false,
    }
    const s = c.items.structOf(owner) orelse return false;
    const m = (c.items.declRef(owner) orelse return false).module;
    if (lay.attr(m, s.attrs, .@"packed") != null) return true;
    // `@c_layout` and `@soa` structs never bit-pack (§4.11.3).
    if (lay.attr(m, s.attrs, .c_layout) != null or lay.attr(m, s.attrs, .soa) != null) return false;
    // A field with `@align` is never packed into a unit.
    if (lay.attr(m, s.fields[i].attrs, .@"align") != null) return false;
    return lay.bitWidth(s.fields[i].type) != null;
}

/// `v` stored in a fresh temporary, with the given root and mutability.
pub fn spill(c: *Checker, value: Typed, at: Node.Index, root: tir.Local, mutable: bool) Error!Place {
    const v = try c.materialize(value, at);
    if (v.ty == .err or v.ty == .noreturn) return .{ .ty = v.ty };
    const l = try c.b.addLocal(.{ .ty = v.ty, .name = .none, .kind = .temp, .node = at });
    const p = try c.emit(v.ty, .{ .local = .{ .local = l } });
    _ = try c.emit(.void, .{ .store = .{ .place = p, .value = v.ref } });
    return .{ .ref = p, .ty = v.ty, .root = root, .mutable = mutable };
}

/// The storage `mut T` view value `v` refers to: mutable (§4.5.3).
fn viewPlace(c: *Checker, v: Typed) Error!Place {
    const elem = c.types.get(v.ty).mut_view.elem;
    return .{ .ref = try c.emit(elem, .{ .deref = .{ .ptr = v.ref } }), .ty = elem, .mutable = true };
}

/// `p`, or the storage it refers to if it holds a `mut T` view (§5.5.3).
fn through(c: *Checker, p: Place) Error!Place {
    if (p.bad() or c.types.get(p.ty) != .mut_view) return p;
    var q = try viewPlace(c, .{ .ty = p.ty, .ref = try c.emit(p.ty, .{ .load = .{ .place = p.ref } }) });
    q.root = p.root;
    return q;
}

fn local(c: *Checker, l: tir.Local) Error!Place {
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
}

fn asValue(c: *Checker, n: Node.Index) Error!Operand {
    return .{ .value = try c.materialize(try check_expr.check(c, n, .none), n) };
}

fn unparen(ast: *const Ast, n: Node.Index) Node.Index {
    var x = n;
    while (ast.kind(x) == .paren) x = ast.data(x).paren.inner;
    return x;
}

/// The expression a chain of fields and elements `n` starts from.
fn rootOf(ast: *const Ast, n: Node.Index) Node.Index {
    var x = n;
    while (true) switch (ast.kind(x)) {
        .paren => x = ast.data(x).paren.inner,
        .field_access => x = ast.data(x).field_access.lhs,
        .index => x = ast.data(x).index.lhs,
        else => return x,
    };
}

/// Where a mutability error of place `n` is reported: its root binding.
pub fn rootToken(ast: *const Ast, n: Node.Index) Ast.TokenIndex {
    return ast.mainToken(rootOf(ast, n));
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const Fixture = emit_tir.Fixture;

test "places mixing fields and elements: reads, writes and `mut` arguments" {
    var f: Fixture = undefined;
    try f.init(
        \\struct Item { pub mut count: u32 }
        \\struct Bag { pub mut items: [4]Item, pub mut ids: [4]u32 }
        \\fn heal(mut it: Item) { it.count += 1; }
        \\fn bump(mut n: u32) { n += 1; }
        \\fn edit(mut b: Bag, mut bags: []Bag, i: usize) -> u32 {
        \\    b.ids[i] = 1;
        \\    b.items[0].count += 2;
        \\    bags[i].ids[0] = 3;
        \\    (bags[i].items)[1].count = 4;
        \\    heal(mut b.items[0]);
        \\    bump(mut bags[i].items[i].count);
        \\    b.items[i].count + bags[0].ids[i]
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    _ = try f.func("edit");
}

test "mixed places: E0337, E0338 at the root, E0336 for values, field visibility kept" {
    var f: Fixture = undefined;
    try f.initPackage(&.{
        .{
            "a",
            \\use geo.{Pair, make};
            \\fn bump(mut n: u32) { n += 1; }
            \\fn edit(ps: [2]Pair, mut qs: [2]Pair) {
            \\    let rs = qs;
            \\    ps[0].x = 1;
            \\    rs[1].x = 2;
            \\    bump(mut rs[0].x);
            \\    bump(mut make()[0].x);
            \\    qs[0].y = 3;
            \\    qs[0].x = 4;
            \\}
        },
        .{ "geo", "pub struct Pair { pub mut x: u32, pub y: u32 }\npub fn make() -> [2]Pair { [Pair { x: 1, y: 2 }, Pair { x: 3, y: 4 }] }" },
    });
    defer f.deinit();
    try f.expectDiags(&.{
        .{ .E0338, "ps" }, .{ .E0337, "rs" }, .{ .E0337, "mut" }, .{ .E0336, "mut" }, .{ null, "y" },
    });
}

test "bit fields and `@packed` fields: assignable, not `mut` (E0308)" {
    var f: Fixture = undefined;
    try f.init(
        \\struct S { health_bits: u7, flag: bool, @align(1) aligned: bool, hp: u32 }
        \\@packed
        \\struct H { tag: u8, len: u32, bytes: [4]u8 }
        \\@c_layout
        \\struct C { on: bool }
        \\fn heal(mut n: u7) { n += 1; }
        \\fn grow(mut n: u32) { n += 1; }
        \\fn set(mut b: bool) { b = true; }
        \\fn ok(mut s: S, mut c: C, mut t: (u8, u32)) {
        \\    s.flag = true;
        \\    s.health_bits += 1;
        \\    grow(mut s.hp);
        \\    set(mut s.aligned);
        \\    set(mut c.on);
        \\    grow(mut t.1);
        \\}
        \\fn bad(mut s: S, mut h: H, mut t: (bool, u32)) {
        \\    heal(mut s.health_bits);
        \\    grow(mut h.len);
        \\    let v: mut bool = s.flag;
        \\    set(mut t.0);
        \\    let b = h.bytes[1..3];
        \\    h.len = 2;
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{ .{ .E0308, "mut" }, .{ .E0308, "mut" }, .{ .E0308, "s" }, .{ .E0308, "mut" }, .{ .E0308, "h" } });
    _ = try f.func("ok");
}

test "`let x = ...; x.f = 1` is E0337; receivers and `mut` arguments too" {
    var f: Fixture = undefined;
    try f.init(
        \\struct P { pub mut x: u32, pub fn bump(mut self) { self.x += 1; } }
        \\fn nudge(mut p: P) { p.x += 1; }
        \\fn edits() {
        \\    let x = P { x: 0 };
        \\    x.x = 1;
        \\    x.bump();
        \\    nudge(mut x);
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{ .{ .E0337, "x" }, .{ .E0337, "x" }, .{ .E0337, "mut" } });
}

test "`-> mut Self` chaining and `let p: mut T = place` write through (§5.5.3, §5.5.4)" {
    var f: Fixture = undefined;
    try f.init(
        \\struct Particle {
        \\    pub mut x: f32,
        \\    pub fn push(mut self, dx: f32) -> mut Self { self.x += dx; return self; }
        \\    pub fn get(self) -> f32 { self.x }
        \\}
        \\fn chain(mut p: Particle) -> f32 { p.push(1.0).push(2.0).get() }
        \\fn step(mut particles: []Particle, i: usize) {
        \\    let p: mut Particle = particles[i];
        \\    p.x = 1.0;
        \\}
        \\fn copy(mut q: Particle) -> f32 { let v: mut Particle = q; let c: Particle = v; c.x + v.x }
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    _ = try f.func("chain");
    _ = try f.func("copy");
    try f.expectDump("step",
        \\fn step(l0 mut particles: []Particle, l1 i: usize) -> void {
        \\  l2 p: mut Particle
        \\b0:
        \\  %0: []Particle = local l0
        \\  %1: usize = local l1
        \\  %2: usize = load %1
        \\  %3: Particle = index %0, %2
        \\  %4: mut Particle = view_mut %3
        \\  %5: mut Particle = local l2
        \\  store %5, %4
        \\  %7: mut Particle = local l2
        \\  %8: mut Particle = load %7
        \\  %9: Particle = deref %8
        \\  %10: f32 = field %9, 0
        \\  %11: f32 = float 1
        \\  store %10, %11
        \\  ret _
        \\}
        \\
    );
}

test "`mut T` views: of immutable places E0337/E0338, of values E0310" {
    var f: Fixture = undefined;
    try f.init(
        \\struct P { pub mut x: u32 }
        \\fn make() -> P { P { x: 1 } }
        \\fn views(p: P) {
        \\    let q = P { x: 2 };
        \\    let a: mut P = p;
        \\    let b: mut P = q;
        \\    let c: mut P = make();
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{ .{ .E0338, "p" }, .{ .E0337, "q" }, .{ .E0310, "(" } });
}

test "`mut` bindings of a `match` on a mutable place are views" {
    var f: Fixture = undefined;
    try f.init(
        \\struct P { x: u32, on: bool }
        \\fn get(mut o: Option<u32>) { match o { .some(mut v) => { v += 1; }, .none => {} } }
        \\fn bits(mut p: P) { match p { P { x: mut x, on: mut on } => { x += 1; } } }
    );
    defer f.deinit();
    try f.expectDiags(&.{.{ .E0308, "on" }});
    _ = try f.func("get");
}
