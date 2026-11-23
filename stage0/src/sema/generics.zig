//! Generic declarations as memoized type functions (§7.6.1, §7.6.2, §4.10,
//! §4.12).
//!
//! A generic struct or enum `Ring<T, CAP: usize>` is a comptime function
//! from its arguments to a type. Applying it to arguments without generic
//! parameters in them (`Ring<u32, 64>` in type position, `Ring(u32, 64)` in
//! expression position, §3.6) instantiates it:
//!
//! - the bounds are checked: a non-plain argument of a `T: plain`
//!   parameter is E0329, reported at the use; protocol bounds (E0373) are
//!   checked once protocols exist (`checkBounds`);
//! - the instance is looked up in, or added to, the shared memo table
//!   (`comptime/instantiate.zig`, `Items.memo`) under the declaration and
//!   the arguments (types by identity, values by equality), so equal
//!   arguments give the same `TypeId` (§4.10, §7.6.2);
//! - the declaration is checked again with its parameters bound to the
//!   arguments (an `instantiate.Frame`): the instance's fields, payloads,
//!   associated consts and method signatures are in terms of the arguments
//!   (`[CAP]T` is `[64]u32`). `Items.structOf`/`enumOf` of the instance
//!   return them, with no generic parameters left;
//! - instantiations nest (a field of an instance names another instance);
//!   a chain deeper than 256 is E0812 (§4.12).
//!
//! A method of an instance is checked per instance, when it is first
//! called (`methodFn`, §7.6.4), with the instance as `Self`; the template
//! body itself is not checked. Generic aliases and distinct types
//! (`type Grid<T> = [16][16]T;`) are instantiated the same way
//! (`aliasType`). The standard containers, not loaded yet (T163), have
//! their `T: plain` element rule in `kinds.zig`.
//!
//! Inside a generic declaration its parameters stay symbolic
//! (`Ring<T, CAP>`, `.param` types); generic function calls and argument
//! inference are T068's.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("../ast/Ast.zig");
const Types = @import("types.zig");
const items_mod = @import("items.zig");
const kinds = @import("kinds.zig");
const emit_tir = @import("emit_tir.zig");
const tir = @import("../tir/tir.zig");
const instantiate = @import("../comptime/instantiate.zig");
const Value = @import("../comptime/value.zig").Value;
const ModuleId = @import("../resolve/module_graph.zig").ModuleId;
const Ref = @import("../resolve/imports.zig").Ref;
const diag = @import("../diag/diag.zig");

const Node = Ast.Node;
const TypeId = Types.TypeId;
const Items = items_mod.Items;
const Info = items_mod.Info;
const Checker = emit_tir.Checker;
const Error = Allocator.Error;

/// The instances of a package, by instance type. Arena-backed (`Items`).
pub const State = struct {
    /// The checked declaration of each instance of a generic struct or enum.
    infos: std.AutoHashMapUnmanaged(TypeId, *const Info) = .empty,
    /// Instances whose declaration bounds a type parameter by a protocol,
    /// checked by `checkBounds`.
    bounded: std.ArrayList(Bounded) = .empty,
};

/// An instantiation at `at` (module `module`) of a declaration whose
/// parameters `gens` have protocol bounds, applied to `args`.
const Bounded = struct {
    module: ModuleId,
    at: Node.Index,
    site: diag.Span,
    gens: []const TypeId,
    args: []const Types.Arg,
};

/// Checks the protocol bounds of every instance (§7.5.2, §7.6.1, E0373)
/// with the protocols of `bs`; without them, the first is unsupported.
pub fn checkBounds(bs: *emit_tir.Bodies, it: *Items) Error!void {
    var i: usize = 0;
    while (i < it.generic.bounded.items.len) : (i += 1) {
        const b = it.generic.bounded.items[i];
        const p = bs.protos orelse {
            if (bs.unsupported == null) bs.unsupported = .{ .module = b.module, .node = b.at, .what = "protocol bounds of generic type arguments without protocols" };
            return;
        };
        _ = try p.checkCallBounds(b.site, b.gens, b.args);
    }
}

/// What `ty` declares: the instance's own declaration for an instance of a
/// generic struct or enum, else that of item `ref` (which declares `ty`).
pub fn infoOf(it: *Items, ty: TypeId, ref: Ref) Error!*const Info {
    return it.generic.infos.get(ty) orelse it.info(ref);
}

/// Whether `ty` is an instance of a generic struct or enum, with its own
/// fields and methods.
pub fn isInstance(it: *const Items, ty: TypeId) bool {
    return it.generic.infos.contains(ty);
}

// ---------------------------------------------------------------------------
// Instances

/// Instantiates generic struct or enum `ref` for nominal type `ty` (its
/// arguments evaluated), written at `at` in module `m`. Returns `ty`, or
/// `.err` if a bound is not met or the nesting is too deep (reported). A
/// `ty` whose arguments mention generic parameters is symbolic and stays
/// as is.
pub fn instance(it: *Items, m: ModuleId, at: Node.Index, ref: Ref, ty: TypeId) Error!TypeId {
    const item = it.im.graph.modules[ref.module].items[ref.item];
    // shortcut: generic protocols are applied by `protocols.zig`; they have no instance declaration.
    if (item.kind == .protocol) return ty;
    const args = it.types.get(ty).nominal.args;
    if (!concrete(it.types, args)) return ty;
    const gens = paramNodes(it, ref.module, item.node);
    if (!try plainBounds(it, m, at, ref.module, gens, args)) return .err;
    const key = try keyOf(it, ref.module, item.node, args);
    if (it.memo.find(key)) |id| return switch (it.memo.get(id).*) {
        .type => |t| t,
        else => .err, // reported with the first use
    };
    const depth = try nextDepth(it, m, at, item.name) orelse return .err;
    const id = try it.memo.add(it.arena.allocator(), key, .{ .type = ty });
    try deferBounds(it, m, at, ref.module, gens, args);
    var frame = try bind(it, id, ref.module, gens, args, depth);
    const saved = it.instance;
    it.instance = &frame;
    defer it.instance = saved;
    const before = it.sink.diags.items.len;
    const info = try it.arena.allocator().create(Info);
    info.* = switch (item.kind) {
        .@"struct" => blk: {
            var s = try it.structDecl(ref.module, ref.item, ty);
            s.generics = &.{};
            s.methods = try ownMethods(it, s.methods, ty);
            break :blk .{ .@"struct" = s };
        },
        .@"enum" => blk: {
            var e = try it.enumDecl(ref.module, ref.item, ty);
            e.generics = &.{};
            e.methods = try ownMethods(it, e.methods, ty);
            break :blk .{ .@"enum" = e };
        },
        else => unreachable, // `nominalOf` instantiates structs, enums and protocols
    };
    // Errors of the declaration itself were reported when it was checked.
    instantiate.dropRepeats(it.sink, before);
    try it.generic.infos.put(it.arena.allocator(), ty, info);
    return ty;
}

/// Generic alias or distinct type `ref` applied to generic arguments
/// `args` (null without `<...>`) at `at` in module `m` (§4.7, §7.6.1).
pub fn aliasType(it: *Items, m: ModuleId, at: Node.Index, ref: Ref, args: ?[]const Node.Index, self_ty: TypeId) Error!TypeId {
    const item = it.im.graph.modules[ref.module].items[ref.item];
    const a = it.im.graph.modules[ref.module].ast;
    const gens = paramNodes(it, ref.module, item.node);
    const given = args orelse &.{};
    if (given.len != gens.len) {
        try it.report(m, it.im.graph.modules[m].ast.mainToken(at), null, &.{}, "`{s}` takes {d} generic argument(s), found {d}", .{ item.name, gens.len, given.len });
        return .err;
    }
    const out = try it.arena.allocator().alloc(Types.Arg, gens.len);
    for (gens, given, out) |g, arg, *o| {
        const vt = try it.paramValueType(ref.module, g);
        o.* = try it.genericArg(m, arg, vt, self_ty) orelse return .err;
    }
    const is_concrete = concrete(it.types, out);
    if (is_concrete and !try plainBounds(it, m, at, ref.module, gens, out)) return .err;
    const key = try keyOf(it, ref.module, item.node, out);
    if (it.memo.find(key)) |id| return switch (it.memo.get(id).*) {
        .type => |t| t,
        // shortcut: an alias applied to its own arguments inside itself is not reported as E0376.
        else => .err,
    };
    const depth = try nextDepth(it, m, at, item.name) orelse return .err;
    const id = try it.memo.add(it.arena.allocator(), key, .failed);
    if (is_concrete) try deferBounds(it, m, at, ref.module, gens, out);
    var frame = try bind(it, id, ref.module, gens, out, depth);
    const saved = it.instance;
    it.instance = &frame;
    defer it.instance = saved;
    const before = it.sink.diags.items.len;
    const ty: TypeId = switch (a.data(item.node)) {
        .type_alias => |d| try it.resolveType(ref.module, d.ty, .none),
        .type_distinct => |d| try it.types.intern(.{ .nominal = .{
            .decl = .{ .package = it.options.package, .index = it.mods[ref.module].base + item.node.int() },
            .args = out,
            .kind = .distinct,
            .name = try it.types.strings.intern(item.name),
            .underlying = try it.resolveType(ref.module, d.ty, .none),
        } }),
        else => unreachable,
    };
    instantiate.dropRepeats(it.sink, before);
    it.memo.get(id).* = .{ .type = ty };
    return ty;
}

/// Generic struct or enum applied with parentheses in expression position,
/// `Ring(u32, 64)` (§7.6.2): the instance type, or null if call `n` is not
/// one (an ordinary call). `.err` after a diagnostic.
pub fn applied(c: *Checker, n: Node.Index) Error!?TypeId {
    const d = c.ast.data(n).call;
    switch (c.ast.kind(d.callee)) {
        .ident, .field_access => {},
        else => return null,
    }
    const e = c.items.names.get(c.m, d.callee) orelse return null;
    if (e.res != .global or e.res.global != .item) return null;
    const ref = e.res.global.item;
    const item = c.items.im.graph.modules[ref.module].items[ref.item];
    if (item.kind != .@"struct" and item.kind != .@"enum") return null;
    if (paramNodes(c.items, ref.module, item.node).len == 0) return null;
    for (d.args) |arg| if (c.ast.kind(arg) == .named_arg) {
        try c.report(arg, null, "generic arguments are positional", .{});
        return .err;
    };
    return try c.items.nominalOf(c.m, d.callee, ref, d.args, c.self_ty);
}

/// The function that a call `n` of method `sig` of an instance
/// (`sig.instance`, declared in module `m`) calls: the method checked with
/// the instance's arguments bound and the instance as `Self` (§7.6.4),
/// once per instance. Null if it failed (`c.failed` is set).
pub fn methodFn(c: *Checker, n: Node.Index, m: ModuleId, sig: items_mod.Fn) Error!?tir.FnId {
    const it = c.items;
    const inst = sig.instance;
    const args = it.types.get(inst).nominal.args;
    const owner = it.im.graph.modules[m].items[it.declRef(inst).?.item];
    const key: instantiate.Key = .{ .module = m, .decl = sig.node, .args = try it.arena.allocator().dupe(Value, &.{.{ .ty = .type, .data = .{ .type = inst } }}) };
    if (it.memo.find(key)) |id| return switch (it.memo.get(id).*) {
        .func => |f| f.id,
        else => {
            c.failed = true; // reported with the first call
            return null;
        },
    };
    const depth = try nextDepth(it, c.m, n, sig.name) orelse {
        c.failed = true;
        return null;
    };
    // The entry exists before the body is checked: recursive calls find it.
    const bs = c.bodies;
    const fid: tir.FnId = .from(bs.fns.items.len);
    try bs.fns.append(bs.arena.allocator(), .{ .module = m, .node = sig.node, .name = sig.name, .checked = true });
    const id = try it.memo.add(it.arena.allocator(), key, .{ .func = .{ .id = fid, .sig = sig } });
    var frame = try bind(it, id, m, paramNodes(it, m, owner.node), args, depth);
    const saved = it.instance;
    it.instance = &frame;
    defer it.instance = saved;
    // Checking may add bodies and move `bs.fns.items`.
    const func = try emit_tir.checkFn(bs, it, m, fid, sig, inst) orelse {
        it.memo.get(id).* = .failed;
        c.failed = true; // reported or recorded by the body
        return null;
    };
    bs.fns.items[fid.int()].func = func;
    return fid;
}

/// Whether method `f` of module `m` is checked per instance of its generic
/// struct or enum (`methodFn`) instead of once: it has no generic or
/// `comptime` parameters of its own.
pub fn perInstance(it: *Items, m: ModuleId, f: items_mod.Fn) bool {
    if (f.generics.len > 0) return false;
    for (f.params) |p| if (p.mode == .@"comptime") return false;
    const a = it.im.graph.modules[m].ast;
    for (it.im.graph.modules[m].items) |item| {
        const members = switch (a.data(item.node)) {
            .struct_decl => |d| if (d.generics != null) d.members else continue,
            .enum_decl => |d| if (d.generics != null) d.members else continue,
            else => continue,
        };
        for (members) |mn| {
            const inner = if (a.kind(mn) == .attributed) a.data(mn).attributed.inner else mn;
            if (inner == f.node) return true;
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// Helpers

/// The generic parameter nodes of declaration `node` of module `m`.
fn paramNodes(it: *const Items, m: ModuleId, node: Node.Index) []const Node.Index {
    const a = it.im.graph.modules[m].ast;
    const gens = switch (a.data(node)) {
        inline .struct_decl, .enum_decl, .protocol_decl, .type_alias, .type_distinct => |d| d.generics,
        else => null,
    };
    return gens orelse &.{};
}

/// E0329 at `at` (module `m`) for each type argument of a `plain`
/// parameter among `gens` (of module `dm`) that is not plain (§7.6.1).
fn plainBounds(it: *Items, m: ModuleId, at: Node.Index, dm: ModuleId, gens: []const Node.Index, args: []const Types.Arg) Error!bool {
    const da = it.im.graph.modules[dm].ast;
    var ok = true;
    for (gens, args) |g, arg| {
        if (arg != .type or arg.type == .err) continue;
        const plain = for (da.data(g).generic_param.bounds) |b| {
            if (da.kind(b) == .path and std.mem.eql(u8, da.tokenSlice(da.mainToken(b)), "plain")) break true;
        } else false;
        if (!plain or (try kinds.kind(it, arg.type)) == .plain) continue;
        ok = false;
        const a = it.im.graph.modules[m].ast;
        try it.report(m, items_mod.typeToken(a, at), .E0329, &.{"plain types hold no resource, shared cell or view (§5.1)"}, "`{s}` is not plain, but `{s}` is bounded by `plain`", .{ try it.tyName(arg.type), da.tokenSlice(da.mainToken(g)) });
    }
    return ok;
}

/// Adds the instantiation at `at` (module `m`) of parameters `gens` (of
/// module `dm`) with `args` to `it.generic.bounded` if a type parameter
/// has a bound other than `plain`.
fn deferBounds(it: *Items, m: ModuleId, at: Node.Index, dm: ModuleId, gens: []const Node.Index, args: []const Types.Arg) Error!void {
    const da = it.im.graph.modules[dm].ast;
    const bounded = for (gens) |g| {
        if ((try it.paramValueType(dm, g)) != .none) continue;
        for (da.data(g).generic_param.bounds) |b| {
            if (!(da.kind(b) == .path and std.mem.eql(u8, da.tokenSlice(da.mainToken(b)), "plain"))) break;
        } else continue;
        break true;
    } else false;
    if (!bounded) return;
    const arena = it.arena.allocator();
    const tys = try arena.alloc(TypeId, gens.len);
    for (gens, tys) |g, *t| t.* = it.mods[dm].params.get(g).?.type;
    const a = it.im.graph.modules[m].ast;
    try it.generic.bounded.append(arena, .{ .module = m, .at = at, .site = it.tokSpan(m, items_mod.typeToken(a, at)), .gens = tys, .args = try arena.dupe(Types.Arg, args) });
}

/// The memo key of declaration `decl` of module `m` applied to `args`,
/// allocated in the `Items` arena.
fn keyOf(it: *Items, m: ModuleId, decl: Node.Index, args: []const Types.Arg) Error!instantiate.Key {
    const vs = try it.arena.allocator().alloc(Value, args.len);
    for (args, vs) |arg, *v| v.* = switch (arg) {
        .type => |t| .{ .ty = .type, .data = .{ .type = t } },
        .value => |x| .{ .ty = x.type, .data = .{ .scalar = x.bits } },
    };
    return .{ .module = m, .decl = decl, .args = vs };
}

/// The nesting depth of a new instantiation of `name` at `at` in module
/// `m`, or null after E0812 if it exceeds the limit (§4.12).
fn nextDepth(it: *Items, m: ModuleId, at: Node.Index, name: []const u8) Error!?u32 {
    const depth = if (it.instance) |f| f.depth + 1 else 1;
    if (depth <= instantiate.max_depth) return depth;
    const a = it.im.graph.modules[m].ast;
    try it.report(m, items_mod.typeToken(a, at), .E0812, &.{"a generic instantiation that names a growing instance of itself never ends"}, "instantiation of `{s}` is nested too deeply: the limit is {d}", .{ name, instantiate.max_depth });
    return null;
}

/// The frame of instance `id`: parameters `gens` of module `m` bound to
/// `args`. A value parameter given a symbolic argument stays unbound.
fn bind(it: *Items, id: instantiate.Id, m: ModuleId, gens: []const Node.Index, args: []const Types.Arg, depth: u32) Error!instantiate.Frame {
    const arena = it.arena.allocator();
    var params: std.ArrayList(Node.Index) = .empty;
    var values: std.ArrayList(items_mod.Value) = .empty;
    for (gens, args) |g, arg| {
        const v: items_mod.Value = switch (arg) {
            .type => |t| if ((try it.paramValueType(m, g)) == .none) .{ .type = t } else continue,
            .value => |x| .{ .scalar = x },
        };
        try params.append(arena, g);
        try values.append(arena, v);
    }
    return .{ .id = id, .module = m, .params = params.items, .values = values.items, .depth = depth };
}

/// `methods` (of instance `inst`) marked as the instance's own.
fn ownMethods(it: *Items, methods: []const items_mod.Fn, inst: TypeId) Error![]const items_mod.Fn {
    const out = try it.arena.allocator().dupe(items_mod.Fn, methods);
    for (out) |*f| f.instance = inst;
    return out;
}

/// Whether no argument mentions a generic parameter.
fn concrete(t: *Types, args: []const Types.Arg) bool {
    for (args) |arg| if (arg == .type and mentionsParam(t, arg.type)) return false;
    return true;
}

/// Whether `ty` mentions a generic parameter.
fn mentionsParam(t: *Types, ty: TypeId) bool {
    return switch (t.get(ty)) {
        .param => true,
        inline .array, .soa_array, .slice, .soa_slice, .handle, .ptr, .mut_view, .vec => |x| mentionsParam(t, x.elem),
        .tuple => |x| for (x.elems) |e| {
            if (mentionsParam(t, e)) break true;
        } else false,
        .fn_ptr => |x| mentionsParam(t, x.ret) or for (x.params) |p| {
            if (mentionsParam(t, p.type)) break true;
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
const Fixture = @import("comptime_ctx.zig").Fixture;

/// The type that alias `name` of the fixture's module denotes.
fn aliasOf(f: *Fixture, name: []const u8) !TypeId {
    return (try f.items.info(.{ .module = 0, .item = f.g.modules[0].names.get(name).? })).alias;
}

test "`Ring<u32, 64>` is one instance; its fields are in terms of the arguments" {
    var f: Fixture = undefined;
    try f.init(
        \\pub struct Ring<T, CAP: usize> { items: [CAP]T, head: usize = 0, len: usize = 0 }
        \\type A = Ring<u32, 64>;
        \\type B = Ring<u32, 64>;
        \\type C = Ring<u32, 32>;
        \\type D = Ring<u8, 64>;
        \\const N: usize = 64;
        \\type E = Ring<u32, N>;
        \\fn first(r: Ring<u32, 64>) -> u32 { let n: usize = r.len; r.items[n] }
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    try f.expectComplete();
    const a = try aliasOf(&f, "A");
    try testing.expectEqual(a, try aliasOf(&f, "B"));
    try testing.expectEqual(a, try aliasOf(&f, "E"));
    try testing.expect(a != try aliasOf(&f, "C"));
    try testing.expect(a != try aliasOf(&f, "D"));
    // Ring<u32, 64>, Ring<u32, 32>, Ring<u8, 64>.
    try testing.expectEqual(3, f.items.memo.count());
    const s = f.items.structOf(a).?;
    try testing.expectEqual(0, s.generics.len);
    const items = f.types.get(s.fields[0].type).array;
    try testing.expectEqual(64, items.len);
    try testing.expectEqual(TypeId.int(.unsigned, 32), items.elem);
    const name = try f.types.allocPrint(testing.allocator, a, .{});
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("Ring<u32, 64>", name);
}

test "`Ring(u32, 64).init()` calls the method of that instance" {
    var f: Fixture = undefined;
    try f.init(
        \\pub struct Ring<T, CAP: usize> {
        \\    items: [CAP]T, len: usize = 0,
        \\    pub fn init() -> Self { Self { items: [0; CAP], len: 0 } }
        \\    pub fn cap(self) -> usize { CAP + self.len }
        \\    pub fn first(self) -> T { self.items[0] }
        \\}
        \\fn demo() -> usize {
        \\    let r = Ring(u32, 64).init();
        \\    let s: Ring<u32, 64> = Ring(u32, 64).init();
        \\    let t: Ring<u8, 4> = .init();
        \\    let x: u32 = r.first() + s.first();
        \\    r.cap() + t.cap() + x as usize
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    try f.expectComplete();
    // Two type instances, `init` and `cap` per instance, `first` once.
    var inits: usize = 0;
    var caps: usize = 0;
    for (f.bodies.fns.items) |b| if (b.func != null) {
        inits += @intFromBool(std.mem.eql(u8, b.name, "init"));
        caps += @intFromBool(std.mem.eql(u8, b.name, "cap"));
    };
    try testing.expectEqual(2, inits);
    try testing.expectEqual(2, caps);
    try testing.expectEqual(7, f.items.memo.count());
    const demo = f.bodies.find(0, "demo").?.func.?;
    try testing.expectEqual(TypeId.usize, demo.ret);
}

test "a non-plain argument of a `plain` parameter is E0329" {
    var f: Fixture = undefined;
    try f.init(
        \\@resource
        \\pub struct File { fd: i32, pub fn close(move self) {} }
        \\struct List<T: plain> { len: usize, first: T }
        \\struct Pair<A, B: plain> { a: A, b: B }
        \\type Files = List<File>;
        \\type Names = List<str>;
        \\type Ok1 = List<u32>;
        \\type Ok2 = Pair<File, vec4<f32>>;
        \\type Bad = Pair<u8, Atomic<u32>>;
    );
    defer f.deinit();
    try f.expectDiags(&.{ .{ .E0329, "List" }, .{ .E0329, "List" }, .{ .E0329, "Pair" } });
    try testing.expectEqual(TypeId.err, try aliasOf(&f, "Files"));
    try testing.expect(f.items.structOf(try aliasOf(&f, "Ok2")) != null);
}

test "the standard containers take plain elements" {
    var f: Fixture = undefined;
    try f.init(
        \\@resource
        \\pub struct File { fd: i32, pub fn close(move self) {} }
        \\type Cells = List<Atomic<u32>>;
        \\type Files = List<File>;
        \\type Ids = Bounded<Pool<u8>, 4>;
        \\type Ok = Pool<(u32, vec4<f32>)>;
    );
    defer f.deinit();
    try kinds.check(&f.items);
    try f.expectDiags(&.{ .{ .E0329, "List" }, .{ .E0329, "List" }, .{ .E0329, "Bounded" } });
}

test "instantiation deeper than 256 is E0812" {
    var f: Fixture = undefined;
    try f.init(
        \\struct Deep<T> { next: Handle<Deep<[1]T>>, value: T }
        \\fn depth(d: Deep<u8>) -> u8 { d.value }
    );
    defer f.deinit();
    try f.expectDiags(&.{.{ .E0812, "Deep" }});
    try testing.expectEqual(instantiate.max_depth, f.items.memo.count());
}

test "`Option<[]u8>` is a view, an instance holding it too" {
    var f: Fixture = undefined;
    try f.init(
        \\struct Wrap<T> { inner: Option<T> }
        \\type A = Option<[]u8>;
        \\type B = Wrap<[]u8>;
        \\type C = Wrap<u32>;
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    try testing.expectEqual(kinds.Kind.view, try kinds.kind(&f.items, try aliasOf(&f, "A")));
    try testing.expectEqual(kinds.Kind.view, try kinds.kind(&f.items, try aliasOf(&f, "B")));
    try testing.expectEqual(kinds.Kind.plain, try kinds.kind(&f.items, try aliasOf(&f, "C")));
}

test "generic enums: variants, patterns and `==` of instances" {
    var f: Fixture = undefined;
    try f.init(
        \\enum Maybe<T> { just(T), nothing }
        \\struct Pair<T> { a: T, b: T }
        \\fn get(m: Maybe<u32>) -> u32 {
        \\    match m { .just(x) => x, .nothing => 0 }
        \\}
        \\fn demo() -> u32 {
        \\    let p: Pair<u32> = .{ a: 1, b: 2 };
        \\    let .{ a, b } = p;
        \\    let q: Pair<u32> = .{ a, b };
        \\    let same = p == q;
        \\    let m = Maybe(u32).just(a);
        \\    if same { get(m) + get(.nothing) + b } else { 0 }
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    try f.expectComplete();
}

test "generic aliases and distinct types are instantiated" {
    var f: Fixture = undefined;
    try f.init(
        \\type Grid<T, N: usize> = [N][N]T;
        \\type Meters<T> = distinct T;
        \\type G = Grid<u8, 4>;
        \\type H = Grid<u8, 4>;
        \\type M = Meters<f32>;
        \\type K = Meters<f32>;
        \\type L = Meters<f64>;
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    const g = try aliasOf(&f, "G");
    try testing.expectEqual(g, try aliasOf(&f, "H"));
    try testing.expectEqual(4, f.types.get(f.types.get(g).array.elem).array.len);
    const m = try aliasOf(&f, "M");
    try testing.expectEqual(m, try aliasOf(&f, "K"));
    try testing.expect(m != try aliasOf(&f, "L"));
    try testing.expectEqual(TypeId.f32, f.types.get(m).nominal.underlying);
}

test "protocol bounds of type arguments are checked (E0373)" {
    var f: Fixture = undefined;
    try f.init(
        \\pub protocol Shape { fn area(self) -> f32; }
        \\struct Label { w: f32 }
        \\struct Square { w: f32 }
        \\impl Shape for Square { fn area(self) -> f32 { self.w * self.w } }
        \\struct Bag<T: Shape> { x: T }
        \\fn bad(b: Bag<Label>) -> f32 { b.x.w }
        \\fn good(b: Bag<Square>) -> f32 { b.x.area() }
    );
    defer f.deinit();
    try f.expectDiags(&.{.{ .E0373, "Bag" }});
}

test "field defaults and associated consts use the instance's arguments" {
    var f: Fixture = undefined;
    try f.init(
        \\struct Ring<T, CAP: usize> { items: [CAP]T, len: usize = CAP, const MASK: usize = CAP - 1; }
        \\enum Level<N: usize> { low, const TOP: usize = N + 1; }
        \\type A = Ring<u8, 8>;
        \\type L = Level<3>;
        \\fn masks() -> [A.MASK]u8 { [0; 7] }
        \\fn tops() -> [L.TOP]u8 { [0; 4] }
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    try f.expectComplete();
    const s = f.items.structOf(try aliasOf(&f, "A")).?;
    try testing.expectEqual(8, s.fields[1].default.?.scalar.bits);
    try testing.expectEqual(7, s.consts[0].value.scalar.bits);
}

test "instances are laid out: E0311 and `@c_layout` E1201" {
    var f: Fixture = undefined;
    try f.init(
        \\@c_layout
        \\struct R<T> { a: T }
        \\struct Ring<T, CAP: usize> { items: [CAP]T }
        \\type A = R<str>;
        \\type B = R<u32>;
        \\fn big(r: Ring<u32, 300000000000000>) {}
    );
    defer f.deinit();
    var lay: @import("layout.zig").Engine = .init(testing.allocator, &f.items);
    defer lay.deinit();
    try lay.check();
    try f.expectDiags(&.{ .{ .E1201, "T" }, .{ .E0311, "Ring" } });
}

test "a runtime generic value argument is E0801" {
    var f: Fixture = undefined;
    try f.init(
        \\struct Buf<N: usize> { bytes: [N]u8 }
        \\fn fill(n: usize, b: Buf<n>) {}
        \\fn ok(comptime n: usize) -> usize { n }
    );
    defer f.deinit();
    try f.expectDiags(&.{.{ .E0801, "n" }});
}
