//! Comptime control flow and diagnostics (§8.5, §6.7.3).
//!
//! - `comptime if cond { A } else { B }` (`comptimeIf`): `cond` is
//!   evaluated by the comptime driver (`comptime_ctx.Ctx.eval`) and only
//!   the chosen branch is type-checked and emitted.
//! - `inline for x in E { body }` (`inlineFor`): `E` is a tuple literal
//!   (of types or values), a range with comptime bounds, or any comptime
//!   array, slice or tuple; the body is checked once per element with `x`
//!   bound to it, a type or a comptime value (`Mod.bound`,
//!   `Mod.bound_values`). Each copy evaluates its comptime contexts afresh
//!   (`Ctx.copy`). `break` leaves the unrolled sequence, `continue` goes on
//!   with the next copy. A range of more elements than the comptime budget
//!   (§8.6) is E0808.
//! - `@compile_error(msg)` (`compileDiag`, `evalBuiltin`): E0804 with
//!   `msg` when it is evaluated: when the interpreter reaches it in
//!   comptime code, or when runtime code containing it is compiled (an
//!   untaken `comptime if` branch is neither).
//! - `@compile_log(args...)`: W0801 wherever it is in the build; when
//!   evaluated it prints its arguments to `Ctx.log`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("../ast/Ast.zig");
const Types = @import("types.zig");
const convert = @import("convert.zig");
const items_mod = @import("items.zig");
const emit_tir = @import("emit_tir.zig");
const check_expr = @import("check_expr.zig");
const check_stmt = @import("check_stmt.zig");
const builtins = @import("builtins.zig");
const comptime_ctx = @import("comptime_ctx.zig");
const prelude = @import("../resolve/prelude.zig");
const tir = @import("../tir/tir.zig");
const interp_ctrl = @import("../comptime/interp_ctrl.zig");
const limits = @import("../comptime/limits.zig");
const Value = @import("../comptime/value.zig").Value;

const Node = Ast.Node;
const TypeId = Types.TypeId;
const Checker = emit_tir.Checker;
const Typed = emit_tir.Typed;
const Error = emit_tir.Error;

/// `comptime if` (§8.5): only the branch `cond` selects is checked.
pub fn comptimeIf(c: *Checker, n: Node.Index, expected: TypeId) Error!Typed {
    const inner = c.ast.data(n).comptime_if.@"if";
    // shortcut: inside comptime code the condition may read the code's own locals, which a separate evaluation cannot see; both branches are checked like a plain `if`.
    if (c.in_comptime) return check_stmt.ifExpr(c, inner, expected);
    const d = c.ast.data(inner).@"if";
    if (c.ast.kind(d.cond) == .let_cond) return c.unsupported(d.cond, "`comptime if let`");
    const cx = comptime_ctx.of(c.items) orelse return c.unsupported(n, "comptime evaluation without an evaluator");
    const v = try cx.eval(c.items, c.m, d.cond, .bool) orelse {
        c.failed = true; // reported, or recorded as unsupported
        return .err;
    };
    if (v.scalar.bits != 0) {
        if (d.@"else" != null) return check_expr.check(c, d.then, expected);
        const t = try check_expr.check(c, d.then, .void);
        return if (t.ty == .noreturn or t.ty == .err) t else .void_value;
    }
    return if (d.@"else") |e| check_expr.check(c, e, expected) else .void_value;
}

/// One element of an `inline for` sequence.
const Elem = union(enum) { type: TypeId, value: items_mod.Value };

/// `inline for x(, i)? in E { body }` (§6.7.3): the body unrolled once per
/// element of comptime-known `E`.
pub fn inlineFor(c: *Checker, n: Node.Index, _: TypeId) Error!Typed {
    const d = c.ast.data(n).for_inline;
    for ([_]?Node.Index{ d.pattern, d.pattern2 }) |p| if (p) |q| switch (c.ast.kind(q)) {
        .pat_bind, .pat_wildcard => {},
        else => return c.unsupported(q, "destructuring in `inline for`"),
    };
    const elems = try sequence(c, d.iter) orelse {
        c.failed = true;
        return .err;
    };
    if (elems.len == 0) return .void_value;
    const mod = &c.items.mods[c.m];
    defer for ([_]?Node.Index{ d.pattern, d.pattern2 }) |p| if (p) |q| {
        _ = mod.bound.remove(q);
        _ = mod.bound_values.remove(q);
    };
    const cx = comptime_ctx.of(c.items).?; // `sequence` needed it
    const outer = cx.copy;
    defer cx.copy = outer;
    const exit = try c.addBlock();
    var next = try c.addBlock();
    try c.br(next, .none);
    for (elems, 0..) |e, i| {
        c.setBlock(next);
        next = if (i + 1 < elems.len) try c.addBlock() else exit;
        cx.copy = cx.nextCopy();
        try bind(c, d.pattern, e);
        if (d.pattern2) |p| try bind(c, p, .{ .value = .{ .scalar = .{ .type = .usize, .bits = i } } });
        if (d.filter) |f| try @import("desugar_loops.zig").filter(c, f, next);
        try c.loops.append(c.arena, .{ .label = null, .is_loop = false, .head = next, .exit = exit, .expected = .none });
        const body = try check_expr.check(c, d.body, .void);
        _ = c.loops.pop();
        if (body.ty != .noreturn) {
            _ = try c.coerce(body, .void, check_stmt.valueNode(c.ast, d.body));
            try c.br(next, .none);
        }
    }
    c.setBlock(exit);
    return .void_value;
}

/// The elements of `inline for` iterable `n`; null after a diagnostic.
fn sequence(c: *Checker, n: Node.Index) Error!?[]const Elem {
    const cx = comptime_ctx.of(c.items) orelse {
        _ = c.unsupported(n, "comptime evaluation without an evaluator");
        return null;
    };
    switch (c.ast.data(n)) {
        .paren => |p| return sequence(c, p.inner),
        .tuple => |t| {
            const out = try c.arena.alloc(Elem, t.elems.len);
            for (t.elems, out) |e, *o| o.* = if (isType(c, e))
                .{ .type = try c.resolveType(e) }
            else
                .{ .value = try cx.eval(c.items, c.m, e, .none) orelse return null };
            return out;
        },
        .range => |r| {
            const lo_n = r.lo orelse return notSequence(c, n);
            const hi_n = r.hi orelse return notSequence(c, n);
            const lo = try cx.eval(c.items, c.m, lo_n, .none) orelse return null;
            if (lo != .scalar) return notSequence(c, n);
            const ty = lo.scalar.type;
            const hi = try cx.eval(c.items, c.m, hi_n, ty) orelse return null;
            const ptr_bits = c.items.options.ptr_bits;
            const info = convert.intInfo(c.types, ptr_bits, ty) orelse return notSequence(c, n);
            const a = intOf(info, lo.scalar.bits);
            const b = intOf(info, hi.scalar.bits) + @intFromBool(c.ast.tokens.items(.kind)[c.ast.mainToken(n)] == .dot_dot_eq);
            const len = @max(b - a, 0);
            if (len > limits.default_quota) {
                try c.report(n, .E0808, "`inline for` over {d} elements exceeds the comptime budget of {d}", .{ len, limits.default_quota });
                return null;
            }
            const out = try c.arena.alloc(Elem, @intCast(len));
            for (out, 0..) |*o, i| o.* = .{ .value = .{ .scalar = .{ .type = ty, .bits = @truncate(@as(u128, @bitCast(a + @as(i128, @intCast(i))))) } } };
            return out;
        },
        else => {},
    }
    const v = try cx.eval(c.items, c.m, n, .none) orelse return null;
    if (v != .computed) return notSequence(c, n);
    const whole = cx.value(v.computed.id);
    const vs: []const Value = switch (whole.data) {
        .aggregate, .slice => |vs| vs,
        .bytes => |bs| blk: {
            const out = try c.arena.alloc(Value, bs.len);
            for (out, bs) |*o, b| o.* = .{ .ty = .int(.unsigned, 8), .data = .{ .scalar = b } };
            break :blk out;
        },
        else => return notSequence(c, n),
    };
    const out = try c.arena.alloc(Elem, vs.len);
    for (vs, out) |e, *o| o.* = switch (e.data) {
        .type => |t| .{ .type = t },
        .scalar => |bits| .{ .value = .{ .scalar = .{ .type = e.ty, .bits = bits } } },
        else => blk: {
            try cx.table.append(cx.gpa, e);
            break :blk .{ .value = .{ .computed = .{ .type = e.ty, .id = .from(cx.table.items.len - 1) } } };
        },
    };
    return out;
}

fn intOf(info: convert.IntInfo, bits: u64) i128 {
    return if (info.signedness == .signed) @as(i64, @bitCast(bits)) else bits;
}

fn notSequence(c: *Checker, n: Node.Index) Error!?[]const Elem {
    try c.report(n, .E0801, "`inline for` needs a comptime array, slice, tuple or range", .{});
    return null;
}

/// Whether expression `n` names a type (`(u8, Vec3)` iterates over types).
fn isType(c: *Checker, n: Node.Index) bool {
    const a = c.ast;
    const base = switch (a.data(n)) {
        .array_type, .slice_type, .soa_array_type, .soa_slice_type, .ptr_type, .ptr_const_type, .mut_type, .fn_type, .type_type, .self_type => return true,
        .paren => |p| return isType(c, p.inner),
        .generic_inst => |g| g.base,
        .ident => n,
        else => return false,
    };
    const e = c.items.names.get(c.m, base) orelse return false;
    if (e.rest != 0) return false;
    return switch (e.res) {
        .local => |l| a.kind(l) == .generic_param or c.items.mods[c.m].bound.contains(l),
        .global => |g| switch (g) {
            .item => |ref| switch (c.items.im.graph.modules[ref.module].items[ref.item].kind) {
                .type_alias, .type_distinct, .@"struct", .@"enum" => true,
                else => false,
            },
            .prelude => |name| prelude.isIntTypeName(name) or for (prelude.entries) |en| {
                if (std.mem.eql(u8, en.name, name)) break en.kind == .type;
            } else false,
            else => false,
        },
    };
}

/// Binds `inline for` pattern `pat` to element `e` for one copy of the
/// body: a type, or a comptime value that runtime and comptime code read
/// (`check_expr.ident`).
fn bind(c: *Checker, pat: Node.Index, e: Elem) Error!void {
    if (c.ast.kind(pat) == .pat_wildcard) return;
    const mod = &c.items.mods[c.m];
    const a = c.items.arena.allocator();
    switch (e) {
        .type => |t| try mod.bound.put(a, pat, t),
        .value => |v| try mod.bound_values.put(a, pat, v),
    }
}

/// `@compile_error(msg)` and `@compile_log(args...)` (§8.5); `a` is the
/// call whose arity and context `builtins.zig` checked.
pub fn compileDiag(a: *builtins.Args) Error!Typed {
    const c = a.c;
    if (a.b == .compile_log) {
        for (0..a.nodes.len) |i| _ = try a.value(i, .none);
        try c.report(a.at, .W0801, "`@compile_log` is left in the build", .{});
        return a.finish(.void);
    }
    _ = try a.as(0, .str);
    // Runtime code containing it is being compiled: it is evaluated now.
    // In comptime code the interpreter reports it when it runs (`evalBuiltin`).
    if (!c.in_comptime and a.ok) {
        const cx = comptime_ctx.of(c.items) orelse return c.unsupported(a.at, "comptime evaluation without an evaluator");
        const msg = try cx.eval(c.items, c.m, a.nodes[0], .str) orelse {
            c.failed = true; // reported
            return .err;
        };
        try c.report(a.at, .E0804, "{s}", .{cx.value(msg.computed.id).data.str});
    }
    return a.finish(.noreturn);
}

/// `Hooks.builtin` of the comptime driver: runs `@compile_error` and
/// `@compile_log` reached by the interpreter.
pub fn evalBuiltin(ctx: *anyopaque, m: *interp_ctrl.Machine, b: tir.BuiltinId, args: []const Value) interp_ctrl.StepError!Value {
    const cx: *comptime_ctx.Ctx = @ptrCast(@alignCast(ctx));
    if (b == builtins.Builtin.compile_log.id()) {
        if (cx.log) |w| {
            for (args, 0..) |v, i| {
                if (i > 0) w.writeAll(", ") catch {};
                try writeValue(w, m, v);
            }
            w.writeAll("\n") catch {};
        }
        return .{ .ty = .void, .data = .void };
    }
    if (b != builtins.Builtin.compile_error.id()) return m.fail(unsupportedBuiltin(@fromBackingInt(b.int())));
    const tr = try m.trace();
    defer tr.deinit(m.gpa);
    if (m.eval) |e| e.reported = true;
    try m.sink.emit(.{
        .code = .E0804,
        .severity = .@"error",
        .message = args[0].data.str,
        .spans = &.{.{ .span = tr.span, .primary = true }},
        .trace = tr.frames,
    });
    return m.fail("`@compile_error`");
}

/// What `Bodies.unsupported` records for builtin `b` reached at comptime,
/// with the task that makes it evaluable there when one does.
fn unsupportedBuiltin(b: builtins.Builtin) []const u8 {
    return switch (b) {
        inline else => |t| "`@" ++ @tagName(t) ++ "` in comptime code" ++ comptime switch (t) {
            .size_of, .align_of, .type_info, .type_name, .has_field, .has_method, .implements, .field_type, .field, .call, .fn_info, .variant_count => " (T069)",
            .embed_file, .env, .env_or, .target => " (T073)",
            .hash => " (T066)",
            else => "",
        },
    };
}

/// Prints `v` for `@compile_log`; output errors are ignored.
fn writeValue(w: *std.Io.Writer, m: *interp_ctrl.Machine, v: Value) Allocator.Error!void {
    const it = m.in.items;
    switch (v.data) {
        .str => |s| w.writeAll(s) catch {},
        .type => |t| w.writeAll(try it.types.allocPrint(m.in.arena, t, .{})) catch {},
        .scalar => |bits| if (v.ty == .bool) {
            w.print("{}", .{bits != 0}) catch {};
        } else if (v.ty == .f32 or v.ty == .f64) {
            w.print("{d}", .{v.toFloat()}) catch {};
        } else if (convert.intInfo(it.types, it.options.ptr_bits, v.ty)) |info| {
            w.print("{d}", .{intOf(info, bits)}) catch {};
        } else w.print("{d}", .{bits}) catch {},
        .aggregate, .slice => |vs| {
            w.writeAll("{") catch {};
            for (vs, 0..) |e, i| {
                w.writeAll(if (i == 0) " " else ", ") catch {};
                try writeValue(w, m, e);
            }
            w.writeAll(" }") catch {};
        },
        else => w.print("<{t}>", .{v.data}) catch {},
    }
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const diag = @import("../diag/diag.zig");
const module_graph = @import("../resolve/module_graph.zig");
const imports = @import("../resolve/imports.zig");
const names_mod = @import("../resolve/names.zig");
const protocols_mod = @import("protocols.zig");
const Interner = @import("../base/Interner.zig");

/// A package checked up to function bodies with comptime evaluation;
/// `@compile_log` prints to `log`.
pub const Fixture = struct {
    p: module_graph.TestPackage,
    g: module_graph.Graph,
    im: imports.Imports,
    names: names_mod.Names,
    strings: Interner,
    types: Types,
    cx: comptime_ctx.Ctx,
    items: items_mod.Items,
    protos: protocols_mod.Protocols,
    bodies: emit_tir.Bodies,
    log: std.Io.Writer.Allocating,

    pub fn init(f: *Fixture, source: []const u8) !void {
        f.p = try .init(&.{.{ "a", source }});
        f.g = try f.p.graph(.{ .kind = .exe });
        f.im = try imports.resolve(testing.allocator, &f.p.sink, &f.g, .{});
        f.names = try names_mod.resolve(testing.allocator, &f.p.sink, &f.im);
        f.strings = .init(testing.allocator, testing.io);
        f.types = try .init(testing.allocator, testing.io, &f.strings);
        f.log = .init(testing.allocator);
        f.cx = .init(testing.allocator);
        f.cx.log = &f.log.writer;
        const pkg: Types.Package = .{ .name = try f.strings.intern("app"), .line = .{ .major = 1 } };
        f.items = try items_mod.check(testing.allocator, &f.p.sink, &f.types, &f.im, &f.names, .{ .package = pkg, .comptime_hook = f.cx.hook() });
        f.protos = try protocols_mod.check(testing.allocator, &f.p.sink, &f.items, .{});
        f.bodies = try emit_tir.checkBodies(testing.allocator, &f.items, &f.protos);
    }

    pub fn deinit(f: *Fixture) void {
        f.bodies.deinit();
        f.protos.deinit();
        f.items.deinit();
        f.cx.deinit();
        f.log.deinit();
        f.types.deinit();
        f.strings.deinit();
        f.names.deinit();
        f.im.deinit();
        f.g.deinit();
        f.p.deinit();
    }

    /// The diagnostics: code and the source text of the primary span.
    pub fn expectDiags(f: *Fixture, want: []const struct { ?diag.DiagCode, []const u8 }) !void {
        if (f.bodies.unsupported) |u| std.debug.print("unsupported: {s}\n", .{u.what});
        try testing.expect(f.bodies.unsupported == null);
        const ds = f.p.sink.finish();
        errdefer for (ds) |d| std.debug.print("got {?t}: {s}\n", .{ d.code, d.message });
        try testing.expectEqual(want.len, ds.len);
        for (want, ds) |w, d| {
            try testing.expectEqual(w[0], d.code);
            const s = d.primarySpan().?;
            try testing.expectEqualStrings(w[1], f.p.asts[@backingInt(s.file)].source[s.start..s.end]);
        }
    }
};

test "the untaken branch of comptime if is not checked; @compile_error there has no effect" {
    var f: Fixture = undefined;
    try f.init(
        \\const N: u32 = 2;
        \\fn pick() -> u32 {
        \\    comptime if N > 3 {
        \\        let wrong: str = N;
        \\        @compile_error("N must be at most 3");
        \\    } else {
        \\        N
        \\    }
        \\}
        \\fn only() { comptime if N == 0 { let bad: bool = 1; } }
        \\comptime {
        \\    if N > 3 { @compile_error("never evaluated"); }
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    try testing.expect(f.bodies.find(0, "pick").?.func != null);
    try testing.expect(f.bodies.find(0, "only").?.func != null);
}

test "taken @compile_error is E0804 with its message, at check and at evaluation" {
    var f: Fixture = undefined;
    try f.init(
        \\const N: u32 = 5;
        \\fn pick() -> u32 {
        \\    comptime if N > 3 { @compile_error("N must be at most 3"); }
        \\    N
        \\}
        \\fn limit(n: u32) -> u32 { n }
        \\comptime {
        \\    if limit(N) > 4 { @compile_error("too big"); }
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{ .{ .E0804, "@compile_error" }, .{ .E0804, "@compile_error" } });
    const ds = f.p.sink.finish();
    try testing.expectEqualStrings("N must be at most 3", ds[0].message);
    try testing.expectEqualStrings("too big", ds[1].message);
    try testing.expectEqualStrings("in this comptime evaluation", ds[1].trace[0].note);
}

test "inline for over a type tuple checks each copy of the body separately" {
    var f: Fixture = undefined;
    try f.init(
        \\fn widths() -> u32 {
        \\    let mut n = 0u32;
        \\    inline for T, i in (u8, u16, u32) {
        \\        let big: T = 300;
        \\        n += i as u32;
        \\    }
        \\    n
        \\}
        \\fn zeros() {
        \\    inline for T in (u16, u32) { let z: T = @zero(T); }
        \\}
    );
    defer f.deinit();
    // `300` overflows only the `u8` copy.
    try f.expectDiags(&.{.{ .E0306, "300" }});
    try testing.expect(f.bodies.find(0, "zeros").?.func != null);
}

test "inline for over values and ranges; break and continue act on the copies" {
    var f: Fixture = undefined;
    try f.init(
        \\const XS: [3]u32 = [1, 2, 3];
        \\fn sum() -> u32 {
        \\    let mut s = 0u32;
        \\    inline for x in XS { if x == 2 { continue; } s += x; }
        \\    inline for i in 0u32..=4 { if i == 3 { break; } s += i; }
        \\    inline for v in (10u32, 20u32) { s += v; }
        \\    s
        \\}
        \\fn bad(n: u32) { inline for x in n { } }
        \\const S: u32 = sum();
    );
    defer f.deinit();
    try f.expectDiags(&.{.{ .E0801, "n" }});
    // 1 + 3, then 0 + 1 + 2, then 10 + 20.
    const s = (try f.items.info(.{ .module = 0, .item = f.g.modules[0].names.get("S").? })).@"const";
    try testing.expectEqual(37, s.value.scalar.bits);
}

test "@compile_log is W0801 wherever it is and prints when evaluated" {
    var f: Fixture = undefined;
    try f.init(
        \\const N: u32 = 7;
        \\comptime { @compile_log("N is", N, true); }
        \\comptime { @compile_log("next"); }
        \\fn later() { @compile_log(1); }
    );
    defer f.deinit();
    try f.expectDiags(&.{ .{ .W0801, "@compile_log" }, .{ .W0801, "@compile_log" }, .{ .W0801, "@compile_log" } });
    try testing.expectEqualStrings("N is, 7, true\nnext\n", f.log.written());
}

test "each inline for copy evaluates its comptime contexts afresh" {
    var f: Fixture = undefined;
    try f.init(
        \\fn g() { inline for T in (u32, u8) { let z: T = comptime { 300 }; } }
    );
    defer f.deinit();
    // Only the `u8` copy overflows; it does not reuse the `u32` copy's value.
    try f.expectDiags(&.{.{ .E0306, "comptime" }});
}

test "inline for values are comptime values in each copy" {
    var f: Fixture = undefined;
    try f.init(
        \\fn h() -> u32 {
        \\    let mut s = 0u32;
        \\    inline for x in (1u32, 2u32) {
        \\        comptime if x == 2 { @compile_error("two"); }
        \\        s += comptime { x * 10 };
        \\    }
        \\    s
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{.{ .E0804, "@compile_error" }});
    try testing.expectEqualStrings("two", f.p.sink.finish()[0].message);
}

test "an inline for range over the comptime budget is E0808" {
    var f: Fixture = undefined;
    try f.init(
        \\fn big() { inline for i in 0u64..=0xFFFF_FFFF_FFFF_FFFF { } }
    );
    defer f.deinit();
    try f.expectDiags(&.{.{ .E0808, "..=" }});
}

test "builtins not evaluable at comptime name their owner" {
    try testing.expectEqualStrings("`@size_of` in comptime code (T069)", unsupportedBuiltin(.size_of));
    try testing.expectEqualStrings("`@zero` in comptime code", unsupportedBuiltin(.zero));
}
