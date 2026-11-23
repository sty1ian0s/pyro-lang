//! `@pure` checking (§8.8, E0809). A `@pure` function has no `mut`
//! parameters, no `Atomic`/`Channel` access, no I/O, no `extern` calls and
//! calls no function that has effects. Contract conditions (§9.5.1) may
//! call only `@pure` functions.
//!
//! The body checker records the first *direct* effect of each body with
//! `note`, at the construct that has it, even when the body is not
//! otherwise supported yet (its TIR is then missing). After all bodies are
//! checked, `check` closes effects over the TIR call graph and reports every
//! `@pure` function that has a `mut` parameter or effects. A function only
//! has effects through its body: calling a function with `mut` parameters
//! is pure (the arguments are the caller's locals or its own views).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("../ast/Ast.zig");
const tir = @import("../tir/tir.zig");
const attrs = @import("attrs.zig");
const emit_tir = @import("emit_tir.zig");
const check_stmt = @import("check_stmt.zig");
const items_mod = @import("items.zig");
const ModuleId = @import("../resolve/module_graph.zig").ModuleId;

const Checker = emit_tir.Checker;
const Bodies = emit_tir.Bodies;
const Items = items_mod.Items;
const Node = Ast.Node;
const Error = Allocator.Error;

/// A direct effect of a function body.
pub const Effect = struct {
    kind: Kind,
    /// The construct with the effect, in the body's module.
    node: Node.Index,

    pub const Kind = enum {
        io,
        atomic,
        channel,
        extern_call,
        /// A call through a function pointer, whose callee is unknown.
        indirect_call,

        fn describe(k: Kind) []const u8 {
            return switch (k) {
                .io => "performs I/O",
                .atomic => "accesses an `Atomic`",
                .channel => "accesses a `Channel`",
                .extern_call => "calls an `extern` function",
                .indirect_call => "calls through a function pointer",
            };
        }
    };
};

/// Records that the body being checked by `c` has effect `kind` at `n`.
/// Only the first effect of a body is kept.
pub fn note(c: *Checker, n: Node.Index, kind: Effect.Kind) void {
    const id = c.bodies.ids.get(.{ c.m, c.sig.node }) orelse return;
    const b = &c.bodies.fns.items[id.int()];
    if (b.effect == null) b.effect = .{ .kind = kind, .node = n };
}

/// Why a function has effects.
const Why = union(enum) {
    direct: Effect,
    /// The call at `node` of `callee`, which has effects.
    calls: struct { callee: tir.FnId, node: Node.Index },
};

/// Reports E0809 for every `@pure` function of `it` that has a `mut`
/// parameter or effects. Run after `emit_tir.checkBodies` filled `bs`.
pub fn check(it: *Items, bs: *const Bodies) Error!void {
    const gpa = bs.arena.child_allocator;
    const why = try gpa.alloc(?Why, bs.fns.items.len);
    defer gpa.free(why);
    for (why, bs.fns.items) |*w, b| w.* = if (b.effect) |e| .{ .direct = e } else null;
    // Greatest fixed point: (mutually) recursive functions are pure unless
    // some member of the cycle has an effect.
    var changed = true;
    while (changed) {
        changed = false;
        for (bs.fns.items, why) |b, *w| {
            if (w.* != null or b.thunk) continue;
            const f = &(b.func orelse continue);
            w.* = firstImpure(f, why) orelse continue;
            changed = true;
        }
    }
    for (it.im.graph.modules, 0..) |mod, mi| {
        const m: ModuleId = @intCast(mi);
        for (0..mod.items.len) |i| switch ((try it.info(.{ .module = m, .item = @intCast(i) })).*) {
            .@"fn" => |f| try checkFn(it, bs, why, m, f),
            .@"struct" => |s| for (s.methods) |f| try checkFn(it, bs, why, m, f),
            .@"enum" => |e| for (e.methods) |f| try checkFn(it, bs, why, m, f),
            // shortcut: `impl` methods are not checked; add them with protocol method bodies (T044, T070).
            else => {},
        };
    }
}

/// The first call in `f` of a function with effects, or of an unknown one.
fn firstImpure(f: *const tir.Func, why: []const ?Why) ?Why {
    for (0..f.insts.len) |i| {
        const r: tir.Ref = .from(@intCast(i));
        const node: Node.Index = @fromBackingInt(@backingInt(f.nodeOf(r)));
        const callee: tir.FnId = switch (f.data(r)) {
            .call => |d| d.callee,
            .ret_tail => |d| d.callee,
            .spawn => |d| d.callee,
            .launch => |d| d.kernel,
            .call_indirect, .ret_tail_indirect, .spawn_indirect => return .{ .direct = .{ .kind = .indirect_call, .node = node } },
            else => continue,
        };
        if (why[callee.int()] != null) return .{ .calls = .{ .callee = callee, .node = node } };
    }
    return null;
}

fn checkFn(it: *Items, bs: *const Bodies, why: []const ?Why, m: ModuleId, f: items_mod.Fn) Error!void {
    const a = it.im.graph.modules[m].ast;
    if (!attrs.flags(a, f.attrs).pure) return;
    for (f.params) |p| if (p.mode == .mut)
        try it.report(m, a.mainToken(p.node), .E0809, &.{"take the parameter by value and return the new value"}, "`@pure` function `{s}` has a `mut` parameter `{s}`", .{ f.name, p.name });
    const id = bs.ids.get(.{ m, f.node }) orelse return;
    switch (why[id.int()] orelse return) {
        .direct => |e| try it.report(m, check_stmt.firstToken(a, e.node), .E0809, &.{}, "`@pure` function `{s}` {s}", .{ f.name, e.kind.describe() }),
        .calls => |c| {
            const callee = bs.fns.items[c.callee.int()].name;
            const reason = switch (why[c.callee.int()].?) {
                .direct => |e| try std.fmt.allocPrint(bs.arena.allocator(), "`{s}` {s}", .{ callee, e.kind.describe() }),
                .calls => |cc| try std.fmt.allocPrint(bs.arena.allocator(), "`{s}` calls `{s}`, which has effects", .{ callee, bs.fns.items[cc.callee.int()].name }),
            };
            try it.report(m, check_stmt.firstToken(a, c.node), .E0809, &.{reason}, "`@pure` function `{s}` calls `{s}`, which has effects", .{ f.name, callee });
        },
    }
}

// ---------------------------------------------------------------------------
// Tests

const Fixture = emit_tir.Fixture;

fn expectPurity(source: []const u8, want: []const struct { ?@import("../diag/diag.zig").DiagCode, []const u8 }) !void {
    var f: Fixture = undefined;
    try f.init(source);
    defer f.deinit();
    try check(&f.items, &f.bodies);
    try f.expectDiags(want);
}

test "E0809: pure arithmetic, local mutation and calls of pure functions" {
    try expectPurity(
        \\@pure
        \\fn square(x: f32) -> f32 { x * x }
        \\fn twice(x: f32) -> f32 { x + x }
        \\fn bump(mut x: u32) { x += 1; }
        \\@pure
        \\fn length2(x: f32, y: f32) -> f32 {
        \\    let mut n: u32 = 0;
        \\    bump(mut n);
        \\    while n < 3 { n += 1; }
        \\    square(x) + twice(y)
        \\}
        \\@pure
        \\fn fact(n: u64) -> u64 { if n == 0 { 1 } else { n * fact(n - 1) } }
    , &.{});
}

test "E0809: a `mut` parameter" {
    try expectPurity(
        \\@pure
        \\fn bump(mut x: u32) { x += 1; }
    , &.{.{ .E0809, "x" }});
}

test "E0809: an `extern` call, directly and through a callee" {
    try expectPurity(
        \\extern "C" { fn rand() -> i32; }
        \\@pure
        \\fn roll() -> i32 { unsafe { rand() } }
        \\fn roll2() -> i32 { unsafe { rand() } }
        \\@pure
        \\fn twice() -> i32 { roll2() + 1 }
    , &.{ .{ .E0809, "rand" }, .{ .E0809, "roll2" } });
}

test "E0809: effects reach through recursion and call chains" {
    try expectPurity(
        \\extern "C" { fn rand() -> i32; }
        \\fn even(n: u32) -> bool { if n == 0 { true } else { odd(n - 1) } }
        \\fn odd(n: u32) -> bool { if n == 0 { false } else { let r = unsafe { rand() }; even(n - 1) } }
        \\@pure
        \\fn check(n: u32) -> bool { even(n) }
    , &.{.{ .E0809, "even" }});
}

test "E0809: I/O" {
    try expectPurity(
        \\@pure
        \\fn log(a: u32) -> u32 { print("{}\n", a); a }
        \\fn noisy(a: u32) -> u32 { eprint("{}\n", a); a }
        \\@pure
        \\fn quiet(a: u32) -> u32 { noisy(a) }
    , &.{ .{ .E0809, "print" }, .{ .E0809, "noisy" } });
}

test "E0809: `Atomic` and `Channel` access" {
    try expectPurity(
        \\@pure
        \\fn hits(c: Atomic<u32>) -> u32 { c.load() }
        \\@pure
        \\fn post(ch: Channel<u32>) { ch.send(1); }
    , &.{ .{ .E0809, "load" }, .{ .E0809, "send" } });
}

test "E0809: a call through a function pointer" {
    try expectPurity(
        \\@pure
        \\fn apply(f: fn(u32) -> u32, x: u32) -> u32 { f(x) }
    , &.{.{ .E0809, "f" }});
}
