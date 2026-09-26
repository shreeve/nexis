//! query/exec.zig — running a plan over one `Read` (NEXTOMIC.md §5
//! "Execute").
//!
//! Invariants:
//!   - One `Read` (one emdb snapshot) per data source serves every scan
//!     of a query; the caller opens them before planning and closes
//!     them after the result is materialised, on success or error. A
//!     scan, `missing?` and `get-else` read the source their clause
//!     names; an input resolves its idents and lookup refs in the
//!     source of the first pattern that gives it an entity role; a pull
//!     expression reads the source it names, `$` by default.
//!   - A scan seeks by the constants and bound variables that lead its
//!     index and post-filters everything else; `tx` binds the
//!     transaction entity id and `added` the datom's flag. The mode of
//!     the db-value is inside the `Read`, so scans see folded datoms.
//!   - Per scan the join is an index nested loop (one seek per input
//!     row) or one constant-prefix scan hash-joined on the shared
//!     variables, as `plan.nestedLoop` decides from the input rows.
//!   - Built-in predicates and functions are Zig over cells; any other
//!     symbol goes to the `CallHook` with VM values, as does the value
//!     of a variable in function position, and its errors propagate
//!     untouched (the caller closes the `Read` on the way out).
//!   - A function result of nil drops the row; collection and relation
//!     bindings fan out one row per element.
//!   - `findRows` forms the basis set (distinct tuples over the find and
//!     `:with` variables) and groups and aggregates it; `materialise`
//!     applies pull expressions in the same snapshot and copies the
//!     result into the VM heap as the find spec and `:keys` ask.
//!
//! Every function on a path to the call hook is `anyerror`: the hook
//! raises whatever the VM raises, and that passes through untouched.

const std = @import("std");
const value = @import("../../value.zig");
const heap_mod = @import("../../heap.zig");
const intern_mod = @import("../../intern.zig");
const string_mod = @import("../../string.zig");
const list_mod = @import("../../coll/list.zig");
const vector_mod = @import("../../coll/vector.zig");
const champ = @import("../../coll/champ.zig");
const dispatch = @import("../../dispatch.zig");
const bignum = @import("../../bignum.zig");
const key = @import("../key.zig");
const datom_mod = @import("../datom.zig");
const schema_mod = @import("../schema.zig");
const db_mod = @import("../db.zig");
const relation = @import("../relation.zig");
const ir = @import("ir.zig");
const plan_mod = @import("plan.zig");
const rules_mod = @import("rules.zig");
const marshal = @import("../marshal.zig");
const pull_mod = @import("../pull.zig");
const fulltext = @import("../fulltext.zig");
const stack = @import("../../stack.zig");

const Allocator = std.mem.Allocator;
const Value = value.Value;
const Heap = heap_mod.Heap;
const Interner = intern_mod.Interner;
const Read = db_mod.Read;
const Var = ir.Var;
const Cell = ir.Cell;
const Relation = relation.Relation;
const Ir = ir.Ir;
const Diag = plan_mod.Diag;
const Plan = plan_mod.Plan;
const Step = plan_mod.Step;
const Scan = plan_mod.Scan;

/// Calls a user function: `call` by VM symbol, `apply` by the value a
/// variable in function position holds. `args` are VM values built in
/// the query's result heap; the result must be a VM value, which the
/// hook keeps reachable for the query's life. `root` does the same for
/// a heap value the pipeline builds itself and holds in a relation or
/// a group across later calls; a host whose calls never collect leaves
/// it null.
pub const CallHook = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, sym: u32, args: []const Value) anyerror!Value,
    apply: *const fn (ctx: *anyopaque, f: Value, args: []const Value) anyerror!Value,
    root: ?*const fn (ctx: *anyopaque, v: Value) anyerror!void = null,
};

/// A data source: a db value's read, or a collection of tuples whose
/// elements a pattern matches by position (`[e a v tx added]`).
pub const Source = union(enum) {
    db: *Read,
    coll: []const []const Cell,
};

pub const Exec = struct {
    arena: Allocator,
    /// The data sources, `$` first.
    sources: []const Source,
    heap: *Heap,
    interner: *Interner,
    hook: ?CallHook,
    /// Where an `UnknownAttribute` in an input leaves its name.
    diag: ?*Diag = null,
    /// The inputs, positional to `:in`: where a pull pattern bound by
    /// `:in` is found.
    args: []const Value = &.{},
    /// The random source of `sample` and `rand`, made on first use.
    prng: ?std.Random.DefaultPrng = null,

    /// Run `p` from `input`, which binds at least `p.input`.
    pub fn runPlan(self: *Exec, p: *const Plan, input: Relation) anyerror!Relation {
        try stack.check();
        var rel = input;
        for (p.steps) |*s| rel = try self.step(s, rel);
        return rel;
    }

    fn step(self: *Exec, s: *const Step, rel: Relation) anyerror!Relation {
        return switch (s.*) {
            .scan => |*sc| self.execScan(sc, rel),
            .match => |*m| self.execMatch(m, rel),
            .pred => |*p| self.execPred(p, rel),
            .bind => |*b| self.execBind(b, rel),
            .not => |*n| self.execNot(n, rel),
            .@"or" => |*o| self.execOr(o, rel),
            .source => |*src| self.execSource(src, rel),
            .fix => |*f| rules_mod.execFix(self, f, rel),
        };
    }

    // ── datoms to cells ───────────────────────────────────────────

    /// The `Read` of a source (null: `$`); a collection has none.
    fn readOf(self: *Exec, src: ?ir.Src) error{QuerySyntax}!*Read {
        return switch (self.sources[src orelse 0]) {
            .db => |r| r,
            .coll => self.syntax("this clause reads a db value, and its source is a collection"),
        };
    }

    /// The cell of a datom value read from `read`: ids as `int`,
    /// keywords as VM keyword ids, uuids as text.
    pub fn valCell(self: *Exec, read: *Read, v: key.Val) !Cell {
        return marshal.cellOf(read, self.arena, v);
    }

    fn datomCells(self: *Exec, read: *Read, d: datom_mod.Datom) ![5]Cell {
        return .{
            .{ .int = @intCast(d.e) },
            .{ .int = d.a },
            try self.valCell(read, d.v),
            .{ .int = @intCast(key.txEntity(d.t)) },
            .{ .boolean = d.added },
        };
    }

    // ── cells to values ───────────────────────────────────────────

    pub fn cellValue(self: *Exec, c: Cell) !Value {
        return switch (c) {
            .nil => value.nilValue(),
            .int => |n| value.fromFixnum(n) orelse try bignum.fromI64(self.heap, n),
            .double => |d| value.fromFloat(d),
            .boolean => |b| value.fromBool(b),
            .keyword => |k| value.fromKeywordId(k),
            .str => |s| try string_mod.fromBytes(self.heap, s),
            .vm => |v| v,
        };
    }

    /// `v`, a heap value the pipeline built, kept reachable for the
    /// query's life: a user function called later may collect.
    fn kept(self: *Exec, v: Value) !Value {
        if (self.hook) |h| if (h.root) |root| try root(h.ctx, v);
        return v;
    }

    /// The cells as a vector value, kept reachable.
    fn keptVector(self: *Exec, cells: []const Cell) !Value {
        return self.kept(try self.rowVector(cells));
    }

    // ── scans ─────────────────────────────────────────────────────

    /// Where an output variable's cell comes from.
    const Src = union(enum) {
        row: usize,
        pos: usize,
    };

    fn execScan(self: *Exec, s: *const Scan, rel: Relation) anyerror!Relation {
        const out_vars = try std.mem.concat(self.arena, Var, &.{ rel.vars, s.fresh });
        var out = try Relation.init(self.arena, out_vars);
        if (s.unsatisfiable or rel.rows == 0) return out;

        const nested = plan_mod.nestedLoop(s, rel.rows);
        const slots = s.slots();
        // A pattern that binds nothing only asks whether a datom exists:
        // one per row is the answer, and nothing repeats.
        const probe = s.fresh.len == 0;

        if (nested) {
            const srcs = try self.arena.alloc(Src, out_vars.len);
            for (out_vars, srcs) |v, *src| src.* = if (rel.colOf(v)) |c| .{ .row = c } else .{ .pos = slotPos(slots, v) };
            const row = try self.arena.alloc(Cell, rel.cols.len);
            var i: usize = 0;
            while (i < rel.rows) : (i += 1) {
                rel.rowInto(i, row);
                try self.scanInto(s, s.index, &rel, row, srcs, &out, probe);
            }
            if (probe) return out;
        } else {
            var pvars: std.ArrayList(Var) = .empty;
            for (slots) |slot| switch (slot) {
                .bound, .fresh => |v| try ir.addVar(self.arena, &pvars, v),
                else => {},
            };
            var scanned = try Relation.init(self.arena, pvars.items);
            const srcs = try self.arena.alloc(Src, pvars.items.len);
            for (pvars.items, srcs) |v, *src| src.* = .{ .pos = slotPos(slots, v) };
            try self.scanInto(s, s.hash_index.?, null, &.{}, srcs, &scanned, false);
            if (probe) return rel.hashJoin(&(try scanned.dedup()));
            out = try rel.hashJoin(&scanned);
        }
        return if (s.dedup) out.dedup() else out;
    }

    /// A pattern over a collection: the tuples whose elements equal the
    /// constants and agree on a repeated variable, joined with `rel` on
    /// the bound variables. A tuple shorter than a position the pattern
    /// uses matches nothing.
    fn execMatch(self: *Exec, m: *const plan_mod.Match, rel: Relation) anyerror!Relation {
        var pvars: std.ArrayList(Var) = .empty;
        for (m.slots) |slot| switch (slot) {
            .bound, .fresh => |v| try ir.addVar(self.arena, &pvars, v),
            else => {},
        };
        var matched = try Relation.init(self.arena, pvars.items);
        const cells = try self.arena.alloc(Cell, pvars.items.len);
        tuples: for (m.rows) |t| {
            for (m.slots, 0..) |slot, pos| {
                if (slot == .blank) continue;
                if (pos >= t.len) continue :tuples;
                switch (slot) {
                    .blank => {},
                    .constant => |c| if (!t[pos].eql(c.cell)) continue :tuples,
                    .same => |v| if (!t[pos].eql(t[slotPos(m.slots, v)])) continue :tuples,
                    .bound, .fresh => |v| {
                        const first = slotPos(m.slots, v);
                        if (first != pos) {
                            if (!t[pos].eql(t[first])) continue :tuples;
                        } else cells[std.mem.indexOfScalar(Var, pvars.items, v).?] = t[pos];
                    },
                }
            }
            try matched.append(cells);
        }
        return rel.hashJoin(&(try matched.dedup()));
    }

    /// The first position whose slot names `v`.
    fn slotPos(slots: [5]plan_mod.Slot, v: Var) usize {
        for (slots, 0..) |slot, i| switch (slot) {
            .bound, .fresh => |x| if (x == v) return i,
            else => {},
        };
        unreachable;
    }

    /// The cell a bound slot compares against: the constant, or the
    /// input row's value (null without a row, when the hash join
    /// compares instead).
    fn slotCell(slot: plan_mod.Slot, rel: ?*const Relation, row: []const Cell) ?Cell {
        return switch (slot) {
            .constant => |c| c.cell,
            .bound => |v| if (rel) |r| row[r.colOf(v).?] else null,
            else => null,
        };
    }

    /// Scan `planned` for the datoms of `s` given one input row (or
    /// none), appending the passing rows to `out` through `srcs`, or
    /// only the first when `first_only`. A
    /// VAET scan whose value cell is not an entity id becomes a scan
    /// of every datom in AEVT, filtered on the value.
    fn scanInto(self: *Exec, s: *const Scan, planned: key.Index, rel: ?*const Relation, row: []const Cell, srcs: []const Src, out: *Relation, first_only: bool) anyerror!void {
        const read = self.sources[s.src].db;
        const slots = s.slots();
        var comps: key.Components = .{};
        var index = planned;
        // The cells the bound positions compare against, with an ident
        // in the attribute position turned into the attribute id.
        var wants: [5]?Cell = undefined;
        for (slots, 0..) |slot, pos| wants[pos] = slotCell(slot, rel, row);

        if (wants[0]) |c| comps.e = c.asEid() orelse return;

        var attr = s.attr;
        if (wants[1]) |c| {
            const n: i64 = switch (c) {
                .keyword => |kw| (try read.db.conn.idents.idOf(read.txn, kw)) orelse return,
                else => c.asInt() orelse return,
            };
            if (n <= 0 or n >= key.attr_partition_end) return;
            comps.a = @intCast(n);
            wants[1] = .{ .int = n };
            if (attr == null) attr = (try read.attr(comps.a.?)) orelse return;
        }

        if (wants[2]) |c| {
            if (slots[2] == .constant and slots[2].constant.bytes != null) {
                comps.v = slots[2].constant.bytes;
            } else if (attr) |at| {
                const val = (try marshal.encodeCell(read, c, at.value_type)) orelse return;
                comps.v = key.valBytes(self.arena, val) catch |err| switch (err) {
                    error.ValueType => return,
                    else => return err,
                };
            } else if (index == .vaet) {
                if (c.asEid()) |eid| {
                    comps.v = try key.valBytes(self.arena, .{ .ref = eid });
                } else {
                    index = .aevt;
                }
            }
        }

        var it = try read.scan(self.arena, index, comps);
        const cells = try self.arena.alloc(Cell, out.cols.len);
        datoms: while (try it.next()) |d| {
            const dc = try self.datomCells(read, d);
            for (slots, 0..) |slot, pos| {
                switch (slot) {
                    .blank, .fresh => {},
                    .constant, .bound => if (wants[pos]) |want| {
                        if (!dc[pos].eql(want)) continue :datoms;
                    },
                    .same => |v| if (!dc[pos].eql(dc[slotPos(slots, v)])) continue :datoms,
                }
            }
            for (srcs, cells) |src, *cell| cell.* = switch (src) {
                .row => |c| row[c],
                .pos => |p| dc[p],
            };
            try out.append(cells);
            if (first_only) return;
        }
    }

    // ── predicates and functions ──────────────────────────────────

    fn argCell(rel: *const Relation, row: usize, a: ir.Arg) Cell {
        return switch (a) {
            .variable => |v| rel.get(row, v).?,
            .constant => |c| c,
            .src => .nil,
        };
    }

    fn argCells(self: *Exec, rel: *const Relation, row: usize, args: []const ir.Arg) ![]Cell {
        const out = try self.arena.alloc(Cell, args.len);
        for (args, out) |a, *c| c.* = argCell(rel, row, a);
        return out;
    }

    fn callUser(self: *Exec, sym: u32, cells: []const Cell) anyerror!Value {
        const hook = self.hook orelse return error.NoHook;
        return hook.call(hook.ctx, sym, try self.argValues(cells));
    }

    /// Apply the value in `f`'s column of `row`, a function bound
    /// through `:in` or an earlier clause.
    fn applyVar(self: *Exec, rel: *const Relation, row: usize, f: Var, cells: []const Cell) anyerror!Value {
        const hook = self.hook orelse return error.NoHook;
        const callee = try self.cellValue(rel.get(row, f).?);
        return hook.apply(hook.ctx, callee, try self.argValues(cells));
    }

    fn argValues(self: *Exec, cells: []const Cell) ![]Value {
        const args = try self.arena.alloc(Value, cells.len);
        for (cells, args) |c, *a| a.* = try self.cellValue(c);
        return args;
    }

    fn execPred(self: *Exec, p: *const plan_mod.Pred, rel: Relation) anyerror!Relation {
        var out = try Relation.init(self.arena, rel.vars);
        const map = try out.mapFrom(&rel);
        var i: usize = 0;
        while (i < rel.rows) : (i += 1) {
            const cells = try self.argCells(&rel, i, p.call.args);
            const keep = switch (p.call.f) {
                .builtin => |b| try self.builtinPred(b, p.call.args, cells),
                .user => |sym| (try self.callUser(sym, cells)).isTruthy(),
                .variable => |f| (try self.applyVar(&rel, i, f, cells)).isTruthy(),
            };
            if (keep) try out.appendFrom(&rel, i, map);
        }
        return out;
    }

    /// `call_args` carry what a cell cannot: the source of `missing?`.
    fn builtinPred(self: *Exec, b: ir.Builtin, call_args: []const ir.Arg, args: []const Cell) anyerror!bool {
        switch (b) {
            .lt, .le, .gt, .ge => {
                for (args[0 .. args.len - 1], args[1..]) |x, y| {
                    const o = x.compare(y, self.interner) orelse return error.ValueType;
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
                for (args[1..]) |y| if (!args[0].eql(y)) return false;
                return true;
            },
            .ne => {
                for (args[1..]) |y| if (!args[0].eql(y)) return true;
                return false;
            },
            .missing => return (try self.firstValue(call_args[0].src, args[1], args[2])) == null,
            .ground, .get_else, .get_some, .tuple, .untuple, .fulltext => unreachable,
        }
    }

    /// `[[e v] ...]`: the string values of `attr` (a keyword cell) in
    /// source `src` that hold every token of `needle`, in entity order.
    /// A view at the newest basis reads the tokens tree; any other
    /// re-tokenises the attribute's values in that view. The attribute
    /// must carry `:db/fulltext` at the view's basis.
    fn fulltextHits(self: *Exec, src: ?ir.Src, attr: Cell, needle: Cell) anyerror![]const []const Cell {
        const read = try self.readOf(src);
        if (needle != .str) return error.ValueType;
        const at = try self.attrNamed(read, attr);
        const a = at.id;
        if (!at.fulltext) {
            if (self.diag) |d| d.* = .{ .message = "attribute is not :db/fulltext", .attr = value.fromKeywordId(attr.keyword) };
            return error.TxData;
        }
        const tokens = try fulltext.tokens(self.arena, needle.str);
        var rows: std.ArrayList([]const Cell) = .empty;
        if (read.fast()) {
            const hits = try fulltext.search(read.db.conn.store, read.txn, self.arena, a, tokens);
            var i: usize = 0;
            while (i < hits.len) {
                const e = hits[i].e;
                var j = i;
                while (j < hits.len and hits[j].e == e) j += 1;
                var it = try read.scan(self.arena, .eavt, .{ .e = e, .a = a });
                while (try it.next()) |d| {
                    if (d.v != .string) continue;
                    const h = key.hash128(d.v.string);
                    for (hits[i..j]) |hit| if (hit.hash == h) {
                        try rows.append(self.arena, try self.pair(read, d));
                        break;
                    };
                }
                i = j;
            }
        } else if (tokens.len > 0) {
            var it = try read.scan(self.arena, .aevt, .{ .a = a });
            while (try it.next()) |d| {
                if (d.v != .string or !try fulltext.matches(self.arena, d.v.string, tokens)) continue;
                try rows.append(self.arena, try self.pair(read, d));
            }
        }
        return rows.items;
    }

    fn pair(self: *Exec, read: *Read, d: datom_mod.Datom) ![]const Cell {
        return self.arena.dupe(Cell, &.{ .{ .int = @intCast(d.e) }, try self.valCell(read, d.v) });
    }

    fn unknownAttribute(self: *Exec, kw: u32) anyerror {
        if (self.diag) |d| d.* = .{ .message = "unknown attribute", .attr = value.fromKeywordId(kw) };
        return error.UnknownAttribute;
    }

    /// The attribute a keyword cell names in `read`: `UnknownAttribute`
    /// when there is none, `ValueType` for any other cell.
    fn attrNamed(self: *Exec, read: *Read, attr: Cell) anyerror!schema_mod.Attr {
        if (attr != .keyword) return error.ValueType;
        const a = (try read.db.conn.idents.idOf(read.txn, attr.keyword)) orelse return self.unknownAttribute(attr.keyword);
        return (try read.attr(a)) orelse self.unknownAttribute(attr.keyword);
    }

    /// The first value of attribute `attr` (a keyword cell) on entity
    /// `e` in source `src`, or null.
    fn firstValue(self: *Exec, src: ?ir.Src, e: Cell, attr: Cell) anyerror!?Cell {
        const read = try self.readOf(src);
        const at = try self.attrNamed(read, attr);
        const eid = e.asEid() orelse return null;
        var it = try read.scan(self.arena, .eavt, .{ .e = eid, .a = at.id });
        const d = (try it.next()) orelse return null;
        return try self.valCell(read, d.v);
    }

    /// `get-else`: the attribute's value on the entity, else the
    /// default. A card-many attribute has no one value and a nil
    /// default binds nothing, so both are refused.
    fn getElse(self: *Exec, src: ?ir.Src, e: Cell, attr: Cell, default: Cell) anyerror!Cell {
        if (default == .nil) return self.syntax("get-else takes a default that is not nil");
        if ((try self.attrNamed(try self.readOf(src), attr)).many()) return self.syntax("get-else takes a cardinality-one attribute");
        return (try self.firstValue(src, e, attr)) orelse default;
    }

    fn syntax(self: *Exec, message: []const u8) error{QuerySyntax} {
        if (self.diag) |d| d.* = .{ .message = message };
        return error.QuerySyntax;
    }

    /// What a function clause returns: a user function's value, or a
    /// built-in's result in cell space, which binds without a trip
    /// through the heap: one value (`ground`, `untuple`, `get-else`), a
    /// tuple (`tuple`, `get-some`) or a collection of tuples
    /// (`fulltext`).
    const Result = union(enum) {
        value: Value,
        cell: Cell,
        tuple: []const Cell,
        tuples: []const []const Cell,
    };

    /// One element of a result that binds as a collection.
    const Elem = union(enum) {
        cell: Cell,
        tuple: []const Cell,
    };

    fn execBind(self: *Exec, b: *const plan_mod.Bind, rel: Relation) anyerror!Relation {
        const out_vars = try std.mem.concat(self.arena, Var, &.{ rel.vars, b.fresh });
        var out = try Relation.init(self.arena, out_vars);
        const row = try self.arena.alloc(Cell, out_vars.len);
        var i: usize = 0;
        while (i < rel.rows) : (i += 1) {
            const cells = try self.argCells(&rel, i, b.call.args);
            const result: Result = switch (b.call.f) {
                .builtin => |bi| switch (bi) {
                    .ground, .untuple => .{ .cell = cells[0] },
                    .get_else => .{ .cell = try self.getElse(b.call.args[0].src, cells[1], cells[2], cells[3]) },
                    // `[attr value]` for the first attribute the entity has, else nil.
                    .get_some => blk: {
                        for (cells[2..]) |attr| {
                            const found = (try self.firstValue(b.call.args[0].src, cells[1], attr)) orelse continue;
                            break :blk .{ .tuple = try self.arena.dupe(Cell, &.{ attr, found }) };
                        }
                        break :blk .{ .cell = .nil };
                    },
                    .tuple => .{ .tuple = cells },
                    .fulltext => .{ .tuples = try self.fulltextHits(b.call.args[0].src, cells[1], cells[2]) },
                    .lt, .le, .gt, .ge, .eq, .ne, .missing => .{ .cell = .{ .boolean = try self.builtinPred(bi, b.call.args, cells) } },
                },
                .user => |sym| .{ .value = try self.callUser(sym, cells) },
                .variable => |f| .{ .value = try self.applyVar(&rel, i, f, cells) },
            };
            rel.rowInto(i, row[0..rel.cols.len]);
            try self.bindResult(b, result, row, rel.cols.len, &out);
        }
        return switch (b.out) {
            .collection, .relation => out.dedup(),
            else => out,
        };
    }

    /// Append the rows `result` binds under `b.out`; `row[0..base]`
    /// holds the input row. An output variable bound before the step
    /// unifies: the row is kept only when the result equals its value.
    /// A nil result binds nothing under a scalar or tuple form; a
    /// result that is not the collection its binding form needs is
    /// `ValueType`.
    fn bindResult(self: *Exec, b: *const plan_mod.Bind, result: Result, row: []Cell, base: usize, out: *Relation) anyerror!void {
        switch (b.out) {
            .scalar => |v| {
                const c: Cell = switch (result) {
                    .value => |x| Cell.fromValue(x),
                    .cell => |x| x,
                    .tuple => |ts| .{ .vm = try self.keptVector(ts) },
                    .tuples => |rows| .{ .vm = try self.keptVectors(rows) },
                };
                if (c == .nil) return;
                if (put(out, row, base, v, c)) try out.append(row);
            },
            .collection => |v| for (try self.elements(result)) |x| {
                const c: Cell = switch (x) {
                    .cell => |y| y,
                    .tuple => |ts| .{ .vm = try self.keptVector(ts) },
                };
                if (put(out, row, base, v, c)) try out.append(row);
            },
            .tuple => |ts| {
                const cells: []const Cell = switch (result) {
                    .value => |x| if (x.isNil()) return else try self.valueCells(x),
                    .cell => |x| if (x == .nil) return else try self.cellCells(x),
                    .tuple => |t| t,
                    .tuples => |rows| blk: {
                        const cs = try self.arena.alloc(Cell, rows.len);
                        for (rows, cs) |r, *c| c.* = .{ .vm = try self.keptVector(r) };
                        break :blk cs;
                    },
                };
                if (try fillTuple(out, ts, cells, row, base)) try out.append(row);
            },
            .relation => |ts| for (try self.elements(result)) |x| {
                const cells = switch (x) {
                    .cell => |y| try self.cellCells(y),
                    .tuple => |t| t,
                };
                if (try fillTuple(out, ts, cells, row, base)) try out.append(row);
            },
        }
    }

    /// The elements of a result that binds as a collection.
    fn elements(self: *Exec, result: Result) ![]const Elem {
        switch (result) {
            .value, .cell => {
                const cells = switch (result) {
                    .value => |x| try self.valueCells(x),
                    .cell => |x| try self.cellCells(x),
                    else => unreachable,
                };
                const out = try self.arena.alloc(Elem, cells.len);
                for (cells, out) |c, *e| e.* = .{ .cell = c };
                return out;
            },
            .tuple => |ts| {
                const out = try self.arena.alloc(Elem, ts.len);
                for (ts, out) |c, *e| e.* = .{ .cell = c };
                return out;
            },
            .tuples => |rows| {
                const out = try self.arena.alloc(Elem, rows.len);
                for (rows, out) |r, *e| e.* = .{ .tuple = r };
                return out;
            },
        }
    }

    /// The elements of a collection value as cells; `ValueType` for
    /// anything but a vector, list or set.
    fn valueCells(self: *Exec, v: Value) ![]const Cell {
        const items = (try self.seqElems(v)) orelse return error.ValueType;
        const out = try self.arena.alloc(Cell, items.len);
        for (items, out) |x, *c| c.* = Cell.fromValue(x);
        return out;
    }

    /// The elements of a cell holding a collection value.
    fn cellCells(self: *Exec, c: Cell) ![]const Cell {
        return switch (c) {
            .vm => |v| self.valueCells(v),
            else => error.ValueType,
        };
    }

    /// Tuples as a vector of vectors, kept reachable.
    fn keptVectors(self: *Exec, rows: []const []const Cell) !Value {
        const vals = try self.arena.alloc(Value, rows.len);
        for (rows, vals) |r, *v| v.* = try self.rowVector(r);
        return self.kept(try vector_mod.fromSlice(self.heap, vals));
    }

    /// Place `cell` in the row for `v`: written when the step binds
    /// `v` (its column is past `base`), compared when an earlier step
    /// did. False when the comparison fails.
    fn put(out: *const Relation, row: []Cell, base: usize, v: Var, cell: Cell) bool {
        const col = out.colOf(v).?;
        if (col < base) return row[col].eql(cell);
        row[col] = cell;
        return true;
    }

    /// Fill the tuple binding `ts` from `items`; false when a bound
    /// variable disagrees with its element, `ValueType` when there are
    /// fewer items than the binding names.
    fn fillTuple(out: *const Relation, ts: []const ?Var, items: []const Cell, row: []Cell, base: usize) !bool {
        if (items.len < ts.len) return error.ValueType;
        for (ts, items[0..ts.len]) |t, x| {
            const tv = t orelse continue;
            if (!put(out, row, base, tv, x)) return false;
        }
        return true;
    }

    /// The elements of a vector, list or set value, or null.
    pub fn seqElems(self: *Exec, v: Value) !?[]Value {
        return marshal.collection(self.arena, v);
    }

    // ── not, or, source ───────────────────────────────────────────

    fn execNot(self: *Exec, n: *const plan_mod.Not, rel: Relation) anyerror!Relation {
        if (rel.rows == 0) return rel;
        const input = try rel.project(n.join, true);
        const found = try self.runPlan(n.sub, input);
        return rel.difference(&found, n.join);
    }

    fn execOr(self: *Exec, o: *const plan_mod.Or, rel: Relation) anyerror!Relation {
        if (rel.rows == 0) return Relation.init(self.arena, try std.mem.concat(self.arena, Var, &.{ rel.vars, o.fresh }));
        const input = if (o.bound.len == 0) try Relation.unit(self.arena) else try rel.project(o.bound, true);
        var acc = try Relation.init(self.arena, o.join);
        for (o.branches) |br| {
            const r = try self.runPlan(br, input);
            const projected = try r.project(o.join, true);
            acc = try acc.unionWith(&projected);
        }
        return rel.hashJoin(&acc);
    }

    fn execSource(self: *Exec, src: *const plan_mod.Source, rel: Relation) anyerror!Relation {
        // A fix step fills every slot of its instances before running them.
        const view = try Relation.viewAs(self.arena, src.vars, src.slot.rel.?);
        return rel.hashJoin(&view);
    }

    // ── inputs ────────────────────────────────────────────────────

    /// The relation the `:in` bindings of `q` make of `args`, one per
    /// binding. A lookup ref or an ident bound to a variable in an
    /// entity position, or in the value position of a ref attribute,
    /// becomes the entity id, and a row whose reference resolves to
    /// nothing is dropped; a keyword bound to a variable that is also a
    /// keyword attribute's value stays a keyword. An input that is not
    /// the collection its binding form needs is `ValueType`.
    pub fn inputRelation(self: *Exec, q: *const Ir, args: []const Value) anyerror!Relation {
        const in = q.in;
        std.debug.assert(args.len == in.len);
        var rel = try Relation.unit(self.arena);
        for (in, args) |b, a| {
            const part: Relation = switch (b) {
                .src, .rules => continue,
                .scalar => |v| blk: {
                    var r = try Relation.init(self.arena, &.{v});
                    try r.append(&.{Cell.fromValue(a)});
                    break :blk r;
                },
                .collection => |v| blk: {
                    var r = try Relation.init(self.arena, &.{v});
                    for ((try self.seqElems(a)) orelse return error.ValueType) |x| try r.append(&.{Cell.fromValue(x)});
                    break :blk try r.dedup();
                },
                .tuple => |ts| blk: {
                    var r = try Relation.init(self.arena, try (ir.Binding{ .tuple = ts }).vars(self.arena));
                    const row = try self.arena.alloc(Cell, r.vars.len);
                    if (try fillTuple(&r, ts, try self.valueCells(a), row, 0)) try r.append(row);
                    break :blk r;
                },
                .relation => |ts| blk: {
                    var r = try Relation.init(self.arena, try (ir.Binding{ .tuple = ts }).vars(self.arena));
                    const row = try self.arena.alloc(Cell, r.vars.len);
                    for ((try self.seqElems(a)) orelse return error.ValueType) |x| {
                        if (try fillTuple(&r, ts, try self.valueCells(x), row, 0)) try r.append(row);
                    }
                    break :blk try r.dedup();
                },
            };
            rel = try rel.hashJoin(&part);
        }
        return self.resolveInputs(q, rel);
    }

    /// `src` is the source of the first pattern that put the variable
    /// in an entity role; its idents and lookups resolve there.
    const InputRole = struct { entity: bool = false, keyword: bool = false, src: ir.Src = 0 };

    /// `rel` with the entity-role columns resolved (see `inputRelation`).
    fn resolveInputs(self: *Exec, q: *const Ir, rel: Relation) anyerror!Relation {
        const roles = try self.arena.alloc(InputRole, q.vars.len);
        @memset(roles, .{});
        try self.inputRoles(q.where, roles);
        var cols: std.ArrayList(usize) = .empty;
        for (rel.vars, 0..) |v, i| if (roles[v].entity and !roles[v].keyword) try cols.append(self.arena, i);
        if (cols.items.len == 0) return rel;

        var out = try Relation.init(self.arena, rel.vars);
        const row = try self.arena.alloc(Cell, rel.vars.len);
        var i: usize = 0;
        rows: while (i < rel.rows) : (i += 1) {
            rel.rowInto(i, row);
            for (cols.items) |c| {
                if (row[c] != .keyword and row[c] != .vm) continue;
                const e = (try self.inputEntity(self.sources[roles[rel.vars[c]].src].db, row[c])) orelse continue :rows;
                row[c] = .{ .int = @intCast(e) };
            }
            try out.append(row);
        }
        return out;
    }

    /// Mark the variables in an entity position or a ref attribute's
    /// value position, and those in a keyword attribute's value position.
    fn inputRoles(self: *Exec, clauses: []const ir.Clause, roles: []InputRole) anyerror!void {
        for (clauses) |c| switch (c) {
            .pattern => |p| {
                // A collection's tuples are taken as they are.
                const read = switch (self.sources[p.src orelse 0]) {
                    .db => |r| r,
                    .coll => continue,
                };
                if (p.e.asVar()) |v| markEntity(&roles[v], p.src orelse 0);
                const v = p.v.asVar() orelse continue;
                if (p.a != .constant or p.a.constant != .cell or p.a.constant.cell != .keyword) continue;
                const id = (try read.db.conn.idents.idOf(read.txn, p.a.constant.cell.keyword)) orelse continue;
                const at = (try read.attr(@intCast(id))) orelse continue;
                if (at.value_type == .ref) markEntity(&roles[v], p.src orelse 0);
                if (at.value_type == .keyword) roles[v].keyword = true;
            },
            .not => |n| try self.inputRoles(n.body, roles),
            .@"or" => |o| for (o.branches) |b| try self.inputRoles(b, roles),
            .pred, .bind, .rule, .source => {},
        };
    }

    fn markEntity(role: *InputRole, src: ir.Src) void {
        if (!role.entity) role.src = src;
        role.entity = true;
    }

    /// The entity an ident or lookup-ref input names in `read` (the
    /// `marshal` contract), or null when there is none; the diagnostic
    /// carries what a failing lookup ref named.
    fn inputEntity(self: *Exec, read: *Read, c: Cell) anyerror!?u64 {
        const v: Value = switch (c) {
            .keyword => |kw| value.fromKeywordId(kw),
            .vm => |v| v,
            else => return null,
        };
        var fault: db_mod.Fault = .{};
        return marshal.entity(read, self.arena, v, &fault) catch |err| {
            if (self.diag) |d| d.* = .{ .message = fault.message orelse "unknown attribute", .attr = fault.attr };
            return err;
        };
    }

    // ── find ──────────────────────────────────────────────────────

    /// Rows of cells in `:find` order, after the basis set, grouping
    /// and aggregation. Distinct for relation and collection specs.
    pub fn findRows(self: *Exec, query: *const ir.Ir, rel: Relation) anyerror![]const []const Cell {
        var basis_vars: std.ArrayList(Var) = .empty;
        for (query.find) |f| try ir.addVar(self.arena, &basis_vars, f.variable_of());
        for (query.with) |w| try ir.addVar(self.arena, &basis_vars, w);
        const basis = try rel.project(basis_vars.items, true);

        var rows: std.ArrayList([]const Cell) = .empty;
        if (!query.hasAggregates()) {
            const find_vars = try self.arena.alloc(Var, query.find.len);
            for (query.find, find_vars) |f, *v| v.* = f.variable_of();
            const tuples = try basis.project(find_vars, query.with.len > 0);
            var i: usize = 0;
            while (i < tuples.rows) : (i += 1) {
                const row = try self.arena.alloc(Cell, find_vars.len);
                tuples.rowInto(i, row);
                try rows.append(self.arena, row);
            }
            return rows.toOwnedSlice(self.arena);
        }

        // Group by the plain find variables (a pull expression groups
        // by its entity), in first-seen order.
        var group_vars: std.ArrayList(Var) = .empty;
        for (query.find) |f| if (f != .agg) try ir.addVar(self.arena, &group_vars, f.variable_of());
        const keys = try basis.project(group_vars.items, false);
        var groups: std.ArrayList(std.ArrayList(usize)) = .empty;
        var index: std.AutoHashMapUnmanaged(u64, std.ArrayList(usize)) = .empty;
        var i: usize = 0;
        while (i < keys.rows) : (i += 1) {
            const h = keys.rowHash(i);
            const gop = try index.getOrPut(self.arena, h);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            var found: ?usize = null;
            for (gop.value_ptr.items) |g| {
                if (keys.rowsEql(groups.items[g].items[0], &keys, i)) {
                    found = g;
                    break;
                }
            }
            const g = found orelse blk: {
                try groups.append(self.arena, .empty);
                try gop.value_ptr.append(self.arena, groups.items.len - 1);
                break :blk groups.items.len - 1;
            };
            try groups.items[g].append(self.arena, i);
        }

        for (groups.items) |members| {
            const row = try self.arena.alloc(Cell, query.find.len);
            for (query.find, row) |f, *cell| {
                cell.* = switch (f) {
                    .variable, .pull => basis.get(members.items[0], f.variable_of()).?,
                    .agg => |a| try self.aggregate(a, &basis, basis.colOf(a.arg).?, members.items),
                };
            }
            try rows.append(self.arena, row);
        }
        return rows.toOwnedSlice(self.arena);
    }

    /// One aggregate over the group's `members` of `col`. `median` of
    /// an even count is the mean of the two middle values as a double;
    /// `variance` divides by the count (population variance) and
    /// `stddev` is its square root; `(min n ?x)` and `(max n ?x)` are
    /// the n smallest or largest values in order, `(sample n ?x)` up to
    /// n distinct values and `(rand n ?x)` n values with repetition,
    /// each a vector; a custom aggregate receives the vector of values.
    fn aggregate(self: *Exec, agg: ir.Agg, basis: *const Relation, col: usize, members: []const usize) anyerror!Cell {
        const op = agg.op;
        switch (op) {
            .count => return .{ .int = @intCast(members.len) },
            .count_distinct, .distinct, .sample => {
                var seen = try Relation.init(self.arena, &.{0});
                for (members) |m| try seen.append(&.{basis.cell(m, col)});
                const d = try seen.dedup();
                if (op == .count_distinct) return .{ .int = @intCast(d.rows) };
                if (op == .sample) {
                    const cells = try self.arena.alloc(Cell, d.rows);
                    for (cells, 0..) |*c, i| c.* = d.cell(i, 0);
                    self.random().shuffle(Cell, cells);
                    return self.cellVector(cells[0..@min(cells.len, agg.n.?)]);
                }
                var set = try champ.setEmpty(self.heap);
                var i: usize = 0;
                while (i < d.rows) : (i += 1) set = try champ.setConj(self.heap, set, try self.cellValue(d.cell(i, 0)), &dispatch.hashValue, &dispatch.equal);
                return .{ .vm = try self.kept(set) };
            },
            .rand => {
                const n = agg.n.?;
                const cells = try self.arena.alloc(Cell, if (members.len == 0) 0 else n);
                for (cells) |*c| c.* = basis.cell(members[self.random().uintLessThan(usize, members.len)], col);
                return self.cellVector(cells);
            },
            .min, .max => {
                if (agg.n) |n| {
                    const cells = try self.arena.alloc(Cell, members.len);
                    for (members, cells) |m, *c| c.* = basis.cell(m, col);
                    std.mem.sort(Cell, cells, CellOrder{ .names = self.interner, .descending = op == .max }, CellOrder.less);
                    return self.cellVector(cells[0..@min(cells.len, n)]);
                }
                var best: ?Cell = null;
                for (members) |m| {
                    const c = basis.cell(m, col);
                    if (best == null) {
                        best = c;
                        continue;
                    }
                    const o = c.orderBy(best.?, self.interner);
                    if ((op == .min and o == .lt) or (op == .max and o == .gt)) best = c;
                }
                return best orelse .nil;
            },
            .median => {
                const cells = try self.arena.alloc(Cell, members.len);
                for (members, cells) |m, *c| c.* = basis.cell(m, col);
                std.mem.sort(Cell, cells, CellOrder{ .names = self.interner, .descending = false }, CellOrder.less);
                if (cells.len == 0) return .nil;
                if (cells.len % 2 == 1) return cells[cells.len / 2];
                const lo = try numberOf(cells[cells.len / 2 - 1]);
                const hi = try numberOf(cells[cells.len / 2]);
                return .{ .double = (lo + hi) / 2 };
            },
            .variance, .stddev => {
                if (members.len == 0) return .nil;
                var mean: f64 = 0;
                for (members) |m| mean += try numberOf(basis.cell(m, col));
                mean /= @floatFromInt(members.len);
                var acc: f64 = 0;
                for (members) |m| {
                    const d = (try numberOf(basis.cell(m, col))) - mean;
                    acc += d * d;
                }
                const variance = acc / @as(f64, @floatFromInt(members.len));
                return .{ .double = if (op == .variance) variance else @sqrt(variance) };
            },
            .custom => {
                const hook = self.hook orelse return error.NoHook;
                const vals = try self.arena.alloc(Value, members.len);
                for (members, vals) |m, *v| v.* = try self.cellValue(basis.cell(m, col));
                const result = try hook.call(hook.ctx, agg.sym, &.{try vector_mod.fromSlice(self.heap, vals)});
                return Cell.fromValue(result);
            },
            .sum, .avg => {
                var isum: i128 = 0;
                var fsum: f64 = 0;
                var is_float = false;
                for (members) |m| switch (basis.cell(m, col)) {
                    .int => |n| isum += n,
                    .double => |d| {
                        is_float = true;
                        fsum += d;
                    },
                    else => return error.ValueType,
                };
                if (op == .sum) {
                    if (is_float) return .{ .double = fsum + @as(f64, @floatFromInt(isum)) };
                    if (std.math.cast(i64, isum)) |n| return .{ .int = n };
                    return .{ .vm = try self.kept(try bignum.fromI128(self.heap, isum)) };
                }
                const total = fsum + @as(f64, @floatFromInt(isum));
                return .{ .double = total / @as(f64, @floatFromInt(members.len)) };
            },
        }
    }

    const CellOrder = struct {
        names: *const Interner,
        descending: bool,

        fn less(self: CellOrder, a: Cell, b: Cell) bool {
            const o = a.orderBy(b, self.names);
            return if (self.descending) o == .gt else o == .lt;
        }
    };

    /// A numeric cell as a double; anything else is `ValueType`.
    fn numberOf(c: Cell) error{ValueType}!f64 {
        return switch (c) {
            .int => |n| @floatFromInt(n),
            .double => |d| d,
            else => error.ValueType,
        };
    }

    fn cellVector(self: *Exec, cells: []const Cell) !Cell {
        return .{ .vm = try self.keptVector(cells) };
    }

    /// The query's random source, seeded once per query from the clock.
    fn random(self: *Exec) std.Random {
        if (self.prng == null) {
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(.MONOTONIC, &ts);
            const seed = (@as(u64, @intCast(ts.sec)) *% 1_000_000_007) ^ @as(u64, @intCast(ts.nsec)) ^ @intFromPtr(self);
            self.prng = std.Random.DefaultPrng.init(seed);
        }
        return self.prng.?.random();
    }

    /// Copy `rows` into the VM heap as the find spec asks: a set of
    /// vectors (a vector of maps under `:keys`, `:strs` or `:syms`), a
    /// vector of values, one value, or one vector. Pull expressions are
    /// applied here, in the query's own snapshot.
    pub fn materialise(self: *Exec, query: *const Ir, rows_in: []const []const Cell) anyerror!Value {
        const rows = try self.pullColumns(query, rows_in);
        if (query.keys) |keys| return self.rowMaps(keys, rows);
        switch (query.find_spec) {
            .relation => {
                var set = try champ.setEmpty(self.heap);
                for (rows) |row| set = try champ.setConj(self.heap, set, try self.rowVector(row), &dispatch.hashValue, &dispatch.equal);
                return set;
            },
            .collection => {
                const vals = try self.arena.alloc(Value, rows.len);
                for (rows, vals) |row, *v| v.* = try self.cellValue(row[0]);
                return vector_mod.fromSlice(self.heap, vals);
            },
            .scalar => {
                if (rows.len == 0) return value.nilValue();
                return self.cellValue(rows[0][0]);
            },
            .tuple => {
                if (rows.len == 0) return value.nilValue();
                return self.rowVector(rows[0]);
            },
        }
    }

    fn rowVector(self: *Exec, row: []const Cell) !Value {
        const vals = try self.arena.alloc(Value, row.len);
        for (row, vals) |c, *v| v.* = try self.cellValue(c);
        return vector_mod.fromSlice(self.heap, vals);
    }

    /// `rows` with every `(pull ?e pattern)` column replaced by the
    /// pattern's map for the row's entity (nil for an entity with no
    /// datoms); a cell that is not an entity id is `ValueType`. Each
    /// pattern is resolved once; a syntax error leaves its reason in
    /// the diagnostic.
    fn pullColumns(self: *Exec, query: *const Ir, rows: []const []const Cell) anyerror![]const []const Cell {
        var any = false;
        for (query.find) |f| if (f == .pull) {
            any = true;
        };
        if (!any) return rows;
        var scratch: Diag = .{};
        const diag = self.diag orelse &scratch;
        const prepared = try self.arena.alloc(?pull_mod.Prepared, query.find.len);
        for (query.find, prepared) |f, *p| {
            if (f != .pull) {
                p.* = null;
                continue;
            }
            const pattern = switch (f.pull.pattern) {
                .value => |v| v,
                .input => |v| inputOf(query, self.args, v),
            };
            p.* = try pull_mod.Prepared.prepare(self.arena, try self.readOf(f.pull.src), self.heap, self.interner, pattern, diag);
        }
        const out = try self.arena.alloc([]const Cell, rows.len);
        for (rows, out) |row, *o| {
            const cells = try self.arena.dupe(Cell, row);
            for (prepared, cells) |*p, *c| {
                const pr = &(p.* orelse continue);
                const e = c.asEid() orelse return error.ValueType;
                c.* = .{ .vm = try pr.eid(e) };
            }
            o.* = cells;
        }
        return out;
    }

    /// The value of the scalar `:in` input that binds `v`.
    fn inputOf(query: *const Ir, args: []const Value, v: Var) Value {
        for (query.in, args) |b, a| if (b == .scalar and b.scalar == v) return a;
        unreachable;
    }

    /// The rows as a vector of maps, one key per find element.
    fn rowMaps(self: *Exec, keys: ir.Keys, rows: []const []const Cell) anyerror!Value {
        const names = try self.arena.alloc(Value, keys.names.len);
        for (keys.names, names) |sym, *n| {
            const text = self.interner.symbolName(sym);
            n.* = switch (keys.kind) {
                .keyword => try self.interner.internKeywordValue(text),
                .string => try string_mod.fromBytes(self.heap, text),
                .symbol => value.fromSymbolId(sym),
            };
        }
        const maps = try self.arena.alloc(Value, rows.len);
        for (rows, maps) |row, *m| {
            var map = try champ.mapEmpty(self.heap);
            for (names, row) |k, c| map = try champ.mapAssoc(self.heap, map, k, try self.cellValue(c), &dispatch.hashValue, &dispatch.equal);
            m.* = map;
        }
        return vector_mod.fromSlice(self.heap, maps);
    }
};
