//! test/integration/nextomic_q.zig — the query corpus (NEXTOMIC.md §8).
//!
//! Every query here runs twice: through the pipeline (parse, plan,
//! exec) and through `Naive`, a nested-loop evaluator over the view's
//! datoms that knows nothing of relations, plans or indexes. The two
//! row sets must agree after sorting. Queries are read from source
//! text with the language reader so the corpus reads like Datalog.
//! Rules in `Naive` are evaluated bottom-up to a naive fixpoint over
//! the whole view, so the rule corpus uses a small graph; the 5k-edge
//! chain is checked against its known closure instead.

const std = @import("std");
const nx = @import("nexis");
const nextomic = nx.nextomic;
const value = nx.value;
const heap_mod = nx.heap;
const intern_mod = nx.intern;
const string_mod = nx.string;
const list_mod = nx.list;
const vector_mod = nx.vector;
const champ = nx.champ;
const dispatch = nx.dispatch;

const testing = std.testing;
const Allocator = std.mem.Allocator;
const Value = value.Value;
const Heap = heap_mod.Heap;
const Interner = intern_mod.Interner;
const query = nextomic.query;
const ir = query.ir;
const Cell = nextomic.Cell;
const Relation = nextomic.Relation;
const Var = ir.Var;
const DbValue = nextomic.DbValue;
const TestConn = nextomic.db.TestConn;
const key = nextomic.key;

// =============================================================================
// Fixture
// =============================================================================

const Fx = @import("nextomic_fx.zig").Fx;

const long_bio_a = "Ann has a biography that runs well past the ninety-six byte inline limit of the sortable string encoding, so it lives out of line with a prefix and a hash.";
const long_bio_d = "Di also has a long biography, long enough to be stored out of line; the first sixty-four bytes are shared with nothing else in this corpus at all.";
const long_bio_x = "Ann has a biography that runs well past the ninety-six byte inline limit of the sortable string encoding, so it lives out of line -- but this one differs after the prefix.";

/// Schema, people, orders, graph, then an update transaction.
fn loadCorpus(fx: *Fx) !void {
    _ = try fx.transact(
        \\[{:db/ident :person/name :db/valueType :db.type/string :db/cardinality :db.cardinality/one :db/index true}
        \\ {:db/ident :person/email :db/valueType :db.type/string :db/cardinality :db.cardinality/one :db/unique :db.unique/identity}
        \\ {:db/ident :person/age :db/valueType :db.type/long :db/cardinality :db.cardinality/one}
        \\ {:db/ident :person/height :db/valueType :db.type/double :db/cardinality :db.cardinality/one}
        \\ {:db/ident :person/active :db/valueType :db.type/boolean :db/cardinality :db.cardinality/one}
        \\ {:db/ident :person/tags :db/valueType :db.type/keyword :db/cardinality :db.cardinality/many}
        \\ {:db/ident :person/friend :db/valueType :db.type/ref :db/cardinality :db.cardinality/many}
        \\ {:db/ident :person/boss :db/valueType :db.type/ref :db/cardinality :db.cardinality/one}
        \\ {:db/ident :person/bio :db/valueType :db.type/string :db/cardinality :db.cardinality/one}
        \\ {:db/ident :person/role :db/valueType :db.type/keyword :db/cardinality :db.cardinality/one}
        \\ {:db/ident :order/number :db/valueType :db.type/long :db/cardinality :db.cardinality/one :db/unique :db.unique/value}
        \\ {:db/ident :order/customer :db/valueType :db.type/ref :db/cardinality :db.cardinality/one}
        \\ {:db/ident :order/total :db/valueType :db.type/double :db/cardinality :db.cardinality/one :db/index true}
        \\ {:db/ident :order/status :db/valueType :db.type/keyword :db/cardinality :db.cardinality/one :db/index true}
        \\ {:db/ident :order/items :db/valueType :db.type/string :db/cardinality :db.cardinality/many}
        \\ {:db/ident :edge/to :db/valueType :db.type/ref :db/cardinality :db.cardinality/many}
        \\ {:db/ident :node/label :db/valueType :db.type/string :db/cardinality :db.cardinality/one}
        \\ {:db/ident :role/admin} {:db/ident :role/user}]
    );
    const people = try std.fmt.allocPrint(fx.arena(),
        \\[{{:db/id "ann" :person/name "Ann" :person/email "ann@x" :person/age 30 :person/height 1.7 :person/active true :person/tags [:red :blue] :person/role :role/admin :person/bio "{s}"}}
        \\ {{:db/id "bob" :person/name "Bob" :person/email "bob@x" :person/age 25 :person/height 1.8 :person/active false :person/tags [:blue] :person/friend ["ann"] :person/boss "ann" :person/role :role/user}}
        \\ {{:db/id "cy" :person/name "Cy" :person/email "cy@x" :person/age 41 :person/height 1.65 :person/active true :person/tags [:red :green] :person/friend ["ann" "bob"] :person/boss "ann"}}
        \\ {{:db/id "di" :person/name "Di" :person/email "di@x" :person/age 30 :person/active true :person/friend ["cy"] :person/boss "cy" :person/bio "{s}"}}
        \\ {{:db/id "ed" :person/name "Ed" :person/email "ed@x" :person/age 55 :person/tags [:green] :person/role :role/admin}}]
    , .{ long_bio_a, long_bio_d });
    _ = try fx.transact(people);
    _ = try fx.transact(
        \\[{:order/number 1 :order/customer [:person/email "ann@x"] :order/total 10.5 :order/status :status/open :order/items ["apple" "pear"]}
        \\ {:order/number 2 :order/customer [:person/email "bob@x"] :order/total 99.0 :order/status :status/shipped :order/items ["fig"]}
        \\ {:order/number 3 :order/customer [:person/email "ann@x"] :order/total 5.25 :order/status :status/shipped}
        \\ {:order/number 4 :order/customer [:person/email "cy@x"] :order/total 42.0 :order/status :status/open :order/items ["apple"]}]
    );
    _ = try fx.transact(
        \\[{:db/id "n1" :node/label "n1" :edge/to ["n2"]} {:db/id "n2" :node/label "n2" :edge/to ["n3"]}
        \\ {:db/id "n3" :node/label "n3" :edge/to ["n1" "n4"]} {:db/id "n4" :node/label "n4" :edge/to ["n5"]}
        \\ {:db/id "n5" :node/label "n5"} {:db/id "n6" :node/label "n6"}]
    );
    _ = try fx.transact(
        \\[[:db/add [:person/email "bob@x"] :person/age 26]
        \\ [:db/retract [:person/email "ann@x"] :person/tags :red]
        \\ {:db/id [:person/email "ed@x"] :person/name "Edward"}
        \\ {:db/id "flo" :person/name "Flo" :person/email "flo@x" :person/age 33 :person/friend [[:person/email "bob@x"]]}
        \\ [:db/retract [:person/email "cy@x"] :person/friend [:person/email "bob@x"]]]
    );
}

// =============================================================================
// Running both engines
// =============================================================================

const Row = []const Cell;

/// Rows through the pipeline, in `arena`.
fn runEngine(fx: *Fx, arena: Allocator, dbv: DbValue, src: []const u8, args: []const Value) anyerror![]const Row {
    var diag: query.Diag = .{};
    return runEngineDiag(fx, arena, dbv, src, args, &diag);
}

fn runEngineDiag(fx: *Fx, arena: Allocator, dbv: DbValue, src: []const u8, args: []const Value, diag: *query.Diag) anyerror![]const Row {
    const qv = try fx.read(src);
    const parsed = try query.parse.parse(testing.allocator, fx.interner(), qv, diag);
    defer parsed.deinit();
    if (args.len != parsed.in.len) {
        diag.* = .{ .message = "wrong number of inputs" };
        return error.QuerySyntax;
    }
    var rules: *const ir.RuleSet = &ir.no_rules;
    var owned_rules: ?*ir.RuleSet = null;
    defer if (owned_rules) |r| r.deinit();
    for (parsed.in, args) |b, a| {
        if (b == .rules) {
            owned_rules = try query.parse.parseRules(testing.allocator, fx.interner(), a, diag);
            rules = owned_rules.?;
        }
    }
    const reads = try openReads(arena, dbv, parsed, args);
    defer for (reads) |r| r.close();
    const sources = try arena.alloc(query.Source, reads.len);
    for (reads, sources) |r, *s| s.* = .{ .db = r };
    var ctx = try query.plan.Ctx.init(arena, sources, fx.interner(), parsed, rules, diag);
    const p = try query.plan.plan(&ctx, parsed);
    var ex = query.Exec{ .arena = arena, .sources = sources, .heap = &fx.heap, .interner = fx.interner(), .hook = fx.hook(), .diag = diag };
    const input = try ex.inputRelation(parsed, args);
    const rel = try ex.runPlan(p, input);
    return ex.findRows(parsed, rel);
}

/// The db-values of a query's sources: `dbv` for `$`, the boxed
/// db-value at each later source's `:in` position.
fn sourceDbs(arena: Allocator, dbv: DbValue, parsed: *const ir.Ir, args: []const Value) ![]DbValue {
    const out = try arena.alloc(DbValue, parsed.sources.len);
    for (parsed.in, args) |b, a| {
        if (b != .src) continue;
        out[b.src] = if (b.src == 0) dbv else try nextomic.natives.dbOf(a);
    }
    return out;
}

/// One open `Read` per source.
fn openReads(arena: Allocator, dbv: DbValue, parsed: *const ir.Ir, args: []const Value) ![]*nextomic.db.Read {
    const dbs = try sourceDbs(arena, dbv, parsed, args);
    const out = try arena.alloc(*nextomic.db.Read, dbs.len);
    var opened: usize = 0;
    errdefer for (out[0..opened]) |r| r.close();
    for (dbs, out) |d, *r| {
        r.* = try arena.create(nextomic.db.Read);
        r.*.* = try d.beginRead();
        opened += 1;
    }
    return out;
}

fn sortedRelation(arena: Allocator, rows: []const Row, width: usize) !Relation {
    const vars = try arena.alloc(Var, width);
    for (vars, 0..) |*v, i| v.* = @intCast(i);
    var rel = try Relation.init(arena, vars);
    for (rows) |r| try rel.append(r);
    try rel.sort();
    return rel;
}

fn printRows(fx: *Fx, label: []const u8, rel: *const Relation) void {
    std.debug.print("{s} ({d} rows):\n", .{ label, rel.rows });
    var i: usize = 0;
    while (i < rel.rows and i < 40) : (i += 1) {
        std.debug.print("  [", .{});
        for (rel.cols) |*c| {
            switch (c.get(i)) {
                .nil => std.debug.print(" nil", .{}),
                .int => |n| std.debug.print(" {d}", .{n}),
                .double => |d| std.debug.print(" {d}", .{d}),
                .boolean => |b| std.debug.print(" {}", .{b}),
                .keyword => |k| std.debug.print(" :{s}", .{fx.interner().keywordName(k)}),
                .str => |s| std.debug.print(" \"{s}\"", .{if (s.len > 20) s[0..20] else s}),
                .vm => std.debug.print(" #vm", .{}),
            }
        }
        std.debug.print(" ]\n", .{});
    }
}

/// Run `src` through both engines and compare. Returns the engine's
/// sorted rows for further checks.
fn check(fx: *Fx, dbv: DbValue, src: []const u8, args: []const Value) !Relation {
    const arena = fx.arena();
    const got = try runEngine(fx, arena, dbv, src, args);
    const want = try Naive.run(fx, arena, dbv, src, args);
    const width = if (got.len > 0) got[0].len else if (want.len > 0) want[0].len else 0;
    const got_rel = try sortedRelation(arena, got, width);
    const want_rel = try sortedRelation(arena, want, width);
    if (!got_rel.eqlRows(&want_rel)) {
        std.debug.print("\nMISMATCH for {s}\n", .{src});
        printRows(fx, "engine", &got_rel);
        printRows(fx, "naive", &want_rel);
        return error.QueryMismatch;
    }
    return got_rel;
}

fn checkCount(fx: *Fx, dbv: DbValue, src: []const u8, args: []const Value, n: usize) !void {
    const rel = try check(fx, dbv, src, args);
    if (rel.rows != n) {
        std.debug.print("\nexpected {d} rows, got {d} for {s}\n", .{ n, rel.rows, src });
        printRows(fx, "engine", &rel);
        return error.RowCount;
    }
}

// =============================================================================
// Naive evaluator
// =============================================================================

const Env = []?Cell;

const Naive = struct {
    fx: *Fx,
    arena: Allocator,
    /// Per source: the db-value, its open read, every datom of the
    /// view as cells.
    dbvs: []const DbValue,
    reads: []const *nextomic.db.Read,
    datoms: []const []const [5]Cell,
    rules: *const ir.RuleSet,
    /// Rule facts per (rule name, source): a rule body reads the
    /// source it is called under.
    facts: std.AutoHashMapUnmanaged(u64, std.ArrayList(Row)) = .empty,
    /// Attribute types per source, by attribute id.
    attr_types: []std.AutoHashMapUnmanaged(u32, key.ValueType),

    fn factKey(name: u32, src: ir.Src) u64 {
        return (@as(u64, name) << 32) | src;
    }

    fn connOf(self: *Naive, src: ir.Src) *nextomic.Conn {
        return self.dbvs[src].conn;
    }

    fn run(fx: *Fx, arena: Allocator, dbv: DbValue, src: []const u8, args: []const Value) anyerror![]const Row {
        const qv = try fx.read(src);
        var diag: query.Diag = .{};
        const parsed = try query.parse.parse(testing.allocator, fx.interner(), qv, &diag);
        defer parsed.deinit();
        if (args.len != parsed.in.len) return error.QuerySyntax;
        var rules: *const ir.RuleSet = &ir.no_rules;
        var owned_rules: ?*ir.RuleSet = null;
        defer if (owned_rules) |r| r.deinit();
        for (parsed.in, args) |b, a| {
            if (b == .rules) {
                owned_rules = try query.parse.parseRules(testing.allocator, fx.interner(), a, &diag);
                rules = owned_rules.?;
            }
        }

        const dbvs = try sourceDbs(arena, dbv, parsed, args);
        const reads = try openReads(arena, dbv, parsed, args);
        defer for (reads) |r| r.close();
        const attr_types = try arena.alloc(std.AutoHashMapUnmanaged(u32, key.ValueType), dbvs.len);
        @memset(attr_types, .empty);
        var self = Naive{ .fx = fx, .arena = arena, .dbvs = dbvs, .reads = reads, .datoms = &.{}, .rules = rules, .attr_types = attr_types };
        try self.loadDatoms();
        try self.computeFacts();

        // Initial environments from :in.
        var envs: std.ArrayList(Env) = .empty;
        try envs.append(arena, try self.emptyEnv(parsed.vars.len));
        for (parsed.in, args) |b, a| {
            var next: std.ArrayList(Env) = .empty;
            switch (b) {
                .src, .rules => continue,
                .scalar => |v| for (envs.items) |e| {
                    const e2 = try self.copy(e);
                    e2[v] = Cell.fromValue(a);
                    try next.append(arena, e2);
                },
                .collection => |v| for (envs.items) |e| for (try seq(arena, a)) |x| {
                    const e2 = try self.copy(e);
                    e2[v] = Cell.fromValue(x);
                    try next.append(arena, e2);
                },
                .tuple => |ts| for (envs.items) |e| {
                    const e2 = try self.copy(e);
                    for (ts, try seq(arena, a)) |t, x| if (t) |v| {
                        e2[v] = Cell.fromValue(x);
                    };
                    try next.append(arena, e2);
                },
                .relation => |ts| for (envs.items) |e| for (try seq(arena, a)) |row| {
                    const e2 = try self.copy(e);
                    for (ts, try seq(arena, row)) |t, x| if (t) |v| {
                        e2[v] = Cell.fromValue(x);
                    };
                    try next.append(arena, e2);
                },
            }
            envs = next;
        }

        // Entity-role inputs resolve to entity ids.
        const roles = try arena.alloc(InputRole, parsed.vars.len);
        @memset(roles, .{});
        try self.inputRoles(parsed.where, roles);
        var resolved: std.ArrayList(Env) = .empty;
        envs: for (envs.items) |e| {
            for (roles, 0..) |r, v| {
                if (!r.entity or r.keyword) continue;
                const c = e[v] orelse continue;
                if (c != .keyword and c != .vm) continue;
                e[v] = .{ .int = @intCast((try self.inputEntity(c, r.src)) orelse continue :envs) };
            }
            try resolved.append(arena, e);
        }
        envs = resolved;

        var solved: std.ArrayList(Env) = .empty;
        for (envs.items) |e| try self.solve(parsed.where, e, &solved, 0);

        // Basis: distinct tuples over find ∪ with variables.
        var basis_vars: std.ArrayList(Var) = .empty;
        for (parsed.find) |f| try ir.addVar(arena, &basis_vars, f.variable_of());
        for (parsed.with) |w| try ir.addVar(arena, &basis_vars, w);
        var basis: std.ArrayList(Row) = .empty;
        for (solved.items) |e| {
            const row = try arena.alloc(Cell, basis_vars.items.len);
            for (basis_vars.items, row) |v, *c| c.* = e[v] orelse return error.Unbound;
            if (!containsRow(basis.items, row)) try basis.append(arena, row);
        }

        var out: std.ArrayList(Row) = .empty;
        if (!parsed.hasAggregates()) {
            for (basis.items) |b| {
                const row = try arena.alloc(Cell, parsed.find.len);
                for (parsed.find, row) |f, *c| c.* = b[indexOf(basis_vars.items, f.variable_of())];
                if (parsed.with.len == 0 or !containsRow(out.items, row)) try out.append(arena, row);
            }
            return out.toOwnedSlice(arena);
        }

        // Group by the plain find variables.
        var group_vars: std.ArrayList(Var) = .empty;
        for (parsed.find) |f| if (f != .agg) try ir.addVar(arena, &group_vars, f.variable_of());
        var keys: std.ArrayList(Row) = .empty;
        var groups: std.ArrayList(std.ArrayList(Row)) = .empty;
        for (basis.items) |b| {
            const k = try arena.alloc(Cell, group_vars.items.len);
            for (group_vars.items, k) |v, *c| c.* = b[indexOf(basis_vars.items, v)];
            var g: ?usize = null;
            for (keys.items, 0..) |kk, i| if (rowEql(kk, k)) {
                g = i;
            };
            if (g == null) {
                try keys.append(arena, k);
                try groups.append(arena, .empty);
                g = keys.items.len - 1;
            }
            try groups.items[g.?].append(arena, b);
        }
        for (groups.items) |members| {
            const row = try arena.alloc(Cell, parsed.find.len);
            for (parsed.find, row) |f, *c| {
                c.* = switch (f) {
                    .variable, .pull => members.items[0][indexOf(basis_vars.items, f.variable_of())],
                    .agg => |ag| try self.aggregate(ag, members.items, indexOf(basis_vars.items, ag.arg)),
                };
            }
            try out.append(arena, row);
        }
        return out.toOwnedSlice(arena);
    }

    /// The naive aggregate: sorting where the engine sorts, a random
    /// vector's length only for `sample` and `rand` (compared by count
    /// in the tests), the same custom call through the fixture.
    fn aggregate(self: *Naive, ag: ir.Agg, members: []const Row, col: usize) !Cell {
        const op = ag.op;
        const sorted = try self.arena.alloc(Cell, members.len);
        for (members, sorted) |m, *c| c.* = m[col];
        std.mem.sort(Cell, sorted, self.fx.interner(), cellAsc);
        switch (op) {
            .count => return .{ .int = @intCast(members.len) },
            .median => {
                if (sorted.len == 0) return .nil;
                if (sorted.len % 2 == 1) return sorted[sorted.len / 2];
                return .{ .double = (try num(sorted[sorted.len / 2 - 1]) + try num(sorted[sorted.len / 2])) / 2 };
            },
            .variance, .stddev => {
                if (sorted.len == 0) return .nil;
                var mean: f64 = 0;
                for (sorted) |c| mean += try num(c);
                mean /= @floatFromInt(sorted.len);
                var acc: f64 = 0;
                for (sorted) |c| acc += (try num(c) - mean) * (try num(c) - mean);
                const v = acc / @as(f64, @floatFromInt(sorted.len));
                return .{ .double = if (op == .variance) v else @sqrt(v) };
            },
            .sample, .rand => return error.Unsupported,
            .custom => {
                const vals = try self.arena.alloc(Value, members.len);
                for (members, vals) |m, *v| v.* = try self.cellValue(m[col]);
                return Cell.fromValue(try Fx.hookCall(@ptrCast(self.fx), ag.sym, &.{try vector_mod.fromSlice(&self.fx.heap, vals)}));
            },
            .count_distinct, .distinct => {
                var seen: std.ArrayList(Cell) = .empty;
                for (members) |m| {
                    var dup = false;
                    for (seen.items) |s| if (s.eql(m[col])) {
                        dup = true;
                    };
                    if (!dup) try seen.append(self.arena, m[col]);
                }
                if (op == .count_distinct) return .{ .int = @intCast(seen.items.len) };
                var set = try champ.setEmpty(&self.fx.heap);
                for (seen.items) |c| set = try champ.setConj(&self.fx.heap, set, try self.cellValue(c), &dispatch.hashValue, &dispatch.equal);
                return .{ .vm = set };
            },
            .min, .max => {
                if (ag.n) |n| {
                    if (op == .max) std.mem.reverse(Cell, sorted);
                    const vals = try self.arena.alloc(Value, @min(n, sorted.len));
                    for (sorted[0..vals.len], vals) |c, *v| v.* = try self.cellValue(c);
                    return .{ .vm = try vector_mod.fromSlice(&self.fx.heap, vals) };
                }
                var best = members[0][col];
                for (members[1..]) |m| {
                    const o = naiveOrder(self.fx.interner(), m[col], best);
                    if ((op == .min and o == .lt) or (op == .max and o == .gt)) best = m[col];
                }
                return best;
            },
            .sum, .avg => {
                var total: f64 = 0;
                var all_int = true;
                var itotal: i64 = 0;
                for (members) |m| switch (m[col]) {
                    .int => |n| {
                        itotal += n;
                        total += @floatFromInt(n);
                    },
                    .double => |d| {
                        all_int = false;
                        total += d;
                    },
                    else => return error.ValueType,
                };
                if (op == .sum) return if (all_int) .{ .int = itotal } else .{ .double = total };
                return .{ .double = total / @as(f64, @floatFromInt(members.len)) };
            },
        }
    }

    fn cellValue(self: *Naive, c: Cell) !Value {
        return switch (c) {
            .nil => value.nilValue(),
            .int => |n| value.fromFixnum(n).?,
            .double => |d| value.fromFloat(d),
            .boolean => |b| value.fromBool(b),
            .keyword => |k| value.fromKeywordId(k),
            .str => |s| try string_mod.fromBytes(&self.fx.heap, s),
            .vm => |v| v,
        };
    }

    fn emptyEnv(self: *Naive, n: usize) !Env {
        const e = try self.arena.alloc(?Cell, n);
        @memset(e, null);
        return e;
    }

    fn copy(self: *Naive, e: Env) !Env {
        return self.arena.dupe(?Cell, e);
    }

    /// Every datom of every source's view as cells, plus attribute types.
    fn loadDatoms(self: *Naive) !void {
        const all = try self.arena.alloc([]const [5]Cell, self.dbvs.len);
        for (self.dbvs, self.reads, all, 0..) |dbv, read, *slot, src| {
            const ds = try dbv.datoms(self.arena, .eavt, .{});
            const out = try self.arena.alloc([5]Cell, ds.len);
            for (ds, out) |d, *o| {
                const v: Cell = switch (d.v) {
                    .boolean => |b| .{ .boolean = b },
                    .long, .instant => |n| .{ .int = n },
                    .double => |x| .{ .double = x },
                    .keyword => |id| .{ .keyword = (try dbv.conn.idents.internOf(read.txn, id)).? },
                    .ref => |r| .{ .int = @intCast(r) },
                    .string, .bytes => |s| .{ .str = s },
                    .uuid => |u| blk: {
                        const text = try self.arena.alloc(u8, 36);
                        nextomic.datom.uuidToText(text[0..36], u);
                        break :blk .{ .str = text };
                    },
                };
                o.* = .{ .{ .int = @intCast(d.e) }, .{ .int = d.a }, v, .{ .int = @intCast(key.txEntity(d.t)) }, .{ .boolean = d.added } };
                if (!self.attr_types[src].contains(d.a)) {
                    if (try read.attr(d.a)) |at| try self.attr_types[src].put(self.arena, d.a, at.value_type);
                }
            }
            slot.* = out;
        }
        self.datoms = all;
    }

    /// Bottom-up naive fixpoint of every rule over the whole view of
    /// every source.
    fn computeFacts(self: *Naive) !void {
        for (self.rules.rules) |r| for (0..self.dbvs.len) |src| {
            const k = factKey(r.name, @intCast(src));
            if (!self.facts.contains(k)) try self.facts.put(self.arena, k, .empty);
        };
        var changed = true;
        while (changed) {
            changed = false;
            for (self.rules.rules) |r| for (0..self.dbvs.len) |src| {
                var solved: std.ArrayList(Env) = .empty;
                try self.solve(r.body, try self.emptyEnv(self.rules.vars.len), &solved, @intCast(src));
                const list = self.facts.getPtr(factKey(r.name, @intCast(src))).?;
                for (solved.items) |e| {
                    const tuple = try self.arena.alloc(Cell, r.head.len);
                    var complete = true;
                    for (r.head, tuple) |h, *c| c.* = e[h] orelse {
                        complete = false;
                        break;
                    };
                    if (!complete) continue;
                    if (!containsRow(list.items, tuple)) {
                        try list.append(self.arena, tuple);
                        changed = true;
                    }
                }
            };
        }
    }

    /// `src` is the source an unprefixed clause reads.
    fn solve(self: *Naive, clauses: []const ir.Clause, env: Env, out: *std.ArrayList(Env), src: ir.Src) anyerror!void {
        if (clauses.len == 0) return out.append(self.arena, env);
        const rest = clauses[1..];
        switch (clauses[0]) {
            .pattern => |p| for (self.datoms[p.src orelse src]) |d| {
                const e2 = (try self.matchPattern(p, d, env, p.src orelse src)) orelse continue;
                try self.solve(rest, e2, out, src);
            },
            .pred => |call| if (try self.evalPred(call, env, src)) try self.solve(rest, env, out, src),
            .bind => |b| {
                const results = try self.evalFn(b.call, env, src);
                for (results) |r| {
                    const bound = try self.bind(b.out, r, env);
                    for (bound) |e2| try self.solve(rest, e2, out, src);
                }
            },
            .not => |n| {
                var sub: std.ArrayList(Env) = .empty;
                try self.solve(n.body, env, &sub, src);
                if (sub.items.len == 0) try self.solve(rest, env, out, src);
            },
            .@"or" => |o| {
                var join: std.ArrayList(Var) = .empty;
                if (o.join) |js| {
                    try join.appendSlice(self.arena, js);
                } else try ir.allVars(self.arena, o.branches[0], &join);
                var seen: std.ArrayList(Env) = .empty;
                for (o.branches) |br| {
                    var sub: std.ArrayList(Env) = .empty;
                    try self.solve(br, env, &sub, src);
                    for (sub.items) |s| {
                        const e2 = try self.copy(env);
                        for (join.items) |v| e2[v] = s[v];
                        var dup = false;
                        for (seen.items) |x| if (envEql(x, e2)) {
                            dup = true;
                        };
                        if (dup) continue;
                        try seen.append(self.arena, e2);
                        try self.solve(rest, e2, out, src);
                    }
                }
            },
            .rule => |r| {
                const list = self.facts.get(factKey(r.name, r.src orelse src)) orelse return error.UnknownRule;
                for (list.items) |tuple| {
                    const e2 = (try self.unifyArgs(r.args, tuple, env)) orelse continue;
                    try self.solve(rest, e2, out, src);
                }
            },
            .source => unreachable,
        }
    }

    fn unifyArgs(self: *Naive, args: []const ir.Arg, tuple: Row, env: Env) !?Env {
        const e2 = try self.copy(env);
        for (args, tuple) |a, c| switch (a) {
            .variable => |v| {
                if (e2[v]) |have| {
                    if (!have.eql(c)) return null;
                } else e2[v] = c;
            },
            .constant => |k| if (!k.eql(c)) return null,
            .src => return error.Unsupported,
        };
        return e2;
    }

    /// The attribute id cell of the attribute with ident `kw` in `src`, or null.
    fn attrCell(self: *Naive, kw: u32, src: ir.Src) !?Cell {
        const id = (try self.connOf(src).idents.idOf(self.reads[src].txn, kw)) orelse return null;
        return .{ .int = id };
    }

    const InputRole = struct { entity: bool = false, keyword: bool = false, src: ir.Src = 0 };

    fn markEntity(role: *InputRole, src: ir.Src) void {
        if (!role.entity) role.src = src;
        role.entity = true;
    }

    /// Mark the variables in an entity position or a ref attribute's
    /// value position, and those in a keyword attribute's value position.
    fn inputRoles(self: *Naive, clauses: []const ir.Clause, roles: []InputRole) !void {
        for (clauses) |c| switch (c) {
            .pattern => |p| {
                const src = p.src orelse 0;
                if (p.e.asVar()) |v| markEntity(&roles[v], src);
                const v = p.v.asVar() orelse continue;
                if (p.a != .constant or p.a.constant != .cell or p.a.constant.cell != .keyword) continue;
                const id = (try self.connOf(src).idents.idOf(self.reads[src].txn, p.a.constant.cell.keyword)) orelse continue;
                const at = (try self.reads[src].attr(id)) orelse continue;
                if (at.value_type == .ref) markEntity(&roles[v], src);
                if (at.value_type == .keyword) roles[v].keyword = true;
            },
            .not => |n| try self.inputRoles(n.body, roles),
            .@"or" => |o| for (o.branches) |b| try self.inputRoles(b, roles),
            else => {},
        };
    }

    fn inputEntity(self: *Naive, c: Cell, src: ir.Src) !?u64 {
        const read = self.reads[src];
        switch (c) {
            .keyword => |kw| return read.entid(self.arena, .{ .ident = kw }),
            .vm => |v| {
                if (v.kind() != .persistent_vector or vector_mod.count(v) != 2 or vector_mod.nth(v, 0).kind() != .keyword) return null;
                const attr_id = (try self.connOf(src).idents.idOf(read.txn, vector_mod.nth(v, 0).asKeywordId())) orelse return error.UnknownAttribute;
                const vt = self.attr_types[src].get(attr_id) orelse return error.UnknownAttribute;
                const val = (try cellToVal(Cell.fromValue(vector_mod.nth(v, 1)), vt)) orelse return error.ValueType;
                return read.entid(self.arena, .{ .lookup = .{ .a = attr_id, .v = val } });
            },
            else => return null,
        }
    }

    /// The cell a pattern constant compares as at position `pos` in `src`.
    fn constCell(self: *Naive, c: ir.Constant, pos: usize, d: [5]Cell, src: ir.Src) !?Cell {
        const a = self.arena;
        const read = self.reads[src];
        switch (c) {
            .lookup => |l| {
                const attr_id = (try self.connOf(src).idents.idOf(read.txn, l.attr)) orelse return null;
                const vt = self.attr_types[src].get(attr_id) orelse return null;
                const val = (try cellToVal(l.v, vt)) orelse return null;
                const eid = (try self.dbvs[src].entid(a, .{ .lookup = .{ .a = attr_id, .v = val } })) orelse return null;
                return .{ .int = @intCast(eid) };
            },
            .cell => |cell| {
                if (cell == .keyword) {
                    const is_ref = switch (pos) {
                        0, 1 => true,
                        2 => blk: {
                            const vt = self.attr_types[src].get(@intCast(d[1].int)) orelse break :blk false;
                            break :blk vt == .ref;
                        },
                        else => false,
                    };
                    if (is_ref) {
                        const eid = (try self.connOf(src).idents.idOf(read.txn, cell.keyword)) orelse return null;
                        return .{ .int = @intCast(eid) };
                    }
                }
                if (pos == 3 and cell == .int) {
                    const n = cell.int;
                    if (n < 0) return null;
                    const t = key.txOfEntity(@intCast(n)) orelse @as(u64, @intCast(n));
                    return .{ .int = @intCast(key.txEntity(t)) };
                }
                return cell;
            },
        }
    }

    fn matchPattern(self: *Naive, p: ir.Pattern, d: [5]Cell, env: Env, src: ir.Src) !?Env {
        var e2: ?Env = null;
        for (p.terms(), 0..) |t, pos| {
            switch (t) {
                .blank => {},
                .variable => |v| {
                    const cur = if (e2) |e| e[v] else env[v];
                    if (cur) |have| {
                        // A keyword in the attribute position names the attribute.
                        const want = if (pos == 1 and have == .keyword) (try self.attrCell(have.keyword, src)) orelse return null else have;
                        if (!want.eql(d[pos])) return null;
                    } else {
                        if (e2 == null) e2 = try self.copy(env);
                        e2.?[v] = d[pos];
                    }
                },
                .constant => |c| {
                    const want = (try self.constCell(c, pos, d, src)) orelse return null;
                    if (!want.eql(d[pos])) return null;
                },
            }
        }
        return e2 orelse try self.copy(env);
    }

    fn argCell(a: ir.Arg, env: Env) !Cell {
        return switch (a) {
            .variable => |v| env[v] orelse error.Unbound,
            .constant => |c| c,
            .src => .nil,
        };
    }

    fn evalPred(self: *Naive, call: ir.Call, env: Env, src: ir.Src) !bool {
        const cells = try self.arena.alloc(Cell, call.args.len);
        for (call.args, cells) |a, *c| c.* = try argCell(a, env);
        switch (call.f) {
            .builtin => |b| switch (b) {
                .lt, .le, .gt, .ge => {
                    var i: usize = 0;
                    while (i + 1 < cells.len) : (i += 1) {
                        const o = naiveCompare(self.fx.interner(), cells[i], cells[i + 1]) orelse return error.ValueType;
                        const ok = switch (b) {
                            .lt => o == .lt,
                            .le => o != .gt,
                            .gt => o == .gt,
                            .ge => o != .lt,
                            else => unreachable,
                        };
                        if (!ok) return false;
                    }
                    return true;
                },
                .eq => {
                    for (cells[1..]) |c| if (!cells[0].eql(c)) return false;
                    return true;
                },
                .ne => {
                    for (cells[1..]) |c| if (!cells[0].eql(c)) return true;
                    return false;
                },
                .missing => return (try self.lookup(cells[1], cells[2], call.args[0].src orelse src)) == null,
                else => return error.Unsupported,
            },
            .user => |sym| {
                const vals = try self.arena.alloc(Value, cells.len);
                for (cells, vals) |c, *v| v.* = try self.cellValue(c);
                return (try Fx.hookCall(@ptrCast(self.fx), sym, vals)).isTruthy();
            },
            .variable => |f| {
                const vals = try self.arena.alloc(Value, cells.len);
                for (cells, vals) |c, *v| v.* = try self.cellValue(c);
                return (try Fx.hookApply(@ptrCast(self.fx), try self.cellValue(env[f] orelse return error.Unbound), vals)).isTruthy();
            },
        }
    }

    /// First value of attribute `attr` (keyword cell) on `e` in `src`.
    fn lookup(self: *Naive, e: Cell, attr: Cell, src: ir.Src) !?Cell {
        const attr_id = (try self.connOf(src).idents.idOf(self.reads[src].txn, attr.keyword)) orelse return null;
        for (self.datoms[src]) |d| {
            if (d[0].eql(e) and d[1].int == attr_id) return d[2];
        }
        return null;
    }

    fn evalFn(self: *Naive, call: ir.Call, env: Env, src: ir.Src) ![]Value {
        const cells = try self.arena.alloc(Cell, call.args.len);
        for (call.args, cells) |a, *c| c.* = try argCell(a, env);
        const vals = try self.arena.alloc(Value, cells.len);
        for (cells, vals) |c, *v| v.* = try self.cellValue(c);
        const result: Value = switch (call.f) {
            .builtin => |b| switch (b) {
                .ground, .untuple => vals[0],
                .get_else => try self.cellValue((try self.lookup(cells[1], cells[2], call.args[0].src orelse src)) orelse cells[3]),
                .get_some => blk: {
                    for (cells[2..]) |attr| {
                        const found = (try self.lookup(cells[1], attr, call.args[0].src orelse src)) orelse continue;
                        break :blk try vector_mod.fromSlice(&self.fx.heap, &.{ try self.cellValue(attr), try self.cellValue(found) });
                    }
                    break :blk value.nilValue();
                },
                .tuple => try vector_mod.fromSlice(&self.fx.heap, vals),
                else => return error.Unsupported,
            },
            .user => |sym| try Fx.hookCall(@ptrCast(self.fx), sym, vals),
            .variable => |f| try Fx.hookApply(@ptrCast(self.fx), try self.cellValue(env[f] orelse return error.Unbound), vals),
        };
        return self.arena.dupe(Value, &.{result});
    }

    /// Bind `x` to `c` in `e`: a variable bound already unifies, so
    /// the environment is kept only when the values agree.
    fn unify(e: Env, x: Var, c: Cell) bool {
        if (e[x]) |have| return have.eql(c);
        e[x] = c;
        return true;
    }

    fn unifyTuple(self: *Naive, ts: []const ?Var, v: Value, env: Env) !?Env {
        const e2 = try self.copy(env);
        for (ts, (try seq(self.arena, v))[0..ts.len]) |t, item| if (t) |x| {
            if (!unify(e2, x, Cell.fromValue(item))) return null;
        };
        return e2;
    }

    fn bind(self: *Naive, b: ir.Binding, v: Value, env: Env) ![]Env {
        var out: std.ArrayList(Env) = .empty;
        switch (b) {
            .scalar => |x| if (!v.isNil()) {
                const e2 = try self.copy(env);
                if (unify(e2, x, Cell.fromValue(v))) try out.append(self.arena, e2);
            },
            .collection => |x| for (try seq(self.arena, v)) |item| {
                const e2 = try self.copy(env);
                if (unify(e2, x, Cell.fromValue(item))) try out.append(self.arena, e2);
            },
            .tuple => |ts| if (!v.isNil()) {
                if (try self.unifyTuple(ts, v, env)) |e2| try out.append(self.arena, e2);
            },
            .relation => |ts| for (try seq(self.arena, v)) |row| {
                if (try self.unifyTuple(ts, row, env)) |e2| try out.append(self.arena, e2);
            },
        }
        return out.toOwnedSlice(self.arena);
    }
};

fn cellAsc(names: *Interner, a: Cell, b: Cell) bool {
    return naiveOrder(names, a, b) == .lt;
}

/// The oracle's order: keywords by their text, as `compare` orders
/// them; everything else in the cell order.
fn naiveOrder(names: *Interner, a: Cell, b: Cell) std.math.Order {
    if (a == .keyword and b == .keyword) return std.mem.order(u8, names.keywordName(a.keyword), names.keywordName(b.keyword));
    return a.order(b);
}

/// The oracle's comparison: values of one type (int and double are
/// one), never VM values.
fn naiveCompare(names: *Interner, a: Cell, b: Cell) ?std.math.Order {
    const numeric = (a == .int or a == .double) and (b == .int or b == .double);
    if (!numeric and std.meta.activeTag(a) != std.meta.activeTag(b)) return null;
    if (a == .vm) return null;
    return naiveOrder(names, a, b);
}

fn num(c: Cell) !f64 {
    return switch (c) {
        .int => |n| @floatFromInt(n),
        .double => |d| d,
        else => error.ValueType,
    };
}

fn cellToVal(c: Cell, vt: key.ValueType) !?key.Val {
    return switch (vt) {
        .string => if (c == .str) .{ .string = c.str } else null,
        .long => if (c == .int) .{ .long = c.int } else null,
        .double => if (c == .double) .{ .double = c.double } else null,
        .ref => if (c.asEid()) |e| .{ .ref = e } else null,
        .boolean => if (c == .boolean) .{ .boolean = c.boolean } else null,
        else => null,
    };
}

fn seq(arena: Allocator, v: Value) ![]Value {
    var out: std.ArrayList(Value) = .empty;
    switch (v.kind()) {
        .persistent_vector => {
            var it = vector_mod.Cursor.init(v);
            while (it.next()) |x| try out.append(arena, x);
        },
        .list => {
            var it = list_mod.Cursor.init(v);
            while (it.next()) |x| try out.append(arena, x);
        },
        .persistent_set => {
            var it = champ.setIter(v);
            while (it.next()) |x| try out.append(arena, x);
        },
        else => return error.NotASeq,
    }
    return out.toOwnedSlice(arena);
}

fn rowEql(a: Row, b: Row) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!x.eql(y)) return false;
    return true;
}

fn containsRow(rows: []const Row, row: Row) bool {
    for (rows) |r| if (rowEql(r, row)) return true;
    return false;
}

fn envEql(a: Env, b: Env) bool {
    for (a, b) |x, y| {
        if (x == null and y == null) continue;
        if (x == null or y == null) return false;
        if (!x.?.eql(y.?)) return false;
    }
    return true;
}

fn indexOf(vars: []const Var, v: Var) usize {
    return std.mem.indexOfScalar(Var, vars, v).?;
}

// =============================================================================
// The corpus
// =============================================================================

const rules_src =
    \\[[(friend ?a ?b) [?a :person/friend ?b]]
    \\ [(friend ?a ?b) [?b :person/friend ?a]]
    \\ [(admin ?p) [?p :person/role :role/admin]]
    \\ [(reach ?a ?b) [?a :edge/to ?b]]
    \\ [(reach ?a ?b) (reach ?a ?m) [?m :edge/to ?b]]
    \\ [(reach-left ?a ?b) [?a :edge/to ?b]]
    \\ [(reach-left ?a ?b) [?a :edge/to ?m] (reach-left ?m ?b)]
    \\ [(even-hops ?a ?b) [?a :edge/to ?m] (odd-hops ?m ?b)]
    \\ [(odd-hops ?a ?b) [?a :edge/to ?b]]
    \\ [(odd-hops ?a ?b) [?a :edge/to ?m] (even-hops ?m ?b)]
    \\ [(labeled ?n ?l) [?n :node/label ?l]]
    \\ [(reach-label [?a] ?l) (reach ?a ?b) (labeled ?b ?l)]
    \\ [(older ?p ?q) [?p :person/age ?x] [?q :person/age ?y] [(> ?x ?y)]]
    \\ [(has-tag ?p ?t) [?p :person/tags ?t]]
    \\ [(has-tag ?p ?t) (friend ?p ?f) [?f :person/tags ?t]]]
;

test "corpus: patterns, constants, joins, predicates, functions, aggregates, find specs" {
    const fx = try Fx.init("q_corpus");
    defer fx.deinit();
    try loadCorpus(fx);
    const dbv = try fx.db();
    const none: []const Value = &.{value.nilValue()};

    // Constants in every position, wildcards, single patterns.
    try checkCount(fx, dbv, "[:find ?e ?n :where [?e :person/name ?n]]", none, 6);
    try checkCount(fx, dbv, "[:find ?e :where [?e :person/name \"Ann\"]]", none, 1);
    try checkCount(fx, dbv, "[:find ?e :where [?e :person/age 30]]", none, 2);
    try checkCount(fx, dbv, "[:find ?e :where [?e :person/height 1.8]]", none, 1);
    try checkCount(fx, dbv, "[:find ?e :where [?e :person/active true]]", none, 3);
    try checkCount(fx, dbv, "[:find ?e :where [?e :person/tags :blue]]", none, 2);
    try checkCount(fx, dbv, "[:find ?e :where [?e :person/role :role/admin]]", none, 2);
    try checkCount(fx, dbv, "[:find ?a ?v :where [[:person/email \"bob@x\"] ?a ?v]]", none, 9);
    try checkCount(fx, dbv, "[:find ?v :where [[:person/email \"ann@x\"] :person/tags ?v]]", none, 1);
    try checkCount(fx, dbv, "[:find ?e :where [?e :person/friend [:person/email \"ann@x\"]]]", none, 2);
    try checkCount(fx, dbv, "[:find ?e :where [?e :person/boss [:person/email \"ann@x\"]]]", none, 2);
    try checkCount(fx, dbv, "[:find ?e :where [?e _ [:person/email \"cy@x\"]]]", none, 2);
    try checkCount(fx, dbv, "[:find ?a :where [:person/name ?a _]]", none, 4);
    try checkCount(fx, dbv, "[:find ?e :where [?e :person/age _]]", none, 6);
    try checkCount(fx, dbv, "[:find ?e :where [?e :person/name]]", none, 6);
    try testing.expectError(error.UnknownAttribute, runEngine(fx, fx.arena(), dbv, "[:find ?e :where [?e :person/nope ?v]]", none));
    try checkCount(fx, dbv, "[:find ?e :where [?e :person/name 42]]", none, 0);
    try checkCount(fx, dbv, "[:find ?e :where [?e :person/tags :nowhere/kw]]", none, 0);
    try checkCount(fx, dbv, "[:find ?e :where [?e :person/friend [:person/email \"nobody\"]]]", none, 0);

    // Long strings (out of line) match by value.
    const bio = try std.fmt.allocPrint(fx.arena(), "[:find ?e :where [?e :person/bio \"{s}\"]]", .{long_bio_a});
    try checkCount(fx, dbv, bio, none, 1);
    const bio_x = try std.fmt.allocPrint(fx.arena(), "[:find ?e :where [?e :person/bio \"{s}\"]]", .{long_bio_x});
    try checkCount(fx, dbv, bio_x, none, 0);
    try checkCount(fx, dbv, "[:find ?e ?b :where [?e :person/bio ?b]]", none, 2);

    // Multi-way joins in both directions.
    try checkCount(fx, dbv, "[:find ?n ?fn :where [?e :person/name ?n] [?e :person/friend ?f] [?f :person/name ?fn]]", none, 4);
    try checkCount(fx, dbv, "[:find ?n ?bn :where [?e :person/boss ?b] [?b :person/name ?bn] [?e :person/name ?n]]", none, 3);
    try checkCount(fx, dbv, "[:find ?n ?num ?st :where [?o :order/customer ?c] [?c :person/name ?n] [?o :order/number ?num] [?o :order/status ?st]]", none, 4);
    try checkCount(fx, dbv, "[:find ?n :where [?o :order/status :status/shipped] [?o :order/customer ?c] [?c :person/name ?n]]", none, 2);
    try checkCount(fx, dbv, "[:find ?n :where [?c :person/name ?n] [?o :order/customer ?c] [?o :order/items \"apple\"]]", none, 2);
    try checkCount(fx, dbv, "[:find ?e ?f :where [?e :person/friend ?f] [?f :person/friend ?e]]", none, 0);
    try checkCount(fx, dbv, "[:find ?e :where [?e :person/friend ?f] [?e :person/boss ?f]]", none, 3);
    try checkCount(fx, dbv, "[:find ?a ?b :where [?a :person/age ?x] [?b :person/age ?x] [(not= ?a ?b)]]", none, 2);
    try checkCount(fx, dbv, "[:find ?e ?tx :where [?e :person/name \"Flo\" ?tx]]", none, 1);
    try checkCount(fx, dbv, "[:find ?e ?t :where [?e :person/name \"Flo\" ?tx] [?tx :db/txInstant ?t]]", none, 1);
    try checkCount(fx, dbv, "[:find ?e :where [?e :person/name \"Flo\" 6]]", none, 1);
    try checkCount(fx, dbv, "[:find ?e :where [?e :person/name \"Ann\" 6]]", none, 0);
    try checkCount(fx, dbv, "[:find ?e ?added :where [?e :person/name \"Ann\" _ ?added]]", none, 1);
    try checkCount(fx, dbv, "[:find ?e :where [?e :person/name \"Ann\" _ true]]", none, 1);
    try checkCount(fx, dbv, "[:find ?e :where [?e :person/name \"Ann\" _ false]]", none, 0);

    // Predicates.
    try checkCount(fx, dbv, "[:find ?n :where [?e :person/age ?a] [(< ?a 30)] [?e :person/name ?n]]", none, 1);
    try checkCount(fx, dbv, "[:find ?n :where [?e :person/age ?a] [(>= ?a 30)] [(<= ?a 41)] [?e :person/name ?n]]", none, 4);
    try checkCount(fx, dbv, "[:find ?n :where [?e :person/name ?n] [(> ?n \"C\")]]", none, 4);
    // A comparison across value types is an error, never a row.
    for ([_][]const u8{
        "[:find ?n :where [?e :person/name ?n] [(> ?n 5)]]",
        "[:find ?n :where [?e :person/name ?n] [?e :person/age ?a] [(< ?a ?n)]]",
        "[:find ?n :where [?e :person/name ?n] [?e :person/active ?x] [(<= ?x 1)]]",
        "[:find ?n :where [?e :person/name ?n] [?e :person/role ?r] [(>= ?r :role/admin)] [(< ?r \"z\")]]",
    }) |src| {
        try testing.expectError(error.ValueType, runEngine(fx, fx.arena(), dbv, src, none));
        try testing.expectError(error.ValueType, Naive.run(fx, fx.arena(), dbv, src, none));
    }
    try checkCount(fx, dbv, "[:find ?n :where [?e :person/name ?n] [?e :person/height ?h] [(< ?h 2)]]", none, 3);
    try checkCount(fx, dbv, "[:find ?n :where [?e :person/height ?h] [(< 1.66 ?h)] [?e :person/name ?n]]", none, 2);
    try checkCount(fx, dbv, "[:find ?n :where [?e :person/name ?n] [(= ?n \"Cy\")]]", none, 1);
    try checkCount(fx, dbv, "[:find ?n :where [?e :person/name ?n] [(not= ?n \"Cy\")]]", none, 5);
    try checkCount(fx, dbv, "[:find ?n :where [?e :person/name ?n] [(missing? $ ?e :person/bio)]]", none, 4);
    try checkCount(fx, dbv, "[:find ?n :where [?e :person/name ?n] [(even? ?e)]]", none, 3);
    try checkCount(fx, dbv, "[:find ?n :where [?e :person/age ?a] [?e :person/name ?n] [(< 20 ?a 31)]]", none, 3);

    // Function bindings, every binding form.
    try checkCount(fx, dbv, "[:find ?n ?a1 :where [?e :person/age ?a] [(inc ?a) ?a1] [?e :person/name ?n]]", none, 6);
    try checkCount(fx, dbv, "[:find ?s :where [?e :person/name ?n] [?e :person/age ?a] [(str ?n \"-\" ?a) ?s]]", none, 6);
    try checkCount(fx, dbv, "[:find ?u :where [?e :person/name ?n] [(upper ?n) ?u]]", none, 6);
    try checkCount(fx, dbv, "[:find ?n ?i :where [?e :person/name ?n] [(range 3) [?i ...]]]", none, 18);
    try checkCount(fx, dbv, "[:find ?n ?x ?y :where [?e :person/name ?n] [?e :person/age ?a] [(pair ?a ?n) [?x ?y]]]", none, 6);
    try checkCount(fx, dbv, "[:find ?n ?h :where [?e :person/name ?n] [?e :person/age ?a] [(halves ?a) [[_ ?h]]]]", none, 12);
    try checkCount(fx, dbv, "[:find ?n ?m :where [?e :person/name ?n] [?e :person/age ?a] [(maybe ?a) ?m]]", none, 3);
    try checkCount(fx, dbv, "[:find ?n ?b :where [?e :person/name ?n] [(get-else $ ?e :person/bio \"none\") ?b]]", none, 6);
    try checkCount(fx, dbv, "[:find ?x :where [(ground 7) ?x]]", none, 1);
    try checkCount(fx, dbv, "[:find ?x :where [(ground [1 2 3]) [?x ...]]]", none, 3);
    try checkCount(fx, dbv, "[:find ?x ?y :where [(ground [[1 2] [3 4]]) [[?x ?y]]]]", none, 2);
    try checkCount(fx, dbv, "[:find ?t :where [?e :person/name \"Ann\"] [?e :person/age ?a] [(tuple ?a \"x\") ?t]]", none, 1);
    try checkCount(fx, dbv, "[:find ?a ?b :where [(ground [10 20]) ?t] [(untuple ?t) [?a ?b]]]", none, 1);
    try checkCount(fx, dbv, "[:find ?n ?a2 :where [?e :person/name ?n] [?e :person/age ?a] [(add ?a ?a) ?a2] [(> ?a2 60)]]", none, 3);
    // get-some binds [attr value] for the first attribute present; != is not=;
    // identity, str, subs and count are ordinary functions through the hook.
    try checkCount(fx, dbv, "[:find ?n ?a ?v :where [?e :person/name ?n] [(get-some $ ?e :person/bio :person/height :person/age) [?a ?v]]]", none, 6);
    try checkCount(fx, dbv, "[:find ?n :where [?e :person/name ?n] [(get-some $ ?e :person/bio :person/height) [?a ?v]] [(= ?a :person/bio)]]", none, 2);
    try checkCount(fx, dbv, "[:find ?n :where [?e :person/name ?n] [(get-some $ ?e :person/tags :person/bio) [_ ?v]]]", none, 5);
    try checkCount(fx, dbv, "[:find ?n :where [?e :person/name ?n] [(get-some $ ?e :person/role :person/bio) [?a ?v]]]", none, 4);
    try checkCount(fx, dbv, "[:find ?n :where [?e :person/name ?n] [(!= ?n \"Cy\")]]", none, 5);
    try checkCount(fx, dbv, "[:find ?n ?m :where [?e :person/name ?n] [(identity ?n) ?m]]", none, 6);
    try checkCount(fx, dbv, "[:find ?s :where [?e :person/name ?n] [(str ?n \"!\") ?s]]", none, 6);
    try checkCount(fx, dbv, "[:find ?p :where [?e :person/name ?n] [(subs ?n 0 1) ?p]]", none, 6);
    try checkCount(fx, dbv, "[:find ?n :where [?e :person/name ?n] [(count ?n) ?c] [(< ?c 3)]]", none, 2);
    try checkCount(fx, dbv, "[:find ?x :where [(ground [7 8]) ?t] [(untuple ?t) [?x _]]]", none, 1);
    try checkCount(fx, dbv, "[:find ?t :where [?e :person/name \"Ann\"] [?e :person/age ?a] [(tuple ?a ?e) ?t] [(untuple ?t) [?a2 ?e2]] [(= ?a ?a2)] [(= ?e ?e2)]]", none, 1);
    for ([_][]const u8{
        "[:find ?n :where [?e :person/name ?n] [(get-some $ ?e) [?a ?v]]]",
        "[:find ?n :where [?e :person/name ?n] [(get-some $ ?e \"bio\") [?a ?v]]]",
        "[:find ?n :where [?e :person/name ?n] [(get-some $ ?e :person/bio)]]",
    }) |src| {
        var d: query.Diag = .{};
        try testing.expectError(error.QuerySyntax, runEngineDiag(fx, fx.arena(), dbv, src, none, &d));
        try testing.expect(d.message.len > 0);
    }
    // An output variable bound before the step unifies: the clause
    // keeps the rows whose result equals the bound value, including
    // when the planner runs a cheaper pattern before the function.
    try checkCount(fx, dbv, "[:find ?n :where [?e :person/name ?n] [(identity ?e) ?e]]", none, 6);
    try checkCount(fx, dbv, "[:find ?n :where [?e :person/name ?n] [(str ?n \"!\") ?n]]", none, 0);
    try checkCount(fx, dbv, "[:find ?n :where [?e :person/age ?a] [(inc ?a) ?a] [?e :person/name ?n]]", none, 0);
    try checkCount(fx, dbv, "[:find ?a :where [?e :person/age ?a] [(identity ?e) ?e2] [?e2 :person/email \"ann@x\"]]", none, 1);
    try checkCount(fx, dbv, "[:find ?n :where [?e :person/name ?n] [?e :person/age ?a] [(pair ?a ?n) [?a ?x]]]", none, 6);
    try checkCount(fx, dbv, "[:find ?n :where [?e :person/name ?n] [?e :person/age ?a] [(pair ?n ?a) [?a ?x]]]", none, 0);
    try checkCount(fx, dbv, "[:find ?n :where [?e :person/name ?n] [?e :person/age ?a] [(range 31) [?a ...]]]", none, 3);
    try checkCount(fx, dbv, "[:find ?n :where [?e :person/name ?n] [?e :person/age ?a] [(halves ?a) [[_ ?a]]]]", none, 0);
    try checkCount(fx, dbv, "[:find ?n :where [?e :person/name ?n] [?e :person/age ?a] [(halves ?a) [[?a ?h]]]]", none, 6);

    // A query is not capped in its number of variables.
    {
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(testing.allocator);
        try src.appendSlice(testing.allocator, "[:find ?v99 :where [?e :person/age ?v0]");
        for (1..100) |i| try src.print(testing.allocator, " [(inc ?v{d}) ?v{d}]", .{ i - 1, i });
        try src.append(testing.allocator, ']');
        try checkCount(fx, dbv, src.items, none, 5);
    }

    // Aggregates and :with.
    try checkCount(fx, dbv, "[:find (count ?e) :where [?e :person/name _]]", none, 1);
    try checkCount(fx, dbv, "[:find (count ?a) :where [_ :person/age ?a]]", none, 1);
    try checkCount(fx, dbv, "[:find (count ?a) :with ?e :where [?e :person/age ?a]]", none, 1);
    try checkCount(fx, dbv, "[:find (sum ?a) (min ?a) (max ?a) (avg ?a) (count-distinct ?a) :with ?e :where [?e :person/age ?a]]", none, 1);
    try checkCount(fx, dbv, "[:find ?st (sum ?t) :where [?o :order/status ?st] [?o :order/total ?t]]", none, 2);
    try checkCount(fx, dbv, "[:find ?n (count ?o) :where [?o :order/customer ?c] [?c :person/name ?n]]", none, 3);
    try checkCount(fx, dbv, "[:find ?n (distinct ?i) :where [?o :order/customer ?c] [?c :person/name ?n] [?o :order/items ?i]]", none, 3);
    try checkCount(fx, dbv, "[:find (max ?n) :where [_ :person/name ?n]]", none, 1);
    try checkCount(fx, dbv, "[:find ?t :with ?o :where [?o :order/status :status/open] [?o :order/total ?t]]", none, 2);
    // Statistics, n-ary min and max, a custom aggregate over the group.
    try checkCount(fx, dbv, "[:find (median ?a) (variance ?a) (stddev ?a) :with ?e :where [?e :person/age ?a]]", none, 1);
    try checkCount(fx, dbv, "[:find (median ?h) :where [_ :person/height ?h]]", none, 1);
    try checkCount(fx, dbv, "[:find (median ?n) :where [?e :person/boss _] [?e :person/name ?n]]", none, 1);
    try checkCount(fx, dbv, "[:find ?st (median ?t) (max 2 ?t) (min 1 ?t) :where [?o :order/status ?st] [?o :order/total ?t]]", none, 2);
    try checkCount(fx, dbv, "[:find (max 3 ?a) (min 10 ?a) :with ?e :where [?e :person/age ?a]]", none, 1);
    try checkCount(fx, dbv, "[:find ?n (total ?a) :with ?o :where [?o :order/customer ?c] [?c :person/name ?n] [?o :order/number ?a]]", none, 3);
    try checkCount(fx, dbv, "[:find (total ?a) :with ?e :where [?e :person/age ?a]]", none, 1);
    for ([_][]const u8{
        "[:find (median ?n) (variance ?n) :where [_ :person/name ?n]]",
        "[:find (stddev ?r) :where [_ :person/role ?r]]",
    }) |src| {
        try testing.expectError(error.ValueType, runEngine(fx, fx.arena(), dbv, src, none));
        try testing.expectError(error.ValueType, Naive.run(fx, fx.arena(), dbv, src, none));
    }

    // Find specs (the row shape is the same; the value shape is checked below).
    try checkCount(fx, dbv, "[:find ?n . :where [?e :person/name ?n] [?e :person/age 55]]", none, 1);
    try checkCount(fx, dbv, "[:find [?n ...] :where [?e :person/name ?n]]", none, 6);
    try checkCount(fx, dbv, "[:find [?n ?a] :where [?e :person/name ?n] [?e :person/age ?a] [?e :person/email \"cy@x\"]]", none, 1);
    try checkCount(fx, dbv, "[:find (count ?e) . :where [?e :person/tags :green]]", none, 1);
    try checkCount(fx, dbv, "[:find [(min ?a) (max ?a)] :where [_ :person/age ?a]]", none, 1);

    // Pull expressions and :keys shape the value, not the rows.
    try checkCount(fx, dbv, "[:find (pull ?e [:person/name]) :where [?e :person/age 30]]", none, 2);
    try checkCount(fx, dbv, "[:find (pull ?e [*]) ?n :where [?e :person/name ?n] [?e :person/tags _]]", none, 4);
    try checkCount(fx, dbv, "[:find (pull ?c [:person/name]) (count ?o) :where [?o :order/customer ?c]]", none, 3);
    try checkCount(fx, dbv, "[:find [(pull ?e [:person/name]) ...] :where [?e :person/tags :green]]", none, 2);
    try checkCount(fx, dbv, "[:find ?n ?a :keys name age :where [?e :person/name ?n] [?e :person/age ?a]]", none, 6);
    try checkCount(fx, dbv, "[:find ?st (sum ?t) :strs status total :where [?o :order/status ?st] [?o :order/total ?t]]", none, 2);

    // Map form.
    try checkCount(fx, dbv, "{:find [?n] :where [[?e :person/name ?n] [?e :person/tags :green]]}", none, 2);
    try checkCount(fx, dbv, "{:find [?n ?a] :keys [n a] :where [[?e :person/name ?n] [?e :person/age ?a]]}", none, 6);
}

test "corpus: every :in form" {
    const fx = try Fx.init("q_in");
    defer fx.deinit();
    try loadCorpus(fx);
    const dbv = try fx.db();
    const nil = value.nilValue();

    try checkCount(fx, dbv, "[:find ?e :in $ ?n :where [?e :person/name ?n]]", &.{ nil, try fx.str("Cy") }, 1);
    try checkCount(fx, dbv, "[:find ?e :in $ ?a :where [?e :person/age ?a]]", &.{ nil, value.fromFixnum(30).? }, 2);
    try checkCount(fx, dbv, "[:find ?e :in $ ?t :where [?e :person/tags ?t]]", &.{ nil, value.fromKeywordId(try fx.kwId("green")) }, 2);
    try checkCount(fx, dbv, "[:find ?n :in $ ?e :where [?e :person/name ?n]]", &.{ nil, value.fromFixnum(@intCast(key.user_partition_start)).? }, 1);
    try checkCount(fx, dbv, "[:find ?e :in $ [?n ...] :where [?e :person/name ?n]]", &.{ nil, try fx.read("[\"Ann\" \"Bob\" \"Nobody\"]") }, 2);
    try checkCount(fx, dbv, "[:find ?e :in $ [?n ?a] :where [?e :person/name ?n] [?e :person/age ?a]]", &.{ nil, try fx.read("[\"Ann\" 30]") }, 1);
    try checkCount(fx, dbv, "[:find ?e :in $ [?n _] :where [?e :person/name ?n]]", &.{ nil, try fx.read("[\"Ann\" 99]") }, 1);
    try checkCount(fx, dbv, "[:find ?e ?a :in $ [[?n ?a]] :where [?e :person/name ?n] [?e :person/age ?a]]", &.{ nil, try fx.read("[[\"Ann\" 30] [\"Bob\" 26] [\"Bob\" 1]]") }, 2);
    try checkCount(fx, dbv, "[:find ?e :in $ ?lo ?hi :where [?e :person/age ?a] [(< ?lo ?a ?hi)]]", &.{ nil, value.fromFixnum(29).?, value.fromFixnum(34).? }, 3);
    try checkCount(fx, dbv, "[:find ?n ?x :in $ [?x ...] :where [?e :person/name ?n] [?e :person/age ?a] [(< ?a ?x)]]", &.{ nil, try fx.read("[27 31]") }, 4);
    try checkCount(fx, dbv, "[:find ?p :in $ % :where (admin ?p)]", &.{ nil, try fx.read(rules_src) }, 2);
    try checkCount(fx, dbv, "[:find ?n :in $ % ?t :where (has-tag ?p ?t) [?p :person/name ?n]]", &.{ nil, try fx.read(rules_src), value.fromKeywordId(try fx.kwId("green")) }, 4);
    try checkCount(fx, dbv, "[:find ?x :in $ ?x]", &.{ nil, value.fromFixnum(5).? }, 1);
    // A variable in function position applies the value it holds: as
    // a predicate, as a function binding under every binding form, in
    // a rule body, and bound by an earlier clause rather than `:in`.
    const even_fn = try fx.read("even?");
    const inc_fn = try fx.read("inc");
    try checkCount(fx, dbv, "[:find ?n :in $ ?pred :where [?e :person/name ?n] [?e :person/age ?a] [(?pred ?a)]]", &.{ nil, even_fn }, 3);
    try checkCount(fx, dbv, "[:find ?n ?a1 :in $ ?f :where [?e :person/name ?n] [?e :person/age ?a] [(?f ?a) ?a1]]", &.{ nil, inc_fn }, 6);
    try checkCount(fx, dbv, "[:find ?n ?i :in $ ?f :where [?e :person/name ?n] [(?f 2) [?i ...]]]", &.{ nil, try fx.read("range") }, 12);
    try checkCount(fx, dbv, "[:find ?n ?x ?y :in $ ?f :where [?e :person/name ?n] [?e :person/age ?a] [(?f ?a ?n) [?x ?y]]]", &.{ nil, try fx.read("pair") }, 6);
    try checkCount(fx, dbv, "[:find ?n ?h :in $ ?f :where [?e :person/name ?n] [?e :person/age ?a] [(?f ?a) [[_ ?h]]]]", &.{ nil, try fx.read("halves") }, 12);
    try checkCount(fx, dbv, "[:find ?n :in $ [?f ...] :where [?e :person/name ?n] [?e :person/age ?a] [(?f ?a) ?r] [(> ?r 41)]]", &.{ nil, try fx.read("[inc identity]") }, 2);
    try checkCount(fx, dbv, "[:find ?n :in $ ?f :where [(ground [1 2]) [?x ...]] [(?f ?x ?x) ?y] [?e :person/age ?a] [(< ?y 3)] [?e :person/name ?n]]", &.{ nil, try fx.read("add") }, 6);
    // The naive fixpoint runs rule bodies with nothing bound, so a rule
    // that applies a head-bound function is checked by row count.
    const via_rule = try runEngine(fx, fx.arena(), dbv, "[:find ?n :in $ % ?pred :where (age-ok ?p ?pred) [?p :person/name ?n]]", &.{ nil, try fx.read("[[(age-ok ?p ?f) [?p :person/age ?a] [(?f ?a)]]]"), even_fn });
    try testing.expectEqual(@as(usize, 3), via_rule.len);
    try checkCount(fx, dbv, "[:find ?n :in $ ?g :where [(identity ?g) ?pred] [?e :person/age ?a] [(?pred ?a)] [?e :person/name ?n]]", &.{ nil, even_fn }, 3);
    // A keyword in function position looks itself up in a map.
    try checkCount(fx, dbv, "[:find ?n ?v :in $ ?k :where [?e :person/name ?n] [(ground {:x 1}) ?m] [(?k ?m) ?v]]", &.{ nil, value.fromKeywordId(try fx.kwId("x")) }, 6);
    try checkCount(fx, dbv, "[:find ?n :in $ ?k :where [?e :person/name ?n] [(ground {:x 1}) ?m] [(?k ?m) ?v]]", &.{ nil, value.fromKeywordId(try fx.kwId("y")) }, 0);
    // A value that is not callable is an error, and the function
    // variable must be bound before the call runs.
    try testing.expectError(error.NotCallable, runEngine(fx, fx.arena(), dbv, "[:find ?n :in $ ?f :where [?e :person/name ?n] [(?f ?n)]]", &.{ nil, value.fromFixnum(7).? }));
    try testing.expectError(error.NotCallable, Naive.run(fx, fx.arena(), dbv, "[:find ?n :in $ ?f :where [?e :person/name ?n] [(?f ?n)]]", &.{ nil, value.fromFixnum(7).? }));
    try testing.expectError(error.QuerySyntax, runEngine(fx, fx.arena(), dbv, "[:find ?n :where [?e :person/name ?n] [(?f ?n)]]", &.{nil}));
    // A bound attribute variable, by id and by ident; an unknown ident matches nothing.
    const name_id = (try dbv.entid(fx.arena(), .{ .ident = try fx.kwId("person/name") })).?;
    try checkCount(fx, dbv, "[:find ?e :in $ ?a :where [?e ?a ?v]]", &.{ nil, value.fromFixnum(@intCast(name_id)).? }, 6);
    try checkCount(fx, dbv, "[:find ?e :in $ ?a :where [?e ?a ?v]]", &.{ nil, value.fromKeywordId(try fx.kwId("person/name")) }, 6);
    try checkCount(fx, dbv, "[:find ?e :in $ ?a :where [?e ?a \"Cy\"]]", &.{ nil, value.fromKeywordId(try fx.kwId("person/name")) }, 1);
    try checkCount(fx, dbv, "[:find ?v :in $ ?a ?e :where [?e ?a ?v]]", &.{ nil, value.fromKeywordId(try fx.kwId("person/tags")), value.fromFixnum(@intCast(key.user_partition_start)).? }, 1);
    try checkCount(fx, dbv, "[:find ?e :in $ ?a :where [?e ?a ?v]]", &.{ nil, value.fromKeywordId(try fx.kwId("nope/attr")) }, 0);
    // A bound value with no attribute: a string or keyword is matched across every attribute.
    try checkCount(fx, dbv, "[:find ?e :in $ ?v :where [?e _ ?v]]", &.{ nil, try fx.str("Cy") }, 1);
    try checkCount(fx, dbv, "[:find ?e ?a :in $ ?v :where [?e ?a ?v]]", &.{ nil, value.fromKeywordId(try fx.kwId("green")) }, 2);
    try checkCount(fx, dbv, "[:find ?e :where [?e _ \"Cy\"]]", &.{nil}, 1);
    try checkCount(fx, dbv, "[:find ?e ?a :where [?e ?a \"Cy\"]]", &.{nil}, 1);
    try checkCount(fx, dbv, "[:find ?e :where [?e _ \"Nobody\"]]", &.{nil}, 0);
    try checkCount(fx, dbv, "[:find ?x ?y :in $ [?x ...] [?y ...]]", &.{ nil, try fx.read("[1 2]"), try fx.read("[3 4 3]") }, 4);
    // A lookup ref or an ident bound to a variable in an entity position, or
    // in the value position of a ref attribute, is the entity id; one that
    // resolves to nothing binds nothing. Keyword-attribute values stay
    // keywords.
    const ann_ref = try fx.read("[:person/email \"ann@x\"]");
    try checkCount(fx, dbv, "[:find ?n :in $ ?e :where [?e :person/name ?n]]", &.{ nil, ann_ref }, 1);
    const as_eid = try check(fx, dbv, "[:find ?e :in $ ?e :where [?e :person/name _]]", &.{ nil, ann_ref });
    try testing.expectEqual(@as(i64, @intCast(key.user_partition_start)), as_eid.cell(0, 0).int);
    try checkCount(fx, dbv, "[:find ?e :in $ ?e :where [?e :db/ident _]]", &.{ nil, value.fromKeywordId(try fx.kwId("role/admin")) }, 1);
    try checkCount(fx, dbv, "[:find ?n :in $ [?e ...] :where [?e :person/name ?n]]", &.{ nil, try fx.read("[[:person/email \"ann@x\"] [:person/email \"bob@x\"] [:person/email \"nobody@x\"]]") }, 2);
    try checkCount(fx, dbv, "[:find ?n :in $ ?b :where [?e :person/boss ?b] [?e :person/name ?n]]", &.{ nil, ann_ref }, 2);
    try checkCount(fx, dbv, "[:find ?n :in $ [?b ?a] :where [?e :person/boss ?b] [?e :person/age ?a] [?e :person/name ?n]]", &.{ nil, try fx.read("[[:person/email \"ann@x\"] 26]") }, 1);
    try checkCount(fx, dbv, "[:find ?n :in $ [[?e ?a]] :where [?e :person/age ?a] [?e :person/name ?n]]", &.{ nil, try fx.read("[[[:person/email \"ann@x\"] 30] [[:person/email \"bob@x\"] 1] [:role/admin 5]]") }, 1);
    try checkCount(fx, dbv, "[:find ?n :in $ ?r :where [?e :person/role ?r] [?e :person/name ?n]]", &.{ nil, value.fromKeywordId(try fx.kwId("role/admin")) }, 2);
    try checkCount(fx, dbv, "[:find ?n :in $ ?e :where [?e :person/name ?n]]", &.{ nil, try fx.read("[:person/email \"nobody@x\"]") }, 0);
    try testing.expectError(error.ValueType, runEngine(fx, fx.arena(), dbv, "[:find ?n :in $ ?e :where [?e :person/name ?n]]", &.{ nil, try fx.read("[:person/email 5]") }));
    try checkCount(fx, dbv, "[:find ?n :in $ ?e :where [?e :person/name ?n]]", &.{ nil, value.fromKeywordId(try fx.kwId("role/nobody")) }, 0);
    try checkCount(fx, dbv, "[:find ?n :in $ ?e :where (not [?e :person/age 30]) [?e :person/name ?n]]", &.{ nil, ann_ref }, 0);
    try testing.expectError(error.TxData, runEngine(fx, fx.arena(), dbv, "[:find ?n :in $ ?e :where [?e :person/name ?n]]", &.{ nil, try fx.read("[:person/name \"Ann\"]") }));
    try testing.expectError(error.UnknownAttribute, runEngine(fx, fx.arena(), dbv, "[:find ?n :in $ ?e :where [?e :person/name ?n]]", &.{ nil, try fx.read("[:nope/attr \"Ann\"]") }));
    // Wrong input count and shape.
    try testing.expectError(error.QuerySyntax, runEngine(fx, fx.arena(), dbv, "[:find ?e :in $ ?n :where [?e :person/name ?n]]", &.{nil}));
    try testing.expectError(error.ValueType, runEngine(fx, fx.arena(), dbv, "[:find ?e :in $ [?n ...] :where [?e :person/name ?n]]", &.{ nil, value.fromFixnum(1).? }));
    try testing.expectError(error.ValueType, runEngine(fx, fx.arena(), dbv, "[:find ?e :in $ [[?n ?a]] :where [?e :person/name ?n]]", &.{ nil, try fx.read("[[\"Ann\"]]") }));
    // An unknown attribute in a lookup-ref input is named in the diagnostic.
    var in_diag: query.Diag = .{};
    try testing.expectError(error.UnknownAttribute, runEngineDiag(fx, fx.arena(), dbv, "[:find ?n :in $ ?e :where [?e :person/name ?n]]", &.{ nil, try fx.read("[:nope/attr \"Ann\"]") }, &in_diag));
    try testing.expectEqual(try fx.kwId("nope/attr"), in_diag.attr.?.asKeywordId());
}

test "corpus: not, not-join, or, or-join, and" {
    const fx = try Fx.init("q_notor");
    defer fx.deinit();
    try loadCorpus(fx);
    const dbv = try fx.db();
    const none: []const Value = &.{value.nilValue()};

    try checkCount(fx, dbv, "[:find ?n :where [?e :person/name ?n] (not [?e :person/tags _])]", none, 2);
    try checkCount(fx, dbv, "[:find ?n :where [?e :person/name ?n] (not [?e :person/tags :blue])]", none, 4);
    try checkCount(fx, dbv, "[:find ?n :where [?e :person/name ?n] (not [?e :person/friend ?f] [?f :person/age 30])]", none, 4);
    try checkCount(fx, dbv, "[:find ?n :where [?e :person/name ?n] (not-join [?e] [?e :person/friend ?f] [?f :person/age 30])]", none, 4);
    try checkCount(fx, dbv, "[:find ?n :where [?e :person/name ?n] [?e :person/age ?a] (not [?e :person/boss ?b] [?b :person/age ?a])]", none, 6);
    try checkCount(fx, dbv, "[:find ?n :where [?e :person/name ?n] (not [(missing? $ ?e :person/bio)])]", none, 2);
    try checkCount(fx, dbv, "[:find ?n :where [?e :person/name ?n] (not (not [?e :person/tags _]))]", none, 4);
    try checkCount(fx, dbv, "[:find ?n :where [?e :person/name ?n] (or [?e :person/tags :green] [?e :person/age 30])]", none, 4);
    try checkCount(fx, dbv, "[:find ?n :where [?e :person/name ?n] (or-join [?e] [?e :person/tags :green] (and [?e :person/age ?a] [(< ?a 30)]))]", none, 3);
    try checkCount(fx, dbv, "[:find ?n :where (or [?e :person/tags :green] [?e :person/age 30]) [?e :person/name ?n]]", none, 4);
    try checkCount(fx, dbv, "[:find ?n :where [?e :person/name ?n] (or-join [?e] [?e :person/friend ?f] (and [?e :person/boss ?b] [?b :person/tags :red]))]", none, 4);
    try checkCount(fx, dbv, "[:find ?n ?w :where [?e :person/name ?n] (or-join [?e ?w] (and [?e :person/tags ?w]) (and [?e :person/role ?w]))]", none, 8);
    try checkCount(fx, dbv, "[:find ?n :where [?e :person/name ?n] (or (and [?e :person/age ?a] [(> ?a 40)]) (and [?e :person/age ?a] [(< ?a 27)]))]", none, 3);
    try checkCount(fx, dbv, "[:find ?n :where [?e :person/name ?n] (or [?e :person/tags :blue] (not [?e :person/friend _]))]", none, 3);
    try checkCount(fx, dbv, "[:find ?n :where [?e :person/name ?n] (not (or [?e :person/tags :blue] [?e :person/tags :green]))]", none, 2);
    try checkCount(fx, dbv, "[:find ?n :where (and [?e :person/name ?n] [?e :person/active true])]", none, 3);
    try checkCount(fx, dbv, "[:find ?o :where (or-join [?o] (and [?o :order/total ?t] [(> ?t 50.0)]) [?o :order/items \"pear\"])]", none, 2);
    // Errors: not with nothing bound outside, or branches with different vars, unbound pattern.
    // A scoping refusal names the variable and the clause it is in.
    const Case = struct { src: []const u8, message: []const u8, clause: ?usize };
    for ([_]Case{
        .{ .src = "[:find ?n :where [?e :person/name ?n] (not [?x :person/tags :blue])]", .message = "not shares no variable with the clauses around it: ?x is bound nowhere outside; not joins on a variable bound outside it", .clause = 1 },
        .{ .src = "[:find ?n :where [?e :person/name ?n] (or [?e :person/tags :blue] [?x :person/tags :green])]", .message = "or branch 2 does not mention ?e, which branch 1 does; every or branch uses the same variables (or-join names the join variables)", .clause = 1 },
        .{ .src = "[:find ?n :where [?e :person/name ?n] (or-join [?e ?w] [?e :person/tags ?w] [?e :person/age 30])]", .message = "or-join branch 2 leaves ?w unbound; every branch binds every join variable", .clause = 1 },
        .{ .src = "[:find ?e :where [?e :person/name ?n] [(< ?zz 3)]]", .message = "?zz is never bound; a predicate, function or rule argument needs a pattern, an input or an earlier clause to bind it", .clause = 1 },
        .{ .src = "[:find ?e :where [?e :person/name ?n] [(?f ?n)] [?e :person/age 30]]", .message = "?f in function position is never bound", .clause = 1 },
        .{ .src = "[:find ?e :where [?e :person/name ?n] (not-join [?e] (not [?q :person/tags :blue]))]", .message = "not shares no variable with the clauses around it: ?q is bound nowhere outside; not joins on a variable bound outside it", .clause = 1 },
        .{ .src = "[:find ?e :where [?e :person/name ?n] (not-join [?zz] [?zz :person/tags :blue])]", .message = "?zz is never bound; not-join joins on variables the clauses around it bind", .clause = 1 },
    }) |case| {
        var d: query.Diag = .{};
        try testing.expectError(error.QuerySyntax, runEngineDiag(fx, fx.arena(), dbv, case.src, none, &d));
        try testing.expectEqualStrings(case.message, d.message);
        try testing.expectEqual(case.clause, d.clause);
    }
    for ([_][]const u8{
        "[:find ?e :where [?e [:person/email \"ann@x\"] ?v]]",
        "[:find ?e :where [?e \"name\" ?v]]",
        "[:find ?e :where [?e :person/name ?v \"tx\"]]",
        "[:find ?e :where [?e :person/name ?v _ 1]]",
        "[:find ?e :where [\"ann\" :person/name ?v]]",
        "[:find ?e :where [[:person/name \"Ann\"] :person/age ?e]]",
    }) |src| {
        var d: query.Diag = .{};
        try testing.expectError(error.QuerySyntax, runEngineDiag(fx, fx.arena(), dbv, src, none, &d));
        try testing.expect(d.message.len > 0);
    }
    var d_attr: query.Diag = .{};
    try testing.expectError(error.UnknownAttribute, runEngineDiag(fx, fx.arena(), dbv, "[:find ?e :where [?e :nope/attr ?v]]", none, &d_attr));
    try testing.expectEqual(try fx.kwId("nope/attr"), d_attr.attr.?.asKeywordId());
    d_attr = .{};
    try testing.expectError(error.UnknownAttribute, runEngineDiag(fx, fx.arena(), dbv, "[:find ?e :where [?e 4000 ?v]]", none, &d_attr));
    try testing.expectEqual(@as(i64, 4000), d_attr.attr.?.asFixnum());
    try testing.expectError(error.UnboundPattern, runEngine(fx, fx.arena(), dbv, "[:find ?e :where [?e ?a ?v]]", none));
    try testing.expectError(error.QuerySyntax, runEngine(fx, fx.arena(), dbv, "[:find ?e :where [?e :person/name ?n] [(< ?zz 3)]]", none));
}

test "corpus: rules" {
    const fx = try Fx.init("q_rules");
    defer fx.deinit();
    try loadCorpus(fx);
    const dbv = try fx.db();
    const rules = try fx.read(rules_src);
    const args: []const Value = &.{ value.nilValue(), rules };

    // Non-recursive, both directions, constants and bound args.
    try checkCount(fx, dbv, "[:find ?a ?b :in $ % :where (friend ?a ?b)]", args, 8);
    try checkCount(fx, dbv, "[:find ?n :in $ % :where [?a :person/name \"Ann\"] (friend ?a ?b) [?b :person/name ?n]]", args, 2);
    try checkCount(fx, dbv, "[:find ?n :in $ % :where [?b :person/email \"bob@x\"] (friend ?a ?b) [?a :person/name ?n]]", args, 2);
    try checkCount(fx, dbv, "[:find ?n :in $ % :where (admin ?p) [?p :person/name ?n]]", args, 2);
    try checkCount(fx, dbv, "[:find ?n ?t :in $ % :where (has-tag ?p ?t) [?p :person/name ?n]]", args, 11);
    try checkCount(fx, dbv, "[:find ?n :in $ % :where [?f :person/email \"flo@x\"] (older ?p ?f) [?p :person/name ?n]]", args, 2);
    try checkCount(fx, dbv, "[:find ?n :in $ % :where [?p :person/name ?n] (not (admin ?p))]", args, 4);
    try checkCount(fx, dbv, "[:find ?n :in $ % :where [?p :person/name ?n] (or (admin ?p) (has-tag ?p :green))]", args, 4);
    // Recursive: pass-through push-down, no push-down, cycles, mutual recursion, required args.
    try checkCount(fx, dbv, "[:find ?a ?b :in $ % :where (reach ?a ?b)]", args, 16);
    try checkCount(fx, dbv, "[:find ?l :in $ % :where [?a :node/label \"n4\"] (reach ?a ?b) [?b :node/label ?l]]", args, 1);
    try checkCount(fx, dbv, "[:find ?l :in $ % :where [?a :node/label \"n1\"] (reach ?a ?b) [?b :node/label ?l]]", args, 5);
    try checkCount(fx, dbv, "[:find ?l :in $ % :where [?a :node/label \"n1\"] (reach-left ?a ?b) [?b :node/label ?l]]", args, 5);
    try checkCount(fx, dbv, "[:find ?l :in $ % :where [?b :node/label \"n5\"] (reach-left ?a ?b) [?a :node/label ?l]]", args, 4);
    try checkCount(fx, dbv, "[:find ?l :in $ % :where [?b :node/label \"n5\"] (reach ?a ?b) [?a :node/label ?l]]", args, 4);
    try checkCount(fx, dbv, "[:find ?a ?b :in $ % :where (even-hops ?a ?b)]", args, 15);
    try checkCount(fx, dbv, "[:find ?a ?b :in $ % :where (odd-hops ?a ?b)]", args, 16);
    try checkCount(fx, dbv, "[:find ?l :in $ % :where [?a :node/label \"n1\"] (even-hops ?a ?b) [?b :node/label ?l]]", args, 5);
    try checkCount(fx, dbv, "[:find ?l :in $ % :where [?a :node/label \"n2\"] (reach-label ?a ?l)]", args, 5);
    try checkCount(fx, dbv, "[:find ?l :in $ % :where [?a :node/label \"n4\"] (reach-label ?a ?l)]", args, 1);
    try checkCount(fx, dbv, "[:find ?l :in $ % :where [?n :node/label ?l] (not (reach ?n ?n))]", args, 3);
    try checkCount(fx, dbv, "[:find ?l :in $ % :where [?n :node/label ?l] (reach ?n ?n)]", args, 3);
    try checkCount(fx, dbv, "[:find (count ?b) :in $ % :where [?a :node/label \"n3\"] (reach ?a ?b)]", args, 1);
    // Errors: unknown rule, arity, required argument unbound.
    for ([_][]const u8{
        "[:find ?a :in $ % :where (nope ?a)]",
        "[:find ?a :in $ % :where (admin ?a ?b)]",
        "[:find ?a ?l :in $ % :where (reach-label ?a ?l)]",
        "[:find ?a :in $ % :where (admin $)]",
    }) |src| {
        var d: query.Diag = .{};
        try testing.expectError(error.QuerySyntax, runEngineDiag(fx, fx.arena(), dbv, src, args, &d));
        try testing.expect(d.message.len > 0);
    }
}

/// An `n`-clause chain `[?x0 attr ?x1] [?x1 attr ?x2] ...` with `find`
/// as its find elements; `%` among the inputs when `rules`.
fn chainQuery(arena: Allocator, n: usize, attr: []const u8, find: []const u8, rules: bool) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.print("[:find {s} {s}:where", .{ find, if (rules) ":in $ % " else "" });
    for (0..n) |i| try out.writer.print(" [?x{d} {s} ?x{d}]", .{ i, attr, i + 1 });
    try out.writer.writeByte(']');
    return out.written();
}

test "corpus: long chains, wide joins, and the variables a relation drops" {
    const fx = try Fx.init("q_chains");
    defer fx.deinit();
    try loadCorpus(fx);
    const dbv = try fx.db();
    const none: []const Value = &.{value.nilValue()};
    const arena = fx.arena();
    const rules = try fx.read(rules_src);
    const args: []const Value = &.{ value.nilValue(), rules };

    // A variable repeated in a pattern whose other variables are bound
    // must carry one value in both positions, on the hash join as on
    // the seek: nobody is their own boss, nor their own friend.
    try checkCount(fx, dbv, "[:find ?e ?b :where [?e :person/boss ?b] [?b :person/boss ?b]]", none, 0);
    try checkCount(fx, dbv, "[:find ?e ?f :where [?e :person/friend ?f] [?f :person/friend ?f]]", none, 0);
    try checkCount(fx, dbv, "[:find ?a :where [?a :edge/to ?b] [?b :edge/to ?c] [?c :edge/to ?a]]", none, 3);

    // Chains round the n1 → n2 → n3 → n1 cycle, narrow and wide: the
    // ends, every variable, the start alone, a count; then rule calls.
    for ([_]usize{ 2, 5, 12, 30 }) |n| {
        const last = try std.fmt.allocPrint(arena, "?x0 ?x{d}", .{n});
        _ = try check(fx, dbv, try chainQuery(arena, n, ":edge/to", last, false), none);
        var every: std.Io.Writer.Allocating = .init(arena);
        for (0..n + 1) |i| try every.writer.print("?x{d} ", .{i});
        _ = try check(fx, dbv, try chainQuery(arena, n, ":edge/to", every.written(), false), none);
        _ = try check(fx, dbv, try chainQuery(arena, n, ":edge/to", "?x0", false), none);
        const counted = try std.fmt.allocPrint(arena, "(count ?x{d}) ?x0", .{n});
        _ = try check(fx, dbv, try chainQuery(arena, n, ":edge/to", counted, false), none);
    }
    try checkCount(fx, dbv, "[:find ?a ?d :in $ % :where (reach-left ?a ?b) (reach-left ?b ?c) (reach-left ?c ?d) [?d :node/label \"n5\"]]", args, 3);

    // A wide join: every attribute of a person, one entity variable.
    _ = try check(fx, dbv, "[:find ?n ?em ?a ?h ?act ?t ?r :where [?e :person/name ?n] [?e :person/email ?em] [?e :person/age ?a] [?e :person/height ?h] [?e :person/active ?act] [?e :person/tags ?t] [?e :person/role ?r]]", none);
    _ = try check(fx, dbv, "[:find ?n ?fn ?bn :where [?e :person/name ?n] [?e :person/friend ?f] [?f :person/name ?fn] [?e :person/boss ?b] [?b :person/name ?bn] [?b :person/age ?ba] [?f :person/age ?fa] [(< ?fa ?ba)]]", none);

    // A variable read by no later clause and asked for by nobody is
    // dropped; the answer is the same wherever its last reader is: only
    // in :with, a rule head, a not, an or-join, a predicate, a function,
    // or nowhere.
    try checkCount(fx, dbv, "[:find (sum ?a) . :with ?e :where [?e :person/age ?a] [?e :person/name ?n]]", none, 1);
    try testing.expectEqual(@as(i64, 30 + 26 + 41 + 30 + 55 + 33), (try check(fx, dbv, "[:find (sum ?a) . :with ?e :where [?e :person/age ?a] [?e :person/name ?n]]", none)).cell(0, 0).int);
    try checkCount(fx, dbv, "[:find (count ?a) . :where [?e :person/age ?a] [?e :person/name ?n]]", none, 1);
    try checkCount(fx, dbv, "[:find ?n :in $ % :where (friend ?a ?b) [?a :person/name ?n]]", args, 5);
    try checkCount(fx, dbv, "[:find ?n :in $ % :where (has-tag ?p ?t) (older ?p ?q) [?p :person/name ?n]]", args, 5);
    try checkCount(fx, dbv, "[:find ?n :where [?e :person/name ?n] [?e :person/age ?a] (not [?e :person/boss ?b] [?b :person/age ?a])]", none, 6);
    try checkCount(fx, dbv, "[:find ?n :where [?e :person/name ?n] [?e :person/age ?a] (or-join [?e ?a] [?e :person/tags :green] (and [?e :person/boss ?b] [?b :person/age ?a]))]", none, 2);
    try checkCount(fx, dbv, "[:find ?n :where [?e :person/name ?n] [?e :person/age ?a] [(add ?a ?a) ?d] [(> ?d 60)]]", none, 3);
    try checkCount(fx, dbv, "[:find ?n :in $ ?f :where [?e :person/name ?n] [?e :person/age ?a] [(?f ?a) ?d] [(> ?d 40)]]", &.{ value.nilValue(), try fx.read("inc") }, 2);
    try checkCount(fx, dbv, "[:find ?n :where [?e :person/name ?n] [?e :person/age ?unused] [?e :person/tags ?t]]", none, 4);
    try checkCount(fx, dbv, "[:find ?t :where [?e :person/tags ?t] [?e :person/age ?a] [(> ?a 20)]]", none, 3);

    // explain names what each step drops.
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var diag: query.Diag = .{};
    try query.explain(testing.allocator, fx.interner(), try fx.read("[:find ?n :where [?e :person/age ?a] [(> ?a 40)] [?e :person/name ?n]]"), dbv, none, &diag, .{ .hook = fx.hook() }, &out.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "2. pred (> ?a 40)") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "drop ?a\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "drop ?e\n") != null);
}

test "corpus: as-of, since, history views" {
    const fx = try Fx.init("q_time");
    defer fx.deinit();
    try loadCorpus(fx);
    const now = try fx.db();
    const none: []const Value = &.{value.nilValue()};

    const before = now.asOf(5);
    try checkCount(fx, before, "[:find ?e ?n :where [?e :person/name ?n]]", none, 5);
    try checkCount(fx, before, "[:find ?e :where [?e :person/name \"Ed\"]]", none, 1);
    try checkCount(fx, before, "[:find ?e :where [?e :person/age 25]]", none, 1);
    try checkCount(fx, before, "[:find ?t :where [[:person/email \"ann@x\"] :person/tags ?t]]", none, 2);
    try checkCount(fx, before, "[:find ?n ?fn :where [?e :person/name ?n] [?e :person/friend ?f] [?f :person/name ?fn]]", none, 4);
    try checkCount(fx, before, "[:find ?n :where [?e :person/name ?n] (not [?e :person/friend _])]", none, 2);
    try checkCount(fx, now.asOf(3), "[:find ?o :where [?o :order/number _]]", none, 0);
    try checkCount(fx, now.asOf(2), "[:find ?e :where [?e :person/name _]]", none, 0);

    const since = now.sinceT(5);
    try checkCount(fx, since, "[:find ?e ?n :where [?e :person/name ?n]]", none, 2);
    try checkCount(fx, since, "[:find ?e ?a :where [?e :person/age ?a]]", none, 2);
    try checkCount(fx, since, "[:find ?e :where [?e :person/tags _]]", none, 0);
    try checkCount(fx, since, "[:find ?n ?fn :where [?e :person/name ?n] [?e :person/friend ?f] [?f :person/name ?fn]]", none, 0);
    try checkCount(fx, now.sinceT(0), "[:find ?e ?n :where [?e :person/name ?n]]", none, 6);

    const hist = now.withHistory();
    try checkCount(fx, hist, "[:find ?v ?added :where [[:person/email \"bob@x\"] :person/age ?v _ ?added]]", none, 3);
    try checkCount(fx, hist, "[:find ?v ?tx ?added :where [[:person/email \"ed@x\"] :person/name ?v ?tx ?added]]", none, 3);
    try checkCount(fx, hist, "[:find ?e :where [?e :person/tags :red _ false]]", none, 1);
    try checkCount(fx, hist, "[:find ?e ?f :where [?e :person/friend ?f _ false]]", none, 1);
    try checkCount(fx, hist, "[:find ?e :where [?e :person/name \"Ed\"]]", none, 1);
    try checkCount(fx, hist, "[:find (count ?tx) :where [_ :person/age _ ?tx]]", none, 1);
    try checkCount(fx, hist, "[:find ?n :where [?e :person/name ?n _ true] [?e :person/age 25 _ ?added]]", none, 1);
    try checkCount(fx, hist.asOf(5), "[:find ?v ?added :where [[:person/email \"bob@x\"] :person/age ?v _ ?added]]", none, 1);
    try checkCount(fx, hist, "[:find ?n :where [?e :person/name ?n] (not [?e :person/name _ _ false])]", none, 5);
}

test "corpus: multiple data sources" {
    const fx = try Fx.init("q_sources");
    defer fx.deinit();
    try loadCorpus(fx);
    const now = try fx.db();
    const before = try nextomic.natives.boxDb(&fx.heap, now.asOf(5));
    const hist = try nextomic.natives.boxDb(&fx.heap, now.withHistory());
    const nil = value.nilValue();
    const rules = try fx.read(rules_src);

    // A prefixed pattern reads its source; unprefixed and `$` read the db.
    try checkCount(fx, now, "[:find ?n ?a ?b :in $ $2 :where [?e :person/name ?n] [?e :person/age ?a] [$2 ?e :person/age ?b] [(not= ?a ?b)]]", &.{ nil, before }, 1);
    try checkCount(fx, now, "[:find ?n :in $ $2 :where [$ ?e :person/name ?n] (not [$2 ?e :person/name ?n])]", &.{ nil, before }, 2);
    try checkCount(fx, now, "[:find ?n :in $ $2 :where [?e :person/name ?n] [$2 ?e :person/tags :red _ false]]", &.{ nil, hist }, 1);
    try checkCount(fx, now, "[:find ?e :in $ $2 :where [$2 ?e :person/name ?n] (not [?e :person/name ?n])]", &.{ nil, before }, 1);
    try checkCount(fx, now, "[:find ?n :in $ $2 :where [?e :person/name ?n] (or [$2 ?e :person/age 25] [?e :person/age 55])]", &.{ nil, before }, 2);
    // missing? and get-else read the source they name.
    try checkCount(fx, now, "[:find ?n :in $ $2 :where [?e :person/name ?n] [(missing? $2 ?e :person/name)]]", &.{ nil, before }, 1);
    try checkCount(fx, now, "[:find ?n ?a :in $ $2 :where [?e :person/name ?n] [(get-else $2 ?e :person/age 0) ?a]]", &.{ nil, before }, 6);
    // A rule called under a source reads it, non-recursive and recursive.
    try checkCount(fx, now, "[:find ?p :in $ $2 % :where ($2 admin ?p)]", &.{ nil, before, rules }, 2);
    try checkCount(fx, now, "[:find ?n :in $ $2 % :where [?b :person/email \"bob@x\"] ($2 friend ?a ?b) [?a :person/name ?n]]", &.{ nil, before, rules }, 2);
    try checkCount(fx, now, "[:find ?n :in $ $2 % :where [?b :person/email \"bob@x\"] (friend ?a ?b) [?a :person/name ?n]]", &.{ nil, before, rules }, 2);
    try checkCount(fx, now, "[:find ?a ?b :in $ $2 % :where ($2 reach ?a ?b)]", &.{ nil, before, rules }, 16);
    try checkCount(fx, now, "[:find ?l :in $ $2 % :where [?a :node/label \"n1\"] ($2 reach ?a ?b) [?b :node/label ?l]]", &.{ nil, before, rules }, 5);
    // Aggregates and :with over a join across sources.
    try checkCount(fx, now, "[:find ?n (count ?o) :in $ $2 :where [$2 ?e :person/name ?n] [?o :order/customer ?e]]", &.{ nil, before }, 3);
    try checkCount(fx, now, "[:find (sum ?a) :with ?e :in $ $2 :where [?e :person/name _] [$2 ?e :person/age ?a]]", &.{ nil, before }, 1);
    // An input in an entity role resolves in the source of the pattern that gave it the role.
    const ann_ref = try fx.read("[:person/email \"ann@x\"]");
    try checkCount(fx, now, "[:find ?a :in $ $2 ?e :where [$2 ?e :person/age ?a]]", &.{ nil, before, ann_ref }, 1);
    try checkCount(fx, now, "[:find ?a :in $ $2 ?e :where [$2 ?e :person/age ?a]]", &.{ nil, before, try fx.read("[:person/email \"flo@x\"]") }, 0);
    // Three sources.
    try checkCount(fx, now, "[:find ?n :in $ $2 $3 :where [?e :person/name ?n] [$2 ?e :person/age 25] [$3 ?e :person/age 26 _ true]]", &.{ nil, before, hist }, 1);
    // Errors: an undeclared source, a missing input, an input that is not a db.
    var d: query.Diag = .{};
    try testing.expectError(error.QuerySyntax, runEngineDiag(fx, fx.arena(), now, "[:find ?n :in $ $2 :where [$3 ?e :person/name ?n]]", &.{ nil, before }, &d));
    try testing.expect(d.message.len > 0);
    try testing.expectError(error.QuerySyntax, runEngine(fx, fx.arena(), now, "[:find ?n :in $ $2 :where [$2 ?e :person/name ?n]]", &.{nil}));
    try testing.expectError(error.KindMismatch, runEngine(fx, fx.arena(), now, "[:find ?n :in $ $2 :where [$2 ?e :person/name ?n]]", &.{ nil, value.fromFixnum(1).? }));

    // explain names the source of a scan; q without a db_of refuses a second source.
    var diag: query.Diag = .{};
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try query.explain(testing.allocator, fx.interner(), try fx.read("[:find ?n :in $ $2 :where [?e :person/name ?n] [$2 ?e :person/age 25]]"), now, &.{ nil, before }, &diag, .{ .db_of = &nextomic.natives.dbOf }, &out.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "scan [$2 ?e") != null);
    try testing.expectError(error.QuerySyntax, query.q(testing.allocator, fx.interner(), &fx.heap, try fx.read("[:find ?n :in $ $2 :where [$2 ?e :person/name ?n]]"), now, &.{ nil, before }, &diag, .{}));
    const res = try query.q(testing.allocator, fx.interner(), &fx.heap, try fx.read("[:find ?n . :in $ $2 :where [?e :person/name ?n] [$2 ?e :person/age 25]]"), now, &.{ nil, before }, &diag, .{ .db_of = &nextomic.natives.dbOf });
    try testing.expectEqualStrings("Bob", string_mod.asBytes(res));
}

test "results materialise as set, scalar, collection, tuple; caches; explain" {
    const fx = try Fx.init("q_values");
    defer fx.deinit();
    try loadCorpus(fx);
    const dbv = try fx.db();
    const none: []const Value = &.{value.nilValue()};
    var diag: query.Diag = .{};
    var cache = query.Cache.init(testing.allocator);
    defer cache.deinit();
    var rules_cache = query.RulesCache.init(testing.allocator);
    defer rules_cache.deinit();
    const opts: query.Options = .{ .hook = fx.hook(), .ir_cache = &cache, .rules_cache = &rules_cache };

    const rel_q = try fx.read("[:find ?n ?a :where [?e :person/name ?n] [?e :person/age ?a] [(< ?a 31)]]");
    const set = try query.q(testing.allocator, fx.interner(), &fx.heap, rel_q, dbv, none, &diag, opts);
    try testing.expect(set.kind() == .persistent_set);
    try testing.expectEqual(@as(usize, 3), champ.setCount(set));
    const probe = try fx.read("[\"Bob\" 26]");
    try testing.expect(champ.setContains(set, probe, &dispatch.hashValue, &dispatch.equal));

    const scalar = try query.q(testing.allocator, fx.interner(), &fx.heap, try fx.read("[:find ?n . :where [?e :person/age 55] [?e :person/name ?n]]"), dbv, none, &diag, opts);
    try testing.expectEqualStrings("Edward", string_mod.asBytes(scalar));
    const nothing = try query.q(testing.allocator, fx.interner(), &fx.heap, try fx.read("[:find ?n . :where [?e :person/age 99] [?e :person/name ?n]]"), dbv, none, &diag, opts);
    try testing.expect(nothing.isNil());

    const coll = try query.q(testing.allocator, fx.interner(), &fx.heap, try fx.read("[:find [?t ...] :where [_ :person/tags ?t]]"), dbv, none, &diag, opts);
    try testing.expect(coll.kind() == .persistent_vector);
    try testing.expectEqual(@as(usize, 3), vector_mod.count(coll));

    const tuple = try query.q(testing.allocator, fx.interner(), &fx.heap, try fx.read("[:find [?n ?a] :where [?e :person/email \"cy@x\"] [?e :person/name ?n] [?e :person/age ?a]]"), dbv, none, &diag, opts);
    try testing.expect(tuple.kind() == .persistent_vector);
    try testing.expectEqualStrings("Cy", string_mod.asBytes(vector_mod.nth(tuple, 0)));
    try testing.expectEqual(@as(i64, 41), vector_mod.nth(tuple, 1).asFixnum());

    const agg = try query.q(testing.allocator, fx.interner(), &fx.heap, try fx.read("[:find [(sum ?a) (count ?e) (avg ?a) (distinct ?a)] :where [?e :person/age ?a]]"), dbv, none, &diag, opts);
    try testing.expectEqual(@as(i64, 30 + 26 + 41 + 30 + 55 + 33), vector_mod.nth(agg, 0).asFixnum());
    try testing.expectEqual(@as(i64, 6), vector_mod.nth(agg, 1).asFixnum());
    try testing.expectApproxEqAbs(@as(f64, 215.0 / 6.0), vector_mod.nth(agg, 2).asFloat(), 1e-9);
    try testing.expectEqual(@as(usize, 5), champ.setCount(vector_mod.nth(agg, 3)));

    // Statistics and random samples as values: an even median is the
    // mean of the two middle values, variance is over the count, sample
    // is distinct, rand repeats, both are cut at n and empty for no rows.
    const stats = try query.q(testing.allocator, fx.interner(), &fx.heap, try fx.read("[:find [(median ?a) (variance ?a) (stddev ?a) (max 2 ?a) (min 2 ?a) (total ?a)] :with ?e :where [?e :person/age ?a]]"), dbv, none, &diag, opts);
    // ages 26 30 30 33 41 55: median 31.5, mean 35.8333, variance 94.4722
    try testing.expectApproxEqAbs(@as(f64, 31.5), vector_mod.nth(stats, 0).asFloat(), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 94.47222222222223), vector_mod.nth(stats, 1).asFloat(), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, @sqrt(94.47222222222223)), vector_mod.nth(stats, 2).asFloat(), 1e-9);
    try testing.expectEqual(@as(i64, 55), vector_mod.nth(vector_mod.nth(stats, 3), 0).asFixnum());
    try testing.expectEqual(@as(i64, 41), vector_mod.nth(vector_mod.nth(stats, 3), 1).asFixnum());
    try testing.expectEqual(@as(i64, 26), vector_mod.nth(vector_mod.nth(stats, 4), 0).asFixnum());
    try testing.expectEqual(@as(i64, 30), vector_mod.nth(vector_mod.nth(stats, 4), 1).asFixnum());
    try testing.expectEqual(@as(i64, 215), vector_mod.nth(stats, 5).asFixnum());
    const odd_median = try query.q(testing.allocator, fx.interner(), &fx.heap, try fx.read("[:find (median ?a) . :where [?e :person/age ?a] [(< ?a 41)]]"), dbv, none, &diag, opts);
    try testing.expectEqual(@as(i64, 30), odd_median.asFixnum());
    const picks = try query.q(testing.allocator, fx.interner(), &fx.heap, try fx.read("[:find [(sample 3 ?a) (rand 8 ?a) (sample 100 ?a) (sample 0 ?a)] :where [?e :person/age ?a]]"), dbv, none, &diag, opts);
    try testing.expectEqual(@as(usize, 3), vector_mod.count(vector_mod.nth(picks, 0)));
    try testing.expectEqual(@as(usize, 8), vector_mod.count(vector_mod.nth(picks, 1)));
    try testing.expectEqual(@as(usize, 5), vector_mod.count(vector_mod.nth(picks, 2)));
    try testing.expectEqual(@as(usize, 0), vector_mod.count(vector_mod.nth(picks, 3)));
    const all_ages = try fx.read("#{26 30 33 41 55}");
    var sit = vector_mod.Cursor.init(vector_mod.nth(picks, 2));
    while (sit.next()) |x| try testing.expect(champ.setContains(all_ages, x, &dispatch.hashValue, &dispatch.equal));
    // No rows form no group: an aggregate-only result is empty, not zero.
    const no_rows = try query.q(testing.allocator, fx.interner(), &fx.heap, try fx.read("[:find [(sample 3 ?a) (rand 3 ?a) (median ?a) (max 2 ?a)] :where [?e :person/age ?a] [(> ?a 100)]]"), dbv, none, &diag, opts);
    try testing.expect(no_rows.isNil());

    // Pull expressions in :find yield the pattern's map per row, in
    // every find spec and beside an aggregate; a history db refuses them.
    const pulled = try query.q(testing.allocator, fx.interner(), &fx.heap, try fx.read("[:find (pull ?e [:person/name :person/age]) :where [?e :person/email \"cy@x\"]]"), dbv, none, &diag, opts);
    try testing.expectEqual(@as(usize, 1), champ.setCount(pulled));
    var pit = champ.setIter(pulled);
    const cy_row = pit.next().?;
    const cy_map = vector_mod.nth(cy_row, 0);
    try testing.expect(cy_map.kind() == .persistent_map);
    try testing.expectEqualStrings("Cy", string_mod.asBytes((try fx.getName(cy_map, "person/name")).?));
    try testing.expectEqual(@as(i64, 41), (try fx.getName(cy_map, "person/age")).?.asFixnum());
    const pulled_one = try query.q(testing.allocator, fx.interner(), &fx.heap, try fx.read("[:find (pull ?e [:person/name]) . :where [?e :person/email \"cy@x\"]]"), dbv, none, &diag, opts);
    try testing.expectEqualStrings("Cy", string_mod.asBytes((try fx.getName(pulled_one, "person/name")).?));
    const pulled_many = try query.q(testing.allocator, fx.interner(), &fx.heap, try fx.read("[:find [(pull ?e [:person/name]) ...] :where [?e :person/tags :green]]"), dbv, none, &diag, opts);
    try testing.expectEqual(@as(usize, 2), vector_mod.count(pulled_many));
    try testing.expect(vector_mod.nth(pulled_many, 0).kind() == .persistent_map);
    const pulled_agg = try query.q(testing.allocator, fx.interner(), &fx.heap, try fx.read("[:find [(pull ?c [:person/name]) (count ?o)] :where [?o :order/customer ?c] [?c :person/email \"ann@x\"]]"), dbv, none, &diag, opts);
    try testing.expectEqualStrings("Ann", string_mod.asBytes((try fx.getName(vector_mod.nth(pulled_agg, 0), "person/name")).?));
    try testing.expectEqual(@as(i64, 2), vector_mod.nth(pulled_agg, 1).asFixnum());
    try testing.expectError(error.HistoryView, query.q(testing.allocator, fx.interner(), &fx.heap, try fx.read("[:find (pull ?e [:person/name]) :where [?e :person/age 30]]"), dbv.withHistory(), none, &diag, opts));
    try testing.expectError(error.PullSyntax, query.q(testing.allocator, fx.interner(), &fx.heap, try fx.read("[:find (pull ?e [bogus]) :where [?e :person/age 30]]"), dbv, none, &diag, opts));
    try testing.expect(diag.message.len > 0);
    try testing.expectError(error.ValueType, query.q(testing.allocator, fx.interner(), &fx.heap, try fx.read("[:find (pull ?n [:person/name]) :where [?e :person/name ?n]]"), dbv, none, &diag, opts));

    // :keys, :strs and :syms return a vector of maps under those names.
    const keyed = try query.q(testing.allocator, fx.interner(), &fx.heap, try fx.read("[:find ?n ?a :keys name age :where [?e :person/name ?n] [?e :person/age ?a] [(< ?a 31)]]"), dbv, none, &diag, opts);
    try testing.expect(keyed.kind() == .persistent_vector);
    try testing.expectEqual(@as(usize, 3), vector_mod.count(keyed));
    const first = vector_mod.nth(keyed, 0);
    try testing.expect((try fx.getName(first, "name")).?.kind() == .string);
    try testing.expect((try fx.getName(first, "age")).?.kind() == .fixnum);
    const strs = try query.q(testing.allocator, fx.interner(), &fx.heap, try fx.read("[:find ?n :strs name :where [?e :person/email \"cy@x\"] [?e :person/name ?n]]"), dbv, none, &diag, opts);
    const strs_v = champ.mapGet(vector_mod.nth(strs, 0), try fx.str("name"), &dispatch.hashValue, &dispatch.equal);
    try testing.expectEqualStrings("Cy", string_mod.asBytes(strs_v.present));
    const syms = try query.q(testing.allocator, fx.interner(), &fx.heap, try fx.read("[:find ?n (count ?e) :syms name n :where [?e :person/name ?n]]"), dbv, none, &diag, opts);
    try testing.expectEqual(@as(usize, 6), vector_mod.count(syms));
    const syms_v = champ.mapGet(vector_mod.nth(syms, 0), try fx.read("n"), &dispatch.hashValue, &dispatch.equal);
    try testing.expectEqual(@as(i64, 1), syms_v.present.asFixnum());
    try testing.expectError(error.QuerySyntax, query.q(testing.allocator, fx.interner(), &fx.heap, try fx.read("[:find ?n ?a :keys name :where [?e :person/name ?n] [?e :person/age ?a]]"), dbv, none, &diag, opts));

    // Keyword and string values come back as VM values; the cache serves repeats.
    const kws = try query.q(testing.allocator, fx.interner(), &fx.heap, rel_q, dbv, none, &diag, opts);
    try testing.expectEqual(@as(usize, 3), champ.setCount(kws));
    try testing.expectEqual(@as(usize, 20), cache.count());
    const rules_q = try fx.read("[:find [?n ...] :in $ % :where (admin ?p) [?p :person/name ?n]]");
    const rules_v = try fx.read(rules_src);
    const admins = try query.q(testing.allocator, fx.interner(), &fx.heap, rules_q, dbv, &.{ value.nilValue(), rules_v }, &diag, opts);
    try testing.expectEqual(@as(usize, 2), vector_mod.count(admins));
    _ = try query.q(testing.allocator, fx.interner(), &fx.heap, rules_q, dbv, &.{ value.nilValue(), rules_v }, &diag, opts);
    try testing.expectEqual(@as(usize, 1), rules_cache.count());

    // A syntax error reports its clause.
    try testing.expectError(error.QuerySyntax, query.q(testing.allocator, fx.interner(), &fx.heap, try fx.read("[:find ?e :where [?e :person/name ?n] [?e bogus]]"), dbv, none, &diag, opts));
    try testing.expectEqual(@as(?usize, 1), diag.clause);

    // The hook's control transfer aborts the query and propagates.
    try testing.expectError(error.ControlTransferred, query.q(testing.allocator, fx.interner(), &fx.heap, try fx.read("[:find ?n :where [?e :person/name ?n] [(boom ?n)]]"), dbv, none, &diag, opts));
    // The read transaction was closed: a transaction still commits.
    _ = try fx.transact("[{:db/id [:person/email \"flo@x\"] :person/age 34}]");

    // Explain.
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try query.explain(testing.allocator, fx.interner(), try fx.read("[:find ?n :in $ % :where [?e :person/age 30] [?e :person/name ?n] (not [?e :person/tags :red]) (admin ?e) [(< 1 2)]]"), dbv, &.{ value.nilValue(), rules_v }, &diag, opts, &out.writer);
    const text = out.written();
    try testing.expect(std.mem.indexOf(u8, text, "1. pred (< 1 2)") != null);
    // The admin rule's body (3 entities) is cheaper than the age scan.
    try testing.expect(std.mem.indexOf(u8, text, "2. or-join [?e] branches=1") != null);
    try testing.expect(std.mem.indexOf(u8, text, "scan [?e :person/role :role/admin _ _] aevt est=3") != null);
    try testing.expect(std.mem.indexOf(u8, text, "not-join [?e]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "scan [?e! :person/age 30 _ _] eavt est=1") != null);
    try testing.expect(std.mem.indexOf(u8, text, "scan [?e! :person/name ?n _ _] eavt est=1") != null);
    out.clearRetainingCapacity();
    try query.explain(testing.allocator, fx.interner(), try fx.read("[:find ?a :where [?e :person/age ?a] [(identity ?e) ?e2] [?e2 :person/email \"ann@x\"]]"), dbv, none, &diag, opts, &out.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "3. bind (identity ?e) -> ?e2!") != null);
    // Every step ends with its join kind (scans) and estimated rows; a
    // seek per row is `nested`, a constant-prefix scan joined on the
    // shared variables is `hash`.
    out.clearRetainingCapacity();
    try query.explain(testing.allocator, fx.interner(), try fx.read("[:find ?n :where [?e :person/age 30] [?e :person/name ?n]]"), dbv, none, &diag, opts, &out.writer);
    const table = out.written();
    try testing.expect(std.mem.indexOf(u8, table, "1. scan [?e :person/age 30 _ _] aevt") != null);
    try testing.expect(std.mem.indexOf(u8, table, "hash    rows~6") != null);
    var lines = std.mem.splitScalar(u8, table, '\n');
    var steps: usize = 0;
    while (lines.next()) |l| {
        if (l.len == 0 or std.mem.startsWith(u8, l, "rows~")) continue;
        steps += 1;
        try testing.expect(std.mem.indexOf(u8, l, " rows~") != null);
    }
    try testing.expectEqual(@as(usize, 2), steps);
    // A bound attribute variable seeks per row.
    out.clearRetainingCapacity();
    try query.explain(testing.allocator, fx.interner(), try fx.read("[:find ?v :in $ ?a ?e :where [?e ?a ?v]]"), dbv, &.{ value.nilValue(), try fx.kw("person/name"), value.fromFixnum(1).? }, &diag, opts, &out.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "nested  rows~") != null);
}

test "transitive closure over a 5k-edge chain" {
    const fx = try Fx.init("q_chain");
    defer fx.deinit();
    _ = try fx.transact(
        \\[{:db/ident :node/id :db/valueType :db.type/long :db/cardinality :db.cardinality/one :db/index true}
        \\ {:db/ident :node/next :db/valueType :db.type/ref :db/cardinality :db.cardinality/one}]
    );
    const n: usize = 5001;
    var ops: std.ArrayList(nextomic.Op) = .empty;
    const id_attr = (try fx.conn().idents.idOfName(blk: {
        const t = try fx.conn().store.beginRead();
        defer t.abort();
        break :blk t;
    }, "node/id")).?;
    const next_attr = (try fx.conn().idents.idOfName(blk: {
        const t = try fx.conn().store.beginRead();
        defer t.abort();
        break :blk t;
    }, "node/next")).?;
    for (0..n) |i| {
        const me: nextomic.transact.Entity = .{ .tempid = .{ .fixnum = -@as(i64, @intCast(i + 1)) } };
        try ops.append(fx.arena(), .{ .add = .{ .e = me, .a = .{ .id = id_attr }, .v = .{ .val = .{ .long = @intCast(i) } } } });
        if (i + 1 < n) try ops.append(fx.arena(), .{ .add = .{ .e = me, .a = .{ .id = next_attr }, .v = .{ .entity = .{ .tempid = .{ .fixnum = -@as(i64, @intCast(i + 2)) } } } } });
    }
    _ = try nextomic.transact.transactOps(fx.conn(), fx.arena(), ops.items, .{});
    const dbv = try fx.db();
    const rules = try fx.read(
        \\[[(reach ?a ?b) [?a :node/next ?b]]
        \\ [(reach ?a ?b) (reach ?a ?m) [?m :node/next ?b]]
        \\ [(back ?a ?b) [?a :node/next ?b]]
        \\ [(back ?a ?b) [?a :node/next ?m] (back ?m ?b)]]
    );
    const args: []const Value = &.{ value.nilValue(), rules };
    const arena = fx.arena();

    // Forward closure from the head, pushed down on the pass-through position.
    const all = try runEngine(fx, arena, dbv, "[:find ?id :in $ % :where [?s :node/id 0] (reach ?s ?b) [?b :node/id ?id]]", args);
    try testing.expectEqual(n - 1, all.len);
    var sum: i64 = 0;
    for (all) |row| sum += row[0].int;
    try testing.expectEqual(@as(i64, @intCast((n - 1) * n / 2)), sum);
    const tail = try runEngine(fx, arena, dbv, "[:find ?id :in $ % :where [?s :node/id 4990] (reach ?s ?b) [?b :node/id ?id]]", args);
    try testing.expectEqual(@as(usize, 10), tail.len);
    // Backward closure to a bound end through the right-recursive rule (position 1 passes through).
    const head = try runEngine(fx, arena, dbv, "[:find ?id :in $ % :where [?e :node/id 10] (back ?a ?e) [?a :node/id ?id]]", args);
    try testing.expectEqual(@as(usize, 10), head.len);
    // Both ends bound.
    const both = try runEngine(fx, arena, dbv, "[:find ?s ?e :in $ % :where [?s :node/id 100] [?e :node/id 4000] (reach ?s ?e)]", args);
    try testing.expectEqual(@as(usize, 1), both.len);
    const none_ = try runEngine(fx, arena, dbv, "[:find ?s ?e :in $ % :where [?s :node/id 4000] [?e :node/id 100] (reach ?s ?e)]", args);
    try testing.expectEqual(@as(usize, 0), none_.len);
}

test "three-way joins over 10k datoms: every access path returns the rows it should" {
    // The same data shape as `zig build bench`'s 200k-datom q corpus
    // (bench/nextomic.zig), at a size a test can afford.
    const fx = try Fx.init("q_joins");
    defer fx.deinit();
    _ = try fx.transact(
        \\[{:db/ident :emp/name :db/valueType :db.type/string :db/cardinality :db.cardinality/one}
        \\ {:db/ident :emp/age :db/valueType :db.type/long :db/cardinality :db.cardinality/one :db/index true}
        \\ {:db/ident :emp/dept :db/valueType :db.type/ref :db/cardinality :db.cardinality/one}
        \\ {:db/ident :emp/salary :db/valueType :db.type/long :db/cardinality :db.cardinality/one}
        \\ {:db/ident :emp/active :db/valueType :db.type/boolean :db/cardinality :db.cardinality/one}
        \\ {:db/ident :dept/name :db/valueType :db.type/string :db/cardinality :db.cardinality/one :db/unique :db.unique/identity}]
    );
    const txn0 = try fx.conn().store.beginRead();
    const a_name = (try fx.conn().idents.idOfName(txn0, "emp/name")).?;
    const a_age = (try fx.conn().idents.idOfName(txn0, "emp/age")).?;
    const a_dept = (try fx.conn().idents.idOfName(txn0, "emp/dept")).?;
    const a_salary = (try fx.conn().idents.idOfName(txn0, "emp/salary")).?;
    const a_active = (try fx.conn().idents.idOfName(txn0, "emp/active")).?;
    const a_dname = (try fx.conn().idents.idOfName(txn0, "dept/name")).?;
    txn0.abort();

    const depts: usize = 20;
    var dept_ops: std.ArrayList(nextomic.Op) = .empty;
    for (0..depts) |i| {
        const name = try std.fmt.allocPrint(fx.arena(), "d{d}", .{i});
        try dept_ops.append(fx.arena(), .{ .add = .{ .e = .{ .tempid = .{ .fixnum = -@as(i64, @intCast(i + 1)) } }, .a = .{ .id = a_dname }, .v = .{ .val = .{ .string = name } } } });
    }
    const dept_report = try nextomic.transact.transactOps(fx.conn(), fx.arena(), dept_ops.items, .{});
    const dept_eids = try fx.arena().alloc(u64, depts);
    for (dept_report.tempids) |b| dept_eids[@intCast(-b.key.fixnum - 1)] = b.eid;

    const emps: usize = 2_000;
    var ops: std.ArrayList(nextomic.Op) = .empty;
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    for (0..emps) |i| {
        const me: nextomic.transact.Entity = .{ .tempid = .{ .fixnum = -@as(i64, @intCast(i + 1)) } };
        const name = try std.fmt.allocPrint(fx.arena(), "emp-{d}", .{i});
        try ops.append(fx.arena(), .{ .add = .{ .e = me, .a = .{ .id = a_name }, .v = .{ .val = .{ .string = name } } } });
        try ops.append(fx.arena(), .{ .add = .{ .e = me, .a = .{ .id = a_age }, .v = .{ .val = .{ .long = 20 + @as(i64, @intCast(rnd.uintLessThan(u32, 45))) } } } });
        try ops.append(fx.arena(), .{ .add = .{ .e = me, .a = .{ .id = a_dept }, .v = .{ .val = .{ .ref = dept_eids[i % depts] } } } });
        try ops.append(fx.arena(), .{ .add = .{ .e = me, .a = .{ .id = a_salary }, .v = .{ .val = .{ .long = 1000 + @as(i64, @intCast(rnd.uintLessThan(u32, 9000))) } } } });
        try ops.append(fx.arena(), .{ .add = .{ .e = me, .a = .{ .id = a_active }, .v = .{ .val = .{ .boolean = i % 3 == 0 } } } });
    }
    _ = try nextomic.transact.transactOps(fx.conn(), fx.arena(), ops.items, .{});
    const dbv = try fx.db();
    const none: []const Value = &.{value.nilValue()};
    var diag: query.Diag = .{};

    const rows3 = try runEngine(fx, fx.arena(), dbv, "[:find ?n ?dn :where [?d :dept/name \"d7\"] [?e :emp/dept ?d] [?e :emp/name ?n] [?d :dept/name ?dn]]", none);
    try testing.expectEqual(emps / depts, rows3.len);
    const q3 = try fx.read("[:find ?n ?dn :where [?d :dept/name \"d7\"] [?e :emp/dept ?d] [?e :emp/name ?n] [?d :dept/name ?dn]]");
    const q_age = try fx.read("[:find ?n ?dn :where [?e :emp/age 33] [?e :emp/dept ?d] [?d :dept/name ?dn] [?e :emp/name ?n]]");
    const q_hash = try fx.read("[:find (count ?e) . :where [?e :emp/active true] [?e :emp/dept ?d] [?d :dept/name \"d3\"]]");
    // Joins either side of the nested-loop/hash-join crossover: the
    // rows out of the age seeks decide how :emp/name and :emp/salary run.
    const q_join = try fx.read("[:find (count ?n) . :in $ [?a ...] :where [?e :emp/age ?a] [?e :emp/name ?n] [?e :emp/salary ?s]]");
    const r3 = try query.q(fx.gpa, fx.interner(), &fx.heap, q3, dbv, none, &diag, .{});
    const r_age = try query.q(fx.gpa, fx.interner(), &fx.heap, q_age, dbv, none, &diag, .{});
    const r_hash = try query.q(fx.gpa, fx.interner(), &fx.heap, q_hash, dbv, none, &diag, .{});
    const r_one = try query.q(fx.gpa, fx.interner(), &fx.heap, q_join, dbv, &.{ value.nilValue(), try fx.read("[33]") }, &diag, .{});
    const r_mid = try query.q(fx.gpa, fx.interner(), &fx.heap, q_join, dbv, &.{ value.nilValue(), try fx.read("[33 34 35]") }, &diag, .{});
    const r_big = try query.q(fx.gpa, fx.interner(), &fx.heap, q_join, dbv, &.{ value.nilValue(), try fx.read("[20 21 22 23 24 25 26]") }, &diag, .{});
    try testing.expect(r_one.asFixnum() > 0 and r_mid.asFixnum() > r_one.asFixnum() and r_big.asFixnum() > r_mid.asFixnum());
    try testing.expectEqual(emps / depts, champ.setCount(r3));
    try testing.expect(champ.setCount(r_age) > 0);
    // d3 holds employees 3, 23, 43, ...; those divisible by three are
    // active: 3, 63, 123, ..., 1983.
    try testing.expectEqual(@as(i64, 34), r_hash.asFixnum());
    var out: std.Io.Writer.Allocating = .init(fx.gpa);
    defer out.deinit();
    try query.explain(fx.gpa, fx.interner(), q3, dbv, none, &diag, .{}, &out.writer);
    try testing.expect(out.written().len > 0);
}
