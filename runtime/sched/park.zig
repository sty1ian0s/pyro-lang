//! Park/unpark: the blocking primitive under `Channel.recv` and
//! `Sender.send` (§10.4). It has futex semantics over a 32-bit word that the
//! channel advances on every change:
//!
//!     // waiter                              // waker
//!     seen = @atomicLoad(word)               change the channel state
//!     if (cannot proceed with `seen`)        @atomicStore(word, word + 1)
//!         pyro_rt_park(word, seen, ...)      pyro_rt_unpark(word, n)
//!
//! `pyro_rt_park` re-checks `word == seen` under the scheduler lock, and
//! `pyro_rt_unpark` takes that lock after the store, so a wake-up between the
//! waiter's load and its park is never lost. Callers loop: a parked thread
//! returns when woken, which does not by itself mean it can proceed.
//!
//! A parked task holds its thread (tasks are not stackful), so parking while
//! tasks are queued and no thread is idle starts another worker. Parking feeds
//! the deadlock detector (deadlock.zig).
// shortcut: one global list of parked waiters, scanned by unpark; key waiters
// by word in a hash table if programs park many tasks at once.

const std = @import("std");
const c = std.c;
const pool = @import("pool.zig");
const deadlock = @import("deadlock.zig");

/// A parked thread. Lives on the parked thread's stack while it waits.
pub const Waiter = struct {
    next: ?*Waiter = null,
    word: *const u32,
    cond: c.pthread_cond_t = .{},
    woken: bool = false,
    /// `pool.current_task` of the parked context; 0 is the main body.
    task: u32,
    /// The blocked operation and its source location, for the deadlock report.
    what: []const u8,
    file: []const u8,
    line: u32,
};

/// Every parked waiter, oldest first. Guarded by the scheduler lock.
pub var parked: struct { first: ?*Waiter = null, last: ?*Waiter = null } = .{};

/// Blocks the calling task until `pyro_rt_unpark(word, ...)` wakes it, unless
/// `word` no longer holds `expected`, in which case it returns at once.
/// `what` (e.g. "recv on `jobs`"), `file` and `line` are Pyro `str`
/// values describing the blocked operation for a deadlock trap. Traps
/// `deadlock` if this leaves no task able to run.
pub export fn pyro_rt_park(
    word: *const u32,
    expected: u32,
    what_ptr: [*]const u8,
    what_len: usize,
    file_ptr: [*]const u8,
    file_len: usize,
    line: u32,
) callconv(.c) void {
    pool.lock();
    defer pool.unlock();
    if (@atomicLoad(u32, word, .seq_cst) != expected) return;

    var w: Waiter = .{
        .word = word,
        .task = pool.current_task,
        .what = what_ptr[0..what_len],
        .file = file_ptr[0..file_len],
        .line = line,
    };
    if (parked.last) |l| l.next = &w else parked.first = &w;
    parked.last = &w;

    if (pool.queued() and deadlock.idle == 0) pool.addWorker();
    deadlock.sleep();
    while (!w.woken) std.debug.assert(c.pthread_cond_wait(&w.cond, &pool.mutex) == .SUCCESS);
}

/// Wakes up to `max` tasks parked on `word`, oldest first, and returns how
/// many it woke.
pub export fn pyro_rt_unpark(word: *const u32, max: u32) callconv(.c) u32 {
    pool.lock();
    defer pool.unlock();
    var woken: u32 = 0;
    var prev: ?*Waiter = null;
    var it = parked.first;
    while (it) |w| {
        it = w.next;
        if (woken == max or w.word != word) {
            prev = w;
            continue;
        }
        if (prev) |p| p.next = w.next else parked.first = w.next;
        if (parked.last == w) parked.last = prev;
        w.woken = true;
        deadlock.wake(); // counted runnable now, before it gets the lock back
        std.debug.assert(c.pthread_cond_signal(&w.cond) == .SUCCESS);
        woken += 1;
    }
    return woken;
}

test "park returns at once when the word already changed" {
    const word: u32 = 1;
    pyro_rt_park(&word, 0, "recv".ptr, 4, "t.pr".ptr, 4, 1);
}

test "unpark with no waiters wakes nothing" {
    const word: u32 = 0;
    try std.testing.expectEqual(0, pyro_rt_unpark(&word, 1));
}

fn parkThenCount(word: *u32, done: *std.atomic.Value(u32)) void {
    pyro_rt_park(word, 0, "recv".ptr, 4, "t.pr".ptr, 4, 1);
    _ = done.fetchAdd(1, .monotonic);
}

test "unpark wakes at most max waiters, oldest first" {
    // Two plain threads stand in for tasks: count them active while they live.
    pool.lock();
    deadlock.wake();
    deadlock.wake();
    pool.unlock();
    defer {
        pool.lock();
        deadlock.sleep();
        deadlock.sleep();
        pool.unlock();
    }
    var word: u32 = 0;
    var done: std.atomic.Value(u32) = .init(0);
    var threads: [2]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, parkThenCount, .{ &word, &done });
    // Wait until both are parked.
    while (true) {
        pool.lock();
        var n: usize = 0;
        var it = parked.first;
        while (it) |w| : (it = w.next) n += 1;
        pool.unlock();
        if (n == 2) break;
        try std.Thread.yield();
    }
    // Waking without changing the word: the waiters return anyway (callers loop).
    try std.testing.expectEqual(1, pyro_rt_unpark(&word, 1));
    try std.testing.expectEqual(1, pyro_rt_unpark(&word, 5));
    for (threads) |t| t.join();
    try std.testing.expectEqual(2, done.load(.monotonic));
    try std.testing.expectEqual(null, parked.first);
}
