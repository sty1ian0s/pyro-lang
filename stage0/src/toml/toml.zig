//! TOML v1.0 documents (§13.2, §13.4): a typed tree whose nodes carry byte spans,
//! a strict parser, and a serializer that reproduces unedited documents byte for byte.
//!
//! Every node of a parsed `Document` lives in the document's arena. Strings are
//! decoded (escapes resolved); spans index the original source.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const parse = @import("parse.zig").parse;
pub const ParseError = @import("parse.zig").Error;
pub const Diagnostic = @import("parse.zig").Diagnostic;
pub const writeCanonical = @import("write.zig").writeCanonical;
pub const writeValue = @import("write.zig").writeValue;

/// Half-open byte range `[start, end)` into the source text.
pub const Span = struct {
    start: u32,
    end: u32,

    pub const none: Span = .{ .start = 0, .end = 0 };

    pub fn slice(s: Span, source: []const u8) []const u8 {
        return source[s.start..s.end];
    }
};

/// 1-based line and column; the column counts Unicode scalar values (§2, diagnostics).
pub const LineCol = struct { line: u32, col: u32 };

/// Maps a byte offset of `source` to a 1-based line/column. A CRLF pair ends one line.
pub fn lineCol(source: []const u8, offset: u32) LineCol {
    var lc: LineCol = .{ .line = 1, .col = 1 };
    for (source[0..offset]) |c| {
        if (c == '\n') {
            lc = .{ .line = lc.line + 1, .col = 1 };
        } else if (c & 0xC0 != 0x80 and c != '\r') {
            lc.col += 1; // count lead bytes only, so one scalar value = one column
        }
    }
    return lc;
}

/// A value node. `span` covers the value's source text: the literal for scalars,
/// `[`..`]` / `{`..`}` for inline arrays and tables, the header (or the first key
/// that created it) for other tables. Built-by-hand values use `Span.none`.
pub const Value = struct {
    span: Span = .none,
    data: Data,
    /// Set by `set`; `Document.write` emits this value from `data` instead of the source.
    edited: bool = false,

    /// Replaces the value; `Document.write` then writes `data` inline in place of the
    /// old source text. Parsed `[header]` tables and arrays of tables have no single
    /// source text to replace, so editing them whole fails; edit their entries instead.
    pub fn set(v: *Value, data: Data) error{EditNotRepresentable}!void {
        // Judge from the parsed node only: an edited value is always spliced as an inline value.
        const section = !v.edited and switch (v.data) {
            .table => |t| t.kind != .inline_table,
            .array => |a| a.kind == .tables,
            else => false,
        };
        if (section and v.span.end > v.span.start) return error.EditNotRepresentable;
        v.data = data;
        v.edited = true;
    }
};

pub const Data = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    datetime: Datetime,
    array: *Array,
    table: *Table,
};

pub const Array = struct {
    items: std.ArrayList(Value) = .empty,
    kind: Kind = .inline_array,

    pub const Kind = enum {
        /// `[a, b]` value syntax; immutable after parsing.
        inline_array,
        /// `[[name]]` array of tables.
        tables,
    };
};

pub const Table = struct {
    /// Entries in insertion (source) order.
    entries: std.array_hash_map.String(Entry) = .empty,
    kind: Kind = .header,
    /// Parser bookkeeping: defined by a header, or by dotted keys in a closed section,
    /// so a later `[header]` naming it is a redefinition.
    explicit: bool = false,
    /// Parser bookkeeping: inline table (or inside one); cannot be extended.
    frozen: bool = false,

    pub const Kind = enum {
        /// `{ ... }` value syntax.
        inline_table,
        /// `[name]` header, an `[[name]]` element, or the root table.
        header,
        /// Created only as a prefix of a header, e.g. `a` in `[a.b]`.
        implicit,
        /// Created by a dotted key, e.g. `a` in `a.b = 1`.
        dotted,
    };

    pub const Entry = struct {
        /// Span of this key segment where the entry was first created.
        key_span: Span = .none,
        value: Value,
    };

    pub fn get(t: *const Table, key: []const u8) ?*Value {
        const e = t.entries.getPtr(key) orelse return null;
        return &e.value;
    }

    /// Adds or replaces an entry. `key` and `value` must outlive the table.
    /// shortcut: `Document.write` does not show entries added to a parsed document;
    /// add insertion splicing when a task needs to add keys to a hand-edited file.
    pub fn put(t: *Table, gpa: Allocator, key: []const u8, value: Value) Allocator.Error!void {
        try t.entries.put(gpa, key, .{ .value = value });
    }
};

/// A TOML date-time. Which parts are present selects the TOML type:
/// date+time+offset = offset date-time, date+time = local date-time,
/// date only = local date, time only = local time.
pub const Datetime = struct {
    date: ?Date = null,
    time: ?Time = null,
    /// Minutes east of UTC; `Z` is 0.
    offset: ?i16 = null,

    pub const Date = struct { year: u16, month: u8, day: u8 };
    /// Fractional seconds beyond nanoseconds are truncated.
    pub const Time = struct { hour: u8, minute: u8, second: u8, nanosecond: u32 = 0 };
};

/// A parsed (or hand-built) TOML document that owns all its nodes.
pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    /// Copy of the parsed text; null for a document built by hand.
    source: ?[]const u8,
    root: *Table,

    /// An empty document to fill by hand; written with `writeCanonical`.
    pub fn init(gpa: Allocator) Allocator.Error!Document {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const root = try arena.allocator().create(Table);
        root.* = .{};
        return .{ .arena = arena, .source = null, .root = root };
    }

    pub fn deinit(doc: *Document) void {
        doc.arena.deinit();
        doc.* = undefined;
    }

    /// Allocator for nodes added to this document; freed by `deinit`.
    pub fn allocator(doc: *Document) Allocator {
        return doc.arena.allocator();
    }

    /// Writes the document. A parsed document is reproduced byte for byte except
    /// that every value marked `edited` is re-serialized in place. A hand-built
    /// document is written canonically.
    pub fn write(doc: *const Document, w: *std.Io.Writer) std.Io.Writer.Error!void {
        return @import("write.zig").writeDocument(doc, w);
    }
};

test "lineCol is 1-based and counts scalar values" {
    const src = "a = 1\r\nb = \"é\" x";
    try std.testing.expectEqual(LineCol{ .line = 1, .col = 1 }, lineCol(src, 0));
    try std.testing.expectEqual(LineCol{ .line = 2, .col = 1 }, lineCol(src, 7));
    // 'x' follows the 2-byte 'é', '"' and ' ': byte 12..13 is é, x at byte 16.
    try std.testing.expectEqual(LineCol{ .line = 2, .col = 9 }, lineCol(src, 16));
}

test "spans map to line and column" {
    var diag: Diagnostic = undefined;
    var doc = try parse(std.testing.allocator, "[pkg]\nname = \"x\"\n  version = 3\n", &diag);
    defer doc.deinit();
    const pkg = doc.root.get("pkg").?.data.table;
    const v = pkg.entries.get("version").?;
    try std.testing.expectEqual(LineCol{ .line = 3, .col = 3 }, lineCol(doc.source.?, v.key_span.start));
    try std.testing.expectEqual(LineCol{ .line = 3, .col = 13 }, lineCol(doc.source.?, v.value.span.start));
    try std.testing.expectEqualStrings("3", v.value.span.slice(doc.source.?));

    try std.testing.expectError(error.InvalidToml, parse(std.testing.allocator, "a = 1\nb = = 2\n", &diag));
    try std.testing.expectEqual(LineCol{ .line = 2, .col = 5 }, lineCol("a = 1\nb = = 2\n", diag.span.start));
}
