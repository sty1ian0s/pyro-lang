//! Comptime interpreter, part B (§8.1, §8.6, B.4): a register machine over
//! the TIR CFG. It runs function bodies (`emit_tir.Bodies`), handles calls,
//! recursion, `match` (lowered to `enum_tag`, `switch_br` and
//! `variant_field`), places, `defer`/`errdefer` scope markers, and reports
//! traps as compile errors carrying the comptime stack trace. The value
//! operations themselves are `interp_expr.zig`'s.
//!
//! - Every instruction of a frame has one register (`Reg`): a value, or a
//!   place (storage path) for place instructions and `mut` views.
//! - Locals are registers too. A `mut` parameter's local holds the caller's
//!   place (`tir.LocalKind.param_mut`), so writes through it reach the
//!   caller's storage.
//! - Values are immutable (`value.zig`); a store rebuilds the members on the
//!   path from the root (copy on write), so a loaded copy never changes.
//! - Calls do not recurse on the host stack: frames live on an explicit
//!   stack, so deep comptime recursion is bounded only by memory and the
//!   budget (§8.6, T059). `return tail` reuses the frame.
//! - Defers (§6.8) run at `scope_end` in LIFO order: the pending body runs
//!   and the `scope_end` executes again for the next one. Interpretation of
//!   §6.8.2: a `scope_end` is on an error route when its block ends in a
//!   `ret` whose value, already computed, is `Result`'s `.err`; only then do
//!   the scope's `errdefer`s run, otherwise they are discarded.
//! - Traps do not run defers (§6.8.1): evaluation stops and `interp_expr.report`
//!   emits the trap with the trace, innermost call first. The trap
//!   diagnostic has no A.3 code (spec gap noted in `interp_expr.report`).
//!
//! Frame memory comes from `gpa` and is freed on return; values come from
//! the evaluation arena (`Interp.arena`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const diag = @import("../diag/diag.zig");
const Types = @import("../sema/types.zig");
const tir = @import("../tir/tir.zig");
const emit_tir = @import("../sema/emit_tir.zig");
const interp_expr = @import("interp_expr.zig");
const Value = @import("value.zig").Value;

const Interp = interp_expr.Interp;
const TypeId = Types.TypeId;
const Ref = tir.Ref;

pub const Error = Allocator.Error || error{
    /// A trap was reached and reported to the sink.
    Trapped,
    /// The evaluation reached something the interpreter cannot run yet;
    /// `Machine.unsupported` says what. Nothing was reported.
    Unsupported,
};

/// The errors of one instruction; `call` reports a trap.
const StepError = interp_expr.Error || error{Unsupported};

/// One step of a place: member `i` of an aggregate, slice or `str`, or
/// payload field `i` of the current variant of an enum.
const Step = union(enum) { member: u32, payload: u32 };

/// Storage: a register and a path into its value.
const Place = struct {
    root: *Reg,
    path: []const Step = &.{},
};

/// The register of an instruction or local.
const Reg = union(enum) {
    /// Not yet written.
    none,
    value: Value,
    /// A place instruction, or a `mut` view of a place.
    place: Place,
};

/// A defer body registered in a scope (§6.8).
const Pending = struct { scope: Ref, body: tir.Block, err_only: bool };

/// Where a running defer body returns to: its `scope_end`.
const Resume = struct { block: tir.Block, pc: u32 };

const Frame = struct {
    id: tir.FnId,
    func: *const tir.Func,
    /// One per instruction of `func`.
    regs: []Reg,
    /// One per local of `func`; parameters first.
    locals: []Reg,
    block: tir.Block = .from(0),
    /// Index of the current instruction in `block`.
    pc: u32 = 0,
    pending: std.ArrayList(Pending) = .empty,
    resume_at: std.ArrayList(Resume) = .empty,

    fn at(f: *const Frame) Ref {
        return f.func.blockInsts(f.block)[f.pc];
    }
};

/// What executing one instruction did.
const Next = union(enum) {
    /// Go on with the next instruction.
    next,
    /// Control moved (branch, call, defer body); the frame is set.
    moved,
    /// The top frame returned this.
    ret: Reg,
};

/// The comptime register machine of one evaluation.
pub const Machine = struct {
    /// Value operations; results live in `in.arena`.
    in: Interp,
    /// Frames and scratch; freed as they end.
    gpa: Allocator,
    bodies: *const emit_tir.Bodies,
    sink: *diag.Sink,
    /// Frames outside the evaluation (`in the initializer of N`), appended
    /// to every trace after the call frames.
    outer: []const diag.TraceFrame = &.{},
    /// What the last `error.Unsupported` reached, with its owning task.
    unsupported: ?[]const u8 = null,
    frames: std.ArrayList(*Frame) = .empty,
    scratch: std.ArrayList(Reg) = .empty,

    pub fn deinit(m: *Machine) void {
        while (m.frames.items.len > 0) m.pop();
        m.frames.deinit(m.gpa);
        m.scratch.deinit(m.gpa);
        m.* = undefined;
    }

    /// Calls function `callee` with `args` (one value per parameter, no
    /// `mut` parameters) and returns its result, allocated in the
    /// evaluation arena.
    pub fn call(m: *Machine, callee: tir.FnId, args: []const Value) Error!Value {
        const regs = try m.gpa.alloc(Reg, args.len);
        defer m.gpa.free(regs);
        for (regs, args) |*r, a| r.* = .{ .value = a };
        const base = m.frames.items.len;
        errdefer while (m.frames.items.len > base) m.pop();
        try m.push(callee, regs);
        while (true) {
            const f = m.frames.getLast();
            const r = f.at();
            const next = m.step(f, r) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Unsupported => return error.Unsupported,
                else => |t| {
                    try m.reportTrap(t);
                    return error.Trapped;
                },
            };
            switch (next) {
                .next => f.pc += 1,
                .moved => {},
                .ret => |res| {
                    m.pop();
                    if (m.frames.items.len == base) return switch (res) {
                        .value => |v| v,
                        else => m.fail("views returned by a comptime evaluation (T060)"),
                    };
                    const caller = m.frames.getLast();
                    caller.regs[caller.at().int()] = res;
                    caller.pc += 1;
                },
            }
        }
    }

    fn fail(m: *Machine, what: []const u8) error{Unsupported} {
        m.unsupported = what;
        return error.Unsupported;
    }

    fn types(m: *const Machine) *Types {
        return m.in.items.types;
    }

    // -----------------------------------------------------------------------
    // Frames

    fn push(m: *Machine, id: tir.FnId, args: []const Reg) (Allocator.Error || error{Unsupported})!void {
        const func = if (m.bodies.fns.items[id.int()].func) |*fx| fx else return m.fail("calls to functions without checked bodies (T060)");
        const f = try m.gpa.create(Frame);
        errdefer m.gpa.destroy(f);
        const regs = try m.gpa.alloc(Reg, func.insts.len);
        errdefer m.gpa.free(regs);
        const locals = try m.gpa.alloc(Reg, func.locals.len);
        @memset(regs, .none);
        @memset(locals, .none);
        @memcpy(locals[0..args.len], args);
        f.* = .{ .id = id, .func = func, .regs = regs, .locals = locals };
        try m.frames.append(m.gpa, f);
    }

    fn pop(m: *Machine) void {
        const f = m.frames.pop().?;
        m.gpa.free(f.regs);
        m.gpa.free(f.locals);
        f.pending.deinit(m.gpa);
        f.resume_at.deinit(m.gpa);
        m.gpa.destroy(f);
    }

    /// The registers of `refs` copied to `m.scratch`, so that a frame can
    /// be replaced or block parameters overwritten.
    fn gather(m: *Machine, f: *const Frame, refs: []const Ref) Allocator.Error![]Reg {
        m.scratch.clearRetainingCapacity();
        for (refs) |r| try m.scratch.append(m.gpa, f.regs[r.int()]);
        return m.scratch.items;
    }

    /// The function a `fn_ref` value names.
    fn fnOf(m: *Machine, v: Value) error{Unsupported}!tir.FnId {
        const r = v.data.fn_ref;
        return m.bodies.ids.get(.{ r.module, r.node }) orelse m.fail("calls to functions without checked bodies (T060)");
    }

    // -----------------------------------------------------------------------
    // Places

    fn val(f: *const Frame, r: Ref) Value {
        return f.regs[r.int()].value;
    }

    fn placeOf(f: *const Frame, r: Ref) Place {
        return f.regs[r.int()].place;
    }

    /// The register stored at `p`.
    fn load(p: Place) Reg {
        if (p.path.len == 0) return p.root.*;
        var v = p.root.value;
        for (p.path) |s| v = switch (s) {
            .member => |i| Interp.extract(v, i),
            .payload => |i| v.data.variant.payload[i],
        };
        return .{ .value = v };
    }

    fn loadValue(p: Place) Value {
        return load(p).value;
    }

    /// `p` extended by `s`.
    fn sub(m: *Machine, p: Place, s: Step) Allocator.Error!Place {
        const path = try m.in.arena.alloc(Step, p.path.len + 1);
        @memcpy(path[0..p.path.len], p.path);
        path[p.path.len] = s;
        return .{ .root = p.root, .path = path };
    }

    fn store(m: *Machine, p: Place, r: Reg) Allocator.Error!void {
        p.root.* = if (p.path.len == 0) r else .{ .value = try m.replace(p.root.value, p.path, r.value) };
    }

    /// `v` with the member at `path` replaced by `new`.
    // shortcut: copies every member on the path per store (O(n) for an array element); add in-place stores to uniquely owned values if comptime array loops get slow.
    fn replace(m: *Machine, v: Value, path: []const Step, new: Value) Allocator.Error!Value {
        if (path.len == 0) return new;
        switch (path[0]) {
            .payload => |i| {
                const x = v.data.variant;
                const payload = try m.in.arena.dupe(Value, x.payload);
                payload[i] = try m.replace(payload[i], path[1..], new);
                return .{ .ty = v.ty, .data = .{ .variant = .{ .index = x.index, .payload = payload } } };
            },
            .member => |i| {
                const n: usize = @intCast(Interp.len(v).data.scalar);
                const elems = try m.in.arena.alloc(Value, n);
                for (elems, 0..) |*e, k| e.* = Interp.extract(v, @intCast(k));
                elems[i] = try m.replace(elems[i], path[1..], new);
                return .{ .ty = v.ty, .data = if (v.data == .slice) .{ .slice = elems } else .{ .aggregate = elems } };
            },
        }
    }

    // -----------------------------------------------------------------------
    // Instructions

    fn step(m: *Machine, f: *Frame, r: Ref) StepError!Next {
        const func = f.func;
        const ty = func.typeOf(r);
        const in = &m.in;
        const out = &f.regs[r.int()];
        const d = func.data(r);
        const v: Value = switch (d) {
            .int => |x| .{ .ty = ty, .data = .{ .scalar = x.value } },
            .float => |x| if (in.base(ty) == .f32)
                .{ .ty = ty, .data = Value.float(.f32, @bitCast(x.bits)).data }
            else
                .{ .ty = ty, .data = .{ .scalar = x.bits } },
            .str => |x| .{ .ty = ty, .data = .{ .str = m.types().strings.get(x.string) } },
            .type => |x| .{ .ty = ty, .data = .{ .type = x.value } },
            .fn_ref => |x| blk: {
                const b = m.bodies.fns.items[x.func.int()];
                break :blk .{ .ty = ty, .data = .{ .fn_ref = .{ .module = b.module, .node = b.node } } };
            },
            .block_param, .scope_begin => return .next,

            .local => |x| {
                const slot = &f.locals[x.local.int()];
                out.* = if (func.local(x.local).kind == .param_mut) slot.* else .{ .place = .{ .root = slot } };
                return .next;
            },
            .deref => |x| switch (f.regs[x.ptr.int()]) {
                .place => {
                    out.* = f.regs[x.ptr.int()];
                    return .next;
                },
                else => return m.fail("raw pointers at comptime (E0805, T059)"),
            },
            .field => |x| {
                out.* = .{ .place = try m.sub(placeOf(f, x.base), .{ .member = x.index }) };
                return .next;
            },
            .index => |x| {
                const base = placeOf(f, x.base);
                const i = val(f, x.index).data.scalar;
                if (i >= Interp.len(loadValue(base)).data.scalar) return error.OutOfBounds;
                out.* = .{ .place = try m.sub(base, .{ .member = @intCast(i) }) };
                return .next;
            },
            .variant_field => |x| {
                out.* = .{ .place = try m.sub(placeOf(f, x.base), .{ .payload = x.index }) };
                return .next;
            },
            inline .load, .move => |x| {
                out.* = load(placeOf(f, x.place));
                return .next;
            },
            .view => |x| blk: {
                const pv = loadValue(placeOf(f, x.place));
                // An array viewed as a slice (§4.9.1); other views read the place.
                const to_slice = m.types().get(in.base(ty)) == .slice and pv.data != .slice;
                break :blk if (to_slice) try in.slice(ty, pv, null, null) else pv;
            },
            .view_mut => |x| {
                out.* = f.regs[x.place.int()];
                return .next;
            },
            .store => |x| {
                try m.store(placeOf(f, x.place), f.regs[x.value.int()]);
                return .next;
            },

            inline .add, .sub, .mul, .div, .rem, .bit_and, .bit_or, .bit_xor, .shl, .shr, .eq, .ne, .lt, .le, .gt, .ge => |x| try in.binary(func.op(r), ty, val(f, x.lhs), val(f, x.rhs)),
            inline .neg, .bit_not, .not => |x| try in.unary(func.op(r), val(f, x.operand)),
            .splat => |x| try in.splat(ty, val(f, x.scalar)),
            .swizzle => |x| try in.swizzle(ty, val(f, x.vec), x.lanes),
            .cast => |x| blk: {
                const a = val(f, x.value);
                const backing: TypeId = if (in.items.enumOf(a.ty)) |e| e.backing else .none;
                break :blk try in.cast(a, ty, backing);
            },
            .coerce => |x| switch (f.regs[x.value.int()]) {
                // `mut T` to a `T` view (§4.9.1): the value it refers to.
                .place => |p| loadValue(p),
                else => try in.coerce(val(f, x.value), ty),
            },
            .aggregate => |x| blk: {
                const elems = try in.arena.alloc(Value, x.elems.len);
                for (elems, x.elems) |*e, a| e.* = val(f, a);
                break :blk .{ .ty = ty, .data = .{ .aggregate = elems } };
            },
            .repeat => |x| try in.repeat(ty, val(f, x.value)),
            .variant => |x| blk: {
                const payload = try in.arena.alloc(Value, x.payload.len);
                for (payload, x.payload) |*e, a| e.* = val(f, a);
                break :blk try in.variant(ty, x.variant, payload);
            },
            .extract => |x| Interp.extract(val(f, x.value), x.index),
            .enum_tag => |x| in.enumTag(ty, loadValue(placeOf(f, x.place))),
            .len => |x| Interp.len(m.valueOrPlace(f, x.value)),
            .slice => |x| try in.slice(
                ty,
                loadValue(placeOf(f, x.base)),
                if (x.lo) |lo| val(f, lo) else null,
                if (x.hi) |hi| val(f, hi) else null,
            ),

            .call => |x| return m.enter(f, x.callee, x.args),
            .call_indirect => |x| return m.enter(f, try m.fnOf(val(f, x.callee)), x.args),
            .ret_tail => |x| return m.tail(f, x.callee, x.args),
            .ret_tail_indirect => |x| return m.tail(f, try m.fnOf(val(f, x.callee)), x.args),

            .@"defer" => |x| return m.register(f, x.scope, x.body, false),
            .@"errdefer" => |x| return m.register(f, x.scope, x.body, true),
            .scope_end => |x| return m.scopeEnd(f, x.scope),
            .defer_end => {
                const at = f.resume_at.pop().?;
                f.block = at.block;
                f.pc = at.pc;
                return .moved;
            },

            .br => |x| return m.branch(f, x.target, x.args),
            .cond_br => |x| return m.branch(f, if (val(f, x.cond).data.scalar != 0) x.then else x.@"else", &.{}),
            .switch_br => |x| {
                const key = val(f, x.value).data.scalar;
                for (x.cases) |c| if (c.key() == key) return m.branch(f, c.block, &.{});
                return m.branch(f, x.default, &.{});
            },
            .ret => |x| return .{ .ret = if (x.value) |a| f.regs[a.int()] else .{ .value = .{ .ty = .void, .data = .void } } },

            .global, .@"comptime" => return m.fail("globals and comptime constants in comptime code (T060)"),
            .addr_of => return m.fail("raw pointers at comptime (E0805, T059)"),
            .builtin => return m.fail("builtin calls at comptime (T059)"),
            .nursery_begin, .spawn, .spawn_indirect, .nursery_end, .pfor_begin, .pfor_end, .launch => return m.fail("concurrency at comptime (E0805, T059)"),
            .@"unreachable" => return m.fail("`unreachable` reached at comptime"),
        };
        out.* = .{ .value = v };
        return .next;
    }

    fn valueOrPlace(_: *Machine, f: *const Frame, r: Ref) Value {
        return switch (f.regs[r.int()]) {
            .place => |p| loadValue(p),
            else => val(f, r),
        };
    }

    /// Jumps to `target`, binding its block parameters to `args`.
    fn branch(m: *Machine, f: *Frame, target: tir.Block, args: []const Ref) Allocator.Error!Next {
        const regs = try m.gather(f, args);
        for (regs, f.func.blockInsts(target)[0..regs.len]) |a, p| f.regs[p.int()] = a;
        f.block = target;
        f.pc = 0;
        return .moved;
    }

    /// Pushes the frame of a call to `callee`; its result lands in the
    /// caller's register of the call when it returns.
    fn enter(m: *Machine, f: *const Frame, callee: tir.FnId, args: []const Ref) StepError!Next {
        try m.push(callee, try m.gather(f, args));
        return .moved;
    }

    /// `return tail callee(args)` (§6.9): the call replaces frame `f`.
    fn tail(m: *Machine, f: *const Frame, callee: tir.FnId, args: []const Ref) StepError!Next {
        const regs = try m.gather(f, args);
        const owned = try m.gpa.dupe(Reg, regs);
        defer m.gpa.free(owned);
        m.pop();
        try m.push(callee, owned);
        return .moved;
    }

    fn register(m: *Machine, f: *Frame, scope: Ref, body: tir.Block, err_only: bool) Allocator.Error!Next {
        try f.pending.append(m.gpa, .{ .scope = scope, .body = body, .err_only = err_only });
        return .next;
    }

    /// Runs the innermost pending defer of `scope`, then comes back here;
    /// with none left, goes on.
    fn scopeEnd(m: *Machine, f: *Frame, scope: Ref) Allocator.Error!Next {
        while (f.pending.items.len > 0 and f.pending.getLast().scope == scope) {
            const p = f.pending.pop().?;
            if (p.err_only and !m.errorRoute(f)) continue;
            try f.resume_at.append(m.gpa, .{ .block = f.block, .pc = f.pc });
            f.block = p.body;
            f.pc = 0;
            return .moved;
        }
        return .next;
    }

    /// Whether the current block ends in a `ret` of a computed `.err` (§6.8.2).
    fn errorRoute(m: *Machine, f: *const Frame) bool {
        const d = f.func.data(f.func.terminator(f.block));
        const ret = if (d == .ret) d.ret.value orelse return false else return false;
        const v = switch (f.regs[ret.int()]) {
            .value => |v| v,
            else => return false,
        };
        const is_result = switch (m.types().get(v.ty)) {
            .nominal => |n| n.lang == .result,
            else => false,
        };
        return is_result and v.data == .variant and v.data.variant.index == 1;
    }

    // -----------------------------------------------------------------------
    // Traces

    /// The span of instruction `r` of frame `f`: the main token of its
    /// node, or of the function for synthesized code.
    fn span(m: *const Machine, f: *const Frame, r: Ref) diag.Span {
        const body = m.bodies.fns.items[f.id.int()];
        const mod = m.in.items.im.graph.modules[body.module];
        const node = f.func.nodeOf(r).unwrap() orelse body.node;
        const ast = mod.ast;
        const t = ast.mainToken(node);
        const start = ast.tokens.items(.start)[t];
        return .{ .file = mod.file, .start = start, .end = start + ast.tokens.items(.len)[t] };
    }

    /// Reports trap `t` at the current instruction of the top frame, with
    /// one trace frame per active call, innermost first, then `outer`.
    fn reportTrap(m: *Machine, t: interp_expr.Trap) Allocator.Error!void {
        const frames = m.frames.items;
        var trace: std.ArrayList(diag.TraceFrame) = .empty;
        defer {
            for (trace.items) |tf| m.gpa.free(tf.note);
            trace.deinit(m.gpa);
        }
        var i = frames.len - 1;
        while (i > 0) : (i -= 1) {
            const name = m.bodies.fns.items[frames[i].id.int()].name;
            const note = try std.fmt.allocPrint(m.gpa, "in call to `{s}`", .{name});
            errdefer m.gpa.free(note);
            try trace.append(m.gpa, .{ .span = m.span(frames[i - 1], frames[i - 1].at()), .note = note });
        }
        for (m.outer) |o| try trace.append(m.gpa, .{ .span = o.span, .note = try m.gpa.dupe(u8, o.note) });
        const top = frames[frames.len - 1];
        try interp_expr.report(m.sink, t, m.span(top, top.at()), trace.items);
    }
};

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const Builder = @import("../tir/builder.zig").Builder;

/// A checked package and a machine over it.
const Fixture = struct {
    f: emit_tir.Fixture,
    arena: std.heap.ArenaAllocator,
    sink: diag.Sink,
    m: Machine,

    fn init(x: *Fixture, src: []const u8) !void {
        try x.f.init(src);
        try x.f.expectDiags(&.{});
        try testing.expectEqual(null, x.f.bodies.unsupported);
        x.arena = .init(testing.allocator);
        x.sink = .init(testing.allocator, testing.io);
        x.m = .{ .in = .{ .items = &x.f.items, .arena = x.arena.allocator() }, .gpa = testing.allocator, .bodies = &x.f.bodies, .sink = &x.sink };
    }

    fn deinit(x: *Fixture) void {
        x.m.deinit();
        x.sink.deinit();
        x.arena.deinit();
        x.f.deinit();
    }

    fn id(x: *Fixture, name: []const u8) tir.FnId {
        return x.f.bodies.ids.get(.{ 0, x.f.bodies.find(0, name).?.node }).?;
    }

    fn run(x: *Fixture, name: []const u8, args: []const Value) Error!Value {
        return x.m.call(x.id(name), args);
    }

    fn int(x: *Fixture, ty: TypeId, v: i128) Value {
        return Value.int(&x.f.types, x.f.items.options.ptr_bits, ty, v).?;
    }

    fn ints(x: *Fixture, ty: TypeId, vs: []const i128) ![]const Value {
        const out = try x.arena.allocator().alloc(Value, vs.len);
        for (out, vs) |*o, v| o.* = x.int(ty, v);
        return out;
    }
};

const u32_t: TypeId = .int(.unsigned, 32);
const u64_t: TypeId = .int(.unsigned, 64);
const i32_t: TypeId = .int(.signed, 32);

test "recursion, loops, arrays, structs, match and mut parameters evaluate" {
    var x: Fixture = undefined;
    try x.init(
        \\fn fib(n: u64) -> u64 { if n < 2 { return n; } fib(n - 1) + fib(n - 2) }
        \\fn fact(n: u64) -> u64 { if n == 0 { 1 } else { n * fact(n - 1) } }
        \\fn sort(xs: [6]i32) -> [6]i32 {
        \\    let mut a = xs;
        \\    let mut i: usize = 1;
        \\    while i < 6 {
        \\        let mut j = i;
        \\        while j > 0 && a[j - 1] > a[j] { let t = a[j]; a[j] = a[j - 1]; a[j - 1] = t; j -= 1; }
        \\        i += 1;
        \\    }
        \\    a
        \\}
        \\fn squares() -> [5]u32 {
        \\    let mut a = [0u32; 5];
        \\    let mut i: usize = 0;
        \\    loop { if i == 5 { break a; } a[i] = (i * i) as u32; i += 1; }
        \\}
        \\enum Shape { dot, line(u16), rect(u16, u16) }
        \\fn area(s: Shape) -> u16 { match s { .dot => 0, .line(n) => n, .rect(w, h) => w * h } }
        \\fn areas() -> u16 { area(Shape.dot) + area(Shape.line(3)) + area(Shape.rect(4, 5)) }
        \\fn bump(mut x: u32, by: u32) { x += by; }
        \\struct P { x: u32, y: u32 }
        \\fn moved() -> u32 { let mut p = P { x: 1, y: 2 }; bump(mut p.x, 10); p.y = 7; p.x * 100 + p.y }
    );
    defer x.deinit();

    try testing.expect((try x.run("fib", &.{x.int(u64_t, 20)})).eql(x.int(u64_t, 6765)));
    try testing.expect((try x.run("fact", &.{x.int(u64_t, 20)})).eql(x.int(u64_t, 2432902008176640000)));
    const arr6 = try x.f.types.intern(.{ .array = .{ .len = 6, .elem = i32_t } });
    const unsorted: Value = .{ .ty = arr6, .data = .{ .aggregate = try x.ints(i32_t, &.{ 5, -1, 3, 3, 0, -7 }) } };
    const sorted = try x.run("sort", &.{unsorted});
    try testing.expect(sorted.eql(.{ .ty = arr6, .data = .{ .aggregate = try x.ints(i32_t, &.{ -7, -1, 0, 3, 3, 5 }) } }));
    try testing.expect(unsorted.data.aggregate[0].eql(x.int(i32_t, 5))); // the argument is a copy
    const sq = try x.run("squares", &.{});
    for (sq.data.aggregate, 0..) |e, i| try testing.expect(e.eql(x.int(u32_t, @intCast(i * i))));
    try testing.expect((try x.run("areas", &.{})).eql(x.int(.int(.unsigned, 16), 23)));
    try testing.expect((try x.run("moved", &.{})).eql(x.int(u32_t, 1107)));
    try testing.expectEqual(0, x.m.frames.items.len);
}

test "deep recursion runs on the frame stack, not the host stack" {
    var x: Fixture = undefined;
    try x.init("fn depth(n: u64) -> u64 { if n == 0 { 0 } else { 1 + depth(n - 1) } }");
    defer x.deinit();
    try testing.expect((try x.run("depth", &.{x.int(u64_t, 50_000)})).eql(x.int(u64_t, 50_000)));
}

test "bounds and division traps are compile errors with the comptime trace" {
    var x: Fixture = undefined;
    try x.init(
        \\fn get(a: [3]u32, i: usize) -> u32 { a[i] }
        \\fn sum(n: usize) -> u32 { let a = [1u32, 2, 3]; let mut s = 0u32; let mut i: usize = 0; while i <= n { s += get(a, i); i += 1; } s }
        \\fn ratio(a: i32, b: i32) -> i32 { a / b }
        \\fn mean(n: i32) -> i32 { ratio(10, n) }
    );
    defer x.deinit();
    const file: diag.FileId = @fromBackingInt(0);
    x.m.outer = &.{.{ .span = .{ .file = file, .start = 0, .end = 2 }, .note = "in the initializer of `N`" }};

    try testing.expect((try x.run("sum", &.{x.int(.usize, 2)})).eql(x.int(u32_t, 6)));
    try testing.expectError(error.Trapped, x.run("sum", &.{x.int(.usize, 3)}));
    try testing.expectEqual(0, x.m.frames.items.len);
    try testing.expectError(error.Trapped, x.run("mean", &.{x.int(i32_t, 0)}));

    const ds = x.sink.finish();
    try testing.expectEqual(2, ds.len);
    const src = x.f.p.asts[0].source;
    // The trap at its operator; the trace names the callee at its call site.
    const Want = struct { msg: []const u8, at: []const u8, note: []const u8, call: []const u8 };
    const want = [_]Want{
        .{ .msg = "comptime evaluation traps: index out of bounds", .at = "[", .note = "in call to `get`", .call = "get(a, i)" },
        .{ .msg = "comptime evaluation traps: division by zero", .at = "/", .note = "in call to `ratio`", .call = "ratio(10, n)" },
    };
    for (want, ds) |w, d| {
        try testing.expectEqual(null, d.code);
        try testing.expectEqualStrings(w.msg, d.message);
        const s = d.primarySpan().?;
        try testing.expectEqualStrings(w.at, src[s.start..s.end]);
        try testing.expectEqual(2, d.trace.len);
        try testing.expectEqualStrings(w.note, d.trace[0].note);
        const call_at = std.mem.indexOf(u8, src, w.call).?;
        try testing.expect(d.trace[0].span.start >= call_at and d.trace[0].span.end <= call_at + w.call.len);
        try testing.expectEqualStrings("in the initializer of `N`", d.trace[1].note);
    }
}

test "defers run LIFO at scope ends; errdefers only on an error return" {
    var x: Fixture = undefined;
    try x.init("fn d(fail: bool) -> u32 { 0 }");
    defer x.deinit();
    const a = x.arena.allocator();

    // fn(fail: bool) -> Result<u32, u32> {
    //     let mut acc = 0;
    //     { defer acc = acc * 10 + 1; errdefer acc = acc * 10 + 2; defer acc = acc * 10 + 3;
    //       if fail { return .err(acc) } }   // the error value is read before the defers
    //     .ok(acc)
    // }
    // The `.err` route has its own `scope_end` (§6.8.1: every route out).
    const app = x.f.types.strings.find("app").?;
    const result = try x.f.types.intern(.{ .nominal = .{
        .decl = .{ .package = .{ .name = app, .line = .{ .major = 1 } }, .index = 99 },
        .args = &.{ .{ .type = u32_t }, .{ .type = u32_t } },
        .kind = .@"enum",
        .name = try x.f.strings.intern("Result"),
        .lang = .result,
    } });
    var b: Builder = .init(a, result);
    const fail = try b.addParam(.none, .bool, .param);
    const acc = try b.addLocal(.{ .ty = u32_t, .name = .none, .kind = .let_mut });
    const entry = try b.addBlock();
    const bodies = [3]tir.Block{ try b.addBlock(), try b.addBlock(), try b.addBlock() };
    const err_exit = try b.addBlock();
    const ok_exit = try b.addBlock();

    b.setBlock(entry);
    _ = try b.add(.void, .{ .store = .{ .place = try b.add(u32_t, .{ .local = .{ .local = acc } }), .value = try b.add(u32_t, .{ .int = .{ .value = 0 } }) } });
    const scope = try b.add(.void, .{ .scope_begin = .{} });
    _ = try b.add(.void, .{ .@"defer" = .{ .scope = scope, .body = bodies[0] } });
    _ = try b.add(.void, .{ .@"errdefer" = .{ .scope = scope, .body = bodies[1] } });
    _ = try b.add(.void, .{ .@"defer" = .{ .scope = scope, .body = bodies[2] } });
    const cond = try b.add(.bool, .{ .load = .{ .place = try b.add(.bool, .{ .local = .{ .local = fail } }) } });
    _ = try b.add(.void, .{ .cond_br = .{ .cond = cond, .then = err_exit, .@"else" = ok_exit } });

    for (bodies, [_]u64{ 1, 2, 3 }) |blk, digit| {
        b.setBlock(blk);
        const p = try b.add(u32_t, .{ .local = .{ .local = acc } });
        const cur = try b.add(u32_t, .{ .load = .{ .place = p } });
        const ten = try b.add(u32_t, .{ .mul = .{ .lhs = cur, .rhs = try b.add(u32_t, .{ .int = .{ .value = 10 } }) } });
        const next = try b.add(u32_t, .{ .add = .{ .lhs = ten, .rhs = try b.add(u32_t, .{ .int = .{ .value = digit } }) } });
        _ = try b.add(.void, .{ .store = .{ .place = p, .value = next } });
        _ = try b.add(.void, .{ .defer_end = .{} });
    }
    for ([_]tir.Block{ err_exit, ok_exit }, [_]u32{ 1, 0 }) |blk, which| {
        b.setBlock(blk);
        const before = try b.add(u32_t, .{ .load = .{ .place = try b.add(u32_t, .{ .local = .{ .local = acc } }) } });
        if (which == 1) {
            const e = try b.add(result, .{ .variant = .{ .variant = 1, .payload = &.{before} } });
            _ = try b.add(.void, .{ .scope_end = .{ .scope = scope } });
            _ = try b.add(.void, .{ .ret = .{ .value = e } });
        } else {
            _ = try b.add(.void, .{ .scope_end = .{ .scope = scope } });
            const after = try b.add(u32_t, .{ .load = .{ .place = try b.add(u32_t, .{ .local = .{ .local = acc } }) } });
            _ = try b.add(.void, .{ .ret = .{ .value = try b.add(result, .{ .variant = .{ .variant = 0, .payload = &.{after} } }) } });
        }
    }
    x.f.bodies.fns.items[x.id("d").int()].func = try b.finish();

    // Success: defers 3 then 1; the errdefer is discarded.
    const good = try x.run("d", &.{.boolean(false)});
    try testing.expectEqual(0, good.data.variant.index);
    try testing.expect(good.data.variant.payload[0].eql(x.int(u32_t, 31)));
    // Error: the `.err` value was computed before the defers ran.
    const bad = try x.run("d", &.{.boolean(true)});
    try testing.expectEqual(1, bad.data.variant.index);
    try testing.expect(bad.data.variant.payload[0].eql(x.int(u32_t, 0)));
}

test "unsupported operations stop the evaluation without a diagnostic" {
    var x: Fixture = undefined;
    try x.init("fn g() -> u32 { 1 }\nfn h() -> u32 { g() }");
    defer x.deinit();
    x.f.bodies.fns.items[x.id("g").int()].func = null;
    try testing.expectError(error.Unsupported, x.run("h", &.{}));
    try testing.expectEqualStrings("calls to functions without checked bodies (T060)", x.m.unsupported.?);
    try testing.expectEqual(0, x.m.frames.items.len);
    try testing.expect(!x.sink.hasErrors());
}
