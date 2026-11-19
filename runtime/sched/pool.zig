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
const deadlock = @import("deadlock.zig");
const c = std.c;

/// One spawned call. Lives in the spawning thread's task arena, followed by
/// the copied argument block.
pub const Task = struct {
    next: ?*Task = null,
    func: *const fn (args: ?*anyopaque) callconv(.c) void,
    args: ?*anyopaque,
    group: *Group,
    /// Spawn number, from 1; names the task in a deadlock report.
    id: u32 = 0,
};

/// The join counter of one nursery. Guarded by `mutex`.
pub const Group = struct {
    pending: usize = 0,
    /// The joiner is waiting for `pending` to reach 0 and is counted blocked
    /// by the deadlock detector.
    joiner_waiting: bool = false,
};

/// The scheduler lock; park.zig waits on it.
pub var mutex: c.pthread_mutex_t = .{};
/// Signaled once per queued task and broadcast when a group drains.
var cond: c.pthread_cond_t = .{};
var head: ?*Task = null;
var tail: ?*Task = null;
var started = false;
var thread_count: usize = 0; // 0 until read or set: the hardware thread count
var next_id: u32 = 0;

/// Id of the task running on this thread; 0 for the program's main body.
pub threadlocal var current_task: u32 = 0;

/// Takes the scheduler lock, which also guards parking (park.zig) and the
/// deadlock counters (deadlock.zig).
pub fn lock() void {
    std.debug.assert(c.pthread_mutex_lock(&mutex) == .SUCCESS);
}

pub fn unlock() void {
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

/// Starts one more worker, so queued tasks still run while a parked task holds
/// a thread. Caller holds the lock. Traps `out_of_memory` if the thread cannot
/// start: the queued tasks would never run.
pub fn addWorker() void {
    const t = std.Thread.spawn(.{}, workerMain, .{}) catch
        trap.trap(.out_of_memory, "cannot start a worker thread for a parked task", @src().file, @src().line);
    t.detach();
}

/// Whether a task is waiting to run. Caller holds the lock.
pub fn queued() bool {
    return head != null;
}

/// Queues `task` for any thread to run.
pub fn push(task: *Task) void {
    lock();
    defer unlock();
    task.group.pending += 1;
    next_id +%= 1;
    task.id = next_id;
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
    const outer = current_task;
    current_task = task.id;
    unlock();
    task.func(task.args);
    lock();
    current_task = outer;
    group.pending -= 1;
    if (group.pending == 0) {
        unblockJoiner(group);
        std.debug.assert(c.pthread_cond_broadcast(&cond) == .SUCCESS);
    }
}

/// Counts `group`'s joiner as runnable again if it was waiting. Caller holds
/// the lock.
fn unblockJoiner(group: *Group) void {
    if (!group.joiner_waiting) return;
    group.joiner_waiting = false;
    deadlock.wake();
}

/// Waits for queued work or a draining group as an idle thread. Caller holds
/// the lock.
fn waitIdle() void {
    deadlock.idle += 1;
    std.debug.assert(c.pthread_cond_wait(&cond, &mutex) == .SUCCESS);
    deadlock.idle -= 1;
}

/// Blocks until every task of `group` has finished, running queued tasks
/// (from any nursery) meanwhile.
pub fn join(group: *Group) void {
    lock();
    defer unlock();
    while (group.pending > 0) {
        if (pop()) |task| {
            unblockJoiner(group);
            run(task);
        } else {
            if (!group.joiner_waiting) {
                group.joiner_waiting = true;
                deadlock.sleep();
            }
            waitIdle();
        }
    }
    // A wake-up meant for queued work may have landed here; pass it on.
    if (head != null) std.debug.assert(c.pthread_cond_signal(&cond) == .SUCCESS);
}

fn workerMain() void {
    lock();
    while (true) {
        if (pop()) |task| {
            deadlock.wake();
            run(task);
            deadlock.sleep();
        } else waitIdle();
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
    next_id = 0;
    current_task = 0;
    deadlock.resetAfterFork();
}
