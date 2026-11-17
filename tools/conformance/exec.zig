//! Runs `pyro` for a case: the `default` runner mode (diagnostic match, then
//! run-pass in every environment) and the `examples/<name>/` runner.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Writer = Io.Writer;
const case_mod = @import("case.zig");
const Case = case_mod.Case;
const Expected = case_mod.Expected;
const diagnostic = @import("diagnostic.zig");

/// Environments every run-pass case and example runs in (§13.3).
pub const envs = [_][]const u8{ "dev", "test", "prod" };

/// What a runner mode concluded about one case.
pub const Verdict = union(enum) {
    pass,
    /// Multi-line explanation, printed indented under the FAIL line.
    fail: []const u8,
    /// Not run here (e.g. missing GPU backend); the reason is printed.
    skip: []const u8,
};

/// Shared state for runners. `arena` is reset after every case.
pub const Ctx = struct {
    arena: Allocator,
    io: Io,
    /// Path of the `pyro` executable under test.
    pyro: []const u8,
};

/// Signature of a runner mode (see `modes` in main.zig). An error becomes a FAIL.
pub const RunFn = *const fn (ctx: Ctx, case: *const Case) anyerror!Verdict;

/// Result of one `pyro` invocation.
pub const Output = struct {
    term: std.process.Child.Term,
    stdout: []const u8,
    stderr: []const u8,

    fn sameAs(a: Output, b: Output) bool {
        return std.meta.eql(a.term, b.term) and
            std.mem.eql(u8, a.stdout, b.stdout) and std.mem.eql(u8, a.stderr, b.stderr);
    }
};

/// Runs `pyro args...` in `cwd` (null: inherit) and collects its output. A child
/// that prints nothing for 60 s is killed and reported as `error.Timeout`.
pub fn pyro(ctx: Ctx, args: []const []const u8, cwd: ?[]const u8) !Output {
    const argv = try std.mem.concat(ctx.arena, []const u8, &.{ &.{ctx.pyro}, args });
    const r = try std.process.run(ctx.arena, ctx.io, .{
        .argv = argv,
        .cwd = if (cwd) |p| .{ .path = p } else .inherit,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(60), .clock = .awake } },
    });
    return .{ .term = r.term, .stdout = r.stdout, .stderr = r.stderr };
}

/// The `default` runner mode.
pub fn runDefault(ctx: Ctx, case: *const Case) anyerror!Verdict {
    var msg: Writer.Allocating = .init(ctx.arena);
    const w = &msg.writer;
    try checkDiagnostics(ctx, case, w);
    if (msg.written().len == 0 and case.stop_after == .run)
        try runEnvs(ctx, w, &.{case.path}, null, case.base, case.ann.debug_assertions);
    return if (msg.written().len == 0) .pass else .{ .fail = msg.written() };
}

/// Runs `pyro check --message-format json [--stop-after lex|parse] <case>` and
/// writes every difference between expected and reported (code, line) pairs.
fn checkDiagnostics(ctx: Ctx, case: *const Case, w: *Writer) !void {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(ctx.arena, &.{ "check", "--message-format", "json" });
    if (case.stop_after == .lex or case.stop_after == .parse)
        try args.appendSlice(ctx.arena, &.{ "--stop-after", @tagName(case.stop_after) });
    try args.append(ctx.arena, case.path);
    const out = try pyro(ctx, args.items, null);

    const exit: ?u8 = if (out.term == .exited) out.term.exited else null;
    if (exit != 0 and exit != 1)
        return w.print("pyro check: {f}\n{s}", .{ out.term, out.stderr });

    var bad_line: usize = 0;
    const diags = diagnostic.parseLines(ctx.arena, out.stdout, &bad_line) catch |err|
        return w.print("pyro check: stdout line {d} is not a valid JSON diagnostic ({t})\n", .{ bad_line, err });

    var actual: std.ArrayList(Expected) = .empty;
    var has_error = false;
    for (diags) |d| {
        has_error = has_error or d.severity == .@"error";
        const span = d.primary() orelse {
            try w.print("{s} has no primary span\n", .{d.code});
            continue;
        };
        try actual.append(ctx.arena, .{ .code = d.code, .line = span.line });
    }
    if (exit.? != @intFromBool(has_error))
        try w.print("pyro check exited {d}, but {s} reported\n", .{ exit.?, if (has_error) "errors were" else "no error was" });

    std.mem.sort(Expected, actual.items, {}, Expected.lessThan);
    const want = case.ann.expected;
    const got = actual.items;
    var i: usize = 0;
    var j: usize = 0;
    while (i < want.len or j < got.len) {
        const order: std.math.Order = if (i == want.len) .gt else if (j == got.len) .lt else if (Expected.lessThan({}, want[i], got[j])) .lt else if (Expected.lessThan({}, got[j], want[i])) .gt else .eq;
        switch (order) {
            .eq => {
                i += 1;
                j += 1;
            },
            .lt => {
                try w.print("missing {s} at line {d}\n", .{ want[i].code, want[i].line });
                i += 1;
            },
            .gt => {
                try w.print("unexpected {s} at line {d}\n", .{ got[j].code, got[j].line });
                j += 1;
            },
        }
    }
}

/// Runs `pyro run --env <env> <file_args>` (or `pyro test` first for an
/// example) in every environment and compares with `<base>.out`, `.err`, `.exit`.
/// Without `debug_assertions` all environments must agree; with it, `prod`
/// compares against `<base>.prod.*` instead.
fn runEnvs(ctx: Ctx, w: *Writer, file_args: []const []const u8, cwd: ?[]const u8, base: []const u8, debug_assertions: bool) !void {
    const prod_base = try std.fmt.allocPrint(ctx.arena, "{s}.prod", .{base});
    const has_prod = try exists(ctx, try std.fmt.allocPrint(ctx.arena, "{s}.out", .{prod_base}));
    if (has_prod and !debug_assertions)
        return w.print("{s}.prod.out exists, but the case is not marked `//@ debug_assertions`\n", .{std.fs.path.basename(base)});
    if (debug_assertions and !has_prod)
        return w.print("`//@ debug_assertions` needs {s}.prod.out\n", .{std.fs.path.basename(base)});

    var outs: [envs.len]Output = undefined;
    for (envs, &outs) |env, *out| {
        const args = try std.mem.concat(ctx.arena, []const u8, &.{ &.{ "run", "--env", env }, file_args });
        out.* = try pyro(ctx, args, cwd);
    }
    for (envs, outs) |env, out| {
        // debug_assertions is false only in prod (§13.3)
        const unchecked = debug_assertions and std.mem.eql(u8, env, "prod");
        if (!debug_assertions and !out.sameAs(outs[0]))
            try w.print("env mismatch: {s} output differs from dev\n", .{env});
        try compare(ctx, w, env, if (unchecked) prod_base else base, out);
    }
}

/// Writes how `out` differs from the expectation files at `base`.
fn compare(ctx: Ctx, w: *Writer, env: []const u8, base: []const u8, out: Output) !void {
    const name = std.fs.path.basename(base);
    const want_out = try read(ctx, base, ".out") orelse return w.print("[{s}] {s}.out is missing\n", .{ env, name });
    const want_err = try read(ctx, base, ".err");
    const want_exit: u8 = if (try read(ctx, base, ".exit")) |s|
        std.fmt.parseInt(u8, std.mem.trim(u8, s, " \t\r\n"), 10) catch return w.print("{s}.exit is not an exit code\n", .{name})
    else
        0;

    if (out.term != .exited or out.term.exited != want_exit)
        try w.print("[{s}] expected exit code {d}, got: {f}\n", .{ env, want_exit, out.term });
    try diffText(w, env, "stdout", want_out, out.stdout);
    if (want_err) |e| try diffText(w, env, "stderr", e, out.stderr);
}

/// Reports the first differing line of two texts.
fn diffText(w: *Writer, env: []const u8, stream: []const u8, want: []const u8, got: []const u8) !void {
    if (std.mem.eql(u8, want, got)) return;
    var a = std.mem.splitScalar(u8, want, '\n');
    var b = std.mem.splitScalar(u8, got, '\n');
    var line: usize = 1;
    while (true) : (line += 1) {
        const x = a.next();
        const y = b.next();
        if (x != null and y != null and std.mem.eql(u8, x.?, y.?)) continue;
        return w.print("[{s}] {s} differs at line {d}\n  expected: {s}\n  actual:   {s}\n", .{
            env, stream, line, x orelse "<end of output>", y orelse "<end of output>",
        });
    }
}

/// Runs the example package in `dir`: `pyro test` must succeed, then `pyro run`
/// in every environment must match `expected.out` (and `.err`, `.exit` if present).
pub fn runExample(ctx: Ctx, dir: []const u8) !Verdict {
    var msg: Writer.Allocating = .init(ctx.arena);
    const w = &msg.writer;
    const t = try pyro(ctx, &.{"test"}, dir);
    if (t.term != .exited or t.term.exited != 0) try w.print("pyro test: {f}\n{s}{s}", .{ t.term, t.stdout, t.stderr });
    try runEnvs(ctx, w, &.{}, dir, try std.fs.path.join(ctx.arena, &.{ dir, "expected" }), false);
    return if (msg.written().len == 0) .pass else .{ .fail = msg.written() };
}

fn read(ctx: Ctx, base: []const u8, ext: []const u8) !?[]u8 {
    const path = try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ base, ext });
    return Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

/// Returns whether `path` exists.
pub fn exists(ctx: Ctx, path: []const u8) !bool {
    Io.Dir.cwd().access(ctx.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}
