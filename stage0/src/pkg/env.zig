//! Build environments (§13.3): the named sets of compile-time settings that `@env`
//! reads (§8.6) and that select checked arithmetic (§6.4), runtime contracts (§9.5),
//! `@todo_err` (§9.2) and the `@hash` name table (§8.6.1).
//!
//! `resolve` merges, in order, the built-in defaults, the manifest's `[env.<name>]`
//! table and the `--set key=value` command-line overrides, typing every value as it
//! goes. Reserved keys have fixed types; any other key is a user key and must be a TOML
//! string, boolean, integer or float.
//!
//! `Env.hash` is the environment's part of every build cache key; its encoding is
//! specified on that function and must never change without bumping `hash_version`.

const std = @import("std");
const toml = @import("../toml/toml.zig");
const manifest = @import("manifest.zig");
const diag = @import("../diag/diag.zig");

/// The environment `pyro build`/`run` use when no `--env` is given.
pub const default_build = "dev";
/// The environment `pyro test`/`bench` use when no `--env` is given.
pub const default_test = "test";
/// The environment `--release` selects.
pub const release = "prod";

/// Values of the reserved key `opt_level` (§13.9).
pub const OptLevel = enum { O0, O1, O2, O3, Oz };

/// Values of the reserved key `debug_info` (§13.11).
pub const DebugInfo = enum { full, lines, none };

/// An environment value, typed as its TOML value. `@env` yields `str`, `bool`, `i64`
/// or `f64` respectively (§8.6).
pub const Value = union(enum) {
    string: []const u8,
    boolean: bool,
    integer: i64,
    float: f64,
};

/// The reserved keys of §13.3. They always exist because they have defaults.
/// Field names are the key names; field order is the hash order (see `Env.hash`).
pub const Reserved = struct {
    opt_level: OptLevel,
    /// Checked build: overflow and shift traps (§6.4).
    debug_assertions: bool,
    /// Runtime contract checks (§9.5).
    contracts: bool,
    /// `@todo_err` allowed (§9.2).
    allow_todo_err: bool,
    debug_info: DebugInfo,
    /// Instrument unsafe code (§12.8).
    sanitize: bool,
    /// Cross-module optimization.
    lto: bool,
    /// Keep the `@hash` name table (§8.6.1).
    hash_names: bool,

    /// The §13.3 `dev` column.
    pub const dev: Reserved = .{ .opt_level = .O0, .debug_assertions = true, .contracts = true, .allow_todo_err = true, .debug_info = .full, .sanitize = false, .lto = false, .hash_names = true };
    /// The §13.3 `test` column.
    pub const @"test": Reserved = .{ .opt_level = .O1, .debug_assertions = true, .contracts = true, .allow_todo_err = true, .debug_info = .full, .sanitize = false, .lto = false, .hash_names = true };
    /// The §13.3 `prod` column.
    pub const prod: Reserved = .{ .opt_level = .O3, .debug_assertions = false, .contracts = false, .allow_todo_err = false, .debug_info = .lines, .sanitize = false, .lto = true, .hash_names = false };

    /// Built-in defaults for `name`. §13.3 gives only `dev`, `test` and `prod`;
    /// a user-defined environment (`[env.staging]`) starts from `dev`, the default
    /// build environment.
    pub fn defaults(name: []const u8) Reserved {
        if (std.mem.eql(u8, name, "test")) return .@"test";
        if (std.mem.eql(u8, name, "prod")) return .prod;
        return .dev;
    }

    /// The value of reserved `key`, or null if `key` is not reserved. Enum-typed keys
    /// read as their TOML string.
    pub fn get(r: Reserved, key: []const u8) ?Value {
        inline for (reserved_names, reserved_types) |name, T| if (std.mem.eql(u8, key, name)) {
            const x = @field(r, name);
            return if (T == bool) .{ .boolean = x } else .{ .string = @tagName(x) };
        };
        return null;
    }

    /// Sets `key` to `v` if `key` is reserved; false if it is not.
    fn set(r: *Reserved, key: []const u8, v: Value) error{WrongType}!bool {
        inline for (reserved_names, reserved_types) |name, T| if (std.mem.eql(u8, key, name)) {
            @field(r, name) = if (T == bool) switch (v) {
                .boolean => |b| b,
                else => return error.WrongType,
            } else switch (v) {
                .string => |s| std.meta.stringToEnum(T, s) orelse return error.WrongType,
                else => return error.WrongType,
            };
            return true;
        };
        return false;
    }

    /// What reserved `key` accepts, for messages.
    fn expected(key: []const u8) []const u8 {
        inline for (reserved_names, reserved_types) |name, T| if (std.mem.eql(u8, key, name)) {
            if (T == bool) return "`true` or `false`";
            return comptime blk: {
                var s: []const u8 = "one of ";
                for (std.meta.fieldNames(T), 0..) |n, i| s = s ++ (if (i == 0) "" else ", ") ++ "\"" ++ n ++ "\"";
                break :blk s;
            };
        };
        unreachable;
    }
};

const reserved_names = @typeInfo(Reserved).@"struct".field_names;
const reserved_types = @typeInfo(Reserved).@"struct".field_types;

/// A user key and its value.
pub const UserKey = struct {
    key: []const u8,
    value: Value,
};

/// Bumped whenever the encoding `Env.hash` digests changes, so old caches miss.
pub const hash_version = 1;

/// A SHA-256 digest of an environment's contents.
pub const Hash = [std.crypto.hash.sha2.Sha256.digest_length]u8;

/// A resolved build environment.
pub const Env = struct {
    /// The selected environment's name. Not part of `hash`.
    name: []const u8,
    reserved: Reserved,
    /// User keys, sorted by key bytes, each key once.
    user: []const UserKey,

    /// The value `@env(key)` reads, or null if `key` is absent (E0807 at the use).
    pub fn get(e: Env, key: []const u8) ?Value {
        if (e.reserved.get(key)) |v| return v;
        for (e.user) |u| if (std.mem.eql(u8, u.key, key)) return u.value;
        return null;
    }

    /// The environment's part of the build cache key (§13.3, B.4): equal for equal
    /// contents on every host, different whenever any key or value differs. The name
    /// is excluded: two environments with the same contents compile identically.
    ///
    /// Encoding (all integers little-endian): `"pyro-env"`, `hash_version` as u32,
    /// then every key, the reserved keys in `Reserved` field order followed by the
    /// user keys in `user` (sorted) order, each as: key length u32, key bytes, a tag
    /// byte, and the value:
    /// - `'s'` string: length u64, then the bytes (enum keys use their tag name);
    /// - `'b'` boolean: one byte, 0 or 1;
    /// - `'i'` integer: i64;
    /// - `'f'` float: the IEEE 754 binary64 bits as u64, every NaN as 0x7ff8000000000000.
    pub fn hash(e: Env) Hash {
        var h: std.crypto.hash.sha2.Sha256 = .init(.{});
        h.update("pyro-env");
        hashInt(&h, u32, hash_version);
        inline for (reserved_names) |name| hashEntry(&h, name, e.reserved.get(name).?);
        for (e.user) |u| hashEntry(&h, u.key, u.value);
        return h.finalResult();
    }
};

fn hashInt(h: *std.crypto.hash.sha2.Sha256, comptime T: type, x: T) void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, x, .little);
    h.update(&buf);
}

fn hashEntry(h: *std.crypto.hash.sha2.Sha256, key: []const u8, v: Value) void {
    hashInt(h, u32, @intCast(key.len));
    h.update(key);
    switch (v) {
        .string => |s| {
            h.update("s");
            hashInt(h, u64, s.len);
            h.update(s);
        },
        .boolean => |b| h.update(if (b) "b\x01" else "b\x00"),
        .integer => |i| {
            h.update("i");
            hashInt(h, i64, i);
        },
        .float => |f| {
            h.update("f");
            hashInt(h, u64, if (std.math.isNan(f)) 0x7ff8000000000000 else @bitCast(f));
        },
    }
}

/// Errors `resolve` returns.
pub const ResolveError = error{ InvalidEnv, OutOfMemory };

/// Resolves environment `name`: the built-in defaults (`Reserved.defaults`), then
/// `[env.<name>]` of `m` (if given), then each `--set key=value` of `sets` in order.
///
/// A `--set` value that is a TOML string, boolean, integer or float literal has that
/// type (`--set lto=true`, `--set n=3`, `--set s="a b"`); any other text is a string
/// (`--set opt_level=O2`).
///
/// Every problem is emitted to `sink` before failing with `error.InvalidEnv`: a
/// mistyped manifest value is E0909 at its span in `file` (the manifest's id); an
/// unknown environment name or a bad `--set` is command-line input and has no code.
/// The result is allocated in `arena` and borrows strings from `m` and `sets`.
pub fn resolve(
    arena: std.mem.Allocator,
    m: ?*const manifest.Manifest,
    file: diag.FileId,
    name: []const u8,
    sets: []const []const u8,
    sink: *diag.Sink,
) ResolveError!Env {
    var r: Resolver = .{ .arena = arena, .sink = sink, .reserved = .defaults(name) };

    var table: ?*const toml.Table = null;
    if (m) |mm| for (mm.envs) |e| {
        if (std.mem.eql(u8, e.name, name)) table = e.table;
    };
    if (table) |t| {
        for (t.entries.keys(), t.entries.values()) |key, *e| {
            const v = scalar(&e.value) orelse {
                try r.fail(.E0909, .{ .file = file, .start = e.value.span.start, .end = e.value.span.end }, "`env.{s}.{s}` must be a string, boolean, integer or float", .{ name, key });
                continue;
            };
            r.put(key, v) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.WrongType => try r.fail(.E0909, .{ .file = file, .start = e.value.span.start, .end = e.value.span.end }, "`env.{s}.{s}` must be {s}", .{ name, key, Reserved.expected(key) }),
            };
        }
    } else if (!std.mem.eql(u8, name, "dev") and !std.mem.eql(u8, name, "test") and !std.mem.eql(u8, name, "prod")) {
        try r.fail(null, null, "unknown build environment `{s}`: it is not `dev`, `test` or `prod`, and `pyro.toml` has no `[env.{s}]`", .{ name, name });
    }

    for (sets) |arg| {
        const eq = std.mem.indexOfScalar(u8, arg, '=') orelse 0;
        if (eq == 0) {
            try r.fail(null, null, "`--set` expects `key=value`, got `{s}`", .{arg});
            continue;
        }
        const key = arg[0..eq];
        r.put(key, try parseSetValue(arena, arg[eq + 1 ..])) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.WrongType => try r.fail(null, null, "`--set {s}`: `{s}` must be {s}", .{ arg, key, Reserved.expected(key) }),
        };
    }

    if (r.failed) return error.InvalidEnv;
    std.mem.sort(UserKey, r.user.items, {}, struct {
        fn lessThan(_: void, a: UserKey, b: UserKey) bool {
            return std.mem.lessThan(u8, a.key, b.key);
        }
    }.lessThan);
    return .{ .name = name, .reserved = r.reserved, .user = r.user.items };
}

const Resolver = struct {
    arena: std.mem.Allocator,
    sink: *diag.Sink,
    reserved: Reserved,
    user: std.ArrayList(UserKey) = .empty,
    failed: bool = false,

    /// Sets `key`, replacing an earlier value.
    fn put(r: *Resolver, key: []const u8, v: Value) error{ WrongType, OutOfMemory }!void {
        if (try r.reserved.set(key, v)) return;
        for (r.user.items) |*u| if (std.mem.eql(u8, u.key, key)) {
            u.value = v;
            return;
        };
        try r.user.append(r.arena, .{ .key = key, .value = v });
    }

    fn fail(r: *Resolver, code: ?diag.DiagCode, span: ?diag.Span, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        r.failed = true;
        const msg = try std.fmt.allocPrint(r.arena, fmt, args);
        if (span) |s| return r.sink.emitAt(code.?, s, msg);
        try r.sink.emit(.{ .code = code, .severity = .@"error", .message = msg });
    }
};

/// `v` as an environment value, or null if TOML gives it another type.
fn scalar(v: *const toml.Value) ?Value {
    return switch (v.data) {
        .string => |s| .{ .string = s },
        .boolean => |b| .{ .boolean = b },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .datetime, .array, .table => null,
    };
}

/// Types a `--set` value: a single TOML scalar literal keeps its type; any other text
/// is the string itself.
fn parseSetValue(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}!Value {
    const src = try std.fmt.allocPrint(arena, "v = {s}\n", .{text});
    var tdiag: toml.Diagnostic = undefined;
    var doc = toml.parse(arena, src, &tdiag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .string = text },
    };
    defer doc.deinit();
    if (doc.root.entries.count() != 1) return .{ .string = text }; // e.g. "1\nw = 2"
    const v = scalar(doc.root.get("v") orelse return .{ .string = text }) orelse return .{ .string = text };
    return switch (v) {
        .string => |s| .{ .string = try arena.dupe(u8, s) },
        else => v,
    };
}

// --- tests ---------------------------------------------------------------------

const testing = std.testing;
const test_file: diag.FileId = @fromBackingInt(@intCast(3));

/// Resolves `name` against `toml_src` (a manifest, or null) and `sets`; returns the
/// env (in `arena`) and fails the test if any diagnostic was emitted.
fn resolveOk(arena: std.mem.Allocator, toml_src: ?[]const u8, name: []const u8, sets: []const []const u8) !Env {
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    var mm: ?manifest.Manifest = if (toml_src) |s| try manifest.load(arena, s, test_file, &sink) else null;
    const e = try resolve(arena, if (mm) |*p| p else null, test_file, name, sets, &sink);
    try testing.expect(!sink.hasErrors());
    return e;
}

const pkg_head = "[package]\nname = \"a\"\nversion = \"1.0.0\"\nedition = \"2026\"\n";

test "defaults match the §13.3 table exactly" {
    const cols = [_]struct { []const u8, [8][]const u8 }{
        .{ "dev", .{ "O0", "true", "true", "true", "full", "false", "false", "true" } },
        .{ "test", .{ "O1", "true", "true", "true", "full", "false", "false", "true" } },
        .{ "prod", .{ "O3", "false", "false", "false", "lines", "false", "true", "false" } },
    };
    const keys = [_][]const u8{ "opt_level", "debug_assertions", "contracts", "allow_todo_err", "debug_info", "sanitize", "lto", "hash_names" };
    try testing.expectEqual(keys.len, reserved_names.len);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for (cols) |col| {
        const e = try resolveOk(arena.allocator(), null, col[0], &.{});
        try testing.expectEqual(0, e.user.len);
        for (keys, col[1]) |k, want| {
            const got = switch (e.get(k).?) {
                .string => |s| s,
                .boolean => |b| if (b) "true" else "false",
                else => unreachable,
            };
            try testing.expectEqualStrings(want, got);
        }
    }
    try testing.expectEqual(Reserved.dev, (try resolveOk(arena.allocator(), pkg_head ++ "[env.staging]\n", "staging", &.{})).reserved);
}

test "the §13.2 sample merges [env.<name>] over the defaults" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const src = pkg_head ++
        \\[env.dev]
        \\db_url = "sqlite://dev.db"
        \\log_level = "trace"
        \\
        \\[env.prod]
        \\opt_level = "O3"
        \\db_url = "postgres://db.internal:5432/core"
        \\log_level = "error"
        \\
    ;
    const dev = try resolveOk(arena.allocator(), src, "dev", &.{});
    try testing.expectEqual(Reserved.dev, dev.reserved);
    try testing.expectEqualStrings("sqlite://dev.db", dev.get("db_url").?.string);
    try testing.expectEqualStrings("trace", dev.get("log_level").?.string);

    const prod = try resolveOk(arena.allocator(), src, "prod", &.{});
    try testing.expectEqual(Reserved.prod, prod.reserved);
    try testing.expectEqualStrings("db_url", prod.user[0].key); // sorted
    try testing.expectEqualStrings("error", prod.get("log_level").?.string);
    try testing.expect(prod.get("missing") == null);

    const t = try resolveOk(arena.allocator(), src, "test", &.{});
    try testing.expectEqual(Reserved.@"test", t.reserved);
    try testing.expectEqual(0, t.user.len);
}

test "--set overrides [env.prod]" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const src = pkg_head ++ "[env.prod]\nopt_level = \"O2\"\nlog_level = \"error\"\nlto = false\nn = 1\n";
    const e = try resolveOk(arena.allocator(), src, "prod", &.{
        "opt_level=Oz",   "log_level=warn",  "lto=true",   "n=3",    "ratio=1.5",
        "quoted=\"a b\"", "date=2024-01-01", "list=[1,2]", "empty=", "n=4",
    });
    try testing.expectEqual(.Oz, e.reserved.opt_level);
    try testing.expect(e.reserved.lto);
    try testing.expect(!e.reserved.contracts); // untouched prod default
    try testing.expectEqualStrings("warn", e.get("log_level").?.string);
    try testing.expectEqual(4, e.get("n").?.integer); // last --set wins
    try testing.expectEqual(1.5, e.get("ratio").?.float);
    try testing.expectEqualStrings("a b", e.get("quoted").?.string);
    try testing.expectEqualStrings("2024-01-01", e.get("date").?.string);
    try testing.expectEqualStrings("[1,2]", e.get("list").?.string);
    try testing.expectEqualStrings("", e.get("empty").?.string);
}

test "wrong reserved type in [env.*] is E0909 at the value" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const src = pkg_head ++ "[env.prod]\nopt_level = 3\ndebug_info = \"partial\"\nlto = \"yes\"\nok = 1\nlist = [1]\nwhen = 2024-01-01\n";
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    var m = try manifest.load(arena.allocator(), src, test_file, &sink);
    try testing.expectError(error.InvalidEnv, resolve(arena.allocator(), &m, test_file, "prod", &.{}, &sink));
    const ds = sink.finish();
    const want = [_][]const u8{ "3", "\"partial\"", "\"yes\"", "[1]", "2024-01-01" };
    try testing.expectEqual(want.len, ds.len);
    for (ds, want) |d, w| {
        try testing.expectEqual(diag.DiagCode.E0909, d.code.?);
        const s = d.primarySpan().?;
        try testing.expectEqualStrings(w, src[s.start..s.end]);
    }
    try testing.expectEqualStrings("`env.prod.opt_level` must be one of \"O0\", \"O1\", \"O2\", \"O3\", \"Oz\"", ds[0].message);
    try testing.expectEqualStrings("`env.prod.lto` must be `true` or `false`", ds[2].message);
    try testing.expectEqualStrings("`env.prod.list` must be a string, boolean, integer or float", ds[3].message);
}

test "wrong reserved type, bad --set and unknown env are rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    try testing.expectError(error.InvalidEnv, resolve(arena.allocator(), null, test_file, "dev", &.{ "contracts=maybe", "opt_level=3", "noequals", "=1" }, &sink));
    try testing.expectError(error.InvalidEnv, resolve(arena.allocator(), null, test_file, "staging", &.{}, &sink));
    const ds = sink.finish(); // sorted by message: none has a location
    const want = [_][]const u8{
        "`--set contracts=maybe`: `contracts` must be `true` or `false`",
        "`--set opt_level=3`: `opt_level` must be one of \"O0\", \"O1\", \"O2\", \"O3\", \"Oz\"",
        "`--set` expects `key=value`, got `=1`",
        "`--set` expects `key=value`, got `noequals`",
        "unknown build environment `staging`: it is not `dev`, `test` or `prod`, and `pyro.toml` has no `[env.staging]`",
    };
    try testing.expectEqual(want.len, ds.len);
    for (ds, want) |d, w| {
        try testing.expect(d.code == null and d.severity == .@"error" and d.primarySpan() == null);
        try testing.expectEqualStrings(w, d.message);
    }
}

test "env hash: stable, name- and order-independent, changes with any key" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = (try resolveOk(a, null, "dev", &.{ "x=1", "s=\"v\"" })).hash();

    // Pinned: cache keys must not change silently across hosts or refactors.
    // Changing this value requires bumping `hash_version`.
    try testing.expectEqualStrings("07375ce48e7ea5155feee16216d160c0a1a40b777a8955bb65aea4593383558c", &std.fmt.bytesToHex((try resolveOk(a, null, "dev", &.{})).hash(), .lower));

    try testing.expectEqualSlices(u8, &base, &(try resolveOk(a, null, "dev", &.{ "s=v", "x=1" })).hash());
    try testing.expectEqualSlices(u8, &base, &(try resolveOk(a, pkg_head ++ "[env.ci]\ns = \"v\"\nx = 1\n", "ci", &.{})).hash());
    // -nan and nan are the same value.
    try testing.expectEqualSlices(u8, &(try resolveOk(a, null, "dev", &.{"f=nan"})).hash(), &(try resolveOk(a, null, "dev", &.{"f=-nan"})).hash());

    const changed = [_][]const []const u8{
        &.{ "x=1", "s=\"v\"", "opt_level=O1" },
        &.{ "x=1", "s=\"v\"", "debug_assertions=false" },
        &.{ "x=1", "s=\"v\"", "contracts=false" },
        &.{ "x=1", "s=\"v\"", "allow_todo_err=false" },
        &.{ "x=1", "s=\"v\"", "debug_info=lines" },
        &.{ "x=1", "s=\"v\"", "sanitize=true" },
        &.{ "x=1", "s=\"v\"", "lto=true" },
        &.{ "x=1", "s=\"v\"", "hash_names=false" },
        &.{ "x=2", "s=\"v\"" }, // value
        &.{ "x=1.0", "s=\"v\"" }, // type
        &.{ "x=\"1\"", "s=\"v\"" },
        &.{ "x=true", "s=\"v\"" },
        &.{ "y=1", "s=\"v\"" }, // key renamed
        &.{"s=\"v\""}, // key removed
        &.{ "x=1", "s=\"v\"", "t=" }, // key added
        &.{ "x=1", "s=\"v1\"" },
        &.{ "x=1", "s=\"\"" },
        &.{ "x1=", "s=\"v\"" }, // no ambiguity between key and value bytes
    };
    var seen: std.ArrayList(Hash) = .empty;
    try seen.append(a, base);
    for (changed) |sets| {
        const h = (try resolveOk(a, null, "dev", sets)).hash();
        for (seen.items) |prev| try testing.expect(!std.mem.eql(u8, &prev, &h));
        try seen.append(a, h);
    }
}
