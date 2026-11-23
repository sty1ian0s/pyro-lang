//! TIR: the typed IR produced by checking (B.1 stage 4) and consumed by the
//! comptime interpreter (§8.1, B.4), the view/resource dataflow checks
//! (§5, B.4) and lowering to P-IR (B.5.3 step 1).
//!
//! Shape:
//!
//! - One `Func` per checked function body (or comptime evaluation). It is a
//!   set of flat arrays: an SoA instruction table, an `extra` array of `u32`,
//!   a block table and a local table. Everything refers to everything else by
//!   `u32` index, never by pointer, so a `Func` can be cached and mapped back.
//! - Every instruction yields a value `Ref` (its index) tagged with a
//!   `TypeId` (`.void` when it yields nothing usable). Block parameters are
//!   `block_param` instructions at the head of their block, so all values are
//!   instruction refs.
//! - The body is a CFG of blocks. A finished block ends in exactly one
//!   terminator (`Op.isTerminator`); branches pass block arguments.
//! - Storage is explicit: locals (parameters first) are slots, and *place*
//!   instructions (`Op.isPlace`) name storage without reading it: `local`,
//!   `global`, `deref`, `field`, `index`, `variant_field`. Places are read
//!   with `load` (copy), `move` (§5.3.2), `view`/`view_mut` (§5.4) or
//!   `addr_of` (§12.2), and written with `store`. Dataflow (§5) sees every
//!   access as an instruction on a place chain. A place's type is the type
//!   of the storage it names. A `mut` parameter's place is the caller's place
//!   (the view is implicit in `LocalKind.param_mut`); a local declared
//!   `mut T` (§5.5.3) holds a view value and is reached through `deref`.
//! - `defer`/`errdefer` (§6.8) are not expanded here. Checking emits scope
//!   markers instead: `scope_begin` opens a scope, `defer`/`errdefer`
//!   register a body region (blocks ending in `defer_end`) in it, and
//!   `scope_end` is emitted on *every* route out of the scope (end of block,
//!   and before each `return`, `break`, `continue` and `?` that leaves it,
//!   innermost first). Defer expansion (`sema/defer.zig`) clones the bodies at
//!   each `scope_end` in LIFO order.
//! - A `nursery` body is a scope too. On every route out of it, its
//!   `nursery_end` (the join) comes *before* the `scope_end` of the body's
//!   scope, so spawned tasks finish before the body's defers run (§10.2
//!   item 3).
//! - Untyped constants (§4.8) never appear as `int`/`float`: they have
//!   arbitrary precision (integers) or are exact rationals (floats), which
//!   64 bits cannot hold. Checking (T043) folds them where they meet a typed
//!   context (deciding E0306 on the exact value) and emits a typed `int` or
//!   `float`; a constant that stays untyped (a `const` initializer, §7) is a
//!   `comptime` value.
//!
//! The payload of each opcode is declared once, as the matching field of
//! `Data`, and encoded generically like the AST (B.3):
//!
//! - each payload field is one `u32` slot (a `u64` takes two, low first),
//!   lists are an `extra` index of `[count, item...]`;
//! - a payload of at most two slots is stored in `a` and `b`; a longer one
//!   keeps slot 0 in `a`, and `b` is the `extra` index of slots 1...
//!
//! The opcode set is frozen (owner: T035). Operations that are library or
//! builtin semantics (wrapping/saturating/checked arithmetic, atomics,
//! reductions, select, `@bit_cast`, `@trap`, asserts, print/format, GPU
//! builtins, ...) are `builtin` instructions keyed by the builtin registry.

const std = @import("std");
const Allocator = std.mem.Allocator;
const base_index = @import("../base/index.zig");
const Interner = @import("../base/Interner.zig");
const types = @import("../sema/types.zig");

pub const TypeId = types.TypeId;
/// An instruction, and the value it yields.
pub const Ref = base_index.Index(.tir_inst);
/// A basic block of the function.
pub const Block = base_index.Index(.tir_block);
/// A local slot of the function; parameters are the first `Func.param_count`.
pub const Local = base_index.Index(.tir_local);
/// A function of the program (assigned by sema; one per instantiation).
pub const FnId = base_index.Index(.tir_fn);
/// A module-level `static`/global (§5.9).
pub const GlobalId = base_index.Index(.tir_global);
/// An entry of the builtin registry (§8.7, T048).
pub const BuiltinId = base_index.Index(.tir_builtin);
/// A value in the comptime value table (§8.1, T057).
pub const ComptimeId = base_index.Index(.comptime_value);
/// An interned string (string literals, local names).
pub const StrId = Interner.Id;
/// An AST node, for diagnostics.
pub const NodeIndex = base_index.Index(.node);

/// The device of a `launch` (§11.2.3).
pub const LaunchTarget = enum(u32) { cpu, gpu };

/// One `switch_br` case: jump to `block` when the value equals `key`.
pub const Case = extern struct {
    key_lo: u32,
    key_hi: u32,
    block: Block,

    pub fn init(k: u64, block: Block) Case {
        return .{ .key_lo = @truncate(k), .key_hi = @intCast(k >> 32), .block = block };
    }

    pub fn key(c: Case) u64 {
        return @as(u64, c.key_hi) << 32 | c.key_lo;
    }
};

/// One instruction row (B.1: SoA, `u32` indices, no pointers).
pub const Inst = struct {
    op: Op,
    /// Type of the yielded value; `.void` if none.
    ty: TypeId,
    /// Source node for diagnostics; `.none` for synthesized code.
    node: NodeIndex,
    a: u32,
    b: u32,
};

/// How a local was declared (§5.5.1, §5.5.2). `comptime` parameters do not
/// appear: they are constants of their instantiation (§8.2).
pub const LocalKind = enum(u8) {
    let,
    let_mut,
    param,
    param_mut,
    param_move,
    /// Compiler temporary (desugarings §6.12, spilled match subjects).
    temp,

    pub fn isParam(k: LocalKind) bool {
        return k == .param or k == .param_mut or k == .param_move;
    }
};

/// One local slot.
pub const LocalInfo = struct {
    ty: TypeId,
    /// Source name; `.none` for temporaries.
    name: StrId,
    kind: LocalKind,
    node: NodeIndex = .none,
    /// A `@workgroup` variable (§11.1.4): one slot shared by the workgroup.
    workgroup: bool = false,
};

/// Opcodes. The payload and meaning of each is documented on the `Data`
/// field of the same name. Order matters: places and terminators are ranges.
pub const Op = enum(u8) {
    int,
    float,
    str,
    type,
    @"comptime",
    fn_ref,
    block_param,

    local,
    global,
    deref,
    field,
    index,
    variant_field,

    load,
    move,
    view,
    view_mut,
    addr_of,
    store,

    add,
    sub,
    mul,
    div,
    rem,
    neg,
    bit_and,
    bit_or,
    bit_xor,
    bit_not,
    shl,
    shr,
    not,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,

    splat,
    swizzle,

    cast,
    coerce,

    aggregate,
    repeat,
    variant,
    extract,
    enum_tag,
    len,
    slice,

    call,
    call_indirect,
    builtin,

    nursery_begin,
    spawn,
    spawn_indirect,
    nursery_end,
    pfor_begin,
    pfor_end,
    launch,

    scope_begin,
    scope_end,
    @"defer",
    @"errdefer",

    br,
    cond_br,
    switch_br,
    ret,
    ret_tail,
    ret_tail_indirect,
    @"unreachable",
    defer_end,

    /// Ends a block; nothing may follow it in the block.
    pub fn isTerminator(op: Op) bool {
        return @backingInt(op) >= @backingInt(Op.br);
    }

    /// Yields a place (storage), not a value.
    pub fn isPlace(op: Op) bool {
        return @backingInt(op) >= @backingInt(Op.local) and @backingInt(op) <= @backingInt(Op.variant_field);
    }
};

const R = Ref;
const OR = ?Ref;
const L = []const Ref;
const Imms = []const u32;
const Cases = []const Case;

/// Typed payload of each opcode. "ty" names the type of the yielded value.
/// Integer signedness, float width, vector lanes and enum/struct layout all
/// come from the operand types, so one opcode serves every numeric type
/// and lowering picks the P-IR instruction (B.5.2) from them.
/// List slices returned by `decode` point into `extra` and are invalidated
/// by the next `Builder.add`.
pub const Data = union(Op) {
    // Constants and values.

    /// Integer, `bool` (0/1) or payload-free enum discriminant, truncated
    /// to the width of ty and stored zero- or sign-extended to 64 bits as ty
    /// is unsigned or signed; signedness of a distinct type is its
    /// underlying type's. ty: a typed integer, `bool`, enum, or distinct
    /// type over one; never `untyped_int` (see the file doc).
    int: struct { value: u64 },
    /// Float constant as `f64` bits (an `f32` constant is exact in `f64`).
    /// ty: `f32`, `f64` or a distinct type over one; never `untyped_float`.
    float: struct { bits: u64 },
    /// String literal (§5.4: origin `static`). ty: `str`.
    str: struct { string: StrId },
    /// A type as a comptime value (§8.3). ty: `type`.
    type: struct { value: TypeId },
    /// A comptime value embedded as a constant (§8.1). ty: its type.
    @"comptime": struct { value: ComptimeId },
    /// Address of function `func` (§6.10, §4.6). ty: a `fn` pointer type or `FnRef`.
    fn_ref: struct { func: FnId },
    /// A block parameter; only at the head of a block, in parameter order.
    /// Branches to the block pass one argument per parameter.
    block_param: struct {},

    // Places (§5.4 origins). ty: the type of the named storage.

    /// Local slot `local`.
    local: struct { local: Local },
    /// Global `global` (§5.9).
    global: struct { global: GlobalId },
    /// The storage a pointer or view value refers to (`*p`, `mut T` locals).
    deref: struct { ptr: R },
    /// Field `index` (declaration order; tuple position) of the struct or
    /// tuple place `base`. On a SoA array/slice place this is the column
    /// (§4.4.2, §6.3.2); on a SoA element place it is that column's element.
    field: struct { base: R, index: u32 },
    /// Element `index` (`usize`) of an array, slice, SoA, `vec` or `str` place
    /// (§6.5.2). Bounds are checked by lowering (§6.5.3).
    index: struct { base: R, index: R },
    /// Payload field `index` of variant `variant` of the enum place `base`.
    /// Only valid where the variant is known (after a `switch_br` on its tag).
    variant_field: struct { base: R, variant: u32, index: u32 },

    // Place access.

    /// Copy of the value at `place`. ty: the place's type.
    load: struct { place: R },
    /// Move of the resource at `place` (§5.3.2); the place is consumed.
    move: struct { place: R },
    /// Read-only view of `place` (§5.4): slice of an array, view argument of a
    /// resource or view. ty: the view type.
    view: struct { place: R },
    /// Mutable view of `place` (`mut` argument, `let x: mut T`, §5.5.3).
    view_mut: struct { place: R },
    /// Raw pointer to `place` (§12.2). ty: `*T` or `*const T`.
    addr_of: struct { place: R },
    /// Writes `value` to `place`. Operands are evaluated before (§6.1). ty: `void`.
    store: struct { place: R, value: R },

    // Arithmetic (§6.4) on scalars or lane-wise on `vec`s of one type;
    // overflow, division and shift traps (§6.4.2, §6.4.3) are inserted by lowering.

    add: struct { lhs: R, rhs: R },
    sub: struct { lhs: R, rhs: R },
    mul: struct { lhs: R, rhs: R },
    /// Integer division truncates; float division is IEEE.
    div: struct { lhs: R, rhs: R },
    /// Sign of the dividend (§6.4.3).
    rem: struct { lhs: R, rhs: R },
    neg: struct { operand: R },
    bit_and: struct { lhs: R, rhs: R },
    bit_or: struct { lhs: R, rhs: R },
    bit_xor: struct { lhs: R, rhs: R },
    bit_not: struct { operand: R },
    /// `rhs` is any unsigned integer type.
    shl: struct { lhs: R, rhs: R },
    /// Arithmetic on signed, logical on unsigned types.
    shr: struct { lhs: R, rhs: R },
    /// Logical `!` on `bool` or `mask<N>`. `&&`/`||` are control flow.
    not: struct { operand: R },
    /// Comparisons (§6.4.1). ty: `bool`, or `mask<N>` on `vec`s. Aggregate
    /// and `str` comparisons are expanded by lowering.
    eq: struct { lhs: R, rhs: R },
    ne: struct { lhs: R, rhs: R },
    lt: struct { lhs: R, rhs: R },
    le: struct { lhs: R, rhs: R },
    gt: struct { lhs: R, rhs: R },
    ge: struct { lhs: R, rhs: R },

    // Vectors (§10.6).

    /// Broadcast of a scalar to every lane (§6.4.1). ty: the `vec`/`mask`.
    splat: struct { scalar: R },
    /// Swizzle `v.xzy` (§10.6.2): result lane i is lane `lanes[i]` of `vec`.
    swizzle: struct { vec: R, lanes: Imms },

    // Conversions.

    /// Explicit `value as ty` (§4.9.2); the conversion kind follows from
    /// the two types.
    cast: struct { value: R },
    /// Implicit conversion (§4.9.1): widening, untyped constant to typed,
    /// `mut T` to `T` view, array to slice, function to `fn` pointer.
    coerce: struct { value: R },

    // Aggregates.

    /// Struct (fields in declaration order), tuple, array or `vec` value
    /// from its elements. Source order evaluation (§6.1) is the order of
    /// the operand instructions, not of this list. ty: the aggregate.
    aggregate: struct { elems: L },
    /// `[value; N]` (§6.2.4); `N` comes from the array type.
    repeat: struct { value: R },
    /// Enum value of variant `variant` with `payload` (`.some(x)`, `.idle`).
    variant: struct { variant: u32, payload: L },
    /// Field or tuple element `index` of the aggregate value `value`.
    extract: struct { value: R, index: u32 },
    /// Discriminant of the enum place `place` (match subjects are places;
    /// a temporary subject is stored to a `temp` local first). ty: the
    /// enum's backing integer type.
    enum_tag: struct { place: R },
    /// Length of an array, slice, SoA or `str` value or place. ty: `usize`.
    len: struct { value: R },
    /// `base[lo..hi]` view of an array, slice, SoA or `str` place (§6.5.4);
    /// absent bounds default to 0 and `len`. ty: the slice/view type.
    slice: struct { base: R, lo: OR, hi: OR },

    // Calls (§6.9). Argument modes are explicit in the argument
    // instructions (`load`/`view`/`view_mut`/`move`).

    /// Direct call. ty: the return type.
    call: struct { callee: FnId, args: L },
    /// Call through a function-pointer value.
    call_indirect: struct { callee: R, args: L },
    /// Builtin or compiler intrinsic (§8.7) from the builtin registry.
    builtin: struct { builtin: BuiltinId, args: L },

    // Concurrency and GPU (§10.2, §10.3, §11.2.3).

    /// Opens a `nursery` body. Its ref names the nursery. ty: `void`.
    nursery_begin: struct {},
    /// `spawn callee(args)` inside `nursery`. ty: `void`.
    spawn: struct { nursery: R, callee: FnId, args: L },
    /// `spawn` through a function-pointer value `callee` (§10.2 item 1
    /// evaluates `f`). ty: `void`.
    spawn_indirect: struct { nursery: R, callee: R, args: L },
    /// End of the nursery body: joins every task spawned in it. Emitted on
    /// every route out of the body, like `scope_end`, and always before the
    /// `scope_end` of the body's own scope (§10.2 item 3: join, then defers).
    nursery_end: struct { nursery: R },
    /// Starts a `parallel_for` body over indices `lo..hi`; yields the
    /// iteration index. The body runs from here to `pfor_end`.
    pfor_begin: struct { lo: R, hi: R },
    /// End of one iteration of the `parallel_for` body opened by `pfor`
    /// (also the target of an unlabelled `continue`).
    pfor_end: struct { pfor: R },
    /// `launch target kernel(args) over n` (§11.2.3); `over` absent means
    /// the length of the first slice or buffer argument. ty: `void`.
    launch: struct { target: LaunchTarget, kernel: FnId, args: L, over: OR },

    // Scope markers (§6.8); see the file doc.

    /// Opens a block scope; its ref names the scope. ty: `void`.
    scope_begin: struct {},
    /// Control leaves `scope` along this path.
    scope_end: struct { scope: R },
    /// Registers `defer` body `body` (blocks ending in `defer_end`) in `scope`.
    @"defer": struct { scope: R, body: Block },
    /// Registers `errdefer` body `body`, run only when the function returns
    /// `.err` (§6.8.2).
    @"errdefer": struct { scope: R, body: Block },

    // Terminators.

    /// Jump to `target`, binding its block parameters to `args`.
    br: struct { target: Block, args: L },
    /// Two-way branch on a `bool`.
    cond_br: struct { cond: R, then: Block, @"else": Block },
    /// Multi-way branch on an integer or enum tag (§6.6.3 lowering).
    switch_br: struct { value: R, default: Block, cases: Cases },
    /// Return `value` (absent for `void`).
    ret: struct { value: OR },
    /// `return tail callee(args)` (§6.9): the frame is reused.
    ret_tail: struct { callee: FnId, args: L },
    /// `return tail` through a function-pointer value `callee` (§6.9).
    ret_tail_indirect: struct { callee: R, args: L },
    /// Control never reaches here (after `noreturn` calls and traps).
    @"unreachable": struct {},
    /// End of a `defer`/`errdefer` body region.
    defer_end: struct {},
};

comptime {
    // B.1: instruction rows hold indices only.
    for (@typeInfo(Inst).@"struct".field_types) |F| std.debug.assert(@typeInfo(F) != .pointer);
    std.debug.assert(@sizeOf(Op) == 1);
}

/// Encoded "absent" slot.
const none: u32 = std.math.maxInt(u32);

/// Encodes `d` into an instruction's `a`/`b`, appending to `extra`.
pub fn encode(gpa: Allocator, extra: *std.ArrayList(u32), d: Data) Allocator.Error!struct { a: u32, b: u32 } {
    switch (d) {
        inline else => |p| {
            const info = @typeInfo(@TypeOf(p)).@"struct";
            var slots: [slotCount(@TypeOf(p))]u32 = undefined;
            var j: usize = 0;
            inline for (info.field_names, info.field_types) |name, F| {
                const v = @field(p, name);
                if (F == u64) {
                    slots[j] = @truncate(v);
                    slots[j + 1] = @intCast(v >> 32);
                    j += 2;
                } else {
                    slots[j] = try encodeSlot(gpa, extra, F, v);
                    j += 1;
                }
            }
            var a: u32 = 0;
            var b: u32 = 0;
            if (slots.len > 0) a = slots[0];
            if (slots.len == 2) b = slots[1];
            if (slots.len > 2) {
                b = @intCast(extra.items.len);
                try extra.appendSlice(gpa, slots[1..]);
            }
            return .{ .a = a, .b = b };
        },
    }
}

/// Decodes the payload of an instruction with opcode `op` and slots `a`, `b`.
pub fn decode(op: Op, a: u32, b: u32, extra: []const u32) Data {
    switch (op) {
        inline else => |k| {
            const P = @FieldType(Data, @tagName(k));
            const info = @typeInfo(P).@"struct";
            const n = comptime slotCount(P);
            var p: P = undefined;
            _ = &p;
            var j: usize = 0;
            inline for (info.field_names, info.field_types) |name, F| {
                const s0 = slot(a, b, extra, n, j);
                if (F == u64) {
                    @field(p, name) = @as(u64, slot(a, b, extra, n, j + 1)) << 32 | s0;
                    j += 2;
                } else {
                    @field(p, name) = decodeSlot(extra, F, s0);
                    j += 1;
                }
            }
            return @unionInit(Data, @tagName(k), p);
        },
    }
}

fn slot(a: u32, b: u32, extra: []const u32, n: usize, j: usize) u32 {
    if (j == 0) return a;
    return if (n <= 2) b else extra[b + j - 1];
}

fn slotCount(comptime P: type) usize {
    var n: usize = 0;
    for (@typeInfo(P).@"struct".field_types) |F| n += if (F == u64) 2 else 1;
    return n;
}

fn encodeSlot(gpa: Allocator, extra: *std.ArrayList(u32), comptime F: type, v: F) Allocator.Error!u32 {
    switch (F) {
        L, Imms, Cases => {
            const e: u32 = @intCast(extra.items.len);
            const words: []const u32 = @ptrCast(v);
            try extra.ensureUnusedCapacity(gpa, words.len + 1);
            extra.appendAssumeCapacity(@intCast(v.len));
            extra.appendSliceAssumeCapacity(words);
            return e;
        },
        OR => return @backingInt(v orelse Ref.none),
        u32 => return v,
        else => return @backingInt(v), // u32-backed enums and indices
    }
}

fn decodeSlot(extra: []const u32, comptime F: type, raw: u32) F {
    switch (F) {
        L, Imms, Cases => {
            const E = @typeInfo(F).pointer.child;
            const items: [*]const E = @ptrCast(extra[raw + 1 ..].ptr);
            return items[0..extra[raw]];
        },
        OR => return @as(Ref, @fromBackingInt(raw)).unwrap(),
        u32 => return raw,
        else => return @fromBackingInt(raw),
    }
}

/// The instructions of one block: `Func.order[start..][0..len]`.
pub const BlockInfo = struct { start: u32, len: u32 };

/// A finished function body; built by `Builder.finish`. All arrays live in
/// the arena the builder used.
pub const Func = struct {
    /// Return type.
    ret: TypeId,
    /// `locals[0..param_count]` are the parameters, in order.
    param_count: u32,
    insts: std.MultiArrayList(Inst).Slice,
    extra: []const u32,
    /// Entry block first.
    blocks: []const BlockInfo,
    /// Instruction refs of every block, block after block.
    order: []const Ref,
    locals: std.MultiArrayList(LocalInfo).Slice,

    pub fn op(f: *const Func, r: Ref) Op {
        return f.insts.items(.op)[r.int()];
    }

    pub fn typeOf(f: *const Func, r: Ref) TypeId {
        return f.insts.items(.ty)[r.int()];
    }

    pub fn nodeOf(f: *const Func, r: Ref) NodeIndex {
        return f.insts.items(.node)[r.int()];
    }

    /// Typed payload of instruction `r`.
    pub fn data(f: *const Func, r: Ref) Data {
        const i = r.int();
        return decode(f.insts.items(.op)[i], f.insts.items(.a)[i], f.insts.items(.b)[i], f.extra);
    }

    /// Instructions of block `b` in order, block parameters first.
    pub fn blockInsts(f: *const Func, b: Block) []const Ref {
        const info = f.blocks[b.int()];
        return f.order[info.start..][0..info.len];
    }

    /// The block's terminator (every finished block has one).
    pub fn terminator(f: *const Func, b: Block) Ref {
        const insts = f.blockInsts(b);
        return insts[insts.len - 1];
    }

    pub fn local(f: *const Func, l: Local) LocalInfo {
        return f.locals.get(l.int());
    }
};

const testing = std.testing;

test "instruction rows are small and pointer-free" {
    try testing.expect(@sizeOf(Inst) <= 20);
    inline for (@typeInfo(Data).@"union".field_types) |P| {
        try testing.expect(comptime slotCount(P) <= 4);
    }
    try testing.expect(Op.ret.isTerminator() and Op.defer_end.isTerminator() and !Op.@"defer".isTerminator());
    try testing.expect(Op.ret_tail_indirect.isTerminator() and !Op.spawn_indirect.isTerminator());
    try testing.expect(Op.local.isPlace() and Op.variant_field.isPlace() and !Op.load.isPlace());
}

test "encode/decode round-trips every slot kind" {
    const gpa = testing.allocator;
    var extra: std.ArrayList(u32) = .empty;
    defer extra.deinit(gpa);

    const big: u64 = 0xdead_beef_0000_0007;
    var s = try encode(gpa, &extra, .{ .int = .{ .value = big } });
    try testing.expectEqual(big, decode(.int, s.a, s.b, extra.items).int.value);

    const args: L = &.{ .from(1), .from(2), .from(3) };
    s = try encode(gpa, &extra, .{ .launch = .{ .target = .gpu, .kernel = .from(9), .args = args, .over = null } });
    const l = decode(.launch, s.a, s.b, extra.items).launch;
    try testing.expectEqual(LaunchTarget.gpu, l.target);
    try testing.expectEqual(FnId.from(9), l.kernel);
    try testing.expectEqualSlices(Ref, args, l.args);
    try testing.expectEqual(null, l.over);

    const cases: Cases = &.{ .init(0, .from(1)), .init(1 << 40, .from(2)) };
    s = try encode(gpa, &extra, .{ .switch_br = .{ .value = .from(0), .default = .from(3), .cases = cases } });
    const sw = decode(.switch_br, s.a, s.b, extra.items).switch_br;
    try testing.expectEqual(@as(u64, 1 << 40), sw.cases[1].key());
    try testing.expectEqual(Block.from(2), sw.cases[1].block);
    try testing.expectEqual(Block.from(3), sw.default);

    s = try encode(gpa, &extra, .{ .swizzle = .{ .vec = .from(4), .lanes = &.{ 0, 2, 1 } } });
    try testing.expectEqualSlices(u32, &.{ 0, 2, 1 }, decode(.swizzle, s.a, s.b, extra.items).swizzle.lanes);

    s = try encode(gpa, &extra, .{ .slice = .{ .base = .from(5), .lo = .from(6), .hi = null } });
    const sl = decode(.slice, s.a, s.b, extra.items).slice;
    try testing.expectEqual(Ref.from(6), sl.lo.?);
    try testing.expectEqual(null, sl.hi);
}
