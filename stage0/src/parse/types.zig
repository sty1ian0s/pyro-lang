//! Type grammar (§3.6): every `type` form, generic arguments, the `as`-target
//! mode, and the call and builtin argument forms that types share with
//! expressions (§3.8 `call_arg`, `builtin_arg`).
//!
//! Generic arguments close through `Parser.eatGenericClose`, so `>>` and
//! `>>=` are split only here (§3.1): `Pool<Pool<T>>` closes both lists.

const std = @import("std");
const Parser = @import("Parser.zig");
const Ast = @import("../ast/Ast.zig");
const Node = Ast.Node;
const TokenKind = @import("../lex/token.zig").TokenKind;
const expr = @import("expr.zig");
const items = @import("items.zig");

/// Parses a `type`.
pub fn parseType(p: *Parser) Parser.Error!Node.Index {
    return parse(p, .normal);
}

/// Parses the right operand of `as` (§3.6 "Types after `as`"). A path in
/// tail position (also after `*`, `[]`, `mut` or `->`) takes no `<...>`, so
/// `x as u32 < y` leaves `<` to the comparison. Inside parentheses, generic
/// arguments and fn parameters types are ordinary: `x as (Handle<T>)`.
pub fn parseAsTarget(p: *Parser) Parser.Error!Node.Index {
    return parse(p, .as_target);
}

const Mode = enum { normal, as_target };

fn parse(p: *Parser, mode: Mode) Parser.Error!Node.Index {
    const t = p.tok_i;
    switch (p.peek(0)) {
        .l_bracket, .kw_soa => {
            const soa = p.eat(.kw_soa) != null;
            _ = try p.expect(.l_bracket);
            if (p.eat(.r_bracket) != null) {
                const elem = try parse(p, mode);
                return if (soa)
                    p.addNode(t, .{ .soa_slice_type = .{ .elem = elem } })
                else
                    p.addNode(t, .{ .slice_type = .{ .elem = elem } });
            }
            const len = try expr.parseExpr(p);
            _ = try p.expect(.r_bracket);
            const elem = try parse(p, mode);
            return if (soa)
                p.addNode(t, .{ .soa_array_type = .{ .len = len, .elem = elem } })
            else
                p.addNode(t, .{ .array_type = .{ .len = len, .elem = elem } });
        },
        .star => {
            _ = p.next();
            const is_const = p.eat(.kw_const) != null;
            const elem = try parse(p, mode);
            return if (is_const)
                p.addNode(t, .{ .ptr_const_type = .{ .elem = elem } })
            else
                p.addNode(t, .{ .ptr_type = .{ .elem = elem } });
        },
        .kw_mut => {
            _ = p.next();
            return p.addNode(t, .{ .mut_type = .{ .elem = try parse(p, mode) } });
        },
        .kw_fn => {
            _ = p.next();
            _ = try p.expect(.l_paren);
            const top = p.scratch.items.len;
            defer p.scratch.shrinkRetainingCapacity(top);
            try parseList(p, parseFnTypeParam, .r_paren);
            const ret = if (p.eat(.arrow) != null) try parse(p, mode) else null;
            return p.addNode(t, .{ .fn_type = .{ .params = p.scratch.items[top..], .ret = ret } });
        },
        .kw_type => return p.addNode(p.next(), .{ .type_type = .{} }),
        .kw_Self => return p.addNode(p.next(), .{ .self_type = .{} }),
        .builtin => {
            _ = p.next();
            _ = try p.expect(.l_paren);
            const top = p.scratch.items.len;
            defer p.scratch.shrinkRetainingCapacity(top);
            try parseList(p, parseBuiltinArg, .r_paren);
            return p.addNode(t, .{ .builtin_call = .{ .args = p.scratch.items[top..] } });
        },
        .l_paren => {
            _ = p.next();
            const first = try parseType(p);
            if (p.eat(.r_paren) != null) return p.addNode(t, .{ .paren = .{ .inner = first } });
            _ = try p.expect(.comma);
            const top = p.scratch.items.len;
            defer p.scratch.shrinkRetainingCapacity(top);
            try p.scratch.append(p.gpa, first);
            try parseList(p, parseType, .r_paren);
            return p.addNode(t, .{ .tuple = .{ .elems = p.scratch.items[top..] } });
        },
        .kw_struct => {
            // Extension point: items.zig (T020) owns `struct_body`; once it exports
            // `pub fn parseAnonStruct(p: *Parser) Parser.Error!Node.Index`, called at
            // `struct` and returning an `anon_struct`, this picks it up unchanged.
            if (@hasDecl(items, "parseAnonStruct")) return items.parseAnonStruct(p);
            _ = p.next();
            // shortcut: fields and members are dropped until items.zig exports
            // `parseAnonStruct`; the "anonymous struct body" test pins this.
            try p.skipGroup(.l_brace, .r_brace);
            return p.addNode(t, .{ .anon_struct = .{ .fields = &.{}, .members = &.{} } });
        },
        .ident => {
            const path = try parsePath(p);
            switch (p.peek(0)) {
                .lt => if (mode == .normal) return parseGenericArgs(p, path),
                .l_paren => {
                    const lp = p.next();
                    const top = p.scratch.items.len;
                    defer p.scratch.shrinkRetainingCapacity(top);
                    try parseList(p, parseCallArg, .r_paren);
                    return p.addNode(lp, .{ .call = .{ .callee = path, .args = p.scratch.items[top..] } });
                },
                else => {},
            }
            return path;
        },
        else => return p.failExpected("a type"),
    }
}

/// Parses `path` (`IDENT ( "." IDENT )*`) in types and struct patterns.
pub fn parsePath(p: *Parser) Parser.Error!Node.Index {
    const first = try p.expect(.ident);
    var last = first;
    while (p.peek(0) == .dot and p.peek(1) == .ident) {
        _ = p.next();
        last = p.next();
    }
    return p.addNode(first, .{ .path = .{ .last = last } });
}

/// `generic_args` after `base`; the current token is `<`.
fn parseGenericArgs(p: *Parser, base: Node.Index) Parser.Error!Node.Index {
    const lt = p.next();
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    while (true) {
        try p.scratch.append(p.gpa, try parseGenericArg(p));
        if (p.eat(.comma) == null or p.peek(0) == .gt or p.peek(0) == .shr or p.peek(0) == .shr_eq) {
            _ = try p.expectGenericClose();
            break;
        }
    }
    return p.addNode(lt, .{ .generic_inst = .{ .base = base, .args = p.scratch.items[top..] } });
}

/// `generic_arg`: a literal, `{ expr }`, or a type (a bare identifier is a
/// type path; name resolution decides if it names a constant).
fn parseGenericArg(p: *Parser) Parser.Error!Node.Index {
    if (try parseLiteral(p)) |lit| return lit;
    const lb = p.eat(.l_brace) orelse return parseType(p);
    const value = try expr.parseExpr(p);
    _ = try p.expect(.r_brace);
    return p.addNode(lb, .{ .generic_expr_arg = .{ .value = value } });
}

/// Parses `"-"? INT_LIT | CHAR_LIT | "true" | "false"` (generic arguments
/// and `literal_pattern`); null, consuming nothing, if none starts here.
/// `-INT_LIT` is a `prefix` `-` of an `int_lit`.
pub fn parseLiteral(p: *Parser) Parser.Error!?Node.Index {
    return switch (p.peek(0)) {
        .int_lit => try p.addNode(p.next(), .{ .int_lit = .{} }),
        .char_lit => try p.addNode(p.next(), .{ .char_lit = .{} }),
        .kw_true, .kw_false => try p.addNode(p.next(), .{ .bool_lit = .{} }),
        .minus => {
            const minus = p.next();
            const lit = try p.addNode(try p.expect(.int_lit), .{ .int_lit = .{} });
            return try p.addNode(minus, .{ .prefix = .{ .operand = lit } });
        },
        else => null,
    };
}

/// `fn_type_param`: a leading `mut`/`move` is a parameter mode.
fn parseFnTypeParam(p: *Parser) Parser.Error!Node.Index {
    const k = p.peek(0);
    if (k != .kw_mut and k != .kw_move) return parseType(p);
    const mode = p.next();
    return p.addNode(mode, .{ .param_mode = .{ .ty = try parseType(p) } });
}

/// Whether a `type_only` (§3.8: a type usable as a call or builtin argument)
/// starts with `k`.
pub fn startsTypeOnly(k: TokenKind) bool {
    return k == .kw_soa or k == .kw_fn or k == .kw_struct or k == .kw_type;
}

/// Parses a `builtin_arg`: `type_only | expr`.
pub fn parseBuiltinArg(p: *Parser) Parser.Error!Node.Index {
    return if (startsTypeOnly(p.peek(0))) parseType(p) else expr.parseExpr(p);
}

/// Parses a `call_arg`: `( IDENT ":" )? "mut"? ( type_only | expr )`, as a
/// `named_arg` around a `mut_arg` around the value, each layer if present.
pub fn parseCallArg(p: *Parser) Parser.Error!Node.Index {
    if (p.peek(0) == .ident and p.peek(1) == .colon) {
        const name = p.next();
        _ = p.next();
        return p.addNode(name, .{ .named_arg = .{ .value = try parseModeArg(p) } });
    }
    return parseModeArg(p);
}

fn parseModeArg(p: *Parser) Parser.Error!Node.Index {
    const m = p.eat(.kw_mut) orelse return parseBuiltinArg(p);
    return p.addNode(m, .{ .mut_arg = .{ .value = try parseBuiltinArg(p) } });
}

/// Parses `( elem ( "," elem )* ","? )? close`, pushing the elements onto
/// `p.scratch`; the caller takes them from its saved length and shrinks back.
pub fn parseList(p: *Parser, comptime elem: fn (*Parser) Parser.Error!Node.Index, close: TokenKind) Parser.Error!void {
    while (p.eat(close) == null) {
        try p.scratch.append(p.gpa, try elem(p));
        if (p.eat(.comma) == null) {
            _ = try p.expect(close);
            return;
        }
    }
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const diag = @import("../diag/diag.zig");
const lexer = @import("../lex/lexer.zig");
const literals = @import("../lex/literals.zig");
const dump = @import("../ast/dump.zig");

const ParseFn = fn (*Parser) Parser.Error!Node.Index;

/// Test helper: parses `src` with `parseFn`, which must succeed without
/// diagnostics and stop at `rest_kind`; returns the compact tree of the result
/// (see `writeTree`) in `buf`.
pub fn testTree(buf: []u8, parseFn: ParseFn, src: []const u8, rest_kind: TokenKind) ![]const u8 {
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    const tokens = try lexer.tokenize(testing.allocator, src, @fromBackingInt(0), &sink, .{ .scan_literal = literals.scan });
    var p: Parser = .init(testing.allocator, src, tokens, @fromBackingInt(0), &sink);
    defer p.deinit();
    const n = try parseFn(&p);
    try testing.expectEqual(0, sink.finish().len);
    try testing.expectEqual(rest_kind, p.peek(0));
    var w: std.Io.Writer = .fixed(buf);
    try writeTree(&p.ast, n, &w);
    return w.buffered();
}

/// Test helper: `parseFn` on `src` fails with exactly the diagnostic `message`.
pub fn testFail(parseFn: ParseFn, src: []const u8, message: []const u8) !void {
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    const tokens = try lexer.tokenize(testing.allocator, src, @fromBackingInt(0), &sink, .{ .scan_literal = literals.scan });
    var p: Parser = .init(testing.allocator, src, tokens, @fromBackingInt(0), &sink);
    defer p.deinit();
    try testing.expectError(error.ParseError, parseFn(&p));
    const ds = sink.finish();
    try testing.expectEqual(1, ds.len);
    try testing.expectEqualStrings(message, ds[0].message);
}

/// Compact tree for tests: `kind(children...)`, `kind:token` for a node
/// without children, `_` for an absent optional child.
fn writeTree(ast: *const Ast, n: Node.Index, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(@tagName(ast.kind(n)));
    var children: usize = 0;
    switch (ast.data(n)) {
        inline else => |d| inline for (@typeInfo(@TypeOf(d)).@"struct".field_names) |name| {
            const v = @field(d, name);
            switch (@TypeOf(v)) {
                Node.Index => try writeChild(ast, v, w, &children),
                ?Node.Index => if (v) |c| try writeChild(ast, c, w, &children) else try writeSep(w, &children, "_"),
                []const Node.Index => for (v) |c| try writeChild(ast, c, w, &children),
                ?[]const Node.Index => if (v) |l| {
                    for (l) |c| try writeChild(ast, c, w, &children);
                } else try writeSep(w, &children, "_"),
                else => {},
            }
        },
    }
    if (children > 0) try w.writeByte(')') else try w.print(":{s}", .{ast.tokenSlice(ast.mainToken(n))});
}

fn writeSep(w: *std.Io.Writer, children: *usize, text: []const u8) std.Io.Writer.Error!void {
    try w.writeAll(if (children.* == 0) "(" else " ");
    try w.writeAll(text);
    children.* += 1;
}

fn writeChild(ast: *const Ast, c: Node.Index, w: *std.Io.Writer, children: *usize) std.Io.Writer.Error!void {
    try writeSep(w, children, "");
    try writeTree(ast, c, w);
}

fn expectType(src: []const u8, want: []const u8) !void {
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings(want, try testTree(&buf, parseType, src, .eof));
}

test "every type form" {
    try expectType("u32", "path:u32");
    try expectType("std.mem.Allocator", "path:std");
    try expectType("[4]f32", "array_type(invalid:4 path:f32)");
    try expectType("[]u8", "slice_type(path:u8)");
    try expectType("soa[N]P", "soa_array_type(invalid:N path:P)");
    try expectType("soa[]P", "soa_slice_type(path:P)");
    try expectType("*u8", "ptr_type(path:u8)");
    try expectType("*const u8", "ptr_const_type(path:u8)");
    try expectType("mut []T", "mut_type(slice_type(path:T))");
    try expectType("fn()", "fn_type(_)");
    try expectType("fn(i32, mut T, move U, mut mut V,) -> bool", "fn_type(path:i32 param_mode(path:T) param_mode(path:U) param_mode(mut_type(path:V)) path:bool)");
    try expectType("type", "type_type:type");
    try expectType("Self", "self_type:Self");
    try expectType("@TypeOf(x, fn() -> u8)", "builtin_call(invalid:x fn_type(path:u8))");
    try expectType("@This()", "builtin_call:@This");
    try expectType("(T)", "paren(path:T)");
    try expectType("(T,)", "tuple(path:T)");
    try expectType("(A, B, C,)", "tuple(path:A path:B path:C)");
    // Call arguments are expressions (stubbed until T023).
    try expectType("Pool(Particle)", "call(path:Pool invalid:Particle)");
    try expectType("Make(n: 4, mut x, fn())", "call(path:Make named_arg(invalid:4) mut_arg(invalid:x) fn_type(_))");
}

test "anonymous struct body" {
    var buf: [128]u8 = undefined;
    const tree = try testTree(&buf, parseType, "struct { x: i32, y: i32 }", .eof);
    if (@hasDecl(items, "parseAnonStruct")) {
        // Wired: the fields survive.
        try testing.expect(std.mem.startsWith(u8, tree, "anon_struct("));
    } else {
        // shortcut (see `parse`): the body is skipped, so no fields remain.
        try testing.expectEqualStrings("anon_struct:struct", tree);
    }
}

test "generic arguments: literals, braced expressions and types" {
    try expectType("Channel<Msg, {CAP * 2}>", "generic_inst(path:Channel path:Msg generic_expr_arg(invalid:CAP))");
    try expectType("A<1, -2, 'c', true, false, B,>", "generic_inst(path:A int_lit:1 prefix(int_lit:2) char_lit:'c' bool_lit:true bool_lit:false path:B)");
    try expectType("[]Map<K, V>", "slice_type(generic_inst(path:Map path:K path:V))");
}

test "`Pool<Pool<T>>` closes through a split `>>`" {
    try expectType("Pool<Pool<T>>", "generic_inst(path:Pool generic_inst(path:Pool path:T))");
    try expectType("A<B<C<D>>>", "generic_inst(path:A generic_inst(path:B generic_inst(path:C path:D)))");
    // `>>=` closes one list and leaves `>=` for the enclosing expression.
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("generic_inst(path:A path:B)", try testTree(&buf, parseType, "A<B>>= x", .gt_eq));
}

test "`as` target: a path takes no generic arguments" {
    var buf: [128]u8 = undefined;
    // In `x as u32 < y` the type ends before `<`, so the `<` compares.
    try testing.expectEqualStrings("path:u32", try testTree(&buf, parseAsTarget, "u32 < y", .lt));
    try testing.expectEqualStrings("ptr_type(path:T)", try testTree(&buf, parseAsTarget, "*T < y", .lt));
    try testing.expectEqualStrings("paren(generic_inst(path:Handle path:T))", try testTree(&buf, parseAsTarget, "(Handle<T>) < y", .lt));
    try testing.expectEqualStrings("generic_inst(path:Handle path:T)", try testTree(&buf, parseType, "Handle<T> < y", .lt));
}

test "type stops before what follows it" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("path:T", try testTree(&buf, parseType, "T = 1", .eq));
    try testing.expectEqualStrings("path:T", try testTree(&buf, parseType, "T { }", .l_brace));
    try testing.expectEqualStrings("generic_inst(path:P path:T)", try testTree(&buf, parseType, "P<T> for", .kw_for));
}

test "malformed types report one error" {
    try testFail(parseType, "=", "expected a type, found `=`");
    try testFail(parseType, "()", "expected a type, found `)`");
    try testFail(parseType, "Vec<>", "expected a type, found `>`");
    try testFail(parseType, "Vec<u8", "expected `>`, found end of file");
    try testFail(parseType, "A<B>= 1", "expected `>`, found `>=`");
    try testFail(parseType, "A<-x>", "expected an integer literal, found `x`");
    try testFail(parseType, "(A B)", "expected `,`, found `B`");
    try testFail(parseType, "@T", "expected `(`, found end of file");
    try testFail(parseType, "fn(A B)", "expected `)`, found `B`");
}

test "golden dump of a generic type" {
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    const src = "std.Pool<T>";
    const tokens = try lexer.tokenize(testing.allocator, src, @fromBackingInt(0), &sink, .{ .scan_literal = literals.scan });
    var p: Parser = .init(testing.allocator, src, tokens, @fromBackingInt(0), &sink);
    defer p.deinit();
    const n = try parseType(&p);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try dump.dumpNode(&p.ast, n, &out.writer, 0);
    try testing.expectEqualStrings(
        \\(generic_inst <
        \\  base=(path std
        \\    last=Pool)
        \\  args=[
        \\    (path T
        \\      last=T)])
    , out.written());
}
