//! All-blocked deadlock detection (§10.4.1 rule 3). If every task of the
//! process is blocked and none can proceed, the runtime traps with kind
//! `deadlock` and lists the tasks parked in channel operations.
//!
//! The detector counts *active* threads: threads whose innermost context (the
//! task or nursery body on top of the thread's stack) can run. A thread stops
//! being active when it parks (park.zig), when a joiner waits for its nursery,
//! or when a worker goes idle. Whoever makes a waiting context runnable counts
//! it active again before waking it, so the count never dips to 0 while a
//! wake-up is in flight. The check runs only when the count drops, under the
//! scheduler lock: when no thread is active and no task is queued, nothing can
//! ever unblock a parked task. This costs nothing until all threads are idle.
// shortcut: a joiner that helps (pool.zig) runs a task on top of its own stack;
// if that task parks, the joiner stays stuck under it even after its nursery
// drains, and a wait that only the joiner could end is reported as a deadlock.
// Fix with stackful tasks or by not helping with tasks that may park.

const std = @import("std");
const pool = @import("pool.zig");
const park = @import("park.zig");
const trap = @import("../trap.zig");

/// Threads whose innermost context can run. The program's main thread starts
/// active. Guarded by the scheduler lock, like every counter here.
var active: usize = 1;

/// Threads waiting in the pool for queued tasks (idle workers and waiting
/// joiners). Updated by pool.zig.
pub var idle: usize = 0;

/// Counts the calling thread's context as runnable again (or a waiting one,
/// on behalf of the thread that is about to wake it). Caller holds the lock.
pub fn wake() void {
    active += 1;
}

/// Counts the calling thread's context as blocked, then traps `deadlock` if no
/// context can run any more. Caller holds the lock.
pub fn sleep() void {
    active -= 1;
    if (active == 0 and !pool.queued()) report();
}

/// Message buffer of the trap; static so reporting needs no allocation.
var msg_buf: [2048]u8 = undefined;

fn report() noreturn {
    var w: std.Io.Writer = .fixed(&msg_buf);
    var site: ?*const park.Waiter = null;
    // A full buffer just cuts the list short.
    w.writeAll("every task is blocked:") catch {};
    var it = park.parked.first;
    while (it) |p| : (it = p.next) {
        site = p;
        if (p.task == 0) w.writeAll(" main") catch {} else w.print(" task {d}", .{p.task}) catch {};
        w.print(" in {s} ({s}:{d});", .{ p.what, p.file, p.line }) catch {};
    }
    const msg = std.mem.trimEnd(u8, w.buffered(), ";");
    // The trap points at the newest parked operation, the one that completed
    // the cycle in the common case.
    if (site) |p| trap.trap(.deadlock, msg, p.file, p.line);
    // Unreachable with correct counting: a blocked joiner waits on a task that
    // is itself blocked, so some task must be parked.
    trap.trap(.deadlock, msg, @src().file, @src().line);
}

/// Resets the counters in a child of `fork()` (tests only); called by
/// `pool.resetAfterFork`.
pub fn resetAfterFork() void {
    active = 1;
    idle = 0;
    park.parked = .{};
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;
const builtin = @import("builtin");
const nursery = @import("nursery.zig");

/// Bounded single-producer single-consumer queue over park/unpark, shaped like
/// the `Channel` lowering (T132) will be: an atomic counter per side, parking
/// on the counter value a task saw.
fn TestChannel(comptime cap: u32) type {
    return struct {
        const Self = @This();
        slots: [cap]u32 = undefined,
        sent: u32 = 0, // advanced by the producer
        received: u32 = 0, // advanced by the consumer

        fn send(ch: *Self, v: u32) void {
            const s = @atomicLoad(u32, &ch.sent, .acquire);
            while (true) {
                const r = @atomicLoad(u32, &ch.received, .acquire);
                if (s -% r < cap) break;
                park.pyro_rt_park(&ch.received, r, "send".ptr, 4, "test.pr".ptr, 7, 1);
            }
            ch.slots[s % cap] = v;
            @atomicStore(u32, &ch.sent, s +% 1, .release);
            _ = park.pyro_rt_unpark(&ch.sent, std.math.maxInt(u32));
        }

        fn recv(ch: *Self) u32 {
            const r = @atomicLoad(u32, &ch.received, .acquire);
            while (true) {
                const s = @atomicLoad(u32, &ch.sent, .acquire);
                if (s != r) break;
                park.pyro_rt_park(&ch.sent, s, "recv".ptr, 4, "test.pr".ptr, 7, 2);
            }
            const v = ch.slots[r % cap];
            @atomicStore(u32, &ch.received, r +% 1, .release);
            _ = park.pyro_rt_unpark(&ch.received, std.math.maxInt(u32));
            return v;
        }
    };
}

const Chan = TestChannel(1); // capacity 1: nearly every operation parks
const iterations = 10_000;

const Stage = struct { in: ?*Chan, out: ?*Chan, sum: *u64 };

/// Producer (no `in`), relay, or consumer (no `out`) of the pipeline.
fn stageTask(args: ?*anyopaque) callconv(.c) void {
    const s: *const Stage = @ptrCast(@alignCast(args.?));
    for (0..iterations) |i| {
        const v: u32 = if (s.in) |in| in.recv() else @intCast(i);
        if (s.out) |out| out.send(v + 1) else s.sum.* += v;
    }
}

fn runPipeline() u64 {
    var a: Chan = .{};
    var b: Chan = .{};
    var sum: u64 = 0;
    const n = nursery.pyro_rt_nursery_begin();
    // Consumer first, so with one thread it parks before anything is sent.
    for ([_]Stage{ .{ .in = &b, .out = null, .sum = &sum }, .{ .in = &a, .out = &b, .sum = &sum }, .{ .in = null, .out = &a, .sum = &sum } }) |st|
        nursery.pyro_rt_spawn(n, stageTask, &st, @sizeOf(Stage), @alignOf(Stage));
    nursery.pyro_rt_nursery_end(n);
    return sum;
}

const expected_sum: u64 = iterations * (iterations - 1) / 2 + 2 * iterations;

test "10k-iteration pipeline runs without a false deadlock" {
    try testing.expectEqual(expected_sum, runPipeline());
}

fn pipelineOneThread() void {
    pool.pyro_rt_set_threads(1);
    if (runPipeline() != expected_sum) std.c._exit(1);
}

test "10k-iteration pipeline on one thread starts workers for parked tasks" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var buf: [512]u8 = undefined;
    const r = try nursery.runForked(pipelineOneThread, &buf);
    try testing.expectEqualStrings("", r.err);
    try testing.expect(std.c.W.IFEXITED(r.status));
    try testing.expectEqual(0, std.c.W.EXITSTATUS(r.status));
}

fn recvForever(args: ?*anyopaque) callconv(.c) void {
    const ch: *const *Chan = @ptrCast(@alignCast(args.?));
    _ = ch.*.recv();
}

fn mutualRecv() void {
    pool.pyro_rt_set_threads(2);
    // Each task waits on the channel the other one would send on.
    var a: Chan = .{};
    var b: Chan = .{};
    const n = nursery.pyro_rt_nursery_begin();
    for ([_]*Chan{ &a, &b }) |ch| nursery.pyro_rt_spawn(n, recvForever, @ptrCast(&ch), @sizeOf(*Chan), @alignOf(*Chan));
    nursery.pyro_rt_nursery_end(n);
}

fn expectDeadlock(child: *const fn () void, expected: []const u8) !void {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var buf: [512]u8 = undefined;
    const r = try nursery.runForked(child, &buf);
    try testing.expect(std.c.W.IFEXITED(r.status));
    try testing.expectEqual(trap.exit_status, std.c.W.EXITSTATUS(r.status));
    try testing.expectEqualStrings(expected, r.err);
}

test "mutual empty recv traps deadlock listing both tasks" {
    // Which task parks first depends on scheduling; accept either order.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var buf: [512]u8 = undefined;
    const r = try nursery.runForked(mutualRecv, &buf);
    try testing.expect(std.c.W.IFEXITED(r.status));
    try testing.expectEqual(trap.exit_status, std.c.W.EXITSTATUS(r.status));
    const one_two = "trap[deadlock]: every task is blocked: task 1 in recv (test.pr:2); task 2 in recv (test.pr:2)\n  --> test.pr:2\n";
    const two_one = "trap[deadlock]: every task is blocked: task 2 in recv (test.pr:2); task 1 in recv (test.pr:2)\n  --> test.pr:2\n";
    if (!std.mem.eql(u8, r.err, one_two)) try testing.expectEqualStrings(two_one, r.err);
}

fn mainRecvAlone() void {
    var a: Chan = .{};
    _ = a.recv();
}

test "the main body parked with no tasks is a deadlock" {
    try expectDeadlock(mainRecvAlone, "trap[deadlock]: every task is blocked: main in recv (test.pr:2)\n  --> test.pr:2\n");
}
