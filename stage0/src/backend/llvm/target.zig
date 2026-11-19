//! LLVM target machine, object output and system linking for the stage-0
//! LLVM backend (B.6.1, §13.2.1, §13.9).
//!
//! A `Machine` turns a resolved `Target` (stage0/src/target.zig) into an
//! LLVM target machine: the LLVM triple of the §13.2.1 support table, a
//! baseline CPU plus the target's feature set, and the codegen level of
//! `opt_level`. Only codegen is configured here: IR optimization belongs to
//! the P-IR pass pipeline (opt/pipeline.zig), so `O2` and `O3` differ only in
//! the codegen level, and `Oz` uses LLVM's `-Oz` codegen level (`default`).
//!
//! `link` runs the system C compiler driver (`cc`) as the linker, so the C
//! runtime start files and libc come from the host toolchain; the caller
//! passes the compiled `runtime/` objects or archives (e.g. the trap entry
//! `pyro_rt_trap` of runtime/trap.zig).
//!
//! `Machine` references LLVM symbols, so only use it when
//! `@import("build_options").llvm` is true. `link` and `features` do not.

const std = @import("std");
const c = @import("c.zig");
const pyro_target = @import("../../target.zig");
const OptLevel = @import("../../pkg/env.zig").OptLevel;

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Target = pyro_target.Target;
const log = std.log.scoped(.llvm_target);

/// The LLVM codegen level of an `opt_level` (§13.9). Mirrors clang: `-Oz`
/// keeps the default codegen level, its size goals live in the IR pipeline.
pub fn codegenLevel(level: OptLevel) c.CodeGenOptLevel {
    return switch (level) {
        .O0 => .none,
        .O1 => .less,
        .O2, .Oz => .default,
        .O3 => .aggressive,
    };
}

/// The LLVM CPU name used for `arch`: the architecture baseline, refined by
/// the explicit feature list.
pub fn cpuName(arch: pyro_target.Arch) [:0]const u8 {
    return switch (arch) {
        .x86_64 => "x86-64",
        .aarch64, .wasm32 => "generic",
        .riscv64 => "generic-rv64",
    };
}

/// The LLVM spelling of a CPU feature (`std.meta.CpuFeature` names follow
/// Zig's, which differ from LLVM's for a few features).
pub fn llvmFeatureName(f: pyro_target.CpuFeature) []const u8 {
    return switch (f) {
        .sse4_1 => "sse4.1",
        .sse4_2 => "sse4.2",
        .bulk_memory => "bulk-memory",
        else => @tagName(f),
    };
}

/// The LLVM feature string of `t`, e.g. `+sse2,+avx2`, written to `buf`.
pub fn features(t: Target, buf: []u8) error{NoSpaceLeft}![:0]const u8 {
    var w: Io.Writer = .fixed(buf);
    var it = t.features.iterator();
    var first = true;
    while (it.next()) |f| {
        w.print("{s}+{s}", .{ if (first) "" else ",", llvmFeatureName(f) }) catch return error.NoSpaceLeft;
        first = false;
    }
    w.writeByte(0) catch return error.NoSpaceLeft;
    const out = w.buffered();
    return out[0 .. out.len - 1 :0];
}

/// Position-independent code wherever a hosted loader may relocate the image
/// (PIE is the default of every hosted toolchain); static elsewhere.
fn relocMode(t: Target) c.RelocMode {
    return if (t.os == .freestanding or t.arch == .wasm32) .static else .pic;
}

/// Registers the LLVM code generator of `arch`. Safe to call repeatedly.
fn initArch(arch: pyro_target.Arch) void {
    switch (arch) {
        .x86_64 => {
            c.LLVMInitializeX86TargetInfo();
            c.LLVMInitializeX86Target();
            c.LLVMInitializeX86TargetMC();
            c.LLVMInitializeX86AsmPrinter();
        },
        .aarch64 => {
            c.LLVMInitializeAArch64TargetInfo();
            c.LLVMInitializeAArch64Target();
            c.LLVMInitializeAArch64TargetMC();
            c.LLVMInitializeAArch64AsmPrinter();
        },
        .riscv64 => {
            c.LLVMInitializeRISCVTargetInfo();
            c.LLVMInitializeRISCVTarget();
            c.LLVMInitializeRISCVTargetMC();
            c.LLVMInitializeRISCVAsmPrinter();
        },
        .wasm32 => {
            c.LLVMInitializeWebAssemblyTargetInfo();
            c.LLVMInitializeWebAssemblyTarget();
            c.LLVMInitializeWebAssemblyTargetMC();
            c.LLVMInitializeWebAssemblyAsmPrinter();
        },
    }
}

pub const Error = Allocator.Error || error{
    /// LLVM rejected the triple or failed to emit; the message was logged.
    Llvm,
};

/// An LLVM target machine for one `Target` and `opt_level`.
pub const Machine = struct {
    tm: c.TargetMachineRef,
    triple: [:0]const u8,

    /// Creates the target machine. Release it with `deinit`.
    pub fn init(t: Target, level: OptLevel) Error!Machine {
        initArch(t.arch);
        // Every support-table triple is a string literal, hence NUL-terminated.
        const triple: [:0]const u8 = @ptrCast(t.llvmTriple());
        var llt: c.TargetRef = undefined;
        var msg: ?[*:0]u8 = null;
        if (c.LLVMGetTargetFromTriple(triple.ptr, &llt, &msg) != 0) return llvmError("target lookup", msg);
        var feat_buf: [256]u8 = undefined;
        const feat = features(t, &feat_buf) catch unreachable; // every feature fits
        const tm = c.LLVMCreateTargetMachine(llt, triple.ptr, cpuName(t.arch).ptr, feat.ptr, codegenLevel(level), relocMode(t), .default);
        return .{ .tm = tm, .triple = triple };
    }

    pub fn deinit(m: *Machine) void {
        c.LLVMDisposeTargetMachine(m.tm);
        m.* = undefined;
    }

    /// Sets `mod`'s target triple and data layout. Call it before running
    /// any target-dependent IR pass; `emitObject` calls it too.
    pub fn configure(m: Machine, mod: c.ModuleRef) void {
        c.LLVMSetTarget(mod, m.triple.ptr);
        const dl = c.LLVMCreateTargetDataLayout(m.tm);
        defer c.LLVMDisposeTargetData(dl);
        c.LLVMSetModuleDataLayout(mod, dl);
    }

    /// Compiles `mod` to a relocatable object file (ELF, Mach-O, COFF or
    /// wasm, by triple). The caller owns the returned bytes.
    pub fn emitObject(m: Machine, gpa: Allocator, mod: c.ModuleRef) Error![]u8 {
        m.configure(mod);
        var buf: c.MemoryBufferRef = undefined;
        var msg: ?[*:0]u8 = null;
        if (c.LLVMTargetMachineEmitToMemoryBuffer(m.tm, mod, .object, &msg, &buf) != 0) return llvmError("object emission", msg);
        defer c.LLVMDisposeMemoryBuffer(buf);
        return gpa.dupe(u8, c.LLVMGetBufferStart(buf)[0..c.LLVMGetBufferSize(buf)]);
    }
};

fn llvmError(what: []const u8, msg: ?[*:0]u8) error{Llvm} {
    defer if (msg) |p| c.LLVMDisposeMessage(p);
    log.err("LLVM {s} failed: {s}", .{ what, if (msg) |p| std.mem.span(p) else "" });
    return error.Llvm;
}

pub const LinkOptions = struct {
    /// The C compiler driver that runs the system linker.
    cc: []const u8 = "cc",
    target: Target,
    /// Objects of the program, in link order.
    objects: []const []const u8,
    /// Compiled `runtime/` objects or archives, linked after `objects`.
    runtime: []const []const u8,
    /// Path of the executable to write.
    output: []const u8,
};

pub const LinkError = Allocator.Error || std.process.RunError || error{
    /// Only hosted Unix-like targets link through `cc` so far.
    Unsupported,
    /// The linker exited unsuccessfully; its output was logged.
    LinkFailed,
};

/// Links an executable for `opts.target` with the system linker.
pub fn link(gpa: Allocator, io: Io, opts: LinkOptions) LinkError!void {
    switch (opts.target.os) {
        .linux, .macos, .android => {},
        // shortcut: no MSVC link.exe, wasm-ld or freestanding linker script yet; add with the targets' drivers.
        .windows, .ios, .wasi, .freestanding => return error.Unsupported,
    }
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ opts.cc, "-o", opts.output });
    try argv.appendSlice(gpa, opts.objects);
    try argv.appendSlice(gpa, opts.runtime);

    const res = try std.process.run(gpa, io, .{ .argv = argv.items });
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    if (!res.term.success()) {
        log.err("`{s}` failed ({any}):\n{s}{s}", .{ opts.cc, res.term, res.stdout, res.stderr });
        return error.LinkFailed;
    }
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const builtin = @import("builtin");
const emit = @import("emit.zig");
const emit_mem = @import("emit_mem.zig");

test "opt_level maps to codegen levels only" {
    try testing.expectEqual(c.CodeGenOptLevel.none, codegenLevel(.O0));
    try testing.expectEqual(c.CodeGenOptLevel.less, codegenLevel(.O1));
    try testing.expectEqual(c.CodeGenOptLevel.default, codegenLevel(.O2));
    try testing.expectEqual(c.CodeGenOptLevel.aggressive, codegenLevel(.O3));
    try testing.expectEqual(c.CodeGenOptLevel.default, codegenLevel(.Oz));
}

test "feature strings use LLVM spellings" {
    var buf: [256]u8 = undefined;
    var t = try pyro_target.parse("x86_64-linux-gnu");
    try testing.expectEqualStrings("+sse2", try features(t, &buf));
    t.features.insert(.sse4_1);
    t.features.insert(.avx2);
    try testing.expectEqualStrings("+sse2,+sse4.1,+avx2", try features(t, &buf));
    try testing.expectEqualStrings("+m,+a,+f,+d,+c", try features(try pyro_target.parse("riscv64-linux-gnu"), &buf));
    var w = try pyro_target.parse("wasm32-wasi");
    try testing.expectEqualStrings("", try features(w, &buf));
    w.features.insert(.bulk_memory);
    try testing.expectEqualStrings("+bulk-memory", try features(w, &buf));
    // Every known feature at once still fits the buffer `Machine.init` uses.
    t.features = .full;
    _ = try features(t, &buf);
}

test "link rejects targets without a cc driver" {
    const t = try pyro_target.parse("x86_64-windows-msvc");
    try testing.expectError(error.Unsupported, link(testing.allocator, testing.io, .{ .target = t, .objects = &.{}, .runtime = &.{}, .output = "a.exe" }));
}

/// Hand-written hello world (§13.2.1 acceptance): writes through libc.
const hello_src =
    \\global @msg: i8 = "hello, world\0a" readonly
    \\fn @write(%fd: i32, %buf: ptr, %n: i64) -> i64
    \\fn @main() -> i32 {
    \\^entry:
    \\  %fd: i32 = const 1
    \\  %n: i64 = const 13
    \\  %w: i64 = call @write(%fd, @msg, %n)
    \\  %zero: i32 = const 0
    \\  ret %zero
    \\}
;

/// Overflows `i32` at run time, so the runtime trap entry ends the process.
const trap_src =
    \\fn @bump(%a: i32) -> i32 noinline {
    \\^entry:
    \\  %one: i32 = const 1
    \\  %r: i32 = add.trap signed %a, %one
    \\  ret %r
    \\}
    \\fn @main() -> i32 {
    \\^entry:
    \\  %max: i32 = const 2147483647
    \\  %r: i32 = call @bump(%max)
    \\  ret %r
    \\}
;

/// The object bytes of P-IR `src` compiled for `triple`.
fn compile(src: []const u8, triple: []const u8, level: OptLevel) ![]u8 {
    var x = try emit_mem.emitVerified(src);
    defer x.deinit();
    var m = try Machine.init(try pyro_target.parse(triple), level);
    defer m.deinit();
    return m.emitObject(testing.allocator, x.mod.?);
}

/// ELF `e_machine` of an object.
fn elfMachine(obj: []const u8) !u16 {
    try testing.expect(obj.len > 20 and std.mem.eql(u8, obj[0..4], "\x7fELF"));
    return std.mem.readInt(u16, obj[18..20], .little);
}

test "objects for x86-64, aarch64, riscv64 and wasm32" {
    try emit.llvmTest(struct {
        fn run() !void {
            for ([_]struct { []const u8, u16 }{
                .{ "x86_64-linux-gnu", 62 }, // EM_X86_64
                .{ "aarch64-linux-gnu", 183 }, // EM_AARCH64
                .{ "riscv64-linux-gnu", 243 }, // EM_RISCV
            }) |case| {
                const obj = try compile(hello_src, case[0], .O2);
                defer testing.allocator.free(obj);
                try testing.expectEqual(case[1], try elfMachine(obj));
            }
            const wasm = try compile(trap_src, "wasm32-wasi", .O0);
            defer testing.allocator.free(wasm);
            try testing.expectEqualSlices(u8, "\x00asm\x01\x00\x00\x00", wasm[0..8]);
        }
    }.run);
}

test "configure sets the triple and data layout" {
    try emit.llvmTest(struct {
        fn run() !void {
            var x = try emit_mem.emitVerified(trap_src);
            defer x.deinit();
            var m = try Machine.init(try pyro_target.parse("wasm32-wasi"), .O0);
            defer m.deinit();
            m.configure(x.mod.?);
            const s = c.LLVMPrintModuleToString(x.mod.?);
            defer c.LLVMDisposeMessage(s);
            const ir_text = std.mem.span(s);
            try testing.expect(std.mem.indexOf(u8, ir_text, "target triple = \"wasm32-unknown-wasi\"") != null);
            try testing.expect(std.mem.indexOf(u8, ir_text, "target datalayout = \"e-m:e-p:32:32") != null);
        }
    }.run);
}

/// A scratch directory with its absolute path.
const Scratch = struct {
    tmp: testing.TmpDir,
    path: [:0]u8,

    fn init() !Scratch {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        return .{ .tmp = tmp, .path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator) };
    }

    fn deinit(s: *Scratch) void {
        testing.allocator.free(s.path);
        s.tmp.cleanup();
    }

    fn join(s: Scratch, name: []const u8) ![]u8 {
        return std.fs.path.join(testing.allocator, &.{ s.path, name });
    }
};

/// Absolute path of the repository's runtime/trap.zig, found by walking up
/// from the working directory (`zig build test` runs in the build root).
fn runtimeSource(gpa: Allocator) ![]u8 {
    var dir = try Io.Dir.cwd().realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(dir);
    while (true) {
        const candidate = try std.fs.path.join(gpa, &.{ dir, "runtime", "trap.zig" });
        if (Io.Dir.cwd().access(testing.io, candidate, .{})) |_| return candidate else |_| gpa.free(candidate);
        const parent = std.fs.path.dirname(dir) orelse return error.SkipZigTest;
        const next = try gpa.dupeSentinel(u8, parent, 0);
        gpa.free(dir);
        dir = next;
    }
}

/// Compiles the runtime trap entry to an object with the Zig compiler
/// (`$ZIG`, else `zig` on PATH), as the build does for `runtime/`.
fn buildRuntime(s: Scratch) ![]u8 {
    const gpa = testing.allocator;
    const src = try runtimeSource(gpa);
    defer gpa.free(src);
    const out = try s.join("pyro_rt.o");
    errdefer gpa.free(out);
    const emit_arg = try std.fmt.allocPrint(gpa, "-femit-bin={s}", .{out});
    defer gpa.free(emit_arg);
    const zig = testing.environ.getPosix("ZIG") orelse "zig";
    try run(&.{ zig, "build-obj", "-lc", "-fPIC", "-fcompiler-rt", "-OReleaseSafe", emit_arg, src }, .{ .exited = 0 }, "");
    return out;
}

/// Runs `argv`, expecting `term` and a stderr starting with `stderr_prefix`.
fn run(argv: []const []const u8, term: std.process.Child.Term, stderr_prefix: []const u8) !void {
    const res = try std.process.run(testing.allocator, testing.io, .{ .argv = argv });
    defer testing.allocator.free(res.stdout);
    defer testing.allocator.free(res.stderr);
    if (!std.meta.eql(res.term, term)) {
        std.debug.print("`{s}`: {any}\n{s}{s}\n", .{ argv[0], res.term, res.stdout, res.stderr });
        return error.TestUnexpectedResult;
    }
    try testing.expect(std.mem.startsWith(u8, res.stderr, stderr_prefix));
}

/// Compiles `src` for the host, links it against the runtime and returns the
/// executable's path.
fn buildExe(s: Scratch, rt: []const u8, src: []const u8, name: []const u8) ![]u8 {
    const host = pyro_target.host() orelse return error.SkipZigTest;
    if (host.os != .linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    const obj = try compile(src, host.triple(), .O2);
    defer gpa.free(obj);
    const obj_name = try std.fmt.allocPrint(gpa, "{s}.o", .{name});
    defer gpa.free(obj_name);
    try s.tmp.dir.writeFile(testing.io, .{ .sub_path = obj_name, .data = obj });
    const obj_path = try s.join(obj_name);
    defer gpa.free(obj_path);
    const exe = try s.join(name);
    errdefer gpa.free(exe);
    try link(gpa, testing.io, .{ .target = host, .objects = &.{obj_path}, .runtime = &.{rt}, .output = exe });
    return exe;
}

test "hand-written P-IR links against the runtime and runs on the host" {
    try emit.llvmTest(struct {
        fn run_() !void {
            const gpa = testing.allocator;
            var s = try Scratch.init();
            defer s.deinit();
            const rt = try buildRuntime(s);
            defer gpa.free(rt);

            const hello = try buildExe(s, rt, hello_src, "hello");
            defer gpa.free(hello);
            const res = try std.process.run(gpa, testing.io, .{ .argv = &.{hello} });
            defer gpa.free(res.stdout);
            defer gpa.free(res.stderr);
            try testing.expect(res.term.success());
            try testing.expectEqualStrings("hello, world\n", res.stdout);

            // Overflow reaches pyro_rt_trap, which exits 134 (§9.4).
            const trapper = try buildExe(s, rt, trap_src, "trapper");
            defer gpa.free(trapper);
            try run(&.{trapper}, .{ .exited = 134 }, "trap[overflow]: ");
        }
    }.run_);
}
