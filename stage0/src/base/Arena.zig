//! Bump-pointer arena with O(1) `reset` (B.1: all compiler data lives in
//! arenas, one per stage and thread). Chunks obtained from the child
//! allocator are kept across `reset` and reused in order, so a stage that
//! resets its arena between inputs stops calling the child allocator once it
//! has seen its largest input. Only `deinit` returns memory.
//!
//! Not thread-safe: give each thread its own arena (see `PerThread`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const Arena = @This();

child: Allocator,
/// First chunk; `reset` rewinds to it.
first: ?*Chunk = null,
/// Chunk currently bumped into.
cur: ?*Chunk = null,
/// Byte offset of the next free byte in `cur`, measured from the chunk start.
end: usize = 0,

/// Header at the start of every chunk; `size` includes the header.
const Chunk = struct {
    next: ?*Chunk,
    size: usize,
};

const header = @sizeOf(Chunk);
const min_chunk = 4096;
const max_growth = 8 << 20;

/// Creates an empty arena; no memory is allocated until first use.
pub fn init(child: Allocator) Arena {
    return .{ .child = child };
}

/// Returns every chunk to the child allocator.
pub fn deinit(self: *Arena) void {
    var it = self.first;
    while (it) |c| {
        it = c.next;
        self.child.rawFree(chunkBytes(c), .of(Chunk), @returnAddress());
    }
    self.* = undefined;
}

/// Invalidates every allocation and rewinds to the first chunk. O(1): no
/// chunk is walked or freed; all chunks are reused by later allocations.
pub fn reset(self: *Arena) void {
    self.cur = self.first;
    self.end = header;
}

/// Returns the `Allocator` interface. `free` and `resize` only take effect
/// on the most recent allocation.
pub fn allocator(self: *Arena) Allocator {
    return .{ .ptr = self, .vtable = &.{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    } };
}

/// Total bytes obtained from the child allocator, headers included.
pub fn capacity(self: *const Arena) usize {
    var n: usize = 0;
    var it = self.first;
    while (it) |c| : (it = c.next) n += c.size;
    return n;
}

fn chunkBytes(c: *Chunk) []u8 {
    return @as([*]u8, @ptrCast(c))[0..c.size];
}

/// Allocates from `cur` without touching other chunks.
fn bump(self: *Arena, len: usize, alignment: Alignment) ?[*]u8 {
    const c = self.cur orelse return null;
    const base = @intFromPtr(c);
    const start = alignment.forward(base + self.end) - base;
    if (start + len > c.size) return null;
    self.end = start + len;
    return @ptrFromInt(base + start);
}

fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    const self: *Arena = @ptrCast(@alignCast(ctx));
    if (self.bump(len, alignment)) |p| return p;
    // Move on to the next chunk retained by an earlier `reset`.
    if (self.cur) |c| if (c.next) |n| {
        self.cur = n;
        self.end = header;
        if (self.bump(len, alignment)) |p| return p;
    };
    // Insert a fresh chunk after `cur`, keeping any retained chunks behind it.
    const prev = if (self.cur) |c| c.size else 0;
    const need = header + len + alignment.toByteUnits();
    const size = @max(need, min_chunk, @min(prev * 2, max_growth));
    const mem = self.child.rawAlloc(size, .of(Chunk), ret_addr) orelse return null;
    const fresh: *Chunk = @ptrCast(@alignCast(mem));
    if (self.cur) |c| {
        fresh.* = .{ .next = c.next, .size = size };
        c.next = fresh;
    } else {
        fresh.* = .{ .next = null, .size = size };
        self.first = fresh;
    }
    self.cur = fresh;
    self.end = header;
    return self.bump(len, alignment).?;
}

/// True if `memory` is the most recent allocation in `cur`.
fn isLast(self: *Arena, memory: []u8) bool {
    const c = self.cur orelse return false;
    return @intFromPtr(memory.ptr) + memory.len == @intFromPtr(c) + self.end;
}

fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    _ = alignment;
    _ = ret_addr;
    const self: *Arena = @ptrCast(@alignCast(ctx));
    if (!self.isLast(memory)) return new_len <= memory.len;
    const start = self.end - memory.len;
    if (start + new_len > self.cur.?.size) return false;
    self.end = start + new_len;
    return true;
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    return if (resize(ctx, memory, alignment, new_len, ret_addr)) memory.ptr else null;
}

fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    _ = alignment;
    _ = ret_addr;
    const self: *Arena = @ptrCast(@alignCast(ctx));
    if (self.isLast(memory)) self.end -= memory.len;
}

/// One arena per worker of a `Pool` (index = the worker id passed to jobs),
/// so a parallel stage allocates without locking.
pub const PerThread = struct {
    arenas: []Arena,

    /// Creates `n` empty arenas; the slice itself comes from `gpa`.
    pub fn init(gpa: Allocator, n: usize) Allocator.Error!PerThread {
        const arenas = try gpa.alloc(Arena, n);
        @memset(arenas, .init(gpa));
        return .{ .arenas = arenas };
    }

    /// Frees every arena and the slice; `gpa` must be the one passed to `init`.
    pub fn deinit(self: *PerThread, gpa: Allocator) void {
        for (self.arenas) |*a| a.deinit();
        gpa.free(self.arenas);
        self.* = undefined;
    }

    /// Returns the arena owned by `worker`.
    pub fn get(self: PerThread, worker: usize) *Arena {
        return &self.arenas[worker];
    }

    /// Resets every arena; O(number of workers).
    pub fn reset(self: PerThread) void {
        for (self.arenas) |*a| a.reset();
    }
};

const testing = std.testing;

test "allocations are aligned and disjoint across chunks" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var prev: ?[]u64 = null;
    for (0..200) |i| {
        const s = try a.alloc(u64, 1 + i % 37);
        @memset(s, i);
        try testing.expect(std.mem.isAligned(@intFromPtr(s.ptr), @alignOf(u64)));
        if (prev) |p| try testing.expectEqual(i - 1, p[0]);
        prev = s;
    }
    const big = try a.alloc(u8, 3 * min_chunk);
    @memset(big, 0xAA);
    try testing.expectEqual(0xAA, big[big.len - 1]);
}

test "reset is O(1): reuses chunks without calling the child allocator" {
    var counting: testing.FailingAllocator = .init(testing.allocator, .{});
    var arena: Arena = .init(counting.allocator());
    defer arena.deinit();
    const a = arena.allocator();

    const pattern = [_]usize{ 100, 5000, 30, 20000, 7, 70000 };
    for (pattern) |n| _ = try a.alloc(u8, n);
    const allocs = counting.allocations;
    const cap = arena.capacity();
    try testing.expect(allocs > 1);

    for (0..3) |_| {
        arena.reset();
        try testing.expectEqual(arena.first, arena.cur);
        try testing.expectEqual(0, counting.deallocations);
        for (pattern) |n| _ = try a.alloc(u8, n);
        try testing.expectEqual(allocs, counting.allocations);
        try testing.expectEqual(cap, arena.capacity());
    }
}

test "free and resize act on the last allocation" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const x = try a.alloc(u8, 16);
    const end = arena.end;
    const y = try a.alloc(u8, 16);
    try testing.expect(a.resize(y, 64));
    try testing.expect(!a.resize(x, 64)); // not last: cannot grow
    try testing.expect(a.resize(x, 8)); // shrinking in place is always fine
    a.free(y.ptr[0..64]);
    try testing.expectEqual(end, arena.end);
}

test "PerThread gives each worker its own arena" {
    var pt: PerThread = try .init(testing.allocator, 3);
    defer pt.deinit(testing.allocator);
    _ = try pt.get(0).allocator().alloc(u8, 10);
    _ = try pt.get(2).allocator().alloc(u8, 10);
    try testing.expect(pt.get(1).first == null);
    pt.reset();
    try testing.expectEqual(pt.get(0).first, pt.get(0).cur);
}
