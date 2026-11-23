//! Names of generated types and instances (§8.3.2, §13.7).
//!
//! A declaration `F` applied to comptime arguments (a type function
//! instance, a generic instance, an instantiated function) has two names:
//!
//! - the *display name* `F(a1, a2)`, used in diagnostics: types as
//!   `Types.print` writes them, integers in decimal, `true`/`false`, enum
//!   values and field ids as `.name`, strings quoted, struct values as
//!   `.{ f: v }`;
//! - the *mangled name* `F__a1__a2…`, the top-level declaration name in
//!   `--expand` output and the symbol base for lowering. Each argument is
//!   rendered by `writeValue`: types by their mangled name (`writeType`),
//!   integers in decimal with an `m` prefix for negatives, `bool` as
//!   `t`/`f`, `FieldId` by field name, payload-free enum values by variant
//!   name, and struct values as `field_value` pairs joined by `_`, leaving
//!   out fields at their default value. `F` with no arguments is just `F`.
//!
//! This API is frozen for generics (T064, T068, T070) and the back end:
//! name an instance by its memo `Id` (`instanceDisplay`,
//! `instanceMangled`), or any declaration name and argument list
//! (`display`, `mangled`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Ast = @import("../ast/Ast.zig");
const Types = @import("../sema/types.zig");
const items_mod = @import("../sema/items.zig");
const convert = @import("../sema/convert.zig");
const instantiate = @import("instantiate.zig");
const typefn = @import("typefn.zig");
const Value = @import("value.zig").Value;
const ModuleId = @import("../resolve/module_graph.zig").ModuleId;

const Node = Ast.Node;
const TypeId = Types.TypeId;
const Items = items_mod.Items;
const Error = Allocator.Error;

/// The name of declaration `decl` of module `m`: the identifier after its
/// keyword (`fn F`, `struct S`, `enum E`).
pub fn declName(it: *const Items, m: ModuleId, decl: Node.Index) []const u8 {
    const a = it.im.graph.modules[m].ast;
    const s = a.tokenSlice(a.mainToken(decl) + 1);
    return if (std.mem.startsWith(u8, s, "r#")) s[2..] else s;
}

/// `F(a1, a2)` for instance `id` of `Items.memo`, in `gpa`.
pub fn instanceDisplay(gpa: Allocator, it: *Items, id: instantiate.Id) Error![]u8 {
    const k = it.memo.keyOf(id);
    return display(gpa, it, declName(it, k.module, k.decl), k.args);
}

/// `F__a1__a2…` for instance `id` of `Items.memo`, in `gpa`.
pub fn instanceMangled(gpa: Allocator, it: *Items, id: instantiate.Id) Error![]u8 {
    const k = it.memo.keyOf(id);
    return mangled(gpa, it, declName(it, k.module, k.decl), k.args);
}

/// The display name `name(a1, a2)`, in `gpa`.
pub fn display(gpa: Allocator, it: *Items, name: []const u8, args: []const Value) Error![]u8 {
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    (blk: {
        w.print("{s}(", .{name}) catch |e| break :blk e;
        for (args, 0..) |v, i| {
            if (i > 0) w.writeAll(", ") catch |e| break :blk e;
            writeDisplayValue(w, it, v) catch |e| break :blk e;
        }
        w.writeByte(')') catch |e| break :blk e;
    }) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// The mangled name `name__a1__a2…`, in `gpa`.
pub fn mangled(gpa: Allocator, it: *Items, name: []const u8, args: []const Value) Error![]u8 {
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    (blk: {
        w.writeAll(name) catch |e| break :blk e;
        for (args) |v| {
            w.writeAll("__") catch |e| break :blk e;
            writeValue(w, it, v) catch |e| break :blk e;
        }
    }) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// Writes the mangled name of type `ty`: a generated type's declaration
/// name, a nominal type's name followed by `__arg` per generic argument,
/// a primitive's name, and for other types a structural spelling made of
/// identifier characters (`arr4_u8`, `sl_u8`, `ptr_T`, `cptr_T`,
/// `tup2_u8_f32`...).
pub fn writeType(w: *Writer, it: *Items, ty: TypeId) Writer.Error!void {
    const types = it.types;
    switch (types.get(ty)) {
        .simple, .int => try types.print(w, ty, .{}),
        .nominal => |n| {
            if (typefn.get(it, ty)) |g| return w.writeAll(g.mangled);
            try w.writeAll(types.strings.get(n.name));
            for (n.args) |arg| {
                try w.writeAll("__");
                switch (arg) {
                    .type => |t| try writeType(w, it, t),
                    .value => |v| try writeInt(w, types, it.options.ptr_bits, v.type, v.bits),
                }
            }
        },
        .param => |p| try w.writeAll(types.strings.get(p.name)),
        .array => |x| {
            try w.print("arr{d}_", .{x.len});
            try writeType(w, it, x.elem);
        },
        .soa_array => |x| {
            try w.print("soa{d}_", .{x.len});
            try writeType(w, it, x.elem);
        },
        .vec => |x| {
            try w.print("vec{d}_", .{x.len});
            try writeType(w, it, x.elem);
        },
        .mask => |x| try w.print("mask{d}", .{x.len}),
        inline .slice, .soa_slice, .handle, .mut_view, .field_id => |x, tag| {
            try w.writeAll(switch (tag) {
                .slice => "sl_",
                .soa_slice => "soasl_",
                .handle => "Handle_",
                .mut_view => "mut_",
                .field_id => "FieldId_",
                else => unreachable,
            });
            try writeType(w, it, if (tag == .field_id) x.owner else x.elem);
        },
        .ptr => |x| {
            try w.writeAll(if (x.is_const) "cptr_" else "ptr_");
            try writeType(w, it, x.elem);
        },
        .tuple => |x| {
            try w.print("tup{d}", .{x.elems.len});
            for (x.elems) |e| {
                try w.writeByte('_');
                try writeType(w, it, e);
            }
        },
        .fn_ptr => |x| {
            try w.print("fn{d}", .{x.params.len});
            for (x.params) |p| {
                try w.writeByte('_');
                try writeType(w, it, p.type);
            }
            try w.writeByte('_');
            try writeType(w, it, x.ret);
        },
    }
}

/// Writes the mangled spelling of comptime value `v` (see the file comment).
pub fn writeValue(w: *Writer, it: *Items, v: Value) Writer.Error!void {
    const types = it.types;
    switch (v.data) {
        .void => try w.writeAll("void"),
        .type => |t| try writeType(w, it, t),
        .scalar => |bits| {
            if (v.ty == .bool) return w.writeAll(if (bits != 0) "t" else "f");
            if (v.ty == .f32 or v.ty == .f64) return writeFloat(w, v.toFloat());
            if (variantName(it, v.ty, bits)) |name| return w.writeAll(name);
            try writeInt(w, types, it.options.ptr_bits, v.ty, bits);
        },
        .str => |s| try writeIdent(w, s),
        .bytes => |s| for (s, 0..) |b, i| {
            if (i > 0) try w.writeByte('_');
            try w.print("{d}", .{b});
        },
        .fn_ref => |f| try w.writeAll(declName(it, f.module, f.node)),
        .field_id => |i| try w.writeAll(fieldName(it, v.ty, i)),
        .aggregate => |vs| if (typefn.structOf(it, v.ty)) |s| {
            // `field_value` pairs; fields at their default are left out.
            var first = true;
            for (s.fields, vs) |f, x| {
                if (f.default) |d| if (instantiate.argValue(it, d)) |dv| if (dv.eql(x)) continue;
                if (!first) try w.writeByte('_');
                first = false;
                try w.print("{s}_", .{f.name});
                try writeValue(w, it, x);
            }
        } else try writeAll(w, it, vs),
        .slice => |vs| try writeAll(w, it, vs),
        .variant => |x| {
            // `Option`: `some(x)` is `x`, `none` is `none`.
            if (isOption(types, v.ty) and x.index == 0) return writeAll(w, it, x.payload);
            try w.writeAll(variantAt(it, v.ty, x.index));
            for (x.payload) |p| {
                try w.writeByte('_');
                try writeValue(w, it, p);
            }
        },
    }
}

/// Writes the display spelling of comptime value `v` (see the file comment).
pub fn writeDisplayValue(w: *Writer, it: *Items, v: Value) Writer.Error!void {
    const types = it.types;
    switch (v.data) {
        .void => try w.writeAll("{}"),
        .type => |t| try types.print(w, t, .{}),
        .scalar => |bits| {
            if (v.ty == .bool) return w.writeAll(if (bits != 0) "true" else "false");
            if (v.ty == .f32 or v.ty == .f64) return w.print("{d}", .{v.toFloat()});
            if (variantName(it, v.ty, bits)) |name| return w.print(".{s}", .{name});
            try writeSigned(w, types, it.options.ptr_bits, v.ty, bits);
        },
        .str => |s| try w.print("\"{s}\"", .{s}),
        .bytes => |s| try w.print("{any}", .{s}),
        .fn_ref => |f| try w.writeAll(declName(it, f.module, f.node)),
        .field_id => |i| try w.print(".{s}", .{fieldName(it, v.ty, i)}),
        .aggregate => |vs| if (typefn.structOf(it, v.ty)) |s| {
            try w.writeAll(".{ ");
            for (s.fields, vs, 0..) |f, x, i| {
                if (i > 0) try w.writeAll(", ");
                try w.print("{s}: ", .{f.name});
                try writeDisplayValue(w, it, x);
            }
            try w.writeAll(" }");
        } else try displayList(w, it, vs),
        .slice => |vs| try displayList(w, it, vs),
        .variant => |x| {
            if (isOption(types, v.ty) and x.index == 0) return displayList(w, it, x.payload);
            try w.print(".{s}", .{variantAt(it, v.ty, x.index)});
            if (x.payload.len > 0) {
                try w.writeByte('(');
                for (x.payload, 0..) |p, i| {
                    if (i > 0) try w.writeAll(", ");
                    try writeDisplayValue(w, it, p);
                }
                try w.writeByte(')');
            }
        },
    }
}

fn writeAll(w: *Writer, it: *Items, vs: []const Value) Writer.Error!void {
    for (vs, 0..) |x, i| {
        if (i > 0) try w.writeByte('_');
        try writeValue(w, it, x);
    }
}

fn displayList(w: *Writer, it: *Items, vs: []const Value) Writer.Error!void {
    try w.writeByte('[');
    for (vs, 0..) |x, i| {
        if (i > 0) try w.writeAll(", ");
        try writeDisplayValue(w, it, x);
    }
    try w.writeByte(']');
}

/// An integer of type `ty` (encoded as in `Value`) in decimal, `m` for minus.
fn writeInt(w: *Writer, types: *Types, ptr_bits: u8, ty: TypeId, bits: u64) Writer.Error!void {
    const x = intOf(types, ptr_bits, ty, bits);
    if (x < 0) try w.writeByte('m');
    try w.print("{d}", .{@abs(x)});
}

fn writeSigned(w: *Writer, types: *Types, ptr_bits: u8, ty: TypeId, bits: u64) Writer.Error!void {
    try w.print("{d}", .{intOf(types, ptr_bits, ty, bits)});
}

fn intOf(types: *Types, ptr_bits: u8, ty: TypeId, bits: u64) i128 {
    const signed = if (convert.intInfo(types, ptr_bits, ty)) |info| info.signedness == .signed else false;
    return if (signed) @as(i64, @bitCast(bits)) else bits;
}

/// A float in decimal with `p` for the point and `m` for minus: `1.5` is `1p5`.
fn writeFloat(w: *Writer, x: f64) Writer.Error!void {
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{x}) catch unreachable; // 64 bytes hold any f64
    for (s) |ch| try w.writeByte(switch (ch) {
        '-' => 'm',
        '.' => 'p',
        else => ch,
    });
}

/// `s` with every byte that is not an identifier character as `_`.
fn writeIdent(w: *Writer, s: []const u8) Writer.Error!void {
    for (s) |ch| try w.writeByte(if (std.ascii.isAlphanumeric(ch) or ch == '_') ch else '_');
}

fn isOption(types: *Types, ty: TypeId) bool {
    return switch (types.get(ty)) {
        .nominal => |n| n.lang == .option,
        else => false,
    };
}

/// The variant of payload-free enum `ty` with discriminant `bits`, if `ty`
/// is a declared enum.
fn variantName(it: *Items, ty: TypeId, bits: u64) ?[]const u8 {
    const e = it.enumOf(ty) orelse return null;
    for (e.variants) |x| if (x.discriminant.bits == bits) return x.name;
    return null;
}

/// The name of variant `index` of enum `ty` (`Option`: `some`, `none`;
/// `Result`: `ok`, `err`).
fn variantAt(it: *Items, ty: TypeId, index: u32) []const u8 {
    if (it.enumOf(ty)) |e| if (index < e.variants.len) return e.variants[index].name;
    return switch (it.types.get(ty)) {
        .nominal => |n| switch (n.lang) {
            .option => if (index == 0) "some" else "none",
            .result => if (index == 0) "ok" else "err",
            else => "variant",
        },
        else => "variant",
    };
}

/// The name of field `index` of the owner of `FieldId` type `ty`.
fn fieldName(it: *Items, ty: TypeId, index: u32) []const u8 {
    const owner = it.types.get(ty).field_id.owner;
    const s = typefn.structOf(it, owner) orelse return "field";
    return if (index < s.fields.len) s.fields[index].name else "field";
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const Fixture = @import("../sema/comptime_ctx.zig").Fixture;

fn typeOf(f: *Fixture, name: []const u8) !TypeId {
    return switch ((try f.items.info(.{ .module = 0, .item = f.g.modules[0].names.get(name).? })).*) {
        .@"struct" => |s| s.type,
        .@"enum" => |e| e.type,
        else => error.TestUnexpectedResult,
    };
}

test "§8.3.2: Table(Monster, .{ sorted_by: .threat, .. }) is Table__Monster__sorted_by_threat" {
    var f: Fixture = undefined;
    try f.init(
        \\struct Monster { health: f32, threat: u32 }
        \\struct Config { sorted_by: u32 = 0, capacity: usize = 0, stable: bool = true }
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    const a = f.items.arena.allocator();
    const monster = try typeOf(&f, "Monster");
    const config = try typeOf(&f, "Config");
    const fid = try f.types.intern(.{ .field_id = .{ .owner = monster } });
    // `sorted_by` holds a field id here; the other fields are at their default.
    const cfg = [_]Value{ .{ .ty = fid, .data = .{ .field_id = 1 } }, .{ .ty = .usize, .data = .{ .scalar = 0 } }, .boolean(true) };
    const args = [_]Value{ .{ .ty = .type, .data = .{ .type = monster } }, .{ .ty = config, .data = .{ .aggregate = &cfg } } };
    try testing.expectEqualStrings("Table__Monster__sorted_by_threat", try mangled(a, &f.items, "Table", &args));
    try testing.expectEqualStrings("Table(Monster, .{ sorted_by: .threat, capacity: 0, stable: true })", try display(a, &f.items, "Table", &args));
    // A field away from its default is kept.
    const cfg2 = [_]Value{ cfg[0], .{ .ty = .usize, .data = .{ .scalar = 64 } }, .boolean(false) };
    const args2 = [_]Value{ args[0], .{ .ty = config, .data = .{ .aggregate = &cfg2 } } };
    try testing.expectEqualStrings("Table__Monster__sorted_by_threat_capacity_64_stable_f", try mangled(a, &f.items, "Table", &args2));
}

test "§8.3.2: integers, negatives, bools, enums and types" {
    var f: Fixture = undefined;
    try f.init(
        \\enum Mode { fast, slow }
        \\struct P { x: u8 }
    );
    defer f.deinit();
    const a = f.items.arena.allocator();
    const mode = try typeOf(&f, "Mode");
    const arr = try f.types.intern(.{ .array = .{ .len = 4, .elem = .int(.unsigned, 8) } });
    const args = [_]Value{
        Value.int(f.items.types, 64, .int(.signed, 32), -12).?,
        Value.int(f.items.types, 64, .usize, 512).?,
        .boolean(true),
        .boolean(false),
        .{ .ty = mode, .data = .{ .scalar = 1 } },
        .{ .ty = .type, .data = .{ .type = try typeOf(&f, "P") } },
        .{ .ty = .type, .data = .{ .type = arr } },
        .{ .ty = .type, .data = .{ .type = .f32 } },
    };
    try testing.expectEqualStrings("F__m12__512__t__f__slow__P__arr4_u8__f32", try mangled(a, &f.items, "F", &args));
    try testing.expectEqualStrings("F(-12, 512, true, false, .slow, P, [4]u8, f32)", try display(a, &f.items, "F", &args));
    try testing.expectEqualStrings("F", try mangled(a, &f.items, "F", &.{}));
    try testing.expectEqualStrings("F()", try display(a, &f.items, "F", &.{}));
}
