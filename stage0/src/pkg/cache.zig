//! The global content-addressed source cache (§13.4; layout in `docs/registry.md`).
//!
//! Source trees live under `src/<sha256 hex>/`, named by their `lock.hashTree`
//! hash. A tree is staged under `tmp/`, extracted with `extractTar` (read-only
//! files, no entry outside the tree), hashed, and moved into `src/` by one
//! rename; an installed entry is never written again. `git/` holds bare
//! mirrors and `index/` copies of registry index files, both keyed by `urlKey`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const lock = @import("lock.zig");

/// An open cache directory.
pub const Cache = struct {
    /// Path of the cache root, owned.
    root: []const u8,
    dir: Io.Dir,

    /// Opens the cache at `root`, creating it and its subdirectories if needed.
    pub fn open(gpa: Allocator, io: Io, root: []const u8) !Cache {
        var dir = try Io.Dir.cwd().createDirPathOpen(io, root, .{});
        errdefer dir.close(io);
        for ([_][]const u8{ "src", "tmp", "git", "index" }) |sub| try dir.createDirPath(io, sub);
        return .{ .root = try gpa.dupe(u8, root), .dir = dir };
    }

    pub fn close(c: *Cache, gpa: Allocator, io: Io) void {
        c.dir.close(io);
        gpa.free(c.root);
        c.* = undefined;
    }

    /// `<root>/<parts...>`, owned by the caller.
    pub fn path(c: *const Cache, gpa: Allocator, parts: []const []const u8) ![]u8 {
        var all: [8][]const u8 = undefined;
        all[0] = c.root;
        @memcpy(all[1..][0..parts.len], parts);
        return std.fs.path.join(gpa, all[0 .. parts.len + 1]);
    }

    /// Whether a tree with hash `h` is installed.
    pub fn has(c: *const Cache, io: Io, h: lock.Hash) bool {
        const name = srcName(h);
        c.dir.access(io, &name, .{}) catch return false;
        return true;
    }

    /// Path of the installed tree with hash `h`, owned by the caller.
    pub fn srcPath(c: *const Cache, gpa: Allocator, h: lock.Hash) ![]u8 {
        const name = srcName(h);
        return c.path(gpa, &.{&name});
    }

    /// Creates an empty staging directory under `tmp/`.
    pub fn stage(c: *const Cache, io: Io) !Staging {
        var s: Staging = .{ .name = undefined, .dir = undefined };
        var rand: [8]u8 = undefined;
        io.random(&rand);
        s.name = "tmp/".* ++ std.fmt.bytesToHex(rand, .lower);
        s.dir = try c.dir.createDirPathOpen(io, &s.name, .{ .open_options = .{ .iterate = true } });
        return s;
    }

    /// Moves `s` into `src/` as the tree with hash `h` and returns its path
    /// (owned by the caller). If another fetch installed it first, `s` is
    /// discarded and the existing entry kept.
    pub fn install(c: *const Cache, gpa: Allocator, io: Io, s: *Staging, h: lock.Hash) ![]u8 {
        s.dir.close(io);
        const name = srcName(h);
        c.dir.rename(&s.name, c.dir, &name, io) catch |err| switch (err) {
            error.DirNotEmpty, error.AccessDenied, error.PermissionDenied => {
                c.dir.deleteTree(io, &s.name) catch {};
                if (!c.has(io, h)) return err;
            },
            else => return err,
        };
        return c.srcPath(gpa, h);
    }

    /// Deletes staging directory `s`.
    pub fn discard(c: *const Cache, io: Io, s: *Staging) void {
        s.dir.close(io);
        c.dir.deleteTree(io, &s.name) catch {};
    }
};

/// A directory under `tmp/` being filled before `Cache.install`.
pub const Staging = struct {
    /// `tmp/<16 hex digits>`, relative to the cache root.
    name: [20]u8,
    /// Opened with `.iterate = true`, so `lock.hashTree` accepts it.
    dir: Io.Dir,
};

fn srcName(h: lock.Hash) [4 + 64]u8 {
    return "src/".* ++ std.fmt.bytesToHex(h, .lower);
}

/// The first 16 hex digits of SHA-256(`url`): the cache key of a remote.
pub fn urlKey(url: []const u8) [16]u8 {
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(url, &h, .{});
    return std.fmt.bytesToHex(h[0..8].*, .lower);
}

pub const ExtractError = error{ UnsafeArchiveEntry, UnsupportedArchiveEntry };

/// Extracts the tar stream `r` into the empty directory `dir`. Files are created
/// read-only (keeping the owner executable bit), never over an existing entry.
/// Absolute paths, `..` components and symbolic links whose target is absolute
/// or contains `..` are rejected, so nothing lands or points outside `dir`.
pub fn extractTar(io: Io, dir: Io.Dir, r: *Io.Reader) !void {
    var name_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var link_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(r, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    var buf: [4096]u8 = undefined;
    while (try it.next()) |f| {
        if (!safePath(f.name)) return error.UnsafeArchiveEntry;
        switch (f.kind) {
            .directory => if (!isDot(f.name)) try dir.createDirPath(io, f.name),
            .sym_link => {
                if (!safePath(f.link_name)) return error.UnsafeArchiveEntry;
                if (std.fs.path.dirname(f.name)) |d| try dir.createDirPath(io, d);
                try dir.symLink(io, f.link_name, f.name, .{});
            },
            .file => {
                if (std.fs.path.dirname(f.name)) |d| try dir.createDirPath(io, d);
                const base: Io.File.Permissions = if (Io.File.Permissions.has_executable_bit and f.mode & 0o100 != 0) .executable_file else .default_file;
                const file = try dir.createFile(io, f.name, .{ .exclusive = true, .permissions = base.setReadOnly(true) });
                defer file.close(io);
                var w = file.writer(io, &buf);
                try it.streamRemaining(f, &w.interface);
                try w.interface.flush();
            },
        }
    }
}

/// Relative, non-empty, and free of `..` components.
fn safePath(p: []const u8) bool {
    if (p.len == 0 or std.fs.path.isAbsolute(p) or p[0] == '/') return false;
    var it = std.mem.tokenizeAny(u8, p, "/\\");
    while (it.next()) |seg| if (std.mem.eql(u8, seg, "..")) return false;
    return true;
}

fn isDot(p: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, p, '/');
    while (it.next()) |seg| if (!std.mem.eql(u8, seg, ".")) return false;
    return true;
}

// --- tests ---------------------------------------------------------------------

const testing = std.testing;

/// A ustar archive of `entries` (name, kind, payload: content or link target).
fn tarOf(gpa: Allocator, entries: []const struct { []const u8, std.tar.FileKind, []const u8 }) ![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var w: std.tar.Writer = .{ .underlying_writer = &out.writer };
    for (entries) |e| switch (e[1]) {
        .file => try w.writeFileBytes(e[0], e[2], .{}),
        .directory => try w.writeDir(e[0], .{}),
        .sym_link => try w.writeLink(e[0], e[2], .{}),
    };
    try w.finishPedantically();
    return out.toOwnedSlice();
}

fn extractBytes(io: Io, dir: Io.Dir, bytes: []const u8) !void {
    var r: Io.Reader = .fixed(bytes);
    return extractTar(io, dir, &r);
}

test "install, has, and a concurrent duplicate install keeps the first" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    var c: Cache = try .open(testing.allocator, testing.io, root);
    defer c.close(testing.allocator, testing.io);

    const tar = try tarOf(testing.allocator, &.{
        .{ "./", .directory, "" },
        .{ "src/lib.pr", .file, "pub fn f() {}\n" },
        .{ "lib", .sym_link, "src/lib.pr" },
    });
    defer testing.allocator.free(tar);

    var a = try c.stage(testing.io);
    try extractBytes(testing.io, a.dir, tar);
    const h = try lock.hashTree(testing.allocator, testing.io, a.dir);
    try testing.expect(!c.has(testing.io, h));
    var b = try c.stage(testing.io);
    try extractBytes(testing.io, b.dir, tar);
    try testing.expectEqual(h, try lock.hashTree(testing.allocator, testing.io, b.dir));

    const p1 = try c.install(testing.allocator, testing.io, &a, h);
    defer testing.allocator.free(p1);
    const p2 = try c.install(testing.allocator, testing.io, &b, h);
    defer testing.allocator.free(p2);
    try testing.expectEqualStrings(p1, p2);
    try testing.expect(c.has(testing.io, h));
    try testing.expect(std.mem.endsWith(u8, p1, &std.fmt.bytesToHex(h, .lower)));

    // Staging is empty again, and installed files are read-only.
    var tmpdir = try c.dir.openDir(testing.io, "tmp", .{ .iterate = true });
    defer tmpdir.close(testing.io);
    var tit = tmpdir.iterate();
    try testing.expectEqual(null, try tit.next(testing.io));
    const st = try c.dir.statFile(testing.io, "src/" ++ std.fmt.bytesToHex(h, .lower) ++ "/src/lib.pr", .{});
    if (Io.File.Permissions.has_executable_bit) try testing.expect(st.permissions.readOnly());
}

test "extractTar rejects entries escaping the tree" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bad = [_][]const struct { []const u8, std.tar.FileKind, []const u8 }{
        &.{.{ "a/../../x", .file, "" }},
        &.{.{ "up", .sym_link, "../outside" }},
        &.{.{ "abs", .sym_link, "/etc/passwd" }},
        &.{.{ "d", .sym_link, "a/b/../../.." }},
    };
    for (bad) |entries| {
        const tar = try tarOf(testing.allocator, entries);
        defer testing.allocator.free(tar);
        try testing.expectError(error.UnsafeArchiveEntry, extractBytes(testing.io, tmp.dir, tar));
    }
    // A link to a sibling inside the tree is fine; a duplicate entry is not.
    const dup = try tarOf(testing.allocator, &.{ .{ "a", .file, "1" }, .{ "a", .file, "2" } });
    defer testing.allocator.free(dup);
    try testing.expectError(error.PathAlreadyExists, extractBytes(testing.io, tmp.dir, dup));
}

test "urlKey is stable and distinguishes URLs" {
    try testing.expectEqualStrings(&urlKey("file:///r"), &urlKey("file:///r"));
    try testing.expect(!std.mem.eql(u8, &urlKey("file:///r"), &urlKey("file:///s")));
}
