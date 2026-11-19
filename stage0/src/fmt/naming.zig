//! The naming conventions of §2.3, checked by `pyro fmt --check`: types and
//! protocols `PascalCase`; functions, variables, fields and enum variants
//! `snake_case`.
//!
//! Only names whose category the syntax alone decides are checked (see
//! `docs/style.md`). A `const` item may be a constant (`SCREAMING_SNAKE_CASE`)
//! or a type (`PascalCase`), and a `comptime` parameter or generic parameter a
//! type or a value: telling them apart needs types, so they are not checked.
//! Functions in an `extern` block keep their C names.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("../ast/Ast.zig");

/// A naming convention of §2.3.
pub const Case = enum {
    snake_case,
    PascalCase,

    /// Whether `name` (without any `r#`) follows the convention.
    pub fn matches(c: Case, name: []const u8) bool {
        return switch (c) {
            .snake_case => for (name) |ch| {
                if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '_')) break false;
            } else true,
            .PascalCase => std.ascii.isUpper(name[0]) and for (name) |ch| {
                if (!std.ascii.isAlphanumeric(ch)) break false;
            } else true,
        };
    }
};

/// A declared name that breaks its convention.
pub const Violation = struct {
    /// The IDENT token of the name.
    token: Ast.TokenIndex,
    /// The convention it should follow.
    want: Case,
};

/// Returns the declared names in `ast` that break their convention, in node
/// order. The result is owned by the caller.
pub fn check(gpa: Allocator, ast: *const Ast) Allocator.Error![]Violation {
    const kinds = ast.tokens.items(.kind);
    var extern_names: std.ArrayList(Ast.TokenIndex) = .empty;
    defer extern_names.deinit(gpa);
    var out: std.ArrayList(Violation) = .empty;
    errdefer out.deinit(gpa);
    for (ast.nodes.items(.kind), ast.nodes.items(.main_token), 0..) |k, mt, i| {
        const n: Ast.Node.Index = .from(i);
        const name: Ast.TokenIndex, const want: Case = switch (k) {
            .extern_block => {
                for (ast.data(n).extern_block.fns) |f| {
                    const inner = if (ast.kind(f) == .attributed) ast.data(f).attributed.inner else f;
                    try extern_names.append(gpa, ast.mainToken(inner) + 1);
                }
                continue;
            },
            .struct_decl, .enum_decl, .protocol_decl, .type_alias, .type_distinct => .{ mt + 1, .PascalCase },
            .fn_decl => .{ mt + 1, .snake_case },
            .field_decl, .variant_decl, .pat_bind, .pat_bind_mut => .{ mt, .snake_case },
            .param => if (kinds[mt] == .ident and !(mt > 0 and kinds[mt - 1] == .kw_comptime)) .{ mt, .snake_case } else continue,
            else => continue,
        };
        if (kinds[name] != .ident) continue;
        const text = ast.tokenSlice(name);
        if (!want.matches(if (std.mem.startsWith(u8, text, "r#")) text[2..] else text)) {
            try out.append(gpa, .{ .token = name, .want = want });
        }
    }
    // An `extern_block` node comes after its functions, so drop their names only now.
    var kept: usize = 0;
    for (out.items) |v| {
        if (std.mem.indexOfScalar(Ast.TokenIndex, extern_names.items, v.token) != null) continue;
        out.items[kept] = v;
        kept += 1;
    }
    out.shrinkRetainingCapacity(kept);
    std.mem.sort(Violation, out.items, {}, struct {
        fn lt(_: void, a: Violation, b: Violation) bool {
            return a.token < b.token;
        }
    }.lt);
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const fmt = @import("fmt.zig");
const diag = @import("../diag/diag.zig");

test "conventions" {
    try testing.expect(Case.snake_case.matches("x_1"));
    try testing.expect(Case.snake_case.matches("_"));
    try testing.expect(!Case.snake_case.matches("xY"));
    try testing.expect(Case.PascalCase.matches("Vec2"));
    try testing.expect(!Case.PascalCase.matches("vec"));
    try testing.expect(!Case.PascalCase.matches("My_Type"));
}

test "names classified by syntax are checked; const, comptime and extern names are not" {
    var sink: diag.Sink = .init(testing.allocator, testing.io);
    defer sink.deinit();
    var ast = (try fmt.parse(testing.allocator,
        \\struct bad_type { Field: i32, ok: i32 }
        \\enum Color { Red, green }
        \\protocol Ord {}
        \\type alias_t = i32;
        \\const anything_Goes: i32 = 1;
        \\extern "C" { fn SDL_Init(flags: u32) -> i32; }
        \\fn BadFn(X: i32, comptime T: type, r#type: i32) {
        \\    let Y = |Z| Z;
        \\    let (a, mut B) = (1, 2);
        \\}
        \\
    , @fromBackingInt(0), &sink)).?;
    defer ast.deinit(testing.allocator);
    const got = try check(testing.allocator, &ast);
    defer testing.allocator.free(got);
    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(testing.allocator);
    for (got) |v| try names.print(testing.allocator, "{s}:{t} ", .{ ast.tokenSlice(v.token), v.want });
    try testing.expectEqualStrings(
        "bad_type:PascalCase Field:snake_case Red:snake_case alias_t:PascalCase BadFn:snake_case X:snake_case Y:snake_case Z:snake_case B:snake_case ",
        names.items,
    );
}
