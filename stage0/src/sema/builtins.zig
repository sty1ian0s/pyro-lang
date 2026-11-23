//! The builtin registry (§8.7): every `@` builtin function and builtin
//! variable (§11.1.7), and the prelude formatting intrinsics `print`,
//! `eprint` and `format` (§14.6), with their arity, typing rule and the
//! context they may be used in.
//!
//! `info` is the one table. A builtin's `tir.BuiltinId` is its `Builtin`
//! ordinal, so TIR `builtin` instructions are keyed by this table. Tasks
//! that give a builtin its semantics (SIMD, GPU, unsafe, comptime) add
//! lowering or evaluation in their own files, never rows. Every row has its
//! final `Rule`; a rule whose typing needs a later task has a `typeCall`
//! arm that records the construct as unsupported with that task, and that
//! task fills in only the arm.
//!
//! Checking a builtin call (`check`, `callIntrinsic`) reports, in order:
//! an unknown name, a variable written with parentheses or a function
//! without, a wrong argument count, a use outside the allowed context
//! (E1202, E0805, E1005, `@old` outside `@ensures`), then argument types.
//! Builtins whose typing needs a later task (reflection, comptime inputs,
//! `Option` results, format strings) are recorded as unsupported with
//! that task, after the checks above.

const std = @import("std");
const Ast = @import("../ast/Ast.zig");
const attr_table = @import("../attr_table.zig");
const tir = @import("../tir/tir.zig");
const Types = @import("types.zig");
const convert = @import("convert.zig");
const items_mod = @import("items.zig");
const kinds = @import("kinds.zig");
const layout = @import("layout.zig");
const emit_tir = @import("emit_tir.zig");
const check_expr = @import("check_expr.zig");
const builtins_expr = @import("builtins_expr.zig");
const comptime_ctx = @import("comptime_ctx.zig");
const comptime_flow = @import("comptime_flow.zig");

const Node = Ast.Node;
const TypeId = Types.TypeId;
const Checker = emit_tir.Checker;
const Typed = emit_tir.Typed;
const Error = emit_tir.Error;

/// Every §8.7 builtin, named as written without the `@`, followed by the
/// formatting intrinsics (§14.6).
pub const Builtin = enum(u32) {
    // Reflection and comptime (§8.4–§8.6).
    size_of,
    align_of,
    type_info,
    type_name,
    has_field,
    has_method,
    implements,
    field_type,
    field,
    call,
    fn_info,
    variant_count,
    enum_from_int,
    compile_error,
    compile_log,
    set_eval_quota,
    embed_file,
    env,
    env_or,
    target,
    hash,
    zero,
    // SIMD (§10.6).
    splat,
    select,
    any,
    all,
    count,
    reduce_add,
    reduce_mul,
    reduce_min,
    reduce_max,
    reduce_and,
    reduce_or,
    shuffle,
    vector_width,
    fma,
    // Integer arithmetic (§6.4.2) and bit operations.
    add_wrap,
    sub_wrap,
    mul_wrap,
    add_sat,
    sub_sat,
    mul_sat,
    add_checked,
    sub_checked,
    mul_checked,
    shl_checked,
    clz,
    ctz,
    popcount,
    bswap,
    bit_reverse,
    bit_cast,
    // Errors and contracts (§9).
    todo_err,
    trap,
    @"unreachable",
    old,
    // GPU (§11.1.7, §11.6.2).
    global_invocation_id,
    local_invocation_id,
    workgroup_id,
    num_workgroups,
    workgroup_barrier,
    vertex_index,
    instance_index,
    frag_coord,
    front_facing,
    sample_index,
    launch_id,
    launch_size,
    discard,
    dpdx,
    dpdy,
    fwidth,
    spec,
    // Unsafe (§12.2, §12.9).
    volatile_read,
    volatile_write,
    ptr_from_int,
    ptr_add,
    int_from_ptr,
    // Ordering and hints (§10.5).
    atomic_fence,
    prefetch,
    likely,
    unlikely,
    // Formatting intrinsics (§14.6): prelude identifiers, not `@` names.
    print,
    eprint,
    format,

    /// The TIR key of this builtin.
    pub fn id(b: Builtin) tir.BuiltinId {
        return .from(@backingInt(b));
    }
};

/// How a builtin is written.
pub const Form = enum {
    /// `@name(args)`.
    function,
    /// `@name`, without parentheses (§3.8, §11.1.7).
    variable,
    /// `name(args)`: a prelude formatting intrinsic (§8.7, §14.6).
    intrinsic,
};

/// A GPU pipeline stage (§11.1.1), named by its stage attribute.
pub const Stage = enum { compute, task, mesh, vertex, fragment, ray_gen, miss, closest_hit, any_hit, intersection };
pub const Stages = std.EnumSet(Stage);

/// Where a builtin may be used (the Context column of §8.7).
pub const Allowed = union(enum) {
    any,
    /// Evaluated at compile time; its value arguments must be comptime-known (§8.1).
    @"comptime",
    /// Usable anywhere; its argument must be comptime-known (`@hash`, §8.6.1).
    comptime_arg,
    /// Only inside `unsafe`, never at comptime (§12.1, §8.6).
    unsafe,
    /// Only in an `@ensures` condition (§9.5).
    ensures,
    /// Only in code of these stages (§11.1.7).
    stages: Stages,
};

/// How a call's result type follows from its arguments (§8.7). Each rule
/// is implemented by `typeCall`.
pub const Rule = enum {
    /// `@size_of`, `@align_of`, `@type_info`, `@type_name`,
    /// `@variant_count`, `@has_field`, `@has_method`, `@implements`,
    /// `@field_type` (T069).
    reflect,
    /// `(x, comptime str) -> F` (T072).
    field,
    /// `(f, args...) -> R` (T071).
    call,
    /// `(f) -> FnInfo` (T071).
    fn_info,
    /// `(E, I) -> Option<E>`.
    enum_from_int,
    /// `(I, I) -> Option<I>`; `@shl_checked` is `(I, U) -> Option<I>`, `U` unsigned.
    checked,
    /// `@compile_error(comptime str) -> noreturn`, `@compile_log(args...) -> void`
    /// (`comptime_flow.zig`).
    compile_diag,
    /// `(u32) -> void`; evaluated by `comptime/limits.zig`.
    eval_quota,
    /// `@embed_file`, `@env`, `@env_or`, `@target` (T073).
    comptime_input,
    /// `(comptime str) -> u64` (`comptime_flow.zig`).
    hash,
    /// `(vec<N, T>, comptime [M]u32) -> vec<M, T>` (T126).
    shuffle,
    /// `(T) -> usize` (T129).
    vector_width,
    /// `@todo_err` (T140).
    todo_err,
    /// `(ordering) -> void` (T130).
    atomic_fence,
    /// `(T) -> T`, `T` plain.
    zero,
    /// `(N, x) -> vec<N, T>`.
    splat,
    /// `(mask<N>, V, V) -> V`, `V` a `vec<N, _>` or `mask<N>`.
    select,
    /// `(mask<N>) -> bool`.
    mask_test,
    /// `(mask<N>) -> usize`.
    count,
    /// `(vec<N, T>) -> T`, `T` numeric.
    reduce,
    /// `(vec<N, T>) -> T`, `T` integer or `bool`; `(mask<N>) -> bool`.
    reduce_bits,
    /// `(F, F, F) -> F`, `F` a float or float `vec`.
    fma,
    /// `(I, I) -> I`, `I` an integer type.
    int_binary,
    /// `(I) -> I`, `I` an integer or integer `vec`.
    bit_op,
    /// Like `bit_op`, on whole bytes.
    bswap,
    /// `(T, x) -> T`, both plain and of equal size.
    bit_cast,
    /// `(str) -> noreturn`.
    trap,
    /// `() -> noreturn`.
    never,
    /// `(e) -> typeof(e)`.
    old,
    /// `vec3<u32>` variable.
    var_vec3_u32,
    /// `u32` variable.
    var_u32,
    /// `vec4<f32>` variable.
    var_vec4_f32,
    /// `bool` variable.
    var_bool,
    /// `() -> void`.
    unit,
    /// `(F) -> F`, `F` an `f32` or `vec<N, f32>`.
    derivative,
    /// `(comptime str, d) -> typeof(d)`.
    spec,
    /// `(*const T) -> T`.
    volatile_read,
    /// `(*T, T) -> void`.
    volatile_write,
    /// `(T, usize) -> *T`.
    ptr_from_int,
    /// `(P, isize) -> P`, `P` a raw pointer.
    ptr_add,
    /// `(P) -> usize`.
    int_from_ptr,
    /// `(P, .read | .write) -> void`.
    prefetch,
    /// `(bool) -> bool`.
    hint,
    /// `(comptime str, args...) -> void`.
    format,
    /// `(mut []u8, comptime str, args...) -> Result<str, fmt.Overflow>`.
    format_into,
};

/// One row of the registry.
pub const Info = struct {
    form: Form = .function,
    /// Number of arguments; the minimum if `variadic`.
    arity: u8 = 0,
    variadic: bool = false,
    allowed: Allowed = .any,
    rule: Rule,
};

/// The registry: the row of builtin `b`.
pub fn info(b: Builtin) Info {
    const compute: Allowed = .{ .stages = .initMany(&.{ .compute, .task, .mesh }) };
    const fragment: Allowed = .{ .stages = .initOne(.fragment) };
    const ray: Allowed = .{ .stages = .initMany(&.{ .ray_gen, .miss, .closest_hit, .any_hit, .intersection }) };
    return switch (b) {
        .size_of, .align_of, .type_info, .type_name, .variant_count => .{ .arity = 1, .allowed = .@"comptime", .rule = .reflect },
        .has_field, .has_method, .implements, .field_type => .{ .arity = 2, .allowed = .@"comptime", .rule = .reflect },
        .field => .{ .arity = 2, .rule = .field },
        .call => .{ .arity = 1, .variadic = true, .rule = .call },
        .fn_info => .{ .arity = 1, .allowed = .@"comptime", .rule = .fn_info },
        .enum_from_int => .{ .arity = 2, .rule = .enum_from_int },
        .compile_error => .{ .arity = 1, .allowed = .@"comptime", .rule = .compile_diag },
        .compile_log => .{ .variadic = true, .allowed = .@"comptime", .rule = .compile_diag },
        .set_eval_quota => .{ .arity = 1, .allowed = .@"comptime", .rule = .eval_quota },
        .embed_file, .env => .{ .arity = 1, .allowed = .@"comptime", .rule = .comptime_input },
        .env_or => .{ .arity = 2, .allowed = .@"comptime", .rule = .comptime_input },
        .target => .{ .allowed = .@"comptime", .rule = .comptime_input },
        .hash => .{ .arity = 1, .allowed = .comptime_arg, .rule = .hash },
        .zero => .{ .arity = 1, .rule = .zero },
        .splat => .{ .arity = 2, .rule = .splat },
        .select => .{ .arity = 3, .rule = .select },
        .any, .all => .{ .arity = 1, .rule = .mask_test },
        .count => .{ .arity = 1, .rule = .count },
        .reduce_add, .reduce_mul, .reduce_min, .reduce_max => .{ .arity = 1, .rule = .reduce },
        .reduce_and, .reduce_or => .{ .arity = 1, .rule = .reduce_bits },
        .shuffle => .{ .arity = 2, .rule = .shuffle },
        .vector_width => .{ .arity = 1, .allowed = .@"comptime", .rule = .vector_width },
        .fma => .{ .arity = 3, .rule = .fma },
        .add_wrap, .sub_wrap, .mul_wrap, .add_sat, .sub_sat, .mul_sat => .{ .arity = 2, .rule = .int_binary },
        .add_checked, .sub_checked, .mul_checked, .shl_checked => .{ .arity = 2, .rule = .checked },
        .clz, .ctz, .popcount, .bit_reverse => .{ .arity = 1, .rule = .bit_op },
        .bswap => .{ .arity = 1, .rule = .bswap },
        .bit_cast => .{ .arity = 2, .rule = .bit_cast },
        .todo_err => .{ .arity = 1, .rule = .todo_err },
        .trap => .{ .arity = 1, .rule = .trap },
        .@"unreachable" => .{ .rule = .never },
        .old => .{ .arity = 1, .allowed = .ensures, .rule = .old },
        .global_invocation_id, .local_invocation_id, .workgroup_id, .num_workgroups => .{ .form = .variable, .allowed = compute, .rule = .var_vec3_u32 },
        .workgroup_barrier => .{ .allowed = compute, .rule = .unit },
        .vertex_index, .instance_index => .{ .form = .variable, .allowed = .{ .stages = .initOne(.vertex) }, .rule = .var_u32 },
        .frag_coord => .{ .form = .variable, .allowed = fragment, .rule = .var_vec4_f32 },
        .front_facing => .{ .form = .variable, .allowed = fragment, .rule = .var_bool },
        .sample_index => .{ .form = .variable, .allowed = fragment, .rule = .var_u32 },
        .launch_id, .launch_size => .{ .form = .variable, .allowed = ray, .rule = .var_vec3_u32 },
        .discard => .{ .allowed = fragment, .rule = .never },
        .dpdx, .dpdy, .fwidth => .{ .arity = 1, .allowed = fragment, .rule = .derivative },
        .spec => .{ .arity = 2, .allowed = .{ .stages = .full }, .rule = .spec },
        .volatile_read => .{ .arity = 1, .allowed = .unsafe, .rule = .volatile_read },
        .volatile_write => .{ .arity = 2, .allowed = .unsafe, .rule = .volatile_write },
        .ptr_from_int => .{ .arity = 2, .allowed = .unsafe, .rule = .ptr_from_int },
        .ptr_add => .{ .arity = 2, .allowed = .unsafe, .rule = .ptr_add },
        .int_from_ptr => .{ .arity = 1, .rule = .int_from_ptr },
        .atomic_fence => .{ .arity = 1, .rule = .atomic_fence },
        .prefetch => .{ .arity = 2, .rule = .prefetch },
        .likely, .unlikely => .{ .arity = 1, .rule = .hint },
        .print, .eprint => .{ .form = .intrinsic, .arity = 1, .variadic = true, .rule = .format },
        .format => .{ .form = .intrinsic, .arity = 2, .variadic = true, .rule = .format_into },
    };
}

/// The `@` builtin named `name` (without the `@`), or null.
pub fn lookup(name: []const u8) ?Builtin {
    const b = std.meta.stringToEnum(Builtin, name) orelse return null;
    return if (info(b).form == .intrinsic) null else b;
}

/// The formatting intrinsic named `name`, or null.
pub fn intrinsic(name: []const u8) ?Builtin {
    const b = std.meta.stringToEnum(Builtin, name) orelse return null;
    return if (info(b).form == .intrinsic) b else null;
}

// ---------------------------------------------------------------------------
// Context

/// The context of a builtin use.
pub const Context = struct {
    in_comptime: bool = false,
    in_unsafe: bool = false,
    in_ensures: bool = false,
    /// The stage of the enclosing function, if it is one.
    stage: ?Stage = null,
};

/// Why a builtin may not be used in a context.
pub const Violation = enum {
    /// An `unsafe` builtin at comptime (E0805).
    @"comptime",
    /// Outside `unsafe` (E1202).
    unsafe,
    /// Outside `@ensures`.
    ensures,
    /// Outside the builtin's stages (E1005).
    stage,
};

/// Whether `b` may be used in `ctx`, and if not, why.
pub fn violation(b: Builtin, ctx: Context) ?Violation {
    return switch (info(b).allowed) {
        .any, .@"comptime", .comptime_arg => null,
        .unsafe => if (ctx.in_comptime) .@"comptime" else if (!ctx.in_unsafe) .unsafe else null,
        .ensures => if (ctx.in_ensures) null else .ensures,
        .stages => |s| if (ctx.stage != null and s.contains(ctx.stage.?)) null else .stage,
    };
}

/// The stage of a function with attributes `attrs`, if it is one.
pub fn stageOf(ast: *const Ast, attrs: []const Node.Index) ?Stage {
    const map = [_]struct { attr_table.Attr, Stage }{
        .{ .gpu_kernel, .compute },            .{ .gpu_task, .task },               .{ .gpu_mesh, .mesh },
        .{ .gpu_vertex, .vertex },             .{ .gpu_fragment, .fragment },       .{ .gpu_ray_gen, .ray_gen },
        .{ .gpu_miss, .miss },                 .{ .gpu_closest_hit, .closest_hit }, .{ .gpu_any_hit, .any_hit },
        .{ .gpu_intersection, .intersection },
    };
    for (map) |e| if (items_mod.hasAttr(ast, attrs, e[0])) return e[1];
    return null;
}

fn contextOf(c: *Checker) Context {
    // shortcut: `@ensures` contracts are not checked yet; T135 sets `in_ensures` when it checks them.
    return .{ .stage = stageOf(c.ast, c.sig.attrs), .in_unsafe = c.in_unsafe, .in_comptime = c.in_comptime };
}

// ---------------------------------------------------------------------------
// Checking

/// Checks the `builtin_call` node `n` (§8.7): `@name(args)` or `@name`.
pub fn check(c: *Checker, n: Node.Index, expected: TypeId) Error!Typed {
    const name = c.ast.tokenSlice(c.ast.mainToken(n));
    const args = c.ast.data(n).builtin_call.args;
    const b = lookup(name[1..]) orelse {
        try c.report(n, null, "unknown builtin `{s}`", .{name});
        return .err;
    };
    const form = info(b).form;
    if (form == .variable and args != null) {
        try c.report(n, null, "`{s}` is a builtin variable and takes no parentheses", .{name});
        return .err;
    }
    if (form == .function and args == null) {
        try c.report(n, null, "builtin function `{s}` must be called: `{s}(...)`", .{ name, name });
        return .err;
    }
    return call(c, n, name, b, args orelse &.{}, expected);
}

/// Checks the call `n` of prelude function `name` if it is a formatting
/// intrinsic (§14.6); null otherwise.
pub fn callIntrinsic(c: *Checker, n: Node.Index, name: []const u8) Error!?Typed {
    const b = intrinsic(name) orelse return null;
    const d = c.ast.data(n).call;
    return try call(c, d.callee, name, b, d.args, .none);
}

/// A builtin call `b` at node `at` with argument nodes `args`.
fn call(c: *Checker, at: Node.Index, name: []const u8, b: Builtin, args: []const Node.Index, expected: TypeId) Error!Typed {
    const i = info(b);
    if (args.len < i.arity or (!i.variadic and args.len > i.arity)) {
        try c.report(at, null, "`{s}` takes {s}{d} argument{s}, found {d}", .{
            name, if (i.variadic) "at least " else "", i.arity, if (i.arity == 1) "" else "s", args.len,
        });
        return .err;
    }
    const ctx = contextOf(c);
    if (violation(b, ctx)) |v| switch (v) {
        .@"comptime" => try c.report(at, .E0805, "`{s}` cannot be used at comptime", .{name}),
        .unsafe => try c.report(at, .E1202, "`{s}` is only allowed inside `unsafe`", .{name}),
        .ensures => try c.report(at, null, "`{s}` is only allowed in an `@ensures` condition", .{name}),
        .stage => if (ctx.stage) |s|
            try c.report(at, .E1005, "`{s}` is not available in a {t} stage", .{ name, s })
        else
            try c.report(at, .E1005, "`{s}` is only available in GPU stage functions", .{name}),
    };
    var a: Args = .{ .c = c, .at = at, .name = name, .b = b, .ctx = ctx, .nodes = args, .refs = try c.arena.alloc(tir.Ref, args.len) };
    @memset(a.refs, .none);
    return typeCall(&a, i.rule, expected);
}

/// The arguments of one builtin call as they are checked.
pub const Args = struct {
    c: *Checker,
    at: Node.Index,
    name: []const u8,
    b: Builtin,
    ctx: Context,
    nodes: []const Node.Index,
    refs: []tir.Ref,
    ok: bool = true,
    diverges: bool = false,

    /// Stores checked argument `v` as argument `i`.
    pub fn record(a: *Args, i: usize, v: Typed) Typed {
        a.ok = a.ok and v.ty != .err;
        a.diverges = a.diverges or v.ty == .noreturn;
        a.refs[i] = v.ref;
        return v;
    }

    /// Value argument `i`; an untyped constant gets its default type.
    pub fn value(a: *Args, i: usize, expected: TypeId) Error!Typed {
        return a.record(i, try a.c.materialize(try check_expr.check(a.c, a.nodes[i], expected), a.nodes[i]));
    }

    /// Value argument `i` converted to `to`.
    pub fn as(a: *Args, i: usize, to: TypeId) Error!Typed {
        return a.record(i, try check_expr.checkAs(a.c, a.nodes[i], to));
    }

    /// Type argument `i`, passed as a `type` value.
    pub fn typeArg(a: *Args, i: usize) Error!TypeId {
        const t = try a.c.resolveType(a.nodes[i]);
        a.ok = a.ok and t != .err;
        a.refs[i] = try a.c.emit(.type, .{ .type = .{ .value = t } });
        return t;
    }

    /// Arguments `0..count`, converted to one type (§6.4.1): the first
    /// typed argument's, else `expected`, else the first constant's default.
    pub fn common(a: *Args, count: usize, expected: TypeId) Error!TypeId {
        var vs: [4]Typed = undefined;
        var ty: TypeId = .none;
        for (vs[0..count], 0..) |*v, i| {
            v.* = try check_expr.check(a.c, a.nodes[i], expected);
            if (ty == .none and !v.isUntyped() and v.ty != .noreturn and v.ty != .err) ty = v.ty;
        }
        if (ty == .none and expected != .err) ty = expected;
        if (ty == .none) for (vs[0..count]) |v| if (v.isUntyped()) {
            ty = convert.defaultType(v.ty);
            break;
        };
        for (vs[0..count], 0..) |v, i| _ = a.record(i, if (ty == .none) v else try a.c.coerce(v, ty, a.nodes[i]));
        return if (a.ok and ty != .none) ty else .err;
    }

    /// E0310 at argument `i`: `found` is not `what`. Silent for a failed or
    /// diverging argument.
    pub fn wrong(a: *Args, i: usize, what: []const u8, found: TypeId) Error!Typed {
        if (found != .err and found != .noreturn) {
            try a.c.report(a.nodes[i], .E0310, "`{s}` expects {s}, found `{s}`", .{ a.name, what, try a.c.tyName(found) });
            a.ok = false;
        }
        return a.finish(.err);
    }

    /// The call's value, of type `ty`, once the arguments are checked.
    pub fn finish(a: *Args, ty: TypeId) Error!Typed {
        if (a.ok and a.diverges) return .never;
        if (!a.ok or ty == .err) {
            a.c.failed = true;
            return .err;
        }
        const r = try a.c.emit(ty, .{ .builtin = .{ .builtin = a.b.id(), .args = a.refs } });
        if (ty == .noreturn) {
            _ = try a.c.emit(.void, .{ .@"unreachable" = .{} });
            return .never;
        }
        return .{ .ty = ty, .ref = r };
    }
};

/// Types the arguments and result of a call by `rule` (see `Rule`).
fn typeCall(a: *Args, rule: Rule, expected: TypeId) Error!Typed {
    const c = a.c;
    switch (rule) {
        .reflect => return c.unsupported(a.at, "reflection builtins (T069)"),
        .field => return c.unsupported(a.at, "`@field` (T072)"),
        .call, .fn_info => return c.unsupported(a.at, "`@call` and `@fn_info` (T071)"),
        .enum_from_int => return builtins_expr.enumFromInt(a),
        .checked => return builtins_expr.checked(a, expected),
        .compile_diag => return comptime_flow.compileDiag(a),
        .eval_quota => {
            _ = try a.as(0, .int(.unsigned, 32));
            return a.finish(.void);
        },
        .comptime_input => return c.unsupported(a.at, "comptime inputs (T073)"),
        .hash => return comptime_flow.hash(a),
        .shuffle => return c.unsupported(a.at, "`@shuffle` (T126)"),
        .vector_width => return c.unsupported(a.at, "`@vector_width` (T129)"),
        .todo_err => return c.unsupported(a.at, "`@todo_err` (T140)"),
        .atomic_fence => return c.unsupported(a.at, "`@atomic_fence` (T130)"),
        .format_into => return c.unsupported(a.at, "`format` into a buffer (T112)"),
        .zero => {
            const t = try a.typeArg(0);
            if (t != .err and try kinds.kind(c.items, t) != .plain) {
                try c.report(a.nodes[0], .E0329, "`@zero` needs a plain type, found `{s}`", .{try c.tyName(t)});
                return .err;
            }
            return a.finish(t);
        },
        .splat => {
            const lanes = try laneCount(a);
            const want: TypeId = if (expected == .none) .none else switch (c.types.get(expected)) {
                .vec => |v| if (v.len == lanes) v.elem else .none,
                else => .none,
            };
            const x = if (want != .none) try a.as(1, want) else try a.value(1, .none);
            if (lanes == 0 or !a.ok) return a.finish(.err);
            if (!vecElem(c, x.ty)) return a.wrong(1, "a `vec` element type (integer, `f32`, `f64` or `bool`)", x.ty);
            const ty = try c.types.intern(.{ .vec = .{ .len = lanes, .elem = x.ty } });
            if (a.diverges) return .never;
            return .{ .ty = ty, .ref = try c.emit(ty, .{ .splat = .{ .scalar = x.ref } }) };
        },
        .select => {
            const m = try a.value(0, .none);
            // `@splat`'s lane type comes from the other value (§8.7); it is
            // checked first only when that cannot change evaluation order (§6.1).
            const swap = expected == .none and constSplat(c, a.nodes[1]);
            const x = try a.value(if (swap) 2 else 1, expected);
            _ = try a.as(if (swap) 1 else 2, x.ty);
            const len = maskLen(c, m.ty) orelse return a.wrong(0, "a `mask<N>`", m.ty);
            const ok = switch (c.types.get(c.underlying(x.ty))) {
                .vec => |v| v.len == len,
                .mask => |k| k.len == len,
                else => false,
            };
            if (!ok) return a.wrong(if (swap) 2 else 1, "a `vec` or `mask` with the mask's lane count", x.ty);
            return a.finish(x.ty);
        },
        .mask_test, .count => {
            const m = try a.value(0, .none);
            if (maskLen(c, m.ty) == null) return a.wrong(0, "a `mask<N>`", m.ty);
            return a.finish(if (rule == .count) .usize else .bool);
        },
        .reduce, .reduce_bits => {
            const v = try a.value(0, .none);
            switch (c.types.get(c.underlying(v.ty))) {
                .vec => |x| if (if (rule == .reduce) x.elem != .bool else x.elem == .bool or isInt(c, x.elem)) return a.finish(x.elem),
                .mask => if (rule == .reduce_bits) return a.finish(.bool),
                else => {},
            }
            return a.wrong(0, if (rule == .reduce) "a numeric `vec`" else "an integer or `bool` `vec`, or a `mask`", v.ty);
        },
        .fma, .derivative => {
            const ty = if (rule == .fma) try a.common(3, expected) else (try a.value(0, expected)).ty;
            const u = c.underlying(ty);
            const elem = switch (c.types.get(u)) {
                .vec => |v| v.elem,
                else => u,
            };
            const ok = if (rule == .fma) elem == .f32 or elem == .f64 else elem == .f32;
            if (!ok) return a.wrong(0, if (rule == .fma) "a float or float `vec`" else "an `f32` or `vec<N, f32>`", ty);
            return a.finish(ty);
        },
        .int_binary => {
            const ty = try a.common(2, expected);
            if (!isInt(c, c.underlying(ty))) return a.wrong(0, "an integer", ty);
            return a.finish(ty);
        },
        .bit_op, .bswap => {
            const x = try a.value(0, expected);
            const u = c.underlying(x.ty);
            const elem = switch (c.types.get(u)) {
                .vec => |v| v.elem,
                else => u,
            };
            if (!isInt(c, elem)) return a.wrong(0, "an integer or integer `vec`", x.ty);
            if (rule == .bswap and intBits(c, elem) % 8 != 0) return a.wrong(0, "an integer of whole bytes", x.ty);
            return a.finish(x.ty);
        },
        .bit_cast => return bitCast(a),
        .trap => {
            _ = try a.as(0, .str);
            return a.finish(.noreturn);
        },
        .never => return a.finish(.noreturn),
        .old => return a.finish((try a.value(0, expected)).ty),
        .var_vec3_u32 => return a.finish(try c.types.intern(.{ .vec = .{ .len = 3, .elem = .int(.unsigned, 32) } })),
        .var_vec4_f32 => return a.finish(try c.types.intern(.{ .vec = .{ .len = 4, .elem = .f32 } })),
        .var_u32 => return a.finish(.int(.unsigned, 32)),
        .var_bool => return a.finish(.bool),
        .unit => return a.finish(.void),
        .spec => {
            try comptimeStr(a, 0);
            return a.finish((try a.value(1, expected)).ty);
        },
        .volatile_read, .int_from_ptr => {
            const p = try a.value(0, .none);
            const ptr = ptrOf(c, p.ty) orelse return a.wrong(0, "a raw pointer", p.ty);
            return a.finish(if (rule == .volatile_read) ptr.elem else .usize);
        },
        .volatile_write => {
            const p = try a.value(0, .none);
            const ptr = ptrOf(c, p.ty);
            const writable = ptr != null and !ptr.?.is_const;
            _ = if (writable) try a.as(1, ptr.?.elem) else try a.value(1, .none);
            if (!writable) return a.wrong(0, "a `*T` pointer", p.ty);
            return a.finish(.void);
        },
        .ptr_from_int => {
            const t = try a.typeArg(0);
            _ = try a.as(1, .usize);
            return a.finish(if (t == .err) .err else try c.types.intern(.{ .ptr = .{ .elem = t, .is_const = false } }));
        },
        .ptr_add => {
            const p = try a.value(0, .none);
            _ = try a.as(1, .isize);
            if (ptrOf(c, p.ty) == null) return a.wrong(0, "a raw pointer", p.ty);
            return a.finish(p.ty);
        },
        .prefetch => {
            const p = try a.value(0, .none);
            const hint = a.nodes[1];
            const write = c.ast.kind(hint) == .inferred_member and std.mem.eql(u8, c.ast.tokenSlice(c.ast.mainToken(hint)), "write");
            if (!write and !(c.ast.kind(hint) == .inferred_member and std.mem.eql(u8, c.ast.tokenSlice(c.ast.mainToken(hint)), "read"))) {
                try c.report(hint, .E0310, "`@prefetch` expects `.read` or `.write`", .{});
                return .err;
            }
            _ = a.record(1, try c.constant(.{ .type = .bool, .bits = @intFromBool(write) }));
            if (ptrOf(c, p.ty) == null) return a.wrong(0, "a raw pointer", p.ty);
            return a.finish(.void);
        },
        .hint => {
            _ = try a.as(0, .bool);
            return a.finish(.bool);
        },
        .format => {
            try comptimeStr(a, 0);
            for (1..a.nodes.len) |i| _ = try a.value(i, .none);
            return c.unsupported(a.at, "format strings and their arguments (T112)");
        },
    }
}

/// `@bit_cast(T, x)` (§8.7): `T` and `x` plain and of equal size; a `T`
/// with invalid bit patterns needs `unsafe` (§12.1, E1202).
fn bitCast(a: *Args) Error!Typed {
    const c = a.c;
    const t = try a.typeArg(0);
    const x = try a.value(1, .none);
    if (t == .err or !a.ok or a.diverges) return a.finish(t);
    for ([_]struct { usize, TypeId }{ .{ 0, t }, .{ 1, x.ty } }) |e| if (try kinds.kind(c.items, e[1]) != .plain) {
        try c.report(a.nodes[e[0]], .E0329, "`@bit_cast` needs plain types, found `{s}`", .{try c.tyName(e[1])});
        return .err;
    };
    var engine: layout.Engine = .init(c.arena, c.items);
    const lt = try engine.layoutOf(t) orelse return c.unsupported(a.at, "`@bit_cast` of types without a layout yet (T045)");
    const lx = try engine.layoutOf(x.ty) orelse return c.unsupported(a.at, "`@bit_cast` of types without a layout yet (T045)");
    if (lt.size != lx.size) {
        try c.report(a.nodes[1], .E0310, "`@bit_cast` needs types of equal size: `{s}` has {d} bytes, `{s}` has {d}", .{ try c.tyName(t), lt.size, try c.tyName(x.ty), lx.size });
        return .err;
    }
    if (!a.ctx.in_unsafe and try invalidBits(c, t, 0)) {
        try c.report(a.at, .E1202, "`@bit_cast` to `{s}`, which has invalid bit patterns, is only allowed inside `unsafe`", .{try c.tyName(t)});
        return .err;
    }
    return a.finish(t);
}

/// Whether some bit pattern of plain type `ty` is not a value: it holds a
/// `bool`, an enum or a handle (§8.7).
fn invalidBits(c: *Checker, ty: TypeId, depth: u32) Error!bool {
    if (depth > 64) return false; // recursive types are E0376
    if (ty == .bool) return true;
    switch (c.types.get(ty)) {
        .handle, .mask => return true,
        .vec => |v| return v.elem == .bool,
        .array => |x| return invalidBits(c, x.elem, depth + 1),
        .tuple => |x| {
            for (x.elems) |e| if (try invalidBits(c, e, depth + 1)) return true;
            return false;
        },
        .nominal => |nm| {
            if (nm.kind == .distinct) return invalidBits(c, nm.underlying, depth + 1);
            const s = c.items.structOf(ty) orelse return true; // enums
            for (s.fields) |f| if (try invalidBits(c, f.type, depth + 1)) return true;
            return false;
        },
        else => return false,
    }
}

/// The lane count of `@splat` (argument 0): a comptime-known integer in
/// `1..64` (§4.3.1, E0303); 0 if reported.
fn laneCount(a: *Args) Error!u32 {
    const c = a.c;
    const n = a.nodes[0];
    const v = try check_expr.check(c, n, .none);
    if (v.ty == .err) return 0;
    const lanes: ?u64 = if (v.konst) |k| (if (k == .int) switch (try convert.convertConst(c.arena, c.types, 64, k, .int(.unsigned, 64))) {
        .ok => |x| x.bits,
        .err => null,
    } else null) else blk: {
        // A typed expression: the lane count is a comptime context (§8.1).
        // shortcut: the operand was also emitted as dead runtime code above; a call in it would run at runtime too, until the checker can discard code.
        const cx = comptime_ctx.of(c.items) orelse {
            try c.report(n, .E0801, "the lane count of `@splat` must be a comptime-known integer", .{});
            return 0;
        };
        const r = try cx.eval(c.items, c.m, n, v.ty) orelse {
            c.failed = true; // reported, or recorded as unsupported
            return 0;
        };
        // A negative signed count reads as a huge one.
        break :blk if (r == .scalar and isInt(c, r.scalar.type)) r.scalar.bits else null;
    };
    if (lanes == null or lanes.? < 1 or lanes.? > 64) {
        try c.report(n, .E0303, "a `vec` has 1 to 64 lanes", .{});
        return 0;
    }
    return @intCast(lanes.?);
}

/// Argument `i` is a comptime-known `str` (E0801): a string literal, a
/// `const`, or another expression evaluated at comptime (§8.1).
fn comptimeStr(a: *Args, i: usize) Error!void {
    const c = a.c;
    if ((try a.as(i, .str)).ty != .str) return;
    var n = a.nodes[i];
    while (c.ast.kind(n) == .paren) n = c.ast.data(n).paren.inner;
    const known = switch (c.ast.kind(n)) {
        .string_lit => true,
        .ident => if (c.items.names.get(c.m, n)) |e| switch (e.res) {
            .local => |l| c.ast.kind(l) == .const_decl,
            .global => |t| t == .item and c.items.im.graph.modules[t.item.module].items[t.item.item].kind == .@"const",
        } else false,
        // Any other expression is a comptime context (§8.1).
        else => if (comptime_ctx.of(c.items)) |cx| {
            if (try cx.eval(c.items, c.m, n, .str) == null) {
                c.failed = true; // reported, or recorded as unsupported
                a.ok = false;
            }
            return;
        } else false,
    };
    if (!known) {
        try c.report(a.nodes[i], .E0801, "`{s}` needs a comptime-known string here", .{a.name});
        a.ok = false;
    }
}

/// Whether `n` is `@splat(N, k)` with `k` a numeric or `bool` literal,
/// possibly negated: its lane type needs context and it has no effects.
fn constSplat(c: *Checker, n: Node.Index) bool {
    const ast = c.ast;
    if (ast.kind(n) != .builtin_call or !std.mem.eql(u8, ast.tokenSlice(ast.mainToken(n)), "@splat")) return false;
    const args = ast.data(n).builtin_call.args orelse return false;
    if (args.len != 2) return false;
    var k = args[1];
    while (true) switch (ast.kind(k)) {
        .paren => k = ast.data(k).paren.inner,
        .prefix => k = ast.data(k).prefix.operand,
        .int_lit, .float_lit, .bool_lit => return true,
        else => return false,
    };
}

fn maskLen(c: *Checker, ty: TypeId) ?u32 {
    return switch (c.types.get(c.underlying(ty))) {
        .mask => |m| m.len,
        else => null,
    };
}

fn ptrOf(c: *Checker, ty: TypeId) ?@FieldType(Types.Key, "ptr") {
    return switch (c.types.get(ty)) {
        .ptr => |p| p,
        else => null,
    };
}

pub fn isInt(c: *Checker, ty: TypeId) bool {
    return ty == .usize or ty == .isize or c.types.get(ty) == .int;
}

fn intBits(c: *Checker, ty: TypeId) u32 {
    return switch (c.types.get(ty)) {
        .int => |i| i.bits,
        else => c.items.options.ptr_bits,
    };
}

/// A valid `vec` element (§4.3.1, E0303): an integer of 1, 2, 4 or 8
/// bytes, `f32`, `f64` or `bool`.
pub fn vecElem(c: *Checker, ty: TypeId) bool {
    if (ty == .f32 or ty == .f64 or ty == .bool or ty == .usize or ty == .isize) return true;
    return switch (c.types.get(ty)) {
        .int => |i| i.bits == 8 or i.bits == 16 or i.bits == 32 or i.bits == 64,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const Fixture = emit_tir.Fixture;

test "registry: lookup, forms and arities" {
    try testing.expectEqual(Builtin.splat, lookup("splat").?);
    try testing.expectEqual(Builtin.@"unreachable", lookup("unreachable").?);
    try testing.expectEqual(null, lookup("print"));
    try testing.expectEqual(null, lookup("frobnicate"));
    try testing.expectEqual(Builtin.format, intrinsic("format").?);
    try testing.expectEqual(null, intrinsic("splat"));
    try testing.expectEqual(Form.variable, info(.frag_coord).form);
    try testing.expect(info(.print).variadic and info(.compile_log).variadic);
    for (std.enums.values(Builtin)) |b| {
        const i = info(b);
        if (i.form == .variable) try testing.expectEqual(0, i.arity);
    }
}

test "context rules: unsafe, comptime, @ensures, stages" {
    try testing.expectEqual(Violation.unsafe, violation(.ptr_add, .{}).?);
    try testing.expectEqual(null, violation(.ptr_add, .{ .in_unsafe = true }));
    try testing.expectEqual(Violation.@"comptime", violation(.volatile_read, .{ .in_comptime = true, .in_unsafe = true }).?);
    try testing.expectEqual(null, violation(.int_from_ptr, .{}));
    try testing.expectEqual(Violation.ensures, violation(.old, .{}).?);
    try testing.expectEqual(null, violation(.old, .{ .in_ensures = true }));
    try testing.expectEqual(null, violation(.workgroup_barrier, .{ .stage = .mesh }));
    try testing.expectEqual(Violation.stage, violation(.vertex_index, .{ .stage = .compute }).?);
    try testing.expectEqual(Violation.stage, violation(.discard, .{ .stage = .vertex }).?);
    try testing.expectEqual(Violation.stage, violation(.frag_coord, .{}).?);
    try testing.expectEqual(null, violation(.launch_id, .{ .stage = .closest_hit }));
    try testing.expectEqual(null, violation(.spec, .{ .stage = .fragment }));
    try testing.expectEqual(null, violation(.size_of, .{}));
}

test "wrong context and unknown names are reported" {
    var f: Fixture = undefined;
    try f.init(
        \\fn raw(p: *u32) -> u32 { @volatile_read(p) }
        \\fn null_ptr() -> *u8 { @ptr_from_int(u8, 0) }
        \\fn cpu() -> f32 { @frag_coord.x }
        \\fn cpu_index() -> u32 { @vertex_index }
        \\@gpu_kernel(workgroup: 64)
        \\fn k() { let v: u32 = @vertex_index; }
        \\@gpu_vertex
        \\fn vs() -> vec4<f32> { @discard(); }
        \\fn post(x: u32) -> u32 { @old(x) }
        \\fn unknown() { @frobnicate(1); }
        \\fn forms() -> u32 { @trap; }
        \\fn parens() -> u32 { @sample_index() }
        \\fn arity() -> bool { @any() }
    );
    defer f.deinit();
    try f.expectDiags(&.{
        .{ .E1202, "@volatile_read" }, .{ .E1202, "@ptr_from_int" }, .{ .E1005, "@frag_coord" }, .{ .E1005, "@vertex_index" },
        .{ .E1005, "@vertex_index" },  .{ .E1005, "@discard" },      .{ null, "@old" },          .{ null, "@frobnicate" },
        .{ null, "@trap" },            .{ null, "@sample_index" },   .{ null, "@any" },
    });
}

test "SIMD and bit builtin signatures" {
    var f: Fixture = undefined;
    try f.init(
        \\fn simd(a: vec4<f32>, b: vec4<f32>, i: vec4<u32>) -> f32 {
        \\    let zero: vec4<f32> = @splat(4, 0.0);
        \\    let m = a < b;
        \\    let pick: vec4<f32> = @select(m, a, zero);
        \\    let swapped = @select(m, @splat(4, -(1.0)), b);
        \\    let swapped_ty: vec4<f32> = swapped;
        \\    let hits: usize = @count(m);
        \\    let some: bool = @any(m) || @all(m & (b > zero));
        \\    let bits: u32 = @reduce_and(i) | @reduce_or(i);
        \\    let any_lane: bool = @reduce_or(m);
        \\    let fused: vec4<f32> = @fma(a, b, pick);
        \\    let s: f64 = @fma(1.0, 2.0, 3.0);
        \\    let ones = @splat(8, 1u8);
        \\    @reduce_add(fused) + @reduce_max(a)
        \\}
        \\fn ints(x: u8, y: u32) -> u32 {
        \\    let w: u8 = @add_wrap(x, 200) + @mul_sat(3, x);
        \\    let z = @sub_wrap(1, 2);
        \\    let c: u32 = @clz(y) + @popcount(y) + @bswap(y) + @bit_reverse(y);
        \\    if @likely(c > 0) && !@unlikely(w == 0) { @ctz(y) } else { @trap("no bits") }
        \\}
        \\fn casts(x: u32) -> f32 { @bit_cast(f32, x) }
        \\fn zeroed() -> (u32, f64) { @zero((u32, f64)) }
        \\fn never() -> u32 { @unreachable() }
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    for ([_][]const u8{ "simd", "ints", "casts", "zeroed", "never" }) |name| _ = try f.func(name);
    try f.expectDump("casts",
        \\fn casts(l0 x: u32) -> f32 {
        \\b0:
        \\  %0: type = type f32
        \\  %1: u32 = local l0
        \\  %2: u32 = load %1
        \\  %3: f32 = builtin #51, [%0, %2]
        \\  ret %3
        \\}
        \\
    );
}

test "SIMD, bit and unsafe argument errors" {
    var f: Fixture = undefined;
    try f.init(
        \\fn bad(v: vec4<f32>, m: mask<4>, x: u12, s: str, p: *const u32, n: usize) {
        \\    let a = @any(v);
        \\    let b = @splat(65, 1.0);
        \\    let c = @reduce_add(m);
        \\    let d = @bswap(x);
        \\    let e = @zero(str);
        \\    let g = @bit_cast(u32, 1u64);
        \\    let h = @bit_cast(bool, 1u8);
        \\    let i = @splat(n, 1.0);
        \\    let j = @fma(1, 2, 3);
        \\    let k = @select(m, s, s);
        \\}
        \\fn unsafe_ops(p: *const u32, q: *u32) {
        \\    @volatile_write(p, 1);
        \\    @volatile_write(q, true);
        \\    let r: u32 = @volatile_read(q);
        \\    let o = @ptr_add(q, 1);
        \\    let a: usize = @int_from_ptr(@ptr_add(q, 1));
        \\    let not_ptr = @int_from_ptr(5);
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{
        .{ .E0310, "v" },               .{ .E0303, "65" },              .{ .E0310, "m" },
        .{ .E0310, "x" },               .{ .E0329, "str" },             .{ .E0310, "1u64" },
        .{ .E1202, "@bit_cast" },       .{ .E0801, "n" },               .{ .E0310, "1" },
        .{ .E0310, "s" },               .{ .E1202, "@volatile_write" }, .{ .E0310, "p" },
        .{ .E1202, "@volatile_write" }, .{ .E0310, "true" },            .{ .E1202, "@volatile_read" },
        .{ .E1202, "@ptr_add" },        .{ .E1202, "@ptr_add" },        .{ .E0310, "5" },
    });
}

test "GPU builtin signatures in their stages" {
    var f: Fixture = undefined;
    try f.init(
        \\@gpu_kernel(workgroup: 64)
        \\fn ids() {
        \\    let g: vec3<u32> = @global_invocation_id;
        \\    let l: vec3<u32> = @local_invocation_id + @workgroup_id * @num_workgroups;
        \\    @workgroup_barrier();
        \\}
        \\@gpu_vertex
        \\fn vs() -> u32 { @vertex_index + @instance_index + @spec("bias", 0u32) }
        \\@gpu_fragment
        \\fn fs(x: f32, uv: vec2<f32>) -> vec4<f32> {
        \\    if !@front_facing { @discard(); }
        \\    let d: f32 = @dpdx(x) + @dpdy(x) + @fwidth(x) + @sample_index as f32;
        \\    let e: vec2<f32> = @fwidth(uv);
        \\    @frag_coord
        \\}
        \\@gpu_ray_gen
        \\fn rg() -> vec3<u32> { @launch_id + @launch_size }
        \\@gpu_fragment
        \\fn fs_bad(i: u32) -> f32 { @dpdx(i) }
    );
    defer f.deinit();
    try f.expectDiags(&.{.{ .E0310, "i" }});
    for ([_][]const u8{ "ids", "vs", "fs", "rg" }) |name| _ = try f.func(name);
}

test "a builtin typed by a later task names it from its rule's arm" {
    var f: Fixture = undefined;
    try f.init(
        \\fn later() -> usize { @vector_width(u8) }
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    try testing.expectEqual(Rule.vector_width, info(.vector_width).rule);
    try testing.expect(std.mem.indexOf(u8, f.bodies.unsupported.?.what, "T129") != null);
}

test "formatting intrinsics: comptime format string; the rest waits for T112" {
    var f: Fixture = undefined;
    try f.init(
        \\const GREETING = "hi {}";
        \\fn dynamic(s: str) { print(s, 1); }
        \\fn few() { eprint(); }
        \\fn ok(x: u32) { print(GREETING, x); }
    );
    defer f.deinit();
    try f.expectDiags(&.{ .{ .E0801, "s" }, .{ null, "eprint" } });
    try testing.expect(std.mem.indexOf(u8, f.bodies.unsupported.?.what, "T112") != null);
}
