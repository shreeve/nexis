//! test/prop/codec.zig — randomized round-trip property tests for
//! `src/codec.zig`: every serializable value round-trips.
//!
//! Properties (CODEC.md §7):
//!
//!   C1. **100k randomized Values round-trip**, so 100k randomized
//!       equality/hash checks: for every serializable kind, nested
//!       up to depth 4,
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
//!   C5. **Hostile structure**: lengths and counts near 2^64 and
//!       counts past the input, under nesting thousands of levels
//!       deep, end in a typed error or a value without overflow, stack
//!       exhaustion or an allocation sized by the count.

const std = @import("std");
const nx = @import("nexis");
const value = nx.value;
const heap_mod = nx.heap;
const intern_mod = nx.intern;
const string = nx.string;
const bignum = nx.bignum;
const list_mod = nx.list;
const vector_mod = nx.vector;
const champ = nx.champ;
const transient = nx.transient;
const codec = nx.codec;
const dispatch = nx.dispatch;
const harness = @import("harness");

const Value = value.Value;
const Heap = heap_mod.Heap;
const Interner = intern_mod.Interner;

const prng_seed: u64 = 0x636F_6465_635F_7870; // "px_codec" LE

// =============================================================================
// Test context
// =============================================================================

const TestCtx = struct {
    allocator: std.mem.Allocator,
    heap: Heap,
    interner: Interner,

    fn init() TestCtx {
        return initWith(std.testing.allocator);
    }

    fn initWith(allocator: std.mem.Allocator) TestCtx {
        return .{
            .allocator = allocator,
            .heap = Heap.init(allocator),
            .interner = Interner.init(allocator),
        };
    }

    /// Drop every heap value; interned names stay.
    fn resetHeap(self: *TestCtx) void {
        self.heap.deinit();
        self.heap = Heap.init(self.allocator);
    }

    fn deinit(self: *TestCtx) void {
        self.heap.deinit();
        self.interner.deinit();
    }
};

// =============================================================================
// C1. 100k randomized round-trip
// =============================================================================

// 100k randomized equality/hash checks across the serializable
// kinds: each trial encodes a random Value, decodes it and
// asserts structural equality and an equal hash. Each trial's values
// die with its heap, and the allocator keeps no stack trace per
// allocation, so 100k trials cost seconds.
test "C1: 100000 random Values round-trip with equal hashes" {
    var gpa: std.heap.DebugAllocator(.{ .stack_trace_frames = 0 }) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var ctx = TestCtx.initWith(allocator);
    defer ctx.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 1);
    var gen = harness.Gen{ .heap = &ctx.heap, .interner = &ctx.interner, .allocator = allocator, .r = prng.random() };

    for (0..100_000) |_| {
        defer ctx.resetHeap();
        const depth = gen.r.intRangeAtMost(u8, 0, 4);
        const v = try gen.container(depth);

        const bytes = try codec.encode(allocator, &ctx.interner, v);
        defer allocator.free(bytes);
        const got = try codec.decode(&ctx.heap, &ctx.interner, bytes, &dispatch.hashValue, &dispatch.equal);

        try std.testing.expect(dispatch.equal(v, got));
        try std.testing.expectEqual(dispatch.hashValue(v), dispatch.hashValue(got));
    }
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
        try transient.transientFrom(&ctx.heap, try champ.mapEmpty(&ctx.heap)),
        try transient.transientFrom(&ctx.heap, try champ.setEmpty(&ctx.heap)),
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

// =============================================================================
// C5. Hostile structure: huge lengths and counts, deep nesting
// =============================================================================

test "C5: 500 hostile headers (huge lengths and counts, deep nesting) decode to a typed error or a value" {
    // The deep trials build thousands of blocks each; an arena keeps
    // them cheap to allocate and to drop.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var ctx = TestCtx.initWith(arena.allocator());
    defer ctx.deinit();
    _ = try ctx.interner.internKeywordValue("k");

    var prng = std.Random.DefaultPrng.init(prng_seed +% 5);
    const r = prng.random();
    const kinds = [_]u8{ 6, 7, 16, 17, 18, 19, 20, 21, 23 };
    const lengths = [_]u64{ std.math.maxInt(u64), std.math.maxInt(u64) - 7, 1 << 35, 1 << 20, 3 };

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var trial: usize = 0;
    while (trial < 500) : (trial += 1) {
        buf.clearRetainingCapacity();
        try buf.appendSlice(std.testing.allocator, &.{ 1, 0 });
        // A run of one-element containers, sometimes thousands deep.
        const depth = if (r.uintLessThan(u8, 8) != 0) r.uintLessThan(usize, 8) else 5000 + r.uintLessThan(usize, 64);
        for (0..depth) |_| try buf.appendSlice(std.testing.allocator, &.{ kinds[4 + r.uintLessThan(usize, 4)], 1 });
        // Then a header whose length or count is hostile.
        const kind = kinds[r.uintLessThan(usize, kinds.len)];
        try buf.append(std.testing.allocator, kind);
        if (kind == 17) try buf.append(std.testing.allocator, 0);
        if (kind == 23) try buf.append(std.testing.allocator, 1);
        var n = lengths[r.uintLessThan(usize, lengths.len)];
        while (true) {
            const byte: u8 = @intCast(n & 0x7F);
            n >>= 7;
            try buf.append(std.testing.allocator, if (n == 0) byte else byte | 0x80);
            if (n == 0) break;
        }
        for (0..r.uintLessThan(usize, 16)) |_| try buf.append(std.testing.allocator, r.int(u8));

        const live_before = ctx.heap.liveCount();
        if (codec.decode(&ctx.heap, &ctx.interner, buf.items, &dispatch.hashValue, &dispatch.equal)) |_| {} else |err| switch (err) {
            error.OutOfMemory => return error.TestUnexpectedResult,
            else => {},
        }
        // A failed decode may leave partial values behind; a count
        // past the input never gets as far as allocating for it.
        try std.testing.expect(ctx.heap.liveCount() - live_before < 4 * depth + 64);
        ctx.resetHeap();
    }
}
