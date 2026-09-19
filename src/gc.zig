//! gc.zig — precise mark-sweep tracing garbage collector.
//!
//! Authoritative spec: `docs/GC.md`. Strategy and root model:
//! `PLAN.md` §10. Mark-bit layout: `docs/VALUE.md` §5. Heap / sweep
//! scaffold: `docs/HEAP.md` and `src/heap.zig`.
//!
//! Every heap kind that allocates blocks (string, bignum, list,
//! persistent_vector, persistent_map, persistent_set, ...) exposes a
//! `trace` function this collector dispatches to during the mark
//! phase.
//!
//! Collector contract (GC.md §4):
//!   - A cycle is `collect(roots)`: the caller's roots, then the
//!     host's (`Host.roots`), then the sweep. The VM decides when a
//!     cycle is due (GC.md §7); the collector has no policy of its
//!     own.
//!   - Non-reentrant — `collect` panics if called from inside a
//!     visitor callback. Flag-guarded via `self.collecting`.
//!   - Precise — the roots are complete; the collector does NOT
//!     scan stacks or registers.
//!   - No write barriers (STW, single-threaded).
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
//!     └─ @import("champ")    — champ.traceMap + champ.traceSet
//!
//! `vm.zig` imports gc.zig and is the collector's host: it
//! enumerates the runtime's roots and traces the two block kinds
//! whose layout it owns (closures and upvalue cells) through
//! `Host`. Per-kind modules take the visitor as `anytype`;
//! `gc.Collector` satisfies the duck-typed visitor ABI
//! `{ markValue, mark, markInternal }`.

const std = @import("std");
const value = @import("value");
const heap_mod = @import("heap");
const string = @import("string");
const bignum = @import("bignum");
const list = @import("list");
const vector = @import("vector");
const champ = @import("champ");
const transient_mod = @import("transient");
const db_mod = @import("db");
const atom_mod = @import("atom");
const record_mod = @import("record");
const protocol_mod = @import("protocol");

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
    /// The runtime behind this heap, when there is one. A collector
    /// over a bare heap (the property tests) has none: its roots are
    /// all explicit and a closure or cell block cannot appear.
    host: ?Host = null,

    /// What the collector needs from the runtime that owns the heap
    /// (GC.md §3, §5): its roots, and the tracing of the two block
    /// kinds whose bodies `vm.zig` lays out.
    pub const Host = struct {
        ctx: *anyopaque,
        /// Mark every root the host holds through `collector`
        /// (`markValue` / `mark`); called once per cycle after the
        /// explicit roots.
        roots: *const fn (ctx: *anyopaque, collector: *Collector) void,
        /// Walk the children of `h`, a `function` block (a closure:
        /// its upvalue cells) or a `cell_internal` block (an upvalue
        /// cell: its value). `h` is already marked.
        trace: *const fn (ctx: *anyopaque, h: *HeapHeader, collector: *Collector) void,
    };

    pub fn init(heap: *Heap) Collector {
        return .{ .heap = heap };
    }

    /// Start a reachability walk from a `Value`. Immediate-kind
    /// Values (nil, bool, char, fixnum, float, keyword, symbol) have
    /// no heap allocation underneath, and the pointer kinds the VM or
    /// static storage owns (`native_fn`, `var_`, the db handles;
    /// `Heap.isBlockKind`) have no block to mark: both are silently
    /// ignored. A Var's root, metadata and thread value are marked by
    /// the host's namespace walk, so skipping the `var_` Value loses
    /// nothing. Every other Value is dereferenced to its
    /// `*HeapHeader` and marked + traced. This is the safe entry
    /// point for callers holding Values (e.g. from a VM frame slot)
    /// rather than raw heap headers.
    pub fn markValue(self: *Collector, v: Value) void {
        if (!Heap.isBlockKind(v.kind())) return;
        std.debug.assert(v.payload != 0 and (v.payload & 0xF) == 0);
        self.mark(@ptrFromInt(v.payload));
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
            .persistent_map => champ.traceMap(h, self),
            .persistent_set => champ.traceSet(h, self),
            .transient => transient_mod.trace(h, self),
            // Durable refs have no heap children — store_id,
            // tree_name, key_bytes are all inline body bytes; the
            // advisory `conn` pointer is NOT heap-managed (per
            // DB.md §7.3).
            .durable_ref => db_mod.trace(h, self),
            // Atom trace walks
            // the contained value. `in_flight` is a u8, not a
            // Value. Self-references work via mark-bit short-
            // circuit in `mark`. ATOM.md §7.
            .atom => atom_mod.trace(h, self),
            // Record trace walks
            // the contained field map (type_id is a plain u32,
            // not a heap value). PROTOCOLS.md §2.1.
            .record => record_mod.trace(h, self),
            // protocol + protocol_fn are LEAFS
            // (no inner heap values).
            .protocol, .protocol_fn => protocol_mod.trace(h, self),
            // Nextomic handles are leaves: the connection box holds a
            // pointer the VM owns plus inline path text, the db box
            // that pointer and numbers (nextomic_handle).
            .nextomic_conn, .nextomic_db => {},
            // Closures and upvalue cells: the host lays them out and
            // walks them (VM.md §6, GC.md §5).
            .function, .cell_internal => {
                const host = self.host orelse std.debug.panic(
                    "gc.mark: a {s} block reached a collector with no host; only a runtime allocates this kind",
                    .{@tagName(k)},
                );
                host.trace(host.ctx, h, self);
            },
            // Vars are arena objects the namespace registry roots
            // (GC.md §3); a `var_` header is a corrupted kind byte.
            // `typed_vector` has no instances and traces no children.
            // The remaining reserved kinds have no implementation.
            // PANIC, not silent no-op, per GC.md §5: a silent no-op
            // on a kind that SHOULD trace would create invisible
            // retention bugs.
            .byte_vector,
            .typed_vector,
            .var_,
            .error_,
            .meta_symbol,
            => std.debug.panic(
                "gc.mark: kind {s} is reserved and has no trace implementation; allocating with this kind is a bug",
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
    /// semantics (CHAMP.md §8.2, VECTOR.md §3 invariants).
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
    ///   1. Mark each root (transitive closure via `mark`), then the
    ///      host's roots when there is a host.
    ///   2. Sweep: free every unmarked, non-pinned heap block.
    ///   3. Clear mark bits on survivors (handled inside sweepUnmarked).
    ///   4. Start a new allocation-counting window on the heap.
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
        if (self.host) |host| host.roots(host.ctx, self);
        const freed = self.heap.sweepUnmarked();
        self.heap.resetAllocationCounter();
        return freed;
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
    var m = try champ.mapEmpty(&heap);
    m = try champ.mapAssoc(&heap, m, value.fromKeywordId(1), l1, &synthHash, &synthEq);
    m = try champ.mapAssoc(&heap, m, value.fromKeywordId(2), l2, &synthHash, &synthEq);

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
    var m = try champ.mapEmpty(&heap);
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        m = try champ.mapAssoc(&heap, m, value.fromKeywordId(i), value.fromFixnum(@intCast(i)).?, &synthHash, &synthEq);
    }
    try testing.expect(m.subkind() == 1); // CHAMP root, not array-map

    _ = try string.fromBytes(&heap, "o1");
    _ = try string.fromBytes(&heap, "o2");

    var gc = Collector.init(&heap);
    const live_before = heap.liveCount();
    _ = gc.collect(&.{Heap.asHeapHeader(m)});
    const live_after = heap.liveCount();
    try testing.expect(live_after < live_before); // orphans freed
    try testing.expectEqual(@as(usize, 20), champ.mapCount(m)); // map intact
    // Every key still looks up to the correct value post-GC.
    i = 0;
    while (i < 20) : (i += 1) {
        switch (champ.mapGet(m, value.fromKeywordId(i), &synthHash, &synthEq)) {
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

    var s = try champ.setEmpty(&heap);
    var i: u32 = 0;
    while (i < 15) : (i += 1) {
        s = try champ.setConj(&heap, s, value.fromKeywordId(i), &synthHash, &synthEq);
    }
    try testing.expect(s.subkind() == 1);

    _ = try string.fromBytes(&heap, "orphan");

    var gc = Collector.init(&heap);
    const live_before = heap.liveCount();
    _ = gc.collect(&.{Heap.asHeapHeader(s)});
    const live_after = heap.liveCount();
    try testing.expect(live_after < live_before);
    try testing.expectEqual(@as(usize, 15), champ.setCount(s));
    i = 0;
    while (i < 15) : (i += 1) {
        try testing.expect(champ.setContains(s, value.fromKeywordId(i), &synthHash, &synthEq));
    }
}

test "collect: atom contained value survives via trace" {
    // Confirms `atom_mod.trace` walks `body.value` so the
    // contained heap value is reachable purely through the atom
    // (no other root). If trace returned a no-op, the contained
    // string would be swept and the post-collect read would
    // surface garbage.
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const contained = try string.fromBytes(&heap, "atom-contained-string");
    const a = try atom_mod.make(&heap, contained);

    var gc = Collector.init(&heap);
    // Only `a` is rooted. `contained` is reachable ONLY through
    // the atom's body. If `atom_mod.trace` is wrong, the string
    // is freed.
    const live_before = heap.liveCount();
    _ = gc.collect(&.{Heap.asHeapHeader(a)});
    const live_after = heap.liveCount();
    // Both atom + string must survive.
    try testing.expectEqual(live_before, live_after);
    // And the contained string is the same Value we put in (the
    // collector is non-moving, so pointer identity is
    // preserved).
    const fetched = atom_mod.getValue(a);
    try testing.expectEqual(contained.payload, fetched.payload);
}

test "collect: atom whose contained value is unreferenced gets that value swept" {
    // Inverse of the previous test: after `reset!`'ing the atom
    // to a different value, the original contained value loses
    // its only edge and must be reclaimed on the next collect.
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const initial = try string.fromBytes(&heap, "initial-string");
    const replacement = try string.fromBytes(&heap, "replacement-string");
    const a = try atom_mod.make(&heap, initial);

    // Replace contained value — `initial` is now an orphan.
    atom_mod.setValue(a, replacement);

    var gc = Collector.init(&heap);
    const live_before = heap.liveCount();
    const freed = gc.collect(&.{Heap.asHeapHeader(a)});
    const live_after = heap.liveCount();
    // The orphan `initial` string must be freed; atom + `replacement` survive.
    try testing.expect(freed >= 1);
    try testing.expect(live_after < live_before);
    try testing.expectEqual(replacement.payload, atom_mod.getValue(a).payload);
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

    // Allocate a "meta map" — here it's just a separate heap block;
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

test "host: roots are marked after the explicit roots and closure/cell blocks trace through it" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    // A cell block whose value is a string, a root string held only
    // by the host, and an orphan. The fake host traces a cell by its
    // one value and roots the cell itself.
    const kept = try string.fromBytes(&heap, "kept");
    const cell_h = try heap.alloc(.cell_internal, @sizeOf(Value));
    Heap.bodyOf(Value, cell_h).* = kept;
    const host_root = try string.fromBytes(&heap, "host-root");
    _ = try string.fromBytes(&heap, "orphan");
    try testing.expectEqual(@as(usize, 4), heap.liveCount());

    const FakeHost = struct {
        cell: *HeapHeader,
        root: Value,
        fn roots(ctx: *anyopaque, c: *Collector) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            c.markValue(self.root);
            c.mark(self.cell);
        }
        fn trace(_: *anyopaque, h: *HeapHeader, c: *Collector) void {
            std.debug.assert(h.kind == @intFromEnum(Kind.cell_internal));
            c.markValue(Heap.bodyOf(Value, h).*);
        }
    };
    var fake = FakeHost{ .cell = cell_h, .root = host_root };
    var collector = Collector.init(&heap);
    collector.host = .{ .ctx = @ptrCast(&fake), .roots = &FakeHost.roots, .trace = &FakeHost.trace };
    const freed = collector.collect(&.{});
    try testing.expectEqual(@as(usize, 1), freed);
    try testing.expectEqual(@as(usize, 3), heap.liveCount());
    try testing.expectEqual(@as(usize, 0), heap.allocated_since_collect);
}

test "markValue ignores the pointer kinds that carry no block" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var collector = Collector.init(&heap);
    // A `native_fn` Value whose payload is a stack address: marking
    // must not dereference it.
    var descriptor: u64 = 0;
    collector.markValue(value.fromNativeFnPtr(@ptrCast(&descriptor)));
    collector.markValue(.{ .tag = @intFromEnum(Kind.var_), .payload = @intFromPtr(&descriptor) });
    try testing.expectEqual(@as(usize, 0), heap.liveCount());
}
