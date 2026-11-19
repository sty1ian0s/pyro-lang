//! P-IR -> LLVM IR (B.6.2): globals, functions, parameter and function
//! attributes, scalar arithmetic, comparisons, conversions and terminators.
//! Memory, calls, checks, atomics and intrinsics are in `emit_mem.zig`,
//! vector operations in `emit_vec.zig`.
//!
//! Block parameters become φ-nodes: each P-IR block gets its φs up front, and
//! every branch records an edge whose arguments are added as incoming values
//! once all blocks are emitted. Blocks are emitted in reverse postorder, so a
//! value's definition is always emitted before its uses; unreachable blocks
//! are dropped. When a `cond_br`/`switch` reaches the same block with
//! arguments more than once, the extra edges go through a fresh block, since
//! LLVM φs cannot tell such edges apart.
//!
//! Float operations get fast-math flags only when the P-IR `fast` flag is set
//! (strict IEEE by default, §6.4.4). `nuw`/`nsw` are copied from P-IR.
//!
//! The input must pass the P-IR verifier. Opcodes the backend does not
//! cover (`handle.lookup` and the concurrency group, which are lowered to
//! runtime calls before codegen) give `error.Unsupported`. A `@name` operand
//! is the address of that function or global.
//!
//! Every function here references LLVM symbols, so only call it when
//! `@import("build_options").llvm` is true.

const std = @import("std");
const c = @import("c.zig");
const ir = @import("../../pir/ir.zig");
const emit_mem = @import("emit_mem.zig");
const emit_vec = @import("emit_vec.zig");

const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error || error{
    /// An opcode, operand form or module item this backend does not emit yet.
    Unsupported,
};

/// Lowers `m` into a new LLVM module named `name` owned by `ctx`. The caller
/// owns the result (`c.LLVMDisposeModule`). `gpa` is used for scratch only.
pub fn emitModule(gpa: Allocator, ctx: c.ContextRef, m: *const ir.Module, name: [:0]const u8) Error!c.ModuleRef {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const mod = c.LLVMModuleCreateWithNameInContext(name.ptr, ctx);
    errdefer c.LLVMDisposeModule(mod);
    const b = c.LLVMCreateBuilderInContext(ctx);
    defer c.LLVMDisposeBuilder(b);

    // Declare every global and function first so bodies can refer to any of them.
    const globals = try arena.alloc(c.ValueRef, m.globals.items.len);
    for (globals, m.globals.items) |*llg, g| llg.* = try emit_mem.declareGlobal(arena, ctx, mod, g);
    const fns = try arena.alloc(c.ValueRef, m.functions.items.len);
    for (fns, m.functions.items) |*llfn, f| llfn.* = try declare(arena, ctx, mod, f);
    for (fns, m.functions.items) |llfn, f| {
        if (f.isDeclaration()) continue;
        var e: FnEmitter = .{ .arena = arena, .ctx = ctx, .b = b, .m = m, .globals = globals, .fns = fns, .f = f, .llfn = llfn };
        try e.body();
    }
    return mod;
}

fn declare(arena: Allocator, ctx: c.ContextRef, mod: c.ModuleRef, f: *const ir.Function) Error!c.ValueRef {
    const params = try arena.alloc(c.TypeRef, f.params.items.len);
    for (params, f.params.items) |*t, p| t.* = llType(ctx, f.typeOf(p.value));
    const fn_ty = c.LLVMFunctionType(llType(ctx, f.ret), params.ptr, @intCast(params.len), 0);
    const llfn = c.LLVMAddFunction(mod, try arena.dupeSentinel(u8, f.name, 0), fn_ty);

    for (f.params.items, 0..) |p, i| {
        const idx: c_uint = @intCast(i + 1);
        setName(c.LLVMGetParam(llfn, @intCast(i)), f.values.items[p.value.index()].name);
        if (p.attrs.@"noalias") addAttr(ctx, llfn, idx, "noalias", 0);
        if (p.attrs.readonly) addAttr(ctx, llfn, idx, "readonly", 0);
        if (p.attrs.@"align" != 0) addAttr(ctx, llfn, idx, "align", p.attrs.@"align");
        if (p.attrs.dereferenceable != 0) addAttr(ctx, llfn, idx, "dereferenceable", p.attrs.dereferenceable);
    }
    const fi = c.attribute_function_index;
    // `@inline` is an inlining requirement (§8.8), hence `alwaysinline`.
    if (f.attrs.@"inline") addAttr(ctx, llfn, fi, "alwaysinline", 0);
    if (f.attrs.@"noinline") addAttr(ctx, llfn, fi, "noinline", 0);
    if (f.attrs.cold) addAttr(ctx, llfn, fi, "cold", 0);
    if (f.attrs.noreturn) addAttr(ctx, llfn, fi, "noreturn", 0);
    return llfn;
}

pub fn addAttr(ctx: c.ContextRef, llfn: c.ValueRef, idx: c_uint, comptime name: []const u8, val: u64) void {
    const kind = c.LLVMGetEnumAttributeKindForName(name.ptr, name.len);
    std.debug.assert(kind != 0);
    c.LLVMAddAttributeAtIndex(llfn, idx, c.LLVMCreateEnumAttribute(ctx, kind, val));
}

fn setName(v: c.ValueRef, name: []const u8) void {
    if (name.len != 0) c.LLVMSetValueName2(v, name.ptr, name.len);
}

/// The LLVM type of a P-IR type (`vec<N x T>` becomes `<N x T>`).
pub fn llType(ctx: c.ContextRef, t: ir.Type) c.TypeRef {
    const elem = switch (t.scalar) {
        .i1 => c.LLVMIntTypeInContext(ctx, 1),
        .i8 => c.LLVMIntTypeInContext(ctx, 8),
        .i16 => c.LLVMIntTypeInContext(ctx, 16),
        .i32 => c.LLVMIntTypeInContext(ctx, 32),
        .i64 => c.LLVMIntTypeInContext(ctx, 64),
        .f32 => c.LLVMFloatTypeInContext(ctx),
        .f64 => c.LLVMDoubleTypeInContext(ctx),
        .ptr => c.LLVMPointerTypeInContext(ctx, 0),
        .void => return c.LLVMVoidTypeInContext(ctx),
    };
    return if (t.isVector()) c.LLVMVectorType(elem, t.lanes) else elem;
}

/// A branch edge whose block arguments still have to be added to the
/// target's φs.
const Edge = struct {
    from: c.BasicBlockRef,
    target: ir.Target,
};

/// Per-function emission state, shared with `emit_mem.zig` and `emit_vec.zig`.
pub const FnEmitter = struct {
    arena: Allocator,
    ctx: c.ContextRef,
    b: c.BuilderRef,
    m: *const ir.Module,
    /// LLVM global per entry of `m.globals`.
    globals: []const c.ValueRef,
    /// LLVM function per entry of `m.functions`.
    fns: []const c.ValueRef,
    f: *const ir.Function,
    llfn: c.ValueRef,
    /// LLVM value per P-IR value; null until emitted.
    values: []?c.ValueRef = &.{},
    /// LLVM block per P-IR block; null for unreachable blocks.
    blocks: []?c.BasicBlockRef = &.{},
    edges: std.ArrayList(Edge) = .empty,

    fn body(e: *FnEmitter) Error!void {
        const f = e.f;
        e.values = try e.arena.alloc(?c.ValueRef, f.values.items.len);
        @memset(e.values, null);
        e.blocks = try e.arena.alloc(?c.BasicBlockRef, f.blocks.items.len);
        @memset(e.blocks, null);
        for (f.params.items, 0..) |p, i| e.values[p.value.index()] = c.LLVMGetParam(e.llfn, @intCast(i));

        const order = try reversePostorder(e.arena, f);
        for (order) |bi| {
            const blk = f.blocks.items[bi];
            const bb = c.LLVMAppendBasicBlockInContext(e.ctx, e.llfn, try e.arena.dupeSentinel(u8, blk.name, 0));
            e.blocks[bi] = bb;
            c.LLVMPositionBuilderAtEnd(e.b, bb);
            for (blk.params.items) |p| {
                const phi = c.LLVMBuildPhi(e.b, llType(e.ctx, f.typeOf(p)), "");
                setName(phi, f.values.items[p.index()].name);
                e.values[p.index()] = phi;
            }
        }
        for (order) |bi| {
            c.LLVMPositionBuilderAtEnd(e.b, e.blocks[bi].?);
            for (f.blocks.items[bi].insts.items) |inst| try e.emitInst(inst);
        }
        for (e.edges.items) |edge| {
            const params = f.blocks.items[edge.target.block.index()].params.items;
            for (params, edge.target.args) |p, arg| {
                const v = try e.operand(arg, f.typeOf(p));
                c.LLVMAddIncoming(e.values[p.index()].?, &.{v}, &.{edge.from}, 1);
            }
        }
    }

    /// The LLVM value of an operand; literals take type `ty`.
    pub fn operand(e: *FnEmitter, o: ir.Operand, ty: ir.Type) Error!c.ValueRef {
        return switch (o) {
            .value => |v| e.values[v.index()].?, // verified P-IR: defined in a dominating block
            .int => |i| if (ty.scalar.isInt() and !ty.isVector())
                c.LLVMConstInt(llType(e.ctx, ty), @bitCast(i), 0)
            else
                error.Unsupported,
            .float => |x| if (ty.scalar.isFloat() and !ty.isVector())
                c.LLVMConstReal(llType(e.ctx, ty), x)
            else
                error.Unsupported,
            // Verified P-IR names no other symbol.
            .symbol => |name| for (e.m.functions.items, e.fns) |f, llfn| {
                if (std.mem.eql(u8, f.name, name)) break llfn;
            } else for (e.m.globals.items, e.globals) |g, llg| {
                if (std.mem.eql(u8, g.name, name)) break llg;
            } else error.Unsupported,
            .type, .order => error.Unsupported,
        };
    }

    /// The LLVM value of value operand `n` of `i` (a `%value` or `@symbol`).
    pub fn val(e: *FnEmitter, i: ir.Inst, n: usize) Error!c.ValueRef {
        return e.operand(i.operands[n], .void);
    }

    fn emitInst(e: *FnEmitter, i: ir.Inst) Error!void {
        const ty = if (i.results.len == 1) e.f.typeOf(i.result()) else ir.Type.void;
        const v: c.ValueRef = switch (i.op) {
            .@"const" => try e.operand(i.operands[0], ty),
            .add, .sub, .mul, .shl => blk: {
                const r = c.LLVMBuildBinOp(e.b, binOpcode(i.op), try e.val(i, 0), try e.val(i, 1), "");
                // A constant-folded result is not an instruction and has no flags.
                if (c.LLVMIsAInstruction(r) != null) {
                    if (i.flags.nuw) c.LLVMSetNUW(r, 1);
                    if (i.flags.nsw) c.LLVMSetNSW(r, 1);
                }
                break :blk r;
            },
            .udiv, .sdiv, .urem, .srem, .@"and", .@"or", .xor, .lshr, .ashr => c.LLVMBuildBinOp(e.b, binOpcode(i.op), try e.val(i, 0), try e.val(i, 1), ""),
            .fadd, .fsub, .fmul, .fdiv, .frem => fastMath(i, c.LLVMBuildBinOp(e.b, binOpcode(i.op), try e.val(i, 0), try e.val(i, 1), "")),
            .fneg => fastMath(i, c.LLVMBuildFNeg(e.b, try e.val(i, 0), "")),
            .icmp => c.LLVMBuildICmp(e.b, intPred(i.pred), try e.val(i, 0), try e.val(i, 1), ""),
            .fcmp => fastMath(i, c.LLVMBuildFCmp(e.b, realPred(i.pred), try e.val(i, 0), try e.val(i, 1), "")),
            .trunc, .zext, .sext, .fptrunc, .fpext, .uitofp, .sitofp, .bitcast, .ptrtoint, .inttoptr => c.LLVMBuildCast(e.b, castOpcode(i.op), try e.val(i, 0), llType(e.ctx, ty), ""),
            .br => blk: {
                // Checks (`bounds`, `*.trap`) may have split the P-IR block.
                const from = c.LLVMGetInsertBlock(e.b);
                break :blk c.LLVMBuildBr(e.b, try e.edgeTo(from, i.targets, 0));
            },
            .cond_br => blk: {
                // Checks (`bounds`, `*.trap`) may have split the P-IR block.
                const from = c.LLVMGetInsertBlock(e.b);
                const t = try e.edgeTo(from, i.targets, 0);
                const f = try e.edgeTo(from, i.targets, 1);
                c.LLVMPositionBuilderAtEnd(e.b, from);
                break :blk c.LLVMBuildCondBr(e.b, try e.val(i, 0), t, f);
            },
            .@"switch" => blk: {
                // Checks (`bounds`, `*.trap`) may have split the P-IR block.
                const from = c.LLVMGetInsertBlock(e.b);
                const dests = try e.arena.alloc(c.BasicBlockRef, i.targets.len);
                for (dests, 0..) |*d, n| d.* = try e.edgeTo(from, i.targets, n);
                c.LLVMPositionBuilderAtEnd(e.b, from);
                const sw = c.LLVMBuildSwitch(e.b, try e.val(i, 0), dests[0], @intCast(dests.len - 1));
                const key_ty = llType(e.ctx, e.f.typeOf(i.operands[0].value));
                for (i.targets[1..], dests[1..]) |t, d| c.LLVMAddCase(sw, c.LLVMConstInt(key_ty, @bitCast(t.key), 0), d);
                break :blk sw;
            },
            .ret => if (i.operands.len == 0) c.LLVMBuildRetVoid(e.b) else c.LLVMBuildRet(e.b, try e.val(i, 0)),
            .@"unreachable" => c.LLVMBuildUnreachable(e.b),
            .splat, .extract, .insert, .shuffle, .select, .@"reduce.add", .@"reduce.mul", .@"reduce.min", .@"reduce.max", .@"reduce.and", .@"reduce.or", .@"load.masked", .@"store.masked" => try emit_vec.emitInst(e, i, ty),
            else => try emit_mem.emitInst(e, i, ty),
        };
        if (i.results.len == 1) {
            e.values[i.result().index()] = v;
            if (c.LLVMIsAInstruction(v) != null) setName(v, e.f.values.items[i.result().index()].name);
        }
    }

    /// The LLVM block that edge `targets[n]` of a terminator in `from` jumps
    /// to, recording its φ arguments. A repeated target with arguments gets
    /// its own forwarding block. May move the builder.
    fn edgeTo(e: *FnEmitter, from: c.BasicBlockRef, targets: []const ir.Target, n: usize) Error!c.BasicBlockRef {
        const t = targets[n];
        const dest = e.blocks[t.block.index()].?;
        if (t.args.len == 0) return dest;
        const repeated = for (targets[0..n]) |prev| {
            if (prev.block == t.block) break true;
        } else false;
        if (!repeated) {
            try e.edges.append(e.arena, .{ .from = from, .target = t });
            return dest;
        }
        const fwd = c.LLVMAppendBasicBlockInContext(e.ctx, e.llfn, "edge");
        c.LLVMPositionBuilderAtEnd(e.b, fwd);
        _ = c.LLVMBuildBr(e.b, dest);
        try e.edges.append(e.arena, .{ .from = fwd, .target = t });
        return fwd;
    }
};

/// Sets every fast-math flag on `v` iff the P-IR instruction has `fast`.
pub fn fastMath(i: ir.Inst, v: c.ValueRef) c.ValueRef {
    if (i.flags.fast and c.LLVMCanValueUseFastMathFlags(v) != 0) c.LLVMSetFastMathFlags(v, c.fast_math_all);
    return v;
}

fn binOpcode(op: ir.Op) c.Opcode {
    return switch (op) {
        inline .add, .sub, .mul, .udiv, .sdiv, .urem, .srem, .@"and", .@"or", .xor, .shl, .lshr, .ashr, .fadd, .fsub, .fmul, .fdiv, .frem => |o| @field(c.Opcode, @tagName(o)),
        else => unreachable,
    };
}

fn castOpcode(op: ir.Op) c.Opcode {
    return switch (op) {
        inline .trunc, .zext, .sext, .fptrunc, .fpext, .uitofp, .sitofp, .bitcast, .ptrtoint, .inttoptr => |o| @field(c.Opcode, @tagName(o)),
        else => unreachable,
    };
}

fn intPred(p: ir.Pred) c.IntPredicate {
    return switch (p) {
        inline .eq, .ne, .ult, .ule, .ugt, .uge, .slt, .sle, .sgt, .sge => |q| @field(c.IntPredicate, @tagName(q)),
        else => unreachable, // the parser and verifier reject float predicates on icmp
    };
}

fn realPred(p: ir.Pred) c.RealPredicate {
    return switch (p) {
        inline .oeq, .one, .olt, .ole, .ogt, .oge, .uno, .ord => |q| @field(c.RealPredicate, @tagName(q)),
        else => unreachable, // the parser and verifier reject integer predicates on fcmp
    };
}

/// Indices of the blocks reachable from the entry, in reverse postorder:
/// every block comes after all blocks that dominate it.
fn reversePostorder(arena: Allocator, f: *const ir.Function) Allocator.Error![]u32 {
    const Frame = struct { block: u32, next: u32 = 0 };
    const seen = try arena.alloc(bool, f.blocks.items.len);
    @memset(seen, false);
    var post: std.ArrayList(u32) = .empty;
    var stack: std.ArrayList(Frame) = .empty;
    if (f.blocks.items.len != 0) {
        seen[0] = true;
        try stack.append(arena, .{ .block = 0 });
    }
    while (stack.items.len != 0) {
        const top = &stack.items[stack.items.len - 1];
        const targets = if (f.blocks.items[top.block].terminator()) |t| t.targets else &.{};
        if (top.next < targets.len) {
            const s = targets[top.next].block.index();
            top.next += 1;
            if (!seen[s]) {
                seen[s] = true;
                try stack.append(arena, .{ .block = s });
            }
        } else {
            try post.append(arena, top.block);
            stack.items.len -= 1;
        }
    }
    std.mem.reverse(u32, post.items);
    return post.items;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const build_options = @import("build_options");
const text = @import("../../pir/text.zig");

pub fn parseText(src: []const u8) !ir.Module {
    var diag: text.Diag = .{};
    return text.parse(testing.allocator, src, &diag) catch |err| {
        std.debug.print("P-IR parse error {d}:{d}: {s}\n", .{ diag.line, diag.col, diag.msg });
        return err;
    };
}

test "reverse postorder puts dominators first and drops unreachable blocks" {
    var m = try parseText(
        \\fn @f(%c: i1) -> void {
        \\^entry:
        \\  br ^head
        \\^dead:
        \\  br ^exit
        \\^exit:
        \\  ret
        \\^head:
        \\  cond_br %c, ^body, ^exit
        \\^body:
        \\  br ^head
        \\}
    );
    defer m.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const order = try reversePostorder(arena.allocator(), m.functions.items[0]);
    // entry=0 dead=1 exit=2 head=3 body=4
    try testing.expectEqualSlices(u32, &.{ 0, 3, 2, 4 }, order);
}

/// Emitted and verified LLVM IR of a P-IR module, for FileCheck-style tests.
pub const Emitted = struct {
    ctx: c.ContextRef,
    /// Null once `jit` hands the module to an execution engine.
    mod: ?c.ModuleRef,
    ir_text: []const u8,

    pub fn init(src: []const u8) !Emitted {
        var m = try parseText(src);
        defer m.deinit();
        const ctx = c.LLVMContextCreate();
        errdefer c.LLVMContextDispose(ctx);
        const mod = try emitModule(testing.allocator, ctx, &m, "test");
        errdefer c.LLVMDisposeModule(mod);

        const s = c.LLVMPrintModuleToString(mod);
        defer c.LLVMDisposeMessage(s);
        const ir_text = try testing.allocator.dupe(u8, std.mem.span(s));
        errdefer testing.allocator.free(ir_text);

        var msg: ?[*:0]u8 = null;
        const bad = c.LLVMVerifyModule(mod, .return_status, &msg) != 0;
        defer if (msg) |p| c.LLVMDisposeMessage(p);
        if (bad) {
            std.debug.print("LLVM verifier: {s}\n{s}\n", .{ if (msg) |p| std.mem.span(p) else "", ir_text });
            return error.TestUnexpectedResult;
        }
        return .{ .ctx = ctx, .mod = mod, .ir_text = ir_text };
    }

    pub fn deinit(x: *Emitted) void {
        testing.allocator.free(x.ir_text);
        if (x.mod) |m| c.LLVMDisposeModule(m);
        c.LLVMContextDispose(x.ctx);
    }

    /// FileCheck-style: each `checks` line occurs, in order; no `nots`
    /// substring occurs anywhere.
    pub fn expect(x: Emitted, checks: []const []const u8, nots: []const []const u8) !void {
        var pos: usize = 0;
        for (checks) |want| {
            const at = std.mem.indexOfPos(u8, x.ir_text, pos, want) orelse {
                std.debug.print("CHECK not found after offset {d}: {s}\n{s}\n", .{ pos, want, x.ir_text });
                return error.TestUnexpectedResult;
            };
            pos = at + want.len;
        }
        for (nots) |bad| if (std.mem.indexOf(u8, x.ir_text, bad) != null) {
            std.debug.print("CHECK-NOT found: {s}\n{s}\n", .{ bad, x.ir_text });
            return error.TestUnexpectedResult;
        };
    }

    /// JIT-compiles the module (consuming it) and returns the address of
    /// function `name`, valid until `ee` is disposed.
    pub fn jit(x: *Emitted, name: [:0]const u8, ee: *c.ExecutionEngineRef) !usize {
        switch (@import("builtin").cpu.arch) {
            .x86_64 => {
                c.LLVMInitializeX86TargetInfo();
                c.LLVMInitializeX86Target();
                c.LLVMInitializeX86TargetMC();
                c.LLVMInitializeX86AsmPrinter();
            },
            .aarch64 => {
                c.LLVMInitializeAArch64TargetInfo();
                c.LLVMInitializeAArch64Target();
                c.LLVMInitializeAArch64TargetMC();
                c.LLVMInitializeAArch64AsmPrinter();
            },
            else => return error.SkipZigTest,
        }
        c.LLVMLinkInMCJIT();
        var err: ?[*:0]u8 = null;
        if (c.LLVMCreateExecutionEngineForModule(ee, x.mod.?, &err) != 0) {
            defer if (err) |p| c.LLVMDisposeMessage(p);
            std.debug.print("MCJIT: {s}\n", .{if (err) |p| std.mem.span(p) else ""});
            return error.TestUnexpectedResult;
        }
        x.mod = null; // owned by `ee` now
        const addr = c.LLVMGetFunctionAddress(ee.*, name.ptr);
        try testing.expect(addr != 0);
        return @intCast(addr);
    }
};

/// Runs `body` only in `-Dllvm=true` builds; the other branch is never
/// analysed, so the default build references no LLVM symbol.
pub fn llvmTest(comptime body: fn () anyerror!void) !void {
    if (build_options.llvm) return body() else return error.SkipZigTest;
}

const sum_src =
    \\fn @sum(%n: i64) -> i64 {
    \\^entry:
    \\  %zero: i64 = const 0
    \\  br ^loop(%zero, %zero)
    \\^loop(%i: i64, %acc: i64):
    \\  %done: i1 = icmp sge %i, %n
    \\  cond_br %done, ^exit(%acc), ^body
    \\^body:
    \\  %acc2: i64 = add nsw %acc, %i
    \\  %one: i64 = const 1
    \\  %i2: i64 = add nuw nsw %i, %one
    \\  br ^loop(%i2, %acc2)
    \\^exit(%r: i64):
    \\  ret %r
    \\}
;

test "block parameters become phis; loop runs under JIT" {
    try llvmTest(struct {
        fn run() !void {
            var x = try Emitted.init(sum_src);
            defer x.deinit();
            try x.expect(&.{
                "define i64 @sum(i64 %n)",
                "entry:",
                "br label %loop",
                "loop:",
                "%i = phi i64 [ 0, %entry ], [ %i2, %body ]",
                "%acc = phi i64 [ 0, %entry ], [ %acc2, %body ]",
                "%done = icmp sge i64 %i, %n",
                "br i1 %done, label %exit, label %body",
                "%acc2 = add nsw i64 %acc, %i",
                "%i2 = add nuw nsw i64 %i, 1",
                "%r = phi i64 [ %acc, %loop ]",
                "ret i64 %r",
            }, &.{});

            var ee: c.ExecutionEngineRef = undefined;
            const addr = try x.jit("sum", &ee);
            defer c.LLVMDisposeExecutionEngine(ee);
            const sum: *const fn (i64) callconv(.c) i64 = @ptrFromInt(addr);
            try testing.expectEqual(@as(i64, 45), sum(10));
            try testing.expectEqual(@as(i64, 0), sum(-3));
        }
    }.run);
}

test "parameter and function attributes" {
    try llvmTest(struct {
        fn run() !void {
            var x = try Emitted.init(
                \\fn @f(%p: ptr noalias align(8) dereferenceable(16), %q: ptr readonly, %n: i32) -> void inline cold {
                \\^entry:
                \\  ret
                \\}
                \\fn @g() -> void noinline noreturn {
                \\^entry:
                \\  unreachable
                \\}
                \\fn @ext(%x: f32) -> f64
            );
            defer x.deinit();
            try x.expect(&.{
                "define void @f(ptr noalias align 8 dereferenceable(16) %p, ptr readonly %q, i32 %n) #0",
                "ret void",
                "define void @g() #1",
                "unreachable",
                "declare double @ext(float)",
                "attributes #0 = { alwaysinline cold }",
                "attributes #1 = { noinline noreturn }",
            }, &.{});
        }
    }.run);
}

test "float ops carry fast-math flags only with fast" {
    try llvmTest(struct {
        fn run() !void {
            var x = try Emitted.init(
                \\fn @strict(%a: f64, %b: f64, %c: f64) -> f64 {
                \\^entry:
                \\  %m: f64 = fmul %a, %b
                \\  %s: f64 = fadd %m, %c
                \\  %d: f64 = fdiv %s, %a
                \\  %r: f64 = frem %d, %b
                \\  %n: f64 = fneg %r
                \\  %u: f64 = fsub %n, %c
                \\  ret %u
                \\}
                \\fn @fast(%a: f32, %b: f32) -> i1 {
                \\^entry:
                \\  %m: f32 = fmul fast %a, %b
                \\  %c: i1 = fcmp olt fast %m, %a
                \\  ret %c
                \\}
            );
            defer x.deinit();
            try x.expect(&.{
                "%m = fmul double %a, %b",
                "%s = fadd double %m, %c",
                "%d = fdiv double %s, %a",
                "%r = frem double %d, %b",
                "%n = fneg double %r",
                "%u = fsub double %n, %c",
                "%m = fmul fast float %a, %b",
                "%c = fcmp fast olt float %m, %a",
            }, &.{ "contract", "fmuladd", "llvm.fma" });
            // Only the two `fast` instructions carry flags.
            try testing.expectEqual(@as(usize, 2), std.mem.count(u8, x.ir_text, " fast "));
        }
    }.run);
}

test "integer ops, comparisons and conversions" {
    try llvmTest(struct {
        fn run() !void {
            var x = try Emitted.init(
                \\fn @ints(%a: i32, %b: i32, %p: ptr, %f: f32) -> i64 {
                \\^entry:
                \\  %1: i32 = sub nuw %a, %b
                \\  %2: i32 = mul nsw %1, %b
                \\  %3: i32 = udiv %2, %b
                \\  %4: i32 = sdiv %3, %b
                \\  %5: i32 = urem %4, %b
                \\  %6: i32 = srem %5, %b
                \\  %7: i32 = and %6, %a
                \\  %8: i32 = or %7, %a
                \\  %9: i32 = xor %8, %a
                \\  %10: i32 = shl nuw %9, %b
                \\  %11: i32 = lshr %10, %b
                \\  %12: i32 = ashr %11, %b
                \\  %13: i1 = icmp ult %12, %a
                \\  %14: i8 = trunc %12
                \\  %15: i64 = zext %14
                \\  %16: i64 = sext %12
                \\  %17: i64 = ptrtoint %p
                \\  %18: ptr = inttoptr %17
                \\  %19: f64 = fpext %f
                \\  %20: f32 = fptrunc %19
                \\  %21: f32 = uitofp %a
                \\  %22: f32 = sitofp %b
                \\  %23: i32 = bitcast %22
                \\  %24: i1 = fcmp uno %20, %21
                \\  %25: i64 = add %15, %16
                \\  ret %25
                \\}
            );
            defer x.deinit();
            try x.expect(&.{
                "sub nuw i32 %a, %b",
                "mul nsw i32",
                "udiv i32",
                "sdiv i32",
                "urem i32",
                "srem i32",
                "and i32",
                "or i32",
                "xor i32",
                "shl nuw i32",
                "lshr i32",
                "ashr i32",
                "icmp ult i32",
                "trunc i32",
                " to i8",
                "zext i8",
                "sext i32",
                "ptrtoint ptr %p to i64",
                "inttoptr i64",
                "fpext float %f to double",
                "fptrunc double",
                "uitofp i32 %a to float",
                "sitofp i32 %b to float",
                "bitcast float",
                "fcmp uno float",
            }, &.{});
        }
    }.run);
}

test "switch with repeated parameterised target runs under JIT" {
    try llvmTest(struct {
        fn run() !void {
            var x = try Emitted.init(
                \\fn @classify(%x: i32) -> i32 {
                \\^entry:
                \\  %ten: i32 = const 10
                \\  %twenty: i32 = const 20
                \\  switch %x, default ^other, [1: ^join(%ten), 2: ^join(%twenty), -1: ^join(%x)]
                \\^other:
                \\  %neg: i1 = icmp slt %x, %ten
                \\  cond_br %neg, ^join(%ten), ^join(%x)
                \\^join(%r: i32):
                \\  ret %r
                \\}
            );
            defer x.deinit();
            try x.expect(&.{
                "switch i32 %x, label %other [",
                "i32 1, label %join",
                "i32 2, label %edge",
                "i32 -1, label %edge",
            }, &.{});

            var ee: c.ExecutionEngineRef = undefined;
            const addr = try x.jit("classify", &ee);
            defer c.LLVMDisposeExecutionEngine(ee);
            const f: *const fn (i32) callconv(.c) i32 = @ptrFromInt(addr);
            try testing.expectEqual(@as(i32, 10), f(1));
            try testing.expectEqual(@as(i32, 20), f(2));
            try testing.expectEqual(@as(i32, -1), f(-1));
            try testing.expectEqual(@as(i32, 10), f(5));
            try testing.expectEqual(@as(i32, 42), f(42));
        }
    }.run);
}

test "function symbols are values" {
    try llvmTest(struct {
        fn run() !void {
            var x = try Emitted.init(
                \\fn @g() -> void {
                \\^entry:
                \\  ret
                \\}
                \\fn @f(%p: ptr) -> i64 {
                \\^entry:
                \\  %a: i64 = ptrtoint @g
                \\  %e: i1 = icmp eq %p, @f
                \\  cond_br %e, ^b(@f), ^b(%p)
                \\^b(%q: ptr):
                \\  %r: i64 = ptrtoint %q
                \\  %s: i64 = add %a, %r
                \\  ret %s
                \\}
                \\fn @h() -> ptr {
                \\^entry:
                \\  ret @h
                \\}
            );
            defer x.deinit();
            try x.expect(&.{
                "%e = icmp eq ptr %p, @f",
                "%q = phi ptr [ @f, %entry ], [ %p, %edge ]",
                "%s = add i64 ptrtoint (ptr @g to i64), %r",
                "ret ptr @h",
            }, &.{});
        }
    }.run);
}

test "unsupported opcodes are reported" {
    try llvmTest(struct {
        fn run() !void {
            const cases = [_][]const u8{
                \\fn @f(%p: ptr, %h: i64) -> i32 {
                \\^entry:
                \\  %i: i32, %ok: i1 = handle.lookup %p, %h
                \\  ret %i
                \\}
                ,
                \\fn @f() -> void {
                \\^entry:
                \\  pfor.end
                \\  ret
                \\}
            };
            for (cases) |src| {
                var m = try parseText(src);
                defer m.deinit();
                const ctx = c.LLVMContextCreate();
                defer c.LLVMContextDispose(ctx);
                try testing.expectError(error.Unsupported, emitModule(testing.allocator, ctx, &m, "t"));
            }
        }
    }.run);
}
