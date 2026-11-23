//! Inference of generic function arguments (§7.6.3, §7.6.2, §4.8, §6.2.2,
//! §7.2.5).
//!
//! A generic function `fn f<T: B>(x: T)` is `fn f(comptime T: type, x: T)`
//! with `T` supplied by inference (§7.6.2). At a call `f(args)` each
//! generic parameter is inferred by unifying the parameter types with the
//! argument types, in source order:
//!
//! - every argument is checked once, left to right, before binding
//!   (`check_call.Param.pre`); its expected type is the parameter type
//!   with the parameters fixed so far substituted, or none while one is
//!   still open (an anonymous positional literal is then a tuple, §6.2.2).
//!   A resource local passed by view is not read here: its local's type is
//!   used;
//! - untyped constants unify only after typed arguments have fixed the
//!   parameter; a parameter fixed by untyped constants alone takes their
//!   default type (`i64`, `f64`, §4.8);
//! - a parameter that is still open is E0372: inference never uses the
//!   expected result type (§4.8). Such a parameter is written `comptime T:
//!   type` and passed (`instantiate.zig`).
//!
//! The instance is then made like an explicit instantiation of a generic
//! declaration (`generics.zig`): bounds are checked at the call (E0329 for
//! `plain`, E0373 for protocols), and the instance is looked up in, or
//! added to, the shared memo table under `generics.keyOf` of the
//! declaration and the arguments, so an inferred instance and one named
//! through an `fn` type share one entry. Its signature and body are checked
//! with the parameters bound (§7.6.4); the template body is never checked
//! (`emit_tir.checkDecl`).
//!
//! A generic function named without a call is instantiated from the
//! expected `fn` type (§7.2.5): `let f: fn(f32) -> f32 = clamp;`.

const std = @import("std");
const Ast = @import("../ast/Ast.zig");
const Types = @import("types.zig");
const items_mod = @import("items.zig");
const kinds = @import("kinds.zig");
const emit_tir = @import("emit_tir.zig");
const check_expr = @import("check_expr.zig");
const check_call = @import("check_call.zig");
const mutability = @import("mutability.zig");
const generics = @import("generics.zig");
const comptime_ctx = @import("comptime_ctx.zig");
const instantiate = @import("../comptime/instantiate.zig");
const tir = @import("../tir/tir.zig");
const ModuleId = @import("../resolve/module_graph.zig").ModuleId;

const Node = Ast.Node;
const TypeId = Types.TypeId;
const Checker = emit_tir.Checker;
const Typed = emit_tir.Typed;
const Error = emit_tir.Error;

/// Call `n` of generic function `sig` (module `m`) with `args`; `recv`,
/// already passed, is the first argument (§6.3.3). Calls the instance for
/// the inferred arguments (§7.6.3).
pub fn call(c: *Checker, n: Node.Index, m: ModuleId, sig: items_mod.Fn, recv: ?Typed, args: []const Node.Index) Error!Typed {
    const ast = c.ast;
    const skip = @intFromBool(recv != null);
    const own = sig.params[skip..];
    const params = try c.arena.alloc(check_call.Param, own.len);
    for (own, params) |p, *o| o.* = .{ .name = p.name, .mode = p.mode, .type = p.type, .default = p.default };
    const seen = try c.arena.alloc(bool, own.len);
    @memset(seen, false);
    const checked = try c.arena.alloc(bool, args.len);
    @memset(checked, false);
    var s: Infer = try .init(c, sig);
    var next: usize = 0;
    var named = false;
    for (args, checked) |a, *done| {
        const pi = paramIndex(ast, own, a, &next, &named) orelse continue;
        if (seen[pi]) continue; // given twice: binding reports it
        seen[pi] = true;
        try preArg(c, &s, a, &params[pi]);
        done.* = params[pi].pre != null;
    }
    s.defaults(params);
    // Diagnostics of the instantiation are at the callee's name.
    const callee = ast.data(n).call.callee;
    if (!try s.complete(c, callee, m, sig, "generic arguments are inferred from the argument types only (§7.6.3); a parameter that appears only in the result is declared `comptime T: type` and passed")) {
        // The other arguments are still checked for their own errors.
        for (args, checked) |a, done| if (!done) {
            _ = try check_expr.check(c, check_call.unwrapArg(ast, a), .none);
        };
        return .err;
    }
    const inst = try instance(c, callee, m, sig, try s.fixed(c)) orelse return .err;
    if (inst.sig.ret == .err) c.failed = true;
    for (inst.sig.params[skip..], params) |p, *o| {
        o.type = p.type;
        o.default = p.default;
    }
    var b = try check_call.bind(c, n, callee, args, params, true);
    if (recv) |r| {
        b.args = try std.mem.concat(c.arena, tir.Ref, &.{ &.{r.ref}, b.args });
        b.ok = b.ok and r.ty != .err;
        b.diverges = b.diverges or r.ty == .noreturn;
    }
    return check_call.finish(c, inst.sig.ret, b, .{ .call = .{ .callee = inst.id, .args = b.args } });
}

/// Generic function `sig` (module `m`) named at `n` without a call: its
/// instance for the `fn` type `expected` as a value (§7.2.5).
pub fn fnValue(c: *Checker, n: Node.Index, m: ModuleId, sig: items_mod.Fn, expected: TypeId) Error!Typed {
    var s: Infer = try .init(c, sig);
    if (expected != .none and expected != .err) switch (c.types.get(c.underlying(expected))) {
        .fn_ptr => |fp| if (fp.params.len == sig.params.len) {
            for (sig.params, fp.params) |p, q| s.unify(p.type, q.type);
            s.unify(sig.ret, fp.ret);
        },
        else => {},
    };
    if (!try s.complete(c, n, m, sig, "name it where an `fn` type is expected, as in `let f: fn(f32) -> f32 = clamp;` (§7.2.5)")) return .err;
    const inst = try instance(c, n, m, sig, try s.fixed(c)) orelse return .err;
    const ty = try check_call.fnType(c, n, inst.sig) orelse return .err;
    return .{ .ty = ty, .ref = try c.emit(ty, .{ .fn_ref = .{ .func = inst.id } }) };
}

// ---------------------------------------------------------------------------
// Unification

/// The generic arguments of one call while they are inferred.
const Infer = struct {
    types: *Types,
    /// The generic parameters, as `.param` types.
    gens: []const TypeId,
    /// The argument of each parameter; null while it is open.
    args: []?Types.Arg,

    fn init(c: *Checker, sig: items_mod.Fn) Error!Infer {
        const args = try c.arena.alloc(?Types.Arg, sig.generics.len);
        @memset(args, null);
        return .{ .types = c.types, .gens = sig.generics, .args = args };
    }

    fn index(s: *const Infer, ty: TypeId) ?usize {
        return std.mem.indexOfScalar(TypeId, s.gens, ty);
    }

    /// Fixes the open parameters in `pat` from `act`, the type of the
    /// argument passed for it. A part that does not match is reported when
    /// the argument is converted.
    fn unify(s: *Infer, pat: TypeId, act_in: TypeId) void {
        const t = s.types;
        if (act_in == .err or act_in == .noreturn or act_in == .untyped_int or act_in == .untyped_float) return;
        // A `mut T` view read as a value is a `T` (§4.5.3).
        const act = if (t.get(pat) != .mut_view and t.get(act_in) == .mut_view) t.get(act_in).mut_view.elem else act_in;
        if (s.index(pat)) |i| {
            if (s.args[i] == null) s.args[i] = .{ .type = act };
            return;
        }
        const ak = t.get(act);
        switch (t.get(pat)) {
            inline .array, .soa_array, .slice, .soa_slice, .handle, .ptr, .mut_view, .vec => |x, tag| if (ak == tag) s.unify(x.elem, @field(ak, @tagName(tag)).elem),
            .tuple => |x| if (ak == .tuple and ak.tuple.elems.len == x.elems.len) for (x.elems, ak.tuple.elems) |p, a| s.unify(p, a),
            .fn_ptr => |x| if (ak == .fn_ptr and ak.fn_ptr.params.len == x.params.len) {
                for (x.params, ak.fn_ptr.params) |p, a| s.unify(p.type, a.type);
                s.unify(x.ret, ak.fn_ptr.ret);
            },
            .nominal => |x| if (ak == .nominal and std.meta.eql(ak.nominal.decl, x.decl) and ak.nominal.args.len == x.args.len) {
                for (x.args, ak.nominal.args) |p, a| {
                    if (p != .type) continue;
                    // A value parameter in an argument list is symbolic: its `.param` type.
                    if (a == .value) {
                        if (s.index(p.type)) |i| if (s.args[i] == null) {
                            s.args[i] = a;
                        };
                    } else s.unify(p.type, a.type);
                }
            },
            else => {},
        }
    }

    /// Fixes each parameter that only untyped constants were passed for to
    /// their default type (§4.8), in parameter order.
    fn defaults(s: *Infer, params: []const check_call.Param) void {
        for (params) |p| {
            const pre = p.pre orelse continue;
            if (pre != .value) continue;
            const i = s.index(p.type) orelse continue;
            if (s.args[i] != null) continue;
            s.args[i] = switch (pre.value.ty) {
                .untyped_int => .{ .type = .int(.signed, 64) },
                .untyped_float => .{ .type = .f64 },
                else => continue,
            };
        }
    }

    /// Whether every parameter is fixed; else E0372 at `n` for each open
    /// type parameter, with `help`.
    fn complete(s: *const Infer, c: *Checker, n: Node.Index, m: ModuleId, sig: items_mod.Fn, help: []const u8) Error!bool {
        const gnodes = c.items.im.graph.modules[m].ast.data(sig.node).fn_decl.generics.?;
        var ok = true;
        for (s.args, s.gens, gnodes) |a, g, gn| if (a == null) {
            ok = false;
            // shortcut: a value parameter is inferred only from generic argument lists, not from array lengths (`[N]T` parameters resolve to `.err`), until generic signatures keep symbolic lengths (T070).
            if (try c.items.paramValueType(m, gn) != .none) {
                _ = c.unsupported(n, "inferring generic value parameters from array lengths (T070)");
                continue;
            }
            try c.reportAt(c.ast.mainToken(n), .E0372, &.{help}, "cannot infer generic parameter `{s}` of `{s}`", .{ s.types.strings.get(s.types.get(g).param.name), sig.name });
        };
        return ok;
    }

    /// The arguments; all fixed.
    fn fixed(s: *const Infer, c: *Checker) Error![]const Types.Arg {
        const out = try c.arena.alloc(Types.Arg, s.args.len);
        for (s.args, out) |a, *o| o.* = a.?;
        return out;
    }

    /// The type arguments fixed so far, `.none` for the others.
    fn typeArgs(s: *const Infer, c: *Checker) Error![]const TypeId {
        const out = try c.arena.alloc(TypeId, s.args.len);
        for (s.args, out) |a, *o| o.* = if (a) |x| (if (x == .type) x.type else .none) else .none;
        return out;
    }

    /// What an argument for a parameter of type `ty` is checked against:
    /// `ty` with the fixed parameters substituted, or `.none` while it
    /// mentions an open one.
    fn expected(s: *const Infer, c: *Checker, ty: TypeId) Error!TypeId {
        if (!generics.mentionsParam(s.types, ty)) return ty;
        const p = c.bodies.protos orelse return .none;
        const t = try p.subst(ty, s.types.get(s.gens[0]).param.owner, try s.typeArgs(c));
        return if (generics.mentionsParam(s.types, t)) .none else t;
    }
};

/// Checks argument `a` for parameter `p` before binding, when it can be,
/// and unifies `p`'s type with the argument's.
fn preArg(c: *Checker, s: *Infer, a: Node.Index, p: *check_call.Param) Error!void {
    const ast = c.ast;
    const inner = if (ast.kind(a) == .named_arg) ast.data(a).named_arg.value else a;
    const marked = ast.kind(inner) == .mut_arg;
    const value = check_call.unwrapArg(ast, a);
    const local = check_call.localOf(c, value);
    const local_ty: TypeId = if (local) |l| c.b.locals.items(.ty)[l.int()] else .none;
    switch (p.mode) {
        .mut => if (marked) {
            const place = try mutability.mutArg(c, inner, value) orelse mutability.Place{ .ty = .err };
            p.pre = .{ .place = place };
            return s.unify(p.type, place.ty);
        },
        .value => if (!marked) {
            // A resource or shared cell local is passed as a view of its place (§5.5.2).
            const by_view = local != null and local_ty != .err and switch (try kinds.kind(c.items, local_ty)) {
                .resource, .shared_cell => true,
                else => false,
            };
            if (!by_view) {
                c.comp_dest = value;
                const v = try check_expr.check(c, value, try s.expected(c, p.type));
                p.pre = .{ .value = v };
                return s.unify(p.type, v.ty);
            }
        },
        .move, .@"comptime" => {},
    }
    // Checked when bound; a local's type is known without reading it.
    if (local != null) s.unify(p.type, local_ty);
}

/// The index among `params` of the parameter that argument `a` is for,
/// as `check_call.bind` binds it: positional arguments in order (`next`),
/// then named ones by name (`named` once one was seen).
fn paramIndex(ast: *const Ast, params: []const items_mod.Param, a: Node.Index, next: *usize, named: *bool) ?usize {
    if (ast.kind(a) == .named_arg) {
        named.* = true;
        const name = ast.tokenSlice(ast.mainToken(a));
        for (params, 0..) |p, i| if (std.mem.eql(u8, p.name, name)) return i;
        return null;
    }
    if (named.* or next.* >= params.len) return null;
    next.* += 1;
    return next.* - 1;
}

// ---------------------------------------------------------------------------
// Instances

/// The instance of generic function `sig` (module `m`) for `args`, called
/// or named by `n` (§7.6.2, §7.6.4): bounds checked, memoized under the
/// declaration and the arguments, its signature and body checked once.
/// Null after a diagnostic or an unsupported construct (`c.failed` set).
fn instance(c: *Checker, n: Node.Index, m: ModuleId, sig: items_mod.Fn, args: []const Types.Arg) Error!?instantiate.Func {
    const it = c.items;
    const decl = try comptime_ctx.declOf(it, m, sig.node) orelse return unsupported(c, n, "generic `impl` methods (T070)");
    if (decl.generics.len > 0 or sig.instance != .none) return unsupported(c, n, "generic methods of generic types (T070)");
    for (sig.params) |p| if (p.mode == .@"comptime") return unsupported(c, n, "generic functions with `comptime` parameters (T070)");
    const gnodes = it.im.graph.modules[m].ast.data(sig.node).fn_decl.generics.?;
    if (!try bounds(c, n, m, sig, gnodes, args)) {
        c.failed = true;
        return null;
    }
    const key = try generics.keyOf(it, m, sig.node, args);
    if (it.memo.find(key)) |id| return switch (it.memo.get(id).*) {
        .func => |f| f,
        else => {
            c.failed = true; // reported with the first use
            return null;
        },
    };
    const depth = try generics.nextDepth(it, c.m, n, sig.name) orelse {
        c.failed = true;
        return null;
    };
    // The entry exists before the body is checked: recursive calls find it.
    const bs = c.bodies;
    const fid: tir.FnId = .from(bs.fns.items.len);
    try bs.fns.append(bs.arena.allocator(), .{ .module = m, .node = sig.node, .name = sig.name, .checked = true });
    const id = try it.memo.add(it.arena.allocator(), key, .{ .func = .{ .id = fid, .sig = sig } });
    var frame = try generics.bind(it, id, m, gnodes, args, depth);
    const saved = it.instance;
    it.instance = &frame;
    defer it.instance = saved;
    // Errors of the template's signature were reported when it was checked.
    const before = it.sink.diags.items.len;
    var isig = try it.signature(m, sig.node, decl.self_ty);
    instantiate.dropRepeats(it.sink, before);
    isig.generics = &.{};
    it.memo.get(id).func.sig = isig;
    // Checking may add bodies and move `bs.fns.items`.
    const func = try emit_tir.checkFn(bs, it, m, fid, isig, decl.self_ty) orelse {
        it.memo.get(id).* = .failed;
        c.failed = true; // reported or recorded by the body
        return null;
    };
    bs.fns.items[fid.int()].func = func;
    return .{ .id = fid, .sig = isig };
}

/// Checks the bounds of parameters `gnodes` of `sig` (module `m`) for
/// `args` at `n`: E0329 for `plain` (§7.6.1), E0373 for protocols
/// (§7.5.2). Whether they hold.
fn bounds(c: *Checker, n: Node.Index, m: ModuleId, sig: items_mod.Fn, gnodes: []const Node.Index, args: []const Types.Arg) Error!bool {
    if (!try generics.plainBounds(c.items, c.m, n, m, gnodes, args)) return false;
    if (c.bodies.protos) |p| return p.checkCallBounds(c.items.tokSpan(c.m, c.ast.mainToken(n)), sig.generics, args);
    const a = c.items.im.graph.modules[m].ast;
    for (gnodes) |g| for (a.data(g).generic_param.bounds) |b| {
        if (a.kind(b) == .path and std.mem.eql(u8, a.tokenSlice(a.mainToken(b)), "plain")) continue;
        if (try c.items.paramValueType(m, g) != .none) continue;
        _ = c.unsupported(n, "protocol bounds of generic calls without protocols");
        return false;
    };
    return true;
}

fn unsupported(c: *Checker, n: Node.Index, what: []const u8) ?instantiate.Func {
    _ = c.unsupported(n, what);
    return null;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const Fixture = comptime_ctx.Fixture;

/// The checked instances named `name`.
fn instances(f: *Fixture, name: []const u8) ![]const tir.Func {
    var out: std.ArrayList(tir.Func) = .empty;
    for (f.bodies.fns.items) |b| if (b.func != null and std.mem.eql(u8, b.name, name)) try out.append(f.bodies.arena.allocator(), b.func.?);
    return out.items;
}

fn retOf(f: *Fixture, name: []const u8) !TypeId {
    return f.bodies.find(0, name).?.func.?.ret;
}

test "`larger(1, x)` infers `f32` from `x`; `larger(1, 2)` defaults to `i64`" {
    var f: Fixture = undefined;
    try f.init(
        \\fn larger<T: plain>(a: T, b: T) -> T { if a > b { a } else { b } }
        \\fn pick<T: plain>(a: T, b: T) -> T { a }
        \\fn floats(x: f32) -> f32 { larger(1, x) }
        \\fn ints() -> i64 { larger(1, 2) }
        \\fn halves() -> f64 { larger(0.5, 2) }
        \\fn named(x: u8) -> u8 { larger(b: x, a: 3) }
        \\fn tuples(x: u8) -> (u8, u8) { pick(.{ x, x }, (x, 1)) }
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    try f.expectComplete();
    try testing.expectEqual(TypeId.f32, try retOf(&f, "floats"));
    try testing.expectEqual(TypeId.int(.signed, 64), try retOf(&f, "ints"));
    // f32, i64, f64, u8; pick((u8, u8)): the templates are not checked.
    try testing.expectEqual(4, (try instances(&f, "larger")).len);
    try testing.expectEqual(5, f.items.memo.count());
}

test "a parameter only in the result is E0372; `comptime T: type` passes it" {
    var f: Fixture = undefined;
    try f.init(
        \\fn zero<T: plain>() -> T { @zero(T) }
        \\fn make(comptime T: type) -> T { @zero(T) }
        \\fn bad() -> u32 { let z: u32 = zero(); z }
        \\fn good() -> u32 { let z: u32 = make(u32); z }
        \\fn value() -> u32 { let g = zero; 0 }
    );
    defer f.deinit();
    try f.expectDiags(&.{ .{ .E0372, "zero" }, .{ .E0372, "zero" } });
    try testing.expectEqual(TypeId.int(.unsigned, 32), try retOf(&f, "good"));
}

test "`let f: fn(f32) -> f32 = clamp;` instantiates `clamp` from the expected type" {
    var f: Fixture = undefined;
    try f.init(
        \\fn clamp<T: plain>(x: T) -> T { if x > 1 { 1 } else { x } }
        \\fn demo(x: f32) -> f32 {
        \\    let f: fn(f32) -> f32 = clamp;
        \\    let g: fn(f32) -> f32 = clamp;
        \\    f(x) + g(x) + clamp(x)
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    try f.expectComplete();
    // The value and the call infer the same arguments: one instance.
    try testing.expectEqual(1, f.items.memo.count());
    const inst = try instances(&f, "clamp");
    try testing.expectEqual(1, inst.len);
    try testing.expectEqual(TypeId.f32, inst[0].ret);
}

test "inference unifies through structure and generic type arguments" {
    var f: Fixture = undefined;
    try f.init(
        \\struct Ring<T, CAP: usize> { items: [CAP]T }
        \\fn first<T: plain>(xs: []T) -> T { xs[0] }
        \\fn cap<T: plain, N: usize>(r: Ring<T, N>) -> usize { N }
        \\fn bump<T: plain>(mut x: T, by: T) { x = x + by; }
        \\fn demo(r: Ring<u16, 8>) -> u16 {
        \\    let arr: [4]u16 = [1, 2, 3, 4];
        \\    let xs: []u16 = arr[0..];
        \\    let mut y: u16 = 1;
        \\    bump(mut y, 2);
        \\    first(xs) + cap(r) as u16 + y
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    try f.expectComplete();
    // Ring<u16, 8>, first(u16), cap(u16, 8), bump(u16).
    try testing.expectEqual(4, f.items.memo.count());
}

test "bounds are checked at the call: E0329 for `plain`, E0373 for a protocol" {
    var f: Fixture = undefined;
    try f.init(
        \\pub protocol Shape { fn area(self) -> f32; }
        \\struct Square { w: f32 }
        \\impl Shape for Square { fn area(self) -> f32 { self.w * self.w } }
        \\struct Label { w: f32 }
        \\fn keep<T: plain>(x: T) -> T { x }
        \\fn area<T: Shape>(x: T) -> f32 { x.area() }
        \\fn a() -> usize { let n = keep("orc"); 3 }
        \\fn b() -> f32 { area(Label { w: 1.0 }) }
        \\fn c() -> f32 { area(Square { w: 2.0 }) + keep(Square { w: 1.0 }).w }
    );
    defer f.deinit();
    try f.expectDiags(&.{ .{ .E0329, "keep" }, .{ .E0373, "area" } });
}
