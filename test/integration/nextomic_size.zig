//! test/integration/nextomic_size.zig — what a store of a fixed history
//! takes, tree by tree (NEXTOMIC.md §2, docs/PERF.md §3.11).
//!
//! One deterministic fixture: 2,000 people of five attributes in
//! transactions of 1,000, 200 one-entity transactions, 200 card-one
//! changes, and a few long strings asserted, replaced and retracted.
//! Every instant after the bootstrap's is fixed, and the bootstrap's
//! takes as many bytes in any year before 2039, so every byte the trees
//! hold is a function of the format. Two tiers:
//!
//!   1. The entries and the key and value bytes of every index tree,
//!      the txlog and the tokens tree, from a walk, are pinned exactly:
//!      they depend on Nextomic's layout alone, so a change to any of
//!      them is a format change, made on purpose.
//!   2. Leaf and overflow pages per tree stay under a ceiling 15% above
//!      what the tree measured when it was pinned, a check of fill in
//!      emdb and in Nextomic's write order alike.
//!
//! A mismatch prints the whole measured table in the shape of `pinned`
//! below, ready to compare and, for a deliberate change, to paste.

const std = @import("std");
const nx = @import("nexis");
const nextomic = nx.nextomic;

const testing = std.testing;
const Allocator = std.mem.Allocator;
const Op = nextomic.Op;
const Val = nextomic.Val;
const Entity = nextomic.transact.Entity;
const Store = nextomic.Store;
const tree_names = nextomic.store.tree_names;

/// The bytes every index tree, the txlog and the tokens tree hold at
/// the end of the fixture, and the leaf and overflow pages they took
/// when pinned. `idents` and `sys` hold names and counters, not
/// datoms, and `sys` a random store id: they are left out.
const Pin = struct { tree: []const u8, entries: u64, key: u64, value: u64, pages: u64 };

const pinned = [_]Pin{
    .{ .tree = "nx/eavt", .entries = 11489, .key = 224829, .value = 68934, .pages = 29 },
    .{ .tree = "nx/aevt", .entries = 11489, .key = 224829, .value = 68934, .pages = 33 },
    .{ .tree = "nx/avet", .entries = 4846, .key = 99598, .value = 29076, .pages = 17 },
    .{ .tree = "nx/vaet", .entries = 2200, .key = 35200, .value = 13200, .pages = 6 },
    .{ .tree = "nx/eavt-h", .entries = 11895, .key = 304357, .value = 2100, .pages = 30 },
    .{ .tree = "nx/aevt-h", .entries = 11895, .key = 304357, .value = 0, .pages = 37 },
    .{ .tree = "nx/avet-h", .entries = 5246, .key = 138674, .value = 0, .pages = 20 },
    .{ .tree = "nx/vaet-h", .entries = 2200, .key = 48400, .value = 0, .pages = 6 },
    .{ .tree = "nx/txlog", .entries = 407, .key = 2442, .value = 221180, .pages = 15 },
    .{ .tree = "nx/fulltext", .entries = 11, .key = 490, .value = 0, .pages = 1 },
};

/// Every transaction's instant: fixed, so the txlog's bytes are too.
const instant: i64 = 2_000_000_000_000;

const Fixture = struct {
    tc: *nextomic.db.TestConn,
    arena_state: std.heap.ArenaAllocator,
    email: u32 = 0,
    name: u32 = 0,
    age: u32 = 0,
    team: u32 = 0,
    score: u32 = 0,
    bio: u32 = 0,
    team_name: u32 = 0,

    fn arena(self: *Fixture) Allocator {
        return self.arena_state.allocator();
    }

    fn kw(self: *Fixture, name: []const u8) !u32 {
        return self.tc.interner.internKeyword(name);
    }

    fn commit(self: *Fixture, ops: []const Op) !nextomic.Report {
        return nextomic.transact.transactOps(self.tc.conn, self.arena(), ops, .{ .now_ms = instant });
    }

    fn attrOps(self: *Fixture, ops: *std.ArrayList(Op), tmp: []const u8, ident: []const u8, vt: u32, extra: ?struct { a: u32, v: Val }) !void {
        const boot = nextomic.boot;
        const e: Entity = .{ .tempid = .{ .string = tmp } };
        try ops.append(self.arena(), .{ .add = .{ .e = e, .a = .{ .id = boot.ident }, .v = .{ .keyword = try self.kw(ident) } } });
        try ops.append(self.arena(), .{ .add = .{ .e = e, .a = .{ .id = boot.value_type }, .v = .{ .val = .{ .keyword = vt } } } });
        try ops.append(self.arena(), .{ .add = .{ .e = e, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_one } } } });
        if (extra) |x| try ops.append(self.arena(), .{ .add = .{ .e = e, .a = .{ .id = x.a }, .v = .{ .val = x.v } } });
    }

    fn schema(self: *Fixture) !void {
        const boot = nextomic.boot;
        var ops: std.ArrayList(Op) = .empty;
        const identity: Val = .{ .keyword = boot.unique_identity };
        try self.attrOps(&ops, "email", "person/email", boot.type_string, .{ .a = boot.unique, .v = identity });
        try self.attrOps(&ops, "name", "person/name", boot.type_string, null);
        try self.attrOps(&ops, "age", "person/age", boot.type_long, .{ .a = boot.index, .v = .{ .boolean = true } });
        try self.attrOps(&ops, "team", "person/team", boot.type_ref, null);
        try self.attrOps(&ops, "score", "person/score", boot.type_long, null);
        try self.attrOps(&ops, "bio", "person/bio", boot.type_string, .{ .a = self.tc.conn.store.fulltext_aid, .v = .{ .boolean = true } });
        try self.attrOps(&ops, "team-name", "team/name", boot.type_string, .{ .a = boot.unique, .v = identity });
        const r = try self.commit(ops.items);
        const ids = [_]*u32{ &self.email, &self.name, &self.age, &self.team, &self.score, &self.bio, &self.team_name };
        for (r.tempids, ids) |b, id| id.* = @intCast(b.eid);
    }

    fn add(self: *Fixture, ops: *std.ArrayList(Op), e: Entity, a: u32, v: Val) !void {
        try ops.append(self.arena(), .{ .add = .{ .e = e, .a = .{ .id = a }, .v = .{ .val = v } } });
    }

    fn person(self: *Fixture, ops: *std.ArrayList(Op), e: Entity, i: usize, teams: []const u64) !void {
        try self.add(ops, e, self.email, .{ .string = try self.arena().print("p{d}@x.org", .{i}) });
        try self.add(ops, e, self.name, .{ .string = try self.arena().print("name-{d}", .{i}) });
        try self.add(ops, e, self.age, .{ .long = @intCast(18 + (i * 7) % 60) });
        try self.add(ops, e, self.team, .{ .ref = teams[i % teams.len] });
        try self.add(ops, e, self.score, .{ .long = @intCast((i * 7919) % 90_001) });
    }
};

fn tempid(i: usize) Entity {
    return .{ .tempid = .{ .fixnum = -@as(i64, @intCast(i + 1)) } };
}

/// A string past the inline limit, different for each `i`.
fn longText(arena: Allocator, i: usize) ![]const u8 {
    const s = try arena.alloc(u8, 300);
    for (s, 0..) |*c, k| c.* = "abcdefghij klmnopqrstuvwxyz"[(k * 5 + i) % 27];
    return s;
}

const Measured = struct { entries: u64, key: u64, value: u64, pages: u64 };

fn measure(store: *Store, arena: Allocator) ![tree_names.len]Measured {
    const txn = try store.beginRead();
    defer txn.abort();
    var out: [tree_names.len]Measured = undefined;
    for (tree_names, 0..) |name, i| {
        const id = try txn.openTree(name, false);
        const s = try Store.treeSize(txn, id, arena);
        out[i] = .{ .entries = s.entries, .key = s.key_bytes, .value = s.value_bytes, .pages = s.leaf_pages + s.overflow_pages };
    }
    return out;
}

fn index(name: []const u8) usize {
    for (tree_names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return i;
    unreachable;
}

test "a store of a fixed history holds the pinned bytes in every tree, in few pages" {
    var fx: Fixture = .{ .tc = try nextomic.db.TestConn.init("size"), .arena_state = .init(testing.allocator) };
    defer fx.tc.deinit();
    defer fx.arena_state.deinit();
    try fx.schema();

    var ops: std.ArrayList(Op) = .empty;
    for (0..10) |i| try fx.add(&ops, tempid(i), fx.team_name, .{ .string = try fx.arena().print("t{d}", .{i}) });
    const teams = try fx.arena().alloc(u64, 10);
    for ((try fx.commit(ops.items)).tempids, teams) |b, *t| t.* = b.eid;

    // The bulk part: 2,000 people in two transactions.
    var people: std.ArrayList(u64) = .empty;
    for (0..2) |b| {
        ops = .empty;
        for (0..1000) |i| try fx.person(&ops, tempid(i), b * 1000 + i, teams);
        for ((try fx.commit(ops.items)).tempids) |t| try people.append(fx.arena(), t.eid);
    }
    const bulk = try measure(fx.tc.conn.store, fx.arena());

    // 200 one-entity transactions, then 200 card-one changes of one
    // datom each.
    for (0..200) |i| {
        ops = .empty;
        try fx.person(&ops, tempid(0), 2000 + i, teams);
        try people.append(fx.arena(), (try fx.commit(ops.items)).tempids[0].eid);
    }
    for (0..200) |i| {
        ops = .empty;
        try fx.add(&ops, .{ .eid = people.items[i * 11] }, fx.age, .{ .long = @intCast(100 + i) });
        _ = try fx.commit(ops.items);
    }
    // Long strings: five asserted, two replaced, one retracted.
    ops = .empty;
    for (0..5) |i| try fx.add(&ops, .{ .eid = people.items[i] }, fx.bio, .{ .string = try longText(fx.arena(), i) });
    _ = try fx.commit(ops.items);
    ops = .empty;
    for (0..2) |i| try fx.add(&ops, .{ .eid = people.items[i] }, fx.bio, .{ .string = try longText(fx.arena(), 10 + i) });
    try ops.append(fx.arena(), .{ .retract_attr = .{ .e = .{ .eid = people.items[4] }, .a = .{ .id = fx.bio } } });
    _ = try fx.commit(ops.items);

    const end = try measure(fx.tc.conn.store, fx.arena());
    // A load of new entities writes each datom once to every index it
    // belongs to and once more to its history twin.
    for (0..4) |i| try testing.expectEqual(bulk[i].entries, bulk[4 + i].entries);

    var ok = true;
    for (pinned) |p| {
        const m = end[index(p.tree)];
        if (m.entries != p.entries or m.key != p.key or m.value != p.value) ok = false;
        // The ceiling: 15% above the pages pinned.
        if (m.pages * 100 > p.pages * 115) ok = false;
    }
    if (!ok) {
        std.debug.print("\nmeasured:\n", .{});
        for (pinned) |p| {
            const m = end[index(p.tree)];
            std.debug.print("    .{{ .tree = \"{s}\", .entries = {d}, .key = {d}, .value = {d}, .pages = {d} }},\n", .{ p.tree, m.entries, m.key, m.value, m.pages });
        }
    }
    try testing.expect(ok);
}
