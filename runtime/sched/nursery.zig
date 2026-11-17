//! C ABI of `nursery { spawn f(args); }` (§10.2), the lowering target of the
//! P-IR `nursery.begin` / `spawn` / `nursery.end` instructions (B.5.2):
//!
//!     n = pyro_rt_nursery_begin();
//!     pyro_rt_spawn(n, f_thunk, &args, @sizeOf(Args), @alignOf(Args));
//!     pyro_rt_nursery_end(n); // join, then reclaim every frame
//!
//! All three calls of one nursery happen on the same thread, in its body.
//! Spawned tasks run on the worker pool or on the thread waiting in
//! `nursery_end`. A trap in a task ends the process (§10.2 rule 7) because
//! `pyro_rt_trap` exits the whole process.

const std = @import("std");
const builtin = @import("builtin");
const pool = @import("pool.zig");
const task_arena = @import("task_arena.zig");

/// One open nursery. Lives in its thread's task arena.
pub const Nursery = struct {
    group: pool.Group = .{},
    /// Arena top before this nursery; restored by `nursery_end`.
    mark: usize,
};

/// Opens a nursery on the calling thread, starting the pool on first use.
pub export fn pyro_rt_nursery_begin() callconv(.c) *Nursery {
    pool.ensureStarted();
    const arena = &task_arena.current;
    const mark = arena.top;
    const n: *Nursery = @ptrCast(@alignCast(arena.alloc(@sizeOf(Nursery), @alignOf(Nursery))));
    n.* = .{ .mark = mark };
    return n;
}

/// Schedules `func(copy of args)` in nursery `n`. The `size` bytes at `args`
/// (aligned to `alignment`, a power of two) are copied into a task frame in
/// the calling thread's arena; `args` may be null when `size` is 0. No heap
/// allocation happens here.
pub export fn pyro_rt_spawn(
    n: *Nursery,
    func: *const fn (args: ?*anyopaque) callconv(.c) void,
    args: ?*const anyopaque,
    size: usize,
    alignment: usize,
) callconv(.c) void {
    const arena = &task_arena.current;
    const task: *pool.Task = @ptrCast(@alignCast(arena.alloc(@sizeOf(pool.Task), @alignOf(pool.Task))));
    var copy: ?*anyopaque = null;
    if (size > 0) {
        const dst = arena.alloc(size, alignment);
        @memcpy(dst[0..size], @as([*]const u8, @ptrCast(args.?))[0..size]);
        copy = dst;
    }
    task.* = .{ .func = func, .args = copy, .group = &n.group };
    pool.push(task);
}

/// Waits for every task spawned in `n` (helping run queued tasks), then frees
/// their frames and `n` itself.
pub export fn pyro_rt_nursery_end(n: *Nursery) callconv(.c) void {
    pool.join(&n.group);
    task_arena.current.top = n.mark;
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;

var tree_tasks: std.atomic.Value(usize) = .init(0);

/// Task body: counts itself, then spawns 10 children down to depth 0.
fn treeTask(args: ?*anyopaque) callconv(.c) void {
    const depth: *const u32 = @ptrCast(@alignCast(args.?));
    _ = tree_tasks.fetchAdd(1, .monotonic);
    if (depth.* == 0) return;
    const n = pyro_rt_nursery_begin();
    const child: u32 = depth.* - 1;
    for (0..10) |_| pyro_rt_spawn(n, treeTask, &child, @sizeOf(u32), @alignOf(u32));
    pyro_rt_nursery_end(n);
}

fn spawnTree(depth: u32) void {
    const n = pyro_rt_nursery_begin();
    pyro_rt_spawn(n, treeTask, &depth, @sizeOf(u32), @alignOf(u32));
    pyro_rt_nursery_end(n);
}

test "10k nested spawns join" {
    tree_tasks.store(0, .monotonic);
    spawnTree(4); // 1 + 10 + 100 + 1000 + 10000 tasks, nested 5 deep
    try testing.expectEqual(11111, tree_tasks.load(.monotonic));
}

fn noop(_: ?*anyopaque) callconv(.c) void {}

// Covers arena growth only: spawn has no allocator parameter, and a stray
// malloc/page_allocator call inside it would not be caught here.
test "spawn makes zero heap allocations; nursery_end reclaims frames" {
    spawnTree(1); // reserve this thread's arena
    const before = task_arena.reservations.load(.monotonic);
    const top = task_arena.current.top;

    const n = pyro_rt_nursery_begin();
    const big: [8]u64 = @splat(7);
    for (0..10_000) |_| pyro_rt_spawn(n, noop, &big, @sizeOf(@TypeOf(big)), @alignOf(u64));
    for (0..10_000) |_| pyro_rt_spawn(n, noop, null, 0, 1);
    pyro_rt_nursery_end(n);

    try testing.expectEqual(before, task_arena.reservations.load(.monotonic));
    try testing.expectEqual(top, task_arena.current.top);
}

fn addArgs(args: ?*anyopaque) callconv(.c) void {
    const a: *const struct { out: *std.atomic.Value(u64), v: u64 } = @ptrCast(@alignCast(args.?));
    _ = a.out.fetchAdd(a.v, .monotonic);
}

test "spawn copies its arguments" {
    var sum: std.atomic.Value(u64) = .init(0);
    const n = pyro_rt_nursery_begin();
    for (1..101) |i| {
        var args: struct { out: *std.atomic.Value(u64), v: u64 } = .{ .out = &sum, .v = i };
        pyro_rt_spawn(n, addArgs, &args, @sizeOf(@TypeOf(args)), @alignOf(@TypeOf(args)));
        args.v = 0; // the task must see the value at spawn time
    }
    pyro_rt_nursery_end(n);
    try testing.expectEqual(5050, sum.load(.monotonic));
}

// Subprocess tests: a trap ends the process, so it runs in a fork() child.

extern "c" fn fork() c_int;
extern "c" fn close(fd: std.c.fd_t) c_int;

/// Runs `child` in a forked process with stderr captured; returns the exit
/// status and the captured stderr in `buf`.
fn runForked(child: *const fn () void, buf: []u8) !struct { status: u32, err: []const u8 } {
    var fds: [2]std.c.fd_t = undefined;
    try testing.expectEqual(0, std.c.pipe(&fds));
    const pid = fork();
    try testing.expect(pid >= 0);
    if (pid == 0) {
        _ = close(fds[0]);
        _ = std.c.dup2(fds[1], 2);
        pool.resetAfterFork();
        child();
        std.c._exit(0);
    }
    _ = close(fds[1]);
    defer _ = close(fds[0]);
    var len: usize = 0;
    while (len < buf.len) {
        const r = std.c.read(fds[0], buf[len..].ptr, buf.len - len);
        if (r <= 0) break;
        len += @intCast(r);
    }
    var status: c_int = 0;
    try testing.expectEqual(pid, std.c.waitpid(pid, &status, 0));
    return .{ .status = @bitCast(status), .err = buf[0..len] };
}

fn expectTrap(child: *const fn () void, expected: []const u8) !void {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var buf: [512]u8 = undefined;
    const r = try runForked(child, &buf);
    try testing.expect(std.c.W.IFEXITED(r.status));
    try testing.expectEqual(@import("../trap.zig").exit_status, std.c.W.EXITSTATUS(r.status));
    try testing.expect(std.mem.startsWith(u8, r.err, expected));
}

fn setThreadsAfterNursery() void {
    pool.pyro_rt_set_threads(3);
    if (pool.pyro_rt_threads() != 3) std.c._exit(1);
    spawnTree(2);
    if (pool.pyro_rt_threads() != 3) std.c._exit(2);
    pool.pyro_rt_set_threads(2);
}

test "set_threads works before the first nursery and traps after it" {
    try expectTrap(setThreadsAfterNursery, "trap[contract]: std.par.set_threads called after the first nursery\n");
}

fn trappingTask(_: ?*anyopaque) callconv(.c) void {
    @import("../trap.zig").trap(.explicit, "boom in task", "task.pr", 3);
}

fn trapInTask() void {
    pool.pyro_rt_set_threads(4);
    const n = pyro_rt_nursery_begin();
    for (0..64) |_| pyro_rt_spawn(n, noop, null, 0, 1);
    pyro_rt_spawn(n, trappingTask, null, 0, 1);
    pyro_rt_nursery_end(n);
}

test "a trap in a task terminates the process" {
    try expectTrap(trapInTask, "trap[explicit]: boom in task\n  --> task.pr:3\n");
}
