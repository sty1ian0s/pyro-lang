//! Core lexer (spec §2.1-§2.5, §2.7, §2.8): identifiers, keywords, builtins,
//! punctuators, comments and doc comments, with maximal munch. Literals are
//! delegated to a `tok.LiteralScanFn` (the T013 contract in `token.zig`).
//!
//! The lexer works on any line-aligned byte range of a file (§2.1.1, B.2): no
//! token it produces crosses an LF, so the parallel driver (T018) can run one
//! `Lexer` per piece. Source-level checks (BOM, E0101, E0102, E0103) belong to
//! the source loader (T011); a CR is treated as whitespace here so a stray one
//! is reported once, by the loader.

const std = @import("std");
const tok = @import("token.zig");
const diag = @import("../diag/diag.zig");

const TokenKind = tok.TokenKind;
const Token = tok.Token;

/// Longest identifier, in bytes (§2.3, E0105).
pub const max_ident_len = 255;

pub const Options = struct {
    /// Scanner for every literal (§2.6). Integration point for T013: pass the
    /// literal lexer's scanner here (or make it the default once
    /// `literals.zig` exists). The default is a minimal local stand-in.
    scan_literal: *const tok.LiteralScanFn = fallbackScanLiteral,
};

pub const Lexer = struct {
    /// The whole file. Token offsets are offsets into it.
    src: []const u8,
    /// Next byte to lex.
    pos: u32,
    /// End of the range to lex; must be `src.len` or just after an LF.
    end: u32,
    file: diag.FileId,
    sink: *diag.Sink,
    opts: Options = .{},
    /// Kind of the last token produced, for the tuple-field rule (§2.6.1).
    prev: ?TokenKind = null,

    /// A lexer over the whole of `src`.
    pub fn init(src: []const u8, file: diag.FileId, sink: *diag.Sink, opts: Options) Lexer {
        return .{ .src = src, .pos = 0, .end = @intCast(src.len), .file = file, .sink = sink, .opts = opts };
    }

    /// Returns the next token, or an `eof` token of length 0 at `end`.
    /// Malformed input yields diagnostics on `sink`; lexing always continues.
    pub fn next(l: *Lexer) error{OutOfMemory}!Token {
        const t = try l.scan();
        l.prev = t.kind;
        return t;
    }

    fn scan(l: *Lexer) error{OutOfMemory}!Token {
        const s = l.src[0..l.end];
        while (l.pos < l.end) {
            const start = l.pos;
            const c = s[start];
            switch (c) {
                ' ', '\t', '\n', '\r' => l.pos += 1,
                '/' => if (at(s, start + 1) == '/') {
                    if (l.comment()) |t| return t;
                } else return l.punct(),
                'A'...'Z', 'a'...'z', '_' => return l.ident(),
                '@' => {
                    if (isIdentStart(at(s, start + 1))) {
                        l.pos = identEnd(s, start + 1);
                        try l.checkLen(start, start + 1);
                        return .{ .kind = .builtin, .start = start, .len = l.pos - start };
                    }
                    return l.invalid(.E0110, start, 1, "`@` must be directly followed by a builtin name");
                },
                '0'...'9', '\'', '"' => return l.literal(),
                '\\' => if (at(s, start + 1) == '\\')
                    return l.literal()
                else
                    return l.invalid(.E0104, start, 1, "`\\` is only allowed in literals and comments"),
                '#', '$', '`' => return l.invalid(.E0104, start, 1, "this symbol is not used by Pyro"),
                0...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => return l.invalid(.E0104, start, 1, "control character outside a comment"),
                0x80...0xff => {
                    // One diagnostic per UTF-8 sequence (E0101 is the loader's).
                    var e = start + 1;
                    while (e < l.end and s[e] & 0xc0 == 0x80) e += 1;
                    return l.invalid(.E0104, start, e - start, "non-ASCII character outside a comment or literal");
                },
                else => return l.punct(),
            }
        }
        return .{ .kind = .eof, .start = l.end, .len = 0 };
    }

    /// At `//`. Returns a `doc_comment` token for `///` (not `////`) and `//!`,
    /// else skips the comment and returns null (§2.8). Any byte but LF is
    /// allowed in a comment.
    fn comment(l: *Lexer) ?Token {
        const s = l.src[0..l.end];
        const start = l.pos;
        var e = start;
        while (e < l.end and s[e] != '\n') e += 1;
        l.pos = e;
        const third = at(s, start + 2);
        const doc = third == '!' or (third == '/' and at(s, start + 3) != '/');
        if (!doc) return null;
        if (s[e - 1] == '\r') e -= 1; // CR before LF is ignored (§2.1).
        return .{ .kind = .doc_comment, .start = start, .len = e - start };
    }

    /// Identifier, keyword or raw identifier `r#name` (§2.3, §2.4).
    fn ident(l: *Lexer) error{OutOfMemory}!Token {
        const s = l.src[0..l.end];
        const start = l.pos;
        if (s[start] == 'r') switch (at(s, start + 1)) {
            '"' => return l.literal(),
            '#' => if (isIdentStart(at(s, start + 2))) {
                const name = start + 2;
                l.pos = identEnd(s, name);
                if (l.pos - name == 1 and s[name] == '_')
                    return l.invalid(.E0104, start, 3, "`r#_` is not a valid raw identifier: `_` is the wildcard, not a name");
                try l.checkLen(start, name);
                return .{ .kind = .ident, .start = start, .len = l.pos - start };
            },
            else => {},
        };
        l.pos = identEnd(s, start);
        const word = s[start..l.pos];
        if (tok.keyword(word)) |k| return .{ .kind = k, .start = start, .len = l.pos - start };
        if (tok.isFutureReserved(word)) {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "`{s}` is reserved for future use; write `r#{s}` to use it as a name", .{ word, word }) catch unreachable;
            try l.report(.E0106, start, l.pos - start, msg);
        }
        try l.checkLen(start, start);
        return .{ .kind = .ident, .start = start, .len = l.pos - start };
    }

    /// E0105 if the name starting at `name` (ending at `pos`) is too long; the
    /// diagnostic covers the whole token from `start`.
    fn checkLen(l: *Lexer, start: u32, name: u32) error{OutOfMemory}!void {
        if (l.pos - name > max_ident_len)
            try l.report(.E0105, start, l.pos - start, "identifier is longer than 255 bytes");
    }

    /// Longest punctuator at `pos` (§2.7), or E0104 if none starts here.
    fn punct(l: *Lexer) error{OutOfMemory}!Token {
        const s = l.src[l.pos..l.end];
        for (punct_by_first[s[0]]) |p| {
            if (std.mem.startsWith(u8, s, p.text)) {
                defer l.pos += @intCast(p.text.len);
                return .{ .kind = p.kind, .start = l.pos, .len = @intCast(p.text.len) };
            }
        }
        return l.invalid(.E0104, l.pos, 1, "this symbol is not used by Pyro");
    }

    fn literal(l: *Lexer) error{OutOfMemory}!Token {
        const start = l.pos;
        const r = l.opts.scan_literal(l.src[0..l.end], start, .{ .after_dot = l.prev == .dot });
        std.debug.assert(r.len > 0 and start + r.len <= l.end);
        l.pos = start + r.len;
        if (r.err) |e| {
            const code: diag.DiagCode, const msg: []const u8 = switch (e) {
                .misplaced_underscore => .{ .E0107, "`_` in a number must stand between two digits" },
                .bad_number => .{ .E0108, "malformed number literal or value does not fit its suffix type" },
                .bad_escape => .{ .E0109, "invalid escape in literal" },
                // Appendix A has no code for this; E0109 is the closest literal error.
                .unterminated => .{ .E0109, "literal is not closed on this line" },
            };
            const end = l.pos;
            const err_at = if (r.err_at >= start and r.err_at < end) r.err_at else start;
            try l.report(code, err_at, end - err_at, msg);
        }
        return .{ .kind = r.kind, .start = start, .len = r.len };
    }

    /// Reports `code` and returns an `invalid` token over `[start, start+len)`.
    fn invalid(l: *Lexer, code: diag.DiagCode, start: u32, len: u32, msg: []const u8) error{OutOfMemory}!Token {
        l.pos = start + len;
        try l.report(code, start, len, msg);
        return .{ .kind = .invalid, .start = start, .len = len };
    }

    fn report(l: *Lexer, code: diag.DiagCode, start: u32, len: u32, msg: []const u8) error{OutOfMemory}!void {
        try l.sink.emitAt(code, .{ .file = l.file, .start = start, .end = start + len }, msg);
    }
};

/// Lexes all of `src` into a new buffer ending with one `eof` token.
pub fn tokenize(gpa: std.mem.Allocator, src: []const u8, file: diag.FileId, sink: *diag.Sink, opts: Options) error{OutOfMemory}!tok.TokenBuffer {
    var buf: tok.TokenBuffer = .empty;
    errdefer buf.deinit(gpa);
    var l: Lexer = .init(src, file, sink, opts);
    while (true) {
        const t = try l.next();
        try buf.append(gpa, t);
        if (t.kind == .eof) return buf;
    }
}

fn at(s: []const u8, i: u32) u8 {
    return if (i < s.len) s[i] else 0;
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn identEnd(s: []const u8, start: u32) u32 {
    var i = start;
    while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '_')) i += 1;
    return i;
}

const Punct = struct { text: []const u8, kind: TokenKind };

/// Punctuators grouped by first byte, longest first, for maximal munch.
const punct_by_first: [256][]const Punct = blk: {
    @setEvalBranchQuota(10_000);
    var t: [256][]const Punct = @splat(&.{});
    for ([_]usize{ 3, 2, 1 }) |n| {
        for (std.enums.values(TokenKind)) |k| {
            if (k.isKeyword()) continue;
            const text = k.lexeme() orelse continue;
            if (text.len == n) t[text[0]] = t[text[0]] ++ [_]Punct{.{ .text = text, .kind = k }};
        }
    }
    const final = t;
    break :blk final;
};

/// Minimal stand-in for the T013 literal scanner: finds where each literal
/// ends and its kind, and reports only unterminated quotes.
/// shortcut: no digit, suffix, escape or range validation; replace with
/// `literals.zig`'s scanner via `Options.scan_literal` once T013 lands.
fn fallbackScanLiteral(src: []const u8, start: u32, ctx: tok.LiteralContext) tok.Scan {
    var i: u32 = start;
    switch (src[i]) {
        '0'...'9' => {
            if (ctx.after_dot) {
                while (i < src.len and std.ascii.isDigit(src[i])) i += 1;
                return .{ .kind = .int_lit, .len = i - start };
            }
            const hex = at(src, i + 1) == 'x';
            var kind: TokenKind = .int_lit;
            while (i < src.len) : (i += 1) {
                const c = src[i];
                if (std.ascii.isAlphanumeric(c) or c == '_') continue;
                if ((c == '+' or c == '-') and !hex and (src[i - 1] | 0x20) == 'e') continue;
                if (c == '.' and kind == .int_lit and std.ascii.isDigit(at(src, i + 1))) {
                    kind = .float_lit;
                    continue;
                }
                break;
            }
            return .{ .kind = kind, .len = i - start };
        },
        '\'', '"' => |q| {
            i += 1;
            while (i < src.len and src[i] != '\n') : (i += 1) {
                if (src[i] == q) return .{ .kind = if (q == '"') .string_lit else .char_lit, .len = i + 1 - start };
                if (src[i] == '\\' and at(src, i + 1) != '\n') i += 1;
            }
            return .{ .kind = if (q == '"') .string_lit else .char_lit, .len = @min(i, src.len) - start, .err = .unterminated, .err_at = start };
        },
        'r' => {
            i += 2;
            while (i < src.len and src[i] != '\n') : (i += 1) {
                if (src[i] == '"') return .{ .kind = .string_lit, .len = i + 1 - start };
            }
            return .{ .kind = .string_lit, .len = i - start, .err = .unterminated, .err_at = start };
        },
        '\\' => {
            while (i < src.len and src[i] != '\n') i += 1;
            if (src[i - 1] == '\r') i -= 1;
            return .{ .kind = .ml_string_line, .len = i - start };
        },
        else => unreachable,
    }
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

const Lexed = struct {
    tokens: tok.TokenBuffer,
    sink: diag.Sink,

    fn deinit(x: *Lexed) void {
        x.tokens.deinit(testing.allocator);
        x.sink.deinit();
    }

    fn kinds(x: *const Lexed) []const TokenKind {
        const k = x.tokens.items(.kind);
        return k[0 .. k.len - 1]; // drop eof
    }

    fn text(x: *const Lexed, src: []const u8, i: usize) []const u8 {
        const t = x.tokens.get(i);
        return src[t.start..][0..t.len];
    }

    /// Codes and start offsets of the reported diagnostics, as "E0110@4 ...".
    fn diags(x: *Lexed, buf: []u8) []const u8 {
        var w: std.Io.Writer = .fixed(buf);
        for (x.sink.finish(), 0..) |d, i| {
            if (i > 0) w.writeByte(' ') catch unreachable;
            w.print("{t}@{d}", .{ d.code.?, d.primarySpan().?.start }) catch unreachable;
        }
        return w.buffered();
    }
};

fn lexWith(src: []const u8, opts: Options) !Lexed {
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    errdefer sink.deinit();
    const tokens = try tokenize(testing.allocator, src, @fromBackingInt(@intCast(0)), &sink, opts);
    return .{ .tokens = tokens, .sink = sink };
}

fn lex(src: []const u8) !Lexed {
    return lexWith(src, .{});
}

fn expectLex(src: []const u8, kinds: []const TokenKind, diags: []const u8) !void {
    var x = try lex(src);
    defer x.deinit();
    try testing.expectEqualSlices(TokenKind, kinds, x.kinds());
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(diags, x.diags(&buf));
}

test "maximal munch of punctuators" {
    try expectLex("a <<= b ..= c .{ }", &.{ .ident, .shl_eq, .ident, .dot_dot_eq, .ident, .dot_l_brace, .r_brace }, "");
    try expectLex("<<<=", &.{ .shl, .lt_eq }, "");
    try expectLex(">>>=", &.{ .shr, .gt_eq }, "");
    try expectLex("...=", &.{ .dot_dot, .dot, .eq }, "");
    try expectLex(". {", &.{ .dot, .l_brace }, "");
    try expectLex("->=>==!=&&||", &.{ .arrow, .fat_arrow, .eq_eq, .bang_eq, .amp_amp, .pipe_pipe }, "");
    try expectLex("+-*/%&|^~!<> =.,;:?()[]{}", &.{
        .plus, .minus, .star,      .slash, .percent,  .amp,     .pipe,    .caret,     .tilde,     .bang,    .lt,      .gt, .eq,
        .dot,  .comma, .semicolon, .colon, .question, .l_paren, .r_paren, .l_bracket, .r_bracket, .l_brace, .r_brace,
    }, "");
    // Every punctuator lexes as itself on its own.
    for (std.enums.values(TokenKind)) |k| {
        if (k.isKeyword()) continue;
        const text = k.lexeme() orelse continue;
        try expectLex(text, &.{k}, "");
    }
}

test "comments and doc comments" {
    const src = "/// doc\r\n//! mod\n// plain\n////x not doc\n/////\na // tail\n///";
    var x = try lex(src);
    defer x.deinit();
    try testing.expectEqualSlices(TokenKind, &.{ .doc_comment, .doc_comment, .ident, .doc_comment }, x.kinds());
    try testing.expectEqualStrings("/// doc", x.text(src, 0));
    try testing.expectEqualStrings("//! mod", x.text(src, 1));
    try testing.expectEqualStrings("///", x.text(src, 3));
}

test "builtins and lone @" {
    try expectLex("@size_of(T)", &.{ .builtin, .l_paren, .ident, .r_paren }, "");
    try expectLex("@ size_of", &.{ .invalid, .ident }, "E0110@0");
    try expectLex("x@", &.{ .ident, .invalid }, "E0110@1");
    try expectLex("@1", &.{ .invalid, .int_lit }, "E0110@0");
}

test "NUL and control characters: ok in comments, E0104 in code" {
    try expectLex("// a\x00b\x01\x7f\n/// \x00\na", &.{ .doc_comment, .ident }, "");
    try expectLex("a\x00b", &.{ .ident, .invalid, .ident }, "E0104@1");
    try expectLex("\x7f\x0c", &.{ .invalid, .invalid }, "E0104@0 E0104@1");
    try expectLex("\ta\r\nb", &.{ .ident, .ident }, "");
}

test "unused symbols and non-ASCII are E0104" {
    try expectLex("# $ `", &.{ .invalid, .invalid, .invalid }, "E0104@0 E0104@2 E0104@4");
    try expectLex("a \\ b", &.{ .ident, .invalid, .ident }, "E0104@2");
    try expectLex("é=1", &.{ .invalid, .eq, .int_lit }, "E0104@0");
    try expectLex("// é ok\n", &.{}, "");
}

test "identifiers, keywords and raw identifiers" {
    try expectLex("fn foo _ _x Self self gpu result", &.{ .kw_fn, .ident, .ident, .ident, .kw_Self, .kw_self, .ident, .ident }, "");
    try expectLex("r#type r#_x r rx r#", &.{ .ident, .ident, .ident, .ident, .ident, .invalid }, "E0104@18");
    try expectLex("r#_ a", &.{ .invalid, .ident }, "E0104@0");
    try expectLex("let async = r#async;", &.{ .kw_let, .ident, .eq, .ident, .semicolon }, "E0106@4");
    var x = try lex("r#type");
    defer x.deinit();
    try testing.expectEqual(6, x.tokens.get(0).len);
}

test "identifier length limit E0105" {
    const ok: [255]u8 = @splat('a');
    try expectLex(&ok, &.{.ident}, "");
    try expectLex(ok ++ "b", &.{.ident}, "E0105@0");
    try expectLex("r#" ++ ok, &.{.ident}, "");
    try expectLex("x @" ++ ok ++ "b", &.{ .ident, .builtin }, "E0105@2");
}

test "literals dispatch to the scanner with the tuple-field context" {
    try expectLex("t.0.1 0..10 1.5 'a' \"s\\\"\" r\"raw\\\"", &.{
        .ident, .dot, .int_lit, .dot, .int_lit, .int_lit, .dot_dot, .int_lit, .float_lit, .char_lit, .string_lit, .string_lit,
    }, "");
    try expectLex("x = \\\\ verbatim \" ' //\n  \\\\ next\r\n;", &.{ .ident, .eq, .ml_string_line, .ml_string_line, .semicolon }, "");
    try expectLex("\"open\nx", &.{ .string_lit, .ident }, "E0109@0");
}

test "literal scanner errors map to E0107-E0109" {
    const Fake = struct {
        fn scan(src: []const u8, start: u32, ctx: tok.LiteralContext) tok.Scan {
            _ = ctx;
            const err: tok.LiteralError = switch (src[start]) {
                '1' => .misplaced_underscore,
                '2' => .bad_number,
                else => .bad_escape,
            };
            return .{ .kind = .int_lit, .len = 3, .err = err, .err_at = start + 1 };
        }
    };
    var x = try lexWith("1__ 2ab 'xy", .{ .scan_literal = Fake.scan });
    defer x.deinit();
    try testing.expectEqualSlices(TokenKind, &.{ .int_lit, .int_lit, .int_lit }, x.kinds());
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("E0107@1 E0108@5 E0109@9", x.diags(&buf));
}

test "token offsets and eof; a line-aligned range lexes on its own" {
    const src = "let x = 1;\nfoo(x);\n";
    var x = try lex(src);
    defer x.deinit();
    try testing.expectEqualStrings("foo", x.text(src, 5));
    const last = x.tokens.get(x.tokens.len - 1);
    try testing.expectEqual(Token{ .kind = .eof, .start = src.len, .len = 0 }, last);

    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    var l: Lexer = .init(src, @fromBackingInt(@intCast(0)), &sink, .{});
    l.pos = 11;
    try testing.expectEqual(Token{ .kind = .ident, .start = 11, .len = 3 }, try l.next());
}
