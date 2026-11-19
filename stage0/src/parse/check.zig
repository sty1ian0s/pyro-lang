//! Post-parse syntactic checks: rules of chapter 3 that need more than one
//! production in view but no names or types. They run on each file's tree
//! right after it is parsed (stage 2), so `--stop-after parse` reports them.
//!
//! - E0202, E0203: every attribute is in the §8.8 table (`attr_table.zig`)
//!   and written in a position its row lists (§3.3), including the `pub fn`
//!   and `mut self` method conditions of `@trap_handler`, `@export` and
//!   `@append_only`;
//! - E0207: an assignment target has the shape of a place (§3.5, §1.6): a
//!   name, `self`, a field or index of a place, or a dereference. Whether a
//!   name denotes a local or parameter is decided after name resolution;
//! - E0210: `break :l` / `continue :l` inside the loop labelled `l`, without
//!   crossing a `fn` or lambda boundary (§3.5);
//! - E0211: `|` alternatives only in `match` arm patterns, each binding the
//!   same names as the first (§3.7). Equal binding types are checked later;
//! - E0501: `spawn` inside a `nursery` body, without crossing a `fn` or
//!   lambda boundary (§3.5).
//!
//! E0213 (`mut`/`move` positions, §3.8.2) is checked while parsing
//! (`expr.zig`), where the position of each expression is known.
//! Poisoned `invalid` nodes have no children, so nothing is reported inside
//! a construct that failed to parse (A.1).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("../ast/Ast.zig");
const diag = @import("../diag/diag.zig");
const attr_table = @import("../attr_table.zig");

const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;

/// Runs every check on `ast` (file `file`) and reports into `sink`.
pub fn checkFile(gpa: Allocator, ast: *const Ast, file: diag.FileId, sink: *diag.Sink) Allocator.Error!void {
    if (ast.nodes.len == 0) return;
    var c: Checker = .{ .gpa = gpa, .ast = ast, .file = file, .sink = sink };
    defer c.labels.deinit(gpa);
    try c.walk(.from(0));
}

const Checker = struct {
    gpa: Allocator,
    ast: *const Ast,
    file: diag.FileId,
    sink: *diag.Sink,
    /// Labels of the enclosing loops, innermost last.
    labels: std.ArrayList(TokenIndex) = .empty,
    /// Labels below this index belong to an enclosing function.
    label_base: usize = 0,
    /// Inside a `nursery` body of the current function.
    in_nursery: bool = false,
    /// Walking a `match` arm's pattern.
    alt_ok: bool = false,

    fn walk(c: *Checker, n: Node.Index) Allocator.Error!void {
        const ast = c.ast;
        switch (ast.kind(n)) {
            .fn_decl, .lambda => {
                const base = c.label_base;
                const nursery = c.in_nursery;
                defer {
                    c.label_base = base;
                    c.in_nursery = nursery;
                }
                c.label_base = c.labels.items.len;
                c.in_nursery = false;
                try c.walkChildren(n);
            },
            .nursery => {
                const nursery = c.in_nursery;
                defer c.in_nursery = nursery;
                c.in_nursery = true;
                try c.walkChildren(n);
            },
            .spawn => {
                if (!c.in_nursery) try c.report(.E0501, c.tokenSpan(ast.mainToken(n)), "`spawn` outside a `nursery` block", "put the `spawn` inside a `nursery { ... }` body of the same function; a `fn` or lambda boundary ends the nursery");
                try c.walkChildren(n);
            },
            .labeled => {
                try c.labels.append(c.gpa, ast.mainToken(n));
                defer _ = c.labels.pop();
                try c.walkChildren(n);
            },
            .@"break" => {
                if (ast.data(n).@"break".label) |l| try c.checkLabel(l);
                try c.walkChildren(n);
            },
            .@"continue" => if (ast.data(n).@"continue".label) |l| try c.checkLabel(l),
            .assign => {
                const lhs = ast.data(n).assign.lhs;
                if (!isPlace(ast, lhs)) try c.report(.E0207, .{
                    .file = c.file,
                    .start = c.tokenSpan(firstToken(ast, lhs)).start,
                    .end = c.tokenSpan(ast.mainToken(n) - 1).end,
                }, "the left side of this assignment is not a place", "assign to a variable, parameter, field, index or dereferenced pointer");
                try c.walkChildren(n);
            },
            .attributed => {
                try c.checkAttrs(n);
                try c.walkChildren(n);
            },
            .match_arm => {
                const arm = ast.data(n).match_arm;
                c.alt_ok = true;
                try c.walk(arm.pattern);
                c.alt_ok = false;
                if (arm.guard) |g| try c.walk(g);
                try c.walk(arm.body);
            },
            .pat_alt => {
                if (c.alt_ok)
                    try c.checkAlternatives(n)
                else
                    try c.report(.E0211, c.tokenSpan(ast.mainToken(n)), "alternative patterns are allowed only in `match` arms", "use a `match`, or test each alternative separately");
                try c.walkChildren(n);
            },
            else => try c.walkChildren(n),
        }
    }

    /// Walks every child node of `n` in source order.
    fn walkChildren(c: *Checker, n: Node.Index) Allocator.Error!void {
        switch (c.ast.data(n)) {
            inline else => |payload| inline for (@typeInfo(@TypeOf(payload)).@"struct".field_names) |name| {
                const v = @field(payload, name);
                switch (@TypeOf(v)) {
                    Node.Index => try c.walk(v),
                    ?Node.Index => if (v) |x| try c.walk(x),
                    []const Node.Index => for (v) |x| try c.walk(x),
                    ?[]const Node.Index => if (v) |xs| for (xs) |x| try c.walk(x),
                    else => {}, // token slots
                }
            },
        }
    }

    // E0210 ------------------------------------------------------------------

    /// E0210 unless label token `l` names a loop of the current function
    /// enclosing it.
    fn checkLabel(c: *Checker, l: TokenIndex) Allocator.Error!void {
        const name = c.ast.tokenSlice(l);
        for (c.labels.items[c.label_base..]) |t| {
            if (std.mem.eql(u8, c.ast.tokenSlice(t), name)) return;
        }
        var buf: [256]u8 = undefined;
        try c.report(.E0210, c.tokenSpan(l), fmt(&buf, "no enclosing loop is labelled `{s}`", .{name}), "a label can be used only by `break` and `continue` inside the loop it labels, in the same function");
    }

    // E0207 ------------------------------------------------------------------

    /// Whether `n` has the shape of a place (§1.6).
    fn isPlace(ast: *const Ast, n: Node.Index) bool {
        return switch (ast.kind(n)) {
            .ident, .self_value, .invalid => true,
            .paren => isPlace(ast, ast.data(n).paren.inner),
            .field_access => isPlace(ast, ast.data(n).field_access.lhs),
            .index => isPlace(ast, ast.data(n).index.lhs),
            // A dereference is a place whatever the pointer expression is.
            .prefix => ast.tokens.items(.kind)[ast.mainToken(n)] == .star,
            else => false,
        };
    }

    /// First token of expression `n`.
    fn firstToken(ast: *const Ast, n: Node.Index) TokenIndex {
        return switch (ast.data(n)) {
            .binary => |d| firstToken(ast, d.lhs),
            .cast => |d| firstToken(ast, d.value),
            .field_access => |d| firstToken(ast, d.lhs),
            .index => |d| firstToken(ast, d.lhs),
            .call => |d| firstToken(ast, d.callee),
            .try_op => |d| firstToken(ast, d.lhs),
            .struct_lit => |d| firstToken(ast, d.ty),
            .range => |d| if (d.lo) |lo| firstToken(ast, lo) else ast.mainToken(n),
            else => ast.mainToken(n),
        };
    }

    // E0202, E0203 -----------------------------------------------------------

    fn checkAttrs(c: *Checker, n: Node.Index) Allocator.Error!void {
        const ast = c.ast;
        const d = ast.data(n).attributed;
        // Null only for an `invalid` node: its error is already reported.
        const position = attr_table.Position.of(ast.kind(d.inner)) orelse return;
        for (d.attrs) |a| {
            const t = ast.mainToken(a);
            const text = ast.tokenSlice(t);
            const name = if (std.mem.startsWith(u8, text, "@")) text[1..] else text;
            var buf: [512]u8 = undefined;
            var help: [512]u8 = undefined;
            const attr = attr_table.lookup(name) orelse {
                try c.report(.E0202, c.tokenSpan(t), fmt(&buf, "unknown attribute `@{s}`", .{name}), "§8.8 lists every attribute; names are case-sensitive");
                continue;
            };
            const row = attr_table.info(attr);
            if (!row.positions.contains(position)) {
                var w: std.Io.Writer = .fixed(&help);
                w.print("`@{s}` applies to ", .{name}) catch {};
                var it = row.positions.iterator();
                var first = true;
                while (it.next()) |p| : (first = false) {
                    if (!first) w.writeAll(", ") catch {};
                    w.writeAll(p.describe()) catch {};
                }
                try c.report(.E0203, c.tokenSpan(t), fmt(&buf, "`@{s}` is not allowed on {s}", .{ name, position.describe() }), w.buffered());
                continue;
            }
            const ok = switch (row.requires) {
                .none => true,
                .pub_fn => t: {
                    const fn_tok = ast.mainToken(d.inner);
                    break :t fn_tok > 0 and ast.tokens.items(.kind)[fn_tok - 1] == .kw_pub;
                },
                .mut_self_method => isMutSelfMethod(ast, d.inner),
            };
            if (!ok) try c.report(.E0203, c.tokenSpan(t), fmt(&buf, "`@{s}` is allowed only on {s}", .{ name, switch (row.requires) {
                .pub_fn => "a `pub` function",
                .mut_self_method => "a method whose first parameter is `mut self`",
                .none => unreachable,
            } }), "move the attribute, or change the declaration");
        }
    }

    fn isMutSelfMethod(ast: *const Ast, f: Node.Index) bool {
        const params = ast.data(f).fn_decl.params;
        if (params.len == 0) return false;
        var p = params[0];
        if (ast.kind(p) == .attributed) p = ast.data(p).attributed.inner;
        const t = ast.mainToken(p);
        const kinds = ast.tokens.items(.kind);
        return ast.kind(p) == .param and kinds[t] == .kw_self and t > 0 and kinds[t - 1] == .kw_mut;
    }

    // E0211 ------------------------------------------------------------------

    /// E0211 for the first alternative of `n` that does not bind the same
    /// names as the first one.
    fn checkAlternatives(c: *Checker, n: Node.Index) Allocator.Error!void {
        const ast = c.ast;
        const alts = ast.data(n).pat_alt.alts;
        var want: std.ArrayList([]const u8) = .empty;
        defer want.deinit(c.gpa);
        var got: std.ArrayList([]const u8) = .empty;
        defer got.deinit(c.gpa);
        try c.bindings(alts[0], &want);
        sortNames(want.items);
        for (alts[1..]) |alt| {
            got.clearRetainingCapacity();
            try c.bindings(alt, &got);
            sortNames(got.items);
            var buf: [512]u8 = undefined;
            const msg = if (missing(want.items, got.items)) |name|
                fmt(&buf, "this alternative does not bind `{s}`, which the first alternative binds", .{name})
            else if (missing(got.items, want.items)) |name|
                fmt(&buf, "this alternative binds `{s}`, which the first alternative does not bind", .{name})
            else
                continue;
            try c.report(.E0211, c.tokenSpan(ast.mainToken(alt)), msg, "every alternative of a `|` pattern must bind the same names");
            return;
        }
    }

    /// Appends the names pattern `n` binds. A nested `|` binds the names of
    /// its first alternative (the others are checked against it).
    fn bindings(c: *Checker, n: Node.Index, out: *std.ArrayList([]const u8)) Allocator.Error!void {
        const ast = c.ast;
        switch (ast.data(n)) {
            .pat_bind, .pat_bind_mut, .field_pat_mut => try out.append(c.gpa, ast.tokenSlice(ast.mainToken(n))),
            .field_pat => |d| if (d.pattern) |p| try c.bindings(p, out) else try out.append(c.gpa, ast.tokenSlice(ast.mainToken(n))),
            .pat_alt => |d| try c.bindings(d.alts[0], out),
            .pat_variant => |d| if (d.elems) |es| for (es) |e| try c.bindings(e, out),
            .pat_tuple => |d| for (d.elems) |e| try c.bindings(e, out),
            .pat_struct => |d| for (d.fields) |e| try c.bindings(e, out),
            .pat_anon_struct => |d| for (d.fields) |e| try c.bindings(e, out),
            else => {}, // `_`, literals, ranges, `..`
        }
    }

    fn sortNames(names: [][]const u8) void {
        std.mem.sort([]const u8, names, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
    }

    /// The first name of sorted `a` that sorted `b` lacks.
    fn missing(a: []const []const u8, b: []const []const u8) ?[]const u8 {
        for (a) |x| {
            for (b) |y| {
                if (std.mem.eql(u8, x, y)) break;
            } else return x;
        }
        return null;
    }

    // Reporting ----------------------------------------------------------------

    fn tokenSpan(c: *const Checker, t: TokenIndex) diag.Span {
        const start = c.ast.tokens.items(.start)[t];
        return .{ .file = c.file, .start = start, .end = start + c.ast.tokens.items(.len)[t] };
    }

    fn report(c: *Checker, code: diag.DiagCode, span: diag.Span, message: []const u8, help: []const u8) Allocator.Error!void {
        try c.sink.emit(.{
            .code = code,
            .severity = .of(code),
            .message = message,
            .spans = &.{.{ .span = span, .primary = true }},
            .help = &.{help},
        });
    }
};

/// `bufPrint` that truncates instead of failing (names are short).
fn fmt(buf: []u8, comptime format: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, format, args) catch buf;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const lexer = @import("../lex/lexer.zig");
const literals = @import("../lex/literals.zig");
const Parser = @import("Parser.zig");

/// Parses and checks `src`; returns the codes of the diagnostics in source
/// order, space-separated (`-` for a code-less syntax error).
fn codes(buf: []u8, src: []const u8) ![]const u8 {
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    const file: diag.FileId = @fromBackingInt(0);
    const tokens = try lexer.tokenize(testing.allocator, src, file, &sink, .{ .scan_literal = literals.scan });
    var ast = try Parser.parse(testing.allocator, src, tokens, file, &sink);
    defer ast.deinit(testing.allocator);
    try checkFile(testing.allocator, &ast, file, &sink);
    var w: std.Io.Writer = .fixed(buf);
    for (sink.finish(), 0..) |d, i| {
        if (i > 0) try w.writeByte(' ');
        try w.writeAll(if (d.code) |code| @tagName(code) else "-");
    }
    return w.buffered();
}

fn expectCodes(src: []const u8, want: []const u8) !void {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(want, try codes(&buf, src));
}

test "E0202: unknown attributes in every position" {
    try expectCodes("@frobnicate fn f() {}", "E0202");
    try expectCodes("struct S { @shiny x: i32 }", "E0202");
    try expectCodes("enum E { @odd a }", "E0202");
    try expectCodes("fn f(@weird x: i32) {}", "E0202");
    try expectCodes("fn g(xs: []f32) { @nonsense let x = 1; @Simd for v in xs {} }", "E0202 E0202");
    // Pass: every attribute is known and in place.
    try expectCodes("@inline @deprecated(\"x\") fn f() {}", "");
}

test "E0203: attributes in positions §8.8 does not list" {
    try expectCodes("@soa fn f() {}", "E0203");
    try expectCodes("@inline struct S { x: i32 }", "E0203");
    try expectCodes("struct T { @soa x: i32 }", "E0203");
    try expectCodes("fn g() { @simd while true {} }", "E0203");
    try expectCodes("fn g(xs: []u8) { @workgroup for x in xs {} }", "E0203");
    try expectCodes("@export fn f() {}", "E0203");
    try expectCodes("struct S { @append_only fn push(self) {} }", "E0203");
    try expectCodes("struct S { x: i32, @doc_hidden pub fn f() {} }", "");
    // Pass: each condition met.
    try expectCodes(
        \\@export("f") pub fn f() {}
        \\@trap_handler pub fn h() {}
        \\struct S { @append_only fn push(mut self) {} }
        \\@soa @align(16) struct P { @cold @align(8) x: f32 }
        \\@link("m") extern "C" { fn cos(x: f64) -> f64; }
        \\fn k(@instance i: u32) { @workgroup let t = 0; @simd for x in xs {} }
    , "");
}

test "E0207: assignment targets must be places" {
    try expectCodes("fn f(x: i32) { 1 = x; x + 1 = 2; -x = 3; x as i64 = 4; f() = 1; }", "E0207 E0207 E0207 E0207 E0207");
    try expectCodes("fn f(x: i32) { x = 1; s.a.b[0] = 2; t.0 = 3; *p = 4; (x) = 5; self.n += 1; }", "");
}

test "E0210: labels name an enclosing loop of the same function" {
    try expectCodes("fn f() { for i in xs { break :outer; } }", "E0210");
    try expectCodes("fn f() { first: while true { break; } while true { continue :first; } }", "E0210");
    try expectCodes("fn f() { l: loop { let g = || { break :l; }; } }", "E0210");
    try expectCodes("fn f() { rows: for r in g { for v in r { break :rows; continue :rows; } } }", "");
    try expectCodes("fn f() { a: while x { b: loop { break :a; continue :b; } } }", "");
}

test "E0211: alternatives bind the same names, only in match arms" {
    try expectCodes("fn f() { match s { .a(r) | .b(side) => 1, } }", "E0211");
    try expectCodes("fn f() { match t { (x, 0) | (0, y) => 1, } }", "E0211");
    try expectCodes("fn f() { match t { (x, 0) | (0, _) => 1, } }", "E0211");
    try expectCodes("fn f() { let .a(x) | .b(x) = v; }", "E0211");
    try expectCodes("fn f() { match s { .a(r) | .b(r) => r, .p | .q => 0, (x, 0) | (0, x) => x, S { x, .. } | S { y: x, .. } => x, } }", "");
    try expectCodes("fn f() { match t { (1 | 2, x) => x, } }", "");
}

test "E0501: spawn only inside a nursery of the same function" {
    try expectCodes("fn f() { spawn work(); }", "E0501");
    try expectCodes("fn f() { nursery { let t = || { spawn work(); }; } }", "E0501");
    try expectCodes("fn f() { nursery {} spawn work(); }", "E0501");
    try expectCodes("fn f() { nursery { spawn a(); if c { spawn b(); } for i in xs { spawn c(i); } nursery { spawn d(); } } }", "");
}

test "nothing is reported inside a construct that failed to parse" {
    try expectCodes("fn f() { spawn work(; }", "-");
}
