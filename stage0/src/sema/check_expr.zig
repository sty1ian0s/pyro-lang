//! Expression checking (§6.1, §6.4.1, §4.8, §4.9): bidirectional typing
//! of expressions and their TIR emission.
//!
//! `check(c, n, expected)` types expression `n`; `expected` is the type the
//! context wants (`.none` for none). It guides untyped constants and
//! branch results but is not enforced: `checkAs` also converts the result
//! (§4.9.1), reporting E0306/E0310.
//!
//! Every expression kind is checked by the handler registered for its node
//! kind in `handlers`, the one dispatch table of the checker. Extension tasks
//! add a `check_*.zig` module and register their handlers there; a kind
//! without a handler is unsupported (see `emit_tir.zig`) and `owner` names
//! the task that adds it.

const std = @import("std");
const Ast = @import("../ast/Ast.zig");
const literals = @import("../lex/literals.zig");
const Types = @import("types.zig");
const convert = @import("convert.zig");
const items_mod = @import("items.zig");
const emit_tir = @import("emit_tir.zig");
const check_stmt = @import("check_stmt.zig");
const check_literals = @import("check_literals.zig");
const check_call = @import("check_call.zig");
const check_member = @import("check_member.zig");
const check_index = @import("check_index.zig");
const builtins = @import("builtins.zig");
const patterns = @import("patterns.zig");
const unsafe = @import("unsafe.zig");
const comptime_ctx = @import("comptime_ctx.zig");
const tir = @import("../tir/tir.zig");
const interp_expr = @import("../comptime/interp_expr.zig");
const TokenKind = @import("../lex/token.zig").TokenKind;

const Node = Ast.Node;
const NodeKind = Ast.NodeKind;
const TypeId = Types.TypeId;
const Checker = emit_tir.Checker;
const Typed = emit_tir.Typed;
const Error = emit_tir.Error;

/// Checks expression node `n` where a value of type `expected` (or `.none`) is wanted.
pub const Handler = *const fn (c: *Checker, n: Node.Index, expected: TypeId) Error!Typed;

/// The handler of each expression node kind. Register new handlers here.
const handlers = blk: {
    var t: std.enums.EnumArray(NodeKind, ?Handler) = .initFill(null);
    for ([_]struct { NodeKind, Handler }{
        .{ .int_lit, intLit },
        .{ .float_lit, floatLit },
        .{ .char_lit, charLit },
        .{ .bool_lit, boolLit },
        .{ .string_lit, stringLit },
        .{ .ident, ident },
        .{ .self_value, selfValue },
        .{ .paren, paren },
        .{ .prefix, prefix },
        .{ .binary, binary },
        .{ .cast, cast },
        .{ .call, check_call.call },
        .{ .field_access, check_member.fieldAccess },
        .{ .index, check_index.index },
        .{ .range, check_index.range },
        .{ .struct_lit, check_literals.structLit },
        .{ .anon_lit, check_literals.anonLit },
        .{ .inferred_member, check_literals.inferredMember },
        .{ .array_lit, check_literals.arrayLit },
        .{ .array_repeat, check_literals.arrayRepeat },
        .{ .tuple, check_literals.tuple },
        .{ .builtin_call, builtins.check },
        .{ .block, check_stmt.block },
        .{ .@"if", check_stmt.ifExpr },
        .{ .loop, check_stmt.loopExpr },
        .{ .@"while", check_stmt.whileExpr },
        .{ .labeled, check_stmt.labeled },
        .{ .match, patterns.matchExpr },
        .{ .unsafe_block, unsafe.block },
        .{ .comptime_block, comptime_ctx.expr },
    }) |e| t.set(e[0], e[1]);
    break :blk t;
};

/// The construct of an unsupported node kind and the task that checks it.
fn owner(k: NodeKind) []const u8 {
    return switch (k) {
        .comptime_if => "`comptime if` (T061)",
        .lambda => "lambdas (T074)",
        .@"for", .for_inline => "`for` loops (T076)",
        .try_op, .array_comp => "`?` and comprehensions (T077)",
        .ml_string => "multi-line strings (T112)",
        else => "this expression (a later task)",
    };
}

/// Checks expression `n` where a value of type `expected` (or `.none`) is
/// wanted; the result need not have that type.
pub fn check(c: *Checker, n: Node.Index, expected: TypeId) Error!Typed {
    const saved = c.b.node;
    c.b.node = n;
    defer c.b.node = saved;
    const k = c.ast.kind(n);
    const h = handlers.get(k) orelse return c.unsupported(n, owner(k));
    return h(c, n, expected);
}

/// Checks expression `n` and converts it to `to` (§4.9.1).
pub fn checkAs(c: *Checker, n: Node.Index, to: TypeId) Error!Typed {
    // A `mut T` is a view of a mutable place (§5.5.3, §5.5.4).
    if (to != .none and to != .err and c.types.get(to) == .mut_view) return @import("mutability.zig").viewMut(c, n, to);
    return c.coerce(try check(c, n, to), to, check_stmt.valueNode(c.ast, n));
}

// ---------------------------------------------------------------------------
// Literals and names

fn intLit(c: *Checker, n: Node.Index, _: TypeId) Error!Typed {
    const iv = literals.decodeInt(c.ast.tokenSlice(c.ast.mainToken(n))) catch {
        c.failed = true; // reported by the lexer (E0108)
        return .err;
    };
    const k = try convert.fromInt(c.arena, iv.value);
    const ty: TypeId = switch (iv.suffix) {
        .none => return .{ .ty = .untyped_int, .konst = k },
        .unsigned => |b| .int(.unsigned, b),
        .signed => |b| .int(.signed, b),
        .usize => .usize,
        .isize => .isize,
    };
    return c.constTo(k, ty, n);
}

fn floatLit(c: *Checker, n: Node.Index, _: TypeId) Error!Typed {
    const text = c.ast.tokenSlice(c.ast.mainToken(n));
    const fv = literals.decodeFloat(text);
    return switch (fv.suffix) {
        .none => .{ .ty = .untyped_float, .konst = convert.parseFloat(c.arena, text) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TooLarge => {
                try c.report(n, .E0306, "float constant is too large", .{});
                return .err;
            },
        } },
        .f32 => c.constant(.{ .type = .f32, .bits = @as(u32, @bitCast(@as(f32, @floatCast(fv.value)))) }),
        .f64 => c.constant(.{ .type = .f64, .bits = @bitCast(fv.value) }),
    };
}

fn charLit(c: *Checker, n: Node.Index, _: TypeId) Error!Typed {
    return .{ .ty = .untyped_int, .konst = try convert.fromInt(c.arena, literals.decodeChar(c.ast.tokenSlice(c.ast.mainToken(n)))) };
}

fn boolLit(c: *Checker, n: Node.Index, _: TypeId) Error!Typed {
    return c.constant(.{ .type = .bool, .bits = @intFromBool(c.ast.tokens.items(.kind)[c.ast.mainToken(n)] == .kw_true) });
}

fn stringLit(c: *Checker, n: Node.Index, _: TypeId) Error!Typed {
    var out: std.Io.Writer.Allocating = .init(c.arena);
    literals.decodeString(c.ast.tokenSlice(c.ast.mainToken(n)), &out.writer) catch return error.OutOfMemory;
    const s = try c.types.strings.intern(out.written());
    return .{ .ty = .str, .ref = try c.emit(.str, .{ .str = .{ .string = s } }) };
}

pub fn ident(c: *Checker, n: Node.Index, _: TypeId) Error!Typed {
    const e = c.items.names.get(c.m, n) orelse {
        try c.report(n, null, "cannot find `{s}` in this scope", .{c.ast.tokenSlice(c.ast.mainToken(n))});
        return .err;
    };
    switch (e.res) {
        .local => |l| switch (c.ast.kind(l)) {
            .pat_bind, .pat_bind_mut, .field_pat, .field_pat_mut, .param => return c.load(c.locals.get(l) orelse {
                // Comptime code sees no runtime local of the enclosing function (§8.1).
                if (c.in_comptime) {
                    try c.report(n, .E0801, "`{s}` is a runtime value and cannot be used at comptime", .{c.ast.tokenSlice(c.ast.mainToken(n))});
                    return .err;
                }
                return c.unsupported(n, "bindings of `for` loops and lambdas (T074, T076)");
            }),
            .const_decl => return constValue(c, n, try c.items.constValue(c.m, l, c.self_ty)),
            .generic_param => return c.unsupported(n, "generic value parameters (T064)"),
            else => return c.unsupported(n, "`result` in contracts (T135)"),
        },
        .global => |t| switch (t) {
            .item => |ref| {
                const item = c.items.im.graph.modules[ref.module].items[ref.item];
                return switch (item.kind) {
                    .@"const" => constValue(c, n, try c.items.constValue(ref.module, item.node, .none)),
                    .@"fn", .extern_fn => check_call.fnValue(c, n, ref),
                    else => c.unsupported(n, "types as values (T065)"),
                };
            },
            // Already reported (the check fails anyway), or from a module a
            // single-file check did not load: not shown valid either way.
            .unresolved => return c.unsupported(n, "names from modules not loaded (multi-file check)"),
            .prelude => return c.unsupported(n, "prelude functions and values (T105)"),
            .external => return c.unsupported(n, "standard library items (T163)"),
            .module => {
                try c.report(n, .E0310, "module `{s}` is not a value", .{c.ast.tokenSlice(c.ast.mainToken(n))});
                return .err;
            },
        },
    }
}

/// The value of const `k` used at `n` (§7.7): untyped constants stay untyped.
pub fn constValue(c: *Checker, n: Node.Index, k: items_mod.Const) Error!Typed {
    return switch (k.value) {
        .untyped => |u| .{ .ty = u.typeOf(), .konst = u },
        .scalar => |s| c.constant(s),
        .type => c.unsupported(n, "types as values (T065)"),
        .computed => |cv| comptime_ctx.use(c, n, cv),
        .unknown => if (k.type == .err) blk: {
            c.failed = true; // reported with the const
            break :blk .err;
        } else c.unsupported(n, "consts evaluated at comptime (T060)"),
    };
}

fn selfValue(c: *Checker, _: Node.Index, _: TypeId) Error!Typed {
    if (c.self_local == .none) {
        c.failed = true; // `self` outside a method is E0205 (parser)
        return .err;
    }
    return c.load(c.self_local);
}

fn paren(c: *Checker, n: Node.Index, expected: TypeId) Error!Typed {
    return check(c, c.ast.data(n).paren.inner, expected);
}

// ---------------------------------------------------------------------------
// Operators (§6.4.1)

fn prefix(c: *Checker, n: Node.Index, expected: TypeId) Error!Typed {
    const op = c.ast.tokens.items(.kind)[c.ast.mainToken(n)];
    const operand = c.ast.data(n).prefix.operand;
    switch (op) {
        .minus, .tilde, .bang => {},
        .star => return unsafe.deref(c, n, expected),
        .amp => return unsafe.addrOf(c, n, expected),
        .kw_move => return c.unsupported(n, "`move` (T080)"),
        else => return comptime_ctx.expr(c, n, expected),
    }
    const v = try check(c, operand, if (op == .bang) .bool else expected);
    if (v.ty == .err or v.ty == .noreturn) return v;
    if (v.konst) |k| switch (op) {
        .minus => return .{ .ty = v.ty, .konst = try convert.negate(k) },
        .tilde => if (k == .int) return .{ .ty = v.ty, .konst = convert.bitNot(c.arena, k) catch return error.OutOfMemory },
        else => {},
    };
    const ok = switch (op) {
        .minus => isNumeric(c, v.ty),
        .tilde => isBitwise(c, v.ty),
        else => v.ty == .bool or c.types.get(v.ty) == .mask,
    };
    if (!ok) {
        try c.report(n, .E0310, "operator `{s}` is not defined for `{s}`", .{ c.ast.tokenSlice(c.ast.mainToken(n)), try c.tyName(v.ty) });
        return .err;
    }
    const d: tir.Data = switch (op) {
        .minus => .{ .neg = .{ .operand = v.ref } },
        .tilde => .{ .bit_not = .{ .operand = v.ref } },
        else => .{ .not = .{ .operand = v.ref } },
    };
    return .{ .ty = v.ty, .ref = try c.emit(v.ty, d) };
}

/// Operator classes of §6.4.1.
const Class = enum { arith, bitwise, shift, eq, ord };

fn classOf(op: TokenKind) ?Class {
    return switch (op) {
        .plus, .minus, .star, .slash, .percent, .plus_eq, .minus_eq, .star_eq, .slash_eq, .percent_eq => .arith,
        .amp, .pipe, .caret, .amp_eq, .pipe_eq, .caret_eq => .bitwise,
        .shl, .shr, .shl_eq, .shr_eq => .shift,
        .eq_eq, .bang_eq => .eq,
        .lt, .gt, .lt_eq, .gt_eq => .ord,
        else => null,
    };
}

fn binary(c: *Checker, n: Node.Index, expected: TypeId) Error!Typed {
    const d = c.ast.data(n).binary;
    const op = c.ast.tokens.items(.kind)[c.ast.mainToken(n)];
    if (op == .amp_amp or op == .pipe_pipe) return check_stmt.logical(c, n, op == .amp_amp);
    const class = classOf(op) orelse return c.unsupported(n, "this operator (a later task)");
    // The other operand is the expected type of each (§6.2.3).
    const l_expected: TypeId = if (class == .arith or class == .bitwise or class == .shift) expected else .none;
    if (class != .shift and l_expected == .none and needsExpected(c.ast, d.lhs)) {
        // Checking the right first emits it first; only a bare `.name` (a
        // variant or `const`, no side effects) may be evaluated after it.
        if (c.ast.kind(d.lhs) != .inferred_member)
            return c.unsupported(d.lhs, "a call or literal typed by the right operand (a later task)");
        const r = try check(c, d.rhs, .none);
        const l = try check(c, d.lhs, if (r.isUntyped() or r.ty == .noreturn) .none else r.ty);
        return operate(c, n, op, l, r, expected);
    }
    const l = try check(c, d.lhs, l_expected);
    const r = try check(c, d.rhs, if (class == .shift) .none else if (l.isUntyped()) .none else l.ty);
    return operate(c, n, op, l, r, expected);
}

/// `n` takes its type only from the expected type: `.name`, `.name(args)`
/// or `.{ ... }` (§6.2.2, §6.2.3).
fn needsExpected(ast: *const Ast, n: Node.Index) bool {
    return switch (ast.kind(n)) {
        .inferred_member, .anon_lit => true,
        .call => ast.kind(ast.data(n).call.callee) == .inferred_member,
        else => false,
    };
}

/// `l op r` for checked operands (also used by compound assignment).
/// `expected` types an untyped left operand of a shift.
pub fn operate(c: *Checker, n: Node.Index, op: TokenKind, l_in: Typed, r_in: Typed, expected: TypeId) Error!Typed {
    const class = classOf(op).?;
    var l = l_in;
    var r = r_in;
    if (l.ty == .err or r.ty == .err) return .err;
    if (l.ty == .noreturn or r.ty == .noreturn) return .never;
    if (l.isUntyped() and r.isUntyped()) return fold(c, n, op, class, l.konst.?, r.konst.?);

    if (class == .shift) {
        if (l.isUntyped()) l = try c.coerce(l, if (expected == .none or expected == .err) .none else expected, n);
        if (l.ty == .err) return .err;
        if (!isBitwise(c, l.ty) or c.types.get(l.ty) == .mask) return notDefined(c, n, l.ty);
        if (c.types.get(l.ty) == .vec) {
            r = try broadcast(c, r, l.ty, n);
        } else if (r.isUntyped()) {
            const u = c.underlying(l.ty);
            r = try c.coerce(r, if (isUnsigned(c, u)) u else .int(.unsigned, 32), n);
        } else if (!isUnsigned(c, c.underlying(r.ty))) {
            try c.report(n, .E0310, "shift amount must be an unsigned integer, found `{s}`", .{try c.tyName(r.ty)});
            return .err;
        }
        if (r.ty == .err) return .err;
        return emitOp(c, op, l.ty, l, r);
    }

    const ty = try unify(c, n, &l, &r) orelse return .err;
    const ok = switch (class) {
        .arith => isNumeric(c, ty),
        .bitwise => isBitwise(c, ty),
        .eq => (try supportsEq(c, ty, 0)) orelse return c.unsupported(n, "`==` on generic and standard library types (T064, T163)"),
        .ord => supportsOrd(c, ty),
        .shift => unreachable,
    };
    if (!ok) return notDefined(c, n, ty);
    const result: TypeId = switch (class) {
        .eq, .ord => switch (c.types.get(ty)) {
            .vec => |v| try c.types.intern(.{ .mask = .{ .len = v.len } }),
            .mask => ty,
            else => .bool,
        },
        else => ty,
    };
    return emitOp(c, op, result, l, r);
}

fn notDefined(c: *Checker, n: Node.Index, ty: TypeId) Error!Typed {
    try c.report(n, .E0310, "operator `{s}` is not defined for `{s}`", .{ c.ast.tokenSlice(c.ast.mainToken(n)), try c.tyName(ty) });
    return .err;
}

fn emitOp(c: *Checker, op: TokenKind, ty: TypeId, l: Typed, r: Typed) Error!Typed {
    const tag: std.meta.Tag(tir.Data) = switch (op) {
        .plus, .plus_eq => .add,
        .minus, .minus_eq => .sub,
        .star, .star_eq => .mul,
        .slash, .slash_eq => .div,
        .percent, .percent_eq => .rem,
        .amp, .amp_eq => .bit_and,
        .pipe, .pipe_eq => .bit_or,
        .caret, .caret_eq => .bit_xor,
        .shl, .shl_eq => .shl,
        .shr, .shr_eq => .shr,
        .eq_eq => .eq,
        .bang_eq => .ne,
        .lt => .lt,
        .gt => .gt,
        .lt_eq => .le,
        .gt_eq => .ge,
        else => unreachable,
    };
    const d: tir.Data = switch (tag) {
        inline .add, .sub, .mul, .div, .rem, .bit_and, .bit_or, .bit_xor, .shl, .shr, .eq, .ne, .lt, .gt, .le, .ge => |t| @unionInit(tir.Data, @tagName(t), .{ .lhs = l.ref, .rhs = r.ref }),
        else => unreachable,
    };
    return .{ .ty = ty, .ref = try c.emit(ty, d) };
}

/// Folds `l op r` on untyped constants (§4.8): the result stays untyped,
/// except comparisons, which give `bool`.
fn fold(c: *Checker, n: Node.Index, op: TokenKind, class: Class, l: convert.Const, r: convert.Const) Error!Typed {
    if (class == .eq or class == .ord) {
        const ord = try convert.order(c.arena, l, r);
        const res = switch (op) {
            .eq_eq => ord == .eq,
            .bang_eq => ord != .eq,
            .lt => ord == .lt,
            .gt => ord == .gt,
            .lt_eq => ord != .gt,
            else => ord != .lt,
        };
        return c.constant(.{ .type = .bool, .bits = @intFromBool(res) });
    }
    const bop: convert.BinOp = switch (op) {
        .plus, .plus_eq => .add,
        .minus, .minus_eq => .sub,
        .star, .star_eq => .mul,
        .slash, .slash_eq => .div,
        .percent, .percent_eq => .rem,
        .shl, .shl_eq => .shl,
        .shr, .shr_eq => .shr,
        .amp, .amp_eq => .bit_and,
        .pipe, .pipe_eq => .bit_or,
        else => .bit_xor,
    };
    const k = convert.binary(c.arena, bop, l, r) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidOperand => return notDefined(c, n, l.typeOf()),
        // A trap in a constant expression is a compile error (§8.6); A.3 has
        // no code for it (spec gap, as in `interp_expr.report`).
        error.DivisionByZero => {
            try c.report(n, null, "comptime evaluation traps: {s}", .{interp_expr.message(error.DivisionByZero)});
            return .err;
        },
        error.TooLarge => {
            try c.report(n, null, "constant expression is too large: shift amount or exponent above {d}", .{convert.max_magnitude});
            return .err;
        },
    };
    return .{ .ty = k.typeOf(), .konst = k };
}

/// Converts `l` and `r` to their common type (§6.4.1): an untyped constant
/// takes the other operand's type, a narrower integer or `f32` widens, and a
/// scalar paired with a `vec` is broadcast. Reports E0310 and returns null
/// if there is none.
fn unify(c: *Checker, n: Node.Index, l: *Typed, r: *Typed) Error!?TypeId {
    const lv = isVecLike(c, l.ty);
    const rv = isVecLike(c, r.ty);
    if (lv and !rv) {
        r.* = try broadcast(c, r.*, l.ty, n);
    } else if (rv and !lv) {
        l.* = try broadcast(c, l.*, r.ty, n);
    } else if (l.isUntyped()) {
        l.* = try c.coerce(l.*, r.ty, n);
    } else if (r.isUntyped()) {
        r.* = try c.coerce(r.*, l.ty, n);
    } else if (l.ty != r.ty) {
        if (widens(c, l.ty, r.ty)) {
            l.* = try c.coerce(l.*, r.ty, n);
        } else if (widens(c, r.ty, l.ty)) {
            r.* = try c.coerce(r.*, l.ty, n);
        } else {
            try c.report(n, .E0310, "mismatched types: `{s}` and `{s}`", .{ try c.tyName(l.ty), try c.tyName(r.ty) });
            return null;
        }
    }
    if (l.ty == .err or r.ty == .err) return null;
    return l.ty;
}

/// Scalar `v` broadcast to every lane of `vec`/`mask` type `to` (§4.3.1).
fn broadcast(c: *Checker, v: Typed, to: TypeId, n: Node.Index) Error!Typed {
    if (v.ty == to) return v;
    const elem: TypeId = switch (c.types.get(to)) {
        .vec => |x| x.elem,
        else => .bool,
    };
    const s = try c.coerce(v, elem, n);
    if (s.ty == .err) return .err;
    return .{ .ty = to, .ref = try c.emit(to, .{ .splat = .{ .scalar = s.ref } }) };
}

fn widens(c: *Checker, from: TypeId, to: TypeId) bool {
    return switch (convert.coerce(c.types, from, to, .{})) {
        .int_widen, .float_widen => true,
        else => false,
    };
}

fn isVecLike(c: *Checker, ty: TypeId) bool {
    return switch (c.types.get(ty)) {
        .vec, .mask => true,
        else => false,
    };
}

fn isInt(c: *Checker, ty: TypeId) bool {
    return ty == .usize or ty == .isize or c.types.get(ty) == .int;
}

/// True for `usize` and the unsigned fixed-width integer types.
pub fn isUnsigned(c: *Checker, ty: TypeId) bool {
    return ty == .usize or switch (c.types.get(ty)) {
        .int => |i| i.signedness == .unsigned,
        else => false,
    };
}

/// Integer, float, a `vec` of them, or a distinct type over one (§4.7).
fn isNumeric(c: *Checker, ty: TypeId) bool {
    const u = c.underlying(ty);
    return switch (c.types.get(u)) {
        .vec => |v| v.elem != .bool,
        else => isInt(c, u) or u == .f32 or u == .f64,
    };
}

/// Integer, a `vec` of integers or `bool`, a `mask`, or a distinct type over one.
fn isBitwise(c: *Checker, ty: TypeId) bool {
    const u = c.underlying(ty);
    return switch (c.types.get(u)) {
        .vec => |v| v.elem == .bool or isInt(c, v.elem),
        .mask => true,
        else => isInt(c, u),
    };
}

/// `==`/`!=` (§6.4.1): primitives, `str`, handles, pointers, `vec`/`mask`
/// lane-wise, and plain structs, tuples, arrays and enums whose parts all
/// support it. Null if that is not known yet: generic instances and
/// standard library types.
fn supportsEq(c: *Checker, ty: TypeId, depth: u32) Error!?bool {
    if (depth > 64) return false; // recursive types are E0376
    switch (ty) {
        .bool, .str, .f32, .f64, .usize, .isize => return true,
        else => {},
    }
    switch (c.types.get(ty)) {
        .int, .handle, .ptr, .vec, .mask => return true,
        .array => |a| return supportsEq(c, a.elem, depth + 1),
        .tuple => |t| return allEq(c, t.elems, depth),
        .nominal => |nm| {
            if (nm.kind == .distinct) return supportsEq(c, nm.underlying, depth + 1);
            // shortcut: generic instances need substitution (T064); standard library types are not loaded (T163).
            if (nm.args.len > 0) return null;
            if (c.items.structOf(ty)) |s| {
                if (try check_stmt.isResource(c, ty)) return false;
                for (s.fields) |f| if (!((try supportsEq(c, f.type, depth + 1)) orelse return null)) return false;
                return true;
            }
            if (c.items.enumOf(ty)) |e| {
                for (e.variants) |v| if (!((try allEq(c, v.payload, depth)) orelse return null)) return false;
                return true;
            }
            return if (nm.kind == .protocol) false else null;
        },
        else => return false,
    }
}

fn allEq(c: *Checker, tys: []const TypeId, depth: u32) Error!?bool {
    for (tys) |t| if (!((try supportsEq(c, t, depth + 1)) orelse return null)) return false;
    return true;
}

/// `< > <= >=` (§6.4.1): integers, floats, `str`, raw pointers (§12.2),
/// payload-free enums, and `vec`s lane-wise.
fn supportsOrd(c: *Checker, ty: TypeId) bool {
    const u = c.underlying(ty);
    if (u == .str or isNumeric(c, u) or c.types.get(u) == .ptr) return true;
    const e = c.items.enumOf(u) orelse return false;
    return !e.has_payload;
}

// ---------------------------------------------------------------------------
// Casts

/// `value as T` (§4.9.2).
fn cast(c: *Checker, n: Node.Index, _: TypeId) Error!Typed {
    const d = c.ast.data(n).cast;
    const to = try c.resolveType(d.ty);
    const v = try check(c, d.value, .none);
    if (to == .err or v.ty == .err) return .err;
    if (v.ty == .noreturn) return v;
    if (v.konst) |k| switch (try convert.castConst(c.arena, c.types, c.items.options.ptr_bits, k, to)) {
        .ok => |val| return c.constant(val),
        .err => |code| {
            try c.report(n, code, "invalid constant conversion to `{s}`", .{try c.tyName(to)});
            return .err;
        },
    };
    const backing: TypeId = if (c.items.enumOf(v.ty)) |e| (if (e.has_payload) .none else e.backing) else .none;
    const kind = convert.cast(c.types, v.ty, to, backing) orelse {
        try c.report(n, .E0307, "invalid cast from `{s}` to `{s}`", .{ try c.tyName(v.ty), try c.tyName(to) });
        return .err;
    };
    if (kind == .identity) return .{ .ty = to, .ref = v.ref };
    if (kind == .int_to_ptr and !try unsafe.require(c, n, "converting an integer to a pointer")) return .err;
    return .{ .ty = to, .ref = try c.emit(to, .{ .cast = .{ .value = v.ref } }) };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const Fixture = emit_tir.Fixture;

test "operators: widening, broadcast, comparisons, shifts, constant folding" {
    var f: Fixture = undefined;
    try f.init(
        \\const K = 1 << 4;
        \\fn rows(a: u32, b: u32, p: bool, q: bool, s: str) {
        \\    let bit_and: bool = a & b == 0;
        \\    let bit_or: bool = a | b != 0;
        \\    let widened: u64 = a as u64 + b as u64;
        \\    let both: bool = a < b && p || q;
        \\    let shifted: bool = a << 1 > b;
        \\    let mixed: u64 = (a as u8) + 1u16 + 1u64;
        \\    let folded: u8 = K * 2 - 1;
        \\    let eq: bool = s == "x" && s < "y";
        \\    let neg: i8 = -128;
        \\    let not: bool = !(p && q);
        \\    let inv: u8 = ~0u8;
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    _ = try f.func("rows");
}

test "operator errors: E0310, E0306, E0307" {
    var f: Fixture = undefined;
    try f.init(
        \\enum Color { red, green }
        \\enum Shape { dot, circle(f32) }
        \\fn bad(x: f32, b: bool, c: Color, s: Shape, n: i32) {
        \\    let a = b + b;
        \\    let o = x & x;
        \\    let big: u8 = 256;
        \\    let lt = s < s;
        \\    let r = b as f32;
        \\    let k = 300 as u8;
        \\    let sh = x << 1;
        \\    let ok: bool = c < c && c == c;
        \\    let z: u8 = 1 / 0;
        \\    let huge: u8 = 1 << 100000;
        \\}
        \\fn fine(c: Color, s: Shape) -> bool { (c as u8) < 2 && s == s }
    );
    defer f.deinit();
    try f.expectDiags(&.{
        .{ .E0310, "+" },  .{ .E0310, "&" },  .{ .E0306, "256" }, .{ .E0310, "<" },
        .{ .E0307, "as" }, .{ .E0306, "as" }, .{ .E0310, "<<" },  .{ null, "/" },
        .{ null, "<<" },
    });
    _ = try f.func("fine");
}

test "calls: direct calls emit `call`; unknown names are reported" {
    var f: Fixture = undefined;
    try f.init(
        \\fn add(a: u32, b: u32) -> u32 { a + b }
        \\fn twice(x: u32) -> u32 { add(x, 1) + add(x, x) }
        \\fn oops() -> u32 { missing + 1 }
        \\fn args() -> u32 { missing_fn(true + 1) }
    );
    defer f.deinit();
    try f.expectDiags(&.{ .{ null, "missing" }, .{ null, "missing_fn" }, .{ .E0310, "+" } });
    try f.expectDump("twice",
        \\fn twice(l0 x: u32) -> u32 {
        \\b0:
        \\  %0: u32 = local l0
        \\  %1: u32 = load %0
        \\  %2: u32 = int 1
        \\  %3: u32 = call @0, [%1, %2]
        \\  %4: u32 = local l0
        \\  %5: u32 = load %4
        \\  %6: u32 = local l0
        \\  %7: u32 = load %6
        \\  %8: u32 = call @0, [%5, %7]
        \\  %9: u32 = add %3, %8
        \\  ret %9
        \\}
        \\
    );
}
