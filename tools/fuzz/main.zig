//! Front-end fuzz driver (T028), run by `zig build fuzz`:
//!
//!     pyro-fuzz [--seconds N] [--count N] [--seed S] [--jobs N] [--corpus DIR]...
//!
//! Feeds `target.generate` inputs to `target.checkInput` until `--seconds`
//! (default 10) have passed or `--count` inputs have run. Input `i` is
//! generated from seed `S + i` (default S = 0) and the `.pr` files under
//! every `--corpus` directory, so a failure is reproduced with
//! `--seed <failing seed> --count 1` and the same corpus. An invariant
//! failure, a panic, or an input running longer than `hang_seconds` prints
//! the failing seed and exits non-zero. The nightly job runs
//! `zig build fuzz -Doptimize=ReleaseSafe -- --seconds 600`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const fe = @import("frontend");
const target = @import("target.zig");

/// An input still running after this long counts as a hang.
const hang_seconds = 30;

const usage = "usage: pyro-fuzz [--seconds N] [--count N] [--seed S] [--jobs N] [--corpus DIR]...\n";

/// Seed of the input being checked, for the panic handler and the watchdog.
var current_seed: std.atomic.Value(u64) = .init(0);
/// Inputs finished so far; the watchdog reports a hang when it stalls.
var done: std.atomic.Value(u64) = .init(0);

pub const panic = std.debug.FullPanic(panicWithSeed);

fn panicWithSeed(msg: []const u8, first_trace_addr: ?usize) noreturn {
    std.debug.print("pyro-fuzz: panic on seed {d}\n", .{current_seed.load(.monotonic)});
    std.debug.defaultPanic(msg, first_trace_addr);
}

const Options = struct {
    seconds: u64 = 10,
    count: u64 = std.math.maxInt(u64),
    seed: u64 = 0,
    jobs: u32 = 4,
    corpus: []const []const u8 = &.{},
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    const opts = parseArgs(arena, args[1..]) catch |err| {
        std.debug.print("pyro-fuzz: {t}\n" ++ usage, .{err});
        return 2;
    };
    const gpa = std.heap.smp_allocator; // thread-safe and fast; leaks are the unit tests' job

    var corpus: std.ArrayList([]const u8) = .empty;
    for (opts.corpus) |dir| try loadCorpus(arena, io, dir, &corpus);

    var pool: fe.Pool = undefined;
    try pool.init(gpa, io, opts.jobs);
    defer pool.deinit(gpa);

    const watchdog = try std.Thread.spawn(.{}, watch, .{io});
    watchdog.detach();

    const start: Io.Timestamp = .now(io, .awake);
    const limit: Io.Duration = .fromSeconds(@intCast(opts.seconds));
    var buf: std.ArrayList(u8) = .empty;
    var n: u64 = 0;
    while (n < opts.count and start.untilNow(io, .awake).nanoseconds < limit.nanoseconds) : (n += 1) {
        const seed = opts.seed +% n;
        current_seed.store(seed, .monotonic);
        var prng: std.Random.DefaultPrng = .init(seed);
        const rand = prng.random();
        try target.generate(gpa, rand, corpus.items, &buf);
        target.checkInput(gpa, io, &pool, buf.items, 1 + rand.uintLessThan(u32, 16)) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                std.debug.print("pyro-fuzz: seed {d}: {t}\n", .{ seed, err });
                return 1;
            },
        };
        _ = done.fetchAdd(1, .monotonic);
    }
    const secs = @as(f64, @floatFromInt(start.untilNow(io, .awake).toMilliseconds())) / 1000;
    std.debug.print("pyro-fuzz: {d} inputs ({d} corpus files) in {d:.1} s, seeds {d}..{d}, no failures\n", .{
        n, corpus.items.len, secs, opts.seed, opts.seed +% n,
    });
    return 0;
}

/// Exits with the current seed if no input finishes for `hang_seconds`.
fn watch(io: Io) void {
    var last = done.load(.monotonic);
    var stalled: u32 = 0;
    while (true) {
        io.sleep(.fromSeconds(1), .awake) catch return;
        const now = done.load(.monotonic);
        stalled = if (now == last) stalled + 1 else 0;
        last = now;
        if (stalled >= hang_seconds) {
            std.debug.print("pyro-fuzz: seed {d}: hang (no progress for {d} s)\n", .{ current_seed.load(.monotonic), hang_seconds });
            std.process.exit(1);
        }
    }
}

fn parseArgs(arena: Allocator, args: []const []const u8) !Options {
    var opts: Options = .{};
    var corpus: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return error.MissingValue;
        const flag = args[i];
        const value = args[i + 1];
        if (std.mem.eql(u8, flag, "--corpus")) {
            try corpus.append(arena, value);
        } else if (std.mem.eql(u8, flag, "--seconds")) {
            opts.seconds = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, flag, "--count")) {
            opts.count = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, flag, "--seed")) {
            opts.seed = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, flag, "--jobs")) {
            opts.jobs = try std.fmt.parseInt(u32, value, 10);
            if (opts.jobs == 0) return error.InvalidJobs;
        } else return error.UnknownFlag;
    }
    opts.corpus = corpus.items;
    return opts;
}

/// Appends the contents of every `.pr` file under `dir`, in sorted path
/// order so seeds mean the same inputs on every machine.
fn loadCorpus(arena: Allocator, io: Io, dir_path: []const u8, out: *std.ArrayList([]const u8)) !void {
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    var paths: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |e| {
        if (e.kind == .file and std.mem.endsWith(u8, e.path, ".pr")) try paths.append(arena, try arena.dupe(u8, e.path));
    }
    std.mem.sort([]const u8, paths.items, {}, lessThan);
    for (paths.items) |p| try out.append(arena, try dir.readFileAlloc(io, p, arena, .limited(1 << 20)));
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

test "parseArgs" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const o = try parseArgs(arena.allocator(), &.{ "--seconds", "600", "--corpus", "x", "--seed", "7", "--corpus", "y" });
    try std.testing.expectEqual(600, o.seconds);
    try std.testing.expectEqual(7, o.seed);
    try std.testing.expectEqual(2, o.corpus.len);
    try std.testing.expectError(error.MissingValue, parseArgs(arena.allocator(), &.{"--seconds"}));
    try std.testing.expectError(error.UnknownFlag, parseArgs(arena.allocator(), &.{ "--x", "1" }));
    try std.testing.expectError(error.InvalidJobs, parseArgs(arena.allocator(), &.{ "--jobs", "0" }));
}
