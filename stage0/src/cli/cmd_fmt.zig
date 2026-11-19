//! `pyro fmt [--check] [path...]` (§13.8): formats source files in the single
//! canonical style (`fmt/fmt.zig`, `docs/style.md`).
//!
//! Each path is a `.pr` file or a directory searched recursively for `.pr`
//! files. Without paths, the `src/` and `tests/` trees of the package around
//! the current directory are formatted. Every file whose text changes is
//! named on stdout; it is rewritten in place (atomically), or with `--check`
//! left alone and the command exits 1. A file that does not lex or parse is
//! not formatted: its diagnostics are reported and the command exits 1.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const cli = @import("main.zig");
const fmt = @import("../fmt/fmt.zig");
const diag = @import("../diag/diag.zig");
const SourceMap = @import("../source/SourceMap.zig");
const layout = @import("../pkg/layout.zig");

pub fn run(ctx: *cli.Ctx) !cli.Exit {
    var arena_state: std.heap.ArenaAllocator = .init(ctx.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var files: std.ArrayList([]const u8) = .empty;
    if (ctx.opts.positionals.len == 0) {
        const root = try layout.findRoot(a, ctx.io, ".") orelse {
            try ctx.out.stderr.writeAll("error: could not find `pyro.toml` in `.` or any parent directory; name the files to format\n");
            return .failed;
        };
        for ([_][]const u8{ "src", "tests" }) |sub| try collect(a, ctx.io, try std.fs.path.join(a, &.{ root, sub }), false, &files);
    } else for (ctx.opts.positionals) |p| try collect(a, ctx.io, p, true, &files);

    var sm: SourceMap = .init(ctx.gpa, ctx.io);
    defer sm.deinit();
    var exit: cli.Exit = .ok;
    for (files.items) |path| {
        var sink: diag.Sink = .init(ctx.gpa, ctx.io);
        defer sink.deinit();
        const id = sm.load(.cwd(), path, &sink) catch |err| {
            try ctx.out.stderr.print("error: cannot read `{s}`: {t}\n", .{ path, err });
            return .usage;
        };
        const file = sm.get(id);
        const formatted = (if (sink.hasErrors()) null else fmt.formatSource(ctx.gpa, ctx.io, file.text, id, &sink)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TokensChanged => {
                try ctx.out.stderr.print("error: internal compiler error: formatting `{s}` would change its tokens\n", .{path});
                return .internal;
            },
        } orelse {
            try cli.renderDiagnostics(ctx, &sm, sink.finish());
            exit = .failed;
            continue;
        };
        defer ctx.gpa.free(formatted);
        if (std.mem.eql(u8, formatted, file.raw)) continue;
        try ctx.out.stdout.print("{s}\n", .{path});
        if (ctx.opts.check) {
            exit = .failed;
            continue;
        }
        var af = try Io.Dir.cwd().createFileAtomic(ctx.io, path, .{ .replace = true });
        defer af.deinit(ctx.io);
        try af.file.writeStreamingAll(ctx.io, formatted);
        try af.replace(ctx.io);
    }
    return exit;
}

/// Appends `path` if it is a file, or the `.pr` files under it (sorted) if it
/// is a directory. A missing path is appended only if `explicit`, so that
/// loading it reports the error.
fn collect(a: Allocator, io: Io, path: []const u8, explicit: bool, files: *std.ArrayList([]const u8)) !void {
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => return files.append(a, path),
        error.FileNotFound => return if (explicit) files.append(a, path),
        else => |e| return e,
    };
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    const first = files.items.len;
    while (try walker.next(io)) |e| {
        if (e.kind == .file and std.mem.endsWith(u8, e.path, ".pr")) try files.append(a, try std.fs.path.join(a, &.{ path, e.path }));
    }
    std.mem.sort([]const u8, files.items[first..], {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

/// Runs `pyro args...`; returns the exit status and stdout (owned by `a`).
fn runPyro(a: Allocator, args: []const []const u8) !struct { cli.Exit, []const u8 } {
    var out: Io.Writer.Allocating = .init(a);
    var err: Io.Writer.Allocating = .init(a);
    const env: std.process.Environ.Map = .init(a);
    const exit = try cli.run(testing.allocator, testing.io, &env, args, .{ .stdout = &out.writer, .stderr = &err.writer });
    return .{ exit, out.written() };
}

test "pyro fmt --check exits 1 on a diff; pyro fmt rewrites; then --check passes" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.pr", .data = "fn main(){let x=1+2;}\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "ok.pr", .data = "fn main() {}\n" });
    const dir = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const file = try std.fs.path.join(a, &.{ dir, "a.pr" });

    const check1 = try runPyro(a, &.{ "fmt", "--check", dir });
    try testing.expectEqual(cli.Exit.failed, check1[0]);
    try testing.expectEqualStrings(try std.mem.concat(a, u8, &.{ file, "\n" }), check1[1]);
    try testing.expectEqualStrings("fn main(){let x=1+2;}\n", try tmp.dir.readFileAlloc(testing.io, "a.pr", a, .unlimited));

    const write = try runPyro(a, &.{ "fmt", dir });
    try testing.expectEqual(cli.Exit.ok, write[0]);
    try testing.expectEqualStrings("fn main() { let x = 1 + 2; }\n", try tmp.dir.readFileAlloc(testing.io, "a.pr", a, .unlimited));

    const check2 = try runPyro(a, &.{ "fmt", "--check", file });
    try testing.expectEqual(cli.Exit.ok, check2[0]);
    try testing.expectEqualStrings("", check2[1]);
}

test "pyro fmt leaves a file with a syntax error alone and exits 1" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "bad.pr", .data = "fn main( {\n" });
    const file = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path, "bad.pr" });
    const r = try runPyro(a, &.{ "fmt", file });
    try testing.expectEqual(cli.Exit.failed, r[0]);
    try testing.expectEqualStrings("fn main( {\n", try tmp.dir.readFileAlloc(testing.io, "bad.pr", a, .unlimited));
}
