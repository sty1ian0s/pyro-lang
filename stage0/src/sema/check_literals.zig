//! Literals and constructors (§6.2.1-§6.2.4, §6.2.6): struct literals,
//! anonymous literals `.{ ... }`, inferred members `.name` / `.name(args)`,
//! arrays, `[v; N]` and tuples, plus the `.some` wrapper of §4.9.1 rule 8.
//!
//! Every handler takes the expected type of `check_expr.check`: anonymous
//! literals and inferred members are resolved in it (E0350, E0353), and it
//! guides the element types of arrays and tuples. Struct construction checks
//! the field list (E0340, E0351) and visibility outside the defining module
//! (E0352, §7.3.3), and emits one `aggregate` in declaration order.

const std = @import("std");
const Ast = @import("../ast/Ast.zig");
const Types = @import("types.zig");
const convert = @import("convert.zig");
const items_mod = @import("items.zig");
const emit_tir = @import("emit_tir.zig");
const check_expr = @import("check_expr.zig");
const check_stmt = @import("check_stmt.zig");
const check_call = @import("check_call.zig");
const tir = @import("../tir/tir.zig");

const Node = Ast.Node;
const TypeId = Types.TypeId;
const Checker = emit_tir.Checker;
const Typed = emit_tir.Typed;
const Error = emit_tir.Error;

/// The operands of an aggregate being built, and whether one failed or
/// diverges.
const Elems = struct {
    refs: []tir.Ref,
    ok: bool = true,
    diverges: bool = false,

    fn init(c: *Checker, n: usize) Error!Elems {
        const refs = try c.arena.alloc(tir.Ref, n);
        @memset(refs, .none);
        return .{ .refs = refs };
    }

    fn set(e: *Elems, i: usize, v: Typed) void {
        e.refs[i] = v.ref;
        e.ok = e.ok and v.ty != .err;
        e.diverges = e.diverges or v.ty == .noreturn;
    }

    /// The result if an operand failed or diverges, else null.
    fn early(e: Elems) ?Typed {
        if (!e.ok) return .err;
        if (e.diverges) return .never;
        return null;
    }

    /// The value of type `ty` made by `d` from the operands.
    fn finish(e: Elems, c: *Checker, ty: TypeId, d: tir.Data) Error!Typed {
        if (e.early()) |v| return v;
        if (ty == .err) return .err;
        return .{ .ty = ty, .ref = try c.emit(ty, d) };
    }
};

/// `ty` without an `Option` around it: the type a literal builds when
/// `ty` is expected (§4.9.1 rule 8).
fn unwrapOption(c: *Checker, ty: TypeId) TypeId {
    if (ty == .none or ty == .err) return ty;
    return convert.optionPayload(c.types, ty) orelse ty;
}

/// `v` wrapped in `.some` as a value of `Option<T>` type `to` (§4.9.1 rule 8);
/// `v` is first converted to `T`.
pub fn wrapSome(c: *Checker, v: Typed, to: TypeId, at: Node.Index) Error!Typed {
    const inner = try c.coerce(v, convert.optionPayload(c.types, to).?, at);
    if (inner.ty == .err or inner.ty == .noreturn) return inner;
    // `Option<T>` is `{ some(T), none }` (§14.1).
    return .{ .ty = to, .ref = try c.emit(to, .{ .variant = .{ .variant = 0, .payload = &.{inner.ref} } }) };
}

// ---------------------------------------------------------------------------
// Struct literals (§6.2.1, §6.2.2)

/// `Path { f: e, .. }`.
pub fn structLit(c: *Checker, n: Node.Index, _: TypeId) Error!Typed {
    const d = c.ast.data(n).struct_lit;
    const ty = try c.resolveType(d.ty);
    if (ty == .err) return checkAlone(c, d.fields);
    return construct(c, d.ty, ty, d.fields);
}

/// The struct declared by `ty` of this package, if it is one.
fn structDecl(c: *Checker, ty: TypeId) Error!?*const items_mod.Struct {
    const ref = c.items.declRef(ty) orelse return null;
    return switch ((try c.items.info(ref)).*) {
        .@"struct" => |*s| s,
        else => null,
    };
}

/// The struct value of type `ty` from `inits` (`field_init`, `named_arg` or
/// shorthand `ident` nodes, optionally ending in `rest`); diagnostics about the whole literal
/// go to `at`.
fn construct(c: *Checker, at: Node.Index, ty: TypeId, inits: []const Node.Index) Error!Typed {
    const s = (try structDecl(c, ty)) orelse {
        if (c.types.get(ty) == .nominal and c.items.declRef(ty) == null)
            return c.unsupported(at, "standard library types (T163)");
        try c.report(at, .E0310, "`{s}` is not a struct and cannot be built from fields", .{try c.tyName(ty)});
        return checkAlone(c, inits);
    };
    if (s.generics.len > 0) return c.unsupported(at, "generic struct literals (T068)");
    const outside = c.items.declRef(ty).?.module != c.m;
    if (outside) for (s.fields) |f| if (f.vis != .pub_mut and f.default == null) {
        try c.report(at, .E0352, "`{s}` cannot be constructed outside its module: field `{s}` is not `pub mut` and has no default", .{ try c.tyName(ty), f.name });
        return checkAlone(c, inits);
    };

    const has_rest = inits.len > 0 and c.ast.kind(inits[inits.len - 1]) == .rest;
    var e: Elems = try .init(c, s.fields.len);
    const seen = try c.arena.alloc(bool, s.fields.len);
    @memset(seen, false);
    for (inits[0 .. inits.len - @intFromBool(has_rest)]) |g| {
        const kind = c.ast.kind(g);
        if (kind != .field_init and kind != .named_arg and kind != .ident) {
            try c.report(g, null, "expected a field `name: value`", .{});
            _ = try check_expr.check(c, g, .none);
            e.ok = false;
            continue;
        }
        const name = c.ast.tokenSlice(c.ast.mainToken(g));
        const i = for (s.fields, 0..) |f, i| {
            if (std.mem.eql(u8, f.name, name)) break i;
        } else {
            try c.report(g, null, "`{s}` has no field `{s}`", .{ try c.tyName(ty), name });
            _ = try fieldValue(c, g, .none);
            e.ok = false;
            continue;
        };
        if (seen[i]) {
            try c.report(g, .E0351, "field `{s}` is given twice", .{name});
            _ = try fieldValue(c, g, .none);
            e.ok = false;
            continue;
        }
        seen[i] = true;
        if (outside and s.fields[i].vis != .pub_mut)
            try c.report(g, .E0352, "field `{s}` of `{s}` is not `pub mut` and cannot be set outside its module", .{ name, try c.tyName(ty) });
        e.set(i, try fieldValue(c, g, s.fields[i].type));
    }

    var missing: std.Io.Writer.Allocating = .init(c.arena);
    for (s.fields, seen, 0..) |f, given, i| {
        if (given) continue;
        if (has_rest and f.default != null) {
            e.set(i, try defaultValue(c, at, f));
        } else {
            if (missing.written().len > 0) missing.writer.writeAll(", ") catch return error.OutOfMemory;
            missing.writer.print("`{s}`", .{f.name}) catch return error.OutOfMemory;
        }
    }
    if (missing.written().len > 0) {
        try c.report(at, .E0340, "missing field(s) {s} in `{s}`", .{ missing.written(), try c.tyName(ty) });
        return .err;
    }
    return e.finish(c, ty, .{ .aggregate = .{ .elems = e.refs } });
}

/// The value of `field_init`, `named_arg` or `ident` `g` converted to `to`
/// (`.none`: unchecked type). The shorthand `x` reads the name `x`.
fn fieldValue(c: *Checker, g: Node.Index, to: TypeId) Error!Typed {
    const value: ?Node.Index = switch (c.ast.data(g)) {
        .field_init => |fi| fi.value,
        .named_arg => |na| na.value,
        .ident => null,
        else => unreachable,
    };
    if (value) |v| return check_expr.checkAs(c, v, to);
    return c.coerce(try check_expr.ident(c, g, to), to, g);
}

/// The declared default of field `f`, evaluated at the construction site.
fn defaultValue(c: *Checker, at: Node.Index, f: items_mod.Field) Error!Typed {
    if (f.type == .err) {
        c.failed = true; // reported with the field
        return .err;
    }
    return switch (f.default.?) {
        .untyped => |k| c.constTo(k, f.type, at),
        .scalar => |v| c.coerce(try c.constant(v), f.type, at),
        .computed => |cv| c.coerce(try @import("comptime_ctx.zig").use(c, at, cv), f.type, at),
        .type => c.unsupported(at, "types as values (T065)"),
        .unknown => if (f.type == .err) blk: {
            c.failed = true; // reported with the default
            break :blk .err;
        } else c.unsupported(at, "values the comptime evaluator could not compute"),
    };
}

/// Checks the values of a literal that failed, for their own errors.
fn checkAlone(c: *Checker, inits: []const Node.Index) Error!Typed {
    for (inits) |g| switch (c.ast.kind(g)) {
        .field_init, .named_arg => _ = try fieldValue(c, g, .none),
        .rest => {},
        else => _ = try check_expr.check(c, g, .none),
    };
    c.failed = true;
    return .err;
}

// ---------------------------------------------------------------------------
// Anonymous literals and tuples (§6.2.2, §6.2.6)

/// `.{ f: e, .. }` builds the expected struct; `.{ a, b }` a tuple or `vec`.
pub fn anonLit(c: *Checker, n: Node.Index, expected: TypeId) Error!Typed {
    const elems = c.ast.data(n).anon_lit.elems;
    const target = unwrapOption(c, expected);
    // A bare `x` is shorthand for `x: x` unless a tuple or `vec` is expected (§3).
    const shorthand = target != .none and target != .err and switch (c.types.get(target)) {
        .tuple, .vec => false,
        else => true,
    };
    const named = for (elems) |e| switch (c.ast.kind(e)) {
        .named_arg, .rest => break true,
        .ident => if (shorthand) break true,
        else => {},
    } else false;
    if (!named) return positional(c, n, elems, expected, true);
    if (expected == .err) return checkAlone(c, elems);
    if (expected == .none) {
        try c.reportAt(c.ast.mainToken(n), .E0350, &.{"write the type before the braces, as in `Point { x: 1, y: 2 }`, or give the binding a type"}, "anonymous struct literal without an expected type", .{});
        return checkAlone(c, elems);
    }
    const v = try construct(c, n, target, elems);
    return if (target == expected) v else wrapSome(c, v, expected, n);
}

/// `(a, b)`.
pub fn tuple(c: *Checker, n: Node.Index, expected: TypeId) Error!Typed {
    return positional(c, n, c.ast.data(n).tuple.elems, expected, false);
}

/// A positional literal: a `vec` (if `allow_vec`) or tuple of the expected
/// type, else a tuple of its elements' types.
fn positional(c: *Checker, n: Node.Index, elems: []const Node.Index, expected: TypeId, allow_vec: bool) Error!Typed {
    const want = unwrapOption(c, expected);
    const key: ?Types.Key = if (want == .none or want == .err) null else c.types.get(want);
    var e: Elems = try .init(c, elems.len);
    if (key) |k| switch (k) {
        .vec => |v| if (allow_vec) {
            for (elems, 0..) |x, i| e.set(i, try check_expr.checkAs(c, x, v.elem));
            if (elems.len != v.len) {
                try c.report(n, .E0310, "expected {d} elements for `{s}`, found {d}", .{ v.len, try c.tyName(want), elems.len });
                return .err;
            }
            return e.finish(c, want, .{ .aggregate = .{ .elems = e.refs } });
        },
        .tuple => |t| if (t.elems.len == elems.len) {
            for (elems, t.elems, 0..) |x, ty, i| e.set(i, try check_expr.checkAs(c, x, ty));
            return e.finish(c, want, .{ .aggregate = .{ .elems = e.refs } });
        },
        else => {},
    };
    const tys = try c.arena.alloc(TypeId, elems.len);
    for (elems, tys, 0..) |x, *ty, i| {
        const v = try c.materialize(try check_expr.check(c, x, .none), x);
        ty.* = v.ty;
        e.set(i, v);
    }
    if (e.early()) |v| return v;
    return e.finish(c, try c.types.intern(.{ .tuple = .{ .elems = tys } }), .{ .aggregate = .{ .elems = e.refs } });
}

// ---------------------------------------------------------------------------
// Arrays (§6.2.4)

/// The element type an expected `[N]T` or `[]T` asks for, or `.none`.
fn expectedElem(c: *Checker, expected: TypeId) TypeId {
    const want = unwrapOption(c, expected);
    if (want == .none or want == .err) return .none;
    return switch (c.types.get(want)) {
        .array => |a| a.elem,
        .slice => |s| s.elem,
        else => .none,
    };
}

/// `[a, b, c]`: `[3]T`, `T` the expected element type or else the type of `a`.
pub fn arrayLit(c: *Checker, n: Node.Index, expected: TypeId) Error!Typed {
    const elems = c.ast.data(n).array_lit.elems;
    var elem = expectedElem(c, expected);
    if (elems.len == 0 and elem == .none) {
        try c.report(n, null, "empty array literal without an expected type", .{});
        return .err;
    }
    var e: Elems = try .init(c, elems.len);
    for (elems, 0..) |x, i| {
        if (elem == .none) {
            const v = try c.materialize(try check_expr.check(c, x, .none), x);
            elem = v.ty;
            e.set(i, v);
        } else e.set(i, try check_expr.checkAs(c, x, elem));
    }
    if (e.early()) |v| return v;
    const ty = try c.types.intern(.{ .array = .{ .len = elems.len, .elem = elem } });
    return e.finish(c, ty, .{ .aggregate = .{ .elems = e.refs } });
}

/// `[v; N]`: `N` copies of the plain value `v`; `N` is comptime.
pub fn arrayRepeat(c: *Checker, n: Node.Index, expected: TypeId) Error!Typed {
    const d = c.ast.data(n).array_repeat;
    const elem = expectedElem(c, expected);
    const v = if (elem == .none)
        try c.materialize(try check_expr.check(c, d.value, .none), d.value)
    else
        try check_expr.checkAs(c, d.value, elem);
    const before = c.sink.diags.items.len;
    const len = try c.items.arrayLen(c.m, d.count, c.self_ty) orelse {
        if (c.sink.diags.items.len > before) {
            c.failed = true; // reported by folding
            return .err;
        }
        if ((try check_expr.check(c, d.count, .usize)).ty == .err) return .err;
        // Folding skips what it cannot fold (a runtime local); the evaluator
        // reports it (E0801), or has recorded the count as unsupported.
        if (@import("comptime_ctx.zig").of(c.items)) |cx| if (try cx.eval(c.items, c.m, d.count, .usize) == null) {
            c.failed = true;
            return .err;
        };
        return c.unsupported(d.count, "repeat counts the comptime evaluator could not compute");
    };
    if (v.ty == .err or v.ty == .noreturn) return v;
    if (try check_stmt.isResource(c, v.ty)) {
        try c.report(d.value, .E0325, "`[v; N]` repeats a resource of type `{s}`; it needs a plain value", .{try c.tyName(v.ty)});
        return .err;
    }
    const ty = try c.types.intern(.{ .array = .{ .len = len, .elem = v.ty } });
    return .{ .ty = ty, .ref = try c.emit(ty, .{ .repeat = .{ .value = v.ref } }) };
}

// ---------------------------------------------------------------------------
// Inferred members (§6.2.3)

/// `.name`.
pub fn inferredMember(c: *Checker, n: Node.Index, expected: TypeId) Error!Typed {
    return member(c, n, n, null, expected);
}

/// `.name(args)`: call node `n` whose callee is an `inferred_member`.
pub fn inferredCall(c: *Checker, n: Node.Index, expected: TypeId) Error!Typed {
    const d = c.ast.data(n).call;
    return member(c, n, d.callee, d.args, expected);
}

fn member(c: *Checker, at: Node.Index, name_node: Node.Index, args: ?[]const Node.Index, expected: TypeId) Error!Typed {
    const name = c.ast.tokenSlice(c.ast.mainToken(name_node));
    if (expected == .err) {
        c.failed = true;
        return .err;
    }
    if (expected == .none) {
        try c.report(name_node, .E0353, "cannot infer the type of `.{s}`: there is no expected type", .{name});
        return .err;
    }
    if (try lookup(c, at, name, args, expected)) |v| return v;
    if (convert.optionPayload(c.types, expected)) |u| if (try lookup(c, at, name, args, u)) |v| {
        return if (v.ty == u) wrapSome(c, v, expected, at) else v;
    };
    try c.report(name_node, .E0353, "no member `.{s}` in `{s}`", .{ name, try c.tyName(expected) });
    return .err;
}

/// Member `name` of `ty` in the order of §6.2.3 (a variant, a `const` of
/// type `ty`, a function returning `ty`), applied to `args`; null if none.
fn lookup(c: *Checker, at: Node.Index, name: []const u8, args: ?[]const Node.Index, ty: TypeId) Error!?Typed {
    const nm = switch (c.types.get(ty)) {
        .nominal => |x| x,
        else => return null,
    };
    if (nm.lang == .option or nm.lang == .result) {
        // `Option<T> { some(T), none }`, `Result<T, E> { ok(T), err(E) }` (§14.1).
        const names: [2][]const u8 = if (nm.lang == .option) .{ "some", "none" } else .{ "ok", "err" };
        for (names, 0..) |vn, i| if (std.mem.eql(u8, vn, name)) {
            const payload: []const TypeId = if (i < nm.args.len and nm.args[i] == .type) &.{nm.args[i].type} else &.{};
            return try variant(c, at, name, ty, @intCast(i), payload, args);
        };
        return null;
    }
    const ref = c.items.declRef(ty) orelse return c.unsupported(at, "members of standard library types (T163)");
    const consts: []const items_mod.Const, const methods: []const items_mod.Fn = switch ((try c.items.info(ref)).*) {
        .@"struct" => |s| .{ s.consts, s.methods },
        .@"enum" => |e| blk: {
            for (e.variants, 0..) |v, i| if (std.mem.eql(u8, v.name, name)) {
                if (e.generics.len > 0) return c.unsupported(at, "variants of generic enums (T064)");
                return try variant(c, at, name, ty, @intCast(i), v.payload, args);
            };
            break :blk .{ e.consts, e.methods };
        },
        else => return null,
    };
    // Members are visible subject to their own `pub` (§7.9, §7.1).
    const outside = ref.module != c.m;
    if (args == null) for (consts) |k| if (k.type == ty and (k.is_pub or !outside) and std.mem.eql(u8, k.name, name)) {
        return try check_expr.constValue(c, at, k);
    };
    if (args) |a| for (methods) |f| {
        const has_self = f.params.len > 0 and f.params[0].is_self;
        if (!has_self and (f.is_pub or !outside) and returnsSelf(c, f.ret, ty) and std.mem.eql(u8, f.name, name))
            return try check_call.callFn(c, at, ref.module, f, null, a);
    };
    return null;
}

/// `ret` is `ty`, `Option<ty>` or `Result<ty, E>`.
fn returnsSelf(c: *Checker, ret: TypeId, ty: TypeId) bool {
    if (ret == ty) return true;
    if (ret == .err or ret == .none) return false;
    return switch (c.types.get(ret)) {
        .nominal => |nm| (nm.lang == .option or nm.lang == .result) and nm.args.len > 0 and nm.args[0] == .type and nm.args[0].type == ty,
        else => false,
    };
}

/// Variant `index` (named `name`) of enum `ty` with `payload` types, given
/// `args` (null without parentheses).
pub fn variant(c: *Checker, at: Node.Index, name: []const u8, ty: TypeId, index: u32, payload: []const TypeId, args: ?[]const Node.Index) Error!Typed {
    const given = args orelse &.{};
    // A `void` payload is written `.ok()` (§4.2.4); a void value has no operand.
    const void_payload = args != null and given.len == 0 and payload.len == 1 and payload[0] == .void;
    if (!void_payload and (given.len != payload.len or (args != null and payload.len == 0))) {
        try c.report(at, .E0310, "variant `.{s}` of `{s}` takes {d} value(s), found {d}", .{ name, try c.tyName(ty), payload.len, given.len });
        for (given) |a| _ = try check_expr.check(c, a, .none);
        return .err;
    }
    var e: Elems = try .init(c, given.len);
    for (given, payload[0..given.len], 0..) |a, p, i| e.set(i, try argument(c, at, a, p));
    return e.finish(c, ty, .{ .variant = .{ .variant = index, .payload = e.refs } });
}

/// A plain positional argument `a` converted to `to`.
fn argument(c: *Checker, at: Node.Index, a: Node.Index, to: TypeId) Error!Typed {
    const kind = c.ast.kind(a);
    if (kind == .named_arg or kind == .mut_arg) return c.unsupported(at, "argument modes and named arguments (T047)");
    return check_expr.checkAs(c, a, to);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const Fixture = emit_tir.Fixture;

/// The ops of function `name` in emission order.
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

test "struct literals: all fields, shorthand, `..` defaults, nested anonymous literals" {
    var f: Fixture = undefined;
    try f.init(
        \\pub struct Player {
        \\    pub mut health: u8 = 100,
        \\    pub mut speed: f32 = 5.0,
        \\    pub mut name_id: u32,
        \\}
        \\struct Point { x: i32, y: i32 }
        \\struct Segment { a: Point, b: Point }
        \\fn origin() -> Point { .{ x: 0, y: 0 } }
        \\fn make(x: i32) -> Segment {
        \\    let a = Player { health: 90, speed: 4.0, name_id: 1 };
        \\    let b = Player { health: 80, name_id: 2, .. };
        \\    let c: Player = .{ name_id: 3, .. };
        \\    let p = Point { y: 2, x };
        \\    Segment { a: .{ x: 0, y: 0 }, b: p }
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    try f.expectDump("origin",
        \\fn origin() -> Point {
        \\b0:
        \\  %0: i32 = int 0
        \\  %1: i32 = int 0
        \\  %2: Point = aggregate [%0, %1]
        \\  ret %2
        \\}
        \\
    );
    try expectOps(&f, "make", &.{ .aggregate, .aggregate, .aggregate, .aggregate, .aggregate, .aggregate });
}

test "anonymous literals: a bare name is a shorthand field unless a tuple or `vec` is expected" {
    var f: Fixture = undefined;
    try f.init(
        \\struct P { x: i32, y: i32 }
        \\fn both(x: i32, y: i32) -> P { .{ x, y } }
        \\fn mixed(x: i32) -> P { .{ x, y: 1 } }
        \\fn pair(x: i32, y: i32) -> (i32, i32) { .{ x, y } }
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    try expectOps(&f, "both", &.{.aggregate});
    try expectOps(&f, "mixed", &.{.aggregate});
    try expectOps(&f, "pair", &.{.aggregate});
}

test "a call or literal left of an operator, typed by the right, is unsupported" {
    var f: Fixture = undefined;
    try f.init(
        \\struct P { n: u32, pub fn init() -> P { P { n: 0 } } }
        \\fn eq(p: P) -> bool { .init() == p }
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    try testing.expectEqualStrings("a call or literal typed by the right operand (a later task)", f.bodies.unsupported.?.what);
}

test "struct literal errors: E0340, E0351, unknown field, E0350, E0310" {
    var f: Fixture = undefined;
    try f.init(
        \\pub struct Player {
        \\    pub mut health: u8 = 100,
        \\    pub mut speed: f32 = 5.0,
        \\    pub mut name_id: u32,
        \\}
        \\enum Color { red }
        \\fn make() {
        \\    let a = Player { name_id: 1 };
        \\    let b = Player { health: 80, .. };
        \\    let c = Player { name_id: 1, name_id: 2, .. };
        \\    let d = Player { name_id: 1, mana: 2, .. };
        \\    let e = .{ x: 1, y: 2 };
        \\    let g: u32 = .{ x: 1 };
        \\    let h: Player = .{ name_id: true, .. };
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{
        .{ .E0340, "Player" }, .{ .E0340, "Player" }, .{ .E0351, "name_id" }, .{ null, "mana" },
        .{ .E0350, ".{" },     .{ .E0310, ".{" },     .{ .E0310, "true" },
    });
}

test "E0352: construction outside the defining module" {
    var f: Fixture = undefined;
    try f.initPackage(&.{
        .{
            "a",
            \\use geo.{Port, Endpoint, Open};
            \\fn make() {
            \\    let p = Port { value: 1 };
            \\    let e = Endpoint { host_id: 1, .. };
            \\    let r = Endpoint { host_id: 1, retries: 2, .. };
            \\    let o: Open = .{ x: 1 };
            \\    let u: Port = .unchecked(5);
            \\}
        },
        .{
            "geo",
            \\pub struct Port { pub value: u16, fn unchecked(v: u16) -> Port { Port { value: v } } }
            \\pub struct Endpoint { pub mut host_id: u32, pub mut port: u16 = 80, retries: u8 = 3 }
            \\pub struct Open { pub mut x: u32 }
            \\pub fn inside() -> Port { .unchecked(1) }
        },
    });
    defer f.deinit();
    // A private constructor is not a visible member outside its module (§7.9).
    try f.expectDiags(&.{ .{ .E0352, "Port" }, .{ .E0352, "retries" }, .{ .E0353, "unchecked" } });
}

test "inferred members: variants, consts, constructors, binary operands, Option" {
    var f: Fixture = undefined;
    try f.init(
        \\enum GameState { idle, playing }
        \\enum Shape { dot, circle(f32), blank(void) }
        \\struct Pool {
        \\    n: u32,
        \\    pub fn init() -> Pool { Pool { n: 0 } }
        \\    pub fn try_make(n: u32) -> Option<Pool> { .some(Pool { n }) }
        \\}
        \\struct Unit {
        \\    pub const ONE: Unit = Unit {};
        \\}
        \\fn states(state: GameState) -> bool {
        \\    let s: GameState = .playing;
        \\    let c: Shape = .circle(1.0);
        \\    let p: Pool = .init();
        \\    let q: Option<Pool> = .try_make(2);
        \\    let b: Shape = .blank();
        \\    .playing == state && s == .idle
        \\}
        \\fn options() -> Option<GameState> {
        \\    let none: Option<u32> = .none;
        \\    let some: Option<u32> = .some(1);
        \\    let wrapped: Option<u32> = 5;
        \\    let pool: Option<Pool> = .init();
        \\    let lit: Option<Pool> = .{ n: 1 };
        \\    .idle
        \\}
        \\fn results() -> Result<u32, GameState> { .err(.idle) }
        \\fn done() -> Result<void, u32> { .ok() }
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    try expectOps(&f, "states", &.{ .variant, .variant, .call, .call, .variant, .variant, .eq, .variant, .eq });
    try expectOps(&f, "options", &.{ .variant, .variant, .variant, .call, .variant, .aggregate, .variant, .variant, .variant });
    try expectOps(&f, "results", &.{ .variant, .variant });
    try expectOps(&f, "done", &.{.variant});
    // The `const` of struct type is left to the comptime evaluator.
    var g: Fixture = undefined;
    try g.init(
        \\struct Unit { pub const ONE: Unit = Unit {}; }
        \\fn one() -> Unit { .ONE }
    );
    defer g.deinit();
    try g.expectDiags(&.{});
    try testing.expectEqual(null, g.bodies.find(0, "one").?.func);
}

test "E0353: no expected type, no such member" {
    var f: Fixture = undefined;
    try f.init(
        \\enum GameState { idle, playing }
        \\enum Shape { dot, circle(f32) }
        \\fn make() {
        \\    let s: GameState = .paused;
        \\    let n = .idle;
        \\    let c: u32 = .zero;
        \\    let o: Option<GameState> = .paused;
        \\    let bad: Shape = .circle;
        \\    let bad2: Shape = .dot(1);
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{
        .{ .E0353, "paused" }, .{ .E0353, "idle" }, .{ .E0353, "zero" }, .{ .E0353, "paused" },
        .{ .E0310, "circle" }, .{ .E0310, "(" },
    });
}

test "arrays, repeats and tuples" {
    var f: Fixture = undefined;
    try f.init(
        \\const N = 3;
        \\fn make(x: f32) -> (u8, f32) {
        \\    let a = [1, 2, 3];
        \\    let b: [3]u8 = [1, 2, 3];
        \\    let e: [0]u8 = [];
        \\    let r = [0u16; 4];
        \\    let s: [N]f32 = [x; N];
        \\    let t = (1, x);
        \\    let v: vec<2, f32> = .{ 1.0, x };
        \\    let p = .{ 1, 2.0 };
        \\    (7, x)
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    try expectOps(&f, "make", &.{ .aggregate, .aggregate, .aggregate, .repeat, .repeat, .aggregate, .aggregate, .aggregate, .aggregate });
    const func = try f.func("make");
    const ret = func.data(func.terminator(.from(0))).ret.value.?;
    const name = try f.types.allocPrint(testing.allocator, func.typeOf(ret), .{});
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("(u8, f32)", name);
}

test "array errors: element mismatch, empty without type, length, runtime count" {
    var f: Fixture = undefined;
    try f.init(
        \\fn make(n: usize) {
        \\    let a = [1, true];
        \\    let e = [];
        \\    let l: [2]u8 = [1, 2, 3];
        \\    let v: vec<2, f32> = .{ 1.0 };
        \\}
        \\fn count(n: usize) { let r = [0; n]; }
    );
    defer f.deinit();
    try f.expectDiags(&.{ .{ .E0310, "true" }, .{ null, "[" }, .{ .E0310, "[" }, .{ .E0310, ".{" } });
    try testing.expectEqualStrings("repeat counts the comptime evaluator could not compute", f.bodies.unsupported.?.what);
}
