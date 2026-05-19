//! string.zig — UTF-8 string heap kind (Phase 1).
//!
//! Authoritative spec: `docs/STRING.md`. Physical storage lives on
//! `src/heap.zig`; semantic rules come from `docs/SEMANTICS.md` §2.4
//! (byte equality) and §3.2 (hash). This is the first real heap kind,
//! so it exercises the full heap→dispatch→hashValue pipeline end to
//! end and sets the pattern every subsequent heap kind (bignum, list,
//! persistent_map, …) will follow.
//!
//! v1 scope: **subkind 1 (heap string) only.** Body is raw UTF-8
//! bytes with no length prefix; length recovered from the heap block.
//! SSO (subkind 0) and zero-copy (subkind 2) are reserved for future
//! commits.
//!
//! Invariants (STRING.md §2):
//!   - Bytes are copied into a fresh heap allocation on `fromBytes`.
//!   - No UTF-8 validation at the storage boundary (reader + codec
//!     are the validators; this module is byte-blob underneath).
//!   - No interning, no content dedup — two `fromBytes("foo")` calls
//!     produce two `*HeapHeader`s that are byte-equal but not pointer-
//!     identical.
//!   - Cached hash of 0 is not stored; that string recomputes on next
//!     access (VALUE.md §4 spec decision).

const std = @import("std");
const value = @import("value");
const heap_mod = @import("heap");
const hash_mod = @import("hash");

const Value = value.Value;
const Kind = value.Kind;
const Heap = heap_mod.Heap;
const HeapHeader = heap_mod.HeapHeader;

const testing = std.testing;

// =============================================================================
// Subkind discriminator
// =============================================================================

pub const subkind_heap: u16 = 1;
// Reserved (not implemented in v1): subkind_inline = 0 (SSO),
// subkind_zero_copy = 2 (mmap slice over emdb page).

// =============================================================================
// Public API
// =============================================================================

/// Allocate a new heap string from raw UTF-8 bytes. Bytes are copied
/// into a fresh `.string` heap block. Caller is responsible for
/// passing well-formed UTF-8 — this is the low-level storage
/// constructor, not a validating one (STRING.md §2 invariant 4).
pub fn fromBytes(heap: *Heap, bytes: []const u8) !Value {
    const h = try heap.alloc(.string, bytes.len);
    const body = Heap.bodyBytes(h);
    std.debug.assert(body.len == bytes.len);
    if (bytes.len > 0) @memcpy(body, bytes);
    return valueFrom(h);
}

/// Byte view over a string Value. Panics if `v.kind() != .string`.
/// For subkind 1 this is the body of the heap block. When SSO /
/// zero-copy subkinds land, the same API returns the logical byte
/// view regardless of storage; callers must not assume the returned
/// pointer lives on the runtime heap.
pub fn asBytes(v: Value) []const u8 {
    std.debug.assert(v.kind() == .string);
    const h = Heap.asHeapHeader(v);
    if (std.debug.runtime_safety) {
        std.debug.assert(v.subkind() == subkind_heap);
    }
    return Heap.bodyBytes(h);
}

/// Cheaper than `asBytes` when only the byte length is needed — still
/// walks to the header but skips the body-pointer arithmetic.
pub fn byteLen(v: Value) usize {
    return asBytes(v).len;
}

/// Per-kind hash entry point — called by `dispatch.heapHashValue`
/// once the kind switch lands on `.string`. Reads
/// `HeapHeader.cachedHash`; if uncomputed (zero), computes
/// `xxHash3(seed, bodyBytes(h))` truncated to u32, stores it in the
/// cache **only when nonzero** (per VALUE.md §4 spec), and returns it.
pub fn hashHeader(h: *HeapHeader) u32 {
    if (std.debug.runtime_safety) {
        std.debug.assert(h.kind == @intFromEnum(Kind.string));
    }
    if (h.cachedHash()) |cached| return cached;
    const bytes = Heap.bodyBytes(h);
    const raw_u64 = hash_mod.hashBytes(bytes);
    const raw: u32 = @truncate(raw_u64);
    if (raw != 0) h.setCachedHash(raw);
    return raw;
}

/// Per-kind equality entry point. Byte-for-byte comparison over two
/// string headers' bodies. The dispatcher has already verified both
/// are `.string`; we assert as defense-in-depth in safe builds.
/// GC trace function (GC.md §5). Strings are leaf heap kinds — their
/// bodies are raw UTF-8 bytes with no heap references. The collector
/// has already marked `h` before dispatching here; there's nothing
/// more for us to do. Metadata is handled by the collector centrally.
pub fn trace(h: *HeapHeader, visitor: anytype) void {
    _ = h;
    _ = visitor;
}

pub fn bytesEqual(a: *HeapHeader, b: *HeapHeader) bool {
    if (std.debug.runtime_safety) {
        std.debug.assert(a.kind == @intFromEnum(Kind.string));
        std.debug.assert(b.kind == @intFromEnum(Kind.string));
    }
    if (a == b) return true; // same header -> trivially equal
    const ab = Heap.bodyBytes(a);
    const bb = Heap.bodyBytes(b);
    return std.mem.eql(u8, ab, bb);
}

// =============================================================================
// Codepoint helpers (Phase 5.2a — peer-AI turn 77)
// =============================================================================
//
// The language-level surface (`(count s)`, `(nth s i)`, `(subs s
// start end)`) indexes by Unicode SCALAR / codepoint, NOT by byte
// and NOT by grapheme cluster. The storage body remains raw UTF-8
// bytes; these helpers walk it once per call to convert codepoint
// indices into byte offsets.
//
// Frozen contract (STRING.md §7):
//   - All four ops return `error.InvalidUtf8` on a malformed body
//     mid-walk. The runtime caller (`stdlib.zig`) maps that to
//     `:utf8-error` (catchable). v1's storage layer does not
//     pre-validate bytes; the user's source had to be well-formed
//     to reach a string Value, but a fuzzer / corrupt-codec path
//     could produce one.
//   - Codepoint count is NOT cached on the HeapHeader. Phase 6 may
//     add a cache slot if profiling shows hot use.

/// Total number of Unicode codepoints in `v`. O(byteLen). Returns
/// `error.InvalidUtf8` if the body contains an invalid byte
/// sequence.
pub fn codepointCount(v: Value) error{InvalidUtf8}!usize {
    const bytes = asBytes(v);
    var count: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch return error.InvalidUtf8;
        if (i + seq_len > bytes.len) return error.InvalidUtf8;
        // Validate the sequence (catches lone continuation bytes
        // and over-long encodings).
        _ = std.unicode.utf8Decode(bytes[i..][0..seq_len]) catch return error.InvalidUtf8;
        i += seq_len;
        count += 1;
    }
    return count;
}

/// Unicode scalar at codepoint index `i`. Returns `error.OutOfBounds`
/// if `i >= codepointCount(v)`, `error.InvalidUtf8` on a malformed
/// byte sequence anywhere up to position `i`.
pub fn codepointAt(v: Value, i: usize) error{ OutOfBounds, InvalidUtf8 }!u21 {
    const bytes = asBytes(v);
    var byte_pos: usize = 0;
    var cp_pos: usize = 0;
    while (byte_pos < bytes.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(bytes[byte_pos]) catch return error.InvalidUtf8;
        if (byte_pos + seq_len > bytes.len) return error.InvalidUtf8;
        const scalar = std.unicode.utf8Decode(bytes[byte_pos..][0..seq_len]) catch return error.InvalidUtf8;
        if (cp_pos == i) return scalar;
        byte_pos += seq_len;
        cp_pos += 1;
    }
    return error.OutOfBounds;
}

/// Convert a codepoint range `[start, end)` to a byte range. Both
/// endpoints are codepoint-indexed. Returns `error.OutOfBounds` if
/// `start > end`, `start > codepointCount(v)`, or `end >
/// codepointCount(v)`; `error.InvalidUtf8` on malformed bytes.
///
/// Caller responsibility: `start` and `end` must already be
/// non-negative — the public API rejects negatives as
/// `:index-out-of-bounds` BEFORE calling this helper, so the helper
/// itself only sees `usize` indices.
pub fn byteRangeForCodepoints(
    v: Value,
    start: usize,
    end: usize,
) error{ OutOfBounds, InvalidUtf8 }!struct { start: usize, end: usize } {
    if (start > end) return error.OutOfBounds;
    const bytes = asBytes(v);
    var byte_pos: usize = 0;
    var cp_pos: usize = 0;
    var byte_start: ?usize = if (start == 0) 0 else null;
    while (byte_pos < bytes.len) {
        if (cp_pos == start) byte_start = byte_pos;
        if (cp_pos == end) {
            return .{ .start = byte_start.?, .end = byte_pos };
        }
        const seq_len = std.unicode.utf8ByteSequenceLength(bytes[byte_pos]) catch return error.InvalidUtf8;
        if (byte_pos + seq_len > bytes.len) return error.InvalidUtf8;
        _ = std.unicode.utf8Decode(bytes[byte_pos..][0..seq_len]) catch return error.InvalidUtf8;
        byte_pos += seq_len;
        cp_pos += 1;
    }
    // Reached end of bytes. Final positions land iff cp_pos
    // matches the requested boundary.
    if (cp_pos == end) {
        if (byte_start == null) {
            if (cp_pos == start) byte_start = byte_pos else return error.OutOfBounds;
        }
        return .{ .start = byte_start.?, .end = byte_pos };
    }
    return error.OutOfBounds;
}

// =============================================================================
// Private helpers
// =============================================================================

/// Pack a fully-constructed `.string` header into a Value with the
/// correct kind, subkind, and zeroed flags/aux. Factored so the SSO
/// and zero-copy subkind paths can compose cleanly when they land.
fn valueFrom(h: *HeapHeader) Value {
    return .{
        .tag = @as(u64, @intFromEnum(Kind.string)) |
            (@as(u64, subkind_heap) << 16),
        .payload = @intFromPtr(h),
    };
}

// =============================================================================
// Inline tests — per-module basics. Randomized sweeps live in
// test/prop/heap.zig (future) or test/prop/string.zig.
// =============================================================================

test "fromBytes + asBytes: round-trip byte-exact" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const cases = [_][]const u8{
        "",
        "a",
        "foo",
        "the quick brown fox",
        "λ", // U+03BB, 2 bytes
        "你好", // 6 bytes
        "emoji-🦀", // 10 bytes
    };
    for (cases) |s| {
        const v = try fromBytes(&heap, s);
        try testing.expect(v.kind() == .string);
        try testing.expectEqual(@as(u16, subkind_heap), v.subkind());
        try testing.expectEqualStrings(s, asBytes(v));
        try testing.expectEqual(s.len, byteLen(v));
    }
}

test "fromBytes: empty string is legal and round-trips" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const v = try fromBytes(&heap, "");
    try testing.expect(v.kind() == .string);
    try testing.expectEqual(@as(usize, 0), byteLen(v));
    try testing.expectEqualStrings("", asBytes(v));
}

test "fromBytes: 64 KiB body round-trips" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const big = try testing.allocator.alloc(u8, 64 * 1024);
    defer testing.allocator.free(big);
    for (big, 0..) |*b, i| b.* = @intCast((i * 7 + 3) & 0xFF);

    const v = try fromBytes(&heap, big);
    try testing.expectEqual(big.len, byteLen(v));
    try testing.expectEqualSlices(u8, big, asBytes(v));
}

test "bytesEqual: byte-for-byte equality; identity short-circuit" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const a = try fromBytes(&heap, "hello");
    const b = try fromBytes(&heap, "hello");
    const c = try fromBytes(&heap, "world");

    const ah = Heap.asHeapHeader(a);
    const bh = Heap.asHeapHeader(b);
    const ch = Heap.asHeapHeader(c);

    // Distinct allocations, byte-equal content.
    try testing.expect(ah != bh);
    try testing.expect(bytesEqual(ah, bh));
    try testing.expect(!bytesEqual(ah, ch));
    // Identity short-circuit.
    try testing.expect(bytesEqual(ah, ah));
}

test "hashHeader: deterministic, matches raw xxHash3, caches nonzero results" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const v = try fromBytes(&heap, "consistent");
    const h = Heap.asHeapHeader(v);

    // Pre-hash: cache should be clear.
    try testing.expectEqual(@as(u32, 0), h.hash);
    try testing.expect(h.cachedHash() == null);

    const h1 = hashHeader(h);
    const h2 = hashHeader(h);
    try testing.expectEqual(h1, h2);

    // Spec-conformance: hashHeader output matches truncated xxHash3 on
    // the byte body.
    const expected: u32 = @truncate(hash_mod.hashBytes("consistent"));
    try testing.expectEqual(expected, h1);

    // Cache was populated (assuming expected != 0, which for this
    // input it is). A real zero hash would not be cached — covered
    // separately if a test input triggers it.
    if (expected != 0) {
        try testing.expectEqual(expected, h.hash);
        try testing.expectEqual(@as(?u32, expected), h.cachedHash());
    }
}

test "hashHeader: equal strings have equal hashes (different headers)" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const a = try fromBytes(&heap, "equal-hash-test");
    const b = try fromBytes(&heap, "equal-hash-test");
    const ha = hashHeader(Heap.asHeapHeader(a));
    const hb = hashHeader(Heap.asHeapHeader(b));
    try testing.expectEqual(ha, hb);
}

test "hashHeader: empty string produces the canonical xxHash3 of empty bytes" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const v = try fromBytes(&heap, "");
    const expected: u32 = @truncate(hash_mod.hashBytes(""));
    try testing.expectEqual(expected, hashHeader(Heap.asHeapHeader(v)));
}

test "byteLen: cheap length access" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const v = try fromBytes(&heap, "five!");
    try testing.expectEqual(@as(usize, 5), byteLen(v));
}

test "valueFrom: tag encodes kind + subkind, payload = *HeapHeader" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const v = try fromBytes(&heap, "x");
    try testing.expectEqual(@intFromEnum(Kind.string), @intFromEnum(v.kind()));
    try testing.expectEqual(@as(u16, subkind_heap), v.subkind());
    const h = Heap.asHeapHeader(v);
    try testing.expectEqual(@intFromPtr(h), v.payload);
}

test "size boundaries 0/1/15/16/17 all heap-stored in v1" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const sizes = [_]usize{ 0, 1, 15, 16, 17 };
    for (sizes) |n| {
        const buf = try testing.allocator.alloc(u8, n);
        defer testing.allocator.free(buf);
        for (buf, 0..) |*b, i| b.* = @intCast(('A' + (i % 26)));
        const v = try fromBytes(&heap, buf);
        try testing.expectEqual(@as(u16, subkind_heap), v.subkind());
        try testing.expectEqual(n, byteLen(v));
        try testing.expectEqualSlices(u8, buf, asBytes(v));
    }
}

test "multiple distinct strings coexist on one heap" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    var values: [8]Value = undefined;
    for (&values, 0..) |*slot, i| {
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "str-{d}", .{i}) catch unreachable;
        slot.* = try fromBytes(&heap, s);
    }
    try testing.expectEqual(@as(usize, 8), heap.liveCount());
    for (values, 0..) |v, i| {
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "str-{d}", .{i}) catch unreachable;
        try testing.expectEqualStrings(s, asBytes(v));
    }
}

test "multi-byte UTF-8 code points survive round-trip byte-exact" {
    // Per SEMANTICS §2.4 strings are byte blobs; no normalization,
    // no code-point iteration. Still, explicitly pin a few common
    // multi-byte sequences so an accidental byte-vs-code-point bug
    // surfaces here rather than in a downstream reader test.
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const cases = [_]struct { s: []const u8, len: usize }{
        .{ .s = "\xC3\xA9", .len = 2 }, // é U+00E9
        .{ .s = "\xE2\x82\xAC", .len = 3 }, // € U+20AC
        .{ .s = "\xF0\x9F\x98\x80", .len = 4 }, // 😀 U+1F600
        .{ .s = "A\xC3\xA9B\xE2\x82\xAC", .len = 7 }, // mixed: A(1)+é(2)+B(1)+€(3)
    };
    for (cases) |c| {
        const v = try fromBytes(&heap, c.s);
        try testing.expectEqual(c.len, byteLen(v));
        try testing.expectEqualSlices(u8, c.s, asBytes(v));
    }
}

test "malformed UTF-8 bytes round-trip byte-exact (byte-blob semantics)" {
    // The low-level storage constructor does not validate UTF-8
    // (STRING.md §2 invariant 4). A raw byte stream that fails
    // Unicode validation still round-trips intact so callers holding
    // arbitrary byte data aren't silently corrupted.
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const malformed = [_][]const u8{
        "\xC0\x80", // overlong encoding of NUL (invalid UTF-8)
        "\x80\x80\x80", // continuation bytes with no lead
        "\xFF\xFE", // never-valid UTF-8 bytes
        "A\x00B", // embedded NUL (valid UTF-8, but trips C-string code)
    };
    for (malformed) |m| {
        const v = try fromBytes(&heap, m);
        try testing.expectEqual(m.len, byteLen(v));
        try testing.expectEqualSlices(u8, m, asBytes(v));
        // And equality still holds byte-for-byte on a copy.
        const v2 = try fromBytes(&heap, m);
        try testing.expect(bytesEqual(Heap.asHeapHeader(v), Heap.asHeapHeader(v2)));
    }
}

// =============================================================================
// Codepoint helper tests (Phase 5.2a — peer-AI turn 77)
// =============================================================================

test "codepointCount: ASCII + multi-byte sequences" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const cases = [_]struct { s: []const u8, count: usize }{
        .{ .s = "", .count = 0 },
        .{ .s = "a", .count = 1 },
        .{ .s = "hello", .count = 5 },
        .{ .s = "é", .count = 1 }, // U+00E9, 2 bytes
        .{ .s = "aéb", .count = 3 }, // 1 + 2 + 1 bytes
        .{ .s = "你好", .count = 2 }, // 3 + 3 bytes
        .{ .s = "🦀", .count = 1 }, // 4 bytes
        .{ .s = "A🦀é€", .count = 4 }, // 1 + 4 + 2 + 3 bytes = 10
    };
    for (cases) |c| {
        const v = try fromBytes(&heap, c.s);
        try testing.expectEqual(c.count, try codepointCount(v));
    }
}

test "codepointCount: invalid UTF-8 returns error" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const v = try fromBytes(&heap, "\xC0\x80"); // overlong NUL
    try testing.expectError(error.InvalidUtf8, codepointCount(v));
}

test "codepointAt: returns Unicode scalar at codepoint index" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const v = try fromBytes(&heap, "aéb🦀");
    try testing.expectEqual(@as(u21, 'a'), try codepointAt(v, 0));
    try testing.expectEqual(@as(u21, 0x00E9), try codepointAt(v, 1));
    try testing.expectEqual(@as(u21, 'b'), try codepointAt(v, 2));
    try testing.expectEqual(@as(u21, 0x1F980), try codepointAt(v, 3));
    try testing.expectError(error.OutOfBounds, codepointAt(v, 4));
}

test "byteRangeForCodepoints: empty range, full range, mid-range" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const v = try fromBytes(&heap, "aéb🦀"); // bytes: 1 + 2 + 1 + 4 = 8
    // [0, 4) = full = byte [0, 8)
    {
        const r = try byteRangeForCodepoints(v, 0, 4);
        try testing.expectEqual(@as(usize, 0), r.start);
        try testing.expectEqual(@as(usize, 8), r.end);
    }
    // [1, 3) = "éb" = byte [1, 4)
    {
        const r = try byteRangeForCodepoints(v, 1, 3);
        try testing.expectEqual(@as(usize, 1), r.start);
        try testing.expectEqual(@as(usize, 4), r.end);
    }
    // [0, 0) = empty at start = byte [0, 0)
    {
        const r = try byteRangeForCodepoints(v, 0, 0);
        try testing.expectEqual(@as(usize, 0), r.start);
        try testing.expectEqual(@as(usize, 0), r.end);
    }
    // [4, 4) = empty at end = byte [8, 8)
    {
        const r = try byteRangeForCodepoints(v, 4, 4);
        try testing.expectEqual(@as(usize, 8), r.start);
        try testing.expectEqual(@as(usize, 8), r.end);
    }
}

test "byteRangeForCodepoints: out-of-bounds returns error" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const v = try fromBytes(&heap, "aéb"); // 3 codepoints
    try testing.expectError(error.OutOfBounds, byteRangeForCodepoints(v, 0, 4));
    try testing.expectError(error.OutOfBounds, byteRangeForCodepoints(v, 4, 5));
    try testing.expectError(error.OutOfBounds, byteRangeForCodepoints(v, 2, 1));
}

test "bytesEqual and hashHeader don't accidentally tamper with each other" {
    // S12: cached-hash is not mutated by a pure equality check. We
    // call bytesEqual without having pre-hashed; the cache must stay
    // clear.
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const a = try fromBytes(&heap, "cache-integrity");
    const b = try fromBytes(&heap, "cache-integrity");
    const ah = Heap.asHeapHeader(a);
    const bh = Heap.asHeapHeader(b);
    try testing.expectEqual(@as(u32, 0), ah.hash);
    try testing.expectEqual(@as(u32, 0), bh.hash);
    try testing.expect(bytesEqual(ah, bh));
    try testing.expectEqual(@as(u32, 0), ah.hash); // still uncomputed
    try testing.expectEqual(@as(u32, 0), bh.hash); // still uncomputed
}
