//! bench/nextomic.zig — the Nextomic corpora of `zig build bench`
//! (categories `nextomic`, docs/PERF.md §3.7, and `nextomic-store`).
//!
//! Two stores built once per run and measured through the engine's
//! Zig API, not through the language: a 200k-datom employee store for
//! `q` (joins by department and by age, an aggregate over a hash join,
//! and one join from 1, 3 and 7 ages, either side of the nested-loop /
//! hash-join crossover; then two long chains added to it) and a
//! 20k-entity store for `pull`. Each row
//! runs once and checks how many rows it returns before it is timed,
//! so a timing never measures a wrong answer; the tests carry 10k-datom
//! twins of both (test/integration/nextomic_{q,pull}.zig).
//!
//! Category `nextomic-store` times nothing: it builds four store
//! shapes (a bulk load, small transactions, churn, long strings) and
//! prints where each one's bytes go, tree by tree (docs/PERF.md §3.11).

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
        if (name.ns) |ns| return a.print("{s}/{s}", .{ ns, name.name });
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
            const name = try self.arena().print("d{d}", .{i});
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
    var of_age: [65]usize = @splat(0);
    var start: usize = 0;
    while (start < emps) : (start += batch) {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var ops: std.ArrayList(nextomic.Op) = .empty;
        for (start..start + batch) |i| {
            const me = tempid(i);
            const name = try arena.print("emp-{d}", .{i});
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

    // Long chains, transacted after the rows above ran so their store
    // is the 200k datoms alone: a 1000-clause chain over a 10-entity
    // chain (planning dominates; no row survives ten hops) and a
    // 100-clause chain over a 20k-entity chain (every step joins 20k
    // rows), finding its ends (the relation keeps two of its 101
    // variables) and finding every variable (it parks them).
    try fx.transact(
        \\[{:db/ident :chain/short :db/valueType :db.type/ref :db/cardinality :db.cardinality/one}
        \\ {:db/ident :chain/long :db/valueType :db.type/ref :db/cardinality :db.cardinality/one}
        \\ {:db/ident :chain/end :db/valueType :db.type/boolean :db/cardinality :db.cardinality/one}]
    );
    const a_end = try fx.attr("chain/end");
    try chain(&fx, try fx.attr("chain/short"), a_end, 10);
    try chain(&fx, try fx.attr("chain/long"), a_end, 20_000);
    const chain_db = try fx.conn.db();
    var short = QCtx{ .fx = &fx, .dbv = chain_db, .inputs = none, .q = try fx.read(try chainQuery(fx.arena(), 1000, ":chain/short", false)) };
    try benchQuery(runner, "q_chain_1000_clauses", &short, 0);
    var long = QCtx{ .fx = &fx, .dbv = chain_db, .inputs = none, .q = try fx.read(try chainQuery(fx.arena(), 100, ":chain/long", false)) };
    try benchQuery(runner, "q_chain_100_over_20k", &long, 20_000 - 100);
    var wide = QCtx{ .fx = &fx, .dbv = chain_db, .inputs = none, .q = try fx.read(try chainQuery(fx.arena(), 100, ":chain/long", true)) };
    try benchQuery(runner, "q_chain_100_find_all_over_20k", &wide, 20_000 - 100);
}

/// Transact `n` entities linked by `attr`, each to the next; the last
/// carries `end`.
fn chain(fx: *Fixture, attr: u32, end: u32, n: usize) !void {
    var arena_state = std.heap.ArenaAllocator.init(fx.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ops: std.ArrayList(nextomic.Op) = .empty;
    for (0..n - 1) |i| try ops.append(arena, .{ .add = .{ .e = tempid(i), .a = .{ .id = attr }, .v = .{ .entity = tempid(i + 1) } } });
    try ops.append(arena, .{ .add = .{ .e = tempid(n - 1), .a = .{ .id = end }, .v = .{ .val = .{ .boolean = true } } } });
    _ = try nextomic.transact.transactOps(fx.conn, arena, ops.items, .{});
}

/// `[:find ?x0 ?xn :where [?x0 attr ?x1] ... [?xn-1 attr ?xn]]`, or
/// with every variable in `:find` when `every`.
fn chainQuery(arena: Allocator, n: usize, attr: []const u8, every: bool) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll("[:find");
    for (0..n + 1) |i| if (every or i == 0 or i == n) try out.writer.print(" ?x{d}", .{i});
    try out.writer.writeAll(" :where");
    for (0..n) |i| try out.writer.print(" [?x{d} {s} ?x{d}]", .{ i, attr, i + 1 });
    try out.writer.writeByte(']');
    return out.written();
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
            const name = try arena.print("emp-{d}", .{i});
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

// =============================================================================
// nextomic-store: where a store's bytes go (docs/PERF.md §3.11)
// =============================================================================

/// The store shapes the size table measures.
const Shape = enum {
    /// §3.11's load: 100 departments, then 100,000 people of five
    /// attributes in transactions of 1,000.
    bulk,
    /// §3.27's: 20,000 people in one-entity transactions, then 2,000
    /// upserts through the unique email, the salary changed.
    @"small-tx",
    /// 10,000 people, then five rounds that change every card-one
    /// attribute of each, a tenth of them retracting their score in one
    /// round and asserting it again in the next.
    churn,
    /// 20,000 documents with a 282-byte string each, every string then
    /// replaced once.
    text,
};

/// Build each shape in a fresh store at `path` and print, for every
/// tree, its entries, key and value bytes, pages, fill and size, then
/// the file's allocated bytes.
pub fn runStore(gpa: Allocator, io: std.Io, path: [:0]const u8) !void {
    inline for (@typeInfo(Shape).@"enum".field_names) |name| {
        removeStore(path);
        defer removeStore(path);
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        {
            var fx: Fixture = undefined;
            try fx.init(gpa, path);
            defer fx.deinit();
            try build(&fx, @field(Shape, name));
            try sizeTable(&fx, &out.writer, name);
        }
        var st: std.c.Stat = undefined;
        if (std.c.stat(path.ptr, &st) != 0) return error.StatFailed;
        const allocated: u64 = @intCast(st.blocks * 512);
        try out.writer.print("file allocated {d:.1} MB\n\n", .{@as(f64, @floatFromInt(allocated)) / 1e6});
        try std.Io.File.stdout().writeStreamingAll(io, out.written());
    }
}

fn removeStore(path: [:0]const u8) void {
    _ = std.c.unlink(path.ptr);
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const lock_path = std.mem.printSentinel(&buf, "{s}-lock", .{path}, 0) catch return;
    _ = std.c.unlink(lock_path.ptr);
}

fn sizeTable(fx: *Fixture, w: *std.Io.Writer, name: []const u8) !void {
    const store = fx.conn.store;
    const txn = try store.beginRead();
    defer txn.abort();
    try w.print("nextomic-store {s}: t {d}\n", .{ name, try store.readT(txn) });
    try w.print("{s:<12} {s:>9} {s:>10} {s:>10} {s:>7} {s:>7} {s:>8} {s:>5} {s:>7}\n", .{ "tree", "entries", "key B", "value B", "leaves", "branch", "overflow", "fill", "MB" });
    var ids: [nextomic.store.tree_names.len]nx.emdb.TreeId = undefined;
    for (0..4) |i| {
        ids[i] = store.trees.current[i];
        ids[4 + i] = store.trees.history[i];
    }
    ids[8] = store.trees.txlog;
    ids[9] = store.trees.idents;
    ids[10] = store.trees.sys;
    ids[11] = store.trees.fulltext;
    var pages: u64 = 0;
    for (nextomic.store.tree_names, ids) |tree_name, id| {
        const s = try nextomic.Store.treeSize(txn, id, fx.gpa);
        pages += s.pages();
        try w.print("{s:<12} {d:>9} {d:>10} {d:>10} {d:>7} {d:>7} {d:>8} ", .{ tree_name, s.entries, s.key_bytes, s.value_bytes, s.leaf_pages, s.branch_pages, s.overflow_pages });
        // Values on overflow pages are not in the leaves.
        if (s.overflow_pages == 0) try w.print("{d:>5.2}", .{s.fill()}) else try w.print("{s:>5}", .{"-"});
        try w.print(" {d:>7.1}\n", .{mb(s.pages())});
    }
    try w.print("{s:<12} {s:>69} {d:>7.1}\n", .{ "all trees", "", mb(pages) });
}

fn mb(pages: u64) f64 {
    return @as(f64, @floatFromInt(pages * nx.db.page_size)) / 1e6;
}

fn build(fx: *Fixture, shape: Shape) !void {
    switch (shape) {
        .bulk => try buildBulk(fx),
        .@"small-tx" => try buildSmallTx(fx),
        .churn => try buildChurn(fx),
        .text => try buildText(fx),
    }
}

/// Transact `ops`, built by the caller in `arena`, which is then reset.
fn commitOps(fx: *Fixture, arena_state: *std.heap.ArenaAllocator, ops: *std.ArrayList(nextomic.Op)) !void {
    _ = try nextomic.transact.transactOps(fx.conn, arena_state.allocator(), ops.items, .{});
    ops.* = .empty;
    _ = arena_state.reset(.retain_capacity);
}

fn add(arena: Allocator, ops: *std.ArrayList(nextomic.Op), e: nextomic.transact.Entity, a: u32, v: nextomic.Val) !void {
    try ops.append(arena, .{ .add = .{ .e = e, .a = .{ .id = a }, .v = .{ .val = v } } });
}

fn buildBulk(fx: *Fixture) !void {
    try fx.transact(
        \\[{:db/ident :dept/name :db/valueType :db.type/string :db/cardinality :db.cardinality/one :db/unique :db.unique/identity}
        \\ {:db/ident :person/email :db/valueType :db.type/string :db/cardinality :db.cardinality/one :db/unique :db.unique/identity}
        \\ {:db/ident :person/name :db/valueType :db.type/string :db/cardinality :db.cardinality/one}
        \\ {:db/ident :person/age :db/valueType :db.type/long :db/cardinality :db.cardinality/one :db/index true}
        \\ {:db/ident :person/dept :db/valueType :db.type/ref :db/cardinality :db.cardinality/one}
        \\ {:db/ident :person/salary :db/valueType :db.type/long :db/cardinality :db.cardinality/one}]
    );
    const depts = try fx.departments(100);
    const a = .{ try fx.attr("person/email"), try fx.attr("person/name"), try fx.attr("person/age"), try fx.attr("person/dept"), try fx.attr("person/salary") };
    var arena_state = std.heap.ArenaAllocator.init(fx.gpa);
    defer arena_state.deinit();
    var ops: std.ArrayList(nextomic.Op) = .empty;
    for (0..100_000) |i| {
        const arena = arena_state.allocator();
        const me = tempid(i % 1000);
        try add(arena, &ops, me, a[0], .{ .string = try arena.print("p{d}@x.org", .{i}) });
        try add(arena, &ops, me, a[1], .{ .string = try arena.print("name-{d}", .{i}) });
        try add(arena, &ops, me, a[2], .{ .long = @intCast(18 + (i * 7) % 60) });
        try add(arena, &ops, me, a[3], .{ .ref = depts[i % 100] });
        try add(arena, &ops, me, a[4], .{ .long = @intCast(30_000 + (i * 7919) % 90_001) });
        if (i % 1000 == 999) try commitOps(fx, &arena_state, &ops);
    }
}

const person_schema =
    \\[{:db/ident :person/email :db/valueType :db.type/string :db/cardinality :db.cardinality/one :db/unique :db.unique/identity}
    \\ {:db/ident :person/name :db/valueType :db.type/string :db/cardinality :db.cardinality/one}
    \\ {:db/ident :person/age :db/valueType :db.type/long :db/cardinality :db.cardinality/one :db/index true}
    \\ {:db/ident :person/code :db/valueType :db.type/string :db/cardinality :db.cardinality/one}
    \\ {:db/ident :person/salary :db/valueType :db.type/long :db/cardinality :db.cardinality/one}]
;

fn buildSmallTx(fx: *Fixture) !void {
    try fx.transact(person_schema);
    const a = .{ try fx.attr("person/email"), try fx.attr("person/name"), try fx.attr("person/age"), try fx.attr("person/code"), try fx.attr("person/salary") };
    var arena_state = std.heap.ArenaAllocator.init(fx.gpa);
    defer arena_state.deinit();
    var ops: std.ArrayList(nextomic.Op) = .empty;
    for (0..22_000) |n| {
        const arena = arena_state.allocator();
        // The last 2,000 name people already in the store: upserts.
        const i = if (n < 20_000) n else n - 20_000;
        const me = tempid(0);
        try add(arena, &ops, me, a[0], .{ .string = try arena.print("p{d}@x.org", .{i}) });
        try add(arena, &ops, me, a[1], .{ .string = try arena.print("name-{d}", .{i}) });
        try add(arena, &ops, me, a[2], .{ .long = @intCast(18 + i % 60) });
        try add(arena, &ops, me, a[3], .{ .string = try arena.print("c{d}", .{i}) });
        try add(arena, &ops, me, a[4], .{ .long = @intCast(if (n < 20_000) 30_000 + i else i) });
        try commitOps(fx, &arena_state, &ops);
    }
}

fn buildChurn(fx: *Fixture) !void {
    try fx.transact(
        \\[{:db/ident :team/name :db/valueType :db.type/string :db/cardinality :db.cardinality/one :db/unique :db.unique/identity}
        \\ {:db/ident :person/email :db/valueType :db.type/string :db/cardinality :db.cardinality/one :db/unique :db.unique/identity}
        \\ {:db/ident :person/name :db/valueType :db.type/string :db/cardinality :db.cardinality/one}
        \\ {:db/ident :person/age :db/valueType :db.type/long :db/cardinality :db.cardinality/one :db/index true}
        \\ {:db/ident :person/score :db/valueType :db.type/long :db/cardinality :db.cardinality/one}
        \\ {:db/ident :person/team :db/valueType :db.type/ref :db/cardinality :db.cardinality/one}]
    );
    const teams = try departmentsOf(fx, "team/name", 10);
    const a = .{ try fx.attr("person/email"), try fx.attr("person/name"), try fx.attr("person/age"), try fx.attr("person/score"), try fx.attr("person/team") };
    var arena_state = std.heap.ArenaAllocator.init(fx.gpa);
    defer arena_state.deinit();
    var ops: std.ArrayList(nextomic.Op) = .empty;
    const people: usize = 10_000;
    const eids = try fx.arena().alloc(u64, people);
    for (0..people / 1000) |b| {
        const arena = arena_state.allocator();
        for (b * 1000..(b + 1) * 1000) |i| {
            const me = tempid(i - b * 1000);
            try add(arena, &ops, me, a[0], .{ .string = try arena.print("p{d}@x.org", .{i}) });
            try add(arena, &ops, me, a[1], .{ .string = try arena.print("name-{d}", .{i}) });
            try add(arena, &ops, me, a[2], .{ .long = @intCast(18 + i % 60) });
            try add(arena, &ops, me, a[3], .{ .long = 0 });
            try add(arena, &ops, me, a[4], .{ .ref = teams[i % 10] });
        }
        const report = try nextomic.transact.transactOps(fx.conn, arena, ops.items, .{});
        for (report.tempids) |t| eids[b * 1000 + @as(usize, @intCast(-t.key.fixnum - 1))] = t.eid;
        ops = .empty;
        _ = arena_state.reset(.retain_capacity);
    }
    for (1..6) |round| {
        for (0..people / 1000) |b| {
            const arena = arena_state.allocator();
            for (b * 1000..(b + 1) * 1000) |i| {
                const me: nextomic.transact.Entity = .{ .eid = eids[i] };
                try add(arena, &ops, me, a[1], .{ .string = try arena.print("name-{d}-{d}", .{ i, round }) });
                try add(arena, &ops, me, a[2], .{ .long = @intCast(18 + (i + round) % 60) });
                if (i % 10 == 0 and round == 2) {
                    try ops.append(arena, .{ .retract_attr = .{ .e = me, .a = .{ .id = a[3] } } });
                } else if (i % 10 != 0 or round != 3) {
                    try add(arena, &ops, me, a[3], .{ .long = @intCast(i * round) });
                } else {
                    // The score retracted last round comes back as it was.
                    try add(arena, &ops, me, a[3], .{ .long = @intCast(i) });
                }
                try add(arena, &ops, me, a[4], .{ .ref = teams[(i + round) % 10] });
            }
            try commitOps(fx, &arena_state, &ops);
        }
    }
}

/// `n` entities named by unique string `attr` `d0`, `d1`, ...; their
/// eids in order.
fn departmentsOf(fx: *Fixture, attr: []const u8, n: usize) ![]u64 {
    const a = try fx.attr(attr);
    var ops: std.ArrayList(nextomic.Op) = .empty;
    for (0..n) |i| try add(fx.arena(), &ops, tempid(i), a, .{ .string = try fx.arena().print("d{d}", .{i}) });
    const report = try nextomic.transact.transactOps(fx.conn, fx.arena(), ops.items, .{});
    const eids = try fx.arena().alloc(u64, n);
    for (report.tempids) |b| eids[@intCast(-b.key.fixnum - 1)] = b.eid;
    return eids;
}

fn buildText(fx: *Fixture) !void {
    try fx.transact(
        \\[{:db/ident :doc/id :db/valueType :db.type/long :db/cardinality :db.cardinality/one :db/unique :db.unique/identity}
        \\ {:db/ident :doc/text :db/valueType :db.type/string :db/cardinality :db.cardinality/one}]
    );
    const a_id = try fx.attr("doc/id");
    const a_text = try fx.attr("doc/text");
    var arena_state = std.heap.ArenaAllocator.init(fx.gpa);
    defer arena_state.deinit();
    var ops: std.ArrayList(nextomic.Op) = .empty;
    for (0..2) |round| {
        for (0..20_000) |i| {
            const arena = arena_state.allocator();
            const me = tempid(i % 1000);
            try add(arena, &ops, me, a_id, .{ .long = @intCast(i) });
            try add(arena, &ops, me, a_text, .{ .string = try text282(arena, i, round) });
            if (i % 1000 == 999) try commitOps(fx, &arena_state, &ops);
        }
    }
}

/// A 282-byte string, different for every document and round.
fn text282(arena: Allocator, i: usize, round: usize) ![]const u8 {
    const s = try arena.alloc(u8, 282);
    const head = try std.fmt.bufPrint(s, "document {d}, version {d}: ", .{ i, round });
    for (s[head.len..], head.len..) |*c, k| c.* = "abcdefghijklmnopqrstuvwxyz "[(k * 7 + i + round) % 27];
    return s;
}
