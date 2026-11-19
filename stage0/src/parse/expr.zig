//! Expression grammar (§3.8, §3.9): a table-driven Pratt parser with the
//! binding powers of §3.9.1, every primary form, postfix operators and the
//! `expr_ns` mode (§3.8.1).
//!
//! Checks that need only the shape of the tree are made here, report, and
//! let parsing continue:
//!
//! - E0214: a second operator of a non-associative level (comparisons,
//!   ranges) after the first, as in `a < b < c` (§3.9.1);
//! - W0201: `<<`/`>>` with a `+`/`-` operand that is not parenthesized;
//! - E0215: a `.{…}` literal with both named and positional elements;
//! - E0108: a signed literal that fits only when negated (`128i8`); a prefix
//!   `-` directly on an integer literal is folded into it, so `-128i8` fits
//!   (§2.6.1, §3.9);
//! - E0213: `mut` anywhere in an expression (it is only a call-argument mode)
//!   and `move` anywhere but at the top of an expression parsed with
//!   `parseExprMove` (§3.8.2). Call arguments, struct-literal field values and
//!   `match`/`if let` scrutinees are parsed that way here; the statement
//!   grammar uses it for `let`, assignments, `return` and `spawn`.

const std = @import("std");
const Parser = @import("Parser.zig");
const Ast = @import("../ast/Ast.zig");
const diag = @import("../diag/diag.zig");
const literals = @import("../lex/literals.zig");
const types = @import("types.zig");
const patterns = @import("patterns.zig");
const items = @import("items.zig");
const stmt = @import("stmt.zig");

const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;
const TokenKind = @import("../lex/token.zig").TokenKind;
const Error = Parser.Error;

/// Parses an `expr`.
pub fn parseExpr(p: *Parser) Error!Node.Index {
    return parseBp(p, 0, .{});
}

/// Parses an `expr_ns`: at its top level `path {` is not a struct literal,
/// the `{` is left for the block that follows (§3.8.1).
pub fn parseExprNs(p: *Parser) Error!Node.Index {
    return parseBp(p, 0, .{ .ns = true });
}

/// Parses an `expr` in a position where `move e` may be the whole
/// expression (§3.8.2): call arguments, `let` initializers, struct-literal
/// field values, assigned values, `return` values and `spawn` arguments.
pub fn parseExprMove(p: *Parser) Error!Node.Index {
    return parseBp(p, 0, .{ .move_ok = true });
}

/// Parses a `condition` (`if`, `while`): `expr_ns`, or `"let" pattern "="
/// expr_ns` as a `let_cond` whose value may be a `move` (§3.8.2).
pub fn parseCondition(p: *Parser) Error!Node.Index {
    const kw = p.eat(.kw_let) orelse return parseExprNs(p);
    const pattern = try patterns.parsePattern(p);
    _ = try p.expect(.eq);
    const value = try parseBp(p, 0, .{ .ns = true, .move_ok = true });
    return p.addNode(kw, .{ .let_cond = .{ .pattern = pattern, .value = value } });
}

/// Whether a `block_expr` starts at the current token (§3.5: at statement
/// position it ends the statement). `comptime` needs the second token.
pub fn startsBlockExpr(p: *const Parser) bool {
    return switch (p.peek(0)) {
        .l_brace, .kw_if, .kw_match, .kw_loop, .kw_unsafe => true,
        .kw_comptime => p.peek(1) == .l_brace or p.peek(1) == .kw_if,
        else => false,
    };
}

/// Parses a `block_expr` (no postfix operators after it): a block, `if`,
/// `match`, `loop`, `unsafe`, `comptime` block or `comptime if`.
pub fn parseBlockExpr(p: *Parser) Error!Node.Index {
    const t = p.tok_i;
    switch (p.peek(0)) {
        .l_brace => return stmt.parseBlock(p),
        .kw_if => return parseIf(p),
        .kw_match => return parseMatch(p),
        .kw_loop => {
            _ = p.next();
            return p.addNode(t, .{ .loop = .{ .body = try stmt.parseBlock(p) } });
        },
        .kw_unsafe => {
            _ = p.next();
            return p.addNode(t, .{ .unsafe_block = .{ .body = try stmt.parseBlock(p) } });
        },
        .kw_comptime => {
            _ = p.next();
            if (p.peek(0) == .kw_if) return p.addNode(t, .{ .comptime_if = .{ .@"if" = try parseIf(p) } });
            return p.addNode(t, .{ .comptime_block = .{ .body = try stmt.parseBlock(p) } });
        },
        else => return p.failExpected("a block expression"),
    }
}

// ---------------------------------------------------------------------------
// Pratt core (§3.9.1)

/// Parsing mode. `ns` carries into operands; both reset inside brackets.
const Ctx = struct {
    /// `expr_ns`: `path {` is not a struct literal.
    ns: bool = false,
    /// A `move` may be the whole expression.
    move_ok: bool = false,
};

/// Precedence level (§3.9 table) of `k` as an infix operator; its left
/// binding power is twice that. Prefix operators are level 12 and postfix
/// operators level 13, handled by `parseUnary` and `parsePostfix`.
fn infixLevel(k: TokenKind) ?u8 {
    return switch (k) {
        .dot_dot, .dot_dot_eq => 1,
        .pipe_pipe => 2,
        .amp_amp => 3,
        .eq_eq, .bang_eq, .lt, .gt, .lt_eq, .gt_eq => 4,
        .pipe => 5,
        .caret => 6,
        .amp => 7,
        .shl, .shr => 8,
        .plus, .minus => 9,
        .star, .slash, .percent => 10,
        .kw_as => 11,
        else => null,
    };
}

/// Levels whose operators do not chain (E0214).
fn nonAssoc(level: u8) bool {
    return level == 1 or level == 4;
}

/// `parse_expr(min_bp)` of §3.9.1.
fn parseBp(p: *Parser, min_bp: u8, ctx: Ctx) Error!Node.Index {
    const inner: Ctx = .{ .ns = ctx.ns };
    // Level of the last operator consumed by this loop; a range with no
    // left operand counts as one.
    var prev: ?u8 = null;
    var lhs = if (min_bp < 2 and (p.peek(0) == .dot_dot or p.peek(0) == .dot_dot_eq)) blk: {
        prev = 1;
        break :blk try parseRange(p, null, inner);
    } else try parseUnary(p, ctx);
    while (infixLevel(p.peek(0))) |level| {
        if (2 * level <= min_bp) break;
        if (ctx.move_ok and isMove(p, lhs)) try reportMove(p, p.ast.mainToken(lhs));
        const op = p.tok_i;
        if (prev == level and nonAssoc(level)) try reportChain(p, op, level);
        prev = level;
        lhs = switch (level) {
            1 => try parseRange(p, lhs, inner),
            11 => blk: {
                _ = p.next();
                const ty = try types.parseAsTarget(p);
                break :blk try p.addNode(op, .{ .cast = .{ .value = lhs, .ty = ty } });
            },
            else => blk: {
                _ = p.next();
                // Non-associative levels too: the rhs stops at the next
                // operator of the same level, which the loop then rejects.
                const rhs = try parseBp(p, 2 * level, inner);
                if (level == 8) try checkShift(p, op, lhs, rhs);
                break :blk try p.addNode(op, .{ .binary = .{ .lhs = lhs, .rhs = rhs } });
            },
        };
    }
    return lhs;
}

/// `..`/`..=` at the current token after `lo`; the right operand is
/// optional (§3.9 level 1).
fn parseRange(p: *Parser, lo: ?Node.Index, ctx: Ctx) Error!Node.Index {
    const op = p.next();
    const hi = if (startsExpr(p.peek(0), ctx.ns)) try parseBp(p, 2, ctx) else null;
    return p.addNode(op, .{ .range = .{ .lo = lo, .hi = hi } });
}

/// Whether an expression can start with `k`; decides if a range has a
/// right operand.
fn startsExpr(k: TokenKind, ns: bool) bool {
    return switch (k) {
        .ident, .builtin, .int_lit, .float_lit, .char_lit, .string_lit, .ml_string_line => true,
        .kw_true, .kw_false, .kw_self, .kw_Self, .kw_struct, .kw_move, .kw_mut => true,
        .kw_if, .kw_match, .kw_loop, .kw_unsafe, .kw_comptime => true,
        .l_paren, .l_bracket, .dot_l_brace, .dot, .pipe, .pipe_pipe => true,
        .minus, .bang, .tilde, .star, .amp => true,
        .l_brace => !ns,
        else => false,
    };
}

/// A prefix operator (level 12) and its operand, or a primary with its
/// postfix operators (level 13). Equivalent to `parse_expr(24)`: no infix
/// operator binds that tightly.
fn parseUnary(p: *Parser, ctx: Ctx) Error!Node.Index {
    const op = p.tok_i;
    const k = p.peek(0);
    switch (k) {
        .minus, .bang, .tilde, .star, .amp, .kw_move, .kw_mut => {},
        // `comptime {` and `comptime if` are block expressions.
        .kw_comptime => if (p.peek(1) == .l_brace or p.peek(1) == .kw_if) return parsePostfix(p, try parseBlockExpr(p)),
        else => return parsePostfix(p, try parsePrimary(p, ctx)),
    }
    _ = p.next();
    // `-INT_LIT` is a folded constant: the literal may be the magnitude of
    // the most negative value, so it skips the E0108 check (§2.6.1).
    if (k == .minus and p.peek(0) == .int_lit and !startsPostfix(p.peek(1))) {
        const lit = try p.addNode(p.next(), .{ .int_lit = .{} });
        return p.addNode(op, .{ .prefix = .{ .operand = lit } });
    }
    const operand = try parseUnary(p, .{ .ns = ctx.ns });
    switch (k) {
        .kw_mut => {
            try report(p, .E0213, op, "`mut` is not an operator", "`mut` marks a call argument passed as a mutable view: `f(mut x)`");
            return p.addNode(op, .{ .mut_arg = .{ .value = operand } });
        },
        .kw_move => if (!ctx.move_ok) try reportMove(p, op),
        else => {},
    }
    return p.addNode(op, .{ .prefix = .{ .operand = operand } });
}

fn startsPostfix(k: TokenKind) bool {
    return k == .dot or k == .l_paren or k == .l_bracket or k == .question;
}

/// Postfix operators after `base`: `.f`, `.0`, `(args)`, `[i]`, `?`.
fn parsePostfix(p: *Parser, base: Node.Index) Error!Node.Index {
    var lhs = base;
    while (true) switch (p.peek(0)) {
        .dot => {
            _ = p.next();
            if (p.peek(0) != .ident and p.peek(0) != .int_lit) return p.failExpected("a field name");
            lhs = try p.addNode(p.next(), .{ .field_access = .{ .lhs = lhs } });
        },
        .l_paren => {
            const lp = p.next();
            const top = p.scratch.items.len;
            defer p.scratch.shrinkRetainingCapacity(top);
            try types.parseList(p, types.parseCallArg, .r_paren);
            lhs = try p.addNode(lp, .{ .call = .{ .callee = lhs, .args = p.scratch.items[top..] } });
        },
        .l_bracket => {
            const lb = p.next();
            const index = try parseExpr(p);
            _ = try p.expect(.r_bracket);
            lhs = try p.addNode(lb, .{ .index = .{ .lhs = lhs, .index = index } });
        },
        .question => lhs = try p.addNode(p.next(), .{ .try_op = .{ .lhs = lhs } }),
        else => return lhs,
    };
}

// ---------------------------------------------------------------------------
// Primaries (§3.8)

fn parsePrimary(p: *Parser, ctx: Ctx) Error!Node.Index {
    const t = p.tok_i;
    switch (p.peek(0)) {
        .int_lit => {
            try checkFit(p, t);
            return p.addNode(p.next(), .{ .int_lit = .{} });
        },
        .float_lit => return p.addNode(p.next(), .{ .float_lit = .{} }),
        .char_lit => return p.addNode(p.next(), .{ .char_lit = .{} }),
        .string_lit => return p.addNode(p.next(), .{ .string_lit = .{} }),
        .kw_true, .kw_false => return p.addNode(p.next(), .{ .bool_lit = .{} }),
        .ml_string_line => {
            var last = p.next();
            while (p.eat(.ml_string_line)) |l| last = l;
            return p.addNode(t, .{ .ml_string = .{ .last = last } });
        },
        .ident => return parseIdent(p, ctx),
        .kw_self => return p.addNode(p.next(), .{ .self_value = .{} }),
        .kw_Self => {
            const ty = try p.addNode(p.next(), .{ .self_type = .{} });
            return if (!ctx.ns and p.peek(0) == .l_brace) parseStructLit(p, ty) else ty;
        },
        .builtin => {
            _ = p.next();
            // A builtin variable takes no parentheses (§8.7).
            if (p.eat(.l_paren) == null) return p.addNode(t, .{ .builtin_call = .{ .args = null } });
            const top = p.scratch.items.len;
            defer p.scratch.shrinkRetainingCapacity(top);
            try types.parseList(p, types.parseBuiltinArg, .r_paren);
            return p.addNode(t, .{ .builtin_call = .{ .args = p.scratch.items[top..] } });
        },
        .l_paren => {
            _ = p.next();
            const first = try parseExpr(p);
            if (p.eat(.r_paren) != null) return p.addNode(t, .{ .paren = .{ .inner = first } });
            _ = try p.expect(.comma);
            const top = p.scratch.items.len;
            defer p.scratch.shrinkRetainingCapacity(top);
            try p.scratch.append(p.gpa, first);
            try types.parseList(p, parseExpr, .r_paren);
            return p.addNode(t, .{ .tuple = .{ .elems = p.scratch.items[top..] } });
        },
        .l_bracket => return parseArray(p),
        .dot_l_brace => return parseAnonLit(p),
        .dot => {
            _ = p.next();
            return p.addNode(try p.expect(.ident), .{ .inferred_member = .{} });
        },
        .pipe, .pipe_pipe => return parseLambda(p, ctx),
        .kw_struct => return items.parseAnonStruct(p),
        .l_brace, .kw_if, .kw_match, .kw_loop, .kw_unsafe, .kw_comptime => return parseBlockExpr(p),
        else => return p.failExpected("an expression"),
    }
}

/// `IDENT ( "." IDENT )*`: a struct literal's path if `{` follows (outside
/// `expr_ns`), otherwise an identifier with field accesses.
fn parseIdent(p: *Parser, ctx: Ctx) Error!Node.Index {
    const first = p.next();
    var last = first;
    while (p.peek(0) == .dot and p.peek(1) == .ident) {
        _ = p.next();
        last = p.next();
    }
    if (!ctx.ns and p.peek(0) == .l_brace)
        return parseStructLit(p, try p.addNode(first, .{ .path = .{ .last = last } }));
    var n = try p.addNode(first, .{ .ident = .{} });
    var t = first + 2;
    while (t <= last) : (t += 2) n = try p.addNode(t, .{ .field_access = .{ .lhs = n } });
    return n;
}

/// `"{" field_inits? "}"` after the type `ty`.
fn parseStructLit(p: *Parser, ty: Node.Index) Error!Node.Index {
    const lb = try p.expect(.l_brace);
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    while (p.peek(0) != .r_brace) {
        if (p.peek(0) == .dot_dot) {
            try p.scratch.append(p.gpa, try p.addNode(p.next(), .{ .rest = .{} }));
            _ = p.eat(.comma);
            break;
        }
        const name = try p.expect(.ident);
        const value = if (p.eat(.colon) != null) try parseExprMove(p) else null;
        try p.scratch.append(p.gpa, try p.addNode(name, .{ .field_init = .{ .value = value } }));
        if (p.eat(.comma) == null) break;
    }
    _ = try p.expect(.r_brace);
    return p.addNode(lb, .{ .struct_lit = .{ .ty = ty, .fields = p.scratch.items[top..] } });
}

/// `".{" ( anon_elem,* ( "," ".." )? | ".." )? "}"`. A `..` directly before
/// `}` or `, }` is the rest marker; any other `..` starts a range element.
fn parseAnonLit(p: *Parser) Error!Node.Index {
    const lb = p.next();
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    // Whether named and positional elements were seen, for E0215. A bare
    // identifier is neither: it may be `x: x` shorthand (§3.8).
    var named = false;
    var positional = false;
    var mixed = false;
    while (p.peek(0) != .r_brace) {
        const t = p.tok_i;
        var comma_eaten = false;
        const elem = if (p.peek(0) == .dot_dot and (p.peek(1) == .r_brace or p.peek(1) == .comma)) blk: {
            _ = p.next();
            _ = p.eat(.comma);
            if (p.peek(0) == .r_brace) {
                try p.scratch.append(p.gpa, try p.addNode(t, .{ .rest = .{} }));
                break;
            }
            // `.., x`: a full range element; its comma is already consumed.
            comma_eaten = true;
            break :blk try p.addNode(t, .{ .range = .{ .lo = null, .hi = null } });
        } else if (p.peek(0) == .ident and p.peek(1) == .colon) blk: {
            _ = p.next();
            _ = p.next();
            break :blk try p.addNode(t, .{ .named_arg = .{ .value = try parseExprMove(p) } });
        } else try parseExpr(p);
        try p.scratch.append(p.gpa, elem);
        switch (p.ast.kind(elem)) {
            .named_arg => named = true,
            .ident => {},
            else => positional = true,
        }
        if (named and positional and !mixed) {
            mixed = true;
            try report(p, .E0215, t, "this `.{…}` literal mixes named and positional elements", "name every element (`f: e`) or none of them");
        }
        if (!comma_eaten and p.eat(.comma) == null) break;
    }
    _ = try p.expect(.r_brace);
    return p.addNode(lb, .{ .anon_lit = .{ .elems = p.scratch.items[top..] } });
}

/// `array_lit`: empty, a list, `[value; count]` or a comprehension.
fn parseArray(p: *Parser) Error!Node.Index {
    const lb = p.next();
    if (p.eat(.r_bracket) != null) return p.addNode(lb, .{ .array_lit = .{ .elems = &.{} } });
    const first = try parseExpr(p);
    switch (p.peek(0)) {
        .semicolon => {
            _ = p.next();
            const count = try parseExpr(p);
            _ = try p.expect(.r_bracket);
            return p.addNode(lb, .{ .array_repeat = .{ .value = first, .count = count } });
        },
        .kw_for => {
            _ = p.next();
            const pattern = try patterns.parsePattern(p);
            const pattern2 = if (p.eat(.comma) != null) try patterns.parsePattern(p) else null;
            _ = try p.expect(.kw_in);
            const iter = try parseExprNs(p);
            const filter = if (p.eat(.kw_where) != null) try parseExprNs(p) else null;
            _ = try p.expect(.r_bracket);
            return p.addNode(lb, .{ .array_comp = .{
                .elem = first,
                .pattern = pattern,
                .pattern2 = pattern2,
                .iter = iter,
                .filter = filter,
            } });
        },
        else => {
            const top = p.scratch.items.len;
            defer p.scratch.shrinkRetainingCapacity(top);
            try p.scratch.append(p.gpa, first);
            if (p.eat(.comma) != null) try types.parseList(p, parseExpr, .r_bracket) else _ = try p.expect(.r_bracket);
            return p.addNode(lb, .{ .array_lit = .{ .elems = p.scratch.items[top..] } });
        },
    }
}

/// `"|" lambda_param,* "|" expr` or `"||" expr`; the body keeps `ns`.
fn parseLambda(p: *Parser, ctx: Ctx) Error!Node.Index {
    const t = p.tok_i;
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    if (p.eat(.pipe_pipe) == null) {
        _ = try p.expect(.pipe);
        while (p.eat(.pipe) == null) {
            const name = try p.expect(.ident);
            const ty = if (p.eat(.colon) != null) try types.parseType(p) else null;
            try p.scratch.append(p.gpa, try p.addNode(name, .{ .param = .{ .ty = ty, .default = null } }));
            if (p.eat(.comma) == null) {
                _ = try p.expect(.pipe);
                break;
            }
        }
    }
    const body = try parseBp(p, 0, .{ .ns = ctx.ns });
    return p.addNode(t, .{ .lambda = .{ .params = p.scratch.items[top..], .body = body } });
}

/// `if_expr`: `"if" condition block ( "else" ( block | if_expr ) )?`.
fn parseIf(p: *Parser) Error!Node.Index {
    const kw = try p.expect(.kw_if);
    const cond = try parseCondition(p);
    const then = try stmt.parseBlock(p);
    const else_ = if (p.eat(.kw_else) == null)
        null
    else if (p.peek(0) == .kw_if)
        try parseIf(p)
    else
        try stmt.parseBlock(p);
    return p.addNode(kw, .{ .@"if" = .{ .cond = cond, .then = then, .@"else" = else_ } });
}

/// `"match" expr_ns "{" match_arm* "}"`.
fn parseMatch(p: *Parser) Error!Node.Index {
    const kw = p.next();
    const subject = try parseBp(p, 0, .{ .ns = true, .move_ok = true });
    _ = try p.expect(.l_brace);
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    while (p.eat(.r_brace) == null) {
        // `pattern ( "if" expr )? "=>" ( block ","? | expr ( "," | &"}" ) )`
        const pattern = try patterns.parsePattern(p);
        const guard = if (p.eat(.kw_if) != null) try parseExpr(p) else null;
        const arrow = try p.expect(.fat_arrow);
        const body = if (p.peek(0) == .l_brace) blk: {
            const b = try stmt.parseBlock(p);
            _ = p.eat(.comma);
            break :blk b;
        } else blk: {
            const e = try parseExpr(p);
            if (p.eat(.comma) == null and p.peek(0) != .r_brace) return p.failExpected("`,` or `}`");
            break :blk e;
        };
        try p.scratch.append(p.gpa, try p.addNode(arrow, .{ .match_arm = .{ .pattern = pattern, .guard = guard, .body = body } }));
    }
    return p.addNode(kw, .{ .match = .{ .subject = subject, .arms = p.scratch.items[top..] } });
}

// ---------------------------------------------------------------------------
// Checks

fn report(p: *Parser, code: diag.DiagCode, t: TokenIndex, message: []const u8, help: []const u8) std.mem.Allocator.Error!void {
    try p.sink.emit(.{
        .code = code,
        .severity = .of(code),
        .message = message,
        .spans = &.{.{ .span = p.tokenSpan(t), .primary = true }},
        .help = &.{help},
    });
}

fn isMove(p: *const Parser, n: Node.Index) bool {
    return p.ast.kind(n) == .prefix and p.ast.tokens.items(.kind)[p.ast.mainToken(n)] == .kw_move;
}

/// E0213 at the `move` token `t`.
fn reportMove(p: *Parser, t: TokenIndex) std.mem.Allocator.Error!void {
    try report(p, .E0213, t, "`move` is not allowed here", "`move e` may only be a call argument, a `let` initializer, a struct-literal field value, an assigned value, a `return` value, a `match`/`if let` scrutinee or a `spawn` argument");
}

/// E0214 at operator `op`, the second of non-associative `level`.
fn reportChain(p: *Parser, op: TokenIndex, level: u8) std.mem.Allocator.Error!void {
    if (level == 4)
        try report(p, .E0214, op, "comparison operators cannot be chained", "combine the comparisons with `&&`, or add parentheses")
    else
        try report(p, .E0214, op, "range operators cannot be chained", "add parentheses");
}

/// W0201 if shift `op` has an unparenthesized `+`/`-` operand.
fn checkShift(p: *Parser, op: TokenIndex, lhs: Node.Index, rhs: Node.Index) std.mem.Allocator.Error!void {
    const kinds = p.ast.tokens.items(.kind);
    for ([_]Node.Index{ lhs, rhs }) |n| {
        if (p.ast.kind(n) != .binary) continue;
        const k = kinds[p.ast.mainToken(n)];
        if (k != .plus and k != .minus) continue;
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "`{s}` is mixed with `{s}` without parentheses", .{ p.ast.tokenSlice(op), k.lexeme().? }) catch unreachable;
        return report(p, .W0201, op, msg, "add parentheses to make the order explicit: shifts bind looser than `+` and `-`");
    }
}

/// E0108 if integer literal `t` has a signed suffix and is the magnitude of
/// the most negative value, which fits only under a prefix `-` (§2.6.1).
/// Larger magnitudes are rejected by the lexer.
fn checkFit(p: *Parser, t: TokenIndex) std.mem.Allocator.Error!void {
    const text = p.ast.tokenSlice(t);
    const v = literals.decodeInt(text) catch return; // reported by the lexer
    switch (v.suffix) {
        .signed, .isize => if (v.value < v.suffix.maxMagnitude()) return,
        else => return,
    }
    const suffix = text[std.mem.indexOfAny(u8, text, "ui").?..];
    var msg: [64]u8 = undefined;
    var help: [320]u8 = undefined;
    try report(
        p,
        .E0108,
        t,
        std.fmt.bufPrint(&msg, "integer literal does not fit `{s}`", .{suffix}) catch unreachable,
        std.fmt.bufPrint(&help, "the largest `{s}` is {d}; only the negated literal `-{s}` fits", .{ suffix, v.value - 1, text }) catch unreachable,
    );
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const lexer = @import("../lex/lexer.zig");

const test_file: diag.FileId = @fromBackingInt(@intCast(0));

/// Fully parenthesized rendering of the operator structure of `n`, for
/// precedence tests: `(l op r)`, `(op x)`, `(x as T)`, postfix forms, and
/// the main token's text for anything else.
fn render(ast: *const Ast, n: Node.Index, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const mt = ast.tokenSlice(ast.mainToken(n));
    switch (ast.data(n)) {
        .binary => |b| {
            try w.writeByte('(');
            try render(ast, b.lhs, w);
            try w.print(" {s} ", .{mt});
            try render(ast, b.rhs, w);
            try w.writeByte(')');
        },
        .prefix => |x| {
            try w.print("({s}{s}", .{ mt, if (std.ascii.isAlphabetic(mt[0])) " " else "" });
            try render(ast, x.operand, w);
            try w.writeByte(')');
        },
        .cast => |c| {
            try w.writeByte('(');
            try render(ast, c.value, w);
            try w.writeAll(" as ");
            try render(ast, c.ty, w);
            try w.writeByte(')');
        },
        .range => |r| {
            try w.writeByte('(');
            if (r.lo) |lo| try render(ast, lo, w);
            try w.writeAll(mt);
            if (r.hi) |hi| try render(ast, hi, w);
            try w.writeByte(')');
        },
        .paren => |x| try render(ast, x.inner, w),
        .field_access => |f| {
            try render(ast, f.lhs, w);
            try w.print(".{s}", .{mt});
        },
        .call => |c| {
            try render(ast, c.callee, w);
            try w.writeByte('(');
            for (c.args, 0..) |a, i| {
                if (i > 0) try w.writeAll(", ");
                try render(ast, a, w);
            }
            try w.writeByte(')');
        },
        .index => |x| {
            try render(ast, x.lhs, w);
            try w.writeByte('[');
            try render(ast, x.index, w);
            try w.writeByte(']');
        },
        .try_op => |x| {
            try render(ast, x.lhs, w);
            try w.writeByte('?');
        },
        else => try w.writeAll(mt),
    }
}

/// Parses `src` with `parseFn` to the end; returns the rendering and the
/// diagnostic codes in emission order, as `rendering | CODE CODE`.
fn parseFor(buf: []u8, parseFn: fn (*Parser) Error!Node.Index, src: []const u8) ![]const u8 {
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    const tokens = try lexer.tokenize(testing.allocator, src, test_file, &sink, .{ .scan_literal = literals.scan });
    var p: Parser = .init(testing.allocator, src, tokens, test_file, &sink);
    defer p.deinit();
    const n = try parseFn(&p);
    try testing.expectEqual(.eof, p.peek(0));
    var w: std.Io.Writer = .fixed(buf);
    try render(&p.ast, n, &w);
    const ds = sink.finish();
    if (ds.len > 0) try w.writeAll(" |");
    for (ds) |d| try w.print(" {s}", .{@tagName(d.code.?)});
    return w.buffered();
}

fn expectExpr(src: []const u8, want: []const u8) !void {
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings(want, try parseFor(&buf, parseExpr, src));
}

fn expectTree(src: []const u8, want: []const u8) !void {
    var buf: [1024]u8 = undefined;
    try testing.expectEqualStrings(want, try types.testTree(&buf, parseExpr, src, .eof));
}

test "binding powers follow the §3.9 table" {
    // Acceptance: bitwise binds tighter than comparison.
    try expectExpr("flags & MASK == 0", "((flags & MASK) == 0)");
    // Acceptance: prefix binds tighter than `as`, postfix tighter than prefix.
    try expectExpr("-x as u8", "((-x) as u8)");
    try expectExpr("-a.b()", "(-a.b())");
    try expectExpr("!xs.is_empty()", "(!xs.is_empty())");
    try expectExpr("-xs[0] as i64", "((-xs[0]) as i64)");
    try expectExpr("a + b * c - d / e % f", "((a + (b * c)) - ((d / e) % f))");
    try expectExpr("a - b - c", "((a - b) - c)");
    try expectExpr("p || q && r", "(p || (q && r))");
    try expectExpr("a ^ b & c | d", "((a ^ (b & c)) | d)");
    try expectExpr("a | b == c", "((a | b) == c)");
    try expectExpr("a << 2 | b >> 1", "((a << 2) | (b >> 1))");
    try expectExpr("a * 2 << 1", "((a * 2) << 1)");
    try expectExpr("a as u64 + b as u64", "((a as u64) + (b as u64))");
    try expectExpr("a < b && b <= c", "((a < b) && (b <= c))");
    try expectExpr("a..b + 1", "(a..(b + 1))");
    try expectExpr("0..xs.len() as u32", "(0..(xs.len() as u32))");
    try expectExpr("parse(a)? + 1", "(parse(a)? + 1)");
    try expectExpr("comptime a + b", "((comptime a) + b)");
    try expectExpr("*p.x", "(*p.x)");
    try expectExpr("--x", "(-(-x))");
    try expectExpr("t.0.1", "t.0.1");
    // `as` takes a type with no `<...>`: the `<` compares.
    try expectExpr("x as u32 < y", "((x as u32) < y)");
}

test "ranges: optional operands" {
    try expectExpr("a..b", "(a..b)");
    try expectExpr("a..=b", "(a..=b)");
    try expectExpr("a..", "(a..)");
    try expectExpr("..b", "(..b)");
    try expectExpr("..", "(..)");
    try expectExpr("xs[1..n]", "xs[(1..n)]");
    try expectExpr("xs[..]", "xs[(..)]");
    try expectExpr("(0..a) == (0..b)", "((0..a) == (0..b))");
}

test "E0214: non-associative levels do not chain" {
    // Acceptance.
    try expectExpr("a < b < c", "((a < b) < c) | E0214");
    try expectExpr("a == b == p", "((a == b) == p) | E0214");
    try expectExpr("a >= b != p", "((a >= b) != p) | E0214");
    try expectExpr("0..a..b", "((0..a)..b) | E0214");
    try expectExpr("..a..b", "((..a)..b) | E0214");
    try expectExpr("(a < b) == (b < c)", "((a < b) == (b < c))");
    try expectExpr("a < b || c < d == e", "((a < b) || ((c < d) == e)) | E0214");
}

test "W0201: shift mixed with `+`/`-` without parentheses" {
    try expectExpr("a << 1 + b", "(a << (1 + b)) | W0201");
    try expectExpr("a + b >> 2", "((a + b) >> 2) | W0201");
    try expectExpr("a - 1 << b", "((a - 1) << b) | W0201");
    try expectExpr("(a << 1) + b", "((a << 1) + b)");
    try expectExpr("a << (1 + b)", "(a << (1 + b))");
    try expectExpr("a >> 1 >> 2", "((a >> 1) >> 2)");
    try expectExpr("a & b << 1", "(a & (b << 1))");
}

test "E0108: a prefix `-` folds into the literal" {
    // Acceptance.
    try expectExpr("-128i8", "(-128i8)");
    try expectExpr("128i8", "128i8 | E0108");
    try expectExpr("-9223372036854775808i64", "(-9223372036854775808i64)");
    try expectExpr("-9223372036854775808isize", "(-9223372036854775808isize)");
    try expectExpr("9223372036854775808isize", "9223372036854775808isize | E0108");
    try expectExpr("127i8 + -1i1", "(127i8 + (-1i1))");
    try expectExpr("255u8", "255u8");
    // Only a `-` directly on the literal folds.
    try expectExpr("-128i8.abs()", "(-128i8.abs()) | E0108");
    try expectExpr("-(128i8)", "(-128i8) | E0108");
    try expectExpr("-128i8 as u8", "((-128i8) as u8)");
}

test "E0213: `mut` and `move` positions" {
    try expectExpr("mut a", "mut | E0213");
    try expectExpr("f(mut a, x: mut b)", "f(mut, x)");
    try expectExpr("f(1 + mut a)", "f((1 + mut)) | E0213");
    try expectExpr("f(move a)", "f((move a))");
    try expectExpr("move a", "(move a) | E0213");
    try expectExpr("1 + move r", "(1 + (move r)) | E0213");
    try expectExpr("[move t]", "[ | E0213");
    try expectExpr("P { r: move x }", "{");
    try expectExpr("match move h { _ => 1 }", "match");
    try expectExpr("if move s {}", "if | E0213");
    try expectExpr("if let x = move s {}", "if");
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("(move a)", try parseFor(&buf, parseExprMove, "move a"));
    try testing.expectEqualStrings("((move a) + 1) | E0213", try parseFor(&buf, parseExprMove, "move a + 1"));
    try testing.expectEqualStrings("(-(move a)) | E0213", try parseFor(&buf, parseExprMove, "-move a"));
}

test "every primary form" {
    try expectTree("42", "int_lit:42");
    try expectTree("3.5e2", "float_lit:3.5e2");
    try expectTree("'x'", "char_lit:'x'");
    try expectTree("\"s\"", "string_lit:\"s\"");
    try expectTree("true", "bool_lit:true");
    try expectTree("\\\\a\n\\\\b\n", "ml_string:\\\\a");
    try expectTree("x", "ident:x");
    try expectTree("self", "self_value:self");
    try expectTree("Self", "self_type:Self");
    try expectTree("@line", "builtin_call(_)");
    try expectTree("@size_of(Pool(T))", "builtin_call(call(ident:Pool ident:T))");
    try expectTree("@size_of(soa[4]P)", "builtin_call(soa_array_type(int_lit:4 path:P))");
    try expectTree("(a)", "paren(ident:a)");
    try expectTree("(a,)", "tuple(ident:a)");
    try expectTree("(a, b, c,)", "tuple(ident:a ident:b ident:c)");
    try expectTree("[]", "array_lit:[");
    try expectTree("[1, 2,]", "array_lit(int_lit:1 int_lit:2)");
    try expectTree("[0; 16]", "array_repeat(int_lit:0 int_lit:16)");
    try expectTree("[x for x in xs]", "array_comp(ident:x pat_bind:x _ ident:xs _)");
    try expectTree("[x for x, i in xs where i > 2]", "array_comp(ident:x pat_bind:x pat_bind:i ident:xs binary(ident:i int_lit:2))");
    try expectTree("P { x: 1, y, }", "struct_lit(path:P field_init(int_lit:1) field_init(_))");
    try expectTree("geo.P { x: 1, .. }", "struct_lit(path:geo field_init(int_lit:1) rest:..)");
    try expectTree("P { .. }", "struct_lit(path:P rest:..)");
    try expectTree("Self {}", "struct_lit(self_type:Self)");
    try expectTree(".{ x: 1, y: 2 }", "anon_lit(named_arg(int_lit:1) named_arg(int_lit:2))");
    try expectTree(".{ 1, 2, }", "anon_lit(int_lit:1 int_lit:2)");
    try expectTree(".{ x, y }", "anon_lit(ident:x ident:y)");
    try expectTree(".{ x: 1, .. }", "anon_lit(named_arg(int_lit:1) rest:..)");
    try expectTree(".{ x: 1, .., }", "anon_lit(named_arg(int_lit:1) rest:..)");
    try expectTree(".{ .. }", "anon_lit(rest:..)");
    try expectTree(".{ .., 1 }", "anon_lit(range(_ _) int_lit:1)");
    try expectTree(".{ ..a }", "anon_lit(range(_ ident:a))");
    try expectTree(".{}", "anon_lit:.{");
    try expectTree(".red", "inferred_member:red");
    try expectTree("|x| x + 1", "lambda(param(_ _) binary(ident:x int_lit:1))");
    try expectTree("|x: i32, y,| x", "lambda(param(path:i32 _) param(_ _) ident:x)");
    try expectTree("|| 0", "lambda(int_lit:0)");
    try expectTree("{ 1 }", "block(_)");
    try expectTree("if a {} else if b {} else {}", "if(ident:a block(_) if(ident:b block(_) block(_)))");
    try expectTree("if let .some(v) = f() {}", "if(let_cond(pat_variant(pat_bind:v) call(ident:f)) block(_) _)");
    try expectTree("match a { 0 => 1, x if x > 1 => { 2 } _ => 3 }", "match(ident:a match_arm(int_lit:0 _ int_lit:1) match_arm(pat_bind:x binary(ident:x int_lit:1) block(_)) match_arm(pat_wildcard:_ _ int_lit:3))");
    try expectTree("loop {}", "loop(block(_))");
    try expectTree("unsafe {}", "unsafe_block(block(_))");
    try expectTree("comptime {}", "comptime_block(block(_))");
    try expectTree("comptime if a {}", "comptime_if(if(ident:a block(_) _))");
    try expectTree("comptime 3", "prefix(int_lit:3)");
    try expectTree("struct { x: i32 }", "anon_struct(field_decl(path:i32 _))");
}

test "postfix forms" {
    try expectTree("p.x", "field_access(ident:p)");
    try expectTree("a.b.c", "field_access(field_access(ident:a))");
    try expectTree("t.0", "field_access(ident:t)");
    try expectTree("p.m(1, n: 2)", "call(field_access(ident:p) int_lit:1 named_arg(int_lit:2))");
    try expectTree("Pool(Particle).init()", "call(field_access(call(ident:Pool ident:Particle)))");
    try expectTree("xs[0]", "index(ident:xs int_lit:0)");
    try expectTree("f()?", "try_op(call(ident:f))");
    try expectTree("{ 1 }.x", "field_access(block(_))");
}

test "expr_ns: `path {` opens the block" {
    // Acceptance.
    try expectTree("if p == Point {}", "if(binary(ident:p ident:Point) block(_) _)");
    try expectTree("if p == (Point { x: 0 }) {}", "if(binary(ident:p paren(struct_lit(path:Point field_init(int_lit:0)))) block(_) _)");
    try expectTree("if f(P {}) {}", "if(call(ident:f struct_lit(path:P)) block(_) _)");
    try expectTree("if [P {}][0] == p {}", "if(binary(index(array_lit(struct_lit(path:P)) int_lit:0) ident:p) block(_) _)");
    try expectTree("match a.b { _ => {} }", "match(field_access(ident:a) match_arm(pat_wildcard:_ _ block(_)))");
    try expectTree("[x for x in 0.. where x > P]", "array_comp(ident:x pat_bind:x _ range(int_lit:0 _) binary(ident:x ident:P))");
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("ident:P", try types.testTree(&buf, parseExprNs, "P { x: 1 }", .l_brace));
    try testing.expectEqualStrings("range(int_lit:0 _)", try types.testTree(&buf, parseExprNs, "0.. {}", .l_brace));
}

test "E0215: `.{…}` elements are all named or all positional" {
    // Acceptance.
    try expectExpr(".{x: 1, 2}", ".{ | E0215");
    try expectExpr(".{ 1, y: 2 }", ".{ | E0215");
    try expectExpr(".{ x: 1, y: 2, 3, 4, .. }", ".{ | E0215");
    // A bare identifier may be `x: x` shorthand, so it mixes with both.
    try expectExpr(".{ x: 1, y }", ".{");
    try expectExpr(".{ 1, y }", ".{");
}

test "malformed expressions report one error" {
    try types.testFail(parseExpr, "", "expected an expression, found end of file");
    try types.testFail(parseExpr, "a +", "expected an expression, found end of file");
    try types.testFail(parseExpr, "(a b)", "expected `,`, found `b`");
    try types.testFail(parseExpr, "f(a b)", "expected `)`, found `b`");
    try types.testFail(parseExpr, "a.", "expected a field name, found end of file");
    try types.testFail(parseExpr, "[1, 2", "expected `]`, found end of file");
    try types.testFail(parseExpr, "P { x 1 }", "expected `}`, found `1`");
    try types.testFail(parseExpr, "P { .., x }", "expected `}`, found `x`");
    try types.testFail(parseExpr, "match a { 1 => 2 3 => 4 }", "expected `,` or `}`, found `3`");
    try types.testFail(parseExpr, "|x x", "expected `|`, found `x`");
    try types.testFail(parseExpr, "if a", "expected `{`, found end of file");
}
