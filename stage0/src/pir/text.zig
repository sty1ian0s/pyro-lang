//! P-IR text format (B.5.1 grammar): printer and parser.
//!
//! ```
//! global @g: i64 = 0 align 8 readonly
//!
//! fn @f(%p: ptr noalias align(8) dereferenceable(16), %n: i64) -> i64 inline {
//! ^entry:
//!   %z: i64 = const 0
//!   br ^loop(%z)
//! ^loop(%i: i64):
//!   %c: i1 = icmp slt %i, %n
//!   cond_br %c, ^loop(%i), ^exit
//! ^exit:
//!   ret %n
//! }
//! ```
//!
//! Instruction syntax: `[%r: T (, %r2: T)* =] opcode modifiers operands`.
//! Modifiers follow the opcode: the `icmp`/`fcmp` predicate, the `atomic.rmw`
//! operation, flags (`nuw nsw fast volatile signed`) and `atomic(order)`.
//! Operands are comma-separated; a trailing `align N` sets the alignment.
//! Calls are `call @f(args)`; branch targets are `^b(args)`; `switch` is
//! `switch %v, default ^d, [k: ^b, ...]`. Each instruction is one line;
//! a block label starts a line. `;` starts a comment.
//! The printer's output is the canonical form: parse(print(m)) prints the same.

const std = @import("std");
const ir = @import("ir.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// ---------------------------------------------------------------- printer

/// Prints `m` in canonical text form.
pub fn print(m: *const ir.Module, w: *Writer) Writer.Error!void {
    for (m.globals.items) |g| {
        try w.print("global @{s}: {f} = ", .{ g.name, g.ty });
        switch (g.init) {
            .int => |x| try w.print("{d}", .{x}),
            .float => |x| try printFloat(w, x),
            .zero => try w.writeAll("zeroinit"),
            .bytes => |s| try printBytes(w, s),
        }
        if (g.@"align" != 0) try w.print(" align {d}", .{g.@"align"});
        if (g.readonly) try w.writeAll(" readonly");
        try w.writeByte('\n');
    }
    for (m.functions.items, 0..) |f, i| {
        if (i > 0 or m.globals.items.len > 0) try w.writeByte('\n');
        try printFunction(f, w);
    }
}

/// Prints one function (declaration or definition).
pub fn printFunction(f: *const ir.Function, w: *Writer) Writer.Error!void {
    try w.print("fn @{s}(", .{f.name});
    for (f.params.items, 0..) |p, i| {
        if (i > 0) try w.writeAll(", ");
        try printValue(f, w, p.value);
        try w.print(": {f}", .{f.typeOf(p.value)});
        if (p.attrs.@"noalias") try w.writeAll(" noalias");
        if (p.attrs.readonly) try w.writeAll(" readonly");
        if (p.attrs.@"align" != 0) try w.print(" align({d})", .{p.attrs.@"align"});
        if (p.attrs.dereferenceable != 0) try w.print(" dereferenceable({d})", .{p.attrs.dereferenceable});
    }
    try w.print(") -> {f}", .{f.ret});
    inline for (.{ "inline", "noinline", "cold", "noreturn" }) |name| {
        if (@field(f.attrs, name)) try w.writeAll(" " ++ name);
    }
    if (f.isDeclaration()) return w.writeByte('\n');
    try w.writeAll(" {\n");
    for (f.blocks.items) |b| {
        try w.print("^{s}", .{b.name});
        if (b.params.items.len > 0) {
            try w.writeByte('(');
            for (b.params.items, 0..) |v, i| {
                if (i > 0) try w.writeAll(", ");
                try printValue(f, w, v);
                try w.print(": {f}", .{f.typeOf(v)});
            }
            try w.writeByte(')');
        }
        try w.writeAll(":\n");
        for (b.insts.items) |inst| {
            try w.writeAll("  ");
            try printInst(f, w, inst);
            try w.writeByte('\n');
        }
    }
    try w.writeAll("}\n");
}

fn printInst(f: *const ir.Function, w: *Writer, inst: ir.Inst) Writer.Error!void {
    for (inst.results, 0..) |v, i| {
        if (i > 0) try w.writeAll(", ");
        try printValue(f, w, v);
        try w.print(": {f}", .{f.typeOf(v)});
    }
    if (inst.results.len > 0) try w.writeAll(" = ");
    try w.writeAll(@tagName(inst.op));
    if (inst.pred != .none) try w.print(" {s}", .{@tagName(inst.pred)});
    if (inst.rmw != .none) try w.print(" {s}", .{@tagName(inst.rmw)});
    inline for (.{ "nuw", "nsw", "fast", "volatile", "signed" }) |name| {
        if (@field(inst.flags, name)) try w.writeAll(" " ++ name);
    }
    if (inst.atomic != .none) try w.print(" atomic({s})", .{@tagName(inst.atomic)});

    switch (inst.op) {
        .br => {
            try w.writeByte(' ');
            try printTarget(f, w, inst.targets[0]);
        },
        .cond_br => {
            try w.writeByte(' ');
            try printOperand(f, w, inst.operands[0]);
            for (inst.targets) |t| {
                try w.writeAll(", ");
                try printTarget(f, w, t);
            }
        },
        .@"switch" => {
            try w.writeByte(' ');
            try printOperand(f, w, inst.operands[0]);
            try w.writeAll(", default ");
            try printTarget(f, w, inst.targets[0]);
            try w.writeAll(", [");
            for (inst.targets[1..], 0..) |t, i| {
                if (i > 0) try w.writeAll(", ");
                try w.print("{d}: ", .{t.key});
                try printTarget(f, w, t);
            }
            try w.writeByte(']');
        },
        else => if (inst.op.isCall()) {
            try w.writeByte(' ');
            try printOperand(f, w, inst.operands[0]);
            try printArgs(f, w, inst.operands[1..]);
        } else {
            for (inst.operands, 0..) |o, i| {
                try w.writeAll(if (i == 0) " " else ", ");
                try printOperand(f, w, o);
            }
            if (inst.@"align" != 0) try w.print("{s}align {d}", .{ if (inst.operands.len > 0) ", " else " ", inst.@"align" });
        },
    }
}

fn printTarget(f: *const ir.Function, w: *Writer, t: ir.Target) Writer.Error!void {
    try w.print("^{s}", .{f.blocks.items[t.block.index()].name});
    if (t.args.len > 0) try printArgs(f, w, t.args);
}

fn printArgs(f: *const ir.Function, w: *Writer, args: []const ir.Operand) Writer.Error!void {
    try w.writeByte('(');
    for (args, 0..) |a, i| {
        if (i > 0) try w.writeAll(", ");
        try printOperand(f, w, a);
    }
    try w.writeByte(')');
}

fn printOperand(f: *const ir.Function, w: *Writer, o: ir.Operand) Writer.Error!void {
    switch (o) {
        .value => |v| try printValue(f, w, v),
        .symbol => |s| try w.print("@{s}", .{s}),
        .int => |x| try w.print("{d}", .{x}),
        .float => |x| try printFloat(w, x),
        .type => |t| try w.print("{f}", .{t}),
        .order => |x| try w.writeAll(@tagName(x)),
    }
}

/// Named values print as `%name`, unnamed ones as `%<index>`.
fn printValue(f: *const ir.Function, w: *Writer, v: ir.Value) Writer.Error!void {
    const name = f.values.items[v.index()].name;
    if (name.len > 0) return w.print("%{s}", .{name});
    try w.print("%{d}", .{v.index()});
}

/// Shortest round-trip decimal, always recognizable as a float literal.
fn printFloat(w: *Writer, x: f64) Writer.Error!void {
    // shortcut: NaN payloads and the sign of NaN are not preserved; add a bit-exact form if a pass needs them.
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{x}) catch return w.print("{e}", .{x});
    try w.writeAll(s);
    if (std.mem.indexOfAny(u8, s, ".ni") == null) try w.writeAll(".0");
}

fn printBytes(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| {
        if (c >= 0x20 and c < 0x7f and c != '"' and c != '\\') try w.writeByte(c) else try w.print("\\{x:0>2}", .{c});
    }
    try w.writeByte('"');
}

// ---------------------------------------------------------------- lexer

const Tag = enum { eof, ident, local, global, label, int, float, string, lparen, rparen, lbrace, rbrace, lbracket, rbracket, comma, colon, equal, langle, rangle, arrow };

const Token = struct {
    tag: Tag,
    start: u32,
    end: u32,
    line: u32,
    col: u32,
};

/// Location and message of the first parse error.
pub const Diag = struct {
    line: u32 = 0,
    col: u32 = 0,
    msg: []const u8 = "",
};

pub const ParseError = Allocator.Error || error{ParseError};

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.';
}

fn tokenize(gpa: Allocator, src: []const u8, out: *std.ArrayList(Token), diag: *Diag) ParseError!void {
    var pos: u32 = 0;
    var line: u32 = 1;
    var line_start: u32 = 0;
    while (true) {
        while (pos < src.len) {
            switch (src[pos]) {
                '\n' => {
                    pos += 1;
                    line += 1;
                    line_start = pos;
                },
                ' ', '\t', '\r' => pos += 1,
                ';' => while (pos < src.len and src[pos] != '\n') {
                    pos += 1;
                },
                else => break,
            }
        }
        const start = pos;
        const col = start - line_start + 1;
        if (pos >= src.len) {
            try out.append(gpa, .{ .tag = .eof, .start = start, .end = start, .line = line, .col = col });
            return;
        }
        const c = src[pos];
        pos += 1;
        const tag: Tag = switch (c) {
            '(' => .lparen,
            ')' => .rparen,
            '{' => .lbrace,
            '}' => .rbrace,
            '[' => .lbracket,
            ']' => .rbracket,
            ',' => .comma,
            ':' => .colon,
            '=' => .equal,
            '<' => .langle,
            '>' => .rangle,
            '%', '@', '^' => blk: {
                while (pos < src.len and isNameChar(src[pos])) pos += 1;
                if (pos == start + 1) return failAt(diag, line, col, "expected a name after sigil");
                break :blk switch (c) {
                    '%' => .local,
                    '@' => .global,
                    else => .label,
                };
            },
            '"' => blk: {
                while (pos < src.len and src[pos] != '"' and src[pos] != '\n') pos += 1;
                if (pos >= src.len or src[pos] != '"') return failAt(diag, line, col, "unterminated string");
                pos += 1;
                break :blk .string;
            },
            '-', '0'...'9' => blk: {
                if (c == '-' and pos < src.len and src[pos] == '>') {
                    pos += 1;
                    break :blk .arrow;
                }
                const hex = c == '0' and pos < src.len and (src[pos] == 'x' or src[pos] == 'X');
                while (pos < src.len) : (pos += 1) {
                    const d = src[pos];
                    const exp_sign = (d == '+' or d == '-') and !hex and (src[pos - 1] == 'e' or src[pos - 1] == 'E');
                    if (!(std.ascii.isAlphanumeric(d) or d == '.' or exp_sign)) break;
                }
                const body = std.mem.trimStart(u8, src[start..pos], "-");
                const float = !hex and (std.mem.indexOfAny(u8, body, ".eE") != null or
                    std.mem.eql(u8, body, "inf") or std.mem.eql(u8, body, "nan"));
                break :blk if (float) .float else .int;
            },
            else => if (std.ascii.isAlphabetic(c) or c == '_') blk: {
                while (pos < src.len and isNameChar(src[pos])) pos += 1;
                break :blk .ident;
            } else return failAt(diag, line, col, "unexpected character"),
        };
        try out.append(gpa, .{ .tag = tag, .start = start, .end = pos, .line = line, .col = col });
    }
}

fn failAt(diag: *Diag, line: u32, col: u32, msg: []const u8) error{ParseError} {
    diag.* = .{ .line = line, .col = col, .msg = msg };
    return error.ParseError;
}

// ---------------------------------------------------------------- parser

/// Parses a module. On failure `diag` holds the first error and nothing
/// leaks. The result owns its memory (call `deinit`).
pub fn parse(gpa: Allocator, src: []const u8, diag: *Diag) ParseError!ir.Module {
    var toks: std.ArrayList(Token) = .empty;
    defer toks.deinit(gpa);
    try tokenize(gpa, src, &toks, diag);

    var m = try ir.Module.init(gpa);
    errdefer m.deinit();
    var p: Parser = .{ .gpa = gpa, .src = src, .toks = toks.items, .m = &m, .diag = diag };
    defer p.deinit();
    while (p.peek().tag != .eof) {
        const t = p.next();
        if (p.isWord(t, "global")) {
            try p.global();
        } else if (p.isWord(t, "fn")) {
            try p.function();
        } else return p.fail(t, "expected 'global' or 'fn'");
    }
    return m;
}

const Parser = struct {
    gpa: Allocator,
    src: []const u8,
    toks: []const Token,
    i: usize = 0,
    m: *ir.Module,
    diag: *Diag,
    // Per-function state.
    f: *ir.Function = undefined,
    locals: std.StringHashMapUnmanaged(ir.Value) = .empty,
    labels: std.StringHashMapUnmanaged(ir.BlockId) = .empty,
    /// Per value: its first-use token if still undefined, else null.
    pending: std.ArrayList(?Token) = .empty,

    fn deinit(p: *Parser) void {
        p.locals.deinit(p.gpa);
        p.labels.deinit(p.gpa);
        p.pending.deinit(p.gpa);
    }

    fn arena(p: *Parser) Allocator {
        return p.m.arena();
    }

    fn peek(p: *Parser) Token {
        return p.toks[p.i];
    }

    fn next(p: *Parser) Token {
        const t = p.toks[p.i];
        if (t.tag != .eof) p.i += 1;
        return t;
    }

    fn text(p: *Parser, t: Token) []const u8 {
        return p.src[t.start..t.end];
    }

    /// Name of a sigil token without its sigil.
    fn name(p: *Parser, t: Token) []const u8 {
        return p.src[t.start + 1 .. t.end];
    }

    fn isWord(p: *Parser, t: Token, w: []const u8) bool {
        return t.tag == .ident and std.mem.eql(u8, p.text(t), w);
    }

    fn fail(p: *Parser, t: Token, msg: []const u8) error{ParseError} {
        return failAt(p.diag, t.line, t.col, msg);
    }

    fn expect(p: *Parser, tag: Tag, msg: []const u8) ParseError!Token {
        const t = p.next();
        if (t.tag != tag) return p.fail(t, msg);
        return t;
    }

    fn expectWord(p: *Parser, w: []const u8, msg: []const u8) ParseError!void {
        const t = p.next();
        if (!p.isWord(t, w)) return p.fail(t, msg);
    }

    fn eat(p: *Parser, tag: Tag) bool {
        if (p.peek().tag != tag) return false;
        _ = p.next();
        return true;
    }

    fn eatWord(p: *Parser, w: []const u8) bool {
        if (!p.isWord(p.peek(), w)) return false;
        _ = p.next();
        return true;
    }

    fn int(p: *Parser, comptime T: type, t: Token) ParseError!T {
        if (t.tag != .int) return p.fail(t, "expected an integer");
        const s = p.text(t);
        if (T == i64) {
            // Accept u64 bit patterns too (e.g. 0xffffffffffffffff).
            return std.fmt.parseInt(i64, s, 0) catch
                @bitCast(std.fmt.parseInt(u64, s, 0) catch return p.fail(t, "integer literal out of range"));
        }
        return std.fmt.parseInt(T, s, 0) catch p.fail(t, "integer literal out of range");
    }

    fn float(p: *Parser, t: Token) ParseError!f64 {
        return std.fmt.parseFloat(f64, p.text(t)) catch p.fail(t, "invalid float literal");
    }

    fn parseType(p: *Parser) ParseError!ir.Type {
        const t = p.next();
        if (p.isWord(t, "vec")) {
            _ = try p.expect(.langle, "expected '<' after 'vec'");
            const n = try p.int(u32, p.next());
            if (n == 0) return p.fail(t, "vector must have at least one lane");
            try p.expectWord("x", "expected 'x' in vector type");
            const et = p.next();
            const elem = if (et.tag == .ident) std.meta.stringToEnum(ir.Scalar, p.text(et)) else null;
            if (elem == null or elem.? == .void) return p.fail(et, "expected a vector element type");
            _ = try p.expect(.rangle, "expected '>' to close vector type");
            return .vec(n, elem.?);
        }
        if (t.tag == .ident) if (std.meta.stringToEnum(ir.Scalar, p.text(t))) |s| return .of(s);
        return p.fail(t, "expected a type");
    }

    fn isTypeStart(p: *Parser, t: Token) bool {
        return t.tag == .ident and (p.isWord(t, "vec") or std.meta.stringToEnum(ir.Scalar, p.text(t)) != null);
    }

    fn global(p: *Parser) ParseError!void {
        const n = try p.expect(.global, "expected '@name'");
        _ = try p.expect(.colon, "expected ':'");
        const ty = try p.parseType();
        _ = try p.expect(.equal, "expected '='");
        const t = p.next();
        const init: ir.Init = switch (t.tag) {
            .int => .{ .int = try p.int(i64, t) },
            .float => .{ .float = try p.float(t) },
            .string => .{ .bytes = try p.decodeString(t) },
            .ident => if (p.isWord(t, "zeroinit"))
                .zero
            else if (p.isWord(t, "inf") or p.isWord(t, "nan"))
                .{ .float = try p.float(t) }
            else
                return p.fail(t, "expected a constant"),
            else => return p.fail(t, "expected a constant"),
        };
        var g: ir.Global = .{ .name = p.name(n), .ty = ty, .init = init };
        if (p.eatWord("align")) g.@"align" = try p.int(u32, p.next());
        if (p.eatWord("readonly")) g.readonly = true;
        try p.m.addGlobal(g);
    }

    fn decodeString(p: *Parser, t: Token) ParseError![]const u8 {
        const s = p.src[t.start + 1 .. t.end - 1];
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            if (s[i] != '\\') {
                try out.append(p.arena(), s[i]);
                continue;
            }
            if (i + 2 >= s.len) return p.fail(t, "expected two hex digits after '\\'");
            const b = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch return p.fail(t, "expected two hex digits after '\\'");
            try out.append(p.arena(), b);
            i += 2;
        }
        return out.items;
    }

    fn function(p: *Parser) ParseError!void {
        const n = try p.expect(.global, "expected '@name'");
        p.f = try p.m.addFunction(p.name(n), .void);
        p.locals.clearRetainingCapacity();
        p.labels.clearRetainingCapacity();
        p.pending.clearRetainingCapacity();

        _ = try p.expect(.lparen, "expected '('");
        if (!p.eat(.rparen)) {
            while (true) {
                const pt = try p.expect(.local, "expected '%name'");
                _ = try p.expect(.colon, "expected ':'");
                const v = try p.define(pt, try p.parseType());
                var attrs: ir.ParamAttrs = .{};
                while (true) {
                    if (p.eatWord("noalias")) {
                        attrs.@"noalias" = true;
                    } else if (p.eatWord("readonly")) {
                        attrs.readonly = true;
                    } else if (p.eatWord("align")) {
                        attrs.@"align" = try p.parenInt(u32);
                    } else if (p.eatWord("dereferenceable")) {
                        attrs.dereferenceable = try p.parenInt(u64);
                    } else break;
                }
                try p.f.params.append(p.arena(), .{ .value = v, .attrs = attrs });
                if (!p.eat(.comma)) break;
            }
            _ = try p.expect(.rparen, "expected ')'");
        }
        _ = try p.expect(.arrow, "expected '->'");
        p.f.ret = try p.parseType();
        while (true) {
            if (p.eatWord("inline")) {
                p.f.attrs.@"inline" = true;
            } else if (p.eatWord("noinline")) {
                p.f.attrs.@"noinline" = true;
            } else if (p.eatWord("cold")) {
                p.f.attrs.cold = true;
            } else if (p.eatWord("noreturn")) {
                p.f.attrs.noreturn = true;
            } else break;
        }
        if (!p.eat(.lbrace)) return; // declaration

        // Create every block up front (labels starting a line, in order) so
        // branches may refer forward.
        var j = p.i;
        while (p.toks[j].tag != .rbrace and p.toks[j].tag != .eof) : (j += 1) {
            const t = p.toks[j];
            if (t.tag != .label or p.toks[j - 1].line == t.line) continue;
            const gop = try p.labels.getOrPut(p.gpa, p.name(t));
            if (gop.found_existing) return p.fail(t, "duplicate block label");
            gop.value_ptr.* = try p.f.addBlock(p.name(t));
        }
        if (p.f.blocks.items.len == 0) return p.fail(p.toks[j], "function body needs at least one block");
        for (p.f.blocks.items) |_| try p.block();
        _ = try p.expect(.rbrace, "expected '}' after the last block's terminator");
        for (p.pending.items) |pt| if (pt) |t| return p.fail(t, "use of undefined value");
    }

    fn parenInt(p: *Parser, comptime T: type) ParseError!T {
        _ = try p.expect(.lparen, "expected '('");
        const v = try p.int(T, p.next());
        _ = try p.expect(.rparen, "expected ')'");
        return v;
    }

    /// Defines local `t` with type `ty`, resolving earlier forward uses.
    fn define(p: *Parser, t: Token, ty: ir.Type) ParseError!ir.Value {
        const gop = try p.locals.getOrPut(p.gpa, p.name(t));
        if (gop.found_existing) {
            const v = gop.value_ptr.*;
            if (p.pending.items[v.index()] == null) return p.fail(t, "value defined twice");
            p.pending.items[v.index()] = null;
            p.f.values.items[v.index()].ty = ty;
            return v;
        }
        gop.value_ptr.* = try p.f.newValue(ty, p.name(t));
        try p.pending.append(p.gpa, null);
        return gop.value_ptr.*;
    }

    /// Looks up local `t`; an unknown name becomes a forward reference.
    fn use(p: *Parser, t: Token) ParseError!ir.Value {
        const gop = try p.locals.getOrPut(p.gpa, p.name(t));
        if (!gop.found_existing) {
            gop.value_ptr.* = try p.f.newValue(.void, p.name(t));
            try p.pending.append(p.gpa, t);
        }
        return gop.value_ptr.*;
    }

    fn block(p: *Parser) ParseError!void {
        const lt = try p.expect(.label, "expected a block label");
        if (p.toks[p.i - 2].line == lt.line) return p.fail(lt, "a block label must start a line");
        const id = p.labels.get(p.name(lt)).?;
        if (p.eat(.lparen)) {
            while (true) {
                const pt = try p.expect(.local, "expected '%name'");
                _ = try p.expect(.colon, "expected ':'");
                const v = try p.define(pt, try p.parseType());
                try p.f.block(id).params.append(p.arena(), v);
                if (!p.eat(.comma)) break;
            }
            _ = try p.expect(.rparen, "expected ')'");
        }
        _ = try p.expect(.colon, "expected ':' after block label");
        while (true) {
            const t = p.peek();
            if (t.tag == .label or t.tag == .rbrace or t.tag == .eof) return p.fail(t, "block does not end with a terminator");
            const inst = try p.instruction();
            try p.f.block(id).insts.append(p.arena(), inst);
            if (inst.op.isTerminator()) return;
        }
    }

    fn instruction(p: *Parser) ParseError!ir.Inst {
        const first = p.peek();
        var results: std.ArrayList(ir.Value) = .empty;
        if (first.tag == .local) {
            while (true) {
                const rt = try p.expect(.local, "expected '%name'");
                _ = try p.expect(.colon, "expected ':'");
                try results.append(p.arena(), try p.define(rt, try p.parseType()));
                if (!p.eat(.comma)) break;
            }
            _ = try p.expect(.equal, "expected '='");
        }
        const ot = try p.expect(.ident, "expected an opcode");
        const op = std.meta.stringToEnum(ir.Op, p.text(ot)) orelse return p.fail(ot, "unknown opcode");
        var inst: ir.Inst = .{ .op = op, .results = results.items };

        // Modifiers.
        while (p.peek().tag == .ident and p.peek().line == first.line) {
            const t = p.peek();
            const w = p.text(t);
            if ((op == .icmp or op == .fcmp) and inst.pred == .none) {
                if (std.meta.stringToEnum(ir.Pred, w)) |pr| if (pr != .none and pr.isInt() == (op == .icmp)) {
                    inst.pred = pr;
                    _ = p.next();
                    continue;
                };
            }
            if (op == .@"atomic.rmw" and inst.rmw == .none) {
                if (std.meta.stringToEnum(ir.RmwOp, w)) |r| if (r != .none) {
                    inst.rmw = r;
                    _ = p.next();
                    continue;
                };
            }
            if (p.eatWord("atomic")) {
                _ = try p.expect(.lparen, "expected '(' after 'atomic'");
                inst.atomic = try p.order(p.next());
                _ = try p.expect(.rparen, "expected ')'");
                continue;
            }
            inline for (.{ "nuw", "nsw", "fast", "volatile", "signed" }) |flag| {
                if (std.mem.eql(u8, w, flag)) {
                    @field(inst.flags, flag) = true;
                    _ = p.next();
                    break;
                }
            } else break;
        }
        if ((op == .icmp or op == .fcmp) and inst.pred == .none) return p.fail(p.peek(), "expected a comparison predicate");
        if (op == .@"atomic.rmw" and inst.rmw == .none) return p.fail(p.peek(), "expected an atomic.rmw operation");

        // Operands.
        var ops: std.ArrayList(ir.Operand) = .empty;
        var targets: std.ArrayList(ir.Target) = .empty;
        switch (op) {
            .br => try targets.append(p.arena(), try p.target()),
            .cond_br => {
                try ops.append(p.arena(), try p.operand());
                for (0..2) |_| {
                    _ = try p.expect(.comma, "expected ','");
                    try targets.append(p.arena(), try p.target());
                }
            },
            .@"switch" => {
                try ops.append(p.arena(), try p.operand());
                _ = try p.expect(.comma, "expected ','");
                try p.expectWord("default", "expected 'default'");
                try targets.append(p.arena(), try p.target());
                _ = try p.expect(.comma, "expected ','");
                _ = try p.expect(.lbracket, "expected '['");
                if (!p.eat(.rbracket)) {
                    while (true) {
                        const key = try p.int(i64, p.next());
                        _ = try p.expect(.colon, "expected ':'");
                        var t = try p.target();
                        t.key = key;
                        try targets.append(p.arena(), t);
                        if (!p.eat(.comma)) break;
                    }
                    _ = try p.expect(.rbracket, "expected ']'");
                }
            },
            else => if (op.isCall()) {
                try ops.append(p.arena(), try p.operand());
                try p.args(&ops);
            } else if (p.peek().line == first.line and p.peek().tag != .eof) {
                while (true) {
                    if (p.eatWord("align")) {
                        inst.@"align" = try p.int(u32, p.next());
                    } else try ops.append(p.arena(), try p.operand());
                    if (!p.eat(.comma)) break;
                }
            },
        }
        const end = p.peek();
        if (end.tag != .eof and end.line == first.line) return p.fail(end, "unexpected token after instruction");
        inst.operands = ops.items;
        inst.targets = targets.items;
        return inst;
    }

    /// `(` operand list `)` appended to `out`.
    fn args(p: *Parser, out: *std.ArrayList(ir.Operand)) ParseError!void {
        _ = try p.expect(.lparen, "expected '('");
        if (p.eat(.rparen)) return;
        while (true) {
            try out.append(p.arena(), try p.operand());
            if (!p.eat(.comma)) break;
        }
        _ = try p.expect(.rparen, "expected ')'");
    }

    fn target(p: *Parser) ParseError!ir.Target {
        const t = try p.expect(.label, "expected '^block'");
        const id = p.labels.get(p.name(t)) orelse return p.fail(t, "undefined block");
        var list: std.ArrayList(ir.Operand) = .empty;
        if (p.peek().tag == .lparen) try p.args(&list);
        return .{ .block = id, .args = list.items };
    }

    fn order(p: *Parser, t: Token) ParseError!ir.Order {
        if (t.tag == .ident) if (std.meta.stringToEnum(ir.Order, p.text(t))) |o| if (o != .none) return o;
        return p.fail(t, "expected a memory order");
    }

    fn operand(p: *Parser) ParseError!ir.Operand {
        const t = p.peek();
        switch (t.tag) {
            .local => return .{ .value = try p.use(p.next()) },
            .global => return .{ .symbol = p.name(p.next()) },
            .int => return .{ .int = try p.int(i64, p.next()) },
            .float => return .{ .float = try p.float(p.next()) },
            .ident => {
                if (p.isTypeStart(t)) return .{ .type = try p.parseType() };
                if (p.isWord(t, "inf") or p.isWord(t, "nan")) return .{ .float = try p.float(p.next()) };
                if (std.meta.stringToEnum(ir.Order, p.text(t))) |o| if (o != .none) {
                    _ = p.next();
                    return .{ .order = o };
                };
                return p.fail(t, "expected an operand");
            },
            else => return p.fail(t, "expected an operand"),
        }
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn printToString(m: *const ir.Module) ![]u8 {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try print(m, &out.writer);
    return out.toOwnedSlice();
}

/// Parses `src`, checks it prints back byte-identically, and returns the module.
fn expectRoundTrip(src: []const u8) !ir.Module {
    var diag: Diag = .{};
    var m = parse(testing.allocator, src, &diag) catch |e| {
        std.debug.print("parse error {d}:{d}: {s}\n", .{ diag.line, diag.col, diag.msg });
        return e;
    };
    errdefer m.deinit();
    const printed = try printToString(&m);
    defer testing.allocator.free(printed);
    try testing.expectEqualStrings(src, printed);
    return m;
}

const corpus = [_][]const u8{
    // Globals, integer and checked arithmetic.
    \\global @counter: i64 = 0 align 8
    \\global @pi: f64 = 3.14159 readonly
    \\global @msg: i8 = "hi\0a\22" align 1 readonly
    \\global @table: i32 = zeroinit
    \\global @big: i64 = -1
    \\
    \\fn @int_ops(%a: i32, %b: i32) -> i32 {
    \\^entry:
    \\  %r0: i32 = add nuw nsw %a, %b
    \\  %r1: i32 = sub nsw %r0, %b
    \\  %r2: i32 = mul nuw %r1, %a
    \\  %r3: i32 = udiv %r2, %b
    \\  %r4: i32 = sdiv %r3, %b
    \\  %r5: i32 = urem %r4, %b
    \\  %r6: i32 = srem %r5, %b
    \\  %r7: i32 = and %r6, %a
    \\  %r8: i32 = or %r7, %a
    \\  %r9: i32 = xor %r8, %a
    \\  %r10: i32 = shl nuw %r9, %b
    \\  %r11: i32 = lshr %r10, %b
    \\  %r12: i32 = ashr %r11, %b
    \\  %t0: i32 = add.trap %r12, %a
    \\  %t1: i32 = sub.trap %t0, %a
    \\  %t2: i32 = mul.trap %t1, %a
    \\  ret %t2
    \\}
    \\
    ,
    // Float arithmetic (scalar and lane-wise) and unconditional branches.
    \\fn @float_ops(%x: f64, %y: f64, %v: vec<4 x f32>) -> f64 {
    \\^entry:
    \\  %k: f64 = const 0.5
    \\  %one: f64 = const 1.0
    \\  %ninf: f64 = const -inf
    \\  %f0: f64 = fadd %x, %y
    \\  %f1: f64 = fsub fast %f0, %k
    \\  %f2: f64 = fmul %f1, %one
    \\  %f3: f64 = fdiv %f2, %ninf
    \\  %f4: f64 = frem %f3, %y
    \\  %f5: f64 = fneg %f4
    \\  %f6: f64 = fma %f5, %x, %y
    \\  %w: vec<4 x f32> = fadd %v, %v
    \\  br ^out(%f6)
    \\^out(%r: f64):
    \\  ret %r
    \\}
    \\
    ,
    // Compare and convert.
    \\fn @cmp_conv(%a: i32, %x: f64, %p: ptr) -> i1 {
    \\^entry:
    \\  %c0: i1 = icmp eq %a, %a
    \\  %c1: i1 = icmp sge %a, %a
    \\  %c2: i1 = fcmp olt %x, %x
    \\  %c3: i1 = fcmp uno %x, %x
    \\  %n0: i8 = trunc %a
    \\  %n1: i64 = zext %n0
    \\  %n2: i64 = sext %a
    \\  %n3: f32 = fptrunc %x
    \\  %n4: f64 = fpext %n3
    \\  %n5: i32 = fptoui.sat %x
    \\  %n6: i32 = fptosi.sat %x
    \\  %n7: f64 = uitofp %a
    \\  %n8: f64 = sitofp %a
    \\  %n9: i64 = bitcast %x
    \\  %n10: i64 = ptrtoint %p
    \\  %n11: ptr = inttoptr %n10
    \\  ret %c0
    \\}
    \\
    ,
    // Memory, SoA, bit fields, checks, handles.
    \\fn @memory(%dst: ptr noalias align(16) dereferenceable(64), %src: ptr readonly, %n: i64) -> void {
    \\^entry:
    \\  %slot: ptr = alloca i64, align 8
    \\  %v: i64 = load %src, align 8
    \\  %vv: i64 = load volatile atomic(acquire) %src, align 8
    \\  store %v, %slot, align 8
    \\  store volatile atomic(release) %vv, %dst
    \\  %q: ptr = gep %dst, %n, 8
    \\  memcpy %q, %src, %n
    \\  %zero: i8 = const 0
    \\  memset %dst, %zero, %n
    \\  %col: ptr = soa.col %dst, 2
    \\  %e: f32 = soa.load %dst, %n, 1
    \\  soa.store %dst, %n, 1, %e
    \\  %u: i32 = trunc %v
    \\  %bx: i32 = bf.extract signed %u, 3, 5
    \\  %bi: i32 = bf.insert %u, %bx, 3, 5
    \\  bounds %n, %v
    \\  %idx: i32, %ok: i1 = handle.lookup %src, %n
    \\  cond_br %ok, ^done, ^fail
    \\^fail:
    \\  trap 2, 17
    \\  unreachable
    \\^done:
    \\  ret
    \\}
    \\
    ,
    // Vector.
    \\fn @vector(%p: ptr, %x: f32, %m: vec<4 x i1>) -> f32 {
    \\^entry:
    \\  %s: vec<4 x f32> = splat %x
    \\  %l: vec<4 x f32> = load.masked %p, %m, %s, align 16
    \\  %e: f32 = extract %l, 0
    \\  %i: vec<4 x f32> = insert %l, %e, 3
    \\  %sh: vec<4 x f32> = shuffle %l, %i, 0, 4, 1, 5
    \\  %sel: vec<4 x f32> = select %m, %sh, %s
    \\  store.masked %sel, %p, %m, align 16
    \\  %ra: f32 = reduce.add %sel
    \\  %rm: f32 = reduce.mul %sel
    \\  %rn: f32 = reduce.min %sel
    \\  %rx: f32 = reduce.max %sel
    \\  %bits: vec<4 x i32> = bitcast %sel
    \\  %rand: i32 = reduce.and %bits
    \\  %ror: i32 = reduce.or %bits
    \\  ret %ra
    \\}
    \\
    ,
    // Calls, concurrency, atomics, switch and conditional branches.
    \\fn @callee(%a: i32) -> i32 inline cold
    \\
    \\fn @calls(%fp: ptr, %a: i32, %n: i64, %p: ptr) -> i32 {
    \\^entry:
    \\  %r0: i32 = call @callee(%a)
    \\  %r1: i32 = call.indirect %fp(%r0)
    \\  %nur: ptr = nursery.begin
    \\  spawn @callee(%r1)
    \\  nursery.end %nur
    \\  %zero: i64 = const 0
    \\  %chunk: i64 = const 64
    \\  %it: i64 = pfor.begin %zero, %n, %chunk
    \\  pfor.end
    \\  %old: i32 = atomic.rmw add %p, %a, seq_cst
    \\  %prev: i32, %ok: i1 = cmpxchg %p, %old, %a, acq_rel, relaxed
    \\  fence seq_cst
    \\  switch %a, default ^exit(%a), [0: ^loop(%zero), -1: ^exit(%r1)]
    \\^loop(%i: i64):
    \\  %next: i64 = add %i, %chunk
    \\  %more: i1 = icmp ult %next, %n
    \\  cond_br %more, ^loop(%next), ^tail
    \\^tail:
    \\  %t: i32 = call.tail @callee(%a)
    \\  ret %t
    \\^exit(%x: i32):
    \\  ret %x
    \\}
    \\
    ,
};

test "round-trip covers every opcode" {
    var seen: std.EnumSet(ir.Op) = .empty;
    for (corpus) |src| {
        var m = try expectRoundTrip(src);
        defer m.deinit();
        for (m.functions.items) |f| for (f.blocks.items) |b| for (b.insts.items) |inst| seen.insert(inst.op);
    }
    var it = seen.complement().iterator();
    while (it.next()) |op| {
        std.debug.print("opcode not covered: {s}\n", .{@tagName(op)});
        return error.TestUnexpectedResult;
    }
}

test "parsed structure matches the text" {
    var m = try expectRoundTrip(corpus[3]);
    defer m.deinit();
    const f = m.findFunction("memory").?;
    try testing.expect(f.params.items[0].attrs.@"noalias");
    try testing.expectEqual(@as(u64, 64), f.params.items[0].attrs.dereferenceable);
    try testing.expect(f.params.items[1].attrs.readonly);
    const entry = f.blocks.items[0];
    const vv = entry.insts.items[2];
    try testing.expect(vv.flags.@"volatile");
    try testing.expectEqual(ir.Order.acquire, vv.atomic);
    try testing.expectEqual(@as(u32, 8), vv.@"align");
    try testing.expect(entry.insts.items[0].operands[0].type.eql(.of(.i64)));
    const lookup = entry.insts.items[16];
    try testing.expectEqual(@as(usize, 2), lookup.results.len);
    try testing.expect(f.typeOf(lookup.results[1]).eql(.of(.i1)));
    try testing.expectEqualStrings("done", f.blocks.items[entry.terminator().?.targets[0].block.index()].name);

    var g = try expectRoundTrip(corpus[0]);
    defer g.deinit();
    try testing.expectEqualStrings("hi\n\"", g.findGlobal("msg").?.init.bytes);
    try testing.expect(g.findGlobal("pi").?.readonly);
}

test "parser normalizes comments, spacing and forward references" {
    const src =
        \\; leading comment
        \\fn @f(%c: i1) -> i64 noinline {   ; trailing comment
        \\^a:
        \\  cond_br %c,^b,   ^c(%late)
        \\^b:
        \\  %late:i64 = const 0x10
        \\  br ^c(%late)
        \\^c(%x: i64):
        \\  ret %x
        \\}
    ;
    var diag: Diag = .{};
    var m = try parse(testing.allocator, src, &diag);
    defer m.deinit();
    const printed = try printToString(&m);
    defer testing.allocator.free(printed);
    try testing.expectEqualStrings(
        \\fn @f(%c: i1) -> i64 noinline {
        \\^a:
        \\  cond_br %c, ^b, ^c(%late)
        \\^b:
        \\  %late: i64 = const 16
        \\  br ^c(%late)
        \\^c(%x: i64):
        \\  ret %x
        \\}
        \\
    , printed);
    var again = try expectRoundTrip(printed);
    defer again.deinit();
}

test "builder output prints and re-parses" {
    var m = try ir.Module.init(testing.allocator);
    defer m.deinit();
    const f = try m.addFunction("twice", .of(.f32));
    const x = try f.addParam(.of(.f32), "x", .{ .readonly = true });
    var b: @import("builder.zig").Builder = .init(f, try f.addBlock("entry"));
    const two = try b.constFloat(.of(.f32), 2);
    const r = try b.binary(.fmul, .{}, x, two);
    try b.ret(r);
    const printed = try printToString(&m);
    defer testing.allocator.free(printed);
    try testing.expectEqualStrings(
        \\fn @twice(%x: f32 readonly) -> f32 {
        \\^entry:
        \\  %1: f32 = const 2.0
        \\  %2: f32 = fmul %x, %1
        \\  ret %2
        \\}
        \\
    , printed);
    var again = try expectRoundTrip(printed);
    defer again.deinit();
}

test "parse errors report location" {
    const cases = [_]struct { src: []const u8, line: u32, col: u32, msg: []const u8 }{
        .{ .src = "fn @f() -> void {\n^a:\n  frob\n}", .line = 3, .col = 3, .msg = "unknown opcode" },
        .{ .src = "fn @f() -> void {\n^a:\n  br ^nope\n}", .line = 3, .col = 6, .msg = "undefined block" },
        .{ .src = "fn @f() -> i32 {\n^a:\n  ret %x\n}", .line = 3, .col = 7, .msg = "use of undefined value" },
        .{ .src = "fn @f(%x: i32) -> void {\n^a:\n  %x: i32 = const 1\n  ret\n}", .line = 3, .col = 3, .msg = "value defined twice" },
        .{ .src = "fn @f() -> void {\n^a:\n  %y: i32 = const 1\n}", .line = 4, .col = 1, .msg = "block does not end with a terminator" },
        .{ .src = "fn @f(%a: i32) -> i1 {\n^a:\n  %c: i1 = icmp olt %a, %a\n  ret %c\n}", .line = 3, .col = 17, .msg = "expected a comparison predicate" },
        .{ .src = "global @g: vec<0 x i8> = 0", .line = 1, .col = 12, .msg = "vector must have at least one lane" },
        .{ .src = "fn @f() -> void {\n^a:\n  ret ret\n}", .line = 3, .col = 7, .msg = "expected an operand" },
    };
    for (cases) |c| {
        var diag: Diag = .{};
        try testing.expectError(error.ParseError, parse(testing.allocator, c.src, &diag));
        try testing.expectEqualStrings(c.msg, diag.msg);
        try testing.expectEqual(c.line, diag.line);
        try testing.expectEqual(c.col, diag.col);
    }
}
