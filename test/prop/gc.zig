//! test/prop/gc.zig — randomized property tests for the precise
//! mark-sweep collector. Covers PLAN §20.2 test #7 (GC stress) with
//! a Collector.collect-driven discipline; `test/prop/heap.zig` covers
//! the same allocator with hand-marking.
//!
//! Properties (GC.md §10 testing):
//!
//!   G1. Flat-root sweep: random allocations, random root subset,
//!       after collect every root's transitive closure survives and
//!       every other unpinned block is freed.
//!   G2. Nested reachability graph: 60 random heap objects
//!       (strings, lists, maps, sets, vectors) nested into each
//!       other; a random subset declared as roots; after a cycle
//!       exactly the objects transitively reachable from the roots
//!       survive.
//!   G3. Idempotence: `collect` called twice back-to-back with the
//!       same roots frees 0 blocks on the second call.
//!   G4. Pinning: any pinned block survives regardless of root
//!       membership; clearing the pin before the next collect makes
//!       it freeable.

const std = @import("std");
const nx = @import("nexis");
const value = nx.value;
const heap_mod = nx.heap;
const string = nx.string;
const list_mod = nx.list;
const vector_mod = nx.vector;
const champ = nx.champ;
const dispatch = nx.dispatch;
const gc = nx.gc;
const harness = @import("harness");

const Value = value.Value;
const Heap = heap_mod.Heap;
const HeapHeader = heap_mod.HeapHeader;
const Collector = gc.Collector;

const prng_seed: u64 = 0x6763_5F70_726F_7061; // "apor_pgc" LE-ish

// -----------------------------------------------------------------------------
// G1. Flat-root sweep — no nested graphs, just many unrelated blocks.
// -----------------------------------------------------------------------------

test "G1: random flat blocks with random root subset" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 1);
    const r = prng.random();

    var trial: usize = 0;
    while (trial < 30) : (trial += 1) {
        const n = r.intRangeAtMost(usize, 1, 30);
        // Allocate n unrelated strings.
        const headers = try gpa.alloc(*HeapHeader, n);
        defer gpa.free(headers);
        for (headers, 0..) |*slot, i| {
            var buf: [16]u8 = undefined;
            const txt = try std.fmt.bufPrint(&buf, "v{d}", .{i});
            const s = try string.fromBytes(&heap, txt);
            slot.* = Heap.asHeapHeader(s);
        }
        // Pick a random subset as roots.
        var roots: std.ArrayList(*HeapHeader) = .empty;
        defer roots.deinit(gpa);
        const in_roots = try gpa.alloc(bool, n);
        defer gpa.free(in_roots);
        @memset(in_roots, false);
        for (headers, 0..) |h, i| {
            if (r.boolean()) {
                try roots.append(gpa, h);
                in_roots[i] = true;
            }
        }

        var collector = Collector.init(&heap);
        defer collector.deinit();
        _ = collector.collect(roots.items);
        // Every root survives; every non-root is gone. Post-sweep
        // the pointer/header is freed, so we can't touch it — but
        // liveCount must equal |roots|.
        try std.testing.expectEqual(roots.items.len, heap.liveCount());
    }
}

// -----------------------------------------------------------------------------
// G2. Nested reachability graph
// -----------------------------------------------------------------------------

test "G2: nested graph — exactly the pool members reachable from the roots survive a cycle" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 2);
    const r = prng.random();

    // Build a pool of heterogeneous heap objects. Each new object
    // MAY reference earlier-allocated pool members as children;
    // we track each object's "reachable set" as a
    // std.AutoHashMap(usize, void) of indices in the pool.
    const pool_size: usize = 60;
    var pool: [pool_size]Value = undefined;

    // Reachable sets: `reach[i]` contains every pool index
    // transitively reachable from `pool[i]`, INCLUDING `i` itself.
    // We populate this incrementally as we build each object.
    var reach: [pool_size]std.AutoHashMap(usize, void) = undefined;
    for (0..pool_size) |i| reach[i] = .init(gpa);
    defer for (0..pool_size) |i| reach[i].deinit();

    // Build pool[0..] bottom-up.
    for (0..pool_size) |i| {
        try reach[i].put(i, {}); // include self

        // Decide what kind of object to build. Simpler kinds first;
        // nested kinds can reference earlier pool members.
        const choice = r.uintLessThan(u8, 5);
        if (choice == 0 or i == 0) {
            // String (leaf)
            var buf: [16]u8 = undefined;
            const txt = try std.fmt.bufPrint(&buf, "s{d}", .{i});
            pool[i] = try string.fromBytes(&heap, txt);
        } else if (choice == 1) {
            // List holding up to 3 random earlier pool members.
            const k = r.intRangeAtMost(usize, 1, @min(i, 3));
            const children = try gpa.alloc(Value, k);
            defer gpa.free(children);
            for (children) |*slot| {
                const idx = r.uintLessThan(usize, i);
                slot.* = pool[idx];
                // Fold child's reachable set into our own.
                var it = reach[idx].iterator();
                while (it.next()) |entry| try reach[i].put(entry.key_ptr.*, {});
            }
            pool[i] = try list_mod.fromSlice(&heap, children);
        } else if (choice == 2) {
            // Vector holding up to 4 random earlier pool members.
            const k = r.intRangeAtMost(usize, 1, @min(i, 4));
            const children = try gpa.alloc(Value, k);
            defer gpa.free(children);
            for (children) |*slot| {
                const idx = r.uintLessThan(usize, i);
                slot.* = pool[idx];
                var it = reach[idx].iterator();
                while (it.next()) |entry| try reach[i].put(entry.key_ptr.*, {});
            }
            pool[i] = try vector_mod.fromSlice(&heap, children);
        } else if (choice == 3) {
            // Map: keys are fixnums (immediate), values are earlier
            // pool members (heap references).
            pool[i] = try champ.mapEmpty(&heap);
            const k = r.intRangeAtMost(usize, 1, @min(i, 3));
            for (0..k) |j| {
                const idx = r.uintLessThan(usize, i);
                pool[i] = try champ.mapAssoc(&heap, pool[i], value.fromFixnum(@intCast(j)).?, pool[idx], &dispatch.hashValue, &dispatch.equal);
                var it = reach[idx].iterator();
                while (it.next()) |entry| try reach[i].put(entry.key_ptr.*, {});
            }
        } else {
            // Set of earlier pool members (where the element is a
            // heap-kind Value — so references are through elements).
            pool[i] = try champ.setEmpty(&heap);
            const k = r.intRangeAtMost(usize, 1, @min(i, 3));
            for (0..k) |_| {
                const idx = r.uintLessThan(usize, i);
                pool[i] = try champ.setConj(&heap, pool[i], pool[idx], &dispatch.hashValue, &dispatch.equal);
                var it = reach[idx].iterator();
                while (it.next()) |entry| try reach[i].put(entry.key_ptr.*, {});
            }
        }
    }

    // Declare a random subset of the pool as roots. Note: the pool
    // objects' INTERMEDIATE path-copy allocations (all the earlier
    // root pointers for each collection built via repeated assoc/
    // conj) are already orphans at this point; the test doesn't
    // track them in the reachable model, so the assertions below are
    // about pool members alone, not a live count.
    var roots: std.ArrayList(*HeapHeader) = .empty;
    defer roots.deinit(gpa);
    var root_indices: std.ArrayList(usize) = .empty;
    defer root_indices.deinit(gpa);
    var rooted_reach: std.AutoHashMap(usize, void) = .init(gpa);
    defer rooted_reach.deinit();

    for (0..pool_size) |i| {
        if (r.boolean()) {
            try root_indices.append(gpa, i);
            try roots.append(gpa, Heap.asHeapHeader(pool[i]));
            var it = reach[i].iterator();
            while (it.next()) |entry| try rooted_reach.put(entry.key_ptr.*, {});
        }
    }

    // Collect.
    var collector = Collector.init(&heap);
    defer collector.deinit();
    _ = collector.collect(roots.items);

    // Exactly the rooted-reachable pool members survive: each pool
    // member is its own block, referenced only by later members that
    // hold it (no two indices share a header).
    const Live = struct {
        set: *std.AutoHashMap(*HeapHeader, void),
        failed: bool = false,
        pub fn visit(self: *@This(), h: *HeapHeader) void {
            self.set.put(h, {}) catch {
                self.failed = true;
            };
        }
    };
    var live_set = std.AutoHashMap(*HeapHeader, void).init(gpa);
    defer live_set.deinit();
    var live: Live = .{ .set = &live_set };
    heap.forEachLive(&live);
    try std.testing.expect(!live.failed);
    for (pool, 0..) |v, idx| {
        const survived = live_set.contains(Heap.asHeapHeader(v));
        std.testing.expectEqual(rooted_reach.contains(idx), survived) catch |err| {
            std.debug.print("G2: pool[{d}] ({s}) reachable={} survived={}\n", .{ idx, @tagName(v.kind()), rooted_reach.contains(idx), survived });
            return err;
        };
    }
}

// -----------------------------------------------------------------------------
// G3. Idempotence
// -----------------------------------------------------------------------------

test "G3: collect twice with same roots — second call frees 0 blocks" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    const a = try string.fromBytes(&heap, "a");
    const b = try string.fromBytes(&heap, "b");
    _ = try string.fromBytes(&heap, "orphan");

    var collector = Collector.init(&heap);
    defer collector.deinit();
    const roots = [_]*HeapHeader{ Heap.asHeapHeader(a), Heap.asHeapHeader(b) };
    const freed1 = collector.collect(&roots);
    try std.testing.expect(freed1 >= 1); // at least the orphan
    const live_after_first = heap.liveCount();

    const freed2 = collector.collect(&roots);
    try std.testing.expectEqual(@as(usize, 0), freed2);
    try std.testing.expectEqual(live_after_first, heap.liveCount());
}

// -----------------------------------------------------------------------------
// G3b. A long list is walked without recursion (GC.md §5)
// -----------------------------------------------------------------------------

test "G3b: a list of half a million cells survives a cycle intact and is freed by the next" {
    // No stack trace per allocation: capturing half a million costs
    // more than the cycles under test. A leak still logs an error,
    // which fails the test.
    var gpa: std.heap.DebugAllocator(.{ .stack_trace_frames = 0 }) = .init;
    defer _ = gpa.deinit();
    var heap = Heap.init(gpa.allocator());
    defer heap.deinit();

    // Half a million cons cells: a recursive walk of the tail chain
    // would exhaust the thread stack long before the end.
    const n: usize = 500_000;
    var xs = try list_mod.empty(&heap);
    var i: usize = 0;
    while (i < n) : (i += 1) xs = try list_mod.cons(&heap, value.fromFixnum(@intCast(i)).?, xs);
    _ = try string.fromBytes(&heap, "orphan");

    var collector = Collector.init(&heap);
    defer collector.deinit();
    const roots = [_]*HeapHeader{Heap.asHeapHeader(xs)};
    const freed = collector.collect(&roots);
    try std.testing.expectEqual(@as(usize, 1), freed);
    try std.testing.expectEqual(n, list_mod.count(xs));
    try std.testing.expectEqual(n + 1, heap.liveCount());

    const freed_all = collector.collect(&.{});
    try std.testing.expectEqual(n + 1, freed_all);
    try std.testing.expectEqual(@as(usize, 0), heap.liveCount());
}

test "G3c: a chain of 300,000 nested vectors, maps, atoms and meta maps survives a cycle" {
    // Every level is a different edge the mark phase follows: a
    // vector element, a map value, an atom's value, a header's meta.
    // The walk is a worklist, so the chain's depth never becomes
    // native recursion depth; a recursive mark faults here long
    // before the end.
    var gpa: std.heap.DebugAllocator(.{ .stack_trace_frames = 0 }) = .init;
    defer _ = gpa.deinit();
    var heap = Heap.init(gpa.allocator());
    defer heap.deinit();

    const depth: usize = 300_000;
    var node = value.fromFixnum(0).?;
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        node = switch (i % 4) {
            0 => try vector_mod.fromSlice(&heap, &.{node}),
            1 => try champ.mapAssoc(&heap, try champ.mapEmpty(&heap), value.fromKeywordId(1), node, &dispatch.hashValue, &dispatch.equal),
            2 => try nx.atom.make(&heap, node),
            // A fresh string whose metadata map holds the level below.
            else => blk: {
                const m = try champ.mapAssoc(&heap, try champ.mapEmpty(&heap), value.fromKeywordId(2), node, &dispatch.hashValue, &dispatch.equal);
                const s = try string.fromBytes(&heap, "m");
                Heap.asHeapHeader(s).setMeta(Heap.asHeapHeader(m));
                break :blk s;
            },
        };
    }
    _ = try string.fromBytes(&heap, "orphan");

    var collector = Collector.init(&heap);
    defer collector.deinit();
    try std.testing.expect(collector.collect(&.{Heap.asHeapHeader(node)}) >= 1);
    // Walk the chain back down to the fixnum at its bottom; a swept
    // level would read freed memory.
    var cur = node;
    var steps: usize = 0;
    while (cur.kind() != .fixnum) : (steps += 1) {
        cur = switch (cur.kind()) {
            .persistent_vector => vector_mod.nth(cur, 0),
            .persistent_map => for ([_]u32{ 1, 2 }) |k| {
                switch (champ.mapGet(cur, value.fromKeywordId(k), &dispatch.hashValue, &dispatch.equal)) {
                    .present => |v| break v,
                    .absent => {},
                }
            } else return error.TestUnexpectedResult,
            .atom => nx.atom.getValue(cur),
            .string => Heap.valueFromHeader(.persistent_map, Heap.asHeapHeader(cur).meta.?),
            else => return error.TestUnexpectedResult,
        };
    }
    // A string level takes two steps: to its meta map, then through it.
    try std.testing.expectEqual(depth + depth / 4, steps);
    _ = collector.collect(&.{});
    try std.testing.expectEqual(@as(usize, 0), heap.liveCount());
}

// -----------------------------------------------------------------------------
// G4. Pinning
// -----------------------------------------------------------------------------

test "G4: pinned block survives without roots; unpinning releases it" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    const a = try string.fromBytes(&heap, "pinned");
    const ah = Heap.asHeapHeader(a);
    ah.setPinned();
    _ = try string.fromBytes(&heap, "not-pinned");

    var collector = Collector.init(&heap);
    defer collector.deinit();

    // First pass: `a` is pinned, other is orphan → other freed, `a` survives.
    const freed1 = collector.collect(&.{});
    try std.testing.expectEqual(@as(usize, 1), freed1);
    try std.testing.expectEqual(@as(usize, 1), heap.liveCount());
    try std.testing.expect(ah.isPinned()); // pin still set

    // Second pass: still pinned → survives again.
    const freed2 = collector.collect(&.{});
    try std.testing.expectEqual(@as(usize, 0), freed2);
    try std.testing.expectEqual(@as(usize, 1), heap.liveCount());

    // Clear pin. Third pass with empty roots → `a` is now unreachable and
    // not pinned, so it must be freed.
    ah.clearPinned();
    const freed3 = collector.collect(&.{});
    try std.testing.expectEqual(@as(usize, 1), freed3);
    try std.testing.expectEqual(@as(usize, 0), heap.liveCount());
}

// -----------------------------------------------------------------------------
// G5 (bonus): stress — many collections interleaved with many allocations.
// -----------------------------------------------------------------------------

test "G5: repeated allocate-and-collect cycles do not leak" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    var collector = Collector.init(&heap);
    defer collector.deinit();

    // 50 cycles: each cycle allocates 10 fresh strings, keeps 3
    // as roots, collects. After the last cycle, drop the last
    // roots and collect again → liveCount must be 0.
    var held: std.ArrayList(*HeapHeader) = .empty;
    defer held.deinit(std.testing.allocator);

    var cycle: usize = 0;
    while (cycle < 50) : (cycle += 1) {
        // Allocate 10 strings this cycle.
        for (0..10) |i| {
            var buf: [16]u8 = undefined;
            const txt = try std.fmt.bufPrint(&buf, "c{d}-s{d}", .{ cycle, i });
            _ = try string.fromBytes(&heap, txt);
        }
        // Keep 3 via roots carried from `held` (which is all pinned-roots).
        const fresh = try string.fromBytes(&heap, "keep1");
        try held.append(std.testing.allocator, Heap.asHeapHeader(fresh));
        if (held.items.len > 3) {
            // Drop the oldest held roots — they become unreachable.
            _ = held.orderedRemove(0);
        }
        _ = collector.collect(held.items);
    }

    // After 50 cycles with at most 3 held roots, the heap must
    // contain exactly `held.items.len` blocks (+ any metadata
    // chains, which none of these strings have).
    try std.testing.expectEqual(held.items.len, heap.liveCount());

    // Drop all held roots and collect → 0 live.
    held.clearRetainingCapacity();
    _ = collector.collect(&.{});
    try std.testing.expectEqual(@as(usize, 0), heap.liveCount());
}

// -----------------------------------------------------------------------------
// G6. A program's heap stays bounded under a forced-frequent trigger
// -----------------------------------------------------------------------------

test "G6: a loop that allocates every iteration runs in bounded heap and computes the same result" {
    // The collector runs every few kilobytes once bootstrap is done.
    var program: harness.Program = undefined;
    try program.initWith(.{ .gc_stress = true });
    defer program.deinit();
    const heap = program.v.ensureHeap();
    const after_boot = heap.live_bytes;
    // Each iteration builds and drops a 64-element vector, a string
    // and a map; only the running total survives. At a cycle every
    // 4 KiB, 2,000 iterations run a few thousand collections.
    const src =
        \\(loop [i 0 total 0]
        \\  (if (< i 2000)
        \\    (recur (inc i) (+ total (count (vec (range 64))) (count (str "item-" i)) (count (assoc {} :k i))))
        \\    total))
    ;
    const result = try program.run(src);
    // (64 + 5..10 + 1) per iteration, summed exactly.
    var expected: i64 = 0;
    var i: i64 = 0;
    while (i < 2000) : (i += 1) {
        var buf: [16]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "item-{d}", .{i});
        expected += 64 + @as(i64, @intCast(text.len)) + 1;
    }
    try std.testing.expectEqual(expected, result.asFixnum());
    try std.testing.expect(program.v.gc_cycles > 100);
    // The high-water mark stays within a fixed budget above what
    // bootstrap left live: the collector reclaimed each iteration's
    // garbage rather than letting it accumulate.
    try std.testing.expect(heap.peak_live_bytes < after_boot + 512 * 1024);
    try std.testing.expect(heap.live_bytes < after_boot + 512 * 1024);
}

test "G6b: results built across many cycles are intact: strings, vectors and closures" {
    // The collector runs every few kilobytes once bootstrap is done.
    var program: harness.Program = undefined;
    try program.initWith(.{ .gc_stress = true });
    defer program.deinit();
    const src =
        \\(defn churn [x] (count (apply str (map (fn [i] (str x i)) (range 100)))))
        \\(def fs (mapv (fn [x] (fn [] (churn x) (str "f" x))) (range 50)))
        \\(def parts (mapv (fn [f] (f)) fs))
        \\(dotimes [i 200] (churn i))
        \\[(count parts) (first parts) (last parts) (apply str (take 5 parts))]
    ;
    const result = try program.run(src);
    try std.testing.expect(program.v.gc_cycles > 0);
    try std.testing.expect(result.kind() == .persistent_vector);
    try std.testing.expectEqual(@as(i64, 50), vector_mod.nth(result, 0).asFixnum());
    try std.testing.expectEqualStrings("f0", string.asBytes(vector_mod.nth(result, 1)));
    try std.testing.expectEqualStrings("f49", string.asBytes(vector_mod.nth(result, 2)));
    try std.testing.expectEqualStrings("f0f1f2f3f4", string.asBytes(vector_mod.nth(result, 3)));
}
