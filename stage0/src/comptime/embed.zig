//! Embedding comptime values in the program (§8.1, §8.3, §8.6).
//!
//! - `checkRuntime` is the E0802 rule: a comptime value that reaches runtime
//!   must be plain, `str`, or an array or slice of plain values, and must
//!   not hold a comptime-only value (`type`, `FnRef`, `FieldId<T>`).
//! - `encode` turns a value into an `Image`: the bytes of the constant in
//!   the target's layout (`sema/layout.zig`) and byte order, with
//!   `usize`/`isize` at the target width. A `str` or slice becomes a
//!   pointer-and-length pair whose pointer slot is a relocation to another
//!   blob holding the elements. `decode` reads an image back.
//! - `addGlobal` emits a blob as a read-only P-IR global (rodata).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Endian = std.builtin.Endian;
const Ast = @import("../ast/Ast.zig");
const Types = @import("../sema/types.zig");
const items_mod = @import("../sema/items.zig");
const kinds = @import("../sema/kinds.zig");
const layout = @import("../sema/layout.zig");
const convert = @import("../sema/convert.zig");
const ir = @import("../pir/ir.zig");
const ModuleId = @import("../resolve/module_graph.zig").ModuleId;
const Value = @import("value.zig").Value;

const Items = items_mod.Items;
const TypeId = Types.TypeId;
const Engine = layout.Engine;
const Layout = layout.Layout;
const Place = layout.Place;

/// `Unsupported`: the type has no layout here (`@packed`, `@c_layout` and
/// SoA types, T045) or holds pointers, which comptime cannot create (§8.6).
pub const Error = Allocator.Error || error{Unsupported};

/// A pointer-sized slot of a blob that holds the address of another blob.
pub const Reloc = struct {
    offset: u64,
    blob: u32,
};

/// The bytes of one constant object.
pub const Blob = struct {
    bytes: []u8,
    @"align": u32,
    relocs: []const Reloc = &.{},
};

/// An embedded value: `blobs[0]` is the value itself; the others hold the
/// elements of its strings and slices.
pub const Image = struct {
    blobs: []const Blob,
};

/// Whether a value of type `ty` may reach runtime (§8.6): plain, `str`, or
/// a slice of plain values (arrays of plain values are plain), holding no
/// comptime-only value (§8.3, §8.4).
pub fn embeddable(it: *Items, ty: TypeId) Allocator.Error!bool {
    const data = switch (it.types.get(ty)) {
        .simple => |s| if (s == .str or s == .err) return true else ty,
        .slice => |s| s.elem,
        else => ty,
    };
    if ((try kinds.kind(it, data)) != .plain) return false;
    var seen: std.AutoHashMapUnmanaged(TypeId, void) = .empty;
    defer seen.deinit(it.types.gpa);
    return !try comptimeOnly(it, &seen, data);
}

/// E0802 hook: a comptime value of type `ty` reaches runtime at token `tok`
/// of module `m`. Reports and returns false if it may not.
pub fn checkRuntime(it: *Items, m: ModuleId, tok: Ast.TokenIndex, ty: TypeId) Allocator.Error!bool {
    if (try embeddable(it, ty)) return true;
    try it.report(m, tok, .E0802, &.{"comptime values that reach runtime must be plain, `str`, or arrays or slices of plain values"}, "comptime-only value of type `{s}` reaches runtime", .{try it.tyName(ty)});
    return false;
}

/// Whether `ty` holds a comptime-only value by value or through a slice.
/// `seen` breaks cycles, which E0376 reports elsewhere.
fn comptimeOnly(it: *Items, seen: *std.AutoHashMapUnmanaged(TypeId, void), ty: TypeId) Allocator.Error!bool {
    if ((try seen.getOrPut(it.types.gpa, ty)).found_existing) return false;
    switch (it.types.get(ty)) {
        .simple => |s| return switch (s) {
            .type, .untyped_int, .untyped_float, .fn_ref => true,
            else => false,
        },
        .field_id => return true,
        inline .vec, .array, .soa_array, .slice, .soa_slice, .ptr, .mut_view => |x| return comptimeOnly(it, seen, x.elem),
        .tuple => |t| {
            for (t.elems) |e| if (try comptimeOnly(it, seen, e)) return true;
            return false;
        },
        .nominal => |n| {
            if (n.kind == .distinct) return comptimeOnly(it, seen, n.underlying);
            for (n.args) |a| if (a == .type and try comptimeOnly(it, seen, a.type)) return true;
            const ref = it.declRef(ty) orelse return false;
            switch ((try it.info(ref)).*) {
                .@"struct" => |s| for (s.fields) |f| {
                    if (try comptimeOnly(it, seen, try it.subst(f.type, n.decl, n.args))) return true;
                },
                .@"enum" => |e| for (e.variants) |v| for (v.payload) |p| {
                    if (try comptimeOnly(it, seen, try it.subst(p, n.decl, n.args))) return true;
                },
                else => {},
            }
            return false;
        },
        .int, .mask, .handle, .fn_ptr, .param => return false,
    }
}

/// Encodes `v` in the target layout of `e` (its `ptr_bits`) and byte order
/// `endian`. `v` must be embeddable (`checkRuntime`). The image lives in
/// `gpa`.
pub fn encode(gpa: Allocator, e: *Engine, endian: Endian, v: Value) Error!Image {
    var c: Codec = .{ .gpa = gpa, .e = e, .endian = endian };
    const l = try c.layoutOf(v.ty);
    const b = try c.newBlob(l.size, l.@"align");
    try c.write(b, 0, v);
    const blobs = try gpa.alloc(Blob, c.blobs.items.len);
    for (blobs, c.blobs.items) |*o, *w| o.* = .{ .bytes = w.bytes, .@"align" = w.@"align", .relocs = w.relocs.items };
    return .{ .blobs = blobs };
}

/// Reads back a value of type `ty` from an image made by `encode` with the
/// same engine and byte order. The value lives in `gpa`.
pub fn decode(gpa: Allocator, e: *Engine, endian: Endian, image: Image, ty: TypeId) Error!Value {
    var c: Codec = .{ .gpa = gpa, .e = e, .endian = endian, .image = image };
    return c.read(0, 0, ty);
}

/// Adds `blob` to `m` as the read-only global `@name`. P-IR initializers
/// have no relocations, so the blob must have none.
pub fn addGlobal(m: *ir.Module, name: []const u8, blob: Blob) Allocator.Error!void {
    // shortcut: relocated blobs (strings, slices) need P-IR relocations; T091 emits them.
    std.debug.assert(blob.relocs.len == 0);
    try m.addGlobal(.{ .name = name, .ty = .of(.i8), .init = .{ .bytes = blob.bytes }, .@"align" = blob.@"align", .readonly = true });
}

/// The shape of one variant of an enum with payloads.
const Variant = struct {
    payload: []const TypeId,
    tag_ty: TypeId,
    tag: u64,
};

const Codec = struct {
    gpa: Allocator,
    e: *Engine,
    endian: Endian,
    /// Encoding: the blobs built so far.
    blobs: std.ArrayList(WorkBlob) = .empty,
    /// Decoding: the image read.
    image: Image = .{ .blobs = &.{} },

    const WorkBlob = struct { bytes: []u8, @"align": u32, relocs: std.ArrayList(Reloc) = .empty };

    fn types(c: *Codec) *Types {
        return c.e.items.types;
    }

    fn ptrBytes(c: *Codec) u64 {
        return c.e.items.options.ptr_bits / 8;
    }

    fn layoutOf(c: *Codec, ty: TypeId) Error!Layout {
        return try c.e.layoutOf(ty) orelse error.Unsupported;
    }

    fn stride(c: *Codec, elem: TypeId) Error!u64 {
        const l = try c.layoutOf(elem);
        return std.mem.alignForward(u64, l.size, l.@"align");
    }

    fn newBlob(c: *Codec, size: u64, @"align": u32) Error!u32 {
        const bytes = try c.gpa.alloc(u8, size);
        @memset(bytes, 0);
        try c.blobs.append(c.gpa, .{ .bytes = bytes, .@"align" = @"align" });
        return @intCast(c.blobs.items.len - 1);
    }

    fn bytesOf(c: *Codec, b: u32) []u8 {
        return if (c.blobs.items.len > 0) c.blobs.items[b].bytes else c.image.blobs[b].bytes;
    }

    fn putInt(c: *Codec, b: u32, off: u64, size: u64, x: u64) void {
        const dst = c.bytesOf(b)[off..][0..size];
        for (0..size) |i| dst[if (c.endian == .little) i else size - 1 - i] = @truncate(x >> @intCast(8 * i));
    }

    fn getInt(c: *Codec, b: u32, off: u64, size: u64) u64 {
        const src = c.bytesOf(b)[off..][0..size];
        var x: u64 = 0;
        for (0..size) |i| x |= @as(u64, src[if (c.endian == .little) i else size - 1 - i]) << @intCast(8 * i);
        return x;
    }

    /// `raw` in the canonical scalar encoding of `ty` (value.zig).
    fn canon(c: *Codec, ty: TypeId, raw: u64) u64 {
        const info = convert.intInfo(c.types(), c.e.items.options.ptr_bits, ty) orelse return raw;
        return if (info.signedness == .signed)
            @bitCast(@as(i64, @bitCast(raw << @intCast(64 - info.bits))) >> @intCast(64 - info.bits))
        else
            raw & (~@as(u64, 0) >> @intCast(64 - info.bits));
    }

    /// The element type and count of a vector, mask or array type.
    fn elems(c: *Codec, ty: TypeId) ?struct { TypeId, u64 } {
        return switch (c.types().get(ty)) {
            .vec => |v| .{ v.elem, v.len },
            .mask => |m| .{ .bool, m.len },
            .array => |a| .{ a.elem, a.len },
            else => null,
        };
    }

    /// The field types of struct or tuple `ty`, in declaration order.
    fn fieldTypes(c: *Codec, ty: TypeId) Error![]const TypeId {
        const it = c.e.items;
        switch (c.types().get(ty)) {
            .tuple => |t| return t.elems,
            .nominal => |n| {
                const s = it.structOf(ty) orelse return error.Unsupported;
                const out = try c.gpa.alloc(TypeId, s.fields.len);
                for (s.fields, out) |f, *o| o.* = try it.subst(f.type, n.decl, n.args);
                return out;
            },
            else => unreachable,
        }
    }

    /// Variant `index` of enum-with-payloads `ty`, or null past the last.
    fn variant(c: *Codec, ty: TypeId, n: Types.Nominal, index: u32) Error!?Variant {
        const it = c.e.items;
        const u8_ty: TypeId = .int(.unsigned, 8);
        switch (n.lang) {
            .option => return switch (index) {
                0 => .{ .payload = try c.gpa.dupe(TypeId, &.{n.args[0].type}), .tag_ty = u8_ty, .tag = 0 },
                1 => .{ .payload = &.{}, .tag_ty = u8_ty, .tag = 1 },
                else => null,
            },
            .result => return if (index < 2) .{ .payload = try c.gpa.dupe(TypeId, &.{n.args[index].type}), .tag_ty = u8_ty, .tag = index } else null,
            else => {},
        }
        const en = it.enumOf(ty) orelse return error.Unsupported;
        if (index >= en.variants.len) return null;
        const v = en.variants[index];
        const tys = try c.gpa.alloc(TypeId, v.payload.len);
        for (v.payload, tys) |p, *o| o.* = try it.subst(p, n.decl, n.args);
        return .{ .payload = tys, .tag_ty = en.backing, .tag = v.discriminant.bits };
    }

    /// The layout of a variant payload: a tuple of its types (§4.11.4).
    fn payloadPlaces(c: *Codec, tys: []const TypeId) Error![]const Place {
        return switch (tys.len) {
            0 => &.{},
            1 => &.{.{ .offset = 0 }},
            else => (try c.layoutOf(try c.types().intern(.{ .tuple = .{ .elems = tys } }))).fields,
        };
    }

    /// The size in bytes of bit-field unit `unit` among `places` (§4.11.2).
    fn unitSize(places: []const Place, unit: u32) u64 {
        var bits: u32 = 0;
        for (places) |p| {
            if (p.unit == unit) bits = @max(bits, @as(u32, p.bit_offset) + p.width);
        }
        return if (bits <= 8) 1 else if (bits <= 16) 2 else if (bits <= 32) 4 else 8;
    }

    // -- encoding --

    fn write(c: *Codec, b: u32, off: u64, v: Value) Error!void {
        const ty = v.ty;
        if (c.elems(ty)) |el| {
            const st = try c.stride(el[0]);
            for (v.data.aggregate, 0..) |x, i| try c.write(b, off + i * st, x);
            return;
        }
        switch (c.types().get(ty)) {
            .simple => |s| switch (s) {
                .void, .noreturn => {},
                .str => try c.writeSlice(b, off, .int(.unsigned, 8), v.data.str.len, .{ .str = v.data.str }),
                else => c.putInt(b, off, (try c.layoutOf(ty)).size, v.data.scalar),
            },
            .int, .handle => c.putInt(b, off, (try c.layoutOf(ty)).size, v.data.scalar),
            .slice => |s| try c.writeSlice(b, off, s.elem, v.data.slice.len, .{ .values = v.data.slice }),
            .tuple => try c.writeRecord(b, off, (try c.layoutOf(ty)).fields, v.data.aggregate),
            .nominal => |n| {
                if (n.kind == .distinct) return c.write(b, off, .{ .ty = n.underlying, .data = v.data });
                if (v.data != .variant) {
                    if (n.kind == .@"enum") return c.putInt(b, off, (try c.layoutOf(ty)).size, v.data.scalar);
                    return c.writeRecord(b, off, (try c.layoutOf(ty)).fields, v.data.aggregate);
                }
                const l = try c.layoutOf(ty);
                const x = v.data.variant;
                if (l.handle_niche) {
                    if (x.index == 0) try c.write(b, off, x.payload[0]); // `.none` stays generation 0
                    return;
                }
                const shape = (try c.variant(ty, n, x.index)).?;
                try c.writeRecord(b, off + l.fields[0].offset, try c.payloadPlaces(shape.payload), x.payload);
                c.putInt(b, off + l.fields[1].offset, (try c.layoutOf(shape.tag_ty)).size, shape.tag);
            },
            else => return error.Unsupported,
        }
    }

    fn writeRecord(c: *Codec, b: u32, off: u64, places: []const Place, vs: []const Value) Error!void {
        for (places, vs) |p, x| {
            const unit = p.unit orelse {
                try c.write(b, off + p.offset, x);
                continue;
            };
            const size = unitSize(places, unit);
            const mask = (~@as(u64, 0)) >> @intCast(64 - @as(u32, p.width));
            c.putInt(b, off + p.offset, size, c.getInt(b, off + p.offset, size) | (x.data.scalar & mask) << @intCast(p.bit_offset));
        }
    }

    const Elems = union(enum) { str: []const u8, values: []const Value };

    /// A pointer slot at `off` relocated to a new blob of the elements,
    /// then the length.
    fn writeSlice(c: *Codec, b: u32, off: u64, elem: TypeId, len: u64, data: Elems) Error!void {
        const st = try c.stride(elem);
        const target = try c.newBlob(st * len, (try c.layoutOf(elem)).@"align");
        switch (data) {
            .str => |s| @memcpy(c.blobs.items[target].bytes, s),
            .values => |vs| for (vs, 0..) |x, i| try c.write(target, i * st, x),
        }
        try c.blobs.items[b].relocs.append(c.gpa, .{ .offset = off, .blob = target });
        c.putInt(b, off + c.ptrBytes(), c.ptrBytes(), len);
    }

    // -- decoding --

    fn read(c: *Codec, b: u32, off: u64, ty: TypeId) Error!Value {
        if (c.elems(ty)) |el| {
            const st = try c.stride(el[0]);
            const out = try c.gpa.alloc(Value, el[1]);
            for (out, 0..) |*o, i| o.* = try c.read(b, off + i * st, el[0]);
            return .{ .ty = ty, .data = .{ .aggregate = out } };
        }
        const data: Value.Data = switch (c.types().get(ty)) {
            .simple => |s| switch (s) {
                .void, .noreturn => .void,
                .str => .{ .str = try c.gpa.dupe(u8, c.bytesOf(try c.slot(b, off))[0..c.getInt(b, off + c.ptrBytes(), c.ptrBytes())]) },
                else => .{ .scalar = c.canon(ty, c.getInt(b, off, (try c.layoutOf(ty)).size)) },
            },
            .int, .handle => .{ .scalar = c.canon(ty, c.getInt(b, off, (try c.layoutOf(ty)).size)) },
            .slice => |s| blk: {
                const target = try c.slot(b, off);
                const st = try c.stride(s.elem);
                const out = try c.gpa.alloc(Value, c.getInt(b, off + c.ptrBytes(), c.ptrBytes()));
                for (out, 0..) |*o, i| o.* = try c.read(target, i * st, s.elem);
                break :blk .{ .slice = out };
            },
            .tuple => .{ .aggregate = try c.readRecord(b, off, (try c.layoutOf(ty)).fields, try c.fieldTypes(ty)) },
            .nominal => |n| blk: {
                if (n.kind == .distinct) break :blk (try c.read(b, off, n.underlying)).data;
                const l = try c.layoutOf(ty);
                if (n.kind == .@"struct") break :blk .{ .aggregate = try c.readRecord(b, off, l.fields, try c.fieldTypes(ty)) };
                if (l.handle_niche) {
                    const h = try c.read(b, off, n.args[0].type);
                    break :blk .{ .variant = if (h.data.scalar == 0) .{ .index = 1 } else .{ .index = 0, .payload = try c.gpa.dupe(Value, &.{h}) } };
                }
                if (l.fields.len == 0) { // payload-free enum: the discriminant
                    const backing = (c.e.items.enumOf(ty) orelse return error.Unsupported).backing;
                    break :blk .{ .scalar = c.canon(backing, c.getInt(b, off, l.size)) };
                }
                var i: u32 = 0;
                while (try c.variant(ty, n, i)) |shape| : (i += 1) {
                    const tag = c.canon(shape.tag_ty, c.getInt(b, off + l.fields[1].offset, (try c.layoutOf(shape.tag_ty)).size));
                    if (tag != shape.tag) continue;
                    const payload = try c.readRecord(b, off + l.fields[0].offset, try c.payloadPlaces(shape.payload), shape.payload);
                    break :blk .{ .variant = .{ .index = i, .payload = payload } };
                }
                return error.Unsupported; // no variant has this tag: not an image of `ty`
            },
            else => return error.Unsupported,
        };
        return .{ .ty = ty, .data = data };
    }

    fn readRecord(c: *Codec, b: u32, off: u64, places: []const Place, tys: []const TypeId) Error![]const Value {
        const out = try c.gpa.alloc(Value, tys.len);
        for (places, tys, out) |p, t, *o| {
            const unit = p.unit orelse {
                o.* = try c.read(b, off + p.offset, t);
                continue;
            };
            const raw = c.getInt(b, off + p.offset, unitSize(places, unit)) >> @intCast(p.bit_offset);
            o.* = .{ .ty = t, .data = .{ .scalar = c.canon(t, raw & (~@as(u64, 0)) >> @intCast(64 - @as(u32, p.width))) } };
        }
        return out;
    }

    /// The blob that the pointer slot at `off` of blob `b` points to.
    fn slot(c: *Codec, b: u32, off: u64) Error!u32 {
        for (c.image.blobs[b].relocs) |r| if (r.offset == off) return r.blob;
        return error.Unsupported;
    }
};

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const diag = @import("../diag/diag.zig");
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
    e: Engine,
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
        f.e = .init(testing.allocator, &f.items);
        f.arena = .init(testing.allocator);
    }

    fn deinit(f: *Fixture) void {
        f.arena.deinit();
        f.e.deinit();
        f.items.deinit();
        f.types.deinit();
        f.strings.deinit();
        f.names.deinit();
        f.im.deinit();
        f.g.deinit();
        f.p.deinit();
    }

    fn typeOf(f: *Fixture, name: []const u8) !TypeId {
        return switch ((try f.items.info(.{ .module = 0, .item = f.g.modules[0].names.get(name).? })).*) {
            .@"struct" => |s| s.type,
            .@"enum" => |en| en.type,
            else => unreachable,
        };
    }

    fn intern(f: *Fixture, key: Types.Key) !TypeId {
        return f.types.intern(key);
    }

    fn int(f: *Fixture, ty: TypeId, v: i128) Value {
        return Value.int(&f.types, f.items.options.ptr_bits, ty, v).?;
    }

    fn agg(f: *Fixture, ty: TypeId, vs: []const Value) !Value {
        return .{ .ty = ty, .data = .{ .aggregate = try f.arena.allocator().dupe(Value, vs) } };
    }

    /// Encodes `v`, checks it decodes to `v`, and returns the image.
    fn roundTrip(f: *Fixture, endian: Endian, v: Value) !Image {
        const a = f.arena.allocator();
        try testing.expect(try embeddable(&f.items, v.ty));
        const image = try encode(a, &f.e, endian, v);
        const back = try decode(a, &f.e, endian, image, v.ty);
        try testing.expect(back.eql(v));
        return image;
    }
};

test "round-trip ints, floats, structs, arrays, tuples and enums into globals" {
    var f: Fixture = undefined;
    try f.init(64,
        \\struct Inner { lo: u8, hi: u8 }
        \\enum Color { red, green, blue }
        \\enum Shape { dot, line(u16, bool), circle(f32) }
        \\struct S {
        \\    a: u8, b: f64, c: i16,
        \\    flag: bool, small: u3, neg: i5, color: Color,
        \\    arr: [3]u32, t: (u8, f32), x: usize, inner: Inner,
        \\    shape: Shape, v: vec<3, f32>,
        \\}
    );
    defer f.deinit();
    const u8_t: TypeId = .int(.unsigned, 8);
    const u16_t: TypeId = .int(.unsigned, 16);
    const u32_t: TypeId = .int(.unsigned, 32);
    const arr_t = try f.intern(.{ .array = .{ .len = 3, .elem = u32_t } });
    const tup_t = try f.intern(.{ .tuple = .{ .elems = &.{ u8_t, .f32 } } });
    const vec_t = try f.intern(.{ .vec = .{ .len = 3, .elem = .f32 } });
    const shape = try f.typeOf("Shape");
    const s_t = try f.typeOf("S");

    // Scalars and an array, with exact bytes in both byte orders.
    const arr = try f.agg(arr_t, &.{ f.int(u32_t, 1), f.int(u32_t, 0x0A0B0C0D), f.int(u32_t, 0xFFFF_FFFF) });
    try testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0, 0x0D, 0x0C, 0x0B, 0x0A, 0xFF, 0xFF, 0xFF, 0xFF }, (try f.roundTrip(.little, arr)).blobs[0].bytes);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 0x0A, 0x0B, 0x0C, 0x0D, 0xFF, 0xFF, 0xFF, 0xFF }, (try f.roundTrip(.big, arr)).blobs[0].bytes);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0xC0, 0x3F }, (try f.roundTrip(.little, .float(.f32, 1.5))).blobs[0].bytes);
    try testing.expectEqualSlices(u8, &.{ 0xFE, 0xFF }, (try f.roundTrip(.little, f.int(.int(.signed, 16), -2))).blobs[0].bytes);
    _ = try f.roundTrip(.little, .float(.f64, -0.0));
    _ = try f.roundTrip(.little, .{ .ty = .f64, .data = .{ .scalar = 0x7FF8_0000_0000_0001 } }); // NaN payload kept
    _ = try f.roundTrip(.little, .float(.f32, 1e-40)); // subnormal

    // A struct with bit fields, a nested struct, a tuple, a vector and enums.
    const inner = try f.agg(try f.typeOf("Inner"), &.{ f.int(u8_t, 7), f.int(u8_t, 9) });
    const line_payload = [_]Value{ f.int(u16_t, 300), .boolean(true) };
    const line: Value = .{ .ty = shape, .data = .{ .variant = .{ .index = 1, .payload = &line_payload } } };
    const fields = [_]Value{
        f.int(u8_t, 200),
        .float(.f64, -2.5),
        f.int(.int(.signed, 16), -1234),
        .boolean(true),
        f.int(.int(.unsigned, 3), 5),
        f.int(.int(.signed, 5), -16),
        .{ .ty = try f.typeOf("Color"), .data = .{ .scalar = 2 } },
        arr,
        try f.agg(tup_t, &.{ f.int(u8_t, 3), .float(.f32, 0.25) }),
        f.int(.usize, 1 << 40),
        inner,
        line,
        try f.agg(vec_t, &.{ .float(.f32, 1), .float(.f32, 2), .float(.f32, 3) }),
    };
    const s = try f.agg(s_t, &fields);
    for ([_]Endian{ .little, .big }) |endian| {
        const image = try f.roundTrip(endian, s);
        try testing.expectEqual(@as(usize, 1), image.blobs.len);
        try testing.expectEqual((try f.e.layoutOf(s_t)).?.size, image.blobs[0].bytes.len);
    }
    // The other variants of `Shape`.
    const circle_payload = [_]Value{.float(.f32, 9.5)};
    _ = try f.roundTrip(.little, .{ .ty = shape, .data = .{ .variant = .{ .index = 0 } } });
    _ = try f.roundTrip(.big, .{ .ty = shape, .data = .{ .variant = .{ .index = 2, .payload = &circle_payload } } });

    // Bit fields sit where the layout puts them: `flag`, `small`, `neg` and
    // `color` share one 2-byte unit (1 + 3 + 5 + 2 bits).
    const img = try encode(f.arena.allocator(), &f.e, .little, s);
    const pl = (try f.e.layoutOf(s_t)).?.fields;
    const unit = std.mem.readInt(u16, img.blobs[0].bytes[pl[3].offset..][0..2], .little);
    try testing.expectEqual(@as(u16, 1 | 5 << 1 | 0b10000 << 4 | 2 << 9), unit);

    // A global in P-IR holds the same bytes, and decodes back.
    var m = try ir.Module.init(testing.allocator);
    defer m.deinit();
    try addGlobal(&m, "S_CONST", img.blobs[0]);
    const g = m.findGlobal("S_CONST").?;
    try testing.expect(g.readonly);
    try testing.expectEqual((try f.e.layoutOf(s_t)).?.@"align", g.@"align");
    const blobs = [_]Blob{.{ .bytes = @constCast(g.init.bytes), .@"align" = g.@"align" }};
    try testing.expect((try decode(f.arena.allocator(), &f.e, .little, .{ .blobs = &blobs }, s_t)).eql(s));
}

test "usize width follows the target; str and slices relocate their elements" {
    for ([_]u8{ 32, 64 }) |bits| {
        var f: Fixture = undefined;
        try f.init(bits, "");
        defer f.deinit();
        const ptr = bits / 8;
        const max: i128 = (@as(i128, 1) << @intCast(bits)) - 1;
        try testing.expect(Value.int(&f.types, bits, .usize, max + 1) == null);
        const big = try f.roundTrip(.little, f.int(.usize, max));
        try testing.expectEqual(@as(usize, ptr), big.blobs[0].bytes.len);
        try testing.expect(std.mem.allEqual(u8, big.blobs[0].bytes, 0xFF));
        try testing.expectEqual(@as(usize, ptr), (try f.roundTrip(.big, f.int(.isize, -1))).blobs[0].bytes.len);

        const name = try f.roundTrip(.little, .{ .ty = .str, .data = .{ .str = "table" } });
        try testing.expectEqual(@as(usize, 2 * ptr), name.blobs[0].bytes.len);
        try testing.expectEqualSlices(Reloc, &.{.{ .offset = 0, .blob = 1 }}, name.blobs[0].relocs);
        try testing.expectEqual(@as(u8, 5), name.blobs[0].bytes[ptr]);
        try testing.expectEqualStrings("table", name.blobs[1].bytes);

        const u16_t: TypeId = .int(.unsigned, 16);
        const elems = [_]Value{ f.int(u16_t, 1), f.int(u16_t, 2), f.int(u16_t, 3) };
        const sl: Value = .{ .ty = try f.intern(.{ .slice = .{ .elem = u16_t } }), .data = .{ .slice = &elems } };
        const img = try f.roundTrip(.big, sl);
        try testing.expectEqualSlices(u8, &.{ 0, 1, 0, 2, 0, 3 }, img.blobs[1].bytes);
        try testing.expectEqual(@as(u32, 2), img.blobs[1].@"align");
    }
}

test "E0802: type, FnRef, FieldId and non-plain values do not reach runtime" {
    var f: Fixture = undefined;
    try f.init(64,
        \\struct P { x: f32, y: f32 }
        \\struct Named { name: str }
        \\@resource
        \\struct R { id: u32 }
    );
    defer f.deinit();
    const p = try f.typeOf("P");
    const yes = [_]TypeId{
        .str,
        .usize,
        p,
        try f.intern(.{ .array = .{ .len = 4, .elem = .int(.unsigned, 8) } }),
        try f.intern(.{ .slice = .{ .elem = p } }),
    };
    for (yes) |ty| try testing.expect(try checkRuntime(&f.items, 0, 0, ty));
    try testing.expectEqual(@as(usize, 0), f.p.sink.finish().len);
    const no = [_]TypeId{
        .type,
        .fn_ref,
        .untyped_int,
        try f.intern(.{ .field_id = .{ .owner = p } }),
        try f.intern(.{ .array = .{ .len = 2, .elem = .type } }),
        try f.intern(.{ .tuple = .{ .elems = &.{ .usize, .fn_ref } } }),
        try f.typeOf("Named"), // a view
        try f.typeOf("R"), // a resource
        try f.intern(.{ .slice = .{ .elem = .str } }),
        try f.intern(.{ .mut_view = .{ .elem = p } }),
    };
    for (no) |ty| try testing.expect(!try checkRuntime(&f.items, 0, 0, ty));
    const ds = f.p.sink.finish();
    try testing.expectEqual(no.len, ds.len);
    for (ds) |d| try testing.expectEqual(@as(?diag.DiagCode, .E0802), d.code);
}
