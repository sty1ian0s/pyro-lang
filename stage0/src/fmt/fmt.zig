//! The canonical formatter behind `pyro fmt` (§13.8). The style is described in
//! `docs/style.md`.
//!
//! The formatter rewrites only what lies *between* tokens: indentation,
//! spacing inside a line, blank lines and the placement of ordinary comments.
//! It keeps every token, and every line break the source has between two
//! tokens, so the token stream and therefore the AST are unchanged (§2.1.1:
//! whitespace and ordinary comments only separate tokens). `format` re-lexes
//! its output and fails with `error.TokensChanged` rather than return text
//! whose tokens differ from the input's.
//!
//! Spacing depends on what a token is, which the token kind alone does not
//! always say (`-` is unary or binary, `<` compares or opens generic
//! arguments, `|` is bitwise or or a lambda bar), so the formatter reads the
//! roles of those tokens off the parsed `Ast`. The output is a function of the
//! tokens and the line breaks only, so formatting is idempotent.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("../ast/Ast.zig");
const tok = @import("../lex/token.zig");
const lexer = @import("../lex/lexer.zig");
const literals = @import("../lex/literals.zig");
const Parser = @import("../parse/Parser.zig");
const diag = @import("../diag/diag.zig");
const TokenKind = tok.TokenKind;

/// Spaces per indentation level.
pub const indent_width = 4;

/// Lexer options of the compiler (the real literal scanner).
pub const lex_options: lexer.Options = .{ .scan_literal = literals.scan };

pub const Error = error{ OutOfMemory, TokensChanged };

/// Lexes and parses `src` (file `file`, BOM stripped) and formats it. Returns
/// null if lexing or parsing reported an error on `sink`: a file that does not
/// parse is not formatted. The result is owned by the caller.
pub fn formatSource(gpa: Allocator, io: std.Io, src: []const u8, file: diag.FileId, sink: *diag.Sink) Error!?[]u8 {
    const tokens = try lexer.tokenize(gpa, src, file, sink, lex_options);
    var ast = try Parser.parse(gpa, src, tokens, file, sink);
    defer ast.deinit(gpa);
    if (sink.hasErrors()) return null;
    return try format(gpa, io, &ast);
}

/// Formats the file `ast` was parsed from; `ast` must have no parse errors.
/// The result is owned by the caller.
pub fn format(gpa: Allocator, io: std.Io, ast: *const Ast) Error![]u8 {
    const roles = try computeRoles(gpa, ast);
    defer gpa.free(roles);
    var f: Formatter = .{ .gpa = gpa, .ast = ast, .kinds = ast.tokens.items(.kind), .roles = roles };
    defer f.stack.deinit(gpa);
    errdefer f.out.deinit(gpa);
    try f.run();
    const out = try f.out.toOwnedSlice(gpa);
    errdefer gpa.free(out);
    if (!try sameTokens(gpa, io, ast, out)) return error.TokensChanged;
    return out;
}

/// What a token does, where its kind alone does not decide its spacing.
const Role = enum(u8) {
    none,
    /// Infix operator of a `binary`, `assign` or pattern alternative: spaced.
    binop,
    /// `..`/`..=` of a range: no space next to an operand.
    range,
    /// The bars around lambda parameters.
    lambda_open,
    lambda_close,
    /// `{` of a generic expression argument (`{CAP * 2}`) or `.{` of a `use`
    /// list: no inner spaces.
    tight_brace,
    /// Last token of an attribute: the next line starts the attributed thing.
    attr_end,
    /// `:` of `break :label` / `continue :label`.
    label_colon,
    /// The contextual keyword `over` of `launch` (an IDENT token).
    contextual_kw,
};

fn computeRoles(gpa: Allocator, ast: *const Ast) Allocator.Error![]Role {
    const kinds = ast.tokens.items(.kind);
    const roles = try gpa.alloc(Role, kinds.len);
    @memset(roles, .none);
    for (ast.nodes.items(.kind), ast.nodes.items(.main_token), 0..) |k, mt, i| {
        const n: Ast.Node.Index = .from(i);
        switch (k) {
            .binary, .assign => roles[mt] = .binop,
            .range, .pat_range => roles[mt] = .range,
            .generic_expr_arg => roles[mt] = .tight_brace,
            .use_list => roles[ast.data(ast.data(n).use_list.path).path.last + 1] = .tight_brace,
            .launch => if (ast.data(n).launch.over != null) {
                // `launch IDENT call over expr`: the first `over` outside brackets after the target.
                var depth: u32 = 0;
                var t = mt + 2;
                while (depth > 0 or kinds[t] != .ident or !std.mem.eql(u8, ast.tokenSlice(t), "over")) : (t += 1) {
                    if (isOpener(kinds[t])) depth += 1;
                    if (isCloser(kinds[t])) depth -= 1;
                }
                roles[t] = .contextual_kw;
            },
            .lambda => if (kinds[mt] == .pipe) {
                roles[mt] = .lambda_open;
                roles[closing(kinds, mt, .pipe)] = .lambda_close;
            },
            .attribute => roles[if (ast.data(n).attribute.args != null) closing(kinds, mt + 1, .r_paren) else mt] = .attr_end,
            .@"break" => if (ast.data(n).@"break".label) |l| {
                roles[l - 1] = .label_colon;
            },
            .@"continue" => if (ast.data(n).@"continue".label) |l| {
                roles[l - 1] = .label_colon;
            },
            else => {},
        }
    }
    // The remaining bars separate pattern alternatives (`pat_alt` marks only the first).
    for (kinds, roles) |k, *r| {
        if (k == .pipe and r.* == .none) r.* = .binop;
    }
    return roles;
}

/// The first `want` token after `from` outside any bracket opened after `from`.
fn closing(kinds: []const TokenKind, from: u32, want: TokenKind) u32 {
    var depth: u32 = 0;
    var i = from + 1;
    while (true) : (i += 1) {
        const k = kinds[i];
        if (depth == 0 and k == want) return i;
        if (isOpener(k)) depth += 1;
        if (isCloser(k)) depth -= 1;
    }
}

fn isOpener(k: TokenKind) bool {
    return switch (k) {
        .l_paren, .l_bracket, .l_brace, .dot_l_brace => true,
        else => false,
    };
}

fn isCloser(k: TokenKind) bool {
    return switch (k) {
        .r_paren, .r_bracket, .r_brace => true,
        else => false,
    };
}

/// An open bracket: the indentation of its line, and whether it is tight.
const Open = struct { indent: u32, tight: bool };

const Formatter = struct {
    gpa: Allocator,
    ast: *const Ast,
    kinds: []const TokenKind,
    roles: []const Role,
    out: std.ArrayList(u8) = .empty,
    stack: std.ArrayList(Open) = .empty,
    /// Indentation of the current output line, in levels.
    line_indent: u32 = 0,
    /// The last token written.
    last: ?u32 = null,
    /// Whether a comment was written after `last`.
    comment_since: bool = false,
    /// Line breaks in the source since the last token or comment.
    pending_nl: u32 = 0,
    /// Output column minus source column of the current line's first token
    /// or comment: how far re-indenting moved the line.
    shift: i64 = 0,

    fn run(f: *Formatter) Allocator.Error!void {
        const starts = f.ast.tokens.items(.start);
        const lens = f.ast.tokens.items(.len);
        var prev_end: u32 = 0;
        for (f.kinds, 0..) |k, i| {
            const t: u32 = @intCast(i);
            try f.gap(prev_end, starts[t], t);
            if (k == .eof) break;
            try f.token(t);
            prev_end = starts[t] + lens[t];
        }
        if (f.out.items.len > 0) try f.out.append(f.gpa, '\n');
    }

    /// Whitespace and ordinary comments in `source[start..end]`, before token `next`.
    fn gap(f: *Formatter, start: u32, end: u32, next: u32) Allocator.Error!void {
        const src = f.ast.source;
        var i = start;
        while (i < end) {
            switch (src[i]) {
                '\n' => {
                    f.pending_nl += 1;
                    i += 1;
                },
                '/' => {
                    const eol: u32 = @intCast(std.mem.indexOfScalarPos(u8, src[0..end], i, '\n') orelse end);
                    try f.comment(i, std.mem.trimEnd(u8, src[i..eol], " \t\r"), next);
                    i = eol;
                },
                else => i += 1, // space, tab, CR
            }
        }
    }

    /// A comment at source offset `at`, before token `next`. A comment after
    /// code keeps its source column (moved along with its line), so aligned
    /// comments stay aligned, but is at least one space from the code.
    fn comment(f: *Formatter, at: u32, text: []const u8, next: u32) Allocator.Error!void {
        if (f.out.items.len > 0 and f.pending_nl == 0) {
            const line_start = if (std.mem.lastIndexOfScalar(u8, f.out.items, '\n')) |nl| nl + 1 else 0;
            const col: i64 = @intCast(f.out.items.len - line_start);
            const want: i64 = @as(i64, f.srcColumn(at)) + f.shift;
            @memset(try f.out.addManyAsSlice(f.gpa, @intCast(@max(1, want - col))), ' ');
        } else {
            try f.startLine(f.lineIndent(next, true), false, at);
        }
        try f.out.appendSlice(f.gpa, text);
        f.comment_since = true;
    }

    /// Byte column (0-based) of source offset `at`.
    fn srcColumn(f: *const Formatter, at: u32) u32 {
        const nl = std.mem.lastIndexOfScalar(u8, f.ast.source[0..at], '\n');
        return at - if (nl) |n| @as(u32, @intCast(n)) + 1 else 0;
    }

    fn token(f: *Formatter, t: u32) Allocator.Error!void {
        const k = f.kinds[t];
        if (f.out.items.len == 0 or f.pending_nl > 0) {
            try f.startLine(f.lineIndent(t, false), isCloser(k), f.ast.tokens.items(.start)[t]);
        } else if (f.needSpace(f.last.?, t)) {
            try f.out.append(f.gpa, ' ');
        }
        try f.out.appendSlice(f.gpa, f.ast.tokenSlice(t));
        if (isOpener(k)) {
            try f.stack.append(f.gpa, .{ .indent = f.line_indent, .tight = f.roles[t] == .tight_brace });
        } else if (isCloser(k)) {
            _ = f.stack.pop();
        }
        f.last = t;
        f.comment_since = false;
    }

    /// Ends the current line (keeping at most one blank line, none after an
    /// opening or before a closing bracket) and indents the next one, which
    /// starts with what is at source offset `at`.
    fn startLine(f: *Formatter, indent: u32, before_closer: bool, at: u32) Allocator.Error!void {
        f.shift = @as(i64, indent * indent_width) - f.srcColumn(at);
        if (f.out.items.len > 0) {
            try f.out.append(f.gpa, '\n');
            const after_opener = !f.comment_since and f.last != null and isOpener(f.kinds[f.last.?]);
            if (f.pending_nl >= 2 and !after_opener and !before_closer) try f.out.append(f.gpa, '\n');
        }
        @memset(try f.out.addManyAsSlice(f.gpa, indent * indent_width), ' ');
        f.line_indent = indent;
        f.pending_nl = 0;
    }

    /// Indentation of a line starting with token `t`, or with a comment
    /// before `t` (`for_comment`): one level per enclosing bracket line, a
    /// closing bracket at its opener's level, plus one for a continuation line.
    fn lineIndent(f: *const Formatter, t: u32, for_comment: bool) u32 {
        const k = f.kinds[t];
        const top = f.stack.last();
        if (!for_comment and isCloser(k)) return if (top) |o| o.indent else 0;
        const base = if (top) |o| o.indent + 1 else 0;
        const p = f.last orelse return base;
        // Lines of one multi-line string line up.
        if (k == .ml_string_line and f.kinds[p] == .ml_string_line) return f.line_indent;
        return switch (k) {
            .eof, .r_paren, .r_bracket, .r_brace, .semicolon, .l_brace => base,
            else => base + @intFromBool(f.continues(p)),
        };
    }

    /// Whether a line after token `p` continues the statement or item `p` is in.
    fn continues(f: *const Formatter, p: u32) bool {
        return switch (f.kinds[p]) {
            .semicolon, .comma, .l_paren, .l_bracket, .l_brace, .dot_l_brace, .r_brace, .doc_comment => false,
            else => f.roles[p] != .attr_end,
        };
    }

    /// Whether tokens `a` and `b`, adjacent on one line, get a space between them.
    fn needSpace(f: *const Formatter, a: u32, b: u32) bool {
        return f.spaceByStyle(a, b) or wouldMerge(f.ast.tokenSlice(a), f.ast.tokenSlice(b));
    }

    fn spaceByStyle(f: *const Formatter, a: u32, b: u32) bool {
        const ka = f.kinds[a];
        const kb = f.kinds[b];
        const ra = f.roles[a];
        const rb = f.roles[b];
        if (kb == .doc_comment) return true;
        switch (ka) {
            .l_paren, .l_bracket => return false,
            else => {},
        }
        switch (kb) {
            .r_paren, .r_bracket, .comma, .semicolon => return false,
            else => {},
        }
        if (kb == .dot_l_brace and rb == .tight_brace) return false; // `use a.b.{x}`
        if (ka == .l_brace or ka == .dot_l_brace) return kb != .r_brace and ra != .tight_brace;
        if (kb == .r_brace) return !f.stack.getLast().tight;
        if (ka == .comma or ka == .semicolon) return !(rb == .lambda_close or f.isGenericClose(b));
        if (ka == .dot) return false;
        if (kb == .colon) return rb == .label_colon;
        if (ka == .colon) return ra != .label_colon;
        if (ra == .binop or rb == .binop) return true;
        if (ra == .range) return kb == .l_brace;
        if (rb == .range) return !f.operandEnd(a);
        if (kb == .question) return false; // postfix `?`
        if (ka == .lt or kb == .lt or f.isGenericClose(b)) return false;
        if (ra == .lambda_open or rb == .lambda_close) return false;
        switch (ka) {
            .minus, .star, .amp, .bang, .tilde => return false, // prefix operators and pointer types
            else => {},
        }
        return switch (kb) {
            .dot => !f.operandEnd(a),
            .l_paren => !(ka == .kw_fn or (ka != .r_brace and f.operandEnd(a))),
            .l_bracket => !(ka != .r_brace and f.operandEnd(a)),
            // The element type after `[N]` / `[]`.
            .ident, .builtin, .star, .kw_Self, .kw_mut, .kw_fn, .kw_soa, .kw_struct, .kw_type => ka != .r_bracket,
            else => true,
        };
    }

    /// Whether `t` can end an operand, so that `(`, `[` or `.` after it is a
    /// postfix operation.
    fn operandEnd(f: *const Formatter, t: u32) bool {
        return switch (f.kinds[t]) {
            .ident => f.roles[t] != .contextual_kw,
            .builtin, .int_lit, .float_lit, .char_lit, .string_lit => true,
            .kw_self, .kw_Self, .kw_true, .kw_false => true,
            .r_paren, .r_bracket, .r_brace, .question => true,
            else => f.isGenericClose(t),
        };
    }

    /// A `>` (or `>>`, `>>=` the parser splits) that closes generic arguments.
    fn isGenericClose(f: *const Formatter, t: u32) bool {
        return switch (f.kinds[t]) {
            .gt, .shr, .shr_eq => f.roles[t] != .binop,
            else => false,
        };
    }
};

/// Whether writing `b` directly after `a` would lex differently: two words
/// join, `//` starts a comment, or a longer punctuator forms (`>` `=`).
fn wouldMerge(a: []const u8, b: []const u8) bool {
    const x = a[a.len - 1];
    const y = b[0];
    const isWord = struct {
        fn f(c: u8) bool {
            return std.ascii.isAlphanumeric(c) or c == '_';
        }
    }.f;
    if (isWord(x) and isWord(y)) return true;
    if (x == '/' and y == '/') return true;
    for (std.enums.values(TokenKind)) |k| {
        if (k.isKeyword()) continue;
        const p = k.lexeme() orelse continue;
        if (p.len > a.len and std.mem.startsWith(u8, p, a) and std.mem.startsWith(u8, b, p[a.len..])) return true;
    }
    return false;
}

const scratch_file: diag.FileId = @fromBackingInt(@intCast(0));

/// Whether `text` lexes to the same kinds and token texts as `ast`.
fn sameTokens(gpa: Allocator, io: std.Io, ast: *const Ast, text: []const u8) Allocator.Error!bool {
    var sink: diag.Sink = .init(gpa, io);
    defer sink.deinit();
    var got = try lexer.tokenize(gpa, text, scratch_file, &sink, lex_options);
    defer got.deinit(gpa);
    if (got.len != ast.tokens.len) return false;
    for (got.items(.kind), got.items(.start), got.items(.len), 0..) |k, start, len, i| {
        if (k != ast.tokens.items(.kind)[i]) return false;
        if (!std.mem.eql(u8, text[start..][0..len], ast.tokenSlice(@intCast(i)))) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const ast_dump = @import("../ast/dump.zig");

/// Formats `src`, which must lex and parse without errors.
fn formatForTest(src: []const u8) ![]u8 {
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    return (try formatSource(testing.allocator, testing.io, src, scratch_file, &sink)) orelse error.TestUnexpectedResult;
}

fn expectFormat(src: []const u8, want: []const u8) !void {
    const got = try formatForTest(src);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
    const again = try formatForTest(got);
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(want, again);
}

test "indentation, spacing and blank lines" {
    try expectFormat(
        \\
        \\
        \\// leading comment
        \\@soa
        \\pub   struct Particle{x:f32 , y : f32,
        \\
        \\
        \\  vel :[3]f32,   // trailing
        \\}
        \\fn add<T:Num>( a:T,b:T )->T{
        \\
        \\return a+b;
        \\
        \\}
        \\
    ,
        \\// leading comment
        \\@soa
        \\pub struct Particle { x: f32, y: f32,
        \\
        \\    vel: [3]f32,   // trailing
        \\}
        \\fn add<T: Num>(a: T, b: T) -> T {
        \\    return a + b;
        \\}
        \\
    );
}

test "unary, binary, generic and lambda spacing" {
    try expectFormat(
        \\fn f(xs:[]i32,p:*const Node<Vec<u8>>)->i32{
        \\    let y=- xs[0]*2-! flag;
        \\    let g=xs.map(| x , i | x+i);
        \\    let r=xs[1 .. n];
        \\    let c=x as u32<y;
        \\    let t=foo()? .bar;
        \\    let a=.{ .red,Color.blue };
        \\    let k:Channel<Msg,{ CAP*2 }> =make();
        \\    outer : for i in 0..=10{ break : outer; }
        \\    match v { .a|.b=>1, _=>-1 }
        \\}
        \\
    ,
        \\fn f(xs: []i32, p: *const Node<Vec<u8>>) -> i32 {
        \\    let y = -xs[0] * 2 - !flag;
        \\    let g = xs.map(|x, i| x + i);
        \\    let r = xs[1..n];
        \\    let c = x as u32 < y;
        \\    let t = foo()?.bar;
        \\    let a = .{ .red, Color.blue };
        \\    let k: Channel<Msg, {CAP * 2}> = make();
        \\    outer: for i in 0..=10 { break :outer; }
        \\    match v { .a | .b => 1, _ => -1 }
        \\}
        \\
    );
}

test "use lists, open ranges, trailing commas and launch over" {
    try expectFormat(
        \\use std . mem.{ Arena,FixedArena };
        \\fn f<T,>(x:T,) {
        \\    let r = .. b;
        \\    let s = a ..;
        \\    let m = |x, y,| x;
        \\    launch cpu k(1.0) over (64, 64, 1);
        \\}
        \\
    ,
        \\use std.mem.{Arena, FixedArena};
        \\fn f<T,>(x: T,) {
        \\    let r = ..b;
        \\    let s = a..;
        \\    let m = |x, y,| x;
        \\    launch cpu k(1.0) over (64, 64, 1);
        \\}
        \\
    );
}

test "continuation lines, brackets and multi-line strings" {
    try expectFormat(
        \\const USAGE: str =
        \\\\usage: pyro
        \\      \\  --env
        \\;
        \\fn g() {
        \\let total = first
        \\+ second;
        \\call(
        \\a,
        \\    b, // why
        \\  );
        \\  // closing note
        \\}
        \\
    ,
        \\const USAGE: str =
        \\    \\usage: pyro
        \\    \\  --env
        \\;
        \\fn g() {
        \\    let total = first
        \\        + second;
        \\    call(
        \\        a,
        \\        b, // why
        \\    );
        \\    // closing note
        \\}
        \\
    );
}

test "trailing comments keep their alignment, moved with their line" {
    try expectFormat(
        \\struct S {
        \\  a: u7,          // first
        \\  bb: bool,       // second
        \\  very_long_name:u3,// third
        \\}
        \\
    ,
        \\struct S {
        \\    a: u7,          // first
        \\    bb: bool,       // second
        \\    very_long_name: u3, // third
        \\}
        \\
    );
}

test "tokens that would merge keep a space" {
    try testing.expect(wouldMerge(">", "="));
    try testing.expect(wouldMerge("&", "&"));
    try testing.expect(wouldMerge("/", "/"));
    try testing.expect(wouldMerge("as", "u32"));
    try testing.expect(!wouldMerge("(", "x"));
    try testing.expect(!wouldMerge("-", "-"));
}

test "a file with a syntax error is not formatted" {
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    try testing.expectEqual(null, try formatSource(testing.allocator, testing.io, "fn f( {", scratch_file, &sink));
}

/// Opens `rel` (relative to the repository root), searching from the current
/// directory up to 8 parents: `zig build test` may start anywhere in the repo.
fn openRepoDir(a: Allocator, rel: []const u8) !std.Io.Dir {
    var prefix: std.ArrayList(u8) = .empty;
    for (0..9) |_| {
        const path = try std.mem.concat(a, u8, &.{ prefix.items, rel });
        if (std.Io.Dir.cwd().openDir(testing.io, path, .{ .iterate = true })) |d| return d else |err| switch (err) {
            error.FileNotFound => try prefix.appendSlice(a, "../"),
            else => return err,
        }
    }
    std.debug.print("{s}/ not found; run `zig build test` inside the repository\n", .{rel});
    return error.TestUnexpectedResult;
}

fn dumpAlloc(a: Allocator, ast: *const Ast) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    try ast_dump.dump(ast, &w.writer);
    return w.written();
}

fn parseCorpus(a: Allocator, src: []const u8, sink: *diag.Sink) !Ast {
    return Parser.parse(a, src, try lexer.tokenize(a, src, scratch_file, sink, lex_options), scratch_file, sink);
}

test "corpus: formatting std/ and conformance/ keeps the AST and is idempotent" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var formatted: usize = 0;
    for ([_][]const u8{ "std", "conformance" }) |rel| {
        var dir = try openRepoDir(a, rel);
        defer dir.close(testing.io);
        var walker = try dir.walk(a);
        defer walker.deinit();
        while (try walker.next(testing.io)) |e| {
            if (e.kind != .file or !std.mem.endsWith(u8, e.path, ".pr")) continue;
            const src = try dir.readFileAlloc(testing.io, e.path, a, .limited(1 << 24));
            var sink: diag.Sink = .init(a, testing.io);
            const ast = try parseCorpus(a, src, &sink);
            if (sink.hasErrors()) continue; // a failing case: nothing to format
            const once = format(a, testing.io, &ast) catch |err| {
                std.debug.print("{s}/{s}: {t}\n", .{ rel, e.path, err });
                return err;
            };
            const twice_ast = try parseCorpus(a, once, &sink);
            const twice = try format(a, testing.io, &twice_ast);
            testing.expectEqualStrings(try dumpAlloc(a, &ast), try dumpAlloc(a, &twice_ast)) catch |err| {
                std.debug.print("{s}/{s}: AST changed\n", .{ rel, e.path });
                return err;
            };
            testing.expectEqualStrings(once, twice) catch |err| {
                std.debug.print("{s}/{s}: not idempotent\n", .{ rel, e.path });
                return err;
            };
            formatted += 1;
        }
    }
    try testing.expect(formatted > 50);
}
