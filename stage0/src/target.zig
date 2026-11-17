//! Compile targets (§13.2.1, §14.8, B.6.1): parsing of `arch-os[-abi]` triples,
//! the reference support table, the LLVM triple mapping used by the stage-0
//! LLVM backend, and the values behind `std.meta.Target` and `@vector_width`.

const std = @import("std");
const builtin = @import("builtin");

/// Instruction-set architecture. Mirrors `std.meta.Arch`.
pub const Arch = enum {
    x86_64,
    aarch64,
    riscv64,
    wasm32,

    /// Pointer width in bits (`std.meta.Target.pointer_bits`).
    pub fn pointerBits(a: Arch) u8 {
        return switch (a) {
            .x86_64, .aarch64, .riscv64 => 64,
            .wasm32 => 32,
        };
    }

    /// Byte order (`std.meta.Target.endian`). Every supported arch is little-endian.
    pub fn endian(a: Arch) std.builtin.Endian {
        _ = a;
        return .little;
    }

    /// Features every CPU of this arch is assumed to have unless overridden.
    pub fn baselineFeatures(a: Arch) FeatureSet {
        return .initMany(switch (a) {
            .x86_64 => &.{.sse2},
            .aarch64 => &.{.neon},
            .riscv64 => &.{ .m, .a, .f, .d, .c }, // rv64gc
            .wasm32 => &.{},
        });
    }
};

/// Operating system. Mirrors `std.meta.Os`.
pub const Os = enum { linux, windows, macos, ios, android, wasi, freestanding };

/// C ABI / libc flavour. Mirrors `std.meta.Abi`; `none` when the triple has no abi part.
pub const Abi = enum { none, gnu, musl, msvc };

/// CPU features known to the implementation. Mirrors `std.meta.CpuFeature`.
/// Names match Zig's `std.Target.<arch>.Feature` tags so host detection can map them.
pub const CpuFeature = enum {
    // x86_64
    sse2,
    sse3,
    ssse3,
    sse4_1,
    sse4_2,
    popcnt,
    avx,
    avx2,
    fma,
    bmi,
    bmi2,
    avx512f,
    // aarch64
    neon,
    fullfp16,
    dotprod,
    sve,
    sve2,
    // riscv64
    m,
    a,
    f,
    d,
    c,
    v,
    // wasm32
    simd128,
    bulk_memory,

    /// The arch this feature belongs to.
    pub fn arch(feature: CpuFeature) Arch {
        return switch (feature) {
            .sse2, .sse3, .ssse3, .sse4_1, .sse4_2, .popcnt, .avx, .avx2, .fma, .bmi, .bmi2, .avx512f => .x86_64,
            .neon, .fullfp16, .dotprod, .sve, .sve2 => .aarch64,
            .m, .a, .f, .d, .c, .v => .riscv64,
            .simd128, .bulk_memory => .wasm32,
        };
    }
};

pub const FeatureSet = std.EnumSet(CpuFeature);

/// One row of the §13.2.1 support table.
pub const Supported = struct {
    /// Canonical Pyro spelling, `arch-os[-abi]`.
    triple: []const u8,
    arch: Arch,
    os: Os,
    abi: Abi,
    /// LLVM target triple for the stage-0 backend (B.6.1).
    llvm: []const u8,
};

/// Triples the reference implementation supports (§13.2.1).
pub const supported = [_]Supported{
    .{ .triple = "x86_64-linux-gnu", .arch = .x86_64, .os = .linux, .abi = .gnu, .llvm = "x86_64-unknown-linux-gnu" },
    .{ .triple = "x86_64-linux-musl", .arch = .x86_64, .os = .linux, .abi = .musl, .llvm = "x86_64-unknown-linux-musl" },
    .{ .triple = "x86_64-windows-msvc", .arch = .x86_64, .os = .windows, .abi = .msvc, .llvm = "x86_64-pc-windows-msvc" },
    .{ .triple = "x86_64-macos", .arch = .x86_64, .os = .macos, .abi = .none, .llvm = "x86_64-apple-macosx" },
    .{ .triple = "x86_64-freestanding", .arch = .x86_64, .os = .freestanding, .abi = .none, .llvm = "x86_64-unknown-none" },
    .{ .triple = "aarch64-linux-gnu", .arch = .aarch64, .os = .linux, .abi = .gnu, .llvm = "aarch64-unknown-linux-gnu" },
    .{ .triple = "aarch64-linux-musl", .arch = .aarch64, .os = .linux, .abi = .musl, .llvm = "aarch64-unknown-linux-musl" },
    .{ .triple = "aarch64-windows-msvc", .arch = .aarch64, .os = .windows, .abi = .msvc, .llvm = "aarch64-pc-windows-msvc" },
    .{ .triple = "aarch64-macos", .arch = .aarch64, .os = .macos, .abi = .none, .llvm = "arm64-apple-macosx" },
    .{ .triple = "aarch64-ios", .arch = .aarch64, .os = .ios, .abi = .none, .llvm = "arm64-apple-ios" },
    .{ .triple = "aarch64-android", .arch = .aarch64, .os = .android, .abi = .none, .llvm = "aarch64-unknown-linux-android" },
    .{ .triple = "aarch64-freestanding", .arch = .aarch64, .os = .freestanding, .abi = .none, .llvm = "aarch64-unknown-none" },
    .{ .triple = "riscv64-linux-gnu", .arch = .riscv64, .os = .linux, .abi = .gnu, .llvm = "riscv64-unknown-linux-gnu" },
    .{ .triple = "riscv64-freestanding", .arch = .riscv64, .os = .freestanding, .abi = .none, .llvm = "riscv64-unknown-none-elf" },
    .{ .triple = "wasm32-wasi", .arch = .wasm32, .os = .wasi, .abi = .none, .llvm = "wasm32-unknown-wasi" },
    .{ .triple = "wasm32-freestanding", .arch = .wasm32, .os = .freestanding, .abi = .none, .llvm = "wasm32-unknown-unknown" },
};

/// A resolved compile target: the values of `std.meta.Target`.
pub const Target = struct {
    arch: Arch,
    os: Os,
    abi: Abi,
    features: FeatureSet,

    pub fn pointerBits(t: Target) u8 {
        return t.arch.pointerBits();
    }

    pub fn endian(t: Target) std.builtin.Endian {
        return t.arch.endian();
    }

    /// `std.meta.Target.has_feature`.
    pub fn hasFeature(t: Target, feature: CpuFeature) bool {
        return t.features.contains(feature);
    }

    /// The support-table row; every `Target` built by this module has one.
    pub fn entry(t: Target) *const Supported {
        for (&supported) |*s| {
            if (s.arch == t.arch and s.os == t.os and s.abi == t.abi) return s;
        }
        unreachable;
    }

    /// LLVM target triple (B.6.1).
    pub fn llvmTriple(t: Target) []const u8 {
        return t.entry().llvm;
    }

    /// Canonical `arch-os[-abi]` spelling.
    pub fn triple(t: Target) []const u8 {
        return t.entry().triple;
    }

    /// `@vector_width(T)` (§10.6.5): preferred native lane count for an element of
    /// `elem_bits` bits (pass 8 for `bool`). 1 when the target has no SIMD unit.
    pub fn vectorWidth(t: Target, elem_bits: u16, is_float: bool) usize {
        const reg_bits: u16 = switch (t.arch) {
            .x86_64 => if (t.hasFeature(.avx512f))
                512
            else if (t.hasFeature(.avx2) or (t.hasFeature(.avx) and is_float))
                256 // AVX1 has 256-bit float ops only
            else
                128,
            .aarch64 => if (t.hasFeature(.neon)) 128 else 0,
            .riscv64 => if (t.hasFeature(.v)) 128 else 0, // V guarantees VLEN >= 128
            .wasm32 => if (t.hasFeature(.simd128)) 128 else 0,
        };
        return @max(1, reg_bits / elem_bits);
    }
};

pub const ParseError = error{
    /// Not of the form `arch-os[-abi]`.
    Malformed,
    /// The arch part names no supported architecture.
    UnknownArch,
    /// The arch is known but the os/abi combination is not in the support table.
    Unsupported,
};

/// Parses `arch-os[-abi]` against the §13.2.1 support table. The result carries the
/// arch's baseline CPU features. On error, `explain` gives the user-facing message.
pub fn parse(text: []const u8) ParseError!Target {
    var parts = std.mem.splitScalar(u8, text, '-');
    const arch_text = parts.first();
    const os_text = parts.next() orelse return error.Malformed;
    const abi_text = parts.next();
    if (parts.next() != null or arch_text.len == 0 or os_text.len == 0) return error.Malformed;
    if (abi_text) |s| if (s.len == 0) return error.Malformed;

    const arch = std.meta.stringToEnum(Arch, arch_text) orelse return error.UnknownArch;
    const os = std.meta.stringToEnum(Os, os_text) orelse return error.Unsupported;
    const abi: Abi = if (abi_text) |s|
        (if (std.meta.stringToEnum(Abi, s)) |v| (if (v == .none) return error.Unsupported else v) else return error.Unsupported)
    else
        .none;
    for (supported) |s| {
        if (s.arch == arch and s.os == os and s.abi == abi)
            return .{ .arch = arch, .os = os, .abi = abi, .features = arch.baselineFeatures() };
    }
    return error.Unsupported;
}

/// Writes a plain-language message for a failed `parse(text)`, naming what is accepted.
pub fn explain(w: *std.Io.Writer, err: ParseError, text: []const u8) std.Io.Writer.Error!void {
    switch (err) {
        error.Malformed => try w.print(
            "`{s}` is not a target triple: write `arch-os` or `arch-os-abi`, for example `x86_64-linux-gnu`",
            .{text},
        ),
        error.UnknownArch => {
            const arch_text = std.mem.sliceTo(text, '-');
            try w.print("unknown architecture `{s}` in target `{s}`; supported architectures:", .{ arch_text, text });
            for (@typeInfo(Arch).@"enum".field_names, 0..) |name, i| {
                try w.print("{s} {s}", .{ if (i == 0) "" else ",", name });
            }
        },
        error.Unsupported => {
            const arch = std.meta.stringToEnum(Arch, std.mem.sliceTo(text, '-')).?;
            try w.print("target `{s}` is not supported; supported targets for {t}:", .{ text, arch });
            var first = true;
            for (supported) |s| {
                if (s.arch != arch) continue;
                try w.print("{s} {s}", .{ if (first) "" else ",", s.triple });
                first = false;
            }
        },
    }
}

/// The target the compiler itself runs on, with the CPU features it was built for
/// (native builds see the real CPU). Null when the host is not in the support table.
pub fn host() ?Target {
    const arch: Arch = switch (builtin.cpu.arch) {
        .x86_64 => .x86_64,
        .aarch64 => .aarch64,
        .riscv64 => .riscv64,
        .wasm32 => .wasm32,
        else => return null,
    };
    const os: Os = switch (builtin.os.tag) {
        .linux => if (builtin.abi.isAndroid()) .android else .linux,
        .windows => .windows,
        .macos => .macos,
        .ios => .ios,
        .wasi => .wasi,
        .freestanding => .freestanding,
        else => return null,
    };
    const abi: Abi = if (os != .linux) .none else switch (builtin.abi) {
        .gnu => .gnu,
        .musl => .musl,
        else => return null,
    };
    for (supported) |s| {
        if (s.arch == arch and s.os == os and s.abi == abi)
            return .{ .arch = arch, .os = os, .abi = abi, .features = hostFeatures(arch) };
    }
    return null; // e.g. x86_64-windows-gnu
}

fn hostFeatures(comptime arch: Arch) FeatureSet {
    const zig_arch = switch (arch) {
        .x86_64 => std.Target.x86,
        .aarch64 => std.Target.aarch64,
        .riscv64 => std.Target.riscv,
        .wasm32 => std.Target.wasm,
    };
    var set: FeatureSet = .empty;
    inline for (@typeInfo(CpuFeature).@"enum".field_names) |name| {
        const ours = @field(CpuFeature, name);
        if (comptime ours.arch() == arch) {
            if (zig_arch.featureSetHas(builtin.cpu.features, @field(zig_arch.Feature, name))) set.insert(ours);
        }
    }
    return set;
}

fn expectExplain(expected: []const u8, text: []const u8) !void {
    const err = if (parse(text)) |_| return error.TestUnexpectedResult else |e| e;
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try explain(&w, err, text);
    try std.testing.expectEqualStrings(expected, w.buffered());
}

test "every supported triple parses and maps" {
    try std.testing.expectEqual(16, supported.len);
    for (supported) |s| {
        const t = try parse(s.triple);
        try std.testing.expectEqual(s.arch, t.arch);
        try std.testing.expectEqual(s.os, t.os);
        try std.testing.expectEqual(s.abi, t.abi);
        try std.testing.expectEqualStrings(s.triple, t.triple());
        try std.testing.expectEqualStrings(s.llvm, t.llvmTriple());
        try std.testing.expect(t.endian() == .little);
    }
    const w = try parse("wasm32-wasi");
    try std.testing.expectEqual(32, w.pointerBits());
    try std.testing.expectEqualStrings("wasm32-unknown-wasi", w.llvmTriple());
    const r = try parse("riscv64-linux-gnu");
    try std.testing.expectEqual(64, r.pointerBits());
    try std.testing.expect(r.hasFeature(.d) and !r.hasFeature(.v) and !r.hasFeature(.sse2));
    try std.testing.expectEqualStrings("arm64-apple-macosx", (try parse("aarch64-macos")).llvmTriple());
}

test "unknown triples give plain diagnostics" {
    try std.testing.expectError(error.Malformed, parse("x86_64"));
    try std.testing.expectError(error.Malformed, parse("x86_64-linux-gnu-extra"));
    try std.testing.expectError(error.Malformed, parse("x86_64--gnu"));
    try std.testing.expectError(error.Unsupported, parse("x86_64-linux"));
    try std.testing.expectError(error.Unsupported, parse("x86_64-linux-none"));
    try std.testing.expectError(error.Unsupported, parse("wasm32-linux-gnu"));
    try expectExplain(
        "unknown architecture `sparc` in target `sparc-linux-gnu`; supported architectures: x86_64, aarch64, riscv64, wasm32",
        "sparc-linux-gnu",
    );
    try expectExplain(
        "target `riscv64-haiku` is not supported; supported targets for riscv64: riscv64-linux-gnu, riscv64-freestanding",
        "riscv64-haiku",
    );
    try expectExplain(
        "`linux` is not a target triple: write `arch-os` or `arch-os-abi`, for example `x86_64-linux-gnu`",
        "linux",
    );
}

test "vector width table" {
    var t = try parse("x86_64-linux-gnu");
    try std.testing.expectEqual(4, t.vectorWidth(32, true)); // SSE2
    t.features.insert(.avx);
    try std.testing.expectEqual(8, t.vectorWidth(32, true));
    try std.testing.expectEqual(4, t.vectorWidth(32, false));
    t.features.insert(.avx512f);
    try std.testing.expectEqual(16, t.vectorWidth(32, true)); // §10.6.5 example
    try std.testing.expectEqual(64, t.vectorWidth(8, false));
    try std.testing.expectEqual(4, (try parse("aarch64-macos")).vectorWidth(32, true));
    try std.testing.expectEqual(1, (try parse("wasm32-wasi")).vectorWidth(32, true));
    try std.testing.expectEqual(1, (try parse("riscv64-linux-gnu")).vectorWidth(64, true));
}

test "host detection on linux x86_64" {
    if (builtin.cpu.arch != .x86_64 or builtin.os.tag != .linux) return error.SkipZigTest;
    const t = host() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Arch.x86_64, t.arch);
    try std.testing.expectEqual(Os.linux, t.os);
    try std.testing.expect(t.abi == .gnu or t.abi == .musl);
    try std.testing.expect(t.hasFeature(.sse2)); // x86-64 baseline
    try std.testing.expectEqual(64, t.pointerBits());
}
