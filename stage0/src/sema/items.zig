//! Item declaration checking, the first part of type checking (B.1 stage 4).
//!
//! `check` gives every item of a package its type-level meaning and reports
//! the item-level rules:
//!
//! - functions: signatures, parameter modes and defaults (§7.2.1-§7.2.3,
//!   E0370);
//! - structs: field types, visibility and defaults (§7.3.1, §7.3.3, E0370),
//!   associated consts and methods; recursive containment by value (E0376);
//! - enums: variants, payloads, discriminants and backing type (§7.4,
//!   §4.11.4, E0309, E0377);
//! - aliases and distinct types (§4.7);
//! - consts: type, value (untyped constants stay untyped, §7.7) and allowed
//!   types (§5.9, E0341);
//! - count limits (§4.12, E0311: fields and variants; the size limit is
//!   layout's);
//! - the entry point of an executable (§7.2.6).
//!
//! Type expressions are resolved through the name resolutions of
//! `resolve/names.zig` (`resolveType`). Comptime expressions in item
//! positions (const initializers, defaults, discriminants, array lengths,
//! value generic arguments) are folded here when they are literals, consts
//! and operators on them; anything else goes to `Options.comptime_hook`,
//! the seam for the comptime evaluator (`comptime_ctx.zig`), and stays `.unknown`
//! without it.
//!
//! Every item is checked lazily, at most once, so items may refer to each
//! other in any order (§7.10). The result answers the declaration queries
//! of later checker passes: `info`, `structOf`, `enumOf`, `declRef`,
//! `signature`, `constValue`, `evalConst` and `resolveType`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const diag = @import("../diag/diag.zig");
const Ast = @import("../ast/Ast.zig");
const literals = @import("../lex/literals.zig");
const Types = @import("types.zig");
const convert = @import("convert.zig");
const collect = @import("../resolve/collect.zig");
const module_graph = @import("../resolve/module_graph.zig");
const imports = @import("../resolve/imports.zig");
const names_mod = @import("../resolve/names.zig");
const prelude = @import("../resolve/prelude.zig");
const attr_table = @import("../attr_table.zig");
const type_kinds = @import("kinds.zig");
const layout_soa = @import("layout_soa.zig");
const tir = @import("../tir/tir.zig");
const instantiate = @import("../comptime/instantiate.zig");
const generics_mod = @import("generics.zig");

const Node = Ast.Node;
const TypeId = Types.TypeId;
const ModuleId = module_graph.ModuleId;
const Ref = imports.Ref;
const Target = imports.Target;
const Imports = imports.Imports;
const Names = names_mod.Names;
const Error = Allocator.Error;

/// Maximum fields per struct and variants per enum (§4.12).
pub const max_members = 65_535;

/// A comptime value of an item position.
pub const Value = union(enum) {
    /// Comptime, but not folded here: left to the comptime evaluator.
    unknown,
    /// An untyped constant (§4.8).
    untyped: convert.Const,
    /// A typed scalar: an integer, `bool` or float (IEEE bits), or an enum
    /// value (its discriminant), in the encoding of `Types.Value`.
    scalar: Types.Value,
    /// A type (`const ELEM: type = u32;`).
    type: TypeId,
    /// Any other value of type `type` computed by the comptime evaluator
    /// (an array, struct, `str`...): entry `id` of its value table
    /// (`comptime_ctx.zig`).
    computed: struct { type: TypeId, id: tir.ComptimeId },
};

/// Evaluates comptime expressions this file does not fold (calls, literals
/// of aggregates, strings...). Installed by the comptime driver
/// (`comptime_ctx.zig`).
pub const ComptimeHook = struct {
    ctx: ?*anyopaque = null,
    /// The value of expression `node` of module `m`, where a value of
    /// `expected` (or `.none`) is wanted; null if it cannot be evaluated.
    eval: *const fn (ctx: ?*anyopaque, items: *Items, m: ModuleId, node: Node.Index, expected: TypeId) Error!?Value,
};

pub const Options = struct {
    /// The package being checked: the identity of its nominal types (§13.4).
    package: Types.Package,
    /// Width of `usize`/`isize` on the target.
    ptr_bits: u8 = 64,
    comptime_hook: ?ComptimeHook = null,
};

/// Parameter mode (§5.5.2).
pub const Mode = enum { value, mut, move, @"comptime" };

/// One function parameter.
pub const Param = struct {
    /// The `param` node.
    node: Node.Index,
    /// `self` for the receiver.
    name: []const u8,
    mode: Mode,
    is_self: bool,
    type: TypeId,
    /// The default value (§7.2.3); null without a default.
    default: ?Value,
};

/// A function signature (§7.2.1).
pub const Fn = struct {
    /// The `fn_decl` node.
    node: Node.Index,
    name: []const u8,
    is_pub: bool,
    /// Generic parameters as `.param` types.
    generics: []const TypeId,
    params: []const Param,
    /// `.void` when `-> R` is omitted.
    ret: TypeId,
    attrs: []const Node.Index,
    /// For a method of an instance of a generic type: that instance, whose
    /// copy of the method a call calls (`generics.zig`); `.none` otherwise.
    instance: TypeId = .none,
};

/// Field visibility (§7.3.3).
pub const Visibility = enum { private, @"pub", pub_mut };

/// One struct field (§7.3.1).
pub const Field = struct {
    /// The `field_decl` node.
    node: Node.Index,
    name: []const u8,
    vis: Visibility,
    type: TypeId,
    /// The default value; null without a default.
    default: ?Value,
    attrs: []const Node.Index,
};

/// A module-level or associated const (§7.7).
pub const Const = struct {
    /// The `const_decl` node.
    node: Node.Index,
    name: []const u8,
    is_pub: bool,
    /// `.untyped_int`/`.untyped_float` for an untyped constant; `.err` if
    /// unknown before comptime evaluation.
    type: TypeId,
    value: Value,
};

/// A struct declaration.
pub const Struct = struct {
    /// The declared type; for a generic declaration, the instance whose
    /// arguments are its own parameters.
    type: TypeId,
    generics: []const TypeId,
    fields: []const Field,
    consts: []const Const,
    methods: []const Fn,
    attrs: []const Node.Index,
};

/// One enum variant.
pub const Variant = struct {
    /// The `variant_decl` node.
    node: Node.Index,
    name: []const u8,
    /// Payload types; empty without parentheses.
    payload: []const TypeId,
    /// The discriminant, typed as the backing type (§4.11.4). Zero if it
    /// could not be evaluated.
    discriminant: Types.Value,
};

/// An enum declaration (§7.4).
pub const Enum = struct {
    /// See `Struct.type`.
    type: TypeId,
    generics: []const TypeId,
    /// The discriminant type: the explicit `: B`, else the smallest of
    /// `u8`/`u16`/`u32` that holds every discriminant (§4.11.4).
    backing: TypeId,
    /// The backing type was written (`enum E: u8`); such an enum is never a
    /// bit field (§4.11.2).
    explicit_backing: bool = false,
    has_payload: bool,
    variants: []const Variant,
    consts: []const Const,
    methods: []const Fn,
    attrs: []const Node.Index,
};

/// What an item declares.
pub const Info = union(enum) {
    /// Not checked yet, or on a declaration cycle.
    pending,
    @"const": Const,
    /// `type A = T`: the type `T` (§4.7).
    alias: TypeId,
    /// `type D = distinct T`: the nominal type `D`.
    distinct: TypeId,
    /// A function or `extern` function.
    @"fn": Fn,
    @"struct": Struct,
    @"enum": Enum,
    /// The protocol's nominal type; members are `protocols.zig`'s.
    protocol: TypeId,
};

/// The entry-point form of an executable (§7.2.6).
pub const Main = enum { void, u8, result };

const State = enum { todo, active, done };

const GenericParam = struct {
    /// The interned `.param` type.
    type: TypeId,
    /// Null until computed; `.none` for a type parameter, else the type of
    /// a value parameter (§7.6.1).
    value_type: ?TypeId = null,
};

/// Per-module state.
const Mod = struct {
    /// Declaration index of node 0: a declaration's `Types.Decl.index` is
    /// `base` plus its node index, unique in the package.
    base: u32,
    infos: []Info,
    states: []State,
    /// Item index of each top-level declaration node.
    item_of: std.AutoHashMapUnmanaged(Node.Index, u32) = .empty,
    /// Attributes of every attributed declaration, member, field and variant.
    attrs: std.AutoHashMapUnmanaged(Node.Index, []const Node.Index) = .empty,
    params: std.AutoHashMapUnmanaged(Node.Index, GenericParam) = .empty,
    /// Const values by declaration and instantiation (`instantiate.current`):
    /// a local `const` in an instance body may depend on its bound `comptime`
    /// parameters (§8.2).
    consts: std.AutoHashMapUnmanaged(struct { Node.Index, instantiate.Id }, struct { state: State, c: Const }) = .empty,
    fns: std.AutoHashMapUnmanaged(Node.Index, Fn) = .empty,
    /// The type bound to an `inline for` binding while one copy of the
    /// loop body is checked (`comptime_flow.zig`).
    bound: std.AutoHashMapUnmanaged(Node.Index, TypeId) = .empty,
    /// The comptime value bound to an `inline for` binding while one copy
    /// of the loop body is checked (`comptime_flow.zig`).
    bound_values: std.AutoHashMapUnmanaged(Node.Index, Value) = .empty,
};

/// The checked items of one package. Borrows the `Imports`, `Names` and
/// type table.
pub const Items = struct {
    /// Heap-allocated so that big integers in values keep a valid allocator.
    arena: *std.heap.ArenaAllocator,
    sink: *diag.Sink,
    types: *Types,
    im: *const Imports,
    names: *const Names,
    options: Options,
    mods: []Mod,
    /// Package of the not-yet-loaded standard library (T163).
    std_pkg: Types.Package,
    /// The entry point, if the package is an executable with a valid one.
    main: ?Main = null,
    /// Memoized type kinds, owned by `kinds.zig` (arena-backed).
    kinds: type_kinds.Cache = .{},
    /// The instantiation memo table, owned by `comptime/instantiate.zig`
    /// (arena-backed).
    memo: instantiate.Memo = .{},
    /// The instantiation whose body or signature is being checked, if any:
    /// its `comptime` parameters are bound to values (§8.2).
    instance: ?*const instantiate.Frame = null,
    /// Instances of generic declarations, owned by `generics.zig`
    /// (arena-backed).
    generic: generics_mod.State = .{},

    pub fn deinit(it: *Items) void {
        const gpa = it.arena.child_allocator;
        it.arena.deinit();
        gpa.destroy(it.arena);
        it.* = undefined;
    }

    fn alloc(it: *Items) Allocator {
        return it.arena.allocator();
    }

    fn ast(it: *const Items, m: ModuleId) *const Ast {
        return it.im.graph.modules[m].ast;
    }

    /// Checks item `ref` if needed and returns what it declares.
    pub fn info(it: *Items, ref: Ref) Error!*const Info {
        return it.ensure(ref.module, ref.item);
    }

    /// The item declaring nominal type `ty` of this package, if any.
    pub fn declRef(it: *Items, ty: TypeId) ?Ref {
        if (ty == .none) return null;
        const n = switch (it.types.get(ty)) {
            .nominal => |n| n,
            else => return null,
        };
        return it.refOfDecl(n.decl);
    }

    fn refOfDecl(it: *const Items, d: Types.Decl) ?Ref {
        if (!std.meta.eql(d.package, it.options.package)) return null;
        var m = it.mods.len;
        while (m > 0) {
            m -= 1;
            if (it.mods[m].base > d.index) continue;
            const node: Node.Index = .from(d.index - it.mods[m].base);
            const i = it.mods[m].item_of.get(node) orelse return null;
            return .{ .module = @intCast(m), .item = i };
        }
        return null;
    }

    /// The struct declaration behind `ty`, once checked: for an instance of
    /// a generic struct, the instance's own (`generics.zig`), in terms of its
    /// arguments; for a symbolic one (`Ring<T, CAP>`), the template's.
    pub fn structOf(it: *Items, ty: TypeId) ?*const Struct {
        if (it.generic.infos.get(ty)) |i| return if (i.* == .@"struct") &i.@"struct" else null;
        const ref = it.declRef(ty) orelse return null;
        if (it.mods[ref.module].states[ref.item] != .done) return null;
        return switch (it.mods[ref.module].infos[ref.item]) {
            .@"struct" => |*s| s,
            else => null,
        };
    }

    /// The enum declaration behind `ty`, once checked.
    pub fn enumOf(it: *Items, ty: TypeId) ?*const Enum {
        if (it.generic.infos.get(ty)) |i| return if (i.* == .@"enum") &i.@"enum" else null;
        const ref = it.declRef(ty) orelse return null;
        if (it.mods[ref.module].states[ref.item] != .done) return null;
        return switch (it.mods[ref.module].infos[ref.item]) {
            .@"enum" => |*e| e,
            else => null,
        };
    }

    /// The attributes written on declaration, member, field or variant `n`.
    pub fn attrsOf(it: *const Items, m: ModuleId, n: Node.Index) []const Node.Index {
        return it.mods[m].attrs.get(n) orelse &.{};
    }

    fn decl(it: *const Items, m: ModuleId, n: Node.Index) Types.Decl {
        return .{ .package = it.options.package, .index = it.mods[m].base + n.int() };
    }

    // -----------------------------------------------------------------------
    // Diagnostics

    fn tokSpan(it: *const Items, m: ModuleId, t: Ast.TokenIndex) diag.Span {
        const a = it.ast(m);
        const start = a.tokens.items(.start)[t];
        return .{ .file = it.im.graph.modules[m].file, .start = start, .end = start + a.tokens.items(.len)[t] };
    }

    /// Reports at token `t`. `code` is null only for rules without an A.3 code.
    pub fn report(it: *Items, m: ModuleId, t: Ast.TokenIndex, code: ?diag.DiagCode, help: []const []const u8, comptime fmt: []const u8, args: anytype) Error!void {
        try it.sink.emit(.{
            .code = code,
            .severity = if (code) |c| .of(c) else .@"error",
            .message = try std.fmt.allocPrint(it.alloc(), fmt, args),
            .spans = &.{.{ .span = it.tokSpan(m, t), .primary = true }},
            .help = help,
        });
    }

    /// `ty` printed into the items arena, for diagnostics.
    pub fn tyName(it: *Items, ty: TypeId) Error![]const u8 {
        return it.types.allocPrint(it.alloc(), ty, .{});
    }

    // -----------------------------------------------------------------------
    // Items

    fn ensure(it: *Items, m: ModuleId, i: u32) Error!*const Info {
        const md = &it.mods[m];
        if (md.states[i] != .todo) return &md.infos[i];
        md.states[i] = .active;
        // An item never sees the bindings of an instantiation that uses it.
        const saved = it.instance;
        it.instance = null;
        defer it.instance = saved;
        const item = it.im.graph.modules[m].items[i];
        const result: Info = switch (item.kind) {
            .@"const" => .{ .@"const" = try it.constValue(m, item.node, .none) },
            .type_alias => .{ .alias = try it.resolveType(m, it.ast(m).data(item.node).type_alias.ty, .none) },
            .type_distinct => .{ .distinct = try it.distinctType(m, i) },
            .@"fn", .extern_fn => .{ .@"fn" = try it.signature(m, item.node, .none) },
            .@"struct" => .{ .@"struct" = try it.structDecl(m, i, try it.selfType(m, i)) },
            .@"enum" => .{ .@"enum" = try it.enumDecl(m, i, try it.selfType(m, i)) },
            .protocol => .{ .protocol = try it.selfType(m, i) },
        };
        md.infos[i] = result;
        md.states[i] = .done;
        return &md.infos[i];
    }

    /// The type named by item `ref` used with generic arguments `args`
    /// (null without `<...>`), written at node `at` of module `m`.
    fn itemType(it: *Items, m: ModuleId, at: Node.Index, ref: Ref, args: ?[]const Node.Index, self_ty: TypeId) Error!TypeId {
        const item = it.im.graph.modules[ref.module].items[ref.item];
        switch (item.kind) {
            .@"struct", .@"enum", .protocol => return it.nominalOf(m, at, ref, args, self_ty),
            .type_alias, .type_distinct => {
                if (args != null or generics(it.ast(ref.module), item.node) != null)
                    return generics_mod.aliasType(it, m, at, ref, args, self_ty);
                if (it.mods[ref.module].states[ref.item] == .active) {
                    try it.report(ref.module, it.ast(ref.module).mainToken(item.node) + 1, .E0376, &.{}, "type `{s}` is defined in terms of itself", .{item.name});
                    return .err;
                }
                return switch ((try it.ensure(ref.module, ref.item)).*) {
                    .alias => |t| t,
                    .distinct => |t| t,
                    else => .err,
                };
            },
            .@"const" => {
                const c = try it.constValue(ref.module, item.node, .none);
                if (c.value == .type) return c.value.type;
                if (c.type == .err) return .err;
            },
            .@"fn", .extern_fn => {},
        }
        try it.report(m, it.ast(m).mainToken(at), null, &.{}, "`{s}` is not a type", .{item.name});
        return .err;
    }

    /// The nominal type of declaration `ref` with arguments `args` written
    /// at `at` in module `m`; an instance of a generic declaration is
    /// instantiated (`generics.zig`).
    pub fn nominalOf(it: *Items, m: ModuleId, at: Node.Index, ref: Ref, args: ?[]const Node.Index, self_ty: TypeId) Error!TypeId {
        const item = it.im.graph.modules[ref.module].items[ref.item];
        const gens = generics(it.ast(ref.module), item.node) orelse &.{};
        const given = args orelse &.{};
        if (given.len != gens.len) {
            try it.report(m, it.ast(m).mainToken(at), null, &.{}, "`{s}` takes {d} generic argument(s), found {d}", .{ item.name, gens.len, given.len });
            return .err;
        }
        const out = try it.alloc().alloc(Types.Arg, gens.len);
        for (gens, given, out) |g, arg, *o| {
            const vt = try it.paramValueType(ref.module, g);
            o.* = try it.genericArg(m, arg, vt, self_ty) orelse return .err;
        }
        const ty = try it.internNominal(ref, out);
        return if (gens.len > 0) generics_mod.instance(it, m, at, ref, ty) else ty;
    }

    fn internNominal(it: *Items, ref: Ref, args: []const Types.Arg) Error!TypeId {
        const item = it.im.graph.modules[ref.module].items[ref.item];
        return it.types.intern(.{ .nominal = .{
            .decl = it.decl(ref.module, item.node),
            .args = args,
            .kind = switch (item.kind) {
                .@"struct" => .@"struct",
                .@"enum" => .@"enum",
                .protocol => .protocol,
                else => unreachable,
            },
            .name = try it.types.strings.intern(item.name),
        } });
    }

    /// The type a declaration has inside its own body (`Self`): a generic
    /// declaration applied to its own parameters.
    fn selfType(it: *Items, m: ModuleId, i: u32) Error!TypeId {
        const node = it.im.graph.modules[m].items[i].node;
        const gens = generics(it.ast(m), node) orelse &.{};
        const args = try it.alloc().alloc(Types.Arg, gens.len);
        for (gens, args) |g, *arg| arg.* = .{ .type = it.mods[m].params.get(g).?.type };
        return it.internNominal(.{ .module = m, .item = i }, args);
    }

    fn distinctType(it: *Items, m: ModuleId, i: u32) Error!TypeId {
        const item = it.im.graph.modules[m].items[i];
        const underlying = try it.resolveType(m, it.ast(m).data(item.node).type_distinct.ty, .none);
        return it.types.intern(.{ .nominal = .{
            .decl = it.decl(m, item.node),
            .kind = .distinct,
            .name = try it.types.strings.intern(item.name),
            .underlying = underlying,
        } });
    }

    /// `.none` if generic parameter `g` of module `m` is a type parameter,
    /// else the type of the value parameter (`CAP: usize`, §7.6.1).
    pub fn paramValueType(it: *Items, m: ModuleId, g: Node.Index) Error!TypeId {
        const gp = it.mods[m].params.getPtr(g).?;
        if (gp.value_type) |t| return t;
        gp.value_type = .none; // also while resolving the bound
        const bounds = it.ast(m).data(g).generic_param.bounds;
        var t: TypeId = .none;
        if (bounds.len == 1 and !std.mem.eql(u8, it.ast(m).tokenSlice(it.ast(m).mainToken(bounds[0])), "plain")) {
            const b = try it.resolveType(m, bounds[0], .none);
            const is_protocol = switch (it.types.get(b)) {
                .nominal => |n| n.kind == .protocol,
                else => b == .err,
            };
            if (!is_protocol) t = b;
        }
        it.mods[m].params.getPtr(g).?.value_type = t;
        return t;
    }

    /// Argument `n` for a generic parameter whose value type is `value_ty`
    /// (`.none` for a type parameter). Null if it cannot be determined. An
    /// unbound value parameter (`CAP` in `Ring<T, CAP>` inside `Ring`) is
    /// symbolic: its `.param` type, as in `selfType`.
    pub fn genericArg(it: *Items, m: ModuleId, n: Node.Index, value_ty: TypeId, self_ty: TypeId) Error!?Types.Arg {
        const a = it.ast(m);
        const inner = if (a.kind(n) == .generic_expr_arg) a.data(n).generic_expr_arg.value else n;
        if (value_ty == .none and inner == n and !isValueArg(a, n)) return .{ .type = try it.resolveType(m, n, self_ty) };
        const want = if (value_ty == .none) TypeId.usize else value_ty;
        const v = try it.coerceValue(m, inner, try it.fold(m, inner, self_ty, want), want);
        return switch (v) {
            .scalar => |s| .{ .value = s },
            else => if (a.kind(inner) == .ident or a.kind(inner) == .path) if (it.names.get(m, inner)) |e| switch (e.res) {
                .local => |l| if (a.kind(l) == .generic_param) .{ .type = it.mods[m].params.get(l).?.type } else null,
                .global => null,
            } else null else null,
        };
    }

    // -----------------------------------------------------------------------
    // Types

    /// The type that type expression `n` of module `m` denotes. `self_ty`
    /// is what `Self` means there (`.none` outside a type). Reports unknown
    /// or non-type names; returns `.err` for anything already reported or
    /// not yet supported (comptime type functions without the hook,
    /// symbolic array lengths in generic bodies).
    pub fn resolveType(it: *Items, m: ModuleId, n: Node.Index, self_ty: TypeId) Error!TypeId {
        const a = it.ast(m);
        return switch (a.data(n)) {
            // A bare name in a builtin argument (`@zero(T)`) is an `ident`.
            .path, .ident => it.pathType(m, n, null, self_ty),
            .generic_inst => |g| it.pathType(m, g.base, g.args, self_ty),
            .paren => |p| it.resolveType(m, p.inner, self_ty),
            .self_type => if (self_ty == .none) .err else self_ty,
            .type_type => .type,
            .tuple => |t| blk: {
                const elems = try it.alloc().alloc(TypeId, t.elems.len);
                for (t.elems, elems) |e, *o| o.* = try it.resolveType(m, e, self_ty);
                break :blk it.types.intern(.{ .tuple = .{ .elems = elems } });
            },
            .array_type => |d| blk: {
                const len = try it.arrayLen(m, d.len, self_ty) orelse break :blk .err;
                break :blk it.types.intern(.{ .array = .{ .len = len, .elem = try it.resolveType(m, d.elem, self_ty) } });
            },
            .soa_array_type => |d| blk: {
                const len = try it.arrayLen(m, d.len, self_ty) orelse break :blk .err;
                break :blk it.types.intern(.{ .soa_array = .{ .len = len, .elem = try layout_soa.elemType(it, m, d.elem, self_ty) } });
            },
            .slice_type => |d| it.types.intern(.{ .slice = .{ .elem = try it.resolveType(m, d.elem, self_ty) } }),
            .soa_slice_type => |d| it.types.intern(.{ .soa_slice = .{ .elem = try layout_soa.elemType(it, m, d.elem, self_ty) } }),
            .ptr_type => |d| it.types.intern(.{ .ptr = .{ .elem = try it.resolveType(m, d.elem, self_ty), .is_const = false } }),
            .ptr_const_type => |d| it.types.intern(.{ .ptr = .{ .elem = try it.resolveType(m, d.elem, self_ty), .is_const = true } }),
            .mut_type => |d| it.types.intern(.{ .mut_view = .{ .elem = try it.resolveType(m, d.elem, self_ty) } }),
            .fn_type => |d| blk: {
                const params = try it.alloc().alloc(Types.FnParam, d.params.len);
                for (d.params, params) |p, *o| o.* = if (a.kind(p) == .param_mode) .{
                    .type = try it.resolveType(m, a.data(p).param_mode.ty, self_ty),
                    .mode = if (a.tokens.items(.kind)[a.mainToken(p)] == .kw_mut) .mut else .move,
                } else .{ .type = try it.resolveType(m, p, self_ty) };
                const ret = if (d.ret) |r| try it.resolveType(m, r, self_ty) else .void;
                break :blk it.types.intern(.{ .fn_ptr = .{ .params = params, .ret = ret } });
            },
            // Type functions, anonymous structs, `@TypeOf(...)`: comptime.
            else => switch (try it.hook(m, n, .type)) {
                .type => |t| t,
                else => .err,
            },
        };
    }

    fn pathType(it: *Items, m: ModuleId, n: Node.Index, args: ?[]const Node.Index, self_ty: TypeId) Error!TypeId {
        const a = it.ast(m);
        const e = it.names.get(m, n) orelse {
            try it.report(m, a.mainToken(n), null, &.{}, "unknown type `{s}`", .{pathText(a, n)});
            return .err;
        };
        // shortcut: associated types (`T.Output`) are resolved by protocols.zig (T044).
        if (e.rest != 0) return .err;
        switch (e.res) {
            .local => |l| switch (a.kind(l)) {
                .generic_param => {
                    if (args != null) return .err;
                    if (instantiate.boundValue(it, m, l)) |v| if (v == .type) return v.type;
                    return it.mods[m].params.get(l).?.type;
                },
                .const_decl => {
                    const c = try it.constValue(m, l, self_ty);
                    if (c.value == .type) return c.value.type;
                    if (c.type == .err) return .err;
                },
                .pat_bind => if (it.mods[m].bound.get(l)) |t| return t,
                else => {},
            },
            .global => |t| switch (t) {
                .item => |ref| return it.itemType(m, n, ref, args, self_ty),
                .prelude => |name| return it.preludeType(m, n, name, args, self_ty),
                .external => |path| return it.stdType(m, path, args, self_ty),
                .unresolved => return .err,
                .module => {},
            },
        }
        try it.report(m, a.mainToken(n), null, &.{}, "`{s}` is not a type", .{pathText(a, n)});
        return .err;
    }

    /// A prelude type name (§14.1) with optional generic arguments.
    fn preludeType(it: *Items, m: ModuleId, n: Node.Index, name: []const u8, args: ?[]const Node.Index, self_ty: TypeId) Error!TypeId {
        const given = args orelse &.{};
        const arity = std.StaticStringMap(usize).initComptime(.{
            .{ "vec", 2 },  .{ "vec2", 1 },   .{ "vec3", 1 },    .{ "vec4", 1 },
            .{ "mask", 1 }, .{ "Handle", 1 }, .{ "FieldId", 1 },
        });
        if (arity.get(name)) |count| {
            if (given.len != count) {
                try it.report(m, it.ast(m).mainToken(n), null, &.{}, "`{s}` takes {d} generic argument(s), found {d}", .{ name, count, given.len });
                return .err;
            }
            if (std.mem.eql(u8, name, "vec") or std.mem.eql(u8, name, "mask")) {
                const len = try it.genericArg(m, given[0], .int(.unsigned, 32), self_ty) orelse return .err;
                const l: u32 = @intCast(len.value.bits);
                if (name.len == 4) return it.types.intern(.{ .mask = .{ .len = l } });
                return it.vecType(m, n, l, try it.resolveType(m, given[1], self_ty));
            }
            const elem = try it.resolveType(m, given[0], self_ty);
            if (name[0] == 'v') return it.vecType(m, n, name[3] - '0', elem);
            if (name[0] == 'H') return it.types.intern(.{ .handle = .{ .elem = elem } });
            return it.types.intern(.{ .field_id = .{ .owner = elem } });
        }
        const simple = std.StaticStringMap(TypeId).initComptime(.{
            .{ "bool", .bool }, .{ "isize", .isize }, .{ "usize", .usize },       .{ "f32", .f32 },
            .{ "f64", .f64 },   .{ "void", .void },   .{ "noreturn", .noreturn }, .{ "str", .str },
        });
        const id: ?TypeId = simple.get(name) orelse if (prelude.isIntTypeName(name))
            TypeId.int(if (name[0] == 'i') .signed else .unsigned, std.fmt.parseInt(u8, name[1..], 10) catch unreachable)
        else
            null;
        if (id) |t| {
            if (args != null) try it.report(m, it.ast(m).mainToken(n), null, &.{}, "`{s}` takes no generic arguments", .{name});
            return t;
        }
        for (prelude.entries, 0..) |entry, i| {
            if (!std.mem.eql(u8, entry.name, name)) continue;
            if (entry.kind != .type and entry.kind != .protocol) break;
            return it.stdNominal(m, @intCast(i), name, entry.kind == .protocol, given, self_ty);
        }
        try it.report(m, it.ast(m).mainToken(n), null, &.{}, "`{s}` is not a type", .{name});
        return .err;
    }

    /// `vec<len, elem>` written at `n`, or E0303 (§4.3.1): `elem` is an
    /// integer of at most 8 bytes, `f32`, `f64` or `bool`, and `1 <= len <= 64`.
    fn vecType(it: *Items, m: ModuleId, n: Node.Index, len: u32, elem: TypeId) Error!TypeId {
        if (elem == .err) return .err;
        const elem_ok = switch (elem) {
            .f32, .f64, .bool, .usize, .isize => true,
            else => switch (it.types.get(elem)) {
                .int => |i| i.bits <= 64,
                .param => true, // checked when instantiated
                else => false,
            },
        };
        const tok = it.ast(m).mainToken(n);
        if (!elem_ok) {
            try it.report(m, tok, .E0303, &.{"use an integer of at most 64 bits, `f32`, `f64` or `bool`"}, "invalid `vec` element type `{s}`", .{try it.tyName(elem)});
            return .err;
        }
        if (len < 1 or len > 64) {
            try it.report(m, tok, .E0303, &.{"a `vec` has 1 to 64 lanes"}, "invalid `vec` length {d}", .{len});
            return .err;
        }
        return it.types.intern(.{ .vec = .{ .len = len, .elem = elem } });
    }

    /// The prelude type `name` (§14.1) applied to `args`: the type that
    /// `name<args>` written in source names.
    pub fn preludeInstance(it: *Items, name: []const u8, args: []const Types.Arg) Error!TypeId {
        for (prelude.entries, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.name, name)) return it.stdInstance(@intCast(i), name, entry.kind == .protocol, args);
        }
        unreachable; // `name` is a prelude type
    }

    /// A type named by a path into `std` or a dependency (`std.fs.File`).
    fn stdType(it: *Items, m: ModuleId, path: []const u8, args: ?[]const Node.Index, self_ty: TypeId) Error!TypeId {
        // shortcut: other packages are not loaded (T163): the type is keyed by
        // a hash of its path and assumed to be a struct; values in `<...>` default to `usize`.
        const index: u32 = @truncate(std.hash.Wyhash.hash(0, path) | 0x8000_0000);
        const name = path[(std.mem.lastIndexOfScalar(u8, path, '.') orelse 0) + 1 ..];
        return it.stdNominal(m, index, name, false, args orelse &.{}, self_ty);
    }

    fn stdNominal(it: *Items, m: ModuleId, index: u32, name: []const u8, is_protocol: bool, args: []const Node.Index, self_ty: TypeId) Error!TypeId {
        const out = try it.alloc().alloc(Types.Arg, args.len);
        for (args, out) |arg, *o| o.* = try it.genericArg(m, arg, .none, self_ty) orelse return .err;
        return it.stdInstance(index, name, is_protocol, out);
    }

    /// `Option<payload>` (§14.1): the type the prelude name `Option`
    /// denotes with argument `payload`.
    pub fn optionOf(it: *Items, payload: TypeId) Error!TypeId {
        return it.preludeInstance("Option", &.{.{ .type = payload }});
    }

    fn stdInstance(it: *Items, index: u32, name: []const u8, is_protocol: bool, out: []const Types.Arg) Error!TypeId {
        const langs = std.StaticStringMap(Types.Lang).initComptime(.{
            .{ "Option", .option }, .{ "Result", .result }, .{ "Atomic", .atomic }, .{ "Channel", .channel },
        });
        const enums = std.StaticStringMap(void).initComptime(.{ .{"Option"}, .{"Result"}, .{"Order"}, .{"TrapKind"}, .{"MemOrder"} });
        return it.types.intern(.{ .nominal = .{
            .decl = .{ .package = it.std_pkg, .index = index },
            .args = out,
            .kind = if (is_protocol) .protocol else if (enums.has(name)) .@"enum" else .@"struct",
            .name = try it.types.strings.intern(name),
            .lang = langs.get(name) orelse .none,
        } });
    }

    /// The value of comptime array length `n`, or null if it is not
    /// known (or was reported).
    pub fn arrayLen(it: *Items, m: ModuleId, n: Node.Index, self_ty: TypeId) Error!?u64 {
        const v = try it.coerceValue(m, n, try it.fold(m, n, self_ty, .usize), .usize);
        return if (v == .scalar) v.scalar.bits else null;
    }

    // -----------------------------------------------------------------------
    // Declarations

    /// The signature of `fn_decl` node `n` of module `m`; `self_ty` is the
    /// enclosing type for methods (`.none` for free functions). Each
    /// declaration is checked once; later calls return the same result.
    pub fn signature(it: *Items, m: ModuleId, n: Node.Index, self_ty: TypeId) Error!Fn {
        // An instance's methods have their own signatures (`generics.zig`).
        if (it.instance == null) if (it.mods[m].fns.get(n)) |f| return f;
        const a = it.ast(m);
        const d = a.data(n).fn_decl;
        const kinds = a.tokens.items(.kind);
        const gens = try it.alloc().alloc(TypeId, if (d.generics) |g| g.len else 0);
        if (d.generics) |g| for (g, gens) |gn, *o| {
            o.* = it.mods[m].params.get(gn).?.type;
        };
        const params = try it.alloc().alloc(Param, d.params.len);
        for (d.params, params) |pn, *o| {
            const p = unwrap(a, pn)[0];
            const pd = a.data(p).param;
            const mt = a.mainToken(p);
            const is_self = kinds[mt] == .kw_self;
            const mode: Mode = switch (kinds[mt - 1]) {
                .kw_mut => .mut,
                .kw_move => .move,
                .kw_comptime => .@"comptime",
                else => .value,
            };
            const ty: TypeId = if (pd.ty) |t| try it.resolveType(m, t, self_ty) else if (is_self and self_ty != .none) self_ty else .err;
            o.* = .{
                .node = p,
                .name = identText(a, mt),
                .mode = mode,
                .is_self = is_self,
                .type = ty,
                .default = if (pd.default) |def| try it.defaultValue(m, def, ty, self_ty) else null,
            };
        }
        const f: Fn = .{
            .node = n,
            .name = identText(a, a.mainToken(n) + 1),
            .is_pub = isPub(a, a.mainToken(n)),
            .generics = gens,
            .params = params,
            .ret = if (d.ret) |r| try it.resolveType(m, r, self_ty) else .void,
            .attrs = it.attrsOf(m, n),
        };
        if (it.instance == null) try it.mods[m].fns.put(it.alloc(), n, f);
        return f;
    }

    /// A parameter or field default (§7.2.3, §7.3.1): a comptime constant
    /// (E0370) converted to `ty`.
    fn defaultValue(it: *Items, m: ModuleId, n: Node.Index, ty: TypeId, self_ty: TypeId) Error!Value {
        if (it.runtimeRef(m, n)) |r| {
            try it.report(m, it.ast(m).mainToken(r), .E0370, &.{"defaults are evaluated at compile time; use a literal, a `const` or a comptime-evaluable call"}, "default value is not a comptime constant: `{s}` is a runtime value", .{it.ast(m).tokenSlice(it.ast(m).mainToken(r))});
            return .unknown;
        }
        return it.coerceValue(m, n, try it.fold(m, n, self_ty, ty), ty);
    }

    /// The first name use in `n` that denotes a runtime value: a parameter
    /// (other than a `comptime` one), a `let` binding or `self`.
    pub fn runtimeRef(it: *const Items, m: ModuleId, n: Node.Index) ?Node.Index {
        const a = it.ast(m);
        switch (a.kind(n)) {
            .self_value => return n,
            .lambda => return null, // its parameters are its own
            .ident => if (it.names.get(m, n)) |e| switch (e.res) {
                .local => |l| switch (a.kind(l)) {
                    .generic_param, .const_decl => {},
                    .param => if (a.tokens.items(.kind)[a.mainToken(l) - 1] != .kw_comptime) return n,
                    else => return n,
                },
                .global => {},
            },
            else => {},
        }
        switch (a.data(n)) {
            inline else => |p| {
                const P = @TypeOf(p);
                inline for (@typeInfo(P).@"struct".field_names, @typeInfo(P).@"struct".field_types) |name, F| {
                    const v = @field(p, name);
                    switch (F) {
                        Node.Index => if (it.runtimeRef(m, v)) |r| return r,
                        ?Node.Index => if (v) |c| if (it.runtimeRef(m, c)) |r| return r,
                        []const Node.Index => for (v) |c| if (it.runtimeRef(m, c)) |r| return r,
                        ?[]const Node.Index => if (v) |l| for (l) |c| if (it.runtimeRef(m, c)) |r| return r,
                        else => {},
                    }
                }
            },
        }
        return null;
    }

    /// The const declared by `const_decl` node `n` of module `m` (§7.7,
    /// §5.9). `self_ty` is the enclosing type of an associated const.
    pub fn constValue(it: *Items, m: ModuleId, n: Node.Index, self_ty: TypeId) Error!Const {
        // shortcut: associated consts are keyed per instance like local ones (re-evaluated, and re-reported, in each instance that names them); key them once if that shows up.
        const key = .{ n, if (it.mods[m].item_of.contains(n)) instantiate.no_instance else instantiate.current(it) };
        const gop = try it.mods[m].consts.getOrPut(it.alloc(), key);
        if (gop.found_existing) return switch (gop.value_ptr.state) {
            .done => gop.value_ptr.c,
            else => {
                // The const's value depends on itself (§7.7, §8.1); no A.3 code covers it.
                const tok = it.ast(m).mainToken(n) + 1;
                try it.report(m, tok, null, &.{"a `const` cannot depend on its own value, directly or through other consts and calls"}, "cycle in the value of `{s}`", .{identText(it.ast(m), tok)});
                return .{ .node = n, .name = "", .is_pub = false, .type = .err, .value = .unknown };
            },
        };
        gop.value_ptr.state = .active;
        const a = it.ast(m);
        const d = a.data(n).const_decl;
        const name_tok = a.mainToken(n) + 1;
        const decl_ty: TypeId = if (d.ty) |t| try it.resolveType(m, t, self_ty) else .none;
        var v = try it.fold(m, d.value, self_ty, decl_ty);
        if (d.ty != null) v = try it.coerceValue(m, d.value, v, decl_ty);
        const ty = if (d.ty != null) decl_ty else valueType(v);
        if (!try it.constTypeOk(ty)) {
            try it.report(m, if (d.ty) |t| typeToken(a, t) else name_tok, .E0341, &.{"a `const` must be plain, `str`, an array or slice of plain values, or comptime-only (§5.9)"}, "invalid type for a `const`: `{s}`", .{try it.tyName(ty)});
        }
        const c: Const = .{ .node = n, .name = identText(a, name_tok), .is_pub = isPub(a, a.mainToken(n)), .type = ty, .value = v };
        it.mods[m].consts.getPtr(key).?.* = .{ .state = .done, .c = c };
        return c;
    }

    /// Struct item `i` of module `m` whose `Self` is `self_ty`: its own
    /// type, or an instance whose parameters are bound (`generics.zig`).
    pub fn structDecl(it: *Items, m: ModuleId, i: u32, self_ty: TypeId) Error!Struct {
        const item = it.im.graph.modules[m].items[i];
        const a = it.ast(m);
        const d = a.data(item.node).struct_decl;
        const kinds = a.tokens.items(.kind);
        if (d.fields.len > max_members) try it.tooMany(m, item, "fields", d.fields.len);
        const fields = try it.alloc().alloc(Field, d.fields.len);
        for (d.fields, fields) |fnode, *o| {
            const f, const attrs = unwrap(a, fnode);
            const fd = a.data(f).field_decl;
            const mt = a.mainToken(f);
            const ty = try it.resolveType(m, fd.ty, self_ty);
            o.* = .{
                .node = f,
                .name = identText(a, mt),
                .vis = if (kinds[mt - 1] == .kw_mut and kinds[mt - 2] == .kw_pub) .pub_mut else if (kinds[mt - 1] == .kw_pub) .@"pub" else .private,
                .type = ty,
                .default = if (fd.default) |def| try it.defaultValue(m, def, ty, self_ty) else null,
                .attrs = attrs,
            };
        }
        const members = try it.membersOf(m, d.members, self_ty);
        return .{
            .type = self_ty,
            .generics = try it.genericTypes(m, d.generics),
            .fields = fields,
            .consts = members.consts,
            .methods = members.methods,
            .attrs = it.attrsOf(m, item.node),
        };
    }

    /// Enum item `i` of module `m` whose `Self` is `self_ty`; see `structDecl`.
    pub fn enumDecl(it: *Items, m: ModuleId, i: u32, self_ty: TypeId) Error!Enum {
        const item = it.im.graph.modules[m].items[i];
        const a = it.ast(m);
        const d = a.data(item.node).enum_decl;
        if (d.variants.len > max_members) try it.tooMany(m, item, "variants", d.variants.len);

        var has_payload = false;
        for (d.variants) |vn| has_payload = has_payload or a.data(unwrap(a, vn)[0]).variant_decl.payload != null;
        var backing: TypeId = .none;
        if (d.backing) |b| {
            const t = try it.resolveType(m, b, self_ty);
            if (has_payload) {
                try it.report(m, a.mainToken(b), .E0377, &.{"remove the backing type; payload enums choose their tag type (§4.11.4)"}, "enum `{s}` has payloads, so it cannot have a backing type", .{item.name});
            } else if (t != .err and it.intInfo(t) == null) {
                try it.report(m, a.mainToken(b), null, &.{}, "enum backing type must be an integer type, found `{s}`", .{try it.tyName(t)});
            } else backing = t;
        }
        const explicit_backing = backing != .none;

        // Discriminants (§4.11.4): explicit ones are comptime integers;
        // the others continue from the previous one.
        const variants = try it.alloc().alloc(Variant, d.variants.len);
        const values = try it.alloc().alloc(?i128, d.variants.len);
        var seen: std.AutoHashMapUnmanaged(i128, void) = .empty;
        var next: ?i128 = 0;
        for (d.variants, variants, values) |vn, *o, *val| {
            const v, _ = unwrap(a, vn);
            const vd = a.data(v).variant_decl;
            const payload = try it.alloc().alloc(TypeId, if (vd.payload) |p| p.len else 0);
            if (vd.payload) |p| for (p, payload) |pn, *pt| {
                pt.* = try it.resolveType(m, pn, self_ty);
            };
            val.* = next;
            if (vd.value) |e| {
                var fv = try it.fold(m, e, self_ty, backing);
                if (backing != .none) fv = try it.coerceValue(m, e, fv, backing);
                val.* = switch (fv) {
                    // Too large for i128 also fits no backing type: E0306 below.
                    .untyped => |c| if (c == .int) c.int.toInt(i128) catch std.math.maxInt(i128) else null,
                    .scalar => |s| if (it.intInfo(s.type)) |info_| scalarInt(s, info_) else null,
                    else => null,
                };
                if (val.* == null and fv != .unknown) // `.unknown` is left to the comptime evaluator
                    try it.report(m, a.mainToken(e), if (fv == .untyped) .E0306 else null, &.{}, "enum discriminant must be a comptime integer constant", .{});
            }
            if (val.*) |x| {
                if ((try seen.fetchPut(it.alloc(), x, {})) != null)
                    try it.report(m, a.mainToken(v), .E0309, &.{"discriminants without `= value` continue from the previous variant"}, "duplicate discriminant {d} for variant `{s}`", .{ x, identText(a, a.mainToken(v)) });
            }
            next = if (val.*) |x| x +| 1 else null;
            o.* = .{ .node = v, .name = identText(a, a.mainToken(v)), .payload = payload, .discriminant = .{ .type = .none, .bits = 0 } };
        }

        if (backing == .none) backing = for ([_]u8{ 8, 16, 32 }) |bits| {
            const t: TypeId = .int(.unsigned, bits);
            if (allFit(values, .unsigned, bits)) break t;
        } else .int(.unsigned, 32); // E0306 below
        const bi = it.intInfo(backing).?;
        for (values, variants) |val, *o| {
            o.discriminant.type = backing;
            const x = val orelse continue;
            if (!fits(x, bi.signedness, bi.bits)) {
                try it.report(m, a.mainToken(o.node), .E0306, &.{}, "discriminant {d} of `{s}` does not fit `{s}`", .{ x, o.name, try it.tyName(backing) });
                continue;
            }
            o.discriminant.bits = @bitCast(@as(i64, @truncate(x)));
        }

        const members = try it.membersOf(m, d.members, self_ty);
        return .{
            .type = self_ty,
            .generics = try it.genericTypes(m, d.generics),
            .backing = backing,
            .explicit_backing = explicit_backing,
            .has_payload = has_payload,
            .variants = variants,
            .consts = members.consts,
            .methods = members.methods,
            .attrs = it.attrsOf(m, item.node),
        };
    }

    fn tooMany(it: *Items, m: ModuleId, item: collect.Item, what: []const u8, count: usize) Error!void {
        try it.report(m, it.ast(m).mainToken(item.node) + 1, .E0311, &.{}, "`{s}` has {d} {s}; the maximum is {d}", .{ item.name, count, what, max_members });
    }

    fn genericTypes(it: *Items, m: ModuleId, gens: ?[]const Node.Index) Error![]const TypeId {
        const g = gens orelse return &.{};
        const out = try it.alloc().alloc(TypeId, g.len);
        for (g, out) |gn, *o| o.* = it.mods[m].params.get(gn).?.type;
        return out;
    }

    fn membersOf(it: *Items, m: ModuleId, members: []const Node.Index, self_ty: TypeId) Error!struct { consts: []const Const, methods: []const Fn } {
        const a = it.ast(m);
        var consts: std.ArrayList(Const) = .empty;
        var methods: std.ArrayList(Fn) = .empty;
        for (members) |mn| {
            const n = unwrap(a, mn)[0];
            switch (a.kind(n)) {
                .fn_decl => try methods.append(it.alloc(), try it.signature(m, n, self_ty)),
                .const_decl => try consts.append(it.alloc(), try it.constValue(m, n, self_ty)),
                else => {},
            }
        }
        return .{ .consts = consts.items, .methods = methods.items };
    }

    // -----------------------------------------------------------------------
    // Constant folding

    /// Evaluates comptime expression `n` of module `m` as far as this file
    /// can (literals, consts, enum variants, operators, casts); the rest
    /// goes to the comptime hook. Untyped constants stay untyped.
    pub fn evalConst(it: *Items, m: ModuleId, n: Node.Index, self_ty: TypeId) Error!Value {
        return it.fold(m, n, self_ty, .none);
    }

    /// The value of comptime argument `n` of module `m` (where `Self` is
    /// `self_ty`) converted to `ty` (§8.2); `.unknown` if it was reported
    /// or cannot be evaluated.
    pub fn comptimeArg(it: *Items, m: ModuleId, n: Node.Index, self_ty: TypeId, ty: TypeId) Error!Value {
        return it.coerceValue(m, n, try it.fold(m, n, self_ty, ty), ty);
    }

    fn hook(it: *Items, m: ModuleId, n: Node.Index, expected: TypeId) Error!Value {
        const h = it.options.comptime_hook orelse return .unknown;
        return try h.eval(h.ctx, it, m, n, expected) orelse .unknown;
    }

    /// `expected` is the type wanted for `n` (or `.none`), passed to the hook
    /// for whatever this file cannot fold. An operand the hook could not
    /// evaluate makes the whole expression `.unknown` without asking again.
    fn fold(it: *Items, m: ModuleId, n: Node.Index, self_ty: TypeId, expected: TypeId) Error!Value {
        const a = it.ast(m);
        const mt = a.mainToken(n);
        const gpa = it.alloc();
        switch (a.data(n)) {
            .int_lit => {
                const iv = literals.decodeInt(a.tokenSlice(mt)) catch return .unknown; // reported by the lexer
                const c = try convert.fromInt(gpa, iv.value);
                const ty: TypeId = switch (iv.suffix) {
                    .none => return .{ .untyped = c },
                    .unsigned => |b| .int(.unsigned, b),
                    .signed => |b| .int(.signed, b),
                    .usize => .usize,
                    .isize => .isize,
                };
                return it.coerceValue(m, n, .{ .untyped = c }, ty);
            },
            .float_lit => {
                const text = a.tokenSlice(mt);
                const fv = literals.decodeFloat(text);
                return switch (fv.suffix) {
                    .none => .{ .untyped = convert.parseFloat(gpa, text) catch |e| switch (e) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.TooLarge => return .unknown,
                    } },
                    .f32 => .{ .scalar = .{ .type = .f32, .bits = @as(u32, @bitCast(@as(f32, @floatCast(fv.value)))) } },
                    .f64 => .{ .scalar = .{ .type = .f64, .bits = @bitCast(fv.value) } },
                };
            },
            .char_lit => return .{ .untyped = try convert.fromInt(gpa, literals.decodeChar(a.tokenSlice(mt))) },
            .bool_lit => return .{ .scalar = .{ .type = .bool, .bits = @intFromBool(a.tokens.items(.kind)[mt] == .kw_true) } },
            .paren => |p| return it.fold(m, p.inner, self_ty, expected),
            .prefix => |p| {
                const v = try it.fold(m, p.operand, self_ty, .none);
                return if (v == .unknown) .unknown else it.foldPrefix(m, n, v, expected);
            },
            .binary => |b| {
                const l = try it.fold(m, b.lhs, self_ty, .none);
                const r = try it.fold(m, b.rhs, self_ty, .none);
                return if (l == .unknown or r == .unknown) .unknown else it.foldBinary(m, n, l, r, expected);
            },
            .cast => |c| {
                const v = try it.fold(m, c.value, self_ty, .none);
                return if (v == .unknown) .unknown else it.foldCast(m, n, v, try it.resolveType(m, c.ty, self_ty), expected);
            },
            // A name in a generic argument list is a `path` (`Ring<u32, N>`).
            .ident, .path => {
                const e = it.names.get(m, n) orelse return .unknown; // reported by the expression checker
                if (e.rest != 0) return it.hook(m, n, expected);
                return switch (e.res) {
                    .local => |l| switch (a.kind(l)) {
                        .const_decl => (try it.constValue(m, l, self_ty)).value,
                        .param, .generic_param => instantiate.boundValue(it, m, l) orelse .unknown,
                        else => .unknown,
                    },
                    .global => |t| it.targetValue(m, n, t, self_ty),
                };
            },
            .self_type => return if (self_ty == .none) .unknown else .{ .type = self_ty },
            .field_access => |f| {
                if (it.names.get(m, n)) |e| if (e.res == .global) return it.targetValue(m, n, e.res.global, self_ty);
                const lhs = try it.fold(m, f.lhs, self_ty, .none);
                if (lhs == .type) if (try it.memberValue(lhs.type, identText(a, mt))) |v| return v;
                return it.hook(m, n, expected);
            },
            .array_type, .slice_type, .soa_array_type, .soa_slice_type, .ptr_type, .ptr_const_type, .mut_type, .fn_type, .type_type, .generic_inst => return .{ .type = try it.resolveType(m, n, self_ty) },
            else => return it.hook(m, n, expected),
        }
    }

    /// The value of a module-level name used as an expression.
    fn targetValue(it: *Items, m: ModuleId, n: Node.Index, t: Target, self_ty: TypeId) Error!Value {
        switch (t) {
            .item => |ref| {
                const item = it.im.graph.modules[ref.module].items[ref.item];
                return switch (item.kind) {
                    .@"const" => (try it.constValue(ref.module, item.node, .none)).value,
                    .@"fn", .extern_fn => it.hook(m, n, .none),
                    else => .{ .type = try it.itemType(m, n, ref, null, self_ty) },
                };
            },
            .prelude => |name| {
                for (prelude.entries) |e| if (std.mem.eql(u8, e.name, name) and e.kind != .type) return .unknown;
                return .{ .type = try it.preludeType(m, n, name, null, self_ty) };
            },
            else => return .unknown,
        }
    }

    /// `T.name` for type `ty`: an enum variant or an associated const.
    fn memberValue(it: *Items, ty: TypeId, name: []const u8) Error!?Value {
        const ref = it.declRef(ty) orelse return null;
        const node = it.im.graph.modules[ref.module].items[ref.item].node;
        const a = it.ast(ref.module);
        const members = switch (a.data(node)) {
            .struct_decl => |d| d.members,
            .enum_decl => |d| blk: {
                for (d.variants) |vn| {
                    const v = unwrap(a, vn)[0];
                    if (!std.mem.eql(u8, identText(a, a.mainToken(v)), name)) continue;
                    if (it.mods[ref.module].states[ref.item] == .active) return .unknown; // a discriminant naming its own enum
                    const e = (try it.ensure(ref.module, ref.item)).@"enum";
                    for (e.variants) |ev| if (ev.node == v) {
                        if (ev.payload.len > 0) return null;
                        return .{ .scalar = .{ .type = ty, .bits = ev.discriminant.bits } };
                    };
                }
                break :blk d.members;
            },
            else => return null,
        };
        for (members) |mn| {
            const c = unwrap(a, mn)[0];
            if (a.kind(c) == .const_decl and std.mem.eql(u8, identText(a, a.mainToken(c) + 1), name))
                return (try it.constValue(ref.module, c, try it.selfType(ref.module, ref.item))).value;
        }
        return null;
    }

    /// `op v` for known `v`; what this file cannot fold goes to the hook.
    fn foldPrefix(it: *Items, m: ModuleId, n: Node.Index, v: Value, expected: TypeId) Error!Value {
        const gpa = it.alloc();
        switch (it.ast(m).tokens.items(.kind)[it.ast(m).mainToken(n)]) {
            .minus => switch (v) {
                .untyped => |c| return .{ .untyped = try convert.negate(c) },
                .scalar => |s| {
                    if (s.type == .f32) return .{ .scalar = .{ .type = .f32, .bits = s.bits ^ 0x8000_0000 } };
                    if (s.type == .f64) return .{ .scalar = .{ .type = .f64, .bits = s.bits ^ (1 << 63) } };
                    if (it.numeric(s)) |x| return it.typed(m, n, try convert.negate(x), s.type, expected);
                },
                else => {},
            },
            .tilde => if (v == .untyped) return .{ .untyped = convert.bitNot(gpa, v.untyped) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return it.hook(m, n, expected),
            } },
            .bang => if (v == .scalar and v.scalar.type == .bool) return .{ .scalar = .{ .type = .bool, .bits = v.scalar.bits ^ 1 } },
            else => {},
        }
        return it.hook(m, n, expected);
    }

    /// `l op r` for known operands; what this file cannot fold goes to the hook.
    fn foldBinary(it: *Items, m: ModuleId, n: Node.Index, l: Value, r: Value, expected: TypeId) Error!Value {
        const gpa = it.alloc();
        const op = it.ast(m).tokens.items(.kind)[it.ast(m).mainToken(n)];
        if (op == .amp_amp or op == .pipe_pipe) {
            if (l != .scalar or r != .scalar or l.scalar.type != .bool or r.scalar.type != .bool) return it.hook(m, n, expected);
            const x = l.scalar.bits != 0;
            const y = r.scalar.bits != 0;
            return .{ .scalar = .{ .type = .bool, .bits = @intFromBool(if (op == .amp_amp) x and y else x or y) } };
        }
        // Operand type: both untyped, or one integer type (§4.8). Typed float
        // arithmetic goes to the strict-IEEE comptime interpreter (T057).
        const lt, const lc = it.operand(l) orelse return it.hook(m, n, expected);
        const rt, const rc = it.operand(r) orelse return it.hook(m, n, expected);
        const ty = if (lt == rt) lt else if (isUntyped(lt)) rt else if (isUntyped(rt)) lt else return it.hook(m, n, expected);
        const bop: convert.BinOp = switch (op) {
            .plus => .add,
            .minus => .sub,
            .star => .mul,
            .slash => .div,
            .percent => .rem,
            .shl => .shl,
            .shr => .shr,
            .amp => .bit_and,
            .pipe => .bit_or,
            .caret => .bit_xor,
            .eq_eq, .bang_eq, .lt, .gt, .lt_eq, .gt_eq => {
                const ord = try convert.order(gpa, lc, rc);
                const res = switch (op) {
                    .eq_eq => ord == .eq,
                    .bang_eq => ord != .eq,
                    .lt => ord == .lt,
                    .gt => ord == .gt,
                    .lt_eq => ord != .gt,
                    else => ord != .lt,
                };
                return .{ .scalar = .{ .type = .bool, .bits = @intFromBool(res) } };
            },
            else => return it.hook(m, n, expected),
        };
        const res = convert.binary(gpa, bop, lc, rc) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return it.hook(m, n, expected), // division by zero, bad operand
        };
        return if (isUntyped(ty)) .{ .untyped = res } else it.typed(m, n, res, ty, expected);
    }

    /// `v as to` for known `v`; what this file cannot fold goes to the hook.
    fn foldCast(it: *Items, m: ModuleId, n: Node.Index, v: Value, to: TypeId, expected: TypeId) Error!Value {
        if (to == .err) return .unknown;
        const c: convert.Const = switch (v) {
            .untyped => |c| c,
            .scalar => |s| blk: {
                if (s.type == to) return v;
                if (s.type == .bool and it.intInfo(to) != null) return .{ .scalar = .{ .type = to, .bits = s.bits } };
                if (it.enumOf(s.type)) |e| break :blk try convert.fromInt(it.alloc(), scalarInt(.{ .type = e.backing, .bits = s.bits }, it.intInfo(e.backing).?));
                break :blk it.numeric(s) orelse return it.hook(m, n, expected);
            },
            else => return it.hook(m, n, expected),
        };
        switch (try convert.castConst(it.alloc(), it.types, it.options.ptr_bits, c, to)) {
            .ok => |val| return .{ .scalar = val },
            .err => |code| {
                if (v == .untyped) {
                    try it.report(m, it.ast(m).mainToken(n), code, &.{}, "invalid constant conversion to `{s}`", .{try it.tyName(to)});
                    return .unknown;
                }
                return it.hook(m, n, expected); // a typed value: truncation is the comptime interpreter's
            },
        }
    }

    /// The type and exact value of a numeric operand: an untyped constant
    /// or a typed integer.
    fn operand(it: *Items, v: Value) ?struct { TypeId, convert.Const } {
        return switch (v) {
            .untyped => |c| .{ c.typeOf(), c },
            .scalar => |s| .{ s.type, it.numeric(s) orelse return null },
            else => null,
        };
    }

    /// Typed integer `s` as an exact constant; null for other types.
    fn numeric(it: *Items, s: Types.Value) ?convert.Const {
        const info_ = it.intInfo(s.type) orelse return null;
        return convert.fromInt(it.alloc(), scalarInt(s, info_)) catch null;
    }

    /// Exact result `c` of typed integer arithmetic node `n`, as a `ty`
    /// value; an overflow goes to the comptime interpreter, which traps (§8.6).
    fn typed(it: *Items, m: ModuleId, n: Node.Index, c: convert.Const, ty: TypeId, expected: TypeId) Error!Value {
        return switch (try convert.convertConst(it.alloc(), it.types, it.options.ptr_bits, c, ty)) {
            .ok => |val| .{ .scalar = val },
            .err => it.hook(m, n, expected),
        };
    }

    /// Converts the value of expression `n` to `to`, where a `to` is
    /// declared (const, default, discriminant, array length): rule 1 for
    /// untyped constants (E0306, E0310), widening for typed integers.
    /// A generic parameter `to` is checked per instantiation (§7.6.4, `generics.zig`),
    /// so `v` is kept as is; other types built from parameters reject
    /// scalars whatever the arguments.
    fn coerceValue(it: *Items, m: ModuleId, n: Node.Index, v: Value, to: TypeId) Error!Value {
        if (to == .err or (to != .none and it.types.get(to) == .param)) return v;
        const tok = it.ast(m).mainToken(n);
        const from = valueType(v);
        switch (v) {
            .unknown => return .unknown,
            .untyped => |c| switch (convert.coerce(it.types, from, to, .{})) {
                .constant => switch (try convert.convertConst(it.alloc(), it.types, it.options.ptr_bits, c, to)) {
                    .ok => |val| return .{ .scalar = val },
                    .err => |code| {
                        try it.report(m, tok, code, &.{}, "{s} constant does not fit `{s}`", .{ if (c == .int) "integer" else "float", try it.tyName(to) });
                        return .unknown;
                    },
                },
                .wrap_some => return .unknown,
                else => {},
            },
            .scalar => |s| switch (convert.coerce(it.types, s.type, to, .{})) {
                .identity => return .{ .scalar = .{ .type = to, .bits = s.bits } },
                .int_widen => return .{ .scalar = .{ .type = to, .bits = s.bits } },
                .float_widen => return .{ .scalar = .{ .type = .f64, .bits = @bitCast(@as(f64, @as(f32, @bitCast(@as(u32, @truncate(s.bits)))))) } },
                .wrap_some => return .unknown,
                else => {},
            },
            .type => if (to == .type) return v,
            .computed => |c| if (c.type == to) return v,
        }
        try it.report(m, tok, .E0310, &.{}, "mismatched types: expected `{s}`, found `{s}`", .{ try it.tyName(to), try it.tyName(from) });
        return .unknown;
    }

    const IntInfo = struct { signedness: std.builtin.Signedness, bits: u16 };

    fn intInfo(it: *Items, ty: TypeId) ?IntInfo {
        return switch (ty) {
            .usize => .{ .signedness = .unsigned, .bits = it.options.ptr_bits },
            .isize => .{ .signedness = .signed, .bits = it.options.ptr_bits },
            .none => null,
            else => switch (it.types.get(ty)) {
                .int => |i| .{ .signedness = i.signedness, .bits = i.bits },
                else => null,
            },
        };
    }

    // -----------------------------------------------------------------------
    // Const types (§5.9)

    /// Whether a `const` may have type `ty`: plain, `str`, an array or slice
    /// of plain values, or comptime-only.
    fn constTypeOk(it: *Items, ty: TypeId) Error!bool {
        switch (ty) {
            .str, .type, .untyped_int, .untyped_float, .fn_ref, .err => return true,
            else => {},
        }
        return switch (it.types.get(ty)) {
            .field_id => true,
            .slice => |s| it.isPlain(s.elem),
            .soa_slice => |s| it.isPlain(s.elem),
            else => it.isPlain(ty),
        };
    }

    /// Whether `ty` contains no resource, shared cell or view (§5.1, §5.2).
    fn isPlain(it: *Items, ty: TypeId) Error!bool {
        return (try type_kinds.kind(it, ty)) == .plain;
    }

    // -----------------------------------------------------------------------
    // Recursive containment (§7.3.1, E0376)

    fn checkContainment(it: *Items) Error!void {
        for (it.im.graph.modules, 0..) |cm, m| for (cm.items, 0..) |item, i| {
            if (item.kind != .@"struct" and item.kind != .@"enum") continue;
            const root = it.decl(@intCast(m), item.node);
            var seen: std.AutoHashMapUnmanaged(TypeId, void) = .empty;
            const found = for (it.containedTypes(.{ .module = @intCast(m), .item = @intCast(i) })) |t| {
                if (try it.contains(t, root, 0, &seen)) break true;
            } else false;
            if (found) try it.report(@intCast(m), it.ast(@intCast(m)).mainToken(item.node) + 1, .E0376, &.{"use a `Handle` or an index instead"}, "recursive type `{s}` contains itself by value", .{item.name});
        };
    }

    /// The types a struct holds by value (its fields) or an enum (its payloads).
    fn containedTypes(it: *Items, ref: Ref) []const TypeId {
        if (it.mods[ref.module].states[ref.item] != .done) return &.{};
        return switch (it.mods[ref.module].infos[ref.item]) {
            .@"struct" => |s| blk: {
                const out = it.alloc().alloc(TypeId, s.fields.len) catch return &.{};
                for (s.fields, out) |f, *o| o.* = f.type;
                break :blk out;
            },
            .@"enum" => |e| blk: {
                var out: std.ArrayList(TypeId) = .empty;
                for (e.variants) |v| out.appendSlice(it.alloc(), v.payload) catch return &.{};
                break :blk out.items;
            },
            else => &.{},
        };
    }

    /// Whether `ty` holds declaration `root` by value. Each nominal type
    /// (one generic instance) is walked once per root; its fields are
    /// walked with its arguments substituted.
    fn contains(it: *Items, ty: TypeId, root: Types.Decl, depth: u32, seen: *std.AutoHashMapUnmanaged(TypeId, void)) Error!bool {
        // shortcut: the visit budget cuts off polymorphic recursion
        // (`L<T>` holding `L<(T, T)>`), which instantiation reports as E0812.
        if (depth > 64 or seen.count() > 4096) return false;
        switch (it.types.get(ty)) {
            .array => |x| return it.contains(x.elem, root, depth + 1, seen),
            .soa_array => |x| return it.contains(x.elem, root, depth + 1, seen),
            .vec => |x| return it.contains(x.elem, root, depth + 1, seen),
            .tuple => |x| {
                for (x.elems) |e| if (try it.contains(e, root, depth + 1, seen)) return true;
                return false;
            },
            .nominal => |n| {
                if (std.meta.eql(n.decl, root)) return true;
                if (n.kind == .distinct) return it.contains(n.underlying, root, depth + 1, seen);
                if ((try seen.fetchPut(it.alloc(), ty, {})) != null) return false;
                if (std.meta.eql(n.decl.package, it.std_pkg)) {
                    // `Option`, `Result`, `Atomic`, ranges hold their arguments inline; containers on the heap.
                    if (isStdHeap(it.types.strings.get(n.name))) return false;
                    for (n.args) |arg| if (arg == .type and try it.contains(arg.type, root, depth + 1, seen)) return true;
                    return false;
                }
                const ref = it.refOfDecl(n.decl) orelse return false;
                for (it.containedTypes(ref)) |t| if (try it.contains(try it.subst(t, n.decl, n.args), root, depth + 1, seen)) return true;
                return false;
            },
            else => return false, // a parameter not bound here, or held indirectly
        }
    }

    /// `ty` with the type parameters of `owner` replaced by `args`. Only the
    /// constructors that hold values inline are rebuilt: a parameter behind
    /// a pointer, slice or handle never matters for containment.
    pub fn subst(it: *Items, ty: TypeId, owner: Types.Decl, args: []const Types.Arg) Error!TypeId {
        switch (it.types.get(ty)) {
            .param => |p| return if (std.meta.eql(p.owner, owner) and p.index < args.len and args[p.index] == .type) args[p.index].type else ty,
            .array => |x| return it.types.intern(.{ .array = .{ .len = x.len, .elem = try it.subst(x.elem, owner, args) } }),
            .soa_array => |x| return it.types.intern(.{ .soa_array = .{ .len = x.len, .elem = try it.subst(x.elem, owner, args) } }),
            .vec => |x| return it.types.intern(.{ .vec = .{ .len = x.len, .elem = try it.subst(x.elem, owner, args) } }),
            .tuple => |x| {
                const elems = try it.alloc().alloc(TypeId, x.elems.len);
                for (x.elems, elems) |e, *o| o.* = try it.subst(e, owner, args);
                return it.types.intern(.{ .tuple = .{ .elems = elems } });
            },
            .nominal => |n| {
                if (n.args.len == 0) return ty;
                const out = try it.alloc().alloc(Types.Arg, n.args.len);
                for (n.args, out) |arg, *o| o.* = if (arg == .type) .{ .type = try it.subst(arg.type, owner, args) } else arg;
                var k = n;
                k.args = out;
                return it.types.intern(.{ .nominal = k });
            },
            else => return ty,
        }
    }

    // -----------------------------------------------------------------------
    // Entry point (§7.2.6)

    fn checkMain(it: *Items) Error!void {
        const g = it.im.graph;
        const root = g.root orelse return;
        if (!std.mem.eql(u8, g.modules[root].path, module_graph.rootPath(.exe))) return;
        // shortcut: a missing `main` is reported by the build driver (T093).
        const i = g.modules[root].names.get("main") orelse return;
        const item = g.modules[root].items[i];
        const a = it.ast(root);
        const tok = a.mainToken(item.node) + 1;
        const forms: []const []const u8 = &.{"the entry point is `pub fn main()`, `pub fn main() -> u8` or `pub fn main() -> Result<void, E>` with `E: Display`"};
        if (item.kind != .@"fn") return it.report(root, tok, null, forms, "`main` must be a function", .{});
        const f = (try it.ensure(root, i)).@"fn";
        if (!item.is_pub) return it.report(root, tok, null, forms, "`main` must be `pub`", .{});
        if (f.params.len > 0 or f.generics.len > 0) return it.report(root, tok, null, forms ++ &[_][]const u8{"command-line arguments come from `std.process`"}, "`main` takes no parameters", .{});
        if (f.ret == .void) {
            it.main = .void;
        } else if (f.ret == TypeId.int(.unsigned, 8)) {
            it.main = .u8;
        } else if (f.ret == .err) {
            return;
        } else switch (it.types.get(f.ret)) {
            .nominal => |n| if (n.lang == .result and n.args.len == 2 and n.args[0] == .type and n.args[0].type == .void and n.args[1] == .type) {
                const e = n.args[1].type;
                if (it.implementsDisplay(e)) {
                    it.main = .result;
                } else try it.report(root, typeToken(a, a.data(item.node).fn_decl.ret.?), .E0373, &.{"add `impl Display for E` so the runtime can print the error"}, "`main` returns `Result<void, {s}>`, but `{s}` does not implement `Display`", .{ try it.tyName(e), try it.tyName(e) });
                return;
            },
            else => {},
        }
        if (it.main == null) try it.report(root, typeToken(a, a.data(item.node).fn_decl.ret.?), .E0310, forms, "`main` cannot return `{s}`", .{try it.tyName(f.ret)});
    }

    /// Whether `ty` implements `std.fmt.Display`: primitives do, and types of
    /// this package with an `impl Display for T`.
    fn implementsDisplay(it: *Items, ty: TypeId) bool {
        switch (it.types.get(ty)) {
            .simple => |s| return s == .bool or s == .str or s == .f32 or s == .f64 or s == .usize or s == .isize or s == .err,
            .int => return true,
            .nominal => |n| {
                // shortcut: std and dependency types are not loaded (T163) and count as implementing it.
                const ref = it.refOfDecl(n.decl) orelse return true;
                for (it.im.impls) |impl| {
                    const p = impl.protocol orelse continue;
                    const is_display = switch (p) {
                        .prelude => |name| std.mem.eql(u8, name, "Display"),
                        .external => |path| std.mem.eql(u8, path, "std.fmt.Display"),
                        else => false,
                    };
                    const t = impl.target orelse continue;
                    if (is_display and t == .item and t.item.module == ref.module and t.item.item == ref.item) return true;
                }
                return false;
            },
            else => return false,
        }
    }
};

/// Checks every item of the package resolved in `im` and `names` and
/// reports problems to `sink`. Errors are internal failures only.
pub fn check(gpa: Allocator, sink: *diag.Sink, types: *Types, im: *const Imports, names: *const Names, options: Options) Error!Items {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(gpa);
    var it: Items = .{
        .arena = arena,
        .sink = sink,
        .types = types,
        .im = im,
        .names = names,
        .options = options,
        .mods = &.{},
        .std_pkg = .{ .name = try types.strings.intern("std"), .line = .{ .major = 0 } },
    };
    errdefer it.deinit();
    const a = it.alloc();
    const modules = im.graph.modules;
    it.mods = try a.alloc(Mod, modules.len);
    var base: u32 = 0;
    for (modules, it.mods, 0..) |cm, *md, m| {
        md.* = .{ .base = base, .infos = try a.alloc(Info, cm.items.len), .states = try a.alloc(State, cm.items.len) };
        @memset(md.infos, .pending);
        @memset(md.states, .todo);
        base += @intCast(cm.ast.nodes.len);
        for (cm.items, 0..) |item, i| try md.item_of.put(a, item.node, @intCast(i));
        if (cm.ast.nodes.len > 0) for (cm.ast.data(.from(0)).root.items) |n| try scan(&it, @intCast(m), n);
    }
    for (modules, 0..) |cm, m| for (0..cm.items.len) |i| {
        _ = try it.ensure(@intCast(m), @intCast(i));
    };
    try it.checkContainment();
    try it.checkMain();
    return it;
}

/// Records the attributes and generic parameters of declaration `n` and
/// its members.
fn scan(it: *Items, m: ModuleId, n: Node.Index) Error!void {
    const a = it.ast(m);
    const inner, const attrs = unwrap(a, n);
    const md = &it.mods[m];
    if (attrs.len > 0) try md.attrs.put(it.alloc(), inner, attrs);
    if (generics(a, inner)) |gs| for (gs, 0..) |g, i| {
        try md.params.put(it.alloc(), g, .{ .type = try it.types.intern(.{ .param = .{
            .owner = it.decl(m, inner),
            .index = @intCast(i),
            .name = try it.types.strings.intern(identText(a, a.mainToken(g))),
        } }) });
    };
    const lists: []const []const Node.Index = switch (a.data(inner)) {
        .struct_decl => |d| &.{ d.fields, d.members },
        .enum_decl => |d| &.{ d.variants, d.members },
        .protocol_decl => |d| &.{d.members},
        .impl_decl => |d| &.{d.members},
        .extern_block => |d| &.{d.fns},
        .fn_decl => |d| &.{d.params},
        else => &.{},
    };
    for (lists) |l| for (l) |c| try scan(it, m, c);
}

// ---------------------------------------------------------------------------
// Helpers

fn unwrap(a: *const Ast, n: Node.Index) struct { Node.Index, []const Node.Index } {
    if (a.kind(n) != .attributed) return .{ n, &.{} };
    const d = a.data(n).attributed;
    return .{ d.inner, d.attrs };
}

fn generics(a: *const Ast, n: Node.Index) ?[]const Node.Index {
    return switch (a.data(n)) {
        inline .fn_decl, .struct_decl, .enum_decl, .protocol_decl, .impl_decl, .type_alias, .type_distinct => |d| d.generics,
        else => null,
    };
}

/// Whether `attrs` (attribute nodes of `a`) include `attr`.
pub fn hasAttr(a: *const Ast, attrs: []const Node.Index, attr: attr_table.Attr) bool {
    for (attrs) |n| {
        const text = a.tokenSlice(a.mainToken(n));
        if (attr_table.lookup(if (std.mem.startsWith(u8, text, "@")) text[1..] else text) == attr) return true;
    }
    return false;
}

/// `pub` is the token before a declaration keyword (see `Ast.zig`).
fn isPub(a: *const Ast, keyword: Ast.TokenIndex) bool {
    return keyword > 0 and a.tokens.items(.kind)[keyword - 1] == .kw_pub;
}

/// The identifier an IDENT token names: `r#type` is `type` (§2.3).
fn identText(a: *const Ast, t: Ast.TokenIndex) []const u8 {
    const s = a.tokenSlice(t);
    return if (std.mem.startsWith(u8, s, "r#")) s[2..] else s;
}

/// The source text of `path` node `n` (`a.b.C`).
fn pathText(a: *const Ast, n: Node.Index) []const u8 {
    if (a.kind(n) == .ident) return a.tokenSlice(a.mainToken(n));
    const starts = a.tokens.items(.start);
    const last = a.data(n).path.last;
    return a.source[starts[a.mainToken(n)] .. starts[last] + a.tokens.items(.len)[last]];
}

/// The token to report a type expression at: its name, not the `<` of `G<T>`.
pub fn typeToken(a: *const Ast, n: Node.Index) Ast.TokenIndex {
    return a.mainToken(if (a.kind(n) == .generic_inst) a.data(n).generic_inst.base else n);
}

/// Generic argument nodes that are values, not types (§3.6 `generic_args`).
fn isValueArg(a: *const Ast, n: Node.Index) bool {
    return switch (a.kind(n)) {
        .int_lit, .char_lit, .bool_lit, .prefix => true,
        else => false,
    };
}

fn isUntyped(ty: TypeId) bool {
    return ty == .untyped_int or ty == .untyped_float;
}

/// Standard containers that keep their elements on the heap.
fn isStdHeap(name: []const u8) bool {
    const heap = std.StaticStringMap(void).initComptime(.{ .{"List"}, .{"Pool"}, .{"Arena"}, .{"Channel"}, .{"Sender"}, .{"Map"}, .{"Table"} });
    return heap.has(name);
}

/// The type of a value: an untyped constant keeps its untyped type.
fn valueType(v: Value) TypeId {
    return switch (v) {
        .unknown => .err,
        .untyped => |c| c.typeOf(),
        .scalar => |s| s.type,
        .type => .type,
        .computed => |c| c.type,
    };
}

fn scalarInt(s: Types.Value, info_: Items.IntInfo) i128 {
    return if (info_.signedness == .signed) @as(i64, @bitCast(s.bits)) else s.bits;
}

fn fits(x: i128, signedness: std.builtin.Signedness, bits: u16) bool {
    if (signedness == .unsigned) return x >= 0 and x < (@as(i128, 1) << @intCast(bits));
    const half = @as(i128, 1) << @intCast(bits - 1);
    return x >= -half and x < half;
}

fn allFit(values: []const ?i128, signedness: std.builtin.Signedness, bits: u16) bool {
    for (values) |v| if (v) |x| if (!fits(x, signedness, bits)) return false;
    return true;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const Interner = @import("../base/Interner.zig");

/// A checked test package; build in place with `init`.
const Fixture = struct {
    p: module_graph.TestPackage,
    g: module_graph.Graph,
    im: Imports,
    names: Names,
    strings: Interner,
    types: Types,
    items: Items,

    fn init(f: *Fixture, mods: []const [2][]const u8, hook_: ?ComptimeHook) !void {
        f.p = try .init(mods);
        f.g = try f.p.graph(.{ .kind = .exe });
        f.im = try imports.resolve(testing.allocator, &f.p.sink, &f.g, .{});
        f.names = try names_mod.resolve(testing.allocator, &f.p.sink, &f.im);
        f.strings = .init(testing.allocator, testing.io);
        f.types = try .init(testing.allocator, testing.io, &f.strings);
        const pkg: Types.Package = .{ .name = try f.strings.intern("app"), .line = .{ .major = 1 } };
        f.items = try check(testing.allocator, &f.p.sink, &f.types, &f.im, &f.names, .{ .package = pkg, .comptime_hook = hook_ });
    }

    fn deinit(f: *Fixture) void {
        f.items.deinit();
        f.types.deinit();
        f.strings.deinit();
        f.names.deinit();
        f.im.deinit();
        f.g.deinit();
        f.p.deinit();
    }

    /// Checks the reported codes and the source text at each primary span.
    fn expectDiags(f: *Fixture, want: []const struct { ?diag.DiagCode, []const u8 }) !void {
        const ds = f.p.sink.finish();
        errdefer for (ds) |d| std.debug.print("got {?t}: {s}\n", .{ d.code, d.message });
        try testing.expectEqual(want.len, ds.len);
        for (want, ds) |w, d| {
            try testing.expectEqual(w[0], d.code);
            const s = d.primarySpan().?;
            try testing.expectEqualStrings(w[1], f.p.asts[@backingInt(s.file)].source[s.start..s.end]);
        }
    }

    /// What item `name` of the first module declares.
    fn get(f: *Fixture, name: []const u8) !*const Info {
        return f.items.info(.{ .module = 0, .item = f.g.modules[0].names.get(name).? });
    }

    fn expectType(f: *Fixture, want: []const u8, ty: TypeId) !void {
        const s = try f.types.allocPrint(testing.allocator, ty, .{});
        defer testing.allocator.free(s);
        try testing.expectEqualStrings(want, s);
    }
};

fn expectInt(want: i128, v: Value) !void {
    switch (v) {
        .untyped => |c| try testing.expectEqual(want, try c.int.toInt(i128)),
        .scalar => |s| try testing.expectEqual(want, @as(i128, @as(i64, @bitCast(s.bits)))),
        else => return error.TestUnexpectedResult,
    }
}

test "enum discriminants continue from the previous one; backing types" {
    var f: Fixture = undefined;
    try f.init(&.{.{
        "a",
        \\enum Opcode: u8 { nop = 0, load, halt = 0xFF }
        \\enum Level: i8 { low = -1, mid, high }
        \\enum Small { a, b }
        \\enum Wide { a = 300, b }
        \\const LOAD = Opcode.load as u8;
        \\const HALTS: bool = (Opcode.halt as u8) == 255 && (Level.high as i8) == 1;
    }}, null);
    defer f.deinit();
    try f.expectDiags(&.{});
    const op = (try f.get("Opcode")).@"enum";
    try testing.expectEqual(TypeId.int(.unsigned, 8), op.backing);
    for (op.variants, [_]i128{ 0, 1, 255 }) |v, want| try expectInt(want, .{ .scalar = v.discriminant });
    const level = (try f.get("Level")).@"enum";
    for (level.variants, [_]i128{ -1, 0, 1 }) |v, want| try expectInt(want, .{ .scalar = v.discriminant });
    try testing.expectEqual(TypeId.int(.unsigned, 8), (try f.get("Small")).@"enum".backing);
    try testing.expectEqual(TypeId.int(.unsigned, 16), (try f.get("Wide")).@"enum".backing);
    const load = (try f.get("LOAD")).@"const";
    try testing.expectEqual(TypeId.int(.unsigned, 8), load.type);
    try expectInt(1, load.value);
    try testing.expectEqual(1, (try f.get("HALTS")).@"const".value.scalar.bits);
}

test "E0309: duplicate discriminants" {
    var f: Fixture = undefined;
    try f.init(&.{.{
        "a",
        \\enum Opcode: u8 { nop = 0, load, store = 1, halt = 0xFF }
        \\enum Level { low = 2, mid = 1, high }
        \\enum Tiny: u2 { a = 3, b }
    }}, null);
    defer f.deinit();
    try f.expectDiags(&.{ .{ .E0309, "store" }, .{ .E0309, "high" }, .{ .E0306, "b" } });
}

test "E0377: backing type only on payload-free enums" {
    var f: Fixture = undefined;
    try f.init(&.{.{
        "a",
        \\enum Msg: u8 { quit, move_to(i32, i32) }
        \\enum Ok: i8 { low = -1, mid, high }
        \\enum Shape { circle(f32), rect(f32, f32), empty }
    }}, null);
    defer f.deinit();
    try f.expectDiags(&.{.{ .E0377, "u8" }});
    const shape = (try f.get("Shape")).@"enum";
    try testing.expect(shape.has_payload);
    try testing.expectEqual(2, shape.variants[1].payload.len);
    try testing.expectEqual(TypeId.f32, shape.variants[1].payload[1]);
}

/// Folds every call to 16, for the comptime hook test.
fn sixteen(_: ?*anyopaque, items: *Items, m: ModuleId, n: Node.Index, _: TypeId) Error!?Value {
    if (items.ast(m).kind(n) != .call) return null;
    return .{ .untyped = try convert.fromInt(items.alloc(), 16) };
}

test "E0370: defaults must be comptime constants; the hook folds calls" {
    var f: Fixture = undefined;
    try f.init(&.{.{
        "a",
        \\const BASE: f32 = 2.0;
        \\fn double(x: u32) -> u32 { x * 2 }
        \\fn scale(x: f32, by: f32 = BASE * 2.0, n: u8 = 3) -> f32 { x * by }
        \\fn pad(len: usize, width: usize = len) -> usize { width - len }
        \\fn wait(ms: u32, until: u32 = ms * 2) -> u32 { until }
        \\fn rep(comptime n: usize, k: usize = n) -> usize { k }
        \\struct Grid {
        \\    cells: u32 = double(8),
        \\    rows: [4]u8 = [0; 4],
        \\    ratio: f32 = BASE,
        \\    big: u8 = 256,
        \\}
    }}, .{ .eval = sixteen });
    defer f.deinit();
    try f.expectDiags(&.{ .{ .E0370, "len" }, .{ .E0370, "ms" }, .{ .E0306, "256" } });
    const scale = (try f.get("scale")).@"fn";
    try testing.expect(scale.params[1].default.? == .unknown); // f32 arithmetic: the hook declines
    try expectInt(3, scale.params[2].default.?);
    try testing.expectEqual(null, scale.params[0].default);
    const grid = (try f.get("Grid")).@"struct";
    try expectInt(16, grid.fields[0].default.?);
    try testing.expectEqual(TypeId.int(.unsigned, 32), grid.fields[0].default.?.scalar.type);
    try testing.expectEqual(TypeId.f32, grid.fields[2].default.?.scalar.type);
}

/// Records what it is asked and answers every typed float binary
/// expression with 1.5 and anything else with null, for the hook test.
const Recorder = struct {
    asked: std.ArrayList(TypeId) = .empty,

    fn eval(ctx: ?*anyopaque, items: *Items, m: ModuleId, n: Node.Index, expected: TypeId) Error!?Value {
        const r: *Recorder = @ptrCast(@alignCast(ctx.?));
        try r.asked.append(testing.allocator, expected);
        if (items.ast(m).kind(n) != .binary or expected != .f32) return null;
        return .{ .scalar = .{ .type = .f32, .bits = @as(u32, @bitCast(@as(f32, 1.5))) } };
    }
};

test "the hook gets what folding gives up on, with the expected type" {
    var rec: Recorder = .{};
    defer rec.asked.deinit(testing.allocator);
    var f: Fixture = undefined;
    try f.init(&.{.{
        "a",
        \\const BASE: f32 = 2.0;
        \\const X: f32 = BASE * 2.0;
        \\const Y: u8 = 255u8 + 1u8;
        \\const Z: u8 = ~1u8;
        \\const W: u16 = (1u8 + 2u16) + 1;
    }}, .{ .ctx = &rec, .eval = Recorder.eval });
    defer f.deinit();
    try f.expectDiags(&.{});
    const x = (try f.get("X")).@"const";
    try testing.expectEqual(TypeId.f32, x.value.scalar.type);
    try testing.expectEqual(@as(f32, 1.5), @as(f32, @bitCast(@as(u32, @truncate(x.value.scalar.bits)))));
    try testing.expect((try f.get("Y")).@"const".value == .unknown);
    try testing.expect((try f.get("W")).@"const".value == .unknown);
    // X, Y (overflow), Z (`~` on a typed value), W's mismatched operands
    // once only: an operand the hook declined is not asked about again.
    const u8_: TypeId = .int(.unsigned, 8);
    try testing.expectEqualSlices(TypeId, &.{ .f32, u8_, u8_, .none }, rec.asked.items);
}

test "defaults of a generic parameter type wait for instantiation" {
    var f: Fixture = undefined;
    try f.init(&.{.{
        "a",
        \\struct S<T> { x: T = 0 }
        \\fn g<T>(x: T = 0) {}
    }}, null);
    defer f.deinit();
    try f.expectDiags(&.{});
    try expectInt(0, (try f.get("S")).@"struct".fields[0].default.?);
}

test "E0310, E0306: discriminants convert to the backing type" {
    var f: Fixture = undefined;
    try f.init(&.{.{
        "a",
        \\enum E: u8 { a = 1u16, b = 2u8 }
        \\enum F { a = 1.5 }
    }}, null);
    defer f.deinit();
    try f.expectDiags(&.{ .{ .E0310, "1u16" }, .{ .E0306, "1.5" } });
    try expectInt(2, .{ .scalar = (try f.get("E")).@"enum".variants[1].discriminant });
}

test "E0376: recursive containment by value" {
    var f: Fixture = undefined;
    try f.init(&.{.{
        "a",
        \\struct Node { value: u32, next: Node }
        \\struct Tree { value: u32, left: Option<Tree> }
        \\enum Expr { num(i64), neg(Expr) }
        \\struct Wrap<T> { inner: T }
        \\struct A { w: Wrap<A> }
        \\struct X { y: [2]Y }
        \\struct Y { x: (u8, X) }
        \\struct Linked { value: u32, next: Option<Handle<Linked>> }
        \\struct Boxed<T> { h: Handle<T> }
        \\struct B { b: Boxed<B>, items: List<B>, s: []B }
        \\struct Empty {}
        \\struct L<T> { a: Option<L<T>>, b: Option<L<T>>, c: (T, Option<L<T>>) }
        \\struct M { l: L<u8>, k: [2]L<u16> }
    }}, null);
    defer f.deinit();
    try f.expectDiags(&.{
        .{ .E0376, "Node" }, .{ .E0376, "Tree" }, .{ .E0376, "Expr" },
        .{ .E0376, "A" },    .{ .E0376, "X" },    .{ .E0376, "Y" },
        .{ .E0376, "L" },
    });
}

test "E0341: allowed const types; untyped consts stay untyped" {
    var f: Fixture = undefined;
    try f.init(&.{.{
        "a",
        \\struct Point { x: i32, y: i32 }
        \\const LIMIT: u32 = 64;
        \\const DOUBLE = LIMIT * 2;
        \\const PI = 3.14159265358979;
        \\const GREETING: str = "hello";
        \\const SMALL_PRIMES: [4]u32 = [2, 3, 5, 7];
        \\const FIRST_TWO: []u32 = SMALL_PRIMES[0..2];
        \\const ORIGIN: Point = .{ x: 0, y: 0 };
        \\const ELEM: type = u32;
        \\const NAMES: List<u32> = .init();
        \\const COUNTER: Atomic<u32> = .init(0);
        \\const VIEWS: [2][]u8 = [[], []];
        \\const F: File = .{ fd: 0 };
        \\@resource
        \\struct File { fd: i32 }
    }}, null);
    defer f.deinit();
    try f.expectDiags(&.{ .{ .E0341, "List" }, .{ .E0341, "Atomic" }, .{ .E0341, "[" }, .{ .E0341, "File" } });
    const pi = (try f.get("PI")).@"const";
    try testing.expectEqual(TypeId.untyped_float, pi.type);
    try testing.expect(pi.value == .untyped);
    const double = (try f.get("DOUBLE")).@"const";
    try testing.expectEqual(TypeId.int(.unsigned, 32), double.type);
    try expectInt(128, double.value);
    try testing.expectEqual(TypeId.int(.unsigned, 32), (try f.get("ELEM")).@"const".value.type);
}

test "E0311: at most 65 535 variants and fields" {
    for ([_]usize{ max_members, max_members + 1 }) |count| {
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(testing.allocator);
        try src.appendSlice(testing.allocator, "enum E {");
        for (0..count) |i| try src.print(testing.allocator, " v{d},", .{i});
        try src.appendSlice(testing.allocator, " }\nstruct S {");
        for (0..count) |i| try src.print(testing.allocator, " f{d}: u8,", .{i});
        try src.appendSlice(testing.allocator, " }");
        var f: Fixture = undefined;
        try f.init(&.{.{ "a", src.items }}, null);
        defer f.deinit();
        if (count == max_members) {
            try f.expectDiags(&.{});
            try testing.expectEqual(TypeId.int(.unsigned, 16), (try f.get("E")).@"enum".backing);
            try testing.expectEqual(max_members, (try f.get("S")).@"struct".fields.len);
        } else try f.expectDiags(&.{ .{ .E0311, "E" }, .{ .E0311, "S" } });
    }
}

test "aliases, distinct types, type expressions" {
    var f: Fixture = undefined;
    try f.init(&.{.{
        "a",
        \\const N: usize = 4;
        \\type Bytes = [N]u8;
        \\type Meters = distinct f32;
        \\type Loop = Again;
        \\type Again = Loop;
        \\struct Ring<T, CAP: usize> { items: [CAP]T, head: usize = 0 }
        \\struct S {
        \\    a: vec<3, f32>,
        \\    b: Option<Handle<S>>,
        \\    c: mask<4>,
        \\    d: (u8, bool),
        \\    e: *const u8,
        \\    g: fn(mut u8, f32) -> bool,
        \\    h: Ring<u32, 64>,
        \\    i: Bytes,
        \\    j: soa []Self,
        \\    k: Missing,
        \\    l: Result<void, Meters>,
        \\}
    }}, null);
    defer f.deinit();
    try f.expectDiags(&.{ .{ .E0376, "Loop" }, .{ null, "Missing" } });
    try f.expectType("[4]u8", (try f.get("Bytes")).alias);
    const meters = (try f.get("Meters")).distinct;
    try testing.expectEqual(TypeId.f32, f.types.get(meters).nominal.underlying);
    const s = (try f.get("S")).@"struct";
    const want = [_][]const u8{ "vec<3, f32>", "Option<Handle<S>>", "mask<4>", "(u8, bool)", "*const u8", "fn(mut u8, f32) -> bool", "Ring<u32, 64>", "[4]u8", "soa []S", "{error}", "Result<void, Meters>" };
    for (want, s.fields) |w, fld| try f.expectType(w, fld.type);
    const ring = (try f.get("Ring")).@"struct";
    try f.expectType("Ring<T, CAP>", ring.type);
    try testing.expectEqual(f.items.declRef(ring.type).?, f.items.declRef(s.fields[6].type).?);
}

test "signatures, field visibility, associated consts and `Self`" {
    var f: Fixture = undefined;
    try f.init(&.{.{
        "a",
        \\pub struct Player {
        \\    pub health: u8 = 100,
        \\    pub mut speed: f32 = 5.0,
        \\    team_id: u2 = 0,
        \\    pub fn heal(mut self, amount: u8 = Self.MAX_HEALTH) -> mut Self { return self; }
        \\    fn take(move self, comptime n: usize) {}
        \\    pub const MAX_HEALTH: u8 = 100;
        \\}
        \\const NEXT = Player.MAX_HEALTH + 1;
        \\pub fn clamp(x: f32, lo: f32 = 0.0, hi: f32 = 1.0) -> f32 { x }
    }}, null);
    defer f.deinit();
    try f.expectDiags(&.{});
    const p = (try f.get("Player")).@"struct";
    try testing.expectEqual(Visibility.@"pub", p.fields[0].vis);
    try testing.expectEqual(Visibility.pub_mut, p.fields[1].vis);
    try testing.expectEqual(Visibility.private, p.fields[2].vis);
    try f.expectType("u2", p.fields[2].type);
    try testing.expectEqual(1, p.consts.len);
    try expectInt(100, p.consts[0].value);
    const heal = p.methods[0];
    try testing.expect(heal.is_pub and heal.params[0].is_self);
    try testing.expectEqual(Mode.mut, heal.params[0].mode);
    try testing.expectEqual(p.type, heal.params[0].type);
    try expectInt(100, heal.params[1].default.?);
    try f.expectType("mut Player", heal.ret);
    const take = p.methods[1];
    try testing.expect(!take.is_pub);
    try testing.expectEqual(Mode.move, take.params[0].mode);
    try testing.expectEqual(Mode.@"comptime", take.params[1].mode);
    try testing.expectEqual(TypeId.void, take.ret);
    try expectInt(101, (try f.get("NEXT")).@"const".value);
    const clamp = (try f.get("clamp")).@"fn";
    try testing.expectEqual(TypeId.f32, clamp.ret);
    try testing.expectEqual(TypeId.f32, clamp.params[2].default.?.scalar.type);
    try testing.expectEqual(p.type, f.items.structOf(p.type).?.type);
}

test "main: `-> u8` and `-> Result<void, E>` with `E: Display`" {
    const cases = [_]struct { []const u8, ?Main, []const struct { ?diag.DiagCode, []const u8 } }{
        .{ "pub fn main() {}", .void, &.{} },
        .{ "pub fn main() -> u8 { 0 }", .u8, &.{} },
        .{ "enum AppError { bad }\nimpl Display for AppError { fn fmt(self) {} }\npub fn main() -> Result<void, AppError> {}", .result, &.{} },
        .{ "pub fn main() -> Result<void, str> {}", .result, &.{} },
        .{ "enum AppError { bad }\npub fn main() -> Result<void, AppError> {}", null, &.{.{ .E0373, "Result" }} },
        .{ "pub fn main() -> i32 { 0 }", null, &.{.{ .E0310, "i32" }} },
        .{ "fn main() {}", null, &.{.{ null, "main" }} },
        .{ "pub fn main(x: u8) {}", null, &.{.{ null, "main" }} },
        .{ "pub const main: u8 = 0;", null, &.{.{ null, "main" }} },
    };
    for (cases) |c| {
        var f: Fixture = undefined;
        try f.init(&.{.{ "main", c[0] }}, null);
        defer f.deinit();
        try f.expectDiags(c[2]);
        try testing.expectEqual(c[1], f.items.main);
    }
}

test "a library module has no entry point" {
    var f: Fixture = undefined;
    try f.init(&.{.{ "util", "fn main(x: u8) -> i32 { 0 }" }}, null);
    defer f.deinit();
    try f.expectDiags(&.{});
    try testing.expectEqual(null, f.items.main);
}
