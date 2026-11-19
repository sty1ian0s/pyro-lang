//! Package layout and workspace discovery (§13.1, §7.8.1).
//!
//! `findRoot` locates the nearest directory with a `pyro.toml`; `open` loads that
//! manifest and maps the package on disk: its kind (executable or library, E0908),
//! the modules under `src/`, the integration-test modules under `tests/`, the
//! `assets/` directory, and the workspace whose `pyro.lock` and build cache it shares.
//!
//! Module paths are only computed here; checking that their segments are identifiers
//! (E0901) belongs to module collection (§7.8.1).

const std = @import("std");
const Io = std.Io;
const diag = @import("../diag/diag.zig");
const SourceMap = @import("../source/SourceMap.zig");
const manifest = @import("manifest.zig");

/// Executable (`src/main.pr`) or library (`src/lib.pr`) (§13.1).
pub const Kind = enum {
    exe,
    lib,

    /// The root module's file, relative to the package directory.
    pub fn rootFile(k: Kind) []const u8 {
        return switch (k) {
            .exe => "src" ++ std.fs.path.sep_str ++ "main.pr",
            .lib => "src" ++ std.fs.path.sep_str ++ "lib.pr",
        };
    }
};

/// One `.pr` file and the module path it defines.
pub const Module = struct {
    /// Dotted module path: `physics.rigid_body` for `src/physics/rigid_body.pr`.
    path: []const u8,
    /// The file, relative to the package directory (`src/physics/rigid_body.pr`).
    file: []const u8,
};

/// The on-disk shape of a package; null for a virtual workspace root.
pub const Package = struct {
    kind: Kind,
    /// Every module under `src/`, sorted by path; includes the root module (`main` or `lib`).
    modules: []const Module,
    /// Every file under `tests/`, sorted by path; module paths are relative to `tests/`.
    /// Each sees only the package's `pub` API (§13.6).
    tests: []const Module,
    /// Absolute path of `assets/`, if it exists.
    assets: ?[]const u8,
};

/// A loaded `pyro.toml` directory: a package, a workspace root, or both.
pub const Layout = struct {
    arena: std.heap.ArenaAllocator,
    /// Absolute, canonical directory holding `pyro.toml`.
    dir: []const u8,
    manifest: manifest.Manifest,
    manifest_file: diag.FileId,
    package: ?Package,
    /// Absolute member directories if this directory is a workspace root, else empty.
    members: []const []const u8,
    /// The workspace root if this package is one of its members (or is it), else `dir`.
    /// It holds the one `pyro.lock` and build cache all members share.
    workspace_dir: []const u8,
    /// `<workspace_dir>/pyro.lock`.
    lock_path: []const u8,

    pub fn deinit(l: *Layout) void {
        l.manifest.deinit();
        l.arena.deinit();
        l.* = undefined;
    }
};

pub const manifest_name = "pyro.toml";
pub const lock_name = "pyro.lock";

/// Returns the nearest directory at or above `start` that contains `pyro.toml`, as an
/// absolute canonical path allocated with `gpa`, or null if there is none.
pub fn findRoot(gpa: std.mem.Allocator, io: Io, start: []const u8) !?[]u8 {
    const abs = try Io.Dir.cwd().realPathFileAlloc(io, start, gpa);
    defer gpa.free(abs);
    var p: ?[]const u8 = abs;
    while (p) |dir| : (p = std.fs.path.dirname(dir)) {
        const toml_path = try std.fs.path.join(gpa, &.{ dir, manifest_name });
        defer gpa.free(toml_path);
        if (try exists(io, toml_path)) return try gpa.dupe(u8, dir);
    }
    return null;
}

/// Errors `open` returns besides I/O failures.
pub const Error = error{ InvalidManifest, InvalidLayout, OutOfMemory };

/// Loads `<dir>/pyro.toml` into `sm` and maps the package. Manifest errors (E0909)
/// and a missing or ambiguous root module (E0908, at the `[package]` header) go to
/// `sink` and fail with `error.InvalidManifest` / `error.InvalidLayout`.
///
/// The enclosing workspace is the first ancestor whose manifest has a `[workspace]`
/// table: the package belongs to it only if one of its `members` resolves to `dir`.
pub fn open(gpa: std.mem.Allocator, io: Io, sm: *SourceMap, sink: *diag.Sink, dir: []const u8) !Layout {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const abs = try Io.Dir.cwd().realPathFileAlloc(io, dir, a);

    const file = try sm.load(.cwd(), try std.fs.path.join(a, &.{ abs, manifest_name }), sink);
    var m = try manifest.load(gpa, sm.get(file).text, file, sink);
    errdefer m.deinit();

    var members: []const []const u8 = &.{};
    if (m.workspace) |ws| members = try resolveMembers(a, abs, ws.members);
    const ws_dir = if (m.workspace != null) abs else try findWorkspace(a, io, sm, sink, abs) orelse abs;

    var package: ?Package = null;
    if (m.package != null) {
        const has_main = try exists(io, try std.fs.path.join(a, &.{ abs, Kind.exe.rootFile() }));
        const has_lib = try exists(io, try std.fs.path.join(a, &.{ abs, Kind.lib.rootFile() }));
        if (has_main == has_lib) {
            const span = m.doc.root.get("package").?.span;
            try sink.emit(.{
                .code = .E0908,
                .severity = .of(.E0908),
                .message = if (has_main)
                    "package has both `src/main.pr` and `src/lib.pr`"
                else
                    "package has neither `src/main.pr` nor `src/lib.pr`",
                .spans = &.{.{ .span = .{ .file = file, .start = span.start, .end = span.end }, .primary = true }},
                .help = &.{"a package is an executable (`src/main.pr`) or a library (`src/lib.pr`), not both"},
            });
            return error.InvalidLayout;
        }
        const assets = try std.fs.path.join(a, &.{ abs, "assets" });
        package = .{
            .kind = if (has_main) .exe else .lib,
            .modules = try collect(a, io, abs, "src"),
            .tests = try collect(a, io, abs, "tests"),
            .assets = if (try exists(io, assets)) assets else null,
        };
    }

    return .{
        .arena = arena,
        .dir = abs,
        .manifest = m,
        .manifest_file = file,
        .package = package,
        .members = members,
        .workspace_dir = ws_dir,
        .lock_path = try std.fs.path.join(a, &.{ ws_dir, lock_name }),
    };
}

/// The module path of `rel`, a `.pr` file path relative to `src/` (§7.8.1):
/// the extension dropped and separators replaced by `.`.
pub fn modulePath(a: std.mem.Allocator, rel: []const u8) ![]u8 {
    const out = try a.dupe(u8, rel[0 .. rel.len - ".pr".len]);
    std.mem.replaceScalar(u8, out, std.fs.path.sep, '.');
    return out;
}

fn resolveMembers(a: std.mem.Allocator, root: []const u8, rel: []const []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, rel.len);
    for (rel, out) |r, *o| o.* = try std.fs.path.resolveAlloc(a, &.{ root, r });
    return out;
}

fn findWorkspace(a: std.mem.Allocator, io: Io, sm: *SourceMap, sink: *diag.Sink, pkg: []const u8) !?[]const u8 {
    var p = std.fs.path.dirname(pkg);
    while (p) |dir| : (p = std.fs.path.dirname(dir)) {
        const toml_path = try std.fs.path.join(a, &.{ dir, manifest_name });
        if (!try exists(io, toml_path)) continue;
        const file = try sm.load(.cwd(), toml_path, sink);
        var m = try manifest.load(a, sm.get(file).text, file, sink);
        defer m.deinit();
        const ws = m.workspace orelse continue;
        for (try resolveMembers(a, dir, ws.members)) |member| {
            if (std.mem.eql(u8, member, pkg)) return dir;
        }
        return null;
    }
    return null;
}

fn collect(a: std.mem.Allocator, io: Io, pkg: []const u8, sub: []const u8) ![]const Module {
    var root = Io.Dir.cwd().openDir(io, try std.fs.path.join(a, &.{ pkg, sub }), .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return &.{},
        else => |e| return e,
    };
    defer root.close(io);
    var walker = try root.walk(a);
    defer walker.deinit();
    var out: std.ArrayList(Module) = .empty;
    while (try walker.next(io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.path, ".pr")) continue;
        try out.append(a, .{
            .path = try modulePath(a, e.path),
            .file = try std.fs.path.join(a, &.{ sub, e.path }),
        });
    }
    std.mem.sort(Module, out.items, {}, struct {
        fn lt(_: void, x: Module, y: Module) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.lt);
    return out.items;
}

fn exists(io: Io, path: []const u8) !bool {
    Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    return true;
}

const testing = std.testing;

const pkg_toml = "[package]\nname = \"p\"\nversion = \"0.1.0\"\nedition = \"2026\"\n";

/// Writes `files` (path, contents) under `tmp`; returns the tree's absolute path.
fn tree(tmp: *testing.TmpDir, files: []const [2][]const u8) ![:0]u8 {
    for (files) |f| {
        if (std.fs.path.dirname(f[0])) |d| try tmp.dir.createDirPath(testing.io, d);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = f[0], .data = f[1] });
    }
    return tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
}

fn expectE0908(files: []const [2][]const u8, message: []const u8) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tree(&tmp, files);
    defer testing.allocator.free(root);
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    var sm: SourceMap = .init(testing.allocator, testing.io);
    defer sm.deinit();
    try testing.expectError(error.InvalidLayout, open(testing.allocator, testing.io, &sm, &sink, root));
    const ds = sink.finish();
    try testing.expectEqual(1, ds.len);
    try testing.expectEqual(diag.DiagCode.E0908, ds[0].code.?);
    try testing.expectEqualStrings(message, ds[0].message);
    const s = ds[0].primarySpan().?;
    try testing.expectEqualStrings("[package]", sm.get(s.file).text[s.start..s.end]);
}

test "E0908: both or neither root module" {
    try expectE0908(&.{
        .{ "pyro.toml", pkg_toml },
        .{ "src/main.pr", "" },
        .{ "src/lib.pr", "" },
    }, "package has both `src/main.pr` and `src/lib.pr`");
    try expectE0908(&.{
        .{ "pyro.toml", pkg_toml },
        .{ "src/util.pr", "" },
    }, "package has neither `src/main.pr` nor `src/lib.pr`");
    try expectE0908(&.{.{ "pyro.toml", pkg_toml }}, "package has neither `src/main.pr` nor `src/lib.pr`");
}

test "src/** maps to module paths; tests/ and assets/ are found" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tree(&tmp, &.{
        .{ "pyro.toml", pkg_toml },
        .{ "src/main.pr", "" },
        .{ "src/physics/rigid_body.pr", "" },
        .{ "src/physics/notes.txt", "" },
        .{ "tests/smoke.pr", "" },
        .{ "assets/logo.png", "" },
    });
    defer testing.allocator.free(root);
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    var sm: SourceMap = .init(testing.allocator, testing.io);
    defer sm.deinit();
    var l = try open(testing.allocator, testing.io, &sm, &sink, root);
    defer l.deinit();
    const p = l.package.?;
    try testing.expectEqual(Kind.exe, p.kind);
    try testing.expectEqual(2, p.modules.len);
    try testing.expectEqualStrings("main", p.modules[0].path);
    try testing.expectEqualStrings("physics.rigid_body", p.modules[1].path);
    try testing.expectEqualStrings("src" ++ std.fs.path.sep_str ++ "physics" ++ std.fs.path.sep_str ++ "rigid_body.pr", p.modules[1].file);
    try testing.expectEqual(1, p.tests.len);
    try testing.expectEqualStrings("smoke", p.tests[0].path);
    try testing.expect(std.mem.endsWith(u8, p.assets.?, "assets"));
    try testing.expectEqualStrings(root, l.workspace_dir);
    try testing.expectEqual(0, sink.finish().len);
}

test "workspace members share one lock path; findRoot walks up" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tree(&tmp, &.{
        .{ "pyro.toml", "[workspace]\nmembers = [\"core\", \"tools/cli\"]\n" },
        .{ "core/pyro.toml", pkg_toml },
        .{ "core/src/lib.pr", "" },
        .{ "tools/cli/pyro.toml", pkg_toml },
        .{ "tools/cli/src/main.pr", "" },
        .{ "tools/cli/src/cmd/run.pr", "" },
        .{ "other/pyro.toml", pkg_toml },
        .{ "other/src/lib.pr", "" },
    });
    defer testing.allocator.free(root);
    const a = testing.allocator;
    var sink: diag.Sink = .init(a, testing.io);
    defer sink.deinit();
    var sm: SourceMap = .init(a, testing.io);
    defer sm.deinit();

    const cmd = try std.fs.path.join(a, &.{ root, "tools", "cli", "src", "cmd" });
    defer a.free(cmd);
    const cli_dir = (try findRoot(a, testing.io, cmd)).?;
    defer a.free(cli_dir);
    try testing.expect(std.mem.endsWith(u8, cli_dir, "cli"));

    var ws = try open(a, testing.io, &sm, &sink, root);
    defer ws.deinit();
    try testing.expect(ws.package == null);
    try testing.expectEqual(2, ws.members.len);

    var cli = try open(a, testing.io, &sm, &sink, cli_dir);
    defer cli.deinit();
    const core_dir = try std.fs.path.join(a, &.{ root, "core" });
    defer a.free(core_dir);
    var core = try open(a, testing.io, &sm, &sink, core_dir);
    defer core.deinit();
    try testing.expectEqual(Kind.lib, core.package.?.kind);
    try testing.expectEqualStrings(ws.lock_path, cli.lock_path);
    try testing.expectEqualStrings(ws.lock_path, core.lock_path);
    try testing.expectEqual(0, cli.members.len);
    try testing.expectEqualStrings("cmd.run", cli.package.?.modules[0].path);

    // Not listed in `members`: its own lock.
    const other_dir = try std.fs.path.join(a, &.{ root, "other" });
    defer a.free(other_dir);
    var other = try open(a, testing.io, &sm, &sink, other_dir);
    defer other.deinit();
    try testing.expectEqualStrings(other.dir, other.workspace_dir);
    try testing.expect(!std.mem.eql(u8, ws.lock_path, other.lock_path));
    try testing.expectEqual(0, sink.finish().len);
}
