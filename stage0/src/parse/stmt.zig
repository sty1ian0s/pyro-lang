//! Statements and blocks (§3.5). Balanced-skip stub from T019; T025
//! replaces it.

const Parser = @import("Parser.zig");
const Node = @import("../ast/Ast.zig").Node;

/// Parses a `block`. Stub: skips the braces and returns an empty block.
pub fn parseBlock(p: *Parser) Parser.Error!Node.Index {
    const lb = p.tok_i;
    try p.skipGroup(.l_brace, .r_brace);
    return p.addNode(lb, .{ .block = .{ .stmts = &.{}, .tail = null } });
}
