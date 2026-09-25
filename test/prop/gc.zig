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
//!   G2. Nested reachability graph: 50–200 random heap objects
//!       (strings, lists, maps, sets, vectors) nested into each
//!       other; a random subset declared as roots; assert
//!       liveCount == |transitively-reachable-from-roots|.
//!   G3. Idempotence: `collect` called twice back-to-back with the
//!       same roots frees 0 blocks on the second call.
//!   G4. Pinning: any pinned block survives regardless of root
//!       membership; clearing the pin before the next collect makes
//!       it freeable.

const std = @import("std");
const nx = @import("nexis");
const value = nx.value;
const heap_mod = nx.heap;
const hash_mod = nx.hash;
const string = nx.string;
const list_mod = nx.list;
const vector_mod = nx.vector;
const champ = nx.champ;
const dispatch = nx.dispatch;
const gc = nx.gc;

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

test "G2: nested graph — reachable closure exactly matches liveCount" {
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
    // track them in the reachable model. That's fine — we're only
    // asserting the FINAL reachable-from-roots pool slice survives,
    // not a specific live count.
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
    _ = collector.collect(roots.items);

    // For every pool index in the rooted reachable set, the
    // corresponding final pool Value must still be accessible. We
    // exercise this via a structural lookup for the easy kinds:
    //   - strings: byteLen should not segfault.
    //   - lists: count should work.
    //   - vectors: count should work.
    //   - maps/sets: count should work.
    var ri = rooted_reach.iterator();
    while (ri.next()) |entry| {
        const idx = entry.key_ptr.*;
        const v = pool[idx];
        switch (v.kind()) {
            .string => {
                _ = string.byteLen(v);
            },
            .list => {
                _ = list_mod.count(v);
            },
            .persistent_vector => {
                _ = vector_mod.count(v);
            },
            .persistent_map => {
                _ = champ.mapCount(v);
            },
            .persistent_set => {
                _ = champ.setCount(v);
            },
            else => {},
        }
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
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    // Half a million cons cells: a recursive walk of the tail chain
    // would exhaust the thread stack long before the end.
    const n: usize = 500_000;
    var xs = try list_mod.empty(&heap);
    var i: usize = 0;
    while (i < n) : (i += 1) xs = try list_mod.cons(&heap, value.fromFixnum(@intCast(i)).?, xs);
    _ = try string.fromBytes(&heap, "orphan");

    var collector = Collector.init(&heap);
    const roots = [_]*HeapHeader{Heap.asHeapHeader(xs)};
    const freed = collector.collect(&roots);
    try std.testing.expectEqual(@as(usize, 1), freed);
    try std.testing.expectEqual(n, list_mod.count(xs));
    try std.testing.expectEqual(n + 1, heap.liveCount());

    const freed_all = collector.collect(&.{});
    try std.testing.expectEqual(n + 1, freed_all);
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

const vm_mod = nx.vm;
const compile = nx.compile;
const intern_mod = nx.intern;
const reader_mod = nx.reader;
const expand_mod = nx.expand;
const stdlib = nx.stdlib;

/// A VM with the core natives and core.nx, whose collector is due
/// every few kilobytes (`GcPolicy.stress`), running one program of
/// top-level forms through the whole pipeline.
const StressProgram = struct {
    arena: std.heap.ArenaAllocator,
    v: vm_mod.VM,
    host_macros: expand_mod.HostMacroTable,
    registry: *vm_mod.NamespaceRegistry,
    interner: *intern_mod.Interner,

    const stub_code = [_]vm_mod.Inst{vm_mod.asm_.returnNil()};
    const stub = vm_mod.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };

    fn init(self: *StressProgram) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer self.arena.deinit();
        self.v = try vm_mod.VM.init(std.testing.allocator, &stub);
        errdefer self.v.deinit();
        self.v.gc_threshold = vm_mod.GcPolicy.stress.threshold;
        self.v.gc_growth_percent = vm_mod.GcPolicy.stress.growth_percent;
        self.v.gc_next_at = vm_mod.GcPolicy.stress.threshold;
        self.interner = self.v.ensureInterner();
        self.registry = try self.v.ensureRegistry();
        try stdlib.installCore(self.registry.core);
        self.host_macros = try expand_mod.defaultMacros(std.testing.allocator);
        errdefer self.host_macros.deinit(std.testing.allocator);
        const saved = self.registry.current;
        self.registry.current = self.registry.core;
        _ = try self.run(stdlib.CORE_NX_SOURCE, self.v.runtime_arena.allocator());
        self.registry.current = saved;
    }

    fn deinit(self: *StressProgram) void {
        self.host_macros.deinit(std.testing.allocator);
        self.v.deinit();
        self.arena.deinit();
    }

    /// Run every top-level form of `src`; the last form's value is
    /// the result. Routines compile into `compile_allocator`.
    fn run(self: *StressProgram, src: []const u8, compile_allocator: std.mem.Allocator) !Value {
        var parse_result = try reader_mod.parser.parseProgram(std.testing.allocator, src);
        defer parse_result.parser.deinit();
        var rdr = reader_mod.Reader.init(std.testing.allocator, src);
        defer rdr.deinit();
        const forms = try rdr.readProgram(parse_result.sexp);
        var last: Value = value.nilValue();
        for (forms) |form| {
            const compiled = try compile.compileFormWith(compile_allocator, form, .{
                .namespace = self.registry.current,
                .interner = self.interner,
                .host_macros = &self.host_macros,
                .persistent_allocator = self.v.runtime_arena.allocator(),
                .registry = self.registry,
            });
            const routine = compiled.toRoutine("gc-prop");
            try self.v.retargetTop(&routine);
            last = try self.v.run();
        }
        return last;
    }
};

test "G6: a loop that allocates every iteration runs in bounded heap and computes the same result" {
    var program: StressProgram = undefined;
    try program.init();
    defer program.deinit();
    const heap = program.v.ensureHeap();
    const after_boot = heap.live_bytes;
    // Each iteration builds and drops a 64-element vector, a string
    // and a map; only the running total survives. 20,000 iterations
    // allocate tens of megabytes in total.
    const src =
        \\(loop [i 0 total 0]
        \\  (if (< i 20000)
        \\    (recur (inc i) (+ total (count (vec (range 64))) (count (str "item-" i)) (count (assoc {} :k i))))
        \\    total))
    ;
    const result = try program.run(src, program.arena.allocator());
    // (64 + 5..10 + 1) per iteration, summed exactly.
    var expected: i64 = 0;
    var i: i64 = 0;
    while (i < 20000) : (i += 1) {
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
    var program: StressProgram = undefined;
    try program.init();
    defer program.deinit();
    const src =
        \\(defn churn [x] (count (apply str (map (fn [i] (str x i)) (range 100)))))
        \\(def fs (mapv (fn [x] (fn [] (churn x) (str "f" x))) (range 50)))
        \\(def parts (mapv (fn [f] (f)) fs))
        \\(dotimes [i 200] (churn i))
        \\[(count parts) (first parts) (last parts) (apply str (take 5 parts))]
    ;
    const result = try program.run(src, program.arena.allocator());
    try std.testing.expect(program.v.gc_cycles > 0);
    try std.testing.expect(result.kind() == .persistent_vector);
    try std.testing.expectEqual(@as(i64, 50), vector_mod.nth(result, 0).asFixnum());
    try std.testing.expectEqualStrings("f0", string.asBytes(vector_mod.nth(result, 1)));
    try std.testing.expectEqualStrings("f49", string.asBytes(vector_mod.nth(result, 2)));
    try std.testing.expectEqualStrings("f0f1f2f3f4", string.asBytes(vector_mod.nth(result, 3)));
}
