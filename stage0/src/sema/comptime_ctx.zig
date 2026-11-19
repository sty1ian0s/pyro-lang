//! Comptime contexts and the evaluation driver (§8.1, §8.5, B.4).
//!
//! Every comptime context reaches the evaluator through one entry point,
//! `Ctx.eval`, installed as item checking's comptime hook
//! (`items.ComptimeHook`):
//!
//! - item positions: `const` initializers, parameter and field defaults,
//!   enum discriminants, array lengths and `vec` lane counts in type
//!   expressions; `items.zig` folds literals and operators itself and
//!   hands the rest here;
//! - top-level `comptime { ... }` blocks, evaluated for their effects by
//!   `emit_tir.checkBodies`;
//! - `comptime { ... }` and `comptime e` inside function bodies (`expr`).
//!
//! An evaluation checks the expression as the body of a parameterless
//! *thunk* function in comptime mode (`Checker.in_comptime`, where a runtime
//! local is E0801), checks the bodies of the functions it may call, and
//! runs the thunk on the TIR interpreter (`comptime/interp_ctrl.zig`) with
//! the §8.6 budget. Scalars and types come back as `items.Value.scalar` and
//! `.type`; any other value (arrays, structs, `str`...) is stored in the
//! value table and comes back as `.computed`, which a function body embeds
//! as a `comptime` TIR constant (`use`) and the back end emits as read-only
//! data (`addRodata`).
//!
//! - Results are cached per expression node: each context is evaluated
//!   once, and a failed one is not reported twice.
//! - A context that is reached again while it is being evaluated is a
//!   cycle and reported. Cycles between consts are found earlier, by
//!   `Items.constValue`.
//! - A trap stops the evaluation with a diagnostic and the comptime stack
//!   trace (`interp_expr.report`): a failing `comptime` block aborts the
//!   compilation. A construct the interpreter cannot run yet is recorded
//!   in `Bodies.unsupported`.
//! - Functions called at comptime are checked into the same `Bodies` that
//!   `checkBodies` later fills, so no body is checked (or reported) twice.

const std = @import("std");
const Allocator = std.mem.Allocator;
const diag = @import("../diag/diag.zig");
const Ast = @import("../ast/Ast.zig");
const Types = @import("types.zig");
const items_mod = @import("items.zig");
const emit_tir = @import("emit_tir.zig");
const check_expr = @import("check_expr.zig");
const check_stmt = @import("check_stmt.zig");
const tir = @import("../tir/tir.zig");
const ir = @import("../pir/ir.zig");
const layout = @import("layout.zig");
const ModuleId = @import("../resolve/module_graph.zig").ModuleId;
const Value = @import("../comptime/value.zig").Value;
const EvalArena = @import("../comptime/arena.zig").EvalArena;
const embed = @import("../comptime/embed.zig");
const interp_ctrl = @import("../comptime/interp_ctrl.zig");
const limits = @import("../comptime/limits.zig");

const Node = Ast.Node;
const TypeId = Types.TypeId;
const Items = items_mod.Items;
const Bodies = emit_tir.Bodies;
const Checker = emit_tir.Checker;
const Typed = emit_tir.Typed;
const Machine = interp_ctrl.Machine;
const Error = Allocator.Error;

/// A computed value as item checking records it.
pub const Computed = @FieldType(items_mod.Value, "computed");

const Key = struct { ModuleId, Node.Index };

/// The comptime state of one package. Must not move after `hook`.
pub const Ctx = struct {
    gpa: Allocator,
    /// Values that are not scalars or types, by `tir.ComptimeId`; they live
    /// in `values`.
    table: std.ArrayList(Value) = .empty,
    values: std.heap.ArenaAllocator,
    /// Memory of the evaluation in progress.
    ev: EvalArena,
    /// The result of each context evaluated; null if it failed.
    cache: std.AutoHashMapUnmanaged(Key, ?items_mod.Value) = .empty,
    /// Contexts being evaluated.
    active: std.AutoHashMapUnmanaged(Key, void) = .empty,
    /// Bodies checked for comptime calls before `checkBodies` runs.
    own: ?Bodies = null,
    /// The bodies of the running `checkBodies`, which evaluation fills.
    shared: ?*Bodies = null,

    pub fn init(gpa: Allocator) Ctx {
        return .{ .gpa = gpa, .values = .init(gpa), .ev = .init(gpa) };
    }

    pub fn deinit(cx: *Ctx) void {
        if (cx.own) |*b| b.deinit();
        cx.cache.deinit(cx.gpa);
        cx.active.deinit(cx.gpa);
        cx.table.deinit(cx.gpa);
        cx.ev.deinit();
        cx.values.deinit();
        cx.* = undefined;
    }

    /// The comptime hook for `items.Options.comptime_hook`.
    pub fn hook(cx: *Ctx) items_mod.ComptimeHook {
        return .{ .ctx = cx, .eval = evalHook };
    }

    /// The value of computed entry `id`.
    pub fn value(cx: *const Ctx, id: tir.ComptimeId) Value {
        return cx.table.items[id.int()];
    }

    /// The bodies checked so far, for `checkBodies` to continue; the
    /// caller owns them.
    pub fn takeBodies(cx: *Ctx) Error!Bodies {
        defer cx.own = null;
        return cx.own orelse try .init(cx.gpa);
    }

    fn bodies(cx: *Ctx) Error!*Bodies {
        if (cx.shared) |b| return b;
        if (cx.own == null) {
            cx.own = try .init(cx.gpa);
            cx.own.?.before_protos = true;
        }
        return &cx.own.?;
    }

    /// The value of comptime expression `n` of module `m`, converted to
    /// `expected` (or of its own type for `.none`); null if it failed or
    /// cannot be evaluated yet (reported, or recorded as unsupported).
    pub fn eval(cx: *Ctx, it: *Items, m: ModuleId, n: Node.Index, expected: TypeId) Error!?items_mod.Value {
        const key: Key = .{ m, n };
        if (cx.cache.get(key)) |v| return v;
        if ((try cx.active.getOrPut(cx.gpa, key)).found_existing) {
            const ast = it.im.graph.modules[m].ast;
            try it.report(m, ast.mainToken(n), null, &.{}, "comptime evaluation depends on its own result", .{});
            return null;
        }
        const v = try cx.run(it, m, n, expected);
        _ = cx.active.remove(key);
        try cx.cache.put(cx.gpa, key, v);
        return v;
    }

    fn run(cx: *Ctx, it: *Items, m: ModuleId, n: Node.Index, expected: TypeId) Error!?items_mod.Value {
        const bs = try cx.bodies();
        const id = try compile(bs, it, m, n, expected) orelse return null;
        try checkCallees(bs, it);
        const ast = it.im.graph.modules[m].ast;
        const start = ast.tokens.items(.start)[ast.mainToken(n)];
        const outer = [_]diag.TraceFrame{.{
            .span = .{ .file = it.im.graph.modules[m].file, .start = start, .end = start + ast.tokens.items(.len)[ast.mainToken(n)] },
            .note = "in this comptime evaluation",
        }};
        var ev: limits.Eval = .{};
        var mach: Machine = .{
            .in = .{ .items = it, .arena = cx.ev.allocator() },
            .gpa = cx.gpa,
            .bodies = bs,
            .sink = it.sink,
            .outer = &outer,
            .hooks = .{ .ctx = cx, .resolve = resolve, .stop = stop },
        };
        defer mach.deinit();
        ev.attach(&mach);
        const r = mach.call(id, &.{}) catch |e| {
            cx.ev.abort();
            switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                // A callee without TIR failed (reported), is unsupported
                // (recorded), or is still being checked: then this
                // evaluation is part of checking it, a cycle.
                error.Unsupported => if (ev.reported or bs.unsupported != null) {} else if (mach.unsupported.?.ptr != interp_ctrl.unchecked_callee.ptr) {
                    bs.unsupported = .{ .module = m, .node = n, .what = mach.unsupported.? };
                } else if (!it.sink.hasErrors()) {
                    try it.report(m, ast.mainToken(n), null, &.{"a function cannot call itself at comptime while its own body is checked"}, "comptime evaluation depends on its own result", .{});
                },
                error.Trapped, error.OverBudget => {}, // reported
            }
            return null;
        };
        const v = try cx.ev.finish(cx.values.allocator(), r);
        switch (v.data) {
            .scalar => |bits| return .{ .scalar = .{ .type = v.ty, .bits = bits } },
            .type => |t| return .{ .type = t },
            else => {},
        }
        try cx.table.append(cx.gpa, v);
        return .{ .computed = .{ .type = v.ty, .id = .from(cx.table.items.len - 1) } };
    }

    /// Embeds computed entry `id` as the read-only global `name` of `out`
    /// (§8.1: arrays land in read-only data), in the layout of `e` and
    /// byte order `endian`. `arena` holds the encoded image.
    pub fn addRodata(cx: *const Ctx, arena: Allocator, e: *layout.Engine, endian: std.builtin.Endian, out: *ir.Module, name: []const u8, id: tir.ComptimeId) embed.Error!void {
        const image = try embed.encode(arena, e, endian, cx.value(id));
        // shortcut: strings and slices need relocated blobs; T091 emits them.
        if (image.blobs.len > 1 or image.blobs[0].relocs.len > 0) return error.Unsupported;
        try embed.addGlobal(out, name, image.blobs[0]);
    }
};

/// The context installed in `it`, if it is a `Ctx`.
pub fn of(it: *const Items) ?*Ctx {
    const h = it.options.comptime_hook orelse return null;
    return if (h.eval == &evalHook) @ptrCast(@alignCast(h.ctx.?)) else null;
}

fn evalHook(ctx: ?*anyopaque, it: *Items, m: ModuleId, n: Node.Index, expected: TypeId) Error!?items_mod.Value {
    const cx: *Ctx = @ptrCast(@alignCast(ctx.?));
    return cx.eval(it, m, n, expected);
}

/// Checks comptime expression `n` as the body of a thunk and returns the
/// thunk's id, or null if checking failed.
fn compile(bs: *Bodies, it: *Items, m: ModuleId, n: Node.Index, expected: TypeId) Error!?tir.FnId {
    const ast = it.im.graph.modules[m].ast;
    const a = bs.arena.allocator();
    var c: Checker = .{
        .bodies = bs,
        .items = it,
        .types = it.types,
        .sink = it.sink,
        .arena = a,
        .m = m,
        .ast = ast,
        // shortcut: the hook gets no enclosing type, so `Self` is unknown in comptime code inside a type.
        .self_ty = .none,
        .sig = .{ .node = n, .name = "comptime", .is_pub = false, .generics = &.{}, .params = &.{}, .ret = expected, .attrs = &.{} },
        .b = .init(a, expected),
        .in_comptime = true,
    };
    c.b.node = n;
    c.setBlock(try c.addBlock());
    const d = ast.data(n);
    const raw = switch (d) {
        .comptime_block => |x| try check_stmt.block(&c, x.body, expected),
        .prefix => |p| if (ast.tokens.items(.kind)[ast.mainToken(n)] == .kw_comptime)
            try check_expr.check(&c, p.operand, expected)
        else
            try check_expr.check(&c, n, expected),
        else => try check_expr.check(&c, n, expected),
    };
    const v = try c.coerce(raw, expected, n);
    if (c.failed) return null;
    if (v.ty == .noreturn) {
        c.b.ret = .void;
    } else {
        c.b.ret = v.ty;
        _ = try c.emit(.void, .{ .ret = .{ .value = if (v.ty == .void) null else v.ref } });
    }
    for (c.b.blocks.items, 0..) |_, i| if (!c.b.isTerminated(.from(i))) {
        c.setBlock(.from(i));
        _ = try c.b.add(.void, .{ .@"unreachable" = .{} });
    };
    const func = try c.b.finish();
    const id = try bs.fnId(m, n, "comptime");
    bs.fns.items[id.int()].func = func;
    bs.fns.items[id.int()].checked = true;
    bs.fns.items[id.int()].thunk = true;
    return id;
}

/// Checks every function body the bodies so far may call and that is not
/// checked yet. Functions found nowhere (impl methods) wait for
/// `checkBodies`; calling one at comptime stops as unsupported.
fn checkCallees(bs: *Bodies, it: *Items) Error!void {
    var i: usize = 0;
    // Checking appends callees to `bs.fns`.
    while (i < bs.fns.items.len) : (i += 1) {
        const b = bs.fns.items[i];
        if (b.checked) continue;
        const ast = it.im.graph.modules[b.module].ast;
        if (ast.kind(b.node) != .fn_decl or ast.data(b.node).fn_decl.body == null) continue;
        const d = try declOf(it, b.module, b.node) orelse continue;
        try emit_tir.checkDecl(bs, it, b.module, d.f, d.self_ty, d.generics);
    }
}

const Decl = struct { f: items_mod.Fn, self_ty: TypeId, generics: []const TypeId };

/// The free function or struct/enum method declared by `fn_decl` `node`.
fn declOf(it: *Items, m: ModuleId, node: Node.Index) Error!?Decl {
    for (it.im.graph.modules[m].items, 0..) |_, i| switch ((try it.info(.{ .module = m, .item = @intCast(i) })).*) {
        .@"fn" => |f| if (f.node == node) return .{ .f = f, .self_ty = .none, .generics = &.{} },
        .@"struct" => |s| for (s.methods) |f| if (f.node == node) return .{ .f = f, .self_ty = s.type, .generics = s.generics },
        .@"enum" => |e| for (e.methods) |f| if (f.node == node) return .{ .f = f, .self_ty = e.type, .generics = e.generics },
        else => {},
    };
    return null;
}

/// The values of `comptime` instructions: computed entries.
fn resolve(ctx: *anyopaque, m: *Machine, func: *const tir.Func, r: tir.Ref) interp_ctrl.StepError!Value {
    const cx: *Ctx = @ptrCast(@alignCast(ctx));
    return switch (func.data(r)) {
        .@"comptime" => |k| cx.value(k.value),
        else => m.fail("`static` items in comptime code"),
    };
}

/// Reports why an evaluation stopped (E0805, E0808) with the comptime
/// stack trace.
fn stop(_: *anyopaque, m: *Machine, why: interp_ctrl.Stop) Allocator.Error!void {
    return limits.report(m, why);
}

/// Computed value `cv` used at `n` in a function body: embedded as a
/// constant (§8.1). Outside comptime code it must be embeddable (E0802).
pub fn use(c: *Checker, n: Node.Index, cv: Computed) Error!Typed {
    if (!c.in_comptime and !try embed.checkRuntime(c.items, c.m, c.ast.mainToken(n), cv.type)) {
        c.failed = true;
        return .err;
    }
    return .{ .ty = cv.type, .ref = try c.emit(cv.type, .{ .@"comptime" = .{ .value = cv.id } }) };
}

/// `comptime { ... }` or `comptime e` in a function body (§8.1): evaluated
/// once at compile time and embedded as a constant.
pub fn expr(c: *Checker, n: Node.Index, expected: TypeId) Error!Typed {
    // Inside comptime code everything is comptime already (§8.1): check inline.
    if (c.in_comptime) return switch (c.ast.data(n)) {
        .comptime_block => |x| check_stmt.block(c, x.body, expected),
        else => |d| check_expr.check(c, d.prefix.operand, expected),
    };
    const cx = of(c.items) orelse return c.unsupported(n, "comptime evaluation without an evaluator");
    const v = try cx.eval(c.items, c.m, n, expected) orelse {
        c.failed = true; // reported, or recorded as unsupported
        return .err;
    };
    return switch (v) {
        .scalar => |s| c.constant(s),
        .computed => |cv| use(c, n, cv),
        .type => c.unsupported(n, "types as values (T065)"),
        .untyped, .unknown => unreachable, // evaluation gives typed values
    };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const module_graph = @import("../resolve/module_graph.zig");
const imports = @import("../resolve/imports.zig");
const names_mod = @import("../resolve/names.zig");
const protocols_mod = @import("protocols.zig");
const Interner = @import("../base/Interner.zig");

/// A package checked up to function bodies with comptime evaluation.
const Fixture = struct {
    p: module_graph.TestPackage,
    g: module_graph.Graph,
    im: imports.Imports,
    names: names_mod.Names,
    strings: Interner,
    types: Types,
    cx: Ctx,
    items: Items,
    protos: protocols_mod.Protocols,
    bodies: Bodies,

    fn init(f: *Fixture, source: []const u8) !void {
        f.p = try .init(&.{.{ "a", source }});
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

    fn expectComplete(f: *Fixture) !void {
        if (f.bodies.unsupported) |u| {
            std.debug.print("unsupported: {s}\n", .{u.what});
            return error.TestUnexpectedResult;
        }
    }

    fn constOf(f: *Fixture, name: []const u8) !items_mod.Const {
        return (try f.items.info(.{ .module = 0, .item = f.g.modules[0].names.get(name).? })).@"const";
    }
};

test "array lengths and consts from const fns; consts used in bodies" {
    var f: Fixture = undefined;
    try f.init(
        \\fn fact(n: u64) -> u64 { if n == 0 { 1 } else { n * fact(n - 1) } }
        \\fn width() -> usize { let mut w: usize = 1; while w < 5 { w += w; } w }
        \\const F5: u64 = fact(5);
        \\const W = width();
        \\struct Buf { data: [width()]u8 }
        \\fn get(b: Buf) -> usize { b.data[7] as usize + W + F5 as usize }
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    try f.expectComplete();
    try testing.expectEqual(120, (try f.constOf("F5")).value.scalar.bits);
    const w = (try f.constOf("W")).value.scalar;
    try testing.expectEqual(TypeId.usize, w.type);
    try testing.expectEqual(8, w.bits);
    const buf = f.items.structOf((try f.items.info(.{ .module = 0, .item = 4 })).@"struct".type).?;
    try testing.expectEqual(8, f.types.get(buf.fields[0].type).array.len);
    try testing.expect(f.bodies.find(0, "get").?.func != null);
    // `fact` and `width` were checked once, for comptime, and kept.
    var n: usize = 0;
    for (f.bodies.fns.items) |b| n += @intFromBool(std.mem.eql(u8, b.name, "fact"));
    try testing.expectEqual(1, n);
}

test "const arrays are computed values that land in rodata" {
    var f: Fixture = undefined;
    try f.init(
        \\fn squares() -> [4]u32 {
        \\    let mut a = [0u32; 4];
        \\    let mut i: usize = 0;
        \\    while i < 4 { a[i] = (i * i) as u32; i += 1; }
        \\    a
        \\}
        \\const TABLE: [4]u32 = squares();
        \\fn lookup(i: usize) -> u32 { TABLE[i] }
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    try f.expectComplete();
    const cv = (try f.constOf("TABLE")).value.computed;
    const tv = f.cx.value(cv.id);
    try testing.expectEqual(4, tv.data.aggregate.len);
    try testing.expectEqual(9, tv.data.aggregate[3].data.scalar);
    // The body reads it as an embedded constant.
    const func = &f.bodies.find(0, "lookup").?.func.?;
    var found = false;
    for (0..func.insts.len) |i| if (func.op(.from(i)) == .@"comptime") {
        found = true;
    };
    try testing.expect(found);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var e: layout.Engine = .init(testing.allocator, &f.items);
    defer e.deinit();
    var out = try ir.Module.init(testing.allocator);
    defer out.deinit();
    try f.cx.addRodata(arena.allocator(), &e, .little, &out, "TABLE", cv.id);
    const g = out.findGlobal("TABLE").?;
    try testing.expect(g.readonly);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 1, 0, 0, 0, 4, 0, 0, 0, 9, 0, 0, 0 }, g.init.bytes);
}

test "a failing comptime block aborts with the comptime trace" {
    var f: Fixture = undefined;
    try f.init(
        \\fn check(n: u32) -> u32 { 100 / n }
        \\comptime { let ok = check(4); }
        \\comptime { check(0); }
    );
    defer f.deinit();
    try f.expectComplete();
    const ds = f.p.sink.finish();
    try testing.expectEqual(1, ds.len);
    try testing.expectEqualStrings("comptime evaluation traps: division by zero", ds[0].message);
    try testing.expectEqual(2, ds[0].trace.len);
    try testing.expectEqualStrings("in call to `check`", ds[0].trace[0].note);
    try testing.expectEqualStrings("in this comptime evaluation", ds[0].trace[1].note);
}

test "mutual const recursion is reported" {
    var f: Fixture = undefined;
    try f.init(
        \\const A: u32 = B + 1;
        \\const B: u32 = next(A);
        \\fn next(x: u32) -> u32 { x + 1 }
    );
    defer f.deinit();
    try f.expectDiags(&.{.{ null, "A" }});
}

test "comptime expressions in bodies; runtime locals are E0801; the budget is E0808" {
    var f: Fixture = undefined;
    try f.init(
        \\fn sq(x: u32) -> u32 { x * x }
        \\fn spin() -> u32 { let mut i = 0u32; while true { i += 1; } i }
        \\fn a() -> u32 { comptime sq(7) + comptime { let k = sq(2); k + 1 } }
        \\fn b(n: u32) -> u32 { comptime sq(n) }
        \\const S: u32 = spin();
    );
    defer f.deinit();
    // E0808 is reported at the evaluation: the `(` of `spin()`.
    try f.expectDiags(&.{ .{ .E0801, "n" }, .{ .E0808, "(" } });
    try testing.expect(f.bodies.find(0, "a").?.func != null);
}

test "impl methods reached from a const are checked again with protocols" {
    var f: Fixture = undefined;
    try f.init(
        \\protocol Get { fn get(self) -> u32; }
        \\struct S { x: u32 }
        \\impl Get for S { fn get(self) -> u32 { self.x } }
        \\fn h(s: S) -> u32 { s.get() }
        \\fn use_h() -> u32 { h(S { x: 1 }) }
        \\const C: u32 = use_h();
        \\fn main() { let k = C; }
    );
    defer f.deinit();
    // No false "no method" error: `C` waits, and `h` is checked again with the impl.
    try f.expectDiags(&.{});
    try testing.expectEqualStrings("impl methods called from comptime code in item positions", f.bodies.unsupported.?.what);
    try testing.expect(f.bodies.find(0, "h").?.func != null);
}

test "typed const lane counts; nested comptime; self-recursion; runtime repeat counts" {
    var f: Fixture = undefined;
    try f.init(
        \\const L: u32 = 4;
        \\fn s(x: f32) -> vec4<f32> { @splat(L, x) }
        \\fn n() -> u32 { comptime { let k = 2u32; comptime k + 1 } }
        \\fn g() -> u32 { comptime g() }
        \\fn q(m: usize) -> [4]u8 { [0u8; m] }
    );
    defer f.deinit();
    try f.expectDiags(&.{ .{ null, "comptime" }, .{ .E0801, "m" } });
    try testing.expect(f.bodies.find(0, "s").?.func != null);
    try testing.expect(f.bodies.find(0, "n").?.func != null);
    try testing.expect(f.bodies.unsupported == null);
}
