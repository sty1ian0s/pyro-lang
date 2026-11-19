//! Stage-0 `pyro` entry point. The command line lives in `cli/main.zig`.

const std = @import("std");
const cli = @import("cli/main.zig");

/// Panics are internal compiler errors: exit status 3 (§13.8).
pub const panic = cli.panic;

pub fn main(init: std.process.Init) u8 {
    return cli.main(init);
}
