//! Body name resolution, the third phase of name resolution (§7.10 step 3).
//!
//! `resolve` walks every item and body of every module with a stack of
//! local scopes and resolves each name use by the order of §6.3.1: local
//! bindings (innermost first), then items and imports of the module, then
//! the prelude (`Imports.lookup`). `a.b` where `a` denotes a module is a
//! member lookup in that module (private members are E0905); any other
//! `a.b` stays a field or method access for type checking. No type
//! information is used (§7.10).
//!
//! Each new local is checked against what it hides (§4.1, §6.3.1, §8.7): a
//! prelude type name or formatting intrinsic (`print`, `eprint`, `format`)
//! cannot be shadowed (E0301); shadowing a module item, an import or another
//! prelude name gets W0301; shadowing another local is silent. Items and
//! imports precede the prelude in lookup (§6.3.1), so they are not checked.
//!
//! Names that resolve to nothing are left out of the result, for type
//! checking (T043) to report. Attribute arguments (`@allow(W0301)`) are not
//! names and are skipped.

const std = @import("std");
const Allocator = std.mem.Allocator;
const diag = @import("../diag/diag.zig");
const Ast = @import("../ast/Ast.zig");
const Compilation = @import("../driver/Compilation.zig");
const collect = @import("collect.zig");
const module_graph = @import("module_graph.zig");
const imports = @import("imports.zig");
const prelude = @import("prelude.zig");

const Node = Ast.Node;
const ModuleId = module_graph.ModuleId;
const Target = imports.Target;
const Imports = imports.Imports;

/// What a name use denotes.
pub const Resolution = union(enum) {
    /// A local binding: the `pat_bind`, `pat_bind_mut`, `field_pat`,
    /// `field_pat_mut`, `param`, `generic_param` or block `const_decl` node.
    local: Node.Index,
    /// A module-level name, or a member of a module (`math.sqrt`).
    global: Target,
};

/// The resolution of one name-use node.
pub const Entry = struct {
    res: Resolution,
    /// For a `path` node: the trailing segments after the resolved prefix,
    /// left to type checking (`T.Output`). Zero for every other node.
    rest: u32 = 0,
};

/// Resolutions of one module, keyed by node: `ident` expressions,
/// `field_access` nodes that are module member lookups, `path` nodes (types,
/// struct literal and pattern types, impl headers) and shorthand
/// `field_init` nodes (`P { x }`).
pub const Map = std.AutoHashMapUnmanaged(Node.Index, Entry);

/// The body resolutions of one package. Borrows the `Imports`.
pub const Names = struct {
    arena: std.heap.ArenaAllocator,
    /// `modules[m]`: the resolutions in module `m`.
    modules: []const Map,

    pub fn deinit(n: *Names) void {
        n.arena.deinit();
        n.* = undefined;
    }

    /// What name-use `node` of module `m` denotes; null if it is no name use
    /// or the name is unknown.
    pub fn get(n: *const Names, m: ModuleId, node: Node.Index) ?Entry {
        return n.modules[m].get(node);
    }
};

/// Resolves the names in every item and body of every module of `im`.
/// Problems (E0301, W0301, E0905) are reported to `sink`; errors are
/// internal failures only.
pub fn resolve(gpa: Allocator, sink: *diag.Sink, im: *const Imports) Allocator.Error!Names {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const maps = try a.alloc(Map, im.graph.modules.len);
    @memset(maps, .empty);
    for (im.graph.modules, maps, 0..) |*mod, *map, m| {
        if (mod.ast.nodes.len == 0) continue; // poisoned file
        var w: Walker = .{ .a = a, .sink = sink, .im = im, .m = @intCast(m), .mod = mod, .ast = mod.ast, .map = map };
        try w.node(.from(0));
    }
    return .{ .arena = arena, .modules = maps };
}

/// Resolve-stage hook for single-file `pyro check`: import resolution
/// (`imports.runFiles`) followed by body name resolution.
pub fn runFiles(_: ?*anyopaque, comp: *Compilation) anyerror!void {
    try imports.eachFile(comp, struct {
        fn then(c: *Compilation, im: *const Imports) anyerror!void {
            var n = try resolve(c.gpa, &c.sink, im);
            n.deinit();
        }
    }.then);
}

const Error = Allocator.Error;

/// What a reserved prelude name is (§4.1).
const Reserved = enum { type, intrinsic };

const Local = struct { name: []const u8, node: Node.Index };

/// Resolves one module.
const Walker = struct {
    a: Allocator,
    sink: *diag.Sink,
    im: *const Imports,
    m: ModuleId,
    mod: *const collect.Module,
    ast: *const Ast,
    map: *Map,
    /// The visible locals, outermost first.
    locals: std.ArrayList(Local) = .empty,
    /// Declare without diagnostics: the second and later alternatives of an
    /// or-pattern bind the same names again.
    quiet: bool = false,

    fn node(w: *Walker, n: Node.Index) Error!void {
        switch (w.ast.kind(n)) {
            .use, .use_list, .invalid => {},
            // Attribute arguments are not names in scope (`@allow(W0301)`).
            .attributed => try w.node(w.ast.data(n).attributed.inner),
            .fn_decl, .struct_decl, .enum_decl, .protocol_decl, .impl_decl, .type_alias, .type_distinct, .lambda => {
                const mark = w.locals.items.len;
                defer w.locals.shrinkRetainingCapacity(mark);
                if (generics(w.ast, n)) |gs| for (gs) |g| try w.declare(w.ast.mainToken(g), g);
                try w.children(n); // `param` nodes declare themselves after their type and default
            },
            .param => {
                try w.children(n);
                const mt = w.ast.mainToken(n);
                if (w.ast.tokens.items(.kind)[mt] == .ident) try w.declare(mt, n); // not `self`
            },
            .block => {
                const mark = w.locals.items.len;
                defer w.locals.shrinkRetainingCapacity(mark);
                const d = w.ast.data(n).block;
                for (d.stmts) |s| try w.stmt(s);
                if (d.tail) |t| try w.node(t);
            },
            .let, .guard_let => try w.stmt(n),
            .@"if" => {
                const d = w.ast.data(n).@"if";
                try w.condScope(d.cond, d.then);
                if (d.@"else") |e| try w.node(e);
            },
            .@"while" => {
                const d = w.ast.data(n).@"while";
                try w.condScope(d.cond, d.body);
            },
            .@"for", .for_inline => switch (w.ast.data(n)) {
                inline .@"for", .for_inline => |d| try w.loop(d.iter, d.pattern, d.pattern2, d.filter, d.body),
                else => unreachable,
            },
            .parallel_for => {
                const d = w.ast.data(n).parallel_for;
                try w.loop(d.iter, d.pattern, null, null, d.body);
            },
            .array_comp => {
                const d = w.ast.data(n).array_comp;
                try w.loop(d.iter, d.pattern, d.pattern2, d.filter, d.elem);
            },
            .match_arm => {
                const d = w.ast.data(n).match_arm;
                const mark = w.locals.items.len;
                defer w.locals.shrinkRetainingCapacity(mark);
                try w.pattern(d.pattern);
                if (d.guard) |g| try w.node(g);
                try w.node(d.body);
            },
            .ident, .field_access => _ = try w.expr(n),
            .path => try w.path(n),
            .field_init => if (w.ast.data(n).field_init.value) |v| try w.node(v) else {
                // Shorthand `P { x }` reads the name `x`.
                if (w.lookup(w.identText(w.ast.mainToken(n)))) |r| try w.map.put(w.a, n, .{ .res = r });
            },
            else => try w.children(n),
        }
    }

    /// Walks every child node of `n`.
    fn children(w: *Walker, n: Node.Index) Error!void {
        switch (w.ast.data(n)) {
            inline else => |p| {
                const P = @TypeOf(p);
                inline for (@typeInfo(P).@"struct".field_names, @typeInfo(P).@"struct".field_types) |name, F| {
                    const v = @field(p, name);
                    switch (F) {
                        Node.Index => try w.node(v),
                        ?Node.Index => if (v) |c| try w.node(c),
                        []const Node.Index => for (v) |c| try w.node(c),
                        ?[]const Node.Index => if (v) |l| for (l) |c| try w.node(c),
                        else => {}, // tokens
                    }
                }
            },
        }
    }

    /// A block statement: `let`, `guard let` and `const` bind their names
    /// for the rest of the block, after their own initializer.
    fn stmt(w: *Walker, s: Node.Index) Error!void {
        const n = if (w.ast.kind(s) == .attributed) w.ast.data(s).attributed.inner else s;
        switch (w.ast.data(n)) {
            .let => |d| {
                if (d.ty) |t| try w.node(t);
                try w.node(d.init);
                try w.pattern(d.pattern);
            },
            .guard_let => |d| {
                try w.node(d.value);
                try w.node(d.@"else");
                try w.pattern(d.pattern);
            },
            .const_decl => {
                try w.children(n);
                try w.declare(w.ast.mainToken(n) + 1, n);
            },
            else => try w.node(s),
        }
    }

    /// An `if`/`while` condition and its body; `let` conditions bind in the body only.
    fn condScope(w: *Walker, cond: Node.Index, body: Node.Index) Error!void {
        const mark = w.locals.items.len;
        defer w.locals.shrinkRetainingCapacity(mark);
        switch (w.ast.data(cond)) {
            .let_cond => |d| {
                try w.node(d.value);
                try w.pattern(d.pattern);
            },
            else => try w.node(cond),
        }
        try w.node(body);
    }

    /// A `for` loop or array comprehension: its patterns bind in the filter and body.
    fn loop(w: *Walker, iter: Node.Index, pat: Node.Index, pat2: ?Node.Index, filter: ?Node.Index, body: Node.Index) Error!void {
        try w.node(iter);
        const mark = w.locals.items.len;
        defer w.locals.shrinkRetainingCapacity(mark);
        try w.pattern(pat);
        if (pat2) |p| try w.pattern(p);
        if (filter) |f| try w.node(f);
        try w.node(body);
    }

    /// Declares the bindings of pattern `p` and resolves the paths in it.
    fn pattern(w: *Walker, p: Node.Index) Error!void {
        switch (w.ast.data(p)) {
            .pat_bind, .pat_bind_mut, .field_pat_mut => try w.declare(w.ast.mainToken(p), p),
            .field_pat => |d| if (d.pattern) |sub| try w.pattern(sub) else try w.declare(w.ast.mainToken(p), p),
            .pat_struct => |d| {
                try w.node(d.ty);
                for (d.fields) |f| try w.pattern(f);
            },
            .pat_tuple => |d| for (d.elems) |e| try w.pattern(e),
            .pat_anon_struct => |d| for (d.fields) |e| try w.pattern(e),
            .pat_variant => |d| if (d.elems) |es| for (es) |e| try w.pattern(e),
            .pat_alt => |d| {
                const quiet = w.quiet;
                defer w.quiet = quiet;
                for (d.alts, 0..) |alt, i| {
                    w.quiet = quiet or i > 0;
                    try w.pattern(alt);
                }
            },
            .pat_wildcard, .rest, .invalid => {},
            else => try w.node(p), // literals and ranges
        }
    }

    /// Resolves `ident` or `field_access` `n` (and what it contains). Returns
    /// the module-level target `n` denotes, if any, so that an enclosing
    /// `field_access` can continue the member lookup.
    fn expr(w: *Walker, n: Node.Index) Error!?Target {
        switch (w.ast.kind(n)) {
            .ident => {
                const r = w.lookup(w.identText(w.ast.mainToken(n))) orelse return null;
                try w.map.put(w.a, n, .{ .res = r });
                return switch (r) {
                    .global => |t| t,
                    .local => null,
                };
            },
            .field_access => {
                const base = try w.expr(w.ast.data(n).field_access.lhs) orelse return null;
                const t = try w.member(base, w.ast.mainToken(n)) orelse return null;
                try w.map.put(w.a, n, .{ .res = .{ .global = t } });
                return t;
            },
            else => {
                try w.node(n);
                return null;
            },
        }
    }

    /// Resolves a `path` node (`B`, `geo.Rect`, `T.Output`): the first
    /// segment by name lookup, then members while the prefix is a module.
    fn path(w: *Walker, n: Node.Index) Error!void {
        var tok = w.ast.mainToken(n);
        const last = w.ast.data(n).path.last;
        var r = w.lookup(w.identText(tok)) orelse return;
        while (tok < last) : (tok += 2) {
            const base = switch (r) {
                .global => |t| t,
                .local => break,
            };
            r = .{ .global = try w.member(base, tok + 2) orelse break };
        }
        try w.map.put(w.a, n, .{ .res = r, .rest = (last - tok) / 2 });
    }

    /// Name lookup (§6.3.1): locals innermost first, then `Imports.lookup`.
    fn lookup(w: *const Walker, name: []const u8) ?Resolution {
        if (w.findLocal(name)) |l| return .{ .local = l };
        return .{ .global = w.im.lookup(w.m, name) orelse return null };
    }

    fn findLocal(w: *const Walker, name: []const u8) ?Node.Index {
        var i = w.locals.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, w.locals.items[i].name, name)) return w.locals.items[i].node;
        }
        return null;
    }

    /// Member `tok` of `base` if `base` is a module (§7.10 step 3); null if
    /// `base` is an item or a non-module prelude name, so the access is a
    /// field or method access. A private member is E0905.
    fn member(w: *Walker, base: Target, tok: Ast.TokenIndex) Error!?Target {
        const name = w.identText(tok);
        switch (base) {
            .external => |p| return .{ .external = try std.fmt.allocPrint(w.a, "{s}.{s}", .{ p, name }) },
            // The prelude's only module is `std` (§14.1).
            .prelude => |p| return if (std.mem.eql(u8, p, "std")) .{ .external = try std.fmt.allocPrint(w.a, "std.{s}", .{name}) } else null,
            .item => return null,
            .unresolved => return .unresolved,
            .module => |mm| {
                const mod = &w.im.graph.modules[mm];
                var private = false;
                if (mod.names.get(name)) |i| {
                    if (mod.items[i].is_pub or mm == w.m) return .{ .item = .{ .module = mm, .item = i } };
                    private = true;
                } else if (w.im.scopes[mm].names.get(name)) |i| {
                    const b = w.im.scopes[mm].bindings[i];
                    if (b.is_pub or mm == w.m) return b.target;
                    private = true;
                }
                try w.sink.emit(.{
                    .code = .E0905,
                    .severity = .of(.E0905),
                    .message = if (private)
                        try std.fmt.allocPrint(w.a, "`{s}` is private to module `{s}`", .{ name, mod.path })
                    else
                        try std.fmt.allocPrint(w.a, "module `{s}` has no public item `{s}`", .{ mod.path, name }),
                    .spans = &.{.{ .span = w.tokenSpan(tok), .primary = true }},
                    .help = if (private) &.{"declare it `pub` in that module to use it here"} else &.{},
                });
                return .unresolved;
            },
        }
    }

    /// Declares local `node`, named by token `tok`, after checking what it shadows.
    fn declare(w: *Walker, tok: Ast.TokenIndex, n: Node.Index) Error!void {
        const name = w.identText(tok);
        if (!w.quiet) try w.shadowing(name, w.tokenSpan(tok));
        try w.locals.append(w.a, .{ .name = name, .node = n });
    }

    /// E0301 or W0301 for a new local `name` at `span` (§6.3.1).
    fn shadowing(w: *Walker, name: []const u8, span: diag.Span) Error!void {
        if (try w.reserved(name, span)) return;
        if (w.findLocal(name) != null) return; // a local may shadow a local
        const help: []const []const u8 = &.{"rename the local, or put `@allow(W0301)` on the item if the shadowing is intended"};
        if (w.mod.find(name)) |it| {
            return w.sink.emit(.{
                .code = .W0301,
                .severity = .of(.W0301),
                .message = try std.fmt.allocPrint(w.a, "local `{s}` shadows the item `{s}` of this module", .{ name, name }),
                .spans = &.{
                    .{ .span = span, .primary = true },
                    .{ .span = w.tokenSpan(w.ast.mainToken(it.node) + 1), .label = "item declared here" },
                },
                .help = help,
            });
        }
        if (w.im.scopes[w.m].names.get(name)) |i| {
            return w.sink.emit(.{
                .code = .W0301,
                .severity = .of(.W0301),
                .message = try std.fmt.allocPrint(w.a, "local `{s}` shadows the import `{s}`", .{ name, name }),
                .spans = &.{
                    .{ .span = span, .primary = true },
                    .{ .span = w.im.scopes[w.m].bindings[i].span, .label = "imported here" },
                },
                .help = help,
            });
        }
        if (w.im.lookup(w.m, name) != null) {
            return w.sink.emit(.{
                .code = .W0301,
                .severity = .of(.W0301),
                .message = try std.fmt.allocPrint(w.a, "local `{s}` shadows the prelude name `{s}`", .{ name, name }),
                .spans = &.{.{ .span = span, .primary = true }},
                .help = help,
            });
        }
    }

    /// E0301 if `name`, declared at `span`, is a prelude type name or
    /// formatting intrinsic (§4.1, §8.7). Returns whether it was.
    fn reserved(w: *Walker, name: []const u8, span: diag.Span) Error!bool {
        const what = reservedKind(name, w.im.no_std) orelse return false;
        try w.sink.emit(.{
            .code = .E0301,
            .severity = .of(.E0301),
            .message = try std.fmt.allocPrint(w.a, "`{s}` is a prelude {s} and cannot be shadowed", .{ name, switch (what) {
                .type => "type",
                .intrinsic => "formatting intrinsic",
            } }),
            .spans = &.{.{ .span = span, .primary = true }},
            .help = &.{"choose another name"},
        });
        return true;
    }

    /// The identifier token `t` names: `r#type` is `type` (§2.3).
    fn identText(w: *const Walker, t: Ast.TokenIndex) []const u8 {
        const s = w.ast.tokenSlice(t);
        return if (std.mem.startsWith(u8, s, "r#")) s[2..] else s;
    }

    fn tokenSpan(w: *const Walker, t: Ast.TokenIndex) diag.Span {
        const start = w.ast.tokens.items(.start)[t];
        return .{ .file = w.mod.file, .start = start, .end = start + w.ast.tokens.items(.len)[t] };
    }
};

/// Whether `name` is a prelude type name or formatting intrinsic, which
/// nothing may shadow (§4.1). `no_std` packages lack `print`/`eprint` and
/// the hosted-only types (§14.1.1).
fn reservedKind(name: []const u8, no_std: bool) ?Reserved {
    if (prelude.isIntTypeName(name)) return .type;
    var found: ?Reserved = null;
    for (prelude.entries) |e| {
        if (!std.mem.eql(u8, e.name, name) or (no_std and e.hosted_only)) continue;
        if (e.kind == .type) return .type; // `vec2` is a type and a function
        // The compiler-defined prelude functions are the formatting intrinsics.
        if (e.kind == .function and e.origin == .compiler) found = .intrinsic;
    }
    return found;
}

/// The generic parameters of a declaration or lambda, if it has any.
fn generics(ast: *const Ast, n: Node.Index) ?[]const Node.Index {
    return switch (ast.data(n)) {
        inline .fn_decl, .struct_decl, .enum_decl, .protocol_decl, .impl_decl, .type_alias, .type_distinct => |d| d.generics,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const TestPackage = module_graph.TestPackage;

/// A resolved test package; `names` is valid until `deinit`.
const Resolved = struct {
    p: TestPackage,
    g: module_graph.Graph,
    im: Imports,
    names: Names,

    fn init(r: *Resolved, mods: []const [2][]const u8, options: imports.Options) !void {
        r.p = try .init(mods);
        errdefer r.p.deinit();
        r.g = try r.p.graph(.{ .kind = .exe });
        errdefer r.g.deinit();
        r.im = try imports.resolve(testing.allocator, &r.p.sink, &r.g, options);
        errdefer r.im.deinit();
        r.names = try resolve(testing.allocator, &r.p.sink, &r.im);
    }

    fn deinit(r: *Resolved) void {
        r.names.deinit();
        r.im.deinit();
        r.g.deinit();
        r.p.deinit();
    }

    /// Checks the reported (code, primary span text) pairs, in order.
    fn expectDiags(r: *Resolved, want: []const struct { diag.DiagCode, []const u8 }) !void {
        const ds = r.p.sink.finish();
        errdefer for (ds) |d| std.debug.print("got {?t}: {s}\n", .{ d.code, d.message });
        try testing.expectEqual(want.len, ds.len);
        for (want, ds) |wnt, d| {
            try testing.expectEqual(wnt[0], d.code.?);
            const s = d.primarySpan().?;
            try testing.expectEqualStrings(wnt[1], r.p.asts[@backingInt(s.file)].source[s.start..s.end]);
        }
    }

    /// The entry of the `nth` (0-based) node of kind `k` whose main token
    /// reads `text`, in module `mod`.
    fn entryOf(r: *Resolved, mod: []const u8, k: Ast.NodeKind, text: []const u8, nth: usize) ?Entry {
        const m = r.g.lookup(mod).?;
        const ast = r.g.modules[m].ast;
        var seen: usize = 0;
        for (0..ast.nodes.len) |i| {
            const n: Node.Index = .from(i);
            if (ast.kind(n) != k or !std.mem.eql(u8, ast.tokenSlice(ast.mainToken(n)), text)) continue;
            if (seen == nth) return r.names.get(m, n);
            seen += 1;
        }
        unreachable;
    }
};

fn expectSingle(src: []const u8, want: []const struct { diag.DiagCode, []const u8 }) !void {
    var r: Resolved = undefined;
    try r.init(&.{.{ "main", src }}, .{});
    defer r.deinit();
    try r.expectDiags(want);
}

test "E0301: locals and parameters cannot shadow prelude types or formatting intrinsics" {
    try expectSingle(
        \\fn area(w: u32, h: u32) -> u32 { let u8 = w * h; w }
        \\fn report(n: u32) { let print = n + 1; let (eprint, x) = (1, 2); }
        \\fn flag_count(bool: u32) -> u32 { 1 }
        \\fn join<str>(a: u32) -> u32 { let format = a; let List = a; let Handle = a; a }
        \\fn m(x: Option<u32>) { match x { .some(i64) => {}, _ => {} } }
        \\fn l() { let f = |vec2| vec2; for f32 in 0..3 {} }
    , &.{
        .{ .E0301, "u8" },   .{ .E0301, "print" },  .{ .E0301, "eprint" },
        .{ .E0301, "bool" }, .{ .E0301, "str" },    .{ .E0301, "format" },
        .{ .E0301, "List" }, .{ .E0301, "Handle" }, .{ .E0301, "i64" },
        .{ .E0301, "vec2" }, .{ .E0301, "f32" },
    });
}

test "items and imports may shadow prelude names: lookup finds them first (§6.3.1)" {
    var r: Resolved = undefined;
    try r.init(&.{
        .{ "main", "use util.{print};\nstruct Pool {}\nfn f(p: Pool) { print(1); }\n" },
        .{ "util", "pub fn print(x: u32) {}" },
    }, .{});
    defer r.deinit();
    try r.expectDiags(&.{});
    try testing.expectEqual(Target{ .item = .{ .module = 0, .item = 0 } }, r.entryOf("main", .path, "Pool", 0).?.res.global);
    try testing.expectEqual(Target{ .item = .{ .module = 1, .item = 0 } }, r.entryOf("main", .ident, "print", 0).?.res.global);
}

test "no_std: print and hosted-only types are not prelude names" {
    var r: Resolved = undefined;
    try r.init(&.{.{ "main", "fn f() { let print = 1; let List = 2; let format = 3; }" }}, .{ .no_std = true });
    defer r.deinit();
    try r.expectDiags(&.{.{ .E0301, "format" }});
}

test "W0301: a local shadows a module item, an import or another prelude name; local over local is silent" {
    try expectSingle(
        \\use std.math;
        \\fn speed() -> u32 { 3 }
        \\const LIMIT: u32 = 4;
        \\fn run(n: u32) -> u32 {
        \\    let speed = 4;
        \\    let assert = 1;
        \\    let math = 2;
        \\    let Display = 3;
        \\    let n = n + 1;
        \\    let n = n * 2;
        \\    let speed = speed + 1;
        \\    if let .some(LIMIT) = x { let LIMIT = 1; }
        \\    n
        \\}
        \\fn std(x: u32) {}
    , &.{
        .{ .W0301, "speed" },   .{ .W0301, "assert" }, .{ .W0301, "math" },
        .{ .W0301, "Display" }, .{ .W0301, "LIMIT" },
    });
}

test "an or-pattern warns once per name" {
    try expectSingle("fn speed() {}\nfn f(x: u32) { match x { .a(speed) | .b(speed) => {}, _ => {} } }", &.{.{ .W0301, "speed" }});
}

test "lookup order: locals, then items and imports, then the prelude" {
    var r: Resolved = undefined;
    try r.init(&.{.{
        "main",
        \\use std.math;
        \\fn helper() -> u32 { 1 }
        \\fn f(x: u32) -> u32 {
        \\    let y = x;
        \\    let s = math.sqrt(2.0);
        \\    let t = std.mem.copy;
        \\    let v = helper() + y;
        \\    { let helper = 2; helper }
        \\    let ok: bool = true;
        \\    print("{}", unknown);
        \\    v
        \\}
    }}, .{});
    defer r.deinit();
    try r.expectDiags(&.{.{ .W0301, "helper" }});

    // `x` and `y` are locals.
    try testing.expectEqual(.param, r.g.modules[0].ast.kind(r.entryOf("main", .ident, "x", 0).?.res.local));
    try testing.expectEqual(.pat_bind, r.g.modules[0].ast.kind(r.entryOf("main", .ident, "y", 0).?.res.local));
    // `math.sqrt` via `use std.math`; `std.mem.copy` via the prelude's `std`.
    try testing.expectEqualStrings("std.math", r.entryOf("main", .ident, "math", 0).?.res.global.external);
    try testing.expectEqualStrings("std.math.sqrt", r.entryOf("main", .field_access, "sqrt", 0).?.res.global.external);
    try testing.expectEqualStrings("std", r.entryOf("main", .ident, "std", 0).?.res.global.prelude);
    try testing.expectEqualStrings("std.mem.copy", r.entryOf("main", .field_access, "copy", 0).?.res.global.external);
    // The item `helper`, then the block's local `helper`.
    try testing.expectEqual(Target{ .item = .{ .module = 0, .item = 0 } }, r.entryOf("main", .ident, "helper", 0).?.res.global);
    try testing.expectEqual(.pat_bind, r.g.modules[0].ast.kind(r.entryOf("main", .ident, "helper", 1).?.res.local));
    // Type paths and the prelude.
    try testing.expectEqualStrings("bool", r.entryOf("main", .path, "bool", 0).?.res.global.prelude);
    try testing.expectEqualStrings("u32", r.entryOf("main", .path, "u32", 0).?.res.global.prelude);
    try testing.expectEqualStrings("print", r.entryOf("main", .ident, "print", 0).?.res.global.prelude);
    // Unknown names are left to type checking.
    try testing.expectEqual(null, r.entryOf("main", .ident, "unknown", 0));
}

test "scopes: let after its initializer, conditions, loops, arms, lambdas, generics" {
    var r: Resolved = undefined;
    try r.init(&.{.{
        "main",
        \\const k: u32 = 1;
        \\fn g<T>(a: T, b: u32 = k) -> T {
        \\    let k = k + 1;
        \\    if let .some(v) = a { v } else { v };
        \\    for i in 0..k { i }
        \\    i;
        \\    match a { .some(w) if w > 0 => w, _ => w }
        \\    let f = |p| p + k;
        \\    let q = P { k };
        \\    guard let .some(z) = a else { z }
        \\    z
        \\}
    }}, .{});
    defer r.deinit();
    try r.expectDiags(&.{.{ .W0301, "k" }});
    const ast = r.g.modules[0].ast;
    const item_k: Target = .{ .item = .{ .module = 0, .item = 0 } };
    // `b = k` and the initializer of `let k` see the item; later uses see the local.
    try testing.expectEqual(item_k, r.entryOf("main", .ident, "k", 0).?.res.global);
    try testing.expectEqual(item_k, r.entryOf("main", .ident, "k", 1).?.res.global);
    try testing.expectEqual(.pat_bind, ast.kind(r.entryOf("main", .ident, "k", 2).?.res.local));
    try testing.expectEqual(.pat_bind, ast.kind(r.entryOf("main", .ident, "k", 3).?.res.local));
    try testing.expectEqual(.pat_bind, ast.kind(r.entryOf("main", .field_init, "k", 0).?.res.local));
    try testing.expectEqual(.generic_param, ast.kind(r.entryOf("main", .path, "T", 0).?.res.local));
    // Bound in the `then` block, the loop body and the arm only.
    try testing.expect(r.entryOf("main", .ident, "v", 0) != null);
    try testing.expectEqual(null, r.entryOf("main", .ident, "v", 1));
    try testing.expect(r.entryOf("main", .ident, "i", 0) != null);
    try testing.expectEqual(null, r.entryOf("main", .ident, "i", 1));
    try testing.expect(r.entryOf("main", .ident, "w", 0) != null);
    try testing.expect(r.entryOf("main", .ident, "w", 1) != null);
    try testing.expectEqual(null, r.entryOf("main", .ident, "w", 2));
    try testing.expectEqual(.param, ast.kind(r.entryOf("main", .ident, "p", 0).?.res.local));
    // `guard let` binds after its `else` block.
    try testing.expectEqual(null, r.entryOf("main", .ident, "z", 0));
    try testing.expect(r.entryOf("main", .ident, "z", 1) != null);
}

test "module member paths: package modules, privacy, items stay field accesses" {
    var r: Resolved = undefined;
    try r.init(&.{
        .{
            "main",
            \\use geo;
            \\use geo.shapes as sh;
            \\fn f(p: geo.Point, s: sh.Circle.Inner) {
            \\    let a = geo.area(p);
            \\    let b = geo.secret();
            \\    let c = geo.missing;
            \\    let d = geo.Point.origin();
            \\    let e = p.x;
            \\}
        },
        .{ "geo", "pub use geo.shapes;\npub struct Point { x: f32 }\npub fn area(p: Point) -> f32 { p.x }\nfn secret() {}" },
        .{ "geo.shapes", "pub struct Circle {}" },
    }, .{});
    defer r.deinit();
    try r.expectDiags(&.{ .{ .E0905, "secret" }, .{ .E0905, "missing" } });
    const geo = r.g.lookup("geo").?;
    const shapes = r.g.lookup("geo.shapes").?;
    try testing.expectEqual(Target{ .item = .{ .module = geo, .item = 0 } }, r.entryOf("main", .path, "geo", 2).?.res.global); // after the two `use` paths
    const circle = r.entryOf("main", .path, "sh", 0).?;
    try testing.expectEqual(Target{ .item = .{ .module = shapes, .item = 0 } }, circle.res.global);
    try testing.expectEqual(1, circle.rest); // `.Inner` is left to type checking
    try testing.expectEqual(Target{ .item = .{ .module = geo, .item = 1 } }, r.entryOf("main", .field_access, "area", 0).?.res.global);
    try testing.expectEqual(Target.unresolved, r.entryOf("main", .field_access, "secret", 0).?.res.global);
    // `geo.Point` is an item, so `.origin` is a method access; `p.x` a field access.
    try testing.expect(r.entryOf("main", .field_access, "Point", 0) != null);
    try testing.expectEqual(null, r.entryOf("main", .field_access, "origin", 0));
    try testing.expectEqual(null, r.entryOf("main", .field_access, "x", 0));
}

test "runFiles: E0301 and W0301 through the resolve stage" {
    var comp: Compilation = undefined;
    try comp.init(testing.allocator, testing.io, .{ .jobs = 1, .stop_after = .check });
    defer comp.deinit();
    try comp.addHook(.resolve, .{ .run = runFiles });
    _ = try comp.addSource("a.pr", "fn speed() {}\nfn f() { let u8 = 1; let speed = 2; }\n");
    try comp.run();
    const ds = comp.sink.finish();
    try testing.expectEqual(2, ds.len);
    try testing.expectEqual(diag.DiagCode.E0301, ds[0].code.?);
    try testing.expectEqual(diag.DiagCode.W0301, ds[1].code.?);
}

test "name resolution does not use type information (§7.10)" {
    const src = @embedFile("names.zig");
    try testing.expect(std.mem.indexOf(u8, src, "types" ++ ".zig") == null);
    try testing.expect(std.mem.indexOf(u8, src, "../" ++ "sema") == null);
}
