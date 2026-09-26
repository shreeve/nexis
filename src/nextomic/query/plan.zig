//! query/plan.zig — greedy selectivity ordering (NEXTOMIC.md §5 "Plan").
//!
//! A `Plan` is the ordered list of steps that `query/exec.zig` runs over
//! one `Read`. Planning resolves the pure `Ir` against that `Read`:
//! keyword attributes become attribute ids, idents and lookup refs in
//! entity positions become entity ids, and constants in value positions
//! are pre-encoded to their sortable bytes when the attribute's type is
//! known. Invariants:
//!   - Steps are ordered greedily: cost-free steps (predicates, function
//!     bindings, `not`, filtering `or`) run as soon as their variables
//!     are bound; among sources (patterns, `or`, rule calls) the one with
//!     the smallest estimate given the variables bound so far runs next.
//!   - A data pattern with nothing bound in `e`, `a` or `v` is refused
//!     with `error.UnboundPattern`; a predicate or function whose inputs
//!     (its arguments, and its function when that is a variable) can
//!     never be bound is `error.QuerySyntax`.
//!   - Index choice follows the §5 table from what is bound when the
//!     pattern runs; estimates come from `Schema` attribute counts.
//!   - A constant that cannot exist in the store (an unknown ident, a
//!     lookup ref with no entity, a value of the wrong type for the
//!     attribute) marks its scan `unsatisfiable`: it yields nothing and
//!     is not an error.
//!   - Sub-plans (`not`, `or`, rule bodies) are planned with their join
//!     variables bound and start from a relation over those variables.
//!   - Every source has its own `Read`; a pattern is resolved and
//!     estimated against the source it names (`$` when it names none),
//!     and the scan step records that source.
//!   - Plan variables extend the IR's table; renamed rule variables are
//!     appended and never alias a query variable.
//!   - Everything a plan allocates lives in the query arena.

const std = @import("std");
const value = @import("../../value.zig");
const intern_mod = @import("../../intern.zig");
const key = @import("../key.zig");
const datom_mod = @import("../datom.zig");
const schema_mod = @import("../schema.zig");
const db_mod = @import("../db.zig");
const store_mod = @import("../store.zig");
const marshal = @import("../marshal.zig");
const relation = @import("../relation.zig");
const stack = @import("../../stack.zig");
const ir = @import("ir.zig");
const rules_mod = @import("rules.zig");
const parse_mod = @import("parse.zig");
const exec_mod = @import("exec.zig");

const Allocator = std.mem.Allocator;
const Value = value.Value;
const Interner = intern_mod.Interner;
const Read = db_mod.Read;
const Attr = schema_mod.Attr;
const Var = ir.Var;
const Cell = ir.Cell;
const Clause = ir.Clause;
const Ir = ir.Ir;
const RuleSet = ir.RuleSet;
const Relation = relation.Relation;
pub const Diag = parse_mod.Diag;

pub const Error = error{
    QuerySyntax,
    UnboundPattern,
    UnknownAttribute,
    OutOfMemory,
};

/// Everything planning can fail with: the planner's own errors and
/// the store's, through the attribute and constant lookups.
pub const Failure = Error || stack.Error || marshal.Error || db_mod.ErrorsOf(marshal.cellOf) || db_mod.ErrorsOf(Interner.internSymbol) || db_mod.ErrorsOf(store_mod.Store.treeEntries);

// =============================================================================
// Steps
// =============================================================================

/// A resolved constant: the cell in the VM's terms (entity ids as
/// `int`, keyword values as VM keyword ids) and, for a value position
/// under an attribute of known type, its sortable encoding.
pub const Const = struct {
    cell: Cell,
    bytes: ?[]const u8 = null,
    /// The VM keyword the constant was written as (an attribute or an
    /// ident), for `explain`.
    name: ?u32 = null,
};

/// A data-pattern position at plan time.
pub const Slot = union(enum) {
    blank,
    /// A variable bound before this step: seeks (in the prefix) or
    /// filters (after a gap) by the row's value.
    bound: Var,
    /// A variable this step binds.
    fresh: Var,
    /// A repeat of a `fresh` variable earlier in the same pattern: the
    /// datom must carry the same value in both positions.
    same: Var,
    constant: Const,
};

pub const Scan = struct {
    /// The data source the scan reads.
    src: ir.Src,
    e: Slot,
    a: Slot,
    v: Slot,
    tx: Slot,
    added: Slot,
    index: key.Index,
    /// The attribute when `a` is a constant.
    attr: ?Attr,
    estimate: u64,
    /// Index and estimate of the one scan over the constant prefix
    /// that a hash join would make; null when the pattern has no
    /// constant to seek by, which forces the nested loop.
    hash_index: ?key.Index,
    hash_estimate: u64,
    /// Entries of the index tree, for the join rule.
    tree_entries: u64,
    /// Rows may repeat (a `_` position); the output is deduplicated.
    dedup: bool,
    /// Variables this scan binds, in position order.
    fresh: []const Var,
    /// A constant that no datom can match.
    unsatisfiable: bool,

    pub fn slots(self: *const Scan) [5]Slot {
        return .{ self.e, self.a, self.v, self.tx, self.added };
    }
};

/// A data pattern over a collection source: its tuples filtered and
/// joined by position, with no index and no resolution (constants are
/// compared as written).
pub const Match = struct {
    src: ir.Src,
    slots: [5]Slot,
    fresh: []const Var,
    rows: []const []const Cell,
};

pub const Pred = struct {
    call: ir.Call,
};

pub const Bind = struct {
    call: ir.Call,
    out: ir.Binding,
    fresh: []const Var,
};

pub const Not = struct {
    join: []const Var,
    sub: *Plan,
};

pub const Or = struct {
    join: []const Var,
    /// Join variables bound before this step.
    bound: []const Var,
    /// Join variables this step binds.
    fresh: []const Var,
    branches: []const *Plan,
};

/// A join with a relation supplied at run time (rule iterations).
pub const Source = struct {
    slot: *SourceSlot,
    /// The plan variables the slot's columns bind, positionally; a
    /// repeated variable requires equal values.
    vars: []const Var,
    fresh: []const Var,
};

pub const SourceSlot = struct {
    rel: ?*const Relation = null,
};

pub const Step = union(enum) {
    scan: Scan,
    match: Match,
    pred: Pred,
    bind: Bind,
    not: Not,
    @"or": Or,
    source: Source,
    fix: rules_mod.Fix,
};

// =============================================================================
// Plan
// =============================================================================

pub const Plan = struct {
    /// The variables this plan starts with (bound by its input relation).
    input: []const Var,
    steps: []const Step,
    /// Estimated rows of the input relation.
    rows_in: u64,
    /// Estimated rows after each step, one per step.
    rows_after: []const u64,
    /// Estimated rows after the last step.
    rows_estimate: u64,

    /// Estimated rows before step `i`.
    pub fn rowsBefore(self: *const Plan, i: usize) u64 {
        return if (i == 0) self.rows_in else self.rows_after[i - 1];
    }
};

/// One data source at plan time: its `Read` and what has been
/// resolved against it, or the tuples of a collection.
pub const DbSource = struct {
    read: ?*Read,
    coll: ?[]const []const Cell = null,
    /// Attributes resolved so far, by VM keyword id.
    attr_cache: std.AutoHashMapUnmanaged(u32, ?Attr) = .empty,
    /// Entries of the AEVT tree this view reads, once asked.
    aevt_entries: ?u64 = null,
};

/// Everything planning needs about the query: the `Read` of every
/// source (`read` is the selected one), the variable table (shared by
/// every sub-plan) and the rule set.
pub const Ctx = struct {
    arena: Allocator,
    /// The selected source's `Read`; `select` switches it. Undefined
    /// while a collection is selected (`coll`).
    read: *Read,
    /// The selected source's tuples when it is a collection.
    coll: ?[]const []const Cell = null,
    interner: *Interner,
    vars: std.ArrayList(ir.VarInfo),
    rules: *const RuleSet,
    rule_info: ?*rules_mod.Info = null,
    /// The selected source's resolved attributes.
    attr_cache: std.AutoHashMapUnmanaged(u32, ?Attr) = .empty,
    /// The query's `Ir` table size; variables at or past it are renames.
    ir_vars: usize,
    /// Run-time relation slots, by `Clause.source.id`.
    sources: std.ArrayList(*SourceSlot) = .empty,
    /// The selected source's AEVT entries, once asked.
    aevt_entries: ?u64 = null,
    /// The data sources by `Src`; `$` first.
    dbs: []DbSource,
    /// VM symbol ids of the sources, for `explain`.
    source_names: []const u32,
    selected: ir.Src = 0,
    /// Nesting of `planSub` calls; 1 while placing the query's own
    /// clauses, whose index a refusal then reports.
    depth: usize = 0,
    clause_index: ?usize = null,
    /// Where a syntax or attribute error leaves its reason.
    diag: *Diag,

    /// `sources` has one entry per query source, `$` first.
    pub fn init(arena: Allocator, sources: []const exec_mod.Source, interner: *Interner, query: *const Ir, rules: *const RuleSet, diag: *Diag) !Ctx {
        std.debug.assert(sources.len == query.sources.len);
        var vars: std.ArrayList(ir.VarInfo) = .empty;
        try vars.appendSlice(arena, query.vars);
        const dbs = try arena.alloc(DbSource, sources.len);
        for (sources, dbs) |src, *d| d.* = switch (src) {
            .db => |r| .{ .read = r },
            .coll => |rows| .{ .read = null, .coll = rows },
        };
        var ctx: Ctx = .{ .arena = arena, .read = undefined, .interner = interner, .vars = vars, .rules = rules, .ir_vars = query.vars.len, .dbs = dbs, .source_names = query.sources, .diag = diag };
        if (dbs.len > 0) ctx.enter(0);
        return ctx;
    }

    /// Make `src` (null: `$`) the source the resolvers read; a query
    /// whose `:in` names no source has none to read.
    pub fn select(self: *Ctx, src: ?ir.Src) error{QuerySyntax}!void {
        if (self.dbs.len == 0) return self.syntax("this clause reads a data source, and :in names none");
        const next = src orelse 0;
        if (next == self.selected) return;
        self.dbs[self.selected].attr_cache = self.attr_cache;
        self.dbs[self.selected].aevt_entries = self.aevt_entries;
        self.enter(next);
    }

    fn enter(self: *Ctx, next: ir.Src) void {
        self.selected = next;
        self.read = self.dbs[next].read orelse undefined;
        self.coll = self.dbs[next].coll;
        self.attr_cache = self.dbs[next].attr_cache;
        self.aevt_entries = self.dbs[next].aevt_entries;
    }

    /// `select` for a clause that reads a db value: `missing?`,
    /// `get-else`, `get-some`, `fulltext`.
    pub fn selectDb(self: *Ctx, src: ?ir.Src) error{QuerySyntax}!void {
        try self.select(src);
        if (self.coll != null) return self.syntax("this clause reads a db value, and its source is a collection");
    }

    /// `QuerySyntax` with its reason and the top-level clause it was
    /// found in.
    pub fn syntax(self: *Ctx, message: []const u8) error{QuerySyntax} {
        self.diag.* = .{ .clause = self.clause_index, .message = message };
        return error.QuerySyntax;
    }

    /// `QuerySyntax` with a formatted reason naming what is wrong.
    pub fn syntaxFmt(self: *Ctx, comptime fmt: []const u8, args: anytype) error{QuerySyntax} {
        self.diag.set(self.clause_index, fmt, args);
        return error.QuerySyntax;
    }

    /// `UnknownAttribute` for the attribute the query wrote as `attr`.
    pub fn unknownAttr(self: *Ctx, attr: Value) error{UnknownAttribute} {
        self.diag.* = .{ .message = "unknown attribute", .attr = attr };
        return error.UnknownAttribute;
    }

    pub fn freshVar(self: *Ctx, sym: u32) !Var {
        const v: Var = @intCast(self.vars.items.len);
        try self.vars.append(self.arena, .{ .sym = sym });
        return v;
    }

    pub fn varName(self: *const Ctx, v: Var) []const u8 {
        return self.interner.symbolName(self.vars.items[v].sym);
    }

    /// The attribute named by VM keyword `kw` as this view sees it.
    pub fn attrByKeyword(self: *Ctx, kw: u32) !?Attr {
        if (self.attr_cache.get(kw)) |a| return a;
        const id = try self.read.db.conn.idents.idOf(self.read.txn, kw);
        const attr: ?Attr = if (id) |a| try self.read.attr(a) else null;
        try self.attr_cache.put(self.arena, kw, attr);
        return attr;
    }

    /// Entries of the AEVT tree this view reads: the cost of a scan
    /// over every datom.
    pub fn aevtEntries(self: *Ctx) !u64 {
        if (self.aevt_entries) |n| return n;
        const store = self.read.db.conn.store;
        const tree = if (self.read.fast()) store.trees.cur(.aevt) else store.trees.hist(.aevt);
        const n = try store_mod.Store.treeEntries(self.read.txn, tree);
        self.aevt_entries = n;
        return n;
    }

    /// Datoms per attribute, the AEVT estimate for an attribute known
    /// only at run time.
    pub fn entriesPerAttr(self: *Ctx) !u64 {
        const attrs = (try self.read.schema()).attrs.count();
        return @max(1, (try self.aevtEntries()) / @max(1, attrs));
    }

    pub fn ruleInfo(self: *Ctx) !*rules_mod.Info {
        if (self.rule_info) |i| return i;
        const info = try self.arena.create(rules_mod.Info);
        info.* = try rules_mod.analyze(self.arena, self.rules);
        self.rule_info = info;
        return info;
    }
};

/// Plan `query` for `read`. The returned plan starts from the relation
/// over the `:in` variables.
pub fn plan(ctx: *Ctx, query: *const Ir) Failure!*Plan {
    return planSub(ctx, query.where, query.in_vars, 1);
}

/// Plan `clauses` starting from a relation over `input`.
pub fn planSub(ctx: *Ctx, clauses: []const Clause, input: []const Var, rows_in: u64) Failure!*Plan {
    try stack.check();
    ctx.depth += 1;
    defer ctx.depth -= 1;
    const out = try ctx.arena.create(Plan);
    var bound: std.ArrayList(Var) = .empty;
    try bound.appendSlice(ctx.arena, input);
    var steps: std.ArrayList(Step) = .empty;
    var rows_after: std.ArrayList(u64) = .empty;
    var rows = rows_in;
    try planClauses(ctx, clauses, &bound, &steps, &rows_after, &rows);
    out.* = .{ .input = try ctx.arena.dupe(Var, input), .steps = try steps.toOwnedSlice(ctx.arena), .rows_in = rows_in, .rows_after = try rows_after.toOwnedSlice(ctx.arena), .rows_estimate = rows };
    return out;
}

/// Record `rows` as the estimate after every step placed since the
/// last note.
fn noteRows(ctx: *Ctx, rows_after: *std.ArrayList(u64), steps: usize, rows: u64) !void {
    while (rows_after.items.len < steps) try rows_after.append(ctx.arena, rows);
}

const Pending = struct {
    clause: Clause,
    done: bool = false,
};

fn planClauses(ctx: *Ctx, clauses: []const Clause, bound: *std.ArrayList(Var), steps: *std.ArrayList(Step), rows_after: *std.ArrayList(u64), rows: *u64) Failure!void {
    const pending = try ctx.arena.alloc(Pending, clauses.len);
    for (clauses, pending) |c, *p| p.* = .{ .clause = c };

    // Variables that some clause at this level binds: `not` joins on its
    // body's variables that are in scope here.
    var scope: std.ArrayList(Var) = .empty;
    try scope.appendSlice(ctx.arena, bound.items);
    try ir.boundVars(ctx.arena, clauses, &scope);

    var remaining = clauses.len;
    while (remaining > 0) {
        // Cost-free steps first.
        var progress = false;
        for (pending, 0..) |*p, idx| {
            if (p.done) continue;
            if (ctx.depth == 1) ctx.clause_index = idx;
            const placed = switch (p.clause) {
                .pred => |call| blk: {
                    if (!callBound(call, bound.items)) break :blk false;
                    try callSources(ctx, call);
                    try steps.append(ctx.arena, .{ .pred = .{ .call = call } });
                    break :blk true;
                },
                .bind => |b| blk: {
                    if (!callBound(b.call, bound.items)) break :blk false;
                    try callSources(ctx, b.call);
                    const outs = try b.out.vars(ctx.arena);
                    const fresh = try newVars(ctx.arena, outs, bound.items);
                    for (fresh) |v| try bound.append(ctx.arena, v);
                    try steps.append(ctx.arena, .{ .bind = .{ .call = b.call, .out = b.out, .fresh = fresh } });
                    break :blk true;
                },
                .not => |n| blk: {
                    const join = try notJoin(ctx, n, scope.items);
                    if (!allBound(join, bound.items)) break :blk false;
                    const sub = try planSub(ctx, n.body, join, rows.*);
                    try steps.append(ctx.arena, .{ .not = .{ .join = join, .sub = sub } });
                    break :blk true;
                },
                .@"or" => |o| blk: {
                    const join = try orJoin(ctx, o);
                    if (!allBound(join, bound.items)) break :blk false;
                    try steps.append(ctx.arena, try planOr(ctx, o.branches, join, bound.items, rows.*, null));
                    break :blk true;
                },
                .rule => |r| blk: {
                    if (!argsBound(r.args, bound.items)) break :blk false;
                    try placeRule(ctx, r, bound, steps, rows);
                    break :blk true;
                },
                .source => |s| blk: {
                    if (!allBound(s.vars, bound.items)) break :blk false;
                    try steps.append(ctx.arena, try planSource(ctx, s, bound.items));
                    break :blk true;
                },
                .pattern => false,
            };
            if (placed) {
                p.done = true;
                remaining -= 1;
                progress = true;
                try noteRows(ctx, rows_after, steps.items.len, rows.*);
            }
        }
        if (progress) continue;
        if (remaining == 0) break;

        // The cheapest source next.
        var best: ?*Pending = null;
        var best_cost: u64 = std.math.maxInt(u64);
        var unbound_pattern = false;
        for (pending, 0..) |*p, idx| {
            if (p.done) continue;
            if (ctx.depth == 1) ctx.clause_index = idx;
            const cost: ?u64 = switch (p.clause) {
                .pattern => |pat| patternEstimate(ctx, pat, bound.items) catch |err| switch (err) {
                    error.UnboundPattern => {
                        unbound_pattern = true;
                        continue;
                    },
                    else => return err,
                },
                .@"or" => |o| if (allBound(o.required, bound.items)) try orEstimate(ctx, o, bound.items) else null,
                .rule => |r| try rules_mod.callEstimate(ctx, r.name, r.args, bound.items),
                .source => 0,
                else => null,
            };
            const c = cost orelse continue;
            if (c < best_cost) {
                best_cost = c;
                best = p;
            }
        }
        const p = best orelse {
            if (unbound_pattern) return error.UnboundPattern;
            return neverBound(ctx, pending, bound.items);
        };
        if (ctx.depth == 1) ctx.clause_index = (@intFromPtr(p) - @intFromPtr(pending.ptr)) / @sizeOf(Pending);
        switch (p.clause) {
            .pattern => |pat| {
                const step = try planPattern(ctx, pat, bound.items);
                switch (step) {
                    .scan => |scan| {
                        for (scan.fresh) |v| try bound.append(ctx.arena, v);
                        rows.* = if (scan.unsatisfiable) 0 else clampRows(std.math.mulWide(u64, rows.*, scan.estimate));
                    },
                    .match => |m| {
                        for (m.fresh) |v| try bound.append(ctx.arena, v);
                        rows.* = clampRows(std.math.mulWide(u64, rows.*, best_cost));
                    },
                    else => unreachable,
                }
                try steps.append(ctx.arena, step);
            },
            .@"or" => |o| {
                const join = try orJoin(ctx, o);
                const step = try planOr(ctx, o.branches, join, bound.items, rows.*, null);
                for (step.@"or".fresh) |v| try bound.append(ctx.arena, v);
                rows.* = clampRows(std.math.mulWide(u64, rows.*, best_cost));
                try steps.append(ctx.arena, step);
            },
            .rule => |r| try placeRule(ctx, r, bound, steps, rows),
            .source => |s| {
                const step = try planSource(ctx, s, bound.items);
                for (step.source.fresh) |v| try bound.append(ctx.arena, v);
                try steps.append(ctx.arena, step);
            },
            else => unreachable,
        }
        try noteRows(ctx, rows_after, steps.items.len, rows.*);
        p.done = true;
        remaining -= 1;
    }
}

/// The refusal for a level whose remaining clauses can never run: the
/// first unbound variable of the first of them, by name and clause.
fn neverBound(ctx: *Ctx, pending: []const Pending, bound: []const Var) error{QuerySyntax} {
    for (pending, 0..) |p, idx| {
        if (p.done) continue;
        if (ctx.depth == 1) ctx.clause_index = idx;
        const args: []const ir.Arg = switch (p.clause) {
            .pred => |call| call.args,
            .bind => |b| b.call.args,
            .rule => |r| r.args,
            .not => |n| {
                const join = n.join orelse continue;
                for (join) |v| if (!ir.containsVar(bound, v)) return ctx.syntaxFmt("{s} is never bound; not-join joins on variables the clauses around it bind", .{ctx.varName(v)});
                continue;
            },
            .@"or" => |o| {
                for (o.required) |v| if (!ir.containsVar(bound, v)) return ctx.syntaxFmt("{s} is never bound; or-join needs its required variables bound before it runs", .{ctx.varName(v)});
                continue;
            },
            else => continue,
        };
        const f: ?ir.FnRef = switch (p.clause) {
            .pred => |call| call.f,
            .bind => |b| b.call.f,
            else => null,
        };
        if (f != null and f.? == .variable and !ir.containsVar(bound, f.?.variable)) return ctx.syntaxFmt("{s} in function position is never bound", .{ctx.varName(f.?.variable)});
        for (args) |a| {
            if (a == .variable and !ir.containsVar(bound, a.variable)) return ctx.syntaxFmt("{s} is never bound; a predicate, function or rule argument needs a pattern, an input or an earlier clause to bind it", .{ctx.varName(a.variable)});
        }
    }
    return ctx.syntax("a predicate, function or rule argument is never bound");
}

fn clampRows(n: u128) u64 {
    return if (n > std.math.maxInt(u64) / 4) std.math.maxInt(u64) / 4 else @intCast(n);
}

fn placeRule(ctx: *Ctx, r: anytype, bound: *std.ArrayList(Var), steps: *std.ArrayList(Step), rows: *u64) Failure!void {
    try rules_mod.planCall(ctx, r.name, r.args, r.src, bound, steps, rows);
}

/// Plan a run-time relation source: a join on its already-bound
/// variables that binds the rest.
fn planSource(ctx: *Ctx, s: anytype, bound: []const Var) !Step {
    const fresh = try newVars(ctx.arena, s.vars, bound);
    return .{ .source = .{ .slot = ctx.sources.items[s.id], .vars = s.vars, .fresh = fresh } };
}

/// Every source a call's arguments name exists.
fn callSources(ctx: *Ctx, call: ir.Call) error{QuerySyntax}!void {
    for (call.args) |a| if (a == .src) try ctx.selectDb(a.src);
}

/// A call can run once its function (when a variable) and every
/// argument variable are bound.
fn callBound(call: ir.Call, bound: []const Var) bool {
    if (call.f == .variable and !ir.containsVar(bound, call.f.variable)) return false;
    return argsBound(call.args, bound);
}

fn argsBound(args: []const ir.Arg, bound: []const Var) bool {
    for (args) |a| {
        if (a == .variable and !ir.containsVar(bound, a.variable)) return false;
    }
    return true;
}

fn allBound(vars: []const Var, bound: []const Var) bool {
    for (vars) |v| if (!ir.containsVar(bound, v)) return false;
    return true;
}

pub fn newVars(arena: Allocator, vars: []const Var, bound: []const Var) ![]Var {
    var out: std.ArrayList(Var) = .empty;
    for (vars) |v| {
        if (!ir.containsVar(bound, v)) try ir.addVar(arena, &out, v);
    }
    return out.toOwnedSlice(arena);
}

/// `not` joins on the body's variables in scope outside; `not-join` on
/// its listed variables. At least one must join.
fn notJoin(ctx: *Ctx, n: anytype, scope: []const Var) ![]const Var {
    if (n.join) |js| return js;
    var body_vars: std.ArrayList(Var) = .empty;
    try ir.allVars(ctx.arena, n.body, &body_vars);
    var join: std.ArrayList(Var) = .empty;
    for (body_vars.items) |v| {
        if (ir.containsVar(scope, v)) try join.append(ctx.arena, v);
    }
    if (join.items.len == 0) {
        std.debug.assert(body_vars.items.len > 0);
        return ctx.syntaxFmt("not shares no variable with the clauses around it: {s} is bound nowhere outside; not joins on a variable bound outside it", .{ctx.varName(body_vars.items[0])});
    }
    return join.toOwnedSlice(ctx.arena);
}

/// `or` joins on every variable of its branches; `or-join` on its list.
fn orJoin(ctx: *Ctx, o: anytype) ![]const Var {
    if (o.join) |js| return js;
    var vs: std.ArrayList(Var) = .empty;
    try ir.allVars(ctx.arena, o.branches[0], &vs);
    return vs.toOwnedSlice(ctx.arena);
}

/// Plan an `or`: every branch starts from the join variables already
/// bound and must end with every join variable bound.
pub fn planOr(ctx: *Ctx, branches: []const ir.Branch, join: []const Var, bound: []const Var, rows: u64, rule: ?u32) Failure!Step {
    var bound_join: std.ArrayList(Var) = .empty;
    for (join) |v| {
        if (ir.containsVar(bound, v)) try bound_join.append(ctx.arena, v);
    }
    const fresh = try newVars(ctx.arena, join, bound);
    const plans = try ctx.arena.alloc(*Plan, branches.len);
    for (branches, plans, 1..) |br, *p, n| {
        p.* = try planSub(ctx, br, bound_join.items, rows);
        var ends: std.ArrayList(Var) = .empty;
        try ends.appendSlice(ctx.arena, bound_join.items);
        try ir.boundVars(ctx.arena, br, &ends);
        for (join) |v| if (!ir.containsVar(ends.items, v)) {
            if (rule) |name| return ctx.syntaxFmt("rule {s} body {d} leaves {s} unbound; every body binds every head variable", .{ ctx.interner.symbolName(name), n, ctx.varName(v) });
            return ctx.syntaxFmt("or-join branch {d} leaves {s} unbound; every branch binds every join variable", .{ n, ctx.varName(v) });
        };
    }
    return .{ .@"or" = .{ .join = join, .bound = try bound_join.toOwnedSlice(ctx.arena), .fresh = fresh, .branches = plans } };
}

fn orEstimate(ctx: *Ctx, o: anytype, bound: []const Var) Failure!u64 {
    var total: u64 = 0;
    for (o.branches) |br| total +|= (try clausesEstimate(ctx, br, bound)) orelse 1;
    return total;
}

/// The smallest pattern estimate among `clauses` given `bound`; null
/// when none of them is a pattern or `or` that can run.
pub fn clausesEstimate(ctx: *Ctx, clauses: []const Clause, bound: []const Var) Failure!?u64 {
    var best: ?u64 = null;
    for (clauses) |c| {
        const est: u64 = switch (c) {
            .pattern => |p| patternEstimate(ctx, p, bound) catch |err| switch (err) {
                error.UnboundPattern => continue,
                else => return err,
            },
            .@"or" => |o| try orEstimate(ctx, o, bound),
            else => continue,
        };
        best = @min(best orelse est, est);
    }
    return best;
}

// =============================================================================
// Data patterns
// =============================================================================

/// Attributes per entity, the EAVT estimate with `a` unbound.
const attrs_per_entity: u64 = 8;
/// Values per entity of a card-many attribute.
const many_per_entity: u64 = 4;
/// Distinct-value divisor for an indexed, non-unique attribute.
const indexed_divisor: u64 = 16;
/// Entities referencing one value through a ref attribute.
const refs_per_value: u64 = 4;

const Choice = struct {
    index: key.Index,
    estimate: u64,
};

fn termBound(t: ir.Term, bound: []const Var) bool {
    return switch (t) {
        .blank => false,
        .constant => true,
        .variable => |v| ir.containsVar(bound, v),
    };
}

/// The attribute of a constant `a` term, or null when `a` is not a
/// constant; an unknown attribute is `error.UnknownAttribute`.
fn patternAttr(ctx: *Ctx, a: ir.Term) !?Attr {
    if (a != .constant) return null;
    switch (a.constant) {
        .cell => |c| switch (c) {
            .keyword => |kw| return (try ctx.attrByKeyword(kw)) orelse ctx.unknownAttr(value.fromKeywordId(kw)),
            .int => |n| {
                // An int cell holds any i64; an id is a fixnum, as transact takes it.
                const id = value.fromFixnum(n) orelse return ctx.syntax("an attribute is a keyword or an id");
                if (n <= 0 or n >= key.attr_partition_end) return ctx.unknownAttr(id);
                return (try ctx.read.attr(@intCast(n))) orelse ctx.unknownAttr(id);
            },
            else => return ctx.syntax("an attribute is a keyword or an id"),
        },
        .lookup => return ctx.syntax("an attribute cannot be a lookup ref"),
    }
}

/// Index and estimate for `p` given `bound` (§5 table).
fn choose(ctx: *Ctx, p: ir.Pattern, bound: []const Var) !Choice {
    const e_b = termBound(p.e, bound);
    const a_b = termBound(p.a, bound);
    const v_b = termBound(p.v, bound);
    const attr = try patternAttr(ctx, p.a);
    if (e_b) {
        if (attr) |at| {
            if (v_b) return .{ .index = .eavt, .estimate = 1 };
            return .{ .index = .eavt, .estimate = if (at.many()) many_per_entity else 1 };
        }
        return .{ .index = .eavt, .estimate = if (a_b) 1 else attrs_per_entity };
    }
    if (a_b and attr == null) {
        // The attribute arrives with the row: AEVT under it, `v` filtered.
        return .{ .index = .aevt, .estimate = try ctx.entriesPerAttr() };
    }
    if (attr) |at| {
        if (v_b) {
            if (at.unique != .none) return .{ .index = .avet, .estimate = 1 };
            if (at.inAvet()) return .{ .index = .avet, .estimate = @max(1, at.count / indexed_divisor) };
            if (at.inVaet()) return .{ .index = .vaet, .estimate = refs_per_value };
            return .{ .index = .aevt, .estimate = @max(1, at.count) };
        }
        return .{ .index = .aevt, .estimate = @max(1, at.count) };
    }
    if (!a_b and v_b) {
        // `v` bound with no attribute: VAET answers for ref attributes,
        // which is what a value that can be an entity id asks for; any
        // other value is matched across every datom in AEVT. A variable
        // is planned as a ref and falls back to the full scan at run
        // time when its cell is not an entity id.
        const ref_like = switch (p.v) {
            .variable => true,
            .constant => |c| c == .lookup or c.cell == .int,
            .blank => unreachable,
        };
        if (ref_like) return .{ .index = .vaet, .estimate = refs_per_value };
        return .{ .index = .aevt, .estimate = try ctx.aevtEntries() };
    }
    return error.UnboundPattern;
}

fn patternEstimate(ctx: *Ctx, p: ir.Pattern, bound: []const Var) !u64 {
    try ctx.select(p.src);
    if (ctx.coll) |rows| return @max(1, rows.len);
    return (try choose(ctx, p, bound)).estimate;
}

/// The step of a data pattern: a scan of a db source, or a match over
/// a collection.
fn planPattern(ctx: *Ctx, p: ir.Pattern, bound: []const Var) Failure!Step {
    try ctx.select(p.src);
    const rows = ctx.coll orelse return .{ .scan = try planScan(ctx, p, bound) };
    var fresh: std.ArrayList(Var) = .empty;
    var slots: [5]Slot = undefined;
    for (p.terms(), &slots) |t, *slot| slot.* = switch (t) {
        .blank => .blank,
        .variable => |v| blk: {
            if (ir.containsVar(bound, v)) break :blk .{ .bound = v };
            if (ir.containsVar(fresh.items, v)) break :blk .{ .same = v };
            try fresh.append(ctx.arena, v);
            break :blk .{ .fresh = v };
        },
        .constant => |c| switch (c) {
            .cell => |cell| .{ .constant = .{ .cell = cell } },
            .lookup => return ctx.syntax("a lookup ref needs a db source; this source is a collection"),
        },
    };
    return .{ .match = .{ .src = ctx.selected, .slots = slots, .fresh = try fresh.toOwnedSlice(ctx.arena), .rows = rows } };
}

fn planScan(ctx: *Ctx, p: ir.Pattern, bound: []const Var) Failure!Scan {
    try ctx.select(p.src);
    const choice = try choose(ctx, p, bound);
    const hash_choice: ?Choice = choose(ctx, p, &.{}) catch |err| switch (err) {
        error.UnboundPattern => null,
        else => return err,
    };
    const attr = try patternAttr(ctx, p.a);
    var unsat = false;
    var fresh: std.ArrayList(Var) = .empty;

    const terms = p.terms();
    var slots: [5]Slot = undefined;
    for (terms, 0..) |t, i| {
        slots[i] = switch (t) {
            .blank => .blank,
            .variable => |v| blk: {
                if (ir.containsVar(bound, v)) break :blk .{ .bound = v };
                if (ir.containsVar(fresh.items, v)) break :blk .{ .same = v };
                try fresh.append(ctx.arena, v);
                break :blk .{ .fresh = v };
            },
            .constant => |c| blk: {
                const resolved = try resolveConst(ctx, c, i, attr) orelse {
                    unsat = true;
                    break :blk .blank;
                };
                break :blk .{ .constant = resolved };
            },
        };
    }

    const history = ctx.read.db.history;
    const dedup = slots[0] == .blank or slots[1] == .blank or slots[2] == .blank or
        (history and (slots[3] == .blank or slots[4] == .blank));
    const store = ctx.read.db.conn.store;
    const tree = if (ctx.read.fast()) store.trees.cur(choice.index) else store.trees.hist(choice.index);
    const entries = try store_mod.Store.treeEntries(ctx.read.txn, tree);

    return .{
        .src = ctx.selected,
        .e = slots[0],
        .a = slots[1],
        .v = slots[2],
        .tx = slots[3],
        .added = slots[4],
        .index = choice.index,
        .attr = attr,
        .estimate = choice.estimate,
        .hash_index = if (hash_choice) |h| h.index else null,
        .hash_estimate = if (hash_choice) |h| h.estimate else 0,
        .tree_entries = entries,
        .dedup = dedup,
        .fresh = try fresh.toOwnedSlice(ctx.arena),
        .unsatisfiable = unsat,
    };
}

/// Resolve a pattern constant at position `pos` (0 e, 1 a, 2 v, 3 tx,
/// 4 added). Null when no datom can carry it.
fn resolveConst(ctx: *Ctx, c: ir.Constant, pos: usize, attr: ?Attr) Failure!?Const {
    switch (pos) {
        0 => {
            const eid = (try resolveEntity(ctx, c)) orelse return null;
            return .{ .cell = .{ .int = @intCast(eid) }, .name = if (c == .cell and c.cell == .keyword) c.cell.keyword else null };
        },
        1 => {
            const at = attr orelse return ctx.syntax("an attribute is a keyword or an id");
            return .{ .cell = .{ .int = at.id }, .name = if (c == .cell and c.cell == .keyword) c.cell.keyword else null };
        },
        2 => {
            if (attr) |at| {
                const val = (try resolveTyped(ctx, c, at.value_type)) orelse return null;
                const bytes = key.valBytes(ctx.arena, val) catch |err| switch (err) {
                    error.ValueType => return null,
                    else => return err,
                };
                return .{ .cell = try marshal.cellOf(ctx.read, ctx.arena, val), .bytes = bytes };
            }
            return switch (c) {
                .cell => |cell| .{ .cell = cell },
                .lookup => blk: {
                    const eid = (try resolveEntity(ctx, c)) orelse return null;
                    break :blk .{ .cell = .{ .int = @intCast(eid) } };
                },
            };
        },
        3 => {
            if (c != .cell or c.cell != .int) return ctx.syntax("the tx position takes a t or a transaction id");
            const n = c.cell.int;
            if (n < 0 or n > key.id_max) return null;
            const t = key.txOfEntity(@intCast(n)) orelse @as(u64, @intCast(n));
            if (t >= key.tx_partition_bit) return null;
            return .{ .cell = .{ .int = @intCast(key.txEntity(t)) } };
        },
        4 => {
            if (c != .cell or c.cell != .boolean) return ctx.syntax("the added position takes a boolean");
            return .{ .cell = c.cell };
        },
        else => unreachable,
    }
}

/// An entity id from an entity-position constant: an integer, a
/// keyword ident or a lookup ref. Null when the view has no such
/// entity.
pub fn resolveEntity(ctx: *Ctx, c: ir.Constant) Failure!?u64 {
    switch (c) {
        .cell => |cell| switch (cell) {
            .int => |n| {
                if (n < 0 or n > key.id_max) return null;
                return @intCast(n);
            },
            .keyword => |kw| {
                // An ident names an entity whatever the view's window; the
                // window filters the entity's datoms, not its name.
                const id = (try ctx.read.db.conn.idents.idOf(ctx.read.txn, kw)) orelse return null;
                return id;
            },
            else => return ctx.syntax("an entity is an id, an ident or a lookup ref"),
        },
        .lookup => |l| {
            const at = (try ctx.attrByKeyword(l.attr)) orelse return ctx.unknownAttr(value.fromKeywordId(l.attr));
            if (at.unique == .none) return ctx.syntax("a lookup ref needs a unique attribute");
            const val = (try resolveTyped(ctx, .{ .cell = l.v }, at.value_type)) orelse return null;
            return ctx.read.entid(ctx.arena, .{ .lookup = .{ .a = at.id, .v = val } }) catch |err| switch (err) {
                error.ValueType, error.TxData => null,
                else => err,
            };
        },
    }
}

/// The datom value of constant `c` under an attribute of type `vt`, or
/// null when no value of that type equals it.
pub fn resolveTyped(ctx: *Ctx, c: ir.Constant, vt: key.ValueType) Failure!?key.Val {
    switch (c) {
        .lookup => {
            if (vt != .ref) return null;
            const eid = (try resolveEntity(ctx, c)) orelse return null;
            return .{ .ref = eid };
        },
        .cell => |cell| {
            if (vt == .ref and cell == .keyword) {
                const eid = (try ctx.read.db.conn.idents.idOf(ctx.read.txn, cell.keyword)) orelse return null;
                return .{ .ref = eid };
            }
            return try marshal.encodeCell(ctx.read, cell, vt);
        },
    }
}

// =============================================================================
// Explain
// =============================================================================

/// Print the plan as a table: one numbered line per step with its
/// description (index, estimate, tree size, bound variables), the join
/// the executor will run for a scan (`nested`: one seek per input row;
/// `hash`: one scan of the constant prefix hash-joined on the shared
/// variables) and the estimated rows after the step; sub-plans indent
/// under their step and end with their own `rows~` line.
pub fn explain(p: *const Plan, ctx: *const Ctx, w: *std.Io.Writer) !void {
    var lines: std.ArrayList(Line) = .empty;
    try explainSub(p, ctx, &lines, 0);
    var width: usize = 0;
    for (lines.items) |l| width = @max(width, l.text.len);
    for (lines.items) |l| {
        if (l.join == null and l.rows == null) {
            try w.print("{s}\n", .{l.text});
            continue;
        }
        try w.writeAll(l.text);
        var pad = width - l.text.len + 2;
        while (pad > 0) : (pad -= 1) try w.writeByte(' ');
        try w.print("{s: <7}", .{l.join orelse ""});
        if (l.rows) |r| try w.print(" rows~{d}", .{r});
        try w.writeByte('\n');
    }
}

/// One line of the table: the description, the join kind of a scan,
/// the estimated rows after the step.
const Line = struct {
    text: []const u8,
    join: ?[]const u8 = null,
    rows: ?u64 = null,
};

fn indent(w: *std.Io.Writer, depth: usize) !void {
    var i: usize = 0;
    while (i < depth) : (i += 1) try w.writeAll("  ");
}

/// Scanned rows one seek is worth per doubling of the tree: a seek
/// costs `log2(entries)` page-level comparisons against a hot tree, a
/// scanned row one cursor step, one decode and one hash-index insert.
/// Measured on the 200k-datom benchmark, where a hash join over a
/// 40k-entry attribute costs what 9k seeks do.
pub const hash_weight: u64 = 4;

/// Does a scan of `s` over `rows` input rows run as an index nested
/// loop (one seek per row) rather than as one scan of its constant
/// prefix hash-joined on the shared variables? A pattern with no
/// constant to seek by, or whose attribute arrives with the row (an
/// ident a hash join could not match against attribute ids), always
/// seeks.
pub fn nestedLoop(s: *const Scan, rows: u64) bool {
    const log_n: u64 = std.math.log2_int_ceil(u64, s.tree_entries + 2);
    return s.hash_index == null or s.a == .bound or (std.math.mulWide(u64, rows, log_n) < std.math.mulWide(u64, s.hash_estimate, hash_weight));
}

/// The join `execScan` runs for `s` on `rows` input rows.
fn joinKind(s: *const Scan, rows: u64) []const u8 {
    if (s.unsatisfiable) return "none";
    return if (nestedLoop(s, rows)) "nested" else "hash";
}

pub fn explainSub(p: *const Plan, ctx: *const Ctx, lines: *std.ArrayList(Line), depth: usize) (Failure || std.Io.Writer.Error)!void {
    try stack.check();
    for (p.steps, 0..) |step, i| {
        var out: std.Io.Writer.Allocating = .init(ctx.arena);
        const w = &out.writer;
        try indent(w, depth);
        try w.print("{d}. ", .{i + 1});
        var line: Line = .{ .text = "", .rows = p.rows_after[i] };
        switch (step) {
            .scan => |s| {
                try w.writeAll("scan [");
                if (s.src != 0) try w.print("{s} ", .{ctx.interner.symbolName(ctx.source_names[s.src])});
                for (s.slots(), 0..) |slot, j| {
                    if (j > 0) try w.writeByte(' ');
                    try explainSlot(slot, ctx, w);
                }
                try w.print("] {s}", .{s.index.name()});
                if (s.unsatisfiable) {
                    try w.writeAll(" unsatisfiable");
                } else {
                    try w.print(" est={d} tree={d}", .{ s.estimate, s.tree_entries });
                    if (s.dedup) try w.writeAll(" dedup");
                }
                line.join = joinKind(&s, p.rowsBefore(i));
                line.text = out.written();
                try lines.append(ctx.arena, line);
            },
            .pred => |pr| {
                try w.writeAll("pred ");
                try explainCall(pr.call, ctx, w);
                line.text = out.written();
                try lines.append(ctx.arena, line);
            },
            .bind => |b| {
                try w.writeAll("bind ");
                try explainCall(b.call, ctx, w);
                try w.writeAll(" -> ");
                try explainBinding(b, ctx, w);
                line.text = out.written();
                try lines.append(ctx.arena, line);
            },
            .not => |n| {
                try w.writeAll("not-join [");
                try explainVars(n.join, ctx, w);
                try w.writeAll("]");
                line.text = out.written();
                try lines.append(ctx.arena, line);
                try explainSub(n.sub, ctx, lines, depth + 1);
            },
            .@"or" => |o| {
                try w.writeAll("or-join [");
                try explainVars(o.join, ctx, w);
                try w.print("] branches={d}", .{o.branches.len});
                line.text = out.written();
                try lines.append(ctx.arena, line);
                for (o.branches) |br| {
                    var bw: std.Io.Writer.Allocating = .init(ctx.arena);
                    try indent(&bw.writer, depth + 1);
                    try bw.writer.writeAll("branch");
                    try lines.append(ctx.arena, .{ .text = bw.written() });
                    try explainSub(br, ctx, lines, depth + 2);
                }
            },
            .source => |s| {
                try w.writeAll("source [");
                try explainVars(s.vars, ctx, w);
                try w.writeAll("]");
                line.join = "hash";
                line.text = out.written();
                try lines.append(ctx.arena, line);
            },
            .match => |m| {
                try w.print("match [{s}", .{ctx.interner.symbolName(ctx.source_names[m.src])});
                for (m.slots) |slot| {
                    try w.writeByte(' ');
                    try explainSlot(slot, ctx, w);
                }
                try w.print("] tuples={d}", .{m.rows.len});
                line.join = "hash";
                line.text = out.written();
                try lines.append(ctx.arena, line);
            },
            .fix => |f| {
                try rules_mod.explainFix(&f, ctx, w);
                line.join = "fixpoint";
                line.text = out.written();
                try lines.append(ctx.arena, line);
                try rules_mod.explainFixBodies(&f, ctx, lines, depth + 1);
            },
        }
    }
    var tail: std.Io.Writer.Allocating = .init(ctx.arena);
    try indent(&tail.writer, depth);
    try tail.writer.print("rows~{d}", .{p.rows_estimate});
    try lines.append(ctx.arena, .{ .text = tail.written() });
}

/// The binding's variables; one bound before the step (which the
/// step unifies rather than binds) is marked `!` like a scan slot.
fn explainBinding(b: Bind, ctx: *const Ctx, w: *std.Io.Writer) !void {
    const outs: []const ?Var = switch (b.out) {
        .scalar, .collection => |v| &.{v},
        .tuple, .relation => |ts| ts,
    };
    var first = true;
    for (outs) |t| {
        const v = t orelse continue;
        if (!first) try w.writeByte(' ');
        first = false;
        try w.writeAll(ctx.varName(v));
        if (!ir.containsVar(b.fresh, v)) try w.writeByte('!');
    }
}

fn explainVars(vars: []const Var, ctx: *const Ctx, w: *std.Io.Writer) !void {
    for (vars, 0..) |v, i| {
        if (i > 0) try w.writeByte(' ');
        try w.writeAll(ctx.varName(v));
    }
}

fn explainSlot(slot: Slot, ctx: *const Ctx, w: *std.Io.Writer) !void {
    switch (slot) {
        .blank => try w.writeAll("_"),
        .bound => |v| try w.print("{s}!", .{ctx.varName(v)}),
        .fresh, .same => |v| try w.writeAll(ctx.varName(v)),
        .constant => |c| {
            if (c.name) |k| return w.print(":{s}", .{ctx.interner.keywordName(k)});
            try explainCell(c.cell, ctx, w);
        },
    }
}

pub fn explainCell(c: Cell, ctx: *const Ctx, w: *std.Io.Writer) !void {
    switch (c) {
        .nil => try w.writeAll("nil"),
        .int => |n| try w.print("{d}", .{n}),
        .double => |d| try w.print("{d}", .{d}),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .keyword => |k| try w.print(":{s}", .{ctx.interner.keywordName(k)}),
        .str => |s| try w.print("\"{s}\"", .{s}),
        .vm => try w.writeAll("#value"),
    }
}

fn explainCall(call: ir.Call, ctx: *const Ctx, w: *std.Io.Writer) !void {
    try w.writeByte('(');
    switch (call.f) {
        .builtin => |b| try w.writeAll(b.name()),
        .user => |s| try w.writeAll(ctx.interner.symbolName(s)),
        .variable => |v| try w.print("{s}!", .{ctx.varName(v)}),
    }
    for (call.args) |a| {
        try w.writeByte(' ');
        switch (a) {
            .variable => |v| try w.writeAll(ctx.varName(v)),
            .constant => |c| try explainCell(c, ctx, w),
            .src => |x| try w.writeAll(ctx.interner.symbolName(ctx.source_names[x orelse 0])),
        }
    }
    try w.writeByte(')');
}
