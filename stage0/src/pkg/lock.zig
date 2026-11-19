//! `pyro.lock` (§13.4): the generated, committed record of every resolved
//! dependency's name, version, source and SHA-256, plus the checks builds run
//! against it: hash verification (E0911), `--locked`, and lock-preferring
//! resolution (only `pyro update` re-resolves from scratch).
//!
//! Format: TOML, one `[[package]]` table per package, sorted by (name, version):
//!
//! ```toml
//! [[package]]
//! name = "util"
//! version = "1.0.0"
//! source = "registry"          # or "registry+<name>", "git+<url>#<commit>", "path+<dir>"
//! sha256 = "<64 lowercase hex digits>"
//! ```
//!
//! `render` is deterministic: equal package sets give byte-identical files, so
//! `--locked` compares bytes. `--offline` is a fetch-level mode (T160): the
//! index and sources come from the cache only, and nothing here changes.

const std = @import("std");
const toml = @import("../toml/toml.zig");
const semver = @import("semver.zig");
const resolve = @import("resolve.zig");
const diag = @import("../diag/diag.zig");

/// SHA-256 digest of a source tree (see `hashTree`).
pub const Hash = [32]u8;

/// Where a locked package's source came from.
pub const Source = union(enum) {
    /// A registry archive; null is the default registry.
    registry: ?[]const u8,
    /// A git checkout at an exact commit.
    git: struct { url: []const u8, rev: []const u8 },
    /// A local directory, relative to the root manifest's directory.
    path: []const u8,
};

/// One `[[package]]` entry.
pub const Package = struct {
    name: []const u8,
    version: semver.Version,
    source: Source,
    sha256: Hash,
    /// The entry's `sha256` value in `pyro.lock`, when parsed from a file.
    span: ?diag.Span = null,
};

/// A parsed `pyro.lock`. Strings point into `arena`.
pub const Lock = struct {
    arena: std.heap.ArenaAllocator,
    /// Sorted by name, then version precedence; no duplicates.
    packages: []const Package,

    pub fn deinit(l: *Lock) void {
        l.arena.deinit();
        l.* = undefined;
    }

    /// The entry for `name` at `version`, if locked.
    pub fn find(l: *const Lock, name: []const u8, version: semver.Version) ?*const Package {
        for (l.packages) |*p| {
            if (std.mem.eql(u8, p.name, name) and p.version.order(version) == .eq) return p;
        }
        return null;
    }
};

pub const ParseError = error{ InvalidLock, OutOfMemory };

/// Parses `source`, the text of the `pyro.lock` registered as `file`. Every
/// problem is reported to `sink` (no A.3 code covers a malformed lock file, so
/// these diagnostics have none); if there was any, the result is `error.InvalidLock`.
pub fn parse(gpa: std.mem.Allocator, source: []const u8, file: diag.FileId, sink: *diag.Sink) ParseError!Lock {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var p: Parser = .{ .a = a, .file = file, .sink = sink };

    var tdiag: toml.Diagnostic = undefined;
    var doc = toml.parse(gpa, source, &tdiag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidToml => {
            try p.report(tdiag.span, "`pyro.lock` is not valid TOML: {s}", .{tdiag.message});
            return error.InvalidLock;
        },
    };
    defer doc.deinit();

    var out: std.ArrayList(Package) = .empty;
    for (doc.root.entries.keys(), doc.root.entries.values()) |k, e| {
        if (!std.mem.eql(u8, k, "package")) {
            try p.report(e.key_span, "unknown key `{s}` in `pyro.lock`", .{k});
            continue;
        }
        if (e.value.data != .array or e.value.data.array.kind != .tables) {
            try p.report(e.value.span, "`package` must be an array of tables (`[[package]]`)", .{});
            continue;
        }
        for (e.value.data.array.items.items) |item| {
            if (try p.package(item.data.table, item.span)) |pkg| try out.append(a, pkg);
        }
    }
    std.mem.sort(Package, out.items, {}, lessThan);
    for (out.items[0..out.items.len -| 1], out.items[@min(1, out.items.len)..]) |x, y| {
        if (!lessThan({}, x, y)) try p.report(spanOf(y.span), "`{s}` {f} is locked twice", .{ y.name, versionFmt(y.version) });
    }
    if (p.failed) return error.InvalidLock;
    return .{ .arena = arena, .packages = out.items };
}

fn spanOf(s: ?diag.Span) toml.Span {
    return if (s) |x| .{ .start = x.start, .end = x.end } else .none;
}

const Parser = struct {
    a: std.mem.Allocator,
    file: diag.FileId,
    sink: *diag.Sink,
    failed: bool = false,

    fn report(p: *Parser, span: toml.Span, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        p.failed = true;
        const msg = try std.fmt.allocPrint(p.a, fmt, args);
        try p.sink.emit(.{
            .code = null,
            .severity = .@"error",
            .message = msg,
            .spans = &.{.{ .span = .{ .file = p.file, .start = span.start, .end = span.end }, .primary = true }},
        });
    }

    /// The string value of required key `key`, or null after reporting.
    fn string(p: *Parser, t: *const toml.Table, header: toml.Span, key: []const u8) !?*const toml.Value {
        const v = t.get(key) orelse {
            try p.report(header, "`[[package]]` entry is missing `{s}`", .{key});
            return null;
        };
        if (v.data != .string) {
            try p.report(v.span, "`{s}` must be a string", .{key});
            return null;
        }
        return v;
    }

    fn package(p: *Parser, t: *const toml.Table, header: toml.Span) !?Package {
        for (t.entries.keys(), t.entries.values()) |k, e| {
            for ([_][]const u8{ "name", "version", "source", "sha256" }) |known| {
                if (std.mem.eql(u8, k, known)) break;
            } else try p.report(e.key_span, "unknown key `{s}` in `[[package]]`", .{k});
        }
        const name = try p.string(t, header, "name");
        const version = try p.string(t, header, "version");
        const source = try p.string(t, header, "source");
        const sha = try p.string(t, header, "sha256");

        var pkg: Package = undefined;
        var ok = name != null and version != null and source != null and sha != null;
        if (name) |v| pkg.name = try p.a.dupe(u8, v.data.string);
        if (version) |v| {
            if (semver.Version.parse(try p.a.dupe(u8, v.data.string))) |x| pkg.version = x else |_| {
                try p.report(v.span, "`{s}` is not a semver version", .{v.data.string});
                ok = false;
            }
        }
        if (source) |v| {
            if (parseSource(try p.a.dupe(u8, v.data.string))) |s| pkg.source = s else {
                try p.report(v.span, "unknown source `{s}`; expected `registry[+name]`, `git+url#commit` or `path+dir`", .{v.data.string});
                ok = false;
            }
        }
        if (sha) |v| {
            if (parseHash(v.data.string)) |h| pkg.sha256 = h else {
                try p.report(v.span, "`sha256` must be 64 lowercase hex digits", .{});
                ok = false;
            }
            pkg.span = .{ .file = p.file, .start = v.span.start, .end = v.span.end };
        }
        return if (ok) pkg else null;
    }
};

fn parseSource(s: []const u8) ?Source {
    if (std.mem.eql(u8, s, "registry")) return .{ .registry = null };
    if (std.mem.startsWith(u8, s, "registry+") and s.len > "registry+".len) return .{ .registry = s["registry+".len..] };
    if (std.mem.startsWith(u8, s, "path+") and s.len > "path+".len) return .{ .path = s["path+".len..] };
    if (std.mem.startsWith(u8, s, "git+")) {
        const hash = std.mem.lastIndexOfScalar(u8, s, '#') orelse return null;
        if (hash <= "git+".len or hash + 1 == s.len) return null;
        return .{ .git = .{ .url = s["git+".len..hash], .rev = s[hash + 1 ..] } };
    }
    return null;
}

fn parseHash(s: []const u8) ?Hash {
    if (s.len != 64) return null;
    for (s) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return null;
    var h: Hash = undefined;
    _ = std.fmt.hexToBytes(&h, s) catch unreachable;
    return h;
}

fn lessThan(_: void, x: Package, y: Package) bool {
    return switch (std.mem.order(u8, x.name, y.name)) {
        .lt => true,
        .gt => false,
        .eq => x.version.order(y.version) == .lt,
    };
}

/// Writes `packages` as a `pyro.lock`, sorted by (name, version) whatever
/// their order in the slice, so the output depends only on the set.
pub fn write(gpa: std.mem.Allocator, packages: []const Package, w: *std.Io.Writer) (std.Io.Writer.Error || error{OutOfMemory})!void {
    const sorted = try gpa.dupe(Package, packages);
    defer gpa.free(sorted);
    std.mem.sort(Package, sorted, {}, lessThan);
    try w.writeAll("# Generated by pyro (§13.4). Do not edit; `pyro update` regenerates it.\n");
    for (sorted) |p| {
        try w.writeAll("\n[[package]]\nname = ");
        try toml.writeValue(.{ .string = p.name }, w);
        try w.print("\nversion = \"{f}\"\nsource = ", .{versionFmt(p.version)});
        var buf: std.Io.Writer.Allocating = .init(gpa);
        defer buf.deinit();
        switch (p.source) {
            .registry => |r| if (r) |name| try buf.writer.print("registry+{s}", .{name}) else try buf.writer.writeAll("registry"),
            .git => |g| try buf.writer.print("git+{s}#{s}", .{ g.url, g.rev }),
            .path => |d| try buf.writer.print("path+{s}", .{d}),
        }
        try toml.writeValue(.{ .string = buf.written() }, w);
        try w.print("\nsha256 = \"{s}\"\n", .{&std.fmt.bytesToHex(p.sha256, .lower)});
    }
}

/// `write` into a new buffer the caller frees.
pub fn render(gpa: std.mem.Allocator, packages: []const Package) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    write(gpa, packages, &out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn versionFmt(v: semver.Version) std.fmt.Alt(semver.Version, writeVersion) {
    return .{ .data = v };
}

fn writeVersion(v: semver.Version, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("{d}.{d}.{d}", .{ v.major, v.minor, v.patch });
    if (v.pre.len != 0) try w.print("-{s}", .{v.pre});
    if (v.build.len != 0) try w.print("+{s}", .{v.build});
}

/// `--locked`: fails if the lock file would change. `existing` is the current
/// `pyro.lock` text (null if there is none) and `packages` what a build would
/// write. On a difference, reports one error to `sink` (the build then exits 1,
/// §13.8) and returns `error.LockOutdated`.
pub fn checkLocked(gpa: std.mem.Allocator, existing: ?[]const u8, packages: []const Package, sink: *diag.Sink) error{ LockOutdated, OutOfMemory }!void {
    const fresh = try render(gpa, packages);
    defer gpa.free(fresh);
    if (existing) |old| if (std.mem.eql(u8, old, fresh)) return;
    try sink.emit(.{
        .code = null,
        .severity = .@"error",
        .message = if (existing == null) "`pyro.lock` is missing and `--locked` forbids creating it" else "`pyro.lock` needs to be updated but `--locked` forbids changing it",
        .help = &.{"run the command without `--locked` to update `pyro.lock`"},
    });
    return error.LockOutdated;
}

/// Checks `actual`, the hash of the fetched or cached source of `pkg`, against
/// the lock. On mismatch, reports E0911 at the entry's `sha256` and returns false.
pub fn verify(pkg: *const Package, actual: Hash, sink: *diag.Sink) error{OutOfMemory}!bool {
    if (std.mem.eql(u8, &pkg.sha256, &actual)) return true;
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "source of `{s}` {f} does not match `pyro.lock`: expected sha256 {s}, found {s}", .{
        pkg.name, versionFmt(pkg.version), &std.fmt.bytesToHex(pkg.sha256, .lower), &std.fmt.bytesToHex(actual, .lower),
    }) catch "source does not match the hash recorded in `pyro.lock`";
    const span: []const diag.Label = if (pkg.span) |s| &.{.{ .span = s, .primary = true }} else &.{};
    try sink.emit(.{
        .code = .E0911,
        .severity = .of(.E0911),
        .message = msg,
        .spans = span,
        .help = &.{"the cached or fetched source was modified; delete it from the cache to refetch, or run `pyro update` if the change is intended"},
    });
    return false;
}

/// SHA-256 of the regular files under `dir` (opened with `.iterate = true`):
/// for each file in byte order of its `/`-separated relative path, the path,
/// a NUL byte, the content length as u64 little-endian, and the content.
/// The hash depends only on paths and contents, not on directory order or
/// timestamps.
/// shortcut: symlinks, empty directories and permission bits are not hashed;
/// include them if sources may carry them meaningfully.
pub fn hashTree(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !Hash {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var paths: std.ArrayList([]u8) = .empty;
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |e| {
        if (e.kind != .file) continue;
        const p = try a.dupe(u8, e.path);
        std.mem.replaceScalar(u8, p, std.fs.path.sep, '/');
        try paths.append(a, p);
    }
    std.mem.sort([]u8, paths.items, {}, struct {
        fn lt(_: void, x: []u8, y: []u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);
    var h: std.crypto.hash.sha2.Sha256 = .init(.{});
    for (paths.items) |p| {
        const content = try dir.readFileAlloc(io, p, gpa, .unlimited);
        defer gpa.free(content);
        h.update(p);
        h.update(&.{0});
        h.update(std.mem.asBytes(&std.mem.nativeToLittle(u64, content.len)));
        h.update(content);
    }
    return h.finalResult();
}

/// Resolves like `resolve.resolve`, but keeps each version recorded in `lock`
/// while the requirements still allow it, so an unchanged manifest reproduces
/// the lock even after the index gained newer releases (only `pyro update`
/// re-resolves). With `lock` null, or when the locked versions no longer
/// satisfy the requirements, resolves from scratch against `index`.
/// shortcut: one stale locked version drops every preference; keep the
/// unaffected ones (per-package fallback) if `pyro add` churns unrelated entries.
pub fn resolveLocked(gpa: std.mem.Allocator, index: resolve.Index, lock: ?*const Lock, root_name: []const u8, root: *const resolve.Release, sink: *diag.Sink) resolve.Error!resolve.Resolution {
    if (lock) |l| {
        var pref: Preferred = .{ .base = index, .lock = l, .arena = .init(gpa) };
        defer pref.arena.deinit();
        var scratch: diag.Sink = .init(gpa, sink.io);
        defer scratch.deinit();
        // The resolution copies names and versions out of the index's
        // releases, so it outlives `pref`'s filtered release arrays.
        if (resolve.resolve(gpa, pref.index(), root_name, root, &scratch)) |res| return res else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unresolvable => {},
        }
    }
    return resolve.resolve(gpa, index, root_name, root, sink);
}

/// An index that hides, on each compatibility line holding a locked version,
/// every other release of that package.
const Preferred = struct {
    base: resolve.Index,
    lock: *const Lock,
    arena: std.heap.ArenaAllocator,
    filtered: std.StringHashMapUnmanaged([]const resolve.Release) = .empty,

    fn index(p: *Preferred) resolve.Index {
        return .{ .ctx = p, .releasesFn = releases };
    }

    fn releases(ctx: *const anyopaque, name: []const u8) []const resolve.Release {
        const p: *Preferred = @ptrCast(@alignCast(@constCast(ctx)));
        const all = p.base.releases(name);
        // The resolver compares release pointers, so each name must map to one slice.
        const a = p.arena.allocator();
        const slot = p.filtered.getOrPut(a, name) catch return all;
        if (slot.found_existing) return slot.value_ptr.*;
        var kept: std.ArrayList(resolve.Release) = .empty;
        for (all) |r| {
            if (!p.keeps(name, r.version)) continue;
            kept.append(a, r) catch {
                slot.value_ptr.* = all;
                return all;
            };
        }
        slot.value_ptr.* = kept.items;
        return kept.items;
    }

    fn keeps(p: *const Preferred, name: []const u8, v: semver.Version) bool {
        var line_locked = false;
        for (p.lock.packages) |l| {
            if (!std.mem.eql(u8, l.name, name)) continue;
            if (l.version.order(v) == .eq) return true;
            line_locked = line_locked or std.meta.eql(l.version.compatLine(), v.compatLine());
        }
        return !line_locked;
    }
};

// --- tests ---------------------------------------------------------------------

const testing = std.testing;
const test_file: diag.FileId = @fromBackingInt(@intCast(3));

fn ver(text: []const u8) semver.Version {
    return semver.Version.parse(text) catch unreachable;
}

fn hashOf(byte: u8) Hash {
    return @splat(byte);
}

const sample = [_]Package{
    .{ .name = "util", .version = ver("1.0.0"), .source = .{ .path = "../util" }, .sha256 = hashOf(0xab) },
    .{ .name = "gfx", .version = ver("2.0.1"), .source = .{ .git = .{ .url = "https://example.com/gfx.git", .rev = "0123abcd" } }, .sha256 = hashOf(0x01) },
    .{ .name = "math", .version = ver("1.9.0-rc.1+b7"), .source = .{ .registry = null }, .sha256 = hashOf(0x10) },
    .{ .name = "math", .version = ver("0.4.2"), .source = .{ .registry = "internal" }, .sha256 = hashOf(0xff) },
};

test "round-trip: render, parse, render is byte-identical and sorted" {
    const text = try render(testing.allocator, &sample);
    defer testing.allocator.free(text);
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    var lock = try parse(testing.allocator, text, test_file, &sink);
    defer lock.deinit();
    try testing.expect(!sink.hasErrors());

    try testing.expectEqual(4, lock.packages.len);
    try testing.expectEqualStrings("gfx", lock.packages[0].name);
    try testing.expectEqualStrings("0123abcd", lock.packages[0].source.git.rev);
    try testing.expectEqual(ver("0.4.2"), lock.packages[1].version);
    try testing.expectEqualStrings("internal", lock.packages[1].source.registry.?);
    try testing.expectEqualStrings("b7", lock.packages[2].version.build);
    try testing.expectEqual(null, lock.packages[2].source.registry);
    try testing.expectEqualStrings("../util", lock.find("util", ver("1.0.0")).?.source.path);
    try testing.expectEqual(hashOf(0xab), lock.find("util", ver("1.0.0")).?.sha256);

    const again = try render(testing.allocator, lock.packages);
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(text, again);
}

test "stable output: input order does not matter; exact format" {
    const reversed = [_]Package{ sample[3], sample[2], sample[1], sample[0] };
    const a = try render(testing.allocator, &sample);
    defer testing.allocator.free(a);
    const b = try render(testing.allocator, &reversed);
    defer testing.allocator.free(b);
    try testing.expectEqualStrings(a, b);

    const one = try render(testing.allocator, sample[0..1]);
    defer testing.allocator.free(one);
    try testing.expectEqualStrings(
        \\# Generated by pyro (§13.4). Do not edit; `pyro update` regenerates it.
        \\
        \\[[package]]
        \\name = "util"
        \\version = "1.0.0"
        \\source = "path+../util"
        \\sha256 = "abababababababababababababababababababababababababababababababab"
        \\
    , one);
}

/// Every diagnostic has `code`, and each needle occurs in exactly one message.
fn expectMessages(sink: *diag.Sink, code: ?diag.DiagCode, needles: []const []const u8) !void {
    const ds = sink.finish();
    try testing.expectEqual(needles.len, ds.len);
    for (ds) |d| try testing.expectEqual(code, d.code);
    for (needles) |n| {
        var hits: usize = 0;
        for (ds) |d| hits += @intFromBool(std.mem.indexOf(u8, d.message, n) != null);
        if (hits != 1) {
            std.debug.print("`{s}` occurs in {d} messages\n", .{ n, hits });
            return error.TestUnexpectedResult;
        }
    }
}

test "tampered cache is E0911 at the lock entry" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "src/inner");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "pyro.toml", .data = "[package]\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/lib.pr", .data = "pub fn answer() -> u32 { 42 }\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/inner/x.pr", .data = "" });
    const good = try hashTree(testing.allocator, testing.io, tmp.dir);
    try testing.expectEqual(good, try hashTree(testing.allocator, testing.io, tmp.dir));

    const text = try render(testing.allocator, &.{.{ .name = "util", .version = ver("1.0.0"), .source = .{ .path = "../util" }, .sha256 = good }});
    defer testing.allocator.free(text);
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    var lock = try parse(testing.allocator, text, test_file, &sink);
    defer lock.deinit();
    const entry = lock.find("util", ver("1.0.0")).?;
    try testing.expect(try verify(entry, good, &sink));

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/lib.pr", .data = "pub fn answer() -> u32 { 43 }\n" });
    try testing.expect(!try verify(entry, try hashTree(testing.allocator, testing.io, tmp.dir), &sink));
    // A moved file changes the hash too, even with identical content.
    try tmp.dir.rename("src/inner/x.pr", tmp.dir, "src/inner/y.pr", testing.io);
    try testing.expect(!std.mem.eql(u8, &good, &try hashTree(testing.allocator, testing.io, tmp.dir)));

    try expectMessages(&sink, .E0911, &.{"source of `util` 1.0.0 does not match `pyro.lock`"});
    const span = sink.finish()[0].primarySpan().?;
    try testing.expectEqualStrings(&std.fmt.bytesToHex(good, .lower), text[span.start + 1 .. span.end - 1]);
}

test "the E0911 conformance fixture parses and its hash mismatches" {
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    var lock = try parse(testing.allocator,
        \\# Conformance fixture: the util hash below is deliberately wrong (E0911).
        \\
        \\[[package]]
        \\name = "util"
        \\version = "1.0.0"
        \\source = "path+../util"
        \\sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
        \\
    , test_file, &sink);
    defer lock.deinit();
    try testing.expect(!try verify(&lock.packages[0], hashOf(1), &sink));
    try expectMessages(&sink, .E0911, &.{"expected sha256 0000"});

    var empty = try parse(testing.allocator, "# no dependencies\n", test_file, &sink);
    defer empty.deinit();
    try testing.expectEqual(0, empty.packages.len);
}

test "malformed lock files report every problem" {
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    try testing.expectError(error.InvalidLock, parse(testing.allocator,
        \\extra = 1
        \\[[package]]
        \\name = "a"
        \\version = "1.x"
        \\source = "ftp+x"
        \\sha256 = "AB"
        \\color = "red"
        \\[[package]]
        \\name = "b"
        \\[[package]]
        \\name = "c"
        \\version = "1.0.0"
        \\source = "registry"
        \\sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
        \\[[package]]
        \\name = "c"
        \\version = "1.0.0"
        \\source = "registry"
        \\sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
        \\
    , test_file, &sink));
    try expectMessages(&sink, null, &.{
        "unknown key `extra`",     "is not a semver version", "unknown source `ftp+x`",
        "64 lowercase hex digits", "unknown key `color`",     "missing `version`",
        "missing `source`",        "missing `sha256`",        "`c` 1.0.0 is locked twice",
    });

    var sink2: diag.Sink = .init(testing.allocator, testing.io);
    defer sink2.deinit();
    try testing.expectError(error.InvalidLock, parse(testing.allocator, "[[package]\n", test_file, &sink2));
    try expectMessages(&sink2, null, &.{"not valid TOML"});
}

/// An index over a fixed table of `name` -> releases.
const TestIndex = struct {
    entries: []const struct { []const u8, []const resolve.Release },

    fn releases(ctx: *const anyopaque, name: []const u8) []const resolve.Release {
        const self: *const TestIndex = @ptrCast(@alignCast(ctx));
        for (self.entries) |e| if (std.mem.eql(u8, e[0], name)) return e[1];
        return &.{};
    }

    fn index(self: *const TestIndex) resolve.Index {
        return .{ .ctx = self, .releasesFn = releases };
    }
};

fn dependsOn(name: []const u8, requirement: []const u8) resolve.Dep {
    return .{ .name = name, .requirement = semver.Requirement.parse(requirement) catch unreachable };
}

/// Lock entries for every non-root package of `res`, hashed from the name.
fn lockOf(res: resolve.Resolution, buf: []Package) []Package {
    var n: usize = 0;
    for (res.packages, 0..) |p, i| {
        if (i == res.root) continue;
        buf[n] = .{ .name = p.name, .version = p.version, .source = .{ .registry = null }, .sha256 = hashOf(@truncate(p.name.len)) };
        n += 1;
    }
    return buf[0..n];
}

test "--locked passes for an unchanged manifest and fails when it changed" {
    const old_ix: TestIndex = .{ .entries = &.{
        .{ "base", &.{ .{ .version = ver("1.2.0") }, .{ .version = ver("2.0.0") } } },
        .{ "log", &.{.{ .version = ver("0.3.1") }} },
    } };
    const root: resolve.Release = .{ .version = ver("0.1.0"), .deps = &.{dependsOn("base", "1")} };
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    var buf: [4]Package = undefined;

    var first = try resolveLocked(testing.allocator, old_ix.index(), null, "app", &root, &sink);
    defer first.deinit();
    const committed = try render(testing.allocator, lockOf(first, &buf));
    defer testing.allocator.free(committed);
    var lock = try parse(testing.allocator, committed, test_file, &sink);
    defer lock.deinit();

    // The registry gained base 1.5.0; the unchanged manifest keeps the locked 1.2.0.
    const new_ix: TestIndex = .{ .entries = &.{
        .{ "base", &.{ .{ .version = ver("1.2.0") }, .{ .version = ver("1.5.0") }, .{ .version = ver("2.0.0") } } },
        .{ "log", &.{.{ .version = ver("0.3.1") }} },
    } };
    var same = try resolveLocked(testing.allocator, new_ix.index(), &lock, "app", &root, &sink);
    defer same.deinit();
    try checkLocked(testing.allocator, committed, lockOf(same, &buf), &sink);
    try testing.expect(!sink.hasErrors());

    // A requirement the locked version no longer meets re-resolves it.
    const bumped: resolve.Release = .{ .version = ver("0.1.0"), .deps = &.{dependsOn("base", "^1.3")} };
    var moved = try resolveLocked(testing.allocator, new_ix.index(), &lock, "app", &bumped, &sink);
    defer moved.deinit();
    try testing.expectEqual(ver("1.5.0"), moved.packages[1].version);

    // The manifest gained a dependency: the lock would change, so `--locked` fails (exit 1).
    const changed: resolve.Release = .{ .version = ver("0.1.0"), .deps = &.{ dependsOn("base", "1"), dependsOn("log", "0.3") } };
    var grown = try resolveLocked(testing.allocator, new_ix.index(), &lock, "app", &changed, &sink);
    defer grown.deinit();
    try testing.expectError(error.LockOutdated, checkLocked(testing.allocator, committed, lockOf(grown, &buf), &sink));
    try testing.expectError(error.LockOutdated, checkLocked(testing.allocator, null, lockOf(grown, &buf), &sink));
    try testing.expect(sink.hasErrors());
    try expectMessages(&sink, null, &.{ "needs to be updated", "is missing" });
}
