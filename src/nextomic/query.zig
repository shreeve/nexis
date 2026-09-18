//! query.zig — the query pipeline's module root (NEXTOMIC.md §5).
//!
//! Parse (`query/parse.zig`) turns a query value into an `Ir`; plan
//! (`query/plan.zig`) resolves it against one `Read` and orders the
//! steps; exec (`query/exec.zig`) runs the plan and materialises the
//! result into the VM heap; rules (`query/rules.zig`) expand rule
//! calls. `q` below is the one-call entry point the natives use.

pub const ir = @import("query/ir.zig");
pub const parse = @import("query/parse.zig");

pub const Ir = ir.Ir;
pub const RuleSet = ir.RuleSet;
pub const Diag = parse.Diag;
pub const Cache = parse.Cache;
pub const RulesCache = parse.RulesCache;

test {
    _ = ir;
    _ = parse;
}
