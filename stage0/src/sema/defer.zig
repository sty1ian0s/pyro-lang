//! `defer`, `errdefer` and `return tail` (§6.8.1, §6.8.2, §6.9).
//!
//! Checking side (called from `check_stmt.zig`):
//!
//! - `deferStmt` checks `defer S`/`errdefer S`: E0360 if `S` contains a
//!   `return`, `break`, `continue` or `?` that leaves `S`, or registers
//!   further defers; E0362 for `errdefer` in a function not returning
//!   `Result`. `S` is emitted as a body region (blocks ending in
//!   `defer_end`) registered by a `defer`/`errdefer` marker in the scope of
//!   the enclosing block (see the `tir.zig` file doc).
//! - A block opens its scope lazily, at its first `defer`: exits before it
//!   have nothing to run. `leave`/`leaveLoop` emit the `scope_end`s of the
//!   scopes a `return`, `?`, `break` or `continue` leaves, innermost first,
//!   after its value is computed; `check_stmt.block` ends the block's own
//!   scope at its end. A loop body is a block, so its defers run on every
//!   iteration.
//! - `returnTail` checks `return tail f(args);`: `f` returns exactly the
//!   function's type (E0310), and the frame can be reused (E0363): no
//!   `defer`/`errdefer` is pending and no view argument names storage of
//!   this frame. The call instruction becomes `ret_tail`.
//!
//! Expansion (`expand`): a copy of a checked `tir.Func` with every
//! registered body cloned at each `scope_end` of its scope, LIFO, which is
//! what lowering and the CFG (T079, T089) consume. `errdefer` bodies are
//! cloned only on an error route, read as the comptime interpreter does
//! (`interp_ctrl.zig`): the `scope_end`'s block ends in a `ret` of a
//! `Result` `.err`. When the returned value is not a `variant` instruction
//! its tag is tested at run time.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("../ast/Ast.zig");
const Types = @import("types.zig");
const tir = @import("../tir/tir.zig");
const Builder = @import("../tir/builder.zig").Builder;
const emit_tir = @import("emit_tir.zig");
const check_expr = @import("check_expr.zig");
const must_use = @import("must_use.zig");

const Node = Ast.Node;
const Checker = emit_tir.Checker;
const Error = emit_tir.Error;
const Ref = tir.Ref;

/// An open block scope (one that registered a defer).
pub const Scope = struct {
    /// Its `scope_begin`.
    begin: Ref,
    /// `Checker.loops.items.len` when it opened: `break`/`continue` to a
    /// loop at a lower index leaves it.
    loops: usize,
};

// ---------------------------------------------------------------------------
// Checking

/// Emits the `scope_end` of every open scope above the first `keep`,
/// innermost first, without closing them (the code after the exit is dead
/// or another route).
pub fn leave(c: *Checker, keep: usize) Error!void {
    var i = c.scopes.items.len;
    while (i > keep) {
        i -= 1;
        _ = try c.emit(.void, .{ .scope_end = .{ .scope = c.scopes.items[i].begin } });
    }
}

/// `leave` for a `break` or `continue` that targets `loop`.
pub fn leaveLoop(c: *Checker, loop: *const emit_tir.Loop) Error!void {
    const li = (@intFromPtr(loop) - @intFromPtr(c.loops.items.ptr)) / @sizeOf(emit_tir.Loop);
    var keep: usize = 0;
    while (keep < c.scopes.items.len and c.scopes.items[keep].loops <= li) keep += 1;
    return leave(c, keep);
}

/// `defer S` or `errdefer S` (§6.8).
pub fn deferStmt(c: *Checker, s: Node.Index) Error!bool {
    const is_err = c.ast.kind(s) == .@"errdefer";
    const body = if (is_err) c.ast.data(s).@"errdefer".body else c.ast.data(s).@"defer".body;
    if (is_err and c.sig.ret != .err and !isResult(c.types, c.sig.ret)) {
        try c.reportAt(c.ast.mainToken(s), .E0362, &.{"use `defer`, or return `Result<T, E>`"}, "`errdefer` needs a function returning `Result`, but `{s}` returns `{s}`", .{ c.sig.name, try c.tyName(c.sig.ret) });
    }
    var labels: std.ArrayList([]const u8) = .empty;
    try contained(c, body, 0, &labels);

    if (c.scopes.items.len == c.scope_base) {
        try c.scopes.append(c.arena, .{ .begin = try c.emit(.void, .{ .scope_begin = .{} }), .loops = c.loops.items.len });
    }
    const region = try c.addBlock();
    const scope = c.scopes.getLast().begin;
    _ = try c.emit(.void, if (is_err) .{ .@"errdefer" = .{ .scope = scope, .body = region } } else .{ .@"defer" = .{ .scope = scope, .body = region } });
    const here = c.b.block;
    // Outer loops are not targets inside `S` (E0360 above).
    const loops = c.loops;
    c.loops = .empty;
    c.setBlock(region);
    const v = try check_expr.check(c, body, .none);
    try must_use.check(c, body, v.ty);
    _ = try c.emit(.void, .{ .defer_end = .{} });
    c.loops = loops;
    c.setBlock(here);
    return false;
}

/// Reports E0360 for each route in `n` (inside a deferred statement, under
/// `depth` loops of it, whose labels are `labels`) that leaves the
/// statement, and for each nested `defer`.
fn contained(c: *Checker, n: Node.Index, depth: u32, labels: *std.ArrayList([]const u8)) Error!void {
    const what: []const u8 = switch (c.ast.kind(n)) {
        .lambda => return, // its own function
        .@"return", .return_tail => "`return`",
        .try_op => "`?`",
        .@"break", .@"continue" => blk: {
            const label = if (c.ast.kind(n) == .@"break") c.ast.data(n).@"break".label else c.ast.data(n).@"continue".label;
            const inside = if (label) |t| for (labels.items) |l| {
                if (std.mem.eql(u8, l, c.ast.tokenSlice(t))) break true;
            } else false else depth > 0;
            if (inside) return children(c, n, depth, labels);
            break :blk if (c.ast.kind(n) == .@"break") "`break`" else "`continue`";
        },
        .@"defer", .@"errdefer" => {
            try c.reportAt(c.ast.mainToken(n), .E0360, &.{"move it out of the deferred statement"}, "a deferred statement cannot register further defers", .{});
            return children(c, n, depth, labels);
        },
        .loop, .@"while", .@"for", .for_inline => return children(c, n, depth + 1, labels),
        .labeled => {
            try labels.append(c.arena, c.ast.tokenSlice(c.ast.mainToken(n)));
            defer _ = labels.pop();
            return children(c, n, depth, labels);
        },
        else => return children(c, n, depth, labels),
    };
    try c.reportAt(c.ast.mainToken(n), .E0360, &.{"deferred code runs while control already leaves the block; decide before the `defer`"}, "{s} cannot leave a deferred statement", .{what});
    return children(c, n, depth, labels);
}

fn children(c: *Checker, n: Node.Index, depth: u32, labels: *std.ArrayList([]const u8)) Error!void {
    switch (c.ast.data(n)) {
        inline else => |p| inline for (@typeInfo(@TypeOf(p)).@"struct".field_names) |name| {
            const v = @field(p, name);
            switch (@TypeOf(v)) {
                Node.Index => try contained(c, v, depth, labels),
                ?Node.Index => if (v) |x| try contained(c, x, depth, labels),
                []const Node.Index => for (v) |x| try contained(c, x, depth, labels),
                ?[]const Node.Index => if (v) |xs| for (xs) |x| try contained(c, x, depth, labels),
                else => {}, // token slots
            }
        },
    }
}

fn isResult(types: *Types, ty: Types.TypeId) bool {
    return switch (types.get(ty)) {
        .nominal => |nm| nm.lang == .result,
        else => false,
    };
}

/// `return tail f(args);` (§6.9).
pub fn returnTail(c: *Checker, s: Node.Index) Error!bool {
    const call = c.ast.data(s).return_tail.call;
    const ret = c.sig.ret;
    const v = try check_expr.check(c, call, ret);
    if (v.ty == .err or v.ty == .noreturn or ret == .err) return true;
    if (v.ty != ret) {
        try c.reportAt(@import("check_stmt.zig").firstToken(c.ast, call), .E0310, &.{"`return tail` needs a callee returning exactly the function's type"}, "mismatched types: expected `{s}`, found `{s}`", .{ try c.tyName(ret), try c.tyName(v.ty) });
        return true;
    }
    const at = c.ast.mainToken(s);
    if (c.scopes.items.len > 0) {
        try c.reportAt(at, .E0363, &.{"drop the `tail`, or run the deferred code before the call"}, "`return tail` cannot reuse the frame: a `defer` or `errdefer` is pending", .{});
        return true;
    }
    if (c.failed) return true;
    const insts = c.b.blocks.items[c.b.block.int()].items;
    const op = c.b.insts.items(.op)[v.ref.int()];
    if ((op != .call and op != .call_indirect) or insts[insts.len - 1] != v.ref) {
        try c.reportAt(at, .E0363, &.{}, "`return tail` needs a function call", .{});
        return true;
    }
    const args = if (op == .call) c.b.data(v.ref).call.args else c.b.data(v.ref).call_indirect.args;
    for (args) |a| if (frameView(c, a)) {
        try c.reportAt(at, .E0363, &.{"pass a copy, or a view of a parameter, instead"}, "`return tail` cannot reuse the frame: an argument views a local of the current frame", .{});
        return true;
    };
    // `call` and `ret_tail` (and the indirect pair) have the same payload.
    c.b.insts.items(.op)[v.ref.int()] = if (op == .call) .ret_tail else .ret_tail_indirect;
    c.b.insts.items(.ty)[v.ref.int()] = .void;
    return true;
}

/// Whether argument `r` is a view of storage in the current frame: a local
/// or by-value parameter, not a `mut` parameter (the caller's place) nor
/// the elements of a view-typed local.
// shortcut: a view loaded from a local (`let s = buf[..]; ... s`) is not traced to its origin, upgrade with view origins (T081)
fn frameView(c: *Checker, r: Ref) bool {
    const b = &c.b;
    var x = r;
    var viewed = false;
    while (true) switch (b.data(x)) {
        .coerce => |d| x = d.value,
        .view => |d| {
            x = d.place;
            viewed = true;
        },
        .view_mut => |d| {
            x = d.place;
            viewed = true;
        },
        .slice => |d| {
            x = d.base;
            viewed = true;
        },
        .field => |d| x = d.base,
        .index => |d| x = d.base,
        .variant_field => |d| x = d.base,
        .local => |d| {
            const l = d.local.int();
            const ty = b.locals.items(.ty)[l];
            const view_ty = ty == .str or switch (c.types.get(ty)) {
                .slice, .soa_slice, .mut_view => true,
                else => false,
            };
            return viewed and !view_ty and b.locals.items(.kind)[l] != .param_mut;
        },
        else => return false,
    };
}

// ---------------------------------------------------------------------------
// Expansion

/// A registered body not yet run.
const Pending = struct { scope: Ref, body: tir.Block, err_only: bool };

/// `f` with its defers materialized: every `defer` body, and every
/// `errdefer` body on an error route, is cloned after each `scope_end` of
/// its scope, innermost registration first. The result has no `defer`,
/// `errdefer` or `defer_end`; `scope_begin`/`scope_end` stay as plain scope
/// boundaries (`unsafe.zig` marks blocks with them). Blocks unreachable
/// from the entry are dropped. Memory comes from `arena`.
pub fn expand(arena: Allocator, f: *const tir.Func) Allocator.Error!tir.Func {
    for (f.insts.items(.op)) |op| {
        if (op == .@"defer" or op == .@"errdefer") break;
    } else return f.*;
    var x: Expander = .{ .f = f, .b = .init(arena, f.ret), .map = try arena.alloc(Ref, f.insts.len), .heads = try arena.alloc(tir.Block, f.blocks.len) };
    @memset(x.map, .none);
    @memset(x.heads, .none);
    for (0..f.locals.len) |i| try x.b.locals.append(arena, f.locals.get(i));
    x.b.param_count = f.param_count;
    _ = try x.head(.from(0), &.{});
    while (x.work.pop()) |w| try x.block(w.old, w.pending);
    return x.b.finish();
}

const Expander = struct {
    f: *const tir.Func,
    b: Builder,
    /// New ref of each old instruction outside defer bodies.
    map: []Ref,
    /// First new block of each old block, once reached.
    heads: []tir.Block,
    work: std.ArrayList(Work) = .empty,
    /// The clone being made, if any: refs and blocks of the body region.
    clone: ?*Clone = null,
    /// Holds a returned `Result` whose tag decides an error route.
    tmp: tir.Local = .none,

    const Work = struct { old: tir.Block, pending: []const Pending };

    const Clone = struct {
        refs: std.AutoHashMapUnmanaged(Ref, Ref) = .empty,
        blocks: std.AutoHashMapUnmanaged(tir.Block, tir.Block) = .empty,
        work: std.ArrayList(tir.Block) = .empty,
        /// Where `defer_end` continues.
        cont: tir.Block,
    };

    /// The new block for old block `old`, reached with `pending` registered.
    /// Blocks are copied after a predecessor, so the definitions a block
    /// uses (in its dominators) are mapped before it.
    fn head(x: *Expander, old: tir.Block, pending: []const Pending) Allocator.Error!tir.Block {
        if (x.heads[old.int()] == .none) {
            x.heads[old.int()] = try x.b.addBlock();
            try x.work.append(x.b.arena, .{ .old = old, .pending = try x.b.arena.dupe(Pending, pending) });
        }
        return x.heads[old.int()];
    }

    fn block(x: *Expander, old: tir.Block, entry: []const Pending) Allocator.Error!void {
        var pending: std.ArrayList(Pending) = .empty;
        try pending.appendSlice(x.b.arena, entry);
        x.b.setBlock(x.heads[old.int()]);
        const term = x.f.data(x.f.terminator(old));
        for (x.f.blockInsts(old)) |r| switch (x.f.data(r)) {
            .@"defer" => |d| try pending.append(x.b.arena, .{ .scope = d.scope, .body = d.body, .err_only = false }),
            .@"errdefer" => |d| try pending.append(x.b.arena, .{ .scope = d.scope, .body = d.body, .err_only = true }),
            .scope_end => |d| {
                try x.copy(r, pending.items);
                while (pending.items.len > 0 and pending.getLast().scope == d.scope) {
                    const p = pending.pop().?;
                    if (!p.err_only) {
                        try x.run(p.body);
                    } else if (term == .ret) if (term.ret.value) |v| switch (x.f.data(v)) {
                        .variant => |vr| if (vr.variant == 1) try x.run(p.body),
                        else => try x.runIfErr(v, p.body),
                    };
                }
            },
            else => try x.copy(r, pending.items),
        };
    }

    /// Clones body region `body` at the insertion point, then continues
    /// after it in a new block.
    fn run(x: *Expander, body: tir.Block) Allocator.Error!void {
        var cl: Clone = .{ .cont = try x.b.addBlock() };
        x.clone = &cl;
        defer x.clone = null;
        _ = try x.b.add(.void, .{ .br = .{ .target = try x.mapBlock(body, &.{}), .args = &.{} } });
        while (cl.work.pop()) |old| {
            x.b.setBlock(cl.blocks.get(old).?);
            for (x.f.blockInsts(old)) |r| try x.copy(r, &.{});
        }
        x.b.setBlock(cl.cont);
    }

    /// `run(body)` when the returned `Result` `value` is `.err` (tag 1, §14.1).
    fn runIfErr(x: *Expander, value: Ref, body: tir.Block) Allocator.Error!void {
        const res = x.f.typeOf(value);
        if (x.tmp == .none) x.tmp = try x.b.addLocal(.{ .ty = res, .name = .none, .kind = .temp });
        _ = try x.b.add(.void, .{ .store = .{ .place = try x.b.add(res, .{ .local = .{ .local = x.tmp } }), .value = x.ref(value) } });
        const tag_ty: Types.TypeId = .int(.unsigned, 8);
        const tag = try x.b.add(tag_ty, .{ .enum_tag = .{ .place = try x.b.add(res, .{ .local = .{ .local = x.tmp } }) } });
        const is_err = try x.b.add(.bool, .{ .eq = .{ .lhs = tag, .rhs = try x.b.add(tag_ty, .{ .int = .{ .value = 1 } }) } });
        const yes = try x.b.addBlock();
        const join = try x.b.addBlock();
        _ = try x.b.add(.void, .{ .cond_br = .{ .cond = is_err, .then = yes, .@"else" = join } });
        x.b.setBlock(yes);
        try x.run(body);
        _ = try x.b.add(.void, .{ .br = .{ .target = join, .args = &.{} } });
        x.b.setBlock(join);
    }

    fn ref(x: *Expander, r: Ref) Ref {
        if (x.clone) |cl| if (cl.refs.get(r)) |n| return n;
        return x.map[r.int()];
    }

    fn mapBlock(x: *Expander, old: tir.Block, pending: []const Pending) Allocator.Error!tir.Block {
        const cl = x.clone orelse return x.head(old, pending);
        const gop = try cl.blocks.getOrPut(x.b.arena, old);
        if (!gop.found_existing) {
            gop.value_ptr.* = try x.b.addBlock();
            try cl.work.append(x.b.arena, old);
        }
        return gop.value_ptr.*;
    }

    /// Appends a copy of old instruction `r` with operands and targets
    /// mapped; `defer_end` of a clone becomes its `br` to the continuation.
    fn copy(x: *Expander, r: Ref, pending: []const Pending) Allocator.Error!void {
        const a = x.b.arena;
        x.b.node = x.f.nodeOf(r);
        var d = x.f.data(r);
        switch (d) {
            inline else => |*p| inline for (@typeInfo(@TypeOf(p.*)).@"struct".field_names) |name| {
                const v = &@field(p, name);
                switch (@TypeOf(v.*)) {
                    Ref => v.* = x.ref(v.*),
                    ?Ref => if (v.*) |o| {
                        v.* = x.ref(o);
                    },
                    []const Ref => {
                        const l = try a.alloc(Ref, v.len);
                        for (l, v.*) |*n, o| n.* = x.ref(o);
                        v.* = l;
                    },
                    tir.Block => v.* = try x.mapBlock(v.*, pending),
                    []const tir.Case => {
                        const l = try a.alloc(tir.Case, v.len);
                        for (l, v.*) |*n, o| n.* = .init(o.key(), try x.mapBlock(o.block, pending));
                        v.* = l;
                    },
                    else => {},
                }
            },
        }
        if (d == .defer_end) d = .{ .br = .{ .target = x.clone.?.cont, .args = &.{} } };
        const ty = x.f.typeOf(r);
        const n = if (d == .block_param) try x.b.addBlockParam(x.b.block, ty) else try x.b.add(ty, d);
        if (x.clone) |cl| try cl.refs.put(a, r, n) else x.map[r.int()] = n;
    }
};

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const dump = @import("../tir/dump.zig");

/// The dump of function `name` of `f` after `expand`.
fn expandedDump(f: *emit_tir.Fixture, name: []const u8) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const e = try expand(arena.allocator(), try f.func(name));
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try dump.dump(&e, &f.types, name, &out.writer);
    return out.toOwnedSlice();
}

fn expectExpanded(f: *emit_tir.Fixture, name: []const u8, want: []const u8) !void {
    const s = try expandedDump(f, name);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings(want, s);
}

/// The number of instructions of `func` with opcode `op`.
fn count(func: *const tir.Func, op: tir.Op) usize {
    var n: usize = 0;
    for (func.insts.items(.op)) |o| n += @intFromBool(o == op);
    return n;
}

test "every exit ends the scope; expansion runs the defer there" {
    var f: emit_tir.Fixture = undefined;
    try f.init(
        \\fn log(x: u32) {}
        \\fn exits(flag: bool) -> u32 {
        \\    defer log(1);
        \\    if flag { return 2; }
        \\    0
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    // Checking: a `scope_end` on the `return` and at the end of the block.
    try f.expectDump("exits",
        \\fn exits(l0 flag: bool) -> u32 {
        \\b0:
        \\  %0 = scope_begin
        \\  defer %0, b1
        \\  %5: bool = local l0
        \\  %6: bool = load %5
        \\  cond_br %6, b2, b3
        \\b1:
        \\  %2: u32 = int 1
        \\  call @0, [%2]
        \\  defer_end
        \\b2:
        \\  %8: u32 = int 2
        \\  scope_end %0
        \\  ret %8
        \\b3:
        \\  br b4, []
        \\b4:
        \\  scope_end %0
        \\  %13: u32 = int 0
        \\  ret %13
        \\}
        \\
    );
    try expectExpanded(&f, "exits",
        \\fn exits(l0 flag: bool) -> u32 {
        \\b0:
        \\  %0 = scope_begin
        \\  %1: bool = local l0
        \\  %2: bool = load %1
        \\  cond_br %2, b1, b2
        \\b1:
        \\  %12: u32 = int 2
        \\  scope_end %0
        \\  br b7, []
        \\b2:
        \\  br b3, []
        \\b3:
        \\  scope_end %0
        \\  br b5, []
        \\b4:
        \\  %10: u32 = int 0
        \\  ret %10
        \\b5:
        \\  %7: u32 = int 1
        \\  call @0, [%7]
        \\  br b4, []
        \\b6:
        \\  ret %12
        \\b7:
        \\  %15: u32 = int 1
        \\  call @0, [%15]
        \\  br b6, []
        \\}
        \\
    );
}

test "errdefer runs on `?` and on a returned `.err`, tested at run time if not constant" {
    var f: emit_tir.Fixture = undefined;
    try f.init(
        \\pub enum E { bad }
        \\fn log(x: u32) {}
        \\fn get(ok: bool) -> Result<u32, E> { if ok { .ok(1) } else { .err(.bad) } }
        \\fn errs(ok: bool) -> Result<u32, E> {
        \\    errdefer log(2);
        \\    let v = get(ok)?;
        \\    get(ok)
        \\}
        \\fn fine() -> Result<u32, E> {
        \\    errdefer log(2);
        \\    .ok(1)
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    // `?` returns a constant `.err`; the tail's `Result` is tested.
    try expectExpanded(&f, "errs",
        \\fn errs(l0 ok: bool) -> Result<u32, E> {
        \\  l1 : Result<u32, E>
        \\  l2 v: u32
        \\  l3 : Result<u32, E>
        \\b0:
        \\  %0 = scope_begin
        \\  %1: bool = local l0
        \\  %2: bool = load %1
        \\  %3: Result<u32, E> = call @1, [%2]
        \\  %4: Result<u32, E> = local l1
        \\  store %4, %3
        \\  %6: Result<u32, E> = local l1
        \\  %7: u8 = enum_tag %6
        \\  %8: u8 = int 0
        \\  %9: bool = eq %7, %8
        \\  cond_br %9, b1, b2
        \\b1:
        \\  %21: Result<u32, E> = local l1
        \\  %22: u32 = variant_field %21, 0, 0
        \\  %23: u32 = load %22
        \\  %24: u32 = local l2
        \\  store %24, %23
        \\  %26: bool = local l0
        \\  %27: bool = load %26
        \\  %28: Result<u32, E> = call @1, [%27]
        \\  scope_end %0
        \\  %30: Result<u32, E> = local l3
        \\  store %30, %28
        \\  %32: Result<u32, E> = local l3
        \\  %33: u8 = enum_tag %32
        \\  %34: u8 = int 1
        \\  %35: bool = eq %33, %34
        \\  cond_br %35, b5, b6
        \\b2:
        \\  %11: Result<u32, E> = local l1
        \\  %12: E = variant_field %11, 1, 0
        \\  %13: E = load %12
        \\  %14: Result<u32, E> = variant 1, [%13]
        \\  scope_end %0
        \\  br b4, []
        \\b3:
        \\  ret %14
        \\b4:
        \\  %17: u32 = int 2
        \\  call @0, [%17]
        \\  br b3, []
        \\b5:
        \\  br b8, []
        \\b6:
        \\  ret %28
        \\b7:
        \\  br b6, []
        \\b8:
        \\  %38: u32 = int 2
        \\  call @0, [%38]
        \\  br b7, []
        \\}
        \\
    );
    // A constant `.ok` discards the errdefer.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const e = try expand(arena.allocator(), try f.func("fine"));
    try testing.expectEqual(0, count(&e, .call));
    try testing.expectEqual(0, count(&e, .@"errdefer"));
}

test "a loop body's defers run on `continue`, `break` and the end of each iteration" {
    var f: emit_tir.Fixture = undefined;
    try f.init(
        \\fn log(x: u32) {}
        \\fn spin() {
        \\    let mut i: u32 = 0;
        \\    while i < 3 {
        \\        if i == 7 { continue; }
        \\        defer log(i);
        \\        i += 1;
        \\        if i == 2 { continue; }
        \\        if i == 9 { break; }
        \\    }
        \\    outer: loop {
        \\        defer log(0);
        \\        loop { break :outer; }
        \\    }
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    const func = try f.func("spin");
    // The `continue` before the `defer` has nothing to run.
    try testing.expectEqual(4, count(func, .scope_end));
    try testing.expectEqual(2, count(func, .@"defer"));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const e = try expand(arena.allocator(), func);
    try testing.expectEqual(4, count(&e, .call));
    try testing.expectEqual(0, count(&e, .@"defer") + count(&e, .defer_end));
}

test "return tail emits ret_tail" {
    var f: emit_tir.Fixture = undefined;
    try f.init(
        \\fn down(n: u32) -> u32 { if n == 0 { return 0; } return tail down(n - 1); }
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    const func = try f.func("down");
    try testing.expectEqual(1, count(func, .ret_tail));
    try testing.expectEqual(0, count(func, .call));
}

test "E0360, E0362, E0363" {
    var f: emit_tir.Fixture = undefined;
    try f.init(
        \\pub enum E { bad }
        \\fn log() {}
        \\fn a(xs: []u32) -> u32 {
        \\    defer { outer: for x in xs { for y in xs { if y == 0 { continue :outer; } break; } } }
        \\    defer { defer log(); }
        \\    for x in xs { defer { continue; } }
        \\    0
        \\}
        \\fn b() -> u32 { errdefer log(); 0 }
        \\fn c(n: u32) -> u32 {
        \\    let mut k = n;
        \\    return tail c(k);
        \\}
        \\fn d(mut k: u32) -> u32 { return tail d(mut k); }
        \\fn e(mut k: u32) -> u32 { let mut j: u32 = 0; return tail d(mut j); }
        \\fn g(n: u32) -> u64 { return tail c(n); }
    );
    defer f.deinit();
    try f.expectDiags(&.{
        .{ .E0360, "defer" },
        .{ .E0360, "continue" },
        .{ .E0362, "errdefer" },
        .{ .E0363, "return" },
        .{ .E0310, "c" },
    });
}
