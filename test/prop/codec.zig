//! test/prop/codec.zig — randomized round-trip property tests for
//! `src/codec.zig`. Closes PLAN §20.2 gate test #5 (codec round-trip).
//!
//! Properties (CODEC.md §7):
//!
//!   C1. **100k randomized Values round-trip** (GATE #5 RECEIPT
//!       + GATE #1 PRIMARY RECEIPT — scaled 10k → 100k in commit
//!       post-codec to satisfy PLAN §20.2 test #1 "100k+ randomized
//!       equality/hash tests across all value kinds"): for every
//!       serializable kind, nested up to depth 4,
//!       `dispatch.equal(v, decode(encode(v)))` AND
//!       `dispatch.hashValue(v) == dispatch.hashValue(decode(encode(v)))`.
//!   C2. **Re-encode byte-equality** for canonical-order kinds
//!       (scalars, strings, bignums, vectors, lists):
//!       `encode(v) == encode(decode(encode(v)))`. Excludes maps/
//!       sets per CODEC.md §2.5.
//!   C3. **Non-serializable rejection**: encoding a transient
//!       returns `UnserializableKind`.
//!   C4. **Corrupted-input defense**: 1000 trials of random bytes
//!       fed to decode either succeed (producing some Value) or
//!       return a `CodecError`; no panic, no crash, no memory
//!       corruption.

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
const transient = @import("transient");
const codec = @import("codec");
const dispatch = @import("dispatch");

const Value = value.Value;
const Heap = heap_mod.Heap;
const Interner = intern_mod.Interner;

const prng_seed: u64 = 0x636F_6465_635F_7870; // "px_codec" LE

// =============================================================================
// Random Value generator
//
// Produces a random Value of any serializable kind, nested up to
// `max_depth`. Leaf preference increases as depth grows to keep
// the recursion bounded. Every keyword / symbol name is interned
// into `ctx.interner` before being returned.
// =============================================================================

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
                // Random char (skip surrogates).
                var c: u21 = self.r.intRangeAtMost(u21, 0, 0x10FFFF);
                if (c >= 0xD800 and c <= 0xDFFF) c = 'a';
                break :blk value.fromChar(c).?;
            },
            5 => blk: {
                const f = self.r.float(f64);
                break :blk value.fromFloat(f);
            },
            6 => blk: {
                // Random keyword name.
                var buf: [32]u8 = undefined;
                const n = self.r.intRangeAtMost(usize, 1, 10);
                for (buf[0..n]) |*b| b.* = self.r.intRangeAtMost(u8, 'a', 'z');
                break :blk try self.ctx.interner.internKeywordValue(buf[0..n]);
            },
            7 => blk: {
                var buf: [32]u8 = undefined;
                const n = self.r.intRangeAtMost(usize, 1, 10);
                for (buf[0..n]) |*b| b.* = self.r.intRangeAtMost(u8, 'A', 'Z');
                break :blk try self.ctx.interner.internSymbolValue(buf[0..n]);
            },
            8 => blk: {
                // Random string.
                var buf: [32]u8 = undefined;
                const n = self.r.uintLessThan(usize, 20);
                for (buf[0..n]) |*b| b.* = self.r.intRangeAtMost(u8, 32, 126);
                break :blk try string.fromBytes(&self.ctx.heap, buf[0..n]);
            },
            9 => blk: {
                // Random bignum (force out-of-fixnum range).
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

        // Bias toward leaves as depth decreases.
        const leaf_prob: u8 = if (depth >= 3) 3 else if (depth == 2) 5 else 7;
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
        const n = self.r.uintLessThan(usize, 6);
        const elems = try std.testing.allocator.alloc(Value, n);
        defer std.testing.allocator.free(elems);
        for (elems) |*slot| slot.* = try self.container(depth);
        return try list_mod.fromSlice(&self.ctx.heap, elems);
    }

    fn makeVector(self: *Gen, depth: u8) !Value {
        const n = self.r.uintLessThan(usize, 10);
        var v = try vector_mod.empty(&self.ctx.heap);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const e = try self.container(depth);
            v = try vector_mod.conj(&self.ctx.heap, v, e);
        }
        return v;
    }

    fn makeMap(self: *Gen, depth: u8) !Value {
        const n = self.r.uintLessThan(usize, 8);
        var m = try hamt.mapEmpty(&self.ctx.heap);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            // Keys must be hashable, so we prefer scalar keys (no
            // transients etc., which we never generate anyway).
            const key = try self.scalar();
            const val = try self.container(depth);
            m = try hamt.mapAssoc(&self.ctx.heap, m, key, val, &dispatch.hashValue, &dispatch.equal);
        }
        return m;
    }

    fn makeSet(self: *Gen, depth: u8) !Value {
        const n = self.r.uintLessThan(usize, 8);
        var s = try hamt.setEmpty(&self.ctx.heap);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const e = try self.scalar();
            _ = depth; // set elements: scalars only to keep hashing deterministic
            s = try hamt.setConj(&self.ctx.heap, s, e, &dispatch.hashValue, &dispatch.equal);
        }
        return s;
    }
};

// =============================================================================
// Test context
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

// =============================================================================
// C1. 10k randomized round-trip (GATE #5 RECEIPT)
// =============================================================================

/// Shared body for the C1 partitioned round-trip test. Each partition
/// uses a distinct PRNG seed offset so the 10 sub-tests cover
/// independent value populations, aggregating to 100k unique trials.
fn runC1Partition(seed_offset: u64, trials: usize) !void {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% seed_offset);
    var gen = Gen{ .ctx = &ctx, .r = prng.random() };

    var trial: usize = 0;
    while (trial < trials) : (trial += 1) {
        const depth = gen.r.intRangeAtMost(u8, 0, 4);
        const v = try gen.container(depth);

        const bytes = try codec.encode(std.testing.allocator, &ctx.interner, v);
        defer std.testing.allocator.free(bytes);
        const got = try codec.decode(&ctx.heap, &ctx.interner, bytes, &dispatch.hashValue, &dispatch.equal);

        try std.testing.expect(dispatch.equal(v, got));
        try std.testing.expectEqual(dispatch.hashValue(v), dispatch.hashValue(got));
    }
}

// C1 is partitioned into 10 × 10_000 sub-tests so each sub-test
// completes within any reasonable per-test timeout (the Zig test
// runner + build system kills individual tests that run too long).
// Aggregate = 100,000 random trials, satisfying PLAN §20.2 gate
// test #1 "100k+ randomized equality/hash tests across all value
// kinds" — each trial encodes a random Value, decodes, and asserts
// both structural equality AND hash preservation.

test "C1a: 10000 random Values round-trip (partition 1/10)" {
    try runC1Partition(1, 10_000);
}
test "C1b: 10000 random Values round-trip (partition 2/10)" {
    try runC1Partition(2, 10_000);
}
test "C1c: 10000 random Values round-trip (partition 3/10)" {
    try runC1Partition(3, 10_000);
}
test "C1d: 10000 random Values round-trip (partition 4/10)" {
    try runC1Partition(4, 10_000);
}
test "C1e: 10000 random Values round-trip (partition 5/10)" {
    try runC1Partition(5, 10_000);
}
test "C1f: 10000 random Values round-trip (partition 6/10)" {
    try runC1Partition(6, 10_000);
}
test "C1g: 10000 random Values round-trip (partition 7/10)" {
    try runC1Partition(7, 10_000);
}
test "C1h: 10000 random Values round-trip (partition 8/10)" {
    try runC1Partition(8, 10_000);
}
test "C1i: 10000 random Values round-trip (partition 9/10)" {
    try runC1Partition(9, 10_000);
}
test "C1j: 10000 random Values round-trip (partition 10/10, closes GATE #1 aggregate to 100k)" {
    try runC1Partition(10, 10_000);
}

// =============================================================================
// C2. Byte-stable re-encode for canonical-order kinds
// =============================================================================

test "C2: re-encode(decode(encode(v))) byte-equal for canonical-order kinds" {
    // Canonical-order kinds per CODEC.md §2.5:
    //   scalars (nil/bool/char/fixnum/float/keyword/symbol),
    //   strings, bignums, vectors, lists.
    // Map/set excluded because iteration order depends on internal
    // structure which may differ between equal values built via
    // different histories.
    var ctx = TestCtx.init();
    defer ctx.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 2);
    const r = prng.random();

    // Produce 1000 canonical-order Values of depth 0..3.
    var trial: usize = 0;
    while (trial < 1000) : (trial += 1) {
        // Pick a kind: scalar, string, bignum, vector, or list.
        // Build by hand to avoid accidentally nesting maps/sets.
        const v = try canonicalKindGen(&ctx, r, 3);

        const bytes1 = try codec.encode(std.testing.allocator, &ctx.interner, v);
        defer std.testing.allocator.free(bytes1);
        const got = try codec.decode(&ctx.heap, &ctx.interner, bytes1, &dispatch.hashValue, &dispatch.equal);
        const bytes2 = try codec.encode(std.testing.allocator, &ctx.interner, got);
        defer std.testing.allocator.free(bytes2);

        try std.testing.expectEqualSlices(u8, bytes1, bytes2);
    }
}

/// Generate a Value of only canonical-order kinds (no maps/sets).
fn canonicalKindGen(ctx: *TestCtx, r: std.Random, depth: u8) !Value {
    if (depth == 0) return try canonicalScalar(ctx, r);

    const pick = r.uintLessThan(u8, 3);
    return switch (pick) {
        0 => try canonicalScalar(ctx, r),
        1 => blk: {
            // List
            const n = r.uintLessThan(usize, 6);
            const elems = try std.testing.allocator.alloc(Value, n);
            defer std.testing.allocator.free(elems);
            for (elems) |*slot| slot.* = try canonicalKindGen(ctx, r, depth - 1);
            break :blk try list_mod.fromSlice(&ctx.heap, elems);
        },
        2 => blk: {
            // Vector
            const n = r.uintLessThan(usize, 10);
            var v = try vector_mod.empty(&ctx.heap);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const e = try canonicalKindGen(ctx, r, depth - 1);
                v = try vector_mod.conj(&ctx.heap, v, e);
            }
            break :blk v;
        },
        else => unreachable,
    };
}

fn canonicalScalar(ctx: *TestCtx, r: std.Random) !Value {
    const pick = r.uintLessThan(u8, 10);
    return switch (pick) {
        0 => value.nilValue(),
        1 => value.fromBool(true),
        2 => value.fromBool(false),
        3 => value.fromFixnum(r.intRangeAtMost(i64, value.fixnum_min, value.fixnum_max)).?,
        4 => blk: {
            var c: u21 = r.intRangeAtMost(u21, 0, 0x10FFFF);
            if (c >= 0xD800 and c <= 0xDFFF) c = 'a';
            break :blk value.fromChar(c).?;
        },
        5 => value.fromFloat(r.float(f64)),
        6 => blk: {
            var buf: [16]u8 = undefined;
            const n = r.intRangeAtMost(usize, 1, 10);
            for (buf[0..n]) |*b| b.* = r.intRangeAtMost(u8, 'a', 'z');
            break :blk try ctx.interner.internKeywordValue(buf[0..n]);
        },
        7 => blk: {
            var buf: [16]u8 = undefined;
            const n = r.intRangeAtMost(usize, 1, 10);
            for (buf[0..n]) |*b| b.* = r.intRangeAtMost(u8, 'A', 'Z');
            break :blk try ctx.interner.internSymbolValue(buf[0..n]);
        },
        8 => blk: {
            var buf: [32]u8 = undefined;
            const n = r.uintLessThan(usize, 20);
            for (buf[0..n]) |*b| b.* = r.intRangeAtMost(u8, 32, 126);
            break :blk try string.fromBytes(&ctx.heap, buf[0..n]);
        },
        9 => blk: {
            const high: u64 = r.int(u64) | (@as(u64, 1) << 63);
            const neg = r.boolean();
            break :blk try bignum.fromLimbs(&ctx.heap, neg, &[_]u64{ r.int(u64), high });
        },
        else => unreachable,
    };
}

// =============================================================================
// C3. Non-serializable rejection
// =============================================================================

test "C3: encoding a transient returns UnserializableKind" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const kinds = [_]Value{
        try transient.transientFrom(&ctx.heap, try hamt.mapEmpty(&ctx.heap)),
        try transient.transientFrom(&ctx.heap, try hamt.setEmpty(&ctx.heap)),
        try transient.transientFrom(&ctx.heap, try vector_mod.empty(&ctx.heap)),
    };
    for (kinds) |v| {
        try std.testing.expectError(
            codec.CodecError.UnserializableKind,
            codec.encode(std.testing.allocator, &ctx.interner, v),
        );
    }
}

// =============================================================================
// C4. Corrupted-input defense
// =============================================================================

test "C4: 1000 random byte slices fed to decode never panic" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 4);
    const r = prng.random();

    var trial: usize = 0;
    while (trial < 1000) : (trial += 1) {
        const n = r.uintLessThan(usize, 64);
        const bytes = try std.testing.allocator.alloc(u8, n);
        defer std.testing.allocator.free(bytes);
        for (bytes) |*b| b.* = r.int(u8);

        // The call must either return a Value (valid decode) or a
        // typed error (any CodecError or error propagated from the
        // constructors). Under test allocator instrumentation, a
        // successful decode's allocations are cleaned up by
        // `ctx.heap.deinit()` at test teardown.
        if (codec.decode(&ctx.heap, &ctx.interner, bytes, &dispatch.hashValue, &dispatch.equal)) |_| {
            // Successful decode — Value is tracked by ctx.heap.
        } else |_| {
            // Any error is acceptable; the point is no panic / crash /
            // memory corruption.
        }
    }
}
