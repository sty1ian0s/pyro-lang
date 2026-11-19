//! Global type table (§4, B.4): every type is interned to a `TypeId`, so
//! type equality (§4.10) is `TypeId` equality.
//!
//! - Primitive and comptime-only scalar types have fixed ids (`TypeId.bool`,
//!   `TypeId.int(.unsigned, 8)`), available without the table.
//! - Structural types (arrays, slices, SoA, tuples, vectors, masks, handles,
//!   pointers, function pointers, `mut` views, `FieldId<T>`) are hash-consed:
//!   equal components give the same id.
//! - Nominal types (structs, enums, protocols, distinct types, §4.10) are
//!   keyed by declaration (package name and semver-compatible line, §13.4,
//!   plus a declaration index) and instantiation arguments (§7.6). Two
//!   declarations with the same body are different types; equal generic
//!   arguments give the same instance.
//! - Aliases (`type Name = T`, §4.7) have no entry: resolving `Name` yields
//!   the id of `T`. Prelude aliases such as `vec3<T>` work the same way.
//! - Standard-library types the compiler must recognise (`Option`, `Atomic`,
//!   the GPU binding and GPU-local types of §11.1) are ordinary nominal types
//!   tagged with a `Lang` item.
//!
//! The table is thread-safe. Ids are assigned in first-intern order, which is
//! not deterministic under parallel checking: never sort or hash output by
//! id; use `print` (or the keys) instead.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Arena = @import("../base/Arena.zig");
const Interner = @import("../base/Interner.zig");
const CompatLine = @import("../pkg/semver.zig").CompatLine;

const Types = @This();

/// Interned type: index into the table. Equal types have equal ids.
pub const TypeId = enum(u32) {
    void,
    noreturn,
    bool,
    isize,
    usize,
    f32,
    f64,
    str,
    /// The type of types (§8.3); comptime-only.
    type,
    /// Untyped integer constant (§4.8); comptime-only.
    untyped_int,
    /// Untyped float constant (§4.8); comptime-only.
    untyped_float,
    /// `std.meta.FnRef` (§8.4.1); comptime-only.
    fn_ref,
    /// Type of an expression that failed to check. Diagnostics involving it
    /// are cascades and should be dropped.
    err,
    /// "No type" sentinel, for optional ids. Never interned.
    none = std.math.maxInt(u32),
    _,

    const first_int: u32 = @backingInt(TypeId.err) + 1;
    const first_interned: u32 = first_int + 128;

    /// The fixed id of `uN` / `iN` (§4.2.2). Asserts `1 <= bits <= 64`.
    pub fn int(signedness: std.builtin.Signedness, bits: u8) TypeId {
        std.debug.assert(bits >= 1 and bits <= 64);
        const base: u32 = if (signedness == .signed) first_int + 64 else first_int;
        return @fromBackingInt(base + bits - 1);
    }
};

/// Package identity for nominal keys (§13.4): incompatible lines of one
/// package coexist, and their types are distinct.
pub const Package = struct {
    name: Interner.Id,
    line: CompatLine,
};

/// Identity of a type-producing declaration: a struct, enum, protocol or
/// distinct-type declaration, an anonymous `struct` expression, or a
/// comptime type function. `index` is assigned by the item collector and is
/// unique within the package.
pub const Decl = struct {
    package: Package,
    index: u32,
};

/// A comptime value used as a generic argument (`Ring<u32, 64>`). Integers,
/// `bool` and enum discriminants are stored in `bits` (signed values
/// two's complement). Other comptime values store a canonical id from the
/// comptime value table, so equal values have equal `bits`.
pub const Value = struct {
    type: TypeId,
    bits: u64,
};

/// A generic argument (§7.6.1): a type or a comptime value.
pub const Arg = union(enum) {
    type: TypeId,
    value: Value,
};

/// Parameter mode in a function-pointer type (§3.6 `fn_type_param`).
pub const Mode = enum(u8) { value, mut, move };

/// One parameter of a function-pointer type.
pub const FnParam = struct {
    type: TypeId,
    mode: Mode = .value,
};

/// Standard-library declarations the compiler gives meaning to.
pub const Lang = enum(u8) {
    none,
    option,
    result,
    atomic,
    channel,
    // GPU binding resources (§11.1.2).
    texture_2d,
    texture_3d,
    texture_cube,
    texture_2d_array,
    depth_texture_2d,
    storage_texture_2d,
    sampler,
    tlas,
    // GPU-local types (§11.1.3).
    ray_query,
    mesh_out,
};

pub const NominalKind = enum(u8) { @"struct", @"enum", protocol, distinct };

/// A nominal type. Only `decl` and `args` identify it; the other fields
/// describe the declaration and must be the same on every intern of it.
pub const Nominal = struct {
    decl: Decl,
    /// Instantiation arguments; empty for a non-generic declaration.
    args: []const Arg = &.{},
    kind: NominalKind,
    /// Declared name, used by `print`.
    name: Interner.Id,
    lang: Lang = .none,
    /// For `.distinct`: the type it wraps (§4.7). `.none` otherwise.
    underlying: TypeId = .none,
};

/// A generic type parameter (or protocol `Self`) of declaration `owner`, as
/// seen while checking signatures before instantiation (§7.6). Only `owner`
/// and `index` identify it.
pub const Param = struct {
    owner: Decl,
    index: u32,
    name: Interner.Id,
};

/// The structure of a type. Slices point into the table and stay valid
/// until `deinit`.
pub const Key = union(enum) {
    /// The fixed ids `void` .. `err`.
    simple: TypeId,
    /// `uN` / `iN`.
    int: struct { signedness: std.builtin.Signedness, bits: u8 },
    /// `vec<N, T>` (§4.3.1).
    vec: struct { len: u32, elem: TypeId },
    /// `mask<N>` (§4.3.2).
    mask: struct { len: u32 },
    /// `[N]T` (§4.4.1).
    array: struct { len: u64, elem: TypeId },
    /// `soa [N]T` (§4.4.2).
    soa_array: struct { len: u64, elem: TypeId },
    /// `[]T` (§4.5.1).
    slice: struct { elem: TypeId },
    /// `soa []T` (§4.5.2).
    soa_slice: struct { elem: TypeId },
    /// `(A, B, ...)`, two or more elements (§4.4.3).
    tuple: struct { elems: []const TypeId },
    /// `Handle<T>` (§4.4.5).
    handle: struct { elem: TypeId },
    /// `*T` / `*const T` (§4.6).
    ptr: struct { elem: TypeId, is_const: bool },
    /// `fn(A, B) -> R` (§4.6); `ret` is `.void` when `-> R` is omitted.
    fn_ptr: struct { params: []const FnParam, ret: TypeId },
    /// `mut T` view (§4.5.3).
    mut_view: struct { elem: TypeId },
    /// `FieldId<T>` (§8.4); comptime-only.
    field_id: struct { owner: TypeId },
    nominal: Nominal,
    param: Param,
};

gpa: Allocator,
io: Io,
strings: *Interner,
lock: Io.RwLock = .init,
/// `keys[id]` is the structure of type `id`.
keys: std.ArrayList(Key) = .empty,
map: std.HashMapUnmanaged(Key, TypeId, KeyContext, std.hash_map.default_max_load_percentage) = .empty,
/// Owns the slices of interned keys; they never move.
data: Arena,

/// Creates a table holding the fixed ids. `strings` resolves names for
/// `print`. `gpa` must be thread-safe if other threads use it concurrently.
pub fn init(gpa: Allocator, io: Io, strings: *Interner) Allocator.Error!Types {
    var t: Types = .{ .gpa = gpa, .io = io, .strings = strings, .data = .init(gpa) };
    errdefer t.deinit();
    try t.keys.ensureTotalCapacity(gpa, TypeId.first_interned);
    for (0..TypeId.first_int) |i| t.keys.appendAssumeCapacity(.{ .simple = @fromBackingInt(@as(u32, @intCast(i))) });
    for ([_]std.builtin.Signedness{ .unsigned, .signed }) |s| {
        for (1..65) |b| t.keys.appendAssumeCapacity(.{ .int = .{ .signedness = s, .bits = @intCast(b) } });
    }
    return t;
}

pub fn deinit(t: *Types) void {
    t.map.deinit(t.gpa);
    t.keys.deinit(t.gpa);
    t.data.deinit();
    t.* = undefined;
}

/// Returns the id of the type `key` describes, adding it if new. The key's
/// slices are copied. For `.simple` and `.int` returns the fixed id.
/// Thread-safe.
pub fn intern(t: *Types, key: Key) Allocator.Error!TypeId {
    switch (key) {
        .simple => |id| return id,
        .int => |i| return .int(i.signedness, i.bits),
        else => {},
    }
    {
        t.lock.lockSharedUncancelable(t.io);
        defer t.lock.unlockShared(t.io);
        if (t.map.get(key)) |id| return id;
    }
    t.lock.lockUncancelable(t.io);
    defer t.lock.unlock(t.io);
    try t.keys.ensureUnusedCapacity(t.gpa, 1);
    const gop = try t.map.getOrPut(t.gpa, key);
    if (gop.found_existing) return gop.value_ptr.*; // another thread won the race
    const copy = t.dupe(key) catch |err| {
        t.map.removeByPtr(gop.key_ptr);
        return err;
    };
    const id: TypeId = @fromBackingInt(@as(u32, @intCast(t.keys.items.len)));
    gop.key_ptr.* = copy;
    gop.value_ptr.* = id;
    t.keys.appendAssumeCapacity(copy);
    return id;
}

/// Returns the structure of `id`. Thread-safe.
pub fn get(t: *Types, id: TypeId) Key {
    t.lock.lockSharedUncancelable(t.io);
    defer t.lock.unlockShared(t.io);
    return t.keys.items[@backingInt(id)];
}

/// Number of types in the table, fixed ids included. Thread-safe.
pub fn count(t: *Types) u32 {
    t.lock.lockSharedUncancelable(t.io);
    defer t.lock.unlockShared(t.io);
    return @intCast(t.keys.items.len);
}

/// Copies the slices of `key` into the table's arena. Caller holds the lock.
fn dupe(t: *Types, key: Key) Allocator.Error!Key {
    const a = t.data.allocator();
    var k = key;
    switch (k) {
        .tuple => |*x| x.elems = try a.dupe(TypeId, x.elems),
        .fn_ptr => |*x| x.params = try a.dupe(FnParam, x.params),
        .nominal => |*x| x.args = try a.dupe(Arg, x.args),
        else => {},
    }
    return k;
}

/// Hashes and compares keys by identity: nominal types and parameters by
/// declaration (and arguments), everything else by full structure.
const KeyContext = struct {
    pub fn hash(_: KeyContext, key: Key) u64 {
        var h: std.hash.Wyhash = .init(0);
        std.hash.autoHash(&h, std.meta.activeTag(key));
        switch (key) {
            .nominal => |n| {
                std.hash.autoHash(&h, n.decl);
                std.hash.autoHashStrat(&h, n.args, .Deep);
            },
            .param => |p| {
                std.hash.autoHash(&h, p.owner);
                std.hash.autoHash(&h, p.index);
            },
            inline else => |x| std.hash.autoHashStrat(&h, x, .Deep),
        }
        return h.final();
    }

    pub fn eql(_: KeyContext, a: Key, b: Key) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .tuple => |x| std.mem.eql(TypeId, x.elems, b.tuple.elems),
            .fn_ptr => |x| x.ret == b.fn_ptr.ret and x.params.len == b.fn_ptr.params.len and
                for (x.params, b.fn_ptr.params) |p, q| {
                    if (!std.meta.eql(p, q)) break false;
                } else true,
            .nominal => |x| std.meta.eql(x.decl, b.nominal.decl) and x.args.len == b.nominal.args.len and
                for (x.args, b.nominal.args) |p, q| {
                    if (!std.meta.eql(p, q)) break false;
                } else true,
            .param => |x| std.meta.eql(x.owner, b.param.owner) and x.index == b.param.index,
            inline else => |x, tag| std.meta.eql(x, @field(b, @tagName(tag))),
        };
    }
};

/// Print options for `print`.
pub const PrintOptions = struct {
    /// Prefix nominal names with their package and line (`geom@2.Vec3`), for
    /// diagnostics that mix two lines of one package (§13.4).
    qualified: bool = false,
};

/// Writes `id` in source spelling (`[4]u8`, `vec<3, f32>`, `*const T`,
/// `fn(mut A, B) -> R`, `Ring<u32, 64>`). Thread-safe.
pub fn print(t: *Types, w: *Writer, id: TypeId, opts: PrintOptions) Writer.Error!void {
    switch (t.get(id)) {
        .simple => |s| try w.writeAll(switch (s) {
            .untyped_int => "untyped integer",
            .untyped_float => "untyped float",
            .fn_ref => "FnRef",
            .err => "{error}",
            else => @tagName(s),
        }),
        .int => |i| try w.print("{c}{d}", .{ @as(u8, if (i.signedness == .signed) 'i' else 'u'), i.bits }),
        .vec => |v| {
            try w.print("vec<{d}, ", .{v.len});
            try t.print(w, v.elem, opts);
            try w.writeByte('>');
        },
        .mask => |m| try w.print("mask<{d}>", .{m.len}),
        .array => |a| {
            try w.print("[{d}]", .{a.len});
            try t.print(w, a.elem, opts);
        },
        .soa_array => |a| {
            try w.print("soa [{d}]", .{a.len});
            try t.print(w, a.elem, opts);
        },
        .slice => |s| {
            try w.writeAll("[]");
            try t.print(w, s.elem, opts);
        },
        .soa_slice => |s| {
            try w.writeAll("soa []");
            try t.print(w, s.elem, opts);
        },
        .tuple => |tu| {
            try w.writeByte('(');
            for (tu.elems, 0..) |e, i| {
                if (i > 0) try w.writeAll(", ");
                try t.print(w, e, opts);
            }
            try w.writeByte(')');
        },
        .handle => |h| {
            try w.writeAll("Handle<");
            try t.print(w, h.elem, opts);
            try w.writeByte('>');
        },
        .ptr => |p| {
            try w.writeAll(if (p.is_const) "*const " else "*");
            try t.print(w, p.elem, opts);
        },
        .fn_ptr => |f| {
            try w.writeAll("fn(");
            for (f.params, 0..) |p, i| {
                if (i > 0) try w.writeAll(", ");
                if (p.mode != .value) try w.print("{t} ", .{p.mode});
                try t.print(w, p.type, opts);
            }
            try w.writeByte(')');
            if (f.ret != .void) {
                try w.writeAll(" -> ");
                try t.print(w, f.ret, opts);
            }
        },
        .mut_view => |m| {
            try w.writeAll("mut ");
            try t.print(w, m.elem, opts);
        },
        .field_id => |f| {
            try w.writeAll("FieldId<");
            try t.print(w, f.owner, opts);
            try w.writeByte('>');
        },
        .nominal => |n| {
            if (opts.qualified) {
                const l = n.decl.package.line;
                try w.print("{s}@{d}", .{ t.strings.get(n.decl.package.name), l.major });
                if (l.major == 0) try w.print(".{d}", .{l.minor});
                try w.writeByte('.');
            }
            try w.writeAll(t.strings.get(n.name));
            if (n.args.len == 0) return;
            try w.writeByte('<');
            for (n.args, 0..) |arg, i| {
                if (i > 0) try w.writeAll(", ");
                switch (arg) {
                    .type => |ty| try t.print(w, ty, opts),
                    .value => |v| try t.printValue(w, v),
                }
            }
            try w.writeByte('>');
        },
        .param => |p| try w.writeAll(t.strings.get(p.name)),
    }
}

fn printValue(t: *Types, w: *Writer, v: Value) Writer.Error!void {
    if (v.type == .bool) return w.writeAll(if (v.bits != 0) "true" else "false");
    const signed = v.type == .isize or v.type == .untyped_int or switch (t.get(v.type)) {
        .int => |i| i.signedness == .signed,
        else => false,
    };
    // shortcut: non-integer values print their raw bits; print through the comptime value table once it exists.
    if (signed) try w.print("{d}", .{@as(i64, @bitCast(v.bits))}) else try w.print("{d}", .{v.bits});
}

/// Returns `id` printed into memory owned by `gpa`.
pub fn allocPrint(t: *Types, gpa: Allocator, id: TypeId, opts: PrintOptions) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    t.print(&out.writer, id, opts) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

const testing = std.testing;

const Fixture = struct {
    strings: Interner,
    types: Types,

    fn init(f: *Fixture) !void {
        f.strings = .init(testing.allocator, testing.io);
        f.types = try .init(testing.allocator, testing.io, &f.strings);
    }

    fn deinit(f: *Fixture) void {
        f.types.deinit();
        f.strings.deinit();
    }

    fn expectPrint(f: *Fixture, expected: []const u8, id: TypeId, opts: PrintOptions) !void {
        const s = try f.types.allocPrint(testing.allocator, id, opts);
        defer testing.allocator.free(s);
        try testing.expectEqualStrings(expected, s);
    }

    fn pkg(f: *Fixture, name: []const u8, major: u64) !Package {
        return .{ .name = try f.strings.intern(name), .line = .{ .major = major } };
    }
};

test "structural types are hash-consed: [4]u8 == [4]u8" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const t = &f.types;
    const u8_ = TypeId.int(.unsigned, 8);
    const a = try t.intern(.{ .array = .{ .len = 4, .elem = u8_ } });
    try testing.expectEqual(a, try t.intern(.{ .array = .{ .len = 4, .elem = u8_ } }));
    try testing.expect(a != try t.intern(.{ .array = .{ .len = 5, .elem = u8_ } }));
    try testing.expect(a != try t.intern(.{ .soa_array = .{ .len = 4, .elem = u8_ } }));

    var elems = [_]TypeId{ u8_, .f32 };
    const tup = try t.intern(.{ .tuple = .{ .elems = &elems } });
    elems[0] = .bool; // the table keeps its own copy
    try testing.expectEqual(tup, try t.intern(.{ .tuple = .{ .elems = &.{ u8_, .f32 } } }));
    try testing.expect(tup != try t.intern(.{ .tuple = .{ .elems = &elems } }));

    const p: []const FnParam = &.{ .{ .type = u8_, .mode = .mut }, .{ .type = .f32 } };
    const fp = try t.intern(.{ .fn_ptr = .{ .params = p, .ret = .void } });
    try testing.expectEqual(fp, try t.intern(.{ .fn_ptr = .{ .params = &.{ .{ .type = u8_, .mode = .mut }, .{ .type = .f32 } }, .ret = .void } }));
    try testing.expect(fp != try t.intern(.{ .fn_ptr = .{ .params = &.{ .{ .type = u8_ }, .{ .type = .f32 } }, .ret = .void } }));

    try testing.expect(try t.intern(.{ .ptr = .{ .elem = u8_, .is_const = true } }) !=
        try t.intern(.{ .ptr = .{ .elem = u8_, .is_const = false } }));
    try testing.expectEqual(t.get(a).array.len, 4);
}

test "primitive ids: usize != u64, fixed ints round-trip" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const t = &f.types;
    try testing.expect(TypeId.usize != TypeId.int(.unsigned, 64));
    try testing.expect(TypeId.isize != TypeId.int(.signed, 64));
    try testing.expect(TypeId.int(.unsigned, 7) != TypeId.int(.signed, 7));
    try testing.expectEqual(TypeId.int(.signed, 64), try t.intern(.{ .int = .{ .signedness = .signed, .bits = 64 } }));
    try testing.expectEqual(TypeId.f64, try t.intern(.{ .simple = .f64 }));
    for ([_]std.builtin.Signedness{ .unsigned, .signed }) |s| for (1..65) |b| {
        const k = t.get(.int(s, @intCast(b))).int;
        try testing.expectEqual(s, k.signedness);
        try testing.expectEqual(b, k.bits);
    };
    try testing.expectEqual(TypeId.first_interned, t.count());
}

test "nominal: identical decls differ, distinct != underlying, alias == T" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const t = &f.types;
    const app = try f.pkg("app", 1);

    // struct A { x: u8 } and struct B { x: u8 }: two declarations, two types.
    const a = try t.intern(.{ .nominal = .{ .decl = .{ .package = app, .index = 0 }, .kind = .@"struct", .name = try f.strings.intern("A") } });
    const b = try t.intern(.{ .nominal = .{ .decl = .{ .package = app, .index = 1 }, .kind = .@"struct", .name = try f.strings.intern("B") } });
    try testing.expect(a != b);
    try testing.expectEqual(a, try t.intern(.{ .nominal = .{ .decl = .{ .package = app, .index = 0 }, .kind = .@"struct", .name = try f.strings.intern("A") } }));

    // type Meters = distinct f32;
    const meters = try t.intern(.{ .nominal = .{
        .decl = .{ .package = app, .index = 2 },
        .kind = .distinct,
        .name = try f.strings.intern("Meters"),
        .underlying = .f32,
    } });
    try testing.expect(meters != TypeId.f32);
    try testing.expectEqual(TypeId.f32, t.get(meters).nominal.underlying);

    // type Bytes = [4]u8; aliases have no entry, so the alias is [4]u8 itself.
    const before = t.count();
    const arr: Key = .{ .array = .{ .len = 4, .elem = .int(.unsigned, 8) } };
    const bytes = try t.intern(arr);
    try testing.expectEqual(bytes, try t.intern(arr));
    try testing.expectEqual(before + 1, t.count());
}

test "generic instances: G<A> == G<A>, args and package lines distinguish" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const t = &f.types;
    const geom1 = try f.pkg("geom", 1);
    const ring_name = try f.strings.intern("Ring");
    const ring = Decl{ .package = geom1, .index = 7 };

    const r1 = try t.intern(.{ .nominal = .{ .decl = ring, .args = &.{ .{ .type = .int(.unsigned, 32) }, .{ .value = .{ .type = .usize, .bits = 64 } } }, .kind = .@"struct", .name = ring_name } });
    const r2 = try t.intern(.{ .nominal = .{ .decl = ring, .args = &.{ .{ .type = .int(.unsigned, 32) }, .{ .value = .{ .type = .usize, .bits = 64 } } }, .kind = .@"struct", .name = ring_name } });
    try testing.expectEqual(r1, r2);
    const r3 = try t.intern(.{ .nominal = .{ .decl = ring, .args = &.{ .{ .type = .int(.unsigned, 32) }, .{ .value = .{ .type = .usize, .bits = 128 } } }, .kind = .@"struct", .name = ring_name } });
    const r4 = try t.intern(.{ .nominal = .{ .decl = ring, .args = &.{ .{ .type = .usize }, .{ .value = .{ .type = .usize, .bits = 64 } } }, .kind = .@"struct", .name = ring_name } });
    try testing.expect(r1 != r3 and r1 != r4);

    // The same declaration from two incompatible lines of a package (§13.4).
    const vec_name = try f.strings.intern("Vec3");
    const v1 = try t.intern(.{ .nominal = .{ .decl = .{ .package = geom1, .index = 3 }, .kind = .@"struct", .name = vec_name } });
    const v2 = try t.intern(.{ .nominal = .{ .decl = .{ .package = try f.pkg("geom", 2), .index = 3 }, .kind = .@"struct", .name = vec_name } });
    try testing.expect(v1 != v2);
    try f.expectPrint("Vec3", v1, .{});
    try f.expectPrint("geom@1.Vec3", v1, .{ .qualified = true });
    try f.expectPrint("geom@2.Vec3", v2, .{ .qualified = true });
    const v0 = try t.intern(.{ .nominal = .{ .decl = .{ .package = .{ .name = geom1.name, .line = .{ .major = 0, .minor = 3 } }, .index = 3 }, .kind = .@"struct", .name = vec_name } });
    try f.expectPrint("geom@0.3.Vec3", v0, .{ .qualified = true });
    try f.expectPrint("Ring<u32, 64>", r1, .{});

    // Type parameters are keyed by owner and position, not by name.
    const p0 = try t.intern(.{ .param = .{ .owner = ring, .index = 0, .name = try f.strings.intern("T") } });
    try testing.expectEqual(p0, try t.intern(.{ .param = .{ .owner = ring, .index = 0, .name = try f.strings.intern("T") } }));
    try testing.expect(p0 != try t.intern(.{ .param = .{ .owner = ring, .index = 1, .name = try f.strings.intern("T") } }));
    try f.expectPrint("T", p0, .{});
}

test "printer matches spec spellings" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const t = &f.types;
    const u8_ = TypeId.int(.unsigned, 8);
    const app = try f.pkg("app", 1);
    const particle = try t.intern(.{ .nominal = .{ .decl = .{ .package = app, .index = 0 }, .kind = .@"struct", .name = try f.strings.intern("Particle") } });
    const atomic = try t.intern(.{ .nominal = .{ .decl = .{ .package = app, .index = 1 }, .args = &.{.{ .type = .int(.unsigned, 32) }}, .kind = .@"struct", .name = try f.strings.intern("Atomic"), .lang = .atomic } });
    const handle = try t.intern(.{ .handle = .{ .elem = particle } });
    const option = try t.intern(.{ .nominal = .{ .decl = .{ .package = app, .index = 2 }, .args = &.{.{ .type = handle }}, .kind = .@"enum", .name = try f.strings.intern("Option"), .lang = .option } });
    const ring = try t.intern(.{ .nominal = .{ .decl = .{ .package = app, .index = 3 }, .args = &.{ .{ .value = .{ .type = .int(.signed, 32), .bits = @bitCast(@as(i64, -3)) } }, .{ .value = .{ .type = .bool, .bits = 1 } } }, .kind = .@"struct", .name = try f.strings.intern("G") } });

    const cases = [_]struct { []const u8, Key }{
        .{ "bool", .{ .simple = .bool } },
        .{ "void", .{ .simple = .void } },
        .{ "noreturn", .{ .simple = .noreturn } },
        .{ "usize", .{ .simple = .usize } },
        .{ "str", .{ .simple = .str } },
        .{ "type", .{ .simple = .type } },
        .{ "untyped integer", .{ .simple = .untyped_int } },
        .{ "untyped float", .{ .simple = .untyped_float } },
        .{ "u7", .{ .int = .{ .signedness = .unsigned, .bits = 7 } } },
        .{ "i64", .{ .int = .{ .signedness = .signed, .bits = 64 } } },
        .{ "vec<3, f32>", .{ .vec = .{ .len = 3, .elem = .f32 } } },
        .{ "mask<4>", .{ .mask = .{ .len = 4 } } },
        .{ "[4]u8", .{ .array = .{ .len = 4, .elem = u8_ } } },
        .{ "soa [512]Particle", .{ .soa_array = .{ .len = 512, .elem = particle } } },
        .{ "[]Atomic<u32>", .{ .slice = .{ .elem = atomic } } },
        .{ "soa []Particle", .{ .soa_slice = .{ .elem = particle } } },
        .{ "(u8, f32)", .{ .tuple = .{ .elems = &.{ u8_, .f32 } } } },
        .{ "Handle<Particle>", .{ .handle = .{ .elem = particle } } },
        .{ "*u8", .{ .ptr = .{ .elem = u8_, .is_const = false } } },
        .{ "*const u8", .{ .ptr = .{ .elem = u8_, .is_const = true } } },
        .{ "fn()", .{ .fn_ptr = .{ .params = &.{}, .ret = .void } } },
        .{ "fn(mut u8, move Particle, f32) -> bool", .{ .fn_ptr = .{ .params = &.{ .{ .type = u8_, .mode = .mut }, .{ .type = particle, .mode = .move }, .{ .type = .f32 } }, .ret = .bool } } },
        .{ "mut Particle", .{ .mut_view = .{ .elem = particle } } },
        .{ "FieldId<Particle>", .{ .field_id = .{ .owner = particle } } },
    };
    for (cases) |c| try f.expectPrint(c[0], try t.intern(c[1]), .{});
    try f.expectPrint("Option<Handle<Particle>>", option, .{});
    try f.expectPrint("G<-3, true>", ring, .{});
}

test "equal ids for equal types under 8 threads" {
    const Pool = @import("../base/Pool.zig");
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var pool: Pool = undefined;
    try pool.init(testing.allocator, testing.io, 8);
    defer pool.deinit(testing.allocator);

    // 8 workers each intern the same 300 types, in different orders.
    const n = 300;
    const workers = 8;
    var ids: [workers][n]TypeId = undefined;
    const Ctx = struct { t: *Types, ids: *[workers][n]TypeId };
    pool.run(workers, Ctx{ .t = &f.types, .ids = &ids }, struct {
        fn job(c: Ctx, _: u32, w: usize) void {
            for (0..n) |k| {
                const i = (k * 7 + w * 31) % n; // 7 is coprime to 300
                const elem = TypeId.int(.unsigned, @intCast(i % 64 + 1));
                const key: Key = switch (i % 3) {
                    0 => .{ .array = .{ .len = i, .elem = elem } },
                    1 => .{ .tuple = .{ .elems = &.{ elem, .int(.signed, @intCast(i / 64 + 1)) } } },
                    else => .{ .slice = .{ .elem = c.t.intern(.{ .array = .{ .len = i, .elem = elem } }) catch unreachable } },
                };
                c.ids[w][i] = c.t.intern(key) catch unreachable;
            }
        }
    }.job);

    for (0..n) |i| for (1..workers) |w| try testing.expectEqual(ids[0][i], ids[w][i]);
    // 100 arrays, 100 tuples (distinct elem lists), 100 slices, 100 inner arrays of slices.
    try testing.expectEqual(TypeId.first_interned + 400, f.types.count());
}
