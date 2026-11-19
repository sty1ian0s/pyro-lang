//! Statements and blocks (§3.5): every statement form, labels, statement
//! attributes, the `block` tail expression, and the checks the grammar does
//! not express: E0208 (`spawn`, `launch` and `return tail` need a call) and
//! E0209 (`launch` target is `gpu` or `cpu`). Both report and parsing
//! continues.
//!
//! A statement that fails to parse is recovered at the statement level: the
//! block loop skips to the next `;` or closing `}` and keeps a poisoned
//! `invalid` node in its place, so one broken statement costs one error.
//!
//! Assignment is a statement, never an expression: the right side of an
//! `assign_op` must be followed by `;`, so `a = b = c` is a syntax error, and
//! `if a = b` stops the condition before `=` and fails to find the block.

const std = @import("std");
const Parser = @import("Parser.zig");
const Ast = @import("../ast/Ast.zig");
const diag = @import("../diag/diag.zig");
const expr = @import("expr.zig");
const types = @import("types.zig");
const patterns = @import("patterns.zig");
const items = @import("items.zig");

const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;
const TokenKind = @import("../lex/token.zig").TokenKind;
const Error = Parser.Error;

/// Parses a `block`: `"{" stmt* expr? "}"`. An expression statement is the
/// expression node itself. The last statement is the `tail` when it is an
/// expression without `;`, or a `block_expr`, directly before the `}`.
pub fn parseBlock(p: *Parser) Error!Node.Index {
    const lb = try p.expect(.l_brace);
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    var tail: ?Node.Index = null;
    while (true) {
        try eatDocs(p);
        if (p.peek(0) == .r_brace or p.peek(0) == .eof) break;
        const start = p.tok_i;
        const len = p.scratch.items.len;
        const s = parseStmt(p) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseError => blk: {
                p.scratch.shrinkRetainingCapacity(len); // attributes of the broken statement
                break :blk Stmt{ .node = try p.recover(.stmt, start) };
            },
        };
        if (s.tail) {
            tail = s.node;
            break;
        }
        try p.scratch.append(p.gpa, s.node);
    }
    _ = try p.expect(.r_brace);
    return p.addNode(lb, .{ .block = .{ .stmts = p.scratch.items[top..], .tail = tail } });
}

/// Doc comments document items, fields, variants and parameters (§2.8). In
/// a block only a local `const` comes close; before anything else they get
/// W0101.
fn eatDocs(p: *Parser) std.mem.Allocator.Error!void {
    const first = try items.eatDocs(p) orelse return;
    if (p.peek(0) != .kw_const)
        try items.reportNothing(p, first, p.tok_i - 1, "statements are not documented; use `//` for an ordinary comment");
}

/// One statement; `tail` if it is the block's final expression.
const Stmt = struct {
    node: Node.Index,
    tail: bool = false,
};

fn parseStmt(p: *Parser) Error!Stmt {
    const t = p.tok_i;
    switch (p.peek(0)) {
        .semicolon => return .{ .node = try p.addNode(p.next(), .{ .empty_stmt = .{} }) },
        .kw_let => return .{ .node = try parseLet(p) },
        .kw_const => return .{ .node = try items.parseConst(p) },
        .kw_guard => {
            _ = p.next();
            _ = try p.expect(.kw_let);
            const pattern = try patterns.parsePattern(p);
            _ = try p.expect(.eq);
            const value = try expr.parseExpr(p);
            _ = try p.expect(.kw_else);
            const else_ = try parseBlock(p);
            return .{ .node = try p.addNode(t, .{ .guard_let = .{ .pattern = pattern, .value = value, .@"else" = else_ } }) };
        },
        .kw_defer => {
            _ = p.next();
            return .{ .node = try p.addNode(t, .{ .@"defer" = .{ .body = try parseDeferBody(p) } }) };
        },
        .kw_errdefer => {
            _ = p.next();
            return .{ .node = try p.addNode(t, .{ .@"errdefer" = .{ .body = try parseDeferBody(p) } }) };
        },
        .kw_return => {
            _ = p.next();
            if (p.eat(.kw_tail) != null) {
                const call = try parseCall(p, "`return tail`", false);
                _ = try p.expect(.semicolon);
                return .{ .node = try p.addNode(t, .{ .return_tail = .{ .call = call } }) };
            }
            const value = if (p.peek(0) == .semicolon) null else try expr.parseExprMove(p);
            _ = try p.expect(.semicolon);
            return .{ .node = try p.addNode(t, .{ .@"return" = .{ .value = value } }) };
        },
        .kw_break => {
            _ = p.next();
            const label = try parseLabelRef(p);
            const value = if (p.peek(0) == .semicolon) null else try expr.parseExpr(p);
            _ = try p.expect(.semicolon);
            return .{ .node = try p.addNode(t, .{ .@"break" = .{ .label = label, .value = value } }) };
        },
        .kw_continue => {
            _ = p.next();
            const label = try parseLabelRef(p);
            _ = try p.expect(.semicolon);
            return .{ .node = try p.addNode(t, .{ .@"continue" = .{ .label = label } }) };
        },
        .kw_spawn => {
            _ = p.next();
            const call = try parseCall(p, "`spawn`", true);
            _ = try p.expect(.semicolon);
            return .{ .node = try p.addNode(t, .{ .spawn = .{ .call = call } }) };
        },
        .kw_launch => return .{ .node = try parseLaunch(p) },
        .kw_nursery => {
            _ = p.next();
            return .{ .node = try p.addNode(t, .{ .nursery = .{ .body = try parseBlock(p) } }) };
        },
        .kw_while, .kw_for, .kw_inline, .kw_parallel_for => return .{ .node = try parseLoop(p) },
        .ident => if (p.peek(1) == .colon) {
            // `label? attribute* loop_stmt` or `label "loop" block`.
            _ = p.next();
            _ = p.next();
            const inner = if (p.peek(0) == .kw_loop) try expr.parseBlockExpr(p) else try parseAttributed(p, false);
            return .{ .node = try p.addNode(t, .{ .labeled = .{ .inner = inner } }) };
        } else if (p.peek(1) == .eq and std.mem.eql(u8, p.ast.tokenSlice(t), "_")) {
            _ = p.next();
            _ = p.next();
            const value = try expr.parseExpr(p);
            _ = try p.expect(.semicolon);
            return .{ .node = try p.addNode(t, .{ .discard = .{ .value = value } }) };
        },
        // `@simd for ...` and `@workgroup let ...` are attributed statements;
        // `@assert(x);` is an expression statement. The token after the
        // builtins decides.
        .builtin => if (Parser.skipAttributes(p.ast.tokens.items(.kind), t)) |after| switch (p.ast.tokens.items(.kind)[after]) {
            .kw_let, .kw_while, .kw_for, .kw_inline, .kw_parallel_for => return .{ .node = try parseAttributed(p, true) },
            else => {},
        },
        else => {},
    }
    // A `block_expr` ends the statement (§3.5): no `;`, no operators after it.
    if (expr.startsBlockExpr(p)) {
        const n = try expr.parseBlockExpr(p);
        return .{ .node = n, .tail = p.peek(0) == .r_brace };
    }
    const lhs = try expr.parseExpr(p);
    if (isAssignOp(p.peek(0))) {
        const op = p.next();
        const rhs = try expr.parseExprMove(p);
        _ = try p.expect(.semicolon);
        return .{ .node = try p.addNode(op, .{ .assign = .{ .lhs = lhs, .rhs = rhs } }) };
    }
    if (p.peek(0) == .r_brace) return .{ .node = lhs, .tail = true };
    _ = try p.expect(.semicolon);
    return .{ .node = lhs };
}

fn isAssignOp(k: TokenKind) bool {
    return switch (k) {
        .eq, .plus_eq, .minus_eq, .star_eq, .slash_eq, .percent_eq, .amp_eq, .pipe_eq, .caret_eq, .shl_eq, .shr_eq => true,
        else => false,
    };
}

/// `"let" pattern ( ":" type )? "=" expr ";"`.
fn parseLet(p: *Parser) Error!Node.Index {
    const kw = try p.expect(.kw_let);
    const pattern = try patterns.parsePattern(p);
    const ty = if (p.eat(.colon) != null) try types.parseType(p) else null;
    _ = try p.expect(.eq);
    const init = try expr.parseExprMove(p);
    _ = try p.expect(.semicolon);
    return p.addNode(kw, .{ .let = .{ .pattern = pattern, .ty = ty, .init = init } });
}

/// `attribute* let_stmt` (if `let_ok`) or `attribute* loop_stmt`, wrapped in
/// `attributed` when there are attributes.
fn parseAttributed(p: *Parser, let_ok: bool) Error!Node.Index {
    const top = p.scratch.items.len;
    try items.parseAttrs(p);
    const inner = switch (p.peek(0)) {
        .kw_let => if (let_ok) try parseLet(p) else return p.failExpected("a loop"),
        .kw_while, .kw_for, .kw_inline, .kw_parallel_for => try parseLoop(p),
        else => return p.failExpected(if (let_ok) "`let` or a loop" else "a loop"),
    };
    return items.wrap(p, top, inner);
}

/// `while_stmt`, `for_stmt` (maybe `inline`) or `parallel_for_stmt`.
fn parseLoop(p: *Parser) Error!Node.Index {
    if (p.eat(.kw_while)) |kw| {
        // §3.8.2: `move` is allowed as an `if let` scrutinee, not `while let`.
        const cond = try expr.parseCondition(p, false);
        return p.addNode(kw, .{ .@"while" = .{ .cond = cond, .body = try parseBlock(p) } });
    }
    if (p.eat(.kw_parallel_for)) |kw| {
        const pattern = try patterns.parsePattern(p);
        _ = try p.expect(.kw_in);
        const iter = try expr.parseExprNs(p);
        return p.addNode(kw, .{ .parallel_for = .{ .pattern = pattern, .iter = iter, .body = try parseBlock(p) } });
    }
    const is_inline = p.eat(.kw_inline) != null;
    const kw = try p.expect(.kw_for);
    const pattern = try patterns.parsePattern(p);
    const pattern2 = if (p.eat(.comma) != null) try patterns.parsePattern(p) else null;
    _ = try p.expect(.kw_in);
    const iter = try expr.parseExprNs(p);
    const filter = if (p.eat(.kw_where) != null) try expr.parseExprNs(p) else null;
    const body = try parseBlock(p);
    return if (is_inline)
        p.addNode(kw, .{ .for_inline = .{ .pattern = pattern, .pattern2 = pattern2, .iter = iter, .filter = filter, .body = body } })
    else
        p.addNode(kw, .{ .@"for" = .{ .pattern = pattern, .pattern2 = pattern2, .iter = iter, .filter = filter, .body = body } });
}

/// `( block | expr ";" )` after `defer`/`errdefer`.
fn parseDeferBody(p: *Parser) Error!Node.Index {
    if (p.peek(0) == .l_brace) return parseBlock(p);
    const e = try expr.parseExpr(p);
    _ = try p.expect(.semicolon);
    return e;
}

/// `( ":" IDENT )?` after `break`/`continue`.
fn parseLabelRef(p: *Parser) Error!?TokenIndex {
    return if (p.eat(.colon) != null) try p.expect(.ident) else null;
}

/// `"launch" IDENT expr ( "over" expr )? ";"`. `gpu`, `cpu` and `over` are
/// contextual: identifiers everywhere else (§2.4.1).
fn parseLaunch(p: *Parser) Error!Node.Index {
    const kw = try p.expect(.kw_launch);
    const target = p.eat(.ident) orelse return p.failExpected("`gpu` or `cpu`");
    const name = p.ast.tokenSlice(target);
    if (!std.mem.eql(u8, name, "gpu") and !std.mem.eql(u8, name, "cpu")) {
        var buf: [320]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "`launch` target must be `gpu` or `cpu`, found `{s}`", .{name[0..@min(name.len, 256)]}) catch unreachable;
        try report(p, .E0209, p.tokenSpan(target), msg, "write `launch gpu f(...)` or `launch cpu f(...)`");
    }
    const call = try parseCall(p, "`launch`", false);
    const over = if (p.peek(0) == .ident and std.mem.eql(u8, p.ast.tokenSlice(p.tok_i), "over")) blk: {
        _ = p.next();
        break :blk try expr.parseExpr(p);
    } else null;
    _ = try p.expect(.semicolon);
    return p.addNode(kw, .{ .launch = .{ .call = call, .over = over } });
}

/// The expression after `spawn`, `launch IDENT` or `return tail` (`what`);
/// E0208 unless it is a call. `move_ok` for `spawn` (§3.8.2).
fn parseCall(p: *Parser, comptime what: []const u8, move_ok: bool) Error!Node.Index {
    const start = p.tok_i;
    const n = if (move_ok) try expr.parseExprMove(p) else try expr.parseExpr(p);
    if (p.ast.kind(n) != .call) try report(p, .E0208, .{
        .file = p.file,
        .start = p.tokenSpan(start).start,
        .end = p.tokenSpan(p.tok_i - 1).end,
    }, what ++ " needs a call expression", "write a function or method call here, as in `f(x)`");
    return n;
}

fn report(p: *Parser, code: diag.DiagCode, span: diag.Span, message: []const u8, help: []const u8) std.mem.Allocator.Error!void {
    try p.sink.emit(.{
        .code = code,
        .severity = .of(code),
        .message = message,
        .spans = &.{.{ .span = span, .primary = true }},
        .help = &.{help},
    });
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const lexer = @import("../lex/lexer.zig");
const literals = @import("../lex/literals.zig");
const dump = @import("../ast/dump.zig");

/// Compact tree of `parseBlock` on `src` (no diagnostics, all consumed).
fn expectBlock(src: []const u8, want: []const u8) !void {
    var buf: [1024]u8 = undefined;
    try testing.expectEqualStrings(want, try types.testTree(&buf, parseBlock, src, .eof));
}

/// Parses `src` as a block to the end and returns the diagnostic codes in
/// emission order (`-` for a code-less syntax error), space-separated.
fn blockCodes(buf: []u8, src: []const u8) ![]const u8 {
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    const tokens = try lexer.tokenize(testing.allocator, src, @fromBackingInt(0), &sink, .{ .scan_literal = literals.scan });
    var p: Parser = .init(testing.allocator, src, tokens, @fromBackingInt(0), &sink);
    defer p.deinit();
    _ = parseBlock(&p) catch {};
    var w: std.Io.Writer = .fixed(buf);
    for (sink.finish(), 0..) |d, i| {
        if (i > 0) try w.writeByte(' ');
        try w.writeAll(if (d.code) |c| @tagName(c) else "-");
    }
    return w.buffered();
}

fn expectCodes(src: []const u8, want: []const u8) !void {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(want, try blockCodes(&buf, src));
}

/// `parseBlock` on `src` reports exactly one diagnostic, `message`.
fn expectFail(src: []const u8, message: []const u8) !void {
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    const tokens = try lexer.tokenize(testing.allocator, src, @fromBackingInt(0), &sink, .{ .scan_literal = literals.scan });
    var p: Parser = .init(testing.allocator, src, tokens, @fromBackingInt(0), &sink);
    defer p.deinit();
    _ = parseBlock(&p) catch {};
    const ds = sink.finish();
    try testing.expectEqual(1, ds.len);
    try testing.expectEqualStrings(message, ds[0].message);
}

test "golden per statement form" {
    try expectBlock("{}", "block(_)");
    try expectBlock("{ ; }", "block(empty_stmt:; _)");
    try expectBlock("{ let a = 1; }", "block(let(pat_bind:a _ int_lit:1) _)");
    try expectBlock("{ let mut b: u32 = 2; }", "block(let(pat_bind_mut:b path:u32 int_lit:2) _)");
    try expectBlock("{ let (c, d) = (3, 4); }", "block(let(pat_tuple(pat_bind:c pat_bind:d) _ tuple(int_lit:3 int_lit:4)) _)");
    try expectBlock("{ let r = move x; }", "block(let(pat_bind:r _ prefix(ident:x)) _)");
    try expectBlock("{ const K: u32 = 5; }", "block(const_decl(path:u32 int_lit:5) _)");
    try expectBlock("{ guard let .some(v) = opt else { return 0; } }", "block(guard_let(pat_variant(pat_bind:v) ident:opt block(return(int_lit:0) _)) _)");
    try expectBlock("{ defer f(1); defer { f(2); } }", "block(defer(call(ident:f int_lit:1)) defer(block(call(ident:f int_lit:2) _)) _)");
    try expectBlock("{ errdefer f(3); errdefer { } }", "block(errdefer(call(ident:f int_lit:3)) errdefer(block(_)) _)");
    try expectBlock("{ return; }", "block(return(_) _)");
    try expectBlock("{ return move r; }", "block(return(prefix(ident:r)) _)");
    try expectBlock("{ return tail f(n - 1); }", "block(return_tail(call(ident:f binary(ident:n int_lit:1))) _)");
    try expectBlock("{ break; break :outer; break :outer 1; break x; }", "block(break(_) break(_) break(int_lit:1) break(ident:x) _)");
    try expectBlock("{ continue; continue :outer; }", "block(continue:continue continue:continue _)");
    try expectBlock("{ nursery { spawn f(move x); } }", "block(nursery(block(spawn(call(ident:f prefix(ident:x))) _)) _)");
    try expectBlock("{ launch gpu k(mut xs); }", "block(launch(call(ident:k mut_arg(ident:xs)) _) _)");
    try expectBlock("{ launch cpu k(xs) over 0..n; }", "block(launch(call(ident:k ident:xs) range(int_lit:0 ident:n)) _)");
    try expectBlock("{ while b < 10 { b += 1; } }", "block(while(binary(ident:b int_lit:10) block(assign(ident:b int_lit:1) _)) _)");
    try expectBlock("{ while let .some(w) = q.pop() { } }", "block(while(let_cond(pat_variant(pat_bind:w) call(field_access(ident:q))) block(_)) _)");
    try expectBlock("{ for i in 0..n { } }", "block(for(pat_bind:i _ range(int_lit:0 ident:n) _ block(_)) _)");
    try expectBlock("{ for x, i in xs where i > 0 { } }", "block(for(pat_bind:x pat_bind:i ident:xs binary(ident:i int_lit:0) block(_)) _)");
    try expectBlock("{ inline for f in fs { } }", "block(for_inline(pat_bind:f _ ident:fs _ block(_)) _)");
    try expectBlock("{ parallel_for x in xs { x *= 2.0; } }", "block(parallel_for(pat_bind:x ident:xs block(assign(ident:x float_lit:2.0) _)) _)");
    try expectBlock("{ outer: for i in xs { } }", "block(labeled(for(pat_bind:i _ ident:xs _ block(_))) _)");
    try expectBlock("{ spin: loop { break :spin; } }", "block(labeled(loop(block(break(_) _))) _)");
    try expectBlock("{ @simd for x in xs { } }", "block(attributed(attribute(_) for(pat_bind:x _ ident:xs _ block(_))) _)");
    try expectBlock("{ c: @simd @unroll(4) while x { } }", "block(labeled(attributed(attribute(_) attribute(int_lit:4) while(ident:x block(_)))) _)");
    try expectBlock("{ @workgroup let t: T = @zero(T); }", "block(attributed(attribute(_) let(pat_bind:t path:T builtin_call(ident:T))) _)");
    try expectBlock("{ @assert(x); }", "block(builtin_call(ident:x) _)");
    try expectBlock("{ @line }", "block(builtin_call(_))");
    try expectBlock("{ _ = f(6); }", "block(discard(call(ident:f int_lit:6)) _)");
    try expectBlock("{ b = 3; b <<= 1; xs[i].y >>= 2; }", "block(assign(ident:b int_lit:3) assign(ident:b int_lit:1) assign(field_access(index(ident:xs ident:i)) int_lit:2) _)");
    try expectBlock("{ f(b); }", "block(call(ident:f ident:b) _)");
    try expectBlock("{ { let inner = 1; } }", "block(block(let(pat_bind:inner _ int_lit:1) _))");
}

test "tail expression" {
    try expectBlock("{ 1 }", "block(int_lit:1)");
    try expectBlock("{ let a = 1; a + 1 }", "block(let(pat_bind:a _ int_lit:1) binary(ident:a int_lit:1))");
    try expectBlock("{ a; }", "block(ident:a _)");
    try expectBlock("{ if c { x } else { y } }", "block(if(ident:c block(ident:x) block(ident:y)))");
    try expectBlock("{ if c { } f(); }", "block(if(ident:c block(_) _) call(ident:f) _)");
    try expectBlock("{ P { x: 1 } }", "block(struct_lit(path:P field_init(int_lit:1)))");
}

test "a block expression ends the statement" {
    // §3.5: `if c {} - 1` is an `if` statement and the expression `-1`.
    try expectBlock("{ if c {} -1; }", "block(if(ident:c block(_) _) prefix(int_lit:1) _)");
    try expectBlock("{ match x { _ => {} } (x, x); }", "block(match(ident:x match_arm(pat_wildcard:_ _ block(_))) tuple(ident:x ident:x) _)");
    try expectBlock("{ loop { break; } !c; }", "block(loop(block(break(_) _)) prefix(ident:c) _)");
    try expectBlock("{ comptime { } (x); }", "block(comptime_block(block(_)) paren(ident:x) _)");
    try expectBlock("{ unsafe { } *p = 1; }", "block(unsafe_block(block(_)) assign(prefix(ident:p) int_lit:1) _)");
    // Elsewhere it is an operand.
    try expectBlock("{ let v = if c { 1 } else { 2 } - 1; }", "block(let(pat_bind:v _ binary(if(ident:c block(int_lit:1) block(int_lit:2)) int_lit:1)) _)");
    try expectBlock("{ comptime x + 1; }", "block(binary(prefix(ident:x) int_lit:1) _)");
}

test "assignment is a statement, not an expression" {
    // Acceptance.
    try expectFail("{ a = b = c; }", "expected `;`, found `=`");
    try expectFail("{ if a = b { } }", "expected `{`, found `=`");
    try expectFail("{ let x = (a = b); }", "expected `,`, found `=`");
    try expectFail("{ a += 1 }", "expected `;`, found `}`");
}

test "malformed statements report one error each" {
    try expectFail("{ let x = 1 }", "expected `;`, found `}`");
    try expectFail("{ a b }", "expected `;`, found `b`");
    try expectFail("{ outer: f(); }", "expected a loop, found `f`");
    try expectFail("{ outer: let x = 1; }", "expected a loop, found `let`");
    // `loop` is not a `loop_stmt`: `@simd` reads as a builtin variable.
    try expectFail("{ @simd loop { } }", "expected `;`, found `loop`");
    try expectFail("{ guard let x = y; }", "expected `else`, found `;`");
    try expectFail("{ launch 1 f(); }", "expected `gpu` or `cpu`, found `1`");
    try expectFail("{ break : ; }", "expected an identifier, found `;`");
    try expectFail("{ for x xs { } }", "expected `in`, found `xs`");
    try expectFail("{", "expected `}`, found end of file");
}

test "statement recovery keeps the rest of the block" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("- - -", try blockCodes(&buf, "{ let = 1; f(); g(1 2); { a b } h() }"));
    // The broken statements are poisoned `invalid` nodes; the others parse.
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    const src = "{ let = 1; @simd for = ; f() }";
    const tokens = try lexer.tokenize(testing.allocator, src, @fromBackingInt(0), &sink, .{ .scan_literal = literals.scan });
    var p: Parser = .init(testing.allocator, src, tokens, @fromBackingInt(0), &sink);
    defer p.deinit();
    const b = (try parseBlock(&p));
    try testing.expectEqual(.eof, p.peek(0));
    const blk = p.ast.data(b).block;
    try testing.expectEqual(2, blk.stmts.len);
    for (blk.stmts) |s| {
        try testing.expectEqual(.invalid, p.ast.kind(s));
        try testing.expect(sink.isPoisoned(.{ .file = p.file, .node = s.int() }));
    }
    try testing.expectEqual(.call, p.ast.kind(blk.tail.?));
    try testing.expectEqual(2, sink.finish().len);
}

test "statement recovery stops at the block's `}` inside an unclosed bracket" {
    try expectFail("{ let x = (1 + ; y(); }", "expected an expression, found `;`");
    try expectFail("{ let x = [1, ; y(); }", "expected an expression, found `;`");
    try expectFail("{ g(1, 2; h(); }", "expected `)`, found `;`");
    try expectFail("{ g(1 2 }", "expected `)`, found `2`");
    // Braces opened inside the broken statement still close it.
    try expectFail("{ f(|| { x y }); g(); }", "expected `;`, found `y`");
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    const src = "{ let x = (1 + ; y(); }";
    const tokens = try lexer.tokenize(testing.allocator, src, @fromBackingInt(0), &sink, .{ .scan_literal = literals.scan });
    var p: Parser = .init(testing.allocator, src, tokens, @fromBackingInt(0), &sink);
    defer p.deinit();
    const blk = p.ast.data(try parseBlock(&p)).block;
    try testing.expectEqual(.eof, p.peek(0));
    try testing.expectEqual(2, blk.stmts.len);
    try testing.expectEqual(.invalid, p.ast.kind(blk.stmts[0]));
    try testing.expectEqual(.call, p.ast.kind(blk.stmts[1]));
}

test "E0208: spawn, launch and return tail need a call" {
    // Acceptance.
    try expectCodes("{ nursery { spawn work(1); spawn w.run(2); } }", "");
    try expectCodes("{ spawn 1 + 2; }", "E0208");
    try expectCodes("{ spawn work; }", "E0208");
    try expectCodes("{ spawn f()?; }", "E0208");
    try expectCodes("{ launch gpu kernel; }", "E0208");
    try expectCodes("{ launch cpu xs over 0..n; }", "E0208");
    try expectCodes("{ return tail count(n - 1, a + 1); }", "");
    try expectCodes("{ return tail count(n - 1) + 1; }", "E0208");
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    const src = "{ spawn 1 + 2; }";
    const tokens = try lexer.tokenize(testing.allocator, src, @fromBackingInt(0), &sink, .{ .scan_literal = literals.scan });
    var p: Parser = .init(testing.allocator, src, tokens, @fromBackingInt(0), &sink);
    defer p.deinit();
    _ = try parseBlock(&p);
    const d = sink.finish()[0];
    try testing.expectEqualStrings("`spawn` needs a call expression", d.message);
    // The span covers the whole expression.
    try testing.expectEqual(8, d.primarySpan().?.start);
    try testing.expectEqual(13, d.primarySpan().?.end);
}

test "E0209: launch target is gpu or cpu" {
    // Acceptance.
    try expectCodes("{ launch gpu k(mut xs); launch cpu k(mut xs); }", "");
    try expectCodes("{ launch tpu k(mut xs); }", "E0209");
    try expectCodes("{ launch GPU k; }", "E0209 E0208");
    // `gpu`, `cpu` and `over` are identifiers elsewhere.
    try expectCodes("{ let gpu = 1; let cpu = gpu + 1; let over = cpu; }", "");
}

test "E0213: move in let, assignment, return and spawn; not while let" {
    try expectCodes("{ let a = move x; b = move y; return move z; }", "");
    try expectCodes("{ f(move x); }", "");
    try expectCodes("{ move x; }", "E0213");
    try expectCodes("{ _ = move x; }", "E0213");
    try expectCodes("{ while let a = move x { } }", "E0213");
    try expectCodes("{ if let a = move x { } }", "");
    try expectCodes("{ break move x; }", "E0213");
}

test "doc comments in a block document nothing" {
    try expectCodes("{ /// K.\n const K = 1; }", "");
    try expectCodes("{ /// x.\n let x = 1; }", "W0101");
    try expectCodes("{ f(); /// end.\n }", "W0101");
}

test "dump golden of a function body" {
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    const src = "{ outer: for x in xs { break :outer; } x = 1; x }";
    const tokens = try lexer.tokenize(testing.allocator, src, @fromBackingInt(0), &sink, .{ .scan_literal = literals.scan });
    var p: Parser = .init(testing.allocator, src, tokens, @fromBackingInt(0), &sink);
    defer p.deinit();
    const b = try parseBlock(&p);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try dump.dumpNode(&p.ast, b, &out.writer, 0);
    try testing.expectEqualStrings(
        \\(block {
        \\  stmts=[
        \\    (labeled outer
        \\      inner=(for for
        \\        pattern=(pat_bind x)
        \\        pattern2=_
        \\        iter=(ident xs)
        \\        filter=_
        \\        body=(block {
        \\          stmts=[
        \\            (break break
        \\              label=outer
        \\              value=_)]
        \\          tail=_)))
        \\    (assign =
        \\      lhs=(ident x)
        \\      rhs=(int_lit 1))]
        \\  tail=(ident x))
    , out.written());
}
