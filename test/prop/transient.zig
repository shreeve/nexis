//! test/prop/transient.zig — randomized property tests for the
//! transient wrapper: transient equivalence and ownership, alongside
//! test/prop/champ.zig (map/set) and test/prop/vector.zig (vector).
//!
//! Properties (TRANSIENT.md §11):
//!
//!   T1. Equivalence: random edit sequences applied via
//!       (transient → N × ...Bang → persistentBang) produce the same
//!       persistent Value (by `dispatch.equal` AND `dispatch.hashValue`)
//!       as the direct persistent path. 1000 trials per kind; T1d
//!       drives random conj!/assoc!/pop! on vectors of up to 1100
//!       elements, across the first trie boundary.
//!   T2. Ownership: frozen transients reject every op with
//!       `error.TransientFrozen`.
//!   T3. Source immutability: a `...Bang` session on transient
//!       `t = transientFrom(p)` does NOT mutate the original
//!       persistent `p`.
//!   T4. GC survival: a transient's inner structure survives GC
//!       when the transient itself is a root, even when the
//!       original persistent Value is dropped.
//!   T5. Persistence under in-place edits: every persistent map,
//!       set and vector any round produced keeps its contents, its
//!       canonical layout and its hash while later transients over
//!       it and its relatives, two at once, edit in place, through
//!       collision nodes and across the vector's trie boundaries,
//!       with collections in between.
//!   T6. The edit clock's wrap: tokens restart and no transient
//!       edits a node another owned.

const std = @import("std");
const nx = @import("nexis");
const value = nx.value;
const heap_mod = nx.heap;
const champ = nx.champ;
const vector = nx.vector;
const transient = nx.transient;
const dispatch = nx.dispatch;
const gc = nx.gc;

const Value = value.Value;
const Heap = heap_mod.Heap;
const HeapHeader = heap_mod.HeapHeader;

const prng_seed: u64 = 0x7472_616E_7369_656E; // "transien" LE

// =============================================================================
// T1 — Equivalence
// =============================================================================

test "T1a: map equivalence — transient × N ≡ persistent × N (1000 trials)" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 0x31);
    const r = prng.random();

    var trial: usize = 0;
    while (trial < 1000) : (trial += 1) {
        const n = r.uintLessThan(usize, 40);

        // Direct persistent path.
        var persistent_path = try champ.mapEmpty(&heap);
        // Transient path — wrap an empty, apply the same sequence.
        const t = try transient.transientFrom(&heap, try champ.mapEmpty(&heap));

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const key = value.fromFixnum(r.intRangeAtMost(i64, 0, 19)).?;
            if (r.boolean()) {
                // assoc
                const val = value.fromFixnum(r.intRangeAtMost(i64, -100, 100)).?;
                persistent_path = try champ.mapAssoc(&heap, persistent_path, key, val, &dispatch.hashValue, &dispatch.equal);
                _ = try transient.mapAssocBang(&heap, t, key, val, &dispatch.hashValue, &dispatch.equal, &dispatch.spoilCount);
            } else {
                // dissoc
                persistent_path = try champ.mapDissoc(&heap, persistent_path, key, &dispatch.hashValue, &dispatch.equal);
                _ = try transient.mapDissocBang(&heap, t, key, &dispatch.hashValue, &dispatch.equal, &dispatch.spoilCount);
            }
        }

        const persistent_from_transient = try transient.persistentBang(t);

        // Equivalence: `=` and hash-equal.
        try std.testing.expect(dispatch.equal(persistent_path, persistent_from_transient));
        try std.testing.expectEqual(
            dispatch.hashValue(persistent_path),
            dispatch.hashValue(persistent_from_transient),
        );
    }
}

test "T1b: set equivalence — transient × N ≡ persistent × N (1000 trials)" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 0x32);
    const r = prng.random();

    var trial: usize = 0;
    while (trial < 1000) : (trial += 1) {
        const n = r.uintLessThan(usize, 40);
        var persistent_path = try champ.setEmpty(&heap);
        const t = try transient.transientFrom(&heap, try champ.setEmpty(&heap));

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const elem = value.fromFixnum(r.intRangeAtMost(i64, 0, 19)).?;
            if (r.boolean()) {
                persistent_path = try champ.setConj(&heap, persistent_path, elem, &dispatch.hashValue, &dispatch.equal);
                _ = try transient.setConjBang(&heap, t, elem, &dispatch.hashValue, &dispatch.equal, &dispatch.spoilCount);
            } else {
                persistent_path = try champ.setDisj(&heap, persistent_path, elem, &dispatch.hashValue, &dispatch.equal);
                _ = try transient.setDisjBang(&heap, t, elem, &dispatch.hashValue, &dispatch.equal, &dispatch.spoilCount);
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

test "T1c: vector equivalence — transient × N conj ≡ persistent × N conj (1000 trials)" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 0x33);
    const r = prng.random();

    var trial: usize = 0;
    while (trial < 1000) : (trial += 1) {
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

test "T1d: vector equivalence — random conj!/assoc!/pop! ≡ conj/assoc/pop (300 trials)" {
    var debug: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{ .stack_trace_frames = 0 });
    defer _ = debug.deinit();
    var heap = Heap.init(debug.allocator());
    defer heap.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 0x34);
    const r = prng.random();

    var trial: usize = 0;
    while (trial < 300) : (trial += 1) {
        // Start anywhere up to past the first trie boundary (1056).
        const start = r.uintLessThan(usize, 1100);
        const elems = try debug.allocator().alloc(Value, start);
        defer debug.allocator().free(elems);
        for (elems, 0..) |*e, i| e.* = value.fromFixnum(@intCast(i)).?;
        var persistent_path = try vector.fromSlice(&heap, elems);
        const t = try transient.transientFrom(&heap, persistent_path);
        for (0..60) |_| {
            const n = vector.count(persistent_path);
            const elem = value.fromFixnum(r.intRangeAtMost(i64, -99, 99)).?;
            switch (r.uintLessThan(u8, 3)) {
                0 => {
                    persistent_path = try vector.conj(&heap, persistent_path, elem);
                    _ = try transient.vectorConjBang(&heap, t, elem);
                },
                1 => if (n > 0) {
                    const i = r.uintLessThan(usize, n);
                    persistent_path = try vector.assoc(&heap, persistent_path, i, elem);
                    _ = try transient.vectorAssocBang(&heap, t, i, elem);
                },
                else => if (n > 0) {
                    persistent_path = try vector.pop(&heap, persistent_path);
                    _ = try transient.vectorPopBang(&heap, t);
                },
            }
        }
        const persistent_from_transient = try transient.persistentBang(t);
        try std.testing.expect(dispatch.equal(persistent_path, persistent_from_transient));
        try std.testing.expectEqual(dispatch.hashValue(persistent_path), dispatch.hashValue(persistent_from_transient));
    }
}

// =============================================================================
// T2 — Ownership
// =============================================================================

test "T2a: map transient post-freeze rejects every op with TransientFrozen" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();
    const t = try transient.transientFrom(&heap, try champ.mapEmpty(&heap));
    _ = try transient.persistentBang(t);
    try std.testing.expectError(
        transient.TransientError.TransientFrozen,
        transient.mapAssocBang(&heap, t, value.testKeyword(1), value.fromFixnum(1).?, &dispatch.hashValue, &dispatch.equal, &dispatch.spoilCount),
    );
    try std.testing.expectError(
        transient.TransientError.TransientFrozen,
        transient.mapDissocBang(&heap, t, value.testKeyword(1), &dispatch.hashValue, &dispatch.equal, &dispatch.spoilCount),
    );
    try std.testing.expectError(
        transient.TransientError.TransientFrozen,
        transient.mapGetBang(t, value.testKeyword(1), &dispatch.hashValue, &dispatch.equal),
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
    const t = try transient.transientFrom(&heap, try champ.setEmpty(&heap));
    _ = try transient.persistentBang(t);
    try std.testing.expectError(
        transient.TransientError.TransientFrozen,
        transient.setConjBang(&heap, t, value.testKeyword(1), &dispatch.hashValue, &dispatch.equal, &dispatch.spoilCount),
    );
    try std.testing.expectError(
        transient.TransientError.TransientFrozen,
        transient.setDisjBang(&heap, t, value.testKeyword(1), &dispatch.hashValue, &dispatch.equal, &dispatch.spoilCount),
    );
    try std.testing.expectError(
        transient.TransientError.TransientFrozen,
        transient.setContainsBang(t, value.testKeyword(1), &dispatch.hashValue, &dispatch.equal),
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
    const t_map = try transient.transientFrom(&heap, try champ.mapEmpty(&heap));
    const t_set = try transient.transientFrom(&heap, try champ.setEmpty(&heap));
    const t_vec = try transient.transientFrom(&heap, try vector.empty(&heap));

    // map ops on non-map transients.
    try std.testing.expectError(
        transient.TransientError.TransientKindMismatch,
        transient.mapAssocBang(&heap, t_set, value.testKeyword(1), value.fromFixnum(1).?, &dispatch.hashValue, &dispatch.equal, &dispatch.spoilCount),
    );
    try std.testing.expectError(
        transient.TransientError.TransientKindMismatch,
        transient.mapAssocBang(&heap, t_vec, value.testKeyword(1), value.fromFixnum(1).?, &dispatch.hashValue, &dispatch.equal, &dispatch.spoilCount),
    );
    // set ops on non-set transients.
    try std.testing.expectError(
        transient.TransientError.TransientKindMismatch,
        transient.setConjBang(&heap, t_map, value.testKeyword(1), &dispatch.hashValue, &dispatch.equal, &dispatch.spoilCount),
    );
    try std.testing.expectError(
        transient.TransientError.TransientKindMismatch,
        transient.setConjBang(&heap, t_vec, value.testKeyword(1), &dispatch.hashValue, &dispatch.equal, &dispatch.spoilCount),
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
        transient.mapCountBang(try champ.mapEmpty(&heap)),
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
        var src = try champ.mapEmpty(&heap);
        var i: u32 = 0;
        while (i < 15) : (i += 1) {
            src = try champ.mapAssoc(&heap, src, value.testKeyword(i), value.fromFixnum(@intCast(i)).?, &dispatch.hashValue, &dispatch.equal);
        }
        const src_hash_before = dispatch.hashValue(src);
        const src_count_before = champ.mapCount(src);

        // Wrap and mutate.
        var t = try transient.transientFrom(&heap, src);
        const ops = r.intRangeAtMost(usize, 1, 20);
        var op: usize = 0;
        while (op < ops) : (op += 1) {
            const pick = r.uintLessThan(u8, 2);
            if (pick == 0) {
                const k = value.testKeyword(r.intRangeAtMost(u32, 0, 100));
                t = try transient.mapAssocBang(&heap, t, k, value.fromFixnum(r.intRangeAtMost(i64, -100, 100)).?, &dispatch.hashValue, &dispatch.equal, &dispatch.spoilCount);
            } else {
                const k = value.testKeyword(r.intRangeAtMost(u32, 0, 30));
                t = try transient.mapDissocBang(&heap, t, k, &dispatch.hashValue, &dispatch.equal, &dispatch.spoilCount);
            }
        }
        _ = try transient.persistentBang(t);

        // `src` must be untouched.
        try std.testing.expectEqual(src_count_before, champ.mapCount(src));
        try std.testing.expectEqual(src_hash_before, dispatch.hashValue(src));
        i = 0;
        while (i < 15) : (i += 1) {
            switch (champ.mapGet(src, value.testKeyword(i), &dispatch.hashValue, &dispatch.equal)) {
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
    var t = try transient.transientFrom(&heap, try champ.mapEmpty(&heap));
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        t = try transient.mapAssocBang(&heap, t, value.testKeyword(i), value.fromFixnum(@intCast(i)).?, &dispatch.hashValue, &dispatch.equal, &dispatch.spoilCount);
    }

    var collector = gc.Collector.init(&heap);
    defer collector.deinit();
    const live_before = heap.liveCount();
    _ = collector.collect(&.{Heap.asHeapHeader(t)});
    const live_after = heap.liveCount();
    // Collection should have pruned orphans but the transient +
    // its inner structure must survive.
    try std.testing.expect(live_after < live_before);

    // Every key is still reachable via the transient.
    i = 0;
    while (i < 20) : (i += 1) {
        const lookup = try transient.mapGetBang(t, value.testKeyword(i), &dispatch.hashValue, &dispatch.equal);
        switch (lookup) {
            .present => |v| try std.testing.expectEqual(@as(i64, @intCast(i)), v.asFixnum()),
            .absent => try std.testing.expect(false),
        }
    }
}

test "T4b: frozen transient still traces inner_header (inner survives via wrapper)" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    const t = try transient.transientFrom(&heap, try champ.mapEmpty(&heap));
    _ = try transient.mapAssocBang(&heap, t, value.testKeyword(1), value.fromFixnum(100).?, &dispatch.hashValue, &dispatch.equal, &dispatch.spoilCount);
    const frozen_persistent = try transient.persistentBang(t);

    // Keep BOTH the wrapper AND the returned persistent Value as
    // roots. The wrapper is frozen — its only outgoing edge is the
    // inner_header, which must still be alive post-GC so the
    // persistent Value (which points at the same *HeapHeader)
    // remains usable.
    var collector = gc.Collector.init(&heap);
    defer collector.deinit();
    _ = collector.collect(&.{
        Heap.asHeapHeader(t),
        Heap.asHeapHeader(frozen_persistent),
    });

    // Persistent Value still functional after GC — proves
    // inner_header reachability was maintained.
    try std.testing.expectEqual(@as(usize, 1), champ.mapCount(frozen_persistent));
    switch (champ.mapGet(frozen_persistent, value.testKeyword(1), &dispatch.hashValue, &dispatch.equal)) {
        .present => |v| try std.testing.expectEqual(@as(i64, 100), v.asFixnum()),
        .absent => try std.testing.expect(false),
    }
}

// =============================================================================
// T5 — Persistence under in-place edits (TRANSIENT.md §1)
//
// A transient edits the nodes it owns in place and shares the rest
// with the persistent collections it came from and gave. Every
// persistent collection any round produced must keep its contents,
// its canonical layout and its hash, however many transients later
// start from it or from its relatives, two of them active at once,
// with collections in between.
// =============================================================================

fn fx(i: i64) Value {
    return value.fromFixnum(i).?;
}

const MapModel = std.array_hash_map.Auto(i64, i64);

/// A collision fixture's hash (test/prop/champ.zig M10): every key's
/// low 32 bits are one value, so the keys meet in a collision node.
fn collidingHash(v: Value) u64 {
    return (@as(u64, dispatch.hashValue(v) >> 32) << 32) | 0xDEAD_BEEF;
}

const MapKeys = struct {
    hash: *const fn (Value) u64,
    /// Fixnum keys, or strings under `collidingHash`.
    strings: bool,

    fn key(self: MapKeys, heap: *Heap, i: i64) !Value {
        if (!self.strings) return fx(i);
        var buf: [32]u8 = undefined;
        return nx.string.fromBytes(heap, std.mem.print(&buf, "collider-{d}", .{i}) catch unreachable);
    }
};

fn expectMapIs(gpa: std.mem.Allocator, heap: *Heap, keys: MapKeys, m: Value, model: *const MapModel) !void {
    try std.testing.expectEqual(model.count(), champ.mapCount(m));
    const entries = try gpa.alloc(champ.Entry, model.count());
    defer gpa.free(entries);
    for (model.keys(), model.values(), entries) |k, v, *e| {
        const kv = try keys.key(heap, k);
        switch (champ.mapGet(m, kv, keys.hash, &dispatch.equal)) {
            .present => |got| try std.testing.expectEqual(v, got.asFixnum()),
            .absent => return error.TestUnexpectedResult,
        }
        e.* = .{ .key = kv, .value = fx(v) };
    }
    try std.testing.expect(champ.canonicalTrie(m, keys.hash));
    // `=` looks keys up by their own hash: only a fixture that keeps it
    // can compare.
    if (keys.strings) return;
    const fresh = try champ.mapFromEntries(heap, entries, keys.hash, &dispatch.equal);
    try std.testing.expect(dispatch.equal(fresh, m));
    try std.testing.expectEqual(dispatch.hashValue(fresh), dispatch.hashValue(m));
}

const Persisted = struct { v: Value, model: MapModel };

fn randomMapEdit(heap: *Heap, r: std.Random, keys: MapKeys, key_max: i64, t: Value, model: *MapModel, gpa: std.mem.Allocator) !void {
    const k = r.intRangeAtMost(i64, 0, key_max);
    const kv = try keys.key(heap, k);
    if (r.uintLessThan(u8, 4) < 3) {
        const v = r.intRangeAtMost(i64, -1000, 1000);
        _ = try transient.mapAssocBang(heap, t, kv, fx(v), keys.hash, &dispatch.equal, &dispatch.spoilCount);
        try model.put(gpa, k, v);
    } else {
        _ = try transient.mapDissocBang(heap, t, kv, keys.hash, &dispatch.equal, &dispatch.spoilCount);
        _ = model.orderedRemove(k);
    }
}

/// Rounds of edits, each through a transient over the last round's
/// map and, alongside it, one over an earlier map; every map any
/// round gave is checked against its model, after a collection that
/// roots only those maps.
fn mapPersistenceRounds(heap: *Heap, r: std.Random, keys: MapKeys, rounds: usize, key_max: i64, max_edits: usize) !void {
    const gpa = std.testing.allocator;
    var persisted: std.ArrayList(Persisted) = .empty;
    defer {
        for (persisted.items) |*p| p.model.deinit(gpa);
        persisted.deinit(gpa);
    }
    var roots: std.ArrayList(*HeapHeader) = .empty;
    defer roots.deinit(gpa);
    var collector = gc.Collector.init(heap);
    defer collector.deinit();

    var cur = try champ.mapEmpty(heap);
    var cur_model: MapModel = .empty;
    defer cur_model.deinit(gpa);
    for (0..rounds) |round| {
        const t = try transient.transientFrom(heap, cur);
        var model = try cur_model.clone(gpa);
        var other: ?struct { t: Value, model: MapModel } = null;
        if (persisted.items.len > 0) {
            const src = persisted.items[r.uintLessThan(usize, persisted.items.len)];
            other = .{ .t = try transient.transientFrom(heap, src.v), .model = try src.model.clone(gpa) };
        }
        for (0..r.uintLessThan(usize, max_edits)) |_| {
            try randomMapEdit(heap, r, keys, key_max, t, &model, gpa);
            if (other) |*o| try randomMapEdit(heap, r, keys, key_max, o.t, &o.model, gpa);
        }
        cur = try transient.persistentBang(t);
        cur_model.deinit(gpa);
        cur_model = try model.clone(gpa);
        try persisted.append(gpa, .{ .v = cur, .model = model });
        if (other) |o| try persisted.append(gpa, .{ .v = try transient.persistentBang(o.t), .model = o.model });

        roots.clearRetainingCapacity();
        for (persisted.items) |p| try roots.append(gpa, Heap.asHeapHeader(p.v));
        _ = collector.collect(roots.items);
        const all = round % 4 == 3 or round + 1 == rounds;
        for (persisted.items, 0..) |*p, i| {
            if (all or i + 2 >= persisted.items.len) try expectMapIs(gpa, heap, keys, p.v, &p.model);
        }
    }
}

test "T5a: persistent maps never change under in-place edits of transients over them" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();
    var prng = std.Random.DefaultPrng.init(prng_seed +% 0x5a);
    try mapPersistenceRounds(&heap, prng.random(), .{ .hash = &dispatch.hashValue, .strings = false }, 24, 1500, 600);
}

test "T5b: in-place edits through collision nodes keep every persistent map" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();
    var prng = std.Random.DefaultPrng.init(prng_seed +% 0x5b);
    const keys: MapKeys = .{ .hash = &collidingHash, .strings = true };
    try mapPersistenceRounds(&heap, prng.random(), keys, 24, 14, 40);
    // The fixture reaches the collision layer.
    const t = try transient.transientFrom(&heap, try champ.mapEmpty(&heap));
    for (0..12) |i| _ = try transient.mapAssocBang(&heap, t, try keys.key(&heap, @intCast(i)), fx(@intCast(i)), keys.hash, &dispatch.equal, &dispatch.spoilCount);
    try std.testing.expectEqual(@as(?u32, 12), champ.mapCollisionCount(try transient.persistentBang(t), 0xDEAD_BEEF));
}

const SetModel = std.array_hash_map.Auto(i64, void);

fn expectSetIs(gpa: std.mem.Allocator, heap: *Heap, s: Value, model: *const SetModel) !void {
    try std.testing.expectEqual(model.count(), champ.setCount(s));
    const elems = try gpa.alloc(Value, model.count());
    defer gpa.free(elems);
    for (model.keys(), elems) |k, *e| {
        try std.testing.expect(champ.setContains(s, fx(k), &dispatch.hashValue, &dispatch.equal));
        e.* = fx(k);
    }
    try std.testing.expect(champ.canonicalTrie(s, &dispatch.hashValue));
    try std.testing.expect(dispatch.equal(try champ.setFromElements(heap, elems, &dispatch.hashValue, &dispatch.equal), s));
}

test "T5c: persistent sets never change under in-place edits of transients over them" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();
    var prng = std.Random.DefaultPrng.init(prng_seed +% 0x5c);
    const r = prng.random();
    var sets: std.ArrayList(Value) = .empty;
    defer sets.deinit(gpa);
    var models: std.ArrayList(SetModel) = .empty;
    defer {
        for (models.items) |*m| m.deinit(gpa);
        models.deinit(gpa);
    }
    try sets.append(gpa, try champ.setEmpty(&heap));
    try models.append(gpa, .empty);
    for (0..30) |_| {
        const from = r.uintLessThan(usize, sets.items.len);
        const t = try transient.transientFrom(&heap, sets.items[from]);
        var model = try models.items[from].clone(gpa);
        for (0..r.uintLessThan(usize, 500)) |_| {
            const k = r.intRangeAtMost(i64, 0, 1200);
            if (r.uintLessThan(u8, 3) < 2) {
                _ = try transient.setConjBang(&heap, t, fx(k), &dispatch.hashValue, &dispatch.equal, &dispatch.spoilCount);
                try model.put(gpa, k, {});
            } else {
                _ = try transient.setDisjBang(&heap, t, fx(k), &dispatch.hashValue, &dispatch.equal, &dispatch.spoilCount);
                _ = model.orderedRemove(k);
            }
        }
        try sets.append(gpa, try transient.persistentBang(t));
        try models.append(gpa, model);
        for (sets.items, models.items) |s, *m| try expectSetIs(gpa, &heap, s, m);
    }
}

test "T5d: persistent vectors never change under in-place conj!/assoc!/pop! of transients over them" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();
    var prng = std.Random.DefaultPrng.init(prng_seed +% 0x5d);
    const r = prng.random();
    var vecs: std.ArrayList(Value) = .empty;
    defer vecs.deinit(gpa);
    var models: std.ArrayList(std.ArrayList(i64)) = .empty;
    defer {
        for (models.items) |*m| m.deinit(gpa);
        models.deinit(gpa);
    }
    var collector = gc.Collector.init(&heap);
    defer collector.deinit();
    var roots: std.ArrayList(*HeapHeader) = .empty;
    defer roots.deinit(gpa);
    try vecs.append(gpa, try vector.empty(&heap));
    try models.append(gpa, .empty);
    for (0..40) |_| {
        const from = r.uintLessThan(usize, vecs.items.len);
        const t = try transient.transientFrom(&heap, vecs.items[from]);
        var model = try models.items[from].clone(gpa);
        // Grow past the 1056 and 32800 boundaries now and then.
        const edits = if (r.uintLessThan(u8, 8) == 0) r.uintLessThan(usize, 34000) else r.uintLessThan(usize, 1500);
        for (0..edits) |_| {
            const pick = r.uintLessThan(u8, 10);
            if (pick < 6 or model.items.len == 0) {
                const x = r.int(i32);
                _ = try transient.vectorConjBang(&heap, t, fx(x));
                try model.append(gpa, x);
            } else if (pick < 9) {
                const i = r.uintLessThan(usize, model.items.len);
                const x = r.int(i32);
                _ = try transient.vectorAssocBang(&heap, t, i, fx(x));
                model.items[i] = x;
            } else {
                _ = try transient.vectorPopBang(&heap, t);
                _ = model.pop();
            }
        }
        try vecs.append(gpa, try transient.persistentBang(t));
        try models.append(gpa, model);
        roots.clearRetainingCapacity();
        for (vecs.items) |v| try roots.append(gpa, Heap.asHeapHeader(v));
        _ = collector.collect(roots.items);
        for (vecs.items, models.items) |v, m| {
            try std.testing.expectEqual(m.items.len, vector.count(v));
            const elems = try gpa.alloc(Value, m.items.len);
            defer gpa.free(elems);
            for (m.items, elems, 0..) |x, *e, i| {
                e.* = fx(x);
                try std.testing.expectEqual(x, vector.nth(v, i).asFixnum());
            }
            const fresh = try vector.fromSlice(&heap, elems);
            try std.testing.expect(dispatch.equal(fresh, v));
            try std.testing.expectEqual(dispatch.hashValue(fresh), dispatch.hashValue(v));
        }
    }
}

// =============================================================================
// T6 — The edit clock wraps (TRANSIENT.md §4)
// =============================================================================

test "T6: across the edit clock's wrap, no transient edits a node another owned" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();
    heap.edit_clock = heap_mod.edit_token_max - 5;
    var prng = std.Random.DefaultPrng.init(prng_seed +% 0x6);
    try mapPersistenceRounds(&heap, prng.random(), .{ .hash = &dispatch.hashValue, .strings = false }, 12, 800, 300);
    try std.testing.expect(heap.edit_clock < 100);

    // A transient active across the wrap keeps working and its
    // collection keeps its elements.
    heap.edit_clock = heap_mod.edit_token_max - 1;
    const t = try transient.transientFrom(&heap, try vector.empty(&heap));
    for (0..100) |i| _ = try transient.vectorConjBang(&heap, t, fx(@intCast(i)));
    const kept = try transient.persistentBang(try transient.transientFrom(&heap, try vector.fromSlice(&heap, &.{ fx(1), fx(2) })));
    const u = try transient.transientFrom(&heap, kept);
    _ = try transient.vectorAssocBang(&heap, u, 0, fx(-1));
    for (100..200) |i| _ = try transient.vectorConjBang(&heap, t, fx(@intCast(i)));
    const v = try transient.persistentBang(t);
    for (0..200) |i| try std.testing.expectEqual(@as(i64, @intCast(i)), vector.nth(v, i).asFixnum());
    try std.testing.expectEqual(@as(i64, 1), vector.nth(kept, 0).asFixnum());
    try std.testing.expectEqual(@as(i64, -1), vector.nth(try transient.persistentBang(u), 0).asFixnum());
}

test "T6: a vector grown under a transient map's token across the wrap stays out of every later transient's reach" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();
    heap.edit_clock = heap_mod.edit_token_max - 3;
    const t = try transient.transientFrom(&heap, try champ.mapEmpty(&heap));
    const bucket = try vector.empty(&heap);
    const spot = try transient.mapLocateBang(t, fx(0), &dispatch.hashValue, &dispatch.equal);
    try transient.mapPutBang(&heap, t, spot, fx(0), bucket);
    // Transients made between two edits, as a `group-by` key function
    // makes them, wrap the clock.
    for (0..10) |_| _ = try transient.transientFrom(&heap, try vector.empty(&heap));
    for (0..10) |i| try transient.vectorConjUnderBang(&heap, t, bucket, fx(@intCast(i)));
    const m = try transient.persistentBang(t);
    // The tokens the clock handed out before the wrap, again.
    heap.edit_clock = heap_mod.edit_token_max - 3;
    for (0..3) |_| _ = try transient.vectorAssocBang(&heap, try transient.transientFrom(&heap, bucket), 0, fx(-1));
    try std.testing.expect(dispatch.equal(bucket, try vector.fromSlice(&heap, &.{ fx(0), fx(1), fx(2), fx(3), fx(4), fx(5), fx(6), fx(7), fx(8), fx(9) })));
    try std.testing.expectEqual(@as(usize, 1), champ.mapCount(m));
}
