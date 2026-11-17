//! P-IR data structures (spec B.5): a typed SSA IR with block parameters.
//!
//! Ownership: a `Module` owns one arena; every function, block, instruction,
//! name and slice reachable from it lives in that arena and is freed by
//! `Module.deinit`. Functions are heap-allocated, so `*Function` stays valid
//! while more functions are added.
//!
//! Instructions use one uniform record (`Inst`). The meaning of `operands` per
//! opcode is documented on `Op`; `text.zig` gives the exact syntax.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Scalar element kinds (B.5.1). `void` is only a return type.
pub const Scalar = enum(u8) {
    i1,
    i8,
    i16,
    i32,
    i64,
    f32,
    f64,
    ptr,
    void,

    pub fn isInt(s: Scalar) bool {
        return switch (s) {
            .i1, .i8, .i16, .i32, .i64 => true,
            else => false,
        };
    }

    pub fn isFloat(s: Scalar) bool {
        return s == .f32 or s == .f64;
    }
};

/// A P-IR type: a scalar, or `vec<lanes x scalar>` when `lanes > 0`.
pub const Type = struct {
    scalar: Scalar,
    /// Lane count of a vector type; 0 for a scalar type.
    lanes: u32 = 0,

    pub const @"void": Type = .{ .scalar = .void };

    pub fn of(s: Scalar) Type {
        return .{ .scalar = s };
    }

    pub fn vec(lanes: u32, elem: Scalar) Type {
        std.debug.assert(lanes > 0);
        return .{ .scalar = elem, .lanes = lanes };
    }

    pub fn isVector(t: Type) bool {
        return t.lanes != 0;
    }

    pub fn eql(a: Type, b: Type) bool {
        return a.scalar == b.scalar and a.lanes == b.lanes;
    }

    /// Prints the type in text syntax (`{f}`).
    pub fn format(t: Type, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (t.lanes == 0) return w.writeAll(@tagName(t.scalar));
        try w.print("vec<{d} x {s}>", .{ t.lanes, @tagName(t.scalar) });
    }
};

/// An SSA value: index into `Function.values`.
pub const Value = enum(u32) {
    _,

    pub fn index(v: Value) u32 {
        return @backingInt(v);
    }
};

/// A block: index into `Function.blocks`.
pub const BlockId = enum(u32) {
    _,

    pub fn index(b: BlockId) u32 {
        return @backingInt(b);
    }
};

/// Per-value data. Values are function arguments, block parameters or
/// instruction results.
pub const ValueInfo = struct {
    ty: Type,
    /// Text name without `%`; empty means "print by index".
    name: []const u8 = "",
};

/// Memory orders (MemOrder, §14). `none` means "not atomic".
pub const Order = enum(u8) { none, relaxed, acquire, release, acq_rel, seq_cst };

/// Comparison predicates of `icmp` (integer) and `fcmp` (float).
pub const Pred = enum(u8) {
    none,
    eq,
    ne,
    ult,
    ule,
    ugt,
    uge,
    slt,
    sle,
    sgt,
    sge,
    oeq,
    one,
    olt,
    ole,
    ogt,
    oge,
    uno,
    ord,

    pub fn isInt(p: Pred) bool {
        return @backingInt(p) >= @backingInt(Pred.eq) and @backingInt(p) <= @backingInt(Pred.sge);
    }

    pub fn isFloat(p: Pred) bool {
        return @backingInt(p) >= @backingInt(Pred.oeq);
    }
};

/// The operation of `atomic.rmw`.
pub const RmwOp = enum(u8) { none, xchg, add, sub, @"and", @"or", xor, nand, min, max, umin, umax };

/// Instruction flags; which ones are meaningful depends on the opcode.
pub const Flags = packed struct(u8) {
    /// No unsigned wrap (integer ops, only when proven).
    nuw: bool = false,
    /// No signed wrap (integer ops, only when proven).
    nsw: bool = false,
    /// Fast-math (float ops, only under `@fast_math`).
    fast: bool = false,
    /// Volatile access (`load`/`store`).
    @"volatile": bool = false,
    /// Sign-extend the extracted field (`bf.extract`).
    signed: bool = false,
    _pad: u3 = 0,
};

/// Opcodes: every B.5.2 opcode plus `const`. The tag name is the text
/// mnemonic. Operand layout (`Inst.operands`) per opcode:
///
/// - Integer, checked, float binary ops: `a, b`. `fneg`: `a`. `fma`: `a, b, c`.
/// - `icmp`/`fcmp` (`Inst.pred`): `a, b`. Conversions: `a` (target = result type).
/// - `alloca`: `type T` (align in `Inst.align`). `load`: `ptr`. `store`: `v, ptr`.
///   `gep`: `ptr, idx, stride(int)`. `memcpy`: `dst, src, len`. `memset`: `dst, byte, len`.
/// - `soa.col`: `base, field(int)`. `soa.load`: `base, i, field(int)`.
///   `soa.store`: `base, i, field(int), v`.
/// - `bf.extract`: `unit, offset(int), width(int)` (`Flags.signed`).
///   `bf.insert`: `unit, v, offset(int), width(int)`.
/// - `splat`: `x`. `extract`: `vec, lane(int)`. `insert`: `vec, x, lane(int)`.
///   `shuffle`: `a, b, mask lanes(int)...`. `select`: `cond, a, b`. `reduce.*`: `vec`.
///   `load.masked`: `ptr, mask, passthru`. `store.masked`: `v, ptr, mask`.
/// - `bounds`: `i, len`. `trap`: `kind(int), msg_id(int)`.
/// - `handle.lookup`: `pool_slots, h`; two results `(dense_index, ok: i1)`.
/// - `call`/`call.tail`/`spawn`: `@f, args...`. `call.indirect`: `%p, args...`.
/// - `nursery.begin`, `nursery.end`, `pfor.end`: any values (runtime-defined).
///   `pfor.begin`: `range values..., chunk`.
/// - `atomic.rmw` (`Inst.rmw`): `ptr, v, order`. `cmpxchg`: `ptr, expected, new,
///   success order, failure order` (results: old value, optionally `ok: i1`).
///   `fence`: `order`.
/// - `const`: one `int` or `float` literal of the result type (B.5.2 lists no
///   constant opcode; this is the only way to make an immediate SSA value).
/// - Terminators: `br` (`targets[0]`), `cond_br`: `cond` (`targets[0..2]`),
///   `switch`: `v` (`targets[0]` = default, the rest carry `key`),
///   `ret`: optional `v`, `unreachable`: none.
pub const Op = enum(u8) {
    // Integer
    add,
    sub,
    mul,
    udiv,
    sdiv,
    urem,
    srem,
    @"and",
    @"or",
    xor,
    shl,
    lshr,
    ashr,
    // Checked
    @"add.trap",
    @"sub.trap",
    @"mul.trap",
    // Float
    fadd,
    fsub,
    fmul,
    fdiv,
    frem,
    fneg,
    fma,
    // Compare
    icmp,
    fcmp,
    // Convert
    trunc,
    zext,
    sext,
    fptrunc,
    fpext,
    @"fptoui.sat",
    @"fptosi.sat",
    uitofp,
    sitofp,
    bitcast,
    ptrtoint,
    inttoptr,
    // Memory
    alloca,
    load,
    store,
    gep,
    memcpy,
    memset,
    // SoA
    @"soa.col",
    @"soa.load",
    @"soa.store",
    // Bit fields
    @"bf.extract",
    @"bf.insert",
    // Vector
    splat,
    extract,
    insert,
    shuffle,
    select,
    @"reduce.add",
    @"reduce.mul",
    @"reduce.min",
    @"reduce.max",
    @"reduce.and",
    @"reduce.or",
    @"load.masked",
    @"store.masked",
    // Checks
    bounds,
    trap,
    // Handles
    @"handle.lookup",
    // Calls
    call,
    @"call.indirect",
    @"call.tail",
    // Concurrency
    @"nursery.begin",
    spawn,
    @"nursery.end",
    @"pfor.begin",
    @"pfor.end",
    // Atomics
    @"atomic.rmw",
    cmpxchg,
    fence,
    // Constants
    @"const",
    // Terminators
    br,
    cond_br,
    @"switch",
    ret,
    @"unreachable",

    pub fn isTerminator(op: Op) bool {
        return @backingInt(op) >= @backingInt(Op.br);
    }

    /// Ops written `op callee(args...)`; `operands[0]` is the callee.
    pub fn isCall(op: Op) bool {
        return switch (op) {
            .call, .@"call.indirect", .@"call.tail", .spawn => true,
            else => false,
        };
    }
};

/// An instruction operand.
pub const Operand = union(enum) {
    value: Value,
    /// `@name`: a global's or function's address (resolve via `Module.find*`).
    symbol: []const u8,
    /// Integer literal: a constant or an immediate field (index, stride, ...).
    int: i64,
    float: f64,
    /// A type operand (`alloca T`).
    type: Type,
    order: Order,
};

/// A branch target with its block arguments. `key` is the case value for
/// `switch` cases (unused otherwise).
pub const Target = struct {
    block: BlockId,
    args: []const Operand = &.{},
    key: i64 = 0,
};

pub const Inst = struct {
    op: Op,
    /// Defined values. Usually zero or one; `handle.lookup` and `cmpxchg`
    /// may define two.
    results: []const Value = &.{},
    flags: Flags = .{},
    /// `icmp`/`fcmp` predicate.
    pred: Pred = .none,
    /// `atomic.rmw` operation.
    rmw: RmwOp = .none,
    /// `load`/`store` `atomic(order)` flag; `.none` means non-atomic.
    atomic: Order = .none,
    /// Alignment in bytes for memory ops; 0 means the type's natural alignment.
    @"align": u32 = 0,
    operands: []const Operand = &.{},
    /// Terminator successors.
    targets: []const Target = &.{},

    /// The single result. Asserts the instruction has exactly one.
    pub fn result(i: Inst) Value {
        std.debug.assert(i.results.len == 1);
        return i.results[0];
    }
};

pub const Block = struct {
    /// Label without `^`.
    name: []const u8,
    params: std.ArrayList(Value) = .empty,
    /// Instructions; a finished block ends with exactly one terminator.
    insts: std.ArrayList(Inst) = .empty,

    pub fn terminator(b: Block) ?Inst {
        if (b.insts.items.len == 0) return null;
        const last = b.insts.items[b.insts.items.len - 1];
        return if (last.op.isTerminator()) last else null;
    }
};

/// Parameter attributes (B.5.1).
pub const ParamAttrs = struct {
    @"noalias": bool = false,
    readonly: bool = false,
    /// `align(N)`; 0 if absent.
    @"align": u32 = 0,
    /// `dereferenceable(N)`; 0 if absent.
    dereferenceable: u64 = 0,
};

pub const Param = struct {
    value: Value,
    attrs: ParamAttrs = .{},
};

/// Function attributes. B.5.1 leaves the set open; these are the ones the
/// pipeline needs (inlining of `@inline` functions, B.5.3).
pub const FnAttrs = packed struct(u8) {
    @"inline": bool = false,
    @"noinline": bool = false,
    cold: bool = false,
    noreturn: bool = false,
    _pad: u4 = 0,
};

pub const Function = struct {
    arena: Allocator,
    /// Symbol name without `@`.
    name: []const u8,
    params: std.ArrayList(Param) = .empty,
    ret: Type,
    attrs: FnAttrs = .{},
    /// Entry block first. Empty for a declaration (no body).
    blocks: std.ArrayList(Block) = .empty,
    values: std.ArrayList(ValueInfo) = .empty,

    /// Creates a value not yet attached to a definition.
    pub fn newValue(f: *Function, ty: Type, name: []const u8) Allocator.Error!Value {
        const v: Value = @fromBackingInt(@intCast(f.values.items.len));
        try f.values.append(f.arena, .{ .ty = ty, .name = try f.arena.dupe(u8, name) });
        return v;
    }

    pub fn typeOf(f: *const Function, v: Value) Type {
        return f.values.items[v.index()].ty;
    }

    pub fn addParam(f: *Function, ty: Type, name: []const u8, attrs: ParamAttrs) Allocator.Error!Value {
        const v = try f.newValue(ty, name);
        try f.params.append(f.arena, .{ .value = v, .attrs = attrs });
        return v;
    }

    pub fn addBlock(f: *Function, name: []const u8) Allocator.Error!BlockId {
        const id: BlockId = @fromBackingInt(@intCast(f.blocks.items.len));
        try f.blocks.append(f.arena, .{ .name = try f.arena.dupe(u8, name) });
        return id;
    }

    pub fn block(f: *Function, id: BlockId) *Block {
        return &f.blocks.items[id.index()];
    }

    pub fn addBlockParam(f: *Function, b: BlockId, ty: Type, name: []const u8) Allocator.Error!Value {
        const v = try f.newValue(ty, name);
        try f.block(b).params.append(f.arena, v);
        return v;
    }

    /// Appends `inst` to block `b`, copying its slices (and symbol names)
    /// into the arena.
    pub fn append(f: *Function, b: BlockId, inst: Inst) Allocator.Error!void {
        var copy = inst;
        copy.results = try f.arena.dupe(Value, inst.results);
        copy.operands = try f.dupeOperands(inst.operands);
        const targets = try f.arena.alloc(Target, inst.targets.len);
        for (targets, inst.targets) |*d, s| d.* = .{ .block = s.block, .key = s.key, .args = try f.dupeOperands(s.args) };
        copy.targets = targets;
        try f.block(b).insts.append(f.arena, copy);
    }

    fn dupeOperands(f: *Function, ops: []const Operand) Allocator.Error![]const Operand {
        const out = try f.arena.dupe(Operand, ops);
        for (out) |*o| if (o.* == .symbol) {
            o.* = .{ .symbol = try f.arena.dupe(u8, o.symbol) };
        };
        return out;
    }

    pub fn isDeclaration(f: *const Function) bool {
        return f.blocks.items.len == 0;
    }
};

/// Initial value of a global.
pub const Init = union(enum) {
    int: i64,
    float: f64,
    /// `zeroinit`: all bytes zero.
    zero,
    /// A byte string literal.
    bytes: []const u8,
};

pub const Global = struct {
    /// Symbol name without `@`.
    name: []const u8,
    ty: Type,
    init: Init,
    /// `align N`; 0 if absent.
    @"align": u32 = 0,
    readonly: bool = false,
};

pub const Module = struct {
    gpa: Allocator,
    arena_state: *std.heap.ArenaAllocator,
    globals: std.ArrayList(Global) = .empty,
    functions: std.ArrayList(*Function) = .empty,

    pub fn init(gpa: Allocator) Allocator.Error!Module {
        const state = try gpa.create(std.heap.ArenaAllocator);
        state.* = .init(gpa);
        return .{ .gpa = gpa, .arena_state = state };
    }

    pub fn deinit(m: *Module) void {
        m.arena_state.deinit();
        m.gpa.destroy(m.arena_state);
        m.* = undefined;
    }

    /// The module's arena; everything it allocates lives until `deinit`.
    pub fn arena(m: *const Module) Allocator {
        return m.arena_state.allocator();
    }

    pub fn addGlobal(m: *Module, g: Global) Allocator.Error!void {
        var copy = g;
        copy.name = try m.arena().dupe(u8, g.name);
        if (g.init == .bytes) copy.init = .{ .bytes = try m.arena().dupe(u8, g.init.bytes) };
        try m.globals.append(m.arena(), copy);
    }

    pub fn addFunction(m: *Module, name: []const u8, ret: Type) Allocator.Error!*Function {
        const a = m.arena();
        const f = try a.create(Function);
        f.* = .{ .arena = a, .name = try a.dupe(u8, name), .ret = ret };
        try m.functions.append(a, f);
        return f;
    }

    pub fn findFunction(m: *const Module, name: []const u8) ?*Function {
        for (m.functions.items) |f| if (std.mem.eql(u8, f.name, name)) return f;
        return null;
    }

    pub fn findGlobal(m: *const Module, name: []const u8) ?*Global {
        for (m.globals.items) |*g| if (std.mem.eql(u8, g.name, name)) return g;
        return null;
    }
};

test "type formatting and predicates" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("vec<4 x f32>", try std.fmt.bufPrint(&buf, "{f}", .{Type.vec(4, .f32)}));
    try std.testing.expectEqualStrings("i1", try std.fmt.bufPrint(&buf, "{f}", .{Type.of(.i1)}));
    try std.testing.expect(Pred.slt.isInt() and !Pred.slt.isFloat());
    try std.testing.expect(Pred.ord.isFloat() and !Pred.none.isInt());
    try std.testing.expect(Op.ret.isTerminator() and !Op.@"const".isTerminator());
}

test "module building keeps function pointers stable" {
    var m = try Module.init(std.testing.allocator);
    defer m.deinit();
    const f = try m.addFunction("f", .void);
    for (0..32) |i| _ = try m.addFunction(if (i % 2 == 0) "g" else "h", .void);
    try std.testing.expectEqual(f, m.findFunction("f").?);
    try std.testing.expect(f.isDeclaration());
}
