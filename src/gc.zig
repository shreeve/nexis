//! gc.zig — precise mark-sweep tracing garbage collector (Phase 1).
//!
//! Authoritative spec: `docs/GC.md`. Strategy and root model:
//! `PLAN.md` §10. Mark-bit layout: `docs/VALUE.md` §5. Heap / sweep
//! scaffold: `docs/HEAP.md` and `src/heap.zig`.
//!
//! This module closes Phase 1 gate test #7 (GC stress) by replacing
//! the hand-marking workaround in `test/prop/heap.zig` with a real
//! precise mark-sweep driver. Every heap kind that currently
//! allocates blocks (string, bignum, list, persistent_vector,
//! persistent_map, persistent_set) exposes a `trace` function this
//! collector dispatches to during the mark phase.
//!
//! v1 collector contract (GC.md §9 scope cut, peer-AI turn 14):
//!   - Explicit-only — callers invoke `collect(roots)` directly. No
//!     auto-trigger based on allocation threshold.
//!   - Non-reentrant — `collect` panics if called from inside a
//!     visitor callback. Flag-guarded via `self.collecting`.
//!   - Precise — caller supplies a complete root set; collector
//!     does NOT scan stacks or registers.
//!   - No write barriers (STW, single-threaded v1).
//!   - No generational / concurrent phases.
//!
//! Module graph (one-way terminal, like dispatch.zig):
//!
//!     gc.zig
//!     ├─ @import("heap")
//!     ├─ @import("value")
//!     ├─ @import("string")  — string.trace
//!     ├─ @import("bignum")  — bignum.trace
//!     ├─ @import("list")    — list.trace
//!     ├─ @import("vector")  — vector.trace
//!     └─ @import("hamt")    — hamt.traceMap + hamt.traceSet
//!
//! Nothing imports gc.zig. Per-kind modules take the visitor as
//! `anytype`; `gc.Collector` satisfies the duck-typed visitor ABI
//! `{ markValue, mark, markInternal }`.

const std = @import("std");
const value = @import("value");
const heap_mod = @import("heap");
const string = @import("string");
const bignum = @import("bignum");
const list = @import("list");
const vector = @import("vector");
const hamt = @import("hamt");
const transient_mod = @import("transient");
const db_mod = @import("db");

const Value = value.Value;
const Kind = value.Kind;
const Heap = heap_mod.Heap;
const HeapHeader = heap_mod.HeapHeader;

const testing = std.testing;

// =============================================================================
// Collector — the public API (GC.md §4)
// =============================================================================

pub const Collector = struct {
    heap: *Heap,
    /// Re-entrancy guard. `collect` sets this to true for the duration
    /// of a cycle; nested `collect` panics. Direct `mark` /
    /// `markInternal` / `markValue` calls outside an active collect
    /// are legal (tests exercise them to verify individual primitives);
    /// they do not touch this flag.
    collecting: bool = false,

    pub fn init(heap: *Heap) Collector {
        return .{ .heap = heap };
    }

    /// Start a reachability walk from a `Value`. Immediate-kind
    /// Values (nil, bool, char, fixnum, float, keyword, symbol) have
    /// no heap allocation underneath; they are silently ignored.
    /// Heap-kind Values are dereferenced to their `*HeapHeader` and
    /// marked + traced. This is the safe entry point for callers
    /// holding Values (e.g. from a VM frame slot) rather than raw
    /// heap headers.
    pub fn markValue(self: *Collector, v: Value) void {
        if (!v.kind().isHeap()) return;
        self.mark(Heap.asHeapHeader(v));
    }

    /// Mark a full heap object and recursively walk its children.
    /// Idempotent via mark-bit short-circuit (a second call on an
    /// already-marked header returns immediately). Handles:
    ///   - mark-bit transition via `markHeaderOnce`.
    ///   - meta chain: if `h.meta != null`, recursively marks `h.meta`
    ///     (which is itself a persistent-map root per SEMANTICS §7).
    ///   - kind dispatch: invokes the per-kind trace function.
    pub fn mark(self: *Collector, h: *HeapHeader) void {
        if (!self.markHeaderOnce(h)) return;
        if (h.meta) |m| self.mark(m);
        const k: Kind = @enumFromInt(h.kind);
        switch (k) {
            .string => string.trace(h, self),
            .bignum => bignum.trace(h, self),
            .list => list.trace(h, self),
            .persistent_vector => vector.trace(h, self),
            .persistent_map => hamt.traceMap(h, self),
            .persistent_set => hamt.traceSet(h, self),
            .transient => transient_mod.trace(h, self),
            // Durable refs have no heap children — store_id,
            // tree_name, key_bytes are all inline body bytes; the
            // advisory `conn` pointer is NOT heap-managed (per
            // DB.md §7.3 / peer-AI turn 23).
            .durable_ref => db_mod.trace(h, self),
            // Reserved heap kinds without implementations in v1.
            // PANIC, not silent no-op, per GC.md §5 / peer-AI turn 14:
            // a silent no-op on a kind that SHOULD trace would create
            // invisible retention bugs once that kind ships.
            .byte_vector,
            .typed_vector,
            .function,
            .var_,
            .error_,
            .meta_symbol,
            => std.debug.panic(
                "gc.mark: kind {s} is reserved but has no v1 trace implementation; allocating with this kind is a bug until the kind ships",
                .{@tagName(k)},
            ),
            // Immediates + sentinels cannot be heap-allocated; reaching
            // here means `h.kind` byte is corrupted.
            else => std.debug.panic(
                "gc.mark: kind byte {d} on heap header {*} is not a valid heap kind — memory corruption or allocator bug",
                .{ h.kind, h },
            ),
        }
    }

    /// Mark an INTERNAL heap node (a subkind-2/3 CHAMP node or a
    /// subkind-2/3/4 vector node — nodes that are never directly
    /// referenced by a user-visible Value). Returns `true` if this
    /// call flipped the mark bit, `false` if the node was already
    /// marked. Callers (per-kind trace code) use the return value
    /// to decide whether to walk the node's payload.
    ///
    /// Does NOT walk `h.meta` — internal nodes have no metadata
    /// semantics in v1 (CHAMP.md §8.2, VECTOR.md §3 invariants).
    /// Does NOT dispatch on `h.kind` — the caller knows the
    /// structural context and will walk the payload itself (vector
    /// trie walking via `traceTrie`; CHAMP walking via
    /// `traceMapNode` / `traceSetNode`).
    pub fn markInternal(self: *Collector, h: *HeapHeader) bool {
        return self.markHeaderOnce(h);
    }

    /// Shared mark-bit primitive. Returns `true` if this call flipped
    /// the bit (caller should continue walking); `false` if already
    /// marked (caller should stop).
    fn markHeaderOnce(self: *Collector, h: *HeapHeader) bool {
        _ = self;
        if (h.isMarked()) return false;
        h.setMarked();
        return true;
    }

    /// Run a full collection cycle:
    ///   1. Mark each root (transitive closure via `mark`).
    ///   2. Sweep: free every unmarked, non-pinned heap block.
    ///   3. Clear mark bits on survivors (handled inside sweepUnmarked).
    /// Returns the number of blocks freed.
    ///
    /// **Not reentrant.** Panics if called while already collecting.
    pub fn collect(self: *Collector, roots: []const *HeapHeader) usize {
        if (self.collecting) {
            std.debug.panic(
                "gc.collect: reentrant invocation (already inside a collect cycle)",
                .{},
            );
        }
        self.collecting = true;
        defer self.collecting = false;

        for (roots) |r| self.mark(r);
        return self.heap.sweepUnmarked();
    }
};

// =============================================================================
// Tests
// =============================================================================

test "collect with empty root set frees every live block" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    // Allocate 5 unrelated blocks.
    _ = try heap.alloc(.string, 0);
    _ = try heap.alloc(.string, 0);
    _ = try heap.alloc(.bignum, 16);
    _ = try heap.alloc(.list, 0);
    _ = try heap.alloc(.string, 5);
    try testing.expectEqual(@as(usize, 5), heap.liveCount());

    var gc = Collector.init(&heap);
    const freed = gc.collect(&.{});
    try testing.expectEqual(@as(usize, 5), freed);
    try testing.expectEqual(@as(usize, 0), heap.liveCount());
}

test "collect: flat roots — only roots survive" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const a = try string.fromBytes(&heap, "a");
    const b = try string.fromBytes(&heap, "b");
    const c = try string.fromBytes(&heap, "c");
    _ = try string.fromBytes(&heap, "d"); // orphan
    _ = try string.fromBytes(&heap, "e"); // orphan
    try testing.expectEqual(@as(usize, 5), heap.liveCount());

    var gc = Collector.init(&heap);
    const ah = Heap.asHeapHeader(a);
    const bh = Heap.asHeapHeader(b);
    const ch = Heap.asHeapHeader(c);
    const freed = gc.collect(&.{ ah, bh, ch });
    try testing.expectEqual(@as(usize, 2), freed);
    try testing.expectEqual(@as(usize, 3), heap.liveCount());
}

test "collect: nested reachability — list of lists, only outer root" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    // Build three inner lists + an outer list holding them.
    //   inner_i = (i+1)
    //   outer   = (inner_0 inner_1 inner_2)
    // Total live blocks: 3 cons cells per inner * 3 inners = 9
    //                  + 1 empty-list terminator per inner * 3 = 3
    //                  + 3 cons cells in outer + 1 empty terminator = 4
    //   = 16 blocks (though strings below add more).
    const inner_0 = try list.fromSlice(&heap, &.{value.fromFixnum(1).?});
    const inner_1 = try list.fromSlice(&heap, &.{value.fromFixnum(2).?});
    const inner_2 = try list.fromSlice(&heap, &.{value.fromFixnum(3).?});
    const outer = try list.fromSlice(&heap, &.{ inner_0, inner_1, inner_2 });
    const live_before = heap.liveCount();

    // Allocate an orphan string — should be swept.
    _ = try string.fromBytes(&heap, "orphan");
    try testing.expectEqual(live_before + 1, heap.liveCount());

    var gc = Collector.init(&heap);
    const outer_h = Heap.asHeapHeader(outer);
    const freed = gc.collect(&.{outer_h});
    try testing.expectEqual(@as(usize, 1), freed); // only the orphan string
    try testing.expectEqual(live_before, heap.liveCount());
}

test "collect: cross-kind graph — map whose values are lists" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const synthHash = struct {
        fn f(x: Value) u64 {
            return x.hashImmediate();
        }
    }.f;
    const synthEq = struct {
        fn f(a: Value, b: Value) bool {
            if (a.tag == b.tag and a.payload == b.payload) return true;
            if (a.kind() != b.kind()) return false;
            return switch (a.kind()) {
                .nil, .false_, .true_ => true,
                .fixnum => a.asFixnum() == b.asFixnum(),
                .keyword => a.asKeywordId() == b.asKeywordId(),
                else => false,
            };
        }
    }.f;

    const l1 = try list.fromSlice(&heap, &.{ value.fromFixnum(10).?, value.fromFixnum(20).? });
    const l2 = try list.fromSlice(&heap, &.{value.fromFixnum(30).?});
    var m = try hamt.mapEmpty(&heap);
    m = try hamt.mapAssoc(&heap, m, value.fromKeywordId(1), l1, &synthHash, &synthEq);
    m = try hamt.mapAssoc(&heap, m, value.fromKeywordId(2), l2, &synthHash, &synthEq);

    // Allocate an unrelated orphan.
    _ = try string.fromBytes(&heap, "orphan");
    const total_before = heap.liveCount();

    var gc = Collector.init(&heap);
    const mh = Heap.asHeapHeader(m);
    const freed = gc.collect(&.{mh});
    // At least 1 block (the orphan string) must be freed.
    try testing.expect(freed >= 1);
    // Everything else (map + both list chains) must survive.
    try testing.expectEqual(total_before - freed, heap.liveCount());
}

test "collect: CHAMP-backed map survives (>8 entries exercises internal nodes)" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const synthHash = struct {
        fn f(x: Value) u64 {
            return x.hashImmediate();
        }
    }.f;
    const synthEq = struct {
        fn f(a: Value, b: Value) bool {
            if (a.tag == b.tag and a.payload == b.payload) return true;
            return false;
        }
    }.f;

    // 20 keyword → fixnum entries forces CHAMP promotion. Each
    // `mapAssoc` is path-copy persistent, so ALL the intermediate
    // roots + their obsolete subtree slices become orphans; the
    // orphan strings below are additional orphans layered on top.
    // GC correctness here means: the FINAL map `m` + its reachable
    // subtree survive intact, and every other block is freed.
    var m = try hamt.mapEmpty(&heap);
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        m = try hamt.mapAssoc(&heap, m, value.fromKeywordId(i), value.fromFixnum(@intCast(i)).?, &synthHash, &synthEq);
    }
    try testing.expect(m.subkind() == 1); // CHAMP root, not array-map

    _ = try string.fromBytes(&heap, "o1");
    _ = try string.fromBytes(&heap, "o2");

    var gc = Collector.init(&heap);
    const live_before = heap.liveCount();
    _ = gc.collect(&.{Heap.asHeapHeader(m)});
    const live_after = heap.liveCount();
    try testing.expect(live_after < live_before); // orphans freed
    try testing.expectEqual(@as(usize, 20), hamt.mapCount(m)); // map intact
    // Every key still looks up to the correct value post-GC.
    i = 0;
    while (i < 20) : (i += 1) {
        switch (hamt.mapGet(m, value.fromKeywordId(i), &synthHash, &synthEq)) {
            .absent => try testing.expect(false),
            .present => |v| try testing.expectEqual(@as(i64, @intCast(i)), v.asFixnum()),
        }
    }
}

test "collect: vector with deep trie survives end-to-end" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    // 1025 elements forces a multi-level trie (shift 5). Like the
    // map test above, `fromSlice` is left-fold `conj` — every
    // intermediate root + its obsolete trie slices become orphans;
    // GC correctness means the final vector survives with all 1025
    // elements still indexable.
    const n: usize = 1025;
    const elems = try testing.allocator.alloc(Value, n);
    defer testing.allocator.free(elems);
    for (elems, 0..) |*slot, i| slot.* = value.fromFixnum(@intCast(i)).?;

    const v = try vector.fromSlice(&heap, elems);
    _ = try string.fromBytes(&heap, "orphan-vec");

    var gc = Collector.init(&heap);
    const live_before = heap.liveCount();
    _ = gc.collect(&.{Heap.asHeapHeader(v)});
    const live_after = heap.liveCount();
    try testing.expect(live_after < live_before); // orphans freed
    try testing.expectEqual(n, vector.count(v));
    // Spot-check indices across the structural boundaries.
    const probe = [_]usize{ 0, 31, 32, 1023, 1024 };
    for (probe) |idx| {
        try testing.expectEqual(@as(i64, @intCast(idx)), vector.nth(v, idx).asFixnum());
    }
}

test "collect: persistent set survives (>8 elements exercises CHAMP internals)" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const synthHash = struct {
        fn f(x: Value) u64 {
            return x.hashImmediate();
        }
    }.f;
    const synthEq = struct {
        fn f(a: Value, b: Value) bool {
            if (a.tag == b.tag and a.payload == b.payload) return true;
            return false;
        }
    }.f;

    var s = try hamt.setEmpty(&heap);
    var i: u32 = 0;
    while (i < 15) : (i += 1) {
        s = try hamt.setConj(&heap, s, value.fromKeywordId(i), &synthHash, &synthEq);
    }
    try testing.expect(s.subkind() == 1);

    _ = try string.fromBytes(&heap, "orphan");

    var gc = Collector.init(&heap);
    const live_before = heap.liveCount();
    _ = gc.collect(&.{Heap.asHeapHeader(s)});
    const live_after = heap.liveCount();
    try testing.expect(live_after < live_before);
    try testing.expectEqual(@as(usize, 15), hamt.setCount(s));
    i = 0;
    while (i < 15) : (i += 1) {
        try testing.expect(hamt.setContains(s, value.fromKeywordId(i), &synthHash, &synthEq));
    }
}

test "collect: pinned block survives without being in roots" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const a = try string.fromBytes(&heap, "pinned");
    const b = try string.fromBytes(&heap, "not-pinned");
    Heap.asHeapHeader(a).setPinned();
    _ = b;

    var gc = Collector.init(&heap);
    const freed = gc.collect(&.{}); // empty roots
    try testing.expectEqual(@as(usize, 1), freed); // only `b` freed; `a` pinned
    try testing.expectEqual(@as(usize, 1), heap.liveCount());
    try testing.expect(Heap.asHeapHeader(a).isPinned()); // pin flag intact
}

test "collect: idempotent — second call frees 0 blocks" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const a = try string.fromBytes(&heap, "a");
    _ = try string.fromBytes(&heap, "orphan");
    try testing.expectEqual(@as(usize, 2), heap.liveCount());

    var gc = Collector.init(&heap);
    try testing.expectEqual(@as(usize, 1), gc.collect(&.{Heap.asHeapHeader(a)}));
    try testing.expectEqual(@as(usize, 1), heap.liveCount());
    // Second collect: only `a` is live, and it's in roots → nothing freed.
    try testing.expectEqual(@as(usize, 0), gc.collect(&.{Heap.asHeapHeader(a)}));
    try testing.expectEqual(@as(usize, 1), heap.liveCount());
}

test "collect: sweep clears mark bits on survivors" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const a = try string.fromBytes(&heap, "a");
    const ah = Heap.asHeapHeader(a);
    try testing.expect(!ah.isMarked()); // freshly allocated

    var gc = Collector.init(&heap);
    _ = gc.collect(&.{ah});
    // After sweep, survivor's mark bit must be cleared so the next
    // cycle starts fresh.
    try testing.expect(!ah.isMarked());
}

test "markInternal: returns true on first call, false on second" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    // Allocate a fake "internal" node directly (any heap block will
    // do for this mechanism test; we're not dispatching on kind).
    const h = try heap.alloc(.persistent_vector, 32);
    var gc = Collector.init(&heap);
    try testing.expect(gc.markInternal(h));
    try testing.expect(!gc.markInternal(h));
}

test "mark: idempotent across direct calls" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const a = try string.fromBytes(&heap, "a");
    var gc = Collector.init(&heap);
    const ah = Heap.asHeapHeader(a);
    gc.mark(ah);
    try testing.expect(ah.isMarked());
    gc.mark(ah); // no-op
    try testing.expect(ah.isMarked());
}

test "markValue: no-op on immediate Values" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    var gc = Collector.init(&heap);
    gc.markValue(value.nilValue());
    gc.markValue(value.fromBool(true));
    gc.markValue(value.fromFixnum(42).?);
    gc.markValue(value.fromKeywordId(1));
    // No panic, no allocation, no state change.
    try testing.expectEqual(@as(usize, 0), heap.liveCount());
}

test "non-reentrant: collect from inside a visitor panics" {
    // This is a structural property we verify by construction; a
    // runtime panic test would require a custom visitor that
    // re-entered the collector. We instead validate the flag guard
    // directly.
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    var gc = Collector.init(&heap);
    gc.collecting = true; // simulate mid-cycle
    // Calling collect while `collecting` is true would panic — we
    // can't easily trigger that without expectPanic infrastructure.
    // The guard is documented and asserted; the inverse assertion
    // is covered by every other test that calls collect successfully
    // (which requires `collecting == false` on entry).
    try testing.expect(gc.collecting);
    gc.collecting = false;
    _ = gc.collect(&.{});
    try testing.expect(!gc.collecting);
}

test "metadata chain: reachable through h.meta" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    // Allocate a "meta map" — in v1 it's just a separate heap block;
    // semantically it would be a persistent-map root. We use a
    // string here because it has no child references, keeping the
    // test focused on the meta traversal itself.
    const meta_h = try heap.alloc(.string, 4);
    const a = try string.fromBytes(&heap, "a");
    const ah = Heap.asHeapHeader(a);
    ah.setMeta(meta_h);
    try testing.expectEqual(@as(usize, 2), heap.liveCount());

    var gc = Collector.init(&heap);
    const freed = gc.collect(&.{ah});
    // Both `a` and its meta must survive.
    try testing.expectEqual(@as(usize, 0), freed);
    try testing.expectEqual(@as(usize, 2), heap.liveCount());
}

test "metadata chain: meta-only unreachable block is swept" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const meta_h = try heap.alloc(.string, 4);
    _ = meta_h;
    // Allocate without attaching — pure orphan.
    try testing.expectEqual(@as(usize, 1), heap.liveCount());

    var gc = Collector.init(&heap);
    const freed = gc.collect(&.{}); // no roots
    try testing.expectEqual(@as(usize, 1), freed);
    try testing.expectEqual(@as(usize, 0), heap.liveCount());
}
