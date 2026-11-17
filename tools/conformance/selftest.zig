//! Self-tests: run the harness against a fake `pyro` (a shell script that replays
//! `//fake` lines written into each case) over a generated conformance tree.

const std = @import("std");
const builtin = @import("builtin");
const main = @import("main.zig");

/// Fake `pyro`. Prints the case's `//fake <cmd>: text` lines, plus
/// `//fake <cmd>[<v>]: text` lines where <v> is the `--env`/`--stop-after` value,
/// and exits with `//fake <cmd>-exit: N` (default 0). Without a `.pr` argument it
/// reads `src/main.pr` (example packages).
const fake_pyro =
    \\#!/bin/sh
    \\cmd=$1; shift; v=; f=src/main.pr
    \\while [ $# -gt 0 ]; do
    \\  case $1 in --env|--stop-after) v=$2; shift;; *.pr) f=$1;; esac; shift
    \\done
    \\sed -n -e "s|^//fake $cmd: ||p" -e "s|^//fake $cmd\[$v\]: ||p" "$f"
    \\code=$(sed -n "s|^//fake $cmd-exit: ||p" "$f"); exit ${code:-0}
    \\
;

fn diag(comptime code: []const u8, comptime severity: []const u8, comptime line: u32) []const u8 {
    return std.fmt.comptimePrint(
        \\{{"code":"{s}","severity":"{s}","message":"m","spans":[{{"file":"f.pr","line":{d},"column":1,"end_line":{d},"end_column":2,"label":"","primary":true}}],"help":[],"fixes":[],"trace":[]}}
    , .{ code, severity, line, line });
}

const files = [_][2][]const u8{
    .{ "conformance/01-diag/match.pr", "bad //~ E0101\nx << 1 + 2 //~ W0201\n//fake check: " ++ diag("W0201", "warning", 2) ++ "\n//fake check: " ++ diag("E0101", "error", 1) ++ "\n//fake check-exit: 1\n" },
    .{ "conformance/01-diag/missing.pr", "bad //~ E0101\n" },
    .{ "conformance/01-diag/extra.pr", "ok\n//fake check: " ++ diag("E0102", "error", 1) ++ "\n//fake check-exit: 1\n" },
    .{ "conformance/01-diag/wrong_line.pr", "ok\nbad //~ E0101\n//fake check: " ++ diag("E0101", "error", 1) ++ "\n//fake check-exit: 1\n" },
    .{ "conformance/01-diag/xfail.pr", "//@ expected-fail: not implemented\nbad //~ E0101\n" },
    .{ "conformance/02-parse/dir.conf", "stop-after: parse\n" },
    .{ "conformance/02-parse/sub/stop.pr", "bad //~ E0102\n//fake check[parse]: " ++ diag("E0102", "error", 1) ++ "\n//fake check-exit: 1\n" },
    .{ "conformance/03-run/same.pr", "//@ covers: E0101\n//fake run: hi\n" },
    .{ "conformance/03-run/same.out", "hi\n" },
    .{ "conformance/03-run/env.pr", "//fake run: hi\n//fake run[prod]: wrapped\n" },
    .{ "conformance/03-run/env.out", "hi\n" },
    .{ "conformance/03-run/da.pr", "//@ debug_assertions\n//fake run: hi\n//fake run[prod]: wrapped\n" },
    .{ "conformance/03-run/da.out", "hi\n" },
    .{ "conformance/03-run/da.prod.out", "hi\nwrapped\n" },
    .{ "examples/hello/src/main.pr", "//fake run: Hello from Pyro\n" },
    .{ "examples/hello/expected.out", "Hello from Pyro\n" },
    .{ "A-diagnostics.md", "## A.3 Registry\n| E0101 | a | 2.1 |\n| E0102 | b | 2.1 |\n| W0201 | c | 3.9 |\n" },
};

test "harness against a fake compiler: match, missing, extra, wrong line, env mismatch" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // the fake compiler is a shell script
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    for (files) |f| {
        if (std.fs.path.dirname(f[0])) |d| try tmp.dir.createDirPath(io, d);
        try tmp.dir.writeFile(io, .{ .sub_path = f[0], .data = f[1] });
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "pyro", .data = fake_pyro, .flags = .{ .permissions = .executable_file } });

    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const opts: main.Options = .{
        .pyro = try std.fs.path.join(arena, &.{ root, "pyro" }),
        .conformance = try std.fs.path.join(arena, &.{ root, "conformance" }),
        .examples = try std.fs.path.join(arena, &.{ root, "examples" }),
        .registry = try std.fs.path.join(arena, &.{ root, "A-diagnostics.md" }),
    };

    var out: std.Io.Writer.Allocating = .init(arena);
    const s = try main.run(gpa, io, opts, &out.writer);
    const text = out.written();
    errdefer std.debug.print("{s}", .{text});

    for ([_][]const u8{
        "PASS  01-diag/match.pr\n",
        "FAIL  01-diag/missing.pr\n      missing E0101 at line 1\n",
        "FAIL  01-diag/extra.pr\n      unexpected E0102 at line 1\n",
        "FAIL  01-diag/wrong_line.pr\n      unexpected E0101 at line 1\n      missing E0101 at line 2\n",
        "XFAIL 01-diag/xfail.pr (not implemented)\n",
        "PASS  02-parse/sub/stop.pr\n",
        "PASS  03-run/da.pr\n",
        "FAIL  03-run/env.pr\n      env mismatch: prod output differs from dev\n      [prod] stdout differs at line 2\n",
        "PASS  03-run/same.pr\n",
        "PASS  examples/hello\n",
        "conformance: 5 passed, 4 failed, 1 xfail, 0 xpass, 0 skipped\n",
        "coverage: 2 of 3 A.3 codes lack a passing or failing case\n  E0102  missing pass\n  W0201  missing pass\n",
    }) |want| {
        if (std.mem.indexOf(u8, text, want) == null) {
            std.debug.print("missing from report:\n{s}\n", .{want});
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expect(!s.ok());

    // Path filter: only the selected case runs.
    var filtered = opts;
    filtered.filters = &.{"same"};
    out.clearRetainingCapacity();
    const s2 = try main.run(gpa, io, filtered, &out.writer);
    try std.testing.expectEqual(main.Summary{ .pass = 1 }, s2);
}
