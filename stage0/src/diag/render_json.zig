//! `--message-format json` renderer (A.2): one JSON object per diagnostic, one
//! object per line. The wire format is the one `tools/conformance/README.md`
//! documents and `tools/conformance/diagnostic.zig` parses strictly: every
//! field present, no others. Lines and columns are 1-based, columns count
//! Unicode scalar values (§2.9), and ends are exclusive.

const std = @import("std");
const diag = @import("diag.zig");
const SourceMap = @import("../source/SourceMap.zig");
const Writer = std.Io.Writer;
const Stringify = std.json.Stringify;

/// A span on the wire. Field order is the output order.
const Span = struct {
    file: []const u8,
    line: u32,
    column: u32,
    end_line: u32,
    end_column: u32,
    label: []const u8,
    primary: bool,
};

const Range = struct {
    line: u32,
    column: u32,
    end_line: u32,
    end_column: u32,
};

const Fix = struct {
    file: []const u8,
    range: Range,
    replacement: []const u8,
};

const TraceFrame = struct {
    message: []const u8,
    span: Span,
};

/// Writes `d` as one JSON object followed by `\n`. A diagnostic without a code
/// (no spec rule covers it) gets `"code":""`.
pub fn render(w: *Writer, sm: *const SourceMap, d: diag.Diagnostic) Writer.Error!void {
    var s: Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("code");
    try s.write(if (d.code) |c| @tagName(c) else "");
    try s.objectField("severity");
    try s.write(@tagName(d.severity));
    try s.objectField("message");
    try s.write(d.message);

    try s.objectField("spans");
    try s.beginArray();
    for (d.spans) |l| try s.write(span(sm, l.span, l.label, l.primary));
    try s.endArray();

    try s.objectField("help");
    try s.write(d.help);

    try s.objectField("fixes");
    try s.beginArray();
    for (d.fixes) |f| try s.write(Fix{
        .file = sm.get(f.span.file).path,
        .range = range(sm, f.span),
        .replacement = f.replacement,
    });
    try s.endArray();

    try s.objectField("trace");
    try s.beginArray();
    for (d.trace) |t| try s.write(TraceFrame{ .message = t.note, .span = span(sm, t.span, "", true) });
    try s.endArray();
    try s.endObject();
    try w.writeByte('\n');
}

/// Renders every diagnostic in order (normally `Sink.finish`'s result).
pub fn renderAll(w: *Writer, sm: *const SourceMap, ds: []const diag.Diagnostic) Writer.Error!void {
    for (ds) |d| try render(w, sm, d);
}

fn range(sm: *const SourceMap, sp: diag.Span) Range {
    const a = sm.location(sp.file, sp.start);
    const b = sm.location(sp.file, sp.end);
    return .{ .line = a.line, .column = a.column, .end_line = b.line, .end_column = b.column };
}

fn span(sm: *const SourceMap, sp: diag.Span, label: []const u8, primary: bool) Span {
    const r = range(sm, sp);
    return .{
        .file = sm.get(sp.file).path,
        .line = r.line,
        .column = r.column,
        .end_line = r.end_line,
        .end_column = r.end_column,
        .label = label,
        .primary = primary,
    };
}

const testing = std.testing;

const a2 = @import("testdata_a2.zig");

fn renderToString(sm: *const SourceMap, ds: []const diag.Diagnostic) ![]u8 {
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try renderAll(&aw.writer, sm, ds);
    return aw.toOwnedSlice();
}

test "A.2 example matches the documented wire format byte for byte" {
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    var sm: SourceMap = .init(testing.allocator, testing.io);
    defer sm.deinit();
    _ = try sm.addBytes("src/frame.pr", a2.source, &sink);
    const got = try renderToString(&sm, &.{a2.example});
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        \\{"code":"E0332","severity":"error","message":"`arena` is changed while a slice from it is still in use","spans":[{"file":"src/frame.pr","line":4,"column":5,"end_line":4,"end_column":18,"label":"`arena` is reset here","primary":true},{"file":"src/frame.pr","line":3,"column":15,"end_line":3,"end_column":20,"label":"`tmp` points into `arena` here","primary":false},{"file":"src/frame.pr","line":5,"column":5,"end_line":5,"end_column":8,"label":"...but `tmp` is still used here","primary":false}],"help":["finish using `tmp` before calling `reset`, or move `arena.reset()` into a `defer`"],"fixes":[{"file":"src/frame.pr","range":{"line":4,"column":5,"end_line":4,"end_column":18},"replacement":"defer arena.reset()"}],"trace":[]}
        \\
    , got);
}

/// The harness schema (tools/conformance/diagnostic.zig), parsed strictly:
/// missing or unknown fields fail.
const Schema = struct {
    code: []const u8,
    severity: enum { @"error", warning },
    message: []const u8,
    spans: []const Span,
    help: []const []const u8,
    fixes: []const Fix,
    trace: []const TraceFrame,
};

test "JSON schema: every field, one object per line, escapes, scalar columns" {
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    var sm: SourceMap = .init(testing.allocator, testing.io);
    defer sm.deinit();
    // "é€😀" are 2, 3 and 4 bytes: one column each.
    const src = "x\nlet é€😀 = \"q\";\n";
    const f = try sm.addBytes("dir/u\"8.pr", src, &sink);
    const q = std.mem.indexOf(u8, src, "\"q\"").?;
    const ds = [_]diag.Diagnostic{
        .{ .code = null, .severity = .@"error", .message = "cannot read `a.pr`\n(no such file)" },
        .{
            .code = .W0201,
            .severity = .warning,
            .message = "m",
            .spans = &.{.{ .span = .{ .file = f, .start = @intCast(q), .end = @intCast(q + 3) }, .label = "a \"label\"", .primary = true }},
            .trace = &.{
                .{ .span = .{ .file = f, .start = 0, .end = 1 }, .note = "in expansion" },
                .{ .span = .{ .file = f, .start = @intCast(src.len), .end = @intCast(src.len) }, .note = "at end" },
            },
        },
    };
    const out = try renderToString(&sm, &ds);
    defer testing.allocator.free(out);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var lines = std.mem.splitScalar(u8, out, '\n');
    var parsed: [2]Schema = undefined;
    for (&parsed) |*p| p.* = try std.json.parseFromSliceLeaky(Schema, arena.allocator(), lines.next().?, .{});
    try testing.expectEqualStrings("", lines.next().?);
    try testing.expectEqual(null, lines.next());

    try testing.expectEqualStrings("", parsed[0].code);
    try testing.expectEqualStrings("cannot read `a.pr`\n(no such file)", parsed[0].message);
    try testing.expectEqual(0, parsed[0].spans.len);

    const p = parsed[1];
    try testing.expectEqualStrings("W0201", p.code);
    try testing.expectEqual(.warning, p.severity);
    const sp = p.spans[0];
    try testing.expectEqualStrings("dir/u\"8.pr", sp.file);
    try testing.expectEqualStrings("a \"label\"", sp.label);
    try testing.expect(sp.primary);
    // `let é€😀 = "q"`: the quote is the 11th scalar, not the 17th byte.
    try testing.expectEqual(Span{ .file = sp.file, .line = 2, .column = 11, .end_line = 2, .end_column = 14, .label = sp.label, .primary = true }, sp);
    try testing.expectEqual(2, p.trace.len);
    try testing.expectEqualStrings("in expansion", p.trace[0].message);
    try testing.expectEqual(1, p.trace[0].span.column);
    try testing.expectEqual(3, p.trace[1].span.line);
    try testing.expectEqual(1, p.trace[1].span.end_column);
}
