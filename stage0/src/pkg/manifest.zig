//! `pyro.toml` package manifests (§13.1, §13.2): schema, validation and the typed view
//! later stages read (environments T030, resolution T031, `no_std` T116, ...).
//!
//! `load` reports every problem it finds to a `diag.Sink`, each at the TOML span it
//! concerns (A.2), before failing. A.3 gives the manifest one code, **E0909**: it is used
//! for unknown keys (as §13.2 requires) and also for every other schema violation
//! (missing or mistyped key, bad package name, bad semver, unsupported target), with a
//! message naming the actual problem.

const std = @import("std");
const toml = @import("../toml/toml.zig");
const semver = @import("semver.zig");
const target = @import("../target.zig");
const diag = @import("../diag/diag.zig");

/// A validated manifest. Strings and tables point into `doc`, which owns them.
pub const Manifest = struct {
    /// The parsed document, kept so tools can edit it in place (`toml.Value.set`).
    doc: toml.Document,
    /// Null only for a virtual workspace root (a manifest with `[workspace]` and no `[package]`).
    package: ?Package,
    dependencies: []const Dependency,
    /// Only for tests, laws and benches.
    dev_dependencies: []const Dependency,
    build: Build,
    gpu: Gpu,
    link: Link,
    /// `[env.<name>]` tables in source order. Their keys are free-form here;
    /// reserved-key typing and merging belong to environments (§13.3).
    envs: []const Env,
    /// `[metadata]`: free-form, never validated.
    metadata: ?*const toml.Table,
    workspace: ?Workspace,

    /// Frees the document and every slice that points into it.
    pub fn deinit(m: *Manifest) void {
        m.doc.deinit();
        m.* = undefined;
    }
};

/// `[package]` (§13.2).
pub const Package = struct {
    /// Matches `[a-z][a-z0-9_]*`, at most 64 bytes.
    name: []const u8,
    version: semver.Version,
    edition: Edition,
    description: ?[]const u8 = null,
    /// An SPDX expression; not checked.
    license: ?[]const u8 = null,
    /// True: core prelude only (§14.1.1).
    no_std: bool = false,
};

/// Language editions this toolchain accepts.
pub const Edition = enum { @"2026" };

pub const Dependency = struct {
    /// The name the package is imported under; a valid package name.
    name: []const u8,
    source: Source,
    /// The dependency's key in the manifest.
    span: toml.Span,
};

/// Where a dependency comes from (§13.4).
pub const Source = union(enum) {
    /// `name = "req"` or `{ version = "req", registry = "..." }`.
    registry: struct {
        requirement: semver.Requirement,
        /// Null for the default registry.
        registry: ?[]const u8 = null,
    },
    /// `{ git = "url", tag | rev | branch = "..." }`; at most one ref.
    git: struct { url: []const u8, ref: GitRef = .default },
    /// `{ path = "dir" }`, relative to the manifest's directory.
    path: []const u8,
};

pub const GitRef = union(enum) {
    /// The remote's default branch.
    default,
    tag: []const u8,
    rev: []const u8,
    branch: []const u8,
};

/// `[build]` (§13.2).
pub const Build = struct {
    /// Empty means the host.
    targets: []const target.Target = &.{},
    /// Null means the toolchain default (B.6).
    backend: ?Backend = null,
    /// Dependencies whose `build.pr` may run (§13.5).
    trusted_build_scripts: []const []const u8 = &.{},
};

/// Code generation backends `build.backend` accepts.
pub const Backend = enum { llvm, native };

/// `[gpu]` (§13.2).
pub const Gpu = struct {
    /// Shader forms to embed; null means the toolchain default.
    backends: ?[]const GpuBackend = null,
    /// CPU fallback when no device (§11.2.3).
    fallback: bool = true,
};

/// Shader forms `gpu.backends` accepts.
pub const GpuBackend = enum { vulkan, metal, webgpu };

/// `[link]` (§13.2).
pub const Link = struct {
    /// Null means the toolchain default.
    mode: ?LinkMode = null,
};

/// Linking modes `link.mode` accepts.
pub const LinkMode = enum { static, dynamic };

/// One `[env.<name>]` table, unvalidated (§13.3).
pub const Env = struct {
    name: []const u8,
    table: *const toml.Table,
    /// The `[env.<name>]` header (or first key).
    span: toml.Span,
};

/// `[workspace]` (§13.2).
pub const Workspace = struct {
    /// Member package directories, relative to the manifest's directory.
    members: []const []const u8,
};

/// Errors `load` returns.
pub const LoadError = error{ InvalidManifest, OutOfMemory };

/// Parses and validates `source`, the text of the `pyro.toml` registered as `file`.
/// Every problem is emitted to `sink` (E0909); if there was any, the result is
/// `error.InvalidManifest`.
pub fn load(gpa: std.mem.Allocator, source: []const u8, file: diag.FileId, sink: *diag.Sink) LoadError!Manifest {
    var tdiag: toml.Diagnostic = undefined;
    var doc = toml.parse(gpa, source, &tdiag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidToml => {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "`pyro.toml` is not valid TOML: {s}", .{tdiag.message}) catch tdiag.message;
            try sink.emitAt(.E0909, .{ .file = file, .start = tdiag.span.start, .end = tdiag.span.end }, msg);
            return error.InvalidManifest;
        },
    };
    errdefer doc.deinit();

    var l: Loader = .{ .arena = doc.allocator(), .file = file, .sink = sink };
    var m: Manifest = .{
        .doc = undefined,
        .package = null,
        .dependencies = &.{},
        .dev_dependencies = &.{},
        .build = .{},
        .gpu = .{},
        .link = .{},
        .envs = &.{},
        .metadata = null,
        .workspace = null,
    };
    const root = doc.root;
    try l.checkKeys(root, &.{ "package", "dependencies", "dev-dependencies", "build", "gpu", "link", "env", "metadata", "workspace" }, "");

    if (root.get("workspace")) |v| if (try l.table(v, "workspace")) |t| {
        try l.checkKeys(t, &.{"members"}, "workspace");
        if (try l.required(t, v, "members", "workspace")) |mv|
            if (try l.strings(mv, "workspace.members")) |s| {
                m.workspace = .{ .members = s };
            };
    };

    if (root.get("package")) |v| {
        if (try l.table(v, "package")) |t| m.package = try l.package(t, v);
    } else if (root.get("workspace") == null) {
        try l.report(.none, "`pyro.toml` has no `[package]` table", .{});
    }

    if (root.get("dependencies")) |v| m.dependencies = try l.dependencies(v, "dependencies");
    if (root.get("dev-dependencies")) |v| m.dev_dependencies = try l.dependencies(v, "dev-dependencies");

    if (root.get("build")) |v| if (try l.table(v, "build")) |t| {
        try l.checkKeys(t, &.{ "targets", "backend", "trusted_build_scripts" }, "build");
        if (t.get("targets")) |tv| if (try l.strings(tv, "build.targets")) |names| {
            const ts = try l.arena.alloc(target.Target, names.len);
            for (names, ts, tv.data.array.items.items) |name, *out, item| {
                out.* = target.parse(name) catch |err| blk: {
                    var buf: [512]u8 = undefined;
                    var w: std.Io.Writer = .fixed(&buf);
                    target.explain(&w, err, name) catch {};
                    try l.report(item.span, "{s}", .{w.buffered()});
                    break :blk undefined;
                };
            }
            m.build.targets = ts;
        };
        if (t.get("backend")) |bv| m.build.backend = try l.enumValue(Backend, bv, "build.backend");
        if (t.get("trusted_build_scripts")) |sv| {
            if (try l.strings(sv, "build.trusted_build_scripts")) |s| m.build.trusted_build_scripts = s;
        }
    };

    if (root.get("gpu")) |v| if (try l.table(v, "gpu")) |t| {
        try l.checkKeys(t, &.{ "backends", "fallback" }, "gpu");
        if (t.get("backends")) |bv| if (try l.array(bv, "gpu.backends")) |items| {
            const bs = try l.arena.alloc(GpuBackend, items.len);
            for (items, bs) |*item, *out| out.* = try l.enumValue(GpuBackend, item, "gpu.backends") orelse undefined;
            m.gpu.backends = bs;
        };
        if (t.get("fallback")) |fv| if (try l.boolean(fv, "gpu.fallback")) |b| {
            m.gpu.fallback = b;
        };
    };

    if (root.get("link")) |v| if (try l.table(v, "link")) |t| {
        try l.checkKeys(t, &.{"mode"}, "link");
        if (t.get("mode")) |mv| m.link.mode = try l.enumValue(LinkMode, mv, "link.mode");
    };

    if (root.get("env")) |v| if (try l.table(v, "env")) |t| {
        var envs: std.ArrayList(Env) = .empty;
        for (t.entries.keys(), t.entries.values()) |name, *e| {
            const where = try std.fmt.allocPrint(l.arena, "env.{s}", .{name});
            if (try l.table(&e.value, where)) |et|
                try envs.append(l.arena, .{ .name = name, .table = et, .span = e.value.span });
        }
        m.envs = envs.items;
    };

    if (root.get("metadata")) |v| m.metadata = try l.table(v, "metadata");

    if (l.failed) return error.InvalidManifest;
    m.doc = doc;
    return m;
}

/// True if `name` is a valid package name: `[a-z][a-z0-9_]*`, at most 64 bytes (§13.2).
pub fn isValidName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or !std.ascii.isLower(name[0])) return false;
    for (name) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_')) return false;
    return true;
}

const Loader = struct {
    arena: std.mem.Allocator,
    file: diag.FileId,
    sink: *diag.Sink,
    failed: bool = false,

    fn report(l: *Loader, span: toml.Span, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        l.failed = true;
        const msg = try std.fmt.allocPrint(l.arena, fmt, args);
        try l.sink.emitAt(.E0909, .{ .file = l.file, .start = span.start, .end = span.end }, msg);
    }

    /// Reports every key of `t` not in `allowed`; `where` names `t` in messages.
    fn checkKeys(l: *Loader, t: *const toml.Table, allowed: []const []const u8, where: []const u8) !void {
        next: for (t.entries.keys(), t.entries.values()) |key, e| {
            for (allowed) |a| if (std.mem.eql(u8, key, a)) continue :next;
            if (where.len == 0)
                try l.report(e.key_span, "unknown key `{s}` in `pyro.toml`", .{key})
            else
                try l.report(e.key_span, "unknown key `{s}` in `[{s}]`", .{ key, where });
        }
    }

    /// The value of required `key` of `t`; reports at `tv` (the table) if missing.
    fn required(l: *Loader, t: *const toml.Table, tv: *const toml.Value, key: []const u8, where: []const u8) !?*toml.Value {
        if (t.get(key)) |v| return v;
        try l.report(tv.span, "`[{s}]` is missing required key `{s}`", .{ where, key });
        return null;
    }

    fn table(l: *Loader, v: *const toml.Value, where: []const u8) !?*toml.Table {
        if (v.data == .table) return v.data.table;
        try l.report(v.span, "`{s}` must be a table", .{where});
        return null;
    }

    fn string(l: *Loader, v: *const toml.Value, where: []const u8) !?[]const u8 {
        if (v.data == .string) return v.data.string;
        try l.report(v.span, "`{s}` must be a string", .{where});
        return null;
    }

    fn boolean(l: *Loader, v: *const toml.Value, where: []const u8) !?bool {
        if (v.data == .boolean) return v.data.boolean;
        try l.report(v.span, "`{s}` must be `true` or `false`", .{where});
        return null;
    }

    fn array(l: *Loader, v: *const toml.Value, where: []const u8) !?[]toml.Value {
        if (v.data == .array and v.data.array.kind == .inline_array) return v.data.array.items.items;
        try l.report(v.span, "`{s}` must be an array", .{where});
        return null;
    }

    /// An array of strings; null (after reporting) if `v` or any element is mistyped.
    fn strings(l: *Loader, v: *const toml.Value, where: []const u8) !?[]const []const u8 {
        const items = try l.array(v, where) orelse return null;
        const out = try l.arena.alloc([]const u8, items.len);
        var ok = true;
        for (items, out) |*item, *s| {
            if (try l.string(item, where)) |text| s.* = text else ok = false;
        }
        return if (ok) out else null;
    }

    fn enumValue(l: *Loader, comptime E: type, v: *const toml.Value, where: []const u8) !?E {
        const text = try l.string(v, where) orelse return null;
        if (std.meta.stringToEnum(E, text)) |e| return e;
        const names = comptime blk: {
            var s: []const u8 = "";
            for (std.meta.fieldNames(E), 0..) |n, i| s = s ++ (if (i == 0) "" else ", ") ++ "\"" ++ n ++ "\"";
            break :blk s;
        };
        try l.report(v.span, "`{s}` is \"{s}\"; expected one of " ++ names, .{ where, text });
        return null;
    }

    fn package(l: *Loader, t: *const toml.Table, tv: *const toml.Value) !?Package {
        try l.checkKeys(t, &.{ "name", "version", "edition", "description", "license", "no_std" }, "package");
        var p: Package = .{ .name = undefined, .version = undefined, .edition = undefined };
        var ok = true;

        if (try l.required(t, tv, "name", "package")) |v| {
            if (try l.string(v, "package.name")) |s| {
                if (isValidName(s)) p.name = s else {
                    try l.reportName(v.span, s);
                    ok = false;
                }
            } else ok = false;
        } else ok = false;

        if (try l.required(t, tv, "version", "package")) |v| {
            if (try l.string(v, "package.version")) |s| {
                if (semver.Version.parse(s)) |ver| p.version = ver else |_| {
                    try l.report(v.span, "`package.version` \"{s}\" is not a Semantic Versioning 2.0 version (`MAJOR.MINOR.PATCH`)", .{s});
                    ok = false;
                }
            } else ok = false;
        } else ok = false;

        if (try l.required(t, tv, "edition", "package")) |v| {
            if (try l.enumValue(Edition, v, "package.edition")) |e| p.edition = e else ok = false;
        } else ok = false;

        if (t.get("description")) |v| p.description = try l.string(v, "package.description");
        if (t.get("license")) |v| p.license = try l.string(v, "package.license");
        if (t.get("no_std")) |v| p.no_std = try l.boolean(v, "package.no_std") orelse false;
        return if (ok) p else null;
    }

    fn reportName(l: *Loader, span: toml.Span, name: []const u8) !void {
        if (name.len > 64)
            try l.report(span, "package name `{s}` is longer than 64 bytes", .{name})
        else
            try l.report(span, "`{s}` is not a valid package name: use a lowercase letter, then lowercase letters, digits or `_`", .{name});
    }

    fn dependencies(l: *Loader, v: *const toml.Value, where: []const u8) ![]const Dependency {
        const t = try l.table(v, where) orelse return &.{};
        var out: std.ArrayList(Dependency) = .empty;
        for (t.entries.keys(), t.entries.values()) |name, *e| {
            if (!isValidName(name)) try l.reportName(e.key_span, name);
            if (try l.dependency(name, &e.value, where)) |src|
                try out.append(l.arena, .{ .name = name, .source = src, .span = e.key_span });
        }
        return out.items;
    }

    fn dependency(l: *Loader, name: []const u8, v: *const toml.Value, section: []const u8) !?Source {
        const where = try std.fmt.allocPrint(l.arena, "{s}.{s}", .{ section, name });
        if (v.data == .string) return .{ .registry = .{ .requirement = try l.requirement(v, where) orelse return null } };
        const t = switch (v.data) {
            .table => |t| t,
            else => {
                try l.report(v.span, "`{s}` must be a version requirement string or a table", .{where});
                return null;
            },
        };

        if (t.get("git")) |gv| {
            try l.checkKeys(t, &.{ "git", "tag", "rev", "branch" }, where);
            const url = try l.string(gv, where) orelse return null;
            var ref: GitRef = .default;
            inline for (.{ "tag", "rev", "branch" }) |k| if (t.get(k)) |rv| {
                const s = try l.string(rv, where) orelse return null;
                if (ref != .default) {
                    try l.report(rv.span, "`{s}` names more than one of `tag`, `rev` and `branch`", .{where});
                    return null;
                }
                ref = @unionInit(GitRef, k, s);
            };
            return .{ .git = .{ .url = url, .ref = ref } };
        }
        if (t.get("path")) |pv| {
            try l.checkKeys(t, &.{"path"}, where);
            return .{ .path = try l.string(pv, where) orelse return null };
        }
        try l.checkKeys(t, &.{ "version", "registry" }, where);
        if (t.get("version") == null) {
            try l.report(v.span, "`{s}` needs one of `version`, `git` or `path`", .{where});
            return null;
        }
        const rv = try l.required(t, v, "version", where) orelse return null;
        const req = try l.requirement(rv, where) orelse return null;
        const registry = if (t.get("registry")) |r| try l.string(r, where) orelse return null else null;
        return .{ .registry = .{ .requirement = req, .registry = registry } };
    }

    fn requirement(l: *Loader, v: *const toml.Value, where: []const u8) !?semver.Requirement {
        const s = try l.string(v, where) orelse return null;
        if (semver.Requirement.parse(s)) |r| return r else |_| {
            try l.report(v.span, "`{s}` has an invalid version requirement \"{s}\"", .{ where, s });
            return null;
        }
    }
};

// --- tests ---------------------------------------------------------------------

const testing = std.testing;

/// The §13.2 sample, verbatim.
const spec_sample =
    \\[package]
    \\name = "engine_core"          # required; [a-z][a-z0-9_]*, ≤ 64 chars
    \\version = "0.4.2"             # required; Semantic Versioning 2.0
    \\edition = "2026"              # required
    \\description = "..."           # optional
    \\license = "MIT OR Apache-2.0" # optional, SPDX expression
    \\no_std = false                # optional; true = core prelude only (§14.1.1)
    \\
    \\[dependencies]
    \\math = "1.2"                                   # registry, caret requirement ^1.2
    \\net = { version = "0.9", registry = "internal" }
    \\gfx = { git = "https://example.com/gfx.git", tag = "v2.0.1" }
    \\local_util = { path = "../util" }
    \\
    \\[dev-dependencies]                             # only for tests, laws, benches
    \\proptest_extras = "0.3"
    \\
    \\[build]
    \\targets = ["x86_64-linux-gnu", "aarch64-macos"]   # default: host
    \\backend = "llvm"                                  # "llvm" | "native" (appendix B.6)
    \\trusted_build_scripts = ["gfx"]                   # dependencies whose build.pr may run
    \\
    \\[gpu]
    \\backends = ["vulkan", "metal", "webgpu"]          # which shader forms to embed
    \\fallback = true                                   # CPU fallback when no device (§11.2.3)
    \\
    \\[link]
    \\mode = "static"                                   # "static" | "dynamic"
    \\
    \\[env.dev]
    \\db_url = "sqlite://dev.db"                        # user key
    \\log_level = "trace"
    \\
    \\[env.prod]
    \\opt_level = "O3"
    \\db_url = "postgres://db.internal:5432/core"
    \\log_level = "error"
    \\
;

const test_file: diag.FileId = @fromBackingInt(@intCast(7));
const a64: [64]u8 = @splat('a');
const a65: [65]u8 = @splat('a');

test "the §13.2 sample loads" {
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    var m = try load(testing.allocator, spec_sample, test_file, &sink);
    defer m.deinit();
    try testing.expect(!sink.hasErrors());

    const p = m.package.?;
    try testing.expectEqualStrings("engine_core", p.name);
    try testing.expectEqual(semver.Version{ .major = 0, .minor = 4, .patch = 2 }, p.version);
    try testing.expectEqual(.@"2026", p.edition);
    try testing.expectEqualStrings("MIT OR Apache-2.0", p.license.?);
    try testing.expect(!p.no_std);

    const deps = m.dependencies;
    try testing.expectEqual(4, deps.len);
    try testing.expectEqualStrings("math", deps[0].name);
    try testing.expect(deps[0].source.registry.requirement.matches(.{ .major = 1, .minor = 9, .patch = 0 }));
    try testing.expect(!deps[0].source.registry.requirement.matches(.{ .major = 2, .minor = 0, .patch = 0 }));
    try testing.expectEqualStrings("internal", deps[1].source.registry.registry.?);
    try testing.expectEqualStrings("https://example.com/gfx.git", deps[2].source.git.url);
    try testing.expectEqualStrings("v2.0.1", deps[2].source.git.ref.tag);
    try testing.expectEqualStrings("../util", deps[3].source.path);
    try testing.expectEqualStrings("proptest_extras", m.dev_dependencies[0].name);

    try testing.expectEqual(2, m.build.targets.len);
    try testing.expectEqualStrings("aarch64-macos", m.build.targets[1].triple());
    try testing.expectEqual(.llvm, m.build.backend.?);
    try testing.expectEqualStrings("gfx", m.build.trusted_build_scripts[0]);
    try testing.expectEqualSlices(GpuBackend, &.{ .vulkan, .metal, .webgpu }, m.gpu.backends.?);
    try testing.expect(m.gpu.fallback);
    try testing.expectEqual(.static, m.link.mode.?);

    try testing.expectEqual(2, m.envs.len);
    try testing.expectEqualStrings("prod", m.envs[1].name);
    try testing.expectEqualStrings("O3", m.envs[1].table.get("opt_level").?.data.string);
    try testing.expect(m.metadata == null and m.workspace == null);
}

test "minimal manifest gets defaults; env and metadata keys are free-form" {
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    var m = try load(testing.allocator,
        \\[package]
        \\name = "a"
        \\version = "1.0.0-rc.1"
        \\edition = "2026"
        \\[env.staging]
        \\anything_goes = 3
        \\[metadata]
        \\x = { y = [1, 2] }
        \\
    , test_file, &sink);
    defer m.deinit();
    try testing.expectEqualStrings("rc.1", m.package.?.version.pre);
    try testing.expectEqual(0, m.dependencies.len);
    try testing.expectEqual(0, m.build.targets.len);
    try testing.expect(m.build.backend == null and m.gpu.backends == null and m.link.mode == null);
    try testing.expect(m.gpu.fallback);
    try testing.expectEqualStrings("staging", m.envs[0].name);
    try testing.expect(m.metadata.?.get("x") != null);
}

test "virtual workspace root needs no [package]" {
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    var m = try load(testing.allocator, "[workspace]\nmembers = [\"core\", \"tools/cli\"]\n", test_file, &sink);
    defer m.deinit();
    try testing.expect(m.package == null);
    try testing.expectEqualStrings("tools/cli", m.workspace.?.members[1]);
}

test "isValidName follows [a-z][a-z0-9_]*, at most 64 bytes" {
    try testing.expect(isValidName("a"));
    try testing.expect(isValidName("engine_core2"));
    try testing.expect(isValidName(&a64));
    try testing.expect(!isValidName(&a65));
    try testing.expect(!isValidName(""));
    try testing.expect(!isValidName("Engine"));
    try testing.expect(!isValidName("2d"));
    try testing.expect(!isValidName("_x"));
    try testing.expect(!isValidName("my-pkg"));
}

/// Loads `source`, expects failure, and checks that exactly the E0909
/// diagnostics at the spans whose text is `spans` (in order) were reported.
fn expectErrors(source: []const u8, spans: []const []const u8) !void {
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    try testing.expectError(error.InvalidManifest, load(testing.allocator, source, test_file, &sink));
    const ds = sink.finish();
    errdefer for (ds) |d| std.debug.print("  {d}..{d}: {s}\n", .{ d.spans[0].span.start, d.spans[0].span.end, d.message });
    try testing.expectEqual(spans.len, ds.len);
    for (ds, spans) |d, want| {
        try testing.expectEqual(diag.DiagCode.E0909, d.code.?);
        const s = d.primarySpan().?;
        try testing.expectEqual(test_file, s.file);
        try testing.expectEqualStrings(want, source[s.start..s.end]);
    }
}

const pkg_head = "[package]\nname = \"a\"\nversion = \"1.0.0\"\nedition = \"2026\"\n";

test "unknown keys are E0909 at the key" {
    try expectErrors("[packages]\nname = \"a\"\n", &.{ "", "packages" }); // "": no [package], reported at offset 0
    try expectErrors(pkg_head ++ "authors = [\"x\"]\n", &.{"authors"});
    try expectErrors(pkg_head ++ "[build]\nopt = 1\n[gpu]\nfallbak = true\n[link]\nkind = \"static\"\n", &.{ "opt", "fallbak", "kind" });
    try expectErrors(pkg_head ++ "[workspace]\nmembers = []\nexclude = []\n", &.{"exclude"});
    try expectErrors(pkg_head ++ "[dependencies]\nx = { path = \"../x\", tag = \"v1\" }\n", &.{"tag"});
    try expectErrors(pkg_head ++ "[dependencies]\nx = { version = \"1\", features = [] }\n", &.{"features"});
}

test "missing required fields are E0909 at the table" {
    try expectErrors("[package]\nname = \"a\"\nedition = \"2026\"\n", &.{"[package]"});
    try expectErrors("[package]\nversion = \"1.0.0\"\n", &.{ "[package]", "[package]" });
    try expectErrors("", &.{""});
    try expectErrors(pkg_head ++ "[workspace]\n", &.{"[workspace]"});
    try expectErrors(pkg_head ++ "[dependencies]\nx = { registry = \"r\" }\n", &.{"{ registry = \"r\" }"});
}

test "bad names, versions and values are E0909 at the value" {
    try expectErrors("[package]\nname = \"Engine\"\nversion = \"1.0.0\"\nedition = \"2026\"\n", &.{"\"Engine\""});
    try expectErrors("[package]\nname = \"" ++ a65 ++ "\"\nversion = \"1.0.0\"\nedition = \"2026\"\n", &.{"\"" ++ a65 ++ "\""});
    try expectErrors("[package]\nname = \"a\"\nversion = \"1.0\"\nedition = \"2026\"\n", &.{"\"1.0\""});
    try expectErrors("[package]\nname = \"a\"\nversion = \"01.0.0\"\nedition = \"2026\"\n", &.{"\"01.0.0\""});
    try expectErrors("[package]\nname = \"a\"\nversion = 1\nedition = \"2025\"\n", &.{ "1", "\"2025\"" });
    try expectErrors(pkg_head ++ "no_std = \"yes\"\n", &.{"\"yes\""});
    try expectErrors(pkg_head ++ "[dependencies]\nx = \">=1.x\"\nBad = \"1\"\ny = 3\n", &.{ "\">=1.x\"", "Bad", "3" });
    try expectErrors(pkg_head ++ "[dependencies]\ng = { git = \"u\", tag = \"t\", rev = \"r\" }\n", &.{"\"r\""});
    try expectErrors(pkg_head ++ "[build]\ntargets = [\"x86_64-linux-gnu\", \"sparc-linux\"]\nbackend = \"gcc\"\n", &.{ "\"sparc-linux\"", "\"gcc\"" });
    try expectErrors(pkg_head ++ "[gpu]\nbackends = [\"vulkan\", \"dx12\"]\nfallback = 1\n", &.{ "\"dx12\"", "1" });
    try expectErrors(pkg_head ++ "[env]\nprod = 1\n", &.{"1"});
    try expectErrors("metadata = 1\n" ++ pkg_head, &.{"1"});
}

test "invalid TOML is E0909 at the syntax error" {
    try expectErrors("[package\n", &.{"\n"});
}

test "messages name the problem" {
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    try testing.expectError(error.InvalidManifest, load(testing.allocator, "[package]\nname = \"a\"\nedition = \"2026\"\nversion = \"x\"\n[link]\nmode = \"shared\"\n", test_file, &sink));
    const ds = sink.finish();
    try testing.expectEqualStrings("`package.version` \"x\" is not a Semantic Versioning 2.0 version (`MAJOR.MINOR.PATCH`)", ds[0].message);
    try testing.expectEqualStrings("`link.mode` is \"shared\"; expected one of \"static\", \"dynamic\"", ds[1].message);

    var sink2: diag.Sink = .init(testing.allocator, testing.io);
    defer sink2.deinit();
    try testing.expectError(error.InvalidManifest, load(testing.allocator, pkg_head ++ "[dependencies]\nx = {}\n", test_file, &sink2));
    try testing.expectEqualStrings("`dependencies.x` needs one of `version`, `git` or `path`", sink2.finish()[0].message);
}
