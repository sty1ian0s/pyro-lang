//! Field access, method resolution and UFCS (§6.3.2, §6.3.3, §7.2.2, §7.9,
//! §4.4.2, §4.4.3).
//!
//! - `fieldAccess` checks `e.f`: a field of a struct (private fields only
//!   inside the declaring module, §7.3.3), a tuple element `t.0`, the
//!   column `[]F` of a SoA array or slice, or a member of a type path
//!   (`Opcode.load`, `Limits.MAX`). A field of a place is read from the
//!   place (`field` then `load`); a field of a temporary is `extract`ed.
//! - `call` checks `e.m(args)` and `T.f(args)`. A method is, in order, a
//!   function member of the receiver's type, a method of a visible protocol
//!   impl (two of them: E0355, resolved by `P.m(e, args)`), or a free
//!   function whose first parameter accepts the receiver (UFCS). The
//!   receiver is passed by that parameter's mode without a call-site
//!   marker: `view_mut` of its place for `mut`, a view of a resource place,
//!   else its value.
//! - `fieldPlace` is the field step of `mutability.operand`'s places, for
//!   reads, assignments and `mut` arguments.
//!
//! Swizzles are T128's, methods of built-in and standard library types
//! T105's, T108's, T110's, T130's and T163's, and generic receivers T068's
//! and T070's.

const std = @import("std");
const Ast = @import("../ast/Ast.zig");
const Types = @import("types.zig");
const convert = @import("convert.zig");
const items_mod = @import("items.zig");
const kinds = @import("kinds.zig");
const emit_tir = @import("emit_tir.zig");
const attrs_mod = @import("attrs.zig");
const check_expr = @import("check_expr.zig");
const check_stmt = @import("check_stmt.zig");
const check_call = @import("check_call.zig");
const check_literals = @import("check_literals.zig");
const check_index = @import("check_index.zig");
const generics = @import("generics.zig");
const mutability = @import("mutability.zig");
const prelude = @import("../resolve/prelude.zig");
const ModuleId = @import("../resolve/module_graph.zig").ModuleId;

const Node = Ast.Node;
const TypeId = Types.TypeId;
const Checker = emit_tir.Checker;
const Typed = emit_tir.Typed;
const Error = emit_tir.Error;
const Place = mutability.Place;

// ---------------------------------------------------------------------------
// Fields (§6.3.2)

/// `e.f` (§6.3.2): a module member, a member of a type, a field of a place,
/// or a field of a temporary value.
pub fn fieldAccess(c: *Checker, n: Node.Index, expected: TypeId) Error!Typed {
    if (c.items.names.get(c.m, n) != null) return check_expr.ident(c, n, expected);
    const lhs = c.ast.data(n).field_access.lhs;
    if (try typePath(c, lhs)) |ty| return typeMember(c, n, n, ty, null);
    return switch (try mutability.operand(c, n, .read)) {
        .place => |p| if (p.bad()) .{ .ty = p.ty } else .{ .ty = p.ty, .ref = try c.emit(p.ty, .{ .load = .{ .place = p.ref } }) },
        .value => |v| v,
    };
}

/// Field `n` (a `field_access`) of place `base`, used by `access`: it keeps
/// the root, mutability and addressability of `base`, and is not
/// addressable if it is a bit field or a `@packed` field (§4.11.2,
/// §4.11.3). A place of type `.err` after a diagnostic.
pub fn fieldPlace(c: *Checker, n: Node.Index, base: Place, access: mutability.Access) Error!Place {
    const f = try field(c, n, base.ty, access) orelse return .{ .ty = .err };
    return .{
        .ref = try c.emit(f.ty, .{ .field = .{ .base = base.ref, .index = f.index } }),
        .ty = f.ty,
        .root = base.root,
        .mutable = base.mutable,
        .through_ptr = base.through_ptr,
        .unaddressable = base.unaddressable or mutability.unaddressableField(c, base.ty, f.index),
    };
}

/// Field `n` (a `field_access`) of value `v`, the checked left-hand side:
/// `extract`ed from it.
pub fn fieldOfValue(c: *Checker, n: Node.Index, v: Typed) Error!Typed {
    if (v.ty == .err or v.ty == .noreturn) return v;
    if (isColumns(c, v.ty)) return c.unsupported(n, "columns of temporary SoA values (T091)");
    const f = try field(c, n, v.ty, .read) orelse return .err;
    return .{ .ty = f.ty, .ref = try c.emit(f.ty, .{ .extract = .{ .value = v.ref, .index = f.index } }) };
}

/// The type of place expression `n` without emitting anything; null if it
/// is not a place expression rooted at a local, or one of its fields or
/// elements is not found (checking it as a value reports that). `mut T`
/// views are followed.
fn placeType(c: *Checker, n: Node.Index) Error!?TypeId {
    const ty: TypeId = switch (c.ast.kind(n)) {
        .paren => return placeType(c, c.ast.data(n).paren.inner),
        .ident, .self_value => c.b.locals.items(.ty)[(check_call.localOf(c, n) orelse return null).int()],
        .field_access => blk: {
            if (c.items.names.get(c.m, n) != null) return null;
            const base = try placeType(c, c.ast.data(n).field_access.lhs) orelse return null;
            if (base == .err) return null;
            break :blk (try lookupField(c, base, c.ast.tokenSlice(c.ast.mainToken(n))) orelse return null).ty;
        },
        .index => blk: {
            if (check_index.isSlice(c.ast, n)) return null;
            const base = try placeType(c, c.ast.data(n).index.lhs) orelse return null;
            if (base == .err) return null;
            const u = c.underlying(base);
            if (u == .str) break :blk .int(.unsigned, 8);
            break :blk switch (c.types.get(u)) {
                inline .array, .soa_array, .slice, .soa_slice, .vec, .ptr => |x| x.elem,
                else => return null,
            };
        },
        else => return null,
    };
    return switch (c.types.get(ty)) {
        .mut_view => |v| v.elem,
        else => ty,
    };
}

const Field = struct { index: u32, ty: TypeId };

/// Field `name` of a value of type `ty`, without visibility checks.
fn lookupField(c: *Checker, ty: TypeId, name: []const u8) Error!?Field {
    switch (c.types.get(ty)) {
        .tuple => |t| {
            const i = std.fmt.parseInt(u32, name, 10) catch return null;
            return if (i < t.elems.len) .{ .index = i, .ty = t.elems[i] } else null;
        },
        // `a.f` of `soa [N]T` or `soa []T` is the column view `[]F` (§4.4.2).
        inline .soa_array, .soa_slice => |x| {
            const f = try lookupField(c, x.elem, name) orelse return null;
            return .{ .index = f.index, .ty = try c.types.intern(.{ .slice = .{ .elem = f.ty } }) };
        },
        else => {
            const s = c.items.structOf(ty) orelse return null;
            for (s.fields, 0..) |f, i| if (std.mem.eql(u8, f.name, name)) return .{ .index = @intCast(i), .ty = f.type };
            return null;
        },
    }
}

/// Field `n` (a `field_access`) of a value of type `ty`, reported if it is
/// missing or not visible for `access` here (§7.3.3).
fn field(c: *Checker, n: Node.Index, ty: TypeId, access: mutability.Access) Error!?Field {
    const name = c.ast.tokenSlice(c.ast.mainToken(n));
    switch (c.types.get(ty)) {
        .vec => {
            _ = c.unsupported(n, "swizzles (T128)");
            return null;
        },
        .nominal => |nm| if (nm.kind == .protocol) {
            c.failed = true; // a protocol as a type is E0375
            return null;
        } else if (nm.args.len > 0 and if (c.items.structOf(ty)) |s| s.generics.len > 0 else false) {
            _ = c.unsupported(n, "fields of generic struct instances (T070)");
            return null;
        } else if (c.items.declRef(ty) == null and nm.kind == .@"struct") {
            _ = c.unsupported(n, "fields of standard library types (T163)");
            return null;
        },
        .soa_array, .soa_slice => if (access == .write) {
            try c.reportAt(c.ast.mainToken(n), .E0207, &.{"a SoA column is a view: assign its elements, `a.f[i] = v` (§4.4.2)"}, "cannot assign to column `{s}`", .{name});
            return null;
        },
        else => {},
    }
    const f = try lookupField(c, ty, name) orelse {
        try c.reportAt(c.ast.mainToken(n), null, &.{}, "no field `{s}` on type `{s}`", .{ name, try c.tyName(ty) });
        return null;
    };
    // A SoA column is as visible as the element's field.
    const owner = switch (c.types.get(ty)) {
        inline .soa_array, .soa_slice => |x| x.elem,
        else => ty,
    };
    if (c.types.get(owner) != .nominal) return f;
    const ref = c.items.declRef(owner).?;
    if (ref.module == c.m) return f;
    const vis = c.items.structOf(owner).?.fields[f.index].vis;
    if (vis == .private or (access == .write and vis != .pub_mut)) {
        const help: []const []const u8 = if (vis == .private) &.{"private fields are visible only inside the declaring module (§7.3.3)"} else &.{"only `pub mut` fields can be written outside the declaring module (§7.3.3)"};
        try c.reportAt(c.ast.mainToken(n), null, help, "field `{s}` of `{s}` is {s} outside its module", .{ name, try c.tyName(ty), if (vis == .private) "private" else "read-only" });
        return null;
    }
    return f;
}

fn isColumns(c: *Checker, ty: TypeId) bool {
    return switch (c.types.get(ty)) {
        .soa_array, .soa_slice => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Type paths (`T.name`, §6.3.3, §7.2.2)

/// The type that `lhs` of `lhs.name` names (`Opcode`, `geo.Point`, `Self`,
/// a prelude type), or null if it is a value.
pub fn typePath(c: *Checker, lhs: Node.Index) Error!?TypeId {
    switch (c.ast.kind(lhs)) {
        .self_type => return if (c.self_ty == .none) null else c.self_ty,
        .call => return generics.applied(c, lhs),
        .ident, .field_access => {},
        else => return null,
    }
    const e = c.items.names.get(c.m, lhs) orelse return null;
    const t = switch (e.res) {
        .global => |t| t,
        .local => return null,
    };
    switch (t) {
        .item => |ref| return switch ((try c.items.info(ref)).*) {
            .@"struct" => |s| s.type,
            .@"enum" => |en| en.type,
            .protocol, .alias, .distinct => |ty| ty,
            else => null,
        },
        .prelude => |name| {
            const is_type = prelude.isIntTypeName(name) or for (prelude.entries) |p| {
                if (std.mem.eql(u8, p.name, name)) break p.kind == .type or p.kind == .protocol;
            } else false;
            return if (is_type) try c.resolveType(lhs) else null;
        },
        else => return null,
    }
}

/// Member `fa` (a `field_access`) of type `ty`, called with `args` at call
/// `at` or used as a value (`args` null, `at == fa`): a variant, a
/// `const`, or a member function (§6.3.3, §7.2.2).
fn typeMember(c: *Checker, fa: Node.Index, at: Node.Index, ty: TypeId, args: ?[]const Node.Index) Error!Typed {
    if (ty == .err) return failed(c, args);
    const name = c.ast.tokenSlice(c.ast.mainToken(fa));
    const nm = switch (c.types.get(ty)) {
        .nominal => |x| x,
        else => {
            _ = c.unsupported(fa, "members of built-in types (T105)");
            return failed(c, args);
        },
    };
    if (nm.kind == .protocol) return protocolCall(c, fa, at, ty, args);
    const ref = c.items.declRef(ty) orelse {
        _ = c.unsupported(fa, if (nm.lang == .option or nm.lang == .result) "members of `Option` and `Result` (T105)" else "members of standard library types (T163)");
        return failed(c, args);
    };
    const type_generics: []const TypeId, const consts: []const items_mod.Const, const methods: []const items_mod.Fn = switch ((try generics.infoOf(c.items, ty, ref)).*) {
        .@"struct" => |s| .{ s.generics, s.consts, s.methods },
        .@"enum" => |e| blk: {
            for (e.variants, 0..) |v, i| if (std.mem.eql(u8, v.name, name)) {
                if (e.generics.len > 0) {
                    _ = c.unsupported(fa, "variants of generic enums (T070)");
                    return failed(c, args);
                }
                return check_literals.variant(c, at, name, ty, @intCast(i), v.payload, args);
            };
            break :blk .{ e.generics, e.consts, e.methods };
        },
        else => .{ &.{}, &.{}, &.{} },
    };
    if (type_generics.len > 0) {
        _ = c.unsupported(fa, "members of generic types (T070)");
        return failed(c, args);
    }
    // Members are visible subject to their own `pub` (§7.9).
    const outside = ref.module != c.m;
    if (args == null) for (consts) |k| if (std.mem.eql(u8, k.name, name)) {
        if (outside and !k.is_pub) return private(c, fa, "constant", name, ty, null);
        try warnDeprecated(c, fa, ref.module, c.items.attrsOf(ref.module, k.node));
        return check_expr.constValue(c, fa, k);
    };
    for (methods) |f| if (std.mem.eql(u8, f.name, name)) {
        if (outside and !f.is_pub) return private(c, fa, "function", name, ty, args);
        try warnDeprecated(c, fa, ref.module, f.attrs);
        const a = args orelse return check_call.fnOf(c, fa, ref.module, f);
        return check_call.callFn(c, at, ref.module, f, null, a);
    };
    // A member of a visible `impl P for T` (§6.3.3 step 1).
    if (c.bodies.protos) |protos| {
        const found = try protos.findMethods(c.m, ty, name);
        if (found.len > 1) {
            try ambiguous(c, fa, ty, found);
            return failed(c, args);
        }
        if (found.len == 1) {
            const callee = try fromImpl(c, fa, found[0]) orelse return failed(c, args);
            try warnDeprecated(c, fa, callee.m, callee.f.attrs);
            const a = args orelse return check_call.fnOf(c, fa, callee.m, callee.f);
            return check_call.callFn(c, at, callee.m, callee.f, null, a);
        }
    } else if (beforeProtos(c, fa)) return failed(c, args);
    try c.reportAt(c.ast.mainToken(fa), null, &.{}, "no member `{s}` in `{s}`", .{ name, try c.tyName(ty) });
    return failed(c, args);
}

/// W0802 at member `fa` if `attrs`, its declaration's attributes in module
/// `m`, mark it `@deprecated` (§8.8).
fn warnDeprecated(c: *Checker, fa: Node.Index, m: ModuleId, attrs: []const Node.Index) Error!void {
    const da = c.items.im.graph.modules[m].ast;
    const at = attrs_mod.deprecated(da, attrs) orelse return;
    const help: []const []const u8 = if (attrs_mod.deprecationNote(da, at)) |note| &.{note} else &.{};
    try c.reportAt(c.ast.mainToken(fa), .W0802, help, "`{s}` is deprecated", .{c.ast.tokenSlice(c.ast.mainToken(fa))});
}

fn private(c: *Checker, fa: Node.Index, what: []const u8, name: []const u8, ty: TypeId, args: ?[]const Node.Index) Error!Typed {
    try c.reportAt(c.ast.mainToken(fa), null, &.{"mark it `pub` to use it outside its module (§7.9)"}, "{s} `{s}` of `{s}` is private", .{ what, name, try c.tyName(ty) });
    return failed(c, args);
}

/// `P.m(e, args)` (§6.3.3): method `m` of protocol `P`'s impl for the type
/// of `e`, which resolves an ambiguity (E0355).
fn protocolCall(c: *Checker, fa: Node.Index, at: Node.Index, proto: TypeId, args_in: ?[]const Node.Index) Error!Typed {
    const name = c.ast.tokenSlice(c.ast.mainToken(fa));
    const args = args_in orelse &.{};
    if (args_in == null or args.len == 0 or c.ast.kind(args[0]) == .named_arg) {
        try c.reportAt(c.ast.mainToken(fa), null, &.{"pass the receiver first: `P.m(e, args)`"}, "protocol method `{s}.{s}` needs a receiver", .{ try c.tyName(proto), name });
        return failed(c, args_in);
    }
    const r = try receiver(c, check_call.unwrapArg(c.ast, args[0]));
    if (r.ty == .err or r.ty == .noreturn) return failedAfter(c, r, args[1..]);
    const protos = c.bodies.protos orelse {
        _ = c.unsupported(fa, "protocol methods without protocol checking (T044)");
        return failed(c, args[1..]);
    };
    for (try protos.findMethods(c.m, r.ty, name)) |mr| if (mr.protocol == proto) {
        const impl = try fromImpl(c, fa, mr) orelse return failed(c, args[1..]);
        const callee = try asMethod(c, fa, r.ty, impl) orelse return failed(c, args[1..]);
        try warnDeprecated(c, fa, callee.m, callee.f.attrs);
        return methodCall(c, at, callee, r, args[1..]);
    };
    try c.reportAt(c.ast.mainToken(fa), null, &.{}, "`{s}` has no method `{s}` from `{s}`", .{ try c.tyName(r.ty), name, try c.tyName(proto) });
    return failed(c, args[1..]);
}

// ---------------------------------------------------------------------------
// Method calls (§6.3.3)

/// Call `n` whose callee is a `field_access` that is not a module member:
/// `T.f(args)` or `e.m(args)`.
pub fn call(c: *Checker, n: Node.Index, _: TypeId) Error!Typed {
    const d = c.ast.data(n).call;
    const lhs = c.ast.data(d.callee).field_access.lhs;
    if (try typePath(c, lhs)) |ty| return typeMember(c, d.callee, n, ty, d.args);
    const r = try receiver(c, lhs);
    if (r.ty == .err or r.ty == .noreturn) return failedAfter(c, r, d.args);
    const callee = try resolve(c, d.callee, r.ty) orelse return failed(c, d.args);
    try warnDeprecated(c, d.callee, callee.m, callee.f.attrs);
    return methodCall(c, n, callee, r, d.args);
}

/// A receiver typed before its method is known: a place expression
/// (`value` null: nothing emitted yet, the parameter mode decides how it
/// is passed) or a checked value. For a `mut T` view value (a `-> mut
/// Self` result, §5.5.4) `ty` is `T`.
const Receiver = struct { node: Node.Index, ty: TypeId, value: ?Typed };

fn receiver(c: *Checker, e: Node.Index) Error!Receiver {
    if (try placeType(c, e)) |ty| return .{ .node = e, .ty = ty, .value = null };
    const v = try c.materialize(try check_expr.check(c, e, .none), e);
    const ty = if (v.ty != .err and c.types.get(v.ty) == .mut_view) c.types.get(v.ty).mut_view.elem else v.ty;
    return .{ .node = e, .ty = ty, .value = v };
}

/// A function a method call resolves to, declared in module `m`.
const Callee = struct { m: ModuleId, f: items_mod.Fn };

/// The function `e.name(...)` calls for a receiver of type `ty` (§6.3.3),
/// or null after a diagnostic. `fa` is the callee `field_access`.
fn resolve(c: *Checker, fa: Node.Index, ty: TypeId) Error!?Callee {
    const name = c.ast.tokenSlice(c.ast.mainToken(fa));
    if (c.types.get(ty) == .nominal and c.types.get(ty).nominal.kind == .protocol) {
        c.failed = true; // a protocol as a type is E0375
        return null;
    }
    // 1. A function member of the type, or of a visible protocol impl (§7.9).
    if (c.items.declRef(ty)) |ref| {
        const type_generics: []const TypeId, const methods: []const items_mod.Fn = switch ((try generics.infoOf(c.items, ty, ref)).*) {
            .@"struct" => |s| .{ s.generics, s.methods },
            .@"enum" => |e| .{ e.generics, e.methods },
            else => .{ &.{}, &.{} },
        };
        for (methods) |f| if (std.mem.eql(u8, f.name, name)) {
            if (type_generics.len > 0) return unsupported(c, fa, "methods of generic types (T070)");
            if (ref.module != c.m and !f.is_pub) {
                _ = try private(c, fa, "method", name, ty, null);
                return null;
            }
            return asMethod(c, fa, ty, .{ .m = ref.module, .f = f });
        };
    }
    if (c.bodies.protos) |protos| {
        const found = try protos.findMethods(c.m, ty, name);
        if (found.len > 1) {
            try ambiguous(c, fa, ty, found);
            return null;
        }
        if (found.len == 1) return asMethod(c, fa, ty, try fromImpl(c, fa, found[0]) orelse return null);
    } else if (beforeProtos(c, fa)) return null;
    // 2. UFCS: a free function visible by name whose first parameter accepts `ty`.
    // shortcut: locals do not shadow it here; a local function pointer is not a free function.
    if (c.items.im.lookup(c.m, name)) |t| if (t == .item) switch ((try c.items.info(t.item)).*) {
        .@"fn" => |f| if (f.params.len > 0 and accepts(c, f.params[0], ty)) return .{ .m = t.item.module, .f = f },
        else => {},
    };
    // shortcut: members of built-in and standard library types are not
    // known yet, so a UFCS function above may wrongly win over one of them.
    switch (c.types.get(ty)) {
        .array, .slice, .soa_array, .soa_slice => return unsupported(c, fa, "methods of arrays and slices (T110)"),
        .vec, .mask => return unsupported(c, fa, "methods of vectors (T128)"),
        .nominal => |nm| if (c.items.declRef(ty) == null) {
            if (nm.lang == .atomic or nm.lang == .channel) @import("purity.zig").note(c, fa, if (nm.lang == .atomic) .atomic else .channel);
            return unsupported(c, fa, switch (nm.lang) {
                .option, .result => "methods of `Option` and `Result` (T105)",
                .atomic => "methods of `Atomic` (T130)",
                else => "methods of standard library types (T163)",
            });
        },
        .param => return unsupported(c, fa, "methods of generic parameters (T070)"),
        else => if (ty == .str) return unsupported(c, fa, "methods of `str` (T108)"),
    }
    try c.reportAt(c.ast.mainToken(fa), null, &.{}, "no method `{s}` on type `{s}`", .{ name, try c.tyName(ty) });
    return null;
}

/// E0355: more than one visible protocol impl for `ty` provides member `fa`.
fn ambiguous(c: *Checker, fa: Node.Index, ty: TypeId, found: []const @import("protocols.zig").MethodRef) Error!void {
    const name = c.ast.tokenSlice(c.ast.mainToken(fa));
    var help: std.Io.Writer.Allocating = .init(c.arena);
    for (found, 0..) |mr, i| help.writer.print("{s}`{s}.{s}(e, ...)`", .{ if (i == 0) "call one explicitly: " else " or ", try c.tyName(mr.protocol), name }) catch return error.OutOfMemory;
    try c.reportAt(c.ast.mainToken(fa), .E0355, &.{help.written()}, "ambiguous method `{s}`: {d} protocol impls for `{s}` provide it", .{ name, found.len, try c.tyName(ty) });
}

/// `callee`, a member `fa` of `ty`, if its first parameter is `self`;
/// otherwise null after reporting it as an associated function.
fn asMethod(c: *Checker, fa: Node.Index, ty: TypeId, callee: Callee) Error!?Callee {
    if (callee.f.params.len > 0 and callee.f.params[0].is_self) return callee;
    const name = c.ast.tokenSlice(c.ast.mainToken(fa));
    try c.reportAt(c.ast.mainToken(fa), null, &.{try std.fmt.allocPrint(c.arena, "call it on the type: `{s}.{s}(...)`", .{ try c.tyName(ty), name })}, "`{s}` is an associated function of `{s}`, not a method", .{ name, try c.tyName(ty) });
    return null;
}

/// Whether bodies are checked before protocols (comptime calls during item
/// checking), where member `fa` may come from an impl not known yet: then
/// the body stops as unsupported and is checked again later.
fn beforeProtos(c: *Checker, fa: Node.Index) bool {
    if (!c.bodies.before_protos) return false;
    _ = c.unsupported(fa, "impl methods called from comptime code in item positions");
    if (c.bodies.ids.get(.{ c.m, c.sig.node })) |id| c.bodies.fns.items[id.int()].retry = true;
    return true;
}

fn unsupported(c: *Checker, n: Node.Index, what: []const u8) ?Callee {
    _ = c.unsupported(n, what);
    return null;
}

/// The impl method `mr` found by `Protocols.findMethods`, if it has a
/// concrete body.
fn fromImpl(c: *Checker, fa: Node.Index, mr: @import("protocols.zig").MethodRef) Error!?Callee {
    const impl = mr.impl orelse return unsupported(c, fa, "methods through generic bounds (T070)");
    if (impl.generics.len > 0) return unsupported(c, fa, "methods of generic impls (T070)");
    for (impl.methods) |f| if (f.node == mr.f.node) return .{ .m = impl.src.module, .f = f };
    return unsupported(c, fa, "protocol default methods (T070)");
}

/// Whether first parameter `p` accepts a receiver of type `ty` (UFCS).
fn accepts(c: *Checker, p: items_mod.Param, ty: TypeId) bool {
    if (p.type == ty) return true;
    return p.mode == .value and convert.coerce(c.types, ty, p.type, .{}) != .none;
}

/// Calls `callee` with receiver `r` as its first argument, passed by that
/// parameter's mode without a call-site marker (§6.3.3), then `args`.
fn methodCall(c: *Checker, n: Node.Index, callee: Callee, r: Receiver, args: []const Node.Index) Error!Typed {
    const recv = try pass(c, r, callee.f.params[0]);
    return check_call.callFn(c, n, callee.m, callee.f, recv, args);
}

/// Receiver `r` passed to parameter `p` (§5.5.2).
fn pass(c: *Checker, r: Receiver, p: items_mod.Param) Error!Typed {
    if (p.type == .err) {
        c.failed = true; // reported with the signature
        return .err;
    }
    switch (p.mode) {
        .@"comptime" => return c.unsupported(r.node, "calls of functions with `comptime` parameters (T063)"),
        .mut => {
            if (r.value) |v| {
                // A `mut T` view is passed on as it is (§4.5.3).
                if (v.ty != r.ty and r.ty == p.type) return v;
                if (v.ty != r.ty) {
                    try c.mismatch(r.node, p.type, r.ty);
                    return .err;
                }
                try c.reportAt(check_stmt.firstToken(c.ast, r.node), .E0336, &.{"bind the value with `let mut` first"}, "receiver of a `mut` parameter is not a mutable place", .{});
                return .err;
            }
            const pl = try receiverPlace(c, r, .write) orelse return .err;
            if (pl.bad()) return .{ .ty = pl.ty };
            if (!try mutability.require(c, pl, r.node, .receiver)) return .err;
            if (pl.ty != p.type) {
                try c.mismatch(r.node, p.type, pl.ty);
                return .err;
            }
            const view = try c.types.intern(.{ .mut_view = .{ .elem = pl.ty } });
            return .{ .ty = view, .ref = try c.emit(view, .{ .view_mut = .{ .place = pl.ref } }) };
        },
        .move => if (try kinds.kind(c.items, p.type) != .plain) return c.unsupported(r.node, "`move` arguments (T080)"),
        .value => {},
    }
    if (r.value) |v| return c.coerce(v, p.type, r.node);
    const pl = try receiverPlace(c, r, .read) orelse return .err;
    if (pl.bad()) return .{ .ty = pl.ty };
    // A resource or shared cell is passed as a view of its place (§5.5.2, §5.1).
    const kind = if (p.mode == .value) try kinds.kind(c.items, p.type) else .plain;
    if (pl.ty == p.type and (kind == .resource or kind == .shared_cell))
        return .{ .ty = pl.ty, .ref = try c.emit(pl.ty, .{ .view = .{ .place = pl.ref } }) };
    return c.coerce(.{ .ty = pl.ty, .ref = try c.emit(pl.ty, .{ .load = .{ .place = pl.ref } }) }, p.type, r.node);
}

/// The place of receiver `r`, a place expression (`placeType`); null if
/// it checked as a value after all (not expected; the body fails).
fn receiverPlace(c: *Checker, r: Receiver, access: mutability.Access) Error!?Place {
    switch (try mutability.operand(c, r.node, access)) {
        .place => |pl| return pl,
        .value => {
            c.failed = true;
            return null;
        },
    }
}

/// Checks the arguments of a failed call for their own errors.
fn failed(c: *Checker, args: ?[]const Node.Index) Error!Typed {
    if (args) |a| return check_call.failedArgs(c, a);
    c.failed = true;
    return .err;
}

/// Like `failed`, after receiver `r` that failed or diverges.
fn failedAfter(c: *Checker, r: Receiver, args: []const Node.Index) Error!Typed {
    const v = try failed(c, args);
    return if (r.ty == .noreturn and !c.failed) .never else v;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const Fixture = emit_tir.Fixture;

test "UFCS to a `mut` first parameter and `mut self` need no marker" {
    var f: Fixture = undefined;
    try f.init(
        \\struct Player {
        \\    pub mut health: u8,
        \\    pub fn hurt(mut self, amount: u8) { self.health -= amount; }
        \\}
        \\fn heal(mut p: Player, amount: u8) { p.health += amount; }
        \\fn tick(mut p: Player) {
        \\    p.heal(2);
        \\    p.hurt(1);
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    try f.expectDump("tick",
        \\fn tick(l0 mut p: Player) -> void {
        \\b0:
        \\  %0: Player = local l0
        \\  %1: mut Player = view_mut %0
        \\  %2: u8 = int 2
        \\  call @1, [%1, %2]
        \\  %4: Player = local l0
        \\  %5: mut Player = view_mut %4
        \\  %6: u8 = int 1
        \\  call @0, [%5, %6]
        \\  ret _
        \\}
        \\
    );
}

test "a type member beats UFCS; receivers of `mut self` must be mutable" {
    var f: Fixture = undefined;
    try f.init(
        \\struct Bot {
        \\    n: u32,
        \\    pub fn speed(self) -> u32 { self.n }
        \\    pub fn bump(mut self) { self.n += 1; }
        \\    pub fn new() -> Bot { Bot { n: 0 } }
        \\}
        \\fn speed(b: Bot) -> bool { true }
        \\fn make() -> Bot { Bot.new() }
        \\fn demo(b: Bot) -> u32 { b.speed() + make().speed() }
        \\fn bad(b: Bot) {
        \\    b.bump();
        \\    make().bump();
        \\    b.new();
        \\    b.fly();
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{ .{ .E0338, "b" }, .{ .E0336, "make" }, .{ null, "new" }, .{ null, "fly" } });
    try f.expectDump("demo",
        \\fn demo(l0 b: Bot) -> u32 {
        \\b0:
        \\  %0: Bot = local l0
        \\  %1: Bot = load %0
        \\  %2: u32 = call @0, [%1]
        \\  %3: Bot = call @4, []
        \\  %4: u32 = call @0, [%3]
        \\  %5: u32 = add %2, %4
        \\  ret %5
        \\}
        \\
    );
}

test "E0355: two protocol impls provide the method; `Protocol.m(e)` resolves it" {
    var f: Fixture = undefined;
    try f.init(
        \\pub protocol Walk { fn step(self) -> u32; }
        \\pub protocol Dance { fn step(self) -> u32; }
        \\struct Bot { n: u32 }
        \\impl Walk for Bot { fn step(self) -> u32 { self.n } }
        \\impl Dance for Bot { fn step(self) -> u32 { self.n * 2 } }
        \\fn ok(b: Bot) -> u32 { Walk.step(b) + Dance.step(b) }
        \\fn bad(b: Bot) -> u32 { b.step() }
    );
    defer f.deinit();
    try f.expectDiags(&.{.{ .E0355, "step" }});
    try f.expectDump("ok",
        \\fn ok(l0 b: Bot) -> u32 {
        \\b0:
        \\  %0: Bot = local l0
        \\  %1: Bot = load %0
        \\  %2: u32 = call @1, [%1]
        \\  %3: Bot = local l0
        \\  %4: Bot = load %3
        \\  %5: u32 = call @2, [%4]
        \\  %6: u32 = add %2, %5
        \\  ret %6
        \\}
        \\
    );
}

test "associated functions of protocol impls: `T.f()` finds them, `e.f()` rejects them" {
    var f: Fixture = undefined;
    try f.init(
        \\pub protocol Make { fn make() -> Self; fn conv(x: u32) -> Self; }
        \\struct Bot { n: u32 }
        \\impl Make for Bot {
        \\    fn make() -> Bot { Bot { n: 0 } }
        \\    fn conv(x: u32) -> Bot { Bot { n: x } }
        \\}
        \\fn ok() -> Bot { Bot.make() }
        \\fn bad(b: Bot) {
        \\    b.make();
        \\    Make.make(b);
        \\    b.conv();
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{ .{ null, "make" }, .{ null, "make" }, .{ null, "conv" } });
    try f.expectDump("ok",
        \\fn ok() -> Bot {
        \\b0:
        \\  %0: Bot = call @1, []
        \\  ret %0
        \\}
        \\
    );
}

test "fields: private fields are rejected outside their module, `pub` ones are read-only" {
    var f: Fixture = undefined;
    try f.initPackage(&.{
        .{
            "a",
            \\use geo.{Point, origin};
            \\fn demo(mut p: Point) -> f32 {
            \\    p.z = 1.0;
            \\    p.y = 2.0;
            \\    p.x + p.y + origin().x
            \\}
            \\fn column(ps: soa []Point) -> []f32 { ps.x }
        },
        .{ "geo", "pub struct Point { x: f32, pub y: f32, pub mut z: f32 }\npub fn origin() -> Point { Point { x: 0.0, y: 0.0, z: 0.0 } }\nfn own(p: Point) -> f32 { p.x }" },
    });
    defer f.deinit();
    try f.expectDiags(&.{ .{ null, "y" }, .{ null, "x" }, .{ null, "x" }, .{ null, "x" } });
}

test "fields: SoA columns are `[]F`, tuples, temporaries, nested writes" {
    var f: Fixture = undefined;
    try f.init(
        \\struct Particle { x: f32, y: f32 }
        \\struct Pair { a: Particle, t: (u8, bool) }
        \\fn column(ps: soa []Particle) -> []f32 { ps.y }
        \\fn make() -> Pair { Pair { a: Particle { x: 1.0, y: 2.0 }, t: (1, true) } }
        \\fn nested(mut p: Pair) -> u8 {
        \\    p.a.x = make().a.y;
        \\    p.t.0 + 1
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    try f.expectDump("column",
        \\fn column(l0 ps: soa []Particle) -> []f32 {
        \\b0:
        \\  %0: soa []Particle = local l0
        \\  %1: []f32 = field %0, 1
        \\  %2: []f32 = load %1
        \\  ret %2
        \\}
        \\
    );
    try f.expectDump("nested",
        \\fn nested(l0 mut p: Pair) -> u8 {
        \\b0:
        \\  %0: Pair = local l0
        \\  %1: Particle = field %0, 0
        \\  %2: f32 = field %1, 0
        \\  %3: Pair = call @1, []
        \\  %4: Particle = extract %3, 0
        \\  %5: f32 = extract %4, 1
        \\  store %2, %5
        \\  %7: Pair = local l0
        \\  %8: (u8, bool) = field %7, 1
        \\  %9: u8 = field %8, 0
        \\  %10: u8 = load %9
        \\  %11: u8 = int 1
        \\  %12: u8 = add %10, %11
        \\  ret %12
        \\}
        \\
    );
}

test "fields and type paths: errors" {
    var f: Fixture = undefined;
    try f.init(
        \\enum Op: u8 { nop, load }
        \\struct S { a: u8, const K: u8 = 3; }
        \\fn make() -> S { S { a: 1 } }
        \\fn bad(s: S, t: (u8, u8)) -> u8 {
        \\    s.a = 1;
        \\    make().a = 2;
        \\    let x = s.b + t.2;
        \\    let y = Op.store;
        \\    (Op.load as u8) + S.K
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{ .{ .E0338, "s" }, .{ .E0207, "a" }, .{ null, "b" }, .{ null, "2" }, .{ null, "store" } });
}
