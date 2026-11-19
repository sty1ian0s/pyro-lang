//! Test helpers shared by the resolver's tests.

const std = @import("std");
const testing = std.testing;
const diag = @import("../diag/diag.zig");
const Ast = @import("../ast/Ast.zig");
const lexer = @import("../lex/lexer.zig");
const Parser = @import("../parse/Parser.zig");

/// Lexes and parses `src` as file 0; the test fails on any diagnostic.
pub fn parseForTest(src: []const u8) !Ast {
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    const file: diag.FileId = @fromBackingInt(@intCast(0));
    const tokens = try lexer.tokenize(testing.allocator, src, file, &sink, .{});
    var ast = try Parser.parse(testing.allocator, src, tokens, file, &sink);
    errdefer ast.deinit(testing.allocator);
    try testing.expectEqual(0, sink.finish().len);
    return ast;
}
