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
//!     can never be bound is `error.QuerySyntax`.
//!   - Index choice follows the §5 table from what is bound when the
//!     pattern runs; estimates come from `Schema` attribute counts.
//!   - A constant that cannot exist in the store (an unknown ident, a
//!     lookup ref with no entity, a value of the wrong type for the
//!     attribute) marks its scan `unsatisfiable`: it yields nothing and
//!     is not an error.
//!   - Sub-plans (`not`, `or`, rule bodies) are planned with their join
//!     variables bound and start from a relation over those variables.
//!   - Plan variables extend the IR's table; renamed rule variables are
//!     appended and never alias a query variable.
//!   - Everything a plan allocates lives in the query arena.

const std = @import("std");
const value = @import("value");
const intern_mod = @import("intern");
const key = @import("../key.zig");
const datom_mod = @import("../datom.zig");
const schema_mod = @import("../schema.zig");
const db_mod = @import("../db.zig");
const relation = @import("../relation.zig");
const ir = @import("ir.zig");
const rules_mod = @import("rules.zig");

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

pub const Error = error{
    QuerySyntax,
    UnboundPattern,
    UnknownAttribute,
    OutOfMemory,
};

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

    pub fn isBound(self: Slot) bool {
        return self == .bound or self == .constant;
    }
};

pub const Scan = struct {
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
    /// Estimated rows after the last step.
    rows_estimate: u64,
};

/// Everything planning needs about the query: the `Read`, the variable
/// table (shared by every sub-plan) and the rule set.
pub const Ctx = struct {
    arena: Allocator,
    read: *Read,
    interner: *Interner,
    vars: std.ArrayList(ir.VarInfo),
    rules: *const RuleSet,
    rule_info: ?*rules_mod.Info = null,
    /// Attributes resolved so far, by VM keyword id.
    attr_cache: std.AutoHashMapUnmanaged(u32, ?Attr) = .empty,
    /// The query's `Ir` table size; variables at or past it are renames.
    ir_vars: usize,
    /// Run-time relation slots, by `Clause.source.id`.
    sources: std.ArrayList(*SourceSlot) = .empty,

    pub fn init(arena: Allocator, read: *Read, interner: *Interner, query: *const Ir, rules: *const RuleSet) !Ctx {
        var vars: std.ArrayList(ir.VarInfo) = .empty;
        try vars.appendSlice(arena, query.vars);
        return .{ .arena = arena, .read = read, .interner = interner, .vars = vars, .rules = rules, .ir_vars = query.vars.len };
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
pub fn plan(ctx: *Ctx, query: *const Ir) anyerror!*Plan {
    var bound: std.ArrayList(Var) = .empty;
    for (query.in) |b| switch (b) {
        .scalar, .collection => |v| try ir.addVar(ctx.arena, &bound, v),
        .tuple, .relation => |ts| for (ts) |t| {
            if (t) |v| try ir.addVar(ctx.arena, &bound, v);
        },
        .src, .rules => {},
    };
    return planSub(ctx, query.where, bound.items, 1);
}

/// Plan `clauses` starting from a relation over `input`.
pub fn planSub(ctx: *Ctx, clauses: []const Clause, input: []const Var, rows_in: u64) anyerror!*Plan {
    const out = try ctx.arena.create(Plan);
    var bound: std.ArrayList(Var) = .empty;
    try bound.appendSlice(ctx.arena, input);
    var steps: std.ArrayList(Step) = .empty;
    var rows = rows_in;
    try planClauses(ctx, clauses, &bound, &steps, &rows);
    out.* = .{ .input = try ctx.arena.dupe(Var, input), .steps = try steps.toOwnedSlice(ctx.arena), .rows_estimate = rows };
    return out;
}

const Pending = struct {
    clause: Clause,
    done: bool = false,
};

fn planClauses(ctx: *Ctx, clauses: []const Clause, bound: *std.ArrayList(Var), steps: *std.ArrayList(Step), rows: *u64) anyerror!void {
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
        for (pending) |*p| {
            if (p.done) continue;
            const placed = switch (p.clause) {
                .pred => |call| blk: {
                    if (!argsBound(call.args, bound.items)) break :blk false;
                    try steps.append(ctx.arena, .{ .pred = .{ .call = call } });
                    break :blk true;
                },
                .bind => |b| blk: {
                    if (!argsBound(b.call.args, bound.items)) break :blk false;
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
                    try steps.append(ctx.arena, try planOr(ctx, o.branches, join, bound.items, rows.*));
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
            }
        }
        if (progress) continue;
        if (remaining == 0) break;

        // The cheapest source next.
        var best: ?*Pending = null;
        var best_cost: u64 = std.math.maxInt(u64);
        var unbound_pattern = false;
        for (pending) |*p| {
            if (p.done) continue;
            const cost: ?u64 = switch (p.clause) {
                .pattern => |pat| patternEstimate(ctx, pat, bound.items) catch |err| switch (err) {
                    error.UnboundPattern => {
                        unbound_pattern = true;
                        continue;
                    },
                    else => return err,
                },
                .@"or" => |o| try orEstimate(ctx, o, bound.items),
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
            return error.QuerySyntax;
        };
        switch (p.clause) {
            .pattern => |pat| {
                const scan = try planScan(ctx, pat, bound.items);
                for (scan.fresh) |v| try bound.append(ctx.arena, v);
                rows.* = if (scan.unsatisfiable) 0 else clampRows(std.math.mulWide(u64, rows.*, scan.estimate));
                try steps.append(ctx.arena, .{ .scan = scan });
            },
            .@"or" => |o| {
                const join = try orJoin(ctx, o);
                const step = try planOr(ctx, o.branches, join, bound.items, rows.*);
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
        p.done = true;
        remaining -= 1;
    }
}

fn clampRows(n: u128) u64 {
    return if (n > std.math.maxInt(u64) / 4) std.math.maxInt(u64) / 4 else @intCast(n);
}

fn placeRule(ctx: *Ctx, r: anytype, bound: *std.ArrayList(Var), steps: *std.ArrayList(Step), rows: *u64) anyerror!void {
    try rules_mod.planCall(ctx, r.name, r.args, bound, steps, rows);
}

/// Plan a run-time relation source: a join on its already-bound
/// variables that binds the rest.
fn planSource(ctx: *Ctx, s: anytype, bound: []const Var) !Step {
    const fresh = try newVars(ctx.arena, s.vars, bound);
    return .{ .source = .{ .slot = ctx.sources.items[s.id], .vars = s.vars, .fresh = fresh } };
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
    if (join.items.len == 0) return error.QuerySyntax;
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
pub fn planOr(ctx: *Ctx, branches: []const ir.Branch, join: []const Var, bound: []const Var, rows: u64) anyerror!Step {
    var bound_join: std.ArrayList(Var) = .empty;
    for (join) |v| {
        if (ir.containsVar(bound, v)) try bound_join.append(ctx.arena, v);
    }
    const fresh = try newVars(ctx.arena, join, bound);
    const plans = try ctx.arena.alloc(*Plan, branches.len);
    for (branches, plans) |br, *p| {
        p.* = try planSub(ctx, br, bound_join.items, rows);
        var ends: std.ArrayList(Var) = .empty;
        try ends.appendSlice(ctx.arena, bound_join.items);
        try ir.boundVars(ctx.arena, br, &ends);
        for (join) |v| if (!ir.containsVar(ends.items, v)) return error.QuerySyntax;
    }
    return .{ .@"or" = .{ .join = join, .bound = try bound_join.toOwnedSlice(ctx.arena), .fresh = fresh, .branches = plans } };
}

fn orEstimate(ctx: *Ctx, o: anytype, bound: []const Var) anyerror!u64 {
    var total: u64 = 0;
    for (o.branches) |br| total +|= try clausesEstimate(ctx, br, bound);
    return total;
}

/// The smallest pattern estimate among `clauses` given `bound`; 1 for a
/// branch without runnable patterns.
pub fn clausesEstimate(ctx: *Ctx, clauses: []const Clause, bound: []const Var) anyerror!u64 {
    var best: u64 = std.math.maxInt(u64);
    for (clauses) |c| {
        const est: u64 = switch (c) {
            .pattern => |p| patternEstimate(ctx, p, bound) catch |err| switch (err) {
                error.UnboundPattern => continue,
                else => return err,
            },
            .@"or" => |o| try orEstimate(ctx, o, bound),
            else => continue,
        };
        best = @min(best, est);
    }
    return if (best == std.math.maxInt(u64)) 1 else best;
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
            .keyword => |kw| return (try ctx.attrByKeyword(kw)) orelse error.UnknownAttribute,
            .int => |n| {
                if (n <= 0 or n >= key.attr_partition_end) return error.UnknownAttribute;
                return (try ctx.read.attr(@intCast(n))) orelse error.UnknownAttribute;
            },
            else => return error.QuerySyntax,
        },
        .lookup => return error.QuerySyntax,
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
        // which is what a value that can be an entity id asks for.
        const ref_like = switch (p.v) {
            .variable => true,
            .constant => |c| c == .lookup or c.cell == .int,
            .blank => unreachable,
        };
        if (ref_like) return .{ .index = .vaet, .estimate = refs_per_value };
    }
    return error.UnboundPattern;
}

fn patternEstimate(ctx: *Ctx, p: ir.Pattern, bound: []const Var) !u64 {
    return (try choose(ctx, p, bound)).estimate;
}

fn planScan(ctx: *Ctx, p: ir.Pattern, bound: []const Var) anyerror!Scan {
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
    const entries = try store.treeEntries(ctx.read.txn, tree);

    return .{
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
fn resolveConst(ctx: *Ctx, c: ir.Constant, pos: usize, attr: ?Attr) anyerror!?Const {
    switch (pos) {
        0 => {
            const eid = (try resolveEntity(ctx, c)) orelse return null;
            return .{ .cell = .{ .int = @intCast(eid) }, .name = if (c == .cell and c.cell == .keyword) c.cell.keyword else null };
        },
        1 => {
            const at = attr orelse return error.QuerySyntax;
            return .{ .cell = .{ .int = at.id }, .name = if (c == .cell and c.cell == .keyword) c.cell.keyword else null };
        },
        2 => {
            if (attr) |at| {
                const val = (try resolveTyped(ctx, c, at.value_type)) orelse return null;
                const bytes = key.valBytes(ctx.arena, val) catch |err| switch (err) {
                    error.ValueType => return null,
                    else => return err,
                };
                return .{ .cell = cellOfVal(ctx, val), .bytes = bytes };
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
            if (c != .cell or c.cell != .int) return error.QuerySyntax;
            const n = c.cell.int;
            if (n < 0) return null;
            const t = key.txOfEntity(@intCast(n)) orelse @as(u64, @intCast(n));
            if (t >= key.tx_partition_bit) return null;
            return .{ .cell = .{ .int = @intCast(key.txEntity(t)) } };
        },
        4 => {
            if (c != .cell or c.cell != .boolean) return error.QuerySyntax;
            return .{ .cell = c.cell };
        },
        else => unreachable,
    }
}

/// An entity id from an entity-position constant: an integer, a
/// keyword ident or a lookup ref. Null when the view has no such
/// entity.
pub fn resolveEntity(ctx: *Ctx, c: ir.Constant) anyerror!?u64 {
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
            else => return error.QuerySyntax,
        },
        .lookup => |l| {
            const at = (try ctx.attrByKeyword(l.attr)) orelse return error.UnknownAttribute;
            if (at.unique == .none) return error.QuerySyntax;
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
pub fn resolveTyped(ctx: *Ctx, c: ir.Constant, vt: key.ValueType) anyerror!?key.Val {
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
            return try encodeCell(ctx.read, cell, vt);
        },
    }
}

/// The datom value of `cell` under type `vt`, or null when no value of
/// that type equals it. Keywords are resolved through the store's
/// idents; an unknown ident is null.
pub fn encodeCell(read: *Read, cell: Cell, vt: key.ValueType) anyerror!?key.Val {
    return switch (vt) {
        .boolean => if (cell == .boolean) .{ .boolean = cell.boolean } else null,
        .long => if (cell == .int) .{ .long = cell.int } else null,
        .double => if (cell == .double) .{ .double = cell.double } else null,
        .instant => if (cell == .int) .{ .instant = cell.int } else null,
        .keyword => blk: {
            if (cell != .keyword) break :blk null;
            const id = (try read.db.conn.idents.idOf(read.txn, cell.keyword)) orelse break :blk null;
            break :blk .{ .keyword = id };
        },
        .ref => blk: {
            const eid = cell.asEid() orelse break :blk null;
            break :blk .{ .ref = eid };
        },
        .string => if (cell == .str) .{ .string = cell.str } else null,
        .uuid => blk: {
            if (cell != .str) break :blk null;
            const u = datom_mod.uuidFromText(cell.str) orelse break :blk null;
            break :blk .{ .uuid = u };
        },
        .bytes => if (cell == .str) .{ .bytes = cell.str } else null,
    };
}

/// The cell a resolved datom value compares as: ids as `int`, keyword
/// values as VM keyword ids (the constant came from one, so the
/// intern exists).
fn cellOfVal(ctx: *Ctx, v: key.Val) Cell {
    return switch (v) {
        .boolean => |b| .{ .boolean = b },
        .long, .instant => |n| .{ .int = n },
        .double => |d| .{ .double = d },
        .keyword => |id| .{ .keyword = ctx.read.db.conn.idents.by_ident.get(id).? },
        .ref => |e| .{ .int = @intCast(e) },
        .string, .bytes => |s| .{ .str = s },
        .uuid => |u| blk: {
            const text = ctx.arena.alloc(u8, 36) catch unreachable;
            datom_mod.uuidToText(text[0..36], u);
            break :blk .{ .str = text };
        },
    };
}

// =============================================================================
// Explain
// =============================================================================

/// Print the ordered steps with their index and estimate.
pub fn explain(p: *const Plan, ctx: *const Ctx, w: *std.Io.Writer) !void {
    try explainSub(p, ctx, w, 0);
}

fn indent(w: *std.Io.Writer, depth: usize) !void {
    var i: usize = 0;
    while (i < depth) : (i += 1) try w.writeAll("  ");
}

pub fn explainSub(p: *const Plan, ctx: *const Ctx, w: *std.Io.Writer, depth: usize) anyerror!void {
    for (p.steps, 1..) |step, num| {
        try indent(w, depth);
        try w.print("{d}. ", .{num});
        switch (step) {
            .scan => |s| {
                try w.writeAll("scan [");
                for (s.slots(), 0..) |slot, i| {
                    if (i > 0) try w.writeByte(' ');
                    try explainSlot(slot, ctx, w);
                }
                try w.print("] {s}", .{s.index.name()});
                if (s.unsatisfiable) {
                    try w.writeAll(" unsatisfiable");
                } else {
                    try w.print(" est={d} tree={d}", .{ s.estimate, s.tree_entries });
                    if (s.dedup) try w.writeAll(" dedup");
                }
                try w.writeByte('\n');
            },
            .pred => |pr| {
                try w.writeAll("pred ");
                try explainCall(pr.call, ctx, w);
                try w.writeByte('\n');
            },
            .bind => |b| {
                try w.writeAll("bind ");
                try explainCall(b.call, ctx, w);
                try w.writeAll(" -> ");
                for (b.fresh, 0..) |v, i| {
                    if (i > 0) try w.writeByte(' ');
                    try w.writeAll(ctx.varName(v));
                }
                try w.writeByte('\n');
            },
            .not => |n| {
                try w.writeAll("not-join [");
                try explainVars(n.join, ctx, w);
                try w.writeAll("]\n");
                try explainSub(n.sub, ctx, w, depth + 1);
            },
            .@"or" => |o| {
                try w.writeAll("or-join [");
                try explainVars(o.join, ctx, w);
                try w.print("] branches={d}\n", .{o.branches.len});
                for (o.branches) |br| {
                    try indent(w, depth + 1);
                    try w.writeAll("branch\n");
                    try explainSub(br, ctx, w, depth + 2);
                }
            },
            .source => |s| {
                try w.writeAll("source [");
                try explainVars(s.vars, ctx, w);
                try w.writeAll("]\n");
            },
            .fix => |f| try rules_mod.explainFix(&f, ctx, w, depth),
        }
    }
    try indent(w, depth);
    try w.print("rows~{d}\n", .{p.rows_estimate});
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
    }
    for (call.args) |a| {
        try w.writeByte(' ');
        switch (a) {
            .variable => |v| try w.writeAll(ctx.varName(v)),
            .constant => |c| try explainCell(c, ctx, w),
            .src => try w.writeAll("$"),
        }
    }
    try w.writeByte(')');
}
