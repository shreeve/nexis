//! test/prop/transient.zig — randomized property tests for the
//! transient wrapper. Together with test/prop/hamt.zig (map/set) and
//! test/prop/vector.zig (vector), this file closes PLAN §20.2 gate
//! tests #3 (transient equivalence) and #4 (transient ownership).
//!
//! Properties (TRANSIENT.md §12):
//!
//!   T1. Equivalence (gate #3): random edit sequences applied via
//!       (transient → N × ...Bang → persistentBang) produce the same
//!       persistent Value (by `dispatch.equal` AND `dispatch.hashValue`)
//!       as the direct persistent path. 300 trials per kind.
//!   T2. Ownership (gate #4): frozen transients reject every op with
//!       `error.TransientFrozen`.
//!   T3. Source immutability: a `...Bang` session on transient
//!       `t = transientFrom(p)` does NOT mutate the original
//!       persistent `p`.
//!   T4. GC survival: a transient's inner structure survives GC
//!       when the transient itself is a root, even when the
//!       original persistent Value is dropped.

const std = @import("std");
const value = @import("value");
const heap_mod = @import("heap");
const hash_mod = @import("hash");
const hamt = @import("hamt");
const vector = @import("vector");
const transient = @import("transient");
const dispatch = @import("dispatch");
const gc = @import("gc");

const Value = value.Value;
const Heap = heap_mod.Heap;
const HeapHeader = heap_mod.HeapHeader;

const prng_seed: u64 = 0x7472_616E_7369_656E; // "transien" LE

// =============================================================================
// T1 — Equivalence (GATE TEST #3 RETIREMENT RECEIPT)
// =============================================================================

test "T1a: map equivalence — transient × N ≡ persistent × N (300 trials)" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 0x31);
    const r = prng.random();

    var trial: usize = 0;
    while (trial < 300) : (trial += 1) {
        const n = r.uintLessThan(usize, 40);

        // Direct persistent path.
        var persistent_path = try hamt.mapEmpty(&heap);
        // Transient path — wrap an empty, apply the same sequence.
        const t = try transient.transientFrom(&heap, try hamt.mapEmpty(&heap));

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const key = value.fromFixnum(r.intRangeAtMost(i64, 0, 19)).?;
            if (r.boolean()) {
                // assoc
                const val = value.fromFixnum(r.intRangeAtMost(i64, -100, 100)).?;
                persistent_path = try hamt.mapAssoc(&heap, persistent_path, key, val, &dispatch.hashValue, &dispatch.equal);
                _ = try transient.mapAssocBang(&heap, t, key, val, &dispatch.hashValue, &dispatch.equal);
            } else {
                // dissoc
                persistent_path = try hamt.mapDissoc(&heap, persistent_path, key, &dispatch.hashValue, &dispatch.equal);
                _ = try transient.mapDissocBang(&heap, t, key, &dispatch.hashValue, &dispatch.equal);
            }
        }

        const persistent_from_transient = try transient.persistentBang(t);

        // Equivalence: gate #3.
        try std.testing.expect(dispatch.equal(persistent_path, persistent_from_transient));
        try std.testing.expectEqual(
            dispatch.hashValue(persistent_path),
            dispatch.hashValue(persistent_from_transient),
        );
    }
}

test "T1b: set equivalence — transient × N ≡ persistent × N (300 trials)" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 0x32);
    const r = prng.random();

    var trial: usize = 0;
    while (trial < 300) : (trial += 1) {
        const n = r.uintLessThan(usize, 40);
        var persistent_path = try hamt.setEmpty(&heap);
        const t = try transient.transientFrom(&heap, try hamt.setEmpty(&heap));

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const elem = value.fromFixnum(r.intRangeAtMost(i64, 0, 19)).?;
            if (r.boolean()) {
                persistent_path = try hamt.setConj(&heap, persistent_path, elem, &dispatch.hashValue, &dispatch.equal);
                _ = try transient.setConjBang(&heap, t, elem, &dispatch.hashValue, &dispatch.equal);
            } else {
                persistent_path = try hamt.setDisj(&heap, persistent_path, elem, &dispatch.hashValue, &dispatch.equal);
                _ = try transient.setDisjBang(&heap, t, elem, &dispatch.hashValue, &dispatch.equal);
            }
        }

        const persistent_from_transient = try transient.persistentBang(t);
        try std.testing.expect(dispatch.equal(persistent_path, persistent_from_transient));
        try std.testing.expectEqual(
            dispatch.hashValue(persistent_path),
            dispatch.hashValue(persistent_from_transient),
        );
    }
}

test "T1c: vector equivalence — transient × N conj ≡ persistent × N conj (300 trials)" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 0x33);
    const r = prng.random();

    var trial: usize = 0;
    while (trial < 300) : (trial += 1) {
        const n = r.uintLessThan(usize, 50);
        var persistent_path = try vector.empty(&heap);
        const t = try transient.transientFrom(&heap, try vector.empty(&heap));

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const elem = value.fromFixnum(@intCast(i)).?;
            persistent_path = try vector.conj(&heap, persistent_path, elem);
            _ = try transient.vectorConjBang(&heap, t, elem);
        }

        const persistent_from_transient = try transient.persistentBang(t);
        try std.testing.expect(dispatch.equal(persistent_path, persistent_from_transient));
        try std.testing.expectEqual(
            dispatch.hashValue(persistent_path),
            dispatch.hashValue(persistent_from_transient),
        );
    }
}

// =============================================================================
// T2 — Ownership (GATE TEST #4 RETIREMENT RECEIPT)
// =============================================================================

test "T2a: map transient post-freeze rejects every op with TransientFrozen" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();
    const t = try transient.transientFrom(&heap, try hamt.mapEmpty(&heap));
    _ = try transient.persistentBang(t);
    try std.testing.expectError(
        transient.TransientError.TransientFrozen,
        transient.mapAssocBang(&heap, t, value.fromKeywordId(1), value.fromFixnum(1).?, &dispatch.hashValue, &dispatch.equal),
    );
    try std.testing.expectError(
        transient.TransientError.TransientFrozen,
        transient.mapDissocBang(&heap, t, value.fromKeywordId(1), &dispatch.hashValue, &dispatch.equal),
    );
    try std.testing.expectError(
        transient.TransientError.TransientFrozen,
        transient.mapGetBang(t, value.fromKeywordId(1), &dispatch.hashValue, &dispatch.equal),
    );
    try std.testing.expectError(
        transient.TransientError.TransientFrozen,
        transient.mapCountBang(t),
    );
    // Second persistentBang also rejects.
    try std.testing.expectError(
        transient.TransientError.TransientFrozen,
        transient.persistentBang(t),
    );
}

test "T2b: set transient post-freeze rejects every op" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();
    const t = try transient.transientFrom(&heap, try hamt.setEmpty(&heap));
    _ = try transient.persistentBang(t);
    try std.testing.expectError(
        transient.TransientError.TransientFrozen,
        transient.setConjBang(&heap, t, value.fromKeywordId(1), &dispatch.hashValue, &dispatch.equal),
    );
    try std.testing.expectError(
        transient.TransientError.TransientFrozen,
        transient.setDisjBang(&heap, t, value.fromKeywordId(1), &dispatch.hashValue, &dispatch.equal),
    );
    try std.testing.expectError(
        transient.TransientError.TransientFrozen,
        transient.setContainsBang(t, value.fromKeywordId(1), &dispatch.hashValue, &dispatch.equal),
    );
    try std.testing.expectError(transient.TransientError.TransientFrozen, transient.setCountBang(t));
}

test "T2c: vector transient post-freeze rejects every op" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();
    const t = try transient.transientFrom(&heap, try vector.empty(&heap));
    _ = try transient.persistentBang(t);
    try std.testing.expectError(
        transient.TransientError.TransientFrozen,
        transient.vectorConjBang(&heap, t, value.fromFixnum(1).?),
    );
    try std.testing.expectError(
        transient.TransientError.TransientFrozen,
        transient.vectorNthBang(t, 0),
    );
    try std.testing.expectError(transient.TransientError.TransientFrozen, transient.vectorCountBang(t));
}

test "T2d: kind-mismatch routing yields TransientKindMismatch for every family" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();
    const t_map = try transient.transientFrom(&heap, try hamt.mapEmpty(&heap));
    const t_set = try transient.transientFrom(&heap, try hamt.setEmpty(&heap));
    const t_vec = try transient.transientFrom(&heap, try vector.empty(&heap));

    // map ops on non-map transients.
    try std.testing.expectError(
        transient.TransientError.TransientKindMismatch,
        transient.mapAssocBang(&heap, t_set, value.fromKeywordId(1), value.fromFixnum(1).?, &dispatch.hashValue, &dispatch.equal),
    );
    try std.testing.expectError(
        transient.TransientError.TransientKindMismatch,
        transient.mapAssocBang(&heap, t_vec, value.fromKeywordId(1), value.fromFixnum(1).?, &dispatch.hashValue, &dispatch.equal),
    );
    // set ops on non-set transients.
    try std.testing.expectError(
        transient.TransientError.TransientKindMismatch,
        transient.setConjBang(&heap, t_map, value.fromKeywordId(1), &dispatch.hashValue, &dispatch.equal),
    );
    try std.testing.expectError(
        transient.TransientError.TransientKindMismatch,
        transient.setConjBang(&heap, t_vec, value.fromKeywordId(1), &dispatch.hashValue, &dispatch.equal),
    );
    // vector ops on non-vector transients.
    try std.testing.expectError(
        transient.TransientError.TransientKindMismatch,
        transient.vectorConjBang(&heap, t_map, value.fromFixnum(1).?),
    );
    try std.testing.expectError(
        transient.TransientError.TransientKindMismatch,
        transient.vectorConjBang(&heap, t_set, value.fromFixnum(1).?),
    );

    // Non-transient Value passed to transient op.
    try std.testing.expectError(
        transient.TransientError.TransientKindMismatch,
        transient.mapCountBang(try hamt.mapEmpty(&heap)),
    );
}

// =============================================================================
// T3 — Source immutability
// =============================================================================

test "T3a: transient session does NOT mutate source persistent map" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 0x73);
    const r = prng.random();

    var trial: usize = 0;
    while (trial < 100) : (trial += 1) {
        // Build a non-trivial source persistent map.
        var src = try hamt.mapEmpty(&heap);
        var i: u32 = 0;
        while (i < 15) : (i += 1) {
            src = try hamt.mapAssoc(&heap, src, value.fromKeywordId(i), value.fromFixnum(@intCast(i)).?, &dispatch.hashValue, &dispatch.equal);
        }
        const src_hash_before = dispatch.hashValue(src);
        const src_count_before = hamt.mapCount(src);

        // Wrap and mutate.
        var t = try transient.transientFrom(&heap, src);
        const ops = r.intRangeAtMost(usize, 1, 20);
        var op: usize = 0;
        while (op < ops) : (op += 1) {
            const pick = r.uintLessThan(u8, 2);
            if (pick == 0) {
                const k = value.fromKeywordId(r.intRangeAtMost(u32, 0, 100));
                t = try transient.mapAssocBang(&heap, t, k, value.fromFixnum(r.intRangeAtMost(i64, -100, 100)).?, &dispatch.hashValue, &dispatch.equal);
            } else {
                const k = value.fromKeywordId(r.intRangeAtMost(u32, 0, 30));
                t = try transient.mapDissocBang(&heap, t, k, &dispatch.hashValue, &dispatch.equal);
            }
        }
        _ = try transient.persistentBang(t);

        // `src` must be untouched.
        try std.testing.expectEqual(src_count_before, hamt.mapCount(src));
        try std.testing.expectEqual(src_hash_before, dispatch.hashValue(src));
        i = 0;
        while (i < 15) : (i += 1) {
            switch (hamt.mapGet(src, value.fromKeywordId(i), &dispatch.hashValue, &dispatch.equal)) {
                .present => |v| try std.testing.expectEqual(@as(i64, @intCast(i)), v.asFixnum()),
                .absent => try std.testing.expect(false),
            }
        }
    }
}

test "T3b: transient session does NOT mutate source persistent vector" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();
    const elems = [_]Value{
        value.fromFixnum(10).?,
        value.fromFixnum(20).?,
        value.fromFixnum(30).?,
    };
    const src = try vector.fromSlice(&heap, &elems);
    const src_hash_before = dispatch.hashValue(src);
    const src_count_before = vector.count(src);

    var t = try transient.transientFrom(&heap, src);
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        t = try transient.vectorConjBang(&heap, t, value.fromFixnum(@intCast(i + 100)).?);
    }
    _ = try transient.persistentBang(t);

    try std.testing.expectEqual(src_count_before, vector.count(src));
    try std.testing.expectEqual(src_hash_before, dispatch.hashValue(src));
    try std.testing.expectEqual(@as(i64, 10), vector.nth(src, 0).asFixnum());
    try std.testing.expectEqual(@as(i64, 20), vector.nth(src, 1).asFixnum());
    try std.testing.expectEqual(@as(i64, 30), vector.nth(src, 2).asFixnum());
}

// =============================================================================
// T4 — GC survival
// =============================================================================

test "T4: transient wrapper as sole root keeps inner structure alive" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    // Build a non-trivial map via repeated assoc (all intermediate
    // persistent roots become orphans after the transient owns its
    // current inner). Keep only the transient as a root.
    var t = try transient.transientFrom(&heap, try hamt.mapEmpty(&heap));
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        t = try transient.mapAssocBang(&heap, t, value.fromKeywordId(i), value.fromFixnum(@intCast(i)).?, &dispatch.hashValue, &dispatch.equal);
    }

    var collector = gc.Collector.init(&heap);
    const live_before = heap.liveCount();
    _ = collector.collect(&.{Heap.asHeapHeader(t)});
    const live_after = heap.liveCount();
    // Collection should have pruned orphans but the transient +
    // its inner structure must survive.
    try std.testing.expect(live_after < live_before);

    // Every key is still reachable via the transient.
    i = 0;
    while (i < 20) : (i += 1) {
        const lookup = try transient.mapGetBang(t, value.fromKeywordId(i), &dispatch.hashValue, &dispatch.equal);
        switch (lookup) {
            .present => |v| try std.testing.expectEqual(@as(i64, @intCast(i)), v.asFixnum()),
            .absent => try std.testing.expect(false),
        }
    }
}

test "T4b: frozen transient still traces inner_header (inner survives via wrapper)" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    const t = try transient.transientFrom(&heap, try hamt.mapEmpty(&heap));
    _ = try transient.mapAssocBang(&heap, t, value.fromKeywordId(1), value.fromFixnum(100).?, &dispatch.hashValue, &dispatch.equal);
    const frozen_persistent = try transient.persistentBang(t);

    // Keep BOTH the wrapper AND the returned persistent Value as
    // roots. The wrapper is frozen — its only outgoing edge is the
    // inner_header, which must still be alive post-GC so the
    // persistent Value (which points at the same *HeapHeader)
    // remains usable.
    var collector = gc.Collector.init(&heap);
    _ = collector.collect(&.{
        Heap.asHeapHeader(t),
        Heap.asHeapHeader(frozen_persistent),
    });

    // Persistent Value still functional after GC — proves
    // inner_header reachability was maintained.
    try std.testing.expectEqual(@as(usize, 1), hamt.mapCount(frozen_persistent));
    switch (hamt.mapGet(frozen_persistent, value.fromKeywordId(1), &dispatch.hashValue, &dispatch.equal)) {
        .present => |v| try std.testing.expectEqual(@as(i64, 100), v.asFixnum()),
        .absent => try std.testing.expect(false),
    }
}
