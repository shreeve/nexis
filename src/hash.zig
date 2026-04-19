//! hash.zig — primitive hashing kernel for the runtime Value layer.
//!
//! This module is intentionally **Value-unaware**. It exports hashers over
//! raw bytes and primitive machine types, plus the two structural combine
//! functions that every aggregate kind must use. `src/value.zig` and
//! `src/eq.zig` import these; no dependency goes the other way.
//!
//! Scope-of-authority: SEMANTICS.md §3 pins the hash invariants. VALUE.md
//! §6 pins the contract (`(= x y) ⇒ (hash x) = (hash y)`). This file is
//! the implementation, not the spec.
//!
//! Algorithm: xxHash3-64 from `std.hash.XxHash3`. Chosen for speed,
//! distribution, and SIMD friendliness (PLAN §9.1, §23 #37 companion).
//! Clojure uses Murmur3; we target a better-distributed, faster modern
//! hash as planned in CLOJURE-REVIEW §2.3.
//!
//! Collection combine functions match Clojure's structural hashing so
//! that the cross-category sequential equality rule (PLAN §6.6) yields
//! equal hashes for `(list 1 2 3)` and `[1 2 3]` by construction.

const std = @import("std");

/// Fixed xxHash3 seed. Chosen once, frozen forever — changing it would
/// invalidate every previously-serialized hash value and break the
/// cross-process stability guarantee for codec-serialized values
/// (SEMANTICS §3.1). Derived from the literal "nexis/1" (ASCII) zero-
/// padded to 8 bytes and read as little-endian u64.
pub const seed: u64 = 0x0000_0000_3173_6978_656E | (@as(u64, '/') << 48) | (@as(u64, '1') << 56);

// Keyword/symbol domain separation is handled by the generic
// `mixKindDomain` below (each Kind byte lands in a distinct region of
// u64 space). This subsumes Clojure's `keyword.hash ^= 0x9E3779B9`
// pattern (PLAN §8.4, §23 #32) for v1 since every Kind participates in
// the same mechanism rather than keyword alone getting a special offset.
// The `mixKeywordDomain` helper is kept below as a thin alias for
// clarity at call sites that want to express "deliberately shifting a
// keyword into its own space," but it layers on top of the generic
// mixer rather than duplicating the separation story.

/// Multiplier used by `combineOrdered`. Matches Clojure's `31 * h +
/// hasheq(x)` (Util.java:hashCombine). Frozen so that
/// `(list 1 2 3)` and `[1 2 3]` always share a hash — the cross-category
/// sequential equality rule in PLAN §6.6 requires it by construction.
pub const ordered_mul: u64 = 31;

/// Per-kind domain mixer used by `mixKindDomain`. A 64-bit golden-ratio
/// constant that, when multiplied by a kind byte, lands the result in a
/// high-entropy quadrant of u64 space. Separates kinds that happen to
/// share a raw-payload hash (e.g. `fixnum(65)` vs `symbol(65)`) so
/// heterogeneous-key HAMTs don't degenerate on coincidentally-equal
/// payload hashes.
pub const kind_domain_mixer: u64 = 0x9E37_79B9_7F4A_7C15;

/// Canonical NaN bit pattern (quiet NaN, zero payload). All NaN-valued
/// `Value.float` instances are normalized to this exact bit pattern at
/// construction so that `hash` and `=` can treat them as a single
/// observable value (SEMANTICS §2.2 / §3.2).
pub const canonical_nan_bits: u64 = 0x7FF8_0000_0000_0000;

/// Positive-zero bit pattern. Both `+0.0` and `-0.0` hash from this
/// pattern so the `(= 0.0 -0.0) ⇒ hash eq` invariant holds (SEMANTICS
/// §3.2).
pub const positive_zero_bits: u64 = 0x0000_0000_0000_0000;

// -----------------------------------------------------------------------------
// Primitive-level hashers
// -----------------------------------------------------------------------------

/// Hash raw bytes. 64-bit output; the caller truncates or folds as
/// needed.
pub inline fn hashBytes(bytes: []const u8) u64 {
    return std.hash.XxHash3.hash(seed, bytes);
}

/// Hash a 64-bit signed integer in a fixed (little-endian) byte order.
/// This is the canonical int hasher used by fixnum and (for small
/// values) bignum canonicalizations.
pub fn hashI64(n: i64) u64 {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(i64, &buf, n, .little);
    return hashBytes(&buf);
}

/// Hash an unsigned 64-bit integer (used for intern ids, store-ids,
/// bignum limb blocks, etc.) in fixed-endian.
pub fn hashU64(n: u64) u64 {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, n, .little);
    return hashBytes(&buf);
}

/// Hash a Unicode scalar (`u21`). Zero-extended to 4 bytes so the
/// same scalar always produces the same hash across 32-bit and 64-bit
/// platforms.
pub fn hashChar(scalar: u21) u64 {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, @intCast(scalar), .little);
    return hashBytes(&buf);
}

/// Hash a canonical-form f64. `+0.0` and `-0.0` collapse to the
/// positive-zero bit pattern; NaN must already have been canonicalized
/// by the caller (enforce via `canonicalizeFloat`). The function asserts
/// the invariant in Debug builds.
pub fn hashFloat(f: f64) u64 {
    var bits: u64 = @bitCast(f);
    if (f == 0.0) bits = positive_zero_bits; // collapses -0.0 → +0.0
    if (std.math.isNan(f)) {
        std.debug.assert(bits == canonical_nan_bits);
    }
    return hashU64(bits);
}

/// Normalize an incoming f64 for storage inside a `Value.float`. NaN
/// is the only value we canonicalize at storage time — every NaN bit
/// pattern collapses to `canonical_nan_bits` so `(= nan nan)` is
/// reflexive and `hashValue` is stable (SEMANTICS §2.2).
///
/// **Signed zero is NOT canonicalized here.** SEMANTICS §2.2 specifies
/// that `identical?` distinguishes `-0.0` from `+0.0` even though `=`
/// and `hash` collapse them. The collapse happens in `hashFloat` only;
/// storage preserves the incoming bit pattern.
pub fn canonicalizeFloat(f: f64) f64 {
    if (std.math.isNan(f)) return @bitCast(canonical_nan_bits);
    return f;
}

// -----------------------------------------------------------------------------
// Domain mixing
// -----------------------------------------------------------------------------

/// Mix a per-kind offset into a base hash so values of different kinds
/// with coincidentally-equal raw-payload hashes (`fixnum(65)` vs
/// `symbol(65)` vs `char(65)`) still land in disjoint regions of the
/// 64-bit hash space. Cheap — a multiply and an add. Applied by the
/// runtime's `Value.hashValue()` after the per-kind primitive hash so
/// every kind automatically carries its own domain even when future
/// kinds are added. Includes keyword-vs-symbol separation as a
/// special case (their kind bytes differ).
pub inline fn mixKindDomain(base: u64, kind_tag: u8) u64 {
    return base +% (@as(u64, kind_tag) *% kind_domain_mixer);
}

// -----------------------------------------------------------------------------
// Structural combiners
// -----------------------------------------------------------------------------

/// Ordered (sequential) combine: `h := mul * h + x`. Matches Clojure's
/// `Util.hashCombine` pattern. Sequential-category collections (list,
/// vector, lazy-seq, cons) must use this same combiner for the cross-
/// category equality rule to hold (PLAN §6.6, §23 #36).
pub inline fn combineOrdered(h: u64, x: u64) u64 {
    return h *% ordered_mul +% x;
}

/// Finalize an ordered hash by folding in the element count. Count
/// inclusion protects against the empty-vs-singleton confusion
/// `(hash []) == (hash [0])` that raw `combineOrdered` would produce.
pub inline fn finalizeOrdered(h: u64, count: usize) u64 {
    return combineOrdered(h, hashU64(@as(u64, count)));
}

/// Unordered combine: `h := h + x`. Maps (key/value pairs) and sets use
/// this so element ordering never affects the aggregate hash.
pub inline fn combineUnordered(h: u64, x: u64) u64 {
    return h +% x;
}

/// Finalize an unordered hash with count. Same role as
/// `finalizeOrdered` — disambiguates empty-vs-other cases.
pub inline fn finalizeUnordered(h: u64, count: usize) u64 {
    return combineOrdered(h, hashU64(@as(u64, count)));
}

// -----------------------------------------------------------------------------
// Convenience: seed + starting values
// -----------------------------------------------------------------------------

/// Initial accumulator for `combineOrdered`. Equivalent to hashing the
/// empty byte slice — the identity for subsequent `combineOrdered`
/// calls.
pub const ordered_init: u64 = 1;

/// Initial accumulator for `combineUnordered`. Zero is the additive
/// identity.
pub const unordered_init: u64 = 0;

// -----------------------------------------------------------------------------
// Tests — invariants over primitive hashers and combiners.
// -----------------------------------------------------------------------------

test "hashBytes is deterministic and seed-stable" {
    const s = "hello, nexis";
    try std.testing.expectEqual(hashBytes(s), hashBytes(s));
    // Different inputs almost always yield different hashes. We assert
    // inequality on a curated pair chosen to never collide; this is not
    // a statistical property test, just a sanity check.
    try std.testing.expect(hashBytes("a") != hashBytes("b"));
}

test "hashI64 / hashU64 / hashChar are endian-stable" {
    // Ground-truth bytes for 0xDEADBEEF_CAFEBABE in little-endian.
    const v: u64 = 0xDEADBEEF_CAFEBABE;
    var expected_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &expected_bytes, v, .little);
    try std.testing.expectEqual(hashBytes(&expected_bytes), hashU64(v));

    try std.testing.expectEqual(hashU64(42), hashI64(42));
    try std.testing.expect(hashI64(-1) != hashI64(1));

    // Char zero-extension: a 21-bit codepoint must hash the same as its
    // u32 zero-extended little-endian form.
    const snowman: u21 = 0x2603;
    var cbuf: [4]u8 = undefined;
    std.mem.writeInt(u32, &cbuf, 0x2603, .little);
    try std.testing.expectEqual(hashBytes(&cbuf), hashChar(snowman));
}

test "canonicalizeFloat normalizes NaN to the canonical bit pattern" {
    const nan_a: f64 = std.math.nan(f64);
    const nan_b: f64 = @bitCast(@as(u64, 0x7FFF_FFFF_FFFF_FFFF)); // non-canonical NaN bits
    try std.testing.expect(std.math.isNan(nan_a));
    try std.testing.expect(std.math.isNan(nan_b));
    const ca: u64 = @bitCast(canonicalizeFloat(nan_a));
    const cb: u64 = @bitCast(canonicalizeFloat(nan_b));
    try std.testing.expectEqual(canonical_nan_bits, ca);
    try std.testing.expectEqual(canonical_nan_bits, cb);
}

test "hashFloat collapses -0.0 to +0.0 for hash equality" {
    const pos: f64 = 0.0;
    const neg: f64 = -0.0;
    // Bit patterns differ — sanity the test setup.
    try std.testing.expect(@as(u64, @bitCast(pos)) != @as(u64, @bitCast(neg)));
    // ...but hashes must collapse, because `(= 0.0 -0.0)` is true
    // (SEMANTICS §2.2).
    try std.testing.expectEqual(hashFloat(pos), hashFloat(neg));
}

test "hashFloat on canonical NaN is deterministic" {
    const nan1 = canonicalizeFloat(std.math.nan(f64));
    const nan2 = canonicalizeFloat(@bitCast(@as(u64, 0x7FFF_FFFF_FFFF_FFFF)));
    try std.testing.expectEqual(hashFloat(nan1), hashFloat(nan2));
}

test "mixKindDomain separates coincidentally-equal payload hashes" {
    const base = hashU64(65);
    // Different kind bytes ⇒ distinct outputs; pure function; zero-kind
    // is the identity.
    try std.testing.expectEqual(base, mixKindDomain(base, 0));
    const d3 = mixKindDomain(base, 3);
    const d4 = mixKindDomain(base, 4);
    const d7 = mixKindDomain(base, 7);
    try std.testing.expect(d3 != d4);
    try std.testing.expect(d4 != d7);
    try std.testing.expect(d3 != d7);
    try std.testing.expectEqual(d4, mixKindDomain(base, 4)); // determinism
}

test "combineOrdered matches Clojure-style 31*h + x" {
    // Build an ordered hash of three elements explicitly, then verify
    // the combiner-based path produces the same u64 value.
    const e1 = hashI64(1);
    const e2 = hashI64(2);
    const e3 = hashI64(3);

    var manual: u64 = ordered_init;
    manual = manual *% ordered_mul +% e1;
    manual = manual *% ordered_mul +% e2;
    manual = manual *% ordered_mul +% e3;

    var via: u64 = ordered_init;
    via = combineOrdered(via, e1);
    via = combineOrdered(via, e2);
    via = combineOrdered(via, e3);

    try std.testing.expectEqual(manual, via);
}

test "combineOrdered: sequential equality cross-category invariant" {
    // A list [1,2,3] and a vector [1,2,3] must hash identically by
    // construction. We exercise the INVARIANT at the combiner level:
    // driven by the same per-element hashes and count, the final hash
    // is identical regardless of which "collection" produced it.
    const items = [_]i64{ 1, 2, 3 };
    var h_list: u64 = ordered_init;
    var h_vec: u64 = ordered_init;
    for (items) |it| {
        h_list = combineOrdered(h_list, hashI64(it));
        h_vec = combineOrdered(h_vec, hashI64(it));
    }
    const final_list = finalizeOrdered(h_list, items.len);
    const final_vec = finalizeOrdered(h_vec, items.len);
    try std.testing.expectEqual(final_list, final_vec);
}

test "combineUnordered is order-insensitive" {
    const a = hashI64(1);
    const b = hashI64(2);
    const c = hashI64(3);

    const abc = combineUnordered(combineUnordered(combineUnordered(unordered_init, a), b), c);
    const cba = combineUnordered(combineUnordered(combineUnordered(unordered_init, c), b), a);
    const bac = combineUnordered(combineUnordered(combineUnordered(unordered_init, b), a), c);

    try std.testing.expectEqual(abc, cba);
    try std.testing.expectEqual(abc, bac);
}

test "finalization with count disambiguates empty vs non-empty" {
    const empty = finalizeOrdered(ordered_init, 0);
    const one_zero = finalizeOrdered(combineOrdered(ordered_init, hashI64(0)), 1);
    try std.testing.expect(empty != one_zero);

    const u_empty = finalizeUnordered(unordered_init, 0);
    const u_one = finalizeUnordered(combineUnordered(unordered_init, hashI64(0)), 1);
    try std.testing.expect(u_empty != u_one);
}
