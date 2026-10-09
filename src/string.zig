//! string.zig — UTF-8 string heap kind.
//!
//! Authoritative spec: `docs/STRING.md`. Physical storage lives on
//! `src/heap.zig`; semantic rules come from `docs/SEMANTICS.md` §2.4
//! (byte equality) and §3.2 (hash).
//!
//! One subkind, the heap string: the body is the raw UTF-8 bytes with
//! no length prefix, the length recovered from the heap block.
//!
//! Invariants (STRING.md §2):
//!   - Bytes are copied into a fresh heap allocation on `fromBytes`.
//!   - No UTF-8 validation at the storage boundary (the reader
//!     produces well-formed UTF-8; the codec keeps bytes as they are;
//!     this module is byte-blob underneath).
//!   - No interning, no content dedup — two `fromBytes("foo")` calls
//!     produce two `*HeapHeader`s that are byte-equal but not pointer-
//!     identical.
//!   - Cached hash of 0 is not stored; that string recomputes on next
//!     access (HEAP.md §1 invariant 3).

const std = @import("std");
const builtin = @import("builtin");
const value = @import("value.zig");
const heap_mod = @import("heap.zig");
const hash_mod = @import("hash.zig");

const Value = value.Value;
const Kind = value.Kind;
const Heap = heap_mod.Heap;
const HeapHeader = heap_mod.HeapHeader;

const testing = std.testing;

// =============================================================================
// Subkind discriminator
// =============================================================================

pub const subkind_heap: u16 = 1;

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

/// A fresh `.string` block of `len` bytes for the caller to fill
/// before the value is used: a builder that knows its length writes
/// its text once, in place, with no intermediate buffer.
pub fn allocUninit(heap: *Heap, len: usize) !struct { value: Value, bytes: []u8 } {
    const h = try heap.alloc(.string, len);
    return .{ .value = valueFrom(h), .bytes = Heap.bodyBytes(h) };
}

/// Byte view over a string Value, the body of its heap block. Panics
/// if `v.kind() != .string`.
pub fn asBytes(v: Value) []const u8 {
    std.debug.assert(v.kind() == .string);
    const h = Heap.asHeapHeader(v);
    if (builtin.optimize.runtimeSafety()) {
        std.debug.assert(v.subkind() == subkind_heap);
    }
    return Heap.bodyBytes(h);
}

/// The length of `v` in bytes.
pub fn byteLen(v: Value) usize {
    return asBytes(v).len;
}

/// Per-kind hash entry point — called by `dispatch.heapHashBase`
/// once the kind switch lands on `.string`. Reads
/// `HeapHeader.cachedHash`; if uncomputed (zero), computes
/// `xxHash3(seed, bodyBytes(h))` truncated to u32, stores it in the
/// cache **only when nonzero** (HEAP.md §1 invariant 3), and returns it.
pub fn hashHeader(h: *HeapHeader) u32 {
    if (builtin.optimize.runtimeSafety()) {
        std.debug.assert(h.kind == @backingInt(Kind.string));
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
pub fn bytesEqual(a: *HeapHeader, b: *HeapHeader) bool {
    if (builtin.optimize.runtimeSafety()) {
        std.debug.assert(a.kind == @backingInt(Kind.string));
        std.debug.assert(b.kind == @backingInt(Kind.string));
    }
    if (a == b) return true; // same header -> trivially equal
    const ab = Heap.bodyBytes(a);
    const bb = Heap.bodyBytes(b);
    return std.mem.eql(u8, ab, bb);
}

// =============================================================================
// Codepoint helpers
// =============================================================================
//
// The language-level surface (`(count s)`, `(nth s i)`, `(subs s
// start end)`) indexes by Unicode SCALAR / codepoint, NOT by byte
// and NOT by grapheme cluster. The storage body remains raw UTF-8
// bytes; these helpers convert codepoint indices into byte offsets.
// A leading ASCII run is found sixteen bytes at a time and indexed
// directly, so an ASCII string costs a vector scan instead of a
// decode per character, and only the bytes past the run are walked.
//
// Frozen contract (STRING.md §3):
//   - All three return `error.InvalidUtf8` on a malformed body up to
//     the position asked for. The runtime caller (`stdlib.zig`) maps
//     that to `:utf8-error` (catchable). The storage layer does not
//     pre-validate bytes (a codec round trip keeps them byte-exact).
//   - Codepoint count is not cached; whether the string is all ASCII
//     is, in the header's flags, so count and index are O(1) on an
//     ASCII string.

/// Length of the ASCII run at the start of `bytes`.
fn asciiPrefixLen(bytes: []const u8) usize {
    const V = @Vector(16, u8);
    var i: usize = 0;
    while (i + 16 <= bytes.len) : (i += 16) {
        const chunk: V = bytes[i..][0..16].*;
        if (@reduce(.Or, chunk) & 0x80 != 0) break;
    }
    while (i < bytes.len and bytes[i] < 0x80) i += 1;
    return i;
}

/// One validated scalar at `bytes[pos..]` (`pos` within `bytes`), and
/// its byte length: a lone continuation byte, a truncated sequence, an
/// overlong form, a surrogate and a scalar past U+10FFFF are
/// `error.InvalidUtf8`.
pub fn decodeAt(bytes: []const u8, pos: usize) error{InvalidUtf8}!struct { scalar: u21, len: u3 } {
    const len = std.unicode.utf8ByteSequenceLength(bytes[pos]) catch return error.InvalidUtf8;
    if (len > bytes.len - pos) return error.InvalidUtf8;
    const at = bytes[pos..];
    const scalar: u21 = switch (len) {
        1 => at[0],
        2 => std.unicode.utf8Decode2(at[0..2].*) catch return error.InvalidUtf8,
        3 => std.unicode.utf8Decode3(at[0..3].*) catch return error.InvalidUtf8,
        4 => std.unicode.utf8Decode4(at[0..4].*) catch return error.InvalidUtf8,
        else => unreachable,
    };
    return .{ .scalar = scalar, .len = len };
}

/// Whether every byte of `v` is ASCII, so a codepoint index is a
/// byte index. The first call scans; the answer is kept in the
/// header's flags, as the bytes never change.
fn isAscii(v: Value) bool {
    const h = Heap.asHeapHeader(v);
    if (h.flags & heap_mod.flag_ascii_known == 0) {
        const bytes = Heap.bodyBytes(h);
        h.flags |= heap_mod.flag_ascii_known;
        if (asciiPrefixLen(bytes) == bytes.len) h.flags |= heap_mod.flag_ascii;
    }
    return h.flags & heap_mod.flag_ascii != 0;
}

/// Total number of Unicode codepoints in `v`: O(1) for an ASCII
/// string after the first call, O(byteLen) otherwise. Returns
/// `error.InvalidUtf8` if the body contains an invalid byte
/// sequence.
pub fn codepointCount(v: Value) error{InvalidUtf8}!usize {
    const bytes = asBytes(v);
    if (isAscii(v)) return bytes.len;
    const ascii = asciiPrefixLen(bytes);
    return ascii + (std.unicode.utf8CountCodepoints(bytes[ascii..]) catch return error.InvalidUtf8);
}

/// Unicode scalar at codepoint index `i`. Returns `error.OutOfBounds`
/// if `i >= codepointCount(v)`, `error.InvalidUtf8` on a malformed
/// byte sequence anywhere up to position `i`.
pub fn codepointAt(v: Value, i: usize) error{ OutOfBounds, InvalidUtf8 }!u21 {
    const bytes = asBytes(v);
    if (isAscii(v)) return if (i < bytes.len) bytes[i] else error.OutOfBounds;
    const ascii = asciiPrefixLen(bytes[0..@min(bytes.len, i +| 1)]);
    if (i < ascii) return bytes[i];
    var byte_pos = ascii;
    var cp_pos = ascii;
    while (byte_pos < bytes.len) : (cp_pos += 1) {
        const d = try decodeAt(bytes, byte_pos);
        if (cp_pos == i) return d.scalar;
        byte_pos += d.len;
    }
    return error.OutOfBounds;
}

/// Convert a codepoint range `[start, end)` to a byte range. Both
/// endpoints are codepoint-indexed. Returns `error.OutOfBounds` if
/// `start > end` or `end > codepointCount(v)`; `error.InvalidUtf8` on
/// malformed bytes before `end`.
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
    if (isAscii(v)) return if (end <= bytes.len) .{ .start = start, .end = end } else error.OutOfBounds;
    const ascii = asciiPrefixLen(bytes[0..@min(bytes.len, end)]);
    if (end <= ascii) return .{ .start = start, .end = end };
    var byte_start: ?usize = if (start <= ascii) start else null;
    var byte_pos = ascii;
    var cp_pos = ascii;
    while (cp_pos < end) : (cp_pos += 1) {
        if (byte_pos == bytes.len) return error.OutOfBounds;
        byte_pos += (try decodeAt(bytes, byte_pos)).len;
        if (cp_pos + 1 == start) byte_start = byte_pos;
    }
    return .{ .start = byte_start.?, .end = byte_pos };
}

// =============================================================================
// Substring search
// =============================================================================

/// The start offsets of the non-overlapping occurrences of `needle`
/// (one byte or more) in `hay`, left to right from `from`: each search
/// resumes after the previous occurrence. Thirty-two positions are
/// tested at once: a position is a candidate when its byte is the
/// needle's first and the byte `needle.len - 1` past it the needle's
/// last, and only a candidate is compared in full, so a one-byte
/// needle costs a vector compare per 32 bytes and a bit scan per
/// occurrence, with no table to build per search. On valid UTF-8 an
/// occurrence of valid UTF-8 starts and ends on code-point boundaries.
pub const Matches = struct {
    hay: []const u8,
    needle: []const u8,
    /// No occurrence starts before this: the end of the last one.
    pos: usize,
    /// The start of the next block to test.
    scan: usize,
    /// The block `bits` describes, and its untested candidates.
    base: usize = 0,
    bits: u32 = 0,

    const width = 32;
    const Block = @Vector(width, u8);

    pub fn init(hay: []const u8, needle: []const u8, from: usize) Matches {
        std.debug.assert(needle.len > 0);
        return .{ .hay = hay, .needle = needle, .pos = from, .scan = from };
    }

    pub fn next(self: *Matches) ?usize {
        const n = self.needle.len;
        if (n > self.hay.len) return null;
        // The last position an occurrence can start at.
        const last = self.hay.len - n;
        while (true) {
            while (self.bits != 0) {
                const i = self.base + @ctz(self.bits);
                self.bits &= self.bits - 1;
                if (i < self.pos) continue;
                if (n > 2 and !std.mem.eql(u8, self.hay[i + 1 .. i + n - 1], self.needle[1 .. n - 1])) continue;
                self.pos = i + n;
                return i;
            }
            self.scan = @max(self.scan, self.pos);
            if (self.scan > last) return null;
            self.base = self.scan;
            self.bits = candidates(self.hay, self.needle, self.base, last);
            self.scan += width;
        }
    }

    /// Bit `k` set when `base + k` (at most `last`) is a candidate.
    fn candidates(hay: []const u8, needle: []const u8, base: usize, last: usize) u32 {
        const n = needle.len;
        if (last - base >= width - 1) {
            const first: Block = hay[base..][0..width].*;
            const bits: u32 = @bitCast(first == @as(Block, @splat(needle[0])));
            if (n == 1) return bits;
            const end: Block = hay[base + n - 1 ..][0..width].*;
            return bits & @as(u32, @bitCast(end == @as(Block, @splat(needle[n - 1]))));
        }
        var bits: u32 = 0;
        for (base..last + 1) |i| {
            if (hay[i] == needle[0] and hay[i + n - 1] == needle[n - 1]) bits |= @as(u32, 1) << @intCast(i - base);
        }
        return bits;
    }
};

/// The first occurrence of `needle` in `hay` at or after `from`; the
/// empty needle is found at `from`.
pub fn indexOf(hay: []const u8, needle: []const u8, from: usize) ?usize {
    if (needle.len == 0) return if (from <= hay.len) from else null;
    var m = Matches.init(hay, needle, from);
    return m.next();
}

/// How many non-overlapping occurrences of `needle` (one byte or
/// more) `hay` holds.
pub fn countMatches(hay: []const u8, needle: []const u8) usize {
    var m = Matches.init(hay, needle, 0);
    var k: usize = 0;
    while (m.next()) |_| k += 1;
    return k;
}

// =============================================================================
// Private helpers
// =============================================================================

/// Pack a fully-constructed `.string` header into a Value with the
/// correct kind, subkind, and zeroed flags/aux.
fn valueFrom(h: *HeapHeader) Value {
    return .{
        .tag = @as(u64, @backingInt(Kind.string)) |
            (@as(u64, subkind_heap) << 16),
        .payload = @intFromPtr(h),
    };
}

// =============================================================================
// Inline tests — per-module basics. Randomized sweeps live in
// test/prop/string.zig.
// =============================================================================

/// `s` repeated `n` times, for building long test strings; the tree's
/// one copy (`vm.zig` and the Nextomic store tests use it too).
pub fn repeat(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    return comptime blk: {
        @setEvalBranchQuota(2 * n + 1000);
        var buf: [s.len * n]u8 = undefined;
        for (0..n) |i| @memcpy(buf[i * s.len ..][0..s.len], s);
        const final = buf;
        break :blk &final;
    };
}

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
// Substring search tests
// =============================================================================

/// Every non-overlapping occurrence by a plain left-to-right scan.
fn naiveMatches(hay: []const u8, needle: []const u8, from: usize, out: *std.ArrayList(usize)) !void {
    var i = from;
    while (i + needle.len <= hay.len) {
        if (std.mem.eql(u8, hay[i..][0..needle.len], needle)) {
            try out.append(testing.allocator, i);
            i += needle.len;
        } else i += 1;
    }
}

fn expectMatches(hay: []const u8, needle: []const u8, from: usize) !void {
    var want: std.ArrayList(usize) = .empty;
    defer want.deinit(testing.allocator);
    try naiveMatches(hay, needle, from, &want);
    var got: std.ArrayList(usize) = .empty;
    defer got.deinit(testing.allocator);
    var m = Matches.init(hay, needle, from);
    while (m.next()) |i| try got.append(testing.allocator, i);
    try testing.expectEqualSlices(usize, want.items, got.items);
    try testing.expectEqual(if (want.items.len > 0) want.items[0] else null, indexOf(hay, needle, from));
    if (from == 0) try testing.expectEqual(want.items.len, countMatches(hay, needle));
}

test "Matches: occurrences across block edges, at both ends, overlapping and past the end" {
    const long = "a,b,,c" ++ @as([40]u8, @splat('x')) ++ ",," ++ repeat("y,", 30) ++ "z,";
    try expectMatches(long, ",", 0);
    try expectMatches(long, ",,", 0);
    try expectMatches(long, "y,y", 0);
    try expectMatches(long, &@as([33]u8, @splat('x')), 0);
    try expectMatches(long, ",", 7);
    try expectMatches(long, "z,", 0);
    try expectMatches("aaaa", "aa", 0);
    try expectMatches("aaaaa", "aa", 1);
    try expectMatches(",", ",", 0);
    try expectMatches("", ",", 0);
    try expectMatches("ab", "abc", 0);
    try expectMatches("h\xC3\xA9llo w\xC3\xB6rld \xC3\xA9", "\xC3\xA9", 0);
    try testing.expectEqual(@as(?usize, 3), indexOf("abc", "", 3));
    try testing.expectEqual(@as(?usize, null), indexOf("abc", "", 4));
}

test "Matches: agrees with a plain scan over random text" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const r = prng.random();
    var hay: [200]u8 = undefined;
    var needle: [5]u8 = undefined;
    for (0..2000) |_| {
        const hay_len = r.uintLessThan(usize, hay.len + 1);
        for (hay[0..hay_len]) |*b| b.* = "ab,"[r.uintLessThan(usize, 3)];
        const needle_len = 1 + r.uintLessThan(usize, needle.len);
        for (needle[0..needle_len]) |*b| b.* = "ab,"[r.uintLessThan(usize, 3)];
        try expectMatches(hay[0..hay_len], needle[0..needle_len], r.uintLessThan(usize, hay_len + 2));
    }
}

test "allocUninit: a block of the length asked, filled by the caller" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const s = try allocUninit(&heap, 5);
    @memcpy(s.bytes, "héll");
    try testing.expectEqualStrings("héll", asBytes(s.value));
    try testing.expectEqual(@as(usize, 0), (try allocUninit(&heap, 0)).bytes.len);
}

// =============================================================================
// Codepoint helper tests
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

test "codepointCount: an ASCII string is scanned once, then counted and indexed by its length" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const ascii = try fromBytes(&heap, "hello");
    const h = Heap.asHeapHeader(ascii);
    try testing.expectEqual(@as(u8, 0), h.flags);
    try testing.expectEqual(@as(usize, 5), try codepointCount(ascii));
    try testing.expectEqual(heap_mod.flag_ascii_known | heap_mod.flag_ascii, h.flags);
    try testing.expectEqual(@as(u21, 'o'), try codepointAt(ascii, 4));
    try testing.expectError(error.OutOfBounds, codepointAt(ascii, 5));
    try testing.expectError(error.OutOfBounds, byteRangeForCodepoints(ascii, 0, 6));
    const mixed = try fromBytes(&heap, "h\u{e9}llo");
    try testing.expectEqual(@as(u21, 0xe9), try codepointAt(mixed, 1));
    try testing.expectEqual(heap_mod.flag_ascii_known, Heap.asHeapHeader(mixed).flags);
    try testing.expectEqual(@as(usize, 5), try codepointCount(mixed));
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
