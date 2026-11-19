//! Builds one TIR `Func` (B.1 stage 4). Checking (T043) drives it: it adds
//! locals and blocks, appends instructions at the end of a current block, and
//! calls `finish` to pack the result into flat arrays.
//!
//! All memory comes from one arena, normally the checking thread's arena
//! from `Arena.PerThread` (B.1: one arena per stage and thread). Growth
//! garbage stays in the arena until it is reset; nothing is freed one by one.

const std = @import("std");
const Allocator = std.mem.Allocator;
const tir = @import("tir.zig");

const Ref = tir.Ref;
const Block = tir.Block;
const Local = tir.Local;
const TypeId = tir.TypeId;

pub const Builder = struct {
    arena: Allocator,
    ret: TypeId,
    insts: std.MultiArrayList(tir.Inst) = .empty,
    extra: std.ArrayList(u32) = .empty,
    /// Instructions of each block, in order.
    blocks: std.ArrayList(std.ArrayList(Ref)) = .empty,
    locals: std.MultiArrayList(tir.LocalInfo) = .empty,
    param_count: u32 = 0,
    /// Insertion block; `add` appends at its end.
    block: Block = .none,
    /// Source node recorded on instructions added from now on.
    node: tir.NodeIndex = .none,

    /// A builder for a function returning `ret`; allocates from `arena`.
    pub fn init(arena: Allocator, ret: TypeId) Builder {
        return .{ .arena = arena, .ret = ret };
    }

    /// Adds parameter `name: ty`. Asserts all parameters come before other locals.
    pub fn addParam(b: *Builder, name: tir.StrId, ty: TypeId, kind: tir.LocalKind) Allocator.Error!Local {
        std.debug.assert(kind.isParam() and b.locals.len == b.param_count);
        b.param_count += 1;
        return b.addLocal(.{ .ty = ty, .name = name, .kind = kind, .node = b.node });
    }

    /// Adds a local slot (use `addParam` for parameters).
    pub fn addLocal(b: *Builder, info: tir.LocalInfo) Allocator.Error!Local {
        try b.locals.append(b.arena, info);
        return .from(b.locals.len - 1);
    }

    /// Adds an empty block. The first block added is the entry block.
    pub fn addBlock(b: *Builder) Allocator.Error!Block {
        try b.blocks.append(b.arena, .empty);
        return .from(b.blocks.items.len - 1);
    }

    /// Moves the insertion point to the end of `blk`.
    pub fn setBlock(b: *Builder, blk: Block) void {
        b.block = blk;
    }

    /// Adds a parameter of type `ty` to `blk`. Asserts `blk` holds only
    /// parameters so far.
    pub fn addBlockParam(b: *Builder, blk: Block, ty: TypeId) Allocator.Error!Ref {
        const list = &b.blocks.items[blk.int()];
        for (list.items) |r| std.debug.assert(b.insts.items(.op)[r.int()] == .block_param);
        return b.append(blk, ty, .{ .block_param = .{} });
    }

    /// Appends an instruction yielding a value of type `ty` (`.void` for
    /// none) to the insertion block. Asserts the block is not terminated.
    pub fn add(b: *Builder, ty: TypeId, d: tir.Data) Allocator.Error!Ref {
        std.debug.assert(!b.isTerminated(b.block));
        return b.append(b.block, ty, d);
    }

    fn append(b: *Builder, blk: Block, ty: TypeId, d: tir.Data) Allocator.Error!Ref {
        // Untyped constants are folded by checking (see `tir.Data.int`).
        std.debug.assert(!((d == .int or d == .float) and (ty == .untyped_int or ty == .untyped_float)));
        const s = try tir.encode(b.arena, &b.extra, d);
        try b.insts.append(b.arena, .{ .op = std.meta.activeTag(d), .ty = ty, .node = b.node, .a = s.a, .b = s.b });
        const r: Ref = .from(b.insts.len - 1);
        try b.blocks.items[blk.int()].append(b.arena, r);
        return r;
    }

    /// Whether `blk` already ends in a terminator.
    pub fn isTerminated(b: *const Builder, blk: Block) bool {
        const items = b.blocks.items[blk.int()].items;
        return items.len > 0 and b.insts.items(.op)[items[items.len - 1].int()].isTerminator();
    }

    pub fn typeOf(b: *const Builder, r: Ref) TypeId {
        return b.insts.items(.ty)[r.int()];
    }

    /// Typed payload of `r`; lists are valid until the next `add`.
    pub fn data(b: *const Builder, r: Ref) tir.Data {
        const i = r.int();
        return tir.decode(b.insts.items(.op)[i], b.insts.items(.a)[i], b.insts.items(.b)[i], b.extra.items);
    }

    /// Packs the body into a `Func` in the builder's arena. Asserts every
    /// block is terminated. The builder must not be used afterwards.
    pub fn finish(b: *Builder) Allocator.Error!tir.Func {
        var total: usize = 0;
        for (b.blocks.items, 0..) |l, i| {
            std.debug.assert(b.isTerminated(.from(i)));
            total += l.items.len;
        }
        const infos = try b.arena.alloc(tir.BlockInfo, b.blocks.items.len);
        const order = try b.arena.alloc(Ref, total);
        var at: u32 = 0;
        for (b.blocks.items, infos) |l, *info| {
            info.* = .{ .start = at, .len = @intCast(l.items.len) };
            @memcpy(order[at..][0..l.items.len], l.items);
            at += info.len;
        }
        return .{
            .ret = b.ret,
            .param_count = b.param_count,
            .insts = b.insts.toOwnedSlice(),
            .extra = b.extra.items,
            .blocks = infos,
            .order = order,
            .locals = b.locals.toOwnedSlice(),
        };
    }
};

const testing = std.testing;

test "builder appends per block and finish packs blocks in order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var b: Builder = .init(arena.allocator(), .bool);
    const x = try b.addParam(.none, .bool, .param);
    const entry = try b.addBlock();
    const join = try b.addBlock();
    const p = try b.addBlockParam(join, .bool);

    b.setBlock(entry);
    const place = try b.add(.bool, .{ .local = .{ .local = x } });
    const v = try b.add(.bool, .{ .load = .{ .place = place } });
    try testing.expect(!b.isTerminated(entry));
    _ = try b.add(.void, .{ .br = .{ .target = join, .args = &.{v} } });
    try testing.expect(b.isTerminated(entry));
    b.setBlock(join);
    _ = try b.add(.void, .{ .ret = .{ .value = p } });

    const f = try b.finish();
    try testing.expectEqual(1, f.param_count);
    try testing.expectEqualSlices(Ref, &.{ place, v, .from(3) }, f.blockInsts(entry));
    try testing.expectEqualSlices(Ref, &.{ p, .from(4) }, f.blockInsts(join));
    try testing.expectEqual(tir.Op.br, f.op(f.terminator(entry)));
    try testing.expectEqualSlices(Ref, &.{v}, f.data(f.terminator(entry)).br.args);
    try testing.expectEqual(TypeId.bool, f.typeOf(v));
    try testing.expectEqual(tir.LocalKind.param, f.local(x).kind);
}
