//! Normative loop desugarings (§6.12.2-§6.12.5, §6.7.2, §6.7.3).
//!
//! Checking emits TIR directly (B.1 stage 4), so each construct is emitted
//! as the TIR of its §6.12 expansion rather than rewritten afterwards; the
//! expansion's fresh names are the names of its `temp` locals, so a TIR
//! printer (`--expand`, T211) can print it back as surface Pyro.
//!
//! - `if let`, `guard let` and `while let` (§6.12.2) are the `match` of
//!   their expansion, emitted by `patterns.letCond` and `patterns.guardLet`.
//! - `for x, i in xs { B }` over an array, slice or SoA (§6.12.3, §6.12.4):
//!
//!   ```
//!   { let __s = xs[..]; let __n: usize = __s.len(); let mut __i: usize = 0;
//!     while __i < __n { let x = __s[__i]; B'; __i += 1; } }
//!   ```
//!
//!   `x` is `let x: mut T = __s[__i];` when `xs` is a mutable place. The
//!   counter is the local of `i` when the loop names it (read-only to the
//!   body). `B'` is `B` with `continue` going to the increment.
//! - `for x in a..b` / `a..=b` (§6.12.3): `x` is the counter itself, from
//!   `a` while `x < b` (`x <= b`), and `b` is read once (`__e`). The
//!   increment never computes past the last value: an inclusive range
//!   leaves the loop at `x == b` before adding 1, so `250u8..=255u8` stops.
//! - `where C` (§6.12.5) is `if !(C) { continue; }` at the head of the
//!   body, for `for` and `inline for` (`filter`).
//!
//! An element pattern other than a name destructures the element into
//! copies (`patterns.forPattern`). `StepRange`/`RevRange` (T105) and
//! `Indexable` types (T110) are not iterable yet.

const std = @import("std");
const Ast = @import("../ast/Ast.zig");
const Types = @import("types.zig");
const emit_tir = @import("emit_tir.zig");
const check_expr = @import("check_expr.zig");
const check_stmt = @import("check_stmt.zig");
const mutability = @import("mutability.zig");
const patterns = @import("patterns.zig");
const tir = @import("../tir/tir.zig");

const Node = Ast.Node;
const TypeId = Types.TypeId;
const Checker = emit_tir.Checker;
const Typed = emit_tir.Typed;
const Error = emit_tir.Error;
const For = @FieldType(Ast.Data, "for");

/// `for x(, i)? in xs (where C)? { B }` (§6.7.2): type `void`.
pub fn forExpr(c: *Checker, n: Node.Index, _: TypeId) Error!Typed {
    return forLabeled(c, n, null);
}

/// `for` with an optional label (§6.7.4).
pub fn forLabeled(c: *Checker, n: Node.Index, label: ?[]const u8) Error!Typed {
    const d = c.ast.data(n).@"for";
    for ([_]?Node.Index{ d.pattern, d.pattern2 }, 0..) |p, k| if (p) |q| switch (c.ast.kind(q)) {
        .pat_bind, .pat_wildcard => {},
        .pat_bind_mut => {
            try c.reportAt(c.ast.mainToken(q), null, &.{"remove `mut`: a loop variable is mutable exactly when the iterable is (§6.7.2)"}, "`mut` cannot be written on a `for` loop variable", .{});
            return .err;
        },
        else => if (k == 1) {
            try c.report(q, null, "the index of a `for` loop must be a name or `_`", .{});
            return .err;
        },
    };
    // The iterable is evaluated once (§6.7.2): a value is stored in a temporary.
    const it = try mutability.basePlace(c, d.iter, .read);
    if (it.bad()) {
        if (it.ty == .err) c.failed = true;
        return .{ .ty = it.ty };
    }
    // `let __r = xs;` (§6.12.3): name the temporary so `--expand` can print it.
    if (c.b.data(it.ref) == .local) {
        const l = c.b.data(it.ref).local.local;
        const names = c.b.locals.items(.name);
        if (names[l.int()] == .none) names[l.int()] = try c.types.strings.intern("__r");
    }
    const u = c.underlying(it.ty);
    switch (c.types.get(u)) {
        inline .array, .slice => |x| return sequence(c, d, label, it, x.elem, try c.types.intern(.{ .slice = .{ .elem = x.elem } })),
        inline .soa_array, .soa_slice => |x| return sequence(c, d, label, it, x.elem, try c.types.intern(.{ .soa_slice = .{ .elem = x.elem } })),
        // Only the standard ranges, not user types of the same name.
        .nominal => |nm| if (nm.args.len == 1 and nm.args[0] == .type and std.meta.eql(nm.decl.package, c.items.std_pkg)) {
            const name = c.types.strings.get(nm.name);
            if (std.mem.eql(u8, name, "Range")) return range(c, d, label, it, nm.args[0].type, false);
            if (std.mem.eql(u8, name, "RangeInclusive")) return range(c, d, label, it, nm.args[0].type, true);
            if (std.mem.eql(u8, name, "StepRange") or std.mem.eql(u8, name, "RevRange")) return c.unsupported(d.iter, "`for` over `step` and `rev` ranges (T105)");
            return c.unsupported(d.iter, "`for` over `Indexable` types (T110)");
        } else return c.unsupported(d.iter, "`for` over `Indexable` types (T110)"),
        else => {},
    }
    try c.reportAt(check_stmt.firstToken(c.ast, d.iter), .E0310, &.{"iterate over a range, an array, a slice or a container"}, "`{s}` is not iterable", .{try c.tyName(it.ty)});
    return .err;
}

/// An array, slice or SoA place `it` of element type `elem`, viewed as
/// `slice` (§6.12.3, §6.12.4).
fn sequence(c: *Checker, d: For, label: ?[]const u8, it: mutability.Place, elem: TypeId, slice: TypeId) Error!Typed {
    const s = try fresh(c, "__s", slice, try c.emit(slice, .{ .slice = .{ .base = it.ref, .lo = null, .hi = null } }));
    const len = try fresh(c, "__n", .usize, try c.emit(.usize, .{ .len = .{ .value = (try c.load(s)).ref } }));
    const i = try binding(c, d.pattern2, "__i", .usize, (try c.constant(.{ .type = .usize, .bits = 0 })).ref);
    const head = try c.addBlock();
    const body_blk = try c.addBlock();
    const cont = try c.addBlock();
    const exit = try c.addBlock();
    try c.br(head, .none);
    c.setBlock(head);
    _ = try c.emit(.void, .{ .cond_br = .{ .cond = try c.emit(.bool, .{ .lt = .{ .lhs = (try c.load(i)).ref, .rhs = (try c.load(len)).ref } }), .then = body_blk, .@"else" = exit } });
    c.setBlock(body_blk);
    const at = try c.emit(elem, .{ .index = .{ .base = try c.emit(slice, .{ .local = .{ .local = s } }), .index = (try c.load(i)).ref } });
    switch (c.ast.kind(d.pattern)) {
        .pat_wildcard => {},
        .pat_bind => if (it.mutable) {
            const view = try c.types.intern(.{ .mut_view = .{ .elem = elem } });
            _ = try bindName(c, d.pattern, view, try c.emit(view, .{ .view_mut = .{ .place = at } }));
        } else if (try check_stmt.isResource(c, elem)) {
            // A resource element is viewed, not copied, as by `forPattern` (§5.5.3).
            _ = try bindName(c, d.pattern, elem, try c.emit(elem, .{ .view = .{ .place = at } }));
        } else {
            _ = try bindName(c, d.pattern, elem, try c.emit(elem, .{ .load = .{ .place = at } }));
        },
        else => try patterns.forPattern(c, d.pattern, elem, at, s),
    }
    try body(c, d, label, cont, exit);
    c.setBlock(cont);
    try increment(c, i, .usize);
    try c.br(head, .none);
    c.setBlock(exit);
    return .void_value;
}

/// A `Range<t>` (or, `inclusive`, `RangeInclusive<t>`) place `it`
/// (§6.12.3); fields `start`, `end` (§14.1.3).
fn range(c: *Checker, d: For, label: ?[]const u8, it: mutability.Place, t: TypeId, inclusive: bool) Error!Typed {
    const end = try fresh(c, "__e", t, try field(c, it, t, 1));
    const x = try binding(c, d.pattern, "__x", t, try field(c, it, t, 0));
    const i: tir.Local = if (d.pattern2) |p| try binding(c, p, "__i", .usize, (try c.constant(.{ .type = .usize, .bits = 0 })).ref) else .none;
    const head = try c.addBlock();
    const body_blk = try c.addBlock();
    const cont = try c.addBlock();
    const exit = try c.addBlock();
    try c.br(head, .none);
    c.setBlock(head);
    const lhs = (try c.load(x)).ref;
    const rhs = (try c.load(end)).ref;
    const cond = try c.emit(.bool, if (inclusive) .{ .le = .{ .lhs = lhs, .rhs = rhs } } else .{ .lt = .{ .lhs = lhs, .rhs = rhs } });
    _ = try c.emit(.void, .{ .cond_br = .{ .cond = cond, .then = body_blk, .@"else" = exit } });
    c.setBlock(body_blk);
    switch (c.ast.kind(d.pattern)) {
        .pat_bind, .pat_wildcard => {},
        else => try patterns.forPattern(c, d.pattern, t, try c.emit(t, .{ .local = .{ .local = x } }), x),
    }
    try body(c, d, label, cont, exit);
    c.setBlock(cont);
    if (inclusive) {
        // `x == end` is the last value: stop before `x + 1` can overflow.
        const step = try c.addBlock();
        const last = try c.emit(.bool, .{ .eq = .{ .lhs = (try c.load(x)).ref, .rhs = (try c.load(end)).ref } });
        _ = try c.emit(.void, .{ .cond_br = .{ .cond = last, .then = exit, .@"else" = step } });
        c.setBlock(step);
    }
    try increment(c, x, t);
    if (i != .none) try increment(c, i, .usize);
    try c.br(head, .none);
    c.setBlock(exit);
    return .void_value;
}

/// `B'` (§6.12.3): body `B` of `d` in the current block, inside the loop,
/// where `continue` goes to the increment `cont` and `break` to `exit`.
fn body(c: *Checker, d: For, label: ?[]const u8, cont: tir.Block, exit: tir.Block) Error!void {
    try c.loops.append(c.arena, .{ .label = label, .is_loop = false, .head = cont, .exit = exit, .expected = .none });
    defer _ = c.loops.pop();
    if (d.filter) |f| try filter(c, f, cont);
    const b = try check_expr.check(c, d.body, .void);
    if (b.ty == .noreturn) return;
    _ = try c.coerce(b, .void, check_stmt.valueNode(c.ast, d.body));
    try c.br(cont, .none);
}

/// `where C` (§6.12.5): `if !(C) { continue; }`, with `continue` going to
/// `skip`; the body follows in the current block.
pub fn filter(c: *Checker, cond: Node.Index, skip: tir.Block) Error!void {
    const v = try check_expr.checkAs(c, cond, .bool);
    const then = try c.addBlock();
    _ = try c.emit(.void, .{ .cond_br = .{ .cond = v.ref, .then = then, .@"else" = skip } });
    c.setBlock(then);
}

/// Field `index` (of type `t`) of the range place `it`, read.
fn field(c: *Checker, it: mutability.Place, t: TypeId, index: u32) Error!tir.Ref {
    return c.emit(t, .{ .load = .{ .place = try c.emit(t, .{ .field = .{ .base = it.ref, .index = index } }) } });
}

/// `l += 1` on a counter of type `t`.
fn increment(c: *Checker, l: tir.Local, t: TypeId) Error!void {
    const one = try c.constant(.{ .type = t, .bits = 1 });
    const sum = try c.emit(t, .{ .add = .{ .lhs = (try c.load(l)).ref, .rhs = one.ref } });
    try store(c, l, t, sum);
}

/// The local of binding `p` when it is a name, else the fresh temporary
/// `name`; initialized to `init`.
fn binding(c: *Checker, p: ?Node.Index, name: []const u8, ty: TypeId, init: tir.Ref) Error!tir.Local {
    if (p) |q| if (c.ast.kind(q) == .pat_bind) return bindName(c, q, ty, init);
    return fresh(c, name, ty, init);
}

/// A read-only local for name pattern `p`, initialized to `init`.
fn bindName(c: *Checker, p: Node.Index, ty: TypeId, init: tir.Ref) Error!tir.Local {
    const text = c.ast.tokenSlice(c.ast.mainToken(p));
    const name = if (std.mem.startsWith(u8, text, "r#")) text[2..] else text;
    const l = try c.b.addLocal(.{ .ty = ty, .name = try c.types.strings.intern(name), .kind = .let, .node = p });
    try c.locals.put(c.arena, p, l);
    try store(c, l, ty, init);
    return l;
}

/// The expansion's temporary `name` (§6.12: fresh names cannot collide
/// with user names), initialized to `init`.
fn fresh(c: *Checker, name: []const u8, ty: TypeId, init: tir.Ref) Error!tir.Local {
    const l = try c.b.addLocal(.{ .ty = ty, .name = try c.types.strings.intern(name), .kind = .temp, .node = c.b.node });
    try store(c, l, ty, init);
    return l;
}

fn store(c: *Checker, l: tir.Local, ty: TypeId, v: tir.Ref) Error!void {
    _ = try c.emit(.void, .{ .store = .{ .place = try c.emit(ty, .{ .local = .{ .local = l } }), .value = v } });
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const Fixture = emit_tir.Fixture;

test "§6.12.3: `for x, i in xs` is the `__s/__n` counting `while`" {
    var f: Fixture = undefined;
    try f.init(
        \\fn sum(xs: []u32) -> u32 {
        \\    let mut t: u32 = 0;
        \\    for x, i in xs { t += x; }
        \\    t
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    try f.expectDump("sum",
        \\fn sum(l0 xs: []u32) -> u32 {
        \\  l1 mut t: u32
        \\  l2 __s: []u32
        \\  l3 __n: usize
        \\  l4 i: usize
        \\  l5 x: u32
        \\b0:
        \\  %0: u32 = int 0
        \\  %1: u32 = local l1
        \\  store %1, %0
        \\  %3: []u32 = local l0
        \\  %4: []u32 = slice %3, _, _
        \\  %5: []u32 = local l2
        \\  store %5, %4
        \\  %7: []u32 = local l2
        \\  %8: []u32 = load %7
        \\  %9: usize = len %8
        \\  %10: usize = local l3
        \\  store %10, %9
        \\  %12: usize = int 0
        \\  %13: usize = local l4
        \\  store %13, %12
        \\  br b1, []
        \\b1:
        \\  %16: usize = local l4
        \\  %17: usize = load %16
        \\  %18: usize = local l3
        \\  %19: usize = load %18
        \\  %20: bool = lt %17, %19
        \\  cond_br %20, b2, b4
        \\b2:
        \\  %22: []u32 = local l2
        \\  %23: usize = local l4
        \\  %24: usize = load %23
        \\  %25: u32 = index %22, %24
        \\  %26: u32 = load %25
        \\  %27: u32 = local l5
        \\  store %27, %26
        \\  %29: u32 = local l1
        \\  %30: u32 = load %29
        \\  %31: u32 = local l5
        \\  %32: u32 = load %31
        \\  %33: u32 = add %30, %32
        \\  store %29, %33
        \\  br b3, []
        \\b3:
        \\  %36: usize = int 1
        \\  %37: usize = local l4
        \\  %38: usize = load %37
        \\  %39: usize = add %38, %36
        \\  %40: usize = local l4
        \\  store %40, %39
        \\  br b1, []
        \\b4:
        \\  %43: u32 = local l1
        \\  %44: u32 = load %43
        \\  ret %44
        \\}
        \\
    );
}

test "§6.12.3: an inclusive range stops at its end; `continue` goes to the increment (B')" {
    var f: Fixture = undefined;
    try f.init(
        \\fn count() -> u32 {
        \\    let mut n: u32 = 0;
        \\    for x in 250u8..=255u8 { if x == 252 { continue; } n += 1; }
        \\    n
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    try f.expectDump("count",
        \\fn count() -> u32 {
        \\  l0 mut n: u32
        \\  l1 __r: RangeInclusive<u8>
        \\  l2 __e: u8
        \\  l3 x: u8
        \\b0:
        \\  %0: u32 = int 0
        \\  %1: u32 = local l0
        \\  store %1, %0
        \\  %3: u8 = int 250
        \\  %4: u8 = int 255
        \\  %5: RangeInclusive<u8> = aggregate [%3, %4]
        \\  %6: RangeInclusive<u8> = local l1
        \\  store %6, %5
        \\  %8: u8 = field %6, 1
        \\  %9: u8 = load %8
        \\  %10: u8 = local l2
        \\  store %10, %9
        \\  %12: u8 = field %6, 0
        \\  %13: u8 = load %12
        \\  %14: u8 = local l3
        \\  store %14, %13
        \\  br b1, []
        \\b1:
        \\  %17: u8 = local l3
        \\  %18: u8 = load %17
        \\  %19: u8 = local l2
        \\  %20: u8 = load %19
        \\  %21: bool = le %18, %20
        \\  cond_br %21, b2, b4
        \\b2:
        \\  %23: u8 = local l3
        \\  %24: u8 = load %23
        \\  %25: u8 = int 252
        \\  %26: bool = eq %24, %25
        \\  cond_br %26, b5, b6
        \\b3:
        \\  %36: u8 = local l3
        \\  %37: u8 = load %36
        \\  %38: u8 = local l2
        \\  %39: u8 = load %38
        \\  %40: bool = eq %37, %39
        \\  cond_br %40, b4, b8
        \\b4:
        \\  %49: u32 = local l0
        \\  %50: u32 = load %49
        \\  ret %50
        \\b5:
        \\  br b3, []
        \\b6:
        \\  br b7, []
        \\b7:
        \\  %30: u32 = local l0
        \\  %31: u32 = load %30
        \\  %32: u32 = int 1
        \\  %33: u32 = add %31, %32
        \\  store %30, %33
        \\  br b3, []
        \\b8:
        \\  %42: u8 = int 1
        \\  %43: u8 = local l3
        \\  %44: u8 = load %43
        \\  %45: u8 = add %44, %42
        \\  %46: u8 = local l3
        \\  store %46, %45
        \\  br b1, []
        \\}
        \\
    );
}

test "§6.12.3: `250u8..=255u8` terminates at comptime; `where`, index and labels" {
    var f: ComptimeFixture = undefined;
    try f.init(
        \\fn count() -> u32 {
        \\    let mut n: u32 = 0;
        \\    for x in 250u8..=255u8 { n += 1; }
        \\    for x, i in 0..10 where x % 2 == 0 { n += i as u32; }
        \\    outer: for a in [1u32, 2, 3] {
        \\        for b in 0..a { if b == 1 { continue :outer; } n += 100; }
        \\        break :outer;
        \\    }
        \\    n
        \\}
        \\const N: u32 = count();
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    // 6 elements of `250u8..=255u8`; indices 0 + 2 + 4 + 6 + 8 of the even
    // `x`; one `100` before `continue :outer` at `b == 1`.
    try testing.expectEqual(6 + 20 + 100, try constBits(&f, "N"));
}

const ComptimeFixture = @import("comptime_flow.zig").Fixture;

/// The bits of scalar constant `name` of module 0.
fn constBits(f: *ComptimeFixture, name: []const u8) !u64 {
    const k = (try f.items.info(.{ .module = 0, .item = f.g.modules[0].names.get(name).? })).@"const";
    return k.value.scalar.bits;
}

test "§6.7.2: elements of a mutable place are `mut T` views, of anything else copies" {
    var f: Fixture = undefined;
    try f.init(
        \\struct P { pub mut x: f32, pub vx: f32 }
        \\fn step(mut ps: []P, dt: f32) { for p in ps { p.x += p.vx * dt; } }
        \\fn zero() -> [3]u8 { let mut a: [3]u8 = [1, 2, 3]; for x in a { x = 0; } a }
        \\fn soa_step(mut ps: soa [8]P) { for p in ps { p.x += 1.0; } }
        \\fn bad(xs: [4]u32) { for x in xs { x = 1; } }
    );
    defer f.deinit();
    try f.expectDiags(&.{.{ .E0337, "x" }});
    _ = try f.func("step");
    _ = try f.func("zero");
    _ = try f.func("soa_step");
}

test "§6.7.2: destructuring elements, `_`, and errors" {
    var f: Fixture = undefined;
    try f.init(
        \\fn pairs(ps: [2](u32, u32)) -> u32 { let mut t: u32 = 0; for (a, b), _ in ps { t += a * b; } for _ in 0..3 { t += 1; } t }
        \\fn not_iterable(x: u32) { for i in x {} }
        \\fn with_mut(xs: []u32) { for mut x in xs {} }
        \\fn refutable(xs: []Option<u32>) { for .some(v) in xs {} }
    );
    defer f.deinit();
    try f.expectDiags(&.{ .{ .E0310, "x" }, .{ null, "x" }, .{ .E0357, "some" } });
    _ = try f.func("pairs");
}

test "§6.12.5: `where` in `inline for` skips copies" {
    var f: ComptimeFixture = undefined;
    try f.init(
        \\fn evens() -> u32 { let mut n: u32 = 0; inline for x in 0u32..6 where x % 2 == 0 { n += x; } n }
        \\const E: u32 = evens();
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    try testing.expectEqual(0 + 2 + 4, try constBits(&f, "E"));
}

test "§6.12.3: a user type named `Range` is not iterated as a range" {
    var f: Fixture = undefined;
    try f.init(
        \\struct Range<T> { pub a: T, pub b: T }
        \\fn g(r: Range<u32>) -> u32 { let mut n: u32 = 0; for x in r { n += x; } n }
    );
    defer f.deinit();
    try testing.expectEqualStrings("`for` over `Indexable` types (T110)", f.bodies.unsupported.?.what);
}

test "§4.5.3: a `mut T` element is read as a `T` in `where` and arithmetic" {
    var f: Fixture = undefined;
    try f.init(
        \\fn c(mut xs: []u32) { for x in xs where x > 1 { x = 0; } }
        \\fn d(mut xs: []u32) -> u32 { let mut t: u32 = 0; for x in xs { x += 2; let y: u32 = x + 1; t += 1 + x + y; } t }
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    _ = try f.func("c");
    _ = try f.func("d");
}

test "§5.5.3: a resource element of an immutable iterable is viewed, not copied" {
    var f: Fixture = undefined;
    try f.init(
        \\@resource struct H { fd: i32 }
        \\fn rs(hs: [2]H) { for h in hs { } }
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    const func = try f.func("rs");
    var views: usize = 0;
    for (0..func.insts.len) |i| views += @intFromBool(func.op(.from(i)) == .view);
    try testing.expectEqual(1, views);
}

test "§6.7.1: `break` with a value in a `for` is E0310" {
    var f: Fixture = undefined;
    try f.init(
        \\fn b(xs: []u32) { for x in xs { break 3; } }
    );
    defer f.deinit();
    try f.expectDiags(&.{.{ .E0310, "break" }});
}
