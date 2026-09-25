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
//! The central invariant (BIGNUM.md §1): for integers, the runtime
//! guarantees that two mathematically-equal integers are always
//! represented by exactly one runtime kind/value form. This is what
//! makes the `(= x y) ⇒ hash(x) = hash(y)` law hold across the
//! fixnum↔bignum boundary without a cross-kind equality rule. Every
//! code path that could produce a bignum funnels through exactly one
//! canonicalization function (`canonicalizeToValue`) that enforces:
//!   - trim trailing zero limbs,
//!   - zero magnitude → `fixnum(0)` regardless of sign,
//!   - fixnum-range magnitude → fixnum,
//!   - otherwise: allocate a heap bignum whose canonical constraints
//!     (BIGNUM.md §2) are all satisfied.

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

/// Body prefix. 8 bytes; followed by a variable-length `[N]u64` limb
/// array. `_pad` is layout-only — it is NEVER fed into hashing or
/// equality. Semantic bytes are only the
/// `negative` field and the limb bytes.
const BignumBody = extern struct {
    /// 0 = non-negative, 1 = negative. Any other value is a runtime
    /// bug caught by safe-build asserts in `isNegative` / accessors.
    negative: u8,
    _pad: [7]u8,
    // limbs: [limb_count]u64 follow immediately after this struct;
    // limb_count = (body.len - 8) / 8. limb[0] is LSW.

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

/// Integer-tower-aware constructor from an `i64`. Returns `fixnum(n)`
/// when `n` is in fixnum range, otherwise a bignum Value. Handles
/// `i64.min` correctly via two's-complement negation in u64 space
/// (BIGNUM.md §7).
pub fn fromI64(heap: *Heap, n: i64) !Value {
    // Fast path: already fits as a fixnum.
    if (value.isFixnumRange(n)) return value.fromFixnum(n).?;

    // Out of fixnum range: materialize sign + single-limb magnitude.
    // For `n == i64.min`, |n| = 2^63 which exactly fits in a u64 limb
    // but NOT in `-n` as i64. Use two's-complement negation on the
    // bit pattern to avoid the overflow.
    const negative = n < 0;
    const magnitude: u64 = if (!negative)
        @intCast(n)
    else
        (~@as(u64, @bitCast(n))) +% 1;

    // Single-limb allocation path; canonicalize still runs the
    // fixnum-range check which will reject (we're here because we
    // failed that check above, but canonicalize re-runs with the
    // sign-aware bound).
    const limbs_arr = [_]u64{magnitude};
    return canonicalizeToValue(heap, negative, &limbs_arr);
}

/// Construct from a signed-magnitude little-endian `u64` limb sequence.
/// Canonicalizes before returning: trims trailing zeros, collapses zero
/// magnitude to `fixnum(0)`, folds fixnum-range magnitudes to `fixnum`.
/// An empty `limbs` slice is treated as magnitude zero (returns
/// `fixnum(0)` regardless of `negative`).
pub fn fromLimbs(heap: *Heap, negative: bool, input_limbs: []const u64) !Value {
    return canonicalizeToValue(heap, negative, input_limbs);
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

/// xxHash3 over {negative_byte, limb_bytes}, truncated to u32.
/// Cached in `HeapHeader.hash` using the cache-if-nonzero pattern
/// (VALUE.md §4). Padding bytes inside the body are deliberately
/// excluded — the hash is over semantic content only.
pub fn hashHeader(h: *HeapHeader) u32 {
    if (std.debug.runtime_safety) {
        std.debug.assert(h.kind == @intFromEnum(Kind.bignum));
    }
    if (h.cachedHash()) |cached| return cached;

    var hasher = std.hash.XxHash3.init(hash_mod.seed);
    hasher.update(&[_]u8{if (headerNegative(h)) 1 else 0});
    hasher.update(std.mem.sliceAsBytes(headerLimbs(h)));
    const raw: u32 = @truncate(hasher.final());
    if (raw != 0) h.setCachedHash(raw);
    return raw;
}

/// GC trace function (GC.md §5). Bignums are leaf heap kinds — their
/// bodies are `{negative: u8, _pad, limbs: [N]u64}` with no heap
/// references.
pub fn trace(h: *HeapHeader, visitor: anytype) void {
    _ = h;
    _ = visitor;
}

/// Semantic equality: same sign, same limb count, same limb bytes.
/// Padding is not compared. Canonical form (no trailing zeros) is
/// maintained by the canonicalizer, so equal limb-byte-streams iff
/// equal magnitudes.
pub fn limbsEqual(a: *HeapHeader, b: *HeapHeader) bool {
    if (std.debug.runtime_safety) {
        std.debug.assert(a.kind == @intFromEnum(Kind.bignum));
        std.debug.assert(b.kind == @intFromEnum(Kind.bignum));
    }
    if (a == b) return true;
    if (headerNegative(a) != headerNegative(b)) return false;
    const al = headerLimbs(a);
    const bl = headerLimbs(b);
    if (al.len != bl.len) return false;
    return std.mem.eql(u64, al, bl);
}

// =============================================================================
// Arithmetic, ordering and conversion (BIGNUM.md §9)
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
    const limbs_u64: []const u64 = @ptrCast(m.limbs[0..m.len]);
    return canonicalizeToValue(heap, !m.positive, limbs_u64);
}

fn mutable(buf: []Limb) bigint.Mutable {
    return .{ .limbs = buf, .len = 1, .positive = true };
}

/// Construct from an `i128`; the two-limb analogue of `fromI64`.
pub fn fromI128(heap: *Heap, n: i128) !Value {
    if (n >= std.math.minInt(i64) and n <= std.math.maxInt(i64)) return fromI64(heap, @intCast(n));
    const mag: u128 = @abs(n);
    const limbs_arr = [_]u64{ @truncate(mag), @truncate(mag >> 64) };
    return canonicalizeToValue(heap, n < 0, &limbs_arr);
}

pub fn add(heap: *Heap, a: Value, b: Value) !Value {
    var sa: [1]Limb = undefined;
    var sb: [1]Limb = undefined;
    const x = view(a, &sa);
    const y = view(b, &sb);
    var sfa = std.heap.stackFallback(scratch_bytes, heap.backing);
    const alloc = sfa.get();
    const buf = try alloc.alloc(Limb, @max(x.limbs.len, y.limbs.len) + 1);
    defer alloc.free(buf);
    var r = mutable(buf);
    r.add(x, y);
    return fromMutable(heap, r);
}

pub fn sub(heap: *Heap, a: Value, b: Value) !Value {
    var sa: [1]Limb = undefined;
    var sb: [1]Limb = undefined;
    const x = view(a, &sa);
    const y = view(b, &sb);
    var sfa = std.heap.stackFallback(scratch_bytes, heap.backing);
    const alloc = sfa.get();
    const buf = try alloc.alloc(Limb, @max(x.limbs.len, y.limbs.len) + 1);
    defer alloc.free(buf);
    var r = mutable(buf);
    r.sub(x, y);
    return fromMutable(heap, r);
}

pub fn mul(heap: *Heap, a: Value, b: Value) !Value {
    var sa: [1]Limb = undefined;
    var sb: [1]Limb = undefined;
    const x = view(a, &sa);
    const y = view(b, &sb);
    var sfa = std.heap.stackFallback(scratch_bytes, heap.backing);
    const alloc = sfa.get();
    const buf = try alloc.alloc(Limb, x.limbs.len + y.limbs.len);
    defer alloc.free(buf);
    var r = mutable(buf);
    r.mulNoAlias(x, y, alloc);
    return fromMutable(heap, r);
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
    var sfa = std.heap.stackFallback(scratch_bytes, heap.backing);
    const alloc = sfa.get();
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
    return canonicalizeToValue(heap, x.positive, @ptrCast(x.limbs));
}

pub fn abs(heap: *Heap, a: Value) !Value {
    var sa: [1]Limb = undefined;
    const x = view(a, &sa);
    return canonicalizeToValue(heap, false, @ptrCast(x.limbs));
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

/// The integer part of a finite f64 (rounding toward zero), in
/// canonical form; `null` for NaN and the infinities, which have no
/// integer value.
pub fn fromF64(heap: *Heap, f: f64) !?Value {
    if (!std.math.isFinite(f)) return null;
    const t = @trunc(f);
    if (@abs(t) < @as(f64, @floatFromInt(@as(u64, 1) << 47))) return value.fromFixnum(@intFromFloat(t)).?;
    var sfa = std.heap.stackFallback(scratch_bytes, heap.backing);
    const alloc = sfa.get();
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

/// Divide and conquer (BIGNUM.md §9): split `x` at a power of ten
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
    var sfa = std.heap.stackFallback(scratch_bytes * 8, std.heap.page_allocator);
    const alloc = sfa.get();
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
    const digits = if (text.len > 0 and text[0] == '-') text[1..] else text;
    if (digits.len == 0) return null;
    for (digits) |c| if (c < '0' or c > '9') return null;
    if (digits.len <= 18) return try fromI64(heap, std.fmt.parseInt(i64, text, 10) catch unreachable);
    var sfa = std.heap.stackFallback(scratch_bytes, heap.backing);
    const alloc = sfa.get();
    const buf = try alloc.alloc(Limb, bigint.calcSetStringLimbCount(10, digits.len));
    defer alloc.free(buf);
    var m = mutable(buf);
    m.setString(10, text) catch unreachable;
    return try fromMutable(heap, m);
}

// =============================================================================
// Private helpers
// =============================================================================

/// The single canonicalization funnel. Every public constructor
/// returns here. Steps in order (BIGNUM.md §3):
///   1. Trim trailing zero limbs.
///   2. Zero magnitude → `fixnum(0)`.
///   3. Fixnum-range magnitude → fixnum.
///   4. Otherwise allocate a heap bignum with trimmed limbs.
fn canonicalizeToValue(heap: *Heap, negative: bool, input_limbs: []const u64) !Value {
    // 1. Trim trailing zeros.
    var trimmed_len: usize = input_limbs.len;
    while (trimmed_len > 0 and input_limbs[trimmed_len - 1] == 0) : (trimmed_len -= 1) {}
    const trimmed = input_limbs[0..trimmed_len];

    // 2. Zero magnitude → fixnum(0). Ignores `negative`.
    if (trimmed.len == 0) return value.fromFixnum(0).?;

    // 3. Fixnum-range magnitude → fixnum. Only a single-limb
    // magnitude can possibly fit; multi-limb is automatically out of
    // i48 range.
    if (trimmed.len == 1) {
        const mag = trimmed[0];
        if (!negative) {
            // Non-negative: representable iff mag <= fixnum_max = 2^47 - 1.
            if (mag <= @as(u64, @intCast(value.fixnum_max))) {
                return value.fromFixnum(@intCast(mag)).?;
            }
        } else {
            // Negative: representable iff mag <= |fixnum_min| = 2^47.
            // The magnitude exactly 2^47 maps to fixnum(-2^47), which
            // IS representable (i48 is asymmetric).
            const neg_bound: u64 = @as(u64, 1) << 47; // 2^47 = |fixnum_min|
            if (mag <= neg_bound) {
                // Reconstruct the signed value. For mag == 2^47, this
                // is fixnum_min. For mag < 2^47, it's `-@as(i64, mag)`.
                const n: i64 = if (mag == neg_bound)
                    value.fixnum_min
                else
                    -@as(i64, @intCast(mag));
                return value.fromFixnum(n).?;
            }
        }
    }

    // 4. Allocate a heap bignum with the trimmed limbs.
    // Overflow-safe: `trimmed.len * limb_bytes` could wrap in non-
    // safe release builds. `std.math.mul` + `std.math.add` reject
    // pathological inputs with `error.Overflow`.
    const limbs_size = try std.math.mul(usize, trimmed.len, limb_bytes);
    const body_size = try std.math.add(usize, prefix_bytes, limbs_size);
    const h = try heap.alloc(.bignum, body_size);
    const body = Heap.bodyBytes(h);
    std.debug.assert(body.len == body_size);

    const prefix: *BignumBody = @ptrCast(@alignCast(body.ptr));
    prefix.negative = if (negative) 1 else 0;
    // _pad bytes are already zero from heap.alloc's zero-init.

    const dst_limbs: []u64 = @as([*]u64, @ptrCast(@alignCast(body.ptr + prefix_bytes)))[0..trimmed.len];
    @memcpy(dst_limbs, trimmed);

    // Canonicality self-check — catches canonicalizer bugs at
    // construction time rather than later at hash/eq.
    if (std.debug.runtime_safety) {
        std.debug.assert(dst_limbs.len >= 1); // not empty
        std.debug.assert(dst_limbs[dst_limbs.len - 1] != 0); // no trailing zero
    }

    return valueFrom(h);
}

/// Private accessor for the body prefix. Centralizes the
/// `body.len >= prefix_bytes` invariant check so every caller
/// doesn't have to re-assert (read-side invariants are enforced,
/// not assumed).
fn headerPrefix(h: *HeapHeader) *const BignumBody {
    const body = Heap.bodyBytes(h);
    std.debug.assert(body.len >= prefix_bytes);
    return @ptrCast(@alignCast(body.ptr));
}

/// Private accessor for the sign bit, centralized so every read
/// path enforces the 0-or-1 invariant on the stored byte.
fn headerNegative(h: *HeapHeader) bool {
    const prefix = headerPrefix(h);
    std.debug.assert(prefix.negative <= 1);
    return prefix.negative == 1;
}

/// Low-level accessor: limbs slice from a `*HeapHeader`. Panics in
/// safe builds if structural constraints aren't met (shape invariants
/// from BIGNUM.md §2: body ≥ prefix, multiple-of-8 tail, ≥ 1 limb,
/// top limb nonzero).
fn headerLimbs(h: *HeapHeader) []const u64 {
    const body = Heap.bodyBytes(h);
    std.debug.assert(body.len >= prefix_bytes);
    const limb_region_bytes = body.len - prefix_bytes;
    std.debug.assert(limb_region_bytes % limb_bytes == 0);
    const limb_count = limb_region_bytes / limb_bytes;
    std.debug.assert(limb_count >= 1); // canonical: non-empty
    const ptr: [*]const u64 = @ptrCast(@alignCast(body.ptr + prefix_bytes));
    const slice = ptr[0..limb_count];
    std.debug.assert(slice[slice.len - 1] != 0); // canonical: no trailing zero
    return slice;
}

/// Pack a heap-bignum Value. Private — the outside world reaches this
/// through `canonicalizeToValue` only.
fn valueFrom(h: *HeapHeader) Value {
    return .{
        .tag = @as(u64, @intFromEnum(Kind.bignum)) |
            (@as(u64, subkind_limbs) << 16),
        .payload = @intFromPtr(h),
    };
}

// =============================================================================
// Inline tests — structural / canonicalization invariants.
// Full Value ↔ dispatch round-trips live in dispatch.zig + test/prop/bignum.zig.
// =============================================================================

test "fromI64: values in fixnum range canonicalize to fixnum" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const cases = [_]i64{ 0, 1, -1, 42, -42, 1000, -1000, value.fixnum_min, value.fixnum_max };
    for (cases) |n| {
        const v = try fromI64(&heap, n);
        try testing.expect(v.kind() == .fixnum);
        try testing.expectEqual(n, v.asFixnum());
    }
    // Nothing was allocated on the heap.
    try testing.expectEqual(@as(usize, 0), heap.liveCount());
}

test "fromI64: values just outside fixnum range become single-limb bignums" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    // fixnum_max + 1 = 2^47, first positive out-of-range value.
    const pos_oor: i64 = value.fixnum_max + 1;
    const v_pos = try fromI64(&heap, pos_oor);
    try testing.expect(v_pos.kind() == .bignum);
    try testing.expect(!isNegative(v_pos));
    try testing.expectEqual(@as(usize, 1), limbCount(v_pos));
    try testing.expectEqual(@as(u64, @intCast(pos_oor)), limbs(v_pos)[0]);
}

test "fromI64: fixnum_min is NOT out of range (asymmetric i48)" {
    // Critical boundary case: -2^47 is exactly fixnum_min and must
    // canonicalize to fixnum, not bignum.
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const v = try fromI64(&heap, value.fixnum_min);
    try testing.expect(v.kind() == .fixnum);
    try testing.expectEqual(value.fixnum_min, v.asFixnum());
}

test "fromI64: i64.min produces a bignum with magnitude 2^63" {
    // Hardest case: |i64.min| = 2^63, which overflows signed negation
    // but fits in a u64 limb. Tests the two's-complement negation path.
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const v = try fromI64(&heap, std.math.minInt(i64));
    try testing.expect(v.kind() == .bignum);
    try testing.expect(isNegative(v));
    try testing.expectEqual(@as(usize, 1), limbCount(v));
    const expected: u64 = @as(u64, 1) << 63;
    try testing.expectEqual(expected, limbs(v)[0]);
}

test "fromLimbs: empty slice returns fixnum(0) regardless of sign" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const a = try fromLimbs(&heap, false, &.{});
    const b = try fromLimbs(&heap, true, &.{});
    try testing.expect(a.kind() == .fixnum and a.asFixnum() == 0);
    try testing.expect(b.kind() == .fixnum and b.asFixnum() == 0);
    try testing.expectEqual(@as(usize, 0), heap.liveCount());
}

test "fromLimbs: all-zero limbs collapse to fixnum(0) regardless of sign" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const v = try fromLimbs(&heap, true, &[_]u64{ 0, 0, 0 });
    try testing.expect(v.kind() == .fixnum);
    try testing.expectEqual(@as(i64, 0), v.asFixnum());
    try testing.expectEqual(@as(usize, 0), heap.liveCount());
}

test "fromLimbs: trailing zeros are trimmed" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    // Single real limb with trailing zeros. The real limb is huge
    // (above fixnum range) so this should produce a 1-limb bignum.
    const big: u64 = (@as(u64, 1) << 50); // 2^50, out of i48 range
    const v = try fromLimbs(&heap, false, &[_]u64{ big, 0, 0 });
    try testing.expect(v.kind() == .bignum);
    try testing.expectEqual(@as(usize, 1), limbCount(v));
    try testing.expectEqual(big, limbs(v)[0]);
}

test "fromLimbs: fixnum-range single-limb magnitude canonicalizes to fixnum" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const v_pos = try fromLimbs(&heap, false, &[_]u64{42});
    try testing.expect(v_pos.kind() == .fixnum);
    try testing.expectEqual(@as(i64, 42), v_pos.asFixnum());

    const v_neg = try fromLimbs(&heap, true, &[_]u64{42});
    try testing.expect(v_neg.kind() == .fixnum);
    try testing.expectEqual(@as(i64, -42), v_neg.asFixnum());

    try testing.expectEqual(@as(usize, 0), heap.liveCount());
}

test "fromLimbs: negative 2^47 canonicalizes to fixnum_min (asymmetric i48 boundary)" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const mag: u64 = @as(u64, 1) << 47; // 2^47 = |fixnum_min|
    const v = try fromLimbs(&heap, true, &[_]u64{mag});
    try testing.expect(v.kind() == .fixnum);
    try testing.expectEqual(value.fixnum_min, v.asFixnum());
    try testing.expectEqual(@as(usize, 0), heap.liveCount());
}

test "fromLimbs: positive 2^47 does NOT fit in fixnum (asymmetric i48 boundary)" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const mag: u64 = @as(u64, 1) << 47; // 2^47, one above fixnum_max
    const v = try fromLimbs(&heap, false, &[_]u64{mag});
    try testing.expect(v.kind() == .bignum);
    try testing.expect(!isNegative(v));
    try testing.expectEqual(@as(usize, 1), limbCount(v));
    try testing.expectEqual(mag, limbs(v)[0]);
}

test "fromLimbs: multi-limb magnitude always allocates a bignum" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const v = try fromLimbs(&heap, false, &[_]u64{ 0xDEAD_BEEF, 0xCAFE_BABE });
    try testing.expect(v.kind() == .bignum);
    try testing.expectEqual(@as(usize, 2), limbCount(v));
    try testing.expectEqual(@as(u64, 0xDEAD_BEEF), limbs(v)[0]);
    try testing.expectEqual(@as(u64, 0xCAFE_BABE), limbs(v)[1]);
}

test "limbsEqual: reflexive and symmetric on distinct allocations" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const big: u64 = @as(u64, 1) << 60;
    const a = try fromLimbs(&heap, false, &[_]u64{ big, 1 });
    const b = try fromLimbs(&heap, false, &[_]u64{ big, 1 });
    const ah = Heap.asHeapHeader(a);
    const bh = Heap.asHeapHeader(b);
    try testing.expect(ah != bh); // distinct allocations
    try testing.expect(limbsEqual(ah, bh));
    try testing.expect(limbsEqual(bh, ah));
    try testing.expect(limbsEqual(ah, ah)); // reflexive
}

test "limbsEqual: sign mismatch breaks equality" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const big: u64 = @as(u64, 1) << 60;
    const a = try fromLimbs(&heap, false, &[_]u64{ big, 1 });
    const b = try fromLimbs(&heap, true, &[_]u64{ big, 1 });
    try testing.expect(!limbsEqual(Heap.asHeapHeader(a), Heap.asHeapHeader(b)));
}

test "limbsEqual: magnitude mismatch breaks equality" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const big: u64 = @as(u64, 1) << 60;
    const a = try fromLimbs(&heap, false, &[_]u64{ big, 1 });
    const b = try fromLimbs(&heap, false, &[_]u64{ big, 2 });
    try testing.expect(!limbsEqual(Heap.asHeapHeader(a), Heap.asHeapHeader(b)));
}

test "limbsEqual: different limb counts break equality" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const a = try fromLimbs(&heap, false, &[_]u64{ 1, 2, 3 });
    const b = try fromLimbs(&heap, false, &[_]u64{ 1, 2 });
    try testing.expect(!limbsEqual(Heap.asHeapHeader(a), Heap.asHeapHeader(b)));
}

test "hashHeader: deterministic, caches nonzero, matches xxHash3 over sign+limbs" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const big: u64 = @as(u64, 1) << 62;
    const v = try fromLimbs(&heap, true, &[_]u64{ big, 7 });
    const h = Heap.asHeapHeader(v);

    // Pre-hash: cache is clear.
    try testing.expectEqual(@as(u32, 0), h.hash);

    // Compute the expected hash by hand: xxHash3 over
    // {negative_byte} ++ limb_bytes.
    var hasher = std.hash.XxHash3.init(hash_mod.seed);
    hasher.update(&[_]u8{1}); // negative
    const limb_arr = [_]u64{ big, 7 };
    hasher.update(std.mem.sliceAsBytes(&limb_arr));
    const expected: u32 = @truncate(hasher.final());

    try testing.expectEqual(expected, hashHeader(h));
    try testing.expectEqual(expected, hashHeader(h)); // deterministic, re-reads cache

    if (expected != 0) {
        try testing.expectEqual(expected, h.hash); // cached
    }
}

test "hashHeader: equal bignums across allocations have equal hashes" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const big: u64 = @as(u64, 1) << 55;
    const a = try fromLimbs(&heap, false, &[_]u64{ big, big, big });
    const b = try fromLimbs(&heap, false, &[_]u64{ big, big, big });
    try testing.expectEqual(
        hashHeader(Heap.asHeapHeader(a)),
        hashHeader(Heap.asHeapHeader(b)),
    );
}

test "hashHeader: sign flip changes the hash" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const big: u64 = @as(u64, 1) << 55;
    const positive = try fromLimbs(&heap, false, &[_]u64{big});
    const negative = try fromLimbs(&heap, true, &[_]u64{big});
    try testing.expect(hashHeader(Heap.asHeapHeader(positive)) !=
        hashHeader(Heap.asHeapHeader(negative)));
}

test "body layout: canonical bignum has no trailing zero limbs" {
    // Direct invariant check: for every bignum we construct, the
    // top limb is nonzero.
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const big: u64 = @as(u64, 1) << 60;
    const cases = [_][]const u64{
        &[_]u64{big},
        &[_]u64{ big, 1 },
        &[_]u64{ big, 1, 2, 3 },
    };
    for (cases) |input| {
        const v = try fromLimbs(&heap, false, input);
        try testing.expect(v.kind() == .bignum);
        const l = limbs(v);
        try testing.expect(l[l.len - 1] != 0);
    }
}

test "body layout: pad bytes are zero (heap.alloc zero-init) and never semantic" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const big: u64 = @as(u64, 1) << 50;
    const v = try fromLimbs(&heap, false, &[_]u64{big});
    const h = Heap.asHeapHeader(v);
    const body = Heap.bodyBytes(h);
    // Pad bytes are offsets 1..8 in the body; must be zero from
    // heap.alloc's memset. Hashing + equality never inspect them;
    // this is a layout-integrity check only.
    for (body[1..8]) |b| {
        try testing.expectEqual(@as(u8, 0), b);
    }
}

test "valueFrom: tag encodes kind + subkind, payload = *HeapHeader" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const big: u64 = @as(u64, 1) << 50;
    const v = try fromLimbs(&heap, false, &[_]u64{big});
    try testing.expect(v.kind() == .bignum);
    try testing.expectEqual(subkind_limbs, v.subkind());
    try testing.expectEqual(@intFromPtr(Heap.asHeapHeader(v)), v.payload);
}

test "cross-constructor canonical coherence: fromI64(n) ≡ fromLimbs(false, &{n, 0, 0})" {
    // Per BIGNUM.md §1: semantically-equal
    // integers produced through different constructor paths must be
    // byte-identical `Value`s (same kind, same payload when fixnum;
    // or equal-by-structure bignums that share hashValue).
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const via_i64 = try fromI64(&heap, 123);
    const via_tight = try fromLimbs(&heap, false, &[_]u64{123});
    const via_padded = try fromLimbs(&heap, false, &[_]u64{ 123, 0, 0 });
    // All three canonicalize to fixnum(123); every invariant follows.
    try testing.expect(via_i64.kind() == .fixnum);
    try testing.expect(via_tight.kind() == .fixnum);
    try testing.expect(via_padded.kind() == .fixnum);
    try testing.expectEqual(@as(i64, 123), via_i64.asFixnum());
    try testing.expectEqual(via_i64.tag, via_tight.tag);
    try testing.expectEqual(via_i64.payload, via_tight.payload);
    try testing.expectEqual(via_i64.tag, via_padded.tag);
    try testing.expectEqual(via_i64.payload, via_padded.payload);
    // No heap allocations because every input canonicalized away.
    try testing.expectEqual(@as(usize, 0), heap.liveCount());
}

test "cross-constructor canonical coherence: i64.min ≡ fromLimbs(true, &{1<<63})" {
    // Two paths to the same out-of-fixnum-range magnitude: fromI64
    // via two's-complement negation, and fromLimbs via explicit
    // sign+magnitude. Both must produce bignums that compare equal
    // by `limbsEqual` and share `hashHeader`.
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const via_i64 = try fromI64(&heap, std.math.minInt(i64));
    const via_limbs = try fromLimbs(&heap, true, &[_]u64{@as(u64, 1) << 63});
    try testing.expect(via_i64.kind() == .bignum);
    try testing.expect(via_limbs.kind() == .bignum);
    const ah = Heap.asHeapHeader(via_i64);
    const bh = Heap.asHeapHeader(via_limbs);
    try testing.expect(ah != bh); // distinct allocations
    try testing.expect(limbsEqual(ah, bh));
    try testing.expectEqual(hashHeader(ah), hashHeader(bh));
}

// =============================================================================
// Inline tests — arithmetic, ordering and conversion
// =============================================================================

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
    var two200_limbs = [_]u64{0} ** 4;
    two200_limbs[3] = @as(u64, 1) << 8;
    const two200 = try fromLimbs(&heap, false, &two200_limbs);
    try testing.expect(compare((try fromF64(&heap, toF64(two200))).?, two200) == .eq);
    try testing.expect(std.math.isInf(toF64(try fromLimbs(&heap, false, &([_]u64{1} ** 20)))));
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
