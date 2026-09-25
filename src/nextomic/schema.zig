//! schema.zig — attributes as-of a basis, replayed from the attribute
//! partition's history (NEXTOMIC.md §4 "Schema as-of").
//!
//! Invariants:
//!   - An entity in the attribute partition is an attribute iff it has a
//!     `:db/valueType`; its entity id is its attribute id.
//!   - Every assertion and retraction of `:db/valueType`,
//!     `:db/cardinality`, `:db/unique`, `:db/index`, `:db/isComponent`
//!     or `:db/fulltext` on an attribute is one event of its timeline,
//!     read once from EAVT-h. `attr(a)` is the timeline replayed to the
//!     schema's basis; `attrAt(a, b)` replays it to `b`, so every flag
//!     and the cardinality read as basis `b` saw them.
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

/// One schema datom on an attribute at `t`: `value` is the
/// `ValueType`, `Cardinality` or `Unique` ordinal, or 0 / 1 for a flag.
pub const Event = struct {
    t: u64,
    field: Field,
    value: u8,
    added: bool,

    pub const Field = enum { value_type, cardinality, unique, index, component, fulltext };
};

pub const Attr = struct {
    id: u32,
    value_type: ValueType,
    cardinality: Cardinality = .one,
    unique: Unique = .none,
    indexed: bool = false,
    component: bool = false,
    /// `:db/fulltext true`: the tokens tree carries the attribute's
    /// string values.
    fulltext: bool = false,
    /// `t` of the transaction that asserted `:db/valueType`.
    since: u64 = 0,
    /// The schema events in `t` order, a retraction before the
    /// assertion that replaces it.
    events: []const Event = &.{},
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

    /// The attribute its events make it by basis `at`, or null before
    /// its `:db/valueType`. A retraction clears its value when that
    /// value is the one in force.
    fn replay(id: u32, events: []const Event, at: u64) ?Attr {
        var out: Attr = .{ .id = id, .value_type = undefined, .events = events };
        var typed = false;
        for (events) |ev| {
            if (ev.t > at) break;
            const v = if (ev.added) ev.value else 0;
            switch (ev.field) {
                .value_type => if (ev.added) {
                    out.value_type = @enumFromInt(ev.value);
                    out.since = ev.t;
                    typed = true;
                },
                .cardinality => if (ev.added or @intFromEnum(out.cardinality) == ev.value) {
                    out.cardinality = @enumFromInt(v);
                },
                .unique => if (ev.added or @intFromEnum(out.unique) == ev.value) {
                    out.unique = @enumFromInt(v);
                },
                .index => if (ev.added or @intFromBool(out.indexed) == ev.value) {
                    out.indexed = v == 1;
                },
                .component => if (ev.added or @intFromBool(out.component) == ev.value) {
                    out.component = v == 1;
                },
                .fulltext => if (ev.added or @intFromBool(out.fulltext) == ev.value) {
                    out.fulltext = v == 1;
                },
            }
        }
        return if (typed) out else null;
    }
};

pub const Schema = struct {
    arena: std.heap.ArenaAllocator,
    basis: u64,
    /// The store's schema generation (`sys["sg"]`) the schema was built
    /// under.
    gen: u64 = 0,
    attrs: std.AutoHashMapUnmanaged(u32, Attr) = .empty,

    /// Build the schema at `basis`, the `sys["t"]` of `txn`, from the
    /// history of the attribute partition.
    pub fn build(gpa: Allocator, store: *Store, txn: *Txn, basis: u64) !*Schema {
        const self = try gpa.create(Schema);
        errdefer gpa.destroy(self);
        self.* = .{ .arena = std.heap.ArenaAllocator.init(gpa), .basis = basis, .gen = try store.readSchemaGen(txn) };
        errdefer self.arena.deinit();
        const arena = self.arena.allocator();

        var start: [key.id_len]u8 = undefined;
        var end: [key.id_len]u8 = undefined;
        key.writeId(&start, 1);
        key.writeId(&end, key.attr_partition_end);

        var events: std.ArrayList(Event) = .empty;
        var e: u64 = 0;
        var s = try Store.scanRange(txn, store.trees.hist(.eavt), &start, &end);
        while (s.next()) |kv| {
            const parts = try key.unpackKey(.eavt, true, kv.key);
            if (parts.e != e) {
                try self.add(arena, e, events.items);
                events = .empty;
                e = parts.e;
            }
            const top = parts.top.?;
            if (top.t > basis) continue;
            const ev = (try eventOf(parts.a, parts.v, store.fulltext_aid)) orelse continue;
            try events.append(arena, .{ .t = top.t, .field = ev.field, .value = ev.value, .added = top.added });
        }
        try self.add(arena, e, events.items);

        var it = self.attrs.valueIterator();
        while (it.next()) |a| a.count = try store.attrCount(txn, a.id);
        return self;
    }

    /// The event a history row of `(a v)` is, or null when `a` is not
    /// a schema attribute.
    fn eventOf(a: u32, vbytes: []const u8, fulltext_aid: u32) !?struct { field: Event.Field, value: u8 } {
        const field: Event.Field = if (a == fulltext_aid) .fulltext else switch (a) {
            boot.value_type => .value_type,
            boot.cardinality => .cardinality,
            boot.unique => .unique,
            boot.index => .index,
            boot.is_component => .component,
            else => return null,
        };
        var buf: [16]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const kv = try key.decodeVal(fba.allocator(), vbytes);
        if (kv != .val) return error.Corrupted;
        const v = kv.val;
        const value: u8 = switch (field) {
            .value_type => if (v == .keyword) @intFromEnum(boot.valueTypeOf(v.keyword) orelse return error.Corrupted) else return error.Corrupted,
            .cardinality => if (v == .keyword) switch (v.keyword) {
                boot.card_one => @intFromEnum(Cardinality.one),
                boot.card_many => @intFromEnum(Cardinality.many),
                else => return error.Corrupted,
            } else return error.Corrupted,
            .unique => if (v == .keyword) switch (v.keyword) {
                boot.unique_identity => @intFromEnum(Unique.identity),
                boot.unique_value => @intFromEnum(Unique.value),
                else => return error.Corrupted,
            } else return error.Corrupted,
            .index, .component, .fulltext => if (v == .boolean) @intFromBool(v.boolean) else return error.Corrupted,
        };
        return .{ .field = field, .value = value };
    }

    /// Enter entity `e` as an attribute when its events give it a type.
    fn add(self: *Schema, arena: Allocator, e: u64, events: []Event) !void {
        if (events.len == 0) return;
        // The tree orders an entity's rows by attribute and value before
        // `t`; the timeline is by `t`, a retraction first.
        std.mem.sort(Event, events, {}, struct {
            fn lt(_: void, x: Event, y: Event) bool {
                return x.t < y.t or (x.t == y.t and !x.added and y.added);
            }
        }.lt);
        const a = Attr.replay(@intCast(e), events, std.math.maxInt(u64)) orelse return;
        try self.attrs.put(arena, a.id, a);
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
    /// it did not exist yet, every flag and the cardinality as `at` saw
    /// them.
    pub fn attrAt(self: *const Schema, a: u32, at: u64) ?Attr {
        const p = self.attrs.getPtr(a) orelse return null;
        if (at >= p.events[p.events.len - 1].t) return p.*;
        var out = Attr.replay(a, p.events, at) orelse return null;
        out.count = p.count;
        return out;
    }

    pub fn count(self: *const Schema) usize {
        return self.attrs.count();
    }
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

    const schema = try Schema.build(testing.allocator, store, txn, try store.readT(txn));
    defer schema.deinit();
    try testing.expectEqual(@as(usize, boot.attrs.len), schema.count());
    const ident = schema.attr(boot.ident).?;
    try testing.expectEqual(ValueType.keyword, ident.value_type);
    try testing.expectEqual(Unique.identity, ident.unique);
    try testing.expect(ident.indexed and ident.inAvet());
    try testing.expectEqual(@as(u64, 1), ident.since);
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
    try testing.expect(schema.attrAt(boot.ident, 1).?.unique == .identity);
}

test "a cardinality change reads as each basis saw it" {
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
    const schema = try Schema.build(testing.allocator, store, txn, 5);
    defer schema.deinit();
    try testing.expectEqual(Cardinality.one, schema.attr(a).?.cardinality);
    try testing.expectEqual(Cardinality.one, schema.attrAt(a, 2).?.cardinality);
    try testing.expectEqual(Cardinality.many, schema.attrAt(a, 3).?.cardinality);
    try testing.expectEqual(Cardinality.many, schema.attrAt(a, 4).?.cardinality);
    try testing.expectEqual(Cardinality.one, schema.attrAt(a, 5).?.cardinality);
    // A schema built at basis 4 ends its timeline there.
    const at4 = try Schema.build(testing.allocator, store, txn, 4);
    defer at4.deinit();
    try testing.expectEqual(Cardinality.many, at4.attr(a).?.cardinality);
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
    const schema = try Schema.build(testing.allocator, store, txn, 6);
    defer schema.deinit();
    const full = schema.attr(a).?;
    try testing.expect(full.indexed);
    try testing.expect(full.fulltext);
    try testing.expectEqual(Unique.identity, full.unique);
    try testing.expectEqual(@as(u64, 2), full.since);
    try testing.expect(schema.attr(r).?.component);
    // Each flag reads from its own t: indexed and in AVET from 3,
    // full-text from 4, unique only from 5.
    const at4 = schema.attrAt(a, 4).?;
    try testing.expect(at4.indexed and at4.inAvet() and at4.fulltext);
    try testing.expectEqual(Unique.none, at4.unique);
    try testing.expectEqual(Unique.identity, schema.attrAt(a, 5).?.unique);
    const at3 = schema.attrAt(a, 3).?;
    try testing.expect(at3.indexed);
    try testing.expect(!at3.fulltext);
    const at2 = schema.attrAt(a, 2).?;
    try testing.expect(!at2.indexed and !at2.inAvet());
    try testing.expectEqual(ValueType.string, at2.value_type);
    try testing.expect(schema.attrAt(a, 1) == null);
    try testing.expect(!schema.attr(boot.ident).?.fulltext);
    try testing.expect(!schema.attrAt(r, 5).?.component);
    try testing.expect(schema.attrAt(r, 6).?.component);
    // A schema built at basis 2 knows neither flag yet.
    const old = try Schema.build(testing.allocator, store, txn, 2);
    defer old.deinit();
    try testing.expect(!old.attr(a).?.indexed);
    try testing.expect(!old.attr(r).?.component);
    try testing.expectEqual(@as(usize, boot.attrs.len + 2), old.count());
}

test "a flag set and cleared again reads as each basis saw it" {
    var td = try store_mod.TestDir.init("schema_flag_timeline");
    defer td.deinit();
    const store = try Store.open(testing.allocator, td.path.ptr, .{});
    defer store.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A ref attribute: created at t=2, a component from t=3, not from
    // t=4, a component again from t=6.
    const r: u32 = boot.next_aid;
    {
        const txn = try store.beginWrite(.none);
        const rt = try key.valBytes(arena, .{ .keyword = boot.type_ref });
        const c1 = try key.valBytes(arena, .{ .keyword = boot.card_one });
        const yes = try key.valBytes(arena, .{ .boolean = true });
        const no = try key.valBytes(arena, .{ .boolean = false });
        try store.writeBatch(txn, 2, &.{
            .{ .e = r, .a = boot.value_type, .vbytes = rt, .added = true, .avet = false, .vaet = false },
            .{ .e = r, .a = boot.cardinality, .vbytes = c1, .added = true, .avet = false, .vaet = false },
        }, arena);
        try store.writeBatch(txn, 3, &.{
            .{ .e = r, .a = boot.is_component, .vbytes = yes, .added = true, .avet = false, .vaet = false },
        }, arena);
        try store.writeBatch(txn, 4, &.{
            .{ .e = r, .a = boot.is_component, .vbytes = yes, .added = false, .avet = false, .vaet = false },
            .{ .e = r, .a = boot.is_component, .vbytes = no, .added = true, .avet = false, .vaet = false },
        }, arena);
        try store.writeBatch(txn, 6, &.{
            .{ .e = r, .a = boot.is_component, .vbytes = no, .added = false, .avet = false, .vaet = false },
            .{ .e = r, .a = boot.is_component, .vbytes = yes, .added = true, .avet = false, .vaet = false },
        }, arena);
        try store.writeT(txn, 6);
        try txn.commit();
    }
    const txn = try store.beginRead();
    defer txn.abort();
    const schema = try Schema.build(testing.allocator, store, txn, 6);
    defer schema.deinit();
    try testing.expect(schema.attr(r).?.component);
    try testing.expect(!schema.attrAt(r, 2).?.component);
    try testing.expect(schema.attrAt(r, 3).?.component);
    try testing.expect(!schema.attrAt(r, 4).?.component);
    try testing.expect(!schema.attrAt(r, 5).?.component);
    try testing.expect(schema.attrAt(r, 6).?.component);
}
