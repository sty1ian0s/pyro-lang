//! Layout engine (§4.11): the size, alignment and field placement of every
//! value type in the default Pyro layout.
//!
//! - primitives, pointers, handles, slices (§4.11.1), `vec<N, T>` (§4.3.1),
//!   `[N]T` (§4.4.1);
//! - structs and tuples (§4.11.2, §4.4.3): bit-field runs packed into units,
//!   members stably sorted by alignment, `@align(n)`;
//! - enums (§4.11.4): the backing integer, or a `payload` + `tag` struct, and
//!   the `Option<Handle<T>>` niche;
//! - the 2⁴⁸ − 1 byte size limit (§4.12, E0311).
//!
//! Layout depends only on the type's structure and the target's pointer
//! width, never on `TypeId` order, so it is deterministic (§4.11).
//!
//! `@packed`, `@c_layout` and SoA layouts are `layout_soa.zig`'s; comptime-only
//! types, generic parameters and std types not loaded yet have no layout
//! (`null`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const diag = @import("../diag/diag.zig");
const Ast = @import("../ast/Ast.zig");
const attr_table = @import("../attr_table.zig");
const module_graph = @import("../resolve/module_graph.zig");
const collect = @import("../resolve/collect.zig");
const Types = @import("types.zig");
const items_mod = @import("items.zig");
const soa = @import("layout_soa.zig");
const attrs_mod = @import("attrs.zig");

const Items = items_mod.Items;
const TypeId = Types.TypeId;
const Node = Ast.Node;
const ModuleId = module_graph.ModuleId;
const Error = Allocator.Error;

/// Maximum type size in bytes (§4.12).
pub const max_size: u64 = (1 << 48) - 1;
/// Maximum `@align(n)` (§8.8).
pub const max_align = attrs_mod.max_align;

/// Where a field (or tuple element) is stored.
pub const Place = struct {
    /// Byte offset of the member holding the field: the field itself, or
    /// its unit for a bit field.
    offset: u64,
    /// Index of the bit-field unit, counted in declaration order; null for
    /// an ordinary field.
    unit: ?u32 = null,
    /// First bit of the field in its unit, least significant first.
    bit_offset: u8 = 0,
    /// Width in bits of a bit field; 0 for an ordinary field.
    width: u8 = 0,
};

/// The layout of a type.
pub const Layout = struct {
    size: u64,
    @"align": u32,
    /// Structs and tuples: one place per field, in declaration order.
    /// Enums with payloads: the `payload` member, then the `tag`.
    fields: []const Place = &.{},
    /// `Option<Handle<T>>`: `.none` is generation 0 (§4.11.4).
    handle_niche: bool = false,

    /// Whether the type exceeds the size limit (E0311).
    pub fn tooLarge(l: Layout) bool {
        return l.size > max_size;
    }
};

/// One struct member before placement: a field or a bit-field unit.
const Member = struct { size: u64, @"align": u32 };

/// Computes and caches layouts for the types of one checked package. Not
/// thread-safe.
pub const Engine = struct {
    items: *Items,
    arena: std.heap.ArenaAllocator,
    cache: std.AutoHashMapUnmanaged(TypeId, Entry) = .empty,

    const Entry = union(enum) { active, done: ?Layout };

    pub fn init(gpa: Allocator, items: *Items) Engine {
        return .{ .items = items, .arena = .init(gpa) };
    }

    pub fn deinit(e: *Engine) void {
        e.arena.deinit();
        e.* = undefined;
    }

    fn alloc(e: *Engine) Allocator {
        return e.arena.allocator();
    }

    /// The layout of `ty`, or null if it has none here: comptime-only types,
    /// parameters, protocols, SoA types of non-structs (E0305), types of
    /// packages not loaded, and types that contain themselves (E0376).
    /// Sizes saturate, so an oversized type is `tooLarge`, never wrapped.
    pub fn layoutOf(e: *Engine, ty: TypeId) Error!?Layout {
        if (e.cache.get(ty)) |entry| return switch (entry) {
            .active => null,
            .done => |l| l,
        };
        try e.cache.put(e.alloc(), ty, .active);
        const l = try e.compute(ty);
        try e.cache.put(e.alloc(), ty, .{ .done = l });
        return l;
    }

    fn compute(e: *Engine, ty: TypeId) Error!?Layout {
        const ptr: u32 = e.items.options.ptr_bits / 8;
        return switch (e.items.types.get(ty)) {
            .simple => |s| switch (s) {
                .void, .noreturn => .{ .size = 0, .@"align" = 1 },
                .bool => .{ .size = 1, .@"align" = 1 },
                .isize, .usize => .{ .size = ptr, .@"align" = ptr },
                .f32 => .{ .size = 4, .@"align" = 4 },
                .f64 => .{ .size = 8, .@"align" = 8 },
                .str => .{ .size = 2 * ptr, .@"align" = ptr },
                else => null,
            },
            .int => |i| storage(i.bits),
            .vec => |v| if (try e.layoutOf(v.elem)) |l| vector(v.len, l.size) else null,
            // shortcut: `mask<N>` layout is implementation-defined (§4.3.2); stored like `vec<N, bool>`.
            .mask => |m| vector(m.len, 1),
            .array => |a| if (soa.isSoa(e, a.elem))
                try soa.soaArray(e, a.len, a.elem)
            else if (try e.layoutOf(a.elem)) |l|
                .{ .size = a.len *| alignUp(l.size, l.@"align"), .@"align" = l.@"align" }
            else
                null,
            .tuple => |t| e.record(t.elems, null, 1, true),
            .handle => .{ .size = 8, .@"align" = 8 },
            .ptr, .fn_ptr, .mut_view => .{ .size = ptr, .@"align" = ptr },
            .slice => |s| if (soa.isSoa(e, s.elem)) try soa.soaSlice(e, s.elem) else .{ .size = 2 * ptr, .@"align" = ptr },
            .soa_array => |a| try soa.soaArray(e, a.len, a.elem),
            .soa_slice => |s| try soa.soaSlice(e, s.elem),
            .field_id, .param => null,
            .nominal => |n| e.nominal(ty, n),
        };
    }

    fn nominal(e: *Engine, ty: TypeId, n: Types.Nominal) Error!?Layout {
        const arg = struct {
            fn f(nn: Types.Nominal, i: usize) ?TypeId {
                return if (i < nn.args.len and nn.args[i] == .type) nn.args[i].type else null;
            }
        }.f;
        switch (n.lang) {
            .option => {
                const t = arg(n, 0) orelse return null;
                if (e.items.types.get(t) == .handle) return .{ .size = 8, .@"align" = 8, .handle_niche = true };
                return e.tagged(&.{ &.{t}, &.{} }, .int(.unsigned, 8)); // some(T), none
            },
            .result => return e.tagged(&.{ &.{arg(n, 0) orelse return null}, &.{arg(n, 1) orelse return null} }, .int(.unsigned, 8)),
            .atomic => return e.layoutOf(arg(n, 0) orelse return null),
            .none => {},
            // shortcut: other std types have no declaration until std is loaded (T163).
            else => return null,
        }
        switch (n.kind) {
            .distinct => return e.layoutOf(n.underlying),
            .protocol => return null,
            .@"struct" => {
                const s = e.items.structOf(ty) orelse return null;
                const m = e.items.declRef(ty).?.module;
                const tys = try e.alloc().alloc(TypeId, s.fields.len);
                const aligns = try e.alloc().alloc(u32, s.fields.len);
                for (s.fields, tys, aligns) |f, *t, *al| {
                    t.* = try e.items.subst(f.type, n.decl, n.args);
                    al.* = try e.alignAttr(m, f.attrs);
                }
                const min_align = try e.alignAttr(m, s.attrs);
                if (e.attr(m, s.attrs, .@"packed") != null) return soa.ordered(e, tys, aligns, min_align, .@"packed");
                if (e.attr(m, s.attrs, .c_layout) != null) return soa.ordered(e, tys, aligns, min_align, .c);
                // §4.11.3: `@soa` structs never bit-pack.
                return e.record(tys, aligns, min_align, e.attr(m, s.attrs, .soa) == null);
            },
            .@"enum" => {
                const en = e.items.enumOf(ty) orelse return null;
                if (!en.has_payload) return e.layoutOf(en.backing);
                const payloads = try e.alloc().alloc([]const TypeId, en.variants.len);
                for (en.variants, payloads) |v, *p| {
                    const tys = try e.alloc().alloc(TypeId, v.payload.len);
                    for (v.payload, tys) |t, *o| o.* = try e.items.subst(t, n.decl, n.args);
                    p.* = tys;
                }
                return e.tagged(payloads, en.backing);
            },
        }
    }

    /// An enum with payloads (§4.11.4): a struct of `payload` (as large and
    /// aligned as the largest variant payload, each laid out as a tuple) and
    /// `tag`.
    fn tagged(e: *Engine, payloads: []const []const TypeId, tag_ty: TypeId) Error!?Layout {
        var payload: Member = .{ .size = 0, .@"align" = 1 };
        for (payloads) |p| {
            const l = try e.record(p, null, 1, true) orelse return null;
            payload = .{ .size = @max(payload.size, l.size), .@"align" = @max(payload.@"align", l.@"align") };
        }
        const tag = try e.layoutOf(tag_ty) orelse return null;
        var members = [_]Member{ payload, .{ .size = tag.size, .@"align" = tag.@"align" } };
        const offsets = try e.alloc().alloc(u64, 2);
        const l = place(&members, offsets, 1);
        const fields = try e.alloc().alloc(Place, 2);
        for (fields, offsets) |*f, o| f.* = .{ .offset = o };
        return .{ .size = l.size, .@"align" = l.@"align", .fields = fields };
    }

    /// Pyro layout of fields `tys` in declaration order (§4.11.2). `aligns`
    /// holds each field's `@align(n)` (0 if none); a field with `@align` is
    /// never packed into a unit. With `bitfields` false every field is a
    /// plain member (`@soa` structs, §4.11.3).
    fn record(e: *Engine, tys: []const TypeId, aligns: ?[]const u32, min_align: u32, bitfields: bool) Error!?Layout {
        const a = e.alloc();
        const places = try a.alloc(Place, tys.len);
        const member_of = try a.alloc(usize, tys.len);
        var members: std.ArrayList(Member) = .empty;
        // The open unit of the current bit-field run: its member index and bits used.
        var unit: ?usize = null;
        var bits: u32 = 0;
        var units: u32 = 0;
        for (tys, places, member_of, 0..) |t, *p, *mo, i| {
            const forced = if (aligns) |al| al[i] else 0;
            if (if (forced == 0 and bitfields) e.bitWidth(t) else null) |w| {
                if (unit == null or bits + w > 64) {
                    if (unit) |u| members.items[u] = unitMember(bits);
                    unit = members.items.len;
                    bits = 0;
                    units += 1;
                    try members.append(a, undefined);
                }
                p.* = .{ .offset = 0, .unit = units - 1, .bit_offset = @intCast(bits), .width = w };
                mo.* = unit.?;
                bits += w;
            } else {
                if (unit) |u| members.items[u] = unitMember(bits);
                unit = null;
                const l = try e.layoutOf(t) orelse return null;
                p.* = .{ .offset = 0 };
                mo.* = members.items.len;
                try members.append(a, .{ .size = l.size, .@"align" = @max(l.@"align", forced) });
            }
        }
        if (unit) |u| members.items[u] = unitMember(bits);
        const offsets = try a.alloc(u64, members.items.len);
        const l = place(members.items, offsets, min_align);
        for (places, member_of) |*p, mo| p.offset = offsets[mo];
        return .{ .size = l.size, .@"align" = l.@"align", .fields = places };
    }

    /// The width of `ty` as a bit field (§4.11.2), or null if it is not one:
    /// `uN`/`iN` with N not 8, 16, 32 or 64, `bool`, or a payload-free enum
    /// without an explicit backing type.
    pub fn bitWidth(e: *Engine, ty: TypeId) ?u8 {
        return switch (e.items.types.get(ty)) {
            .simple => |s| if (s == .bool) 1 else null,
            .int => |i| switch (i.bits) {
                8, 16, 32, 64 => null,
                else => i.bits,
            },
            .nominal => |n| {
                if (n.kind != .@"enum" or n.lang != .none) return null;
                const en = e.items.enumOf(ty) orelse return null;
                if (en.has_payload or en.explicit_backing) return null;
                var max: u64 = 0;
                for (en.variants) |v| max = @max(max, v.discriminant.bits);
                return @max(1, 64 - @clz(max));
            },
            else => null,
        };
    }

    /// For `ctype.isCompatible`'s `decls`: true for `@c_layout` structs and
    /// payload-free `@c_layout` enums with an explicit backing type.
    pub fn isCLayout(e: *Engine, id: TypeId) bool {
        const ref = e.items.declRef(id) orelse return false;
        if (e.items.structOf(id)) |s| return e.attr(ref.module, s.attrs, .c_layout) != null;
        const en = e.items.enumOf(id) orelse return false;
        return !en.has_payload and en.explicit_backing and e.attr(ref.module, en.attrs, .c_layout) != null;
    }

    /// For `ctype.isCompatible`'s `decls`: the backing integer of enum `id`.
    pub fn enumBacking(e: *Engine, id: TypeId) TypeId {
        return (e.items.enumOf(id) orelse return .err).backing;
    }

    fn ast(e: *Engine, m: ModuleId) *const Ast {
        return e.items.im.graph.modules[m].ast;
    }

    /// The attribute node `which` among `attrs` of module `m`.
    pub fn attr(e: *Engine, m: ModuleId, attrs: []const Node.Index, which: attr_table.Attr) ?Node.Index {
        const a = e.ast(m);
        for (attrs) |n| {
            const text = a.tokenSlice(a.mainToken(n));
            if (attr_table.lookup(if (std.mem.startsWith(u8, text, "@")) text[1..] else text) == which) return n;
        }
        return null;
    }

    /// The argument of `@align(n)` among `attrs`, if written.
    fn alignArg(e: *Engine, m: ModuleId, attrs: []const Node.Index) ?Node.Index {
        const a = e.ast(m);
        const n = e.attr(m, attrs, .@"align") orelse return null;
        const args = a.data(n).attribute.args orelse return null;
        if (args.len == 0) return null;
        return if (a.kind(args[0]) == .named_arg) a.data(args[0]).named_arg.value else args[0];
    }

    /// `@align(n)` among `attrs`, or 0 if absent or invalid.
    fn alignAttr(e: *Engine, m: ModuleId, attrs: []const Node.Index) Error!u32 {
        const arg = e.alignArg(m, attrs) orelse return 0;
        // Invalid arguments are reported by `attrs.zig`.
        const v = attrs_mod.intValue(e.items, try attrs_mod.argValue(e.items, m, arg)) orelse return 0;
        return if (attrs_mod.validAlign(v)) @intCast(v) else 0;
    }

    fn report(e: *Engine, m: ModuleId, t: Ast.TokenIndex, code: ?diag.DiagCode, comptime fmt: []const u8, args: anytype) Error!void {
        const a = e.ast(m);
        const start = a.tokens.items(.start)[t];
        const message = try std.fmt.allocPrint(e.alloc(), fmt, args);
        try e.items.sink.emit(.{
            .code = code,
            .severity = if (code) |c| .of(c) else .@"error",
            .message = message,
            .spans = &.{.{ .span = .{ .file = e.items.im.graph.modules[m].file, .start = start, .end = start + a.tokens.items(.len)[t] }, .primary = true }},
        });
    }

    /// Lays out every non-generic struct, enum, alias and distinct type of
    /// the package and reports types over the size limit (E0311) and `@c_layout` fields without a C
    /// representation (E1201). A type that is too large because a
    /// declared non-generic type it contains is, is not reported again.
    pub fn check(e: *Engine) Error!void {
        for (e.items.im.graph.modules, 0..) |mod, mi| for (mod.items, 0..) |item, i| {
            const m: ModuleId = @intCast(mi);
            const info = try e.items.info(.{ .module = m, .item = @intCast(i) });
            var parts: std.ArrayList(TypeId) = .empty;
            switch (info.*) {
                .@"struct" => |s| {
                    // Generic fields are judged at instantiation.
                    if (s.generics.len == 0 and e.attr(m, s.attrs, .c_layout) != null) try soa.checkCFields(e, m, s);
                    for (s.fields) |f| try parts.append(e.alloc(), f.type);
                    if (s.generics.len == 0) try e.checkSize(m, item, s.type, parts.items);
                },
                .@"enum" => |en| {
                    for (en.variants) |v| try parts.appendSlice(e.alloc(), v.payload);
                    if (en.generics.len == 0) try e.checkSize(m, item, en.type, parts.items);
                },
                .alias => |t| try e.checkSize(m, item, t, &.{t}),
                .distinct => |t| try e.checkSize(m, item, t, &.{e.items.types.get(t).nominal.underlying}),
                else => {},
            }
        };
    }

    fn checkSize(e: *Engine, m: ModuleId, item: collect.Item, ty: TypeId, parts: []const TypeId) Error!void {
        const l = try e.layoutOf(ty) orelse return;
        if (!l.tooLarge()) return;
        for (parts) |p| if (try e.reportedElsewhere(p)) return;
        try e.report(m, e.ast(m).mainToken(item.node) + 1, .E0311, "`{s}` is too large: {d} bytes; the maximum type size is 2^48 - 1 bytes", .{ item.name, l.size });
    }

    /// Whether `ty` is too large because of a type `check` reports itself:
    /// a non-generic declared type, possibly inside arrays, tuples or
    /// generic arguments.
    fn reportedElsewhere(e: *Engine, ty: TypeId) Error!bool {
        const l = try e.layoutOf(ty) orelse return false;
        if (!l.tooLarge()) return false;
        switch (e.items.types.get(ty)) {
            .array => |a| return e.reportedElsewhere(a.elem),
            .tuple => |t| for (t.elems) |el| if (try e.reportedElsewhere(el)) return true,
            .nominal => |n| {
                if (n.args.len == 0) return e.items.declRef(ty) != null;
                for (n.args) |a| if (a == .type and try e.reportedElsewhere(a.type)) return true;
            },
            else => {},
        }
        return false;
    }
};

/// Storage size of `uN`/`iN` (§4.2.2), also the size of a unit of `bits`
/// bits (§4.11.2 `size_for`).
pub fn storage(bits: u32) Layout {
    const size: u32 = if (bits <= 8) 1 else if (bits <= 16) 2 else if (bits <= 32) 4 else 8;
    return .{ .size = size, .@"align" = size };
}

fn unitMember(bits: u32) Member {
    const l = storage(bits);
    return .{ .size = l.size, .@"align" = l.@"align" };
}

/// `vec<N, T>` (§4.3.1): `N × sizeof(T)` rounded up to a power of two,
/// aligned to `min(size, 64)`.
fn vector(len: u32, elem_size: u64) Layout {
    const raw = len * elem_size;
    if (raw == 0) return .{ .size = 0, .@"align" = 1 };
    const size = std.math.ceilPowerOfTwoAssert(u64, raw);
    return .{ .size = size, .@"align" = @intCast(@min(size, 64)) };
}

pub fn alignUp(x: u64, a: u64) u64 {
    return (x +| (a - 1)) & ~(a - 1);
}

/// Places `members` (§4.11.2 steps 3-4): stably sorted by alignment,
/// descending, each at the next multiple of its alignment. Writes each
/// member's offset to `offsets` and returns the struct's size and alignment.
fn place(members: []const Member, offsets: []u64, min_align: u32) Member {
    var off: u64 = 0;
    var al: u32 = @max(1, min_align);
    var done: usize = 0;
    // Stable sort without allocating: visit members by descending alignment
    // class (powers of two), declaration order within a class.
    var class: u32 = max_align;
    while (done < members.len) : (class /= 2) {
        for (members, offsets) |mem, *o| {
            if (mem.@"align" != class) continue;
            off = alignUp(off, mem.@"align");
            o.* = off;
            off +|= mem.size;
            al = @max(al, mem.@"align");
            done += 1;
        }
        if (class == 1) break;
    }
    std.debug.assert(done == members.len);
    return .{ .size = alignUp(off, al), .@"align" = al };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const Interner = @import("../base/Interner.zig");
const imports = @import("../resolve/imports.zig");
const names_mod = @import("../resolve/names.zig");
const ctype = @import("ctype.zig");

/// A checked one-module test package with a layout engine.
pub const Fixture = struct {
    p: module_graph.TestPackage,
    g: module_graph.Graph,
    im: imports.Imports,
    names: names_mod.Names,
    strings: Interner,
    types: Types,
    items: Items,
    e: Engine,

    pub fn init(f: *Fixture, src: []const u8) !void {
        f.p = try .init(&.{.{ "a", src }});
        f.g = try f.p.graph(.{ .kind = .exe });
        f.im = try imports.resolve(testing.allocator, &f.p.sink, &f.g, .{});
        f.names = try names_mod.resolve(testing.allocator, &f.p.sink, &f.im);
        f.strings = .init(testing.allocator, testing.io);
        f.types = try .init(testing.allocator, testing.io, &f.strings);
        const pkg: Types.Package = .{ .name = try f.strings.intern("app"), .line = .{ .major = 1 } };
        f.items = try items_mod.check(testing.allocator, &f.p.sink, &f.types, &f.im, &f.names, .{ .package = pkg });
        f.e = .init(testing.allocator, &f.items);
        try f.e.check();
    }

    pub fn deinit(f: *Fixture) void {
        f.e.deinit();
        f.items.deinit();
        f.types.deinit();
        f.strings.deinit();
        f.names.deinit();
        f.im.deinit();
        f.g.deinit();
        f.p.deinit();
    }

    pub fn info(f: *Fixture, name: []const u8) !*const items_mod.Info {
        return f.items.info(.{ .module = 0, .item = f.g.modules[0].names.get(name).? });
    }

    /// The type declared by struct or enum `name`.
    pub fn typeOf(f: *Fixture, name: []const u8) !TypeId {
        return switch ((try f.info(name)).*) {
            .@"struct" => |s| s.type,
            .@"enum" => |en| en.type,
            else => unreachable,
        };
    }

    /// The layout of struct or enum `name`.
    pub fn of(f: *Fixture, name: []const u8) !Layout {
        return (try f.e.layoutOf(try f.typeOf(name))).?;
    }

    /// The layout of the type of field `field` of struct `name`.
    pub fn field(f: *Fixture, name: []const u8, field_name: []const u8) !Layout {
        for ((try f.info(name)).@"struct".fields) |fl| {
            if (std.mem.eql(u8, fl.name, field_name)) return (try f.e.layoutOf(fl.type)).?;
        }
        unreachable;
    }

    /// Checks the reported codes and the source text at each primary span.
    pub fn expectDiags(f: *Fixture, want: []const struct { ?diag.DiagCode, []const u8 }) !void {
        const ds = f.p.sink.finish();
        errdefer for (ds) |d| std.debug.print("got {?t}: {s}\n", .{ d.code, d.message });
        try testing.expectEqual(want.len, ds.len);
        for (want, ds) |w, d| {
            try testing.expectEqual(w[0], d.code);
            const s = d.primarySpan().?;
            try testing.expectEqualStrings(w[1], f.p.asts[@backingInt(s.file)].source[s.start..s.end]);
        }
    }
};

pub fn expectLayout(size: u64, @"align": u32, l: Layout) !void {
    try testing.expectEqual(size, l.size);
    try testing.expectEqual(@"align", l.@"align");
}

test "§4.11.2 PlayerState: size 8, align 4, exact bit positions" {
    var f: Fixture = undefined;
    try f.init(
        \\struct PlayerState {
        \\    health: u7,
        \\    is_crouching: bool,
        \\    weapon_slot: u3,
        \\    score: u32,
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    const l = try f.of("PlayerState");
    try expectLayout(8, 4, l);
    try testing.expectEqualSlices(Place, &.{
        .{ .offset = 4, .unit = 0, .bit_offset = 0, .width = 7 },
        .{ .offset = 4, .unit = 0, .bit_offset = 7, .width = 1 },
        .{ .offset = 4, .unit = 0, .bit_offset = 8, .width = 3 },
        .{ .offset = 0 },
    }, l.fields);
}

test "primitives, vec<3, f32> 16/16, [0]T size 0, arrays, Handle, slices" {
    var f: Fixture = undefined;
    try f.init(
        \\struct P {}
        \\struct S {
        \\    v: vec<3, f32>, v8: vec<8, f64>, vb: vec4<bool>,
        \\    z: [0]u64, arr: [3]u16, b: bool, u: u24, i: i33, x: usize, d: f64,
        \\    h: Handle<P>, s: []u8, t: str, p: *const u8, e: P,
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    const want = [_]struct { []const u8, u64, u32 }{
        .{ "v", 16, 16 }, .{ "v8", 64, 64 }, .{ "vb", 4, 4 },
        .{ "z", 0, 8 },   .{ "arr", 6, 2 },  .{ "b", 1, 1 },
        .{ "u", 4, 4 },   .{ "i", 8, 8 },    .{ "x", 8, 8 },
        .{ "d", 8, 8 },   .{ "h", 8, 8 },    .{ "s", 16, 8 },
        .{ "t", 16, 8 },  .{ "p", 8, 8 },    .{ "e", 0, 1 },
    };
    for (want) |w| {
        errdefer std.debug.print("field {s}\n", .{w[0]});
        try expectLayout(w[1], w[2], try f.field("S", w[0]));
    }
}

test "4-variant enum is a 2-bit field; explicit backing is not a bit field" {
    var f: Fixture = undefined;
    try f.init(
        \\enum Dir { n, e, s, w }
        \\enum One { only }
        \\enum Sparse { a, b = 200 }
        \\enum Byte: u8 { a, b }
        \\struct S { d: Dir, x: u3, o: One, sp: Sparse }
        \\struct T { d: Dir, b: Byte }
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    const e = &f.e;
    try testing.expectEqual(@as(?u8, 2), e.bitWidth(try f.typeOf("Dir")));
    try testing.expectEqual(@as(?u8, 1), e.bitWidth(try f.typeOf("One")));
    try testing.expectEqual(@as(?u8, 8), e.bitWidth(try f.typeOf("Sparse")));
    try testing.expectEqual(@as(?u8, null), e.bitWidth(try f.typeOf("Byte")));
    try expectLayout(1, 1, try f.of("Dir"));
    const s = try f.of("S");
    try expectLayout(2, 2, s);
    try testing.expectEqualSlices(Place, &.{
        .{ .offset = 0, .unit = 0, .bit_offset = 0, .width = 2 },
        .{ .offset = 0, .unit = 0, .bit_offset = 2, .width = 3 },
        .{ .offset = 0, .unit = 0, .bit_offset = 5, .width = 1 },
        .{ .offset = 0, .unit = 0, .bit_offset = 6, .width = 8 },
    }, s.fields);
    const t = try f.of("T");
    try expectLayout(2, 1, t);
    try testing.expectEqualSlices(Place, &.{ .{ .offset = 0, .unit = 0, .width = 2 }, .{ .offset = 1 } }, t.fields);
}

test "a 70-bit run splits at 64; runs end at ordinary fields" {
    var f: Fixture = undefined;
    try f.init(
        \\struct R { a: u40, b: u30 }
        \\struct Q { a: u4, m: u8, b: u4, c: i1 }
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    const r = try f.of("R");
    try expectLayout(16, 8, r);
    try testing.expectEqualSlices(Place, &.{
        .{ .offset = 0, .unit = 0, .bit_offset = 0, .width = 40 },
        .{ .offset = 8, .unit = 1, .bit_offset = 0, .width = 30 },
    }, r.fields);
    const q = try f.of("Q");
    try expectLayout(3, 1, q);
    try testing.expectEqualSlices(Place, &.{
        .{ .offset = 0, .unit = 0, .width = 4 },
        .{ .offset = 1 },
        .{ .offset = 2, .unit = 1, .width = 4 },
        .{ .offset = 2, .unit = 1, .bit_offset = 4, .width = 1 },
    }, q.fields);
}

test "stable alignment sort, tuples, @align" {
    var f: Fixture = undefined;
    try f.init(
        \\struct M { a: u8, b: u64, c: u16, d: u64, e: (u8, u32, bool) }
        \\@align(16) struct A { x: u8 }
        \\struct F { a: u8, @align(8) b: bool, c: bool }
        \\@align(3) struct Bad { x: u8 }
        \\const J: usize = 32;
        \\const K: usize = 3;
        \\@align(J) struct ByName { x: u8 }
        \\@align(K) struct BadName {}
        \\@align(1.5) struct Float {}
        \\@align(true) struct Flag {}
        \\@align(Nope) struct Unknown {}
    );
    defer f.deinit();
    // Invalid `@align` arguments are reported by `attrs.zig`, not here.
    try f.expectDiags(&.{});
    try expectLayout(32, 32, try f.of("ByName"));
    const m = try f.of("M");
    try expectLayout(32, 8, m);
    // b, d (align 8), then e (align 4), c (2), a (1).
    try testing.expectEqualSlices(Place, &.{ .{ .offset = 26 }, .{ .offset = 0 }, .{ .offset = 24 }, .{ .offset = 8 }, .{ .offset = 16 } }, m.fields);
    const e = try f.field("M", "e");
    try expectLayout(8, 4, e);
    try testing.expectEqualSlices(Place, &.{ .{ .offset = 4 }, .{ .offset = 0 }, .{ .offset = 5, .unit = 0, .width = 1 } }, e.fields);
    try expectLayout(16, 16, try f.of("A"));
    const fl = try f.of("F");
    try expectLayout(8, 8, fl);
    try testing.expectEqualSlices(Place, &.{ .{ .offset = 1 }, .{ .offset = 0 }, .{ .offset = 2, .unit = 0, .width = 1 } }, fl.fields);
    try expectLayout(1, 1, try f.of("Bad"));
}

test "enums: backing, payloads, Option<Handle<T>> niche, Result" {
    var f: Fixture = undefined;
    try f.init(
        \\enum Wide { a = 300 }
        \\enum Small: i8 { a = -1 }
        \\enum Shape { circle(f32), rect(f32, f32), none }
        \\enum Big { a(u8), b(u64) }
        \\struct P {}
        \\struct S {
        \\    h: Option<Handle<P>>, o: Option<u32>, r: Result<u64, u8>, sh: Shape,
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    try expectLayout(2, 2, try f.of("Wide"));
    try expectLayout(1, 1, try f.of("Small"));
    const shape = try f.of("Shape");
    try expectLayout(12, 4, shape);
    try testing.expectEqualSlices(Place, &.{ .{ .offset = 0 }, .{ .offset = 8 } }, shape.fields);
    try expectLayout(16, 8, try f.of("Big"));
    const h = try f.field("S", "h");
    try expectLayout(8, 8, h);
    try testing.expect(h.handle_niche);
    try expectLayout(8, 4, try f.field("S", "o"));
    try expectLayout(16, 8, try f.field("S", "r"));
    try expectLayout(48, 8, try f.of("S"));
}

test "generic instances use their arguments; distinct uses its underlying type" {
    var f: Fixture = undefined;
    try f.init(
        \\struct Pair<T> { a: T, b: u8 }
        \\type Meters = distinct f64;
        \\struct S { p: Pair<u32>, q: Pair<u3>, m: Meters }
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    try expectLayout(8, 4, try f.field("S", "p"));
    const q = try f.field("S", "q");
    try expectLayout(2, 1, q);
    try testing.expectEqualSlices(Place, &.{ .{ .offset = 0, .unit = 0, .width = 3 }, .{ .offset = 1 } }, q.fields);
    try expectLayout(8, 8, try f.field("S", "m"));
}

test "E0311: types over 2^48 - 1 bytes, reported once" {
    var f: Fixture = undefined;
    try f.init(
        \\type TooBig = [281474976710656]u8;
        \\type Fine = [281474976710655]u8;
        \\type Nested = [2]Huge;
        \\type D = distinct [281474976710656]u8;
        \\struct Huge { a: [35184372088832]u64 }
        \\struct Outer { h: Huge, more: [2]Huge }
        \\struct Edge { a: [281474976710655]u8 }
        \\struct Over { a: [281474976710655]u8, b: u8 }
        \\enum E { a([281474976710656]u8) }
        \\struct G<T> { a: [281474976710656]T }
        \\struct UsesG { g: G<u8> }
        \\struct Wrap<T> { t: T }
        \\struct UsesWrap { w: Wrap<Huge>, t: (Huge, u8) }
    );
    defer f.deinit();
    try f.expectDiags(&.{ .{ .E0311, "TooBig" }, .{ .E0311, "D" }, .{ .E0311, "Huge" }, .{ .E0311, "Over" }, .{ .E0311, "E" }, .{ .E0311, "UsesG" } });
    try testing.expect(!(try f.of("Edge")).tooLarge());
    try testing.expect((try f.of("Outer")).tooLarge());
}

test "recursive containment has no layout" {
    var f: Fixture = undefined;
    try f.init(
        \\struct Node { value: u32, next: Node }
    );
    defer f.deinit();
    try testing.expectEqual(@as(?Layout, null), try f.e.layoutOf(try f.typeOf("Node")));
}

test "ctype decls contract: isCLayout, enumBacking" {
    var f: Fixture = undefined;
    try f.init(
        \\@c_layout struct C { x: i32 }
        \\@c_layout enum M: u16 { a, b }
        \\@c_layout enum N { a }
        \\struct Plain { x: i32 }
    );
    defer f.deinit();
    const e = &f.e;
    try testing.expect(e.isCLayout(try f.typeOf("C")));
    try testing.expect(e.isCLayout(try f.typeOf("M")));
    try testing.expect(!e.isCLayout(try f.typeOf("N")));
    try testing.expect(!e.isCLayout(try f.typeOf("Plain")));
    try testing.expectEqual(TypeId.int(.unsigned, 16), e.enumBacking(try f.typeOf("M")));
    try testing.expect(ctype.isCompatible(&f.types, try f.typeOf("M"), .{ .pos = .param }, e));
    try testing.expect(!ctype.isCompatible(&f.types, try f.typeOf("Plain"), .{ .pos = .param }, e));
}

test "repeat runs give identical layouts" {
    const src =
        \\enum Dir { n, e, s, w }
        \\struct P {}
        \\struct S { a: u7, d: Dir, x: u64, t: (u8, bool, u40), v: vec3<f32>, h: Option<Handle<P>>, z: [0]u8, q: u60, r: u10 }
    ;
    var runs: [2]Layout = undefined;
    var fixtures: [2]Fixture = undefined;
    for (&fixtures, &runs) |*f, *r| {
        try f.init(src);
        r.* = try f.of("S");
    }
    defer for (&fixtures) |*f| f.deinit();
    try testing.expectEqual(runs[0].size, runs[1].size);
    try testing.expectEqual(runs[0].@"align", runs[1].@"align");
    try testing.expectEqualSlices(Place, runs[0].fields, runs[1].fields);
}
