//! P-IR -> LLVM IR (B.6.2) for vector operations. Called from `emit.zig`.
//!
//! - `splat` is `insertelement` into lane 0 plus a zero-mask `shufflevector`.
//! - Integer `reduce.*` and float `reduce.min`/`reduce.max` map to
//!   `llvm.vector.reduce.*`; integer min/max compare unsigned unless the
//!   `signed` flag is set.
//! - Float `reduce.add`/`reduce.mul` are emitted as an explicit tree, because
//!   §10.6.3 fixes the order ("pairwise halves, lane 0 leftmost") and
//!   `llvm.vector.reduce.fadd` is either strictly sequential or, with
//!   `reassoc`, unordered. Each round combines lane `k` with lane
//!   `k + ceil(n/2)`; the middle lane of an odd round passes through.
//! - `load.masked`/`store.masked` map to `llvm.masked.load`/`llvm.masked.store`;
//!   masked-off lanes are never accessed. Alignment 0 is the lane type's
//!   natural alignment.
//!
//! Every function here references LLVM symbols, so only call it when
//! `@import("build_options").llvm` is true.

const std = @import("std");
const c = @import("c.zig");
const ir = @import("../../pir/ir.zig");
const emit = @import("emit.zig");
const emit_mem = @import("emit_mem.zig");

const Error = emit.Error;
const FnEmitter = emit.FnEmitter;
const llType = emit.llType;

/// Emits vector instruction `i` with result type `ty` (void if none) and
/// returns its LLVM value.
pub fn emitInst(e: *FnEmitter, i: ir.Inst, ty: ir.Type) Error!c.ValueRef {
    const b = e.b;
    const ops = i.operands;
    return switch (i.op) {
        .splat => blk: {
            const lane0 = c.LLVMBuildInsertElement(b, c.LLVMGetPoison(llType(e.ctx, ty)), try e.val(i, 0), lane(e, 0), "");
            const zeros = c.LLVMConstNull(llType(e.ctx, .vec(ty.lanes, .i32)));
            break :blk c.LLVMBuildShuffleVector(b, lane0, c.LLVMGetPoison(llType(e.ctx, ty)), zeros, "");
        },
        .extract => c.LLVMBuildExtractElement(b, try e.val(i, 0), lane(e, ops[1].int), ""),
        .insert => c.LLVMBuildInsertElement(b, try e.val(i, 0), try e.val(i, 1), lane(e, ops[2].int), ""),
        .shuffle => blk: {
            const mask = try e.arena.alloc(c.ValueRef, ops.len - 2);
            for (mask, ops[2..]) |*m, o| m.* = lane(e, o.int);
            break :blk c.LLVMBuildShuffleVector(b, try e.val(i, 0), try e.val(i, 1), c.LLVMConstVector(mask.ptr, @intCast(mask.len)), "");
        },
        .select => c.LLVMBuildSelect(b, try e.val(i, 0), try e.val(i, 1), try e.val(i, 2), ""),
        .@"reduce.add", .@"reduce.mul", .@"reduce.min", .@"reduce.max", .@"reduce.and", .@"reduce.or" => try reduce(e, i, ty),
        .@"load.masked" => blk: {
            const vt = e.f.typeOf(ops[2].value);
            break :blk emit_mem.callIntrinsic(e, "llvm.masked.load", &.{ llType(e.ctx, vt), llType(e.ctx, .of(.ptr)) }, &.{
                try e.val(i, 0), alignArg(e, i, vt), try e.val(i, 1), try e.val(i, 2),
            });
        },
        .@"store.masked" => blk: {
            const vt = e.f.typeOf(ops[0].value);
            break :blk emit_mem.callIntrinsic(e, "llvm.masked.store", &.{ llType(e.ctx, vt), llType(e.ctx, .of(.ptr)) }, &.{
                try e.val(i, 0), try e.val(i, 1), alignArg(e, i, vt), try e.val(i, 2),
            });
        },
        else => unreachable, // emit.zig dispatches only vector opcodes here
    };
}

/// An `i32` lane index or shuffle mask element.
fn lane(e: *FnEmitter, n: i64) c.ValueRef {
    return c.LLVMConstInt(c.LLVMIntTypeInContext(e.ctx, 32), @intCast(n), 0);
}

/// The `i32` alignment argument of a masked access to vector type `vt`.
fn alignArg(e: *FnEmitter, i: ir.Inst, vt: ir.Type) c.ValueRef {
    // shortcut: ptr lanes assume 8-byte pointers until T088 sets the data layout.
    const natural: u32 = switch (vt.scalar) {
        .i1, .i8 => 1,
        .i16 => 2,
        .i32, .f32 => 4,
        .i64, .f64, .ptr => 8,
        .void => unreachable,
    };
    return lane(e, if (i.@"align" != 0) i.@"align" else natural);
}

fn reduce(e: *FnEmitter, i: ir.Inst, ty: ir.Type) Error!c.ValueRef {
    const v = try e.val(i, 0);
    const vt = e.f.typeOf(i.operands[0].value);
    const float = ty.scalar.isFloat();
    if (float and i.op == .@"reduce.add") return tree(e, v, vt, .fadd, -0.0);
    if (float and i.op == .@"reduce.mul") return tree(e, v, vt, .fmul, 1.0);
    const s = i.flags.signed;
    const name = switch (i.op) {
        .@"reduce.add" => "llvm.vector.reduce.add",
        .@"reduce.mul" => "llvm.vector.reduce.mul",
        .@"reduce.and" => "llvm.vector.reduce.and",
        .@"reduce.or" => "llvm.vector.reduce.or",
        .@"reduce.min" => if (float) "llvm.vector.reduce.fmin" else if (s) "llvm.vector.reduce.smin" else "llvm.vector.reduce.umin",
        .@"reduce.max" => if (float) "llvm.vector.reduce.fmax" else if (s) "llvm.vector.reduce.smax" else "llvm.vector.reduce.umax",
        else => unreachable,
    };
    return emit_mem.callIntrinsic(e, name, &.{llType(e.ctx, vt)}, &.{v});
}

/// Reduces float vector `v` of type `vt` with `op` in the §10.6.3 tree
/// order; `identity` fills the missing partner of an odd round's middle lane.
fn tree(e: *FnEmitter, v: c.ValueRef, vt: ir.Type, op: c.Opcode, identity: f64) Error!c.ValueRef {
    const elem = llType(e.ctx, .of(vt.scalar));
    var x = v;
    var n = vt.lanes;
    while (n > 1) {
        const half = (n + 1) / 2;
        const ids = try e.arena.alloc(c.ValueRef, n);
        @memset(ids, c.LLVMConstReal(elem, identity));
        const id_vec = c.LLVMConstVector(ids.ptr, n);
        const lo = try e.arena.alloc(c.ValueRef, half);
        const hi = try e.arena.alloc(c.ValueRef, half);
        for (lo, hi, 0..) |*l, *h, k| {
            l.* = lane(e, @intCast(k));
            // Index `n` is lane 0 of `id_vec`.
            h.* = lane(e, @intCast(if (half + k < n) half + k else n));
        }
        const a = c.LLVMBuildShuffleVector(e.b, x, id_vec, c.LLVMConstVector(lo.ptr, half), "");
        const bb = c.LLVMBuildShuffleVector(e.b, x, id_vec, c.LLVMConstVector(hi.ptr, half), "");
        x = c.LLVMBuildBinOp(e.b, op, a, bb, "");
        n = half;
    }
    return c.LLVMBuildExtractElement(e.b, x, lane(e, 0), "");
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const llvmTest = emit.llvmTest;
const emitVerified = emit_mem.emitVerified;
const jitFn = emit_mem.jitFn;
const fnAddr = emit_mem.fnAddr;

test "lane access, shuffles, selects and integer reductions" {
    try llvmTest(struct {
        fn run() !void {
            var x = try emitVerified(
                \\fn @lanes(%x: i32, %m: vec<4 x i1>, %c: i1) -> vec<4 x i32> {
                \\^entry:
                \\  %s: vec<4 x i32> = splat %x
                \\  %e: i32 = extract %s, 2
                \\  %i: vec<4 x i32> = insert %s, %e, 3
                \\  %sh: vec<4 x i32> = shuffle %s, %i, 7, 0, 5, 1
                \\  %wide: vec<2 x i32> = shuffle %sh, %sh, 0, 6
                \\  %sel: vec<4 x i32> = select %m, %sh, %s
                \\  %sel2: vec<4 x i32> = select %c, %sel, %i
                \\  ret %sel2
                \\}
                \\fn @reds(%v: vec<4 x i32>, %b: vec<8 x i1>) -> i32 {
                \\^entry:
                \\  %a: i32 = reduce.add %v
                \\  %m: i32 = reduce.mul %v
                \\  %umin: i32 = reduce.min %v
                \\  %smin: i32 = reduce.min signed %v
                \\  %umax: i32 = reduce.max %v
                \\  %smax: i32 = reduce.max signed %v
                \\  %and: i32 = reduce.and %v
                \\  %or: i32 = reduce.or %v
                \\  %any: i1 = reduce.or %b
                \\  %r0: i32 = add %a, %m
                \\  %r1: i32 = add %r0, %umin
                \\  %r2: i32 = add %r1, %smin
                \\  %r3: i32 = add %r2, %umax
                \\  %r4: i32 = add %r3, %smax
                \\  %r5: i32 = add %r4, %and
                \\  %r6: i32 = add %r5, %or
                \\  ret %r6
                \\}
                \\fn @fred(%v: vec<4 x f64>) -> f64 {
                \\^entry:
                \\  %lo: f64 = reduce.min %v
                \\  %hi: f64 = reduce.max %v
                \\  %r: f64 = fadd %lo, %hi
                \\  ret %r
                \\}
            );
            defer x.deinit();
            try x.expect(&.{
                "%0 = insertelement <4 x i32> poison, i32 %x, i32 0",
                "%s = shufflevector <4 x i32> %0, <4 x i32> poison, <4 x i32> zeroinitializer",
                "%e = extractelement <4 x i32> %s, i32 2",
                "%i = insertelement <4 x i32> %s, i32 %e, i32 3",
                "%sh = shufflevector <4 x i32> %s, <4 x i32> %i, <4 x i32> <i32 7, i32 0, i32 5, i32 1>",
                "%wide = shufflevector <4 x i32> %sh, <4 x i32> %sh, <2 x i32> <i32 0, i32 6>",
                "%sel = select <4 x i1> %m, <4 x i32> %sh, <4 x i32> %s",
                "%sel2 = select i1 %c, <4 x i32> %sel, <4 x i32> %i",
                "%a = call i32 @llvm.vector.reduce.add.v4i32(<4 x i32> %v)",
                "%m = call i32 @llvm.vector.reduce.mul.v4i32(<4 x i32> %v)",
                "%umin = call i32 @llvm.vector.reduce.umin.v4i32(<4 x i32> %v)",
                "%smin = call i32 @llvm.vector.reduce.smin.v4i32(<4 x i32> %v)",
                "%umax = call i32 @llvm.vector.reduce.umax.v4i32(<4 x i32> %v)",
                "%smax = call i32 @llvm.vector.reduce.smax.v4i32(<4 x i32> %v)",
                "%and = call i32 @llvm.vector.reduce.and.v4i32(<4 x i32> %v)",
                "%or = call i32 @llvm.vector.reduce.or.v4i32(<4 x i32> %v)",
                "%any = call i1 @llvm.vector.reduce.or.v8i1(<8 x i1> %b)",
                "%lo = call double @llvm.vector.reduce.fmin.v4f64(<4 x double> %v)",
                "%hi = call double @llvm.vector.reduce.fmax.v4f64(<4 x double> %v)",
            }, &.{});

            var ee: c.ExecutionEngineRef = undefined;
            const reds = try jitFn(*const fn (@Vector(4, i32)) callconv(.c) i32, &x, "reds", &ee);
            defer c.LLVMDisposeExecutionEngine(ee);
            // add 5, mul -6, umin 1, smin -1, umax -1 (0xffffffff), smax 3,
            // and 1 & -1 & 2 & 3 = 0, or = -1.
            try testing.expectEqual(@as(i32, 5 - 6 + 1 - 1 - 1 + 3 + 0 - 1), reds(.{ 1, -1, 2, 3 }));
        }
    }.run);
}

test "float reduce.add and reduce.mul use the pairwise tree order" {
    try llvmTest(struct {
        fn run() !void {
            var x = try emitVerified(
                \\fn @sum4(%p: ptr) -> f64 {
                \\^entry:
                \\  %v: vec<4 x f64> = load %p, align 8
                \\  %r: f64 = reduce.add %v
                \\  ret %r
                \\}
                \\fn @sum3(%p: ptr) -> f32 {
                \\^entry:
                \\  %v: vec<3 x f32> = load %p, align 4
                \\  %r: f32 = reduce.add %v
                \\  ret %r
                \\}
                \\fn @prod4(%p: ptr) -> f64 {
                \\^entry:
                \\  %v: vec<4 x f64> = load %p, align 8
                \\  %r: f64 = reduce.mul %v
                \\  ret %r
                \\}
            );
            defer x.deinit();
            try x.expect(&.{
                "shufflevector <4 x double> %v, <4 x double> splat (double -0.000000e+00), <2 x i32> <i32 0, i32 1>",
                "shufflevector <4 x double> %v, <4 x double> splat (double -0.000000e+00), <2 x i32> <i32 2, i32 3>",
                "fadd <2 x double>",
                "fadd <1 x double>",
                "extractelement <1 x double>",
                // Odd round: lane 1 meets lane 3, which is the identity.
                "shufflevector <3 x float> %v, <3 x float> splat (float -0.000000e+00), <2 x i32> <i32 2, i32 3>",
                "fmul <2 x double>",
            }, &.{ "llvm.vector.reduce.fadd", "llvm.vector.reduce.fmul", "reassoc", "fast" });

            var ee: c.ExecutionEngineRef = undefined;
            // Vectors go through memory: by-value vector arguments are not C ABI.
            const sum4 = try jitFn(*const fn (*const [4]f64) callconv(.c) f64, &x, "sum4", &ee);
            defer c.LLVMDisposeExecutionEngine(ee);
            const sum3 = try fnAddr(*const fn (*const [3]f32) callconv(.c) f32, ee, "sum3");
            const prod4 = try fnAddr(*const fn (*const [4]f64) callconv(.c) f64, ee, "prod4");
            // (1e20 + -1e20) + (1 + 1) = 2; left-to-right would give 1.
            try testing.expectEqual(@as(f64, 2.0), sum4(&.{ 1e20, 1.0, -1e20, 1.0 }));
            // (v0 + v2) + v1: (1e8 + -1e8) + 1 = 1; left-to-right gives 0 in f32.
            try testing.expectEqual(@as(f32, 1.0), sum3(&.{ 1e8, 1.0, -1e8 }));
            // -0.0 is the additive identity: an all -0.0 sum stays -0.0.
            try testing.expect(std.math.signbit(sum4(&@splat(-0.0))));
            try testing.expectEqual(@as(f64, 24.0), prod4(&.{ 1, 2, 3, 4 }));
        }
    }.run);
}

test "masked tail store and load never touch masked-off lanes" {
    try llvmTest(struct {
        fn run() !void {
            var x = try emitVerified(
                \\fn @tail(%p: ptr, %n: i32, %iota: ptr, %x: f32) -> f32 {
                \\^entry:
                \\  %lanes: vec<4 x i32> = load %iota, align 4
                \\  %nv: vec<4 x i32> = splat %n
                \\  %m: vec<4 x i1> = icmp ult %lanes, %nv
                \\  %xv: vec<4 x f32> = splat %x
                \\  store.masked %xv, %p, %m
                \\  %z: f32 = const 0.0
                \\  %zv: vec<4 x f32> = splat %z
                \\  %l: vec<4 x f32> = load.masked %p, %m, %zv, align 8
                \\  %r: f32 = reduce.add %l
                \\  ret %r
                \\}
            );
            defer x.deinit();
            try x.expect(&.{
                "call void @llvm.masked.store.v4f32.p0(<4 x float> %xv, ptr %p, i32 4, <4 x i1> %m)",
                "%l = call <4 x float> @llvm.masked.load.v4f32.p0(ptr %p, i32 8, <4 x i1> %m, <4 x float> zeroinitializer)",
            }, &.{});

            var ee: c.ExecutionEngineRef = undefined;
            const tail = try jitFn(*const fn ([*]f32, i32, *const [4]i32, f32) callconv(.c) f32, &x, "tail", &ee);
            defer c.LLVMDisposeExecutionEngine(ee);

            // Two pages; the second is inaccessible, so touching a lane past
            // the first page's end faults.
            const page = std.heap.pageSize();
            const mem = std.c.mmap(null, 2 * page, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
            try testing.expect(mem != std.c.MAP_FAILED);
            const base: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(mem));
            defer _ = std.c.munmap(@ptrCast(base), 2 * page);
            try testing.expectEqual(0, std.c.mprotect(@ptrCast(@alignCast(base + page)), page, .{}));

            const floats: [*]f32 = @ptrCast(@alignCast(base));
            const end = page / @sizeOf(f32);
            const iota = [_]i32{ 0, 1, 2, 3 };
            @memset(floats[end - 4 .. end], 9.0);
            // 2 lanes left before the guard page.
            try testing.expectEqual(@as(f32, 3.0), tail(floats + end - 2, 2, &iota, 1.5));
            try testing.expectEqualSlices(f32, &.{ 9.0, 9.0, 1.5, 1.5 }, floats[end - 4 .. end]);
            try testing.expectEqual(@as(f32, 0.0), tail(floats + end, 0, &iota, 7.0));
        }
    }.run);
}
