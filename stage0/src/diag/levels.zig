//! Warning levels (A.2, §8.8): `@allow(W....)` and `@deny(W....)` on an item
//! set the level of that warning for every diagnostic located inside the item,
//! nested items included. An inner item's attribute overrides an outer one
//! for the same code; other codes inherit. `@deny` promotes the warning to an
//! error. Errors cannot be suppressed: an attribute naming an `E` code has no
//! effect.
//!
//! `Levels` collects the attributed items of every file after parsing and is
//! installed as the sink's `WarningPolicy` (`policy`), which `Sink.finish`
//! consults per warning by its primary span.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("../ast/Ast.zig");
const diag = @import("diag.zig");
const Sink = diag.Sink;
const DiagCode = diag.DiagCode;
const WarningLevel = Sink.WarningLevel;

const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;

const Levels = @This();

/// Every `@allow`/`@deny` of a warning code, in the order files were added
/// and, within a file, outer items before inner ones.
scopes: std.ArrayList(Scope) = .empty,

/// One `@allow(code)` or `@deny(code)`: `level` applies to `code` within the
/// byte range `[start, end)` of the attributed item in `file`.
const Scope = struct {
    file: diag.FileId,
    start: u32,
    end: u32,
    code: DiagCode,
    level: WarningLevel,
};

pub fn deinit(l: *Levels, gpa: Allocator) void {
    l.scopes.deinit(gpa);
    l.* = undefined;
}

/// Records the warning levels set by the attributes in `ast`, the parsed
/// tree of file `file`. Not thread-safe; call once per file after parsing.
pub fn addFile(l: *Levels, gpa: Allocator, ast: *const Ast, file: diag.FileId) Allocator.Error!void {
    if (ast.nodes.len == 0) return;
    var work: std.ArrayList(Node.Index) = .empty;
    defer work.deinit(gpa);
    try work.append(gpa, .from(0));
    // Pre-order: an item is recorded before the items nested in it.
    while (work.pop()) |n| {
        if (ast.kind(n) == .attributed) try l.addItem(gpa, ast, file, n);
        switch (ast.data(n)) {
            inline else => |p| inline for (@typeInfo(@TypeOf(p)).@"struct".field_names) |name| {
                const v = @field(p, name);
                switch (@TypeOf(v)) {
                    Node.Index => try work.append(gpa, v),
                    ?Node.Index => if (v) |c| try work.append(gpa, c),
                    []const Node.Index => try work.appendSlice(gpa, v),
                    ?[]const Node.Index => if (v) |cs| try work.appendSlice(gpa, cs),
                    else => {}, // token slots
                }
            },
        }
    }
}

fn addItem(l: *Levels, gpa: Allocator, ast: *const Ast, file: diag.FileId, n: Node.Index) Allocator.Error!void {
    const d = ast.data(n).attributed;
    var end: ?u32 = null;
    for (d.attrs) |a| {
        const level: WarningLevel = if (std.mem.eql(u8, ast.tokenSlice(ast.mainToken(a)), "@allow"))
            .allow
        else if (std.mem.eql(u8, ast.tokenSlice(ast.mainToken(a)), "@deny"))
            .deny
        else
            continue;
        const args = ast.data(a).attribute.args orelse continue;
        // A malformed argument is not a level; comptime reports it (§8.1).
        if (args.len != 1 or ast.kind(args[0]) != .ident) continue;
        const code = std.meta.stringToEnum(DiagCode, ast.tokenSlice(ast.mainToken(args[0]))) orelse continue;
        if (!code.isWarning()) continue; // A.2: errors cannot be suppressed.
        if (end == null) {
            const last = lastToken(ast, d.inner);
            end = ast.tokens.items(.start)[last] + ast.tokens.items(.len)[last];
        }
        try l.scopes.append(gpa, .{
            .file = file,
            .start = ast.tokens.items(.start)[ast.mainToken(n)],
            .end = end.?,
            .code = code,
            .level = level,
        });
    }
}

/// Last token of item `item`: the `}` closing its body, or the `;` ending it.
fn lastToken(ast: *const Ast, item: Node.Index) TokenIndex {
    const kinds = ast.tokens.items(.kind);
    const mt = ast.mainToken(item);
    // The `{` opening the body, for items that end with one.
    const open: ?TokenIndex = switch (ast.data(item)) {
        .fn_decl => |f| if (f.body) |b| ast.mainToken(b) else null,
        .comptime_block => |c| ast.mainToken(c.body),
        .struct_decl, .enum_decl, .protocol_decl, .impl_decl, .extern_block => b: {
            var t = mt;
            while (kinds[t] != .l_brace and kinds[t] != .eof) t += 1;
            break :b t;
        },
        else => null,
    };
    var depth: u32 = 0;
    var t = open orelse mt;
    while (true) : (t += 1) switch (kinds[t]) {
        .l_brace, .dot_l_brace, .l_paren, .l_bracket => depth += 1,
        .r_brace, .r_paren, .r_bracket => {
            depth -|= 1;
            if (depth == 0 and open != null) return t;
        },
        .semicolon => if (depth == 0 and open == null) return t,
        .eof => return t,
        else => {},
    };
}

/// The effective level of warning `code` at `at`: that of the innermost item
/// containing `at.start` with an attribute for `code`, else `.warn`.
pub fn levelAt(l: *const Levels, code: DiagCode, at: diag.Span) WarningLevel {
    var best: ?Scope = null;
    // shortcut: linear scan over all attributes; index by file if programs grow many.
    for (l.scopes.items) |s| {
        if (s.file != at.file or s.code != code or at.start < s.start or at.start >= s.end) continue;
        // Inner items start later; among one item's attributes the last wins.
        if (best == null or s.start >= best.?.start) best = s;
    }
    return if (best) |b| b.level else .warn;
}

/// `l` as a sink policy; `l` must outlive the sink's `finish`.
pub fn policy(l: *const Levels) Sink.WarningPolicy {
    return .{ .ctx = l, .levelAt = levelAtOpaque };
}

fn levelAtOpaque(ctx: *const anyopaque, code: DiagCode, at: diag.Span) WarningLevel {
    const l: *const Levels = @ptrCast(@alignCast(ctx));
    return l.levelAt(code, at);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const lexer = @import("../lex/lexer.zig");
const literals = @import("../lex/literals.zig");
const Parser = @import("../parse/Parser.zig");

/// Parses `src` with levels applied; returns `code:severity` per diagnostic
/// in source order, space-separated, and whether the sink has errors.
fn run(buf: []u8, src: []const u8) !struct { []const u8, bool } {
    const gpa = testing.allocator;
    var sink: Sink = .init(gpa, testing.io);
    defer sink.deinit();
    const file: diag.FileId = @fromBackingInt(0);
    const tokens = try lexer.tokenize(gpa, src, file, &sink, .{ .scan_literal = literals.scan });
    var ast = try Parser.parse(gpa, src, tokens, file, &sink);
    defer ast.deinit(gpa);
    var levels: Levels = .{};
    defer levels.deinit(gpa);
    try levels.addFile(gpa, &ast, file);
    sink.warning_policy = levels.policy();
    var w: std.Io.Writer = .fixed(buf);
    for (sink.finish(), 0..) |d, i| {
        if (i > 0) try w.writeByte(' ');
        try w.print("{t}:{t}", .{ d.code.?, d.severity });
    }
    return .{ w.buffered(), sink.hasErrors() };
}

fn expectRun(src: []const u8, want: []const u8, errors: bool) !void {
    var buf: [256]u8 = undefined;
    const got, const has_errors = try run(&buf, src);
    try testing.expectEqualStrings(want, got);
    try testing.expectEqual(errors, has_errors);
}

test "W0201 in an @allow(W0201) fn is suppressed" {
    try expectRun("@allow(W0201) fn f(a: u32) -> u32 { a << 1 + a }", "", false);
    // Only inside the item.
    try expectRun(
        \\@allow(W0201) fn f(a: u32) -> u32 { a << 1 + a }
        \\fn g(a: u32) -> u32 { a << 1 + a }
    , "W0201:warning", false);
}

test "@deny(W0201) makes the warning an error" {
    try expectRun("@deny(W0201) fn f(a: u32) -> u32 { a << 1 + a }", "W0201:error", true);
}

test "@allow of an error code has no effect" {
    try expectRun("@allow(E0214) fn f(a: u32) -> bool { a < 1 < a }", "E0214:error", true);
}

test "inner items override outer levels; other codes inherit" {
    try expectRun(
        \\@deny(W0201) struct S {
        \\    @allow(W0201) fn f(a: u32) -> u32 { a << 1 + a }
        \\    @allow(W0802) fn g(a: u32) -> u32 { a << 1 + a }
        \\}
    , "W0201:error", true);
}

test "item extents: `;`-terminated items and nested braces" {
    try expectRun(
        \\@allow(W0201) const X: u32 = S { a: 1 }.a << 1 + 2;
        \\const Y: u32 = 1 << 2 + 3;
        \\@deny(W0201) fn f() { if true { g(.{ 1 }); } }
        \\fn h(a: u32) -> u32 { a << 1 + a }
    , "W0201:warning W0201:warning", false); // `Y` and `h`
}

test "the last of an item's attributes for a code wins" {
    try expectRun("@deny(W0201) @allow(W0201) fn f(a: u32) -> u32 { a << 1 + a }", "", false);
}
