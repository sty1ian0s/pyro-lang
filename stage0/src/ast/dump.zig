//! S-expression AST dumper behind `--dump-ast` (B.3).
//!
//! Format, one node:
//!
//! ```
//! (kind modifiers... main-token name
//!   field=value
//!   ...)
//! ```
//!
//! - `modifiers` are the `pub`/`mut`/`move`/`comptime` tokens that the
//!   token stream records before a declaration, field or parameter;
//! - `main-token` is the main token's source text (omitted for `root`);
//! - `name` is the token at `main_token + 1` for kinds that keep their name,
//!   ABI string or launch target there;
//! - fields follow `Ast.Data` order: a node, a token's text, `[...]` for a
//!   list (`[]` when empty) or `_` for an absent optional.
//!
//! The output depends only on the tree and the tokens, so it is stable.

const std = @import("std");
const Ast = @import("Ast.zig");
const Node = Ast.Node;
const NodeKind = Ast.NodeKind;
const Writer = std.Io.Writer;

/// Writes the tree under node 0 (the root), followed by a newline.
pub fn dump(ast: *const Ast, w: *Writer) Writer.Error!void {
    try dumpNode(ast, .from(0), w, 0);
    try w.writeByte('\n');
}

/// Writes the subtree under `n`; nested lines are indented relative to `depth`.
pub fn dumpNode(ast: *const Ast, n: Node.Index, w: *Writer, depth: usize) Writer.Error!void {
    const k = ast.kind(n);
    const mt = ast.mainToken(n);
    try w.print("({s}", .{@tagName(k)});
    if (hasModifiers(k)) {
        var first = mt;
        while (first > 0 and isModifier(ast.tokens.items(.kind)[first - 1])) first -= 1;
        for (first..mt) |t| try w.print(" {s}", .{ast.tokenSlice(@intCast(t))});
    }
    if (k != .root) try w.print(" {s}", .{ast.tokenSlice(mt)});
    if (hasName(k)) try w.print(" {s}", .{ast.tokenSlice(mt + 1)});

    switch (ast.data(n)) {
        inline else => |p| {
            const info = @typeInfo(@TypeOf(p)).@"struct";
            inline for (info.field_names) |name| {
                try newline(w, depth + 1);
                try w.print("{s}=", .{name});
                try value(ast, w, depth + 1, @field(p, name));
            }
        },
    }
    try w.writeByte(')');
}

fn value(ast: *const Ast, w: *Writer, depth: usize, v: anytype) Writer.Error!void {
    switch (@TypeOf(v)) {
        Node.Index => try dumpNode(ast, v, w, depth),
        Ast.TokenIndex => try w.writeAll(ast.tokenSlice(v)),
        []const Node.Index => {
            if (v.len == 0) return w.writeAll("[]");
            try w.writeByte('[');
            for (v) |c| {
                try newline(w, depth + 1);
                try dumpNode(ast, c, w, depth + 1);
            }
            try w.writeByte(']');
        },
        else => if (v) |x| try value(ast, w, depth, x) else try w.writeByte('_'),
    }
}

fn newline(w: *Writer, depth: usize) Writer.Error!void {
    try w.writeByte('\n');
    try w.splatByteAll(' ', 2 * depth);
}

fn hasName(k: NodeKind) bool {
    return switch (k) {
        .const_decl, .type_alias, .type_distinct, .fn_decl, .struct_decl, .enum_decl, .protocol_decl, .extern_block, .launch => true,
        else => false,
    };
}

fn hasModifiers(k: NodeKind) bool {
    return switch (k) {
        .use, .use_list, .const_decl, .type_alias, .type_distinct, .fn_decl, .struct_decl, .enum_decl, .protocol_decl, .impl_decl, .extern_block, .comptime_block, .field_decl, .param => true,
        else => false,
    };
}

fn isModifier(t: @import("../lex/token.zig").TokenKind) bool {
    return switch (t) {
        .kw_pub, .kw_mut, .kw_move, .kw_comptime => true,
        else => false,
    };
}

const testing = std.testing;
const token = @import("../lex/token.zig");

/// Test helper: an `Ast` whose tokens are the space-separated words of `src`,
/// kinded as keyword, punctuator or identifier.
fn testAst(gpa: std.mem.Allocator, src: []const u8) !Ast {
    var ast: Ast = .{ .source = src };
    errdefer ast.deinit(gpa);
    var it = std.mem.tokenizeScalar(u8, src, ' ');
    while (it.next()) |word| {
        const k = token.keyword(word) orelse for (std.enums.values(token.TokenKind)) |p| {
            if (p.lexeme()) |l| if (std.mem.eql(u8, l, word)) break p;
        } else .ident;
        const start: u32 = @intCast(word.ptr - src.ptr);
        try ast.tokens.append(gpa, .{ .kind = k, .start = start, .len = @intCast(word.len) });
    }
    return ast;
}

fn dumpAlloc(ast: *const Ast, n: Node.Index) ![]u8 {
    var out: Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try dumpNode(ast, n, &out.writer, 0);
    return out.toOwnedSlice();
}

test "construct, decode and dump every node kind" {
    const gpa = testing.allocator;
    var ast = try testAst(gpa, "k n leaf");
    defer ast.deinit(gpa);
    const leaf = try ast.add(gpa, 2, .{ .ident = .{} });
    @setEvalBranchQuota(10_000);

    inline for (comptime std.enums.values(NodeKind)) |k| {
        // Once with every optional present, once with every optional absent.
        inline for (.{ true, false }) |present| {
            const P = @FieldType(Ast.Data, @tagName(k));
            const info = @typeInfo(P).@"struct";
            var p: P = undefined;
            _ = &p;
            inline for (info.field_names, info.field_types) |name, F| {
                @field(p, name) = switch (F) {
                    Node.Index => leaf,
                    ?Node.Index => if (present) leaf else null,
                    Ast.TokenIndex => 2,
                    ?Ast.TokenIndex => if (present) 2 else null,
                    []const Node.Index => &.{ leaf, leaf },
                    ?[]const Node.Index => if (present) &.{leaf} else null,
                    else => unreachable,
                };
            }
            const n = try ast.add(gpa, 0, @unionInit(Ast.Data, @tagName(k), p));
            try testing.expectEqual(k, ast.kind(n));
            try testing.expectEqual(0, ast.mainToken(n));

            const got = @field(ast.data(n), @tagName(k));
            inline for (info.field_names, info.field_types) |name, F| {
                switch (F) {
                    []const Node.Index => try testing.expectEqualSlices(Node.Index, @field(p, name), @field(got, name)),
                    ?[]const Node.Index => if (@field(p, name)) |want|
                        try testing.expectEqualSlices(Node.Index, want, @field(got, name).?)
                    else
                        try testing.expectEqual(null, @field(got, name)),
                    else => try testing.expectEqual(@field(p, name), @field(got, name)),
                }
            }

            const text = try dumpAlloc(&ast, n);
            defer gpa.free(text);
            try testing.expect(std.mem.startsWith(u8, text, "(" ++ @tagName(k)));
            try testing.expectEqual(info.field_names.len, std.mem.count(u8, text, "="));
        }
    }
}

test "golden dump of a small file" {
    // pub fn add(mut a: i32) -> i32 { let x = a + 1; x }
    const gpa = testing.allocator;
    var ast = try testAst(gpa, "pub fn add ( mut a : i32 ) -> i32 { let x = a + 1 ; x }");
    defer ast.deinit(gpa);

    const root = try ast.add(gpa, 0, .{ .invalid = .{} }); // reserved, set below
    const i32_param = try ast.add(gpa, 7, .{ .path = .{ .last = 7 } });
    const param = try ast.add(gpa, 5, .{ .param = .{ .ty = i32_param, .default = null } });
    const i32_ret = try ast.add(gpa, 10, .{ .path = .{ .last = 10 } });
    const pat = try ast.add(gpa, 13, .{ .pat_bind = .{} });
    const a = try ast.add(gpa, 15, .{ .ident = .{} });
    const one = try ast.add(gpa, 17, .{ .int_lit = .{} });
    const sum = try ast.add(gpa, 16, .{ .binary = .{ .lhs = a, .rhs = one } });
    const let = try ast.add(gpa, 12, .{ .let = .{ .pattern = pat, .ty = null, .init = sum } });
    const x = try ast.add(gpa, 19, .{ .ident = .{} });
    const body = try ast.add(gpa, 11, .{ .block = .{ .stmts = &.{let}, .tail = x } });
    const f = try ast.add(gpa, 1, .{ .fn_decl = .{ .generics = null, .params = &.{param}, .ret = i32_ret, .body = body } });
    try ast.set(gpa, root, 0, .{ .root = .{ .items = &.{f} } });

    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    try dump(&ast, &out.writer);
    try testing.expectEqualStrings(
        \\(root
        \\  items=[
        \\    (fn_decl pub fn add
        \\      generics=_
        \\      params=[
        \\        (param mut a
        \\          ty=(path i32
        \\            last=i32)
        \\          default=_)]
        \\      ret=(path i32
        \\        last=i32)
        \\      body=(block {
        \\        stmts=[
        \\          (let let
        \\            pattern=(pat_bind x)
        \\            ty=_
        \\            init=(binary +
        \\              lhs=(ident a)
        \\              rhs=(int_lit 1)))]
        \\        tail=(ident x)))])
        \\
    , out.written());
}
