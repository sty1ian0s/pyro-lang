//! Item grammar (§3.2-§3.4). Skeleton stub from T019; T020 replaces it.
//!
//! The stub reads what makes an item recognizable (doc comments, attributes,
//! `pub`, keyword, name) and skips the rest with balanced skips, so a file
//! parses into one skeleton node per item: lists are empty and skipped parts
//! are placeholder nodes.

const Parser = @import("Parser.zig");
const Node = @import("../ast/Ast.zig").Node;
const types = @import("types.zig");
const expr = @import("expr.zig");
const stmt = @import("stmt.zig");

/// Parses one `item` (§3.2), wrapped in `attributed` if it has attributes.
pub fn parseItem(p: *Parser) Parser.Error!Node.Index {
    while (p.eat(.doc_comment)) |_| {}
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    while (p.peek(0) == .builtin) {
        const t = p.next();
        const args: ?[]const Node.Index = if (p.peek(0) == .l_paren) &.{} else null;
        if (args != null) try p.skipGroup(.l_paren, .r_paren);
        try p.scratch.append(p.gpa, try p.addNode(t, .{ .attribute = .{ .args = args } }));
    }
    _ = p.eat(.kw_pub);
    const item = try parseItemKind(p);
    const attrs = p.scratch.items[top..];
    if (attrs.len == 0) return item;
    return p.addNode(p.ast.mainToken(attrs[0]), .{ .attributed = .{ .attrs = attrs, .inner = item } });
}

fn parseItemKind(p: *Parser) Parser.Error!Node.Index {
    const kw = p.tok_i;
    switch (p.peek(0)) {
        .kw_use => {
            _ = p.next();
            const path = try p.stub(p.tok_i);
            _ = p.skipBalanced(&.{.semicolon}, false);
            _ = try p.expect(.semicolon);
            return p.addNode(kw, .{ .use = .{ .path = path, .alias = null } });
        },
        .kw_const => {
            _ = p.next();
            _ = try p.expect(.ident);
            const ty = if (p.eat(.colon) != null) try types.parseType(p) else null;
            _ = try p.expect(.eq);
            const value = try expr.parseExpr(p);
            _ = try p.expect(.semicolon);
            return p.addNode(kw, .{ .const_decl = .{ .ty = ty, .value = value } });
        },
        .kw_type => {
            _ = p.next();
            _ = try p.expect(.ident);
            try skipGenerics(p);
            _ = try p.expect(.eq);
            const distinct = p.eat(.kw_distinct) != null;
            const ty = try types.parseType(p);
            _ = try p.expect(.semicolon);
            return if (distinct)
                p.addNode(kw, .{ .type_distinct = .{ .generics = null, .ty = ty } })
            else
                p.addNode(kw, .{ .type_alias = .{ .generics = null, .ty = ty } });
        },
        .kw_fn => {
            _ = p.next();
            _ = try p.expect(.ident);
            try skipGenerics(p);
            try p.skipGroup(.l_paren, .r_paren);
            const ret = if (p.eat(.arrow) != null) try types.parseType(p) else null;
            const body = switch (p.peek(0)) {
                .l_brace => try stmt.parseBlock(p),
                .semicolon => blk: {
                    _ = p.next();
                    break :blk null;
                },
                else => return p.failExpected("`{` or `;`"),
            };
            return p.addNode(kw, .{ .fn_decl = .{ .generics = null, .params = &.{}, .ret = ret, .body = body } });
        },
        .kw_struct, .kw_enum, .kw_protocol, .kw_impl, .kw_extern => |k| {
            _ = p.next();
            switch (k) {
                .kw_impl => {},
                .kw_extern => _ = try p.expect(.string_lit),
                else => _ = try p.expect(.ident),
            }
            _ = p.skipBalanced(&.{.l_brace}, true); // generics, backing type, impl header
            try p.skipGroup(.l_brace, .r_brace);
            return switch (k) {
                .kw_struct => p.addNode(kw, .{ .struct_decl = .{ .generics = null, .fields = &.{}, .members = &.{} } }),
                .kw_enum => p.addNode(kw, .{ .enum_decl = .{ .generics = null, .backing = null, .variants = &.{}, .members = &.{} } }),
                .kw_protocol => p.addNode(kw, .{ .protocol_decl = .{ .generics = null, .members = &.{} } }),
                .kw_impl => p.addNode(kw, .{ .impl_decl = .{ .generics = null, .protocol = try p.stub(kw), .target = try p.stub(kw), .members = &.{} } }),
                else => p.addNode(kw, .{ .extern_block = .{ .fns = &.{} } }),
            };
        },
        .kw_comptime => {
            _ = p.next();
            return p.addNode(kw, .{ .comptime_block = .{ .body = try stmt.parseBlock(p) } });
        },
        else => return p.failExpected("an item"),
    }
}

/// Skips `generic_params` if present.
fn skipGenerics(p: *Parser) Parser.Error!void {
    if (p.eat(.lt) == null) return;
    _ = p.skipBalanced(&.{}, true);
    _ = try p.expectGenericClose();
}
