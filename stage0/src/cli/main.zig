//! The `pyro` command line (§13.8): parses arguments (`args.zig`), dispatches
//! to a command, and maps the outcome to the exit status:
//!
//! | status | meaning                                            |
//! |--------|----------------------------------------------------|
//! | 0      | success                                            |
//! | 1      | compile errors (or test failures)                  |
//! | 2      | invalid usage                                      |
//! | 3      | internal compiler error (any internal failure, a panic, or a command stage 0 does not implement yet) |
//!
//! Stage 0 implements only `check`, and only on files named on the command
//! line: `pyro check [flags] file.pr...` is a stage-0 convenience that checks
//! the given files as one compilation without a package manifest. `pyro check`
//! with no file (package mode) and every other command report "not implemented".
//!
//! Diagnostics go to stderr in the human format (A.2), or to stdout as one JSON
//! object per line with `--message-format json` (`tools/conformance/README.md`).
//! The debug dumps `--dump-tokens` and `--dump-ast` write to stdout after the
//! diagnostics.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
const args_mod = @import("args.zig");
const Options = args_mod.Options;
const Command = args_mod.Command;
const Compilation = @import("../driver/Compilation.zig");
const render_json = @import("../diag/render_json.zig");
const render_human = @import("../diag/render_human.zig");
const ast_dump = @import("../ast/dump.zig");

/// Exit statuses (§13.8).
pub const Exit = enum(u8) { ok = 0, failed = 1, usage = 2, internal = 3 };

/// Dispatch table: the function that runs each command. Later tasks replace a
/// `notImplemented` entry with their `cmd_*.zig` function.
const commands = std.enums.EnumArray(Command, *const fn (*Ctx) anyerror!Exit).init(.{
    .new = notImplemented,
    .init = notImplemented,
    .build = notImplemented,
    .run = notImplemented,
    .check = check,
    .@"test" = notImplemented,
    .bench = notImplemented,
    .fmt = notImplemented,
    .doc = notImplemented,
    .lsp = notImplemented,
    .profile = notImplemented,
    .add = notImplemented,
    .remove = notImplemented,
    .update = notImplemented,
    .fetch = notImplemented,
    .publish = notImplemented,
    .clean = notImplemented,
});

pub const usage_text =
    \\usage: pyro <command> [options]
    \\
    \\commands:
    \\  new <name> [--lib], init   create a package
    \\  build                      compile (default env dev)
    \\  run [-- args]              build and run the executable
    \\  check [file.pr...]         parse, resolve and type-check only
    \\  test [pattern] [--seed n]  run tests and laws
    \\  bench [pattern]            run benchmarks
    \\  fmt [--check]              format source
    \\  doc [--open]               generate HTML docs
    \\  lsp                        language server over stdio
    \\  profile [-- args]          run with the sampling profiler
    \\  add <dep> [--dev], remove  edit [dependencies]
    \\  update [dep], fetch        re-resolve or download dependencies
    \\  publish                    upload to a registry
    \\  clean                      delete build outputs
    \\
    \\options:
    \\  --env <name>  --release  --target <triple>  --backend llvm|native
    \\  --set key=value  --jobs n  --offline  --locked  --expand[=full]
    \\  --trust-build-scripts  --color auto|always|never
    \\  --message-format human|json
    \\
    \\debug: --dump-tokens  --dump-ast  --stop-after lex|parse
    \\
    \\stage 0: only `pyro check file.pr...` is implemented.
    \\
;

/// Where a command writes. `stderr_file` (null in tests) is used only to detect
/// whether `--color auto` should color.
pub const Streams = struct {
    stdout: *Writer,
    stderr: *Writer,
    stderr_file: ?Io.File = null,
};

/// State a command runs with.
const Ctx = struct {
    gpa: Allocator,
    io: Io,
    opts: Options,
    out: Streams,
};

/// The process entry point; `stage0/src/main.zig` delegates here.
pub fn main(init: std.process.Init) u8 {
    const argv = init.minimal.args.toSlice(init.arena.allocator()) catch return internalError("out of memory");
    var out_buf: [4096]u8 = undefined;
    var err_buf: [1024]u8 = undefined;
    var stdout = Io.File.stdout().writer(init.io, &out_buf);
    var stderr = Io.File.stderr().writer(init.io, &err_buf);
    const streams: Streams = .{ .stdout = &stdout.interface, .stderr = &stderr.interface, .stderr_file = .stderr() };
    const status = run(init.gpa, init.io, if (argv.len > 0) argv[1..] else &.{}, streams) catch |err| {
        stdout.interface.flush() catch {};
        stderr.interface.flush() catch {};
        return internalError(@errorName(err));
    };
    stdout.interface.flush() catch {};
    stderr.interface.flush() catch {};
    return @backingInt(status);
}

/// Panic handler for the `pyro` executable (installed as `panic` in the root
/// file): reports an internal compiler error and exits with status 3.
pub const panic = std.debug.FullPanic(panicExit);

fn panicExit(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    std.debug.print("error: internal compiler error: {s}\n", .{msg});
    std.debug.dumpCurrentStackTrace(.{ .first_address = first_trace_addr orelse @returnAddress() });
    std.process.exit(@backingInt(Exit.internal));
}

fn internalError(what: []const u8) u8 {
    std.debug.print("error: internal compiler error: {s}\n", .{what});
    return @backingInt(Exit.internal);
}

/// Runs the command line `args` (without the program name). Returns an error
/// only for internal failures, which the caller reports as status 3.
pub fn run(gpa: Allocator, io: Io, args: []const []const u8, out: Streams) !Exit {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (args.len == 1 and (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h"))) {
        try out.stdout.writeAll(usage_text);
        return .ok;
    }
    var msg: []const u8 = "";
    const opts = args_mod.parse(arena, args, &msg) catch |err| switch (err) {
        error.Usage => {
            if (args.len == 0) {
                try out.stderr.writeAll(usage_text);
            } else {
                try out.stderr.print("error: {s}\n(run `pyro --help` for usage)\n", .{msg});
            }
            return .usage;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (opts.debug_ice) @panic("forced by --debug-ice");
    var ctx: Ctx = .{ .gpa = gpa, .io = io, .opts = opts, .out = out };
    return commands.get(opts.command)(&ctx);
}

fn notImplemented(ctx: *Ctx) !Exit {
    try ctx.out.stderr.print("error: `pyro {t}` is not implemented yet (stage 0)\n", .{ctx.opts.command});
    return .internal;
}

/// `pyro check file.pr...`: the front end on the named files, up to
/// `--stop-after` (default: the whole check).
fn check(ctx: *Ctx) !Exit {
    const o = ctx.opts;
    if (o.positionals.len == 0) {
        try ctx.out.stderr.writeAll("error: `pyro check` without files (package mode) is not implemented yet (stage 0)\n");
        return .internal;
    }
    if (o.dump_ast and o.stop_after == .lex) {
        try ctx.out.stderr.writeAll("error: `--dump-ast` needs parsing, but `--stop-after lex` stops before it\n");
        return .usage;
    }
    var comp: Compilation = undefined;
    try comp.init(ctx.gpa, ctx.io, .{
        .jobs = o.jobs,
        .stop_after = if (o.stop_after) |s| switch (s) {
            .lex => .lex,
            .parse => .parse,
        } else .check,
    });
    defer comp.deinit();
    for (o.positionals) |path| _ = comp.addFile(.cwd(), path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try ctx.out.stderr.print("error: cannot read `{s}`: {t}\n", .{ path, err });
            return .usage;
        },
    };
    try comp.run();

    const ds = comp.sink.finish();
    switch (o.message_format) {
        .json => try render_json.renderAll(ctx.out.stdout, &comp.sources, ds),
        .human => {
            const mode: Io.Terminal.Mode = if (ctx.out.stderr_file) |f|
                try render_human.colorMode(ctx.io, f, o.color)
            else if (o.color == .always) .escape_codes else .no_color;
            try render_human.renderAll(.{ .writer = ctx.out.stderr, .mode = mode }, &comp.sources, ds);
        },
    }
    for (comp.files.items) |*f| {
        if (f.poisoned) continue;
        if (o.dump_tokens) try dumpTokens(ctx.out.stdout, &comp, f);
        if (o.dump_ast and f.ast.nodes.len > 0) try ast_dump.dump(&f.ast, ctx.out.stdout);
    }
    for (ds) |d| if (d.severity == .@"error") return .failed;
    // A full check that ran no resolve or check stage has not shown the program
    // valid, so it must not report success.
    if (o.stop_after == null and !hasSemanticStages(&comp)) {
        try ctx.out.stderr.writeAll("error: name resolution and type checking are not implemented yet (stage 0); use `--stop-after lex|parse`\n");
        return .internal;
    }
    return .ok;
}

/// Whether any stage-3 or stage-4 hook (B.1) is registered.
fn hasSemanticStages(comp: *const Compilation) bool {
    for ([_]Compilation.HookStage{ .resolve, .check }) |s| {
        if (comp.hooks[@backingInt(s)].items.len > 0) return true;
    }
    return false;
}

/// `--dump-tokens`: one line per token, `line:column kind "text"`.
fn dumpTokens(w: *Writer, comp: *Compilation, f: *const Compilation.File) !void {
    const toks = f.ast.tokens.slice();
    for (toks.items(.kind), toks.items(.start), toks.items(.len)) |k, start, len| {
        const loc = comp.sources.location(f.id, start);
        try w.print("{d}:{d} {t} \"{f}\"\n", .{ loc.line, loc.column, k, std.zig.fmtString(f.ast.source[start..][0..len]) });
    }
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

/// Runs `pyro args...` with captured output.
const Captured = struct {
    exit: Exit,
    stdout: Writer.Allocating,
    stderr: Writer.Allocating,

    fn init(args: []const []const u8) !Captured {
        var c: Captured = .{ .exit = undefined, .stdout = .init(testing.allocator), .stderr = .init(testing.allocator) };
        errdefer c.deinit();
        c.exit = try run(testing.allocator, testing.io, args, .{ .stdout = &c.stdout.writer, .stderr = &c.stderr.writer });
        return c;
    }

    fn deinit(c: *Captured) void {
        c.stdout.deinit();
        c.stderr.deinit();
    }
};

/// A scratch directory holding `name` with `contents`; returns its path
/// relative to the cwd (allocated in `arena`).
fn writeCase(arena: Allocator, tmp: *testing.TmpDir, name: []const u8, contents: []const u8) ![]const u8 {
    try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = contents });
    return std.fs.path.join(arena, &.{ ".zig-cache", "tmp", &tmp.sub_path, name });
}

test "no arguments: usage on stderr, exit 2" {
    var c: Captured = try .init(&.{});
    defer c.deinit();
    try testing.expectEqual(Exit.usage, c.exit);
    try testing.expect(std.mem.startsWith(u8, c.stderr.written(), "usage: pyro"));
}

test "unknown flag and unknown command exit 2" {
    var c: Captured = try .init(&.{ "check", "--no-such-flag", "a.pr" });
    defer c.deinit();
    try testing.expectEqual(Exit.usage, c.exit);
    try testing.expectEqualStrings("error: unknown flag `--no-such-flag`\n(run `pyro --help` for usage)\n", c.stderr.written());
    var d: Captured = try .init(&.{"frobnicate"});
    defer d.deinit();
    try testing.expectEqual(Exit.usage, d.exit);
}

test "every command dispatches; stubs report not implemented" {
    for (std.enums.values(Command)) |cmd| {
        if (cmd == .check) continue;
        var c: Captured = try .init(&.{@tagName(cmd)});
        defer c.deinit();
        try testing.expectEqual(Exit.internal, c.exit);
        try testing.expect(std.mem.indexOf(u8, c.stderr.written(), "not implemented") != null);
    }
}

test "check: clean file exits 0 with no output" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeCase(arena.allocator(), &tmp, "ok.pr", "fn main() {}\n");
    var c: Captured = try .init(&.{ "check", "--message-format", "json", "--stop-after", "parse", path });
    defer c.deinit();
    try testing.expectEqual(Exit.ok, c.exit);
    try testing.expectEqualStrings("", c.stdout.written());
    try testing.expectEqualStrings("", c.stderr.written());
    // Without a semantic stage, a full check cannot claim success.
    var full: Captured = try .init(&.{ "check", "--message-format", "json", path });
    defer full.deinit();
    try testing.expectEqual(Exit.internal, full.exit);
    try testing.expectEqualStrings("", full.stdout.written());
}

test "check: an error exits 1 with one JSON diagnostic per line" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // shortcut: E0104 (lexer) stands in for the E0214 of T024's acceptance
    // until the Pratt parser (T023) reports E0214; conformance covers that case.
    const path = try writeCase(arena.allocator(), &tmp, "bad.pr", "fn main() {}\nconst x = 1 ` 2;\n");
    var c: Captured = try .init(&.{ "check", "--message-format=json", "--stop-after", "lex", path });
    defer c.deinit();
    try testing.expectEqual(Exit.failed, c.exit);
    const line = std.mem.trimEnd(u8, c.stdout.written(), "\n");
    try testing.expect(std.mem.indexOfScalar(u8, line, '\n') == null);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("E0104", obj.get("code").?.string);
    try testing.expectEqualStrings("error", obj.get("severity").?.string);
    const span = obj.get("spans").?.array.items[0].object;
    try testing.expectEqual(2, span.get("line").?.integer);
    try testing.expectEqualStrings(path, span.get("file").?.string);
}

test "check: human format goes to stderr" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeCase(arena.allocator(), &tmp, "bad.pr", "fn a() { ` }\n");
    var c: Captured = try .init(&.{ "check", path });
    defer c.deinit();
    try testing.expectEqual(Exit.failed, c.exit);
    try testing.expectEqualStrings("", c.stdout.written());
    try testing.expect(std.mem.startsWith(u8, c.stderr.written(), "error[E0104]: "));
}

test "check: --dump-tokens and --dump-ast" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeCase(arena.allocator(), &tmp, "t.pr", "fn a() {}\n");
    var c: Captured = try .init(&.{ "check", "--stop-after", "parse", "--dump-tokens", "--dump-ast", path });
    defer c.deinit();
    try testing.expectEqual(Exit.ok, c.exit);
    const out = c.stdout.written();
    try testing.expect(std.mem.startsWith(u8, out, "1:1 kw_fn \"fn\"\n1:4 ident \"a\"\n"));
    try testing.expect(std.mem.indexOf(u8, out, "(root") != null);
    var d: Captured = try .init(&.{ "check", "--stop-after", "lex", "--dump-ast", path });
    defer d.deinit();
    try testing.expectEqual(Exit.usage, d.exit);
}

test "check: missing file or no file" {
    var c: Captured = try .init(&.{ "check", "does/not/exist.pr" });
    defer c.deinit();
    try testing.expectEqual(Exit.usage, c.exit);
    var d: Captured = try .init(&.{"check"});
    defer d.deinit();
    try testing.expectEqual(Exit.internal, d.exit);
}
