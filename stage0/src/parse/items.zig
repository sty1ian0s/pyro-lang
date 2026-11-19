//! Item grammar (§3.2-§3.4): items, attributes, `pub`, declarations, generic
//! parameters, parameters, struct/enum/protocol/impl/extern bodies, and the
//! checks the grammar does not express (E0201, E0204, E0205, E0206) plus
//! W0101 for doc comments that document nothing (§2.8).
//!
//! Doc comments, `pub`, `pub mut` and parameter modes are not stored in
//! nodes: they are the tokens before a declaration (see `Ast.zig`);
//! `docTokens` finds a declaration's doc comments.
//!
//! These checks report and parsing continues, so they never cause a
//! recovery. Grammar errors inside an item body propagate to the item loop,
//! whose recovery skips the whole item (one error per broken item).

const std = @import("std");
const Parser = @import("Parser.zig");
const Ast = @import("../ast/Ast.zig");
const diag = @import("../diag/diag.zig");
const types = @import("types.zig");
const expr = @import("expr.zig");
const stmt = @import("stmt.zig");

const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;
const TokenKind = @import("../lex/token.zig").TokenKind;
const max_ident_len = @import("../lex/lexer.zig").max_ident_len;
const Error = Parser.Error;

/// Where a function is declared; decides whether `;` instead of a body
/// (E0204) and a `self` parameter (E0205) are allowed.
const FnCtx = enum {
    /// Top level.
    free,
    /// In a struct body, enum or impl.
    member,
    /// In a protocol: may end in `;` (required method).
    protocol,
    /// `extern_fn`: no generics, always `;`.
    @"extern",
};

/// What a body holds before its members.
const Elems = enum { none, fields, variants };

/// Parses one `item` (§3.2), wrapped in `attributed` if it has attributes.
/// Leading doc comments are consumed and stay in the token stream.
pub fn parseItem(p: *Parser) Error!Node.Index {
    _ = try eatDocs(p);
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    try parseAttrs(p);
    const pub_tok = p.eat(.kw_pub);
    if (pub_tok) |t| switch (p.peek(0)) {
        .kw_impl, .kw_comptime => |k| try reportPub(p, t, if (k == .kw_impl) "an `impl` block" else "a `comptime` block"),
        else => {},
    };
    return wrap(p, top, try parseItemKind(p));
}

/// Consumes doc comments. Returns whether `end` follows them; if it does,
/// the doc comments document nothing and get W0101. List loops call this
/// before each element, the item loop with `end` = `eof`.
pub fn docsThenEnd(p: *Parser, end: TokenKind) std.mem.Allocator.Error!bool {
    const first = try eatDocs(p);
    if (p.peek(0) != end) return false;
    if (first) |f| try reportNothing(p, f, p.tok_i - 1, "put it directly before an item, field, variant or parameter, or use `//` for an ordinary comment");
    return true;
}

/// Consumes doc comments and returns the first of the trailing `///` run,
/// which documents what follows. A `//!` here is past the module-doc
/// position (§2.8, §3.2), so it and the `///` before it get W0101.
fn eatDocs(p: *Parser) std.mem.Allocator.Error!?TokenIndex {
    var run: ?TokenIndex = null;
    while (p.eat(.doc_comment)) |t| {
        if (run == null) run = t;
        if (std.mem.startsWith(u8, p.ast.tokenSlice(t), "//!")) {
            try reportNothing(p, run.?, t, "module docs `//!` go only at the start of the file; use `///` or `//` here");
            run = null;
        }
    }
    return run;
}

/// W0101 over doc comment tokens `[first, last]`.
fn reportNothing(p: *Parser, first: TokenIndex, last: TokenIndex, help: []const u8) std.mem.Allocator.Error!void {
    try report(p, .W0101, .{
        .file = p.file,
        .start = p.tokenSpan(first).start,
        .end = p.tokenSpan(last).end,
    }, "this doc comment documents nothing", help, &.{});
}

/// Token range `[start, end)` of the `///` doc comments of declaration `n`
/// (an item, member, field, variant or parameter, possibly `attributed`):
/// the doc comments directly before its first attribute, `pub`, parameter
/// mode or keyword. Module docs (`//!`) never belong to a declaration.
pub fn docTokens(ast: *const Ast, n: Node.Index) struct { start: TokenIndex, end: TokenIndex } {
    const kinds = ast.tokens.items(.kind);
    var first = ast.mainToken(n);
    if (ast.kind(n) != .attributed) {
        while (first > 0 and switch (kinds[first - 1]) {
            .kw_pub, .kw_mut, .kw_move, .kw_comptime => true,
            else => false,
        }) first -= 1;
    }
    var start = first;
    while (start > 0 and kinds[start - 1] == .doc_comment and
        std.mem.startsWith(u8, ast.tokenSlice(start - 1), "///")) start -= 1;
    return .{ .start = start, .end = first };
}

/// Parses `"const" IDENT ( ":" type )? "=" expr ";"` (items, members and
/// statements).
pub fn parseConst(p: *Parser) Error!Node.Index {
    const kw = try p.expect(.kw_const);
    _ = try p.expect(.ident);
    const ty = if (p.eat(.colon) != null) try types.parseType(p) else null;
    _ = try p.expect(.eq);
    const value = try expr.parseExpr(p);
    _ = try p.expect(.semicolon);
    return p.addNode(kw, .{ .const_decl = .{ .ty = ty, .value = value } });
}

/// Parses `"struct" struct_body` (anonymous struct type or comptime
/// expression) into `anon_struct`.
pub fn parseAnonStruct(p: *Parser) Error!Node.Index {
    const kw = try p.expect(.kw_struct);
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    const mid = try parseBody(p, .member, .fields);
    return p.addNode(kw, .{ .anon_struct = .{ .fields = p.scratch.items[top..mid], .members = p.scratch.items[mid..] } });
}

fn parseItemKind(p: *Parser) Error!Node.Index {
    const kw = p.tok_i;
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    switch (p.peek(0)) {
        .kw_use => return parseUse(p),
        .kw_const => return parseConst(p),
        .kw_fn => return parseFn(p, .free),
        .kw_type => {
            _ = p.next();
            _ = try p.expect(.ident);
            const generics = try parseGenerics(p, top);
            _ = try p.expect(.eq);
            const distinct = p.eat(.kw_distinct) != null;
            const ty = try types.parseType(p);
            _ = try p.expect(.semicolon);
            return if (distinct)
                p.addNode(kw, .{ .type_distinct = .{ .generics = generics.get(p), .ty = ty } })
            else
                p.addNode(kw, .{ .type_alias = .{ .generics = generics.get(p), .ty = ty } });
        },
        .kw_struct => {
            _ = p.next();
            _ = try p.expect(.ident);
            const generics = try parseGenerics(p, top);
            const mid = try parseBody(p, .member, .fields);
            return p.addNode(kw, .{ .struct_decl = .{
                .generics = generics.get(p),
                .fields = p.scratch.items[generics.end..mid],
                .members = p.scratch.items[mid..],
            } });
        },
        .kw_enum => {
            _ = p.next();
            _ = try p.expect(.ident);
            const generics = try parseGenerics(p, top);
            const backing = if (p.eat(.colon) != null) try types.parseType(p) else null;
            const mid = try parseBody(p, .member, .variants);
            return p.addNode(kw, .{ .enum_decl = .{
                .generics = generics.get(p),
                .backing = backing,
                .variants = p.scratch.items[generics.end..mid],
                .members = p.scratch.items[mid..],
            } });
        },
        .kw_protocol => {
            _ = p.next();
            _ = try p.expect(.ident);
            const generics = try parseGenerics(p, top);
            _ = try parseBody(p, .protocol, .none);
            return p.addNode(kw, .{ .protocol_decl = .{ .generics = generics.get(p), .members = p.scratch.items[generics.end..] } });
        },
        .kw_impl => {
            _ = p.next();
            const generics = try parseGenerics(p, top);
            const protocol = try types.parseType(p);
            _ = try p.expect(.kw_for);
            const target = try types.parseType(p);
            _ = try parseBody(p, .member, .none);
            return p.addNode(kw, .{ .impl_decl = .{
                .generics = generics.get(p),
                .protocol = protocol,
                .target = target,
                .members = p.scratch.items[generics.end..],
            } });
        },
        .kw_extern => {
            _ = p.next();
            _ = try p.expect(.string_lit);
            _ = try parseBody(p, .@"extern", .none);
            return p.addNode(kw, .{ .extern_block = .{ .fns = p.scratch.items[top..] } });
        },
        .kw_comptime => {
            _ = p.next();
            return p.addNode(kw, .{ .comptime_block = .{ .body = try stmt.parseBlock(p) } });
        },
        else => return p.failExpected("an item"),
    }
}

/// `"use" path ( "as" IDENT | ".{" use_item,+ "}" )? ";"`.
fn parseUse(p: *Parser) Error!Node.Index {
    const kw = try p.expect(.kw_use);
    const path = try parsePath(p);
    if (p.eat(.dot_l_brace) != null) {
        const top = p.scratch.items.len;
        defer p.scratch.shrinkRetainingCapacity(top);
        try commaList(p, .r_brace, parseUseItem);
        _ = try p.expect(.r_brace);
        _ = try p.expect(.semicolon);
        return p.addNode(kw, .{ .use_list = .{ .path = path, .items = p.scratch.items[top..] } });
    }
    const alias = if (p.eat(.kw_as) != null) try p.expect(.ident) else null;
    _ = try p.expect(.semicolon);
    return p.addNode(kw, .{ .use = .{ .path = path, .alias = alias } });
}

fn parseUseItem(p: *Parser) Error!Node.Index {
    const name = try p.expect(.ident);
    const alias = if (p.eat(.kw_as) != null) try p.expect(.ident) else null;
    return p.addNode(name, .{ .use_item = .{ .alias = alias } });
}

/// `IDENT ( "." IDENT )*`. Stops before `.{`, which is one token.
fn parsePath(p: *Parser) Error!Node.Index {
    const first = try p.expect(.ident);
    var last = first;
    while (p.peek(0) == .dot) {
        _ = p.next();
        last = try p.expect(.ident);
    }
    return p.addNode(first, .{ .path = .{ .last = last } });
}

// ---------------------------------------------------------------------------
// Attributes

/// Parses `attribute*`, pushing the `attribute` nodes onto `scratch`.
fn parseAttrs(p: *Parser) Error!void {
    while (p.eat(.builtin)) |t| {
        const top = p.scratch.items.len; // callers shrink on error
        const has_args = p.eat(.l_paren) != null;
        if (has_args) {
            if (p.peek(0) != .r_paren) try commaList(p, .r_paren, parseAttrArg);
            _ = try p.expect(.r_paren);
        }
        const node = try p.addNode(t, .{ .attribute = .{ .args = if (has_args) p.scratch.items[top..] else null } });
        p.scratch.shrinkRetainingCapacity(top);
        try p.scratch.append(p.gpa, node);
    }
}

/// `( IDENT ":" )? expr`.
fn parseAttrArg(p: *Parser) Error!Node.Index {
    if (p.peek(0) == .ident and p.peek(1) == .colon) {
        const name = p.next();
        _ = p.next();
        return p.addNode(name, .{ .named_arg = .{ .value = try expr.parseExpr(p) } });
    }
    return expr.parseExpr(p);
}

/// Wraps `inner` in `attributed` if attributes were pushed onto `scratch`
/// above `top`, and pops them.
fn wrap(p: *Parser, top: usize, inner: Node.Index) Error!Node.Index {
    defer p.scratch.shrinkRetainingCapacity(top);
    const attrs = p.scratch.items[top..];
    if (attrs.len == 0) return inner;
    return p.addNode(p.ast.mainToken(attrs[0]), .{ .attributed = .{ .attrs = attrs, .inner = inner } });
}

// ---------------------------------------------------------------------------
// Lists

/// Parses `elem ( "," elem )* ","?` before `close` (not consumed), pushing
/// the elements onto `scratch`.
fn commaList(p: *Parser, close: TokenKind, comptime elem: fn (*Parser) Error!Node.Index) Error!void {
    while (true) {
        try p.scratch.append(p.gpa, try elem(p));
        if (p.eat(.comma) == null or p.peek(0) == close) return;
    }
}

/// Generic parameters pushed onto `scratch` from `top` to `end`.
const Generics = struct {
    top: usize,
    end: usize,
    present: bool,

    fn get(g: Generics, p: *Parser) ?[]const Node.Index {
        return if (g.present) p.scratch.items[g.top..g.end] else null;
    }
};

/// Parses `generic_params?`, pushing `generic_param` nodes onto `scratch`,
/// which must be at `top`.
fn parseGenerics(p: *Parser, top: usize) Error!Generics {
    std.debug.assert(p.scratch.items.len == top);
    const present = p.eat(.lt) != null;
    if (present) while (true) {
        const name = try p.expect(.ident);
        const bounds = p.scratch.items.len;
        if (p.eat(.colon) != null) {
            try p.scratch.append(p.gpa, try types.parseType(p));
            while (p.eat(.plus) != null) try p.scratch.append(p.gpa, try types.parseType(p));
        }
        const param = try p.addNode(name, .{ .generic_param = .{ .bounds = p.scratch.items[bounds..] } });
        p.scratch.shrinkRetainingCapacity(bounds);
        try p.scratch.append(p.gpa, param);
        if (p.eat(.comma) == null) {
            _ = try p.expectGenericClose();
            break;
        }
        if (p.eatGenericClose() != null) break;
    };
    return .{ .top = top, .end = p.scratch.items.len, .present = present };
}

// ---------------------------------------------------------------------------
// Bodies

/// Parses `"{" elem_list? member* "}"`, pushing the elements (fields or
/// variants) and then the members onto `scratch`; returns where the members
/// start. Members of `ctx` are `fn_decl`/`const_decl` (only `fn_decl` for
/// `extern`), each possibly `attributed`.
fn parseBody(p: *Parser, ctx: FnCtx, comptime elems: Elems) Error!usize {
    _ = try p.expect(.l_brace);
    var members: ?usize = null;
    var missing_comma = false;
    while (!try docsThenEnd(p, .r_brace)) {
        const top = p.scratch.items.len;
        try parseAttrs(p);
        const is_member = elems == .none or startsMember(p);
        if (is_member) {
            if (members == null) members = top;
        } else if (members != null) {
            if (missing_comma) return p.failExpected("`,` or `}`");
            return p.fail(if (elems == .fields)
                "a field must come before the first function or constant"
            else
                "a variant must come before the first function or constant");
        }
        const inner = if (is_member) try parseMember(p, ctx) else switch (elems) {
            .fields => try parseField(p),
            .variants => try parseVariant(p),
            .none => unreachable,
        };
        const node = try wrap(p, top, inner);
        try p.scratch.append(p.gpa, node);
        if (!is_member and p.eat(.comma) == null) {
            members = p.scratch.items.len;
            missing_comma = true;
        }
    }
    _ = try p.expect(.r_brace);
    return members orelse p.scratch.items.len;
}

/// Whether a member (`pub`? `fn`/`const`) starts here rather than a field or
/// variant. `pub` needs the second token (§3.1): `pub fn` vs `pub mut x`.
fn startsMember(p: *const Parser) bool {
    const k = if (p.peek(0) == .kw_pub) p.peek(1) else p.peek(0);
    return k == .kw_fn or k == .kw_const;
}

/// `"pub"? ( fn_decl | const_decl )`, or `extern_fn` in an extern block.
fn parseMember(p: *Parser, ctx: FnCtx) Error!Node.Index {
    _ = p.eat(.kw_pub);
    return switch (p.peek(0)) {
        .kw_fn => parseFn(p, ctx),
        .kw_const => if (ctx == .@"extern") p.failExpected("`fn`") else parseConst(p),
        else => p.failExpected(if (ctx == .@"extern") "`fn`" else "`fn` or `const`"),
    };
}

/// `( "pub" "mut"? )? IDENT ":" type ( "=" expr )?`.
fn parseField(p: *Parser) Error!Node.Index {
    if (p.eat(.kw_pub) != null) _ = p.eat(.kw_mut);
    const name = try p.expect(.ident);
    _ = try p.expect(.colon);
    const ty = try types.parseType(p);
    const default = if (p.eat(.eq) != null) try expr.parseExpr(p) else null;
    return p.addNode(name, .{ .field_decl = .{ .ty = ty, .default = default } });
}

/// `IDENT ( "(" type,+ ")" )? ( "=" expr )?`.
fn parseVariant(p: *Parser) Error!Node.Index {
    const name = try p.expect(.ident);
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    const has_payload = p.eat(.l_paren) != null;
    if (has_payload) {
        try commaList(p, .r_paren, types.parseType);
        _ = try p.expect(.r_paren);
    }
    const value = if (p.eat(.eq) != null) try expr.parseExpr(p) else null;
    return p.addNode(name, .{ .variant_decl = .{
        .payload = if (has_payload) p.scratch.items[top..] else null,
        .value = value,
    } });
}

// ---------------------------------------------------------------------------
// Functions

/// `"fn" IDENT generic_params? "(" param_list? ")" fn_ret? ( block | ";" )`;
/// for `extern` no generics and always `;`.
fn parseFn(p: *Parser, ctx: FnCtx) Error!Node.Index {
    const kw = try p.expect(.kw_fn);
    const name = try p.expect(.ident);
    const top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(top);
    const generics: Generics = if (ctx == .@"extern")
        .{ .top = top, .end = top, .present = false }
    else
        try parseGenerics(p, top);
    _ = try p.expect(.l_paren);
    try parseParams(p, ctx);
    _ = try p.expect(.r_paren);
    const ret = if (p.eat(.arrow) != null) try types.parseType(p) else null;
    const body = switch (p.peek(0)) {
        .l_brace => if (ctx == .@"extern") return p.failExpected("`;`") else try stmt.parseBlock(p),
        .semicolon => blk: {
            _ = p.next();
            if (ctx == .free or ctx == .member) {
                var buf: [320]u8 = undefined;
                try report(p, .E0204, p.tokenSpan(name), bufPrint(&buf, "function `{s}` has no body", .{identName(p, name)}), "add a body `{ ... }`; only required methods in a `protocol` end in `;`", &.{});
            }
            break :blk null;
        },
        else => return p.failExpected(if (ctx == .@"extern") "`;`" else "`{` or `;`"),
    };
    return p.addNode(kw, .{ .fn_decl = .{
        .generics = generics.get(p),
        .params = p.scratch.items[generics.end..],
        .ret = ret,
        .body = body,
    } });
}

/// `param ( "," param )* ","?` up to `)`, pushing `param` nodes (possibly
/// `attributed`) onto `scratch`. Reports E0205 and E0206.
fn parseParams(p: *Parser, ctx: FnCtx) Error!void {
    var first = true;
    var first_default: ?TokenIndex = null;
    while (!try docsThenEnd(p, .r_paren)) : (first = false) {
        const top = p.scratch.items.len;
        try parseAttrs(p);
        const param = try parseParam(p, ctx, first);
        const name = p.ast.mainToken(param);
        if (p.ast.data(param).param.default != null) {
            if (first_default == null) first_default = name;
        } else if (first_default) |d| {
            var buf: [640]u8 = undefined;
            var help: [640]u8 = undefined;
            try report(
                p,
                .E0206,
                p.tokenSpan(name),
                bufPrint(&buf, "parameter `{s}` has no default value, but comes after `{s}`, which has one", .{ identName(p, name), identName(p, d) }),
                bufPrint(&help, "give `{s}` a default value, or move it before `{s}`", .{ identName(p, name), identName(p, d) }),
                &.{},
            );
        }
        try p.scratch.append(p.gpa, try wrap(p, top, param));
        if (p.eat(.comma) == null) break;
    }
}

/// `param_mode? ( "self" | IDENT ":" type ) ( "=" expr )?`; the mode stays
/// the token before the name.
fn parseParam(p: *Parser, ctx: FnCtx, first: bool) Error!Node.Index {
    const comptime_mode = p.peek(0) == .kw_comptime;
    switch (p.peek(0)) {
        .kw_comptime, .kw_mut, .kw_move => _ = p.next(),
        else => {},
    }
    var ty: ?Node.Index = null;
    const name = if (p.eat(.kw_self)) |s| blk: {
        const problem: ?[]const u8 = if (ctx != .member and ctx != .protocol)
            "`self` is only allowed in functions declared inside a `struct`, `enum`, `protocol` or `impl`"
        else if (!first)
            "`self` must be the first parameter"
        else if (comptime_mode)
            "`self` cannot be `comptime`"
        else
            null;
        if (problem) |m| try report(p, .E0205, p.tokenSpan(s), m, "use `self`, `mut self` or `move self` only as the first parameter of a method", &.{});
        break :blk s;
    } else blk: {
        const id = try p.expect(.ident);
        _ = try p.expect(.colon);
        ty = try types.parseType(p);
        break :blk id;
    };
    const default = if (p.eat(.eq) != null) try expr.parseExpr(p) else null;
    return p.addNode(name, .{ .param = .{ .ty = ty, .default = default } });
}

// ---------------------------------------------------------------------------
// Diagnostics

fn report(p: *Parser, code: diag.DiagCode, span: diag.Span, message: []const u8, help: []const u8, fixes: []const diag.Fix) std.mem.Allocator.Error!void {
    try p.sink.emit(.{
        .code = code,
        .severity = .of(code),
        .message = message,
        .spans = &.{.{ .span = span, .primary = true }},
        .help = &.{help},
        .fixes = fixes,
    });
}

/// E0201 at `pub` token `t`, with a fix deleting it.
fn reportPub(p: *Parser, t: TokenIndex, what: []const u8) std.mem.Allocator.Error!void {
    var buf: [96]u8 = undefined;
    const span = p.tokenSpan(t);
    const del: diag.Span = .{ .file = p.file, .start = span.start, .end = p.tokenSpan(t + 1).start };
    try report(p, .E0201, span, bufPrint(&buf, "`pub` is not allowed on {s}", .{what}), "remove `pub`", &.{.{ .span = del, .replacement = "" }});
}

/// Identifier token `t` cut to `max_ident_len` bytes at a UTF-8 boundary:
/// longer ones got E0105 but still reach the parser, and message buffers
/// are sized for this bound.
fn identName(p: *Parser, t: TokenIndex) []const u8 {
    const s = p.ast.tokenSlice(t);
    if (s.len <= max_ident_len) return s;
    var n: usize = max_ident_len;
    while (s[n] & 0xC0 == 0x80) n -= 1;
    return s[0..n];
}

/// `std.fmt.bufPrint` for messages whose buffers fit their longest input
/// (names go through `identName`).
fn bufPrint(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch unreachable;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const lexer = @import("../lex/lexer.zig");
const literals = @import("../lex/literals.zig");
const dump = @import("../ast/dump.zig");

const test_file: diag.FileId = @fromBackingInt(@intCast(0));

/// `src` parsed with the sequential lexer, plus its diagnostics.
const Parsed = struct {
    ast: Ast,
    sink: diag.Sink,

    fn init(r: *Parsed, src: []const u8) !void {
        r.sink = .init(testing.allocator, testing.io);
        const tokens = try lexer.tokenize(testing.allocator, src, test_file, &r.sink, .{ .scan_literal = literals.scan });
        r.ast = try Parser.parse(testing.allocator, src, tokens, test_file, &r.sink);
    }

    fn deinit(r: *Parsed) void {
        r.ast.deinit(testing.allocator);
        r.sink.deinit();
    }

    fn items(r: *const Parsed) []const Node.Index {
        return r.ast.data(.from(0)).root.items;
    }
};

/// Parses `src` without diagnostics and compares the dump of its items.
fn expectDump(src: []const u8, expected: []const u8) !void {
    var r: Parsed = undefined;
    try r.init(src);
    defer r.deinit();
    try testing.expectEqual(0, r.sink.finish().len);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    for (r.items()) |n| {
        try dump.dumpNode(&r.ast, n, &out.writer, 0);
        try out.writer.writeByte('\n');
    }
    try testing.expectEqualStrings(expected, out.written());
}

const Expected = struct { code: ?diag.DiagCode, line: u32 };

/// Parses `src` and compares its diagnostics' codes and 1-based lines.
fn expectDiags(src: []const u8, expected: []const Expected) !void {
    var r: Parsed = undefined;
    try r.init(src);
    defer r.deinit();
    const ds = r.sink.finish();
    var got: std.ArrayList(Expected) = .empty;
    defer got.deinit(testing.allocator);
    for (ds) |d| {
        const at = d.primarySpan().?.start;
        const line: u32 = @intCast(std.mem.count(u8, src[0..at], "\n") + 1);
        try got.append(testing.allocator, .{ .code = d.code, .line = line });
    }
    try testing.expectEqualSlices(Expected, expected, got.items);
}

// Goldens print blocks as the T025 stub leaves them: empty.

test "golden: use" {
    try expectDump(
        \\use std.math;
        \\pub use std.math as m;
        \\use physics.rigid_body.{RigidBody, step as physics_step,};
    ,
        \\(use use
        \\  path=(path std
        \\    last=math)
        \\  alias=_)
        \\(use pub use
        \\  path=(path std
        \\    last=math)
        \\  alias=m)
        \\(use_list use
        \\  path=(path physics
        \\    last=rigid_body)
        \\  items=[
        \\    (use_item RigidBody
        \\      alias=_)
        \\    (use_item step
        \\      alias=physics_step)])
        \\
    );
}

test "golden: const and type" {
    try expectDump(
        \\pub const N: u32 = 4;
        \\const M = N;
        \\type Pair<A, B: Eq + Show,> = (A, B);
        \\pub type Id = distinct u64;
    ,
        \\(const_decl pub const N
        \\  ty=(path u32
        \\    last=u32)
        \\  value=(int_lit 4))
        \\(const_decl const M
        \\  ty=_
        \\  value=(ident N))
        \\(type_alias type Pair
        \\  generics=[
        \\    (generic_param A
        \\      bounds=[])
        \\    (generic_param B
        \\      bounds=[
        \\        (path Eq
        \\          last=Eq)
        \\        (path Show
        \\          last=Show)])]
        \\  ty=(tuple (
        \\    elems=[
        \\      (path A
        \\        last=A)
        \\      (path B
        \\        last=B)]))
        \\(type_distinct pub type Id
        \\  generics=_
        \\  ty=(path u64
        \\    last=u64))
        \\
    );
}

test "golden: fn with attributes, generics, modes and defaults" {
    try expectDump(
        \\/// Doc.
        \\@inline @deprecated(since: "1.2", "use g") pub fn f<T: A<B<C>>>(
        \\    comptime n: u32,
        \\    /// Doc.
        \\    @unused mut a: T,
        \\    move b: T = d,
        \\) -> T { a }
        \\fn g() {}
    ,
        \\(attributed @inline
        \\  attrs=[
        \\    (attribute @inline
        \\      args=_)
        \\    (attribute @deprecated
        \\      args=[
        \\        (named_arg since
        \\          value=(string_lit "1.2"))
        \\        (string_lit "use g")])]
        \\  inner=(fn_decl pub fn f
        \\    generics=[
        \\      (generic_param T
        \\        bounds=[
        \\          (generic_inst <
        \\            base=(path A
        \\              last=A)
        \\            args=[
        \\              (generic_inst <
        \\                base=(path B
        \\                  last=B)
        \\                args=[
        \\                  (path C
        \\                    last=C)])])])]
        \\    params=[
        \\      (param comptime n
        \\        ty=(path u32
        \\          last=u32)
        \\        default=_)
        \\      (attributed @unused
        \\        attrs=[
        \\          (attribute @unused
        \\            args=_)]
        \\        inner=(param mut a
        \\          ty=(path T
        \\            last=T)
        \\          default=_))
        \\      (param move b
        \\        ty=(path T
        \\          last=T)
        \\        default=(ident d))]
        \\    ret=(path T
        \\      last=T)
        \\    body=(block {
        \\      stmts=[]
        \\      tail=_)))
        \\(fn_decl fn g
        \\  generics=_
        \\  params=[]
        \\  ret=_
        \\  body=(block {
        \\    stmts=[]
        \\    tail=_))
        \\
    );
}

test "golden: struct" {
    try expectDump(
        \\struct P<T> {
        \\    /// Doc.
        \\    pub mut x: T = 0,
        \\    pub y: T,
        \\    @align(4) z: u8,
        \\
        \\    pub fn get(self) -> T { self.x }
        \\    @inline fn set(mut self, v: T) {}
        \\    pub const K: u32 = 1;
        \\}
        \\struct E {}
    ,
        \\(struct_decl struct P
        \\  generics=[
        \\    (generic_param T
        \\      bounds=[])]
        \\  fields=[
        \\    (field_decl pub mut x
        \\      ty=(path T
        \\        last=T)
        \\      default=(int_lit 0))
        \\    (field_decl pub y
        \\      ty=(path T
        \\        last=T)
        \\      default=_)
        \\    (attributed @align
        \\      attrs=[
        \\        (attribute @align
        \\          args=[
        \\            (int_lit 4)])]
        \\      inner=(field_decl z
        \\        ty=(path u8
        \\          last=u8)
        \\        default=_))]
        \\  members=[
        \\    (fn_decl pub fn get
        \\      generics=_
        \\      params=[
        \\        (param self
        \\          ty=_
        \\          default=_)]
        \\      ret=(path T
        \\        last=T)
        \\      body=(block {
        \\        stmts=[]
        \\        tail=_))
        \\    (attributed @inline
        \\      attrs=[
        \\        (attribute @inline
        \\          args=_)]
        \\      inner=(fn_decl fn set
        \\        generics=_
        \\        params=[
        \\          (param mut self
        \\            ty=_
        \\            default=_)
        \\          (param v
        \\            ty=(path T
        \\              last=T)
        \\            default=_)]
        \\        ret=_
        \\        body=(block {
        \\          stmts=[]
        \\          tail=_)))
        \\    (const_decl pub const K
        \\      ty=(path u32
        \\        last=u32)
        \\      value=(int_lit 1))])
        \\(struct_decl struct E
        \\  generics=_
        \\  fields=[]
        \\  members=[])
        \\
    );
}

test "golden: enum" {
    try expectDump(
        \\enum Shape<T>: u8 {
        \\    Circle(T),
        \\    Rect(T, T,) = 2,
        \\    @deprecated None
        \\    fn area(self) -> T { 0 }
        \\}
        \\enum Dir { up, down, }
    ,
        \\(enum_decl enum Shape
        \\  generics=[
        \\    (generic_param T
        \\      bounds=[])]
        \\  backing=(path u8
        \\    last=u8)
        \\  variants=[
        \\    (variant_decl Circle
        \\      payload=[
        \\        (path T
        \\          last=T)]
        \\      value=_)
        \\    (variant_decl Rect
        \\      payload=[
        \\        (path T
        \\          last=T)
        \\        (path T
        \\          last=T)]
        \\      value=(int_lit 2))
        \\    (attributed @deprecated
        \\      attrs=[
        \\        (attribute @deprecated
        \\          args=_)]
        \\      inner=(variant_decl None
        \\        payload=_
        \\        value=_))]
        \\  members=[
        \\    (fn_decl fn area
        \\      generics=_
        \\      params=[
        \\        (param self
        \\          ty=_
        \\          default=_)]
        \\      ret=(path T
        \\        last=T)
        \\      body=(block {
        \\        stmts=[]
        \\        tail=_))])
        \\(enum_decl enum Dir
        \\  generics=_
        \\  backing=_
        \\  variants=[
        \\    (variant_decl up
        \\      payload=_
        \\      value=_)
        \\    (variant_decl down
        \\      payload=_
        \\      value=_)]
        \\  members=[])
        \\
    );
}

test "golden: protocol and impl" {
    try expectDump(
        \\protocol Show<T> {
        \\    fn show(self) -> String;
        \\    fn name(self) -> String { "" }
        \\    const K: u32 = 1;
        \\}
        \\impl<T: Show> Show for P<T> {
        \\    pub fn show(self) -> String { "" }
        \\}
    ,
        \\(protocol_decl protocol Show
        \\  generics=[
        \\    (generic_param T
        \\      bounds=[])]
        \\  members=[
        \\    (fn_decl fn show
        \\      generics=_
        \\      params=[
        \\        (param self
        \\          ty=_
        \\          default=_)]
        \\      ret=(path String
        \\        last=String)
        \\      body=_)
        \\    (fn_decl fn name
        \\      generics=_
        \\      params=[
        \\        (param self
        \\          ty=_
        \\          default=_)]
        \\      ret=(path String
        \\        last=String)
        \\      body=(block {
        \\        stmts=[]
        \\        tail=_))
        \\    (const_decl const K
        \\      ty=(path u32
        \\        last=u32)
        \\      value=(int_lit 1))])
        \\(impl_decl impl
        \\  generics=[
        \\    (generic_param T
        \\      bounds=[
        \\        (path Show
        \\          last=Show)])]
        \\  protocol=(path Show
        \\    last=Show)
        \\  target=(generic_inst <
        \\    base=(path P
        \\      last=P)
        \\    args=[
        \\      (path T
        \\        last=T)])
        \\  members=[
        \\    (fn_decl pub fn show
        \\      generics=_
        \\      params=[
        \\        (param self
        \\          ty=_
        \\          default=_)]
        \\      ret=(path String
        \\        last=String)
        \\      body=(block {
        \\        stmts=[]
        \\        tail=_))])
        \\
    );
}

test "golden: extern and comptime" {
    try expectDump(
        \\pub extern "C" {
        \\    fn puts(s: *const u8) -> i32;
        \\    @link_name("abs") pub fn abs(x: c_int) -> c_int;
        \\}
        \\comptime { assert(N > 0); }
    ,
        \\(extern_block pub extern "C"
        \\  fns=[
        \\    (fn_decl fn puts
        \\      generics=_
        \\      params=[
        \\        (param s
        \\          ty=(ptr_const_type *
        \\            elem=(path u8
        \\              last=u8))
        \\          default=_)]
        \\      ret=(path i32
        \\        last=i32)
        \\      body=_)
        \\    (attributed @link_name
        \\      attrs=[
        \\        (attribute @link_name
        \\          args=[
        \\            (string_lit "abs")])]
        \\      inner=(fn_decl pub fn abs
        \\        generics=_
        \\        params=[
        \\          (param x
        \\            ty=(path c_int
        \\              last=c_int)
        \\            default=_)]
        \\        ret=(path c_int
        \\          last=c_int)
        \\        body=_))])
        \\(comptime_block comptime
        \\  body=(block {
        \\    stmts=[]
        \\    tail=_))
        \\
    );
}

test "E0201: `pub` on impl and comptime, with a fix" {
    try expectDiags(
        \\struct M { v: f64 }
        \\protocol Show { fn show(self); }
        \\pub impl Show for M {
        \\    fn show(self) {}
        \\}
        \\pub comptime {
        \\    const K = 1;
        \\}
    , &.{ .{ .code = .E0201, .line = 3 }, .{ .code = .E0201, .line = 6 } });
    var r: Parsed = undefined;
    try r.init("pub  comptime {}");
    defer r.deinit();
    const d = r.sink.finish()[0];
    try testing.expectEqualStrings("`pub` is not allowed on a `comptime` block", d.message);
    try testing.expectEqualDeep(diag.Fix{ .span = .{ .file = test_file, .start = 0, .end = 5 }, .replacement = "" }, d.fixes[0]);
    try testing.expectEqual(.comptime_block, r.ast.kind(r.items()[0]));
}

test "E0201: `pub` accepted on every other item, member and field" {
    try expectDiags(
        \\pub use std.math;
        \\pub const LIMIT: u32 = 10;
        \\pub type Meters = distinct f64;
        \\pub fn area(w: f64, h: f64) -> f64 { w * h }
        \\pub struct Point {
        \\    pub x: i32,
        \\    pub mut y: i32,
        \\    pub fn origin() -> Point { Point { x: 0, y: 0 } }
        \\    pub const ZERO: i32 = 0;
        \\}
        \\pub enum Dir { up, down }
        \\pub protocol Show { fn show(self); }
        \\pub extern "C" {
        \\    pub fn abs(x: c_int) -> c_int;
        \\}
        \\impl Show for Point { fn show(self) {} }
        \\comptime { const K = 1; }
    , &.{});
}

test "E0204: `;` instead of a body outside a protocol" {
    try expectDiags(
        \\fn missing_body(x: i32) -> i32;
        \\struct S {
        \\    x: i32,
        \\    fn no_body(self);
        \\}
        \\enum E {
        \\    a,
        \\    fn no_body(self) -> u32;
        \\}
        \\protocol P { fn required(self); }
        \\impl P for S {
        \\    fn required(self);
        \\}
        \\extern "C" { fn abs(x: c_int) -> c_int; }
    , &.{
        .{ .code = .E0204, .line = 1 }, .{ .code = .E0204, .line = 4 },
        .{ .code = .E0204, .line = 8 }, .{ .code = .E0204, .line = 12 },
    });
    // An extern function cannot have a body: a grammar error.
    try expectDiags("extern \"C\" { fn f() {} }", &.{.{ .code = null, .line = 1 }});
}

test "E0205: misplaced `self`" {
    try expectDiags(
        \\fn free(self) {}
        \\struct S {
        \\    x: i32,
        \\    fn second(x: i32, self) {}
        \\    fn ct(comptime self) {}
        \\    fn ok(self) {}
        \\    fn ok_mut(mut self) {}
        \\    fn ok_move(move self) {}
        \\}
        \\protocol P {
        \\    fn late(n: u32, self);
        \\    fn ok(self);
        \\}
        \\enum E { a, fn ok(self) {} }
        \\impl P for S { fn ok(self) {} }
        \\extern "C" { fn e(self); }
    , &.{
        .{ .code = .E0205, .line = 1 },  .{ .code = .E0205, .line = 4 },
        .{ .code = .E0205, .line = 5 },  .{ .code = .E0205, .line = 11 },
        .{ .code = .E0205, .line = 16 },
    });
}

test "E0206: defaults only on trailing parameters" {
    try expectDiags(
        \\fn f(a: i32 = 1, b: i32) {}
        \\struct S {
        \\    x: f32,
        \\    fn m(self, scale: f32 = 1.0, offset: f32) {}
        \\}
        \\fn ok(a: i32, b: i32 = 1, c: bool = false) {}
        \\fn all_default(a: i32 = 0, b: i32 = 0,) {}
    , &.{ .{ .code = .E0206, .line = 1 }, .{ .code = .E0206, .line = 4 } });
}

test "E0204 and E0206 name identifiers longer than 255 bytes" {
    const long: [400]u8 = @splat('a');
    try expectDiags("fn " ++ long ++ "();", &.{ .{ .code = .E0105, .line = 1 }, .{ .code = .E0204, .line = 1 } });
    try expectDiags(
        "fn f(" ++ long ++ "x: i32 = 0, " ++ long ++ "y: i32) {}",
        &.{ .{ .code = .E0105, .line = 1 }, .{ .code = .E0105, .line = 1 }, .{ .code = .E0206, .line = 1 } },
    );
}

test "W0101: module doc comment after the first item" {
    try expectDiags(
        \\//! Module doc.
        \\fn f() {}
        \\/// Cut off by the module doc below.
        \\//! Too late.
        \\fn g() {}
        \\struct S {
        \\    //! In a body.
        \\    x: i32,
        \\}
        \\fn h(
        \\    //! In parameters.
        \\    a: i32,
        \\) {}
    , &.{
        .{ .code = .W0101, .line = 3 },  .{ .code = .W0101, .line = 7 },
        .{ .code = .W0101, .line = 11 },
    });
}

test "W0101: doc comment documenting nothing" {
    try expectDiags(
        \\struct Point {
        \\    x: i32,
        \\    /// Nothing follows inside the struct.
        \\}
        \\fn f(a: i32,
        \\    /// Nothing follows inside the parameters.
        \\) {}
        \\/// Nothing follows at the end of the file.
        \\/// Second line.
    , &.{
        .{ .code = .W0101, .line = 3 }, .{ .code = .W0101, .line = 6 },
        .{ .code = .W0101, .line = 8 },
    });
    // Docs on items, fields, variants, members and parameters are fine.
    try expectDiags(
        \\//! Module doc.
        \\/// Struct.
        \\struct Point {
        \\    /// Field.
        \\    x: i32,
        \\}
        \\/// Enum.
        \\enum Color {
        \\    /// Variant.
        \\    Red,
        \\    /// Member.
        \\    fn f() {}
        \\}
        \\protocol Shape {
        \\    fn area(
        \\        /// Parameter.
        \\        w: u32,
        \\    ) -> u32;
        \\}
        \\//// Four slashes: an ordinary comment.
    , &.{});
}

test "`pub fn` is a member, `pub mut x: T` and `pub x: T` are fields" {
    var r: Parsed = undefined;
    try r.init("struct S { pub mut x: T, pub y: T, pub fn f() {} pub const C = 1; }");
    defer r.deinit();
    try testing.expectEqual(0, r.sink.finish().len);
    const s = r.ast.data(r.items()[0]).struct_decl;
    try testing.expectEqual(2, s.fields.len);
    for (s.fields) |f| try testing.expectEqual(.field_decl, r.ast.kind(f));
    try testing.expectEqual(2, s.members.len);
    try testing.expectEqual(.fn_decl, r.ast.kind(s.members[0]));
    try testing.expectEqual(.const_decl, r.ast.kind(s.members[1]));
}

test "fields and variants come before members" {
    try expectDiags("struct S { fn f() {} x: i32 }\nfn g() {}", &.{.{ .code = null, .line = 1 }});
    try expectDiags("enum E { a b }\nfn g() {}", &.{.{ .code = null, .line = 1 }});
    // A variant without a comma may be followed by members (`","?`).
    try expectDiags("enum E { a fn f() {} }", &.{});
}

test "docTokens finds `///` docs before attributes and modifiers" {
    const src =
        \\//! Module.
        \\/// One.
        \\/// Two.
        \\@inline pub fn f() {}
        \\/// Three.
        \\pub const C = 1;
        \\fn g() {}
    ;
    var r: Parsed = undefined;
    try r.init(src);
    defer r.deinit();
    const its = r.items();
    const one = docTokens(&r.ast, its[0]);
    try testing.expectEqual(1, one.start);
    try testing.expectEqual(3, one.end);
    const three = docTokens(&r.ast, its[1]);
    try testing.expectEqualStrings("/// Three.", r.ast.tokenSlice(three.start));
    try testing.expectEqual(1, three.end - three.start);
    const none = docTokens(&r.ast, its[2]);
    try testing.expectEqual(none.start, none.end);
}

test "parseAnonStruct" {
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    const src = "struct { x: u8, fn f(self) {} }";
    const tokens = try lexer.tokenize(testing.allocator, src, test_file, &sink, .{ .scan_literal = literals.scan });
    var p: Parser = .init(testing.allocator, src, tokens, test_file, &sink);
    defer p.deinit();
    const n = try parseAnonStruct(&p);
    try testing.expectEqual(0, sink.finish().len);
    const s = p.ast.data(n).anon_struct;
    try testing.expectEqual(1, s.fields.len);
    try testing.expectEqual(1, s.members.len);
    try testing.expectEqual(.eof, p.peek(0));
}
