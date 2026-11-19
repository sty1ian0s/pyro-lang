//! The prelude export list (§14.1) and its `no_std` subset (§14.1.1).
//!
//! Every module implicitly imports these names (§7.8.4). Most are items that
//! `std/prelude.pr` re-exports with `pub use`; the rest are built into the
//! compiler or declared in `std/prelude.pr` itself. The tests check this
//! table against §14.1/§14.1.1 of the spec and against the `std/` sources.

const std = @import("std");

/// What a prelude name denotes.
pub const Kind = enum { type, protocol, function, module };

/// Where a prelude name is declared.
pub const Origin = union(enum) {
    /// Built into the compiler: primitive types (§4), `Handle`, `FieldId`,
    /// the formatting intrinsics (§8) and the module `std`.
    compiler,
    /// A function declared in `std/prelude.pr` itself (`assert`, `vec2`...).
    prelude_file,
    /// A `pub` item of this `std` module, re-exported by `std/prelude.pr`.
    module: []const u8,
};

/// One prelude name.
pub const Entry = struct {
    name: []const u8,
    kind: Kind,
    origin: Origin,
    /// Not in the core prelude of `no_std` packages (§14.1.1).
    hosted_only: bool = false,
};

/// The prelude, in §14.1 order. The integer types `i1`…`i64` and `u1`…`u64`
/// are a family, matched by `isIntTypeName` instead of listed here.
pub const entries = [_]Entry{
    builtin("bool"),
    builtin("isize"),
    builtin("usize"),
    builtin("f32"),
    builtin("f64"),
    builtin("void"),
    builtin("noreturn"),
    builtin("str"),
    builtin("vec"),
    builtin("vec2"),
    builtin("vec3"),
    builtin("vec4"),
    builtin("mask"),
    builtin("Handle"),
    builtin("FieldId"),
    item("Option", .type, "std.core.option"),
    item("Result", .type, "std.core.result"),
    item("Range", .type, "std.core.range"),
    item("RangeInclusive", .type, "std.core.range"),
    item("Order", .type, "std.core.protocols"),
    item("TrapKind", .type, "std.core.trap"),
    item("Bounded", .type, "std.bounded"),
    hosted(item("List", .type, "std.list")),
    hosted(item("Pool", .type, "std.pool")),
    hosted(item("Arena", .type, "std.mem")),
    hosted(item("Channel", .type, "std.core.channel")),
    item("Sender", .type, "std.core.channel"),
    item("Atomic", .type, "std.core.atomic"),
    item("MemOrder", .type, "std.core.atomic"),
    item("StepRange", .type, "std.core.range"),
    item("RevRange", .type, "std.core.range"),

    item("Ord", .protocol, "std.core.protocols"),
    item("From", .protocol, "std.core.protocols"),
    item("Hash", .protocol, "std.core.protocols"),
    item("Display", .protocol, "std.core.protocols"),
    item("Debug", .protocol, "std.core.protocols"),
    item("Indexable", .protocol, "std.core.protocols"),
    item("IndexableMut", .protocol, "std.core.protocols"),

    hosted(.{ .name = "print", .kind = .function, .origin = .compiler }),
    hosted(.{ .name = "eprint", .kind = .function, .origin = .compiler }),
    .{ .name = "format", .kind = .function, .origin = .compiler },
    .{ .name = "assert", .kind = .function, .origin = .prelude_file },
    .{ .name = "vec2", .kind = .function, .origin = .prelude_file },
    .{ .name = "vec3", .kind = .function, .origin = .prelude_file },
    .{ .name = "vec4", .kind = .function, .origin = .prelude_file },

    .{ .name = "std", .kind = .module, .origin = .compiler },
};

/// True for the prelude integer type names `i1`…`i64` and `u1`…`u64`.
pub fn isIntTypeName(name: []const u8) bool {
    if (name.len < 2 or (name[0] != 'i' and name[0] != 'u') or name[1] == '0') return false;
    const bits = std.fmt.parseInt(u8, name[1..], 10) catch return false;
    return bits >= 1 and bits <= 64;
}

fn builtin(name: []const u8) Entry {
    return .{ .name = name, .kind = .type, .origin = .compiler };
}

fn item(name: []const u8, kind: Kind, module: []const u8) Entry {
    return .{ .name = name, .kind = kind, .origin = .{ .module = module } };
}

fn hosted(e: Entry) Entry {
    var h = e;
    h.hosted_only = true;
    return h;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const Io = std.Io;
const Ast = @import("../ast/Ast.zig");
const collect = @import("collect.zig");
const token = @import("../lex/token.zig");
const parseForTest = @import("test_util.zig").parseForTest;

/// Reads `rel` (relative to the repository root) into `a`. The test binary
/// runs from wherever `zig build test` was started inside the repository, so
/// this looks in the current directory and up to 8 parents. Null if absent.
fn readRepoFile(a: std.mem.Allocator, rel: []const u8) !?[]u8 {
    var prefix: std.ArrayList(u8) = .empty;
    for (0..9) |_| {
        const path = try std.mem.concat(a, u8, &.{ prefix.items, rel });
        if (Io.Dir.cwd().readFileAlloc(testing.io, path, a, .limited(1 << 20))) |bytes| {
            return bytes;
        } else |err| switch (err) {
            error.FileNotFound => try prefix.appendSlice(a, "../"),
            else => return err,
        }
    }
    return null;
}

/// Like `readRepoFile`, but fails the test when the file is missing.
fn mustReadRepoFile(a: std.mem.Allocator, rel: []const u8) ![]u8 {
    return (try readRepoFile(a, rel)) orelse {
        std.debug.print("{s} not found; run `zig build test` inside the repository\n", .{rel});
        return error.TestUnexpectedResult;
    };
}

/// The text of the spec section that starts at heading `heading`, up to the
/// next heading.
fn section(md: []const u8, heading: []const u8) []const u8 {
    const start = std.mem.indexOf(u8, md, heading).? + heading.len;
    const end = std.mem.indexOfPos(u8, md, start, "\n#") orelse md.len;
    return md[start..end];
}

/// Appends the leading identifier of every `` `code` `` span in `text` that
/// has no `.` in it and is not a keyword (so `std.math.sqrt(x)` and `use`
/// are skipped): `assert(c, m)` gives `assert`.
fn codeNames(a: std.mem.Allocator, text: []const u8, out: *std.ArrayList([]const u8)) !void {
    var it = std.mem.splitScalar(u8, text, '`');
    _ = it.next(); // text before the first span
    while (it.next()) |span| {
        defer _ = it.next(); // text between spans
        var end: usize = 0;
        while (end < span.len and (std.ascii.isAlphanumeric(span[end]) or span[end] == '_')) end += 1;
        if (end == 0 or std.mem.indexOfScalar(u8, span, '.') != null or token.keyword(span[0..end]) != null) continue;
        try out.append(a, span[0..end]);
    }
}

fn countEntries(name: []const u8, kind: Kind) usize {
    var n: usize = 0;
    for (entries) |e| n += @intFromBool(e.kind == kind and std.mem.eql(u8, e.name, name));
    return n;
}

test "export list matches §14.1" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prelude = section(try mustReadRepoFile(a, "spec/14-standard-library.md"), "## 14.1 Prelude");

    const bullets = [_]struct { []const u8, Kind }{
        .{ "- **Types:**", .type },
        .{ "- **Protocols:**", .protocol },
        .{ "- **Functions:**", .function },
        .{ "- **Modules:**", .module },
    };
    var total: usize = 0;
    for (bullets) |b| {
        const start = std.mem.indexOf(u8, prelude, b[0]).?;
        const end = std.mem.indexOfPos(u8, prelude, start + 1, "\n- ") orelse prelude.len;
        var names: std.ArrayList([]const u8) = .empty;
        try codeNames(a, prelude[start..end], &names);
        for (names.items) |name| {
            if (b[1] == .type and isIntTypeName(name)) continue; // `i1`…`i64`, `u1`…`u64`
            if (countEntries(name, b[1]) != 1) {
                std.debug.print("§14.1 {t} `{s}` is not listed once in `entries`\n", .{ b[1], name });
                return error.TestUnexpectedResult;
            }
            total += 1;
        }
    }
    // Same size and every spec name present once: no extra entries.
    try testing.expectEqual(entries.len, total);
    try testing.expect(isIntTypeName("i1") and isIntTypeName("u64") and isIntTypeName("i17"));
    try testing.expect(!isIntTypeName("i0") and !isIntTypeName("u65") and !isIntTypeName("i08") and !isIntTypeName("int"));
}

test "hosted-only names match §14.1.1" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const core = section(try mustReadRepoFile(a, "spec/14-standard-library.md"), "### 14.1.1 Core prelude (`no_std`)");
    // The first sentence lists what `no_std` packages do not get.
    var names: std.ArrayList([]const u8) = .empty;
    try codeNames(a, core[0..std.mem.indexOf(u8, core, ". ").?], &names);
    try testing.expectEqualStrings("no_std", names.items[0]); // from `no_std = true`

    var hosted_count: usize = 0;
    for (entries) |e| hosted_count += @intFromBool(e.hosted_only);
    try testing.expectEqual(names.items.len - 1, hosted_count);
    for (names.items[1..]) |name| {
        var found = false;
        for (entries) |e| found = found or (e.hosted_only and std.mem.eql(u8, e.name, name));
        if (!found) {
            std.debug.print("§14.1.1 removes `{s}`, but it is not hosted_only\n", .{name});
            return error.TestUnexpectedResult;
        }
    }
}

test "std/prelude.pr re-exports exactly the module items, core before hosted" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ast = try parseForTest(try mustReadRepoFile(a, "std/prelude.pr"));
    defer ast.deinit(testing.allocator);
    const m = try collect.collect(a, "prelude", @fromBackingInt(@intCast(0)), &ast);

    var exported: usize = 0;
    var seen_hosted = false;
    for (m.uses) |u| {
        try testing.expect(u.is_pub);
        for (ast.data(u.node).use_list.items) |it| {
            try testing.expect(ast.data(it).use_item.alias == null);
            const name = ast.tokenSlice(ast.mainToken(it));
            const e = for (entries) |e| {
                if (e.origin == .module and std.mem.eql(u8, e.name, name)) break e;
            } else {
                std.debug.print("std/prelude.pr re-exports `{s}`, which is not a prelude module item\n", .{name});
                return error.TestUnexpectedResult;
            };
            try testing.expectEqualStrings(e.origin.module, u.path);
            // The core prelude comes first, so its subset is a prefix of the file.
            if (seen_hosted and !e.hosted_only) {
                std.debug.print("core item `{s}` follows a hosted-only item in std/prelude.pr\n", .{name});
                return error.TestUnexpectedResult;
            }
            seen_hosted = seen_hosted or e.hosted_only;
            exported += 1;
        }
    }
    var expected: usize = 0;
    for (entries) |e| expected += @intFromBool(e.origin == .module);
    try testing.expectEqual(expected, exported);
}

test "existing std modules declare their prelude items" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var checked: usize = 0;
    for (entries) |e| {
        if (e.origin != .module) continue;
        // `std.core.range` is `std/core/range.pr`.
        const rel = try std.mem.concat(a, u8, &.{ e.origin.module, ".pr" });
        std.mem.replaceScalar(u8, rel[0 .. rel.len - 3], '.', '/');
        // Modules owned by later tasks (`std.list`, `std.mem`...) may not exist yet.
        const src = try readRepoFile(a, rel) orelse continue;
        var ast = try parseForTest(src);
        defer ast.deinit(testing.allocator);
        const m = try collect.collect(a, e.origin.module, @fromBackingInt(@intCast(0)), &ast);
        const it = m.find(e.name) orelse {
            std.debug.print("{s} does not declare `{s}`\n", .{ rel, e.name });
            return error.TestUnexpectedResult;
        };
        try testing.expect(it.is_pub);
        try testing.expect(switch (e.kind) {
            .type => it.kind == .@"enum" or it.kind == .@"struct",
            .protocol => it.kind == .protocol,
            else => false,
        });
        checked += 1;
    }
    // T037 declares Option, Result, the four ranges, Order, the seven protocols; T010 TrapKind.
    try testing.expect(checked >= 15);
}
