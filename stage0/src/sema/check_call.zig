//! Calls and function values (§6.9, §6.12.7, §7.2.3-§7.2.5, §5.5.2, §4.6).
//!
//! - `call` checks `f(args)`: a direct call of a named function, or a call
//!   through a function-pointer value. Positional arguments bind in order,
//!   then named ones by name (E0374 for a positional argument after a named
//!   one or a parameter given twice); missing parameters take their defaults
//!   (§7.2.3), emitted after the explicit arguments in parameter order. The
//!   TIR arguments are in parameter order: `view_mut` of the place for a
//!   `mut` parameter, `view` of a resource place for a read-only one, else
//!   the value.
//! - Parameter modes at the call site (§5.5.2): E0334 for a missing `mut`
//!   marker, E0335 for an extra one, E0336 for a `mut` argument that is not
//!   a mutable place, E0801 for a `comptime` argument that is not
//!   comptime-known (`Items.runtimeRef`: no runtime name in it). A call
//!   with `comptime` arguments calls their instantiation
//!   (`comptime/instantiate.zig`).
//! - `fnValue` gives a named non-generic function as an `fn(...) -> R`
//!   value; named and default arguments do not apply through it (§7.2.5).
//! - `checkSignature` checks parameter declarations: E0339 for a `mut T`
//!   parameter type (§4.5.3), E0326 for `move` on a concrete plain type.
//!
//! - `callFn` calls a declared function, optionally with an already passed
//!   receiver for its first parameter; method calls (`check_member.zig`)
//!   bind through it.
//!
//! Generic calls are T068's.

const std = @import("std");
const Ast = @import("../ast/Ast.zig");
const Types = @import("types.zig");
const items_mod = @import("items.zig");
const kinds = @import("kinds.zig");
const emit_tir = @import("emit_tir.zig");
const check_expr = @import("check_expr.zig");
const check_literals = @import("check_literals.zig");
const mutability = @import("mutability.zig");
const builtins = @import("builtins.zig");
const check_member = @import("check_member.zig");
const check_stmt = @import("check_stmt.zig");
const builtins_expr = @import("builtins_expr.zig");
const unsafe = @import("unsafe.zig");
const tir = @import("../tir/tir.zig");
const module_graph = @import("../resolve/module_graph.zig");
const Ref = @import("../resolve/imports.zig").Ref;
const instantiate = @import("../comptime/instantiate.zig");

const Node = Ast.Node;
const TypeId = Types.TypeId;
const Checker = emit_tir.Checker;
const Typed = emit_tir.Typed;
const Error = emit_tir.Error;
const Mode = items_mod.Mode;

/// A parameter as a call binds it: from a declaration, or unnamed and
/// without default from a function-pointer type.
const Param = struct {
    name: ?[]const u8 = null,
    mode: Mode,
    type: TypeId,
    default: ?items_mod.Value = null,
};

/// `f(args)` (§6.9).
pub fn call(c: *Checker, n: Node.Index, expected: TypeId) Error!Typed {
    const d = c.ast.data(n).call;
    switch (c.ast.kind(d.callee)) {
        .inferred_member => return check_literals.inferredCall(c, n, expected),
        .ident, .field_access => {
            // A `field_access` is a module member (`geo.area`) or a method.
            const e = c.items.names.get(c.m, d.callee) orelse
                return if (c.ast.kind(d.callee) == .field_access) check_member.call(c, n, expected) else failedCall(c, d);
            switch (e.res) {
                .global => |t| switch (t) {
                    .item => |ref| return direct(c, n, d, ref),
                    .unresolved => return failedCall(c, d),
                    .prelude => |p| return (try builtins.callIntrinsic(c, n, p)) orelse
                        (try builtins_expr.vecCtor(c, n, p, expected)) orelse
                        c.unsupported(n, "prelude functions (T105)"),
                    .external => return c.unsupported(n, "calls of standard library functions (T163)"),
                    .module => {}, // not a value: reported by the callee
                },
                .local => {}, // a function-pointer value
            }
        },
        else => {},
    }
    return indirect(c, n, d);
}

/// A call of item `ref` by name.
fn direct(c: *Checker, n: Node.Index, d: @FieldType(Ast.Data, "call"), ref: Ref) Error!Typed {
    const sig = switch ((try c.items.info(ref)).*) {
        .@"fn" => |f| f,
        else => return c.unsupported(n, "calls of this form (T046, T065)"),
    };
    const item = c.items.im.graph.modules[ref.module].items[ref.item];
    if (item.kind == .extern_fn) try unsafe.callee(c, d.callee, c.items.im.graph.modules[ref.module].ast, sig, true);
    return callFn(c, n, ref.module, sig, null, d.args);
}

/// Call `n` of function `sig` declared in module `m` with `args`. A
/// `recv`, already passed by the caller, is the first argument (§6.3.3)
/// and `args` bind to the other parameters. An `extern` callee is gated
/// by the caller; an `@unsafe` one here (§12.1).
pub fn callFn(c: *Checker, n: Node.Index, m: module_graph.ModuleId, sig: items_mod.Fn, recv: ?Typed, args: []const Node.Index) Error!Typed {
    if (items_mod.hasAttr(c.items.im.graph.modules[m].ast, sig.attrs, .unsafe))
        try unsafe.callee(c, c.ast.data(n).call.callee, c.items.im.graph.modules[m].ast, sig, false);
    if (sig.generics.len > 0) return c.unsupported(n, "generic calls (T068)");
    const skip = @intFromBool(recv != null);
    const has_comptime = for (sig.params[skip..]) |p| {
        if (p.mode == .@"comptime") break true;
    } else false;
    // A call with `comptime` arguments calls their instantiation (§8.2).
    const inst = if (has_comptime) try instantiate.instance(c, n, m, sig, skip, args) else null;
    const f = if (inst) |i| i.sig else sig;
    if (f.ret == .err) c.failed = true;
    const params = try c.arena.alloc(Param, f.params.len - skip);
    for (f.params[skip..], params) |p, *o| o.* = .{ .name = p.name, .mode = p.mode, .type = p.type, .default = p.default };
    var b = try bind(c, n, c.ast.data(n).call.callee, args, params, true);
    if (recv) |r| {
        b.args = try std.mem.concat(c.arena, tir.Ref, &.{ &.{r.ref}, b.args });
        b.ok = b.ok and r.ty != .err;
        b.diverges = b.diverges or r.ty == .noreturn;
    }
    if (has_comptime) {
        const i = inst orelse {
            c.failed = true; // reported or recorded
            return .err;
        };
        // The instance takes the runtime arguments only.
        var len: usize = 0;
        for (f.params, b.args) |p, a| if (p.mode != .@"comptime") {
            b.args[len] = a;
            len += 1;
        };
        b.args = b.args[0..len];
        return finish(c, f.ret, b, .{ .call = .{ .callee = i.id, .args = b.args } });
    }
    const id = try c.bodies.fnId(m, sig.node, sig.name);
    return finish(c, sig.ret, b, .{ .call = .{ .callee = id, .args = b.args } });
}

/// A call through a function-pointer value (§4.6): no named or default
/// arguments (§7.2.5).
fn indirect(c: *Checker, n: Node.Index, d: @FieldType(Ast.Data, "call")) Error!Typed {
    const f = try check_expr.check(c, d.callee, .none);
    if (f.ty == .err or f.ty == .noreturn) {
        for (d.args) |a| _ = try check_expr.check(c, unwrapArg(c.ast, a), .none);
        return if (f.ty == .err) .err else .never;
    }
    const fp = switch (c.types.get(c.underlying(f.ty))) {
        .fn_ptr => |x| x,
        else => {
            try c.report(d.callee, .E0310, "a value of type `{s}` cannot be called", .{try c.tyName(f.ty)});
            return failedArgs(c, d.args);
        },
    };
    const params = try c.arena.alloc(Param, fp.params.len);
    for (fp.params, params) |p, *o| o.* = .{ .type = p.type, .mode = switch (p.mode) {
        .value => .value,
        .mut => .mut,
        .move => .move,
    } };
    if (fp.ret == .err) c.failed = true;
    const b = try bind(c, n, d.callee, d.args, params, false);
    return finish(c, fp.ret, b, .{ .call_indirect = .{ .callee = f.ref, .args = b.args } });
}

/// Bound arguments in parameter order.
const Bound = struct { args: []tir.Ref, ok: bool, diverges: bool };

/// Binds and checks `args` of the call of `callee` against `params` (§6.9, §7.2.4): explicit
/// arguments left to right in source order, then the missing parameters'
/// defaults in parameter order (§6.12.7). `named_ok` is false through a
/// function pointer.
fn bind(c: *Checker, n: Node.Index, callee: Node.Index, args: []const Node.Index, params: []const Param, named_ok: bool) Error!Bound {
    const ast = c.ast;
    var b: Bound = .{ .args = try c.arena.alloc(tir.Ref, params.len), .ok = true, .diverges = false };
    const given = try c.arena.alloc(bool, params.len);
    @memset(given, false);
    var next: usize = 0;
    var named = false;
    for (args) |a| {
        const value = unwrapArg(ast, a);
        const i: ?usize = if (ast.kind(a) == .named_arg) blk: {
            named = true;
            const name = ast.tokenSlice(ast.mainToken(a));
            if (!named_ok) {
                try c.reportAt(ast.mainToken(a), null, &.{"function pointers have no parameter names; pass the arguments by position"}, "named argument `{s}` in a call through a function pointer", .{name});
                break :blk null;
            }
            const i = for (params, 0..) |p, i| {
                if (std.mem.eql(u8, p.name.?, name)) break i;
            } else {
                try c.reportAt(ast.mainToken(a), null, &.{}, "`{s}` has no parameter named `{s}`", .{ ast.tokenSlice(ast.mainToken(callee)), name });
                break :blk null;
            };
            if (given[i]) {
                try c.reportAt(ast.mainToken(a), .E0374, &.{"each parameter is given at most once"}, "parameter `{s}` is given more than once", .{name});
                break :blk null;
            }
            break :blk i;
        } else if (named) blk: {
            try c.reportAt(firstToken(ast, a), .E0374, &.{"after the first named argument, every argument must be named"}, "positional argument after a named argument", .{});
            break :blk null;
        } else if (next < params.len) blk: {
            next += 1;
            break :blk next - 1;
        } else blk: {
            try c.reportAt(firstToken(ast, a), null, &.{}, "too many arguments: the callee takes {d}", .{params.len});
            break :blk null;
        };
        const pi = i orelse {
            b.ok = false;
            _ = try check_expr.check(c, value, .none);
            continue;
        };
        given[pi] = true;
        const v = try arg(c, if (ast.kind(a) == .named_arg) ast.data(a).named_arg.value else a, params[pi]);
        b.ok = b.ok and v.ty != .err;
        b.diverges = b.diverges or v.ty == .noreturn;
        b.args[pi] = v.ref;
    }
    for (params, given, b.args) |p, g, *o| if (!g) {
        const def = p.default orelse {
            // After a binding error, a missing parameter is usually its consequence.
            if (!b.ok) {} else if (p.name) |name| {
                try c.report(callee, null, "missing argument for parameter `{s}`", .{name});
            } else try c.report(callee, null, "missing arguments: the function pointer takes {d}", .{params.len});
            b.ok = false;
            continue;
        };
        const v = try defaultArg(c, n, def, p.type);
        b.ok = b.ok and v.ty != .err;
        o.* = v.ref;
    };
    return b;
}

/// The value of a `named_arg` or `mut_arg` argument, or the argument itself.
pub fn unwrapArg(ast: *const Ast, a: Node.Index) Node.Index {
    var x = a;
    if (ast.kind(x) == .named_arg) x = ast.data(x).named_arg.value;
    if (ast.kind(x) == .mut_arg) x = ast.data(x).mut_arg.value;
    return x;
}

/// Argument `a` (a `mut_arg` or an expression) for parameter `p` (§5.5.2).
fn arg(c: *Checker, a: Node.Index, p: Param) Error!Typed {
    const ast = c.ast;
    const marked = ast.kind(a) == .mut_arg;
    const value = if (marked) ast.data(a).mut_arg.value else a;
    if (p.mode == .mut) {
        if (!marked) {
            try c.reportAt(firstToken(ast, value), .E0334, &.{"write `mut` before the argument: the callee may change it"}, "missing `mut` for `mut` parameter{s}", .{try paramName(c, p)});
            _ = try check_expr.check(c, value, .none);
            return .err;
        }
        const place = try mutability.mutArg(c, a, value) orelse return .err;
        if (place.ty == .noreturn) return .never;
        if (place.ty == .err or p.type == .err) return .err;
        if (place.ty != p.type) {
            try c.mismatch(value, p.type, place.ty);
            return .err;
        }
        const view = try c.types.intern(.{ .mut_view = .{ .elem = place.ty } });
        return .{ .ty = view, .ref = try c.emit(view, .{ .view_mut = .{ .place = place.ref } }) };
    }
    if (marked) try c.reportAt(ast.mainToken(a), .E0335, &.{"remove `mut`: the parameter is read-only"}, "`mut` given for read-only parameter{s}", .{try paramName(c, p)});
    if (p.mode == .@"comptime") if (c.items.runtimeRef(c.m, value)) |r| {
        try c.reportAt(ast.mainToken(r), .E0801, &.{"pass a literal, a `const`, a `comptime` parameter or a `comptime` expression"}, "argument for `comptime` parameter{s} is not comptime-known: `{s}` is a runtime value", .{ try paramName(c, p), ast.tokenSlice(ast.mainToken(r)) });
        _ = try check_expr.check(c, value, .none);
        return .err;
    } else return .void_value; // evaluated by the instantiation
    // A `move` argument needs the `move` prefix and ownership checks
    // (§5.5.2). A concrete plain `move` parameter is E0326 at its
    // declaration and its argument is checked as a copy.
    if (p.mode == .move and p.type != .err and (mentionsParam(c.types, p.type) or try kinds.kind(c.items, p.type) != .plain))
        return c.unsupported(value, "`move` arguments (T080)");
    // A resource or shared cell is passed to a read-only parameter as a
    // view of its place, not copied (§5.5.2, §5.1).
    const kind: kinds.Kind = if (p.mode == .value and p.type != .err) try kinds.kind(c.items, p.type) else .plain;
    if (kind == .resource or kind == .shared_cell) {
        if (localOf(c, value)) |l| {
            const ty = c.b.locals.items(.ty)[l.int()];
            if (ty != p.type) {
                if (ty != .err) try c.mismatch(value, p.type, ty);
                c.failed = true;
                return .err;
            }
            const place = try c.emit(ty, .{ .local = .{ .local = l } });
            return .{ .ty = ty, .ref = try c.emit(ty, .{ .view = .{ .place = place } }) };
        }
    }
    c.comp_dest = value;
    const v = try check_expr.checkAs(c, value, p.type);
    if (marked and v.ty != .noreturn) return .err;
    return v;
}

/// " `name`" for a declared parameter, "" through a function pointer.
fn paramName(c: *Checker, p: Param) Error![]const u8 {
    return if (p.name) |name| std.fmt.allocPrint(c.arena, " `{s}`", .{name}) else "";
}

/// The local that place expression `n` names (a binding, a parameter or
/// `self`, possibly parenthesized), or null.
pub fn localOf(c: *Checker, n: Node.Index) ?tir.Local {
    switch (c.ast.kind(n)) {
        .paren => return localOf(c, c.ast.data(n).paren.inner),
        .self_value => return c.self_local.unwrap(),
        .ident => {
            const e = c.items.names.get(c.m, n) orelse return null;
            return switch (e.res) {
                .local => |l| switch (c.ast.kind(l)) {
                    .pat_bind, .pat_bind_mut, .field_pat, .field_pat_mut, .param => c.locals.get(l),
                    else => null,
                },
                .global => null,
            };
        },
        else => return null,
    }
}

/// Default value `v` of a parameter of type `ty` at call `n` (§7.2.3).
fn defaultArg(c: *Checker, n: Node.Index, v: items_mod.Value, ty: TypeId) Error!Typed {
    return switch (v) {
        .untyped => |k| c.constTo(k, ty, n),
        .scalar => |s| c.constant(s),
        .type => c.unsupported(n, "types as values (T065)"),
        .computed => |cv| @import("comptime_ctx.zig").use(c, n, cv),
        .unknown => if (ty == .err) blk: {
            c.failed = true; // reported with the default
            break :blk .err;
        } else c.unsupported(n, "values the comptime evaluator could not compute"),
    };
}

/// Emits call `data` returning `ret` once its arguments `b` are checked.
fn finish(c: *Checker, ret: TypeId, b: Bound, data: tir.Data) Error!Typed {
    if (!b.ok) return .err;
    if (b.diverges) return .never;
    const r = try c.emit(ret, data);
    if (ret == .noreturn) {
        _ = try c.emit(.void, .{ .@"unreachable" = .{} });
        return .never;
    }
    return .{ .ty = ret, .ref = r };
}

/// A call whose callee is unknown or unresolved: the callee reports (or
/// records) why, and the arguments are still checked for their own errors.
fn failedCall(c: *Checker, d: @FieldType(Ast.Data, "call")) Error!Typed {
    _ = try check_expr.check(c, d.callee, .none);
    return failedArgs(c, d.args);
}

/// Checks the arguments of a call that failed, for their own errors.
pub fn failedArgs(c: *Checker, args: []const Node.Index) Error!Typed {
    for (args) |a| _ = try check_expr.check(c, unwrapArg(c.ast, a), .none);
    return .err;
}

/// The first token of argument `a`, to report it at its start.
fn firstToken(ast: *const Ast, a: Node.Index) Ast.TokenIndex {
    var x = a;
    while (true) switch (ast.kind(x)) {
        .call => x = ast.data(x).call.callee,
        .field_access => x = ast.data(x).field_access.lhs,
        .index => x = ast.data(x).index.lhs,
        else => return ast.mainToken(x),
    };
}

// ---------------------------------------------------------------------------
// Function values

/// Function item `ref` named at `n` without a call: an `fn(...) -> R` value
/// (§7.2.5, §4.6).
pub fn fnValue(c: *Checker, n: Node.Index, ref: Ref) Error!Typed {
    const item = c.items.im.graph.modules[ref.module].items[ref.item];
    const sig = switch ((try c.items.info(ref)).*) {
        .@"fn" => |f| f,
        else => {
            c.failed = true; // a declaration cycle, reported with the item
            return .err;
        },
    };
    if (item.kind == .extern_fn) {
        try c.reportAt(c.ast.mainToken(n), null, &.{"`fn` pointers use the Pyro calling convention; wrap the call in a Pyro function"}, "`extern` function `{s}` cannot be used as a value", .{item.name});
        return .err;
    }
    return fnOf(c, n, ref.module, sig);
}

/// Function `sig` of module `m` (an item or a member function) named at
/// `n` without a call: an `fn(...) -> R` value (§7.2.5).
pub fn fnOf(c: *Checker, n: Node.Index, m: module_graph.ModuleId, sig: items_mod.Fn) Error!Typed {
    if (sig.generics.len > 0) return c.unsupported(n, "instantiating generic functions (T068)");
    const params = try c.arena.alloc(Types.FnParam, sig.params.len);
    var bad = sig.ret == .err;
    for (sig.params, params) |p, *o| {
        bad = bad or p.type == .err;
        o.* = .{
            .type = p.type,
            .mode = switch (p.mode) {
                .value => .value,
                .mut => .mut,
                .move => .move,
                .@"comptime" => {
                    // An `fn` type has no `comptime` parameters (§4.6, §8.2).
                    try c.reportAt(c.ast.mainToken(n), null, &.{"call it with its `comptime` arguments instead"}, "`{s}` has `comptime` parameters and cannot be used as a value", .{sig.name});
                    return .err;
                },
            },
        };
    }
    if (bad) {
        c.failed = true; // reported with the signature
        return .err;
    }
    const ty = try c.types.intern(.{ .fn_ptr = .{ .params = params, .ret = sig.ret } });
    const id = try c.bodies.fnId(m, sig.node, sig.name);
    return .{ .ty = ty, .ref = try c.emit(ty, .{ .fn_ref = .{ .func = id } }) };
}

// ---------------------------------------------------------------------------
// Signatures

/// Checks the parameter declarations of `f` (module `m`): E0339 for a
/// `mut T` parameter type (§4.5.3), E0326 for `move` on a parameter whose
/// type is plain and mentions no generic parameter (§5.5.2).
pub fn checkSignature(it: *items_mod.Items, m: module_graph.ModuleId, f: items_mod.Fn) Error!void {
    const a = it.im.graph.modules[m].ast;
    for (f.params) |p| {
        if (p.type == .err) continue;
        if (it.types.get(p.type) == .mut_view) {
            const t = items_mod.typeToken(a, a.data(p.node).param.ty.?);
            try it.report(m, t, .E0339, &.{"declare a `mut` parameter instead: `mut p: T`"}, "`{s}` cannot be a parameter type", .{try it.tyName(p.type)});
        } else if (p.mode == .move and !mentionsParam(it.types, p.type) and (try kinds.kind(it, p.type)) == .plain) {
            try it.report(m, a.mainToken(p.node) - 1, .E0326, &.{"plain values are always copied; remove `move`"}, "`move` parameter `{s}` has plain type `{s}`", .{ p.name, try it.tyName(p.type) });
        }
    }
}

/// Whether `ty` mentions a generic type parameter.
fn mentionsParam(t: *Types, ty: TypeId) bool {
    return switch (t.get(ty)) {
        .param => true,
        inline .array, .soa_array, .slice, .soa_slice, .handle, .ptr, .mut_view => |x| mentionsParam(t, x.elem),
        .tuple => |x| for (x.elems) |e| {
            if (mentionsParam(t, e)) break true;
        } else false,
        .nominal => |x| for (x.args) |g| {
            if (g == .type and mentionsParam(t, g.type)) break true;
        } else false,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const Fixture = emit_tir.Fixture;
const diag = @import("../diag/diag.zig");

test "binding: positional, named, defaults; `spawn_actor(position: p, scale: 2.0)` binds" {
    var f: Fixture = undefined;
    try f.init(
        \\fn spawn_actor(position: f32, scale: f32 = 1.0, layer: u8 = 0) {}
        \\fn place(p: f32) {
        \\    spawn_actor(p);
        \\    spawn_actor(position: p, scale: 2.0);
        \\    spawn_actor(p, layer: 3);
        \\    spawn_actor(layer: 2, position: p);
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    try f.expectDump("place",
        \\fn place(l0 p: f32) -> void {
        \\b0:
        \\  %0: f32 = local l0
        \\  %1: f32 = load %0
        \\  %2: f32 = float 1
        \\  %3: u8 = int 0
        \\  call @0, [%1, %2, %3]
        \\  %5: f32 = local l0
        \\  %6: f32 = load %5
        \\  %7: f32 = float 2
        \\  %8: u8 = int 0
        \\  call @0, [%6, %7, %8]
        \\  %10: f32 = local l0
        \\  %11: f32 = load %10
        \\  %12: u8 = int 3
        \\  %13: f32 = float 1
        \\  call @0, [%11, %13, %12]
        \\  %15: u8 = int 2
        \\  %16: f32 = local l0
        \\  %17: f32 = load %16
        \\  %18: f32 = float 1
        \\  call @0, [%17, %18, %15]
        \\  ret _
        \\}
        \\
    );
}

test "E0374: positional after named, duplicates; unknown names and arity" {
    var f: Fixture = undefined;
    try f.init(
        \\fn spawn_actor(position: f32, scale: f32 = 1.0, layer: u8 = 0) {}
        \\fn place(p: f32) {
        \\    spawn_actor(scale: 2.0, p);
        \\    spawn_actor(p, scale: 2.0, scale: 3.0);
        \\    spawn_actor(p, position: p);
        \\    spawn_actor(p, size: 1.0);
        \\    spawn_actor(p, 1.0, 2, 3);
        \\    spawn_actor(scale: 1.0);
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{
        .{ .E0374, "p" },  .{ .E0374, "scale" }, .{ .E0374, "position" },
        .{ null, "size" }, .{ null, "3" },       .{ null, "spawn_actor" },
    });
}

test "modes: E0334, E0335; E0336 for values, E0337/E0338 for immutable roots; `view_mut` for `mut` arguments" {
    var f: Fixture = undefined;
    try f.init(
        \\const LIMIT: u8 = 9;
        \\fn heal(mut p: u8, amount: u8) { p += amount; }
        \\fn show(p: u8) -> u8 { p }
        \\fn make() -> u8 { 1 }
        \\fn good(mut p: u8) {
        \\    let mut q: u8 = 5;
        \\    heal(mut p, 1);
        \\    heal(mut q, 1);
        \\    heal(mut (q), show(1));
        \\}
        \\fn bad(p: u8) {
        \\    let q: u8 = 1;
        \\    heal(p, 10);
        \\    let x = show(mut p);
        \\    heal(mut make(), 1);
        \\    heal(mut LIMIT, 1);
        \\    heal(mut q, 1);
        \\    heal(mut p, 1);
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{
        .{ .E0334, "p" },   .{ .E0335, "mut" }, .{ .E0336, "mut" },
        .{ .E0336, "mut" }, .{ .E0337, "mut" }, .{ .E0338, "mut" },
    });
    try f.expectDump("good",
        \\fn good(l0 mut p: u8) -> void {
        \\  l1 mut q: u8
        \\b0:
        \\  %0: u8 = int 5
        \\  %1: u8 = local l1
        \\  store %1, %0
        \\  %3: u8 = local l0
        \\  %4: mut u8 = view_mut %3
        \\  %5: u8 = int 1
        \\  call @0, [%4, %5]
        \\  %7: u8 = local l1
        \\  %8: mut u8 = view_mut %7
        \\  %9: u8 = int 1
        \\  call @0, [%8, %9]
        \\  %11: u8 = local l1
        \\  %12: mut u8 = view_mut %11
        \\  %13: u8 = int 1
        \\  %14: u8 = call @1, [%13]
        \\  call @0, [%12, %14]
        \\  ret _
        \\}
        \\
    );
}

test "E0801: `comptime` arguments must be comptime-known" {
    var f: Fixture = undefined;
    try f.init(
        \\fn scale(comptime n: u32, x: u32) -> u32 { x * n }
        \\fn demo(count: u32) -> u32 { scale(count + 1, 1) }
    );
    defer f.deinit();
    try f.expectDiags(&.{.{ .E0801, "count" }});
}

test "function pointers: non-generic function as a value, indirect calls, named argument rejected" {
    var f: Fixture = undefined;
    try f.init(
        \\fn half(x: f32) -> f32 { x }
        \\fn apply(g: fn(f32) -> f32, v: f32) -> f32 { g(v) }
        \\fn demo() -> f32 {
        \\    let f: fn(f32) -> f32 = half;
        \\    apply(half, f(1.0))
        \\}
        \\fn bad(g: fn(f32) -> f32, n: u32) {
        \\    let a = g(x: 1.0);
        \\    let b = g();
        \\    let c = n(1);
        \\    let d: fn(u32) -> f32 = half;
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{ .{ null, "x" }, .{ null, "g" }, .{ .E0310, "n" }, .{ .E0310, "half" } });
    try f.expectDump("demo",
        \\fn demo() -> f32 {
        \\  l0 f: fn(f32) -> f32
        \\b0:
        \\  %0: fn(f32) -> f32 = fn_ref @0
        \\  %1: fn(f32) -> f32 = local l0
        \\  store %1, %0
        \\  %3: fn(f32) -> f32 = fn_ref @0
        \\  %4: fn(f32) -> f32 = local l0
        \\  %5: fn(f32) -> f32 = load %4
        \\  %6: f32 = float 1
        \\  %7: f32 = call_indirect %5, [%6]
        \\  %8: f32 = call @1, [%3, %7]
        \\  ret %8
        \\}
        \\
    );
}

test "signatures: E0339 `mut T` parameter type, E0326 `move` of a plain type" {
    var f: Fixture = undefined;
    try f.init(
        \\@resource
        \\struct File { fd: i32 }
        \\struct Point { x: f32 }
        \\fn heal(p: mut Point) {}
        \\fn consume(move n: u32) -> u32 { n }
        \\fn take(move p: Point) {}
        \\fn keep(move f: File) {}
        \\fn pass<T>(move x: T) -> T { x }
        \\fn modes(mut p: Point, move f: File) {}
    );
    defer f.deinit();
    try f.expectDiags(&.{ .{ .E0339, "mut" }, .{ .E0326, "move" }, .{ .E0326, "move" } });
}

test "resource arguments of read-only parameters are passed as views" {
    var f: Fixture = undefined;
    try f.init(
        \\@resource
        \\struct File { fd: i32 }
        \\fn size(f: File) -> u32 { 0 }
        \\fn demo(f: File) -> u32 { size(f) }
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    try f.expectDump("demo",
        \\fn demo(l0 f: File) -> u32 {
        \\b0:
        \\  %0: File = local l0
        \\  %1: File = view %0
        \\  %2: u32 = call @0, [%1]
        \\  ret %2
        \\}
        \\
    );
}

test "`move` arguments are unsupported until T080" {
    for ([_][]const u8{
        "fn demo(f: File) { keep(f); }",
        "fn demo(move f: File) { keep(f); }",
        "fn demo(g: fn(move File), f: File) { g(f); }",
    }) |body| {
        var f: Fixture = undefined;
        const src = try std.mem.concat(testing.allocator, u8, &.{ "@resource\nstruct File { fd: i32 }\nfn keep(move f: File) {}\n", body });
        defer testing.allocator.free(src);
        try f.init(src);
        defer f.deinit();
        try f.expectDiags(&.{});
        try testing.expectEqualStrings("`move` arguments (T080)", f.bodies.unsupported.?.what);
        try testing.expectEqual(null, f.bodies.find(0, "demo").?.func);
    }
}

test "`mut` arguments: parenthesized places, fields of mutable places; values are E0336, read-only parameters E0338" {
    for ([_]struct { []const u8, ?diag.DiagCode, ?[]const u8 }{
        .{ "heal(mut (p.health), 1);", null, null },
        .{ "heal(mut r.health, 1);", .E0338, null },
        .{ "heal(mut ((q)), 1);", null, null },
        .{ "heal(mut -q, 1);", .E0336, null },
        .{ "heal(mut (1), 1);", .E0336, null },
    }) |case| {
        var f: Fixture = undefined;
        const src = try std.mem.concat(testing.allocator, u8, &.{
            "struct P { health: u8 }\nfn heal(mut p: u8, amount: u8) { p += amount; }\nfn demo(mut p: P, r: P) {\n    let mut q: u8 = 1;\n    ",
            case[0],
            "\n}\n",
        });
        defer testing.allocator.free(src);
        try f.init(src);
        defer f.deinit();
        const ds = f.p.sink.finish();
        if (case[1]) |code| {
            try testing.expectEqual(1, ds.len);
            try testing.expectEqual(code, ds[0].code.?);
        } else try testing.expectEqual(0, ds.len);
        if (case[2]) |what| try testing.expectEqualStrings(what, f.bodies.unsupported.?.what) else try testing.expectEqual(null, f.bodies.unsupported);
    }
}
