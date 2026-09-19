//! test/integration/nextomic_fn.zig — transaction functions,
//! `:db.fn/cas` and schema alteration through the shared fixture
//! (NEXTOMIC.md §3).
//!
//! Tx-data is read from source text, the functions a `:db.fn/call`
//! names live in `nextomic_fx.zig`, and every case checks the report's
//! datoms and the state the next db-value sees.

const std = @import("std");
const nextomic = @import("nextomic");
const value = @import("value");

const testing = std.testing;
const Value = value.Value;
const Fault = nextomic.db.Fault;
const boot = nextomic.boot;

const Fx = @import("nextomic_fx.zig").Fx;

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
    const r1 = try fx.transactFn(try std.fmt.allocPrint(a, "[[:db/add {d} :person/name \"Anne\"] [:db.fn/call bump-age {d} 5] [:db/add {d} :person/tags :x]]", .{ ann, ann, ann }), &fault);
    try testing.expectEqual(@as(usize, 5), facts(r1).len);
    try testing.expectEqual(age, facts(r1)[2].a);
    try testing.expect(!facts(r1)[2].added);
    try testing.expectEqual(@as(i64, 35), facts(r1)[3].v.long);
    const after1 = try fx.pullSrc(try fx.db(), "[:person/age]", try std.fmt.allocPrint(a, "{d}", .{ann}));
    try testing.expectEqual(@as(i64, 35), (try fx.getName(after1, "person/age")).?.asFixnum());

    // Two nested bumps read the same db-before, so they claim one value.
    const r2 = try fx.transactFn(try std.fmt.allocPrint(a, "[[:db.fn/call twice {d}]]", .{ann}), &fault);
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

    const r1 = try fx.transactFn(try std.fmt.allocPrint(a, "[[:db.fn/cas {d} :person/age 30 31]]", .{ann}), &fault);
    try testing.expectEqual(@as(usize, 2), facts(r1).len);
    try testing.expectEqual(@as(i64, 31), facts(r1)[1].v.long);
    try testing.expectError(error.Cas, fx.transactFn(try std.fmt.allocPrint(a, "[[:db.fn/cas {d} :person/age 30 32]]", .{ann}), &fault));
    try testing.expectEqual(@as(i64, 30), fault.cas.?.expected.?.long);
    try testing.expectEqual(@as(i64, 31), fault.cas.?.actual.?.long);
    try testing.expectEqual(try fx.kwId("person/age"), fault.attr.?.asKeywordId());
    try testing.expectError(error.Cas, fx.transactFn(try std.fmt.allocPrint(a, "[[:db.fn/cas {d} :person/age nil 32]]", .{ann}), &fault));
    try testing.expect(fault.cas.?.expected == null);
    // Absent attribute, nil expected: asserted; card-many refused.
    const r2 = try fx.transactFn("[[:db.fn/cas \"bob\" :person/age nil 7]]", &fault);
    try testing.expectEqual(@as(i64, 7), facts(r2)[0].v.long);
    try testing.expectError(error.TxData, fx.transactFn(try std.fmt.allocPrint(a, "[[:db.fn/cas {d} :person/tags nil :x]]", .{ann}), &fault));
    // A cas inside a call form.
    try testing.expectError(error.Cas, fx.transactFn(try std.fmt.allocPrint(a, "[[:db.fn/cas {d} :person/age 31 33] [:db.fn/cas {d} :person/age 31 34]]", .{ ann, ann }), &fault));
    try testing.expectEqual(@as(u64, r2.t), (try fx.db()).basis);
    _ = boot;
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
    const eid = try std.fmt.allocPrint(a, "{d}", .{ann});
    // pull and q spell the new name; the old one is unknown.
    const pulled = try fx.pullSrc(after, "[:person/full-name]", eid);
    try testing.expectEqualStrings("Ann", @import("string").asBytes((try fx.getName(pulled, "person/full-name")).?));
    const old_view = try fx.pullSrc(before, "[*]", eid);
    try testing.expect((try fx.getName(old_view, "person/full-name")) != null);
    try testing.expect((try fx.getName(old_view, "person/name")) == null);
    const rows = try fx.q(after, "[:find ?n :where [?e :person/full-name ?n]]");
    try testing.expectEqual(@as(usize, 1), @import("champ").setCount(rows));
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
    const eid = try std.fmt.allocPrint(a, "{d}", .{ann});
    var fault: Fault = .{};

    const one = try fx.db();
    _ = try fx.transact("[[:db/add :person/name :db/cardinality :db.cardinality/many]]");
    _ = try fx.transact(try std.fmt.allocPrint(a, "[[:db/add {d} :person/name \"Annie\"]]", .{ann}));
    const many = try fx.db();
    const both = try fx.pullSrc(many, "[:person/name]", eid);
    try testing.expectEqual(@as(usize, 2), @import("vector").count((try fx.getName(both, "person/name")).?));
    // The basis before the change still reads a scalar.
    const single = try fx.pullSrc(one, "[:person/name]", eid);
    try testing.expectEqualStrings("Ann", @import("string").asBytes((try fx.getName(single, "person/name")).?));
    const single_as_of = try fx.pullSrc(many.asOf(one.basis), "[:person/name]", eid);
    try testing.expectEqualStrings("Ann", @import("string").asBytes((try fx.getName(single_as_of, "person/name")).?));

    // Back to one: refused while two values stand, then allowed.
    try testing.expectError(error.Schema, fx.transactFn("[[:db/add :person/name :db/cardinality :db.cardinality/one]]", &fault));
    try testing.expectEqual(@as(?u64, ann), fault.e);
    _ = try fx.transact(try std.fmt.allocPrint(a, "[[:db/retract {d} :person/name \"Ann\"] [:db/add :person/name :db/cardinality :db.cardinality/one]]", .{ann}));
    const back = try fx.db();
    const name = blk: {
        const txn = try fx.conn().store.beginRead();
        defer txn.abort();
        break :blk (try fx.conn().idents.idOfName(txn, "person/name")).?;
    };
    try testing.expect(!(try back.attr(name)).?.many());
    try testing.expect((try many.attr(name)).?.many());
    const now = try fx.pullSrc(back, "[:person/name]", eid);
    try testing.expectEqualStrings("Annie", @import("string").asBytes((try fx.getName(now, "person/name")).?));
    const then = try fx.pullSrc(many.asOf(many.basis), "[:person/name]", eid);
    try testing.expectEqual(@as(usize, 2), @import("vector").count((try fx.getName(then, "person/name")).?));
}
