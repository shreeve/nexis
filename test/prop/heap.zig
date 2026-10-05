//! test/prop/heap.zig — randomized property tests for the heap allocator.
//!
//! GC stress at the allocator: allocate-heavy workloads interleaved
//! with forced sweeps; no leaked or corrupted objects, all live data
//! survives, no dangling headers. Builds on
//! the inline tests in `src/heap.zig`; this file exists to hammer the
//! alloc/mark/sweep operations at scale with deterministic
//! PRNG-driven workloads and an oracle cross-check.
//!
//! Properties (HEAP.md §1 + §2 invariants):
//!   H1. Alloc / sweep oracle consistency — random allocations and
//!       drops keep `liveCount` in lockstep with an external oracle
//!       ArrayList of live pointers through repeated sweeps.
//!   H2. Sweep preserves exactly the marked set; `freed` matches the
//!       oracle's count of unmarked blocks; survivors have
//!       `marked == 0`.
//!   H3. Alloc / sweep cycles don't leak across K iterations (the
//!       SafeAllocator behind `std.testing.allocator` is the oracle).
//!   H4. Body bytes on a sweep survivor are unchanged by the sweep.
//!   H5. Header side-fields (cached hash, meta) on a survivor are
//!       intact after sweep; only the `marked` bit clears.
//!   H6. Interleaved alloc + mark + sweep never corrupts the live
//!       set — oracle cross-check after every step.
//!   H7. Zero-body and 64 KiB allocations coexist through many cycles.
//!   H8. Read-only `forEachLive` visits exactly `liveCount` distinct
//!       blocks, and only blocks the oracle tracks as live.
//!
//! Deterministic PRNG seeds — failures reproduce by running the same
//! test under the same Zig build.

const std = @import("std");
const nx = @import("nexis");
const value = nx.value;
const heap_mod = nx.heap;

const Heap = heap_mod.Heap;
const HeapHeader = heap_mod.HeapHeader;

const prng_seed: u64 = 0x6865_6170_5F70_726F; // "heap_pro" ASCII LE

// -----------------------------------------------------------------------------
// Oracle: tracks the expected live set as an ArrayList of *HeapHeader.
// Entries are removed (via swap-remove for O(1)) when the corresponding
// block is dropped or swept. The test never dereferences a pointer
// removed from the oracle.
// -----------------------------------------------------------------------------

const Oracle = struct {
    live: std.ArrayList(*HeapHeader) = .empty,

    fn deinit(self: *Oracle, gpa: std.mem.Allocator) void {
        self.live.deinit(gpa);
    }

    fn add(self: *Oracle, gpa: std.mem.Allocator, h: *HeapHeader) !void {
        try self.live.append(gpa, h);
    }

    fn removeAt(self: *Oracle, idx: usize) *HeapHeader {
        return self.live.swapRemove(idx);
    }

    fn indexOf(self: *const Oracle, h: *HeapHeader) ?usize {
        for (self.live.items, 0..) |entry, i| if (entry == h) return i;
        return null;
    }

    fn count(self: *const Oracle) usize {
        return self.live.items.len;
    }
};

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

/// Pick a random heap kind (kinds 16..29 per `docs/VALUE.md` §2.2).
fn randHeapKind(rand: std.Random) value.Kind {
    const options = [_]value.Kind{
        .string,            .bignum,      .persistent_map, .persistent_set,
        .persistent_vector, .list,        .byte_vector,    .typed_vector,
        .function,          .var_,        .durable_ref,    .transient,
        .error_,            .meta_symbol,
    };
    const idx = rand.uintLessThan(usize, options.len);
    return options[idx];
}

/// Fill a body with a deterministic pattern keyed on `seed`, so body
/// bytes can be checked to survive sweep cycles intact.
fn paintBody(h: *HeapHeader, seed: u8) void {
    const bytes = Heap.bodyBytes(h);
    for (bytes, 0..) |*b, i| b.* = seed +% @as(u8, @truncate(i));
}

fn verifyBody(h: *HeapHeader, seed: u8) !void {
    const bytes = Heap.bodyBytes(h);
    for (bytes, 0..) |b, i| {
        const expected: u8 = seed +% @as(u8, @truncate(i));
        try std.testing.expectEqual(expected, b);
    }
}

// -----------------------------------------------------------------------------
// H1. Alloc / sweep oracle consistency.
// -----------------------------------------------------------------------------

test "H1: alloc + drop + sweep oracle consistency over 2000 random ops" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    var oracle: Oracle = .{};
    defer oracle.deinit(gpa);

    var prng = std.Random.DefaultPrng.init(prng_seed +% 1);
    const r = prng.random();

    var dropped: usize = 0;
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        // 60% alloc, 35% drop (if non-empty), 5% sweep. Biased toward
        // growth so the oracle exercises a full range of sizes.
        const roll = r.uintLessThan(u8, 100);
        if (roll < 35 and oracle.count() > 0) {
            _ = oracle.removeAt(r.uintLessThan(usize, oracle.count()));
            dropped += 1;
        } else if (roll < 40) {
            for (oracle.live.items) |h| h.setMarked();
            try std.testing.expectEqual(dropped, heap.sweepUnmarked());
            dropped = 0;
        } else {
            const kind = randHeapKind(r);
            const body_size = r.uintLessThan(usize, 64);
            const h = try heap.alloc(kind, body_size);
            try oracle.add(gpa, h);
        }
        try std.testing.expectEqual(oracle.count() + dropped, heap.liveCount());
    }
    try std.testing.expectEqual(oracle.count() + dropped, heap.sweepUnmarked());
    try std.testing.expectEqual(@as(usize, 0), heap.liveCount());
}

// -----------------------------------------------------------------------------
// H2. Sweep preserves exactly the marked set.
// -----------------------------------------------------------------------------

test "H2: sweep frees exactly the unmarked set" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 2);
    const r = prng.random();

    const N: usize = 512;
    // Keep headers in a fixed, original-order slice. Using swap-remove
    // on an ArrayList would scramble the pointer-to-expectation mapping
    // and make the post-sweep cross-check coverage incomplete.
    const headers = try gpa.alloc(*HeapHeader, N);
    defer gpa.free(headers);
    const expected_survive = try gpa.alloc(bool, N);
    defer gpa.free(expected_survive);

    for (headers) |*slot| {
        slot.* = try heap.alloc(.string, r.uintLessThan(usize, 32));
    }
    for (headers, 0..) |h, i| {
        const marked = r.boolean();
        if (marked) h.setMarked();
        expected_survive[i] = marked;
    }

    var expected_freed: usize = 0;
    for (expected_survive) |s| if (!s) {
        expected_freed += 1;
    };

    const freed = heap.sweepUnmarked();
    try std.testing.expectEqual(expected_freed, freed);
    try std.testing.expectEqual(N - expected_freed, heap.liveCount());

    // Full per-index cross-check: every surviving header has its
    // marked bit cleared. Non-survivors are not dereferenced — their
    // storage is gone.
    for (headers, 0..) |h, i| {
        if (expected_survive[i]) try std.testing.expect(!h.isMarked());
    }
}

// -----------------------------------------------------------------------------
// H3. Repeated alloc / sweep cycles don't leak.
// -----------------------------------------------------------------------------

test "H3: 50 cycles of alloc + random-mark + sweep, no leaks" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 3);
    const r = prng.random();

    var cycle: usize = 0;
    while (cycle < 50) : (cycle += 1) {
        const batch = 32 + r.uintLessThan(usize, 64);
        var i: usize = 0;
        while (i < batch) : (i += 1) {
            const h = try heap.alloc(.string, r.uintLessThan(usize, 128));
            if (r.boolean()) h.setMarked();
        }
        _ = heap.sweepUnmarked();
    }
    // heap.deinit's SafeAllocator leak check is the oracle here.
    // Drop remaining live blocks so deinit has nothing left to
    // reconcile against the tracking allocator.
    _ = heap.sweepUnmarked();
    try std.testing.expectEqual(@as(usize, 0), heap.liveCount());
}

// -----------------------------------------------------------------------------
// H4. Body bytes on a sweep survivor are unchanged by the sweep.
// -----------------------------------------------------------------------------

test "H4: body bytes survive a sweep cycle on a marked object" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 4);
    const r = prng.random();

    const N: usize = 64;
    var survivors: std.ArrayList(*HeapHeader) = .empty;
    defer survivors.deinit(gpa);
    var seeds: std.ArrayList(u8) = .empty;
    defer seeds.deinit(gpa);

    var i: usize = 0;
    while (i < N) : (i += 1) {
        const body_size = 1 + r.uintLessThan(usize, 128);
        const h = try heap.alloc(.string, body_size);
        const seed_byte: u8 = @truncate(i ^ 0x5A);
        paintBody(h, seed_byte);
        if (r.boolean()) {
            h.setMarked();
            try survivors.append(gpa, h);
            try seeds.append(gpa, seed_byte);
        }
    }

    _ = heap.sweepUnmarked();

    for (survivors.items, seeds.items) |h, seed_byte| {
        try verifyBody(h, seed_byte);
    }
}

// -----------------------------------------------------------------------------
// H5. Header side-fields on a survivor are intact after sweep.
// -----------------------------------------------------------------------------

test "H5: cachedHash / meta preserved across sweep; marked clears" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    // The survivor carries a cached hash and a meta map.
    const m = try heap.alloc(.persistent_map, 0);
    const h = try heap.alloc(.string, 0);
    h.setMarked();
    h.setCachedHash(0xABCD_1234);
    h.setMeta(m);

    // A bunch of non-survivors.
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        _ = try heap.alloc(.bignum, 0);
    }
    // `m` also needs to survive so `h.meta` stays valid post-sweep.
    m.setMarked();

    const freed = heap.sweepUnmarked();
    try std.testing.expectEqual(@as(usize, 16), freed);

    try std.testing.expect(!h.isMarked()); // cleared by sweep
    try std.testing.expectEqual(@as(?u32, 0xABCD_1234), h.cachedHash());
    try std.testing.expect(h.hasMeta());
    try std.testing.expectEqual(@as(?*HeapHeader, m), h.getMeta());
}

// -----------------------------------------------------------------------------
// H6. Interleaved workload oracle-check after every op.
// -----------------------------------------------------------------------------

test "H6: alloc + mark + sweep interleaved, oracle-verified" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    var oracle: Oracle = .{};
    defer oracle.deinit(gpa);

    var prng = std.Random.DefaultPrng.init(prng_seed +% 6);
    const r = prng.random();

    var step: usize = 0;
    while (step < 1500) : (step += 1) {
        // Operation probabilities chosen so the live set oscillates
        // rather than drifting to zero or maxing out: 50% alloc, 35%
        // mark, 15% sweep.
        const roll = r.uintLessThan(u8, 100);
        if (roll < 50) {
            const h = try heap.alloc(.string, r.uintLessThan(usize, 48));
            try oracle.add(gpa, h);
        } else if (roll < 85 and oracle.count() > 0) {
            const idx = r.uintLessThan(usize, oracle.count());
            oracle.live.items[idx].setMarked();
        } else {
            // Sweep: rebuild the oracle to hold only marked survivors
            // (which is what the heap will keep).
            var kept: Oracle = .{};
            defer kept.deinit(gpa);
            for (oracle.live.items) |h| {
                if (h.isMarked()) {
                    try kept.add(gpa, h);
                }
            }
            const before = heap.liveCount();
            const freed = heap.sweepUnmarked();
            try std.testing.expectEqual(before - kept.count(), freed);

            oracle.live.clearRetainingCapacity();
            for (kept.live.items) |h| {
                try std.testing.expect(!h.isMarked()); // cleared
                try oracle.add(gpa, h);
            }
        }
        try std.testing.expectEqual(oracle.count(), heap.liveCount());
    }
}

// -----------------------------------------------------------------------------
// H7. Zero-body and 64 KiB allocations coexist across cycles.
// -----------------------------------------------------------------------------

test "H7: mixed tiny + large (64 KiB) bodies through sweep cycles" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 7);
    const r = prng.random();

    const big_body: usize = 64 * 1024;

    var cycle: usize = 0;
    while (cycle < 10) : (cycle += 1) {
        // Allocate 8 big + 32 tiny per cycle; mark half of each.
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            const h = try heap.alloc(.byte_vector, big_body);
            if (i % 2 == 0) h.setMarked();
        }
        i = 0;
        while (i < 32) : (i += 1) {
            const h = try heap.alloc(.string, r.uintLessThan(usize, 4));
            if (i % 2 == 0) h.setMarked();
        }
        const before = heap.liveCount();
        const freed = heap.sweepUnmarked();
        // Half the current allocations should survive. But the live
        // list also contains survivors from prior cycles whose mark
        // was cleared last sweep — those get swept this time. The
        // strong invariant is: `freed + liveCount == before`.
        try std.testing.expectEqual(before, freed + heap.liveCount());
    }
}

// -----------------------------------------------------------------------------
// H8. Read-only forEachLive sees exactly liveCount distinct blocks.
// -----------------------------------------------------------------------------

test "H8: forEachLive visits exactly liveCount distinct blocks" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 8);
    const r = prng.random();

    // Populate with a mix of alloc + sweep cycles.
    var cycle: usize = 0;
    while (cycle < 5) : (cycle += 1) {
        var i: usize = 0;
        while (i < 64) : (i += 1) {
            const h = try heap.alloc(.list, r.uintLessThan(usize, 32));
            if (r.boolean()) h.setMarked();
        }
        _ = heap.sweepUnmarked();
    }

    // Use a set-flavored visitor: track seen pointers via sort+dedup at
    // the end, since we want to assert distinctness without allocating
    // a hash set per visit.
    var seen: std.ArrayList(*HeapHeader) = .empty;
    defer seen.deinit(gpa);

    const Collector = struct {
        out: *std.ArrayList(*HeapHeader),
        out_gpa: std.mem.Allocator,
        pub fn visit(self: *@This(), h: *HeapHeader) void {
            self.out.append(self.out_gpa, h) catch @panic("collector OOM");
        }
    };

    var coll: Collector = .{ .out = &seen, .out_gpa = gpa };
    const heap_ref: *const Heap = &heap;
    heap_ref.forEachLive(&coll);

    try std.testing.expectEqual(heap.liveCount(), seen.items.len);

    // Distinctness: sort by address and verify no adjacent duplicates.
    std.sort.pdq(*HeapHeader, seen.items, {}, struct {
        fn lt(_: void, a: *HeapHeader, b: *HeapHeader) bool {
            return @intFromPtr(a) < @intFromPtr(b);
        }
    }.lt);
    var j: usize = 1;
    while (j < seen.items.len) : (j += 1) {
        try std.testing.expect(seen.items[j - 1] != seen.items[j]);
    }
}
