//! Function-body checking and TIR emission (B.1 stage 4).
//!
//! `checkBodies` checks the body of every function of a package after item
//! checking (`items.zig`) and emits one typed TIR `Func` (`tir/`) per body.
//! A body with an error gets no TIR. The work is split over three files:
//!
//! - this file: the per-function `Checker` (locals, loops, diagnostics,
//!   conversions, TIR emission), the function driver (parameters, the
//!   result, E0302, E0371) and the package driver, plus the `pyro check`
//!   stage hook `runFiles`;
//! - `check_expr.zig`: bidirectional expression typing and the dispatch
//!   table of expression handlers by node kind;
//! - `check_stmt.zig`: blocks, statements and control flow.
//!
//! Extension tasks add a `check_*.zig` module and register its handlers in
//! the one dispatch table of `check_expr.zig`. A construct without a handler
//! is *unsupported*: the body is not checked further and gets no TIR, and
//! `Bodies.unsupported` names the first such construct, so that `pyro check`
//! never reports success on a program it did not fully check.
//!
//! Values (`Typed`) follow the TIR rules: untyped constants (§4.8) stay
//! exact (`Typed.konst`) until they meet a typed context, where they are
//! converted (E0306, E0310) and emitted as typed `int`/`float`. An
//! expression of type `noreturn` ends its block; code after it is checked
//! but emitted into blocks without predecessors, which end in `unreachable`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const diag = @import("../diag/diag.zig");
const Ast = @import("../ast/Ast.zig");
const Types = @import("types.zig");
const convert = @import("convert.zig");
const items_mod = @import("items.zig");
const tir = @import("../tir/tir.zig");
const Builder = @import("../tir/builder.zig").Builder;
const collect = @import("../resolve/collect.zig");
const module_graph = @import("../resolve/module_graph.zig");
const imports = @import("../resolve/imports.zig");
const names_mod = @import("../resolve/names.zig");
const Compilation = @import("../driver/Compilation.zig");
const check_stmt = @import("check_stmt.zig");
const kinds_mod = @import("kinds.zig");
const layout_mod = @import("layout.zig");
const protocols_mod = @import("protocols.zig");

const Node = Ast.Node;
const TypeId = Types.TypeId;
const ModuleId = module_graph.ModuleId;
const Items = items_mod.Items;
pub const Error = Allocator.Error;

/// The result of checking an expression.
pub const Typed = struct {
    ty: TypeId,
    /// The TIR value. `.none` for `void`, `noreturn`, `.err` and untyped
    /// constants, and after the function failed (nothing is emitted then).
    ref: tir.Ref = .none,
    /// The exact value of an untyped constant (`ty` is `.untyped_int` or
    /// `.untyped_float`).
    konst: ?convert.Const = null,

    /// A failed expression; diagnostics involving it are dropped.
    pub const err: Typed = .{ .ty = .err };
    /// A diverging expression (§4.2.4).
    pub const never: Typed = .{ .ty = .noreturn };
    pub const void_value: Typed = .{ .ty = .void };

    pub fn isUntyped(v: Typed) bool {
        return v.ty == .untyped_int or v.ty == .untyped_float;
    }
};

/// An enclosing `loop` or `while` (§6.7.1, §6.7.4).
pub const Loop = struct {
    label: ?[]const u8,
    /// `loop` (whose `break` may carry a value), not `while`.
    is_loop: bool,
    /// The `continue` target.
    head: tir.Block,
    /// The `break` target; for a value-carrying `loop` it has one parameter.
    exit: tir.Block,
    /// The type expected of the whole loop, or `.none`.
    expected: TypeId,
    /// The type of the `break` values, once one is checked.
    result: TypeId = .none,
    /// The exit block's parameter: the loop's value once `result` is set.
    param: tir.Ref = .none,
    /// Untyped `break` values that wait for `result` (§4.8): set by a typed
    /// `break` or at the loop's end.
    pending: std.ArrayList(PendingBreak) = .empty,
    /// Some `break` targets this loop.
    has_break: bool = false,
    /// Some `break` without a value targets this loop.
    has_void_break: bool = false,
};

/// A `break` of an untyped constant, whose block ends once its type is known.
pub const PendingBreak = struct { block: tir.Block, value: Typed, node: Node.Index };

/// A construct that has no checker yet.
pub const Unsupported = struct {
    module: ModuleId,
    node: Node.Index,
    /// What it is and the task that adds it: "`match` (T052)".
    what: []const u8,
};

/// One checked function body; its index is its `tir.FnId`.
pub const Body = struct {
    module: ModuleId,
    /// The `fn_decl` node.
    node: Node.Index,
    name: []const u8,
    /// Null if the body has an error, is unsupported, or was not checked
    /// (a function only called).
    func: ?tir.Func = null,
};

/// The checked bodies of one package.
pub const Bodies = struct {
    /// Heap-allocated so that big integers in constants keep a valid allocator.
    arena: *std.heap.ArenaAllocator,
    /// Indexed by `tir.FnId`.
    fns: std.ArrayList(Body) = .empty,
    ids: std.AutoHashMapUnmanaged(struct { ModuleId, Node.Index }, tir.FnId) = .empty,
    /// The first construct that could not be checked, if any.
    unsupported: ?Unsupported = null,

    pub fn deinit(bs: *Bodies) void {
        const gpa = bs.arena.child_allocator;
        bs.arena.deinit();
        gpa.destroy(bs.arena);
        bs.* = undefined;
    }

    /// The id of function `node` of module `m`, assigned on first use.
    pub fn fnId(bs: *Bodies, m: ModuleId, node: Node.Index, name: []const u8) Error!tir.FnId {
        const a = bs.arena.allocator();
        const gop = try bs.ids.getOrPut(a, .{ m, node });
        if (!gop.found_existing) {
            gop.value_ptr.* = .from(bs.fns.items.len);
            try bs.fns.append(a, .{ .module = m, .node = node, .name = name });
        }
        return gop.value_ptr.*;
    }

    /// The body of function `name` of module `m`, if it was checked.
    pub fn find(bs: *const Bodies, m: ModuleId, name: []const u8) ?*const Body {
        for (bs.fns.items) |*b| if (b.module == m and std.mem.eql(u8, b.name, name)) return b;
        return null;
    }
};

/// The state of checking one function body.
pub const Checker = struct {
    bodies: *Bodies,
    items: *Items,
    types: *Types,
    sink: *diag.Sink,
    arena: Allocator,
    m: ModuleId,
    ast: *const Ast,
    /// What `Self` means in the body; `.none` outside a type.
    self_ty: TypeId,
    sig: items_mod.Fn,
    b: Builder,
    /// The TIR local of each `param` and `let` binding node.
    locals: std.AutoHashMapUnmanaged(Node.Index, tir.Local) = .empty,
    /// The `self` parameter, if any.
    self_local: tir.Local = .none,
    /// Enclosing loops, innermost last.
    loops: std.ArrayList(Loop) = .empty,
    /// Inside an `unsafe` block (§12.1).
    in_unsafe: bool = false,
    /// Checking comptime code (§8.6); set by comptime evaluation (T060).
    in_comptime: bool = false,
    /// An error was reported or a construct is unsupported: nothing more is
    /// emitted and the body gets no TIR.
    failed: bool = false,

    // -----------------------------------------------------------------------
    // Diagnostics

    fn tokSpan(c: *const Checker, t: Ast.TokenIndex) diag.Span {
        const start = c.ast.tokens.items(.start)[t];
        return .{ .file = c.items.im.graph.modules[c.m].file, .start = start, .end = start + c.ast.tokens.items(.len)[t] };
    }

    /// Reports at token `t`. `code` is null only for rules without an A.3 code.
    pub fn reportAt(c: *Checker, t: Ast.TokenIndex, code: ?diag.DiagCode, help: []const []const u8, comptime fmt: []const u8, args: anytype) Error!void {
        c.failed = true;
        try c.sink.emit(.{
            .code = code,
            .severity = if (code) |k| .of(k) else .@"error",
            .message = try std.fmt.allocPrint(c.arena, fmt, args),
            .spans = &.{.{ .span = c.tokSpan(t), .primary = true }},
            .help = help,
        });
    }

    /// Reports at the main token of node `n`.
    pub fn report(c: *Checker, n: Node.Index, code: ?diag.DiagCode, comptime fmt: []const u8, args: anytype) Error!void {
        return c.reportAt(c.ast.mainToken(n), code, &.{}, fmt, args);
    }

    /// E0310 at `n`: a value of type `found` where `want` is required.
    pub fn mismatch(c: *Checker, n: Node.Index, want: TypeId, found: TypeId) Error!void {
        try c.report(n, .E0310, "mismatched types: expected `{s}`, found `{s}`", .{ try c.tyName(want), try c.tyName(found) });
    }

    pub fn tyName(c: *Checker, ty: TypeId) Error![]const u8 {
        return c.types.allocPrint(c.arena, ty, .{});
    }

    /// Records that `n` (described by `what`, with its owning task) cannot be
    /// checked yet; the body fails without a diagnostic.
    pub fn unsupported(c: *Checker, n: Node.Index, what: []const u8) Typed {
        c.failed = true;
        if (c.bodies.unsupported == null) c.bodies.unsupported = .{ .module = c.m, .node = n, .what = what };
        return .err;
    }

    // -----------------------------------------------------------------------
    // Emission

    /// Appends an instruction to the current block and returns its value.
    /// Emits nothing once the function failed, or when an operand is missing
    /// (dead code after a diverging operand). After a terminator, a new block
    /// without predecessors receives the dead code.
    pub fn emit(c: *Checker, ty: TypeId, d: tir.Data) Error!tir.Ref {
        if (c.failed or !operandsPresent(d)) return .none;
        if (c.b.isTerminated(c.b.block)) c.b.setBlock(try c.b.addBlock());
        return c.b.add(ty, d);
    }

    pub fn addBlock(c: *Checker) Error!tir.Block {
        return c.b.addBlock();
    }

    pub fn setBlock(c: *Checker, blk: tir.Block) void {
        c.b.setBlock(blk);
    }

    /// Adds a parameter of type `ty` to the (still empty) block `blk`.
    pub fn blockParam(c: *Checker, blk: tir.Block, ty: TypeId) Error!tir.Ref {
        if (c.failed) return .none;
        return c.b.addBlockParam(blk, ty);
    }

    /// `br target [arg]` from the current block; `arg` is a value or `.none`.
    pub fn br(c: *Checker, target: tir.Block, arg: tir.Ref) Error!void {
        _ = try c.emit(.void, .{ .br = .{ .target = target, .args = if (arg == .none) &.{} else &.{arg} } });
    }

    /// The typed constant `v` (an integer, `bool`, enum or float).
    pub fn constant(c: *Checker, v: Types.Value) Error!Typed {
        const u = c.underlying(v.type);
        const d: tir.Data = if (u == .f32)
            .{ .float = .{ .bits = @bitCast(@as(f64, @as(f32, @bitCast(@as(u32, @truncate(v.bits)))))) } }
        else if (u == .f64)
            .{ .float = .{ .bits = v.bits } }
        else
            .{ .int = .{ .value = v.bits } };
        return .{ .ty = v.type, .ref = try c.emit(v.type, d) };
    }

    /// Loads local `l`.
    pub fn load(c: *Checker, l: tir.Local) Error!Typed {
        const ty = c.b.locals.items(.ty)[l.int()];
        const place = try c.emit(ty, .{ .local = .{ .local = l } });
        return .{ .ty = ty, .ref = try c.emit(ty, .{ .load = .{ .place = place } }) };
    }

    // -----------------------------------------------------------------------
    // Conversions (§4.8, §4.9.1)

    /// `v` converted implicitly to `to` (§4.9.1), reporting E0306/E0310 at
    /// `at`. `to == .none` gives an untyped constant its default type.
    pub fn coerce(c: *Checker, v: Typed, to: TypeId, at: Node.Index) Error!Typed {
        if (to == .none) return c.materialize(v, at);
        if (v.ty == .err or to == .err) {
            c.failed = true; // reported with the value or the type
            return .err;
        }
        switch (convert.coerce(c.types, v.ty, to, .{})) {
            .identity => return .{ .ty = to, .ref = v.ref },
            .never => return v,
            .constant => return c.constTo(v.konst.?, to, at),
            .int_widen, .float_widen, .ptr_to_const => return .{ .ty = to, .ref = try c.emit(to, .{ .coerce = .{ .value = v.ref } }) },
            .wrap_some => return @import("check_literals.zig").wrapSome(c, v, to, at),
            .array_to_slice, .soa_array_to_soa_slice => return c.unsupported(at, "array-to-slice views (T051)"),
            .lambda_to_fn_ptr => return c.unsupported(at, "lambdas (T074)"),
            .fn_ref => return c.unsupported(at, "`FnRef` values (T071)"),
            .none => {
                try c.mismatch(at, to, v.ty);
                return .err;
            },
        }
    }

    /// An untyped constant converted to its default type (§4.8); any other
    /// value unchanged.
    pub fn materialize(c: *Checker, v: Typed, at: Node.Index) Error!Typed {
        if (!v.isUntyped()) return v;
        return c.constTo(v.konst.?, convert.defaultType(v.ty), at);
    }

    /// Untyped constant `k` converted to `to` (rule 1 of §4.9.1) and emitted.
    pub fn constTo(c: *Checker, k: convert.Const, to: TypeId, at: Node.Index) Error!Typed {
        switch (try convert.convertConst(c.arena, c.types, c.items.options.ptr_bits, k, to)) {
            .ok => |val| return c.constant(val),
            .err => |code| {
                if (code == .E0310) {
                    try c.mismatch(at, to, k.typeOf());
                } else try c.report(at, code, "{s} constant does not fit `{s}`", .{ if (k == .int) "integer" else "float", try c.tyName(to) });
                return .err;
            },
        }
    }

    // -----------------------------------------------------------------------
    // Types

    /// The type named by type expression `n`; `.err` (and the body fails) if
    /// it was reported.
    pub fn resolveType(c: *Checker, n: Node.Index) Error!TypeId {
        const t = try c.items.resolveType(c.m, n, c.self_ty);
        if (t == .err) c.failed = true;
        return t;
    }

    /// `ty` with distinct wrappers removed (§4.7).
    pub fn underlying(c: *Checker, ty: TypeId) TypeId {
        var t = ty;
        while (true) switch (c.types.get(t)) {
            .nominal => |n| if (n.kind == .distinct) {
                t = n.underlying;
            } else return t,
            else => return t,
        };
    }

    /// The enclosing loop named `label`, or the innermost one.
    pub fn findLoop(c: *Checker, label: ?[]const u8) ?*Loop {
        var i = c.loops.items.len;
        while (i > 0) {
            i -= 1;
            const l = &c.loops.items[i];
            const want = label orelse return l;
            if (l.label) |have| if (std.mem.eql(u8, have, want)) return l;
        }
        return null;
    }
};

/// Whether every required operand ref of `d` is present.
fn operandsPresent(d: tir.Data) bool {
    switch (d) {
        inline else => |p| {
            inline for (@typeInfo(@TypeOf(p)).@"struct".field_names) |name| {
                const v = @field(p, name);
                switch (@TypeOf(v)) {
                    tir.Ref => if (v == .none) return false,
                    []const tir.Ref => for (v) |r| if (r == .none) return false,
                    else => {},
                }
            }
            return true;
        },
    }
}

// ---------------------------------------------------------------------------
// Functions

/// Checks the body of function `sig` (declared in module `m`, inside type
/// `self_ty` or `.none`) and returns its TIR, or null if it failed.
pub fn checkFn(bodies: *Bodies, it: *Items, m: ModuleId, sig: items_mod.Fn, self_ty: TypeId) Error!?tir.Func {
    const ast = it.im.graph.modules[m].ast;
    const body = ast.data(sig.node).fn_decl.body.?;
    const arena = bodies.arena.allocator();
    var c: Checker = .{
        .bodies = bodies,
        .items = it,
        .types = it.types,
        .sink = it.sink,
        .arena = arena,
        .m = m,
        .ast = ast,
        .self_ty = self_ty,
        .sig = sig,
        .b = .init(arena, sig.ret),
    };
    if (sig.ret == .err) c.failed = true;
    for (sig.params) |p| {
        const kind: tir.LocalKind = switch (p.mode) {
            .value => .param,
            .mut => .param_mut,
            .move => .param_move,
            .@"comptime" => {
                _ = c.unsupported(p.node, "`comptime` parameters (T063)");
                return null;
            },
        };
        if (p.type == .err) c.failed = true;
        c.b.node = p.node;
        const l = try c.b.addParam(try it.types.strings.intern(p.name), p.type, kind);
        try c.locals.put(arena, p.node, l);
        if (p.is_self) c.self_local = l;
    }
    c.b.node = body;
    c.setBlock(try c.addBlock());
    const v = try check_stmt.block(&c, body, if (sig.ret == .void) .none else sig.ret);
    try finishBody(&c, body, v);
    if (c.failed) return null;
    for (c.b.blocks.items, 0..) |_, i| if (!c.b.isTerminated(.from(i))) {
        c.setBlock(.from(i));
        _ = try c.b.add(.void, .{ .@"unreachable" = .{} });
    };
    return try c.b.finish();
}

/// The result of the body `v` (§7.2.1): E0302 if a `noreturn` function can
/// reach its end, E0371 if a function with a result has none, else `ret`.
fn finishBody(c: *Checker, body: Node.Index, v: Typed) Error!void {
    const ret = c.sig.ret;
    if (v.ty == .noreturn) return;
    // A body that already failed may diverge in a part that was not checked.
    if (c.failed) return;
    const close = closingBrace(c.ast, c.ast.mainToken(body));
    if (ret == .noreturn) {
        return c.reportAt(close, .E0302, &.{"end the body with a call to a `noreturn` function, a trap or a `loop` without `break`"}, "`{s}` is declared `-> noreturn` but can reach the end of its body", .{c.sig.name});
    }
    if (ret != .void and v.ty == .void) {
        return c.reportAt(close, .E0371, &.{"end the body with a value or `return` one on every path"}, "missing return value: `{s}` must return `{s}`", .{ c.sig.name, try c.tyName(ret) });
    }
    const r = try c.coerce(v, ret, check_stmt.valueNode(c.ast, body));
    _ = try c.emit(.void, .{ .ret = .{ .value = if (ret == .void) null else r.ref } });
}

/// The `}` that closes the `{` at token `open`.
fn closingBrace(ast: *const Ast, open: Ast.TokenIndex) Ast.TokenIndex {
    const kinds = ast.tokens.items(.kind);
    var depth: u32 = 0;
    var t = open;
    while (t < kinds.len) : (t += 1) switch (kinds[t]) {
        .l_brace, .dot_l_brace => depth += 1,
        .r_brace => {
            depth -= 1;
            if (depth == 0) return t;
        },
        else => {},
    };
    return open;
}

// ---------------------------------------------------------------------------
// Package

/// Checks every function body of the package whose items are `it`, and
/// reports to `it.sink`. Errors are internal failures only.
/// `protos`, if given, supplies the `impl` blocks whose methods are checked;
/// without it they are recorded as unsupported.
pub fn checkBodies(gpa: Allocator, it: *Items, protos: ?*const protocols_mod.Protocols) Error!Bodies {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(gpa);
    var bs: Bodies = .{ .arena = arena };
    errdefer bs.deinit();
    for (it.im.graph.modules, 0..) |cm, mi| {
        const m: ModuleId = @intCast(mi);
        for (cm.items, 0..) |item, i| switch ((try it.info(.{ .module = m, .item = @intCast(i) })).*) {
            .@"fn" => |f| try checkDecl(&bs, it, m, f, .none, &.{}),
            .@"const" => |k| comptimeValue(&bs, m, k.node, k.value, k.type),
            .@"struct" => |s| {
                for (s.fields) |fd| if (fd.default) |v| comptimeValue(&bs, m, fd.node, v, fd.type);
                for (s.consts) |k| comptimeValue(&bs, m, k.node, k.value, k.type);
                for (s.methods) |f| try checkDecl(&bs, it, m, f, s.type, s.generics);
            },
            .@"enum" => |e| {
                for (e.consts) |k| comptimeValue(&bs, m, k.node, k.value, k.type);
                for (e.methods) |f| try checkDecl(&bs, it, m, f, e.type, e.generics);
            },
            // A default method is generic over `Self`.
            .protocol => try unsupportedBodies(&bs, cm.ast, m, item.node, "protocol default methods (T070)"),
            .pending, .alias, .distinct => {},
        };
        if (cm.ast.nodes.len > 0) for (cm.ast.data(.from(0)).root.items) |n| {
            const inner = if (cm.ast.kind(n) == .attributed) cm.ast.data(n).attributed.inner else n;
            switch (cm.ast.kind(inner)) {
                .impl_decl => if (protos == null) try unsupportedBodies(&bs, cm.ast, m, inner, "`impl` methods (T044)"),
                .comptime_block => if (bs.unsupported == null) {
                    bs.unsupported = .{ .module = m, .node = inner, .what = "comptime blocks (T060)" };
                },
                else => {},
            }
        };
    }
    if (protos) |p| {
        for (p.impls) |impl| {
            if (impl.protocol == .err or impl.target == .err) continue;
            for (impl.methods) |f| try checkDecl(&bs, it, impl.src.module, f, impl.target, impl.generics);
        }
        // Protocol method declarations have no checked body, but their
        // parameters follow the same rules (§4.5.3, §5.5.2).
        var it_protos = p.protos.valueIterator();
        while (it_protos.next()) |pr| {
            const ref = it.declRef(pr.type) orelse continue;
            for (pr.methods) |md| try @import("check_call.zig").checkSignature(it, ref.module, md.f);
        }
    }
    return bs;
}

/// Records a const, default or field default of type `ty` whose value
/// item checking left to the comptime evaluator as unsupported.
fn comptimeValue(bs: *Bodies, m: ModuleId, node: Node.Index, v: items_mod.Value, ty: TypeId) void {
    if (v == .unknown and ty != .err and bs.unsupported == null)
        bs.unsupported = .{ .module = m, .node = node, .what = "values computed at comptime (T060)" };
}

/// Checks function `f` if it has a body. Generic bodies are checked per
/// instantiation (T070).
fn checkDecl(bs: *Bodies, it: *Items, m: ModuleId, f: items_mod.Fn, self_ty: TypeId, type_generics: []const TypeId) Error!void {
    try @import("check_call.zig").checkSignature(it, m, f);
    for (f.params) |p| if (p.default) |v| comptimeValue(bs, m, p.node, v, p.type);
    const ast = it.im.graph.modules[m].ast;
    if (ast.data(f.node).fn_decl.body == null) return;
    const id = try bs.fnId(m, f.node, f.name);
    if (f.generics.len > 0 or type_generics.len > 0) {
        if (bs.unsupported == null) bs.unsupported = .{ .module = m, .node = f.node, .what = "generic function bodies (T070)" };
        return;
    }
    // Checking the body may grow `bs.fns` (callee ids): index it afterwards.
    const func = try checkFn(bs, it, m, f, self_ty);
    bs.fns.items[id.int()].func = func;
}

/// Records the bodies of the members of `decl` as unsupported.
fn unsupportedBodies(bs: *Bodies, ast: *const Ast, m: ModuleId, decl: Node.Index, what: []const u8) Error!void {
    const members = switch (ast.data(decl)) {
        .protocol_decl => |d| d.members,
        .impl_decl => |d| d.members,
        else => return,
    };
    for (members) |mn| {
        const n = if (ast.kind(mn) == .attributed) ast.data(mn).attributed.inner else mn;
        if (ast.kind(n) == .fn_decl and ast.data(n).fn_decl.body != null and bs.unsupported == null)
            bs.unsupported = .{ .module = m, .node = n, .what = what };
    }
}

/// Check-stage hook for single-file `pyro check`: item and body checking of
/// each file. Name resolution is redone silently (the resolve stage already
/// reported its diagnostics). Fails with `error.CheckIncomplete` if some
/// construct could not be checked and no error was reported, because the
/// program has then not been shown valid.
pub fn runFiles(_: ?*anyopaque, comp: *Compilation) anyerror!void {
    var incomplete = false;
    for (comp.files.items) |*f| {
        if (f.poisoned) continue;
        // Same module naming as `imports.eachFile`.
        const stem = std.fs.path.stem(comp.sources.get(f.id).path);
        const name = if (collect.isValidSegment(stem)) stem else "main";
        const file = try std.mem.concat(comp.gpa, u8, &.{ "src" ++ std.fs.path.sep_str, name, ".pr" });
        defer comp.gpa.free(file);
        var scratch: diag.Sink = .init(comp.gpa, comp.io);
        defer scratch.deinit();
        const in: module_graph.Input = .{ .module = .{ .path = name, .file = file }, .file = f.id, .ast = &f.ast };
        var g = try module_graph.build(comp.gpa, &scratch, &.{in}, .{ .kind = .exe });
        defer g.deinit();
        var im = try imports.resolve(comp.gpa, &scratch, &g, .{ .partial = true });
        defer im.deinit();
        var names = try names_mod.resolve(comp.gpa, &scratch, &im);
        defer names.deinit();
        var types: Types = try .init(comp.gpa, comp.io, &comp.interner);
        defer types.deinit();
        const pkg: Types.Package = .{ .name = try comp.interner.intern(name), .line = .{ .major = 0 } };
        var it = try items_mod.check(comp.gpa, &comp.sink, &types, &im, &names, .{ .package = pkg });
        defer it.deinit();
        try kinds_mod.check(&it);
        var lay: layout_mod.Engine = .init(comp.gpa, &it);
        defer lay.deinit();
        try lay.check();
        var protos = try protocols_mod.check(comp.gpa, &comp.sink, &it, .{});
        defer protos.deinit();
        var bs = try checkBodies(comp.gpa, &it, &protos);
        defer bs.deinit();
        if (bs.unsupported != null) incomplete = true;
    }
    if (incomplete and !comp.sink.hasErrors()) return error.CheckIncomplete;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const Interner = @import("../base/Interner.zig");
const dump = @import("../tir/dump.zig");

/// A package checked up to function bodies, for tests; build in place with
/// `init`.
pub const Fixture = struct {
    p: module_graph.TestPackage,
    g: module_graph.Graph,
    im: imports.Imports,
    names: names_mod.Names,
    strings: Interner,
    types: Types,
    items: Items,
    bodies: Bodies,

    pub fn init(f: *Fixture, source: []const u8) !void {
        return f.initPackage(&.{.{ "a", source }});
    }

    /// A package of modules `{ path, source }`; the first is module 0.
    pub fn initPackage(f: *Fixture, mods: []const [2][]const u8) !void {
        f.p = try .init(mods);
        f.g = try f.p.graph(.{ .kind = .exe });
        f.im = try imports.resolve(testing.allocator, &f.p.sink, &f.g, .{});
        f.names = try names_mod.resolve(testing.allocator, &f.p.sink, &f.im);
        f.strings = .init(testing.allocator, testing.io);
        f.types = try .init(testing.allocator, testing.io, &f.strings);
        const pkg: Types.Package = .{ .name = try f.strings.intern("app"), .line = .{ .major = 1 } };
        f.items = try items_mod.check(testing.allocator, &f.p.sink, &f.types, &f.im, &f.names, .{ .package = pkg });
        f.bodies = try checkBodies(testing.allocator, &f.items, null);
    }

    pub fn deinit(f: *Fixture) void {
        f.bodies.deinit();
        f.items.deinit();
        f.types.deinit();
        f.strings.deinit();
        f.names.deinit();
        f.im.deinit();
        f.g.deinit();
        f.p.deinit();
    }

    /// Checks the reported codes and the source text at each primary span.
    pub fn expectDiags(f: *Fixture, want: []const struct { ?diag.DiagCode, []const u8 }) !void {
        const ds = f.p.sink.finish();
        errdefer for (ds) |d| std.debug.print("got {?t}: {s}\n", .{ d.code, d.message });
        try testing.expectEqual(want.len, ds.len);
        for (want, ds) |w, d| {
            try testing.expectEqual(w[0], d.code);
            const s = d.primarySpan().?;
            try testing.expectEqualStrings(w[1], f.p.asts[@backingInt(s.file)].source[s.start..s.end]);
        }
    }

    /// The TIR of function `name`; fails if it has none.
    pub fn func(f: *Fixture, name: []const u8) !*const tir.Func {
        const b = f.bodies.find(0, name) orelse return error.TestUnexpectedResult;
        return if (b.func) |*x| x else error.TestUnexpectedResult;
    }

    /// Compares the dump of function `name` with `want`.
    pub fn expectDump(f: *Fixture, name: []const u8, want: []const u8) !void {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try dump.dump(try f.func(name), &f.types, name, &out.writer);
        try testing.expectEqualStrings(want, out.written());
    }
};

test "golden TIR: parameters, arithmetic, untyped constants, return" {
    var f: Fixture = undefined;
    try f.init(
        \\fn mad(a: i32, b: i32) -> i32 { return a * b + -1; }
        \\fn widen(small: u8, x: f32) -> f64 {
        \\    let w: u16 = small + 1;
        \\    let y: f64 = x;
        \\    y * 2.0
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    try f.expectDump("mad",
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
    );
    try f.expectDump("widen",
        \\fn widen(l0 small: u8, l1 x: f32) -> f64 {
        \\  l2 w: u16
        \\  l3 y: f64
        \\b0:
        \\  %0: u8 = local l0
        \\  %1: u8 = load %0
        \\  %2: u8 = int 1
        \\  %3: u8 = add %1, %2
        \\  %4: u16 = coerce %3
        \\  %5: u16 = local l2
        \\  store %5, %4
        \\  %7: f32 = local l1
        \\  %8: f32 = load %7
        \\  %9: f64 = coerce %8
        \\  %10: f64 = local l3
        \\  store %10, %9
        \\  %12: f64 = local l3
        \\  %13: f64 = load %12
        \\  %14: f64 = float 2
        \\  %15: f64 = mul %13, %14
        \\  ret %15
        \\}
        \\
    );
}

test "golden TIR: if value, loop with break value, while" {
    var f: Fixture = undefined;
    try f.init(
        \\fn max(a: f64, b: f64) -> f64 { if a > b { a } else { b } }
        \\fn sum(n: u64) -> u64 {
        \\    let mut s: u64 = 0;
        \\    let mut i: u64 = 0;
        \\    loop { if i >= n { break s; } s += i; i += 1; }
        \\}
        \\fn count(n: u32) -> u32 {
        \\    let mut i = 0u32;
        \\    while i < n && i != 7 { i += 1; }
        \\    i
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    try f.expectDump("max",
        \\fn max(l0 a: f64, l1 b: f64) -> f64 {
        \\b0:
        \\  %0: f64 = local l0
        \\  %1: f64 = load %0
        \\  %2: f64 = local l1
        \\  %3: f64 = load %2
        \\  %4: bool = gt %1, %3
        \\  cond_br %4, b1, b2
        \\b1:
        \\  %6: f64 = local l0
        \\  %7: f64 = load %6
        \\  br b3, [%7]
        \\b2:
        \\  %8: f64 = local l1
        \\  %9: f64 = load %8
        \\  br b3, [%9]
        \\b3(%10: f64):
        \\  ret %10
        \\}
        \\
    );
    try f.expectDump("sum",
        \\fn sum(l0 n: u64) -> u64 {
        \\  l1 mut s: u64
        \\  l2 mut i: u64
        \\b0:
        \\  %0: u64 = int 0
        \\  %1: u64 = local l1
        \\  store %1, %0
        \\  %3: u64 = int 0
        \\  %4: u64 = local l2
        \\  store %4, %3
        \\  br b1, []
        \\b1:
        \\  %7: u64 = local l2
        \\  %8: u64 = load %7
        \\  %9: u64 = local l0
        \\  %10: u64 = load %9
        \\  %11: bool = ge %8, %10
        \\  cond_br %11, b3, b4
        \\b2(%15: u64):
        \\  ret %15
        \\b3:
        \\  %13: u64 = local l1
        \\  %14: u64 = load %13
        \\  br b2, [%14]
        \\b4:
        \\  br b5, []
        \\b5:
        \\  %18: u64 = local l1
        \\  %19: u64 = load %18
        \\  %20: u64 = local l2
        \\  %21: u64 = load %20
        \\  %22: u64 = add %19, %21
        \\  store %18, %22
        \\  %24: u64 = local l2
        \\  %25: u64 = load %24
        \\  %26: u64 = int 1
        \\  %27: u64 = add %25, %26
        \\  store %24, %27
        \\  br b1, []
        \\}
        \\
    );
    _ = try f.func("count");
}

test "E0310: distinct types, mixed numeric operands, non-bool conditions" {
    var f: Fixture = undefined;
    try f.init(
        \\type Meters = distinct f32;
        \\type Seconds = distinct f32;
        \\fn mixes(d: Meters, t: Seconds, n: i32, x: f32, count: u32) {
        \\    let bad = d + t;
        \\    let sum = n + x;
        \\    if count { return; }
        \\    let s: str = n;
        \\    let ok: Meters = 100.0;
        \\    let speed = (d as f32) / (t as f32);
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{ .{ .E0310, "+" }, .{ .E0310, "+" }, .{ .E0310, "count" }, .{ .E0310, "n" } });
    try testing.expectEqual(null, f.bodies.find(0, "mixes").?.func);
}

test "vec broadcast and lane-wise comparison give mask<N>" {
    var f: Fixture = undefined;
    try f.init(
        \\fn scale(v: vec<4, f32>) -> vec<4, f32> { v * 2.0 }
        \\fn less(v: vec4<f32>, w: vec4<f32>) -> mask<4> { v < w }
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    try f.expectDump("scale",
        \\fn scale(l0 v: vec<4, f32>) -> vec<4, f32> {
        \\b0:
        \\  %0: vec<4, f32> = local l0
        \\  %1: vec<4, f32> = load %0
        \\  %2: f32 = float 2
        \\  %3: vec<4, f32> = splat %2
        \\  %4: vec<4, f32> = mul %1, %3
        \\  ret %4
        \\}
        \\
    );
    const less = try f.func("less");
    const ret = less.terminator(.from(0));
    const mask = less.data(ret).ret.value.?;
    try testing.expectEqual(tir.Op.lt, less.op(mask));
    try testing.expectEqual(Types.Key{ .mask = .{ .len = 4 } }, f.types.get(less.typeOf(mask)));
}

test "noreturn: loop without break, calls, E0302" {
    var f: Fixture = undefined;
    try f.init(
        \\fn spin() -> noreturn { loop {} }
        \\fn pick(flag: bool) -> u32 { if flag { 1 } else { spin() } }
        \\fn wait_for(ready: bool) -> f32 {
        \\    if ready { return 1.0; }
        \\    spin()
        \\}
        \\fn stop(code: u8) -> noreturn {
        \\    if code == 0 {
        \\        return;
        \\    }
        \\    spin();
        \\}
        \\fn falls(done: bool) -> noreturn {
        \\    if done { spin(); }
        \\}
        \\fn both(c: bool) -> noreturn { if c { spin() } else { loop {} } }
        \\fn dead(c: bool) -> u32 { return 1; 2 }
    );
    defer f.deinit();
    try f.expectDiags(&.{ .{ .E0302, "return" }, .{ .E0302, "}" } });
    for ([_][]const u8{ "spin", "pick", "wait_for", "both", "dead" }) |name| _ = try f.func(name);
    try f.expectDump("spin",
        \\fn spin() -> noreturn {
        \\b0:
        \\  br b1, []
        \\b1:
        \\  br b1, []
        \\b2:
        \\  unreachable
        \\}
        \\
    );
}

test "E0371: missing return value" {
    var f: Fixture = undefined;
    try f.init(
        \\fn half(x: u32) -> u32 {
        \\    if x == 0 {
        \\        return;
        \\    }
        \\    x / 2
        \\}
        \\fn sign(x: i32) -> i32 {
        \\    if x < 0 { return -1; }
        \\    if x > 0 { return 1; }
        \\}
        \\fn ok(x: i32) -> i32 {
        \\    if x < 0 { return -1; }
        \\    let y = loop { break x + 1; };
        \\    y
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{ .{ .E0371, "return" }, .{ .E0371, "}" } });
    _ = try f.func("ok");
}

test "pyro check stage: unsupported constructs make the check incomplete" {
    var f: Fixture = undefined;
    try f.init(
        \\fn a(x: u32) -> u32 { match x { _ => 1 } }
        \\fn b() -> u32 { 2 }
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    try testing.expectEqualStrings("`match` (T052)", f.bodies.unsupported.?.what);
    try testing.expectEqual(null, f.bodies.find(0, "a").?.func);
    _ = try f.func("b");
}

test "pyro check stage: names from modules not loaded make the check incomplete, arguments are still checked" {
    for ([_]struct { []const u8, ?diag.DiagCode }{
        .{ "thing(1)", null },
        .{ "thing(true + 1)", .E0310 },
    }) |case| {
        var comp: Compilation = undefined;
        try comp.init(testing.allocator, testing.io, .{ .jobs = 1, .stop_after = .check });
        defer comp.deinit();
        try comp.addHook(.resolve, .{ .run = names_mod.runFiles });
        try comp.addHook(.check, .{ .run = runFiles });
        const src = try std.mem.concat(testing.allocator, u8, &.{ "use physics.helpers.thing;\nfn main() { let x: u32 = ", case[0], "; }\n" });
        defer testing.allocator.free(src);
        _ = try comp.addSource("a.pr", src);
        const res = comp.run();
        const ds = comp.sink.finish();
        if (case[1]) |code| {
            try res;
            try testing.expectEqual(1, ds.len);
            try testing.expectEqual(code, ds[0].code.?);
        } else {
            try testing.expectError(error.CheckIncomplete, res);
            try testing.expectEqual(0, ds.len);
        }
    }
}

test "protocol method signatures: E0339 `mut T` parameter type, E0326 `move` of a plain type" {
    var comp: Compilation = undefined;
    try comp.init(testing.allocator, testing.io, .{ .jobs = 1, .stop_after = .check });
    defer comp.deinit();
    try comp.addHook(.resolve, .{ .run = names_mod.runFiles });
    try comp.addHook(.check, .{ .run = runFiles });
    _ = try comp.addSource("a.pr", "protocol Q { fn f(self, p: mut u32); fn g(self, move n: u32); }\npub fn main() {}\n");
    try comp.run();
    const ds = comp.sink.finish();
    try testing.expectEqual(2, ds.len);
    try testing.expectEqual(.E0339, ds[0].code.?);
    try testing.expectEqual(.E0326, ds[1].code.?);
}

test "a parameter type that failed to resolve fails the calling body too" {
    var f: Fixture = undefined;
    try f.init(
        \\fn g(x: Bogus) {}
        \\fn f() { g(1); }
    );
    defer f.deinit();
    try f.expectDiags(&.{.{ null, "Bogus" }});
    try testing.expectEqual(null, f.bodies.find(0, "f").?.func);
}
