//! Hosted trap entry (§9.4): writes the trap diagnostic to stderr and ends the
//! process with exit status 134. `defer`/`errdefer` blocks never run: the
//! process exits from here without unwinding.
//!
//! Diagnostic format (same shape as compiler diagnostics, A.2):
//!
//!     trap[<kind>]: <message>
//!       --> <file>:<line>
//!
//! Freestanding targets call the package's `@trap_handler` instead; that path
//! is compiled Pyro code, not this runtime.

const std = @import("std");
const builtin = @import("builtin");

/// Mirror of the prelude enum `TrapKind` in `std/core/trap.pr`. The
/// discriminants are the `kind` argument of `pyro_rt_trap`; keep both files in
/// the same order.
pub const TrapKind = enum(u8) {
    bounds = 0,
    overflow = 1,
    div_zero = 2,
    shift = 3,
    assert = 4,
    todo_err = 5,
    contract = 6,
    @"unreachable" = 7,
    explicit = 8,
    stack_overflow = 9,
    capacity = 10,
    deadlock = 11,
    out_of_memory = 12,
    ray_recursion = 13,
    gpu_limit = 14,
};

/// Exit status of a trapping hosted process (§9.4).
pub const exit_status = 134;

/// Set by the first trapping thread; later trappers wait for it to exit the
/// process so two diagnostics never interleave.
var trapping: std.atomic.Value(bool) = .init(false);

/// C-ABI trap entry called by compiled code. `msg` and `file` are Pyro `str`
/// values passed as pointer and length (not NUL-terminated); a pointer may be
/// null when its length is 0 (an empty `str`). An out-of-range `kind` prints
/// as `unknown` instead of being trusted.
pub export fn pyro_rt_trap(
    kind: u32,
    msg_ptr: ?[*]const u8,
    msg_len: usize,
    file_ptr: ?[*]const u8,
    file_len: usize,
    line: u32,
) callconv(.c) noreturn {
    const name = if (std.enums.fromInt(TrapKind, kind)) |k| @tagName(k) else "unknown";
    trapNamed(name, strArg(msg_ptr, msg_len), strArg(file_ptr, file_len), line);
}

/// A C-ABI `str` argument as a slice; a null pointer is the empty string.
fn strArg(ptr: ?[*]const u8, len: usize) []const u8 {
    return if (ptr) |p| p[0..len] else "";
}

/// Zig-side trap entry for runtime code (allocator, scheduler, GPU readback).
pub fn trap(kind: TrapKind, msg: []const u8, file: []const u8, line: u32) noreturn {
    trapNamed(@tagName(kind), msg, file, line);
}

fn trapNamed(kind: []const u8, msg: []const u8, file: []const u8, line: u32) noreturn {
    if (trapping.swap(true, .acq_rel)) while (true) std.atomic.spinLoopHint();

    var line_buf: [10]u8 = undefined;
    const line_len = std.fmt.printInt(&line_buf, line, 10, .lower, .{});
    // shortcut: no stack trace yet; T136 adds symbolized traces in checked builds.
    for ([_][]const u8{ "trap[", kind, "]: ", msg, "\n  --> ", file, ":", line_buf[0..line_len], "\n" }) |part|
        writeStderr(part);
    // _exit, not exit: no atexit handlers or stdio flushing run on a trap.
    std.c._exit(exit_status);
}

/// Writes all of `bytes` to fd 2, ignoring errors (nothing left to report to).
fn writeStderr(bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = std.c.write(2, rest.ptr, rest.len);
        if (n <= 0) {
            if (std.c.errno(n) == .INTR) continue;
            return;
        }
        rest = rest[@intCast(n)..];
    }
}

extern "c" fn fork() c_int;
extern "c" fn close(fd: std.c.fd_t) c_int;
extern fn pyro_test_trap_harness() noreturn; // runtime/trap_harness.c

test "pyro_rt_trap called from C prints the trap diagnostic and exits 134" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(0, std.c.pipe(&fds));
    const pid = fork();
    try std.testing.expect(pid >= 0);
    if (pid == 0) {
        _ = close(fds[0]);
        _ = std.c.dup2(fds[1], 2);
        pyro_test_trap_harness();
    }
    _ = close(fds[1]);
    defer _ = close(fds[0]);

    var buf: [256]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        const n = std.c.read(fds[0], buf[len..].ptr, buf.len - len);
        if (n <= 0) break;
        len += @intCast(n);
    }
    var status: c_int = 0;
    try std.testing.expectEqual(pid, std.c.waitpid(pid, &status, 0));

    const s: u32 = @bitCast(status);
    try std.testing.expect(std.c.W.IFEXITED(s));
    try std.testing.expectEqual(exit_status, std.c.W.EXITSTATUS(s));
    try std.testing.expectEqualStrings(
        "trap[bounds]: index 5 out of bounds for length 3\n  --> src/main.pr:12\n",
        buf[0..len],
    );
}

test "every TrapKind has the discriminant of std/core/trap.pr" {
    const src = @embedFile("trap.pr"); // std/core/trap.pr, wired by build.zig

    var count: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, src, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        // Variant lines have the shape `name = N,`.
        const name, const rest = std.mem.cut(u8, line, " = ") orelse continue;
        const num = std.mem.trimEnd(u8, rest, ",");
        const value = std.fmt.parseInt(u8, num, 10) catch continue;
        const kind = std.meta.stringToEnum(TrapKind, name) orelse return error.UnknownTrapKind;
        try std.testing.expectEqual(value, @backingInt(kind));
        count += 1;
    }
    try std.testing.expectEqual(@typeInfo(TrapKind).@"enum".field_names.len, count);
}
