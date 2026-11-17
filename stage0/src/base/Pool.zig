//! Fixed-size thread pool for the parallel pipeline stages (B.1): files,
//! modules, functions. `--jobs n` (§13.7) means `n` threads run jobs in
//! total: the thread calling `run` is worker 0 and `n - 1` persistent
//! threads are workers 1..n-1. Jobs receive their worker id so they can use
//! per-thread state such as `Arena.PerThread` without locking.
//!
//! `run` is a parallel for: it hands out indices `0..n` through an atomic
//! counter and returns once every job has finished. Which worker runs which
//! index is not deterministic; jobs must write results by index.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Pool = @This();

io: Io,
threads: []std.Thread,
mutex: Io.Mutex = .init,
/// Signalled when a new batch is published or on shutdown.
wake: Io.Condition = .init,
/// Signalled when the last worker leaves the current batch.
idle: Io.Condition = .init,
batch: ?*Batch = null,
/// Bumped once per published batch; workers compare it to the last one seen.
generation: u64 = 0,
/// Workers (excluding the caller) not yet finished with the current batch.
busy: usize = 0,
shutdown: bool = false,

const Batch = struct {
    next: std.atomic.Value(usize) = .init(0),
    len: usize,
    context: *const anyopaque,
    func: *const fn (*const anyopaque, worker: u32, index: usize) void,

    fn drain(b: *Batch, worker: u32) void {
        while (true) {
            const i = b.next.fetchAdd(1, .monotonic);
            if (i >= b.len) return;
            b.func(b.context, worker, i);
        }
    }
};

/// Starts `job_count - 1` worker threads; `null` means one per logical
/// CPU. The pool must not move after `init` (workers hold its address), so
/// it is initialised in place.
pub fn init(pool: *Pool, gpa: Allocator, io: Io, job_count: ?u32) !void {
    const n: usize = job_count orelse @intCast(std.Thread.getCpuCount() catch 1);
    std.debug.assert(n >= 1);
    pool.* = .{ .io = io, .threads = try gpa.alloc(std.Thread, n - 1) };
    errdefer gpa.free(pool.threads);
    for (pool.threads, 1..) |*t, id| {
        t.* = std.Thread.spawn(.{}, workerMain, .{ pool, @as(u32, @intCast(id)) }) catch |err| {
            pool.threads = pool.threads[0 .. id - 1];
            pool.deinit(gpa);
            return err;
        };
    }
}

/// Stops and joins every worker. `gpa` must be the one passed to `init`.
pub fn deinit(pool: *Pool, gpa: Allocator) void {
    pool.mutex.lockUncancelable(pool.io);
    pool.shutdown = true;
    pool.mutex.unlock(pool.io);
    pool.wake.broadcast(pool.io);
    for (pool.threads) |t| t.join();
    gpa.free(pool.threads);
    pool.* = undefined;
}

/// Number of workers, including the calling thread: the valid worker ids
/// are `0..jobs()`.
pub fn jobs(pool: *const Pool) u32 {
    return @intCast(pool.threads.len + 1);
}

/// Calls `func(context, worker, i)` for every `i` in `0..n` across all
/// workers and returns when all calls have returned. Call from one thread
/// at a time, and not from inside a job.
pub fn run(
    pool: *Pool,
    n: usize,
    context: anytype,
    comptime func: fn (@TypeOf(context), worker: u32, index: usize) void,
) void {
    const C = @TypeOf(context);
    const Erased = struct {
        fn call(ctx: *const anyopaque, worker: u32, index: usize) void {
            func(@as(*const C, @ptrCast(@alignCast(ctx))).*, worker, index);
        }
    };
    var batch: Batch = .{ .len = n, .context = @ptrCast(&context), .func = Erased.call };
    if (n == 0) return;
    if (pool.threads.len == 0 or n == 1) return batch.drain(0);

    pool.mutex.lockUncancelable(pool.io);
    std.debug.assert(pool.batch == null and pool.busy == 0);
    pool.batch = &batch;
    pool.generation += 1;
    pool.busy = pool.threads.len;
    pool.mutex.unlock(pool.io);
    pool.wake.broadcast(pool.io);

    batch.drain(0);

    pool.mutex.lockUncancelable(pool.io);
    while (pool.busy != 0) pool.idle.waitUncancelable(pool.io, &pool.mutex);
    pool.batch = null;
    pool.mutex.unlock(pool.io);
}

fn workerMain(pool: *Pool, id: u32) void {
    var seen: u64 = 0;
    pool.mutex.lockUncancelable(pool.io);
    defer pool.mutex.unlock(pool.io);
    while (true) {
        while (pool.generation == seen and !pool.shutdown) pool.wake.waitUncancelable(pool.io, &pool.mutex);
        if (pool.shutdown) return;
        seen = pool.generation;
        const batch = pool.batch.?;
        pool.mutex.unlock(pool.io);
        batch.drain(id);
        pool.mutex.lockUncancelable(pool.io);
        pool.busy -= 1;
        if (pool.busy == 0) pool.idle.signal(pool.io);
    }
}

const testing = std.testing;

test "runs and joins N jobs, each exactly once" {
    for ([_]u32{ 1, 2, 8 }) |j| {
        var pool: Pool = undefined;
        try pool.init(testing.allocator, testing.io, j);
        defer pool.deinit(testing.allocator);
        try testing.expectEqual(j, pool.jobs());

        // Several batches on the same pool exercise worker re-arming.
        for ([_]usize{ 0, 1, 7, 1000 }) |n| {
            const hits = try testing.allocator.alloc(std.atomic.Value(u32), n);
            defer testing.allocator.free(hits);
            @memset(hits, .init(0));
            var bad_worker: std.atomic.Value(bool) = .init(false);
            const Ctx = struct { hits: []std.atomic.Value(u32), bad: *std.atomic.Value(bool), jobs: u32 };
            pool.run(n, Ctx{ .hits = hits, .bad = &bad_worker, .jobs = j }, struct {
                fn f(c: Ctx, worker: u32, i: usize) void {
                    if (worker >= c.jobs) c.bad.store(true, .monotonic);
                    _ = c.hits[i].fetchAdd(1, .monotonic);
                }
            }.f);
            for (hits) |h| try testing.expectEqual(1, h.load(.monotonic));
            try testing.expect(!bad_worker.load(.monotonic));
        }
    }
}

test "uses more than one worker when jobs block" {
    var pool: Pool = undefined;
    try pool.init(testing.allocator, testing.io, 4);
    defer pool.deinit(testing.allocator);

    // Every job waits until all 4 have started, which only terminates if
    // 4 workers run concurrently.
    var started: std.atomic.Value(u32) = .init(0);
    pool.run(4, &started, struct {
        fn f(s: *std.atomic.Value(u32), _: u32, _: usize) void {
            _ = s.fetchAdd(1, .acq_rel);
            while (s.load(.acquire) < 4) std.atomic.spinLoopHint();
        }
    }.f);
    try testing.expectEqual(4, started.load(.monotonic));
}
