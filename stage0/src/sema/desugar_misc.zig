//! Normative desugarings of `?`, comprehensions, defaults and named
//! arguments (§6.12.1, §6.12.6, §6.12.7), emitted directly as TIR.
//!
//! - `tryOp` checks `e?` (§6.12.1, §9.1.2): `e` is an `Option` or a
//!   `Result`, and the function returns the same kind (E0602). A `Result`
//!   error `E` that differs from the function's error `F` is converted with
//!   `F.from`, the method of `impl From<E> for F` (E0601 without one). The
//!   TIR is the expansion's `match`: `e` is stored to a `temp` local, its tag
//!   tested, the failure block returns `.none` or `.err(F.from(__e))`, and
//!   the `.ok`/`.some` payload is the value.
//! - `arrayComp` checks `[e for p in src where cond]` (§6.2.5): it is only
//!   the value stored to a `[N]T` or `Bounded<T, N>` destination, a
//!   `let`, `const` or `static` initializer, an assigned value or an
//!   argument, possibly in parentheses (`Checker.comp_dest`, E0354), and
//!   `where` is not allowed for `[N]T` (E0354). A `[N]T` destination
//!   expands as §6.12.6: the source length is checked (E0354 for an array
//!   or a slice with constant bounds, else a trap), the result starts as
//!   `[@zero(T); N]` (so `T` is plain, E0329) and an index loop stores `e`
//!   per element. `?` outside a function body is E0602.
//! - Defaults and named arguments are bound by `check_call.zig`: explicit
//!   arguments are emitted left to right in source order, then the
//!   defaults of the missing parameters, which is the §6.12.7 expansion.
//!   The tests here pin that order.

const std = @import("std");
const Ast = @import("../ast/Ast.zig");
const Types = @import("types.zig");
const emit_tir = @import("emit_tir.zig");
const check_expr = @import("check_expr.zig");
const check_stmt = @import("check_stmt.zig");
const builtins = @import("builtins.zig");
const kinds = @import("kinds.zig");
const tir = @import("../tir/tir.zig");

const Node = Ast.Node;
const TypeId = Types.TypeId;
const Checker = emit_tir.Checker;
const Typed = emit_tir.Typed;
const Error = emit_tir.Error;

// ---------------------------------------------------------------------------
// `?`

/// `Option<ok>` (`err` is `.none`) or `Result<ok, err>`.
const Carrier = struct { lang: Types.Lang, ok: TypeId, err: TypeId };

fn carrier(c: *Checker, ty: TypeId) ?Carrier {
    const nm = switch (c.types.get(ty)) {
        .nominal => |nm| nm,
        else => return null,
    };
    if (nm.lang != .option and nm.lang != .result) return null;
    var tys: [2]TypeId = .{ .none, .none };
    for (nm.args, 0..) |a, i| if (i < 2 and a == .type) {
        tys[i] = a.type;
    };
    return .{ .lang = nm.lang, .ok = tys[0], .err = tys[1] };
}

/// `e?` (§6.12.1).
pub fn tryOp(c: *Checker, n: Node.Index, _: TypeId) Error!Typed {
    const lhs = c.ast.data(n).try_op.lhs;
    const v = try c.materialize(try check_expr.check(c, lhs, .none), lhs);
    if (v.ty == .err or v.ty == .noreturn) return v;
    const op = carrier(c, v.ty) orelse {
        try c.report(n, .E0310, "`?` needs an `Option` or a `Result`, found `{s}`", .{try c.tyName(v.ty)});
        return .err;
    };
    if (c.ast.kind(c.sig.node) != .fn_decl) { // a `const`/`static` initializer or a `comptime` block
        try c.reportAt(c.ast.mainToken(n), .E0602, &.{"handle the value with `match` or `if let` instead"}, "`?` is only allowed in a function body returning `Option` or `Result`", .{});
        return .err;
    }
    const ret = c.sig.ret;
    if (ret == .err) {
        c.failed = true; // reported with the signature
        return .err;
    }
    const want = carrier(c, ret) orelse return wrongReturn(c, n, op, ret);
    if (want.lang != op.lang) return wrongReturn(c, n, op, ret);
    const from: ?tir.FnId = if (op.lang == .result and op.err != want.err)
        try fromFn(c, n, op.err, want.err) orelse return .err
    else
        null;

    const l = try c.b.addLocal(.{ .ty = v.ty, .name = .none, .kind = .temp, .node = lhs });
    _ = try c.emit(.void, .{ .store = .{ .place = try local(c, l, v.ty), .value = v.ref } });
    // `Option`/`Result` tags: `.some`/`.ok` is 0 (§14.1).
    const tag_ty: TypeId = .int(.unsigned, 8);
    const tag = try c.emit(tag_ty, .{ .enum_tag = .{ .place = try local(c, l, v.ty) } });
    const zero = try c.constant(.{ .type = tag_ty, .bits = 0 });
    const is_ok = try c.emit(.bool, .{ .eq = .{ .lhs = tag, .rhs = zero.ref } });
    const ok_blk = try c.addBlock();
    const fail = try c.addBlock();
    _ = try c.emit(.void, .{ .cond_br = .{ .cond = is_ok, .then = ok_blk, .@"else" = fail } });

    c.setBlock(fail);
    const early = if (op.lang == .option)
        try c.emit(ret, .{ .variant = .{ .variant = 1, .payload = &.{} } })
    else blk: {
        var e = try payload(c, l, v.ty, 1, op.err);
        if (from) |f| e = try c.emit(want.err, .{ .call = .{ .callee = f, .args = &.{e} } });
        break :blk try c.emit(ret, .{ .variant = .{ .variant = 1, .payload = &.{e} } });
    };
    try @import("defer.zig").leave(c, 0); // runs `errdefer`s too (§6.8.2)
    _ = try c.emit(.void, .{ .ret = .{ .value = early } });

    c.setBlock(ok_blk);
    if (op.ok == .void) return .void_value;
    return .{ .ty = op.ok, .ref = try payload(c, l, v.ty, 0, op.ok) };
}

/// E0602: `?` on `op` in a function returning `ret`.
fn wrongReturn(c: *Checker, n: Node.Index, op: Carrier, ret: TypeId) Error!Typed {
    const kind = if (op.lang == .option) "Option" else "Result";
    const help = try std.fmt.allocPrint(c.arena, "`?` on a `{s}` needs a function returning `{s}`; handle the value with `match` or `if let` instead", .{ kind, kind });
    try c.reportAt(c.ast.mainToken(n), .E0602, &.{help}, "`?` cannot be used in a function returning `{s}`", .{try c.tyName(ret)});
    return .err;
}

/// The `from` method of `impl From<e> for f` (§14.2), or null after E0601
/// or an unsupported case.
fn fromFn(c: *Checker, n: Node.Index, e: TypeId, f: TypeId) Error!?tir.FnId {
    if (e == .err or f == .err) {
        c.failed = true;
        return null;
    }
    const protos = c.bodies.protos orelse {
        _ = c.unsupported(n, "`?` conversions without protocol checking (T044)");
        return null;
    };
    const proto = try c.items.preludeInstance("From", &.{.{ .type = e }});
    if (try protos.implFor(proto, f)) |hit| {
        const impl = hit[0];
        if (impl.generics.len > 0) {
            _ = c.unsupported(n, "`?` conversions through generic impls (T070)");
            return null;
        }
        for (impl.methods) |m| if (std.mem.eql(u8, m.name, "from")) return try c.bodies.fnId(impl.src.module, m.node, m.name);
        c.failed = true; // the impl lacks `from`: E0378
        return null;
    }
    if (try protos.satisfies(f, proto)) {
        _ = c.unsupported(n, "`From` conversions of standard library types (T105)");
        return null;
    }
    const es = try c.tyName(e);
    const fs = try c.tyName(f);
    const help = try std.fmt.allocPrint(c.arena, "add `impl From<{s}> for {s}`, or convert the error with `match`", .{ es, fs });
    try c.reportAt(c.ast.mainToken(n), .E0601, &.{help}, "`?` cannot convert error `{s}` to `{s}`: `{s}` does not implement `From<{s}>`", .{ es, fs, fs, es });
    return null;
}

/// The place of local `l` of type `ty`.
fn local(c: *Checker, l: tir.Local, ty: TypeId) Error!tir.Ref {
    return c.emit(ty, .{ .local = .{ .local = l } });
}

/// The payload of variant `variant` of the enum in local `l`: moved for a
/// resource, else copied.
fn payload(c: *Checker, l: tir.Local, enum_ty: TypeId, variant: u32, ty: TypeId) Error!tir.Ref {
    const at = try c.emit(ty, .{ .variant_field = .{ .base = try local(c, l, enum_ty), .variant = variant, .index = 0 } });
    if (try check_stmt.isResource(c, ty)) return c.emit(ty, .{ .move = .{ .place = at } });
    return c.emit(ty, .{ .load = .{ .place = at } });
}

// ---------------------------------------------------------------------------
// Comprehensions

/// `[e for p, i in src where cond]` (§6.2.5, §6.12.6).
pub fn arrayComp(c: *Checker, n: Node.Index, expected: TypeId) Error!Typed {
    const d = c.ast.data(n).array_comp;
    // `(e)` is only grouping (§6.2.6): it keeps the destination.
    var at = c.comp_dest;
    while (at != .none and c.ast.kind(at) == .paren) at = c.ast.data(at).paren.inner;
    const dest: enum { array, bounded, other } = if (at != n or expected == .none or expected == .err) .other else switch (c.types.get(expected)) {
        .array => .array,
        .nominal => |nm| if (std.mem.eql(u8, c.types.strings.get(nm.name), "Bounded")) .bounded else .other,
        else => .other,
    };
    if (expected == .err) {
        c.failed = true;
        return .err;
    }
    switch (dest) {
        .other => {
            try c.reportAt(c.ast.mainToken(n), .E0354, &.{"a comprehension is the initializer, assigned value or argument of type `[N]T` or `Bounded<T, N>`: write `let out: [N]T = [...]`"}, "comprehension without a `[N]T` or `Bounded<T, N>` destination", .{});
            return .err;
        },
        .bounded => return c.unsupported(n, "comprehensions into `Bounded` (T111)"),
        .array => {},
    }
    if (d.filter) |f| {
        try c.report(f, .E0354, "`where` is not allowed in a comprehension into `{s}`", .{try c.tyName(expected)});
        return .err;
    }
    const arr = c.types.get(expected).array;
    if (try kinds.kind(c.items, arr.elem) != .plain) { // the result starts as `[@zero(T); N]` (§6.12.6, §8.7)
        try c.reportAt(c.ast.mainToken(n), .E0329, &.{"`@zero` needs a plain element type; fill the array with a loop instead"}, "a comprehension into `{s}` starts from `@zero({s})`, which needs a plain type", .{ try c.tyName(expected), try c.tyName(arr.elem) });
        return .err;
    }
    const src = try c.materialize(try check_expr.check(c, d.iter, .none), d.iter);
    if (src.ty == .err or src.ty == .noreturn) return src;
    const elem: TypeId = switch (c.types.get(src.ty)) {
        .array => |a| blk: {
            if (a.len != arr.len) {
                try c.report(d.iter, .E0354, "the source has {d} elements, but the destination `{s}` has {d}", .{ a.len, try c.tyName(expected), arr.len });
                return .err;
            }
            break :blk a.elem;
        },
        .slice => |s| blk: {
            if (knownLen(c, src.ref)) |len| if (len != arr.len) {
                try c.report(d.iter, .E0354, "the source has {d} elements, but the destination `{s}` has {d}", .{ len, try c.tyName(expected), arr.len });
                return .err;
            };
            break :blk s.elem;
        },
        .nominal => |nm| if (nm.lang == .none and std.mem.startsWith(u8, c.types.strings.get(nm.name), "Range"))
            return c.unsupported(d.iter, "comprehensions over ranges (T105)")
        else
            return c.unsupported(d.iter, "comprehensions over containers (T111)"),
        else => {
            try c.report(d.iter, .E0310, "a comprehension iterates over an array or a slice, found `{s}`", .{try c.tyName(src.ty)});
            return .err;
        },
    };
    // `let __s = xs[..];`
    const s = try c.b.addLocal(.{ .ty = src.ty, .name = .none, .kind = .temp, .node = d.iter });
    _ = try c.emit(.void, .{ .store = .{ .place = try local(c, s, src.ty), .value = src.ref } });
    const n_const = try c.constant(.{ .type = .usize, .bits = arr.len });
    // `assert(__s.len() == N, "comprehension length mismatch");` (§6.13)
    if (c.types.get(src.ty) == .slice) {
        const len = try c.emit(.usize, .{ .len = .{ .value = try local(c, s, src.ty) } });
        const bad = try c.emit(.bool, .{ .ne = .{ .lhs = len, .rhs = n_const.ref } });
        const trap = try c.addBlock();
        const go = try c.addBlock();
        _ = try c.emit(.void, .{ .cond_br = .{ .cond = bad, .then = trap, .@"else" = go } });
        c.setBlock(trap);
        const msg = try c.emit(.str, .{ .str = .{ .string = try c.types.strings.intern("comprehension length mismatch") } });
        _ = try c.emit(.noreturn, .{ .builtin = .{ .builtin = builtins.Builtin.trap.id(), .args = &.{msg} } });
        _ = try c.emit(.void, .{ .@"unreachable" = .{} });
        c.setBlock(go);
    }
    // `let mut out: [N]T = [@zero(T); N];`
    const out = try c.b.addLocal(.{ .ty = expected, .name = .none, .kind = .temp, .node = n });
    const ty_ref = try c.emit(.type, .{ .type = .{ .value = arr.elem } });
    const z = try c.emit(arr.elem, .{ .builtin = .{ .builtin = builtins.Builtin.zero.id(), .args = &.{ty_ref} } });
    const rep = try c.emit(expected, .{ .repeat = .{ .value = z } });
    _ = try c.emit(.void, .{ .store = .{ .place = try local(c, out, expected), .value = rep } });
    // `for x, __i in __s { out[__i] = e; }` as an index loop (§6.12.3).
    const i = try c.b.addLocal(.{ .ty = .usize, .name = .none, .kind = .temp, .node = n });
    const zero = try c.constant(.{ .type = .usize, .bits = 0 });
    _ = try c.emit(.void, .{ .store = .{ .place = try local(c, i, .usize), .value = zero.ref } });
    const head = try c.addBlock();
    const body = try c.addBlock();
    const exit = try c.addBlock();
    try c.br(head, .none);
    c.setBlock(head);
    const iv = (try c.load(i)).ref;
    const more = try c.emit(.bool, .{ .lt = .{ .lhs = iv, .rhs = (try c.constant(.{ .type = .usize, .bits = arr.len })).ref } });
    _ = try c.emit(.void, .{ .cond_br = .{ .cond = more, .then = body, .@"else" = exit } });

    c.setBlock(body);
    const x = try c.emit(elem, .{ .index = .{ .base = try local(c, s, src.ty), .index = iv } });
    try bindPattern(c, d.pattern, elem, try c.emit(elem, .{ .load = .{ .place = x } }));
    if (d.pattern2) |p| try bindPattern(c, p, .usize, iv);
    const e = try check_expr.checkAs(c, d.elem, arr.elem);
    const slot = try c.emit(arr.elem, .{ .index = .{ .base = try local(c, out, expected), .index = iv } });
    _ = try c.emit(.void, .{ .store = .{ .place = slot, .value = e.ref } });
    const one = try c.constant(.{ .type = .usize, .bits = 1 });
    const next = try c.emit(.usize, .{ .add = .{ .lhs = (try c.load(i)).ref, .rhs = one.ref } });
    _ = try c.emit(.void, .{ .store = .{ .place = try local(c, i, .usize), .value = next } });
    try c.br(head, .none);

    c.setBlock(exit);
    if (e.ty == .err) return .err;
    return c.load(out);
}

/// The length of slice value `r` when it is `e[a..b]` with constant bounds
/// (a missing `b` of an array is its length), else null.
fn knownLen(c: *Checker, r: tir.Ref) ?u64 {
    if (r == .none) return null;
    const s = switch (c.b.data(r)) {
        .slice => |s| s,
        else => return null,
    };
    const lo: u64 = if (s.lo) |x| intConst(c, x) orelse return null else 0;
    const hi: u64 = if (s.hi) |x| intConst(c, x) orelse return null else switch (c.types.get(c.underlying(c.b.typeOf(s.base)))) {
        .array => |a| a.len,
        else => return null,
    };
    return if (hi >= lo) hi - lo else null;
}

fn intConst(c: *Checker, r: tir.Ref) ?u64 {
    return switch (c.b.data(r)) {
        .int => |i| i.value,
        else => null,
    };
}

/// Binds comprehension pattern `p` to `value` of type `ty`: a name, `mut`
/// name or `_`.
fn bindPattern(c: *Checker, p: Node.Index, ty: TypeId, value: tir.Ref) Error!void {
    const k = c.ast.kind(p);
    if (k == .pat_wildcard) return;
    if (k != .pat_bind and k != .pat_bind_mut) {
        _ = c.unsupported(p, "destructuring patterns in comprehensions (T076)");
        return;
    }
    const name = c.ast.tokenSlice(c.ast.mainToken(p));
    const l = try c.b.addLocal(.{
        .ty = ty,
        .name = try c.types.strings.intern(if (std.mem.startsWith(u8, name, "r#")) name[2..] else name),
        .kind = if (k == .pat_bind_mut) .let_mut else .let,
        .node = p,
    });
    try c.locals.put(c.arena, p, l);
    _ = try c.emit(.void, .{ .store = .{ .place = try local(c, l, ty), .value = value } });
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const Fixture = emit_tir.Fixture;

test "`?`: E0601 without `From`, E0602 in a function returning something else" {
    var f: Fixture = undefined;
    try f.init(
        \\pub enum A { x }
        \\pub enum B { y }
        \\fn get() -> Result<u8, A> { return .err(.x); }
        \\fn opt() -> Option<u8> { return .none; }
        \\fn no_from() -> Result<u8, B> { let v = get()?; return .ok(v); }
        \\fn in_void() { let v = get()?; }
        \\fn in_option() -> Option<u8> { let v = get()?; return .some(v); }
        \\fn in_result() -> Result<u8, A> { let v = opt()?; return .ok(v); }
        \\fn not_carrier(x: u8) -> Option<u8> { let v = x?; return .some(v); }
    );
    defer f.deinit();
    try f.expectDiags(&.{
        .{ .E0601, "?" },
        .{ .E0602, "?" },
        .{ .E0602, "?" },
        .{ .E0602, "?" },
        .{ .E0310, "?" },
    });
}

test "`?` expands to a tag test with an early return; `From` converts the error" {
    var f: Fixture = undefined;
    try f.init(
        \\pub enum A { x }
        \\pub enum B { y, a(A) }
        \\impl From<A> for B { fn from(e: A) -> Self { .a(e) } }
        \\fn get() -> Result<u8, A> { return .err(.x); }
        \\fn opt() -> Option<u8> { return .none; }
        \\fn conv() -> Result<u8, B> { let v = get()?; return .ok(v); }
        \\fn same() -> Option<u8> { opt()? ; return .some(1); }
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    try f.expectDump("conv",
        \\fn conv() -> Result<u8, B> {
        \\  l0 : Result<u8, A>
        \\  l1 v: u8
        \\b0:
        \\  %0: Result<u8, A> = call @0, []
        \\  %1: Result<u8, A> = local l0
        \\  store %1, %0
        \\  %3: Result<u8, A> = local l0
        \\  %4: u8 = enum_tag %3
        \\  %5: u8 = int 0
        \\  %6: bool = eq %4, %5
        \\  cond_br %6, b1, b2
        \\b1:
        \\  %14: Result<u8, A> = local l0
        \\  %15: u8 = variant_field %14, 0, 0
        \\  %16: u8 = load %15
        \\  %17: u8 = local l1
        \\  store %17, %16
        \\  %19: u8 = local l1
        \\  %20: u8 = load %19
        \\  %21: Result<u8, B> = variant 0, [%20]
        \\  ret %21
        \\b2:
        \\  %8: Result<u8, A> = local l0
        \\  %9: A = variant_field %8, 1, 0
        \\  %10: A = load %9
        \\  %11: B = call @3, [%10]
        \\  %12: Result<u8, B> = variant 1, [%11]
        \\  ret %12
        \\}
        \\
    );
}

test "comprehensions: E0354 without a `[N]T` destination, for `where` into `[N]T` and a length mismatch" {
    var f: Fixture = undefined;
    try f.init(
        \\fn take(xs: [4]u32) {}
        \\fn bad(src: [4]u32) -> [4]u32 {
        \\    let xs = [x * 2 for x in src];
        \\    let d: [4]u32 = [x for x in src where x > 1];
        \\    let short: [3]u32 = [x for x in src];
        \\    take([x for x in src]);
        \\    let mut m: [4]u32 = src;
        \\    m = [x + 1 for x in src];
        \\    return [x for x in src];
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{
        .{ .E0354, "[" },
        .{ .E0354, ">" },
        .{ .E0354, "src" },
        .{ .E0354, "[" },
    });
}

// `?` outside a function body needs the comptime evaluator, which the
// fixture lacks: conformance case e0602_outside_fn.pr covers it.
test "comprehensions: E0329 for views, parentheses keep the destination, E0354 for constant slice lengths" {
    var f: Fixture = undefined;
    try f.init(
        \\fn names(src: []str) -> str { let out: [2]str = [s for s in src]; out[0] }
        \\fn paren(src: [4]u32) -> u32 { let a: [2]u32 = ([x for x in src[1..3]]); a[0] }
        \\fn short(src: [4]u32) -> u32 { let a: [2]u32 = [x for x in src[0..3]]; a[0] }
        \\fn rest(src: [4]u32) -> u32 { let a: [3]u32 = [x for x in src[2..]]; a[0] }
    );
    defer f.deinit();
    try f.expectDiags(&.{
        .{ .E0329, "[" },
        .{ .E0354, "[" },
        .{ .E0354, "[" },
    });
}

test "comprehension into `[N]T` from a slice: length check, zeroed result, index loop" {
    var f: Fixture = undefined;
    try f.init(
        \\fn double(src: []u32) -> u32 {
        \\    let out: [2]u32 = [x * i as u32 for x, i in src];
        \\    out[1]
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    try f.expectDump("double",
        \\fn double(l0 src: []u32) -> u32 {
        \\  l1 : []u32
        \\  l2 : [2]u32
        \\  l3 : usize
        \\  l4 x: u32
        \\  l5 i: usize
        \\  l6 out: [2]u32
        \\b0:
        \\  %0: []u32 = local l0
        \\  %1: []u32 = load %0
        \\  %2: []u32 = local l1
        \\  store %2, %1
        \\  %4: usize = int 2
        \\  %5: []u32 = local l1
        \\  %6: usize = len %5
        \\  %7: bool = ne %6, %4
        \\  cond_br %7, b1, b2
        \\b1:
        \\  %9: str = str "comprehension length mismatch"
        \\  %10: noreturn = builtin #53, [%9]
        \\  unreachable
        \\b2:
        \\  %12: type = type u32
        \\  %13: u32 = builtin #21, [%12]
        \\  %14: [2]u32 = repeat %13
        \\  %15: [2]u32 = local l2
        \\  store %15, %14
        \\  %17: usize = int 0
        \\  %18: usize = local l3
        \\  store %18, %17
        \\  br b3, []
        \\b3:
        \\  %21: usize = local l3
        \\  %22: usize = load %21
        \\  %23: usize = int 2
        \\  %24: bool = lt %22, %23
        \\  cond_br %24, b4, b5
        \\b4:
        \\  %26: []u32 = local l1
        \\  %27: u32 = index %26, %22
        \\  %28: u32 = load %27
        \\  %29: u32 = local l4
        \\  store %29, %28
        \\  %31: usize = local l5
        \\  store %31, %22
        \\  %33: u32 = local l4
        \\  %34: u32 = load %33
        \\  %35: usize = local l5
        \\  %36: usize = load %35
        \\  %37: u32 = cast %36
        \\  %38: u32 = mul %34, %37
        \\  %39: [2]u32 = local l2
        \\  %40: u32 = index %39, %22
        \\  store %40, %38
        \\  %42: usize = int 1
        \\  %43: usize = local l3
        \\  %44: usize = load %43
        \\  %45: usize = add %44, %42
        \\  %46: usize = local l3
        \\  store %46, %45
        \\  br b3, []
        \\b5:
        \\  %49: [2]u32 = local l2
        \\  %50: [2]u32 = load %49
        \\  %51: [2]u32 = local l6
        \\  store %51, %50
        \\  %53: [2]u32 = local l6
        \\  %54: usize = int 1
        \\  %55: u32 = index %53, %54
        \\  %56: u32 = load %55
        \\  ret %56
        \\}
        \\
    );
}

test "named and default arguments: explicit arguments left to right in source order, then defaults (§6.12.7)" {
    var f: Fixture = undefined;
    try f.init(
        \\fn f(x: u8, z: u8, y: u8 = 7) {}
        \\fn g() -> u8 { 1 }
        \\fn h() -> u8 { 2 }
        \\fn run() { f(z: g(), x: h()); }
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    // `g()` (for `z`) is called before `h()` (for `x`), then the default of `y`.
    try f.expectDump("run",
        \\fn run() -> void {
        \\b0:
        \\  %0: u8 = call @1, []
        \\  %1: u8 = call @2, []
        \\  %2: u8 = int 7
        \\  call @0, [%1, %0, %2]
        \\  ret _
        \\}
        \\
    );
}
