//! Blocks, statements and control flow (§6.6.1, §6.7.1, §6.7.4, §6.11,
//! §6.11.1, §3.5): block values and divergence, `let`, assignment and
//! compound assignment, `_ = e`, `return`, `break`/`continue`, `if`,
//! `loop`, `while`, labels and `&&`/`||`.
//!
//! TIR shapes: `if` is a `cond_br` to one block per branch and a join block
//! whose parameter is the value; `loop` jumps to a head block and value
//! `break`s pass their value to the exit block's parameter; `while` tests its
//! condition in the head block. A `loop` without `break` has type `noreturn`
//! and an exit block without predecessors.

const std = @import("std");
const Ast = @import("../ast/Ast.zig");
const Types = @import("types.zig");
const tir = @import("../tir/tir.zig");
const attr_table = @import("../attr_table.zig");
const conv = @import("convert.zig");
const emit_tir = @import("emit_tir.zig");
const check_expr = @import("check_expr.zig");
const check_call = @import("check_call.zig");
const check_index = @import("check_index.zig");
const mutability = @import("mutability.zig");
const must_use = @import("must_use.zig");
const patterns = @import("patterns.zig");

const Node = Ast.Node;
const TypeId = Types.TypeId;
const Checker = emit_tir.Checker;
const Typed = emit_tir.Typed;
const Error = emit_tir.Error;
const Place = mutability.Place;

/// The node whose value block `n` yields: its tail, recursively; `n` itself
/// for any other expression. Conversion errors are reported there.
pub fn valueNode(ast: *const Ast, n: Node.Index) Node.Index {
    var x = n;
    while (ast.kind(x) == .block) x = ast.data(x).block.tail orelse return x;
    return x;
}

// ---------------------------------------------------------------------------
// Blocks and statements (§6.11)

/// `{ s1; s2; e }`: the value of `e`; without it `void`, or `noreturn` if a
/// statement always diverges.
pub fn block(c: *Checker, n: Node.Index, expected: TypeId) Error!Typed {
    const d = c.ast.data(n).block;
    var diverges = false;
    for (d.stmts) |s| {
        const saved = c.b.node;
        c.b.node = s;
        defer c.b.node = saved;
        if (try stmt(c, s)) diverges = true;
    }
    // A `mut T` tail is a view of a place, as for `return` (§5.5.4).
    const view = expected != .none and expected != .err and c.types.get(expected) == .mut_view;
    const v: Typed = if (d.tail) |t| (if (view) try check_expr.checkAs(c, t, expected) else try check_expr.check(c, t, expected)) else .void_value;
    return if (diverges and v.ty != .err) .never else v;
}

/// Checks statement `s`; true if it always diverges.
fn stmt(c: *Checker, s: Node.Index) Error!bool {
    switch (c.ast.kind(s)) {
        .empty_stmt => return false,
        .let => return let(c, s),
        .assign => return assign(c, s),
        .discard => return discard(c, s),
        .@"return" => return @"return"(c, s),
        .@"break" => return @"break"(c, s),
        .@"continue" => return @"continue"(c, s),
        .const_decl => {
            const k = try c.items.constValue(c.m, s, c.self_ty);
            if (k.type == .err) c.failed = true;
            if (k.value == .unknown and k.type != .err) _ = c.unsupported(s, "values the comptime evaluator could not compute");
            return false;
        },
        .@"defer", .@"errdefer", .return_tail => _ = c.unsupported(s, "`defer`, `errdefer` and `return tail` (T078)"),
        .guard_let => return patterns.guardLet(c, s),
        .spawn, .nursery => _ = c.unsupported(s, "`nursery` and `spawn` (T125)"),
        .launch => _ = c.unsupported(s, "`launch` (T187)"),
        .attributed => _ = c.unsupported(s, "`@simd` loops and `@workgroup` variables (T156, T177)"),
        else => {
            const v = try check_expr.check(c, s, .none);
            try must_use.check(c, s, v.ty);
            return v.ty == .noreturn;
        },
    }
    return false;
}

/// `let p (: T)? = e;` (§3.5). Other patterns than a name or `_` destructure
/// (`patterns.letPattern`).
fn let(c: *Checker, s: Node.Index) Error!bool {
    const d = c.ast.data(s).let;
    const pk = c.ast.kind(d.pattern);
    if (pk != .pat_bind and pk != .pat_bind_mut and pk != .pat_wildcard) return patterns.letPattern(c, s);
    const decl: TypeId = if (d.ty) |t| try c.resolveType(t) else .none;
    c.comp_dest = d.init;
    const v = if (decl != .none) try check_expr.checkAs(c, d.init, decl) else try c.materialize(try check_expr.check(c, d.init, .none), d.init);
    if (pk == .pat_wildcard) return v.ty == .noreturn;
    const ty = if (decl != .none) decl else v.ty;
    c.b.node = d.pattern;
    const name = c.ast.tokenSlice(c.ast.mainToken(d.pattern));
    const l = try c.b.addLocal(.{
        .ty = ty,
        .name = try c.types.strings.intern(if (std.mem.startsWith(u8, name, "r#")) name[2..] else name),
        .kind = if (pk == .pat_bind_mut) .let_mut else .let,
        .node = d.pattern,
    });
    try c.locals.put(c.arena, d.pattern, l);
    if (v.ty != .noreturn and v.ref != .none) {
        const slot = try c.emit(ty, .{ .local = .{ .local = l } });
        _ = try c.emit(.void, .{ .store = .{ .place = slot, .value = v.ref } });
    }
    return v.ty == .noreturn;
}

/// The storage assignment target `n` names (§3.5, §1.6), or null after a
/// diagnostic: a binding, `*p`, or a field or element of a place
/// (`mutability.operand`), which must be mutable (`mutability.require`).
fn place(c: *Checker, n: Node.Index) Error!?Place {
    switch (c.ast.kind(n)) {
        .paren => return place(c, c.ast.data(n).paren.inner),
        .ident => if (check_call.localOf(c, n) == null) return nameTarget(c, n),
        // A module member (`geo.origin`) is a name like an `ident`.
        .field_access => if (c.items.names.get(c.m, n) != null) return notPlace(c, n),
        .self_value => if (c.self_local == .none) return null, // E0205 (parser)
        .index => {},
        .prefix => if (c.ast.tokens.items(.kind)[c.ast.mainToken(n)] != .star) return notPlace(c, n),
        else => return notPlace(c, n),
    }
    const p = switch (try mutability.operand(c, n, .write)) {
        .place => |p| p,
        .value => |v| {
            if (v.ty != .err) try c.reportAt(c.ast.mainToken(n), .E0207, &.{"bind the value with `let mut` first"}, "cannot assign to field `{s}` of a value that is not a place", .{c.ast.tokenSlice(c.ast.mainToken(n))});
            c.failed = true;
            return null;
        },
    };
    if (p.ty == .err) return null;
    if (p.ty == .noreturn) return p;
    if (c.ast.kind(n) == .index and check_index.isSlice(c.ast, n)) {
        try c.reportAt(c.ast.mainToken(n), .E0207, &.{"assign to its elements instead, e.g. `s[i] = x`"}, "cannot assign to a slice: it is a view, not a place", .{});
        return null;
    }
    return if (try mutability.require(c, p, n, .assign)) p else null;
}

fn notPlace(c: *Checker, n: Node.Index) Error!?Place {
    _ = try check_expr.check(c, n, .none);
    try c.reportAt(c.ast.mainToken(n), .E0207, &.{"assign to a binding, a field or element of one, or `*p`"}, "assignment target is not a place", .{});
    return null;
}

/// Assignment target `n`, a name that is not a local: E0207 for a constant,
/// function, type or module.
fn nameTarget(c: *Checker, n: Node.Index) Error!?Place {
    const name = c.ast.tokenSlice(c.ast.mainToken(n));
    const e = c.items.names.get(c.m, n) orelse {
        try c.report(n, null, "cannot find `{s}` in this scope", .{name});
        return null;
    };
    const what: []const u8 = switch (e.res) {
        .local => |l| switch (c.ast.kind(l)) {
            .pat_bind, .pat_bind_mut, .field_pat, .field_pat_mut, .param => {
                _ = c.unsupported(n, "bindings of `for` loops and lambdas (T074, T076)");
                return null;
            },
            .const_decl => "constant",
            else => {
                _ = c.unsupported(n, "assignment to `result` in contracts (T135)");
                return null;
            },
        },
        .global => |t| switch (t) {
            .item => |ref| switch (c.items.im.graph.modules[ref.module].items[ref.item].kind) {
                .@"const" => "constant",
                .@"fn", .extern_fn => "function",
                else => "type",
            },
            .unresolved => {
                _ = c.unsupported(n, "names from modules not loaded (multi-file check)");
                return null;
            },
            .module => "module",
            .prelude, .external => "name outside this package",
        },
    };
    try c.report(n, .E0207, "cannot assign to {s} `{s}`: it is not a place", .{ what, name });
    return null;
}

/// `place op= value;` (§3.5): the place first, then the value, then the
/// store (§6.1). A compound assignment computes `place op value` in the
/// place's type.
fn assign(c: *Checker, s: Node.Index) Error!bool {
    const d = c.ast.data(s).assign;
    const op = c.ast.tokens.items(.kind)[c.ast.mainToken(s)];
    const p = try place(c, d.lhs) orelse {
        _ = try check_expr.check(c, d.rhs, .none);
        return false;
    };
    if (p.ty == .noreturn) { // the target diverges, e.g. `a[die()] = x`
        _ = try check_expr.check(c, d.rhs, .none);
        return true;
    }
    var v: Typed = undefined;
    if (op == .eq) {
        c.comp_dest = d.rhs;
        v = try check_expr.checkAs(c, d.rhs, p.ty);
    } else {
        const cur: Typed = .{ .ty = p.ty, .ref = try c.emit(p.ty, .{ .load = .{ .place = p.ref } }) };
        const r = try check_expr.check(c, d.rhs, if (op == .shl_eq or op == .shr_eq) .none else p.ty);
        v = try check_expr.operate(c, s, op, cur, r, p.ty);
        if (v.ty != .err and v.ty != .noreturn and v.ty != p.ty) {
            try c.mismatch(s, p.ty, v.ty);
            v = .err;
        }
    }
    if (v.ty == .noreturn) return true;
    if (v.ref != .none) _ = try c.emit(.void, .{ .store = .{ .place = p.ref, .value = v.ref } });
    return false;
}

/// `_ = e;` (§6.11.1): evaluates and drops `e`; E0327 for a resource.
fn discard(c: *Checker, s: Node.Index) Error!bool {
    const value = c.ast.data(s).discard.value;
    const v = try check_expr.check(c, value, .none);
    if (v.ty != .err and v.ty != .noreturn and try isResource(c, v.ty)) {
        try c.reportAt(firstToken(c.ast, value), .E0327, &.{"bind it with `let` and release it, e.g. with `defer x.close();`"}, "a resource of type `{s}` cannot be discarded", .{try c.tyName(v.ty)});
    }
    return v.ty == .noreturn;
}

/// The first token of a call or name expression, to report it at its start.
pub fn firstToken(ast: *const Ast, n: Node.Index) Ast.TokenIndex {
    var x = n;
    while (ast.kind(x) == .call) x = ast.data(x).call.callee;
    return ast.mainToken(x);
}

/// `return e?;` (§7.2.1, §4.2.4): E0302 in a `noreturn` function, E0371
/// without a value where one is required.
fn @"return"(c: *Checker, s: Node.Index) Error!bool {
    const value = c.ast.data(s).@"return".value;
    const ret = c.sig.ret;
    if (ret == .noreturn) {
        try c.reportAt(c.ast.mainToken(s), .E0302, &.{"a `noreturn` function must end in a trap, a call to a `noreturn` function or a `loop` without `break`"}, "`{s}` is declared `-> noreturn` but returns", .{c.sig.name});
        if (value) |v| _ = try check_expr.check(c, v, .none);
        return true;
    }
    const r: Typed = if (value) |v| try check_expr.checkAs(c, v, ret) else blk: {
        if (ret != .void and ret != .err) {
            try c.reportAt(c.ast.mainToken(s), .E0371, &.{}, "missing return value: `{s}` must return `{s}`", .{ c.sig.name, try c.tyName(ret) });
        }
        break :blk .void_value;
    };
    if (r.ty != .noreturn) _ = try c.emit(.void, .{ .ret = .{ .value = r.ref.unwrap() } });
    return true;
}

/// `break (:label)? value?;` (§6.7.1): all value `break`s of one `loop` agree
/// on the type, which the first typed one fixes. Untyped constants wait for
/// it, or take the loop's expected type or their default type at its end
/// (§4.8), as `if` branches do.
fn @"break"(c: *Checker, s: Node.Index) Error!bool {
    const d = c.ast.data(s).@"break";
    const loop = c.findLoop(if (d.label) |t| c.ast.tokenSlice(t) else null) orelse {
        c.failed = true; // outside a loop, or an unknown label: E0210 (parser)
        return true;
    };
    loop.has_break = true;
    const value = d.value orelse {
        loop.has_void_break = true;
        if (loop.result != .none or loop.pending.items.len > 0) {
            const ty = if (loop.result != .none) loop.result else loop.pending.items[0].value.ty;
            try c.report(s, .E0310, "mismatched types: `break` without a value in a `loop` whose `break`s give `{s}`", .{try c.tyName(ty)});
        }
        try c.br(loop.exit, .none);
        return true;
    };
    if (!loop.is_loop) {
        try c.report(s, .E0310, "`break` with a value is only allowed in `loop`; `while` has type `void`", .{});
        _ = try check_expr.check(c, value, .none);
        return true;
    }
    const v = try check_expr.check(c, value, if (loop.result != .none) loop.result else loop.expected);
    const at = valueNode(c.ast, value);
    // `c.loops` may grow while `value` is checked: find the loop again.
    const l = c.findLoop(if (d.label) |t| c.ast.tokenSlice(t) else null).?;
    if (v.ty == .noreturn or v.ty == .err) return true;
    if (l.result == .none) {
        if (l.has_void_break) {
            try c.report(s, .E0310, "mismatched types: this `break` gives `{s}`, another gives no value", .{try c.tyName(v.ty)});
            return true;
        }
        if (v.isUntyped()) {
            try l.pending.append(c.arena, .{ .block = c.b.block, .value = v, .node = at });
            c.setBlock(try c.addBlock()); // for the dead code after the `break`
            return true;
        }
        try settle(c, l, v.ty);
    }
    try c.br(l.exit, (try c.coerce(v, l.result, at)).ref);
    return true;
}

/// Fixes the type of `l`'s `break` values to `ty` and ends the blocks of its
/// pending untyped `break`s.
fn settle(c: *Checker, l: *emit_tir.Loop, ty: TypeId) Error!void {
    l.result = ty;
    l.param = try c.blockParam(l.exit, ty);
    const here = c.b.block;
    const node = c.b.node;
    for (l.pending.items) |p| {
        c.setBlock(p.block);
        c.b.node = p.node;
        try c.br(l.exit, (try c.coerce(p.value, ty, p.node)).ref);
    }
    l.pending.clearRetainingCapacity();
    c.setBlock(here);
    c.b.node = node;
}

/// `continue (:label)?;`
fn @"continue"(c: *Checker, s: Node.Index) Error!bool {
    const label = c.ast.data(s).@"continue".label;
    const loop = c.findLoop(if (label) |t| c.ast.tokenSlice(t) else null) orelse {
        c.failed = true; // E0210 (parser)
        return true;
    };
    try c.br(loop.head, .none);
    return true;
}

// ---------------------------------------------------------------------------
// Control flow (§6.6.1, §6.7.1, §6.7.4)

/// `if cond { a } else { b }`: `cond` is `bool` (E0310); with `else` the
/// branches have a common type, without it the then-block is `void`.
pub fn ifExpr(c: *Checker, n: Node.Index, expected: TypeId) Error!Typed {
    const d = c.ast.data(n).@"if";
    var then_blk: tir.Block = undefined;
    var else_blk: tir.Block = undefined;
    var cond: Typed = undefined;
    if (c.ast.kind(d.cond) == .let_cond) {
        then_blk = try c.addBlock();
        else_blk = try c.addBlock();
        cond = try patterns.letCond(c, d.cond, then_blk, else_blk);
    } else {
        cond = try check_expr.checkAs(c, d.cond, .bool);
        then_blk = try c.addBlock();
        else_blk = try c.addBlock();
        _ = try c.emit(.void, .{ .cond_br = .{ .cond = cond.ref, .then = then_blk, .@"else" = else_blk } });
    }

    c.setBlock(then_blk);
    const tv = try check_expr.check(c, d.then, if (d.@"else" == null) .void else expected);
    const then_end = c.b.block;
    c.setBlock(else_blk);
    const ev: Typed = if (d.@"else") |e| try check_expr.check(c, e, expected) else .void_value;
    const else_end = c.b.block;

    if (cond.ty == .noreturn or (tv.ty == .noreturn and ev.ty == .noreturn)) return .never;
    const join_ty: TypeId = if (d.@"else" == null) .void else try common(c, d, tv, ev, expected) orelse return .err;
    const join = try c.addBlock();
    const param: tir.Ref = if (join_ty == .void or join_ty == .err) .none else try c.blockParam(join, join_ty);
    for ([_]Typed{ tv, ev }, [_]tir.Block{ then_end, else_end }, [_]?Node.Index{ d.then, d.@"else" }) |v, end, node| {
        if (v.ty == .noreturn) continue;
        c.setBlock(end);
        const at = valueNode(c.ast, node orelse d.then);
        const cv = try c.coerce(v, join_ty, at);
        try c.br(join, if (join_ty == .void) .none else cv.ref);
    }
    c.setBlock(join);
    if (tv.ty == .err or ev.ty == .err) return .err;
    return .{ .ty = join_ty, .ref = param };
}

/// The common type of two branch values (§6.6.1): the typed one (a
/// narrower integer or `f32` widens), or the type `untypedType` gives
/// untyped constants. `hint` (the expected type, or `.none`) only picks the
/// type of untyped constants and of typed values that both widen to it: it
/// does not force a conversion, so an `if` operand has the same type in any
/// context. E0310 and null if there is none.
fn common(c: *Checker, d: @FieldType(Ast.Data, "if"), a: Typed, b: Typed, hint: TypeId) Error!?TypeId {
    if (a.ty == .err or b.ty == .err) return .err;
    if (a.ty == .noreturn) return if (b.isUntyped()) try untypedType(c, hint, &.{b}) else b.ty;
    if (b.ty == .noreturn) return if (a.isUntyped()) try untypedType(c, hint, &.{a}) else a.ty;
    if (a.isUntyped() and b.isUntyped()) return try untypedType(c, hint, &.{ a, b });
    if (a.isUntyped()) return b.ty;
    if (b.isUntyped() or a.ty == b.ty) return a.ty;
    if (widens(c, a.ty, b.ty)) return b.ty;
    if (widens(c, b.ty, a.ty)) return a.ty;
    if (hint != .none and hint != .err and widens(c, a.ty, hint) and widens(c, b.ty, hint)) return hint;
    try c.report(valueNode(c.ast, d.@"else".?), .E0310, "`if` and `else` have different types: `{s}` and `{s}`", .{ try c.tyName(a.ty), try c.tyName(b.ty) });
    return null;
}

/// `from` widens implicitly to `to` (§4.9.1).
pub fn widens(c: *Checker, from: TypeId, to: TypeId) bool {
    return switch (conv.coerce(c.types, from, to, .{})) {
        .int_widen, .float_widen => true,
        else => false,
    };
}

/// The type untyped constants `vs` take at run time (§4.8): `hint`, if each
/// converts to it (a value that does not fit is reported on conversion),
/// else the default type, `f64` if one is a float. A `vec` hint gives its
/// element type, as a scalar operand of a `vec` is broadcast (§6.4.1), and
/// `Option<T>` gives `T` (§4.9.1).
pub fn untypedType(c: *Checker, hint: TypeId, vs: []const Typed) Error!TypeId {
    if (hint != .none and hint != .err) {
        const h = switch (c.types.get(hint)) {
            .vec => |x| x.elem,
            else => conv.optionPayload(c.types, hint) orelse hint,
        };
        for (vs) |v| switch (try conv.convertConst(c.arena, c.types, c.items.options.ptr_bits, v.konst.?, h)) {
            .ok => {},
            .err => |code| if (code == .E0310) break,
        } else return h;
    }
    for (vs) |v| if (v.ty == .untyped_float) return .f64;
    return .int(.signed, 64);
}

/// `loop { body }`: the type of its `break` values, `void` if no `break`
/// carries one, `noreturn` without `break` (§6.7.1).
pub fn loopExpr(c: *Checker, n: Node.Index, expected: TypeId) Error!Typed {
    return loopLabeled(c, n, expected, null);
}

fn loopLabeled(c: *Checker, n: Node.Index, expected: TypeId, label: ?[]const u8) Error!Typed {
    const head = try c.addBlock();
    const exit = try c.addBlock();
    try c.br(head, .none);
    c.setBlock(head);
    try c.loops.append(c.arena, .{ .label = label, .is_loop = true, .head = head, .exit = exit, .expected = expected });
    const body = try check_expr.check(c, c.ast.data(n).loop.body, .void);
    if (body.ty != .noreturn) {
        _ = try c.coerce(body, .void, valueNode(c.ast, c.ast.data(n).loop.body));
        try c.br(head, .none);
    }
    var l = c.loops.pop().?;
    if (l.pending.items.len > 0) {
        const vs = try c.arena.alloc(Typed, l.pending.items.len);
        for (vs, l.pending.items) |*v, p| v.* = p.value;
        try settle(c, &l, try untypedType(c, expected, vs));
    }
    c.setBlock(exit);
    if (l.result != .none) return .{ .ty = l.result, .ref = l.param };
    return if (l.has_break) .void_value else .never;
}

/// `while cond { body }`: type `void` (§6.7.1).
pub fn whileExpr(c: *Checker, n: Node.Index, _: TypeId) Error!Typed {
    return whileLabeled(c, n, null);
}

fn whileLabeled(c: *Checker, n: Node.Index, label: ?[]const u8) Error!Typed {
    const d = c.ast.data(n).@"while";
    const head = try c.addBlock();
    const body_blk = try c.addBlock();
    const exit = try c.addBlock();
    try c.br(head, .none);
    c.setBlock(head);
    if (c.ast.kind(d.cond) == .let_cond) {
        _ = try patterns.letCond(c, d.cond, body_blk, exit);
    } else {
        const cond = try check_expr.checkAs(c, d.cond, .bool);
        _ = try c.emit(.void, .{ .cond_br = .{ .cond = cond.ref, .then = body_blk, .@"else" = exit } });
    }
    c.setBlock(body_blk);
    try c.loops.append(c.arena, .{ .label = label, .is_loop = false, .head = head, .exit = exit, .expected = .none });
    const body = try check_expr.check(c, d.body, .void);
    if (body.ty != .noreturn) {
        _ = try c.coerce(body, .void, valueNode(c.ast, d.body));
        try c.br(head, .none);
    }
    _ = c.loops.pop();
    c.setBlock(exit);
    return .void_value;
}

/// `label: loop/while ...` (§6.7.4).
pub fn labeled(c: *Checker, n: Node.Index, expected: TypeId) Error!Typed {
    const inner = c.ast.data(n).labeled.inner;
    const label = c.ast.tokenSlice(c.ast.mainToken(n));
    const saved = c.b.node;
    c.b.node = inner;
    defer c.b.node = saved;
    return switch (c.ast.kind(inner)) {
        .loop => loopLabeled(c, inner, expected, label),
        .@"while" => whileLabeled(c, inner, label),
        else => check_expr.check(c, inner, expected),
    };
}

/// `a && b`, `a || b` on `bool` (§6.4.1): `b` is evaluated only when
/// needed (§6.1).
pub fn logical(c: *Checker, n: Node.Index, is_and: bool) Error!Typed {
    const d = c.ast.data(n).binary;
    const l = try check_expr.checkAs(c, d.lhs, .bool);
    const rhs_blk = try c.addBlock();
    const short = try c.addBlock();
    const join = try c.addBlock();
    _ = try c.emit(.void, .{ .cond_br = .{
        .cond = l.ref,
        .then = if (is_and) rhs_blk else short,
        .@"else" = if (is_and) short else rhs_blk,
    } });
    c.setBlock(rhs_blk);
    const r = try check_expr.checkAs(c, d.rhs, .bool);
    if (r.ty != .noreturn) try c.br(join, r.ref);
    c.setBlock(short);
    const k = try c.constant(.{ .type = .bool, .bits = @intFromBool(!is_and) });
    try c.br(join, k.ref);
    const p = try c.blockParam(join, .bool);
    c.setBlock(join);
    if (l.ty == .err or r.ty == .err) return .err;
    if (l.ty == .noreturn) return .never;
    return .{ .ty = .bool, .ref = p };
}

// ---------------------------------------------------------------------------
// Type kinds

/// Whether `ty` is a resource (§5.1): marked `@resource`, or holding a
/// resource field, payload or element.
// shortcut: a local predicate until kinds.zig (T042) gives the kind of a type; generic instances are not substituted.
pub fn isResource(c: *Checker, ty: TypeId) Error!bool {
    return resourceIn(c, ty, 0);
}

fn resourceIn(c: *Checker, ty: TypeId, depth: u32) Error!bool {
    if (depth > 64) return false; // recursive types are E0376
    switch (c.types.get(ty)) {
        .array => |a| return resourceIn(c, a.elem, depth + 1),
        .soa_array => |a| return resourceIn(c, a.elem, depth + 1),
        .tuple => |t| {
            for (t.elems) |e| if (try resourceIn(c, e, depth + 1)) return true;
            return false;
        },
        .nominal => |nm| {
            if (nm.kind == .distinct) return resourceIn(c, nm.underlying, depth + 1);
            if (std.meta.eql(nm.decl.package, c.items.std_pkg)) {
                // Standard containers own heap memory (§14.4).
                const owning = std.StaticStringMap(void).initComptime(.{ .{"List"}, .{"Pool"}, .{"Arena"}, .{"Map"}, .{"Table"}, .{"String"} });
                if (owning.has(c.types.strings.get(nm.name))) return true;
                for (nm.args) |a| if (a == .type and try resourceIn(c, a.type, depth + 1)) return true;
                return false;
            }
            if (c.items.structOf(ty)) |s| {
                const ref = c.items.declRef(ty).?;
                const ast = c.items.im.graph.modules[ref.module].ast;
                for (s.attrs) |a| {
                    const text = ast.tokenSlice(ast.mainToken(a));
                    if (attr_table.lookup(if (std.mem.startsWith(u8, text, "@")) text[1..] else text) == .resource) return true;
                }
                for (s.fields) |f| if (try resourceIn(c, f.type, depth + 1)) return true;
            } else if (c.items.enumOf(ty)) |e| {
                for (e.variants) |v| for (v.payload) |p| {
                    if (try resourceIn(c, p, depth + 1)) return true;
                };
            }
            return false;
        },
        else => return false,
    }
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const Fixture = emit_tir.Fixture;

test "E0327: discarding a resource; other values may be discarded" {
    var f: Fixture = undefined;
    try f.init(
        \\@resource
        \\pub struct File { fd: i32 }
        \\struct Pair { a: File, n: u8 }
        \\struct Plain { n: u8 }
        \\fn open(fd: i32) -> File { loop {} }
        \\fn pair() -> Pair { loop {} }
        \\fn plain() -> Plain { loop {} }
        \\fn count() -> usize { 3 }
        \\fn discard() {
        \\    _ = open(1);
        \\    _ = pair();
        \\    _ = plain();
        \\    _ = count();
        \\    _ = 5;
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{ .{ .E0327, "open" }, .{ .E0327, "pair" } });
}

test "let, assignment and compound assignment: E0207, E0337, E0338" {
    var f: Fixture = undefined;
    try f.init(
        \\const LIMIT: i32 = 10;
        \\@resource
        \\struct File { fd: i32 }
        \\fn open() -> File { loop {} }
        \\fn close(move f: File) { f = open(); }
        \\fn helper() {}
        \\fn writes(n: i32, mut m: i32) {
        \\    let x = 1;
        \\    let mut y: i64 = x;
        \\    y += 2;
        \\    y <<= 1u8;
        \\    m = n;
        \\    LIMIT = 11;
        \\    helper = helper;
        \\    x = 2;
        \\    n = 3;
        \\    y += 1.5;
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{
        .{ .E0338, "f" }, .{ .E0207, "LIMIT" }, .{ .E0207, "helper" }, .{ .E0337, "x" }, .{ .E0338, "n" }, .{ .E0306, "+=" },
    });
}

test "if and loop typing: common types, break agreement, labels" {
    var f: Fixture = undefined;
    try f.init(
        \\fn pick(c: bool, a: u8, b: u16) -> u16 { if c { a } else { b } }
        \\fn dflt(c: bool) -> i64 { let x = if c { 1 } else { 2 }; x }
        \\fn void_if(c: bool) { if c { 1u8; } }
        \\fn no_else(c: bool) { if c { 1u8 } }
        \\fn breaks(n: u32) -> u32 {
        \\    outer: loop {
        \\        while true {
        \\            if n > 3 { break :outer; }
        \\            break;
        \\        }
        \\        continue :outer;
        \\    }
        \\    n
        \\}
        \\fn disagree(c: bool) -> u32 {
        \\    loop { if c { break 1u32; } break "s"; }
        \\}
        \\fn mixed(c: bool) -> u32 {
        \\    if c { 1u32 } else { "s" }
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{ .{ .E0310, "1u8" }, .{ .E0310, "\"s\"" }, .{ .E0310, "\"s\"" } });
    for ([_][]const u8{ "pick", "dflt", "void_if", "breaks" }) |name| _ = try f.func(name);
}

test "an expected type only guides untyped branches and breaks" {
    var f: Fixture = undefined;
    try f.init(
        \\fn scale(c: bool, w: vec<4, f32>) -> vec<4, f32> {
        \\    let v: vec<4, f32> = (if c { 1.0 } else { 2.0 }) * w;
        \\    v
        \\}
        \\fn shift(n: u32) -> u64 { let v: u64 = (if n > 0 { n } else { 1 }) << 2u8; v }
        \\fn widen(c: bool, a: u32, b: i32) -> i64 { if c { a } else { b } }
        \\fn first_untyped(c: bool, n: u32) -> u32 {
        \\    let x = loop { if c { break 0; } break n; };
        \\    x
        \\}
        \\fn hinted(c: bool) -> u8 { loop { if c { break 1; } break 2; } }
        \\fn dflt(c: bool) -> i64 { let x = loop { if c { break 1; } break 2; }; x }
        \\fn too_big() -> u8 { loop { break 300; } }
        \\fn void_after(c: bool) { loop { if c { break 1; } break; } }
    );
    defer f.deinit();
    try f.expectDiags(&.{ .{ .E0306, "300" }, .{ .E0310, "break" } });
    for ([_][]const u8{ "scale", "widen", "first_untyped", "hinted", "dflt" }) |name| _ = try f.func(name);
    try f.expectDump("first_untyped",
        \\fn first_untyped(l0 c: bool, l1 n: u32) -> u32 {
        \\  l2 x: u32
        \\b0:
        \\  br b1, []
        \\b1:
        \\  %1: bool = local l0
        \\  %2: bool = load %1
        \\  cond_br %2, b3, b4
        \\b2(%7: u32):
        \\  %11: u32 = local l2
        \\  store %11, %7
        \\  %13: u32 = local l2
        \\  %14: u32 = load %13
        \\  ret %14
        \\b3:
        \\  %8: u32 = int 0
        \\  br b2, [%8]
        \\b4:
        \\  br b6, []
        \\b5:
        \\  unreachable
        \\b6:
        \\  %5: u32 = local l1
        \\  %6: u32 = load %5
        \\  br b2, [%6]
        \\}
        \\
    );
    try f.expectDump("shift",
        \\fn shift(l0 n: u32) -> u64 {
        \\  l1 v: u64
        \\b0:
        \\  %0: u32 = local l0
        \\  %1: u32 = load %0
        \\  %2: u32 = int 0
        \\  %3: bool = gt %1, %2
        \\  cond_br %3, b1, b2
        \\b1:
        \\  %5: u32 = local l0
        \\  %6: u32 = load %5
        \\  br b3, [%6]
        \\b2:
        \\  %9: u32 = int 1
        \\  br b3, [%9]
        \\b3(%7: u32):
        \\  %11: u8 = int 2
        \\  %12: u32 = shl %7, %11
        \\  %13: u64 = coerce %12
        \\  %14: u64 = local l1
        \\  store %14, %13
        \\  %16: u64 = local l1
        \\  %17: u64 = load %16
        \\  ret %17
        \\}
        \\
    );
}
