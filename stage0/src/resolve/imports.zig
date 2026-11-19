//! Import resolution, the second phase of name resolution (§7.10 step 2).
//!
//! `resolve` walks the module graph (`module_graph.zig`) in topological
//! layers and binds every `use` of every module (§7.8.2): the first path
//! segment selects `std`, a dependency or the current package; `use a.b`
//! binds a module or item under its last segment (or its `as` name), and
//! `use a.b.{X, Y as Z}` binds items of module `a.b`. Only modules and `pub`
//! items can be imported (E0905), including names a module re-exports with
//! `pub use`, transitively. Two bindings of one name in a module are E0903,
//! and a local module named like a dependency is E0904.
//!
//! The result answers the module-level part of name lookup (§6.3.1): items,
//! then imports, then the implicit prelude (§7.8.4, §14.1). It also indexes
//! every `impl` block by the protocol and type it names, for the §7.9 rule
//! that an impl's methods are visible where both are nameable.
//!
//! Other packages' sources are not loaded here (multi-package compilation is
//! T163): an import from `std` or a dependency is bound as an `external` path.

const std = @import("std");
const Allocator = std.mem.Allocator;
const diag = @import("../diag/diag.zig");
const Ast = @import("../ast/Ast.zig");
const Compilation = @import("../driver/Compilation.zig");
const collect = @import("collect.zig");
const module_graph = @import("module_graph.zig");
const prelude = @import("prelude.zig");

const Node = Ast.Node;
const ModuleId = module_graph.ModuleId;
const Graph = module_graph.Graph;

/// An item of this package: index `item` of `Graph.modules[module].items`.
pub const Ref = struct {
    module: ModuleId,
    item: u32,

    fn eql(x: Ref, y: Ref) bool {
        return x.module == y.module and x.item == y.item;
    }
};

/// What a name denotes at module level.
pub const Target = union(enum) {
    /// A module of this package.
    module: ModuleId,
    /// An item of this package, where it is declared (`pub use` chains are followed).
    item: Ref,
    /// A module or item of `std` or a dependency, by its full dotted path.
    external: []const u8,
    /// A prelude name (§14.1): an `entries` name or an integer type name.
    prelude: []const u8,
    /// Not resolvable: the error was already reported, the name is inside an
    /// import cycle (E0902), or its module is not loaded (`Options.partial`).
    unresolved,
};

/// One name bound by a `use`.
pub const Binding = struct {
    name: []const u8,
    target: Target,
    /// Bound by `pub use`: other modules can import it from this one.
    is_pub: bool,
    /// The token that introduces the name: the `as` name, the list item, or
    /// the last path segment.
    span: diag.Span,
};

/// The imports of one module.
pub const Scope = struct {
    /// In source order, including ones rejected as E0903.
    bindings: []const Binding = &.{},
    /// Binding index by name; the first binding of a name wins.
    names: std.StringHashMapUnmanaged(u32) = .empty,

    fn get(s: *const Scope, name: []const u8) ?*const Binding {
        return &s.bindings[s.names.get(name) orelse return null];
    }
};

/// An `impl P for T` block (§7.5, §7.9).
pub const Impl = struct {
    module: ModuleId,
    /// The `impl_decl` node in `module`'s tree.
    node: Node.Index,
    /// What the protocol and the type name, from `module`. Null when the
    /// type is not a (generic) path: `*T`, `[]T`, `(A, B)`...
    protocol: ?Target,
    target: ?Target,
};

pub const Options = struct {
    /// Dependency names from `pyro.toml` (§7.8.2).
    dependencies: []const []const u8 = &.{},
    /// The package is `no_std`: the prelude is the core prelude (§14.1.1).
    no_std: bool = false,
    /// Only some modules of the package are loaded (single-file `pyro check`):
    /// an import of a package module that does not exist binds `unresolved`
    /// instead of reporting E0905.
    partial: bool = false,
};

/// The import scopes and impl index of one package. Borrows the graph.
pub const Imports = struct {
    arena: std.heap.ArenaAllocator,
    graph: *const Graph,
    /// `scopes[m]`: the imports of module `m`.
    scopes: []const Scope,
    impls: []const Impl,
    no_std: bool,

    pub fn deinit(im: *Imports) void {
        im.arena.deinit();
        im.* = undefined;
    }

    /// What `name` denotes at the top level of module `m`: one of its items,
    /// else one of its imports, else a prelude name (§6.3.1). Null if none.
    pub fn lookup(im: *const Imports, m: ModuleId, name: []const u8) ?Target {
        if (im.graph.modules[m].names.get(name)) |i| return .{ .item = .{ .module = m, .item = i } };
        if (im.scopes[m].get(name)) |b| return b.target;
        if (prelude.isIntTypeName(name)) return .{ .prelude = name };
        for (prelude.entries) |e| {
            if (std.mem.eql(u8, e.name, name) and !(im.no_std and e.hosted_only)) return .{ .prelude = e.name };
        }
        return null;
    }

    /// Whether module `m` can name `t` (§7.9): `t` is declared in `m`,
    /// imported by `m`, or a `pub` member of a module `m` imports.
    pub fn nameable(im: *const Imports, m: ModuleId, t: Target) bool {
        const ref = switch (t) {
            .item => |r| r,
            .unresolved => return false,
            // shortcut: std and dependency items are not loaded (T163) and the
            // prelude's `std` names every std module, so they count as nameable.
            else => return true,
        };
        if (ref.module == m) return true;
        for (im.scopes[m].bindings) |b| switch (b.target) {
            .item => |r| if (r.eql(ref)) return true,
            .module => |mm| if (im.exports(mm, ref)) return true,
            else => {},
        };
        return false;
    }

    /// Whether the methods of `impl` are visible in module `m` (§7.9): both
    /// the protocol and the type are nameable there. A type that is not a
    /// path (null) does not restrict visibility here.
    pub fn implVisible(im: *const Imports, m: ModuleId, impl: Impl) bool {
        const p = impl.protocol orelse return true;
        return im.nameable(m, p) and (impl.target == null or im.nameable(m, impl.target.?));
    }

    /// Whether module `mm` lets importers name item `ref`.
    fn exports(im: *const Imports, mm: ModuleId, ref: Ref) bool {
        if (ref.module == mm and im.graph.modules[mm].items[ref.item].is_pub) return true;
        for (im.scopes[mm].bindings) |b| {
            if (b.is_pub and b.target == .item and b.target.item.eql(ref)) return true;
        }
        return false;
    }
};

/// Resolves the imports of every module of `g`. Problems in the program
/// (E0903-E0905) are reported to `sink`; errors are internal failures only.
/// `g` must outlive the result.
pub fn resolve(gpa: Allocator, sink: *diag.Sink, g: *const Graph, options: Options) Allocator.Error!Imports {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var r: Resolver = .{
        .a = a,
        .sink = sink,
        .g = g,
        .options = options,
        .scopes = try a.alloc(Scope, g.modules.len),
        .done = try a.alloc(bool, g.modules.len),
    };
    @memset(r.scopes, .{});
    @memset(r.done, false);
    for (0..g.modules.len) |m| {
        try r.shadowedDependency(@intCast(m));
        try r.duplicateItems(@intCast(m));
    }
    // An import of a module from an earlier layer sees all of its bindings.
    for (g.layers) |layer| {
        for (layer) |m| {
            try r.module(m);
            r.done[m] = true;
        }
    }

    var im: Imports = .{ .arena = undefined, .graph = g, .scopes = r.scopes, .impls = &.{}, .no_std = options.no_std };
    im.impls = try r.implIndex(&im);
    im.arena = arena; // after the last arena allocation
    return im;
}

const Resolver = struct {
    a: Allocator,
    sink: *diag.Sink,
    g: *const Graph,
    options: Options,
    scopes: []Scope,
    /// The module's bindings are complete.
    done: []bool,
    /// Report problems; off while indexing impls, whose names `names.zig` reports.
    report: bool = true,

    fn isExternal(r: *const Resolver, head: []const u8) bool {
        if (std.mem.eql(u8, head, "std")) return true;
        for (r.options.dependencies) |d| if (std.mem.eql(u8, head, d)) return true;
        return false;
    }

    /// E0904: module `m`'s first path segment is a dependency name, so
    /// `use` paths could never reach it (§7.8.2).
    fn shadowedDependency(r: *Resolver, m: ModuleId) !void {
        const mod = &r.g.modules[m];
        const head = mod.path[0 .. std.mem.indexOfScalar(u8, mod.path, '.') orelse mod.path.len];
        if (std.mem.eql(u8, head, "std") or !r.isExternal(head)) return;
        try r.sink.emit(.{
            .code = .E0904,
            .severity = .of(.E0904),
            .message = try std.fmt.allocPrint(r.a, "module `{s}` has the name of the dependency `{s}`", .{ mod.path, head }),
            .spans = &.{.{ .span = .{ .file = mod.file, .start = 0, .end = 0 }, .primary = true }},
            .help = &.{"rename the module: a `use` path starting with a dependency's name always selects the dependency"},
        });
    }

    /// E0903 for every item whose name an earlier item of the module declares.
    fn duplicateItems(r: *Resolver, m: ModuleId) !void {
        const mod = &r.g.modules[m];
        for (mod.items, 0..) |it, i| {
            const first = mod.names.get(it.name).?;
            if (first == i) continue;
            try r.collision(
                try std.fmt.allocPrint(r.a, "`{s}` is declared twice in module `{s}`", .{ it.name, mod.path }),
                itemSpan(mod, it),
                "declared again here",
                itemSpan(mod, mod.items[first]),
                "first declared here",
                "rename one of the items",
            );
        }
    }

    fn collision(r: *Resolver, msg: []const u8, at: diag.Span, at_label: []const u8, prev: diag.Span, prev_label: []const u8, help: []const u8) !void {
        try r.sink.emit(.{
            .code = .E0903,
            .severity = .of(.E0903),
            .message = msg,
            .spans = &.{ .{ .span = at, .label = at_label, .primary = true }, .{ .span = prev, .label = prev_label } },
            .help = &.{help},
        });
    }

    /// Binds every `use` of module `m`.
    fn module(r: *Resolver, m: ModuleId) !void {
        const mod = &r.g.modules[m];
        const ast = mod.ast;
        var b: Builder = .{ .r = r, .m = m };
        for (mod.uses) |u| switch (ast.data(u.node)) {
            .use => |d| {
                const t = try r.path(m, u, d.path);
                try b.bind(d.alias orelse ast.data(d.path).path.last, t, u.is_pub);
            },
            .use_list => |d| {
                const base = try r.path(m, u, d.path);
                for (d.items) |it| {
                    if (ast.kind(it) != .use_item) continue; // poisoned by a parse error
                    const t = try r.member(m, base, ast.mainToken(it));
                    try b.bind(ast.data(it).use_item.alias orelse ast.mainToken(it), t, u.is_pub);
                }
            },
            else => unreachable, // `collect` records only `use` and `use_list`
        };
        r.scopes[m] = .{ .bindings = b.list.items, .names = b.names };
    }

    /// The target of the path of `use` `u` in module `m` (`d_path` is its node):
    /// another package's path, or the longest prefix that is a package module
    /// followed by member lookups for the remaining segments.
    fn path(r: *Resolver, m: ModuleId, u: collect.Use, d_path: Node.Index) !Target {
        const ast = r.g.modules[m].ast;
        const head = u.path[0 .. std.mem.indexOfScalar(u8, u.path, '.') orelse u.path.len];
        if (r.isExternal(head)) return .{ .external = u.path };
        var end = u.path.len;
        var rest: u32 = 0; // segments after the module prefix
        while (r.g.lookup(u.path[0..end]) == null) : (rest += 1) {
            end = std.mem.lastIndexOfScalar(u8, u.path[0..end], '.') orelse {
                if (!r.options.partial) try r.sink.emitAt(.E0905, u.span, try std.fmt.allocPrint(r.a, "`{s}` names no module of this package", .{u.path}));
                return .unresolved;
            };
        }
        var t: Target = .{ .module = r.g.lookup(u.path[0..end]).? };
        const last = ast.data(d_path).path.last;
        var tok = last + 2 - 2 * rest;
        while (tok <= last) : (tok += 2) t = try r.member(m, t, tok);
        return t;
    }

    /// Member `tok` (an IDENT of module `m`) of `base`, which must be a module (E0905).
    fn member(r: *Resolver, m: ModuleId, base: Target, tok: Ast.TokenIndex) !Target {
        const imp = &r.g.modules[m];
        const name = identText(imp.ast, tok);
        const span = tokenSpan(imp, tok);
        switch (base) {
            .external => |p| return .{ .external = try std.fmt.allocPrint(r.a, "{s}.{s}", .{ p, name }) },
            .unresolved => return .unresolved,
            .item, .prelude => {
                if (r.report) try r.sink.emit(.{
                    .code = .E0905,
                    .severity = .of(.E0905),
                    .message = try std.fmt.allocPrint(r.a, "cannot import `{s}` from an item: only modules and their `pub` items can be imported", .{name}),
                    .spans = &.{.{ .span = span, .primary = true }},
                });
                return .unresolved;
            },
            .module => |mm| {
                const mod = &r.g.modules[mm];
                var private = false;
                if (mod.names.get(name)) |i| {
                    if (mod.items[i].is_pub or mm == m) return .{ .item = .{ .module = mm, .item = i } };
                    private = true;
                } else {
                    if (!r.done[mm]) return .unresolved; // same import cycle, already E0902
                    if (r.scopes[mm].get(name)) |b| {
                        if (b.is_pub or mm == m) return b.target;
                        private = true;
                    }
                }
                if (!r.report) return .unresolved;
                try r.sink.emit(.{
                    .code = .E0905,
                    .severity = .of(.E0905),
                    .message = if (private)
                        try std.fmt.allocPrint(r.a, "`{s}` is private to module `{s}`", .{ name, mod.path })
                    else
                        try std.fmt.allocPrint(r.a, "module `{s}` has no public item `{s}`", .{ mod.path, name }),
                    .spans = &.{.{ .span = span, .primary = true }},
                    .help = if (private) &.{"declare it `pub` (or `pub use` it) in that module to import it"} else &.{},
                });
                return .unresolved;
            },
        }
    }

    /// Every `impl` block of the package with what its protocol and type name.
    fn implIndex(r: *Resolver, im: *const Imports) ![]const Impl {
        r.report = false;
        var list: std.ArrayList(Impl) = .empty;
        for (r.g.modules, 0..) |mod, mi| {
            const ast = mod.ast;
            if (ast.nodes.len == 0) continue;
            for (ast.data(.from(0)).root.items) |item| {
                const n = if (ast.kind(item) == .attributed) ast.data(item).attributed.inner else item;
                const d = switch (ast.data(n)) {
                    .impl_decl => |d| d,
                    else => continue,
                };
                const m: ModuleId = @intCast(mi);
                try list.append(r.a, .{ .module = m, .node = n, .protocol = try r.typeHead(im, m, d.protocol), .target = try r.typeHead(im, m, d.target) });
            }
        }
        return list.items;
    }

    /// What the path of type `ty` (`a.B`, `B<T>`) denotes in module `m`; null if `ty` is no path.
    fn typeHead(r: *Resolver, im: *const Imports, m: ModuleId, ty: Node.Index) !?Target {
        const ast = r.g.modules[m].ast;
        const p = if (ast.kind(ty) == .generic_inst) ast.data(ty).generic_inst.base else ty;
        if (ast.kind(p) != .path) return null;
        var tok = ast.mainToken(p);
        var t = im.lookup(m, identText(ast, tok)) orelse return .unresolved;
        while (tok < ast.data(p).path.last) {
            tok += 2;
            t = try r.member(m, t, tok);
        }
        return t;
    }
};

/// Accumulates one module's bindings, reporting E0903 collisions.
const Builder = struct {
    r: *Resolver,
    m: ModuleId,
    list: std.ArrayList(Binding) = .empty,
    names: std.StringHashMapUnmanaged(u32) = .empty,

    fn bind(b: *Builder, tok: Ast.TokenIndex, t: Target, is_pub: bool) !void {
        const r = b.r;
        const mod = &r.g.modules[b.m];
        const name = identText(mod.ast, tok);
        const span = tokenSpan(mod, tok);
        const gop = try b.names.getOrPut(r.a, name);
        if (mod.find(name)) |it| {
            try r.collision(
                try std.fmt.allocPrint(r.a, "the import `{s}` collides with the item `{s}` of module `{s}`", .{ name, name, mod.path }),
                span,
                "imported here",
                itemSpan(mod, it.*),
                "item declared here",
                "rename the import with `as`",
            );
        } else if (gop.found_existing) {
            try r.collision(
                try std.fmt.allocPrint(r.a, "two imports bind the name `{s}`", .{name}),
                span,
                "imported again here",
                b.list.items[gop.value_ptr.*].span,
                "first imported here",
                "rename one of the imports with `as`",
            );
        }
        if (!gop.found_existing) gop.value_ptr.* = @intCast(b.list.items.len);
        try b.list.append(r.a, .{ .name = name, .target = t, .is_pub = is_pub, .span = span });
    }
};

/// The identifier an IDENT token names: `r#type` is `type` (§2.3).
fn identText(ast: *const Ast, t: Ast.TokenIndex) []const u8 {
    const s = ast.tokenSlice(t);
    return if (std.mem.startsWith(u8, s, "r#")) s[2..] else s;
}

fn tokenSpan(mod: *const collect.Module, t: Ast.TokenIndex) diag.Span {
    const start = mod.ast.tokens.items(.start)[t];
    return .{ .file = mod.file, .start = start, .end = start + mod.ast.tokens.items(.len)[t] };
}

/// The span of an item's name (the token after its keyword, see `Ast.zig`).
fn itemSpan(mod: *const collect.Module, it: collect.Item) diag.Span {
    return tokenSpan(mod, mod.ast.mainToken(it.node) + 1);
}

/// `resolve` hook for single-file `pyro check`: each input file is the root
/// module of its own package, of which only that file is loaded
/// (`Options.partial`). Package mode registers the graph and import stages
/// with the package's manifest instead (T163).
pub fn runFiles(_: ?*anyopaque, comp: *Compilation) anyerror!void {
    const sep = std.fs.path.sep_str;
    for (comp.files.items) |*f| {
        if (f.poisoned) continue;
        const in: module_graph.Input = .{ .module = .{ .path = "main", .file = "src" ++ sep ++ "main.pr" }, .file = f.id, .ast = &f.ast };
        var g = try module_graph.build(comp.gpa, &comp.sink, &.{in}, .{ .kind = .exe });
        defer g.deinit();
        var im = try resolve(comp.gpa, &comp.sink, &g, .{ .partial = true });
        im.deinit();
    }
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const TestPackage = module_graph.TestPackage;

/// Resolves the package `mods` and checks the reported (code, message) pairs.
fn expectDiags(mods: []const [2][]const u8, options: Options, want: []const struct { diag.DiagCode, []const u8 }) !void {
    var p: TestPackage = try .init(mods);
    defer p.deinit();
    var g = try p.graph(.{ .kind = .exe, .dependencies = options.dependencies });
    defer g.deinit();
    var im = try resolve(testing.allocator, &p.sink, &g, options);
    defer im.deinit();
    const ds = p.sink.finish();
    errdefer for (ds) |d| std.debug.print("got {?t}: {s}\n", .{ d.code, d.message });
    try testing.expectEqual(want.len, ds.len);
    for (want, ds) |w, d| {
        try testing.expectEqual(w[0], d.code.?);
        try testing.expectEqualStrings(w[1], d.message);
    }
}

/// The text of `d`'s primary span in package `p`.
fn primaryText(p: *const TestPackage, d: diag.Diagnostic) []const u8 {
    const s = d.primarySpan().?;
    return p.asts[@backingInt(s.file)].source[s.start..s.end];
}

test "E0903: duplicate items, two imports of one name, an import colliding with an item" {
    var p: TestPackage = try .init(&.{
        .{
            "main",
            \\use std.math;
            \\use std.mem as math;
            \\use util.{f, g as f};
            \\use util.h;
            \\fn h() {}
            \\const N: u32 = 1;
            \\const N: u32 = 2;
            \\pub fn main() {}
        },
        .{ "util", "pub fn f() {}\npub fn g() {}\npub fn h() {}" },
    });
    defer p.deinit();
    var g = try p.graph(.{ .kind = .exe });
    defer g.deinit();
    var im = try resolve(testing.allocator, &p.sink, &g, .{});
    defer im.deinit();
    const ds = p.sink.finish();
    const want = [_]struct { []const u8, []const u8 }{
        .{ "two imports bind the name `math`", "math" },
        .{ "two imports bind the name `f`", "f" },
        .{ "the import `h` collides with the item `h` of module `main`", "h" },
        .{ "`N` is declared twice in module `main`", "N" },
    };
    try testing.expectEqual(want.len, ds.len);
    for (want, ds) |w, d| {
        try testing.expectEqual(diag.DiagCode.E0903, d.code.?);
        try testing.expectEqualStrings(w[0], d.message);
        try testing.expectEqualStrings(w[1], primaryText(&p, d));
        try testing.expectEqual(2, d.spans.len);
    }
    // The second `math` and the second `N` are the reported ones.
    const src = p.asts[0].source;
    try testing.expectEqual(std.mem.indexOf(u8, src, "math;\nuse util").?, ds[0].primarySpan().?.start);
    try testing.expectEqual(std.mem.lastIndexOf(u8, src, "N:").?, ds[3].primarySpan().?.start);
}

test "E0903: renaming with `as` resolves a collision; one module under two names is fine" {
    try expectDiags(&.{.{
        "main",
        \\use std.math;
        \\use std.math as m;
        \\use std.mem as memory;
        \\const mem: u32 = 1;
    }}, .{}, &.{});
}

test "E0904: a local module named like a dependency" {
    try expectDiags(&.{
        .{ "main", "use util;\nuse helpers;" },
        .{ "util", "" },
        .{ "helpers", "" },
    }, .{ .dependencies = &.{"util"} }, &.{
        .{ .E0904, "module `util` has the name of the dependency `util`" },
    });
}

test "E0905: private items, missing items and modules, members of items" {
    try expectDiags(&.{
        .{
            "main",
            \\use shapes.{area, Square, nothing};
            \\use shapes.area.x;
            \\use shapes.helper;
            \\use nowhere.f;
            \\use shapes.Square.{side};
        },
        .{ "shapes", "use std.math as helper;\nfn area() {}\npub struct Square { pub side: f32 }" },
    }, .{}, &.{
        .{ .E0905, "`area` is private to module `shapes`" },
        .{ .E0905, "module `shapes` has no public item `nothing`" },
        .{ .E0905, "`area` is private to module `shapes`" },
        .{ .E0905, "`helper` is private to module `shapes`" },
        .{ .E0905, "`nowhere.f` names no module of this package" },
        .{ .E0905, "cannot import `side` from an item: only modules and their `pub` items can be imported" },
    });
}

test "transitive `pub use`; a private `use` does not re-export" {
    var p: TestPackage = try .init(&.{
        .{ "main", "use geometry.{area, Square};\nuse outer.area as a2;\nuse geometry;\nuse priv.area as a3;" },
        .{ "geometry", "pub use shapes.{area, Square};" },
        .{ "outer", "pub use geometry.area;" },
        .{ "priv", "use shapes.area;" },
        .{ "shapes", "pub struct Square {}\npub fn area(s: Square) -> f32 { 1.0 }" },
    });
    defer p.deinit();
    var g = try p.graph(.{ .kind = .exe });
    defer g.deinit();
    var im = try resolve(testing.allocator, &p.sink, &g, .{});
    defer im.deinit();
    const ds = p.sink.finish();
    try testing.expectEqual(1, ds.len);
    try testing.expectEqualStrings("`area` is private to module `priv`", ds[0].message);

    const main = g.lookup("main").?;
    const shapes = g.lookup("shapes").?;
    const area: Target = .{ .item = .{ .module = shapes, .item = 1 } };
    try testing.expectEqualDeep(area, im.lookup(main, "area").?);
    try testing.expectEqualDeep(area, im.lookup(main, "a2").?);
    try testing.expectEqualDeep(Target.unresolved, im.lookup(main, "a3").?);
    try testing.expectEqualDeep(Target{ .module = g.lookup("geometry").? }, im.lookup(main, "geometry").?);
    try testing.expectEqualDeep(Target{ .item = .{ .module = shapes, .item = 0 } }, im.lookup(main, "Square").?);
}

test "lookup: items, then imports, then the prelude; no_std gets the core prelude" {
    var p: TestPackage = try .init(&.{.{ "main", "use std.math;\nuse dep.x.{Y as Z};\nstruct Option {}" }});
    defer p.deinit();
    var g = try p.graph(.{ .kind = .exe, .dependencies = &.{"dep"} });
    defer g.deinit();
    var im = try resolve(testing.allocator, &p.sink, &g, .{ .dependencies = &.{"dep"} });
    defer im.deinit();
    try testing.expectEqual(0, p.sink.finish().len);
    try testing.expectEqualDeep(Target{ .item = .{ .module = 0, .item = 0 } }, im.lookup(0, "Option").?);
    try testing.expectEqualStrings("std.math", im.lookup(0, "math").?.external);
    try testing.expectEqualStrings("dep.x.Y", im.lookup(0, "Z").?.external);
    for ([_][]const u8{ "Result", "i32", "u64", "print", "std", "Display" }) |n| try testing.expectEqualStrings(n, im.lookup(0, n).?.prelude);
    try testing.expectEqual(null, im.lookup(0, "i65"));
    try testing.expectEqual(null, im.lookup(0, "Y"));
    im.no_std = true;
    try testing.expectEqual(null, im.lookup(0, "print"));
    try testing.expectEqual(null, im.lookup(0, "List"));
    try testing.expectEqualStrings("Bounded", im.lookup(0, "Bounded").?.prelude);
}

test "impl index: methods visible where both protocol and type are nameable" {
    var p: TestPackage = try .init(&.{
        .{ "proto", "pub protocol Shape {}" },
        .{ "ty", "pub struct Sq {}" },
        .{ "impls", "use proto.Shape;\nuse ty;\nimpl Shape for ty.Sq {}\n@inline impl Display for Generic<u32> {}\nstruct Generic<T> {}" },
        .{ "both", "use proto;\nuse ty.{Sq};" },
        .{ "only_ty", "use ty.Sq;" },
        .{ "reexp", "use outer.{Shape};\nuse ty.Sq;" },
        .{ "outer", "pub use proto.Shape;" },
    });
    defer p.deinit();
    var g = try p.graph(.{ .kind = .lib });
    defer g.deinit();
    var im = try resolve(testing.allocator, &p.sink, &g, .{});
    defer im.deinit();
    try testing.expectEqual(0, p.sink.finish().len);
    try testing.expectEqual(2, im.impls.len);
    const shape = im.impls[0];
    try testing.expectEqualDeep(Target{ .item = .{ .module = g.lookup("proto").?, .item = 0 } }, shape.protocol.?);
    try testing.expectEqualDeep(Target{ .item = .{ .module = g.lookup("ty").?, .item = 0 } }, shape.target.?);
    try testing.expect(im.implVisible(g.lookup("impls").?, shape));
    try testing.expect(im.implVisible(g.lookup("both").?, shape));
    try testing.expect(im.implVisible(g.lookup("reexp").?, shape));
    try testing.expect(!im.implVisible(g.lookup("only_ty").?, shape));
    try testing.expect(!im.implVisible(g.lookup("proto").?, shape));
    // A prelude protocol for a private generic type: visible only in its module.
    const display = im.impls[1];
    try testing.expectEqualStrings("Display", display.protocol.?.prelude);
    try testing.expect(im.implVisible(g.lookup("impls").?, display));
    try testing.expect(!im.implVisible(g.lookup("both").?, display));
}

test "an import cycle leaves the bindings it needs unresolved, without cascades" {
    try expectDiags(&.{
        // `a` binds `w` before `b` is resolved, so neither `w` resolves.
        .{ "a", "pub use b.{w};" },
        .{ "b", "pub use a.{w};" },
    }, .{}, &.{
        .{ .E0902, "cyclic module imports: a → b → a" },
    });
}

test "runFiles: single files resolve alone; missing package modules are not errors" {
    var comp: Compilation = undefined;
    try comp.init(testing.allocator, testing.io, .{ .jobs = 1, .stop_after = .check });
    defer comp.deinit();
    try comp.addHook(.resolve, .{ .run = runFiles });
    _ = try comp.addSource("a.pr", "use std.math;\nconst math: u32 = 1;\n");
    _ = try comp.addSource("b.pr", "use shapes.{area};\nuse other;\npub fn main() {}\n");
    try comp.run();
    const ds = comp.sink.finish();
    try testing.expectEqual(1, ds.len);
    try testing.expectEqual(diag.DiagCode.E0903, ds[0].code.?);
    try testing.expectEqual(comp.files.items[0].id, ds[0].primarySpan().?.file);
}
