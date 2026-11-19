//! The attribute table (§8.8, §3.3): every attribute the language defines,
//! the positions it may appear in and the arguments it takes. This is the
//! single list of attributes. The post-parse check (`parse/check.zig`)
//! reports names missing from it (E0202) and attributes in a position the
//! table does not list (E0203). Later stages (comptime evaluation of
//! attribute arguments, layout, GPU, codegen) look attributes up here and add
//! their semantics in their own files, never rows.
//!
//! Frozen API (T026 GATE): `Attr`, `Position`, `Info`, `Arg`, `ArgKind`,
//! `Requirement`, `lookup`, `info`.

const std = @import("std");
const Ast = @import("ast/Ast.zig");

/// Every §8.8 attribute, named as written without the `@`.
pub const Attr = enum {
    soa,
    @"align",
    @"packed",
    c_layout,
    cold,
    resource,
    @"test",
    bench,
    trap_handler,
    law,
    requires,
    ensures,
    invariant,
    no_alloc,
    allocates,
    append_only,
    pure,
    @"inline",
    no_inline,
    fast_math,
    simd,
    gpu_kernel,
    gpu_vertex,
    gpu_fragment,
    gpu_task,
    gpu_mesh,
    gpu_ray_gen,
    gpu_miss,
    gpu_closest_hit,
    gpu_any_hit,
    gpu_intersection,
    position,
    flat,
    linear,
    target,
    depth,
    instance,
    task_payload,
    per_primitive,
    primitive_id,
    layer,
    viewport_index,
    cull_primitive,
    @"export",
    unsafe,
    workgroup,
    link,
    deprecated,
    doc_hidden,
    allow,
    deny,
};

/// A place an attribute can be written (§3.3): an item of a given kind (struct
/// and enum members are `fn`/`const` items too), a field, an enum variant, a
/// parameter, a loop statement or a `let` statement.
pub const Position = enum {
    use,
    @"const",
    type,
    @"fn",
    @"struct",
    @"enum",
    protocol,
    impl,
    extern_block,
    comptime_block,
    field,
    variant,
    param,
    let,
    @"for",
    inline_for,
    @"while",
    parallel_for,

    /// Position of an attribute on a node of kind `kind` (the `inner` of an
    /// `attributed` node), or null for a kind no attribute is written on.
    pub fn of(kind: Ast.NodeKind) ?Position {
        return switch (kind) {
            .use, .use_list => .use,
            .const_decl => .@"const",
            .type_alias, .type_distinct => .type,
            .fn_decl => .@"fn",
            .struct_decl => .@"struct",
            .enum_decl => .@"enum",
            .protocol_decl => .protocol,
            .impl_decl => .impl,
            .extern_block => .extern_block,
            .comptime_block => .comptime_block,
            .field_decl => .field,
            .variant_decl => .variant,
            .param => .param,
            .let => .let,
            .@"for" => .@"for",
            .for_inline => .inline_for,
            .@"while" => .@"while",
            .parallel_for => .parallel_for,
            else => null,
        };
    }

    /// How diagnostics name the position ("on a function").
    pub fn describe(p: Position) []const u8 {
        return switch (p) {
            .use => "a `use` declaration",
            .@"const" => "a constant",
            .type => "a type declaration",
            .@"fn" => "a function",
            .@"struct" => "a struct",
            .@"enum" => "an enum",
            .protocol => "a protocol",
            .impl => "an `impl` block",
            .extern_block => "an `extern` block",
            .comptime_block => "a `comptime` block",
            .field => "a field",
            .variant => "an enum variant",
            .param => "a parameter",
            .let => "a `let` statement",
            .@"for" => "a `for` loop",
            .inline_for => "an `inline for` loop",
            .@"while" => "a `while` loop",
            .parallel_for => "a `parallel_for` loop",
        };
    }
};

pub const Positions = std.EnumSet(Position);

/// What an argument must evaluate to. Checking it is comptime's job (§8.1:
/// attribute arguments are comptime contexts), except `condition`, whose
/// meaning is given by the contract rules (§9.5).
pub const ArgKind = enum {
    /// A comptime integer.
    int,
    /// A comptime `u32` or 3-tuple `(x, y, z)` (§11.1.1).
    workgroup,
    /// A `bool` expression over the parameters, `self` and `result` (§9.5).
    condition,
    /// A comptime string.
    string,
    /// A warning code such as `W0201` (A.2).
    diag_code,
    /// A trap kind enum literal such as `.bounds` (§13.6).
    trap_kind,
};

/// One argument of an attribute. Named arguments are written `name: value`;
/// positional ones are written in table order.
pub const Arg = struct {
    name: []const u8,
    named: bool,
    kind: ArgKind,
    optional: bool = false,
};

/// A condition on the declaration beyond its position.
pub const Requirement = enum {
    none,
    /// The function is `pub` (`@trap_handler`, `@export`).
    pub_fn,
    /// The function's first parameter is `mut self` (`@append_only`).
    mut_self_method,
};

/// One row of the table.
pub const Info = struct {
    positions: Positions,
    /// Empty: written without parentheses.
    args: []const Arg = &.{},
    requires: Requirement = .none,
};

/// The attribute named `name` (without `@`), or null if §8.8 has none (E0202).
pub fn lookup(name: []const u8) ?Attr {
    return std.meta.stringToEnum(Attr, name);
}

/// The table row of `a`.
pub fn info(a: Attr) Info {
    return table.get(a);
}

fn at(comptime ps: []const Position) Positions {
    return .initMany(ps);
}

fn pos(n: []const u8, k: ArgKind) Arg {
    return .{ .name = n, .named = false, .kind = k };
}

fn posOpt(n: []const u8, k: ArgKind) Arg {
    return .{ .name = n, .named = false, .kind = k, .optional = true };
}

fn named(n: []const u8, k: ArgKind) Arg {
    return .{ .name = n, .named = true, .kind = k };
}

fn namedOpt(n: []const u8, k: ArgKind) Arg {
    return .{ .name = n, .named = true, .kind = k, .optional = true };
}

const fn_only: Info = .{ .positions = at(&.{.@"fn"}) };
const field_only: Info = .{ .positions = at(&.{.field}) };
const param_only: Info = .{ .positions = at(&.{.param}) };
/// "any item" (§8.8): every item kind, members included.
const any_item = at(&.{ .use, .@"const", .type, .@"fn", .@"struct", .@"enum", .protocol, .impl, .extern_block, .comptime_block });
const contract = &[_]Arg{ pos("cond", .condition), posOpt("msg", .string) };
/// `workgroup` defaults to 64 (§11.1.1).
const workgroup_arg = &[_]Arg{namedOpt("workgroup", .workgroup)};

const table: std.EnumArray(Attr, Info) = .init(.{
    .soa = .{ .positions = at(&.{.@"struct"}) },
    .@"align" = .{ .positions = at(&.{ .@"struct", .field }), .args = &.{pos("n", .int)} },
    .@"packed" = .{ .positions = at(&.{.@"struct"}) },
    .c_layout = .{ .positions = at(&.{ .@"struct", .@"enum" }) },
    .cold = field_only,
    .resource = .{ .positions = at(&.{.@"struct"}) },
    .@"test" = .{ .positions = at(&.{.@"fn"}), .args = &.{namedOpt("traps", .trap_kind)} },
    .bench = fn_only,
    .trap_handler = .{ .positions = at(&.{.@"fn"}), .requires = .pub_fn },
    .law = .{ .positions = at(&.{.@"fn"}), .args = &.{namedOpt("cases", .int)} },
    .requires = .{ .positions = at(&.{.@"fn"}), .args = contract },
    .ensures = .{ .positions = at(&.{.@"fn"}), .args = contract },
    .invariant = .{ .positions = at(&.{.@"struct"}), .args = contract },
    .no_alloc = fn_only,
    .allocates = fn_only,
    .append_only = .{ .positions = at(&.{.@"fn"}), .requires = .mut_self_method },
    .pure = fn_only,
    .@"inline" = fn_only,
    .no_inline = fn_only,
    .fast_math = fn_only,
    .simd = .{ .positions = at(&.{.@"for"}) },
    .gpu_kernel = .{ .positions = at(&.{.@"fn"}), .args = workgroup_arg },
    .gpu_vertex = fn_only,
    .gpu_fragment = fn_only,
    .gpu_task = .{ .positions = at(&.{.@"fn"}), .args = workgroup_arg },
    .gpu_mesh = .{ .positions = at(&.{.@"fn"}), .args = &.{
        namedOpt("workgroup", .workgroup),
        named("max_vertices", .int),
        named("max_primitives", .int),
    } },
    .gpu_ray_gen = fn_only,
    .gpu_miss = fn_only,
    .gpu_closest_hit = fn_only,
    .gpu_any_hit = fn_only,
    .gpu_intersection = fn_only,
    .position = field_only,
    .flat = field_only,
    .linear = field_only,
    .target = .{ .positions = at(&.{.field}), .args = &.{pos("n", .int)} },
    .depth = field_only,
    .instance = param_only,
    .task_payload = param_only,
    .per_primitive = param_only,
    .primitive_id = field_only,
    .layer = field_only,
    .viewport_index = field_only,
    .cull_primitive = field_only,
    .@"export" = .{ .positions = at(&.{.@"fn"}), .args = &.{posOpt("name", .string)}, .requires = .pub_fn },
    .unsafe = fn_only,
    .workgroup = .{ .positions = at(&.{.let}) },
    .link = .{ .positions = at(&.{.extern_block}), .args = &.{pos("name", .string)} },
    .deprecated = .{ .positions = any_item, .args = &.{pos("msg", .string)} },
    .doc_hidden = .{ .positions = any_item },
    .allow = .{ .positions = any_item, .args = &.{pos("code", .diag_code)} },
    .deny = .{ .positions = any_item, .args = &.{pos("code", .diag_code)} },
});

const testing = std.testing;

test "lookup finds every §8.8 attribute and nothing else" {
    try testing.expectEqual(Attr.soa, lookup("soa").?);
    try testing.expectEqual(Attr.@"align", lookup("align").?);
    try testing.expectEqual(Attr.gpu_intersection, lookup("gpu_intersection").?);
    try testing.expectEqual(null, lookup("frobnicate"));
    try testing.expectEqual(null, lookup("Simd")); // case matters
    try testing.expectEqual(null, lookup("@simd"));
    try testing.expectEqual(51, std.enums.values(Attr).len);
}

test "positions, arguments and requirements" {
    try testing.expect(info(.soa).positions.contains(.@"struct"));
    try testing.expect(!info(.soa).positions.contains(.@"fn"));
    try testing.expect(info(.simd).positions.contains(.@"for"));
    try testing.expect(!info(.simd).positions.contains(.@"while"));
    try testing.expect(info(.deprecated).positions.contains(.impl));
    try testing.expect(!info(.deprecated).positions.contains(.field));
    try testing.expectEqual(3, info(.gpu_mesh).args.len);
    try testing.expect(info(.gpu_mesh).args[0].optional and !info(.gpu_mesh).args[1].optional);
    try testing.expect(info(.@"test").args[0].named);
    try testing.expectEqual(Requirement.pub_fn, info(.@"export").requires);
    try testing.expectEqual(0, info(.bench).args.len);
    try testing.expectEqual(Position.inline_for, Position.of(.for_inline).?);
    try testing.expectEqual(null, Position.of(.binary));
}
