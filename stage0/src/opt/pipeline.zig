//! Pass manager and `opt_level` pipelines (spec B.5.3, §13.9, §13.3).
//!
//! A pipeline is an ordered list of `Pass`es. Every pipeline starts with
//! canonicalization (B.5.3 step 2, required at every level), then adds the
//! passes of its level:
//!
//! | Level | Passes after canonicalize                                     |
//! |-------|---------------------------------------------------------------|
//! | `O0`  | none                                                          |
//! | `O1`  | inline, sroa, gvn, sccp                                       |
//! | `O2`  | O1 + loops, indvar, bce, licm, vectorize, unroll              |
//! | `O3`  | O2 + inline_aggressive, lto (`lto` is a no-op unless enabled) |
//! | `Oz`  | O2 without unroll, + outline_cold                             |
//!
//! `simd_enforce` (mandatory `@simd` vectorization) ends every list, `O0`
//! included. No level changes observable behaviour (§13.9); every pass must
//! preserve the verifier invariants and trap behaviour (B.5.3).
//!
//! Passes owned by later tasks are listed in `registry` as placeholders
//! (`run` is null): they run as no-ops until their owner fills them in, so
//! pipelines keep their final shape today.
//!
//! Function passes run on every defined function in parallel (one `Io.Group`
//! task per function); module passes run alone. With `Options.verify`, the
//! verifier checks the whole module before the first pass and after every
//! pass that ran, and the first violation names the pass that caused it.

const std = @import("std");
const builtin = @import("builtin");
const ir = @import("../pir/ir.zig");
const verify = @import("../pir/verify.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// `opt_level` environment key values (§13.3). Parse with
/// `std.meta.stringToEnum(OptLevel, "O2")`.
pub const OptLevel = enum { O0, O1, O2, O3, Oz };

/// Settings visible to passes and to the pass manager.
pub const Options = struct {
    level: OptLevel,
    /// `lto` environment key (§13.3): enables cross-module optimization at O3.
    lto: bool = false,
    /// Verify the module before the pipeline and after every pass that ran.
    verify: bool = builtin.mode == .debug,
};

/// A function pass. It may change only `f`'s body (blocks, instructions,
/// values), allocating from `f.arena`; it must not change any signature and
/// may read other functions' signatures through `m` only, because other
/// functions are transformed concurrently. `gpa` is for scratch memory.
pub const FunctionPassFn = *const fn (gpa: Allocator, opts: *const Options, m: *const ir.Module, f: *ir.Function) Allocator.Error!void;

/// A module pass: runs alone and may change anything in `m`.
pub const ModulePassFn = *const fn (gpa: Allocator, opts: *const Options, m: *ir.Module) Allocator.Error!void;

/// One pass: its name, the task that implements it, and its entry point.
pub const Pass = struct {
    name: []const u8,
    /// Owning task id in tasks.md.
    owner: []const u8,
    run: union(enum) {
        /// `null`: placeholder, a no-op until `owner` implements it.
        function: ?FunctionPassFn,
        /// `null`: placeholder, a no-op until `owner` implements it.
        module: ?ModulePassFn,
    },

    /// True if the pass is not implemented yet.
    pub fn isPlaceholder(p: Pass) bool {
        return switch (p.run) {
            inline else => |f| f == null,
        };
    }
};

/// Every pass a pipeline names. Owners replace `null` with their entry point.
pub const PassId = enum {
    ssa,
    constfold,
    dce,
    @"inline",
    sroa,
    gvn,
    sccp,
    loops,
    indvar,
    bce,
    licm,
    vectorize,
    unroll,
    inline_aggressive,
    lto,
    outline_cold,
    simd_enforce,
};

/// The pass registry, indexed by `PassId`.
pub const registry: std.enums.EnumArray(PassId, Pass) = .init(.{
    .ssa = fnPass("ssa", "T148", null),
    .constfold = fnPass("constfold", "T148", null),
    .dce = fnPass("dce", "T148", null),
    // Reads callee bodies, so it cannot run beside other function passes.
    .@"inline" = modPass("inline", "T149", null),
    .sroa = fnPass("sroa", "T150", null),
    .gvn = fnPass("gvn", "T151", null),
    .sccp = fnPass("sccp", "T152", null),
    .loops = fnPass("loops", "T153", null),
    .indvar = fnPass("indvar", "T153", null),
    .bce = fnPass("bce", "T154", null),
    .licm = fnPass("licm", "T153", null),
    .vectorize = fnPass("vectorize", "T155", null),
    .unroll = fnPass("unroll", "T153", null),
    .inline_aggressive = modPass("inline_aggressive", "T166", null),
    .lto = modPass("lto", "T166", null),
    .outline_cold = modPass("outline_cold", "T166", null),
    .simd_enforce = fnPass("simd_enforce", "T156", null),
});

fn fnPass(name: []const u8, owner: []const u8, run_fn: ?FunctionPassFn) Pass {
    return .{ .name = name, .owner = owner, .run = .{ .function = run_fn } };
}

fn modPass(name: []const u8, owner: []const u8, run_fn: ?ModulePassFn) Pass {
    return .{ .name = name, .owner = owner, .run = .{ .module = run_fn } };
}

/// The pass list of `level` (see the table in the file comment).
pub fn passIds(level: OptLevel) []const PassId {
    return level_lists.get(level);
}

const level_lists: std.enums.EnumArray(OptLevel, []const PassId) = blk: {
    const canon = [_]PassId{ .ssa, .constfold, .dce };
    const o1 = canon ++ [_]PassId{ .@"inline", .sroa, .gvn, .sccp };
    const o2_head = o1 ++ [_]PassId{ .loops, .indvar, .bce, .licm, .vectorize };
    const o2 = o2_head ++ [_]PassId{.unroll};
    const last = [_]PassId{.simd_enforce};
    break :blk .init(.{
        .O0 = &(canon ++ last),
        .O1 = &(o1 ++ last),
        .O2 = &(o2 ++ last),
        .O3 = &(o2 ++ [_]PassId{ .inline_aggressive, .lto } ++ last),
        .Oz = &(o2_head ++ [_]PassId{.outline_cold} ++ last),
    });
};

/// The passes of `level`, resolved through `registry`.
pub fn pipeline(level: OptLevel) []const Pass {
    return switch (level) {
        inline else => |l| comptime blk: {
            const ids = passIds(l);
            var out: [ids.len]Pass = undefined;
            for (ids, &out) |id, *p| p.* = registry.get(id);
            const final = out;
            break :blk &final;
        },
    };
}

/// Where the pipeline stopped on a verifier failure.
pub const Report = struct {
    /// Name of the pass after which verification failed, or "input" if the
    /// module was invalid before the first pass.
    pass: []const u8 = "",
    failure: verify.Failure = .{},
};

pub const Error = Allocator.Error || Io.Cancelable || error{Invalid};

/// Runs the pipeline of `opts.level` on `m`. See `run`.
pub fn runLevel(gpa: Allocator, io: Io, m: *ir.Module, opts: Options, report: *Report) Error!void {
    return run(gpa, io, m, pipeline(opts.level), opts, report);
}

/// Runs `passes` on `m` in order. Function passes run on every defined
/// function in parallel through `io`, so `gpa` and `m`'s allocator must be
/// thread-safe when `io` is concurrent. On `error.Invalid`, `report` names the
/// pass that broke the module and the violation.
pub fn run(gpa: Allocator, io: Io, m: *ir.Module, passes: []const Pass, opts: Options, report: *Report) Error!void {
    if (opts.verify) try check(gpa, m, "input", report);
    for (passes) |p| {
        switch (p.run) {
            .module => |f| try (f orelse continue)(gpa, &opts, m),
            .function => |f| try forEachFunction(gpa, io, m, f orelse continue, &opts),
        }
        if (opts.verify) try check(gpa, m, p.name, report);
    }
}

fn check(gpa: Allocator, m: *const ir.Module, pass: []const u8, report: *Report) Error!void {
    verify.verify(gpa, m, &report.failure) catch |e| {
        if (e == error.Invalid) report.pass = pass;
        return e;
    };
}

fn forEachFunction(gpa: Allocator, io: Io, m: *ir.Module, pass: FunctionPassFn, opts: *const Options) Error!void {
    const results = try gpa.alloc(Allocator.Error!void, m.functions.items.len);
    defer gpa.free(results);
    @memset(results, {});
    var group: Io.Group = .init;
    for (m.functions.items, results) |f, *r| {
        if (!f.isDeclaration()) group.async(io, runOne, .{ pass, gpa, opts, m, f, r });
    }
    try group.await(io);
    for (results) |r| try r;
}

fn runOne(pass: FunctionPassFn, gpa: Allocator, opts: *const Options, m: *const ir.Module, f: *ir.Function, result: *Allocator.Error!void) void {
    result.* = pass(gpa, opts, m, f);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const text = @import("../pir/text.zig");

const sample =
    \\global @g: i64 = 0 align 8
    \\
    \\fn @ext(%x: i32) -> i32
    \\
    \\fn @sum(%p: ptr noalias, %n: i64) -> i64 {
    \\^entry:
    \\  %z: i64 = const 0
    \\  br ^loop(%z, %z)
    \\^loop(%i: i64, %acc: i64):
    \\  %c: i1 = icmp slt %i, %n
    \\  cond_br %c, ^body, ^done
    \\^body:
    \\  bounds %i, %n
    \\  %q: ptr = gep %p, %i, 8
    \\  %v: i64 = load %q, align 8
    \\  %a: i64 = add.trap %acc, %v
    \\  %one: i64 = const 1
    \\  %i1: i64 = add nsw %i, %one
    \\  br ^loop(%i1, %a)
    \\^done:
    \\  ret %acc
    \\}
    \\
    \\fn @caller(%x: i32) -> i32 {
    \\^entry:
    \\  %r: i32 = call @ext(%x)
    \\  ret %r
    \\}
    \\
;

fn parseSample(src: []const u8) !ir.Module {
    var diag: text.Diag = .{};
    return text.parse(testing.allocator, src, &diag);
}

fn printed(m: *const ir.Module) ![]u8 {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try text.print(m, &out.writer);
    return out.toOwnedSlice();
}

test "every level's pipeline runs on hand-written P-IR" {
    var m = try parseSample(sample);
    defer m.deinit();
    const before = try printed(&m);
    defer testing.allocator.free(before);
    for (std.enums.values(OptLevel)) |level| {
        var report: Report = .{};
        try runLevel(testing.allocator, testing.io, &m, .{ .level = level, .verify = true }, &report);
    }
    // Every pass is still a placeholder, so the module is unchanged.
    const after = try printed(&m);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
}

fn has(level: OptLevel, id: PassId) bool {
    return std.mem.indexOfScalar(PassId, passIds(level), id) != null;
}

test "pipeline contents follow B.5.3 and §13.9" {
    try testing.expectEqual(OptLevel.O3, std.meta.stringToEnum(OptLevel, "O3").?);
    for (std.enums.values(OptLevel)) |level| {
        const ids = passIds(level);
        try testing.expectEqualSlices(PassId, &.{ .ssa, .constfold, .dce }, ids[0..3]);
        try testing.expectEqual(PassId.simd_enforce, ids[ids.len - 1]);
        try testing.expectEqual(ids.len, pipeline(level).len);
        for (ids, pipeline(level)) |id, p| try testing.expectEqualStrings(registry.get(id).name, p.name);
    }
    try testing.expect(!has(.O0, .@"inline") and has(.O1, .@"inline") and !has(.O1, .licm));
    try testing.expectEqualSlices(PassId, passIds(.O2)[0 .. passIds(.O2).len - 1], passIds(.O3)[0 .. passIds(.O2).len - 1]);
    try testing.expect(has(.O3, .unroll) and has(.O3, .lto) and !has(.O2, .inline_aggressive));
    try testing.expect(!has(.Oz, .unroll) and has(.Oz, .outline_cold) and has(.Oz, .vectorize));
}

test "registry: names match ids and placeholders name their owner" {
    for (std.enums.values(PassId)) |id| {
        const p = registry.get(id);
        try testing.expectEqualStrings(@tagName(id), p.name);
        try testing.expect(p.owner.len == 4 and p.owner[0] == 'T');
        _ = try std.fmt.parseInt(u16, p.owner[1..], 10);
        try testing.expect(p.isPlaceholder());
    }
    try testing.expect(registry.get(.@"inline").run == .module);
    try testing.expect(registry.get(.gvn).run == .function);
}

/// Test pass: prepends `const 7` to the entry block.
fn addConst(gpa: Allocator, opts: *const Options, m: *const ir.Module, f: *ir.Function) Allocator.Error!void {
    _ = .{ gpa, opts, m };
    const v = try f.newValue(.of(.i32), "");
    const entry = f.block(@fromBackingInt(0));
    try entry.insts.insert(f.arena, 0, .{ .op = .@"const", .results = try f.arena.dupe(ir.Value, &.{v}), .operands = try f.arena.dupe(ir.Operand, &.{.{ .int = 7 }}) });
}

fn countConsts(f: *const ir.Function) usize {
    var n: usize = 0;
    for (f.blocks.items[0].insts.items) |i| n += @intFromBool(i.op == .@"const");
    return n;
}

var consts_seen: usize = 0;

/// Test module pass: records how many consts `@caller` has when it runs.
fn observe(gpa: Allocator, opts: *const Options, m: *ir.Module) Allocator.Error!void {
    _ = .{ gpa, opts };
    consts_seen = countConsts(m.findFunction("caller").?);
}

test "function passes run on every defined function, in pass order" {
    var m = try parseSample(sample);
    defer m.deinit();
    const passes = [_]Pass{
        fnPass("add1", "T146", addConst),
        modPass("observe", "T146", observe),
        registry.get(.gvn),
        fnPass("add2", "T146", addConst),
    };
    var report: Report = .{};
    consts_seen = 0;
    try run(testing.allocator, testing.io, &m, &passes, .{ .level = .O1, .verify = true }, &report);
    try testing.expectEqual(1, consts_seen);
    try testing.expectEqual(2, countConsts(m.findFunction("caller").?));
    try testing.expectEqual(3, countConsts(m.findFunction("sum").?));
    try testing.expect(m.findFunction("ext").?.isDeclaration());
}

/// Test pass: drops the terminator of `@caller`'s entry block.
fn dropTerminator(gpa: Allocator, opts: *const Options, m: *const ir.Module, f: *ir.Function) Allocator.Error!void {
    _ = .{ gpa, opts, m };
    if (std.mem.eql(u8, f.name, "caller")) _ = f.blocks.items[0].insts.pop();
}

var ran_after_break = false;

fn markRan(gpa: Allocator, opts: *const Options, m: *ir.Module) Allocator.Error!void {
    _ = .{ gpa, opts, m };
    ran_after_break = true;
}

test "the verifier runs between passes and names the breaking pass" {
    var m = try parseSample(sample);
    defer m.deinit();
    const passes = [_]Pass{
        fnPass("add", "T146", addConst),
        fnPass("breaker", "T146", dropTerminator),
        modPass("mark", "T146", markRan),
    };
    var report: Report = .{};
    ran_after_break = false;
    try testing.expectError(error.Invalid, run(testing.allocator, testing.io, &m, &passes, .{ .level = .O2, .verify = true }, &report));
    try testing.expectEqualStrings("breaker", report.pass);
    try testing.expectEqualStrings("caller", report.failure.func);
    try testing.expectEqual(verify.Kind.bad_terminator, report.failure.kind);
    try testing.expect(!ran_after_break);
}

test "an invalid input module is reported before any pass runs" {
    var m = try parseSample(sample);
    defer m.deinit();
    _ = m.findFunction("caller").?.blocks.items[0].insts.pop();
    const passes = [_]Pass{modPass("mark", "T146", markRan)};
    var report: Report = .{};
    ran_after_break = false;
    try testing.expectError(error.Invalid, run(testing.allocator, testing.io, &m, &passes, .{ .level = .O0, .verify = true }, &report));
    try testing.expectEqualStrings("input", report.pass);
    try testing.expect(!ran_after_break);
}
