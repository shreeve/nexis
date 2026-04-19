//! test/prop/primitive.zig — randomized property tests for immediates.
//!
//! This is the first entry in the Phase 1 gate test suite (PLAN §20.2
//! test #1). It exercises the bedrock invariants of `identical?`, `=`,
//! and `hash` across the full immediate kind space, using a deterministic
//! PRNG so failures are reproducible.
//!
//! Each property runs `iterations` times with a fixed seed. The counts
//! are small here (1 000 × 7 properties = 7 000 checks) because
//! immediates are a closed world; the big 100k-iteration sweep lands
//! once heap kinds come online and the matrix actually has weight.
//!
//! Invariants exercised (SEMANTICS §2, VALUE.md §6):
//!   P1. `identical?` is reflexive.
//!   P2. `=` is reflexive, symmetric, transitive.
//!   P3. `(identical? x y) ⇒ (= x y)`.
//!   P4. `(= x y) ⇒ (hash x) = (hash y)` — the bedrock.
//!   P5. Metadata is absent on immediates; `hash` is a pure function of
//!       the discriminating state.
//!   P6. Cross-kind: `(= x y)` is false when `kind(x) != kind(y)`, with
//!       the explicit exception of `{false_, true_}` never being `=`.
//!   P7. NaN canonicalization: any f64 input — including arbitrary NaN
//!       bit patterns — produces a Value whose hash and equality
//!       behaviour are identical to the canonical NaN.
//!
//! There's no adversarial key generator here; the sample space is
//! dense enough (every kind, broad value ranges) that a fixed-seed
//! uniform sampler catches the interesting cases.

const std = @import("std");
const value = @import("value");
const eq = @import("eq");
const hash = @import("hash");

const Value = value.Value;

const iterations_per_property: usize = 1_000;
const prng_seed: u64 = 0x6E65_7869_7350_726F; // "nexisPro" as ASCII big-endian

const Kind = enum { nil_, true_v, false_v, char_v, fixnum_v, float_v, kw_v, sym_v };
const kind_count: usize = @typeInfo(Kind).@"enum".fields.len;

fn randKind(rand: std.Random) Kind {
    return @enumFromInt(rand.uintLessThan(u8, kind_count));
}

fn randValue(rand: std.Random) Value {
    const k = randKind(rand);
    return switch (k) {
        .nil_ => value.nilValue(),
        .true_v => value.fromBool(true),
        .false_v => value.fromBool(false),
        .char_v => blk: {
            // Valid Unicode scalar, avoiding surrogates; fromChar
            // would return null otherwise.
            while (true) {
                const cp = rand.uintLessThan(u32, 0x11_0000);
                if (cp >= 0xD800 and cp <= 0xDFFF) continue;
                break :blk value.fromChar(@intCast(cp)).?;
            }
        },
        .fixnum_v => blk: {
            const n = rand.intRangeAtMost(i64, value.fixnum_min, value.fixnum_max);
            break :blk value.fromFixnum(n).?;
        },
        .float_v => blk: {
            // Sample over all f64 bit patterns — includes NaN,
            // subnormals, Inf, signed zero. fromFloat canonicalizes
            // NaN on the way in, so downstream invariants must hold
            // regardless of the raw input pattern.
            const bits = rand.int(u64);
            const f: f64 = @bitCast(bits);
            break :blk value.fromFloat(f);
        },
        .kw_v => value.fromKeywordId(rand.uintLessThan(u32, 32)),
        .sym_v => value.fromSymbolId(rand.uintLessThan(u32, 32)),
    };
}

test "P1: identical? is reflexive" {
    var prng = std.Random.DefaultPrng.init(prng_seed);
    const r = prng.random();
    var i: usize = 0;
    while (i < iterations_per_property) : (i += 1) {
        const v = randValue(r);
        try std.testing.expect(eq.identical(v, v));
    }
}

test "P2: = is reflexive, symmetric, (pairwise) transitive" {
    var prng = std.Random.DefaultPrng.init(prng_seed +% 1);
    const r = prng.random();
    var i: usize = 0;
    while (i < iterations_per_property) : (i += 1) {
        const a = randValue(r);
        const b = randValue(r);
        const c = randValue(r);

        // Reflexive.
        try std.testing.expect(eq.equal(a, a));
        // Symmetric.
        try std.testing.expectEqual(eq.equal(a, b), eq.equal(b, a));
        // Transitive — only interesting when both halves hold.
        if (eq.equal(a, b) and eq.equal(b, c)) {
            try std.testing.expect(eq.equal(a, c));
        }
    }
}

test "P3: identical? ⇒ =" {
    var prng = std.Random.DefaultPrng.init(prng_seed +% 2);
    const r = prng.random();
    var i: usize = 0;
    while (i < iterations_per_property) : (i += 1) {
        const a = randValue(r);
        const b = randValue(r);
        if (eq.identical(a, b)) {
            try std.testing.expect(eq.equal(a, b));
        }
    }
}

test "P4: = ⇒ hash equal — the bedrock" {
    var prng = std.Random.DefaultPrng.init(prng_seed +% 3);
    const r = prng.random();
    var i: usize = 0;
    while (i < iterations_per_property) : (i += 1) {
        const a = randValue(r);
        const b = randValue(r);
        if (eq.equal(a, b)) {
            try std.testing.expectEqual(a.hashValue(), b.hashValue());
        }
    }
}

test "P5: hash is a pure function of the Value bits (modulo the -0.0/+0.0 collapse)" {
    // Build two independent Values from the same discriminating state
    // and assert their hashes agree. This is `hash` determinism —
    // distinct from the P4 ⇒ direction.
    var prng = std.Random.DefaultPrng.init(prng_seed +% 4);
    const r = prng.random();
    var i: usize = 0;
    while (i < iterations_per_property) : (i += 1) {
        const a = randValue(r);
        // Reconstruct a value with the same discriminating state.
        const b = switch (a.kind()) {
            .nil => value.nilValue(),
            .true_ => value.fromBool(true),
            .false_ => value.fromBool(false),
            .char => value.fromChar(a.asChar()).?,
            .fixnum => value.fromFixnum(a.asFixnum()).?,
            .float => value.fromFloat(a.asFloat()),
            .keyword => value.fromKeywordId(a.asKeywordId()),
            .symbol => value.fromSymbolId(a.asSymbolId()),
            else => unreachable,
        };
        try std.testing.expectEqual(a.hashValue(), b.hashValue());
    }
}

test "P6: cross-kind = is false (except within {true_, false_} / {keyword×keyword} / etc.)" {
    var prng = std.Random.DefaultPrng.init(prng_seed +% 5);
    const r = prng.random();
    var i: usize = 0;
    while (i < iterations_per_property) : (i += 1) {
        const a = randValue(r);
        const b = randValue(r);
        if (a.kind() != b.kind() and eq.equal(a, b)) {
            // There are zero legitimate cross-kind equalities in v1.
            // (Cross-type numeric `==` is v2 work — PLAN §23 #11.)
            try std.testing.expect(false);
        }
    }
}

test "P7: NaN canonicalization — arbitrary NaN bits behave identically" {
    var prng = std.Random.DefaultPrng.init(prng_seed +% 6);
    const r = prng.random();
    const canonical = value.fromFloat(std.math.nan(f64));
    var i: usize = 0;
    while (i < iterations_per_property) : (i += 1) {
        // Force the high bits to produce a NaN bit pattern
        // (exponent = all ones, mantissa non-zero). We sample the
        // mantissa bits uniformly so both quiet and signaling NaNs
        // and every payload variant appear.
        const mantissa = r.int(u52) | 1; // ensure non-zero
        const sign: u64 = r.uintLessThan(u64, 2) << 63;
        const bits: u64 = sign | (@as(u64, 0x7FF) << 52) | @as(u64, mantissa);
        const v = value.fromFloat(@bitCast(bits));

        try std.testing.expect(eq.equal(v, canonical));
        try std.testing.expectEqual(v.hashValue(), canonical.hashValue());
        // And bit-level: all NaN inputs collapse to the canonical bit pattern.
        try std.testing.expectEqual(hash.canonical_nan_bits, v.payload);
    }
}
