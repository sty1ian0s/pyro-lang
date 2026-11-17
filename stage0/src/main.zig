//! Stage-0 `pyro` entry point. CLI shell only: every invocation prints usage
//! and exits 2 (invalid usage, §13.8) until T024 adds command dispatch.

const std = @import("std");

const usage =
    \\usage: pyro <command> [options]
    \\
    \\commands:
    \\  new, init     create a package
    \\  build         compile (default env dev)
    \\  run           build and run the executable
    \\  check         parse, resolve and type-check only
    \\  test          run tests and laws
    \\  bench         run benchmarks
    \\  fmt           format source
    \\  doc           generate HTML docs
    \\  lsp           language server over stdio
    \\  profile       run with the sampling profiler
    \\  add, remove   edit [dependencies]
    \\  update, fetch re-resolve or download dependencies
    \\  publish       upload to a registry
    \\  clean         delete build outputs
    \\
    \\stage 0: no commands are implemented yet.
    \\
;

pub fn main() u8 {
    std.debug.print("{s}", .{usage});
    return 2;
}

test "usage lists the check command" {
    try std.testing.expect(std.mem.indexOf(u8, usage, "check") != null);
}
