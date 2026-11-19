//! Comptime parameters and the shared instantiation memo table (§8.2,
//! §7.6.2, §8.3.1, §4.12).
//!
//! A call of a function with `comptime` parameters, `fn f(comptime n:
//! usize, x: f32)`, evaluates each `comptime` argument at the call in the
//! caller's context (§8.1); a runtime argument is E0801, reported when the
//! arguments are bound (`check_call.zig`). The call then calls the
//! *instantiation* of `f` for those values: a separate TIR function whose
//! signature and body are checked with the `comptime` parameters bound to
//! constants (`Frame`), so `n` may size arrays (`-> [n]u8`, `[x; n]`). The
//! instance takes only the runtime parameters. A function with `comptime`
//! parameters has no body of its own: `emit_tir.checkFn` checks it only as
//! an instantiation.
//!
//! ## The memo table
//!
//! `Items.memo` is the single memo table of a package. Function
//! instantiations use it here; generic types and functions (T064, T068,
//! T070) and type functions (T065) reuse it, so that applying the same
//! declaration to equal arguments yields the same instance (§7.6.2, §8.3.1).
//!
//! - `Key`: the declaration (its module and declaring node) and its
//!   comptime arguments as `value.Value`s (`argValue` converts an
//!   `items.Value`). Keys are equal when the declarations are the same and
//!   the arguments are `Value.eql`: types by identity, other values by
//!   structural equality.
//! - `Memo.find(key)` returns the instance's `Id`; `Memo.add(gpa, key,
//!   result)` adds one (the key's arguments must outlive the table: use the
//!   `Items` arena); `Memo.get(id)` its `Result`, updatable in place.
//! - `Result`: `.func` (a function instance: its TIR id and instantiated
//!   signature), `.type` (a type instance), or `.failed` (a failed
//!   instance: later uses report nothing more).
//! - Add the entry *before* checking the instance, so that a recursive
//!   reference finds it instead of instantiating again.
//! - An `Id` also names the instantiation context of comptime evaluation
//!   (`current`): the comptime driver caches results per expression and
//!   instance, so a result computed inside one instance does not leak into
//!   another.
//!
//! Instantiations nest (an instance's body calls another one); a chain
//! deeper than 256 is E0812 (§4.12), reported at the call that exceeds it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("../ast/Ast.zig");
const diag = @import("../diag/diag.zig");
const Types = @import("../sema/types.zig");
const items_mod = @import("../sema/items.zig");
const emit_tir = @import("../sema/emit_tir.zig");
const check_call = @import("../sema/check_call.zig");
const check_expr = @import("../sema/check_expr.zig");
const comptime_ctx = @import("../sema/comptime_ctx.zig");
const tir = @import("../tir/tir.zig");
const ModuleId = @import("../resolve/module_graph.zig").ModuleId;
const Value = @import("value.zig").Value;

const Node = Ast.Node;
const TypeId = Types.TypeId;
const Items = items_mod.Items;
const Checker = emit_tir.Checker;
const Typed = emit_tir.Typed;
const Error = Allocator.Error;

/// Maximum nesting of instantiations (§4.12).
pub const max_depth = 256;

/// An entry of the memo table; stable for the life of the table.
pub const Id = u32;

/// `current` outside any instantiation.
pub const no_instance: Id = std.math.maxInt(Id);

/// A declaration applied to comptime arguments.
pub const Key = struct {
    module: ModuleId,
    /// The declaring node: a `fn_decl`, or a generic type declaration.
    decl: Node.Index,
    args: []const Value,
};

/// A function instance.
pub const Func = struct {
    id: tir.FnId,
    /// The signature with the `comptime` parameters bound.
    sig: items_mod.Fn,
};

/// What an instantiation produced.
pub const Result = union(enum) {
    /// It failed (reported, or recorded as unsupported).
    failed,
    func: Func,
    type: TypeId,
};

/// The memo table: instances by declaration and comptime arguments.
pub const Memo = struct {
    map: std.HashMapUnmanaged(Key, Id, KeyContext, std.hash_map.default_max_load_percentage) = .empty,
    results: std.ArrayList(Result) = .empty,

    /// The instance of `key`, if there is one.
    pub fn find(memo: *const Memo, key: Key) ?Id {
        return memo.map.get(key);
    }

    /// Adds the instance of `key` (which must not be present) with `result`.
    pub fn add(memo: *Memo, gpa: Allocator, key: Key, result: Result) Error!Id {
        const id: Id = @intCast(memo.results.items.len);
        try memo.results.append(gpa, result);
        try memo.map.putNoClobber(gpa, key, id);
        return id;
    }

    /// The result of instance `id`.
    pub fn get(memo: *Memo, id: Id) *Result {
        return &memo.results.items[id];
    }

    /// The number of instances.
    pub fn count(memo: *const Memo) usize {
        return memo.results.items.len;
    }
};

const KeyContext = struct {
    pub fn hash(_: KeyContext, k: Key) u64 {
        var h: std.hash.Wyhash = .init(0);
        h.update(std.mem.asBytes(&k.module));
        h.update(std.mem.asBytes(&k.decl));
        // Members of aggregates are left to `eql`.
        for (k.args) |v| {
            h.update(std.mem.asBytes(&v.ty));
            switch (v.data) {
                .scalar => |bits| h.update(std.mem.asBytes(&bits)),
                .type => |t| h.update(std.mem.asBytes(&t)),
                else => {},
            }
        }
        return h.final();
    }

    pub fn eql(_: KeyContext, a: Key, b: Key) bool {
        if (a.module != b.module or a.decl != b.decl or a.args.len != b.args.len) return false;
        for (a.args, b.args) |x, y| if (!x.eql(y)) return false;
        return true;
    }
};

/// Key argument for comptime value `v`; null for a value that is not known
/// (`.unknown`) or not typed yet (`.untyped`).
pub fn argValue(it: *Items, v: items_mod.Value) ?Value {
    return switch (v) {
        .scalar => |s| .{ .ty = s.type, .data = .{ .scalar = s.bits } },
        .type => |t| .{ .ty = .type, .data = .{ .type = t } },
        .computed => |cv| comptime_ctx.of(it).?.value(cv.id),
        .untyped, .unknown => null,
    };
}

// ---------------------------------------------------------------------------
// Bindings

/// The instantiation being checked: its `comptime` parameters bound to
/// values. Installed as `Items.instance`.
pub const Frame = struct {
    id: Id,
    module: ModuleId,
    /// The `param` nodes of the bound parameters.
    params: []const Node.Index,
    values: []const items_mod.Value,
    /// Nesting of instantiations, 1 for the outermost.
    depth: u32,
};

/// The instantiation context of comptime evaluation: the current instance,
/// or `no_instance`.
pub fn current(it: *const Items) Id {
    return if (it.instance) |f| f.id else no_instance;
}

/// The value bound to `comptime` parameter `param` of module `m` in the
/// instantiation being checked, if any.
pub fn boundValue(it: *const Items, m: ModuleId, param: Node.Index) ?items_mod.Value {
    const f = it.instance orelse return null;
    if (f.module != m) return null;
    for (f.params, f.values) |p, v| if (p == param) return v;
    return null;
}

/// Bound parameter `param` used at `n` in a body: a constant (§8.2), or
/// null if it is not bound.
pub fn boundParam(c: *Checker, n: Node.Index, param: Node.Index) Error!?Typed {
    const v = boundValue(c.items, c.m, param) orelse return null;
    return try check_expr.constValue(c, n, .{ .node = param, .name = "", .is_pub = false, .type = .err, .value = v });
}

// ---------------------------------------------------------------------------
// Instantiation

/// The instantiation of `sig` (module `m`) that call `n` with `args` calls;
/// `skip` parameters are taken by a receiver. Null if it cannot be made: a
/// `comptime` argument is missing or runtime (both reported when the
/// arguments are bound), or failed (reported or recorded as unsupported;
/// `c.failed` is set).
pub fn instance(c: *Checker, n: Node.Index, m: ModuleId, sig: items_mod.Fn, skip: usize, args: []const Node.Index) Error!?Func {
    const it = c.items;
    const arena = it.arena.allocator();
    var params: std.ArrayList(Node.Index) = .empty;
    var values: std.ArrayList(items_mod.Value) = .empty;
    var key_args: std.ArrayList(Value) = .empty;
    const own = sig.params[skip..];
    for (own, 0..) |p, i| {
        if (p.mode != .@"comptime") continue;
        if (p.type == .type) {
            _ = c.unsupported(n, "`comptime` type parameters (T068)");
            return null;
        }
        const before = c.sink.diags.items.len;
        const at = argNode(c.ast, args, own, i);
        const v: items_mod.Value = if (at) |a| v: {
            if (it.runtimeRef(c.m, a) != null) return null;
            break :v try it.comptimeArg(c.m, a, c.self_ty, p.type);
        } else p.default orelse return null;
        const kv = argValue(it, v) orelse {
            if (p.type == .err or c.sink.diags.items.len > before) {
                c.failed = true; // reported
            } else _ = c.unsupported(at orelse n, "`comptime` arguments the evaluator could not compute");
            return null;
        };
        try params.append(arena, p.node);
        try values.append(arena, v);
        try key_args.append(arena, kv);
    }
    const key: Key = .{ .module = m, .decl = sig.node, .args = key_args.items };
    if (it.memo.find(key)) |id| return switch (it.memo.get(id).*) {
        .func => |f| f,
        else => {
            c.failed = true; // reported with the first call
            return null;
        },
    };
    const depth = if (it.instance) |f| f.depth + 1 else 1;
    if (depth > max_depth) {
        try c.report(n, .E0812, "instantiation of `{s}` is nested too deeply: the limit is {d}", .{ sig.name, max_depth });
        return null;
    }
    const decl = try comptime_ctx.declOf(it, m, sig.node) orelse
        comptime_ctx.Decl{ .f = sig, .self_ty = .none, .generics = &.{} }; // shortcut: impl methods get no `Self`; T070 resolves them.
    if (sig.generics.len > 0 or decl.generics.len > 0) {
        _ = c.unsupported(n, "generic function bodies (T070)");
        return null;
    }
    // The entry exists before the body is checked: recursive calls find it.
    const bs = c.bodies;
    const fid: tir.FnId = .from(bs.fns.items.len);
    try bs.fns.append(bs.arena.allocator(), .{ .module = m, .node = sig.node, .name = sig.name, .checked = true });
    const id = try it.memo.add(arena, key, .{ .func = .{ .id = fid, .sig = sig } });
    var frame: Frame = .{ .id = id, .module = m, .params = params.items, .values = values.items, .depth = depth };
    const saved = it.instance;
    it.instance = &frame;
    defer it.instance = saved;
    const isig = try signature(it, m, sig, decl.self_ty);
    it.memo.get(id).func.sig = isig;
    // shortcut: an instance first checked before protocols exist and stopped at a method call is not checked again (`Body.retry`).
    // Checking may add bodies and move `bs.fns.items`.
    const func = try emit_tir.checkFn(bs, it, m, isig, decl.self_ty) orelse {
        it.memo.get(id).* = .failed;
        c.failed = true; // reported or recorded by the body
        return null;
    };
    bs.fns.items[fid.int()].func = func;
    return .{ .id = fid, .sig = isig };
}

/// `sig` with the types that depend on the bound `comptime` parameters
/// resolved again: those that did not resolve without them.
fn signature(it: *Items, m: ModuleId, sig: items_mod.Fn, self_ty: TypeId) Error!items_mod.Fn {
    const ast = it.im.graph.modules[m].ast;
    const before = it.sink.diags.items.len;
    const params = try it.arena.allocator().dupe(items_mod.Param, sig.params);
    for (params) |*p| if (p.type == .err) if (ast.data(p.node).param.ty) |t| {
        p.type = try it.resolveType(m, t, self_ty);
    };
    var f = sig;
    f.params = params;
    if (f.ret == .err) f.ret = try it.resolveType(m, ast.data(sig.node).fn_decl.ret.?, self_ty);
    dropRepeats(it.sink, before);
    return f;
}

/// Drops the diagnostics from index `from` on that repeat an earlier one:
/// errors of the template's signature, reported when it was checked.
fn dropRepeats(sink: *diag.Sink, from: usize) void {
    const ds = &sink.diags;
    var len = from;
    for (ds.items[from..]) |d| {
        const seen = for (ds.items[0..from]) |e| {
            if (e.code == d.code and std.meta.eql(e.primarySpan(), d.primarySpan()) and std.mem.eql(u8, e.message, d.message)) break true;
        } else false;
        if (seen) continue;
        ds.items[len] = d;
        len += 1;
    }
    ds.shrinkRetainingCapacity(len);
}

/// The argument for parameter `i` of `params` among call arguments `args`:
/// the one named after it, else the positional one before any named
/// argument (§7.2.4). Binding the arguments reports misuse.
fn argNode(ast: *const Ast, args: []const Node.Index, params: []const items_mod.Param, i: usize) ?Node.Index {
    var pos: usize = 0;
    var named = false;
    for (args) |a| {
        if (ast.kind(a) == .named_arg) {
            named = true;
            if (std.mem.eql(u8, ast.tokenSlice(ast.mainToken(a)), params[i].name)) return check_call.unwrapArg(ast, a);
        } else if (!named) {
            if (pos == i) return check_call.unwrapArg(ast, a);
            pos += 1;
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const Fixture = comptime_ctx.Fixture;

/// The callees of the `call` instructions of the first checked body named
/// `name` (an instance, for a function with `comptime` parameters).
fn callees(f: *Fixture, name: []const u8) ![]tir.FnId {
    const func = for (f.bodies.fns.items) |*b| {
        if (!b.thunk and b.func != null and std.mem.eql(u8, b.name, name)) break &b.func.?;
    } else return error.TestUnexpectedResult;
    var out: std.ArrayList(tir.FnId) = .empty;
    for (0..func.insts.len) |i| switch (func.data(.from(i))) {
        .call => |x| try out.append(f.bodies.arena.allocator(), x.callee),
        else => {},
    };
    return out.items;
}

test "equal comptime arguments share one instance; distinct ones do not" {
    var f: Fixture = undefined;
    try f.init(
        \\const WIDTH: usize = 4;
        \\fn repeat(comptime n: usize, x: u8) -> [n]u8 { [x; n] }
        \\fn twice(comptime n: usize, x: u8) -> [n]u8 { repeat(n, x + x) }
        \\fn demo(x: u8) -> u8 {
        \\    let a = repeat(3, x);
        \\    let b = repeat(n: 3, x: x);
        \\    let c = repeat(WIDTH, x);
        \\    let d = twice(4, x);
        \\    a[2] + b[0] + c[3] + d[3]
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    try f.expectComplete();
    // repeat(3), repeat(4) (shared by `WIDTH` and `twice(4)`), twice(4).
    try testing.expectEqual(3, f.items.memo.count());
    const cs = try callees(&f, "demo");
    try testing.expectEqual(4, cs.len);
    try testing.expectEqual(cs[0], cs[1]);
    try testing.expect(cs[0] != cs[2]);
    try testing.expectEqual(cs[2], (try callees(&f, "twice"))[0]);
    // The instance takes the runtime parameter only and returns `[3]u8`.
    const inst = f.bodies.fns.items[cs[0].int()];
    try testing.expectEqualStrings("repeat", inst.name);
    try testing.expectEqual(3, f.types.get(inst.func.?.ret).array.len);
    try testing.expectEqual(1, inst.func.?.param_count);
}

test "a runtime argument for a comptime parameter is E0801" {
    var f: Fixture = undefined;
    try f.init(
        \\fn repeat(comptime n: usize, x: u8) -> [n]u8 { [x; n] }
        \\fn demo(count: usize) -> u8 { let xs = repeat(count, 1); 7 }
        \\fn value() -> u8 { let g = repeat; 7 }
    );
    defer f.deinit();
    // A function with `comptime` parameters is no `fn` value either.
    try f.expectDiags(&.{ .{ .E0801, "count" }, .{ null, "repeat" } });
    try testing.expectEqual(0, f.items.memo.count());
}

test "instances run at comptime and select by their bound value" {
    var f: Fixture = undefined;
    try f.init(
        \\fn scale(comptime k: u32, x: u32) -> u32 { x * k + comptime { k * 100 } }
        \\const A: u32 = scale(2, 5);
        \\const B: u32 = scale(3, 5);
        \\fn sum() -> u32 { A + B + scale(2, 1) }
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    try f.expectComplete();
    try testing.expectEqual(210, (try f.constOf("A")).value.scalar.bits);
    try testing.expectEqual(315, (try f.constOf("B")).value.scalar.bits);
    try testing.expectEqual(2, f.items.memo.count());
}

test "local consts in an instance body take its bound values" {
    for ([_][]const u8{
        \\const A: u32 = k(1);
        \\const B: u32 = k(5);
        \\fn k(comptime n: u32) -> u32 { const m: u32 = n * 2; m }
        ,
        \\fn d() -> u32 { k(5) + k(1) }
        \\const B: u32 = k(5);
        \\const A: u32 = k(1);
        \\fn k(comptime n: u32) -> u32 { const m: u32 = n * 2; m }
        ,
    }) |src| {
        var f: Fixture = undefined;
        try f.init(src);
        defer f.deinit();
        try f.expectDiags(&.{});
        try f.expectComplete();
        try testing.expectEqual(2, (try f.constOf("A")).value.scalar.bits);
        try testing.expectEqual(10, (try f.constOf("B")).value.scalar.bits);
    }
}

test "a failed instance is reported once and not called" {
    var f: Fixture = undefined;
    try f.init(
        \\fn g(comptime n: u32) -> u32 { n + true }
        \\fn d() -> u32 { g(1) + g(1) }
    );
    defer f.deinit();
    try f.expectDiags(&.{.{ .E0310, "+" }});
    try testing.expectEqual(1, f.items.memo.count());
    try testing.expect(f.items.memo.get(0).* == .failed);
}

test "signature errors of the template are not repeated by its instances" {
    var f: Fixture = undefined;
    try f.init(
        \\fn h(comptime n: usize, x: Bogus) -> [n]u8 { [1; n] }
        \\fn d() -> u8 { h(2, 0)[0] }
    );
    defer f.deinit();
    try f.expectDiags(&.{.{ null, "Bogus" }});
}

test "`comptime` type parameters are left to T068" {
    var f: Fixture = undefined;
    try f.init(
        \\fn id(comptime T: type, x: T) -> T { x }
        \\fn d() -> u32 { id(u32, 5) }
    );
    defer f.deinit();
    try testing.expect(std.mem.indexOf(u8, f.bodies.unsupported.?.what, "T068") != null);
    try testing.expectEqual(0, f.items.memo.count());
}

test "unbounded nested instantiation is E0812" {
    var f: Fixture = undefined;
    try f.init(
        \\fn deep(comptime n: u32) -> u32 { deep(n + 1) }
        \\fn demo() -> u32 { deep(0) }
    );
    defer f.deinit();
    try f.expectDiags(&.{.{ .E0812, "(" }});
    try testing.expectEqual(max_depth, f.items.memo.count());
}

test "memo keys compare types by identity and values structurally" {
    var memo: Memo = .{};
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const xs = [_]Value{ .{ .ty = .usize, .data = .{ .scalar = 1 } }, .{ .ty = .usize, .data = .{ .scalar = 2 } } };
    const arr: Value = .{ .ty = .str, .data = .{ .aggregate = &xs } };
    const k1: Key = .{ .module = 0, .decl = .from(5), .args = &.{ .{ .ty = .type, .data = .{ .type = .bool } }, arr } };
    const id = try memo.add(a, k1, .{ .type = .bool });
    const ys = [_]Value{ .{ .ty = .usize, .data = .{ .scalar = 1 } }, .{ .ty = .usize, .data = .{ .scalar = 2 } } };
    const k2: Key = .{ .module = 0, .decl = .from(5), .args = &.{ .{ .ty = .type, .data = .{ .type = .bool } }, .{ .ty = .str, .data = .{ .aggregate = &ys } } } };
    try testing.expectEqual(id, memo.find(k2).?);
    const k3: Key = .{ .module = 0, .decl = .from(5), .args = &.{ .{ .ty = .type, .data = .{ .type = .f64 } }, arr } };
    try testing.expect(memo.find(k3) == null);
    try testing.expectEqual(TypeId.bool, memo.get(id).type);
}
