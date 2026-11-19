//! Command-line parsing for `pyro` (§13.8). `parse` turns `argv[1..]` into
//! `Options`; anything it rejects is invalid usage (exit status 2).
//!
//! Grammar: `pyro <command> [flags] [positionals] [-- passthrough]`. Flags and
//! positionals may be interleaved. Value flags take `--flag value` or
//! `--flag=value`; `--expand` takes its optional value only as `--expand=full`
//! because `pyro build --expand module.path` names a module positionally.
//!
//! Besides the common flags of §13.8 there are command-specific flags (the
//! §13.8 table: `new --lib`, `test --seed n`, `fmt --check`, `doc --open`,
//! `add --dev`) and stage-0 debug flags (`--dump-tokens`, `--dump-ast`,
//! `--stop-after lex|parse`, `--debug-ice`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ColorChoice = @import("../diag/render_human.zig").ColorChoice;

/// The §13.8 commands. `init` and `new` are distinct commands with one row.
pub const Command = enum { new, init, build, run, check, @"test", bench, fmt, doc, lsp, profile, add, remove, update, fetch, publish, clean };

pub const Backend = enum { llvm, native };
pub const MessageFormat = enum { human, json };
/// `--expand` (§13.7) or `--expand=full`.
pub const Expand = enum { normal, full };
/// `--stop-after` (debug): the last front-end stage to run.
pub const StopAfter = enum { lex, parse };

/// One `--set key=value`.
pub const Set = struct { key: []const u8, value: []const u8 };

/// A parsed command line. Slices point into the `args` given to `parse` or
/// into its arena.
pub const Options = struct {
    command: Command,
    /// `--env name`, or `prod` from `--release`; null: the command's default.
    env: ?[]const u8 = null,
    target: ?[]const u8 = null,
    backend: ?Backend = null,
    set: []const Set = &.{},
    /// `--jobs n` (n >= 1); null: one per logical CPU.
    jobs: ?u32 = null,
    offline: bool = false,
    locked: bool = false,
    expand: ?Expand = null,
    trust_build_scripts: bool = false,
    color: ColorChoice = .auto,
    message_format: MessageFormat = .human,

    // Command-specific (§13.8 table).
    lib: bool = false,
    dev: bool = false,
    check: bool = false,
    open: bool = false,
    seed: ?u64 = null,

    // Debug.
    dump_tokens: bool = false,
    dump_ast: bool = false,
    stop_after: ?StopAfter = null,
    /// Panics on purpose, to test the internal-error exit path (status 3).
    debug_ice: bool = false,

    /// Non-flag arguments after the command, in order.
    positionals: []const []const u8 = &.{},
    /// Arguments after `--`, for the program (`run`, `profile`).
    passthrough: []const []const u8 = &.{},
};

/// Every flag. A `boolean` flag sets the `Options` field `field`; a `value`
/// flag consumes an argument for it. `only` restricts a flag to one command.
const Flag = struct {
    name: []const u8,
    field: []const u8,
    kind: enum { boolean, value, release, expand } = .boolean,
    only: ?Command = null,
};

const flags = [_]Flag{
    .{ .name = "--env", .field = "env", .kind = .value },
    .{ .name = "--release", .field = "env", .kind = .release },
    .{ .name = "--target", .field = "target", .kind = .value },
    .{ .name = "--backend", .field = "backend", .kind = .value },
    .{ .name = "--set", .field = "set", .kind = .value },
    .{ .name = "--jobs", .field = "jobs", .kind = .value },
    .{ .name = "--offline", .field = "offline" },
    .{ .name = "--locked", .field = "locked" },
    .{ .name = "--expand", .field = "expand", .kind = .expand },
    .{ .name = "--trust-build-scripts", .field = "trust_build_scripts" },
    .{ .name = "--color", .field = "color", .kind = .value },
    .{ .name = "--message-format", .field = "message_format", .kind = .value },
    .{ .name = "--lib", .field = "lib", .only = .new },
    .{ .name = "--dev", .field = "dev", .only = .add },
    .{ .name = "--check", .field = "check", .only = .fmt },
    .{ .name = "--open", .field = "open", .only = .doc },
    .{ .name = "--seed", .field = "seed", .kind = .value, .only = .@"test" },
    .{ .name = "--dump-tokens", .field = "dump_tokens" },
    .{ .name = "--dump-ast", .field = "dump_ast" },
    .{ .name = "--stop-after", .field = "stop_after", .kind = .value },
    .{ .name = "--debug-ice", .field = "debug_ice" },
};

pub const Error = error{ Usage, OutOfMemory };

/// Parses `args` (without the program name). On `error.Usage`, `msg` holds a
/// one-line explanation allocated in `arena`.
pub fn parse(arena: Allocator, args: []const []const u8, msg: *[]const u8) Error!Options {
    if (args.len == 0) return usage(arena, msg, "no command given", .{});
    var o: Options = .{ .command = std.meta.stringToEnum(Command, args[0]) orelse
        return usage(arena, msg, "unknown command `{s}`", .{args[0]}) };
    var positionals: std.ArrayList([]const u8) = .empty;
    var sets: std.ArrayList(Set) = .empty;
    var release = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--")) {
            if (o.command != .run and o.command != .profile)
                return usage(arena, msg, "`pyro {t}` takes no `--` arguments", .{o.command});
            o.passthrough = args[i + 1 ..];
            break;
        }
        if (!std.mem.startsWith(u8, a, "-") or a.len == 1) {
            try positionals.append(arena, a);
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, a, '=');
        const name = a[0 .. eq orelse a.len];
        const flag = for (flags) |f| {
            if (std.mem.eql(u8, f.name, name)) break f;
        } else return usage(arena, msg, "unknown flag `{s}`", .{name});
        if (flag.only) |c| if (c != o.command)
            return usage(arena, msg, "`{s}` is only valid for `pyro {t}`", .{ name, c });

        switch (flag.kind) {
            .value => {},
            // `--expand` alone, or `--expand=full`.
            .expand => {
                o.expand = if (eq) |e| (if (std.mem.eql(u8, a[e + 1 ..], "full"))
                    .full
                else
                    return usage(arena, msg, "`--expand` takes only `=full`", .{})) else .normal;
                continue;
            },
            .boolean, .release => {
                if (eq != null) return usage(arena, msg, "`{s}` takes no value", .{name});
                if (flag.kind == .release) release = true;
                inline for (flags) |f| if (comptime f.kind == .boolean) {
                    if (std.mem.eql(u8, f.name, name)) @field(o, f.field) = true;
                };
                continue;
            },
        }
        const v = if (eq) |e| a[e + 1 ..] else blk: {
            i += 1;
            if (i == args.len) return usage(arena, msg, "`{s}` needs a value", .{name});
            break :blk args[i];
        };
        if (v.len == 0) return usage(arena, msg, "`{s}` needs a value", .{name});
        const field = flag.field;
        if (std.mem.eql(u8, field, "env")) {
            o.env = v;
        } else if (std.mem.eql(u8, field, "target")) {
            o.target = v;
        } else if (std.mem.eql(u8, field, "set")) {
            const k = std.mem.indexOfScalar(u8, v, '=') orelse
                return usage(arena, msg, "`--set` needs `key=value`, got `{s}`", .{v});
            if (k == 0) return usage(arena, msg, "`--set` needs `key=value`, got `{s}`", .{v});
            try sets.append(arena, .{ .key = v[0..k], .value = v[k + 1 ..] });
        } else if (std.mem.eql(u8, field, "jobs")) {
            o.jobs = std.fmt.parseInt(u32, v, 10) catch 0;
            if (o.jobs == 0) return usage(arena, msg, "`--jobs` needs a positive integer, got `{s}`", .{v});
        } else if (std.mem.eql(u8, field, "seed")) {
            o.seed = std.fmt.parseInt(u64, v, 0) catch
                return usage(arena, msg, "`--seed` needs an integer, got `{s}`", .{v});
        } else if (std.mem.eql(u8, field, "backend")) {
            o.backend = try enumValue(Backend, arena, msg, name, v);
        } else if (std.mem.eql(u8, field, "color")) {
            o.color = try enumValue(ColorChoice, arena, msg, name, v);
        } else if (std.mem.eql(u8, field, "message_format")) {
            o.message_format = try enumValue(MessageFormat, arena, msg, name, v);
        } else if (std.mem.eql(u8, field, "stop_after")) {
            o.stop_after = try enumValue(StopAfter, arena, msg, name, v);
        } else unreachable;
    }
    // §13.8: `--release` is `--env prod`.
    if (release) {
        if (o.env) |e| if (!std.mem.eql(u8, e, "prod"))
            return usage(arena, msg, "`--release` conflicts with `--env {s}`", .{e});
        o.env = "prod";
    }
    o.positionals = positionals.items;
    o.set = sets.items;
    return o;
}

fn enumValue(comptime E: type, arena: Allocator, msg: *[]const u8, name: []const u8, v: []const u8) Error!E {
    if (std.meta.stringToEnum(E, v)) |e| return e;
    const alts = comptime alts: {
        var s: []const u8 = "";
        for (std.meta.fieldNames(E), 0..) |f, i| s = s ++ (if (i > 0) "|" else "") ++ f;
        break :alts s;
    };
    return usage(arena, msg, "`{s}` must be " ++ alts ++ ", got `{s}`", .{ name, v });
}

fn usage(arena: Allocator, msg: *[]const u8, comptime fmt: []const u8, args: anytype) Error {
    msg.* = try std.fmt.allocPrint(arena, fmt, args);
    return error.Usage;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn parseOk(arena: Allocator, args: []const []const u8) !Options {
    var msg: []const u8 = "";
    return parse(arena, args, &msg) catch |err| {
        std.debug.print("unexpected usage error: {s}\n", .{msg});
        return err;
    };
}

fn expectUsage(args: []const []const u8, expected_msg: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var msg: []const u8 = "";
    try testing.expectError(error.Usage, parse(arena.allocator(), args, &msg));
    try testing.expectEqualStrings(expected_msg, msg);
}

test "every common flag" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const o = try parseOk(arena.allocator(), &.{
        "build",    "--env",         "test",                  "--target=x86_64-linux-gnu", "--backend", "native",
        "--set",    "opt_level=O2",  "--set=a.b=c=d",         "--jobs",                    "4",         "--offline",
        "--locked", "--expand=full", "--trust-build-scripts", "--color",                   "never",     "--message-format",
        "json",     "main.sub",
    });
    try testing.expectEqual(Command.build, o.command);
    try testing.expectEqualStrings("test", o.env.?);
    try testing.expectEqualStrings("x86_64-linux-gnu", o.target.?);
    try testing.expectEqual(Backend.native, o.backend.?);
    try testing.expectEqual(2, o.set.len);
    try testing.expectEqualStrings("opt_level", o.set[0].key);
    try testing.expectEqualStrings("O2", o.set[0].value);
    try testing.expectEqualStrings("a.b", o.set[1].key);
    try testing.expectEqualStrings("c=d", o.set[1].value);
    try testing.expectEqual(4, o.jobs.?);
    try testing.expect(o.offline and o.locked and o.trust_build_scripts);
    try testing.expectEqual(Expand.full, o.expand.?);
    try testing.expectEqual(ColorChoice.never, o.color);
    try testing.expectEqual(MessageFormat.json, o.message_format);
    try testing.expectEqual(1, o.positionals.len);
    try testing.expectEqualStrings("main.sub", o.positionals[0]);
}

test "--release is --env prod" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = try parseOk(arena.allocator(), &.{ "build", "--release" });
    const b = try parseOk(arena.allocator(), &.{ "build", "--env", "prod" });
    try testing.expectEqualStrings(b.env.?, a.env.?);
    _ = try parseOk(arena.allocator(), &.{ "build", "--release", "--env=prod" });
    try expectUsage(&.{ "build", "--env", "dev", "--release" }, "`--release` conflicts with `--env dev`");
}

test "--expand without a value leaves the next argument positional" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const o = try parseOk(arena.allocator(), &.{ "build", "--expand", "app.main" });
    try testing.expectEqual(Expand.normal, o.expand.?);
    try testing.expectEqualStrings("app.main", o.positionals[0]);
    try expectUsage(&.{ "build", "--expand=some" }, "`--expand` takes only `=full`");
}

test "debug flags and the single-file check" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const o = try parseOk(arena.allocator(), &.{ "check", "--stop-after", "lex", "--dump-tokens", "--dump-ast", "a.pr" });
    try testing.expectEqual(StopAfter.lex, o.stop_after.?);
    try testing.expect(o.dump_tokens and o.dump_ast and !o.debug_ice);
    try testing.expectEqualStrings("a.pr", o.positionals[0]);
}

test "command-specific flags and passthrough" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try parseOk(arena.allocator(), &.{ "new", "x", "--lib" })).lib);
    try testing.expectEqual(7, (try parseOk(arena.allocator(), &.{ "test", "--seed=7" })).seed.?);
    const r = try parseOk(arena.allocator(), &.{ "run", "--release", "--", "--lib", "x" });
    try testing.expectEqual(2, r.passthrough.len);
    try testing.expectEqualStrings("--lib", r.passthrough[0]);
    try expectUsage(&.{ "build", "--lib" }, "`--lib` is only valid for `pyro new`");
    try expectUsage(&.{ "check", "--", "x" }, "`pyro check` takes no `--` arguments");
}

test "invalid usage" {
    try expectUsage(&.{}, "no command given");
    try expectUsage(&.{"frobnicate"}, "unknown command `frobnicate`");
    try expectUsage(&.{ "check", "--frobnicate" }, "unknown flag `--frobnicate`");
    try expectUsage(&.{ "check", "--jobs" }, "`--jobs` needs a value");
    try expectUsage(&.{ "check", "--jobs", "0" }, "`--jobs` needs a positive integer, got `0`");
    try expectUsage(&.{ "check", "--color", "pink" }, "`--color` must be auto|always|never, got `pink`");
    try expectUsage(&.{ "check", "--stop-after", "check" }, "`--stop-after` must be lex|parse, got `check`");
    try expectUsage(&.{ "check", "--offline=yes" }, "`--offline` takes no value");
    try expectUsage(&.{ "check", "--set", "novalue" }, "`--set` needs `key=value`, got `novalue`");
}
