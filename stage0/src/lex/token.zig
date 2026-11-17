//! Token kinds, the SoA token buffer, keyword lookup and the literal
//! sub-scanner contract (spec §2.2, §2.4, §2.7, B.2).
//!
//! `TokenKind` is frozen: later additions go through this file's owner (T005).

const std = @import("std");

/// Kind of a token (§2.2). One byte, so `TokenBuffer.kind` is a dense `[]u8`.
///
/// Reserved keywords are named `kw_<word>`; the keyword table is derived from
/// those names, so adding a `kw_` field between `kw_as` and `kw_while` is all
/// it takes to add a keyword. A comptime check rejects any other placement.
pub const TokenKind = enum(u8) {
    ident,
    /// `@` immediately followed by an identifier (§2.5).
    builtin,

    int_lit,
    float_lit,
    char_lit,
    string_lit,
    ml_string_line,

    /// `///` or `//!` comment (§2.8).
    doc_comment,
    eof,
    /// Bytes that form no valid token; a diagnostic has been reported.
    invalid,

    // §2.4.1 reserved keywords.
    kw_as,
    kw_break,
    kw_comptime,
    kw_const,
    kw_continue,
    kw_defer,
    kw_distinct,
    kw_else,
    kw_enum,
    kw_errdefer,
    kw_extern,
    kw_false,
    kw_fn,
    kw_for,
    kw_guard,
    kw_if,
    kw_impl,
    kw_in,
    kw_inline,
    kw_launch,
    kw_let,
    kw_loop,
    kw_match,
    kw_move,
    kw_mut,
    kw_nursery,
    kw_parallel_for,
    kw_protocol,
    kw_pub,
    kw_return,
    kw_self,
    kw_Self,
    kw_soa,
    kw_spawn,
    kw_struct,
    kw_tail,
    kw_true,
    kw_type,
    kw_unsafe,
    kw_use,
    kw_where,
    kw_while,

    // §2.7 punctuators, three chars.
    shl_eq, // <<=
    shr_eq, // >>=
    dot_dot_eq, // ..=
    // Two chars.
    eq_eq, // ==
    bang_eq, // !=
    lt_eq, // <=
    gt_eq, // >=
    amp_amp, // &&
    pipe_pipe, // ||
    shl, // <<
    shr, // >>
    plus_eq, // +=
    minus_eq, // -=
    star_eq, // *=
    slash_eq, // /=
    percent_eq, // %=
    amp_eq, // &=
    pipe_eq, // |=
    caret_eq, // ^=
    arrow, // ->
    fat_arrow, // =>
    dot_dot, // ..
    dot_l_brace, // .{
    // One char.
    plus,
    minus,
    star,
    slash,
    percent,
    amp,
    pipe,
    caret,
    tilde,
    bang,
    lt,
    gt,
    eq,
    dot,
    comma,
    semicolon,
    colon,
    question,
    l_paren,
    r_paren,
    l_bracket,
    r_bracket,
    l_brace,
    r_brace,

    /// True for the §2.4.1 reserved keywords.
    pub fn isKeyword(k: TokenKind) bool {
        return @backingInt(k) >= @backingInt(TokenKind.kw_as) and
            @backingInt(k) <= @backingInt(TokenKind.kw_while);
    }

    /// The fixed source text of a keyword or punctuator, null for every other kind.
    pub fn lexeme(k: TokenKind) ?[]const u8 {
        if (k.isKeyword()) return @tagName(k)["kw_".len..];
        return switch (k) {
            .shl_eq => "<<=",
            .shr_eq => ">>=",
            .dot_dot_eq => "..=",
            .eq_eq => "==",
            .bang_eq => "!=",
            .lt_eq => "<=",
            .gt_eq => ">=",
            .amp_amp => "&&",
            .pipe_pipe => "||",
            .shl => "<<",
            .shr => ">>",
            .plus_eq => "+=",
            .minus_eq => "-=",
            .star_eq => "*=",
            .slash_eq => "/=",
            .percent_eq => "%=",
            .amp_eq => "&=",
            .pipe_eq => "|=",
            .caret_eq => "^=",
            .arrow => "->",
            .fat_arrow => "=>",
            .dot_dot => "..",
            .dot_l_brace => ".{",
            .plus => "+",
            .minus => "-",
            .star => "*",
            .slash => "/",
            .percent => "%",
            .amp => "&",
            .pipe => "|",
            .caret => "^",
            .tilde => "~",
            .bang => "!",
            .lt => "<",
            .gt => ">",
            .eq => "=",
            .dot => ".",
            .comma => ",",
            .semicolon => ";",
            .colon => ":",
            .question => "?",
            .l_paren => "(",
            .r_paren => ")",
            .l_bracket => "[",
            .r_bracket => "]",
            .l_brace => "{",
            .r_brace => "}",
            else => null,
        };
    }
};

comptime {
    std.debug.assert(@sizeOf(TokenKind) == 1);
    // isKeyword() is a range check, so every kw_ tag must sit inside kw_as..kw_while.
    for (std.meta.tags(TokenKind)) |k| {
        if (std.mem.startsWith(u8, @tagName(k), "kw_") != k.isKeyword())
            @compileError("TokenKind." ++ @tagName(k) ++ " must lie between kw_as and kw_while iff it is a kw_ tag");
    }
}

/// One token (B.2): kind plus byte range within its file. Line and column are
/// derived from `start` only when a diagnostic needs them (§2.9).
pub const Token = struct {
    kind: TokenKind,
    start: u32,
    len: u32,
};

/// Struct-of-arrays token storage: `items(.kind)`, `items(.start)`, `items(.len)`.
/// Index type for tokens elsewhere in the compiler is `u32`.
pub const TokenBuffer = std.MultiArrayList(Token);

/// §2.4.2 words: not keywords, but rejected as identifiers (E0106).
pub const future_reserved = [_][]const u8{
    "actor", "async", "await", "macro", "static", "try", "union", "var", "yield",
};

/// Returns the keyword kind for identifier bytes `word`, or null if it is not a
/// §2.4.1 keyword. Contextual keywords (§2.4.3) and §2.4.2 words return null.
pub fn keyword(word: []const u8) ?TokenKind {
    const e = lookup(word) orelse return null;
    return if (e.kind == .ident) null else e.kind;
}

/// True if `word` is a §2.4.2 reserved-for-future-use word (E0106).
pub fn isFutureReserved(word: []const u8) bool {
    const e = lookup(word) orelse return false;
    return e.kind == .ident;
}

// Perfect hash over all reserved words, built at the compiler's build time
// (B.2). Future-reserved words are stored with kind `.ident`.

const Entry = struct { text: []const u8, kind: TokenKind };

const all_words: []const Entry = blk: {
    var list: []const Entry = &.{};
    for (std.enums.values(TokenKind)) |k| {
        if (k.isKeyword()) list = list ++ [_]Entry{.{ .text = k.lexeme().?, .kind = k }};
    }
    for (future_reserved) |w| list = list ++ [_]Entry{.{ .text = w, .kind = .ident }};
    break :blk list;
};

const table_bits = 8;
const table_len = 1 << table_bits;

fn hash(seed: u32, word: []const u8) u32 {
    var h: u32 = seed ^ @as(u32, @truncate(word.len));
    for (word) |b| h = (h ^ b) *% 0x01000193;
    return h >> (32 - table_bits);
}

/// Searches seeds until every reserved word lands in its own slot. Fails the
/// build if none of the tried seeds is collision-free.
const perfect = blk: {
    @setEvalBranchQuota(100_000_000);
    var seed: u32 = 0x811c9dc5;
    for (0..10_000) |_| {
        var slots: [table_len]?Entry = @splat(null);
        const ok = for (all_words) |e| {
            const i = hash(seed, e.text);
            if (slots[i] != null) break false;
            slots[i] = e;
        } else true;
        if (ok) break :blk .{ .seed = seed, .slots = slots };
        seed +%= 0x9e3779b9;
    }
    @compileError("no collision-free keyword hash seed found");
};

fn lookup(word: []const u8) ?Entry {
    const e = perfect.slots[hash(perfect.seed, word)] orelse return null;
    return if (std.mem.eql(u8, e.text, word)) e else null;
}

// Literal sub-scanner contract (§2.6). The core lexer (T012, `lexer.zig`)
// dispatches to scanners in `literals.zig` (T013) with these signatures.

/// What the core lexer knows when it calls a literal scanner.
pub const LiteralContext = struct {
    /// The previous token was `.`: a digit run is a plain decimal `INT_LIT`
    /// with no fraction, exponent or suffix (tuple-field rule, §2.6.1).
    after_dot: bool = false,
};

/// Why a literal is malformed. The core lexer maps these to diagnostics.
pub const LiteralError = enum(u8) {
    /// E0107: `_` not between two digits.
    misplaced_underscore,
    /// E0108: literal followed by an identifier character, bad suffix, or
    /// value does not fit its suffixed type.
    bad_number,
    /// E0109: invalid escape, `\x80`-`\xFF`, surrogate or > U+10FFFF.
    bad_escape,
    /// Closing quote missing before end of line, or empty char literal.
    /// Appendix A has no dedicated code; the literal lexer picks one.
    unterminated,
};

/// Result of a literal scan. `len` always covers the whole maximal-munch run so
/// lexing resumes after it, even when `err` is set.
pub const Scan = struct {
    kind: TokenKind,
    len: u32,
    err: ?LiteralError = null,
    /// Byte offset in the file of the offending part, for the diagnostic.
    err_at: u32 = 0,
};

/// Scans one literal starting at `src[start]`: a digit for numbers, `'` for
/// chars, `"` or `r"` for strings, `\\` for multi-line string lines. `src` is
/// the whole file (or line-aligned piece); no literal crosses an LF (§2.1.1).
pub const LiteralScanFn = fn (src: []const u8, start: u32, ctx: LiteralContext) Scan;

test "every reserved keyword maps to its kind" {
    const words = [_][]const u8{
        "as",    "break",    "comptime",     "const",    "continue", "defer",  "distinct", "else",
        "enum",  "errdefer", "extern",       "false",    "fn",       "for",    "guard",    "if",
        "impl",  "in",       "inline",       "launch",   "let",      "loop",   "match",    "move",
        "mut",   "nursery",  "parallel_for", "protocol", "pub",      "return", "self",     "Self",
        "soa",   "spawn",    "struct",       "tail",     "true",     "type",   "unsafe",   "use",
        "where", "while",
    };
    var count: usize = 0;
    for (std.enums.values(TokenKind)) |k| {
        if (k.isKeyword()) count += 1;
    }
    try std.testing.expectEqual(words.len, count);
    for (words) |w| {
        const k = keyword(w) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(w, k.lexeme().?);
        try std.testing.expect(!isFutureReserved(w));
    }
    try std.testing.expectEqual(TokenKind.kw_self, keyword("self").?);
    try std.testing.expectEqual(TokenKind.kw_Self, keyword("Self").?);
}

test "contextual keywords and other words stay identifiers" {
    for ([_][]const u8{ "gpu", "cpu", "over", "result", "", "_", "SELF", "fns", "parallel", "r#type", "x" }) |w| {
        try std.testing.expectEqual(@as(?TokenKind, null), keyword(w));
        try std.testing.expect(!isFutureReserved(w));
    }
}

test "future-reserved words are flagged, not keywords" {
    for (future_reserved) |w| {
        try std.testing.expect(isFutureReserved(w));
        try std.testing.expectEqual(@as(?TokenKind, null), keyword(w));
    }
    try std.testing.expectEqual(9, future_reserved.len);
}

test "keyword hash is collision-free" {
    // Also enforced at build time by `perfect`; recheck at run time.
    var seen: [table_len]bool = @splat(false);
    for (all_words) |e| {
        const i = hash(perfect.seed, e.text);
        try std.testing.expect(!seen[i]);
        seen[i] = true;
    }
    try std.testing.expectEqual(42 + 9, all_words.len);
}

test "punctuator lexemes are unique and complete" {
    var n: usize = 0;
    for (std.enums.values(TokenKind)) |a| {
        if (a.isKeyword()) continue;
        const la = a.lexeme() orelse continue;
        n += 1;
        for (std.enums.values(TokenKind)) |b| {
            if (a == b) continue;
            if (b.lexeme()) |lb| try std.testing.expect(!std.mem.eql(u8, la, lb));
        }
    }
    try std.testing.expectEqual(3 + 20 + 24, n);
    try std.testing.expectEqualStrings(".{", TokenKind.dot_l_brace.lexeme().?);
    try std.testing.expectEqual(@as(?[]const u8, null), TokenKind.ident.lexeme());
}

test "TokenBuffer is SoA" {
    const gpa = std.testing.allocator;
    var buf: TokenBuffer = .empty;
    defer buf.deinit(gpa);
    try buf.append(gpa, .{ .kind = .kw_fn, .start = 0, .len = 2 });
    try buf.append(gpa, .{ .kind = .ident, .start = 3, .len = 4 });
    try std.testing.expectEqualSlices(TokenKind, &.{ .kw_fn, .ident }, buf.items(.kind));
    try std.testing.expectEqualSlices(u32, &.{ 0, 3 }, buf.items(.start));
}
