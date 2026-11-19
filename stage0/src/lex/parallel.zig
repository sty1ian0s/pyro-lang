//! Parallel lexing driver (spec §2.1.1, §2.9, B.2).
//!
//! No token spans a line (§2.1.1), so a file split at line starts lexes piece
//! by piece with no boundary repair: split the file into W pieces of about
//! `len / W` bytes, moving each split point forward to just after the next LF;
//! lex every piece on the job pool into its own buffer; concatenate the
//! buffers at offsets given by prefix sums of their lengths; append one `eof`.
//! Small files take the sequential path, where threading costs more than it
//! saves. Diagnostics go to the thread-safe `Sink`, whose `finish` order does
//! not depend on which thread emitted what, so the result is identical to a
//! sequential lex for any W.

const std = @import("std");
const tok = @import("token.zig");
const lexer = @import("lexer.zig");
const literals = @import("literals.zig");
const diag = @import("../diag/diag.zig");
const Pool = @import("../base/Pool.zig");

const Token = tok.Token;
const TokenBuffer = tok.TokenBuffer;

pub const Options = struct {
    /// Passed to every piece's `Lexer`.
    lex: lexer.Options = .{ .scan_literal = literals.scan },
    /// Number of pieces; `null` means one per pool worker.
    pieces: ?u32 = null,
    /// Files shorter than this many bytes are lexed sequentially.
    min_parallel_len: u32 = 64 * 1024,
};

/// Lexes all of `src` (the text of file `file`, BOM already stripped) into a
/// new buffer ending with one `eof` token at `src.len`: the same tokens, and
/// the same diagnostics on `sink`, as `lexer.tokenize`. `gpa` must be
/// thread-safe; it allocates the per-piece buffers on pool workers.
pub fn tokenize(
    gpa: std.mem.Allocator,
    pool: *Pool,
    src: []const u8,
    file: diag.FileId,
    sink: *diag.Sink,
    opts: Options,
) error{OutOfMemory}!TokenBuffer {
    const w = opts.pieces orelse pool.jobs();
    if (w <= 1 or src.len < opts.min_parallel_len)
        return lexer.tokenize(gpa, src, file, sink, opts.lex);

    const bounds = try gpa.alloc(u32, w + 1);
    defer gpa.free(bounds);
    splitAtLines(src, bounds);

    const bufs = try gpa.alloc(TokenBuffer, w);
    defer gpa.free(bufs);
    @memset(bufs, .empty);
    defer for (bufs) |*b| b.deinit(gpa);
    var failed: std.atomic.Value(bool) = .init(false);

    const Lex = struct {
        gpa: std.mem.Allocator,
        src: []const u8,
        bounds: []const u32,
        bufs: []TokenBuffer,
        failed: *std.atomic.Value(bool),
        file: diag.FileId,
        sink: *diag.Sink,
        opts: lexer.Options,

        fn run(c: @This(), _: u32, i: usize) void {
            c.lexPiece(i) catch c.failed.store(true, .monotonic);
        }

        fn lexPiece(c: @This(), i: usize) error{OutOfMemory}!void {
            var l: lexer.Lexer = .init(c.src, c.file, c.sink, c.opts);
            l.pos = c.bounds[i];
            l.end = c.bounds[i + 1];
            // A piece starts a line, so the lexer's fresh state (no previous
            // token for the tuple-field rule, §2.6.1) is already correct.
            while (true) {
                const t = try l.next();
                if (t.kind == .eof) return;
                try c.bufs[i].append(c.gpa, t);
            }
        }
    };
    pool.run(w, Lex{
        .gpa = gpa,
        .src = src,
        .bounds = bounds,
        .bufs = bufs,
        .failed = &failed,
        .file = file,
        .sink = sink,
        .opts = opts.lex,
    }, Lex.run);
    if (failed.load(.monotonic)) return error.OutOfMemory;

    // Prefix sums of the piece lengths give each piece's slot in `out`;
    // `bounds` is reused for them.
    var total: u32 = 0;
    for (bufs, 0..) |b, i| {
        bounds[i] = total;
        total += @intCast(b.len);
    }
    var out: TokenBuffer = .empty;
    errdefer out.deinit(gpa);
    try out.resize(gpa, total + 1);
    const Copy = struct {
        out: TokenBuffer.Slice,
        at: []const u32,
        bufs: []const TokenBuffer,

        fn run(c: @This(), _: u32, i: usize) void {
            const b = c.bufs[i];
            inline for (comptime std.enums.values(TokenBuffer.Field)) |f|
                @memcpy(c.out.items(f)[c.at[i]..][0..b.len], b.items(f));
        }
    };
    pool.run(w, Copy{ .out = out.slice(), .at = bounds, .bufs = bufs }, Copy.run);
    out.set(total, .{ .kind = .eof, .start = @intCast(src.len), .len = 0 });
    return out;
}

/// Fills `bounds` (W + 1 entries) with piece boundaries: `0`, then each
/// `i * len / W` moved forward to just after the next LF (or to `len`), then
/// `len`. Boundaries never decrease; pieces may be empty when a line is
/// longer than a piece.
fn splitAtLines(src: []const u8, bounds: []u32) void {
    const w = bounds.len - 1;
    bounds[0] = 0;
    for (1..w) |i| {
        const target = src.len * i / w;
        const from = @max(target, bounds[i - 1]);
        const lf = std.mem.indexOfScalarPos(u8, src, from, '\n');
        bounds[i] = @intCast(if (lf) |p| p + 1 else src.len);
    }
    bounds[w] = @intCast(src.len);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

/// Tokens and finished diagnostics of one lex.
const Result = struct {
    tokens: TokenBuffer,
    sink: diag.Sink,

    fn deinit(r: *Result) void {
        r.tokens.deinit(testing.allocator);
        r.sink.deinit();
    }
};

fn lexWith(pool: ?*Pool, src: []const u8, w: u32) !Result {
    var r: Result = .{ .tokens = .empty, .sink = .init(testing.allocator, testing.io) };
    errdefer r.sink.deinit();
    const file: diag.FileId = @fromBackingInt(@intCast(7));
    r.tokens = if (pool) |p|
        try tokenize(testing.allocator, p, src, file, &r.sink, .{ .pieces = w, .min_parallel_len = 0 })
    else
        try lexer.tokenize(testing.allocator, src, file, &r.sink, .{ .scan_literal = literals.scan });
    return r;
}

fn expectSameDiags(want: []const diag.Diagnostic, got: []const diag.Diagnostic) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |a, b| {
        try testing.expectEqual(a.code, b.code);
        try testing.expectEqual(a.primarySpan(), b.primarySpan());
        try testing.expectEqualStrings(a.message, b.message);
    }
}

/// Lexes `src` sequentially and with every W in 1..16 on `pool`, and checks
/// that tokens and diagnostics are identical.
fn expectParallelMatches(pool: *Pool, src: []const u8) !void {
    var seq = try lexWith(null, src, 1);
    defer seq.deinit();
    const want = seq.sink.finish();
    for (1..17) |w| {
        var par = try lexWith(pool, src, @intCast(w));
        defer par.deinit();
        try testing.expectEqual(seq.tokens.len, par.tokens.len);
        inline for (comptime std.enums.values(TokenBuffer.Field)) |f|
            try testing.expectEqualSlices(@FieldType(Token, @tagName(f)), seq.tokens.items(f), par.tokens.items(f));
        try expectSameDiags(want, par.sink.finish());
    }
}

/// Lines covering every token class and lexical error, including line kinds
/// a byte-chunked lexer would cut badly: multi-line string lines, comments
/// holding quotes, and unterminated literals.
const fragments = [_][]const u8{
    "fn main() -> i32 { return 0; }",
    "let s = \"a \\\"quoted\\\" \\u{1F600} string\";",
    "let r = r\"raw \\n string\";",
    "    \\\\ multi-line string line with \"quotes\" and // not a comment",
    "    \\\\",
    "// comment with \"unterminated string and \\\\ ml marker",
    "/// doc comment for the next item",
    "//! module doc",
    "//// not a doc comment",
    "t.0.1 + t.\n0.1",
    "x <<= 1..=2; y = .{ 1, 2 };",
    "let c = '\\n'; let bad = '\\u{D800}';",
    "1__000 1_ 0x_ff 0b102 300u8 1.5e10f32 .5 1.",
    "# $ ` @ size_of",
    "\"unterminated string",
    "let r#type = r#_;",
    "@size_of(T) // trailing comment ünïcödé",
    "let ü = 1;",
    "a\x00b // NUL \x00 in comment",
    "line with CRLF;\r",
    "",
    "   \t  ",
};

fn genSource(gpa: std.mem.Allocator, seed: u64, min_len: usize) ![]u8 {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rand = prng.random();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    while (out.items.len < min_len) {
        try out.appendSlice(gpa, fragments[rand.uintLessThan(usize, fragments.len)]);
        try out.append(gpa, '\n');
    }
    // Sometimes end without a final LF.
    if (rand.boolean()) out.items.len -= 1;
    return out.toOwnedSlice(gpa);
}

test "fuzz: W in 1..16 gives the same tokens and diagnostics as sequential" {
    var pool: Pool = undefined;
    try pool.init(testing.allocator, testing.io, 4);
    defer pool.deinit(testing.allocator);
    for (0..8) |seed| {
        const src = try genSource(testing.allocator, seed, 1 << 16);
        defer testing.allocator.free(src);
        try expectParallelMatches(&pool, src);
    }
}

test "every line its own piece; tuple-field rule needs no boundary state" {
    var pool: Pool = undefined;
    try pool.init(testing.allocator, testing.io, 3);
    defer pool.deinit(testing.allocator);
    // `t.` ends line 1, so `0.1` on line 2 is a float, not tuple fields;
    // `t.0.1` on line 3 is `t . 0 . 1` within one line.
    const src = "t.\n0.1\nt.0.1\n";
    // 16 pieces over 13 bytes: every line start is a split point.
    var b: [17]u32 = undefined;
    splitAtLines(src, &b);
    for (b[1..16]) |x| try testing.expect(x == 3 or x == 7 or x == src.len);
    for ([_]u32{ 3, 7 }) |x| try testing.expect(std.mem.indexOfScalar(u32, &b, x) != null);
    var par = try lexWith(&pool, src, 16);
    defer par.deinit();
    try testing.expectEqualSlices(tok.TokenKind, &.{
        .ident, .dot, .float_lit, .ident, .dot, .int_lit, .dot, .int_lit, .eof,
    }, par.tokens.items(.kind));
    try expectParallelMatches(&pool, src);
}

test "edge inputs: empty, one long line, no final LF, below threshold" {
    var pool: Pool = undefined;
    try pool.init(testing.allocator, testing.io, 2);
    defer pool.deinit(testing.allocator);
    for ([_][]const u8{ "", "\n", "\n\n\n", "x", "let x = 1; let y = 2; let z = 3;", "a\nb", "a\nb\n" }) |src|
        try expectParallelMatches(&pool, src);

    // Default options: a small file takes the sequential path and still ends in eof.
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    var t = try tokenize(testing.allocator, &pool, "a b", @fromBackingInt(@intCast(0)), &sink, .{});
    defer t.deinit(testing.allocator);
    try testing.expectEqualSlices(tok.TokenKind, &.{ .ident, .ident, .eof }, t.items(.kind));
}

test "split points land on line starts" {
    const src = "aaaa\nbb\ncccccccc\nd\n";
    var b: [5]u32 = undefined;
    splitAtLines(src, &b);
    try testing.expectEqual(0, b[0]);
    try testing.expectEqual(src.len, b[4]);
    for (b[1..4], b[0..3]) |x, prev| {
        try testing.expect(x >= prev);
        try testing.expect(x == src.len or src[x - 1] == '\n');
    }
}
