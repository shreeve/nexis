//! bignum.zig — arbitrary-precision integer heap kind.
//!
//! Authoritative spec: `docs/BIGNUM.md`. Integer-tower semantics:
//! `docs/SEMANTICS.md` §2.2. Physical storage: `src/heap.zig`.
//!
//! The module owns the integer tower's arbitrary-precision half:
//! construction and canonical form, equality and hash, the arithmetic
//! (`add sub mul quot rem mod neg abs`), ordering, conversion to and
//! from f64 and i64, and decimal parsing and printing. The limb
//! arithmetic itself is `std.math.big.int`: a heap bignum's body is a
//! sign byte followed by little-endian `u64` limbs, which is exactly a
//! `big.int.Const`, so every operation reads the operands in place and
//! only the result is copied onto the heap.
//!
//! Every integer has one form (BIGNUM.md §1): every result goes
//! through `fromLimbs`, the canonicalizer (§3), so a magnitude that
//! fits i48 is always a fixnum.

const std = @import("std");
const value = @import("value.zig");
const heap_mod = @import("heap.zig");
const hash_mod = @import("hash.zig");

const Value = value.Value;
const Kind = value.Kind;
const Heap = heap_mod.Heap;
const HeapHeader = heap_mod.HeapHeader;

const testing = std.testing;

// =============================================================================
// Subkind + body layout
// =============================================================================

pub const subkind_limbs: u16 = 0;

/// The body's prefix: the sign, 1 negative and 0 not, and padding never
/// hashed or compared; the limbs, least significant first, follow
/// (BIGNUM.md §2).
const BignumBody = extern struct {
    negative: u8,
    _pad: [7]u8,

    comptime {
        std.debug.assert(@sizeOf(BignumBody) == 8);
        std.debug.assert(@offsetOf(BignumBody, "negative") == 0);
    }
};

const prefix_bytes: usize = @sizeOf(BignumBody);
const limb_bytes: usize = @sizeOf(u64);

// =============================================================================
// Public API — construction
// =============================================================================

/// The canonical integer `n`; `i64.min`'s magnitude, 2^63, comes from
/// negating in `u64` (BIGNUM.md §7).
pub fn fromI64(heap: *Heap, n: i64) !Value {
    if (value.fromFixnum(n)) |v| return v;
    return fromLimbs(heap, n < 0, &.{@abs(n)});
}

// =============================================================================
// Public API — accessors (bignum only)
// =============================================================================

pub fn isNegative(v: Value) bool {
    std.debug.assert(v.kind() == .bignum);
    return headerNegative(Heap.asHeapHeader(v));
}

/// Immutable slice of the u64 limbs (LSW first). Lifetime is tied to
/// the heap allocation backing `v`.
pub fn limbs(v: Value) []const u64 {
    std.debug.assert(v.kind() == .bignum);
    const h = Heap.asHeapHeader(v);
    return headerLimbs(h);
}

pub fn limbCount(v: Value) usize {
    return limbs(v).len;
}

// =============================================================================
// Per-kind hash / equality — called by dispatch
// =============================================================================

/// The sign and xxHash3 of the limb bytes, ordered-combined and cached
/// (BIGNUM.md §5); the padding is never hashed.
pub fn hashHeader(h: *HeapHeader) u32 {
    std.debug.assert(h.kind == @backingInt(Kind.bignum));
    if (h.cachedHash()) |cached| return cached;
    const limb_hash = hash_mod.hashBytes(std.mem.sliceAsBytes(headerLimbs(h)));
    return h.cacheHash(hash_mod.combineOrdered(@intFromBool(headerNegative(h)), limb_hash));
}

/// The same sign and limbs: in canonical form, the same integer
/// (BIGNUM.md §6).
pub fn limbsEqual(a: *HeapHeader, b: *HeapHeader) bool {
    std.debug.assert(a.kind == @backingInt(Kind.bignum) and b.kind == @backingInt(Kind.bignum));
    return a == b or (headerNegative(a) == headerNegative(b) and std.mem.eql(u64, headerLimbs(a), headerLimbs(b)));
}

// =============================================================================
// Arithmetic, ordering and conversion (BIGNUM.md §8)
//
// Every function accepts any member of the integer tower (fixnum or
// bignum) for each integer operand and returns a canonical Value:
// a fixnum when the result fits, a heap bignum otherwise. Operands
// are viewed as `std.math.big.int.Const` in place; result limbs are
// computed in a scratch buffer (on the stack for anything up to
// `scratch_limbs`, from the heap's backing allocator beyond) and
// copied onto the heap once, through the canonicalization funnel.
// =============================================================================

const bigint = std.math.big.int;
pub const Limb = std.math.big.Limb;

comptime {
    // A body's `u64` limbs are read directly as `big.int` limbs.
    std.debug.assert(@sizeOf(Limb) == limb_bytes);
}

/// Limbs of stack scratch before an operation borrows from the
/// heap's backing allocator: the sums, products and quotients of
/// everyday bignums never allocate.
const scratch_limbs = 64;
const scratch_bytes = scratch_limbs * limb_bytes;

/// Any integer-tower member viewed in place as a `big.int.Const`.
/// `scratch` backs the single limb of a fixnum; a bignum's limbs
/// are its heap body, so the view lives as long as the value.
pub fn view(v: Value, scratch: *[1]Limb) bigint.Const {
    switch (v.kind()) {
        .fixnum => {
            const n = v.asFixnum();
            scratch[0] = @abs(n);
            return .{ .limbs = scratch[0..], .positive = n >= 0 };
        },
        .bignum => {
            const h = Heap.asHeapHeader(v);
            return .{ .limbs = @ptrCast(headerLimbs(h)), .positive = !headerNegative(h) };
        },
        else => unreachable,
    }
}

/// Any member of the integer tower.
pub fn isInteger(v: Value) bool {
    return v.isFixnum() or v.kind() == .bignum;
}

/// A finished `big.int.Mutable` onto the heap in canonical form.
fn fromMutable(heap: *Heap, m: bigint.Mutable) !Value {
    return fromLimbs(heap, !m.positive, @ptrCast(m.limbs[0..m.len]));
}

/// Scratch limbs on the stack, then from the heap's backing allocator.
const Scratch = struct {
    stack: [scratch_limbs]Limb,
    bfa: std.heap.BufferFirstAllocator,

    fn allocator(s: *Scratch, heap: *Heap) std.mem.Allocator {
        s.bfa = .init(@ptrCast(&s.stack), heap.backing);
        return s.bfa.allocator();
    }
};

fn mutable(buf: []Limb) bigint.Mutable {
    return .{ .limbs = buf, .len = 1, .positive = true };
}

/// Construct from an `i128`; the two-limb analogue of `fromI64`.
pub fn fromI128(heap: *Heap, n: i128) !Value {
    if (n >= std.math.minInt(i64) and n <= std.math.maxInt(i64)) return fromI64(heap, @intCast(n));
    const mag: u128 = @abs(n);
    return fromLimbs(heap, n < 0, &.{ @truncate(mag), @truncate(mag >> 64) });
}

pub fn add(heap: *Heap, a: Value, b: Value) !Value {
    return binary(heap, a, b, .add);
}

pub fn sub(heap: *Heap, a: Value, b: Value) !Value {
    return binary(heap, a, b, .sub);
}

pub fn mul(heap: *Heap, a: Value, b: Value) !Value {
    return binary(heap, a, b, .mul);
}

fn binary(heap: *Heap, a: Value, b: Value, comptime op: enum { add, sub, mul }) !Value {
    var sa: [1]Limb = undefined;
    var sb: [1]Limb = undefined;
    const x = view(a, &sa);
    const y = view(b, &sb);
    var scratch: Scratch = undefined;
    const alloc = scratch.allocator(heap);
    const buf = try alloc.alloc(Limb, if (op == .mul) x.limbs.len + y.limbs.len else @max(x.limbs.len, y.limbs.len) + 1);
    defer alloc.free(buf);
    var r = mutable(buf);
    switch (op) {
        .add => r.add(x, y),
        .sub => r.sub(x, y),
        .mul => r.mulNoAlias(x, y, alloc),
    }
    return fromMutable(heap, r);
}

/// `first` times every integer of `rest`, the running product kept in
/// two scratch buffers that take turns: only the result reaches the
/// heap. A fold through `mul` would leave every partial product there,
/// and a native's garbage is not collected before it returns (VM.md
/// §9).
pub fn product(heap: *Heap, first: Value, rest: []const Value) !Value {
    const alloc = heap.backing;
    var sa: [1]Limb = undefined;
    const a = view(first, &sa);
    var cur = try alloc.dupe(Limb, a.limbs);
    defer alloc.free(cur);
    var spare: []Limb = &.{};
    defer alloc.free(spare);
    var acc: bigint.Mutable = .{ .limbs = cur, .len = a.limbs.len, .positive = a.positive };
    for (rest) |x| {
        var sx: [1]Limb = undefined;
        const y = view(x, &sx);
        const need = acc.len + y.limbs.len;
        if (spare.len < need) {
            alloc.free(spare);
            spare = &.{};
            spare = try alloc.alloc(Limb, need + need / 2);
        }
        var r = mutable(spare);
        r.mulNoAlias(acc.toConst(), y, alloc);
        spare = cur;
        cur = r.limbs;
        acc = r;
    }
    return fromMutable(heap, acc);
}

const DivPart = enum { quotient, remainder, exact_quotient };
const Rounding = enum { truncated, floored };

/// The division family over a non-zero divisor (the caller raises
/// on zero): truncated division gives `quot` and `rem` (remainder
/// with the dividend's sign), floored division gives `mod`
/// (remainder with the divisor's sign). `exact_quotient` is the
/// quotient when the remainder is zero and `null` otherwise.
fn divide(heap: *Heap, a: Value, b: Value, rounding: Rounding, part: DivPart) !?Value {
    var sa: [1]Limb = undefined;
    var sb: [1]Limb = undefined;
    const x = view(a, &sa);
    const y = view(b, &sb);
    std.debug.assert(!y.eqlZero());
    var scratch: Scratch = undefined;
    const alloc = scratch.allocator(heap);
    const qbuf = try alloc.alloc(Limb, x.limbs.len + 1);
    defer alloc.free(qbuf);
    const rbuf = try alloc.alloc(Limb, y.limbs.len + 1);
    defer alloc.free(rbuf);
    const tmp = try alloc.alloc(Limb, bigint.calcDivLimbsBufferLen(x.limbs.len, y.limbs.len));
    defer alloc.free(tmp);
    var q = mutable(qbuf);
    var r = mutable(rbuf);
    switch (rounding) {
        .truncated => q.divTrunc(&r, x, y, tmp),
        .floored => q.divFloor(&r, x, y, tmp),
    }
    return switch (part) {
        .quotient => try fromMutable(heap, q),
        .remainder => try fromMutable(heap, r),
        .exact_quotient => if (r.toConst().eqlZero()) try fromMutable(heap, q) else null,
    };
}

/// Truncated quotient.
pub fn quot(heap: *Heap, a: Value, b: Value) !Value {
    return (try divide(heap, a, b, .truncated, .quotient)).?;
}

/// The quotient when `b` divides `a` exactly, `null` otherwise.
pub fn quotExact(heap: *Heap, a: Value, b: Value) !?Value {
    return divide(heap, a, b, .truncated, .exact_quotient);
}

/// Remainder of truncated division: the dividend's sign.
pub fn rem(heap: *Heap, a: Value, b: Value) !Value {
    return (try divide(heap, a, b, .truncated, .remainder)).?;
}

/// Remainder of floored division: the divisor's sign.
pub fn mod(heap: *Heap, a: Value, b: Value) !Value {
    return (try divide(heap, a, b, .floored, .remainder)).?;
}

pub fn neg(heap: *Heap, a: Value) !Value {
    var sa: [1]Limb = undefined;
    const x = view(a, &sa);
    return fromLimbs(heap, x.positive, @ptrCast(x.limbs));
}

pub fn abs(heap: *Heap, a: Value) !Value {
    var sa: [1]Limb = undefined;
    const x = view(a, &sa);
    return fromLimbs(heap, false, @ptrCast(x.limbs));
}

/// Exact ordering of two integers of any size.
pub fn compare(a: Value, b: Value) std.math.Order {
    var sa: [1]Limb = undefined;
    var sb: [1]Limb = undefined;
    return view(a, &sa).order(view(b, &sb));
}

pub fn isEven(v: Value) bool {
    var s: [1]Limb = undefined;
    return view(v, &s).isEven();
}

/// The nearest f64 (ties to even); an infinity beyond f64's range.
pub fn toF64(v: Value) f64 {
    var s: [1]Limb = undefined;
    return view(v, &s).toFloat(f64, .nearest_even)[0];
}

/// `a / b` for integers of any size, `b` non-zero, as the nearest
/// f64 (ties to even). The quotient is taken to 55 or 56 bits with a
/// sticky bit for the remainder and rounded once, at 53 bits or at the
/// subnormal grid, so operands beyond f64's range still give the
/// finite quotient and none is rounded before the division.
pub fn quotientF64(heap: *Heap, a: Value, b: Value) !f64 {
    var sa: [1]Limb = undefined;
    var sb: [1]Limb = undefined;
    const x = view(a, &sa);
    const y = view(b, &sb);
    std.debug.assert(!y.eqlZero());
    if (x.eqlZero()) return 0.0;
    // A·2^k / B lies in [2^54, 2^56).
    const k: isize = 55 + @as(isize, @intCast(y.bitCountAbs())) - @as(isize, @intCast(x.bitCountAbs()));
    const sign: f64 = if (x.positive == y.positive) 1.0 else -1.0;
    if (k < -1100) return sign * std.math.inf(f64);
    if (k > 1134) return sign * 0.0;
    const up: usize = @intCast(@max(k, 0));
    const down: usize = @intCast(@max(-k, 0));
    var scratch: Scratch = undefined;
    const alloc = scratch.allocator(heap);
    const xs_buf = try alloc.alloc(Limb, x.limbs.len + up / @bitSizeOf(Limb) + 1);
    defer alloc.free(xs_buf);
    const ys_buf = try alloc.alloc(Limb, y.limbs.len + down / @bitSizeOf(Limb) + 1);
    defer alloc.free(ys_buf);
    var xs = mutable(xs_buf);
    var ys = mutable(ys_buf);
    xs.shiftLeft(x.abs(), up);
    ys.shiftLeft(y.abs(), down);
    const qbuf = try alloc.alloc(Limb, xs.len + 1);
    defer alloc.free(qbuf);
    const rbuf = try alloc.alloc(Limb, ys.len + 1);
    defer alloc.free(rbuf);
    const tmp = try alloc.alloc(Limb, bigint.calcDivLimbsBufferLen(xs.len, ys.len));
    defer alloc.free(tmp);
    var q = mutable(qbuf);
    var r = mutable(rbuf);
    q.divTrunc(&r, xs.toConst(), ys.toConst(), tmp);
    const quotient = q.toConst().toInt(u64) catch unreachable;
    const n: isize = 64 - @as(isize, @clz(quotient));
    // Drop the bits below the 53rd, or below 2^-1074 for a subnormal.
    const s: isize = @max(n - 53, k - 1074);
    if (s > n) return sign * 0.0;
    const shift: u6 = @intCast(s);
    var m = quotient >> shift;
    const rest = quotient & ((@as(u64, 1) << shift) - 1);
    const half = @as(u64, 1) << (shift - 1);
    if (rest > half or (rest == half and (!r.toConst().eqlZero() or m & 1 == 1))) m += 1;
    return sign * std.math.ldexp(@as(f64, @floatFromInt(m)), @intCast(s - k));
}

/// The integer part of a finite f64 (rounding toward zero), in
/// canonical form; `null` for NaN and the infinities, which have no
/// integer value.
pub fn fromF64(heap: *Heap, f: f64) !?Value {
    if (!std.math.isFinite(f)) return null;
    const t = @trunc(f);
    if (@abs(t) < @as(f64, @floatFromInt(@as(u64, 1) << 47))) return value.fromFixnum(@trunc(t)).?;
    var scratch: Scratch = undefined;
    const alloc = scratch.allocator(heap);
    const buf = try alloc.alloc(Limb, bigint.calcLimbLen(t) + 1);
    defer alloc.free(buf);
    var m = mutable(buf);
    _ = m.setFloat(t, .trunc);
    return try fromMutable(heap, m);
}

/// The value as an `i64` when it fits, `null` otherwise.
pub fn toI64(v: Value) ?i64 {
    if (v.isFixnum()) return v.asFixnum();
    var s: [1]Limb = undefined;
    return view(v, &s).toInt(i64) catch null;
}

/// Decimal text, a leading `-` for a negative value, no suffix.
pub fn formatDecimal(v: Value, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (v.isFixnum()) return writer.print("{d}", .{v.asFixnum()});
    var s: [1]Limb = undefined;
    const x = view(v, &s);
    if (!x.positive) try writer.writeByte('-');
    const magnitude: bigint.Const = .{ .limbs = x.limbs, .positive = true };
    if (x.limbs.len <= split_limbs) return writeSmallDecimal(magnitude, 0, writer);
    // The quotients, remainders and powers of ten of the split all
    // live until the digits are written; they total O(n log n) limbs.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    writeSplitDecimal(arena.allocator(), magnitude, writer) catch |err| switch (err) {
        error.OutOfMemory => return error.WriteFailed,
        error.WriteFailed => return error.WriteFailed,
    };
}

/// At or under this many limbs, `std`'s conversion (one division by
/// 10^9 per nine digits, each a pass over the whole number) is the
/// faster one.
const split_limbs = 32;

/// Divide and conquer (BIGNUM.md §8): split `x` at a power of ten
/// 10^(9·2^i) into a high and a low half and write each, the low half
/// zero-padded to its full width. Each level's divisions cost about
/// half the level above's, so the whole conversion costs about one
/// Knuth division of `x` by its square root, where `std`'s costs a
/// pass over `x` per nine digits: a 130 000-digit value converts in a
/// fraction of the time, and a million-digit one in seconds instead of
/// a minute.
fn writeSplitDecimal(arena: std.mem.Allocator, x: bigint.Const, writer: *std.Io.Writer) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
    // powers[i] = 10^(9·2^i), up to the first whose square exceeds x.
    var powers: std.ArrayList(bigint.Const) = .empty;
    var p: bigint.Const = .{ .limbs = try arena.dupe(Limb, &.{1_000_000_000}), .positive = true };
    while (true) {
        try powers.append(arena, p);
        if (p.limbs.len * 2 > x.limbs.len + 1) break;
        var sq: bigint.Mutable = .{ .limbs = try arena.alloc(Limb, 2 * p.limbs.len + 1), .len = 1, .positive = true };
        sq.sqrNoAlias(p, null);
        p = sq.toConst();
    }
    try writePart(arena, x, powers.items, powers.items.len, 0, writer);
}

/// `x`, which is below `powers[level - 1]` squared, written with at
/// least `width` digits.
fn writePart(
    arena: std.mem.Allocator,
    x: bigint.Const,
    powers: []const bigint.Const,
    level: usize,
    width: usize,
    writer: *std.Io.Writer,
) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
    if (level == 0 or x.limbs.len <= split_limbs) return writeSmallDecimal(x, width, writer);
    const pow = powers[level - 1];
    if (x.order(pow) == .lt) return writePart(arena, x, powers, level - 1, width, writer);
    const half = @as(usize, 9) << @intCast(level - 1);
    var q: bigint.Mutable = .{ .limbs = try arena.alloc(Limb, x.limbs.len + 1), .len = 1, .positive = true };
    var r: bigint.Mutable = .{ .limbs = try arena.alloc(Limb, pow.limbs.len + 1), .len = 1, .positive = true };
    q.divTrunc(&r, x, pow, try arena.alloc(Limb, bigint.calcDivLimbsBufferLen(x.limbs.len, pow.limbs.len)));
    try writePart(arena, q.toConst(), powers, level - 1, width -| half, writer);
    try writePart(arena, r.toConst(), powers, level - 1, half, writer);
}

/// `x` through `std`'s conversion, left-padded with zeros to `width`.
fn writeSmallDecimal(x: bigint.Const, width: usize, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    var stack: [scratch_limbs * 8]Limb = undefined;
    var bfa: std.heap.BufferFirstAllocator = .init(@ptrCast(&stack), std.heap.page_allocator);
    const alloc = bfa.allocator();
    const digits = alloc.alloc(u8, @max(1, x.sizeInBaseUpperBound(10))) catch return error.WriteFailed;
    defer alloc.free(digits);
    const tmp = alloc.alloc(Limb, bigint.calcToStringLimbsBufferLen(@max(1, x.limbs.len), 10)) catch return error.WriteFailed;
    defer alloc.free(tmp);
    const n = x.toString(digits, 10, .lower, tmp);
    if (n < width) try writer.splatByteAll('0', width - n);
    try writer.writeAll(digits[0..n]);
}

/// Parse `-?[0-9]+` into canonical form; `null` when `text` is not
/// that shape.
pub fn parseDecimal(heap: *Heap, text: []const u8) !?Value {
    const negative = text.len > 0 and text[0] == '-';
    const digits = text[@intFromBool(negative)..];
    if (digits.len == 0) return null;
    for (digits) |c| if (c < '0' or c > '9') return null;
    if (digits.len <= 18) return try fromI64(heap, std.fmt.parseInt(i64, text, 10) catch unreachable);
    if (digits.len <= split_digits) {
        var scratch: Scratch = undefined;
        const alloc = scratch.allocator(heap);
        const buf = try alloc.alloc(Limb, bigint.calcSetStringLimbCount(10, digits.len));
        defer alloc.free(buf);
        var m = mutable(buf);
        m.setString(10, text) catch unreachable;
        return try fromMutable(heap, m);
    }
    // The halves, products and powers of ten of the split all live
    // until the sum is built; they total O(n log n) limbs.
    var arena = std.heap.ArenaAllocator.init(heap.backing);
    defer arena.deinit();
    var split: DecimalSplit = .{ .arena = arena.allocator() };
    const magnitude = try split.read(digits);
    return try fromLimbs(heap, negative, @ptrCast(magnitude.limbs));
}

/// At or under this many digits, `std`'s conversion (one multiply-add
/// over the whole number per 19 digits) is the faster one.
const split_digits = 4000;

/// Divide and conquer (BIGNUM.md §8): `digits` as `hi · 10^k + lo`,
/// `lo` the last `k`, half the digits, each half read the same way and
/// the product of two halves of one size taken by `std`'s Karatsuba
/// multiply. Where `std`'s conversion is quadratic in the digits, this
/// costs a few multiplies of the number's halves: a million digits
/// read in about a second.
const DecimalSplit = struct {
    arena: std.mem.Allocator,
    /// 10^k for each `k` a split has needed; a level needs at most two.
    powers: std.ArrayList(struct { k: usize, p: bigint.Const }) = .empty,

    fn read(d: *DecimalSplit, digits: []const u8) std.mem.Allocator.Error!bigint.Const {
        if (digits.len <= split_digits) {
            var m = mutable(try d.arena.alloc(Limb, bigint.calcSetStringLimbCount(10, digits.len)));
            m.setString(10, digits) catch unreachable;
            return m.toConst();
        }
        const k = digits.len / 2;
        const hi = try d.read(digits[0 .. digits.len - k]);
        const lo = try d.read(digits[digits.len - k ..]);
        var r = try d.product(hi, try d.power(k));
        r.add(r.toConst(), lo);
        return r.toConst();
    }

    /// 10^k, as the product of its halves.
    fn power(d: *DecimalSplit, k: usize) std.mem.Allocator.Error!bigint.Const {
        for (d.powers.items) |e| if (e.k == k) return e.p;
        const p = if (k <= 19) bigint.Const{ .limbs = try d.arena.dupe(Limb, &.{std.math.pow(Limb, 10, k)}), .positive = true } else (try d.product(try d.power(k / 2), try d.power(k - k / 2))).toConst();
        try d.powers.append(d.arena, .{ .k = k, .p = p });
        return p;
    }

    /// `a · b`, with a limb to spare for the sum `read` adds to it.
    fn product(d: *DecimalSplit, a: bigint.Const, b: bigint.Const) std.mem.Allocator.Error!bigint.Mutable {
        var r = mutable(try d.arena.alloc(Limb, a.limbs.len + b.limbs.len + 1));
        r.mulNoAlias(a, b, d.arena);
        return r;
    }
};

// =============================================================================
// Private helpers
// =============================================================================

/// The canonical integer of a sign and a little-endian magnitude, which
/// may be empty or carry trailing zero limbs (BIGNUM.md §3): zero is
/// `fixnum(0)` whatever the sign, a magnitude in i48 a fixnum, anything
/// else a bignum of the trimmed limbs. Every result passes through here.
pub fn fromLimbs(heap: *Heap, negative: bool, input_limbs: []const u64) !Value {
    var n: usize = input_limbs.len;
    while (n > 0 and input_limbs[n - 1] == 0) n -= 1;
    const trimmed = input_limbs[0..n];
    if (n == 0) return value.fromFixnum(0).?;
    if (n == 1 and trimmed[0] <= 1 << 47) {
        const m: i64 = @intCast(trimmed[0]);
        if (value.fromFixnum(if (negative) -m else m)) |v| return v;
    }
    const h = try heap.alloc(.bignum, prefix_bytes + n * limb_bytes);
    const body = Heap.bodyBytes(h);
    @as(*BignumBody, @ptrCast(@alignCast(body.ptr))).negative = @intFromBool(negative);
    @memcpy(@as([*]u64, @ptrCast(@alignCast(body.ptr + prefix_bytes)))[0..n], trimmed);
    return .{ .tag = @as(u64, @backingInt(Kind.bignum)) | (@as(u64, subkind_limbs) << 16), .payload = @intFromPtr(h) };
}

fn headerNegative(h: *HeapHeader) bool {
    const prefix: *const BignumBody = @ptrCast(@alignCast(Heap.bodyBytes(h).ptr));
    std.debug.assert(prefix.negative <= 1);
    return prefix.negative == 1;
}

/// The limbs, asserted canonical: at least one, the top one nonzero.
fn headerLimbs(h: *HeapHeader) []const u64 {
    const body = Heap.bodyBytes(h);
    std.debug.assert(body.len > prefix_bytes and (body.len - prefix_bytes) % limb_bytes == 0);
    const ptr: [*]const u64 = @ptrCast(@alignCast(body.ptr + prefix_bytes));
    const slice = ptr[0 .. (body.len - prefix_bytes) / limb_bytes];
    std.debug.assert(slice[slice.len - 1] != 0);
    return slice;
}

// =============================================================================
// Tests. The randomized laws are test/prop/bignum.zig's.
// =============================================================================

test "fromI64 and fromLimbs: one form per integer at the i48 and i64 edges" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const two47: u64 = 1 << 47;
    // Fixnums, never allocated: either edge of i48, zero of either
    // sign, trailing zero limbs.
    for ([_]Value{
        try fromI64(&heap, value.fixnum_min),
        try fromI64(&heap, value.fixnum_max),
        try fromLimbs(&heap, true, &.{two47}),
        try fromLimbs(&heap, true, &.{}),
        try fromLimbs(&heap, true, &.{ 0, 0, 0 }),
        try fromLimbs(&heap, false, &.{ 42, 0, 0 }),
    }, [_]i64{ value.fixnum_min, value.fixnum_max, value.fixnum_min, 0, 0, 42 }) |v, n| {
        try testing.expect(v.kind() == .fixnum);
        try testing.expectEqual(n, v.asFixnum());
    }
    try testing.expectEqual(@as(usize, 0), heap.liveCount());
    // Bignums, trimmed: one past either edge, i64.min, and 2^47 with
    // trailing zeros.
    for ([_]Value{
        try fromI64(&heap, value.fixnum_max + 1),
        try fromI64(&heap, value.fixnum_min - 1),
        try fromI64(&heap, std.math.minInt(i64)),
        try fromLimbs(&heap, false, &.{ two47, 0 }),
    }, [_]bool{ false, true, true, false }, [_]u64{ two47, two47 + 1, 1 << 63, two47 }) |v, negative, magnitude| {
        try testing.expect(v.kind() == .bignum);
        try testing.expectEqual(negative, isNegative(v));
        try testing.expectEqualSlices(u64, &.{magnitude}, limbs(v));
        try testing.expectEqual(subkind_limbs, v.subkind());
    }
    const a = try fromI64(&heap, std.math.minInt(i64));
    const b = try fromLimbs(&heap, true, &.{1 << 63});
    try testing.expect(limbsEqual(Heap.asHeapHeader(a), Heap.asHeapHeader(b)));
    try testing.expectEqual(hashHeader(Heap.asHeapHeader(a)), hashHeader(Heap.asHeapHeader(b)));
}

fn fx(n: i64) Value {
    return value.fromFixnum(n).?;
}

fn expectDecimal(expected: []const u8, v: Value) !void {
    var w = std.Io.Writer.Allocating.init(testing.allocator);
    defer w.deinit();
    try formatDecimal(v, &w.writer);
    try testing.expectEqualStrings(expected, w.written());
}

test "add/sub: fixnum sums that leave i48 promote, and the reverse step demotes" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const over = try add(&heap, fx(value.fixnum_max), fx(1));
    try testing.expect(over.kind() == .bignum);
    try expectDecimal("140737488355328", over);
    const back = try sub(&heap, over, fx(1));
    try testing.expect(back.kind() == .fixnum);
    try testing.expectEqual(value.fixnum_max, back.asFixnum());
    const under = try sub(&heap, fx(value.fixnum_min), fx(1));
    try testing.expect(under.kind() == .bignum);
    try expectDecimal("-140737488355329", under);
    const back_up = try add(&heap, under, fx(1));
    try testing.expect(back_up.kind() == .fixnum);
    try testing.expectEqual(value.fixnum_min, back_up.asFixnum());
}

test "add: opposite signs cancel across limbs down to a fixnum" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const big_pos = try fromLimbs(&heap, false, &[_]u64{ 5, 1 });
    const big_neg = try fromLimbs(&heap, true, &[_]u64{ 0, 1 });
    const sum = try add(&heap, big_pos, big_neg);
    try testing.expect(sum.kind() == .fixnum);
    try testing.expectEqual(@as(i64, 5), sum.asFixnum());
}

test "mul: products against i128 and a 2^128 crossing" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const p = try mul(&heap, fx(100_000_000), fx(10_000_000_000));
    try expectDecimal("1000000000000000000", p);
    const p2 = try mul(&heap, p, p);
    try expectDecimal("1000000000000000000000000000000000000", p2);
    const p3 = try mul(&heap, p2, fx(-3));
    try expectDecimal("-3000000000000000000000000000000000000", p3);
    const zero = try mul(&heap, p3, fx(0));
    try testing.expect(zero.kind() == .fixnum and zero.asFixnum() == 0);
    const two63 = try fromI64(&heap, std.math.minInt(i64));
    const sq = try mul(&heap, two63, two63);
    try expectDecimal("85070591730234615865843651857942052864", sq);
}

test "quot/rem/mod: signs follow Zig's @divTrunc/@rem/@mod on every sign combination" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const big_a: i128 = 123_456_789_012_345_678_901_234_567_890;
    const small_b: i128 = 97;
    const signs = [_]i128{ 1, -1 };
    for (signs) |sa| for (signs) |sb| {
        const a = sa * big_a;
        const b = sb * small_b;
        const av = try fromI128(&heap, a);
        const bv = try fromI128(&heap, b);
        try testing.expect(compare(try quot(&heap, av, bv), try fromI128(&heap, @divTrunc(a, b))) == .eq);
        try testing.expect(compare(try rem(&heap, av, bv), try fromI128(&heap, @rem(a, b))) == .eq);
        try testing.expect(compare(try mod(&heap, av, bv), try fromI128(&heap, @mod(a, b))) == .eq);
    };
    // A remainder or modulus is always a fixnum here (|b| = 97).
    const r = try rem(&heap, try fromI128(&heap, -big_a), fx(97));
    try testing.expect(r.kind() == .fixnum);
    try testing.expectEqual(@rem(-big_a, 97), @as(i128, r.asFixnum()));
}

test "quotExact: the quotient only when the remainder is zero" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const a = (try parseDecimal(&heap, "1000000000000000000000000000000000000")).?;
    const b = (try parseDecimal(&heap, "1000000000000000000")).?;
    const q = (try quotExact(&heap, a, b)).?;
    try testing.expect(compare(q, b) == .eq);
    try testing.expect((try quotExact(&heap, a, fx(7))) == null);
    try testing.expect((try quotExact(&heap, fx(6), fx(3))).?.asFixnum() == 2);
    try testing.expect((try quotExact(&heap, fx(6), fx(4))) == null);
}

test "quotientF64: operands past f64's range, signs, and rounding at the subnormal grid" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var digits: [402]u8 = @splat('0');
    digits[0] = '1';
    const e400 = (try parseDecimal(&heap, digits[0..401])).?;
    const e399 = (try parseDecimal(&heap, digits[0..400])).?;
    const e100 = (try parseDecimal(&heap, digits[0..101])).?;
    digits[400] = '1';
    const e400_1 = (try parseDecimal(&heap, digits[0..401])).?;
    try testing.expectEqual(@as(f64, 10.0 / 3.0), try quotientF64(&heap, e400, try mul(&heap, fx(3), e399)));
    try testing.expectEqual(@as(f64, -10.0 / 3.0), try quotientF64(&heap, e400, try mul(&heap, fx(-3), e399)));
    try testing.expectEqual(@as(f64, 1e300), try quotientF64(&heap, e400_1, e100));
    try testing.expect(std.math.isPositiveInf(try quotientF64(&heap, e400_1, fx(3))));
    try testing.expect(std.math.isNegativeInf(try quotientF64(&heap, e400_1, fx(-3))));
    try testing.expectEqual(@as(f64, 0.0), try quotientF64(&heap, fx(1), e400));
    // Powers of two around 2^-1074, the least subnormal: ties go to even.
    var two_limbs: [17]u64 = @splat(0);
    two_limbs[16] = 1 << 50;
    const p1074 = try fromLimbs(&heap, false, &two_limbs);
    const tiny = std.math.floatTrueMin(f64);
    try testing.expectEqual(tiny, try quotientF64(&heap, fx(1), p1074));
    try testing.expectEqual(@as(f64, 0.0), try quotientF64(&heap, fx(1), try mul(&heap, fx(2), p1074)));
    try testing.expectEqual(tiny, try quotientF64(&heap, fx(3), try mul(&heap, fx(4), p1074)));
    try testing.expectEqual(2 * tiny, try quotientF64(&heap, fx(3), try mul(&heap, fx(2), p1074)));
    try testing.expectEqual(-2 * tiny, try quotientF64(&heap, fx(-3), try mul(&heap, fx(2), p1074)));
}

test "quot: fixnum_min / -1 is the one fixnum quotient that promotes" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const q = try quot(&heap, fx(value.fixnum_min), fx(-1));
    try testing.expect(q.kind() == .bignum);
    try expectDecimal("140737488355328", q);
}

test "neg/abs: canonical on both sides of the boundary" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const n = try neg(&heap, fx(value.fixnum_min));
    try testing.expect(n.kind() == .bignum);
    try expectDecimal("140737488355328", n);
    const back = try neg(&heap, n);
    try testing.expect(back.kind() == .fixnum and back.asFixnum() == value.fixnum_min);
    const a = try abs(&heap, fx(value.fixnum_min));
    try testing.expect(compare(a, n) == .eq);
    try testing.expect((try neg(&heap, fx(0))).asFixnum() == 0);
    try testing.expect((try abs(&heap, fx(-7))).asFixnum() == 7);
    const big_neg = try fromLimbs(&heap, true, &[_]u64{ 1, 1 });
    try testing.expect(!isNegative(try abs(&heap, big_neg)));
    try testing.expect(!isNegative(try neg(&heap, big_neg)));
}

test "compare: exact across fixnum and bignum, by sign and magnitude" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const big_pos = try fromLimbs(&heap, false, &[_]u64{ 0, 1 });
    const big_pos1 = try fromLimbs(&heap, false, &[_]u64{ 1, 1 });
    const big_neg = try fromLimbs(&heap, true, &[_]u64{ 0, 1 });
    try testing.expect(compare(fx(7), big_pos) == .lt);
    try testing.expect(compare(big_pos, fx(7)) == .gt);
    try testing.expect(compare(big_neg, fx(-7)) == .lt);
    try testing.expect(compare(big_pos, big_pos1) == .lt);
    try testing.expect(compare(big_pos, big_pos) == .eq);
    try testing.expect(compare(big_neg, big_pos) == .lt);
    try testing.expect(compare(fx(-1), fx(1)) == .lt);
    try testing.expect(compare(fx(0), fx(0)) == .eq);
}

test "isEven: reads the lowest limb of either kind" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    try testing.expect(isEven(fx(4)) and !isEven(fx(-3)));
    try testing.expect(isEven(try fromLimbs(&heap, true, &[_]u64{ 2, 9 })));
    try testing.expect(!isEven(try fromLimbs(&heap, false, &[_]u64{ 3, 9 })));
}

test "toF64/fromF64: 2^64 round-trips; the fraction truncates; NaN and infinity have no integer" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const two64 = try fromLimbs(&heap, false, &[_]u64{ 0, 1 });
    try testing.expectEqual(@as(f64, 18446744073709551616.0), toF64(two64));
    try testing.expectEqual(@as(f64, -3.0), toF64(fx(-3)));
    const back = (try fromF64(&heap, 18446744073709551616.0)).?;
    try testing.expect(compare(back, two64) == .eq);
    const neg_big = (try fromF64(&heap, -1.5e30)).?;
    try expectDecimal("-1499999999999999889089448902656", neg_big);
    const small = (try fromF64(&heap, -2.75)).?;
    try testing.expect(small.kind() == .fixnum and small.asFixnum() == -2);
    try testing.expect((try fromF64(&heap, 0.999)).?.asFixnum() == 0);
    try testing.expect((try fromF64(&heap, std.math.nan(f64))) == null);
    try testing.expect((try fromF64(&heap, std.math.inf(f64))) == null);
    // 2^200 rounds to the nearest double and back to the same integer.
    var two200_limbs: [4]u64 = @splat(0);
    two200_limbs[3] = @as(u64, 1) << 8;
    const two200 = try fromLimbs(&heap, false, &two200_limbs);
    try testing.expect(compare((try fromF64(&heap, toF64(two200))).?, two200) == .eq);
    try testing.expect(std.math.isInf(toF64(try fromLimbs(&heap, false, &@as([20]u64, @splat(1))))));
}

test "toI64: fixnums, bignums within i64, and one beyond" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    try testing.expectEqual(@as(?i64, 5), toI64(fx(5)));
    try testing.expectEqual(@as(?i64, std.math.minInt(i64)), toI64(try fromI64(&heap, std.math.minInt(i64))));
    try testing.expectEqual(@as(?i64, std.math.maxInt(i64)), toI64(try fromI64(&heap, std.math.maxInt(i64))));
    try testing.expectEqual(@as(?i64, null), toI64(try fromLimbs(&heap, false, &[_]u64{ 0, 1 })));
}

test "formatDecimal/parseDecimal: round trip at every size, canonical on the way in" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const texts = [_][]const u8{
        "0",
        "-1",
        "140737488355327",
        "140737488355328",
        "-140737488355328",
        "-140737488355329",
        "9223372036854775807",
        "-9223372036854775808",
        "18446744073709551616",
        "123456789012345678901234567890123456789012345678901234567890",
        "-99999999999999999999999999999999999999999999999999999999999999999999999999999999",
    };
    for (texts) |t| {
        const v = (try parseDecimal(&heap, t)).?;
        try expectDecimal(t, v);
    }
    try testing.expect((try parseDecimal(&heap, "140737488355327")).?.kind() == .fixnum);
    try testing.expect((try parseDecimal(&heap, "-140737488355328")).?.kind() == .fixnum);
    try testing.expect((try parseDecimal(&heap, "140737488355328")).?.kind() == .bignum);
    try testing.expect((try parseDecimal(&heap, "-140737488355329")).?.kind() == .bignum);
    try testing.expect((try parseDecimal(&heap, "")) == null);
    try testing.expect((try parseDecimal(&heap, "-")) == null);
    try testing.expect((try parseDecimal(&heap, "12x")) == null);
    try testing.expect((try parseDecimal(&heap, "1_000")) == null);
}

test "formatDecimal: the divide-and-conquer split writes std's digits, zero runs included" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var prng = std.Random.DefaultPrng.init(0xDEC1);
    const r = prng.random();
    const ten = try fromI64(&heap, 10);
    var cases: std.ArrayList(Value) = .empty;
    defer cases.deinit(testing.allocator);
    // 10^k - 1, 10^k and 10^k + 1 around the split sizes: all-nines,
    // and a one followed by zero runs that every low half must pad.
    for ([_]u32{ 600, 1000, 4000, 9000 }) |k| {
        var p = try fromI64(&heap, 1);
        for (0..k) |_| p = try mul(&heap, p, ten);
        try cases.append(testing.allocator, try sub(&heap, p, try fromI64(&heap, 1)));
        try cases.append(testing.allocator, p);
        try cases.append(testing.allocator, try add(&heap, p, try fromI64(&heap, 1)));
    }
    for ([_]usize{ 33, 64, 100, 257, 700 }) |n| {
        const ls = try testing.allocator.alloc(u64, n);
        defer testing.allocator.free(ls);
        for (ls) |*l| l.* = r.int(u64);
        try cases.append(testing.allocator, try fromLimbs(&heap, r.boolean(), ls));
    }
    for (cases.items) |v| {
        var s1: [1]Limb = undefined;
        const want = try view(v, &s1).toStringAlloc(testing.allocator, 10, .lower);
        defer testing.allocator.free(want);
        var w = std.Io.Writer.Allocating.init(testing.allocator);
        defer w.deinit();
        try formatDecimal(v, &w.writer);
        try testing.expectEqualStrings(want, w.written());
    }
}

test "fromI128: both limbs, both signs, and the i64 edge" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const v = try fromI128(&heap, (@as(i128, 1) << 100) + 7);
    try testing.expectEqual(@as(usize, 2), limbCount(v));
    try testing.expectEqual(@as(u64, 7), limbs(v)[0]);
    try testing.expectEqual(@as(u64, 1) << 36, limbs(v)[1]);
    const n = try fromI128(&heap, -(@as(i128, 1) << 100));
    try testing.expect(isNegative(n));
    try testing.expect((try fromI128(&heap, 42)).asFixnum() == 42);
    try testing.expect(compare(try fromI128(&heap, std.math.minInt(i64)), try fromI64(&heap, std.math.minInt(i64))) == .eq);
}
