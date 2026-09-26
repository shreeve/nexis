//! test/integration/nextomic_pull.zig — the pull corpus and the
//! speculative `with` tests (NEXTOMIC.md §6, §8).
//!
//! Every pattern here runs twice: through `pull` and through `Naive`,
//! a reference evaluator that interprets the same pattern value over
//! `DbValue.entity` and `DbValue.datoms` and knows nothing of the
//! puller's scans, budgets or covered sets. The two results must be
//! `=`. Patterns and entity arguments are read from source text with
//! the language reader. The corpus runs on the current view and on an
//! as-of view taken before an update transaction, and once more on a
//! `with` view. The `with` tests then check that `q`, `entity` and
//! `pull` see the speculative datoms, that errors surface without a
//! write, and that the committed basis is unchanged afterwards.

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
const emdb = nx.emdb;

const testing = std.testing;
const Allocator = std.mem.Allocator;
const Value = value.Value;
const Heap = heap_mod.Heap;
const Interner = intern_mod.Interner;
const query = nextomic.query;
const pull = nextomic.pull;
const default_limit = pull.default_limit;
const DbValue = nextomic.DbValue;
const TestConn = nextomic.db.TestConn;
const key = nextomic.key;
const Val = key.Val;
const Attr = nextomic.Attr;

// =============================================================================
// Fixture
// =============================================================================

const Fx = @import("nextomic_fx.zig").Fx;

const long_bio = "Ann has a biography that runs well past the ninety-six byte inline limit of the sortable string encoding, so it lives out of line with a prefix and a hash.";

/// People with friends, bosses, a level ident and a component house of
/// component rooms; orders; a graph with a cycle; a self-loop.
fn loadCorpus(fx: *Fx) !void {
    _ = try fx.transact(
        \\[{:db/ident :person/name :db/valueType :db.type/string :db/cardinality :db.cardinality/one}
        \\ {:db/ident :person/email :db/valueType :db.type/string :db/cardinality :db.cardinality/one :db/unique :db.unique/identity}
        \\ {:db/ident :person/age :db/valueType :db.type/long :db/cardinality :db.cardinality/one}
        \\ {:db/ident :person/height :db/valueType :db.type/double :db/cardinality :db.cardinality/one}
        \\ {:db/ident :person/active :db/valueType :db.type/boolean :db/cardinality :db.cardinality/one}
        \\ {:db/ident :person/tags :db/valueType :db.type/keyword :db/cardinality :db.cardinality/many}
        \\ {:db/ident :person/friend :db/valueType :db.type/ref :db/cardinality :db.cardinality/many}
        \\ {:db/ident :person/boss :db/valueType :db.type/ref :db/cardinality :db.cardinality/one}
        \\ {:db/ident :person/level :db/valueType :db.type/ref :db/cardinality :db.cardinality/one}
        \\ {:db/ident :person/bio :db/valueType :db.type/string :db/cardinality :db.cardinality/one}
        \\ {:db/ident :person/house :db/valueType :db.type/ref :db/cardinality :db.cardinality/one :db/isComponent true}
        \\ {:db/ident :house/name :db/valueType :db.type/string :db/cardinality :db.cardinality/one}
        \\ {:db/ident :house/rooms :db/valueType :db.type/ref :db/cardinality :db.cardinality/many :db/isComponent true}
        \\ {:db/ident :room/name :db/valueType :db.type/string :db/cardinality :db.cardinality/one}
        \\ {:db/ident :room/area :db/valueType :db.type/double :db/cardinality :db.cardinality/one}
        \\ {:db/ident :order/number :db/valueType :db.type/long :db/cardinality :db.cardinality/one :db/unique :db.unique/value}
        \\ {:db/ident :order/customer :db/valueType :db.type/ref :db/cardinality :db.cardinality/one}
        \\ {:db/ident :order/items :db/valueType :db.type/string :db/cardinality :db.cardinality/many}
        \\ {:db/ident :edge/to :db/valueType :db.type/ref :db/cardinality :db.cardinality/many}
        \\ {:db/ident :node/label :db/valueType :db.type/string :db/cardinality :db.cardinality/one :db/unique :db.unique/identity}
        \\ {:db/ident :level/junior} {:db/ident :level/senior}]
    );
    const people = try std.fmt.allocPrint(fx.arena(),
        \\[{{:db/id "ann" :person/name "Ann" :person/email "ann@x" :person/age 30 :person/height 1.7 :person/active true :person/tags [:red :blue] :person/level :level/senior :person/bio "{s}"
        \\  :person/house {{:house/name "Villa" :house/rooms [{{:room/name "kitchen" :room/area 12.5}} {{:room/name "hall" :room/area 8.0}}]}}}}
        \\ {{:db/id "bob" :person/name "Bob" :person/email "bob@x" :person/age 25 :person/tags [:blue] :person/friend ["ann"] :person/boss "ann" :person/level :level/junior}}
        \\ {{:db/id "cy" :person/name "Cy" :person/email "cy@x" :person/age 41 :person/friend ["ann" "bob"] :person/boss "ann"}}
        \\ {{:db/id "di" :person/name "Di" :person/email "di@x" :person/friend ["cy"] :person/boss "cy"}}
        \\ {{:db/id "ed" :person/name "Ed" :person/email "ed@x" :person/age 55 :person/friend ["ed"]}}]
    , .{long_bio});
    _ = try fx.transact(people);
    _ = try fx.transact(
        \\[{:order/number 1 :order/customer [:person/email "ann@x"] :order/items ["apple" "pear"]}
        \\ {:order/number 2 :order/customer [:person/email "bob@x"] :order/items ["fig"]}
        \\ {:order/number 3 :order/customer [:person/email "ann@x"]}]
    );
    _ = try fx.transact(
        \\[{:db/id "n1" :node/label "n1" :edge/to ["n2"]} {:db/id "n2" :node/label "n2" :edge/to ["n3"]}
        \\ {:db/id "n3" :node/label "n3" :edge/to ["n1" "n4"]} {:db/id "n4" :node/label "n4" :edge/to ["n5"]}
        \\ {:db/id "n5" :node/label "n5"} {:db/id "n6" :node/label "n6"}]
    );
    // Order 9 has one more item than the default card-many cut.
    var big: std.ArrayList(u8) = .empty;
    try big.appendSlice(fx.arena(), "[{:order/number 9 :order/items [");
    for (0..default_limit + 1) |i| try big.print(fx.arena(), "\"item{d:0>4}\" ", .{i});
    try big.appendSlice(fx.arena(), "]}]");
    _ = try fx.transact(big.items);
}

/// The update after which the as-of corpus runs: a retraction, a
/// rename, a new friend edge and a new person.
fn updateCorpus(fx: *Fx) !nextomic.Report {
    return fx.transact(
        \\[[:db/retract [:person/email "ann@x"] :person/tags :red]
        \\ {:db/id [:person/email "ed@x"] :person/name "Edward"}
        \\ [:db/add [:person/email "ann@x"] :person/friend [:person/email "di@x"]]
        \\ {:db/id "flo" :person/name "Flo" :person/email "flo@x" :person/boss [:person/email "ann@x"]}
        \\ [:db/retractEntity [:order/number 3]]]
    );
}

// =============================================================================
// Naive — a reference pull over entity() and datoms()
// =============================================================================

const Naive = struct {
    fx: *Fx,
    dbv: DbValue,
    txn: *emdb.Txn,
    arena: Allocator,
    path: std.ArrayList(u64) = .empty,
    k_db_id: Value,
    k_db_ident: Value,

    const Spec = struct {
        attr: Attr,
        reverse: bool,
        k: Value,
        limit: ?u32,
        default: ?Value,
    };

    /// Remaining recursion depth per (attribute, direction).
    const Budget = std.AutoHashMapUnmanaged(u64, u32);

    fn init(fx: *Fx, dbv: DbValue) !Naive {
        return .{
            .fx = fx,
            .dbv = dbv,
            .txn = try dbv.conn.beginReadTxn(),
            .arena = fx.arena(),
            .k_db_id = try fx.kw("db/id"),
            .k_db_ident = try fx.kw("db/ident"),
        };
    }

    fn deinit(self: *Naive) void {
        self.txn.abort();
    }

    fn assoc(self: *Naive, m: Value, k: Value, v: Value) !Value {
        return champ.mapAssoc(&self.fx.heap, m, k, v, &dispatch.hashValue, &dispatch.equal);
    }

    fn elems(self: *Naive, v: Value) ![]Value {
        var out: std.ArrayList(Value) = .empty;
        switch (v.kind()) {
            .persistent_vector => {
                var it = vector_mod.Cursor.init(v);
                while (it.next()) |x| try out.append(self.arena, x);
            },
            .list => {
                var it = list_mod.Cursor.init(v);
                while (it.next()) |x| try out.append(self.arena, x);
            },
            else => return error.BadPattern,
        }
        return out.toOwnedSlice(self.arena);
    }

    fn symIs(self: *Naive, v: Value, name: []const u8) bool {
        return v.isSymbol() and std.mem.eql(u8, self.fx.interner().symbolName(v.asSymbolId()), name);
    }

    fn kwIs(self: *Naive, v: Value, name: []const u8) bool {
        return v.kind() == .keyword and std.mem.eql(u8, self.fx.interner().keywordName(v.asKeywordId()), name);
    }

    /// Attributes resolve through the ident cache and the schema of
    /// the view, not through `entid`: a `since` view hides the
    /// attribute's own `:db/ident` datom but still has the schema.
    fn attrByName(self: *Naive, name: []const u8) !Attr {
        const k = try self.fx.interner().internKeyword(name);
        const id = (try self.dbv.conn.idents.idOf(self.txn, k)) orelse return error.UnknownAttribute;
        return (try self.dbv.attr(id)) orelse error.UnknownAttribute;
    }

    fn specOf(self: *Naive, k: Value) !Spec {
        const name = self.fx.interner().keywordName(k.asKeywordId());
        const slash = std.mem.indexOfScalar(u8, name, '/').?;
        const reverse = name[slash + 1] == '_';
        const forward = if (reverse) try std.mem.concat(self.arena, u8, &.{ name[0 .. slash + 1], name[slash + 2 ..] }) else name;
        const attr = try self.attrByName(forward);
        return .{ .attr = attr, .reverse = reverse, .k = k, .limit = default_limit, .default = null };
    }

    /// `(attr opts)`, `[attr opts]`, `(limit attr n)`, `(default attr v)`.
    fn exprOf(self: *Naive, v: Value) !Spec {
        const items = try self.elems(v);
        if (items[0].isSymbol()) {
            var spec = try self.specOf(items[1]);
            if (self.symIs(items[0], "limit")) {
                spec.limit = if (items[2].isNil()) null else @intCast(items[2].asFixnum());
            } else spec.default = items[2];
            return spec;
        }
        var spec = try self.specOf(items[0]);
        var i: usize = 1;
        while (i < items.len) : (i += 2) {
            if (self.kwIs(items[i], "limit")) {
                spec.limit = if (items[i + 1].isNil()) null else @intCast(items[i + 1].asFixnum());
            } else if (self.kwIs(items[i], "default")) {
                spec.default = items[i + 1];
            } else if (self.kwIs(items[i], "as")) {
                spec.k = items[i + 1];
            } else return error.BadPattern;
        }
        return spec;
    }

    fn keyOf(self: *Naive, v: Value) !Spec {
        return if (v.kind() == .keyword) self.specOf(v) else self.exprOf(v);
    }

    fn resolve(self: *Naive, e: Value) !u64 {
        switch (e.kind()) {
            .fixnum => return @intCast(e.asFixnum()),
            .keyword => return (try self.dbv.entid(self.arena, .{ .ident = e.asKeywordId() })) orelse error.NoEntity,
            .persistent_vector => {
                const spec = try self.specOf(vector_mod.nth(e, 0));
                const raw = vector_mod.nth(e, 1);
                const v: Val = switch (raw.kind()) {
                    .string => .{ .string = string_mod.asBytes(raw) },
                    .fixnum => .{ .long = raw.asFixnum() },
                    else => return error.BadPattern,
                };
                return (try self.dbv.entid(self.arena, .{ .lookup = .{ .a = spec.attr.id, .v = v } })) orelse error.NoEntity;
            },
            else => return error.BadPattern,
        }
    }

    fn budgetKey(spec: Spec) u64 {
        return @as(u64, spec.attr.id) * 2 + @intFromBool(spec.reverse);
    }

    fn refMap(self: *Naive, e: u64) !Value {
        var m = try champ.mapEmpty(&self.fx.heap);
        m = try self.assoc(m, self.k_db_id, value.fromFixnum(@intCast(e)).?);
        if (key.isAttrPartition(e)) {
            if (try self.dbv.ident(self.arena, e)) |k| m = try self.assoc(m, self.k_db_ident, value.fromKeywordId(k));
        }
        return m;
    }

    const Sub = union(enum) { none, pattern: Value, recurse: ?u32 };

    fn onPath(self: *Naive, e: u64) bool {
        return std.mem.indexOfScalar(u64, self.path.items, e) != null;
    }

    fn renderRef(self: *Naive, pattern: Value, spec: Spec, sub: Sub, budget: *Budget, target: u64) anyerror!Value {
        switch (sub) {
            .pattern => |p| {
                var fresh: Budget = .empty;
                return self.nested(p, target, &fresh);
            },
            .recurse => |depth| {
                const bk = budgetKey(spec);
                if (depth) |d| {
                    const remaining = budget.get(bk) orelse d;
                    if (remaining == 0) return self.refMap(target);
                    var next = try budget.clone(self.arena);
                    try next.put(self.arena, bk, remaining - 1);
                    return self.nested(pattern, target, &next);
                }
                return self.nested(pattern, target, budget);
            },
            .none => {
                if (spec.attr.component) {
                    var fresh: Budget = .empty;
                    return self.nested(try self.fx.read("[*]"), target, &fresh);
                }
                return self.refMap(target);
            },
        }
    }

    fn nested(self: *Naive, pattern: Value, target: u64, budget: *Budget) anyerror!Value {
        if (self.onPath(target)) return self.refMap(target);
        try self.path.append(self.arena, target);
        defer _ = self.path.pop();
        return (try self.pull(pattern, target, budget)) orelse self.refMap(target);
    }

    fn renderVal(self: *Naive, pattern: Value, spec: Spec, sub: Sub, budget: *Budget, v: Val) anyerror!Value {
        if (v == .ref) return self.renderRef(pattern, spec, sub, budget, v.ref);
        return self.dbv.conn.valToValue(self.txn, &self.fx.heap, v);
    }

    /// The values of a spec on `e`: forward from the entity map,
    /// reverse from VAET.
    fn valuesOf(self: *Naive, ent: []const DbValue.EntityAttr, spec: Spec, e: u64) ![]Val {
        var out: std.ArrayList(Val) = .empty;
        if (spec.reverse) {
            const vb = try key.valBytes(self.arena, .{ .ref = e });
            for (try self.dbv.datoms(self.arena, .vaet, .{ .v = vb, .a = spec.attr.id })) |d| try out.append(self.arena, .{ .ref = d.e });
        } else {
            for (ent) |ea| if (ea.a == spec.attr.id) try out.appendSlice(self.arena, ea.vals);
        }
        return out.toOwnedSlice(self.arena);
    }

    /// Emit one spec into `m`; returns whether a value was present.
    fn emit(self: *Naive, m: *Value, pattern: Value, ent: []const DbValue.EntityAttr, e: u64, spec: Spec, sub: Sub, budget: *Budget) anyerror!bool {
        var vals = try self.valuesOf(ent, spec, e);
        const many = if (spec.reverse) !spec.attr.component else spec.attr.many();
        if (many) {
            if (spec.limit) |l| if (vals.len > l) {
                vals = vals[0..l];
            };
        } else if (vals.len > 1) vals = vals[0..1];
        if (vals.len == 0) {
            if (spec.default) |d| m.* = try self.assoc(m.*, spec.k, d);
            return false;
        }
        if (!many) {
            m.* = try self.assoc(m.*, spec.k, try self.renderVal(pattern, spec, sub, budget, vals[0]));
            return true;
        }
        const out = try self.arena.alloc(Value, vals.len);
        for (vals, out) |v, *o| o.* = try self.renderVal(pattern, spec, sub, budget, v);
        m.* = try self.assoc(m.*, spec.k, try vector_mod.fromSlice(&self.fx.heap, out));
        return true;
    }

    fn pull(self: *Naive, pattern: Value, e: u64, budget: *Budget) anyerror!?Value {
        const ent = try self.dbv.entity(self.arena, e);
        var m = try champ.mapEmpty(&self.fx.heap);
        m = try self.assoc(m, self.k_db_id, value.fromFixnum(@intCast(e)).?);
        var any = false;
        var wildcard = false;
        var covered: std.AutoHashMapUnmanaged(u32, void) = .empty;
        for (try self.elems(pattern)) |item| {
            switch (item.kind()) {
                .keyword => {
                    if (self.kwIs(item, "db/id")) continue;
                    const spec = try self.specOf(item);
                    if (try self.emit(&m, pattern, ent, e, spec, .none, budget)) any = true;
                    if (!spec.reverse) try covered.put(self.arena, spec.attr.id, {});
                },
                .symbol => wildcard = true,
                .persistent_map => {
                    var it = champ.mapIter(item);
                    while (it.next()) |entry| {
                        const spec = try self.keyOf(entry.key);
                        const sub: Sub = if (entry.value.isSymbol()) .{ .recurse = null } else if (entry.value.kind() == .fixnum) .{ .recurse = @intCast(entry.value.asFixnum()) } else .{ .pattern = entry.value };
                        if (try self.emit(&m, pattern, ent, e, spec, sub, budget)) any = true;
                        if (!spec.reverse) try covered.put(self.arena, spec.attr.id, {});
                    }
                },
                .list, .persistent_vector => {
                    const spec = try self.exprOf(item);
                    if (try self.emit(&m, pattern, ent, e, spec, .none, budget)) any = true;
                    if (!spec.reverse) try covered.put(self.arena, spec.attr.id, {});
                },
                else => return error.BadPattern,
            }
        }
        if (wildcard) {
            for (ent) |ea| {
                any = true;
                if (covered.contains(ea.a)) continue;
                const attr = (try self.dbv.attr(ea.a)).?;
                const k = (try self.dbv.conn.idents.internOf(self.txn, ea.a)).?;
                const spec: Spec = .{ .attr = attr, .reverse = false, .k = value.fromKeywordId(k), .limit = default_limit, .default = null };
                _ = try self.emit(&m, pattern, ent, e, spec, .none, budget);
            }
        }
        if (!any and ent.len == 0) return null;
        return m;
    }

    fn run(self: *Naive, pattern: Value, e: Value) anyerror!Value {
        const eid = try self.resolve(e);
        self.path.clearRetainingCapacity();
        try self.path.append(self.arena, eid);
        var budget: Budget = .empty;
        return (try self.pull(pattern, eid, &budget)) orelse value.nilValue();
    }
};

// =============================================================================
// Printing values for a mismatch
// =============================================================================

fn dump(fx: *Fx, w: *std.Io.Writer, v: Value) anyerror!void {
    switch (v.kind()) {
        .nil => try w.writeAll("nil"),
        .true_ => try w.writeAll("true"),
        .false_ => try w.writeAll("false"),
        .fixnum => try w.print("{d}", .{v.asFixnum()}),
        .float => try w.print("{d}", .{v.asFloat()}),
        .keyword => try w.print(":{s}", .{fx.interner().keywordName(v.asKeywordId())}),
        .string => try w.print("\"{s}\"", .{string_mod.asBytes(v)}),
        .persistent_vector => {
            try w.writeAll("[");
            var it = vector_mod.Cursor.init(v);
            var first = true;
            while (it.next()) |x| {
                if (!first) try w.writeAll(" ");
                first = false;
                try dump(fx, w, x);
            }
            try w.writeAll("]");
        },
        .persistent_map => {
            try w.writeAll("{");
            var it = champ.mapIter(v);
            var first = true;
            while (it.next()) |entry| {
                if (!first) try w.writeAll(", ");
                first = false;
                try dump(fx, w, entry.key);
                try w.writeAll(" ");
                try dump(fx, w, entry.value);
            }
            try w.writeAll("}");
        },
        else => try w.print("<{s}>", .{@tagName(v.kind())}),
    }
}

// =============================================================================
// The corpus
// =============================================================================

const Case = struct { pattern: []const u8, entity: []const u8 };

const ann = "[:person/email \"ann@x\"]";
const bob = "[:person/email \"bob@x\"]";
const cy = "[:person/email \"cy@x\"]";
const di = "[:person/email \"di@x\"]";
const ed = "[:person/email \"ed@x\"]";

const corpus = [_]Case{
    // Wildcard, attribute lists, missing attributes, idents, long strings.
    .{ .pattern = "[*]", .entity = ann },
    .{ .pattern = "[*]", .entity = bob },
    .{ .pattern = "[*]", .entity = ed },
    .{ .pattern = "[*]", .entity = "[:node/label \"n6\"]" },
    .{ .pattern = "[*]", .entity = "[:order/number 1]" },
    .{ .pattern = "[*]", .entity = ":level/senior" },
    .{ .pattern = "[*]", .entity = ":person/friend" },
    .{ .pattern = "[:person/name :person/age]", .entity = ann },
    .{ .pattern = "[:person/name :person/age]", .entity = di },
    .{ .pattern = "[:db/id :person/name]", .entity = ann },
    .{ .pattern = "[:person/tags]", .entity = ann },
    .{ .pattern = "[:person/tags]", .entity = di },
    .{ .pattern = "[:person/friend :person/boss]", .entity = cy },
    .{ .pattern = "[:person/level]", .entity = ann },
    .{ .pattern = "[:person/bio :person/height :person/active]", .entity = ann },
    .{ .pattern = "[:order/items :order/customer]", .entity = "[:order/number 1]" },
    .{ .pattern = "[:order/items :order/customer]", .entity = "[:order/number 2]" },
    .{ .pattern = "[*]", .entity = "[:order/number 9]" },
    .{ .pattern = "[:order/items]", .entity = "[:order/number 9]" },
    .{ .pattern = "[(:order/items :limit nil)]", .entity = "[:order/number 9]" },
    .{ .pattern = "[(:order/items :limit 1001)]", .entity = "[:order/number 9]" },
    // Components.
    .{ .pattern = "[:person/house]", .entity = ann },
    .{ .pattern = "[:person/name :person/house]", .entity = bob },
    .{ .pattern = "[{:person/house [:house/name {:house/rooms [:room/name]}]}]", .entity = ann },
    .{ .pattern = "[{:person/house [:house/name :house/rooms]}]", .entity = ann },
    .{ .pattern = "[{:person/house [{:house/rooms [:room/name :house/_rooms]}]}]", .entity = ann },
    .{ .pattern = "[{:person/house [:person/_house]}]", .entity = ann },
    .{ .pattern = "[{:person/house [{:person/_house [:person/name]}]}]", .entity = ann },
    .{ .pattern = "[* {:person/house [:house/name]}]", .entity = ann },
    // Nested patterns.
    .{ .pattern = "[{:person/friend [:person/name]}]", .entity = cy },
    .{ .pattern = "[{:person/friend [:person/name {:person/friend [:person/email]}]}]", .entity = cy },
    .{ .pattern = "[{:person/boss [*]}]", .entity = bob },
    .{ .pattern = "[{:person/boss [:person/name {:person/boss [:person/name]}]}]", .entity = di },
    .{ .pattern = "[{:person/level [:db/ident]}]", .entity = bob },
    .{ .pattern = "[{:order/customer [:person/name :person/email]}]", .entity = "[:order/number 2]" },
    .{ .pattern = "[{:person/friend [{:person/friend [{:person/friend [:person/name]}]}]}]", .entity = di },
    .{ .pattern = "[{:edge/to [:node/label {:edge/to [:node/label]}]}]", .entity = "[:node/label \"n1\"]" },
    // Reverse references.
    .{ .pattern = "[:person/_friend]", .entity = ann },
    .{ .pattern = "[:person/_friend]", .entity = bob },
    .{ .pattern = "[:person/_friend]", .entity = ed },
    .{ .pattern = "[:person/_boss]", .entity = ann },
    .{ .pattern = "[:person/_boss]", .entity = cy },
    .{ .pattern = "[:person/_boss]", .entity = di },
    .{ .pattern = "[{:person/_friend [:person/name]}]", .entity = ann },
    .{ .pattern = "[{:person/_boss [:person/name {:person/_boss [:person/name]}]}]", .entity = ann },
    .{ .pattern = "[:order/_customer]", .entity = ann },
    .{ .pattern = "[{:order/_customer [:order/number :order/items]}]", .entity = ann },
    .{ .pattern = "[:person/name :person/_friend :order/_customer]", .entity = ann },
    .{ .pattern = "[:edge/_to]", .entity = "[:node/label \"n1\"]" },
    .{ .pattern = "[:node/label {:edge/_to [:node/label]}]", .entity = "[:node/label \"n5\"]" },
    // Recursion: cycles, self-loops, depths.
    .{ .pattern = "[:person/name {:person/friend ...}]", .entity = cy },
    .{ .pattern = "[:person/name {:person/friend ...}]", .entity = di },
    .{ .pattern = "[:person/name {:person/friend ...}]", .entity = ed },
    .{ .pattern = "[:person/name {:person/friend ...}]", .entity = bob },
    .{ .pattern = "[:person/name {:person/boss ...}]", .entity = di },
    .{ .pattern = "[:person/name {:person/boss 1}]", .entity = di },
    .{ .pattern = "[:person/name {:person/boss 0}]", .entity = di },
    .{ .pattern = "[:person/name {:person/boss 5}]", .entity = di },
    .{ .pattern = "[:node/label {:edge/to ...}]", .entity = "[:node/label \"n1\"]" },
    .{ .pattern = "[:node/label {:edge/to ...}]", .entity = "[:node/label \"n3\"]" },
    .{ .pattern = "[:node/label {:edge/to ...}]", .entity = "[:node/label \"n6\"]" },
    .{ .pattern = "[:node/label {:edge/to 2}]", .entity = "[:node/label \"n1\"]" },
    .{ .pattern = "[:node/label {:edge/to 1} {:edge/_to 1}]", .entity = "[:node/label \"n3\"]" },
    .{ .pattern = "[* {:edge/to [:node/label]}]", .entity = "[:node/label \"n3\"]" },
    .{ .pattern = "[:person/name {:person/friend ...} {:person/boss 1}]", .entity = di },
    .{ .pattern = "[:person/name {:person/_friend ...}]", .entity = ann },
    // Options: limit, default, as; expression forms; map keys with options.
    .{ .pattern = "[(:person/tags :limit 1)]", .entity = ann },
    .{ .pattern = "[(:person/friend :limit 1)]", .entity = cy },
    .{ .pattern = "[[:person/tags :limit nil]]", .entity = ann },
    .{ .pattern = "[(:person/friend :limit 0)]", .entity = cy },
    .{ .pattern = "[(limit :person/tags 1)]", .entity = ann },
    .{ .pattern = "[(limit :order/_customer 1)]", .entity = ann },
    .{ .pattern = "[(:person/age :default 0)]", .entity = di },
    .{ .pattern = "[(:person/age :default 0)]", .entity = ann },
    .{ .pattern = "[(default :person/age -1) (default :person/tags [])]", .entity = di },
    .{ .pattern = "[(:person/name :as :nm) (:person/age :as :yrs)]", .entity = ann },
    .{ .pattern = "[(:person/_boss :as :reports)]", .entity = ann },
    .{ .pattern = "[{(:person/friend :limit 1 :as :pal) [:person/name]}]", .entity = cy },
    .{ .pattern = "[{(:order/_customer :limit 1) [:order/number]}]", .entity = ann },
    .{ .pattern = "[{[:person/friend :as :pals] [:person/name]}]", .entity = cy },
    .{ .pattern = "[{(limit :person/friend 1) [:person/name]}]", .entity = cy },
    .{ .pattern = "[* :person/name (:person/tags :limit 1)]", .entity = ann },
};

/// Run one case on `dbv`. With `resolve_on`, the entity argument is
/// resolved to an eid on that view first: a `since` view cannot see
/// the lookup refs' datoms.
fn checkCase(fx: *Fx, dbv: DbValue, c: Case, resolve_on: ?DbValue) !void {
    var entity = try fx.read(c.entity);
    if (resolve_on) |rv| {
        var resolver = try Naive.init(fx, rv);
        defer resolver.deinit();
        entity = value.fromFixnum(@intCast(try resolver.resolve(entity))).?;
    }
    const got = try pull.pull(fx.gpa, fx.interner(), &fx.heap, dbv, try fx.read(c.pattern), entity, &fx.diag);
    var naive = try Naive.init(fx, dbv);
    defer naive.deinit();
    const want = try naive.run(try fx.read(c.pattern), entity);
    if (!dispatch.equal(got, want)) {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try out.writer.print("pull {s} {s}\n  got:  ", .{ c.pattern, c.entity });
        try dump(fx, &out.writer, got);
        try out.writer.writeAll("\n  want: ");
        try dump(fx, &out.writer, want);
        std.debug.print("{s}\n", .{out.written()});
        return error.PullMismatch;
    }
}

fn checkCorpus(fx: *Fx, dbv: DbValue) !void {
    for (corpus) |c| try checkCase(fx, dbv, c, null);
}

test "corpus: every pattern agrees with the naive evaluator on current and as-of views" {
    const fx = try Fx.init("pull_corpus");
    defer fx.deinit();
    try loadCorpus(fx);
    const before = try fx.db();
    try checkCorpus(fx, before);
    const r = try updateCorpus(fx);
    const after = try fx.db();
    try checkCorpus(fx, after);
    try checkCorpus(fx, after.asOf(r.t - 1));
    try checkCorpus(fx, before);
    for (corpus) |c| try checkCase(fx, after.sinceT(r.t - 1), c, after);

    // A few shapes pinned by hand.
    const flo = try fx.pullSrc(after, "[:person/name {:person/boss [:person/name]}]", "[:person/email \"flo@x\"]");
    try testing.expectEqualStrings("Ann", string_mod.asBytes((try fx.getName((try fx.getName(flo, "person/boss")).?, "person/name")).?));
    try testing.expectError(error.NoEntity, fx.pullSrc(after.asOf(r.t - 1), "[*]", "[:person/email \"flo@x\"]"));
    try testing.expectError(error.NoEntity, fx.pullSrc(after, "[*]", "[:order/number 3]"));
    try testing.expectEqual(@as(usize, 3), champ.mapCount(try fx.pullSrc(after.asOf(r.t - 1), "[*]", "[:order/number 3]")));
    const tags_now = (try fx.getName(try fx.pullSrc(after, "[:person/tags]", ann), "person/tags")).?;
    try testing.expectEqual(@as(usize, 1), vector_mod.count(tags_now));
    const tags_then = (try fx.getName(try fx.pullSrc(after.asOf(r.t - 1), "[:person/tags]", ann), "person/tags")).?;
    try testing.expectEqual(@as(usize, 2), vector_mod.count(tags_then));
    var resolver = try Naive.init(fx, after);
    const ann_eid = value.fromFixnum(@intCast(try resolver.resolve(try fx.read(ann)))).?;
    resolver.deinit();
    const since = try pull.pull(fx.gpa, fx.interner(), &fx.heap, after.sinceT(r.t - 1), try fx.read("[*]"), ann_eid, &fx.diag);
    try testing.expectEqual(@as(usize, 2), champ.mapCount(since));
    try testing.expect((try fx.getName(since, "person/friend")) != null);
    try testing.expectError(error.NoEntity, fx.pullSrc(after.sinceT(r.t - 1), "[*]", ann));
    try testing.expectError(error.HistoryView, fx.pullSrc(after.withHistory(), "[*]", ann));

    // pull-many over lookup refs, idents and eids in one Read.
    const es = [_]Value{ try fx.read(ann), try fx.read(":level/junior"), value.fromFixnum(1 << 40).? };
    const many = try pull.pullMany(testing.allocator, fx.interner(), &fx.heap, after, try fx.read("[:person/name :db/ident]"), &es, &fx.diag);
    try testing.expectEqual(@as(usize, 3), vector_mod.count(many));
    try testing.expectEqualStrings("Ann", string_mod.asBytes((try fx.getName(vector_mod.nth(many, 0), "person/name")).?));
    try testing.expect((try fx.getName(vector_mod.nth(many, 1), "db/ident")).?.kind() == .keyword);
    try testing.expect(vector_mod.nth(many, 2).isNil());
}

// =============================================================================
// with
// =============================================================================

test "with: q, entity and pull see the speculative datoms; nothing is written" {
    const fx = try Fx.init("pull_with");
    defer fx.deinit();
    try loadCorpus(fx);
    const before = try fx.db();
    const base_count = champ.setCount(try fx.q(before, "[:find ?e :where [?e :person/name _]]"));

    const tx = try fx.read(
        \\[{:db/id "gus" :person/name "Gus" :person/email "gus@x" :person/age 33 :person/tags [:new] :person/boss [:person/email "ann@x"]}
        \\ [:db/add [:person/email "ann@x"] :person/friend "gus"]
        \\ [:db/retract [:person/email "ann@x"] :person/tags :red]]
    );
    const w = try nextomic.transact.with(fx.conn(), fx.arena(), tx, .{});
    defer w.destroy();
    const view = w.db();
    try testing.expectEqual(before.basis + 1, w.report.t);
    try testing.expectEqual(before.basis, w.report.db_before.basis);
    const gus = w.report.tempids[0].eid;

    // q: the new person, the new friend edge, the retracted tag, the tx entity.
    try testing.expectEqual(base_count + 1, champ.setCount(try fx.q(view, "[:find ?e :where [?e :person/name _]]")));
    try testing.expectEqual(@as(usize, 1), champ.setCount(try fx.q(view, "[:find ?e :where [?e :person/name \"Gus\"] [?e :person/boss [:person/email \"ann@x\"]]]")));
    try testing.expectEqual(@as(usize, 1), champ.setCount(try fx.q(view, "[:find ?f :where [[:person/email \"ann@x\"] :person/friend ?f] [?f :person/name \"Gus\"]]")));
    try testing.expectEqual(@as(usize, 0), champ.setCount(try fx.q(view, "[:find ?e :where [?e :person/tags :red]]")));
    try testing.expectEqual(@as(usize, 1), champ.setCount(try fx.q(view, "[:find ?e :where [?e :person/tags :new]]")));
    const gus_tx = try fx.q(view, "[:find ?tx . :where [?e :person/name \"Gus\" ?tx]]");
    try testing.expectEqual(@as(i64, @intCast(key.txEntity(w.report.t))), gus_tx.asFixnum());
    // entity and pull through the view.
    try testing.expectEqual(@as(usize, 5), (try view.entity(fx.arena(), gus)).len);
    const pulled = try fx.pullSrc(view, "[:person/name {:person/boss [:person/name {:person/friend [:person/name]}]} :person/_friend]", "[:person/email \"gus@x\"]");
    try testing.expectEqualStrings("Gus", string_mod.asBytes((try fx.getName(pulled, "person/name")).?));
    const boss = (try fx.getName(pulled, "person/boss")).?;
    try testing.expectEqualStrings("Ann", string_mod.asBytes((try fx.getName(boss, "person/name")).?));
    // Ann's one friend is Gus, who is on the path and so a plain ref.
    const back = (try fx.getName(boss, "person/friend")).?;
    try testing.expectEqual(@as(usize, 1), vector_mod.count(back));
    try testing.expectEqual(@as(usize, 1), champ.mapCount(vector_mod.nth(back, 0)));
    try testing.expectEqual(@as(usize, 1), vector_mod.count((try fx.getName(pulled, "person/_friend")).?));
    // The whole corpus holds on the view too, against the naive evaluator reading the same view.
    try checkCorpus(fx, view);
    // As-of on the view hides the speculative transaction.
    try testing.expectEqual(base_count, champ.setCount(try fx.q(view.asOf(before.basis), "[:find ?e :where [?e :person/name _]]")));

    // The committed state is unchanged, and stays so after finish.
    try testing.expectEqual(base_count, champ.setCount(try fx.q(before, "[:find ?e :where [?e :person/name _]]")));
    try testing.expectEqual(base_count, champ.setCount(try fx.q(try fx.db(), "[:find ?e :where [?e :person/name _]]")));
    try testing.expectEqual(@as(usize, 1), champ.setCount(try fx.q(try fx.db(), "[:find ?e :where [?e :person/tags :red]]")));
    try testing.expectError(error.Nested, nextomic.transact.with(fx.conn(), fx.arena(), tx, .{}));
    try testing.expectError(error.Nested, nextomic.transact.transact(fx.conn(), fx.arena(), tx, .{}));
    w.finish();
    try testing.expectEqual(before.basis, (try fx.db()).basis);
    try testing.expectEqual(base_count, champ.setCount(try fx.q(try fx.db(), "[:find ?e :where [?e :person/name _]]")));
    try testing.expectError(error.Closed, fx.q(view, "[:find ?e :where [?e :person/name _]]"));

    // Errors surface without a write; a real transaction then takes the speculative t.
    try testing.expectError(error.Conflict, nextomic.transact.with(fx.conn(), fx.arena(), try fx.read(
        \\[[:db/add [:person/email "ann@x"] :person/age 1] [:db/add [:person/email "ann@x"] :person/age 2]]
    ), .{}));
    try testing.expectError(error.Unique, nextomic.transact.with(fx.conn(), fx.arena(), try fx.read(
        \\[[:db/add [:person/email "bob@x"] :person/email "ann@x"]]
    ), .{}));
    try testing.expectEqual(before.basis, (try fx.db()).basis);
    const r = try nextomic.transact.transact(fx.conn(), fx.arena(), tx, .{});
    try testing.expectEqual(w.report.t, r.t);
    try testing.expectEqual(gus, r.tempids[0].eid);
    try testing.expectEqual(base_count + 1, champ.setCount(try fx.q(try fx.db(), "[:find ?e :where [?e :person/name _]]")));
}

// =============================================================================
// Benchmark
// =============================================================================

test "pull-many [*], a nested pattern and a reverse ref over 2k entities" {
    // The same data shape as `zig build bench`'s 20k-entity pull
    // corpus (bench/nextomic.zig), at a size a test can afford.
    const fx = try Fx.init("pull_many");
    defer fx.deinit();
    _ = try fx.transact(
        \\[{:db/ident :emp/name :db/valueType :db.type/string :db/cardinality :db.cardinality/one}
        \\ {:db/ident :emp/age :db/valueType :db.type/long :db/cardinality :db.cardinality/one}
        \\ {:db/ident :emp/dept :db/valueType :db.type/ref :db/cardinality :db.cardinality/one}
        \\ {:db/ident :emp/skills :db/valueType :db.type/keyword :db/cardinality :db.cardinality/many}
        \\ {:db/ident :dept/name :db/valueType :db.type/string :db/cardinality :db.cardinality/one :db/unique :db.unique/identity}]
    );
    const txn0 = try fx.conn().store.beginRead();
    const a_name = (try fx.conn().idents.idOfName(txn0, "emp/name")).?;
    const a_age = (try fx.conn().idents.idOfName(txn0, "emp/age")).?;
    const a_dept = (try fx.conn().idents.idOfName(txn0, "emp/dept")).?;
    const a_skills = (try fx.conn().idents.idOfName(txn0, "emp/skills")).?;
    const a_dname = (try fx.conn().idents.idOfName(txn0, "dept/name")).?;
    txn0.abort();
    const k_zig = try fx.interner().internKeyword("skill/zig");
    const k_lisp = try fx.interner().internKeyword("skill/lisp");

    const depts: usize = 10;
    var dept_ops: std.ArrayList(nextomic.Op) = .empty;
    for (0..depts) |i| {
        const name = try std.fmt.allocPrint(fx.arena(), "d{d}", .{i});
        try dept_ops.append(fx.arena(), .{ .add = .{ .e = .{ .tempid = .{ .fixnum = -@as(i64, @intCast(i + 1)) } }, .a = .{ .id = a_dname }, .v = .{ .val = .{ .string = name } } } });
    }
    const dept_report = try nextomic.transact.transactOps(fx.conn(), fx.arena(), dept_ops.items, .{});
    const dept_eids = try fx.arena().alloc(u64, depts);
    for (dept_report.tempids) |b| dept_eids[@intCast(-b.key.fixnum - 1)] = b.eid;

    const emps: usize = 2_000;
    const batch: usize = 500;
    var eids: std.ArrayList(Value) = .empty;
    var start: usize = 0;
    while (start < emps) : (start += batch) {
        var ops: std.ArrayList(nextomic.Op) = .empty;
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        for (start..start + batch) |i| {
            const me: nextomic.transact.Entity = .{ .tempid = .{ .fixnum = -@as(i64, @intCast(i + 1)) } };
            const name = try std.fmt.allocPrint(arena, "emp-{d}", .{i});
            try ops.append(arena, .{ .add = .{ .e = me, .a = .{ .id = a_name }, .v = .{ .val = .{ .string = name } } } });
            try ops.append(arena, .{ .add = .{ .e = me, .a = .{ .id = a_age }, .v = .{ .val = .{ .long = @intCast(20 + i % 45) } } } });
            try ops.append(arena, .{ .add = .{ .e = me, .a = .{ .id = a_dept }, .v = .{ .val = .{ .ref = dept_eids[i % depts] } } } });
            try ops.append(arena, .{ .add = .{ .e = me, .a = .{ .id = a_skills }, .v = .{ .keyword = k_zig } } });
            if (i % 2 == 0) try ops.append(arena, .{ .add = .{ .e = me, .a = .{ .id = a_skills }, .v = .{ .keyword = k_lisp } } });
        }
        const r = try nextomic.transact.transactOps(fx.conn(), arena, ops.items, .{});
        for (r.tempids) |b| try eids.append(fx.arena(), value.fromFixnum(@intCast(b.eid)).?);
    }
    const dbv = try fx.db();
    const star = try fx.read("[*]");
    const nested = try fx.read("[:emp/name {:emp/dept [:dept/name]} (:emp/skills :limit 1)]");
    const reverse = try fx.read("[:dept/name (:emp/_dept :limit nil)]");
    const dept = value.fromFixnum(@intCast(dept_eids[3])).?;

    const all = try pull.pullMany(fx.gpa, fx.interner(), &fx.heap, dbv, star, eids.items, &fx.diag);
    const some = try pull.pullMany(fx.gpa, fx.interner(), &fx.heap, dbv, nested, eids.items, &fx.diag);
    const rev = try pull.pull(fx.gpa, fx.interner(), &fx.heap, dbv, reverse, dept, &fx.diag);
    try testing.expectEqual(emps, vector_mod.count(all));
    try testing.expectEqual(emps, vector_mod.count(some));
    try testing.expectEqual(emps / depts, vector_mod.count((try fx.getName(rev, "emp/_dept")).?));
}
