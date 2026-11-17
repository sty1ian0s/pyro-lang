//! Global thread-safe string interner (B.1, B.4): maps byte strings to dense
//! `u32` ids, so identifiers compare by id. Equal bytes always get the same
//! id. Ids are assigned in first-intern order, which is not deterministic
//! when threads intern concurrently: never sort or hash output by id, use
//! the bytes (`get`) instead.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Arena = @import("Arena.zig");
const Interner = @This();

/// Interned string id: index into the interner's string table.
pub const Id = @import("index.zig").Index(.string);

gpa: Allocator,
io: Io,
lock: Io.RwLock = .init,
map: std.StringHashMapUnmanaged(Id) = .empty,
/// `strings[id]` is the interned copy of the bytes for `id`.
strings: std.ArrayList([]const u8) = .empty,
/// Owns the interned bytes; they never move, so `get` slices stay valid.
bytes: Arena,

/// `gpa` must be thread-safe if other threads use it at the same time.
pub fn init(gpa: Allocator, io: Io) Interner {
    return .{ .gpa = gpa, .io = io, .bytes = .init(gpa) };
}

pub fn deinit(self: *Interner) void {
    self.map.deinit(self.gpa);
    self.strings.deinit(self.gpa);
    self.bytes.deinit();
    self.* = undefined;
}

/// Returns the id for `s`, adding a copy of `s` if it is new. Thread-safe.
pub fn intern(self: *Interner, s: []const u8) Allocator.Error!Id {
    if (self.find(s)) |id| return id;

    self.lock.lockUncancelable(self.io);
    defer self.lock.unlock(self.io);
    try self.strings.ensureUnusedCapacity(self.gpa, 1);
    const gop = try self.map.getOrPut(self.gpa, s);
    if (gop.found_existing) return gop.value_ptr.*; // another thread won the race
    const copy = self.bytes.allocator().dupe(u8, s) catch |err| {
        self.map.removeByPtr(gop.key_ptr);
        return err;
    };
    const id: Id = .from(self.strings.items.len);
    gop.key_ptr.* = copy;
    gop.value_ptr.* = id;
    self.strings.appendAssumeCapacity(copy);
    return id;
}

/// Returns the id for `s` if it was interned. Thread-safe.
pub fn find(self: *Interner, s: []const u8) ?Id {
    self.lock.lockSharedUncancelable(self.io);
    defer self.lock.unlockShared(self.io);
    return self.map.get(s);
}

/// Returns the bytes for `id`; valid until `deinit`. Thread-safe.
pub fn get(self: *Interner, id: Id) []const u8 {
    self.lock.lockSharedUncancelable(self.io);
    defer self.lock.unlockShared(self.io);
    return self.strings.items[id.int()];
}

/// Number of distinct strings interned so far.
pub fn count(self: *Interner) u32 {
    self.lock.lockSharedUncancelable(self.io);
    defer self.lock.unlockShared(self.io);
    return @intCast(self.strings.items.len);
}

const testing = std.testing;
const Pool = @import("Pool.zig");

test "equal bytes get equal ids, different bytes different ids" {
    var in: Interner = .init(testing.allocator, testing.io);
    defer in.deinit();
    var buf = "foo".*;
    const a = try in.intern(&buf);
    buf[0] = 'g'; // the interner keeps its own copy
    try testing.expectEqual(a, try in.intern("foo"));
    try testing.expect(a != try in.intern("goo"));
    try testing.expectEqualStrings("foo", in.get(a));
    try testing.expectEqual(null, in.find("bar"));
    try testing.expectEqual(2, in.count());
}

test "equal ids for equal bytes under 8 threads" {
    var in: Interner = .init(testing.allocator, testing.io);
    defer in.deinit();
    var pool: Pool = undefined;
    try pool.init(testing.allocator, testing.io, 8);
    defer pool.deinit(testing.allocator);

    // 8 workers each intern the same 500 strings, in different orders.
    const words = 500;
    const workers = 8;
    var ids: [workers][words]Id = undefined;
    const Ctx = struct { in: *Interner, ids: *[workers][words]Id };
    pool.run(workers, Ctx{ .in = &in, .ids = &ids }, struct {
        fn f(c: Ctx, _: u32, w: usize) void {
            for (0..words) |k| {
                const i = (k * 7 + w * 61) % words; // 7 is coprime to 500
                var buf: [16]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "w{d}", .{i}) catch unreachable;
                c.ids[w][i] = c.in.intern(s) catch unreachable;
            }
        }
    }.f);

    try testing.expectEqual(words, in.count());
    for (0..words) |i| {
        for (1..workers) |w| try testing.expectEqual(ids[0][i], ids[w][i]);
        var buf: [16]u8 = undefined;
        try testing.expectEqualStrings(try std.fmt.bufPrint(&buf, "w{d}", .{i}), in.get(ids[0][i]));
    }
}
