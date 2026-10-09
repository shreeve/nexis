//! test/integration/nextomic_fn.zig — transaction functions,
//! `:db.fn/cas`, schema alteration, excision and full-text through the
//! shared fixture (NEXTOMIC.md §3, §4, §5).
//!
//! Tx-data is read from source text, the functions a `:db.fn/call`
//! names live in `nextomic_fx.zig`, and every case checks the report's
//! datoms and the state the next db-value sees.

const std = @import("std");
const nx = @import("nexis");
const nextomic = nx.nextomic;
const value = nx.value;

const testing = std.testing;
const Value = value.Value;
const Fault = nextomic.db.Fault;

const Fx = @import("nextomic_fx.zig").Fx;
const harness = @import("harness");

fn loadPeople(fx: *Fx) !u64 {
    _ = try fx.transact(
        \\[{:db/ident :person/name :db/valueType :db.type/string :db/cardinality :db.cardinality/one}
        \\ {:db/ident :person/email :db/valueType :db.type/string :db/cardinality :db.cardinality/one :db/unique :db.unique/identity}
        \\ {:db/ident :person/age :db/valueType :db.type/long :db/cardinality :db.cardinality/one}
        \\ {:db/ident :person/tags :db/valueType :db.type/keyword :db/cardinality :db.cardinality/many}]
    );
    const r = try fx.transact("[{:db/id \"ann\" :person/name \"Ann\" :person/email \"ann@x\" :person/age 30}]");
    return r.tempids[0].eid;
}

/// The datoms of `report` other than `:db/txInstant`.
fn facts(report: nextomic.Report) []const nextomic.Datom {
    return report.tx_data[0 .. report.tx_data.len - 1];
}

test "a call's tx-data takes its place; nested calls see one db-before" {
    const fx = try Fx.init("fn_call");
    defer fx.deinit();
    const ann = try loadPeople(fx);
    const a = fx.arena();
    var fault: Fault = .{};
    const age = blk: {
        const txn = try fx.conn().store.beginRead();
        defer txn.abort();
        break :blk (try fx.conn().idents.idOfName(txn, "person/age")).?;
    };

    // The datoms land where the form was, after the surrounding forms before it.
    const r1 = try fx.transactFn(try a.print("[[:db/add {d} :person/name \"Anne\"] [:db.fn/call bump-age {d} 5] [:db/add {d} :person/tags :x]]", .{ ann, ann, ann }), &fault);
    try testing.expectEqual(@as(usize, 5), facts(r1).len);
    try testing.expectEqual(age, facts(r1)[2].a);
    try testing.expect(!facts(r1)[2].added);
    try testing.expectEqual(@as(i64, 35), facts(r1)[3].v.long);
    const after1 = try fx.pullSrc(try fx.db(), "[:person/age]", try a.print("{d}", .{ann}));
    try testing.expectEqual(@as(i64, 35), (try fx.getName(after1, "person/age")).?.asFixnum());

    // Two nested bumps read the same db-before, so they claim one value.
    const r2 = try fx.transactFn(try a.print("[[:db.fn/call twice {d}]]", .{ann}), &fault);
    try testing.expectEqual(@as(usize, 2), facts(r2).len);
    try testing.expectEqual(@as(i64, 36), facts(r2)[1].v.long);

    // Nil is no tx-data; the depth bound stops a runaway; a value in
    // function position that is not callable is malformed.
    const r3 = try fx.transactFn("[[:db.fn/call nothing]]", &fault);
    try testing.expectEqual(@as(usize, 0), facts(r3).len);
    try testing.expectError(error.TxFn, fx.transactFn("[[:db.fn/call forever]]", &fault));
    try testing.expect(fault.message != null);
    try testing.expectError(error.TxData, fx.transactFn("[[:db.fn/call \"bump-age\"]]", &fault));
    try testing.expectError(error.TxFn, fx.transact("[[:db.fn/call nothing]]"));
    try testing.expectEqual(r3.t, (try fx.db()).basis);
}

test "cas swaps on a match and names the mismatch" {
    const fx = try Fx.init("fn_cas");
    defer fx.deinit();
    const ann = try loadPeople(fx);
    const a = fx.arena();
    var fault: Fault = .{};

    const r1 = try fx.transactFn(try a.print("[[:db.fn/cas {d} :person/age 30 31]]", .{ann}), &fault);
    try testing.expectEqual(@as(usize, 2), facts(r1).len);
    try testing.expectEqual(@as(i64, 31), facts(r1)[1].v.long);
    try testing.expectError(error.Cas, fx.transactFn(try a.print("[[:db.fn/cas {d} :person/age 30 32]]", .{ann}), &fault));
    try testing.expectEqual(@as(i64, 30), fault.cas.?.expected.?.long);
    try testing.expectEqual(@as(i64, 31), fault.cas.?.actual.?.long);
    try testing.expectEqual(try fx.kwId("person/age"), fault.attr.?.asKeywordId());
    try testing.expectError(error.Cas, fx.transactFn(try a.print("[[:db.fn/cas {d} :person/age nil 32]]", .{ann}), &fault));
    try testing.expect(fault.cas.?.expected == null);
    // Absent attribute, nil expected: asserted; card-many refused.
    const r2 = try fx.transactFn("[[:db.fn/cas \"bob\" :person/age nil 7]]", &fault);
    try testing.expectEqual(@as(i64, 7), facts(r2)[0].v.long);
    try testing.expectError(error.TxData, fx.transactFn(try a.print("[[:db.fn/cas {d} :person/tags nil :x]]", .{ann}), &fault));
    // A cas inside a call form.
    try testing.expectError(error.Cas, fx.transactFn(try a.print("[[:db.fn/cas {d} :person/age 31 33] [:db.fn/cas {d} :person/age 31 34]]", .{ ann, ann }), &fault));
    try testing.expectEqual(@as(u64, r2.t), (try fx.db()).basis);
}

test "a renamed attribute answers to its new ident in every view and query" {
    const fx = try Fx.init("fn_rename");
    defer fx.deinit();
    const ann = try loadPeople(fx);
    const a = fx.arena();
    const before = try fx.db();

    const r = try fx.transact("[[:db/add :person/name :db/ident :person/full-name]]");
    try testing.expectEqual(@as(usize, 0), facts(r).len);
    const after = try fx.db();
    const eid = try a.print("{d}", .{ann});
    // pull and q spell the new name; the old one is unknown.
    const pulled = try fx.pullSrc(after, "[:person/full-name]", eid);
    try testing.expectEqualStrings("Ann", nx.string.asBytes((try fx.getName(pulled, "person/full-name")).?));
    const old_view = try fx.pullSrc(before, "[*]", eid);
    try testing.expect((try fx.getName(old_view, "person/full-name")) != null);
    try testing.expect((try fx.getName(old_view, "person/name")) == null);
    const rows = try fx.q(after, "[:find ?n :where [?e :person/full-name ?n]]");
    try testing.expectEqual(@as(usize, 1), nx.champ.setCount(rows));
    try testing.expectError(error.UnknownAttribute, fx.q(after, "[:find ?n :where [?e :person/name ?n]]"));
    try testing.expectError(error.UnknownAttribute, fx.transact("[[:db/add \"x\" :person/name \"X\"]]"));
    // The txlog entry written under the old name decodes.
    const entries = try nextomic.db.txRange(fx.conn(), a, 2, 3);
    try testing.expect(entries[0].datoms.len > 0);
}

test "cardinality changes apply from the next transaction and keep their history" {
    const fx = try Fx.init("fn_card");
    defer fx.deinit();
    const ann = try loadPeople(fx);
    const a = fx.arena();
    const eid = try a.print("{d}", .{ann});
    var fault: Fault = .{};

    const one = try fx.db();
    _ = try fx.transact("[[:db/add :person/name :db/cardinality :db.cardinality/many]]");
    _ = try fx.transact(try a.print("[[:db/add {d} :person/name \"Annie\"]]", .{ann}));
    const many = try fx.db();
    const both = try fx.pullSrc(many, "[:person/name]", eid);
    try testing.expectEqual(@as(usize, 2), nx.vector.count((try fx.getName(both, "person/name")).?));
    // The basis before the change still reads a scalar.
    const single = try fx.pullSrc(one, "[:person/name]", eid);
    try testing.expectEqualStrings("Ann", nx.string.asBytes((try fx.getName(single, "person/name")).?));
    const single_as_of = try fx.pullSrc(many.asOf(one.basis), "[:person/name]", eid);
    try testing.expectEqualStrings("Ann", nx.string.asBytes((try fx.getName(single_as_of, "person/name")).?));

    // Back to one: refused while two values stand, then allowed.
    try testing.expectError(error.Schema, fx.transactFn("[[:db/add :person/name :db/cardinality :db.cardinality/one]]", &fault));
    try testing.expectEqual(@as(?u64, ann), fault.e);
    _ = try fx.transact(try a.print("[[:db/retract {d} :person/name \"Ann\"] [:db/add :person/name :db/cardinality :db.cardinality/one]]", .{ann}));
    const back = try fx.db();
    const name = blk: {
        const txn = try fx.conn().store.beginRead();
        defer txn.abort();
        break :blk (try fx.conn().idents.idOfName(txn, "person/name")).?;
    };
    try testing.expect(!(try back.attr(name)).?.many());
    try testing.expect((try many.attr(name)).?.many());
    const now = try fx.pullSrc(back, "[:person/name]", eid);
    try testing.expectEqualStrings("Annie", nx.string.asBytes((try fx.getName(now, "person/name")).?));
    const then = try fx.pullSrc(many.asOf(many.basis), "[:person/name]", eid);
    try testing.expectEqual(@as(usize, 2), nx.vector.count((try fx.getName(then, "person/name")).?));
}

test "a flag declared false turns true later; a component flag reads as each view saw it" {
    const fx = try Fx.init("fn_flags");
    defer fx.deinit();
    const a = fx.arena();
    var fault: Fault = .{};
    _ = try fx.transact(
        \\[{:db/ident :t/name :db/valueType :db.type/string :db/cardinality :db.cardinality/one :db/index false :db/fulltext false}
        \\ {:db/ident :t/home :db/valueType :db.type/ref :db/cardinality :db.cardinality/one :db/isComponent true}
        \\ {:db/ident :t/city :db/valueType :db.type/string :db/cardinality :db.cardinality/one}]
    );
    const r = try fx.transact("[{:db/id \"p\" :t/name \"Red Plum\" :t/home {:t/city \"Oslo\"}}]");
    const p = try a.print("{d}", .{r.tempids[0].eid});
    const before = try fx.db();
    const name = blk: {
        const txn = try fx.conn().store.beginRead();
        defer txn.abort();
        break :blk (try fx.conn().idents.idOfName(txn, "t/name")).?;
    };

    // `false` to `true` is the flag's arrival: AVET and the tokens tree
    // are backfilled. Retracting `true` stays refused.
    _ = try fx.transact("[[:db/add :t/name :db/index true] [:db/add :t/name :db/fulltext true]]");
    const flagged = try fx.db();
    try testing.expect((try flagged.attr(name)).?.indexed);
    try testing.expect((try flagged.attr(name)).?.fulltext);
    try testing.expect(!(try flagged.asOf(before.basis).attr(name)).?.indexed);
    try testing.expectEqual(@as(usize, 1), (try flagged.datoms(a, .avet, .{ .a = name })).len);
    try testing.expectEqual(@as(usize, 1), count(try fx.q(flagged, "[:find ?e :where [(fulltext $ :t/name \"plum\") [[?e ?v]]]]")));
    try testing.expectError(error.Conflict, fx.transact("[[:db/retract :t/name :db/index true]]"));
    try testing.expectError(error.Conflict, fx.transact("[[:db/add :t/name :db/fulltext false]]"));

    // `:db/isComponent true` takes a ref attribute only.
    try testing.expectError(error.Schema, fx.transactFn("[[:db/add :t/city :db/isComponent true]]", &fault));
    try testing.expect(fault.attr != null);
    try testing.expectError(error.Schema, fx.transact("[{:db/ident :t/n :db/valueType :db.type/long :db/cardinality :db.cardinality/one :db/isComponent true}]"));

    // A component flag cleared later: a view before the change still
    // pulls the component whole, the current view pulls a ref.
    _ = try fx.transact("[[:db/add :t/home :db/isComponent false]]");
    const later = try fx.db();
    const then = (try fx.getName(try fx.pullSrc(later.asOf(before.basis), "[:t/home]", p), "t/home")).?;
    try testing.expect((try fx.getName(then, "t/city")) != null);
    const now = (try fx.getName(try fx.pullSrc(later, "[:t/home]", p), "t/home")).?;
    try testing.expect((try fx.getName(now, "t/city")) == null);
}

test "excision empties the entity for pull and q on every view, and tx-range replays without it" {
    const fx = try Fx.init("fn_excise");
    defer fx.deinit();
    const ann = try loadPeople(fx);
    const a = fx.arena();
    const eid = try a.print("{d}", .{ann});
    _ = try fx.transact(try a.print("[[:db/add {d} :person/tags :red] [:db/add {d} :person/tags :blue] {{:db/id \"bob\" :person/name \"Bob\" :person/email \"bob@x\"}}]", .{ ann, ann }));
    const before = try fx.db();
    const hist = before.withHistory();

    const x = try nextomic.transact.excise(fx.conn(), a, try fx.read(eid), try fx.kw("person/tags"), .{});
    try testing.expectEqual(@as(u64, 2), x.removed);
    const mid = try fx.db();
    const pulled = try fx.pullSrc(mid, "[*]", eid);
    try testing.expect((try fx.getName(pulled, "person/tags")) == null);
    try testing.expect((try fx.getName(pulled, "person/name")) != null);
    const pulled_before = try fx.pullSrc(before, "[*]", eid);
    try testing.expect((try fx.getName(pulled_before, "person/tags")) == null);
    try testing.expectEqual(@as(usize, 0), nx.champ.setCount(try fx.q(hist, "[:find ?t :where [?e :person/tags ?t]]")));

    const y = try nextomic.transact.excise(fx.conn(), a, try fx.read("[:person/email \"ann@x\"]"), null, .{});
    try testing.expectEqual(@as(u64, 3), y.removed);
    const after = try fx.db();
    try testing.expect((try fx.pullSrc(after, "[*]", eid)).isNil());
    try testing.expect((try fx.pullSrc(before, "[*]", eid)).isNil());
    try testing.expectEqual(@as(usize, 1), nx.champ.setCount(try fx.q(after, "[:find ?n :where [?e :person/name ?n]]")));
    try testing.expectEqual(@as(usize, 1), nx.champ.setCount(try fx.q(after.withHistory(), "[:find ?n :where [?e :person/name ?n]]")));
    // The log replays without Ann; the entries that held her are marked.
    const log = try nextomic.db.txRange(fx.conn(), a, 3, null);
    var marked: usize = 0;
    for (log) |entry| {
        for (entry.datoms) |d| try testing.expect(d.e != ann);
        if (entry.excised.len > 0) marked += 1;
    }
    try testing.expectEqual(@as(usize, 4), marked);
    try testing.expectEqual(y.report.t, (try fx.db()).basis);
}

test "excision removes an entity's whole history, current facts and retired ones alike, and marks every entry that held it" {
    const fx = try Fx.init("fn_excise_rows");
    defer fx.deinit();
    const ann = try loadPeople(fx);
    const a = fx.arena();
    // Di's facts are all current; Cy's name is retired twice over, so
    // only history rows hold it; Ann has both.
    const r_di = try fx.transact("[{:db/id \"di\" :person/name \"Di\" :person/email \"di@x\" :person/age 40}]");
    const di = r_di.tempids[0].eid;
    const r_cy = try fx.transact("[{:db/id \"cy\" :person/name \"C1\" :person/email \"cy@x\"}]");
    const cy = r_cy.tempids[0].eid;
    const t_c2 = (try fx.transact("[[:db/add [:person/email \"cy@x\"] :person/name \"C2\"] [:db/add [:person/email \"ann@x\"] :person/age 31]]")).t;
    const t_gone = (try fx.transact("[[:db/retract [:person/email \"cy@x\"] :person/name \"C2\"]]")).t;

    const di_x = try nextomic.transact.excise(fx.conn(), a, try fx.read(try a.print("{d}", .{di})), null, .{});
    try testing.expectEqual(@as(u64, 3), di_x.removed);
    const cy_x = try nextomic.transact.excise(fx.conn(), a, try fx.read(try a.print("{d}", .{cy})), try fx.kw("person/name"), .{});
    try testing.expectEqual(@as(u64, 4), cy_x.removed);
    // Ann: her name and email, her age 30 asserted and retracted, and
    // her age 31.
    const ann_x = try nextomic.transact.excise(fx.conn(), a, try fx.read(try a.print("{d}", .{ann})), null, .{});
    try testing.expectEqual(@as(u64, 5), ann_x.removed);

    const now = try fx.db();
    for ([_]nextomic.DbValue{ now, now.asOf(t_c2), now.withHistory(), now.sinceT(0) }) |view| {
        for ([_][]const u8{ "Ann", "Di", "C1", "C2" }) |name| {
            try testing.expectEqual(@as(usize, 0), count(try fx.q(view, try a.print("[:find ?e :where [?e :person/name \"{s}\"]]", .{name}))));
        }
        try testing.expectEqual(@as(usize, 0), count(try fx.q(view, "[:find ?a :where [?e :person/age ?a]]")));
    }
    // Cy keeps her email; every entry that held an excised datom, and
    // each excising transaction's own, carries its entity.
    try testing.expectEqual(@as(usize, 1), count(try fx.q(now, "[:find ?e :where [?e :person/email \"cy@x\"]]")));
    const log = try nextomic.db.txRange(fx.conn(), a, 1, null);
    for (log) |entry| {
        var held = false;
        for (entry.datoms) |d| {
            try testing.expect(d.e != ann and d.e != di);
            if (d.v == .string) try testing.expect(!std.mem.eql(u8, d.v.string, "C1") and !std.mem.eql(u8, d.v.string, "C2"));
        }
        for (entry.excised) |e| {
            if (e == cy) held = held or entry.t == r_cy.t or entry.t == t_c2 or entry.t == t_gone or entry.t == cy_x.report.t;
            if (e == di) held = held or entry.t == r_di.t or entry.t == di_x.report.t;
            if (e == ann) held = true;
        }
        const must = entry.t == r_di.t or entry.t == r_cy.t or entry.t == t_c2 or entry.t == t_gone or entry.t == di_x.report.t or entry.t == cy_x.report.t or entry.t == ann_x.report.t;
        if (must) try testing.expect(held);
    }
}

/// The rows of the tokens tree.
fn tokenRows(fx: *Fx) !usize {
    const store = fx.conn().store;
    const txn = try store.beginRead();
    defer txn.abort();
    var s = try nextomic.Store.scan(txn, store.trees.fulltext, &.{});
    var n: usize = 0;
    while (try s.next()) |_| n += 1;
    return n;
}

fn count(v: Value) usize {
    return nx.champ.setCount(v);
}

test "full-text stays in step under assert, retract, backfill and excision" {
    const fx = try Fx.init("fn_fulltext");
    defer fx.deinit();
    const a = fx.arena();
    try testing.expectEqual(@as(usize, 0), try tokenRows(fx));

    _ = try fx.transact(
        \\[{:db/ident :doc/n :db/valueType :db.type/long :db/cardinality :db.cardinality/one}
        \\ {:db/ident :doc/title :db/valueType :db.type/string :db/cardinality :db.cardinality/one :db/fulltext true}
        \\ {:db/ident :doc/body :db/valueType :db.type/string :db/cardinality :db.cardinality/many}]
    );
    const r = try fx.transact(
        \\[{:db/id "a" :doc/n 1 :doc/title "Red Apple Pie" :doc/body ["sweet red filling" "flaky crust"]}
        \\ {:db/id "b" :doc/n 2 :doc/title "Green apple" :doc/body ["tart"]}]
    );
    const doc_a = r.tempids[0].eid;
    const eid = try a.print("{d}", .{doc_a});
    // "red apple pie" → red, apple, pie; "green apple" → green, apple.
    try testing.expectEqual(@as(usize, 5), try tokenRows(fx));
    const titled = try fx.db();
    try testing.expectEqual(@as(usize, 1), count(try fx.q(titled, "[:find ?n :where [(fulltext $ :doc/title \"apple RED\") [[?e ?v]]] [?e :doc/n ?n]]")));
    try testing.expectEqual(@as(usize, 2), count(try fx.q(titled, "[:find ?n :where [(fulltext $ :doc/title \"apple\") [[?e ?v]]] [?e :doc/n ?n]]")));
    try testing.expectEqual(@as(usize, 0), count(try fx.q(titled, "[:find ?n :where [(fulltext $ :doc/title \"apple plum\") [[?e ?v]]] [?e :doc/n ?n]]")));
    try testing.expectError(error.TxData, fx.q(titled, "[:find ?v :where [(fulltext $ :doc/body \"red\") [[?e ?v]]]]"));
    try testing.expectError(error.Schema, fx.transact("[[:db/add :doc/n :db/fulltext true]]"));

    // The flag's arrival backfills every current value of the attribute.
    _ = try fx.transact("[[:db/add :doc/body :db/fulltext true]]");
    try testing.expectEqual(@as(usize, 11), try tokenRows(fx));
    const backfilled = try fx.db();
    try testing.expectEqual(@as(usize, 1), count(try fx.q(backfilled, "[:find ?v :where [(fulltext $ :doc/body \"red\") [[?e ?v]]]]")));
    try testing.expectEqual(@as(usize, 1), count(try fx.q(backfilled, "[:find ?v :where [(fulltext $ :doc/body \"crust\") [[?e ?v]]]]")));
    // An earlier view does not know the flag.
    try testing.expectError(error.TxData, fx.q(titled, "[:find ?v :where [(fulltext $ :doc/body \"red\") [[?e ?v]]]]"));

    // Retracting one value of the many attribute leaves the other's rows.
    _ = try fx.transact(try a.print("[[:db/retract {d} :doc/body \"sweet red filling\"] [:db/add {d} :doc/title \"Red Plum Pie\"]]", .{ doc_a, doc_a }));
    try testing.expectEqual(@as(usize, 8), try tokenRows(fx));
    const retracted = try fx.db();
    try testing.expectEqual(@as(usize, 0), count(try fx.q(retracted, "[:find ?v :where [(fulltext $ :doc/body \"red\") [[?e ?v]]]]")));
    try testing.expectEqual(@as(usize, 1), count(try fx.q(retracted, "[:find ?v :where [(fulltext $ :doc/body \"crust\") [[?e ?v]]]]")));
    try testing.expectEqual(@as(usize, 1), count(try fx.q(retracted, "[:find ?v :where [(fulltext $ :doc/title \"plum\") [[?e ?v]]]]")));
    try testing.expectEqual(@as(usize, 1), count(try fx.q(retracted, "[:find ?v :where [(fulltext $ :doc/title \"apple\") [[?e ?v]]]]")));
    // Earlier and history views re-tokenise the values they hold.
    try testing.expectEqual(@as(usize, 1), count(try fx.q(backfilled, "[:find ?v :where [(fulltext $ :doc/body \"red\") [[?e ?v]]]]")));
    try testing.expectEqual(@as(usize, 2), count(try fx.q(retracted.withHistory(), "[:find ?v :where [(fulltext $ :doc/title \"red\") [[?e ?v]]]]")));
    try testing.expectEqual(@as(usize, 1), count(try fx.q(retracted.sinceT(backfilled.basis), "[:find ?v :where [(fulltext $ :doc/title \"plum\") [[?e ?v]]]]")));

    // Excision drops the entity's rows and only those.
    const x = try nextomic.transact.excise(fx.conn(), a, try fx.read(eid), null, .{});
    try testing.expect(x.removed > 0);
    try testing.expectEqual(@as(usize, 3), try tokenRows(fx));
    const excised = try fx.db();
    try testing.expectEqual(@as(usize, 0), count(try fx.q(excised, "[:find ?v :where [(fulltext $ :doc/body \"crust\") [[?e ?v]]]]")));
    try testing.expectEqual(@as(usize, 1), count(try fx.q(excised, "[:find ?v :where [(fulltext $ :doc/title \"apple\") [[?e ?v]]]]")));
    try testing.expectEqual(@as(usize, 0), count(try fx.q(backfilled, "[:find ?v :where [(fulltext $ :doc/body \"red\") [[?e ?v]]]]")));
}

test "full-text folds case across scripts" {
    const fx = try Fx.init("fn_fulltext_fold");
    defer fx.deinit();
    _ = try fx.transact(
        \\[{:db/ident :doc/title :db/valueType :db.type/string :db/cardinality :db.cardinality/one :db/fulltext true}
        \\ {:db/ident :doc/n :db/valueType :db.type/long :db/cardinality :db.cardinality/one}]
    );
    _ = try fx.transact(
        \\[{:db/id "a" :doc/title "Café au lait"} {:db/id "b" :doc/title "CAFÉ NOIR"}
        \\ {:db/id "c" :doc/title "ΣΟΦΙΑ"} {:db/id "d" :doc/title "σοφιας"} {:db/id "e" :doc/title "ПРИВЕТ мир"}]
    );
    // café au lait noir σοφια σοφιασ привет мир
    try testing.expectEqual(@as(usize, 9), try tokenRows(fx));
    const cases = [_]struct { needle: []const u8, hits: usize }{
        .{ .needle = "café", .hits = 2 },
        .{ .needle = "CAFÉ", .hits = 2 },
        .{ .needle = "Café Noir", .hits = 1 },
        .{ .needle = "σοφια", .hits = 1 },
        .{ .needle = "ΣΟΦΙΑΣ", .hits = 1 },
        .{ .needle = "привет", .hits = 1 },
        .{ .needle = "Мир", .hits = 1 },
    };
    const dbv = try fx.db();
    for (cases) |c| {
        errdefer std.debug.print("needle {s}\n", .{c.needle});
        const src = try fx.arena().print("[:find ?e :where [(fulltext $ :doc/title \"{s}\") [[?e ?v]]]]", .{c.needle});
        try testing.expectEqual(c.hits, count(try fx.q(dbv, src)));
    }
}

test "a store of another format is refused at connect, naming the format it holds" {
    var hs = try harness.Store.init("fn_format");
    defer hs.deinit();
    const path = try testing.allocator.dupeSentinel(u8, hs.path, 0);
    defer testing.allocator.free(path);
    (try nextomic.Store.open(testing.allocator, path.ptr, .{})).close();
    {
        // A store an earlier build wrote: its format number is 2.
        const file = try nx.db.StoreFile.acquire(path.ptr, .{ .allocator = testing.allocator });
        defer file.release();
        const txn = try file.beginWrite(.{});
        errdefer txn.abort();
        try txn.putInTree(try txn.openTree("nx/sys", false), "format", &.{ 0, 2 });
        try file.commit(txn);
    }
    var program: harness.Program = undefined;
    try program.init();
    defer program.deinit();
    const src = try hs.source(
        \\(let [e (try (nextomic/connect "@STORE@") (catch any e e))]
        \\  [(:error e) (:format e) (:message e)])
    );
    defer testing.allocator.free(src);
    try harness.expectResult(&program, src, try program.run(src), "[:db/corrupted 2 Nextomic store format 2; this build reads format 3. Recreate the store or re-import its data (docs/NEXTOMIC.md §2)]");
}

test "a lookup ref nested past the native stack is StackOverflow in tx-data and in every read" {
    const fx = try Fx.init("fn_deep_lookup");
    defer fx.deinit();
    _ = try fx.transact(
        \\[{:db/ident :n/parent :db/valueType :db.type/ref :db/cardinality :db.cardinality/one :db/unique :db.unique/identity}
        \\ {:db/ident :n/name :db/valueType :db.type/string :db/cardinality :db.cardinality/one :db/unique :db.unique/identity}]
    );
    // [:n/parent [:n/parent ... [:n/name "x"]]], a lookup ref whose value
    // is a lookup ref, 5000 deep.
    var v = try fx.read("[:n/name \"x\"]");
    const parent = try fx.kw("n/parent");
    for (0..5000) |_| v = try nx.vector.fromSlice(&fx.heap, &.{ parent, v });
    nx.stack.arm(64 * 1024);
    defer nx.stack.arm(nx.stack.main_thread_budget);
    const tx = try nx.vector.fromSlice(&fx.heap, &.{try nx.vector.fromSlice(&fx.heap, &.{ try fx.kw("db/add"), try fx.str("a"), parent, v })});
    try testing.expectError(error.StackOverflow, nextomic.transact.transact(fx.conn(), fx.arena(), tx, .{}));
    var rd = try (try fx.db()).beginRead();
    defer rd.close();
    var fault: Fault = .{};
    try testing.expectError(error.StackOverflow, nextomic.marshal.entity(&rd, fx.arena(), v, &fault));
}

fn tempidOf(r: nextomic.Report, name: []const u8) !u64 {
    for (r.tempids) |b| if (b.key == .string and std.mem.eql(u8, b.key.string, name)) return b.eid;
    return error.TestUnexpectedResult;
}

test "a lookup ref value upserts through any unique assertion of the transaction" {
    const fx = try Fx.init("fn_lookup_upsert");
    defer fx.deinit();
    const a = fx.arena();
    _ = try fx.transact(
        \\[{:db/ident :u/email :db/valueType :db.type/string :db/cardinality :db.cardinality/one :db/unique :db.unique/identity}
        \\ {:db/ident :u/alt :db/valueType :db.type/string :db/cardinality :db.cardinality/one :db/unique :db.unique/identity}
        \\ {:db/ident :u/code :db/valueType :db.type/string :db/cardinality :db.cardinality/one :db/unique :db.unique/value}
        \\ {:db/ident :u/key :db/valueType :db.type/ref :db/cardinality :db.cardinality/one :db/unique :db.unique/identity}
        \\ {:db/ident :u/n :db/valueType :db.type/long :db/cardinality :db.cardinality/one}]
    );
    const r = try fx.transact("[{:db/id \"x\" :u/email \"x\"} {:db/id \"y\" :u/key \"x\" :u/n 1}]");
    const x = try tempidOf(r, "x");
    const y = try tempidOf(r, "y");
    // The identity the lookup ref names is asserted on an explicit eid.
    const ra = try fx.transact(try a.print("[[:db/add {d} :u/alt \"alt\"] {{:db/id \"t\" :u/key [:u/alt \"alt\"] :u/n 2}}]", .{x}));
    try testing.expectEqual(y, try tempidOf(ra, "t"));
    // A unique value on a tempid that upserts through another identity.
    const rb = try fx.transact("[{:db/id \"w\" :u/email \"x\" :u/code \"cx\"} {:db/id \"t\" :u/key [:u/code \"cx\"] :u/n 4}]");
    try testing.expectEqual(x, try tempidOf(rb, "w"));
    try testing.expectEqual(y, try tempidOf(rb, "t"));
    // A unique value on a new entity: the claim on it is new too.
    const rc = try fx.transact("[{:db/id \"z\" :u/code \"c1\" :u/email \"z\"} {:db/id \"t\" :u/key [:u/code \"c1\"] :u/n 3}]");
    const z = try tempidOf(rc, "z");
    const t = try tempidOf(rc, "t");
    try testing.expect(z != x and z != y and t != x and t != y and t != z);
    const n = try fx.q(try fx.db(), "[:find ?n :where [?e :u/n ?n]]");
    try testing.expectEqual(@as(usize, 2), count(n));
}
