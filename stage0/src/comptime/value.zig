//! Comptime values (§8.1, §8.3, B.4): what the comptime interpreter computes
//! and what a comptime evaluation produces.
//!
//! Every value carries its `TypeId`. Scalars use the encoding of
//! `Types.Value`: an integer is two's complement, sign-extended to 64 bits
//! for a signed type and zero-extended for an unsigned one, at the type's
//! width on the target (`usize`/`isize` are `ptr_bits` wide, §8.6); a float
//! is its IEEE bits (an `f32` in the low 32); a `bool` is 0 or 1; a
//! payload-free enum is its discriminant. Aggregates hold their members as
//! values. Values of type `type`, `FnRef` and `FieldId<T>` exist only at
//! comptime (§8.3, §8.4); `embed.zig` keeps them from reaching runtime.
//!
//! Slices inside a value point into the allocator that built it, usually
//! the evaluation arena (`arena.zig`); `dupe` copies a value out of it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("../ast/Ast.zig");
const Types = @import("../sema/types.zig");
const convert = @import("../sema/convert.zig");
const ModuleId = @import("../resolve/module_graph.zig").ModuleId;

const TypeId = Types.TypeId;

/// A function as a comptime value (`std.meta.FnRef`, §8.4.1): its
/// `fn_decl` node, which also identifies methods.
pub const FnRef = struct {
    module: ModuleId,
    node: Ast.Node.Index,
};

/// A comptime value of type `ty`.
pub const Value = struct {
    ty: TypeId,
    data: Data,

    pub const Data = union(enum) {
        /// `void`, and other zero-sized values with no members.
        void,
        /// Integers, `bool`, floats, payload-free enums and handles, in the
        /// encoding of `Types.Value` (see the file comment).
        scalar: u64,
        /// The UTF-8 bytes of a `str`.
        str: []const u8,
        /// A value of type `type` (§8.3).
        type: TypeId,
        /// A value of type `FnRef` (§8.4.1).
        fn_ref: FnRef,
        /// A value of type `FieldId<T>` (§8.4.2): the field's index in
        /// declaration order.
        field_id: u32,
        /// Struct fields in declaration order, tuple elements, array
        /// elements, or vector and mask lanes.
        aggregate: []const Value,
        /// An enum with payloads, `Option<T>` or `Result<T, E>`.
        variant: Variant,
        /// The elements of a slice value.
        slice: []const Value,
    };

    /// A variant of an enum with payloads: its index in declaration order
    /// (`Option`: `some` 0, `none` 1; `Result`: `ok` 0, `err` 1) and its
    /// payload values.
    pub const Variant = struct {
        index: u32,
        payload: []const Value = &.{},
    };

    /// Integer `v` of integer type `ty` (`usize`/`isize` are `ptr_bits`
    /// wide), or null if it does not fit. Asserts `ty` is an integer type.
    pub fn int(types: *Types, ptr_bits: u8, ty: TypeId, v: i128) ?Value {
        const info = convert.intInfo(types, ptr_bits, ty).?;
        const min: i128 = if (info.signedness == .signed) -(@as(i128, 1) << @intCast(info.bits - 1)) else 0;
        const max: i128 = (@as(i128, 1) << @intCast(info.bits - @intFromBool(info.signedness == .signed))) - 1;
        if (v < min or v > max) return null;
        return .{ .ty = ty, .data = .{ .scalar = @bitCast(@as(i64, @truncate(v))) } };
    }

    /// The integer held by `v`, of integer type `v.ty`.
    pub fn toInt(v: Value, types: *Types, ptr_bits: u8) i128 {
        const info = convert.intInfo(types, ptr_bits, v.ty).?;
        return if (info.signedness == .signed) @as(i64, @bitCast(v.data.scalar)) else @as(i128, v.data.scalar);
    }

    /// Float `x` of type `ty` (`f32` or `f64`); an `f32` is rounded to
    /// nearest even.
    pub fn float(ty: TypeId, x: f64) Value {
        const bits: u64 = switch (ty) {
            .f32 => @as(u32, @bitCast(@as(f32, @floatCast(x)))),
            .f64 => @bitCast(x),
            else => unreachable,
        };
        return .{ .ty = ty, .data = .{ .scalar = bits } };
    }

    /// The float held by `v`, of type `f32` or `f64`.
    pub fn toFloat(v: Value) f64 {
        return switch (v.ty) {
            .f32 => @as(f32, @bitCast(@as(u32, @truncate(v.data.scalar)))),
            .f64 => @bitCast(v.data.scalar),
            else => unreachable,
        };
    }

    /// A `bool`.
    pub fn boolean(b: bool) Value {
        return .{ .ty = .bool, .data = .{ .scalar = @intFromBool(b) } };
    }

    /// A deep copy of `v` whose slices live in `gpa`.
    pub fn dupe(v: Value, gpa: Allocator) Allocator.Error!Value {
        return .{ .ty = v.ty, .data = switch (v.data) {
            .str => |s| .{ .str = try gpa.dupe(u8, s) },
            .aggregate => |vs| .{ .aggregate = try dupeAll(gpa, vs) },
            .slice => |vs| .{ .slice = try dupeAll(gpa, vs) },
            .variant => |x| .{ .variant = .{ .index = x.index, .payload = try dupeAll(gpa, x.payload) } },
            else => v.data,
        } };
    }

    /// Structural equality: equal types and equal members.
    pub fn eql(a: Value, b: Value) bool {
        if (a.ty != b.ty or std.meta.activeTag(a.data) != std.meta.activeTag(b.data)) return false;
        return switch (a.data) {
            .str => |s| std.mem.eql(u8, s, b.data.str),
            .aggregate => |vs| eqlAll(vs, b.data.aggregate),
            .slice => |vs| eqlAll(vs, b.data.slice),
            .variant => |x| x.index == b.data.variant.index and eqlAll(x.payload, b.data.variant.payload),
            inline else => |x, tag| std.meta.eql(x, @field(b.data, @tagName(tag))),
        };
    }
};

fn dupeAll(gpa: Allocator, vs: []const Value) Allocator.Error![]const Value {
    const out = try gpa.alloc(Value, vs.len);
    for (vs, out) |v, *o| o.* = try v.dupe(gpa);
    return out;
}

fn eqlAll(a: []const Value, b: []const Value) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!x.eql(y)) return false;
    return true;
}

const testing = std.testing;
const Interner = @import("../base/Interner.zig");

test "integers follow the target width of usize and isize" {
    var strings: Interner = .init(testing.allocator, testing.io);
    defer strings.deinit();
    var types: Types = try .init(testing.allocator, testing.io, &strings);
    defer types.deinit();

    try testing.expect(Value.int(&types, 32, .usize, 1 << 32) == null);
    try testing.expectEqual(@as(i128, 1 << 32), Value.int(&types, 64, .usize, 1 << 32).?.toInt(&types, 64));
    try testing.expect(Value.int(&types, 32, .isize, -(1 << 31) - 1) == null);
    const m = Value.int(&types, 32, .isize, -(1 << 31)).?;
    try testing.expectEqual(@as(u64, 0xFFFF_FFFF_8000_0000), m.data.scalar);
    try testing.expectEqual(@as(i128, -(1 << 31)), m.toInt(&types, 32));
    try testing.expect(Value.int(&types, 64, .int(.unsigned, 3), 8) == null);
    try testing.expectEqual(@as(i128, std.math.maxInt(u64)), Value.int(&types, 64, .int(.unsigned, 64), std.math.maxInt(u64)).?.toInt(&types, 64));
}

test "floats keep their IEEE bits; dupe and eql are deep" {
    try testing.expectEqual(@as(u64, 0x3FC0_0000), Value.float(.f32, 1.5).data.scalar);
    try testing.expectEqual(@as(f64, 1.5), Value.float(.f64, 1.5).toFloat());
    try testing.expect(std.math.isNan(Value.float(.f32, std.math.nan(f64)).toFloat()));

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const elems = [_]Value{ .boolean(true), .{ .ty = .str, .data = .{ .str = "hi" } } };
    const v: Value = .{ .ty = .void, .data = .{ .aggregate = &elems } };
    const copy = try v.dupe(arena.allocator());
    try testing.expect(copy.eql(v));
    try testing.expect(copy.data.aggregate.ptr != v.data.aggregate.ptr);
    try testing.expect(!copy.eql(.{ .ty = .void, .data = .{ .aggregate = elems[0..1] } }));
}
