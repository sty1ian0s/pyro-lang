//! The `pyro check --message-format json` wire format (A.2), as the harness reads
//! it. README.md documents it for the renderer (T017). Parsing is strict: every
//! field is required and unknown fields are rejected, so the harness doubles as a
//! schema check.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Severity = enum { @"error", warning };

/// A source range. Lines and columns are 1-based; columns count Unicode scalar
/// values; `end_line`/`end_column` point one past the last character.
pub const Range = struct {
    line: u32,
    column: u32,
    end_line: u32,
    end_column: u32,
};

pub const Span = struct {
    file: []const u8,
    line: u32,
    column: u32,
    end_line: u32,
    end_column: u32,
    /// Text shown under the span; empty when there is none.
    label: []const u8,
    /// Exactly one span per diagnostic is primary: the `-->` location.
    primary: bool,
};

/// A machine-applicable edit (A.1 item 4).
pub const Fix = struct {
    file: []const u8,
    range: Range,
    replacement: []const u8,
};

/// One instantiation or expansion step (A.1 item 5). Innermost first; the last
/// frame is in the user's own code.
pub const TraceFrame = struct {
    message: []const u8,
    span: Span,
};

/// One diagnostic: one JSON object on one line of stdout.
pub const Diagnostic = struct {
    code: []const u8,
    severity: Severity,
    message: []const u8,
    spans: []const Span,
    help: []const []const u8,
    fixes: []const Fix,
    trace: []const TraceFrame,

    /// The primary span, or null if the diagnostic has none.
    pub fn primary(d: Diagnostic) ?Span {
        for (d.spans) |s| if (s.primary) return s;
        return null;
    }
};

/// Parses `pyro check` stdout: one object per non-empty line. On error,
/// `bad_line` is the 1-based line that failed.
pub fn parseLines(arena: Allocator, stdout: []const u8, bad_line: *usize) ![]Diagnostic {
    var list: std.ArrayList(Diagnostic) = .empty;
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    bad_line.* = 0;
    while (lines.next()) |line| {
        bad_line.* += 1;
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        try list.append(arena, try std.json.parseFromSliceLeaky(Diagnostic, arena, line, .{}));
    }
    return list.items;
}

test "parse the A.2 JSON format" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var bad: usize = 0;
    const ds = try parseLines(arena.allocator(),
        \\{"code":"E0332","severity":"error","message":"`arena` is changed while a slice from it is still in use","spans":[{"file":"src/frame.pr","line":4,"column":5,"end_line":4,"end_column":18,"label":"`arena` is reset here","primary":true},{"file":"src/frame.pr","line":3,"column":15,"end_line":3,"end_column":20,"label":"`tmp` points into `arena` here","primary":false}],"help":["finish using `tmp` before calling `reset`"],"fixes":[{"file":"src/frame.pr","range":{"line":4,"column":5,"end_line":4,"end_column":18},"replacement":""}],"trace":[]}
        \\
        \\{"code":"W0201","severity":"warning","message":"m","spans":[],"help":[],"fixes":[],"trace":[{"message":"in expansion","span":{"file":"a.pr","line":1,"column":1,"end_line":1,"end_column":2,"label":"","primary":true}}]}
    , &bad);
    try std.testing.expectEqual(@as(usize, 2), ds.len);
    try std.testing.expectEqual(Severity.@"error", ds[0].severity);
    try std.testing.expectEqual(@as(u32, 4), ds[0].primary().?.line);
    try std.testing.expect(ds[1].primary() == null);
    try std.testing.expectError(error.MissingField, parseLines(arena.allocator(), "{\"code\":\"E0101\"}", &bad));
    try std.testing.expectEqual(@as(usize, 1), bad);
}
