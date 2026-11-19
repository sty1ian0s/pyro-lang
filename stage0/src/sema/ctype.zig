//! C-compatible type predicate (§12.5). Sema reports **E1201** where it is
//! false: on `extern` block and `@export` signatures (§12.6) and on the
//! fields of a `@c_layout` struct (§4.11.3).
//!
//! The table in §12.5 is exhaustive. Everything else (`str`, slices, tuples,
//! `Option`, handles, vectors, distinct types, comptime-only types, generic
//! parameters) is not C-compatible.

const std = @import("std");
const Types = @import("types.zig");
const TypeId = Types.TypeId;

/// Where a type is written; some rows of §12.5 are position-dependent.
pub const Site = struct {
    pos: Pos,
    /// Written inside an `extern` block, where `fn(...)` types are C
    /// function pointers (§12.5, last row).
    in_extern: bool = false,

    pub const Pos = enum {
        /// A function parameter.
        param,
        /// A function result: the only place `void` is allowed.
        ret,
        /// A `@c_layout` struct field: the only place `[N]T` is allowed, and
        /// sub-byte integers are stored in their storage size (§4.11.3).
        field,
    };
};

/// Reports whether `id`, written at `site`, is C-compatible (§12.5).
///
/// `decls` answers for nominal types, which the type table does not
/// describe: `decls.isCLayout(id) bool` must return true exactly for
/// `@c_layout` structs and payload-free `@c_layout` enums with an explicit
/// `: iN`/`uN` backing. The fields of such a struct are checked at its
/// declaration, not here.
///
/// `.err` counts as compatible, so a failed type gives no cascade E1201.
pub fn isCompatible(types: *Types, id: TypeId, site: Site, decls: anytype) bool {
    return switch (types.get(id)) {
        .simple => |s| switch (s) {
            .bool, .isize, .usize, .f32, .f64, .err => true,
            .void => site.pos == .ret,
            else => false,
        },
        .int => |i| site.pos == .field or switch (i.bits) {
            8, 16, 32, 64 => true,
            else => false,
        },
        // C sees only the address, so any pointee is allowed.
        .ptr => true,
        .array => |a| site.pos == .field and isCompatible(types, a.elem, site, decls),
        .fn_ptr => |f| site.in_extern and isCompatible(types, f.ret, .{ .pos = .ret, .in_extern = true }, decls) and
            for (f.params) |p| {
                if (p.mode != .value or !isCompatible(types, p.type, .{ .pos = .param, .in_extern = true }, decls)) break false;
            } else true,
        .nominal => |n| (n.kind == .@"struct" or n.kind == .@"enum") and decls.isCLayout(id),
        .vec, .mask, .soa_array, .slice, .soa_slice, .tuple, .handle, .mut_view, .field_id, .param => false,
    };
}

const testing = std.testing;
const Interner = @import("../base/Interner.zig");

/// Test `decls`: a fixed set of `@c_layout` declarations.
const CLayouts = struct {
    ids: []const TypeId,

    pub fn isCLayout(c: CLayouts, id: TypeId) bool {
        return std.mem.indexOfScalar(TypeId, c.ids, id) != null;
    }
};

test "C-compatible type table (§12.5)" {
    var strings: Interner = .init(testing.allocator, testing.io);
    defer strings.deinit();
    var types: Types = try .init(testing.allocator, testing.io, &strings);
    defer types.deinit();
    const t = &types;

    const app: Types.Package = .{ .name = try strings.intern("app"), .line = .{ .major = 1 } };
    const nominal = struct {
        fn f(tt: *Types, s: *Interner, pkg: Types.Package, index: u32, kind: Types.NominalKind, name: []const u8, lang: Types.Lang, args: []const Types.Arg) !TypeId {
            return tt.intern(.{ .nominal = .{ .decl = .{ .package = pkg, .index = index }, .args = args, .kind = kind, .name = try s.intern(name), .lang = lang } });
        }
    }.f;
    const u8_ = TypeId.int(.unsigned, 8);
    const i32_ = TypeId.int(.signed, 32);
    const vec2 = try nominal(t, &strings, app, 0, .@"struct", "Vec2", .none, &.{}); // @c_layout
    const mode = try nominal(t, &strings, app, 1, .@"enum", "Mode", .none, &.{}); // @c_layout enum: u8
    const plain = try nominal(t, &strings, app, 2, .@"struct", "Plain", .none, &.{});
    const option = try nominal(t, &strings, app, 3, .@"enum", "Option", .option, &.{.{ .type = try t.intern(.{ .ptr = .{ .elem = u8_, .is_const = false } }) }});
    const meters = try t.intern(.{ .nominal = .{ .decl = .{ .package = app, .index = 4 }, .kind = .distinct, .name = try strings.intern("Meters"), .underlying = .f32 } });
    const decls: CLayouts = .{ .ids = &.{ vec2, mode, meters } };

    const ptr_const_u8 = try t.intern(.{ .ptr = .{ .elem = u8_, .is_const = true } });
    const cmp: Types.Key = .{ .fn_ptr = .{ .params = &.{ .{ .type = ptr_const_u8 }, .{ .type = ptr_const_u8 } }, .ret = i32_ } };

    const param: Site = .{ .pos = .param };
    const ret: Site = .{ .pos = .ret };
    const field: Site = .{ .pos = .field };
    const ext: Site = .{ .pos = .param, .in_extern = true };

    const cases = [_]struct { Types.Key, Site, bool }{
        // Scalars.
        .{ .{ .simple = .bool }, param, true },
        .{ .{ .simple = .isize }, param, true },
        .{ .{ .simple = .usize }, ret, true },
        .{ .{ .simple = .f32 }, param, true },
        .{ .{ .simple = .f64 }, field, true },
        .{ .{ .int = .{ .signedness = .signed, .bits = 8 } }, param, true },
        .{ .{ .int = .{ .signedness = .unsigned, .bits = 16 } }, param, true },
        .{ .{ .int = .{ .signedness = .signed, .bits = 32 } }, ret, true },
        .{ .{ .int = .{ .signedness = .unsigned, .bits = 64 } }, param, true },
        .{ .{ .int = .{ .signedness = .unsigned, .bits = 7 } }, param, false },
        .{ .{ .int = .{ .signedness = .signed, .bits = 24 } }, ret, false },
        .{ .{ .int = .{ .signedness = .unsigned, .bits = 3 } }, field, true },
        // void: result only.
        .{ .{ .simple = .void }, ret, true },
        .{ .{ .simple = .void }, param, false },
        .{ .{ .simple = .void }, field, false },
        .{ .{ .simple = .noreturn }, ret, false },
        // Pointers, any pointee.
        .{ .{ .ptr = .{ .elem = u8_, .is_const = false } }, param, true },
        .{ .{ .ptr = .{ .elem = vec2, .is_const = true } }, ret, true },
        .{ .{ .ptr = .{ .elem = plain, .is_const = false } }, field, true },
        // `[N]T`: struct field only, element C-compatible.
        .{ .{ .array = .{ .len = 16, .elem = u8_ } }, field, true },
        .{ .{ .array = .{ .len = 4, .elem = vec2 } }, field, true },
        .{ .{ .array = .{ .len = 16, .elem = u8_ } }, param, false },
        .{ .{ .array = .{ .len = 16, .elem = u8_ } }, ret, false },
        .{ .{ .array = .{ .len = 2, .elem = .str } }, field, false },
        // Function pointers: only inside an `extern` block, C-compatible
        // signature, value parameters.
        .{ cmp, ext, true },
        .{ cmp, .{ .pos = .ret, .in_extern = true }, true },
        .{ cmp, param, false },
        .{ .{ .fn_ptr = .{ .params = &.{}, .ret = .void } }, ext, true },
        .{ .{ .fn_ptr = .{ .params = &.{.{ .type = .str }}, .ret = .void } }, ext, false },
        .{ .{ .fn_ptr = .{ .params = &.{.{ .type = i32_ }}, .ret = .str } }, ext, false },
        .{ .{ .fn_ptr = .{ .params = &.{.{ .type = .void }}, .ret = .void } }, ext, false },
        .{ .{ .fn_ptr = .{ .params = &.{.{ .type = i32_, .mode = .mut }}, .ret = .void } }, ext, false },
        // Nominal: only `@c_layout` structs and enums.
        .{ .{ .simple = vec2 }, param, true },
        .{ .{ .simple = mode }, ret, true },
        .{ .{ .simple = vec2 }, field, true },
        .{ .{ .simple = plain }, param, false },
        .{ .{ .simple = option }, param, false },
        .{ .{ .simple = option }, field, false },
        .{ .{ .simple = meters }, param, false },
        // Never C-compatible.
        .{ .{ .simple = .str }, param, false },
        .{ .{ .simple = .str }, field, false },
        .{ .{ .slice = .{ .elem = u8_ } }, param, false },
        .{ .{ .slice = .{ .elem = u8_ } }, field, false },
        .{ .{ .soa_slice = .{ .elem = vec2 } }, param, false },
        .{ .{ .soa_array = .{ .len = 4, .elem = vec2 } }, field, false },
        .{ .{ .tuple = .{ .elems = &.{ i32_, i32_ } } }, ret, false },
        .{ .{ .vec = .{ .len = 4, .elem = .f32 } }, param, false },
        .{ .{ .mask = .{ .len = 4 } }, param, false },
        .{ .{ .handle = .{ .elem = vec2 } }, param, false },
        .{ .{ .mut_view = .{ .elem = vec2 } }, param, false },
        .{ .{ .field_id = .{ .owner = vec2 } }, param, false },
        .{ .{ .param = .{ .owner = .{ .package = app, .index = 9 }, .index = 0, .name = try strings.intern("T") } }, param, false },
        .{ .{ .simple = .type }, param, false },
        .{ .{ .simple = .untyped_int }, param, false },
        .{ .{ .simple = .untyped_float }, param, false },
        .{ .{ .simple = .fn_ref }, param, false },
        // A failed type gives no cascade.
        .{ .{ .simple = .err }, param, true },
    };
    for (cases) |c| {
        const id = try t.intern(c[0]);
        if (isCompatible(t, id, c[1], decls) != c[2]) {
            const s = try t.allocPrint(testing.allocator, id, .{});
            defer testing.allocator.free(s);
            std.debug.print("{s} at {t} (in_extern={}): expected {}\n", .{ s, c[1].pos, c[1].in_extern, c[2] });
            return error.TestUnexpectedResult;
        }
    }
}
