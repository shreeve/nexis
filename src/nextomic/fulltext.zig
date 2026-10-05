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
//!   - `tokens` splits text into runs of ASCII letters, digits and
//!     non-ASCII characters other than the separators (`separator`:
//!     spaces and punctuation), and folds each run's characters by
//!     Unicode simple case folding (`fold`: ASCII, Latin, Greek, Cyrillic,
//!     Armenian, Georgian, Glagolitic, Deseret, the letterlike and
//!     fullwidth forms); bytes that are not UTF-8 stay as they are. A
//!     folded token longer than `max_token` bytes is dropped, so no row
//!     key exceeds the page's key bound. A token never holds 0x00,
//!     which makes the separator unambiguous. Indexing and search both
//!     tokenise through `tokens`, so they fold alike.
//!   - The rows are written under `store.fulltext_fold`, stamped in
//!     `sys` with the `t` they are current at (`Store.fulltextFresh`).
//!     A stamp of another folding, or a `t` committed without a stamp,
//!     is stale: `rebuild` writes the rows again, at connect when the
//!     file is writable and at the start of the next transaction, and
//!     until then a search re-tokenises the values instead.
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

/// The distinct folded tokens of `text`, in byte order.
pub fn tokens(arena: Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const c = charAt(text, i);
        if (!c.token) {
            i += c.len;
            continue;
        }
        const start = i;
        while (i < text.len) {
            const d = charAt(text, i);
            if (!d.token) break;
            i += d.len;
        }
        const token = try foldRun(arena, text[start..i]);
        if (token.len > max_token) continue;
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

/// The character at `text[i]`: its length, and whether it belongs to
/// a token. ASCII letters and digits do, other ASCII does not; a
/// non-ASCII character does unless it is a separator; a byte that does
/// not start a valid UTF-8 sequence does, alone.
fn charAt(text: []const u8, i: usize) struct { len: usize, token: bool } {
    const b = text[i];
    if (b < 0x80) return .{ .len = 1, .token = std.ascii.isAlphanumeric(b) };
    const n = std.unicode.utf8ByteSequenceLength(b) catch return .{ .len = 1, .token = true };
    if (i + n > text.len) return .{ .len = 1, .token = true };
    const cp = std.unicode.utf8Decode(text[i..][0..n]) catch return .{ .len = 1, .token = true };
    return .{ .len = n, .token = !separator(cp) };
}

/// The non-ASCII spaces and punctuation that end a token: Latin-1's
/// (no-break space to `¿` but `ª`, `µ` and `º`, and `×`, `÷`), General
/// Punctuation, the CJK symbols and punctuation but the ideographic
/// letters and numerals among them, and the fullwidth and halfwidth
/// forms of ASCII punctuation.
fn separator(cp: u21) bool {
    return switch (cp) {
        0xA0...0xA9, 0xAB...0xB4, 0xB6...0xB9, 0xBB...0xBF, 0xD7, 0xF7 => true,
        0x2000...0x206F => true,
        0x3000...0x3004, 0x3008...0x3020, 0x302A...0x3030, 0x3036, 0x3037, 0x303D...0x303F => true,
        0xFF01...0xFF0F, 0xFF1A...0xFF20, 0xFF3B...0xFF40, 0xFF5B...0xFF65 => true,
        else => false,
    };
}

/// `run` with every character folded; a byte that does not start a
/// valid UTF-8 sequence is kept as it is.
fn foldRun(arena: Allocator, run: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = try .initCapacity(arena, run.len);
    var i: usize = 0;
    while (i < run.len) {
        const b = run[i];
        if (b < 0x80) {
            try out.append(arena, std.ascii.toLower(b));
            i += 1;
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(b) catch 1;
        const cp = if (n > 1 and i + n <= run.len) std.unicode.utf8Decode(run[i..][0..n]) catch null else null;
        if (cp) |c| {
            var buf: [4]u8 = undefined;
            const m = std.unicode.utf8Encode(fold(c), &buf) catch unreachable;
            try out.appendSlice(arena, buf[0..m]);
            i += n;
        } else {
            try out.append(arena, b);
            i += 1;
        }
    }
    return out.items;
}

/// A span of code points that fold by one offset: every one of them,
/// or (`alternate`) every other one from `lo`, the upper case of a
/// lower-case neighbour.
const Fold = struct { lo: u21, hi: u21, delta: i32, alternate: bool = false };

fn single(cp: u21, to: u21) Fold {
    return .{ .lo = cp, .hi = cp, .delta = @as(i32, to) - @as(i32, cp) };
}

fn span(lo: u21, hi: u21, to: u21) Fold {
    return .{ .lo = lo, .hi = hi, .delta = @as(i32, to) - @as(i32, lo) };
}

fn pairs(lo: u21, hi: u21) Fold {
    return .{ .lo = lo, .hi = hi, .delta = 1, .alternate = true };
}

/// Unicode simple case folding (CaseFolding.txt, statuses C and S) for
/// the scripts `fold` covers, sorted by `lo`. ASCII folds in `foldRun`.
const folds = [_]Fold{
    single(0xB5, 0x3BC),
    span(0xC0, 0xD6, 0xE0),
    span(0xD8, 0xDE, 0xF8),
    pairs(0x100, 0x12F),
    pairs(0x132, 0x137),
    pairs(0x139, 0x148),
    pairs(0x14A, 0x177),
    single(0x178, 0xFF),
    pairs(0x179, 0x17E),
    single(0x17F, 's'),
    single(0x181, 0x253),
    pairs(0x182, 0x185),
    single(0x186, 0x254),
    single(0x187, 0x188),
    span(0x189, 0x18A, 0x256),
    single(0x18B, 0x18C),
    single(0x18E, 0x1DD),
    single(0x18F, 0x259),
    single(0x190, 0x25B),
    single(0x191, 0x192),
    single(0x193, 0x260),
    single(0x194, 0x263),
    single(0x196, 0x269),
    single(0x197, 0x268),
    single(0x198, 0x199),
    single(0x19C, 0x26F),
    single(0x19D, 0x272),
    single(0x19F, 0x275),
    pairs(0x1A0, 0x1A5),
    single(0x1A6, 0x280),
    single(0x1A7, 0x1A8),
    single(0x1A9, 0x283),
    single(0x1AC, 0x1AD),
    single(0x1AE, 0x288),
    single(0x1AF, 0x1B0),
    span(0x1B1, 0x1B2, 0x28A),
    pairs(0x1B3, 0x1B6),
    single(0x1B7, 0x292),
    single(0x1B8, 0x1B9),
    single(0x1BC, 0x1BD),
    single(0x1C4, 0x1C6),
    single(0x1C5, 0x1C6),
    single(0x1C7, 0x1C9),
    single(0x1C8, 0x1C9),
    single(0x1CA, 0x1CC),
    pairs(0x1CB, 0x1DC),
    pairs(0x1DE, 0x1EF),
    single(0x1F1, 0x1F3),
    pairs(0x1F2, 0x1F5),
    single(0x1F6, 0x195),
    single(0x1F7, 0x1BF),
    pairs(0x1F8, 0x21F),
    single(0x220, 0x19E),
    pairs(0x222, 0x233),
    single(0x23A, 0x2C65),
    single(0x23B, 0x23C),
    single(0x23D, 0x19A),
    single(0x23E, 0x2C66),
    single(0x241, 0x242),
    single(0x243, 0x180),
    single(0x244, 0x289),
    single(0x245, 0x28C),
    pairs(0x246, 0x24F),
    single(0x345, 0x3B9),
    pairs(0x370, 0x373),
    single(0x376, 0x377),
    single(0x37F, 0x3F3),
    single(0x386, 0x3AC),
    span(0x388, 0x38A, 0x3AD),
    single(0x38C, 0x3CC),
    span(0x38E, 0x38F, 0x3CD),
    span(0x391, 0x3A1, 0x3B1),
    span(0x3A3, 0x3AB, 0x3C3),
    single(0x3C2, 0x3C3),
    single(0x3CF, 0x3D7),
    single(0x3D0, 0x3B2),
    single(0x3D1, 0x3B8),
    single(0x3D5, 0x3C6),
    single(0x3D6, 0x3C0),
    pairs(0x3D8, 0x3EF),
    single(0x3F0, 0x3BA),
    single(0x3F1, 0x3C1),
    single(0x3F4, 0x3B8),
    single(0x3F5, 0x3B5),
    single(0x3F7, 0x3F8),
    single(0x3F9, 0x3F2),
    single(0x3FA, 0x3FB),
    span(0x3FD, 0x3FF, 0x37B),
    span(0x400, 0x40F, 0x450),
    span(0x410, 0x42F, 0x430),
    pairs(0x460, 0x481),
    pairs(0x48A, 0x4BF),
    single(0x4C0, 0x4CF),
    pairs(0x4C1, 0x4CE),
    pairs(0x4D0, 0x52F),
    span(0x531, 0x556, 0x561),
    span(0x10A0, 0x10C5, 0x2D00),
    single(0x10C7, 0x2D27),
    single(0x10CD, 0x2D2D),
    single(0x1C80, 0x432),
    single(0x1C81, 0x434),
    single(0x1C82, 0x43E),
    span(0x1C83, 0x1C84, 0x441),
    single(0x1C85, 0x442),
    single(0x1C86, 0x44A),
    single(0x1C87, 0x463),
    single(0x1C88, 0xA64B),
    span(0x1C90, 0x1CBA, 0x10D0),
    span(0x1CBD, 0x1CBF, 0x10FD),
    pairs(0x1E00, 0x1E95),
    single(0x1E9B, 0x1E61),
    single(0x1E9E, 0xDF),
    pairs(0x1EA0, 0x1EFF),
    span(0x1F08, 0x1F0F, 0x1F00),
    span(0x1F18, 0x1F1D, 0x1F10),
    span(0x1F28, 0x1F2F, 0x1F20),
    span(0x1F38, 0x1F3F, 0x1F30),
    span(0x1F48, 0x1F4D, 0x1F40),
    .{ .lo = 0x1F59, .hi = 0x1F5F, .delta = -8, .alternate = true },
    span(0x1F68, 0x1F6F, 0x1F60),
    span(0x1F88, 0x1F8F, 0x1F80),
    span(0x1F98, 0x1F9F, 0x1F90),
    span(0x1FA8, 0x1FAF, 0x1FA0),
    span(0x1FB8, 0x1FB9, 0x1FB0),
    span(0x1FBA, 0x1FBB, 0x1F70),
    single(0x1FBC, 0x1FB3),
    single(0x1FBE, 0x3B9),
    span(0x1FC8, 0x1FCB, 0x1F72),
    single(0x1FCC, 0x1FC3),
    span(0x1FD8, 0x1FD9, 0x1FD0),
    span(0x1FDA, 0x1FDB, 0x1F76),
    span(0x1FE8, 0x1FE9, 0x1FE0),
    span(0x1FEA, 0x1FEB, 0x1F7A),
    single(0x1FEC, 0x1FE5),
    span(0x1FF8, 0x1FF9, 0x1F78),
    span(0x1FFA, 0x1FFB, 0x1F7C),
    single(0x1FFC, 0x1FF3),
    single(0x2126, 0x3C9),
    single(0x212A, 'k'),
    single(0x212B, 0xE5),
    single(0x2132, 0x214E),
    span(0x2160, 0x216F, 0x2170),
    single(0x2183, 0x2184),
    span(0x24B6, 0x24CF, 0x24D0),
    span(0x2C00, 0x2C2F, 0x2C30),
    pairs(0xA640, 0xA66D),
    pairs(0xA680, 0xA69B),
    span(0xFF21, 0xFF3A, 0xFF41),
    span(0x10400, 0x10427, 0x10428),
};

/// The simple case folding of `cp`: itself outside the table.
pub fn fold(cp: u21) u21 {
    if (cp < 0x80) return std.ascii.toLower(@intCast(cp));
    var lo: usize = 0;
    var hi: usize = folds.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const f = folds[mid];
        if (cp < f.lo) {
            hi = mid;
        } else if (cp > f.hi) {
            lo = mid + 1;
        } else {
            if (f.alternate and (cp - f.lo) % 2 != 0) return cp;
            return @intCast(@as(i32, cp) + f.delta);
        }
    }
    return cp;
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

/// Put (`added`) or delete the rows of a current EAVT row
/// `(e a vbytes)` of a string attribute; an out-of-line value is read
/// back from its payload.
pub fn indexRow(store: *Store, txn: *Txn, arena: Allocator, a: u32, e: u64, vbytes: []const u8, added: bool) !void {
    const kv = try key.decodeVal(arena, vbytes);
    const text = switch (kv) {
        .val => |v| if (v == .string) v.string else return,
        .string_long => (try store.currentPayload(txn, e, a, vbytes, arena)) orelse return error.Corrupted,
        .bytes_long => return,
    };
    try index(store, txn, arena, a, e, text, added);
}

/// The attributes whose current `:db/fulltext` is true.
fn fulltextAttrs(store: *Store, txn: *Txn, arena: Allocator) ![]const u32 {
    var out: std.ArrayList(u32) = .empty;
    var s = try Store.scan(txn, store.trees.cur(.aevt), try key.prefixBytes(arena, .aevt, .{ .a = store.fulltext_aid }));
    while (try s.next()) |kv| {
        const parts = try key.unpackKey(.aevt, false, kv.key);
        const v = try key.decodeVal(arena, parts.v);
        if (v == .val and v.val == .boolean and v.val.boolean) try out.append(arena, @intCast(parts.e));
    }
    return out.items;
}

/// Whether `rebuild` has work at `t`: the rows are stale and some
/// attribute is full-text.
pub fn needsRebuild(store: *Store, txn: *Txn, arena: Allocator, t: u64) !bool {
    if (try store.fulltextFresh(txn, t)) return false;
    return (try fulltextAttrs(store, txn, arena)).len > 0;
}

/// Write every row again, under this build's folding, from the current
/// string values of every full-text attribute, and stamp the rows
/// current at `t`.
pub fn rebuild(store: *Store, txn: *Txn, arena: Allocator, t: u64) !void {
    try txn.dropTree(store.trees.fulltext, false);
    for (try fulltextAttrs(store, txn, arena)) |a| {
        var rows: std.ArrayList(key.Parts) = .empty;
        var r = try Store.scan(txn, store.trees.cur(.aevt), try key.prefixBytes(arena, .aevt, .{ .a = a }));
        while (try r.next()) |kv| {
            var parts = try key.unpackKey(.aevt, false, kv.key);
            parts.v = try arena.dupe(u8, parts.v);
            try rows.append(arena, parts);
        }
        for (rows.items) |p| try indexRow(store, txn, arena, a, p.e, p.v, true);
    }
    try store.writeFulltextStamp(txn, t);
}

/// One value found by `search`: the entity and its value's hash.
pub const Hit = struct { e: u64, hash: u128 };

/// The `(e, hash)` pairs under `a` whose rows carry every token of
/// `needle`, ascending by `e` then `hash`; empty for a needle without
/// tokens.
pub fn search(store: *Store, txn: *Txn, arena: Allocator, a: u32, needle: []const []const u8) ![]const Hit {
    if (needle.len == 0) return &.{};
    var hits: std.array_hash_map.Auto(Hit, void) = .empty;
    for (needle, 0..) |token, i| {
        var found: std.array_hash_map.Auto(Hit, void) = .empty;
        var s = try Store.scan(txn, store.trees.fulltext, try tokenPrefix(arena, a, token));
        while (try s.next()) |kv| {
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
        .e = try key.readId(k[k.len - tail ..][0..key.id_len]),
        .hash = std.mem.readInt(u128, k[k.len - key.hash_len ..][0..key.hash_len], .big),
    };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "the fold table is sorted, disjoint and idempotent, and folds to lower case" {
    for (folds[0 .. folds.len - 1], folds[1..]) |x, y| try testing.expect(x.hi < y.lo);
    for (folds) |f| try testing.expect(f.lo <= f.hi);
    var cp: u21 = 0;
    while (cp < 0x110000) : (cp += 1) {
        const once = fold(cp);
        errdefer std.debug.print("U+{X} folds to U+{X}, then to U+{X}\n", .{ cp, once, fold(once) });
        try testing.expectEqual(once, fold(once));
        // Surrogates are no characters; nothing folds into them.
        if (once != cp) try testing.expect(once < 0xD800 or once > 0xDFFF);
    }
    const pairs_ = [_][2]u21{
        .{ 'A', 'a' },       .{ 0xC9, 0xE9 },     .{ 0x178, 0xFF },    .{ 0x17F, 's' },
        .{ 0x1C5, 0x1C6 },   .{ 0x391, 0x3B1 },   .{ 0x3A3, 0x3C3 },   .{ 0x3C2, 0x3C3 },
        .{ 0x386, 0x3AC },   .{ 0x410, 0x430 },   .{ 0x401, 0x451 },   .{ 0x531, 0x561 },
        .{ 0x1E9E, 0xDF },   .{ 0x1F59, 0x1F51 }, .{ 0x1F5A, 0x1F5A }, .{ 0x212A, 'k' },
        .{ 0xFF21, 0xFF41 }, .{ 0x130, 0x130 },   .{ 0xDF, 0xDF },     .{ 0x4E00, 0x4E00 },
        .{ 0x1A0, 0x1A1 },   .{ 0x1AF, 0x1B0 },   .{ 0x181, 0x253 },   .{ 0x23B, 0x23C },
        .{ 0x1C92, 0x10D2 }, .{ 0x1CBF, 0x10FF }, .{ 0x1C85, 0x442 },  .{ 0x1C88, 0xA64B },
    };
    for (pairs_) |p| try testing.expectEqual(p[1], fold(p[0]));
}

test "tokens fold case, keep digits and non-ASCII bytes, split on the rest" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ts = try tokens(arena, "  Hello, WORLD! x2 -- CAFÉ_au-lait  hello café ΣΟΦΊΑ σοφία");
    const want = [_][]const u8{ "au", "café", "hello", "lait", "world", "x2", "σοφία" };
    try testing.expectEqual(want.len, ts.len);
    for (want, ts) |w, t| try testing.expectEqualStrings(w, t);
    try testing.expectEqual(@as(usize, 0), (try tokens(arena, " ... ")).len);
    // Non-ASCII spaces and punctuation separate tokens too.
    const prose = try tokens(arena, "hello\u{2014}world \u{201C}quoted\u{201D} x\u{A0}y \u{3001}\u{65E5}\u{3005}\u{FF01}");
    const words = [_][]const u8{ "hello", "quoted", "world", "x", "y", "\u{65E5}\u{3005}" };
    try testing.expectEqual(words.len, prose.len);
    for (words, prose) |w, t| try testing.expectEqualStrings(w, t);
    try testing.expectEqual(@as(usize, 0), (try tokens(arena, "")).len);
    // A token past the bound is dropped; its neighbours stay.
    const long = try arena.alloc(u8, max_token + 1);
    @memset(long, 'a');
    const text = try std.mem.concat(arena, u8, &.{ "b ", long, " c" });
    const kept = try tokens(arena, text);
    try testing.expectEqual(@as(usize, 2), kept.len);
    try testing.expectEqualStrings("b", kept[0]);
    try testing.expectEqualStrings("c", kept[1]);
    // Bytes that are not UTF-8 stay as they are; a fold may shorten a token.
    const odd = try tokens(arena, "\xC3\xFF\xE9 \u{212A}ELVIN");
    try testing.expectEqual(@as(usize, 2), odd.len);
    try testing.expectEqualStrings("kelvin", odd[0]);
    try testing.expectEqualStrings("\xC3\xFF\xE9", odd[1]);
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
    const long_text = try std.mem.concat(arena, u8, &.{ "zebra ", &@as([200]u8, @splat('x')) });
    const vb = try key.valBytes(arena, .{ .string = long_text });
    try store.writeBatch(txn, 2, &.{
        .{ .e = e2, .a = a, .vbytes = vb, .payload = long_text, .added = true, .avet = false, .vaet = false },
    }, arena);
    try index(store, txn, arena, a, e2, long_text, true);
    try testing.expectEqual(@as(usize, 1), (try search(store, txn, arena, a, try tokens(arena, "zebra"))).len);
    try indexRow(store, txn, arena, a, e2, vb, false);
    try testing.expectEqual(@as(usize, 0), (try search(store, txn, arena, a, try tokens(arena, "zebra"))).len);
}
