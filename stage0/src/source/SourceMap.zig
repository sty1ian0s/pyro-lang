//! The table of loaded `.pr` files (§2.1, B.2). Each file gets a `FileId`,
//! its text (memory-mapped when possible, leading BOM stripped) and the
//! ascending array of its LF offsets, built with a SIMD scan. Loading reports
//! the file-level rules of §2.1: E0103 (too large), E0101 (invalid UTF-8) and
//! E0102 (stray CR). Line and column are computed only on demand (§2.9).
//!
//! All offsets (token starts, spans) are byte offsets into `File.text`, the
//! file contents after the BOM, so a BOM shifts nothing.

const std = @import("std");
const diag = @import("../diag/diag.zig");
const FileId = diag.FileId;
const Sink = diag.Sink;

const SourceMap = @This();

gpa: std.mem.Allocator,
io: std.Io,
files: std.ArrayList(File) = .empty,

/// One loaded source file. Owned by the map; valid until `deinit`.
pub const File = struct {
    /// The path as given to `load` or `addBytes`.
    path: []const u8,
    /// Contents after the BOM. Empty when the file is too large (E0103).
    text: []const u8,
    /// Byte offset in `text` of every LF, ascending.
    lfs: []const u32,
    /// Full file contents including any BOM; `text` is a suffix of it.
    raw: []const u8,
    /// Set when `raw` is a memory map; otherwise `raw` is owned by `gpa`.
    map: ?std.Io.File.MemoryMap,
};

/// A 1-based line and a 1-based column counted in Unicode scalar values (§2.9).
pub const Location = struct {
    line: u32,
    column: u32,
};

/// The largest legal file size in bytes (§2.1).
pub const max_size = std.math.maxInt(u32);

const bom = "\xEF\xBB\xBF";

pub fn init(gpa: std.mem.Allocator, io: std.Io) SourceMap {
    return .{ .gpa = gpa, .io = io };
}

pub fn deinit(sm: *SourceMap) void {
    for (sm.files.items) |*f| {
        sm.gpa.free(f.path);
        sm.gpa.free(f.lfs);
        if (f.map) |*m| m.destroy(sm.io) else sm.gpa.free(f.raw);
    }
    sm.files.deinit(sm.gpa);
    sm.* = undefined;
}

/// Memory-maps `sub_path` (relative to `dir`) and registers it. Rule
/// violations go to `sink` and still yield a `FileId`, so diagnostics can
/// point into the file; only I/O failures return an error.
pub fn load(sm: *SourceMap, dir: std.Io.Dir, sub_path: []const u8, sink: *Sink) !FileId {
    const file = try dir.openFile(sm.io, sub_path, .{});
    defer file.close(sm.io);
    const size = try file.length(sm.io);
    if (size > max_size) {
        const id = try sm.register(sub_path, "", null);
        try sink.emit(.{
            .code = .E0103,
            .severity = .of(.E0103),
            .message = "this source file is larger than 4 GiB",
            .spans = &.{.{ .span = .{ .file = id, .start = 0, .end = 0 }, .primary = true }},
            .help = &.{"split the file into several smaller files"},
        });
        return id;
    }
    if (size == 0) return sm.addBytes(sub_path, "", sink); // mmap rejects length 0
    const id = id: {
        var map = try file.createMemoryMap(sm.io, .{
            .len = @intCast(size),
            .protection = .{ .read = true },
            .populate = false,
        });
        errdefer map.destroy(sm.io);
        break :id try sm.register(sub_path, map.memory, map);
    };
    return sm.check(id, sink); // `sm` owns the map now; a failing `check` must not unmap it
}

/// Registers in-memory contents (a copy of `bytes`) under `path`. Reports
/// E0101/E0102 like `load`. `bytes.len` must not exceed `max_size`.
pub fn addBytes(sm: *SourceMap, path: []const u8, bytes: []const u8, sink: *Sink) !FileId {
    std.debug.assert(bytes.len <= max_size);
    const id = id: {
        const raw = try sm.gpa.dupe(u8, bytes);
        errdefer sm.gpa.free(raw);
        break :id try sm.register(path, raw, null);
    };
    return sm.check(id, sink); // `sm` owns `raw` now; a failing `check` must not free it
}

/// The file `id` names.
pub fn get(sm: *const SourceMap, id: FileId) *const File {
    return &sm.files.items[@backingInt(id)];
}

/// Line and column of byte `offset` in file `id`. `offset` may equal
/// `text.len` (end of file).
pub fn location(sm: *const SourceMap, id: FileId, offset: u32) Location {
    const f = sm.get(id);
    std.debug.assert(offset <= f.text.len);
    const line = std.sort.lowerBound(u32, f.lfs, offset, order);
    const start = if (line == 0) 0 else f.lfs[line - 1] + 1;
    return .{ .line = @intCast(line + 1), .column = scalarCount(f.text[start..offset]) + 1 };
}

fn order(offset: u32, lf: u32) std.math.Order {
    return std.math.order(offset, lf);
}

/// Appends a file record taking ownership of `raw` (and `map`).
fn register(sm: *SourceMap, path: []const u8, raw: []const u8, map: ?std.Io.File.MemoryMap) !FileId {
    const text = if (std.mem.startsWith(u8, raw, bom)) raw[bom.len..] else raw;
    const owned_path = try sm.gpa.dupe(u8, path);
    errdefer sm.gpa.free(owned_path);
    const lfs = try lineFeeds(sm.gpa, text);
    errdefer sm.gpa.free(lfs);
    const id: FileId = @fromBackingInt(@intCast(sm.files.items.len));
    try sm.files.append(sm.gpa, .{ .path = owned_path, .text = text, .lfs = lfs, .raw = raw, .map = map });
    return id;
}

/// Reports one E0101 per maximal run of invalid UTF-8 bytes and one E0102
/// per CR not followed by LF: each is an independent error (A.1).
fn check(sm: *SourceMap, id: FileId, sink: *Sink) !FileId {
    const text = sm.get(id).text;
    var pos: usize = 0;
    while (nextInvalidUtf8(text, pos)) |bad| : (pos = bad.end) try sink.emit(.{
        .code = .E0101,
        .severity = .of(.E0101),
        .message = "this file is not valid UTF-8 text",
        .spans = &.{.{ .span = .{ .file = id, .start = bad.start, .end = bad.end }, .primary = true, .label = "invalid bytes" }},
        .help = &.{"save the file with UTF-8 encoding"},
    });
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, i, '\r')) |cr| : (i = cr + 1) {
        if (cr + 1 < text.len and text[cr + 1] == '\n') continue;
        const at: u32 = @intCast(cr);
        try sink.emit(.{
            .code = .E0102,
            .severity = .of(.E0102),
            .message = "a carriage return (CR) is not followed by a line feed",
            .spans = &.{.{ .span = .{ .file = id, .start = at, .end = at + 1 }, .primary = true }},
            .help = &.{"use LF or CRLF line endings"},
        });
    }
    return id;
}

/// The first maximal run of bytes at or after `from` that do not start a
/// valid UTF-8 sequence, if any. `from` must be on a sequence boundary.
fn nextInvalidUtf8(s: []const u8, from: usize) ?struct { start: u32, end: u32 } {
    if (std.unicode.utf8ValidateSlice(s[from..])) return null;
    var i = from;
    while (validSeqLen(s[i..])) |n| i += n;
    var end = i + 1;
    while (end < s.len and validSeqLen(s[end..]) == null) end += 1;
    return .{ .start = @intCast(i), .end = @intCast(end) };
}

/// Length of the valid UTF-8 sequence `s` starts with; null if it starts with
/// none (or is empty).
fn validSeqLen(s: []const u8) ?usize {
    if (s.len == 0) return null;
    const n = std.unicode.utf8ByteSequenceLength(s[0]) catch return null;
    if (n > s.len) return null;
    _ = std.unicode.utf8Decode(s[0..n]) catch return null;
    return n;
}

/// Byte offsets of every LF in `text`, scanning 32 bytes per step (B.2).
fn lineFeeds(gpa: std.mem.Allocator, text: []const u8) ![]u32 {
    var out: std.ArrayList(u32) = try .initCapacity(gpa, std.mem.count(u8, text, "\n"));
    const V = @Vector(32, u8);
    var i: usize = 0;
    while (i + 32 <= text.len) : (i += 32) {
        const chunk: V = text[i..][0..32].*;
        var mask: u32 = @bitCast(chunk == @as(V, @splat('\n')));
        while (mask != 0) : (mask &= mask - 1) out.appendAssumeCapacity(@intCast(i + @ctz(mask)));
    }
    for (text[i..], i..) |c, j| if (c == '\n') out.appendAssumeCapacity(@intCast(j));
    return out.toOwnedSlice(gpa);
}

/// Number of scalar values in `s`: bytes that are not UTF-8 continuation bytes.
fn scalarCount(s: []const u8) u32 {
    var n: u32 = 0;
    for (s) |c| n += @intFromBool(c & 0xC0 != 0x80);
    return n;
}

const testing = std.testing;

fn expectLoc(sm: *const SourceMap, id: FileId, offset: u32, line: u32, column: u32) !void {
    try testing.expectEqual(Location{ .line = line, .column = column }, sm.location(id, offset));
}

fn expectOnly(sink: *Sink, code: diag.DiagCode, start: u32) !void {
    const ds = sink.finish();
    try testing.expectEqual(1, ds.len);
    try testing.expectEqual(code, ds[0].code.?);
    try testing.expectEqual(start, ds[0].primarySpan().?.start);
}

test "BOM ignored with correct offsets" {
    var sink: Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    var sm: SourceMap = .init(testing.allocator, testing.io);
    defer sm.deinit();
    const id = try sm.addBytes("a.pr", bom ++ "fn\nx", &sink);
    try testing.expectEqualStrings("fn\nx", sm.get(id).text);
    try expectLoc(&sm, id, 0, 1, 1);
    try expectLoc(&sm, id, 3, 2, 1);
    try testing.expectEqual(0, sink.finish().len);
}

test "E0101 at the start of each invalid run" {
    const cases = [_]struct { []const u8, u32 }{
        .{ "ok \xFF", 3 }, // never a lead byte
        .{ "é\xC3(", 2 }, // missing continuation
        .{ "a\xC0\xAF", 1 }, // overlong
        .{ "ab\xED\xA0\x80", 2 }, // surrogate
        .{ "x\xE2\x82", 1 }, // truncated at EOF
    };
    for (cases) |c| {
        var sink: Sink = .init(testing.allocator, testing.io);
        defer sink.deinit();
        var sm: SourceMap = .init(testing.allocator, testing.io);
        defer sm.deinit();
        _ = try sm.addBytes("a.pr", c[0], &sink);
        try expectOnly(&sink, .E0101, c[1]);
    }
    var sink: Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    var sm: SourceMap = .init(testing.allocator, testing.io);
    defer sm.deinit();
    _ = try sm.addBytes("a.pr", "\xFF\xFEa\nb\xC0", &sink);
    const ds = sink.finish();
    try testing.expectEqual(2, ds.len);
    for (ds, [_][2]u32{ .{ 0, 2 }, .{ 5, 6 } }) |d, span| {
        try testing.expectEqual(.E0101, d.code.?);
        try testing.expectEqual(span[0], d.primarySpan().?.start);
        try testing.expectEqual(span[1], d.primarySpan().?.end);
    }
}

test "E0102 at a lone CR; CRLF accepted" {
    var sink: Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    var sm: SourceMap = .init(testing.allocator, testing.io);
    defer sm.deinit();
    _ = try sm.addBytes("ok.pr", "a\r\nb\r\n", &sink);
    try testing.expectEqual(0, sink.finish().len);
    _ = try sm.addBytes("mid.pr", "a\r\nb\rc\rd", &sink);
    _ = try sm.addBytes("end.pr", "a\r", &sink);
    const ds = sink.finish();
    try testing.expectEqual(3, ds.len);
    for (ds, [_]u32{ 4, 6, 1 }) |d, at| {
        try testing.expectEqual(.E0102, d.code.?);
        try testing.expectEqual(at, d.primarySpan().?.start);
    }
}

test "columns count scalar values" {
    var sink: Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    var sm: SourceMap = .init(testing.allocator, testing.io);
    defer sm.deinit();
    // "é" is 2 bytes, "€" 3, "😀" 4: one column each.
    const id = try sm.addBytes("a.pr", "x\né€😀y", &sink);
    try expectLoc(&sm, id, 2, 2, 1);
    try expectLoc(&sm, id, 4, 2, 2);
    try expectLoc(&sm, id, 7, 2, 3);
    try expectLoc(&sm, id, 11, 2, 4);
    try expectLoc(&sm, id, 12, 2, 5); // end of file
}

test "CRLF and LF give the same line numbers" {
    var sink: Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    var sm: SourceMap = .init(testing.allocator, testing.io);
    defer sm.deinit();
    const lf = try sm.addBytes("lf.pr", "a\nbb\n\nc", &sink);
    const crlf = try sm.addBytes("crlf.pr", "a\r\nbb\r\n\r\nc", &sink);
    try expectLoc(&sm, lf, 3, 2, 2);
    try expectLoc(&sm, crlf, 4, 2, 2);
    try expectLoc(&sm, lf, 6, 4, 1);
    try expectLoc(&sm, crlf, 9, 4, 1);
    try testing.expectEqual(0, sink.finish().len);
}

test "LF scan matches a scalar scan across vector chunks" {
    var buf: [200]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = if (i % 7 == 0 or i == 31 or i == 32) '\n' else 'a';
    const lfs = try lineFeeds(testing.allocator, &buf);
    defer testing.allocator.free(lfs);
    var expected: std.ArrayList(u32) = .empty;
    defer expected.deinit(testing.allocator);
    for (buf, 0..) |c, i| if (c == '\n') try expected.append(testing.allocator, @intCast(i));
    try testing.expectEqualSlices(u32, expected.items, lfs);
}

test "load maps a file from disk" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "m.pr", .data = bom ++ "let x\r\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "empty.pr", .data = "" });
    var sink: Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    var sm: SourceMap = .init(testing.allocator, testing.io);
    defer sm.deinit();
    const id = try sm.load(tmp.dir, "m.pr", &sink);
    try testing.expectEqualStrings("m.pr", sm.get(id).path);
    try testing.expectEqualStrings("let x\r\n", sm.get(id).text);
    try expectLoc(&sm, id, 7, 2, 1);
    const empty = try sm.load(tmp.dir, "empty.pr", &sink);
    try testing.expectEqual(0, sm.get(empty).text.len);
    try testing.expectEqual(0, sink.finish().len);
}

test "E0103 for a file over 2^32-1 bytes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const f = try tmp.dir.createFile(testing.io, "big.pr", .{});
        defer f.close(testing.io);
        try f.setLength(testing.io, max_size + 1); // sparse: no data is written
    }
    var sink: Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    var sm: SourceMap = .init(testing.allocator, testing.io);
    defer sm.deinit();
    const id = try sm.load(tmp.dir, "big.pr", &sink);
    try testing.expectEqual(0, sm.get(id).text.len);
    try expectOnly(&sink, .E0103, 0);
}

test "a failing sink leaves file ownership with the map" {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    var sink: Sink = .init(failing.allocator(), testing.io);
    defer sink.deinit();
    var sm: SourceMap = .init(testing.allocator, testing.io);
    defer sm.deinit();
    try testing.expectError(error.OutOfMemory, sm.addBytes("a.pr", "\xFF", &sink));
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "cr.pr", .data = "a\rb" });
    try testing.expectError(error.OutOfMemory, sm.load(tmp.dir, "cr.pr", &sink));
}
