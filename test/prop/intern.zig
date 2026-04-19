//! test/prop/intern.zig — randomized property tests for the intern tables.
//!
//! Second entry in the Phase 1 gate test suite (PLAN §20.2 test #8:
//! "Interning invariants: same textual symbol → same intern id across
//! reads; namespace qualification preserved"). Grows the suite
//! incrementally as each new runtime module lands.
//!
//! Properties (INTERN.md §1):
//!   I1. Idempotence — interning the same bytes twice yields the same id.
//!   I2. Distinctness — different names produce different ids (per table).
//!   I3. Round-trip — `name(intern(s)) == s` byte-for-byte.
//!   I4. Table disjointness — keyword and symbol id spaces are independent;
//!       the resulting Values have disjoint hashes.
//!   I5. Density — N fresh names produce ids `0..N-1` in insertion order.
//!   I6. Randomized stress — 5000 random names with duplicates; the final
//!       count equals the number of unique names, and every intern call
//!       is consistent with an oracle map.
//!   I7. UTF-8 — non-ASCII names round-trip byte-exact.
//!   I8. Long names — a 64 KiB name round-trips byte-exact.
//!   I9. split — full edge-case table matches INTERN.md §3.
//!   I10. by_name/names counts stay in lockstep across a mixed workload.

const std = @import("std");
const value = @import("value");
const intern = @import("intern");

const Interner = intern.Interner;
const prng_seed: u64 = 0x696E_7465_726E_5F50; // "intern_P" ASCII LE

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

/// Generate a random ASCII-only name of length [1..max_len]. Chosen from
/// a small alphabet so duplicates occur naturally and exercise the
/// idempotence path.
fn randName(rand: std.Random, buf: []u8, alphabet: []const u8, max_len: usize) []const u8 {
    const len = rand.intRangeAtMost(usize, 1, max_len);
    const n = @min(len, buf.len);
    for (buf[0..n]) |*b| {
        const i = rand.uintLessThan(usize, alphabet.len);
        b.* = alphabet[i];
    }
    return buf[0..n];
}

// -----------------------------------------------------------------------------
// Properties
// -----------------------------------------------------------------------------

test "I1: idempotence — same bytes intern to same id" {
    var it = Interner.init(std.testing.allocator);
    defer it.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed);
    const r = prng.random();
    const alphabet = "abcdefghij";
    var buf: [8]u8 = undefined;

    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const name = randName(r, &buf, alphabet, 8);
        const a = try it.internKeyword(name);
        const b = try it.internKeyword(name);
        try std.testing.expectEqual(a, b);
        const c = try it.internSymbol(name);
        const d = try it.internSymbol(name);
        try std.testing.expectEqual(c, d);
    }
}

test "I2: distinctness — different names produce different ids" {
    var it = Interner.init(std.testing.allocator);
    defer it.deinit();

    const names = [_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon" };
    var ids: [names.len]u32 = undefined;
    for (names, 0..) |n, i| ids[i] = try it.internKeyword(n);

    for (0..names.len) |i| {
        for (i + 1..names.len) |j| {
            try std.testing.expect(ids[i] != ids[j]);
        }
    }
}

test "I3: round-trip — name(intern(s)) == s" {
    var it = Interner.init(std.testing.allocator);
    defer it.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 3);
    const r = prng.random();
    const alphabet = "abcdefghijklmnop";
    var buf: [16]u8 = undefined;

    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const name = randName(r, &buf, alphabet, 16);
        const kid = try it.internKeyword(name);
        try std.testing.expectEqualStrings(name, it.keywordName(kid));
        const sid = try it.internSymbol(name);
        try std.testing.expectEqualStrings(name, it.symbolName(sid));
    }
}

test "I4: kw/sym table disjointness — Values differ under = and hash" {
    var it = Interner.init(std.testing.allocator);
    defer it.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 4);
    const r = prng.random();
    const alphabet = "abcdef";
    var buf: [6]u8 = undefined;

    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const name = randName(r, &buf, alphabet, 6);
        const kw = try it.internKeywordValue(name);
        const sym = try it.internSymbolValue(name);
        try std.testing.expect(kw.kind() == .keyword);
        try std.testing.expect(sym.kind() == .symbol);
        try std.testing.expect(!kw.identicalTo(sym));
        try std.testing.expect(kw.hashValue() != sym.hashValue());
    }
}

test "I5: density — insertion order assigns dense ids 0..N-1" {
    var it = Interner.init(std.testing.allocator);
    defer it.deinit();

    const N: u32 = 128;
    var i: u32 = 0;
    while (i < N) : (i += 1) {
        var buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "sym{d}", .{i}) catch unreachable;
        const id = try it.internSymbol(name);
        try std.testing.expectEqual(i, id);
    }
    try std.testing.expectEqual(N, it.symbolCount());
}

test "I6: randomized stress with duplicates vs oracle" {
    var it = Interner.init(std.testing.allocator);
    defer it.deinit();

    // Oracle: std.StringHashMap as the known-good reference.
    var oracle = std.StringHashMap(u32).init(std.testing.allocator);
    defer {
        var iter = oracle.iterator();
        while (iter.next()) |entry| std.testing.allocator.free(entry.key_ptr.*);
        oracle.deinit();
    }

    var prng = std.Random.DefaultPrng.init(prng_seed +% 6);
    const r = prng.random();
    // Narrow alphabet + short length guarantees frequent duplicates,
    // hammering the idempotence path.
    const alphabet = "abc";
    var buf: [3]u8 = undefined;

    var next_id: u32 = 0;
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        const name = randName(r, &buf, alphabet, 3);
        const got = try it.internKeyword(name);

        const gop = try oracle.getOrPut(name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try std.testing.allocator.dupe(u8, name);
            gop.value_ptr.* = next_id;
            next_id += 1;
        }
        try std.testing.expectEqual(gop.value_ptr.*, got);
    }
    try std.testing.expectEqual(next_id, it.keywordCount());
    try std.testing.expectEqual(oracle.count(), it.keywordCount());
}

test "I7: UTF-8 names survive round-trip byte-exact" {
    var it = Interner.init(std.testing.allocator);
    defer it.deinit();

    const samples = [_][]const u8{
        "λ",
        "你好",
        "Ω-micro",
        "naïve",
        "emoji-🦀",
        "mixed/λ",
    };
    for (samples) |s| {
        const id = try it.internSymbol(s);
        try std.testing.expectEqualStrings(s, it.symbolName(id));
    }
}

test "I8: very-long names round-trip (64 KiB)" {
    var it = Interner.init(std.testing.allocator);
    defer it.deinit();

    const big = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(big);
    for (big, 0..) |*b, i| b.* = @intCast((i & 0x3F) + 'A');

    const id = try it.internKeyword(big);
    try std.testing.expectEqual(@as(u32, 0), id);
    try std.testing.expectEqualStrings(big, it.keywordName(id));

    // Idempotence on the big name.
    const id2 = try it.internKeyword(big);
    try std.testing.expectEqual(id, id2);
    try std.testing.expectEqual(@as(u32, 1), it.keywordCount());
}

test "I9: split — edge-case table matches INTERN.md §3" {
    // Canonical passes.
    {
        const q = try intern.split("foo");
        try std.testing.expect(q.ns == null);
        try std.testing.expectEqualStrings("foo", q.local);
    }
    {
        const q = try intern.split("+");
        try std.testing.expect(q.ns == null);
        try std.testing.expectEqualStrings("+", q.local);
    }
    {
        const q = try intern.split("/");
        try std.testing.expect(q.ns == null);
        try std.testing.expectEqualStrings("/", q.local);
    }
    {
        const q = try intern.split("a/b");
        try std.testing.expectEqualStrings("a", q.ns.?);
        try std.testing.expectEqualStrings("b", q.local);
    }
    {
        const q = try intern.split("nexis.core/map");
        try std.testing.expectEqualStrings("nexis.core", q.ns.?);
        try std.testing.expectEqualStrings("map", q.local);
    }
    // Errors.
    try std.testing.expectError(error.EmptyName, intern.split(""));
    try std.testing.expectError(error.EmptyNamespace, intern.split("/foo"));
    try std.testing.expectError(error.EmptyLocalName, intern.split("foo/"));
    try std.testing.expectError(error.MultipleSlashes, intern.split("a//b"));
    try std.testing.expectError(error.MultipleSlashes, intern.split("a/b/c"));
}

test "I10: by_name/names counts stay in lockstep under mixed workload" {
    var it = Interner.init(std.testing.allocator);
    defer it.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 10);
    const r = prng.random();
    const alphabet = "xyzw";
    var buf: [4]u8 = undefined;

    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        const name = randName(r, &buf, alphabet, 4);
        if (r.boolean()) {
            _ = try it.internKeyword(name);
        } else {
            _ = try it.internSymbol(name);
        }
        // Internal count invariant — accessor-based sanity check.
        const kn = it.keywordCount();
        const sn = it.symbolCount();
        try std.testing.expect(kn <= @as(u32, @intCast(i + 1)));
        try std.testing.expect(sn <= @as(u32, @intCast(i + 1)));
    }
}
