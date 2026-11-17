//! Build wiring for the generated `diag_codes` module (T003).
//! `build.zig` calls `module` from `addCommonImports`.

const std = @import("std");

/// Returns the `diag_codes` module, generated from `spec/A-diagnostics.md` and
/// `stage0/build/impl_warnings.md` by running `gen_diag_codes.zig` on the host.
/// The module is created once per build and shared by every importer.
pub fn module(b: *std.Build) *std.Build.Module {
    if (b.modules.get("diag_codes")) |m| return m;
    const gen = b.addExecutable(.{
        .name = "gen_diag_codes",
        .root_module = b.createModule(.{
            .root_source_file = b.path("stage0/build/gen_diag_codes.zig"),
            .target = b.graph.host,
        }),
    });
    const run = b.addRunArtifact(gen);
    const out = run.addOutputFileArg("diag_codes.zig");
    run.addFileArg(b.path("spec/A-diagnostics.md"));
    run.addFileArg(b.path("stage0/build/impl_warnings.md"));
    return b.addModule("diag_codes", .{ .root_source_file = out });
}
