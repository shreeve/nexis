//! query/natives.zig — `nextomic/q` and `nextomic/explain` (NEXTOMIC.md
//! §5, §6).
//!
//! `(q query db & inputs)` runs `query.q` and returns the materialised
//! result; `(explain query db & inputs)` returns the plan as a string.
//! The inputs follow `:in` positionally after `$`, so the db is the
//! `$` argument and the rest bind `?x`, `[?x ...]`, `[?a ?b]`,
//! `[[?a ?b]]` and `%`.
//!
//! Caches: one IR cache and one rules cache per VM, on the natives'
//! per-VM state (`natives.state`). A parsed query is pure syntax over
//! the VM's symbol table, so one cache serves every connection the VM
//! opens. The caches hold the query values themselves (by heap identity
//! first, then by structure); no collector frees or moves a heap value,
//! so an entry stays valid for the VM's life. One that does must
//! `clear` both caches.
//!
//! Functions: a predicate or function-binding symbol that is not a
//! built-in resolves through the namespace registry the way the
//! compiler resolves a symbol (an alias-qualified `ns/name` to that
//! namespace's own var; a bare name in the current namespace, then its
//! auto-referred parents) and is called through `VM.callValue` with
//! the clause's arguments as values. Whatever that call raises
//! propagates untouched: a throw inside a predicate reaches the
//! caller's `try` as the thrown value after `query.q` has closed its
//! `Read`, and `ControlTransferred` passes through unchanged.
//!
//! Errors: `QuerySyntax` throws `{:error :nextomic/query-syntax
//! :message "..." :clause i}` (`:clause` only when the parser was
//! inside a `:where` clause), so the reason travels with the throw;
//! `UnboundPattern` throws `:nextomic/unbound-pattern`; every other
//! error takes the `natives.zig` mapping. VM errors pass through.

const std = @import("std");
const value = @import("value");
const vm_mod = @import("vm");
const string_mod = @import("string");
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

const native_q = NativeFn{ .name = "nextomic/q", .min_arity = 2, .max_arity = null, .call = &fnQ };
const native_explain = NativeFn{ .name = "nextomic/explain", .min_arity = 2, .max_arity = null, .call = &fnExplain };

// =============================================================================
// Errors
// =============================================================================

/// The keyword a pipeline error throws as, or null for a VM error,
/// which passes through unchanged.
pub fn keywordFor(err: anyerror) ?[]const u8 {
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

/// Surface `err` to the program.
fn fail(vm: *VM, err: anyerror, diag: *const Diag) VmError {
    if (err == error.QuerySyntax) return throwSyntax(vm, diag.message, diag.clause);
    if (keywordFor(err)) |name| return vm.throwKeyword(name);
    inline for (@typeInfo(VmError).error_set.?) |e| {
        if (err == @field(anyerror, e.name)) return @field(VmError, e.name);
    }
    unreachable;
}

/// Throw the `:nextomic/query-syntax` map.
fn throwSyntax(vm: *VM, message: []const u8, clause: ?usize) VmError {
    return natives.throwSyntax(vm, "nextomic/query-syntax", message, clause);
}

// =============================================================================
// The call hook
// =============================================================================

const Hook = struct {
    vm: *VM,

    fn callHook(self: *Hook) query.CallHook {
        return .{ .ctx = @ptrCast(self), .call = &call };
    }

    fn call(ctx: *anyopaque, sym: u32, args: []const Value) anyerror!Value {
        const self: *Hook = @ptrCast(@alignCast(ctx));
        const callee = try self.resolve(sym);
        return self.vm.callValue(callee, args);
    }

    /// The bound value the symbol names, or a thrown
    /// `:nextomic/query-syntax` naming what is missing.
    fn resolve(self: *Hook, sym: u32) anyerror!Value {
        const vm = self.vm;
        const name = vm.ensureInterner().symbolName(sym);
        if (std.mem.startsWith(u8, name, "?")) return self.unknown("function position takes a function name, not a variable", name);
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
        return self.unknown("unknown function", name);
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
pub fn splitQualified(name: []const u8) ?Qualified {
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
    const d = try natives.dbOf(args[1]);
    const st = try natives.state(vm);
    var hook = Hook{ .vm = vm };
    const options: query.Options = .{ .hook = hook.callHook(), .ir_cache = &st.ir_cache, .rules_cache = &st.rules_cache };
    return query.q(vm.allocator, vm.ensureInterner(), vm.ensureHeap(), args[0], d, args[1..], diag, options);
}

fn fnExplain(vm: *VM, args: []const Value) VmError!Value {
    var diag: Diag = .{};
    return explainNative(vm, args, &diag) catch |err| fail(vm, err, &diag);
}

fn explainNative(vm: *VM, args: []const Value, diag: *Diag) !Value {
    const d = try natives.dbOf(args[1]);
    const st = try natives.state(vm);
    var hook = Hook{ .vm = vm };
    const options: query.Options = .{ .hook = hook.callHook(), .ir_cache = &st.ir_cache, .rules_cache = &st.rules_cache };
    var out: std.Io.Writer.Allocating = .init(vm.allocator);
    defer out.deinit();
    try query.explain(vm.allocator, vm.ensureInterner(), args[0], d, args[1..], diag, options, &out.writer);
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
