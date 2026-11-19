//! Collect, the first phase of name resolution (§7.10 step 1), for one module:
//! its module path (§7.8.1, E0901), the table of items it declares (§7.1) and
//! the `use` declarations that become edges of the module graph (§7.8.3).
//!
//! Nothing here looks at another module; `module_graph.zig` joins the modules.
//! Names are slices of the module's source text, valid while its `Ast` lives.

const std = @import("std");
const Allocator = std.mem.Allocator;
const diag = @import("../diag/diag.zig");
const Ast = @import("../ast/Ast.zig");
const token = @import("../lex/token.zig");
const max_ident_len = @import("../lex/lexer.zig").max_ident_len;

const Node = Ast.Node;

/// What a named item is (§7.1). `impl` blocks and top-level `comptime` blocks
/// declare no name and are not listed.
pub const ItemKind = enum { @"const", type_alias, type_distinct, @"fn", @"struct", @"enum", protocol, extern_fn };

/// One named item of a module.
pub const Item = struct {
    /// The declared name; a raw identifier `r#type` is listed as `type`.
    name: []const u8,
    kind: ItemKind,
    is_pub: bool,
    /// The declaration node (`fn_decl`, `struct_decl`, ...), without its `attributed` wrapper.
    node: Node.Index,
};

/// One `use` declaration (§7.8.2).
pub const Use = struct {
    /// The `use` or `use_list` node.
    node: Node.Index,
    is_pub: bool,
    /// The dotted path before `as` or `.{`, raw-identifier prefixes removed: `a.b`.
    path: []const u8,
    /// Source span of the path, for diagnostics about this import.
    span: diag.Span,
};

/// The collected contents of one module.
pub const Module = struct {
    /// Dotted module path (`physics.rigid_body`).
    path: []const u8,
    file: diag.FileId,
    ast: *const Ast,
    /// Named items in declaration order. Duplicates are kept; reporting them
    /// is import resolution's job (E0903).
    items: []const Item,
    /// Item index by name; the first of duplicates wins.
    names: std.StringHashMapUnmanaged(u32),
    uses: []const Use,

    /// The first item called `name`, if any.
    pub fn find(m: *const Module, name: []const u8) ?*const Item {
        return &m.items[m.names.get(name) orelse return null];
    }
};

/// True if `s` is an identifier (§2.3) that may name a module: ASCII letters,
/// digits and `_`, not starting with a digit, at most 255 bytes, and neither
/// `_`, a keyword (§2.4.1) nor a reserved word (§2.4.2).
pub fn isValidSegment(s: []const u8) bool {
    if (s.len == 0 or s.len > max_ident_len or std.ascii.isDigit(s[0])) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return !std.mem.eql(u8, s, "_") and token.keyword(s) == null and !token.isFutureReserved(s);
}

/// Checks every segment of `rel`, a `.pr` file path relative to the source root
/// (`physics/rigid_body.pr`). Reports the first bad segment as E0901 at the
/// start of `file` and returns false. Checking the file path rather than the
/// dotted module path also rejects a `.` inside a file name (`a.b.pr`).
pub fn checkPath(sink: *diag.Sink, file: diag.FileId, rel: []const u8) Allocator.Error!bool {
    std.debug.assert(std.mem.endsWith(u8, rel, ".pr"));
    var it = std.mem.splitScalar(u8, rel[0 .. rel.len - ".pr".len], std.fs.path.sep);
    while (it.next()) |seg| {
        if (isValidSegment(seg)) continue;
        var buf: [max_ident_len + 128]u8 = undefined;
        const shown = seg[0..@min(seg.len, max_ident_len)];
        try sink.emit(.{
            .code = .E0901,
            .severity = .of(.E0901),
            .message = std.fmt.bufPrint(&buf, "module path segment `{s}` is not an identifier", .{shown}) catch unreachable,
            .spans = &.{.{ .span = .{ .file = file, .start = 0, .end = 0 }, .primary = true }},
            .help = &.{"rename the file or directory: module path segments are identifiers (letters, digits, `_`) and not keywords"},
        });
        return false;
    }
    return true;
}

/// Collects the items and `use` declarations of module `path` (file `file`,
/// tree `ast`). An empty `ast` (a poisoned file) yields an empty module.
/// Everything is allocated with `a`, meant to be an arena.
pub fn collect(a: Allocator, path: []const u8, file: diag.FileId, ast: *const Ast) Allocator.Error!Module {
    var items: std.ArrayList(Item) = .empty;
    var uses: std.ArrayList(Use) = .empty;
    if (ast.nodes.len > 0) for (ast.data(.from(0)).root.items) |n| try collectItem(a, ast, file, n, &items, &uses);

    var names: std.StringHashMapUnmanaged(u32) = .empty;
    for (items.items, 0..) |it, i| {
        const gop = try names.getOrPut(a, it.name);
        if (!gop.found_existing) gop.value_ptr.* = @intCast(i);
    }
    return .{ .path = path, .file = file, .ast = ast, .items = items.items, .names = names, .uses = uses.items };
}

fn collectItem(
    a: Allocator,
    ast: *const Ast,
    file: diag.FileId,
    node: Node.Index,
    items: *std.ArrayList(Item),
    uses: *std.ArrayList(Use),
) Allocator.Error!void {
    const n = if (ast.kind(node) == .attributed) ast.data(node).attributed.inner else node;
    const kind: ItemKind = switch (ast.data(n)) {
        .const_decl => .@"const",
        .type_alias => .type_alias,
        .type_distinct => .type_distinct,
        .fn_decl => .@"fn",
        .struct_decl => .@"struct",
        .enum_decl => .@"enum",
        .protocol_decl => .protocol,
        .extern_block => |e| {
            for (e.fns) |f| {
                const inner = if (ast.kind(f) == .attributed) ast.data(f).attributed.inner else f;
                try items.append(a, item(ast, inner, .extern_fn));
            }
            return;
        },
        .use => |u| return uses.append(a, try use(a, ast, file, n, u.path)),
        .use_list => |u| return uses.append(a, try use(a, ast, file, n, u.path)),
        else => return, // impl, comptime, and nodes poisoned by parse errors
    };
    try items.append(a, item(ast, n, kind));
}

fn item(ast: *const Ast, n: Node.Index, kind: ItemKind) Item {
    const mt = ast.mainToken(n);
    return .{ .name = identText(ast, mt + 1), .kind = kind, .is_pub = isPub(ast, mt), .node = n };
}

fn use(a: Allocator, ast: *const Ast, file: diag.FileId, n: Node.Index, path: Node.Index) Allocator.Error!Use {
    const first = ast.mainToken(path);
    const last = ast.data(path).path.last;
    var segs: std.ArrayList([]const u8) = .empty;
    var t = first;
    while (t <= last) : (t += 2) try segs.append(a, identText(ast, t));
    const starts = ast.tokens.items(.start);
    return .{
        .node = n,
        .is_pub = isPub(ast, ast.mainToken(n)),
        .path = try std.mem.join(a, ".", segs.items),
        .span = .{ .file = file, .start = starts[first], .end = starts[last] + ast.tokens.items(.len)[last] },
    };
}

/// `pub` is the token before a declaration keyword (see `Ast.zig`).
fn isPub(ast: *const Ast, keyword: Ast.TokenIndex) bool {
    return keyword > 0 and ast.tokens.items(.kind)[keyword - 1] == .kw_pub;
}

/// The identifier an IDENT token names: `r#type` is `type` (§2.3).
fn identText(ast: *const Ast, t: Ast.TokenIndex) []const u8 {
    const s = ast.tokenSlice(t);
    return if (std.mem.startsWith(u8, s, "r#")) s[2..] else s;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const parseForTest = @import("test_util.zig").parseForTest;

test "segments must be identifiers, not keywords or reserved words" {
    for ([_][]const u8{ "main", "rigid_body", "_x", "a1", "Gpu", "gpu", "result" }) |s| try testing.expect(isValidSegment(s));
    for ([_][]const u8{ "", "bad-name", "1st", "_", "fn", "type", "async", "a.b", "caf\xc3\xa9" }) |s| try testing.expect(!isValidSegment(s));
    try testing.expect(!isValidSegment(&(@as([256]u8, @splat('a')))));
}

test "E0901: bad file or directory name, reported at the start of the file" {
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    const sep = std.fs.path.sep_str;
    const files = [_]diag.FileId{ @fromBackingInt(@intCast(0)), @fromBackingInt(@intCast(1)), @fromBackingInt(@intCast(2)) };
    try testing.expect(try checkPath(&sink, files[0], "physics" ++ sep ++ "rigid_body.pr"));
    try testing.expect(!try checkPath(&sink, files[0], "bad-name.pr"));
    try testing.expect(!try checkPath(&sink, files[1], "my dir" ++ sep ++ "ok.pr"));
    try testing.expect(!try checkPath(&sink, files[2], "a.b.pr"));
    const ds = sink.finish();
    try testing.expectEqual(3, ds.len);
    for (ds, files) |d, f| {
        try testing.expectEqual(diag.DiagCode.E0901, d.code.?);
        try testing.expectEqual(diag.Span{ .file = f, .start = 0, .end = 0 }, d.primarySpan().?);
    }
    try testing.expectEqualStrings("module path segment `bad-name` is not an identifier", ds[0].message);
    try testing.expectEqualStrings("module path segment `my dir` is not an identifier", ds[1].message);
    try testing.expectEqualStrings("module path segment `a.b` is not an identifier", ds[2].message);
}

test "item table: names, kinds, visibility; uses with their paths" {
    var ast = try parseForTest(
        \\use std.math;
        \\pub use geometry.{Vec2, Rect};
        \\use physics.rigid_body as rb;
        \\pub const N: u32 = 4;
        \\type Id = u32;
        \\pub type Meters = distinct f32;
        \\@inline pub fn step() {}
        \\fn r#type() {}
        \\pub struct P { x: f32 }
        \\enum E { a, b }
        \\protocol Shape {}
        \\impl Shape for P {}
        \\extern "C" { pub fn puts(s: *const u8) -> i32; fn abs(x: i32) -> i32; }
        \\comptime {}
        \\fn step() {}
    );
    defer ast.deinit(testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const m = try collect(arena.allocator(), "m", @fromBackingInt(@intCast(0)), &ast);

    const want = [_]struct { []const u8, ItemKind, bool }{
        .{ "N", .@"const", true },           .{ "Id", .type_alias, false },
        .{ "Meters", .type_distinct, true }, .{ "step", .@"fn", true },
        .{ "type", .@"fn", false },          .{ "P", .@"struct", true },
        .{ "E", .@"enum", false },           .{ "Shape", .protocol, false },
        .{ "puts", .extern_fn, true },       .{ "abs", .extern_fn, false },
        .{ "step", .@"fn", false },
    };
    try testing.expectEqual(want.len, m.items.len);
    for (want, m.items) |w, it| {
        try testing.expectEqualStrings(w[0], it.name);
        try testing.expectEqual(w[1], it.kind);
        try testing.expectEqual(w[2], it.is_pub);
    }
    try testing.expect(m.find("step").?.is_pub); // the first `step` wins
    try testing.expectEqual(null, m.find("rb"));

    try testing.expectEqual(3, m.uses.len);
    try testing.expectEqualStrings("std.math", m.uses[0].path);
    try testing.expect(!m.uses[0].is_pub);
    try testing.expectEqualStrings("geometry", m.uses[1].path);
    try testing.expect(m.uses[1].is_pub);
    try testing.expectEqual(.use_list, ast.kind(m.uses[1].node));
    try testing.expectEqualStrings("physics.rigid_body", m.uses[2].path);
    const s = m.uses[2].span;
    try testing.expectEqualStrings("physics.rigid_body", ast.source[s.start..s.end]);
}

test "a poisoned (unparsed) file collects to an empty module" {
    const ast: Ast = .{ .source = "" };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const m = try collect(arena.allocator(), "m", @fromBackingInt(@intCast(0)), &ast);
    try testing.expectEqual(0, m.items.len + m.uses.len);
}
