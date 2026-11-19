//! P-IR -> LLVM IR (B.6.2) for globals, memory, SoA, bit fields, checks,
//! calls, atomics and intrinsic-backed scalar ops (`fma`, `fptoui.sat`,
//! `fptosi.sat`). Called from `emit.zig`.
//!
//! - `load`/`store` keep `volatile`, `atomic(order)` (`relaxed` is LLVM's
//!   `monotonic`) and `align`; alignment 0 is the type's natural alignment.
//! - `gep p, i, stride` is `getelementptr [stride x i8], ptr p, i`: one
//!   instruction scaling the (signed) index by the byte stride.
//! - SoA: `base` points at a `soa []T` value as laid out by §4.11.5, `k`
//!   column pointers then the length. `soa.col` loads column pointer
//!   `field`; `soa.load`/`soa.store` index that column by `i`.
//! - Bit fields expand to shifts and masks of the storage unit.
//! - `bounds` and `*.trap` branch to a fresh cold block that calls the trap
//!   runtime (`pyro_rt_trap`, runtime/trap.zig) and continue in a new block.
//!   `*.trap` uses `llvm.{s,u}{add,sub,mul}.with.overflow`; the `signed` flag
//!   picks the signed check, and a vector traps if any lane overflows.
//! - `call.tail` is a `musttail` call (the verifier already checked that the
//!   prototypes match and the call is directly returned).
//!
//! Every function here references LLVM symbols, so only call it when
//! `@import("build_options").llvm` is true.

const std = @import("std");
const c = @import("c.zig");
const ir = @import("../../pir/ir.zig");
const emit = @import("emit.zig");

const Error = emit.Error;
const FnEmitter = emit.FnEmitter;
const llType = emit.llType;

/// `TrapKind` discriminants of runtime/trap.zig (`std/core/trap.pr`).
const trap_bounds = 0;
const trap_overflow = 1;

/// Adds global `g` to `mod`. A byte-string initializer gives the global
/// type `[len x i8]`; a `readonly` global is constant.
pub fn declareGlobal(arena: std.mem.Allocator, ctx: c.ContextRef, mod: c.ModuleRef, g: ir.Global) Error!c.ValueRef {
    const ty = llType(ctx, g.ty);
    const init = switch (g.init) {
        .int => |x| if (g.ty.scalar.isInt() and !g.ty.isVector()) c.LLVMConstInt(ty, @bitCast(x), 0) else return error.Unsupported,
        .float => |x| if (g.ty.scalar.isFloat() and !g.ty.isVector()) c.LLVMConstReal(ty, x) else return error.Unsupported,
        .zero => c.LLVMConstNull(ty),
        .bytes => |s| c.LLVMConstStringInContext2(ctx, s.ptr, s.len, 1),
    };
    const llg = c.LLVMAddGlobal(mod, if (g.init == .bytes) c.LLVMArrayType2(i8Type(ctx), g.init.bytes.len) else ty, try arena.dupeSentinel(u8, g.name, 0));
    c.LLVMSetInitializer(llg, init);
    if (g.@"align" != 0) c.LLVMSetAlignment(llg, g.@"align");
    if (g.readonly) c.LLVMSetGlobalConstant(llg, 1);
    return llg;
}

/// Emits `i`, whose single result (if any) has type `ty`, and returns the
/// LLVM value of that result (or the instruction itself when it has none).
/// The results of a two-result `cmpxchg` are recorded in `e.values` directly.
pub fn emitInst(e: *FnEmitter, i: ir.Inst, ty: ir.Type) Error!c.ValueRef {
    const b = e.b;
    const ops = i.operands;
    return switch (i.op) {
        .alloca => blk: {
            const a = c.LLVMBuildAlloca(b, llType(e.ctx, ops[0].type), "");
            if (i.@"align" != 0) c.LLVMSetAlignment(a, i.@"align");
            break :blk a;
        },
        .load => memFlags(i, ty, c.LLVMBuildLoad2(b, llType(e.ctx, ty), try e.val(i, 0), "")),
        .store => memFlags(i, typeOf(e, ops[0]), c.LLVMBuildStore(b, try e.val(i, 0), try e.val(i, 1))),
        .gep => blk: {
            const stride = std.math.cast(u64, ops[2].int) orelse return error.Unsupported;
            break :blk c.LLVMBuildGEP2(b, c.LLVMArrayType2(i8Type(e.ctx), stride), try e.val(i, 0), &.{try e.val(i, 1)}, 1, "");
        },
        .memcpy => c.LLVMBuildMemCpy(b, try e.val(i, 0), i.@"align", try e.val(i, 1), i.@"align", try e.val(i, 2)),
        .memset => c.LLVMBuildMemSet(b, try e.val(i, 0), try e.val(i, 1), try e.val(i, 2), i.@"align"),
        .@"soa.col" => try soaColumn(e, ops[0], ops[1].int),
        .@"soa.load" => c.LLVMBuildLoad2(b, llType(e.ctx, ty), try soaElem(e, i, ty), ""),
        .@"soa.store" => blk: {
            const v = try e.val(i, 3);
            break :blk c.LLVMBuildStore(b, v, try soaElem(e, i, typeOf(e, ops[3])));
        },
        .@"bf.extract" => try bfExtract(e, i, ty),
        .@"bf.insert" => try bfInsert(e, i, ty),
        .fma => emit.fastMath(i, callIntrinsic(e, "llvm.fma", &.{llType(e.ctx, ty)}, &.{ try e.val(i, 0), try e.val(i, 1), try e.val(i, 2) })),
        .@"fptoui.sat", .@"fptosi.sat" => callIntrinsic(
            e,
            if (i.op == .@"fptoui.sat") "llvm.fptoui.sat" else "llvm.fptosi.sat",
            &.{ llType(e.ctx, ty), llType(e.ctx, typeOf(e, ops[0])) },
            &.{try e.val(i, 0)},
        ),
        .@"add.trap", .@"sub.trap", .@"mul.trap" => try checkedArith(e, i, ty),
        .bounds => blk: {
            const fail = c.LLVMBuildICmp(b, .uge, try e.val(i, 0), try e.val(i, 1), "");
            trapIf(e, fail, trap_bounds);
            break :blk fail;
        },
        // shortcut: msg_id is dropped until T090 defines the trap message/location table.
        .trap => trapCall(e, std.math.cast(u32, ops[0].int) orelse return error.Unsupported),
        .call, .@"call.tail" => blk: {
            const callee = try e.val(i, 0);
            const call = try buildCall(e, c.LLVMGlobalGetValueType(callee), callee, ops[1..]);
            if (i.op == .@"call.tail") c.LLVMSetTailCallKind(call, .must_tail);
            break :blk call;
        },
        .@"call.indirect" => blk: {
            const params = try e.arena.alloc(c.TypeRef, ops.len - 1);
            for (params, ops[1..]) |*p, o| p.* = llType(e.ctx, typeOf(e, o));
            const fn_ty = c.LLVMFunctionType(llType(e.ctx, ty), params.ptr, @intCast(params.len), 0);
            break :blk try buildCall(e, fn_ty, try e.val(i, 0), ops[1..]);
        },
        .@"atomic.rmw" => c.LLVMBuildAtomicRMW(b, rmwOp(i.rmw), try e.val(i, 0), try e.val(i, 1), ordering(ops[2].order), 0),
        .cmpxchg => blk: {
            const pair = c.LLVMBuildAtomicCmpXchg(b, try e.val(i, 0), try e.val(i, 1), try e.val(i, 2), ordering(ops[3].order), ordering(ops[4].order), 0);
            const old = c.LLVMBuildExtractValue(b, pair, 0, "");
            if (i.results.len == 2) {
                // emit.zig records single results only.
                for (i.results, [_]c.ValueRef{ old, c.LLVMBuildExtractValue(b, pair, 1, "") }) |r, v| {
                    e.values[r.index()] = v;
                    const name = e.f.values.items[r.index()].name;
                    if (name.len != 0) c.LLVMSetValueName2(v, name.ptr, name.len);
                }
            }
            break :blk old;
        },
        .fence => c.LLVMBuildFence(b, ordering(ops[0].order), 0, ""),
        else => error.Unsupported,
    };
}

fn i8Type(ctx: c.ContextRef) c.TypeRef {
    return c.LLVMIntTypeInContext(ctx, 8);
}

/// The P-IR type of a value or `@symbol` operand.
fn typeOf(e: *const FnEmitter, o: ir.Operand) ir.Type {
    return if (o == .value) e.f.typeOf(o.value) else .of(.ptr);
}

fn bits(s: ir.Scalar) u32 {
    return switch (s) {
        .i1 => 1,
        .i8 => 8,
        .i16 => 16,
        .i32, .f32 => 32,
        .i64, .f64 => 64,
        .ptr, .void => unreachable,
    };
}

/// The low `n` bits set (1 <= n <= 64).
fn lowMask(n: u32) u64 {
    return ~@as(u64, 0) >> @intCast(64 - n);
}

/// Applies `align`, `volatile` and `atomic(order)` of `i` to load/store `v`,
/// which accesses a value of type `ty`. An alignless atomic is aligned to its
/// size: LLVM would take the data layout's ABI alignment, which can be
/// smaller, and lowers an underaligned atomic to an `__atomic_*` libcall.
fn memFlags(i: ir.Inst, ty: ir.Type, v: c.ValueRef) c.ValueRef {
    // shortcut: ptr is 8 bytes; use the target's pointer size once T088 sets the data layout.
    const size: u32 = if (ty.scalar == .ptr) 8 else bits(ty.scalar) / 8;
    const @"align" = if (i.@"align" == 0 and i.atomic != .none) size else i.@"align";
    if (@"align" != 0) c.LLVMSetAlignment(v, @"align");
    if (i.flags.@"volatile") c.LLVMSetVolatile(v, 1);
    if (i.atomic != .none) c.LLVMSetOrdering(v, ordering(i.atomic));
    return v;
}

fn ordering(o: ir.Order) c.AtomicOrdering {
    return switch (o) {
        .none => .not_atomic,
        .relaxed => .monotonic,
        .acquire => .acquire,
        .release => .release,
        .acq_rel => .acq_rel,
        .seq_cst => .seq_cst,
    };
}

fn rmwOp(op: ir.RmwOp) c.AtomicRMWBinOp {
    return switch (op) {
        .none => unreachable, // the verifier requires an operation
        inline else => |o| @field(c.AtomicRMWBinOp, @tagName(o)),
    };
}

/// Calls `callee` of type `fn_ty` with the value operands `args`.
fn buildCall(e: *FnEmitter, fn_ty: c.TypeRef, callee: c.ValueRef, args: []const ir.Operand) Error!c.ValueRef {
    const vals = try e.arena.alloc(c.ValueRef, args.len);
    for (vals, args) |*v, o| v.* = try e.operand(o, .void);
    return c.LLVMBuildCall2(e.b, fn_ty, callee, vals.ptr, @intCast(vals.len), "");
}

/// Calls LLVM intrinsic `name`, overloaded on `overloads`.
pub fn callIntrinsic(e: *FnEmitter, name: []const u8, overloads: []const c.TypeRef, args: []const c.ValueRef) c.ValueRef {
    const id = c.LLVMLookupIntrinsicID(name.ptr, name.len);
    std.debug.assert(id != 0);
    const decl = c.LLVMGetIntrinsicDeclaration(c.LLVMGetGlobalParent(e.llfn), id, overloads.ptr, overloads.len);
    const fn_ty = c.LLVMIntrinsicGetType(e.ctx, id, overloads.ptr, overloads.len);
    return c.LLVMBuildCall2(e.b, fn_ty, decl, args.ptr, @intCast(args.len), "");
}

/// The column pointer `field` of the `soa []T` value at `base`.
fn soaColumn(e: *FnEmitter, base: ir.Operand, field: i64) Error!c.ValueRef {
    const ptr_ty = llType(e.ctx, .of(.ptr));
    const idx = c.LLVMConstInt(c.LLVMIntTypeInContext(e.ctx, 64), @intCast(field), 0);
    const slot = c.LLVMBuildGEP2(e.b, ptr_ty, try e.operand(base, .void), &.{idx}, 1, "");
    return c.LLVMBuildLoad2(e.b, ptr_ty, slot, "");
}

/// The address of element `i` (operand 1) of SoA column `field` (operand 2),
/// whose elements have type `elem`.
fn soaElem(e: *FnEmitter, i: ir.Inst, elem: ir.Type) Error!c.ValueRef {
    const col = try soaColumn(e, i.operands[0], i.operands[2].int);
    return c.LLVMBuildGEP2(e.b, llType(e.ctx, elem), col, &.{try e.val(i, 1)}, 1, "");
}

/// Converts integer `v` of type `from` to `to` (scalar integers): truncates,
/// or zero/sign-extends per `signed`.
fn resize(e: *FnEmitter, v: c.ValueRef, from: ir.Type, to: ir.Type, signed: bool) c.ValueRef {
    const fb = bits(from.scalar);
    const tb = bits(to.scalar);
    if (fb == tb) return v;
    const op: c.Opcode = if (tb < fb) .trunc else if (signed) .sext else .zext;
    return c.LLVMBuildCast(e.b, op, v, llType(e.ctx, to), "");
}

fn bfExtract(e: *FnEmitter, i: ir.Inst, ty: ir.Type) Error!c.ValueRef {
    const ut = typeOf(e, i.operands[0]);
    const llu = llType(e.ctx, ut);
    const ub = bits(ut.scalar);
    const off: u32 = @intCast(i.operands[1].int);
    const width: u32 = @intCast(i.operands[2].int);
    var x = try e.val(i, 0);
    if (i.flags.signed) {
        // Move the field to the top, then shift it down arithmetically.
        if (ub - off - width != 0) x = c.LLVMBuildBinOp(e.b, .shl, x, c.LLVMConstInt(llu, ub - off - width, 0), "");
        if (ub - width != 0) x = c.LLVMBuildBinOp(e.b, .ashr, x, c.LLVMConstInt(llu, ub - width, 0), "");
    } else {
        if (off != 0) x = c.LLVMBuildBinOp(e.b, .lshr, x, c.LLVMConstInt(llu, off, 0), "");
        if (width != ub) x = c.LLVMBuildBinOp(e.b, .@"and", x, c.LLVMConstInt(llu, lowMask(width), 0), "");
    }
    return resize(e, x, ut, ty, i.flags.signed);
}

fn bfInsert(e: *FnEmitter, i: ir.Inst, ty: ir.Type) Error!c.ValueRef {
    const llu = llType(e.ctx, ty);
    const ub = bits(ty.scalar);
    const off: u32 = @intCast(i.operands[2].int);
    const width: u32 = @intCast(i.operands[3].int);
    const field = lowMask(width) << @intCast(off);
    var v = resize(e, try e.val(i, 1), typeOf(e, i.operands[1]), ty, false);
    if (width == ub) return v; // the field is the whole unit
    if (off != 0) v = c.LLVMBuildBinOp(e.b, .shl, v, c.LLVMConstInt(llu, off, 0), "");
    v = c.LLVMBuildBinOp(e.b, .@"and", v, c.LLVMConstInt(llu, field, 0), "");
    const kept = c.LLVMBuildBinOp(e.b, .@"and", try e.val(i, 0), c.LLVMConstInt(llu, ~field & lowMask(ub), 0), "");
    return c.LLVMBuildBinOp(e.b, .@"or", kept, v, "");
}

fn checkedArith(e: *FnEmitter, i: ir.Inst, ty: ir.Type) Error!c.ValueRef {
    const s = i.flags.signed;
    const name = switch (i.op) {
        .@"add.trap" => if (s) "llvm.sadd.with.overflow" else "llvm.uadd.with.overflow",
        .@"sub.trap" => if (s) "llvm.ssub.with.overflow" else "llvm.usub.with.overflow",
        .@"mul.trap" => if (s) "llvm.smul.with.overflow" else "llvm.umul.with.overflow",
        else => unreachable,
    };
    const pair = callIntrinsic(e, name, &.{llType(e.ctx, ty)}, &.{ try e.val(i, 0), try e.val(i, 1) });
    const r = c.LLVMBuildExtractValue(e.b, pair, 0, "");
    var ovf = c.LLVMBuildExtractValue(e.b, pair, 1, "");
    if (ty.isVector()) ovf = callIntrinsic(e, "llvm.vector.reduce.or", &.{llType(e.ctx, .vec(ty.lanes, .i1))}, &.{ovf});
    trapIf(e, ovf, trap_overflow);
    return r;
}

/// Branches to a new cold block that traps with `kind` when `fail` is true,
/// and leaves the builder at the start of a new fall-through block placed
/// right after the current one (trap blocks stay at the end).
fn trapIf(e: *FnEmitter, fail: c.ValueRef, kind: u32) void {
    const trap_bb = c.LLVMAppendBasicBlockInContext(e.ctx, e.llfn, "trap");
    const cont = c.LLVMAppendBasicBlockInContext(e.ctx, e.llfn, "cont");
    c.LLVMMoveBasicBlockAfter(cont, c.LLVMGetInsertBlock(e.b));
    _ = c.LLVMBuildCondBr(e.b, fail, trap_bb, cont);
    c.LLVMPositionBuilderAtEnd(e.b, trap_bb);
    _ = trapCall(e, kind);
    _ = c.LLVMBuildUnreachable(e.b);
    c.LLVMPositionBuilderAtEnd(e.b, cont);
}

/// Calls `pyro_rt_trap(kind, msg, msg_len, file, file_len, line)` with an
/// empty message and location, declaring it `noreturn cold` on first use.
fn trapCall(e: *FnEmitter, kind: u32) c.ValueRef {
    const i32_ty = c.LLVMIntTypeInContext(e.ctx, 32);
    // shortcut: `usize` is i64; switch to the target's pointer width once T088 sets the data layout.
    const usize_ty = c.LLVMIntTypeInContext(e.ctx, 64);
    const ptr_ty = llType(e.ctx, .of(.ptr));
    const params = [_]c.TypeRef{ i32_ty, ptr_ty, usize_ty, ptr_ty, usize_ty, i32_ty };
    const fn_ty = c.LLVMFunctionType(c.LLVMVoidTypeInContext(e.ctx), &params, params.len, 0);
    const mod = c.LLVMGetGlobalParent(e.llfn);
    const callee = c.LLVMGetNamedFunction(mod, "pyro_rt_trap") orelse blk: {
        const f = c.LLVMAddFunction(mod, "pyro_rt_trap", fn_ty);
        inline for (.{ "noreturn", "cold", "nounwind" }) |a| emit.addAttr(e.ctx, f, c.attribute_function_index, a, 0);
        break :blk f;
    };
    const null_ptr = c.LLVMConstNull(ptr_ty);
    const zero = c.LLVMConstNull(usize_ty);
    const args = [_]c.ValueRef{ c.LLVMConstInt(i32_ty, kind, 0), null_ptr, zero, null_ptr, zero, c.LLVMConstNull(i32_ty) };
    return c.LLVMBuildCall2(e.b, fn_ty, callee, &args, args.len, "");
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const verify = @import("../../pir/verify.zig");
const Emitted = emit.Emitted;
const llvmTest = emit.llvmTest;

/// Emitted and LLVM-verified IR of `src`, which must also pass the P-IR
/// verifier.
pub fn emitVerified(src: []const u8) !Emitted {
    var m = try emit.parseText(src);
    defer m.deinit();
    var failure: verify.Failure = .{};
    verify.verify(testing.allocator, &m, &failure) catch |err| {
        std.debug.print("P-IR verifier: {f}\n", .{failure});
        return err;
    };
    return Emitted.init(src);
}

/// JIT-compiles `x` (see `Emitted.jit`) and returns its function `name` as `F`.
pub fn jitFn(comptime F: type, x: *Emitted, name: [:0]const u8, ee: *c.ExecutionEngineRef) !F {
    return @ptrFromInt(try x.jit(name, ee));
}

/// Function `name` of a module already JIT-compiled into `ee`, as `F`.
pub fn fnAddr(comptime F: type, ee: c.ExecutionEngineRef, name: [:0]const u8) !F {
    const addr = c.LLVMGetFunctionAddress(ee, name.ptr);
    try testing.expect(addr != 0);
    return @ptrFromInt(@as(usize, @intCast(addr)));
}

test "globals, memory access flags, gep, memcpy and memset" {
    try llvmTest(struct {
        fn run() !void {
            var x = try emitVerified(
                \\global @counter: i64 = 7 align 16
                \\global @msg: i8 = "hi" readonly
                \\global @pi: f64 = 3.5
                \\global @table: vec<4 x i32> = zeroinit
                \\fn @mem(%dst: ptr, %src: ptr, %n: i64) -> i64 {
                \\^entry:
                \\  %slot: ptr = alloca i64, align 8
                \\  %v: i64 = load %src, align 4
                \\  %a: i64 = load volatile atomic(acquire) %src, align 8
                \\  %r: i32 = load atomic(relaxed) %src
                \\  %g: i64 = load @counter
                \\  store %v, %slot
                \\  store volatile %a, %dst, align 2
                \\  store atomic(seq_cst) %g, @counter, align 8
                \\  %h: i64 = load atomic(acquire) @counter
                \\  store atomic(relaxed) %h, %slot
                \\  %q: ptr = gep %dst, %n, 12
                \\  memcpy %q, %src, %n, align 4
                \\  %zero: i8 = const 0
                \\  memset %dst, %zero, %n
                \\  ret %h
                \\}
            );
            defer x.deinit();
            // Natural alignment comes from the module's data layout; without
            // one (set by T088), LLVM's default aligns i64 to 4. Alignless
            // atomics are aligned to their size instead.
            try x.expect(&.{
                "@counter = global i64 7, align 16",
                "@msg = constant [2 x i8] c\"hi\"",
                "@pi = global double 3.500000e+00",
                "@table = global <4 x i32> zeroinitializer",
                "%slot = alloca i64, align 8",
                "%v = load i64, ptr %src, align 4",
                "%a = load atomic volatile i64, ptr %src acquire, align 8",
                "%r = load atomic i32, ptr %src monotonic, align 4",
                "%g = load i64, ptr @counter, align 4",
                "store i64 %v, ptr %slot, align 4",
                "store volatile i64 %a, ptr %dst, align 2",
                "store atomic i64 %g, ptr @counter seq_cst, align 8",
                "%h = load atomic i64, ptr @counter acquire, align 8",
                "store atomic i64 %h, ptr %slot monotonic, align 8",
                "%q = getelementptr [12 x i8], ptr %dst, i64 %n",
                "call void @llvm.memcpy.p0.p0.i64(ptr align 4 %q, ptr align 4 %src, i64 %n, i1 false)",
                "call void @llvm.memset.p0.i64(ptr %dst, i8 0, i64 %n, i1 false)",
            }, &.{});

            var ee: c.ExecutionEngineRef = undefined;
            const mem = try jitFn(*const fn ([*]u8, [*]const u8, i64) callconv(.c) i64, &x, "mem", &ee);
            defer c.LLVMDisposeExecutionEngine(ee);
            var src: [24]u8 align(8) = undefined;
            for (&src, 0..) |*s, k| s.* = @intCast(k + 1);
            var dst: [48]u8 align(8) = @splat(0xAA);
            try testing.expectEqual(@as(i64, 7), mem(&dst, &src, 3));
            // The volatile store wrote src[0..8] to dst, memcpy copied 3
            // bytes to dst + 3 * 12, then memset zeroed dst[0..3].
            try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 4, 5, 6, 7, 8, 0xAA }, dst[0..9]);
            try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 0xAA }, dst[36..40]);
        }
    }.run);
}

test "soa columns follow the soa []T layout" {
    try llvmTest(struct {
        fn run() !void {
            var x = try emitVerified(
                \\fn @soa(%s: ptr, %i: i64) -> f64 {
                \\^entry:
                \\  %a: i32 = soa.load %s, %i, 0
                \\  %b: f64 = soa.load %s, %i, 1
                \\  %af: f64 = sitofp %a
                \\  %sum: f64 = fadd %af, %b
                \\  soa.store %s, %i, 1, %sum
                \\  %col: ptr = soa.col %s, 1
                \\  %first: f64 = load %col
                \\  ret %first
                \\}
            );
            defer x.deinit();
            try x.expect(&.{
                "getelementptr ptr, ptr %s, i64 0",
                "load ptr, ptr",
                "getelementptr i32, ptr",
                "%a = load i32, ptr",
                "getelementptr ptr, ptr %s, i64 1",
                "getelementptr double, ptr",
                "%b = load double, ptr",
                "store double %sum, ptr",
                "%col = load ptr, ptr",
            }, &.{});

            var ee: c.ExecutionEngineRef = undefined;
            const f = try jitFn(*const fn (*anyopaque, i64) callconv(.c) f64, &x, "soa", &ee);
            defer c.LLVMDisposeExecutionEngine(ee);
            var a = [_]i32{ 10, 20, 30 };
            var b = [_]f64{ 0.5, 1.5, 2.5 };
            var s: extern struct { a: [*]i32, b: [*]f64, len: usize } = .{ .a = &a, .b = &b, .len = 3 };
            try testing.expectEqual(@as(f64, 0.5), f(&s, 2));
            try testing.expectEqual(@as(f64, 32.5), b[2]);
            try testing.expectEqual(@as(f64, 10.5), f(&s, 0));
            try testing.expectEqualSlices(i32, &.{ 10, 20, 30 }, &a);
        }
    }.run);
}

test "bit fields extract and insert" {
    try llvmTest(struct {
        fn run() !void {
            var x = try emitVerified(
                \\fn @sx(%u: i32) -> i8 {
                \\^entry:
                \\  %r: i8 = bf.extract signed %u, 3, 5
                \\  ret %r
                \\}
                \\fn @zx(%u: i32) -> i64 {
                \\^entry:
                \\  %r: i64 = bf.extract %u, 3, 5
                \\  ret %r
                \\}
                \\fn @top(%u: i16) -> i16 {
                \\^entry:
                \\  %r: i16 = bf.extract signed %u, 4, 12
                \\  ret %r
                \\}
                \\fn @ins(%u: i32, %v: i8) -> i32 {
                \\^entry:
                \\  %r: i32 = bf.insert %u, %v, 8, 4
                \\  ret %r
                \\}
                \\fn @ins64(%u: i8, %v: i64) -> i8 {
                \\^entry:
                \\  %r: i8 = bf.insert %u, %v, 0, 8
                \\  ret %r
                \\}
            );
            defer x.deinit();
            try x.expect(&.{
                "%0 = shl i32 %u, 24",
                "%1 = ashr i32 %0, 27",
                "%r = trunc i32 %1 to i8",
                "%0 = lshr i32 %u, 3",
                "%1 = and i32 %0, 31",
                "%r = zext i32 %1 to i64",
                "%r = ashr i16 %u, 4",
                "zext i8 %v to i32",
                "%1 = shl i32 %0, 8",
                "%2 = and i32 %1, 3840",
                "%3 = and i32 %u, -3841",
                "%r = or i32 %3, %2",
                "%r = trunc i64 %v to i8",
                "ret i8 %r",
            }, &.{});

            var ee: c.ExecutionEngineRef = undefined;
            const sx = try jitFn(*const fn (u32) callconv(.c) i8, &x, "sx", &ee);
            defer c.LLVMDisposeExecutionEngine(ee);
            const zx = try fnAddr(*const fn (u32) callconv(.c) u64, ee, "zx");
            const top = try fnAddr(*const fn (u16) callconv(.c) i16, ee, "top");
            const ins = try fnAddr(*const fn (u32, u8) callconv(.c) u32, ee, "ins");
            const ins64 = try fnAddr(*const fn (u8, u64) callconv(.c) u8, ee, "ins64");
            for ([_]u32{ 0, 0xFFFF_FFFF, 0b10110_101, 0b01011_000, 0xDEAD_BEEF }) |u| {
                const field: u5 = @truncate(u >> 3);
                try testing.expectEqual(@as(i8, @as(i5, @bitCast(field))), sx(u));
                try testing.expectEqual(@as(u64, field), zx(u));
                const v: u8 = @truncate(u *% 7);
                try testing.expectEqual((u & ~@as(u32, 0xF00)) | (@as(u32, v & 0xF) << 8), ins(u, v));
            }
            try testing.expectEqual(@as(i16, -1), top(0xFFF0));
            try testing.expectEqual(@as(i16, 0x7FF), top(0x7FF0));
            try testing.expectEqual(@as(u8, 0x34), ins64(0xFF, 0x1234));
        }
    }.run);
}

test "fma and saturating conversions" {
    try llvmTest(struct {
        fn run() !void {
            var x = try emitVerified(
                \\fn @fused(%a: f64, %b: f64, %c: f64) -> f64 {
                \\^entry:
                \\  %r: f64 = fma %a, %b, %c
                \\  ret %r
                \\}
                \\fn @fma_fast(%a: vec<4 x f32>) -> vec<4 x f32> {
                \\^entry:
                \\  %r: vec<4 x f32> = fma fast %a, %a, %a
                \\  ret %r
                \\}
                \\fn @tou(%x: f64) -> i8 {
                \\^entry:
                \\  %r: i8 = fptoui.sat %x
                \\  ret %r
                \\}
                \\fn @tos(%x: f32) -> i32 {
                \\^entry:
                \\  %r: i32 = fptosi.sat %x
                \\  ret %r
                \\}
            );
            defer x.deinit();
            try x.expect(&.{
                "%r = call double @llvm.fma.f64(double %a, double %b, double %c)",
                "%r = call fast <4 x float> @llvm.fma.v4f32(",
                "%r = call i8 @llvm.fptoui.sat.i8.f64(double %x)",
                "%r = call i32 @llvm.fptosi.sat.i32.f32(float %x)",
            }, &.{});

            var ee: c.ExecutionEngineRef = undefined;
            const tou = try jitFn(*const fn (f64) callconv(.c) u8, &x, "tou", &ee);
            defer c.LLVMDisposeExecutionEngine(ee);
            const tos = try fnAddr(*const fn (f32) callconv(.c) i32, ee, "tos");
            const fma = try fnAddr(*const fn (f64, f64, f64) callconv(.c) f64, ee, "fused");
            try testing.expectEqual(@as(u8, 0), tou(std.math.nan(f64)));
            try testing.expectEqual(@as(u8, 255), tou(300.0));
            try testing.expectEqual(@as(u8, 0), tou(-5.0));
            try testing.expectEqual(@as(u8, 42), tou(42.9));
            try testing.expectEqual(@as(i32, 0), tos(std.math.nan(f32)));
            try testing.expectEqual(@as(i32, std.math.maxInt(i32)), tos(1e10));
            try testing.expectEqual(@as(i32, std.math.minInt(i32)), tos(-std.math.inf(f32)));
            try testing.expectEqual(@as(i32, -3), tos(-3.7));
            // Fused: the exact product 0.1 * 10 is not 1, so the result is not 0.
            try testing.expectEqual(@mulAdd(f64, 0.1, 10.0, -1.0), fma(0.1, 10.0, -1.0));
            try testing.expect(fma(0.1, 10.0, -1.0) != 0.0);
        }
    }.run);
}

test "calls, indirect calls and musttail recursion without stack growth" {
    try llvmTest(struct {
        fn run() !void {
            var x = try emitVerified(
                \\fn @ext(%x: f32) -> f64
                \\fn @inc(%x: i32) -> i32 {
                \\^entry:
                \\  %one: i32 = const 1
                \\  %r: i32 = add %x, %one
                \\  ret %r
                \\}
                \\fn @apply(%fp: ptr, %x: i32) -> i32 {
                \\^entry:
                \\  %a: i32 = call @inc(%x)
                \\  %b: i32 = call.indirect %fp(%a)
                \\  %c: i32 = call @inc(%b)
                \\  ret %c
                \\}
                \\fn @noop(%x: f32) -> void {
                \\^entry:
                \\  %d: f64 = call @ext(%x)
                \\  ret
                \\}
                \\fn @count(%n: i64, %acc: i64) -> i64 {
                \\^entry:
                \\  %zero: i64 = const 0
                \\  %done: i1 = icmp eq %n, %zero
                \\  cond_br %done, ^out, ^more
                \\^out:
                \\  ret %acc
                \\^more:
                \\  %one: i64 = const 1
                \\  %n1: i64 = sub %n, %one
                \\  %a1: i64 = add %acc, %one
                \\  %r: i64 = call.tail @count(%n1, %a1)
                \\  ret %r
                \\}
            );
            defer x.deinit();
            try x.expect(&.{
                "declare double @ext(float)",
                "%a = call i32 @inc(i32 %x)",
                "%b = call i32 %fp(i32 %a)",
                "%c = call i32 @inc(i32 %b)",
                "%d = call double @ext(float %x)",
                "%r = musttail call i64 @count(i64 %n1, i64 %a1)",
                "ret i64 %r",
            }, &.{});

            var ee: c.ExecutionEngineRef = undefined;
            const count = try jitFn(*const fn (i64, i64) callconv(.c) i64, &x, "count", &ee);
            defer c.LLVMDisposeExecutionEngine(ee);
            const apply = try fnAddr(*const fn (*const anyopaque, i32) callconv(.c) i32, ee, "apply");
            const double = struct {
                fn f(v: i32) callconv(.c) i32 {
                    return v * 2;
                }
            }.f;
            try testing.expectEqual(@as(i32, 2 * (5 + 1) + 1), apply(&double, 5));
            // 50M frames of even 16 bytes would need 800 MB of stack.
            try testing.expectEqual(@as(i64, 50_000_000), count(50_000_000, 0));
        }
    }.run);
}

extern "c" fn fork() c_int;

/// Stand-in for `pyro_rt_trap` in JIT tests: exits with status 100 + kind.
fn testTrap(kind: u32, _: ?[*]const u8, _: usize, _: ?[*]const u8, _: usize, _: u32) callconv(.c) noreturn {
    std.c._exit(@intCast(100 + kind));
}

/// Runs `f(args)` in a child process and returns its exit status.
fn exitStatus(f: anytype, args: anytype) !u8 {
    const pid = fork();
    try testing.expect(pid >= 0);
    if (pid == 0) {
        _ = @call(.auto, f, args);
        std.c._exit(0);
    }
    var status: c_int = 0;
    try testing.expectEqual(pid, std.c.waitpid(pid, &status, 0));
    const s: u32 = @bitCast(status);
    try testing.expect(std.c.W.IFEXITED(s));
    return std.c.W.EXITSTATUS(s);
}

test "checked arithmetic, bounds and trap call the trap runtime" {
    try llvmTest(struct {
        fn run() !void {
            var x = try emitVerified(
                \\fn @sadd(%a: i32, %b: i32) -> i32 {
                \\^entry:
                \\  %r: i32 = add.trap signed %a, %b
                \\  ret %r
                \\}
                \\fn @usub(%a: i8, %b: i8) -> i8 {
                \\^entry:
                \\  %r: i8 = sub.trap %a, %b
                \\  ret %r
                \\}
                \\fn @vmul(%a: vec<4 x i16>) -> vec<4 x i16> {
                \\^entry:
                \\  %r: vec<4 x i16> = mul.trap signed %a, %a
                \\  ret %r
                \\}
                \\fn @at(%p: ptr, %i: i64, %len: i64) -> i32 {
                \\^entry:
                \\  bounds %i, %len
                \\  %q: ptr = gep %p, %i, 4
                \\  %v: i32 = load %q
                \\  %c: i1 = icmp eq %v, %v
                \\  cond_br %c, ^ok(%v), ^bad
                \\^ok(%r: i32):
                \\  ret %r
                \\^bad:
                \\  trap 8, 3
                \\  unreachable
                \\}
            );
            defer x.deinit();
            try x.expect(&.{
                "call { i32, i1 } @llvm.sadd.with.overflow.i32(i32 %a, i32 %b)",
                "%r = extractvalue { i32, i1 }",
                "br i1 %1, label %trap, label %cont",
                "cont:",
                "ret i32 %r",
                "trap:",
                "call void @pyro_rt_trap(i32 1, ptr null, i64 0, ptr null, i64 0, i32 0)",
                "unreachable",
                "@llvm.usub.with.overflow.i8(i8 %a, i8 %b)",
                "@llvm.smul.with.overflow.v4i16(<4 x i16> %a, <4 x i16> %a)",
                "@llvm.vector.reduce.or.v4i1(",
                "%0 = icmp uge i64 %i, %len",
                "br i1 %0, label %trap, label %cont",
                "cont:",
                "%v = load i32",
                "call void @pyro_rt_trap(i32 8, ptr null, i64 0, ptr null, i64 0, i32 0)",
                "%r = phi i32 [ %v, %cont ]",
                "trap:",
                "call void @pyro_rt_trap(i32 0,",
                "declare void @pyro_rt_trap(i32, ptr, i64, ptr, i64, i32) #",
                "cold noreturn nounwind",
            }, &.{});

            c.LLVMAddSymbol("pyro_rt_trap", &testTrap);
            var ee: c.ExecutionEngineRef = undefined;
            const sadd = try jitFn(*const fn (i32, i32) callconv(.c) i32, &x, "sadd", &ee);
            defer c.LLVMDisposeExecutionEngine(ee);
            const usub = try fnAddr(*const fn (u8, u8) callconv(.c) u8, ee, "usub");
            const vmul = try fnAddr(*const fn (@Vector(4, i16)) callconv(.c) @Vector(4, i16), ee, "vmul");
            const at = try fnAddr(*const fn ([*]const i32, i64, i64) callconv(.c) i32, ee, "at");

            try testing.expectEqual(@as(i32, -1), sadd(std.math.maxInt(i32), std.math.minInt(i32)));
            try testing.expectEqual(@as(u8, 0), usub(200, 200));
            try testing.expectEqual(@Vector(4, i16){ 1, 4, 32761, 0 }, vmul(.{ 1, -2, 181, 0 }));
            const xs = [_]i32{ 10, 20, 30 };
            try testing.expectEqual(@as(i32, 30), at(&xs, 2, 3));

            const overflow: u8 = 100 + 1;
            try testing.expectEqual(overflow, try exitStatus(sadd, .{ std.math.maxInt(i32), 1 }));
            try testing.expectEqual(overflow, try exitStatus(usub, .{ 1, 2 }));
            try testing.expectEqual(overflow, try exitStatus(vmul, .{@Vector(4, i16){ 1, 2, 182, 3 }}));
            try testing.expectEqual(@as(u8, 100), try exitStatus(at, .{ &xs, 3, 3 }));
            try testing.expectEqual(@as(u8, 100), try exitStatus(at, .{ &xs, -1, 3 }));
        }
    }.run);
}

test "atomic read-modify-write, compare-exchange and fences" {
    try llvmTest(struct {
        fn run() !void {
            var x = try emitVerified(
                \\fn @atomics(%p: ptr, %v: i32, %q: ptr, %f: f64) -> i32 {
                \\^entry:
                \\  %x0: i32 = atomic.rmw xchg %p, %v, relaxed
                \\  %x1: i32 = atomic.rmw add %p, %v, acquire
                \\  %x2: i32 = atomic.rmw sub %p, %v, release
                \\  %x3: i32 = atomic.rmw and %p, %v, acq_rel
                \\  %x4: i32 = atomic.rmw or %p, %v, seq_cst
                \\  %x5: i32 = atomic.rmw xor %p, %v, seq_cst
                \\  %x6: i32 = atomic.rmw nand %p, %v, seq_cst
                \\  %x7: i32 = atomic.rmw min %p, %v, seq_cst
                \\  %x8: i32 = atomic.rmw max %p, %v, seq_cst
                \\  %x9: i32 = atomic.rmw umin %p, %v, seq_cst
                \\  %x10: i32 = atomic.rmw umax %p, %v, seq_cst
                \\  %xf: f64 = atomic.rmw xchg %q, %f, seq_cst
                \\  %old: i32, %ok: i1 = cmpxchg %p, %x10, %v, acq_rel, acquire
                \\  %old2: i32 = cmpxchg %p, %old, %v, seq_cst, relaxed
                \\  fence acquire
                \\  fence seq_cst
                \\  %z: i32 = zext %ok
                \\  %r: i32 = add %old2, %z
                \\  ret %r
                \\}
            );
            defer x.deinit();
            try x.expect(&.{
                "%x0 = atomicrmw xchg ptr %p, i32 %v monotonic",
                "%x1 = atomicrmw add ptr %p, i32 %v acquire",
                "%x2 = atomicrmw sub ptr %p, i32 %v release",
                "%x3 = atomicrmw and ptr %p, i32 %v acq_rel",
                "%x4 = atomicrmw or ptr %p, i32 %v seq_cst",
                "%x5 = atomicrmw xor ptr %p, i32 %v seq_cst",
                "%x6 = atomicrmw nand ptr %p, i32 %v seq_cst",
                "%x7 = atomicrmw min ptr %p, i32 %v seq_cst",
                "%x8 = atomicrmw max ptr %p, i32 %v seq_cst",
                "%x9 = atomicrmw umin ptr %p, i32 %v seq_cst",
                "%x10 = atomicrmw umax ptr %p, i32 %v seq_cst",
                "%xf = atomicrmw xchg ptr %q, double %f seq_cst",
                "cmpxchg ptr %p, i32 %x10, i32 %v acq_rel acquire",
                "%old = extractvalue { i32, i1 }",
                "%ok = extractvalue { i32, i1 }",
                "cmpxchg ptr %p, i32 %old, i32 %v seq_cst monotonic",
                "%old2 = extractvalue { i32, i1 }",
                "fence acquire",
                "fence seq_cst",
            }, &.{"weak"});

            var ee: c.ExecutionEngineRef = undefined;
            const f = try jitFn(*const fn (*i32, i32, *f64, f64) callconv(.c) i32, &x, "atomics", &ee);
            defer c.LLVMDisposeExecutionEngine(ee);
            var cell: i32 = 5;
            var fcell: f64 = 1.5;
            // Trace: xchg 3, +3=6, -3=3, &3=3, |3=3, ^3=0, nand 3=-1, min=-1,
            // max=3, umin=3, umax=3 (x10 = 3); cmpxchg(3 -> 3) succeeds,
            // cmpxchg(3 -> 3) again: old2 = 3, plus ok = 1.
            try testing.expectEqual(@as(i32, 4), f(&cell, 3, &fcell, 2.5));
            try testing.expectEqual(@as(i32, 3), cell);
            try testing.expectEqual(@as(f64, 2.5), fcell);
        }
    }.run);
}
