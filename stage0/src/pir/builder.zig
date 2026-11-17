//! Instruction builder for P-IR: appends instructions at the end of a current
//! block and creates their result values. Lowering (B.5.3 step 1) uses this.

const std = @import("std");
const ir = @import("ir.zig");

const Allocator = std.mem.Allocator;
const Type = ir.Type;
const Value = ir.Value;
const BlockId = ir.BlockId;
const Operand = ir.Operand;
const Target = ir.Target;
const Op = ir.Op;

pub const Builder = struct {
    func: *ir.Function,
    /// Insertion block; instructions are appended at its end.
    block: BlockId,

    pub fn init(func: *ir.Function, block: BlockId) Builder {
        return .{ .func = func, .block = block };
    }

    /// Moves the insertion point to the end of `b`.
    pub fn setBlock(self: *Builder, b: BlockId) void {
        self.block = b;
    }

    /// Appends `inst` after creating one unnamed result per entry of
    /// `result_types` (its `results` field is overwritten). Returns the results.
    pub fn emitMulti(self: *Builder, result_types: []const Type, inst: ir.Inst) Allocator.Error![]const Value {
        const results = try self.func.arena.alloc(Value, result_types.len);
        for (results, result_types) |*r, t| r.* = try self.func.newValue(t, "");
        var copy = inst;
        copy.results = results;
        try self.func.append(self.block, copy);
        return results;
    }

    /// Appends `inst` with one result of type `ty`.
    pub fn emit(self: *Builder, ty: Type, inst: ir.Inst) Allocator.Error!Value {
        return (try self.emitMulti(&.{ty}, inst))[0];
    }

    /// Appends `inst` without results.
    pub fn emitVoid(self: *Builder, inst: ir.Inst) Allocator.Error!void {
        _ = try self.emitMulti(&.{}, inst);
    }

    pub fn constInt(self: *Builder, ty: Type, v: i64) Allocator.Error!Value {
        return self.emit(ty, .{ .op = .@"const", .operands = &.{.{ .int = v }} });
    }

    pub fn constFloat(self: *Builder, ty: Type, v: f64) Allocator.Error!Value {
        return self.emit(ty, .{ .op = .@"const", .operands = &.{.{ .float = v }} });
    }

    /// Two-operand arithmetic; the result has the type of `a`.
    pub fn binary(self: *Builder, op: Op, flags: ir.Flags, a: Value, b: Value) Allocator.Error!Value {
        return self.emit(self.func.typeOf(a), .{ .op = op, .flags = flags, .operands = &.{ .{ .value = a }, .{ .value = b } } });
    }

    /// `icmp`/`fcmp`, chosen by the predicate; result `i1` (or a vector of `i1`).
    pub fn cmp(self: *Builder, pred: ir.Pred, a: Value, b: Value) Allocator.Error!Value {
        const at = self.func.typeOf(a);
        return self.emit(.{ .scalar = .i1, .lanes = at.lanes }, .{
            .op = if (pred.isFloat()) .fcmp else .icmp,
            .pred = pred,
            .operands = &.{ .{ .value = a }, .{ .value = b } },
        });
    }

    /// A conversion op to type `to`.
    pub fn convert(self: *Builder, op: Op, to: Type, a: Value) Allocator.Error!Value {
        return self.emit(to, .{ .op = op, .operands = &.{.{ .value = a }} });
    }

    pub fn alloca(self: *Builder, ty: Type, alignment: u32) Allocator.Error!Value {
        return self.emit(.of(.ptr), .{ .op = .alloca, .@"align" = alignment, .operands = &.{.{ .type = ty }} });
    }

    pub fn load(self: *Builder, ty: Type, ptr: Value, alignment: u32) Allocator.Error!Value {
        return self.emit(ty, .{ .op = .load, .@"align" = alignment, .operands = &.{.{ .value = ptr }} });
    }

    pub fn store(self: *Builder, v: Value, ptr: Value, alignment: u32) Allocator.Error!void {
        return self.emitVoid(.{ .op = .store, .@"align" = alignment, .operands = &.{ .{ .value = v }, .{ .value = ptr } } });
    }

    /// `call @name(args)`; `ret_ty` is the callee's return type (no result if void).
    pub fn call(self: *Builder, name: []const u8, ret_ty: Type, args: []const Value) Allocator.Error!?Value {
        const ops = try self.func.arena.alloc(Operand, args.len + 1); // copied again by append; cheap
        ops[0] = .{ .symbol = name };
        for (ops[1..], args) |*o, a| o.* = .{ .value = a };
        const inst: ir.Inst = .{ .op = .call, .operands = ops };
        if (ret_ty.scalar == .void) {
            try self.emitVoid(inst);
            return null;
        }
        return try self.emit(ret_ty, inst);
    }

    pub fn br(self: *Builder, dest: BlockId, args: []const Operand) Allocator.Error!void {
        return self.emitVoid(.{ .op = .br, .targets = &.{.{ .block = dest, .args = args }} });
    }

    pub fn condBr(self: *Builder, c: Value, t: Target, f: Target) Allocator.Error!void {
        return self.emitVoid(.{ .op = .cond_br, .operands = &.{.{ .value = c }}, .targets = &.{ t, f } });
    }

    pub fn ret(self: *Builder, v: ?Value) Allocator.Error!void {
        if (v) |x| return self.emitVoid(.{ .op = .ret, .operands = &.{.{ .value = x }} });
        return self.emitVoid(.{ .op = .ret });
    }
};

test "builder emits typed results and terminators" {
    var m = try ir.Module.init(std.testing.allocator);
    defer m.deinit();
    const f = try m.addFunction("sum", .of(.i64));
    const n = try f.addParam(.of(.i64), "n", .{});
    const entry = try f.addBlock("entry");
    const loop = try f.addBlock("loop");
    const i = try f.addBlockParam(loop, .of(.i64), "i");

    var b: Builder = .init(f, entry);
    const zero = try b.constInt(.of(.i64), 0);
    try b.br(loop, &.{.{ .value = zero }});
    b.setBlock(loop);
    const one = try b.constInt(.of(.i64), 1);
    const next = try b.binary(.add, .{ .nsw = true }, i, one);
    const done = try b.cmp(.sge, next, n);
    try b.condBr(done, .{ .block = entry }, .{ .block = loop, .args = &.{.{ .value = next }} });

    try std.testing.expect(f.typeOf(done).eql(.of(.i1)));
    try std.testing.expect(f.typeOf(next).eql(.of(.i64)));
    try std.testing.expectEqual(ir.Op.icmp, f.block(loop).insts.items[2].op);
    try std.testing.expectEqual(ir.Op.cond_br, f.block(loop).terminator().?.op);
    try std.testing.expectEqual(loop, f.block(loop).terminator().?.targets[1].block);
}
