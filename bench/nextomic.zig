//! bench/nextomic.zig — the Nextomic corpora of `zig build bench`
//! (category `nextomic`, docs/PERF.md §3.7).
//!
//! Two stores built once per run and measured through the engine's
//! Zig API, not through the language: a 200k-datom employee store for
//! `q` (joins by department and by age, an aggregate over a hash join,
//! and one join from 1, 3 and 7 ages, either side of the nested-loop /
//! hash-join crossover) and a 20k-entity store for `pull`. Each row
//! runs once and checks how many rows it returns before it is timed,
//! so a timing never measures a wrong answer; the tests carry 10k-datom
//! twins of both (test/integration/nextomic_{q,pull}.zig).

const std = @import("std");
const nx = @import("nexis");
const bench = nx.bench;
const nextomic = nx.nextomic;
const value = nx.value;
const heap_mod = nx.heap;
const intern_mod = nx.intern;
const string_mod = nx.string;
const list_mod = nx.list;
const vector_mod = nx.vector;
const champ = nx.champ;
const dispatch = nx.dispatch;
const reader_mod = nx.reader;

const Allocator = std.mem.Allocator;
const Value = value.Value;
const query = nextomic.query;
const pull = nextomic.pull;

/// A connection over a store under `dir`, with the heap and arena the
/// queries build their values in.
const Fixture = struct {
    gpa: Allocator,
    interner: intern_mod.Interner,
    conn: *nextomic.Conn,
    heap: heap_mod.Heap,
    arena_state: std.heap.ArenaAllocator,

    fn init(self: *Fixture, gpa: Allocator, path: [:0]const u8) !void {
        self.gpa = gpa;
        self.interner = intern_mod.Interner.init(gpa);
        self.conn = try nextomic.Conn.open(gpa, &self.interner, path.ptr, .{ .sync = .none });
        self.heap = heap_mod.Heap.init(gpa);
        self.arena_state = std.heap.ArenaAllocator.init(gpa);
    }

    fn deinit(self: *Fixture) void {
        self.arena_state.deinit();
        self.heap.deinit();
        self.conn.destroy();
        self.interner.deinit();
    }

    fn arena(self: *Fixture) Allocator {
        return self.arena_state.allocator();
    }

    fn attr(self: *Fixture, name: []const u8) !u32 {
        const txn = try self.conn.store.beginRead();
        defer txn.abort();
        return (try self.conn.idents.idOfName(txn, name)).?;
    }

    /// One form of source text as a value.
    fn read(self: *Fixture, src: []const u8) !Value {
        var parsed = try reader_mod.parser.parseProgram(self.gpa, src);
        defer parsed.parser.deinit();
        var rdr = reader_mod.Reader.init(self.gpa, src);
        defer rdr.deinit();
        const forms = try rdr.readProgram(parsed.sexp);
        return self.formToValue(forms[0]);
    }

    fn formToValue(self: *Fixture, form: *const reader_mod.Form) anyerror!Value {
        const a = self.arena();
        return switch (form.datum) {
            .nil => value.nilValue(),
            .bool_ => |b| value.fromBool(b),
            .int => |n| value.fromFixnum(n).?,
            .string => |s| try string_mod.fromBytes(&self.heap, s),
            .keyword => |name| try self.interner.internKeywordValue(try joinName(a, name)),
            .symbol => |name| try self.interner.internSymbolValue(try joinName(a, name)),
            .list, .vector => |items| blk: {
                const vals = try a.alloc(Value, items.len);
                for (items, vals) |it, *v| v.* = try self.formToValue(it);
                break :blk if (form.datum == .list)
                    try list_mod.fromSlice(&self.heap, vals)
                else
                    try vector_mod.fromSlice(&self.heap, vals);
            },
            .map => |items| blk: {
                var m = try champ.mapEmpty(&self.heap);
                var i: usize = 0;
                while (i < items.len) : (i += 2) {
                    m = try champ.mapAssoc(&self.heap, m, try self.formToValue(items[i]), try self.formToValue(items[i + 1]), &dispatch.hashValue, &dispatch.equal);
                }
                break :blk m;
            },
            else => error.UnsupportedForm,
        };
    }

    fn joinName(a: Allocator, name: anytype) ![]const u8 {
        if (name.ns) |ns| return std.fmt.allocPrint(a, "{s}/{s}", .{ ns, name.name });
        return name.name;
    }

    fn transact(self: *Fixture, src: []const u8) !void {
        _ = try nextomic.transact.transact(self.conn, self.arena(), try self.read(src), .{});
    }

    /// Transact `n` departments named d0, d1, ...; their eids in order.
    fn departments(self: *Fixture, n: usize) ![]u64 {
        const a_dname = try self.attr("dept/name");
        var ops: std.ArrayList(nextomic.Op) = .empty;
        for (0..n) |i| {
            const name = try std.fmt.allocPrint(self.arena(), "d{d}", .{i});
            try ops.append(self.arena(), .{ .add = .{ .e = tempid(i), .a = .{ .id = a_dname }, .v = .{ .val = .{ .string = name } } } });
        }
        const report = try nextomic.transact.transactOps(self.conn, self.arena(), ops.items, .{});
        const eids = try self.arena().alloc(u64, n);
        for (report.tempids) |b| eids[@intCast(-b.key.fixnum - 1)] = b.eid;
        return eids;
    }
};

fn tempid(i: usize) nextomic.transact.Entity {
    return .{ .tempid = .{ .fixnum = -@as(i64, @intCast(i + 1)) } };
}

const QCtx = struct {
    fx: *Fixture,
    dbv: nextomic.DbValue,
    q: Value,
    inputs: []const Value,

    fn answer(self: *QCtx) !Value {
        var diag: query.Diag = .{};
        return query.q(self.fx.gpa, &self.fx.interner, &self.fx.heap, self.q, self.dbv, self.inputs, &diag, .{});
    }

    fn run(self: *QCtx) anyerror!void {
        std.mem.doNotOptimizeAway(try self.answer());
    }
};

const PullCtx = struct {
    fx: *Fixture,
    dbv: nextomic.DbValue,
    pattern: Value,
    /// `pull-many` over these, or `pull` of `one`.
    eids: []const Value = &.{},
    one: ?Value = null,

    fn answer(self: *PullCtx) !Value {
        var diag: pull.Diag = .{};
        return if (self.one) |eid|
            pull.pull(self.fx.gpa, &self.fx.interner, &self.fx.heap, self.dbv, self.pattern, eid, &diag)
        else
            pull.pullMany(self.fx.gpa, &self.fx.interner, &self.fx.heap, self.dbv, self.pattern, self.eids, &diag);
    }

    fn run(self: *PullCtx) anyerror!void {
        std.mem.doNotOptimizeAway(try self.answer());
    }
};

/// Fail unless `result` holds `rows` rows: a scalar count, or the
/// count of a set or vector.
fn expectRows(name: []const u8, result: Value, rows: usize) !void {
    const got: usize = switch (result.kind()) {
        .fixnum => @intCast(result.asFixnum()),
        .persistent_set => champ.setCount(result),
        .persistent_vector => vector_mod.count(result),
        else => return error.UnexpectedResult,
    };
    if (got == rows) return;
    std.debug.print("nexis-bench: {s} returned {d} rows, not {d}\n", .{ name, got, rows });
    return error.WrongRowCount;
}

/// Check the answer of `ctx`'s query, then time it.
fn benchQuery(runner: *bench.Runner, comptime name: []const u8, ctx: *QCtx, rows: usize) !void {
    try expectRows(name, try ctx.answer(), rows);
    try runner.bench(name, "nextomic", 200_000, ctx, QCtx.run);
}

/// The 200k-datom `q` corpus: 40,000 employees with five attributes
/// each over 20 departments.
pub fn runQuery(runner: *bench.Runner, gpa: Allocator, path: [:0]const u8) !void {
    var fx: Fixture = undefined;
    try fx.init(gpa, path);
    defer fx.deinit();
    try fx.transact(
        \\[{:db/ident :emp/name :db/valueType :db.type/string :db/cardinality :db.cardinality/one}
        \\ {:db/ident :emp/age :db/valueType :db.type/long :db/cardinality :db.cardinality/one :db/index true}
        \\ {:db/ident :emp/dept :db/valueType :db.type/ref :db/cardinality :db.cardinality/one}
        \\ {:db/ident :emp/salary :db/valueType :db.type/long :db/cardinality :db.cardinality/one}
        \\ {:db/ident :emp/active :db/valueType :db.type/boolean :db/cardinality :db.cardinality/one}
        \\ {:db/ident :dept/name :db/valueType :db.type/string :db/cardinality :db.cardinality/one :db/unique :db.unique/identity}]
    );
    const a_name = try fx.attr("emp/name");
    const a_age = try fx.attr("emp/age");
    const a_dept = try fx.attr("emp/dept");
    const a_salary = try fx.attr("emp/salary");
    const a_active = try fx.attr("emp/active");
    const depts = try fx.departments(20);

    const emps: usize = 40_000;
    const batch: usize = 5_000;
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    // Employees per age, for the rows each query must return.
    var of_age = [_]usize{0} ** 65;
    var start: usize = 0;
    while (start < emps) : (start += batch) {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var ops: std.ArrayList(nextomic.Op) = .empty;
        for (start..start + batch) |i| {
            const me = tempid(i);
            const name = try std.fmt.allocPrint(arena, "emp-{d}", .{i});
            try ops.append(arena, .{ .add = .{ .e = me, .a = .{ .id = a_name }, .v = .{ .val = .{ .string = name } } } });
            const age = 20 + rnd.uintLessThan(u32, 45);
            of_age[age] += 1;
            try ops.append(arena, .{ .add = .{ .e = me, .a = .{ .id = a_age }, .v = .{ .val = .{ .long = age } } } });
            try ops.append(arena, .{ .add = .{ .e = me, .a = .{ .id = a_dept }, .v = .{ .val = .{ .ref = depts[i % depts.len] } } } });
            try ops.append(arena, .{ .add = .{ .e = me, .a = .{ .id = a_salary }, .v = .{ .val = .{ .long = 1000 + @as(i64, @intCast(rnd.uintLessThan(u32, 9000))) } } } });
            try ops.append(arena, .{ .add = .{ .e = me, .a = .{ .id = a_active }, .v = .{ .val = .{ .boolean = i % 3 == 0 } } } });
        }
        _ = try nextomic.transact.transactOps(fx.conn, arena, ops.items, .{});
    }
    const dbv = try fx.conn.db();
    const none: []const Value = &.{value.nilValue()};
    const join = try fx.read("[:find (count ?n) . :in $ [?a ...] :where [?e :emp/age ?a] [?e :emp/name ?n] [?e :emp/salary ?s]]");

    var by_dept = QCtx{ .fx = &fx, .dbv = dbv, .inputs = none, .q = try fx.read("[:find ?n ?dn :where [?d :dept/name \"d7\"] [?e :emp/dept ?d] [?e :emp/name ?n] [?d :dept/name ?dn]]") };
    try benchQuery(runner, "q_join3_by_dept_2k_rows", &by_dept, emps / depts.len);
    var by_age = QCtx{ .fx = &fx, .dbv = dbv, .inputs = none, .q = try fx.read("[:find ?n ?dn :where [?e :emp/age 33] [?e :emp/dept ?d] [?d :dept/name ?dn] [?e :emp/name ?n]]") };
    try benchQuery(runner, "q_join3_by_age", &by_age, of_age[33]);
    // Active is every third employee, d3 every twentieth from the
    // fourth: the employees 3, 63, 123, ...
    var active = QCtx{ .fx = &fx, .dbv = dbv, .inputs = none, .q = try fx.read("[:find (count ?e) . :where [?e :emp/active true] [?e :emp/dept ?d] [?d :dept/name \"d3\"]]") };
    try benchQuery(runner, "q_count_hash_join", &active, (emps - 3 + 59) / 60);
    var ages_1 = QCtx{ .fx = &fx, .dbv = dbv, .q = join, .inputs = &.{ value.nilValue(), try fx.read("[33]") } };
    try benchQuery(runner, "q_join3_from_1_age", &ages_1, of_age[33]);
    var ages_3 = QCtx{ .fx = &fx, .dbv = dbv, .q = join, .inputs = &.{ value.nilValue(), try fx.read("[33 34 35]") } };
    try benchQuery(runner, "q_join3_from_3_ages", &ages_3, of_age[33] + of_age[34] + of_age[35]);
    var ages_7 = QCtx{ .fx = &fx, .dbv = dbv, .q = join, .inputs = &.{ value.nilValue(), try fx.read("[20 21 22 23 24 25 26]") } };
    var young: usize = 0;
    for (of_age[20..27]) |n| young += n;
    try benchQuery(runner, "q_join3_from_7_ages", &ages_7, young);
}

/// The 20k-entity `pull` corpus: employees with a name, an age, a
/// department and one or two skills, over 10 departments.
pub fn runPull(runner: *bench.Runner, gpa: Allocator, path: [:0]const u8) !void {
    var fx: Fixture = undefined;
    try fx.init(gpa, path);
    defer fx.deinit();
    try fx.transact(
        \\[{:db/ident :emp/name :db/valueType :db.type/string :db/cardinality :db.cardinality/one}
        \\ {:db/ident :emp/age :db/valueType :db.type/long :db/cardinality :db.cardinality/one}
        \\ {:db/ident :emp/dept :db/valueType :db.type/ref :db/cardinality :db.cardinality/one}
        \\ {:db/ident :emp/skills :db/valueType :db.type/keyword :db/cardinality :db.cardinality/many}
        \\ {:db/ident :dept/name :db/valueType :db.type/string :db/cardinality :db.cardinality/one :db/unique :db.unique/identity}]
    );
    const a_name = try fx.attr("emp/name");
    const a_age = try fx.attr("emp/age");
    const a_dept = try fx.attr("emp/dept");
    const a_skills = try fx.attr("emp/skills");
    const k_zig = try fx.interner.internKeyword("skill/zig");
    const k_lisp = try fx.interner.internKeyword("skill/lisp");
    const depts = try fx.departments(10);

    const emps: usize = 20_000;
    const batch: usize = 5_000;
    var eids: std.ArrayList(Value) = .empty;
    var start: usize = 0;
    while (start < emps) : (start += batch) {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var ops: std.ArrayList(nextomic.Op) = .empty;
        for (start..start + batch) |i| {
            const me = tempid(i);
            const name = try std.fmt.allocPrint(arena, "emp-{d}", .{i});
            try ops.append(arena, .{ .add = .{ .e = me, .a = .{ .id = a_name }, .v = .{ .val = .{ .string = name } } } });
            try ops.append(arena, .{ .add = .{ .e = me, .a = .{ .id = a_age }, .v = .{ .val = .{ .long = @intCast(20 + i % 45) } } } });
            try ops.append(arena, .{ .add = .{ .e = me, .a = .{ .id = a_dept }, .v = .{ .val = .{ .ref = depts[i % depts.len] } } } });
            try ops.append(arena, .{ .add = .{ .e = me, .a = .{ .id = a_skills }, .v = .{ .keyword = k_zig } } });
            if (i % 2 == 0) try ops.append(arena, .{ .add = .{ .e = me, .a = .{ .id = a_skills }, .v = .{ .keyword = k_lisp } } });
        }
        const report = try nextomic.transact.transactOps(fx.conn, arena, ops.items, .{});
        for (report.tempids) |b| try eids.append(fx.arena(), value.fromFixnum(@intCast(b.eid)).?);
    }
    const dbv = try fx.conn.db();

    var star = PullCtx{ .fx = &fx, .dbv = dbv, .eids = eids.items, .pattern = try fx.read("[*]") };
    try expectRows("pull_many_star", try star.answer(), emps);
    try runner.bench("pull_many_star", "nextomic", 20_000, &star, PullCtx.run);
    var nested = PullCtx{ .fx = &fx, .dbv = dbv, .eids = eids.items, .pattern = try fx.read("[:emp/name {:emp/dept [:dept/name]} (:emp/skills :limit 1)]") };
    try expectRows("pull_many_nested_ref_limit", try nested.answer(), emps);
    try runner.bench("pull_many_nested_ref_limit", "nextomic", 20_000, &nested, PullCtx.run);
    var reverse = PullCtx{ .fx = &fx, .dbv = dbv, .one = value.fromFixnum(@intCast(depts[3])).?, .pattern = try fx.read("[:dept/name (:emp/_dept :limit nil)]") };
    const reverse_key = try fx.interner.internKeywordValue("emp/_dept");
    const reverse_refs = switch (champ.mapGet(try reverse.answer(), reverse_key, &dispatch.hashValue, &dispatch.equal)) {
        .present => |refs| refs,
        .absent => return error.UnexpectedResult,
    };
    try expectRows("pull_reverse_ref_2k", reverse_refs, emps / depts.len);
    try runner.bench("pull_reverse_ref_2k", "nextomic", 2_000, &reverse, PullCtx.run);
}
