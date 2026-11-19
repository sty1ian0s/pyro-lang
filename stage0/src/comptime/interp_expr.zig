//! Comptime interpreter, part A (§8.1, §8.6, B.4): the value operations of
//! TIR. Given operand `Value`s, each function computes what one TIR
//! instruction yields at comptime; the register machine over the CFG
//! (`interp_ctrl.zig`, T058) calls them and owns places, calls and traces.
//!
//! - Integers (§6.4.2, §6.4.3) are computed at the target's width
//!   (`usize`/`isize` are `ptr_bits` wide, §8.6). A result outside the type,
//!   division by zero, `iN.MIN / -1` and a shift by the width or more are
//!   traps: comptime evaluation fails with a `Trap`, which `report` turns
//!   into a compile error carrying the comptime trace. Comptime traps in
//!   every build mode; the unchecked-build wrapping of §6.4.2 is a runtime
//!   behaviour.
//! - Floats are strict IEEE 754 binary32/binary64 (§6.4.4, §8.6): every
//!   operation rounds once to nearest even at its own width, nothing is
//!   contracted or reassociated (Zig's default strict float mode), and
//!   subnormals are kept. The one thing IEEE leaves to the hardware is
//!   which NaN comes out, and x86-64 and aarch64 differ there, so NaNs are
//!   computed explicitly: a NaN operand propagates quieted (the left one
//!   first), and an invalid operation yields the positive quiet NaN.
//! - Aggregates (structs, tuples, arrays, `vec`, `mask`), slices, `str` and
//!   enums are `Value` members (`value.zig`); bounds are checked (§6.5.3).
//!
//! Results are allocated from `Interp.arena`, the evaluation arena.

const std = @import("std");
const Allocator = std.mem.Allocator;
const diag = @import("../diag/diag.zig");
const Types = @import("../sema/types.zig");
const convert = @import("../sema/convert.zig");
const Items = @import("../sema/items.zig").Items;
const tir = @import("../tir/tir.zig");
const Value = @import("value.zig").Value;

const TypeId = Types.TypeId;
const IntInfo = convert.IntInfo;

/// A runtime trap reached during comptime evaluation (§6.4.2, §6.4.3,
/// §6.5.3). Comptime turns it into a compile error.
pub const Trap = error{
    IntegerOverflow,
    DivisionByZero,
    ShiftOverflow,
    OutOfBounds,
    NotCharBoundary,
};

pub const Error = Allocator.Error || Trap;

/// The trap message, as the runtime words it.
pub fn message(t: Trap) []const u8 {
    return switch (t) {
        error.IntegerOverflow => "integer overflow",
        error.DivisionByZero => "division by zero",
        error.ShiftOverflow => "shift amount is not less than the bit width",
        error.OutOfBounds => "index out of bounds",
        error.NotCharBoundary => "str slice bound is not on a UTF-8 character boundary",
    };
}

/// Reports trap `t` reached at `span` as a compile error (§8.6) with the
/// comptime `trace` (innermost first). A.3 has no code for it, so the
/// diagnostic has none (spec gap, see T058).
pub fn report(sink: *diag.Sink, t: Trap, span: diag.Span, trace: []const diag.TraceFrame) Allocator.Error!void {
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "comptime evaluation traps: {s}", .{message(t)}) catch unreachable;
    try sink.emit(.{
        .code = null,
        .severity = .@"error",
        .message = msg,
        .spans = &.{.{ .span = span, .primary = true }},
        .trace = trace,
    });
}

/// The value operations of one evaluation.
pub const Interp = struct {
    items: *Items,
    /// The evaluation arena (`arena.zig`); results live here.
    arena: Allocator,

    fn types(in: *const Interp) *Types {
        return in.items.types;
    }

    /// `ty` with `distinct` wrappers removed (§4.7).
    fn base(in: *const Interp, ty: TypeId) TypeId {
        var t = ty;
        while (true) switch (in.types().get(t)) {
            .nominal => |n| if (n.kind == .distinct) {
                t = n.underlying;
            } else return t,
            else => return t,
        };
    }

    fn intInfo(in: *const Interp, ty: TypeId) ?IntInfo {
        return convert.intInfo(in.types(), in.items.options.ptr_bits, in.base(ty));
    }

    /// Lane count of a `vec` or `mask` type, or null.
    fn lanes(in: *const Interp, ty: TypeId) ?u32 {
        return switch (in.types().get(in.base(ty))) {
            .vec => |v| v.len,
            .mask => |m| m.len,
            else => null,
        };
    }

    /// Lane type of a `vec` or `mask` type.
    fn laneType(in: *const Interp, ty: TypeId) TypeId {
        return switch (in.types().get(in.base(ty))) {
            .vec => |v| v.elem,
            else => .bool,
        };
    }

    /// `a op b` for the binary arithmetic, bitwise, shift and comparison
    /// opcodes (`add` .. `ge`), yielding type `ty`; lane-wise on `vec`s and
    /// `mask`s (a scalar shift amount applies to every lane).
    pub fn binary(in: *const Interp, op: tir.Op, ty: TypeId, a: Value, b: Value) Error!Value {
        if (in.lanes(a.ty)) |n| {
            const out = try in.arena.alloc(Value, n);
            const lane_ty = in.laneType(ty);
            for (out, a.data.aggregate, 0..) |*o, x, i| {
                const y = if (b.data == .aggregate) b.data.aggregate[i] else b;
                o.* = try in.binary(op, lane_ty, x, y);
            }
            return .{ .ty = ty, .data = .{ .aggregate = out } };
        }
        switch (op) {
            .eq, .ne => return .boolean(in.equal(a, b) == (op == .eq)),
            .lt, .le, .gt, .ge => {
                const ord = in.order(a, b) orelse return .boolean(false); // NaN is unordered
                return .boolean(switch (op) {
                    .lt => ord == .lt,
                    .le => ord != .gt,
                    .gt => ord == .gt,
                    else => ord != .lt,
                });
            },
            else => {},
        }
        const bt = in.base(a.ty);
        const x = a.data.scalar;
        const y = b.data.scalar;
        const bits: u64 = switch (bt) {
            .f32 => floatBits(strict(f32, op, floatOf(f32, x), floatOf(f32, y))),
            .f64 => floatBits(strict(f64, op, floatOf(f64, x), floatOf(f64, y))),
            .bool => switch (op) {
                .bit_and => x & y,
                .bit_or => x | y,
                .bit_xor => x ^ y,
                else => unreachable,
            },
            else => try intBinary(op, in.intInfo(bt).?, x, y),
        };
        return .{ .ty = ty, .data = .{ .scalar = bits } };
    }

    fn intBinary(op: tir.Op, info: IntInfo, x: u64, y: u64) Trap!u64 {
        switch (op) {
            .bit_and => return x & y,
            .bit_or => return x | y,
            .bit_xor => return x ^ y,
            .shl, .shr => {
                // The amount is unsigned (§6.4.1), so `y` is zero-extended.
                if (y >= info.bits) return error.ShiftOverflow;
                const n: u6 = @intCast(y);
                if (op == .shl) return wrap(info, x << n);
                return if (info.signedness == .signed) @bitCast(@as(i64, @bitCast(x)) >> n) else x >> n;
            },
            else => {},
        }
        const l = intOf(info, x);
        const r = intOf(info, y);
        const res: i128 = switch (op) {
            .add => l + r,
            .sub => l - r,
            .mul => blk: {
                const p, const o = @mulWithOverflow(l, r);
                if (o != 0) return error.IntegerOverflow;
                break :blk p;
            },
            .div, .rem => blk: {
                if (r == 0) return error.DivisionByZero;
                break :blk if (op == .div) @divTrunc(l, r) else @rem(l, r);
            },
            else => unreachable,
        };
        return fit(info, res) orelse error.IntegerOverflow;
    }

    /// `neg`, `bit_not` or `not` of `a`, yielding type `a.ty`; lane-wise on
    /// `vec`s and `mask`s.
    pub fn unary(in: *const Interp, op: tir.Op, a: Value) Error!Value {
        if (in.lanes(a.ty)) |n| {
            const out = try in.arena.alloc(Value, n);
            for (out, a.data.aggregate) |*o, x| o.* = try in.unary(op, x);
            return .{ .ty = a.ty, .data = .{ .aggregate = out } };
        }
        const x = a.data.scalar;
        const bt = in.base(a.ty);
        const bits: u64 = switch (op) {
            .not => x ^ 1,
            .neg => switch (bt) {
                // IEEE negation flips the sign bit, also of a NaN.
                .f32 => x ^ (1 << 31),
                .f64 => x ^ (1 << 63),
                else => blk: {
                    const info = in.intInfo(bt).?;
                    break :blk fit(info, -intOf(info, x)) orelse return error.IntegerOverflow;
                },
            },
            .bit_not => wrap(in.intInfo(bt).?, ~x),
            else => unreachable,
        };
        return .{ .ty = a.ty, .data = .{ .scalar = bits } };
    }

    /// Equality (§6.4.1): floats by IEEE (`NaN != NaN`, `0.0 == -0.0`),
    /// aggregates, `str`, slices and enums member-wise.
    pub fn equal(in: *const Interp, a: Value, b: Value) bool {
        switch (a.data) {
            .scalar => |x| return switch (in.base(a.ty)) {
                .f32 => floatOf(f32, x) == floatOf(f32, b.data.scalar),
                .f64 => floatOf(f64, x) == floatOf(f64, b.data.scalar),
                else => x == b.data.scalar,
            },
            .str => |s| return std.mem.eql(u8, s, b.data.str),
            .aggregate, .slice, .bytes => {
                const n = count(a);
                if (n != count(b)) return false;
                for (0..n) |i| if (!in.equal(elem(a, i), elem(b, i))) return false;
                return true;
            },
            .variant => |v| {
                const w = b.data.variant;
                if (v.index != w.index) return false;
                for (v.payload, w.payload) |x, y| if (!in.equal(x, y)) return false;
                return true;
            },
            else => return a.eql(b),
        }
    }

    /// Ordering (§6.4.1) of integers, floats, `str` (byte-wise) and
    /// payload-free enums (by discriminant); null if a float is NaN.
    pub fn order(in: *const Interp, a: Value, b: Value) ?std.math.Order {
        if (a.data == .str) return std.mem.order(u8, a.data.str, b.data.str);
        const x = a.data.scalar;
        const y = b.data.scalar;
        const bt = in.base(a.ty);
        switch (bt) {
            // An `f32` is exact as `f64`.
            .f32 => return floatOrder(floatOf(f32, x), floatOf(f32, y)),
            .f64 => return floatOrder(floatOf(f64, x), floatOf(f64, y)),
            else => {},
        }
        const info = in.intInfo(bt) orelse if (in.items.enumOf(bt)) |e| in.intInfo(e.backing).? else IntInfo{ .signedness = .unsigned, .bits = 64 };
        return std.math.order(intOf(info, x), intOf(info, y));
    }

    /// `v as to` (§4.9.2). `enum_backing` is the backing type of `v.ty` if
    /// it is a payload-free enum, `.none` otherwise. Asserts the cast is
    /// legal.
    pub fn cast(in: *const Interp, v: Value, to: TypeId, enum_backing: TypeId) Error!Value {
        const kind = convert.cast(in.types(), v.ty, to, enum_backing).?;
        const from = in.base(v.ty);
        const bits: u64 = switch (kind) {
            .constant => unreachable, // TIR holds no untyped values
            .identity, .distinct, .bool_to_int, .ptr_to_int, .ptr_to_ptr, .int_to_ptr => return retype(v, to),
            .vec => {
                const out = try in.arena.alloc(Value, v.data.aggregate.len);
                const lane_to = in.laneType(to);
                const lane_backing: TypeId = .none;
                for (out, v.data.aggregate) |*o, x| o.* = try in.cast(x, lane_to, lane_backing);
                return .{ .ty = to, .data = .{ .aggregate = out } };
            },
            .int_to_int => wrap(in.intInfo(to).?, v.data.scalar),
            .enum_to_int => fit(in.intInfo(to).?, intOf(in.intInfo(enum_backing).?, v.data.scalar)).?,
            .int_to_float => blk: {
                const x = intOf(in.intInfo(from).?, v.data.scalar);
                break :blk if (in.base(to) == .f32) floatBits(@as(f32, @floatFromInt(x))) else floatBits(@as(f64, @floatFromInt(x)));
            },
            .float_to_int => floatToInt(in.intInfo(to).?, if (from == .f32) floatOf(f32, v.data.scalar) else floatOf(f64, v.data.scalar)),
            .float_to_float => if (in.base(to) == .f32) narrow(floatOf(f64, v.data.scalar)) else widen(floatOf(f32, v.data.scalar)),
        };
        return .{ .ty = to, .data = .{ .scalar = bits } };
    }

    /// Implicit conversion of `v` to `to` (§4.9.1, TIR `coerce`).
    pub fn coerce(in: *const Interp, v: Value, to: TypeId) Error!Value {
        const form: convert.Form = .{ .place = true, .non_generic_fn = v.data == .fn_ref };
        return switch (convert.coerce(in.types(), v.ty, to, form)) {
            .float_widen => .{ .ty = to, .data = .{ .scalar = widen(floatOf(f32, v.data.scalar)) } },
            .array_to_slice => .{ .ty = to, .data = .{ .slice = try in.values(v, 0, count(v)) } },
            .wrap_some => .{ .ty = to, .data = .{ .variant = .{ .index = 0, .payload = try in.arena.dupe(Value, &.{v}) } } },
            // Integer widening keeps the 64-bit encoding; the others
            // (views, function values) only change the type.
            else => retype(v, to),
        };
    }

    /// Broadcast of `scalar` to every lane of `vec`/`mask` type `ty`.
    pub fn splat(in: *const Interp, ty: TypeId, scalar: Value) Allocator.Error!Value {
        const out = try in.arena.alloc(Value, in.lanes(ty).?);
        @memset(out, scalar);
        return .{ .ty = ty, .data = .{ .aggregate = out } };
    }

    /// Swizzle (§10.6.2): lane `i` of the result is lane `lanes_[i]` of `v`.
    pub fn swizzle(in: *const Interp, ty: TypeId, v: Value, lanes_: []const u32) Allocator.Error!Value {
        const out = try in.arena.alloc(Value, lanes_.len);
        for (out, lanes_) |*o, l| o.* = v.data.aggregate[l];
        return .{ .ty = ty, .data = .{ .aggregate = out } };
    }

    /// A struct, tuple, array, `vec` or `mask` of type `ty` from `elems`.
    pub fn aggregate(in: *const Interp, ty: TypeId, elems: []const Value) Allocator.Error!Value {
        return .{ .ty = ty, .data = .{ .aggregate = try in.arena.dupe(Value, elems) } };
    }

    /// `[v; N]` of array type `ty` (§6.2.4).
    pub fn repeat(in: *const Interp, ty: TypeId, v: Value) Allocator.Error!Value {
        const out = try in.arena.alloc(Value, @intCast(in.types().get(in.base(ty)).array.len));
        @memset(out, v);
        return .{ .ty = ty, .data = .{ .aggregate = out } };
    }

    /// Variant `which` of enum `ty` with `payload`. A payload-free enum is
    /// its discriminant (`value.zig`).
    pub fn variant(in: *const Interp, ty: TypeId, which: u32, payload: []const Value) Allocator.Error!Value {
        if (in.items.enumOf(ty)) |e| if (!e.has_payload) {
            return .{ .ty = ty, .data = .{ .scalar = e.variants[which].discriminant.bits } };
        };
        return .{ .ty = ty, .data = .{ .variant = .{ .index = which, .payload = try in.arena.dupe(Value, payload) } } };
    }

    /// The discriminant of enum value `v`, of the enum's backing type `ty`.
    pub fn enumTag(in: *const Interp, ty: TypeId, v: Value) Value {
        const disc: u64 = switch (v.data) {
            .scalar => |s| s,
            .variant => |x| if (in.items.enumOf(v.ty)) |e| e.variants[x.index].discriminant.bits else x.index,
            else => unreachable,
        };
        return .{ .ty = ty, .data = .{ .scalar = disc } };
    }

    /// Member `member` of a struct, tuple or array value.
    pub fn extract(v: Value, member: u32) Value {
        return elem(v, member);
    }

    /// Length of an array, slice or `str` value, as a `usize`.
    pub fn len(v: Value) Value {
        return .{ .ty = .usize, .data = .{ .scalar = count(v) } };
    }

    /// `v[i]` (§6.5.2) of an array, slice, `vec` or `str` (a `u8`) value;
    /// traps out of bounds (§6.5.3).
    pub fn index(v: Value, i: Value) Trap!Value {
        if (i.data.scalar >= count(v)) return error.OutOfBounds;
        return elem(v, @intCast(i.data.scalar));
    }

    /// `v[lo..hi]` (§6.5.4) of an array, slice or `str` value, of slice type
    /// `ty`; null bounds default to 0 and the length. Traps unless
    /// `lo <= hi <= len`, or when a `str` bound splits a character.
    pub fn slice(in: *const Interp, ty: TypeId, v: Value, lo: ?Value, hi: ?Value) Error!Value {
        const n = count(v);
        const a = if (lo) |x| x.data.scalar else 0;
        const b = if (hi) |x| x.data.scalar else n;
        if (a > b or b > n) return error.OutOfBounds;
        if (v.data == .str) {
            const s = v.data.str;
            for ([_]u64{ a, b }) |k| if (k < n and s[@intCast(k)] & 0xC0 == 0x80) return error.NotCharBoundary;
            return .{ .ty = ty, .data = .{ .str = s[@intCast(a)..@intCast(b)] } };
        }
        return .{ .ty = ty, .data = .{ .slice = try in.values(v, @intCast(a), @intCast(b)) } };
    }

    /// Members `a..b` of `v` as values.
    fn values(in: *const Interp, v: Value, a: usize, b: usize) Allocator.Error![]const Value {
        return switch (v.data) {
            .aggregate, .slice => |vs| vs[a..b],
            else => {
                const out = try in.arena.alloc(Value, b - a);
                for (out, a..) |*o, i| o.* = elem(v, i);
                return out;
            },
        };
    }
};

fn retype(v: Value, to: TypeId) Value {
    return .{ .ty = to, .data = v.data };
}

/// Member count of an aggregate, slice, `[N]u8` or `str`.
fn count(v: Value) u64 {
    return switch (v.data) {
        .aggregate, .slice => |vs| vs.len,
        .bytes, .str => |s| s.len,
        else => unreachable,
    };
}

/// Member `i` of an aggregate, slice, `[N]u8` or `str` (bytes are `u8`).
fn elem(v: Value, i: usize) Value {
    return switch (v.data) {
        .aggregate, .slice => |vs| vs[i],
        .bytes, .str => |s| .{ .ty = .int(.unsigned, 8), .data = .{ .scalar = s[i] } },
        else => unreachable,
    };
}

/// The integer encoded by `x` (see `value.zig`).
fn intOf(info: IntInfo, x: u64) i128 {
    return if (info.signedness == .signed) @as(i64, @bitCast(x)) else x;
}

/// `x` encoded at `info`, or null if out of range.
fn fit(info: IntInfo, x: i128) ?u64 {
    const signed = info.signedness == .signed;
    const min: i128 = if (signed) -(@as(i128, 1) << @intCast(info.bits - 1)) else 0;
    const max: i128 = (@as(i128, 1) << @intCast(info.bits - @intFromBool(signed))) - 1;
    if (x < min or x > max) return null;
    return @bitCast(@as(i64, @truncate(x)));
}

/// `x` truncated to `info.bits` and zero- or sign-extended to 64 bits.
fn wrap(info: IntInfo, x: u64) u64 {
    const s: u6 = @intCast(64 - @as(u7, @intCast(info.bits)));
    return if (info.signedness == .signed) @bitCast(@as(i64, @bitCast(x << s)) >> s) else x << s >> s;
}

fn Bits(comptime F: type) type {
    return @Int(.unsigned, @bitSizeOf(F));
}

fn floatOf(comptime F: type, x: u64) F {
    return @bitCast(@as(Bits(F), @truncate(x)));
}

fn floatBits(x: anytype) u64 {
    return @as(Bits(@TypeOf(x)), @bitCast(x));
}

fn quietBit(comptime F: type) Bits(F) {
    return 1 << (std.math.floatFractionalBits(F) - 1);
}

/// The IEEE `add`/`sub`/`mul`/`div`/`rem` of `x` and `y`, each rounded once
/// at `F`, with host-independent NaNs (see the file comment).
fn strict(comptime F: type, op: tir.Op, x: F, y: F) F {
    if (std.math.isNan(x)) return @bitCast(@as(Bits(F), @bitCast(x)) | quietBit(F));
    if (std.math.isNan(y)) return @bitCast(@as(Bits(F), @bitCast(y)) | quietBit(F));
    const r = switch (op) {
        .add => x + y,
        .sub => x - y,
        .mul => x * y,
        .div => x / y,
        .rem => @rem(x, y), // sign of the dividend (§6.4.3); exact
        else => unreachable,
    };
    return if (std.math.isNan(r)) @bitCast(@as(Bits(F), @bitCast(std.math.inf(F))) | quietBit(F)) else r;
}

/// `f64` to `f32` bits, rounding to nearest even; a NaN keeps its sign and
/// the top of its payload and becomes quiet.
fn narrow(x: f64) u64 {
    if (!std.math.isNan(x)) return floatBits(@as(f32, @floatCast(x)));
    const b: u64 = @bitCast(x);
    const sign: u32 = @intCast(b >> 63);
    return sign << 31 | 0x7FC0_0000 | @as(u32, @truncate(b >> 29 & 0x3F_FFFF));
}

/// `f32` to `f64` bits (exact); a NaN keeps its sign and payload and
/// becomes quiet.
fn widen(x: f32) u64 {
    if (!std.math.isNan(x)) return floatBits(@as(f64, x));
    const b: u32 = @bitCast(x);
    return @as(u64, b >> 31) << 63 | 0x7FF8_0000_0000_0000 | @as(u64, b & 0x3F_FFFF) << 29;
}

fn floatOrder(l: f64, r: f64) ?std.math.Order {
    if (std.math.isNan(l) or std.math.isNan(r)) return null;
    return std.math.order(l, r);
}

/// `x as` an integer type (§4.9.2): toward zero, saturating, NaN to 0. An
/// `f32` is exact as `f64`.
fn floatToInt(info: IntInfo, x: f64) u64 {
    if (std.math.isNan(x)) return 0;
    const signed = info.signedness == .signed;
    const min: i128 = if (signed) -(@as(i128, 1) << @intCast(info.bits - 1)) else 0;
    const max: i128 = (@as(i128, 1) << @intCast(info.bits - @intFromBool(signed))) - 1;
    const t = @trunc(x);
    // `max` as a float rounds to `max` or up to `max + 1`; either way a
    // truncated `t` at or above it saturates.
    const v: i128 = if (t <= @as(f64, @floatFromInt(min))) min else if (t >= @as(f64, @floatFromInt(max))) max else @intFromFloat(t);
    return fit(info, v).?;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const items_mod = @import("../sema/items.zig");
const module_graph = @import("../resolve/module_graph.zig");
const imports = @import("../resolve/imports.zig");
const names_mod = @import("../resolve/names.zig");
const Interner = @import("../base/Interner.zig");

/// A checked one-module package for a target with `ptr_bits`-wide pointers.
const Fixture = struct {
    p: module_graph.TestPackage,
    g: module_graph.Graph,
    im: imports.Imports,
    names: names_mod.Names,
    strings: Interner,
    types: Types,
    items: Items,
    arena: std.heap.ArenaAllocator,

    fn init(f: *Fixture, ptr_bits: u8, src: []const u8) !void {
        f.p = try .init(&.{.{ "a", src }});
        f.g = try f.p.graph(.{ .kind = .lib });
        f.im = try imports.resolve(testing.allocator, &f.p.sink, &f.g, .{});
        f.names = try names_mod.resolve(testing.allocator, &f.p.sink, &f.im);
        f.strings = .init(testing.allocator, testing.io);
        f.types = try .init(testing.allocator, testing.io, &f.strings);
        const pkg: Types.Package = .{ .name = try f.strings.intern("app"), .line = .{ .major = 1 } };
        f.items = try items_mod.check(testing.allocator, &f.p.sink, &f.types, &f.im, &f.names, .{ .package = pkg, .ptr_bits = ptr_bits });
        f.arena = .init(testing.allocator);
    }

    fn deinit(f: *Fixture) void {
        f.arena.deinit();
        f.items.deinit();
        f.types.deinit();
        f.strings.deinit();
        f.names.deinit();
        f.im.deinit();
        f.g.deinit();
        f.p.deinit();
    }

    fn interp(f: *Fixture) Interp {
        return .{ .items = &f.items, .arena = f.arena.allocator() };
    }

    fn typeOf(f: *Fixture, name: []const u8) !TypeId {
        return switch ((try f.items.info(.{ .module = 0, .item = f.g.modules[0].names.get(name).? })).*) {
            .@"struct" => |s| s.type,
            .@"enum" => |en| en.type,
            .distinct => |d| d,
            else => unreachable,
        };
    }

    fn int(f: *Fixture, ty: TypeId, v: i128) Value {
        return Value.int(&f.types, f.items.options.ptr_bits, ty, v).?;
    }
};

const u8_t: TypeId = .int(.unsigned, 8);
const i8_t: TypeId = .int(.signed, 8);
const u64_t: TypeId = .int(.unsigned, 64);
const i64_t: TypeId = .int(.signed, 64);

fn f32v(bits: u32) Value {
    return .{ .ty = .f32, .data = .{ .scalar = bits } };
}

fn f64v(bits: u64) Value {
    return .{ .ty = .f64, .data = .{ .scalar = bits } };
}

test "integer arithmetic at the target width traps on overflow, zero division and wide shifts" {
    for ([_]u8{ 32, 64 }) |ptr_bits| {
        var f: Fixture = undefined;
        try f.init(ptr_bits, "");
        defer f.deinit();
        const in = f.interp();

        // usize is the target's width (§8.6).
        const big = f.int(.usize, (@as(i128, 1) << @intCast(ptr_bits)) - 1);
        try testing.expectError(error.IntegerOverflow, in.binary(.add, .usize, big, f.int(.usize, 1)));
        try testing.expectError(error.IntegerOverflow, in.binary(.sub, .usize, f.int(.usize, 0), f.int(.usize, 1)));
        try testing.expectEqual(big.data.scalar, (try in.binary(.mul, .usize, big, f.int(.usize, 1))).data.scalar);
        const min = f.int(.isize, -(@as(i128, 1) << @intCast(ptr_bits - 1)));
        try testing.expectError(error.IntegerOverflow, in.binary(.div, .isize, min, f.int(.isize, -1)));
        try testing.expectError(error.IntegerOverflow, in.unary(.neg, min));
        try testing.expectError(error.ShiftOverflow, in.binary(.shl, .usize, big, f.int(u8_t, ptr_bits)));
    }
    var f: Fixture = undefined;
    try f.init(64, "");
    defer f.deinit();
    const in = f.interp();

    try testing.expectError(error.IntegerOverflow, in.binary(.add, u8_t, f.int(u8_t, 200), f.int(u8_t, 56)));
    try testing.expectEqual(@as(u64, 255), (try in.binary(.add, u8_t, f.int(u8_t, 200), f.int(u8_t, 55))).data.scalar);
    try testing.expectError(error.IntegerOverflow, in.binary(.mul, u64_t, f.int(u64_t, 1 << 63), f.int(u64_t, 1 << 63)));
    try testing.expectError(error.IntegerOverflow, in.binary(.mul, i8_t, f.int(i8_t, -128), f.int(i8_t, -1)));
    try testing.expectError(error.DivisionByZero, in.binary(.div, i8_t, f.int(i8_t, 1), f.int(i8_t, 0)));
    try testing.expectError(error.DivisionByZero, in.binary(.rem, u8_t, f.int(u8_t, 1), f.int(u8_t, 0)));
    // Truncated division; `%` takes the dividend's sign (§6.4.3).
    try testing.expect((try in.binary(.div, i8_t, f.int(i8_t, -7), f.int(i8_t, 2))).eql(f.int(i8_t, -3)));
    try testing.expect((try in.binary(.rem, i8_t, f.int(i8_t, -7), f.int(i8_t, 2))).eql(f.int(i8_t, -1)));
    try testing.expect((try in.binary(.rem, i8_t, f.int(i8_t, -128), f.int(i8_t, -1))).eql(f.int(i8_t, 0)));
    // Shifts drop bits; `>>` is arithmetic on signed types.
    try testing.expect((try in.binary(.shl, u8_t, f.int(u8_t, 0x81), f.int(u8_t, 1))).eql(f.int(u8_t, 2)));
    try testing.expect((try in.binary(.shl, i8_t, f.int(i8_t, 0x40), f.int(u8_t, 1))).eql(f.int(i8_t, -128)));
    try testing.expect((try in.binary(.shr, i8_t, f.int(i8_t, -128), f.int(u8_t, 7))).eql(f.int(i8_t, -1)));
    try testing.expect((try in.binary(.shr, u8_t, f.int(u8_t, 0x80), f.int(u8_t, 7))).eql(f.int(u8_t, 1)));
    try testing.expectError(error.ShiftOverflow, in.binary(.shr, u8_t, f.int(u8_t, 1), f.int(u8_t, 8)));
    try testing.expect((try in.unary(.bit_not, f.int(u8_t, 0x0F))).eql(f.int(u8_t, 0xF0)));
    try testing.expect((try in.unary(.bit_not, f.int(i8_t, 0))).eql(f.int(i8_t, -1)));
    try testing.expect((try in.unary(.bit_not, f.int(i64_t, -1))).eql(f.int(i64_t, 0)));
    try testing.expectEqual(@as(u64, 0), (try in.binary(.bit_and, u64_t, f.int(u64_t, 0xF0), f.int(u64_t, 0x0F))).data.scalar);
    try testing.expect((try in.binary(.lt, .bool, f.int(i8_t, -1), f.int(i8_t, 0))).eql(.boolean(true)));
    try testing.expect((try in.binary(.gt, .bool, f.int(u64_t, std.math.maxInt(u64)), f.int(u64_t, 0))).eql(.boolean(true)));
    try testing.expect((try in.unary(.not, .boolean(true))).eql(.boolean(false)));
}

test "floats are strict IEEE with host-independent bits, NaNs and subnormals" {
    var f: Fixture = undefined;
    try f.init(64, "");
    defer f.deinit();
    const in = f.interp();
    const Case = struct { op: tir.Op, a: u64, b: u64, want: u64 };

    const f64_cases = [_]Case{
        .{ .op = .add, .a = 0x3FB999999999999A, .b = 0x3FC999999999999A, .want = 0x3FD3333333333334 }, // 0.1 + 0.2
        .{ .op = .mul, .a = 0x0010000000000000, .b = 0x3FE0000000000000, .want = 0x0008000000000000 }, // min normal / 2: subnormal
        .{ .op = .div, .a = 0x0000000000000001, .b = 0x4000000000000000, .want = 0x0000000000000000 }, // min subnormal / 2: ties to even
        .{ .op = .div, .a = 0x0000000000000003, .b = 0x4000000000000000, .want = 0x0000000000000002 }, // 1.5 ulp: ties to even
        .{ .op = .div, .a = 0x3FF0000000000000, .b = 0x8000000000000000, .want = 0xFFF0000000000000 }, // 1 / -0 = -inf, no trap
        .{ .op = .sub, .a = 0x7FF0000000000000, .b = 0x7FF0000000000000, .want = 0x7FF8000000000000 }, // inf - inf: positive quiet NaN
        .{ .op = .mul, .a = 0x0000000000000000, .b = 0xFFF0000000000000, .want = 0x7FF8000000000000 }, // 0 * -inf (x86 would give 0xFFF8...)
        .{ .op = .add, .a = 0x7FF0000000000001, .b = 0x7FF8000000000002, .want = 0x7FF8000000000001 }, // left NaN wins, quieted
        .{ .op = .mul, .a = 0x3FF0000000000000, .b = 0xFFF4000000000007, .want = 0xFFFC000000000007 }, // NaN payload and sign kept
        .{ .op = .rem, .a = 0xC01C000000000000, .b = 0x4000000000000000, .want = 0xBFF0000000000000 }, // -7 % 2 = -1
        .{ .op = .rem, .a = 0x3FF0000000000000, .b = 0x0000000000000000, .want = 0x7FF8000000000000 }, // 1 % 0 = NaN
    };
    for (f64_cases) |c| try testing.expectEqual(c.want, (try in.binary(c.op, .f64, f64v(c.a), f64v(c.b))).data.scalar);

    const f32_cases = [_]Case{
        .{ .op = .add, .a = 0x3DCCCCCD, .b = 0x3E4CCCCD, .want = 0x3E99999A }, // 0.1f + 0.2f, not via f64
        .{ .op = .mul, .a = 0x00800000, .b = 0x3F000000, .want = 0x00400000 }, // subnormal
        .{ .op = .add, .a = 0x00000001, .b = 0x00000001, .want = 0x00000002 }, // subnormal sum, no flush to zero
        .{ .op = .mul, .a = 0x7F7FFFFF, .b = 0x40000000, .want = 0x7F800000 }, // overflow to inf
        .{ .op = .div, .a = 0x00000000, .b = 0x00000000, .want = 0x7FC00000 }, // 0 / 0
        .{ .op = .sub, .a = 0x7F800001, .b = 0x3F800000, .want = 0x7FC00001 }, // signalling NaN quieted
    };
    for (f32_cases) |c| try testing.expectEqual(c.want, (try in.binary(c.op, .f32, f32v(@intCast(c.a)), f32v(@intCast(c.b)))).data.scalar);
    // f32 `a * b + c` rounds twice (no fused multiply-add, §6.4.4).
    const a = f32v(0x3F800001); // 1 + 2^-23
    const sq = try in.binary(.mul, .f32, a, a);
    const r = try in.binary(.sub, .f32, sq, f32v(0x3F800000));
    try testing.expectEqual(@as(u64, 0x34800000), r.data.scalar); // 2^-22, not fma's 2^-22 + 2^-46

    // Negation flips the sign bit, even of NaN and zero.
    try testing.expectEqual(@as(u64, 0x8000000000000000), (try in.unary(.neg, f64v(0))).data.scalar);
    try testing.expectEqual(@as(u64, 0xFFC00000), (try in.unary(.neg, f32v(0x7FC00000))).data.scalar);
    // IEEE comparisons: NaN is unordered, 0 == -0.
    const nan = f64v(0x7FF8000000000000);
    try testing.expect((try in.binary(.ne, .bool, nan, nan)).eql(.boolean(true)));
    try testing.expect((try in.binary(.eq, .bool, nan, nan)).eql(.boolean(false)));
    try testing.expect((try in.binary(.le, .bool, nan, f64v(0))).eql(.boolean(false)));
    try testing.expect((try in.binary(.ge, .bool, nan, f64v(0))).eql(.boolean(false)));
    try testing.expect((try in.binary(.eq, .bool, f64v(0), f64v(0x8000000000000000))).eql(.boolean(true)));
}

test "casts follow §4.9.2" {
    var f: Fixture = undefined;
    try f.init(32, "enum E: i8 { a = -2, b = 5 }\ntype Meters = distinct u16;");
    defer f.deinit();
    const in = f.interp();

    // Integer to integer truncates or extends by the source signedness.
    try testing.expect((try in.cast(f.int(.int(.unsigned, 16), 0x1FF), u8_t, .none)).eql(f.int(u8_t, 0xFF)));
    try testing.expect((try in.cast(f.int(i8_t, -1), .int(.unsigned, 16), .none)).eql(f.int(.int(.unsigned, 16), 0xFFFF)));
    try testing.expect((try in.cast(f.int(u8_t, 0xFF), i8_t, .none)).eql(f.int(i8_t, -1)));
    try testing.expect((try in.cast(f.int(u64_t, 1 << 40), .usize, .none)).eql(f.int(.usize, 0))); // 32-bit target
    // Integer to float rounds to nearest even at the target width.
    try testing.expectEqual(@as(u64, 0x4B800000), (try in.cast(f.int(.int(.unsigned, 32), (1 << 24) + 1), .f32, .none)).data.scalar);
    try testing.expectEqual(@as(u64, 0x43F0000000000000), (try in.cast(f.int(u64_t, std.math.maxInt(u64)), .f64, .none)).data.scalar);
    // Float to integer: toward zero, saturating, NaN to 0.
    try testing.expect((try in.cast(f64v(0xC00C000000000000), i8_t, .none)).eql(f.int(i8_t, -3))); // -3.5
    try testing.expect((try in.cast(f64v(0x40AF400000000000), i8_t, .none)).eql(f.int(i8_t, 127))); // 4000
    try testing.expect((try in.cast(f64v(0xFFF0000000000000), u8_t, .none)).eql(f.int(u8_t, 0))); // -inf
    try testing.expect((try in.cast(f64v(0x43F0000000000000), u64_t, .none)).eql(f.int(u64_t, std.math.maxInt(u64)))); // 2^64
    try testing.expect((try in.cast(f32v(0x7FC00000), i64_t, .none)).eql(f.int(i64_t, 0)));
    // Float to float rounds to nearest even; NaNs keep sign and payload top.
    try testing.expectEqual(@as(u64, 0x3DCCCCCD), (try in.cast(f64v(0x3FB999999999999A), .f32, .none)).data.scalar); // 0.1
    try testing.expectEqual(@as(u64, 0x00000001), (try in.cast(f64v(0x36A0000000000000), .f32, .none)).data.scalar); // 2^-149
    try testing.expectEqual(@as(u64, 0xFFC00001), (try in.cast(f64v(0xFFF0000020000000), .f32, .none)).data.scalar);
    try testing.expectEqual(@as(u64, 0x7FF8000020000000), (try in.cast(f32v(0x7F800001), .f64, .none)).data.scalar);
    try testing.expectEqual(@as(u64, 0x7FF8000020000000), (try in.coerce(f32v(0x7F800001), .f64)).data.scalar);
    // Bool, enum and distinct.
    try testing.expect((try in.cast(.boolean(true), u8_t, .none)).eql(f.int(u8_t, 1)));
    const e = try f.typeOf("E");
    const a = try in.variant(e, 0, &.{});
    try testing.expect((try in.cast(a, .int(.signed, 16), i8_t)).eql(f.int(.int(.signed, 16), -2)));
    try testing.expect(in.enumTag(i8_t, a).eql(f.int(i8_t, -2)));
    try testing.expect((try in.binary(.lt, .bool, a, try in.variant(e, 1, &.{}))).eql(.boolean(true)));
    const m = try f.typeOf("Meters");
    const d = try in.cast(f.int(.int(.unsigned, 16), 7), m, .none);
    try testing.expectEqual(m, d.ty);
    try testing.expectError(error.IntegerOverflow, in.binary(.mul, m, d, .{ .ty = m, .data = .{ .scalar = 0x4000 } }));
}

test "vectors are lane-wise; aggregates, slices and str are bounds-checked" {
    var f: Fixture = undefined;
    try f.init(64, "enum Shape { dot, line(u16) }");
    defer f.deinit();
    const in = f.interp();
    const v3 = try f.types.intern(.{ .vec = .{ .len = 3, .elem = u8_t } });
    const m3 = try f.types.intern(.{ .mask = .{ .len = 3 } });
    const arr_t = try f.types.intern(.{ .array = .{ .len = 3, .elem = u8_t } });
    const slice_t = try f.types.intern(.{ .slice = .{ .elem = u8_t } });

    const x = try in.aggregate(v3, &.{ f.int(u8_t, 1), f.int(u8_t, 2), f.int(u8_t, 250) });
    const y = try in.splat(v3, f.int(u8_t, 6));
    try testing.expect((try in.binary(.add, v3, x, f.int(u8_t, 0))).eql(x));
    try testing.expectError(error.IntegerOverflow, in.binary(.add, v3, x, y)); // lane 2
    const lt = try in.binary(.lt, m3, x, y);
    try testing.expect(lt.eql(try in.aggregate(m3, &.{ .boolean(true), .boolean(true), .boolean(false) })));
    try testing.expect((try in.unary(.not, lt)).eql(try in.aggregate(m3, &.{ .boolean(false), .boolean(false), .boolean(true) })));
    try testing.expect((try in.swizzle(v3, x, &.{ 2, 0, 0 })).eql(try in.aggregate(v3, &.{ f.int(u8_t, 250), f.int(u8_t, 1), f.int(u8_t, 1) })));

    // Arrays: indexing and slicing trap out of bounds; the compact byte form
    // compares equal to the element form.
    const arr = try in.repeat(arr_t, f.int(u8_t, 9));
    const bytes: Value = .{ .ty = arr_t, .data = .{ .bytes = &.{ 9, 9, 9 } } };
    try testing.expect((try in.binary(.eq, .bool, arr, bytes)).eql(.boolean(true)));
    try testing.expect((try Interp.index(bytes, f.int(.usize, 2))).eql(f.int(u8_t, 9)));
    try testing.expectError(error.OutOfBounds, Interp.index(arr, f.int(.usize, 3)));
    const s = try in.slice(slice_t, bytes, f.int(.usize, 1), null);
    try testing.expectEqual(@as(u64, 2), Interp.len(s).data.scalar);
    try testing.expect((try in.coerce(arr, slice_t)).eql(try in.slice(slice_t, arr, null, null)));
    try testing.expectError(error.OutOfBounds, in.slice(slice_t, arr, f.int(.usize, 2), f.int(.usize, 1)));
    try testing.expectError(error.OutOfBounds, in.slice(slice_t, arr, null, f.int(.usize, 4)));
    try testing.expect(Interp.extract(arr, 1).eql(f.int(u8_t, 9)));

    // str: bytes, and slices on character boundaries only (§6.5.4).
    const str: Value = .{ .ty = .str, .data = .{ .str = "aé" } };
    try testing.expect((try Interp.index(str, f.int(.usize, 0))).eql(f.int(u8_t, 'a')));
    try testing.expectError(error.NotCharBoundary, in.slice(.str, str, null, f.int(.usize, 2)));
    try testing.expectEqualStrings("é", (try in.slice(.str, str, f.int(.usize, 1), null)).data.str);
    const ab: Value = .{ .ty = .str, .data = .{ .str = "ab" } };
    try testing.expect((try in.binary(.lt, .bool, str, ab)).eql(.boolean(false)));
    try testing.expect((try in.binary(.ne, .bool, str, ab)).eql(.boolean(true)));

    // Enums with payloads compare by variant and payload.
    const shape = try f.typeOf("Shape");
    const l1 = try in.variant(shape, 1, &.{f.int(.int(.unsigned, 16), 3)});
    const l2 = try in.variant(shape, 1, &.{f.int(.int(.unsigned, 16), 4)});
    try testing.expect((try in.binary(.eq, .bool, l1, l2)).eql(.boolean(false)));
    try testing.expect(in.enumTag(u8_t, l1).eql(f.int(u8_t, 1)));
}

test "a trap is a compile error carrying the comptime trace" {
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    const file: diag.FileId = @fromBackingInt(0);
    const trace = [_]diag.TraceFrame{
        .{ .span = .{ .file = file, .start = 40, .end = 48 }, .note = "in call to `grow`" },
        .{ .span = .{ .file = file, .start = 0, .end = 20 }, .note = "in the initializer of `N`" },
    };
    try report(&sink, error.IntegerOverflow, .{ .file = file, .start = 60, .end = 65 }, &trace);
    try testing.expect(sink.hasErrors());
    const ds = sink.finish();
    try testing.expectEqual(@as(usize, 1), ds.len);
    try testing.expectEqualStrings("comptime evaluation traps: integer overflow", ds[0].message);
    try testing.expectEqual(@as(u32, 60), ds[0].primarySpan().?.start);
    try testing.expectEqual(@as(usize, 2), ds[0].trace.len);
    try testing.expectEqualStrings("in call to `grow`", ds[0].trace[0].note);
}
