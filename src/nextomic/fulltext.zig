//! fulltext.zig — the `nx/fulltext` tokens tree behind `:db/fulltext`
//! (NEXTOMIC.md §2, §5).
//!
//! Invariants:
//!   - A row `[a:4][token][0x00][e:6][hash:16]` with an empty value is in
//!     the tree iff attribute `a` carries `:db/fulltext true` and `e`
//!     currently holds under `a` a string value whose 128-bit content
//!     hash (`key.hash128`) is `hash` and whose tokens include `token`.
//!     transact.zig keeps that under assert, retract and the flag's
//!     arrival; excise.zig under excision. The hash tells apart two
//!     values of one cardinality-many attribute that share a token, so
//!     retracting one leaves the other's rows.
//!   - `tokens` lowercases ASCII letters, keeps digits and every byte of
//!     a non-ASCII character, and splits on every other byte; a token
//!     longer than `max_token` bytes is dropped, so no row key exceeds
//!     the page's key bound. A token never holds 0x00, which makes the
//!     separator unambiguous.
//!   - `search` answers the `(e, hash)` pairs whose rows carry every
//!     token of the needle; a needle without tokens matches nothing.

const std = @import("std");
const emdb = @import("emdb");
const key = @import("key.zig");
const store_mod = @import("store.zig");

const Allocator = std.mem.Allocator;
const Txn = emdb.Txn;
const Store = store_mod.Store;

/// Longest token indexed, in bytes.
pub const max_token = 255;

/// The distinct tokens of `text`, in byte order.
pub fn tokens(arena: Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (!isTokenByte(text[i])) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < text.len and isTokenByte(text[i])) i += 1;
        if (i - start > max_token) continue;
        const token = try std.ascii.allocLowerString(arena, text[start..i]);
        const g = try seen.getOrPut(arena, token);
        if (!g.found_existing) try out.append(arena, token);
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);
    return out.toOwnedSlice(arena);
}

fn isTokenByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b >= 0x80;
}

/// True when the tokens of `text` include every token of `needle`;
/// false for a needle without tokens.
pub fn matches(arena: Allocator, text: []const u8, needle: []const []const u8) !bool {
    if (needle.len == 0) return false;
    const have = try tokens(arena, text);
    for (needle) |n| {
        var found = false;
        for (have) |h| if (std.mem.eql(u8, h, n)) {
            found = true;
            break;
        };
        if (!found) return false;
    }
    return true;
}

/// The row key of `token` under `a` for the value of `e` hashing to
/// `hash`.
pub fn rowKey(arena: Allocator, a: u32, token: []const u8, e: u64, hash: u128) ![]const u8 {
    const out = try arena.alloc(u8, key.attr_len + token.len + 1 + key.id_len + key.hash_len);
    key.writeAttr(out[0..key.attr_len], a);
    @memcpy(out[key.attr_len..][0..token.len], token);
    out[key.attr_len + token.len] = 0;
    key.writeId(out[key.attr_len + token.len + 1 ..][0..key.id_len], e);
    std.mem.writeInt(u128, out[key.attr_len + token.len + 1 + key.id_len ..][0..key.hash_len], hash, .big);
    return out;
}

/// The prefix of every row of `token` under `a`.
pub fn tokenPrefix(arena: Allocator, a: u32, token: []const u8) ![]const u8 {
    const out = try arena.alloc(u8, key.attr_len + token.len + 1);
    key.writeAttr(out[0..key.attr_len], a);
    @memcpy(out[key.attr_len..][0..token.len], token);
    out[key.attr_len + token.len] = 0;
    return out;
}

/// Put (`added`) or delete the rows of the string value `text` that
/// `e` holds under `a`.
pub fn index(store: *Store, txn: *Txn, arena: Allocator, a: u32, e: u64, text: []const u8, added: bool) !void {
    const hash = key.hash128(text);
    for (try tokens(arena, text)) |token| {
        const k = try rowKey(arena, a, token, e, hash);
        if (added) {
            try txn.putInTree(store.trees.fulltext, k, &.{});
        } else {
            _ = try txn.delFromTree(store.trees.fulltext, k);
        }
    }
}

/// Delete the rows of a current EAVT row `(e a vbytes)` of a string
/// attribute; an out-of-line value is read back from its payload.
pub fn unindexRow(store: *Store, txn: *Txn, arena: Allocator, a: u32, e: u64, vbytes: []const u8) !void {
    const kv = try key.decodeVal(arena, vbytes);
    const text = switch (kv) {
        .val => |v| if (v == .string) v.string else return,
        .string_long => (try store.currentPayload(txn, e, a, vbytes, arena)) orelse return error.Corrupted,
        .bytes_long => return,
    };
    try index(store, txn, arena, a, e, text, false);
}

/// One value found by `search`: the entity and its value's hash.
pub const Hit = struct { e: u64, hash: u128 };

/// The `(e, hash)` pairs under `a` whose rows carry every token of
/// `needle`, ascending by `e` then `hash`; empty for a needle without
/// tokens.
pub fn search(store: *Store, txn: *Txn, arena: Allocator, a: u32, needle: []const []const u8) ![]const Hit {
    if (needle.len == 0) return &.{};
    var hits: std.AutoArrayHashMapUnmanaged(Hit, void) = .empty;
    for (needle, 0..) |token, i| {
        var found: std.AutoArrayHashMapUnmanaged(Hit, void) = .empty;
        var s = try Store.scan(txn, store.trees.fulltext, try tokenPrefix(arena, a, token));
        while (s.next()) |kv| {
            const hit = try hitOf(kv.key);
            if (i == 0 or hits.contains(hit)) try found.put(arena, hit, {});
        }
        hits = found;
        if (hits.count() == 0) break;
    }
    const out = try arena.dupe(Hit, hits.keys());
    std.mem.sort(Hit, out, {}, struct {
        fn lt(_: void, x: Hit, y: Hit) bool {
            return x.e < y.e or (x.e == y.e and x.hash < y.hash);
        }
    }.lt);
    return out;
}

/// The entity and hash a row key ends with.
fn hitOf(k: []const u8) !Hit {
    const tail = key.id_len + key.hash_len;
    if (k.len < key.attr_len + 1 + tail) return error.Corrupted;
    return .{
        .e = key.readId(k[k.len - tail ..][0..key.id_len]),
        .hash = std.mem.readInt(u128, k[k.len - key.hash_len ..][0..key.hash_len], .big),
    };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "tokens lowercase ASCII, keep digits and non-ASCII bytes, split on the rest" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ts = try tokens(arena, "  Hello, WORLD! x2 -- café_au-lait  hello ");
    const want = [_][]const u8{ "au", "café", "hello", "lait", "world", "x2" };
    try testing.expectEqual(want.len, ts.len);
    for (want, ts) |w, t| try testing.expectEqualStrings(w, t);
    try testing.expectEqual(@as(usize, 0), (try tokens(arena, " ... ")).len);
    try testing.expectEqual(@as(usize, 0), (try tokens(arena, "")).len);
    // A token past the bound is dropped; its neighbours stay.
    const long = try arena.alloc(u8, max_token + 1);
    @memset(long, 'a');
    const text = try std.mem.concat(arena, u8, &.{ "b ", long, " c" });
    const kept = try tokens(arena, text);
    try testing.expectEqual(@as(usize, 2), kept.len);
    try testing.expectEqualStrings("b", kept[0]);
    try testing.expectEqualStrings("c", kept[1]);
}

test "matches needs every needle token and refuses an empty needle" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expect(try matches(arena, "The quick brown fox", try tokens(arena, "FOX quick")));
    try testing.expect(!try matches(arena, "The quick brown fox", try tokens(arena, "quick dog")));
    try testing.expect(!try matches(arena, "The quick brown fox", try tokens(arena, "!!")));
}

test "index and search keep rows per value and intersect tokens" {
    var td = try store_mod.TestDir.init("fulltext_rows");
    defer td.deinit();
    const store = try Store.open(testing.allocator, td.path.ptr, .{});
    defer store.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a: u32 = store_mod.boot.next_aid;
    const e1: u64 = 1 << 33;
    const e2: u64 = (1 << 33) + 1;

    const txn = try store.beginWrite(.none);
    defer txn.abort();
    try index(store, txn, arena, a, e1, "Red apple pie", true);
    try index(store, txn, arena, a, e1, "red wine", true);
    try index(store, txn, arena, a, e2, "Green apple", true);

    const red = try search(store, txn, arena, a, try tokens(arena, "red"));
    try testing.expectEqual(@as(usize, 2), red.len);
    try testing.expectEqual(e1, red[0].e);
    try testing.expectEqual(e1, red[1].e);
    const red_apple = try search(store, txn, arena, a, try tokens(arena, "Apple RED"));
    try testing.expectEqual(@as(usize, 1), red_apple.len);
    try testing.expectEqual(key.hash128("Red apple pie"), red_apple[0].hash);
    const apple = try search(store, txn, arena, a, try tokens(arena, "apple"));
    try testing.expectEqual(@as(usize, 2), apple.len);
    try testing.expectEqual(e1, apple[0].e);
    try testing.expectEqual(e2, apple[1].e);
    try testing.expectEqual(@as(usize, 0), (try search(store, txn, arena, a, try tokens(arena, "apple plum"))).len);
    try testing.expectEqual(@as(usize, 0), (try search(store, txn, arena, a, &.{})).len);
    // Another attribute's rows are its own.
    try testing.expectEqual(@as(usize, 0), (try search(store, txn, arena, a + 1, try tokens(arena, "red"))).len);

    // Retracting one value leaves the other's shared token.
    try index(store, txn, arena, a, e1, "red wine", false);
    const still = try search(store, txn, arena, a, try tokens(arena, "red"));
    try testing.expectEqual(@as(usize, 1), still.len);
    try testing.expectEqual(key.hash128("Red apple pie"), still[0].hash);
    try testing.expectEqual(@as(usize, 0), (try search(store, txn, arena, a, try tokens(arena, "wine"))).len);

    // An out-of-line value unindexes through its payload.
    const long_text = try std.mem.concat(arena, u8, &.{ "zebra ", "x" ** 200 });
    const vb = try key.valBytes(arena, .{ .string = long_text });
    try store.writeBatch(txn, 2, &.{
        .{ .e = e2, .a = a, .vbytes = vb, .payload = long_text, .added = true, .avet = false, .vaet = false },
    }, arena);
    try index(store, txn, arena, a, e2, long_text, true);
    try testing.expectEqual(@as(usize, 1), (try search(store, txn, arena, a, try tokens(arena, "zebra"))).len);
    try unindexRow(store, txn, arena, a, e2, vb);
    try testing.expectEqual(@as(usize, 0), (try search(store, txn, arena, a, try tokens(arena, "zebra"))).len);
}
