//! Worker pool behind `nursery`/`spawn` (§10.2 rule 6) and `std.par`'s
//! `threads`/`set_threads` (§14.5). The pool starts on the first nursery with
//! `threads() - 1` workers; the thread waiting at a nursery's end is the last
//! one, because it runs queued tasks itself while it waits (helping join).
//!
//! All scheduler state is guarded by one pthread mutex, so ThreadSanitizer
//! sees every hand-off.
// shortcut: one global FIFO under one lock; switch to per-worker work-stealing
// deques if profiling shows queue contention.
// shortcut: a helping joiner runs the oldest queued task of any nursery, so
// nesting depth on one thread is bounded by queued sibling tasks, not by
// nursery depth (a wide enough tree can overflow the native stack), and a
// joiner whose group drained waits for unrelated nested tasks; restrict helping
// to the joining group's descendants with the work-stealing upgrade.

const std = @import("std");
const trap = @import("../trap.zig");
const c = std.c;

/// One spawned call. Lives in the spawning thread's task arena, followed by
/// the copied argument block.
pub const Task = struct {
    next: ?*Task = null,
    func: *const fn (args: ?*anyopaque) callconv(.c) void,
    args: ?*anyopaque,
    group: *Group,
};

/// The join counter of one nursery. Guarded by `mutex`.
pub const Group = struct {
    pending: usize = 0,
};

var mutex: c.pthread_mutex_t = .{};
/// Signaled once per queued task and broadcast when a group drains.
var cond: c.pthread_cond_t = .{};
var head: ?*Task = null;
var tail: ?*Task = null;
var started = false;
var thread_count: usize = 0; // 0 until read or set: the hardware thread count

fn lock() void {
    std.debug.assert(c.pthread_mutex_lock(&mutex) == .SUCCESS);
}

fn unlock() void {
    std.debug.assert(c.pthread_mutex_unlock(&mutex) == .SUCCESS);
}

fn defaultThreads() usize {
    return std.Thread.getCpuCount() catch 1;
}

/// C ABI of `std.par.threads()`: the configured number of threads that run
/// tasks, one per hardware thread unless `set_threads` changed it.
pub export fn pyro_rt_threads() callconv(.c) usize {
    lock();
    defer unlock();
    if (thread_count == 0) thread_count = defaultThreads();
    return thread_count;
}

/// C ABI of `std.par.set_threads(n)`. Traps (`contract`) after the first
/// nursery has started the pool, or when `n` is 0.
pub export fn pyro_rt_set_threads(n: usize) callconv(.c) void {
    lock();
    defer unlock();
    if (started) trap.trap(.contract, "std.par.set_threads called after the first nursery", @src().file, @src().line);
    if (n == 0) trap.trap(.contract, "std.par.set_threads(0)", @src().file, @src().line);
    thread_count = n;
}

/// Starts the workers on the first call. Called by `nursery_begin`.
pub fn ensureStarted() void {
    lock();
    defer unlock();
    if (started) return;
    started = true;
    if (thread_count == 0) thread_count = defaultThreads();
    for (1..thread_count) |_| {
        // A worker that fails to start only costs parallelism: waiting
        // threads run every task themselves.
        const t = std.Thread.spawn(.{}, workerMain, .{}) catch break;
        t.detach();
    }
}

/// Queues `task` for any thread to run.
pub fn push(task: *Task) void {
    lock();
    defer unlock();
    task.group.pending += 1;
    if (tail) |t| t.next = task else head = task;
    tail = task;
    std.debug.assert(c.pthread_cond_signal(&cond) == .SUCCESS);
}

/// Pops the oldest task. Caller holds the lock.
fn pop() ?*Task {
    const task = head orelse return null;
    head = task.next;
    if (head == null) tail = null;
    return task;
}

/// Runs `task` without the lock, then retires it from its group. Caller holds
/// the lock on entry and on return.
fn run(task: *Task) void {
    const group = task.group; // the frame may be reclaimed once pending drops
    unlock();
    task.func(task.args);
    lock();
    group.pending -= 1;
    if (group.pending == 0) std.debug.assert(c.pthread_cond_broadcast(&cond) == .SUCCESS);
}

/// Blocks until every task of `group` has finished, running queued tasks
/// (from any nursery) meanwhile.
pub fn join(group: *Group) void {
    lock();
    defer unlock();
    while (group.pending > 0) {
        if (pop()) |task| run(task) else std.debug.assert(c.pthread_cond_wait(&cond, &mutex) == .SUCCESS);
    }
    // A wake-up meant for queued work may have landed here; pass it on.
    if (head != null) std.debug.assert(c.pthread_cond_signal(&cond) == .SUCCESS);
}

fn workerMain() void {
    lock();
    while (true) {
        if (pop()) |task| run(task) else std.debug.assert(c.pthread_cond_wait(&cond, &mutex) == .SUCCESS);
    }
}

/// Resets the scheduler in a child of `fork()` (tests only): the workers do not
/// exist there and the lock may have been held by one of them.
pub fn resetAfterFork() void {
    mutex = .{};
    cond = .{};
    head = null;
    tail = null;
    started = false;
    thread_count = 0;
}
