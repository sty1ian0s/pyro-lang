//! General-purpose allocator (§14.3): the heap behind `std` containers and
//! `Arena` chunks. It has no user-visible handle.
//!
//! Each thread has its own heap of power-of-two size classes (16 B to 16 KiB).
//! A class carves blocks from 64 KiB spans; the span header names the owning
//! heap, so a block freed on another thread goes back to its owner through a
//! lock-free queue (§14.3) that the owner drains when a free list runs dry.
//! Larger requests map pages directly.
//!
//! Failure has two paths (§9.4, §14.3): `alloc` returns null, the
//! `AllocError` result of the `try_` variants; `allocOrTrap` traps with
//! `out_of_memory`.

const std = @import("std");
const builtin = @import("builtin");
const trap = @import("../trap.zig");
const PageAllocator = std.heap.PageAllocator;

/// Mirror of `std.mem.HeapStats`: what the general allocator did on the
/// calling thread. Byte counts are the requested sizes. A block freed on
/// another thread counts as freed on the freeing thread, so totals across all
/// threads balance. Fits one cache line (D.5).
pub const HeapStats = extern struct {
    bytes_allocated: u64 = 0,
    bytes_freed: u64 = 0,
    allocations: u64 = 0,
    frees: u64 = 0,
};

/// Largest request served from size classes; larger ones map pages.
pub const max_small = 1 << 14;
const min_class_log2 = 4; // 16 B: room for the free-list link
const class_count = std.math.log2_int(usize, max_small) - min_class_log2 + 1;
const span_size = 1 << 16;

/// A free block; the link lives in the block's own memory.
const Block = struct { next: ?*Block };

/// Header at the start of every span. Written once by the owner before any
/// block of the span is handed out.
const Span = struct { owner: *Heap, class: u8 };

const Heap = struct {
    free: [class_count]?*Block = @splat(null),
    /// Uncarved range `[cursor, limit)` of the newest span of each class.
    cursor: [class_count]usize = @splat(0),
    limit: [class_count]usize = @splat(0),
    /// Blocks freed by other threads: a Treiber stack pushed by any thread and
    /// emptied whole by the owner, so pops never race (no ABA).
    remote: std.atomic.Value(?*Block) = .init(null),

    fn allocSmall(h: *Heap, class: u8) ?[*]u8 {
        if (h.pop(class)) |b| return b;
        h.drainRemote();
        if (h.pop(class)) |b| return b;
        const size = classSize(class);
        if (h.cursor[class] == h.limit[class]) {
            const base = PageAllocator.map(span_size, .fromByteUnits(span_size)) orelse return null;
            const span: *Span = @ptrCast(@alignCast(base));
            span.* = .{ .owner = h, .class = class };
            h.cursor[class] = @intFromPtr(base) + std.mem.alignForward(usize, @sizeOf(Span), size);
            h.limit[class] = @intFromPtr(base) + span_size;
        }
        defer h.cursor[class] += size;
        return @ptrFromInt(h.cursor[class]);
    }

    fn pop(h: *Heap, class: u8) ?[*]u8 {
        const b = h.free[class] orelse return null;
        h.free[class] = b.next;
        return @ptrCast(b);
    }

    fn push(h: *Heap, class: u8, b: *Block) void {
        b.next = h.free[class];
        h.free[class] = b;
    }

    fn pushRemote(h: *Heap, b: *Block) void {
        var head = h.remote.load(.monotonic);
        while (true) {
            b.next = head;
            head = h.remote.cmpxchgWeak(head, b, .release, .monotonic) orelse return;
        }
    }

    fn drainRemote(h: *Heap) void {
        var it = h.remote.swap(null, .acquire);
        while (it) |b| {
            it = b.next;
            h.push(spanOf(b).class, b);
        }
    }
};

/// This thread's heap, created on its first allocation.
// shortcut: a heap and its spans are never reclaimed after its thread exits
// (remote frees still land on it); upgrade if short-lived threads allocate.
threadlocal var local: ?*Heap = null;
threadlocal var stats: HeapStats = .{};

/// Failure injection for tests: when non-null, this many more allocations on
/// this thread succeed, then one fails as if the OS refused, and injection
/// turns off.
pub threadlocal var fail_after: ?u64 = null;

fn classOf(size: usize, alignment: usize) ?u8 {
    const n = @max(size, alignment, 1 << min_class_log2);
    if (n > max_small) return null;
    return @intCast(std.math.log2_int_ceil(usize, n) - min_class_log2);
}

fn classSize(class: u8) usize {
    return @as(usize, 1) << @intCast(class + min_class_log2);
}

fn spanOf(p: *anyopaque) *Span {
    return @ptrFromInt(@intFromPtr(p) & ~@as(usize, span_size - 1));
}

fn heap() ?*Heap {
    if (local) |h| return h;
    const mem = PageAllocator.map(@sizeOf(Heap), .of(Heap)) orelse return null;
    const h: *Heap = @ptrCast(@alignCast(mem));
    h.* = .{};
    local = h;
    return h;
}

/// Allocates `size` bytes aligned to `alignment` (a power of two). Returns
/// null when memory is exhausted: the `AllocError` path of `try_` variants.
/// The memory is not zeroed.
pub fn alloc(size: usize, alignment: usize) ?[*]u8 {
    std.debug.assert(std.math.isPowerOfTwo(alignment));
    if (fail_after) |n| {
        fail_after = if (n == 0) null else n - 1;
        if (n == 0) return null;
    }
    const p = if (classOf(size, alignment)) |class|
        (heap() orelse return null).allocSmall(class)
    else
        PageAllocator.map(@max(size, 1), .fromByteUnits(alignment)); // mmap rejects 0
    if (p != null) {
        stats.bytes_allocated += size;
        stats.allocations += 1;
    }
    return p;
}

/// Like `alloc`, but traps with `out_of_memory` instead of returning null:
/// the path of growing operations without a `try_` prefix (§9.4).
pub fn allocOrTrap(size: usize, alignment: usize) [*]u8 {
    return alloc(size, alignment) orelse {
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "allocation of {d} bytes failed", .{size}) catch unreachable;
        trap.trap(.out_of_memory, msg, @src().file, @src().line);
    };
}

/// Frees memory from `alloc` on any thread. `size` and `alignment` must be
/// the values it was allocated with.
pub fn free(ptr: [*]u8, size: usize, alignment: usize) void {
    stats.bytes_freed += size;
    stats.frees += 1;
    if (classOf(size, alignment)) |class| {
        const b: *Block = @ptrCast(@alignCast(ptr));
        const span = spanOf(b);
        std.debug.assert(span.class == class);
        if (span.owner == local) span.owner.push(class, b) else span.owner.pushRemote(b);
    } else {
        PageAllocator.unmap(@alignCast(ptr[0..@max(size, 1)]));
    }
}

/// Allocation counters of the calling thread (`std.mem.heap_stats`).
pub fn heapStats() HeapStats {
    return stats;
}

/// C-ABI entry for growing operations: never returns null; traps with
/// `out_of_memory` on failure.
pub export fn pyro_rt_alloc(size: usize, alignment: usize) callconv(.c) *anyopaque {
    return allocOrTrap(size, alignment);
}

/// C-ABI entry for `try_` variants: null means `AllocError`.
pub export fn pyro_rt_try_alloc(size: usize, alignment: usize) callconv(.c) ?*anyopaque {
    return alloc(size, alignment);
}

/// C-ABI free; `size` and `alignment` are the values passed at allocation.
pub export fn pyro_rt_free(ptr: *anyopaque, size: usize, alignment: usize) callconv(.c) void {
    free(@ptrCast(ptr), size, alignment);
}

/// C-ABI `std.mem.heap_stats`.
pub export fn pyro_rt_heap_stats() callconv(.c) HeapStats {
    return stats;
}

const testing = std.testing;

fn statsDelta(before: HeapStats) HeapStats {
    const now = heapStats();
    return .{
        .bytes_allocated = now.bytes_allocated - before.bytes_allocated,
        .bytes_freed = now.bytes_freed - before.bytes_freed,
        .allocations = now.allocations - before.allocations,
        .frees = now.frees - before.frees,
    };
}

test "every size class and the large path round-trip; heap_stats balances" {
    const before = heapStats();
    const sizes = [_]usize{ 0, 1, 16, 17, 100, 1000, 4096, max_small, max_small + 1, 1 << 20 };
    var ptrs: [sizes.len][*]u8 = undefined;
    for (sizes, &ptrs) |size, *p| {
        p.* = alloc(size, 1).?;
        @memset(p.*[0..size], 0xAB);
    }
    for (sizes, ptrs) |size, p| {
        for (p[0..size]) |byte| try testing.expectEqual(0xAB, byte);
        free(p, size, 1);
    }
    var total: u64 = 0;
    for (sizes) |s| total += s;
    try testing.expectEqual(HeapStats{
        .bytes_allocated = total,
        .bytes_freed = total,
        .allocations = sizes.len,
        .frees = sizes.len,
    }, statsDelta(before));
    try testing.expect(@sizeOf(HeapStats) <= 64);
}

test "alignment is honored and freed blocks are reused" {
    for ([_]usize{ 1, 8, 64, 4096, 1 << 15 }) |alignment| {
        const z = alloc(0, alignment).?;
        free(z, 0, alignment);
        const p = alloc(24, alignment).?;
        try testing.expect(std.mem.isAligned(@intFromPtr(p), alignment));
        free(p, 24, alignment);
    }
    const a = alloc(48, 8).?;
    free(a, 48, 8);
    try testing.expectEqual(a, alloc(48, 8).?);
    free(a, 48, 8);
}

test "a block freed on another thread returns to its owner's free list" {
    const Owner = struct {
        fn run(ok: *bool) !void {
            const p = alloc(200, 8).?;
            const t = try std.Thread.spawn(.{}, free, .{ p, 200, 8 });
            t.join();
            // Fresh heap: the class's free list is empty, so the drained
            // remote block comes back before a new block is carved.
            ok.* = alloc(200, 8).? == p;
        }
    };
    var ok = false;
    const t = try std.Thread.spawn(.{}, Owner.run, .{&ok});
    t.join();
    try testing.expect(ok);
}

test "N-thread cross-thread free stress; heap_stats balance across threads" {
    const n_threads = 8;
    const rounds = 2000;
    const Batch = struct {
        tag: u8,
        ptrs: [16][*]u8,
        sizes: [16]usize,

        fn check(b: *@This()) !void {
            for (b.ptrs, b.sizes) |p, size| {
                for (p[0..size]) |byte| if (byte != b.tag) return error.Corrupted;
                free(p, size, 1);
            }
            free(@ptrCast(b), @sizeOf(@This()), @alignOf(@This()));
        }
    };
    const Shared = struct {
        // Thread i hands each batch to thread i+1, which frees what it gets.
        mailbox: [n_threads]std.atomic.Value(?*Batch) = @splat(.init(null)),
        stats: [n_threads]HeapStats = undefined,
        ok: [n_threads]bool = @splat(false),

        fn worker(s: *@This(), i: usize) void {
            s.ok[i] = if (s.run(i)) true else |_| false;
        }

        fn run(s: *@This(), i: usize) !void {
            var rng = std.Random.DefaultPrng.init(i);
            const random = rng.random();
            for (0..rounds) |round| {
                const b: *Batch = @ptrCast(@alignCast(alloc(@sizeOf(Batch), @alignOf(Batch)).?));
                b.tag = @truncate(i * 31 + round);
                for (&b.ptrs, &b.sizes) |*p, *size| {
                    size.* = random.uintAtMost(usize, if (random.boolean()) 256 else 2 * max_small);
                    p.* = alloc(size.*, 1).?;
                    @memset(p.*[0..size.*], b.tag);
                }
                if (s.mailbox[(i + 1) % n_threads].swap(b, .acq_rel)) |old| try old.check();
                if (s.mailbox[i].swap(null, .acq_rel)) |mine| try mine.check();
            }
            s.stats[i] = heapStats();
        }
    };

    const before = heapStats();
    var s: Shared = .{};
    var threads: [n_threads]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Shared.worker, .{ &s, i });
    for (threads) |t| t.join();
    for (&s.mailbox) |*m| if (m.swap(null, .acquire)) |b| try b.check();

    var sum = statsDelta(before);
    for (s.stats, s.ok) |st, ok| {
        try testing.expect(ok);
        try testing.expect(st.allocations > 0);
        sum.bytes_allocated += st.bytes_allocated;
        sum.bytes_freed += st.bytes_freed;
        sum.allocations += st.allocations;
        sum.frees += st.frees;
    }
    try testing.expectEqual(sum.bytes_allocated, sum.bytes_freed);
    try testing.expectEqual(sum.allocations, sum.frees);
    try testing.expectEqual(n_threads * rounds * 17, sum.allocations);
}

test "failure injection: try path returns null, stats untouched" {
    const before = heapStats();
    fail_after = 1;
    const a = alloc(32, 8).?;
    try testing.expectEqual(null, alloc(32, 8));
    try testing.expectEqual(null, fail_after);
    const b = alloc(32, 8).?;
    free(a, 32, 8);
    free(b, 32, 8);
    try testing.expectEqual(2, statsDelta(before).allocations);
    // A request the OS cannot back takes the same path without injection.
    try testing.expectEqual(null, pyro_rt_try_alloc(1 << 62, 1));
}

extern "c" fn fork() c_int;
extern "c" fn close(fd: std.c.fd_t) c_int;

test "failure injection: trapping path exits 134 with out_of_memory" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var fds: [2]std.c.fd_t = undefined;
    try testing.expectEqual(0, std.c.pipe(&fds));
    const pid = fork();
    try testing.expect(pid >= 0);
    if (pid == 0) {
        _ = close(fds[0]);
        _ = std.c.dup2(fds[1], 2);
        fail_after = 0;
        _ = pyro_rt_alloc(64, 8);
        std.c._exit(0); // not reached
    }
    _ = close(fds[1]);
    defer _ = close(fds[0]);

    var buf: [256]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        const n = std.c.read(fds[0], buf[len..].ptr, buf.len - len);
        if (n <= 0) break;
        len += @intCast(n);
    }
    var status: c_int = 0;
    try testing.expectEqual(pid, std.c.waitpid(pid, &status, 0));
    const s: u32 = @bitCast(status);
    try testing.expect(std.c.W.IFEXITED(s));
    try testing.expectEqual(trap.exit_status, std.c.W.EXITSTATUS(s));
    try testing.expectStringStartsWith(buf[0..len], "trap[out_of_memory]: allocation of 64 bytes failed\n  --> ");
}
