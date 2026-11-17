//! Semantic Versioning 2.0 versions and Cargo-style version requirements
//! (§13.2 `version`, §13.4 requirements and compatibility lines).
//!
//! Nothing here allocates: prerelease and build strings are slices of the
//! parsed input, so the input must outlive the returned values.

const std = @import("std");
const Order = std.math.Order;

pub const Error = error{InvalidVersion};

/// A SemVer 2.0 version: `MAJOR.MINOR.PATCH[-PRERELEASE][+BUILD]`.
pub const Version = struct {
    major: u64,
    minor: u64,
    patch: u64,
    /// Dot-separated prerelease identifiers without the leading `-`; empty if none.
    pre: []const u8 = "",
    /// Dot-separated build identifiers without the leading `+`; empty if none.
    build: []const u8 = "",

    /// Parses a full version. Rejects leading zeros in numeric parts, empty
    /// identifiers and characters outside `[0-9A-Za-z-]`.
    pub fn parse(text: []const u8) Error!Version {
        var p: Parser = .{ .text = text };
        const v = try p.version(false);
        try p.end();
        return .{ .major = v.major, .minor = v.minor.?, .patch = v.patch.?, .pre = v.pre, .build = v.build };
    }

    /// SemVer 2.0 precedence. Build metadata is ignored.
    pub fn order(a: Version, b: Version) Order {
        return std.math.order(a.major, b.major).differ() orelse
            std.math.order(a.minor, b.minor).differ() orelse
            std.math.order(a.patch, b.patch).differ() orelse
            orderPre(a.pre, b.pre);
    }

    /// The semver-compatible line this version belongs to (§13.4).
    pub fn compatLine(v: Version) CompatLine {
        return if (v.major == 0) .{ .major = 0, .minor = v.minor } else .{ .major = v.major };
    }
};

/// Key of a semver-compatible line: the major version, or the minor version
/// for `0.x` (`minor` is 0 whenever `major > 0`). The resolver unifies versions
/// with equal keys; different keys may coexist.
pub const CompatLine = struct {
    major: u64,
    minor: u64 = 0,
};

/// Compares prerelease strings per SemVer 2.0 §11: a version without a
/// prerelease ranks above one with; identifiers compare numerically when
/// both are numeric, numeric ranks below alphanumeric, otherwise ASCII order;
/// a shorter list that is a prefix of a longer one ranks lower.
fn orderPre(a: []const u8, b: []const u8) Order {
    if (a.len == 0 or b.len == 0) return std.math.order(b.len, a.len);
    var ia = std.mem.splitScalar(u8, a, '.');
    var ib = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const x = ia.next() orelse return if (ib.next() == null) .eq else .lt;
        const y = ib.next() orelse return .gt;
        const xn = isNumeric(x);
        const yn = isNumeric(y);
        const o: Order = if (xn and yn)
            // No leading zeros, so the longer number is larger; avoids u64 overflow.
            std.math.order(x.len, y.len).differ() orelse std.mem.order(u8, x, y)
        else if (xn != yn)
            (if (xn) .lt else .gt)
        else
            std.mem.order(u8, x, y);
        if (o != .eq) return o;
    }
}

fn isNumeric(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// Comparison operator of one requirement comparator.
pub const Op = enum { exact, greater, greater_eq, less, less_eq, tilde, caret };

/// One comparator such as `>=1.2` or `~1.2.3`. Missing minor/patch mean a
/// partial version; a prerelease requires a full version.
pub const Comparator = struct {
    op: Op,
    major: u64,
    minor: ?u64 = null,
    patch: ?u64 = null,
    pre: []const u8 = "",

    /// Cargo semantics, without the prerelease opt-in rule (see `Requirement.matches`).
    pub fn matches(c: Comparator, v: Version) bool {
        return switch (c.op) {
            .exact => c.matchesExact(v),
            .greater => c.matchesGreater(v),
            .greater_eq => c.matchesExact(v) or c.matchesGreater(v),
            .less => c.matchesLess(v),
            .less_eq => c.matchesExact(v) or c.matchesLess(v),
            .tilde => c.matchesTilde(v),
            .caret => c.matchesCaret(v),
        };
    }

    fn matchesExact(c: Comparator, v: Version) bool {
        if (v.major != c.major) return false;
        if (c.minor) |m| if (v.minor != m) return false;
        if (c.patch) |p| if (v.patch != p) return false;
        return orderPre(v.pre, c.pre) == .eq;
    }

    fn matchesGreater(c: Comparator, v: Version) bool {
        if (v.major != c.major) return v.major > c.major;
        const m = c.minor orelse return false;
        if (v.minor != m) return v.minor > m;
        const p = c.patch orelse return false;
        if (v.patch != p) return v.patch > p;
        return orderPre(v.pre, c.pre) == .gt;
    }

    fn matchesLess(c: Comparator, v: Version) bool {
        if (v.major != c.major) return v.major < c.major;
        const m = c.minor orelse return false;
        if (v.minor != m) return v.minor < m;
        const p = c.patch orelse return false;
        if (v.patch != p) return v.patch < p;
        return orderPre(v.pre, c.pre) == .lt;
    }

    fn matchesTilde(c: Comparator, v: Version) bool {
        if (v.major != c.major) return false;
        if (c.minor) |m| if (v.minor != m) return false;
        if (c.patch) |p| if (v.patch != p) return v.patch > p;
        return orderPre(v.pre, c.pre) != .lt;
    }

    fn matchesCaret(c: Comparator, v: Version) bool {
        if (v.major != c.major) return false;
        const m = c.minor orelse return true;
        const p = c.patch orelse return if (c.major > 0) v.minor >= m else v.minor == m;
        if (c.major > 0) {
            if (v.minor != m) return v.minor > m;
            if (v.patch != p) return v.patch > p;
        } else if (m > 0) {
            if (v.minor != m) return false;
            if (v.patch != p) return v.patch > p;
        } else if (v.minor != m or v.patch != p) return false;
        return orderPre(v.pre, c.pre) != .lt;
    }

    /// True if `c` opts in to prereleases of `v`'s exact `major.minor.patch`.
    fn allowsPreOf(c: Comparator, v: Version) bool {
        return c.pre.len != 0 and c.major == v.major and c.minor == v.minor and c.patch == v.patch;
    }
};

/// A comma-separated conjunction of comparators, e.g. `">=1.2, <1.5"`.
/// A bare version means caret: `"1.2"` == `"^1.2"` == `>=1.2.0, <2.0.0`.
pub const Requirement = struct {
    /// shortcut: fixed capacity keeps parsing allocation-free; raise if real manifests need more.
    pub const max_comparators = 8;

    buf: [max_comparators]Comparator = undefined,
    len: usize = 0,

    pub const ParseError = error{ InvalidRequirement, TooManyComparators };

    pub fn parse(text: []const u8) ParseError!Requirement {
        var r: Requirement = .{};
        var it = std.mem.splitScalar(u8, text, ',');
        while (it.next()) |part| {
            if (r.len == max_comparators) return error.TooManyComparators;
            r.buf[r.len] = parseComparator(part) catch return error.InvalidRequirement;
            r.len += 1;
        }
        return r;
    }

    pub fn comparators(r: *const Requirement) []const Comparator {
        return r.buf[0..r.len];
    }

    /// True if `v` satisfies every comparator. A prerelease version matches
    /// only if some comparator names a prerelease of the same
    /// `major.minor.patch` (Cargo rule).
    pub fn matches(r: *const Requirement, v: Version) bool {
        for (r.comparators()) |c| if (!c.matches(v)) return false;
        if (v.pre.len == 0) return true;
        for (r.comparators()) |c| if (c.allowsPreOf(v)) return true;
        return false;
    }
};

fn parseComparator(part: []const u8) Error!Comparator {
    const s = std.mem.trim(u8, part, " \t");
    const ops = [_]struct { []const u8, Op }{
        .{ ">=", .greater_eq }, .{ "<=", .less_eq }, .{ ">", .greater }, .{ "<", .less },
        .{ "=", .exact },       .{ "^", .caret },    .{ "~", .tilde },
    };
    var op: Op = .caret;
    var rest = s;
    for (ops) |o| if (std.mem.startsWith(u8, s, o[0])) {
        op = o[1];
        rest = std.mem.trimStart(u8, s[o[0].len..], " \t");
        break;
    };
    var p: Parser = .{ .text = rest };
    const v = try p.version(true);
    try p.end();
    if (v.build.len != 0) return error.InvalidVersion;
    return .{ .op = op, .major = v.major, .minor = v.minor, .patch = v.patch, .pre = v.pre };
}

const Parser = struct {
    text: []const u8,
    i: usize = 0,

    const Partial = struct { major: u64, minor: ?u64 = null, patch: ?u64 = null, pre: []const u8 = "", build: []const u8 = "" };

    fn version(p: *Parser, allow_partial: bool) Error!Partial {
        var v: Partial = .{ .major = try p.number() };
        if (p.eat('.')) {
            v.minor = try p.number();
            if (p.eat('.')) v.patch = try p.number();
        }
        if (v.patch == null) {
            if (!allow_partial) return error.InvalidVersion;
            return v; // `-`/`+` after a partial version is left for `end` to reject.
        }
        if (p.eat('-')) v.pre = try p.identifiers(true);
        if (p.eat('+')) v.build = try p.identifiers(false);
        return v;
    }

    fn number(p: *Parser) Error!u64 {
        const start = p.i;
        while (p.i < p.text.len and std.ascii.isDigit(p.text[p.i])) p.i += 1;
        const digits = p.text[start..p.i];
        if (digits.len == 0 or (digits.len > 1 and digits[0] == '0')) return error.InvalidVersion;
        return std.fmt.parseInt(u64, digits, 10) catch error.InvalidVersion;
    }

    /// Dot-separated non-empty `[0-9A-Za-z-]+` identifiers; `pre` forbids
    /// leading zeros in numeric identifiers.
    fn identifiers(p: *Parser, pre: bool) Error![]const u8 {
        const start = p.i;
        while (p.i < p.text.len and (std.ascii.isAlphanumeric(p.text[p.i]) or p.text[p.i] == '-' or p.text[p.i] == '.')) p.i += 1;
        const s = p.text[start..p.i];
        var it = std.mem.splitScalar(u8, s, '.');
        while (it.next()) |id| {
            if (id.len == 0) return error.InvalidVersion;
            if (pre and id.len > 1 and id[0] == '0' and isNumeric(id)) return error.InvalidVersion;
        }
        return s;
    }

    fn eat(p: *Parser, c: u8) bool {
        if (p.i < p.text.len and p.text[p.i] == c) {
            p.i += 1;
            return true;
        }
        return false;
    }

    fn end(p: *Parser) Error!void {
        if (p.i != p.text.len) return error.InvalidVersion;
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn ver(text: []const u8) Version {
    return Version.parse(text) catch unreachable;
}

fn expectMatches(req: []const u8, yes: []const []const u8, no: []const []const u8) !void {
    const r = try Requirement.parse(req);
    for (yes) |s| testing.expect(r.matches(ver(s))) catch |e| {
        std.debug.print("{s} should match {s}\n", .{ req, s });
        return e;
    };
    for (no) |s| testing.expect(!r.matches(ver(s))) catch |e| {
        std.debug.print("{s} should not match {s}\n", .{ req, s });
        return e;
    };
}

test "version parse" {
    const x = ver("1.2.3-alpha.1+build.007");
    try testing.expectEqual(@as(u64, 1), x.major);
    try testing.expectEqual(@as(u64, 2), x.minor);
    try testing.expectEqual(@as(u64, 3), x.patch);
    try testing.expectEqualStrings("alpha.1", x.pre);
    try testing.expectEqualStrings("build.007", x.build);
    for ([_][]const u8{ "", "1", "1.2", "01.2.3", "1.2.3-", "1.2.3-a..b", "1.2.3-01", "1.2.3+", "1.2.3 ", "1.2.3-a_b", "v1.2.3", "1.2.3.4" }) |bad|
        try testing.expectError(error.InvalidVersion, Version.parse(bad));
}

test "prerelease ordering per SemVer 2.0" {
    // SemVer 2.0 §11 example chain, extended past the release.
    const chain = [_][]const u8{ "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1", "1.1.0", "2.0.0" };
    for (chain[0 .. chain.len - 1], chain[1..]) |a, b| {
        try testing.expectEqual(Order.lt, ver(a).order(ver(b)));
        try testing.expectEqual(Order.gt, ver(b).order(ver(a)));
    }
    try testing.expectEqual(Order.eq, ver("1.0.0+a").order(ver("1.0.0+b")));
    try testing.expectEqual(Order.lt, ver("1.0.0-99999999999999999999").order(ver("1.0.0-100000000000000000000")));
}

test "1.2 == ^1.2 == >=1.2.0, <2.0.0" {
    const yes = [_][]const u8{ "1.2.0", "1.2.9", "1.9.0", "1.99.99" };
    const no = [_][]const u8{ "1.1.9", "2.0.0", "0.9.0", "2.0.0-alpha", "1.5.0-rc.1" };
    for ([_][]const u8{ "1.2", "^1.2", ">=1.2.0, <2.0.0" }) |req| try expectMatches(req, &yes, &no);
}

test "caret on 0.x and partials" {
    try expectMatches("^0.2.3", &.{ "0.2.3", "0.2.9" }, &.{ "0.2.2", "0.3.0", "1.0.0" });
    try expectMatches("^0.0.3", &.{"0.0.3"}, &.{ "0.0.4", "0.1.0" });
    try expectMatches("^0.0", &.{ "0.0.0", "0.0.9" }, &.{"0.1.0"});
    try expectMatches("^1", &.{ "1.0.0", "1.9.9" }, &.{"2.0.0"});
    try expectMatches("0.9", &.{ "0.9.0", "0.9.7" }, &.{ "0.10.0", "0.8.9" });
}

test "tilde" {
    try expectMatches("~1.2.3", &.{ "1.2.3", "1.2.9" }, &.{ "1.2.2", "1.3.0", "2.0.0" });
    try expectMatches("~1.2", &.{ "1.2.0", "1.2.9" }, &.{ "1.3.0", "1.1.9" });
    try expectMatches("~1", &.{ "1.0.0", "1.9.0" }, &.{"2.0.0"});
}

test "exact and comparison operators" {
    try expectMatches("=1.2.3", &.{"1.2.3"}, &.{ "1.2.4", "1.2.2" });
    try expectMatches("=1.2", &.{ "1.2.0", "1.2.7" }, &.{"1.3.0"});
    try expectMatches(">=1.2, <1.5", &.{ "1.2.0", "1.4.99" }, &.{ "1.1.9", "1.5.0", "1.5.0-alpha" });
    try expectMatches("> 1.2", &.{"1.3.0"}, &.{ "1.2.9", "1.2.0" });
    try expectMatches("<=1.2", &.{ "1.2.9", "0.1.0" }, &.{"1.3.0"});
    try expectMatches("<1.2.3", &.{"1.2.2"}, &.{"1.2.3"});
}

test "prereleases only match when a comparator opts in" {
    try expectMatches(">=1.2.3-alpha.2", &.{ "1.2.3-alpha.2", "1.2.3-beta", "1.2.3", "1.3.0" }, &.{ "1.2.3-alpha.1", "1.3.0-alpha" });
    try expectMatches("^1.2.3-rc.1", &.{ "1.2.3-rc.1", "1.2.3-rc.2", "1.2.4" }, &.{ "1.2.4-rc.1", "2.0.0" });
    try expectMatches("=1.0.0-beta", &.{"1.0.0-beta"}, &.{ "1.0.0-alpha", "1.0.0" });
}

test "requirement parse errors" {
    for ([_][]const u8{ "", "1.2,", "1.2-alpha", "^", ">=1.2.3+build", "1.2.3 x", "*", "01.2" }) |bad|
        try testing.expectError(error.InvalidRequirement, Requirement.parse(bad));
    try testing.expectError(error.TooManyComparators, Requirement.parse(">=1, >=1, >=1, >=1, >=1, >=1, >=1, >=1, >=1"));
}

test "compatibility line: major, or minor for 0.x" {
    try testing.expectEqual(CompatLine{ .major = 1 }, ver("1.2.3").compatLine());
    try testing.expectEqual(ver("1.0.0").compatLine(), ver("1.9.4-rc.1").compatLine());
    try testing.expectEqual(CompatLine{ .major = 0, .minor = 4 }, ver("0.4.2").compatLine());
    try testing.expect(!std.meta.eql(ver("0.4.2").compatLine(), ver("0.5.0").compatLine()));
    try testing.expect(!std.meta.eql(ver("1.0.0").compatLine(), ver("2.0.0").compatLine()));
}
