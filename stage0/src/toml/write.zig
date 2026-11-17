//! TOML serialization: format-preserving for parsed documents, canonical otherwise.

const std = @import("std");
const Writer = std.Io.Writer;
const toml = @import("toml.zig");
const Value = toml.Value;
const Data = toml.Data;
const Table = toml.Table;
const Datetime = toml.Datetime;

/// See `Document.write`.
pub fn writeDocument(doc: *const toml.Document, w: *Writer) Writer.Error!void {
    const src = doc.source orelse return writeCanonical(doc.root, w);
    var cursor: u32 = 0;
    // Edits are few, so a tree walk per edit beats allocating a sorted edit list.
    while (nextEdit(doc.root, cursor)) |v| {
        try w.writeAll(src[cursor..v.span.start]);
        try writeValue(v.data, w);
        cursor = v.span.end;
    }
    try w.writeAll(src[cursor..]);
}

/// The edited value with source text that starts first at or after `from`.
fn nextEdit(t: *const Table, from: u32) ?*const Value {
    var best: ?*const Value = null;
    for (t.entries.values()) |*e| findEdit(&e.value, from, &best);
    return best;
}

fn findEdit(v: *const Value, from: u32, best: *?*const Value) void {
    if (v.edited) {
        if (v.span.end > v.span.start and v.span.start >= from and
            (best.* == null or v.span.start < best.*.?.span.start)) best.* = v;
        return; // nothing inside an edited value is in the source any more
    }
    switch (v.data) {
        .table => |t| for (t.entries.values()) |*e| findEdit(&e.value, from, best),
        .array => |a| for (a.items.items) |*item| findEdit(item, from, best),
        else => {},
    }
}

const Path = struct { key: []const u8, parent: ?*const Path };

/// Writes `root` as a fresh document: each table's plain keys first, then its
/// `[sub.tables]` and `[[arrays.of.tables]]`. Inline syntax is kept for values that
/// are inline (kind `inline_table` / `inline_array`).
pub fn writeCanonical(root: *const Table, w: *Writer) Writer.Error!void {
    var started = false;
    try writeSection(root, null, w, &started);
}

fn isSection(v: Value) bool {
    return switch (v.data) {
        .table => |t| t.kind != .inline_table,
        .array => |a| a.kind == .tables,
        else => false,
    };
}

fn writeSection(t: *const Table, path: ?*const Path, w: *Writer, started: *bool) Writer.Error!void {
    for (t.entries.keys(), t.entries.values()) |k, e| {
        if (isSection(e.value)) continue;
        try writeKey(k, w);
        try w.writeAll(" = ");
        try writeValue(e.value.data, w);
        try w.writeByte('\n');
        started.* = true;
    }
    for (t.entries.keys(), t.entries.values()) |k, e| {
        if (!isSection(e.value)) continue;
        const sub_path: Path = .{ .key = k, .parent = path };
        switch (e.value.data) {
            .table => |sub| {
                // A table holding only sections needs no header of its own.
                var needs_header = sub.entries.count() == 0;
                for (sub.entries.values()) |se| needs_header = needs_header or !isSection(se.value);
                if (needs_header) try writeHeader(&sub_path, "[", "]", w, started);
                try writeSection(sub, &sub_path, w, started);
            },
            .array => |a| for (a.items.items) |item| {
                try writeHeader(&sub_path, "[[", "]]", w, started);
                try writeSection(item.data.table, &sub_path, w, started);
            },
            else => unreachable,
        }
    }
}

fn writeHeader(path: *const Path, open: []const u8, close: []const u8, w: *Writer, started: *bool) Writer.Error!void {
    if (started.*) try w.writeByte('\n');
    started.* = true;
    try w.writeAll(open);
    try writePath(path, w);
    try w.writeAll(close);
    try w.writeByte('\n');
}

fn writePath(path: *const Path, w: *Writer) Writer.Error!void {
    if (path.parent) |parent| {
        try writePath(parent, w);
        try w.writeByte('.');
    }
    try writeKey(path.key, w);
}

fn writeKey(key: []const u8, w: *Writer) Writer.Error!void {
    for (key) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') break;
    } else if (key.len > 0) return w.writeAll(key);
    try writeString(key, w);
}

/// Writes one value in inline syntax (tables as `{ ... }`).
pub fn writeValue(data: Data, w: *Writer) Writer.Error!void {
    switch (data) {
        .string => |s| try writeString(s, w),
        .integer => |i| try w.print("{d}", .{i}),
        .float => |f| try writeFloat(f, w),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .datetime => |dt| try writeDatetime(dt, w),
        .array => |a| {
            try w.writeByte('[');
            for (a.items.items, 0..) |item, i| {
                if (i > 0) try w.writeAll(", ");
                try writeValue(item.data, w);
            }
            try w.writeByte(']');
        },
        .table => |t| {
            if (t.entries.count() == 0) return w.writeAll("{}");
            try w.writeAll("{ ");
            for (t.entries.keys(), t.entries.values(), 0..) |k, e, i| {
                if (i > 0) try w.writeAll(", ");
                try writeKey(k, w);
                try w.writeAll(" = ");
                try writeValue(e.value.data, w);
            }
            try w.writeAll(" }");
        },
    }
}

fn writeString(s: []const u8, w: *Writer) Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        '\r' => try w.writeAll("\\r"),
        0x08 => try w.writeAll("\\b"),
        0x0C => try w.writeAll("\\f"),
        0...0x07, 0x0B, 0x0E...0x1F, 0x7F => try w.print("\\u{X:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn writeFloat(f: f64, w: *Writer) Writer.Error!void {
    if (std.math.isNan(f)) return w.writeAll("nan");
    if (std.math.isInf(f)) return w.writeAll(if (f > 0) "inf" else "-inf");
    var buf: [std.fmt.float.bufferSize(.decimal, f64)]u8 = undefined;
    const s = std.fmt.float.render(&buf, f, .{ .mode = .decimal }) catch unreachable; // buffer sized for f64
    try w.writeAll(s);
    // `{d}` prints integral floats without a fraction, which TOML would read as an integer.
    if (std.mem.indexOfAny(u8, s, ".e") == null) try w.writeAll(".0");
}

fn writeDatetime(dt: Datetime, w: *Writer) Writer.Error!void {
    if (dt.date) |d| try w.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ d.year, d.month, d.day });
    if (dt.date != null and dt.time != null) try w.writeByte('T');
    if (dt.time) |t| {
        try w.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ t.hour, t.minute, t.second });
        if (t.nanosecond != 0) {
            var buf: [9]u8 = undefined;
            _ = std.fmt.bufPrint(&buf, "{d:0>9}", .{t.nanosecond}) catch unreachable;
            try w.print(".{s}", .{std.mem.trimEnd(u8, &buf, "0")});
        }
    }
    if (dt.offset) |off| {
        if (off == 0) return w.writeByte('Z');
        const abs = @abs(off);
        try w.print("{c}{d:0>2}:{d:0>2}", .{ @as(u8, if (off < 0) '-' else '+'), abs / 60, abs % 60 });
    }
}

test "edited values are re-serialized in place, everything else is kept" {
    const src = "# deps\n[dependencies]\nmath = \"1.2\"   # pinned\nnet = { version = \"0.9\" }\n";
    var diag: toml.Diagnostic = undefined;
    var doc = try toml.parse(std.testing.allocator, src, &diag);
    defer doc.deinit();
    const deps = doc.root.get("dependencies").?;
    try deps.data.table.get("math").?.set(.{ .string = "2.0" });
    try deps.data.table.get("net").?.data.table.get("version").?.set(.{ .float = 3 });
    try std.testing.expectError(error.EditNotRepresentable, deps.set(.{ .integer = 1 }));

    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try doc.write(&out.writer);
    try std.testing.expectEqualStrings(
        "# deps\n[dependencies]\nmath = \"2.0\"   # pinned\nnet = { version = 3.0 }\n",
        out.written(),
    );
}

test "canonical output of a hand-built document" {
    var doc = try toml.Document.init(std.testing.allocator);
    defer doc.deinit();
    const gpa = doc.allocator();
    const pkg = try gpa.create(Table);
    pkg.* = .{};
    try pkg.put(gpa, "name", .{ .data = .{ .string = "a\"b\n" } });
    try pkg.put(gpa, "odd key", .{ .data = .{ .datetime = .{
        .date = .{ .year = 1979, .month = 5, .day = 27 },
        .time = .{ .hour = 7, .minute = 32, .second = 0, .nanosecond = 120_000_000 },
        .offset = -420,
    } } });
    const arr = try gpa.create(toml.Array);
    arr.* = .{ .kind = .tables };
    try arr.items.append(gpa, .{ .data = .{ .table = pkg } });
    try doc.root.put(gpa, "package", .{ .data = .{ .array = arr } });
    try doc.root.put(gpa, "f", .{ .data = .{ .float = -0.0 } });

    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try doc.write(&out.writer);
    try std.testing.expectEqualStrings(
        "f = -0.0\n\n[[package]]\nname = \"a\\\"b\\n\"\n\"odd key\" = 1979-05-27T07:32:00.12-07:00\n",
        out.written(),
    );
}
