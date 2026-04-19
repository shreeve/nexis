//! eq.zig — `identical?` and **immediate-only** `=` for the Value layer.
//!
//! This module is deliberately narrow: it implements the equivalence
//! relation on immediate kinds (nil, bool, char, fixnum, float, keyword,
//! symbol) plus the bit-identity fast path. Heap-kind equality lives in
//! `src/dispatch.zig` as `dispatch.equal(a, b)`, which is the canonical
//! full-Value entry point.
//!
//! The split is an architectural consequence (peer-AI review
//! conversation `nexis-phase-1` turns 3+5): putting the dispatcher in
//! this module would create a module-graph cycle that Zig's test
//! runner cannot resolve when any cycle member is used as a test-
//! binary root. Rather than hide the partial-ness behind a total-
//! looking API, the function name carries the contract: `equalImmediate`.
//! Symmetric to `Value.hashImmediate`.
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
//!   - `=` on `-0.0` and `+0.0` is **true** (IEEE numeric equality for
//!     zero — SEMANTICS §2.2), even though `identical?` is false.
//!   - Metadata never affects equality (PLAN §23 #12). Not exercised
//!     here — no metadata paths on immediates.
//!
//! Design note: `identical` and `equalImmediate` are both pure
//! functions of the two `Value` words. No allocator, no I/O, no
//! mutation.

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
/// signed zero). Use `dispatch.equal` if you want the `=` semantics.
pub inline fn identical(a: Value, b: Value) bool {
    return a.identicalTo(b);
}

// -----------------------------------------------------------------------------
// = (immediate-only)
// -----------------------------------------------------------------------------

/// Immediate-kind value equality per SEMANTICS §2. **Panics on heap
/// kinds** — callers that may hold a heap Value must go through
/// `dispatch.equal(a, b)`, which routes through the bit-identity fast
/// path, the cross-kind / cross-category rule, and the per-kind
/// structural comparators.
///
/// In debug builds, an early assert trips loudly with a clear message
/// rather than letting the unreachable arm at the bottom panic with a
/// less informative payload.
pub fn equalImmediate(a: Value, b: Value) bool {
    if (std.debug.runtime_safety) {
        if (a.kind().isHeap() or b.kind().isHeap()) {
            std.debug.panic(
                "eq.equalImmediate: called with heap kind {s} / {s} — use dispatch.equal instead",
                .{ @tagName(a.kind()), @tagName(b.kind()) },
            );
        }
    }

    // Fast path: bit-identical ⇒ equal for every immediate kind and
    // for canonical floats (including the single canonical-NaN bit
    // pattern). The one immediate case it MISSES is the `-0.0 == +0.0`
    // rule; those have distinct bit patterns and fall through to the
    // float arm below.
    if (a.tag == b.tag and a.payload == b.payload) return true;

    const ka = a.kind();
    const kb = b.kind();
    if (ka != kb) return false;

    return switch (ka) {
        .nil, .false_, .true_ => true, // singletons (already matched bit-id; kept for completeness)
        .char => a.asChar() == b.asChar(),
        .fixnum => a.asFixnum() == b.asFixnum(),
        .float => blk: {
            // Canonical NaN on both sides would have matched the fast
            // path. Here we land on either (a) two NaNs that differ in
            // bits (shouldn't happen post-canonicalization) or (b) the
            // signed-zero case. IEEE equality on `f64` folds signed-
            // zero to true and NaN to false; post-canonicalization we
            // never have a bit-distinct NaN pair, so the IEEE compare
            // is correct.
            const fa = a.asFloat();
            const fb = b.asFloat();
            if (std.debug.runtime_safety) {
                if (std.math.isNan(fa) and std.math.isNan(fb)) {
                    std.debug.panic(
                        "eq.equalImmediate: non-canonical NaN reached float arm",
                        .{},
                    );
                }
            }
            break :blk fa == fb;
        },
        .keyword => a.asKeywordId() == b.asKeywordId(),
        .symbol => a.asSymbolId() == b.asSymbolId(),
        .unbound, .undef => std.debug.panic(
            "eq.equalImmediate: runtime sentinel {s} escaped",
            .{@tagName(ka)},
        ),
        // Heap kinds are precluded by the entry assert; the dispatcher
        // owns them. This arm exists so the switch is total.
        else => std.debug.panic(
            "eq.equalImmediate: kind {s} is not an immediate — use dispatch.equal",
            .{@tagName(ka)},
        ),
    };
}

// -----------------------------------------------------------------------------
// Tests — immediates only. Cross-file property tests (eq↔hash consistency
// on randomized inputs) live in test/prop/primitive.zig.
// -----------------------------------------------------------------------------

test "identical and equal agree on simple immediates" {
    try std.testing.expect(identical(value.nilValue(), value.nilValue()));
    try std.testing.expect(equalImmediate(value.nilValue(), value.nilValue()));

    const t = value.fromBool(true);
    const f = value.fromBool(false);
    try std.testing.expect(identical(t, t));
    try std.testing.expect(equalImmediate(t, t));
    try std.testing.expect(!identical(t, f));
    try std.testing.expect(!equalImmediate(t, f));

    try std.testing.expect(!equalImmediate(t, value.nilValue())); // nil != false
}

test "fixnum and float are never equal (cross-type rule)" {
    const i = value.fromFixnum(1).?;
    const f = value.fromFloat(1.0);
    try std.testing.expect(!equalImmediate(i, f));
    try std.testing.expect(!equalImmediate(f, i));
}

test "canonical NaN is reflexive under =" {
    const nan1 = value.fromFloat(std.math.nan(f64));
    const nan2 = value.fromFloat(@bitCast(@as(u64, 0x7FFF_FFFF_FFFF_FFFF)));
    try std.testing.expect(identical(nan1, nan2)); // both canonicalized
    try std.testing.expect(equalImmediate(nan1, nan2));
}

test "-0.0 and +0.0: identical? distinguishes, = folds" {
    const pos = value.fromFloat(0.0);
    const neg = value.fromFloat(-0.0);
    try std.testing.expect(!identical(pos, neg)); // distinct bit patterns
    try std.testing.expect(equalImmediate(pos, neg)); // IEEE: 0.0 == -0.0
}

test "keyword / symbol with same id are NOT equal (different kinds)" {
    const kw = value.fromKeywordId(7);
    const sy = value.fromSymbolId(7);
    try std.testing.expect(!equalImmediate(kw, sy));
    try std.testing.expect(!identical(kw, sy));
}

test "keyword / symbol within-kind equality on intern ids" {
    try std.testing.expect(equalImmediate(value.fromKeywordId(7), value.fromKeywordId(7)));
    try std.testing.expect(!equalImmediate(value.fromKeywordId(7), value.fromKeywordId(8)));
    try std.testing.expect(equalImmediate(value.fromSymbolId(7), value.fromSymbolId(7)));
    try std.testing.expect(!equalImmediate(value.fromSymbolId(7), value.fromSymbolId(8)));
}

test "char equality" {
    const a = value.fromChar('a').?;
    const a2 = value.fromChar('a').?;
    const b = value.fromChar('b').?;
    try std.testing.expect(equalImmediate(a, a2));
    try std.testing.expect(!equalImmediate(a, b));
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

    for (samples) |s| {
        try std.testing.expect(equalImmediate(s, s));
    }

    for (samples) |a| {
        for (samples) |b| {
            try std.testing.expectEqual(equalImmediate(a, b), equalImmediate(b, a));
        }
    }

    for (samples) |a| {
        for (samples) |b| {
            if (!equalImmediate(a, b)) continue;
            for (samples) |c| {
                if (!equalImmediate(b, c)) continue;
                try std.testing.expect(equalImmediate(a, c));
            }
        }
    }
}

test "equal ⇒ hash equal (the bedrock invariant, immediates)" {
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
            if (equalImmediate(a, b)) {
                try std.testing.expectEqual(a.hashImmediate(), b.hashImmediate());
            }
        }
    }
}
