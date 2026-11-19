//! Exhaustiveness and reachability of patterns (§6.6.3, B.4): the
//! pattern-matrix usefulness algorithm over enum variants, `bool`, integer
//! ranges, tuples and structs.
//!
//! A pattern vector `q` is *useful* with respect to the rows of a matrix if
//! some value matches `q` but no row. `useful` answers that and returns a
//! witness: a vector of patterns matching such values. A `match` is
//! exhaustive if `_` is not useful after its unguarded arms; an arm is
//! unreachable (W0302) if it is not useful after the unguarded arms before
//! it. Integer columns are split into the disjoint ranges the rows'
//! endpoints delimit, so each range is one constructor.

const std = @import("std");
const Ast = @import("../ast/Ast.zig");
const Types = @import("types.zig");
const convert = @import("convert.zig");
const emit_tir = @import("emit_tir.zig");

const Node = Ast.Node;
const TypeId = Types.TypeId;
const Checker = emit_tir.Checker;
const Error = emit_tir.Error;

/// The integers (or `bool` values, 0 and 1) `lo..=hi`.
pub const Range = struct { lo: i128, hi: i128 };

/// A constructor of a type's values.
pub const Ctor = union(enum) {
    /// Variant `index` of an enum; 0 for the only constructor of a tuple or struct.
    variant: u32,
    range: Range,
};

/// A checked pattern (§3.7).
pub const Pat = struct {
    /// The type of the values it matches; `.err` after a diagnostic.
    ty: TypeId,
    shape: Shape,
    /// The pattern node; `.none` for a synthesized pattern.
    node: Node.Index = .none,
    /// For a binding (`x`, `mut x`, a field shorthand): the binding node.
    bind: Node.Index = .none,

    pub const Shape = union(enum) {
        /// `_` or a binding: matches every value.
        wild,
        /// Constructor `ctor` with one sub-pattern per field, in declaration order.
        ctor: struct { ctor: Ctor, args: []const Pat },
        /// `p1 | p2 | ...`.
        alt: []const Pat,
    };

    pub fn wild(ty: TypeId) Pat {
        return .{ .ty = ty, .shape = .wild };
    }
};

/// The values of a type, as constructors.
pub const Space = union(enum) {
    /// Enum variants, or the one constructor of a tuple or struct.
    sum: Sum,
    /// Integers or `bool` in `range`.
    int: struct { range: Range, is_bool: bool },
    /// Values patterns cannot name (floats, `str`, ...): only `_` and bindings match.
    any,
};

pub const Sum = struct {
    kind: enum { @"enum", tuple, @"struct" },
    /// Variant names (enum) or field names (struct); empty for a tuple.
    names: []const []const u8,
    /// The field types of each constructor.
    fields: []const []const TypeId,
};

/// The constructors of `ty` (distinct wrappers removed, §4.7).
pub fn spaceOf(c: *Checker, ty: TypeId) Error!Space {
    const u = c.underlying(ty);
    if (u == .bool) return .{ .int = .{ .range = .{ .lo = 0, .hi = 1 }, .is_bool = true } };
    if (convert.intInfo(c.types, c.items.options.ptr_bits, u)) |i| {
        const r: Range = if (i.signedness == .signed)
            .{ .lo = -(@as(i128, 1) << @intCast(i.bits - 1)), .hi = (@as(i128, 1) << @intCast(i.bits - 1)) - 1 }
        else
            .{ .lo = 0, .hi = (@as(i128, 1) << @intCast(i.bits)) - 1 };
        return .{ .int = .{ .range = r, .is_bool = false } };
    }
    switch (c.types.get(u)) {
        .tuple => |t| return .{ .sum = .{ .kind = .tuple, .names = &.{}, .fields = try one(c, t.elems) } },
        .nominal => |nm| {
            if (nm.lang == .option or nm.lang == .result) {
                // `Option<T> { some(T), none }`, `Result<T, E> { ok(T), err(E) }` (§14.1).
                const names: []const []const u8 = if (nm.lang == .option) &.{ "some", "none" } else &.{ "ok", "err" };
                const fields = try c.arena.alloc([]const TypeId, 2);
                for (fields, 0..) |*f, i| f.* = if (i < nm.args.len and nm.args[i] == .type) try c.arena.dupe(TypeId, &.{nm.args[i].type}) else &.{};
                if (nm.lang == .option) fields[1] = &.{};
                return .{ .sum = .{ .kind = .@"enum", .names = names, .fields = fields } };
            }
            if (c.items.enumOf(u)) |e| {
                const names = try c.arena.alloc([]const u8, e.variants.len);
                const fields = try c.arena.alloc([]const TypeId, e.variants.len);
                for (e.variants, names, fields) |v, *n, *f| {
                    n.* = v.name;
                    f.* = v.payload;
                }
                return .{ .sum = .{ .kind = .@"enum", .names = names, .fields = fields } };
            }
            if (c.items.structOf(u)) |s| {
                const names = try c.arena.alloc([]const u8, s.fields.len);
                const types = try c.arena.alloc(TypeId, s.fields.len);
                for (s.fields, names, types) |f, *n, *t| {
                    n.* = f.name;
                    t.* = f.type;
                }
                return .{ .sum = .{ .kind = .@"struct", .names = names, .fields = try one(c, types) } };
            }
            return .any;
        },
        else => return .any,
    }
}

fn one(c: *Checker, tys: []const TypeId) Error![]const []const TypeId {
    const out = try c.arena.alloc([]const TypeId, 1);
    out[0] = tys;
    return out;
}

// ---------------------------------------------------------------------------
// Entry points

/// Up to `max` patterns of type `ty` that no pattern of `rows` matches;
/// empty if `rows` are exhaustive. Each witness covers values the earlier
/// ones do not.
pub fn missing(c: *Checker, rows: []const Pat, ty: TypeId, max: usize) Error![]const Pat {
    var matrix: std.ArrayList([]const Pat) = .empty;
    for (rows) |*r| try matrix.append(c.arena, r[0..1]);
    var out: std.ArrayList(Pat) = .empty;
    while (out.items.len < max) {
        const w = try useful(c, matrix.items, &.{.wild(ty)}) orelse break;
        try out.append(c.arena, w[0]);
        try matrix.append(c.arena, w[0..1]);
    }
    return out.items;
}

/// Whether some value matches `p` but none of `rows`.
pub fn isUseful(c: *Checker, rows: []const Pat, p: Pat) Error!bool {
    const matrix = try c.arena.alloc([]const Pat, rows.len);
    for (matrix, rows) |*m, *r| m.* = r[0..1];
    return try useful(c, matrix, &.{p}) != null;
}

// ---------------------------------------------------------------------------
// Usefulness

/// A vector refining `q` whose values match no row of `rows`, or null if
/// there is none. All rows and `q` have the same column types.
fn useful(c: *Checker, rows_in: []const []const Pat, q: []const Pat) Error!?[]Pat {
    if (q.len == 0) return if (rows_in.len == 0) try c.arena.alloc(Pat, 0) else null;
    // A row with an alternative at its head is one row per alternative.
    var rows: std.ArrayList([]const Pat) = .empty;
    for (rows_in) |r| try expandHead(c, &rows, r);

    const head = q[0];
    const rest = q[1..];
    switch (head.shape) {
        .alt => |alts| {
            for (alts) |a| if (try useful(c, rows.items, try prepend(c, &.{a}, rest))) |w| return w;
            return null;
        },
        .ctor => |k| switch (k.ctor) {
            .variant => return specialize(c, rows.items, head.ty, k.ctor, k.args, rest),
            .range => |r| return splitRange(c, rows.items, head.ty, r, rest),
        },
        .wild => {},
    }
    switch (try spaceOf(c, head.ty)) {
        .int => |i| return splitRange(c, rows.items, head.ty, i.range, rest),
        .sum => |s| {
            const used = try c.arena.alloc(bool, s.fields.len);
            @memset(used, false);
            for (rows.items) |r| switch (r[0].shape) {
                .ctor => |k| if (k.ctor == .variant and k.ctor.variant < used.len) {
                    used[k.ctor.variant] = true;
                },
                else => {},
            };
            const unused = std.mem.indexOfScalar(bool, used, false) orelse {
                // Every constructor appears: one of them must be useful.
                for (s.fields, 0..) |f, v| {
                    if (try specialize(c, rows.items, head.ty, .{ .variant = @intCast(v) }, try wilds(c, f), rest)) |w| return w;
                }
                return null;
            };
            const w = try useful(c, try defaultRows(c, rows.items), rest) orelse return null;
            const args = try wilds(c, s.fields[unused]);
            return try prepend(c, &.{.{ .ty = head.ty, .shape = .{ .ctor = .{ .ctor = .{ .variant = @intCast(unused) }, .args = args } } }}, w);
        },
        .any => {
            const w = try useful(c, try defaultRows(c, rows.items), rest) orelse return null;
            return try prepend(c, &.{.wild(head.ty)}, w);
        },
    }
}

/// `r` with its head alternatives (nested ones too) as separate rows.
fn expandHead(c: *Checker, out: *std.ArrayList([]const Pat), r: []const Pat) Error!void {
    if (r.len == 0 or r[0].shape != .alt) return out.append(c.arena, r);
    for (r[0].shape.alt) |a| try expandHead(c, out, try prepend(c, &.{a}, r[1..]));
}

/// Usefulness of `ctor(args) ++ rest` (`args` empty for a range): the rows
/// that match `ctor`, with its fields as new columns.
fn specialize(c: *Checker, rows: []const []const Pat, ty: TypeId, ctor: Ctor, args: []const Pat, rest: []const Pat) Error!?[]Pat {
    var spec: std.ArrayList([]const Pat) = .empty;
    for (rows) |r| switch (r[0].shape) {
        .wild => try spec.append(c.arena, try prepend(c, try wilds(c, try argTypes(c, args)), r[1..])),
        .ctor => |k| if (covers(k.ctor, ctor)) try spec.append(c.arena, try prepend(c, k.args, r[1..])),
        .alt => unreachable, // expanded by `useful`
    };
    const w = try useful(c, spec.items, try prepend(c, args, rest)) orelse return null;
    const fields = try c.arena.dupe(Pat, w[0..args.len]);
    return try prepend(c, &.{.{ .ty = ty, .shape = .{ .ctor = .{ .ctor = ctor, .args = fields } } }}, w[args.len..]);
}

/// Row constructor `row` matches every value of constructor `q` (`q` is a
/// variant, or a range that no row endpoint splits).
fn covers(row: Ctor, q: Ctor) bool {
    return switch (q) {
        .variant => |v| row == .variant and row.variant == v,
        .range => |r| row == .range and row.range.lo <= r.lo and r.hi <= row.range.hi,
    };
}

/// Usefulness of the integers `r` in the head column: `r` is split at the
/// endpoints of the rows' ranges and each part is tried as a constructor.
fn splitRange(c: *Checker, rows: []const []const Pat, ty: TypeId, r: Range, rest: []const Pat) Error!?[]Pat {
    var points: std.ArrayList(i128) = .empty;
    try points.appendSlice(c.arena, &.{ r.lo, r.hi + 1 });
    for (rows) |row| switch (row[0].shape) {
        .ctor => |k| if (k.ctor == .range) {
            const h = k.ctor.range;
            if (h.hi < r.lo or h.lo > r.hi) continue;
            try points.appendSlice(c.arena, &.{ @max(h.lo, r.lo), @min(h.hi, r.hi) + 1 });
        },
        else => {},
    };
    std.mem.sort(i128, points.items, {}, std.sort.asc(i128));
    var i: usize = 0;
    while (i + 1 < points.items.len) : (i += 1) {
        const lo = points.items[i];
        const next = points.items[i + 1];
        if (next == lo) continue;
        if (try specialize(c, rows, ty, .{ .range = .{ .lo = lo, .hi = next - 1 } }, &.{}, rest)) |w| return w;
    }
    return null;
}

/// The rows whose head is `_`, without it.
fn defaultRows(c: *Checker, rows: []const []const Pat) Error![]const []const Pat {
    var out: std.ArrayList([]const Pat) = .empty;
    for (rows) |r| if (r[0].shape == .wild) try out.append(c.arena, r[1..]);
    return out.items;
}

fn wilds(c: *Checker, tys: []const TypeId) Error![]Pat {
    const out = try c.arena.alloc(Pat, tys.len);
    for (out, tys) |*p, t| p.* = .wild(t);
    return out;
}

fn argTypes(c: *Checker, args: []const Pat) Error![]const TypeId {
    const out = try c.arena.alloc(TypeId, args.len);
    for (out, args) |*t, a| t.* = a.ty;
    return out;
}

fn prepend(c: *Checker, front: []const Pat, rest: []const Pat) Error![]Pat {
    return std.mem.concat(c.arena, Pat, &.{ front, rest });
}

// ---------------------------------------------------------------------------
// Formatting

/// Writes `ps` as source patterns, separated by `, `, for a diagnostic.
pub fn print(c: *Checker, ps: []const Pat) Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(c.arena);
    for (ps, 0..) |p, i| {
        if (i > 0) out.writer.writeAll(", ") catch return error.OutOfMemory;
        out.writer.writeByte('`') catch return error.OutOfMemory;
        try write(c, &out.writer, p);
        out.writer.writeByte('`') catch return error.OutOfMemory;
    }
    return out.written();
}

fn write(c: *Checker, w: *std.Io.Writer, p: Pat) Error!void {
    writeOrFail(c, w, p) catch |e| switch (e) {
        error.WriteFailed => return error.OutOfMemory,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

fn writeOrFail(c: *Checker, w: *std.Io.Writer, p: Pat) (Error || std.Io.Writer.Error)!void {
    const k = switch (p.shape) {
        .wild => return w.writeAll("_"),
        .alt => |alts| {
            for (alts, 0..) |a, i| {
                if (i > 0) try w.writeAll(" | ");
                try writeOrFail(c, w, a);
            }
            return;
        },
        .ctor => |k| k,
    };
    switch (try spaceOf(c, p.ty)) {
        .int => |i| {
            const r = k.ctor.range;
            if (i.is_bool) return w.writeAll(if (r.lo != r.hi) "_" else if (r.lo == 1) "true" else "false");
            if (r.lo == r.hi) return w.print("{d}", .{r.lo});
            return w.print("{d}..={d}", .{ r.lo, r.hi });
        },
        .sum => |s| {
            const v = k.ctor.variant;
            switch (s.kind) {
                .@"enum" => {
                    try w.print(".{s}", .{s.names[v]});
                    if (s.fields[v].len > 0) try writeList(c, w, "(", k.args, ")");
                },
                .tuple => try writeList(c, w, "(", k.args, ")"),
                .@"struct" => {
                    try w.print("{s} {{", .{try c.tyName(p.ty)});
                    for (k.args, s.names) |a, name| if (a.shape != .wild) {
                        try w.print(" {s}: ", .{name});
                        try writeOrFail(c, w, a);
                        try w.writeAll(",");
                    };
                    try w.writeAll(" .. }");
                },
            }
        },
        .any => try w.writeAll("_"),
    }
}

fn writeList(c: *Checker, w: *std.Io.Writer, open: []const u8, ps: []const Pat, close: []const u8) (Error || std.Io.Writer.Error)!void {
    try w.writeAll(open);
    for (ps, 0..) |a, i| {
        if (i > 0) try w.writeAll(", ");
        try writeOrFail(c, w, a);
    }
    try w.writeAll(close);
}
