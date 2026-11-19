//! Untyped constants and conversions (§4.8, §4.9, §4.7, §4.2.4).
//!
//! - `Const` holds an untyped constant: an arbitrary-precision integer or an
//!   exact rational. `fromInt`/`parseFloat` build one from a literal and
//!   `binary`/`negate`/`bitNot`/`order` fold constant expressions, which
//!   stay untyped (§4.8).
//! - `convertConst` converts an untyped constant where a type is expected
//!   (rule 1 of §4.9.1) and `castConst` applies `as` to one (§4.9.2). Both
//!   give the typed value or the diagnostic code to report.
//! - `coerce` decides whether a value of one type converts implicitly to
//!   another (rules 1-9 of §4.9.1); `cast` decides whether `x as T` is legal
//!   (the §4.9.2 table, E0307).
//! - `defaultType` gives the type of an untyped constant with no context.
//!
//! This file only classifies; the checker reports diagnostics and inserts
//! the conversions.

const std = @import("std");
const Allocator = std.mem.Allocator;
const BigInt = std.math.big.int.Managed;
const Types = @import("types.zig");
const TypeId = Types.TypeId;
const DiagCode = @import("../diag/diag.zig").DiagCode;

/// An exact rational `num / den`: `den` is positive and `gcd(num, den) == 1`,
/// so equal values have equal representations.
pub const Rational = struct {
    num: BigInt,
    den: BigInt,

    pub fn deinit(r: *Rational) void {
        r.num.deinit();
        r.den.deinit();
    }

    /// Normalizes `num / den` in place and moves both into the result. On
    /// error the caller still owns them (possibly modified). Asserts `den != 0`.
    fn init(num: *BigInt, den: *BigInt) Allocator.Error!Rational {
        std.debug.assert(!den.eqlZero());
        if (!den.isPositive()) {
            den.negate();
            num.negate();
        }
        if (num.eqlZero()) {
            try den.set(1);
        } else {
            var g = try BigInt.init(num.allocator);
            defer g.deinit();
            try g.gcd(num, den);
            try divTruncInPlace(num, &g);
            try divTruncInPlace(den, &g);
        }
        return .{ .num = num.*, .den = den.* };
    }
};

/// An untyped constant (§4.8): an untyped integer or an untyped float.
pub const Const = union(enum) {
    int: BigInt,
    float: Rational,

    pub fn deinit(c: *Const) void {
        switch (c.*) {
            .int => |*i| i.deinit(),
            .float => |*r| r.deinit(),
        }
    }

    /// `.untyped_int` or `.untyped_float`.
    pub fn typeOf(c: Const) TypeId {
        return switch (c) {
            .int => .untyped_int,
            .float => .untyped_float,
        };
    }
};

/// Largest decimal exponent and shift amount a constant may use. Larger ones
/// would make constants of millions of bits; they fail with `TooLarge`.
pub const max_magnitude = 1 << 16;

pub const FoldError = Allocator.Error || error{
    /// Integer or float division (or `%`) by zero.
    DivisionByZero,
    /// Operator not defined for the operands: bitwise or shift on a float,
    /// or a negative shift amount.
    InvalidOperand,
    /// Shift amount or exponent above `max_magnitude`.
    TooLarge,
};

/// An untyped integer constant with value `value` (any integer type).
pub fn fromInt(gpa: Allocator, value: anytype) Allocator.Error!Const {
    return .{ .int = try .initSet(gpa, value) };
}

/// The exact value of the text of an untyped `FLOAT_LIT` (§2.6.2): well-formed
/// and without suffix, e.g. `1_000.25e-3`.
pub fn parseFloat(gpa: Allocator, text: []const u8) error{ OutOfMemory, TooLarge }!Const {
    var digits: std.ArrayList(u8) = .empty;
    defer digits.deinit(gpa);
    var exp: i64 = 0;
    var i: usize = 0;
    var in_fraction = false;
    while (i < text.len) : (i += 1) switch (text[i]) {
        '_' => {},
        '.' => in_fraction = true,
        'e', 'E' => break,
        else => |c| {
            try digits.append(gpa, c);
            if (in_fraction) exp -= 1;
        },
    };
    if (i < text.len) {
        var e: i64 = 0;
        var sign: i64 = 1;
        for (text[i + 1 ..]) |c| switch (c) {
            '+', '_' => {},
            '-' => sign = -1,
            else => {
                e = e * 10 + (c - '0');
                if (e > max_magnitude) return error.TooLarge;
            },
        };
        exp += sign * e;
    }
    if (exp > max_magnitude or exp < -max_magnitude) return error.TooLarge;

    var num = try BigInt.init(gpa);
    errdefer num.deinit();
    num.setString(10, digits.items) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable, // the lexer only produces well-formed literals
    };
    var den = try BigInt.initSet(gpa, 1);
    errdefer den.deinit();
    var pow = try BigInt.initSet(gpa, 10);
    defer pow.deinit();
    try pow.pow(&pow, @intCast(@abs(exp)));
    if (exp > 0) try num.mul(&num, &pow) else try den.copy(pow.toConst());
    return .{ .float = try .init(&num, &den) };
}

/// Binary operators that fold on untyped constants.
pub const BinOp = enum { add, sub, mul, div, rem, shl, shr, bit_and, bit_or, bit_xor };

/// Folds `a op b` into a new constant owned by the caller. Integer `/` and
/// `%` truncate toward zero (§6.4.3), shifts and bitwise operators act on
/// infinite two's complement, and `>>` is arithmetic. An untyped integer
/// mixed with an untyped float is promoted to float.
pub fn binary(gpa: Allocator, op: BinOp, a: Const, b: Const) FoldError!Const {
    if (a == .int and b == .int) return .{ .int = try intBinary(gpa, op, &a.int, &b.int) };
    switch (op) {
        .add, .sub, .mul, .div, .rem => {},
        else => return error.InvalidOperand,
    }
    var x = try toRational(gpa, a);
    defer x.deinit();
    var y = try toRational(gpa, b);
    defer y.deinit();
    return .{ .float = try ratBinary(gpa, op, &x, &y) };
}

/// Unary `-a`.
pub fn negate(a: Const) Allocator.Error!Const {
    var r = try clone(a);
    switch (r) {
        .int => |*i| i.negate(),
        .float => |*f| f.num.negate(),
    }
    return r;
}

/// Unary `~a` on an untyped integer: `-a - 1`.
pub fn bitNot(gpa: Allocator, a: Const) FoldError!Const {
    if (a != .int) return error.InvalidOperand;
    var r = try BigInt.init(gpa);
    errdefer r.deinit();
    try r.addScalar(&a.int, 1);
    r.negate();
    return .{ .int = r };
}

/// Compares two constants by value (for `== != < <= > >=`).
pub fn order(gpa: Allocator, a: Const, b: Const) Allocator.Error!std.math.Order {
    if (a == .int and b == .int) return a.int.order(b.int);
    var x = try toRational(gpa, a);
    defer x.deinit();
    var y = try toRational(gpa, b);
    defer y.deinit();
    var l = try BigInt.init(gpa);
    defer l.deinit();
    var r = try BigInt.init(gpa);
    defer r.deinit();
    try l.mul(&x.num, &y.den);
    try r.mul(&y.num, &x.den);
    return l.order(r);
}

/// The type of an untyped constant with no context (§4.8): `i64` for an
/// untyped integer, `f64` for an untyped float; any other type unchanged.
pub fn defaultType(ty: TypeId) TypeId {
    return switch (ty) {
        .untyped_int => .int(.signed, 64),
        .untyped_float => .f64,
        else => ty,
    };
}

/// Result of converting an untyped constant to a type.
pub const ConstResult = union(enum) {
    /// The typed value. `bits` holds an integer in two's complement
    /// (sign-extended to 64 bits) or the IEEE bits of an `f32`/`f64`.
    /// `type` is the requested type, a distinct type included.
    ok: Types.Value,
    err: DiagCode,
};

/// Rule 1 of §4.9.1: converts untyped constant `c` to `to`. An integer type
/// needs an integer constant that fits (E0306); a float type rounds to
/// nearest even and must stay finite (E0306); a distinct type converts
/// through its underlying type (§4.7). Any other type is a mismatch (E0310).
/// `ptr_bits` is the width of `usize`/`isize`.
pub fn convertConst(gpa: Allocator, types: *Types, ptr_bits: u8, c: Const, to: TypeId) Allocator.Error!ConstResult {
    return constTo(gpa, types, ptr_bits, c, to, .implicit);
}

/// `c as to` for untyped constant `c` (§4.9.2): like `convertConst`, except
/// that an untyped float converts to an integer type by rounding toward
/// zero. The result must fit (E0306: `300 as u8` is an error, not a
/// truncation). Targets outside the table are E0307.
pub fn castConst(gpa: Allocator, types: *Types, ptr_bits: u8, c: Const, to: TypeId) Allocator.Error!ConstResult {
    return constTo(gpa, types, ptr_bits, c, to, .cast);
}

fn constTo(gpa: Allocator, types: *Types, ptr_bits: u8, c: Const, to: TypeId, mode: enum { implicit, cast }) Allocator.Error!ConstResult {
    const target = underlying(types, to);
    const bad: DiagCode = if (mode == .cast) .E0307 else .E0310;
    if (target == .err) return .{ .ok = .{ .type = to, .bits = 0 } }; // already reported
    if (target == .f32 or target == .f64) {
        var r = try toRational(gpa, c);
        defer r.deinit();
        const bits: u64 = if (target == .f32)
            @as(u32, @bitCast(try roundRational(f32, &r) orelse return .{ .err = .E0306 }))
        else
            @bitCast(try roundRational(f64, &r) orelse return .{ .err = .E0306 });
        return .{ .ok = .{ .type = to, .bits = bits } };
    }
    const int = intInfo(types, ptr_bits, target) orelse return .{ .err = bad };
    var value = switch (c) {
        .int => |i| try i.clone(),
        .float => |f| if (mode == .cast) blk: {
            var q = try BigInt.init(gpa);
            errdefer q.deinit();
            var rem = try BigInt.init(gpa);
            defer rem.deinit();
            try q.divTrunc(&rem, &f.num, &f.den);
            break :blk q;
        } else return .{ .err = .E0306 },
    };
    defer value.deinit();
    if (!value.fitsInTwosComp(int.signedness, int.bits)) return .{ .err = .E0306 };
    const bits: u64 = if (value.isPositive()) value.toInt(u64) catch unreachable else @bitCast(value.toInt(i64) catch unreachable);
    return .{ .ok = .{ .type = to, .bits = bits } };
}

/// How a value converts implicitly (§4.9.1). The rule number is in brackets.
pub const Coercion = enum {
    /// Same type; nothing to do. Also returned when either side is `.err`.
    identity,
    /// [1] `from` is an untyped constant: `convertConst` gives the value or
    /// the error.
    constant,
    /// [2] `uN`/`iN` to a wider integer: zero- or sign-extend.
    int_widen,
    /// [3] `f32` to `f64`.
    float_widen,
    /// [4] `noreturn` to any type.
    never,
    /// [5] `[N]T` place to `[]T`.
    array_to_slice,
    /// [5] `soa [N]T` place to `soa []T`.
    soa_array_to_soa_slice,
    /// [6] `*T` to `*const T`.
    ptr_to_const,
    /// [7] Non-capturing lambda to a function pointer. The checker matches
    /// the lambda against the signature (§6.10).
    lambda_to_fn_ptr,
    /// [8] `T` to `Option<T>`: wrap in `.some`. For an untyped constant,
    /// first convert it to the payload type (`optionPayload`).
    wrap_some,
    /// [9] Non-generic function name to `std.meta.FnRef`.
    fn_ref,
    /// No implicit conversion: a type mismatch (E0310).
    none,
};

/// Facts about the converted expression that its type does not carry.
pub const Form = struct {
    /// The expression is a place (§5), so an array can be viewed as a slice.
    place: bool = false,
    /// The expression is a lambda without captures.
    non_capturing_lambda: bool = false,
    /// The expression names a non-generic function.
    non_generic_fn: bool = false,
};

/// Classifies the implicit conversion of a `from` value to `to` (§4.9.1).
/// A `[]T` with a mutable origin used as a read-only view has the same type,
/// so rule 5's last case is `.identity`.
pub fn coerce(types: *Types, from: TypeId, to: TypeId, form: Form) Coercion {
    if (from == to or from == .err or to == .err) return .identity;
    if (from == .noreturn) return .never;
    if (to == .fn_ref) return if (form.non_generic_fn) .fn_ref else .none;
    const to_key = types.get(to);
    if (form.non_capturing_lambda) return if (to_key == .fn_ptr) .lambda_to_fn_ptr else .none;
    if (optionPayload(types, to)) |payload| {
        if (from == payload or isUntyped(from)) return .wrap_some;
    }
    if (isUntyped(from)) return .constant;
    if (from == .f32 and to == .f64) return .float_widen;
    return switch (types.get(from)) {
        .int => if (intWidens(types, from, to)) .int_widen else .none,
        .array => |a| if (form.place and to_key == .slice and to_key.slice.elem == a.elem) .array_to_slice else .none,
        .soa_array => |a| if (form.place and to_key == .soa_slice and to_key.soa_slice.elem == a.elem) .soa_array_to_soa_slice else .none,
        .ptr => |p| if (!p.is_const and to_key == .ptr and to_key.ptr.is_const and to_key.ptr.elem == p.elem) .ptr_to_const else .none,
        else => .none,
    };
}

/// The payload `T` if `ty` is `Option<T>`, else null.
pub fn optionPayload(types: *Types, ty: TypeId) ?TypeId {
    return switch (types.get(ty)) {
        .nominal => |n| if (n.lang == .option and n.args.len == 1 and n.args[0] == .type) n.args[0].type else null,
        else => null,
    };
}

/// A legal `as` conversion (§4.9.2).
pub const Cast = enum {
    /// Same type, `noreturn`, or an `.err` operand.
    identity,
    /// `from` is an untyped constant: `castConst` gives the value or the error.
    constant,
    /// Truncate, or zero/sign-extend by source signedness.
    int_to_int,
    /// Round to nearest even.
    int_to_float,
    /// Round toward zero; saturate; NaN to 0.
    float_to_int,
    /// Round to nearest even (`f64` to `f32`), or widen.
    float_to_float,
    /// `false` to 0, `true` to 1.
    bool_to_int,
    /// Discriminant of a payload-free enum, to its backing type or wider.
    enum_to_int,
    /// `distinct D` to its underlying type, or back.
    distinct,
    /// `vec<N, A>` to `vec<N, B>`, lane-wise by the scalar rules.
    vec,
    /// Pointer to `usize`; address unchanged.
    ptr_to_int,
    /// Pointer to another pointer type; address unchanged.
    ptr_to_ptr,
    /// `usize` to `*T`: legal only in `unsafe` code (§12.2); the checker
    /// enforces that.
    int_to_ptr,
};

/// Classifies `x as to` where `x: from` (§4.9.2). `enum_backing` is the
/// backing integer type of `from` if it is a payload-free enum, `.none`
/// otherwise. Null means the cast is invalid (E0307); integer to `bool` is
/// one such case.
pub fn cast(types: *Types, from: TypeId, to: TypeId, enum_backing: TypeId) ?Cast {
    if (from == to or from == .err or to == .err or from == .noreturn) return .identity;
    if (isUntyped(from)) return .constant;
    if (enum_backing != .none) return if (enum_backing == to or intWidens(types, enum_backing, to) or backingFitsPtr(types, enum_backing, to)) .enum_to_int else null;
    const from_key = types.get(from);
    const to_key = types.get(to);
    if (from_key == .nominal and from_key.nominal.underlying == to) return .distinct;
    if (to_key == .nominal and to_key.nominal.underlying == from) return .distinct;
    if (from_key == .vec and to_key == .vec) {
        const a = from_key.vec;
        const b = to_key.vec;
        if (a.len != b.len) return null;
        return if (cast(types, a.elem, b.elem, .none) != null) .vec else null;
    }
    const from_int = isInt(types, from);
    const to_int = isInt(types, to);
    const from_float = from == .f32 or from == .f64;
    const to_float = to == .f32 or to == .f64;
    if (from_int and to_int) return .int_to_int;
    if (from_int and to_float) return .int_to_float;
    if (from_float and to_int) return .float_to_int;
    if (from_float and to_float) return .float_to_float;
    if (from == .bool and to_int) return .bool_to_int;
    if (from_key == .ptr) {
        if (to == .usize) return .ptr_to_int;
        if (to_key == .ptr) return .ptr_to_ptr;
    }
    if (from == .usize and to_key == .ptr) return .int_to_ptr;
    return null;
}

fn isUntyped(ty: TypeId) bool {
    return ty == .untyped_int or ty == .untyped_float;
}

fn isInt(types: *Types, ty: TypeId) bool {
    return ty == .usize or ty == .isize or types.get(ty) == .int;
}

/// Rule 2: `uN` to `uM`, `iN` to `iM`, or `uN` to `iM`, with M > N.
fn intWidens(types: *Types, from: TypeId, to: TypeId) bool {
    const a = types.get(from);
    const b = types.get(to);
    if (a != .int or b != .int) return false;
    if (b.int.bits <= a.int.bits) return false;
    return a.int.signedness == b.int.signedness or a.int.signedness == .unsigned;
}

/// `usize`/`isize` are at least 32 bits (§4.2.2), so a `uN` with N <= 32
/// widens to `usize`, and a `uN` with N < 32 or an `iN` with N <= 32
/// widens to `isize`.
fn backingFitsPtr(types: *Types, from: TypeId, to: TypeId) bool {
    const a = switch (types.get(from)) {
        .int => |i| i,
        else => return false,
    };
    return switch (to) {
        .usize => a.signedness == .unsigned and a.bits <= 32,
        .isize => if (a.signedness == .unsigned) a.bits < 32 else a.bits <= 32,
        else => false,
    };
}

const IntInfo = struct { signedness: std.builtin.Signedness, bits: u8 };

fn intInfo(types: *Types, ptr_bits: u8, ty: TypeId) ?IntInfo {
    return switch (ty) {
        .usize => .{ .signedness = .unsigned, .bits = ptr_bits },
        .isize => .{ .signedness = .signed, .bits = ptr_bits },
        else => switch (types.get(ty)) {
            .int => |i| .{ .signedness = i.signedness, .bits = i.bits },
            else => null,
        },
    };
}

/// Strips distinct wrappers (§4.7).
fn underlying(types: *Types, ty: TypeId) TypeId {
    var t = ty;
    while (true) switch (types.get(t)) {
        .nominal => |n| if (n.kind == .distinct) {
            t = n.underlying;
        } else return t,
        else => return t,
    };
}

fn clone(c: Const) Allocator.Error!Const {
    return switch (c) {
        .int => |i| .{ .int = try i.clone() },
        .float => |f| blk: {
            var num = try f.num.clone();
            errdefer num.deinit();
            break :blk .{ .float = .{ .num = num, .den = try f.den.clone() } };
        },
    };
}

fn toRational(gpa: Allocator, c: Const) Allocator.Error!Rational {
    return switch (c) {
        .int => |i| blk: {
            var num = try i.clone();
            errdefer num.deinit();
            break :blk .{ .num = num, .den = try .initSet(gpa, 1) };
        },
        .float => (try clone(c)).float,
    };
}

/// `a = a / b`, truncated.
fn divTruncInPlace(a: *BigInt, b: *const BigInt) Allocator.Error!void {
    var q = try BigInt.init(a.allocator);
    defer q.deinit();
    var r = try BigInt.init(a.allocator);
    defer r.deinit();
    try q.divTrunc(&r, a, b);
    a.swap(&q);
}

fn intBinary(gpa: Allocator, op: BinOp, a: *const BigInt, b: *const BigInt) FoldError!BigInt {
    var r = try BigInt.init(gpa);
    errdefer r.deinit();
    switch (op) {
        .add => try r.add(a, b),
        .sub => try r.sub(a, b),
        .mul => try r.mul(a, b),
        .div, .rem => {
            if (b.eqlZero()) return error.DivisionByZero;
            var other = try BigInt.init(gpa);
            defer other.deinit();
            if (op == .div) try r.divTrunc(&other, a, b) else try other.divTrunc(&r, a, b);
        },
        .shl, .shr => {
            if (!b.isPositive() and !b.eqlZero()) return error.InvalidOperand;
            const n = b.toInt(u32) catch return error.TooLarge;
            if (op == .shr) {
                try r.shiftRight(a, n);
            } else {
                if (n > max_magnitude) return error.TooLarge;
                try r.shiftLeft(a, n);
            }
        },
        .bit_and => try r.bitAnd(a, b),
        .bit_or => try r.bitOr(a, b),
        .bit_xor => try r.bitXor(a, b),
    }
    return r;
}

fn ratBinary(gpa: Allocator, op: BinOp, x: *const Rational, y: *const Rational) FoldError!Rational {
    var num = try BigInt.init(gpa);
    errdefer num.deinit();
    var den = try BigInt.init(gpa);
    errdefer den.deinit();
    var t = try BigInt.init(gpa);
    defer t.deinit();
    switch (op) {
        .add, .sub => {
            try num.mul(&x.num, &y.den);
            try t.mul(&y.num, &x.den);
            if (op == .add) try num.add(&num, &t) else try num.sub(&num, &t);
            try den.mul(&x.den, &y.den);
        },
        .mul => {
            try num.mul(&x.num, &y.num);
            try den.mul(&x.den, &y.den);
        },
        .div => {
            if (y.num.eqlZero()) return error.DivisionByZero;
            try num.mul(&x.num, &y.den);
            try den.mul(&x.den, &y.num);
        },
        .rem => {
            // x - trunc(x / y) * y, which has the sign of x (§6.4.3).
            if (y.num.eqlZero()) return error.DivisionByZero;
            var q = try ratBinary(gpa, .div, x, y);
            defer q.deinit();
            divTruncInPlace(&q.num, &q.den) catch |e| return e;
            try q.den.set(1);
            var p = try ratBinary(gpa, .mul, &q, y);
            defer p.deinit();
            const r = try ratBinary(gpa, .sub, x, &p);
            num.deinit();
            den.deinit();
            return r;
        },
        else => unreachable,
    }
    return Rational.init(&num, &den);
}

/// The value of `r` in float type `F`, rounded to nearest even (§4.2.3);
/// null if it rounds past the largest finite value. Values below the
/// smallest subnormal round to zero.
fn roundRational(comptime F: type, r: *const Rational) Allocator.Error!?F {
    const gpa = r.num.allocator;
    if (r.num.eqlZero()) return 0;
    const m = std.math.floatMantissaBits(F) + 1; // significand bits
    const quantum = std.math.floatExponentMin(F) - (m - 1); // exponent of the smallest subnormal

    var p = try r.num.clone();
    defer p.deinit();
    p.abs();
    const q = &r.den;
    // e = floor(log2(p / q)): first estimate from bit lengths, then fix by one.
    var e: isize = @as(isize, @intCast(p.bitCountAbs())) - @as(isize, @intCast(q.bitCountAbs()));
    {
        var a = try p.clone();
        defer a.deinit();
        var b = try q.clone();
        defer b.deinit();
        if (e >= 0) try b.shiftLeft(&b, @intCast(e)) else try a.shiftLeft(&a, @intCast(-e));
        if (a.order(b) == .lt) e -= 1;
    }
    if (e > std.math.floatExponentMax(F)) return null;
    const sign: F = if (r.num.isPositive()) 1 else -1;
    if (e < quantum - 1) return sign * 0; // below half the smallest subnormal

    // n = p / q / 2^u, rounded to nearest even, has at most m bits.
    const u = @max(e - (m - 1), quantum);
    var den = try q.clone();
    defer den.deinit();
    if (u >= 0) try den.shiftLeft(&den, @intCast(u)) else try p.shiftLeft(&p, @intCast(-u));
    var n = try BigInt.init(gpa);
    defer n.deinit();
    var rem = try BigInt.init(gpa);
    defer rem.deinit();
    try n.divTrunc(&rem, &p, &den);
    try rem.shiftLeft(&rem, 1);
    switch (rem.order(den)) {
        .gt => try n.addScalar(&n, 1),
        .eq => if (n.isOdd()) try n.addScalar(&n, 1),
        .lt => {},
    }
    const v = std.math.ldexp(@as(F, @floatFromInt(n.toInt(u64) catch unreachable)), @intCast(u));
    if (std.math.isInf(v)) return null;
    return sign * v;
}

// Tests.

const testing = std.testing;
const Interner = @import("../base/Interner.zig");

const Fixture = struct {
    strings: Interner,
    types: Types,

    fn init(f: *Fixture) !void {
        f.strings = .init(testing.allocator, testing.io);
        f.types = try .init(testing.allocator, testing.io, &f.strings);
    }

    fn deinit(f: *Fixture) void {
        f.types.deinit();
        f.strings.deinit();
    }

    fn convert(f: *Fixture, c: Const, to: TypeId) !ConstResult {
        return convertConst(testing.allocator, &f.types, 64, c, to);
    }

    fn castC(f: *Fixture, c: Const, to: TypeId) !ConstResult {
        return castConst(testing.allocator, &f.types, 64, c, to);
    }
};

const u8_ = TypeId.int(.unsigned, 8);
const i8_ = TypeId.int(.signed, 8);
const i16_ = TypeId.int(.signed, 16);
const i32_ = TypeId.int(.signed, 32);
const u32_ = TypeId.int(.unsigned, 32);

fn floatConst(text: []const u8) !Const {
    return parseFloat(testing.allocator, text);
}

fn intConst(v: anytype) !Const {
    return fromInt(testing.allocator, v);
}

fn expectErr(code: DiagCode, r: ConstResult) !void {
    try testing.expectEqual(code, r.err);
}

fn expectBits(bits: u64, r: ConstResult) !void {
    try testing.expectEqual(bits, r.ok.bits);
}

test "300 as u8 on a constant is E0306; 255 fits" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var c300 = try intConst(300);
    defer c300.deinit();
    try expectErr(.E0306, try f.castC(c300, u8_));
    try expectErr(.E0306, try f.convert(c300, u8_));
    var c255 = try intConst(255);
    defer c255.deinit();
    try expectBits(255, try f.convert(c255, u8_));
    var neg = try intConst(-1);
    defer neg.deinit();
    try expectErr(.E0306, try f.convert(neg, u32_));
    try expectBits(@bitCast(@as(i64, -1)), try f.convert(neg, i8_));
    var m128 = try intConst(-128);
    defer m128.deinit();
    try expectBits(@bitCast(@as(i64, -128)), try f.convert(m128, i8_));
    var m129 = try intConst(-129);
    defer m129.deinit();
    try expectErr(.E0306, try f.convert(m129, i8_));
    // usize follows the target pointer width.
    var big = try intConst(1 << 40);
    defer big.deinit();
    try expectBits(1 << 40, try f.convert(big, .usize));
    try expectErr(.E0306, try convertConst(testing.allocator, &f.types, 32, big, .usize));
}

test "1.5 -> i32 is E0306; as truncates toward zero" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var c = try floatConst("1.5");
    defer c.deinit();
    try expectErr(.E0306, try f.convert(c, i32_));
    try expectBits(1, try f.castC(c, i32_));
    var n = try floatConst("-2.75");
    defer n.deinit();
    try expectBits(@bitCast(@as(i64, -2)), try f.castC(n, i32_));
    var big = try floatConst("1e3");
    defer big.deinit();
    try expectErr(.E0306, try f.castC(big, u8_));
}

test "untyped constants: bool targets, distinct types, defaults" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var one = try intConst(1);
    defer one.deinit();
    try expectErr(.E0310, try f.convert(one, .bool));
    try expectErr(.E0307, try f.castC(one, .bool));
    try expectErr(.E0310, try f.convert(one, .str));

    const meters = try f.types.intern(.{ .nominal = .{
        .decl = .{ .package = .{ .name = try f.strings.intern("app"), .line = .{ .major = 1 } }, .index = 0 },
        .kind = .distinct,
        .name = try f.strings.intern("Meters"),
        .underlying = .f32,
    } });
    var hundred = try floatConst("100.0");
    defer hundred.deinit();
    const r = try f.convert(hundred, meters);
    try testing.expectEqual(meters, r.ok.type);
    try testing.expectEqual(@as(u32, @bitCast(@as(f32, 100))), r.ok.bits);
    try expectBits(@as(u32, @bitCast(@as(f32, 1))), try f.convert(one, meters));

    try testing.expectEqual(TypeId.int(.signed, 64), defaultType(.untyped_int));
    try testing.expectEqual(TypeId.f64, defaultType(.untyped_float));
    try testing.expectEqual(u8_, defaultType(u8_));
}

test "round to nearest even into f32" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const cases = [_]struct { []const u8, f32 }{
        .{ "0.1", 0.1 },
        .{ "16777217.0", 16777216.0 }, // 2^24 + 1: tie, to even (down)
        .{ "16777219.0", 16777220.0 }, // 2^24 + 3: tie, to even (up)
        .{ "16777217.000001", 16777218.0 }, // above the tie
        .{ "3.4028235e38", std.math.floatMax(f32) },
        .{ "1.401298464324817e-45", std.math.floatTrueMin(f32) },
        .{ "7.006492321624085e-46", 0.0 }, // exactly half the smallest subnormal: tie to 0
        .{ "1e-50", 0.0 },
        .{ "3.14159265358979", 3.14159265358979 },
    };
    for (cases) |c| {
        var k = try floatConst(c[0]);
        defer k.deinit();
        try expectBits(@as(u32, @bitCast(c[1])), try f.convert(k, .f32));
    }
    var huge = try floatConst("3.5e38");
    defer huge.deinit();
    try expectErr(.E0306, try f.convert(huge, .f32));
    var d = try floatConst("0.1");
    defer d.deinit();
    try expectBits(@bitCast(@as(f64, 0.1)), try f.convert(d, .f64));
    var neg = try floatConst("-2.5e-3");
    defer neg.deinit();
    try expectBits(@bitCast(@as(f64, -2.5e-3)), try f.convert(neg, .f64));
    var big = try intConst(std.math.maxInt(u64));
    defer big.deinit();
    try expectBits(@bitCast(@as(f64, 18446744073709551615.0)), try f.convert(big, .f64));
}

test "fold: arbitrary precision, truncating division, rationals" {
    const gpa = testing.allocator;
    var one = try intConst(1);
    defer one.deinit();
    var hundred = try intConst(100);
    defer hundred.deinit();
    var huge = try binary(gpa, .shl, one, hundred); // 1 << 100
    defer huge.deinit();
    var n95 = try intConst(95);
    defer n95.deinit();
    var back = try binary(gpa, .shr, huge, n95);
    defer back.deinit();
    try testing.expectEqual(32, try back.int.toInt(u8));

    var m7 = try intConst(-7);
    defer m7.deinit();
    var two = try intConst(2);
    defer two.deinit();
    var q = try binary(gpa, .div, m7, two);
    defer q.deinit();
    try testing.expectEqual(-3, try q.int.toInt(i8));
    var r = try binary(gpa, .rem, m7, two);
    defer r.deinit();
    try testing.expectEqual(-1, try r.int.toInt(i8));
    var shr = try binary(gpa, .shr, m7, one);
    defer shr.deinit();
    try testing.expectEqual(-4, try shr.int.toInt(i8));
    var not = try bitNot(gpa, m7);
    defer not.deinit();
    try testing.expectEqual(6, try not.int.toInt(i8));

    var zero = try intConst(0);
    defer zero.deinit();
    try testing.expectError(error.DivisionByZero, binary(gpa, .div, one, zero));
    var tenth = try floatConst("0.1");
    defer tenth.deinit();
    try testing.expectError(error.InvalidOperand, binary(gpa, .bit_and, tenth, one));
    var m1 = try intConst(-1);
    defer m1.deinit();
    try testing.expectError(error.InvalidOperand, binary(gpa, .shl, one, m1));

    // 0.1 + 0.2 == 0.3 exactly, unlike in f64.
    var fifth = try floatConst("0.2");
    defer fifth.deinit();
    var sum = try binary(gpa, .add, tenth, fifth);
    defer sum.deinit();
    var three = try floatConst("3e-1");
    defer three.deinit();
    try testing.expectEqual(.eq, try order(gpa, sum, three));
    // 1 / 3 * 3 == 1, and int mixed with float is float.
    var three_f = try floatConst("3.0");
    defer three_f.deinit();
    var third = try binary(gpa, .div, one, three_f);
    defer third.deinit();
    try testing.expectEqual(TypeId.untyped_float, third.typeOf());
    try testing.expectEqual(.lt, try order(gpa, third, one));
    // 5.5 % 2 == 1.5, -5.5 % 2 == -1.5
    var a = try floatConst("5.5");
    defer a.deinit();
    var rm = try binary(gpa, .rem, a, two);
    defer rm.deinit();
    var na = try negate(a);
    defer na.deinit();
    var nrm = try binary(gpa, .rem, na, two);
    defer nrm.deinit();
    var expect = try floatConst("1.5");
    defer expect.deinit();
    try testing.expectEqual(.eq, try order(gpa, rm, expect));
    var nexpect = try negate(expect);
    defer nexpect.deinit();
    try testing.expectEqual(.eq, try order(gpa, nrm, nexpect));
    try testing.expectError(error.TooLarge, parseFloat(gpa, "1e999999"));
}

fn foldFloatsOom(gpa: Allocator) !void {
    var a = try parseFloat(gpa, "5.5");
    defer a.deinit();
    var b = try parseFloat(gpa, "2.25");
    defer b.deinit();
    for ([_]BinOp{ .add, .div, .rem }) |op| {
        var r = try binary(gpa, op, a, b);
        r.deinit();
    }
}

test "fold: no leak or double free on allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, foldFloatsOom, .{});
}

test "coerce: rules 1-9" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const t = &f.types;
    const u16_ = TypeId.int(.unsigned, 16);
    try testing.expectEqual(.float_widen, coerce(t, .f32, .f64, .{}));
    try testing.expectEqual(.none, coerce(t, .f64, .f32, .{}));
    try testing.expectEqual(.none, coerce(t, i32_, .f32, .{}));
    try testing.expectEqual(.int_widen, coerce(t, u8_, i16_, .{}));
    try testing.expectEqual(.int_widen, coerce(t, u8_, u16_, .{}));
    try testing.expectEqual(.none, coerce(t, u8_, i8_, .{}));
    try testing.expectEqual(.none, coerce(t, i8_, u16_, .{}));
    try testing.expectEqual(.none, coerce(t, u16_, u8_, .{}));
    try testing.expectEqual(.none, coerce(t, u8_, .usize, .{}));
    try testing.expectEqual(.none, coerce(t, u8_, .bool, .{}));
    try testing.expectEqual(.constant, coerce(t, .untyped_int, u8_, .{}));
    try testing.expectEqual(.never, coerce(t, .noreturn, u8_, .{}));
    try testing.expectEqual(.identity, coerce(t, .err, u8_, .{}));

    const arr = try t.intern(.{ .array = .{ .len = 4, .elem = u8_ } });
    const slice = try t.intern(.{ .slice = .{ .elem = u8_ } });
    try testing.expectEqual(.array_to_slice, coerce(t, arr, slice, .{ .place = true }));
    try testing.expectEqual(.none, coerce(t, arr, slice, .{}));
    try testing.expectEqual(.identity, coerce(t, slice, slice, .{}));
    const app: Types.Package = .{ .name = try f.strings.intern("app"), .line = .{ .major = 1 } };
    const particle = try t.intern(.{ .nominal = .{ .decl = .{ .package = app, .index = 0 }, .kind = .@"struct", .name = try f.strings.intern("P") } });
    const soa = try t.intern(.{ .soa_array = .{ .len = 8, .elem = particle } });
    const soa_slice = try t.intern(.{ .soa_slice = .{ .elem = particle } });
    try testing.expectEqual(.soa_array_to_soa_slice, coerce(t, soa, soa_slice, .{ .place = true }));

    const p = try t.intern(.{ .ptr = .{ .elem = u8_, .is_const = false } });
    const cp = try t.intern(.{ .ptr = .{ .elem = u8_, .is_const = true } });
    try testing.expectEqual(.ptr_to_const, coerce(t, p, cp, .{}));
    try testing.expectEqual(.none, coerce(t, cp, p, .{}));

    const fp = try t.intern(.{ .fn_ptr = .{ .params = &.{.{ .type = u8_ }}, .ret = .bool } });
    try testing.expectEqual(.lambda_to_fn_ptr, coerce(t, .void, fp, .{ .non_capturing_lambda = true }));
    try testing.expectEqual(.none, coerce(t, .void, u8_, .{ .non_capturing_lambda = true }));

    const opt = try t.intern(.{ .nominal = .{ .decl = .{ .package = app, .index = 1 }, .args = &.{.{ .type = u8_ }}, .kind = .@"enum", .name = try f.strings.intern("Option"), .lang = .option } });
    try testing.expectEqual(u8_, optionPayload(t, opt).?);
    try testing.expectEqual(.wrap_some, coerce(t, u8_, opt, .{}));
    try testing.expectEqual(.wrap_some, coerce(t, .untyped_int, opt, .{}));
    try testing.expectEqual(.none, coerce(t, i8_, opt, .{}));

    try testing.expectEqual(.fn_ref, coerce(t, fp, .fn_ref, .{ .non_generic_fn = true }));
    try testing.expectEqual(.none, coerce(t, fp, .fn_ref, .{}));
}

test "as table: legal casts and E0307" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const t = &f.types;
    try testing.expectEqual(null, cast(t, i32_, .bool, .none)); // int -> bool is E0307
    try testing.expectEqual(null, cast(t, .f32, .str, .none));
    try testing.expectEqual(.int_to_int, cast(t, i32_, u8_, .none));
    try testing.expectEqual(.int_to_int, cast(t, .usize, u8_, .none));
    try testing.expectEqual(.int_to_float, cast(t, i32_, .f32, .none));
    try testing.expectEqual(.float_to_int, cast(t, .f64, i32_, .none));
    try testing.expectEqual(.float_to_float, cast(t, .f64, .f32, .none));
    try testing.expectEqual(.bool_to_int, cast(t, .bool, u8_, .none));
    try testing.expectEqual(null, cast(t, .bool, .f32, .none));
    try testing.expectEqual(.identity, cast(t, u8_, u8_, .none));
    try testing.expectEqual(.constant, cast(t, .untyped_int, u8_, .none));

    const app: Types.Package = .{ .name = try f.strings.intern("app"), .line = .{ .major = 1 } };
    const op = try t.intern(.{ .nominal = .{ .decl = .{ .package = app, .index = 0 }, .kind = .@"enum", .name = try f.strings.intern("Op") } });
    try testing.expectEqual(.enum_to_int, cast(t, op, u8_, u8_));
    try testing.expectEqual(.enum_to_int, cast(t, op, u32_, u8_));
    try testing.expectEqual(null, cast(t, op, u8_, .int(.unsigned, 16))); // narrower than backing
    try testing.expectEqual(null, cast(t, op, u8_, .none)); // payload enum
    try testing.expectEqual(.enum_to_int, cast(t, op, .usize, u8_));
    try testing.expectEqual(.enum_to_int, cast(t, op, .usize, u32_));
    try testing.expectEqual(.enum_to_int, cast(t, op, .isize, u8_));
    try testing.expectEqual(null, cast(t, op, .isize, u32_)); // u32 may not fit a 32-bit isize
    try testing.expectEqual(.enum_to_int, cast(t, op, .isize, i32_));
    try testing.expectEqual(null, cast(t, op, .usize, i32_));
    try testing.expectEqual(null, cast(t, op, .usize, .int(.unsigned, 64)));

    const meters = try t.intern(.{ .nominal = .{ .decl = .{ .package = app, .index = 1 }, .kind = .distinct, .name = try f.strings.intern("Meters"), .underlying = .f32 } });
    try testing.expectEqual(.distinct, cast(t, meters, .f32, .none));
    try testing.expectEqual(.distinct, cast(t, .f32, meters, .none));
    try testing.expectEqual(null, cast(t, meters, .f64, .none));

    const vi = try t.intern(.{ .vec = .{ .len = 4, .elem = i32_ } });
    const vf = try t.intern(.{ .vec = .{ .len = 4, .elem = .f32 } });
    const vf3 = try t.intern(.{ .vec = .{ .len = 3, .elem = .f32 } });
    const vb = try t.intern(.{ .vec = .{ .len = 4, .elem = .bool } });
    try testing.expectEqual(.vec, cast(t, vi, vf, .none));
    try testing.expectEqual(null, cast(t, vi, vf3, .none));
    try testing.expectEqual(null, cast(t, vi, vb, .none));

    const p = try t.intern(.{ .ptr = .{ .elem = u8_, .is_const = false } });
    const cp = try t.intern(.{ .ptr = .{ .elem = i32_, .is_const = true } });
    try testing.expectEqual(.ptr_to_int, cast(t, p, .usize, .none));
    try testing.expectEqual(null, cast(t, p, .int(.unsigned, 64), .none));
    try testing.expectEqual(.ptr_to_ptr, cast(t, p, cp, .none));
    try testing.expectEqual(.int_to_ptr, cast(t, .usize, p, .none));
    try testing.expectEqual(null, cast(t, u32_, p, .none));
}
