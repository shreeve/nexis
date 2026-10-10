//! uuid.zig — the `uuid` heap kind: a leaf block of the 16 bytes of a
//! UUID in network order (docs/STDLIB.md §14, SEMANTICS.md §2.8).
//!
//! 128 bits do not fit the 120 a Value leaves beside its kind byte, so
//! a UUID is a block. It is `=` and hashes by its bytes, orders by them
//! unsigned (its text's order), carries no metadata and holds no heap
//! reference, so the collector traces nothing in it.

const std = @import("std");
const value = @import("value.zig");
const heap_mod = @import("heap.zig");
const hash_mod = @import("hash.zig");

const Value = value.Value;
const Heap = heap_mod.Heap;
const HeapHeader = heap_mod.HeapHeader;

/// The length of a UUID's canonical text.
pub const text_len = 36;

/// A new uuid of the 16 bytes `bytes`.
pub fn make(heap: *Heap, bytes: [16]u8) !Value {
    const h = try heap.alloc(.uuid, 16);
    Heap.bodyBytes(h)[0..16].* = bytes;
    return Heap.valueFromHeader(.uuid, h);
}

/// The 16 bytes of the uuid `v`.
pub fn bytesOf(v: Value) *const [16]u8 {
    std.debug.assert(v.kind() == .uuid);
    return Heap.bodyBytes(Heap.asHeapHeader(v))[0..16];
}

/// `hash` of a uuid before its kind byte is mixed in: XXH3 of its
/// bytes, computed each time (16 bytes need no cache).
pub fn hashHeader(h: *HeapHeader) u64 {
    return hash_mod.hashBytes(Heap.bodyBytes(h)[0..16]);
}

pub fn bytesEqual(a: *HeapHeader, b: *HeapHeader) bool {
    return std.mem.eql(u8, Heap.bodyBytes(a)[0..16], Heap.bodyBytes(b)[0..16]);
}

/// Two uuids by their bytes, unsigned: the order of their texts.
pub fn order(a: Value, b: Value) std.math.Order {
    return std.mem.order(u8, bytesOf(a), bytesOf(b));
}

/// The canonical text of `u`: lower-case hex in groups of 8, 4, 4, 4
/// and 12 digits joined by `-`.
pub fn writeText(out: *[text_len]u8, u: [16]u8) void {
    const hex = "0123456789abcdef";
    var o: usize = 0;
    for (u, 0..) |b, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[o] = '-';
            o += 1;
        }
        out[o] = hex[b >> 4];
        out[o + 1] = hex[b & 0xF];
        o += 2;
    }
}

/// The UUID the text `s` names in the grammar of Java's
/// `UUID.fromString`, or null: five groups of 1–8, 1–4, 1–4, 1–4 and
/// 1–12 hex digits of either case joined by `-`, each group right
/// aligned in its field, at most 36 characters. A sign on a group and
/// an over-long group, which Java takes, are refused.
pub fn parse(s: []const u8) ?[16]u8 {
    if (s.len > text_len) return null;
    const widths = [5]u8{ 8, 4, 4, 4, 12 };
    var out: [16]u8 = undefined;
    var o: usize = 0;
    var groups = std.mem.splitScalar(u8, s, '-');
    for (widths, 0..) |width, g| {
        const group = groups.next() orelse return null;
        if (group.len == 0 or group.len > width) return null;
        var n: u64 = 0;
        for (group) |c| n = n << 4 | (std.fmt.charToDigit(c, 16) catch return null);
        // The field's width / 2 bytes, most significant first.
        const bytes = width / 2;
        for (0..bytes) |k| out[o + k] = @truncate(n >> @intCast(8 * (bytes - 1 - k)));
        o += bytes;
        if (g == 4 and groups.next() != null) return null;
    }
    return out;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn textOf(u: [16]u8) [text_len]u8 {
    var text: [text_len]u8 = undefined;
    writeText(&text, u);
    return text;
}

test "uuid: parse reads Java's UUID.fromString grammar and refuses its accidents" {
    const ok = [_]struct { []const u8, []const u8 }{
        .{ "0123abcd-4567-89ef-0123-456789abcdef", "0123abcd-4567-89ef-0123-456789abcdef" },
        .{ "0123ABCD-4567-89EF-0123-456789ABCDEF", "0123abcd-4567-89ef-0123-456789abcdef" },
        .{ "1-2-3-4-5", "00000001-0002-0003-0004-000000000005" },
        .{ "ffffffff-ffff-ffff-ffff-ffffffffffff", "ffffffff-ffff-ffff-ffff-ffffffffffff" },
    };
    for (ok) |c| try testing.expectEqualStrings(c[1], &textOf(parse(c[0]).?));
    const refused = [_][]const u8{
        "",                                      "x",
        "0123abcd-4567-89ef-0123-456789abcdef0", "0123abcd-4567-89ef-0123",
        "1--3-4-5",                              "1-2-3-4-5-6",
        "1-2-3-4-g",                             "+1-2-3-4-5",
        "123456789-1-1-1-1",                     "1-12345-1-1-1",
        "1-2-3-4-",                              "1-2-3-4-1234567890123",
    };
    for (refused) |s| testing.expectEqual(@as(?[16]u8, null), parse(s)) catch |err| {
        std.debug.print("\n  parse \"{s}\"\n", .{s});
        return err;
    };
}

test "uuid: the canonical text reads back as the bytes" {
    var rng = std.Random.DefaultPrng.init(0x0001d);
    for (0..1000) |_| {
        var u: [16]u8 = undefined;
        rng.random().bytes(&u);
        const text = textOf(u);
        try testing.expectEqualSlices(u8, &u, &parse(&text).?);
    }
    try testing.expectEqualStrings("ff000102-0304-0506-0708-090a0b0c0d0e", &textOf(.{ 0xff, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14 }));
}

test "uuid: a block holds its bytes, equals, hashes and orders by them" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const ones: [16]u8 = @splat(0xff);
    const lo = try make(&heap, @splat(0));
    const hi = try make(&heap, ones);
    const lo2 = try make(&heap, @splat(0));
    try testing.expect(lo.kind() == .uuid);
    try testing.expectEqualSlices(u8, &ones, bytesOf(hi));
    try testing.expect(bytesEqual(Heap.asHeapHeader(lo), Heap.asHeapHeader(lo2)));
    try testing.expect(!bytesEqual(Heap.asHeapHeader(lo), Heap.asHeapHeader(hi)));
    try testing.expectEqual(hashHeader(Heap.asHeapHeader(lo)), hashHeader(Heap.asHeapHeader(lo2)));
    try testing.expectEqual(std.math.Order.lt, order(lo, hi));
    try testing.expectEqual(std.math.Order.eq, order(lo, lo2));
}
