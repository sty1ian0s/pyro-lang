//! Diagnostics core (Appendix A): the data model every compiler stage reports
//! through, and the registry of codes. Frozen API (T003); renderers (T017) and
//! warning levels (T027) live in their own files and build on these types.
//!
//! Producers fill a `Diagnostic` and hand it to a `Sink`; the driver calls
//! `Sink.finish` once all stages are done and renders the result.

const std = @import("std");

/// Every code of the A.3 registry plus the implementation warnings (`W9xxx`),
/// generated at build time. Write codes as enum literals (`.E0332`): a code not
/// in the registry does not compile.
pub const DiagCode = @import("diag_codes").DiagCode;
pub const Sink = @import("Sink.zig");

/// Index of a loaded source file. The source map (T011) assigns them.
pub const FileId = enum(u32) { _ };

/// A byte range `[start, end)` in one file. Line and column are computed only
/// when rendering (B.2).
pub const Span = struct {
    file: FileId,
    start: u32,
    end: u32,
};

/// A node of a per-file id space (an AST node index, or any other per-file
/// index a stage uses consistently). Used to suppress cascading errors.
pub const NodeRef = struct {
    file: FileId,
    node: u32,
};

pub const Severity = enum {
    @"error",
    warning,

    /// The severity a code has unless warning levels (`@deny`) change it.
    pub fn of(code: DiagCode) Severity {
        return if (code.isWarning()) .warning else .@"error";
    }
};

/// A marked span. Primary spans are drawn `^^^`, secondary ones `---` (A.2).
pub const Label = struct {
    span: Span,
    /// Text after the marks; may be empty.
    label: []const u8 = "",
    primary: bool = false,
};

/// A machine-applicable edit: replace the bytes of `span` with `replacement`.
pub const Fix = struct {
    span: Span,
    replacement: []const u8,
};

/// One step of an instantiation, comptime or expansion trace (A.1 item 5).
/// Traces list frames innermost first and end at the user's own code.
pub const TraceFrame = struct {
    span: Span,
    note: []const u8,
};

pub const Diagnostic = struct {
    /// Null only for diagnostics no spec rule covers (bad command-line input,
    /// I/O failures); every rule violation carries its A.3 code.
    code: ?DiagCode,
    severity: Severity,
    /// Plain-language statement of the problem (A.1 item 3).
    message: []const u8,
    /// The first span with `primary` set is the reported location and the sort
    /// key. A diagnostic with no primary span has no location.
    spans: []const Label = &.{},
    /// `help:` lines.
    help: []const []const u8 = &.{},
    fixes: []const Fix = &.{},
    trace: []const TraceFrame = &.{},
    /// The node this diagnostic is about. If that node is poisoned (see
    /// `Sink.poison`) when the sink finishes, the diagnostic is dropped: an
    /// earlier error already explains it. The diagnostic that poisons a node
    /// must not name that node as its subject.
    subject: ?NodeRef = null,

    /// The reported location: the first primary span, if any.
    pub fn primarySpan(d: Diagnostic) ?Span {
        for (d.spans) |l| if (l.primary) return l.span;
        return null;
    }
};

test "registry holds exactly the A.3 codes" {
    const codes = std.meta.tags(DiagCode);
    var errors: usize = 0;
    var warnings: usize = 0;
    for (codes) |c| {
        if (!c.isWarning()) errors += 1 else if (@backingInt(c) < 19000) warnings += 1; // W9xxx: impl_warnings.md
    }
    try std.testing.expectEqual(141, errors);
    try std.testing.expectEqual(11, warnings);

    try std.testing.expectEqualStrings("conflicting access while a view is live (exclusivity)", DiagCode.E0332.meaning());
    try std.testing.expectEqualStrings("`@todo_err` present", DiagCode.W0601.meaning());
    try std.testing.expectEqual(332, @backingInt(DiagCode.E0332));
    try std.testing.expectEqual(10201, @backingInt(DiagCode.W0201));
    try std.testing.expectEqual(.@"error", Severity.of(.E1401));
    try std.testing.expectEqual(.warning, Severity.of(.W1002));
}

test "codes absent from A.3 are rejected" {
    // `.E0399` used as a DiagCode would be a compile error; these are the same check.
    comptime std.debug.assert(!@hasField(DiagCode, "E0399"));
    comptime std.debug.assert(!@hasField(DiagCode, "W9000"));
    try std.testing.expectEqual(null, std.meta.stringToEnum(DiagCode, "E0399"));
    try std.testing.expectEqual(DiagCode.E0214, std.meta.stringToEnum(DiagCode, "E0214").?);
}

test "primarySpan picks the first primary label" {
    const f: FileId = @fromBackingInt(@intCast(0));
    const d: Diagnostic = .{
        .code = .E0332,
        .severity = .@"error",
        .message = "m",
        .spans = &.{
            .{ .span = .{ .file = f, .start = 1, .end = 2 }, .label = "here" },
            .{ .span = .{ .file = f, .start = 5, .end = 9 }, .primary = true },
        },
    };
    try std.testing.expectEqual(5, d.primarySpan().?.start);
    try std.testing.expectEqual(null, (Diagnostic{ .code = null, .severity = .@"error", .message = "m" }).primarySpan());
}
