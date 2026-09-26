//! query/rules.zig — rule expansion and evaluation (NEXTOMIC.md §5
//! "Rules").
//!
//! A `%` input is a `RuleSet`. Calls to non-recursive rules inline as
//! an `or-join` over the rule's bodies, each body renamed into fresh
//! plan variables with its head bound to the call's arguments. Calls
//! into a recursive strongly connected component become a `Fix` step:
//! every rule of the component is instantiated once, recursive calls
//! inside the bodies become run-time `source` joins, and the step runs
//! the semi-naive fixpoint
//!   total = ∪ base bodies; delta = total;
//!   repeat { new = ∪ recursive bodies with one recursive call bound
//!            to delta and the others to total, minus total;
//!            total ∪= new; delta = new } until delta is empty.
//! Invariants:
//!   - Constant call arguments are grounded into fresh variables before
//!     the call, so every argument is a variable when the rule expands.
//!   - A bound argument is pushed into the called rule's bodies only at
//!     a pass-through position: the component has one rule and every
//!     recursive call in every body passes the head variable of that
//!     position through unchanged. Every other bound argument filters
//!     the result. Pushing elsewhere would lose derivations.
//!   - Termination: `total` only grows and every row comes from a
//!     finite set of datoms and inputs, so the fixpoint is reached.
//!   - Soundness: a growing fixpoint answers stratified programs only,
//!     so a component whose rules call one another inside `not` is
//!     refused before it runs.
//!   - Rule bodies see the same `Read` snapshots as the query; a body's
//!     unprefixed clauses read the source the call names (`$` by
//!     default), and a recursive component is instantiated under one
//!     source.

const std = @import("std");
const ir = @import("ir.zig");
const plan_mod = @import("plan.zig");
const exec_mod = @import("exec.zig");
const relation = @import("../relation.zig");
const stack = @import("../../stack.zig");

const Allocator = std.mem.Allocator;
const Var = ir.Var;
const Clause = ir.Clause;
const RuleSet = ir.RuleSet;
const Ctx = plan_mod.Ctx;
const Plan = plan_mod.Plan;
const Step = plan_mod.Step;
const Failure = plan_mod.Failure;
const Bound = plan_mod.Bound;
const Relation = relation.Relation;

/// Planner cost of a recursive rule call: after every pattern that
/// could bind its arguments.
const recursive_cost: u64 = 1 << 20;
/// Planner cost of an inlined rule body with no pattern that can run,
/// and the row growth assumed per rule call.
const body_cost: u64 = 16;

// =============================================================================
// Call graph analysis
// =============================================================================

pub const Info = struct {
    /// Distinct rule names.
    names: []const u32,
    /// Component id per name index.
    scc_of: []const usize,
    /// Per component: does it contain a cycle?
    recursive: []const bool,
    /// Per component: does one of its rules call another of its rules
    /// inside a `not`? Such a program is not stratified.
    negated: []const bool,

    pub fn nameIndex(self: *const Info, name: u32) ?usize {
        for (self.names, 0..) |n, i| if (n == name) return i;
        return null;
    }

    pub fn isRecursive(self: *const Info, name: u32) bool {
        const i = self.nameIndex(name) orelse return false;
        return self.recursive[self.scc_of[i]];
    }

    /// Name indexes in the component of `name`.
    pub fn members(self: *const Info, arena: Allocator, name: u32) ![]usize {
        const i = self.nameIndex(name).?;
        var out: std.ArrayList(usize) = .empty;
        for (self.scc_of, 0..) |s, j| if (s == self.scc_of[i]) try out.append(arena, j);
        return out.toOwnedSlice(arena);
    }
};

/// Strongly connected components of the rule call graph (Tarjan).
pub fn analyze(arena: Allocator, set: *const RuleSet) !Info {
    var names: std.ArrayList(u32) = .empty;
    for (set.rules) |r| {
        var seen = false;
        for (names.items) |n| if (n == r.name) {
            seen = true;
        };
        if (!seen) try names.append(arena, r.name);
    }
    const n = names.items.len;
    const edges = try arena.alloc([]usize, n);
    const negative = try arena.alloc([]usize, n);
    for (names.items, 0..) |name, i| {
        var calls: std.ArrayList(Call) = .empty;
        for (set.byName(name).?) |r| try collectCalls(arena, r.body, false, &calls);
        var out: std.ArrayList(usize) = .empty;
        var neg: std.ArrayList(usize) = .empty;
        for (calls.items) |c| {
            for (names.items, 0..) |m, j| if (m == c.name) {
                try out.append(arena, j);
                if (c.negated) try neg.append(arena, j);
            };
        }
        edges[i] = try out.toOwnedSlice(arena);
        negative[i] = try neg.toOwnedSlice(arena);
    }

    var t = Tarjan{
        .arena = arena,
        .edges = edges,
        .index = try arena.alloc(?usize, n),
        .low = try arena.alloc(usize, n),
        .on_stack = try arena.alloc(bool, n),
        .scc_of = try arena.alloc(usize, n),
    };
    @memset(t.index, null);
    @memset(t.on_stack, false);
    for (0..n) |i| if (t.index[i] == null) try t.visit(i);

    const recursive = try arena.alloc(bool, t.scc_count);
    @memset(recursive, false);
    for (0..n) |i| {
        var members: usize = 0;
        for (t.scc_of) |s| if (s == t.scc_of[i]) {
            members += 1;
        };
        if (members > 1) recursive[t.scc_of[i]] = true;
        for (edges[i]) |j| if (j == i) {
            recursive[t.scc_of[i]] = true;
        };
    }
    const negated = try arena.alloc(bool, t.scc_count);
    @memset(negated, false);
    for (negative, 0..) |js, i| for (js) |j| {
        if (t.scc_of[i] == t.scc_of[j]) negated[t.scc_of[i]] = true;
    };
    return .{ .names = try names.toOwnedSlice(arena), .scc_of = t.scc_of, .recursive = recursive, .negated = negated };
}

const Tarjan = struct {
    arena: Allocator,
    edges: []const []const usize,
    index: []?usize,
    low: []usize,
    on_stack: []bool,
    scc_of: []usize,
    stack: std.ArrayList(usize) = .empty,
    next: usize = 0,
    scc_count: usize = 0,

    fn visit(self: *Tarjan, v: usize) !void {
        try stack.check();
        self.index[v] = self.next;
        self.low[v] = self.next;
        self.next += 1;
        try self.stack.append(self.arena, v);
        self.on_stack[v] = true;
        for (self.edges[v]) |w| {
            if (self.index[w] == null) {
                try self.visit(w);
                self.low[v] = @min(self.low[v], self.low[w]);
            } else if (self.on_stack[w]) {
                self.low[v] = @min(self.low[v], self.index[w].?);
            }
        }
        if (self.low[v] == self.index[v].?) {
            while (true) {
                const w = self.stack.pop().?;
                self.on_stack[w] = false;
                self.scc_of[w] = self.scc_count;
                if (w == v) break;
            }
            self.scc_count += 1;
        }
    }
};

const Call = struct { name: u32, negated: bool };

/// Rule names called anywhere in `clauses`, each marked when it is
/// inside a `not`.
fn collectCalls(arena: Allocator, clauses: []const Clause, negated: bool, out: *std.ArrayList(Call)) !void {
    try stack.check();
    for (clauses) |c| switch (c) {
        .rule => |r| try out.append(arena, .{ .name = r.name, .negated = negated }),
        .not => |n| try collectCalls(arena, n.body, true, out),
        .@"or" => |o| for (o.branches) |br| try collectCalls(arena, br, negated, out),
        else => {},
    };
}

/// Is head position `pos` of rule `name` passed through unchanged by
/// every recursive call in every body of the rule?
fn passThrough(arena: Allocator, set: *const RuleSet, name: u32, pos: usize) !bool {
    for (set.byName(name).?) |r| {
        var calls: std.ArrayList(ir.Clause) = .empty;
        try collectRuleCalls(arena, r.body, name, &calls);
        for (calls.items) |c| {
            const a = c.rule.args[pos];
            if (a != .variable or a.variable != r.head[pos]) return false;
        }
    }
    return true;
}

fn collectRuleCalls(arena: Allocator, clauses: []const Clause, name: u32, out: *std.ArrayList(Clause)) !void {
    try stack.check();
    for (clauses) |c| switch (c) {
        .rule => |r| if (r.name == name) try out.append(arena, c),
        .not => |n| try collectRuleCalls(arena, n.body, name, out),
        .@"or" => |o| for (o.branches) |br| try collectRuleCalls(arena, br, name, out),
        else => {},
    };
}

// =============================================================================
// Planning
// =============================================================================

fn defsOf(ctx: *Ctx, name: u32, args: []const ir.Arg) ![]const ir.Rule {
    const defs = ctx.rules.byName(name) orelse return ctx.syntax("unknown rule");
    if (defs[0].head.len != args.len) return ctx.syntax("a rule is called with the wrong number of arguments");
    return defs;
}

/// The planner's cost for calling `name`, or null while a required
/// argument is unbound.
pub fn callEstimate(ctx: *Ctx, name: u32, args: []const ir.Arg, bound: *const Bound) Failure!?u64 {
    const defs = try defsOf(ctx, name, args);
    for (args[0..defs[0].required]) |a| {
        if (a == .variable and !bound.has(a.variable)) return null;
    }
    const info = try ctx.ruleInfo();
    if (info.isRecursive(name)) return recursive_cost;
    // Each body costs its cheapest pattern, with the head variables
    // bound where the call's arguments are.
    var total: u64 = 0;
    for (defs) |def| {
        var head_bound: Bound = .{};
        for (def.head, args) |h, a| {
            if (a != .variable or bound.has(a.variable)) try head_bound.add(ctx.arena, h);
        }
        total +|= (try plan_mod.clausesEstimate(ctx, def.body, &head_bound)) orelse body_cost;
    }
    return total;
}

/// Append the steps of a rule call: grounding binds for constant
/// arguments, then an `or` (non-recursive) or a `fix` (recursive).
pub fn planCall(ctx: *Ctx, name: u32, args: []const ir.Arg, src: ?ir.Src, bound: *Bound, steps: *std.ArrayList(Step), rows: *u64) Failure!void {
    const defs = try defsOf(ctx, name, args);
    const arg_vars = try ctx.arena.alloc(Var, args.len);
    for (args, arg_vars) |a, *v| {
        v.* = switch (a) {
            .variable => |x| x,
            .constant => |c| blk: {
                const g = try groundConst(ctx, c);
                try steps.append(ctx.arena, .{ .bind = .{ .call = g.bind.call, .out = g.bind.out, .fresh = try ctx.arena.dupe(Var, &.{g.bind.out.scalar}) } });
                try bound.add(ctx.arena, g.bind.out.scalar);
                break :blk g.bind.out.scalar;
            },
            .src => return ctx.syntax("$ cannot be a rule argument"),
        };
    }
    for (arg_vars[0..defs[0].required]) |v| {
        if (!bound.has(v)) return ctx.syntax("a required rule argument is unbound");
    }

    const info = try ctx.ruleInfo();
    if (!info.isRecursive(name)) {
        const branches = try ctx.arena.alloc(ir.Branch, defs.len);
        for (defs, branches) |def, *br| {
            var r = try Renamer.init(ctx, arg_vars, def, null, src);
            br.* = try r.clauses(def.body);
        }
        var join: std.ArrayList(Var) = .empty;
        for (arg_vars) |v| try ir.addVar(ctx.arena, &join, v);
        const step = try plan_mod.planOr(ctx, branches, join.items, bound, rows.*, name);
        for (step.@"or".fresh) |v| try bound.add(ctx.arena, v);
        try steps.append(ctx.arena, step);
    } else {
        const fix = try planFix(ctx, name, arg_vars, src, bound, rows.*);
        for (fix.fresh) |v| try bound.add(ctx.arena, v);
        try steps.append(ctx.arena, .{ .fix = fix });
    }
    rows.* = std.math.mul(u64, rows.*, body_cost) catch std.math.maxInt(u64) / 4;
}

/// `[(ground c) ?const]` over a fresh variable: a constant rule
/// argument, grounded so that every argument is a variable.
fn groundConst(ctx: *Ctx, c: ir.Cell) !Clause {
    const fresh = try ctx.freshVar(try ctx.interner.internSymbol("?const"));
    const call: ir.Call = .{ .f = .{ .builtin = .ground }, .args = try ctx.arena.dupe(ir.Arg, &.{.{ .constant = c }}) };
    return .{ .bind = .{ .call = call, .out = .{ .scalar = fresh } } };
}

pub const CallSite = struct {
    slot: *plan_mod.SourceSlot,
    /// Instance index of the callee.
    callee: usize,
};

pub const Body = struct {
    plan: *Plan,
    /// Empty for a base body.
    sites: []const CallSite,
};

pub const Instance = struct {
    name: u32,
    head: []const Var,
    bodies: []const Body,
};

pub const Fix = struct {
    /// The call's argument variables.
    args: []const Var,
    /// Instance of the called rule.
    target: usize,
    instances: []const Instance,
    /// Argument positions pushed into the target's bodies.
    pushed: []const usize,
    /// Arguments this step binds.
    fresh: []const Var,
};

fn planFix(ctx: *Ctx, name: u32, arg_vars: []const Var, src: ?ir.Src, bound: *const Bound, rows: u64) Failure!Fix {
    const info = try ctx.ruleInfo();
    // The fixpoint only adds rows, which is sound for stratified rules
    // alone: a rule that depends on its own negation has no answer it
    // could reach.
    if (info.negated[info.scc_of[info.nameIndex(name).?]]) return ctx.syntaxFmt("{s} recurses through not; a rule cannot depend on the negation of itself", .{ctx.interner.symbolName(name)});
    const members = try info.members(ctx.arena, name);

    var pushed: std.ArrayList(usize) = .empty;
    if (members.len == 1) {
        for (arg_vars, 0..) |v, i| {
            if (bound.has(v) and try passThrough(ctx.arena, ctx.rules, name, i)) try pushed.append(ctx.arena, i);
        }
    }

    const instances = try ctx.arena.alloc(Instance, members.len);
    var target: usize = 0;
    for (members, instances, 0..) |m, *inst, idx| {
        const iname = info.names[m];
        if (iname == name) target = idx;
        const defs = ctx.rules.byName(iname).?;
        const head = try ctx.arena.alloc(Var, defs[0].head.len);
        for (defs[0].head, head) |rv, *pv| pv.* = try ctx.freshVar(ctx.rules.vars[rv].sym);
        inst.* = .{ .name = iname, .head = head, .bodies = &.{} };
    }
    const scc_names = try ctx.arena.alloc(u32, members.len);
    for (members, scc_names) |m, *s| s.* = info.names[m];

    for (instances, 0..) |*inst, idx| {
        const defs = ctx.rules.byName(inst.name).?;
        const bodies = try ctx.arena.alloc(Body, defs.len);
        var input: std.ArrayList(Var) = .empty;
        if (idx == target) {
            for (pushed.items) |pos| try input.append(ctx.arena, inst.head[pos]);
        }
        for (defs, bodies) |def, *body| {
            var r = try Renamer.init(ctx, inst.head, def, .{ .names = scc_names, .instances = instances }, src);
            const clauses = try r.clauses(def.body);
            body.* = .{
                .plan = try plan_mod.planSub(ctx, clauses, input.items, rows),
                .sites = try r.sites.toOwnedSlice(ctx.arena),
            };
        }
        inst.bodies = bodies;
    }

    return .{
        .args = arg_vars,
        .target = target,
        .instances = instances,
        .pushed = try pushed.toOwnedSlice(ctx.arena),
        .fresh = try plan_mod.newVars(ctx.arena, arg_vars, bound),
    };
}

/// Copies a rule body into plan variables: head variables map to the
/// call's arguments, every other rule variable to a fresh plan
/// variable; calls to component members become `source` clauses; a
/// clause that names no source reads the call's.
const Renamer = struct {
    ctx: *Ctx,
    map: []?Var,
    scc: ?Scc,
    /// The call's data source; the body's default.
    src: ?ir.Src,
    sites: std.ArrayList(CallSite) = .empty,

    const Scc = struct {
        names: []const u32,
        instances: []const Instance,
    };

    fn init(ctx: *Ctx, call_args: []const Var, def: ir.Rule, scc: ?Scc, src: ?ir.Src) !Renamer {
        const map = try ctx.arena.alloc(?Var, ctx.rules.vars.len);
        @memset(map, null);
        for (def.head, call_args) |h, a| map[h] = a;
        return .{ .ctx = ctx, .map = map, .scc = scc, .src = src };
    }

    fn v(self: *Renamer, rv: Var) !Var {
        if (self.map[rv]) |pv| return pv;
        const pv = try self.ctx.freshVar(self.ctx.rules.vars[rv].sym);
        self.map[rv] = pv;
        return pv;
    }

    fn optVar(self: *Renamer, rv: ?Var) !?Var {
        return if (rv) |x| try self.v(x) else null;
    }

    fn vars(self: *Renamer, rvs: []const Var) ![]Var {
        const out = try self.ctx.arena.alloc(Var, rvs.len);
        for (rvs, out) |rv, *pv| pv.* = try self.v(rv);
        return out;
    }

    fn term(self: *Renamer, t: ir.Term) !ir.Term {
        return switch (t) {
            .variable => |rv| .{ .variable = try self.v(rv) },
            else => t,
        };
    }

    fn args(self: *Renamer, as: []const ir.Arg) ![]ir.Arg {
        const out = try self.ctx.arena.alloc(ir.Arg, as.len);
        for (as, out) |a, *o| o.* = switch (a) {
            .variable => |rv| .{ .variable = try self.v(rv) },
            .src => |x| .{ .src = x orelse self.src },
            .constant => a,
        };
        return out;
    }

    fn call(self: *Renamer, c: ir.Call) !ir.Call {
        const f: ir.FnRef = switch (c.f) {
            .variable => |rv| .{ .variable = try self.v(rv) },
            else => c.f,
        };
        return .{ .f = f, .args = try self.args(c.args) };
    }

    fn binding(self: *Renamer, b: ir.Binding) !ir.Binding {
        return switch (b) {
            .scalar => |rv| .{ .scalar = try self.v(rv) },
            .collection => |rv| .{ .collection = try self.v(rv) },
            .tuple => |ts| .{ .tuple = try self.optVars(ts) },
            .relation => |ts| .{ .relation = try self.optVars(ts) },
        };
    }

    fn optVars(self: *Renamer, ts: []const ?Var) ![]?Var {
        const out = try self.ctx.arena.alloc(?Var, ts.len);
        for (ts, out) |t, *o| o.* = try self.optVar(t);
        return out;
    }

    fn clauses(self: *Renamer, cs: []const Clause) Failure![]Clause {
        var out: std.ArrayList(Clause) = .empty;
        for (cs) |c| try self.clause(c, &out);
        return out.toOwnedSlice(self.ctx.arena);
    }

    fn clause(self: *Renamer, c: Clause, out: *std.ArrayList(Clause)) Failure!void {
        try stack.check();
        const arena = self.ctx.arena;
        switch (c) {
            .pattern => |p| try out.append(arena, .{ .pattern = .{
                .src = p.src orelse self.src,
                .e = try self.term(p.e),
                .a = try self.term(p.a),
                .v = try self.term(p.v),
                .tx = try self.term(p.tx),
                .added = try self.term(p.added),
            } }),
            .pred => |call_| try out.append(arena, .{ .pred = try self.call(call_) }),
            .bind => |b| try out.append(arena, .{ .bind = .{ .call = try self.call(b.call), .out = try self.binding(b.out) } }),
            .not => |n| try out.append(arena, .{ .not = .{
                .join = if (n.join) |js| try self.vars(js) else null,
                .body = try self.clauses(n.body),
            } }),
            .@"or" => |o| {
                const branches = try arena.alloc(ir.Branch, o.branches.len);
                for (o.branches, branches) |br, *nb| nb.* = try self.clauses(br);
                try out.append(arena, .{ .@"or" = .{ .join = if (o.join) |js| try self.vars(js) else null, .branches = branches, .required = try self.vars(o.required) } });
            },
            .rule => |r| {
                const renamed = try self.args(r.args);
                if (self.scc) |scc| {
                    for (scc.names, 0..) |n, idx| {
                        if (n != r.name) continue;
                        // A recursive call: ground constants, then join with the instance's rows.
                        const svars = try arena.alloc(Var, renamed.len);
                        for (renamed, svars) |a, *sv| sv.* = switch (a) {
                            .variable => |pv| pv,
                            .constant => |cell| blk: {
                                const g = try groundConst(self.ctx, cell);
                                try out.append(arena, g);
                                break :blk g.bind.out.scalar;
                            },
                            .src => return self.ctx.syntax("$ cannot be a rule argument"),
                        };
                        const slot = try arena.create(plan_mod.SourceSlot);
                        slot.* = .{};
                        const id = self.ctx.sources.items.len;
                        try self.ctx.sources.append(arena, slot);
                        try self.sites.append(arena, .{ .slot = slot, .callee = idx });
                        try out.append(arena, .{ .source = .{ .id = id, .vars = svars } });
                        return;
                    }
                }
                try out.append(arena, .{ .rule = .{ .name = r.name, .args = renamed, .src = r.src orelse self.src } });
            },
            .source => |s| try out.append(arena, .{ .source = .{ .id = s.id, .vars = try self.vars(s.vars) } }),
        }
    }
};

// =============================================================================
// Execution
// =============================================================================

/// Run the fixpoint of `fix` and join its result with `rel`.
pub fn execFix(ex: *exec_mod.Exec, fix: *const Fix, rel: Relation) anyerror!Relation {
    const arena = ex.arena;
    const n = fix.instances.len;
    const totals = try arena.alloc(*relation.Accumulator, n);
    const deltas = try arena.alloc(Relation, n);
    const inputs = try arena.alloc(Relation, n);
    for (fix.instances, 0..) |inst, i| {
        totals[i] = try relation.Accumulator.create(arena, inst.head);
        deltas[i] = try Relation.init(arena, inst.head);
        inputs[i] = try Relation.unit(arena);
    }
    if (fix.pushed.len > 0) {
        const target = fix.instances[fix.target];
        const arg_vars = try arena.alloc(Var, fix.pushed.len);
        const head_vars = try arena.alloc(Var, fix.pushed.len);
        for (fix.pushed, arg_vars, head_vars) |pos, *a, *h| {
            a.* = fix.args[pos];
            h.* = target.head[pos];
        }
        const projected = try rel.project(arg_vars, true);
        inputs[fix.target] = .{ .arena = arena, .vars = head_vars, .cols = projected.cols, .rows = projected.rows };
    }

    // Base bodies.
    for (fix.instances, 0..) |inst, i| {
        for (inst.bodies) |body| {
            if (body.sites.len > 0) continue;
            const r = try ex.runPlan(body.plan, inputs[i]);
            try absorb(totals[i], &deltas[i], &r);
        }
    }

    // Semi-naive rounds.
    while (true) {
        const news = try arena.alloc(Relation, n);
        for (fix.instances, 0..) |inst, i| news[i] = try Relation.init(arena, inst.head);
        var any = false;
        for (fix.instances, 0..) |inst, i| {
            for (inst.bodies) |body| {
                if (body.sites.len == 0) continue;
                for (body.sites, 0..) |_, k| {
                    for (body.sites, 0..) |site, j| {
                        site.slot.rel = if (j == k) &deltas[site.callee] else &totals[site.callee].rel;
                    }
                    if (deltas[body.sites[k].callee].rows == 0) continue;
                    const r = try ex.runPlan(body.plan, inputs[i]);
                    try absorb(totals[i], &news[i], &r);
                }
            }
        }
        for (news) |nr| if (nr.rows > 0) {
            any = true;
        };
        if (!any) break;
        for (news, deltas) |nr, *d| d.* = nr;
    }

    // Rename the target's rows to the call's arguments.
    const result = try Relation.viewAs(arena, fix.args, &totals[fix.target].rel);
    return rel.hashJoin(&result);
}

/// Add the rows of `r` (over the accumulator's variables) to `total`,
/// appending the ones that were new to `fresh`.
fn absorb(total: *relation.Accumulator, fresh: *Relation, r: *const Relation) !void {
    const map = try total.rel.mapFrom(r);
    const fmap = try fresh.mapFrom(r);
    var i: usize = 0;
    while (i < r.rows) : (i += 1) {
        if (try total.add(r, i, map)) try fresh.appendFrom(r, i, fmap);
    }
}

// =============================================================================
// Explain
// =============================================================================

/// The fix step's own line: the target rule, its arguments, how many
/// positions are pushed down and how many rules the component holds.
pub fn explainFix(f: *const Fix, ctx: *const Ctx, w: *std.Io.Writer) !void {
    try w.print("fix {s} [", .{ctx.interner.symbolName(f.instances[f.target].name)});
    for (f.args, 0..) |v, i| {
        if (i > 0) try w.writeByte(' ');
        try w.writeAll(ctx.varName(v));
    }
    try w.print("] pushed={d} instances={d}", .{ f.pushed.len, f.instances.len });
}

/// The lines of every body of every rule in the component, under the
/// fix step.
pub fn explainFixBodies(f: *const Fix, ctx: *const Ctx, lines: anytype, depth: usize) !void {
    for (f.instances) |inst| {
        for (inst.bodies) |body| {
            var out: std.Io.Writer.Allocating = .init(ctx.arena);
            var i: usize = 0;
            while (i < depth) : (i += 1) try out.writer.writeAll("  ");
            try out.writer.print("{s} body {s}", .{ ctx.interner.symbolName(inst.name), if (body.sites.len == 0) "base" else "recursive" });
            try lines.append(ctx.arena, .{ .text = out.written() });
            try plan_mod.explainSub(body.plan, ctx, lines, depth + 1);
        }
    }
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "call graph: self loop, mutual recursion, acyclic" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const call = struct {
        fn c(name: u32) Clause {
            return .{ .rule = .{ .name = name, .args = &.{} } };
        }
    };
    const rules = [_]ir.Rule{
        .{ .name = 1, .required = 0, .head = &.{}, .body = &.{call.c(1)} },
        .{ .name = 2, .required = 0, .head = &.{}, .body = &.{call.c(3)} },
        .{ .name = 3, .required = 0, .head = &.{}, .body = &.{.{ .not = .{ .join = null, .body = &.{call.c(2)} } }} },
        .{ .name = 4, .required = 0, .head = &.{}, .body = &.{ call.c(1), call.c(2) } },
        .{ .name = 5, .required = 0, .head = &.{}, .body = &.{} },
    };
    const set: RuleSet = .{ .arena_state = null, .vars = &.{}, .rules = &rules };
    const info = try analyze(arena, &set);
    try testing.expect(info.isRecursive(1));
    try testing.expect(info.isRecursive(2) and info.isRecursive(3));
    try testing.expectEqual(info.scc_of[info.nameIndex(2).?], info.scc_of[info.nameIndex(3).?]);
    try testing.expect(!info.isRecursive(4));
    try testing.expect(!info.isRecursive(5));
    try testing.expectEqual(@as(usize, 2), (try info.members(arena, 2)).len);
    // 3 calls 2 under `not` and 2 calls 3: not stratified; 1 is.
    try testing.expect(info.negated[info.scc_of[info.nameIndex(2).?]]);
    try testing.expect(!info.negated[info.scc_of[info.nameIndex(1).?]]);
    try testing.expect(!info.negated[info.scc_of[info.nameIndex(4).?]]);
}

test "a call chain past the stack guard is StackOverflow" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // r0 calls r1 calls r2 ... : one frame per rule in the analysis.
    const n = 5000;
    const rules = try arena.alloc(ir.Rule, n);
    for (rules, 0..) |*r, i| {
        const body: []const Clause = if (i + 1 < n) try arena.dupe(Clause, &.{.{ .rule = .{ .name = @intCast(i + 1), .args = &.{} } }}) else &.{};
        r.* = .{ .name = @intCast(i), .required = 0, .head = &.{}, .body = body };
    }
    const set: RuleSet = .{ .arena_state = null, .vars = &.{}, .rules = rules };
    stack.arm(64 * 1024);
    defer stack.arm(stack.main_thread_budget);
    try testing.expectError(error.StackOverflow, analyze(arena, &set));
}

test "pass-through positions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // reach(?a ?b) :- edge(?a ?b); reach(?a ?b) :- reach(?a ?m) edge(?m ?b)
    const rules = [_]ir.Rule{
        .{ .name = 1, .required = 0, .head = &.{ 0, 1 }, .body = &.{.{ .pattern = .{ .e = .{ .variable = 0 }, .a = .blank, .v = .{ .variable = 1 } } }} },
        .{ .name = 1, .required = 0, .head = &.{ 0, 1 }, .body = &.{
            .{ .rule = .{ .name = 1, .args = &.{ .{ .variable = 0 }, .{ .variable = 2 } } } },
            .{ .pattern = .{ .e = .{ .variable = 2 }, .a = .blank, .v = .{ .variable = 1 } } },
        } },
    };
    const set: RuleSet = .{ .arena_state = null, .vars = &.{}, .rules = &rules };
    try testing.expect(try passThrough(arena, &set, 1, 0));
    try testing.expect(!try passThrough(arena, &set, 1, 1));
}
