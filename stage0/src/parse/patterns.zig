//! Pattern grammar (§3.7). Balanced-skip stub from T019; T021 replaces it.

const Parser = @import("Parser.zig");
const Node = @import("../ast/Ast.zig").Node;

/// Parses a `pattern`. Stub: skips to a token that can follow a pattern
/// outside brackets and returns a placeholder.
pub fn parsePattern(p: *Parser) Parser.Error!Node.Index {
    const at = p.tok_i;
    if (!p.skipBalanced(&.{ .comma, .semicolon, .eq, .colon, .fat_arrow, .kw_in, .kw_if }, false))
        return p.failExpected("a pattern");
    return p.stub(at);
}
