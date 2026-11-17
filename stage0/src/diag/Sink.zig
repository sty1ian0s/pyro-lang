//! Thread-safe collector of diagnostics. Any number of threads may `emit` and
//! `poison` concurrently; `finish` then yields the diagnostics in a
//! deterministic order (file, offset), independent of thread timing, with
//! cascading errors dropped (A.1) and warning levels applied.
//!
//! A `Sink` must not be copied after `init`.

const std = @import("std");
const diag = @import("diag.zig");
const Diagnostic = diag.Diagnostic;
const DiagCode = diag.DiagCode;
const NodeRef = diag.NodeRef;
const Span = diag.Span;

const Sink = @This();

io: std.Io,
mutex: std.Io.Mutex = .init,
/// Owns every stored diagnostic, its strings and slices, and the poison set.
arena: std.heap.ArenaAllocator,
diags: std.ArrayList(Diagnostic) = .empty,
poisoned: std.AutoHashMapUnmanaged(NodeRef, void) = .empty,
/// Consulted by `finish` for every diagnostic with a `W` code. Errors never
/// reach it: they cannot be suppressed (A.2). Set before calling `finish`.
warning_policy: ?WarningPolicy = null,

pub const WarningLevel = enum { allow, warn, deny };

/// Effective warning level at a source location (`@allow` / `@deny`, T027).
pub const WarningPolicy = struct {
    ctx: *const anyopaque,
    levelAt: *const fn (ctx: *const anyopaque, code: DiagCode, at: Span) WarningLevel,
};

pub fn init(gpa: std.mem.Allocator, io: std.Io) Sink {
    return .{ .io = io, .arena = .init(gpa) };
}

pub fn deinit(s: *Sink) void {
    s.arena.deinit();
    s.* = undefined;
}

/// Stores a deep copy of `d`; the caller's memory may be freed afterwards.
pub fn emit(s: *Sink, d: Diagnostic) error{OutOfMemory}!void {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    const a = s.arena.allocator();
    try s.diags.append(a, try copy(a, d));
}

/// Emits `message` with `code`'s default severity and one primary span.
pub fn emitAt(s: *Sink, code: DiagCode, span: Span, message: []const u8) error{OutOfMemory}!void {
    return s.emit(.{
        .code = code,
        .severity = .of(code),
        .message = message,
        .spans = &.{.{ .span = span, .primary = true }},
    });
}

/// Marks `node` as broken by an error already reported. Every diagnostic whose
/// `subject` is `node` is dropped by `finish`, whether emitted before or after
/// this call.
pub fn poison(s: *Sink, node: NodeRef) error{OutOfMemory}!void {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    try s.poisoned.put(s.arena.allocator(), node, {});
}

/// Lets a stage skip work on nodes whose errors would be dropped anyway.
pub fn isPoisoned(s: *Sink, node: NodeRef) bool {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    return s.poisoned.contains(node);
}

/// True if an error not dropped as a cascade has been emitted so far.
/// Warnings promoted by `@deny` count only after `finish`.
pub fn hasErrors(s: *Sink) bool {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    for (s.diags.items) |d| {
        if (d.severity == .@"error" and !s.isCascade(d)) return true;
    }
    return false;
}

/// Drops cascades and `@allow`ed warnings, promotes `@deny`ed warnings, and
/// returns the rest sorted by (file, offset); diagnostics without a location
/// come first. Call after all producers are done. The slice is owned by the
/// sink and valid until `deinit`; calling `finish` again returns the same list.
pub fn finish(s: *Sink) []const Diagnostic {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    var kept: usize = 0;
    for (s.diags.items) |d| {
        if (s.isCascade(d)) continue;
        var out = d;
        if (s.warning_policy) |p| if (d.code) |c| if (c.isWarning()) {
            const level: WarningLevel = if (d.primarySpan()) |sp| p.levelAt(p.ctx, c, sp) else .warn;
            switch (level) {
                .allow => continue,
                .warn => {},
                .deny => out.severity = .@"error",
            }
        };
        s.diags.items[kept] = out;
        kept += 1;
    }
    s.diags.shrinkRetainingCapacity(kept);
    std.mem.sort(Diagnostic, s.diags.items, {}, lessThan);
    return s.diags.items;
}

fn isCascade(s: *const Sink, d: Diagnostic) bool {
    const node = d.subject orelse return false;
    return s.poisoned.contains(node);
}

/// Total order: location, then code, severity and message, so diagnostics
/// emitted by different threads at the same offset still sort the same way.
fn lessThan(_: void, a: Diagnostic, b: Diagnostic) bool {
    const sa = a.primarySpan();
    const sb = b.primarySpan();
    if ((sa == null) != (sb == null)) return sa == null;
    if (sa) |x| {
        const y = sb.?;
        if (x.file != y.file) return @backingInt(x.file) < @backingInt(y.file);
        if (x.start != y.start) return x.start < y.start;
        if (x.end != y.end) return x.end < y.end;
    }
    const ca: u32 = if (a.code) |c| @backingInt(c) else 0;
    const cb: u32 = if (b.code) |c| @backingInt(c) else 0;
    if (ca != cb) return ca < cb;
    if (a.severity != b.severity) return @backingInt(a.severity) < @backingInt(b.severity);
    return std.mem.lessThan(u8, a.message, b.message);
}

fn copy(a: std.mem.Allocator, d: Diagnostic) error{OutOfMemory}!Diagnostic {
    var out = d;
    out.message = try a.dupe(u8, d.message);

    const spans = try a.dupe(diag.Label, d.spans);
    for (spans) |*l| l.label = try a.dupe(u8, l.label);
    out.spans = spans;

    const help = try a.dupe([]const u8, d.help);
    for (help) |*h| h.* = try a.dupe(u8, h.*);
    out.help = help;

    const fixes = try a.dupe(diag.Fix, d.fixes);
    for (fixes) |*f| f.replacement = try a.dupe(u8, f.replacement);
    out.fixes = fixes;

    const trace = try a.dupe(diag.TraceFrame, d.trace);
    for (trace) |*t| t.note = try a.dupe(u8, t.note);
    out.trace = trace;
    return out;
}

const testing = std.testing;

fn fileId(n: u32) diag.FileId {
    return @fromBackingInt(@intCast(n));
}

fn at(file: u32, start: u32) Span {
    return .{ .file = fileId(file), .start = start, .end = start + 1 };
}

/// One line per diagnostic: what a renderer would print, minus layout.
fn dump(buf: *std.ArrayList(u8), ds: []const Diagnostic) !void {
    for (ds) |d| {
        const sp = d.primarySpan().?;
        try buf.print(testing.allocator, "{d}:{d} {t} {s} {s}\n", .{ @backingInt(sp.file), sp.start, d.code.?, @tagName(d.severity), d.message });
    }
}

fn emitShare(s: *Sink, thread: u32) void {
    // Each thread emits every 4th diagnostic, in descending offset order.
    var i: u32 = 200;
    while (i > 0) {
        i -= 1;
        if (i % 4 != thread) continue;
        const code: DiagCode = if (i % 3 == 0) .W0201 else .E0214;
        var msg_buf: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "problem {d}", .{i % 7}) catch unreachable;
        s.emitAt(code, at(i % 5, i / 10 * 10), msg) catch @panic("OOM");
    }
}

test "4-thread emission prints in stable order" {
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    {
        var s: Sink = .init(testing.allocator, testing.io);
        defer s.deinit();
        for (0..4) |t| emitShare(&s, @intCast(t));
        try dump(&expected, s.finish());
    }
    try testing.expectEqual(200, std.mem.count(u8, expected.items, "\n"));

    for (0..10) |_| {
        var s: Sink = .init(testing.allocator, testing.io);
        defer s.deinit();
        var threads: [4]std.Thread = undefined;
        for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, emitShare, .{ &s, @as(u32, @intCast(i)) });
        for (threads) |t| t.join();
        var got: std.ArrayList(u8) = .empty;
        defer got.deinit(testing.allocator);
        try dump(&got, s.finish());
        try testing.expectEqualStrings(expected.items, got.items);
    }
}

test "order is file, then offset; unlocated first" {
    var s: Sink = .init(testing.allocator, testing.io);
    defer s.deinit();
    try s.emitAt(.E0310, at(1, 3), "c");
    try s.emitAt(.E0310, at(0, 9), "b");
    try s.emitAt(.E0310, at(0, 2), "a");
    try s.emit(.{ .code = null, .severity = .@"error", .message = "no location" });
    const ds = s.finish();
    try testing.expectEqualStrings("no location", ds[0].message);
    try testing.expectEqualStrings("a", ds[1].message);
    try testing.expectEqualStrings("b", ds[2].message);
    try testing.expectEqualStrings("c", ds[3].message);
}

test "diagnostic caused by poisoned node dropped" {
    var s: Sink = .init(testing.allocator, testing.io);
    defer s.deinit();
    const bad: NodeRef = .{ .file = fileId(0), .node = 5 };
    const good: NodeRef = .{ .file = fileId(0), .node = 6 };

    // A checker error about the broken node, emitted before the parser poisons it.
    try s.emit(.{ .code = .E0310, .severity = .@"error", .message = "cascade", .spans = &.{.{ .span = at(0, 12), .primary = true }}, .subject = bad });
    // The parser's own error, which poisons the node.
    try s.emitAt(.E0207, at(0, 10), "root cause");
    try s.poison(bad);
    try testing.expect(s.isPoisoned(bad));
    try testing.expect(!s.isPoisoned(good));
    try s.emit(.{ .code = .E0310, .severity = .@"error", .message = "cascade 2", .spans = &.{.{ .span = at(0, 14), .primary = true }}, .subject = bad });
    try s.emit(.{ .code = .E0310, .severity = .@"error", .message = "independent", .spans = &.{.{ .span = at(0, 20), .primary = true }}, .subject = good });

    const ds = s.finish();
    try testing.expectEqual(2, ds.len);
    try testing.expectEqualStrings("root cause", ds[0].message);
    try testing.expectEqualStrings("independent", ds[1].message);
}

test "emit deep-copies the diagnostic" {
    var s: Sink = .init(testing.allocator, testing.io);
    defer s.deinit();
    var msg = "temp".*;
    var lbl = "lbl".*;
    var help = "help".*;
    var repl = "x".*;
    var note = "in instantiation".*;
    try s.emit(.{
        .code = .E0332,
        .severity = .@"error",
        .message = &msg,
        .spans = &.{.{ .span = at(0, 1), .label = &lbl, .primary = true }},
        .help = &.{&help},
        .fixes = &.{.{ .span = at(0, 1), .replacement = &repl }},
        .trace = &.{.{ .span = at(0, 7), .note = &note }},
    });
    @memset(&msg, '!');
    @memset(&lbl, '!');
    @memset(&help, '!');
    @memset(&repl, '!');
    @memset(&note, '!');
    const d = s.finish()[0];
    try testing.expectEqualStrings("temp", d.message);
    try testing.expectEqualStrings("lbl", d.spans[0].label);
    try testing.expectEqualStrings("help", d.help[0]);
    try testing.expectEqualStrings("x", d.fixes[0].replacement);
    try testing.expectEqualStrings("in instantiation", d.trace[0].note);
}

test "warning policy: allow drops, deny promotes, errors untouched" {
    const Policy = struct {
        fn levelAt(_: *const anyopaque, code: DiagCode, sp: Span) WarningLevel {
            std.debug.assert(code.isWarning());
            return switch (sp.start) {
                0 => .allow,
                1 => .deny,
                else => .warn,
            };
        }
    };
    var s: Sink = .init(testing.allocator, testing.io);
    defer s.deinit();
    s.warning_policy = .{ .ctx = undefined, .levelAt = Policy.levelAt };
    try s.emitAt(.W0201, at(0, 0), "allowed");
    try s.emitAt(.W0201, at(0, 1), "denied");
    try s.emitAt(.W0201, at(0, 2), "warned");
    try s.emitAt(.E0214, at(0, 3), "error");
    try testing.expect(s.hasErrors());
    const ds = s.finish();
    try testing.expectEqual(3, ds.len);
    try testing.expectEqualStrings("denied", ds[0].message);
    try testing.expectEqual(.@"error", ds[0].severity);
    try testing.expectEqual(.warning, ds[1].severity);
    try testing.expectEqual(.@"error", ds[2].severity);
}

test "hasErrors ignores cascades and warnings" {
    var s: Sink = .init(testing.allocator, testing.io);
    defer s.deinit();
    try s.emitAt(.W0201, at(0, 0), "w");
    try testing.expect(!s.hasErrors());
    const n: NodeRef = .{ .file = fileId(0), .node = 1 };
    try s.poison(n);
    try s.emit(.{ .code = .E0310, .severity = .@"error", .message = "cascade", .subject = n });
    try testing.expect(!s.hasErrors());
}
