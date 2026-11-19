//! Attribute semantics (§8.8, §8.1, §3.3).
//!
//! Placement (E0202, E0203) is checked after parsing (`parse/check.zig`) and
//! warning levels (`@allow`, `@deny`) are applied by `diag/levels.zig`. This
//! file adds what needs the checked items:
//!
//! - every attribute's arguments match its `attr_table` row (names, arity)
//!   and are comptime values of the right kind (§8.1: an attribute argument
//!   is a comptime context): integers, strings, warning codes, trap kinds,
//!   workgroup sizes; `@align(n)` is a power of two no greater than 4096;
//! - `@inline` and `@no_inline` exclude each other;
//! - every use of a `@deprecated` item warns (W0802), at the use, so that
//!   `@allow(W0802)`/`@deny(W0802)` on the using item set its level.
//!
//! `flags` gives later stages (inliner, `pyro doc`) the marker attributes of
//! a declaration. Contract conditions (`@requires`, `@ensures`,
//! `@invariant`) are checked with contracts (§9.5), not here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("../ast/Ast.zig");
const attr_table = @import("../attr_table.zig");
const diag = @import("../diag/diag.zig");
const module_graph = @import("../resolve/module_graph.zig");
const items_mod = @import("items.zig");

const Items = items_mod.Items;
const Node = Ast.Node;
const ModuleId = module_graph.ModuleId;
const Error = Allocator.Error;

/// Maximum `@align(n)` (§8.8).
pub const max_align = 4096;

/// Whether `v` is a valid `@align(n)` argument: a power of two, at most
/// `max_align`.
pub fn validAlign(v: u64) bool {
    return v > 0 and v <= max_align and std.math.isPowerOfTwo(v);
}

/// The attribute that attribute node `n` of `a` names, or null if unknown
/// (E0202, reported after parsing).
pub fn attrOf(a: *const Ast, n: Node.Index) ?attr_table.Attr {
    const text = a.tokenSlice(a.mainToken(n));
    return attr_table.lookup(if (std.mem.startsWith(u8, text, "@")) text[1..] else text);
}

/// The marker attributes of a declaration.
pub const Flags = packed struct {
    deprecated: bool = false,
    doc_hidden: bool = false,
    @"inline": bool = false,
    no_inline: bool = false,
};

/// The flags set by `attrs`, the attribute nodes of one declaration
/// (`Items.attrsOf`).
pub fn flags(a: *const Ast, attrs: []const Node.Index) Flags {
    var f: Flags = .{};
    for (attrs) |n| switch (attrOf(a, n) orelse continue) {
        .deprecated => f.deprecated = true,
        .doc_hidden => f.doc_hidden = true,
        .@"inline" => f.@"inline" = true,
        .no_inline => f.no_inline = true,
        else => {},
    };
    return f;
}

/// The value of attribute argument `x` of module `m`, or null if `x` is an
/// identifier that names no module constant. Name resolution skips
/// attribute arguments, so a bare identifier is looked up among the
/// module's constants here; anything else is evaluated at comptime.
pub fn argValue(it: *Items, m: ModuleId, x: Node.Index) Error!?items_mod.Value {
    const a = it.im.graph.modules[m].ast;
    if (a.kind(x) != .ident) return try it.evalConst(m, x, .none);
    const mod = it.im.graph.modules[m];
    const i = mod.names.get(a.tokenSlice(a.mainToken(x))) orelse return null;
    if (mod.items[i].kind != .@"const") return null;
    return (try it.constValue(m, mod.items[i].node, .none)).value;
}

/// `v` as an integer, or null if it is not one (or is null); a negative or
/// too large integer is `maxInt(u64)`.
pub fn intValue(it: *const Items, v: ?items_mod.Value) ?u64 {
    return switch (v orelse return null) {
        .untyped => |c| if (c == .int) c.int.toInt(u64) catch std.math.maxInt(u64) else null,
        .scalar => |s| {
            const signed = switch (it.types.get(s.type)) {
                .int => |i| i.signedness == .signed,
                .simple => |k| if (k == .usize) false else if (k == .isize) true else return null,
                else => return null,
            };
            // Signed scalars are stored sign-extended.
            return if (signed and @as(i64, @bitCast(s.bits)) < 0) std.math.maxInt(u64) else s.bits;
        },
        else => null,
    };
}

/// The value node of argument `name` of attribute node `at`, written by
/// name or by position, or null if it is absent or the attribute unknown.
pub fn arg(a: *const Ast, at: Node.Index, name: []const u8) ?Node.Index {
    const row = attr_table.info(attrOf(a, at) orelse return null);
    var next: usize = 0;
    for (a.data(at).attribute.args orelse &.{}) |x| switch (slotOf(a, row, x, &next)) {
        .slot => |i| if (std.mem.eql(u8, row.args[i].name, name)) return valueOf(a, x),
        else => {},
    };
    return null;
}

const Slot = union(enum) { slot: usize, unknown_name, too_many };

/// The slot of `row` that argument `x` fills. `next` is the next
/// positional slot; positional arguments skip named-only slots.
fn slotOf(a: *const Ast, row: attr_table.Info, x: Node.Index, next: *usize) Slot {
    if (a.kind(x) == .named_arg) {
        const label = a.tokenSlice(a.mainToken(x));
        for (row.args, 0..) |s, i| if (std.mem.eql(u8, s.name, label)) return .{ .slot = i };
        return .unknown_name;
    }
    while (next.* < row.args.len and row.args[next.*].named) next.* += 1;
    if (next.* == row.args.len) return .too_many;
    next.* += 1;
    return .{ .slot = next.* - 1 };
}

fn valueOf(a: *const Ast, x: Node.Index) Node.Index {
    return if (a.kind(x) == .named_arg) a.data(x).named_arg.value else x;
}

/// Checks the attribute arguments of every module of `it` and reports uses
/// of deprecated items. Run after item checking, with the comptime hook
/// installed so that string arguments can be evaluated.
pub fn check(it: *Items) Error!void {
    for (it.im.graph.modules, 0..) |mod, mi| {
        const m: ModuleId = @intCast(mi);
        const a = mod.ast;
        for (0..a.nodes.len) |i| {
            const n: Node.Index = .from(@intCast(i));
            if (a.kind(n) == .attributed) try checkAttributed(it, m, n);
        }
        try deprecatedUses(it, m);
    }
}

fn checkAttributed(it: *Items, m: ModuleId, n: Node.Index) Error!void {
    const a = it.im.graph.modules[m].ast;
    const d = a.data(n).attributed;
    // A misplaced attribute is E0203 already; its arguments are not judged.
    const position = attr_table.Position.of(a.kind(d.inner)) orelse return;
    for (d.attrs) |at| {
        const attr = attrOf(a, at) orelse continue;
        if (!attr_table.info(attr).positions.contains(position)) continue;
        try checkArgs(it, m, at, attr);
    }
    const f = flags(a, d.attrs);
    if (f.@"inline" and f.no_inline)
        try it.report(m, a.mainToken(n), null, &.{"keep one of them"}, "`@inline` and `@no_inline` contradict each other", .{});
}

/// Matches the arguments of attribute node `at` to the slots of its table
/// row, then checks each value.
fn checkArgs(it: *Items, m: ModuleId, at: Node.Index, attr: attr_table.Attr) Error!void {
    const a = it.im.graph.modules[m].ast;
    const row = attr_table.info(attr);
    const tok = a.mainToken(at);
    const name = @tagName(attr);
    const args = a.data(at).attribute.args;
    if (row.args.len == 0) {
        if (args != null) try it.report(m, tok, null, &.{}, "`@{s}` takes no arguments", .{name});
        return;
    }
    var slots: [4]?Node.Index = @splat(null);
    var next: usize = 0;
    for (args orelse &.{}) |x| {
        const i = switch (slotOf(a, row, x, &next)) {
            .slot => |i| i,
            .unknown_name => {
                try it.report(m, a.mainToken(x), null, &.{}, "`@{s}` has no argument `{s}`", .{ name, a.tokenSlice(a.mainToken(x)) });
                continue;
            },
            .too_many => {
                try it.report(m, a.mainToken(x), null, &.{}, "too many arguments to `@{s}`", .{name});
                break;
            },
        };
        if (slots[i] != null) {
            try it.report(m, a.mainToken(x), null, &.{}, "argument `{s}` of `@{s}` is given twice", .{ row.args[i].name, name });
            continue;
        }
        slots[i] = valueOf(a, x);
    }
    for (row.args, slots[0..row.args.len]) |s, slot| {
        const v = slot orelse {
            if (!s.optional) try it.report(m, tok, null, &.{}, "`@{s}` needs argument `{s}`", .{ name, s.name });
            continue;
        };
        try checkValue(it, m, attr, s, v);
    }
}

fn checkValue(it: *Items, m: ModuleId, attr: attr_table.Attr, s: attr_table.Arg, v: Node.Index) Error!void {
    const a = it.im.graph.modules[m].ast;
    const tok = a.mainToken(v);
    switch (s.kind) {
        .int => {
            const n = intValue(it, try argValue(it, m, v)) orelse
                return it.report(m, tok, null, &.{}, "`@{s}` argument `{s}` must be a comptime integer constant", .{ @tagName(attr), s.name });
            if (attr == .@"align" and n == std.math.maxInt(u64))
                try it.report(m, tok, null, &.{}, "`@align` needs a positive alignment no greater than {d}", .{max_align})
            else if (attr == .@"align" and !validAlign(n))
                try it.report(m, tok, null, &.{}, "`@align({d})`: the alignment must be a power of two no greater than {d}", .{ n, max_align });
        },
        .string => switch (try argValue(it, m, v) orelse return notString(it, m, tok, attr, s)) {
            .computed => |c| if (c.type != .str) try notString(it, m, tok, attr, s),
            .unknown => {}, // not evaluable: reported, or recorded as unsupported
            else => try notString(it, m, tok, attr, s),
        },
        .diag_code => {
            const code = (if (a.kind(v) == .ident) std.meta.stringToEnum(diag.DiagCode, a.tokenSlice(tok)) else null) orelse
                return it.report(m, tok, null, &.{"name a code of the diagnostics table (A), such as `W0802`"}, "`@{s}` needs a diagnostic code", .{@tagName(attr)});
            if (!code.isWarning())
                try it.report(m, tok, null, &.{"errors cannot be suppressed (A.2)"}, "`@{s}({t})`: only warnings can be allowed or denied", .{ @tagName(attr), code });
        },
        // shortcut: only the form `.kind` is checked; §13.6's kind list is checked with `@test` (T135).
        .trap_kind => if (a.kind(v) != .inferred_member)
            try it.report(m, tok, null, &.{}, "`@{s}` argument `{s}` must be a trap kind such as `.bounds`", .{ @tagName(attr), s.name }),
        .workgroup => {
            const dims: []const Node.Index = if (a.kind(v) == .tuple) a.data(v).tuple.elems else &.{v};
            var ok = a.kind(v) != .tuple or dims.len == 3;
            for (dims) |dim| ok = ok and (intValue(it, try argValue(it, m, dim)) orelse std.math.maxInt(u64)) <= std.math.maxInt(u32);
            if (!ok) try it.report(m, tok, null, &.{}, "`@{s}` workgroup size must be a comptime `u32` or a tuple `(x, y, z)` of them", .{@tagName(attr)});
        },
        .condition => {}, // §9.5
    }
}

fn notString(it: *Items, m: ModuleId, tok: Ast.TokenIndex, attr: attr_table.Attr, s: attr_table.Arg) Error!void {
    try it.report(m, tok, null, &.{}, "`@{s}` argument `{s}` must be a comptime string", .{ @tagName(attr), s.name });
}

/// W0802 at every name use in module `m` that denotes a `@deprecated` item.
/// Members reached through a type (`S.f`, `x.f()`) warn from member
/// checking (`check_member.zig`) instead.
fn deprecatedUses(it: *Items, m: ModuleId) Error!void {
    const a = it.im.graph.modules[m].ast;
    var entries = it.names.modules[m].iterator();
    while (entries.next()) |e| {
        const ref = switch (e.value_ptr.res) {
            .global => |t| switch (t) {
                .item => |r| r,
                else => continue,
            },
            .local => continue,
        };
        const item = it.im.graph.modules[ref.module].items[ref.item];
        const da = it.im.graph.modules[ref.module].ast;
        const at = deprecated(da, it.attrsOf(ref.module, item.node)) orelse continue;
        const help: []const []const u8 = if (deprecationNote(da, at)) |note| &.{note} else &.{};
        try it.report(m, a.mainToken(e.key_ptr.*), .W0802, help, "`{s}` is deprecated", .{item.name});
    }
}

/// The `@deprecated` node among `attrs` (attribute nodes of `a`), if any.
pub fn deprecated(a: *const Ast, attrs: []const Node.Index) ?Node.Index {
    for (attrs) |at| if (attrOf(a, at) == .deprecated) return at;
    return null;
}

/// The message of `@deprecated("...")` node `at` as written, if it is a
/// plain string literal.
// shortcut: escapes are shown undecoded; decode them if messages use escapes.
pub fn deprecationNote(a: *const Ast, at: Node.Index) ?[]const u8 {
    const args = a.data(at).attribute.args orelse return null;
    if (args.len != 1 or a.kind(args[0]) != .string_lit) return null;
    const text = a.tokenSlice(a.mainToken(args[0]));
    if (text.len < 2 or text[0] != '"' or text[text.len - 1] != '"') return null;
    return text[1 .. text.len - 1];
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const Compilation = @import("../driver/Compilation.zig");
const emit_tir = @import("emit_tir.zig");

/// Runs `pyro check` stages on `src` and expects diagnostics `want`
/// (`code` or `-` for none, the severity, and a fragment of the message),
/// in source order.
fn expectCheck(src: []const u8, want: []const struct { ?diag.DiagCode, diag.Severity, []const u8 }) !void {
    var comp: Compilation = undefined;
    try comp.init(testing.allocator, testing.io, .{ .jobs = 1, .stop_after = .check });
    defer comp.deinit();
    try comp.addHook(.check, .{ .run = emit_tir.runFiles });
    _ = try comp.addSource("a.pr", src);
    try comp.run();
    const ds = comp.sink.finish();
    errdefer for (ds) |d| std.debug.print("got {?t} {t}: {s}\n", .{ d.code, d.severity, d.message });
    try testing.expectEqual(want.len, ds.len);
    for (want, ds) |w, d| {
        try testing.expectEqual(w[0], d.code);
        try testing.expectEqual(w[1], d.severity);
        try testing.expect(std.mem.indexOf(u8, d.message, w[2]) != null);
    }
}

test "wrong-target attributes are rejected (E0203)" {
    try expectCheck(
        \\@align(8) fn f() {}
        \\@inline struct S { x: u8 }
    , &.{ .{ .E0203, .@"error", "`@align` is not allowed on a function" }, .{ .E0203, .@"error", "`@inline` is not allowed on a struct" } });
}

test "@align: power of two no greater than 4096, comptime integer" {
    try expectCheck(
        \\@align(3) struct A { x: u8 }
        \\@align(8192) struct B { x: u8 }
        \\const K: usize = 3;
        \\const J: usize = 32;
        \\@align(K) struct C { x: u8 }
        \\@align(J) struct D { @align(4096) x: u8 }
        \\@align(true) struct E { x: u8 }
        \\@align(Nope) struct F { x: u8 }
        \\@align struct G { x: u8 }
        \\const N: i32 = -8;
        \\@align(-8) struct H { x: u8 }
        \\@align(N) struct I { x: u8 }
    , &.{
        .{ null, .@"error", "`@align(3)`" },
        .{ null, .@"error", "`@align(8192)`" },
        .{ null, .@"error", "`@align(3)`" },
        .{ null, .@"error", "comptime integer" },
        .{ null, .@"error", "comptime integer" },
        .{ null, .@"error", "needs argument `n`" },
        .{ null, .@"error", "`@align` needs a positive alignment" },
        .{ null, .@"error", "`@align` needs a positive alignment" },
    });
}

test "argument shapes: names, arity and kinds" {
    try expectCheck(
        \\@inline(1) fn a() {}
        \\@deprecated(42) fn b() {}
        \\@deprecated("old", "older") fn c() {}
        \\@law(count: 3) fn d() {}
        \\@allow(X9999) fn e() {}
        \\@test(traps: bounds) fn g() {}
        \\@gpu_kernel(workgroup: (8, 8)) fn h() {}
        \\@gpu_mesh(max_vertices: 64, max_primitives: 64, max_vertices: 3) fn k() {}
        \\@deprecated(Nope) fn l() {}
        \\@deprecated(g) fn n() {}
        \\@allow(E0203) fn p() {}
        \\@gpu_kernel(workgroup: -1) fn q() {}
        \\@gpu_kernel(workgroup: (8,)) fn r() {}
        \\@gpu_kernel(workgroup: 4294967296) fn s() {}
        \\const MSG = "ok";
        \\@deprecated(MSG) @doc_hidden @law(cases: 10) @test(traps: .bounds) @allow(W0802) fn ok() {}
        \\@gpu_kernel(workgroup: (8, 8, 4294967295)) fn ok2() {}
    , &.{
        .{ null, .@"error", "`@inline` takes no arguments" },
        .{ null, .@"error", "must be a comptime string" },
        .{ null, .@"error", "too many arguments to `@deprecated`" },
        .{ null, .@"error", "`@law` has no argument `count`" },
        .{ null, .@"error", "needs a diagnostic code" },
        .{ null, .@"error", "must be a trap kind" },
        .{ null, .@"error", "workgroup size" },
        .{ null, .@"error", "`max_vertices` of `@gpu_mesh` is given twice" },
        .{ null, .@"error", "`@deprecated` argument `msg` must be a comptime string" },
        .{ null, .@"error", "`@deprecated` argument `msg` must be a comptime string" },
        .{ null, .@"error", "`@allow(E0203)`: only warnings" },
        .{ null, .@"error", "workgroup size" },
        .{ null, .@"error", "workgroup size" },
        .{ null, .@"error", "workgroup size" },
    });
}

test "arg finds an argument by name or position" {
    var a = try @import("../resolve/test_util.zig").parseForTest(
        \\@gpu_mesh(max_vertices: 64, max_primitives: 32) fn f() {}
        \\@deprecated("old") fn g() {}
    );
    defer a.deinit(testing.allocator);
    var found: usize = 0;
    for (0..a.nodes.len) |i| {
        const n: Node.Index = .from(@intCast(i));
        if (a.kind(n) != .attribute) continue;
        switch (attrOf(&a, n).?) {
            .gpu_mesh => {
                try testing.expectEqualStrings("32", a.tokenSlice(a.mainToken(arg(&a, n, "max_primitives").?)));
                try testing.expectEqualStrings("64", a.tokenSlice(a.mainToken(arg(&a, n, "max_vertices").?)));
            },
            .deprecated => try testing.expectEqualStrings("\"old\"", a.tokenSlice(a.mainToken(arg(&a, n, "msg").?))),
            else => unreachable,
        }
        found += 1;
    }
    try testing.expectEqual(2, found);
}

test "@inline and @no_inline exclude each other; flags" {
    try expectCheck("@inline @no_inline fn f() {}", &.{.{ null, .@"error", "contradict" }});
    var a = try @import("../resolve/test_util.zig").parseForTest("@doc_hidden @inline fn f() {}");
    defer a.deinit(testing.allocator);
    for (0..a.nodes.len) |i| if (a.kind(.from(@intCast(i))) == .attributed) {
        const f = flags(&a, a.data(.from(@intCast(i))).attributed.attrs);
        try testing.expectEqual(Flags{ .doc_hidden = true, .@"inline" = true }, f);
        return;
    };
    return error.TestUnexpectedResult;
}

test "using a deprecated item warns W0802; @allow silences, @deny errors" {
    try expectCheck(
        \\@deprecated("use area_of instead")
        \\fn area(w: f32, h: f32) -> f32 { w * h }
        \\fn area_of(w: f32, h: f32) -> f32 { w * h }
        \\fn room() -> f32 { area(2.0, 3.0) }
        \\fn fine() -> f32 { area_of(2.0, 3.0) }
        \\@allow(W0802) fn legacy() -> f32 { area(1.0, 1.0) }
        \\@deny(W0802) fn strict() -> f32 { area(4.0, 5.0) }
        \\@deprecated("gone") struct Old { x: u8 }
        \\fn make() -> Old { Old { x: 1 } }
    , &.{
        .{ .W0802, .warning, "`area` is deprecated" },
        .{ .W0802, .@"error", "`area` is deprecated" },
        .{ .W0802, .warning, "`Old` is deprecated" },
        .{ .W0802, .warning, "`Old` is deprecated" },
    });
}

test "using a deprecated member through a type warns W0802" {
    try expectCheck(
        \\struct T {
        \\    x: u8,
        \\    @deprecated("x") fn m() {}
        \\    @deprecated("y") fn get(self) -> u8 { self.x }
        \\    @deprecated("z") const K: u8 = 1;
        \\}
        \\fn f(t: T) -> u8 { T.m(); t.get() + T.K }
        \\@allow(W0802) fn g() { T.m() }
    , &.{
        .{ .W0802, .warning, "`m` is deprecated" },
        .{ .W0802, .warning, "`get` is deprecated" },
        .{ .W0802, .warning, "`K` is deprecated" },
    });
}
