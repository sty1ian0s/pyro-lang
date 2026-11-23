//! Type kinds (§5.1): every type is plain, a resource, a shared cell or a
//! view, computed after instantiation (`Option<[]u8>` is a view,
//! `Option<u32>` plain).
//!
//! `check` reports the kind rules of types written in item positions
//! (aliases, distinct types, struct fields, enum payloads, signatures):
//!
//! - a type holding both a resource and a view (§5.1, §5.4.1, **E0330**),
//!   and a view as an element of a standard container;
//! - a resource as an element of a fixed array or standard container
//!   (§5.3.1, **E0325**), and a shared cell as an element of a standard
//!   container (`T: plain`, §14.4, **E0329**);
//! - a `mask<N>` in a struct field or array (§4.3.2, **E0304**).
//!
//! `checkCopy` is the **E0328** hook of the expression checker. Views in
//! `const`s are E0341 (`items.zig`); captured views are the lambda
//! checker's; non-plain channel messages are E0505 (§10.4).

const std = @import("std");
const diag = @import("../diag/diag.zig");
const Ast = @import("../ast/Ast.zig");
const Types = @import("types.zig");
const items_mod = @import("items.zig");
const module_graph = @import("../resolve/module_graph.zig");

const Items = items_mod.Items;
const TypeId = Types.TypeId;
const ModuleId = module_graph.ModuleId;
const Error = std.mem.Allocator.Error;

/// The kind of a type (§5.1).
pub const Kind = enum { plain, resource, shared_cell, view };

/// What a type holds, transitively.
const Flags = struct {
    resource: bool = false,
    view: bool = false,
    shared: bool = false,

    fn merge(a: Flags, b: Flags) Flags {
        return .{ .resource = a.resource or b.resource, .view = a.view or b.view, .shared = a.shared or b.shared };
    }

    fn mixed(f: Flags) bool {
        return f.resource and f.view;
    }

    /// A resource wins over a shared cell (§5.1). §5.1 also says "a struct
    /// that contains a shared cell is itself a shared cell (unless it also
    /// contains a resource)", so a shared cell wins over a view: a type
    /// holding both must not be copied (E0328). View placement rules read
    /// `Flags.view`, not the kind.
    fn kind(f: Flags) Kind {
        return if (f.resource) .resource else if (f.shared) .shared_cell else if (f.view) .view else .plain;
    }
};

/// Memoized kinds, kept in `Items.kinds`. A null entry marks a type being
/// computed; meeting it again means a recursive type (E0376), which then
/// counts as holding nothing.
pub const Cache = struct {
    flags: std.AutoHashMapUnmanaged(TypeId, ?Flags) = .empty,
    /// The first problem in the fields and payloads of a generic instance.
    instances: std.AutoHashMapUnmanaged(TypeId, ?(?Problem)) = .empty,
};

// shortcut: the standard library is not loaded (T163), so its resources and
// containers (§14.4-§14.7, §10.4) are known by name; read `@resource` once it is.
const std_resources = std.StaticStringMap(void).initComptime(.{
    .{"Arena"}, .{"List"},   .{"Pool"},    .{"SparseMap"}, .{"Map"},         .{"Table"},     .{"Channel"},   .{"Sender"},
    .{"File"},  .{"Buffer"}, .{"Builder"}, .{"Command"},   .{"TcpListener"}, .{"TcpStream"}, .{"UdpSocket"},
});
const std_containers = std.StaticStringMap(void).initComptime(.{
    .{"List"}, .{"Pool"}, .{"SparseMap"}, .{"Map"}, .{"Bounded"}, .{"Table"},
});

/// The kind of `ty`. Generic parameters not yet substituted count as plain;
/// a failed type is plain.
pub fn kind(it: *Items, ty: TypeId) Error!Kind {
    return (try flagsOf(it, ty)).kind();
}

fn flagsOf(it: *Items, ty: TypeId) Error!Flags {
    const gpa = it.arena.allocator();
    const gop = try it.kinds.flags.getOrPut(gpa, ty);
    if (gop.found_existing) return gop.value_ptr.* orelse .{};
    gop.value_ptr.* = null;
    const f = try computeFlags(it, ty);
    try it.kinds.flags.put(gpa, ty, f); // the recursion may have moved `gop`
    return f;
}

fn computeFlags(it: *Items, ty: TypeId) Error!Flags {
    switch (it.types.get(ty)) {
        .simple => |s| return .{ .view = s == .str },
        .slice, .soa_slice, .mut_view => return .{ .view = true },
        .array => |x| return flagsOf(it, x.elem),
        .soa_array => |x| return flagsOf(it, x.elem),
        .tuple => |x| {
            var f: Flags = .{};
            for (x.elems) |e| f = f.merge(try flagsOf(it, e));
            return f;
        },
        .nominal => |n| {
            if (n.kind == .distinct) return flagsOf(it, n.underlying);
            if (n.lang == .atomic) return .{ .shared = true };
            var f: Flags = .{};
            if (isStd(it, n)) {
                if (std_resources.has(it.types.strings.get(n.name))) return .{ .resource = true };
                for (n.args) |arg| if (arg == .type) {
                    f = f.merge(try flagsOf(it, arg.type));
                };
                return f;
            }
            // shortcut: types of other packages are not loaded (T163) and count as plain.
            const ref = it.declRef(ty) orelse return f;
            switch ((try it.info(ref)).*) {
                .@"struct" => |s| {
                    f.resource = items_mod.hasAttr(astOf(it, ref.module), s.attrs, .resource);
                    for (s.fields) |fld| f = f.merge(try flagsOf(it, try it.subst(fld.type, n.decl, n.args)));
                },
                .@"enum" => |e| for (e.variants) |v| for (v.payload) |p| {
                    f = f.merge(try flagsOf(it, try it.subst(p, n.decl, n.args)));
                },
                else => {}, // protocols; declarations on a cycle
            }
            return f;
        },
        // Scalars, vectors, masks, handles, pointers, function pointers,
        // comptime-only types and unsubstituted parameters.
        else => return .{},
    }
}

fn isStd(it: *Items, n: Types.Nominal) bool {
    return std.meta.eql(n.decl.package, it.std_pkg);
}

fn astOf(it: *Items, m: ModuleId) *const Ast {
    return it.im.graph.modules[m].ast;
}

/// E0328 hook for the expression checker: using a place of type `ty` as a
/// value copies it, which a shared cell forbids (§5.1). Passing the place to
/// a read-only parameter passes a view and must not come here. Reports at
/// token `tok` of module `m` and returns whether the copy is allowed.
pub fn checkCopy(it: *Items, m: ModuleId, tok: Ast.TokenIndex, ty: TypeId) Error!bool {
    if ((try kind(it, ty)) != .shared_cell) return true;
    try it.report(m, tok, .E0328, &.{"use the cell through its methods (`load`, `store`, `fetch_add`) or pass it to a read-only parameter"}, "`{s}` is a shared cell and cannot be copied", .{try it.tyName(ty)});
    return false;
}

/// Checks the kinds of the types written in every item of `it` (see the
/// file comment). Run after `items.check`.
pub fn check(it: *Items) Error!void {
    for (it.im.graph.modules, 0..) |cm, mi| {
        const m: ModuleId = @intCast(mi);
        const a = cm.ast;
        for (cm.items, 0..) |item, i| switch ((try it.info(.{ .module = m, .item = @intCast(i) })).*) {
            .alias => |ty| try checkWritten(it, m, a.data(item.node).type_alias.ty, ty, false),
            .distinct => |ty| switch (it.types.get(ty)) {
                .nominal => |n| try checkWritten(it, m, a.data(item.node).type_distinct.ty, n.underlying, false),
                else => {},
            },
            .@"fn" => |f| try checkFn(it, m, f),
            .@"struct" => |s| {
                for (s.fields) |fld| try checkWritten(it, m, a.data(fld.node).field_decl.ty, fld.type, true);
                for (s.methods) |f| try checkFn(it, m, f);
                if (!(try flagsOf(it, s.type)).mixed()) continue;
                const first_view: ?struct { TypeId, Ast.Node.Index } = outer: for (s.fields) |fld| {
                    const fl = try flagsOf(it, fld.type);
                    if (fl.mixed()) break :outer null; // reported where its type is declared or written
                    if (fl.view) break :outer .{ fld.type, a.data(fld.node).field_decl.ty };
                } else null;
                if (first_view) |fv| try mixedDecl(it, m, fv[1], s.type, fv[0]);
            },
            .@"enum" => |e| {
                for (e.variants) |v| for (v.payload, payloadNodes(a, v.node)) |p, pn| try checkWritten(it, m, pn, p, false);
                for (e.methods) |f| try checkFn(it, m, f);
                if (!(try flagsOf(it, e.type)).mixed()) continue;
                const first_view: ?struct { TypeId, Ast.Node.Index } = outer: for (e.variants) |v| {
                    for (v.payload, payloadNodes(a, v.node)) |p, pn| {
                        const f = try flagsOf(it, p);
                        if (f.mixed()) break :outer null; // reported where `p` is declared or written
                        if (f.view) break :outer .{ p, pn };
                    }
                } else null;
                if (first_view) |fv| try mixedDecl(it, m, fv[1], e.type, fv[0]);
            },
            else => {},
        };
    }
}

fn payloadNodes(a: *const Ast, v: Ast.Node.Index) []const Ast.Node.Index {
    return a.data(v).variant_decl.payload orelse &.{};
}

fn checkFn(it: *Items, m: ModuleId, f: items_mod.Fn) Error!void {
    const a = astOf(it, m);
    for (f.params) |p| if (a.data(p.node).param.ty) |t| try checkWritten(it, m, t, p.type, false);
    if (a.data(f.node).fn_decl.ret) |r| try checkWritten(it, m, r, f.ret, false);
}

fn mixedDecl(it: *Items, m: ModuleId, node: Ast.Node.Index, owner: TypeId, view: TypeId) Error!void {
    try it.report(m, items_mod.typeToken(astOf(it, m), node), .E0330, &.{"a resource cannot hold a view: copy the data, or store an index or `Handle` into its owner"}, "`{s}` holds both a resource and a view (`{s}`)", .{ try it.tyName(owner), try it.tyName(view) });
}

/// A kind rule broken inside a written type.
const Problem = struct {
    code: diag.DiagCode,
    /// The type breaking the rule.
    outer: TypeId,
    /// The offending element (the type itself for E0304 and a mix).
    inner: TypeId,
};

/// Reports the first problem in type `ty` written at type node `node`.
/// `stored` is set where the value lives in memory (a struct field).
fn checkWritten(it: *Items, m: ModuleId, node: Ast.Node.Index, ty: TypeId, stored: bool) Error!void {
    const p = (try problem(it, ty, stored, 0)) orelse return;
    const tok = items_mod.typeToken(astOf(it, m), node);
    const outer = try it.tyName(p.outer);
    const inner = try it.tyName(p.inner);
    switch (p.code) {
        .E0304 => try it.report(m, tok, .E0304, &.{"masks live only in locals and registers; store the compared vectors, or a `bool` per lane"}, "`{s}` cannot be stored in a struct field or array", .{inner}),
        .E0329 => try it.report(m, tok, .E0329, &.{"the standard containers require plain element types (§14.4)"}, "`{s}` is not plain, but the elements of `{s}` must be", .{ inner, outer }),
        .E0325 => try it.report(m, tok, .E0325, &.{"keep the resources in a container of plain data and refer to them with `Handle`s"}, "resource `{s}` cannot be an element of `{s}`", .{ inner, outer }),
        else => if (p.inner == p.outer)
            try it.report(m, tok, .E0330, &.{"a type cannot contain both a resource and a view"}, "`{s}` holds both a resource and a view", .{outer})
        else
            try it.report(m, tok, .E0330, &.{"views live only in locals, parameters, results and other views"}, "view `{s}` cannot be an element of `{s}`", .{ inner, outer }),
    }
}

fn problem(it: *Items, ty: TypeId, stored: bool, depth: u32) Error!?Problem {
    if (depth > 64) return null; // generic instances that grow without end
    switch (it.types.get(ty)) {
        .mask => return if (stored) .{ .code = .E0304, .outer = ty, .inner = ty } else null,
        inline .array, .soa_array => |x| {
            if ((try kind(it, x.elem)) == .resource) return .{ .code = .E0325, .outer = ty, .inner = x.elem };
            return problem(it, x.elem, true, depth + 1);
        },
        inline .slice, .soa_slice => |x| return problem(it, x.elem, true, depth + 1),
        .mut_view => |x| return problem(it, x.elem, stored, depth + 1),
        .tuple => |x| {
            for (x.elems) |e| if (try problem(it, e, stored, depth + 1)) |p| return p;
        },
        .nominal => |n| {
            const container = isStd(it, n) and std_containers.has(it.types.strings.get(n.name));
            for (n.args) |arg| if (arg == .type) {
                if (try problem(it, arg.type, stored or container, depth + 1)) |p| return p;
                if (container) {
                    const f = try flagsOf(it, arg.type);
                    if (f.resource) return .{ .code = .E0325, .outer = ty, .inner = arg.type };
                    if (f.view) return .{ .code = .E0330, .outer = ty, .inner = arg.type };
                    // The containers' element parameters are `T: plain` (§14.4, §7.6.1).
                    if (f.shared) return .{ .code = .E0329, .outer = ty, .inner = arg.type };
                }
            };
            // A declaration that mixes for any arguments is reported where it is declared.
            if (n.args.len == 0) return null;
            if (!isStd(it, n)) {
                if (it.declRef(ty)) |ref| switch ((try it.info(ref)).*) {
                    inline .@"struct", .@"enum" => |d| if ((try flagsOf(it, d.type)).mixed()) return null,
                    else => {},
                };
                if (try instanceProblem(it, ty, n, depth)) |p| return p;
            }
        },
        else => return null,
    }
    return if ((try flagsOf(it, ty)).mixed()) .{ .code = .E0330, .outer = ty, .inner = ty } else null;
}

/// The first problem in the fields (stored) and payloads of generic
/// instance `ty`, after substituting its arguments (§5.1).
fn instanceProblem(it: *Items, ty: TypeId, n: Types.Nominal, depth: u32) Error!?Problem {
    const gpa = it.arena.allocator();
    const gop = try it.kinds.instances.getOrPut(gpa, ty);
    if (gop.found_existing) return gop.value_ptr.* orelse null;
    gop.value_ptr.* = null;
    const p: ?Problem = if (it.declRef(ty)) |ref| switch ((try it.info(ref)).*) {
        .@"struct" => |s| for (s.fields) |fld| {
            if (try problem(it, try it.subst(fld.type, n.decl, n.args), true, depth + 1)) |p| break p;
        } else null,
        .@"enum" => |e| outer: {
            for (e.variants) |v| for (v.payload) |pt| {
                if (try problem(it, try it.subst(pt, n.decl, n.args), false, depth + 1)) |p| break :outer p;
            };
            break :outer null;
        },
        else => null,
    } else null;
    try it.kinds.instances.put(gpa, ty, p);
    return p;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const Interner = @import("../base/Interner.zig");
const imports = @import("../resolve/imports.zig");
const names_mod = @import("../resolve/names.zig");

/// A package checked by `items.check` and `check`; build in place.
const Fixture = struct {
    p: module_graph.TestPackage,
    g: module_graph.Graph,
    im: imports.Imports,
    names: names_mod.Names,
    strings: Interner,
    types: Types,
    items: Items,

    fn init(f: *Fixture, src: []const u8) !void {
        f.p = try .init(&.{.{ "a", src }});
        f.g = try f.p.graph(.{ .kind = .lib });
        f.im = try imports.resolve(testing.allocator, &f.p.sink, &f.g, .{});
        f.names = try names_mod.resolve(testing.allocator, &f.p.sink, &f.im);
        f.strings = .init(testing.allocator, testing.io);
        f.types = try .init(testing.allocator, testing.io, &f.strings);
        const pkg: Types.Package = .{ .name = try f.strings.intern("app"), .line = .{ .major = 1 } };
        f.items = try items_mod.check(testing.allocator, &f.p.sink, &f.types, &f.im, &f.names, .{ .package = pkg });
        try check(&f.items);
    }

    fn deinit(f: *Fixture) void {
        f.items.deinit();
        f.types.deinit();
        f.strings.deinit();
        f.names.deinit();
        f.im.deinit();
        f.g.deinit();
        f.p.deinit();
    }

    /// Checks the reported codes and the source line of each primary span.
    fn expectDiags(f: *Fixture, want: []const struct { diag.DiagCode, []const u8 }) !void {
        const ds = f.p.sink.finish();
        errdefer for (ds) |d| std.debug.print("got {?t}: {s}\n", .{ d.code, d.message });
        try testing.expectEqual(want.len, ds.len);
        for (want, ds) |w, d| {
            try testing.expectEqual(@as(?diag.DiagCode, w[0]), d.code);
            const s = d.primarySpan().?;
            const src = f.p.asts[@backingInt(s.file)].source;
            const start = if (std.mem.lastIndexOfScalar(u8, src[0..s.start], '\n')) |i| i + 1 else 0;
            const end = std.mem.indexOfScalarPos(u8, src, s.start, '\n') orelse src.len;
            try testing.expectEqualStrings(w[1], std.mem.trim(u8, src[start..end], " "));
        }
    }

    fn item(f: *Fixture, name: []const u8) !*const items_mod.Info {
        return f.items.info(.{ .module = 0, .item = f.g.modules[0].names.get(name).? });
    }
};

test "kinds are computed after instantiation (§5.1)" {
    var f: Fixture = undefined;
    try f.init(
        \\@resource
        \\struct File { fd: i32 }
        \\enum IoError { closed }
        \\struct Stats { hits: Atomic<u64>, n: u32 }
        \\struct Both { s: Stats, f: File }
        \\struct Wrap<T> { x: T }
        \\enum Either<A, B> { left(A), right(B) }
        \\type Meters = distinct f32;
        \\fn probe(
        \\    a: Option<[]u8>, b: Option<u32>, c: Result<File, IoError>, d: Stats,
        \\    e: [4]Atomic<u32>, g: Wrap<str>, h: Wrap<u32>, i: Handle<File>,
        \\    j: *File, k: str, l: (u32, Stats), m: fn(u32) -> u32,
        \\    n: Either<u8, File>, o: Both, p: soa []Stats, q: Meters, r: vec<4, f32>, s: List<u32>
        \\) {}
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    const want = [_]Kind{
        .view,        .plain,    .resource,    .shared_cell,
        .shared_cell, .view,     .plain,       .plain,
        .plain,       .view,     .shared_cell, .plain,
        .resource,    .resource, .view,        .plain,
        .plain,       .resource,
    };
    const params = (try f.item("probe")).@"fn".params;
    try testing.expectEqual(want.len, params.len);
    for (want, params) |w, p| {
        errdefer std.debug.print("param `{s}`\n", .{p.name});
        try testing.expectEqual(w, try kind(&f.items, p.type));
    }
}

test "E0330: resource and view in one type" {
    var f: Fixture = undefined;
    try f.init(
        \\@resource
        \\struct Parser { input: str }
        \\@resource
        \\struct Buffer { fd: i32 }
        \\struct Reader { buf: Buffer, rest: []u8 }
        \\enum Msg { file(Buffer), text(str) }
        \\struct Pair<A, B> { a: A, b: B }
        \\fn split(x: (Buffer, str)) {}
        \\fn names() -> List<str> {}
        \\type P = Pair<Buffer, []u8>;
        \\fn reuse(r: Reader, p: Parser) {}
    );
    defer f.deinit();
    try f.expectDiags(&.{
        .{ .E0330, "struct Parser { input: str }" },
        .{ .E0330, "struct Reader { buf: Buffer, rest: []u8 }" },
        .{ .E0330, "enum Msg { file(Buffer), text(str) }" },
        .{ .E0330, "fn split(x: (Buffer, str)) {}" },
        .{ .E0330, "fn names() -> List<str> {}" },
        .{ .E0330, "type P = Pair<Buffer, []u8>;" },
    });
}

test "E0330 pass: views in locals, parameters, results, view types" {
    var f: Fixture = undefined;
    try f.init(
        \\@resource
        \\struct File { fd: i32 }
        \\struct Token { text: str, line: u32 }
        \\enum Piece { word(str), num(u32) }
        \\struct Pair<A, B> { a: A, b: B }
        \\fn halves(xs: []u8) -> ([]u8, []u8) {}
        \\fn maybe(xs: []u8) -> Option<[]u8> {}
        \\fn both(t: Token, f: File) -> Pair<File, u32> {}
        \\type Words = Pair<str, Token>;
    );
    defer f.deinit();
    try f.expectDiags(&.{});
}

test "E0325: resources in fixed arrays and containers" {
    var f: Fixture = undefined;
    try f.init(
        \\@resource
        \\pub struct File { fd: i32 }
        \\pub enum IoError { closed }
        \\type Files = [4]File;
        \\struct Rack {
        \\    slots: [2]File,
        \\    open: List<File>,
        \\    maybe: [3]Option<File>,
        \\}
        \\fn take(xs: Pool<Result<File, IoError>>) {}
    );
    defer f.deinit();
    try f.expectDiags(&.{
        .{ .E0325, "type Files = [4]File;" },
        .{ .E0325, "slots: [2]File," },
        .{ .E0325, "open: List<File>," },
        .{ .E0325, "maybe: [3]Option<File>," },
        .{ .E0325, "fn take(xs: Pool<Result<File, IoError>>) {}" },
    });
}

test "E0325 pass: resources as fields, tuple elements and payloads" {
    var f: Fixture = undefined;
    try f.init(
        \\@resource
        \\pub struct File { fd: i32 }
        \\pub enum IoError { closed }
        \\struct Rack { main: File, spare: (File, u32), ids: [4]i32, h: [4]Handle<File>, l: List<u32> }
        \\enum Slot { open(File), closed }
        \\fn first(r: Result<File, IoError>) -> Option<File> {}
    );
    defer f.deinit();
    try f.expectDiags(&.{});
}

test "E0304: masks only in locals" {
    var f: Fixture = undefined;
    try f.init(
        \\struct Hits {
        \\    lanes: mask<4>,
        \\    count: u32,
        \\    pair: (mask<8>, u8),
        \\}
        \\type MaskRow = [8]mask<4>;
        \\fn rows(r: []mask<2>) {}
        \\fn cmp(a: vec<4, f32>, m: mask<4>) -> mask<4> {}
        \\type M = mask<4>;
    );
    defer f.deinit();
    try f.expectDiags(&.{
        .{ .E0304, "lanes: mask<4>," },
        .{ .E0304, "pair: (mask<8>, u8)," },
        .{ .E0304, "type MaskRow = [8]mask<4>;" },
        .{ .E0304, "fn rows(r: []mask<2>) {}" },
    });
}

test "E0328: copying a shared cell; the hook allows other kinds" {
    var f: Fixture = undefined;
    try f.init(
        \\@resource
        \\struct File { fd: i32 }
        \\struct Stats { hits: Atomic<u64> }
        \\fn touch(s: Stats, n: Atomic<u64>, k: u32, f: File, c: [2]Atomic<u8>) {}
    );
    defer f.deinit();
    const params = (try f.item("touch")).@"fn".params;
    const a = astOf(&f.items, 0);
    const want = [_]bool{ false, false, true, true, false };
    for (params, want) |p, w| try testing.expectEqual(w, try checkCopy(&f.items, 0, a.mainToken(p.node), p.type));
    try f.expectDiags(&.{
        .{ .E0328, "fn touch(s: Stats, n: Atomic<u64>, k: u32, f: File, c: [2]Atomic<u8>) {}" },
        .{ .E0328, "fn touch(s: Stats, n: Atomic<u64>, k: u32, f: File, c: [2]Atomic<u8>) {}" },
        .{ .E0328, "fn touch(s: Stats, n: Atomic<u64>, k: u32, f: File, c: [2]Atomic<u8>) {}" },
    });
}

test "recursive types end (E0376) and kinds are memoized" {
    var f: Fixture = undefined;
    try f.init(
        \\struct T { a: T, b: T }
        \\struct G<X> { a: G<X>, b: G<X> }
        \\fn take(t: T, g: G<u8>) {}
    );
    defer f.deinit();
    const ds = f.p.sink.finish();
    try testing.expect(ds.len > 0);
    for (ds) |d| try testing.expectEqual(@as(?diag.DiagCode, .E0376), d.code);
    try testing.expectEqual(Kind.plain, try kind(&f.items, (try f.item("take")).@"fn".params[0].type));
}

test "kind rules apply to the fields of generic instances (§5.1)" {
    var f: Fixture = undefined;
    try f.init(
        \\@resource
        \\struct File { fd: i32 }
        \\struct Arr<T> { xs: [2]T }
        \\struct Box<T> { l: List<T> }
        \\struct W<T> { x: T }
        \\enum E<T> { one(List<T>), none }
        \\fn p1(a: Arr<File>) {}
        \\fn p2(b: Box<str>) {}
        \\fn p3(c: W<mask<4>>) {}
        \\fn p4(d: E<File>, e: W<W<mask<2>>>) {}
        \\fn ok(a: Arr<u8>, b: Box<u32>, c: W<str>, d: W<File>) {}
    );
    defer f.deinit();
    try f.expectDiags(&.{
        .{ .E0325, "fn p1(a: Arr<File>) {}" },
        .{ .E0330, "fn p2(b: Box<str>) {}" },
        .{ .E0304, "fn p3(c: W<mask<4>>) {}" },
        .{ .E0325, "fn p4(d: E<File>, e: W<W<mask<2>>>) {}" },
        .{ .E0304, "fn p4(d: E<File>, e: W<W<mask<2>>>) {}" },
    });
}

test "a shared cell with a view inside is a shared cell (§5.1, E0328)" {
    var f: Fixture = undefined;
    try f.init(
        \\struct S { a: Atomic<u32>, s: str }
        \\fn touch(s: S, l: List<S>) {}
    );
    defer f.deinit();
    const params = (try f.item("touch")).@"fn".params;
    try testing.expectEqual(Kind.shared_cell, try kind(&f.items, params[0].type));
    try testing.expect(!try checkCopy(&f.items, 0, astOf(&f.items, 0).mainToken(params[0].node), params[0].type));
    try f.expectDiags(&.{
        .{ .E0328, "fn touch(s: S, l: List<S>) {}" },
        .{ .E0330, "fn touch(s: S, l: List<S>) {}" },
    });
}
