//! query/exec.zig — running a plan over one `Read` (NEXTOMIC.md §5
//! "Execute").
//!
//! Invariants:
//!   - One `Read` (one emdb snapshot) serves every scan of a query; the
//!     caller opens it before planning and closes it after the result
//!     is materialised, on success or error.
//!   - A scan seeks by the constants and bound variables that lead its
//!     index and post-filters everything else; `tx` binds the
//!     transaction entity id and `added` the datom's flag. The mode of
//!     the db-value is inside the `Read`, so scans see folded datoms.
//!   - Per scan the join is an index nested loop (one seek per input
//!     row) when `rows × log2(tree entries)` is below the estimate of
//!     the single constant-prefix scan, else that one scan hash-joined
//!     on the shared variables.
//!   - Built-in predicates and functions are Zig over cells; any other
//!     symbol goes to the `CallHook` with VM values and its errors
//!     propagate untouched (the caller closes the `Read` on the way
//!     out).
//!   - A function result of nil drops the row; collection and relation
//!     bindings fan out one row per element.
//!   - `finish` forms the basis set (distinct tuples over the find and
//!     `:with` variables), groups and aggregates it, and copies the
//!     result into the VM heap as the find spec asks.

const std = @import("std");
const value = @import("value");
const heap_mod = @import("heap");
const intern_mod = @import("intern");
const string_mod = @import("string");
const list_mod = @import("list");
const vector_mod = @import("vector");
const champ = @import("champ");
const dispatch = @import("dispatch");
const key = @import("../key.zig");
const datom_mod = @import("../datom.zig");
const db_mod = @import("../db.zig");
const relation = @import("../relation.zig");
const ir = @import("ir.zig");
const plan_mod = @import("plan.zig");
const rules_mod = @import("rules.zig");

const Allocator = std.mem.Allocator;
const Value = value.Value;
const Heap = heap_mod.Heap;
const Interner = intern_mod.Interner;
const Read = db_mod.Read;
const Var = ir.Var;
const Cell = ir.Cell;
const Relation = relation.Relation;
const Plan = plan_mod.Plan;
const Step = plan_mod.Step;
const Scan = plan_mod.Scan;

/// Calls a user function by VM symbol. `args` are VM values built in
/// the query's result heap; the result must be a VM value.
pub const CallHook = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, sym: u32, args: []const Value) anyerror!Value,
};

pub const Exec = struct {
    arena: Allocator,
    read: *Read,
    heap: *Heap,
    interner: *Interner,
    hook: ?CallHook,

    /// Run `p` from `input`, which binds at least `p.input`.
    pub fn runPlan(self: *Exec, p: *const Plan, input: Relation) anyerror!Relation {
        var rel = input;
        for (p.steps) |*s| rel = try self.step(s, rel);
        return rel;
    }

    fn step(self: *Exec, s: *const Step, rel: Relation) anyerror!Relation {
        return switch (s.*) {
            .scan => |*sc| self.execScan(sc, rel),
            .pred => |*p| self.execPred(p, rel),
            .bind => |*b| self.execBind(b, rel),
            .not => |*n| self.execNot(n, rel),
            .@"or" => |*o| self.execOr(o, rel),
            .source => |*src| self.execSource(src, rel),
            .fix => |*f| rules_mod.execFix(self, f, rel),
        };
    }

    // ── datoms to cells ───────────────────────────────────────────

    /// The cell of a datom value: ids as `int`, keywords as VM keyword
    /// ids, uuids as text.
    pub fn valCell(self: *Exec, v: key.Val) !Cell {
        return switch (v) {
            .boolean => |b| .{ .boolean = b },
            .long, .instant => |n| .{ .int = n },
            .double => |d| .{ .double = d },
            .keyword => |id| .{ .keyword = (try self.read.db.conn.idents.internOf(self.read.txn, id)) orelse return error.Corrupted },
            .ref => |e| .{ .int = @intCast(e) },
            .string, .bytes => |s| .{ .str = s },
            .uuid => |u| blk: {
                const text = try self.arena.alloc(u8, 36);
                datom_mod.uuidToText(text[0..36], u);
                break :blk .{ .str = text };
            },
        };
    }

    fn datomCells(self: *Exec, d: datom_mod.Datom) ![5]Cell {
        return .{
            .{ .int = @intCast(d.e) },
            .{ .int = d.a },
            try self.valCell(d.v),
            .{ .int = @intCast(key.txEntity(d.t)) },
            .{ .boolean = d.added },
        };
    }

    // ── cells to values ───────────────────────────────────────────

    pub fn cellValue(self: *Exec, c: Cell) !Value {
        return switch (c) {
            .nil => value.nilValue(),
            .int => |n| value.fromFixnum(n) orelse error.ValueType,
            .double => |d| value.fromFloat(d),
            .boolean => |b| value.fromBool(b),
            .keyword => |k| value.fromKeywordId(k),
            .str => |s| try string_mod.fromBytes(self.heap, s),
            .vm => |v| v,
        };
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

        const log_n: u64 = std.math.log2_int_ceil(u64, s.tree_entries + 2);
        const nested = s.hash_index == null or (std.math.mulWide(u64, rel.rows, log_n) < s.hash_estimate);
        const slots = s.slots();

        if (nested) {
            const srcs = try self.arena.alloc(Src, out_vars.len);
            for (out_vars, srcs) |v, *src| src.* = if (rel.colOf(v)) |c| .{ .row = c } else .{ .pos = slotPos(slots, v) };
            const row = try self.arena.alloc(Cell, rel.cols.len);
            var i: usize = 0;
            while (i < rel.rows) : (i += 1) {
                rel.rowInto(i, row);
                try self.scanInto(s, s.index, &rel, row, srcs, &out);
            }
        } else {
            var pvars: std.ArrayList(Var) = .empty;
            for (slots) |slot| switch (slot) {
                .bound, .fresh => |v| try ir.addVar(self.arena, &pvars, v),
                else => {},
            };
            var scanned = try Relation.init(self.arena, pvars.items);
            const srcs = try self.arena.alloc(Src, pvars.items.len);
            for (pvars.items, srcs) |v, *src| src.* = .{ .pos = slotPos(slots, v) };
            try self.scanInto(s, s.hash_index.?, null, &.{}, srcs, &scanned);
            out = try rel.hashJoin(&scanned);
        }
        return if (s.dedup) out.dedup() else out;
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

    /// Scan `index` for the datoms of `s` given one input row (or none),
    /// appending the passing rows to `out` through `srcs`.
    fn scanInto(self: *Exec, s: *const Scan, index: key.Index, rel: ?*const Relation, row: []const Cell, srcs: []const Src, out: *Relation) anyerror!void {
        const slots = s.slots();
        var comps: key.Components = .{};

        if (slotCell(slots[0], rel, row)) |c| comps.e = c.asEid() orelse return;

        var attr = s.attr;
        if (slotCell(slots[1], rel, row)) |c| {
            const n = c.asInt() orelse return;
            if (n <= 0 or n >= key.attr_partition_end) return;
            comps.a = @intCast(n);
            if (attr == null) attr = (try self.read.attr(comps.a.?)) orelse return;
        }

        if (slotCell(slots[2], rel, row)) |c| {
            if (slots[2] == .constant and slots[2].constant.bytes != null) {
                comps.v = slots[2].constant.bytes;
            } else if (attr) |at| {
                const val = (try plan_mod.encodeCell(self.read, c, at.value_type)) orelse return;
                comps.v = key.valBytes(self.arena, val) catch |err| switch (err) {
                    error.ValueType => return,
                    else => return err,
                };
            } else if (index == .vaet) {
                const eid = c.asEid() orelse return;
                comps.v = try key.valBytes(self.arena, .{ .ref = eid });
            }
        }

        var it = try self.read.scan(self.arena, index, comps);
        const cells = try self.arena.alloc(Cell, out.cols.len);
        datoms: while (try it.next()) |d| {
            const dc = try self.datomCells(d);
            for (slots, 0..) |slot, pos| {
                switch (slot) {
                    .blank, .fresh => {},
                    .constant, .bound => if (slotCell(slot, rel, row)) |want| {
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
        const hook = self.hook orelse return error.QuerySyntax;
        const args = try self.arena.alloc(Value, cells.len);
        for (cells, args) |c, *a| a.* = try self.cellValue(c);
        return hook.call(hook.ctx, sym, args);
    }

    fn execPred(self: *Exec, p: *const plan_mod.Pred, rel: Relation) anyerror!Relation {
        var out = try Relation.init(self.arena, rel.vars);
        const map = try out.mapFrom(&rel);
        var i: usize = 0;
        while (i < rel.rows) : (i += 1) {
            const cells = try self.argCells(&rel, i, p.call.args);
            const keep = switch (p.call.f) {
                .builtin => |b| try self.builtinPred(b, cells),
                .user => |sym| (try self.callUser(sym, cells)).isTruthy(),
            };
            if (keep) try out.appendFrom(&rel, i, map);
        }
        return out;
    }

    fn builtinPred(self: *Exec, b: ir.Builtin, args: []const Cell) anyerror!bool {
        switch (b) {
            .lt, .le, .gt, .ge => {
                if (args.len < 2) return error.QuerySyntax;
                for (args[0 .. args.len - 1], args[1..]) |x, y| {
                    const o = x.order(y);
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
                if (args.len < 2) return error.QuerySyntax;
                for (args[1..]) |y| if (!args[0].eql(y)) return false;
                return true;
            },
            .ne => {
                if (args.len < 2) return error.QuerySyntax;
                for (args[1..]) |y| if (!args[0].eql(y)) return true;
                return false;
            },
            .missing => {
                if (args.len != 3) return error.QuerySyntax;
                return (try self.firstValue(args[1], args[2])) == null;
            },
            .ground, .get_else, .tuple, .untuple => return error.QuerySyntax,
        }
    }

    /// The first current value of attribute `attr` (a keyword cell) on
    /// entity `e`, or null.
    fn firstValue(self: *Exec, e: Cell, attr: Cell) anyerror!?Cell {
        const eid = e.asEid() orelse return null;
        if (attr != .keyword) return error.QuerySyntax;
        const a = (try self.read.db.conn.idents.idOf(self.read.txn, attr.keyword)) orelse return null;
        var it = try self.read.scan(self.arena, .eavt, .{ .e = eid, .a = a });
        const d = (try it.next()) orelse return null;
        return try self.valCell(d.v);
    }

    fn execBind(self: *Exec, b: *const plan_mod.Bind, rel: Relation) anyerror!Relation {
        const out_vars = try std.mem.concat(self.arena, Var, &.{ rel.vars, b.fresh });
        var out = try Relation.init(self.arena, out_vars);
        const row = try self.arena.alloc(Cell, out_vars.len);
        var i: usize = 0;
        while (i < rel.rows) : (i += 1) {
            const cells = try self.argCells(&rel, i, b.call.args);
            const result: Value = switch (b.call.f) {
                .builtin => |bi| switch (bi) {
                    .ground, .untuple => blk: {
                        if (cells.len != 1) return error.QuerySyntax;
                        break :blk try self.cellValue(cells[0]);
                    },
                    .get_else => blk: {
                        if (cells.len != 4) return error.QuerySyntax;
                        const found = try self.firstValue(cells[1], cells[2]);
                        break :blk try self.cellValue(found orelse cells[3]);
                    },
                    .tuple => blk: {
                        const vals = try self.arena.alloc(Value, cells.len);
                        for (cells, vals) |c, *v| v.* = try self.cellValue(c);
                        break :blk try vector_mod.fromSlice(self.heap, vals);
                    },
                    else => return error.QuerySyntax,
                },
                .user => |sym| try self.callUser(sym, cells),
            };
            rel.rowInto(i, row[0..rel.cols.len]);
            try self.bindValue(b, result, row, rel.cols.len, &out);
        }
        return switch (b.out) {
            .collection, .relation => out.dedup(),
            else => out,
        };
    }

    /// Append the rows `result` binds under `b.out`; `row[0..base]`
    /// holds the input row and the rest is filled here.
    fn bindValue(self: *Exec, b: *const plan_mod.Bind, result: Value, row: []Cell, base: usize, out: *Relation) anyerror!void {
        switch (b.out) {
            .scalar => {
                if (result.isNil()) return;
                row[base] = Cell.fromValue(result);
                try out.append(row);
            },
            .collection => {
                const items = (try self.seqElems(result)) orelse return error.QuerySyntax;
                for (items) |x| {
                    row[base] = Cell.fromValue(x);
                    try out.append(row);
                }
            },
            .tuple => |ts| {
                if (result.isNil()) return;
                try self.fillTuple(ts, result, row, base);
                try out.append(row);
            },
            .relation => |ts| {
                const items = (try self.seqElems(result)) orelse return error.QuerySyntax;
                for (items) |x| {
                    try self.fillTuple(ts, x, row, base);
                    try out.append(row);
                }
            },
        }
    }

    fn fillTuple(self: *Exec, ts: []const ?Var, v: Value, row: []Cell, base: usize) anyerror!void {
        const items = (try self.seqElems(v)) orelse return error.QuerySyntax;
        if (items.len < ts.len) return error.QuerySyntax;
        var k: usize = base;
        for (ts, items[0..ts.len]) |t, x| {
            if (t == null) continue;
            row[k] = Cell.fromValue(x);
            k += 1;
        }
    }

    /// The elements of a vector, list or set value, or null.
    pub fn seqElems(self: *Exec, v: Value) !?[]Value {
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
            .persistent_set => {
                var it = champ.setIter(v);
                while (it.next()) |x| try out.append(self.arena, x);
            },
            else => return null,
        }
        return try out.toOwnedSlice(self.arena);
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
        const slot = src.slot.rel orelse return error.QuerySyntax;
        var distinct: std.ArrayList(Var) = .empty;
        for (src.vars) |v| try ir.addVar(self.arena, &distinct, v);
        var view: Relation = undefined;
        if (distinct.items.len == src.vars.len) {
            view = .{ .arena = self.arena, .vars = src.vars, .cols = slot.cols, .rows = slot.rows };
        } else {
            view = try Relation.init(self.arena, distinct.items);
            const cells = try self.arena.alloc(Cell, distinct.items.len);
            var i: usize = 0;
            rows: while (i < slot.rows) : (i += 1) {
                for (src.vars, 0..) |v, pos| {
                    const d = std.mem.indexOfScalar(Var, distinct.items, v).?;
                    const c = slot.cell(i, pos);
                    if (std.mem.indexOfScalar(Var, src.vars, v).? == pos) {
                        cells[d] = c;
                    } else if (!cells[d].eql(c)) continue :rows;
                }
                try view.append(cells);
            }
        }
        return rel.hashJoin(&view);
    }

    // ── inputs ────────────────────────────────────────────────────

    /// The relation the `:in` bindings describe over `args`, which are
    /// positional with `in` (the `$` and `%` positions are ignored).
    pub fn inputRelation(self: *Exec, in: []const ir.InBinding, args: []const Value) anyerror!Relation {
        if (args.len != in.len) return error.QuerySyntax;
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
                    for ((try self.seqElems(a)) orelse return error.QuerySyntax) |x| try r.append(&.{Cell.fromValue(x)});
                    break :blk try r.dedup();
                },
                .tuple => |ts| blk: {
                    var r = try Relation.init(self.arena, try tupleVars(self.arena, ts));
                    const row = try self.arena.alloc(Cell, r.vars.len);
                    try self.fillTuple(ts, a, row, 0);
                    try r.append(row);
                    break :blk r;
                },
                .relation => |ts| blk: {
                    var r = try Relation.init(self.arena, try tupleVars(self.arena, ts));
                    const row = try self.arena.alloc(Cell, r.vars.len);
                    for ((try self.seqElems(a)) orelse return error.QuerySyntax) |x| {
                        try self.fillTuple(ts, x, row, 0);
                        try r.append(row);
                    }
                    break :blk try r.dedup();
                },
            };
            rel = try rel.hashJoin(&part);
        }
        return rel;
    }

    fn tupleVars(arena: Allocator, ts: []const ?Var) ![]Var {
        var out: std.ArrayList(Var) = .empty;
        for (ts) |t| if (t) |v| try out.append(arena, v);
        return out.toOwnedSlice(arena);
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
            for (query.find, find_vars) |f, *v| v.* = f.variable;
            const tuples = try basis.project(find_vars, query.with.len > 0);
            var i: usize = 0;
            while (i < tuples.rows) : (i += 1) {
                const row = try self.arena.alloc(Cell, find_vars.len);
                tuples.rowInto(i, row);
                try rows.append(self.arena, row);
            }
            return rows.toOwnedSlice(self.arena);
        }

        // Group by the plain find variables, in first-seen order.
        var group_vars: std.ArrayList(Var) = .empty;
        for (query.find) |f| if (f == .variable) try ir.addVar(self.arena, &group_vars, f.variable);
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
                    .variable => |v| basis.get(members.items[0], v).?,
                    .agg => |a| try self.aggregate(a.op, &basis, basis.colOf(a.arg).?, members.items),
                };
            }
            try rows.append(self.arena, row);
        }
        return rows.toOwnedSlice(self.arena);
    }

    fn aggregate(self: *Exec, op: ir.AggOp, basis: *const Relation, col: usize, members: []const usize) anyerror!Cell {
        switch (op) {
            .count => return .{ .int = @intCast(members.len) },
            .count_distinct, .distinct => {
                var seen = try Relation.init(self.arena, &.{0});
                for (members) |m| try seen.append(&.{basis.cell(m, col)});
                const d = try seen.dedup();
                if (op == .count_distinct) return .{ .int = @intCast(d.rows) };
                var set = try champ.setEmpty(self.heap);
                var i: usize = 0;
                while (i < d.rows) : (i += 1) set = try champ.setConj(self.heap, set, try self.cellValue(d.cell(i, 0)), &dispatch.hashValue, &dispatch.equal);
                return .{ .vm = set };
            },
            .min, .max => {
                var best: ?Cell = null;
                for (members) |m| {
                    const c = basis.cell(m, col);
                    if (best == null) {
                        best = c;
                        continue;
                    }
                    const o = c.order(best.?);
                    if ((op == .min and o == .lt) or (op == .max and o == .gt)) best = c;
                }
                return best orelse .nil;
            },
            .sum, .avg => {
                var isum: i64 = 0;
                var fsum: f64 = 0;
                var is_float = false;
                for (members) |m| switch (basis.cell(m, col)) {
                    .int => |n| isum = std.math.add(i64, isum, n) catch return error.ValueType,
                    .double => |d| {
                        is_float = true;
                        fsum += d;
                    },
                    else => return error.ValueType,
                };
                if (op == .sum) {
                    if (is_float) return .{ .double = fsum + @as(f64, @floatFromInt(isum)) };
                    return .{ .int = isum };
                }
                const total = fsum + @as(f64, @floatFromInt(isum));
                return .{ .double = total / @as(f64, @floatFromInt(members.len)) };
            },
        }
    }

    /// Copy `rows` into the VM heap as `spec` asks: a set of vectors, a
    /// vector of values, one value, or one vector.
    pub fn materialise(self: *Exec, spec: ir.FindSpec, rows: []const []const Cell) anyerror!Value {
        switch (spec) {
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
};
