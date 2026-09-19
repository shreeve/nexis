//! schema.zig — attributes as-of a basis, built from the attribute
//! partition's datoms (NEXTOMIC.md §4 "Schema as-of").
//!
//! Invariants:
//!   - An entity in the attribute partition is an attribute iff it has a
//!     `:db/valueType`; its entity id is its attribute id.
//!   - Schema is additive: value type and cardinality never change once
//!     written; `:db/index` and `:db/unique` can only be added. So a
//!     Schema built at basis B is a superset of every earlier basis, and
//!     `attrAt(a, b)` for `b < B` masks the AVET flags that arrived after
//!     `b` and hides attributes created after `b`.
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

pub const Attr = struct {
    id: u32,
    value_type: ValueType,
    cardinality: Cardinality = .one,
    unique: Unique = .none,
    indexed: bool = false,
    component: bool = false,
    /// `t` of the transaction that asserted `:db/valueType`.
    since: u64,
    /// `t` from which AVET carries the attribute (the first assertion of
    /// `:db/index true` or `:db/unique`); 0 when it never did.
    avet_since: u64 = 0,
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

        var acc = Accumulator{};
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
        while (it.next()) |a| a.count = try store.attrCount(txn, a.id);
        return self;
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
    /// it did not exist yet, with AVET flags cleared when they arrived
    /// after `at`.
    pub fn attrAt(self: *const Schema, a: u32, at: u64) ?Attr {
        const p = self.attrs.getPtr(a) orelse return null;
        if (p.since > at) return null;
        var copy = p.*;
        if (copy.avet_since > at) {
            copy.indexed = false;
            copy.unique = .none;
            copy.avet_since = 0;
        }
        return copy;
    }

    pub fn count(self: *const Schema) usize {
        return self.attrs.count();
    }

    /// Accumulates one attribute entity's rows; rows arrive in `(e a)`
    /// order so an entity is complete when `e` changes.
    const Accumulator = struct {
        e: u64 = 0,
        value_type: ?ValueType = null,
        type_t: u64 = 0,
        cardinality: Cardinality = .one,
        unique: Unique = .none,
        unique_t: u64 = 0,
        indexed: bool = false,
        index_t: u64 = 0,
        component: bool = false,

        fn row(self: *Accumulator, schema: *Schema, arena: Allocator, fact: []const u8, t: u64) !void {
            const parts = try key.unpackKey(.eavt, false, fact);
            if (parts.e != self.e) {
                try self.flush(schema, arena);
                self.* = .{ .e = parts.e };
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
                .avet_since = avet_since,
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

test "attrAt masks flags that arrived after the asked basis" {
    var td = try store_mod.TestDir.init("schema_mask");
    defer td.deinit();
    const store = try Store.open(testing.allocator, td.path.ptr, .{});
    defer store.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Attribute 22: string, card-one at t=2; index added at t=3.
    const a: u32 = 22;
    {
        const txn = try store.beginWrite(.none);
        const vt = try key.valBytes(arena, .{ .keyword = boot.type_string });
        const c1 = try key.valBytes(arena, .{ .keyword = boot.card_one });
        try store.writeBatch(txn, 2, &.{
            .{ .e = a, .a = boot.value_type, .vbytes = vt, .added = true, .avet = false, .vaet = false },
            .{ .e = a, .a = boot.cardinality, .vbytes = c1, .added = true, .avet = false, .vaet = false },
        }, arena);
        const yes = try key.valBytes(arena, .{ .boolean = true });
        try store.writeBatch(txn, 3, &.{
            .{ .e = a, .a = boot.index, .vbytes = yes, .added = true, .avet = false, .vaet = false },
        }, arena);
        try store.writeT(txn, 3);
        try txn.commit();
    }
    const txn = try store.beginRead();
    defer txn.abort();
    const schema = try Schema.build(testing.allocator, store, txn, 3, 3);
    defer schema.deinit();
    const full = schema.attr(a).?;
    try testing.expect(full.indexed);
    try testing.expectEqual(@as(u64, 2), full.since);
    try testing.expectEqual(@as(u64, 3), full.avet_since);
    const at2 = schema.attrAt(a, 2).?;
    try testing.expect(!at2.indexed);
    try testing.expectEqual(ValueType.string, at2.value_type);
    try testing.expect(schema.attrAt(a, 1) == null);

    // The same shapes fall out of a history build at basis 2.
    const old = try Schema.build(testing.allocator, store, txn, 2, 3);
    defer old.deinit();
    try testing.expect(!old.attr(a).?.indexed);
    try testing.expectEqual(@as(usize, boot.attrs.len + 1), old.count());
}
