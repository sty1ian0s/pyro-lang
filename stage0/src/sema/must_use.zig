//! The `Result` must-use rule (§9.1.1): an expression statement whose type
//! is `Result<T, E>` is an error (E0603). `?`, `match`, `if let` and the
//! discard `_ = e;` (§6.11.1) consume the value; discarding an `Option` or
//! any other value is allowed.

const std = @import("std");
const Ast = @import("../ast/Ast.zig");
const Types = @import("types.zig");
const emit_tir = @import("emit_tir.zig");
const check_stmt = @import("check_stmt.zig");

const Checker = emit_tir.Checker;
const Error = emit_tir.Error;

/// Reports E0603 if expression statement `s` has type `ty` and `ty` is a
/// `Result`. Called by the statement checker after typing `s`.
pub fn check(c: *Checker, s: Ast.Node.Index, ty: Types.TypeId) Error!void {
    if (!isResult(c.types, ty)) return;
    try c.reportAt(check_stmt.firstToken(c.ast, s), .E0603, &.{"handle it with `?`, `match` or `if let`, or discard it with `_ = expr;`"}, "unused value of type `{s}`", .{try c.tyName(ty)});
}

/// Whether `ty` is an instance of the prelude `Result` (§9.1).
pub fn isResult(types: *Types, ty: Types.TypeId) bool {
    return switch (types.get(ty)) {
        .nominal => |n| n.lang == .result,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Tests

const Fixture = emit_tir.Fixture;

test "E0603: a Result expression statement; `_ = r` and other values are fine" {
    var f: Fixture = undefined;
    try f.init(
        \\pub enum IoError { closed }
        \\fn send(b: u8) -> Result<u8, IoError> { .ok(b) }
        \\fn find(b: u8) -> Option<u8> { .some(b) }
        \\fn add(a: u32, b: u32) -> u32 { a + b }
        \\fn run(open: bool) {
        \\    send(1);
        \\    if open { send(2); }
        \\    _ = send(3);
        \\    find(4);
        \\    add(1, 2);
        \\}
    );
    defer f.deinit();
    try f.expectDiags(&.{ .{ .E0603, "send" }, .{ .E0603, "send" } });
}
