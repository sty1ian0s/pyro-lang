//! Types as values and type functions (§8.3, §8.3.1, §8.3.2).
//!
//! A value of type `type` exists only at comptime. In a function body it is
//! a `comptime` TIR constant (`typeValue`) whose entry in the comptime value
//! table holds the type; outside comptime code it is E0802.
//!
//! A *type function* returns `type` (§8.3.1). Its body is comptime code:
//! it may only be called at comptime (E0802 otherwise, `checkCall`), and it
//! uses types as values freely. Its `comptime` parameters, types included,
//! are bound per call by `instantiate.zig`, so equal arguments (types by
//! identity, values by equality) share one instance in `Items.memo`, and
//! the instance returns the identical type.
//!
//! A `struct { ... }` expression (`anon_struct`) makes a new nominal struct
//! type (`structType`), identified by the expression and the instance it is
//! checked in. Its fields are resolved with the instance's parameters bound
//! (`CAP`, `T`) and recorded in `Items.generated` (`Generated`), where
//! `structOf` finds them. Names follow §8.3.2 (`mangle.zig`): the type an
//! instance of `F` returns prints as `F(args)` in diagnostics and is
//! `F__a1__a2…` in `--expand` output and lowering (`Generated.mangled`);
//! it gets these names when it leaves the instance (`returned`). Any other
//! struct expression is named by the `const` it is bound to, else
//! `struct`, in diagnostics (`alias`), and is `struct__N` (`F__a1…__struct__N`
//! inside an instance) for lowering, so mangled names stay unique.
//!
//! Every parameter of a type function is a comptime parameter, and every
//! call of one has an instance (`Items.signature`, `check_call.callFn`), so
//! that `F(3)` and `F(4)` are distinct instances named by their arguments.
//!
//! Anonymous `enum` expressions are reserved for a future edition (§8.3.1);
//! the parser rejects them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("../ast/Ast.zig");
const Types = @import("../sema/types.zig");
const items_mod = @import("../sema/items.zig");
const emit_tir = @import("../sema/emit_tir.zig");
const comptime_ctx = @import("../sema/comptime_ctx.zig");
const embed = @import("embed.zig");
const instantiate = @import("instantiate.zig");
const mangle = @import("mangle.zig");
const prelude = @import("../resolve/prelude.zig");
const ModuleId = @import("../resolve/module_graph.zig").ModuleId;

const Node = Ast.Node;
const TypeId = Types.TypeId;
const Items = items_mod.Items;
const Checker = emit_tir.Checker;
const Typed = emit_tir.Typed;
const Error = Allocator.Error;

/// A struct type made by a `struct { ... }` expression.
pub const Generated = struct {
    module: ModuleId,
    /// The `anon_struct` node.
    node: Node.Index,
    /// The instance it was made in, or `instantiate.no_instance`.
    instance: instantiate.Id,
    /// The declaration name of §8.3.2 (`SortedSoA__Monster__512`), for
    /// `--expand` and lowering. Diagnostics print the type itself.
    mangled: []const u8,
    /// How the type is named so far: `returned` and `alias` are final.
    naming: enum { anonymous, alias, returned } = .anonymous,
    /// Its fields; it has no generics, and members are not supported yet.
    decl: items_mod.Struct,
};

/// Generated types by type (`Items.generated`).
pub const Table = std.AutoHashMapUnmanaged(TypeId, *Generated);

/// The generated type `ty`, if it is one.
pub fn get(it: *const Items, ty: TypeId) ?*const Generated {
    return it.generated.get(ty);
}

/// The struct behind `ty`: a declared struct (`Items.structOf`) or a
/// generated one.
pub fn structOf(it: *Items, ty: TypeId) ?*const items_mod.Struct {
    if (get(it, ty)) |g| return &g.decl;
    return it.structOf(ty);
}

/// Whether the body being checked is comptime code: comptime evaluation or
/// a type function (§8.3.1).
fn comptimeBody(c: *const Checker) bool {
    return c.in_comptime or c.sig.ret == .type;
}

/// Whether prelude name `name` is a primitive type (§4, §14.1): built into
/// the compiler, so usable as a value without the standard library.
pub fn isPrimitive(name: []const u8) bool {
    if (prelude.isIntTypeName(name)) return true;
    for (prelude.entries) |e| if (std.mem.eql(u8, e.name, name)) return e.kind == .type and e.origin == .compiler;
    return false;
}

/// The handler of a type written as an expression (`u8`, `[N]T`, `[]T`):
/// the type, as a value.
pub fn typeExpr(c: *Checker, n: Node.Index, _: TypeId) Error!Typed {
    return typeValue(c, n, try c.items.resolveType(c.m, n, c.self_ty));
}

/// Type `t` used as a value at `n` (§8.3): a comptime constant, E0802
/// outside comptime code.
pub fn typeValue(c: *Checker, n: Node.Index, t: TypeId) Error!Typed {
    if (t == .err) {
        c.failed = true; // reported with the type
        return .err;
    }
    const cx = comptime_ctx.of(c.items) orelse return c.unsupported(n, "comptime evaluation without an evaluator");
    if (!comptimeBody(c) and !try embed.checkRuntime(c.items, c.m, c.ast.mainToken(n), .type)) {
        c.failed = true;
        return .err;
    }
    try cx.table.append(cx.gpa, .{ .ty = .type, .data = .{ .type = t } });
    return .{ .ty = .type, .ref = try c.emit(.type, .{ .@"comptime" = .{ .value = .from(cx.table.items.len - 1) } }) };
}

/// A call at `n` of a function returning `type`: false (reported) if it is
/// outside comptime code, where the type would reach runtime (E0802).
pub fn checkCall(c: *Checker, n: Node.Index) Error!bool {
    if (comptimeBody(c)) return true;
    if (try embed.checkRuntime(c.items, c.m, c.ast.mainToken(n), .type)) return true;
    c.failed = true;
    return false;
}

/// The `anon_struct` expression handler: the type, as a value.
pub fn anonStruct(c: *Checker, n: Node.Index, _: TypeId) Error!Typed {
    const t = try structType(c, n);
    if (c.failed) return .err;
    return typeValue(c, n, t);
}

/// The struct type that `struct { ... }` expression `n` makes in the
/// instance being checked (§8.3.1): one type per expression and instance.
pub fn structType(c: *Checker, n: Node.Index) Error!TypeId {
    const it = c.items;
    const m = c.m;
    const a = c.ast;
    const d = a.data(n).anon_struct;
    if (d.members.len > 0) {
        _ = c.unsupported(n, "methods and consts of generated types (T070)");
        return .err;
    }
    const inst = instantiate.current(it);
    const gpa = it.arena.allocator();
    // The instance identifies the type: the memo gives equal arguments one instance.
    const args: []const Types.Arg = if (inst == instantiate.no_instance) &.{} else try gpa.dupe(Types.Arg, &.{.{ .value = .{ .type = .int(.unsigned, 32), .bits = inst } }});
    const node_id = it.mods[m].base + n.int();
    const names: Names = if (inst == instantiate.no_instance)
        .{ .display = "struct", .mangled = try std.fmt.allocPrint(gpa, "struct__{d}", .{node_id}) }
    else
        .{ .display = "struct", .mangled = try std.fmt.allocPrint(gpa, "{s}__struct__{d}", .{ try mangle.instanceMangled(gpa, it, inst), node_id }) };
    const ty = try it.types.intern(.{ .nominal = .{
        .decl = .{ .package = it.options.package, .index = node_id },
        .args = args,
        .kind = .@"struct",
        .name = try it.types.strings.intern(names.display),
        .generated = true,
    } });
    if (get(it, ty) != null) return ty;
    const g = try gpa.create(Generated);
    g.* = .{ .module = m, .node = n, .instance = inst, .mangled = names.mangled, .decl = .{
        .type = ty,
        .generics = &.{},
        .fields = &.{},
        .consts = &.{},
        .methods = &.{},
        .attrs = &.{},
    } };
    // Present before its fields resolve, so that `Self` in a field finds it.
    try it.generated.put(gpa, ty, g);
    if (d.fields.len > items_mod.max_members) {
        try c.report(n, .E0311, "`{s}` has {d} fields; the maximum is {d}", .{ names.display, d.fields.len, items_mod.max_members });
        return .err;
    }
    const kinds = a.tokens.items(.kind);
    const fields = try gpa.alloc(items_mod.Field, d.fields.len);
    for (d.fields, fields) |fnode, *o| {
        const f, const attrs = if (a.kind(fnode) == .attributed) .{ a.data(fnode).attributed.inner, a.data(fnode).attributed.attrs } else .{ fnode, &.{} };
        const fd = a.data(f).field_decl;
        const mt = a.mainToken(f);
        const fty = try it.resolveType(m, fd.ty, ty);
        o.* = .{
            .node = f,
            .name = identText(a, mt),
            .vis = if (kinds[mt - 1] == .kw_mut and kinds[mt - 2] == .kw_pub) .pub_mut else if (kinds[mt - 1] == .kw_pub) .@"pub" else .private,
            .type = fty,
            // shortcut: a runtime name in a default is not E0370 here as in declared structs; share `Items.defaultValue` if it shows up.
            .default = if (fd.default) |def| try it.comptimeArg(m, def, ty, fty) else null,
            .attrs = attrs,
        };
    }
    g.decl.fields = fields;
    return ty;
}

const Names = struct { display: []const u8, mangled: []const u8 };

/// Type `t` was computed by a comptime evaluation (`comptime_ctx`): if it
/// is a struct made in an instance other than the evaluation's own, the
/// instance returned it, so it takes the instance's names `F(args)` and
/// `F__a1__a2…` (§8.3.2).
// shortcut: a type that leaves its instance other than as the result (reflection on a field type) is taken as returned; check the instance's result once reflection exists (T066).
pub fn returned(it: *Items, t: TypeId) Error!void {
    const g = it.generated.get(t) orelse return;
    if (g.naming == .returned or g.instance == instantiate.no_instance or g.instance == instantiate.current(it)) return;
    const gpa = it.arena.allocator();
    g.mangled = try mangle.instanceMangled(gpa, it, g.instance);
    it.types.rename(t, try it.types.strings.intern(try mangle.instanceDisplay(gpa, it, g.instance)));
    g.naming = .returned;
}

/// Type `t` is the value of `const` `name`: a struct not yet named is
/// named after it in diagnostics (§8.3.2).
pub fn alias(it: *Items, t: TypeId, name: []const u8) Error!void {
    const g = it.generated.get(t) orelse return;
    if (g.naming != .anonymous) return;
    it.types.rename(t, try it.types.strings.intern(name));
    g.naming = .alias;
}

/// The identifier an IDENT token names: `r#type` is `type` (§2.3).
fn identText(a: *const Ast, t: Ast.TokenIndex) []const u8 {
    const s = a.tokenSlice(t);
    return if (std.mem.startsWith(u8, s, "r#")) s[2..] else s;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const Fixture = comptime_ctx.Fixture;

/// The type const `name` holds.
fn constType(f: *Fixture, name: []const u8) !TypeId {
    const k = try f.constOf(name);
    if (k.value != .type) return error.TestUnexpectedResult;
    return k.value.type;
}

test "a type function applied to equal arguments returns the identical type" {
    var f: Fixture = undefined;
    try f.init(
        \\struct Monster { health: f32, threat: u32 }
        \\const N: usize = 512;
        \\pub fn SortedSoA(comptime T: type, comptime CAP: usize) -> type {
        \\    return struct {
        \\        len: usize = 0,
        \\        cols: soa [CAP]T,
        \\        order: [CAP]u32,
        \\    };
        \\}
        \\const A = SortedSoA(Monster, 512);
        \\const B = SortedSoA(Monster, N);
        \\const C = SortedSoA(Monster, 64);
        \\fn take(a: A, b: SortedSoA(Monster, 512)) -> usize { 7 }
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    try f.expectComplete();
    const a = try constType(&f, "A");
    try testing.expectEqual(a, try constType(&f, "B"));
    try testing.expect(a != try constType(&f, "C"));
    // One instance per distinct argument list.
    try testing.expectEqual(2, f.items.memo.count());
    const take = (try f.items.info(.{ .module = 0, .item = f.g.modules[0].names.get("take").? })).@"fn";
    try testing.expectEqual(a, take.params[0].type);
    try testing.expectEqual(a, take.params[1].type);
    // §8.3.2: the type's names.
    try testing.expectEqualStrings("SortedSoA(Monster, 512)", try f.items.tyName(a));
    try testing.expectEqualStrings("SortedSoA__Monster__512", get(&f.items, a).?.mangled);
    // The fields are resolved with the parameters bound.
    const s = structOf(&f.items, a).?;
    try testing.expectEqual(3, s.fields.len);
    try testing.expectEqualStrings("cols", s.fields[1].name);
    try testing.expectEqual(512, f.types.get(s.fields[2].type).array.len);
    try testing.expectEqual(0, s.fields[0].default.?.scalar.bits);
}

test "diagnostics name a generated type F(args)" {
    var f: Fixture = undefined;
    try f.init(
        \\fn Wrap(comptime T: type, comptime K: i32) -> type { struct { x: T } }
        \\const W = Wrap(u8, -3);
        \\fn bad(w: W) -> u32 { w }
    );
    defer f.deinit();
    const ds = f.p.sink.finish();
    try testing.expectEqual(1, ds.len);
    try testing.expectEqualStrings("mismatched types: expected `u32`, found `Wrap(u8, -3)`", ds[0].message);
    try testing.expectEqualStrings("Wrap__u8__m3", get(&f.items, try constType(&f, "W")).?.mangled);
}

test "types as values in comptime code; E0802 at runtime" {
    var f: Fixture = undefined;
    try f.init(
        \\struct P { x: u32 }
        \\const T: type = P;
        \\fn Same(comptime U: type) -> type { let v = U; v }
        \\fn Pair() -> type { struct { a: u8, b: u8 } }
        \\const S = Same(T);
        \\const Q = Pair();
        \\const R = Pair();
        \\fn leak() { let t = T; }
        \\fn call() { let t = Pair(); }
    );
    defer f.deinit();
    try f.expectDiags(&.{ .{ .E0802, "T" }, .{ .E0802, "(" } });
    try testing.expectEqual(try constType(&f, "T"), try constType(&f, "S"));
    const q = try constType(&f, "Q");
    try testing.expectEqual(q, try constType(&f, "R"));
    try testing.expectEqualStrings("Pair()", try f.items.tyName(q));
    try testing.expectEqualStrings("Pair", get(&f.items, q).?.mangled);
}

test "only the returned struct takes the instance's names; others stay unique" {
    var f: Fixture = undefined;
    try f.init(
        \\fn F(comptime T: type) -> type {
        \\    const Inner = struct { a: T };
        \\    struct { i: Inner, b: T }
        \\}
        \\const X = F(u8);
        \\const S = struct { a: u8 };
        \\const U = struct { a: u8 };
        \\fn bad(s: S) -> U { s }
    );
    defer f.deinit();
    const ds = f.p.sink.finish();
    try testing.expectEqual(1, ds.len);
    // §8.3.2: a struct bound to a `const` is named by it.
    try testing.expectEqualStrings("mismatched types: expected `U`, found `S`", ds[0].message);
    const x = try constType(&f, "X");
    try testing.expectEqualStrings("F(u8)", try f.items.tyName(x));
    try testing.expectEqualStrings("F__u8", get(&f.items, x).?.mangled);
    const inner = structOf(&f.items, x).?.fields[0].type;
    try testing.expect(inner != x);
    try testing.expectEqualStrings("Inner", try f.items.tyName(inner));
    const im = get(&f.items, inner).?.mangled;
    try testing.expect(std.mem.startsWith(u8, im, "F__u8__struct__"));
    try testing.expect(!std.mem.eql(u8, im, get(&f.items, x).?.mangled));
    try testing.expect(!std.mem.eql(u8, im, get(&f.items, try constType(&f, "S")).?.mangled));
}

test "§8.3: primitive and constructed types are values in type functions" {
    var f: Fixture = undefined;
    try f.init(
        \\fn Arr(comptime T: type, comptime N: usize) -> type { [N]T }
        \\fn Byte() -> type { let v = u8; v }
        \\const A = Arr(Byte(), 4);
        \\fn leak() { let t = u8; }
    );
    defer f.deinit();
    try f.expectDiags(&.{.{ .E0802, "u8" }});
    const a = try constType(&f, "A");
    try testing.expectEqual(4, f.types.get(a).array.len);
    try testing.expectEqual(TypeId.int(.unsigned, 8), f.types.get(a).array.elem);
}

test "every parameter of a type function is comptime: F(3) and F(4) differ" {
    var f: Fixture = undefined;
    try f.init(
        \\fn G(n: usize) -> type { struct { a: [n]u8 } }
        \\const A = G(3);
        \\const B = G(4);
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    const a = try constType(&f, "A");
    try testing.expect(a != try constType(&f, "B"));
    try testing.expectEqualStrings("G(3)", try f.items.tyName(a));
    try testing.expectEqualStrings("G__3", get(&f.items, a).?.mangled);
}
