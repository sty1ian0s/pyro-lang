//! Human-readable diagnostic renderer (A.2, `--message-format human`):
//!
//! ```
//! error[E0332]: `arena` is changed while a slice from it is still in use
//!   --> src/frame.pr:4:5
//!    |
//!  4 |     arena.reset();
//!    |     ^^^^^^^^^^^^^ `arena` is reset here
//!    |
//! help: finish using `tmp` before calling `reset`, ...
//! ```
//!
//! Primary spans are marked `^^^`, secondary ones `---`, one mark per Unicode
//! scalar value; reported columns count scalar values (§2.9). Labels in other
//! files get their own `:::` section. Trace frames (A.1 item 5) print as
//! `note:` lines with their location. Colors follow `--color` (§13.8).

const std = @import("std");
const diag = @import("diag.zig");
const SourceMap = @import("../source/SourceMap.zig");
const Terminal = std.Io.Terminal;
const Color = Terminal.Color;

pub const Error = Terminal.SetColorError;

/// The `--color auto|always|never` choice (§13.8).
pub const ColorChoice = enum { auto, always, never };

/// The terminal mode `choice` selects for output to `file`: `auto` colors
/// only a terminal that supports it.
pub fn colorMode(io: std.Io, file: std.Io.File, choice: ColorChoice) std.Io.Cancelable!Terminal.Mode {
    return switch (choice) {
        .always => .escape_codes,
        .never => .no_color,
        .auto => Terminal.Mode.detect(io, file, false, false),
    };
}

/// Renders `d` to `t`, ending with a newline.
pub fn render(t: Terminal, sm: *const SourceMap, d: diag.Diagnostic) Error!void {
    const w = t.writer;
    const sev: Color = if (d.severity == .@"error") .bright_red else .bright_yellow;
    try t.setColor(.bold);
    try t.setColor(sev);
    try w.writeAll(@tagName(d.severity));
    if (d.code) |c| try w.print("[{t}]", .{c});
    try t.setColor(.reset);
    try t.setColor(.bold);
    try w.print(": {s}", .{d.message});
    try t.setColor(.reset);
    try w.writeByte('\n');

    const r: Renderer = .{ .t = t, .sm = sm, .d = d, .sev = sev, .width = gutterWidth(sm, d) };
    if (d.primarySpan()) |p| {
        try r.section(p, "-->");
        for (d.spans, 0..) |l, i| {
            const f = l.span.file;
            if (f == p.file or for (d.spans[0..i]) |e| (if (e.span.file == f) break true) else false) continue;
            try r.section(l.span, ":::");
        }
        if (d.trace.len + d.help.len > 0) {
            try r.gutter();
            try w.writeByte('\n');
        }
    }
    for (d.trace) |fr| {
        try r.heading("note", fr.note);
        try r.location("-->", fr.span);
    }
    for (d.help) |h| try r.heading("help", h);
}

/// Renders every diagnostic in order (normally `Sink.finish`'s result),
/// separated by blank lines.
pub fn renderAll(t: Terminal, sm: *const SourceMap, ds: []const diag.Diagnostic) Error!void {
    for (ds, 0..) |d, i| {
        if (i > 0) try t.writer.writeByte('\n');
        try render(t, sm, d);
    }
}

/// Digits of the largest line number printed in the gutter or a location.
fn gutterWidth(sm: *const SourceMap, d: diag.Diagnostic) usize {
    var max: u32 = 1;
    for (d.spans) |l| max = @max(max, sm.location(l.span.file, l.span.start).line);
    for (d.trace) |fr| max = @max(max, sm.location(fr.span.file, fr.span.start).line);
    return std.math.log10_int(max) + 1;
}

const Renderer = struct {
    t: Terminal,
    sm: *const SourceMap,
    d: diag.Diagnostic,
    sev: Color,
    width: usize,

    /// `<margin>--> file:line:col`.
    fn location(r: Renderer, arrow: []const u8, sp: diag.Span) Error!void {
        const loc = r.sm.location(sp.file, sp.start);
        try r.t.writer.splatByteAll(' ', r.width + 1);
        try r.color(.bright_blue);
        try r.t.writer.writeAll(arrow);
        try r.t.setColor(.reset);
        try r.t.writer.print(" {s}:{d}:{d}\n", .{ r.sm.get(sp.file).path, loc.line, loc.column });
    }

    /// `<margin> |` without a newline.
    fn gutter(r: Renderer) Error!void {
        try r.t.writer.splatByteAll(' ', r.width + 2);
        try r.color(.bright_blue);
        try r.t.writer.writeByte('|');
        try r.t.setColor(.reset);
    }

    fn heading(r: Renderer, word: []const u8, text: []const u8) Error!void {
        try r.t.setColor(.bold);
        try r.t.writer.writeAll(word);
        try r.t.setColor(.reset);
        try r.t.writer.print(": {s}\n", .{text});
    }

    fn color(r: Renderer, c: Color) Error!void {
        try r.t.setColor(.bold);
        try r.t.setColor(c);
    }

    /// The location line, then every line of `head.file` that a label starts
    /// on, in order, each followed by its labels left to right. A gap of one
    /// line is shown; a longer gap prints `...`.
    fn section(r: Renderer, head: diag.Span, arrow: []const u8) Error!void {
        const f = head.file;
        try r.location(arrow, head);
        try r.gutter();
        try r.t.writer.writeByte('\n');
        var prev: u32 = 0;
        var next = r.nextLine(f, 0);
        while (next) |n| : ({
            prev = n;
            next = r.nextLine(f, n);
        }) {
            if (prev != 0 and n == prev + 2) try r.sourceLine(f, prev + 1);
            if (prev != 0 and n > prev + 2) try r.t.writer.writeAll("...\n");
            try r.sourceLine(f, n);
            var last: ?LabelKey = null;
            while (r.nextLabel(f, n, last)) |k| : (last = k) try r.annotate(r.d.spans[k.index], n);
        }
    }

    /// The smallest line above `after` that a label in file `f` starts on.
    fn nextLine(r: Renderer, f: diag.FileId, after: u32) ?u32 {
        var best: ?u32 = null;
        for (r.d.spans) |l| {
            if (l.span.file != f) continue;
            const n = r.sm.location(f, l.span.start).line;
            if (n > after and (best == null or n < best.?)) best = n;
        }
        return best;
    }

    const LabelKey = struct {
        start: u32,
        index: usize,

        fn lessThan(a: LabelKey, b: LabelKey) bool {
            return a.start < b.start or (a.start == b.start and a.index < b.index);
        }
    };

    /// The next label starting on `line` of `f` after `last`, by start then
    /// declaration order.
    fn nextLabel(r: Renderer, f: diag.FileId, line: u32, last: ?LabelKey) ?LabelKey {
        var best: ?LabelKey = null;
        for (r.d.spans, 0..) |l, i| {
            if (l.span.file != f or r.sm.location(f, l.span.start).line != line) continue;
            const k: LabelKey = .{ .start = l.span.start, .index = i };
            if (last != null and !last.?.lessThan(k)) continue;
            if (best == null or k.lessThan(best.?)) best = k;
        }
        return best;
    }

    /// ` n | text`. Control bytes other than TAB (legal in comments, §2.1;
    /// a lone CR is what E0102 reports) print as their one-column U+2400
    /// control picture, so untrusted source cannot drive the terminal.
    fn sourceLine(r: Renderer, f: diag.FileId, n: u32) Error!void {
        const text = lineText(r.sm.get(f), n);
        const w = r.t.writer;
        try r.color(.bright_blue);
        try w.print(" {[n]d:>[w]} |", .{ .n = n, .w = r.width });
        try r.t.setColor(.reset);
        if (text.len > 0) try w.writeByte(' ');
        for (text) |c| switch (c) {
            0...0x08, 0x0A...0x1F => try w.print("{u}", .{@as(u21, 0x2400) + c}),
            0x7F => try w.writeAll("\u{2421}"),
            else => try w.writeByte(c),
        };
        try w.writeByte('\n');
    }

    /// `   |     ^^^^ label` under `l`, which starts on `line`.
    // shortcut: a span crossing lines is marked to the end of its first line;
    // draw rustc-style multi-line brackets if a check needs them.
    fn annotate(r: Renderer, l: diag.Label, line: u32) Error!void {
        const file = r.sm.get(l.span.file);
        const text = lineText(file, line);
        const line_start: u32 = @intCast(text.ptr - file.text.ptr);
        const before = text[0..@min(text.len, l.span.start - line_start)]; // may start on the stripped CR/LF
        const marked = text[before.len..@max(before.len, @min(text.len, l.span.end - line_start))];
        const w = r.t.writer;
        try r.gutter();
        try w.writeByte(' ');
        // shortcut: one column per scalar (a control byte's picture is one),
        // tabs copied so they align; wide (CJK, emoji) characters before a
        // mark shift it left.
        for (before) |c| if (c & 0xC0 != 0x80) try w.writeByte(if (c == '\t') '\t' else ' ');
        try r.color(if (l.primary) r.sev else .bright_blue);
        try w.splatByteAll(if (l.primary) '^' else '-', @max(1, scalarCount(marked)));
        if (l.label.len > 0) try w.print(" {s}", .{l.label});
        try r.t.setColor(.reset);
        try w.writeByte('\n');
    }
};

/// Line `n` (1-based) of `f` without its LF or CRLF.
fn lineText(f: *const SourceMap.File, n: u32) []const u8 {
    const start = if (n == 1) 0 else f.lfs[n - 2] + 1;
    const end = if (n - 1 < f.lfs.len) f.lfs[n - 1] else f.text.len;
    return std.mem.trimEnd(u8, f.text[start..end], "\r");
}

fn scalarCount(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| n += @intFromBool(c & 0xC0 != 0x80);
    return n;
}

const testing = std.testing;
const a2 = @import("testdata_a2.zig");

fn expectRender(sm: *const SourceMap, mode: Terminal.Mode, ds: []const diag.Diagnostic, expected: []const u8) !void {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try renderAll(.{ .writer = &aw.writer, .mode = mode }, sm, ds);
    try testing.expectEqualStrings(expected, aw.written());
}

const Fixture = struct {
    sink: diag.Sink,
    sm: SourceMap,

    fn init(f: *Fixture) void {
        f.* = .{ .sink = .init(testing.allocator, testing.io), .sm = .init(testing.allocator, testing.io) };
    }

    fn deinit(f: *Fixture) void {
        f.sm.deinit();
        f.sink.deinit();
    }

    fn add(f: *Fixture, path: []const u8, text: []const u8) !diag.FileId {
        return f.sm.addBytes(path, text, &f.sink);
    }
};

fn span(f: diag.FileId, text: []const u8, needle: []const u8, len: usize) diag.Span {
    const at = std.mem.indexOf(u8, text, needle).?;
    return .{ .file = f, .start = @intCast(at), .end = @intCast(at + len) };
}

test "golden: A.2 example byte for byte" {
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();
    _ = try fx.add("src/frame.pr", a2.source);
    try expectRender(&fx.sm, .no_color, &.{a2.example},
        \\error[E0332]: `arena` is changed while a slice from it is still in use
        \\  --> src/frame.pr:4:5
        \\   |
        \\ 3 |     let tmp = arena.alloc_slice(u32, 64);
        \\   |               ----- `tmp` points into `arena` here
        \\ 4 |     arena.reset();
        \\   |     ^^^^^^^^^^^^^ `arena` is reset here
        \\ 5 |     tmp[0] = 1;
        \\   |     --- ...but `tmp` is still used here
        \\   |
        \\help: finish using `tmp` before calling `reset`, or move `arena.reset()` into a `defer`
        \\
    );
}

test "non-ASCII line: scalar columns and marks, CRLF stripped" {
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();
    const src = "let é€😀 = \"q\";\r\n";
    const f = try fx.add("u.pr", src);
    try expectRender(&fx.sm, .no_color, &.{.{
        .code = .W0201,
        .severity = .warning,
        .message = "m",
        .spans = &.{
            .{ .span = span(f, src, "é", "é€😀".len), .label = "name" },
            .{ .span = span(f, src, "\"q\"", 3), .primary = true },
        },
    }},
        \\warning[W0201]: m
        \\  --> u.pr:1:11
        \\   |
        \\ 1 | let é€😀 = "q";
        \\   |     --- name
        \\   |           ^^^
        \\
    );
}

test "gutter width, gaps, other files, trace, no location, multi-line span" {
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    for (1..13) |i| try src.print(testing.allocator, "\tline{d}\n", .{i});
    const a = try fx.add("a.pr", src.items);
    const b = try fx.add("b.pr", "fn g() {\n}\n");
    try expectRender(&fx.sm, .no_color, &.{
        .{ .code = null, .severity = .@"error", .message = "cannot read `x.pr`", .help = &.{"check the path"} },
        .{
            .code = .E0310,
            .severity = .@"error",
            .message = "m",
            .spans = &.{
                .{ .span = span(a, src.items, "line12", 6), .primary = true, .label = "here" },
                .{ .span = span(b, "fn g() {\n}\n", "g()", 3), .label = "declared here" },
                .{ .span = span(a, src.items, "line10", 6) },
                .{ .span = span(a, src.items, "line2\n", 9) },
            },
            .trace = &.{.{ .span = span(b, "fn g() {\n}\n", "}", 1), .note = "in instantiation of `g`" }},
        },
    }, "error: cannot read `x.pr`\n" ++
        "help: check the path\n" ++
        "\n" ++
        "error[E0310]: m\n" ++
        "   --> a.pr:12:2\n" ++
        "    |\n" ++
        "  2 | \tline2\n" ++
        "    | \t-----\n" ++
        "...\n" ++
        " 10 | \tline10\n" ++
        "    | \t------\n" ++
        " 11 | \tline11\n" ++
        " 12 | \tline12\n" ++
        "    | \t^^^^^^ here\n" ++
        "   ::: b.pr:1:4\n" ++
        "    |\n" ++
        "  1 | fn g() {\n" ++
        "    |    --- declared here\n" ++
        "    |\n" ++
        "note: in instantiation of `g`\n" ++
        "   --> b.pr:2:1\n");
}

test "--color always uses escape codes, never does not" {
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();
    const f = try fx.add("c.pr", "x\n");
    const d: diag.Diagnostic = .{
        .code = .E0214,
        .severity = .@"error",
        .message = "m",
        .spans = &.{.{ .span = .{ .file = f, .start = 0, .end = 1 }, .primary = true }},
        .help = &.{"h"},
    };
    try expectRender(&fx.sm, .escape_codes, &.{d}, "\x1b[1m\x1b[91merror[E0214]\x1b[0m\x1b[1m: m\x1b[0m\n" ++
        "  \x1b[1m\x1b[94m-->\x1b[0m c.pr:1:1\n" ++
        "   \x1b[1m\x1b[94m|\x1b[0m\n" ++
        "\x1b[1m\x1b[94m 1 |\x1b[0m x\n" ++
        "   \x1b[1m\x1b[94m|\x1b[0m \x1b[1m\x1b[91m^\x1b[0m\n" ++
        "   \x1b[1m\x1b[94m|\x1b[0m\n" ++
        "\x1b[1mhelp\x1b[0m: h\n");
    try testing.expectEqual(Terminal.Mode.escape_codes, try colorMode(testing.io, .stdout(), .always));
    try testing.expectEqual(Terminal.Mode.no_color, try colorMode(testing.io, .stdout(), .never));
}

test "span on a line ending marks one column past the text" {
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();
    const f = try fx.add("e.pr", "ab\r\n");
    try expectRender(&fx.sm, .no_color, &.{.{
        .code = .E0214,
        .severity = .@"error",
        .message = "m",
        .spans = &.{.{ .span = .{ .file = f, .start = 3, .end = 4 }, .primary = true, .label = "at LF" }},
    }},
        \\error[E0214]: m
        \\  --> e.pr:1:4
        \\   |
        \\ 1 | ab
        \\   |   ^ at LF
        \\
    );
}

test "control bytes in source print as one-column pictures, never raw" {
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();
    const src = "x // \x1b[2J\x07\x7f\nab\rcd\tef\n";
    const f = try fx.add("ctl.pr", src);
    const d: diag.Diagnostic = .{
        .code = .E0102,
        .severity = .@"error",
        .message = "m",
        .spans = &.{
            .{ .span = span(f, src, "\x1b", 1), .label = "esc" },
            .{ .span = span(f, src, "\r", 1), .primary = true, .label = "cr" },
            .{ .span = span(f, src, "ef", 2) },
        },
    };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try renderAll(.{ .writer = &aw.writer, .mode = .no_color }, &fx.sm, &.{d});
    for (aw.written()) |c| try testing.expect(c >= 0x20 and c != 0x7F or c == '\t' or c == '\n');
    try testing.expectEqualStrings("error[E0102]: m\n" ++
        "  --> ctl.pr:2:3\n" ++
        "   |\n" ++
        " 1 | x // \u{241B}[2J\u{2407}\u{2421}\n" ++
        "   |      - esc\n" ++
        " 2 | ab\u{240D}cd\tef\n" ++
        "   |   ^ cr\n" ++
        "   |      \t--\n", aw.written());
}
