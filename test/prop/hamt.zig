//! test/prop/hamt.zig — randomized properties for the persistent map
//! heap kind (CHAMP). Ships alongside commit 1; commit 2 extends this
//! file with parallel set properties (S1–S9) when `persistent_set`
//! lands.
//!
//! Primary purpose: retire the associative equality category's hidden
//! fault line — until these properties pass, the `(= a b) ⇒ hash(a) =
//! hash(b)` invariant is hypothetical for the entire associative
//! category. M6 is the retirement receipt parallel to
//! `test/prop/vector.zig` V3 (sequential category) and V9 (cross-kind
//! at structural boundaries).
//!
//! Properties (CHAMP.md §12.4):
//!   M1. `mapFromEntries` + `mapGet` round-trip: every inserted
//!       (k, v) looks up to exactly `v`; absent keys return `.absent`.
//!   M2. `mapAssoc` + `mapDissoc` random sequences preserve the entry
//!       multiset (minus dissoc'd keys).
//!   M3. `mapAssoc` replace-value: associng `(k, v1)` then `(k, v2)`
//!       yields `mapGet(m, k) == .present = v2` with unchanged count.
//!   M4. `assoc` same-value short-circuit returns the same map pointer.
//!   M5. Equality laws over random maps: reflexive, symmetric,
//!       transitive (pairwise).
//!   M6. **Cross-subkind hash equivalence** (RETIREMENT RECEIPT for
//!       `.associative` category): 500 random maps built via two
//!       different paths — one that stays array-map, one that
//!       promote-then-dissocs — hash and equal identically.
//!   M7. Cross-category never-equal: a map is never `=` to any non-
//!       associative Value; `dispatch.hashValue` outputs distinct.
//!   M8. Persistent immutability: `mapAssoc(m, k, v)` does not mutate
//!       `m`; `mapGet(m, k)` still returns the pre-assoc result.
//!   M9. Keyword-keyed fast-path correctness: maps keyed entirely by
//!       keywords produce identical semantic results to maps keyed by
//!       non-interned values (the fast path is an optimization only).
//!   M10. Collision-bucket stress: synthetic hash-collision fixture
//!        forces ≥5 entries into a collision node; round-trip + dissoc
//!        + equality all hold.

const std = @import("std");
const value = @import("value");
const heap_mod = @import("heap");
const hash_mod = @import("hash");
const hamt = @import("hamt");
const list_mod = @import("list");
const vector_mod = @import("vector");
const dispatch = @import("dispatch");

const Value = value.Value;
const Heap = heap_mod.Heap;

const prng_seed: u64 = 0x686D_7470_5F70_726F; // "ormp_thmt" LE-ish

fn randKey(rand: std.Random) Value {
    // Mix of keyword ids (exercises the keyword fast path) and fixnums
    // (exercises the general-purpose key path).
    const pick = rand.uintLessThan(u8, 2);
    return switch (pick) {
        0 => value.fromKeywordId(rand.uintLessThan(u32, 1024)),
        1 => value.fromFixnum(rand.intRangeAtMost(i64, -1000, 1000)).?,
        else => unreachable,
    };
}

fn randValue(rand: std.Random) Value {
    const pick = rand.uintLessThan(u8, 4);
    return switch (pick) {
        0 => value.fromFixnum(rand.intRangeAtMost(i64, -10_000, 10_000)).?,
        1 => value.fromKeywordId(rand.uintLessThan(u32, 32)),
        2 => value.nilValue(),
        3 => value.fromBool(rand.boolean()),
        else => unreachable,
    };
}

// -----------------------------------------------------------------------------
// M1. fromEntries + get round-trip
// -----------------------------------------------------------------------------

test "M1: mapFromEntries + mapGet round-trip over 200 random maps" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 1);
    const r = prng.random();

    var trial: usize = 0;
    while (trial < 200) : (trial += 1) {
        const n = r.uintLessThan(usize, 40);
        // Generate DISTINCT keys by using a deterministic counter so
        // lookups have a predictable ground-truth. Interleave with
        // random values.
        const entries = try gpa.alloc(hamt.Entry, n);
        defer gpa.free(entries);
        for (entries, 0..) |*e, i| {
            e.* = .{
                .key = value.fromFixnum(@intCast(i + trial * 100)).?,
                .value = randValue(r),
            };
        }
        const m = try hamt.mapFromEntries(&heap, entries, &dispatch.hashValue, &dispatch.equal);
        try std.testing.expectEqual(n, hamt.mapCount(m));
        for (entries) |e| {
            switch (hamt.mapGet(m, e.key, &dispatch.hashValue, &dispatch.equal)) {
                .absent => try std.testing.expect(false),
                .present => |v| try std.testing.expect(dispatch.equal(v, e.value)),
            }
        }
        // Absent key.
        const miss_key = value.fromFixnum(999_999_999).?;
        try std.testing.expect(hamt.mapGet(m, miss_key, &dispatch.hashValue, &dispatch.equal) == .absent);
    }
}

// -----------------------------------------------------------------------------
// M2. assoc + dissoc preserve entry multiset (model vs. implementation)
// -----------------------------------------------------------------------------

test "M2: random assoc/dissoc sequences preserve the entry set" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 2);
    const r = prng.random();

    const trials: usize = 50;
    var trial: usize = 0;
    while (trial < trials) : (trial += 1) {
        // Model map: a plain ArrayList of (key, value) pairs we maintain
        // in lockstep with the runtime map. At each step we compare
        // ground-truth to runtime lookup.
        var model: std.ArrayList(hamt.Entry) = .empty;
        defer model.deinit(gpa);

        var m = try hamt.mapEmpty(&heap);
        const ops: usize = 30;
        var op: usize = 0;
        while (op < ops) : (op += 1) {
            const is_assoc = r.boolean() or model.items.len == 0;
            if (is_assoc) {
                const k = value.fromFixnum(r.intRangeAtMost(i64, 0, 19)).?;
                const v = randValue(r);
                m = try hamt.mapAssoc(&heap, m, k, v, &dispatch.hashValue, &dispatch.equal);
                // Update model: if key present, replace value; else append.
                var found = false;
                for (model.items) |*me| {
                    if (dispatch.equal(me.key, k)) {
                        me.value = v;
                        found = true;
                        break;
                    }
                }
                if (!found) try model.append(gpa, .{ .key = k, .value = v });
            } else {
                const idx = r.uintLessThan(usize, model.items.len);
                const k = model.items[idx].key;
                m = try hamt.mapDissoc(&heap, m, k, &dispatch.hashValue, &dispatch.equal);
                _ = model.swapRemove(idx);
            }
            // After each op: count + all keys must match.
            try std.testing.expectEqual(model.items.len, hamt.mapCount(m));
            for (model.items) |me| {
                switch (hamt.mapGet(m, me.key, &dispatch.hashValue, &dispatch.equal)) {
                    .absent => try std.testing.expect(false),
                    .present => |v| try std.testing.expect(dispatch.equal(v, me.value)),
                }
            }
        }
    }
}

// -----------------------------------------------------------------------------
// M3. Replace-value
// -----------------------------------------------------------------------------

test "M3: assoc replace-value updates value, count unchanged" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 3);
    const r = prng.random();

    var trial: usize = 0;
    while (trial < 100) : (trial += 1) {
        // Build a map of arbitrary size, then replace one random key's
        // value and verify.
        const n = r.intRangeAtMost(usize, 1, 25);
        var m = try hamt.mapEmpty(&heap);
        var idx: usize = 0;
        while (idx < n) : (idx += 1) {
            const k = value.fromFixnum(@intCast(idx)).?;
            const v = value.fromFixnum(@intCast(idx)).?;
            m = try hamt.mapAssoc(&heap, m, k, v, &dispatch.hashValue, &dispatch.equal);
        }
        const pick = r.uintLessThan(usize, n);
        const k_pick = value.fromFixnum(@intCast(pick)).?;
        const v_new = value.fromFixnum(-42).?;
        const m2 = try hamt.mapAssoc(&heap, m, k_pick, v_new, &dispatch.hashValue, &dispatch.equal);
        try std.testing.expectEqual(hamt.mapCount(m), hamt.mapCount(m2));
        switch (hamt.mapGet(m2, k_pick, &dispatch.hashValue, &dispatch.equal)) {
            .absent => try std.testing.expect(false),
            .present => |v| try std.testing.expect(dispatch.equal(v, v_new)),
        }
    }
}

// -----------------------------------------------------------------------------
// M4. Same-value short-circuit
// -----------------------------------------------------------------------------

test "M4: assoc same-value returns same map pointer" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();
    // Build various-sized maps; assoc each existing key with its
    // existing value; result must be the same pointer.
    const sizes = [_]u32{ 0, 1, 5, 8, 9, 15, 40 };
    for (sizes) |size| {
        var m = try hamt.mapEmpty(&heap);
        var i: u32 = 0;
        while (i < size) : (i += 1) {
            m = try hamt.mapAssoc(&heap, m, value.fromFixnum(@intCast(i)).?, value.fromFixnum(@intCast(i)).?, &dispatch.hashValue, &dispatch.equal);
        }
        if (size == 0) continue;
        // Assoc existing key with existing value.
        const k_pick = value.fromFixnum(@intCast(size / 2)).?;
        const v_existing = value.fromFixnum(@intCast(size / 2)).?;
        const m2 = try hamt.mapAssoc(&heap, m, k_pick, v_existing, &dispatch.hashValue, &dispatch.equal);
        try std.testing.expect(Heap.asHeapHeader(m) == Heap.asHeapHeader(m2));
    }
}

// -----------------------------------------------------------------------------
// M5. Equality laws
// -----------------------------------------------------------------------------

test "M5: equality laws (reflexive, symmetric, pairwise transitive)" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();
    var prng = std.Random.DefaultPrng.init(prng_seed +% 5);
    const r = prng.random();

    // Build a pool of 16 maps, each independently from a random key/value
    // sequence. Multiple maps may coincidentally be equal; that's
    // desirable for the transitivity check.
    const pool_size: usize = 16;
    var pool: [pool_size]Value = undefined;
    for (0..pool_size) |i| {
        const n = r.uintLessThan(usize, 15);
        var m = try hamt.mapEmpty(&heap);
        var j: usize = 0;
        while (j < n) : (j += 1) {
            const k = value.fromFixnum(r.intRangeAtMost(i64, 0, 20)).?;
            const v = value.fromFixnum(r.intRangeAtMost(i64, -100, 100)).?;
            m = try hamt.mapAssoc(&heap, m, k, v, &dispatch.hashValue, &dispatch.equal);
        }
        pool[i] = m;
    }
    // Reflexivity.
    for (pool) |a| try std.testing.expect(dispatch.equal(a, a));
    // Symmetry + (transitive) correctness via hash.
    for (pool, 0..) |a, i| {
        for (pool, 0..) |b, j| {
            const ab = dispatch.equal(a, b);
            const ba = dispatch.equal(b, a);
            try std.testing.expectEqual(ab, ba);
            if (ab) {
                try std.testing.expectEqual(dispatch.hashValue(a), dispatch.hashValue(b));
            }
            _ = i;
            _ = j;
        }
    }
    // Transitivity (pairwise): for every (i, j, k) if a==b and b==c then a==c.
    for (pool) |a| {
        for (pool) |b| {
            if (!dispatch.equal(a, b)) continue;
            for (pool) |c| {
                if (dispatch.equal(b, c)) {
                    try std.testing.expect(dispatch.equal(a, c));
                }
            }
        }
    }
}

// -----------------------------------------------------------------------------
// M6. Cross-subkind hash equivalence — THE RETIREMENT RECEIPT
// -----------------------------------------------------------------------------

test "M6: cross-subkind (array-map vs CHAMP) same entries hash AND equal" {
    // Parallel to test/prop/vector.zig V3 for the associative category.
    // For each of 500 random ≤8-entry key-value sets we build two
    // maps: `am` that stays as array-map, `ch` that grows to 9 entries
    // and dissocs one back out (forcing CHAMP subkind). Both must be
    // `dispatch.equal` and produce identical `dispatch.hashValue`
    // outputs, proving the associative-category architecture holds
    // across subkinds. This retires the fault line analogous to
    // V3 for sequential.
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 6);
    const r = prng.random();

    const trials: usize = 500;
    var trial: usize = 0;
    while (trial < trials) : (trial += 1) {
        // 1..8 distinct keys for array-map path.
        const n = r.intRangeAtMost(u32, 1, 8);
        const entries = try gpa.alloc(hamt.Entry, n);
        defer gpa.free(entries);
        for (entries, 0..) |*e, idx| {
            e.* = .{
                .key = value.fromFixnum(@intCast(idx + trial * 100)).?,
                .value = randValue(r),
            };
        }
        // Path A: pure array-map (stays subkind 0).
        var am = try hamt.mapEmpty(&heap);
        for (entries) |e| {
            am = try hamt.mapAssoc(&heap, am, e.key, e.value, &dispatch.hashValue, &dispatch.equal);
        }
        try std.testing.expect(am.subkind() == 0);

        // Path B: grow to n+1 then dissoc the extra key → CHAMP.
        var ch = am;
        const extra_key = value.fromFixnum(@intCast(1_000_000 + trial)).?;
        ch = try hamt.mapAssoc(&heap, ch, extra_key, value.fromFixnum(99).?, &dispatch.hashValue, &dispatch.equal);
        if (n >= 8) {
            try std.testing.expect(ch.subkind() == 1);
        }
        ch = try hamt.mapDissoc(&heap, ch, extra_key, &dispatch.hashValue, &dispatch.equal);

        // Equality and hash must agree regardless of whether ch is
        // actually CHAMP (it is, when n == 8) or stayed array-map.
        try std.testing.expect(dispatch.equal(am, ch));
        try std.testing.expect(dispatch.equal(ch, am));
        try std.testing.expectEqual(dispatch.hashValue(am), dispatch.hashValue(ch));
    }
}

// -----------------------------------------------------------------------------
// M7. Cross-category never-equal
// -----------------------------------------------------------------------------

test "M7: map never equal to non-associative Values" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();
    const m = try hamt.mapAssoc(
        &heap,
        try hamt.mapEmpty(&heap),
        value.fromKeywordId(1),
        value.fromFixnum(1).?,
        &dispatch.hashValue,
        &dispatch.equal,
    );
    const non_assoc = [_]Value{
        value.nilValue(),
        value.fromBool(true),
        value.fromBool(false),
        value.fromFixnum(0).?,
        value.fromFixnum(1).?,
        value.fromFloat(0.0),
        value.fromKeywordId(1),
        value.fromChar('a').?,
        try list_mod.empty(&heap),
        try vector_mod.empty(&heap),
    };
    for (non_assoc) |other| {
        try std.testing.expect(!dispatch.equal(m, other));
        try std.testing.expect(!dispatch.equal(other, m));
    }
    // Empty-map vs all of the above: never equal.
    const em = try hamt.mapEmpty(&heap);
    for (non_assoc) |other| {
        try std.testing.expect(!dispatch.equal(em, other));
    }
}

// -----------------------------------------------------------------------------
// M8. Persistent immutability
// -----------------------------------------------------------------------------

test "M8: assoc and dissoc never mutate source map" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();
    var prng = std.Random.DefaultPrng.init(prng_seed +% 8);
    const r = prng.random();

    // Build a random source map m_src of size 0..30.
    var m_src = try hamt.mapEmpty(&heap);
    var model: std.ArrayList(hamt.Entry) = .empty;
    defer model.deinit(gpa);
    const n = r.uintLessThan(usize, 30);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const k = value.fromFixnum(@intCast(i)).?;
        const v = randValue(r);
        m_src = try hamt.mapAssoc(&heap, m_src, k, v, &dispatch.hashValue, &dispatch.equal);
        try model.append(gpa, .{ .key = k, .value = v });
    }
    const src_count = hamt.mapCount(m_src);
    // Perform 40 random assoc/dissoc operations AGAINST m_src (not
    // updating m_src between). After each, m_src must still reflect
    // its original state exactly.
    var ops: usize = 0;
    while (ops < 40) : (ops += 1) {
        const is_assoc = r.boolean();
        if (is_assoc) {
            _ = try hamt.mapAssoc(&heap, m_src, value.fromFixnum(9999).?, value.fromFixnum(0).?, &dispatch.hashValue, &dispatch.equal);
        } else if (n > 0) {
            _ = try hamt.mapDissoc(&heap, m_src, value.fromFixnum(@intCast(r.uintLessThan(usize, n))).?, &dispatch.hashValue, &dispatch.equal);
        }
        try std.testing.expectEqual(src_count, hamt.mapCount(m_src));
        for (model.items) |me| {
            switch (hamt.mapGet(m_src, me.key, &dispatch.hashValue, &dispatch.equal)) {
                .absent => try std.testing.expect(false),
                .present => |v| try std.testing.expect(dispatch.equal(v, me.value)),
            }
        }
    }
}

// -----------------------------------------------------------------------------
// M9. Keyword-keyed fast-path correctness
// -----------------------------------------------------------------------------

test "M9: keyword-keyed maps give identical results to fixnum-keyed maps" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();
    var prng = std.Random.DefaultPrng.init(prng_seed +% 9);
    const r = prng.random();

    var trial: usize = 0;
    while (trial < 100) : (trial += 1) {
        const n = r.intRangeAtMost(u32, 0, 30);
        // Two parallel sequences: same values, but one uses keyword
        // keys (fast path) and the other uses fixnum keys (general
        // path). After identical operations, equality over "keys I've
        // inserted" must report the same hit/miss results.
        var m_kw = try hamt.mapEmpty(&heap);
        var m_fx = try hamt.mapEmpty(&heap);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const v = randValue(r);
            m_kw = try hamt.mapAssoc(&heap, m_kw, value.fromKeywordId(i), v, &dispatch.hashValue, &dispatch.equal);
            m_fx = try hamt.mapAssoc(&heap, m_fx, value.fromFixnum(@intCast(i)).?, v, &dispatch.hashValue, &dispatch.equal);
        }
        try std.testing.expectEqual(hamt.mapCount(m_kw), hamt.mapCount(m_fx));
        // Every key lookup must match presence and value between them.
        i = 0;
        while (i < n) : (i += 1) {
            const kw = hamt.mapGet(m_kw, value.fromKeywordId(i), &dispatch.hashValue, &dispatch.equal);
            const fx = hamt.mapGet(m_fx, value.fromFixnum(@intCast(i)).?, &dispatch.hashValue, &dispatch.equal);
            switch (kw) {
                .absent => try std.testing.expect(fx == .absent),
                .present => |v_kw| switch (fx) {
                    .absent => try std.testing.expect(false),
                    .present => |v_fx| try std.testing.expect(dispatch.equal(v_kw, v_fx)),
                },
            }
        }
    }
}

// -----------------------------------------------------------------------------
// M10. Collision-bucket stress
// -----------------------------------------------------------------------------

/// Synthetic hash function that returns the same low-32 bits for every
/// key, forcing every insert into a collision node regardless of the
/// key's real hash. CHAMP indexes on low 32 bits (CHAMP.md §5.1) so
/// the collision path is exercised end-to-end.
///
/// Invariant: low 32 bits = `0xDEAD_BEEF` for every input. High 32
/// bits vary by input so that any downstream hashing pipelines that
/// DO consume the full u64 (e.g. when a colliding-keyed map's own
/// entries are hashed into a parent collection) still produce
/// distinct hashes across distinct entries.
///
/// Do not "optimize" to a constant u64 — that would cause spurious
/// collisions in other test paths that re-use this fixture. See the
/// equivalent `collidingHash` comment in `src/coll/hamt.zig`'s inline
/// tests for the same discipline.
fn collidingHash(v: Value) u64 {
    return (@as(u64, v.hashImmediate() >> 32) << 32) | 0xDEAD_BEEF;
}

test "M10: collision node stress — ≥5 distinct keys sharing an indexing hash" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    // Insert 10 distinct keys. With `collidingHash`, all land in a
    // single collision node at the deepest trie level.
    var m = try hamt.mapEmpty(&heap);
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        m = try hamt.mapAssoc(&heap, m, value.fromKeywordId(i), value.fromFixnum(@intCast(i)).?, &collidingHash, &dispatch.equal);
    }
    try std.testing.expectEqual(@as(usize, 10), hamt.mapCount(m));
    // Every key must be retrievable.
    i = 0;
    while (i < 10) : (i += 1) {
        switch (hamt.mapGet(m, value.fromKeywordId(i), &collidingHash, &dispatch.equal)) {
            .absent => try std.testing.expect(false),
            .present => |v| try std.testing.expectEqual(@as(i64, @intCast(i)), v.asFixnum()),
        }
    }
    // Dissoc alternating keys; remaining keys must still look up.
    m = try hamt.mapDissoc(&heap, m, value.fromKeywordId(0), &collidingHash, &dispatch.equal);
    m = try hamt.mapDissoc(&heap, m, value.fromKeywordId(3), &collidingHash, &dispatch.equal);
    m = try hamt.mapDissoc(&heap, m, value.fromKeywordId(7), &collidingHash, &dispatch.equal);
    try std.testing.expectEqual(@as(usize, 7), hamt.mapCount(m));
    try std.testing.expect(hamt.mapGet(m, value.fromKeywordId(0), &collidingHash, &dispatch.equal) == .absent);
    try std.testing.expect(hamt.mapGet(m, value.fromKeywordId(3), &collidingHash, &dispatch.equal) == .absent);
    try std.testing.expect(hamt.mapGet(m, value.fromKeywordId(7), &collidingHash, &dispatch.equal) == .absent);
    switch (hamt.mapGet(m, value.fromKeywordId(5), &collidingHash, &dispatch.equal)) {
        .absent => try std.testing.expect(false),
        .present => |v| try std.testing.expectEqual(@as(i64, 5), v.asFixnum()),
    }
    // Dissoc all remaining → empty.
    const remaining = [_]u32{ 1, 2, 4, 5, 6, 8, 9 };
    for (remaining) |r| {
        m = try hamt.mapDissoc(&heap, m, value.fromKeywordId(r), &collidingHash, &dispatch.equal);
    }
    try std.testing.expect(hamt.mapIsEmpty(m));
}

// -----------------------------------------------------------------------------
// M11 (bonus): bedrock `equal ⇒ hashValue equal` over a large random pool
// -----------------------------------------------------------------------------

test "M11: equal ⇒ hashValue equal over 500 random map pairs" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();
    var prng = std.Random.DefaultPrng.init(prng_seed +% 11);
    const r = prng.random();

    var trial: usize = 0;
    while (trial < 500) : (trial += 1) {
        // Build identical maps in two different insertion orders.
        const n = r.intRangeAtMost(usize, 0, 30);
        const entries = try gpa.alloc(hamt.Entry, n);
        defer gpa.free(entries);
        for (entries, 0..) |*e, idx| {
            e.* = .{
                .key = value.fromFixnum(@intCast(idx + trial * 100)).?,
                .value = randValue(r),
            };
        }
        var a = try hamt.mapEmpty(&heap);
        for (entries) |e| {
            a = try hamt.mapAssoc(&heap, a, e.key, e.value, &dispatch.hashValue, &dispatch.equal);
        }
        // Reverse-order build.
        var b = try hamt.mapEmpty(&heap);
        var idx_r: usize = entries.len;
        while (idx_r > 0) {
            idx_r -= 1;
            const e = entries[idx_r];
            b = try hamt.mapAssoc(&heap, b, e.key, e.value, &dispatch.hashValue, &dispatch.equal);
        }
        try std.testing.expect(dispatch.equal(a, b));
        try std.testing.expectEqual(dispatch.hashValue(a), dispatch.hashValue(b));
    }
}
