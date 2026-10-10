//! test/integration/nextomic_store.zig — Nextomic against store files
//! (NEXTOMIC.md §2-§4): the store's trees, bootstrap, batches, the merged
//! and folded scans and the format check; db-values over every view;
//! and the transaction protocol: schema installs, card-one overwrites,
//! tempids, upserts and lookup refs, retractions, the unique and schema
//! rules, speculative `with`, excision, durability, the caches, and a
//! transaction's arena and failure behaviour.

const std = @import("std");
const nx = @import("nexis");
const nextomic = nx.nextomic;
const value = nx.value;
const string_mod = nx.string;
const list_mod = nx.list;
const vector_mod = nx.vector;
const champ = nx.champ;
const sorted = nx.sorted;
const stack = nx.stack;
const emdb = nx.emdb;
const key = nextomic.key;
const datom_mod = nextomic.datom;
const store_mod = nextomic.store;
const idents_mod = nextomic.idents;
const schema_mod = nextomic.schema;
const db_mod = nextomic.db;
const transact_mod = nextomic.transact;

const Allocator = std.mem.Allocator;
const Value = value.Value;
const Txn = emdb.Txn;
const Store = store_mod.Store;
const Schema = schema_mod.Schema;
const Attr = schema_mod.Attr;
const Conn = db_mod.Conn;
const DbValue = db_mod.DbValue;
const Fault = db_mod.Fault;
const Val = key.Val;
const Datom = datom_mod.Datom;
const boot = store_mod.boot;
const transact = transact_mod.transact;
const transactOps = transact_mod.transactOps;
const with = transact_mod.with;
const withOps = transact_mod.withOps;
const excise = transact_mod.excise;
const max_call_depth = transact_mod.max_call_depth;
const CallHook = transact_mod.CallHook;
const TempidKey = transact_mod.TempidKey;
const Report = transact_mod.Report;
const With = transact_mod.With;
const Op = transact_mod.Op;
const Entity = transact_mod.Entity;
const Error = transact_mod.Error;
const Index = key.Index;
const SyncMode = store_mod.SyncMode;
const Heap = nx.heap.Heap;
const Interner = nx.intern.Interner;
const db_layer = store_mod.db_layer;
const TestDir = store_mod.TestDir;
const TestConn = db_mod.TestConn;
const txRange = db_mod.txRange;
const format_version = store_mod.format_version;
const repeat = string_mod.repeat;

const testing = std.testing;

fn kw(tc: *TestConn, name: []const u8) !u32 {
    return tc.interner.internKeyword(name);
}

/// Install `:user/email` (string, unique identity), `:user/name`
/// (string), `:user/age` (long), `:user/tags` (keyword, many),
/// `:user/friend` (ref, many), `:user/home` (ref, component),
/// `:addr/city` (string), `:user/bio` (string).
fn installSchema(tc: *TestConn, arena: Allocator) !void {
    const ops = [_]Op{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "email" } }, .a = .{ .id = boot.ident }, .v = .{ .keyword = try kw(tc, "user/email") } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "email" } }, .a = .{ .id = boot.value_type }, .v = .{ .val = .{ .keyword = boot.type_string } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "email" } }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_one } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "email" } }, .a = .{ .id = boot.unique }, .v = .{ .val = .{ .keyword = boot.unique_identity } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "name" } }, .a = .{ .id = boot.ident }, .v = .{ .keyword = try kw(tc, "user/name") } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "name" } }, .a = .{ .id = boot.value_type }, .v = .{ .val = .{ .keyword = boot.type_string } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "name" } }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_one } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "age" } }, .a = .{ .id = boot.ident }, .v = .{ .keyword = try kw(tc, "user/age") } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "age" } }, .a = .{ .id = boot.value_type }, .v = .{ .val = .{ .keyword = boot.type_long } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "age" } }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_one } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "tags" } }, .a = .{ .id = boot.ident }, .v = .{ .keyword = try kw(tc, "user/tags") } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "tags" } }, .a = .{ .id = boot.value_type }, .v = .{ .val = .{ .keyword = boot.type_keyword } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "tags" } }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_many } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "friend" } }, .a = .{ .id = boot.ident }, .v = .{ .keyword = try kw(tc, "user/friend") } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "friend" } }, .a = .{ .id = boot.value_type }, .v = .{ .val = .{ .keyword = boot.type_ref } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "friend" } }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_many } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "home" } }, .a = .{ .id = boot.ident }, .v = .{ .keyword = try kw(tc, "user/home") } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "home" } }, .a = .{ .id = boot.value_type }, .v = .{ .val = .{ .keyword = boot.type_ref } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "home" } }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_one } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "home" } }, .a = .{ .id = boot.is_component }, .v = .{ .val = .{ .boolean = true } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "city" } }, .a = .{ .id = boot.ident }, .v = .{ .keyword = try kw(tc, "addr/city") } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "city" } }, .a = .{ .id = boot.value_type }, .v = .{ .val = .{ .keyword = boot.type_string } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "city" } }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_one } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "bio" } }, .a = .{ .id = boot.ident }, .v = .{ .keyword = try kw(tc, "user/bio") } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "bio" } }, .a = .{ .id = boot.value_type }, .v = .{ .val = .{ .keyword = boot.type_string } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "bio" } }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_one } } } },
    };
    const r = try transactOps(tc.conn, arena, &ops, .{});
    try testing.expectEqual(@as(u64, 2), r.t);
    try testing.expectEqual(@as(usize, 8), r.tempids.len);
}

fn attrId(tc: *TestConn, name: []const u8) !u32 {
    const txn = try tc.conn.store.beginRead();
    defer txn.abort();
    return (try tc.conn.idents.idOfName(txn, name)).?;
}

test "schema install then asserts, card-one overwrite, no-op, retract" {
    const tc = try TestConn.init("tx_basic");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);

    const email = try attrId(tc, "user/email");
    const name = try attrId(tc, "user/name");
    const age = try attrId(tc, "user/age");
    try testing.expectEqual(boot.next_aid, email);

    const r1 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "a@x" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Ann" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .fixnum = -1 } }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 30 } } } },
    }, .{});
    try testing.expectEqual(@as(u64, 3), r1.t);
    try testing.expectEqual(@as(usize, 2), r1.tempids.len);
    const a = r1.tempids[0].eid;
    try testing.expectEqual(key.user_partition_start, a);
    try testing.expectEqual(@as(usize, 4), r1.tx_data.len);
    try testing.expectEqual(boot.tx_instant, r1.tx_data[3].a);
    try testing.expectEqual(@as(u64, 2), r1.db_before.basis);
    try testing.expectEqual(@as(u64, 3), r1.db_after.basis);

    // Overwrite card-one: one retract, one add. Re-assert: nothing.
    const r2 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Anne" } } } },
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "a@x" } } } },
    }, .{});
    try testing.expectEqual(@as(usize, 3), r2.tx_data.len);
    try testing.expect(!r2.tx_data[0].added and r2.tx_data[1].added);
    try testing.expectEqualStrings("Ann", r2.tx_data[0].v.string);

    const db = try tc.conn.db();
    const ds = try db.datoms(arena, .eavt, .{ .e = a });
    try testing.expectEqual(@as(usize, 2), ds.len);
    try testing.expectEqualStrings("Anne", ds[1].v.string);
    try testing.expectEqual(@as(u64, 4), ds[1].t);
    try testing.expectEqual(@as(u64, 3), ds[0].t);

    // as-of 3 shows Ann; history shows all three name rows.
    const old = try db.asOf(3).datoms(arena, .eavt, .{ .e = a, .a = name });
    try testing.expectEqualStrings("Ann", old[0].v.string);
    const hist = try db.withHistory().datoms(arena, .eavt, .{ .e = a, .a = name });
    try testing.expectEqual(@as(usize, 3), hist.len);

    // Lookup ref and ident-based attribute resolution; retract; retract-attr.
    const r3 = try transactOps(tc.conn, arena, &.{
        .{ .retract = .{ .e = .{ .lookup = .{ .a = .{ .ident = try kw(tc, "user/email") }, .v = .{ .string = "a@x" } } }, .a = .{ .ident = try kw(tc, "user/name") }, .v = .{ .val = .{ .string = "Anne" } } } },
        .{ .retract = .{ .e = .{ .eid = a }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "never" } } } },
    }, .{});
    try testing.expectEqual(@as(usize, 2), r3.tx_data.len);
    const after = try (try tc.conn.db()).datoms(arena, .eavt, .{ .e = a });
    try testing.expectEqual(@as(usize, 1), after.len);
    try testing.expectEqual(email, after[0].a);
    try testing.expectEqual(@as(u64, 0), (try (try tc.conn.db()).attr(name)).?.count);
    try testing.expectEqual(@as(u64, 1), (try (try tc.conn.db()).attr(email)).?.count);

    // Errors.
    try testing.expectError(error.UnknownAttribute, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .ident = try kw(tc, "user/nope") }, .v = .{ .val = .{ .string = "x" } } } },
    }, .{}));
    try testing.expectError(error.ValueType, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = age }, .v = .{ .val = .{ .string = "x" } } } },
    }, .{}));
    try testing.expectError(error.NoEntity, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .lookup = .{ .a = .{ .id = email }, .v = .{ .string = "nobody" } } }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 1 } } } },
    }, .{}));
    try testing.expectError(error.Conflict, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 1 } } } },
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 2 } } } },
    }, .{}));
    try testing.expectError(error.Conflict, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 1 } } } },
        .{ .retract = .{ .e = .{ .eid = a }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 1 } } } },
    }, .{}));
    // A failed transaction left t alone.
    try testing.expectEqual(@as(u64, 5), (try tc.conn.db()).basis);
}

test "unique identity upsert, unique conflicts, card-many, retractEntity cascade" {
    const tc = try TestConn.init("tx_unique");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const email = try attrId(tc, "user/email");
    const name = try attrId(tc, "user/name");
    const tags = try attrId(tc, "user/tags");
    const friend = try attrId(tc, "user/friend");
    const home = try attrId(tc, "user/home");
    const city = try attrId(tc, "addr/city");

    const r1 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "a@x" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = tags }, .v = .{ .keyword = try kw(tc, "tag/red") } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = tags }, .v = .{ .keyword = try kw(tc, "tag/blue") } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = home }, .v = .{ .entity = .{ .tempid = .{ .string = "h" } } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "h" } }, .a = .{ .id = city }, .v = .{ .val = .{ .string = "Oslo" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "b" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "b@x" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "b" } }, .a = .{ .id = friend }, .v = .{ .entity = .{ .tempid = .{ .string = "a" } } } } },
    }, .{});
    const a = r1.tempids[0].eid;
    const h = r1.tempids[1].eid;
    const b = r1.tempids[2].eid;
    try testing.expect(a != h and h != b);

    // Upsert: a new tempid with a's email is a.
    const r2 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "x" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "a@x" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "x" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Ann" } } } },
    }, .{});
    try testing.expectEqual(a, r2.tempids[0].eid);
    try testing.expectEqual(@as(usize, 2), r2.tx_data.len);

    // Two tempids with one identity unify; a same-tx lookup ref resolves.
    const r3 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "p" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "c@x" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "q" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "c@x" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "q" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Cy" } } } },
        .{ .add = .{ .e = .{ .lookup = .{ .a = .{ .id = email }, .v = .{ .string = "c@x" } } }, .a = .{ .id = tags }, .v = .{ .keyword = try kw(tc, "tag/red") } } },
    }, .{});
    try testing.expectEqual(r3.tempids[0].eid, r3.tempids[1].eid);
    try testing.expectEqual(@as(usize, 4), r3.tx_data.len);

    // Unique collision with an explicit different entity.
    try testing.expectError(error.Unique, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = b }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "a@x" } } } },
    }, .{}));
    // Same-transaction unique collision.
    try testing.expectError(error.Unique, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "n1" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "z@x" } } } },
        .{ .add = .{ .e = .{ .eid = b }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "z@x" } } } },
    }, .{}));

    // Card-many re-assert is a no-op; retract-attr removes both tags.
    const r4 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = tags }, .v = .{ .keyword = try kw(tc, "tag/red") } } },
        .{ .retract_attr = .{ .e = .{ .eid = b }, .a = .{ .id = friend } } },
    }, .{});
    try testing.expectEqual(@as(usize, 2), r4.tx_data.len);
    try testing.expect(!r4.tx_data[0].added);

    // VAET: nobody points at a now.
    const db4 = try tc.conn.db();
    const vb = try key.valBytes(arena, .{ .ref = a });
    try testing.expectEqual(@as(usize, 0), (try db4.datoms(arena, .vaet, .{ .v = vb })).len);
    try testing.expectEqual(@as(usize, 1), (try db4.asOf(r3.t).datoms(arena, .vaet, .{ .v = vb })).len);

    // retractEntity a: its datoms, the component home h, and nothing else.
    const r5 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = b }, .a = .{ .id = friend }, .v = .{ .val = .{ .ref = a } } } },
    }, .{});
    _ = r5;
    const r6 = try transactOps(tc.conn, arena, &.{.{ .retract_entity = .{ .eid = a } }}, .{});
    const db6 = try tc.conn.db();
    try testing.expectEqual(@as(usize, 0), (try db6.datoms(arena, .eavt, .{ .e = a })).len);
    try testing.expectEqual(@as(usize, 0), (try db6.datoms(arena, .eavt, .{ .e = h })).len);
    try testing.expectEqual(@as(usize, 1), (try db6.datoms(arena, .eavt, .{ .e = b })).len);
    var retracted: usize = 0;
    for (r6.tx_data) |d| {
        if (!d.added) retracted += 1;
    }
    // a: email, name, tags x2, home; h: city; b: friend -> a.
    try testing.expectEqual(@as(usize, 7), retracted);
    try testing.expectEqual(@as(usize, 10), (try db6.withHistory().datoms(arena, .eavt, .{ .e = a })).len);
    try testing.expectEqual(@as(usize, 2), (try db6.withHistory().datoms(arena, .eavt, .{ .e = h })).len);
}

test "schema changes: index backfill, unique backfill refusal, immutable type" {
    const tc = try TestConn.init("tx_schema");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const name = try attrId(tc, "user/name");
    const age = try attrId(tc, "user/age");

    const r1 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Ann" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "b" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Ann" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 1 } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "b" } }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 2 } } } },
    }, .{});
    const a = r1.tempids[0].eid;

    // AVET on name is empty before the index, full after, with original t.
    const nb = try key.valBytes(arena, .{ .string = "Ann" });
    try testing.expectEqual(@as(usize, 0), (try (try tc.conn.db()).datoms(arena, .avet, .{ .a = name, .v = nb })).len);
    const r2 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = name }, .a = .{ .id = boot.index }, .v = .{ .val = .{ .boolean = true } } } },
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Anne" } } } },
    }, .{});
    const db2 = try tc.conn.db();
    const hits = try db2.datoms(arena, .avet, .{ .a = name, .v = nb });
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqual(r1.t, hits[0].t);
    const ab = try key.valBytes(arena, .{ .string = "Anne" });
    try testing.expectEqual(@as(usize, 1), (try db2.datoms(arena, .avet, .{ .a = name, .v = ab })).len);
    try testing.expect((try db2.attr(name)).?.indexed);
    try testing.expect(!(try db2.asOf(r1.t).attr(name)).?.indexed);
    _ = r2;

    // Unique on age is fine (distinct values); unique on name would collide.
    _ = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = age }, .a = .{ .id = boot.unique }, .v = .{ .val = .{ .keyword = boot.unique_value } } } },
    }, .{});
    try testing.expectError(error.Unique, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "c" } }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 1 } } } },
    }, .{}));
    _ = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Ann" } } } },
    }, .{});
    try testing.expectError(error.Unique, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = name }, .a = .{ .id = boot.unique }, .v = .{ .val = .{ .keyword = boot.unique_value } } } },
    }, .{}));
    // Value type never changes.
    try testing.expectError(error.Conflict, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = age }, .a = .{ .id = boot.value_type }, .v = .{ .val = .{ .keyword = boot.type_string } } } },
    }, .{}));
    // A new attribute needs a type and a cardinality; a bad type ident is refused.
    try testing.expectError(error.TxData, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "n" } }, .a = .{ .id = boot.ident }, .v = .{ .keyword = try kw(tc, "user/half") } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "n" } }, .a = .{ .id = boot.value_type }, .v = .{ .val = .{ .keyword = boot.type_string } } } },
    }, .{}));
    try testing.expectError(error.ValueType, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "n" } }, .a = .{ .id = boot.ident }, .v = .{ .keyword = try kw(tc, "user/bad") } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "n" } }, .a = .{ .id = boot.value_type }, .v = .{ .val = .{ .keyword = boot.card_one } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "n" } }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_one } } } },
    }, .{}));
    // An ident on a user entity is refused; the aborted mints were not kept.
    try testing.expectError(error.Conflict, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = boot.ident }, .v = .{ .keyword = try kw(tc, "user/alias") } } },
    }, .{}));
    const txn = try tc.conn.store.beginRead();
    defer txn.abort();
    try testing.expect((try tc.conn.idents.idOfName(txn, "user/half")) == null);
}

test "Lisp tx-data: vector forms, map forms, nested maps, card-many vectors, datomic.tx" {
    const tc = try TestConn.init("tx_lisp");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var heap = nx.heap.Heap.init(arena);
    defer heap.deinit();
    const dispatch = nx.dispatch;
    try installSchema(tc, arena);
    const email = try attrId(tc, "user/email");
    const home = try attrId(tc, "user/home");
    const tags = try attrId(tc, "user/tags");
    const city = try attrId(tc, "addr/city");
    const friend = try attrId(tc, "user/friend");

    const K = struct {
        fn k(t: *TestConn, n: []const u8) !Value {
            return t.interner.internKeywordValue(n);
        }
    };
    const s = struct {
        fn s(h: *nx.heap.Heap, t: []const u8) !Value {
            return string_mod.fromBytes(h, t);
        }
    };
    var m = try champ.mapEmpty(&heap);
    m = try champ.mapAssoc(&heap, m, try K.k(tc, "db/id"), try s.s(&heap, "ann"), &dispatch.hashValue, &dispatch.equal);
    m = try champ.mapAssoc(&heap, m, try K.k(tc, "user/email"), try s.s(&heap, "ann@x"), &dispatch.hashValue, &dispatch.equal);
    const tagv = try vector_mod.fromSlice(&heap, &.{ try K.k(tc, "tag/a"), try K.k(tc, "tag/b") });
    m = try champ.mapAssoc(&heap, m, try K.k(tc, "user/tags"), tagv, &dispatch.hashValue, &dispatch.equal);
    var nested = try champ.mapEmpty(&heap);
    nested = try champ.mapAssoc(&heap, nested, try K.k(tc, "addr/city"), try s.s(&heap, "Rome"), &dispatch.hashValue, &dispatch.equal);
    m = try champ.mapAssoc(&heap, m, try K.k(tc, "user/home"), nested, &dispatch.hashValue, &dispatch.equal);
    const friends = try vector_mod.fromSlice(&heap, &.{try s.s(&heap, "bob")});
    m = try champ.mapAssoc(&heap, m, try K.k(tc, "user/friend"), friends, &dispatch.hashValue, &dispatch.equal);

    const add_bob = try vector_mod.fromSlice(&heap, &.{ try K.k(tc, "db/add"), try s.s(&heap, "bob"), try K.k(tc, "user/email"), try s.s(&heap, "bob@x") });
    const tx_doc = try vector_mod.fromSlice(&heap, &.{ try K.k(tc, "db/add"), try s.s(&heap, "datomic.tx"), try K.k(tc, "db/doc"), try s.s(&heap, "import") });
    const tx_data = try vector_mod.fromSlice(&heap, &.{ m, add_bob, tx_doc });

    const r = try transactOps(tc.conn, arena, &.{}, .{});
    _ = r;
    const clock = store_mod.nowMillis() + 42_000;
    const rep = try transact(tc.conn, arena, tx_data, .{ .now_ms = clock });
    try testing.expectEqual(@as(usize, 2), rep.tempids.len);
    const ann = rep.tempids[0].eid;
    const bob = rep.tempids[1].eid;
    const db = try tc.conn.db();
    const ent = try db.entity(arena, ann);
    try testing.expectEqual(@as(usize, 4), ent.len);
    try testing.expectEqual(email, ent[0].a);
    try testing.expectEqual(tags, ent[1].a);
    try testing.expectEqual(@as(usize, 2), ent[1].vals.len);
    try testing.expectEqual(friend, ent[2].a);
    try testing.expectEqual(bob, ent[2].vals[0].ref);
    try testing.expectEqual(home, ent[3].a);
    const home_e = ent[3].vals[0].ref;
    const home_ent = try db.entity(arena, home_e);
    try testing.expectEqual(city, home_ent[0].a);
    try testing.expectEqualStrings("Rome", home_ent[0].vals[0].string);
    const txe = try db.entity(arena, key.txEntity(rep.t));
    try testing.expectEqual(@as(usize, 2), txe.len);
    try testing.expectEqual(boot.doc, txe[0].a);
    try testing.expectEqual(clock, txe[1].vals[0].instant);

    // retractEntity by lookup ref through a vector form.
    const lookup = try vector_mod.fromSlice(&heap, &.{ try K.k(tc, "user/email"), try s.s(&heap, "bob@x") });
    const re = try vector_mod.fromSlice(&heap, &.{ try K.k(tc, "db/retractEntity"), lookup });
    const rep2 = try transact(tc.conn, arena, try vector_mod.fromSlice(&heap, &.{re}), .{});
    try testing.expectEqual(@as(usize, 3), rep2.tx_data.len);
    try testing.expectEqual(@as(usize, 0), (try (try tc.conn.db()).entity(arena, bob)).len);

    // Malformed forms.
    const bad = try vector_mod.fromSlice(&heap, &.{try K.k(tc, "db/add")});
    try testing.expectError(error.TxData, transact(tc.conn, arena, try vector_mod.fromSlice(&heap, &.{bad}), .{}));
    try testing.expectError(error.TxData, transact(tc.conn, arena, try s.s(&heap, "nope"), .{}));
}

/// Lisp values for tx-data tests.
const Lisp = struct {
    tc: *TestConn,
    heap: *nx.heap.Heap,

    const dispatch = nx.dispatch;
    const KV = struct { []const u8, Value };

    fn kw(self: Lisp, name: []const u8) !Value {
        return self.tc.interner.internKeywordValue(name);
    }
    fn str(self: Lisp, text: []const u8) !Value {
        return string_mod.fromBytes(self.heap, text);
    }
    fn vec(self: Lisp, items: []const Value) !Value {
        return vector_mod.fromSlice(self.heap, items);
    }
    fn map(self: Lisp, entries: []const KV) !Value {
        var m = try champ.mapEmpty(self.heap);
        for (entries) |e| m = try champ.mapAssoc(self.heap, m, try self.kw(e[0]), e[1], &dispatch.hashValue, &dispatch.equal);
        return m;
    }
};

test "a reverse ref in a map form asserts the forward datom" {
    const tc = try TestConn.init("tx_reverse");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var heap = nx.heap.Heap.init(arena);
    defer heap.deinit();
    const l = Lisp{ .tc = tc, .heap = &heap };
    try installSchema(tc, arena);
    const friend = try attrId(tc, "user/friend");
    const home = try attrId(tc, "user/home");

    // Ann and Bob befriend Cy through Cy's map; Cy's home names its
    // owner through a reverse component ref, from a nested map.
    const r = try transact(tc.conn, arena, try l.vec(&.{
        try l.map(&.{ .{ "db/id", try l.str("ann") }, .{ "user/email", try l.str("ann@x") } }),
        try l.map(&.{ .{ "db/id", try l.str("bob") }, .{ "user/email", try l.str("bob@x") } }),
        try l.map(&.{
            .{ "db/id", try l.str("cy") },
            .{ "user/email", try l.str("cy@x") },
            .{ "user/_friend", try l.vec(&.{ try l.str("ann"), try l.vec(&.{ try l.kw("user/email"), try l.str("bob@x") }) }) },
        }),
        try l.map(&.{ .{ "addr/city", try l.str("Rome") }, .{ "user/_home", try l.str("cy") } }),
        try l.map(&.{ .{ "db/id", try l.str("di") }, .{ "user/email", try l.str("di@x") }, .{ "user/_friend", try l.map(&.{.{ "user/email", try l.str("ed@x") }}) } }),
    }), .{});
    var ann: u64 = 0;
    var bob: u64 = 0;
    var cy: u64 = 0;
    var di: u64 = 0;
    for (r.tempids) |b| {
        if (std.mem.eql(u8, b.key.string, "ann")) ann = b.eid;
        if (std.mem.eql(u8, b.key.string, "bob")) bob = b.eid;
        if (std.mem.eql(u8, b.key.string, "cy")) cy = b.eid;
        if (std.mem.eql(u8, b.key.string, "di")) di = b.eid;
    }
    const db = try tc.conn.db();
    const ann_friends = try db.datoms(arena, .eavt, .{ .e = ann, .a = friend });
    try testing.expectEqual(@as(usize, 1), ann_friends.len);
    try testing.expectEqual(cy, ann_friends[0].v.ref);
    const bob_friends = try db.datoms(arena, .eavt, .{ .e = bob, .a = friend });
    try testing.expectEqual(cy, bob_friends[0].v.ref);
    try testing.expectEqual(@as(usize, 0), (try db.datoms(arena, .eavt, .{ .e = cy, .a = friend })).len);
    const cy_home = try db.datoms(arena, .eavt, .{ .e = cy, .a = home });
    try testing.expectEqual(@as(usize, 1), cy_home.len);
    const ed_friends = try db.datoms(arena, .vaet, .{ .a = friend, .v = try key.valBytes(arena, .{ .ref = di }) });
    try testing.expectEqual(@as(usize, 1), ed_friends.len);

    // A reverse ref needs a ref attribute and an entity value.
    try testing.expectError(error.TxData, transact(tc.conn, arena, try l.vec(&.{
        try l.map(&.{ .{ "db/id", try l.str("x") }, .{ "user/_email", try l.str("ann@x") } }),
    }), .{}));
    try testing.expectError(error.UnknownAttribute, transact(tc.conn, arena, try l.vec(&.{
        try l.map(&.{ .{ "db/id", try l.str("x") }, .{ "user/_nope", try l.str("ann") } }),
    }), .{}));
    try testing.expectError(error.TxData, transact(tc.conn, arena, try l.vec(&.{
        try l.map(&.{ .{ "db/id", try l.str("x") }, .{ "user/_friend", value.fromBool(true) } }),
    }), .{}));
}

test "a nested map under a plain ref must carry an identity" {
    const tc = try TestConn.init("tx_nested_identity");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var heap = nx.heap.Heap.init(arena);
    defer heap.deinit();
    const l = Lisp{ .tc = tc, .heap = &heap };
    try installSchema(tc, arena);

    // Under a component, or with a unique attribute or a :db/id, a
    // nested map is an entity; otherwise it would be an orphan.
    const ok = try transact(tc.conn, arena, try l.vec(&.{
        try l.map(&.{
            .{ "user/email", try l.str("ann@x") },
            .{ "user/home", try l.map(&.{.{ "addr/city", try l.str("Rome") }}) },
            .{ "user/friend", try l.vec(&.{
                try l.map(&.{.{ "user/email", try l.str("bob@x") }}),
                try l.map(&.{ .{ "db/id", try l.str("cy") }, .{ "user/name", try l.str("Cy") } }),
            }) },
        }),
    }), .{});
    try testing.expectEqual(@as(usize, 1), ok.tempids.len);
    const ann = (try (try tc.conn.db()).entid(arena, .{ .lookup = .{ .a = try attrId(tc, "user/email"), .v = .{ .string = "ann@x" } } })).?;
    try testing.expectEqual(@as(usize, 2), (try (try tc.conn.db()).datoms(arena, .eavt, .{ .e = ann, .a = try attrId(tc, "user/friend") })).len);
    try testing.expectError(error.TxData, transact(tc.conn, arena, try l.vec(&.{
        try l.map(&.{
            .{ "user/email", try l.str("ann@x") },
            .{ "user/friend", try l.map(&.{.{ "user/name", try l.str("Orphan") }}) },
        }),
    }), .{}));
}

test "nested map forms past the stack budget fail with StackOverflow and abort" {
    const tc = try TestConn.init("tx_nested_deep");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var heap = nx.heap.Heap.init(arena);
    defer heap.deinit();
    const l = Lisp{ .tc = tc, .heap = &heap };
    try installSchema(tc, arena);

    var m = try l.map(&.{.{ "addr/city", try l.str("Rome") }});
    for (0..100_000) |_| m = try l.map(&.{.{ "user/home", m }});
    stack.arm(1 << 20);
    defer stack.arm(stack.main_thread_budget);
    try testing.expectError(error.StackOverflow, transact(tc.conn, arena, try l.vec(&.{m}), .{}));
    // The write transaction is gone: the next one takes the next t.
    var shallow = try l.map(&.{.{ "addr/city", try l.str("Oslo") }});
    for (0..50) |_| shallow = try l.map(&.{.{ "user/home", shallow }});
    const r = try transact(tc.conn, arena, try l.vec(&.{shallow}), .{});
    try testing.expectEqual(@as(u64, 3), r.t);
    try testing.expectEqual(@as(usize, 52), r.tx_data.len);
}

test "a failing transaction reports what it was looking at" {
    const tc = try TestConn.init("tx_fault");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var heap = nx.heap.Heap.init(arena);
    defer heap.deinit();
    const l = Lisp{ .tc = tc, .heap = &heap };
    try installSchema(tc, arena);
    const email = try attrId(tc, "user/email");
    const age = try attrId(tc, "user/age");
    const k_email = try kw(tc, "user/email");
    const k_age = try kw(tc, "user/age");
    const r = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "a@x" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "b" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "b@x" } } } },
    }, .{});
    const a = r.tempids[0].eid;

    var fault: Fault = .{};
    // Unique: the attribute and the value.
    try testing.expectError(error.Unique, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "b@x" } } } },
    }, .{ .fault = &fault }));
    try testing.expectEqual(k_email, fault.attr.?.asKeywordId());
    try testing.expectEqualStrings("b@x", fault.value.?.string);
    try testing.expect(fault.e == null);
    // Conflict: the entity and the attribute.
    fault = .{};
    try testing.expectError(error.Conflict, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 1 } } } },
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 2 } } } },
    }, .{ .fault = &fault }));
    try testing.expectEqual(k_age, fault.attr.?.asKeywordId());
    try testing.expectEqual(a, fault.e.?);
    // Unknown attribute: as the program named it.
    fault = .{};
    const k_nope = try kw(tc, "user/nope");
    try testing.expectError(error.UnknownAttribute, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .ident = k_nope }, .v = .{ .val = .{ .long = 1 } } } },
    }, .{ .fault = &fault }));
    try testing.expectEqual(k_nope, fault.attr.?.asKeywordId());
    fault = .{};
    try testing.expectError(error.UnknownAttribute, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = 4000 }, .v = .{ .val = .{ .long = 1 } } } },
    }, .{ .fault = &fault }));
    try testing.expectEqual(@as(i64, 4000), fault.attr.?.asFixnum());
    // Malformed tx-data: the reason.
    fault = .{};
    try testing.expectError(error.TxData, transact(tc.conn, arena, try l.vec(&.{
        try l.vec(&.{ try l.kw("db/add"), value.fromFixnum(@intCast(a)).?, try l.kw("user/age") }),
    }), .{ .fault = &fault }));
    try testing.expect(fault.message != null);
    // Nothing is reported when nothing fails, and a fault is optional.
    fault = .{};
    _ = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 3 } } } },
    }, .{ .fault = &fault });
    try testing.expect(fault.attr == null and fault.message == null);
}

test "a card-many attribute cannot be unique" {
    const tc = try TestConn.init("tx_unique_many");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const tags = try attrId(tc, "user/tags");

    try testing.expectError(error.TxData, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = tags }, .a = .{ .id = boot.unique }, .v = .{ .val = .{ .keyword = boot.unique_value } } } },
    }, .{}));
    try testing.expectError(error.TxData, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "nick" } }, .a = .{ .id = boot.ident }, .v = .{ .keyword = try kw(tc, "user/nick") } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "nick" } }, .a = .{ .id = boot.value_type }, .v = .{ .val = .{ .keyword = boot.type_string } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "nick" } }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_many } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "nick" } }, .a = .{ .id = boot.unique }, .v = .{ .val = .{ .keyword = boot.unique_identity } } } },
    }, .{}));
    try testing.expect((try (try tc.conn.db()).attr(tags)).?.unique == .none);
}

test "long strings round trip through the payload in every view" {
    const tc = try TestConn.init("tx_long");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const bio = try attrId(tc, "user/bio");
    const long = &@as([40_000]u8, @splat('L'));
    const r = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = bio }, .v = .{ .val = .{ .string = long } } } },
    }, .{});
    const a = r.tempids[0].eid;
    const db = try tc.conn.db();
    for ([_]DbValue{ db, db.asOf(r.t), db.withHistory(), db.sinceT(r.t - 1) }) |view| {
        const ds = try view.datoms(arena, .eavt, .{ .e = a });
        try testing.expectEqual(@as(usize, 1), ds.len);
        try testing.expectEqualStrings(long, ds[0].v.string);
        const via_aevt = try view.datoms(arena, .aevt, .{ .a = bio });
        try testing.expectEqualStrings(long, via_aevt[0].v.string);
    }
    // Re-assertion is a no-op; a different long value with the same prefix replaces it.
    const r2 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = bio }, .v = .{ .val = .{ .string = long } } } },
    }, .{});
    try testing.expectEqual(@as(usize, 1), r2.tx_data.len);
    const other = long[0 .. long.len - 1] ++ "M";
    const r3 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = bio }, .v = .{ .val = .{ .string = other } } } },
    }, .{});
    try testing.expectEqual(@as(usize, 3), r3.tx_data.len);
    try testing.expectEqualStrings(long, r3.tx_data[0].v.string);
    const now = try (try tc.conn.db()).datoms(arena, .eavt, .{ .e = a });
    try testing.expectEqualStrings(other, now[0].v.string);
    const txs = try db_mod.txRange(tc.conn, arena, r3.t, null);
    try testing.expectEqualStrings(other, txs[0].datoms[1].v.string);
}

test "with: the view sees the speculative state, the connection does not" {
    const tc = try TestConn.init("tx_with");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const email = try attrId(tc, "user/email");
    const name = try attrId(tc, "user/name");
    const tags = try attrId(tc, "user/tags");
    const home = try attrId(tc, "user/home");
    const city = try attrId(tc, "addr/city");
    const k_new = try kw(tc, "tag/new");
    const before = try tc.conn.db();

    const w = try withOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "a@x" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Ann" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = tags }, .v = .{ .keyword = k_new } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = home }, .v = .{ .entity = .{ .tempid = .{ .string = "h" } } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "h" } }, .a = .{ .id = city }, .v = .{ .val = .{ .string = "Oslo" } } } },
    }, .{});
    defer w.finish();

    // The report.
    try testing.expectEqual(before.basis + 1, w.report.t);
    try testing.expectEqual(before.basis, w.report.db_before.basis);
    try testing.expectEqual(w.report.t, w.db().basis);
    try testing.expectEqual(@as(usize, 2), w.report.tempids.len);
    try testing.expectEqual(@as(usize, 6), w.report.tx_data.len);
    const a = w.report.tempids[0].eid;
    const h = w.report.tempids[1].eid;

    // Every read of the view sees the speculative datoms.
    const view = w.db();
    try testing.expectEqual(@as(usize, 4), (try view.entity(arena, a)).len);
    try testing.expectEqual(@as(usize, 1), (try view.datoms(arena, .aevt, .{ .a = email })).len);
    const hb = try key.valBytes(arena, .{ .ref = h });
    try testing.expectEqual(@as(usize, 1), (try view.datoms(arena, .vaet, .{ .v = hb })).len);
    try testing.expectEqual(@as(?u64, a), try view.entid(arena, .{ .lookup = .{ .a = email, .v = .{ .string = "a@x" } } }));
    try testing.expectEqual(@as(u64, 1), (try view.attr(email)).?.count);
    const entries = try db_mod.txRange(w.view, arena, w.report.t, null);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(@as(usize, 6), entries[0].datoms.len);
    try testing.expectEqual(w.report.t, (try w.view.db()).basis);
    // Time travel on the view folds the speculative rows like any other.
    try testing.expectEqual(@as(usize, 0), (try view.asOf(before.basis).entity(arena, a)).len);
    try testing.expectEqual(@as(usize, 4), (try view.withHistory().datoms(arena, .eavt, .{ .e = a })).len);
    try testing.expectEqual(@as(usize, 4), (try view.sinceT(before.basis).datoms(arena, .eavt, .{ .e = a })).len);
    // The minted keyword resolves through the view's cache only.
    {
        const txn = try w.view.beginReadTxn();
        defer w.view.endReadTxn(txn);
        try testing.expect((try w.view.idents.idOf(txn, k_new)) != null);
    }
    try testing.expect(tc.conn.idents.by_intern.get(k_new) == null);

    // The committed state is untouched.
    try testing.expectEqual(before.basis, (try tc.conn.db()).basis);
    try testing.expectEqual(@as(usize, 0), (try before.entity(arena, a)).len);
    try testing.expectEqual(@as(usize, 0), (try w.report.db_before.entity(arena, a)).len);
    try testing.expectEqual(@as(u64, 0), (try before.attr(email)).?.count);

    // One write transaction per store: nothing else may begin one.
    try testing.expectError(error.Nested, withOps(tc.conn, arena, &.{}, .{}));
    try testing.expectError(error.Nested, transactOps(tc.conn, arena, &.{}, .{}));
    try testing.expectError(error.Nested, transactOps(w.view, arena, &.{}, .{}));
    try testing.expectError(error.Nested, withOps(w.view, arena, &.{}, .{}));

    w.finish();
    w.finish();
    try testing.expectError(error.Closed, view.entity(arena, a));
    try testing.expect(tc.conn.speculative == null);
    try testing.expectEqual(before.basis, (try tc.conn.db()).basis);
    {
        const txn = try tc.conn.store.beginRead();
        defer txn.abort();
        try testing.expect((try tc.conn.idents.idOf(txn, k_new)) == null);
    }

    // A real transaction takes the same t, the same eid and the same ident id.
    const r = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "b" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Bob" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "b" } }, .a = .{ .id = tags }, .v = .{ .keyword = k_new } } },
    }, .{});
    try testing.expectEqual(w.report.t, r.t);
    try testing.expectEqual(a, r.tempids[0].eid);
    try testing.expectEqual(w.report.tx_data[2].v.keyword, r.tx_data[1].v.keyword);
    try testing.expectEqual(@as(usize, 2), (try (try tc.conn.db()).entity(arena, a)).len);
}

test "with: errors surface without holding the write transaction; schema changes stay in the view" {
    const tc = try TestConn.init("tx_with_err");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const email = try attrId(tc, "user/email");
    const age = try attrId(tc, "user/age");
    const r0 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "a@x" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "b" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "b@x" } } } },
    }, .{});
    const a = r0.tempids[0].eid;
    const b = r0.tempids[1].eid;

    try testing.expectError(error.Conflict, withOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 1 } } } },
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 2 } } } },
    }, .{}));
    try testing.expectError(error.Unique, withOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = b }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "a@x" } } } },
    }, .{}));
    try testing.expectError(error.UnknownAttribute, withOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .ident = try kw(tc, "user/nope") }, .v = .{ .val = .{ .long = 1 } } } },
    }, .{}));
    try testing.expectError(error.ValueType, withOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = age }, .v = .{ .val = .{ .string = "x" } } } },
    }, .{}));
    try testing.expect(tc.conn.speculative == null);
    try testing.expectEqual(r0.t, (try tc.conn.db()).basis);
    try testing.expectEqual(@as(usize, 1), (try (try tc.conn.db()).entity(arena, a)).len);

    // A speculative attribute exists in the view and nowhere else.
    const w = try withOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "nick" } }, .a = .{ .id = boot.ident }, .v = .{ .keyword = try kw(tc, "user/nick") } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "nick" } }, .a = .{ .id = boot.value_type }, .v = .{ .val = .{ .keyword = boot.type_string } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "nick" } }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_one } } } },
    }, .{});
    defer w.finish();
    const nick: u32 = @intCast(w.report.tempids[0].eid);
    try testing.expectEqual(key.ValueType.string, (try w.db().attr(nick)).?.value_type);
    try testing.expectEqual(@as(?u64, nick), try w.db().entid(arena, .{ .ident = try kw(tc, "user/nick") }));
    try testing.expect((try (try tc.conn.db()).attr(nick)) == null);
    w.finish();
    try testing.expect((try (try tc.conn.db()).attr(nick)) == null);
    try testing.expectEqual(r0.t, (try tc.conn.db()).basis);
    const r1 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 3 } } } },
    }, .{});
    try testing.expectEqual(r0.t + 1, r1.t);
}

test "with: Lisp tx-data" {
    const tc = try TestConn.init("tx_with_lisp");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var heap = nx.heap.Heap.init(arena);
    defer heap.deinit();
    try installSchema(tc, arena);
    const name = try attrId(tc, "user/name");
    const add = try vector_mod.fromSlice(&heap, &.{
        try tc.interner.internKeywordValue("db/add"),
        try string_mod.fromBytes(&heap, "z"),
        try tc.interner.internKeywordValue("user/name"),
        try string_mod.fromBytes(&heap, "Zed"),
    });
    const clock = store_mod.nowMillis() + 7_000;
    const w = try with(tc.conn, arena, try vector_mod.fromSlice(&heap, &.{add}), .{ .now_ms = clock });
    defer w.finish();
    const z = w.report.tempids[0].eid;
    const ent = try w.db().entity(arena, z);
    try testing.expectEqual(@as(usize, 1), ent.len);
    try testing.expectEqual(name, ent[0].a);
    try testing.expectEqualStrings("Zed", ent[0].vals[0].string);
    try testing.expectEqual(clock, (try w.db().entity(arena, key.txEntity(w.report.t)))[0].vals[0].instant);
    w.finish();
    try testing.expectError(error.TxData, with(tc.conn, arena, try string_mod.fromBytes(&heap, "nope"), .{}));
    try testing.expect(tc.conn.speculative == null);
}

test "a string with an escaped NUL never aliases its prefix under a prefix scan" {
    const tc = try TestConn.init("tx_nul_alias");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const email = try attrId(tc, "user/email");
    const name = try attrId(tc, "user/name");

    // x's identity is "a\x00b", whose encoding starts with the encoding of "a".
    const r1 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "x" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "a\x00b" } } } },
    }, .{});
    const x = r1.tempids[0].eid;
    const db = try tc.conn.db();
    const a_bytes = try key.valBytes(arena, .{ .string = "a" });

    // Reads: no datom carries "a".
    try testing.expect((try db.entid(arena, .{ .lookup = .{ .a = email, .v = .{ .string = "a" } } })) == null);
    try testing.expectEqual(@as(usize, 0), (try db.datoms(arena, .avet, .{ .a = email, .v = a_bytes })).len);
    try testing.expectEqual(@as(usize, 0), (try db.datoms(arena, .eavt, .{ .e = x, .a = email, .v = a_bytes })).len);
    try testing.expectEqual(@as(usize, 0), (try db.datoms(arena, .aevt, .{ .a = email, .e = x, .v = a_bytes })).len);
    try testing.expectEqual(@as(?u64, x), try db.entid(arena, .{ .lookup = .{ .a = email, .v = .{ .string = "a\x00b" } } }));

    // Writes: "a" is free, so another entity may take it, and a tempid
    // claiming it is a new entity rather than an upsert onto x.
    const r2 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "z" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "a" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "z" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Zed" } } } },
    }, .{});
    const z = r2.tempids[0].eid;
    try testing.expect(z != x);
    const db2 = try tc.conn.db();
    const xs = try db2.datoms(arena, .eavt, .{ .e = x, .a = email });
    try testing.expectEqual(@as(usize, 1), xs.len);
    try testing.expectEqualStrings("a\x00b", xs[0].v.string);
    try testing.expectEqual(@as(?u64, z), try db2.entid(arena, .{ .lookup = .{ .a = email, .v = .{ .string = "a" } } }));
    // A lookup ref on "a" now names z, not x.
    try testing.expectError(error.NoEntity, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .lookup = .{ .a = .{ .id = email }, .v = .{ .string = "a\x00" } } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "nobody" } } } },
    }, .{}));
    const r3 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .lookup = .{ .a = .{ .id = email }, .v = .{ .string = "a" } } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Zed2" } } } },
    }, .{});
    try testing.expectEqual(z, r3.tx_data[0].e);
}

test "explicit entity ids must have been allocated" {
    const tc = try TestConn.init("tx_explicit_eid");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const name = try attrId(tc, "user/name");
    const friend = try attrId(tc, "user/friend");

    const r1 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Ann" } } } },
    }, .{});
    const a = r1.tempids[0].eid;
    const next_aid = blk: {
        const txn = try tc.conn.store.beginRead();
        defer txn.abort();
        break :blk try tc.conn.store.readNextAid(txn);
    };

    // A user id the allocator has not handed out; an attribute-partition
    // id no ident holds; a transaction entity that does not exist yet.
    try testing.expectError(error.NoEntity, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a + 5 }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "ghost" } } } },
    }, .{}));
    try testing.expectError(error.NoEntity, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = next_aid + 100 }, .a = .{ .id = boot.doc }, .v = .{ .val = .{ .string = "ghost" } } } },
    }, .{}));
    try testing.expectError(error.NoEntity, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = key.txEntity(r1.t + 5) }, .a = .{ .id = boot.doc }, .v = .{ .val = .{ .string = "ghost" } } } },
    }, .{}));
    // The same ids as ref values.
    try testing.expectError(error.NoEntity, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = friend }, .v = .{ .val = .{ .ref = a + 5 } } } },
    }, .{}));
    try testing.expectError(error.NoEntity, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = friend }, .v = .{ .entity = .{ .eid = key.txEntity(r1.t + 5) } } } },
    }, .{}));
    try testing.expectEqual(r1.t, (try tc.conn.db()).basis);

    // Allocated ids are fine: an existing entity, an attribute entity, a
    // past transaction entity and this transaction's own entity, as
    // entities and as ref values.
    const r2 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = friend }, .v = .{ .val = .{ .ref = a } } } },
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = friend }, .v = .{ .val = .{ .ref = key.txEntity(r1.t) } } } },
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = friend }, .v = .{ .val = .{ .ref = name } } } },
        .{ .add = .{ .e = .{ .eid = name }, .a = .{ .id = boot.doc }, .v = .{ .val = .{ .string = "a name" } } } },
        .{ .add = .{ .e = .{ .eid = key.txEntity(r1.t) }, .a = .{ .id = boot.doc }, .v = .{ .val = .{ .string = "old tx" } } } },
        .{ .add = .{ .e = .{ .eid = key.txEntity(r1.t + 1) }, .a = .{ .id = boot.doc }, .v = .{ .val = .{ .string = "this tx" } } } },
    }, .{});
    try testing.expectEqual(r1.t + 1, r2.t);
    try testing.expectEqual(@as(usize, 7), r2.tx_data.len);
    // An allocated entity stays addressable after every datom is retracted.
    _ = try transactOps(tc.conn, arena, &.{.{ .retract_entity = .{ .eid = a } }}, .{});
    const r4 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Back" } } } },
    }, .{});
    try testing.expectEqual(a, r4.tx_data[0].e);
}

/// Transact one new entity with a fresh keyword value while allocation
/// `fail_index` of `where` fails; returns whether a failure was induced.
fn transactWithFailure(tc: *TestConn, arena: Allocator, name: u32, tags: u32, where: enum { arena, cache }, fail_index: usize) !bool {
    var tx_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer tx_arena.deinit();
    var fa = std.testing.FailingAllocator.init(if (where == .arena) tx_arena.allocator() else testing.allocator, .{ .fail_index = fail_index });
    const saved_gpa = tc.conn.idents.gpa;
    if (where == .cache) {
        // An empty cache has to grow for the mint, so the publication's
        // own allocation is in the sweep.
        tc.conn.idents.by_intern.clearAndFree(saved_gpa);
        tc.conn.idents.by_ident.clearAndFree(saved_gpa);
        tc.conn.idents.gpa = fa.allocator();
    }
    defer tc.conn.idents.gpa = saved_gpa;
    const tag = try kw(tc, try arena.print("tag/oom-{s}-{d}", .{ @tagName(where), fail_index }));
    const before = (try tc.conn.db()).basis;
    const result = transactOps(tc.conn, if (where == .arena) fa.allocator() else tx_arena.allocator(), &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "n" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "N" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "n" } }, .a = .{ .id = tags }, .v = .{ .keyword = tag } } },
    }, .{});
    const after = (try tc.conn.db()).basis;
    if (result) |r| {
        try testing.expectEqual(before + 1, r.t);
        try testing.expectEqual(before + 1, after);
        try testing.expectEqual(@as(usize, 1), r.tempids.len);
        try testing.expectEqual(@as(usize, 3), r.tx_data.len);
    } else |err| {
        try testing.expectEqual(error.OutOfMemory, err);
        try testing.expectEqual(before, after);
    }
    return fa.has_induced_failure;
}

test "an allocation failure never reports an error for a committed transaction" {
    const tc = try TestConn.init("tx_oom");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const name = try attrId(tc, "user/name");
    const tags = try attrId(tc, "user/tags");

    // Every allocation the transaction makes, first in its arena and
    // then in the ident cache, fails once at index i. Either the
    // transaction errors and t is untouched, or it commits and reports.
    inline for (.{ .arena, .cache }) |where| {
        var fail_index: usize = 0;
        while (try transactWithFailure(tc, arena, name, tags, where, fail_index)) : (fail_index += 1) {}
        try testing.expect(fail_index > @as(usize, if (where == .arena) 8 else 0));
    }
}

test "retractEntity expands against the committed state; the transaction's own datoms survive" {
    const tc = try TestConn.init("tx_retract_pending");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const name = try attrId(tc, "user/name");
    const age = try attrId(tc, "user/age");
    const friend = try attrId(tc, "user/friend");
    const home = try attrId(tc, "user/home");
    const city = try attrId(tc, "addr/city");

    // A tempid asserted and retracted in one transaction: the retraction
    // sees nothing committed, so the assertion stands.
    const r1 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "x" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "X" } } } },
        .{ .retract_entity = .{ .tempid = .{ .string = "x" } } },
    }, .{});
    const x = r1.tempids[0].eid;
    try testing.expectEqual(@as(usize, 2), r1.tx_data.len);
    try testing.expectEqual(@as(usize, 1), (try (try tc.conn.db()).entity(arena, x)).len);

    // A pending inbound ref is not a current (e' a' e) datom: it stays.
    const r2 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "A" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 3 } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = home }, .v = .{ .entity = .{ .tempid = .{ .string = "h1" } } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "h1" } }, .a = .{ .id = city }, .v = .{ .val = .{ .string = "Oslo" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "b" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "B" } } } },
    }, .{});
    const a = r2.tempids[0].eid;
    const h1 = r2.tempids[1].eid;
    const b = r2.tempids[2].eid;
    const r3 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = b }, .a = .{ .id = friend }, .v = .{ .val = .{ .ref = a } } } },
        .{ .retract_entity = .{ .eid = a } },
    }, .{});
    var retracted: usize = 0;
    for (r3.tx_data) |d| {
        if (!d.added) retracted += 1;
    }
    // a: name, age, home; h1: city.
    try testing.expectEqual(@as(usize, 4), retracted);
    const db3 = try tc.conn.db();
    try testing.expectEqual(@as(usize, 0), (try db3.entity(arena, a)).len);
    try testing.expectEqual(@as(usize, 0), (try db3.entity(arena, h1)).len);
    const ab = try key.valBytes(arena, .{ .ref = a });
    try testing.expectEqual(@as(usize, 1), (try db3.datoms(arena, .vaet, .{ .v = ab })).len);

    // A component replaced and its parent retracted in one transaction:
    // the committed component goes with the parent, the new one stays.
    const r4 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "p" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "P" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "p" } }, .a = .{ .id = home }, .v = .{ .entity = .{ .tempid = .{ .string = "old" } } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "old" } }, .a = .{ .id = city }, .v = .{ .val = .{ .string = "Oslo" } } } },
    }, .{});
    const p = r4.tempids[0].eid;
    const old = r4.tempids[1].eid;
    const r5 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = p }, .a = .{ .id = home }, .v = .{ .entity = .{ .tempid = .{ .string = "new" } } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "new" } }, .a = .{ .id = city }, .v = .{ .val = .{ .string = "Rome" } } } },
        .{ .retract_entity = .{ .eid = p } },
    }, .{});
    const new = r5.tempids[0].eid;
    const db5 = try tc.conn.db();
    try testing.expectEqual(@as(usize, 0), (try db5.entity(arena, old)).len);
    const p_now = try db5.entity(arena, p);
    try testing.expectEqual(@as(usize, 1), p_now.len);
    try testing.expectEqual(home, p_now[0].a);
    try testing.expectEqual(new, p_now[0].vals[0].ref);
    try testing.expectEqualStrings("Rome", (try db5.entity(arena, new))[0].vals[0].string);

    // retractEntity followed by an assertion on the same entity in one
    // transaction: the assertion is the entity's only datom afterwards.
    const r6 = try transactOps(tc.conn, arena, &.{
        .{ .retract_entity = .{ .eid = b } },
        .{ .add = .{ .e = .{ .eid = b }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 5 } } } },
    }, .{});
    _ = r6;
    const bn = try (try tc.conn.db()).entity(arena, b);
    try testing.expectEqual(@as(usize, 1), bn.len);
    try testing.expectEqual(age, bn[0].a);
}

test "retractEntity follows a component chain of any length" {
    const tc = try TestConn.init("tx_retract_chain");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const home = try attrId(tc, "user/home");
    const city = try attrId(tc, "addr/city");

    // c0 -> c1 -> ... -> cn through the component `:user/home`; a
    // native frame per level would exhaust the stack long before n.
    const n = 20_000;
    var ops: std.ArrayList(Op) = .empty;
    var names: [n + 1][]const u8 = undefined;
    for (&names, 0..) |*nm, i| nm.* = try arena.print("c{d}", .{i});
    for (0..n) |i| try ops.append(arena, .{ .add = .{ .e = .{ .tempid = .{ .string = names[i] } }, .a = .{ .id = home }, .v = .{ .entity = .{ .tempid = .{ .string = names[i + 1] } } } } });
    try ops.append(arena, .{ .add = .{ .e = .{ .tempid = .{ .string = names[n] } }, .a = .{ .id = city }, .v = .{ .val = .{ .string = "end" } } } });
    const r = try transactOps(tc.conn, arena, ops.items, .{});
    const head = r.tempids[0].eid;
    const tail = r.tempids[n].eid;
    const gone = try transactOps(tc.conn, arena, &.{.{ .retract_entity = .{ .eid = head } }}, .{});
    // Every home link and the tail's city, then the instant.
    try testing.expectEqual(@as(usize, n + 2), gone.tx_data.len);
    const db = try tc.conn.db();
    try testing.expectEqual(@as(usize, 0), (try db.entity(arena, tail)).len);
    try testing.expectEqual(@as(usize, 0), (try db.datoms(arena, .aevt, .{ .a = home })).len);
}

test "a lookup ref under a card-many ref attribute is one ref; a vector of them is a collection" {
    const tc = try TestConn.init("tx_lookup_many");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var heap = nx.heap.Heap.init(arena);
    defer heap.deinit();
    const dispatch = nx.dispatch;
    try installSchema(tc, arena);
    const email = try attrId(tc, "user/email");
    const friend = try attrId(tc, "user/friend");
    const tags = try attrId(tc, "user/tags");

    const r0 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "bob" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "bob@x" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "cy" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "cy@x" } } } },
    }, .{});
    const bob = r0.tempids[0].eid;
    const cy = r0.tempids[1].eid;

    const K = struct {
        fn k(t: *TestConn, n: []const u8) !Value {
            return t.interner.internKeywordValue(n);
        }
    };
    const lookup_bob = try vector_mod.fromSlice(&heap, &.{ try K.k(tc, "user/email"), try string_mod.fromBytes(&heap, "bob@x") });
    const lookup_cy = try vector_mod.fromSlice(&heap, &.{ try K.k(tc, "user/email"), try string_mod.fromBytes(&heap, "cy@x") });

    // One lookup ref: one friend.
    var m = try champ.mapEmpty(&heap);
    m = try champ.mapAssoc(&heap, m, try K.k(tc, "db/id"), try string_mod.fromBytes(&heap, "ann"), &dispatch.hashValue, &dispatch.equal);
    m = try champ.mapAssoc(&heap, m, try K.k(tc, "user/email"), try string_mod.fromBytes(&heap, "ann@x"), &dispatch.hashValue, &dispatch.equal);
    m = try champ.mapAssoc(&heap, m, try K.k(tc, "user/friend"), lookup_bob, &dispatch.hashValue, &dispatch.equal);
    const r1 = try transact(tc.conn, arena, try vector_mod.fromSlice(&heap, &.{m}), .{});
    try testing.expectEqual(@as(usize, 1), r1.tempids.len);
    const ann = r1.tempids[0].eid;
    const friends1 = try (try tc.conn.db()).datoms(arena, .eavt, .{ .e = ann, .a = friend });
    try testing.expectEqual(@as(usize, 1), friends1.len);
    try testing.expectEqual(bob, friends1[0].v.ref);

    // A vector of lookup refs and tempids: one friend each.
    const many = try vector_mod.fromSlice(&heap, &.{ lookup_cy, try string_mod.fromBytes(&heap, "dee") });
    var m2 = try champ.mapEmpty(&heap);
    m2 = try champ.mapAssoc(&heap, m2, try K.k(tc, "db/id"), try string_mod.fromBytes(&heap, "ann2"), &dispatch.hashValue, &dispatch.equal);
    m2 = try champ.mapAssoc(&heap, m2, try K.k(tc, "user/email"), try string_mod.fromBytes(&heap, "ann@x"), &dispatch.hashValue, &dispatch.equal);
    m2 = try champ.mapAssoc(&heap, m2, try K.k(tc, "user/friend"), many, &dispatch.hashValue, &dispatch.equal);
    var dee = try champ.mapEmpty(&heap);
    dee = try champ.mapAssoc(&heap, dee, try K.k(tc, "db/id"), try string_mod.fromBytes(&heap, "dee"), &dispatch.hashValue, &dispatch.equal);
    dee = try champ.mapAssoc(&heap, dee, try K.k(tc, "user/email"), try string_mod.fromBytes(&heap, "dee@x"), &dispatch.hashValue, &dispatch.equal);
    const r2 = try transact(tc.conn, arena, try vector_mod.fromSlice(&heap, &.{ m2, dee }), .{});
    try testing.expectEqual(ann, r2.tempids[0].eid);
    const dee_e = r2.tempids[1].eid;
    const friends2 = try (try tc.conn.db()).datoms(arena, .eavt, .{ .e = ann, .a = friend });
    try testing.expectEqual(@as(usize, 3), friends2.len);
    try testing.expectEqual(bob, friends2[0].v.ref);
    try testing.expectEqual(cy, friends2[1].v.ref);
    try testing.expectEqual(dee_e, friends2[2].v.ref);

    // A two-element keyword vector under a card-many keyword attribute is
    // still a collection, whatever its first element names.
    var m3 = try champ.mapEmpty(&heap);
    m3 = try champ.mapAssoc(&heap, m3, try K.k(tc, "db/id"), try string_mod.fromBytes(&heap, "ann3"), &dispatch.hashValue, &dispatch.equal);
    m3 = try champ.mapAssoc(&heap, m3, try K.k(tc, "user/email"), try string_mod.fromBytes(&heap, "ann@x"), &dispatch.hashValue, &dispatch.equal);
    m3 = try champ.mapAssoc(&heap, m3, try K.k(tc, "user/tags"), try vector_mod.fromSlice(&heap, &.{ try K.k(tc, "user/email"), try K.k(tc, "tag/b") }), &dispatch.hashValue, &dispatch.equal);
    _ = try transact(tc.conn, arena, try vector_mod.fromSlice(&heap, &.{m3}), .{});
    try testing.expectEqual(@as(usize, 2), (try (try tc.conn.db()).datoms(arena, .eavt, .{ .e = ann, .a = tags })).len);
}

/// Install `:user/nick` (string, indexed) and `:user/spouse` (ref,
/// unique identity) beside `installSchema`'s attributes.
fn installIdentitySchema(tc: *TestConn, arena: Allocator) !void {
    _ = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "nick" } }, .a = .{ .id = boot.ident }, .v = .{ .keyword = try kw(tc, "user/nick") } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "nick" } }, .a = .{ .id = boot.value_type }, .v = .{ .val = .{ .keyword = boot.type_string } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "nick" } }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_one } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "nick" } }, .a = .{ .id = boot.index }, .v = .{ .val = .{ .boolean = true } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "spouse" } }, .a = .{ .id = boot.ident }, .v = .{ .keyword = try kw(tc, "user/spouse") } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "spouse" } }, .a = .{ .id = boot.value_type }, .v = .{ .val = .{ .keyword = boot.type_ref } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "spouse" } }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_one } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "spouse" } }, .a = .{ .id = boot.unique }, .v = .{ .val = .{ .keyword = boot.unique_identity } } } },
    }, .{});
}

test "an indexed attribute becomes unique while a value moves between entities" {
    const tc = try TestConn.init("tx_unique_move");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    try installIdentitySchema(tc, arena);
    const email = try attrId(tc, "user/email");
    const nick = try attrId(tc, "user/nick");

    const r1 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "a@x" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = nick }, .v = .{ .val = .{ .string = "N" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "b" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "b@x" } } } },
    }, .{});
    const a = r1.tempids[0].eid;
    const b = r1.tempids[1].eid;

    // Without the retraction, two entities would hold "N": refused.
    try testing.expectError(error.Unique, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = b }, .a = .{ .id = nick }, .v = .{ .val = .{ .string = "N" } } } },
        .{ .add = .{ .e = .{ .eid = nick }, .a = .{ .id = boot.unique }, .v = .{ .val = .{ .keyword = boot.unique_identity } } } },
    }, .{}));
    // The value moves from a to b in the transaction that makes the
    // attribute unique: after it, exactly one entity holds "N".
    const r2 = try transactOps(tc.conn, arena, &.{
        .{ .retract = .{ .e = .{ .eid = a }, .a = .{ .id = nick }, .v = .{ .val = .{ .string = "N" } } } },
        .{ .add = .{ .e = .{ .eid = b }, .a = .{ .id = nick }, .v = .{ .val = .{ .string = "N" } } } },
        .{ .add = .{ .e = .{ .eid = nick }, .a = .{ .id = boot.unique }, .v = .{ .val = .{ .keyword = boot.unique_identity } } } },
    }, .{});
    try testing.expectEqual(@as(usize, 4), r2.tx_data.len);
    const db = try tc.conn.db();
    try testing.expectEqual(schema_mod.Unique.identity, (try db.attr(nick)).?.unique);
    try testing.expectEqual(@as(?u64, b), try db.entid(arena, .{ .lookup = .{ .a = nick, .v = .{ .string = "N" } } }));
    try testing.expectEqual(@as(usize, 1), (try db.datoms(arena, .aevt, .{ .a = nick })).len);
}

test "identity claims whose value is a lookup ref or a tempid upsert" {
    const tc = try TestConn.init("tx_identity_ref");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    try installIdentitySchema(tc, arena);
    const email = try attrId(tc, "user/email");
    const name = try attrId(tc, "user/name");
    const age = try attrId(tc, "user/age");
    const spouse = try attrId(tc, "user/spouse");

    const r1 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "a@x" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "h" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "h@x" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = spouse }, .v = .{ .entity = .{ .tempid = .{ .string = "h" } } } } },
    }, .{});
    const a = r1.tempids[0].eid;
    const h = r1.tempids[1].eid;

    // The claim's value is a lookup ref: x is a.
    const r2 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "x" } }, .a = .{ .id = spouse }, .v = .{ .entity = .{ .lookup = .{ .a = .{ .id = email }, .v = .{ .string = "h@x" } } } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "x" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Ann" } } } },
    }, .{});
    try testing.expectEqual(a, r2.tempids[0].eid);
    try testing.expectEqual(@as(usize, 2), r2.tx_data.len);
    for (r2.tx_data) |d| try testing.expect(d.a != spouse);

    // The claim's value is a tempid that itself upserts: x is a, hh is h.
    const r3 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "x" } }, .a = .{ .id = spouse }, .v = .{ .entity = .{ .tempid = .{ .string = "hh" } } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "x" } }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 3 } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "hh" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "h@x" } } } },
    }, .{});
    try testing.expectEqual(a, r3.tempids[0].eid);
    try testing.expectEqual(h, r3.tempids[1].eid);
    try testing.expectEqual(@as(usize, 2), r3.tx_data.len);

    // Two tempids claiming one new entity as spouse are one entity.
    const r4 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "p" } }, .a = .{ .id = spouse }, .v = .{ .entity = .{ .tempid = .{ .string = "n" } } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "q" } }, .a = .{ .id = spouse }, .v = .{ .entity = .{ .tempid = .{ .string = "n" } } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "q" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Q" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "n" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "n@x" } } } },
    }, .{});
    // Tempids are listed in order of first mention: p, n, q.
    try testing.expectEqual(r4.tempids[0].eid, r4.tempids[2].eid);
    try testing.expect(r4.tempids[1].eid != r4.tempids[0].eid);
    try testing.expect(r4.tempids[1].eid != a and r4.tempids[1].eid != h);
    try testing.expectEqual(@as(usize, 4), r4.tx_data.len);

    // A claim through a lookup ref on a new entity's identity, asserted
    // later in the same transaction: y and m are fresh, y's spouse is m.
    const r5 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "y" } }, .a = .{ .id = spouse }, .v = .{ .entity = .{ .lookup = .{ .a = .{ .id = email }, .v = .{ .string = "m@x" } } } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "y" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Y" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "m" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "m@x" } } } },
    }, .{});
    const y = r5.tempids[0].eid;
    const m = r5.tempids[1].eid;
    try testing.expect(y != m and y > h and m > h);
    try testing.expectEqual(@as(usize, 4), r5.tx_data.len);
    try testing.expectEqual(@as(?u64, y), try (try tc.conn.db()).entid(arena, .{ .lookup = .{ .a = spouse, .v = .{ .ref = m } } }));
}

test "a large transaction's arena stays well under a kilobyte per datom" {
    const tc = try TestConn.init("tx_arena_per_datom");
    defer tc.deinit();
    var setup = std.heap.ArenaAllocator.init(testing.allocator);
    defer setup.deinit();
    try installSchema(tc, setup.allocator());
    const email = try attrId(tc, "user/email");
    const name = try attrId(tc, "user/name");
    const age = try attrId(tc, "user/age");
    const bio = try attrId(tc, "user/bio");
    const home = try attrId(tc, "user/home");

    // The ops live in their own arena; the transaction's arena holds
    // only what the transaction allocates.
    const entities = 20_000;
    const per_entity = 5;
    const ops = try setup.allocator().alloc(Op, entities * per_entity);
    for (0..entities) |i| {
        const id: TempidKey = .{ .fixnum = -@as(i64, @intCast(i + 1)) };
        const em = try setup.allocator().print("user{d}@example.com", .{i});
        const nm = try setup.allocator().print("User Number {d}", .{i});
        ops[i * per_entity + 0] = .{ .add = .{ .e = .{ .tempid = id }, .a = .{ .id = email }, .v = .{ .val = .{ .string = em } } } };
        ops[i * per_entity + 1] = .{ .add = .{ .e = .{ .tempid = id }, .a = .{ .id = name }, .v = .{ .val = .{ .string = nm } } } };
        ops[i * per_entity + 2] = .{ .add = .{ .e = .{ .tempid = id }, .a = .{ .id = age }, .v = .{ .val = .{ .long = @intCast(i % 90) } } } };
        ops[i * per_entity + 3] = .{ .add = .{ .e = .{ .tempid = id }, .a = .{ .id = bio }, .v = .{ .val = .{ .string = "A short biography that fits inline in the key." } } } };
        ops[i * per_entity + 4] = .{ .add = .{ .e = .{ .tempid = id }, .a = .{ .id = home }, .v = .{ .entity = .{ .tempid = .{ .fixnum = -@as(i64, @intCast((i % entities) + 1)) } } } } };
    }

    var tx_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer tx_arena.deinit();
    const r = try transactOps(tc.conn, tx_arena.allocator(), ops, .{});
    try testing.expectEqual(@as(usize, entities * per_entity + 1), r.tx_data.len);
    try testing.expect(tx_arena.queryCapacity() / r.tx_data.len < 1024);
}

test "history composed with since shows only the rows after since" {
    const tc = try TestConn.init("tx_history_since");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const name = try attrId(tc, "user/name");

    const r1 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Ann" } } } },
    }, .{});
    const a = r1.tempids[0].eid;
    const r2 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Anne" } } } },
    }, .{});
    const db = try tc.conn.db();
    // History alone: the assertion, its retraction and the new value.
    try testing.expectEqual(@as(usize, 3), (try db.withHistory().datoms(arena, .eavt, .{ .e = a })).len);
    // History since r1: the two rows of r2, whichever way it is composed.
    for ([_]DbValue{ db.sinceT(r1.t).withHistory(), db.withHistory().sinceT(r1.t) }) |view| {
        const rows = try view.datoms(arena, .eavt, .{ .e = a });
        try testing.expectEqual(@as(usize, 2), rows.len);
        for (rows) |d| try testing.expectEqual(r2.t, d.t);
        try testing.expect(!rows[0].added and rows[1].added);
    }
    // Since r2 there is nothing; since 0 there is everything.
    try testing.expectEqual(@as(usize, 0), (try db.sinceT(r2.t).withHistory().datoms(arena, .eavt, .{ .e = a })).len);
    try testing.expectEqual(@as(usize, 3), (try db.sinceT(0).withHistory().datoms(arena, .eavt, .{ .e = a })).len);
    // As-of composes on top: history since r1 as of r1 is empty.
    try testing.expectEqual(@as(usize, 0), (try db.sinceT(r1.t).withHistory().asOf(r1.t).datoms(arena, .eavt, .{ .e = a })).len);
}

test "two card-one values in one transaction conflict even when the first is current" {
    const tc = try TestConn.init("tx_card_one_current");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const age = try attrId(tc, "user/age");

    const r1 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 30 } } } },
    }, .{});
    const a = r1.tempids[0].eid;
    try testing.expectError(error.Conflict, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 30 } } } },
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 31 } } } },
    }, .{}));
    // Re-asserting the current value twice writes nothing.
    const r2 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 30 } } } },
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 30 } } } },
    }, .{});
    try testing.expectEqual(@as(usize, 1), r2.tx_data.len);
    try testing.expectEqual(@as(i64, 30), (try (try tc.conn.db()).entity(arena, a))[0].vals[0].long);
}

test "a bare retract and an add under one attribute commute; a re-asserted datom conflicts with its retraction" {
    const tc = try TestConn.init("tx_retract_order");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const name = try attrId(tc, "user/name");
    const age = try attrId(tc, "user/age");
    const tags = try attrId(tc, "user/tags");
    const red = try kw(tc, "tag/red");
    const blue = try kw(tc, "tag/blue");

    const r1 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Ann" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 30 } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = tags }, .v = .{ .keyword = red } } },
    }, .{});
    const a = r1.tempids[0].eid;
    var red_id: u32 = 0;
    for (r1.tx_data) |d| if (d.a == tags) {
        red_id = d.v.keyword;
    };

    // The add stands whichever form comes first: the bare retract
    // expands against the committed value.
    const r2 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 9 } } } },
        .{ .retract_attr = .{ .e = .{ .eid = a }, .a = .{ .id = age } } },
    }, .{});
    try testing.expectEqual(@as(usize, 3), r2.tx_data.len);
    var ages = try (try tc.conn.db()).datoms(arena, .eavt, .{ .e = a, .a = age });
    try testing.expectEqual(@as(usize, 1), ages.len);
    try testing.expectEqual(@as(i64, 9), ages[0].v.long);
    const r3 = try transactOps(tc.conn, arena, &.{
        .{ .retract_attr = .{ .e = .{ .eid = a }, .a = .{ .id = age } } },
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 10 } } } },
    }, .{});
    try testing.expectEqual(@as(usize, 3), r3.tx_data.len);
    ages = try (try tc.conn.db()).datoms(arena, .eavt, .{ .e = a, .a = age });
    try testing.expectEqual(@as(usize, 1), ages.len);
    try testing.expectEqual(@as(i64, 10), ages[0].v.long);

    // Card-many: the committed tag goes, the asserted one stays.
    _ = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = tags }, .v = .{ .keyword = blue } } },
        .{ .retract_attr = .{ .e = .{ .eid = a }, .a = .{ .id = tags } } },
    }, .{});
    var tag_rows = try (try tc.conn.db()).datoms(arena, .eavt, .{ .e = a, .a = tags });
    try testing.expectEqual(@as(usize, 1), tag_rows.len);
    try testing.expect(tag_rows[0].v.keyword != red_id);
    _ = try transactOps(tc.conn, arena, &.{
        .{ .retract_attr = .{ .e = .{ .eid = a }, .a = .{ .id = tags } } },
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = tags }, .v = .{ .keyword = red } } },
    }, .{});
    tag_rows = try (try tc.conn.db()).datoms(arena, .eavt, .{ .e = a, .a = tags });
    try testing.expectEqual(@as(usize, 1), tag_rows.len);
    try testing.expectEqual(red_id, tag_rows[0].v.keyword);

    // Re-asserting a current datom and retracting it in one transaction
    // is the assertion-and-retraction conflict, in either order and
    // under every retraction form.
    const add_age: Op = .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 10 } } } };
    const bare: Op = .{ .retract_attr = .{ .e = .{ .eid = a }, .a = .{ .id = age } } };
    const exact: Op = .{ .retract = .{ .e = .{ .eid = a }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 10 } } } };
    const add_name: Op = .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Ann" } } } };
    const whole: Op = .{ .retract_entity = .{ .eid = a } };
    try testing.expectError(error.Conflict, transactOps(tc.conn, arena, &.{ add_age, bare }, .{}));
    try testing.expectError(error.Conflict, transactOps(tc.conn, arena, &.{ bare, add_age }, .{}));
    try testing.expectError(error.Conflict, transactOps(tc.conn, arena, &.{ add_age, exact }, .{}));
    try testing.expectError(error.Conflict, transactOps(tc.conn, arena, &.{ exact, add_age }, .{}));
    try testing.expectError(error.Conflict, transactOps(tc.conn, arena, &.{ add_name, whole }, .{}));
    try testing.expectError(error.Conflict, transactOps(tc.conn, arena, &.{ whole, add_name }, .{}));

    // retractEntity and an add of a fresh value commute: the entity
    // keeps the added datom alone.
    _ = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Bea" } } } },
        whole,
    }, .{});
    var rows = try (try tc.conn.db()).datoms(arena, .eavt, .{ .e = a });
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("Bea", rows[0].v.string);
    _ = try transactOps(tc.conn, arena, &.{
        whole,
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Cy" } } } },
    }, .{});
    rows = try (try tc.conn.db()).datoms(arena, .eavt, .{ .e = a });
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("Cy", rows[0].v.string);
}

test "an explicit :db/txInstant on the transaction entity stands" {
    const tc = try TestConn.init("tx_explicit_instant");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const name = try attrId(tc, "user/name");

    const later = store_mod.nowMillis() + 3_600_000;
    const r = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .tx, .a = .{ .id = boot.tx_instant }, .v = .{ .val = .{ .instant = later } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Ann" } } } },
    }, .{ .now_ms = later + 777 });
    try testing.expectEqual(@as(usize, 2), r.tx_data.len);
    var instants: usize = 0;
    for (r.tx_data) |d| if (d.a == boot.tx_instant) {
        instants += 1;
        try testing.expectEqual(later, d.v.instant);
    };
    try testing.expectEqual(@as(usize, 1), instants);
    const db = try tc.conn.db();
    try testing.expectEqual(later, (try db.entity(arena, key.txEntity(r.t)))[0].vals[0].instant);
    const entries = try db_mod.txRange(tc.conn, arena, r.t, null);
    try testing.expectEqual(later, entries[0].instant);
    // Instants never go back: an explicit one earlier than the last is
    // refused, a clock behind it takes the last one.
    try testing.expectError(error.TxData, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .tx, .a = .{ .id = boot.tx_instant }, .v = .{ .val = .{ .instant = later - 1 } } } },
    }, .{}));
    const behind = try transactOps(tc.conn, arena, &.{}, .{ .now_ms = 5 });
    try testing.expectEqual(later, behind.tx_data[0].v.instant);
    // Only the transaction's own entity takes an instant, and nothing
    // retracts one.
    try testing.expectError(error.TxData, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = key.txEntity(r.t) }, .a = .{ .id = boot.tx_instant }, .v = .{ .val = .{ .instant = later + 1 } } } },
    }, .{}));
    try testing.expectError(error.TxData, transactOps(tc.conn, arena, &.{
        .{ .retract_attr = .{ .e = .{ .eid = key.txEntity(r.t) }, .a = .{ .id = boot.tx_instant } } },
    }, .{}));
    // Two different instants for one transaction conflict.
    try testing.expectError(error.Conflict, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .tx, .a = .{ .id = boot.tx_instant }, .v = .{ .val = .{ .instant = 1 } } } },
        .{ .add = .{ .e = .tx, .a = .{ .id = boot.tx_instant }, .v = .{ .val = .{ .instant = 2 } } } },
    }, .{}));
}

test "a tempid must be the entity of some datom; a retraction mints no keyword" {
    const tc = try TestConn.init("tx_tempid_value");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var heap = nx.heap.Heap.init(arena);
    defer heap.deinit();
    const l = Lisp{ .tc = tc, .heap = &heap };
    try installSchema(tc, arena);
    const name = try attrId(tc, "user/name");
    const friend = try attrId(tc, "user/friend");
    const tags = try attrId(tc, "user/tags");
    var fault: Fault = .{};

    // A tempid only in a value position would be a dangling ref.
    try testing.expectError(error.TxData, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = friend }, .v = .{ .entity = .{ .tempid = .{ .string = "ghost" } } } } },
    }, .{ .fault = &fault }));
    try testing.expect(fault.message != null);
    try testing.expectError(error.TxData, transact(tc.conn, arena, try l.vec(&.{try l.map(&.{.{ "db/id", try l.str("lonely") }})}), .{}));
    try testing.expectError(error.TxData, transact(tc.conn, arena, try l.vec(&.{try l.map(&.{})}), .{}));
    // As a value and as an entity, it is one new entity.
    const r = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = friend }, .v = .{ .entity = .{ .tempid = .{ .string = "b" } } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "b" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "B" } } } },
    }, .{});
    try testing.expectEqual(@as(usize, 2), r.tempids.len);

    // Retracting a keyword the store has never seen retracts nothing and
    // mints no ident id.
    const aid = blk: {
        const txn = try tc.conn.store.beginRead();
        defer txn.abort();
        break :blk try tc.conn.store.readNextAid(txn);
    };
    const a = r.tempids[0].eid;
    const gone = try transactOps(tc.conn, arena, &.{
        .{ .retract = .{ .e = .{ .eid = a }, .a = .{ .id = tags }, .v = .{ .keyword = try kw(tc, "brand/new") } } },
    }, .{});
    try testing.expectEqual(@as(usize, 1), gone.tx_data.len);
    try testing.expectError(error.NoEntity, transact(tc.conn, arena, try l.vec(&.{try l.vec(&.{
        try l.kw("db/retract"), try l.vec(&.{ try l.kw("db/ident"), try l.kw("brand/newer") }), try l.kw("user/name"), try l.str("x"),
    })}), .{}));
    const txn = try tc.conn.store.beginRead();
    defer txn.abort();
    try testing.expectEqual(aid, try tc.conn.store.readNextAid(txn));
}

test "two identities naming two entities for one tempid conflict, naming the datom" {
    const tc = try TestConn.init("tx_identity_conflict");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const email = try attrId(tc, "user/email");
    _ = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "a@x" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "b" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "b@x" } } } },
    }, .{});
    var fault: Fault = .{};
    try testing.expectError(error.Conflict, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "t" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "a@x" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "t" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "b@x" } } } },
    }, .{ .fault = &fault }));
    try testing.expect(fault.e != null);
    try testing.expectEqual(try kw(tc, "user/email"), fault.attr.?.asKeywordId());
}

const engineSyncs = store_mod.db_layer.engineSyncs;

test "durability: a transaction syncs only when it or its connection asks; sync and release sync what is left once" {
    const tc = try TestConn.init("tx_durability");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const file = tc.conn.store.file;

    // TestConn's connection commits without a sync; the store's
    // bootstrap was its first commit.
    var before = engineSyncs();
    try installSchema(tc, arena);
    try testing.expectEqual(before, engineSyncs());
    try testing.expect(file.unsynced);
    const name = try attrId(tc, "user/name");
    const add: []const Op = &.{.{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "A" } } } }};

    // Another connection sees the commit at once. One whose commits sync
    // makes every commit before it durable.
    const other = try Conn.open(testing.allocator, &tc.interner, tc.td.path.ptr, .{ .sync = .full });
    defer other.destroy();
    try testing.expectEqual(@as(u64, 2), (try other.db()).basis);
    _ = try transactOps(other, arena, add, .{});
    try testing.expect(engineSyncs() > before);
    try testing.expect(!file.unsynced);

    // A transaction's own :sync overrides its connection's, either way.
    before = engineSyncs();
    _ = try transactOps(other, arena, add, .{ .sync = .none });
    try testing.expectEqual(before, engineSyncs());
    try testing.expect(file.unsynced);
    _ = try transactOps(tc.conn, arena, add, .{ .sync = .full });
    try testing.expect(engineSyncs() > before);
    try testing.expect(!file.unsynced);

    // sync is one full sync of what is unsynced, and nothing when all is.
    _ = try transactOps(tc.conn, arena, add, .{});
    before = engineSyncs();
    try tc.conn.sync();
    try testing.expectEqual(before + 1, engineSyncs());
    try tc.conn.sync();
    try testing.expectEqual(before + 1, engineSyncs());

    // release syncs, though another connection still holds the file.
    _ = try transactOps(tc.conn, arena, add, .{});
    try other.release();
    try testing.expectEqual(before + 2, engineSyncs());
    try testing.expect(!file.unsynced);
}

/// Makes the meta sync of the next commit fail: once the meta page is
/// written, the data file's descriptor names a pipe, which cannot sync.
const MetaSyncFailure = struct {
    fd: std.c.fd_t,
    saved: std.c.fd_t = -1,
    pipe: [2]std.c.fd_t = undefined,

    fn notify(ctx: *anyopaque, step: emdb.CommitStep) void {
        const self: *MetaSyncFailure = @ptrCast(@alignCast(ctx));
        if (step != .metaWritten) return;
        self.saved = std.c.dup(self.fd);
        _ = std.c.dup2(self.pipe[0], self.fd);
    }

    fn restore(self: *MetaSyncFailure) void {
        _ = std.c.dup2(self.saved, self.fd);
        for ([_]std.c.fd_t{ self.saved, self.pipe[0], self.pipe[1] }) |fd| _ = std.c.close(fd);
    }
};

test "durability: a commit whose meta sync fails stands and reaches the caches; the file then syncs nothing until it is reopened" {
    const tc = try TestConn.init("tx_meta_sync");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const name = try attrId(tc, "user/name");
    const add: []const Op = &.{.{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "A" } } } }};
    const before = try tc.conn.db();
    try testing.expectEqual(@as(u64, 0), (try before.attr(name)).?.count);

    const env = &tc.conn.store.file.env.inner;
    var failure = MetaSyncFailure{ .fd = env.dataFile.fd };
    try testing.expectEqual(@as(c_int, 0), std.c.pipe(&failure.pipe));
    env.commitObserver = .{ .ctx = &failure, .notify = MetaSyncFailure.notify };
    const committed = transactOps(tc.conn, arena, add, .{ .sync = .full });
    env.commitObserver = null;
    failure.restore();
    try testing.expectError(error.DurabilityUnknown, committed);
    try testing.expect(tc.conn.store.file.unsynced);

    // The commit stands, the cached count includes it, and the
    // connection takes the next transaction.
    const after = try tc.conn.db();
    try testing.expectEqual(before.basis + 1, after.basis);
    try testing.expectEqual(@as(u64, 1), (try after.attr(name)).?.count);
    const r = try transactOps(tc.conn, arena, add, .{});
    try testing.expectEqual(@as(u64, 2), (try (try tc.conn.db()).attr(name)).?.count);

    // No sync is issued again (emdb INV-SYNC-04): `sync` fails, and a
    // transaction or excision that would sync fails before it writes
    // anything, the caches untouched, while one that syncs nothing
    // commits.
    const syncs = engineSyncs();
    try testing.expectError(error.SyncFailed, tc.conn.sync());
    try testing.expectError(error.SyncFailed, transactOps(tc.conn, arena, add, .{ .sync = .full }));
    try testing.expectError(error.SyncFailed, transactOps(tc.conn, arena, add, .{ .sync = .no_meta }));
    const e = value.fromFixnum(@intCast(r.tempids[0].eid)).?;
    try testing.expectError(error.SyncFailed, excise(tc.conn, arena, e, null, .{ .sync = .full }));
    const kept = try tc.conn.db();
    try testing.expectEqual(r.t, kept.basis);
    try testing.expectEqual(@as(u64, 2), (try kept.attr(name)).?.count);
    const x = try excise(tc.conn, arena, e, null, .{});
    try testing.expectEqual(r.t + 1, x.report.t);
    try testing.expectEqual(@as(u64, 1), (try (try tc.conn.db()).attr(name)).?.count);

    // release syncs nothing and raises nothing; reopened, the file
    // syncs again and holds exactly the commits that published.
    try tc.conn.release();
    try testing.expectEqual(syncs, engineSyncs());
    try tc.reopen();
    const reopened = try tc.conn.db();
    try testing.expectEqual(x.report.t, reopened.basis);
    try testing.expectEqual(@as(u64, 1), (try reopened.attr(name)).?.count);
    _ = try transactOps(tc.conn, arena, add, .{ .sync = .full });
    try testing.expect(engineSyncs() > syncs);
    try tc.conn.sync();
}

test "durability: a connection opened without :sync takes the process's (NEXIS_DURABILITY)" {
    const tc = try TestConn.init("tx_durability_default");
    defer tc.deinit();
    const conn = try Conn.open(testing.allocator, &tc.interner, tc.td.path.ptr, .{});
    defer conn.destroy();
    try testing.expectEqual(SyncMode.of(store_mod.db_layer.Durability.process()), conn.sync_mode);
}

test "reads share the file's held snapshot until a commit passes it; a with view's reads are never kept" {
    const tc = try TestConn.init("tx_held");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const name = try attrId(tc, "user/name");
    const file = tc.conn.store.file;
    const other = try Conn.open(testing.allocator, &tc.interner, tc.td.path.ptr, .{ .sync = .none });
    defer other.destroy();

    const db2 = try tc.conn.db();
    const held = file.held.?;
    // Another connection to the file reads through the same snapshot.
    try testing.expectEqual(db2.basis, (try other.db()).basis);
    try testing.expectEqual(held, file.held.?);
    // Nested reads: the outer holds the snapshot, the inner begins its own.
    var outer = try db2.beginRead();
    try testing.expect(file.held == null);
    try testing.expectEqual(held, outer.txn);
    var inner = try db2.beginRead();
    try testing.expect(inner.txn != held);
    inner.close();
    try testing.expect(file.held != null);
    outer.close();

    // A transaction on either connection lets it go, and the next read
    // sees its commit.
    const r = try transactOps(other, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "A" } } } },
    }, .{});
    try testing.expectEqual(r.t, (try tc.conn.db()).basis);
    const e = r.tempids[0].eid;
    try testing.expectEqual(@as(usize, 1), (try (try tc.conn.db()).datoms(arena, .eavt, .{ .e = e })).len);

    // The view of a with reads children of its write transaction; the
    // write let the snapshot go and the view keeps none.
    const w = try withOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = e }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "B" } } } },
    }, .{});
    try testing.expect(file.held == null);
    try testing.expectEqual(r.t + 1, w.db().basis);
    try testing.expectEqual(@as(usize, 1), (try w.db().datoms(arena, .eavt, .{ .e = e })).len);
    try testing.expect(file.held == null);
    w.finish();
    try testing.expectEqual(r.t, (try tc.conn.db()).basis);
}

test "another connection's data commits keep the schema cache; its schema changes rebuild it" {
    const tc = try TestConn.init("tx_schema_gen");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const name = try attrId(tc, "user/name");
    const other = try Conn.open(testing.allocator, &tc.interner, tc.td.path.ptr, .{ .sync = .none });
    defer other.destroy();

    _ = try (try tc.conn.db()).attr(name);
    const cached = tc.conn.schema_cache.?;
    _ = try transactOps(other, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "A" } } } },
    }, .{});
    const db = try tc.conn.db();
    try testing.expect((try db.attr(name)) != null);
    try testing.expectEqual(cached, tc.conn.schema_cache.?);
    try testing.expectEqual(db.basis, cached.basis);

    _ = try transactOps(other, arena, &.{
        .{ .add = .{ .e = .{ .eid = name }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_many } } } },
    }, .{});
    try testing.expect((try (try tc.conn.db()).attr(name)).?.many());
}

test "a schema change that leaves the generation alone still rebuilds the cache" {
    const tc = try TestConn.init("tx_schema_gen_old_build");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const name = try attrId(tc, "user/name");
    const other = try Conn.open(testing.allocator, &tc.interner, tc.td.path.ptr, .{ .sync = .none });
    defer other.destroy();

    try testing.expect(!(try (try tc.conn.db()).attr(name)).?.many());
    const store = other.store;
    const gen = blk: {
        const txn = try store.beginRead();
        defer txn.abort();
        break :blk try store.readSchemaGen(txn);
    };
    // A data commit, then the schema change, then "sg" put back.
    _ = try transactOps(other, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "A" } } } },
    }, .{});
    _ = try transactOps(other, arena, &.{
        .{ .add = .{ .e = .{ .eid = name }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_many } } } },
    }, .{});
    {
        const txn = try store.beginWrite(.none);
        errdefer txn.abort();
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, gen, .big);
        try store.sysPut(txn, "sg", &bytes);
        try txn.commit();
    }
    try testing.expect((try (try tc.conn.db()).attr(name)).?.many());
    // Data-only commits since keep the rebuilt cache.
    const cached = tc.conn.schema_cache.?;
    _ = try transactOps(other, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "b" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "B" } } } },
    }, .{});
    _ = try (try tc.conn.db()).attr(name);
    try testing.expectEqual(cached, tc.conn.schema_cache.?);
}

test "the view outlives the scratch arena; the next with reuses it, and an escaped db-value stays closed" {
    const tc = try TestConn.init("tx_with_view_lifetime");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const name = try attrId(tc, "user/name");

    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    const w = try withOps(tc.conn, scratch.allocator(), &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Ann" } } } },
    }, .{});
    const escaped = w.db();
    const a = w.report.tempids[0].eid;
    try testing.expectEqual(@as(usize, 1), (try escaped.entity(arena, a)).len);
    w.finish();
    // The scratch arena, and the `With` in it, are gone; the view is
    // not: an escaped db-value answers Closed rather than reading freed
    // memory, and the connection is free again.
    scratch.deinit();
    try testing.expectError(error.Closed, escaped.entity(arena, a));
    try testing.expect(tc.conn.speculative == null);
    try testing.expectEqual(@as(usize, 0), (try (try tc.conn.db()).entity(arena, a)).len);

    // Every with of the connection reads through the one view; the
    // earlier scope's db-value names an earlier life of it, so it stays
    // closed while the next scope reads.
    const w2 = try withOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "b" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Bea" } } } },
    }, .{});
    defer w2.finish();
    try testing.expectEqual(escaped.conn, w2.view);
    try testing.expectError(error.Closed, escaped.entity(arena, a));
    try testing.expectEqual(@as(usize, 1), (try w2.db().entity(arena, w2.report.tempids[0].eid)).len);
}

test "a held with keeps the store open until finish; a closed connection refuses writes" {
    const tc = try TestConn.init("tx_busy_with");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const name = try attrId(tc, "user/name");

    const w = try withOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Ann" } } } },
    }, .{});
    defer w.finish();
    const a = w.report.tempids[0].eid;
    try testing.expectError(error.Busy, tc.conn.release());
    tc.conn.close();
    try testing.expect(!tc.conn.is_open and tc.conn.close_pending and !tc.conn.store_closed);
    // The view still reads the speculative state.
    try testing.expectEqual(@as(usize, 1), (try w.db().entity(arena, a)).len);
    w.finish();
    try testing.expect(tc.conn.store_closed);
    try testing.expectError(error.Closed, w.db().entity(arena, a));
    try testing.expectError(error.Closed, transactOps(tc.conn, arena, &.{}, .{}));
    try testing.expectError(error.Closed, withOps(tc.conn, arena, &.{}, .{}));
}

test "an ident rename retires the old name; cardinality changes under the data's rule" {
    const tc = try TestConn.init("tx_alter");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const name = try attrId(tc, "user/name");
    const email = try attrId(tc, "user/email");
    const tags = try attrId(tc, "user/tags");
    var fault: Fault = .{};

    const r1 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Ann" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = tags }, .v = .{ .keyword = try kw(tc, "tag/x") } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = tags }, .v = .{ .keyword = try kw(tc, "tag/y") } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "b" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Bob" } } } },
    }, .{});
    const a = r1.tempids[0].eid;
    const b = r1.tempids[1].eid;

    // Rename: no datom, the new keyword resolves, the old is retired.
    const k_full = try kw(tc, "user/full-name");
    const r2 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = name }, .a = .{ .id = boot.ident }, .v = .{ .keyword = k_full } } },
    }, .{});
    try testing.expectEqual(@as(usize, 1), r2.tx_data.len);
    const db2 = try tc.conn.db();
    try testing.expectEqual(@as(?u64, name), try db2.entid(arena, .{ .ident = k_full }));
    try testing.expect((try db2.entid(arena, .{ .ident = try kw(tc, "user/name") })) == null);
    try testing.expectEqual(@as(?u32, k_full), try db2.ident(arena, name));
    try testing.expectEqual(@as(?u32, k_full), try db2.asOf(r1.t).ident(arena, name));
    try testing.expectError(error.UnknownAttribute, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .ident = try kw(tc, "user/name") }, .v = .{ .val = .{ .string = "x" } } } },
    }, .{}));
    // The retired name is never minted again, as an attribute or a value.
    try testing.expectError(error.TxData, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "n" } }, .a = .{ .id = boot.ident }, .v = .{ .keyword = try kw(tc, "user/name") } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "n" } }, .a = .{ .id = boot.value_type }, .v = .{ .val = .{ .keyword = boot.type_string } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "n" } }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_one } } } },
    }, .{}));
    try testing.expectError(error.TxData, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = tags }, .v = .{ .keyword = try kw(tc, "user/name") } } },
    }, .{}));
    // A keyword naming another entity conflicts; the entity's own ident is a no-op.
    try testing.expectError(error.Conflict, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = name }, .a = .{ .id = boot.ident }, .v = .{ .keyword = try kw(tc, "user/email") } } },
    }, .{}));
    const r3 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = name }, .a = .{ .id = boot.ident }, .v = .{ .keyword = k_full } } },
    }, .{});
    try testing.expectEqual(@as(usize, 1), r3.tx_data.len);
    // The txlog still decodes the entry written under the old name.
    const entries = try db_mod.txRange(tc.conn, arena, 2, 3);
    try testing.expectEqual(@as(usize, 1), entries.len);
    var saw_name = false;
    for (entries[0].datoms) |d| {
        if (d.a == boot.ident and d.v.keyword == name) saw_name = true;
    }
    try testing.expect(saw_name);
    // A second connection sees the rename through the generation.
    {
        const other = try Conn.open(testing.allocator, &tc.interner, tc.td.path.ptr, .{ .sync = .none });
        defer other.destroy();
        const odb = try other.db();
        try testing.expectEqual(@as(?u64, name), try odb.entid(arena, .{ .ident = k_full }));
        try testing.expect((try odb.entid(arena, .{ .ident = try kw(tc, "user/name") })) == null);
        try testing.expectEqual(@as(?u32, k_full), try odb.ident(arena, name));
    }

    // Cardinality one → many: the attribute takes a second value; an
    // earlier basis still reads it as card-one.
    const r4 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = name }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_many } } } },
    }, .{});
    try testing.expectEqual(@as(usize, 3), r4.tx_data.len);
    const r5 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Annie" } } } },
    }, .{});
    try testing.expectEqual(@as(usize, 2), r5.tx_data.len);
    const db5 = try tc.conn.db();
    try testing.expect((try db5.attr(name)).?.many());
    try testing.expect(!(try db5.asOf(r1.t).attr(name)).?.many());
    try testing.expectEqual(@as(usize, 2), (try db5.entity(arena, a))[0].vals.len);
    try testing.expectEqual(@as(usize, 1), (try db5.asOf(r1.t).entity(arena, a))[0].vals.len);

    // Many → one is refused while `a` holds two values, naming it.
    try testing.expectError(error.Schema, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = name }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_one } } } },
    }, .{ .fault = &fault }));
    try testing.expectEqual(@as(?u64, a), fault.e);
    try testing.expectEqual(k_full, fault.attr.?.asKeywordId());
    // Retracting in the same transaction makes room; a second value asserted in it does not.
    try testing.expectError(error.Schema, transactOps(tc.conn, arena, &.{
        .{ .retract = .{ .e = .{ .eid = a }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Ann" } } } },
        .{ .add = .{ .e = .{ .eid = b }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Bobby" } } } },
        .{ .add = .{ .e = .{ .eid = name }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_one } } } },
    }, .{ .fault = &fault }));
    try testing.expectEqual(@as(?u64, b), fault.e);
    const r6 = try transactOps(tc.conn, arena, &.{
        .{ .retract = .{ .e = .{ .eid = a }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Ann" } } } },
        .{ .add = .{ .e = .{ .eid = name }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_one } } } },
    }, .{});
    const db6 = try tc.conn.db();
    try testing.expect(!(try db6.attr(name)).?.many());
    try testing.expect((try db6.asOf(r5.t).attr(name)).?.many());
    // The card-one rule applies from the next transaction on.
    const r7 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Anne" } } } },
    }, .{});
    try testing.expectEqual(@as(usize, 3), r7.tx_data.len);
    _ = r6;
    // A unique attribute stays card-one; a bare retraction of the cardinality is a conflict.
    try testing.expectError(error.Schema, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = email }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_many } } } },
    }, .{}));
    try testing.expectError(error.Conflict, transactOps(tc.conn, arena, &.{
        .{ .retract = .{ .e = .{ .eid = name }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_one } } } },
    }, .{}));
}

test "excision removes an entity's datoms from every view and rewrites the txlog" {
    const tc = try TestConn.init("tx_excise");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const email = try attrId(tc, "user/email");
    const name = try attrId(tc, "user/name");
    const friend = try attrId(tc, "user/friend");
    var fault: Fault = .{};

    const r1 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "a@x" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Ann" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "b" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Bob" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "b" } }, .a = .{ .id = friend }, .v = .{ .entity = .{ .tempid = .{ .string = "a" } } } } },
    }, .{});
    const a = r1.tempids[0].eid;
    const b = r1.tempids[1].eid;
    const r2 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Anne" } } } },
    }, .{});
    const before = try tc.conn.db();

    // One attribute: its rows go from every view, the rest stay.
    const x = try excise(tc.conn, arena, value.fromFixnum(@intCast(a)).?, value.fromFixnum(name).?, .{});
    try testing.expectEqual(r2.t + 1, x.report.t);
    try testing.expectEqual(a, x.excised);
    try testing.expectEqual(@as(u64, 3), x.removed);
    try testing.expectEqual(@as(usize, 1), x.report.tx_data.len);
    const db3 = try tc.conn.db();
    try testing.expectEqual(@as(usize, 1), (try db3.entity(arena, a)).len);
    try testing.expectEqual(email, (try db3.entity(arena, a))[0].a);
    try testing.expectEqual(@as(usize, 1), (try before.entity(arena, a)).len);
    try testing.expectEqual(@as(usize, 0), (try db3.withHistory().datoms(arena, .eavt, .{ .e = a, .a = name })).len);
    try testing.expectEqual(@as(usize, 0), (try db3.datoms(arena, .aevt, .{ .a = name, .e = a })).len);
    try testing.expectEqual(@as(usize, 1), (try db3.datoms(arena, .aevt, .{ .a = name })).len);
    try testing.expectEqual(@as(u64, 1), (try db3.attr(name)).?.count);
    // The txlog: the entries that held the datoms lost them and carry
    // the marker; the excising entry carries it too.
    const log = try db_mod.txRange(tc.conn, arena, r1.t, null);
    try testing.expectEqual(@as(usize, 3), log.len);
    try testing.expectEqualSlices(u64, &.{a}, log[0].excised);
    try testing.expectEqual(@as(usize, 4), log[0].datoms.len);
    try testing.expectEqualSlices(u64, &.{a}, log[1].excised);
    try testing.expectEqual(@as(usize, 1), log[1].datoms.len);
    try testing.expectEqual(boot.tx_instant, log[1].datoms[0].a);
    try testing.expectEqualSlices(u64, &.{a}, log[2].excised);
    for (log) |entry| for (entry.datoms) |d| try testing.expect(!(d.e == a and d.a == name));

    // The whole entity: gone everywhere; the ref to it from `b` stays.
    const y = try excise(tc.conn, arena, value.fromFixnum(@intCast(a)).?, null, .{});
    try testing.expectEqual(@as(u64, 1), y.removed);
    const db4 = try tc.conn.db();
    try testing.expectEqual(@as(usize, 0), (try db4.entity(arena, a)).len);
    try testing.expectEqual(@as(usize, 0), (try before.entity(arena, a)).len);
    try testing.expect((try db4.entid(arena, .{ .lookup = .{ .a = email, .v = .{ .string = "a@x" } } })) == null);
    try testing.expectEqual(@as(usize, 2), (try db4.entity(arena, b)).len);
    try testing.expectEqual(a, (try db4.entity(arena, b))[1].vals[0].ref);
    try testing.expectEqual(@as(usize, 1), (try db4.datoms(arena, .vaet, .{ .v = try key.valBytes(arena, .{ .ref = a }) })).len);
    const log2 = try db_mod.txRange(tc.conn, arena, r1.t, r1.t + 1);
    try testing.expectEqual(@as(usize, 3), log2[0].datoms.len);
    for (log2[0].datoms) |d| try testing.expect(d.e == b or d.e == key.txEntity(r1.t));
    // An excised entity is still addressable: excising it again removes nothing.
    const z = try excise(tc.conn, arena, value.fromFixnum(@intCast(a)).?, null, .{});
    try testing.expectEqual(@as(u64, 0), z.removed);

    // Refusals: an attribute or transaction entity, a tempid, an
    // unallocated id, an unknown attribute; nothing is recorded.
    const basis = (try tc.conn.db()).basis;
    try testing.expectError(error.TxData, excise(tc.conn, arena, value.fromFixnum(name).?, null, .{ .fault = &fault }));
    try testing.expectError(error.TxData, excise(tc.conn, arena, value.fromFixnum(@intCast(key.txEntity(r1.t))).?, null, .{}));
    var heap = nx.heap.Heap.init(arena);
    defer heap.deinit();
    try testing.expectError(error.TxData, excise(tc.conn, arena, try string_mod.fromBytes(&heap, "tmp"), null, .{}));
    try testing.expectError(error.NoEntity, excise(tc.conn, arena, value.fromFixnum(@intCast(key.user_partition_start + 99)).?, null, .{}));
    try testing.expectError(error.UnknownAttribute, excise(tc.conn, arena, value.fromFixnum(@intCast(b)).?, value.fromFixnum(9999).?, .{ .fault = &fault }));
    try testing.expectEqual(basis, (try tc.conn.db()).basis);
    // Inside a held `with`, excision is nested.
    const w = try withOps(tc.conn, arena, &.{}, .{});
    defer w.finish();
    try testing.expectError(error.Nested, excise(tc.conn, arena, value.fromFixnum(@intCast(b)).?, null, .{}));
}

/// `[:db.fn/cas e a old new]` as a VM value; `old` may be nil.
fn casForm(heap: *nx.heap.Heap, tc: *TestConn, e: Value, attr: []const u8, old: Value, new: Value) !Value {
    const it = &tc.interner;
    const form = try vector_mod.fromSlice(heap, &.{ try it.internKeywordValue("db.fn/cas"), e, try it.internKeywordValue(attr), old, new });
    return vector_mod.fromSlice(heap, &.{form});
}

test "cas asserts against the committed value and reports what it found" {
    const tc = try TestConn.init("tx_cas");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var heap = nx.heap.Heap.init(arena);
    defer heap.deinit();
    try installSchema(tc, arena);
    const age = try attrId(tc, "user/age");
    const name = try attrId(tc, "user/name");
    const r0 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Ann" } } } },
    }, .{});
    const a = r0.tempids[0].eid;
    const eid = value.fromFixnum(@intCast(a)).?;
    const nil = value.nilValue();
    const n = struct {
        fn n(x: i64) Value {
            return value.fromFixnum(x).?;
        }
    }.n;
    var fault: Fault = .{};

    // An absent attribute: nil expected succeeds, a value expected fails.
    const r1 = try transact(tc.conn, arena, try casForm(&heap, tc, eid, "user/age", nil, n(1)), .{});
    try testing.expectEqual(@as(usize, 2), r1.tx_data.len);
    try testing.expectEqual(@as(i64, 1), r1.tx_data[0].v.long);
    try testing.expectError(error.Cas, transact(tc.conn, arena, try casForm(&heap, tc, eid, "user/age", nil, n(2)), .{ .fault = &fault }));
    try testing.expect(fault.cas.?.expected == null);
    try testing.expectEqual(@as(i64, 1), fault.cas.?.actual.?.long);
    try testing.expectEqual(try kw(tc, "user/age"), fault.attr.?.asKeywordId());

    // The right expectation swaps; the wrong one names both values.
    const r2 = try transact(tc.conn, arena, try casForm(&heap, tc, eid, "user/age", n(1), n(2)), .{});
    try testing.expectEqual(@as(usize, 3), r2.tx_data.len);
    try testing.expect(!r2.tx_data[0].added and r2.tx_data[1].added);
    try testing.expectError(error.Cas, transact(tc.conn, arena, try casForm(&heap, tc, eid, "user/age", n(1), n(3)), .{ .fault = &fault }));
    try testing.expectEqual(@as(i64, 1), fault.cas.?.expected.?.long);
    try testing.expectEqual(@as(i64, 2), fault.cas.?.actual.?.long);

    // A retraction earlier in the transaction counts; card-many is refused.
    const retract = try vector_mod.fromSlice(&heap, &.{ try tc.interner.internKeywordValue("db/retract"), eid, try tc.interner.internKeywordValue("user/age"), n(2) });
    const both = try vector_mod.fromSlice(&heap, &.{ retract, vector_mod.nth(try casForm(&heap, tc, eid, "user/age", nil, n(9)), 0) });
    const r3 = try transact(tc.conn, arena, both, .{});
    try testing.expectEqual(@as(usize, 3), r3.tx_data.len);
    try testing.expectError(error.TxData, transact(tc.conn, arena, try casForm(&heap, tc, eid, "user/tags", nil, try tc.interner.internKeywordValue("tag/x")), .{}));
    const ent = try (try tc.conn.db()).entity(arena, a);
    try testing.expectEqual(age, ent[1].a);
    try testing.expectEqual(@as(i64, 9), ent[1].vals[0].long);
}

/// A transaction-function hook for the tests: `f` is a symbol naming
/// a behaviour, and the hook builds the tx-data the behaviour returns.
const TestTxHook = struct {
    tc: *TestConn,
    heap: *nx.heap.Heap,
    calls: usize = 0,
    /// The basis the last call saw.
    basis: u64 = 0,

    fn hook(self: *TestTxHook) CallHook {
        return .{ .ctx = @ptrCast(self), .call = &call };
    }

    fn call(ctx: *anyopaque, f: Value, db_before: DbValue, args: []const Value) anyerror!Value {
        const self: *TestTxHook = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.basis = db_before.basis;
        const heap = self.heap;
        const it = &self.tc.interner;
        const name = it.symbolName(f.asSymbolId());
        // Age of `args[0]` becomes `args[1]`.
        if (std.mem.eql(u8, name, "age!")) {
            const form = try vector_mod.fromSlice(heap, &.{ try it.internKeywordValue("db/add"), args[0], try it.internKeywordValue("user/age"), args[1] });
            return vector_mod.fromSlice(heap, &.{form});
        }
        // Calls `age!` through a nested call form.
        if (std.mem.eql(u8, name, "via")) {
            const form = try vector_mod.fromSlice(heap, &.{ try it.internKeywordValue("db.fn/call"), try it.internSymbolValue("age!"), args[0], args[1] });
            return vector_mod.fromSlice(heap, &.{form});
        }
        // Calls itself forever.
        if (std.mem.eql(u8, name, "forever")) {
            const form = try vector_mod.fromSlice(heap, &.{ try it.internKeywordValue("db.fn/call"), f });
            return vector_mod.fromSlice(heap, &.{form});
        }
        // `(countdown e n)`: calls itself `n` levels deep, then `age!`.
        if (std.mem.eql(u8, name, "countdown")) {
            const n = args[1].asFixnum();
            const next = if (n == 0)
                try vector_mod.fromSlice(heap, &.{ try it.internKeywordValue("db.fn/call"), try it.internSymbolValue("age!"), args[0], value.fromFixnum(99).? })
            else
                try vector_mod.fromSlice(heap, &.{ try it.internKeywordValue("db.fn/call"), f, args[0], value.fromFixnum(n - 1).? });
            return vector_mod.fromSlice(heap, &.{next});
        }
        // Nothing.
        if (std.mem.eql(u8, name, "nothing")) return value.nilValue();
        // Not tx-data.
        if (std.mem.eql(u8, name, "text")) return string_mod.fromBytes(heap, "nope");
        return error.UnknownBehaviour;
    }
};

test "transaction functions splice their tx-data in place, nest to a bound, and see db-before" {
    const tc = try TestConn.init("tx_fn");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var heap = nx.heap.Heap.init(arena);
    defer heap.deinit();
    try installSchema(tc, arena);
    const age = try attrId(tc, "user/age");
    const name = try attrId(tc, "user/name");
    const r0 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Ann" } } } },
    }, .{});
    const a = r0.tempids[0].eid;
    var th = TestTxHook{ .tc = tc, .heap = &heap };
    const it = &tc.interner;
    const call_kw = try it.internKeywordValue("db.fn/call");
    const eid = value.fromFixnum(@intCast(a)).?;
    var fault: Fault = .{};

    // Without a hook the form cannot run; nothing is written.
    const direct = try vector_mod.fromSlice(&heap, &.{try vector_mod.fromSlice(&heap, &.{ call_kw, try it.internSymbolValue("age!"), eid, value.fromFixnum(30).? })});
    try testing.expectError(error.TxFn, transact(tc.conn, arena, direct, .{ .fault = &fault }));
    try testing.expect(fault.message != null);
    try testing.expectEqual(r0.t, (try tc.conn.db()).basis);

    // The call's datoms land in place, between the surrounding forms.
    const add_kw = try it.internKeywordValue("db/add");
    const name_kw = try it.internKeywordValue("user/name");
    const before = try vector_mod.fromSlice(&heap, &.{ add_kw, eid, name_kw, try string_mod.fromBytes(&heap, "Anne") });
    const tx = try vector_mod.fromSlice(&heap, &.{ before, try vector_mod.fromSlice(&heap, &.{ call_kw, try it.internSymbolValue("via"), eid, value.fromFixnum(30).? }) });
    const r1 = try transact(tc.conn, arena, tx, .{ .hook = th.hook() });
    try testing.expectEqual(@as(usize, 2), th.calls);
    try testing.expectEqual(r0.t, th.basis);
    // Anne retract+add, age add, txInstant.
    try testing.expectEqual(@as(usize, 4), r1.tx_data.len);
    try testing.expectEqual(name, r1.tx_data[0].a);
    try testing.expectEqual(age, r1.tx_data[2].a);
    try testing.expectEqual(@as(i64, 30), r1.tx_data[2].v.long);

    // A chain of `max_call_depth` nested calls runs: countdown from
    // n makes n + 1 calls, then `age!` one more.
    const countdown = try vector_mod.fromSlice(&heap, &.{try vector_mod.fromSlice(&heap, &.{ call_kw, try it.internSymbolValue("countdown"), eid, value.fromFixnum(max_call_depth - 2).? })});
    const r_deep = try transact(tc.conn, arena, countdown, .{ .hook = th.hook() });
    try testing.expectEqual(@as(i64, 99), r_deep.tx_data[1].v.long);

    // Unbounded nesting stops at the depth limit, which the message
    // names, with nothing written.
    const forever = try vector_mod.fromSlice(&heap, &.{try vector_mod.fromSlice(&heap, &.{ call_kw, try it.internSymbolValue("forever") })});
    try testing.expectError(error.TxFn, transact(tc.conn, arena, forever, .{ .hook = th.hook(), .fault = &fault }));
    try testing.expectEqualStrings("transaction functions nest past 1000 calls", fault.message.?);
    try testing.expectEqual(r_deep.t, (try tc.conn.db()).basis);

    // A nil result is no tx-data; a non-tx-data result is malformed.
    const nothing = try vector_mod.fromSlice(&heap, &.{try vector_mod.fromSlice(&heap, &.{ call_kw, try it.internSymbolValue("nothing") })});
    const r2 = try transact(tc.conn, arena, nothing, .{ .hook = th.hook() });
    try testing.expectEqual(@as(usize, 1), r2.tx_data.len);
    const bad = try vector_mod.fromSlice(&heap, &.{try vector_mod.fromSlice(&heap, &.{ call_kw, try it.internSymbolValue("text") })});
    try testing.expectError(error.TxData, transact(tc.conn, arena, bad, .{ .hook = th.hook() }));
    // Only a function or a symbol may sit in function position.
    const not_fn = try vector_mod.fromSlice(&heap, &.{try vector_mod.fromSlice(&heap, &.{ call_kw, try string_mod.fromBytes(&heap, "f") })});
    try testing.expectError(error.TxData, transact(tc.conn, arena, not_fn, .{ .hook = th.hook() }));

    // A second write on the connection inside a call is nested.
    const Inner = struct {
        fn call(ctx: *anyopaque, _: Value, db_before: DbValue, _: []const Value) anyerror!Value {
            const c: *TestConn = @ptrCast(@alignCast(ctx));
            var inner_arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer inner_arena.deinit();
            try testing.expectError(error.Nested, transactOps(c.conn, inner_arena.allocator(), &.{}, .{}));
            try testing.expectError(error.Nested, withOps(c.conn, inner_arena.allocator(), &.{}, .{}));
            // Reads of db-before work while the write is held.
            try testing.expect((try db_before.datoms(inner_arena.allocator(), .eavt, .{ .e = boot.ident })).len > 0);
            return value.nilValue();
        }
    };
    const inner_hook: CallHook = .{ .ctx = @ptrCast(tc), .call = &Inner.call };
    _ = try transact(tc.conn, arena, nothing, .{ .hook = inner_hook });
}

// ── the store ────────────────────────────────────────────────────

test "a count or a t read out of its range is Corrupted" {
    var td = try TestDir.init("store_ranges");
    defer td.deinit();
    const store = try Store.open(testing.allocator, td.path.ptr, .{});
    defer store.close();
    const txn = try store.beginWrite(.none);
    defer txn.abort();
    // No attribute holds more current datoms than there are ids.
    try store.writeAttrCount(txn, boot.doc, key.id_max + 1);
    try testing.expectError(error.Corrupted, store.attrCount(txn, boot.doc));
    var raw: [key.id_len]u8 = undefined;
    key.writeId(&raw, key.tx_partition_bit);
    try testing.expectError(error.Corrupted, key.readT(&raw));
    key.writeId(&raw, key.tx_partition_bit - 1);
    try testing.expectEqual(key.tx_partition_bit - 1, try key.readT(&raw));
}

test "a page that fails its check ends a scan with an error, never early" {
    var td = try TestDir.init("store_damaged");
    defer td.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fact = try key.keyBytes(arena, .eavt, boot.doc, boot.ident, try key.valBytes(arena, .{ .keyword = boot.doc }), null);
    (try Store.open(testing.allocator, td.path.ptr, .{})).close();
    // One byte flipped in the page holding :db/doc's ident row: the
    // nx/eavt leaf fails its checksum.
    const io = testing.io;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, td.path, arena, .unlimited);
    var at: usize = 0;
    var damaged: usize = 0;
    while (std.mem.findPos(u8, bytes, at, fact)) |i| : (at = i + fact.len) {
        bytes[i + fact.len - 1] ^= 0xFF;
        damaged += 1;
    }
    try testing.expect(damaged >= 1);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = td.path, .data = bytes });

    const store = try Store.open(testing.allocator, td.path.ptr, .{});
    defer store.close();
    const txn = try store.beginRead();
    defer txn.abort();
    var s = try Store.scan(txn, store.trees.cur(.eavt), &.{});
    try testing.expectError(error.InvalidPage, s.next());
    var f = try Store.foldScan(txn, store.trees, .eavt, &.{}, null, .{ .as_of = 1 });
    try testing.expectError(error.InvalidPage, f.next());
    try testing.expectError(error.InvalidPage, store.currentPayload(txn, boot.doc, boot.ident, (try key.unpackKey(.eavt, false, fact)).v, arena));
}

test "open bootstraps once and reopen finds the same ids" {
    var td = try TestDir.init("store_boot");
    defer td.deinit();

    var uuid: [16]u8 = undefined;
    {
        const store = try Store.open(testing.allocator, td.path.ptr, .{});
        defer store.close();
        uuid = store.uuid;
        const txn = try store.beginRead();
        defer txn.abort();
        try testing.expectEqual(@as(u64, 1), try store.readT(txn));
        try testing.expectEqual(key.user_partition_start, try store.readNextEid(txn));
        try testing.expectEqual(boot.next_aid, try store.readNextAid(txn));
        try testing.expectEqual(@as(?u32, boot.ident), try store.identIdByName(txn, "db/ident"));
        try testing.expectEqual(@as(?u32, boot.unique_value), try store.identIdByName(txn, "db.unique/value"));
        try testing.expectEqualStrings("db.type/string", (try store.identNameById(txn, boot.type_string)).?);
        try testing.expectEqual(@as(u64, boot.idents.len), try store.attrCount(txn, boot.ident));
        try testing.expect((try store.getTxlog(txn, 1)) != null);
    }
    {
        const store = try Store.open(testing.allocator, td.path.ptr, .{});
        defer store.close();
        try testing.expectEqualSlices(u8, &uuid, &store.uuid);
        const txn = try store.beginRead();
        defer txn.abort();
        try testing.expectEqual(@as(u64, 1), try store.readT(txn));
        try testing.expectEqual(@as(?u32, boot.ident), try store.identIdByName(txn, "db/ident"));
        try testing.expectEqual(@as(u64, boot.idents.len), try store.attrCount(txn, boot.ident));
    }
}

test "a new store file starts small and grows a step at a time" {
    var td = try TestDir.init("store_map");
    defer td.deinit();
    const store = try Store.open(testing.allocator, td.path.ptr, .{});
    defer store.close();
    try testing.expectEqual(db_layer.initial_map_size, store.file.env.info().mapSize);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Payloads past the first size grow the file in whole steps.
    const payload = try arena.alloc(u8, 4096);
    @memset(payload, 'x');
    const batch = try arena.alloc(Store.Prepared, 512);
    for (batch, 0..) |*p, i| p.* = .{ .e = (1 << 33) + i, .a = 100, .vbytes = try key.valBytes(arena, .{ .long = 0 }), .payload = payload, .added = true, .avet = false, .vaet = false };
    const txn = try store.beginWrite(.none);
    errdefer txn.abort();
    try store.writeBatch(txn, 2, batch, arena);
    try txn.commit();
    const grown = store.file.env.info().mapSize;
    try testing.expect(grown > db_layer.initial_map_size and grown < 64 << 20);
    try testing.expectEqual(0, (grown - db_layer.initial_map_size) % db_layer.map_grow_step);
}

test "bootstrap datoms are in every index they belong to" {
    var td = try TestDir.init("store_idx");
    defer td.deinit();
    const store = try Store.open(testing.allocator, td.path.ptr, .{});
    defer store.close();
    const txn = try store.beginRead();
    defer txn.abort();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // EAVT [1]: :db/ident has ident, valueType, cardinality, unique, index.
    const p = try key.prefixBytes(arena, .eavt, .{ .e = boot.ident });
    var s = try Store.scan(txn, store.trees.cur(.eavt), p);
    var n: usize = 0;
    while (try s.next()) |kv| : (n += 1) {
        const cur = try key.readCurrent(kv.value);
        try testing.expectEqual(@as(u64, 1), cur.t);
        try testing.expectEqual(@as(usize, 0), cur.rest.len);
    }
    try testing.expectEqual(@as(usize, 5), n);

    // AVET [:db/ident] holds every ident; [:db/valueType] is not indexed.
    const pa = try key.prefixBytes(arena, .avet, .{ .a = boot.ident });
    var sa = try Store.scan(txn, store.trees.cur(.avet), pa);
    n = 0;
    while (try sa.next()) |_| n += 1;
    try testing.expectEqual(@as(usize, boot.idents.len), n);
    const pv = try key.prefixBytes(arena, .avet, .{ .a = boot.value_type });
    var sv = try Store.scan(txn, store.trees.cur(.avet), pv);
    try testing.expect((try sv.next()) == null);

    // Nothing is retired yet: the history trees are empty.
    for (store.trees.history) |tree| try testing.expectEqual(@as(u64, 0), try Store.treeEntries(txn, tree));

    // Empty prefix walks the whole tree.
    var all = try Store.scan(txn, store.trees.cur(.aevt), &.{});
    n = 0;
    while (try all.next()) |_| n += 1;
    try testing.expect(n > boot.idents.len);
}

test "abort leaves nothing behind" {
    var td = try TestDir.init("store_abort");
    defer td.deinit();
    const store = try Store.open(testing.allocator, td.path.ptr, .{});
    defer store.close();
    {
        const txn = try store.beginWrite(.none);
        try store.writeT(txn, 99);
        try store.putIdent(txn, "gone", 1000);
        txn.abort();
    }
    const txn = try store.beginRead();
    defer txn.abort();
    try testing.expectEqual(@as(u64, 1), try store.readT(txn));
    try testing.expect((try store.identIdByName(txn, "gone")) == null);
}

test "fold keeps the newest in-window row per fact and drops retractions" {
    var td = try TestDir.init("store_fold");
    defer td.deinit();
    const store = try Store.open(testing.allocator, td.path.ptr, .{});
    defer store.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Entity 2^33, attribute 100: v=1 asserted at t=2, retracted at t=3,
    // v=2 asserted at t=3, v=2 retracted at t=5; attribute 101: v=7 at t=4.
    const e: u64 = 1 << 33;
    const v1 = try key.valBytes(arena, .{ .long = 1 });
    const v2 = try key.valBytes(arena, .{ .long = 2 });
    const v7 = try key.valBytes(arena, .{ .long = 7 });
    {
        const txn = try store.beginWrite(.none);
        try store.writeBatch(txn, 2, &.{.{ .e = e, .a = 100, .vbytes = v1, .added = true, .avet = false, .vaet = false }}, arena);
        try store.writeBatch(txn, 3, &.{
            .{ .e = e, .a = 100, .vbytes = v1, .added = false, .avet = false, .vaet = false },
            .{ .e = e, .a = 100, .vbytes = v2, .added = true, .avet = false, .vaet = false },
        }, arena);
        try store.writeBatch(txn, 4, &.{.{ .e = e, .a = 101, .vbytes = v7, .added = true, .avet = false, .vaet = false }}, arena);
        try store.writeBatch(txn, 5, &.{.{ .e = e, .a = 100, .vbytes = v2, .added = false, .avet = false, .vaet = false }}, arena);
        try txn.commit();
    }
    const txn = try store.beginRead();
    defer txn.abort();
    const prefix = try key.prefixBytes(arena, .eavt, .{ .e = e });
    const end = (try key.successor(arena, prefix)).?;

    const Expect = struct { window: Store.Window, facts: []const u64 };
    const cases = [_]Expect{
        .{ .window = .{ .as_of = 1 }, .facts = &.{} },
        .{ .window = .{ .as_of = 2 }, .facts = &.{1} },
        .{ .window = .{ .as_of = 3 }, .facts = &.{2} },
        .{ .window = .{ .as_of = 4 }, .facts = &.{ 2, 7 } },
        .{ .window = .{ .as_of = 5 }, .facts = &.{7} },
        .{ .window = .{ .since = .{ .after = 3, .upto = 5 } }, .facts = &.{7} },
        .{ .window = .{ .since = .{ .after = 2, .upto = 4 } }, .facts = &.{ 2, 7 } },
        .{ .window = .{ .since = .{ .after = 4, .upto = 5 } }, .facts = &.{} },
    };
    for (cases) |c| {
        var fs = try Store.foldScan(txn, store.trees, .eavt, prefix, end, c.window);
        var got: std.ArrayList(u64) = .empty;
        while (try fs.next()) |r| {
            try testing.expect(r.added);
            const parts = try key.unpackKey(.eavt, false, r.fact);
            const kv = try key.decodeVal(arena, parts.v);
            try got.append(arena, @intCast(kv.val.long));
        }
        try testing.expectEqualSlices(u64, c.facts, got.items);
    }
    // History mode sees all five rows in t order with their flags.
    var all = try Store.foldScan(txn, store.trees, .eavt, prefix, end, .{ .all = .{ .after = 0, .upto = 5 } });
    var n: usize = 0;
    var adds: usize = 0;
    while (try all.next()) |r| {
        n += 1;
        if (r.added) adds += 1;
    }
    try testing.expectEqual(@as(usize, 5), n);
    try testing.expectEqual(@as(usize, 3), adds);
    // Current trees hold only attribute 101 now.
    var cur = try Store.scan(txn, store.trees.cur(.eavt), prefix);
    const only = (try cur.next()).?;
    try testing.expectEqual(@as(u32, 101), (try key.unpackKey(.eavt, false, only.key)).a);
    try testing.expect((try cur.next()) == null);
}

test "batches written between existing keys fill their leaves" {
    var td = try TestDir.init("store_fill");
    defer td.deinit();
    const store = try Store.open(testing.allocator, td.path.ptr, .{});
    defer store.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // New entities land before the bootstrap transaction's entity in
    // EAVT and attribute 100's between attribute 8's and 101's in AEVT;
    // attribute 101's are appended past AEVT's last key.
    var k: u64 = 0;
    for (0..16) |t| {
        const batch = try arena.alloc(Store.Prepared, 5000);
        for (0..2500) |j| {
            const e = (1 << 33) + k;
            const name = try arena.print("name-{d}", .{k});
            batch[2 * j] = .{ .e = e, .a = 100, .vbytes = try key.valBytes(arena, .{ .long = @intCast(k) }), .added = true, .avet = false, .vaet = false };
            batch[2 * j + 1] = .{ .e = e, .a = 101, .vbytes = try key.valBytes(arena, .{ .string = name }), .added = true, .avet = false, .vaet = false };
            k += 1;
        }
        const txn = try store.beginWrite(.none);
        errdefer txn.abort();
        try store.writeBatch(txn, t + 2, batch, arena);
        try txn.commit();
    }
    const txn = try store.beginRead();
    defer txn.abort();
    for ([_]Index{ .eavt, .aevt }) |index| {
        try testing.expect((try Store.treeSize(txn, store.trees.cur(index), testing.allocator)).fill() > 0.75);
        // New facts retire nothing.
        try testing.expectEqual(@as(u64, 0), try Store.treeEntries(txn, store.trees.hist(index)));
    }
}

test "a batch holds what writing its datoms one at a time holds" {
    var tds = [2]TestDir{ try TestDir.init("store_order_batch"), try TestDir.init("store_order_single") };
    defer for (&tds) |*td| td.deinit();
    const batched = try Store.open(testing.allocator, tds[0].path.ptr, .{});
    defer batched.close();
    const single = try Store.open(testing.allocator, tds[1].path.ptr, .{});
    defer single.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prng = std.Random.DefaultPrng.init(0x6e78_6f72_6465_7200);
    const rand = prng.random();

    // Batches of up to 4000 datoms over a few thousand facts, most of
    // them assertions of facts not current, the rest retractions of
    // current ones, each fact at most once a batch, as a transaction
    // writes them.
    var current: std.AutoHashMapUnmanaged(u64, void) = .empty;
    for (0..30) |i| {
        const t = i + 2;
        var in_batch: std.AutoHashMapUnmanaged(u64, void) = .empty;
        var list: std.ArrayList(Store.Prepared) = .empty;
        for (0..rand.intRangeAtMost(usize, 1, 4000)) |_| {
            const a = rand.intRangeAtMost(u32, 100, 102);
            const x = rand.uintLessThan(u64, 3000);
            const e_off = rand.uintLessThan(u64, 3000);
            const id = (e_off * 4 + (a - 100)) * 4096 + (if (a == 102) x else x % 50);
            if ((try in_batch.getOrPut(arena, id)).found_existing) continue;
            const held = current.contains(id);
            if (held and rand.uintLessThan(u8, 4) != 0) continue;
            if (held) _ = current.remove(id) else try current.put(arena, id, {});
            const v: key.Val = if (a == 102) .{ .ref = (1 << 33) + x } else .{ .long = @intCast(x % 50) };
            try list.append(arena, .{
                .e = (1 << 33) + e_off,
                .a = a,
                .vbytes = try key.valBytes(arena, v),
                .added = !held,
                .avet = a == 101,
                .vaet = a == 102,
            });
        }
        const batch = list.items;
        for ([_]*Store{ batched, single }) |store| {
            const txn = try store.beginWrite(.none);
            errdefer txn.abort();
            if (store == batched) {
                try store.writeBatch(txn, t, batch, arena);
            } else for (batch) |p| try store.writeBatch(txn, t, &.{p}, arena);
            try txn.commit();
        }
    }
    const txns = [2]*Txn{ try batched.beginRead(), try single.beginRead() };
    defer for (txns) |txn| txn.abort();
    for (0..4) |ix| for ([_]bool{ false, true }) |history| {
        const index: Index = @fromBackingInt(@intCast(ix));
        // The bootstrap's datoms differ in their instants: compare the
        // keys the batches can hold.
        const from = try key.prefixBytes(arena, index, switch (index) {
            .eavt => .{ .e = 1 << 33 },
            .vaet => .{ .v = try key.valBytes(arena, .{ .ref = 1 << 33 }) },
            else => .{ .a = 100 },
        });
        const to: ?[]const u8 = if (index == .eavt) try key.prefixBytes(arena, .eavt, .{ .e = key.tx_partition_bit }) else null;
        var scans: [2]Store.Scan = undefined;
        for (&scans, txns, [_]*Store{ batched, single }) |*sc, txn, store|
            sc.* = try Store.scanRange(txn, if (history) store.trees.hist(index) else store.trees.cur(index), from, to);
        while (try scans[0].next()) |x| {
            const y = (try scans[1].next()) orelse return error.TestUnexpectedResult;
            try testing.expectEqualSlices(u8, y.key, x.key);
            try testing.expectEqualSlices(u8, y.value, x.value);
        }
        try testing.expect((try scans[1].next()) == null);
    };
}

test "an out-of-line value is stored once in the index trees, beside its current row or on its retired assertion" {
    var td = try TestDir.init("store_payload");
    defer td.deinit();
    const store = try Store.open(testing.allocator, td.path.ptr, .{});
    defer store.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const e: u64 = 1 << 33;
    const long = repeat("a string long enough to leave its index keys for a payload of its own, ", 3);
    const v = try key.valBytes(arena, .{ .string = long });
    const cur_key = try key.keyBytes(arena, .eavt, e, 101, v, null);
    {
        const txn = try store.beginWrite(.none);
        errdefer txn.abort();
        try store.writeBatch(txn, 3, &.{.{ .e = e, .a = 101, .vbytes = v, .payload = long, .added = true, .avet = false, .vaet = false }}, arena);
        try txn.commit();
    }
    {
        // Current: the payload follows `t` in the EAVT value, and the
        // history trees hold nothing.
        const txn = try store.beginRead();
        defer txn.abort();
        try testing.expectEqualStrings(long, (try key.readCurrent((try txn.getFromTree(store.trees.cur(.eavt), cur_key)).?)).rest);
        try testing.expectEqual(@as(u64, 0), try Store.treeEntries(txn, store.trees.hist(.eavt)));
        try testing.expectEqualStrings(long, (try store.currentPayload(txn, e, 101, v, arena)).?);
    }
    {
        const txn = try store.beginWrite(.none);
        errdefer txn.abort();
        try store.writeBatch(txn, 4, &.{.{ .e = e, .a = 101, .vbytes = v, .payload = long, .added = false, .avet = false, .vaet = false }}, arena);
        try txn.commit();
    }
    {
        // Retracted: the assertion moves to EAVT-h with its payload, and
        // the retraction's row beside it holds nothing.
        const txn = try store.beginRead();
        defer txn.abort();
        try testing.expect((try store.currentPayload(txn, e, 101, v, arena)) == null);
        try testing.expectEqual(@as(u64, 2), try Store.treeEntries(txn, store.trees.hist(.eavt)));
        try testing.expectEqualStrings(long, (try txn.getFromTree(store.trees.hist(.eavt), try key.keyBytes(arena, .eavt, e, 101, v, .{ .t = 3, .added = true }))).?);
        try testing.expectEqual(0, (try txn.getFromTree(store.trees.hist(.eavt), try key.keyBytes(arena, .eavt, e, 101, v, .{ .t = 4, .added = false }))).?.len);
        try testing.expectEqualStrings(long, try store.historyPayload(txn, e, 101, v, .{ .t = 3, .added = true }));
        try testing.expectEqualStrings(long, try store.historyPayload(txn, e, 101, v, .{ .t = 4, .added = false }));
    }
    {
        const w = try store.beginWrite(.none);
        errdefer w.abort();
        try store.writeBatch(w, 5, &.{.{ .e = e, .a = 101, .vbytes = v, .payload = long, .added = true, .avet = false, .vaet = false }}, arena);
        try w.commit();
    }
    const again = try store.beginRead();
    defer again.abort();
    try testing.expectEqualStrings(long, (try key.readCurrent((try again.getFromTree(store.trees.cur(.eavt), cur_key)).?)).rest);
    try testing.expectEqual(@as(u64, 2), try Store.treeEntries(again, store.trees.hist(.eavt)));
}

test "a retraction of a fact that is not current is Corrupted" {
    var td = try TestDir.init("store_retract_absent");
    defer td.deinit();
    const store = try Store.open(testing.allocator, td.path.ptr, .{});
    defer store.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const txn = try store.beginWrite(.none);
    defer txn.abort();
    try testing.expectError(error.Corrupted, store.writeBatch(txn, 2, &.{.{ .e = 1 << 33, .a = 100, .vbytes = try key.valBytes(arena, .{ .long = 1 }), .added = false, .avet = false, .vaet = false }}, arena));
}

test "a file holding some of the trees, or the trees without their header, is Corrupted, never bootstrapped again" {
    var tds = [2]TestDir{ try TestDir.init("store_headless"), try TestDir.init("store_treeless") };
    defer for (&tds) |*td| td.deinit();
    for (tds, 0..) |td, i| {
        (try Store.open(testing.allocator, td.path.ptr, .{})).close();
        {
            const file = try db_layer.StoreFile.acquire(td.path.ptr, .{ .allocator = testing.allocator });
            defer file.release();
            const txn = try file.beginWrite(.{});
            errdefer txn.abort();
            if (i == 0) {
                _ = try txn.delFromTree(try txn.openTree("nx/sys", false), "format");
            } else {
                try txn.dropTree(try txn.openTree("nx/fulltext", false), true);
            }
            try file.commit(txn);
        }
        try testing.expectError(error.Corrupted, Store.open(testing.allocator, td.path.ptr, .{}));
    }
}

test "a store opens at this build's format alone and names any other" {
    var td = try TestDir.init("store_format");
    defer td.deinit();
    (try Store.open(testing.allocator, td.path.ptr, .{})).close();
    for ([_]u16{ 1, 2, 4, format_version }) |f| {
        {
            const file = try db_layer.StoreFile.acquire(td.path.ptr, .{ .allocator = testing.allocator });
            defer file.release();
            const txn = try file.beginWrite(.{});
            errdefer txn.abort();
            var buf: [2]u8 = undefined;
            std.mem.writeInt(u16, &buf, f, .big);
            try txn.putInTree(try txn.openTree("nx/sys", false), "format", &buf);
            try file.commit(txn);
        }
        var found: u16 = 0;
        if (f == format_version) {
            const store = try Store.open(testing.allocator, td.path.ptr, .{ .refused_format = &found });
            store.close();
            try testing.expectEqual(0, found);
        } else {
            try testing.expectError(error.Format, Store.open(testing.allocator, td.path.ptr, .{ .refused_format = &found }));
            try testing.expectEqual(f, found);
        }
    }
}

test "renaming an ident retires the old name and bumps the generation" {
    var td = try TestDir.init("store_rename");
    defer td.deinit();
    const store = try Store.open(testing.allocator, td.path.ptr, .{});
    defer store.close();
    {
        const txn = try store.beginWrite(.none);
        try testing.expectEqual(@as(u64, 0), try store.readIdentGen(txn));
        try store.putIdent(txn, "user/email", boot.next_aid);
        try store.renameIdent(txn, boot.next_aid, "user/mail");
        try txn.commit();
    }
    const txn = try store.beginRead();
    defer txn.abort();
    try testing.expect((try store.identIdByName(txn, "user/email")) == null);
    try testing.expectEqual(@as(?u32, boot.next_aid), try store.retiredIdentId(txn, "user/email"));
    try testing.expectEqual(@as(?u32, boot.next_aid), try store.identIdByName(txn, "user/mail"));
    try testing.expect((try store.retiredIdentId(txn, "user/mail")) == null);
    try testing.expectEqualStrings("user/mail", (try store.identNameById(txn, boot.next_aid)).?);
    try testing.expectEqual(@as(u64, 1), try store.readIdentGen(txn));
}

test "long ident names use the heap path" {
    var td = try TestDir.init("store_longname");
    defer td.deinit();
    const store = try Store.open(testing.allocator, td.path.ptr, .{});
    defer store.close();
    const long_name = "ns/" ++ @as([400]u8, @splat('x'));
    {
        const txn = try store.beginWrite(.none);
        try store.putIdent(txn, long_name, 5000);
        try txn.commit();
    }
    const txn = try store.beginRead();
    defer txn.abort();
    try testing.expectEqual(@as(?u32, 5000), try store.identIdByName(txn, long_name));
    try testing.expectEqualStrings(long_name, (try store.identNameById(txn, 5000)).?);
}

test "reopening a complete store writes nothing, so a read-only file opens" {
    var td = try TestDir.init("store_open_read");
    defer td.deinit();
    const committed = blk: {
        const store = try Store.open(testing.allocator, td.path.ptr, .{});
        defer store.close();
        const txn = try store.beginRead();
        defer txn.abort();
        break :blk txn.txnId;
    };
    {
        const store = try Store.open(testing.allocator, td.path.ptr, .{});
        defer store.close();
        const txn = try store.beginRead();
        defer txn.abort();
        try testing.expectEqual(committed, txn.txnId);
    }
    try testing.expectEqual(@as(c_int, 0), std.c.chmod(td.path.ptr, 0o444));
    defer _ = std.c.chmod(td.path.ptr, 0o644);
    const store = try Store.open(testing.allocator, td.path.ptr, .{});
    defer store.close();
    {
        const txn = try store.beginRead();
        defer txn.abort();
        try testing.expectEqual(@as(u64, 1), try store.readT(txn));
    }
    try testing.expectError(error.TxnReadOnly, store.beginWrite(.none));
}

test "a second store on the same file refuses to write while the first does" {
    var td = try TestDir.init("store_same_file");
    defer td.deinit();
    const a = try Store.open(testing.allocator, td.path.ptr, .{});
    defer a.close();
    const b = try Store.open(testing.allocator, td.path.ptr, .{});
    defer b.close();
    // One environment, checked before a second write begins: on two,
    // emdb's writer lock would wait for `a`, which this thread holds.
    try testing.expect(a.file == b.file);
    const txn = try a.beginWrite(.none);
    try testing.expectError(error.WriterActive, b.beginWrite(.none));
    txn.abort();
    const again = try b.beginWrite(.none);
    again.abort();
}

test "a db/* connection and a store of one file share one writer" {
    var td = try TestDir.init("store_db_layer");
    defer td.deinit();
    const store = try Store.open(testing.allocator, td.path.ptr, .{});
    defer store.close();
    const file = try db_layer.StoreFile.acquire(td.path.ptr, .{ .allocator = testing.allocator });
    defer file.release();
    try testing.expect(file == store.file);
    const kv = try file.beginWrite(.{});
    try testing.expectError(error.WriterActive, store.beginWrite(.none));
    kv.abort();
    const txn = try store.beginWrite(.none);
    try testing.expectError(error.WriterActive, file.beginWrite(.{}));
    txn.abort();
}

test "a copy of a store file is another file: its uuid is shared, its writer is not" {
    var td = try TestDir.init("store_copied");
    defer td.deinit();
    const a = try Store.open(testing.allocator, td.path.ptr, .{});
    defer a.close();
    const copy = try testing.allocator.printSentinel("{s}/copy.emdb", .{std.Io.Dir.path.dirname(td.path).?}, 0);
    defer testing.allocator.free(copy);
    try std.Io.Dir.cwd().copyFile(td.path, std.Io.Dir.cwd(), copy, testing.io, .{});
    const b = try Store.open(testing.allocator, copy.ptr, .{});
    defer b.close();
    try testing.expectEqualSlices(u8, &a.uuid, &b.uuid);
    try testing.expect(a.file != b.file);
    const ta = try a.beginWrite(.none);
    defer ta.abort();
    const tb = try b.beginWrite(.none);
    tb.abort();
}

test "a merged scan orders facts by their bytes, each fact's history before its current row" {
    var td = try TestDir.init("store_merged");
    defer td.deinit();
    const store = try Store.open(testing.allocator, td.path.ptr, .{});
    defer store.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Facts that prefix one another: "a", "a\x00", "a\x00b", a 64-byte
    // inline string and its out-of-line sibling, each with rows in
    // the current tree, the history tree or both.
    const e: u64 = 1 << 33;
    const inline64 = &@as([key.prefix_len]u8, @splat('x'));
    const long = inline64 ++ "and more, past the inline limit of ninety-six bytes, so out of line";
    const Row = struct { v: []const u8, t: u64, added: bool, current: bool };
    const rows = [_]Row{
        .{ .v = "a", .t = 2, .added = true, .current = false },
        .{ .v = "a", .t = 3, .added = false, .current = false },
        .{ .v = "a", .t = 5, .added = true, .current = true },
        .{ .v = "a\x00", .t = 2, .added = true, .current = false },
        .{ .v = "a\x00", .t = 6, .added = false, .current = false },
        .{ .v = "a\x00b", .t = 4, .added = true, .current = true },
        .{ .v = inline64, .t = 7, .added = true, .current = true },
        .{ .v = long, .t = 3, .added = true, .current = false },
        .{ .v = long, .t = 8, .added = false, .current = false },
        .{ .v = long, .t = 9, .added = true, .current = true },
        .{ .v = "z", .t = 2, .added = true, .current = true },
    };
    {
        const txn = try store.beginWrite(.none);
        errdefer txn.abort();
        for (rows) |r| {
            const vb = try key.valBytes(arena, .{ .string = r.v });
            inline for (.{ Index.eavt, Index.avet }) |ix| {
                if (r.current) {
                    var tb: [key.t_value_max]u8 = undefined;
                    try txn.putInTree(store.trees.cur(ix), try key.keyBytes(arena, ix, e, 100, vb, null), key.writeCurrentT(&tb, r.t));
                } else {
                    try txn.putInTree(store.trees.hist(ix), try key.keyBytes(arena, ix, e, 100, vb, .{ .t = r.t, .added = r.added }), &.{});
                }
            }
        }
        try txn.commit();
    }
    const txn = try store.beginRead();
    defer txn.abort();
    inline for (.{ Index.eavt, Index.avet }) |ix| {
        const prefix = try key.prefixBytes(arena, ix, if (ix == .eavt) .{ .e = e } else .{ .a = 100 });
        const end = try key.successor(arena, prefix);
        var m = try Store.mergedScan(txn, store.trees, ix, prefix, end);
        // Every row, in the order `rows` lists them; in AVET, where the
        // entity follows the value, the out-of-line value's rows come
        // before its 64-byte inline sibling's (NEXTOMIC.md §2.2).
        const order: []const usize = if (ix == .eavt) &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 } else &.{ 0, 1, 2, 3, 4, 5, 7, 8, 9, 6, 10 };
        for (order) |r| {
            const want = rows[r];
            const got = (try m.next()) orelse return error.TestUnexpectedResult;
            const parts = try key.unpackKey(ix, false, got.fact);
            try testing.expectEqualSlices(u8, try key.valBytes(arena, .{ .string = want.v }), parts.v);
            try testing.expectEqual(want.t, got.t);
            try testing.expectEqual(want.added, got.added);
            try testing.expectEqual(want.current, got.current);
        }
        try testing.expect((try m.next()) == null);
        // As of 6: "a" (asserted again at 5) and the out-of-line
        // value (asserted at 3) and "z"; "a\x00" went at 6, and "a\x00b"
        // came at 4.
        var f = try Store.foldScan(txn, store.trees, ix, prefix, end, .{ .as_of = 6 });
        var n: usize = 0;
        while (try f.next()) |r| : (n += 1) try testing.expect(r.added and r.t <= 6);
        try testing.expectEqual(@as(usize, 4), n);
    }
}

test "a current row after a history row that is not an older retraction breaks H1" {
    var td = try TestDir.init("store_h1");
    defer td.deinit();
    const store = try Store.open(testing.allocator, td.path.ptr, .{});
    defer store.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const e: u64 = 1 << 33;
    const vb = try key.valBytes(arena, .{ .long = 1 });
    // The current assertion at 5 after a retained assertion at 3, and
    // after a retraction at 6.
    const histories = [_][]const key.Top{ &.{.{ .t = 3, .added = true }}, &.{ .{ .t = 2, .added = true }, .{ .t = 6, .added = false } } };
    for (histories) |rows| {
        const txn = try store.beginWrite(.none);
        defer txn.abort();
        var tb: [key.t_value_max]u8 = undefined;
        try txn.putInTree(store.trees.cur(.eavt), try key.keyBytes(arena, .eavt, e, 100, vb, null), key.writeCurrentT(&tb, 5));
        for (rows) |top| try txn.putInTree(store.trees.hist(.eavt), try key.keyBytes(arena, .eavt, e, 100, vb, top), &.{});
        const prefix = try key.prefixBytes(arena, .eavt, .{ .e = e });
        var m = try Store.mergedScan(txn, store.trees, .eavt, prefix, try key.successor(arena, prefix));
        for (rows) |_| _ = try m.next();
        try testing.expectError(error.Corrupted, m.next());
    }
}

test "a fact's history that starts with a retraction, repeats a flag or ends in an assertion with no current row breaks H1" {
    var td = try TestDir.init("store_h1_history");
    defer td.deinit();
    const store = try Store.open(testing.allocator, td.path.ptr, .{});
    defer store.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const e: u64 = 1 << 33;
    const Case = struct { rows: []const key.Top, other: bool = false };
    const cases = [_]Case{
        // A retraction with no assertion before it.
        .{ .rows = &.{.{ .t = 3, .added = false }} },
        // Two assertions in a row.
        .{ .rows = &.{ .{ .t = 2, .added = true }, .{ .t = 3, .added = true }, .{ .t = 4, .added = false } } },
        // An assertion last, the fact not current: the scan ends there.
        .{ .rows = &.{.{ .t = 2, .added = true }} },
        // The same, followed by another fact's rows.
        .{ .rows = &.{ .{ .t = 2, .added = true }, .{ .t = 3, .added = false }, .{ .t = 4, .added = true } }, .other = true },
    };
    for (cases) |c| {
        const txn = try store.beginWrite(.none);
        defer txn.abort();
        const vb = try key.valBytes(arena, .{ .long = 1 });
        for (c.rows) |top| try txn.putInTree(store.trees.hist(.eavt), try key.keyBytes(arena, .eavt, e, 100, vb, top), &.{});
        if (c.other) {
            const ob = try key.valBytes(arena, .{ .long = 2 });
            try txn.putInTree(store.trees.hist(.eavt), try key.keyBytes(arena, .eavt, e, 100, ob, .{ .t = 2, .added = true }), &.{});
            try txn.putInTree(store.trees.hist(.eavt), try key.keyBytes(arena, .eavt, e, 100, ob, .{ .t = 5, .added = false }), &.{});
        }
        const prefix = try key.prefixBytes(arena, .eavt, .{ .e = e });
        var m = try Store.mergedScan(txn, store.trees, .eavt, prefix, try key.successor(arena, prefix));
        const failed = while (true) {
            const r = m.next() catch |err| break err;
            if (r == null) break error.TestUnexpectedResult;
        };
        try testing.expect(failed == error.Corrupted);
    }
}

// ── db-values ────────────────────────────────────────────────────

test "a released connection reopens in its own struct; db-values of its earlier life stay closed" {
    const tc = try TestConn.init("db_reopen");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const old = try tc.conn.db();
    try tc.conn.release();
    const before = tc.conn;
    try tc.conn.reopen(tc.td.path.ptr, .{ .sync = .none });
    try testing.expectEqual(before, tc.conn);
    try testing.expectError(error.Closed, old.datoms(arena, .eavt, .{ .e = boot.doc }));
    try testing.expectEqual(@as(usize, 3), (try (try tc.conn.db()).datoms(arena, .eavt, .{ .e = boot.doc })).len);
}

test "a connection creates a new store file at the store's initial map size" {
    const tc = try TestConn.init("db_map_size");
    defer tc.deinit();
    try testing.expectEqual(store_mod.db_layer.initial_map_size, tc.conn.store.file.env.info().mapSize);
}

test "db at bootstrap: datoms, entity, entid, ident, tx-range" {
    const tc = try TestConn.init("db_boot");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const db = try tc.conn.db();
    try testing.expectEqual(@as(u64, 1), db.basis);

    // Every view of the bootstrap agrees on :db/ident's datoms.
    const cur = try db.datoms(arena, .eavt, .{ .e = boot.ident });
    try testing.expectEqual(@as(usize, 5), cur.len);
    const old = try db.asOf(1).datoms(arena, .eavt, .{ .e = boot.ident });
    try testing.expectEqual(@as(usize, 5), old.len);
    const none = try db.asOf(0).datoms(arena, .eavt, .{ .e = boot.ident });
    try testing.expectEqual(@as(usize, 0), none.len);
    const hist = try db.withHistory().datoms(arena, .eavt, .{ .e = boot.ident });
    try testing.expectEqual(@as(usize, 5), hist.len);
    for (cur, old, hist) |a, b, c| {
        try testing.expect(a.eqlFact(b) and b.eqlFact(c));
        try testing.expectEqual(@as(u64, 1), a.t);
        try testing.expect(a.added and c.added);
    }
    const since = try db.sinceT(1).datoms(arena, .eavt, .{ .e = boot.ident });
    try testing.expectEqual(@as(usize, 0), since.len);
    const since0 = try db.sinceT(0).datoms(arena, .eavt, .{ .e = boot.ident });
    try testing.expectEqual(@as(usize, 5), since0.len);

    // Filter after a gap: eavt with only `a` bound scans everything and keeps one attribute.
    const only_type = try db.datoms(arena, .eavt, .{ .a = boot.value_type });
    try testing.expectEqual(@as(usize, boot.attrs.len), only_type.len);

    // AVET on :db/ident with a value bound.
    const vb = try key.valBytes(arena, .{ .keyword = boot.doc });
    const hit = try db.datoms(arena, .avet, .{ .a = boot.ident, .v = vb });
    try testing.expectEqual(@as(usize, 1), hit.len);
    try testing.expectEqual(@as(u64, boot.doc), hit[0].e);

    // entity: current, as-of and since views; never a history view.
    const ent = try db.entity(arena, boot.tx_instant);
    try testing.expectEqual(@as(usize, 4), ent.len);
    try testing.expectEqual(boot.ident, ent[0].a);
    try testing.expectEqual(@as(u32, boot.tx_instant), ent[0].vals[0].keyword);
    try testing.expectError(error.HistoryView, db.withHistory().entity(arena, boot.tx_instant));

    // entid / ident
    const k_doc = try tc.interner.internKeyword("db/doc");
    try testing.expectEqual(@as(?u64, boot.doc), try db.entid(arena, .{ .ident = k_doc }));
    const k_nope = try tc.interner.internKeyword("nope/nope");
    try testing.expect((try db.entid(arena, .{ .ident = k_nope })) == null);
    try testing.expectEqual(@as(?u64, boot.doc), try db.entid(arena, .{ .lookup = .{ .a = boot.ident, .v = .{ .keyword = boot.doc } } }));
    try testing.expectError(error.TxData, db.entid(arena, .{ .lookup = .{ .a = boot.doc, .v = .{ .string = "x" } } }));
    try testing.expectEqual(@as(?u32, k_doc), try db.ident(arena, boot.doc));
    try testing.expect((try db.ident(arena, 1 << 40)) == null);
    try testing.expect((try db.asOf(0).entid(arena, .{ .ident = k_doc })) == null);

    // attr as-of
    try testing.expect((try db.attr(boot.ident)).?.indexed);
    try testing.expect((try db.asOf(0).attr(boot.ident)) == null);

    // tx-range
    const entries = try txRange(tc.conn, arena, 0, null);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(@as(u64, 1), entries[0].t);
    try testing.expect(entries[0].datoms.len > boot.idents.len);
    try testing.expect(entries[0].instant > 0);
    const empty = try txRange(tc.conn, arena, 2, null);
    try testing.expectEqual(@as(usize, 0), empty.len);

    // A closed connection refuses every operation.
    try tc.conn.release();
    try testing.expectError(error.Closed, db.datoms(arena, .eavt, .{ .e = 1 }));
    try testing.expectError(error.Closed, tc.conn.db());
}

test "a bounded scan seeks to its start and stops at its end, on every view" {
    const tc = try TestConn.init("db_scan_range");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const db = try tc.conn.db();

    // AVET of :db/ident is keyed by ident id: [doc, type_double) holds
    // doc, txInstant and type_long.
    const abuf = try key.prefixBytes(arena, .avet, .{ .a = boot.ident });
    const lo = try key.prefixBytes(arena, .avet, .{ .a = boot.ident, .v = try key.valBytes(arena, .{ .keyword = boot.doc }) });
    const hi = try key.prefixBytes(arena, .avet, .{ .a = boot.ident, .v = try key.valBytes(arena, .{ .keyword = boot.type_double }) });
    for ([_]DbValue{ db, db.asOf(1) }) |view| {
        var rd = try view.beginRead();
        defer rd.close();
        var it = try rd.scanRange(arena, .avet, lo, hi);
        var seen: [3]u64 = undefined;
        var n: usize = 0;
        while (try it.next()) |d| : (n += 1) seen[n] = d.e;
        try testing.expectEqual(@as(usize, 3), n);
        try testing.expectEqualSlices(u64, &.{ boot.doc, boot.tx_instant, boot.type_long }, &seen);
        // An open end runs to the attribute's last key and past it.
        var open = try rd.scanRange(arena, .avet, lo, (try key.successor(arena, abuf)).?);
        var m: usize = 0;
        while (try open.next()) |_| m += 1;
        try testing.expectEqual(@as(usize, boot.idents.len - boot.doc + 1), m);
    }
}

test "a txlog key past the id range is corrupt, not a crash" {
    const tc = try TestConn.init("db_txlog_corrupt");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    {
        const txn = try tc.conn.store.beginWrite(.none);
        errdefer txn.abort();
        try txn.putInTree(tc.conn.store.trees.txlog, &@as([key.id_len]u8, @splat(0xFF)), &.{});
        try txn.commit();
    }
    try testing.expectError(error.Corrupted, txRange(tc.conn, arena_state.allocator(), 1, null));
}

test "basis in the future is refused" {
    const tc = try TestConn.init("db_future");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var db = try tc.conn.db();
    db.basis = 99;
    try testing.expectError(error.BasisInFuture, db.datoms(arena, .eavt, .{ .e = 1 }));
}

test "a t out of its range in a current row or a txlog key is Corrupted" {
    const tc = try TestConn.init("db_t_range");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const store = tc.conn.store;
    // A current EAVT row of :db/doc whose `t` is 2^46 | 1, and a txlog
    // key 2^46 | 2: both pass the id range, neither is a `t`.
    {
        const txn = try store.beginWrite(.none);
        errdefer txn.abort();
        const k = try key.keyBytes(arena, .eavt, boot.doc, boot.ident, try key.valBytes(arena, .{ .keyword = boot.doc }), null);
        // 2^46 | 1 as a LEB128: seven groups of seven bits.
        try txn.putInTree(store.trees.cur(.eavt), k, &.{ 0x81, 0x80, 0x80, 0x80, 0x80, 0x80, 0x10 });
        var kb: [key.ordered_max]u8 = undefined;
        try txn.putInTree(store.trees.txlog, key.writeOrdered(&kb, key.tx_partition_bit | 2), (try store.getTxlog(txn, 1)).?);
        try store.commit(txn);
    }
    const db = try tc.conn.db();
    try testing.expectError(error.Corrupted, db.datoms(arena, .eavt, .{ .e = boot.doc }));
    try testing.expectError(error.Corrupted, txRange(tc.conn, arena, 0, null));
}

test "a VAET component must be a ref value" {
    const tc = try TestConn.init("db_vaet_value");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const db = try tc.conn.db();
    const sb = try key.valBytes(arena, .{ .string = "x" });
    try testing.expectError(error.ValueType, db.datoms(arena, .vaet, .{ .v = sb }));
    try testing.expectError(error.ValueType, key.prefixBytes(arena, .vaet, .{ .v = sb }));
    try testing.expectError(error.ValueType, key.keyBytes(arena, .vaet, 1, 2, sb, null));
    try testing.expectError(error.ValueType, key.prefixBytes(arena, .vaet, .{ .v = "" }));
    // A ref value scans; the other indexes take any value.
    const rb = try key.valBytes(arena, .{ .ref = 1 });
    _ = try db.datoms(arena, .vaet, .{ .v = rb });
    _ = try db.datoms(arena, .avet, .{ .a = 1, .v = sb });
}

test "materialise every value kind into a heap" {
    const tc = try TestConn.init("db_mat");
    defer tc.deinit();
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const txn = try tc.conn.store.beginRead();
    defer txn.abort();
    const conn = tc.conn;
    try testing.expect((try conn.valToValue(txn, &heap, .{ .boolean = true })).asBool());
    try testing.expectEqual(@as(i64, -3), (try conn.valToValue(txn, &heap, .{ .long = -3 })).asFixnum());
    try testing.expectEqual(@as(f64, 1.5), (try conn.valToValue(txn, &heap, .{ .double = 1.5 })).asFloat());
    try testing.expectEqual(@as(i64, 7), (try conn.valToValue(txn, &heap, .{ .instant = 7 })).asFixnum());
    try testing.expectEqual(@as(i64, 1 << 40), (try conn.valToValue(txn, &heap, .{ .ref = 1 << 40 })).asFixnum());
    const many = try conn.valToValue(txn, &heap, .{ .keyword = boot.card_many });
    try testing.expectEqualStrings("db.cardinality/many", tc.interner.keywordName(many.asKeywordId()));
    const s = try conn.valToValue(txn, &heap, .{ .string = "hi" });
    try testing.expectEqualStrings("hi", string_mod.asBytes(s));
    const u = try conn.valToValue(txn, &heap, .{ .uuid = @splat(0) });
    try testing.expectEqualStrings("00000000-0000-0000-0000-000000000000", string_mod.asBytes(u));
    const b = try conn.valToValue(txn, &heap, .{ .bytes = "\x00\x01" });
    try testing.expectEqualStrings("\x00\x01", string_mod.asBytes(b));
}

test "every operation on a closed connection is error.Closed" {
    const tc = try TestConn.init("db_closed");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const db = try tc.conn.db();
    const views = [_]DbValue{ db, db.asOf(1), db.sinceT(0), db.withHistory() };
    try tc.conn.release();
    try tc.conn.release();
    tc.conn.close();
    try testing.expect(!tc.conn.is_open and tc.conn.store_closed);
    try testing.expectError(error.Closed, tc.conn.db());
    try testing.expectError(error.Closed, tc.conn.sync());
    try testing.expectError(error.Closed, txRange(tc.conn, arena, 0, null));
    for (views) |v| {
        try testing.expectError(error.Closed, v.beginRead());
        try testing.expectError(error.Closed, v.datoms(arena, .eavt, .{ .e = 1 }));
        if (!v.history) try testing.expectError(error.Closed, v.entity(arena, 1));
        try testing.expectError(error.Closed, v.entid(arena, .{ .eid = 1 }));
        try testing.expectError(error.Closed, v.entid(arena, .{ .lookup = .{ .a = boot.ident, .v = .{ .keyword = boot.doc } } }));
        try testing.expectError(error.Closed, v.ident(arena, boot.doc));
        try testing.expectError(error.Closed, v.attr(boot.ident));
    }
}

test "close waits for operations in flight; release refuses them" {
    const tc = try TestConn.init("db_busy");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const db = try tc.conn.db();

    var rd = try db.beginRead();
    try testing.expectEqual(@as(u32, 1), tc.conn.busy);
    try testing.expectError(error.Busy, tc.conn.release());
    try testing.expect(tc.conn.is_open);
    // close marks the connection closed at once and keeps the store until
    // the read ends, so its cursors stay valid.
    tc.conn.close();
    try testing.expect(!tc.conn.is_open);
    try testing.expect(tc.conn.close_pending);
    try testing.expectError(error.Closed, tc.conn.db());
    try testing.expectError(error.Closed, db.datoms(arena, .eavt, .{ .e = 1 }));
    var it = try rd.scan(arena, .eavt, .{ .e = boot.ident });
    var n: usize = 0;
    while (try it.next()) |_| n += 1;
    try testing.expectEqual(@as(usize, 5), n);
    rd.close();
    try testing.expectEqual(@as(u32, 0), tc.conn.busy);
    try testing.expect(!tc.conn.close_pending);
    try testing.expect(tc.conn.store_closed);
    try tc.conn.release();
}
