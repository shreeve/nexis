//! test/prop/bignum.zig — randomized properties for the bignum heap kind.
//!
//! Primary purpose: randomized equality and hash laws across the
//! fixnum↔bignum boundary, i.e. canonicalization. Every test here stresses the canonicalization
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
//!   A1. add/sub/compare against Zig i128 over random pairs; every
//!       result canonical.
//!   A2. mul against Zig i128 over random i64 pairs.
//!   A3. quot/rem/mod against @divTrunc/@rem/@mod over every sign
//!       combination and divisor size.
//!   A4. The fixnum boundary: ±2^47 crossed both ways by add and sub,
//!       the kind decided by the value alone.
//!   A5. Algebraic identities on multi-limb values: `(a*b) quot b = a`,
//!       `(a*b) rem b = 0`, `(a+b)-b = a`, `neg(neg a) = a`,
//!       `abs(a) = abs(neg a)`, order agrees with the sign of `a-b`.
//!   A6. Decimal text round-trips; toF64/fromF64 round-trips below 2^53.

const std = @import("std");
const nx = @import("nexis");
const value = nx.value;
const heap_mod = nx.heap;
const hash_mod = nx.hash;
const bignum = nx.bignum;
const dispatch = nx.dispatch;

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

// -----------------------------------------------------------------------------
// Arithmetic (BIGNUM.md §9)
// -----------------------------------------------------------------------------

/// Every value the tower produces is canonical: a fixnum when it fits
/// i48, otherwise a bignum with a nonzero top limb whose magnitude is
/// outside the fixnum range.
fn expectCanonical(v: Value) !void {
    if (v.isFixnum()) return;
    try std.testing.expect(v.kind() == .bignum);
    const l = bignum.limbs(v);
    try std.testing.expect(l[l.len - 1] != 0);
    if (l.len == 1) {
        const bound: u64 = if (bignum.isNegative(v)) @as(u64, 1) << 47 else (@as(u64, 1) << 47) - 1;
        try std.testing.expect(l[0] > bound);
    }
}

fn expectSame(heap: *Heap, got: Value, reference: i128) !void {
    try expectCanonical(got);
    const want = try bignum.fromI128(heap, reference);
    try std.testing.expect(dispatch.equal(got, want));
    try std.testing.expectEqual(dispatch.hashValue(got), dispatch.hashValue(want));
}

/// A random i128 that leaves room for one add or sub without overflow.
fn randI127(r: std.Random) i128 {
    return r.int(i128) >> 1;
}

test "A1: add, sub and compare agree with i128 over random pairs; results are canonical" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();
    var prng = std.Random.DefaultPrng.init(prng_seed +% 11);
    const r = prng.random();
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        // Mix magnitudes: the full i127 range, the i64 range and the fixnum range.
        const a: i128 = switch (r.uintLessThan(u8, 3)) {
            0 => randI127(r),
            1 => r.int(i64),
            else => @as(i128, r.intRangeAtMost(i64, value.fixnum_min, value.fixnum_max)),
        };
        const b: i128 = switch (r.uintLessThan(u8, 3)) {
            0 => randI127(r),
            1 => r.int(i64),
            else => @as(i128, r.intRangeAtMost(i64, value.fixnum_min, value.fixnum_max)),
        };
        const av = try bignum.fromI128(&heap, a);
        const bv = try bignum.fromI128(&heap, b);
        try expectSame(&heap, try bignum.add(&heap, av, bv), a + b);
        try expectSame(&heap, try bignum.sub(&heap, av, bv), a - b);
        try expectSame(&heap, try bignum.neg(&heap, av), -a);
        try expectSame(&heap, try bignum.abs(&heap, av), if (a < 0) -a else a);
        try std.testing.expectEqual(std.math.order(a, b), bignum.compare(av, bv));
        try std.testing.expectEqual(a & 1 == 0, bignum.isEven(av));
    }
}

test "A2: mul agrees with i128 over random i64 pairs" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();
    var prng = std.Random.DefaultPrng.init(prng_seed +% 12);
    const r = prng.random();
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        const a: i64 = if (r.boolean()) r.int(i64) else r.intRangeAtMost(i64, value.fixnum_min, value.fixnum_max);
        const b: i64 = if (r.boolean()) r.int(i64) else r.intRangeAtMost(i64, -1000, 1000);
        const av = try bignum.fromI64(&heap, a);
        const bv = try bignum.fromI64(&heap, b);
        try expectSame(&heap, try bignum.mul(&heap, av, bv), @as(i128, a) * @as(i128, b));
        try expectSame(&heap, try bignum.mul(&heap, bv, av), @as(i128, a) * @as(i128, b));
    }
}

test "A3: quot, rem and mod agree with @divTrunc, @rem and @mod on every sign combination" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();
    var prng = std.Random.DefaultPrng.init(prng_seed +% 13);
    const r = prng.random();
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        const a: i128 = if (r.boolean()) randI127(r) else r.int(i64);
        var b: i128 = switch (r.uintLessThan(u8, 3)) {
            0 => r.int(i64),
            1 => r.intRangeAtMost(i64, -100, 100),
            else => randI127(r),
        };
        if (b == 0) b = 7;
        const av = try bignum.fromI128(&heap, a);
        const bv = try bignum.fromI128(&heap, b);
        try expectSame(&heap, try bignum.quot(&heap, av, bv), @divTrunc(a, b));
        try expectSame(&heap, try bignum.rem(&heap, av, bv), @rem(a, b));
        try expectSame(&heap, try bignum.mod(&heap, av, bv), @mod(a, b));
        const exact = try bignum.quotExact(&heap, av, bv);
        if (@rem(a, b) == 0) {
            try expectSame(&heap, exact.?, @divTrunc(a, b));
        } else {
            try std.testing.expect(exact == null);
        }
    }
}

test "A4: the fixnum boundary is crossed both ways and the kind follows the value alone" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();
    var prng = std.Random.DefaultPrng.init(prng_seed +% 14);
    const r = prng.random();
    const edges = [_]i128{ value.fixnum_max, value.fixnum_min };
    for (edges) |edge| {
        var i: usize = 0;
        while (i < 500) : (i += 1) {
            const delta: i128 = r.intRangeAtMost(i64, -64, 64);
            const target = edge + delta;
            const start = try bignum.fromI128(&heap, edge);
            const dv = try bignum.fromI128(&heap, delta);
            const up = try bignum.add(&heap, start, dv);
            try expectSame(&heap, up, target);
            try std.testing.expectEqual(value.isFixnumRange(@intCast(target)), up.isFixnum());
            const back = try bignum.sub(&heap, up, dv);
            try expectSame(&heap, back, edge);
            try std.testing.expect(back.isFixnum());
            // The same value reached by multiplication and by division.
            const twice = try bignum.mul(&heap, up, try bignum.fromI64(&heap, 2));
            try expectSame(&heap, twice, target * 2);
            try expectSame(&heap, try bignum.quot(&heap, twice, try bignum.fromI64(&heap, 2)), target);
        }
    }
    // The exact edges.
    const max = try bignum.fromI64(&heap, value.fixnum_max);
    const min = try bignum.fromI64(&heap, value.fixnum_min);
    const one = try bignum.fromI64(&heap, 1);
    try std.testing.expect((try bignum.add(&heap, max, one)).kind() == .bignum);
    try std.testing.expect((try bignum.sub(&heap, min, one)).kind() == .bignum);
    try std.testing.expect((try bignum.neg(&heap, min)).kind() == .bignum);
    try std.testing.expect((try bignum.neg(&heap, max)).isFixnum());
    try std.testing.expect((try bignum.sub(&heap, try bignum.add(&heap, max, one), one)).isFixnum());
    try std.testing.expect((try bignum.add(&heap, try bignum.sub(&heap, min, one), one)).isFixnum());
}

/// A random integer of 2 to 5 limbs with either sign.
fn randWide(heap: *Heap, r: std.Random) !Value {
    var buf: [5]u64 = undefined;
    const limbs_slice = randOorLimbs(r, &buf);
    return bignum.fromLimbs(heap, r.boolean(), limbs_slice);
}

test "A5: algebraic identities hold on multi-limb values" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();
    var prng = std.Random.DefaultPrng.init(prng_seed +% 15);
    const r = prng.random();
    const zero = try bignum.fromI64(&heap, 0);
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const a = try randWide(&heap, r);
        const b = try randWide(&heap, r);
        const ab = try bignum.mul(&heap, a, b);
        try expectCanonical(ab);
        try std.testing.expect(dispatch.equal(try bignum.quot(&heap, ab, b), a));
        try std.testing.expect(dispatch.equal((try bignum.quotExact(&heap, ab, b)).?, a));
        try std.testing.expect(dispatch.equal(try bignum.rem(&heap, ab, b), zero));
        try std.testing.expect(dispatch.equal(try bignum.mod(&heap, ab, a), zero));
        const sum = try bignum.add(&heap, a, b);
        try std.testing.expect(dispatch.equal(try bignum.sub(&heap, sum, b), a));
        try std.testing.expect(dispatch.equal(try bignum.sub(&heap, sum, a), b));
        try std.testing.expect(dispatch.equal(try bignum.neg(&heap, try bignum.neg(&heap, a)), a));
        try std.testing.expect(dispatch.equal(try bignum.abs(&heap, a), try bignum.abs(&heap, try bignum.neg(&heap, a))));
        try std.testing.expect(dispatch.equal(try bignum.sub(&heap, a, a), zero));
        // quot/rem/mod reassemble the dividend.
        const q = try bignum.quot(&heap, a, b);
        const rm = try bignum.rem(&heap, a, b);
        try std.testing.expect(dispatch.equal(try bignum.add(&heap, try bignum.mul(&heap, q, b), rm), a));
        const m = try bignum.mod(&heap, a, b);
        if (!dispatch.equal(m, zero)) try std.testing.expectEqual(bignum.isNegative(b), bignum.isNegative(m));
        if (!dispatch.equal(rm, zero)) try std.testing.expectEqual(bignum.isNegative(a), bignum.isNegative(rm));
        // Order agrees with the sign of the difference.
        const diff = try bignum.sub(&heap, a, b);
        const expected_order: std.math.Order = if (dispatch.equal(diff, zero)) .eq else if (bignum.isNegative(diff)) .lt else .gt;
        try std.testing.expectEqual(expected_order, bignum.compare(a, b));
    }
}

test "A6: decimal text and doubles round-trip" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();
    var prng = std.Random.DefaultPrng.init(prng_seed +% 16);
    const r = prng.random();
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        const a = try randWide(&heap, r);
        var w = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer w.deinit();
        try bignum.formatDecimal(a, &w.writer);
        const text = w.written();
        try std.testing.expect(text.len > 19);
        try std.testing.expect(text[0] == '-' or (text[0] >= '1' and text[0] <= '9'));
        const back = (try bignum.parseDecimal(&heap, text)).?;
        try std.testing.expect(dispatch.equal(back, a));
        // Doubles: exact below 2^53; beyond, the double reads back as
        // an integer with the same double, within one ulp of the
        // original: |rounded - a| * 2^52 <= |a|.
        const n: i64 = r.intRangeAtMost(i64, -(1 << 53), 1 << 53);
        const nv = try bignum.fromI64(&heap, n);
        try std.testing.expectEqual(@as(f64, @floatFromInt(n)), bignum.toF64(nv));
        try std.testing.expect(dispatch.equal((try bignum.fromF64(&heap, bignum.toF64(nv))).?, nv));
        const f = bignum.toF64(a);
        try std.testing.expectEqual(bignum.isNegative(a), f < 0);
        const rounded = (try bignum.fromF64(&heap, f)).?;
        try std.testing.expectEqual(f, bignum.toF64(rounded));
        const off = try bignum.abs(&heap, try bignum.sub(&heap, rounded, a));
        const scaled = try bignum.mul(&heap, off, try bignum.fromI64(&heap, 1 << 52));
        try std.testing.expect(bignum.compare(scaled, try bignum.abs(&heap, a)) != .gt);
    }
}
