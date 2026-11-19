//! One compilation session (B.1, §13.7, §13.8). It owns everything the
//! pipeline shares: the input files and their ASTs, the `SourceMap`, the
//! global `Interner`, the diagnostic `Sink`, the job `Pool` (`--jobs`) and
//! the per-stage, per-thread arenas.
//!
//! `run` drives the six stages of B.1. Stages 1 (lex) and 2 (parse) are built
//! in and run in parallel; stages 3-6 are hooks that later tasks register
//! with `addHook`:
//!
//! | `HookStage` | B.1 stage                  | runs when `stop_after` is |
//! |-------------|----------------------------|---------------------------|
//! | `resolve`   | 3. collect & resolve       | check, expand, build      |
//! | `check`     | 4. comptime & check        | check, expand, build      |
//! | `expand`    | `--expand` printer (§13.7) | expand                    |
//! | `lower`     | 5. lower & optimize        | build                     |
//! | `codegen`   | 6. codegen & link          | build                     |
//!
//! `expand`, `lower` and `codegen` run only if no error was reported so
//! far, counting warnings promoted by `@deny` (`Sink.hasErrors`): no output
//! is produced from a program with errors. Within a stage,
//! hooks run in registration order. A hook does its own parallelism on
//! `pool` and reports through `sink`, whose `finish` order does not depend
//! on thread timing, so diagnostics are identical for every `--jobs`.
//!
//! A file whose text is unusable (E0101 invalid UTF-8, E0103 too large) is
//! poisoned: stages 1-2 skip it, its `ast` stays empty, and later stages
//! must skip it too (A.1: no cascading errors). A stray CR (E0102) does not
//! poison: the lexer treats it as whitespace, so the file's other errors are
//! still reported (A.1).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const diag = @import("../diag/diag.zig");
const SourceMap = @import("../source/SourceMap.zig");
const Interner = @import("../base/Interner.zig");
const Pool = @import("../base/Pool.zig");
const Arena = @import("../base/Arena.zig");
const Ast = @import("../ast/Ast.zig");
const lexer = @import("../lex/lexer.zig");
const parallel = @import("../lex/parallel.zig");
const Parser = @import("../parse/Parser.zig");

const Compilation = @This();

/// Thread-safe: stages 1-2 allocate from it on pool workers.
gpa: Allocator,
io: Io,
options: Options,
sources: SourceMap,
interner: Interner,
sink: diag.Sink,
pool: Pool,
/// Input files in the order they were added; `files.items[i].id` is the
/// `FileId` the source map gave the i-th file.
files: std.ArrayList(File) = .empty,
hooks: [hook_stages.len]std.ArrayList(Hook) = @splat(.empty),
/// One `Arena.PerThread` per hook stage; see `arena`.
arenas: [hook_stages.len]Arena.PerThread,

/// Last stage `run` performs (`--stop-after`, `pyro check`, `--expand`).
pub const StopAfter = enum { lex, parse, check, expand, build };

/// Extension points for stages 3-6, in the order `run` calls them.
pub const HookStage = enum { resolve, check, expand, lower, codegen };

const hook_stages = std.enums.values(HookStage);

/// A pass registered on a `HookStage`. `run` is called once per `Compilation.run`
/// with the session; it reports problems in the user's program through
/// `comp.sink` and returns an error only for internal failures (out of
/// memory, I/O), which abort the pipeline.
pub const Hook = struct {
    ctx: ?*anyopaque = null,
    run: *const fn (ctx: ?*anyopaque, comp: *Compilation) anyerror!void,
};

pub const Options = struct {
    /// Worker count (`--jobs n`); `null` means one per logical CPU.
    jobs: ?u32 = null,
    stop_after: StopAfter = .build,
};

/// One input file.
pub const File = struct {
    id: diag.FileId,
    /// Loading found the text unusable; see the file comment.
    poisoned: bool,
    /// After stage 1, the file's tokens; after stage 2, also its tree.
    /// `ast.source` is the file's text from the source map.
    ast: Ast,
};

/// Initialises the session in place: it must not move afterwards (the pool
/// and the sink hold their own addresses).
pub fn init(comp: *Compilation, gpa: Allocator, io: Io, options: Options) !void {
    comp.* = .{
        .gpa = gpa,
        .io = io,
        .options = options,
        .sources = .init(gpa, io),
        .interner = .init(gpa, io),
        .sink = .init(gpa, io),
        .pool = undefined,
        .arenas = undefined,
    };
    errdefer {
        comp.sink.deinit();
        comp.interner.deinit();
        comp.sources.deinit();
    }
    try comp.pool.init(gpa, io, options.jobs);
    errdefer comp.pool.deinit(gpa);
    for (&comp.arenas, 0..) |*a, i| a.* = Arena.PerThread.init(gpa, comp.pool.jobs()) catch |err| {
        for (comp.arenas[0..i]) |*done| done.deinit(gpa);
        return err;
    };
}

pub fn deinit(comp: *Compilation) void {
    const gpa = comp.gpa;
    for (comp.files.items) |*f| f.ast.deinit(gpa);
    comp.files.deinit(gpa);
    for (&comp.hooks) |*h| h.deinit(gpa);
    for (&comp.arenas) |*a| a.deinit(gpa);
    comp.pool.deinit(gpa);
    comp.sink.deinit();
    comp.interner.deinit();
    comp.sources.deinit();
    comp.* = undefined;
}

/// Memory-maps `sub_path` (relative to `dir`) as an input file. Loading
/// errors are reported and may poison the file; only I/O failures return an error.
pub fn addFile(comp: *Compilation, dir: Io.Dir, sub_path: []const u8) !diag.FileId {
    var local: diag.Sink = .init(comp.gpa, comp.io);
    defer local.deinit();
    return comp.addLoaded(try comp.sources.load(dir, sub_path, &local), &local);
}

/// Adds in-memory contents (copied) as an input file named `path`.
pub fn addSource(comp: *Compilation, path: []const u8, bytes: []const u8) !diag.FileId {
    var local: diag.Sink = .init(comp.gpa, comp.io);
    defer local.deinit();
    return comp.addLoaded(try comp.sources.addBytes(path, bytes, &local), &local);
}

/// Records file `id`, poisoned if loading it reported anything but E0102
/// into `local`.
fn addLoaded(comp: *Compilation, id: diag.FileId, local: *diag.Sink) !diag.FileId {
    const ds = local.finish();
    var poisoned = false;
    for (ds) |d| {
        try comp.sink.emit(d);
        if (d.code != .E0102) poisoned = true;
    }
    // Node 0 is a file's root: cascades about the file as a whole are dropped.
    if (poisoned) try comp.sink.poison(.{ .file = id, .node = 0 });
    try comp.files.append(comp.gpa, .{
        .id = id,
        .poisoned = poisoned,
        .ast = .{ .source = comp.sources.get(id).text },
    });
    return id;
}

/// Registers `hook` to run at `stage`, after the hooks registered before it.
pub fn addHook(comp: *Compilation, stage: HookStage, hook: Hook) Allocator.Error!void {
    try comp.hooks[@backingInt(stage)].append(comp.gpa, hook);
}

/// The arena of pool worker `worker` for hook stage `stage` (B.1: one arena
/// per stage and thread). Arenas live until `deinit`.
pub fn arena(comp: *Compilation, stage: HookStage, worker: u32) *Arena {
    return comp.arenas[@backingInt(stage)].get(worker);
}

/// Runs the pipeline over every added file up to `options.stop_after`.
/// Diagnostics accumulate in `sink`; call `sink.finish()` afterwards. Errors
/// are internal failures only. Call once.
pub fn run(comp: *Compilation) !void {
    try comp.lexAll();
    if (comp.options.stop_after == .lex) return;
    try comp.parseAll();
    if (comp.options.stop_after == .parse) return;
    try comp.runHooks(.resolve);
    try comp.runHooks(.check);
    if (comp.options.stop_after == .check or comp.sink.hasErrors()) return;
    if (comp.options.stop_after == .expand) return comp.runHooks(.expand);
    try comp.runHooks(.lower);
    try comp.runHooks(.codegen);
}

fn runHooks(comp: *Compilation, stage: HookStage) !void {
    for (comp.hooks[@backingInt(stage)].items) |h| try h.run(h.ctx, comp);
}

const lex_options: parallel.Options = .{};

/// Stage 1. Large files are split over line ranges (B.2), one file at a time
/// because `Pool.run` does not nest; the rest are lexed in parallel over files.
fn lexAll(comp: *Compilation) !void {
    for (comp.files.items) |*f| {
        if (f.poisoned or f.ast.source.len < lex_options.min_parallel_len) continue;
        f.ast.tokens = try parallel.tokenize(comp.gpa, &comp.pool, f.ast.source, f.id, &comp.sink, lex_options);
    }
    try comp.forEachFile(struct {
        fn lex(c: *Compilation, f: *File) !void {
            if (f.ast.source.len >= lex_options.min_parallel_len) return;
            f.ast.tokens = try lexer.tokenize(c.gpa, f.ast.source, f.id, &c.sink, lex_options.lex);
        }
    }.lex);
}

/// Stage 2, in parallel over files.
fn parseAll(comp: *Compilation) !void {
    try comp.forEachFile(struct {
        fn parse(c: *Compilation, f: *File) !void {
            const tokens = f.ast.tokens;
            f.ast.tokens = .empty; // `Parser.parse` owns them now, even on failure
            f.ast = try Parser.parse(c.gpa, f.ast.source, tokens, f.id, &c.sink);
        }
    }.parse);
}

/// Calls `func` on every non-poisoned file on the pool.
fn forEachFile(comp: *Compilation, comptime func: fn (*Compilation, *File) Allocator.Error!void) Allocator.Error!void {
    var failed: std.atomic.Value(bool) = .init(false);
    const Job = struct {
        comp: *Compilation,
        failed: *std.atomic.Value(bool),

        fn run(j: @This(), _: u32, i: usize) void {
            const f = &j.comp.files.items[i];
            if (f.poisoned) return;
            func(j.comp, f) catch j.failed.store(true, .monotonic);
        }
    };
    comp.pool.run(comp.files.items.len, Job{ .comp = comp, .failed = &failed }, Job.run);
    if (failed.load(.monotonic)) return error.OutOfMemory;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const render_json = @import("../diag/render_json.zig");

/// Inputs with lexical, syntax and load errors, one of them large enough to
/// take the parallel lexing path.
fn addTestInputs(comp: *Compilation) !void {
    _ = try comp.addSource("a.pr", "fn a() {}\nconst = 1;\nfn b() { # }\n");
    _ = try comp.addSource("b.pr", "type T = ;\nlet $ = 1__0;\n");
    _ = try comp.addSource("bad.pr", "fn \xFF() {}\nconst = 1;\n"); // E0101 only: poisoned
    _ = try comp.addSource("empty.pr", "");
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(testing.allocator);
    var i: usize = 0;
    while (big.items.len < 2 * lex_options.min_parallel_len) : (i += 1)
        try big.appendSlice(testing.allocator, if (i % 50 == 0) "fn f() { ` }\nconst = 2;\n" else "fn g(x: i32) -> i32 { x }\n");
    _ = try comp.addSource("big.pr", big.items);
}

/// Runs the test inputs with `jobs` workers; returns the JSON diagnostics.
fn diagnosticsWithJobs(jobs: u32) ![]u8 {
    var comp: Compilation = undefined;
    try comp.init(testing.allocator, testing.io, .{ .jobs = jobs, .stop_after = .parse });
    defer comp.deinit();
    try addTestInputs(&comp);
    try comp.run();
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try render_json.renderAll(&out.writer, &comp.sources, comp.sink.finish());
    return out.toOwnedSlice();
}

test "multi-file input: identical diagnostics with --jobs 1 and --jobs 8" {
    const one = try diagnosticsWithJobs(1);
    defer testing.allocator.free(one);
    const eight = try diagnosticsWithJobs(8);
    defer testing.allocator.free(eight);
    try testing.expectEqualStrings(one, eight);
    // Lex errors (E0104), parse errors and the load error are all present...
    try testing.expect(std.mem.count(u8, one, "\"E0104\"") >= 4);
    try testing.expect(std.mem.count(u8, one, "\"file\":\"big.pr\"") >= 4);
    try testing.expectEqual(1, std.mem.count(u8, one, "\"E0101\""));
    // ...but the poisoned file reports nothing beyond its load error.
    try testing.expectEqual(1, std.mem.count(u8, one, "\"file\":\"bad.pr\""));
}

test "poisoned input is skipped; others are lexed and parsed" {
    var comp: Compilation = undefined;
    try comp.init(testing.allocator, testing.io, .{ .jobs = 2, .stop_after = .parse });
    defer comp.deinit();
    _ = try comp.addSource("ok.pr", "fn a() {}\n");
    _ = try comp.addSource("bad.pr", "fn a() {}\xFF\nconst = 1;\n");
    try comp.run();
    const ok = comp.files.items[0];
    const bad = comp.files.items[1];
    try testing.expect(!ok.poisoned and bad.poisoned);
    try testing.expect(ok.ast.nodes.len > 1);
    try testing.expectEqual(0, bad.ast.tokens.len);
    try testing.expectEqual(0, bad.ast.nodes.len);
    const ds = comp.sink.finish();
    try testing.expectEqual(1, ds.len);
    try testing.expectEqual(.E0101, ds[0].code.?);
}

test "stray CR is reported but does not hide the file's other errors" {
    var comp: Compilation = undefined;
    try comp.init(testing.allocator, testing.io, .{ .jobs = 2, .stop_after = .parse });
    defer comp.deinit();
    _ = try comp.addSource("cr.pr", "fn a() {}\rfn b() {}\nconst = 1;\n");
    try comp.run();
    const cr = comp.files.items[0];
    try testing.expect(!cr.poisoned);
    try testing.expect(cr.ast.nodes.len > 1);
    const ds = comp.sink.finish();
    try testing.expect(ds.len >= 2);
    try testing.expectEqual(.E0102, ds[0].code.?);
    for (ds[1..]) |d| try testing.expect(d.code != .E0102 and d.severity == .@"error");
}

/// Records which hooks ran, in order.
const Recorder = struct {
    log: [16]u8 = undefined,
    len: usize = 0,

    fn hook(r: *Recorder, comptime tag: u8) Hook {
        return .{ .ctx = r, .run = struct {
            fn run(ctx: ?*anyopaque, _: *Compilation) anyerror!void {
                const self: *Recorder = @ptrCast(@alignCast(ctx.?));
                self.log[self.len] = tag;
                self.len += 1;
            }
        }.run };
    }

    fn ran(r: *const Recorder) []const u8 {
        return r.log[0..r.len];
    }
};

/// Runs `src` to `stop_after` with one hook per stage (two on `check`) and
/// returns the order they ran in: r(esolve), c/C (check), e(xpand), l(ower),
/// g (codegen).
fn hooksRun(stop_after: StopAfter, src: []const u8, rec: *Recorder) !void {
    var comp: Compilation = undefined;
    try comp.init(testing.allocator, testing.io, .{ .jobs = 2, .stop_after = stop_after });
    defer comp.deinit();
    _ = try comp.addSource("m.pr", src);
    try comp.addHook(.codegen, rec.hook('g'));
    try comp.addHook(.lower, rec.hook('l'));
    try comp.addHook(.expand, rec.hook('e'));
    try comp.addHook(.check, rec.hook('c'));
    try comp.addHook(.check, rec.hook('C'));
    try comp.addHook(.resolve, rec.hook('r'));
    try comp.run();
    if (stop_after == .lex) try testing.expectEqual(0, comp.files.items[0].ast.nodes.len);
}

test "stop_after selects the stages that run; stop after parse skips stage-3 hooks" {
    const cases = [_]struct { StopAfter, []const u8, []const u8 }{
        .{ .lex, "fn a() {}", "" },
        .{ .parse, "fn a() {}", "" },
        .{ .check, "fn a() {}", "rcC" },
        .{ .expand, "fn a() {}", "rcCe" },
        .{ .build, "fn a() {}", "rcClg" },
        // Errors: checking still runs, nothing is expanded or generated.
        .{ .expand, "const = 1;", "rcC" },
        .{ .build, "const = 1;", "rcC" },
    };
    for (cases) |c| {
        var rec: Recorder = .{};
        try hooksRun(c[0], c[1], &rec);
        try testing.expectEqualStrings(c[2], rec.ran());
    }
}

test "a warning promoted by @deny stops lower and codegen" {
    const Deny = struct {
        fn levelAt(_: *const anyopaque, _: diag.DiagCode, _: diag.Span) diag.Sink.WarningLevel {
            return .deny;
        }
        fn warn(_: ?*anyopaque, c: *Compilation) anyerror!void {
            try c.sink.emitAt(.W0201, .{ .file = c.files.items[0].id, .start = 0, .end = 2 }, "denied");
        }
    };
    var rec: Recorder = .{};
    var comp: Compilation = undefined;
    try comp.init(testing.allocator, testing.io, .{ .jobs = 2 });
    defer comp.deinit();
    comp.sink.warning_policy = .{ .ctx = undefined, .levelAt = Deny.levelAt };
    _ = try comp.addSource("m.pr", "fn a() {}");
    try comp.addHook(.check, .{ .run = Deny.warn });
    try comp.addHook(.lower, rec.hook('l'));
    try comp.addHook(.codegen, rec.hook('g'));
    try comp.run();
    try testing.expectEqualStrings("", rec.ran());
}

test "lex-only run keeps tokens; hook arenas are per stage and worker" {
    var comp: Compilation = undefined;
    try comp.init(testing.allocator, testing.io, .{ .jobs = 3, .stop_after = .lex });
    defer comp.deinit();
    _ = try comp.addSource("m.pr", "fn a() {}");
    try comp.run();
    try testing.expectEqual(7, comp.files.items[0].ast.tokens.len); // 6 tokens + eof
    try testing.expect(comp.arena(.check, 2) != comp.arena(.check, 1));
    try testing.expect(comp.arena(.check, 0) != comp.arena(.lower, 0));
    _ = try comp.arena(.resolve, 2).allocator().alloc(u8, 10);
}
