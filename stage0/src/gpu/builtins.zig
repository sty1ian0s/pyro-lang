//! GPU builtins and workgroup variables (§11.1.4, §11.1.7).
//!
//! The stage builtins (`@global_invocation_id`, `@vertex_index`,
//! `@workgroup_barrier()`, `@discard()`, ...) are entries of the builtin
//! registry (`sema/builtins.zig`): their stage sets report **E1005** outside
//! the stages of §11.1.7, using the stage classification of `stages.zig`
//! (`builtins.stageOf`), and a barrier is a `builtin` TIR instruction.
//!
//! This file checks the one GPU statement the registry cannot see,
//! `@workgroup let` (§11.1.4):
//!
//! - it is allowed only in a compute, task or mesh stage function (**E1005**,
//!   as for the stage builtins);
//! - its type is plain, `Atomic<T>`, or a fixed array of either; any other
//!   type is forbidden in stage code (**E1003**);
//! - it binds one name, whose TIR local is marked `workgroup`.
//!
//! Barrier placement (E1013) is `uniformity.zig` (T180) and races on
//! workgroup memory are `races.zig` (T181).

const std = @import("std");
const Ast = @import("../ast/Ast.zig");
const attrs = @import("../sema/attrs.zig");
const builtins = @import("../sema/builtins.zig");
const kinds = @import("../sema/kinds.zig");
const emit_tir = @import("../sema/emit_tir.zig");
const Types = @import("../sema/types.zig");

const Checker = emit_tir.Checker;
const Error = emit_tir.Error;
const Node = Ast.Node;
const TypeId = Types.TypeId;

/// Checks the attributed `let` statement `s` with `checkLet` (the plain
/// `let` checker) and, if it carries `@workgroup`, the rules of the file
/// comment. Returns whether the statement diverges, like `checkLet`.
pub fn workgroupLet(c: *Checker, s: Node.Index, comptime checkLet: fn (*Checker, Node.Index) Error!bool) Error!bool {
    const a = c.ast;
    const d = a.data(s).attributed;
    // Other attributes on a `let` are misplaced, which `attrs.check` reports.
    const at = for (d.attrs) |n| {
        if (attrs.attrOf(a, n) == .workgroup) break n;
    } else return checkLet(c, d.inner);
    if (builtins.stageOf(a, c.sig.attrs)) |stage| switch (stage) {
        .compute, .task, .mesh => {},
        else => try c.report(at, .E1005, "`@workgroup` variables are not available in a {t} stage", .{stage}),
    } else try c.report(at, .E1005, "`@workgroup` variables are only available in compute, task and mesh stage functions", .{});

    const ld = a.data(d.inner).let;
    const single = switch (a.kind(ld.pattern)) {
        .pat_bind, .pat_bind_mut => true,
        else => false,
    };
    if (!single) try c.report(ld.pattern, null, "a `@workgroup` variable binds a single name", .{});
    const diverges = try checkLet(c, d.inner);
    if (!single) return diverges;
    const l = c.locals.get(ld.pattern) orelse return diverges;
    c.b.locals.items(.workgroup)[l.int()] = true;
    const ty = c.b.locals.items(.ty)[l.int()];
    if (ty != .err and !try shareable(c, ty))
        try c.reportAt(a.mainToken(ld.ty orelse ld.pattern), .E1003, &.{"use a plain type, `Atomic<T>`, or a fixed array of either"}, "`@workgroup` variable `{s}` has type `{s}`, which workgroup memory cannot hold", .{ a.tokenSlice(a.mainToken(ld.pattern)), try c.tyName(ty) });
    // shortcut: TIR stores the initializer as for any `let`; §11.1.4 runs it in local invocation 0 followed by a barrier, which the compute emitters lower (T184, T185, T186).
    return diverges;
}

/// Whether workgroup memory can hold `t`: plain, `Atomic<T>` or a fixed
/// array of either (§11.1.4).
fn shareable(c: *Checker, t: TypeId) Error!bool {
    const elem = switch (c.types.get(t)) {
        .array => |arr| arr.elem,
        else => t,
    };
    return switch (c.types.get(elem)) {
        .nominal => |n| n.lang == .atomic,
        else => false,
    } or try kinds.kind(c.items, elem) == .plain;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "@workgroup variables are marked in TIR" {
    var f: emit_tir.Fixture = undefined;
    try f.init(
        \\struct Cell { v: f32, n: u32 }
        \\@gpu_kernel(workgroup: 64)
        \\fn k() {
        \\    @workgroup let mut tile: [64]f32 = [0.0; 64];
        \\    let plain: u32 = 0;
        \\    @workgroup let cells: [4]Cell = @zero([4]Cell);
        \\    @workgroup_barrier();
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    const func = try f.func("k");
    var n: usize = 0;
    for (0..func.locals.len) |i| n += @intFromBool(func.locals.items(.workgroup)[i]);
    try testing.expectEqual(2, n);
}

test "@workgroup types: plain, Atomic, arrays of either; others E1003; stages E1005" {
    var f: emit_tir.Fixture = undefined;
    try f.init(
        \\struct Words { s: str }
        \\@gpu_kernel(workgroup: 64)
        \\fn k(xs: []f32) {
        \\    @workgroup let mut count: Atomic<u32> = .init(0);
        \\    @workgroup let mut bins: [8]Atomic<u32> = [.init(0); 8];
        \\    @workgroup let v: []f32 = xs;
        \\    @workgroup let w: Words = Words { s: "a" };
        \\    @workgroup let a: [2]str = ["a", "b"];
        \\}
        \\@gpu_vertex
        \\fn vs() -> vec4<f32> {
        \\    @workgroup let t: f32 = 0.0;
        \\    vec4(t, t, t, 1.0)
        \\}
        \\fn cpu() { @workgroup let t: u32 = 0; }
        \\@gpu_task(workgroup: 32)
        \\fn ts() -> vec3<u32> {
        \\    @workgroup let mut seen: u32 = 0;
        \\    @workgroup_barrier();
        \\    vec3(seen, 1, 1)
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{
        .{ .E1003, "[" },
        .{ .E1003, "Words" },
        .{ .E1003, "[" },
        .{ .E1005, "@workgroup" },
        .{ .E1005, "@workgroup" },
    });
}
