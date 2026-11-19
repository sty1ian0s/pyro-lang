//! Builtins in expression scope whose result type is built from their
//! arguments: checked arithmetic (§6.4.2) and `@enum_from_int` (§7.4,
//! §4.9.2), both returning `Option`, and the prelude `vec` constructors
//! `vec2(x, y)`, `vec3(x, y, z)` and `vec4(x, y, z, w)` (§4.3.1), which
//! infer the lane type from their arguments.
//!
//! The wrapping and saturating builtins share the `int_binary` rule in
//! `builtins.zig`; the two `Option` rules are its arms here.

const std = @import("std");
const Ast = @import("../ast/Ast.zig");
const tir = @import("../tir/tir.zig");
const Types = @import("types.zig");
const convert = @import("convert.zig");
const emit_tir = @import("emit_tir.zig");
const builtins = @import("builtins.zig");

const Node = Ast.Node;
const TypeId = Types.TypeId;
const Checker = emit_tir.Checker;
const Typed = emit_tir.Typed;
const Error = emit_tir.Error;
const Args = builtins.Args;

/// `@add_checked`, `@sub_checked`, `@mul_checked`, `@shl_checked`:
/// `(I, I) -> Option<I>`, `I` an integer type; `.none` on overflow in
/// every build (§6.4.2). An expected `Option<I>` types constant operands.
pub fn checked(a: *Args, expected: TypeId) Error!Typed {
    const c = a.c;
    const want = if (expected == .none or expected == .err) .none else convert.optionPayload(c.types, expected) orelse .none;
    const ty = try a.common(2, want);
    if (!builtins.isInt(c, c.underlying(ty))) return a.wrong(0, "an integer", ty);
    return a.finish(try c.items.optionOf(ty));
}

/// `@enum_from_int(E, x) -> Option<E>` (§7.4): the variant of
/// payload-free enum `E` whose discriminant is integer `x`, if any.
pub fn enumFromInt(a: *Args) Error!Typed {
    const c = a.c;
    const e = try a.typeArg(0);
    const x = try a.value(1, .none);
    if (e == .err) return a.finish(.err);
    const decl = c.items.enumOf(e);
    if (decl == null or decl.?.has_payload) return a.wrong(0, "an enum without payloads", e);
    if (!builtins.isInt(c, c.underlying(x.ty))) return a.wrong(1, "an integer", x.ty);
    return a.finish(try c.items.optionOf(e));
}

/// The call `n` of prelude function `name` if it is a `vec` constructor
/// (§4.3.1); null otherwise. The lane type is the first typed argument's,
/// else the lane type of an expected `vec` of that length, else the first
/// constant's default type.
pub fn vecCtor(c: *Checker, n: Node.Index, name: []const u8, expected: TypeId) Error!?Typed {
    const lanes: u32 = if (std.mem.eql(u8, name, "vec2")) 2 else if (std.mem.eql(u8, name, "vec3")) 3 else if (std.mem.eql(u8, name, "vec4")) 4 else return null;
    const d = c.ast.data(n).call;
    if (d.args.len != lanes) {
        try c.report(d.callee, null, "`{s}` takes {d} arguments, found {d}", .{ name, lanes, d.args.len });
        return .err;
    }
    const want = if (expected == .none or expected == .err) expected else convert.optionPayload(c.types, expected) orelse expected;
    const elem: TypeId = if (want == .none or want == .err) .none else switch (c.types.get(want)) {
        .vec => |v| if (v.len == lanes) v.elem else .none,
        else => .none,
    };
    // `b` names no builtin: the arguments build an aggregate, never a `builtin` instruction.
    var a: Args = .{ .c = c, .at = d.callee, .name = name, .b = .splat, .ctx = .{}, .nodes = d.args, .refs = try c.arena.alloc(tir.Ref, lanes) };
    @memset(a.refs, .none);
    const ty = try a.common(lanes, elem);
    if (ty == .err) return try a.finish(.err);
    if (!builtins.vecElem(c, ty)) return try a.wrong(0, "a `vec` element type (integer, `f32`, `f64` or `bool`)", ty);
    if (a.diverges) return .never;
    const vt = try c.types.intern(.{ .vec = .{ .len = lanes, .elem = ty } });
    return .{ .ty = vt, .ref = try c.emit(vt, .{ .aggregate = .{ .elems = a.refs } }) };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const Fixture = emit_tir.Fixture;

test "@enum_from_int gives Option<E>; checked arithmetic gives Option<I>" {
    var f: Fixture = undefined;
    try f.init(
        \\enum Opcode: u8 { nop = 0, load = 1, store = 2, halt = 0xFF }
        \\fn decode(b: u8) -> Option<Opcode> { @enum_from_int(Opcode, b) }
        \\fn three() -> Option<Opcode> { @enum_from_int(Opcode, 3) }
        \\fn add(x: u8) -> Option<u8> { @add_checked(x, 1) }
        \\fn ops(x: i32, y: i32) {
        \\    let s: Option<i32> = @sub_checked(x, y);
        \\    let m = @mul_checked(x, 2);
        \\    let mt: Option<i32> = m;
        \\    let k: Option<u16> = @shl_checked(1, 3);
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    for ([_][]const u8{ "decode", "three", "add", "ops" }) |name| _ = try f.func(name);
    try f.expectDump("add",
        \\fn add(l0 x: u8) -> Option<u8> {
        \\b0:
        \\  %0: u8 = local l0
        \\  %1: u8 = load %0
        \\  %2: u8 = int 1
        \\  %3: Option<u8> = builtin #42, [%1, %2]
        \\  ret %3
        \\}
        \\
    );
}

test "@enum_from_int and checked arithmetic argument errors" {
    var f: Fixture = undefined;
    try f.init(
        \\enum Shape { circle(f32), empty }
        \\struct P { x: u8 }
        \\fn bad(x: f32, b: bool) {
        \\    let s = @enum_from_int(Shape, 0);
        \\    let p = @enum_from_int(P, 0);
        \\    let q = @enum_from_int(Order, x);
        \\    let c = @add_checked(x, 1.0);
        \\    let d = @mul_checked(b, b);
        \\    let w: u8 = @add_checked(1u8, 2);
        \\}
        \\enum Order { lt, eq, gt }
    );
    defer f.deinit();
    try f.expectDiags(&.{
        .{ .E0310, "Shape" }, .{ .E0310, "P" }, .{ .E0310, "x" },
        .{ .E0310, "x" },     .{ .E0310, "b" }, .{ .E0310, "@add_checked" },
    });
}

test "vec2/vec3/vec4 infer the lane type" {
    var f: Fixture = undefined;
    try f.init(
        \\fn ctors(x: u32, y: f32) {
        \\    let a: vec3<u32> = vec3(x, 1, 1);
        \\    let b: vec2<f32> = vec2(1.0, y);
        \\    let c = vec4(1.0, 2.0, 3.0, 4.0);
        \\    let ct: vec4<f64> = c;
        \\    let d: vec3<f32> = vec3(0.0, 0.0, 0.0);
        \\    let e = vec2(true, false);
        \\    let et: vec2<bool> = e;
        \\    let o: Option<vec2<u8>> = vec2(1, 2);
        \\}
        \\fn pair(x: u16) -> vec2<u16> { vec2(x, x) }
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    _ = try f.func("ctors");
    try f.expectDump("pair",
        \\fn pair(l0 x: u16) -> vec<2, u16> {
        \\b0:
        \\  %0: u16 = local l0
        \\  %1: u16 = load %0
        \\  %2: u16 = local l0
        \\  %3: u16 = load %2
        \\  %4: vec<2, u16> = aggregate [%1, %3]
        \\  ret %4
        \\}
        \\
    );
}

test "vec constructor errors" {
    var f: Fixture = undefined;
    try f.init(
        \\fn bad(s: str, x: u8, y: f32) {
        \\    let a = vec3(1.0, 2.0);
        \\    let b = vec2(s, s);
        \\    let c = vec2(x, y);
        \\    let d: vec2<u12> = vec2(1, 2);
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{ .{ null, "vec3" }, .{ .E0310, "s" }, .{ .E0310, "y" }, .{ .E0310, "1" } });
}
