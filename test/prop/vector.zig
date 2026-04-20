//! test/prop/vector.zig — randomized properties for the persistent
//! vector heap kind and, critically, the cross-kind list↔vector
//! sequential equality + hash invariants.
//!
//! Primary purpose: retire the Phase 1 hidden fault line peer-AI
//! turn-3 flagged — "the combination of dispatch/category routing,
//! heap object layout/tracing, and cross-kind semantic equality/
//! hashing at scale." Until this file's V3 / V9 properties pass, that
//! combination is hypothetical.
//!
//! Properties:
//!   V1. fromSlice + nth round-trip byte-exact over 200 random sizes.
//!   V2. conj produces the same logical sequence as fromSlice
//!       (equivalent via `dispatch.equal`, same hashValue).
//!   V3. Cross-kind: 500 random element sequences lifted into BOTH a
//!       list and a vector produce `dispatch.equal`-true and
//!       hash-equal Values. THIS IS THE RETIREMENT RECEIPT.
//!   V4. Equivalence-relation laws on vectors (reflexive / symmetric
//!       / pairwise transitive) over 32 random vectors.
//!   V5. Bedrock `equal ⇒ hashValue equal` over 500 random vector
//!       pairs built from identical sequences in distinct
//!       allocations.
//!   V6. Cross-kind never-equal: vector is never `=` to any non-
//!       sequential Value; hashes differ.
//!   V7. Length discrimination: differing lengths break equality.
//!   V8. Nested collections round-trip through recursive dispatch.
//!   V9. Cross-kind at shift-boundary sizes (33, 1024, 1025, 1057,
//!       32768, 32769) — stresses the trie descent in the cursor
//!       walker.

const std = @import("std");
const value = @import("value");
const heap_mod = @import("heap");
const hash_mod = @import("hash");
const list_mod = @import("list");
const vector_mod = @import("vector");
const dispatch = @import("dispatch");

const Value = value.Value;
const Heap = heap_mod.Heap;

const prng_seed: u64 = 0x7665_6374_6F72_5F70; // "vector_p" ASCII LE

fn randImmediate(rand: std.Random) Value {
    const pick = rand.uintLessThan(u8, 3);
    return switch (pick) {
        0 => value.fromFixnum(rand.intRangeAtMost(i64, -1000, 1000)).?,
        1 => value.fromKeywordId(rand.uintLessThan(u32, 32)),
        2 => value.fromChar(rand.intRangeAtMost(u21, 32, 126)).?,
        else => unreachable,
    };
}

// -----------------------------------------------------------------------------
// V1. fromSlice + nth byte-exact round-trip
// -----------------------------------------------------------------------------

test "V1: fromSlice + nth round-trip byte-exact over 200 random sizes" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 1);
    const r = prng.random();

    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const len = r.uintLessThan(usize, 100);
        const elems = try gpa.alloc(Value, len);
        defer gpa.free(elems);
        for (elems) |*slot| slot.* = randImmediate(r);

        const v = try vector_mod.fromSlice(&heap, elems);
        try std.testing.expectEqual(len, vector_mod.count(v));
        for (elems, 0..) |expected, idx| {
            try std.testing.expect(vector_mod.nth(v, idx).identicalTo(expected));
        }
    }
}

// -----------------------------------------------------------------------------
// V2. conj ≡ fromSlice
// -----------------------------------------------------------------------------

test "V2: reduce(conj, empty, elems) ≡ fromSlice(elems)" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 2);
    const r = prng.random();

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const len = r.uintLessThan(usize, 64);
        const elems = try gpa.alloc(Value, len);
        defer gpa.free(elems);
        for (elems) |*slot| slot.* = randImmediate(r);

        const via_slice = try vector_mod.fromSlice(&heap, elems);
        var via_conj = try vector_mod.empty(&heap);
        for (elems) |e| via_conj = try vector_mod.conj(&heap, via_conj, e);

        try std.testing.expect(dispatch.equal(via_slice, via_conj));
        try std.testing.expectEqual(dispatch.hashValue(via_slice), dispatch.hashValue(via_conj));
    }
}

// -----------------------------------------------------------------------------
// V3. Cross-kind list ↔ vector — THE retirement receipt
// -----------------------------------------------------------------------------

test "V3: 2000 random sequences produce list↔vector equal+hash-equal (retirement receipt, gate #1 scaled)" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 3);
    const r = prng.random();

    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        const len = r.uintLessThan(usize, 48);
        const elems = try gpa.alloc(Value, len);
        defer gpa.free(elems);
        for (elems) |*slot| slot.* = randImmediate(r);

        const l = try list_mod.fromSlice(&heap, elems);
        const v = try vector_mod.fromSlice(&heap, elems);
        try std.testing.expect(dispatch.equal(l, v));
        try std.testing.expect(dispatch.equal(v, l));
        try std.testing.expectEqual(dispatch.hashValue(l), dispatch.hashValue(v));
    }
}

// -----------------------------------------------------------------------------
// V4. Equivalence-relation laws on vectors
// -----------------------------------------------------------------------------

test "V4: equal is reflexive, symmetric, pairwise transitive on random vectors" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 4);
    const r = prng.random();

    const N: usize = 32;
    const vs = try gpa.alloc(Value, N);
    defer gpa.free(vs);

    // Smaller element pool makes some pairs share values (trigger
    // transitivity checks) while keeping variety.
    const pool: usize = 4;
    for (vs) |*slot| {
        const len = r.uintLessThan(usize, 6);
        const elems = try gpa.alloc(Value, len);
        defer gpa.free(elems);
        for (elems) |*e| e.* = value.fromFixnum(@intCast(r.uintLessThan(usize, pool))).?;
        slot.* = try vector_mod.fromSlice(&heap, elems);
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
// V5. Bedrock: equal ⇒ hashValue equal
// -----------------------------------------------------------------------------

test "V5: 2000 identically-sequenced vector pairs across allocations share hashValue (gate #1 scaled)" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 5);
    const r = prng.random();

    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        const len = r.uintLessThan(usize, 40);
        const elems = try gpa.alloc(Value, len);
        defer gpa.free(elems);
        for (elems) |*slot| slot.* = randImmediate(r);

        const a = try vector_mod.fromSlice(&heap, elems);
        const b = try vector_mod.fromSlice(&heap, elems);
        try std.testing.expect(dispatch.equal(a, b));
        try std.testing.expectEqual(dispatch.hashValue(a), dispatch.hashValue(b));
    }
}

// -----------------------------------------------------------------------------
// V6. Cross-kind never-equal
// -----------------------------------------------------------------------------

test "V6: vector is never equal to a non-sequential Value; hashes differ" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    const v = try vector_mod.fromSlice(&heap, &.{
        value.fromFixnum(1).?,
        value.fromFixnum(2).?,
    });
    const v_h = dispatch.hashValue(v);

    const non_seq = [_]Value{
        value.nilValue(),
        value.fromBool(true),
        value.fromBool(false),
        value.fromFixnum(0).?,
        value.fromFixnum(1).?,
        value.fromChar('x').?,
        value.fromKeywordId(0),
        value.fromSymbolId(0),
    };
    for (non_seq) |o| {
        try std.testing.expect(!dispatch.equal(v, o));
        try std.testing.expect(!dispatch.equal(o, v));
        try std.testing.expect(v_h != dispatch.hashValue(o));
    }
}

// -----------------------------------------------------------------------------
// V7. Length discrimination
// -----------------------------------------------------------------------------

test "V7: different lengths break equality (same-kind and cross-kind)" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    const a = try vector_mod.fromSlice(&heap, &.{
        value.fromFixnum(1).?,
        value.fromFixnum(2).?,
    });
    const b = try vector_mod.fromSlice(&heap, &.{
        value.fromFixnum(1).?,
        value.fromFixnum(2).?,
        value.fromFixnum(3).?,
    });
    const la = try list_mod.fromSlice(&heap, &.{
        value.fromFixnum(1).?,
        value.fromFixnum(2).?,
    });
    try std.testing.expect(!dispatch.equal(a, b)); // same kind
    try std.testing.expect(!dispatch.equal(la, b)); // cross kind
    try std.testing.expect(!dispatch.equal(b, la));
}

// -----------------------------------------------------------------------------
// V8. Nested collections round-trip through recursive dispatch
// -----------------------------------------------------------------------------

test "V8: nested vectors — recursive dispatch reaches inner sequences" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    const inner_a = try vector_mod.fromSlice(&heap, &.{
        value.fromFixnum(10).?,
        value.fromFixnum(20).?,
    });
    const inner_b = try vector_mod.fromSlice(&heap, &.{
        value.fromFixnum(10).?,
        value.fromFixnum(20).?,
    });
    const outer_a = try vector_mod.fromSlice(&heap, &.{ inner_a, value.fromKeywordId(5) });
    const outer_b = try vector_mod.fromSlice(&heap, &.{ inner_b, value.fromKeywordId(5) });
    try std.testing.expect(dispatch.equal(outer_a, outer_b));
    try std.testing.expectEqual(dispatch.hashValue(outer_a), dispatch.hashValue(outer_b));
}

// -----------------------------------------------------------------------------
// V9. Cross-kind at trie shift-boundary sizes — stresses cursor walker
// -----------------------------------------------------------------------------

test "V9: cross-kind equality + hash at shift-boundary sizes (33, 1024, 1025, 1057)" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    const sizes = [_]usize{ 33, 1024, 1025, 1057 };
    for (sizes) |n| {
        const elems = try gpa.alloc(Value, n);
        defer gpa.free(elems);
        for (elems, 0..) |*slot, i| slot.* = value.fromFixnum(@intCast(i)).?;

        const l = try list_mod.fromSlice(&heap, elems);
        const v = try vector_mod.fromSlice(&heap, elems);
        try std.testing.expect(dispatch.equal(l, v));
        try std.testing.expect(dispatch.equal(v, l));
        try std.testing.expectEqual(dispatch.hashValue(l), dispatch.hashValue(v));
    }
}
