//! query/natives.zig — `nextomic/q` and `nextomic/explain` (NEXTOMIC.md
//! §5, §6).
//!
//! `(q query & inputs)` runs `query.q` and returns the materialised
//! result; `(explain query & inputs)` returns the plan as a string.
//! The inputs follow `:in` positionally (`[$]` when the query has no
//! `:in`): a db value for each source, the rules for `%`, and values
//! for `?x`, `[?x ...]`, `[?a ?b]` and `[[?a ?b]]`.
//!
//! Caches: one IR cache and one rules cache per VM, on the natives'
//! per-VM state (`natives.state`). A parsed query is pure syntax over
//! the VM's symbol table, so one cache serves every connection the VM
//! opens. The caches hold the query values themselves, rooted, and pin
//! the parse a running query uses, so a nested `q` in a callback can
//! neither free nor replace it (NEXTOMIC.md §5 "Parse").
//!
//! Rooting: a value a user function returns to the pipeline may end up
//! in a relation cell that the next call back into the VM must not see
//! collected, so the hook pushes every result on a root scope that
//! lives as long as the `q` call (GC.md §3); `root` pushes the heap
//! values the pipeline builds itself (a `tuple` bound as one value, an
//! aggregate's vector or set) the same way.
//!
//! Functions: a predicate or function-binding symbol that is not a
//! built-in resolves through the namespace registry the way the
//! compiler resolves a symbol (an alias-qualified `ns/name` to that
//! namespace's own var; a bare name in the current namespace, then its
//! auto-referred parents) and is called through `VM.callValue` with
//! the clause's arguments as values. A `?variable` in function
//! position applies the value it holds: a function through
//! `VM.callValue`, a keyword or collection as the language applies
//! them, anything else `:not-callable`. Whatever that call raises
//! propagates untouched: a throw inside a predicate reaches the
//! caller's `try` as the thrown value after `query.q` has closed its
//! `Read`, and `ControlTransferred` passes through unchanged.
//!
//! Errors: `QuerySyntax` throws `{:error :nextomic/query-syntax
//! :message "..." :clause i}` (`:clause` only when the parser was
//! inside a `:where` clause), so the reason travels with the throw;
//! `PullSyntax` from a `(pull ?e pattern)` find element throws the
//! `:nextomic/pull-syntax` map the same way;
//! `UnboundPattern` throws `:nextomic/unbound-pattern`; every other
//! error takes the `natives.zig` mapping. VM errors pass through.

const std = @import("std");
const value = @import("../../value.zig");
const vm_mod = @import("../../vm.zig");
const string_mod = @import("../../string.zig");
const natives = @import("../natives.zig");
const query = @import("../query.zig");

const Value = value.Value;
const VM = vm_mod.VM;
const VmError = vm_mod.VmError;
const NativeFn = vm_mod.NativeFn;
const Namespace = vm_mod.Namespace;
const Var = vm_mod.Var;
const Diag = query.Diag;

// =============================================================================
// Installation
// =============================================================================

const Entry = struct { name: []const u8, descriptor: *const NativeFn };

const entries = [_]Entry{
    .{ .name = "q", .descriptor = &native_q },
    .{ .name = "explain", .descriptor = &native_explain },
};

pub fn install(ns: *Namespace) !void {
    for (entries) |entry| {
        const v = try ns.intern(entry.name);
        v.root = vm_mod.nativeFnValue(entry.descriptor);
        v.bound = true;
    }
}

const native_q = NativeFn{ .name = "nextomic/q", .min_arity = 1, .max_arity = null, .call = &fnQ };
const native_explain = NativeFn{ .name = "nextomic/explain", .min_arity = 1, .max_arity = null, .call = &fnExplain };

// =============================================================================
// Errors
// =============================================================================

/// The keyword a pipeline error throws as, or null for a VM error,
/// which passes through unchanged.
fn keywordFor(err: anyerror) ?[]const u8 {
    switch (err) {
        error.QuerySyntax => return "nextomic/query-syntax",
        error.UnboundPattern => return "nextomic/unbound-pattern",
        else => {},
    }
    inline for (@typeInfo(VmError).error_set.?) |e| {
        if (err == @field(anyerror, e.name)) return null;
    }
    return natives.errorKeyword(err);
}

/// Surface `err` to the program with what `diag` knows: the reason of
/// a syntax error or of malformed input, the attribute of an unknown one.
fn fail(vm: *VM, err: anyerror, diag: *const Diag) VmError {
    if (err == error.QuerySyntax) return throwSyntax(vm, diag.message, diag.clause);
    if (err == error.PullSyntax) return natives.throwSyntax(vm, "nextomic/pull-syntax", diag.message, diag.clause);
    if (err == error.UnknownAttribute) return natives.failWith(vm, err, .{ .attr = diag.attr });
    if (err == error.TxData) return natives.failWith(vm, err, .{ .message = messageOf(diag), .attr = diag.attr });
    if (keywordFor(err)) |name| return vm.throwKeyword(name);
    inline for (@typeInfo(VmError).error_set.?) |e| {
        if (err == @field(anyerror, e.name)) return @field(VmError, e.name);
    }
    unreachable;
}

/// The message `diag` carries, when it carries one.
fn messageOf(diag: *const Diag) ?[]const u8 {
    return if (diag.message.len == 0) null else diag.message;
}

/// Throw the `:nextomic/query-syntax` map.
fn throwSyntax(vm: *VM, message: []const u8, clause: ?usize) VmError {
    return natives.throwSyntax(vm, "nextomic/query-syntax", message, clause);
}

// =============================================================================
// The call hook
// =============================================================================

pub const Hook = struct {
    vm: *VM,
    /// Roots every result a callback returns for the query's life.
    scope: vm_mod.RootScope,

    fn init(vm: *VM) Hook {
        return .{ .vm = vm, .scope = vm.rootScope() };
    }

    fn deinit(self: *Hook) void {
        self.scope.release();
    }

    fn callHook(self: *Hook) query.CallHook {
        return .{ .ctx = @ptrCast(self), .call = &call, .apply = &apply, .root = &root };
    }

    fn call(ctx: *anyopaque, sym: u32, args: []const Value) anyerror!Value {
        const self: *Hook = @ptrCast(@alignCast(ctx));
        const callee = try self.resolve(sym);
        const result = try self.vm.callValue(callee, args);
        try self.scope.push(result);
        return result;
    }

    fn root(ctx: *anyopaque, v: Value) anyerror!void {
        const self: *Hook = @ptrCast(@alignCast(ctx));
        try self.scope.push(v);
    }

    /// Apply the value a variable in function position holds: a
    /// function, or a keyword or collection looked up as the language
    /// applies them; anything else is the VM's `:not-callable`.
    fn apply(ctx: *anyopaque, f: Value, args: []const Value) anyerror!Value {
        const self: *Hook = @ptrCast(@alignCast(ctx));
        if (vm_mod.isLookupCallable(f.kind())) return vm_mod.callLookup(f, args);
        const result = try self.vm.callValue(f, args);
        try self.scope.push(result);
        return result;
    }

    /// The bound value the symbol names, or a thrown
    /// `:nextomic/query-syntax` naming what is missing.
    pub fn resolve(self: *Hook, sym: u32) anyerror!Value {
        return (try self.lookup(sym)) orelse self.unknown("unknown function", self.vm.ensureInterner().symbolName(sym));
    }

    /// The bound value the symbol names as the compiler resolves it: an
    /// alias-qualified `ns/name` to that namespace's own var, a bare
    /// name in the current namespace and then its auto-referred
    /// parents; null when nothing is bound.
    pub fn lookup(self: *Hook, sym: u32) !?Value {
        const vm = self.vm;
        const name = vm.ensureInterner().symbolName(sym);
        const registry = try vm.ensureRegistry();
        const current = registry.current;
        const found: ?*Var = blk: {
            if (splitQualified(name)) |q| {
                const ns_name = if (current.aliases_initialized) current.lookupAlias(q.ns) orelse q.ns else q.ns;
                const ns = registry.lookupNs(ns_name) orelse break :blk null;
                break :blk ns.lookupLocal(q.name);
            }
            break :blk current.lookup(name);
        };
        if (found) |v| if (v.bound) return v.root;
        return null;
    }

    fn unknown(self: *Hook, reason: []const u8, name: []const u8) anyerror!Value {
        const vm = self.vm;
        const message = try std.fmt.allocPrint(vm.allocator, "{s}: {s}", .{ reason, name });
        defer vm.allocator.free(message);
        return throwSyntax(vm, message, null);
    }
};

const Qualified = struct { ns: []const u8, name: []const u8 };

/// `ns/name` split at its first `/`; null for a bare name, for `/`
/// itself and for a name with nothing on one side of the slash.
fn splitQualified(name: []const u8) ?Qualified {
    const i = std.mem.indexOfScalar(u8, name, '/') orelse return null;
    if (i == 0 or i + 1 == name.len) return null;
    return .{ .ns = name[0..i], .name = name[i + 1 ..] };
}

// =============================================================================
// q, explain
// =============================================================================

fn fnQ(vm: *VM, args: []const Value) VmError!Value {
    var diag: Diag = .{};
    return qNative(vm, args, &diag) catch |err| fail(vm, err, &diag);
}

fn qNative(vm: *VM, args: []const Value, diag: *Diag) !Value {
    const st = try natives.state(vm);
    var hook = Hook.init(vm);
    defer hook.deinit();
    const options: query.Options = .{ .hook = hook.callHook(), .db_of = &natives.dbOf, .ir_cache = &st.ir_cache, .rules_cache = &st.rules_cache };
    return query.q(vm.allocator, vm.ensureInterner(), vm.ensureHeap(), args[0], null, args[1..], diag, options);
}

fn fnExplain(vm: *VM, args: []const Value) VmError!Value {
    var diag: Diag = .{};
    return explainNative(vm, args, &diag) catch |err| fail(vm, err, &diag);
}

fn explainNative(vm: *VM, args: []const Value, diag: *Diag) !Value {
    const st = try natives.state(vm);
    var hook = Hook.init(vm);
    defer hook.deinit();
    const options: query.Options = .{ .hook = hook.callHook(), .db_of = &natives.dbOf, .ir_cache = &st.ir_cache, .rules_cache = &st.rules_cache };
    var out: std.Io.Writer.Allocating = .init(vm.allocator);
    defer out.deinit();
    try query.explain(vm.allocator, vm.ensureInterner(), args[0], null, args[1..], diag, options, &out.writer);
    return string_mod.fromBytes(vm.ensureHeap(), out.written());
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "pipeline errors map to keywords; VM errors pass through" {
    try testing.expectEqualStrings("nextomic/unbound-pattern", keywordFor(error.UnboundPattern).?);
    try testing.expectEqualStrings("nextomic/unknown-attribute", keywordFor(error.UnknownAttribute).?);
    try testing.expectEqualStrings("nextomic/value-type", keywordFor(error.ValueType).?);
    try testing.expectEqualStrings("nextomic/closed", keywordFor(error.Closed).?);
    try testing.expectEqualStrings("nextomic/nested", keywordFor(error.Nested).?);
    try testing.expectEqualStrings("nextomic/pull-syntax", keywordFor(error.PullSyntax).?);
    try testing.expectEqualStrings("nextomic/history-view", keywordFor(error.HistoryView).?);
    try testing.expectEqualStrings("db/corrupted", keywordFor(error.Corrupted).?);
    try testing.expect(keywordFor(error.ControlTransferred) == null);
    try testing.expect(keywordFor(error.UncaughtThrow) == null);
    try testing.expect(keywordFor(error.ArityMismatch) == null);
    try testing.expect(keywordFor(error.OutOfMemory) == null);
    try testing.expect(keywordFor(error.KindMismatch) == null);
}

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
