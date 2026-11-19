//! Typed `u32` index wrappers (B.1): compiler data refers to other data by
//! `u32` index into flat arrays, never by pointer. Each `Index(tag)` is a
//! distinct type, so a node index cannot be passed where a token index is
//! expected.

const std = @import("std");

/// Returns a distinct non-exhaustive `enum(u32)` index type named by `tag`.
/// `.none` (all ones) is the reserved "no index" sentinel, so an optional
/// index costs 4 bytes instead of 8.
pub fn Index(comptime tag: @EnumLiteral()) type {
    return enum(u32) {
        none = std.math.maxInt(u32),
        _,

        const Self = @This();

        /// The tag this index type was created with.
        pub const kind = tag;

        /// Wraps array position `i`. Asserts `i` fits and is not the sentinel.
        pub inline fn from(i: usize) Self {
            std.debug.assert(i < std.math.maxInt(u32));
            return @fromBackingInt(@intCast(i));
        }

        /// Returns the array position. Asserts `self` is not `.none`.
        pub inline fn int(self: Self) u32 {
            std.debug.assert(self != .none);
            return @backingInt(self);
        }

        /// Returns `null` for `.none`, else `self`.
        pub fn unwrap(self: Self) ?Self {
            return if (self == .none) null else self;
        }
    };
}

test "index types are distinct and round-trip" {
    const Node = Index(.node);
    const Token = Index(.token);
    try std.testing.expect(Node != Token);
    try std.testing.expect(Node == Index(.node));
    try std.testing.expectEqual(4, @sizeOf(Node));

    const n: Node = .from(42);
    try std.testing.expectEqual(42, n.int());
    try std.testing.expectEqual(n, n.unwrap().?);
    try std.testing.expectEqual(null, Node.none.unwrap());
}
