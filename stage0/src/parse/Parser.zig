//! Parser core (spec §3.1, §3.9.1, B.3): token cursor with two tokens of
//! lookahead, `expect`/`eat`, the type-context `>>`/`>>=` split, error
//! recovery with poisoned nodes, and `parseFile`.
//!
//! The grammar itself lives in one file per area, each owned by its own task,
//! so they can be written in parallel without touching this file:
//!
//! | file           | entry point      | grammar        |
//! |----------------|------------------|----------------|
//! | `items.zig`    | `parseItem`      | §3.2-§3.4      |
//! | `types.zig`    | `parseType`      | §3.6           |
//! | `patterns.zig` | `parsePattern`   | §3.7           |
//! | `expr.zig`     | `parseExpr`      | §3.8, §3.9     |
//! | `stmt.zig`     | `parseBlock`     | §3.5           |
//!
//! Every entry point has the signature `fn (*Parser) Parser.Error!Node.Index`
//! and is frozen; further modes (expr_ns, `as` targets, ...) are extra public
//! functions added by the owning file. Grammar files call each other directly.
//! The versions written with this file are balanced-skip stubs: they find
//! where their construct ends and return a skeleton.
//!
//! Errors: a grammar function that cannot continue reports one diagnostic
//! (`fail`, `failExpected`, `expect`) and returns `error.ParseError`. The
//! nearest list, statement or item loop catches it and calls `recover`, which
//! skips to a synchronization point and returns an `invalid` node poisoned in
//! the sink (T003), so later stages report nothing more about it (A.1).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("../ast/Ast.zig");
const tok = @import("../lex/token.zig");
const parallel = @import("../lex/parallel.zig");
const diag = @import("../diag/diag.zig");
const Pool = @import("../base/Pool.zig");
const items = @import("items.zig");

const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;
const TokenKind = tok.TokenKind;

const Parser = @This();

gpa: Allocator,
/// The tree being built; owns the tokens.
ast: Ast,
file: diag.FileId,
sink: *diag.Sink,
/// Current token.
tok_i: TokenIndex = 0,
/// Bytes of the current token already consumed by a `>>`/`>>=` split (0 or 1).
split: u8 = 0,
/// Shared stack for building node lists: push above the current length, pass
/// `scratch.items[top..]` to `addNode` (which copies it), then shrink back.
scratch: std.ArrayList(Node.Index) = .empty,

pub const Error = error{ OutOfMemory, ParseError };

/// Lexes `source` (file `file`, BOM stripped) with the parallel lexer and
/// parses it. Never fails on bad input: diagnostics go to `sink` and broken
/// parts become poisoned `invalid` nodes. Inherits `parallel.tokenize`'s
/// contract: never call it from inside a `pool` job or concurrently on the
/// same pool. To parse many files in parallel, lex each one sequentially
/// inside its job (`lexer.tokenize` with `literals.scan`) and call `parse`.
pub fn parseFile(
    gpa: Allocator,
    pool: *Pool,
    source: []const u8,
    file: diag.FileId,
    sink: *diag.Sink,
) error{OutOfMemory}!Ast {
    const tokens = try parallel.tokenize(gpa, pool, source, file, sink, .{});
    return parse(gpa, source, tokens, file, sink);
}

/// Parses already lexed `tokens` (ending in `eof`; ownership moves to the
/// result) into an `Ast` whose root lists the file's items.
pub fn parse(
    gpa: Allocator,
    source: []const u8,
    tokens: tok.TokenBuffer,
    file: diag.FileId,
    sink: *diag.Sink,
) error{OutOfMemory}!Ast {
    var p: Parser = .init(gpa, source, tokens, file, sink);
    defer p.deinit();
    const root = try p.addNode(0, .{ .invalid = .{} }); // reserved, set below
    std.debug.assert(root.int() == 0);
    // MODULE_DOC* (§3.2): the root's docs are these leading tokens.
    while (p.peek(0) == .doc_comment and std.mem.startsWith(u8, p.ast.tokenSlice(p.tok_i), "//!")) _ = p.next();
    while (!try items.docsThenEnd(&p, .eof)) { // W0101 for trailing docs
        const start = p.tok_i;
        const item = items.parseItem(&p) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseError => try p.recover(.item, start),
        };
        try p.scratch.append(gpa, item);
    }
    try p.ast.set(gpa, root, 0, .{ .root = .{ .items = p.scratch.items } });
    return p.takeAst();
}

/// A parser over `tokens` (taken over; freed by `deinit` unless `takeAst`).
pub fn init(gpa: Allocator, source: []const u8, tokens: tok.TokenBuffer, file: diag.FileId, sink: *diag.Sink) Parser {
    std.debug.assert(tokens.len > 0 and tokens.items(.kind)[tokens.len - 1] == .eof);
    return .{ .gpa = gpa, .ast = .{ .source = source, .tokens = tokens }, .file = file, .sink = sink };
}

pub fn deinit(p: *Parser) void {
    p.scratch.deinit(p.gpa);
    p.ast.deinit(p.gpa);
}

/// Moves the tree out; `deinit` then frees only the parser's own state.
pub fn takeAst(p: *Parser) Ast {
    const ast = p.ast;
    p.ast = .{ .source = ast.source };
    return ast;
}

// ---------------------------------------------------------------------------
// Cursor

/// Kind of the current token (`n == 0`) or the one after it (`n == 1`).
/// Two tokens is all the grammar ever needs (§3.1). After a split, the current
/// token reads as what is left of it (`>>` -> `>`, `>>=` -> `>=` or `=`).
pub fn peek(p: *const Parser, n: u1) TokenKind {
    const kinds = p.ast.tokens.items(.kind);
    const i = @min(p.tok_i + n, kinds.len - 1); // the last token is eof
    return if (n == 0) remainder(kinds[i], p.split) else kinds[i];
}

/// Advances past the current token (or what a split left of it) and returns
/// its index. Never moves past `eof`.
pub fn next(p: *Parser) TokenIndex {
    const i = p.tok_i;
    if (i + 1 < p.ast.tokens.len) p.tok_i += 1;
    p.split = 0;
    return i;
}

/// Consumes the current token if it is `kind`.
pub fn eat(p: *Parser, kind: TokenKind) ?TokenIndex {
    return if (p.peek(0) == kind) p.next() else null;
}

/// Consumes the current token, which must be `kind`; reports
/// "expected `kind`" otherwise.
pub fn expect(p: *Parser, kind: TokenKind) Error!TokenIndex {
    return p.eat(kind) orelse p.failExpected(describe(kind));
}

/// A `>` consumed by `eatGenericClose`.
pub const GenericClose = struct {
    /// The token it came from; for a split, the whole `>>` or `>>=`.
    token: TokenIndex,
    /// Exactly the consumed `>`.
    span: diag.Span,
};

/// Consumes one `>` closing generic arguments (type context only, §3.1): a
/// `>>` is split into `>` `>` and a `>>=` into `>` `>=`, the first `>`
/// consumed and the rest left as the current token. Everywhere else `>>`
/// stays one shift token. §3.1 lists only these two splits, so `>=` is never
/// split: `A<B>= 1` does not close `A<B>`.
pub fn eatGenericClose(p: *Parser) ?GenericClose {
    const k = p.peek(0);
    if (k != .gt and k != .shr and k != .shr_eq) return null;
    const start = p.tokenSpan(p.tok_i).start;
    const close: GenericClose = .{ .token = p.tok_i, .span = .{ .file = p.file, .start = start, .end = start + 1 } };
    if (k == .gt) _ = p.next() else p.split = 1;
    return close;
}

/// `eatGenericClose`, reporting "expected `>`" if there is none.
pub fn expectGenericClose(p: *Parser) Error!GenericClose {
    return p.eatGenericClose() orelse p.failExpected(describe(.gt));
}

/// What is left of `kind` after its first `split` bytes were consumed.
fn remainder(kind: TokenKind, split: u8) TokenKind {
    if (split == 0) return kind;
    return switch (kind) {
        .shr => .gt,
        .shr_eq => .gt_eq,
        else => unreachable,
    };
}

/// Source span of token `t`, or of what a split left of the current token.
pub fn tokenSpan(p: *const Parser, t: TokenIndex) diag.Span {
    const cut: u32 = if (t == p.tok_i) p.split else 0;
    const start = p.ast.tokens.items(.start)[t] + cut;
    return .{ .file = p.file, .start = start, .end = start + p.ast.tokens.items(.len)[t] - cut };
}

// ---------------------------------------------------------------------------
// Nodes and errors

/// Appends a node; see `Ast.add`.
pub fn addNode(p: *Parser, main_token: TokenIndex, d: Ast.Data) Allocator.Error!Node.Index {
    return p.ast.add(p.gpa, main_token, d);
}

/// Reports `message` at the current token and returns `error.ParseError`.
/// Nothing is reported at an `invalid` token: the lexer already did (A.1).
pub fn fail(p: *Parser, message: []const u8) Error {
    if (p.ast.tokens.items(.kind)[p.tok_i] != .invalid) {
        // Grammar violations have no A.3 code; only the rules listed there do.
        try p.sink.emit(.{
            .code = null,
            .severity = .@"error",
            .message = message,
            .spans = &.{.{ .span = p.tokenSpan(p.tok_i), .primary = true }},
        });
    }
    return error.ParseError;
}

/// Reports "expected `what`, found <current token>".
pub fn failExpected(p: *Parser, what: []const u8) Error {
    var buf: [256]u8 = undefined;
    const sp = p.tokenSpan(p.tok_i);
    const text = p.ast.source[sp.start..sp.end];
    // Quote the token's text unless it is long or would break the quoting.
    const msg = if (p.peek(0) == .eof or text.len > 64 or std.mem.indexOfScalar(u8, text, '`') != null)
        std.fmt.bufPrint(&buf, "expected {s}, found {s}", .{ what, describe(p.peek(0)) })
    else
        std.fmt.bufPrint(&buf, "expected {s}, found `{s}`", .{ what, text });
    return p.fail(msg catch unreachable);
}

/// How diagnostics name a token kind: its text in backticks, or a phrase.
pub fn describe(kind: TokenKind) []const u8 {
    return switch (kind) {
        .ident => "an identifier",
        .builtin => "a builtin",
        .int_lit => "an integer literal",
        .float_lit => "a float literal",
        .char_lit => "a character literal",
        .string_lit => "a string literal",
        .ml_string_line => "a multi-line string",
        .doc_comment => "a doc comment",
        .eof => "end of file",
        .invalid => "an invalid token",
        inline else => |k| "`" ++ comptime k.lexeme().? ++ "`",
    };
}

/// A placeholder node at token `at` for what a stub skipped. Not poisoned:
/// nothing was wrong with the input. Disappears as the stubs are replaced.
pub fn stub(p: *Parser, at: TokenIndex) Allocator.Error!Node.Index {
    return p.addNode(at, .{ .invalid = .{} });
}

// ---------------------------------------------------------------------------
// Recovery

/// Where `recover` stops skipping.
pub const Sync = enum {
    /// After a `;` or the `}` closing the broken item, or before the next
    /// item (its keyword, doc comment or attributes).
    item,
    /// After a `;` or the `}` closing the broken statement, or before the `}`
    /// closing the enclosing block.
    stmt,
    /// Before the next `,` or `;`, or the closer of the enclosing list.
    delimiter,
};

/// Call after a `ParseError` from the construct that began at token `start`.
/// Skips to the next `sync` point, keeping brackets balanced (brackets opened
/// between `start` and the error count as open), and returns an `invalid`
/// node at the error token, poisoned in the sink. An item always consumes at
/// least one token, so an item loop makes progress.
pub fn recover(p: *Parser, sync: Sync, start: TokenIndex) Allocator.Error!Node.Index {
    const at = p.tok_i;
    const n = try p.addNode(at, .{ .invalid = .{} });
    try p.sink.poison(.{ .file = p.file, .node = n.int() });

    const kinds = p.ast.tokens.items(.kind);
    var depth: u32 = 0;
    for (kinds[start..at]) |k| {
        if (isOpener(k)) depth += 1 else if (isCloser(k)) depth -|= 1;
    }
    while (true) {
        const k = p.peek(0);
        if (k == .eof) break;
        if (isOpener(k)) {
            depth += 1;
        } else if (isCloser(k)) {
            if (depth == 0) switch (sync) {
                .item => {}, // stray closer: skip it
                .stmt => if (k == .r_brace) break,
                .delimiter => break,
            } else {
                depth -= 1;
                if (depth == 0 and k == .r_brace and sync != .delimiter) {
                    _ = p.next();
                    break;
                }
            }
        } else if (depth == 0) switch (k) {
            .semicolon => if (sync == .delimiter) break else {
                _ = p.next();
                break;
            },
            .comma => if (sync == .delimiter) break,
            // Progress counts from `start`: an item that broke at the next
            // item's first token leaves that item whole.
            else => if (sync == .item and p.tok_i != start and startsItem(kinds, p.tok_i)) break,
        };
        _ = p.next();
    }
    return n;
}

/// Balanced skip for grammar stubs: consumes tokens until, at nesting depth
/// 0, one in `stop`, an unmatched closer or `eof` (none consumed). With
/// `angles` (type context), `<` opens generic arguments, closed through
/// `eatGenericClose`, and a `>`-like token outside them also stops. Returns
/// whether anything was consumed.
pub fn skipBalanced(p: *Parser, stop: []const TokenKind, angles: bool) bool {
    const begin = .{ p.tok_i, p.split };
    var depth: u32 = 0;
    var angle: u32 = 0;
    while (true) {
        const k = p.peek(0);
        if (k == .eof) break;
        if (depth == 0) {
            if (angles and isGtLike(k)) {
                if (angle == 0 or p.eatGenericClose() == null) break;
                angle -= 1;
                continue;
            }
            if (angle == 0 and std.mem.indexOfScalar(TokenKind, stop, k) != null) break;
            if (angles and k == .lt) angle += 1;
            if (isCloser(k)) break;
        }
        if (isOpener(k)) depth += 1 else if (isCloser(k)) depth -= 1;
        _ = p.next();
    }
    return p.tok_i != begin[0] or p.split != begin[1];
}

/// Consumes `open`, everything up to its matching closer, and `close`.
pub fn skipGroup(p: *Parser, open: TokenKind, close: TokenKind) Error!void {
    _ = try p.expect(open);
    _ = p.skipBalanced(&.{}, false);
    _ = try p.expect(close);
}

fn isOpener(k: TokenKind) bool {
    return k == .l_paren or k == .l_bracket or k == .l_brace or k == .dot_l_brace;
}

fn isCloser(k: TokenKind) bool {
    return k == .r_paren or k == .r_bracket or k == .r_brace;
}

fn isGtLike(k: TokenKind) bool {
    return k == .gt or k == .shr or k == .shr_eq or k == .gt_eq;
}

/// Whether an item (§3.2) starts at token `i`: an item keyword, possibly
/// after attributes (`BUILTIN ( "(" ... ")" )?`). A builtin not followed by
/// an item is an expression, not a sync point.
fn startsItem(kinds: []const TokenKind, i: TokenIndex) bool {
    var j = i;
    while (kinds[j] == .builtin) {
        j += 1;
        if (kinds[j] != .l_paren) continue;
        var depth: u32 = 0;
        while (kinds[j] != .eof) : (j += 1) {
            if (isOpener(kinds[j])) {
                depth += 1;
            } else if (isCloser(kinds[j])) {
                depth -|= 1;
                if (depth == 0) break;
            }
        }
        if (kinds[j] == .eof) return false;
        j += 1;
    }
    return isItemKeyword(kinds[j]);
}

/// Keywords that start an item (§3.2), where item recovery resumes.
fn isItemKeyword(k: TokenKind) bool {
    return switch (k) {
        .kw_use, .kw_const, .kw_type, .kw_fn, .kw_struct, .kw_enum, .kw_protocol, .kw_impl, .kw_extern, .kw_comptime, .kw_pub, .doc_comment => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const literals = @import("../lex/literals.zig");
const lexer = @import("../lex/lexer.zig");
const dump = @import("../ast/dump.zig");

const test_file: diag.FileId = @fromBackingInt(@intCast(0));

/// Parser over `src` lexed sequentially, for driving single grammar functions.
fn testParser(src: []const u8, sink: *diag.Sink) !Parser {
    const tokens = try lexer.tokenize(testing.allocator, src, test_file, sink, .{ .scan_literal = literals.scan });
    return .init(testing.allocator, src, tokens, test_file, sink);
}

/// Parses `src` through `parseFile`; returns the AST and the diagnostics.
const Parsed = struct {
    ast: Ast,
    sink: diag.Sink,
    pool: Pool,

    fn init(r: *Parsed, src: []const u8) !void {
        r.sink = .init(testing.allocator, testing.io);
        try r.pool.init(testing.allocator, testing.io, 2);
        r.ast = try parseFile(testing.allocator, &r.pool, src, test_file, &r.sink);
    }

    fn deinit(r: *Parsed) void {
        r.ast.deinit(testing.allocator);
        r.pool.deinit(testing.allocator);
        r.sink.deinit();
    }

    fn itemKinds(r: *const Parsed, buf: []Ast.NodeKind) []Ast.NodeKind {
        const its = r.ast.data(.from(0)).root.items;
        for (its, buf[0..its.len]) |n, *k| {
            const inner = if (r.ast.kind(n) == .attributed) r.ast.data(n).attributed.inner else n;
            k.* = r.ast.kind(inner);
        }
        return buf[0..its.len];
    }
};

test "peek gives two tokens of lookahead and stops at eof" {
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    var p = try testParser("a : b", &sink);
    defer p.deinit();
    try testing.expectEqual(.ident, p.peek(0));
    try testing.expectEqual(.colon, p.peek(1));
    try testing.expectEqual(0, p.eat(.ident));
    try testing.expectEqual(null, p.eat(.ident));
    try testing.expectEqual(1, try p.expect(.colon));
    try testing.expectEqual(.eof, p.peek(1));
    _ = p.next();
    try testing.expectEqual(.eof, p.peek(0));
    try testing.expectEqual(.eof, p.peek(1));
    _ = p.next(); // stays on eof
    try testing.expectEqual(.eof, p.peek(0));
    try testing.expectEqual(0, sink.finish().len);
}

test "expect reports what it wanted and what it found" {
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    var p = try testParser("fn x", &sink);
    defer p.deinit();
    try testing.expectError(error.ParseError, p.expect(.ident));
    _ = p.next();
    _ = p.next();
    try testing.expectError(error.ParseError, p.expect(.semicolon));
    const ds = sink.finish();
    try testing.expectEqual(2, ds.len);
    try testing.expectEqualStrings("expected an identifier, found `fn`", ds[0].message);
    try testing.expectEqual(null, ds[0].code);
    try testing.expectEqual(0, ds[0].primarySpan().?.start);
    try testing.expectEqualStrings("expected `;`, found end of file", ds[1].message);
}

test "`>>` is split only in type context" {
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    // Type context: `Pool<Pool<T>>` closes through a split `>>`.
    var p = try testParser("Pool<Pool<T>> >>= x", &sink);
    defer p.deinit();
    for (0..5) |_| _ = p.next();
    try testing.expectEqual(.shr, p.peek(0));
    // Each close carries the span of exactly the `>` it consumed.
    try testing.expectEqual(GenericClose{ .token = 5, .span = .{ .file = test_file, .start = 11, .end = 12 } }, p.eatGenericClose());
    try testing.expectEqual(.gt, p.peek(0));
    try testing.expectEqual(.shr_eq, p.peek(1));
    try testing.expectEqual(diag.Span{ .file = test_file, .start = 12, .end = 13 }, p.tokenSpan(5));
    try testing.expectEqual(GenericClose{ .token = 5, .span = .{ .file = test_file, .start = 12, .end = 13 } }, try p.expectGenericClose());
    // `>>=` splits into `>` and `>=`; `>=` is not split (§3.1).
    try testing.expectEqual(GenericClose{ .token = 6, .span = .{ .file = test_file, .start = 14, .end = 15 } }, p.eatGenericClose());
    try testing.expectEqual(.gt_eq, p.peek(0));
    try testing.expectEqual(null, p.eatGenericClose());
    try testing.expectEqual(6, p.eat(.gt_eq));
    try testing.expectEqual(.ident, p.peek(0));

    // Expression context: `a >> b` keeps its shift token.
    var q = try testParser("a >> b >>= c", &sink);
    defer q.deinit();
    _ = q.next();
    try testing.expectError(error.ParseError, q.expect(.gt));
    try testing.expectEqual(1, try q.expect(.shr));
    _ = q.next();
    try testing.expectEqual(3, try q.expect(.shr_eq));
}

test "split in a stubbed item: nested generics close without error" {
    var r: Parsed = undefined;
    try r.init("fn f<T: A<B<C>>>(x: Pool<Pool<T>>) -> Map<K, V>>= {}\nconst s: i32 = a >> b;\n");
    defer r.deinit();
    // `Map<K, V>>=` is a type whose `>` is followed by `>=`: the stub stops at
    // the leftover `>=`, so exactly one error, and the next item still parses.
    const ds = r.sink.finish();
    try testing.expectEqual(1, ds.len);
    try testing.expectEqualStrings("expected `{` or `;`, found `>=`", ds[0].message);
    var buf: [4]Ast.NodeKind = undefined;
    try testing.expectEqualSlices(Ast.NodeKind, &.{ .invalid, .const_decl }, r.itemKinds(&buf));
}

test "`>=` does not close generic arguments" {
    for ([_][]const u8{ "fn f<T>= () {}\n", "fn f<T: A<B>>= () {}\n" }) |src| {
        var r: Parsed = undefined;
        try r.init(src);
        defer r.deinit();
        const ds = r.sink.finish();
        try testing.expectEqual(1, ds.len);
        try testing.expectEqualStrings("expected `>`, found `>=`", ds[0].message);
    }
}

test "broken item recovers with one error" {
    const cases = [_][]const u8{
        "fn a() {}\nconst = 1;\nfn b() {}\n",
        "fn a() {}\n42 + 1 fn b() {}\n",
        "fn a() {}\nstruct S { x: i32 } }\nfn b() {}\n",
        "fn a() {}\nconst x: = 1;\nfn b() {}\n",
        "fn a() {}\ntype T = ;\nfn b() {}\n",
        // Broken right at the next item's keyword: that item survives.
        "fn a() {}\nconst fn b() {}\n",
        // The next item's attributes are not skipped as garbage.
        "fn a() {}\n42 + 1 @inline fn b() {}\n",
        "fn a() {}\n42 + 1 @extern(\"C\", x: (1)) pub fn b() {}\n",
        // A builtin call is not an item start.
        "fn a() {}\nconst x: = @sizeOf(i32);\nfn b() {}\n",
    };
    for (cases) |src| {
        var r: Parsed = undefined;
        try r.init(src);
        defer r.deinit();
        try testing.expectEqual(1, r.sink.finish().len);
        var buf: [8]Ast.NodeKind = undefined;
        const ks = r.itemKinds(&buf);
        try testing.expectEqual(.fn_decl, ks[0]);
        try testing.expectEqual(.fn_decl, ks[ks.len - 1]);
        // `itemKinds` looks through `attributed`; check the wrapper is kept.
        const its = r.ast.data(.from(0)).root.items;
        const attributed = std.mem.indexOf(u8, src, "@inline") != null or std.mem.indexOf(u8, src, "@extern") != null;
        try testing.expectEqual(attributed, r.ast.kind(its[its.len - 1]) == .attributed);
        // The broken item is one poisoned `invalid` node.
        var invalid: usize = 0;
        for (r.ast.data(.from(0)).root.items) |n| if (r.ast.kind(n) == .invalid) {
            invalid += 1;
            try testing.expect(r.sink.isPoisoned(.{ .file = test_file, .node = n.int() }));
        };
        try testing.expectEqual(1, invalid);
    }
}

test "recovery inside an item body skips nested items" {
    // An error inside the struct body: `fn m` there is not an item start.
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    var p = try testParser("struct S { x: , fn m() {} } fn b() {}", &sink);
    defer p.deinit();
    for (0..5) |_| _ = p.next(); // at `,` inside the body
    const n = try p.recover(.item, 0);
    try testing.expectEqual(.invalid, p.ast.kind(n));
    try testing.expectEqual(5, p.ast.mainToken(n));
    try testing.expectEqual(.kw_fn, p.peek(0));
    try testing.expectEqual(13, p.tok_i); // after the struct's `}`
}

test "statement and delimiter recovery stop points" {
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    var p = try testParser("{ let = ; x } (a b, c) [d e]", &sink);
    defer p.deinit();
    _ = p.next();
    _ = p.next(); // at `=`
    _ = try p.recover(.stmt, 1);
    try testing.expectEqual(.ident, p.peek(0)); // after `;`
    _ = p.next();
    _ = try p.recover(.stmt, 5); // at `}`: stays for the block to close
    try testing.expectEqual(.r_brace, p.peek(0));
    _ = p.next();
    _ = p.next();
    _ = p.next(); // at `b`
    _ = try p.recover(.delimiter, 8);
    try testing.expectEqual(.comma, p.peek(0));
    for (0..5) |_| _ = p.next(); // at `e`
    _ = try p.recover(.delimiter, 14);
    try testing.expectEqual(.r_bracket, p.peek(0));
    // A statement whose braces close ends recovery after the `}`.
    var q = try testParser("if a { b c } d", &sink);
    defer q.deinit();
    for (0..4) |_| _ = q.next(); // at `c`
    _ = try q.recover(.stmt, 0);
    try testing.expectEqual(.ident, q.peek(0));
    try testing.expectEqual(6, q.tok_i);
}

test "no parse error is reported at a token the lexer rejected" {
    var r: Parsed = undefined;
    try r.init("fn a() {}\n# fn b() {}\n");
    defer r.deinit();
    const ds = r.sink.finish();
    try testing.expectEqual(1, ds.len);
    try testing.expectEqual(.E0104, ds[0].code.?);
}

test "stubbed parse yields item skeletons" {
    const src =
        \\//! Module doc.
        \\use std.io;
        \\/// Doc.
        \\@inline pub fn add<T: Num>(a: T, b: T = 0) -> T { a + b }
        \\pub const N: u32 = 4 * 2;
        \\type Id = distinct u64;
        \\type Pair<A, B> = (A, B);
        \\struct P<T> { pub mut x: T, fn get(self) -> T { self.x } }
        \\enum E: u8 { A = 1, B }
        \\protocol Show { fn show(self) -> String; }
        \\impl<T> Show for P<T> { fn show(self) -> String { "" } }
        \\extern "C" { fn puts(s: *const u8) -> i32; }
        \\comptime { assert(N > 0); }
        \\
    ;
    var r: Parsed = undefined;
    try r.init(src);
    defer r.deinit();
    try testing.expectEqual(0, r.sink.finish().len);
    var buf: [16]Ast.NodeKind = undefined;
    try testing.expectEqualSlices(Ast.NodeKind, &.{
        .use,            .fn_decl,   .const_decl,    .type_distinct, .type_alias,
        .struct_decl,    .enum_decl, .protocol_decl, .impl_decl,     .extern_block,
        .comptime_block,
    }, r.itemKinds(&buf));

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const fn_item = r.ast.data(.from(0)).root.items[1];
    try dump.dumpNode(&r.ast, fn_item, &out.writer, 0);
    try testing.expectEqualStrings(
        \\(attributed @inline
        \\  attrs=[
        \\    (attribute @inline
        \\      args=_)]
        \\  inner=(fn_decl pub fn add
        \\    generics=[
        \\      (generic_param T
        \\        bounds=[
        \\          (path Num
        \\            last=Num)])]
        \\    params=[
        \\      (param a
        \\        ty=(path T
        \\          last=T)
        \\        default=_)
        \\      (param b
        \\        ty=(path T
        \\          last=T)
        \\        default=(invalid 0))]
        \\    ret=(path T
        \\      last=T)
        \\    body=(block {
        \\      stmts=[]
        \\      tail=_)))
    , out.written());
}

test "empty file and module docs only" {
    for ([_][]const u8{ "", "//! doc\n", "\n\n" }) |src| {
        var r: Parsed = undefined;
        try r.init(src);
        defer r.deinit();
        try testing.expectEqual(0, r.sink.finish().len);
        try testing.expectEqual(0, r.ast.data(.from(0)).root.items.len);
    }
}

test "stubs: pattern, expression and type entry points" {
    const patterns = @import("patterns.zig");
    const expr = @import("expr.zig");
    const types = @import("types.zig");
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    var p = try testParser("(a, .B(c)) = f(x, [y]) , Vec<Vec<u8>>; ;", &sink);
    defer p.deinit();
    _ = try patterns.parsePattern(&p);
    try testing.expectEqual(.eq, p.peek(0));
    _ = p.next();
    _ = try expr.parseExpr(&p);
    try testing.expectEqual(.comma, p.peek(0));
    _ = p.next();
    _ = try types.parseType(&p);
    try testing.expectEqual(.semicolon, p.peek(0));
    _ = p.next();
    try testing.expectError(error.ParseError, expr.parseExpr(&p));
    try testing.expectError(error.ParseError, types.parseType(&p));
    try testing.expectError(error.ParseError, patterns.parsePattern(&p));
    try testing.expectEqual(3, sink.finish().len);
}
