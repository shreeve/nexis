//! test/prop/db.zig — randomized round-trip property tests for
//! `src/db.zig` + emdb integration. Closes PLAN §20.2 gate test
//! #6 (emdb round-trip) and completes the Phase 1 gate scorecard
//! to 8/8.
//!
//! Properties (DB.md §10):
//!
//!   D1. **10k random Values across 5 named trees** (GATE #6
//!       RECEIPT): every trial writes a random Value to a
//!       `(tree_name, key_bytes)` pair selected from 5 named trees.
//!       After commit, a fresh read transaction pulls each entry
//!       back. Assert:
//!         - `dispatch.equal(v_written, v_read)` per trial.
//!         - `dispatch.hashValue(v_written) == dispatch.hashValue(v_read)`.
//!         - Named-tree independence: a key present in tree A with
//!           value vA and key present in tree B with value vB
//!           does NOT bleed between trees.
//!
//!   D2. **Reopen-connection readback**: Write 2000 values, close
//!       the Connection, reopen the same file with a fresh
//!       Connection + fresh Heap + fresh Interner, and re-read
//!       every entry. Strengthens D1 by crossing connection
//!       lifetime (peer-AI turn 23).
//!
//!   D3. **`durable_ref` identity triple**: 2000 random ref
//!       construction / equality / hash trials. No DB I/O; pure
//!       heap-value property. `(store_id, tree_name, key_bytes)`
//!       triple determines equality + hash, independent of `conn`.
//!
//!   D4. **Cross-tree independence (focused)**: Write the SAME
//!       key bytes across all 5 trees with DIFFERENT values. Each
//!       tree must return its own value.

const std = @import("std");
const value = @import("value");
const heap_mod = @import("heap");
const hash_mod = @import("hash");
const intern_mod = @import("intern");
const string = @import("string");
const bignum = @import("bignum");
const list_mod = @import("list");
const vector_mod = @import("vector");
const hamt = @import("hamt");
const codec_mod = @import("codec");
const db = @import("db");
const dispatch = @import("dispatch");

const Value = value.Value;
const Heap = heap_mod.Heap;
const Interner = intern_mod.Interner;

const prng_seed: u64 = 0x70785F_64625F00; // "px_db\0\0\0"

const tree_names = [_][]const u8{
    "users",
    "orders",
    "events",
    "cache",
    "metrics",
};

// =============================================================================
// Temp DB path helpers
// =============================================================================

fn tmpDbPath(allocator: std.mem.Allocator, suffix: []const u8) ![:0]u8 {
    const path = try std.fmt.allocPrintSentinel(allocator, "test_nexis_dbprop_{s}.emdb", .{suffix}, 0);
    cleanupDb(path);
    return path;
}

fn cleanupDb(path: [:0]const u8) void {
    _ = std.c.unlink(path.ptr);
    var buf: [256]u8 = undefined;
    const lock_path = std.fmt.bufPrintSentinel(&buf, "{s}-lock", .{path}, 0) catch return;
    _ = std.c.unlink(lock_path.ptr);
}

// =============================================================================
// Test context + random Value generator
// =============================================================================

const TestCtx = struct {
    heap: Heap,
    interner: Interner,

    fn init() TestCtx {
        return .{
            .heap = Heap.init(std.testing.allocator),
            .interner = Interner.init(std.testing.allocator),
        };
    }

    fn deinit(self: *TestCtx) void {
        self.heap.deinit();
        self.interner.deinit();
    }
};

const Gen = struct {
    ctx: *TestCtx,
    r: std.Random,

    fn scalar(self: *Gen) !Value {
        const pick = self.r.uintLessThan(u8, 10);
        return switch (pick) {
            0 => value.nilValue(),
            1 => value.fromBool(true),
            2 => value.fromBool(false),
            3 => value.fromFixnum(self.r.intRangeAtMost(i64, value.fixnum_min, value.fixnum_max)).?,
            4 => blk: {
                var c: u21 = self.r.intRangeAtMost(u21, 0, 0x10FFFF);
                if (c >= 0xD800 and c <= 0xDFFF) c = 'a';
                break :blk value.fromChar(c).?;
            },
            5 => value.fromFloat(self.r.float(f64)),
            6 => blk: {
                var buf: [16]u8 = undefined;
                const n = self.r.intRangeAtMost(usize, 1, 8);
                for (buf[0..n]) |*b| b.* = self.r.intRangeAtMost(u8, 'a', 'z');
                break :blk try self.ctx.interner.internKeywordValue(buf[0..n]);
            },
            7 => blk: {
                var buf: [16]u8 = undefined;
                const n = self.r.intRangeAtMost(usize, 1, 8);
                for (buf[0..n]) |*b| b.* = self.r.intRangeAtMost(u8, 'A', 'Z');
                break :blk try self.ctx.interner.internSymbolValue(buf[0..n]);
            },
            8 => blk: {
                var buf: [32]u8 = undefined;
                const n = self.r.uintLessThan(usize, 20);
                for (buf[0..n]) |*b| b.* = self.r.intRangeAtMost(u8, 32, 126);
                break :blk try string.fromBytes(&self.ctx.heap, buf[0..n]);
            },
            9 => blk: {
                const high: u64 = self.r.int(u64) | (@as(u64, 1) << 63);
                const neg = self.r.boolean();
                break :blk try bignum.fromLimbs(&self.ctx.heap, neg, &[_]u64{ self.r.int(u64), high });
            },
            else => unreachable,
        };
    }

    fn container(self: *Gen, depth: u8) (std.mem.Allocator.Error || error{
        InternTableFull, EmptyName, InvalidListTail, Overflow,
    })!Value {
        if (depth == 0) return try self.scalar();

        // Bias toward leaves.
        const leaf_prob: u8 = if (depth >= 2) 5 else 7;
        if (self.r.uintLessThan(u8, 10) < leaf_prob) return try self.scalar();

        const pick = self.r.uintLessThan(u8, 4);
        return switch (pick) {
            0 => try self.makeList(depth - 1),
            1 => try self.makeVector(depth - 1),
            2 => try self.makeMap(depth - 1),
            3 => try self.makeSet(depth - 1),
            else => unreachable,
        };
    }

    fn makeList(self: *Gen, depth: u8) !Value {
        const n = self.r.uintLessThan(usize, 5);
        const elems = try std.testing.allocator.alloc(Value, n);
        defer std.testing.allocator.free(elems);
        for (elems) |*slot| slot.* = try self.container(depth);
        return try list_mod.fromSlice(&self.ctx.heap, elems);
    }

    fn makeVector(self: *Gen, depth: u8) !Value {
        const n = self.r.uintLessThan(usize, 8);
        var v = try vector_mod.empty(&self.ctx.heap);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            v = try vector_mod.conj(&self.ctx.heap, v, try self.container(depth));
        }
        return v;
    }

    fn makeMap(self: *Gen, depth: u8) !Value {
        const n = self.r.uintLessThan(usize, 6);
        var m = try hamt.mapEmpty(&self.ctx.heap);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const key = try self.scalar();
            const val = try self.container(depth);
            m = try hamt.mapAssoc(&self.ctx.heap, m, key, val, &dispatch.hashValue, &dispatch.equal);
        }
        return m;
    }

    fn makeSet(self: *Gen, depth: u8) !Value {
        const n = self.r.uintLessThan(usize, 6);
        var s = try hamt.setEmpty(&self.ctx.heap);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            _ = depth;
            s = try hamt.setConj(&self.ctx.heap, s, try self.scalar(), &dispatch.hashValue, &dispatch.equal);
        }
        return s;
    }
};

// =============================================================================
// D1. Gate #6 receipt — 10k Values across 5 named trees
//
// Partitioned into 5 × 2000-trial sub-tests so that a single sub-
// test's runtime stays reasonable (matches the codec C1 shape).
// Each sub-test is independent — fresh DB file, fresh Connection,
// fresh heap, fresh interner, fresh PRNG seed offset.
// =============================================================================

fn runD1Partition(suffix: []const u8, seed_offset: u64, trials: usize) !void {
    const path = try tmpDbPath(std.testing.allocator, suffix);
    defer std.testing.allocator.free(path);
    defer cleanupDb(path);

    var ctx = TestCtx.init();
    defer ctx.deinit();

    var conn = try db.open(
        std.testing.allocator,
        &ctx.heap,
        &ctx.interner,
        path.ptr,
        .{ .allocator = std.testing.allocator, .mapSize = 64 * 1024 * 1024 },
    );
    defer db.close(&conn);

    var prng = std.Random.DefaultPrng.init(prng_seed +% seed_offset);
    var gen = Gen{ .ctx = &ctx, .r = prng.random() };

    // Pre-generate the values and their (tree_idx, key_bytes) slots
    // so we can replay the reads after commit.
    const Record = struct {
        tree_idx: u8,
        key: [16]u8,
        key_len: u8,
        v: Value,
        hash_val: u64,
    };
    const records = try std.testing.allocator.alloc(Record, trials);
    defer std.testing.allocator.free(records);

    // Batch writes into 1 transaction per 500 trials to keep txn
    // buffer usage reasonable (emdb's default mapSize).
    var trial: usize = 0;
    const batch: usize = 500;
    while (trial < trials) {
        var wtxn = try db.beginWrite(&conn);
        const end = @min(trial + batch, trials);
        while (trial < end) : (trial += 1) {
            const depth = gen.r.intRangeAtMost(u8, 0, 3);
            const v = try gen.container(depth);
            const tree_idx = gen.r.uintLessThan(u8, @intCast(tree_names.len));
            const key_len: u8 = @intCast(gen.r.intRangeAtMost(usize, 4, 16));
            var key: [16]u8 = undefined;
            for (key[0..key_len]) |*b| b.* = gen.r.intRangeAtMost(u8, 33, 126);
            try db.put(&wtxn, tree_names[tree_idx], key[0..key_len], v);
            records[trial] = .{
                .tree_idx = tree_idx,
                .key = key,
                .key_len = key_len,
                .v = v,
                .hash_val = dispatch.hashValue(v),
            };
        }
        try db.commit(&wtxn);
    }

    // Read everything back in a single read transaction.
    var rtxn = try db.beginRead(&conn);
    defer db.abortRead(&rtxn);

    for (records, 0..) |rec, i| {
        const got_opt = try db.get(&rtxn, tree_names[rec.tree_idx], rec.key[0..rec.key_len], &dispatch.hashValue, &dispatch.equal);
        if (got_opt == null) {
            std.debug.print("D1 trial {d}: tree={s} key={s} VANISHED after commit\n", .{
                i, tree_names[rec.tree_idx], rec.key[0..rec.key_len],
            });
            return error.MissingAfterCommit;
        }
        const got = got_opt.?;
        if (!dispatch.equal(rec.v, got)) {
            std.debug.print("D1 trial {d}: tree={s} key={s} kinds: written={s} got={s}\n", .{
                i, tree_names[rec.tree_idx], rec.key[0..rec.key_len],
                @tagName(rec.v.kind()), @tagName(got.kind()),
            });
            return error.UnequalAfterRoundTrip;
        }
        try std.testing.expectEqual(rec.hash_val, dispatch.hashValue(got));
    }
}

test "D1a: 2000 random Values across 5 trees (partition 1/5)" {
    try runD1Partition("d1a", 1, 2000);
}
test "D1b: 2000 random Values across 5 trees (partition 2/5)" {
    try runD1Partition("d1b", 2, 2000);
}
test "D1c: 2000 random Values across 5 trees (partition 3/5)" {
    try runD1Partition("d1c", 3, 2000);
}
test "D1d: 2000 random Values across 5 trees (partition 4/5)" {
    try runD1Partition("d1d", 4, 2000);
}
test "D1e: 2000 random Values across 5 trees (partition 5/5, aggregates 10k GATE #6 receipt)" {
    try runD1Partition("d1e", 5, 2000);
}

// =============================================================================
// D2. Reopen-connection readback (peer-AI turn 23 strengthening)
//
// Writes persist across Connection close / reopen on the same file.
// =============================================================================

test "D2: reopen-connection readback (2000 Values, close+reopen between)" {
    const path = try tmpDbPath(std.testing.allocator, "d2");
    defer std.testing.allocator.free(path);
    defer cleanupDb(path);

    // ---- Session 1: write ----
    const Record = struct {
        tree_idx: u8,
        key: [16]u8,
        key_len: u8,
        // We serialize bytes + kind expectations here rather than
        // holding `Value` across Session 1 → Session 2 (heaps differ).
        bytes: []u8,
    };
    const N: usize = 2000;
    const records = try std.testing.allocator.alloc(Record, N);
    defer {
        for (records) |r| std.testing.allocator.free(r.bytes);
        std.testing.allocator.free(records);
    }

    {
        var ctx = TestCtx.init();
        defer ctx.deinit();

        var conn = try db.open(
            std.testing.allocator,
            &ctx.heap,
            &ctx.interner,
            path.ptr,
            .{ .allocator = std.testing.allocator, .mapSize = 64 * 1024 * 1024 },
        );
        defer db.close(&conn);

        var prng = std.Random.DefaultPrng.init(prng_seed +% 0x42);
        var gen = Gen{ .ctx = &ctx, .r = prng.random() };

        var wtxn = try db.beginWrite(&conn);

        var i: usize = 0;
        while (i < N) : (i += 1) {
            const depth = gen.r.intRangeAtMost(u8, 0, 3);
            const v = try gen.container(depth);
            const tree_idx = gen.r.uintLessThan(u8, @intCast(tree_names.len));
            const key_len: u8 = @intCast(gen.r.intRangeAtMost(usize, 4, 16));
            var key: [16]u8 = undefined;
            for (key[0..key_len]) |*b| b.* = gen.r.intRangeAtMost(u8, 33, 126);

            try db.put(&wtxn, tree_names[tree_idx], key[0..key_len], v);

            // Snapshot the canonical bytes for cross-session
            // comparison.
            const bytes = try codec_mod.encode(std.testing.allocator, &ctx.interner, v);
            records[i] = .{
                .tree_idx = tree_idx,
                .key = key,
                .key_len = key_len,
                .bytes = bytes,
            };
        }

        try db.commit(&wtxn);
    }

    // ---- Session 2: reopen on a fresh heap + interner; read back ----
    //
    // Comparison strategy: Session-1 Values live in a freed heap, so
    // we can't hold them across sessions. Instead we compare each
    // read-back Value against the Value produced by decoding the
    // Session-1 encoded bytes onto the Session-2 heap. This also
    // sidesteps the map/set iteration-order wrinkle (CODEC.md §2.5):
    // two decodes of the SAME canonical bytes under the same
    // structural canonicalization always produce
    // `dispatch.equal`-matching Values, even when their internal
    // CHAMP node layouts might differ from the original write path.
    {
        var ctx = TestCtx.init();
        defer ctx.deinit();

        var conn = try db.open(
            std.testing.allocator,
            &ctx.heap,
            &ctx.interner,
            path.ptr,
            .{ .allocator = std.testing.allocator, .mapSize = 64 * 1024 * 1024 },
        );
        defer db.close(&conn);

        var rtxn = try db.beginRead(&conn);
        defer db.abortRead(&rtxn);

        for (records, 0..) |rec, i| {
            const got_opt = try db.get(&rtxn, tree_names[rec.tree_idx], rec.key[0..rec.key_len], &dispatch.hashValue, &dispatch.equal);
            try std.testing.expect(got_opt != null);
            const got = got_opt.?;

            const expected = try codec_mod.decode(
                &ctx.heap,
                &ctx.interner,
                rec.bytes,
                &dispatch.hashValue,
                &dispatch.equal,
            );

            if (!dispatch.equal(expected, got)) {
                std.debug.print("D2 trial {d}: reopen readback diverges: expected-kind={s} got-kind={s}\n", .{
                    i, @tagName(expected.kind()), @tagName(got.kind()),
                });
                return error.ReopenDivergence;
            }
            try std.testing.expectEqual(dispatch.hashValue(expected), dispatch.hashValue(got));
        }
    }
}

// =============================================================================
// D3. `durable_ref` identity-triple properties (no DB I/O)
// =============================================================================

test "D3: durable_ref identity triple determines eq+hash (2000 trials)" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 0xD3);
    const r = prng.random();

    var trial: usize = 0;
    while (trial < 2000) : (trial += 1) {
        // Random store_id.
        const store_id = @as(u128, r.int(u64)) | (@as(u128, r.int(u64)) << 64);
        // Random tree name (1..16 bytes of printable ASCII).
        var tree_buf: [16]u8 = undefined;
        const tree_len = r.intRangeAtMost(usize, 1, 16);
        for (tree_buf[0..tree_len]) |*b| b.* = r.intRangeAtMost(u8, 'a', 'z');
        // Random key bytes (1..32 bytes, any 0..255).
        var key_buf: [32]u8 = undefined;
        const key_len = r.intRangeAtMost(usize, 1, 32);
        for (key_buf[0..key_len]) |*b| b.* = r.int(u8);

        // Build TWO refs with identical identity triple; they must
        // compare equal and hash equal.
        const r1 = try db.refFromBytes(&heap, store_id, tree_buf[0..tree_len], key_buf[0..key_len]);
        const r2 = try db.refFromBytes(&heap, store_id, tree_buf[0..tree_len], key_buf[0..key_len]);
        try std.testing.expect(dispatch.equal(r1, r2));
        try std.testing.expectEqual(dispatch.hashValue(r1), dispatch.hashValue(r2));

        // Mutate one component; refs must now be unequal.
        // (Any one of store_id, tree_name, key_bytes.)
        const which = r.uintLessThan(u8, 3);
        const r3 = switch (which) {
            0 => try db.refFromBytes(&heap, store_id ^ 0x1, tree_buf[0..tree_len], key_buf[0..key_len]),
            1 => mk: {
                var alt_tree = tree_buf;
                alt_tree[0] +%= 1;
                break :mk try db.refFromBytes(&heap, store_id, alt_tree[0..tree_len], key_buf[0..key_len]);
            },
            2 => mk: {
                var alt_key = key_buf;
                alt_key[0] +%= 1;
                break :mk try db.refFromBytes(&heap, store_id, tree_buf[0..tree_len], alt_key[0..key_len]);
            },
            else => unreachable,
        };
        try std.testing.expect(!dispatch.equal(r1, r3));
    }
}

// =============================================================================
// D4. Cross-tree independence (focused)
// =============================================================================

test "D4: same key in every tree returns its own value (no cross-contamination)" {
    const path = try tmpDbPath(std.testing.allocator, "d4");
    defer std.testing.allocator.free(path);
    defer cleanupDb(path);

    var ctx = TestCtx.init();
    defer ctx.deinit();

    var conn = try db.open(
        std.testing.allocator,
        &ctx.heap,
        &ctx.interner,
        path.ptr,
        .{ .allocator = std.testing.allocator },
    );
    defer db.close(&conn);

    var wtxn = try db.beginWrite(&conn);
    for (tree_names, 0..) |tn, i| {
        const v = value.fromFixnum(@intCast(1000 + i)).?;
        try db.put(&wtxn, tn, "shared-key", v);
    }
    try db.commit(&wtxn);

    var rtxn = try db.beginRead(&conn);
    defer db.abortRead(&rtxn);
    for (tree_names, 0..) |tn, i| {
        const got = try db.get(&rtxn, tn, "shared-key", &dispatch.hashValue, &dispatch.equal);
        try std.testing.expect(got != null and got.?.kind() == .fixnum);
        try std.testing.expectEqual(@as(i64, @intCast(1000 + i)), got.?.asFixnum());
    }
}
