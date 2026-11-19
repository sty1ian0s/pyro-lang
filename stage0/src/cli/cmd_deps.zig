//! `pyro add`, `pyro remove`, `pyro update` and `pyro fetch` (§13.8, §13.4).
//!
//! `add name[@requirement]` and `remove name` edit `[dependencies]` (`add --dev`:
//! `[dev-dependencies]`; `remove` edits both) of the nearest `pyro.toml` as text,
//! so every other byte of the file is kept and `add` followed by `remove`
//! restores it exactly. `add name` writes the newest stable release in the
//! registry index; `add name@req` writes `req` once a release matches it. They
//! never touch `pyro.lock`: the next `fetch` (or build) updates it.
//!
//! `fetch` resolves the manifest, keeping the versions recorded in `pyro.lock`
//! (§13.4), puts every source into the cache, and writes `pyro.lock` if it
//! changed (with `--locked`, fails instead). `update` does the same but
//! re-resolves: everything, or with names only those packages and their
//! dependency subgraph, keeping every other locked version. `--offline` uses
//! only the cache; a miss fails naming the package.
//!
//! The registries and the cache come from the environment (`docs/registry.md`):
//! `PYRO_REGISTRY`, `PYRO_REGISTRY_<NAME>`, and `PYRO_CACHE`, else
//! `$XDG_CACHE_HOME/pyro`, else `$HOME/.cache/pyro`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const cli = @import("main.zig");
const diag = @import("../diag/diag.zig");
const SourceMap = @import("../source/SourceMap.zig");
const toml = @import("../toml/toml.zig");
const Pool = @import("../base/Pool.zig");
const semver = @import("../pkg/semver.zig");
const manifest = @import("../pkg/manifest.zig");
const resolve = @import("../pkg/resolve.zig");
const lock = @import("../pkg/lock.zig");
const fetch = @import("../pkg/fetch.zig");
const layout = @import("../pkg/layout.zig");
const Cache = @import("../pkg/cache.zig").Cache;

/// Runs `add`, `remove`, `update` or `fetch` on the package around the working directory.
pub fn run(ctx: *cli.Ctx) !cli.Exit {
    return runFrom(ctx, ".");
}

/// `run` for the package whose `pyro.toml` is at or above `start`.
fn runFrom(ctx: *cli.Ctx, start: []const u8) !cli.Exit {
    const o = ctx.opts;
    switch (o.command) {
        .add, .remove => if (o.positionals.len == 0) return usage(ctx, "`pyro {t}` needs at least one dependency name", .{o.command}),
        .fetch => if (o.positionals.len != 0) return usage(ctx, "`pyro fetch` takes no arguments", .{}),
        else => {},
    }
    if (o.command == .add) for (o.positionals) |arg| {
        const at = std.mem.indexOfScalar(u8, arg, '@');
        const name = arg[0 .. at orelse arg.len];
        if (!manifest.isValidName(name)) return usage(ctx, "`{s}` is not a valid package name", .{name});
        if (at) |i| _ = semver.Requirement.parse(arg[i + 1 ..]) catch
            return usage(ctx, "`{s}` is not a valid version requirement", .{arg[i + 1 ..]});
    };

    var arena_state: std.heap.ArenaAllocator = .init(ctx.gpa);
    defer arena_state.deinit();
    var s: Session = .{ .ctx = ctx, .a = arena_state.allocator(), .sm = .init(ctx.gpa, ctx.io), .sink = .init(ctx.gpa, ctx.io) };
    defer s.deinit();
    const exit: cli.Exit = if (try layout.findRoot(s.a, ctx.io, start)) |dir| blk: {
        s.dir = dir;
        break :blk switch (o.command) {
            .add => try s.add(),
            .remove => try s.remove(),
            .update, .fetch => try s.sync(),
            else => unreachable,
        };
    } else try s.fail("could not find `pyro.toml` in `{s}` or any parent directory", .{start});
    try cli.renderDiagnostics(ctx, &s.sm, s.sink.finish());
    return if (exit == .ok and s.sink.hasErrors()) .failed else exit;
}

fn usage(ctx: *cli.Ctx, comptime fmt: []const u8, args: anytype) !cli.Exit {
    try ctx.out.stderr.print("error: " ++ fmt ++ "\n(run `pyro --help` for usage)\n", args);
    return .usage;
}

/// Packages `update` may move away from their locked versions.
const Unlock = union(enum) { none, all, names: []const []const u8 };

const Session = struct {
    ctx: *cli.Ctx,
    /// Freed when the command returns.
    a: Allocator,
    sm: SourceMap,
    sink: diag.Sink,
    /// Absolute directory holding the package's `pyro.toml`.
    dir: []const u8 = "",
    cache: ?Cache = null,
    fetcher: ?fetch.Fetcher = null,

    fn deinit(s: *Session) void {
        if (s.cache) |*c| c.close(s.ctx.gpa, s.ctx.io);
        s.sink.deinit();
        s.sm.deinit();
    }

    /// Reports an error without a location.
    fn fail(s: *Session, comptime fmt: []const u8, args: anytype) !cli.Exit {
        try s.report(null, fmt, args);
        return .failed;
    }

    fn report(s: *Session, span: ?diag.Span, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        const spans: []const diag.Label = if (span) |sp| &.{.{ .span = sp, .primary = true }} else &.{};
        try s.sink.emit(.{ .code = null, .severity = .@"error", .message = try std.fmt.allocPrint(s.a, fmt, args), .spans = spans });
    }

    /// The fetcher over the cache and registries the environment names; null after reporting.
    fn getFetcher(s: *Session) !?*fetch.Fetcher {
        if (s.fetcher) |*f| return f;
        const env = s.ctx.environ;
        const root = if (envVar(env, "PYRO_CACHE")) |c|
            c
        else if (envVar(env, "XDG_CACHE_HOME")) |x|
            try std.fs.path.join(s.a, &.{ x, "pyro" })
        else if (envVar(env, "HOME")) |h|
            try std.fs.path.join(s.a, &.{ h, ".cache", "pyro" })
        else {
            _ = try s.fail("cannot locate the package cache: set `PYRO_CACHE`", .{});
            return null;
        };
        s.cache = Cache.open(s.ctx.gpa, s.ctx.io, root) catch |err| {
            _ = try s.fail("cannot open the package cache `{s}`: {t}", .{ root, err });
            return null;
        };
        var regs: std.ArrayList(fetch.Registry) = .empty;
        const prefix = "PYRO_REGISTRY_";
        for (env.keys(), env.values()) |k, v| {
            if (std.mem.eql(u8, k, prefix[0 .. prefix.len - 1])) {
                try regs.append(s.a, .{ .url = v });
            } else if (std.mem.startsWith(u8, k, prefix) and k.len > prefix.len) {
                try regs.append(s.a, .{ .name = try std.ascii.allocLowerString(s.a, k[prefix.len..]), .url = v });
            }
        }
        s.fetcher = .{
            .gpa = s.ctx.gpa,
            .io = s.ctx.io,
            .cache = &s.cache.?,
            .sink = &s.sink,
            .environ = env,
            .registries = regs.items,
            .root_dir = s.dir,
            .offline = s.ctx.opts.offline,
        };
        return &s.fetcher.?;
    }

    fn manifestPath(s: *Session) ![]const u8 {
        return std.fs.path.join(s.a, &.{ s.dir, layout.manifest_name });
    }

    fn readManifest(s: *Session, path: []const u8) ![]const u8 {
        return Io.Dir.cwd().readFileAlloc(s.ctx.io, path, s.a, .limited(SourceMap.max_size));
    }

    /// Validates `text`, the current contents of `pyro.toml` at `path`; null after reporting.
    fn loadManifest(s: *Session, path: []const u8, text: []const u8) !?manifest.Manifest {
        const file = try s.sm.addBytes(path, text, &s.sink);
        if (s.sink.hasErrors()) return null;
        return manifest.load(s.ctx.gpa, s.sm.get(file).text, file, &s.sink) catch |err| switch (err) {
            error.InvalidManifest => null,
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    fn unsupported(s: *Session, section: []const u8) !cli.Exit {
        return s.fail("`[{s}]` is not written as `name = ...` lines under a `[{s}]` header; edit `pyro.toml` by hand", .{ section, section });
    }

    fn add(s: *Session) !cli.Exit {
        const section: []const u8 = if (s.ctx.opts.dev) "dev-dependencies" else "dependencies";
        const path = try s.manifestPath();
        var text = try s.readManifest(path);
        for (s.ctx.opts.positionals) |arg| {
            const at = std.mem.indexOfScalar(u8, arg, '@');
            const name = arg[0 .. at orelse arg.len];
            var m = try s.loadManifest(path, text) orelse return .failed;
            defer m.deinit();
            if (m.doc.root.get(section)) |v| if (v.data == .table and v.data.table.get(name) != null)
                return s.fail("`{s}` is already in `[{s}]`; remove it first to change it", .{ name, section });
            const req = try s.requirementFor(name, if (at) |i| arg[i + 1 ..] else null) orelse return .failed;
            // A requirement never contains `"` or `\`, so it needs no escaping.
            const line = try std.fmt.allocPrint(s.a, "{s} = \"{s}\"", .{ name, req });
            text = insertEntry(s.a, text, &m.doc, section, line) catch |err| switch (err) {
                error.UnsupportedLayout => return s.unsupported(section),
                error.OutOfMemory => return error.OutOfMemory,
            };
        }
        try Io.Dir.cwd().writeFile(s.ctx.io, .{ .sub_path = path, .data = text });
        return .ok;
    }

    /// The requirement `add` writes for `name`: `req` once a release of the
    /// default registry matches it, else the newest stable release. Null after reporting.
    fn requirementFor(s: *Session, name: []const u8, req: ?[]const u8) !?[]const u8 {
        const f = try s.getFetcher() orelse return null;
        var ix = f.index(null, name, null) catch |err| switch (err) {
            error.FetchFailed => return null,
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer ix.deinit();
        if (ix.releases.len == 0) {
            _ = try s.fail("the registry has no package `{s}`", .{name});
            return null;
        }
        if (req) |text| {
            const r = semver.Requirement.parse(text) catch unreachable; // checked by `runFrom`
            for (ix.releases) |x| if (r.matches(x.release.version)) return text;
            _ = try s.fail("no release of `{s}` matches `{s}`", .{ name, text });
            return null;
        }
        var best: ?semver.Version = null;
        for (ix.releases) |x| {
            const v = x.release.version;
            if (v.pre.len == 0 and (best == null or v.order(best.?) == .gt)) best = v;
        }
        const v = best orelse {
            _ = try s.fail("`{s}` has no stable release; name one with `pyro add {s}@<requirement>`", .{ name, name });
            return null;
        };
        return try std.fmt.allocPrint(s.a, "{d}.{d}.{d}", .{ v.major, v.minor, v.patch });
    }

    fn remove(s: *Session) !cli.Exit {
        const path = try s.manifestPath();
        var text = try s.readManifest(path);
        for (s.ctx.opts.positionals) |name| {
            var removed = false;
            for ([_][]const u8{ "dependencies", "dev-dependencies" }) |section| {
                var m = try s.loadManifest(path, text) orelse return .failed;
                defer m.deinit();
                const edited = removeEntry(s.a, text, &m.doc, section, name) catch |err| switch (err) {
                    error.UnsupportedLayout => return s.unsupported(section),
                    error.OutOfMemory => return error.OutOfMemory,
                };
                if (edited) |t| {
                    text = t;
                    removed = true;
                }
            }
            if (!removed) return s.fail("`{s}` is not in `[dependencies]` or `[dev-dependencies]`", .{name});
        }
        try Io.Dir.cwd().writeFile(s.ctx.io, .{ .sub_path = path, .data = text });
        return .ok;
    }

    /// `fetch` and `update`; see the module documentation.
    fn sync(s: *Session) !cli.Exit {
        const ctx = s.ctx;
        const gpa = ctx.gpa;
        var l = layout.open(gpa, ctx.io, &s.sm, &s.sink, s.dir) catch |err| switch (err) {
            error.InvalidManifest, error.InvalidLayout => return .failed,
            else => |e| return e,
        };
        defer l.deinit();
        if (l.manifest.workspace != null or !std.mem.eql(u8, l.workspace_dir, l.dir)) {
            try ctx.out.stderr.print("error: `pyro {t}` in a workspace is not implemented yet (stage 0)\n", .{ctx.opts.command});
            return .internal;
        }
        const f = try s.getFetcher() orelse return .failed;

        const old_text: ?[]const u8 = Io.Dir.cwd().readFileAlloc(ctx.io, l.lock_path, s.a, .limited(SourceMap.max_size)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return s.fail("cannot read `{s}`: {t}", .{ l.lock_path, err }),
        };
        var old: ?lock.Lock = null;
        defer if (old) |*x| x.deinit();
        if (old_text) |t| {
            const file = try s.sm.addBytes(l.lock_path, t, &s.sink);
            old = lock.parse(gpa, s.sm.get(file).text, file, &s.sink) catch |err| switch (err) {
                error.InvalidLock => return .failed,
                error.OutOfMemory => return error.OutOfMemory,
            };
        }
        const old_ptr: ?*const lock.Lock = if (old) |*x| x else null;

        var unlock: Unlock = if (ctx.opts.command == .fetch) .none else if (ctx.opts.positionals.len == 0) .all else .none;
        if (ctx.opts.command == .update and ctx.opts.positionals.len != 0) {
            var current = try s.plan(&l, f, old_ptr, .none) orelse return .failed;
            defer current.deinit();
            unlock = .{ .names = try subgraph(s, &current.res, ctx.opts.positionals) orelse return .failed };
        }
        var p = try s.plan(&l, f, old_ptr, unlock) orelse return .failed;
        defer p.deinit();

        // Registry sources; git and path sources were fetched while planning.
        var pkgs: std.ArrayList(lock.Package) = .empty;
        var reqs: std.ArrayList(fetch.Request) = .empty;
        for (p.res.packages, 0..) |rp, i| {
            if (i == p.res.root) continue;
            const node = p.graph.nodes.get(rp.name).?;
            const k = for (node.releases, 0..) |r, j| {
                if (r.version.order(rp.version) == .eq) break j;
            } else unreachable;
            var sha = node.hashes[k];
            if (node.source == .registry) {
                var span: ?diag.Span = null;
                // A locked release keeps its recorded hash, so a changed archive is E0911.
                if (p.graph.locked(rp.name, rp.version)) |lp| if (lp.source == .registry) {
                    sha = lp.sha256;
                    span = lp.span;
                };
                try reqs.append(s.a, .{ .name = rp.name, .version = rp.version, .source = node.source, .sha256 = sha, .span = span });
            }
            try pkgs.append(s.a, .{ .name = rp.name, .version = rp.version, .source = node.source, .sha256 = sha });
        }
        var pool: Pool = undefined;
        try pool.init(gpa, ctx.io, ctx.opts.jobs);
        defer pool.deinit(gpa);
        const out = try s.a.alloc(fetch.Error!fetch.Fetched, reqs.items.len);
        f.fetchAll(&pool, reqs.items, out);
        var failed = false;
        var oom = false;
        for (out) |r| {
            var got = r catch |err| {
                failed = true;
                oom = oom or err == error.OutOfMemory;
                continue;
            };
            got.deinit(gpa);
        }
        if (oom) return error.OutOfMemory;
        if (failed) return .failed;

        if (ctx.opts.locked) {
            lock.checkLocked(gpa, old_text, pkgs.items, &s.sink) catch |err| switch (err) {
                error.LockOutdated => return .failed,
                error.OutOfMemory => return error.OutOfMemory,
            };
            return .ok;
        }
        const text = try lock.render(s.a, pkgs.items);
        if (old_text == null or !std.mem.eql(u8, old_text.?, text))
            try Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = l.lock_path, .data = text });
        return .ok;
    }

    /// Builds the package index from the manifest and resolves it, keeping the
    /// locked versions `unlock` does not release. Null after reporting.
    fn plan(s: *Session, l: *const layout.Layout, f: *fetch.Fetcher, old: ?*const lock.Lock, unlock: Unlock) !?Plan {
        const m = &l.manifest;
        const pkg = m.package orelse return null; // a virtual root is a workspace, refused by `sync`
        var g: Graph = .{ .s = s, .f = f, .old = old, .unlock = unlock };
        errdefer g.deinit();
        var root_deps: std.ArrayList(resolve.Dep) = .empty;
        for ([_][]const manifest.Dependency{ m.dependencies, m.dev_dependencies }) |deps| for (deps) |d| {
            const dep: resolve.Dep = .fromManifest(d, l.manifest_file);
            try root_deps.append(s.a, dep);
            const src = try g.want(d.name, d.source, "", dep.span) orelse {
                g.deinit();
                return null;
            };
            g.add(d.name, src, dep.span) catch |err| switch (err) {
                error.FetchFailed => {
                    g.deinit();
                    return null;
                },
                error.OutOfMemory => return error.OutOfMemory,
            };
        };
        const root: resolve.Release = .{ .version = pkg.version, .deps = root_deps.items };
        // `update` with names keeps every other locked version.
        var kept: lock.Lock = .{ .arena = .init(s.ctx.gpa), .packages = &.{} };
        const prefer: ?*const lock.Lock = switch (unlock) {
            .none => old,
            .all => null,
            .names => if (old) |o| blk: {
                var ps: std.ArrayList(lock.Package) = .empty;
                for (o.packages) |lp| if (!contains(unlock.names, lp.name)) try ps.append(s.a, lp);
                kept.packages = ps.items;
                break :blk &kept;
            } else null,
        };
        const res = lock.resolveLocked(s.ctx.gpa, g.index(), prefer, pkg.name, &root, &s.sink) catch |err| switch (err) {
            error.Unresolvable => {
                g.deinit();
                return null;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        return .{ .graph = g, .res = res };
    }
};

fn envVar(env: *const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const v = env.get(key) orelse return null;
    return if (v.len == 0) null else v;
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// The names of the packages `names` select in `res`, and of every package they
/// depend on, copied into the session arena. Null after reporting an unknown name.
fn subgraph(s: *Session, res: *const resolve.Resolution, names: []const []const u8) !?[]const []const u8 {
    const seen = try s.a.alloc(bool, res.packages.len);
    @memset(seen, false);
    var stack: std.ArrayList(u32) = .empty;
    for (names) |n| {
        const before = stack.items.len;
        for (res.packages, 0..) |p, i| if (i != res.root and std.mem.eql(u8, p.name, n)) try stack.append(s.a, @intCast(i));
        if (stack.items.len == before) {
            _ = try s.fail("`{s}` is not a dependency of this package", .{n});
            return null;
        }
    }
    var out: std.ArrayList([]const u8) = .empty;
    while (stack.pop()) |i| {
        if (seen[i]) continue;
        seen[i] = true;
        try out.append(s.a, try s.a.dupe(u8, res.packages[i].name));
        try stack.appendSlice(s.a, res.packages[i].deps);
    }
    return out.items;
}

const Plan = struct {
    graph: Graph,
    res: resolve.Resolution,

    fn deinit(p: *Plan) void {
        p.res.deinit();
        p.graph.deinit();
    }
};

/// The package index `resolve` reads, built eagerly (a `resolve.Index` cannot
/// fail): registry index files, and the manifests of fetched git and path packages.
/// shortcut: one source per package name (the first one met); key nodes by
/// (name, source) if a graph needs one name from two sources.
const Graph = struct {
    s: *Session,
    f: *fetch.Fetcher,
    old: ?*const lock.Lock,
    unlock: Unlock,
    nodes: std.StringArrayHashMapUnmanaged(Node) = .empty,
    indexes: std.ArrayList(fetch.Index) = .empty,
    manifests: std.ArrayList(manifest.Manifest) = .empty,

    const Node = struct {
        /// For git, `rev` is the fetched commit.
        source: lock.Source,
        releases: []const resolve.Release = &.{},
        /// Tree hash of each release.
        hashes: []const lock.Hash = &.{},
    };

    fn deinit(g: *Graph) void {
        for (g.indexes.items) |*ix| ix.deinit();
        for (g.manifests.items) |*m| m.deinit();
        g.* = undefined;
    }

    fn index(g: *const Graph) resolve.Index {
        return .{ .ctx = g, .releasesFn = releases };
    }

    fn releases(ctx: *const anyopaque, name: []const u8) []const resolve.Release {
        const g: *const Graph = @ptrCast(@alignCast(ctx));
        return if (g.nodes.get(name)) |n| n.releases else &.{};
    }

    /// The `pyro.lock` entry of `name` (at `version`, if given) that this run keeps.
    fn locked(g: *const Graph, name: []const u8, version: ?semver.Version) ?*const lock.Package {
        const l = g.old orelse return null;
        switch (g.unlock) {
            .none => {},
            .all => return null,
            .names => |ns| if (contains(ns, name)) return null,
        }
        for (l.packages) |*p| {
            if (std.mem.eql(u8, p.name, name) and (version == null or p.version.order(version.?) == .eq)) return p;
        }
        return null;
    }

    /// The source to fetch for a dependency declared by a manifest. `base` is
    /// the declaring path package's directory relative to the root ("" for the
    /// root itself), or null inside a git package, where path sources have no
    /// meaning. A git source keeps its locked commit while the lock entry has
    /// the manifest's URL and reference. Null after reporting.
    fn want(g: *Graph, name: []const u8, src: manifest.Source, base: ?[]const u8, span: ?diag.Span) !?lock.Source {
        const a = g.s.a;
        switch (src) {
            .registry => |r| return .{ .registry = r.registry },
            .git => |gs| {
                const ref: []const u8 = switch (gs.ref) {
                    .default => "",
                    inline else => |v, tag| try std.mem.concat(a, u8, &.{ @tagName(tag), "=", v }),
                };
                if (g.locked(name, null)) |p| if (p.source == .git and std.mem.eql(u8, p.source.git.url, gs.url) and std.mem.eql(u8, p.source.git.ref, ref))
                    return .{ .git = .{ .url = gs.url, .rev = p.source.git.rev, .ref = ref } };
                return .{ .git = .{ .url = gs.url, .rev = try fetch.gitRev(a, gs.ref), .ref = ref } };
            },
            .path => |p| {
                const b = base orelse {
                    try g.s.report(span, "path dependency `{s}` inside a git package is not supported", .{name});
                    return null;
                };
                return .{ .path = if (b.len == 0) p else try std.fs.path.join(a, &.{ b, p }) };
            },
        }
    }

    /// Adds `name`, fetched from `src`, and everything it may depend on.
    fn add(g: *Graph, name: []const u8, src: lock.Source, span: ?diag.Span) fetch.Error!void {
        const a = g.s.a;
        const gpa = g.s.ctx.gpa;
        const slot = try g.nodes.getOrPut(a, name);
        if (slot.found_existing) return;
        slot.value_ptr.* = .{ .source = src };
        switch (src) {
            .registry => |r| {
                try g.indexes.ensureUnusedCapacity(a, 1);
                g.indexes.appendAssumeCapacity(try g.f.index(r, name, span));
                const ix = g.indexes.items[g.indexes.items.len - 1];
                const rels = try a.alloc(resolve.Release, ix.releases.len);
                const hashes = try a.alloc(lock.Hash, ix.releases.len);
                for (ix.releases, rels, hashes) |x, *rel, *h| {
                    rel.* = x.release;
                    h.* = x.sha256;
                }
                g.nodes.getPtr(name).?.* = .{ .source = src, .releases = rels, .hashes = hashes };
                for (rels) |rel| for (rel.deps) |d| try g.add(d.name, .{ .registry = r }, null);
            },
            .git, .path => {
                var req: fetch.Request = .{ .name = name, .source = src, .span = span };
                if (src == .git) if (g.locked(name, null)) |p| if (p.source == .git and std.mem.eql(u8, p.source.git.rev, src.git.rev)) {
                    req.sha256 = p.sha256;
                };
                var got = try g.f.fetch(req);
                defer got.deinit(gpa);
                const path = try std.fs.path.join(a, &.{ got.dir, layout.manifest_name });
                const file = g.s.sm.load(.cwd(), path, &g.s.sink) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        try g.s.report(span, "dependency `{s}` has no readable `pyro.toml` at `{s}`: {t}", .{ name, path, err });
                        return error.FetchFailed;
                    },
                };
                try g.manifests.ensureUnusedCapacity(a, 1);
                g.manifests.appendAssumeCapacity(manifest.load(gpa, g.s.sm.get(file).text, file, &g.s.sink) catch |err| switch (err) {
                    error.InvalidManifest => return error.FetchFailed,
                    error.OutOfMemory => return error.OutOfMemory,
                });
                const m = &g.manifests.items[g.manifests.items.len - 1];
                const pkg = m.package orelse {
                    try g.s.report(span, "dependency `{s}` at `{s}` is a workspace, not a package", .{ name, got.dir });
                    return error.FetchFailed;
                };
                if (!std.mem.eql(u8, pkg.name, name)) {
                    try g.s.report(span, "dependency `{s}` at `{s}` is the package `{s}`", .{ name, got.dir, pkg.name });
                    return error.FetchFailed;
                }
                const deps = try a.alloc(resolve.Dep, m.dependencies.len);
                for (m.dependencies, deps) |d, *dep| dep.* = .fromManifest(d, file);
                const rel = try a.alloc(resolve.Release, 1);
                rel[0] = .{ .version = pkg.version, .deps = deps };
                const hash = try a.alloc(lock.Hash, 1);
                hash[0] = got.sha256;
                const source: lock.Source = switch (src) {
                    .git => |gs| .{ .git = .{ .url = gs.url, .rev = try a.dupe(u8, got.rev.?), .ref = gs.ref } },
                    else => src,
                };
                g.nodes.getPtr(name).?.* = .{ .source = source, .releases = rel, .hashes = hash };
                const base: ?[]const u8 = if (src == .path) src.path else null;
                for (m.dependencies, deps) |d, dep| {
                    const child = try g.want(d.name, d.source, base, dep.span) orelse return error.FetchFailed;
                    try g.add(d.name, child, dep.span);
                }
            },
        }
    }
};

const EditError = error{ UnsupportedLayout, OutOfMemory };

/// `text`, parsed as `doc`, with `line` (`key = value`, no newline) added after
/// the last entry of table `section`, or in a new `[section]` table appended
/// to the file.
fn insertEntry(a: Allocator, text: []const u8, doc: *const toml.Document, section: []const u8, line: []const u8) EditError![]u8 {
    const v = doc.root.get(section) orelse {
        const sep: []const u8 = if (text.len == 0) "" else if (text[text.len - 1] == '\n') "\n" else "\n\n";
        return std.mem.concat(a, u8, &.{ text, sep, "[", section, "]\n", line, "\n" });
    };
    const t = try headerTable(v);
    var last = v.span.end;
    for (t.entries.values()) |*e| last = @max(last, endOf(&e.value));
    if (std.mem.indexOfScalarPos(u8, text, last, '\n')) |nl|
        return std.mem.concat(a, u8, &.{ text[0 .. nl + 1], line, "\n", text[nl + 1 ..] });
    return std.mem.concat(a, u8, &.{ text, "\n", line });
}

/// `text`, parsed as `doc`, without the line of entry `name` of table
/// `section`; null if there is no such entry. The table header always stays,
/// even when the table ends up empty: a header `insertEntry` appended cannot be
/// told from one the user wrote, and only the user's may be kept. So removing
/// what `add` put into an existing table restores the text byte for byte, and
/// removing it from a table `add` created leaves that table's empty header.
fn removeEntry(a: Allocator, text: []const u8, doc: *const toml.Document, section: []const u8, name: []const u8) EditError!?[]u8 {
    const v = doc.root.get(section) orelse return null;
    const t = try headerTable(v);
    const e = t.entries.getPtr(name) orelse return null;
    if (endOf(&e.value) == 0 or (e.value.data == .table and e.value.data.table.kind == .dotted)) return error.UnsupportedLayout;
    const start = lineStart(text, e.key_span.start);
    if (std.mem.trim(u8, text[start..e.key_span.start], " \t").len != 0) return error.UnsupportedLayout;
    if (std.mem.indexOfScalarPos(u8, text, e.value.span.end, '\n')) |nl|
        return try std.mem.concat(a, u8, &.{ text[0..start], text[nl + 1 ..] });
    // An unterminated last line: drop the newline `insertEntry` added before it.
    return try a.dupe(u8, text[0 .. start - @intFromBool(start > 0)]);
}

fn headerTable(v: *const toml.Value) error{UnsupportedLayout}!*const toml.Table {
    if (v.data != .table or v.data.table.kind != .header or v.span.end == v.span.start) return error.UnsupportedLayout;
    return v.data.table;
}

/// End of the source text of a table entry written in the table's own section;
/// 0 for one that is a section of its own (`[t.sub]`, `[[t.sub]]`).
fn endOf(v: *const toml.Value) u32 {
    switch (v.data) {
        .array => |arr| if (arr.kind == .tables) return 0,
        .table => |t| switch (t.kind) {
            .inline_table => {},
            .header, .implicit => return 0,
            .dotted => {
                var end: u32 = 0;
                for (t.entries.values()) |*e| end = @max(end, endOf(&e.value));
                return end;
            },
        },
        else => {},
    }
    return v.span.end;
}

fn lineStart(text: []const u8, pos: usize) usize {
    return if (std.mem.lastIndexOfScalar(u8, text[0..pos], '\n')) |n| n + 1 else 0;
}

// --- tests ---------------------------------------------------------------------

const testing = std.testing;
const gpa_t = testing.allocator;
const io_t = testing.io;
const args_mod = @import("args.zig");

test "insertEntry then removeEntry restores the text, but for a header it added" {
    var arena: std.heap.ArenaAllocator = .init(gpa_t);
    defer arena.deinit();
    const a = arena.allocator();
    const line = "util = \"1.0\"";
    const texts = [_][]const u8{
        "",
        "[package]\nname = \"x\"\n",
        "[package]\nname = \"x\"",
        "[package]\nname = \"x\"\n\n[dependencies]\n",
        "[dependencies]",
        "[dependencies]\n[build]\nbackend = \"llvm\"\n",
        "[dependencies]\nm = \"1\" # pinned\nn = { version = \"2\", registry = \"r\" }\n\n# trailer\n[gpu]\n",
        "[dependencies]\nm = \"1\"",
        "[dependencies]\nn.version = \"2\"\n[dependencies.o]\nversion = \"3\"\n",
    };
    for (texts) |text| for ([_][]const u8{ "dependencies", "dev-dependencies" }) |section| {
        var d: toml.Diagnostic = undefined;
        var doc = try toml.parse(gpa_t, text, &d);
        defer doc.deinit();
        const added = try insertEntry(a, text, &doc, section, line);
        var doc2 = try toml.parse(gpa_t, added, &d);
        defer doc2.deinit();
        try testing.expectEqualStrings("1.0", doc2.root.get(section).?.data.table.get("util").?.data.string);
        const removed = (try removeEntry(a, added, &doc2, section, "util")).?;
        try testing.expectEqual(null, try removeEntry(a, added, &doc2, section, "absent"));
        if (doc.root.get(section) != null) {
            try testing.expectEqualStrings(text, removed);
        } else {
            // The added header stays; from then on the round trip is exact.
            try testing.expectEqualStrings(added[0 .. added.len - line.len - 1], removed);
            var doc3 = try toml.parse(gpa_t, removed, &d);
            defer doc3.deinit();
            try testing.expectEqualStrings(added, try insertEntry(a, removed, &doc3, section, line));
        }
    };
    // A user's table keeps its header when its last entry goes.
    {
        const text = "[package]\nname = \"x\"\n\n[dependencies]\nfoo = \"1\"\n";
        var d: toml.Diagnostic = undefined;
        var doc = try toml.parse(gpa_t, text, &d);
        defer doc.deinit();
        try testing.expectEqualStrings(text[0 .. text.len - "foo = \"1\"\n".len], (try removeEntry(a, text, &doc, "dependencies", "foo")).?);
    }
    // Entries written as their own sections or dotted keys are not removed.
    var d: toml.Diagnostic = undefined;
    var doc = try toml.parse(gpa_t, texts[texts.len - 1], &d);
    defer doc.deinit();
    for ([_][]const u8{ "n", "o" }) |name|
        try testing.expectError(error.UnsupportedLayout, removeEntry(a, texts[texts.len - 1], &doc, "dependencies", name));
}

/// A temporary directory with a file:// registry `reg/`, a package `app/`, a
/// path package `local/` and a cache `cache/`.
const Fixture = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    app: []u8,
    env: std.process.Environ.Map,

    fn init(f: *Fixture, manifest_text: []const u8) !void {
        f.tmp = testing.tmpDir(.{});
        errdefer f.tmp.cleanup();
        f.root = try f.tmp.dir.realPathFileAlloc(io_t, ".", gpa_t);
        f.app = try std.fs.path.join(gpa_t, &.{ f.root, "app" });
        f.env = .init(gpa_t);
        try f.write("app/pyro.toml", manifest_text);
        try f.write("app/src/main.pr", "fn main() {}\n");
        try f.write("local/pyro.toml", "[package]\nname = \"local\"\nversion = \"0.1.0\"\nedition = \"2026\"\n[dependencies]\nc = \"1\"\n");
        try f.write("local/src/lib.pr", "pub fn here() {}\n");
        try f.tmp.dir.createDirPath(io_t, "reg/index");
        const cache = try std.fs.path.join(gpa_t, &.{ f.root, "cache" });
        defer gpa_t.free(cache);
        const reg = try std.mem.concat(gpa_t, u8, &.{ "file://", f.root, "/reg" });
        defer gpa_t.free(reg);
        try f.env.put("PYRO_CACHE", cache);
        try f.env.put("PYRO_REGISTRY", reg);
    }

    fn deinit(f: *Fixture) void {
        f.env.deinit();
        gpa_t.free(f.app);
        gpa_t.free(f.root);
        f.tmp.cleanup();
    }

    fn write(f: *Fixture, path: []const u8, data: []const u8) !void {
        try f.tmp.dir.createDirPath(io_t, std.fs.path.dirname(path).?);
        try f.tmp.dir.writeFile(io_t, .{ .sub_path = path, .data = data });
    }

    fn read(f: *Fixture, path: []const u8) ![]u8 {
        return f.tmp.dir.readFileAlloc(io_t, path, gpa_t, .limited(1 << 20));
    }

    /// Adds release `version` of `name` to the registry; `deps` is the index's
    /// inline `deps` table body.
    fn publish(f: *Fixture, name: []const u8, version: []const u8, deps: []const u8) !void {
        const dir = try std.fmt.allocPrint(gpa_t, "pkgs/{s}-{s}", .{ name, version });
        defer gpa_t.free(dir);
        const files = [_][2][]const u8{
            .{ "pyro.toml", try std.fmt.allocPrint(gpa_t, "[package]\nname = \"{s}\"\nversion = \"{s}\"\nedition = \"2026\"\n", .{ name, version }) },
            .{ "src/lib.pr", try std.fmt.allocPrint(gpa_t, "// {s} {s}\n", .{ name, version }) },
        };
        for (files) |e| {
            defer gpa_t.free(e[1]);
            const p = try std.fs.path.join(gpa_t, &.{ dir, e[0] });
            defer gpa_t.free(p);
            try f.write(p, e[1]);
        }
        var d = try f.tmp.dir.openDir(io_t, dir, .{ .iterate = true });
        const hash = try lock.hashTree(gpa_t, io_t, d);
        d.close(io_t);

        const archive = try std.fmt.allocPrint(gpa_t, "reg/archives/{s}/{s}-{s}.tar.gz", .{ name, name, version });
        defer gpa_t.free(archive);
        try f.tmp.dir.createDirPath(io_t, std.fs.path.dirname(archive).?);
        try f.sh(".", &.{ "tar", "-czf", archive, "-C", dir, "." });

        const index = try std.fmt.allocPrint(gpa_t, "reg/index/{s}.toml", .{name});
        defer gpa_t.free(index);
        const old = f.read(index) catch try gpa_t.dupe(u8, "");
        defer gpa_t.free(old);
        const entry = try std.fmt.allocPrint(gpa_t, "{s}[[release]]\nversion = \"{s}\"\nsha256 = \"{s}\"\ndeps = {{ {s} }}\n", .{ old, version, &std.fmt.bytesToHex(hash, .lower), deps });
        defer gpa_t.free(entry);
        try f.write(index, entry);
    }

    fn sh(f: *Fixture, cwd: []const u8, argv: []const []const u8) !void {
        const dir = try std.fs.path.join(gpa_t, &.{ f.root, cwd });
        defer gpa_t.free(dir);
        const r = try std.process.run(gpa_t, io_t, .{ .argv = argv, .cwd = .{ .path = dir } });
        defer gpa_t.free(r.stdout);
        defer gpa_t.free(r.stderr);
        if (!r.term.success()) {
            std.debug.print("{s}: {s}\n", .{ argv[0], r.stderr });
            return error.CommandFailed;
        }
    }

    /// Commits everything in `dir` as a new commit of the git repository there.
    fn commit(f: *Fixture, dir: []const u8) !void {
        try f.sh(dir, &.{ "git", "add", "." });
        try f.sh(dir, &.{ "git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "c" });
    }

    /// Runs `pyro args...` in `app/`.
    fn pyro(f: *Fixture, args: []const []const u8) !Result {
        var arena: std.heap.ArenaAllocator = .init(gpa_t);
        defer arena.deinit();
        var r: Result = .{ .exit = undefined, .stdout = .init(gpa_t), .stderr = .init(gpa_t) };
        errdefer r.deinit();
        var msg: []const u8 = "";
        const opts = try args_mod.parse(arena.allocator(), args, &msg);
        var ctx: cli.Ctx = .{ .gpa = gpa_t, .io = io_t, .environ = &f.env, .opts = opts, .out = .{ .stdout = &r.stdout.writer, .stderr = &r.stderr.writer } };
        r.exit = try runFrom(&ctx, f.app);
        return r;
    }

    /// Runs `pyro args...` and expects `exit`.
    fn expect(f: *Fixture, exit: cli.Exit, args: []const []const u8) !void {
        var r = try f.pyro(args);
        defer r.deinit();
        if (r.exit != exit) {
            std.debug.print("pyro {s}: exit {t}\n{s}", .{ args[0], r.exit, r.stderr.written() });
            return error.TestUnexpectedExit;
        }
    }
};

const Result = struct {
    exit: cli.Exit,
    stdout: Io.Writer.Allocating,
    stderr: Io.Writer.Allocating,

    fn deinit(r: *Result) void {
        r.stdout.deinit();
        r.stderr.deinit();
    }

    fn expectError(r: *Result, exit: cli.Exit, needle: []const u8) !void {
        try testing.expectEqual(exit, r.exit);
        if (std.mem.indexOf(u8, r.stderr.written(), needle) == null) {
            std.debug.print("stderr: {s}\n", .{r.stderr.written()});
            return error.TestExpectedMessage;
        }
    }
};

/// `pyro args...` fails with `exit` and `needle` on stderr.
fn expectFailure(f: *Fixture, exit: cli.Exit, args: []const []const u8, needle: []const u8) !void {
    var r = try f.pyro(args);
    defer r.deinit();
    try r.expectError(exit, needle);
}

const app_manifest =
    \\# The demo app.
    \\[package]
    \\name = "app"
    \\version = "0.1.0"
    \\edition = "2026"
    \\
    \\[dependencies]
    \\local = { path = "../local" }   # in place
    \\
    \\[build]
    \\backend = "llvm"
    \\
;

test "add then remove leaves pyro.toml byte-identical" {
    var fx: Fixture = undefined;
    try fx.init(app_manifest);
    defer fx.deinit();
    try fx.publish("util", "1.0.0", "");
    try fx.publish("util", "1.2.0", "");
    try fx.publish("util", "2.0.0-rc.1", "");

    try fx.expect(.ok, &.{ "add", "util" });
    try fx.expect(.ok, &.{ "add", "--dev", "util@~1.0" });
    const added = try fx.read("app/pyro.toml");
    defer gpa_t.free(added);
    try testing.expectEqualStrings(
        \\# The demo app.
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\edition = "2026"
        \\
        \\[dependencies]
        \\local = { path = "../local" }   # in place
        \\util = "1.2.0"
        \\
        \\[build]
        \\backend = "llvm"
        \\
        \\[dev-dependencies]
        \\util = "~1.0"
        \\
    , added);

    // `[dev-dependencies]` was new, so its header stays (see `removeEntry`).
    const with_dev = app_manifest ++ "\n[dev-dependencies]\n";
    try fx.expect(.ok, &.{ "remove", "util" });
    const removed = try fx.read("app/pyro.toml");
    defer gpa_t.free(removed);
    try testing.expectEqualStrings(with_dev, removed);
    try fx.write("app/pyro.toml", app_manifest);

    try expectFailure(&fx, .failed, &.{ "add", "local" }, "`local` is already in `[dependencies]`");
    try expectFailure(&fx, .failed, &.{ "add", "ghost" }, "the registry has no package `ghost`");
    try expectFailure(&fx, .failed, &.{ "add", "util@^3" }, "no release of `util` matches `^3`");
    try expectFailure(&fx, .failed, &.{ "remove", "util" }, "`util` is not in `[dependencies]` or `[dev-dependencies]`");
    try expectFailure(&fx, .usage, &.{ "add", "Bad" }, "`Bad` is not a valid package name");
    try expectFailure(&fx, .usage, &.{ "add", "util@x.y" }, "`x.y` is not a valid version requirement");
    try expectFailure(&fx, .usage, &.{"remove"}, "needs at least one dependency name");
    const unchanged = try fx.read("app/pyro.toml");
    defer gpa_t.free(unchanged);
    try testing.expectEqualStrings(app_manifest, unchanged);
}

/// The `version` locked for `name` in `app/pyro.lock`.
fn lockedVersion(fx: *Fixture, name: []const u8) ![]const u8 {
    const text = try fx.read("app/pyro.lock");
    defer gpa_t.free(text);
    const key = try std.fmt.allocPrint(gpa_t, "name = \"{s}\"\nversion = \"", .{name});
    defer gpa_t.free(key);
    const at = (std.mem.indexOf(u8, text, key) orelse return error.NotLocked) + key.len;
    const end = std.mem.indexOfScalarPos(u8, text, at, '"').?;
    for ([_][]const u8{ "1.0.0", "1.1.0", "0.1.0" }) |v| if (std.mem.eql(u8, text[at..end], v)) return v;
    return error.UnexpectedVersion;
}

test "fetch locks and caches; update touches only the named dependency's subgraph" {
    var fx: Fixture = undefined;
    try fx.init(
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\edition = "2026"
        \\[dependencies]
        \\a = "1"
        \\c = "1"
        \\local = { path = "../local" }
        \\
    );
    defer fx.deinit();
    try fx.publish("a", "1.0.0", "b = \"^1.0\"");
    try fx.publish("b", "1.0.0", "");
    try fx.publish("c", "1.0.0", "");
    try fx.write("gfx/pyro.toml", "[package]\nname = \"gfx\"\nversion = \"1.0.0\"\nedition = \"2026\"\n");
    try fx.write("gfx/src/lib.pr", "pub fn draw() {}\n");
    try fx.sh("gfx", &.{ "git", "init", "--quiet" });
    try fx.commit("gfx");
    const git_dep = try std.fmt.allocPrint(gpa_t, "gfx = {{ git = \"file://{s}/gfx\" }}\n", .{fx.root});
    defer gpa_t.free(git_dep);
    {
        const m = try fx.read("app/pyro.toml");
        defer gpa_t.free(m);
        const both = try std.mem.concat(gpa_t, u8, &.{ m, git_dep });
        defer gpa_t.free(both);
        try fx.write("app/pyro.toml", both);
    }

    try fx.expect(.ok, &.{"fetch"});
    const first = try fx.read("app/pyro.lock");
    defer gpa_t.free(first);
    for ([_][]const u8{ "a", "b", "c" }) |n| try testing.expectEqualStrings("1.0.0", try lockedVersion(&fx, n));
    try testing.expectEqualStrings("0.1.0", try lockedVersion(&fx, "local"));
    try testing.expect(std.mem.indexOf(u8, first, "source = \"path+../local\"") != null);
    try testing.expect(std.mem.indexOf(u8, first, "source = \"git+file://") != null);
    // The registry archives are in the cache.
    var src = try fx.tmp.dir.openDir(io_t, "cache/src", .{ .iterate = true });
    defer src.close(io_t);
    var n: usize = 0;
    var it = src.iterate();
    while (try it.next(io_t)) |_| n += 1;
    try testing.expectEqual(4, n); // a, b, c and gfx; `local` is read in place

    // New releases everywhere: `fetch` keeps the lock, `update a` moves a and b only.
    try fx.publish("a", "1.1.0", "b = \"^1.1\"");
    try fx.publish("b", "1.1.0", "");
    try fx.publish("c", "1.1.0", "");
    try fx.write("gfx/src/lib.pr", "pub fn draw() { }\n");
    try fx.commit("gfx");
    try fx.expect(.ok, &.{"fetch"});
    const again = try fx.read("app/pyro.lock");
    defer gpa_t.free(again);
    try testing.expectEqualStrings(first, again);
    try fx.expect(.ok, &.{ "fetch", "--locked" });

    try fx.expect(.ok, &.{ "update", "a" });
    try testing.expectEqualStrings("1.1.0", try lockedVersion(&fx, "a"));
    try testing.expectEqualStrings("1.1.0", try lockedVersion(&fx, "b"));
    try testing.expectEqualStrings("1.0.0", try lockedVersion(&fx, "c"));
    const after_a = try fx.read("app/pyro.lock");
    defer gpa_t.free(after_a);
    const gfx_at = std.mem.indexOf(u8, first, "name = \"gfx\"").?;
    const gfx_entry = first[gfx_at..][0..std.mem.indexOf(u8, first[gfx_at..], "\n\n").?];
    try testing.expect(std.mem.indexOf(u8, after_a, gfx_entry) != null); // same commit and hash

    try expectFailure(&fx, .failed, &.{ "update", "ghost" }, "`ghost` is not a dependency of this package");
    try fx.expect(.ok, &.{"update"});
    try testing.expectEqualStrings("1.1.0", try lockedVersion(&fx, "c"));
    const after_all = try fx.read("app/pyro.lock");
    defer gpa_t.free(after_all);
    try testing.expect(std.mem.indexOf(u8, after_all, gfx_entry) == null); // gfx moved to the new commit
}

test "a changed git reference moves the locked commit; --locked fails until then" {
    var fx: Fixture = undefined;
    try fx.init("");
    defer fx.deinit();
    try fx.write("gfx/pyro.toml", "[package]\nname = \"gfx\"\nversion = \"1.0.0\"\nedition = \"2026\"\n");
    try fx.write("gfx/src/lib.pr", "pub fn draw() {}\n");
    try fx.sh("gfx", &.{ "git", "init", "--quiet" });
    try fx.commit("gfx");
    try fx.sh("gfx", &.{ "git", "tag", "v1" });
    try fx.write("gfx/src/lib.pr", "pub fn draw() { }\n");
    try fx.commit("gfx");
    try fx.sh("gfx", &.{ "git", "tag", "v2" });

    var locks: [2][]u8 = .{ &.{}, &.{} };
    defer for (locks) |l| gpa_t.free(l);
    for ([_][]const u8{ "v1", "v2" }, &locks) |tag, *out| {
        const m = try std.fmt.allocPrint(gpa_t, "[package]\nname = \"app\"\nversion = \"0.1.0\"\nedition = \"2026\"\n[dependencies]\ngfx = {{ git = \"file://{s}/gfx\", tag = \"{s}\" }}\n", .{ fx.root, tag });
        defer gpa_t.free(m);
        try fx.write("app/pyro.toml", m);
        if (out == &locks[1]) try expectFailure(&fx, .failed, &.{ "fetch", "--locked" }, "`pyro.lock` needs to be updated");
        try fx.expect(.ok, &.{"fetch"});
        try fx.expect(.ok, &.{ "fetch", "--locked" });
        out.* = try fx.read("app/pyro.lock");
    }
    try testing.expect(std.mem.indexOf(u8, locks[0], "/gfx?tag=v1#") != null);
    try testing.expect(std.mem.indexOf(u8, locks[1], "/gfx?tag=v2#") != null);
    const commit = struct {
        fn of(text: []const u8) []const u8 {
            const at = std.mem.indexOfScalarPos(u8, text, std.mem.indexOf(u8, text, "?tag=").?, '#').? + 1;
            return text[at..std.mem.indexOfScalarPos(u8, text, at, '"').?];
        }
    }.of;
    try testing.expect(!std.mem.eql(u8, commit(locks[0]), commit(locks[1])));
}

test "offline fetch with a cold cache fails clearly; warm, it needs no registry" {
    var fx: Fixture = undefined;
    try fx.init(
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\edition = "2026"
        \\[dependencies]
        \\c = "1"
        \\
    );
    defer fx.deinit();
    try fx.publish("c", "1.0.0", "");

    try expectFailure(&fx, .failed, &.{ "fetch", "--offline" }, "the registry index of `c` is not in the package cache and `--offline` forbids fetching it");
    try testing.expectError(error.FileNotFound, fx.read("app/pyro.lock"));

    try fx.expect(.ok, &.{"fetch"});
    try fx.tmp.dir.deleteTree(io_t, "reg");
    try fx.expect(.ok, &.{ "fetch", "--offline", "--locked" });

    // Without the index copy, the cached archive alone is not enough to resolve.
    try fx.tmp.dir.deleteTree(io_t, "cache/index");
    try expectFailure(&fx, .failed, &.{ "fetch", "--offline" }, "`--offline` forbids fetching it");
}

test "usage errors and a missing manifest" {
    var fx: Fixture = undefined;
    try fx.init(app_manifest);
    defer fx.deinit();
    try expectFailure(&fx, .usage, &.{ "fetch", "x" }, "`pyro fetch` takes no arguments");
    try fx.tmp.dir.deleteFile(io_t, "app/pyro.toml");
    try expectFailure(&fx, .failed, &.{"fetch"}, "could not find `pyro.toml`");
}
