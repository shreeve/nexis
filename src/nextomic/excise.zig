//! excise.zig — removing an entity's datoms from every tree and from
//! the txlog (NEXTOMIC.md §4 "Excision").
//!
//! An excision names an entity, or an entity and one attribute, and
//! runs inside the write transaction of the transaction that records
//! it (transact.zig owns begin, `:db/txInstant` and commit):
//!   - every current and history datom `[e a? ...]` leaves the eight
//!     index trees: EAVT and EAVT-h by one prefix delete each, AEVT and
//!     AEVT-h by a prefix delete when the attribute is given, and the
//!     rest one key at a time from a scan of the EAVT-h and EAVT rows,
//!     which together name every datom the entity ever had;
//!   - every txlog entry holding one of those datoms is rewritten
//!     without their rows and marked with the entity; an entry that
//!     ends up empty stays, with its instant and its marker, so
//!     `tx-range` replays the same transactions with the datoms gone;
//!   - the per-attribute current counts drop by the current rows
//!     removed, and the tokens tree loses the rows of every current
//!     string value of a `:db/fulltext` attribute.
//! Datoms that refer to the entity through a ref attribute are not
//! its datoms and stay. Nothing here touches `sys["t"]` or the
//! transaction's own entry: those are the transaction's.

const std = @import("std");
const emdb = @import("emdb");
const key = @import("key.zig");
const datom_mod = @import("datom.zig");
const store_mod = @import("store.zig");
const schema_mod = @import("schema.zig");
const fulltext = @import("fulltext.zig");

const Allocator = std.mem.Allocator;
const Txn = emdb.Txn;
const Store = store_mod.Store;
const Schema = schema_mod.Schema;
const Index = key.Index;

/// What an excision removed: the transactions it rewrote and the
/// current rows per attribute it deleted.
pub const Outcome = struct {
    /// Every `t` whose txlog entry was rewritten, ascending.
    ts: []const u64,
    /// Rows of the entity's history removed: its retired EAVT-h rows
    /// and its current EAVT rows, every assertion and retraction it
    /// ever had.
    removed: u64,
    /// Attribute id → current rows removed.
    counts: std.AutoHashMapUnmanaged(u32, u64),
};

/// One row to delete from the trees other than EAVT.
const Row = struct { a: u32, vbytes: []const u8, top: ?key.Top };

/// Remove the datoms of `e` (under `a` when given) from the index trees.
/// `schema` is the schema at the transaction's `now`, which knows which
/// attributes AVET and VAET carry. Scratch lives in `arena`.
pub fn removeDatoms(store: *Store, txn: *Txn, arena: Allocator, schema: *const Schema, e: u64, a: ?u32) !Outcome {
    var rows: std.ArrayList(Row) = .empty;
    var ts: std.array_hash_map.Auto(u64, void) = .empty;
    var counts: std.AutoHashMapUnmanaged(u32, u64) = .empty;
    const prefix = try key.prefixBytes(arena, .eavt, .{ .e = e, .a = a });

    // The history rows and the current rows together name every datom
    // the entity ever had; the current rows are those still asserted,
    // each the latest assertion of its fact. Both are collected before
    // anything is deleted, so no cursor walks a tree being changed.
    {
        var s = try Store.scan(txn, store.trees.hist(.eavt), prefix);
        s.cursor.keysOnly = true;
        while (try s.next()) |kv| {
            const parts = try key.unpackKey(.eavt, true, kv.key);
            try rows.append(arena, .{ .a = parts.a, .vbytes = try arena.dupe(u8, parts.v), .top = parts.top });
            try ts.put(arena, parts.top.?.t, {});
        }
    }
    {
        var s = try Store.scan(txn, store.trees.cur(.eavt), prefix);
        while (try s.next()) |kv| {
            const parts = try key.unpackKey(.eavt, false, kv.key);
            try rows.append(arena, .{ .a = parts.a, .vbytes = try arena.dupe(u8, parts.v), .top = null });
            try ts.put(arena, (try key.readCurrent(kv.value)).t, {});
            const g = try counts.getOrPut(arena, parts.a);
            if (!g.found_existing) g.value_ptr.* = 0;
            g.value_ptr.* += 1;
        }
    }

    for (rows.items) |r| {
        const attr = schema.attr(r.a) orelse return error.Corrupted;
        const history = r.top != null;
        if (!history and attr.fulltext) try fulltext.indexRow(store, txn, arena, r.a, e, r.vbytes, false);
        // AEVT under a given attribute is one prefix delete below.
        if (a == null) try delete(store, txn, arena, .aevt, history, e, r);
        if (attr.inAvet()) try delete(store, txn, arena, .avet, history, e, r);
        if (attr.inVaet()) try delete(store, txn, arena, .vaet, history, e, r);
    }
    if (a) |attr_id| {
        const aevt_prefix = try key.prefixBytes(arena, .aevt, .{ .a = attr_id, .e = e });
        _ = try txn.delPrefixFromTree(store.trees.cur(.aevt), aevt_prefix);
        _ = try txn.delPrefixFromTree(store.trees.hist(.aevt), aevt_prefix);
    }
    _ = try txn.delPrefixFromTree(store.trees.cur(.eavt), prefix);
    _ = try txn.delPrefixFromTree(store.trees.hist(.eavt), prefix);

    const sorted = try arena.dupe(u64, ts.keys());
    std.mem.sort(u64, sorted, {}, std.sort.asc(u64));
    return .{ .ts = sorted, .removed = rows.items.len, .counts = counts };
}

fn delete(store: *Store, txn: *Txn, arena: Allocator, index: Index, history: bool, e: u64, r: Row) !void {
    const k = try key.keyBytes(arena, index, e, r.a, r.vbytes, r.top);
    const tree = if (history) store.trees.hist(index) else store.trees.cur(index);
    _ = try txn.delFromTree(tree, k);
}

/// Rewrite the txlog entry of each `t` in `ts` without the datoms of
/// `e` (under `a` when given), marking it with `e` (datom.zig
/// `exciseTxlog`); the entry's instant and its other rows stand as
/// stored.
pub fn rewriteTxlog(store: *Store, txn: *Txn, arena: Allocator, ts: []const u64, e: u64, a: ?u32, types: datom_mod.Source) !void {
    for (ts) |t| {
        const bytes = (try store.getTxlog(txn, t)) orelse return error.Corrupted;
        try store.putTxlog(txn, t, try datom_mod.exciseTxlog(arena, bytes, e, a, types));
    }
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "removeDatoms empties every tree of the entity and reports its transactions" {
    var td = try store_mod.TestDir.init("excise_trees");
    defer td.deinit();
    const store = try Store.open(testing.allocator, td.path.ptr, .{});
    defer store.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Two attributes: 100 (indexed) and 101 (ref); entity e at t=2 and
    // t=3, a retraction at t=3, and another entity f referring to e.
    const boot = store_mod.boot;
    const e: u64 = 1 << 33;
    const f: u64 = (1 << 33) + 1;
    const s1 = try key.valBytes(arena, .{ .string = "one" });
    const s2 = try key.valBytes(arena, .{ .string = "two" });
    const rf = try key.valBytes(arena, .{ .ref = f });
    const re = try key.valBytes(arena, .{ .ref = e });
    {
        const txn = try store.beginWrite(.none);
        const vt_s = try key.valBytes(arena, .{ .keyword = boot.type_string });
        const vt_r = try key.valBytes(arena, .{ .keyword = boot.type_ref });
        const c1 = try key.valBytes(arena, .{ .keyword = boot.card_one });
        const yes = try key.valBytes(arena, .{ .boolean = true });
        try store.writeBatch(txn, 2, &.{
            .{ .e = 100, .a = boot.value_type, .vbytes = vt_s, .added = true, .avet = false, .vaet = false },
            .{ .e = 100, .a = boot.cardinality, .vbytes = c1, .added = true, .avet = false, .vaet = false },
            .{ .e = 100, .a = boot.index, .vbytes = yes, .added = true, .avet = false, .vaet = false },
            .{ .e = 100, .a = store.fulltext_aid, .vbytes = yes, .added = true, .avet = false, .vaet = false },
            .{ .e = 101, .a = boot.value_type, .vbytes = vt_r, .added = true, .avet = false, .vaet = false },
            .{ .e = 101, .a = boot.cardinality, .vbytes = c1, .added = true, .avet = false, .vaet = false },
            .{ .e = e, .a = 100, .vbytes = s1, .added = true, .avet = true, .vaet = false },
            .{ .e = e, .a = 101, .vbytes = rf, .added = true, .avet = false, .vaet = true },
        }, arena);
        try store.writeBatch(txn, 3, &.{
            .{ .e = e, .a = 100, .vbytes = s1, .added = false, .avet = true, .vaet = false },
            .{ .e = e, .a = 100, .vbytes = s2, .added = true, .avet = true, .vaet = false },
            .{ .e = f, .a = 101, .vbytes = re, .added = true, .avet = false, .vaet = true },
        }, arena);
        try store.writeAttrCount(txn, 100, 1);
        try store.writeAttrCount(txn, 101, 2);
        try fulltext.index(store, txn, arena, 100, e, "two", true);
        try store.writeT(txn, 3);
        try txn.commit();
    }
    const txn = try store.beginWrite(.none);
    defer txn.abort();
    const schema = try Schema.build(testing.allocator, store, txn, 3);
    defer schema.deinit();

    const out = try removeDatoms(store, txn, arena, schema, e, null);
    try testing.expectEqualSlices(u64, &.{ 2, 3 }, out.ts);
    try testing.expectEqual(@as(u64, 4), out.removed);
    try testing.expectEqual(@as(u64, 1), out.counts.get(100).?);
    try testing.expectEqual(@as(u64, 1), out.counts.get(101).?);

    // Nothing of e remains in any tree; f's ref to e does.
    const pe = try key.prefixBytes(arena, .eavt, .{ .e = e });
    inline for (.{ Index.eavt, Index.aevt, Index.avet, Index.vaet }) |ix| {
        var cur = try Store.scan(txn, store.trees.cur(ix), &.{});
        while (try cur.next()) |kv| try testing.expect((try key.unpackKey(ix, false, kv.key)).e != e);
        var hist = try Store.scan(txn, store.trees.hist(ix), &.{});
        while (try hist.next()) |kv| try testing.expect((try key.unpackKey(ix, true, kv.key)).e != e);
    }
    var none = try Store.scan(txn, store.trees.cur(.eavt), pe);
    try testing.expect((try none.next()) == null);
    var vaet = try Store.scan(txn, store.trees.cur(.vaet), try key.prefixBytes(arena, .vaet, .{ .v = re }));
    try testing.expectEqual(f, (try key.unpackKey(.vaet, false, (try vaet.next()).?.key)).e);
    try testing.expectEqual(@as(usize, 0), (try fulltext.search(store, txn, arena, 100, try fulltext.tokens(arena, "two"))).len);

    // Attribute-only excision leaves the other attribute alone.
    const g: u64 = (1 << 33) + 2;
    try store.writeBatch(txn, 4, &.{
        .{ .e = g, .a = 100, .vbytes = s1, .added = true, .avet = true, .vaet = false },
        .{ .e = g, .a = 101, .vbytes = rf, .added = true, .avet = false, .vaet = true },
    }, arena);
    const out2 = try removeDatoms(store, txn, arena, schema, g, 100);
    try testing.expectEqualSlices(u64, &.{4}, out2.ts);
    try testing.expectEqual(@as(u64, 1), out2.removed);
    var left = try Store.scan(txn, store.trees.cur(.eavt), try key.prefixBytes(arena, .eavt, .{ .e = g }));
    try testing.expectEqual(@as(u32, 101), (try key.unpackKey(.eavt, false, (try left.next()).?.key)).a);
    try testing.expect((try left.next()) == null);
    var avet = try Store.scan(txn, store.trees.cur(.avet), try key.prefixBytes(arena, .avet, .{ .a = 100 }));
    try testing.expect((try avet.next()) == null);
}
