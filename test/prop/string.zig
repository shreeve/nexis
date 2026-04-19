//! test/prop/string.zig — randomized properties for the string heap kind.
//!
//! Exercises the full Value → dispatch → string pipeline established
//! in commit 5 (conversation `nexis-phase-1` turn 6 + 7). Each
//! property uses a fixed PRNG seed so failures reproduce.
//!
//! Properties:
//!   S1. `dispatch.equal(a, b)` is reflexive, symmetric, transitive
//!       over random strings.
//!   S2. `dispatch.equal ⇒ dispatch.hashValue equal` — the bedrock
//!       invariant, exercised on distinct-allocation equal strings.
//!   S3. Cross-kind: a string Value is never `equal` to a keyword /
//!       symbol / fixnum / char / float / nil / bool with any of
//!       their values; hashes differ as well (via `mixKindDomain`).
//!   S4. `fromBytes(bytes)` + `asBytes(v)` round-trip byte-exact
//!       across 1000 random byte sequences (including empty and
//!       non-ASCII).
//!   S5. `hashHeader(h)` matches raw `xxHash3(seed, bytes)` truncated
//!       to u32 for 1000 random strings (spec conformance with
//!       SEMANTICS.md §3.2).
//!   S6. Hash cache: a freshly-allocated string starts with
//!       `cachedHash() == null`; first `hashValue` populates the
//!       cache (when the hash is nonzero); subsequent calls return
//!       the same result without recomputing from bytes (tested by
//!       reading the raw `HeapHeader.hash` field).

const std = @import("std");
const value = @import("value");
const heap_mod = @import("heap");
const hash_mod = @import("hash");
const string = @import("string");
const dispatch = @import("dispatch");

const Value = value.Value;
const Heap = heap_mod.Heap;
const HeapHeader = heap_mod.HeapHeader;

const prng_seed: u64 = 0x7374_725F_7072_6F70; // "str_prop" ASCII LE

fn randBytes(rand: std.Random, buf: []u8, min_len: usize, max_len: usize) []const u8 {
    const len = rand.intRangeAtMost(usize, min_len, max_len);
    const n = @min(len, buf.len);
    for (buf[0..n]) |*b| b.* = rand.int(u8);
    return buf[0..n];
}

// -----------------------------------------------------------------------------
// S1. equivalence-relation laws
// -----------------------------------------------------------------------------

test "S1: dispatch.equal is reflexive, symmetric, transitive (pairwise)" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 1);
    const r = prng.random();

    var buf: [16]u8 = undefined;
    const N: usize = 64;
    const vs = try gpa.alloc(Value, N);
    defer gpa.free(vs);
    for (vs) |*slot| {
        const bytes = randBytes(r, &buf, 0, 16);
        slot.* = try string.fromBytes(&heap, bytes);
    }

    for (vs) |a| {
        try std.testing.expect(dispatch.equal(a, a));
        for (vs) |b| {
            try std.testing.expectEqual(dispatch.equal(a, b), dispatch.equal(b, a));
            if (!dispatch.equal(a, b)) continue;
            for (vs) |c| {
                if (!dispatch.equal(b, c)) continue;
                try std.testing.expect(dispatch.equal(a, c));
            }
        }
    }
}

// -----------------------------------------------------------------------------
// S2. equal ⇒ hashValue equal
// -----------------------------------------------------------------------------

test "S2: equal ⇒ hashValue equal on 500 random strings" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 2);
    const r = prng.random();

    var buf_a: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        // Generate a byte sequence, allocate two separate strings
        // with it, assert equality and hash agreement.
        const bytes = randBytes(r, &buf_a, 0, 32);
        const a = try string.fromBytes(&heap, bytes);
        const b = try string.fromBytes(&heap, bytes);
        try std.testing.expect(dispatch.equal(a, b));
        try std.testing.expectEqual(dispatch.hashValue(a), dispatch.hashValue(b));
    }
}

// -----------------------------------------------------------------------------
// S3. cross-kind non-equality + hash disjointness
// -----------------------------------------------------------------------------

test "S3: string Value is never equal to any non-string Value; hashes differ" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    const s = try string.fromBytes(&heap, "cross-kind");
    const s_hash = dispatch.hashValue(s);

    // Immediates chosen to span the non-string kind space. `dispatch.
    // hashValue` routes immediates to `v.hashImmediate()` directly.
    const others = [_]Value{
        value.nilValue(),
        value.fromBool(true),
        value.fromBool(false),
        value.fromChar('a').?,
        value.fromFixnum(42).?,
        value.fromFloat(3.14),
        value.fromKeywordId(0),
        value.fromSymbolId(0),
    };
    for (others) |o| {
        try std.testing.expect(!dispatch.equal(s, o));
        try std.testing.expect(!dispatch.equal(o, s));
        // Hashes should also differ — `mixKindDomain` stamps the
        // kind byte, so string and any immediate land in different
        // regions of u64 space.
        try std.testing.expect(s_hash != dispatch.hashValue(o));
    }
}

// -----------------------------------------------------------------------------
// S4. fromBytes + asBytes round-trip over random byte sequences
// -----------------------------------------------------------------------------

test "S4: 1000 random byte sequences round-trip byte-exact" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 4);
    const r = prng.random();

    var buf: [64]u8 = undefined;
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const bytes = randBytes(r, &buf, 0, 64);
        const v = try string.fromBytes(&heap, bytes);
        try std.testing.expectEqualSlices(u8, bytes, string.asBytes(v));
    }
}

// -----------------------------------------------------------------------------
// S5. hashHeader matches raw xxHash3 truncation
// -----------------------------------------------------------------------------

test "S5: hashHeader matches truncated xxHash3 for 1000 random strings" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 5);
    const r = prng.random();

    var buf: [48]u8 = undefined;
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const bytes = randBytes(r, &buf, 0, 48);
        const v = try string.fromBytes(&heap, bytes);
        const h = Heap.asHeapHeader(v);
        const expected: u32 = @truncate(hash_mod.hashBytes(bytes));
        try std.testing.expectEqual(expected, string.hashHeader(h));
    }
}

// -----------------------------------------------------------------------------
// S6. hash cache populates on first call; subsequent calls read cache
// -----------------------------------------------------------------------------

test "S6: hashHeader populates the cache (when nonzero) on first call" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 6);
    const r = prng.random();

    var buf: [32]u8 = undefined;
    var populated: usize = 0;
    var zero_cases: usize = 0;
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const bytes = randBytes(r, &buf, 1, 32);
        const v = try string.fromBytes(&heap, bytes);
        const h = Heap.asHeapHeader(v);

        try std.testing.expectEqual(@as(u32, 0), h.hash); // fresh cache
        const h1 = string.hashHeader(h);
        // Raw xxHash result. If nonzero, the cache must equal it.
        // If zero (exceedingly rare), the spec accepts a recompute:
        // the cache stays zero and the observable hash equals 0.
        if (h1 != 0) {
            try std.testing.expectEqual(h1, h.hash);
            populated += 1;
        } else {
            try std.testing.expectEqual(@as(u32, 0), h.hash);
            zero_cases += 1;
        }
        const h2 = string.hashHeader(h);
        try std.testing.expectEqual(h1, h2);
    }
    // Sanity: across 200 random strings we expect overwhelmingly
    // nonzero hashes. Don't hard-fail on zero_cases > 0, but require
    // at least one nonzero cache to have been populated.
    try std.testing.expect(populated > 0);
}
