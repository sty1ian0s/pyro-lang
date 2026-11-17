//! Conformance case model (B.9): `//~` diagnostic expectations, `//@` case
//! directives and per-directory `dir.conf` settings. See README.md.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// How far the pipeline goes for a case (`stop-after`). `lex`/`parse` are passed
/// to `pyro check --stop-after`; `check` is a full check; `run` also runs the case.
pub const Phase = enum { lex, parse, check, run };

/// One expected or reported diagnostic: an A.3 code on a 1-based source line.
pub const Expected = struct {
    code: []const u8,
    line: u32,

    /// Orders by line, then code; the harness compares sorted lists.
    pub fn lessThan(_: void, a: Expected, b: Expected) bool {
        if (a.line != b.line) return a.line < b.line;
        return std.mem.lessThan(u8, a.code, b.code);
    }
};

/// Everything a case's source says about itself.
pub const Annotations = struct {
    /// `//~` expectations, sorted with `Expected.lessThan`.
    expected: []Expected = &.{},
    /// `//@ stop-after: <phase>`; overrides `dir.conf`.
    stop_after: ?Phase = null,
    /// `//@ expected-fail: <reason>`: a failure is reported as XFAIL, a pass as XPASS.
    expected_fail: ?[]const u8 = null,
    /// `//@ debug_assertions`: run output may differ in `prod` (`<case>.prod.out`).
    debug_assertions: bool = false,
    /// `//@ covers: <codes>`: this case is a passing case for those codes.
    covers: []const []const u8 = &.{},
};

/// Settings from `dir.conf` files. A key set in a nearer directory wins.
pub const DirConf = struct {
    stop_after: ?Phase = null,
    /// Runner mode name (see `modes` in main.zig); null means `default`.
    mode: ?[]const u8 = null,
};

/// A fully resolved case, as handed to a runner mode.
pub const Case = struct {
    /// Path of the `.pr` file, usable for opening and as a `pyro` argument.
    path: []const u8,
    /// `path` without `.pr`; expectation files are `<base>.out` etc.
    base: []const u8,
    /// Path relative to the conformance directory, with `/`; used in reports.
    rel: []const u8,
    ann: Annotations,
    stop_after: Phase,
    mode: []const u8,
};

/// Returns true for an A.3-shaped code such as `E0332` or `W9001`.
pub fn isCode(s: []const u8) bool {
    if (s.len != 5 or (s[0] != 'E' and s[0] != 'W')) return false;
    for (s[1..]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// Parses `//~` and `//@` lines of `source`. On `error.BadCase`, `err_msg` says why.
/// Returned slices point into `source` or `arena`.
pub fn parse(arena: Allocator, source: []const u8, err_msg: *[]const u8) !Annotations {
    var ann: Annotations = .{};
    var expected: std.ArrayList(Expected) = .empty;
    var covers: std.ArrayList([]const u8) = .empty;

    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_no: u32 = 0;
    while (lines.next()) |line| {
        line_no += 1;
        if (std.mem.indexOf(u8, line, "//~")) |at| {
            const after = line[at + 3 ..];
            const rest = std.mem.trimStart(u8, after, "^");
            const up = after.len - rest.len;
            if (up >= line_no) return fail(arena, err_msg, "line {d}: `//~^` points before line 1", .{line_no});
            const target: u32 = line_no - @as(u32, @intCast(up));
            var toks = std.mem.tokenizeAny(u8, rest, " \t\r");
            var n: usize = 0;
            while (toks.next()) |tok| : (n += 1) {
                if (!isCode(tok)) break; // the rest is free text
                try expected.append(arena, .{ .code = tok, .line = target });
            }
            if (n == 0) return fail(arena, err_msg, "line {d}: `//~` without a diagnostic code", .{line_no});
            continue;
        }
        const body = std.mem.cutPrefix(u8, std.mem.trim(u8, line, " \t\r"), "//@") orelse continue;
        const key, const value = splitKeyValue(body);
        if (std.mem.eql(u8, key, "stop-after")) {
            ann.stop_after = std.meta.stringToEnum(Phase, value) orelse
                return fail(arena, err_msg, "line {d}: unknown stop-after phase `{s}`", .{ line_no, value });
        } else if (std.mem.eql(u8, key, "expected-fail")) {
            if (value.len == 0) return fail(arena, err_msg, "line {d}: expected-fail needs a reason", .{line_no});
            ann.expected_fail = value;
        } else if (std.mem.eql(u8, key, "debug_assertions")) {
            ann.debug_assertions = true;
        } else if (std.mem.eql(u8, key, "covers")) {
            var toks = std.mem.tokenizeAny(u8, value, " \t,");
            while (toks.next()) |tok| {
                if (!isCode(tok)) return fail(arena, err_msg, "line {d}: `{s}` is not a diagnostic code", .{ line_no, tok });
                try covers.append(arena, tok);
            }
        } else return fail(arena, err_msg, "line {d}: unknown directive `{s}`", .{ line_no, key });
    }
    std.mem.sort(Expected, expected.items, {}, Expected.lessThan);
    ann.expected = expected.items;
    ann.covers = covers.items;
    return ann;
}

/// Fills unset fields of `conf` from the text of one `dir.conf` file
/// (`key: value` lines, `#` comments).
pub fn applyDirConf(arena: Allocator, conf: *DirConf, text: []const u8, err_msg: *[]const u8) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const key, const value = splitKeyValue(line);
        if (std.mem.eql(u8, key, "stop-after")) {
            const p = std.meta.stringToEnum(Phase, value) orelse
                return fail(arena, err_msg, "dir.conf: unknown stop-after phase `{s}`", .{value});
            if (conf.stop_after == null) conf.stop_after = p;
        } else if (std.mem.eql(u8, key, "mode")) {
            if (conf.mode == null) conf.mode = value;
        } else return fail(arena, err_msg, "dir.conf: unknown key `{s}`", .{key});
    }
}

fn splitKeyValue(s: []const u8) struct { []const u8, []const u8 } {
    const key, const value = std.mem.cutScalar(u8, s, ':') orelse .{ s, "" };
    return .{ std.mem.trim(u8, key, " \t"), std.mem.trim(u8, value, " \t\r") };
}

fn fail(arena: Allocator, err_msg: *[]const u8, comptime fmt: []const u8, args: anytype) error{ BadCase, OutOfMemory } {
    err_msg.* = try std.fmt.allocPrint(arena, fmt, args);
    return error.BadCase;
}

test "parse annotations and directives" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var msg: []const u8 = "";
    const ann = try parse(arena.allocator(),
        \\//@ stop-after: parse
        \\//@ expected-fail: needs sema
        \\//@ covers: E0101, W0201
        \\let x = 1 << 2 + 3; //~ W0201 E0201 shift mixed
        \\
        \\//~^^ E0102
    , &msg);
    try std.testing.expectEqual(Phase.parse, ann.stop_after.?);
    try std.testing.expectEqualStrings("needs sema", ann.expected_fail.?);
    try std.testing.expectEqual(@as(usize, 2), ann.covers.len);
    try std.testing.expectEqual(@as(usize, 3), ann.expected.len);
    try std.testing.expectEqualStrings("E0102", ann.expected[0].code);
    try std.testing.expectEqual(@as(u32, 4), ann.expected[0].line);
    try std.testing.expectEqualStrings("E0201", ann.expected[1].code);
    try std.testing.expectEqualStrings("W0201", ann.expected[2].code);
}

test "bad annotations are rejected with a reason" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var msg: []const u8 = "";
    try std.testing.expectError(error.BadCase, parse(arena.allocator(), "x //~ oops", &msg));
    try std.testing.expectEqualStrings("line 1: `//~` without a diagnostic code", msg);
    try std.testing.expectError(error.BadCase, parse(arena.allocator(), "//~^ E0101", &msg));
    try std.testing.expectError(error.BadCase, parse(arena.allocator(), "//@ stop-after: emit", &msg));
    try std.testing.expectError(error.BadCase, parse(arena.allocator(), "//@ flaky", &msg));
}

test "dir.conf: nearer settings win" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var msg: []const u8 = "";
    var conf: DirConf = .{};
    try applyDirConf(arena.allocator(), &conf, "# near\nstop-after: parse\n", &msg);
    try applyDirConf(arena.allocator(), &conf, "stop-after: lex\nmode: gpu-agree\n", &msg);
    try std.testing.expectEqual(Phase.parse, conf.stop_after.?);
    try std.testing.expectEqualStrings("gpu-agree", conf.mode.?);
}
