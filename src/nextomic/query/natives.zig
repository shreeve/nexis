//! query/natives.zig — `nextomic/q` and `nextomic/explain` (NEXTOMIC.md
//! §5, §6), rows of `natives.table`.
//!
//! `(q query & inputs)` runs `query.q` and returns the materialised
//! result; `(explain query & inputs)` returns the plan as a string.
//! The inputs follow `:in` positionally (`[$]` when the query has no
//! `:in`): a db value or a collection of tuples for each source, the
//! rules for `%`, and values
//! for `?x`, `[?x ...]`, `[?a ?b]` and `[[?a ?b]]`. The arg-map form
//! `(q {:query query :args [inputs...]})` is the same call.
//!
//! Caches: one IR cache and one rules cache per VM, on the natives'
//! per-VM state (`natives.state`). A parsed query is pure syntax over
//! the VM's symbol table, so one cache serves every connection the VM
//! opens. The caches hold the query values themselves, rooted, and pin
//! the parse a running query uses, so a nested `q` in a callback can
//! neither free nor replace it (NEXTOMIC.md §5 "Parse").
//!
//! Rooting: a value the pipeline keeps in a relation cell or a group
//! (a function's result it binds, a custom aggregate's result, a
//! `tuple` bound as one value, an aggregate's vector or set) must
//! survive the next call back into the VM, so `keep` and `root` push
//! it on a root scope that lives as long as the `q` call (GC.md
//! §11.5). An immediate needs no root and is not pushed, nor is a
//! predicate's result, which is tested and dropped unrealized.
//!
//! Functions: a predicate, function-binding or custom aggregate symbol
//! that is not a built-in resolves through the namespace registry the
//! way the compiler resolves a symbol (an alias-qualified `ns/name` to
//! that namespace's own var; a bare name in the current namespace, then
//! its auto-referred parents), once per query before any row runs, and
//! is called through `VM.callValue` with the clause's arguments as
//! values. A `?variable` in function
//! position applies the value it holds: a function through
//! `VM.callValue`, a keyword or collection as the language applies
//! them, anything else `:not-callable`. Whatever that call raises
//! propagates untouched: a throw inside a predicate reaches the
//! caller's `try` as the thrown value after `query.q` has closed its
//! `Read`, and `ControlTransferred` passes through unchanged.
//!
//! Errors go through `natives.wrapDiag`, shared with pull: `QuerySyntax`
//! throws `{:error :nextomic/query-syntax :message "..." :clause i}`
//! (`:clause` only when the parser was inside a `:where` clause), so the
//! reason travels with the throw, and `PullSyntax` from a pull find
//! element the `:nextomic/pull-syntax` map the same way; every other
//! error takes the `natives.zig` keyword. VM errors pass through.

const std = @import("std");
const value = @import("../../value.zig");
const vm_mod = @import("../../vm.zig");
const random_mod = @import("../../random.zig");
const string_mod = @import("../../string.zig");
const champ = @import("../../coll/champ.zig");
const dispatch = @import("../../dispatch.zig");
const natives = @import("../natives.zig");
const marshal = @import("../marshal.zig");
const query = @import("../query.zig");
const seq_mod = @import("../../seq.zig");

const Value = value.Value;
const VM = vm_mod.VM;
const Var = vm_mod.Var;
const Diag = query.Diag;

// =============================================================================
// The call hook
// =============================================================================

const Hook = struct {
    vm: *VM,
    /// Roots every value the pipeline keeps, for the query's life.
    scope: vm_mod.RootScope,

    fn init(vm: *VM) Hook {
        return .{ .vm = vm, .scope = vm.rootScope() };
    }

    fn deinit(self: *Hook) void {
        self.scope.release();
    }

    fn callHook(self: *Hook) query.CallHook {
        return .{ .ctx = @ptrCast(self), .resolve = &resolve, .apply = &apply, .keep = &keep, .root = &root };
    }

    /// A function's result the query binds or aggregates, realized and
    /// made lists as the query's inputs are (docs/LAZY.md §8), rooted
    /// for the query's life.
    fn keep(ctx: *anyopaque, r: Value) anyerror!Value {
        const self: *Hook = @ptrCast(@alignCast(ctx));
        if (!r.kind().isHeap()) return r;
        try self.scope.push(r);
        const l = try seq_mod.asLists(self.vm, r);
        if (!l.identicalTo(r)) try self.scope.push(l);
        return l;
    }

    fn root(ctx: *anyopaque, v: Value) anyerror!void {
        const self: *Hook = @ptrCast(@alignCast(ctx));
        if (v.kind().isHeap()) try self.scope.push(v);
    }

    /// Apply the value a variable in function position holds: a
    /// function, or a keyword or collection looked up as the language
    /// applies them; anything else is the VM's `:not-callable`.
    fn apply(ctx: *anyopaque, f: Value, args: []const Value) anyerror!Value {
        const self: *Hook = @ptrCast(@alignCast(ctx));
        if (vm_mod.isLookupCallable(f.kind())) return vm_mod.callLookupIn(self.vm, f, args);
        return self.vm.callValue(f, args);
    }

    /// The bound value the symbol names, rooted for the query's life
    /// (a later call may rebind the Var), or a thrown
    /// `:nextomic/query-syntax` naming what is missing.
    fn resolve(ctx: *anyopaque, sym: u32) anyerror!Value {
        const self: *Hook = @ptrCast(@alignCast(ctx));
        const vm = self.vm;
        if (try lookup(vm, sym)) |v| {
            try root(ctx, v);
            return v;
        }
        const message = try vm.allocator.print("unknown function: {s}", .{vm.ensureInterner().symbolName(sym)});
        defer vm.allocator.free(message);
        return natives.throwSyntax(vm, "nextomic/query-syntax", message, null);
    }
};

/// The bound value the symbol names as the compiler resolves it: an
/// alias-qualified `ns/name` to that namespace's own var, a bare name
/// in the current namespace and then its auto-referred parents; null
/// when nothing is bound.
pub fn lookup(vm: *VM, sym: u32) !?Value {
    const name = vm.ensureInterner().symbolName(sym);
    const registry = try vm.ensureRegistry();
    const current = registry.current;
    const found: ?*Var = blk: {
        if (splitQualified(name)) |q| {
            const ns_name = current.lookupAlias(q.ns) orelse q.ns;
            const ns = registry.lookupNs(ns_name) orelse break :blk null;
            break :blk ns.lookupLocal(q.name);
        }
        break :blk current.lookup(name);
    };
    if (found) |v| if (v.bound) return v.root;
    return null;
}

const Qualified = struct { ns: []const u8, name: []const u8 };

/// `ns/name` split at its first `/`; null for a bare name, for `/`
/// itself and for a name with nothing on one side of the slash.
fn splitQualified(name: []const u8) ?Qualified {
    const i = std.mem.findScalar(u8, name, '/') orelse return null;
    if (i == 0 or i + 1 == name.len) return null;
    return .{ .ns = name[0..i], .name = name[i + 1 ..] };
}

// =============================================================================
// q, explain
// =============================================================================

pub const fnQ = natives.wrapDiag(qNative);

fn qNative(vm: *VM, call_args: []const Value, diag: *Diag) !Value {
    var arena_state = std.heap.ArenaAllocator.init(vm.allocator);
    defer arena_state.deinit();
    const args = try argMap(vm, arena_state.allocator(), call_args, diag) orelse call_args;
    var hook = Hook.init(vm);
    defer hook.deinit();
    return query.q(vm.allocator, vm.ensureInterner(), vm.ensureHeap(), args[0], null, args[1..], diag, try options(vm, hook.callHook()));
}

pub const fnExplain = natives.wrapDiag(explainNative);

/// The plan `q` would run, as a string; it calls no function.
fn explainNative(vm: *VM, call_args: []const Value, diag: *Diag) !Value {
    var arena_state = std.heap.ArenaAllocator.init(vm.allocator);
    defer arena_state.deinit();
    const args = try argMap(vm, arena_state.allocator(), call_args, diag) orelse call_args;
    var out: std.Io.Writer.Allocating = .init(vm.allocator);
    defer out.deinit();
    try query.explain(vm.allocator, vm.ensureInterner(), args[0], null, args[1..], diag, try options(vm, null), &out.writer);
    return string_mod.fromBytes(vm.ensureHeap(), out.written());
}

/// The options of a query this VM runs: its caches and `hook`.
fn options(vm: *VM, hook: ?query.CallHook) !query.Options {
    const st = try natives.state(vm);
    return .{ .hook = hook, .db_of = &natives.dbOf, .ir_cache = &st.ir_cache, .rules_cache = &st.rules_cache, .random = random_mod.shared(vm.io orelse std.Io.Threaded.global_single_threaded.io()) };
}

/// The arguments an arg-map call `(q {:query q :args [...]})` stands
/// for, `[q ...]`; null when the call is not one. A map is an arg-map
/// when it has `:query`; its other keys are `:args` and Datomic's
/// `:timeout` and `:io-context`, which are ignored so that code written
/// for Datomic runs (a query here is one read in the caller's thread,
/// with no timer to arm and no I/O to attribute), and anything else is
/// `:nextomic/query-syntax`.
fn argMap(vm: *VM, arena: std.mem.Allocator, args: []const Value, diag: *Diag) !?[]const Value {
    if (args.len != 1 or args[0].kind() != .persistent_map) return null;
    const it = vm.ensureInterner();
    const k_query = try it.internKeywordValue("query");
    const k_args = try it.internKeywordValue("args");
    const ignored = [_]Value{ try it.internKeywordValue("timeout"), try it.internKeywordValue("io-context") };
    const query_v = switch (champ.mapGet(args[0], k_query, &dispatch.hashValue, &dispatch.equal)) {
        .present => |v| v,
        .absent => return null,
    };
    var inputs: []const Value = &.{};
    var keys = champ.mapIter(args[0]);
    while (keys.next()) |e| {
        if (dispatch.equal(e.key, k_query) or dispatch.equal(e.key, ignored[0]) or dispatch.equal(e.key, ignored[1])) continue;
        if (!dispatch.equal(e.key, k_args)) {
            diag.* = .{ .message = "an arg-map takes :query and :args, and ignores :timeout and :io-context" };
            return error.QuerySyntax;
        }
        inputs = (try marshal.sequence(arena, e.value)) orelse {
            diag.* = .{ .message = ":args is a vector of the query's inputs" };
            return error.QuerySyntax;
        };
    }
    const out = try arena.alloc(Value, inputs.len + 1);
    out[0] = query_v;
    @memcpy(out[1..], inputs);
    return out;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "qualified names split at the first slash" {
    try testing.expect(splitQualified("str") == null);
    try testing.expect(splitQualified("/") == null);
    try testing.expect(splitQualified("ns/") == null);
    try testing.expect(splitQualified("/x") == null);
    const q = splitQualified("nexis.string/upper-case").?;
    try testing.expectEqualStrings("nexis.string", q.ns);
    try testing.expectEqualStrings("upper-case", q.name);
    const d = splitQualified("d/a/b").?;
    try testing.expectEqualStrings("d", d.ns);
    try testing.expectEqualStrings("a/b", d.name);
}
