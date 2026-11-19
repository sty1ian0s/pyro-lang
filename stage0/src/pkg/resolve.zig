//! Dependency resolution (§13.4) over an abstract package index.
//!
//! For each package name the resolver picks one version per semver-compatible
//! line (`semver.CompatLine`): the highest version satisfying every requirement
//! on that line. A requirement belongs to the line of the highest release it
//! matches, so `^1.0` and `^2.0` of one package coexist as two nodes while
//! diamonds share one node. When the requirements on a line conflict, those
//! that also match an older line move there. Requirements that no version
//! satisfies are E0910, listing every requirement chain on the line; cycles
//! are E0906.
//!
//! The result depends only on the root and the index contents: it never depends
//! on hash order or timing, and packages come out sorted by (name, version).

const std = @import("std");
const semver = @import("semver.zig");
const manifest = @import("manifest.zig");
const diag = @import("../diag/diag.zig");

/// One dependency edge as declared by a release.
pub const Dep = struct {
    /// Package name.
    name: []const u8,
    requirement: semver.Requirement = .{},
    /// Matches every version, prereleases included, ignoring `requirement`
    /// (git and path sources).
    pinned: bool = false,
    /// Manifest entry, used to locate diagnostics when this is a root dependency.
    span: ?diag.Span = null,

    /// A root dependency from the manifest registered as `file`. Git and path
    /// sources are pinned: their single release is the version.
    pub fn fromManifest(d: manifest.Dependency, file: diag.FileId) Dep {
        return .{
            .name = d.name,
            .requirement = switch (d.source) {
                .registry => |r| r.requirement,
                .git, .path => .{},
            },
            .pinned = d.source != .registry,
            .span = .{ .file = file, .start = d.span.start, .end = d.span.end },
        };
    }

    /// Whether version `v` satisfies this dependency.
    pub fn accepts(d: *const Dep, v: semver.Version) bool {
        return d.pinned or d.requirement.matches(v);
    }
};

/// One published version of a package and its dependencies.
pub const Release = struct {
    version: semver.Version,
    deps: []const Dep = &.{},
};

/// Source of releases: registries, git and path packages all map a name to the
/// releases available under it (any order; empty if unknown). Returned slices
/// must stay valid and unchanged for the duration of `resolve`.
pub const Index = struct {
    ctx: *const anyopaque,
    releasesFn: *const fn (ctx: *const anyopaque, name: []const u8) []const Release,

    pub fn releases(ix: Index, name: []const u8) []const Release {
        return ix.releasesFn(ix.ctx, name);
    }
};

/// One node of the resolved graph: a package version compiled once per
/// environment and target.
pub const Package = struct {
    name: []const u8,
    version: semver.Version,
    /// Indices into `Resolution.packages`, ascending.
    deps: []const u32,
};

/// The resolved package graph. Strings point into the root and index.
pub const Resolution = struct {
    arena: std.heap.ArenaAllocator,
    /// Sorted by name, then version precedence.
    packages: []const Package,
    /// Index of the root package in `packages`.
    root: u32,

    pub fn deinit(r: *Resolution) void {
        r.arena.deinit();
        r.* = undefined;
    }
};

pub const Error = error{ Unresolvable, OutOfMemory };

/// Resolves the dependency graph of the package `root_name` at release `root`.
/// Every unsatisfiable requirement (E0910) and cycle (E0906) is emitted to
/// `sink`; if there was any, the result is `error.Unresolvable`. A dependency
/// naming `root_name` resolves to the root itself.
pub fn resolve(gpa: std.mem.Allocator, index: Index, root_name: []const u8, root: *const Release, sink: *diag.Sink) Error!Resolution {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    var r: Resolver = .{ .a = arena.allocator(), .index = index, .root_name = root_name, .root = root };

    // Re-expand from the root until the chosen versions stop changing, so a
    // version's dependencies count only while that version is chosen; then move
    // requirements off conflicting lines and repeat. Each move excludes one
    // (requirement, line) pair for good, so this terminates.
    // shortcut: greedy, no backtracking (a conflict is reported, not routed
    // around by an older parent version, and an oscillation is reported after
    // `max_passes`); upgrade to PubGrub if real registries need it.
    const max_passes = 64;
    var prev: []const Slot = &.{};
    while (true) {
        var passes: usize = 0;
        while (true) : (passes += 1) {
            try r.pass(prev);
            const Change = struct { slot: u32, to: *const Release };
            var changes: std.ArrayList(Change) = .empty;
            for (r.slots.items, 0..) |s, i| {
                const f = r.best(s.name, s.line, s.reqs.items) orelse continue;
                if (f != s.release) try changes.append(r.a, .{ .slot = @intCast(i), .to = f });
            }
            if (changes.items.len == 0) break;
            if (passes == max_passes) {
                for (changes.items) |c| {
                    const s = r.slots.items[c.slot];
                    const msg = try std.fmt.allocPrint(r.a, "dependency resolution did not converge: `{s}` {f} keeps changing between versions", .{ s.name, lineFmt(s.line) });
                    try r.emit(sink, .E0910, msg, s.reqs.items);
                }
                return error.Unresolvable;
            }
            for (changes.items) |c| r.slots.items[c.slot].release = c.to;
            prev = r.slots.items;
        }
        if (!try r.demote()) break;
    }

    var failed = try r.reportMissing(sink);
    failed = try r.reportConflicts(sink) or failed;
    failed = try r.reportCycles(sink) or failed;
    if (failed) return error.Unresolvable;
    return .{ .packages = try r.graph(), .root = r.root_index, .arena = arena };
}

const Req = struct {
    dep: *const Dep,
    /// Slot of the release declaring `dep`.
    from: u32,
};

/// A (name, compatibility line) node of the current pass.
const Slot = struct {
    name: []const u8,
    line: semver.CompatLine,
    /// The release expanded in this pass; after the pass, the best choice.
    release: *const Release,
    /// The requirement that first reached this slot (breadth-first), giving the
    /// shortest chain from the root; null for the root.
    via: ?Req,
    reqs: std.ArrayList(Req) = .empty,
    /// Resolved `release.deps`, in declaration order.
    edges: std.ArrayList(Edge) = .empty,
};

const Edge = struct {
    to: u32,
    dep: *const Dep,
};

const Resolver = struct {
    a: std.mem.Allocator,
    index: Index,
    root_name: []const u8,
    root: *const Release,
    slots: std.ArrayList(Slot) = .empty,
    /// Requirements no release matches at all.
    missing: std.ArrayList(Req) = .empty,
    /// Lines a requirement was moved off by `demote`; kept across passes.
    excluded: std.ArrayList(struct { dep: *const Dep, line: semver.CompatLine }) = .empty,
    root_index: u32 = 0,

    fn candidates(r: *Resolver, name: []const u8) []const Release {
        return if (std.mem.eql(u8, name, r.root_name)) r.root[0..1] else r.index.releases(name);
    }

    /// Highest release of `name` on `line` satisfying every requirement in `reqs`.
    fn best(r: *Resolver, name: []const u8, line: semver.CompatLine, reqs: []const Req) ?*const Release {
        var top: ?*const Release = null;
        next: for (r.candidates(name)) |*c| {
            if (!std.meta.eql(c.version.compatLine(), line)) continue;
            for (reqs) |q| if (!q.dep.accepts(c.version)) continue :next;
            if (top == null or c.version.order(top.?.version) == .gt) top = c;
        }
        return top;
    }

    /// Highest release `dep` accepts outside the lines it was moved off and `skip`.
    fn highest(r: *Resolver, dep: *const Dep, skip: ?semver.CompatLine) ?*const Release {
        var t: ?*const Release = null;
        next: for (r.candidates(dep.name)) |*c| {
            if (!dep.accepts(c.version)) continue;
            const line = c.version.compatLine();
            if (skip != null and std.meta.eql(line, skip.?)) continue;
            for (r.excluded.items) |e| if (e.dep == dep and std.meta.eql(e.line, line)) continue :next;
            if (t == null or c.version.order(t.?.version) == .gt) t = c;
        }
        return t;
    }

    /// On every line no version satisfies, keeps the requirements that match no
    /// other line (or else the first) and moves each other requirement the best
    /// version for those rejects to its next line. Returns whether any moved.
    fn demote(r: *Resolver) !bool {
        var moved = false;
        for (r.slots.items) |s| {
            if (r.best(s.name, s.line, s.reqs.items) != null) continue;
            var fixed: std.ArrayList(Req) = .empty;
            for (s.reqs.items) |q| if (r.highest(q.dep, s.line) == null) try fixed.append(r.a, q);
            if (fixed.items.len == 0) try fixed.append(r.a, s.reqs.items[0]);
            // Fixed requirements conflicting among themselves are a real E0910.
            const keep = r.best(s.name, s.line, fixed.items) orelse continue;
            for (s.reqs.items) |q| {
                if (q.dep.accepts(keep.version)) continue;
                try r.excluded.append(r.a, .{ .dep = q.dep, .line = s.line });
                moved = true;
            }
        }
        return moved;
    }

    // shortcut: linear lookup; fine for hundreds of packages, use a hash map beyond.
    fn find(slots: []const Slot, name: []const u8, line: semver.CompatLine) ?u32 {
        for (slots, 0..) |s, i| {
            if (std.meta.eql(s.line, line) and std.mem.eql(u8, s.name, name)) return @intCast(i);
        }
        return null;
    }

    /// Expands the graph breadth-first from the root, reusing the choices of
    /// `prev` where they satisfy the requirement that reaches them first.
    fn pass(r: *Resolver, prev: []const Slot) !void {
        r.slots = .empty;
        r.missing = .empty;
        try r.slots.append(r.a, .{ .name = r.root_name, .line = r.root.version.compatLine(), .release = r.root, .via = null });
        var i: u32 = 0;
        while (i < r.slots.items.len) : (i += 1) {
            for (r.slots.items[i].release.deps) |*dep| {
                const q: Req = .{ .dep = dep, .from = i };
                const t = r.highest(dep, null) orelse {
                    try r.missing.append(r.a, q);
                    continue;
                };
                const line = t.version.compatLine();
                const j = find(r.slots.items, dep.name, line) orelse blk: {
                    var pick = t;
                    if (find(prev, dep.name, line)) |p| {
                        if (dep.accepts(prev[p].release.version)) pick = prev[p].release;
                    }
                    try r.slots.append(r.a, .{ .name = dep.name, .line = line, .release = pick, .via = q });
                    break :blk @as(u32, @intCast(r.slots.items.len - 1));
                };
                try r.slots.items[j].reqs.append(r.a, q);
                try r.slots.items[i].edges.append(r.a, .{ .to = j, .dep = dep });
            }
        }
    }

    /// Appends "app 1.0.0 -> mid 2.1.0" for the shortest chain from the root to slot `i`.
    fn chain(r: *Resolver, out: *std.ArrayList(u8), i: u32) !void {
        var path: std.ArrayList(u32) = .empty;
        var s: ?u32 = i;
        while (s) |k| : (s = if (r.slots.items[k].via) |v| v.from else null) try path.append(r.a, k);
        std.mem.reverse(u32, path.items);
        for (path.items, 0..) |k, n| {
            if (n != 0) try out.appendSlice(r.a, " -> ");
            try r.node(out, k);
        }
    }

    fn node(r: *Resolver, out: *std.ArrayList(u8), i: u32) !void {
        const s = r.slots.items[i];
        try out.print(r.a, "{s} ", .{s.name});
        try writeVersion(r.a, out, s.release.version);
    }

    /// "{chain} requires {name} {requirement}".
    fn requirementLine(r: *Resolver, q: Req) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try r.chain(&out, q.from);
        try out.print(r.a, " requires {s} ", .{q.dep.name});
        try writeRequirement(r.a, &out, q.dep.requirement);
        return out.items;
    }

    /// The root dependency `q`'s chain starts with: where a manifest-level
    /// diagnostic about `q` points.
    fn rootDep(r: *Resolver, q: Req) *const Dep {
        var cur = q;
        while (cur.from != 0) cur = r.slots.items[cur.from].via.?;
        return cur.dep;
    }

    /// Emits `message` with one `help:` line per requirement and a label on
    /// each distinct root dependency (the first is primary).
    fn emit(r: *Resolver, sink: *diag.Sink, code: diag.DiagCode, message: []const u8, reqs: []const Req) !void {
        var help: std.ArrayList([]const u8) = .empty;
        var spans: std.ArrayList(diag.Label) = .empty;
        for (reqs) |q| {
            try help.append(r.a, try r.requirementLine(q));
            const sp = r.rootDep(q).span orelse continue;
            for (spans.items) |l| {
                if (std.meta.eql(l.span, sp)) break;
            } else try spans.append(r.a, .{ .span = sp, .primary = spans.items.len == 0 });
        }
        try sink.emit(.{ .code = code, .severity = .of(code), .message = message, .spans = spans.items, .help = help.items });
    }

    fn reportMissing(r: *Resolver, sink: *diag.Sink) !bool {
        for (r.missing.items) |q| {
            var msg: std.ArrayList(u8) = .empty;
            const avail = r.candidates(q.dep.name);
            if (avail.len == 0) {
                try msg.print(r.a, "no package named `{s}` is available", .{q.dep.name});
            } else {
                try msg.print(r.a, "no version of `{s}` matches ", .{q.dep.name});
                try writeRequirement(r.a, &msg, q.dep.requirement);
                try msg.appendSlice(r.a, " (available:");
                for (avail) |c| {
                    try msg.append(r.a, ' ');
                    try writeVersion(r.a, &msg, c.version);
                }
                try msg.append(r.a, ')');
            }
            try r.emit(sink, .E0910, msg.items, &.{q});
        }
        return r.missing.items.len != 0;
    }

    fn reportConflicts(r: *Resolver, sink: *diag.Sink) !bool {
        var failed = false;
        for (r.slots.items) |s| {
            if (r.best(s.name, s.line, s.reqs.items) != null) continue;
            failed = true;
            const msg = try std.fmt.allocPrint(r.a, "no version of `{s}` {f} satisfies every requirement on it", .{ s.name, lineFmt(s.line) });
            try r.emit(sink, .E0910, msg, s.reqs.items);
        }
        return failed;
    }

    /// Depth-first from the root; every back edge closes one cycle.
    fn reportCycles(r: *Resolver, sink: *diag.Sink) !bool {
        const State = enum { new, active, done };
        const state = try r.a.alloc(State, r.slots.items.len);
        @memset(state, .new);
        // (slot, next edge) frames; `stack` holds the active path.
        const Frame = struct { slot: u32, edge: u32 = 0 };
        var stack: std.ArrayList(Frame) = .empty;
        try stack.append(r.a, .{ .slot = 0 });
        state[0] = .active;
        var failed = false;
        while (stack.items.len != 0) {
            const top = &stack.items[stack.items.len - 1];
            const edges = r.slots.items[top.slot].edges.items;
            if (top.edge == edges.len) {
                state[top.slot] = .done;
                _ = stack.pop();
                continue;
            }
            const e = top.edge;
            top.edge += 1;
            const to = edges[e].to;
            switch (state[to]) {
                .done => {},
                .new => {
                    state[to] = .active;
                    try stack.append(r.a, .{ .slot = to });
                },
                .active => {
                    failed = true;
                    // The cycle is the stack from `to` up, closed by the edge just taken.
                    var start: usize = 0;
                    while (stack.items[start].slot != to) start += 1;
                    var msg: std.ArrayList(u8) = .empty;
                    try msg.appendSlice(r.a, "package dependency cycle: ");
                    var reqs: std.ArrayList(Req) = .empty;
                    for (stack.items[start..]) |f| {
                        try r.node(&msg, f.slot);
                        try msg.appendSlice(r.a, " -> ");
                        try reqs.append(r.a, .{ .dep = r.slots.items[f.slot].edges.items[f.edge - 1].dep, .from = f.slot });
                    }
                    try r.node(&msg, to);
                    try r.emit(sink, .E0906, msg.items, reqs.items);
                },
            }
        }
        return failed;
    }

    /// The final slots as packages sorted by (name, version), edges remapped.
    fn graph(r: *Resolver) ![]const Package {
        const n = r.slots.items.len;
        const order = try r.a.alloc(u32, n);
        for (order, 0..) |*o, i| o.* = @intCast(i);
        std.mem.sort(u32, order, r.slots.items, struct {
            fn lt(slots: []const Slot, x: u32, y: u32) bool {
                return switch (std.mem.order(u8, slots[x].name, slots[y].name)) {
                    .lt => true,
                    .gt => false,
                    .eq => slots[x].release.version.order(slots[y].release.version) == .lt,
                };
            }
        }.lt);
        const rank = try r.a.alloc(u32, n);
        for (order, 0..) |o, i| rank[o] = @intCast(i);
        const out = try r.a.alloc(Package, n);
        for (order, out) |o, *p| {
            const s = r.slots.items[o];
            const deps = try r.a.alloc(u32, s.edges.items.len);
            for (s.edges.items, deps) |e, *dst| dst.* = rank[e.to];
            std.mem.sort(u32, deps, {}, std.sort.asc(u32));
            p.* = .{ .name = s.name, .version = s.release.version, .deps = deps };
        }
        r.root_index = rank[0];
        return out;
    }
};

/// Formats a compatibility line as `2.x` or `0.3.x`.
fn lineFmt(l: semver.CompatLine) std.fmt.Alt(semver.CompatLine, writeLine) {
    return .{ .data = l };
}

fn writeLine(l: semver.CompatLine, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("{d}.", .{l.major});
    if (l.major == 0) try w.print("{d}.", .{l.minor});
    try w.writeAll("x");
}

fn writeVersion(a: std.mem.Allocator, out: *std.ArrayList(u8), v: semver.Version) !void {
    try out.print(a, "{d}.{d}.{d}", .{ v.major, v.minor, v.patch });
    if (v.pre.len != 0) try out.print(a, "-{s}", .{v.pre});
}

fn writeRequirement(a: std.mem.Allocator, out: *std.ArrayList(u8), req: semver.Requirement) !void {
    if (req.len == 0) return out.append(a, '*');
    for (req.comparators(), 0..) |c, i| {
        if (i != 0) try out.appendSlice(a, ", ");
        try out.appendSlice(a, switch (c.op) {
            .exact => "=",
            .greater => ">",
            .greater_eq => ">=",
            .less => "<",
            .less_eq => "<=",
            .tilde => "~",
            .caret => "^",
        });
        try out.print(a, "{d}", .{c.major});
        if (c.minor) |m| try out.print(a, ".{d}", .{m});
        if (c.patch) |p| try out.print(a, ".{d}", .{p});
        if (c.pre.len != 0) try out.print(a, "-{s}", .{c.pre});
    }
}

// --- tests ---------------------------------------------------------------------

const testing = std.testing;

/// An index over a fixed table of `name` -> releases.
const TestIndex = struct {
    entries: []const struct { []const u8, []const Release },

    fn releases(ctx: *const anyopaque, name: []const u8) []const Release {
        const self: *const TestIndex = @ptrCast(@alignCast(ctx));
        for (self.entries) |e| if (std.mem.eql(u8, e[0], name)) return e[1];
        return &.{};
    }

    fn index(self: *const TestIndex) Index {
        return .{ .ctx = self, .releasesFn = releases };
    }
};

fn ver(text: []const u8) semver.Version {
    return semver.Version.parse(text) catch unreachable;
}

fn dependsOn(name: []const u8, requirement: []const u8) Dep {
    return .{ .name = name, .requirement = semver.Requirement.parse(requirement) catch unreachable };
}

fn expectPackages(res: Resolution, expected: []const []const u8) !void {
    try testing.expectEqual(expected.len, res.packages.len);
    for (res.packages, expected) |p, e| {
        const got = try std.fmt.allocPrint(testing.allocator, "{s} {d}.{d}.{d}", .{ p.name, p.version.major, p.version.minor, p.version.patch });
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(e, got);
    }
}

test "diamond resolves to one shared node at the highest common version" {
    const ix: TestIndex = .{ .entries = &.{
        .{ "left", &.{.{ .version = ver("1.0.0"), .deps = &.{dependsOn("base", "^1.2")} }} },
        .{ "right", &.{.{ .version = ver("1.0.0"), .deps = &.{dependsOn("base", ">=1.1, <1.4")} }} },
        .{ "base", &.{ .{ .version = ver("1.1.0") }, .{ .version = ver("1.4.0") }, .{ .version = ver("1.3.5") }, .{ .version = ver("2.0.0") } } },
    } };
    const root: Release = .{ .version = ver("0.1.0"), .deps = &.{ dependsOn("left", "1"), dependsOn("right", "1") } };
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    var res = try resolve(testing.allocator, ix.index(), "app", &root, &sink);
    defer res.deinit();
    try expectPackages(res, &.{ "app 0.1.0", "base 1.3.5", "left 1.0.0", "right 1.0.0" });
    try testing.expectEqual(0, res.root);
    try testing.expectEqualSlices(u32, &.{ 2, 3 }, res.packages[0].deps);
    try testing.expectEqualSlices(u32, &.{1}, res.packages[2].deps);
    try testing.expectEqualSlices(u32, &.{1}, res.packages[3].deps);
}

test "incompatible lines coexist; 0.x lines split on the minor version" {
    const ix: TestIndex = .{ .entries = &.{
        .{ "old", &.{.{ .version = ver("1.0.0"), .deps = &.{ dependsOn("log", "^1.1"), dependsOn("tiny", "0.2") } }} },
        .{ "log", &.{ .{ .version = ver("1.1.0") }, .{ .version = ver("1.9.2") }, .{ .version = ver("2.3.0") }, .{ .version = ver("3.0.0-rc.1") } } },
        .{ "tiny", &.{ .{ .version = ver("0.2.7") }, .{ .version = ver("0.3.1") } } },
    } };
    const root: Release = .{ .version = ver("1.0.0"), .deps = &.{ dependsOn("old", "1"), dependsOn("log", "2"), dependsOn("tiny", "0.3") } };
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    var res = try resolve(testing.allocator, ix.index(), "app", &root, &sink);
    defer res.deinit();
    try expectPackages(res, &.{ "app 1.0.0", "log 1.9.2", "log 2.3.0", "old 1.0.0", "tiny 0.2.7", "tiny 0.3.1" });
    try testing.expectEqualSlices(u32, &.{ 2, 3, 5 }, res.packages[0].deps);
    try testing.expectEqualSlices(u32, &.{ 1, 4 }, res.packages[3].deps);
}

test "a lowered choice drops the dependencies of the version it replaced" {
    // First pass expands mid 1.5.0 (needs extra); `pin` then forces mid 1.0.0.
    const ix: TestIndex = .{ .entries = &.{
        .{ "mid", &.{ .{ .version = ver("1.0.0") }, .{ .version = ver("1.5.0"), .deps = &.{dependsOn("extra", "1")} } } },
        .{ "pin", &.{.{ .version = ver("1.0.0"), .deps = &.{dependsOn("mid", "=1.0.0")} }} },
        .{ "extra", &.{.{ .version = ver("1.0.0") }} },
    } };
    const root: Release = .{ .version = ver("1.0.0"), .deps = &.{ dependsOn("mid", "1"), dependsOn("pin", "1") } };
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    var res = try resolve(testing.allocator, ix.index(), "app", &root, &sink);
    defer res.deinit();
    try expectPackages(res, &.{ "app 1.0.0", "mid 1.0.0", "pin 1.0.0" });
}

test "cycle is E0906 naming the loop and located at the root dependency" {
    const f: diag.FileId = @fromBackingInt(@intCast(3));
    const ix: TestIndex = .{ .entries = &.{
        .{ "b", &.{.{ .version = ver("0.1.0"), .deps = &.{.{ .name = "c" }} }} },
        .{ "c", &.{.{ .version = ver("0.1.0"), .deps = &.{.{ .name = "a" }} }} },
    } };
    const root: Release = .{ .version = ver("0.1.0"), .deps = &.{.{ .name = "b", .span = .{ .file = f, .start = 40, .end = 41 } }} };
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    try testing.expectError(error.Unresolvable, resolve(testing.allocator, ix.index(), "a", &root, &sink));
    const ds = sink.finish();
    try testing.expectEqual(1, ds.len);
    try testing.expectEqual(.E0906, ds[0].code.?);
    try testing.expectEqualStrings("package dependency cycle: a 0.1.0 -> b 0.1.0 -> c 0.1.0 -> a 0.1.0", ds[0].message);
    try testing.expectEqual(40, ds[0].primarySpan().?.start);
}

test "conflict is E0910 listing both requirement chains" {
    const f: diag.FileId = @fromBackingInt(@intCast(1));
    const ix: TestIndex = .{ .entries = &.{
        .{ "web", &.{.{ .version = ver("2.1.0"), .deps = &.{dependsOn("json", "^1.4")} }} },
        .{ "db", &.{.{ .version = ver("0.3.0"), .deps = &.{dependsOn("json", "~1.2.0")} }} },
        .{ "json", &.{ .{ .version = ver("1.2.9") }, .{ .version = ver("1.5.0") } } },
    } };
    var web = dependsOn("web", "2");
    web.span = .{ .file = f, .start = 10, .end = 13 };
    var db = dependsOn("db", "0.3");
    db.span = .{ .file = f, .start = 20, .end = 22 };
    const root: Release = .{ .version = ver("1.0.0"), .deps = &.{ web, db } };
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    try testing.expectError(error.Unresolvable, resolve(testing.allocator, ix.index(), "app", &root, &sink));
    const ds = sink.finish();
    try testing.expectEqual(1, ds.len);
    try testing.expectEqual(.E0910, ds[0].code.?);
    try testing.expectEqualStrings("no version of `json` 1.x satisfies every requirement on it", ds[0].message);
    try testing.expectEqual(2, ds[0].help.len);
    try testing.expectEqualStrings("app 1.0.0 -> web 2.1.0 requires json ^1.4", ds[0].help[0]);
    try testing.expectEqualStrings("app 1.0.0 -> db 0.3.0 requires json ~1.2.0", ds[0].help[1]);
    try testing.expectEqual(2, ds[0].spans.len);
    try testing.expectEqual(10, ds[0].primarySpan().?.start);
}

test "requirement no release matches is E0910 listing what exists" {
    const ix: TestIndex = .{ .entries = &.{.{ "util", &.{.{ .version = ver("1.4.0") }} }} };
    const f: diag.FileId = @fromBackingInt(@intCast(2));
    var util = dependsOn("util", "^2.0");
    util.span = .{ .file = f, .start = 5, .end = 9 };
    var ghost = dependsOn("ghost", "1");
    ghost.span = .{ .file = f, .start = 30, .end = 35 };
    const root: Release = .{ .version = ver("0.1.0"), .deps = &.{ util, ghost } };
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    try testing.expectError(error.Unresolvable, resolve(testing.allocator, ix.index(), "app", &root, &sink));
    const ds = sink.finish();
    try testing.expectEqual(2, ds.len);
    try testing.expectEqualStrings("no version of `util` matches ^2.0 (available: 1.4.0)", ds[0].message);
    try testing.expectEqualStrings("app 0.1.0 requires util ^2.0", ds[0].help[0]);
    try testing.expectEqualStrings("no package named `ghost` is available", ds[1].message);
}

test "resolution is deterministic regardless of index and declaration order" {
    const a_rel = [_]Release{ .{ .version = ver("1.0.0"), .deps = &.{dependsOn("z", "1")} }, .{ .version = ver("1.2.0"), .deps = &.{ dependsOn("z", "1"), dependsOn("y", "1") } } };
    const a_rev = [_]Release{ a_rel[1], a_rel[0] };
    const z_rel = [_]Release{ .{ .version = ver("1.0.0") }, .{ .version = ver("1.1.0") } };
    const z_rev = [_]Release{ z_rel[1], z_rel[0] };
    const y_rel = [_]Release{.{ .version = ver("1.0.0"), .deps = &.{dependsOn("z", "~1.0")} }};
    const ix1: TestIndex = .{ .entries = &.{ .{ "a", &a_rel }, .{ "z", &z_rel }, .{ "y", &y_rel } } };
    const ix2: TestIndex = .{ .entries = &.{ .{ "y", &y_rel }, .{ "z", &z_rev }, .{ "a", &a_rev } } };
    const root1: Release = .{ .version = ver("1.0.0"), .deps = &.{ dependsOn("a", "1"), dependsOn("z", "1") } };
    const root2: Release = .{ .version = ver("1.0.0"), .deps = &.{ dependsOn("z", "1"), dependsOn("a", "1") } };
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    var r1 = try resolve(testing.allocator, ix1.index(), "app", &root1, &sink);
    defer r1.deinit();
    var r2 = try resolve(testing.allocator, ix2.index(), "app", &root2, &sink);
    defer r2.deinit();
    try expectPackages(r1, &.{ "a 1.2.0", "app 1.0.0", "y 1.0.0", "z 1.0.0" });
    try testing.expectEqual(r1.root, r2.root);
    for (r1.packages, r2.packages) |p, q| {
        try testing.expectEqualStrings(p.name, q.name);
        try testing.expect(p.version.order(q.version) == .eq);
        try testing.expectEqualSlices(u32, p.deps, q.deps);
    }
}

test "manifest dependencies become root requirements" {
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    var m = try manifest.load(testing.allocator,
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\edition = "2026"
        \\[dependencies]
        \\math = "1.2"
        \\local = { path = "../local" }
        \\
    , @fromBackingInt(@intCast(0)), &sink);
    defer m.deinit();
    const deps = [_]Dep{ .fromManifest(m.dependencies[0], @fromBackingInt(@intCast(0))), .fromManifest(m.dependencies[1], @fromBackingInt(@intCast(0))) };
    try testing.expect(deps[0].requirement.matches(ver("1.9.0")) and !deps[0].requirement.matches(ver("1.1.0")));
    try testing.expect(deps[1].accepts(ver("7.0.0")) and deps[1].accepts(ver("0.1.0-dev")));
    try testing.expect(deps[0].span.?.end > deps[0].span.?.start);
}

test "a pinned path dependency resolves to its prerelease" {
    const ix: TestIndex = .{ .entries = &.{.{ "local", &.{.{ .version = ver("0.1.0-dev") }} }} };
    const root: Release = .{ .version = ver("1.0.0"), .deps = &.{.{ .name = "local", .pinned = true }} };
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    var res = try resolve(testing.allocator, ix.index(), "app", &root, &sink);
    defer res.deinit();
    try expectPackages(res, &.{ "app 1.0.0", "local 0.1.0" });
    try testing.expectEqualStrings("dev", res.packages[1].version.pre);
}

test "a requirement moves to an older line when the newest one conflicts" {
    const ix: TestIndex = .{ .entries = &.{
        .{ "a", &.{.{ .version = ver("1.0.0"), .deps = &.{dependsOn("json", ">=1.0, <2.1")} }} },
        .{ "json", &.{ .{ .version = ver("1.0.0") }, .{ .version = ver("2.0.0") }, .{ .version = ver("2.1.0") } } },
    } };
    const root: Release = .{ .version = ver("1.0.0"), .deps = &.{ dependsOn("a", "1"), dependsOn("json", "^2.1") } };
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    var res = try resolve(testing.allocator, ix.index(), "app", &root, &sink);
    defer res.deinit();
    try expectPackages(res, &.{ "a 1.0.0", "app 1.0.0", "json 1.0.0", "json 2.1.0" });
    try testing.expectEqualSlices(u32, &.{2}, res.packages[0].deps);
    try testing.expectEqualSlices(u32, &.{ 0, 3 }, res.packages[1].deps);
}

test "an oscillating choice is E0910 with the chains of the unsettled slots" {
    // shortcut: no backtracking, so x 1.4.0 with z 1.2.0 is not found (known limitation).
    const f: diag.FileId = @fromBackingInt(@intCast(4));
    const ix: TestIndex = .{ .entries = &.{
        .{ "x", &.{ .{ .version = ver("1.4.0") }, .{ .version = ver("1.5.0"), .deps = &.{dependsOn("p", "1")} } } },
        .{ "p", &.{.{ .version = ver("1.0.0"), .deps = &.{dependsOn("z", "=1.0")} }} },
        .{ "z", &.{ .{ .version = ver("1.0.0"), .deps = &.{dependsOn("x", "<1.5")} }, .{ .version = ver("1.2.0") } } },
    } };
    var x = dependsOn("x", "^1");
    x.span = .{ .file = f, .start = 10, .end = 11 };
    var z = dependsOn("z", "^1");
    z.span = .{ .file = f, .start = 20, .end = 21 };
    const root: Release = .{ .version = ver("1.0.0"), .deps = &.{ x, z } };
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    try testing.expectError(error.Unresolvable, resolve(testing.allocator, ix.index(), "app", &root, &sink));
    const ds = sink.finish();
    try testing.expect(ds.len != 0);
    for (ds) |d| {
        try testing.expectEqual(.E0910, d.code.?);
        try testing.expect(std.mem.startsWith(u8, d.message, "dependency resolution did not converge: `"));
        try testing.expect(d.help.len != 0);
        try testing.expect(d.primarySpan() != null);
    }
}
