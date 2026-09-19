//! schema.zig — attributes as-of a basis, built from the attribute
//! partition's datoms (NEXTOMIC.md §4 "Schema as-of").
//!
//! Invariants:
//!   - An entity in the attribute partition is an attribute iff it has a
//!     `:db/valueType`; its entity id is its attribute id.
//!   - Value type never changes once written; `:db/index`, `:db/unique`
//!     and `:db/fulltext` can only be added; `:db/cardinality` may
//!     change, and an attribute whose cardinality ever changed carries
//!     the whole timeline of its assertions. So a Schema built at basis
//!     B answers every earlier basis: `attrAt(a, b)` for `b < B` hides
//!     attributes created after `b`, masks `:db/unique`, `:db/index`,
//!     `:db/isComponent` and `:db/fulltext` each by the `t` of its own
//!     assertion when that is after `b`, and reads the cardinality in
//!     force at `b` off the timeline.
//!   - `:db/fulltext` is the one bootstrap attribute whose id differs
//!     between stores (`Store.fulltext_aid`); the store supplies it.
//!   - `count` is the number of current AEVT entries of the attribute at
//!     the transaction the schema was built in; it is a planner estimate.

const std = @import("std");
const emdb = @import("emdb");
const key = @import("key.zig");
const store_mod = @import("store.zig");

const Allocator = std.mem.Allocator;
const Store = store_mod.Store;
const Txn = emdb.Txn;
const ValueType = key.ValueType;
const boot = store_mod.boot;

pub const Cardinality = enum { one, many };
pub const Unique = enum { none, identity, value };

/// One `:db/cardinality` assertion: the cardinality from `t` on.
pub const CardAt = struct { t: u64, cardinality: Cardinality };

pub const Attr = struct {
    id: u32,
    value_type: ValueType,
    cardinality: Cardinality = .one,
    unique: Unique = .none,
    indexed: bool = false,
    component: bool = false,
    /// `t` of the transaction that asserted `:db/valueType`.
    since: u64,
    /// `t` of the `:db/unique` assertion; 0 without one.
    unique_t: u64 = 0,
    /// `t` of the `:db/index` assertion in force; 0 without one.
    index_t: u64 = 0,
    /// `t` of the `:db/isComponent` assertion in force; 0 without one.
    component_t: u64 = 0,
    /// `t` from which AVET carries the attribute (the first assertion of
    /// `:db/index true` or `:db/unique`); 0 when it never did.
    avet_since: u64 = 0,
    /// `t` of the `:db/cardinality` assertion in force.
    card_t: u64 = 0,
    /// `:db/fulltext true`: the tokens tree carries the attribute's
    /// string values.
    fulltext: bool = false,
    /// `t` of the `:db/fulltext true` assertion; 0 without one.
    fulltext_since: u64 = 0,
    /// Every `:db/cardinality` assertion up to the schema's basis, in
    /// `t` order, for an attribute whose cardinality has changed; empty
    /// when it never did.
    card_changes: []const CardAt = &.{},
    /// Current AEVT entries when the schema was built.
    count: u64 = 0,

    pub fn inAvet(self: Attr) bool {
        return self.indexed or self.unique != .none;
    }

    pub fn inVaet(self: Attr) bool {
        return self.value_type == .ref;
    }

    pub fn many(self: Attr) bool {
        return self.cardinality == .many;
    }
};

pub const Schema = struct {
    arena: std.heap.ArenaAllocator,
    basis: u64,
    attrs: std.AutoHashMapUnmanaged(u32, Attr) = .empty,

    /// Build the schema as-of `basis` through `txn`, whose `sys["t"]` is
    /// `now`. When `basis == now` the current trees answer directly;
    /// otherwise the history trees are folded at `basis`.
    pub fn build(gpa: Allocator, store: *Store, txn: *Txn, basis: u64, now: u64) !*Schema {
        const self = try gpa.create(Schema);
        errdefer gpa.destroy(self);
        self.* = .{ .arena = std.heap.ArenaAllocator.init(gpa), .basis = basis };
        errdefer self.arena.deinit();
        const arena = self.arena.allocator();

        var start: [key.id_len]u8 = undefined;
        var end: [key.id_len]u8 = undefined;
        key.writeId(&start, 1);
        key.writeId(&end, key.attr_partition_end);

        var acc = Accumulator{ .fulltext_aid = store.fulltext_aid };
        if (basis == now) {
            var s = try Store.scanRange(txn, store.trees.cur(.eavt), &start, &end);
            while (s.next()) |kv| {
                if (kv.value.len < key.id_len) return error.Corrupted;
                const t = key.readId(kv.value[0..key.id_len]);
                try acc.row(self, arena, kv.key, t);
            }
        } else {
            var fs = try Store.foldScan(txn, store.trees.hist(.eavt), &start, &end, .{ .as_of = basis });
            while (fs.next()) |r| try acc.row(self, arena, r.fact, r.t);
        }
        try acc.flush(self, arena);

        var it = self.attrs.valueIterator();
        while (it.next()) |a| {
            a.count = try store.attrCount(txn, a.id);
            if (a.card_t != a.since) a.card_changes = try cardTimeline(arena, store, txn, a.id, basis);
        }
        return self;
    }

    /// The `:db/cardinality` assertions of attribute `a` with `t <=
    /// basis`, from the history tree, in `t` order.
    fn cardTimeline(arena: Allocator, store: *Store, txn: *Txn, a: u32, basis: u64) ![]const CardAt {
        var out: std.ArrayList(CardAt) = .empty;
        const prefix = try key.prefixBytes(arena, .eavt, .{ .e = a, .a = boot.cardinality });
        var s = try Store.scan(txn, store.trees.hist(.eavt), prefix);
        while (s.next()) |kv| {
            const parts = try key.unpackKey(.eavt, true, kv.key);
            const top = parts.top.?;
            if (!top.added or top.t > basis) continue;
            const kv2 = try key.decodeVal(arena, parts.v);
            if (kv2 != .val or kv2.val != .keyword) return error.Corrupted;
            const c: Cardinality = switch (kv2.val.keyword) {
                boot.card_one => .one,
                boot.card_many => .many,
                else => return error.Corrupted,
            };
            try out.append(arena, .{ .t = top.t, .cardinality = c });
        }
        // The tree orders by value before `top`; the timeline is by `t`.
        std.mem.sort(CardAt, out.items, {}, struct {
            fn lt(_: void, x: CardAt, y: CardAt) bool {
                return x.t < y.t;
            }
        }.lt);
        return out.toOwnedSlice(arena);
    }

    pub fn deinit(self: *Schema) void {
        const gpa = self.arena.child_allocator;
        self.attrs.deinit(self.arena.allocator());
        self.arena.deinit();
        gpa.destroy(self);
    }

    /// The attribute as of this schema's basis.
    pub fn attr(self: *const Schema, a: u32) ?*const Attr {
        return self.attrs.getPtr(a);
    }

    /// The attribute as it was at basis `at <= self.basis`: absent when
    /// it did not exist yet; `:db/unique`, `:db/index`, `:db/isComponent`
    /// and `:db/fulltext` each cleared when its assertion came after
    /// `at`, AVET availability bounded the same way, and the
    /// cardinality in force at `at`. A flag reads its assertion in
    /// force alone, so before that assertion it is clear even when an
    /// earlier assertion had set it.
    pub fn attrAt(self: *const Schema, a: u32, at: u64) ?Attr {
        const p = self.attrs.getPtr(a) orelse return null;
        if (p.since > at) return null;
        var copy = p.*;
        if (copy.unique_t > at) {
            copy.unique = .none;
            copy.unique_t = 0;
        }
        if (copy.index_t > at) {
            copy.indexed = false;
            copy.index_t = 0;
        }
        if (copy.component_t > at) {
            copy.component = false;
            copy.component_t = 0;
        }
        if (copy.avet_since > at) copy.avet_since = 0;
        if (copy.fulltext_since > at) {
            copy.fulltext = false;
            copy.fulltext_since = 0;
        }
        for (copy.card_changes) |c| {
            if (c.t > at) break;
            copy.cardinality = c.cardinality;
            copy.card_t = c.t;
        }
        return copy;
    }

    pub fn count(self: *const Schema) usize {
        return self.attrs.count();
    }

    /// Accumulates one attribute entity's rows; rows arrive in `(e a)`
    /// order so an entity is complete when `e` changes.
    const Accumulator = struct {
        fulltext_aid: u32,
        e: u64 = 0,
        value_type: ?ValueType = null,
        type_t: u64 = 0,
        cardinality: Cardinality = .one,
        card_t: u64 = 0,
        unique: Unique = .none,
        unique_t: u64 = 0,
        indexed: bool = false,
        index_t: u64 = 0,
        component: bool = false,
        component_t: u64 = 0,
        fulltext: bool = false,
        fulltext_t: u64 = 0,

        fn row(self: *Accumulator, schema: *Schema, arena: Allocator, fact: []const u8, t: u64) !void {
            const parts = try key.unpackKey(.eavt, false, fact);
            if (parts.e != self.e) {
                try self.flush(schema, arena);
                self.* = .{ .fulltext_aid = self.fulltext_aid, .e = parts.e };
            }
            if (parts.a == self.fulltext_aid) {
                const kv = try key.decodeVal(arena, parts.v);
                if (kv != .val or kv.val != .boolean) return error.Corrupted;
                self.fulltext = kv.val.boolean;
                self.fulltext_t = t;
                return;
            }
            const kv = try key.decodeVal(arena, parts.v);
            switch (parts.a) {
                boot.value_type => {
                    if (kv != .val or kv.val != .keyword) return error.Corrupted;
                    self.value_type = boot.valueTypeOf(kv.val.keyword) orelse return error.Corrupted;
                    self.type_t = t;
                },
                boot.cardinality => {
                    if (kv != .val or kv.val != .keyword) return error.Corrupted;
                    self.cardinality = switch (kv.val.keyword) {
                        boot.card_one => .one,
                        boot.card_many => .many,
                        else => return error.Corrupted,
                    };
                    self.card_t = t;
                },
                boot.unique => {
                    if (kv != .val or kv.val != .keyword) return error.Corrupted;
                    self.unique = switch (kv.val.keyword) {
                        boot.unique_identity => .identity,
                        boot.unique_value => .value,
                        else => return error.Corrupted,
                    };
                    self.unique_t = t;
                },
                boot.index => {
                    if (kv != .val or kv.val != .boolean) return error.Corrupted;
                    self.indexed = kv.val.boolean;
                    self.index_t = t;
                },
                boot.is_component => {
                    if (kv != .val or kv.val != .boolean) return error.Corrupted;
                    self.component = kv.val.boolean;
                    self.component_t = t;
                },
                else => {},
            }
        }

        fn flush(self: *Accumulator, schema: *Schema, arena: Allocator) !void {
            const vt = self.value_type orelse return;
            if (self.e >= key.attr_partition_end) return error.Corrupted;
            var avet_since: u64 = 0;
            if (self.unique != .none) avet_since = self.unique_t;
            if (self.indexed and (avet_since == 0 or self.index_t < avet_since)) avet_since = self.index_t;
            try schema.attrs.put(arena, @intCast(self.e), .{
                .id = @intCast(self.e),
                .value_type = vt,
                .cardinality = self.cardinality,
                .unique = self.unique,
                .indexed = self.indexed,
                .component = self.component,
                .since = self.type_t,
                .unique_t = self.unique_t,
                .index_t = self.index_t,
                .component_t = self.component_t,
                .avet_since = avet_since,
                .card_t = self.card_t,
                .fulltext = self.fulltext,
                .fulltext_since = if (self.fulltext) self.fulltext_t else 0,
            });
        }
    };
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "bootstrap schema has the eight attributes with their shapes" {
    var td = try store_mod.TestDir.init("schema_boot");
    defer td.deinit();
    const store = try Store.open(testing.allocator, td.path.ptr, .{});
    defer store.close();
    const txn = try store.beginRead();
    defer txn.abort();

    const now = try store.readT(txn);
    for ([_]u64{ now, 1 }) |basis| {
        const schema = try Schema.build(testing.allocator, store, txn, basis, now);
        defer schema.deinit();
        try testing.expectEqual(@as(usize, boot.attrs.len), schema.count());
        const ident = schema.attr(boot.ident).?;
        try testing.expectEqual(ValueType.keyword, ident.value_type);
        try testing.expectEqual(Unique.identity, ident.unique);
        try testing.expect(ident.indexed and ident.inAvet());
        try testing.expectEqual(@as(u64, 1), ident.since);
        try testing.expectEqual(@as(u64, 1), ident.avet_since);
        try testing.expectEqual(@as(u64, boot.idents.len), ident.count);
        const doc = schema.attr(boot.doc).?;
        try testing.expectEqual(ValueType.string, doc.value_type);
        try testing.expect(!doc.inAvet());
        try testing.expectEqual(@as(u64, 0), doc.count);
        const tx = schema.attr(boot.tx_instant).?;
        try testing.expectEqual(ValueType.instant, tx.value_type);
        try testing.expect(tx.indexed);
        try testing.expect(schema.attr(boot.type_long) == null);
        try testing.expect(schema.attrAt(boot.ident, 0) == null);
        try testing.expect(schema.attrAt(boot.ident, 1) != null);
    }
}

test "a cardinality change carries its timeline for every basis" {
    var td = try store_mod.TestDir.init("schema_card");
    defer td.deinit();
    const store = try Store.open(testing.allocator, td.path.ptr, .{});
    defer store.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The first minted attribute: string, card-one at t=2; many at t=3;
    // one again at t=5.
    const a: u32 = boot.next_aid;
    {
        const txn = try store.beginWrite(.none);
        const vt = try key.valBytes(arena, .{ .keyword = boot.type_string });
        const c1 = try key.valBytes(arena, .{ .keyword = boot.card_one });
        const cm = try key.valBytes(arena, .{ .keyword = boot.card_many });
        try store.writeBatch(txn, 2, &.{
            .{ .e = a, .a = boot.value_type, .vbytes = vt, .added = true, .avet = false, .vaet = false },
            .{ .e = a, .a = boot.cardinality, .vbytes = c1, .added = true, .avet = false, .vaet = false },
        }, arena);
        try store.writeBatch(txn, 3, &.{
            .{ .e = a, .a = boot.cardinality, .vbytes = c1, .added = false, .avet = false, .vaet = false },
            .{ .e = a, .a = boot.cardinality, .vbytes = cm, .added = true, .avet = false, .vaet = false },
        }, arena);
        try store.writeBatch(txn, 5, &.{
            .{ .e = a, .a = boot.cardinality, .vbytes = cm, .added = false, .avet = false, .vaet = false },
            .{ .e = a, .a = boot.cardinality, .vbytes = c1, .added = true, .avet = false, .vaet = false },
        }, arena);
        try store.writeT(txn, 5);
        try txn.commit();
    }
    const txn = try store.beginRead();
    defer txn.abort();
    const schema = try Schema.build(testing.allocator, store, txn, 5, 5);
    defer schema.deinit();
    const full = schema.attr(a).?;
    try testing.expectEqual(Cardinality.one, full.cardinality);
    try testing.expectEqual(@as(u64, 5), full.card_t);
    try testing.expectEqual(@as(usize, 3), full.card_changes.len);
    try testing.expectEqual(Cardinality.one, schema.attrAt(a, 2).?.cardinality);
    try testing.expectEqual(Cardinality.many, schema.attrAt(a, 3).?.cardinality);
    try testing.expectEqual(Cardinality.many, schema.attrAt(a, 4).?.cardinality);
    try testing.expectEqual(Cardinality.one, schema.attrAt(a, 5).?.cardinality);
    // A history build at basis 4 stops its timeline there.
    const at4 = try Schema.build(testing.allocator, store, txn, 4, 5);
    defer at4.deinit();
    try testing.expectEqual(Cardinality.many, at4.attr(a).?.cardinality);
    try testing.expectEqual(@as(usize, 2), at4.attr(a).?.card_changes.len);
    // An attribute whose cardinality never changed carries no timeline.
    try testing.expectEqual(@as(usize, 0), schema.attr(boot.ident).?.card_changes.len);
}

test "attrAt masks flags that arrived after the asked basis" {
    var td = try store_mod.TestDir.init("schema_mask");
    defer td.deinit();
    const store = try Store.open(testing.allocator, td.path.ptr, .{});
    defer store.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The first minted attribute: string, card-one at t=2; index added
    // at t=3, fulltext at t=4, unique at t=5. The second: ref, card-one
    // at t=2; component at t=6.
    const a: u32 = boot.next_aid;
    const r: u32 = boot.next_aid + 1;
    {
        const txn = try store.beginWrite(.none);
        const vt = try key.valBytes(arena, .{ .keyword = boot.type_string });
        const rt = try key.valBytes(arena, .{ .keyword = boot.type_ref });
        const c1 = try key.valBytes(arena, .{ .keyword = boot.card_one });
        try store.writeBatch(txn, 2, &.{
            .{ .e = a, .a = boot.value_type, .vbytes = vt, .added = true, .avet = false, .vaet = false },
            .{ .e = a, .a = boot.cardinality, .vbytes = c1, .added = true, .avet = false, .vaet = false },
            .{ .e = r, .a = boot.value_type, .vbytes = rt, .added = true, .avet = false, .vaet = false },
            .{ .e = r, .a = boot.cardinality, .vbytes = c1, .added = true, .avet = false, .vaet = false },
        }, arena);
        const yes = try key.valBytes(arena, .{ .boolean = true });
        try store.writeBatch(txn, 3, &.{
            .{ .e = a, .a = boot.index, .vbytes = yes, .added = true, .avet = false, .vaet = false },
        }, arena);
        try store.writeBatch(txn, 4, &.{
            .{ .e = a, .a = store.fulltext_aid, .vbytes = yes, .added = true, .avet = false, .vaet = false },
        }, arena);
        const identity = try key.valBytes(arena, .{ .keyword = boot.unique_identity });
        try store.writeBatch(txn, 5, &.{
            .{ .e = a, .a = boot.unique, .vbytes = identity, .added = true, .avet = false, .vaet = false },
        }, arena);
        try store.writeBatch(txn, 6, &.{
            .{ .e = r, .a = boot.is_component, .vbytes = yes, .added = true, .avet = false, .vaet = false },
        }, arena);
        try store.writeT(txn, 6);
        try txn.commit();
    }
    const txn = try store.beginRead();
    defer txn.abort();
    const schema = try Schema.build(testing.allocator, store, txn, 6, 6);
    defer schema.deinit();
    const full = schema.attr(a).?;
    try testing.expect(full.indexed);
    try testing.expect(full.fulltext);
    try testing.expectEqual(Unique.identity, full.unique);
    try testing.expectEqual(@as(u64, 2), full.since);
    try testing.expectEqual(@as(u64, 3), full.index_t);
    try testing.expectEqual(@as(u64, 3), full.avet_since);
    try testing.expectEqual(@as(u64, 4), full.fulltext_since);
    try testing.expectEqual(@as(u64, 5), full.unique_t);
    try testing.expect(schema.attr(r).?.component);
    try testing.expectEqual(@as(u64, 6), schema.attr(r).?.component_t);
    // Each flag is masked by its own t: indexed and in AVET from 3,
    // unique only from 5.
    const at4 = schema.attrAt(a, 4).?;
    try testing.expect(at4.indexed and at4.inAvet() and at4.fulltext);
    try testing.expectEqual(Unique.none, at4.unique);
    try testing.expectEqual(@as(u64, 0), at4.unique_t);
    try testing.expectEqual(@as(u64, 3), at4.avet_since);
    try testing.expectEqual(Unique.identity, schema.attrAt(a, 5).?.unique);
    const at3 = schema.attrAt(a, 3).?;
    try testing.expect(at3.indexed);
    try testing.expect(!at3.fulltext);
    try testing.expectEqual(@as(u64, 0), at3.fulltext_since);
    const at2 = schema.attrAt(a, 2).?;
    try testing.expect(!at2.indexed and !at2.inAvet());
    try testing.expectEqual(@as(u64, 0), at2.index_t);
    try testing.expectEqual(@as(u64, 0), at2.avet_since);
    try testing.expectEqual(ValueType.string, at2.value_type);
    try testing.expect(schema.attrAt(a, 1) == null);
    try testing.expect(!schema.attr(boot.ident).?.fulltext);
    try testing.expect(!schema.attrAt(r, 5).?.component);
    try testing.expectEqual(@as(u64, 0), schema.attrAt(r, 5).?.component_t);
    try testing.expect(schema.attrAt(r, 6).?.component);

    // The same shapes fall out of a history build at basis 2.
    const old = try Schema.build(testing.allocator, store, txn, 2, 6);
    defer old.deinit();
    try testing.expect(!old.attr(a).?.indexed);
    try testing.expect(!old.attr(a).?.fulltext);
    try testing.expectEqual(Unique.none, old.attr(a).?.unique);
    try testing.expect(!old.attr(r).?.component);
    try testing.expectEqual(@as(usize, boot.attrs.len + 2), old.count());
    const at4h = try Schema.build(testing.allocator, store, txn, 4, 6);
    defer at4h.deinit();
    try testing.expect(at4h.attr(a).?.indexed);
    try testing.expectEqual(Unique.none, at4h.attr(a).?.unique);
}
