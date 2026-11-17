//! Per-thread task arenas (§10.2 rule 6, B.5.2): `spawn` copies its task frame
//! into the spawning thread's arena instead of the heap. Nurseries nest LIFO
//! on a thread, so the arena is a bump allocator that `nursery_end` resets to
//! the mark `nursery_begin` took.

const std = @import("std");
const trap = @import("../trap.zig");

/// Virtual address space reserved per thread. Pages are committed by the OS on
/// first touch, so a thread that only spawns a few tasks uses a few pages.
pub const reserve_bytes = 64 * 1024 * 1024;

/// A bump allocator over one reservation that is never freed or grown.
pub const Arena = struct {
    buf: []u8 = &.{},
    top: usize = 0,

    /// Returns `size` bytes aligned to `alignment` (a power of two). Reserves
    /// the backing memory on first use; traps `capacity` when it is full.
    pub fn alloc(a: *Arena, size: usize, alignment: usize) [*]u8 {
        if (a.buf.len == 0) a.reserve();
        const start = std.mem.alignForward(usize, @intFromPtr(a.buf.ptr) + a.top, alignment) - @intFromPtr(a.buf.ptr);
        if (start > a.buf.len or a.buf.len - start < size)
            trap.trap(.capacity, "task arena exhausted (too many live spawns on one thread)", @src().file, @src().line);
        a.top = start + size;
        return a.buf.ptr + start;
    }

    fn reserve(a: *Arena) void {
        a.buf = std.heap.page_allocator.alloc(u8, reserve_bytes) catch
            trap.trap(.out_of_memory, "cannot reserve task arena", @src().file, @src().line);
        _ = reservations.fetchAdd(1, .monotonic);
    }
};

/// The calling thread's arena.
pub threadlocal var current: Arena = .{};

/// Number of arena reservations made by all threads. The only allocation the
/// scheduler makes per thread; tests use it to prove spawns do not allocate.
pub var reservations: std.atomic.Value(usize) = .init(0);

test "alloc aligns, bumps and resets to a mark" {
    var a: Arena = .{};
    const p = a.alloc(3, 1);
    const q = a.alloc(8, 8);
    try std.testing.expect(@intFromPtr(q) % 8 == 0);
    try std.testing.expect(@intFromPtr(q) >= @intFromPtr(p) + 3);
    const mark = a.top;
    _ = a.alloc(100, 16);
    a.top = mark;
    try std.testing.expectEqual(q + 8, a.alloc(1, 1));
    std.heap.page_allocator.free(a.buf);
}
