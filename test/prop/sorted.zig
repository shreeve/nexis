//! test/prop/sorted.zig — randomized properties of the sorted map and
//! set heap kinds (docs/SORTED.md §9).
//!
//!   P1. Model: random assoc/dissoc (maps) and conj/disj (sets) against
//!       a sorted-array model; after every step the tree keeps its
//!       invariants (sizes, (3, 2) balance, strictly ascending keys),
//!       the count and every lookup agree, and the walk in both
//!       directions is the model's order.
//!   P2. Persistence: a version kept aside is unchanged by every later
//!       update, which shares its nodes.
//!   P3. Ranges: the walk from a random bound, ascending and
//!       descending, is the model's slice from that bound.
//!   P4. Comparators: a descending order and one that equates keys
//!       (by last digit) keep the invariants under their own order,
//!       and a key the comparator finds equal replaces the value but
//!       keeps the key.
//!   P5. Equality and hash: a sorted map equals, and hashes as, the
//!       hash map with its entries, and a sorted set the hash set;
//!       across two comparators too; one differing value or element
//!       makes them unequal; a map is never equal to a set.
//!   P6. Natural order: strings, keywords and vectors of mixed length
//!       sort as `compare` orders them.
//!   P7. GC: the root alone keeps every node, key and value alive
//!       through a collection; a dropped version's private nodes are
//!       swept.
//!   P8. Codec: random natural-order maps and sets round-trip equal,
//!       hash-equal and sorted.

const std = @import("std");
const nx = @import("nexis");
const value = nx.value;
const heap_mod = nx.heap;
const champ = nx.champ;
const sorted = nx.sorted;
const vector = nx.vector;
const string = nx.string;
const dispatch = nx.dispatch;
const codec = nx.codec;
const gc = nx.gc;
const intern_mod = nx.intern;

const Value = value.Value;
const Heap = heap_mod.Heap;
const Order = std.math.Order;
const testing = std.testing;

const prng_seed: u64 = 0x736F_7274_6564_2121; // "sorted!!"

fn fx(n: i64) Value {
    return value.fromFixnum(n).?;
}

/// Fixnums, ascending.
const Asc = struct {
    pub const Error = error{};
    pub fn order(_: Asc, a: Value, b: Value) Error!Order {
        return std.math.order(a.asFixnum(), b.asFixnum());
    }
};

/// Fixnums, descending.
const Desc = struct {
    pub const Error = error{};
    pub fn order(_: Desc, a: Value, b: Value) Error!Order {
        return std.math.order(b.asFixnum(), a.asFixnum());
    }
};

/// Fixnums by their last decimal digit: 3, 13 and 23 are one key.
const LastDigit = struct {
    pub const Error = error{};
    pub fn order(_: LastDigit, a: Value, b: Value) Error!Order {
        return std.math.order(@mod(a.asFixnum(), 10), @mod(b.asFixnum(), 10));
    }
};

/// The model: keys ascending, one value each.
const Model = struct {
    keys: std.ArrayList(i64) = .empty,
    vals: std.ArrayList(i64) = .empty,

    fn deinit(m: *Model) void {
        m.keys.deinit(testing.allocator);
        m.vals.deinit(testing.allocator);
    }

    fn clone(m: *const Model) !Model {
        return .{ .keys = try m.keys.clone(testing.allocator), .vals = try m.vals.clone(testing.allocator) };
    }

    fn index(m: *const Model, k: i64) struct { at: usize, found: bool } {
        const at = std.sort.lowerBound(i64, m.keys.items, k, orderI64);
        return .{ .at = at, .found = at < m.keys.items.len and m.keys.items[at] == k };
    }

    fn put(m: *Model, k: i64, v: i64) !void {
        const i = m.index(k);
        if (i.found) {
            m.vals.items[i.at] = v;
            return;
        }
        try m.keys.insert(testing.allocator, i.at, k);
        try m.vals.insert(testing.allocator, i.at, v);
    }

    fn del(m: *Model, k: i64) void {
        const i = m.index(k);
        if (!i.found) return;
        _ = m.keys.orderedRemove(i.at);
        _ = m.vals.orderedRemove(i.at);
    }
};

fn orderI64(target: i64, item: i64) Order {
    return std.math.order(target, item);
}

/// `v` holds exactly the model's entries, in its order both ways.
fn expectMatches(v: Value, model: *const Model, is_map: bool) !void {
    try sorted.checkInvariants(v, Asc{});
    const n = model.keys.items.len;
    try testing.expectEqual(n, sorted.count(v));
    var up = sorted.Iter.init(v, true);
    var down = sorted.Iter.init(v, false);
    for (0..n) |i| {
        const e = up.next().?;
        try testing.expectEqual(model.keys.items[i], e.key.asFixnum());
        if (is_map) try testing.expectEqual(model.vals.items[i], e.value.asFixnum());
        try testing.expectEqual(model.keys.items[n - 1 - i], down.next().?.key.asFixnum());
    }
    try testing.expect(up.next() == null and down.next() == null);
}

test "P1, P2: random updates against a sorted model, with old versions unchanged" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var prng = std.Random.DefaultPrng.init(prng_seed);
    const r = prng.random();
    for ([_]bool{ true, false }) |is_map| {
        for (0..30) |_| {
            const range = r.intRangeAtMost(i64, 1, 400);
            var v = try sorted.empty(&heap, if (is_map) .sorted_map else .sorted_set, value.nilValue());
            var model: Model = .{};
            defer model.deinit();
            var kept: ?struct { v: Value, model: Model } = null;
            defer if (kept) |*k| k.model.deinit();
            for (0..r.intRangeAtMost(usize, 1, 600)) |step| {
                const k = r.intRangeAtMost(i64, -range, range);
                if (r.uintLessThan(u8, 3) != 0) {
                    const val = r.intRangeAtMost(i64, 0, 5);
                    v = if (is_map) try sorted.assoc(&heap, v, fx(k), fx(val), Asc{}) else try sorted.conj(&heap, v, fx(k), Asc{});
                    try model.put(k, if (is_map) val else 0);
                } else {
                    v = try sorted.without(&heap, v, fx(k), Asc{});
                    model.del(k);
                }
                try expectMatches(v, &model, is_map);
                const probe = r.intRangeAtMost(i64, -range - 1, range + 1);
                const hit = try sorted.find(v, fx(probe), Asc{});
                try testing.expectEqual(model.index(probe).found, hit != null);
                if (step == 50 and kept == null) kept = .{ .v = v, .model = try model.clone() };
            }
            if (kept) |*k| try expectMatches(k.v, &k.model, is_map);
        }
    }
}

test "P3: a walk from a random bound, either way, is the model's slice from it" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var prng = std.Random.DefaultPrng.init(prng_seed +% 3);
    const r = prng.random();
    for (0..200) |_| {
        var s = try sorted.empty(&heap, .sorted_set, value.nilValue());
        var model: Model = .{};
        defer model.deinit();
        for (0..r.uintLessThan(usize, 80)) |_| {
            const k = r.intRangeAtMost(i64, 0, 100);
            s = try sorted.conj(&heap, s, fx(k), Asc{});
            try model.put(k, 0);
        }
        const bound = r.intRangeAtMost(i64, -5, 105);
        const at = model.index(bound);
        var up = try sorted.Iter.from(s, fx(bound), true, Asc{});
        for (model.keys.items[at.at..]) |k| try testing.expectEqual(k, up.next().?.key.asFixnum());
        try testing.expect(up.next() == null);
        // Descending: from the greatest key not above the bound.
        const top = if (at.found) at.at + 1 else at.at;
        var down = try sorted.Iter.from(s, fx(bound), false, Asc{});
        var i = top;
        while (i > 0) {
            i -= 1;
            try testing.expectEqual(model.keys.items[i], down.next().?.key.asFixnum());
        }
        try testing.expect(down.next() == null);
    }
}

test "P4: a comparator of its own orders the tree, and its equal keys are one key" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var prng = std.Random.DefaultPrng.init(prng_seed +% 4);
    const r = prng.random();
    var desc = try sorted.empty(&heap, .sorted_map, value.nilValue());
    var digit = try sorted.empty(&heap, .sorted_map, value.nilValue());
    var first_of_digit: [10]?i64 = @splat(null);
    for (0..1000) |i| {
        const k = r.intRangeAtMost(i64, 0, 999);
        desc = try sorted.assoc(&heap, desc, fx(k), fx(@intCast(i)), Desc{});
        digit = try sorted.assoc(&heap, digit, fx(k), fx(@intCast(i)), LastDigit{});
        const d: usize = @intCast(@mod(k, 10));
        if (first_of_digit[d] == null) first_of_digit[d] = k;
        if (r.uintLessThan(u8, 5) == 0) desc = try sorted.without(&heap, desc, fx(r.intRangeAtMost(i64, 0, 999)), Desc{});
        try sorted.checkInvariants(desc, Desc{});
        try sorted.checkInvariants(digit, LastDigit{});
    }
    var prev: ?i64 = null;
    var it = sorted.Iter.init(desc, true);
    while (it.next()) |e| {
        if (prev) |p| try testing.expect(e.key.asFixnum() < p);
        prev = e.key.asFixnum();
    }
    try testing.expectEqual(@as(usize, 10), sorted.count(digit));
    for (first_of_digit, 0..) |k, d| {
        const e = (try sorted.find(digit, fx(@intCast(d + 10)), LastDigit{})).?;
        try testing.expectEqual(k.?, e.key.asFixnum());
    }
}

fn expectSame(a: Value, b: Value) !void {
    try testing.expect(dispatch.equal(a, b));
    try testing.expect(dispatch.equal(b, a));
    try testing.expectEqual(dispatch.hashValue(a), dispatch.hashValue(b));
}

fn expectDifferent(a: Value, b: Value) !void {
    try testing.expect(!dispatch.equal(a, b));
    try testing.expect(!dispatch.equal(b, a));
}

test "P5: a sorted map or set is = to, and hashes as, the hash collection with its entries, across orders" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var prng = std.Random.DefaultPrng.init(prng_seed +% 5);
    const r = prng.random();
    const h = &dispatch.hashValue;
    const eq = &dispatch.equal;
    for (0..300) |_| {
        var sm = try sorted.empty(&heap, .sorted_map, value.nilValue());
        var dm = try sorted.empty(&heap, .sorted_map, fx(0));
        var hm = try champ.mapEmpty(&heap);
        var ss = try sorted.empty(&heap, .sorted_set, value.nilValue());
        var ds = try sorted.empty(&heap, .sorted_set, fx(0));
        var hs = try champ.setEmpty(&heap);
        const n = r.uintLessThan(usize, 60);
        for (0..n) |_| {
            const k = fx(r.intRangeAtMost(i64, -50, 50));
            const v = fx(r.intRangeAtMost(i64, 0, 3));
            sm = try sorted.assoc(&heap, sm, k, v, Asc{});
            dm = try sorted.assoc(&heap, dm, k, v, Desc{});
            hm = try champ.mapAssoc(&heap, hm, k, v, h, eq);
            ss = try sorted.conj(&heap, ss, k, Asc{});
            ds = try sorted.conj(&heap, ds, k, Desc{});
            hs = try champ.setConj(&heap, hs, k, h, eq);
        }
        try expectSame(sm, hm);
        try expectSame(sm, dm);
        try expectSame(dm, hm);
        try expectSame(ss, hs);
        try expectSame(ss, ds);
        try expectSame(ds, hs);
        if (n > 0 and sorted.count(sm) > 0) {
            const e = sorted.entryAt(sm, r.uintLessThan(usize, sorted.count(sm)));
            const changed = try sorted.assoc(&heap, sm, e.key, fx(99), Asc{});
            try expectDifferent(changed, hm);
            try expectDifferent(changed, dm);
            const fewer = try sorted.without(&heap, ss, e.key, Asc{});
            try expectDifferent(fewer, hs);
            try expectDifferent(fewer, ds);
            try expectDifferent(sm, ss);
        }
        try expectDifferent(sm, try vector.empty(&heap));
    }
    // Empty ones: equal across kinds, never a map to a set.
    try expectSame(try sorted.empty(&heap, .sorted_map, value.nilValue()), try champ.mapEmpty(&heap));
    try expectSame(try sorted.empty(&heap, .sorted_set, fx(0)), try champ.setEmpty(&heap));
    try expectDifferent(try sorted.empty(&heap, .sorted_map, value.nilValue()), try champ.setEmpty(&heap));
}

test "P6: strings, keywords and vectors sort as compare orders them" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var interner = intern_mod.Interner.init(testing.allocator);
    defer interner.deinit();
    const order = sorted.Natural{ .interner = &interner };
    var prng = std.Random.DefaultPrng.init(prng_seed +% 6);
    const r = prng.random();
    var strings = try sorted.empty(&heap, .sorted_set, value.nilValue());
    var keywords = try sorted.empty(&heap, .sorted_set, value.nilValue());
    var vectors = try sorted.empty(&heap, .sorted_set, value.nilValue());
    for (0..500) |_| {
        var buf: [6]u8 = undefined;
        const n = r.intRangeAtMost(usize, 1, buf.len);
        for (buf[0..n]) |*b| b.* = r.intRangeAtMost(u8, 'a', 'd');
        strings = try sorted.conj(&heap, strings, try string.fromBytes(&heap, buf[0..n]), order);
        if (r.boolean()) buf[r.uintLessThan(usize, n)] = '/';
        keywords = try sorted.conj(&heap, keywords, interner.internKeywordValue(buf[0..n]) catch continue, order);
        var elems: [3]Value = undefined;
        const len = r.uintLessThan(usize, 4);
        for (elems[0..len]) |*e| e.* = fx(r.intRangeAtMost(i64, 0, 3));
        vectors = try sorted.conj(&heap, vectors, try vector.fromSlice(&heap, elems[0..len]), order);
    }
    for ([_]Value{ strings, keywords, vectors }) |s| try sorted.checkInvariants(s, order);
    // Vectors: every shorter one first.
    var it = sorted.Iter.init(vectors, true);
    var last_len: usize = 0;
    while (it.next()) |e| {
        try testing.expect(vector.count(e.key) >= last_len);
        last_len = vector.count(e.key);
    }
    // A key of another kind has no place in the order.
    try testing.expectError(error.KindMismatch, sorted.conj(&heap, strings, fx(1), order));
}

test "P7: the root alone keeps the tree alive; a dropped version's own nodes are swept" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var collector = gc.Collector.init(&heap);
    defer collector.deinit();
    var m = try sorted.empty(&heap, .sorted_map, value.nilValue());
    for (0..300) |i| m = try sorted.assoc(&heap, m, fx(@intCast(i)), try string.fromBytes(&heap, "v"), Asc{});
    _ = collector.collect(&.{heap_mod.Heap.asHeapHeader(m)});
    // The root, 300 nodes and 300 strings.
    try testing.expectEqual(@as(usize, 601), heap.liveCount());
    for (0..300) |i| try testing.expectEqualStrings("v", string.asBytes((try sorted.find(m, fx(@intCast(i)), Asc{})).?.value));
    const smaller = try sorted.without(&heap, m, fx(150), Asc{});
    _ = collector.collect(&.{heap_mod.Heap.asHeapHeader(smaller)});
    try testing.expectEqual(@as(usize, 299), sorted.count(smaller));
    try sorted.checkInvariants(smaller, Asc{});
    // One node and its string fewer, and the one root; the path copy
    // replaced the rest of the dropped version's path.
    try testing.expectEqual(@as(usize, 599), heap.liveCount());
}

test "P8: natural-order maps and sets round-trip through the codec equal, hash-equal and sorted" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var interner = intern_mod.Interner.init(testing.allocator);
    defer interner.deinit();
    const order = sorted.Natural{ .interner = &interner };
    var prng = std.Random.DefaultPrng.init(prng_seed +% 8);
    const r = prng.random();
    for (0..300) |_| {
        const is_map = r.boolean();
        var v = try sorted.empty(&heap, if (is_map) .sorted_map else .sorted_set, value.nilValue());
        const use_strings = r.boolean();
        for (0..r.uintLessThan(usize, 40)) |_| {
            var buf: [4]u8 = undefined;
            const n = r.intRangeAtMost(usize, 1, buf.len);
            for (buf[0..n]) |*b| b.* = r.intRangeAtMost(u8, 'a', 'z');
            const k = if (use_strings) try string.fromBytes(&heap, buf[0..n]) else fx(r.intRangeAtMost(i64, -1000, 1000));
            v = if (is_map) try sorted.assoc(&heap, v, k, try interner.internKeywordValue(buf[0..n]), order) else try sorted.conj(&heap, v, k, order);
        }
        const bytes = try codec.encode(testing.allocator, &interner, v);
        defer testing.allocator.free(bytes);
        const got = try codec.decode(&heap, &interner, bytes, &dispatch.hashValue, &dispatch.equal);
        try testing.expectEqual(v.kind(), got.kind());
        try sorted.checkInvariants(got, order);
        try expectSame(v, got);
        const again = try codec.encode(testing.allocator, &interner, got);
        defer testing.allocator.free(again);
        try testing.expectEqualSlices(u8, bytes, again);
    }
}
