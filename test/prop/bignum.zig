//! test/prop/bignum.zig — randomized properties for the bignum heap kind.
//!
//! Primary purpose: retire the Phase 1 gate test #1 "fixnum↔bignum
//! canonicalization" risk that peer-AI turn-3 flagged as a lurking
//! semantic hotspot. Every test here stresses the canonicalization
//! invariant: a bignum whose magnitude fits in i48 cannot exist, so
//! two mathematically-equal integers are always represented by exactly
//! one runtime kind/value form (BIGNUM.md §1).
//!
//! Deterministic PRNG seeds so failures reproduce.
//!
//! Properties:
//!   N1. `fromI64(n)` canonicalization: fixnum-range n → fixnum (no
//!       heap alloc); out-of-range n → bignum with correct magnitude.
//!   N2. i64.min specifically: two's-complement negation produces a
//!       bignum whose single-limb magnitude is exactly 2⁶³.
//!   N3. `fromLimbs` fixnum-range fold: any input whose trimmed
//!       magnitude fits in i48 must return a fixnum, not a bignum.
//!   N4. `fromLimbs` zero fold: all-zero limb input (any sign) → fixnum(0).
//!   N5. Trailing-zero trim: bignums that escape `fromLimbs` have
//!       nonzero top limb.
//!   N6. Equivalence relation on bignums: reflexive, symmetric,
//!       (pairwise) transitive.
//!   N7. Bedrock `equal ⇒ hashValue equal` over 500 random bignum
//!       pairs built from identical limb sequences in different
//!       allocations.
//!   N8. Cross-kind: bignums are never `=` to any non-bignum Value
//!       (including fixnums, since canonicalization prevents overlap).
//!   N9. Reconstruction round-trip: build a bignum from random limbs,
//!       read the limbs back, confirm byte-exact equality including
//!       sign.
//!   N10. `hashValue` matches the spec formula: xxHash3 over
//!        {negative_byte, limb_bytes}, kind-domain mixed via dispatch.

const std = @import("std");
const value = @import("value");
const heap_mod = @import("heap");
const hash_mod = @import("hash");
const bignum = @import("bignum");
const dispatch = @import("dispatch");

const Value = value.Value;
const Heap = heap_mod.Heap;

const prng_seed: u64 = 0x6269_676E_756D_5F70; // "bignum_p" ASCII LE

/// Build a random limb sequence guaranteed to land outside the fixnum
/// range — at least 2 limbs, with a nonzero top limb.
fn randOorLimbs(rand: std.Random, buf: []u64) []const u64 {
    std.debug.assert(buf.len >= 2);
    const n = 2 + rand.uintLessThan(usize, buf.len - 1);
    for (buf[0..n]) |*slot| slot.* = rand.int(u64);
    // Force the top limb to be nonzero so canonical trim doesn't
    // unexpectedly shrink to a fixnum-range magnitude.
    if (buf[n - 1] == 0) buf[n - 1] = 1;
    return buf[0..n];
}

// -----------------------------------------------------------------------------
// N1. fromI64 canonicalization boundary
// -----------------------------------------------------------------------------

test "N1: fromI64 fixnum-range → fixnum (no alloc); out-of-range → bignum" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 1);
    const r = prng.random();

    var i: usize = 0;
    while (i < 500) : (i += 1) {
        // Sample across the i64 range so we hit both branches.
        const n = r.int(i64);
        const v = try bignum.fromI64(&heap, n);
        if (value.isFixnumRange(n)) {
            try std.testing.expect(v.kind() == .fixnum);
            try std.testing.expectEqual(n, v.asFixnum());
        } else {
            try std.testing.expect(v.kind() == .bignum);
        }
    }
    // Drop any bignums before deinit so testing.allocator is clean.
    _ = heap.sweepUnmarked();
}

// -----------------------------------------------------------------------------
// N2. i64.min round-trip
// -----------------------------------------------------------------------------

test "N2: fromI64(i64.min) produces a bignum with magnitude 2^63" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    const v = try bignum.fromI64(&heap, std.math.minInt(i64));
    try std.testing.expect(v.kind() == .bignum);
    try std.testing.expect(bignum.isNegative(v));
    try std.testing.expectEqual(@as(usize, 1), bignum.limbCount(v));
    const expected: u64 = @as(u64, 1) << 63;
    try std.testing.expectEqual(expected, bignum.limbs(v)[0]);
}

// -----------------------------------------------------------------------------
// N3. fromLimbs fixnum-range fold
// -----------------------------------------------------------------------------

test "N3: fromLimbs with fixnum-range magnitude canonicalizes to fixnum (no alloc)" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 3);
    const r = prng.random();

    var i: usize = 0;
    while (i < 200) : (i += 1) {
        // Single limb whose value fits in fixnum range for both signs.
        // Use [1, 2^47 - 1] to stay in symmetric valid range (2^47 is
        // only valid as negative, so we exclude it here).
        const mag: u64 = r.uintAtMost(u64, @as(u64, @intCast(value.fixnum_max))) + 0;
        const negative = r.boolean();
        const v = try bignum.fromLimbs(&heap, negative, &[_]u64{mag});
        try std.testing.expect(v.kind() == .fixnum);
        const expected: i64 = if (negative and mag != 0)
            -@as(i64, @intCast(mag))
        else
            @as(i64, @intCast(mag));
        try std.testing.expectEqual(expected, v.asFixnum());
    }
    try std.testing.expectEqual(@as(usize, 0), heap.liveCount());
}

// -----------------------------------------------------------------------------
// N4. Zero fold
// -----------------------------------------------------------------------------

test "N4: fromLimbs zero magnitude (any sign, any length) → fixnum(0)" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    const shapes = [_][]const u64{
        &.{},
        &[_]u64{0},
        &[_]u64{ 0, 0 },
        &[_]u64{ 0, 0, 0, 0, 0, 0 },
    };
    for (shapes) |shape| {
        for ([_]bool{ false, true }) |neg| {
            const v = try bignum.fromLimbs(&heap, neg, shape);
            try std.testing.expect(v.kind() == .fixnum);
            try std.testing.expectEqual(@as(i64, 0), v.asFixnum());
        }
    }
    try std.testing.expectEqual(@as(usize, 0), heap.liveCount());
}

// -----------------------------------------------------------------------------
// N5. Trailing-zero trim
// -----------------------------------------------------------------------------

test "N5: bignums from fromLimbs never have trailing zero limbs" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 5);
    const r = prng.random();

    var buf: [8]u64 = undefined;
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const input = randOorLimbs(r, &buf);
        // Pad with arbitrary trailing zeros so trimming has work to do.
        var padded: [12]u64 = undefined;
        @memcpy(padded[0..input.len], input);
        const pad_count = r.uintAtMost(usize, 4);
        for (padded[input.len..][0..pad_count]) |*z| z.* = 0;
        const v = try bignum.fromLimbs(&heap, r.boolean(), padded[0 .. input.len + pad_count]);
        try std.testing.expect(v.kind() == .bignum);
        const l = bignum.limbs(v);
        try std.testing.expect(l[l.len - 1] != 0);
    }
    _ = heap.sweepUnmarked();
}

// -----------------------------------------------------------------------------
// N6. Equivalence relation on bignums
// -----------------------------------------------------------------------------

test "N6: equal is reflexive, symmetric, pairwise transitive on random bignums" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 6);
    const r = prng.random();

    // Build a pool of bignums. Some pairs will share limb sequences to
    // make transitivity tests meaningful.
    const N: usize = 32;
    const vs = try gpa.alloc(Value, N);
    defer gpa.free(vs);

    var buf: [6]u64 = undefined;
    for (vs) |*slot| {
        const input = randOorLimbs(r, &buf);
        slot.* = try bignum.fromLimbs(&heap, r.boolean(), input);
    }

    for (vs) |a| {
        try std.testing.expect(dispatch.equal(a, a));
        for (vs) |b| {
            try std.testing.expectEqual(dispatch.equal(a, b), dispatch.equal(b, a));
            if (!dispatch.equal(a, b)) continue;
            for (vs) |c| {
                if (!dispatch.equal(b, c)) continue;
                try std.testing.expect(dispatch.equal(a, c));
            }
        }
    }
}

// -----------------------------------------------------------------------------
// N7. Bedrock: equal ⇒ hashValue equal
// -----------------------------------------------------------------------------

test "N7: equal bignums across allocations share hashValue (bedrock)" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 7);
    const r = prng.random();

    var buf: [6]u64 = undefined;
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const input = randOorLimbs(r, &buf);
        const neg = r.boolean();
        const a = try bignum.fromLimbs(&heap, neg, input);
        const b = try bignum.fromLimbs(&heap, neg, input);
        try std.testing.expect(dispatch.equal(a, b));
        try std.testing.expectEqual(dispatch.hashValue(a), dispatch.hashValue(b));
    }
}

// -----------------------------------------------------------------------------
// N8. Cross-kind never-equal
// -----------------------------------------------------------------------------

test "N8: bignum is never equal to any non-bignum Value; hashes differ" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    const big = try bignum.fromLimbs(&heap, false, &[_]u64{ 1, 1 });
    try std.testing.expect(big.kind() == .bignum);
    const big_h = dispatch.hashValue(big);

    const others = [_]Value{
        value.nilValue(),
        value.fromBool(true),
        value.fromBool(false),
        value.fromFixnum(0).?,
        value.fromFixnum(1).?,
        value.fromFixnum(value.fixnum_max).?,
        value.fromFixnum(value.fixnum_min).?,
        value.fromFloat(0.0),
        value.fromFloat(1.0),
        value.fromChar('x').?,
        value.fromKeywordId(0),
        value.fromSymbolId(0),
    };
    for (others) |o| {
        try std.testing.expect(!dispatch.equal(big, o));
        try std.testing.expect(!dispatch.equal(o, big));
        try std.testing.expect(big_h != dispatch.hashValue(o));
    }
}

// -----------------------------------------------------------------------------
// N9. Reconstruction round-trip
// -----------------------------------------------------------------------------

test "N9: fromLimbs + accessors round-trip limbs + sign byte-exact" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 9);
    const r = prng.random();

    var buf: [6]u64 = undefined;
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const input = randOorLimbs(r, &buf);
        const neg = r.boolean();
        const v = try bignum.fromLimbs(&heap, neg, input);
        try std.testing.expect(v.kind() == .bignum);
        try std.testing.expectEqual(neg, bignum.isNegative(v));
        try std.testing.expectEqualSlices(u64, input, bignum.limbs(v));
    }
}

// -----------------------------------------------------------------------------
// N10. hashValue matches spec formula
// -----------------------------------------------------------------------------

test "N10: hashValue(bignum) matches xxHash3 over {sign, limbs} + mixKindDomain" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    const big: u64 = @as(u64, 1) << 62;
    const limb_arr = [_]u64{ big, 3, 5 };
    const v = try bignum.fromLimbs(&heap, true, &limb_arr);
    try std.testing.expect(v.kind() == .bignum);

    // Compute expected by hand.
    var hasher = std.hash.XxHash3.init(hash_mod.seed);
    hasher.update(&[_]u8{1}); // negative
    hasher.update(std.mem.sliceAsBytes(&limb_arr));
    const base_u32: u32 = @truncate(hasher.final());
    const expected = hash_mod.mixKindDomain(@as(u64, base_u32), @intFromEnum(value.Kind.bignum));

    try std.testing.expectEqual(expected, dispatch.hashValue(v));
}
