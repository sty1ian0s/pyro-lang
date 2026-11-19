//! Expression grammar (§3.8, §3.9). Balanced-skip stub from T019; T023
//! replaces it with the Pratt parser.

const Parser = @import("Parser.zig");
const Node = @import("../ast/Ast.zig").Node;

/// Parses an `expr`. Stub: skips to a `,` `;` or `=>` outside brackets and
/// returns a placeholder.
pub fn parseExpr(p: *Parser) Parser.Error!Node.Index {
    const at = p.tok_i;
    if (!p.skipBalanced(&.{ .comma, .semicolon, .fat_arrow }, false)) return p.failExpected("an expression");
    return p.stub(at);
}
