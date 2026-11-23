//! Text dump of a TIR `Func`, for golden tests and `--dump-tir`.
//!
//! ```
//! fn area(l0 s: Shape) -> f32 {
//!   l1 mut t: f32
//! b0:
//!   %0: Shape = local l0
//!   %1: u8 = enum_tag %0
//!   switch_br %1, b3, [0: b1, 1: b2]
//! b4(%9: f32):
//!   ret %9
//! }
//! ```
//!
//! - The header lists the parameters, then one line per other local
//!   (`mut`/`move` from `LocalKind`; temporaries have no name).
//! - Block parameters are printed in the block label, not as instructions.
//! - An instruction is `%N: T = op operands` when it yields a value, else
//!   `op operands`; `scope_begin` and `nursery_begin` print `%N = op` because
//!   later markers refer to them. Operands follow `Data` field order: `%N`
//!   (or `_` when absent), `bN`, `lN`, `@N` function, `gN` global, `#N`
//!   builtin, `$N` comptime value, a type, a quoted string, a number, `[...]`
//!   for a list. `int` prints signed or unsigned by its type (a distinct type
//!   by its underlying type; untyped constants never reach TIR), `float` as f64.
//!
//! The output depends only on the function and the type table's spellings.

const std = @import("std");
const tir = @import("tir.zig");
const Types = @import("../sema/types.zig");
const Writer = std.Io.Writer;

const Ref = tir.Ref;
const Func = tir.Func;

/// Writes function `f`, named `name`, followed by a newline.
pub fn dump(f: *const Func, types: *Types, name: []const u8, w: *Writer) Writer.Error!void {
    try w.print("fn {s}(", .{name});
    for (0..f.param_count) |i| {
        if (i > 0) try w.writeAll(", ");
        try local(f, types, .from(i), w);
    }
    try w.writeAll(") -> ");
    try types.print(w, f.ret, .{});
    try w.writeAll(" {\n");
    for (f.param_count..f.locals.len) |i| {
        try w.writeAll("  ");
        try local(f, types, .from(i), w);
        try w.writeByte('\n');
    }
    for (0..f.blocks.len) |bi| {
        const insts = f.blockInsts(.from(bi));
        var n_params: usize = 0;
        while (n_params < insts.len and f.op(insts[n_params]) == .block_param) n_params += 1;
        try w.print("b{d}", .{bi});
        if (n_params > 0) {
            try w.writeByte('(');
            for (insts[0..n_params], 0..) |p, i| {
                if (i > 0) try w.writeAll(", ");
                try w.print("%{d}: ", .{p.int()});
                try types.print(w, f.typeOf(p), .{});
            }
            try w.writeByte(')');
        }
        try w.writeAll(":\n");
        for (insts[n_params..]) |r| try inst(f, types, r, w);
    }
    try w.writeAll("}\n");
}

fn local(f: *const Func, types: *Types, l: tir.Local, w: *Writer) Writer.Error!void {
    const info = f.local(l);
    try w.print("l{d} ", .{l.int()});
    if (info.workgroup) try w.writeAll("workgroup ");
    switch (info.kind) {
        .let_mut, .param_mut => try w.writeAll("mut "),
        .param_move => try w.writeAll("move "),
        .let, .param, .temp => {},
    }
    if (info.name.unwrap()) |n| try w.writeAll(types.strings.get(n));
    try w.writeAll(": ");
    try types.print(w, info.ty, .{});
}

fn inst(f: *const Func, types: *Types, r: Ref, w: *Writer) Writer.Error!void {
    const ty = f.typeOf(r);
    const op = f.op(r);
    try w.writeAll("  ");
    if (ty != .void) {
        try w.print("%{d}: ", .{r.int()});
        try types.print(w, ty, .{});
        try w.writeAll(" = ");
    } else if (op == .scope_begin or op == .nursery_begin) {
        try w.print("%{d} = ", .{r.int()});
    }
    try w.writeAll(@tagName(op));
    switch (f.data(r)) {
        .int => |p| if (isSigned(types, ty))
            try w.print(" {d}", .{@as(i64, @bitCast(p.value))})
        else
            try w.print(" {d}", .{p.value}),
        .float => |p| try w.print(" {d}", .{@as(f64, @bitCast(p.bits))}),
        inline else => |p| {
            const info = @typeInfo(@TypeOf(p)).@"struct";
            inline for (info.field_names, info.field_types, 0..) |fname, F, i| {
                try w.writeAll(if (i == 0) " " else ", ");
                try operand(types, w, F, @field(p, fname));
            }
        },
    }
    try w.writeByte('\n');
}

/// Whether `int` constants of `ty` print signed; distinct types (§4.7) use
/// their underlying type.
fn isSigned(types: *Types, ty: tir.TypeId) bool {
    return switch (types.get(ty)) {
        .int => |i| i.signedness == .signed,
        .simple => |s| s == .isize,
        .nominal => |n| n.kind == .distinct and isSigned(types, n.underlying),
        else => false,
    };
}

fn operand(types: *Types, w: *Writer, comptime F: type, v: F) Writer.Error!void {
    switch (F) {
        Ref => try w.print("%{d}", .{v.int()}),
        ?Ref => if (v) |x| try w.print("%{d}", .{x.int()}) else try w.writeByte('_'),
        tir.Block => try w.print("b{d}", .{v.int()}),
        tir.Local => try w.print("l{d}", .{v.int()}),
        tir.FnId => try w.print("@{d}", .{v.int()}),
        tir.GlobalId => try w.print("g{d}", .{v.int()}),
        tir.BuiltinId => try w.print("#{d}", .{v.int()}),
        tir.ComptimeId => try w.print("${d}", .{v.int()}),
        tir.StrId => try w.print("\"{f}\"", .{std.zig.fmtString(types.strings.get(v))}),
        tir.TypeId => try types.print(w, v, .{}),
        tir.LaunchTarget => try w.writeAll(@tagName(v)),
        u32 => try w.print("{d}", .{v}),
        []const Ref, []const u32, []const tir.Case => {
            try w.writeByte('[');
            for (v, 0..) |x, i| {
                if (i > 0) try w.writeAll(", ");
                switch (F) {
                    []const Ref => try w.print("%{d}", .{x.int()}),
                    []const u32 => try w.print("{d}", .{x}),
                    else => try w.print("{d}: b{d}", .{ x.key(), x.block.int() }),
                }
            }
            try w.writeByte(']');
        },
        else => @compileError("no dump format for " ++ @typeName(F)),
    }
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const Allocator = std.mem.Allocator;
const Builder = @import("builder.zig").Builder;
const Interner = @import("../base/Interner.zig");
const Arena = @import("../base/Arena.zig");
const Pool = @import("../base/Pool.zig");
const TypeId = tir.TypeId;
const StrId = tir.StrId;

/// Names and types shared by the hand-built functions.
const Ctx = struct {
    vec2: TypeId,
    mut_vec2: TypeId,
    shape: TypeId,
    /// `type Meters = distinct i32;`
    meters: TypeId,
    /// `fn(i32)`
    fn_i32: TypeId,
    /// `fn(Meters) -> Meters`
    fn_meters: TypeId,
    a: StrId,
    b: StrId,
    n: StrId,
    s: StrId,
    i: StrId,
    v: StrId,
    fp: StrId,
};

const Fixture = struct {
    strings: Interner,
    types: Types,
    ctx: Ctx,

    fn init(fx: *Fixture) !void {
        fx.strings = .init(testing.allocator, testing.io);
        fx.types = try .init(testing.allocator, testing.io, &fx.strings);
        const pkg: Types.Package = .{ .name = try fx.strings.intern("app"), .line = .{ .major = 1 } };
        const vec2 = try fx.types.intern(.{ .nominal = .{ .decl = .{ .package = pkg, .index = 0 }, .kind = .@"struct", .name = try fx.strings.intern("Vec2") } });
        const meters = try fx.types.intern(.{ .nominal = .{ .decl = .{ .package = pkg, .index = 2 }, .kind = .distinct, .name = try fx.strings.intern("Meters"), .underlying = i32_ } });
        fx.ctx = .{
            .vec2 = vec2,
            .mut_vec2 = try fx.types.intern(.{ .mut_view = .{ .elem = vec2 } }),
            .shape = try fx.types.intern(.{ .nominal = .{ .decl = .{ .package = pkg, .index = 1 }, .kind = .@"enum", .name = try fx.strings.intern("Shape") } }),
            .a = try fx.strings.intern("a"),
            .b = try fx.strings.intern("b"),
            .n = try fx.strings.intern("n"),
            .s = try fx.strings.intern("s"),
            .i = try fx.strings.intern("i"),
            .v = try fx.strings.intern("v"),
            .fp = try fx.strings.intern("fp"),
            .meters = meters,
            .fn_i32 = try fx.types.intern(.{ .fn_ptr = .{ .params = &.{.{ .type = i32_ }}, .ret = .void } }),
            .fn_meters = try fx.types.intern(.{ .fn_ptr = .{ .params = &.{.{ .type = meters }}, .ret = meters } }),
        };
    }

    fn deinit(fx: *Fixture) void {
        fx.types.deinit();
        fx.strings.deinit();
    }
};

const i32_ = TypeId.int(.signed, 32);
const u64_ = TypeId.int(.unsigned, 64);
const u8_ = TypeId.int(.unsigned, 8);

fn place(b: *Builder, l: tir.Local, ty: TypeId) !Ref {
    return b.add(ty, .{ .local = .{ .local = l } });
}

fn loadLocal(b: *Builder, l: tir.Local, ty: TypeId) !Ref {
    return b.add(ty, .{ .load = .{ .place = try place(b, l, ty) } });
}

/// `fn mad(a: i32, b: i32) -> i32 { return a * b + -1; }`
fn buildMad(arena: Allocator, c: Ctx) !Func {
    var b: Builder = .init(arena, i32_);
    const pa = try b.addParam(c.a, i32_, .param);
    const pb = try b.addParam(c.b, i32_, .param);
    b.setBlock(try b.addBlock());
    const m = try b.add(i32_, .{ .mul = .{ .lhs = try loadLocal(&b, pa, i32_), .rhs = try loadLocal(&b, pb, i32_) } });
    const k = try b.add(i32_, .{ .int = .{ .value = @bitCast(@as(i64, -1)) } });
    _ = try b.add(.void, .{ .ret = .{ .value = try b.add(i32_, .{ .add = .{ .lhs = m, .rhs = k } }) } });
    return b.finish();
}

const mad_golden =
    \\fn mad(l0 a: i32, l1 b: i32) -> i32 {
    \\b0:
    \\  %0: i32 = local l0
    \\  %1: i32 = load %0
    \\  %2: i32 = local l1
    \\  %3: i32 = load %2
    \\  %4: i32 = mul %1, %3
    \\  %5: i32 = int -1
    \\  %6: i32 = add %4, %5
    \\  ret %6
    \\}
    \\
;

/// `fn max(a: f64, b: f64) -> f64 { if a > b { a } else { b } }`
fn buildMax(arena: Allocator, c: Ctx) !Func {
    var b: Builder = .init(arena, .f64);
    const pa = try b.addParam(c.a, .f64, .param);
    const pb = try b.addParam(c.b, .f64, .param);
    const entry = try b.addBlock();
    const then = try b.addBlock();
    const els = try b.addBlock();
    const join = try b.addBlock();
    const result = try b.addBlockParam(join, .f64);
    b.setBlock(entry);
    const x = try loadLocal(&b, pa, .f64);
    const y = try loadLocal(&b, pb, .f64);
    const cond = try b.add(.bool, .{ .gt = .{ .lhs = x, .rhs = y } });
    _ = try b.add(.void, .{ .cond_br = .{ .cond = cond, .then = then, .@"else" = els } });
    b.setBlock(then);
    _ = try b.add(.void, .{ .br = .{ .target = join, .args = &.{x} } });
    b.setBlock(els);
    _ = try b.add(.void, .{ .br = .{ .target = join, .args = &.{y} } });
    b.setBlock(join);
    _ = try b.add(.void, .{ .ret = .{ .value = result } });
    return b.finish();
}

const max_golden =
    \\fn max(l0 a: f64, l1 b: f64) -> f64 {
    \\b0:
    \\  %1: f64 = local l0
    \\  %2: f64 = load %1
    \\  %3: f64 = local l1
    \\  %4: f64 = load %3
    \\  %5: bool = gt %2, %4
    \\  cond_br %5, b1, b2
    \\b1:
    \\  br b3, [%2]
    \\b2:
    \\  br b3, [%4]
    \\b3(%0: f64):
    \\  ret %0
    \\}
    \\
;

/// ```
/// fn sum(n: u64) -> u64 {
///     let mut s: u64 = 0; let mut i: u64 = 0;
///     loop { if i >= n { break s; } s += i; i += 1; }
/// }
/// ```
fn buildSum(arena: Allocator, c: Ctx) !Func {
    var b: Builder = .init(arena, u64_);
    const n = try b.addParam(c.n, u64_, .param);
    const s = try b.addLocal(.{ .ty = u64_, .name = c.s, .kind = .let_mut });
    const i = try b.addLocal(.{ .ty = u64_, .name = c.i, .kind = .let_mut });
    const entry = try b.addBlock();
    const head = try b.addBlock();
    const brk = try b.addBlock();
    const body = try b.addBlock();
    const exit = try b.addBlock();
    const value = try b.addBlockParam(exit, u64_);

    b.setBlock(entry);
    for ([_]tir.Local{ s, i }) |l| {
        const p = try place(&b, l, u64_);
        _ = try b.add(.void, .{ .store = .{ .place = p, .value = try b.add(u64_, .{ .int = .{ .value = 0 } }) } });
    }
    _ = try b.add(.void, .{ .br = .{ .target = head, .args = &.{} } });

    b.setBlock(head);
    const done = try b.add(.bool, .{ .ge = .{ .lhs = try loadLocal(&b, i, u64_), .rhs = try loadLocal(&b, n, u64_) } });
    _ = try b.add(.void, .{ .cond_br = .{ .cond = done, .then = brk, .@"else" = body } });

    b.setBlock(brk);
    _ = try b.add(.void, .{ .br = .{ .target = exit, .args = &.{try loadLocal(&b, s, u64_)} } });

    b.setBlock(body);
    // s += i: the place first, then the value (§6.1).
    const ps = try place(&b, s, u64_);
    const sum = try b.add(u64_, .{ .add = .{ .lhs = try loadLocal(&b, s, u64_), .rhs = try loadLocal(&b, i, u64_) } });
    _ = try b.add(.void, .{ .store = .{ .place = ps, .value = sum } });
    const pi = try place(&b, i, u64_);
    const one = try b.add(u64_, .{ .int = .{ .value = 1 } });
    const inc = try b.add(u64_, .{ .add = .{ .lhs = try loadLocal(&b, i, u64_), .rhs = one } });
    _ = try b.add(.void, .{ .store = .{ .place = pi, .value = inc } });
    _ = try b.add(.void, .{ .br = .{ .target = head, .args = &.{} } });

    b.setBlock(exit);
    _ = try b.add(.void, .{ .ret = .{ .value = value } });
    return b.finish();
}

const sum_golden =
    \\fn sum(l0 n: u64) -> u64 {
    \\  l1 mut s: u64
    \\  l2 mut i: u64
    \\b0:
    \\  %1: u64 = local l1
    \\  %2: u64 = int 0
    \\  store %1, %2
    \\  %4: u64 = local l2
    \\  %5: u64 = int 0
    \\  store %4, %5
    \\  br b1, []
    \\b1:
    \\  %8: u64 = local l2
    \\  %9: u64 = load %8
    \\  %10: u64 = local l0
    \\  %11: u64 = load %10
    \\  %12: bool = ge %9, %11
    \\  cond_br %12, b2, b3
    \\b2:
    \\  %14: u64 = local l1
    \\  %15: u64 = load %14
    \\  br b4, [%15]
    \\b3:
    \\  %17: u64 = local l1
    \\  %18: u64 = local l1
    \\  %19: u64 = load %18
    \\  %20: u64 = local l2
    \\  %21: u64 = load %20
    \\  %22: u64 = add %19, %21
    \\  store %17, %22
    \\  %24: u64 = local l2
    \\  %25: u64 = int 1
    \\  %26: u64 = local l2
    \\  %27: u64 = load %26
    \\  %28: u64 = add %27, %25
    \\  store %24, %28
    \\  br b1, []
    \\b4(%0: u64):
    \\  ret %0
    \\}
    \\
;

/// `fn nudge(mut v: Vec2) { defer log(v.x); scale(mut v, 2.5); }` with
/// `scale` = @1 and `log` = @2.
fn buildNudge(arena: Allocator, c: Ctx) !Func {
    var b: Builder = .init(arena, .void);
    const v = try b.addParam(c.v, c.vec2, .param_mut);
    const entry = try b.addBlock();
    const defer_body = try b.addBlock();

    b.setBlock(entry);
    const scope = try b.add(.void, .{ .scope_begin = .{} });
    _ = try b.add(.void, .{ .@"defer" = .{ .scope = scope, .body = defer_body } });
    const view = try b.add(c.mut_vec2, .{ .view_mut = .{ .place = try place(&b, v, c.vec2) } });
    const k = try b.add(.f32, .{ .float = .{ .bits = @bitCast(@as(f64, 2.5)) } });
    _ = try b.add(.void, .{ .call = .{ .callee = .from(1), .args = &.{ view, k } } });
    _ = try b.add(.void, .{ .scope_end = .{ .scope = scope } });
    _ = try b.add(.void, .{ .ret = .{ .value = null } });

    b.setBlock(defer_body);
    const x = try b.add(.f32, .{ .field = .{ .base = try place(&b, v, c.vec2), .index = 0 } });
    _ = try b.add(.void, .{ .call = .{ .callee = .from(2), .args = &.{try b.add(.f32, .{ .load = .{ .place = x } })} } });
    _ = try b.add(.void, .{ .defer_end = .{} });
    return b.finish();
}

const nudge_golden =
    \\fn nudge(l0 mut v: Vec2) -> void {
    \\b0:
    \\  %0 = scope_begin
    \\  defer %0, b1
    \\  %2: Vec2 = local l0
    \\  %3: mut Vec2 = view_mut %2
    \\  %4: f32 = float 2.5
    \\  call @1, [%3, %4]
    \\  scope_end %0
    \\  ret _
    \\b1:
    \\  %8: Vec2 = local l0
    \\  %9: f32 = field %8, 0
    \\  %10: f32 = load %9
    \\  call @2, [%10]
    \\  defer_end
    \\}
    \\
;

/// `fn area(s: Shape) -> f32 { match s { .circle(r) => r * r, .square(w) => w * w } }`
fn buildArea(arena: Allocator, c: Ctx) !Func {
    var b: Builder = .init(arena, .f32);
    const s = try b.addParam(c.s, c.shape, .param);
    const entry = try b.addBlock();
    const arms = [_]tir.Block{ try b.addBlock(), try b.addBlock() };
    const no_match = try b.addBlock();
    const join = try b.addBlock();
    const result = try b.addBlockParam(join, .f32);

    b.setBlock(entry);
    const subject = try place(&b, s, c.shape);
    const tag = try b.add(u8_, .{ .enum_tag = .{ .place = subject } });
    _ = try b.add(.void, .{ .switch_br = .{ .value = tag, .default = no_match, .cases = &.{ .init(0, arms[0]), .init(1, arms[1]) } } });
    for (arms, 0..) |arm, variant| {
        b.setBlock(arm);
        const payload = try b.add(.f32, .{ .variant_field = .{ .base = subject, .variant = @intCast(variant), .index = 0 } });
        const x = try b.add(.f32, .{ .load = .{ .place = payload } });
        _ = try b.add(.void, .{ .br = .{ .target = join, .args = &.{try b.add(.f32, .{ .mul = .{ .lhs = x, .rhs = x } })} } });
    }
    b.setBlock(no_match);
    _ = try b.add(.void, .{ .@"unreachable" = .{} });
    b.setBlock(join);
    _ = try b.add(.void, .{ .ret = .{ .value = result } });
    return b.finish();
}

const area_golden =
    \\fn area(l0 s: Shape) -> f32 {
    \\b0:
    \\  %1: Shape = local l0
    \\  %2: u8 = enum_tag %1
    \\  switch_br %2, b3, [0: b1, 1: b2]
    \\b1:
    \\  %4: f32 = variant_field %1, 0, 0
    \\  %5: f32 = load %4
    \\  %6: f32 = mul %5, %5
    \\  br b4, [%6]
    \\b2:
    \\  %8: f32 = variant_field %1, 1, 0
    \\  %9: f32 = load %8
    \\  %10: f32 = mul %9, %9
    \\  br b4, [%10]
    \\b3:
    \\  unreachable
    \\b4(%0: f32):
    \\  ret %0
    \\}
    \\
;

/// ```
/// fn crew(n: i32, fp: fn(i32)) {
///     nursery { defer log(n); spawn work(n); spawn fp(n); }
/// }
/// ```
/// with `work` = @1 and `log` = @2. The join comes before the body's defers.
fn buildCrew(arena: Allocator, c: Ctx) !Func {
    var b: Builder = .init(arena, .void);
    const n = try b.addParam(c.n, i32_, .param);
    const fp = try b.addParam(c.fp, c.fn_i32, .param);
    const entry = try b.addBlock();
    const defer_body = try b.addBlock();

    b.setBlock(entry);
    const scope = try b.add(.void, .{ .scope_begin = .{} });
    const nursery = try b.add(.void, .{ .nursery_begin = .{} });
    _ = try b.add(.void, .{ .@"defer" = .{ .scope = scope, .body = defer_body } });
    _ = try b.add(.void, .{ .spawn = .{ .nursery = nursery, .callee = .from(1), .args = &.{try loadLocal(&b, n, i32_)} } });
    const f = try loadLocal(&b, fp, c.fn_i32);
    _ = try b.add(.void, .{ .spawn_indirect = .{ .nursery = nursery, .callee = f, .args = &.{try loadLocal(&b, n, i32_)} } });
    _ = try b.add(.void, .{ .nursery_end = .{ .nursery = nursery } });
    _ = try b.add(.void, .{ .scope_end = .{ .scope = scope } });
    _ = try b.add(.void, .{ .ret = .{ .value = null } });

    b.setBlock(defer_body);
    _ = try b.add(.void, .{ .call = .{ .callee = .from(2), .args = &.{try loadLocal(&b, n, i32_)} } });
    _ = try b.add(.void, .{ .defer_end = .{} });
    return b.finish();
}

const crew_golden =
    \\fn crew(l0 n: i32, l1 fp: fn(i32)) -> void {
    \\b0:
    \\  %0 = scope_begin
    \\  %1 = nursery_begin
    \\  defer %0, b1
    \\  %3: i32 = local l0
    \\  %4: i32 = load %3
    \\  spawn %1, @1, [%4]
    \\  %6: fn(i32) = local l1
    \\  %7: fn(i32) = load %6
    \\  %8: i32 = local l0
    \\  %9: i32 = load %8
    \\  spawn_indirect %1, %7, [%9]
    \\  nursery_end %1
    \\  scope_end %0
    \\  ret _
    \\b1:
    \\  %14: i32 = local l0
    \\  %15: i32 = load %14
    \\  call @2, [%15]
    \\  defer_end
    \\}
    \\
;

/// `fn relay(fp: fn(Meters) -> Meters) -> Meters { return tail fp(-1); }`
/// (the untyped `-1` folded to `Meters`, a distinct `i32`).
fn buildRelay(arena: Allocator, c: Ctx) !Func {
    var b: Builder = .init(arena, c.meters);
    const fp = try b.addParam(c.fp, c.fn_meters, .param);
    b.setBlock(try b.addBlock());
    const f = try loadLocal(&b, fp, c.fn_meters);
    const k = try b.add(c.meters, .{ .int = .{ .value = @bitCast(@as(i64, -1)) } });
    _ = try b.add(.void, .{ .ret_tail_indirect = .{ .callee = f, .args = &.{k} } });
    return b.finish();
}

const relay_golden =
    \\fn relay(l0 fp: fn(Meters) -> Meters) -> Meters {
    \\b0:
    \\  %0: fn(Meters) -> Meters = local l0
    \\  %1: fn(Meters) -> Meters = load %0
    \\  %2: Meters = int -1
    \\  ret_tail_indirect %1, [%2]
    \\}
    \\
;

const Golden = struct {
    name: []const u8,
    build: *const fn (Allocator, Ctx) anyerror!Func,
    text: []const u8,
};

const goldens = [_]Golden{
    .{ .name = "mad", .build = buildMad, .text = mad_golden },
    .{ .name = "max", .build = buildMax, .text = max_golden },
    .{ .name = "sum", .build = buildSum, .text = sum_golden },
    .{ .name = "nudge", .build = buildNudge, .text = nudge_golden },
    .{ .name = "area", .build = buildArea, .text = area_golden },
    .{ .name = "crew", .build = buildCrew, .text = crew_golden },
    .{ .name = "relay", .build = buildRelay, .text = relay_golden },
};

fn dumpAlloc(gpa: Allocator, f: *const Func, types: *Types, name: []const u8) ![]u8 {
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    try dump(f, types, name, &out.writer);
    return out.toOwnedSlice();
}

test "hand-built TIR golden dumps: arith, if, loop, call+field+defer, enum match, nursery, indirect tail call" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    for (goldens) |g| {
        const f = try g.build(arena.allocator(), fx.ctx);
        const text = try dumpAlloc(testing.allocator, &f, &fx.types, g.name);
        defer testing.allocator.free(text);
        try testing.expectEqualStrings(g.text, text);
    }
}

test "builders run in parallel, each on its worker's arena" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var pool: Pool = undefined;
    try pool.init(testing.allocator, testing.io, 4);
    defer pool.deinit(testing.allocator);
    var arenas: Arena.PerThread = try .init(testing.allocator, pool.jobs());
    defer arenas.deinit(testing.allocator);

    const n = 64;
    var ok: [n]bool = @splat(false);
    const Job = struct { fx: *Fixture, arenas: Arena.PerThread, ok: *[n]bool };
    pool.run(n, Job{ .fx = &fx, .arenas = arenas, .ok = &ok }, struct {
        fn job(j: Job, worker: u32, i: usize) void {
            const g = goldens[i % goldens.len];
            const f = g.build(j.arenas.get(worker).allocator(), j.fx.ctx) catch return;
            const text = dumpAlloc(testing.allocator, &f, &j.fx.types, g.name) catch return;
            defer testing.allocator.free(text);
            j.ok[i] = std.mem.eql(u8, text, g.text);
        }
    }.job);
    for (ok) |x| try testing.expect(x);
}
