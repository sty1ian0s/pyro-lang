//! Conformance harness (B.9), run by `zig build conformance`:
//!
//!     pyro-conformance <pyro> <conformance-dir> [--examples <dir>] [--registry <A-diagnostics.md>]
//!                      [--coverage-out <file>] [--require-coverage] [filter...]
//!
//! Walks `<conformance-dir>/**/*.pr`, runs each case through its runner mode, then
//! the `examples/<name>/` packages, then prints the A.3 coverage report. A case or
//! example runs only if its path contains one of the filters (if any). Exits 1 if
//! anything failed. The case format is documented in README.md.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Writer = Io.Writer;
const case_mod = @import("case.zig");
const Case = case_mod.Case;
const exec = @import("exec.zig");
const Coverage = @import("coverage.zig").Coverage;
const parseRegistry = @import("coverage.zig").parseRegistry;

/// Runner modes, selected per directory with `mode: <name>` in `dir.conf`.
/// A task adding a mode adds its file and one line here.
pub const modes = std.StaticStringMap(exec.RunFn).initComptime(.{
    .{ "default", &exec.runDefault },
});

pub const Options = struct {
    pyro: []const u8,
    conformance: []const u8,
    examples: ?[]const u8 = null,
    /// `spec/A-diagnostics.md`; without it no coverage report is printed.
    registry: ?[]const u8 = null,
    coverage_out: ?[]const u8 = null,
    /// Fail if any A.3 code lacks a passing or failing case.
    require_coverage: bool = false,
    filters: []const []const u8 = &.{},
};

pub const Summary = struct {
    pass: u32 = 0,
    fail: u32 = 0,
    xfail: u32 = 0,
    xpass: u32 = 0,
    skip: u32 = 0,
    coverage_ok: bool = true,

    pub fn ok(s: Summary) bool {
        return s.fail == 0 and s.xpass == 0 and s.coverage_ok;
    }
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const opts = parseArgs(arena, args[1..]) catch |err| {
        std.debug.print("pyro-conformance: {t}\nusage: pyro-conformance <pyro> <conformance-dir> [--examples <dir>] [--registry <md>] [--coverage-out <file>] [--require-coverage] [filter...]\n", .{err});
        return 2;
    };
    var buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(init.io, &buf);
    const summary = try run(init.gpa, init.io, opts, &stdout.interface);
    try stdout.interface.flush();
    return if (summary.ok()) 0 else 1;
}

fn parseArgs(arena: Allocator, args: []const []const u8) !Options {
    var positional: std.ArrayList([]const u8) = .empty;
    var opts: Options = .{ .pyro = "", .conformance = "" };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--require-coverage")) {
            opts.require_coverage = true;
            continue;
        }
        const field: *?[]const u8 = if (std.mem.eql(u8, a, "--examples"))
            &opts.examples
        else if (std.mem.eql(u8, a, "--registry"))
            &opts.registry
        else if (std.mem.eql(u8, a, "--coverage-out"))
            &opts.coverage_out
        else if (std.mem.startsWith(u8, a, "--"))
            return error.UnknownOption
        else {
            try positional.append(arena, a);
            continue;
        };
        i += 1;
        if (i == args.len) return error.MissingOptionValue;
        field.* = args[i];
    }
    if (positional.items.len < 2) return error.MissingArguments;
    opts.pyro = positional.items[0];
    opts.conformance = positional.items[1];
    opts.filters = positional.items[2..];
    return opts;
}

/// Runs the whole suite, printing one line per case to `w`.
pub fn run(gpa: Allocator, io: Io, opts: Options, w: *Writer) !Summary {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var case_arena: std.heap.ArenaAllocator = .init(gpa);
    defer case_arena.deinit();
    // Examples run with their package as cwd, so a relative compiler path must be made absolute.
    // A bare name (no separator) is left for PATH lookup.
    const pyro = if (std.mem.indexOfAny(u8, opts.pyro, std.fs.path.sep_str ++ "/") != null)
        try Io.Dir.cwd().realPathFileAlloc(io, opts.pyro, arena)
    else
        opts.pyro;
    const ctx: exec.Ctx = .{ .arena = case_arena.allocator(), .io = io, .pyro = pyro };

    const coverage: ?Coverage = if (opts.registry) |path|
        try .init(arena, try parseRegistry(arena, try Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited)))
    else
        null;

    var summary: Summary = .{};
    for (try listFiles(arena, io, opts.conformance, .file, ".pr")) |rel| {
        if (!selected(opts.filters, rel)) continue;
        defer _ = case_arena.reset(.retain_capacity);
        var err_msg: []const u8 = "";
        const verdict: exec.Verdict, const case: ?Case = blk: {
            const case = loadCase(ctx, opts.conformance, rel, &err_msg) catch |err| switch (err) {
                error.BadCase => break :blk .{ .{ .fail = err_msg }, null },
                else => return err,
            };
            const mode = modes.get(case.mode) orelse
                break :blk .{ .{ .fail = try std.fmt.allocPrint(ctx.arena, "unknown mode `{s}`\n", .{case.mode}) }, case };
            break :blk .{ mode(ctx, &case) catch |err| .{ .fail = @errorName(err) }, case };
        };
        const xfail = if (case) |c| c.ann.expected_fail else null;
        try report(w, &summary, rel, verdict, xfail);
        if (coverage) |cov| if (case) |c| if (xfail == null) {
            for (c.ann.expected) |e| cov.add(cov.fail, e.code);
            for (c.ann.covers) |code| cov.add(cov.pass, code);
        };
    }

    if (opts.examples) |dir| for (try listFiles(arena, io, dir, .directory, "")) |name| {
        const display = try std.fmt.allocPrint(arena, "examples/{s}", .{name});
        if (!selected(opts.filters, display)) continue;
        defer _ = case_arena.reset(.retain_capacity);
        const path = try std.fs.path.join(ctx.arena, &.{ dir, name });
        const verdict: exec.Verdict = if (!try exec.exists(ctx, try std.fs.path.join(ctx.arena, &.{ path, "expected.out" })))
            .{ .skip = "no expected.out" }
        else
            exec.runExample(ctx, path) catch |err| .{ .fail = @errorName(err) };
        try report(w, &summary, display, verdict, null);
    };

    try w.print("conformance: {d} passed, {d} failed, {d} xfail, {d} xpass, {d} skipped\n", .{ summary.pass, summary.fail, summary.xfail, summary.xpass, summary.skip });
    if (coverage) |cov| {
        try cov.writeLacking(w);
        if (opts.coverage_out) |path| {
            var md: Writer.Allocating = .init(arena);
            try cov.writeMarkdown(&md.writer);
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = md.written() });
        }
        summary.coverage_ok = !opts.require_coverage or cov.lacking() == 0;
    }
    return summary;
}

fn selected(filters: []const []const u8, path: []const u8) bool {
    if (filters.len == 0) return true;
    for (filters) |f| if (std.mem.indexOf(u8, path, f) != null) return true;
    return false;
}

/// Prints one outcome line, applying `//@ expected-fail`.
fn report(w: *Writer, s: *Summary, rel: []const u8, verdict: exec.Verdict, xfail: ?[]const u8) !void {
    switch (verdict) {
        .pass => if (xfail) |why| {
            s.xpass += 1;
            try w.print("XPASS {s} (marked expected-fail: {s})\n", .{ rel, why });
        } else {
            s.pass += 1;
            try w.print("PASS  {s}\n", .{rel});
        },
        .fail => |msg| if (xfail) |why| {
            s.xfail += 1;
            try w.print("XFAIL {s} ({s})\n", .{ rel, why });
        } else {
            s.fail += 1;
            try w.print("FAIL  {s}\n", .{rel});
            var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, msg, "\n"), '\n');
            while (lines.next()) |line| try w.print("      {s}\n", .{line});
        },
        .skip => |why| {
            s.skip += 1;
            try w.print("SKIP  {s} ({s})\n", .{ rel, why });
        },
    }
}

/// Reads and resolves one case: annotations, `dir.conf` settings and phase.
fn loadCase(ctx: exec.Ctx, root: []const u8, rel: []const u8, err_msg: *[]const u8) !Case {
    const path = try std.fs.path.join(ctx.arena, &.{ root, rel });
    const base = path[0 .. path.len - ".pr".len];
    const source = try Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .unlimited);
    const ann = try case_mod.parse(ctx.arena, source, err_msg);

    var conf: case_mod.DirConf = .{};
    var dir: ?[]const u8 = std.fs.path.dirname(rel);
    while (true) : (dir = std.fs.path.dirname(dir.?)) {
        const conf_path = try std.fs.path.join(ctx.arena, &.{ root, dir orelse "", "dir.conf" });
        if (Io.Dir.cwd().readFileAlloc(ctx.io, conf_path, ctx.arena, .unlimited)) |text| {
            try case_mod.applyDirConf(ctx.arena, &conf, text, err_msg);
        } else |err| if (err != error.FileNotFound) return err;
        if (dir == null) break;
    }

    const has_out = try exec.exists(ctx, try std.fmt.allocPrint(ctx.arena, "{s}.out", .{base}));
    const stop_after = ann.stop_after orelse conf.stop_after orelse if (has_out) case_mod.Phase.run else .check;
    if (has_out != (stop_after == .run))
        return badCase(ctx, err_msg, "stop-after is `{t}` but {s}.out {s}", .{ stop_after, std.fs.path.basename(base), if (has_out) "exists" else "is missing" });
    if (stop_after == .run) for (ann.expected) |e| if (e.code[0] == 'E')
        return badCase(ctx, err_msg, "a run-pass case cannot expect error {s}", .{e.code});
    if (ann.debug_assertions and stop_after != .run)
        return badCase(ctx, err_msg, "`//@ debug_assertions` only applies to run-pass cases", .{});
    return .{ .path = path, .base = base, .rel = rel, .ann = ann, .stop_after = stop_after, .mode = conf.mode orelse "default" };
}

fn badCase(ctx: exec.Ctx, err_msg: *[]const u8, comptime fmt: []const u8, args: anytype) error{ BadCase, OutOfMemory } {
    err_msg.* = try std.fmt.allocPrint(ctx.arena, fmt, args);
    return error.BadCase;
}

/// Sorted paths (relative to `root`, with `/`) of entries of `kind`: every file
/// ending in `ext` at any depth, or the immediate subdirectories.
fn listFiles(arena: Allocator, io: Io, root: []const u8, kind: Io.File.Kind, ext: []const u8) ![]const []const u8 {
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.kind != kind or !std.mem.endsWith(u8, entry.path, ext)) continue;
        if (kind == .directory and entry.depth() != 1) continue;
        const rel = try arena.dupe(u8, entry.path);
        std.mem.replaceScalar(u8, rel, std.fs.path.sep, '/');
        try out.append(arena, rel);
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return out.items;
}
