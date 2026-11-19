//! `pyro fmt [--check] [path...]` (§13.8): formats source files in the single
//! canonical style (`fmt/fmt.zig`, `docs/style.md`).
//!
//! Each path is a `.pr` file or a directory searched recursively for `.pr`
//! files. Without paths, `build.pr` and the `src/` and `tests/` trees of the
//! package around the current directory are formatted, and at a workspace
//! root those of every member too. Every file whose text changes is named on
//! stdout; it is rewritten in place (atomically, through a symlink, keeping
//! its mode), or with `--check` left alone and the command exits 1. `--check`
//! also reports names that break the §2.3 conventions (`fmt/naming.zig`) and
//! then exits 1. A file that does not lex or parse is not formatted: its
//! diagnostics are reported and the command exits 1.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const cli = @import("main.zig");
const fmt = @import("../fmt/fmt.zig");
const naming = @import("../fmt/naming.zig");
const diag = @import("../diag/diag.zig");
const SourceMap = @import("../source/SourceMap.zig");
const layout = @import("../pkg/layout.zig");

/// Runs `pyro fmt`; without paths, on the package around the working directory.
pub fn run(ctx: *cli.Ctx) !cli.Exit {
    return runFrom(ctx, ".");
}

/// `run`, finding the package (when no paths are given) at or above `start`.
fn runFrom(ctx: *cli.Ctx, start: []const u8) !cli.Exit {
    var arena_state: std.heap.ArenaAllocator = .init(ctx.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sm: SourceMap = .init(ctx.gpa, ctx.io);
    defer sm.deinit();
    var files: std.ArrayList([]const u8) = .empty;
    if (ctx.opts.positionals.len == 0) {
        const root = try layout.findRoot(a, ctx.io, start) orelse {
            try ctx.out.stderr.print("error: could not find `pyro.toml` in `{s}` or any parent directory; name the files to format\n", .{start});
            return .failed;
        };
        var sink: diag.Sink = .init(ctx.gpa, ctx.io);
        defer sink.deinit();
        var l = layout.open(ctx.gpa, ctx.io, &sm, &sink, root) catch |err| switch (err) {
            error.InvalidManifest, error.InvalidLayout => {
                try cli.renderDiagnostics(ctx, &sm, sink.finish());
                return .failed;
            },
            else => |e| return e,
        };
        defer l.deinit();
        // The package and, at a workspace root, every member (§13.1, §13.5).
        for (try std.mem.concat(a, []const u8, &.{ &.{l.dir}, l.members })) |dir| {
            for ([_][]const u8{ "build.pr", "src", "tests" }) |sub| try collect(a, ctx.io, try std.fs.path.join(a, &.{ dir, sub }), false, &files);
        }
    } else for (ctx.opts.positionals) |p| try collect(a, ctx.io, p, true, &files);

    var exit: cli.Exit = .ok;
    for (files.items) |path| {
        var sink: diag.Sink = .init(ctx.gpa, ctx.io);
        defer sink.deinit();
        const id = sm.load(.cwd(), path, &sink) catch |err| {
            try ctx.out.stderr.print("error: cannot read `{s}`: {t}\n", .{ path, err });
            return .usage;
        };
        const file = sm.get(id);
        var ast = (if (sink.hasErrors()) null else try fmt.parse(ctx.gpa, file.text, id, &sink)) orelse {
            try cli.renderDiagnostics(ctx, &sm, sink.finish());
            exit = .failed;
            continue;
        };
        defer ast.deinit(ctx.gpa);
        if (ctx.opts.check) {
            const bad = try naming.check(ctx.gpa, &ast);
            defer ctx.gpa.free(bad);
            for (bad) |v| {
                const loc = sm.location(id, ast.tokens.items(.start)[v.token]);
                try ctx.out.stdout.print("{s}:{d}:{d}: `{s}` is not {t} (§2.3)\n", .{ path, loc.line, loc.column, ast.tokenSlice(v.token), v.want });
                exit = .failed;
            }
        }
        const formatted = fmt.format(ctx.gpa, ctx.io, &ast) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TokensChanged => {
                try ctx.out.stderr.print("error: internal compiler error: formatting `{s}` would change its tokens\n", .{path});
                return .internal;
            },
        };
        defer ctx.gpa.free(formatted);
        if (std.mem.eql(u8, formatted, file.raw)) continue;
        try ctx.out.stdout.print("{s}\n", .{path});
        if (ctx.opts.check) {
            exit = .failed;
            continue;
        }
        // Rewrite the target of a symlink, not the link, and keep the file's mode.
        const real = try Io.Dir.cwd().realPathFileAlloc(ctx.io, path, a);
        const st = try Io.Dir.cwd().statFile(ctx.io, real, .{});
        var af = try Io.Dir.cwd().createFileAtomic(ctx.io, real, .{ .replace = true, .permissions = st.permissions });
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

/// Runs `pyro fmt [--check]` with no paths, for the package at or above `start`.
fn runPackage(a: Allocator, start: []const u8, check: bool) !struct { cli.Exit, []const u8 } {
    var out: Io.Writer.Allocating = .init(a);
    var err: Io.Writer.Allocating = .init(a);
    const env: std.process.Environ.Map = .init(a);
    var ctx: cli.Ctx = .{ .gpa = testing.allocator, .io = testing.io, .environ = &env, .opts = .{ .command = .fmt, .check = check }, .out = .{ .stdout = &out.writer, .stderr = &err.writer } };
    return .{ try runFrom(&ctx, start), out.written() };
}

test "pyro fmt without paths formats build.pr, src/ and tests/ of the workspace and its members" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const pkg = "[package]\nname = \"p\"\nversion = \"0.1.0\"\nedition = \"2026\"\n";
    const ugly = "fn main(){}\n";
    for ([_][2][]const u8{
        .{ "pyro.toml", "[workspace]\nmembers = [\"m\"]\n" ++ pkg },
        .{ "build.pr", ugly },
        .{ "src/main.pr", ugly },
        .{ "tests/t.pr", ugly },
        .{ "other/x.pr", ugly },
        .{ "m/pyro.toml", pkg },
        .{ "m/build.pr", ugly },
        .{ "m/src/lib.pr", ugly },
    }) |f| {
        if (std.fs.path.dirname(f[0])) |d| try tmp.dir.createDirPath(testing.io, d);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = f[0], .data = f[1] });
    }
    const start = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path, "src" });
    const r = try runPackage(a, start, false);
    try testing.expectEqual(cli.Exit.ok, r[0]);
    for ([_][]const u8{ "build.pr", "src/main.pr", "tests/t.pr", "m/build.pr", "m/src/lib.pr" }) |p| {
        try testing.expectEqualStrings("fn main() {}\n", try tmp.dir.readFileAlloc(testing.io, p, a, .unlimited));
    }
    try testing.expectEqualStrings(ugly, try tmp.dir.readFileAlloc(testing.io, "other/x.pr", a, .unlimited));
    try testing.expectEqual(cli.Exit.ok, (try runPackage(a, start, true))[0]);
}

test "pyro fmt rewrites the target of a symlink and keeps the file mode" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "real.pr", .data = "fn main(){}\n" });
    try tmp.dir.symLink(testing.io, "real.pr", "link.pr", .{});
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "exe.pr", .data = "fn main(){}\n", .flags = .{ .permissions = .fromMode(0o755) } });
    const dir = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });

    const r = try runPyro(a, &.{ "fmt", try std.fs.path.join(a, &.{ dir, "link.pr" }), try std.fs.path.join(a, &.{ dir, "exe.pr" }) });
    try testing.expectEqual(cli.Exit.ok, r[0]);
    try testing.expectEqualStrings("fn main() {}\n", try tmp.dir.readFileAlloc(testing.io, "real.pr", a, .unlimited));
    const link = try tmp.dir.statFile(testing.io, "link.pr", .{ .follow_symlinks = false });
    try testing.expectEqual(Io.File.Kind.sym_link, link.kind);
    const exe = try tmp.dir.statFile(testing.io, "exe.pr", .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o755), exe.permissions.toMode() & 0o777);
}

test "pyro fmt --check reports names that break the §2.3 conventions" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "n.pr", .data = "struct point { x: i32 }\nfn Main() {}\n" });
    const file = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path, "n.pr" });
    const r = try runPyro(a, &.{ "fmt", "--check", file });
    try testing.expectEqual(cli.Exit.failed, r[0]);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a,
        \\{0s}:1:8: `point` is not PascalCase (§2.3)
        \\{0s}:2:4: `Main` is not snake_case (§2.3)
        \\
    , .{file}), r[1]);
    // Without `--check`, names are not checked and the file is already formatted.
    try testing.expectEqual(cli.Exit.ok, (try runPyro(a, &.{ "fmt", file }))[0]);
}
