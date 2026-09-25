//! query.zig — the query pipeline's module root (NEXTOMIC.md §5).
//!
//! Parse (`query/parse.zig`) turns a query value into an `Ir`; plan
//! (`query/plan.zig`) resolves it against one `Read` and orders the
//! steps; exec (`query/exec.zig`) runs the plan and materialises the
//! result into the VM heap; rules (`query/rules.zig`) expand rule
//! calls. `q` is the one-call entry point: it opens one `Read` per
//! data source, runs the whole pipeline in one arena, closes the
//! `Read`s on every path and returns the result value. `explain`
//! prints the plan instead.

const std = @import("std");
const value = @import("../value.zig");
const heap_mod = @import("../heap.zig");
const intern_mod = @import("../intern.zig");
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
pub const Roots = parse.Roots;
pub const Plan = plan.Plan;
pub const CallHook = exec.CallHook;
pub const Exec = exec.Exec;

pub const Options = struct {
    hook: ?CallHook = null,
    /// The db-value a `$name` source after `$` is bound to, from its
    /// input; without it a query with a second source is refused.
    db_of: ?*const fn (v: Value) anyerror!DbValue = null,
    /// Parsed queries are looked up here when given; otherwise parsed
    /// afresh and freed after the run.
    ir_cache: ?*Cache = null,
    rules_cache: ?*RulesCache = null,
};

/// The parsed query and, when `:in` has `%`, its rule set: pinned in
/// the caches when given (released by `deinit`), else owned here.
const Parsed = struct {
    query: *Ir,
    rules: *const RuleSet = &ir.no_rules,
    options: Options,

    fn deinit(self: *Parsed) void {
        if (self.options.ir_cache) |c| c.release(self.query) else self.query.deinit();
        if (self.rules == &ir.no_rules) return;
        if (self.options.rules_cache) |c| c.release(self.rules) else @constCast(self.rules).deinit();
    }
};

fn parseAll(gpa: Allocator, interner: *Interner, query: Value, args: []const Value, diag: *Diag, options: Options) !Parsed {
    var out: Parsed = .{
        .query = if (options.ir_cache) |c| try c.acquire(interner, query, diag) else try parse.parse(gpa, interner, query, diag),
        .options = options,
    };
    errdefer out.deinit();
    if (args.len != out.query.in.len) {
        diag.* = .{ .message = "wrong number of inputs" };
        return error.QuerySyntax;
    }
    for (out.query.in, args) |b, a| {
        if (b != .rules) continue;
        out.rules = if (options.rules_cache) |c| try c.acquire(interner, a, diag) else try parse.parseRules(gpa, interner, a, diag);
    }
    return out;
}

/// One `Read` per data source, `$` first, open together and closed
/// together.
const Reads = struct {
    items: []*db_mod.Read,

    /// `db`, when given, is `$`; every other source comes from its
    /// input through `options.db_of`.
    fn open(arena: Allocator, db: ?DbValue, query: *const Ir, args: []const Value, options: Options, diag: *Diag) !Reads {
        const items = try arena.alloc(*db_mod.Read, query.sources.len);
        var opened: usize = 0;
        errdefer for (items[0..opened]) |r| r.close();
        for (query.in, args) |b, a| {
            if (b != .src) continue;
            const d: DbValue = if (b.src == 0 and db != null) db.? else blk: {
                const db_of = options.db_of orelse {
                    diag.* = .{ .message = "a data source after $ takes a db value" };
                    return error.QuerySyntax;
                };
                break :blk try db_of(a);
            };
            const r = try arena.create(db_mod.Read);
            r.* = try d.beginRead();
            items[b.src] = r;
            opened += 1;
        }
        return .{ .items = items };
    }

    fn close(self: Reads) void {
        for (self.items) |r| r.close();
    }
};

/// Run `query` with `args` positional to its `:in`: a source position
/// carries a db value, the `%` position the rules. `db`, when given,
/// is `$` in place of its input. The result lives in `heap`.
pub fn q(gpa: Allocator, interner: *Interner, heap: *Heap, query: Value, db: ?DbValue, args: []const Value, diag: *Diag, options: Options) anyerror!Value {
    var parsed = try parseAll(gpa, interner, query, args, diag, options);
    defer parsed.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const reads = try Reads.open(arena, db, parsed.query, args, options, diag);
    defer reads.close();

    var ctx = try plan.Ctx.init(arena, reads.items, interner, parsed.query, parsed.rules, diag);
    const p = try plan.plan(&ctx, parsed.query);
    var ex = exec.Exec{ .arena = arena, .reads = reads.items, .heap = heap, .interner = interner, .hook = options.hook, .diag = diag };
    const input = try ex.inputRelation(parsed.query, args);
    const rel = try ex.runPlan(p, input);
    const rows = try ex.findRows(parsed.query, rel);
    return ex.materialise(parsed.query, rows);
}

/// Print the plan of `query` against `db` to `w`.
pub fn explain(gpa: Allocator, interner: *Interner, query: Value, db: ?DbValue, args: []const Value, diag: *Diag, options: Options, w: *std.Io.Writer) anyerror!void {
    var parsed = try parseAll(gpa, interner, query, args, diag, options);
    defer parsed.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const reads = try Reads.open(arena, db, parsed.query, args, options, diag);
    defer reads.close();

    var ctx = try plan.Ctx.init(arena, reads.items, interner, parsed.query, parsed.rules, diag);
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
