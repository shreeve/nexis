//! eq.zig — `identical?` and `=` for the Value layer.
//!
//! Phase 1 commit 1 scope: immediates only. Heap-kind equality plugs in
//! kind-by-kind as those modules land, via the `heapEq` hook (`@panic`
//! placeholder until then).
//!
//! Authoritative spec: `docs/SEMANTICS.md` §2. Non-negotiable invariants:
//!
//!   - `identical?` is bit-equality on the 16-byte `Value` struct.
//!   - `(identical? x y) ⇒ (= x y)`.
//!   - `(= x y) ⇒ (hash x) = (hash y)` (cross-file obligation — tested
//!     by the randomized prop suite in `test/prop/primitive.zig`).
//!   - `=` is cross-type **false** between disjoint numeric kinds
//!     (PLAN §23 #11: `(= 1 1.0)` is `false`). No implicit coercion.
//!   - `=` on canonical NaN is **true** (reflexive — SEMANTICS §2.2).
//!   - `=` on `-0.0` and `+0.0` is **true** (IEEE numeric equality
//!     for zero — SEMANTICS §2.2), even though `identical?` is false.
//!   - Metadata never affects equality (PLAN §23 #12). Not exercised
//!     here — no metadata paths on immediates.
//!
//! Design note: both `identical?` and `=` are pure functions of the two
//! `Value` words, no allocator argument. Heap-kind extension will add a
//! context parameter once hash caching / interning state is needed.

const std = @import("std");
const value = @import("value");
const Value = value.Value;
const Kind = value.Kind;

// -----------------------------------------------------------------------------
// identical?
// -----------------------------------------------------------------------------

/// Pointer / bit identity. For immediates: bit-equality on the whole
/// 16-byte struct. For heap kinds: same `HeapHeader*` in the payload
/// (also subsumed by bit equality). Never performs a structural walk.
///
/// `(identical? 0.0 -0.0)` is `false` here — their bit patterns differ
/// even after `canonicalizeFloat` (which intentionally does not collapse
/// signed zero). Use `equal` if you want the `=` semantics instead.
pub inline fn identical(a: Value, b: Value) bool {
    return a.identicalTo(b);
}

// -----------------------------------------------------------------------------
// =
// -----------------------------------------------------------------------------

/// Value equality per SEMANTICS §2. Pure function; no allocation, no
/// I/O, no mutation. Heap-kind extension lives in `heapEq` below.
pub fn equal(a: Value, b: Value) bool {
    // Fast path: bit-identical ⇒ equal. Catches most immediate-immediate
    // comparisons without looking at kinds twice.
    //
    // IMPORTANT: this fast path is correct for `nil`, `bool`, `char`,
    // `fixnum`, `keyword`, `symbol`, and CANONICAL floats (including
    // the single canonical-NaN bit pattern). The only immediate case it
    // MISSES is the `-0.0 == +0.0` rule — those have distinct bit
    // patterns and fall through to the kind-dispatched tail below.
    if (a.tag == b.tag and a.payload == b.payload) return true;

    const ka = a.kind();
    const kb = b.kind();

    // Cross-kind rule. The one wrinkle is the signed-zero case inside
    // `float`: `pos.tag == neg.tag` (same kind), but payloads differ —
    // handled by the float branch below.
    if (ka != kb) return false;

    return switch (ka) {
        .nil, .false_, .true_ => true, // singletons — handled by the fast path above, but kept for completeness.
        .char => a.asChar() == b.asChar(),
        .fixnum => a.asFixnum() == b.asFixnum(),
        .float => blk: {
            // Canonical NaN on both sides: fast path matched. Here we
            // land on either (a) two NaNs that somehow differ in bits
            // (shouldn't happen post-canonicalization — assert in Debug)
            // or (b) the signed-zero case. IEEE equality on `f64` folds
            // signed-zero to true and NaN to false; since post-
            // canonicalization we never have a bit-distinct NaN pair,
            // the IEEE comparison gives the right answer.
            const fa = a.asFloat();
            const fb = b.asFloat();
            if (std.debug.runtime_safety) {
                if (std.math.isNan(fa) and std.math.isNan(fb)) {
                    // Two canonical NaNs would have matched the fast path; if
                    // we're here with both NaN, someone bypassed the
                    // canonical constructor.
                    std.debug.panic("eq: non-canonical NaN reached equal()", .{});
                }
            }
            break :blk fa == fb;
        },
        .keyword => a.asKeywordId() == b.asKeywordId(),
        .symbol => a.asSymbolId() == b.asSymbolId(),
        // Heap kinds hand off.
        .string, .bignum, .persistent_map, .persistent_set, .persistent_vector, .list, .byte_vector, .typed_vector, .function, .var_, .durable_ref, .transient, .error_, .meta_symbol => heapEq(a, b),
        .unbound, .undef => {
            std.debug.panic("eq: runtime sentinel escaped to equal(): {s}", .{@tagName(ka)});
        },
        _ => {
            std.debug.panic("eq: unknown kind {d}", .{@intFromEnum(ka)});
        },
    };
}

/// Per-kind heap equality. Each heap module registers here as it lands.
/// Until then, any heap value hitting `equal` is a Phase 1 scoping bug
/// — constructing a heap Value requires the heap module to exist.
fn heapEq(_: Value, _: Value) bool {
    @panic("eq.heapEq: heap kind equality not implemented in this commit — wire up when the kind's module lands");
}

// -----------------------------------------------------------------------------
// Tests — immediates only. Cross-file property tests (eq↔hash consistency
// on randomized inputs) live in test/prop/primitive.zig.
// -----------------------------------------------------------------------------

test "identical and equal agree on simple immediates" {
    try std.testing.expect(identical(value.nilValue(), value.nilValue()));
    try std.testing.expect(equal(value.nilValue(), value.nilValue()));

    const t = value.fromBool(true);
    const f = value.fromBool(false);
    try std.testing.expect(identical(t, t));
    try std.testing.expect(equal(t, t));
    try std.testing.expect(!identical(t, f));
    try std.testing.expect(!equal(t, f));

    try std.testing.expect(!equal(t, value.nilValue())); // nil != false
}

test "fixnum and float are never equal (cross-type rule)" {
    const i = value.fromFixnum(1).?;
    const f = value.fromFloat(1.0);
    try std.testing.expect(!equal(i, f));
    try std.testing.expect(!equal(f, i));
}

test "canonical NaN is reflexive under =" {
    const nan1 = value.fromFloat(std.math.nan(f64));
    const nan2 = value.fromFloat(@bitCast(@as(u64, 0x7FFF_FFFF_FFFF_FFFF)));
    try std.testing.expect(identical(nan1, nan2)); // both canonicalized
    try std.testing.expect(equal(nan1, nan2));
}

test "-0.0 and +0.0: identical? distinguishes, = folds" {
    const pos = value.fromFloat(0.0);
    const neg = value.fromFloat(-0.0);
    try std.testing.expect(!identical(pos, neg)); // distinct bit patterns
    try std.testing.expect(equal(pos, neg)); // IEEE: 0.0 == -0.0
}

test "keyword / symbol with same id are NOT equal (different kinds)" {
    const kw = value.fromKeywordId(7);
    const sy = value.fromSymbolId(7);
    try std.testing.expect(!equal(kw, sy));
    try std.testing.expect(!identical(kw, sy));
}

test "keyword / symbol within-kind equality on intern ids" {
    try std.testing.expect(equal(value.fromKeywordId(7), value.fromKeywordId(7)));
    try std.testing.expect(!equal(value.fromKeywordId(7), value.fromKeywordId(8)));
    try std.testing.expect(equal(value.fromSymbolId(7), value.fromSymbolId(7)));
    try std.testing.expect(!equal(value.fromSymbolId(7), value.fromSymbolId(8)));
}

test "char equality" {
    const a = value.fromChar('a').?;
    const a2 = value.fromChar('a').?;
    const b = value.fromChar('b').?;
    try std.testing.expect(equal(a, a2));
    try std.testing.expect(!equal(a, b));
}

test "equivalence-relation laws on immediates" {
    // Pick a cross-kind mix; exercise reflexivity, symmetry, transitivity
    // explicitly for every pair. This is a pinned unit test; the
    // randomized sweep lives in the prop suite.
    const samples = [_]Value{
        value.nilValue(),
        value.fromBool(true),
        value.fromBool(false),
        value.fromChar('a').?,
        value.fromChar('b').?,
        value.fromFixnum(0).?,
        value.fromFixnum(1).?,
        value.fromFixnum(-1).?,
        value.fromFloat(0.0),
        value.fromFloat(-0.0),
        value.fromFloat(1.0),
        value.fromFloat(std.math.nan(f64)),
        value.fromKeywordId(1),
        value.fromKeywordId(2),
        value.fromSymbolId(1),
        value.fromSymbolId(2),
    };

    // Reflexivity.
    for (samples) |s| {
        try std.testing.expect(equal(s, s));
    }

    // Symmetry.
    for (samples) |a| {
        for (samples) |b| {
            try std.testing.expectEqual(equal(a, b), equal(b, a));
        }
    }

    // Transitivity — when (= a b) and (= b c) then (= a c).
    for (samples) |a| {
        for (samples) |b| {
            if (!equal(a, b)) continue;
            for (samples) |c| {
                if (!equal(b, c)) continue;
                try std.testing.expect(equal(a, c));
            }
        }
    }
}

test "equal ⇒ hash equal (the bedrock invariant)" {
    const samples = [_]Value{
        value.nilValue(),
        value.fromBool(true),
        value.fromBool(false),
        value.fromChar('a').?,
        value.fromFixnum(0).?,
        value.fromFixnum(-1).?,
        value.fromFloat(0.0),
        value.fromFloat(-0.0),
        value.fromFloat(1.5),
        value.fromFloat(std.math.nan(f64)),
        value.fromKeywordId(1),
        value.fromSymbolId(1),
    };
    for (samples) |a| {
        for (samples) |b| {
            if (equal(a, b)) {
                try std.testing.expectEqual(a.hashValue(), b.hashValue());
            }
        }
    }
}
