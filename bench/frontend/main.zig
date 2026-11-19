//! Front-end throughput bench (T028; spec §1.5 goal: hundreds of thousands
//! of lines per second per core), run by `zig build bench`:
//!
//!     pyro-bench-frontend [--seconds N] DIR...
//!
//! Loads every `.pr` file under each DIR once, then lexes, parses and runs
//! the post-parse checks over all of them on one thread, pass after pass,
//! until `--seconds` (default 3) have passed. Prints a human summary and one
//! tab-separated line, `bench<TAB>frontend<TAB><lines/s/core><TAB><bytes/s/core>`,
//! that the nightly job keeps as its tracked result. Not a merge gate: build
//! with `-Doptimize=ReleaseFast` for meaningful numbers.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const fe = @import("frontend");
const diag = fe.diag;

const usage = "usage: pyro-bench-frontend [--seconds N] DIR...\n";

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var seconds: u64 = 3;
    var dirs: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--seconds") and i + 1 < args.len) {
            i += 1;
            seconds = std.fmt.parseInt(u64, args[i], 10) catch {
                std.debug.print("pyro-bench-frontend: bad --seconds\n" ++ usage, .{});
                return 2;
            };
        } else try dirs.append(arena, args[i]);
    }
    if (dirs.items.len == 0) {
        std.debug.print(usage, .{});
        return 2;
    }

    var sm: fe.SourceMap = .init(gpa, io);
    defer sm.deinit();
    var files: std.ArrayList(diag.FileId) = .empty;
    for (dirs.items) |d| try loadDir(arena, io, &sm, d, &files);

    var lines: u64 = 0;
    var bytes: u64 = 0;
    for (files.items) |f| {
        const text = sm.get(f).text;
        bytes += text.len;
        lines += std.mem.count(u8, text, "\n") + @intFromBool(text.len > 0 and text[text.len - 1] != '\n');
    }
    if (lines == 0) {
        std.debug.print("pyro-bench-frontend: no .pr files found\n", .{});
        return 2;
    }

    const start: Io.Timestamp = .now(io, .awake);
    const limit: Io.Duration = .fromSeconds(@intCast(seconds));
    var passes: u64 = 0;
    while (passes == 0 or start.untilNow(io, .awake).nanoseconds < limit.nanoseconds) : (passes += 1) {
        for (files.items) |f| try frontEnd(gpa, io, sm.get(f).text, f);
    }
    const ns: f64 = @floatFromInt(start.untilNow(io, .awake).nanoseconds);
    const lps = @as(f64, @floatFromInt(lines * passes)) * std.time.ns_per_s / ns;
    const bps = @as(f64, @floatFromInt(bytes * passes)) * std.time.ns_per_s / ns;

    var buf: [512]u8 = undefined;
    var out = Io.File.stdout().writer(io, &buf);
    const w = &out.interface;
    try w.print("frontend: {d} files, {d} lines, {d} bytes x {d} passes in {d:.2} s: {d:.0} lines/s/core, {d:.1} MB/s/core\n", .{
        files.items.len, lines, bytes, passes, ns / std.time.ns_per_s, lps, bps / 1e6,
    });
    try w.print("bench\tfrontend\t{d:.0}\t{d:.0}\n", .{ lps, bps });
    try w.flush();
    return 0;
}

/// Stages 1-2 for one file, single-threaded: lex, parse, post-parse checks.
fn frontEnd(gpa: Allocator, io: Io, text: []const u8, file: diag.FileId) !void {
    var sink: diag.Sink = .init(gpa, io);
    defer sink.deinit();
    const tokens = try fe.lexer.tokenize(gpa, text, file, &sink, (fe.parallel.Options{}).lex);
    var ast = try fe.Parser.parse(gpa, text, tokens, file, &sink);
    defer ast.deinit(gpa);
    try fe.check.checkFile(gpa, &ast, file, &sink);
    _ = sink.finish();
}

/// Loads every `.pr` file under `dir_path` whose text is usable (the files
/// `Compilation` would lex), appending their ids to `files`.
fn loadDir(arena: Allocator, io: Io, sm: *fe.SourceMap, dir_path: []const u8, files: *std.ArrayList(diag.FileId)) !void {
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.path, ".pr")) continue;
        var sink: diag.Sink = .init(arena, io);
        defer sink.deinit();
        const id = try sm.load(dir, e.path, &sink);
        const usable = for (sink.finish()) |d| {
            if (d.code != .E0102) break false;
        } else true;
        if (usable) try files.append(arena, id);
    }
}
