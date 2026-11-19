//! Unsafe code (§12.1, §12.2, §8.6): the lexical `unsafe` context and the
//! operations that need it.
//!
//! - `block` checks `unsafe { ... }`: its body is checked with
//!   `Checker.in_unsafe` set. The body of an `@unsafe` function is not an
//!   unsafe context by itself (§12.1).
//! - `require` is the one gate of every unsafe operation: E1202 outside
//!   `unsafe`, E0805 in comptime code (`Checker.in_comptime`), which cannot
//!   use `unsafe` at all (§8.6).
//! - Raw-pointer operations (§12.2): `deref` (`*p`), `addrOf` (`&x`) and
//!   `pointee` (`*p` as a place, for `mutability.operand`).
//!   Integer-to-pointer `as` casts gate in `check_expr.cast`, pointer
//!   builtins in `builtins.zig`, pointer indexing in T051's `p[i]`.
//! - `callee` gates calls of `extern` and `@unsafe` functions.

const std = @import("std");
const Ast = @import("../ast/Ast.zig");
const Types = @import("types.zig");
const items_mod = @import("items.zig");
const emit_tir = @import("emit_tir.zig");
const check_expr = @import("check_expr.zig");
const check_stmt = @import("check_stmt.zig");
const tir = @import("../tir/tir.zig");

const Node = Ast.Node;
const TypeId = Types.TypeId;
const Checker = emit_tir.Checker;
const Typed = emit_tir.Typed;
const Error = emit_tir.Error;

/// `unsafe { ... }` (§6.11, §12.1). E0805 in comptime code (§8.6).
pub fn block(c: *Checker, n: Node.Index, expected: TypeId) Error!Typed {
    if (c.in_comptime) try c.report(n, .E0805, "`unsafe` cannot be used in comptime code", .{});
    // An empty scope at the block's entry marks it for the interpreter,
    // which forbids running it (§8.6, `comptime/limits.zig`).
    const node = c.b.node;
    c.b.node = n;
    const mark = try c.emit(.void, .{ .scope_begin = .{} });
    _ = try c.emit(.void, .{ .scope_end = .{ .scope = mark } });
    c.b.node = node;
    const saved = c.in_unsafe;
    c.in_unsafe = true;
    defer c.in_unsafe = saved;
    return check_stmt.block(c, c.ast.data(n).unsafe_block.body, expected);
}

/// Whether unsafe operation `what` at `n` is allowed here; reports E1202
/// outside `unsafe` and E0805 in comptime code otherwise. Inside an
/// `unsafe` block already rejected at comptime nothing more is reported.
pub fn require(c: *Checker, n: Node.Index, what: []const u8) Error!bool {
    if (c.in_unsafe) return !c.in_comptime;
    if (c.in_comptime) {
        try c.report(n, .E0805, "{s} cannot be used in comptime code", .{what});
    } else try c.reportAt(c.ast.mainToken(n), .E1202, &.{"wrap the operation in `unsafe { ... }` and document why it is sound"}, "{s} is only allowed inside `unsafe`", .{what});
    return false;
}

/// Gates the call at `at` of function `sig`, declared in `ast`, which is
/// `extern` if `is_extern` (§12.1, §12.6).
pub fn callee(c: *Checker, at: Node.Index, ast: *const Ast, sig: items_mod.Fn, is_extern: bool) Error!void {
    if (is_extern) {
        _ = try require(c, at, try std.fmt.allocPrint(c.arena, "calling `extern` function `{s}`", .{sig.name}));
    } else if (items_mod.hasAttr(ast, sig.attrs, .unsafe)) {
        _ = try require(c, at, try std.fmt.allocPrint(c.arena, "calling `@unsafe` function `{s}`", .{sig.name}));
    }
}

/// `*p` as a value (§12.2): loads the pointee.
pub fn deref(c: *Checker, n: Node.Index, _: TypeId) Error!Typed {
    const p = try pointee(c, n) orelse return .err;
    return .{ .ty = p.ty, .ref = try c.emit(p.ty, .{ .load = .{ .place = p.ref } }) };
}

/// A place, its type, and whether it may be written.
pub const Addressed = struct { ref: tir.Ref, ty: TypeId, mutable: bool };

/// The place `*p` names at `n` (§12.2), writable through `*T` only, or
/// null after a diagnostic. Writes are checked by `mutability.require`.
pub fn pointee(c: *Checker, n: Node.Index) Error!?Addressed {
    const ok = try require(c, n, "dereferencing a raw pointer");
    const v = try check_expr.check(c, c.ast.data(n).prefix.operand, .none);
    if (v.ty == .err or v.ty == .noreturn) {
        c.failed = true; // reported with the operand, or dead code
        return null;
    }
    const ptr = switch (c.types.get(v.ty)) {
        .ptr => |x| x,
        else => {
            try c.report(n, .E0310, "cannot dereference a value of type `{s}`: it is not a raw pointer", .{try c.tyName(v.ty)});
            return null;
        },
    };
    if (!ok) return null;
    return .{ .ref = try c.emit(ptr.elem, .{ .deref = .{ .ptr = v.ref } }), .ty = ptr.elem, .mutable = !ptr.is_const };
}

/// `&x` (§12.2): `*T` for a mutable place `x: T`, else `*const T`.
pub fn addrOf(c: *Checker, n: Node.Index, _: TypeId) Error!Typed {
    const ok = try require(c, n, "taking the address of a place");
    const p = try placeOf(c, c.ast.data(n).prefix.operand) orelse {
        c.failed = true;
        return .err;
    };
    if (!ok) return .err;
    const ty = try c.types.intern(.{ .ptr = .{ .elem = p.ty, .is_const = !p.mutable } });
    return .{ .ty = ty, .ref = try c.emit(ty, .{ .addr_of = .{ .place = p.ref } }) };
}

/// The place `n` names and whether it is mutable, or null after a diagnostic.
fn placeOf(c: *Checker, n: Node.Index) Error!?Addressed {
    const ast = c.ast;
    const local: tir.Local = switch (ast.kind(n)) {
        .paren => return placeOf(c, ast.data(n).paren.inner),
        .prefix => return if (ast.tokens.items(.kind)[ast.mainToken(n)] == .star) pointee(c, n) else notPlace(c, n),
        .self_value => c.self_local.unwrap() orelse return null, // E0205 (parser)
        .field_access, .index => {
            _ = c.unsupported(n, "the address of fields and elements (T050, T051)");
            return null;
        },
        .ident => blk: {
            const e = c.items.names.get(c.m, n) orelse {
                _ = try check_expr.check(c, n, .none); // reports the unknown name
                return null;
            };
            switch (e.res) {
                .local => |l| switch (ast.kind(l)) {
                    .pat_bind, .pat_bind_mut, .param => break :blk c.locals.get(l) orelse {
                        _ = c.unsupported(n, "bindings of this kind (T052)");
                        return null;
                    },
                    else => return notPlace(c, n),
                },
                .global => return notPlace(c, n),
            }
        },
        else => return notPlace(c, n),
    };
    const info = c.b.locals.get(local.int());
    return .{
        .ref = try c.emit(info.ty, .{ .local = .{ .local = local } }),
        .ty = info.ty,
        .mutable = switch (info.kind) {
            .let_mut, .param_mut, .temp => true,
            .let, .param, .param_move => false,
        },
    };
}

fn notPlace(c: *Checker, n: Node.Index) Error!?Addressed {
    try c.report(n, null, "cannot take the address of this expression: it is not a place", .{});
    return null;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const Fixture = emit_tir.Fixture;

test "unsafe operations inside `unsafe` (§12.1, §12.2)" {
    var f: Fixture = undefined;
    try f.init(
        \\extern "C" { fn abs(x: i32) -> i32; }
        \\/// Reads `*p`. `p` must point to a live `u32`.
        \\@unsafe
        \\fn read(p: *const u32) -> u32 { unsafe { *p } }
        \\fn addr_of(x: u32) -> *const u32 { unsafe { &x } }
        \\fn addr_of_mut() -> *u32 { let mut m: u32 = 1; unsafe { &m } }
        \\fn from_int(addr: usize) -> *u32 { unsafe { addr as *u32 } }
        \\fn writes(q: *u32) { unsafe { *q = 2; *q += 1; bump(mut *q); } }
        \\fn compare(p: *const u32, q: *u32, r: *u32) -> bool { (p as usize) == @int_from_ptr(q) && q < r }
        \\fn extern_call() -> u32 { let a = unsafe { abs(-3) } as u32; a }
        \\fn bit_cast() -> bool { unsafe { @bit_cast(bool, 1u8) } }
        \\fn reads(p: *const u32, r: *u32, a: u32) -> u32 { a + unsafe { *p + read(p) + *r } }
        \\fn bump(mut v: u32) { v += 1; }
        \\fn arith(p: *u32) -> *u32 { unsafe { @ptr_add(p, 1) } }
        \\fn null_ptr() -> *u8 { unsafe { @ptr_from_int(u8, 0) } }
        \\fn vol(p: *u32) -> u32 { unsafe { @volatile_write(p, 1); @volatile_read(p) } }
    );
    defer f.deinit();
    try f.expectDiags(&.{});
    for ([_][]const u8{ "read", "addr_of", "addr_of_mut", "from_int", "writes", "compare", "extern_call", "bit_cast", "reads", "arith", "null_ptr", "vol" }) |name| {
        _ = try f.func(name);
    }
}

test "unsafe operations outside `unsafe` are E1202 (§12.1)" {
    var f: Fixture = undefined;
    try f.init(
        \\extern "C" { fn abs(x: i32) -> i32; }
        \\@unsafe
        \\fn read(p: *const u32) -> u32 { *p }
        \\fn outside(x: u32, addr: usize, q: *u32) -> i32 {
        \\    let p = &x;
        \\    let r = addr as *u32;
        \\    *q = 1;
        \\    let b = read(p);
        \\    let flag = @bit_cast(bool, 1u8);
        \\    let s = @ptr_add(q, 1);
        \\    let t = @ptr_from_int(u8, 0);
        \\    @volatile_write(q, 1);
        \\    let v = @volatile_read(q);
        \\    abs(-3)
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{
        .{ .E1202, "*" },              .{ .E1202, "&" },             .{ .E1202, "as" },
        .{ .E1202, "*" },              .{ .E1202, "read" },          .{ .E1202, "@bit_cast" },
        .{ .E1202, "@ptr_add" },       .{ .E1202, "@ptr_from_int" }, .{ .E1202, "@volatile_write" },
        .{ .E1202, "@volatile_read" }, .{ .E1202, "abs" },
    });
}

test "raw pointer errors: `*const T` writes, non-pointers, non-places" {
    var f: Fixture = undefined;
    try f.init(
        \\fn bad(p: *const u32, x: u32) {
        \\    unsafe { *p = 1; }
        \\    let y = unsafe { *x };
        \\    let z = unsafe { &5 };
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{ .{ .E0337, "*" }, .{ .E0310, "*" }, .{ null, "5" } });
}

test "assignment through a non-`*` prefix is E0207, not a name lookup" {
    var f: Fixture = undefined;
    try f.init("fn a() { let mut y = 1; -y = 2; }");
    defer f.deinit();
    try f.expectDiags(&.{.{ .E0207, "-" }});
}

test "comptime code cannot use `unsafe` (E0805, §8.6)" {
    var f: Fixture = undefined;
    try f.init(
        \\extern "C" { fn abs(x: i32) -> i32; }
        \\fn f() -> i32 { abs(2) + unsafe { abs(1) } }
    );
    defer f.deinit();
    // Re-check `f`'s body as comptime code, as T060 does for comptime contexts.
    const sig = (try f.items.info(.{ .module = 0, .item = 1 })).@"fn";
    const arena = f.bodies.arena.allocator();
    var c: Checker = .{
        .bodies = &f.bodies,
        .items = &f.items,
        .types = f.items.types,
        .sink = f.items.sink,
        .arena = arena,
        .m = 0,
        .ast = f.items.im.graph.modules[0].ast,
        .self_ty = .none,
        .sig = sig,
        .b = .init(arena, sig.ret),
        .in_comptime = true,
    };
    c.setBlock(try c.addBlock());
    _ = try check_stmt.block(&c, c.ast.data(sig.node).fn_decl.body.?, sig.ret);
    // The runtime check of `f` reported `abs(2)` outside `unsafe` first.
    try f.expectDiags(&.{ .{ .E0805, "abs" }, .{ .E1202, "abs" }, .{ .E0805, "unsafe" } });
}
