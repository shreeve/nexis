//! query.zig — the query pipeline's module root (NEXTOMIC.md §5).
//!
//! Parse (`query/parse.zig`) turns a query value into an `Ir`; plan
//! (`query/plan.zig`) resolves it against one `Read` and orders the
//! steps; exec (`query/exec.zig`) runs the plan and materialises the
//! result into the VM heap; rules (`query/rules.zig`) expand rule
//! calls. `q` is the one-call entry point: it opens the `Read`, runs
//! the whole pipeline in one arena, closes the `Read` on every path
//! and returns the result value. `explain` prints the plan instead.

const std = @import("std");
const value = @import("value");
const heap_mod = @import("heap");
const intern_mod = @import("intern");
const db_mod = @import("db.zig");

pub const ir = @import("query/ir.zig");
pub const parse = @import("query/parse.zig");
pub const plan = @import("query/plan.zig");
pub const exec = @import("query/exec.zig");
pub const rules = @import("query/rules.zig");

const Allocator = std.mem.Allocator;
const Value = value.Value;
const Heap = heap_mod.Heap;
const Interner = intern_mod.Interner;
const DbValue = db_mod.DbValue;

pub const Ir = ir.Ir;
pub const RuleSet = ir.RuleSet;
pub const Diag = parse.Diag;
pub const Cache = parse.Cache;
pub const RulesCache = parse.RulesCache;
pub const Plan = plan.Plan;
pub const CallHook = exec.CallHook;
pub const Exec = exec.Exec;

pub const Options = struct {
    hook: ?CallHook = null,
    /// Parsed queries are looked up here when given; otherwise parsed
    /// afresh and freed after the run.
    ir_cache: ?*Cache = null,
    rules_cache: ?*RulesCache = null,
};

/// The parsed query and, when `:in` has `%`, its rule set; owned by
/// the caches when given, else by this struct.
const Parsed = struct {
    gpa: Allocator,
    query: *Ir,
    rules: *const RuleSet,
    owns_query: bool,
    owns_rules: bool,

    fn deinit(self: *Parsed) void {
        if (self.owns_query) self.query.deinit();
        if (self.owns_rules) @constCast(self.rules).deinit();
    }
};

fn parseAll(gpa: Allocator, interner: *Interner, query: Value, args: []const Value, diag: *Diag, options: Options) !Parsed {
    var out: Parsed = .{ .gpa = gpa, .query = undefined, .rules = &ir.no_rules, .owns_query = false, .owns_rules = false };
    if (options.ir_cache) |c| {
        out.query = try c.get(interner, query, diag);
    } else {
        out.query = try parse.parse(gpa, interner, query, diag);
        out.owns_query = true;
    }
    errdefer if (out.owns_query) out.query.deinit();
    if (args.len != out.query.in.len) {
        diag.* = .{ .message = "wrong number of inputs" };
        return error.QuerySyntax;
    }
    for (out.query.in, args) |b, a| {
        if (b != .rules) continue;
        if (options.rules_cache) |c| {
            out.rules = try c.get(interner, a, diag);
        } else {
            out.rules = try parse.parseRules(gpa, interner, a, diag);
            out.owns_rules = true;
        }
    }
    return out;
}

/// Run `query` against `db` with `args` positional to its `:in` (the
/// `$` and `%` positions carry the db and the rules; pass anything
/// there). The result lives in `heap`.
pub fn q(gpa: Allocator, interner: *Interner, heap: *Heap, query: Value, db: DbValue, args: []const Value, diag: *Diag, options: Options) anyerror!Value {
    var parsed = try parseAll(gpa, interner, query, args, diag, options);
    defer parsed.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var read = try db.beginRead();
    defer read.close();

    var ctx = try plan.Ctx.init(arena, &read, interner, parsed.query, parsed.rules);
    const p = try plan.plan(&ctx, parsed.query);
    var ex = exec.Exec{ .arena = arena, .read = &read, .heap = heap, .interner = interner, .hook = options.hook };
    const input = try ex.inputRelation(parsed.query, args);
    const rel = try ex.runPlan(p, input);
    const rows = try ex.findRows(parsed.query, rel);
    return ex.materialise(parsed.query.find_spec, rows);
}

/// Print the plan of `query` against `db` to `w`.
pub fn explain(gpa: Allocator, interner: *Interner, query: Value, db: DbValue, args: []const Value, diag: *Diag, options: Options, w: *std.Io.Writer) anyerror!void {
    var parsed = try parseAll(gpa, interner, query, args, diag, options);
    defer parsed.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var read = try db.beginRead();
    defer read.close();

    var ctx = try plan.Ctx.init(arena, &read, interner, parsed.query, parsed.rules);
    const p = try plan.plan(&ctx, parsed.query);
    try plan.explain(p, &ctx, w);
}

test {
    _ = ir;
    _ = parse;
    _ = plan;
    _ = exec;
    _ = rules;
}
