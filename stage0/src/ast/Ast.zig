//! The AST of one source file (spec B.3): a struct-of-arrays node table plus
//! an `extra` array for variable-length data. Nodes never hold pointers.
//!
//! Every node is `Node{kind, main_token, a, b}`. The payload of each kind is
//! declared once, as the matching field of `Data`, and encoded generically:
//!
//! - each payload field is one `u32` slot: a node index, a token index, or
//!   an `extra` index of a list `[count, child0, child1, ...]`;
//!   optional slots hold `none` (all ones);
//! - a payload of at most two slots is stored in `a` and `b`;
//! - a longer payload keeps slot 0 in `a`, and `b` is the `extra` index of
//!   slots 1.. stored consecutively (B.3: `If { a = cond, b = extra index
//!   of [then, else] }`).
//!
//! `data` decodes a node into its typed payload and `add` encodes one, so the
//! layout table in `Data` is the only place a layout is written down.
//!
//! Facts that the token stream already records are not duplicated in nodes:
//!
//! - doc comments of a declaration are the `doc_comment` tokens directly
//!   before its first token (its first attribute, or its keyword);
//! - `pub` is the token before a declaration keyword, and `pub`/`pub mut`
//!   the tokens before a field name;
//! - a parameter mode (`comptime`, `mut`, `move`) is the token before the
//!   parameter name;
//! - the declared name of `const_decl`, `type_alias`, `type_distinct`,
//!   `fn_decl`, `struct_decl`, `enum_decl` and `protocol_decl`, the ABI
//!   string of `extern_block` and the `gpu`/`cpu` target of `launch` are at
//!   `main_token + 1`;
//! - the operator of `prefix`, `binary`, `assign`, `range` and `pat_range`
//!   is its main token.
//!
//! Node 0 is the `root`. Parent links are not stored; passes walk top-down.

const std = @import("std");
const Allocator = std.mem.Allocator;
const tok = @import("../lex/token.zig");
const base_index = @import("../base/index.zig");

const Ast = @This();

/// Source bytes of the file. Borrowed; must outlive the `Ast`.
source: []const u8,
/// The file's tokens (B.2). Owned.
tokens: tok.TokenBuffer = .empty,
/// Node table, root at index 0. Owned.
nodes: std.MultiArrayList(Node) = .empty,
/// Variable-length node data; see the file doc. Owned.
extra: std.ArrayList(u32) = .empty,

/// Index into `tokens`.
pub const TokenIndex = u32;

/// Encoded "absent" value of an optional slot.
pub const none: u32 = std.math.maxInt(u32);

/// One AST node (B.3). `a` and `b` are interpreted per `kind`, see `Data`.
pub const Node = struct {
    kind: NodeKind,
    /// Token used for diagnostics; its meaning per kind is documented on `Data`.
    main_token: TokenIndex,
    a: u32,
    b: u32,

    /// Index into `nodes`; `.none` marks an absent optional child.
    pub const Index = base_index.Index(.node);
};

comptime {
    std.debug.assert(@sizeOf(Node) <= 16);
}

/// Kind of a node: one per chapter-3 production (spec §3.2-§3.8), plus
/// `invalid` for nodes the parser poisons during error recovery.
/// Frozen after T014; additions go through the owner of this file.
/// Each kind is documented on the `Data` field of the same name.
pub const NodeKind = enum(u16) {
    root,
    invalid,
    attributed,
    attribute,
    named_arg,
    use,
    use_list,
    use_item,
    path,
    const_decl,
    type_alias,
    type_distinct,
    generic_param,
    fn_decl,
    param,
    struct_decl,
    anon_struct,
    field_decl,
    enum_decl,
    variant_decl,
    protocol_decl,
    impl_decl,
    extern_block,
    comptime_block,

    block,
    empty_stmt,
    let,
    guard_let,
    @"defer",
    @"errdefer",
    @"return",
    return_tail,
    @"break",
    @"continue",
    spawn,
    launch,
    nursery,
    labeled,
    @"while",
    @"for",
    for_inline,
    parallel_for,
    let_cond,
    discard,
    assign,

    array_type,
    slice_type,
    soa_array_type,
    soa_slice_type,
    ptr_type,
    ptr_const_type,
    mut_type,
    fn_type,
    param_mode,
    type_type,
    generic_inst,
    generic_expr_arg,

    pat_wildcard,
    pat_bind,
    pat_bind_mut,
    pat_range,
    pat_variant,
    pat_tuple,
    pat_struct,
    pat_anon_struct,
    field_pat,
    field_pat_mut,
    pat_alt,
    rest,

    int_lit,
    float_lit,
    char_lit,
    string_lit,
    ml_string,
    bool_lit,
    ident,
    self_value,
    self_type,
    builtin_call,
    paren,
    tuple,
    array_lit,
    array_repeat,
    array_comp,
    struct_lit,
    field_init,
    anon_lit,
    inferred_member,
    lambda,
    @"if",
    comptime_if,
    match,
    match_arm,
    loop,
    unsafe_block,
    prefix,
    binary,
    range,
    cast,
    field_access,
    call,
    mut_arg,
    index,
    try_op,
};

// Slot types of payload fields (see the file doc).
const N = Node.Index;
const ON = ?Node.Index;
const L = []const Node.Index;
const OL = ?[]const Node.Index;
const T = TokenIndex;
const OT = ?TokenIndex;

/// Typed payload of each node kind. The doc of each field names the grammar
/// production and what `main_token` points at ("mt").
/// List slices returned by `data` point into `extra` and are invalidated by
/// the next `add`.
pub const Data = union(NodeKind) {
    // Modules and items (§3.2-§3.4).

    /// `module`. mt: 0. Module doc comments are the leading `//!` tokens.
    root: struct { items: L },
    /// Poisoned node produced by parser recovery. mt: where the error was found.
    invalid: struct {},
    /// `attribute+` before an item, member, field, variant, parameter, loop or
    /// `let` (§3.3). mt: the first attribute's BUILTIN.
    attributed: struct { attrs: L, inner: N },
    /// `BUILTIN ( "(" attr_args? ")" )?`. mt: BUILTIN. `args` is null without
    /// parentheses; elements are exprs or `named_arg`.
    attribute: struct { args: OL },
    /// `IDENT ":" expr` in attribute and call arguments. mt: IDENT.
    named_arg: struct { value: N },
    /// `use path ( "as" IDENT )? ;`. mt: `use`.
    use: struct { path: N, alias: OT },
    /// `use path .{ use_item, ... } ;`. mt: `use`. Items are `use_item`.
    use_list: struct { path: N, items: L },
    /// `IDENT ( "as" IDENT )?`. mt: the first IDENT.
    use_item: struct { alias: OT },
    /// `IDENT ( "." IDENT )*` in `use` and types. mt: first IDENT; the
    /// segments are every other token from mt to `last`.
    path: struct { last: T },
    /// `"const" IDENT ( ":" type )? "=" expr ";"`. mt: `const`.
    const_decl: struct { ty: ON, value: N },
    /// `"type" IDENT generic_params? "=" type ";"`. mt: `type`.
    type_alias: struct { generics: OL, ty: N },
    /// `"type" IDENT generic_params? "=" "distinct" type ";"`. mt: `type`.
    type_distinct: struct { generics: OL, ty: N },
    /// `IDENT ( ":" bound_list )?`; `bounds` may be empty. mt: IDENT.
    generic_param: struct { bounds: L },
    /// `fn_decl`, `extern_fn` and protocol required methods. mt: `fn`.
    /// `body` is null for `;`.
    fn_decl: struct { generics: OL, params: L, ret: ON, body: ON },
    /// `param` (mode at mt-1) or `lambda_param`. mt: `self` or IDENT.
    /// `ty` is null for `self` and untyped lambda parameters.
    param: struct { ty: ON, default: ON },
    /// `"struct" IDENT generic_params? struct_body`. mt: `struct`.
    /// Fields are `field_decl`, members `fn_decl`/`const_decl` (maybe `attributed`).
    struct_decl: struct { generics: OL, fields: L, members: L },
    /// `"struct" struct_body` as a type or comptime expression. mt: `struct`.
    anon_struct: struct { fields: L, members: L },
    /// `field`. mt: IDENT; `pub`/`pub mut` precede it.
    field_decl: struct { ty: N, default: ON },
    /// `"enum" IDENT generic_params? ( ":" type )? "{" variant_list? member* "}"`.
    /// mt: `enum`.
    enum_decl: struct { generics: OL, backing: ON, variants: L, members: L },
    /// `variant`. mt: IDENT. `payload` is null without parentheses.
    variant_decl: struct { payload: OL, value: ON },
    /// `"protocol" IDENT generic_params? "{" member* "}"`. mt: `protocol`.
    protocol_decl: struct { generics: OL, members: L },
    /// `"impl" generic_params? type "for" type "{" member* "}"`. mt: `impl`.
    impl_decl: struct { generics: OL, protocol: N, target: N, members: L },
    /// `"extern" STRING_LIT "{" extern_fn* "}"`. mt: `extern`.
    extern_block: struct { fns: L },
    /// `"comptime" block` as item or block expression. mt: `comptime`.
    comptime_block: struct { body: N },

    // Statements and blocks (§3.5).

    /// `"{" stmt* expr? "}"`. mt: `{`. Expression statements are the
    /// expression node itself.
    block: struct { stmts: L, tail: ON },
    /// `";"`. mt: `;`.
    empty_stmt: struct {},
    /// `"let" pattern ( ":" type )? "=" expr ";"`. mt: `let`.
    let: struct { pattern: N, ty: ON, init: N },
    /// `"guard" "let" pattern "=" expr "else" block`. mt: `guard`.
    guard_let: struct { pattern: N, value: N, @"else": N },
    /// `"defer" ( block | expr ";" )`. mt: `defer`.
    @"defer": struct { body: N },
    /// `"errdefer" ( block | expr ";" )`. mt: `errdefer`.
    @"errdefer": struct { body: N },
    /// `"return" expr? ";"`. mt: `return`.
    @"return": struct { value: ON },
    /// `"return" "tail" expr ";"`. mt: `return`.
    return_tail: struct { call: N },
    /// `"break" ( ":" IDENT )? expr? ";"`. mt: `break`; `label` is the IDENT.
    @"break": struct { label: OT, value: ON },
    /// `"continue" ( ":" IDENT )? ";"`. mt: `continue`.
    @"continue": struct { label: OT },
    /// `"spawn" expr ";"`. mt: `spawn`.
    spawn: struct { call: N },
    /// `"launch" IDENT expr ( "over" expr )? ";"`. mt: `launch`.
    launch: struct { call: N, over: ON },
    /// `"nursery" block`. mt: `nursery`.
    nursery: struct { body: N },
    /// `IDENT ":"` before a loop or `loop` block. mt: the label IDENT.
    labeled: struct { inner: N },
    /// `"while" condition block`. mt: `while`.
    @"while": struct { cond: N, body: N },
    /// `"for" pattern ( "," pattern )? "in" expr_ns ( "where" expr_ns )? block`.
    /// mt: `for`.
    @"for": struct { pattern: N, pattern2: ON, iter: N, filter: ON, body: N },
    /// `"inline" "for" ...`, same layout as `for`. mt: `for`.
    for_inline: struct { pattern: N, pattern2: ON, iter: N, filter: ON, body: N },
    /// `"parallel_for" pattern "in" expr_ns block`. mt: `parallel_for`.
    parallel_for: struct { pattern: N, iter: N, body: N },
    /// `"let" pattern "=" expr_ns` as an `if`/`while` condition. mt: `let`.
    let_cond: struct { pattern: N, value: N },
    /// `"_" "=" expr ";"`. mt: `_`.
    discard: struct { value: N },
    /// `expr assign_op expr ";"`. mt: the `assign_op`.
    assign: struct { lhs: N, rhs: N },

    // Types (§3.6). Tuple, parenthesized, `Self`, builtin, anonymous struct,
    // path and type-function-call types reuse `tuple`, `paren`, `self_type`,
    // `builtin_call`, `anon_struct`, `path` and `call` (callee a `path`).

    /// `"[" expr "]" type`. mt: `[`.
    array_type: struct { len: N, elem: N },
    /// `"[" "]" type`. mt: `[`.
    slice_type: struct { elem: N },
    /// `"soa" "[" expr "]" type`. mt: `soa`.
    soa_array_type: struct { len: N, elem: N },
    /// `"soa" "[" "]" type`. mt: `soa`.
    soa_slice_type: struct { elem: N },
    /// `"*" type`. mt: `*`.
    ptr_type: struct { elem: N },
    /// `"*" "const" type`. mt: `*`.
    ptr_const_type: struct { elem: N },
    /// `"mut" type` (mutable view). mt: `mut`.
    mut_type: struct { elem: N },
    /// `"fn" "(" fn_type_param,* ")" ( "->" type )?`. mt: `fn`.
    fn_type: struct { params: L, ret: ON },
    /// `( "mut" | "move" ) type` as a `fn_type_param`. mt: the mode.
    param_mode: struct { ty: N },
    /// `"type"`. mt: `type`.
    type_type: struct {},
    /// `path generic_args`. mt: `<`. Arguments are types, `int_lit`,
    /// `prefix` `-` of an `int_lit`, `char_lit`, `bool_lit` or `generic_expr_arg`.
    generic_inst: struct { base: N, args: L },
    /// `"{" expr "}"` as a generic argument. mt: `{`.
    generic_expr_arg: struct { value: N },

    // Patterns (§3.7). Literal patterns reuse `int_lit`, `char_lit`,
    // `bool_lit` and `prefix` `-` of an `int_lit`.

    /// `"_"`. mt: `_`.
    pat_wildcard: struct {},
    /// `IDENT` binding. mt: IDENT.
    pat_bind: struct {},
    /// `"mut" IDENT` binding. mt: IDENT.
    pat_bind_mut: struct {},
    /// `literal_pattern ( ".." | "..=" ) literal_pattern`. mt: the operator.
    pat_range: struct { lo: N, hi: N },
    /// `"." IDENT ( "(" pattern,* ")" )?`. mt: IDENT. `elems` null without parentheses.
    pat_variant: struct { elems: OL },
    /// `"(" pattern "," pattern,* ")"`. mt: `(`.
    pat_tuple: struct { elems: L },
    /// `path "{" field_pattern_list "}"`. mt: `{`. A trailing `rest` node marks `..`.
    pat_struct: struct { ty: N, fields: L },
    /// `".{" field_pattern_list "}"`. mt: `.{`.
    pat_anon_struct: struct { fields: L },
    /// `IDENT ( ":" pattern )?`. mt: IDENT.
    field_pat: struct { pattern: ON },
    /// `"mut" IDENT` field pattern. mt: IDENT.
    field_pat_mut: struct {},
    /// `pattern_single ( "|" pattern_single )+`. mt: the first `|`.
    pat_alt: struct { alts: L },
    /// The rest marker `..` in struct patterns and literals. mt: `..`.
    rest: struct {},

    // Expressions (§3.8, §3.9).

    /// INT_LIT. mt: the literal.
    int_lit: struct {},
    /// FLOAT_LIT. mt: the literal.
    float_lit: struct {},
    /// CHAR_LIT. mt: the literal.
    char_lit: struct {},
    /// STRING_LIT. mt: the literal.
    string_lit: struct {},
    /// `ML_STRING_LINE+`. mt: the first line; `last` is the last line.
    ml_string: struct { last: T },
    /// `"true"` or `"false"`. mt: the keyword.
    bool_lit: struct {},
    /// IDENT. mt: IDENT.
    ident: struct {},
    /// `"self"`. mt: `self`.
    self_value: struct {},
    /// `"Self"` in expressions and types. mt: `Self`.
    self_type: struct {},
    /// `BUILTIN ( "(" builtin_args? ")" )?` in expressions and types. mt:
    /// BUILTIN. `args` is null for a builtin variable (no parentheses).
    builtin_call: struct { args: OL },
    /// `"(" expr ")"` or `"(" type ")"`. mt: `(`.
    paren: struct { inner: N },
    /// `"(" expr "," expr,* ")"` or the tuple type. mt: `(`.
    tuple: struct { elems: L },
    /// `"[" expr,* "]"`. mt: `[`.
    array_lit: struct { elems: L },
    /// `"[" expr ";" expr "]"`. mt: `[`.
    array_repeat: struct { value: N, count: N },
    /// `"[" expr "for" pattern ( "," pattern )? "in" expr_ns ( "where" expr_ns )? "]"`.
    /// mt: `[`.
    array_comp: struct { elem: N, pattern: N, pattern2: ON, iter: N, filter: ON },
    /// `( path | "Self" ) "{" field_inits? "}"`. mt: `{`. `fields` are
    /// `field_init`, optionally ending in `rest`.
    struct_lit: struct { ty: N, fields: L },
    /// `IDENT ( ":" expr )?`; `value` is null for the shorthand. mt: IDENT.
    field_init: struct { value: ON },
    /// `".{" anon_elem,* "}"`. mt: `.{`. Elements are exprs or `named_arg`,
    /// optionally ending in `rest`.
    anon_lit: struct { elems: L },
    /// `"." IDENT`. mt: IDENT.
    inferred_member: struct {},
    /// `"|" lambda_param,* "|" expr` or `"||" expr`. mt: `|` or `||`.
    /// Parameters are `param`.
    lambda: struct { params: L, body: N },
    /// `"if" condition block ( "else" ( block | if ) )?`. mt: `if`. `cond` is
    /// an expr or `let_cond`.
    @"if": struct { cond: N, then: N, @"else": ON },
    /// `"comptime" if_expr` (§8.5). mt: `comptime`.
    comptime_if: struct { @"if": N },
    /// `"match" expr_ns "{" match_arm* "}"`. mt: `match`.
    match: struct { subject: N, arms: L },
    /// `pattern ( "if" expr )? "=>" ( block | expr )`. mt: `=>`.
    match_arm: struct { pattern: N, guard: ON, body: N },
    /// `"loop" block`. mt: `loop`.
    loop: struct { body: N },
    /// `"unsafe" block`. mt: `unsafe`.
    unsafe_block: struct { body: N },
    /// Prefix `-` `!` `~` `*` `&` `comptime` `move` (level 12). mt: the operator.
    prefix: struct { operand: N },
    /// Infix operators of levels 2-10. mt: the operator.
    binary: struct { lhs: N, rhs: N },
    /// `..`/`..=` with optional operands (level 1). mt: the operator.
    range: struct { lo: ON, hi: ON },
    /// `expr "as" type`. mt: `as`.
    cast: struct { value: N, ty: N },
    /// Postfix `.IDENT` or `.INT_LIT`. mt: the field name token.
    field_access: struct { lhs: N },
    /// Postfix `(call_args)`; also `path(call_args)` in types. mt: `(`.
    /// Arguments are exprs, types, `named_arg` or `mut_arg`.
    call: struct { callee: N, args: L },
    /// `"mut" expr` as a call argument. mt: `mut`.
    mut_arg: struct { value: N },
    /// Postfix `"[" expr "]"`. mt: `[`.
    index: struct { lhs: N, index: N },
    /// Postfix `?`. mt: `?`.
    try_op: struct { lhs: N },
};

/// Frees everything the `Ast` owns.
pub fn deinit(ast: *Ast, gpa: Allocator) void {
    ast.tokens.deinit(gpa);
    ast.nodes.deinit(gpa);
    ast.extra.deinit(gpa);
    ast.* = undefined;
}

/// Kind of node `n`.
pub fn kind(ast: *const Ast, n: Node.Index) NodeKind {
    return ast.nodes.items(.kind)[n.int()];
}

/// Main token of node `n`.
pub fn mainToken(ast: *const Ast, n: Node.Index) TokenIndex {
    return ast.nodes.items(.main_token)[n.int()];
}

/// Source text of token `t`.
pub fn tokenSlice(ast: *const Ast, t: TokenIndex) []const u8 {
    const start = ast.tokens.items(.start)[t];
    return ast.source[start..][0..ast.tokens.items(.len)[t]];
}

/// Typed payload of node `n`.
pub fn data(ast: *const Ast, n: Node.Index) Data {
    const i = n.int();
    const a = ast.nodes.items(.a)[i];
    const b = ast.nodes.items(.b)[i];
    switch (ast.nodes.items(.kind)[i]) {
        inline else => |k| {
            const P = @FieldType(Data, @tagName(k));
            const names = @typeInfo(P).@"struct".field_names;
            var p: P = undefined;
            _ = &p;
            inline for (names, @typeInfo(P).@"struct".field_types, 0..) |name, F, j| {
                const raw = if (j == 0) a else if (names.len <= 2) b else ast.extra.items[b + j - 1];
                @field(p, name) = ast.decodeSlot(F, raw);
            }
            return @unionInit(Data, @tagName(k), p);
        },
    }
}

/// Children of list `extra[e]`: `[count, child...]`.
fn list(ast: *const Ast, e: u32) L {
    const items = ast.extra.items[e + 1 ..][0..ast.extra.items[e]];
    return @ptrCast(items);
}

fn decodeSlot(ast: *const Ast, comptime F: type, raw: u32) F {
    return switch (F) {
        N => @fromBackingInt(raw),
        ON => @as(N, @fromBackingInt(raw)).unwrap(),
        T => raw,
        OT => if (raw == none) null else raw,
        L => ast.list(raw),
        OL => if (raw == none) null else ast.list(raw),
        else => @compileError("unsupported payload slot type " ++ @typeName(F)),
    };
}

/// Appends a node with main token `main_token` and payload `d`; returns its index.
/// Lists in `d` are copied into `extra`.
pub fn add(ast: *Ast, gpa: Allocator, main_token: TokenIndex, d: Data) Allocator.Error!Node.Index {
    const node = try ast.encode(gpa, main_token, d);
    try ast.nodes.append(gpa, node);
    return .from(ast.nodes.len - 1);
}

/// Overwrites node `n`, e.g. the root reserved at index 0 before its items
/// were parsed.
pub fn set(ast: *Ast, gpa: Allocator, n: Node.Index, main_token: TokenIndex, d: Data) Allocator.Error!void {
    ast.nodes.set(n.int(), try ast.encode(gpa, main_token, d));
}

fn encode(ast: *Ast, gpa: Allocator, main_token: TokenIndex, d: Data) Allocator.Error!Node {
    switch (d) {
        inline else => |p, k| {
            const info = @typeInfo(@TypeOf(p)).@"struct";
            var slots: [info.field_names.len]u32 = undefined;
            inline for (info.field_names, info.field_types, 0..) |name, F, j| {
                slots[j] = try ast.encodeSlot(gpa, F, @field(p, name));
            }
            var node: Node = .{ .kind = k, .main_token = main_token, .a = 0, .b = 0 };
            if (slots.len > 0) node.a = slots[0];
            if (slots.len == 2) node.b = slots[1];
            if (slots.len > 2) {
                node.b = @intCast(ast.extra.items.len);
                try ast.extra.appendSlice(gpa, slots[1..]);
            }
            return node;
        },
    }
}

fn encodeSlot(ast: *Ast, gpa: Allocator, comptime F: type, v: F) Allocator.Error!u32 {
    return switch (F) {
        N => v.int(),
        ON => if (v) |x| x.int() else none,
        T => v,
        OT => v orelse none,
        L => ast.addList(gpa, v),
        OL => if (v) |x| ast.addList(gpa, x) else none,
        else => @compileError("unsupported payload slot type " ++ @typeName(F)),
    };
}

fn addList(ast: *Ast, gpa: Allocator, items: L) Allocator.Error!u32 {
    const e: u32 = @intCast(ast.extra.items.len);
    try ast.extra.ensureUnusedCapacity(gpa, items.len + 1);
    ast.extra.appendAssumeCapacity(@intCast(items.len));
    ast.extra.appendSliceAssumeCapacity(@ptrCast(items));
    return e;
}

const testing = std.testing;

test "node is at most 16 bytes" {
    try testing.expect(@sizeOf(Node) <= 16);
    try testing.expectEqual(2, @sizeOf(NodeKind));
}

test "B.3 layouts: binary in a/b, call args and if branches via extra" {
    const gpa = testing.allocator;
    var ast: Ast = .{ .source = "" };
    defer ast.deinit(gpa);

    const x = try ast.add(gpa, 0, .{ .ident = .{} });
    const y = try ast.add(gpa, 0, .{ .ident = .{} });
    const bin = try ast.add(gpa, 0, .{ .binary = .{ .lhs = x, .rhs = y } });
    try testing.expectEqual(x.int(), ast.nodes.items(.a)[bin.int()]);
    try testing.expectEqual(y.int(), ast.nodes.items(.b)[bin.int()]);

    const call = try ast.add(gpa, 0, .{ .call = .{ .callee = x, .args = &.{ x, y } } });
    const e = ast.nodes.items(.b)[call.int()];
    try testing.expectEqualSlices(u32, &.{ 2, x.int(), y.int() }, ast.extra.items[e..][0..3]);

    const if_ = try ast.add(gpa, 0, .{ .@"if" = .{ .cond = x, .then = y, .@"else" = null } });
    const f = ast.nodes.items(.b)[if_.int()];
    try testing.expectEqualSlices(u32, &.{ y.int(), none }, ast.extra.items[f..][0..2]);
    try testing.expectEqual(x.int(), ast.data(if_).@"if".cond.int());
    try testing.expectEqual(null, ast.data(if_).@"if".@"else");
}
