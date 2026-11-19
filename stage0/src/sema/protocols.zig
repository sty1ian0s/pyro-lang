//! Protocols (§7.5, §7.9): declarations, `impl` blocks, coherence and
//! bounds.
//!
//! `check` runs after `items.check` and reports the package-level rules:
//!
//! - every `impl P for T` defines each required method of `P` with the
//!   exact signature, where `Self` = `T`, and nothing `P` does not declare
//!   (§7.5.1, E0378); default methods may be overridden, with the same
//!   signature;
//! - coherence: an impl lives in the module of `P` or of `T`, and no two
//!   impls of `P` overlap on one type (§7.5.1, E0379);
//! - a protocol is not a type (§7.5, E0375) in item signatures, fields,
//!   payloads, aliases, consts and impl targets.
//!
//! Entry points for the expression checker (T043) and generic
//! instantiation (T064):
//!
//! - `checkCallBounds(site, generics, args)`: the bound check of a call (or
//!   instantiation) once its generic arguments are known; reports E0373
//!   (§7.5.2) and, through `Options.plain_hook`, E0329 (§7.6.1) at `site`;
//! - `satisfies(ty, protocol)` / `implFor(protocol, ty)`: impl lookup;
//! - `findMethod(m, ty, name)`: method syntax through impls visible in
//!   module `m` (§7.9) or the bounds of a type parameter;
//! - `checkType(m, node, ty)`: E0375 for a type written in a body
//!   (`let x: Shape`);
//! - `protocolOf`, `boundsOf`, `subst`: declarations and substitution.
//!
//! A protocol's `Self` is a `.param` type of the protocol declaration whose
//! index is one past its generic parameters (`Protocol.self`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const diag = @import("../diag/diag.zig");
const Ast = @import("../ast/Ast.zig");
const Types = @import("types.zig");
const items_mod = @import("items.zig");
const imports = @import("../resolve/imports.zig");
const module_graph = @import("../resolve/module_graph.zig");

const Node = Ast.Node;
const TypeId = Types.TypeId;
const ModuleId = module_graph.ModuleId;
const Target = imports.Target;
const Items = items_mod.Items;
const Fn = items_mod.Fn;
const Error = Allocator.Error;

/// Decides whether a type is plain (§5.1), for the `plain` bound.
/// Installed by type kinds (T042); without it `plain` bounds are not checked.
pub const PlainHook = struct {
    ctx: ?*anyopaque = null,
    isPlain: *const fn (ctx: ?*anyopaque, ty: TypeId) Error!bool,
};

pub const Options = struct {
    plain_hook: ?PlainHook = null,
};

/// One method of a protocol, in terms of `Protocol.self`.
pub const Method = struct {
    f: Fn,
    /// A default method (with a body), which impls may omit.
    has_default: bool,
};

/// A protocol declaration of this package (§7.5.1).
pub const Protocol = struct {
    /// The protocol applied to its own generic parameters.
    type: TypeId,
    /// `Self` inside the protocol.
    self: TypeId,
    generics: []const TypeId,
    methods: []const Method,

    pub fn method(p: *const Protocol, name: []const u8) ?*const Method {
        for (p.methods) |*m| if (std.mem.eql(u8, m.f.name, name)) return m;
        return null;
    }
};

/// An `impl P for T` block.
pub const Impl = struct {
    src: imports.Impl,
    /// Generic parameters of `impl<...>`.
    generics: []const TypeId,
    /// `P` with its arguments; `.err` if it is not a protocol.
    protocol: TypeId,
    target: TypeId,
    /// The methods, with `Self` = `target`.
    methods: []const Fn,
};

/// The bounds of a type parameter (§7.5.2, §7.6.1).
pub const Bounds = struct {
    /// Protocol types, possibly in terms of other parameters of the same
    /// declaration (`T: From<E>`).
    protocols: []const TypeId = &.{},
    plain: bool = false,
};

/// A method found by `findMethod`.
pub const MethodRef = struct {
    /// The signature. A default method or a method through a bound is in
    /// terms of the protocol's `Self` (and generics): `subst` them.
    f: Fn,
    protocol: TypeId,
    /// The impl providing it; null for a method through a parameter's bound.
    impl: ?*const Impl,
    /// The impl's generic arguments for this receiver (`.none` if unbound).
    args: []const TypeId = &.{},
};

/// The protocols and impls of one package. Borrows `Items`.
pub const Protocols = struct {
    arena: *std.heap.ArenaAllocator,
    sink: *diag.Sink,
    items: *Items,
    options: Options,
    impls: []Impl = &.{},
    /// By the protocol's `Types.Decl.index`.
    protos: std.AutoHashMapUnmanaged(u32, Protocol) = .empty,
    bounds: std.AutoHashMapUnmanaged(TypeId, Bounds) = .empty,
    /// Recursion depth of `satisfies` through bounded generic impls.
    depth: u32 = 0,

    pub fn deinit(p: *Protocols) void {
        const gpa = p.arena.child_allocator;
        p.arena.deinit();
        gpa.destroy(p.arena);
        p.* = undefined;
    }

    fn alloc(p: *Protocols) Allocator {
        return p.arena.allocator();
    }

    fn types(p: *Protocols) *Types {
        return p.items.types;
    }

    fn ast(p: *const Protocols, m: ModuleId) *const Ast {
        return p.items.im.graph.modules[m].ast;
    }

    fn tokSpan(p: *const Protocols, m: ModuleId, t: Ast.TokenIndex) diag.Span {
        const a = p.ast(m);
        const start = a.tokens.items(.start)[t];
        return .{ .file = p.items.im.graph.modules[m].file, .start = start, .end = start + a.tokens.items(.len)[t] };
    }

    fn report(p: *Protocols, span: diag.Span, code: ?diag.DiagCode, help: []const []const u8, comptime fmt: []const u8, args: anytype) Error!void {
        try p.sink.emit(.{
            .code = code,
            .severity = if (code) |c| .of(c) else .@"error",
            .message = try std.fmt.allocPrint(p.alloc(), fmt, args),
            .spans = &.{.{ .span = span, .primary = true }},
            .help = help,
        });
    }

    fn tyName(p: *Protocols, ty: TypeId) Error![]const u8 {
        return p.types().allocPrint(p.alloc(), ty, .{});
    }

    /// The module and node of declaration `d` of this package.
    fn locate(p: *const Protocols, d: Types.Decl) ?struct { ModuleId, Node.Index } {
        if (!std.meta.eql(d.package, p.items.options.package)) return null;
        var m = p.items.mods.len;
        while (m > 0) {
            m -= 1;
            const base = p.items.mods[m].base;
            if (base <= d.index) return .{ @intCast(m), .from(d.index - base) };
        }
        return null;
    }

    fn decl(p: *const Protocols, m: ModuleId, n: Node.Index) Types.Decl {
        return .{ .package = p.items.options.package, .index = p.items.mods[m].base + n.int() };
    }

    fn isStd(p: *const Protocols, d: Types.Decl) bool {
        return std.meta.eql(d.package, p.items.std_pkg);
    }

    // -----------------------------------------------------------------------
    // Declarations

    /// The declaration of protocol type `ty` (any instance), if it is a
    /// protocol of this package. Standard protocols are not loaded (T163).
    pub fn protocolOf(p: *Protocols, ty: TypeId) Error!?*const Protocol {
        const ref = p.items.declRef(ty) orelse return null;
        const info = try p.items.info(ref);
        if (info.* != .protocol) return null;
        const node = p.items.im.graph.modules[ref.module].items[ref.item].node;
        const key = p.decl(ref.module, node).index;
        if (p.protos.getPtr(key)) |pr| return pr;
        const a = p.ast(ref.module);
        const d = a.data(node).protocol_decl;
        const gens = try p.paramTypes(ref.module, d.generics);
        const self = try p.types().intern(.{ .param = .{
            .owner = p.decl(ref.module, node),
            .index = @intCast(gens.len),
            .name = try p.types().strings.intern("Self"),
        } });
        var methods: std.ArrayList(Method) = .empty;
        for (d.members) |mn| {
            const n = unwrap(a, mn);
            if (a.kind(n) != .fn_decl) continue;
            try methods.append(p.alloc(), .{
                .f = try p.items.signature(ref.module, n, self),
                .has_default = a.data(n).fn_decl.body != null,
            });
        }
        try p.protos.put(p.alloc(), key, .{ .type = info.protocol, .self = self, .generics = gens, .methods = methods.items });
        return p.protos.getPtr(key).?;
    }

    fn paramTypes(p: *Protocols, m: ModuleId, gens: ?[]const Node.Index) Error![]const TypeId {
        const g = gens orelse return &.{};
        const out = try p.alloc().alloc(TypeId, g.len);
        for (g, out) |gn, *o| o.* = p.items.mods[m].params.get(gn).?.type;
        return out;
    }

    /// The bounds of type parameter `param`; empty for any other type. The
    /// `Self` of a protocol is bounded by the protocol itself.
    pub fn boundsOf(p: *Protocols, param: TypeId) Error!Bounds {
        if (p.bounds.get(param)) |b| return b;
        const key = switch (p.types().get(param)) {
            .param => |k| k,
            else => return .{},
        };
        const m, const n = p.locate(key.owner) orelse return .{};
        const a = p.ast(m);
        const gens = generics(a, n) orelse &.{};
        var b: Bounds = .{};
        if (key.index == gens.len) {
            if (a.kind(n) == .protocol_decl) {
                const i = p.items.mods[m].item_of.get(n) orelse return .{};
                b.protocols = try p.alloc().dupe(TypeId, &.{(try p.items.info(.{ .module = m, .item = i })).protocol});
            }
        } else {
            const g = gens[key.index];
            const list = a.data(g).generic_param.bounds;
            var out: std.ArrayList(TypeId) = .empty;
            for (list) |bn| {
                if (a.kind(bn) == .path and std.mem.eql(u8, a.tokenSlice(a.mainToken(bn)), "plain")) {
                    b.plain = true;
                    continue;
                }
                const t = try p.resolveBound(m, g, bn, list.len);
                // A non-protocol single bound makes a value parameter (§7.6.1).
                switch (p.types().get(t)) {
                    .nominal => |k| if (k.kind == .protocol) try out.append(p.alloc(), t),
                    else => {},
                }
            }
            b.protocols = out.items;
        }
        try p.bounds.put(p.alloc(), param, b);
        return b;
    }

    /// Resolves bound `bn` of generic parameter `g`. `items` already
    /// resolved (and reported on) a single bound when it computed the
    /// parameter's value type: resolve it again without reporting.
    fn resolveBound(p: *Protocols, m: ModuleId, g: Node.Index, bn: Node.Index, count: usize) Error!TypeId {
        if (count != 1 or p.items.mods[m].params.get(g).?.value_type == null) return p.items.resolveType(m, bn, .none);
        var quiet: diag.Sink = .init(p.alloc(), p.types().io);
        defer quiet.deinit();
        const saved = p.items.sink;
        p.items.sink = &quiet;
        defer p.items.sink = saved;
        return p.items.resolveType(m, bn, .none);
    }

    // -----------------------------------------------------------------------
    // Substitution and matching

    /// `ty` with the parameters of `owner` replaced: parameter `i` by
    /// `args[i]`, unless that is `.none` or out of range.
    pub fn subst(p: *Protocols, ty: TypeId, owner: Types.Decl, args: []const TypeId) Error!TypeId {
        const t = p.types();
        return switch (t.get(ty)) {
            .param => |k| if (std.meta.eql(k.owner, owner) and k.index < args.len and args[k.index] != .none) args[k.index] else ty,
            .array => |x| t.intern(.{ .array = .{ .len = x.len, .elem = try p.subst(x.elem, owner, args) } }),
            .soa_array => |x| t.intern(.{ .soa_array = .{ .len = x.len, .elem = try p.subst(x.elem, owner, args) } }),
            .slice => |x| t.intern(.{ .slice = .{ .elem = try p.subst(x.elem, owner, args) } }),
            .soa_slice => |x| t.intern(.{ .soa_slice = .{ .elem = try p.subst(x.elem, owner, args) } }),
            .vec => |x| t.intern(.{ .vec = .{ .len = x.len, .elem = try p.subst(x.elem, owner, args) } }),
            .handle => |x| t.intern(.{ .handle = .{ .elem = try p.subst(x.elem, owner, args) } }),
            .ptr => |x| t.intern(.{ .ptr = .{ .elem = try p.subst(x.elem, owner, args), .is_const = x.is_const } }),
            .mut_view => |x| t.intern(.{ .mut_view = .{ .elem = try p.subst(x.elem, owner, args) } }),
            .field_id => |x| t.intern(.{ .field_id = .{ .owner = try p.subst(x.owner, owner, args) } }),
            .tuple => |x| blk: {
                const elems = try p.alloc().alloc(TypeId, x.elems.len);
                for (x.elems, elems) |e, *o| o.* = try p.subst(e, owner, args);
                break :blk t.intern(.{ .tuple = .{ .elems = elems } });
            },
            .fn_ptr => |x| blk: {
                const params = try p.alloc().alloc(Types.FnParam, x.params.len);
                for (x.params, params) |e, *o| o.* = .{ .type = try p.subst(e.type, owner, args), .mode = e.mode };
                break :blk t.intern(.{ .fn_ptr = .{ .params = params, .ret = try p.subst(x.ret, owner, args) } });
            },
            .nominal => |x| blk: {
                if (x.args.len == 0) break :blk ty;
                const out = try p.alloc().alloc(Types.Arg, x.args.len);
                for (x.args, out) |arg, *o| o.* = if (arg == .type) .{ .type = try p.subst(arg.type, owner, args) } else arg;
                var k = x;
                k.args = out;
                break :blk t.intern(.{ .nominal = k });
            },
            .simple, .int, .mask => ty,
        };
    }

    /// Whether `ty` is an instance of `pattern`, binding the parameters of
    /// `owner` in `binds` (`.none` = unbound).
    fn match(p: *Protocols, pattern: TypeId, ty: TypeId, owner: Types.Decl, binds: []TypeId) bool {
        if (pattern == ty) return true;
        const t = p.types();
        const k = t.get(ty);
        switch (t.get(pattern)) {
            .param => |x| {
                if (!std.meta.eql(x.owner, owner) or x.index >= binds.len) return false;
                if (binds[x.index] == .none) binds[x.index] = ty;
                return binds[x.index] == ty;
            },
            .array => |x| return k == .array and x.len == k.array.len and p.match(x.elem, k.array.elem, owner, binds),
            .soa_array => |x| return k == .soa_array and x.len == k.soa_array.len and p.match(x.elem, k.soa_array.elem, owner, binds),
            .slice => |x| return k == .slice and p.match(x.elem, k.slice.elem, owner, binds),
            .soa_slice => |x| return k == .soa_slice and p.match(x.elem, k.soa_slice.elem, owner, binds),
            .vec => |x| return k == .vec and x.len == k.vec.len and p.match(x.elem, k.vec.elem, owner, binds),
            .handle => |x| return k == .handle and p.match(x.elem, k.handle.elem, owner, binds),
            .ptr => |x| return k == .ptr and x.is_const == k.ptr.is_const and p.match(x.elem, k.ptr.elem, owner, binds),
            .mut_view => |x| return k == .mut_view and p.match(x.elem, k.mut_view.elem, owner, binds),
            .tuple => |x| {
                if (k != .tuple or x.elems.len != k.tuple.elems.len) return false;
                for (x.elems, k.tuple.elems) |a, b| if (!p.match(a, b, owner, binds)) return false;
                return true;
            },
            .nominal => |x| {
                if (k != .nominal or !p.sameDecl(x, k.nominal) or x.args.len != k.nominal.args.len) return false;
                for (x.args, k.nominal.args) |a, b| {
                    if (a == .type and b == .type) {
                        if (!p.match(a.type, b.type, owner, binds)) return false;
                    } else if (!std.meta.eql(a, b)) return false;
                }
                return true;
            },
            else => return false,
        }
    }

    /// Same declaration. A standard type is named by its prelude entry or
    /// by its path (`Display`, `std.fmt.Display`): compare names there.
    // shortcut: std is not loaded (T163); exact once std declarations have one identity.
    fn sameDecl(p: *const Protocols, a: Types.Nominal, b: Types.Nominal) bool {
        if (std.meta.eql(a.decl, b.decl)) return true;
        return p.isStd(a.decl) and p.isStd(b.decl) and a.name == b.name;
    }

    // -----------------------------------------------------------------------
    // Impl lookup

    /// The impl of `protocol` (with its arguments) for `ty`, and the impl's
    /// generic arguments; null if this package has none.
    pub fn implFor(p: *Protocols, protocol: TypeId, ty: TypeId) Error!?struct { *const Impl, []const TypeId } {
        for (p.impls) |*impl| {
            if (impl.protocol == .err or impl.target == .err) continue;
            const binds = try p.alloc().alloc(TypeId, impl.generics.len);
            @memset(binds, .none);
            const owner = p.decl(impl.src.module, impl.src.node);
            if (!p.match(impl.protocol, protocol, owner, binds) or !p.match(impl.target, ty, owner, binds)) continue;
            if (!try p.argsSatisfy(impl.generics, binds)) continue;
            return .{ impl, binds };
        }
        return null;
    }

    /// Whether `ty` implements `protocol` (§7.5.2): through an impl, or as
    /// a type parameter bounded by it. `.err` satisfies everything.
    pub fn satisfies(p: *Protocols, ty: TypeId, protocol: TypeId) Error!bool {
        if (ty == .err or protocol == .err) return true;
        if (p.depth > 32) return false;
        p.depth += 1;
        defer p.depth -= 1;
        const pk = switch (p.types().get(protocol)) {
            .nominal => |k| k,
            else => return false,
        };
        switch (p.types().get(ty)) {
            .param => {
                for ((try p.boundsOf(ty)).protocols) |b| {
                    const bk = p.types().get(b);
                    if (b == protocol or (bk == .nominal and p.sameDecl(bk.nominal, pk) and argsEql(bk.nominal.args, pk.args))) return true;
                }
                return false;
            },
            .nominal => |k| if (p.isStd(pk.decl) and p.isStd(k.decl)) return true,
            else => if (p.isStd(pk.decl)) return true,
        }
        // shortcut: std is not loaded (T163): primitives and std types count as
        // implementing std protocols; package types need an impl here.
        return try p.implFor(protocol, ty) != null;
    }

    /// Whether each bound type argument satisfies the bounds of its parameter.
    fn argsSatisfy(p: *Protocols, gens: []const TypeId, args: []const TypeId) Error!bool {
        for (gens, args) |g, arg| {
            if (arg == .none) continue;
            const owner = p.types().get(g).param.owner;
            for ((try p.boundsOf(g)).protocols) |b| {
                if (!try p.satisfies(arg, try p.subst(b, owner, args))) return false;
            }
        }
        return true;
    }

    /// Checks the bounds of generic parameters `gens` (all of one
    /// declaration) against arguments `args`, for a call or an
    /// instantiation at `site`: E0373 for an unmet protocol bound, E0329 for
    /// a non-plain argument of a `plain` parameter. Value arguments are not
    /// checked. Returns whether all bounds hold.
    pub fn checkCallBounds(p: *Protocols, site: diag.Span, gens: []const TypeId, args: []const Types.Arg) Error!bool {
        const tys = try p.alloc().alloc(TypeId, gens.len);
        for (tys, 0..) |*t, i| t.* = if (i < args.len and args[i] == .type) args[i].type else .none;
        var ok = true;
        for (gens, tys) |g, ty| {
            if (ty == .none or ty == .err) continue;
            const key = p.types().get(g).param;
            const b = try p.boundsOf(g);
            for (b.protocols) |bp| {
                const want = try p.subst(bp, key.owner, tys);
                if (try p.satisfies(ty, want)) continue;
                ok = false;
                const want_s = try p.tyName(want);
                try p.report(site, .E0373, &.{try std.fmt.allocPrint(p.alloc(), "required by the bound `{s}: {s}`; add `impl {s} for {s}`", .{ p.types().strings.get(key.name), want_s, want_s, try p.tyName(ty) })}, "`{s}` does not implement `{s}`", .{ try p.tyName(ty), want_s });
            }
            if (b.plain) if (p.options.plain_hook) |h| if (!try h.isPlain(h.ctx, ty)) {
                ok = false;
                try p.report(site, .E0329, &.{}, "`{s}` is not plain, but `{s}` is bounded by `plain`", .{ try p.tyName(ty), p.types().strings.get(key.name) });
            };
        }
        return ok;
    }

    /// Method `name` of receiver type `ty` from a protocol, as seen from
    /// module `m` (§7.9): through the bounds of a type parameter, or an impl
    /// for `ty` whose protocol and type are nameable in `m` (its own method,
    /// else the protocol's default). Methods declared in a struct or enum
    /// body are `Items`'.
    // shortcut: the first impl in declaration order wins; ambiguity between two protocols is the caller's.
    pub fn findMethod(p: *Protocols, m: ModuleId, ty: TypeId, name: []const u8) Error!?MethodRef {
        if (p.types().get(ty) == .param) {
            for ((try p.boundsOf(ty)).protocols) |b| {
                const pr = try p.protocolOf(b) orelse continue;
                if (pr.method(name)) |md| return .{ .f = md.f, .protocol = b, .impl = null };
            }
            return null;
        }
        for (p.impls) |*impl| {
            if (impl.protocol == .err or !p.items.im.implVisible(m, impl.src)) continue;
            const binds = try p.alloc().alloc(TypeId, impl.generics.len);
            @memset(binds, .none);
            if (!p.match(impl.target, ty, p.decl(impl.src.module, impl.src.node), binds)) continue;
            for (impl.methods) |f| if (std.mem.eql(u8, f.name, name)) return .{ .f = f, .protocol = impl.protocol, .impl = impl, .args = binds };
            const pr = try p.protocolOf(impl.protocol) orelse continue;
            if (pr.method(name)) |md| if (md.has_default) return .{ .f = md.f, .protocol = impl.protocol, .impl = impl, .args = binds };
        }
        return null;
    }

    // -----------------------------------------------------------------------
    // E0375

    /// Reports E0375 if type `ty`, written as type expression `node` of
    /// module `m`, is or contains a protocol. Returns whether it is fine.
    pub fn checkType(p: *Protocols, m: ModuleId, node: Node.Index, ty: TypeId) Error!bool {
        const proto = p.protocolIn(ty) orelse return true;
        try p.report(p.tokSpan(m, typeToken(p.ast(m), node)), .E0375, &.{"a protocol is not a type: use a generic parameter bounded by it (`<T: P>`) or an enum (§7.5.3)"}, "protocol `{s}` used as a type", .{try p.tyName(proto)});
        return false;
    }

    /// The first protocol in `ty`, if any.
    fn protocolIn(p: *Protocols, ty: TypeId) ?TypeId {
        if (ty == .none) return null;
        return switch (p.types().get(ty)) {
            .nominal => |k| {
                if (k.kind == .protocol) return ty;
                for (k.args) |arg| if (arg == .type) if (p.protocolIn(arg.type)) |x| return x;
                return null;
            },
            inline .array, .soa_array, .slice, .soa_slice, .vec, .handle, .ptr, .mut_view => |x| p.protocolIn(x.elem),
            .tuple => |x| for (x.elems) |e| {
                if (p.protocolIn(e)) |r| break r;
            } else null,
            .fn_ptr => |x| for (x.params) |e| {
                if (p.protocolIn(e.type)) |r| break r;
            } else p.protocolIn(x.ret),
            else => null,
        };
    }

    fn checkFnTypes(p: *Protocols, m: ModuleId, f: Fn) Error!void {
        const a = p.ast(m);
        for (f.params) |param| if (a.data(param.node).param.ty) |t| {
            _ = try p.checkType(m, t, param.type);
        };
        if (a.data(f.node).fn_decl.ret) |r| _ = try p.checkType(m, r, f.ret);
    }

    fn checkConstTypes(p: *Protocols, m: ModuleId, consts: []const items_mod.Const) Error!void {
        for (consts) |c| if (p.ast(m).data(c.node).const_decl.ty) |t| {
            _ = try p.checkType(m, t, c.type);
        };
    }

    fn checkItemTypes(p: *Protocols) Error!void {
        for (p.items.im.graph.modules, 0..) |cm, mi| for (cm.items, 0..) |item, i| {
            const m: ModuleId = @intCast(mi);
            const a = p.ast(m);
            switch ((try p.items.info(.{ .module = m, .item = @intCast(i) })).*) {
                .@"fn" => |f| try p.checkFnTypes(m, f),
                .@"struct" => |s| {
                    for (s.fields) |f| _ = try p.checkType(m, a.data(f.node).field_decl.ty, f.type);
                    for (s.methods) |f| try p.checkFnTypes(m, f);
                    try p.checkConstTypes(m, s.consts);
                },
                .@"enum" => |e| {
                    for (e.variants) |v| if (a.data(v.node).variant_decl.payload) |nodes| for (nodes, v.payload) |n, t| {
                        _ = try p.checkType(m, n, t);
                    };
                    for (e.methods) |f| try p.checkFnTypes(m, f);
                    try p.checkConstTypes(m, e.consts);
                },
                .alias => |t| _ = try p.checkType(m, a.data(item.node).type_alias.ty, t),
                .distinct => |t| if (p.types().get(t) == .nominal) {
                    _ = try p.checkType(m, a.data(item.node).type_distinct.ty, p.types().get(t).nominal.underlying);
                },
                .@"const" => |c| try p.checkConstTypes(m, &.{c}),
                .protocol => |t| if (try p.protocolOf(t)) |pr| for (pr.methods) |md| try p.checkFnTypes(m, md.f),
                .pending => {},
            }
        };
    }

    // -----------------------------------------------------------------------
    // Impls (E0378, E0379)

    fn buildImpls(p: *Protocols) Error!void {
        const src = p.items.im.impls;
        p.impls = try p.alloc().alloc(Impl, src.len);
        for (src, p.impls) |s, *o| {
            const m = s.module;
            const a = p.ast(m);
            const d = a.data(s.node).impl_decl;
            const target = try p.items.resolveType(m, d.target, .none);
            var protocol = try p.items.resolveType(m, d.protocol, target);
            const is_protocol = switch (p.types().get(protocol)) {
                .nominal => |k| k.kind == .protocol,
                else => false,
            };
            if (!is_protocol and protocol != .err) {
                try p.report(p.tokSpan(m, typeToken(a, d.protocol)), null, &.{}, "`{s}` is not a protocol", .{try p.tyName(protocol)});
            }
            if (!is_protocol) protocol = .err;
            _ = try p.checkType(m, d.target, target);
            var methods: std.ArrayList(Fn) = .empty;
            for (d.members) |mn| {
                const n = unwrap(a, mn);
                if (a.kind(n) == .fn_decl) try methods.append(p.alloc(), try p.items.signature(m, n, target));
            }
            o.* = .{ .src = s, .generics = try p.paramTypes(m, d.generics), .protocol = protocol, .target = target, .methods = methods.items };
            for (o.methods) |f| try p.checkFnTypes(m, f);
        }
    }

    /// Coherence (§7.5.1, E0379): placement, then overlap with an earlier impl.
    fn checkCoherence(p: *Protocols) Error!void {
        for (p.impls, 0..) |*impl, i| {
            const m = impl.src.module;
            const a = p.ast(m);
            const d = a.data(impl.src.node).impl_decl;
            const at = p.tokSpan(m, typeToken(a, d.protocol));
            if (impl.protocol == .err or impl.target == .err) continue;
            if (!placed(impl)) {
                try p.report(at, .E0379, &.{"an `impl P for T` must be in the module that declares `P` or the one that declares `T`"}, "`impl {s} for {s}` is in neither the module of `{s}` nor the module of `{s}`", .{ try p.tyName(impl.protocol), try p.tyName(impl.target), try p.tyName(impl.protocol), try p.tyName(impl.target) });
                continue;
            }
            for (p.impls[0..i]) |*prev| {
                if (prev.protocol == .err or prev.target == .err or !placed(prev)) continue;
                if (!try p.overlap(impl, prev) and !try p.overlap(prev, impl)) continue;
                try p.report(at, .E0379, &.{"there is at most one impl of a protocol for a type"}, "duplicate `impl {s} for {s}`", .{ try p.tyName(impl.protocol), try p.tyName(impl.target) });
                break;
            }
        }
    }

    /// Whether `general`'s patterns match `specific`'s types.
    fn overlap(p: *Protocols, general: *const Impl, specific: *const Impl) Error!bool {
        const binds = try p.alloc().alloc(TypeId, general.generics.len);
        @memset(binds, .none);
        const owner = p.decl(general.src.module, general.src.node);
        return p.match(general.protocol, specific.protocol, owner, binds) and p.match(general.target, specific.target, owner, binds);
    }

    /// Signatures (§7.5.1, E0378).
    fn checkMethods(p: *Protocols, impl: *const Impl) Error!void {
        const pr = try p.protocolOf(impl.protocol) orelse return; // std protocols are not loaded (T163)
        const m = impl.src.module;
        const a = p.ast(m);
        const d = a.data(impl.src.node).impl_decl;
        // `Self` and the protocol's parameters, as this impl instantiates them.
        const pargs = p.types().get(impl.protocol).nominal.args;
        const self_args = try p.alloc().alloc(TypeId, pargs.len + 1);
        for (pargs, self_args[0..pargs.len]) |arg, *o| o.* = if (arg == .type) arg.type else .none;
        self_args[pargs.len] = impl.target;
        const powner = p.types().get(pr.self).param.owner;

        for (pr.methods) |md| {
            const want = try p.substFn(md.f, powner, self_args);
            const have = for (impl.methods) |f| {
                if (std.mem.eql(u8, f.name, md.f.name)) break f;
            } else {
                if (!md.has_default) try p.report(p.tokSpan(m, typeToken(a, d.protocol)), .E0378, &.{try std.fmt.allocPrint(p.alloc(), "add `{s}`", .{try p.fnText(want, null)})}, "`impl {s} for {s}` is missing method `{s}`", .{ try p.tyName(impl.protocol), try p.tyName(impl.target), md.f.name });
                continue;
            };
            if (try p.sameSig(want, have)) continue;
            try p.report(p.tokSpan(m, a.mainToken(have.node) + 1), .E0378, &.{try std.fmt.allocPrint(p.alloc(), "protocol `{s}` declares `{s}`", .{ try p.tyName(impl.protocol), try p.fnText(want, have) })}, "method `{s}` does not match its declaration in `{s}`", .{ have.name, try p.tyName(impl.protocol) });
        }
        for (impl.methods) |f| if (pr.method(f.name) == null) {
            try p.report(p.tokSpan(m, a.mainToken(f.node) + 1), .E0378, &.{"an impl defines only the methods its protocol declares; put other methods in the type's body"}, "`{s}` is not a method of protocol `{s}`", .{ f.name, try p.tyName(impl.protocol) });
        };
    }

    fn substFn(p: *Protocols, f: Fn, owner: Types.Decl, args: []const TypeId) Error!Fn {
        var out = f;
        const params = try p.alloc().alloc(items_mod.Param, f.params.len);
        for (f.params, params) |x, *o| {
            o.* = x;
            o.type = try p.subst(x.type, owner, args);
        }
        out.params = params;
        out.ret = try p.subst(f.ret, owner, args);
        return out;
    }

    /// Exact signature equality, the method generics of `want` renamed to
    /// those of `have`. Errors (already reported) match anything.
    fn sameSig(p: *Protocols, want_: Fn, have: Fn) Error!bool {
        if (want_.generics.len != have.generics.len or want_.params.len != have.params.len) return false;
        var want = want_;
        if (want.generics.len > 0) want = try p.substFn(want, p.types().get(want.generics[0]).param.owner, have.generics);
        if (!sameType(want.ret, have.ret)) return false;
        for (want.params, have.params) |x, y| {
            if (x.mode != y.mode or x.is_self != y.is_self or !sameType(x.type, y.type)) return false;
        }
        return true;
    }

    /// `fn name<..>(self, mut x: T) -> R`, with the generic names of
    /// `names_from` when given (so the text reads like the impl's).
    fn fnText(p: *Protocols, f_: Fn, names_from: ?Fn) Error![]const u8 {
        var f = f_;
        if (names_from) |h| if (h.generics.len == f.generics.len and f.generics.len > 0) {
            f = try p.substFn(f, p.types().get(f.generics[0]).param.owner, h.generics);
            f.generics = h.generics;
        };
        var s: std.ArrayList(u8) = .empty;
        const gpa = p.alloc();
        try s.print(gpa, "fn {s}", .{f.name});
        if (f.generics.len > 0) {
            for (f.generics, 0..) |g, i| try s.print(gpa, "{s}{s}", .{ if (i == 0) "<" else ", ", try p.tyName(g) });
            try s.append(gpa, '>');
        }
        try s.append(gpa, '(');
        for (f.params, 0..) |x, i| {
            if (i > 0) try s.appendSlice(gpa, ", ");
            if (x.mode != .value) try s.print(gpa, "{t} ", .{x.mode});
            if (x.is_self) try s.appendSlice(gpa, "self") else try s.print(gpa, "{s}: {s}", .{ x.name, try p.tyName(x.type) });
        }
        try s.append(gpa, ')');
        if (f.ret != .void) try s.print(gpa, " -> {s}", .{try p.tyName(f.ret)});
        return s.items;
    }
};

fn argsEql(a: []const Types.Arg, b: []const Types.Arg) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.meta.eql(x, y)) return false;
    return true;
}

fn sameType(a: TypeId, b: TypeId) bool {
    return a == b or a == .err or b == .err;
}

/// Whether `impl` is in the module of its protocol or of its type.
fn placed(impl: *const Impl) bool {
    return isIn(impl.src.protocol, impl.src.module) or isIn(impl.src.target, impl.src.module);
}

/// Whether `t` names an item of module `m`.
fn isIn(t: ?Target, m: ModuleId) bool {
    const x = t orelse return false;
    return x == .item and x.item.module == m;
}

/// Checks the protocols and impls of the package `items` checked, and
/// reports problems to `sink`. Errors are internal failures only. The
/// result borrows `items`.
pub fn check(gpa: Allocator, sink: *diag.Sink, items: *Items, options: Options) Error!Protocols {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(gpa);
    var p: Protocols = .{ .arena = arena, .sink = sink, .items = items, .options = options };
    errdefer p.deinit();
    try p.buildImpls();
    try p.checkItemTypes();
    try p.checkCoherence();
    for (p.impls) |*impl| if (impl.protocol != .err and impl.target != .err) try p.checkMethods(impl);
    return p;
}

// ---------------------------------------------------------------------------
// Helpers

fn unwrap(a: *const Ast, n: Node.Index) Node.Index {
    return if (a.kind(n) == .attributed) a.data(n).attributed.inner else n;
}

fn generics(a: *const Ast, n: Node.Index) ?[]const Node.Index {
    return switch (a.data(n)) {
        inline .fn_decl, .struct_decl, .enum_decl, .protocol_decl, .impl_decl, .type_alias, .type_distinct => |d| d.generics,
        else => null,
    };
}

/// The token to report a type expression at: its name, not the `<` of `G<T>`.
fn typeToken(a: *const Ast, n: Node.Index) Ast.TokenIndex {
    return a.mainToken(if (a.kind(n) == .generic_inst) a.data(n).generic_inst.base else n);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const Interner = @import("../base/Interner.zig");
const names_mod = @import("../resolve/names.zig");

/// A checked test package; build in place with `init`.
const Fixture = struct {
    p: module_graph.TestPackage,
    g: module_graph.Graph,
    im: imports.Imports,
    names: names_mod.Names,
    strings: Interner,
    types: Types,
    items: Items,
    protos: Protocols,

    fn init(f: *Fixture, mods: []const [2][]const u8, options: Options) !void {
        f.p = try .init(mods);
        f.g = try f.p.graph(.{ .kind = .exe });
        f.im = try imports.resolve(testing.allocator, &f.p.sink, &f.g, .{});
        f.names = try names_mod.resolve(testing.allocator, &f.p.sink, &f.im);
        f.strings = .init(testing.allocator, testing.io);
        f.types = try .init(testing.allocator, testing.io, &f.strings);
        const pkg: Types.Package = .{ .name = try f.strings.intern("app"), .line = .{ .major = 1 } };
        f.items = try items_mod.check(testing.allocator, &f.p.sink, &f.types, &f.im, &f.names, .{ .package = pkg });
        f.protos = try check(testing.allocator, &f.p.sink, &f.items, options);
    }

    fn deinit(f: *Fixture) void {
        f.protos.deinit();
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
        errdefer for (ds) |d| std.debug.print("got {?t} at {d}:{d}: {s}\n", .{ d.code, @backingInt(d.primarySpan().?.file), d.primarySpan().?.start, d.message });
        try testing.expectEqual(want.len, ds.len);
        for (want, ds) |w, d| {
            try testing.expectEqual(w[0], d.code);
            const s = d.primarySpan().?;
            try testing.expectEqualStrings(w[1], f.p.asts[@backingInt(s.file)].source[s.start..s.end]);
        }
    }

    /// What item `name` of the first module declares.
    fn get(f: *Fixture, name: []const u8) !*const items_mod.Info {
        return f.items.info(.{ .module = 0, .item = f.g.modules[0].names.get(name).? });
    }

    /// The type item `name` of the first module declares.
    fn ty(f: *Fixture, name: []const u8) !TypeId {
        return switch ((try f.get(name)).*) {
            .@"struct" => |s| s.type,
            .protocol => |t| t,
            else => error.TestUnexpectedResult,
        };
    }

    /// Generic type `name` of the first module applied to `args`.
    fn inst(f: *Fixture, name: []const u8, args: []const TypeId) !TypeId {
        var k = f.types.get(try f.ty(name)).nominal;
        const out = try testing.allocator.alloc(Types.Arg, args.len);
        defer testing.allocator.free(out);
        for (args, out) |a, *o| o.* = .{ .type = a };
        k.args = out;
        return f.types.intern(.{ .nominal = k });
    }

    /// The span of the first `text` in module 0.
    fn at(f: *Fixture, text: []const u8) diag.Span {
        const start: u32 = @intCast(std.mem.indexOf(u8, f.p.asts[0].source, text).?);
        return .{ .file = f.g.modules[0].file, .start = start, .end = start + @as(u32, @intCast(text.len)) };
    }
};

test "§7.5.1 Renderable: required and default methods, impl lookup" {
    var f: Fixture = undefined;
    try f.init(&.{.{
        "a",
        \\struct BBox { w: f32 }
        \\struct Canvas { pub mut n: u32 }
        \\pub protocol Renderable {
        \\    fn bounds(self) -> BBox;
        \\    fn draw(self, mut canvas: Canvas);
        \\    fn is_visible(self) -> bool { true }          // default method
        \\}
        \\struct MeshInstance { bounds: BBox }
        \\impl Renderable for MeshInstance {
        \\    fn bounds(self) -> BBox { self.bounds }
        \\    fn draw(self, mut canvas: Canvas) { }
        \\}
        \\struct Ghost { w: f32 }
        \\impl Renderable for Ghost {
        \\    fn bounds(self) -> BBox { BBox { w: self.w } }
        \\    fn draw(self, mut canvas: Canvas) { }
        \\    fn is_visible(self) -> bool { false }
        \\}
    }}, .{});
    defer f.deinit();
    try f.expectDiags(&.{});
    const renderable = try f.ty("Renderable");
    const pr = (try f.protos.protocolOf(renderable)).?;
    try testing.expectEqual(3, pr.methods.len);
    try testing.expect(!pr.method("draw").?.has_default and pr.method("is_visible").?.has_default);
    try testing.expectEqual(pr.self, pr.method("bounds").?.f.params[0].type);
    try testing.expectEqualSlices(TypeId, &.{renderable}, (try f.protos.boundsOf(pr.self)).protocols);

    const mesh = try f.ty("MeshInstance");
    const ghost = try f.ty("Ghost");
    try testing.expect(try f.protos.satisfies(mesh, renderable));
    try testing.expect(!try f.protos.satisfies(try f.ty("BBox"), renderable));
    // Inherited default, overridden default, required method.
    const inherited = (try f.protos.findMethod(0, mesh, "is_visible")).?;
    try testing.expectEqual(pr.method("is_visible").?.f.node, inherited.f.node);
    try testing.expectEqual(f.protos.impls[0].src.node, inherited.impl.?.src.node);
    const overridden = (try f.protos.findMethod(0, ghost, "is_visible")).?;
    try testing.expectEqual(f.protos.impls[1].methods[2].node, overridden.f.node);
    try testing.expectEqual(.mut, (try f.protos.findMethod(0, mesh, "draw")).?.f.params[1].mode);
    try testing.expectEqual(null, try f.protos.findMethod(0, mesh, "nope"));
}

test "E0378: missing methods, mismatched signatures, extra methods" {
    var f: Fixture = undefined;
    try f.init(&.{.{
        "a",
        \\struct Canvas { pub mut n: u32 }
        \\pub protocol Renderable {
        \\    fn bounds(self) -> u32;
        \\    fn draw(self, mut canvas: Canvas);
        \\    fn is_visible(self) -> bool { true }
        \\}
        \\struct Sprite { w: u32 }
        \\impl Renderable for Sprite { fn bounds(self) -> u32 { self.w } }
        \\struct Text { len: u32 }
        \\impl Renderable for Text {
        \\    fn bounds(self) -> u64 { 0 }
        \\    fn draw(self, canvas: Canvas) {}
        \\    fn is_visible(self, x: u8) -> bool { true }
        \\    fn extra(self) {}
        \\}
        \\protocol From<E> { fn from(e: E) -> Self; }
        \\struct W { v: u8 }
        \\impl From<u8> for W { fn from(e: u8) -> Self { W { v: e } } }
        \\struct V { v: u8 }
        \\impl From<u8> for V { fn from(e: u16) -> V { V { v: 0 } } }
        \\protocol Mapper { fn map<T>(self, x: T) -> T; }
        \\impl Mapper for W { fn map<U>(self, x: U) -> U { x } }
        \\impl Mapper for V { fn map<U>(self, x: U) -> u8 { 0 } }
    }}, .{});
    defer f.deinit();
    try f.expectDiags(&.{
        .{ .E0378, "Renderable" }, .{ .E0378, "bounds" }, .{ .E0378, "draw" },
        .{ .E0378, "is_visible" }, .{ .E0378, "extra" },  .{ .E0378, "from" },
        .{ .E0378, "map" },
    });
}

test "E0379: impl placement and overlapping impls" {
    var f: Fixture = undefined;
    try f.init(&.{
        .{
            "shapes",
            \\pub protocol Shape { fn area(self) -> f32; }
            \\pub struct L<T> { x: T }
            \\impl<T> Shape for L<T> { fn area(self) -> f32 { 0.0 } }
            \\impl Shape for L<u32> { fn area(self) -> f32 { 1.0 } }
            \\impl Shape for u32 { fn area(self) -> f32 { 1.0 } }
        },
        .{
            "geo",
            \\use shapes.Shape;
            \\pub struct Sq { pub side: f32 }
            \\impl Shape for Sq { fn area(self) -> f32 { self.side } }
            \\impl Shape for Sq { fn area(self) -> f32 { 0.0 } }
            \\impl Ord for Sq { fn cmp(self, other: Self) -> Order { .equal } }
        },
        .{
            "app",
            \\use shapes.Shape;
            \\use geo.Sq;
            \\struct Mine { v: u8 }
            \\impl Shape for Mine { fn area(self) -> f32 { 0.0 } }
            \\impl Shape for Sq { fn area(self) -> f32 { 0.0 } }
            \\impl From<u8> for Order { fn from(e: u8) -> Self { .equal } }
        },
    }, .{});
    defer f.deinit();
    try f.expectDiags(&.{ .{ .E0379, "Shape" }, .{ .E0379, "Shape" }, .{ .E0379, "Shape" }, .{ .E0379, "From" } });
    const ds = f.p.sink.finish();
    try testing.expect(std.mem.indexOf(u8, ds[0].message, "duplicate `impl Shape for L<u32>`") != null);
    try testing.expect(std.mem.indexOf(u8, ds[2].message, "neither") != null);
}

test "E0375: a protocol is not a type" {
    var f: Fixture = undefined;
    try f.init(&.{.{
        "a",
        \\pub protocol Shape { fn area(self) -> f32; fn same(self, other: Shape) -> bool; }
        \\fn describe(s: Shape) -> f32 { 0.0 }
        \\struct Scene { main: []Shape, ok: u32 }
        \\fn make() -> Option<Shape> { .none }
        \\type S = Shape;
        \\fn fine<T: Shape>(s: T, xs: []T) -> f32 { 0.0 }
        \\enum AnyShape { circle(f32), empty }
    }}, .{});
    defer f.deinit();
    try f.expectDiags(&.{ .{ .E0375, "Shape" }, .{ .E0375, "Shape" }, .{ .E0375, "[" }, .{ .E0375, "Option" }, .{ .E0375, "Shape" } });
    try testing.expect(try f.protos.checkType(0, f.p.asts[0].data(.from(0)).root.items[0], .f32));
}

test "E0373: unmet bounds at the call site" {
    var f: Fixture = undefined;
    try f.init(&.{.{
        "a",
        \\pub protocol Shape { fn area(self) -> f32; }
        \\pub protocol Named { fn id(self) -> u32; }
        \\struct Square { side: f32 }
        \\impl Shape for Square { fn area(self) -> f32 { self.side } }
        \\impl Named for Square { fn id(self) -> u32 { 4 } }
        \\struct Label { width: f32 }
        \\impl Shape for Label { fn area(self) -> f32 { 0.0 } }
        \\struct Pair<T> { a: T }
        \\impl<T: Shape> Shape for Pair<T> { fn area(self) -> f32 { 0.0 } }
        \\struct Point { x: i32 }
        \\impl Ord for Point { fn cmp(self, other: Self) -> Order { .equal } }
        \\struct W { v: u8 }
        \\impl From<u8> for W { fn from(e: u8) -> Self { W { v: e } } }
        \\fn tagged<T: Shape + Named>(x: T) -> u32 { x.id() }
        \\fn conv<T: From<E>, E>(e: E) -> T { T.from(e) }
        \\fn largest<T: Ord>(a: T) -> T { a }
        \\fn use_it(labels: []Label) -> u32 { tagged(labels[0]) + conv(1u16) }
    }}, .{});
    defer f.deinit();
    const square = try f.ty("Square");
    const label = try f.ty("Label");
    const shape = try f.ty("Shape");
    const named = try f.ty("Named");
    const tagged = (try f.get("tagged")).@"fn";
    const conv = (try f.get("conv")).@"fn";
    const largest = (try f.get("largest")).@"fn";
    const site = f.at("tagged(labels");
    const u8_: TypeId = .int(.unsigned, 8);
    const u16_: TypeId = .int(.unsigned, 16);

    try testing.expect(try f.protos.checkCallBounds(site, tagged.generics, &.{.{ .type = square }}));
    try testing.expect(!try f.protos.checkCallBounds(site, tagged.generics, &.{.{ .type = label }}));
    try testing.expect(try f.protos.checkCallBounds(site, conv.generics, &.{ .{ .type = try f.ty("W") }, .{ .type = u8_ } }));
    try testing.expect(!try f.protos.checkCallBounds(f.at("conv(1u16)"), conv.generics, &.{ .{ .type = try f.ty("W") }, .{ .type = u16_ } }));
    try testing.expect(try f.protos.checkCallBounds(site, largest.generics, &.{.{ .type = try f.ty("Point") }}));
    try testing.expect(try f.protos.checkCallBounds(site, largest.generics, &.{.{ .type = .int(.unsigned, 32) }}));
    try testing.expect(!try f.protos.checkCallBounds(site, largest.generics, &.{.{ .type = label }}));
    try f.expectDiags(&.{ .{ .E0373, "tagged(labels" }, .{ .E0373, "tagged(labels" }, .{ .E0373, "conv(1u16)" } });

    // Generic impls: `Pair<T>: Shape` needs `T: Shape`.
    try testing.expect(try f.protos.satisfies(try f.inst("Pair", &.{square}), shape));
    try testing.expect(try f.protos.satisfies(try f.inst("Pair", &.{try f.inst("Pair", &.{label})}), shape));
    try testing.expect(!try f.protos.satisfies(try f.inst("Pair", &.{u8_}), shape));
    try testing.expect(!try f.protos.satisfies(try f.inst("Pair", &.{square}), named));
    // A bounded parameter satisfies its bounds and has their methods.
    const t = tagged.generics[0];
    try testing.expect(try f.protos.satisfies(t, named));
    try testing.expect(!try f.protos.satisfies(conv.generics[1], shape));
    const id = (try f.protos.findMethod(0, t, "id")).?;
    try testing.expectEqual(named, id.protocol);
    try testing.expectEqual(null, id.impl);
}

fn notStr(_: ?*anyopaque, ty: TypeId) Error!bool {
    return ty != .str;
}

test "E0329: the plain bound through the hook" {
    var f: Fixture = undefined;
    try f.init(&.{.{
        "a",
        \\fn copy_all<T: plain>(xs: []T) {}
        \\fn both<T: plain + Ord>(x: T) {}
    }}, .{ .plain_hook = .{ .isPlain = notStr } });
    defer f.deinit();
    const copy = (try f.get("copy_all")).@"fn";
    try testing.expect((try f.protos.boundsOf(copy.generics[0])).plain);
    try testing.expectEqual(1, (try f.protos.boundsOf((try f.get("both")).@"fn".generics[0])).protocols.len);
    const site = f.at("copy_all");
    try testing.expect(try f.protos.checkCallBounds(site, copy.generics, &.{.{ .type = .int(.unsigned, 32) }}));
    try testing.expect(!try f.protos.checkCallBounds(site, copy.generics, &.{.{ .type = .str }}));
    try f.expectDiags(&.{.{ .E0329, "copy_all" }});
}
