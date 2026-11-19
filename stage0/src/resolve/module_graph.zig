//! The module graph of one package (§7.8.1, §7.8.3, §7.10 step 1).
//!
//! `build` collects every module (`collect.zig`), checks module paths (E0901),
//! turns `use` and `pub use` declarations into edges between the package's own
//! modules, rejects every import cycle with its full chain (E0902), and orders the
//! modules in topological layers: a module's imports are all in earlier layers,
//! so import resolution (§7.10 step 2) can run layer by layer, and the modules
//! of one layer are independent. Each module appears exactly once however many
//! modules import it (diamonds).
//!
//! `Stage` runs `build` as the `resolve` hook of a `Compilation`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const diag = @import("../diag/diag.zig");
const Ast = @import("../ast/Ast.zig");
const layout = @import("../pkg/layout.zig");
const Compilation = @import("../driver/Compilation.zig");
const collect = @import("collect.zig");

/// Index into `Graph.modules`.
pub const ModuleId = u32;

/// An import of one package module by another.
pub const Edge = struct {
    target: ModuleId,
    /// The first `use` of the importing module that names `target` (index into its `uses`).
    use: u32,
};

/// One module to collect.
pub const Input = struct {
    /// Module path and file as `layout.open` found them.
    module: layout.Module,
    file: diag.FileId,
    /// The parsed file; empty (no nodes) if the file was poisoned.
    ast: *const Ast,
};

/// How to read the package's modules.
pub const Options = struct {
    /// Decides the root module: `main` for executables, `lib` for libraries (§7.8.1).
    kind: layout.Kind,
    /// Dependency names from `pyro.toml`. A `use` whose first segment is one of
    /// these or `std` names another package and adds no edge (§7.8.2).
    dependencies: []const []const u8 = &.{},
};

/// The module graph of one package. Owns its module paths; borrows each
/// input's `Ast`, which must outlive the graph.
pub const Graph = struct {
    arena: std.heap.ArenaAllocator,
    /// Every input module, sorted by module path.
    modules: []const collect.Module,
    /// `edges[m]`: the package modules `m` imports, each once, in `use` order.
    edges: []const []const Edge,
    /// The root module, if the package has one.
    root: ?ModuleId,
    /// Topological layers: every import of a module in layer `i` is in a layer
    /// before `i`. Modules of one import cycle share a layer. Each module is in
    /// exactly one layer; each layer is sorted by module path.
    layers: []const []const ModuleId,
    /// Module by path; modules whose path failed E0901 are absent, so they cannot be imported.
    by_path: std.StringHashMapUnmanaged(ModuleId),
    /// An E0902 was reported.
    has_cycle: bool,

    /// Frees everything the graph owns.
    pub fn deinit(g: *Graph) void {
        g.arena.deinit();
        g.* = undefined;
    }

    /// The module with dotted path `path`, if it exists in this package.
    pub fn lookup(g: *const Graph, path: []const u8) ?ModuleId {
        return g.by_path.get(path);
    }
};

/// The root module's path for package kind `kind` (`src/main.pr` or `src/lib.pr`).
pub fn rootPath(kind: layout.Kind) []const u8 {
    return switch (kind) {
        .exe => "main",
        .lib => "lib",
    };
}

/// Builds the module graph of `inputs`. Problems in the program (E0901,
/// E0902) are reported to `sink`; errors are internal failures only.
/// The graph copies the module paths and borrows the inputs' trees.
pub fn build(gpa: Allocator, sink: *diag.Sink, inputs: []const Input, options: Options) Allocator.Error!Graph {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const sorted = try a.dupe(Input, inputs);
    std.mem.sort(Input, sorted, {}, struct {
        fn lt(_: void, x: Input, y: Input) bool {
            return std.mem.lessThan(u8, x.module.path, y.module.path);
        }
    }.lt);

    const modules = try a.alloc(collect.Module, sorted.len);
    var by_path: std.StringHashMapUnmanaged(ModuleId) = .empty;
    for (sorted, modules, 0..) |in, *m, i| {
        const path = try a.dupe(u8, in.module.path);
        m.* = try collect.collect(a, path, in.file, in.ast);
        // `file` is `<root dir>/<rel>`: check `rel` (src/ or tests/ stripped).
        const f = in.module.file;
        const rel = if (std.mem.indexOfScalar(u8, f, std.fs.path.sep)) |k| f[k + 1 ..] else f;
        if (try collect.checkPath(sink, in.file, rel)) try by_path.put(a, path, @intCast(i));
    }

    const edges = try a.alloc([]const Edge, modules.len);
    for (modules, edges) |m, *out| {
        var list: std.ArrayList(Edge) = .empty;
        for (m.uses, 0..) |u, ui| {
            const t = target(&by_path, options, u.path) orelse continue;
            for (list.items) |e| {
                if (e.target == t) break;
            } else try list.append(a, .{ .target = t, .use = @intCast(ui) });
        }
        out.* = list.items;
    }

    var g: Graph = .{
        .arena = undefined,
        .modules = modules,
        .edges = edges,
        .root = by_path.get(rootPath(options.kind)),
        .layers = &.{},
        .by_path = by_path,
        .has_cycle = false,
    };
    try order(a, sink, &g);
    g.arena = arena; // after the last arena allocation
    return g;
}

/// The package module that import path `path` (`a.b`, `a.b.Item`) names: its
/// longest prefix that is a module. Null for another package or no module.
fn target(by_path: *const std.StringHashMapUnmanaged(ModuleId), options: Options, path: []const u8) ?ModuleId {
    const first = path[0 .. std.mem.indexOfScalar(u8, path, '.') orelse path.len];
    if (std.mem.eql(u8, first, "std")) return null;
    for (options.dependencies) |d| if (std.mem.eql(u8, first, d)) return null;
    var end = path.len;
    while (true) {
        if (by_path.get(path[0..end])) |id| return id;
        end = std.mem.lastIndexOfScalar(u8, path[0..end], '.') orelse return null;
    }
}

/// Tarjan's algorithm over `g.edges`: fills `g.layers` and reports the
/// cycles of every cyclic strongly connected component (E0902).
fn order(a: Allocator, sink: *diag.Sink, g: *Graph) Allocator.Error!void {
    const n = g.modules.len;
    const unvisited = std.math.maxInt(u32);
    var t: Tarjan = .{
        .a = a,
        .sink = sink,
        .g = g,
        .index = try a.alloc(u32, n),
        .low = try a.alloc(u32, n),
        .on_stack = try a.alloc(bool, n),
        .scc_of = try a.alloc(u32, n),
        .scc_layer = try a.alloc(u32, n),
        .parent = try a.alloc(u32, n),
    };
    @memset(t.index, unvisited);
    @memset(t.on_stack, false);
    @memset(t.scc_of, unvisited);
    for (0..n) |v| if (t.index[v] == unvisited) try t.visit(@intCast(v));

    var count: u32 = 0;
    for (t.scc_of) |s| count = @max(count, t.scc_layer[s] + 1);
    const layers = try a.alloc(std.ArrayList(ModuleId), count);
    @memset(layers, .empty);
    for (t.scc_of, 0..) |s, m| try layers[t.scc_layer[s]].append(a, @intCast(m));
    const out = try a.alloc([]const ModuleId, count);
    for (layers, out) |l, *o| o.* = l.items;
    g.layers = out;
}

const Tarjan = struct {
    a: Allocator,
    sink: *diag.Sink,
    g: *Graph,
    index: []u32,
    low: []u32,
    on_stack: []bool,
    stack: std.ArrayList(ModuleId) = .empty,
    next: u32 = 0,
    scc_of: []u32,
    /// Layer of each component, by component number.
    scc_layer: []u32,
    scc_count: u32 = 0,
    /// Scratch for `shortestCycle`.
    parent: []u32,
    /// Edges `from → to` closing an already reported cycle, as `from << 32 | to`.
    cut: std.AutoHashMapUnmanaged(u64, void) = .empty,

    fn visit(t: *Tarjan, v: ModuleId) Allocator.Error!void {
        t.index[v] = t.next;
        t.low[v] = t.next;
        t.next += 1;
        try t.stack.append(t.a, v);
        t.on_stack[v] = true;
        for (t.g.edges[v]) |e| {
            const w = e.target;
            if (t.index[w] == std.math.maxInt(u32)) {
                try t.visit(w);
                t.low[v] = @min(t.low[v], t.low[w]);
            } else if (t.on_stack[w]) {
                t.low[v] = @min(t.low[v], t.index[w]);
            }
        }
        if (t.low[v] != t.index[v]) return;

        // `v` roots a component. Every component it imports from is complete,
        // so its layer is known.
        const s = t.scc_count;
        t.scc_count += 1;
        const top = std.mem.lastIndexOfScalar(ModuleId, t.stack.items, v).?;
        const members = t.stack.items[top..];
        for (members) |m| {
            t.on_stack[m] = false;
            t.scc_of[m] = s;
        }
        var layer: u32 = 0;
        var cyclic = members.len > 1;
        for (members) |m| {
            for (t.g.edges[m]) |e| {
                if (t.scc_of[e.target] != s) layer = @max(layer, t.scc_layer[t.scc_of[e.target]] + 1) else if (e.target == m) cyclic = true;
            }
        }
        t.scc_layer[s] = layer;
        if (cyclic) try t.reportCycles(members, s);
        t.stack.shrinkRetainingCapacity(top);
    }

    /// E0902 for every cycle of component `s`. For each member `start` by
    /// path, reports the shortest cycle `start → … → start` and cuts its
    /// closing edge, until no cycle returns to `start`. Once every member is
    /// done no uncut cycle is left, and no cycle is reported twice.
    fn reportCycles(t: *Tarjan, members: []ModuleId, s: u32) Allocator.Error!void {
        t.g.has_cycle = true;
        std.mem.sort(ModuleId, members, {}, std.sort.asc(ModuleId)); // ids are in path order
        for (members) |start| {
            while (try t.shortestCycle(members, s, start)) |last| {
                try t.reportCycle(start, last);
                try t.cut.put(t.a, key(last, start), {});
            }
        }
    }

    fn key(from: ModuleId, to: ModuleId) u64 {
        return @as(u64, from) << 32 | to;
    }

    /// Breadth-first from `start` over uncut edges inside component `s`: the
    /// last module of the shortest cycle back to `start`, with the path to it
    /// in `parent`. Null if no cycle returns to `start`.
    fn shortestCycle(t: *Tarjan, members: []const ModuleId, s: u32, start: ModuleId) Allocator.Error!?ModuleId {
        const none = std.math.maxInt(u32);
        for (members) |m| t.parent[m] = none;
        var queue: std.ArrayList(ModuleId) = .empty;
        try queue.append(t.a, start);
        var i: usize = 0;
        while (i < queue.items.len) : (i += 1) {
            const u = queue.items[i];
            for (t.g.edges[u]) |e| {
                if (t.cut.contains(key(u, e.target))) continue;
                if (e.target == start) return u;
                if (t.scc_of[e.target] != s or t.parent[e.target] != none) continue;
                t.parent[e.target] = u;
                try queue.append(t.a, e.target);
            }
        }
        return null;
    }

    /// One E0902: the cycle `start → … → last → start` found by `shortestCycle`,
    /// at the `use` in `start`, labelling every `use` on it.
    fn reportCycle(t: *Tarjan, start: ModuleId, last: ModuleId) Allocator.Error!void {
        const g = t.g;
        var chain: std.ArrayList(ModuleId) = .empty; // start ... last, reversed below
        var m = last;
        while (m != start) : (m = t.parent[m]) try chain.append(t.a, m);
        try chain.append(t.a, start);
        std.mem.reverse(ModuleId, chain.items);

        var msg: std.ArrayList(u8) = .empty;
        try msg.appendSlice(t.a, "cyclic module imports: ");
        var labels = try t.a.alloc(diag.Label, chain.items.len);
        for (chain.items, 0..) |from, k| {
            const to = if (k + 1 < chain.items.len) chain.items[k + 1] else start;
            const edge = for (g.edges[from]) |e| {
                if (e.target == to) break e;
            } else unreachable;
            try msg.print(t.a, "{s} → ", .{g.modules[from].path});
            labels[k] = .{
                .span = g.modules[from].uses[edge.use].span,
                .primary = k == 0,
                .label = try std.fmt.allocPrint(t.a, "`{s}` imports `{s}`", .{ g.modules[from].path, g.modules[to].path }),
            };
        }
        try msg.appendSlice(t.a, g.modules[start].path);
        try t.sink.emit(.{
            .code = .E0902,
            .severity = .of(.E0902),
            .message = msg.items,
            .spans = labels,
            .help = &.{"move the declarations both sides need into a lower-level module that each of them imports"},
        });
    }
};

/// Stage 3 (collect) of one package as a `Compilation` hook. `register` adds
/// the package's modules as input files; after `Compilation.run` passes the
/// `resolve` stage, `graph` holds the result.
pub const Stage = struct {
    modules: []const layout.Module,
    options: Options,
    /// Index in `comp.files` of the first module's file; the others follow in order.
    first_file: usize,
    graph: ?Graph = null,

    /// Adds every module of `pkg`, whose directory is `dir`, to `comp` and
    /// registers the hook. `s` must not move until `comp.run` returns.
    pub fn register(s: *Stage, comp: *Compilation, dir: []const u8, pkg: layout.Package, options: Options) !void {
        s.* = .{ .modules = pkg.modules, .options = options, .first_file = comp.files.items.len };
        for (pkg.modules) |m| {
            const path = try std.fs.path.join(comp.gpa, &.{ dir, m.file });
            defer comp.gpa.free(path);
            _ = try comp.addFile(.cwd(), path);
        }
        try comp.addHook(.resolve, .{ .ctx = s, .run = run });
    }

    /// Frees the graph, if `run` built one.
    pub fn deinit(s: *Stage) void {
        if (s.graph) |*g| g.deinit();
        s.* = undefined;
    }

    fn run(ctx: ?*anyopaque, comp: *Compilation) anyerror!void {
        const s: *Stage = @ptrCast(@alignCast(ctx.?));
        const inputs = try comp.gpa.alloc(Input, s.modules.len);
        defer comp.gpa.free(inputs);
        for (s.modules, inputs, comp.files.items[s.first_file..][0..s.modules.len]) |m, *in, *f|
            in.* = .{ .module = m, .file = f.id, .ast = &f.ast };
        s.graph = try build(comp.gpa, &comp.sink, inputs, s.options);
    }
};

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

/// A package of in-memory modules `{ path, source }`; `a.b` is file `src/a/b.pr`.
const TestPackage = struct {
    asts: []Ast,
    inputs: []Input,
    sink: diag.Sink,

    fn init(mods: []const [2][]const u8) !TestPackage {
        const gpa = testing.allocator;
        const p: TestPackage = .{
            .asts = try gpa.alloc(Ast, mods.len),
            .inputs = try gpa.alloc(Input, mods.len),
            .sink = .init(gpa, testing.io),
        };
        for (mods, p.asts, p.inputs, 0..) |md, *ast, *in, i| {
            ast.* = try @import("test_util.zig").parseForTest(md[1]);
            const file = try std.mem.concat(gpa, u8, &.{ "src" ++ std.fs.path.sep_str, md[0], ".pr" });
            std.mem.replaceScalar(u8, file["src/".len .. file.len - ".pr".len], '.', std.fs.path.sep);
            in.* = .{ .module = .{ .path = md[0], .file = file }, .file = @fromBackingInt(@intCast(i)), .ast = ast };
        }
        return p;
    }

    fn deinit(p: *TestPackage) void {
        for (p.asts, p.inputs) |*ast, in| {
            ast.deinit(testing.allocator);
            testing.allocator.free(in.module.file);
        }
        testing.allocator.free(p.asts);
        testing.allocator.free(p.inputs);
        p.sink.deinit();
    }

    fn graph(p: *TestPackage, options: Options) !Graph {
        return build(testing.allocator, &p.sink, p.inputs, options);
    }
};

fn expectLayers(g: *const Graph, want: []const []const []const u8) !void {
    try testing.expectEqual(want.len, g.layers.len);
    for (want, g.layers) |w, l| {
        try testing.expectEqual(w.len, l.len);
        for (w, l) |path, m| try testing.expectEqualStrings(path, g.modules[m].path);
    }
}

test "diamond: each module once, in topological layers; no cycle" {
    var p: TestPackage = try .init(&.{
        .{ "main", "use left;\nuse right;\nuse left.f;\npub fn main() {}" },
        .{ "left", "use base;\npub fn f() {}" },
        .{ "right", "pub use base.{shared};\npub fn g() {}" },
        .{ "base", "use std.math;\npub fn shared() {}" },
    });
    defer p.deinit();
    var g = try p.graph(.{ .kind = .exe });
    defer g.deinit();
    try testing.expectEqual(0, p.sink.finish().len);
    try testing.expect(!g.has_cycle);
    try expectLayers(&g, &.{ &.{"base"}, &.{ "left", "right" }, &.{"main"} });
    const main = g.lookup("main").?;
    try testing.expectEqual(main, g.root.?);
    try testing.expectEqual(2, g.edges[main].len); // `use left.f` adds no second edge
}

test "E0902: the full chain once per cycle, at the use in its first module" {
    var p: TestPackage = try .init(&.{
        .{ "main", "use a;\npub fn main() {}" },
        .{ "c", "// c\nuse a;" },
        .{ "a", "use b.g;" },
        .{ "b", "use c;\nuse std.io;" },
        .{ "self_ref", "use self_ref;" },
    });
    defer p.deinit();
    var g = try p.graph(.{ .kind = .exe });
    defer g.deinit();
    try testing.expect(g.has_cycle);
    const ds = p.sink.finish();
    try testing.expectEqual(2, ds.len);

    const d = ds[0];
    try testing.expectEqual(diag.DiagCode.E0902, d.code.?);
    try testing.expectEqualStrings("cyclic module imports: a → b → c → a", d.message);
    try testing.expectEqual(3, d.spans.len);
    const want = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "a", "b.g", "`a` imports `b`" },
        .{ "b", "c", "`b` imports `c`" },
        .{ "c", "a", "`c` imports `a`" },
    };
    for (want, d.spans) |w, l| {
        const m = g.modules[g.lookup(w[0]).?];
        try testing.expectEqual(m.file, l.span.file);
        try testing.expectEqualStrings(w[1], m.ast.source[l.span.start..l.span.end]);
        try testing.expectEqualStrings(w[2], l.label);
    }
    try testing.expect(d.spans[0].primary and !d.spans[1].primary);
    try testing.expectEqualStrings("cyclic module imports: self_ref → self_ref", ds[1].message);

    // Every module still gets one layer; a cycle shares one.
    try expectLayers(&g, &.{ &.{ "a", "b", "c", "self_ref" }, &.{"main"} });
}

test "E0902: every cycle of one component is reported, each once" {
    var p: TestPackage = try .init(&.{
        // Figure eight through `a`, and `b ↔ d`, which does not pass through `a`.
        .{ "a", "use b;\nuse c;" },
        .{ "b", "use a;\nuse d;" },
        .{ "c", "use a;" },
        .{ "d", "use b;" },
    });
    defer p.deinit();
    var g = try p.graph(.{ .kind = .lib });
    defer g.deinit();
    const ds = p.sink.finish();
    try testing.expectEqual(3, ds.len);
    try testing.expectEqualStrings("cyclic module imports: a → b → a", ds[0].message);
    try testing.expectEqualStrings("cyclic module imports: a → c → a", ds[1].message);
    try testing.expectEqualStrings("cyclic module imports: b → d → b", ds[2].message);
    try expectLayers(&g, &.{&.{ "a", "b", "c", "d" }});
}

test "dependencies and std add no edges; unknown paths add none either" {
    var p: TestPackage = try .init(&.{
        .{ "lib", "use dep.x;\nuse std.math;\nuse nowhere.y;\nuse util.{f};" },
        .{ "util", "use lib;" },
        .{ "dep", "" }, // a local module named like a dependency: E0904 is import resolution's
    });
    defer p.deinit();
    var g = try p.graph(.{ .kind = .lib, .dependencies = &.{"dep"} });
    defer g.deinit();
    const lib = g.lookup("lib").?;
    try testing.expectEqual(1, g.edges[lib].len);
    try testing.expectEqual(g.lookup("util").?, g.edges[lib][0].target);
    try testing.expectEqual(1, p.sink.finish().len); // lib → util → lib
}

test "root module is main.pr or lib.pr by package kind" {
    var p: TestPackage = try .init(&.{ .{ "main", "" }, .{ "lib", "" } });
    defer p.deinit();
    var exe = try p.graph(.{ .kind = .exe });
    defer exe.deinit();
    try testing.expectEqualStrings("main", exe.modules[exe.root.?].path);
    var lib = try p.graph(.{ .kind = .lib });
    defer lib.deinit();
    try testing.expectEqualStrings("lib", lib.modules[lib.root.?].path);
}

test "E0901: a badly named module is reported and cannot be imported" {
    var p: TestPackage = try .init(&.{
        .{ "main", "use bad.name;" },
        .{ "bad-name", "use main;" },
        .{ "phys.rigid_body", "pub fn step() {}" },
    });
    defer p.deinit();
    var g = try p.graph(.{ .kind = .exe });
    defer g.deinit();
    const ds = p.sink.finish();
    try testing.expectEqual(1, ds.len);
    try testing.expectEqual(diag.DiagCode.E0901, ds[0].code.?);
    try testing.expectEqual(null, g.lookup("bad-name"));
    try testing.expect(g.lookup("phys.rigid_body") != null);
    try testing.expectEqual(0, g.edges[g.lookup("main").?].len);
}

test "Stage: a package on disk goes through layout, the Compilation and the resolve hook" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const files = [_][2][]const u8{
        .{ "pyro.toml", "[package]\nname = \"p\"\nversion = \"0.1.0\"\nedition = \"2026\"\n" },
        .{ "src/main.pr", "use physics.rigid_body;\nuse left;\npub fn main() {}\n" },
        .{ "src/left.pr", "use physics.rigid_body.{step};\n" },
        .{ "src/physics/rigid_body.pr", "pub fn step() {}\n" },
    };
    for (files) |f| {
        if (std.fs.path.dirname(f[0])) |d| try tmp.dir.createDirPath(testing.io, d);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = f[0], .data = f[1] });
    }
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    var comp: Compilation = undefined;
    try comp.init(testing.allocator, testing.io, .{ .jobs = 2, .stop_after = .check });
    defer comp.deinit();
    var l = try layout.open(testing.allocator, testing.io, &comp.sources, &comp.sink, root);
    defer l.deinit();
    var stage: Stage = undefined;
    try stage.register(&comp, l.dir, l.package.?, .{ .kind = l.package.?.kind });
    defer stage.deinit();
    try comp.run();

    try testing.expectEqual(0, comp.sink.finish().len);
    const g = &stage.graph.?;
    try testing.expectEqualStrings("main", g.modules[g.root.?].path);
    try expectLayers(g, &.{ &.{"physics.rigid_body"}, &.{"left"}, &.{"main"} });
}
