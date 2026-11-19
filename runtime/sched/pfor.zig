//! C ABI of `parallel_for` (§10.3), the lowering target of the P-IR
//! `pfor.begin range, chunk` / `pfor.end` pair (B.5.2). The loop body becomes
//! a chunk function that runs iterations `lo..hi` in order:
//!
//!     pyro_rt_pfor(lo, hi, chunk_hint, body_chunk, &captures);
//!
//! The range is cut into contiguous chunks of at least `min_chunk` iterations
//! (the whole range when it is smaller). Up to `threads()` runners, the calling
//! thread among them, claim chunks from a shared counter, so faster threads
//! take more chunks. The call returns after every chunk has finished.

const std = @import("std");
const pool = @import("pool.zig");
const nursery = @import("nursery.zig");

/// Lower bound on chunk length from §10.3.
pub const min_chunk = 64;

/// Runs iterations `lo..hi` of one chunk, in order. `ctx` is the captures
/// pointer passed to `pyro_rt_pfor`.
pub const ChunkFn = *const fn (ctx: ?*anyopaque, lo: usize, hi: usize) callconv(.c) void;

/// Runs `body` over `begin..end` in parallel chunks of at least
/// `max(chunk_hint, 64)` iterations; `chunk_hint` 0 lets the runtime choose.
pub export fn pyro_rt_pfor(begin: usize, end: usize, chunk_hint: usize, body: ChunkFn, ctx: ?*anyopaque) callconv(.c) void {
    run(begin, end, chunk_hint, body, ctx, pool.pyro_rt_threads());
}

/// Shared by every runner of one loop; lives on the caller's stack, which
/// outlives the runners because `run` joins them before returning.
const Loop = struct {
    next: std.atomic.Value(usize) = .init(0),
    chunks: usize,
    begin: usize,
    len: usize,
    body: ChunkFn,
    ctx: ?*anyopaque,

    /// Claims and runs chunks until none are left. Chunk `i` covers
    /// `len*i/chunks .. len*(i+1)/chunks`, so every chunk has at least
    /// `len/chunks` iterations: no short tail chunk.
    fn drain(l: *Loop) void {
        while (true) {
            const i = l.next.fetchAdd(1, .monotonic);
            if (i >= l.chunks) return;
            l.body(l.ctx, l.begin + bound(l.len, i, l.chunks), l.begin + bound(l.len, i + 1, l.chunks));
        }
    }

    fn bound(len: usize, i: usize, chunks: usize) usize {
        return @intCast(@as(u128, len) * i / chunks);
    }
};

fn runner(args: ?*anyopaque) callconv(.c) void {
    const l: *const *Loop = @ptrCast(@alignCast(args.?));
    l.*.drain();
}

/// `pyro_rt_pfor` with an explicit runner count (`threads` >= 1).
fn run(begin: usize, end: usize, chunk_hint: usize, body: ChunkFn, ctx: ?*anyopaque, threads: usize) void {
    if (end <= begin) return;
    const len = end - begin;
    // About 4 chunks per runner balances uneven iterations without much
    // counter traffic.
    const size = @max(min_chunk, chunk_hint, len / (threads * 4));
    var loop: Loop = .{ .chunks = @max(1, len / size), .begin = begin, .len = len, .body = body, .ctx = ctx };
    const helpers = @min(threads, loop.chunks) - 1;
    if (helpers == 0) return loop.drain();
    const n = nursery.pyro_rt_nursery_begin();
    const lp = &loop;
    for (0..helpers) |_| nursery.pyro_rt_spawn(n, runner, @ptrCast(&lp), @sizeOf(*Loop), @alignOf(*Loop));
    loop.drain();
    nursery.pyro_rt_nursery_end(n);
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;

/// Records how often each index ran, which chunks ran, and on which threads.
const Record = struct {
    begin: usize,
    hits: []std.atomic.Value(u8),
    chunks: []Chunk,
    n_chunks: std.atomic.Value(usize) = .init(0),
    caller: std.Thread.Id,
    off_caller: std.atomic.Value(bool) = .init(false),

    const Chunk = struct { lo: usize, hi: usize };

    fn body(ctx: ?*anyopaque, lo: usize, hi: usize) callconv(.c) void {
        const r: *Record = @ptrCast(@alignCast(ctx.?));
        for (lo..hi) |i| _ = r.hits[i - r.begin].fetchAdd(1, .monotonic);
        r.chunks[r.n_chunks.fetchAdd(1, .monotonic)] = .{ .lo = lo, .hi = hi };
        if (std.Thread.getCurrentId() != r.caller) r.off_caller.store(true, .monotonic);
    }

    fn lessThan(_: void, a: Chunk, b: Chunk) bool {
        return a.lo < b.lo;
    }
};

/// Runs a loop over `begin..begin+len` on `threads` runners and checks that
/// every index ran once, in contiguous chunks of >= 64 that tile the range.
fn expectLoop(begin: usize, len: usize, chunk_hint: usize, threads: usize) !void {
    const a = testing.allocator;
    const hits = try a.alloc(std.atomic.Value(u8), len);
    defer a.free(hits);
    @memset(hits, .init(0));
    const chunks = try a.alloc(Record.Chunk, len / min_chunk + 1);
    defer a.free(chunks);
    var r: Record = .{ .begin = begin, .hits = hits, .chunks = chunks, .caller = std.Thread.getCurrentId() };

    run(begin, begin + len, chunk_hint, Record.body, &r, threads);

    for (hits) |h| try testing.expectEqual(1, h.load(.monotonic));
    const ran = chunks[0..r.n_chunks.load(.monotonic)];
    if (len == 0) return testing.expectEqual(0, ran.len);
    std.mem.sort(Record.Chunk, ran, {}, Record.lessThan);
    var at = begin;
    for (ran) |c| {
        try testing.expectEqual(at, c.lo);
        try testing.expect(c.hi - c.lo >= @min(len, @max(min_chunk, chunk_hint)));
        at = c.hi;
    }
    try testing.expectEqual(begin + len, at);
    if (threads == 1) try testing.expect(!r.off_caller.load(.monotonic));
}

const lens = [_]usize{ 0, 1, 63, 64, 65, 127, 128, 1_000_000 };

test "one thread: each index once, chunks contiguous and >= 64, all on the caller" {
    for (lens) |len| try expectLoop(0, len, 0, 1);
}

test "N threads: each index once, chunks contiguous and >= 64" {
    for ([_]usize{ 2, 8, 64 }) |threads| {
        for (lens) |len| try expectLoop(0, len, 0, threads);
    }
}

test "non-zero range start and chunk hint" {
    try expectLoop(1000, 10_000, 500, 8);
    try expectLoop(7, 65, 1000, 8);
}

test "exported entry uses the pool's thread count" {
    var sum: std.atomic.Value(u64) = .init(0);
    const Sum = struct {
        fn body(ctx: ?*anyopaque, lo: usize, hi: usize) callconv(.c) void {
            const s: *std.atomic.Value(u64) = @ptrCast(@alignCast(ctx.?));
            var part: u64 = 0;
            for (lo..hi) |i| part += i;
            _ = s.fetchAdd(part, .monotonic);
        }
    };
    pyro_rt_pfor(0, 100_000, 0, Sum.body, &sum);
    try testing.expectEqual(100_000 * 99_999 / 2, sum.load(.monotonic));
}

test "nested parallel_for" {
    var sum: std.atomic.Value(u64) = .init(0);
    const Outer = struct {
        fn inner(ctx: ?*anyopaque, lo: usize, hi: usize) callconv(.c) void {
            const s: *std.atomic.Value(u64) = @ptrCast(@alignCast(ctx.?));
            _ = s.fetchAdd(hi - lo, .monotonic);
        }
        fn body(ctx: ?*anyopaque, lo: usize, hi: usize) callconv(.c) void {
            for (lo..hi) |_| run(0, 1000, 0, inner, ctx, 4);
        }
    };
    run(0, 256, 0, Outer.body, &sum, 4);
    try testing.expectEqual(256 * 1000, sum.load(.monotonic));
}
