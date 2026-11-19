//! Comptime memory (§8.6 "Memory"): comptime code allocates from a
//! compiler-managed arena that is freed after each evaluation.
//!
//! An `EvalArena` serves one evaluation at a time: the interpreter allocates
//! from `allocator()`, and `finish` copies the result out to long-lived
//! memory and frees everything else the evaluation allocated. Its chunks are
//! reused by the next evaluation (`base/Arena.zig`), so a stream of
//! evaluations stops calling the child allocator once it has seen its
//! largest one. Not thread-safe: one per worker.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Arena = @import("../base/Arena.zig");
const Value = @import("value.zig").Value;

pub const EvalArena = struct {
    scratch: Arena,

    pub fn init(child: Allocator) EvalArena {
        return .{ .scratch = .init(child) };
    }

    pub fn deinit(e: *EvalArena) void {
        e.scratch.deinit();
        e.* = undefined;
    }

    /// Memory of the evaluation in progress; valid until `finish` or
    /// `abort`.
    pub fn allocator(e: *EvalArena) Allocator {
        return e.scratch.allocator();
    }

    /// Ends the evaluation: copies `result` into `out` and frees all its
    /// memory. `result` and everything else from `allocator()` become
    /// invalid; the returned value does not refer to them.
    pub fn finish(e: *EvalArena, out: Allocator, result: Value) Allocator.Error!Value {
        const v = try result.dupe(out);
        e.scratch.reset();
        return v;
    }

    /// Ends a failed evaluation, freeing all its memory.
    pub fn abort(e: *EvalArena) void {
        e.scratch.reset();
    }
};

const testing = std.testing;

test "arena is freed per evaluation; results outlive it" {
    var counting: testing.FailingAllocator = .init(testing.allocator, .{});
    var ev: EvalArena = .init(counting.allocator());
    defer ev.deinit();
    var out: std.heap.ArenaAllocator = .init(testing.allocator);
    defer out.deinit();

    var results: [20]Value = undefined;
    var allocs: usize = 0;
    for (&results, 0..) |*r, i| {
        // An evaluation that builds a 1000-element array plus garbage.
        const a = ev.allocator();
        _ = try a.alloc(u8, 10_000);
        const elems = try a.alloc(Value, 1000);
        for (elems, 0..) |*x, j| x.* = .{ .ty = .usize, .data = .{ .scalar = i * 1000 + j } };
        r.* = try ev.finish(out.allocator(), .{ .ty = .void, .data = .{ .aggregate = elems } });
        try testing.expectEqual(ev.scratch.first, ev.scratch.cur); // rewound
        if (i == 0) allocs = counting.allocations;
        try testing.expectEqual(allocs, counting.allocations); // chunks reused, none added
    }
    _ = try ev.allocator().alloc(u8, 100_000); // a failed evaluation
    ev.abort();
    try testing.expectEqual(ev.scratch.first, ev.scratch.cur);
    for (results, 0..) |r, i| {
        try testing.expectEqual(@as(usize, 1000), r.data.aggregate.len);
        try testing.expectEqual(@as(u64, i * 1000 + 999), r.data.aggregate[999].data.scalar);
    }
}
