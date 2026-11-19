//! Source fetching (§13.4): registry archives, git and path dependencies into
//! the content-addressed cache (`cache.zig`). The registry protocol, archive
//! format and git handling are recorded in `docs/registry.md`.
//!
//! `Fetcher.fetch` gives the directory holding a package's source and its
//! `lock.hashTree` hash. A request whose expected hash is already cached only
//! reads (and re-verifies, E0911) the cache entry; with `offline` set, a cache
//! miss is an error and no remote is touched. `fetchAll` runs requests on a
//! `Pool`. Every failure is reported to the sink and returned as `FetchFailed`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const semver = @import("semver.zig");
const lock = @import("lock.zig");
const resolve = @import("resolve.zig");
const manifest = @import("manifest.zig");
const toml = @import("../toml/toml.zig");
const diag = @import("../diag/diag.zig");
const Pool = @import("../base/Pool.zig");
const Cache = @import("cache.zig").Cache;
const cache = @import("cache.zig");

/// A configured registry: `name` null is the default registry.
pub const Registry = struct {
    name: ?[]const u8 = null,
    /// Base URL; stage 0 supports `file://` only.
    url: []const u8,
};

/// One package source to fetch.
pub const Request = struct {
    name: []const u8,
    /// For registry sources: the release to fetch. Unused otherwise.
    version: semver.Version = .{ .major = 0, .minor = 0, .patch = 0 },
    /// For git sources, `rev` is anything `git rev-parse` accepts (see `gitRev`).
    source: lock.Source,
    /// Expected tree hash, from `pyro.lock`. Null: registry requests take it
    /// from the index; git requests accept whatever the commit holds.
    sha256: ?lock.Hash = null,
    /// Where diagnostics about this request point (the lock entry).
    span: ?diag.Span = null,

    /// The request reproducing lock entry `p`.
    pub fn fromLock(p: *const lock.Package) Request {
        return .{ .name = p.name, .version = p.version, .source = p.source, .sha256 = p.sha256, .span = p.span };
    }
};

/// The `rev` to fetch for a manifest git reference, owned by the caller.
pub fn gitRev(gpa: Allocator, ref: manifest.GitRef) error{OutOfMemory}![]u8 {
    return switch (ref) {
        .default => gpa.dupe(u8, "HEAD"),
        .tag => |t| std.mem.concat(gpa, u8, &.{ "refs/tags/", t }),
        .branch => |b| std.mem.concat(gpa, u8, &.{ "refs/heads/", b }),
        .rev => |r| gpa.dupe(u8, r),
    };
}

/// A fetched source. Free with `deinit`.
pub const Fetched = struct {
    /// The source directory: a cache entry, or a path dependency in place.
    dir: []u8,
    sha256: lock.Hash,
    /// Git sources: the resolved commit, for `pyro.lock`.
    rev: ?[]u8 = null,

    pub fn deinit(x: *Fetched, gpa: Allocator) void {
        gpa.free(x.dir);
        if (x.rev) |r| gpa.free(r);
        x.* = undefined;
    }
};

pub const Error = error{ FetchFailed, OutOfMemory };

/// One release in a registry index.
pub const IndexRelease = struct {
    release: resolve.Release,
    sha256: lock.Hash,
};

/// A registry index file. Strings point into `arena`.
pub const Index = struct {
    arena: std.heap.ArenaAllocator,
    releases: []const IndexRelease,

    pub fn deinit(ix: *Index) void {
        ix.arena.deinit();
        ix.* = undefined;
    }
};

/// Parses registry index `text` (format in `docs/registry.md`) into `a`. On
/// `error.InvalidIndex`, `problem` describes the first problem.
pub fn parseIndex(a: Allocator, text: []const u8, problem: *[]const u8) error{ InvalidIndex, OutOfMemory }![]const IndexRelease {
    var tdiag: toml.Diagnostic = undefined;
    var doc = toml.parse(a, text, &tdiag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidToml => return bad(problem, try std.fmt.allocPrint(a, "not valid TOML: {s}", .{tdiag.message})),
    };
    defer doc.deinit();
    var out: std.ArrayList(IndexRelease) = .empty;
    for (doc.root.entries.keys(), doc.root.entries.values()) |k, e| {
        if (!std.mem.eql(u8, k, "release") or e.value.data != .array or e.value.data.array.kind != .tables)
            return bad(problem, try std.fmt.allocPrint(a, "unexpected key `{s}`; expected `[[release]]` tables", .{k}));
        for (e.value.data.array.items.items) |item| {
            const t = item.data.table;
            for (t.entries.keys()) |key| {
                for ([_][]const u8{ "version", "sha256", "deps" }) |known| {
                    if (std.mem.eql(u8, key, known)) break;
                } else return bad(problem, try std.fmt.allocPrint(a, "unknown key `{s}` in `[[release]]`", .{key}));
            }
            const v = t.get("version") orelse return bad(problem, "`[[release]]` is missing `version`");
            const h = t.get("sha256") orelse return bad(problem, "`[[release]]` is missing `sha256`");
            if (v.data != .string or h.data != .string) return bad(problem, "`version` and `sha256` must be strings");
            const version = semver.Version.parse(try a.dupe(u8, v.data.string)) catch
                return bad(problem, try std.fmt.allocPrint(a, "`{s}` is not a semver version", .{v.data.string}));
            const sha = lock.parseHash(h.data.string) orelse return bad(problem, "`sha256` must be 64 lowercase hex digits");
            var deps: std.ArrayList(resolve.Dep) = .empty;
            if (t.get("deps")) |d| {
                if (d.data != .table) return bad(problem, "`deps` must be a table of requirements");
                for (d.data.table.entries.keys(), d.data.table.entries.values()) |dn, de| {
                    if (!manifest.isValidName(dn) or de.value.data != .string)
                        return bad(problem, try std.fmt.allocPrint(a, "bad dependency `{s}`", .{dn}));
                    const req = semver.Requirement.parse(try a.dupe(u8, de.value.data.string)) catch
                        return bad(problem, try std.fmt.allocPrint(a, "bad requirement for `{s}`", .{dn}));
                    try deps.append(a, .{ .name = try a.dupe(u8, dn), .requirement = req });
                }
            }
            try out.append(a, .{ .release = .{ .version = version, .deps = deps.items }, .sha256 = sha });
        }
    }
    return out.items;
}

fn bad(problem: *[]const u8, msg: []const u8) error{InvalidIndex} {
    problem.* = msg;
    return error.InvalidIndex;
}

/// Fetches sources into `cache`. `gpa` must be thread-safe for `fetchAll`.
pub const Fetcher = struct {
    gpa: Allocator,
    io: Io,
    cache: *const Cache,
    sink: *diag.Sink,
    registries: []const Registry = &.{},
    /// Directory path dependencies are relative to (the root manifest's).
    root_dir: []const u8 = ".",
    /// `--offline`: use only the cache.
    offline: bool = false,
    /// shortcut: serializes git commands so parallel fetches never race on one
    /// mirror; lock per mirror if many git dependencies make this a bottleneck.
    git_mutex: Io.Mutex = .init,

    /// Fetches `req`; see the module documentation.
    pub fn fetch(f: *Fetcher, req: Request) Error!Fetched {
        return switch (req.source) {
            .path => |p| f.fetchPath(req, p),
            .registry => |r| f.fetchRegistry(req, r),
            .git => |g| f.fetchGit(req, g.url, g.rev),
        };
    }

    /// Fetches every request in parallel on `pool`; `out[i]` is the result of `reqs[i]`.
    pub fn fetchAll(f: *Fetcher, pool: *Pool, reqs: []const Request, out: []Error!Fetched) void {
        std.debug.assert(out.len == reqs.len);
        const Job = struct {
            f: *Fetcher,
            reqs: []const Request,
            out: []Error!Fetched,
            fn run(j: @This(), _: u32, i: usize) void {
                j.out[i] = j.f.fetch(j.reqs[i]);
            }
        };
        pool.run(reqs.len, Job{ .f = f, .reqs = reqs, .out = out }, Job.run);
    }

    /// The index of package `name` in registry `registry` (null: default),
    /// read from the registry (and copied to the cache) or, offline, from the
    /// cached copy. An unknown package has no releases.
    pub fn index(f: *Fetcher, registry: ?[]const u8, name: []const u8, span: ?diag.Span) Error!Index {
        const req: Request = .{ .name = name, .source = .{ .registry = registry }, .span = span };
        const reg = try f.registryFor(req, registry);
        if (!manifest.isValidName(name)) return f.fail(req, "`{s}` is not a valid package name", .{name});
        const key = cache.urlKey(reg.url);
        const copy = try std.mem.concat(f.gpa, u8, &.{ "index/", &key, "/", name, ".toml" });
        defer f.gpa.free(copy);
        const cached = f.cache.dir.readFileAlloc(f.io, copy, f.gpa, .limited(max_bytes)) catch null;
        defer if (cached) |c| f.gpa.free(c);

        var text: []const u8 = undefined;
        var owned: ?[]u8 = null;
        defer if (owned) |o| f.gpa.free(o);
        if (f.offline) {
            text = cached orelse return f.fail(req, "the registry index of `{s}` is not in the package cache and `--offline` forbids fetching it", .{name});
        } else {
            const rel = try std.mem.concat(f.gpa, u8, &.{ "index/", name, ".toml" });
            defer f.gpa.free(rel);
            owned = f.readRemote(reg.url, rel) catch |err| switch (err) {
                error.FileNotFound => try f.gpa.dupe(u8, ""),
                error.OutOfMemory => return error.OutOfMemory,
                else => return f.fail(req, "cannot read the registry index of `{s}` from `{s}`: {t}", .{ name, reg.url, err }),
            };
            text = owned.?;
            if (cached == null or !std.mem.eql(u8, cached.?, text)) {
                f.cache.dir.createDirPath(f.io, std.fs.path.dirname(copy).?) catch {};
                f.cache.dir.writeFile(f.io, .{ .sub_path = copy, .data = text }) catch |err|
                    return f.fail(req, "cannot write the package cache: {t}", .{err});
            }
        }
        var arena: std.heap.ArenaAllocator = .init(f.gpa);
        errdefer arena.deinit();
        var problem: []const u8 = "";
        const releases = parseIndex(arena.allocator(), text, &problem) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidIndex => return f.fail(req, "the registry index of `{s}` is invalid: {s}", .{ name, problem }),
        };
        return .{ .arena = arena, .releases = releases };
    }

    const max_bytes = 1 << 30;

    fn fetchPath(f: *Fetcher, req: Request, rel: []const u8) Error!Fetched {
        const dir = try std.fs.path.join(f.gpa, &.{ f.root_dir, rel });
        errdefer f.gpa.free(dir);
        var d = Io.Dir.cwd().openDir(f.io, dir, .{ .iterate = true }) catch |err|
            return f.fail(req, "cannot open path dependency `{s}` at `{s}`: {t}", .{ req.name, dir, err });
        defer d.close(f.io);
        const h = lock.hashTree(f.gpa, f.io, d) catch |err| return f.fail(req, "cannot read `{s}`: {t}", .{ dir, err });
        return .{ .dir = dir, .sha256 = h };
    }

    fn fetchRegistry(f: *Fetcher, req: Request, registry: ?[]const u8) Error!Fetched {
        if (!manifest.isValidName(req.name)) return f.fail(req, "`{s}` is not a valid package name", .{req.name});
        const expected = req.sha256 orelse blk: {
            var ix = try f.index(registry, req.name, req.span);
            defer ix.deinit();
            for (ix.releases) |r| if (r.release.version.order(req.version) == .eq) break :blk r.sha256;
            return f.fail(req, "the registry has no `{s}` {f}", .{ req.name, lock.versionFmt(req.version) });
        };
        if (f.cache.has(f.io, expected)) return f.fromCache(req, expected, null);
        if (f.offline) return f.offlineMiss(req);

        const reg = try f.registryFor(req, registry);
        const rel = try std.fmt.allocPrint(f.gpa, "archives/{s}/{s}-{f}.tar.gz", .{ req.name, req.name, lock.versionFmt(req.version) });
        defer f.gpa.free(rel);
        const bytes = f.readRemote(reg.url, rel) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return f.fail(req, "cannot download `{s}` from `{s}`: {t}", .{ rel, reg.url, err }),
        };
        defer f.gpa.free(bytes);
        var in: Io.Reader = .fixed(bytes);
        const window = try f.gpa.alloc(u8, std.compress.flate.max_window_len);
        defer f.gpa.free(window);
        var gz: std.compress.flate.Decompress = .init(&in, .gzip, window);
        return f.installFrom(req, &gz.reader, expected, null);
    }

    fn fetchGit(f: *Fetcher, req: Request, url: []const u8, rev: []const u8) Error!Fetched {
        if (req.sha256) |h| if (f.cache.has(f.io, h)) return f.fromCache(req, h, try f.gpa.dupe(u8, rev));
        if (rev.len == 0 or rev[0] == '-') return f.fail(req, "invalid git revision `{s}`", .{rev});

        f.git_mutex.lockUncancelable(f.io);
        var locked = true;
        defer if (locked) f.git_mutex.unlock(f.io);
        const mirror = try f.openMirror(req, url);
        defer f.gpa.free(mirror.path);
        const commit = try f.resolveRev(req, mirror, url, rev);
        errdefer f.gpa.free(commit);
        const tar = try f.git(req, mirror.path, &.{ "archive", "--format=tar", commit });
        defer f.gpa.free(tar);
        f.git_mutex.unlock(f.io);
        locked = false;

        var in: Io.Reader = .fixed(tar);
        return f.installFrom(req, &in, req.sha256, commit);
    }

    /// Extracts tar stream `r` into staging, checks its hash against
    /// `expected` (if any) and installs it.
    fn installFrom(f: *Fetcher, req: Request, r: *Io.Reader, expected: ?lock.Hash, rev: ?[]u8) Error!Fetched {
        var s = f.cache.stage(f.io) catch |err| return f.fail(req, "cannot write the package cache: {t}", .{err});
        var staged = true;
        defer if (staged) f.cache.discard(f.io, &s);
        cache.extractTar(f.io, s.dir, r) catch |err|
            return f.fail(req, "cannot unpack the source of {f}: {t}", .{ describe(req), err });
        const h = lock.hashTree(f.gpa, f.io, s.dir) catch |err|
            return f.fail(req, "cannot read the unpacked source of {f}: {t}", .{ describe(req), err });
        if (expected) |e| if (!std.mem.eql(u8, &e, &h)) {
            if (req.sha256 != null) {
                _ = try lock.verify(&f.lockEntry(req, e), h, f.sink);
                return error.FetchFailed;
            }
            return f.fail(req, "the archive of {f} does not match the registry index: expected sha256 {s}, found {s}", .{
                describe(req), &std.fmt.bytesToHex(e, .lower), &std.fmt.bytesToHex(h, .lower),
            });
        };
        staged = false;
        const dir = f.cache.install(f.gpa, f.io, &s, h) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return f.fail(req, "cannot write the package cache: {t}", .{err}),
        };
        return .{ .dir = dir, .sha256 = h, .rev = rev };
    }

    /// A cache hit: re-hashes the entry (reads only) and reports E0911 if it
    /// was modified.
    fn fromCache(f: *Fetcher, req: Request, h: lock.Hash, rev: ?[]u8) Error!Fetched {
        errdefer if (rev) |r| f.gpa.free(r);
        const dir = try f.cache.srcPath(f.gpa, h);
        errdefer f.gpa.free(dir);
        var d = Io.Dir.cwd().openDir(f.io, dir, .{ .iterate = true }) catch |err| return f.fail(req, "cannot open `{s}`: {t}", .{ dir, err });
        defer d.close(f.io);
        const actual = lock.hashTree(f.gpa, f.io, d) catch |err| return f.fail(req, "cannot read `{s}`: {t}", .{ dir, err });
        if (!try lock.verify(&f.lockEntry(req, h), actual, f.sink)) return error.FetchFailed;
        return .{ .dir = dir, .sha256 = h, .rev = rev };
    }

    fn lockEntry(_: *const Fetcher, req: Request, h: lock.Hash) lock.Package {
        return .{ .name = req.name, .version = req.version, .source = req.source, .sha256 = h, .span = req.span };
    }

    const Mirror = struct { path: []u8, fresh: bool };

    /// The bare mirror of `url`, cloned on first use.
    fn openMirror(f: *Fetcher, req: Request, url: []const u8) Error!Mirror {
        const name = cache.urlKey(url) ++ ".git".*;
        const path = try f.cache.path(f.gpa, &.{ "git", &name });
        errdefer f.gpa.free(path);
        if (Io.Dir.cwd().access(f.io, path, .{})) |_| return .{ .path = path, .fresh = false } else |_| {}
        if (f.offline) return f.offlineMiss(req);

        var s = f.cache.stage(f.io) catch |err| return f.fail(req, "cannot write the package cache: {t}", .{err});
        s.dir.close(f.io);
        const tmp = try f.cache.path(f.gpa, &.{&s.name});
        defer f.gpa.free(tmp);
        const out = f.git(req, f.cache.root, &.{ "clone", "--mirror", "--quiet", "--", url, tmp }) catch |err| {
            f.cache.dir.deleteTree(f.io, &s.name) catch {};
            return err;
        };
        f.gpa.free(out);
        f.cache.dir.rename(&s.name, f.cache.dir, "git/" ++ name, f.io) catch {
            // Another process cloned it first; use theirs.
            f.cache.dir.deleteTree(f.io, &s.name) catch {};
        };
        return .{ .path = path, .fresh = true };
    }

    /// The full commit hash `rev` names, fetching the mirror first unless
    /// `rev` is a commit it already has, it was just cloned, or offline.
    fn resolveRev(f: *Fetcher, req: Request, m: Mirror, url: []const u8, rev: []const u8) Error![]u8 {
        const spec = try std.mem.concat(f.gpa, u8, &.{ rev, "^{commit}" });
        defer f.gpa.free(spec);
        const args: []const []const u8 = &.{ "rev-parse", "--verify", "--quiet", spec };
        const pinned = rev.len == 40 and for (rev) |c| {
            if (!std.ascii.isHex(c)) break false;
        } else true;
        if (pinned) if (try f.gitMaybe(m.path, args)) |out| return f.trimmed(out);
        if (!m.fresh and !f.offline) f.gpa.free(try f.git(req, m.path, &.{ "fetch", "--quiet", "--prune", "origin" }));
        const out = try f.gitMaybe(m.path, args) orelse
            return f.fail(req, "git revision `{s}` not found in `{s}`{s}", .{ rev, url, if (f.offline) " (`--offline` uses only the cached mirror)" else "" });
        return f.trimmed(out);
    }

    /// `out` without its trailing newline; frees `out`.
    fn trimmed(f: *Fetcher, out: []u8) error{OutOfMemory}![]u8 {
        defer f.gpa.free(out);
        return f.gpa.dupe(u8, std.mem.trimEnd(u8, out, "\n"));
    }

    /// Runs `git -C cwd args...`; stdout on success, null on a non-zero exit.
    fn gitMaybe(f: *Fetcher, cwd: []const u8, args: []const []const u8) Error!?[]u8 {
        var stderr: []u8 = &.{};
        defer f.gpa.free(stderr);
        return f.runGit(cwd, args, &stderr) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return null;
        };
    }

    /// Runs `git -C cwd args...` and returns stdout; reports failures.
    fn git(f: *Fetcher, req: Request, cwd: []const u8, args: []const []const u8) Error![]u8 {
        var stderr: []u8 = &.{};
        defer f.gpa.free(stderr);
        return f.runGit(cwd, args, &stderr) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            const why = if (stderr.len != 0) std.mem.trimEnd(u8, stderr, "\n") else @errorName(err);
            return f.fail(req, "`git {s}` failed for {f}: {s}", .{ args[0], describe(req), why });
        };
    }

    fn runGit(f: *Fetcher, cwd: []const u8, args: []const []const u8, stderr: *[]u8) ![]u8 {
        const argv = try std.mem.concat(f.gpa, []const u8, &.{ &.{ "git", "-C", cwd }, args });
        defer f.gpa.free(argv);
        const r = try std.process.run(f.gpa, f.io, .{ .argv = argv });
        stderr.* = r.stderr;
        if (r.term.success()) return r.stdout;
        f.gpa.free(r.stdout);
        return error.GitFailed;
    }

    fn registryFor(f: *Fetcher, req: Request, name: ?[]const u8) Error!Registry {
        for (f.registries) |r| {
            if (r.name == null and name == null) return r;
            if (r.name != null and name != null and std.mem.eql(u8, r.name.?, name.?)) return r;
        }
        return f.fail(req, "registry `{s}` is not configured", .{name orelse "default"});
    }

    /// Reads `rel` under registry base `url`.
    /// shortcut: `file://` only; add an HTTP GET here when registries go online.
    fn readRemote(f: *Fetcher, url: []const u8, rel: []const u8) ![]u8 {
        const prefix = "file://";
        if (!std.mem.startsWith(u8, url, prefix)) return error.UnsupportedRegistryUrl;
        const path = try std.fs.path.join(f.gpa, &.{ url[prefix.len..], rel });
        defer f.gpa.free(path);
        return Io.Dir.cwd().readFileAlloc(f.io, path, f.gpa, .limited(max_bytes));
    }

    fn offlineMiss(f: *Fetcher, req: Request) Error {
        return f.fail(req, "{f} is not in the package cache and `--offline` forbids fetching it", .{describe(req)});
    }

    /// Reports an error about `req` and returns `error.FetchFailed`.
    fn fail(f: *Fetcher, req: Request, comptime fmt: []const u8, args: anytype) Error {
        const msg = std.fmt.allocPrint(f.gpa, fmt, args) catch return error.OutOfMemory;
        defer f.gpa.free(msg);
        const spans: []const diag.Label = if (req.span) |s| &.{.{ .span = s, .primary = true }} else &.{};
        f.sink.emit(.{ .code = null, .severity = .@"error", .message = msg, .spans = spans }) catch return error.OutOfMemory;
        return error.FetchFailed;
    }
};

fn describe(req: Request) std.fmt.Alt(Request, writeDesc) {
    return .{ .data = req };
}

fn writeDesc(req: Request, w: *Io.Writer) Io.Writer.Error!void {
    switch (req.source) {
        .registry => try w.print("`{s}` {f}", .{ req.name, lock.versionFmt(req.version) }),
        .git => |g| try w.print("`{s}` (git `{s}` at `{s}`)", .{ req.name, g.url, g.rev }),
        .path => |p| try w.print("`{s}` (path `{s}`)", .{ req.name, p }),
    }
}

// --- tests ---------------------------------------------------------------------

const testing = std.testing;
const gpa_t = testing.allocator;
const io_t = testing.io;

fn ver(text: []const u8) semver.Version {
    return semver.Version.parse(text) catch unreachable;
}

fn run(cwd: []const u8, argv: []const []const u8) ![]u8 {
    const r = try std.process.run(gpa_t, io_t, .{ .argv = argv, .cwd = .{ .path = cwd } });
    defer gpa_t.free(r.stderr);
    if (!r.term.success()) {
        std.debug.print("{s}: {s}\n", .{ argv[0], r.stderr });
        gpa_t.free(r.stdout);
        return error.CommandFailed;
    }
    return r.stdout;
}

fn sh(cwd: []const u8, argv: []const []const u8) !void {
    gpa_t.free(try run(cwd, argv));
}

/// A temporary directory holding a file:// registry with `util` 1.0.0, a git
/// repository `gfx` tagged `v1`, a path package `local`, and an empty cache.
const Fixture = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    reg_url: []u8,
    git_url: []u8,
    util_hash: lock.Hash,
    cache: Cache,

    fn init(f: *Fixture) !void {
        f.tmp = testing.tmpDir(.{});
        errdefer f.tmp.cleanup();
        const d = f.tmp.dir;
        f.root = try d.realPathFileAlloc(io_t, ".", gpa_t);
        const files = [_][2][]const u8{
            .{ "util/pyro.toml", "[package]\nname = \"util\"\nversion = \"1.0.0\"\nedition = \"2026\"\n" },
            .{ "util/src/lib.pr", "pub fn answer() -> u32 { 42 }\n" },
            .{ "gfx/pyro.toml", "[package]\nname = \"gfx\"\nversion = \"2.0.1\"\nedition = \"2026\"\n" },
            .{ "gfx/src/lib.pr", "pub fn draw() {}\n" },
            .{ "local/pyro.toml", "[package]\nname = \"local\"\nversion = \"0.1.0\"\nedition = \"2026\"\n" },
            .{ "local/src/lib.pr", "pub fn here() {}\n" },
        };
        for (files) |e| {
            try d.createDirPath(io_t, std.fs.path.dirname(e[0]).?);
            try d.writeFile(io_t, .{ .sub_path = e[0], .data = e[1] });
        }
        var util = try d.openDir(io_t, "util", .{ .iterate = true });
        f.util_hash = try lock.hashTree(gpa_t, io_t, util);
        util.close(io_t);

        try d.createDirPath(io_t, "reg/archives/util");
        try d.createDirPath(io_t, "reg/index");
        try sh(f.root, &.{ "tar", "-czf", "reg/archives/util/util-1.0.0.tar.gz", "-C", "util", "." });
        const index = try std.fmt.allocPrint(gpa_t, "[[release]]\nversion = \"1.0.0\"\nsha256 = \"{s}\"\ndeps = {{ base = \"^1.0\" }}\n", .{&std.fmt.bytesToHex(f.util_hash, .lower)});
        defer gpa_t.free(index);
        try d.writeFile(io_t, .{ .sub_path = "reg/index/util.toml", .data = index });
        f.reg_url = try std.mem.concat(gpa_t, u8, &.{ "file://", f.root, "/reg" });

        const g = try std.fs.path.join(gpa_t, &.{ f.root, "gfx" });
        defer gpa_t.free(g);
        try sh(g, &.{ "git", "init", "--quiet" });
        try sh(g, &.{ "git", "add", "." });
        try sh(g, &.{ "git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "init" });
        try sh(g, &.{ "git", "tag", "v1" });
        f.git_url = try std.mem.concat(gpa_t, u8, &.{ "file://", g });

        const c = try std.fs.path.join(gpa_t, &.{ f.root, "cache" });
        defer gpa_t.free(c);
        f.cache = try .open(gpa_t, io_t, c);
    }

    fn deinit(f: *Fixture) void {
        f.cache.close(gpa_t, io_t);
        gpa_t.free(f.root);
        gpa_t.free(f.reg_url);
        gpa_t.free(f.git_url);
        f.tmp.cleanup();
    }

    fn fetcher(f: *Fixture, sink: *diag.Sink) Fetcher {
        const regs = gpa_t.alloc(Registry, 1) catch unreachable;
        regs[0] = .{ .url = f.reg_url };
        return .{ .gpa = gpa_t, .io = io_t, .cache = &f.cache, .sink = sink, .registries = regs, .root_dir = f.root };
    }
};

/// SHA-256 over every cache entry's path, kind, size, inode, mtime and ctime:
/// equal snapshots mean nothing in the cache was written.
fn snapshot(c: *const Cache) !lock.Hash {
    var d = try c.dir.openDir(io_t, ".", .{ .iterate = true });
    defer d.close(io_t);
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |p| gpa_t.free(p);
        paths.deinit(gpa_t);
    }
    var w = try d.walk(gpa_t);
    defer w.deinit();
    while (try w.next(io_t)) |e| try paths.append(gpa_t, try gpa_t.dupe(u8, e.path));
    std.mem.sort([]u8, paths.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    var h: std.crypto.hash.sha2.Sha256 = .init(.{});
    for (paths.items) |p| {
        const st = try d.statFile(io_t, p, .{ .follow_symlinks = false });
        h.update(p);
        h.update(std.mem.asBytes(&.{ st.size, @as(u64, @intCast(st.inode)), @as(u64, @backingInt(st.kind)) }));
        h.update(std.mem.asBytes(&[2]i96{ st.mtime.nanoseconds, st.ctime.nanoseconds }));
    }
    return h.finalResult();
}

fn countCode(sink: *diag.Sink, code: diag.DiagCode) usize {
    var n: usize = 0;
    for (sink.finish()) |d| n += @intFromBool(d.code == code);
    return n;
}

/// Some diagnostic's message contains `needle`.
fn expectMessage(sink: *diag.Sink, needle: []const u8) !void {
    const ds = sink.finish();
    for (ds) |d| if (std.mem.indexOf(u8, d.message, needle) != null) return;
    for (ds) |d| std.debug.print("diagnostic: {s}\n", .{d.message});
    return error.TestExpectedDiagnostic;
}

test "file:// registry and local git fixtures populate the cache; a second fetch writes nothing" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var sink: diag.Sink = .init(gpa_t, io_t);
    defer sink.deinit();
    var f = fx.fetcher(&sink);
    defer gpa_t.free(f.registries);

    var pool: Pool = undefined;
    try pool.init(gpa_t, io_t, 2);
    defer pool.deinit(gpa_t);

    const first = [_]Request{
        .{ .name = "util", .version = ver("1.0.0"), .source = .{ .registry = null } },
        .{ .name = "gfx", .source = .{ .git = .{ .url = fx.git_url, .rev = "refs/tags/v1" } } },
    };
    var out: [2]Error!Fetched = undefined;
    f.fetchAll(&pool, &first, &out);
    var util = try out[0];
    defer util.deinit(gpa_t);
    var gfx = try out[1];
    defer gfx.deinit(gpa_t);
    try testing.expect(!sink.hasErrors());

    try testing.expectEqual(fx.util_hash, util.sha256);
    try testing.expect(fx.cache.has(io_t, util.sha256) and fx.cache.has(io_t, gfx.sha256));
    const lib = try std.fs.path.join(gpa_t, &.{ gfx.dir, "src/lib.pr" });
    defer gpa_t.free(lib);
    const text = try Io.Dir.cwd().readFileAlloc(io_t, lib, gpa_t, .limited(1024));
    defer gpa_t.free(text);
    try testing.expectEqualStrings("pub fn draw() {}\n", text);
    try testing.expectEqual(40, gfx.rev.?.len);

    // The lock now records both; the remotes go away and the cache must suffice.
    const locked = [_]lock.Package{
        .{ .name = "util", .version = ver("1.0.0"), .source = .{ .registry = null }, .sha256 = util.sha256 },
        .{ .name = "gfx", .version = ver("2.0.1"), .source = .{ .git = .{ .url = fx.git_url, .rev = gfx.rev.? } }, .sha256 = gfx.sha256 },
    };
    try fx.tmp.dir.deleteTree(io_t, "reg");
    try fx.tmp.dir.deleteTree(io_t, "gfx");
    const before = try snapshot(&fx.cache);
    for ([_]bool{ false, true }) |offline| {
        f.offline = offline;
        for (&locked, [_]*const Fetched{ &util, &gfx }) |*p, prev| {
            var again = try f.fetch(.fromLock(p));
            defer again.deinit(gpa_t);
            try testing.expectEqualStrings(prev.dir, again.dir);
        }
    }
    try testing.expectEqual(before, try snapshot(&fx.cache));
    try testing.expect(!sink.hasErrors());
}

test "path dependencies are read in place" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var sink: diag.Sink = .init(gpa_t, io_t);
    defer sink.deinit();
    var f = fx.fetcher(&sink);
    defer gpa_t.free(f.registries);
    f.offline = true;

    const before = try snapshot(&fx.cache);
    var got = try f.fetch(.{ .name = "local", .source = .{ .path = "local" } });
    defer got.deinit(gpa_t);
    const expected_dir = try std.fs.path.join(gpa_t, &.{ fx.root, "local" });
    defer gpa_t.free(expected_dir);
    try testing.expectEqualStrings(expected_dir, got.dir);
    var d = try fx.tmp.dir.openDir(io_t, "local", .{ .iterate = true });
    defer d.close(io_t);
    try testing.expectEqual(try lock.hashTree(gpa_t, io_t, d), got.sha256);
    try testing.expectEqual(before, try snapshot(&fx.cache));
}

test "hash mismatches, offline misses and tampered cache entries fail clearly" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var f = fx.fetcher(undefined);
    defer gpa_t.free(f.registries);
    const wrong: lock.Hash = @splat(0);

    {
        // Offline, cold cache: no remote is read.
        var sink: diag.Sink = .init(gpa_t, io_t);
        defer sink.deinit();
        f.sink = &sink;
        f.offline = true;
        try testing.expectError(error.FetchFailed, f.fetch(.{ .name = "util", .version = ver("1.0.0"), .source = .{ .registry = null }, .sha256 = fx.util_hash }));
        try testing.expectError(error.FetchFailed, f.fetch(.{ .name = "gfx", .source = .{ .git = .{ .url = fx.git_url, .rev = "HEAD" } } }));
        try testing.expectError(error.FetchFailed, f.fetch(.{ .name = "util", .version = ver("1.0.0"), .source = .{ .registry = null } }));
        try testing.expectEqual(3, sink.finish().len);
        try expectMessage(&sink, "`util` 1.0.0 is not in the package cache and `--offline` forbids fetching it");
        try expectMessage(&sink, "registry index of `util` is not in the package cache");
        f.offline = false;
    }
    {
        // A lock hash the archive does not match is E0911; nothing is installed.
        var sink: diag.Sink = .init(gpa_t, io_t);
        defer sink.deinit();
        f.sink = &sink;
        try testing.expectError(error.FetchFailed, f.fetch(.{ .name = "util", .version = ver("1.0.0"), .source = .{ .registry = null }, .sha256 = wrong }));
        try testing.expectError(error.FetchFailed, f.fetch(.{ .name = "util", .version = ver("9.0.0"), .source = .{ .registry = null } }));
        try testing.expectError(error.FetchFailed, f.fetch(.{ .name = "nope", .version = ver("1.0.0"), .source = .{ .registry = "other" } }));
        try testing.expectEqual(1, countCode(&sink, .E0911));
        try expectMessage(&sink, "the registry has no `util` 9.0.0");
        try expectMessage(&sink, "registry `other` is not configured");
        try testing.expect(!fx.cache.has(io_t, wrong) and !fx.cache.has(io_t, fx.util_hash));
    }
    {
        // A modified cache entry is E0911 on the next fetch.
        var sink: diag.Sink = .init(gpa_t, io_t);
        defer sink.deinit();
        f.sink = &sink;
        var got = try f.fetch(.{ .name = "util", .version = ver("1.0.0"), .source = .{ .registry = null } });
        defer got.deinit(gpa_t);
        var d = try Io.Dir.cwd().openDir(io_t, got.dir, .{});
        defer d.close(io_t);
        try d.writeFile(io_t, .{ .sub_path = "extra.pr", .data = "" });
        try testing.expectError(error.FetchFailed, f.fetch(.{ .name = "util", .version = ver("1.0.0"), .source = .{ .registry = null }, .sha256 = fx.util_hash }));
        try testing.expectEqual(1, sink.finish().len);
        try testing.expectEqual(.E0911, sink.finish()[0].code);
    }
}

test "registry index parsing and the offline index copy" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var sink: diag.Sink = .init(gpa_t, io_t);
    defer sink.deinit();
    var f = fx.fetcher(&sink);
    defer gpa_t.free(f.registries);

    var ix = try f.index(null, "util", null);
    defer ix.deinit();
    try testing.expectEqual(1, ix.releases.len);
    try testing.expectEqual(fx.util_hash, ix.releases[0].sha256);
    try testing.expectEqualStrings("base", ix.releases[0].release.deps[0].name);
    try testing.expect(ix.releases[0].release.deps[0].accepts(ver("1.4.0")));
    var none = try f.index(null, "absent", null);
    defer none.deinit();
    try testing.expectEqual(0, none.releases.len);

    // Offline reads the copy made above.
    try fx.tmp.dir.deleteTree(io_t, "reg");
    f.offline = true;
    var off = try f.index(null, "util", null);
    defer off.deinit();
    try testing.expectEqual(fx.util_hash, off.releases[0].sha256);
    try testing.expect(!sink.hasErrors());

    var arena: std.heap.ArenaAllocator = .init(gpa_t);
    defer arena.deinit();
    var problem: []const u8 = "";
    const zero_hex: [64]u8 = @splat('0');
    for ([_][]const u8{
        "x = 1\n",
        "[[release]]\nversion = \"1.0.0\"\n",
        "[[release]]\nversion = \"1.0\"\nsha256 = \"\"\n",
        "[[release]]\nversion = \"1.0.0\"\nsha256 = \"" ++ zero_hex ++ "\"\ncolor = 1\n",
        "[[release]]\nversion = \"1.0.0\"\nsha256 = \"" ++ zero_hex ++ "\"\ndeps = { Bad = \"1\" }\n",
    }, [_][]const u8{ "unexpected key `x`", "missing `sha256`", "not a semver version", "unknown key `color`", "bad dependency `Bad`" }) |text, needle| {
        try testing.expectError(error.InvalidIndex, parseIndex(arena.allocator(), text, &problem));
        try testing.expect(std.mem.indexOf(u8, problem, needle) != null);
    }
}

test "gitRev maps manifest references" {
    for ([_]manifest.GitRef{ .default, .{ .tag = "v1" }, .{ .branch = "main" }, .{ .rev = "abc" } }, [_][]const u8{ "HEAD", "refs/tags/v1", "refs/heads/main", "abc" }) |ref, want| {
        const got = try gitRev(gpa_t, ref);
        defer gpa_t.free(got);
        try testing.expectEqualStrings(want, got);
    }
}
