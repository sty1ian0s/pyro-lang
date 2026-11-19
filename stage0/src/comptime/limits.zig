//! Comptime limits (§8.6): the evaluation budget, `@set_eval_quota`, and the
//! operations comptime code may not run (E0805, E0808).
//!
//! API for the evaluation driver (T060). For each top-level comptime
//! evaluation (one const initializer, comptime block, comptime argument,
//! ...):
//!
//!     var ev: limits.Eval = .{};        // fresh budget: `default_quota`
//!     ev.attach(&machine);              // sets `Machine.budget` and `Machine.eval`
//!     const v = machine.call(f, args);  // `Hooks.stop` calls `limits.report(m, why)`
//!
//! - The budget counts executed backward branches and calls
//!   (`interp_ctrl.Machine.tick`). A new `Eval` per top-level evaluation
//!   gives each its own 10 000 000 steps; nested calls share their
//!   evaluation's budget.
//! - `@set_eval_quota(n)` executed during the evaluation raises its quota to
//!   `n` (`Eval.raise`; never lowers it): the steps already spent count
//!   against the new quota.
//! - The driver's `Hooks.stop` calls `report`, which emits E0808 when the
//!   budget runs out, and E0805 when the evaluation reaches an `unsafe`
//!   block, a raw-pointer operation or concurrency, each with the comptime
//!   trace. `extern` calls are only allowed inside `unsafe`, so they stop at
//!   their block. Afterwards `Machine.call` returns `error.OverBudget`
//!   (E0808) or `error.Unsupported` (E0805); `Eval.reported` tells the
//!   driver that a diagnostic was emitted, so the latter is a failed
//!   evaluation, not an unsupported construct.
//! - An `unsafe` block is forbidden when control enters it, so a block on a
//!   branch comptime does not take is allowed. Checking opens each block
//!   with an empty scope whose node is the `unsafe` block
//!   (`sema/unsafe.zig`); the interpreter stops at its `scope_begin`.
//!
//! `@set_eval_quota` outside comptime evaluation has no effect; its type is
//! `(u32) -> void` (`builtins.zig`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const diag = @import("../diag/diag.zig");
const tir = @import("../tir/tir.zig");
const interp_ctrl = @import("interp_ctrl.zig");

const Machine = interp_ctrl.Machine;
const Stop = interp_ctrl.Stop;

/// The budget of a top-level evaluation (§8.6): executed backward branches
/// and calls.
pub const default_quota: u64 = 10_000_000;

/// The limits of one top-level comptime evaluation.
pub const Eval = struct {
    /// Steps left; `Machine.budget` points here.
    left: u64 = default_quota,
    /// The current quota; `left` started from it.
    quota: u64 = default_quota,
    /// Set when `report` emitted E0805 or E0808 for this evaluation.
    reported: bool = false,

    /// An evaluation with `quota` steps.
    pub fn init(quota: u64) Eval {
        return .{ .left = quota, .quota = quota };
    }

    /// Makes `e` the budget of the evaluations `m` runs next.
    pub fn attach(e: *Eval, m: *Machine) void {
        m.budget = &e.left;
        m.eval = e;
    }

    /// `@set_eval_quota(n)`: raises the quota to `n`; a lower `n` does nothing.
    pub fn raise(e: *Eval, n: u64) void {
        if (n <= e.quota) return;
        e.left += n - e.quota;
        e.quota = n;
    }
};

/// Reports why `m` stopped (E0805 or E0808) with the comptime trace; the
/// body of the driver's `Hooks.stop`. Marks `m.eval` as reported.
pub fn report(m: *Machine, why: Stop) Allocator.Error!void {
    const tr = try m.trace();
    defer tr.deinit(m.gpa);
    if (m.eval) |e| e.reported = true;
    const code: diag.DiagCode, const msg = switch (why) {
        .budget => .{ .E0808, if (m.eval) |e|
            try std.fmt.allocPrint(m.gpa, "comptime evaluation exceeded its budget of {d} backward branches and calls", .{e.quota})
        else
            try m.gpa.dupe(u8, "comptime evaluation exceeded its budget") },
        .forbidden => |what| .{ .E0805, try std.fmt.allocPrint(m.gpa, "{s} cannot be used in comptime code", .{what}) },
    };
    defer m.gpa.free(msg);
    const help: []const []const u8 = if (why == .budget) &.{"raise it with `@set_eval_quota(n)` inside the evaluation"} else &.{};
    // §8.6: E0808 is reported at the evaluation, the outermost frame; the
    // step that ran out leads the trace instead.
    var at = tr.span;
    var trace = tr.frames;
    if (why == .budget and trace.len > 0) {
        trace = try m.gpa.alloc(diag.TraceFrame, tr.frames.len);
        trace[0] = .{ .span = tr.span, .note = "the budget ran out here" };
        @memcpy(trace[1..], tr.frames[0 .. tr.frames.len - 1]);
        at = tr.frames[tr.frames.len - 1].span;
    }
    defer if (trace.ptr != tr.frames.ptr) m.gpa.free(trace);
    try m.sink.emit(.{
        .code = code,
        .severity = .of(code),
        .message = msg,
        .spans = &.{.{ .span = at, .primary = true }},
        .help = help,
        .trace = trace,
    });
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const emit_tir = @import("../sema/emit_tir.zig");
const Builder = @import("../tir/builder.zig").Builder;
const Types = @import("../sema/types.zig");
const Value = @import("value.zig").Value;

const u64_t: Types.TypeId = .int(.unsigned, 64);

/// A checked package and a machine over it whose stop hook is `report`.
const Fixture = struct {
    f: emit_tir.Fixture,
    arena: std.heap.ArenaAllocator,
    sink: diag.Sink,
    m: Machine,

    fn init(x: *Fixture, src: []const u8) !void {
        try x.f.init(src);
        try x.f.expectDiags(&.{});
        try testing.expectEqual(null, x.f.bodies.unsupported);
        x.arena = .init(testing.allocator);
        x.sink = .init(testing.allocator, testing.io);
        x.m = .{ .in = .{ .items = &x.f.items, .arena = x.arena.allocator() }, .gpa = testing.allocator, .bodies = &x.f.bodies, .sink = &x.sink };
        x.m.hooks = .{ .ctx = undefined, .resolve = resolve, .stop = stop };
    }

    fn deinit(x: *Fixture) void {
        x.m.deinit();
        x.sink.deinit();
        x.arena.deinit();
        x.f.deinit();
    }

    fn resolve(_: *anyopaque, m: *Machine, _: *const tir.Func, _: tir.Ref) interp_ctrl.StepError!Value {
        return m.fail("unused");
    }

    fn stop(_: *anyopaque, m: *Machine, why: Stop) Allocator.Error!void {
        return report(m, why);
    }

    fn id(x: *Fixture, name: []const u8) tir.FnId {
        return x.f.bodies.ids.get(.{ 0, x.f.bodies.find(0, name).?.node }).?;
    }

    /// Runs `name(args)` as one top-level evaluation with `quota` steps.
    fn eval(x: *Fixture, quota: u64, name: []const u8, args: []const Value) !struct { interp_ctrl.Error!Value, Eval } {
        var ev: Eval = .init(quota);
        ev.attach(&x.m);
        const r = x.m.call(x.id(name), args);
        x.m.budget = null;
        x.m.eval = null;
        return .{ r, ev };
    }

    fn int(x: *Fixture, v: i128) Value {
        return Value.int(&x.f.types, x.f.items.options.ptr_bits, u64_t, v).?;
    }

    /// The one diagnostic: its code, message, primary text and trace notes.
    fn expectDiag(x: *Fixture, code: diag.DiagCode, msg: []const u8, at: []const u8, notes: []const []const u8) !void {
        const ds = x.sink.finish();
        try testing.expectEqual(1, ds.len);
        const d = ds[0];
        try testing.expectEqual(code, d.code.?);
        try testing.expectEqualStrings(msg, d.message);
        const s = d.primarySpan().?;
        try testing.expectEqualStrings(at, x.f.p.asts[0].source[s.start..s.end]);
        try testing.expectEqual(notes.len, d.trace.len);
        for (notes, d.trace) |n, tf| try testing.expectEqualStrings(n, tf.note);
    }
};

test "an infinite loop is E0808 with the comptime trace" {
    var x: Fixture = undefined;
    try x.init(
        \\fn forever() -> u64 { let mut i = 0u64; loop { i += 1; } }
        \\fn top() -> u64 { forever() }
    );
    defer x.deinit();
    // The evaluation site, as the driver passes it: here the name `top`.
    const src = x.f.p.asts[0].source;
    const site: u32 = @intCast(std.mem.indexOf(u8, src, "top").?);
    x.m.outer = &.{.{ .span = .{ .file = @fromBackingInt(0), .start = site, .end = site + 3 }, .note = "in this comptime evaluation" }};
    const r, const ev = try x.eval(1000, "top", &.{});
    try testing.expectError(error.OverBudget, r);
    try testing.expect(ev.reported);
    // Reported at the evaluation; the trace starts where the budget ran out.
    try x.expectDiag(.E0808, "comptime evaluation exceeded its budget of 1000 backward branches and calls", "top", &.{ "the budget ran out here", "in call to `forever`" });
    const d = x.sink.finish()[0];
    try testing.expectEqualStrings("loop", src[d.trace[0].span.start..d.trace[0].span.end]);
    try testing.expectEqualStrings("raise it with `@set_eval_quota(n)` inside the evaluation", d.help[0]);
}

test "@set_eval_quota raises the budget of its evaluation and never lowers it" {
    var x: Fixture = undefined;
    try x.init(
        \\fn count(n: u64) -> u64 { let mut i = 0u64; while i < n { i += 1; } i }
        \\fn raised(n: u64) -> u64 { @set_eval_quota(5000); count(n) }
        \\fn lowered(n: u64) -> u64 { @set_eval_quota(10); count(n) }
    );
    defer x.deinit();
    const ok, const ev = try x.eval(1000, "raised", &.{x.int(3000)});
    try testing.expect((try ok).eql(x.int(3000)));
    try testing.expectEqual(5000, ev.quota);
    try testing.expect(!ev.reported);
    try testing.expect(!x.sink.hasErrors());

    const low, _ = try x.eval(1000, "lowered", &.{x.int(500)});
    try testing.expect((try low).eql(x.int(500)));
    const over, _ = try x.eval(1000, "count", &.{x.int(3000)});
    try testing.expectError(error.OverBudget, over);
    try x.expectDiag(.E0808, "comptime evaluation exceeded its budget of 1000 backward branches and calls", "while", &.{});
}

test "the budget is per top-level evaluation" {
    var x: Fixture = undefined;
    try x.init("fn count(n: u64) -> u64 { let mut i = 0u64; while i < n { i += 1; } i }");
    defer x.deinit();
    // Each evaluation spends 60% of its quota; together they would exceed it.
    for (0..2) |_| {
        const r, _ = try x.eval(1000, "count", &.{x.int(600)});
        try testing.expect((try r).eql(x.int(600)));
    }
    var shared: Eval = .init(1000);
    shared.attach(&x.m);
    _ = try x.m.call(x.id("count"), &.{x.int(600)});
    try testing.expectError(error.OverBudget, x.m.call(x.id("count"), &.{x.int(600)}));
    try testing.expectEqual(10_000_000, (Eval{}).left);
}

test "E0805: entering an `unsafe` block stops, whatever it contains" {
    var x: Fixture = undefined;
    try x.init(
        \\extern "C" { fn abs(x: i32) -> i32; }
        \\fn guarded(b: bool) -> u64 {
        \\    if b {
        \\        unsafe { return 1; }
        \\    }
        \\    2
        \\}
        \\fn ext() -> i32 { unsafe { abs(-1) } }
        \\fn ptr() -> u64 { let x = 7u64; unsafe { let p = &x; *p } }
        \\fn top() -> u64 { guarded(true) }
        \\fn empty() -> u64 { unsafe { } 3 }
        \\fn constant() -> u64 { unsafe { 1 } }
    );
    defer x.deinit();
    // Not reached: allowed.
    const r, _ = try x.eval(1000, "guarded", &.{.boolean(false)});
    try testing.expect((try r).eql(x.int(2)));

    const Case = struct { name: []const u8, notes: []const []const u8 };
    for ([_]Case{
        .{ .name = "top", .notes = &.{"in call to `guarded`"} },
        .{ .name = "ext", .notes = &.{} },
        .{ .name = "ptr", .notes = &.{} },
        .{ .name = "empty", .notes = &.{} },
        .{ .name = "constant", .notes = &.{} },
    }) |c| {
        x.sink.deinit();
        x.sink = .init(testing.allocator, testing.io);
        const e, const ev = try x.eval(1000, c.name, &.{});
        try testing.expectError(error.Unsupported, e);
        try testing.expect(ev.reported);
        try x.expectDiag(.E0805, "`unsafe` blocks cannot be used in comptime code", "unsafe", c.notes);
    }
}

test "E0805: concurrency" {
    var x: Fixture = undefined;
    try x.init("fn fan_out() -> u64 { 0 }");
    defer x.deinit();
    // `nursery { ... }` is not checked yet (T125): build its TIR directly.
    var b: Builder = .init(x.arena.allocator(), u64_t);
    b.setBlock(try b.addBlock());
    _ = try b.add(.void, .{ .nursery_begin = .{} });
    _ = try b.add(.void, .{ .ret = .{ .value = try b.add(u64_t, .{ .int = .{ .value = 0 } }) } });
    x.f.bodies.fns.items[x.id("fan_out").int()].func = try b.finish();
    const r, const ev = try x.eval(1000, "fan_out", &.{});
    try testing.expectError(error.Unsupported, r);
    try testing.expect(ev.reported);
    try x.expectDiag(.E0805, "concurrency cannot be used in comptime code", "fn", &.{});
}
