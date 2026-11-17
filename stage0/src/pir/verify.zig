//! P-IR verifier (spec B.5.1, B.5.3): checks the invariants every pass must
//! preserve.
//!
//! - SSA: every value is defined exactly once (function parameter, block
//!   parameter or instruction result) and every used value is defined.
//! - Dominance: every definition dominates all its uses. A block argument is a
//!   use at the end of the predecessor. Uses in unreachable blocks are not
//!   checked (they never execute).
//! - Block parameters: each branch passes as many arguments as the target block
//!   has parameters, with matching types. The entry block takes none.
//! - Operand types: operand kinds, counts and types, result counts and types,
//!   and flags per opcode (layout documented on `ir.Op`).
//! - Terminators: every block ends with exactly one terminator, and targets
//!   name existing blocks.
//! - Reducibility: every retreating edge of a depth-first walk from the entry
//!   targets a block that dominates its source (a natural loop header).
//!
//! The verifier stops at the first violation and describes it in a `Failure`.
//! Passes call `afterPass`, which verifies in debug compiler builds only.

const std = @import("std");
const builtin = @import("builtin");
const ir = @import("ir.zig");

const Allocator = std.mem.Allocator;
const Type = ir.Type;
const Inst = ir.Inst;
const Op = ir.Op;
const Operand = ir.Operand;

/// The invariant a `Failure` violates.
pub const Kind = enum {
    /// A used value has no definition (or its index is out of range).
    undefined_value,
    /// A value, function or global is defined twice.
    multiple_definition,
    /// A definition does not dominate one of its uses.
    not_dominated,
    /// A branch passes the wrong number of block arguments, or the entry block
    /// has parameters.
    block_arity,
    /// A block argument's type differs from the parameter's type.
    block_arg_type,
    /// Wrong number or kind of operands (value vs. literal vs. order ...).
    bad_operand,
    /// An operand has a type the opcode does not accept.
    operand_type,
    /// Wrong number or type of results.
    bad_result,
    /// A flag, predicate, order or alignment the opcode does not accept.
    bad_flag,
    /// A `@symbol` names no function or global, or a call's signature differs.
    bad_symbol,
    /// A block is empty, does not end in a terminator, has a terminator before
    /// its end, or branches to a block that does not exist.
    bad_terminator,
    /// The control-flow graph is irreducible.
    irreducible,
};

/// The first violation found.
pub const Failure = struct {
    kind: Kind = undefined,
    /// Static description of what is wrong.
    msg: []const u8 = "",
    /// Function name without `@`; empty for a module-level failure.
    func: []const u8 = "",
    /// Block index, if the failure is inside a block.
    block: ?u32 = null,
    /// Instruction index within `block`, if the failure is at an instruction.
    inst: ?u32 = null,

    /// Prints `@f block B inst I: msg (kind)` (`{f}`).
    pub fn format(fl: Failure, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (fl.func.len != 0) try w.print("@{s}", .{fl.func});
        if (fl.block) |b| try w.print(" block {d}", .{b});
        if (fl.inst) |i| try w.print(" inst {d}", .{i});
        if (fl.func.len != 0) try w.writeAll(": ");
        try w.print("{s} ({s})", .{ fl.msg, @tagName(fl.kind) });
    }
};

pub const Error = Allocator.Error || error{Invalid};

/// Verifies every function of `m`, and that symbol names are unique.
/// `gpa` is used for scratch memory only. On `error.Invalid`, `failure`
/// describes the violation.
pub fn verify(gpa: Allocator, m: *const ir.Module, failure: *Failure) Error!void {
    for (m.globals.items, 0..) |g, i| {
        for (m.globals.items[0..i]) |h| if (std.mem.eql(u8, g.name, h.name)) return dupSymbol(failure);
        for (m.functions.items) |f| if (std.mem.eql(u8, g.name, f.name)) return dupSymbol(failure);
    }
    for (m.functions.items, 0..) |f, i| {
        for (m.functions.items[0..i]) |h| if (std.mem.eql(u8, f.name, h.name)) return dupSymbol(failure);
        try verifyFunction(gpa, m, f, failure);
    }
}

fn dupSymbol(failure: *Failure) error{Invalid} {
    failure.* = .{ .kind = .multiple_definition, .msg = "symbol defined twice" };
    return error.Invalid;
}

/// Verifies one function of `m` (calls are checked against `m`'s functions).
pub fn verifyFunction(gpa: Allocator, m: *const ir.Module, f: *const ir.Function, failure: *Failure) Error!void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var v: Verifier = .{ .arena = arena_state.allocator(), .m = m, .f = f, .failure = failure };
    try v.run();
}

/// Verifies `m` after the pass `pass` in debug compiler builds and panics on a
/// violation, naming the pass. A no-op in release builds (B.5.3: every pass
/// must preserve the verifier invariants).
pub fn afterPass(gpa: Allocator, m: *const ir.Module, pass: []const u8) void {
    if (builtin.mode != .debug) return;
    var failure: Failure = .{};
    verify(gpa, m, &failure) catch |e| switch (e) {
        error.OutOfMemory => std.debug.panic("P-IR verifier after pass '{s}': out of memory", .{pass}),
        error.Invalid => std.debug.panic("P-IR verifier after pass '{s}': {f}", .{ pass, failure }),
    };
}

const none = std.math.maxInt(u32);

const Verifier = struct {
    arena: Allocator,
    m: *const ir.Module,
    f: *const ir.Function,
    failure: *Failure,

    /// Per value: defining block (`none` if undefined) and position in it
    /// (0 for parameters, instruction index + 1 for results).
    def_block: []u32 = &.{},
    def_pos: []u32 = &.{},
    /// Per block: postorder number of the DFS from the entry (`none` if
    /// unreachable) and immediate dominator.
    po: []u32 = &.{},
    idom: []u32 = &.{},

    /// Current position, for failures and dominance checks.
    cur_block: ?u32 = null,
    cur_inst: ?u32 = null,

    fn fail(v: *Verifier, kind: Kind, msg: []const u8) error{Invalid} {
        v.failure.* = .{ .kind = kind, .msg = msg, .func = v.f.name, .block = v.cur_block, .inst = v.cur_inst };
        return error.Invalid;
    }

    fn want(v: *Verifier, ok: bool, kind: Kind, msg: []const u8) error{Invalid}!void {
        if (!ok) return v.fail(kind, msg);
    }

    fn run(v: *Verifier) Error!void {
        const f = v.f;
        const nvals = f.values.items.len;
        v.def_block = try v.arena.alloc(u32, nvals);
        v.def_pos = try v.arena.alloc(u32, nvals);
        @memset(v.def_block, none);

        for (f.params.items) |p| try v.define(p.value, 0, 0);
        try v.checkParamAttrs();
        if (f.isDeclaration()) return;

        try v.want(f.blocks.items[0].params.items.len == 0, .block_arity, "entry block must not have parameters");
        for (f.blocks.items, 0..) |b, bi| {
            v.cur_block = @intCast(bi);
            v.cur_inst = null;
            try v.want(b.insts.items.len != 0, .bad_terminator, "empty block");
            for (b.params.items) |p| try v.define(p, @intCast(bi), 0);
            for (b.insts.items, 0..) |inst, ii| {
                v.cur_inst = @intCast(ii);
                const last = ii + 1 == b.insts.items.len;
                if (last) try v.want(inst.op.isTerminator(), .bad_terminator, "block does not end in a terminator");
                if (!last) try v.want(!inst.op.isTerminator(), .bad_terminator, "terminator before the end of the block");
                for (inst.targets) |t| try v.want(t.block.index() < f.blocks.items.len, .bad_terminator, "branch to a block that does not exist");
                for (inst.results) |r| try v.define(r, @intCast(bi), @intCast(ii + 1));
            }
        }
        v.cur_block = null;
        v.cur_inst = null;

        try v.computeDominators();

        for (f.blocks.items, 0..) |b, bi| {
            v.cur_block = @intCast(bi);
            for (b.insts.items, 0..) |inst, ii| {
                v.cur_inst = @intCast(ii);
                try v.checkFlags(inst);
                try v.checkInst(inst, b.insts.items[ii + 1 ..]);
                for (inst.targets) |t| try v.checkTarget(t);
            }
        }
    }

    fn define(v: *Verifier, x: ir.Value, block: u32, pos: u32) error{Invalid}!void {
        const i = x.index();
        try v.want(i < v.def_block.len, .undefined_value, "defined value has no entry in the value table");
        try v.want(v.def_block[i] == none, .multiple_definition, "value defined twice");
        // B.5.1: `void` is only a return type; LLVM cannot name, pass or phi it.
        try v.want(isValue(v.f.typeOf(x)), .bad_result, "value of type void");
        v.def_block[i] = block;
        v.def_pos[i] = pos;
    }

    fn checkParamAttrs(v: *Verifier) error{Invalid}!void {
        for (v.f.params.items) |p| {
            const a = p.attrs;
            if (a.@"noalias" or a.readonly or a.@"align" != 0 or a.dereferenceable != 0)
                try v.want(v.f.typeOf(p.value).eql(.of(.ptr)), .bad_flag, "pointer attribute on a non-pointer parameter");
            try v.want(a.@"align" == 0 or std.math.isPowerOfTwo(a.@"align"), .bad_flag, "alignment is not a power of two");
        }
    }

    // ------------------------------------------------------------ CFG

    /// Computes postorder numbers, immediate dominators (Cooper, Harvey and
    /// Kennedy, "A Simple, Fast Dominance Algorithm") and checks reducibility.
    fn computeDominators(v: *Verifier) Error!void {
        const blocks = v.f.blocks.items;
        const n = blocks.len;
        v.po = try v.arena.alloc(u32, n);
        v.idom = try v.arena.alloc(u32, n);
        @memset(v.po, none);
        @memset(v.idom, none);
        const state = try v.arena.alloc(enum { new, open, done }, n);
        @memset(state, .new);
        var postorder: std.ArrayList(u32) = .empty;
        const Edge = struct { from: u32, to: u32 };
        var retreating: std.ArrayList(Edge) = .empty;
        const preds = try v.arena.alloc(std.ArrayList(u32), n);
        @memset(preds, .empty);

        // Iterative DFS: each stack entry is (block, index of next successor).
        const Frame = struct { block: u32, next: u32 };
        var stack: std.ArrayList(Frame) = .empty;
        try stack.append(v.arena, .{ .block = 0, .next = 0 });
        state[0] = .open;
        while (stack.items.len != 0) {
            const top = &stack.items[stack.items.len - 1];
            const succs = blocks[top.block].terminator().?.targets;
            if (top.next == succs.len) {
                state[top.block] = .done;
                v.po[top.block] = @intCast(postorder.items.len);
                try postorder.append(v.arena, top.block);
                stack.items.len -= 1;
                continue;
            }
            const from = top.block;
            const to = succs[top.next].block.index();
            top.next += 1;
            try preds[to].append(v.arena, from);
            switch (state[to]) {
                .new => {
                    state[to] = .open;
                    try stack.append(v.arena, .{ .block = to, .next = 0 });
                },
                .open => try retreating.append(v.arena, .{ .from = from, .to = to }),
                .done => {},
            }
        }

        v.idom[0] = 0;
        var changed = true;
        while (changed) {
            changed = false;
            var i = postorder.items.len - 1; // reverse postorder; the entry is last
            while (i > 0) {
                i -= 1;
                const b = postorder.items[i];
                var new: u32 = none;
                for (preds[b].items) |p| {
                    if (v.idom[p] == none) continue;
                    new = if (new == none) p else v.intersect(p, new);
                }
                if (v.idom[b] != new) {
                    v.idom[b] = new;
                    changed = true;
                }
            }
        }

        for (retreating.items) |e| if (!v.dominates(e.to, e.from)) {
            v.cur_block = e.from;
            return v.fail(.irreducible, "irreducible control flow: loop entered other than through its header");
        };
    }

    fn intersect(v: *Verifier, a: u32, b: u32) u32 {
        var x = a;
        var y = b;
        while (x != y) {
            while (v.po[x] < v.po[y]) x = v.idom[x];
            while (v.po[y] < v.po[x]) y = v.idom[y];
        }
        return x;
    }

    /// Whether block `a` dominates block `b`; both must be reachable.
    fn dominates(v: *Verifier, a: u32, b: u32) bool {
        var x = b;
        while (true) {
            if (x == a) return true;
            if (x == 0) return false;
            x = v.idom[x];
        }
    }

    // ------------------------------------------------------------ operands

    /// Checks that operand `i` is a value (or `@symbol`, a pointer) whose
    /// definition dominates the current instruction; returns its type.
    fn val(v: *Verifier, inst: Inst, i: usize) error{Invalid}!Type {
        return v.use(inst.operands[i]);
    }

    fn use(v: *Verifier, o: Operand) error{Invalid}!Type {
        switch (o) {
            .value => |x| {
                const i = x.index();
                try v.want(i < v.def_block.len and v.def_block[i] != none, .undefined_value, "use of an undefined value");
                const ub = v.cur_block.?;
                if (v.po[ub] != none) {
                    const db = v.def_block[i];
                    const ok = if (db == ub)
                        v.def_pos[i] <= v.cur_inst.?
                    else
                        v.po[db] != none and v.dominates(db, ub);
                    try v.want(ok, .not_dominated, "definition does not dominate this use");
                }
                return v.f.typeOf(x);
            },
            .symbol => |s| {
                try v.want(v.m.findFunction(s) != null or v.m.findGlobal(s) != null, .bad_symbol, "unknown symbol");
                return .of(.ptr);
            },
            else => return v.fail(.bad_operand, "expected a value operand"),
        }
    }

    fn lit(v: *Verifier, inst: Inst, i: usize) error{Invalid}!i64 {
        return switch (inst.operands[i]) {
            .int => |x| x,
            else => v.fail(.bad_operand, "expected an integer literal operand"),
        };
    }

    fn order(v: *Verifier, inst: Inst, i: usize) error{Invalid}!ir.Order {
        return switch (inst.operands[i]) {
            .order => |o| if (o == .none) v.fail(.bad_operand, "memory order must not be none") else o,
            else => v.fail(.bad_operand, "expected a memory order operand"),
        };
    }

    fn nOps(v: *Verifier, inst: Inst, n: usize) error{Invalid}!void {
        try v.want(inst.operands.len == n, .bad_operand, "wrong number of operands");
    }

    /// Checks the instruction has exactly one result and returns its type.
    fn result(v: *Verifier, inst: Inst) error{Invalid}!Type {
        try v.want(inst.results.len == 1, .bad_result, "expected exactly one result");
        return v.f.typeOf(inst.results[0]);
    }

    fn noResult(v: *Verifier, inst: Inst) error{Invalid}!void {
        try v.want(inst.results.len == 0, .bad_result, "instruction has no result");
    }

    fn resultIs(v: *Verifier, inst: Inst, t: Type) error{Invalid}!void {
        try v.want((try v.result(inst)).eql(t), .bad_result, "wrong result type");
    }

    fn isInt(t: Type) bool {
        return t.scalar.isInt();
    }

    fn isFloat(t: Type) bool {
        return t.scalar.isFloat();
    }

    fn isScalarInt(t: Type) bool {
        return t.lanes == 0 and t.scalar.isInt();
    }

    /// A first-class value type: anything but `void`.
    fn isValue(t: Type) bool {
        return t.scalar != .void;
    }

    /// A type LLVM accepts for atomic access: a byte-sized-or-wider scalar
    /// integer, a pointer, or (if `float_ok`) a float.
    fn isAtomic(t: Type, float_ok: bool) bool {
        return t.lanes == 0 and (t.scalar == .ptr or (isInt(t) and bits(t.scalar) >= 8) or (float_ok and isFloat(t)));
    }

    fn bits(s: ir.Scalar) u32 {
        return switch (s) {
            .i1 => 1,
            .i8 => 8,
            .i16 => 16,
            .i32, .f32 => 32,
            .i64, .f64 => 64,
            .ptr, .void => 0, // target-dependent / none
        };
    }

    fn checkFlags(v: *Verifier, inst: Inst) error{Invalid}!void {
        const fl = inst.flags;
        const op = inst.op;
        if (fl.nuw or fl.nsw) try v.want(switch (op) {
            .add, .sub, .mul, .shl => true,
            else => false,
        }, .bad_flag, "nuw/nsw only apply to add, sub, mul and shl");
        if (fl.fast) try v.want(switch (op) {
            .fadd, .fsub, .fmul, .fdiv, .frem, .fneg, .fma => true,
            else => false,
        }, .bad_flag, "fast only applies to float arithmetic");
        const mem = op == .load or op == .store;
        if (fl.@"volatile") try v.want(mem, .bad_flag, "volatile only applies to load and store");
        if (inst.atomic != .none) try v.want(mem, .bad_flag, "atomic only applies to load and store");
        if (op == .load) try v.want(inst.atomic != .release and inst.atomic != .acq_rel, .bad_flag, "invalid order for an atomic load");
        if (op == .store) try v.want(inst.atomic != .acquire and inst.atomic != .acq_rel, .bad_flag, "invalid order for an atomic store");
        if (fl.signed) try v.want(op == .@"bf.extract", .bad_flag, "signed only applies to bf.extract");
        try v.want(switch (op) {
            .icmp => inst.pred.isInt(),
            .fcmp => inst.pred.isFloat(),
            else => inst.pred == .none,
        }, .bad_flag, "predicate does not match the opcode");
        try v.want((op == .@"atomic.rmw") == (inst.rmw != .none), .bad_flag, "rmw operation does not match the opcode");
        try v.want(inst.@"align" == 0 or std.math.isPowerOfTwo(inst.@"align"), .bad_flag, "alignment is not a power of two");
        if (!op.isTerminator()) try v.want(inst.targets.len == 0, .bad_terminator, "branch targets on a non-terminator");
    }

    fn checkTarget(v: *Verifier, t: ir.Target) error{Invalid}!void {
        const params = v.f.blocks.items[t.block.index()].params.items;
        try v.want(t.args.len == params.len, .block_arity, "wrong number of block arguments");
        for (t.args, params) |a, p|
            try v.want((try v.use(a)).eql(v.f.typeOf(p)), .block_arg_type, "block argument type differs from the parameter type");
        try v.want(t.block.index() != 0, .bad_terminator, "branch to the entry block");
    }

    /// Checks operands and results of `inst`; `rest` are the instructions
    /// after it in its block.
    fn checkInst(v: *Verifier, inst: Inst, rest: []const Inst) Error!void {
        const ops = inst.operands;
        switch (inst.op) {
            .add, .sub, .mul, .udiv, .sdiv, .urem, .srem, .@"and", .@"or", .xor, .shl, .lshr, .ashr, .@"add.trap", .@"sub.trap", .@"mul.trap" => {
                try v.nOps(inst, 2);
                const t = try v.val(inst, 0);
                try v.want(isInt(t), .operand_type, "integer operation on a non-integer type");
                try v.want((try v.val(inst, 1)).eql(t), .operand_type, "operand types differ");
                try v.resultIs(inst, t);
            },
            .fadd, .fsub, .fmul, .fdiv, .frem, .fneg, .fma => {
                try v.nOps(inst, switch (inst.op) {
                    .fneg => 1,
                    .fma => 3,
                    else => 2,
                });
                const t = try v.val(inst, 0);
                try v.want(isFloat(t), .operand_type, "float operation on a non-float type");
                for (1..ops.len) |i| try v.want((try v.val(inst, i)).eql(t), .operand_type, "operand types differ");
                try v.resultIs(inst, t);
            },
            .icmp, .fcmp => {
                try v.nOps(inst, 2);
                const t = try v.val(inst, 0);
                if (inst.op == .icmp)
                    try v.want(isInt(t) or t.scalar == .ptr, .operand_type, "icmp on a non-integer type")
                else
                    try v.want(isFloat(t), .operand_type, "fcmp on a non-float type");
                try v.want((try v.val(inst, 1)).eql(t), .operand_type, "operand types differ");
                try v.resultIs(inst, .{ .scalar = .i1, .lanes = t.lanes });
            },
            .trunc, .zext, .sext, .fptrunc, .fpext, .@"fptoui.sat", .@"fptosi.sat", .uitofp, .sitofp, .bitcast, .ptrtoint, .inttoptr => {
                try v.nOps(inst, 1);
                try v.checkConvert(inst.op, try v.val(inst, 0), try v.result(inst));
            },
            .alloca => {
                try v.nOps(inst, 1);
                switch (ops[0]) {
                    .type => |t| try v.want(isValue(t), .operand_type, "alloca of void"),
                    else => return v.fail(.bad_operand, "alloca takes a type operand"),
                }
                try v.resultIs(inst, .of(.ptr));
            },
            .load => {
                try v.nOps(inst, 1);
                try v.ptr(inst, 0);
                const r = try v.result(inst);
                try v.want(isValue(r), .bad_result, "load of void");
                if (inst.atomic != .none) try v.want(isAtomic(r, true), .bad_result, "atomic load of an unsupported type");
            },
            .store => {
                try v.nOps(inst, 2);
                const t = try v.val(inst, 0);
                try v.want(isValue(t), .operand_type, "store of void");
                if (inst.atomic != .none) try v.want(isAtomic(t, true), .operand_type, "atomic store of an unsupported type");
                try v.ptr(inst, 1);
                try v.noResult(inst);
            },
            .gep => {
                try v.nOps(inst, 3);
                try v.ptr(inst, 0);
                try v.int(inst, 1);
                _ = try v.lit(inst, 2);
                try v.resultIs(inst, .of(.ptr));
            },
            .memcpy, .memset => {
                try v.nOps(inst, 3);
                try v.ptr(inst, 0);
                if (inst.op == .memcpy)
                    try v.ptr(inst, 1)
                else
                    try v.want((try v.val(inst, 1)).eql(.of(.i8)), .operand_type, "memset byte must be i8");
                try v.int(inst, 2);
                try v.noResult(inst);
            },
            .@"soa.col" => {
                try v.nOps(inst, 2);
                try v.ptr(inst, 0);
                try v.field(inst, 1);
                try v.resultIs(inst, .of(.ptr));
            },
            .@"soa.load" => {
                try v.nOps(inst, 3);
                try v.ptr(inst, 0);
                try v.int(inst, 1);
                try v.field(inst, 2);
                try v.want(isValue(try v.result(inst)), .bad_result, "load of void");
            },
            .@"soa.store" => {
                try v.nOps(inst, 4);
                try v.ptr(inst, 0);
                try v.int(inst, 1);
                try v.field(inst, 2);
                try v.want(isValue(try v.val(inst, 3)), .operand_type, "store of void");
                try v.noResult(inst);
            },
            .@"bf.extract", .@"bf.insert" => {
                const insert = inst.op == .@"bf.insert";
                try v.nOps(inst, if (insert) 4 else 3);
                const unit = try v.val(inst, 0);
                try v.want(isScalarInt(unit), .operand_type, "bit-field unit must be a scalar integer");
                if (insert) try v.want(isScalarInt(try v.val(inst, 1)), .operand_type, "inserted bit field must be a scalar integer");
                const off = try v.lit(inst, ops.len - 2);
                const width = try v.lit(inst, ops.len - 1);
                const ub = bits(unit.scalar);
                try v.want(off >= 0 and width > 0 and off < ub and width <= ub - off, .bad_operand, "bit field lies outside its unit");
                const r = try v.result(inst);
                if (insert)
                    try v.want(r.eql(unit), .bad_result, "wrong result type")
                else
                    try v.want(isScalarInt(r) and bits(r.scalar) >= width, .bad_result, "bit field does not fit the result type");
            },
            .splat => {
                try v.nOps(inst, 1);
                const x = try v.val(inst, 0);
                try v.want(x.lanes == 0 and isValue(x), .operand_type, "splat of a non-scalar");
                const r = try v.result(inst);
                try v.want(r.isVector() and r.scalar == x.scalar, .bad_result, "wrong result type");
            },
            .extract, .insert => {
                const insert = inst.op == .insert;
                try v.nOps(inst, if (insert) 3 else 2);
                const vec = try v.vector(inst, 0);
                if (insert) try v.want((try v.val(inst, 1)).eql(.of(vec.scalar)), .operand_type, "inserted element type differs from the lane type");
                const lane = try v.lit(inst, ops.len - 1);
                try v.want(lane >= 0 and lane < vec.lanes, .bad_operand, "lane index out of range");
                try v.resultIs(inst, if (insert) vec else .of(vec.scalar));
            },
            .shuffle => {
                try v.want(ops.len > 2, .bad_operand, "shuffle needs a mask");
                const vec = try v.vector(inst, 0);
                try v.want((try v.val(inst, 1)).eql(vec), .operand_type, "operand types differ");
                for (2..ops.len) |i| {
                    const l = try v.lit(inst, i);
                    try v.want(l >= 0 and l < 2 * @as(i64, vec.lanes), .bad_operand, "shuffle lane out of range");
                }
                try v.resultIs(inst, .vec(@intCast(ops.len - 2), vec.scalar));
            },
            .select => {
                try v.nOps(inst, 3);
                const c = try v.val(inst, 0);
                const t = try v.val(inst, 1);
                try v.want(c.scalar == .i1 and (c.lanes == 0 or c.lanes == t.lanes), .operand_type, "select condition must be i1 or a matching vector of i1");
                try v.want(isValue(t), .operand_type, "select of void");
                try v.want((try v.val(inst, 2)).eql(t), .operand_type, "operand types differ");
                try v.resultIs(inst, t);
            },
            .@"reduce.add", .@"reduce.mul", .@"reduce.min", .@"reduce.max", .@"reduce.and", .@"reduce.or" => {
                try v.nOps(inst, 1);
                const vec = try v.vector(inst, 0);
                const bitwise = inst.op == .@"reduce.and" or inst.op == .@"reduce.or";
                try v.want(isInt(vec) or (!bitwise and isFloat(vec)), .operand_type, "reduction over an unsupported lane type");
                try v.resultIs(inst, .of(vec.scalar));
            },
            .@"load.masked" => {
                try v.nOps(inst, 3);
                try v.ptr(inst, 0);
                const m = try v.mask(inst, 1);
                const pass = try v.vector(inst, 2);
                try v.want(pass.lanes == m.lanes, .operand_type, "mask and value lane counts differ");
                try v.resultIs(inst, pass);
            },
            .@"store.masked" => {
                try v.nOps(inst, 3);
                const vec = try v.vector(inst, 0);
                try v.ptr(inst, 1);
                try v.want((try v.mask(inst, 2)).lanes == vec.lanes, .operand_type, "mask and value lane counts differ");
                try v.noResult(inst);
            },
            .bounds => {
                try v.nOps(inst, 2);
                const t = try v.val(inst, 0);
                try v.want(isScalarInt(t), .operand_type, "bounds index must be a scalar integer");
                try v.want((try v.val(inst, 1)).eql(t), .operand_type, "operand types differ");
                try v.noResult(inst);
            },
            .trap => {
                try v.nOps(inst, 2);
                _ = try v.lit(inst, 0);
                _ = try v.lit(inst, 1);
                try v.noResult(inst);
            },
            .@"handle.lookup" => {
                try v.nOps(inst, 2);
                try v.ptr(inst, 0);
                try v.int(inst, 1);
                try v.want(inst.results.len == 2, .bad_result, "handle.lookup defines (dense_index, ok)");
                try v.want(isScalarInt(v.f.typeOf(inst.results[0])), .bad_result, "dense index must be a scalar integer");
                try v.want(v.f.typeOf(inst.results[1]).eql(.of(.i1)), .bad_result, "ok result must be i1");
            },
            .call, .@"call.tail", .spawn => try v.checkCall(inst, rest),
            .@"call.indirect" => {
                try v.want(ops.len >= 1, .bad_operand, "call.indirect needs a callee");
                try v.want(ops[0] == .value, .bad_operand, "call.indirect callee must be a value");
                try v.ptr(inst, 0);
                for (1..ops.len) |i| try v.want(isValue(try v.val(inst, i)), .operand_type, "argument of type void");
                try v.want(inst.results.len <= 1, .bad_result, "call defines at most one result");
            },
            .@"nursery.begin", .@"nursery.end", .@"pfor.end" => {
                // Operands are runtime-defined; they must still be valid uses.
                for (0..ops.len) |i| _ = try v.val(inst, i);
                try v.want(inst.results.len <= 1, .bad_result, "too many results");
            },
            .@"pfor.begin" => {
                try v.want(ops.len >= 2, .bad_operand, "pfor.begin takes a range and a chunk size");
                for (0..ops.len) |i| try v.int(inst, i);
                try v.want(inst.results.len <= 1, .bad_result, "too many results");
            },
            .@"atomic.rmw" => {
                try v.nOps(inst, 3);
                try v.ptr(inst, 0);
                const t = try v.val(inst, 1);
                const xchg = inst.rmw == .xchg;
                try v.want(isAtomic(t, xchg) and (xchg or isInt(t)), .operand_type, "atomic.rmw on an unsupported type");
                _ = try v.order(inst, 2);
                try v.resultIs(inst, t);
            },
            .cmpxchg => {
                try v.nOps(inst, 5);
                try v.ptr(inst, 0);
                const t = try v.val(inst, 1);
                try v.want(isAtomic(t, false), .operand_type, "cmpxchg on an unsupported type");
                try v.want((try v.val(inst, 2)).eql(t), .operand_type, "operand types differ");
                _ = try v.order(inst, 3);
                const fo = try v.order(inst, 4);
                try v.want(fo != .release and fo != .acq_rel, .bad_operand, "invalid failure order");
                try v.want(inst.results.len == 1 or inst.results.len == 2, .bad_result, "cmpxchg defines (old) or (old, ok)");
                try v.want(v.f.typeOf(inst.results[0]).eql(t), .bad_result, "wrong result type");
                if (inst.results.len == 2) try v.want(v.f.typeOf(inst.results[1]).eql(.of(.i1)), .bad_result, "ok result must be i1");
            },
            .fence => {
                try v.nOps(inst, 1);
                try v.want(try v.order(inst, 0) != .relaxed, .bad_operand, "fence cannot be relaxed");
                try v.noResult(inst);
            },
            .@"const" => {
                try v.nOps(inst, 1);
                const r = try v.result(inst);
                try v.want(r.lanes == 0, .bad_result, "const of a vector type");
                switch (ops[0]) {
                    .int => try v.want(r.scalar.isInt(), .bad_result, "integer constant of a non-integer type"),
                    .float => try v.want(r.scalar.isFloat(), .bad_result, "float constant of a non-float type"),
                    else => return v.fail(.bad_operand, "const takes an integer or float literal"),
                }
            },
            .br => {
                try v.want(ops.len == 0 and inst.targets.len == 1, .bad_operand, "br takes exactly one target");
                try v.noResult(inst);
            },
            .cond_br => {
                try v.want(ops.len == 1 and inst.targets.len == 2, .bad_operand, "cond_br takes a condition and two targets");
                try v.want((try v.val(inst, 0)).eql(.of(.i1)), .operand_type, "condition must be i1");
                try v.noResult(inst);
            },
            .@"switch" => {
                try v.want(ops.len == 1 and inst.targets.len >= 1, .bad_operand, "switch takes a value and a default target");
                const t = try v.val(inst, 0);
                try v.want(isScalarInt(t), .operand_type, "switch on a non-integer");
                // Keys must fit the scrutinee (signed or unsigned) and differ once truncated to it.
                const b: u6 = @intCast(bits(t.scalar) - 1);
                const lo = -(@as(i64, 1) << b);
                const key_mask = (@as(u64, 2) << b) -% 1;
                const cases = inst.targets[1..];
                for (cases, 0..) |c, i| {
                    try v.want(b == 63 or (c.key >= lo and c.key <= @as(i64, @intCast(key_mask))), .bad_operand, "switch case does not fit the scrutinee type");
                    for (cases[0..i]) |d|
                        try v.want((@as(u64, @bitCast(c.key)) ^ @as(u64, @bitCast(d.key))) & key_mask != 0, .bad_operand, "duplicate switch case");
                }
                try v.noResult(inst);
            },
            .ret => {
                try v.noResult(inst);
                if (v.f.ret.scalar == .void) return v.nOps(inst, 0);
                try v.nOps(inst, 1);
                try v.want((try v.val(inst, 0)).eql(v.f.ret), .operand_type, "returned value differs from the return type");
            },
            .@"unreachable" => {
                try v.nOps(inst, 0);
                try v.noResult(inst);
            },
        }
    }

    fn checkCall(v: *Verifier, inst: Inst, rest: []const Inst) Error!void {
        const ops = inst.operands;
        try v.want(ops.len >= 1 and ops[0] == .symbol, .bad_operand, "call needs a @function callee");
        const callee = v.m.findFunction(ops[0].symbol) orelse return v.fail(.bad_symbol, "callee is not a function");
        const params = callee.params.items;
        try v.want(ops.len - 1 == params.len, .bad_symbol, "wrong number of call arguments");
        for (params, 1..) |p, i| {
            // The callee may not be verified yet; do not trust its value table.
            try v.want(p.value.index() < callee.values.items.len, .bad_symbol, "callee parameter has no entry in its value table");
            try v.want((try v.val(inst, i)).eql(callee.typeOf(p.value)), .bad_symbol, "call argument type differs from the parameter type");
        }
        if (inst.op == .spawn or callee.ret.scalar == .void)
            try v.noResult(inst)
        else
            try v.resultIs(inst, callee.ret);
        if (inst.op == .@"call.tail") {
            // musttail: the call must be directly returned, and caller and
            // callee prototypes must match.
            try v.want(callee.ret.eql(v.f.ret), .bad_symbol, "call.tail callee return type differs from the caller's");
            try v.want(params.len == v.f.params.items.len, .bad_symbol, "call.tail callee parameter count differs from the caller's");
            for (params, v.f.params.items) |p, q|
                try v.want(callee.typeOf(p.value).eql(v.f.typeOf(q.value)), .bad_symbol, "call.tail callee parameter types differ from the caller's");
            const ok = rest.len == 1 and rest[0].op == .ret and
                (inst.results.len == 0 or (rest[0].operands.len == 1 and rest[0].operands[0] == .value and
                    rest[0].operands[0].value == inst.results[0]));
            try v.want(ok, .bad_terminator, "call.tail must be followed by ret of its result");
        }
    }

    fn checkConvert(v: *Verifier, op: Op, from: Type, to: Type) error{Invalid}!void {
        if (op != .bitcast) try v.want(from.lanes == to.lanes, .operand_type, "conversion changes the lane count");
        const a = from.scalar;
        const b = to.scalar;
        const ok = switch (op) {
            .trunc => a.isInt() and b.isInt() and bits(a) > bits(b),
            .zext, .sext => a.isInt() and b.isInt() and bits(a) < bits(b),
            .fptrunc => a == .f64 and b == .f32,
            .fpext => a == .f32 and b == .f64,
            .@"fptoui.sat", .@"fptosi.sat" => a.isFloat() and b.isInt(),
            .uitofp, .sitofp => a.isInt() and b.isFloat(),
            .bitcast => bits(a) != 0 and bits(b) != 0 and
                bits(a) * @max(from.lanes, 1) == bits(b) * @max(to.lanes, 1),
            .ptrtoint => a == .ptr and b.isInt(),
            .inttoptr => a.isInt() and b == .ptr,
            else => unreachable,
        };
        try v.want(ok, .operand_type, "invalid conversion types");
    }

    fn ptr(v: *Verifier, inst: Inst, i: usize) error{Invalid}!void {
        try v.want((try v.val(inst, i)).eql(.of(.ptr)), .operand_type, "expected a ptr operand");
    }

    fn int(v: *Verifier, inst: Inst, i: usize) error{Invalid}!void {
        try v.want(isScalarInt(try v.val(inst, i)), .operand_type, "expected a scalar integer operand");
    }

    fn field(v: *Verifier, inst: Inst, i: usize) error{Invalid}!void {
        try v.want((try v.lit(inst, i)) >= 0, .bad_operand, "negative field index");
    }

    fn vector(v: *Verifier, inst: Inst, i: usize) error{Invalid}!Type {
        const t = try v.val(inst, i);
        try v.want(t.isVector(), .operand_type, "expected a vector operand");
        return t;
    }

    fn mask(v: *Verifier, inst: Inst, i: usize) error{Invalid}!Type {
        const t = try v.vector(inst, i);
        try v.want(t.scalar == .i1, .operand_type, "mask must be a vector of i1");
        return t;
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;
const text = @import("text.zig");
const Builder = @import("builder.zig").Builder;

fn parse(src: []const u8) !ir.Module {
    var diag: text.Diag = .{};
    return text.parse(testing.allocator, src, &diag) catch |e| {
        std.debug.print("parse error {d}:{d}: {s}\n", .{ diag.line, diag.col, diag.msg });
        return e;
    };
}

fn expectValid(src: []const u8) !void {
    var m = try parse(src);
    defer m.deinit();
    var failure: Failure = .{};
    verify(testing.allocator, &m, &failure) catch |e| {
        if (e == error.Invalid) std.debug.print("unexpected verifier failure: {f}\n", .{failure});
        return e;
    };
    afterPass(testing.allocator, &m, "test");
}

fn expectFailure(kind: Kind, m: *const ir.Module) !void {
    var failure: Failure = .{};
    try testing.expectError(error.Invalid, verify(testing.allocator, m, &failure));
    if (failure.kind != kind) std.debug.print("got {f}\n", .{failure});
    try testing.expectEqual(kind, failure.kind);
}

fn expectInvalid(kind: Kind, src: []const u8) !void {
    var m = try parse(src);
    defer m.deinit();
    try expectFailure(kind, &m);
}

test "valid modules cover every opcode" {
    const srcs = [_][]const u8{
        \\global @counter: i64 = 0 align 8
        \\global @msg: i8 = "hi" readonly
        \\
        \\fn @int_ops(%a: i32, %b: i32) -> i32 {
        \\^entry:
        \\  %r0: i32 = add nuw nsw %a, %b
        \\  %r1: i32 = sub nsw %r0, %b
        \\  %r2: i32 = mul nuw %r1, %a
        \\  %r3: i32 = udiv %r2, %b
        \\  %r4: i32 = sdiv %r3, %b
        \\  %r5: i32 = urem %r4, %b
        \\  %r6: i32 = srem %r5, %b
        \\  %r7: i32 = and %r6, %a
        \\  %r8: i32 = or %r7, %a
        \\  %r9: i32 = xor %r8, %a
        \\  %r10: i32 = shl nuw %r9, %b
        \\  %r11: i32 = lshr %r10, %b
        \\  %r12: i32 = ashr %r11, %b
        \\  %t0: i32 = add.trap %r12, %a
        \\  %t1: i32 = sub.trap %t0, %a
        \\  %t2: i32 = mul.trap %t1, %a
        \\  ret %t2
        \\}
        \\
        \\fn @float_ops(%x: f64, %y: f64, %v: vec<4 x f32>) -> f64 {
        \\^entry:
        \\  %k: f64 = const 0.5
        \\  %f0: f64 = fadd %x, %y
        \\  %f1: f64 = fsub fast %f0, %k
        \\  %f2: f64 = fmul %f1, %k
        \\  %f3: f64 = fdiv %f2, %k
        \\  %f4: f64 = frem %f3, %y
        \\  %f5: f64 = fneg %f4
        \\  %f6: f64 = fma %f5, %x, %y
        \\  %w: vec<4 x f32> = fadd %v, %v
        \\  br ^out(%f6)
        \\^out(%r: f64):
        \\  ret %r
        \\}
        \\
        \\fn @cmp_conv(%a: i32, %x: f64, %p: ptr) -> i1 {
        \\^entry:
        \\  %c0: i1 = icmp eq %a, %a
        \\  %c1: i1 = icmp eq %p, %p
        \\  %c2: i1 = fcmp olt %x, %x
        \\  %n0: i8 = trunc %a
        \\  %n1: i64 = zext %n0
        \\  %n2: i64 = sext %a
        \\  %n3: f32 = fptrunc %x
        \\  %n4: f64 = fpext %n3
        \\  %n5: i32 = fptoui.sat %x
        \\  %n6: i32 = fptosi.sat %x
        \\  %n7: f64 = uitofp %a
        \\  %n8: f64 = sitofp %a
        \\  %n9: i64 = bitcast %x
        \\  %n10: i64 = ptrtoint %p
        \\  %n11: ptr = inttoptr %n10
        \\  ret %c0
        \\}
        \\
        \\fn @memory(%dst: ptr noalias align(16) dereferenceable(64), %src: ptr readonly, %n: i64) -> void {
        \\^entry:
        \\  %slot: ptr = alloca i64, align 8
        \\  %v: i64 = load %src, align 8
        \\  %vv: i64 = load volatile atomic(acquire) %src, align 8
        \\  %g: i64 = load @counter
        \\  store %v, %slot, align 8
        \\  store volatile atomic(release) %vv, %dst
        \\  %q: ptr = gep %dst, %n, 8
        \\  memcpy %q, %src, %n
        \\  %zero: i8 = const 0
        \\  memset %dst, %zero, %n
        \\  %col: ptr = soa.col %dst, 2
        \\  %e: f32 = soa.load %dst, %n, 1
        \\  soa.store %dst, %n, 1, %e
        \\  %u: i32 = trunc %v
        \\  %bx: i32 = bf.extract signed %u, 3, 5
        \\  %bi: i32 = bf.insert %u, %bx, 3, 5
        \\  bounds %n, %v
        \\  %idx: i32, %ok: i1 = handle.lookup %src, %n
        \\  cond_br %ok, ^done, ^fail
        \\^fail:
        \\  trap 2, 17
        \\  unreachable
        \\^done:
        \\  ret
        \\}
        \\
        \\fn @vector(%p: ptr, %x: f32, %m: vec<4 x i1>) -> f32 {
        \\^entry:
        \\  %s: vec<4 x f32> = splat %x
        \\  %l: vec<4 x f32> = load.masked %p, %m, %s, align 16
        \\  %e: f32 = extract %l, 0
        \\  %i: vec<4 x f32> = insert %l, %e, 3
        \\  %sh: vec<4 x f32> = shuffle %l, %i, 0, 4, 1, 5
        \\  %sel: vec<4 x f32> = select %m, %sh, %s
        \\  store.masked %sel, %p, %m, align 16
        \\  %ra: f32 = reduce.add %sel
        \\  %rm: f32 = reduce.mul %sel
        \\  %rn: f32 = reduce.min %sel
        \\  %rx: f32 = reduce.max %sel
        \\  %bits: vec<4 x i32> = bitcast %sel
        \\  %rand: i32 = reduce.and %bits
        \\  %ror: i32 = reduce.or %bits
        \\  ret %ra
        \\}
        \\
        \\fn @callee(%a: i32) -> i32 inline cold
        \\
        \\fn @tail(%b: i32) -> i32 {
        \\^entry:
        \\  %t: i32 = call.tail @callee(%b)
        \\  ret %t
        \\}
        \\
        \\fn @calls(%fp: ptr, %a: i32, %n: i64, %p: ptr) -> i32 {
        \\^entry:
        \\  %r0: i32 = call @callee(%a)
        \\  %r1: i32 = call.indirect %fp(%r0)
        \\  %nur: ptr = nursery.begin
        \\  spawn @callee(%r1)
        \\  nursery.end %nur
        \\  %zero: i64 = const 0
        \\  %chunk: i64 = const 64
        \\  %it: i64 = pfor.begin %zero, %n, %chunk
        \\  pfor.end
        \\  %old: i32 = atomic.rmw add %p, %a, seq_cst
        \\  %prev: i32, %ok: i1 = cmpxchg %p, %old, %a, acq_rel, relaxed
        \\  fence seq_cst
        \\  switch %a, default ^exit(%a), [0: ^loop(%zero), -1: ^exit(%r1)]
        \\^loop(%i: i64):
        \\  %next: i64 = add %i, %chunk
        \\  %more: i1 = icmp ult %next, %n
        \\  cond_br %more, ^loop(%next), ^tail
        \\^tail:
        \\  %t: i32 = call @callee(%a)
        \\  ret %t
        \\^exit(%x: i32):
        \\  ret %x
        \\}
        \\
    };
    var seen: std.EnumSet(Op) = .empty;
    for (srcs) |src| {
        try expectValid(src);
        var m = try parse(src);
        defer m.deinit();
        for (m.functions.items) |f| for (f.blocks.items) |b| for (b.insts.items) |inst| seen.insert(inst.op);
    }
    try testing.expect(seen.complement().count() == 0);
}

test "ssa: use of an undefined value" {
    var m = try ir.Module.init(testing.allocator);
    defer m.deinit();
    const f = try m.addFunction("f", .of(.i32));
    const entry = try f.addBlock("entry");
    const ghost = try f.newValue(.of(.i32), "ghost"); // never defined
    var b: Builder = .init(f, entry);
    try b.ret(ghost);
    try expectFailure(.undefined_value, &m);
}

test "ssa: value defined twice" {
    var m = try ir.Module.init(testing.allocator);
    defer m.deinit();
    const f = try m.addFunction("f", .of(.i32));
    const entry = try f.addBlock("entry");
    var b: Builder = .init(f, entry);
    const x = try b.constInt(.of(.i32), 1);
    try f.append(entry, .{ .op = .@"const", .results = &.{x}, .operands = &.{.{ .int = 2 }} });
    try b.ret(x);
    try expectFailure(.multiple_definition, &m);
}

test "ssa: duplicate symbol" {
    var m = try ir.Module.init(testing.allocator);
    defer m.deinit();
    _ = try m.addFunction("f", .void);
    try m.addGlobal(.{ .name = "f", .ty = .of(.i32), .init = .zero });
    try expectFailure(.multiple_definition, &m);
}

test "dominance: use before definition in the same block" {
    try expectInvalid(.not_dominated,
        \\fn @f(%a: i32) -> i32 {
        \\^entry:
        \\  %y: i32 = add %x, %a
        \\  %x: i32 = add %a, %a
        \\  ret %y
        \\}
        \\
    );
}

test "dominance: use in a block the definition does not dominate" {
    try expectInvalid(.not_dominated,
        \\fn @f(%c: i1, %a: i32) -> i32 {
        \\^entry:
        \\  cond_br %c, ^left, ^join
        \\^left:
        \\  %x: i32 = add %a, %a
        \\  br ^join
        \\^join:
        \\  ret %x
        \\}
        \\
    );
    // Passing it as a block argument from where it dominates is fine.
    try expectValid(
        \\fn @f(%c: i1, %a: i32) -> i32 {
        \\^entry:
        \\  cond_br %c, ^left, ^join(%a)
        \\^left:
        \\  %x: i32 = add %a, %a
        \\  br ^join(%x)
        \\^join(%r: i32):
        \\  ret %r
        \\}
        \\
    );
}

test "dominance: unreachable blocks are not checked" {
    try expectValid(
        \\fn @f(%a: i32) -> i32 {
        \\^entry:
        \\  ret %a
        \\^dead:
        \\  ret %x
        \\^dead2:
        \\  %x: i32 = add %a, %a
        \\  br ^dead
        \\}
        \\
    );
}

test "block params: arity" {
    try expectInvalid(.block_arity,
        \\fn @f(%a: i32) -> i32 {
        \\^entry:
        \\  br ^next(%a, %a)
        \\^next(%x: i32):
        \\  ret %x
        \\}
        \\
    );
    try expectInvalid(.block_arity,
        \\fn @f(%a: i32) -> i32 {
        \\^entry(%x: i32):
        \\  ret %x
        \\}
        \\
    );
}

test "block params: types" {
    try expectInvalid(.block_arg_type,
        \\fn @f(%a: i32) -> i64 {
        \\^entry:
        \\  br ^next(%a)
        \\^next(%x: i64):
        \\  ret %x
        \\}
        \\
    );
}

test "operand types" {
    const cases = [_]struct { Kind, []const u8 }{
        .{ .operand_type, "fn @f(%a: i32, %b: i64) -> i32 {\n^entry:\n  %r: i32 = add %a, %b\n  ret %r\n}\n" },
        .{ .operand_type, "fn @f(%a: f32) -> f32 {\n^entry:\n  %r: f32 = add %a, %a\n  ret %r\n}\n" },
        .{ .operand_type, "fn @f(%a: i32) -> i32 {\n^entry:\n  %r: i32 = fadd %a, %a\n  ret %r\n}\n" },
        .{ .operand_type, "fn @f(%a: i32) -> i64 {\n^entry:\n  %r: i64 = trunc %a\n  ret %r\n}\n" },
        .{ .operand_type, "fn @f(%a: i32) -> void {\n^entry:\n  %v: i32 = load %a\n  ret\n}\n" },
        .{ .operand_type, "fn @f(%a: i32) -> i32 {\n^entry:\n  ret %a\n^b:\n  cond_br %a, ^b, ^b\n}\n" },
        .{ .operand_type, "fn @f(%a: i32) -> i64 {\n^entry:\n  ret %a\n}\n" },
        .{ .bad_result, "fn @f(%a: i32) -> i64 {\n^entry:\n  %r: i64 = add %a, %a\n  ret %r\n}\n" },
        .{ .bad_result, "fn @f(%a: i32) -> i32 {\n^entry:\n  %c: i32 = icmp eq %a, %a\n  ret %c\n}\n" },
        .{ .bad_flag, "fn @f(%a: f32) -> f32 {\n^entry:\n  %r: f32 = fadd nsw %a, %a\n  ret %r\n}\n" },
        .{ .bad_flag, "fn @f(%a: i32) -> i32 {\n^entry:\n  %r: i32 = add fast %a, %a\n  ret %r\n}\n" },
        .{ .bad_operand, "fn @f(%v: vec<4 x f32>) -> f32 {\n^entry:\n  %e: f32 = extract %v, 4\n  ret %e\n}\n" },
        .{ .bad_operand, "fn @f(%u: i8) -> i8 {\n^entry:\n  %e: i8 = bf.extract %u, 4, 5\n  ret %e\n}\n" },
        .{ .bad_symbol, "fn @g(%a: i64) -> void\nfn @f(%a: i32) -> void {\n^entry:\n  call @g(%a)\n  ret\n}\n" },
        .{ .bad_symbol, "fn @f(%a: i32) -> ptr {\n^entry:\n  %p: ptr = inttoptr %a\n  ret @nowhere\n}\n" },
        .{ .bad_symbol, "fn @g(%a: i32, %b: i32) -> i32\nfn @f(%a: i32) -> i32 {\n^entry:\n  %r: i32 = call.tail @g(%a, %a)\n  ret %r\n}\n" },
        .{ .bad_result, "fn @f(%a: void) -> void {\n^entry:\n  ret\n}\n" },
        .{ .bad_result, "fn @f(%p: ptr) -> void {\n^entry:\n  %r: void = call.indirect %p()\n  ret\n}\n" },
        .{ .bad_operand, "fn @f() -> void {\n^entry:\n  fence relaxed\n  ret\n}\n" },
        .{ .operand_type, "fn @f(%p: ptr, %q: ptr) -> ptr {\n^entry:\n  %r: ptr = atomic.rmw add %p, %q, seq_cst\n  ret %r\n}\n" },
        .{ .operand_type, "fn @f(%p: ptr, %b: i1) -> i1 {\n^entry:\n  %r: i1 = atomic.rmw add %p, %b, seq_cst\n  ret %r\n}\n" },
        .{ .bad_result, "fn @f(%p: ptr) -> vec<4 x f32> {\n^entry:\n  %r: vec<4 x f32> = load atomic(acquire) %p\n  ret %r\n}\n" },
        .{ .bad_operand, "fn @f(%a: i8) -> void {\n^entry:\n  switch %a, default ^x, [0: ^x, 256: ^x]\n^x:\n  ret\n}\n" },
        .{ .bad_operand, "fn @f(%a: i8) -> void {\n^entry:\n  switch %a, default ^x, [-1: ^x, 255: ^x]\n^x:\n  ret\n}\n" },
        .{ .bad_terminator, "fn @g() -> i32\nfn @f() -> i32 {\n^entry:\n  %r: i32 = call.tail @g()\n  %s: i32 = add %r, %r\n  ret %s\n}\n" },
    };
    for (cases) |c| {
        expectInvalid(c[0], c[1]) catch |e| {
            std.debug.print("case:\n{s}\n", .{c[1]});
            return e;
        };
    }
}

test "ssa: malformed callee does not crash the caller's check" {
    var m = try ir.Module.init(testing.allocator);
    defer m.deinit();
    const f = try m.addFunction("f", .void);
    const entry = try f.addBlock("entry");
    var b: Builder = .init(f, entry);
    const x = try b.constInt(.of(.i32), 1);
    _ = try b.call("g", .void, &.{x});
    try b.ret(null);
    const g = try m.addFunction("g", .void);
    try g.params.append(g.arena, .{ .value = @fromBackingInt(5) }); // no value table entry
    try expectFailure(.bad_symbol, &m);
}

test "terminators" {
    var m = try ir.Module.init(testing.allocator);
    defer m.deinit();
    const f = try m.addFunction("f", .void);
    const entry = try f.addBlock("entry");
    var b: Builder = .init(f, entry);
    _ = try b.constInt(.of(.i32), 1);
    try expectFailure(.bad_terminator, &m); // missing terminator

    try b.ret(null);
    try b.ret(null);
    try expectFailure(.bad_terminator, &m); // terminator before the end

    f.block(entry).insts.items.len = 1;
    try b.br(@fromBackingInt(7), &.{});
    try expectFailure(.bad_terminator, &m); // target does not exist

    f.block(entry).insts.items.len = 1;
    try b.ret(null);
    _ = try f.addBlock("empty");
    try expectFailure(.bad_terminator, &m); // empty block
}

test "reducibility" {
    // Two entries into the cycle a <-> b: neither header dominates the other.
    try expectInvalid(.irreducible,
        \\fn @f(%c: i1) -> void {
        \\^entry:
        \\  cond_br %c, ^a, ^b
        \\^a:
        \\  br ^b
        \\^b:
        \\  cond_br %c, ^a, ^exit
        \\^exit:
        \\  ret
        \\}
        \\
    );
    // A natural loop with nested back edges is reducible.
    try expectValid(
        \\fn @f(%c: i1) -> void {
        \\^entry:
        \\  br ^head
        \\^head:
        \\  cond_br %c, ^body, ^exit
        \\^body:
        \\  cond_br %c, ^body, ^head
        \\^exit:
        \\  ret
        \\}
        \\
    );
}

test "failure formatting" {
    var buf: [128]u8 = undefined;
    const fl: Failure = .{ .kind = .not_dominated, .msg = "m", .func = "f", .block = 1, .inst = 2 };
    try testing.expectEqualStrings("@f block 1 inst 2: m (not_dominated)", try std.fmt.bufPrint(&buf, "{f}", .{fl}));
}
