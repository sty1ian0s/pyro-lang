//! Test-only fixtures shared by the diagnostic renderers' tests: the A.2
//! example source and diagnostic.

const std = @import("std");
const diag = @import("diag.zig");

/// Test fixture: the A.2 example source; lines 3-5 are the ones A.2 shows.
pub const source =
    \\fn frame(arena: mut Arena) {
    \\    // scratch space for one frame
    \\    let tmp = arena.alloc_slice(u32, 64);
    \\    arena.reset();
    \\    tmp[0] = 1;
    \\}
    \\
;

/// Test fixture: the A.2 example diagnostic over `source`, which must be
/// the first file of the source map (`FileId` 0).
pub const example: diag.Diagnostic = blk: {
    @setEvalBranchQuota(10_000);
    const at = struct {
        fn at(needle: []const u8, skip: usize, len: usize) diag.Span {
            const start = std.mem.indexOf(u8, source, needle).? + skip;
            return .{ .file = @fromBackingInt(0), .start = start, .end = start + len };
        }
    }.at;
    break :blk .{
        .code = .E0332,
        .severity = .@"error",
        .message = "`arena` is changed while a slice from it is still in use",
        .spans = &.{
            .{ .span = at("arena.reset", 0, 13), .label = "`arena` is reset here", .primary = true },
            .{ .span = at("let tmp", 10, 5), .label = "`tmp` points into `arena` here" },
            .{ .span = at("tmp[0]", 0, 3), .label = "...but `tmp` is still used here" },
        },
        .help = &.{"finish using `tmp` before calling `reset`, or move `arena.reset()` into a `defer`"},
        .fixes = &.{.{ .span = at("arena.reset", 0, 13), .replacement = "defer arena.reset()" }},
    };
};
