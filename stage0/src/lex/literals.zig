//! Literal sub-scanners (§2.6) implementing the contract in `token.zig`, plus
//! pure decode helpers the parser uses to get literal values.
//!
//! Scanners never allocate and never look past the current line (§2.1.1).
//! They do not check UTF-8 validity (E0101) or control characters (E0104):
//! those are file-wide properties the core lexer (`lexer.zig`) reports.
//! When `Scan.err` is set, `Scan.kind` is `.invalid`, so the decode helpers
//! only ever see well-formed literal text.

const std = @import("std");
const tok = @import("token.zig");
const DiagCode = @import("../diag/diag.zig").DiagCode;

const LiteralContext = tok.LiteralContext;
const LiteralError = tok.LiteralError;
const Scan = tok.Scan;

/// Dispatches on the first byte(s) at `src[start]`: a digit, `'`, `"`, `r"`
/// or `\\`. The caller guarantees one of these is present.
pub fn scan(src: []const u8, start: u32, ctx: LiteralContext) Scan {
    return switch (src[start]) {
        '0'...'9' => scanNumber(src, start, ctx),
        '\'' => scanChar(src, start, ctx),
        '"', 'r' => scanString(src, start, ctx),
        '\\' => scanMlStringLine(src, start, ctx),
        else => unreachable,
    };
}

/// The A.3 code for a literal error. Appendix A has no code for an
/// unterminated or empty literal; E0109 (malformed string or char literal) is
/// the closest fit.
pub fn diagCode(err: LiteralError) DiagCode {
    return switch (err) {
        .misplaced_underscore => .E0107,
        .bad_number => .E0108,
        .bad_escape, .unterminated => .E0109,
    };
}

comptime {
    for (.{ scan, scanNumber, scanChar, scanString, scanMlStringLine }) |f| {
        const check: tok.LiteralScanFn = f;
        _ = check;
    }
}

// Numbers (§2.6.1, §2.6.2).

/// Scans an `INT_LIT` or `FLOAT_LIT` starting at a digit. With
/// `ctx.after_dot`, scans only a plain decimal integer (tuple-field rule).
/// Any identifier characters directly after the literal are part of the run;
/// unless they form a valid suffix they are E0108. An integer whose magnitude
/// exceeds its suffix type (or `u64` when unsuffixed) is also E0108.
pub fn scanNumber(src: []const u8, start: u32, ctx: LiteralContext) Scan {
    var r: Result = .{};
    var kind: tok.TokenKind = .int_lit;
    var i = start;

    const base: u8 = if (!ctx.after_dot and src[i] == '0' and i + 1 < src.len)
        switch (src[i + 1]) {
            'x' => 16,
            'o' => 8,
            'b' => 2,
            else => 10,
        }
    else
        10;

    if (base != 10) {
        i += 2;
        if (i >= src.len or (src[i] != '_' and !isDigit(src[i], base))) r.fail(.bad_number, i);
        i = digitRun(src, i, base, &r);
    } else {
        i = digitRun(src, i, 10, &r);
        if (!ctx.after_dot) {
            // Digits are required after `.`, so `1.` and `0..10` stay integers.
            if (byteAt(src, i) == '.' and isDigit(byteAt(src, i + 1), 10)) {
                kind = .float_lit;
                i = digitRun(src, i + 1, 10, &r);
            }
            if ((byteAt(src, i) | 0x20) == 'e') {
                const sign: u32 = switch (byteAt(src, i + 1)) {
                    '+', '-' => 1,
                    else => 0,
                };
                if (isDigit(byteAt(src, i + 1 + sign), 10)) {
                    kind = .float_lit;
                    i = digitRun(src, i + 1 + sign, 10, &r);
                }
            }
        }
    }

    // Maximal munch: a literal never ends inside an identifier-character run.
    const suffix_start = i;
    while (i < src.len and isIdentChar(src[i])) i += 1;
    const suffix = src[suffix_start..i];
    if (suffix.len > 0) {
        const ok = !ctx.after_dot and switch (kind) {
            .float_lit => floatSuffix(suffix) != .none,
            else => intSuffix(suffix) != null,
        };
        if (!ok) r.fail(.bad_number, suffix_start);
    }
    if (r.err == null and kind == .int_lit) {
        _ = decodeInt(src[start..i]) catch r.fail(.bad_number, start);
    }
    return r.finish(kind, start, i);
}

/// Consumes digits of `base` and `_` from `i`; reports the first `_` that is
/// not between two digits (E0107). Returns the end of the run.
fn digitRun(src: []const u8, from: u32, base: u8, r: *Result) u32 {
    var i = from;
    while (i < src.len and (src[i] == '_' or isDigit(src[i], base))) i += 1;
    for (from..i) |p| {
        if (src[p] != '_') continue;
        if (p == from or src[p - 1] == '_' or p + 1 == i or src[p + 1] == '_') {
            r.fail(.misplaced_underscore, @intCast(p));
            break;
        }
    }
    return i;
}

/// Type suffix of an integer literal (§2.6.1).
pub const IntSuffix = union(enum) {
    none,
    /// `uN`, N in 1..=64.
    unsigned: u7,
    /// `iN`, N in 1..=64.
    signed: u7,
    usize,
    isize,

    /// Largest literal magnitude the suffix admits. For `iN` this is 2^(N-1),
    /// since `-128i8` is negation applied to `128i8` (§2.6.1); semantic
    /// analysis rejects a positive use that does not fit. `usize`/`isize`
    /// assume 64-bit; a narrower target is checked during semantic analysis.
    pub fn maxMagnitude(s: IntSuffix) u64 {
        return switch (s) {
            .none, .usize => std.math.maxInt(u64),
            .isize => 1 << 63,
            .unsigned => |n| @as(u64, std.math.maxInt(u64)) >> @intCast(64 - @as(u8, n)),
            .signed => |n| @as(u64, 1) << @intCast(n - 1),
        };
    }
};

/// Parses an integer suffix (`u8`, `i64`, `usize`, ...). Returns `.none` for
/// the empty string and null for anything that is not a valid suffix.
pub fn intSuffix(s: []const u8) ?IntSuffix {
    if (s.len == 0) return .none;
    if (std.mem.eql(u8, s, "usize")) return .usize;
    if (std.mem.eql(u8, s, "isize")) return .isize;
    // width ::= [1-9] | [1-5][0-9] | "6" [0-4]: no leading zero, 1..=64.
    if (s.len < 2 or s.len > 3 or s[1] == '0') return null;
    for (s[1..]) |c| if (!std.ascii.isDigit(c)) return null;
    const n = std.fmt.parseInt(u7, s[1..], 10) catch unreachable;
    if (n > 64) return null;
    return switch (s[0]) {
        'u' => .{ .unsigned = n },
        'i' => .{ .signed = n },
        else => null,
    };
}

/// Type suffix of a float literal (§2.6.2).
pub const FloatSuffix = enum { none, f32, f64 };

fn floatSuffix(s: []const u8) FloatSuffix {
    if (std.mem.eql(u8, s, "f32")) return .f32;
    if (std.mem.eql(u8, s, "f64")) return .f64;
    return .none;
}

/// Value of an `INT_LIT`.
pub const IntValue = struct { value: u64, suffix: IntSuffix };

/// Decodes the text of a well-formed `INT_LIT` token. Fails only if the
/// magnitude exceeds `suffix.maxMagnitude()`, which `scanNumber` reports.
pub fn decodeInt(text: []const u8) error{Overflow}!IntValue {
    // `u`/`i` are digits in no base, and `x`/`o`/`b` occur only at index 1.
    const end = std.mem.indexOfAny(u8, text, "ui") orelse text.len;
    const suffix = intSuffix(text[end..]).?;
    const base: u8 = if (text.len > 2 and text[0] == '0') switch (text[1]) {
        'x' => 16,
        'o' => 8,
        'b' => 2,
        else => 10,
    } else 10;
    const digits = if (base == 10) text[0..end] else text[2..end];
    const value = std.fmt.parseInt(u64, digits, base) catch |e| switch (e) {
        error.Overflow => return error.Overflow,
        error.InvalidCharacter => unreachable,
    };
    if (value > suffix.maxMagnitude()) return error.Overflow;
    return .{ .value = value, .suffix = suffix };
}

/// Value of a `FLOAT_LIT`.
pub const FloatValue = struct {
    /// Nearest f64; for an `f32` suffix, the nearest f32 widened (no double
    /// rounding). Out-of-range values become infinity.
    value: f64,
    suffix: FloatSuffix,
};

/// Decodes the text of a well-formed `FLOAT_LIT` token.
pub fn decodeFloat(text: []const u8) FloatValue {
    const suffix = if (text.len > 3) floatSuffix(text[text.len - 3 ..]) else .none;
    const body = if (suffix == .none) text else text[0 .. text.len - 3];
    const value: f64 = switch (suffix) {
        .f32 => std.fmt.parseFloat(f32, body) catch unreachable,
        .none, .f64 => std.fmt.parseFloat(f64, body) catch unreachable,
    };
    return .{ .value = value, .suffix = suffix };
}

// Characters and strings (§2.6.3, §2.6.4).

/// Scans a `CHAR_LIT` starting at `'`. Exactly one scalar value or escape
/// must sit between the quotes; an empty literal, more than one character or
/// a missing closing quote on the line is `.unterminated`.
pub fn scanChar(src: []const u8, start: u32, ctx: LiteralContext) Scan {
    _ = ctx;
    return scanQuoted(src, start, start + 1, '\'', .char_lit);
}

/// Scans a `STRING_LIT` starting at `"` or at the `r` of a raw `r"..."`.
pub fn scanString(src: []const u8, start: u32, ctx: LiteralContext) Scan {
    _ = ctx;
    if (src[start] == '"') return scanQuoted(src, start, start + 1, '"', .string_lit);
    std.debug.assert(src[start] == 'r' and src[start + 1] == '"');
    var i = start + 2;
    while (i < src.len and src[i] != '\n') : (i += 1) {
        if (src[i] == '"') return .{ .kind = .string_lit, .len = i + 1 - start };
    }
    return .{ .kind = .invalid, .len = i - start, .err = .unterminated, .err_at = i };
}

/// Shared loop for `'...'` and `"..."`: resolves escapes, counts scalar
/// values, and stops at the closing quote or the end of the line.
fn scanQuoted(src: []const u8, start: u32, body: u32, quote: u8, kind: tok.TokenKind) Scan {
    var r: Result = .{};
    var i = body;
    var count: u32 = 0;
    var second: u32 = 0;
    while (true) {
        if (i >= src.len or src[i] == '\n') {
            // A missing quote outranks an earlier bad escape.
            r.err = null;
            r.fail(.unterminated, i);
            return r.finish(kind, start, i);
        }
        if (src[i] == quote) break;
        // Step one byte at a time so bad UTF-8 never skips a quote or LF;
        // continuation bytes do not start a new scalar value.
        if (src[i] & 0xC0 == 0x80) {
            i += 1;
            continue;
        }
        if (count == 1) second = i;
        count += 1;
        if (src[i] == '\\') {
            const e = escape(src, i);
            if (e.value == null) r.fail(.bad_escape, i);
            i += e.len;
        } else i += 1;
    }
    i += 1;
    if (quote == '\'' and count != 1 and r.err == null) {
        r.fail(.unterminated, if (count == 0) body else second);
    }
    return r.finish(kind, start, i);
}

const Escape = struct {
    /// Bytes consumed, at least 1, never past an LF or a quote.
    len: u32,
    /// The scalar value, or null if the escape is invalid (E0109).
    value: ?u21,
};

/// Reads the escape starting at the `\` at `src[i]` (§2.6.4).
fn escape(src: []const u8, i: u32) Escape {
    const c = byteAt(src, i + 1);
    const simple: ?u21 = switch (c) {
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        '0' => 0,
        '\\', '\'', '"' => c,
        else => null,
    };
    if (simple) |v| return .{ .len = 2, .value = v };
    switch (c) {
        'x' => {
            // `\x` hex hex, at most 0x7F so strings stay valid UTF-8.
            const hi = std.fmt.charToDigit(byteAt(src, i + 2), 16) catch return .{ .len = 2, .value = null };
            const lo = std.fmt.charToDigit(byteAt(src, i + 3), 16) catch return .{ .len = 3, .value = null };
            const v = @as(u21, hi) * 16 + lo;
            return .{ .len = 4, .value = if (v <= 0x7F) v else null };
        },
        'u' => {
            // `\u{` hex{1,6} `}`, a scalar value (no surrogates, <= U+10FFFF).
            if (byteAt(src, i + 2) != '{') return .{ .len = 2, .value = null };
            var j = i + 3;
            var v: u32 = 0;
            while (std.fmt.charToDigit(byteAt(src, j), 16)) |d| : (j += 1) {
                if (j - (i + 3) < 6) v = v * 16 + d;
            } else |_| {}
            const n = j - (i + 3);
            if (byteAt(src, j) != '}') return .{ .len = j - i, .value = null };
            const ok = n >= 1 and n <= 6 and v <= 0x10FFFF and !(v >= 0xD800 and v <= 0xDFFF);
            return .{ .len = j + 1 - i, .value = if (ok) @intCast(v) else null };
        },
        // Do not swallow the line end: the literal is then unterminated.
        '\n', 0 => return .{ .len = 1, .value = null },
        else => return .{ .len = 2, .value = null },
    }
}

/// Decodes the text of a well-formed `CHAR_LIT` token to its scalar value.
/// Invalid UTF-8 (already reported as E0101) decodes to U+FFFD.
pub fn decodeChar(text: []const u8) u21 {
    const body = text[1 .. text.len - 1];
    if (body[0] == '\\') return escape(body, 0).value.?;
    const view = std.unicode.Utf8View.init(body) catch return 0xFFFD;
    var it = view.iterator();
    return it.nextCodepoint().?;
}

/// Writes the bytes of a well-formed `STRING_LIT` token (quoted or raw) to
/// `w`, with escapes resolved (§2.6.4). No NUL terminator is added.
pub fn decodeString(text: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (text[0] == 'r') return w.writeAll(text[2 .. text.len - 1]);
    const body = text[1 .. text.len - 1];
    var i: u32 = 0;
    var plain: u32 = 0;
    while (i < body.len) {
        if (body[i] != '\\') {
            i += 1;
            continue;
        }
        try w.writeAll(body[plain..i]);
        const e = escape(body, i);
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(e.value.?, &buf) catch unreachable;
        try w.writeAll(buf[0..n]);
        i += e.len;
        plain = i;
    }
    try w.writeAll(body[plain..]);
}

// Multi-line strings (§2.6.5).

/// Scans an `ML_STRING_LINE` starting at `\\`: the rest of the line, verbatim.
/// A CR directly before the LF is not part of the token (§2.1). Whether `\\`
/// starts its line is the core lexer's check.
pub fn scanMlStringLine(src: []const u8, start: u32, ctx: LiteralContext) Scan {
    _ = ctx;
    std.debug.assert(src[start] == '\\' and src[start + 1] == '\\');
    var i = start + 2;
    while (i < src.len and src[i] != '\n') i += 1;
    if (i < src.len and src[i - 1] == '\r') i -= 1;
    return .{ .kind = .ml_string_line, .len = i - start };
}

/// Content of an `ML_STRING_LINE` token: everything after `\\`, no escapes.
/// The parser joins consecutive lines with LF, with no trailing LF.
pub fn mlStringContent(text: []const u8) []const u8 {
    return text[2..];
}

// Shared helpers.

/// First error of a scan; later errors in the same literal are not reported.
const Result = struct {
    err: ?LiteralError = null,
    err_at: u32 = 0,

    fn fail(r: *Result, err: LiteralError, at: u32) void {
        if (r.err != null) return;
        r.err = err;
        r.err_at = at;
    }

    fn finish(r: Result, kind: tok.TokenKind, start: u32, end: u32) Scan {
        return .{
            .kind = if (r.err == null) kind else .invalid,
            .len = end - start,
            .err = r.err,
            .err_at = r.err_at,
        };
    }
};

/// `src[i]`, or 0 past the end (0 matches no literal character).
fn byteAt(src: []const u8, i: u32) u8 {
    return if (i < src.len) src[i] else 0;
}

fn isDigit(c: u8, base: u8) bool {
    return if (std.fmt.charToDigit(c, base)) |_| true else |_| false;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

// Tests.

const testing = std.testing;

fn expectScan(src: []const u8, start: u32, ctx: LiteralContext, kind: tok.TokenKind, len: u32) !void {
    const s = scan(src, start, ctx);
    try testing.expectEqual(@as(?LiteralError, null), s.err);
    try testing.expectEqual(kind, s.kind);
    try testing.expectEqual(len, s.len);
}

fn expectErr(src: []const u8, err: LiteralError, err_at: u32) !void {
    const s = scan(src, 0, .{});
    try testing.expectEqual(@as(?LiteralError, err), s.err);
    try testing.expectEqual(tok.TokenKind.invalid, s.kind);
    try testing.expectEqual(err_at, s.err_at);
}

test "tuple-field rule: t.0.1 lexes as t . 0 . 1" {
    try expectScan("t.0.1", 2, .{ .after_dot = true }, .int_lit, 1);
    try expectScan("t.0.1", 4, .{ .after_dot = true }, .int_lit, 1);
    // Without the rule the same bytes would be a float.
    try expectScan("t.0.1", 2, .{}, .float_lit, 3);
    // No suffix or exponent after a dot.
    try testing.expectEqual(Scan{ .kind = .invalid, .len = 3, .err = .bad_number, .err_at = 3 }, scan("x.0u8", 2, .{ .after_dot = true }));
    try testing.expectEqual(Scan{ .kind = .invalid, .len = 3, .err = .bad_number, .err_at = 3 }, scan("t.0e1", 2, .{ .after_dot = true }));
}

test "misplaced underscore is E0107" {
    try expectErr("1__000", .misplaced_underscore, 1);
    try expectErr("1_", .misplaced_underscore, 1);
    try expectErr("1_u8", .misplaced_underscore, 1);
    try expectErr("0x_1", .misplaced_underscore, 2);
    try expectErr("1.5_", .misplaced_underscore, 3);
    try expectErr("1e5_", .misplaced_underscore, 3);
    try expectScan("1_000_000", 0, .{}, .int_lit, 9);
    try expectScan("0xdead_BEEF", 0, .{}, .int_lit, 11);
    try expectScan("1_0.2_5e1_0", 0, .{}, .float_lit, 11);
    try testing.expectEqual(DiagCode.E0107, diagCode(.misplaced_underscore));
}

test "1. and .5 are not floats" {
    try expectScan("1.", 0, .{}, .int_lit, 1);
    try expectScan("1.foo", 0, .{}, .int_lit, 1);
    try expectScan("0..10", 0, .{}, .int_lit, 1);
    try expectScan("1._5", 0, .{}, .int_lit, 1);
    // `.5`: the core lexer emits `.`, then scans `5` with after_dot set.
    try expectScan(".5", 1, .{ .after_dot = true }, .int_lit, 1);
}

test "integer bases and suffixes" {
    try expectScan("0x1F + 1", 0, .{}, .int_lit, 4);
    try expectScan("0o17", 0, .{}, .int_lit, 4);
    try expectScan("0b1010u4", 0, .{}, .int_lit, 8);
    try expectScan("007", 0, .{}, .int_lit, 3);
    try expectScan("255u8", 0, .{}, .int_lit, 5);
    try expectScan("5u3", 0, .{}, .int_lit, 3);
    try expectScan("128i8", 0, .{}, .int_lit, 5);
    try expectScan("3usize", 0, .{}, .int_lit, 6);
    try expectScan("3isize", 0, .{}, .int_lit, 6);
    try expectScan("1u64", 0, .{}, .int_lit, 4);

    const v = try decodeInt("0xFF_FFu16");
    try testing.expectEqual(0xFFFF, v.value);
    try testing.expectEqual(IntSuffix{ .unsigned = 16 }, v.suffix);
    try testing.expectEqual(IntValue{ .value = 7, .suffix = .none }, try decodeInt("0b111"));
    try testing.expectEqual(IntValue{ .value = 15, .suffix = .{ .signed = 5 } }, try decodeInt("0o17i5"));
    try testing.expectEqual(IntValue{ .value = 1000, .suffix = .usize }, try decodeInt("1_000usize"));
    try testing.expectEqual(IntValue{ .value = 0, .suffix = .none }, try decodeInt("0"));
}

test "trailing identifier characters and bad suffixes are E0108" {
    try expectErr("5u128", .bad_number, 1);
    try expectErr("12abc", .bad_number, 2);
    try expectErr("5u0", .bad_number, 1);
    try expectErr("5u65", .bad_number, 1);
    try expectErr("5u08", .bad_number, 1);
    try expectErr("5i", .bad_number, 1);
    try expectErr("1f32", .bad_number, 1);
    try expectErr("1.5u8", .bad_number, 3);
    try expectErr("1e", .bad_number, 1);
    try expectErr("0b102", .bad_number, 4);
    try expectErr("0o8", .bad_number, 2);
    try expectErr("0x", .bad_number, 2);
    try expectErr("0xg", .bad_number, 2);
    // The whole run is consumed so lexing resumes after it.
    try testing.expectEqual(@as(u32, 5), scan("12abc+1", 0, .{}).len);
    try testing.expectEqual(DiagCode.E0108, diagCode(.bad_number));
}

test "magnitude must fit u64 or the suffix type (E0108)" {
    try expectScan("18446744073709551615", 0, .{}, .int_lit, 20);
    try expectErr("18446744073709551616", .bad_number, 0);
    try expectErr("0x1_0000_0000_0000_0000", .bad_number, 0);
    try expectErr("256u8", .bad_number, 0);
    try expectErr("8u3", .bad_number, 0);
    try expectErr("129i8", .bad_number, 0);
    try expectScan("9223372036854775808i64", 0, .{}, .int_lit, 22);
    try expectErr("9223372036854775809i64", .bad_number, 0);
    try expectScan("1i1", 0, .{}, .int_lit, 3);
    try expectErr("2i1", .bad_number, 0);
    try testing.expectError(error.Overflow, decodeInt("256u8"));
}

test "floats" {
    try expectScan("1.5", 0, .{}, .float_lit, 3);
    try expectScan("1e10", 0, .{}, .float_lit, 4);
    try expectScan("1E-3f32", 0, .{}, .float_lit, 7);
    try expectScan("2.5e+3f64", 0, .{}, .float_lit, 9);
    try expectScan("1.0.max", 0, .{}, .float_lit, 3);
    try testing.expectEqual(Scan{ .kind = .invalid, .len = 2, .err = .bad_number, .err_at = 1 }, scan("1e+x", 0, .{}));

    try testing.expectEqual(FloatValue{ .value = 2500, .suffix = .f64 }, decodeFloat("2.5e+3f64"));
    try testing.expectEqual(FloatValue{ .value = 1000.25, .suffix = .none }, decodeFloat("1_000.2_5"));
    const f = decodeFloat("0.1f32");
    try testing.expectEqual(FloatSuffix.f32, f.suffix);
    try testing.expectEqual(@as(f64, @as(f32, 0.1)), f.value);
}

test "char literals" {
    try expectScan("'a'", 0, .{}, .char_lit, 3);
    try expectScan("'€' x", 0, .{}, .char_lit, 5);
    try expectScan("'\\''", 0, .{}, .char_lit, 4);
    try expectScan("'\\u{1F600}'", 0, .{}, .char_lit, 11);
    try testing.expectEqual(@as(u21, 97), decodeChar("'a'"));
    try testing.expectEqual(@as(u21, 8364), decodeChar("'€'"));
    try testing.expectEqual(@as(u21, '\''), decodeChar("'\\''"));
    try testing.expectEqual(@as(u21, 0), decodeChar("'\\0'"));
    try testing.expectEqual(@as(u21, 0x7F), decodeChar("'\\x7f'"));
    try testing.expectEqual(@as(u21, 0x1F600), decodeChar("'\\u{1F600}'"));

    try expectErr("''", .unterminated, 1);
    try expectErr("'ab'", .unterminated, 2);
    try expectErr("'a\n'", .unterminated, 2);
    try expectErr("'\\q'", .bad_escape, 1);
    // Truncated UTF-8 never jumps past the closing quote or the LF.
    try expectScan("'\xC3' + 'b'", 0, .{}, .char_lit, 3);
    try expectScan("\"\xE2\" x", 0, .{}, .string_lit, 3);
    try expectErr("\"\xF0\nx = 1;\n", .unterminated, 2);
    try testing.expectEqual(@as(u32, 2), scan("\"\xF0\nx", 0, .{}).len);
    try testing.expectEqual(DiagCode.E0109, diagCode(.unterminated));
}

test "escapes: \\u{D800} and \\x80 are E0109" {
    try expectErr("\"\\u{D800}\"", .bad_escape, 1);
    try expectErr("\"\\u{DFFF}\"", .bad_escape, 1);
    try expectErr("\"\\u{110000}\"", .bad_escape, 1);
    try expectErr("\"\\u{}\"", .bad_escape, 1);
    try expectErr("\"\\u{0000041}\"", .bad_escape, 1);
    try expectErr("\"\\u41\"", .bad_escape, 1);
    try expectErr("\"\\x80\"", .bad_escape, 1);
    try expectErr("\"\\xFF\"", .bad_escape, 1);
    try expectErr("\"\\x4\"", .bad_escape, 1);
    try expectErr("\"ok\\a\"", .bad_escape, 3);
    // The whole literal is still consumed.
    try testing.expectEqual(@as(u32, 10), scan("\"\\u{D800}\";", 0, .{}).len);
    try expectScan("\"\\u{D7FF}\\u{E000}\\u{10FFFF}\\x7F\"", 0, .{}, .string_lit, 32);
    try testing.expectEqual(DiagCode.E0109, diagCode(.bad_escape));
}

test "strings and raw strings" {
    try expectScan("\"hi\" + x", 0, .{}, .string_lit, 4);
    try expectScan("\"\"", 0, .{}, .string_lit, 2);
    try expectScan("\"a\\\"b\"", 0, .{}, .string_lit, 6);
    try expectScan("r\"C:\\dir\\\"", 0, .{}, .string_lit, 10);
    try expectErr("\"abc\n\"", .unterminated, 4);
    try expectErr("\"abc\\", .unterminated, 5);
    try expectErr("\"\\u{D800}", .unterminated, 9);
    try expectErr("r\"abc", .unterminated, 5);

    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try decodeString("\"a\\tb\\n\\\\\\\"\\x41\\u{20AC}€\"", &w);
    try testing.expectEqualStrings("a\tb\n\\\"A€€", w.buffered());
    w = .fixed(&buf);
    try decodeString("r\"\\n\\x\"", &w);
    try testing.expectEqualStrings("\\n\\x", w.buffered());
}

test "multi-line string line is verbatim" {
    const src = "    \\\\usage: \"pyro\" \\n // not a comment\r\n    \\\\\n\\\\end";
    var at: u32 = 0;
    var lines: [3][]const u8 = undefined;
    for (&lines) |*line| {
        at = @intCast(std.mem.indexOfPos(u8, src, at, "\\\\").?);
        const s = scan(src, at, .{});
        try testing.expectEqual(Scan{ .kind = .ml_string_line, .len = s.len }, s);
        line.* = mlStringContent(src[at..][0..s.len]);
        at += s.len;
    }
    try testing.expectEqualStrings("usage: \"pyro\" \\n // not a comment", lines[0]);
    try testing.expectEqualStrings("", lines[1]);
    try testing.expectEqualStrings("end", lines[2]);
}
