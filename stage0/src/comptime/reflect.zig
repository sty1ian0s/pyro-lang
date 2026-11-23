//! Reflection builtins (§8.4, §8.7) and the compiler's `std.meta` types
//! (§14.8).
//!
//! `@size_of(T)`, `@align_of(T)`, `@type_info(T)`, `@type_name(T)`,
//! `@has_field(T, name)`, `@has_method(T, name)`, `@implements(T, P)`,
//! `@field_type(T, name)` and `@variant_count(E)` are comptime-only (§8.7).
//! The checker types a call (`check`) and the interpreter computes its
//! value (`eval`, from `comptime_flow.evalBuiltin`). In runtime code the
//! whole call is a comptime context: it is evaluated once and embedded as
//! a constant (`comptime_ctx.expr`), so a `TypeInfo`, which holds types,
//! is E0802 there.
//!
//! Sizes, alignments, offsets and bit fields come from the layout engine
//! (`sema/layout.zig`), never recomputed here.
//!
//! The `TypeInfo` family and the target enums are ordinary Pyro
//! declarations (`source`), checked as module `std.meta` of every package
//! (`Meta`), so values, patterns and member access on them need nothing
//! special. `std/meta.pr` holds the same text; a test keeps them equal.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("../ast/Ast.zig");
const diag = @import("../diag/diag.zig");
const Types = @import("../sema/types.zig");
const items_mod = @import("../sema/items.zig");
const emit_tir = @import("../sema/emit_tir.zig");
const builtins = @import("../sema/builtins.zig");
const comptime_ctx = @import("../sema/comptime_ctx.zig");
const layout = @import("../sema/layout.zig");
const layout_soa = @import("../sema/layout_soa.zig");
const kinds = @import("../sema/kinds.zig");
const generics = @import("../sema/generics.zig");
const module_graph = @import("../resolve/module_graph.zig");
const imports = @import("../resolve/imports.zig");
const lexer = @import("../lex/lexer.zig");
const Parser = @import("../parse/Parser.zig");
const Compilation = @import("../driver/Compilation.zig");
const interp_ctrl = @import("interp_ctrl.zig");
const embed = @import("embed.zig");
const typefn = @import("typefn.zig");
const Value = @import("value.zig").Value;

const Node = Ast.Node;
const TypeId = Types.TypeId;
const Items = items_mod.Items;
const Typed = emit_tir.Typed;
const Error = emit_tir.Error;
const Machine = interp_ctrl.Machine;
const StepError = interp_ctrl.StepError;

/// The module path of the compiler's `std.meta` declarations.
pub const module_path = "std.meta";

/// The declarations of `std/meta.pr` between its `// compiler:` markers.
pub const source =
    \\/// What `@type_info(T)` returns (§8.4): one case per type class. A distinct
    \\/// type reports the type it wraps.
    \\pub enum TypeInfo {
    \\    int(IntInfo),
    \\    float(FloatInfo),
    \\    bool_,
    \\    void_,
    \\    noreturn_,
    \\    type_,
    \\    vector(VectorInfo),
    \\    array(ArrayInfo),
    \\    slice(SliceInfo),
    \\    pointer(PointerInfo),
    \\    struct_(StructInfo),
    \\    enum_(EnumInfo),
    \\    tuple(TupleInfo),
    \\    function(FnInfo),
    \\    handle(type),
    \\}
    \\
    \\/// `uN`, `iN`, `usize` and `isize`: `bits` is the target width for the last two.
    \\pub struct IntInfo { pub signed: bool, pub bits: u8 }
    \\
    \\/// `f32` and `f64`.
    \\pub struct FloatInfo { pub bits: u8 }
    \\
    \\/// `vec<len, child>`.
    \\pub struct VectorInfo { pub len: usize, pub child: type }
    \\
    \\/// `[len]child`, and `soa [len]child` with `soa` set.
    \\pub struct ArrayInfo { pub len: usize, pub child: type, pub r#soa: bool }
    \\
    \\/// `[]child`, and `soa []child` with `soa` set.
    \\pub struct SliceInfo { pub child: type, pub r#soa: bool }
    \\
    \\/// `*child` and `*const child`.
    \\pub struct PointerInfo { pub child: type, pub is_const: bool }
    \\
    \\/// A struct: its fields in declaration order and its layout (§4.11). A
    \\/// comptime-only struct has no layout: `size`, `align` and the field
    \\/// offsets are 0.
    \\pub struct StructInfo {
    \\    pub fields: []FieldInfo,
    \\    pub is_soa: bool,
    \\    pub is_resource: bool,
    \\    pub size: usize,
    \\    pub align: usize,
    \\}
    \\
    \\/// One struct field. `offset` is the byte offset of the field, or of the
    \\/// unit holding it for a bit field (§4.11.2), whose first bit in the unit
    \\/// is `bit_offset`; `bit_width` is 0 for a field that is not a bit field.
    \\pub struct FieldInfo {
    \\    pub name: str,
    \\    pub ty: type,
    \\    pub offset: usize,
    \\    pub bit_offset: u8,
    \\    pub bit_width: u8,
    \\    pub is_pub: bool,
    \\    pub is_pub_mut: bool,
    \\    pub has_default: bool,
    \\}
    \\
    \\/// An enum: its variants in declaration order and its discriminant type
    \\/// (§4.11.4).
    \\pub struct EnumInfo { pub variants: []VariantInfo, pub backing: type }
    \\
    \\/// One enum variant: `payload` is empty without parentheses, and
    \\/// `discriminant` holds the bits of its discriminant (two's complement for
    \\/// a signed backing type).
    \\pub struct VariantInfo { pub name: str, pub payload: []type, pub discriminant: u64 }
    \\
    \\/// A tuple: its element types.
    \\pub struct TupleInfo { pub fields: []type }
    \\
    \\/// A function (`@fn_info`) or function-pointer type: its parameters, return
    \\/// type and attribute names (without `@`). Function-pointer parameters
    \\/// have empty names, and their attributes are empty.
    \\pub struct FnInfo { pub params: []ParamInfo, pub ret: type, pub attrs: []str }
    \\
    \\/// One parameter of a `FnInfo`.
    \\pub struct ParamInfo { pub name: str, pub mode: ParamMode, pub ty: type, pub attrs: []str }
    \\
    \\/// How a parameter is passed (§7.2.1).
    \\pub enum ParamMode { value, r#mut, r#move, r#comptime }
    \\
    \\/// Instruction-set architectures the implementation supports (§13.2.1).
    \\pub enum Arch { x86_64, aarch64, riscv64, wasm32 }
    \\
    \\/// Operating systems the implementation supports (§13.2.1).
    \\pub enum Os { linux, windows, macos, ios, android, wasi, freestanding }
    \\
    \\/// C ABI flavours; `none` when the target names none (§13.2.1).
    \\pub enum Abi { none, gnu, musl, msvc }
    \\
    \\/// Byte order.
    \\pub enum Endian { big, little }
    \\
    \\/// The target being compiled for (`@target()`, §8.6). `has_feature` is
    \\/// added with the rest of `std.meta` (T115).
    \\pub struct Target { pub arch: Arch, pub os: Os, pub abi: Abi, pub pointer_bits: u8, pub endian: Endian }
    \\
    \\/// CPU features the implementation knows, for `Target.has_feature`.
    \\pub enum CpuFeature {
    \\    sse2, sse3, ssse3, sse4_1, sse4_2, popcnt, avx, avx2, fma, bmi, bmi2, avx512f, avx512bw,
    \\    neon, fullfp16, dotprod, sve, sve2,
    \\    m, a, f, d, c, v,
    \\    simd128, bulk_memory,
    \\}
    \\
;

// ---------------------------------------------------------------------------
// The `std.meta` module

/// The parsed `source`, added to every package as module `std.meta`.
// shortcut: std is not loaded (T163), so each package checks its own copy of
// these declarations and its `TypeInfo` is a type of that package; load the
// real `std.meta` instead once packages are compiled together.
pub const Meta = struct {
    ast: Ast,
    file: diag.FileId,

    /// Registers and parses `source` in `comp`.
    pub fn init(comp: *Compilation) !Meta {
        var local: diag.Sink = .init(comp.gpa, comp.io);
        defer local.deinit();
        const file = try comp.sources.addBytes("std/meta.pr", source, &local);
        const tokens = try lexer.tokenize(comp.gpa, source, file, &local, .{});
        const ast = try Parser.parse(comp.gpa, source, tokens, file, &local);
        std.debug.assert(local.finish().len == 0);
        return .{ .ast = ast, .file = file };
    }

    pub fn deinit(meta: *Meta, gpa: Allocator) void {
        meta.ast.deinit(gpa);
    }

    /// The module graph input of the module.
    pub fn input(meta: *const Meta) module_graph.Input {
        return .{ .module = .{ .path = module_path, .file = "src/std/meta.pr" }, .file = meta.file, .ast = &meta.ast };
    }
};

/// The item that path `std.meta.Name` names, if the package has the module.
pub fn metaRef(it: *const Items, path: []const u8) ?imports.Ref {
    const prefix = module_path ++ ".";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const m = it.im.graph.lookup(module_path) orelse return null;
    const i = it.im.graph.modules[m].names.get(path[prefix.len..]) orelse return null;
    return .{ .module = m, .item = i };
}

/// The `std.meta` type `name` (a struct or enum of `source`), or null if
/// the package has no `std.meta` module.
pub fn metaType(it: *Items, name: []const u8) Error!?TypeId {
    const m = it.im.graph.lookup(module_path) orelse return null;
    // A `TypeInfo` value reaches its payload types, whose fields user code
    // reads before items check the module in order: check all of it now.
    for (0..it.im.graph.modules[m].items.len) |i| _ = try it.info(.{ .module = m, .item = @intCast(i) });
    const i = it.im.graph.modules[m].names.get(name).?;
    return switch ((try it.info(.{ .module = m, .item = i })).*) {
        .@"struct" => |s| s.type,
        .@"enum" => |e| e.type,
        else => unreachable,
    };
}

// ---------------------------------------------------------------------------
// Checking

/// Types reflection builtin call `a` (`Rule.reflect`); its arity and
/// context are checked.
pub fn check(a: *builtins.Args, expected: TypeId) Error!Typed {
    const c = a.c;
    // Runtime code: the whole call is a comptime context (§8.1).
    if (!c.in_comptime and c.sig.ret != .type) return comptime_ctx.expr(c, a.at, expected);
    const t = try typeOperand(a, 0);
    const ty: TypeId = switch (a.b) {
        .size_of, .align_of, .variant_count => .usize,
        .type_name => .str,
        .has_field, .has_method => blk: {
            _ = try a.as(1, .str);
            break :blk .bool;
        },
        .implements => blk: {
            _ = try typeOperand(a, 1);
            break :blk .bool;
        },
        .field_type => blk: {
            // A field name: a comptime `str` or a `FieldId<T>` (§8.4.2).
            const fid = if (t == .none or t == .err) .none else try c.types.intern(.{ .field_id = .{ .owner = t } });
            const f = try a.value(1, fid);
            const is_fid = f.ty == fid or (fid == .none and c.types.get(f.ty) == .field_id);
            if (f.ty != .str and !is_fid) return a.wrong(1, "a field name (`str` or `FieldId<T>`)", f.ty);
            break :blk .type;
        },
        .type_info => try metaType(c.items, "TypeInfo") orelse return c.unsupported(a.at, "`@type_info` without the `std.meta` module (T163)"),
        else => unreachable,
    };
    return a.finish(ty);
}

/// Type argument `i` of `a`: a type expression, resolved now, or in
/// comptime code a value of type `type` (`info.child`, a local), known only
/// when the call runs (`.none`).
fn typeOperand(a: *builtins.Args, i: usize) Error!TypeId {
    const c = a.c;
    const n = a.nodes[i];
    const value = switch (c.ast.kind(n)) {
        .index => true,
        .field_access => c.items.names.get(c.m, n) == null,
        .ident => if (c.items.names.get(c.m, n)) |e| e.res == .local and c.ast.kind(e.res.local) == .pat_bind and
            !c.items.mods[c.m].bound.contains(e.res.local) else false,
        else => false,
    };
    if (!value) return a.typeArg(i);
    _ = try a.as(i, .type);
    return .none;
}

// ---------------------------------------------------------------------------
// Evaluation

/// Whether `eval` computes builtin `b`.
pub fn evaluates(b: builtins.Builtin) bool {
    return switch (b) {
        .size_of, .align_of, .type_info, .type_name, .has_field, .has_method, .implements, .field_type, .variant_count => true,
        else => false,
    };
}

/// The value of reflection builtin `b` (`evaluates(b)`) applied to `args`,
/// reached by the interpreter `m`.
pub fn eval(m: *Machine, b: builtins.Builtin, args: []const Value) StepError!Value {
    var r: Reflect = .{ .m = m, .it = m.in.items, .e = .init(m.in.arena, m.in.items) };
    const t = args[0].data.type;
    switch (b) {
        .size_of, .align_of => {
            const l = try r.layoutOf(t, b);
            return usize_(if (b == .size_of) l.size else l.@"align");
        },
        .type_name => return str(try r.it.types.allocPrint(m.in.arena, t, .{})),
        .variant_count => return usize_((try r.variants(t, b)).len),
        .has_field => return .boolean(r.fieldIndex(t, args[1].data.str) != null),
        .has_method => return .boolean(try r.hasMethod(t, args[1].data.str)),
        .implements => {
            const p = args[1].data.type;
            const k = r.it.types.get(p);
            if (k != .nominal or k.nominal.kind != .protocol) return r.report("`@implements` expects a protocol, found `{s}`", .{try r.name(p)});
            // shortcut: item-level comptime code (const initializers) runs while items are checked, before protocols exist, so `@implements` is unsupported there; the stage driver must check protocols first (T093).
            const protos = m.bodies.protos orelse return m.fail("`@implements` in item-level comptime code (T093)");
            return .boolean(try protos.satisfies(t, p));
        },
        .field_type => {
            const s = try r.structOf(t, b);
            const i = switch (args[1].data) {
                .field_id => |i| i,
                else => r.fieldIndex(t, args[1].data.str) orelse return r.report("no field `{s}` on type `{s}`", .{ args[1].data.str, try r.name(t) }),
            };
            return r.typeValue(try r.fieldType(t, s, i));
        },
        .type_info => return r.typeInfo(t),
        else => unreachable,
    }
}

/// The state of one reflection call.
const Reflect = struct {
    m: *Machine,
    it: *Items,
    e: layout.Engine,

    fn arena(r: *Reflect) Allocator {
        return r.m.in.arena;
    }

    fn name(r: *Reflect, t: TypeId) Allocator.Error![]const u8 {
        return r.it.types.allocPrint(r.arena(), t, .{});
    }

    /// Reports an error at the call with the comptime stack trace.
    fn report(r: *Reflect, comptime fmt: []const u8, args: anytype) StepError {
        const m = r.m;
        const tr = try m.trace();
        defer tr.deinit(m.gpa);
        if (m.eval) |ev| ev.reported = true;
        try m.sink.emit(.{
            .code = null,
            .severity = .@"error",
            .message = try std.fmt.allocPrint(r.arena(), fmt, args),
            .spans = &.{.{ .span = tr.span, .primary = true }},
            .trace = tr.frames,
        });
        return m.fail("reflection error");
    }

    /// Stops at a type `b` cannot reflect on: a generic parameter (its
    /// instances are not checked one by one yet), a type of a package not
    /// loaded, or one with no `what`.
    fn cannot(r: *Reflect, t: TypeId, b: builtins.Builtin, what: []const u8) StepError {
        if (generics.mentionsParam(r.it.types, t)) return r.m.fail("reflection on generic parameters (T070)");
        const k = r.it.types.get(t);
        if (k == .nominal and k.nominal.kind != .protocol and r.it.declRef(t) == null and typefn.get(r.it, t) == null)
            return r.m.fail("reflection on standard library types (T163)");
        return r.report("`@{t}`: `{s}` has no {s}", .{ b, try r.name(t), what });
    }

    fn layoutOf(r: *Reflect, t: TypeId, b: builtins.Builtin) StepError!layout.Layout {
        if (try r.e.layoutOf(t)) |l| return l;
        if (try r.broken(t)) return r.reported();
        return r.cannot(t, b, if (try embed.isComptimeOnly(r.it, t)) "layout: it is comptime-only" else "layout");
    }

    /// Stops without a diagnostic: one was already reported.
    fn reported(r: *Reflect) StepError {
        if (r.m.eval) |ev| ev.reported = true;
        return r.m.fail("reflection error");
    }

    /// Whether `t` has no layout because of an error already reported: it
    /// holds, by value, an unknown type (`.err`) or itself (E0376).
    fn broken(r: *Reflect, t: TypeId) Allocator.Error!bool {
        var path: std.ArrayList(TypeId) = .empty;
        return r.brokenIn(t, &path);
    }

    fn brokenIn(r: *Reflect, t: TypeId, path: *std.ArrayList(TypeId)) Allocator.Error!bool {
        if (t == .err or std.mem.indexOfScalar(TypeId, path.items, t) != null) return true;
        try path.append(r.arena(), t);
        defer _ = path.pop();
        switch (r.it.types.get(t)) {
            inline .vec, .array, .soa_array => |x| return r.brokenIn(x.elem, path),
            .tuple => |x| for (x.elems) |e| {
                if (try r.brokenIn(e, path)) return true;
            },
            .nominal => |n| {
                if (n.kind == .distinct) return r.brokenIn(n.underlying, path);
                for (n.args) |a| if (a == .type and try r.brokenIn(a.type, path)) return true;
                if (typefn.structOf(r.it, t)) |s| for (s.fields, 0..) |_, i| {
                    if (try r.brokenIn(try r.fieldType(t, s, @intCast(i)), path)) return true;
                } else if (r.it.enumOf(t)) |e| for (e.variants) |v| for (v.payload) |p| {
                    if (try r.brokenIn(try r.it.subst(p, n.decl, n.args), path)) return true;
                };
            },
            else => {},
        }
        return false;
    }

    /// The declaration behind struct `t`.
    fn structOf(r: *Reflect, t: TypeId, b: builtins.Builtin) StepError!*const items_mod.Struct {
        return typefn.structOf(r.it, t) orelse r.cannot(t, b, "fields: it is not a struct");
    }

    fn fieldIndex(r: *Reflect, t: TypeId, field: []const u8) ?u32 {
        const s = typefn.structOf(r.it, t) orelse return null;
        for (s.fields, 0..) |f, i| if (std.mem.eql(u8, f.name, field)) return @intCast(i);
        return null;
    }

    /// The type of field `i` of struct `t`, its arguments substituted.
    fn fieldType(r: *Reflect, t: TypeId, s: *const items_mod.Struct, i: u32) Allocator.Error!TypeId {
        const n = r.it.types.get(t).nominal;
        return r.it.subst(s.fields[i].type, n.decl, n.args);
    }

    fn hasMethod(r: *Reflect, t: TypeId, method: []const u8) StepError!bool {
        const own: []const items_mod.Fn = if (typefn.structOf(r.it, t)) |s| s.methods else if (r.it.enumOf(t)) |e| e.methods else &.{};
        for (own) |f| if (std.mem.eql(u8, f.name, method)) return true;
        // shortcut: item-level comptime code (const initializers) runs while items are checked, before protocols exist, so `@has_method` cannot see impl methods there; the stage driver must check protocols first (T093).
        const protos = r.m.bodies.protos orelse return r.m.fail("`@has_method` through impls in item-level comptime code (T093)");
        const frames = r.m.frames.items;
        const module = r.m.bodies.fns.items[frames[frames.len - 1].id.int()].module;
        return try protos.findMethod(module, t, method) != null;
    }

    /// The variants of enum `t`: name, payload types and discriminant.
    fn variants(r: *Reflect, t: TypeId, b: builtins.Builtin) StepError![]const Variant {
        const n = switch (r.it.types.get(t)) {
            .nominal => |n| n,
            else => return r.cannot(t, b, "variants: it is not an enum"),
        };
        const a = r.arena();
        switch (n.lang) {
            .option, .result => {
                const names: [2][]const u8 = if (n.lang == .option) .{ "some", "none" } else .{ "ok", "err" };
                const out = try a.alloc(Variant, 2);
                for (out, names, 0..) |*v, nm, i| v.* = .{
                    .name = nm,
                    .payload = if (n.lang == .option and i == 1) &.{} else try a.dupe(TypeId, &.{n.args[i].type}),
                    .discriminant = i,
                };
                return out;
            },
            else => {},
        }
        const en = r.it.enumOf(t) orelse return r.cannot(t, b, "variants: it is not an enum");
        const out = try a.alloc(Variant, en.variants.len);
        for (en.variants, out) |v, *o| {
            const tys = try a.alloc(TypeId, v.payload.len);
            for (v.payload, tys) |p, *pt| pt.* = try r.it.subst(p, n.decl, n.args);
            o.* = .{ .name = v.name, .payload = tys, .discriminant = v.discriminant.bits };
        }
        return out;
    }

    // -- Values -----------------------------------------------------------

    fn meta(r: *Reflect, comptime type_name: []const u8) StepError!TypeId {
        return try metaType(r.it, type_name) orelse r.m.fail("`@type_info` without the `std.meta` module (T163)");
    }

    /// A value of `std.meta` struct `type_name`; `fields` in declaration order.
    fn record(r: *Reflect, comptime type_name: []const u8, fields: []const Value) StepError!Value {
        return .{ .ty = try r.meta(type_name), .data = .{ .aggregate = try r.arena().dupe(Value, fields) } };
    }

    /// A slice of `std.meta` values of type `elem`.
    fn slice(r: *Reflect, elem: TypeId, vs: []const Value) Allocator.Error!Value {
        return .{ .ty = try r.it.types.intern(.{ .slice = .{ .elem = elem } }), .data = .{ .slice = vs } };
    }

    /// A `[]type` of `tys`.
    fn types(r: *Reflect, tys: []const TypeId) Allocator.Error!Value {
        const vs = try r.arena().alloc(Value, tys.len);
        for (tys, vs) |t, *v| v.* = try r.typeValue(t);
        return r.slice(.type, vs);
    }

    /// Type `t` as a value. A type reached inside another one is not the
    /// result of the instance that made it (§8.3.2).
    fn typeValue(r: *Reflect, t: TypeId) Allocator.Error!Value {
        typefn.reached(r.it, t);
        return .{ .ty = .type, .data = .{ .type = t } };
    }

    /// Case `case_name` of `TypeInfo` with `payload`.
    fn case(r: *Reflect, comptime case_name: []const u8, payload: ?Value) StepError!Value {
        const ti = try r.meta("TypeInfo");
        const en = r.it.enumOf(ti).?;
        const index = for (en.variants, 0..) |v, i| {
            if (std.mem.eql(u8, v.name, case_name)) break i;
        } else unreachable;
        const p: []const Value = if (payload) |v| try r.arena().dupe(Value, &.{v}) else &.{};
        return .{ .ty = ti, .data = .{ .variant = .{ .index = @intCast(index), .payload = p } } };
    }

    fn typeInfo(r: *Reflect, t: TypeId) StepError!Value {
        const it = r.it;
        switch (it.types.get(t)) {
            .simple => |s| return switch (s) {
                .bool => r.case("bool_", null),
                .void => r.case("void_", null),
                .noreturn => r.case("noreturn_", null),
                .type => r.case("type_", null),
                .isize, .usize => r.case("int", try r.record("IntInfo", &.{ .boolean(s == .isize), u8_(it.options.ptr_bits) })),
                .f32, .f64 => r.case("float", try r.record("FloatInfo", &.{u8_(if (s == .f32) 32 else 64)})),
                else => r.cannot(t, .type_info, "`TypeInfo` case"), // `str`, untyped constants, `FnRef`
            },
            .int => |i| return r.case("int", try r.record("IntInfo", &.{ .boolean(i.signedness == .signed), u8_(i.bits) })),
            .vec => |v| return r.case("vector", try r.record("VectorInfo", &.{ usize_(v.len), try r.typeValue(v.elem) })),
            inline .array, .soa_array => |x, tag| return r.case("array", try r.record("ArrayInfo", &.{ usize_(x.len), try r.typeValue(x.elem), .boolean(tag == .soa_array) })),
            inline .slice, .soa_slice => |x, tag| return r.case("slice", try r.record("SliceInfo", &.{ try r.typeValue(x.elem), .boolean(tag == .soa_slice) })),
            .ptr => |p| return r.case("pointer", try r.record("PointerInfo", &.{ try r.typeValue(p.elem), .boolean(p.is_const) })),
            .tuple => |x| return r.case("tuple", try r.record("TupleInfo", &.{try r.types(x.elems)})),
            .handle => |h| return r.case("handle", try r.typeValue(h.elem)),
            .fn_ptr => |f| {
                const params = try r.arena().alloc(Value, f.params.len);
                for (f.params, params) |p, *o| o.* = try r.record("ParamInfo", &.{
                    str(""),
                    .{ .ty = try r.meta("ParamMode"), .data = .{ .scalar = @backingInt(p.mode) } },
                    try r.typeValue(p.type),
                    try r.slice(.str, &.{}),
                });
                return r.case("function", try r.record("FnInfo", &.{ try r.slice(try r.meta("ParamInfo"), params), try r.typeValue(f.ret), try r.slice(.str, &.{}) }));
            },
            .nominal => |n| switch (n.kind) {
                .distinct => return r.typeInfo(n.underlying),
                .@"struct" => return r.case("struct_", try r.structInfo(t)),
                .@"enum" => {
                    const vs = try r.variants(t, .type_info);
                    const out = try r.arena().alloc(Value, vs.len);
                    for (vs, out) |v, *o| o.* = try r.record("VariantInfo", &.{ str(v.name), try r.types(v.payload), .{ .ty = .int(.unsigned, 64), .data = .{ .scalar = v.discriminant } } });
                    const backing = if (n.lang != .none) TypeId.int(.unsigned, 8) else it.enumOf(t).?.backing;
                    return r.case("enum_", try r.record("EnumInfo", &.{ try r.slice(try r.meta("VariantInfo"), out), try r.typeValue(backing) }));
                },
                .protocol => return r.cannot(t, .type_info, "`TypeInfo` case: it is a protocol"),
            },
            // `mask<N>`, `mut T` views and `FieldId<T>` have no case (§8.4).
            .mask, .mut_view, .field_id, .param => return r.cannot(t, .type_info, "`TypeInfo` case"),
        }
    }

    fn structInfo(r: *Reflect, t: TypeId) StepError!Value {
        const s = try r.structOf(t, .type_info);
        const l = try r.e.layoutOf(t);
        if (l == null and !try embed.isComptimeOnly(r.it, t)) return if (try r.broken(t)) r.reported() else r.cannot(t, .type_info, "layout");
        const fields = try r.arena().alloc(Value, s.fields.len);
        for (s.fields, fields, 0..) |f, *o, i| {
            const p: layout.Place = if (l) |x| x.fields[i] else .{ .offset = 0 };
            o.* = try r.record("FieldInfo", &.{
                str(f.name),
                try r.typeValue(try r.fieldType(t, s, @intCast(i))),
                usize_(p.offset),
                u8_(p.bit_offset),
                u8_(p.width),
                .boolean(f.vis != .private),
                .boolean(f.vis == .pub_mut),
                .boolean(f.default != null),
            });
        }
        return r.record("StructInfo", &.{
            try r.slice(try r.meta("FieldInfo"), fields),
            .boolean(layout_soa.isSoa(&r.e, t)),
            .boolean(try kinds.kind(r.it, t) == .resource),
            usize_(if (l) |x| x.size else 0),
            usize_(if (l) |x| x.@"align" else 0),
        });
    }
};

/// One enum variant as reflection reports it.
const Variant = struct { name: []const u8, payload: []const TypeId, discriminant: u64 };

fn usize_(x: u64) Value {
    return .{ .ty = .usize, .data = .{ .scalar = x } };
}

fn u8_(x: u8) Value {
    return .{ .ty = .int(.unsigned, 8), .data = .{ .scalar = x } };
}

fn str(s: []const u8) Value {
    return .{ .ty = .str, .data = .{ .str = s } };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const Interner = @import("../base/Interner.zig");
const names_mod = @import("../resolve/names.zig");
const protocols_mod = @import("../sema/protocols.zig");
const target = @import("../target.zig");

/// A package of module `a` and the `std.meta` module, checked up to
/// function bodies with comptime evaluation.
const Fixture = struct {
    p: module_graph.TestPackage,
    g: module_graph.Graph,
    im: imports.Imports,
    names: names_mod.Names,
    strings: Interner,
    types: Types,
    cx: comptime_ctx.Ctx,
    items: Items,
    protos: protocols_mod.Protocols,
    bodies: emit_tir.Bodies,

    fn init(f: *Fixture, src: []const u8) !void {
        f.p = try .init(&.{ .{ "a", src }, .{ module_path, source } });
        f.g = try f.p.graph(.{ .kind = .exe });
        f.im = try imports.resolve(testing.allocator, &f.p.sink, &f.g, .{});
        f.names = try names_mod.resolve(testing.allocator, &f.p.sink, &f.im);
        f.strings = .init(testing.allocator, testing.io);
        f.types = try .init(testing.allocator, testing.io, &f.strings);
        f.cx = .init(testing.allocator);
        const pkg: Types.Package = .{ .name = try f.strings.intern("app"), .line = .{ .major = 1 } };
        f.items = try items_mod.check(testing.allocator, &f.p.sink, &f.types, &f.im, &f.names, .{ .package = pkg, .comptime_hook = f.cx.hook() });
        f.protos = try protocols_mod.check(testing.allocator, &f.p.sink, &f.items, .{});
        f.bodies = try emit_tir.checkBodies(testing.allocator, &f.items, &f.protos);
    }

    fn deinit(f: *Fixture) void {
        f.bodies.deinit();
        f.protos.deinit();
        f.items.deinit();
        f.cx.deinit();
        f.types.deinit();
        f.strings.deinit();
        f.names.deinit();
        f.im.deinit();
        f.g.deinit();
        f.p.deinit();
    }

    /// The diagnostics: code and message start.
    fn expectDiags(f: *Fixture, want: []const struct { ?diag.DiagCode, []const u8 }) !void {
        if (f.bodies.unsupported) |u| std.debug.print("unsupported: {s}\n", .{u.what});
        try testing.expect(f.bodies.unsupported == null);
        const ds = f.p.sink.finish();
        errdefer for (ds) |d| std.debug.print("got {?t}: {s}\n", .{ d.code, d.message });
        try testing.expectEqual(want.len, ds.len);
        for (want, ds) |w, d| {
            try testing.expectEqual(w[0], d.code);
            try testing.expect(std.mem.startsWith(u8, d.message, w[1]));
        }
    }

    /// Item `name` of module `a` (module 0: modules are sorted by path).
    fn info(f: *Fixture, name: []const u8) !*const items_mod.Info {
        return f.items.info(.{ .module = 0, .item = f.g.modules[0].names.get(name).? });
    }

    fn scalar(f: *Fixture, name: []const u8) !u64 {
        return (try f.info(name)).@"const".value.scalar.bits;
    }

    fn computed(f: *Fixture, name: []const u8) !Value {
        return f.cx.value((try f.info(name)).@"const".value.computed.id);
    }

    /// The `TypeInfo` case of computed value `v`.
    fn caseName(f: *Fixture, v: Value) ![]const u8 {
        const ti = (try metaType(&f.items, "TypeInfo")).?;
        try testing.expectEqual(ti, v.ty);
        return f.items.enumOf(ti).?.variants[v.data.variant.index].name;
    }
};

/// Reads `rel`, relative to the repository root, from the current
/// directory or one of its parents.
fn readRepoFile(a: Allocator, rel: []const u8) ![]u8 {
    var path: std.ArrayList(u8) = .empty;
    for (0..9) |_| {
        const p = try std.mem.concat(a, u8, &.{ path.items, rel });
        if (std.Io.Dir.cwd().readFileAlloc(testing.io, p, a, .limited(1 << 20))) |bytes| return bytes else |err| switch (err) {
            error.FileNotFound => try path.appendSlice(a, "../"),
            else => return err,
        }
    }
    std.debug.print("{s} not found; run `zig build test` inside the repository\n", .{rel});
    return error.TestUnexpectedResult;
}

test "std/meta.pr declares the compiler's std.meta types verbatim" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const text = try readRepoFile(arena.allocator(), "std/meta.pr");
    const begin = "// compiler: begin\n";
    const start = (std.mem.indexOf(u8, text, begin) orelse return error.TestUnexpectedResult) + begin.len;
    const end = std.mem.indexOfPos(u8, text, start, "// compiler: end") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(source, text[start..end]);
}

test "the std.meta target enums list the targets of target.zig" {
    var f: Fixture = undefined;
    try f.init("");
    defer f.deinit();
    try f.expectDiags(&.{});
    inline for (.{ .{ "Arch", target.Arch }, .{ "Os", target.Os }, .{ "Abi", target.Abi }, .{ "CpuFeature", target.CpuFeature }, .{ "Endian", std.builtin.Endian } }) |e| {
        const en = f.items.enumOf((try metaType(&f.items, e[0])).?).?;
        const want = @typeInfo(e[1]).@"enum".field_names;
        try testing.expectEqual(want.len, en.variants.len);
        for (want, en.variants) |w, v| try testing.expectEqualStrings(w, v.name);
    }
}

/// Type classes with the `TypeInfo` case each has (null: none, §8.4).
const classes = [_]struct { []const u8, ?[]const u8 }{
    .{ "u7", "int" },
    .{ "i64", "int" },
    .{ "usize", "int" },
    .{ "f64", "float" },
    .{ "bool", "bool_" },
    .{ "vec<4, f32>", "vector" },
    .{ "[3]u16", "array" },
    .{ "soa [4]S", "array" },
    .{ "[]u8", "slice" },
    .{ "soa []S", "slice" },
    .{ "*const u8", "pointer" },
    .{ "(u8, u32, bool)", "tuple" },
    .{ "Handle<P>", "handle" },
    .{ "Option<Handle<P>>", "enum_" },
    .{ "Option<u32>", "enum_" },
    .{ "fn(u8, mut u32) -> u32", "function" },
    .{ "P", "struct_" },
    .{ "Q", "struct_" },
    .{ "C", "struct_" },
    .{ "S", "struct_" },
    .{ "E", "enum_" },
    .{ "F", "enum_" },
    .{ "D", "int" },
    .{ "G", "struct_" },
    .{ "str", null },
    .{ "mask<8>", null },
    .{ "isize", "int" },
    .{ "void", "void_" },
    .{ "noreturn", "noreturn_" },
    .{ "DP", "struct_" },
};

/// `type Tn = <class n>;`, its size and alignment as consts, and its
/// `TypeInfo` if it has a case.
fn classSource() []const u8 {
    comptime var s: []const u8 =
        \\struct P { a: u8, pub b: u32, c: bool, pub mut d: u3 = 1, e: Handle<P> }
        \\@packed struct Q { a: u8, b: u32 }
        \\@c_layout struct C { a: u8, b: u64 }
        \\@soa struct S { x: f32, y: u8 }
        \\enum E { a(u8), b(u64, u8), c }
        \\enum F: u16 { x = 3, y }
        \\type D = distinct u32;
        \\fn Gen(comptime T: type) -> type { return struct { x: T, y: u8 }; }
        \\type G = Gen(u64);
        \\type DP = distinct P;
        \\const IT = @type_info(type);
        \\
    ;
    inline for (classes, 0..) |k, i| {
        s = s ++ std.fmt.comptimePrint("type T{d} = {s};\nconst S{d}: usize = @size_of(T{d});\nconst A{d}: usize = @align_of(T{d});\n", .{ i, k[0], i, i, i, i });
        if (k[1] != null) s = s ++ std.fmt.comptimePrint("const I{d} = @type_info(T{d});\n", .{ i, i });
    }
    return s;
}

test "@size_of, @align_of and @type_info agree with the layout engine for every type class" {
    @setEvalBranchQuota(100_000);
    var f: Fixture = undefined;
    try f.init(comptime classSource());
    defer f.deinit();
    try f.expectDiags(&.{});
    var e: layout.Engine = .init(testing.allocator, &f.items);
    defer e.deinit();
    inline for (classes, 0..) |k, i| {
        errdefer std.debug.print("type class `{s}`\n", .{k[0]});
        const t = (try f.info(std.fmt.comptimePrint("T{d}", .{i}))).alias;
        const l = (try e.layoutOf(t)).?;
        try testing.expectEqual(l.size, try f.scalar(std.fmt.comptimePrint("S{d}", .{i})));
        try testing.expectEqual(@as(u64, l.@"align"), try f.scalar(std.fmt.comptimePrint("A{d}", .{i})));
        if (k[1]) |case_name| {
            const v = try f.computed(std.fmt.comptimePrint("I{d}", .{i}));
            try testing.expectEqualStrings(case_name, try f.caseName(v));
            if (std.mem.eql(u8, case_name, "struct_")) {
                // StructInfo: fields, is_soa, is_resource, size, align.
                const s = v.data.variant.payload[0].data.aggregate;
                try testing.expectEqual(l.size, s[3].data.scalar);
                try testing.expectEqual(@as(u64, l.@"align"), s[4].data.scalar);
                const fields = s[0].data.slice;
                try testing.expectEqual(l.fields.len, fields.len);
                // FieldInfo: name, ty, offset, bit_offset, bit_width, ...
                for (l.fields, fields) |p, fv| {
                    const x = fv.data.aggregate;
                    try testing.expectEqual(p.offset, x[2].data.scalar);
                    try testing.expectEqual(@as(u64, p.bit_offset), x[3].data.scalar);
                    try testing.expectEqual(@as(u64, p.width), x[4].data.scalar);
                }
            }
        }
    }
    // `type` has a case but no layout.
    try testing.expectEqualStrings("type_", try f.caseName(try f.computed("IT")));
    // Member facts of `P` (class 16), `S` (19) and `F` (21).
    const p = (try f.computed("I16")).data.variant.payload[0].data.aggregate;
    const d = p[0].data.slice[3].data.aggregate;
    try testing.expectEqualStrings("d", d[0].data.str);
    try testing.expectEqual(TypeId.int(.unsigned, 3), d[1].data.type);
    try testing.expect(d[5].data.scalar == 1 and d[6].data.scalar == 1 and d[7].data.scalar == 1);
    try testing.expectEqual(@as(u64, 0), p[0].data.slice[0].data.aggregate[5].data.scalar); // `a` is private
    try testing.expectEqual(@as(u64, 1), (try f.computed("I19")).data.variant.payload[0].data.aggregate[1].data.scalar); // `@soa`
    const en = (try f.computed("I21")).data.variant.payload[0].data.aggregate;
    try testing.expectEqual(TypeId.int(.unsigned, 16), en[1].data.type);
    try testing.expectEqual(@as(u64, 4), en[0].data.slice[1].data.aggregate[2].data.scalar);
}

test "@type_name, @has_field, @has_method, @implements, @field_type and @variant_count" {
    var f: Fixture = undefined;
    try f.init(
        \\protocol Area { fn area(self) -> f32; }
        \\struct Sq { pub side: f32 }
        \\impl Area for Sq { fn area(self) -> f32 { self.side * self.side } }
        \\struct Pt { x: f32, y: Sq, fn len(self) -> f32 { self.x } }
        \\enum Shape { circle(f32), rect(f32, f32), empty }
        \\fn Wrap(comptime T: type) -> type { const Inner = struct { v: T }; return struct { inner: Inner }; }
        \\type W = Wrap(u8);
        \\type I = @field_type(W, "inner");
        \\const NAME: str = @type_name(W);
        \\const INNER: str = @type_name(I);
        \\const FIELD: str = @type_name(@field_type(Pt, "y"));
        \\const COUNT: usize = @variant_count(Shape);
        \\fn checks() -> bool {
        \\    @has_field(Pt, "x") && !@has_field(Pt, "z") && @has_method(Pt, "len") && @has_method(Sq, "area")
        \\        && !@has_method(Pt, "area") && @implements(Sq, Area) && !@implements(Pt, Area)
        \\}
        \\comptime {
        \\    if !@has_field(Pt, "x") || @has_field(Pt, "z") { @compile_error("has_field"); }
        \\    if !@has_method(Pt, "len") || @has_method(Pt, "area") { @compile_error("own method"); }
        \\    if !@has_method(Sq, "area") || @has_method(Sq, "len") { @compile_error("impl method"); }
        \\    if !@implements(Sq, Area) || @implements(Pt, Area) { @compile_error("implements"); }
        \\}
        \\fn F(comptime T: type) -> type { const S = struct { v: T }; const info = @type_info([2]S); return S; }
        \\const OWN: str = @type_name(F(u8));
        \\fn G(comptime T: type) -> type { const i = @type_info([1]T); return u8; }
        \\fn H(comptime T: type) -> type { const S = struct { v: T }; const K = G(S); return S; }
        \\const NESTED: str = @type_name(H(u8));
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    try testing.expectEqualStrings("Wrap(u8)", (try f.computed("NAME")).data.str);
    // `Inner` is reached by reflection, not returned by `Wrap(u8)` (§8.3.2).
    try testing.expectEqualStrings("Inner", (try f.computed("INNER")).data.str);
    try testing.expectEqualStrings("Sq", (try f.computed("FIELD")).data.str);
    // Reflection inside the instance that returns the type does not stop it
    // being named after the call.
    try testing.expectEqualStrings("F(u8)", (try f.computed("OWN")).data.str);
    // Nor does reflection in a nested instance that runs inside it.
    try testing.expectEqualStrings("H(u8)", (try f.computed("NESTED")).data.str);
    try testing.expectEqual(@as(u64, 3), try f.scalar("COUNT"));
    // In runtime code each call is a constant: no builtin is left to run.
    const body = f.bodies.find(0, "checks").?.func.?;
    for (body.order) |r| try testing.expect(body.op(r) != .builtin);
}

test "reflection errors name the call; TypeInfo reaching runtime is E0802" {
    var f: Fixture = undefined;
    try f.init(
        \\struct Pt { x: f32 }
        \\type A = @field_type(Pt, "z");
        \\const B = @type_info(str);
        \\const D = @variant_count(Pt);
        \\const E = @size_of(type);
        \\fn bad() -> bool { @implements(u8, Pt) }
        \\fn leak() { let i = @type_info(Pt); }
    );
    defer f.deinit();
    try f.expectDiags(&.{
        .{ null, "no field `z` on type `Pt`" },
        .{ null, "`@type_info`: `str` has no `TypeInfo` case" },
        .{ null, "`@variant_count`: `Pt` has no variants" },
        .{ null, "`@size_of`: `type` has no layout: it is comptime-only" },
        .{ null, "`@implements` expects a protocol, found `Pt`" },
        .{ .E0802, "comptime-only value of type `TypeInfo`" },
    });
}

test "@has_method through impls in a const initializer is unsupported (T093)" {
    var f: Fixture = undefined;
    try f.init(
        \\protocol Area { fn area(self) -> f32; }
        \\struct Sq { pub side: f32, fn grow(self) -> f32 { self.side } }
        \\impl Area for Sq { fn area(self) -> f32 { self.side * self.side } }
        \\const OWN: bool = @has_method(Sq, "grow");
        \\const IMPL: bool = @has_method(Sq, "area");
    );
    defer f.deinit();
    try testing.expectEqual(@as(u64, 1), try f.scalar("OWN"));
    try testing.expectEqualStrings("`@has_method` through impls in item-level comptime code (T093)", f.bodies.unsupported.?.what);
}

test "reflection adds no error to a type whose layout an earlier error broke" {
    var f: Fixture = undefined;
    try f.init(
        \\struct Q { a: Nope, b: u8 }
        \\struct R { r: R }
        \\const SQ = @size_of(Q);
        \\const SR = @size_of(R);
        \\const IQ = @type_info(Q);
    );
    defer f.deinit();
    try f.expectDiags(&.{ .{ null, "unknown type `Nope`" }, .{ .E0376, "recursive type `R`" } });
}
