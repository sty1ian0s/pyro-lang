//! Pattern grammar (§3.7): every `pattern_single` form and `|` alternatives.
//! That alternatives appear only in `match` arms and bind the same names
//! (E0211), and that struct patterns name every field (E0212), are checked
//! after parsing.

const std = @import("std");
const Parser = @import("Parser.zig");
const Node = @import("../ast/Ast.zig").Node;
const types = @import("types.zig");

/// Parses a `pattern`: `pattern_single ( "|" pattern_single )*`.
pub fn parsePattern(p: *Parser) Parser.Error!Node.Index {
    const first = try parseSingle(p);
    if (p.peek(0) != .pipe) return first;
    const bar = p.tok_i;
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    try p.scratch.append(p.gpa, first);
    while (p.eat(.pipe) != null) try p.scratch.append(p.gpa, try parseSingle(p));
    return p.addNode(bar, .{ .pat_alt = .{ .alts = p.scratch.items[top..] } });
}

fn parseSingle(p: *Parser) Parser.Error!Node.Index {
    const t = p.tok_i;
    switch (p.peek(0)) {
        .ident => {
            if (std.mem.eql(u8, p.ast.tokenSlice(t), "_")) return p.addNode(p.next(), .{ .pat_wildcard = .{} });
            // Two tokens decide: `IDENT .` or `IDENT {` starts a struct pattern's path.
            if (p.peek(1) != .dot and p.peek(1) != .l_brace) return p.addNode(p.next(), .{ .pat_bind = .{} });
            const path = try types.parsePath(p);
            const lb = try p.expect(.l_brace);
            const top = p.scratch.items.len;
            defer p.scratch.shrinkRetainingCapacity(top);
            try parseFieldPatterns(p);
            return p.addNode(lb, .{ .pat_struct = .{ .ty = path, .fields = p.scratch.items[top..] } });
        },
        .kw_mut => {
            _ = p.next();
            return p.addNode(try p.expect(.ident), .{ .pat_bind_mut = .{} });
        },
        .dot => {
            _ = p.next();
            const name = try p.expect(.ident);
            if (p.eat(.l_paren) == null) return p.addNode(name, .{ .pat_variant = .{ .elems = null } });
            const top = p.scratch.items.len;
            defer p.scratch.shrinkRetainingCapacity(top);
            try p.scratch.append(p.gpa, try parsePattern(p));
            if (p.eat(.comma) != null) try types.parseList(p, parsePattern, .r_paren) else _ = try p.expect(.r_paren);
            return p.addNode(name, .{ .pat_variant = .{ .elems = p.scratch.items[top..] } });
        },
        .l_paren => {
            _ = p.next();
            const top = p.scratch.items.len;
            defer p.scratch.shrinkRetainingCapacity(top);
            try p.scratch.append(p.gpa, try parsePattern(p));
            _ = try p.expect(.comma);
            try types.parseList(p, parsePattern, .r_paren);
            return p.addNode(t, .{ .pat_tuple = .{ .elems = p.scratch.items[top..] } });
        },
        .dot_l_brace => {
            _ = p.next();
            const top = p.scratch.items.len;
            defer p.scratch.shrinkRetainingCapacity(top);
            try parseFieldPatterns(p);
            return p.addNode(t, .{ .pat_anon_struct = .{ .fields = p.scratch.items[top..] } });
        },
        else => {
            const lo = try types.parseLiteral(p) orelse return p.failExpected("a pattern");
            const k = p.peek(0);
            if (k != .dot_dot and k != .dot_dot_eq) return lo;
            const op = p.next();
            const hi = try types.parseLiteral(p) orelse return p.failExpected("a literal pattern");
            return p.addNode(op, .{ .pat_range = .{ .lo = lo, .hi = hi } });
        },
    }
}

/// `field_pattern_list "}"` after the opening `{` or `.{`: pushes the field
/// patterns onto `p.scratch`, then a `rest` node for a trailing `..`.
fn parseFieldPatterns(p: *Parser) Parser.Error!void {
    while (true) switch (p.peek(0)) {
        .r_brace => break,
        .dot_dot => {
            try p.scratch.append(p.gpa, try p.addNode(p.next(), .{ .rest = .{} }));
            break;
        },
        else => {
            try p.scratch.append(p.gpa, try parseFieldPattern(p));
            if (p.eat(.comma) == null and p.peek(0) != .dot_dot) break;
        },
    };
    _ = try p.expect(.r_brace);
}

/// `field_pattern`: `IDENT ( ":" pattern )? | "mut" IDENT`.
fn parseFieldPattern(p: *Parser) Parser.Error!Node.Index {
    if (p.eat(.kw_mut) != null) return p.addNode(try p.expect(.ident), .{ .field_pat_mut = .{} });
    const name = try p.expect(.ident);
    const pattern = if (p.eat(.colon) != null) try parsePattern(p) else null;
    return p.addNode(name, .{ .field_pat = .{ .pattern = pattern } });
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn expectPattern(src: []const u8, want: []const u8) !void {
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings(want, try types.testTree(&buf, parsePattern, src, .eof));
}

test "every pattern form" {
    try expectPattern("_", "pat_wildcard:_");
    try expectPattern("x", "pat_bind:x");
    try expectPattern("mut x", "pat_bind_mut:x");
    try expectPattern("42", "int_lit:42");
    try expectPattern("-1", "prefix(int_lit:1)");
    try expectPattern("'a'", "char_lit:'a'");
    try expectPattern("true", "bool_lit:true");
    try expectPattern("-128..=-1", "pat_range(prefix(int_lit:128) prefix(int_lit:1))");
    try expectPattern("'a'..'z'", "pat_range(char_lit:'a' char_lit:'z')");
    try expectPattern(".None", "pat_variant(_)");
    try expectPattern(".Some(x)", "pat_variant(pat_bind:x)");
    try expectPattern(".Pair(_, mut b,)", "pat_variant(pat_wildcard:_ pat_bind_mut:b)");
    try expectPattern("(a,)", "pat_tuple(pat_bind:a)");
    try expectPattern("(a, (b, _), .C)", "pat_tuple(pat_bind:a pat_tuple(pat_bind:b pat_wildcard:_) pat_variant(_))");
    try expectPattern("Point { x, y: 0 }", "pat_struct(path:Point field_pat(_) field_pat(int_lit:0))");
    try expectPattern("geo.Point { mut x, .. }", "pat_struct(path:geo field_pat_mut:x rest:..)");
    try expectPattern("P { .. }", "pat_struct(path:P rest:..)");
    try expectPattern("P {}", "pat_struct(path:P)");
    try expectPattern(".{ a: .{ b }, }", "pat_anon_struct(field_pat(pat_anon_struct(field_pat(_))))");
}

test "`|` alternatives" {
    try expectPattern("1 | 2 | 3..5", "pat_alt(int_lit:1 int_lit:2 pat_range(int_lit:3 int_lit:5))");
    try expectPattern(".A(x) | .B(x)", "pat_alt(pat_variant(pat_bind:x) pat_variant(pat_bind:x))");
    // Nested inside a variant payload.
    try expectPattern(".Some(1 | 2)", "pat_variant(pat_alt(int_lit:1 int_lit:2))");
}

test "pattern stops before what follows it" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("pat_bind:x", try types.testTree(&buf, parsePattern, "x if x > 0 =>", .kw_if));
    try testing.expectEqualStrings("pat_bind:x", try types.testTree(&buf, parsePattern, "x in xs", .kw_in));
    try testing.expectEqualStrings("pat_tuple(pat_bind:a pat_bind:b)", try types.testTree(&buf, parsePattern, "(a, b) = t", .eq));
}

test "malformed patterns report one error" {
    try types.testFail(parsePattern, "1.5", "expected a pattern, found `1.5`");
    try types.testFail(parsePattern, "\"s\"", "expected a pattern, found `\"s\"`");
    try types.testFail(parsePattern, "(a)", "expected `,`, found `)`");
    try types.testFail(parsePattern, ".A()", "expected a pattern, found `)`");
    try types.testFail(parsePattern, "1..", "expected a literal pattern, found end of file");
    try types.testFail(parsePattern, "a.b", "expected `{`, found end of file");
    try types.testFail(parsePattern, "P { x y }", "expected `}`, found `y`");
    try types.testFail(parsePattern, "P { .., x }", "expected `}`, found `,`");
    try types.testFail(parsePattern, "1 |", "expected a pattern, found end of file");
}
