//! Front-end fuzz target (T028; spec §1.4 principle 5, B.2, B.3).
//!
//! `checkInput` runs one input through the same steps as stages 1-2 of
//! `Compilation` (load, lex, parse, post-parse checks) and checks the
//! invariants the front end promises for every input, valid or not:
//!
//! - it terminates without a crash (a panic or hang fails the whole run);
//! - every diagnostic has a primary span, and every span lies inside the
//!   input file (A.1 item 2);
//! - every load and lex diagnostic carries its A.3 code (A.1 item 1). Parse
//!   diagnostics may lack one: A.3 lists codes for the §3 rules (E02xx), and
//!   `Parser.fail` reports plain grammar violations, which no code covers,
//!   with `code = null`; warnings and E02xx errors still carry theirs;
//! - lexing split into W line-aligned pieces gives the same tokens and the
//!   same diagnostics as a sequential lex (§2.1.1, B.2).
//!
//! `generate` makes deterministic inputs from a seed: random bytes, token
//! soup, and mutations of seed programs. `zig build test` runs a bounded
//! number of them; `zig build fuzz` (`main.zig`) runs them for a time limit
//! and is the nightly job. The `std.testing.fuzz` test below runs its corpus
//! in `zig build test`; `zig build test --fuzz` would drive it with Zig's
//! coverage-guided fuzzer, but Zig 0.17.1's fails on this tree ("corrupted
//! coverage file ... pcs_len was zero").

const std = @import("std");
const Allocator = std.mem.Allocator;
const fe = @import("frontend");
const diag = fe.diag;

/// An invariant `checkInput` found broken.
pub const Failure = error{
    /// A load or lex diagnostic has no A.3 code.
    MissingCode,
    /// A diagnostic has no primary span.
    MissingSpan,
    /// A span lies in another file, past the end of the input, or ends before it starts.
    BadSpan,
    /// Parallel and sequential lexing produced different tokens.
    TokensDiffer,
    /// Parallel and sequential lexing produced different diagnostics.
    DiagnosticsDiffer,
};

pub const Error = Failure || Allocator.Error;

/// Name the input is registered under.
const path = "fuzz.pr";

/// Checks the front-end invariants on `bytes`, lexing in parallel with
/// `pieces` line-aligned pieces on `pool`. `gpa` must be thread-safe.
pub fn checkInput(gpa: Allocator, io: std.Io, pool: *fe.Pool, bytes: []const u8, pieces: u32) Error!void {
    var sm: fe.SourceMap = .init(gpa, io);
    defer sm.deinit();
    var load_sink: diag.Sink = .init(gpa, io);
    defer load_sink.deinit();
    const file = try sm.addBytes(path, bytes, &load_sink);
    const text = sm.get(file).text;
    const loaded = load_sink.finish();
    try checkDiagnostics(loaded, file, text.len, .coded);
    // Like `Compilation.addLoaded`: anything but a stray CR poisons the file.
    for (loaded) |d| if (d.code != .E0102) return;

    var seq_sink: diag.Sink = .init(gpa, io);
    defer seq_sink.deinit();
    var par_sink: diag.Sink = .init(gpa, io);
    defer par_sink.deinit();
    var parse_sink: diag.Sink = .init(gpa, io);
    defer parse_sink.deinit();

    const opts: fe.parallel.Options = .{ .pieces = pieces, .min_parallel_len = 0 };
    const seq = try fe.lexer.tokenize(gpa, text, file, &seq_sink, opts.lex);
    // `parse` owns `seq` from here on, even on failure.
    var ast = try fe.Parser.parse(gpa, text, seq, file, &parse_sink);
    defer ast.deinit(gpa);
    try fe.check.checkFile(gpa, &ast, file, &parse_sink);

    var par = try fe.parallel.tokenize(gpa, pool, text, file, &par_sink, opts);
    defer par.deinit(gpa);
    if (ast.tokens.len != par.len) return error.TokensDiffer;
    inline for (comptime std.enums.values(fe.token.TokenBuffer.Field)) |f| {
        if (!std.mem.eql(@FieldType(fe.token.Token, @tagName(f)), ast.tokens.items(f), par.items(f)))
            return error.TokensDiffer;
    }

    const lex_diags = seq_sink.finish();
    try checkDiagnostics(lex_diags, file, text.len, .coded);
    try sameDiagnostics(lex_diags, par_sink.finish());
    try checkDiagnostics(parse_sink.finish(), file, text.len, .grammar_uncoded);
}

/// Whether `checkDiagnostics` accepts code-less diagnostics.
pub const Codes = enum {
    /// Every diagnostic needs a code (loading, lexing: every §2 rule has one).
    coded,
    /// Code-less errors are grammar violations (`Parser.fail`); warnings still need a code.
    grammar_uncoded,
};

/// Checks that every diagnostic in `ds` has a primary span and, as `codes`
/// says, a code, and that all its spans lie within `[0, len]` of `file`.
pub fn checkDiagnostics(ds: []const diag.Diagnostic, file: diag.FileId, len: usize, codes: Codes) Failure!void {
    for (ds) |d| {
        if (d.code == null and (codes == .coded or d.severity != .@"error")) return error.MissingCode;
        if (d.primarySpan() == null) return error.MissingSpan;
        for (d.spans) |l| try checkSpan(l.span, file, len);
        for (d.fixes) |f| try checkSpan(f.span, file, len);
        for (d.trace) |t| try checkSpan(t.span, file, len);
    }
}

fn checkSpan(s: diag.Span, file: diag.FileId, len: usize) Failure!void {
    if (s.file != file or s.start > s.end or s.end > len) return error.BadSpan;
}

fn sameDiagnostics(want: []const diag.Diagnostic, got: []const diag.Diagnostic) Failure!void {
    if (want.len != got.len) return error.DiagnosticsDiffer;
    for (want, got) |a, b| {
        if (a.code != b.code or !std.meta.eql(a.primarySpan(), b.primarySpan()) or
            !std.mem.eql(u8, a.message, b.message)) return error.DiagnosticsDiffer;
    }
}

// ---------------------------------------------------------------------------
// Input generation

/// Generated inputs stop growing at this many bytes.
pub const max_len = 16 * 1024;

/// Small programs covering the main item, statement and expression forms;
/// mutation starts from these and from any corpus the driver loads.
pub const seed_programs = [_][]const u8{
    \\//! Module doc.
    \\/// A particle stored column-wise.
    \\@soa
    \\pub struct Particle {
    \\    pub mut x: f32,
    \\    @align(8) y: f32,
    \\}
    \\
    \\enum Code: u8 { ok = 0, bad = 1 }
    \\
    \\fn sum(xs: []f32) -> f32 {
    \\    let mut s: f32 = 0.0;
    \\    for x in xs { s += x; }
    \\    s
    \\}
    \\
    ,
    \\fn classify(v: Option<i32>) -> u8 {
    \\    match v {
    \\        .some(n) if n > 0 => 1,
    \\        .some(_) => 2,
    \\        .none => 0,
    \\    }
    \\}
    \\
    \\fn shifts(a: Vec<Vec<u8>>) -> u32 { a.len() >> 1 }
    \\
    ,
    \\@link("m")
    \\extern "C" {
    \\    pub fn cos(x: f64) -> f64;
    \\}
    \\
    \\@requires(x > 0, "x must be positive")
    \\fn next(x: u32) -> u32 { x + 1 }
    \\
    \\fn strings() {
    \\    let s = "a \"quoted\" \u{1F600} string";
    \\    let r = r"raw";
    \\    let m =
    \\        \\multi-line
    \\        \\string
    \\    ;
    \\    let c = '\n';
    \\}
    \\
    ,
    \\fn loops(mut n: i64) -> i64 {
    \\    'outer: while n > 0 {
    \\        if n % 2 == 0 { n /= 2; continue 'outer; } else { n = 3 * n + 1; }
    \\        let t = .{ n, 0x_ff, 1_000u32, 1.5e3 };
    \\        let p = t.0.1;
    \\    }
    \\    return n;
    \\}
    \\
};

/// Fragments token soup and mutation insert: every keyword and punctuator,
/// plus identifiers, literals, comments, attributes and awkward bytes.
const dictionary = dict: {
    @setEvalBranchQuota(10_000);
    var words: []const []const u8 = &.{
        "x",      "T",        "self",  "r#type", "_",        "Self",         "main",
        "0",      "1_000",    "0xff",  "0b102",  "1.5e3",    "300u8",        "1.",
        "'a'",    "'\\u{0}'", "\"s\"", "\"\\q",  "r\"r\"",   "\"",           "'",
        "\\\\ m", "// c",     "/// d", "//! m",  "@soa",     "@align(8)",    "@size_of",
        "@",      "#",        "$",     "`",      "\n",       "\r\n",         "\r",
        " ",      "\t",       "\x00",  "\xff",   "\xc3\xa9", "\xef\xbb\xbf",
    };
    for (std.meta.tags(fe.token.TokenKind)) |k| {
        if (k.lexeme()) |s| words = words ++ &[_][]const u8{s};
    }
    break :dict words;
};

/// Bytes random-byte inputs draw from most of the time.
const charset = "abcxyz_019 \t\n.,;:(){}[]<>=!+-*/%&|^~?@#'\"\\r";

/// Replaces `out` with a fresh input drawn from `rand`: random bytes, token
/// soup, or a mutated program from `seed_programs` and `corpus`.
pub fn generate(gpa: Allocator, rand: std.Random, corpus: []const []const u8, out: *std.ArrayList(u8)) Allocator.Error!void {
    out.clearRetainingCapacity();
    switch (rand.uintLessThan(u8, 10)) {
        0, 1 => for (0..rand.uintAtMost(usize, 512)) |_| {
            try out.append(gpa, if (rand.uintLessThan(u8, 8) == 0)
                rand.int(u8)
            else
                charset[rand.uintLessThan(usize, charset.len)]);
        },
        2, 3, 4 => for (0..rand.uintAtMost(usize, 256)) |_| {
            try out.appendSlice(gpa, dictionary[rand.uintLessThan(usize, dictionary.len)]);
            if (rand.boolean()) try out.append(gpa, ' ');
        },
        else => {
            try out.appendSlice(gpa, pickSeed(rand, corpus));
            for (0..1 + rand.uintLessThan(usize, 8)) |_| try mutate(gpa, rand, corpus, out);
        },
    }
}

fn pickSeed(rand: std.Random, corpus: []const []const u8) []const u8 {
    const i = rand.uintLessThan(usize, seed_programs.len + corpus.len);
    return if (i < seed_programs.len) seed_programs[i] else corpus[i - seed_programs.len];
}

/// Applies one random edit to `out`.
fn mutate(gpa: Allocator, rand: std.Random, corpus: []const []const u8, out: *std.ArrayList(u8)) Allocator.Error!void {
    const len = out.items.len;
    const at = rand.uintAtMost(usize, len);
    const span = @min(len - at, rand.uintAtMost(usize, 32));
    if (len >= max_len) return out.replaceRange(gpa, at, span, "");
    switch (rand.uintLessThan(u8, 6)) {
        0 => if (at < len) {
            out.items[at] = rand.int(u8);
        },
        1 => try out.insertSlice(gpa, at, dictionary[rand.uintLessThan(usize, dictionary.len)]),
        2 => out.replaceRange(gpa, at, span, "") catch unreachable, // shrinking never allocates
        3 => {
            const copy = try gpa.dupe(u8, out.items[at..][0..span]);
            defer gpa.free(copy);
            try out.insertSlice(gpa, rand.uintAtMost(usize, len), copy);
        },
        4 => {
            const other = pickSeed(rand, corpus);
            const from = rand.uintAtMost(usize, other.len);
            const n = @min(other.len - from, rand.uintAtMost(usize, 256));
            try out.insertSlice(gpa, at, other[from..][0..n]);
        },
        else => try out.insertSlice(gpa, at, "\n"),
    }
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "seed programs satisfy every invariant" {
    var pool: fe.Pool = undefined;
    try pool.init(testing.allocator, testing.io, 4);
    defer pool.deinit(testing.allocator);
    for (seed_programs) |src| {
        for (1..6) |w| try checkInput(testing.allocator, testing.io, &pool, src, @intCast(w));
    }
}

test "broken invariants are detected" {
    const f: diag.FileId = @fromBackingInt(@intCast(0));
    const g: diag.FileId = @fromBackingInt(@intCast(1));
    const ok: diag.Label = .{ .span = .{ .file = f, .start = 1, .end = 3 }, .primary = true };
    try checkDiagnostics(&.{.{ .code = .E0101, .severity = .@"error", .message = "m", .spans = &.{ok} }}, f, 3, .coded);
    try testing.expectError(error.MissingCode, checkDiagnostics(&.{.{ .code = null, .severity = .@"error", .message = "m", .spans = &.{ok} }}, f, 3, .coded));
    try checkDiagnostics(&.{.{ .code = null, .severity = .@"error", .message = "m", .spans = &.{ok} }}, f, 3, .grammar_uncoded);
    try testing.expectError(error.MissingCode, checkDiagnostics(&.{.{ .code = null, .severity = .warning, .message = "m", .spans = &.{ok} }}, f, 3, .grammar_uncoded));
    try testing.expectError(error.MissingSpan, checkDiagnostics(&.{.{ .code = .E0101, .severity = .@"error", .message = "m" }}, f, 3, .coded));
    try testing.expectError(error.BadSpan, checkDiagnostics(&.{.{ .code = .E0101, .severity = .@"error", .message = "m", .spans = &.{ok} }}, f, 2, .coded));
    try testing.expectError(error.BadSpan, checkDiagnostics(&.{.{ .code = .E0101, .severity = .@"error", .message = "m", .spans = &.{ok} }}, g, 3, .coded));
    const backwards: diag.Label = .{ .span = .{ .file = f, .start = 2, .end = 1 } };
    try testing.expectError(error.BadSpan, checkDiagnostics(&.{.{ .code = .E0101, .severity = .@"error", .message = "m", .spans = &.{ ok, backwards } }}, f, 3, .coded));
}

test "bounded run of generated inputs" {
    var pool: fe.Pool = undefined;
    try pool.init(testing.allocator, testing.io, 4);
    defer pool.deinit(testing.allocator);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    for (0..300) |seed| {
        var prng: std.Random.DefaultPrng = .init(seed);
        const rand = prng.random();
        try generate(testing.allocator, rand, &.{}, &buf);
        try checkInput(testing.allocator, testing.io, &pool, buf.items, 1 + rand.uintLessThan(u32, 16));
    }
}

test "generation is deterministic and bounded" {
    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(testing.allocator);
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(testing.allocator);
    for (0..64) |seed| {
        var p1: std.Random.DefaultPrng = .init(seed);
        var p2: std.Random.DefaultPrng = .init(seed);
        try generate(testing.allocator, p1.random(), &.{"fn f() {}"}, &a);
        try generate(testing.allocator, p2.random(), &.{"fn f() {}"}, &b);
        try testing.expectEqualStrings(a.items, b.items);
        try testing.expect(a.items.len <= max_len + 256 + 32);
    }
}

/// Encodes `src` and `pieces` the way `fuzzOne` reads them from a `Smith`.
fn smithInput(comptime src: []const u8, comptime pieces: u64) []const u8 {
    return comptime std.mem.toBytes(std.mem.nativeToLittle(u32, src.len)) ++ src ++
        std.mem.toBytes(std.mem.nativeToLittle(u64, pieces));
}

const FuzzContext = struct { pool: *fe.Pool };

fn fuzzOne(ctx: FuzzContext, smith: *testing.Smith) anyerror!void {
    var buf: [4096]u8 = undefined;
    const n = smith.slice(&buf);
    const pieces = smith.valueRangeAtMost(u32, 1, 16);
    try checkInput(testing.allocator, testing.io, ctx.pool, buf[0..n], pieces);
}

test "fuzz: lexer and parser invariants" {
    // The pool outlives every input, so it must not use the per-input
    // `testing.allocator` the fuzzer resets.
    var pool: fe.Pool = undefined;
    try pool.init(std.heap.page_allocator, testing.io, 4);
    defer pool.deinit(std.heap.page_allocator);
    try testing.fuzz(FuzzContext{ .pool = &pool }, fuzzOne, .{ .corpus = &.{
        smithInput(seed_programs[0], 3),
        smithInput(seed_programs[1], 1),
        smithInput(seed_programs[2], 7),
        smithInput(seed_programs[3], 16),
        smithInput("fn f() { let s = \"unterminated\n}\n", 2),
    } });
}
