//! query/ir.zig — the parsed query (NEXTOMIC.md §5 "Parse").
//!
//! An `Ir` is pure syntax with a symbol table: variables are dense
//! indexes into `vars`, constants are `Cell`s in the VM's terms, and
//! nothing in it depends on a store. Resolution against a db (idents,
//! lookup refs, attribute types, sortable encodings) happens in
//! `query/plan.zig`, so an `Ir` cached for a query value stays valid
//! for every db it is later run against. Invariants:
//!   - `vars[i].sym` is unique; every `Var` in the tree is `< vars.len`.
//!   - Every `find` and `with` variable is bound by some `in` binding
//!     or by some `where` clause (`parse.zig` checks this).
//!   - `sources[0]` is `$`; every explicit `Src` in the tree is
//!     `< sources.len`.
//!   - Everything hangs off `arena`; `deinit` frees it all.

const std = @import("std");
const value = @import("value");
const relation = @import("../relation.zig");

const Allocator = std.mem.Allocator;
const Value = value.Value;

pub const Var = relation.Var;
pub const Cell = relation.Cell;

/// A data source: the index of a `$` binding in `:in`, in order (`$`
/// itself is 0). A clause whose source is null reads the default
/// source: `$` at the top level, the call's source inside a rule body.
pub const Src = u32;

pub const VarInfo = struct {
    /// VM symbol intern id.
    sym: u32,
};

/// A lookup ref `[:attr v]`: attribute by VM keyword id.
pub const Lookup = struct {
    attr: u32,
    v: Cell,
};

pub const Constant = union(enum) {
    cell: Cell,
    lookup: Lookup,
};

/// A data-pattern position.
pub const Term = union(enum) {
    blank,
    variable: Var,
    constant: Constant,

    pub fn asVar(self: Term) ?Var {
        return if (self == .variable) self.variable else null;
    }
};

/// `[e a v]`, `[e a v tx]` or `[e a v tx added]`; absent trailing
/// positions are `blank`.
pub const Pattern = struct {
    src: ?Src = null,
    e: Term,
    a: Term,
    v: Term,
    tx: Term = .blank,
    added: Term = .blank,

    pub fn terms(self: *const Pattern) [5]Term {
        return .{ self.e, self.a, self.v, self.tx, self.added };
    }
};

pub const Builtin = enum {
    lt,
    le,
    gt,
    ge,
    eq,
    ne,
    missing,
    ground,
    get_else,
    tuple,
    untuple,

    pub fn name(self: Builtin) []const u8 {
        return switch (self) {
            .lt => "<",
            .le => "<=",
            .gt => ">",
            .ge => ">=",
            .eq => "=",
            .ne => "not=",
            .missing => "missing?",
            .ground => "ground",
            .get_else => "get-else",
            .tuple => "tuple",
            .untuple => "untuple",
        };
    }

    pub fn fromName(s: []const u8) ?Builtin {
        inline for (@typeInfo(Builtin).@"enum".fields) |f| {
            const b: Builtin = @enumFromInt(f.value);
            if (std.mem.eql(u8, s, b.name())) return b;
        }
        if (std.mem.eql(u8, s, "!=")) return .ne;
        return null;
    }
};

pub const FnRef = union(enum) {
    builtin: Builtin,
    /// VM symbol intern id, resolved by the caller's `CallHook`.
    user: u32,
    /// A variable whose cell is the function value: bound through
    /// `:in` or an earlier clause, applied by the `CallHook`.
    variable: Var,
};

/// A predicate or function argument.
pub const Arg = union(enum) {
    variable: Var,
    constant: Cell,
    /// A data source (`$`, `$2`); null is the default source.
    src: ?Src,
};

pub const Call = struct {
    f: FnRef,
    args: []const Arg,
};

/// How a function's result binds: `?x`, `[?a ?b]`, `[?x ...]`,
/// `[[?a ?b]]`. A `null` in a tuple is `_`.
pub const Binding = union(enum) {
    scalar: Var,
    tuple: []const ?Var,
    collection: Var,
    relation: []const ?Var,

    /// The variables the binding introduces.
    pub fn vars(self: Binding, arena: Allocator) ![]const Var {
        return switch (self) {
            .scalar, .collection => |v| try arena.dupe(Var, &.{v}),
            .tuple, .relation => |ts| blk: {
                var out: std.ArrayList(Var) = .empty;
                for (ts) |t| if (t) |v| try out.append(arena, v);
                break :blk try out.toOwnedSlice(arena);
            },
        };
    }
};

pub const Branch = []const Clause;

pub const Clause = union(enum) {
    pattern: Pattern,
    pred: Call,
    bind: struct { call: Call, out: Binding },
    /// `not` (join on the body's variables bound outside) or `not-join`
    /// (join on `join`).
    not: struct { join: ?[]const Var, body: []const Clause },
    /// `or` (every branch binds the same variables, all of which join)
    /// or `or-join` (join on `join`; other variables are branch-local).
    @"or": struct { join: ?[]const Var, branches: []const Branch },
    /// `(rule-name arg ...)` or `($src rule-name arg ...)`; the body's
    /// unprefixed clauses read `src` (null: the default source).
    rule: struct { name: u32, args: []const Arg, src: ?Src = null },
    /// A join with a relation supplied at run time, by slot id in the
    /// plan context; rule expansion replaces recursive calls with it.
    /// `vars` bind the relation's columns positionally.
    source: struct { id: usize, vars: []const Var },
};

pub const AggOp = enum {
    count,
    sum,
    min,
    max,
    avg,
    median,
    variance,
    stddev,
    count_distinct,
    distinct,
    sample,
    rand,
    /// A symbol that names no built-in: called through the `CallHook`
    /// with the vector of the group's values.
    custom,

    pub fn name(self: AggOp) []const u8 {
        return switch (self) {
            .count => "count",
            .sum => "sum",
            .min => "min",
            .max => "max",
            .avg => "avg",
            .median => "median",
            .variance => "variance",
            .stddev => "stddev",
            .count_distinct => "count-distinct",
            .distinct => "distinct",
            .sample => "sample",
            .rand => "rand",
            .custom => "custom",
        };
    }

    pub fn fromName(s: []const u8) ?AggOp {
        inline for (@typeInfo(AggOp).@"enum".fields) |f| {
            const op: AggOp = @enumFromInt(f.value);
            if (op != .custom and std.mem.eql(u8, s, op.name())) return op;
        }
        return null;
    }

    /// Does the aggregate take a leading count: `(op n ?x)`?
    pub fn takesN(self: AggOp) ?enum { required, optional } {
        return switch (self) {
            .sample, .rand => .required,
            .min, .max => .optional,
            else => null,
        };
    }
};

pub const Agg = struct {
    op: AggOp,
    arg: Var,
    /// The `n` of `(sample n ?x)`, `(rand n ?x)`, `(min n ?x)`, `(max n ?x)`.
    n: ?u32 = null,
    /// The symbol of a `custom` aggregate.
    sym: u32 = 0,
};

pub const FindElem = union(enum) {
    variable: Var,
    agg: Agg,
    /// `(pull ?e pattern)`: the pattern value is resolved against the
    /// db when the result is materialised; the element groups and
    /// dedups as its variable.
    pull: struct { e: Var, pattern: Value },

    pub fn variable_of(self: FindElem) Var {
        return switch (self) {
            .variable => |v| v,
            .agg => |a| a.arg,
            .pull => |p| p.e,
        };
    }
};

pub const FindSpec = enum { relation, scalar, collection, tuple };

/// `:keys`, `:strs` or `:syms`: one name per find element; the result
/// is a vector of maps under those names.
pub const Keys = struct {
    kind: enum { keyword, string, symbol },
    /// VM symbol intern ids, in find order.
    names: []const u32,
};

pub const InBinding = union(enum) {
    /// A data source, numbered by its position among the sources.
    src: Src,
    rules,
    scalar: Var,
    collection: Var,
    tuple: []const ?Var,
    relation: []const ?Var,
};

pub const Ir = struct {
    arena_state: std.heap.ArenaAllocator,
    vars: []const VarInfo,
    find_spec: FindSpec,
    find: []const FindElem,
    keys: ?Keys = null,
    with: []const Var,
    in: []const InBinding,
    /// VM symbol ids of the sources, by `Src`: `$` first.
    sources: []const u32,
    where: []const Clause,

    pub fn deinit(self: *Ir) void {
        const gpa = self.arena_state.child_allocator;
        self.arena_state.deinit();
        gpa.destroy(self);
    }

    pub fn arena(self: *Ir) Allocator {
        return self.arena_state.allocator();
    }

    pub fn hasAggregates(self: *const Ir) bool {
        for (self.find) |f| if (f == .agg) return true;
        return false;
    }
};

/// A rule `[(name [?req ...] ?arg ...) body...]`. Head variables are
/// the required ones first, in head order.
pub const Rule = struct {
    name: u32,
    /// Number of leading head variables that must be bound at a call.
    required: usize,
    head: []const Var,
    body: []const Clause,
};

/// A parsed `%` input. Rules have their own variable table; a call
/// site renames them into the plan's. Invariants:
///   - Rules with one name are contiguous in `rules`, in source order
///     (`parse.zig` groups them), so `byName` is one slice.
///   - A set with `arena_state` owns its rules and is freed by
///     `deinit`; one without (`no_rules`, or a set a test builds over
///     static rules) is not, and `deinit` is a no-op.
pub const RuleSet = struct {
    arena_state: ?std.heap.ArenaAllocator,
    vars: []const VarInfo,
    rules: []const Rule,

    pub fn deinit(self: *RuleSet) void {
        if (self.arena_state) |*state| {
            const gpa = state.child_allocator;
            state.deinit();
            gpa.destroy(self);
        }
    }

    /// Every rule named `name`, or null.
    pub fn byName(self: *const RuleSet, name: u32) ?[]const Rule {
        var lo: ?usize = null;
        var hi: usize = 0;
        for (self.rules, 0..) |r, i| {
            if (r.name != name) continue;
            std.debug.assert(lo == null or hi == i);
            if (lo == null) lo = i;
            hi = i + 1;
        }
        const start = lo orelse return null;
        return self.rules[start..hi];
    }
};

/// The empty rule set, for queries without `%`.
pub const no_rules: RuleSet = .{
    .arena_state = null,
    .vars = &.{},
    .rules = &.{},
};

// =============================================================================
// Variable collection
// =============================================================================

/// Variables bound by evaluating `clauses` (patterns, function outputs,
/// `or` join variables, rule arguments); not `not` bodies.
pub fn boundVars(arena: Allocator, clauses: []const Clause, out: *std.ArrayList(Var)) !void {
    for (clauses) |c| switch (c) {
        .pattern => |p| for (p.terms()) |t| {
            if (t.asVar()) |v| try addVar(arena, out, v);
        },
        .pred => {},
        .bind => |b| for (try b.out.vars(arena)) |v| try addVar(arena, out, v),
        .not => {},
        .@"or" => |o| {
            if (o.join) |js| {
                for (js) |v| try addVar(arena, out, v);
            } else for (o.branches) |br| try boundVars(arena, br, out);
        },
        .rule => |r| for (r.args) |a| {
            if (a == .variable) try addVar(arena, out, a.variable);
        },
        .source => |s| for (s.vars) |v| try addVar(arena, out, v),
    };
}

/// Every variable mentioned anywhere in `clauses`, including predicate
/// arguments and `not` bodies.
pub fn allVars(arena: Allocator, clauses: []const Clause, out: *std.ArrayList(Var)) !void {
    for (clauses) |c| switch (c) {
        .pattern => |p| for (p.terms()) |t| {
            if (t.asVar()) |v| try addVar(arena, out, v);
        },
        .pred => |call| try callVars(arena, call, out),
        .bind => |b| {
            try callVars(arena, b.call, out);
            for (try b.out.vars(arena)) |v| try addVar(arena, out, v);
        },
        .not => |n| {
            if (n.join) |js| for (js) |v| try addVar(arena, out, v);
            try allVars(arena, n.body, out);
        },
        .@"or" => |o| {
            if (o.join) |js| for (js) |v| try addVar(arena, out, v);
            for (o.branches) |br| try allVars(arena, br, out);
        },
        .rule => |r| for (r.args) |a| {
            if (a == .variable) try addVar(arena, out, a.variable);
        },
        .source => |s| for (s.vars) |v| try addVar(arena, out, v),
    };
}

fn callVars(arena: Allocator, call: Call, out: *std.ArrayList(Var)) !void {
    if (call.f == .variable) try addVar(arena, out, call.f.variable);
    for (call.args) |a| {
        if (a == .variable) try addVar(arena, out, a.variable);
    }
}

pub fn addVar(arena: Allocator, out: *std.ArrayList(Var), v: Var) !void {
    for (out.items) |x| if (x == v) return;
    try out.append(arena, v);
}

pub fn containsVar(vars: []const Var, v: Var) bool {
    for (vars) |x| if (x == v) return true;
    return false;
}

test "binding vars and var collection" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const b: Binding = .{ .tuple = &.{ 1, null, 3 } };
    try std.testing.expectEqualSlices(Var, &.{ 1, 3 }, try b.vars(arena));
    const clauses = [_]Clause{
        .{ .pattern = .{ .e = .{ .variable = 0 }, .a = .{ .constant = .{ .cell = .{ .keyword = 9 } } }, .v = .{ .variable = 1 } } },
        .{ .pred = .{ .f = .{ .builtin = .lt }, .args = &.{ .{ .variable = 1 }, .{ .constant = .{ .int = 3 } } } } },
        .{ .not = .{ .join = null, .body = &.{.{ .pattern = .{ .e = .{ .variable = 0 }, .a = .blank, .v = .{ .variable = 7 } } }} } },
    };
    var bound: std.ArrayList(Var) = .empty;
    try boundVars(arena, &clauses, &bound);
    try std.testing.expectEqualSlices(Var, &.{ 0, 1 }, bound.items);
    var all: std.ArrayList(Var) = .empty;
    try allVars(arena, &clauses, &all);
    try std.testing.expectEqualSlices(Var, &.{ 0, 1, 7 }, all.items);
    try std.testing.expectEqual(Builtin.ne, Builtin.fromName("!=").?);
    try std.testing.expectEqual(AggOp.count_distinct, AggOp.fromName("count-distinct").?);
}
