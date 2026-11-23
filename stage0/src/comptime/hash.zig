//! `@hash` (§8.6.1): the 64-bit FNV-1a hash of a string's UTF-8 bytes,
//! and the program's name table, which maps each hash to the one string
//! hashed to it. Two distinct strings with the same hash are E0811.
//! `std.hash.fnv1a64` (§14.9) is the same function at runtime.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The 64-bit FNV-1a hash of `bytes`.
pub fn fnv1a64(bytes: []const u8) u64 {
    return std.hash.Fnv1a_64.hash(bytes);
}

/// Every distinct string hashed in a program, by hash. Lives in an arena:
/// entries are never removed.
pub const Names = struct {
    map: std.AutoHashMapUnmanaged(u64, []const u8) = .empty,

    /// Records `s` and returns its hash, or `error.Collision` when a
    /// different string already has it (`collidesWith` names that one).
    /// `arena` holds the table and a copy of `s`.
    pub fn record(t: *Names, arena: Allocator, s: []const u8) (Allocator.Error || error{Collision})!u64 {
        const h = fnv1a64(s);
        const gop = try t.map.getOrPut(arena, h);
        if (!gop.found_existing) {
            gop.value_ptr.* = try arena.dupe(u8, s);
        } else if (!std.mem.eql(u8, gop.value_ptr.*, s)) return error.Collision;
        return h;
    }

    /// The string hashed to `h`, if any (`std.debug.name_of`).
    pub fn nameOf(t: *const Names, h: u64) ?[]const u8 {
        return t.map.get(h);
    }
};

const testing = std.testing;

test "fnv1a64 vectors" {
    try testing.expectEqual(0xcbf29ce484222325, fnv1a64(""));
    try testing.expectEqual(0xaf63dc4c8601ec8c, fnv1a64("a"));
    try testing.expectEqual(0x85944171f73967e8, fnv1a64("foobar"));
    try testing.expectEqual(0x19fb901921bfa625, fnv1a64("orc"));
}

test "Names records strings and detects a collision" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var t: Names = .{};
    const h = try t.record(a, "cfce3eaa8d97691a");
    try testing.expectEqual(0x227addae96a78f3d, h);
    try testing.expectEqual(h, try t.record(a, "cfce3eaa8d97691a"));
    try testing.expectError(error.Collision, t.record(a, "6f98c950bd676157"));
    try testing.expectEqualStrings("cfce3eaa8d97691a", t.nameOf(h).?);
    try testing.expectEqual(null, t.nameOf(fnv1a64("orc")));
}
