//! Runs the vendored toml-test v1.0 corpus (testdata/README.md) against the parser
//! and both serializers.

const std = @import("std");
const toml = @import("toml.zig");
const corpus = @import("testdata/corpus.zig");
const Json = std.json.Value;

test "toml-test valid: tree matches JSON, unedited write is byte-identical, canonical write re-parses equal" {
    const gpa = std.testing.allocator;
    var failures: usize = 0;
    for (corpus.valid) |case| {
        checkValid(gpa, case) catch |err| {
            std.debug.print("FAIL {s}: {t}\n", .{ case.name, err });
            failures += 1;
        };
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "toml-test invalid: every document is rejected" {
    var failures: usize = 0;
    for (corpus.invalid) |case| {
        var diag: toml.Diagnostic = undefined;
        if (toml.parse(std.testing.allocator, case.toml, &diag)) |doc| {
            var d = doc;
            d.deinit();
            std.debug.print("FAIL {s}: accepted\n", .{case.name});
            failures += 1;
        } else |err| try std.testing.expectEqual(error.InvalidToml, err);
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

fn checkValid(gpa: std.mem.Allocator, case: corpus.Valid) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const json = try std.json.parseFromSliceLeaky(Json, arena.allocator(), case.json, .{});

    var diag: toml.Diagnostic = undefined;
    var doc = toml.parse(gpa, case.toml, &diag) catch |err| {
        const lc = toml.lineCol(case.toml, diag.span.start);
        std.debug.print("{s}:{d}:{d}: {s}\n", .{ case.name, lc.line, lc.col, diag.message });
        return err;
    };
    defer doc.deinit();
    try expectMatches(gpa, .{ .table = doc.root }, json);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try doc.write(&out.writer);
    if (!std.mem.eql(u8, case.toml, out.written())) return error.RoundTripNotIdentical;

    out.clearRetainingCapacity();
    try toml.writeCanonical(doc.root, &out.writer);
    var again = toml.parse(gpa, out.written(), &diag) catch |err| {
        std.debug.print("canonical output of {s} rejected ({s}):\n{s}\n", .{ case.name, diag.message, out.written() });
        return err;
    };
    defer again.deinit();
    try expectMatches(gpa, .{ .table = again.root }, json);
}

fn expectMatches(gpa: std.mem.Allocator, data: toml.Data, json: Json) !void {
    switch (data) {
        .table => |t| {
            if (json != .object or json.object.count() != t.entries.count()) return error.TableMismatch;
            for (t.entries.keys(), t.entries.values()) |k, e| {
                try expectMatches(gpa, e.value.data, json.object.get(k) orelse return error.MissingKey);
            }
        },
        .array => |a| {
            if (json != .array or json.array.items.len != a.items.items.len) return error.ArrayMismatch;
            for (a.items.items, json.array.items) |item, j| try expectMatches(gpa, item.data, j);
        },
        else => {
            if (json != .object) return error.ScalarMismatch;
            const ty = (json.object.get("type") orelse return error.ScalarMismatch).string;
            const text = (json.object.get("value") orelse return error.ScalarMismatch).string;
            const ok = switch (data) {
                .string => |s| std.mem.eql(u8, ty, "string") and std.mem.eql(u8, s, text),
                .integer => |i| std.mem.eql(u8, ty, "integer") and i == try std.fmt.parseInt(i64, text, 10),
                .float => |f| std.mem.eql(u8, ty, "float") and floatEq(f, try std.fmt.parseFloat(f64, text)),
                .boolean => |b| std.mem.eql(u8, ty, "bool") and std.mem.eql(u8, text, if (b) "true" else "false"),
                .datetime => |dt| std.mem.eql(u8, ty, datetimeType(dt)) and try datetimeEq(gpa, dt, text),
                .array, .table => unreachable,
            };
            if (!ok) return error.ScalarMismatch;
        },
    }
}

fn floatEq(a: f64, b: f64) bool {
    return (std.math.isNan(a) and std.math.isNan(b)) or a == b;
}

fn datetimeType(dt: toml.Datetime) []const u8 {
    if (dt.date == null) return "time-local";
    if (dt.time == null) return "date-local";
    return if (dt.offset == null) "datetime-local" else "datetime";
}

/// toml-test writes date-times in RFC 3339, which is also TOML syntax.
fn datetimeEq(gpa: std.mem.Allocator, dt: toml.Datetime, text: []const u8) !bool {
    const src = try std.fmt.allocPrint(gpa, "v = {s}", .{text});
    defer gpa.free(src);
    var diag: toml.Diagnostic = undefined;
    var doc = try toml.parse(gpa, src, &diag);
    defer doc.deinit();
    return std.meta.eql(dt, doc.root.get("v").?.data.datetime);
}
