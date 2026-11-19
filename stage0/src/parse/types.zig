//! Type grammar (§3.6). Balanced-skip stub from T019; T021 replaces it.

const Parser = @import("Parser.zig");
const Node = @import("../ast/Ast.zig").Node;

/// Parses a `type`. Stub: skips to a `,` `;` `=` or `{` outside brackets and
/// generic arguments (splitting `>>` when closing them) and returns a
/// placeholder.
pub fn parseType(p: *Parser) Parser.Error!Node.Index {
    const at = p.tok_i;
    if (!p.skipBalanced(&.{ .comma, .semicolon, .eq, .l_brace }, true)) return p.failExpected("a type");
    return p.stub(at);
}
