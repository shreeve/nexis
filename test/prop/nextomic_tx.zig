//! test/prop/nextomic_tx.zig — random transaction sequences against an
//! in-memory reference model (NEXTOMIC.md §3, §4).
//!
//! The model expands every transaction's ops by the §3 rules on its own
//! (card-one implicit retract, no-op re-assertion, unique-identity
//! upsert, retract-attribute, retract-entity with VAET cleanup and
//! component cascade) and keeps its own log. After each commit the
//! report's datoms must equal the model's expansion; after the run,
//! for every basis `t` the store's as-of view through every index must
//! equal the model's replay, `since` windows and `history` must match,
//! long strings must round-trip through the payload, an aborted
//! transaction must leave every tree's entry count and `t` unchanged,
//! and a reopened store must continue from the same `t`.

const std = @import("std");
const nx = @import("nexis");
const nextomic = nx.nextomic;

const key = nextomic.key;
const boot = nextomic.boot;
const transact = nextomic.transact;
const db_mod = nextomic.db;
const Op = transact.Op;
const Val = key.Val;
const Datom = nextomic.Datom;
const testing = std.testing;
const Allocator = std.mem.Allocator;

const prng_seed: u64 = 0x6e78_7478_5f70_0000; // "nxtx_p\0\0"
const transactions: usize = 60;
const reopen_at: usize = 31;

// =============================================================================
// Attributes under test
// =============================================================================

const Attrs = struct {
    email: u32, // string, unique identity
    name: u32, // string
    age: u32, // long
    tags: u32, // keyword, many
    friend: u32, // ref, many
    home: u32, // ref, component
    city: u32, // string
    bio: u32, // string, often long
};

fn kw(tc: *db_mod.TestConn, name: []const u8) !u32 {
    return tc.interner.internKeyword(name);
}

fn attrOps(arena: Allocator, tc: *db_mod.TestConn, tmp: []const u8, ident: []const u8, vt: u32, many: bool, unique: bool, component: bool) ![]Op {
    var out: std.ArrayList(Op) = .empty;
    const e: transact.Entity = .{ .tempid = .{ .string = tmp } };
    try out.append(arena, .{ .add = .{ .e = e, .a = .{ .id = boot.ident }, .v = .{ .keyword = try kw(tc, ident) } } });
    try out.append(arena, .{ .add = .{ .e = e, .a = .{ .id = boot.value_type }, .v = .{ .val = .{ .keyword = vt } } } });
    try out.append(arena, .{ .add = .{ .e = e, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = if (many) boot.card_many else boot.card_one } } } });
    if (unique) try out.append(arena, .{ .add = .{ .e = e, .a = .{ .id = boot.unique }, .v = .{ .val = .{ .keyword = boot.unique_identity } } } });
    if (component) try out.append(arena, .{ .add = .{ .e = e, .a = .{ .id = boot.is_component }, .v = .{ .val = .{ .boolean = true } } } });
    return out.toOwnedSlice(arena);
}

fn installSchema(arena: Allocator, tc: *db_mod.TestConn) !Attrs {
    var ops: std.ArrayList(Op) = .empty;
    try ops.appendSlice(arena, try attrOps(arena, tc, "email", "user/email", boot.type_string, false, true, false));
    try ops.appendSlice(arena, try attrOps(arena, tc, "name", "user/name", boot.type_string, false, false, false));
    try ops.appendSlice(arena, try attrOps(arena, tc, "age", "user/age", boot.type_long, false, false, false));
    try ops.appendSlice(arena, try attrOps(arena, tc, "tags", "user/tags", boot.type_keyword, true, false, false));
    try ops.appendSlice(arena, try attrOps(arena, tc, "friend", "user/friend", boot.type_ref, true, false, false));
    try ops.appendSlice(arena, try attrOps(arena, tc, "home", "user/home", boot.type_ref, false, false, true));
    try ops.appendSlice(arena, try attrOps(arena, tc, "city", "addr/city", boot.type_string, false, false, false));
    try ops.appendSlice(arena, try attrOps(arena, tc, "bio", "user/bio", boot.type_string, false, false, false));
    _ = try transact.transactOps(tc.conn, arena, ops.items, .{});
    const txn = try tc.conn.store.beginRead();
    defer txn.abort();
    return .{
        .email = (try tc.conn.idents.idOfName(txn, "user/email")).?,
        .name = (try tc.conn.idents.idOfName(txn, "user/name")).?,
        .age = (try tc.conn.idents.idOfName(txn, "user/age")).?,
        .tags = (try tc.conn.idents.idOfName(txn, "user/tags")).?,
        .friend = (try tc.conn.idents.idOfName(txn, "user/friend")).?,
        .home = (try tc.conn.idents.idOfName(txn, "user/home")).?,
        .city = (try tc.conn.idents.idOfName(txn, "addr/city")).?,
        .bio = (try tc.conn.idents.idOfName(txn, "user/bio")).?,
    };
}

// =============================================================================
// Reference model
// =============================================================================

const Row = struct { e: u64, a: u32, vb: []const u8, v: Val, t: u64, added: bool };

const Model = struct {
    arena: Allocator,
    attrs: Attrs,
    tag_ids: [4]u32,
    log: std.ArrayList(Row) = .empty,
    /// `e|a|vb` -> row index of the current assertion.
    current: std.StringHashMapUnmanaged(usize) = .empty,
    emails: std.StringHashMapUnmanaged(u64) = .empty,
    alive: std.ArrayList(u64) = .empty,

    fn factKey(self: *Model, e: u64, a: u32, vb: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.arena, "{d}|{d}|{x}", .{ e, a, vb });
    }

    fn many(self: *Model, a: u32) bool {
        return a == self.attrs.tags or a == self.attrs.friend;
    }

    fn isRef(self: *Model, a: u32) bool {
        return a == self.attrs.friend or a == self.attrs.home;
    }

    /// One transaction's expansion. Pending rows carry `t`.
    const Pending = struct {
        model: *Model,
        rows: std.ArrayList(Row) = .empty,
        keys: std.StringHashMapUnmanaged(usize) = .empty,
        t: u64,

        fn pendingOf(self: *Pending, k: []const u8) ?*Row {
            const i = self.keys.get(k) orelse return null;
            return &self.rows.items[i];
        }

        fn push(self: *Pending, e: u64, a: u32, v: Val, added: bool) !void {
            const vb = try key.valBytes(self.model.arena, v);
            const k = try self.model.factKey(e, a, vb);
            try self.keys.put(self.model.arena, k, self.rows.items.len);
            try self.rows.append(self.model.arena, .{ .e = e, .a = a, .vb = vb, .v = v, .t = self.t, .added = added });
        }

        /// The committed value of a card-one `(e a)` unless pending-retracted.
        fn currentOne(self: *Pending, e: u64, a: u32) !?Row {
            for (self.model.log.items) |r| {
                if (r.e != e or r.a != a) continue;
                const k = try self.model.factKey(e, a, r.vb);
                if (self.model.current.get(k)) |i| {
                    if (self.pendingOf(k)) |p| if (!p.added) continue;
                    return self.model.log.items[i];
                }
            }
            return null;
        }

        fn has(self: *Pending, e: u64, a: u32, vb: []const u8) !bool {
            const k = try self.model.factKey(e, a, vb);
            return self.model.current.contains(k);
        }

        fn add(self: *Pending, e: u64, a: u32, v: Val) !void {
            const vb = try key.valBytes(self.model.arena, v);
            const k = try self.model.factKey(e, a, vb);
            if (self.pendingOf(k)) |_| return;
            if (try self.has(e, a, vb)) return;
            if (!self.model.many(a)) {
                if (try self.currentOne(e, a)) |old| try self.push(e, a, old.v, false);
            }
            try self.push(e, a, v, true);
        }

        fn retract(self: *Pending, e: u64, a: u32, v: Val) !void {
            const vb = try key.valBytes(self.model.arena, v);
            const k = try self.model.factKey(e, a, vb);
            if (self.pendingOf(k)) |_| return;
            if (!try self.has(e, a, vb)) return;
            try self.push(e, a, v, false);
        }

        fn retractAttr(self: *Pending, e: u64, a: u32) !void {
            var it = self.model.current.valueIterator();
            while (it.next()) |i| {
                const r = self.model.log.items[i.*];
                if (r.e != e or r.a != a) continue;
                try self.retract(e, a, r.v);
            }
        }

        fn retractEntity(self: *Pending, e: u64) !void {
            var comps: std.ArrayList(u64) = .empty;
            var it = self.model.current.valueIterator();
            while (it.next()) |i| {
                const r = self.model.log.items[i.*];
                if (r.e == e) {
                    if (r.a == self.model.attrs.home) try comps.append(self.model.arena, r.v.ref);
                    try self.retract(e, r.a, r.v);
                } else if (self.model.isRef(r.a) and r.v.ref == e) {
                    try self.retract(r.e, r.a, r.v);
                }
            }
            for (comps.items) |c| try self.retractEntity(c);
        }

        fn commit(self: *Pending) !void {
            const m = self.model;
            for (self.rows.items) |r| {
                const k = try m.factKey(r.e, r.a, r.vb);
                if (r.added) {
                    try m.current.put(m.arena, k, m.log.items.len);
                    if (r.a == m.attrs.email) try m.emails.put(m.arena, r.v.string, r.e);
                } else {
                    _ = m.current.remove(k);
                    if (r.a == m.attrs.email) _ = m.emails.remove(r.v.string);
                }
                try m.log.append(m.arena, r);
            }
        }
    };

    /// Replay: facts current as of `upto`, from an empty state when
    /// `after` is given (since), keyed `e|a|vb|t`.
    fn replay(self: *Model, arena: Allocator, after: ?u64, upto: u64) !std.StringHashMapUnmanaged(void) {
        var cur: std.StringHashMapUnmanaged(u64) = .empty;
        for (self.log.items) |r| {
            if (r.t > upto) continue;
            if (after) |a| if (r.t <= a) continue;
            const k = try self.factKey(r.e, r.a, r.vb);
            if (r.added) try cur.put(arena, k, r.t) else _ = cur.remove(k);
        }
        var out: std.StringHashMapUnmanaged(void) = .empty;
        var it = cur.iterator();
        while (it.next()) |e| try out.put(arena, try std.fmt.allocPrint(arena, "{s}|{d}", .{ e.key_ptr.*, e.value_ptr.* }), {});
        return out;
    }

    fn historyRows(self: *Model, arena: Allocator, upto: u64) !std.StringHashMapUnmanaged(u32) {
        var out: std.StringHashMapUnmanaged(u32) = .empty;
        for (self.log.items) |r| {
            if (r.t > upto) continue;
            const k = try std.fmt.allocPrint(arena, "{d}|{d}|{x}|{d}|{}", .{ r.e, r.a, r.vb, r.t, r.added });
            const g = try out.getOrPut(arena, k);
            if (!g.found_existing) g.value_ptr.* = 0;
            g.value_ptr.* += 1;
        }
        return out;
    }
};

// =============================================================================
// Generator
// =============================================================================

const Gen = struct {
    rand: std.Random,
    arena: Allocator,
    model: *Model,
    tc: *db_mod.TestConn,
    next_email: u32 = 0,
    long_bios: usize = 0,

    /// A small age that collides often, or one at an edge of the long
    /// range (NEXTOMIC.md §2.2), past the fixnum range included.
    fn age(self: *Gen) i64 {
        const edges = [_]i64{ std.math.minInt(i64), -(1 << 47) - 1, 1 << 47, 1 << 53, std.math.maxInt(i64) };
        const i = self.rand.uintLessThan(usize, 5 + edges.len);
        return if (i < 5) @intCast(i + 1) else edges[i - 5];
    }

    /// One transaction: ops, the entities it touches (no conflicts), and
    /// the tempid names for new entities.
    const Tx = struct {
        ops: std.ArrayList(Op) = .empty,
        touched: std.AutoHashMapUnmanaged(u64, void) = .empty,
        removed: std.AutoHashMapUnmanaged(u64, void) = .empty,
        new_count: u32 = 0,
    };

    fn pickAlive(self: *Gen, tx: *Tx) ?u64 {
        const alive = self.model.alive.items;
        if (alive.len == 0) return null;
        var tries: usize = 0;
        while (tries < 8) : (tries += 1) {
            const e = alive[self.rand.uintLessThan(usize, alive.len)];
            if (!tx.removed.contains(e)) return e;
        }
        return null;
    }

    fn entityRef(self: *Gen, e: u64) transact.Entity {
        // Sometimes reach the entity through its email lookup ref.
        if (self.rand.uintLessThan(u8, 4) == 0) {
            var it = self.model.emails.iterator();
            while (it.next()) |x| {
                if (x.value_ptr.* == e) return .{ .lookup = .{ .a = .{ .id = self.model.attrs.email }, .v = .{ .string = x.key_ptr.* } } };
            }
        }
        return .{ .eid = e };
    }

    fn freshEmail(self: *Gen) ![]const u8 {
        self.next_email += 1;
        return std.fmt.allocPrint(self.arena, "u{d}@x", .{self.next_email});
    }

    fn bio(self: *Gen) ![]const u8 {
        const n: usize = switch (self.rand.uintLessThan(u8, 6)) {
            0 => 0,
            1, 2 => self.rand.uintAtMost(usize, key.inline_max),
            3, 4 => key.inline_max + 1 + self.rand.uintAtMost(usize, 300),
            else => blk: {
                self.long_bios += 1;
                break :blk 20_000 + self.rand.uintAtMost(usize, 30_000);
            },
        };
        const s = try self.arena.alloc(u8, n);
        for (s, 0..) |*c, i| c.* = if (self.rand.uintLessThan(u8, 16) == 0) 0 else @intCast('a' + (i % 26));
        return s;
    }

    fn tagVal(self: *Gen) Val {
        return .{ .keyword = self.model.tag_ids[self.rand.uintLessThan(usize, 4)] };
    }

    fn genTx(self: *Gen) !Tx {
        var tx: Tx = .{};
        const m = self.model;
        const a = m.attrs;
        const n = 1 + self.rand.uintLessThan(usize, 7);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            switch (self.rand.uintLessThan(u8, 12)) {
                0, 1 => {
                    // New entity by tempid.
                    tx.new_count += 1;
                    const tmp = try std.fmt.allocPrint(self.arena, "n{d}", .{tx.new_count});
                    const e: transact.Entity = .{ .tempid = .{ .string = tmp } };
                    try tx.ops.append(self.arena, .{ .add = .{ .e = e, .a = .{ .id = a.email }, .v = .{ .val = .{ .string = try self.freshEmail() } } } });
                    try tx.ops.append(self.arena, .{ .add = .{ .e = e, .a = .{ .id = a.age }, .v = .{ .val = .{ .long = self.age() } } } });
                    if (self.rand.boolean()) try tx.ops.append(self.arena, .{ .add = .{ .e = e, .a = .{ .id = a.tags }, .v = .{ .val = self.tagVal() } } });
                },
                2 => {
                    // Upsert through an existing email.
                    const e = self.pickAlive(&tx) orelse continue;
                    if (tx.touched.contains(e)) continue;
                    var email: ?[]const u8 = null;
                    var it = m.emails.iterator();
                    while (it.next()) |x| if (x.value_ptr.* == e) {
                        email = x.key_ptr.*;
                    };
                    const em = email orelse continue;
                    try tx.touched.put(self.arena, e, {});
                    tx.new_count += 1;
                    const tmp = try std.fmt.allocPrint(self.arena, "u{d}", .{tx.new_count});
                    const t: transact.Entity = .{ .tempid = .{ .string = tmp } };
                    try tx.ops.append(self.arena, .{ .add = .{ .e = t, .a = .{ .id = a.email }, .v = .{ .val = .{ .string = em } } } });
                    try tx.ops.append(self.arena, .{ .add = .{ .e = t, .a = .{ .id = a.name }, .v = .{ .val = .{ .string = try std.fmt.allocPrint(self.arena, "name{d}", .{self.rand.uintLessThan(u8, 3)}) } } } });
                },
                3, 4 => {
                    // Card-one overwrite (or no-op).
                    const e = self.pickAlive(&tx) orelse continue;
                    if (tx.touched.contains(e)) continue;
                    try tx.touched.put(self.arena, e, {});
                    const which = self.rand.uintLessThan(u8, 3);
                    if (which == 0) {
                        try tx.ops.append(self.arena, .{ .add = .{ .e = self.entityRef(e), .a = .{ .id = a.age }, .v = .{ .val = .{ .long = self.age() } } } });
                    } else if (which == 1) {
                        try tx.ops.append(self.arena, .{ .add = .{ .e = self.entityRef(e), .a = .{ .id = a.bio }, .v = .{ .val = .{ .string = try self.bio() } } } });
                    } else {
                        try tx.ops.append(self.arena, .{ .add = .{ .e = .{ .eid = e }, .a = .{ .id = a.name }, .v = .{ .val = .{ .string = try std.fmt.allocPrint(self.arena, "name{d}", .{self.rand.uintLessThan(u8, 3)}) } } } });
                    }
                },
                5 => {
                    // Card-many add or retract.
                    const e = self.pickAlive(&tx) orelse continue;
                    if (tx.touched.contains(e)) continue;
                    try tx.touched.put(self.arena, e, {});
                    if (self.rand.boolean()) {
                        try tx.ops.append(self.arena, .{ .add = .{ .e = .{ .eid = e }, .a = .{ .id = a.tags }, .v = .{ .val = self.tagVal() } } });
                    } else {
                        try tx.ops.append(self.arena, .{ .retract = .{ .e = .{ .eid = e }, .a = .{ .id = a.tags }, .v = .{ .val = self.tagVal() } } });
                    }
                },
                6 => {
                    // Retract-attribute.
                    const e = self.pickAlive(&tx) orelse continue;
                    if (tx.touched.contains(e)) continue;
                    try tx.touched.put(self.arena, e, {});
                    const attr = if (self.rand.boolean()) a.age else a.tags;
                    try tx.ops.append(self.arena, .{ .retract_attr = .{ .e = .{ .eid = e }, .a = .{ .id = attr } } });
                },
                7 => {
                    // Friend ref between two alive entities.
                    const e = self.pickAlive(&tx) orelse continue;
                    const f = self.pickAlive(&tx) orelse continue;
                    if (tx.touched.contains(e) or tx.touched.contains(f)) continue;
                    try tx.touched.put(self.arena, e, {});
                    try tx.touched.put(self.arena, f, {});
                    try tx.ops.append(self.arena, .{ .add = .{ .e = .{ .eid = e }, .a = .{ .id = a.friend }, .v = .{ .entity = self.entityRef(f) } } });
                },
                8 => {
                    // Component home: a new address entity.
                    const e = self.pickAlive(&tx) orelse continue;
                    if (tx.touched.contains(e)) continue;
                    try tx.touched.put(self.arena, e, {});
                    tx.new_count += 1;
                    const tmp = try std.fmt.allocPrint(self.arena, "h{d}", .{tx.new_count});
                    try tx.ops.append(self.arena, .{ .add = .{ .e = .{ .eid = e }, .a = .{ .id = a.home }, .v = .{ .entity = .{ .tempid = .{ .string = tmp } } } } });
                    try tx.ops.append(self.arena, .{ .add = .{ .e = .{ .tempid = .{ .string = tmp } }, .a = .{ .id = a.city }, .v = .{ .val = .{ .string = if (self.rand.boolean()) "Oslo" else "Rome" } } } });
                },
                9 => {
                    // Retract the whole entity: cascades to its home and
                    // clears refs to it, so nothing else in this
                    // transaction may touch it or its home.
                    if (tx.ops.items.len != 0) continue;
                    const e = self.pickAlive(&tx) orelse continue;
                    try tx.touched.put(self.arena, e, {});
                    try tx.removed.put(self.arena, e, {});
                    try tx.ops.append(self.arena, .{ .retract_entity = self.entityRef(e) });
                    break;
                },
                else => {
                    // Retract a specific card-one value (present or not).
                    const e = self.pickAlive(&tx) orelse continue;
                    if (tx.touched.contains(e)) continue;
                    try tx.touched.put(self.arena, e, {});
                    try tx.ops.append(self.arena, .{ .retract = .{ .e = .{ .eid = e }, .a = .{ .id = a.age }, .v = .{ .val = .{ .long = self.age() } } } });
                },
            }
        }
        return tx;
    }

    /// Apply the transaction to the model with the eids the store chose.
    fn expect(self: *Gen, tx: *const Tx, report: transact.Report) !void {
        const m = self.model;
        var p: Model.Pending = .{ .model = m, .t = report.t };
        for (tx.ops.items) |op| {
            switch (op) {
                .add => |o| try p.add(try self.resolve(o.e, report), o.a.id, try self.resolveVal(o.v, report)),
                .retract => |o| try p.retract(try self.resolve(o.e, report), o.a.id, try self.resolveVal(o.v, report)),
                .retract_attr => |o| try p.retractAttr(try self.resolve(o.e, report), o.a.id),
                .retract_entity => |e| try p.retractEntity(try self.resolve(e, report)),
            }
        }
        // Compare with the report as sets of e|a|vb|added.
        var want: std.StringHashMapUnmanaged(void) = .empty;
        for (p.rows.items) |r| try want.put(self.arena, try std.fmt.allocPrint(self.arena, "{d}|{d}|{x}|{}", .{ r.e, r.a, r.vb, r.added }), {});
        var got: std.StringHashMapUnmanaged(void) = .empty;
        for (report.tx_data) |d| {
            if (d.a == boot.tx_instant) continue;
            try testing.expectEqual(report.t, d.t);
            const vb = try key.valBytes(self.arena, d.v);
            try got.put(self.arena, try std.fmt.allocPrint(self.arena, "{d}|{d}|{x}|{}", .{ d.e, d.a, vb, d.added }), {});
        }
        try expectSameKeys(void, "the replayed model", &want, &got);
        try p.commit();
        // Alive set: entities with any current fact.
        m.alive.clearRetainingCapacity();
        var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
        var it = m.current.valueIterator();
        while (it.next()) |i| {
            const r = m.log.items[i.*];
            if (r.a == m.attrs.city) continue;
            if (!(try seen.getOrPut(self.arena, r.e)).found_existing) try m.alive.append(m.arena, r.e);
        }
    }

    fn resolve(self: *Gen, e: transact.Entity, report: transact.Report) !u64 {
        return switch (e) {
            .eid => |id| id,
            .tempid => |k| blk: {
                for (report.tempids) |b| {
                    if (b.key == .string and std.mem.eql(u8, b.key.string, k.string)) break :blk b.eid;
                }
                return error.TempidMissing;
            },
            .lookup => |l| self.model.emails.get(l.v.string) orelse error.LookupMissing,
            else => error.Unsupported,
        };
    }

    fn resolveVal(self: *Gen, v: transact.ValRef, report: transact.Report) !Val {
        return switch (v) {
            .val => |x| x,
            .entity => |e| .{ .ref = try self.resolve(e, report) },
            else => error.Unsupported,
        };
    }
};

/// `got` holds exactly `want`; a difference is printed under `where`.
fn expectSameKeys(comptime V: type, where: []const u8, want: *std.StringHashMapUnmanaged(V), got: *std.StringHashMapUnmanaged(V)) !void {
    var ok = want.count() == got.count();
    errdefer std.debug.print("key sets differ at {s} (seed 0x{x})\n", .{ where, prng_seed });
    var it = want.iterator();
    while (it.next()) |e| {
        const g = got.get(e.key_ptr.*);
        if (g == null or (V != void and g.? != e.value_ptr.*)) {
            std.debug.print("missing in store: {s}\n", .{e.key_ptr.*});
            ok = false;
        }
    }
    var it2 = got.iterator();
    while (it2.next()) |e| {
        if (!want.contains(e.key_ptr.*)) {
            std.debug.print("unexpected in store: {s}\n", .{e.key_ptr.*});
            ok = false;
        }
    }
    try testing.expect(ok);
}

// =============================================================================
// Store views as key sets
// =============================================================================

fn isUser(e: u64) bool {
    return e >= key.user_partition_start and e < key.user_partition_end;
}

fn viewSet(arena: Allocator, db: db_mod.DbValue, index: key.Index, comps: key.Components, with_added: bool) !std.StringHashMapUnmanaged(u32) {
    var out: std.StringHashMapUnmanaged(u32) = .empty;
    const ds = try db.datoms(arena, index, comps);
    for (ds) |d| {
        if (!isUser(d.e)) continue;
        const vb = try key.valBytes(arena, d.v);
        const k = if (with_added)
            try std.fmt.allocPrint(arena, "{d}|{d}|{x}|{d}|{}", .{ d.e, d.a, vb, d.t, d.added })
        else
            try std.fmt.allocPrint(arena, "{d}|{d}|{x}|{d}", .{ d.e, d.a, vb, d.t });
        const g = try out.getOrPut(arena, k);
        if (!g.found_existing) g.value_ptr.* = 0;
        g.value_ptr.* += 1;
    }
    return out;
}

fn toCounted(arena: Allocator, s: *std.StringHashMapUnmanaged(void)) !std.StringHashMapUnmanaged(u32) {
    var out: std.StringHashMapUnmanaged(u32) = .empty;
    var it = s.keyIterator();
    while (it.next()) |k| try out.put(arena, k.*, 1);
    return out;
}

/// Every basis: as-of through every index, a since window, history.
fn verifyAllBases(arena_parent: Allocator, model: *Model, tc: *db_mod.TestConn, rand: std.Random) !void {
    const db = try tc.conn.db();
    var t: u64 = 1;
    while (t <= db.basis) : (t += 1) {
        var arena_state = std.heap.ArenaAllocator.init(arena_parent);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const view = db.asOf(t);

        var want_set = try model.replay(arena, null, t);
        var want = try toCounted(arena, &want_set);
        var got = try viewSet(arena, view, .eavt, .{}, false);
        const where = try std.fmt.allocPrint(arena, "as-of {d}", .{t});
        try expectSameKeys(u32, where, &want, &got);
        var got_aevt = try viewSet(arena, view, .aevt, .{}, false);
        try expectSameKeys(u32, where, &want, &got_aevt);

        // AVET holds exactly the unique attribute's facts; VAET the refs.
        var want_avet: std.StringHashMapUnmanaged(u32) = .empty;
        var want_vaet: std.StringHashMapUnmanaged(u32) = .empty;
        var it = want.keyIterator();
        while (it.next()) |k| {
            var parts = std.mem.splitScalar(u8, k.*, '|');
            _ = parts.next();
            const a = try std.fmt.parseInt(u32, parts.next().?, 10);
            if (a == model.attrs.email) try want_avet.put(arena, k.*, 1);
            if (a == model.attrs.friend or a == model.attrs.home) try want_vaet.put(arena, k.*, 1);
        }
        var got_avet = try viewSet(arena, view, .avet, .{ .a = model.attrs.email }, false);
        try expectSameKeys(u32, where, &want_avet, &got_avet);
        var got_vaet = try viewSet(arena, view, .vaet, .{}, false);
        try expectSameKeys(u32, where, &want_vaet, &got_vaet);

        // since: a random earlier point, from an empty state.
        const after = rand.uintLessThan(u64, t);
        var want_since_set = try model.replay(arena, after, t);
        var want_since = try toCounted(arena, &want_since_set);
        var got_since = try viewSet(arena, view.sinceT(after), .eavt, .{}, false);
        try expectSameKeys(u32, try std.fmt.allocPrint(arena, "since {d} as-of {d}", .{ after, t }), &want_since, &got_since);

        // history: every row up to t, with its flag.
        var want_hist = try model.historyRows(arena, t);
        var got_hist = try viewSet(arena, view.withHistory(), .eavt, .{}, true);
        try expectSameKeys(u32, try std.fmt.allocPrint(arena, "history as-of {d}", .{t}), &want_hist, &got_hist);
    }
    // The plain db equals as-of its basis; the current-tree fast path
    // and the fold agree.
    var arena_state = std.heap.ArenaAllocator.init(arena_parent);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fast = try viewSet(arena, db, .eavt, .{}, false);
    var folded = try viewSet(arena, db.asOf(db.basis), .eavt, .{}, false);
    try expectSameKeys(u32, "the current trees against the fold", &fast, &folded);
}

// =============================================================================
// The run
// =============================================================================

test "T1 random transactions vs the model at every basis, reopen, abort" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prng = std.Random.DefaultPrng.init(prng_seed);
    const rand = prng.random();

    const tc = try db_mod.TestConn.init("prop_tx");
    defer tc.deinit();
    const attrs = try installSchema(arena, tc);
    var tag_ids: [4]u32 = undefined;
    {
        // Mint the tag keywords once so the model knows their ids. They
        // hang off an attribute entity, outside the user partition the
        // model tracks.
        const names = [_][]const u8{ "tag/a", "tag/b", "tag/c", "tag/d" };
        var ops: [4]Op = undefined;
        for (names, 0..) |n, i| ops[i] = .{ .add = .{ .e = .{ .eid = attrs.tags }, .a = .{ .id = attrs.tags }, .v = .{ .keyword = try kw(tc, n) } } };
        const r = try transact.transactOps(tc.conn, arena, &ops, .{});
        for (r.tx_data, 0..) |d, i| {
            if (i < 4) tag_ids[i] = d.v.keyword;
        }
    }

    var model = Model{ .arena = arena, .attrs = attrs, .tag_ids = tag_ids };
    var gen = Gen{ .rand = rand, .arena = arena, .model = &model, .tc = tc };

    var last_t: u64 = (try tc.conn.db()).basis;
    var i: usize = 0;
    while (i < transactions) : (i += 1) {
        errdefer std.debug.print("failed at transaction {d} of seed 0x{x}\n", .{ i, prng_seed });
        if (i == reopen_at) {
            try tc.reopen();
            try testing.expectEqual(last_t, (try tc.conn.db()).basis);
            try verifyAllBases(testing.allocator, &model, tc, rand);
        }
        var tx = try gen.genTx();
        if (tx.ops.items.len == 0) continue;
        const report = try transact.transactOps(tc.conn, arena, tx.ops.items, .{});
        try testing.expectEqual(last_t + 1, report.t);
        try testing.expectEqual(last_t, report.db_before.basis);
        try testing.expectEqual(report.t, report.db_after.basis);
        last_t = report.t;
        try gen.expect(&tx, report);
    }
    try testing.expect(gen.long_bios > 0);
    try testing.expect(model.log.items.len > 100);
    try verifyAllBases(testing.allocator, &model, tc, rand);

    // Abort: a conflicting transaction leaves every tree and t untouched.
    const e = model.alive.items[0];
    var before: [nextomic.store.tree_names.len]u64 = undefined;
    {
        const txn = try tc.conn.store.beginRead();
        defer txn.abort();
        for (0..4) |k| before[k] = try nextomic.Store.treeEntries(txn, tc.conn.store.trees.current[k]);
        for (0..4) |k| before[4 + k] = try nextomic.Store.treeEntries(txn, tc.conn.store.trees.history[k]);
        before[8] = try nextomic.Store.treeEntries(txn, tc.conn.store.trees.txlog);
        before[9] = try nextomic.Store.treeEntries(txn, tc.conn.store.trees.idents);
        before[10] = try nextomic.Store.treeEntries(txn, tc.conn.store.trees.sys);
    }
    try testing.expectError(error.Conflict, transact.transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = e }, .a = .{ .id = attrs.tags }, .v = .{ .keyword = try kw(tc, "tag/aborted") } } },
        .{ .add = .{ .e = .{ .eid = e }, .a = .{ .id = attrs.age }, .v = .{ .val = .{ .long = 100 } } } },
        .{ .add = .{ .e = .{ .eid = e }, .a = .{ .id = attrs.age }, .v = .{ .val = .{ .long = 101 } } } },
    }, .{}));
    {
        const txn = try tc.conn.store.beginRead();
        defer txn.abort();
        try testing.expectEqual(last_t, try tc.conn.store.readT(txn));
        try testing.expectEqual(before[0], try nextomic.Store.treeEntries(txn, tc.conn.store.trees.current[0]));
        for (0..4) |k| try testing.expectEqual(before[k], try nextomic.Store.treeEntries(txn, tc.conn.store.trees.current[k]));
        for (0..4) |k| try testing.expectEqual(before[4 + k], try nextomic.Store.treeEntries(txn, tc.conn.store.trees.history[k]));
        try testing.expectEqual(before[8], try nextomic.Store.treeEntries(txn, tc.conn.store.trees.txlog));
        try testing.expectEqual(before[9], try nextomic.Store.treeEntries(txn, tc.conn.store.trees.idents));
        try testing.expectEqual(before[10], try nextomic.Store.treeEntries(txn, tc.conn.store.trees.sys));
        try testing.expect((try tc.conn.idents.idOfName(txn, "tag/aborted")) == null);
    }
    // And the store still transacts afterwards.
    const r = try transact.transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = e }, .a = .{ .id = attrs.age }, .v = .{ .val = .{ .long = 100 } } } },
    }, .{});
    try testing.expectEqual(last_t + 1, r.t);

    // The txlog replays the same rows the model holds, in order.
    const entries = try db_mod.txRange(tc.conn, arena, 1, null);
    try testing.expectEqual(r.t, entries[entries.len - 1].t);
    var logged: usize = 0;
    for (entries) |en| {
        for (en.datoms) |d| {
            if (isUser(d.e)) logged += 1;
        }
    }
    try testing.expectEqual(model.log.items.len + 1, logged);
}

// =============================================================================
// Cache coherence: after any transaction, committed or failed, the
// connection that ran it agrees with a fresh one on every ident and
// every attribute.
// =============================================================================

const ident_pool = [_][]const u8{ "p/a", "p/b", "p/c", "p/d", "p/e", "p/f", "p/g", "p/h" };

/// `conn` and a connection opened fresh on the same file resolve every
/// pool name, name every ident id, and describe every attribute alike.
fn expectAgreesWithFresh(arena: Allocator, tc: *db_mod.TestConn, where: usize) !void {
    errdefer std.debug.print("caches disagree after transaction {d} (seed 0x{x})\n", .{ where, prng_seed });
    const fresh = try db_mod.Conn.open(testing.allocator, &tc.interner, tc.td.path.ptr, .{ .sync = .none });
    defer fresh.destroy();
    const old_db = try tc.conn.db();
    const new_db = try fresh.db();
    try testing.expectEqual(new_db.basis, old_db.basis);
    for (ident_pool) |name| {
        const k = try kw(tc, name);
        try testing.expectEqual(try new_db.entid(arena, .{ .ident = k }), try old_db.entid(arena, .{ .ident = k }));
    }
    const next_aid = blk: {
        const txn = try fresh.store.beginRead();
        defer txn.abort();
        break :blk try fresh.store.readNextAid(txn);
    };
    var id: u32 = 1;
    while (id < next_aid) : (id += 1) {
        try testing.expectEqual(try new_db.ident(arena, id), try old_db.ident(arena, id));
        const want = try new_db.attr(id);
        const got = try old_db.attr(id);
        try testing.expectEqual(want == null, got == null);
        if (want) |w| {
            const g = got.?;
            try testing.expectEqual(w.value_type, g.value_type);
            try testing.expectEqual(w.cardinality, g.cardinality);
            try testing.expectEqual(w.unique, g.unique);
            try testing.expectEqual(w.indexed, g.indexed);
            try testing.expectEqual(w.component, g.component);
            try testing.expectEqual(w.fulltext, g.fulltext);
        }
    }
}

test "T2 a failed transaction leaves the ident and schema caches as a fresh connection sees them" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prng = std.Random.DefaultPrng.init(prng_seed ^ 0x1de);
    const rand = prng.random();

    const tc = try db_mod.TestConn.init("prop_tx_idents");
    defer tc.deinit();
    // Attribute ids the store holds: renamed, given keyword values, and
    // named by the pool.
    var attrs: std.ArrayList(u32) = .empty;
    const seed_ops = try attrOps(arena, tc, "k", "p/a", boot.type_keyword, false, false, false);
    const r0 = try transact.transactOps(tc.conn, arena, seed_ops, .{});
    try attrs.append(arena, @intCast(r0.tempids[0].eid));

    var committed: usize = 0;
    var failed: usize = 0;
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        var ops: std.ArrayList(Op) = .empty;
        const n = 1 + rand.uintLessThan(usize, 4);
        for (0..n) |_| {
            const name = try kw(tc, ident_pool[rand.uintLessThan(usize, ident_pool.len)]);
            const a = attrs.items[rand.uintLessThan(usize, attrs.items.len)];
            switch (rand.uintLessThan(u8, 5)) {
                // Rename an attribute: the name may be taken or retired,
                // and a second rename in the same transaction may name it too.
                0, 1 => try ops.append(arena, .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = boot.ident }, .v = .{ .keyword = name } } }),
                // A new attribute under a pool name.
                2 => try ops.appendSlice(arena, try attrOps(arena, tc, try std.fmt.allocPrint(arena, "t{d}", .{i}), ident_pool[rand.uintLessThan(usize, ident_pool.len)], if (rand.boolean()) boot.type_keyword else boot.type_long, false, false, false)),
                // Name an attribute by a pool keyword, as an entity and
                // as an attribute, with a keyword value from the pool.
                3 => try ops.append(arena, .{ .add = .{ .e = .{ .ident = name }, .a = .{ .id = boot.doc }, .v = .{ .val = .{ .string = "d" } } } }),
                else => try ops.append(arena, .{ .add = .{ .e = .{ .tempid = .{ .string = "v" } }, .a = .{ .ident = name }, .v = .{ .keyword = try kw(tc, ident_pool[rand.uintLessThan(usize, ident_pool.len)]) } } }),
            }
        }
        // Half the transactions end in a conflict of their own.
        if (rand.boolean()) {
            try ops.append(arena, .{ .add = .{ .e = .{ .eid = boot.ident }, .a = .{ .id = boot.doc }, .v = .{ .val = .{ .string = "x" } } } });
            try ops.append(arena, .{ .add = .{ .e = .{ .eid = boot.ident }, .a = .{ .id = boot.doc }, .v = .{ .val = .{ .string = "y" } } } });
        }
        var fault: db_mod.Fault = .{};
        const speculative = rand.uintLessThan(u8, 4) == 0;
        if (speculative) {
            if (transact.withOps(tc.conn, arena, ops.items, .{ .fault = &fault })) |w| w.destroy() else |_| {}
        } else if (transact.transactOps(tc.conn, arena, ops.items, .{ .fault = &fault })) |r| {
            committed += 1;
            for (r.tempids) |b| {
                if (b.key != .string or b.key.string[0] != 't') continue;
                if (key.isAttrPartition(b.eid)) try attrs.append(arena, @intCast(b.eid));
            }
        } else |_| failed += 1;
        try expectAgreesWithFresh(arena, tc, i);
    }
    try testing.expect(committed > 10);
    try testing.expect(failed > 10);
}

// =============================================================================
// tx-data is a set: any order of the same forms gives the same outcome.
// =============================================================================

/// The outcome of one speculative run: the error, or the datoms as
/// `e|a|v|added` with every tempid's eid spelled by its name, since
/// tempids take eids in first-seen order.
fn outcome(arena: Allocator, tc: *db_mod.TestConn, ops: []const Op) ![]const u8 {
    const w = transact.withOps(tc.conn, arena, ops, .{ .now_ms = 1 }) catch |err| return @errorName(err);
    defer w.destroy();
    const r = w.report;
    var rows: std.ArrayList([]const u8) = .empty;
    for (r.tx_data) |d| {
        if (d.a == boot.tx_instant) continue;
        const e = try spell(arena, r, d.e);
        const v = if (d.v == .ref) try spell(arena, r, d.v.ref) else try std.fmt.allocPrint(arena, "{x}", .{try key.valBytes(arena, d.v)});
        try rows.append(arena, try std.fmt.allocPrint(arena, "{s}|{d}|{s}|{}", .{ e, d.a, v, d.added }));
    }
    std.mem.sort([]const u8, rows.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return std.mem.join(arena, "\n", rows.items);
}

fn spell(arena: Allocator, r: transact.Report, e: u64) ![]const u8 {
    for (r.tempids) |b| if (b.eid == e) return std.fmt.allocPrint(arena, "tmp:{s}", .{b.key.string});
    return std.fmt.allocPrint(arena, "{d}", .{e});
}

test "T3 a permutation of tx-data gives the same report or fails alike" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prng = std.Random.DefaultPrng.init(prng_seed ^ 0x5e7);
    const rand = prng.random();

    const tc = try db_mod.TestConn.init("prop_tx_perm");
    defer tc.deinit();
    var schema_ops: std.ArrayList(Op) = .empty;
    try schema_ops.appendSlice(arena, try attrOps(arena, tc, "k", "u/k", boot.type_string, false, true, false));
    try schema_ops.appendSlice(arena, try attrOps(arena, tc, "v", "u/v", boot.type_string, false, false, false));
    try schema_ops.appendSlice(arena, try attrOps(arena, tc, "n", "u/n", boot.type_long, false, false, false));
    // `:u/v` is unique by value.
    try schema_ops.append(arena, .{ .add = .{ .e = .{ .tempid = .{ .string = "v" } }, .a = .{ .id = boot.unique }, .v = .{ .val = .{ .keyword = boot.unique_value } } } });
    const rs = try transact.transactOps(tc.conn, arena, schema_ops.items, .{});
    var ids: [3]u32 = undefined;
    for (rs.tempids, 0..) |b, i| ids[i] = @intCast(b.eid);
    const k_attr, const v_attr, const n_attr = ids;

    const pool = [_][]const u8{ "p", "q", "r", "s" };
    var ents: [3]u64 = undefined;
    {
        var ops: std.ArrayList(Op) = .empty;
        for (0..3) |i| {
            const t: transact.Entity = .{ .tempid = .{ .string = pool[i] } };
            try ops.append(arena, .{ .add = .{ .e = t, .a = .{ .id = k_attr }, .v = .{ .val = .{ .string = pool[i] } } } });
            try ops.append(arena, .{ .add = .{ .e = t, .a = .{ .id = v_attr }, .v = .{ .val = .{ .string = pool[i] } } } });
        }
        const r = try transact.transactOps(tc.conn, arena, ops.items, .{});
        for (r.tempids, 0..) |b, i| ents[i] = b.eid;
    }

    var succeeded: usize = 0;
    var failed: usize = 0;
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        var ops: std.ArrayList(Op) = .empty;
        const n = 2 + rand.uintLessThan(usize, 4);
        for (0..n) |_| {
            const val: Val = .{ .string = pool[rand.uintLessThan(usize, pool.len)] };
            const e: transact.Entity = switch (rand.uintLessThan(u8, 6)) {
                0, 1, 2 => .{ .eid = ents[rand.uintLessThan(usize, 3)] },
                3, 4 => .{ .lookup = .{ .a = .{ .id = k_attr }, .v = .{ .string = pool[rand.uintLessThan(usize, pool.len)] } } },
                else => .{ .tempid = .{ .string = if (rand.boolean()) "t1" else "t2" } },
            };
            const a = if (rand.boolean()) k_attr else v_attr;
            switch (rand.uintLessThan(u8, 6)) {
                0, 1 => try ops.append(arena, .{ .add = .{ .e = e, .a = .{ .id = a }, .v = .{ .val = val } } }),
                2 => if (e != .tempid) try ops.append(arena, .{ .retract = .{ .e = e, .a = .{ .id = a }, .v = .{ .val = val } } }),
                3 => if (e != .tempid) try ops.append(arena, .{ .retract_attr = .{ .e = e, .a = .{ .id = a } } }),
                else => try ops.append(arena, .{ .add = .{ .e = e, .a = .{ .id = n_attr }, .v = .{ .val = .{ .long = rand.intRangeAtMost(i64, 1, 3) } } } }),
            }
        }
        if (ops.items.len < 2) continue;
        const want = try outcome(arena, tc, ops.items);
        for (0..3) |_| {
            const shuffled = try arena.dupe(Op, ops.items);
            rand.shuffle(Op, shuffled);
            const got = try outcome(arena, tc, shuffled);
            const failure = std.mem.indexOfScalar(u8, want, '|') == null and want.len > 0 and std.ascii.isUpper(want[0]);
            const got_failure = std.mem.indexOfScalar(u8, got, '|') == null and got.len > 0 and std.ascii.isUpper(got[0]);
            // Two independent faults may surface in either order; the
            // outcome is still a failure both ways.
            if (failure and got_failure) continue;
            if (!std.mem.eql(u8, want, got)) {
                std.debug.print("transaction {d} (seed 0x{x}): in order\n{s}\nshuffled\n{s}\n", .{ i, prng_seed, want, got });
                return error.TestUnexpectedResult;
            }
        }
        if (transact.transactOps(tc.conn, arena, ops.items, .{})) |_| succeeded += 1 else |_| failed += 1;
    }
    try testing.expect(succeeded > 30);
    try testing.expect(failed > 30);
}

// =============================================================================
// A late index: the attribute's AVET history, current and history trees,
// is its whole history, values retracted before the indexing included.
// =============================================================================

/// The datoms of attribute `a` in `index` for `view`, as
/// `e|v|t|added` counts; `eavt` walks every datom and keeps `a`'s.
fn attrSet(arena: Allocator, view: db_mod.DbValue, index: key.Index, a: u32) !std.StringHashMapUnmanaged(u32) {
    var out: std.StringHashMapUnmanaged(u32) = .empty;
    const comps: key.Components = if (index == .eavt) .{} else .{ .a = a };
    for (try view.datoms(arena, index, comps)) |d| {
        if (d.a != a) continue;
        const k = try std.fmt.allocPrint(arena, "{d}|{x}|{d}|{}", .{ d.e, try key.valBytes(arena, d.v), d.t, d.added });
        const g = try out.getOrPut(arena, k);
        if (!g.found_existing) g.value_ptr.* = 0;
        g.value_ptr.* += 1;
    }
    return out;
}

test "T4 an attribute indexed late holds its whole history in AVET" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prng = std.Random.DefaultPrng.init(prng_seed ^ 0xa7e7);
    const rand = prng.random();

    const tc = try db_mod.TestConn.init("prop_tx_late_index");
    defer tc.deinit();
    const attrs = try installSchema(arena, tc);
    const long_text = "a value past the inline limit, so its AVET rows carry a hash and its EAVT rows the payload: " ++ "x" ** 40;
    var es: [6]u64 = undefined;
    for (&es, 0..) |*e, i| {
        const r = try transact.transactOps(tc.conn, arena, &.{
            .{ .add = .{ .e = .{ .tempid = .{ .fixnum = -1 } }, .a = .{ .id = attrs.age }, .v = .{ .val = .{ .long = @intCast(i) } } } },
        }, .{});
        e.* = r.tempids[0].eid;
    }
    var retracted: usize = 0;
    var indexed_at: u64 = 0;
    for (0..80) |i| {
        var ops: std.ArrayList(Op) = .empty;
        var used: std.AutoHashMapUnmanaged(u64, void) = .empty;
        for (0..1 + rand.uintLessThan(usize, 3)) |_| {
            const e = es[rand.uintLessThan(usize, es.len)];
            if ((try used.getOrPut(arena, e)).found_existing) continue;
            const ent: transact.Entity = .{ .eid = e };
            switch (rand.uintLessThan(u8, 4)) {
                // A card-one overwrite retracts the value it replaces.
                0, 1 => try ops.append(arena, .{ .add = .{ .e = ent, .a = .{ .id = attrs.age }, .v = .{ .val = .{ .long = rand.uintLessThan(u8, 8) } } } }),
                2 => try ops.append(arena, .{ .retract_attr = .{ .e = ent, .a = .{ .id = attrs.age } } }),
                else => try ops.append(arena, .{ .add = .{ .e = ent, .a = .{ .id = attrs.bio }, .v = .{ .val = .{ .string = if (rand.boolean()) long_text else "short" } } } }),
            }
        }
        // Midway both attributes become indexed, beside data of their own.
        if (i == 40) {
            for ([_]u32{ attrs.age, attrs.bio }) |a| try ops.append(arena, .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = boot.index }, .v = .{ .val = .{ .boolean = true } } } });
        }
        const r = try transact.transactOps(tc.conn, arena, ops.items, .{});
        if (i == 40) indexed_at = r.t;
        if (i < 40) for (r.tx_data) |d| {
            if (!d.added and (d.a == attrs.age or d.a == attrs.bio)) retracted += 1;
        };
    }
    try testing.expect(retracted > 10);
    const db = try tc.conn.db();
    for ([_]u32{ attrs.age, attrs.bio }) |a| {
        errdefer std.debug.print("attribute {d} (seed 0x{x})\n", .{ a, prng_seed ^ 0xa7e7 });
        var want = try attrSet(arena, db.withHistory(), .eavt, a);
        var got = try attrSet(arena, db.withHistory(), .avet, a);
        try expectSameKeys(u32, "history AVET against EAVT", &want, &got);
        var t: u64 = indexed_at;
        while (t <= db.basis) : (t += 1) {
            const view = db.asOf(t);
            var want_t = try attrSet(arena, view, .aevt, a);
            var got_t = try attrSet(arena, view, .avet, a);
            try expectSameKeys(u32, try std.fmt.allocPrint(arena, "AVET as-of {d}", .{t}), &want_t, &got_t);
        }
    }
}
