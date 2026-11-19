//! Patterns and binding modes (§3.7, §6.6.2, §6.6.3, §6.2.6, §5.3.3):
//! `match`, `if let`, `while let`, `guard let` and destructuring `let`.
//!
//! A pattern is first checked against the type of the value it matches
//! (E0310, E0306, E0353, E0211, E0212), giving an `exhaustive.Pat`. The
//! patterns of a `match` are then checked for reachability (W0302) and
//! exhaustiveness (E0357), and a `let` pattern must be irrefutable (E0357).
//!
//! TIR shape: the subject is a place: the local it names, or a `temp`
//! local holding its value. A pattern is tested against sub-places of it
//! (`field`, `variant_field` after an `enum_tag` test) by a chain of
//! `cond_br`s that jump to the failure block on the first mismatch; an
//! alternative pattern is one chain per alternative. Bindings are stored
//! only after the whole pattern matched (§6.6.3):
//!
//! - a subject naming a place of plain type gives copies (`load`);
//! - a subject naming a place of resource type gives read-only `view`s of
//!   its resource parts and moves nothing;
//! - `move x` or a resource temporary moves its resource parts into the
//!   bindings (`move`), which must then be consumed (§5.3.3, T080).

const std = @import("std");
const Ast = @import("../ast/Ast.zig");
const literals = @import("../lex/literals.zig");
const Types = @import("types.zig");
const convert = @import("convert.zig");
const emit_tir = @import("emit_tir.zig");
const check_expr = @import("check_expr.zig");
const check_stmt = @import("check_stmt.zig");
const exhaustive = @import("exhaustive.zig");
const tir = @import("../tir/tir.zig");

const Node = Ast.Node;
const TypeId = Types.TypeId;
const Checker = emit_tir.Checker;
const Typed = emit_tir.Typed;
const Error = emit_tir.Error;
const Pat = exhaustive.Pat;

// ---------------------------------------------------------------------------
// Constructs

/// `match e { P1 => a, P2 if g => b, ... }` (§6.6.3): the arms' common type.
pub fn matchExpr(c: *Checker, n: Node.Index, expected: TypeId) Error!Typed {
    const d = c.ast.data(n).match;
    const subj = try subject(c, d.subject, .none);
    // shortcut: arms after a diverging subject are dead and not checked; check them when dead code gets diagnostics.
    if (subj.value.ty == .noreturn) return .never;

    var ok = true;
    const pats = try c.arena.alloc(Pat, d.arms.len);
    for (pats, d.arms) |*p, arm| p.* = try check(c, c.ast.data(arm).match_arm.pattern, subj.value.ty, &ok);
    if (ok and subj.value.ty != .err) {
        var prior: std.ArrayList(Pat) = .empty;
        for (pats, d.arms) |p, arm| {
            if (!try exhaustive.isUseful(c, prior.items, p))
                try c.reportAt(c.ast.mainToken(p.node), .W0302, &.{"remove it, or move it before the arms that cover its values"}, "unreachable `match` arm: earlier arms match every value it matches", .{});
            // A guard may fail (§6.6.3): a guarded arm covers nothing.
            if (c.ast.data(arm).match_arm.guard == null) try prior.append(c.arena, p);
        }
        const miss = try exhaustive.missing(c, prior.items, subj.value.ty, 4);
        if (miss.len > 0)
            try c.reportAt(c.ast.mainToken(n), .E0357, &.{"add arms for them, or a `_` arm (guarded arms may fail and cover nothing)"}, "non-exhaustive `match`: {s}{s} not covered", .{ try exhaustive.print(c, miss[0..@min(miss.len, 3)]), if (miss.len > 3) " and more" else "" });
    }

    const vals = try c.arena.alloc(Typed, d.arms.len);
    const ends = try c.arena.alloc(tir.Block, d.arms.len);
    for (d.arms, pats, vals, ends) |arm, p, *v, *end| {
        const a = c.ast.data(arm).match_arm;
        const fail = try c.addBlock();
        try bindTest(c, subj, p, fail, true);
        if (a.guard) |g| {
            const cond = try check_expr.checkAs(c, g, .bool);
            const body = try c.addBlock();
            _ = try c.emit(.void, .{ .cond_br = .{ .cond = cond.ref, .then = body, .@"else" = fail } });
            c.setBlock(body);
        }
        v.* = try check_expr.check(c, a.body, expected);
        end.* = c.b.block;
        c.setBlock(fail);
    }
    // No arm matched: impossible once the arms are exhaustive.
    _ = try c.emit(.void, .{ .@"unreachable" = .{} });

    const ty = try armsType(c, d.arms, vals, expected) orelse return .err;
    if (ty == .noreturn) return .never;
    const join = try c.addBlock();
    const param: tir.Ref = if (ty == .void or ty == .err) .none else try c.blockParam(join, ty);
    for (vals, ends, d.arms) |v, end, arm| {
        if (v.ty == .noreturn) continue;
        c.setBlock(end);
        const cv = try c.coerce(v, ty, check_stmt.valueNode(c.ast, c.ast.data(arm).match_arm.body));
        try c.br(join, if (ty == .void) .none else cv.ref);
    }
    c.setBlock(join);
    if (ty == .err) return .err;
    return .{ .ty = ty, .ref = param };
}

/// The condition `let P = e` of `if let` and `while let` (§6.6.2): jumps to
/// `then` with `P`'s bindings bound if `e` matches `P`, else to `otherwise`.
/// Returns the checked value of `e`.
pub fn letCond(c: *Checker, cond: Node.Index, then: tir.Block, otherwise: tir.Block) Error!Typed {
    const d = c.ast.data(cond).let_cond;
    const subj = try subject(c, d.value, .none);
    if (subj.value.ty == .noreturn) return subj.value;
    var ok = true;
    const p = try check(c, d.pattern, subj.value.ty, &ok);
    try bindTest(c, subj, p, otherwise, true);
    try c.br(then, .none);
    return subj.value;
}

/// `guard let P = e else { B }` (§6.6.2): `B` must diverge (E0356); `P`'s
/// bindings are in scope for the rest of the block. True if `e` diverges.
pub fn guardLet(c: *Checker, s: Node.Index) Error!bool {
    const d = c.ast.data(s).guard_let;
    const subj = try subject(c, d.value, .none);
    if (subj.value.ty == .noreturn) return true;
    var ok = true;
    const p = try check(c, d.pattern, subj.value.ty, &ok);
    const fail = try c.addBlock();
    try bindTest(c, subj, p, fail, true);
    const matched = c.b.block;
    c.setBlock(fail);
    const e = try check_expr.check(c, d.@"else", .none);
    if (e.ty != .noreturn and e.ty != .err)
        try c.reportAt(c.ast.mainToken(d.@"else"), .E0356, &.{"end the `else` block with `return`, `break`, `continue` or a trap"}, "the `else` block of `guard let` must not finish: it has type `{s}`, not `noreturn`", .{try c.tyName(e.ty)});
    c.setBlock(matched);
    return false;
}

/// Destructuring `let P (: T)? = e;` (§3.5, §6.2.6): `P` must match every
/// value (E0357). True if `e` diverges.
pub fn letPattern(c: *Checker, s: Node.Index) Error!bool {
    const d = c.ast.data(s).let;
    const decl: TypeId = if (d.ty) |t| try c.resolveType(t) else .none;
    if (decl != .none and decl != .err and c.types.get(decl) == .mut_view) {
        _ = c.unsupported(s, "`mut T` locals (T055)");
        return false;
    }
    const subj = try subject(c, d.init, decl);
    if (subj.value.ty == .noreturn) return true;
    var ok = true;
    const p = try check(c, d.pattern, subj.value.ty, &ok);
    if (ok and subj.value.ty != .err) {
        const miss = try exhaustive.missing(c, &.{p}, subj.value.ty, 4);
        if (miss.len > 0)
            try c.reportAt(c.ast.mainToken(d.pattern), .E0357, &.{"use `guard let ... else { ... }` or `if let` to handle the other values"}, "refutable pattern in `let`: {s}{s} not covered", .{ try exhaustive.print(c, miss[0..@min(miss.len, 3)]), if (miss.len > 3) " and more" else "" });
    }
    // No failure target: an irrefutable pattern without alternatives (§3.7)
    // emits no test, and after E0357 nothing is emitted.
    try bindTest(c, subj, p, .none, false);
    return false;
}

/// The common type of the arm values `vals` (§6.6.3), as for `if` (§6.6.1):
/// the typed value every other one widens to, else `hint` if all widen to
/// it; untyped constants take `check_stmt.untypedType`. `noreturn` if every
/// arm diverges. E0310 and null if there is none.
fn armsType(c: *Checker, arms: []const Node.Index, vals: []const Typed, hint: TypeId) Error!?TypeId {
    var cand: TypeId = .none;
    var untyped: std.ArrayList(Typed) = .empty;
    for (vals) |v| {
        if (v.ty == .err) return .err;
        if (v.ty == .noreturn) continue;
        if (v.isUntyped()) {
            try untyped.append(c.arena, v);
        } else if (cand == .none or check_stmt.widens(c, cand, v.ty)) cand = v.ty;
    }
    if (cand == .none) return if (untyped.items.len == 0) .noreturn else try check_stmt.untypedType(c, hint, untyped.items);
    for (vals, arms) |v, arm| {
        if (v.ty == .noreturn or v.isUntyped() or v.ty == cand or check_stmt.widens(c, v.ty, cand)) continue;
        if (hint != .none and hint != .err) {
            for (vals) |x| {
                if (x.ty == .noreturn or x.isUntyped() or x.ty == hint or check_stmt.widens(c, x.ty, hint)) continue;
                break;
            } else return hint;
        }
        try c.report(check_stmt.valueNode(c.ast, c.ast.data(arm).match_arm.body), .E0310, "`match` arms have different types: `{s}` and `{s}`", .{ try c.tyName(cand), try c.tyName(v.ty) });
        return null;
    }
    return cand;
}

// ---------------------------------------------------------------------------
// The subject

/// How bindings take their values (§6.6.3).
const Mode = enum { copy, view, move };

/// The value a pattern is matched against, as a place.
const Subject = struct {
    /// The local holding it; its value or `.err`/`.noreturn` in `value`.
    root: tir.Local = .none,
    value: Typed,
    mode: Mode = .copy,
    /// The subject names a mutable place (`let mut`, `mut` parameter).
    mutable: bool = false,
};

/// The subject `e`: the local it names, `move x`, or a temporary holding
/// its value (converted to `decl` unless `.none`).
fn subject(c: *Checker, e: Node.Index, decl: TypeId) Error!Subject {
    if (decl == .none) {
        if (c.ast.kind(e) == .prefix and c.ast.tokens.items(.kind)[c.ast.mainToken(e)] == .kw_move) {
            const operand = c.ast.data(e).prefix.operand;
            const l = localOf(c, operand) orelse return .{ .value = c.unsupported(e, "`move` of fields and elements (T080)") };
            return .{ .root = l, .value = .{ .ty = c.b.locals.items(.ty)[l.int()] }, .mode = .move };
        }
        if (localOf(c, e)) |l| {
            const ty = c.b.locals.items(.ty)[l.int()];
            const kind = c.b.locals.items(.kind)[l.int()];
            return .{
                .root = l,
                .value = .{ .ty = ty },
                .mode = if (ty != .err and try check_stmt.isResource(c, ty)) .view else .copy,
                .mutable = kind == .let_mut or kind == .param_mut,
            };
        }
    }
    const v = if (decl != .none) try check_expr.checkAs(c, e, decl) else try c.materialize(try check_expr.check(c, e, .none), e);
    if (v.ty == .err or v.ty == .noreturn) return .{ .value = v };
    const l = try c.b.addLocal(.{ .ty = v.ty, .name = .none, .kind = .temp, .node = e });
    const slot = try c.emit(v.ty, .{ .local = .{ .local = l } });
    _ = try c.emit(.void, .{ .store = .{ .place = slot, .value = v.ref } });
    return .{ .root = l, .value = v, .mode = if (try check_stmt.isResource(c, v.ty)) .move else .copy };
}

/// The TIR local expression `e` names, if it is a local binding or `self`.
fn localOf(c: *Checker, e: Node.Index) ?tir.Local {
    switch (c.ast.kind(e)) {
        .paren => return localOf(c, c.ast.data(e).paren.inner),
        .self_value => return c.self_local.unwrap(),
        .ident => {},
        else => return null,
    }
    const entry = c.items.names.get(c.m, e) orelse return null;
    return switch (entry.res) {
        .local => |l| c.locals.get(l),
        .global => null,
    };
}

// ---------------------------------------------------------------------------
// Checking patterns

/// Checks pattern `n` against values of type `ty` and returns it; clears
/// `ok` after a diagnostic. With `ty == .err` nothing is reported and the
/// bindings get type `.err`.
fn check(c: *Checker, n: Node.Index, ty: TypeId, ok: *bool) Error!Pat {
    if (ty == .err) return errPat(c, n, ok);
    const kind = c.ast.kind(n);
    switch (kind) {
        .pat_wildcard => return .{ .ty = ty, .shape = .wild, .node = n },
        .pat_bind, .pat_bind_mut => return .{ .ty = ty, .shape = .wild, .node = n, .bind = n },
        .int_lit, .char_lit, .bool_lit, .prefix => {
            const r = try literal(c, n, ty) orelse return errPat(c, n, ok);
            return ctor(ty, n, .{ .range = .{ .lo = r, .hi = r } }, &.{});
        },
        .pat_range => {
            const d = c.ast.data(n).pat_range;
            const lo = try literal(c, d.lo, ty) orelse return errPat(c, n, ok);
            var hi = try literal(c, d.hi, ty) orelse return errPat(c, n, ok);
            if (c.ast.tokens.items(.kind)[c.ast.mainToken(n)] == .dot_dot) hi -= 1;
            if (hi < lo) {
                try c.report(n, .E0310, "empty range pattern: it matches no value", .{});
                return errPat(c, n, ok);
            }
            return ctor(ty, n, .{ .range = .{ .lo = lo, .hi = hi } }, &.{});
        },
        .pat_variant => return variant(c, n, ty, ok),
        .pat_tuple => {
            const elems = c.ast.data(n).pat_tuple.elems;
            const tys = switch (c.types.get(c.underlying(ty))) {
                .tuple => |t| t.elems,
                else => &.{},
            };
            if (tys.len != elems.len) {
                try c.report(n, .E0310, "mismatched types: expected `{s}`, found a tuple pattern of {d} elements", .{ try c.tyName(ty), elems.len });
                return errPat(c, n, ok);
            }
            const args = try c.arena.alloc(Pat, elems.len);
            for (args, elems, tys) |*a, e, t| a.* = try check(c, e, t, ok);
            return ctor(ty, n, .{ .variant = 0 }, args);
        },
        .pat_struct, .pat_anon_struct => return structPat(c, n, ty, ok),
        .pat_alt => {
            const alts = c.ast.data(n).pat_alt.alts;
            const ps = try c.arena.alloc(Pat, alts.len);
            for (ps, alts) |*p, a| p.* = try check(c, a, ty, ok);
            try sameBindings(c, ps, ok);
            return .{ .ty = ty, .shape = .{ .alt = ps }, .node = n };
        },
        else => {
            try c.report(n, null, "expected a pattern", .{});
            return errPat(c, n, ok);
        },
    }
}

fn ctor(ty: TypeId, n: Node.Index, k: exhaustive.Ctor, args: []const Pat) Pat {
    return .{ .ty = ty, .shape = .{ .ctor = .{ .ctor = k, .args = args } }, .node = n };
}

/// Pattern `n` after a diagnostic (or against a failed type): its bindings
/// get type `.err`; it matches everything.
fn errPat(c: *Checker, n: Node.Index, ok: *bool) Error!Pat {
    ok.* = false;
    c.failed = true;
    const subs: []const Node.Index = switch (c.ast.data(n)) {
        .pat_bind, .pat_bind_mut, .field_pat_mut => return .{ .ty = .err, .shape = .wild, .node = n, .bind = n },
        .field_pat => |f| if (f.pattern) |p| return errPat(c, p, ok) else return .{ .ty = .err, .shape = .wild, .node = n, .bind = n },
        .pat_variant => |v| v.elems orelse &.{},
        .pat_tuple => |t| t.elems,
        .pat_struct => |s| s.fields,
        .pat_anon_struct => |s| s.fields,
        .pat_alt => |a| a.alts,
        else => &.{},
    };
    var args: std.ArrayList(Pat) = .empty;
    for (subs) |s| if (c.ast.kind(s) != .rest) try args.append(c.arena, try errPat(c, s, ok));
    if (c.ast.kind(n) == .pat_alt) return .{ .ty = .err, .shape = .{ .alt = args.items }, .node = n };
    return ctor(.err, n, .{ .variant = 0 }, args.items);
}

/// The value of literal pattern `n` (§3.7) as a value of `ty`: an integer
/// or character in range of an integer type (E0306), or `true`/`false` for
/// `bool`; null after a diagnostic.
fn literal(c: *Checker, n: Node.Index, ty: TypeId) Error!?i128 {
    const space = try exhaustive.spaceOf(c, ty);
    const int = switch (space) {
        .int => |i| i,
        else => null,
    };
    if (c.ast.kind(n) == .bool_lit) {
        if (int == null or !int.?.is_bool) {
            try c.mismatch(n, ty, .bool);
            return null;
        }
        return @intFromBool(c.ast.tokens.items(.kind)[c.ast.mainToken(n)] == .kw_true);
    }
    const neg = c.ast.kind(n) == .prefix;
    const lit = if (neg) c.ast.data(n).prefix.operand else n;
    const text = c.ast.tokenSlice(c.ast.mainToken(lit));
    var value: i128 = undefined;
    var suffix: TypeId = .none;
    if (c.ast.kind(lit) == .char_lit) {
        value = literals.decodeChar(text);
    } else {
        const iv = literals.decodeInt(text) catch {
            c.failed = true; // reported by the lexer (E0108)
            return null;
        };
        value = iv.value;
        suffix = switch (iv.suffix) {
            .none => .none,
            .unsigned => |b| .int(.unsigned, b),
            .signed => |b| .int(.signed, b),
            .usize => .usize,
            .isize => .isize,
        };
    }
    if (neg) value = -value;
    if (int == null or int.?.is_bool or (suffix != .none and suffix != ty)) {
        try c.mismatch(n, ty, if (suffix != .none) suffix else .untyped_int);
        return null;
    }
    if (value < int.?.range.lo or value > int.?.range.hi) {
        try c.report(n, .E0306, "integer constant does not fit `{s}`", .{try c.tyName(ty)});
        return null;
    }
    return value;
}

/// `.name` or `.name(p, ...)` (§3.7) against enum `ty`.
fn variant(c: *Checker, n: Node.Index, ty: TypeId, ok: *bool) Error!Pat {
    const name = c.ast.tokenSlice(c.ast.mainToken(n));
    const elems = c.ast.data(n).pat_variant.elems;
    const u = c.underlying(ty);
    if (c.types.get(u) == .nominal and c.types.get(u).nominal.lang == .none) {
        if (c.items.declRef(u) == null) {
            _ = c.unsupported(n, "patterns of standard library types (T163)");
            return errPat(c, n, ok);
        }
        if (c.items.enumOf(u)) |e| if (e.generics.len > 0) {
            _ = c.unsupported(n, "variants of generic enums (T064)");
            return errPat(c, n, ok);
        };
    }
    const sum = switch (try exhaustive.spaceOf(c, ty)) {
        .sum => |s| if (s.kind == .@"enum") s else null,
        else => null,
    };
    const index = if (sum) |s| for (s.names, 0..) |vn, i| {
        if (std.mem.eql(u8, vn, name)) break i;
    } else null else null;
    const i = index orelse {
        try c.report(n, .E0353, "no variant `.{s}` in `{s}`", .{ name, try c.tyName(ty) });
        return errPat(c, n, ok);
    };
    const payload = sum.?.fields[i];
    const given = elems orelse &.{};
    // A `void` payload is written `.ok()` (§4.2.4).
    const void_payload = elems != null and given.len == 0 and payload.len == 1 and payload[0] == .void;
    if (!void_payload and (given.len != payload.len or (elems != null and payload.len == 0))) {
        try c.report(n, .E0310, "variant `.{s}` of `{s}` has {d} value(s), the pattern gives {d}", .{ name, try c.tyName(ty), payload.len, given.len });
        return errPat(c, n, ok);
    }
    const args = try c.arena.alloc(Pat, payload.len);
    for (args, payload, 0..) |*a, t, j| a.* = if (void_payload) .wild(t) else try check(c, given[j], t, ok);
    return ctor(ty, n, .{ .variant = @intCast(i) }, args);
}

/// `Path { f: p, g, mut h, .. }` or `.{ ... }` (§3.7) against struct `ty`:
/// without `..` every field is named (E0212).
fn structPat(c: *Checker, n: Node.Index, ty: TypeId, ok: *bool) Error!Pat {
    const fields = switch (c.ast.data(n)) {
        .pat_struct => |d| blk: {
            const named = try c.resolveType(d.ty);
            if (named == .err) return errPat(c, n, ok);
            if (named != ty) {
                try c.mismatch(n, ty, named);
                return errPat(c, n, ok);
            }
            break :blk d.fields;
        },
        .pat_anon_struct => |d| d.fields,
        else => unreachable,
    };
    const u = c.underlying(ty);
    const s = c.items.structOf(u) orelse {
        if (c.types.get(u) == .nominal and c.items.declRef(u) == null) {
            _ = c.unsupported(n, "patterns of standard library types (T163)");
        } else try c.report(n, .E0310, "mismatched types: `{s}` is not a struct, found a struct pattern", .{try c.tyName(ty)});
        return errPat(c, n, ok);
    };
    if (s.generics.len > 0) {
        _ = c.unsupported(n, "patterns of generic structs (T064)");
        return errPat(c, n, ok);
    }
    // shortcut: private fields are matched from any module; T050's field visibility rules (§7.3.3) apply once shared.
    const args = try c.arena.alloc(Pat, s.fields.len);
    const seen = try c.arena.alloc(bool, s.fields.len);
    @memset(seen, false);
    for (s.fields, args) |f, *a| a.* = .wild(f.type);
    const has_rest = fields.len > 0 and c.ast.kind(fields[fields.len - 1]) == .rest;
    for (fields[0 .. fields.len - @intFromBool(has_rest)]) |g| {
        const name = c.ast.tokenSlice(c.ast.mainToken(g));
        const i = for (s.fields, 0..) |f, i| {
            if (std.mem.eql(u8, f.name, name)) break i;
        } else {
            try c.report(g, null, "`{s}` has no field `{s}`", .{ try c.tyName(ty), name });
            _ = try errPat(c, g, ok);
            continue;
        };
        if (seen[i]) {
            try c.report(g, .E0351, "field `{s}` is given twice", .{name});
            _ = try errPat(c, g, ok);
            continue;
        }
        seen[i] = true;
        const t = s.fields[i].type;
        args[i] = switch (c.ast.data(g)) {
            .field_pat => |fp| if (fp.pattern) |p| try check(c, p, t, ok) else .{ .ty = t, .shape = .wild, .node = g, .bind = g },
            else => .{ .ty = t, .shape = .wild, .node = g, .bind = g }, // `mut x`
        };
    }
    if (!has_rest) {
        var miss: std.Io.Writer.Allocating = .init(c.arena);
        for (s.fields, seen) |f, given| if (!given) {
            if (miss.written().len > 0) miss.writer.writeAll(", ") catch return error.OutOfMemory;
            miss.writer.print("`{s}`", .{f.name}) catch return error.OutOfMemory;
        };
        if (miss.written().len > 0) {
            try c.reportAt(c.ast.mainToken(n), .E0212, &.{"name every field, or end the pattern with `..` to ignore the rest"}, "struct pattern misses field(s) {s} of `{s}`", .{ miss.written(), try c.tyName(ty) });
            ok.* = false;
        }
    }
    return ctor(ty, n, .{ .variant = 0 }, args);
}

/// E0211 (§3.7): every alternative binds each name with the type it has in
/// the first one (the names themselves are checked by the parser).
fn sameBindings(c: *Checker, alts: []const Pat, ok: *bool) Error!void {
    var first: std.ArrayList(Pat) = .empty;
    try bindings(c, alts[0], &first);
    for (alts[1..]) |a| {
        var these: std.ArrayList(Pat) = .empty;
        try bindings(c, a, &these);
        for (these.items) |b| for (first.items) |f| {
            if (!std.mem.eql(u8, bindName(c, b.bind), bindName(c, f.bind))) continue;
            if (b.ty != f.ty and b.ty != .err and f.ty != .err) {
                try c.reportAt(c.ast.mainToken(b.bind), .E0211, &.{"every alternative of a `|` pattern must bind each name with the same type"}, "`{s}` has type `{s}` here but `{s}` in the first alternative", .{ bindName(c, b.bind), try c.tyName(b.ty), try c.tyName(f.ty) });
                ok.* = false;
            }
        };
    }
}

/// The bindings of `p`, in source order (of its first alternatives).
fn bindings(c: *Checker, p: Pat, out: *std.ArrayList(Pat)) Error!void {
    switch (p.shape) {
        .wild => if (p.bind != .none) try out.append(c.arena, p),
        .ctor => |k| for (k.args) |a| try bindings(c, a, out),
        .alt => |alts| try bindings(c, alts[0], out),
    }
}

/// The name binding node `n` introduces, without a raw-identifier `r#`.
fn bindName(c: *Checker, n: Node.Index) []const u8 {
    const name = c.ast.tokenSlice(c.ast.mainToken(n));
    return if (std.mem.startsWith(u8, name, "r#")) name[2..] else name;
}

// ---------------------------------------------------------------------------
// Lowering

/// One step from a place to a part of it.
const Step = struct { ty: TypeId, data: union(enum) { field: u32, variant_field: struct { variant: u32, index: u32 } } };

/// Emits the test of `subj` against `p`: on a match, the bindings are
/// stored and control continues in a new current block; otherwise it jumps
/// to `fail`. `match_rules`: a `mut x` binding into a mutable place is a
/// view of it (§6.6.3), not a copy as in a destructuring `let`.
fn bindTest(c: *Checker, subj: Subject, p: Pat, fail: tir.Block, match_rules: bool) Error!void {
    const branches = try expand(c, p);
    // The bindings of every alternative share one local per name.
    var named: std.StringHashMapUnmanaged(tir.Local) = .empty;
    const matched = if (branches.len > 1) try c.addBlock() else undefined;
    for (branches, 0..) |b, i| {
        const last = i + 1 == branches.len;
        const next = if (last) fail else try c.addBlock();
        try tests(c, subj, b, &.{}, next);
        try bindAll(c, subj, b, &.{}, &named, match_rules);
        if (branches.len == 1) return;
        try c.br(matched, .none);
        c.setBlock(if (last) matched else next);
    }
}

/// The alternative-free patterns that together match what `p` matches.
fn expand(c: *Checker, p: Pat) Error![]const Pat {
    switch (p.shape) {
        .wild => return c.arena.dupe(Pat, &.{p}),
        .alt => |alts| {
            var out: std.ArrayList(Pat) = .empty;
            for (alts) |a| try out.appendSlice(c.arena, try expand(c, a));
            return out.items;
        },
        .ctor => |k| {
            var out: std.ArrayList(Pat) = .empty;
            try out.append(c.arena, p);
            for (k.args, 0..) |a, i| {
                const choices = try expand(c, a);
                if (choices.len == 1) continue;
                var next: std.ArrayList(Pat) = .empty;
                for (out.items) |o| for (choices) |ch| {
                    const args = try c.arena.dupe(Pat, o.shape.ctor.args);
                    args[i] = ch;
                    var x = o;
                    x.shape.ctor.args = args;
                    try next.append(c.arena, x);
                };
                out = next;
            }
            return out.items;
        },
    }
}

/// The place `path` leads to from the subject.
fn place(c: *Checker, subj: Subject, path: []const Step) Error!tir.Ref {
    var r = try c.emit(subj.value.ty, .{ .local = .{ .local = subj.root } });
    for (path) |s| r = try c.emit(s.ty, switch (s.data) {
        .field => |i| .{ .field = .{ .base = r, .index = i } },
        .variant_field => |v| .{ .variant_field = .{ .base = r, .variant = v.variant, .index = v.index } },
    });
    return r;
}

/// `cond_br cond` to a new block, which becomes current, or to `fail`.
fn branch(c: *Checker, cond: tir.Ref, fail: tir.Block) Error!void {
    const ok = try c.addBlock();
    _ = try c.emit(.void, .{ .cond_br = .{ .cond = cond, .then = ok, .@"else" = fail } });
    c.setBlock(ok);
}

/// Emits the tests of the alternative-free pattern `p` at `path`.
fn tests(c: *Checker, subj: Subject, p: Pat, path: []const Step, fail: tir.Block) Error!void {
    const k = switch (p.shape) {
        .wild => return,
        .alt => unreachable, // expanded
        .ctor => |k| k,
    };
    if (p.ty == .err) return;
    switch (try exhaustive.spaceOf(c, p.ty)) {
        .int => |space| {
            const r = k.ctor.range;
            const v = try c.emit(p.ty, .{ .load = .{ .place = try place(c, subj, path) } });
            if (r.lo == r.hi) return branch(c, try compare(c, .eq, v, p.ty, r.lo), fail);
            if (r.lo > space.range.lo) try branch(c, try compare(c, .ge, v, p.ty, r.lo), fail);
            if (r.hi < space.range.hi) try branch(c, try compare(c, .le, v, p.ty, r.hi), fail);
        },
        .sum => |s| {
            const vi = k.ctor.variant;
            if (s.kind == .@"enum" and s.names.len > 1) {
                const backing: TypeId, const disc: i128 = if (c.items.enumOf(c.underlying(p.ty))) |e|
                    .{ e.backing, e.variants[vi].discriminant.bits }
                else
                    .{ .int(.unsigned, 8), vi }; // `Option`/`Result`: tags 0 and 1
                const tag = try c.emit(backing, .{ .enum_tag = .{ .place = try place(c, subj, path) } });
                try branch(c, try compare(c, .eq, tag, backing, disc), fail);
            }
            for (k.args, s.fields[vi], 0..) |a, t, i| try tests(c, subj, a, try stepTo(c, path, s, vi, i, t), fail);
        },
        .any => unreachable, // only wild patterns check against these
    }
}

/// `path` extended to field `i` (of type `t`) of constructor `vi` of `s`.
fn stepTo(c: *Checker, path: []const Step, s: exhaustive.Sum, vi: u32, i: usize, t: TypeId) Error![]const Step {
    const step: Step = .{ .ty = t, .data = if (s.kind == .@"enum")
        .{ .variant_field = .{ .variant = vi, .index = @intCast(i) } }
    else
        .{ .field = @intCast(i) } };
    return std.mem.concat(c.arena, Step, &.{ path, &.{step} });
}

/// `v op k` for constant `k` of type `ty`, as a `bool`.
fn compare(c: *Checker, comptime op: enum { eq, ge, le }, v: tir.Ref, ty: TypeId, k: i128) Error!tir.Ref {
    const kv = try c.constant(.{ .type = ty, .bits = @truncate(@as(u128, @bitCast(k))) });
    return c.emit(.bool, switch (op) {
        .eq => .{ .eq = .{ .lhs = v, .rhs = kv.ref } },
        .ge => .{ .ge = .{ .lhs = v, .rhs = kv.ref } },
        .le => .{ .le = .{ .lhs = v, .rhs = kv.ref } },
    });
}

/// Stores the bindings of the alternative-free pattern `p` at `path`.
fn bindAll(c: *Checker, subj: Subject, p: Pat, path: []const Step, named: *std.StringHashMapUnmanaged(tir.Local), match_rules: bool) Error!void {
    switch (p.shape) {
        .wild => if (p.bind != .none) try bind(c, subj, p, path, named, match_rules),
        .alt => unreachable, // expanded
        .ctor => |k| {
            if (p.ty == .err) {
                for (k.args) |a| try bindAll(c, subj, a, path, named, match_rules);
                return;
            }
            if (k.ctor == .range) return;
            const s = (try exhaustive.spaceOf(c, p.ty)).sum;
            const vi = k.ctor.variant;
            for (k.args, s.fields[vi], 0..) |a, t, i| try bindAll(c, subj, a, try stepTo(c, path, s, vi, i, t), named, match_rules);
        },
    }
}

/// Binds `p.bind` to the part of the subject at `path` (§6.6.3).
fn bind(c: *Checker, subj: Subject, p: Pat, path: []const Step, named: *std.StringHashMapUnmanaged(tir.Local), match_rules: bool) Error!void {
    const kind = c.ast.kind(p.bind);
    const is_mut = kind == .pat_bind_mut or kind == .field_pat_mut;
    const name = bindName(c, p.bind);
    const gop = try named.getOrPut(c.arena, name);
    if (!gop.found_existing) gop.value_ptr.* = try c.b.addLocal(.{
        .ty = p.ty,
        .name = try c.types.strings.intern(name),
        .kind = if (is_mut) .let_mut else .let,
        .node = p.bind,
    });
    const l = gop.value_ptr.*;
    try c.locals.put(c.arena, p.bind, l);
    if (p.ty == .err) return;
    if ((match_rules and is_mut and subj.mutable) or c.types.get(p.ty) == .mut_view) {
        _ = c.unsupported(p.bind, "`mut` views bound by patterns (T055)");
        return;
    }
    const at = try place(c, subj, path);
    const value = if (try check_stmt.isResource(c, p.ty)) switch (subj.mode) {
        .move => try c.emit(p.ty, .{ .move = .{ .place = at } }),
        .view, .copy => try c.emit(p.ty, .{ .view = .{ .place = at } }),
    } else try c.emit(p.ty, .{ .load = .{ .place = at } });
    const slot = try c.emit(p.ty, .{ .local = .{ .local = l } });
    _ = try c.emit(.void, .{ .store = .{ .place = slot, .value = value } });
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const Fixture = emit_tir.Fixture;

/// Fails unless some diagnostic message contains `text`.
fn expectMessage(f: *Fixture, text: []const u8) !void {
    for (f.p.sink.finish()) |d| if (std.mem.indexOf(u8, d.message, text) != null) return;
    std.debug.print("no diagnostic mentions {s}\n", .{text});
    return error.TestUnexpectedResult;
}

/// The ops of function `name` among `want`, in emission order.
fn expectOps(f: *Fixture, name: []const u8, want: []const tir.Op) !void {
    const func = try f.func(name);
    var got: std.ArrayList(tir.Op) = .empty;
    defer got.deinit(testing.allocator);
    for (0..func.insts.len) |i| {
        const op = func.op(.from(i));
        if (std.mem.indexOfScalar(tir.Op, want, op) != null) try got.append(testing.allocator, op);
    }
    try testing.expectEqualSlices(tir.Op, want, got.items);
}

test "E0357: a missing variant is listed; u2 with four arms is exhaustive; u8 needs `_`" {
    var f: Fixture = undefined;
    try f.init(
        \\enum Light { red, yellow, green }
        \\fn next(l: Light) -> Light {
        \\    match l { .red => .green, .green => .red }
        \\}
        \\fn quarter(q: u2) -> u32 { match q { 0 => 0, 1 => 90, 2 => 180, 3 => 270 } }
        \\fn byte(b: u8) -> u32 { match b { 0 => 0, 1 => 1 } }
        \\fn guarded(l: Light, ok: bool) -> u32 { match l { .red => 0, .yellow => 1, .green if ok => 2 } }
        \\fn flag(b: bool, t: (bool, u8)) -> u32 {
        \\    let x: u32 = match b { true => 1, false => 0 };
        \\    match t { (true, _) => x, (false, 0..=9) => 1, (false, 10..=255) => 2 }
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{ .{ .E0357, "match" }, .{ .E0357, "match" }, .{ .E0357, "match" } });
    try expectMessage(&f, "`.yellow` not covered");
    try expectMessage(&f, "`2..=255` not covered");
    try expectMessage(&f, "`.green` not covered");
    _ = try f.func("quarter");
    _ = try f.func("flag");
}

test "W0302: arms after `_` or a covered value; guarded arms cover nothing" {
    var f: Fixture = undefined;
    try f.init(
        \\enum Light { red, yellow, green }
        \\fn code(l: Light, urgent: bool) -> u32 {
        \\    match l { .red if urgent => 0, .red => 1, _ => 2, .green => 3 }
        \\}
        \\fn digit(b: u8) -> u32 { match b { 0..=9 => 0, 5 => 1, _ => 2 } }
    );
    defer f.deinit();
    try f.expectDiags(&.{ .{ .W0302, "green" }, .{ .W0302, "5" } });
    // Warnings do not fail the body.
    _ = try f.func("code");
    _ = try f.func("digit");
}

test "E0356: the `else` of `guard let` must diverge; bindings live on" {
    var f: Fixture = undefined;
    try f.init(
        \\fn find(v: u32) -> Option<usize> { if v == 7 { .some(3) } else { .none } }
        \\fn index_of(v: u32) -> usize {
        \\    guard let .some(i) = find(v) else { return 0; }
        \\    i
        \\}
        \\fn bad(v: u32) -> usize {
        \\    guard let .some(i) = find(v) else { 1u8; }
        \\    i
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{.{ .E0356, "{" }});
    _ = try f.func("index_of");
}

test "`match move` binds a resource payload by move; a place binds by view" {
    var f: Fixture = undefined;
    try f.init(
        \\@resource
        \\struct File { fd: i32 }
        \\enum Slot { empty, full(File) }
        \\fn take(move s: Slot) {
        \\    match move s { .full(f) => {}, .empty => {} }
        \\}
        \\fn peek(s: Slot) -> i32 {
        \\    match s { .full(f) => 1, .empty => 0 }
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    try expectOps(&f, "take", &.{ .enum_tag, .variant_field, .move, .enum_tag });
    try expectOps(&f, "peek", &.{ .enum_tag, .variant_field, .view, .enum_tag });
}

test "E0211 alternative types, E0212 struct pattern fields, destructuring `let`" {
    var f: Fixture = undefined;
    try f.init(
        \\enum Value { int(i32), flag(bool), other(i32) }
        \\struct Point { x: i32, y: i32 }
        \\fn size(v: Value) -> u32 { match v { .int(x) | .flag(x) => 0, .other(_) => 1 } }
        \\fn number(v: Value) -> i32 { match v { .int(x) | .other(x) => x, .flag(_) => 0 } }
        \\fn first(p: Point) -> i32 { let Point { x } = p; x }
        \\fn both(p: Point, t: (u8, u8)) -> i32 {
        \\    let Point { x: a, y: b } = p;
        \\    let .{ mut y, .. } = p;
        \\    y += 1;
        \\    let (q, r) = t;
        \\    a + b + y + (q + r) as i32
        \\}
        \\fn refutable(o: Option<u32>) -> u32 { let .some(v) = o; v }
    );
    defer f.deinit();
    try f.expectDiags(&.{ .{ .E0211, "x" }, .{ .E0212, "{" }, .{ .E0357, "some" } });
    try expectMessage(&f, "`.none` not covered");
    _ = try f.func("number");
    _ = try f.func("both");
}

test "golden TIR: `if let` and `while let`" {
    var f: Fixture = undefined;
    try f.init(
        \\fn get(n: u32) -> Option<u32> { if n > 0 { .some(n) } else { .none } }
        \\fn or_zero(o: Option<u32>) -> u32 { if let .some(v) = o { v } else { 0 } }
        \\fn count(n: u32) -> u32 {
        \\    let mut k = n;
        \\    while let .some(v) = get(k) { k = v - 1; }
        \\    k
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    try f.expectDump("or_zero",
        \\fn or_zero(l0 o: Option<u32>) -> u32 {
        \\  l1 v: u32
        \\b0:
        \\  %0: Option<u32> = local l0
        \\  %1: u8 = enum_tag %0
        \\  %2: u8 = int 0
        \\  %3: bool = eq %1, %2
        \\  cond_br %3, b3, b2
        \\b1:
        \\  %11: u32 = local l1
        \\  %12: u32 = load %11
        \\  br b4, [%12]
        \\b2:
        \\  %15: u32 = int 0
        \\  br b4, [%15]
        \\b3:
        \\  %5: Option<u32> = local l0
        \\  %6: u32 = variant_field %5, 0, 0
        \\  %7: u32 = load %6
        \\  %8: u32 = local l1
        \\  store %8, %7
        \\  br b1, []
        \\b4(%13: u32):
        \\  ret %13
        \\}
        \\
    );
    _ = try f.func("count");
}
