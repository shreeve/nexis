//! The macroexpander: Form → Form, between the reader and the
//! compiler (docs/MACROEXPAND.md). It walks a form by each special
//! form's traversal rule, expands macro calls (a user `defmacro` run
//! in a sub-VM, or a host macro of `defaultMacros`) until the head is
//! no macro, rewrites syntax-quote, `#()`, `@x` and `^meta` away, and
//! records why and where an expansion failed.

const std = @import("std");
const reader_mod = @import("reader.zig");
const intern_mod = @import("intern.zig");
const vm_mod = @import("vm.zig");
const value_mod = @import("value.zig");
const list_mod = @import("coll/list.zig");
const vector_mod = @import("coll/vector.zig");
const champ_mod = @import("coll/champ.zig");
const heap_mod = @import("heap.zig");
const bignum_mod = @import("bignum.zig");
const stack = @import("stack.zig");
const string_mod = @import("string.zig");
const dispatch = @import("dispatch.zig");

const Form = reader_mod.Form;
const Datum = reader_mod.Datum;
const SrcSpan = reader_mod.SrcSpan;
const Allocator = std.mem.Allocator;

// =============================================================================
// Types
// =============================================================================

/// Errors specific to macroexpansion. Mapped to CompileError
/// variants by the caller (compile.zig):
///   ExpansionDepthExceeded → CompileError.MacroDepthExceeded
///   everything else        → CompileError.MacroExpansionFailure
///   OutOfMemory            → CompileError.OutOfMemory
pub const ExpandError = error{
    ExpansionDepthExceeded,
    MalformedMacroCall,
    /// A `require` ran a file whose form failed at run time with no
    /// handler in force; the VM's `traced_error` and `error_trace`
    /// carry the failure.
    RequiredFileFailed,
    /// A `require` ran a file whose form threw, and a handler in
    /// the running program took the throw; the VM has already
    /// unwound to it. Passed through unchanged.
    ControlTransferred,
    OutOfMemory,
};

/// Callback for compile-time evaluation of arbitrary Form
/// trees. Used by `defmacro` to
/// compile the equivalent `(def name (fn* name [params] body))`
/// form and evaluate it via a fresh sub-VM. The callback lives
/// outside expand.zig (in compile.zig) so the expander doesn't
/// need to depend on the compile backend — passing this through
/// as a context-pointer + fn-pointer pair avoids the cycle.
///
/// Implementation contract:
///   - `eval(user_data, form, out_vm)` returns the runtime Value
///     produced by compiling + running `form`.
///   - The returned Value may reference `out_vm.runtime_arena`.
///   - The caller MUST keep `out_vm` alive until done reading
///     the result; the helper does NOT call `out_vm.deinit`.
pub const CompileEvalContext = struct {
    user_data: *anyopaque,
    eval: *const fn (
        user_data: *anyopaque,
        form: *const Form,
        out_vm: *vm_mod.VM,
    ) anyerror!value_mod.Value,
};

/// Callback used by `(require ...)` to load a namespace from
/// disk. Set by the CLI / test harness.
/// The callback is responsible for ALL file-loading concerns
/// (path resolution, parsing, compilation, evaluation, registry
/// updates, cycle detection). The expander just decodes the
/// `(require ...)` arg and dispatches.
pub const LoadCallback = struct {
    user_data: *anyopaque,
    load: *const fn (user_data: *anyopaque, ns_name: []const u8) anyerror!void,
};

/// Why an expansion failed and where (MACROEXPAND.md §8): the
/// innermost form that failed, and a message naming the problem.
pub const Failure = struct {
    span: SrcSpan,
    message: []const u8,
};

/// Every resource a host MacroFn might need (MACROEXPAND.md §1). The
/// compiler builds one per top-level form.
pub const ExpandContext = struct {
    allocator: Allocator,
    interner: *intern_mod.Interner,
    /// Macro registry. May be empty (no host expansion fires).
    host_macros: *const HostMacroTable,
    /// Namespace for user-defmacro lookup. When
    /// expanding `(my-fn ...)`, if `my-fn` resolves to a Var
    /// whose `.macro = true`, dispatch as a user macro instead
    /// of an ordinary call. Null = no namespace = no user
    /// macros (useful for tests that exercise host-macro-only
    /// expansion).
    namespace: ?*vm_mod.Namespace = null,
    /// Compile-time eval callback. Set by
    /// `compile.zig` when building the ExpandContext. The
    /// `defmacro` handler uses this to compile + evaluate the
    /// macro fn's body via a fresh sub-VM. Null = `defmacro`
    /// raises MacroExpansionFailure.
    compile_eval: ?CompileEvalContext = null,
    /// When set, `(ns NAME)` special form switches
    /// the current namespace via `registry.switchTo(NAME)`. The
    /// CLI sets this; ad-hoc tests can leave it null (in which
    /// case `(ns NAME)` raises MalformedMacroCall).
    registry: ?*vm_mod.NamespaceRegistry = null,
    /// When set, `(require ...)` special form calls
    /// through this callback to load a namespace from disk.
    /// Null = `(require ...)` raises MalformedMacroCall (useful
    /// for tests that compile in-memory only).
    load_callback: ?LoadCallback = null,
    /// Lazy-init heap for arg Value construction when no
    /// `value_heap` is given. Macro args that are vectors/maps/sets
    /// need a heap for their backing nodes; this one lives on
    /// ExpandContext.allocator (the compile arena) and is reused
    /// across macro invocations.
    _arg_heap: ?heap_mod.Heap = null,
    /// A heap to build values on instead of `_arg_heap`: the
    /// calling VM's heap, which the compiler passes whenever a
    /// namespace registry carries one and the run-time hooks
    /// (`macroexpand-1`, `read-string`) always pass. Macro
    /// arguments, the macro sub-VM's allocations and the values
    /// it returns then live where the VM's Vars can hold them.
    value_heap: ?*heap_mod.Heap = null,
    /// The calling VM's `io`, given to a user macro's sub-VM so the
    /// macro body can print; null leaves the sub-VM without one.
    io: ?std.Io = null,
    /// Set by the first (innermost) failure of an expansion that
    /// returns an error; the message lives in `allocator`.
    failure: ?Failure = null,

    /// Record why expanding the form at `span` failed, unless an
    /// inner form already did, and return `err`.
    pub fn failWith(self: *ExpandContext, err: ExpandError, span: SrcSpan, comptime fmt: []const u8, args: anytype) ExpandError {
        if (self.failure == null) {
            const message = std.fmt.allocPrint(self.allocator, fmt, args) catch return ExpandError.OutOfMemory;
            self.failure = .{ .span = span, .message = message };
        }
        return err;
    }

    /// `failWith` for a malformed form.
    pub fn fail(self: *ExpandContext, span: SrcSpan, comptime fmt: []const u8, args: anytype) ExpandError {
        return self.failWith(ExpandError.MalformedMacroCall, span, fmt, args);
    }

    /// The heap for arg Value construction: `value_heap` when set,
    /// else the lazily created `_arg_heap`, good for the lifetime
    /// of the ExpandContext.
    pub fn heapForArgs(self: *ExpandContext) ExpandError!*heap_mod.Heap {
        if (self.value_heap) |h| return h;
        if (self._arg_heap == null) {
            self._arg_heap = heap_mod.Heap.init(self.allocator);
        }
        return &self._arg_heap.?;
    }

    /// A fresh name `<base>__<N>__auto__` (MACROEXPAND.md §4) in
    /// `ctx.allocator`.
    pub fn gensym(self: *ExpandContext, base: []const u8) ExpandError![]const u8 {
        gensym_counter += 1;
        return std.fmt.allocPrint(self.allocator, "{s}__{d}__auto__", .{ base, gensym_counter });
    }
};

/// The auto-gensym counter. A context lives for one top-level form,
/// but a name it generates may be defined as a Var that later forms
/// see, so the counter is process-wide (one isolate, one thread).
var gensym_counter: u64 = 0;

/// Host-Zig macro callback. Takes the call form (head + args)
/// and produces a rewritten form. The result is then re-fed to
/// `expandForm` (so macro-of-macros works automatically).
pub const MacroFn = *const fn (
    ctx: *ExpandContext,
    call_form: *const Form,
    args: []const *Form,
) ExpandError!*Form;

/// Maps unqualified symbol name → MacroFn. `defaultMacros`
/// builds the standard table (let/fn/defn/when/cond/and/or/...);
/// an empty table disables host expansion.
pub const HostMacroTable = std.StringHashMapUnmanaged(MacroFn);

/// Lexical-name set for macro-shadowing tracking. Mirrors
/// `compile.LowerEnv` exactly so the two stay aligned.
/// Innermost-first lookup via parent walk.
pub const ExpandEnv = struct {
    lexical_names: NameSet = .{},
    parent: ?*const ExpandEnv = null,

    const NameSet = std.StringHashMapUnmanaged(void);

    pub fn contains(self: *const ExpandEnv, name: []const u8) bool {
        if (self.lexical_names.contains(name)) return true;
        if (self.parent) |p| return p.contains(name);
        return false;
    }

    pub fn deinit(self: *ExpandEnv, allocator: Allocator) void {
        self.lexical_names.deinit(allocator);
    }
};

/// MACROEXPAND.md §6: how many times in a row the form at one
/// position may be a macro call whose expansion is again a macro
/// call. Nesting in the source never counts; the native stack guard
/// bounds that.
pub const MAX_EXPANSION_DEPTH: u32 = 256;

// =============================================================================
// Public entry
// =============================================================================

/// Walk a single Form, expanding any macro calls found in
/// operator position. Returns the transformed Form (which may
/// share subtrees with the input — Form trees are immutable
/// from this layer's POV). The output is suitable for direct
/// consumption by `compile.lowerForm`.
///
/// Empty `ctx.host_macros` table → output structurally identical
/// to input.
pub fn expandForm(
    ctx: *ExpandContext,
    env: ?*const ExpandEnv,
    form: *const Form,
) ExpandError!*Form {
    return expandFormDepth(ctx, env, form, 0);
}

/// One macro step, the way `macroexpand-1` sees it: when `form` is
/// a call whose head names a user or host macro (special forms and
/// the `#%` primitives are not macros), the macro's raw output;
/// otherwise null. Nothing inside the result is expanded and no
/// lexical environment applies: the form is top-level data.
pub fn expandOnce(ctx: *ExpandContext, form: *const Form) ExpandError!?*Form {
    if (form.datum != .list) return null;
    const items = form.datum.list;
    const macro = findMacro(ctx, null, items) orelse return null;
    return try callMacro(ctx, macro, form, items);
}

/// What a list's head names when it is a macro: a user macro Var or
/// a host macro.
const Macro = union(enum) {
    user: *vm_mod.Var,
    host: MacroFn,
};

/// The macro `items[0]` names, if any (MACROEXPAND.md §1.1): a
/// qualified head names a macro Var of the namespace its prefix (or
/// alias) names, or a host macro through `nexis.core`; an
/// unqualified head that is not a special form or `#%` primitive and
/// not lexically bound names a macro Var of the current namespace or
/// its refers, else a host macro.
fn findMacro(ctx: *ExpandContext, env: ?*const ExpandEnv, items: []const *Form) ?Macro {
    if (items.len == 0 or items[0].datum != .symbol) return null;
    const head = items[0].datum.symbol;
    if (head.ns) |ns_prefix| {
        const target = aliasTarget(ctx, ns_prefix);
        if (ctx.registry) |reg| if (reg.lookupNs(target)) |ns| if (ns.lookupLocal(head.name)) |v| {
            if (v.macro and v.bound) return .{ .user = v };
        };
        if (std.mem.eql(u8, target, "nexis.core")) if (ctx.host_macros.get(head.name)) |f| return .{ .host = f };
        return null;
    }
    if (isSpecialFormName(head.name)) return null;
    if (env) |e| if (e.contains(head.name)) return null;
    if (ctx.namespace) |ns| if (ns.lookup(head.name)) |v| {
        if (v.macro and v.bound) return .{ .user = v };
        // A Var of the name other than `nexis.core`'s (the
        // namespace's own, excluded or defined, or a referred one)
        // hides the host macro, as it hides a core function.
        if (ctx.registry) |reg| if (reg.core.lookupLocal(head.name) != v) return null;
    };
    if (ctx.host_macros.get(head.name)) |f| return .{ .host = f };
    return null;
}

/// The raw output of `macro` on the call `call_form`.
fn callMacro(ctx: *ExpandContext, macro: Macro, call_form: *const Form, items: []const *Form) ExpandError!*Form {
    return switch (macro) {
        .user => |v| callUserMacro(ctx, v, call_form, items),
        .host => |f| f(ctx, call_form, items[1..]),
    };
}

/// The special forms: never macros, never shadowable, each with its
/// own traversal rule (MACROEXPAND.md §2b). `catch` and `finally`
/// are clauses of `try`, not forms of their own. The compiler
/// recognises the same names.
pub const special_forms = std.StaticStringMap(SpecialForm).initComptime(.{
    .{ "quote", &opaqueForm },
    .{ "var", &opaqueForm },
    .{ "if", &expandIf },
    .{ "do", &walkCall },
    .{ "recur", &walkCall },
    .{ "throw", &walkCall },
    .{ "let*", &expandLetStar },
    .{ "loop*", &expandLetStar },
    .{ "fn*", &expandFnStar },
    .{ "letfn*", &expandLetFnStar },
    .{ "def", &expandDef },
    .{ "set!", &expandSetBang },
    .{ "try", &expandTry },
    .{ "defmacro", &expandDefmacro },
    .{ "ns", &expandNs },
    .{ "require", &expandRequire },
});

const SpecialForm = *const fn (ctx: *ExpandContext, env: ?*const ExpandEnv, list_form: *const Form, items: []const *Form) ExpandError!*Form;

/// Whether `name` heads a special form or is an internal `#%`
/// primitive (`#%list`, `#%vector`, ...), whose arguments expand as
/// a call's do.
fn isSpecialFormName(name: []const u8) bool {
    return special_forms.has(name) or std.mem.startsWith(u8, name, "#%");
}

// =============================================================================
// Internal walker
// =============================================================================

/// `form` expanded, `depth` being how many macro expansions in a row
/// produced it at this position; its sub-forms start again at 0.
fn expandFormDepth(
    ctx: *ExpandContext,
    env: ?*const ExpandEnv,
    form: *const Form,
    depth: u32,
) ExpandError!*Form {
    if (depth > MAX_EXPANSION_DEPTH) return ctx.failWith(ExpandError.ExpansionDepthExceeded, form.origin, "macro expansion did not finish after {d} expansions in a row", .{MAX_EXPANSION_DEPTH});
    try checkStack();
    const b = Builder{ .ctx = ctx, .origin = form.origin };
    return switch (form.datum) {
        .nil, .bool_, .int, .bigint, .real, .char, .string, .keyword, .symbol => mutCast(form),
        .list => |items| try expandList(ctx, env, form, items, depth),
        // Collection literals are expressions: their items expand.
        .vector, .map, .set => try mapChildren(ctx, form, Walk{ .env = env }),
        // Opaque (§7): `(quote (when x y))` does not expand `when`.
        .quote => mutCast(form),
        // §5: the construction form, then expanded like any form so
        // macros in the unquoted parts fire.
        .syntax_quote => |payload| blk: {
            var scope = GensymScope{};
            defer scope.deinit(ctx.allocator);
            break :blk try expandFormDepth(ctx, env, try syntaxQuote(ctx, &scope, payload), depth);
        },
        // The reader refuses these outside syntax-quote; a macro
        // could still produce one.
        .unquote, .unquote_splicing => ctx.fail(form.origin, "{s} outside syntax-quote", .{describeForm(form)}),
        .anon_fn => |items| try expandFormDepth(ctx, env, try anonFnForm(ctx, form, items), depth),
        // `^meta` on a collection literal attaches to the value, as
        // `with-meta` does; on anything else (a symbol, a call) it
        // is a hint and is dropped.
        .with_meta => |wm| switch (wm.target.datum) {
            .vector, .map, .set => try b.list(.{
                "nexis.core/with-meta",
                try expandForm(ctx, env, wm.target),
                try expandForm(ctx, env, try metaMapExpr(ctx, wm.meta.datum.map, wm.meta.origin)),
            }),
            else => try expandFormDepth(ctx, env, wm.target, depth),
        },
        // `@x` is `(nexis.core/deref x)`, qualified so that neither a
        // local nor a Var named `deref` captures it.
        .deref => |inner| try b.list(.{ "nexis.core/deref", try expandForm(ctx, env, inner) }),
    };
}

/// Cast a `*const Form` to `*Form`. The Form tree is arena-
/// owned and immutable from the expander's POV — when we
/// "pass through" a form we return the same pointer. The Tiny
/// lowerer also expects `*Form`. Cast safety: the lowerer
/// reads the form; nothing in the pipeline writes back to it.
inline fn mutCast(form: *const Form) *Form {
    return @constCast(form);
}

/// The native stack guard (`stack.zig`) for every recursion of the
/// expander over a form: a form nested past the stack's budget is
/// `ExpansionDepthExceeded`, never a fault.
inline fn checkStack() ExpandError!void {
    stack.check() catch return ExpandError.ExpansionDepthExceeded;
}

/// Expand a list form; a failure no inner form explained is
/// recorded against this one.
fn expandList(
    ctx: *ExpandContext,
    env: ?*const ExpandEnv,
    list_form: *const Form,
    items: []const *Form,
    depth: u32,
) ExpandError!*Form {
    return dispatchList(ctx, env, list_form, items, depth) catch |err| {
        if (ctx.failure != null) return err;
        const head = if (items.len > 0 and items[0].datum == .symbol) items[0].datum.symbol.name else "";
        return switch (err) {
            error.MalformedMacroCall => ctx.fail(list_form.origin, "malformed ({s} ...)", .{head}),
            error.ExpansionDepthExceeded => ctx.failWith(err, list_form.origin, "form nested too deeply", .{}),
            else => err,
        };
    };
}

/// A special form walks by its own rule; a macro call expands and
/// its output is expanded again, one step deeper; anything else is
/// a call, whose head and arguments expand.
fn dispatchList(
    ctx: *ExpandContext,
    env: ?*const ExpandEnv,
    list_form: *const Form,
    items: []const *Form,
    depth: u32,
) ExpandError!*Form {
    if (items.len > 0 and items[0].datum == .symbol and items[0].datum.symbol.ns == null) {
        if (special_forms.get(items[0].datum.symbol.name)) |walk| return walk(ctx, env, list_form, items);
    }
    if (findMacro(ctx, env, items)) |macro| {
        return expandFormDepth(ctx, env, try callMacro(ctx, macro, list_form, items), depth + 1);
    }
    return mapChildren(ctx, list_form, Walk{ .env = env });
}

/// The namespace name `ns_prefix` stands for: the target of an
/// alias registered in the current namespace, else itself.
fn aliasTarget(ctx: *ExpandContext, ns_prefix: []const u8) []const u8 {
    const cur = ctx.namespace orelse return ns_prefix;
    if (!cur.aliases_initialized) return ns_prefix;
    return cur.lookupAlias(ns_prefix) orelse ns_prefix;
}

// =============================================================================
// Per-special-form walkers (MACROEXPAND.md §2b)
// =============================================================================

/// `quote` and `var`: nothing inside is expanded.
fn opaqueForm(_: *ExpandContext, _: ?*const ExpandEnv, list_form: *const Form, _: []const *Form) ExpandError!*Form {
    return mutCast(list_form);
}

/// `do`, `recur`, `throw` and a call: every sub-form expands under
/// the same env.
fn walkCall(ctx: *ExpandContext, env: ?*const ExpandEnv, list_form: *const Form, _: []const *Form) ExpandError!*Form {
    return mapChildren(ctx, list_form, Walk{ .env = env });
}

fn expandIf(ctx: *ExpandContext, env: ?*const ExpandEnv, list_form: *const Form, items: []const *Form) ExpandError!*Form {
    if (items.len < 3 or items.len > 4) return ctx.fail(list_form.origin, "if: expected a test, a then and an optional else", .{});
    return mapChildren(ctx, list_form, Walk{ .env = env });
}

/// `let*` / `loop*`: each value expands with the names bound before
/// it in the env, the body with all of them; the names do not
/// expand, and lose any `^hint`.
fn expandLetStar(ctx: *ExpandContext, env: ?*const ExpandEnv, list_form: *const Form, items: []const *Form) ExpandError!*Form {
    const head = items[0].datum.symbol.name;
    const bindings = try ctx.allocator.dupe(*Form, try bindingVector(ctx, list_form, items));
    var local: ExpandEnv = .{ .parent = env };
    defer local.deinit(ctx.allocator);
    var i: usize = 0;
    while (i < bindings.len) : (i += 2) {
        const name = stripMeta(bindings[i]);
        if (name.datum != .symbol or name.datum.symbol.ns != null) return ctx.fail(name.origin, "{s}: cannot bind {s}", .{ head, describeForm(name) });
        bindings[i] = name;
        bindings[i + 1] = try expandForm(ctx, &local, bindings[i + 1]);
        try local.lexical_names.put(ctx.allocator, name.datum.symbol.name, {});
    }
    return makeList(ctx, try (Builder{ .ctx = ctx, .origin = list_form.origin }).items(.{
        items[0],
        try makeVector(ctx, bindings, items[1].origin),
        try expandAll(ctx, &local, items[2..]),
    }), list_form.origin);
}

/// The binding vector of a `(let [n v ...] ...)`-shaped form: a
/// vector of name/value pairs.
fn bindingVector(ctx: *ExpandContext, list_form: *const Form, items: []const *Form) ExpandError![]const *Form {
    const head = if (items[0].datum == .symbol) items[0].datum.symbol.name else "";
    if (items.len < 2 or items[1].datum != .vector) return ctx.fail(list_form.origin, "{s}: expected a binding vector", .{head});
    const bindings = items[1].datum.vector;
    if (bindings.len % 2 != 0) return ctx.fail(items[1].origin, "{s}: the binding vector needs an even number of forms", .{head});
    return bindings;
}

/// Add the plain names of a parameter vector (not `&`) to `env`.
fn bindParams(ctx: *ExpandContext, env: *ExpandEnv, params: []const *Form) ExpandError!void {
    for (params) |p| {
        if (p.datum != .symbol or p.datum.symbol.ns != null or isAmpersand(p)) continue;
        try env.lexical_names.put(ctx.allocator, p.datum.symbol.name, {});
    }
}

/// `(fn* name? [params] body...)`: the body expands with the name
/// and the parameters in the env; the parameter vector does not
/// expand and loses its hints.
fn expandFnStar(ctx: *ExpandContext, env: ?*const ExpandEnv, list_form: *const Form, items: []const *Form) ExpandError!*Form {
    const name: []const *Form = if (items.len > 1 and items[1].datum == .symbol) items[1..2] else &.{};
    const rest = items[1 + name.len ..];
    if (rest.len == 0) return ctx.fail(list_form.origin, "fn*: expected a parameter vector", .{});
    const params = try stripParams(ctx, rest[0]);
    if (params.datum != .vector) return ctx.fail(params.origin, "fn*: expected a parameter vector, not {s}", .{describeForm(params)});
    var local: ExpandEnv = .{ .parent = env };
    defer local.deinit(ctx.allocator);
    try bindParams(ctx, &local, name);
    try bindParams(ctx, &local, params.datum.vector);
    return makeList(ctx, try (Builder{ .ctx = ctx, .origin = list_form.origin }).items(.{ items[0], name, params, try expandAll(ctx, &local, rest[1..]) }), list_form.origin);
}

/// `(letfn* [(name params-or-clauses body...) ...] body...)`: every
/// name is in the env of every fn body and of the letfn body; an
/// entry goes through the `fn` expansion first, so overload clauses
/// and destructuring work as for `fn`.
fn expandLetFnStar(ctx: *ExpandContext, env: ?*const ExpandEnv, list_form: *const Form, items: []const *Form) ExpandError!*Form {
    if (items.len < 2 or items[1].datum != .vector) return ctx.fail(list_form.origin, "letfn*: expected a vector of fn bindings", .{});
    const entries = items[1].datum.vector;
    var local: ExpandEnv = .{ .parent = env };
    defer local.deinit(ctx.allocator);
    for (entries) |entry| {
        if (entry.datum != .list or entry.datum.list.len < 2) return ctx.fail(entry.origin, "letfn*: expected (name [params] body...), not {s}", .{describeForm(entry)});
        _ = try plainName(ctx, entry.datum.list[0], "letfn*: a name");
        try bindParams(ctx, &local, entry.datum.list[0..1]);
    }
    const new_entries = try ctx.allocator.alloc(*Form, entries.len);
    for (entries, new_entries) |entry, *out| {
        // The entry as `(fn* name [params] body...)`, expanded under
        // `local`, is `(name [params] body...)` behind its head.
        const fn_form = try expandFnStar(ctx, &local, entry, (try fnStar(ctx, entry, entry.datum.list)).datum.list);
        out.* = try makeList(ctx, fn_form.datum.list[1..], entry.origin);
    }
    return makeList(ctx, try (Builder{ .ctx = ctx, .origin = list_form.origin }).items(.{
        items[0],
        try makeVector(ctx, new_entries, items[1].origin),
        try expandAll(ctx, &local, items[2..]),
    }), list_form.origin);
}

/// `(fn args...)` lowered to its `(fn* ...)` form, destructuring and
/// overload clauses included, without expanding the body.
fn fnStar(ctx: *ExpandContext, call_form: *const Form, args: []const *Form) ExpandError!*Form {
    var fn_form = try expandFnRename(ctx, call_form, args);
    // Overload clauses come back as `(fn name? [& args] body)`; one
    // more pass renames that to `fn*`.
    if (std.mem.eql(u8, fn_form.datum.list[0].datum.symbol.name, "fn")) {
        fn_form = try expandFnRename(ctx, call_form, fn_form.datum.list[1..]);
    }
    return fn_form;
}

/// What kind of form `form` is, with its article, for a failure
/// message.
fn describeForm(form: *const Form) []const u8 {
    return switch (form.datum) {
        .nil => "nil",
        .bool_ => "a boolean",
        .int, .bigint => "an integer",
        .real => "a real",
        .char => "a char",
        .string => "a string",
        .keyword => "a keyword",
        .symbol => |sym| if (sym.ns != null) "a qualified symbol" else "a symbol",
        .list => "a list",
        .vector => "a vector",
        .map => "a map",
        .set => "a set",
        .with_meta => "a form with metadata",
        .anon_fn => "a #() literal",
        .quote => "a quote",
        .syntax_quote => "a syntax-quote",
        .unquote => "an unquote",
        .unquote_splicing => "an unquote-splicing",
        .deref => "a deref",
    };
}

/// `form` without the `^meta` it carries: in a binding or parameter
/// position a type hint or flag has no meaning in nexis and is
/// dropped (MACROEXPAND.md §2b, `^meta`).
fn stripMeta(form: *const Form) *Form {
    var f = form;
    while (f.datum == .with_meta) f = f.datum.with_meta.target;
    return mutCast(f);
}

/// The visitor that strips `^meta` from each element of a parameter
/// or binding vector.
const StripMeta = struct {
    fn visit(_: StripMeta, _: *ExpandContext, form: *const Form) ExpandError!*Form {
        return stripMeta(form);
    }
};

/// A parameter vector with the `^meta` on it (a return hint) and on
/// each of its elements dropped.
fn stripParams(ctx: *ExpandContext, params: *const Form) ExpandError!*Form {
    const vec = stripMeta(params);
    if (vec.datum != .vector) return vec;
    return try mapChildren(ctx, vec, StripMeta{});
}

// ---- def / defn -----------------------------------------------------------

fn expandDef(
    ctx: *ExpandContext,
    env: ?*const ExpandEnv,
    list_form: *const Form,
    items: []const *Form,
) ExpandError!*Form {
    // (def name) | (def name value) | (def name "doc" value); the
    // name may carry `^meta`, which lands on the Var.
    if (items.len < 2 or items.len > 4) return ctx.fail(list_form.origin, "def: expected a name, an optional docstring and a value", .{});
    if (items.len == 4 and items[2].datum != .string) return ctx.fail(items[2].origin, "def: the docstring must be a string, not {s}", .{describeForm(items[2])});
    const b = Builder{ .ctx = ctx, .origin = list_form.origin };
    const named = try splitMetaName(ctx, items[1]);
    const name = named.name.datum.symbol.name;
    if (ctx.namespace) |ns| if (ns.vars.getEntry(name)) |entry| if (!isOwnVar(entry)) {
        return ctx.fail(named.name.origin, "def: {s} already refers to a Var of another namespace", .{name});
    };
    const value = try expandAll(ctx, env, if (items.len == 2) &.{} else items[items.len - 1 ..]);
    const def_form = try b.list(.{ items[0], named.name, value });
    if (named.meta == null and items.len < 4) return def_form;
    var meta: std.ArrayList(*Form) = .empty;
    if (named.meta) |m| try meta.appendSlice(ctx.allocator, m);
    if (items.len == 4) try meta.appendSlice(ctx.allocator, &.{ try b.kw("doc"), items[2] });
    return withVarMeta(ctx, def_form, meta.items, list_form.origin);
}

/// Each of `forms` expanded under `env`.
fn expandAll(ctx: *ExpandContext, env: ?*const ExpandEnv, forms: []const *Form) ExpandError![]*Form {
    const out = try ctx.allocator.alloc(*Form, forms.len);
    for (forms, out) |f, *o| o.* = try expandForm(ctx, env, f);
    return out;
}

/// A definition's name form split into the symbol and the entries
/// of any `^meta` it carries (`^:private f` reads as `{:private
/// true}`); a name that is neither is malformed.
fn splitMetaName(ctx: *ExpandContext, form: *const Form) ExpandError!struct { name: *const Form, meta: ?[]const *Form } {
    const target, const meta: ?[]const *Form = switch (form.datum) {
        .with_meta => |wm| .{ wm.target, if (wm.meta.datum == .map) wm.meta.datum.map else null },
        else => .{ form, null },
    };
    if (target.datum != .symbol or target.datum.symbol.ns != null) return ctx.fail(form.origin, "the name defined must be an unqualified symbol, not {s}", .{describeForm(target)});
    return .{ .name = target, .meta = meta };
}

/// The map literal `{k v ...}` of `meta_items` as an expression: a
/// symbol under `:tag` (a type hint, `^String x`) is quoted, since
/// it names a class nexis does not have.
fn metaMapExpr(ctx: *ExpandContext, meta_items: []const *Form, origin: SrcSpan) ExpandError!*Form {
    const b = Builder{ .ctx = ctx, .origin = origin };
    const items = try ctx.allocator.dupe(*Form, meta_items);
    var i: usize = 1;
    while (i < items.len) : (i += 2) {
        const key = items[i - 1];
        const is_tag = key.datum == .keyword and key.datum.keyword.ns == null and std.mem.eql(u8, key.datum.keyword.name, "tag");
        if (is_tag and items[i].datum == .symbol) items[i] = try b.list(.{ "quote", items[i] });
    }
    return b.map(.{items});
}

/// `def_form` (a `def`, which yields its Var) wrapped so the Var then
/// carries the map built from `meta_items` (flat k v ...):
///   (let* [v# def_form] (nexis.core/reset-meta! v# {k v ...}) v#)
/// No items: `def_form` itself.
fn withVarMeta(ctx: *ExpandContext, def_form: *Form, meta_items: []const *Form, origin: SrcSpan) ExpandError!*Form {
    if (meta_items.len == 0) return def_form;
    const b = Builder{ .ctx = ctx, .origin = origin };
    const v = try b.gensym("nx");
    return b.list(.{ "let*", try b.vec(.{ v, def_form }), try b.list(.{ "nexis.core/reset-meta!", v, try metaMapExpr(ctx, meta_items, origin) }), v });
}

/// Expand `(try body* (catch MATCHER BINDING handler*)* (finally
/// body*)?)` onto the compiler's primitive, which takes exactly one
/// `(catch any g ...)`:
///
///   (try body...
///     (catch any g#
///       (if (nexis.internal/#%catch-matches? g# :tag) (let* [b1 g#] h1...)
///       (if ... (let* [bn g#] hn...)
///       (throw g#))))
///     (finally ...)?)
///
/// A MATCHER is `any` (every value, no test), a keyword TAG, which
/// matches a thrown value equal to TAG or a map whose `:error` entry
/// is TAG (the shape of Nextomic's error maps and the
/// no-matching-clause map), or, for code written for Clojure, a
/// class name (`Exception`, `Throwable`, any symbol) or `:default`,
/// which match every value as `any` does: nexis has no classes.
/// Clauses are tried in order; a value no clause matches is
/// rethrown, so it unwinds through the `finally` to the enclosing
/// `try`. With no clause at all the handler is the rethrow, which
/// is finally-only `try`; with neither catch nor finally the form is
/// `(do body...)`. The body, each handler (with its binding in the
/// env) and the finally body are expanded; matchers and bindings are
/// not.
fn expandTry(
    ctx: *ExpandContext,
    env: ?*const ExpandEnv,
    list_form: *const Form,
    items: []const *Form,
) ExpandError!*Form {
    const b = Builder{ .ctx = ctx, .origin = list_form.origin };
    // Body forms, then catch clauses, then an optional finally.
    var end = items.len;
    const finally_form: ?*const Form = if (end > 1 and isClauseHead(items[end - 1], "finally")) items[end - 1] else null;
    if (finally_form != null) end -= 1;
    var catch_start = end;
    while (catch_start > 1 and isClauseHead(items[catch_start - 1], "catch")) catch_start -= 1;
    const body = items[1..catch_start];
    const catches = items[catch_start..end];
    for (body) |f| if (isClauseHead(f, "catch") or isClauseHead(f, "finally")) return ctx.fail(f.origin, "try: catch and finally come after the body, finally last", .{});
    const new_body = try expandAll(ctx, env, body);
    if (catches.len == 0 and finally_form == null) return b.list(.{ "do", new_body });

    const g = try b.gensym("caught");
    var handler = try b.list(.{ "throw", g });
    var i = catches.len;
    while (i > 0) {
        i -= 1;
        const clause = catches[i].datum.list;
        if (clause.len < 3) return ctx.fail(catches[i].origin, "catch: expected (catch matcher binding body...)", .{});
        const matcher = clause[1];
        const binding = stripMeta(clause[2]);
        if (binding.datum != .symbol or binding.datum.symbol.ns != null) return ctx.fail(binding.origin, "catch: the binding must be an unqualified symbol, not {s}", .{describeForm(binding)});
        var handler_env: ExpandEnv = .{ .parent = env };
        defer handler_env.deinit(ctx.allocator);
        try handler_env.lexical_names.put(ctx.allocator, binding.datum.symbol.name, {});
        const clause_body = try b.list(.{ "let*", try b.vec(.{ binding, g }), try expandAll(ctx, &handler_env, clause[3..]) });
        const is_any = matcher.datum == .symbol or
            (matcher.datum == .keyword and matcher.datum.keyword.ns == null and std.mem.eql(u8, matcher.datum.keyword.name, "default"));
        if (is_any) {
            handler = clause_body;
        } else if (matcher.datum == .keyword) {
            handler = try b.list(.{ "if", try b.list(.{ "nexis.internal/#%catch-matches?", g, matcher }), clause_body, handler });
        } else {
            return ctx.fail(matcher.origin, "catch: expected any, a class name or a keyword tag, not {s}", .{describeForm(matcher)});
        }
    }
    const catch_form = try b.list(.{ "catch", "any", g, handler });
    if (finally_form) |ff| {
        const fin = ff.datum.list;
        return b.list(.{ items[0], new_body, catch_form, try makeList(ctx, try b.items(.{ fin[0], try expandAll(ctx, env, fin[1..]) }), ff.origin) });
    }
    return b.list(.{ items[0], new_body, catch_form });
}

/// The `(fn* [%1 ...] (body...))` form a `#(body...)` literal
/// stands for (MACROEXPAND.md §9), built syntactically and not yet
/// expanded. Shared by the expander and by macro-argument
/// conversion, so a `#()` inside a user macro's body reaches the
/// macro as an ordinary `fn*` form.
fn anonFnForm(
    ctx: *ExpandContext,
    call_form: *const Form,
    items: []const *Form,
) ExpandError!*Form {
    const origin = call_form.origin;
    var anon: AnonParams = .{};
    const body = try ctx.allocator.alloc(*Form, items.len);
    for (items, body) |it, *b| b.* = try anon.visit(ctx, it);

    const params = try ctx.allocator.alloc(*Form, anon.max_positional + @as(usize, if (anon.uses_rest) 2 else 0));
    for (params[0..anon.max_positional], 1..) |*p, n| p.* = try makeSymbol(ctx, try std.fmt.allocPrint(ctx.allocator, "%{d}", .{n}), origin);
    if (anon.uses_rest) {
        params[anon.max_positional] = try makeSymbol(ctx, "&", origin);
        params[anon.max_positional + 1] = try makeSymbol(ctx, "%&", origin);
    }
    return (Builder{ .ctx = ctx, .origin = origin }).list(.{ "fn*", try makeVector(ctx, params, origin), try makeList(ctx, body, origin) });
}

/// The `%` parameters a `#()` body uses, found in every sub-form
/// but a quoted one: `%` is rewritten to `%1`, `%N` counts toward
/// the arity and `%&` makes the fn variadic. A nested `#()` is
/// malformed (Clojure's rule; the reader refuses it first).
const AnonParams = struct {
    max_positional: u32 = 0,
    uses_rest: bool = false,

    fn visit(self: *AnonParams, ctx: *ExpandContext, form: *const Form) ExpandError!*Form {
        switch (form.datum) {
            .symbol => |sym| if (sym.ns == null and sym.name.len > 0 and sym.name[0] == '%') {
                const name = sym.name;
                if (name.len == 1) {
                    self.max_positional = @max(self.max_positional, 1);
                    return try makeSymbol(ctx, "%1", form.origin);
                }
                if (std.mem.eql(u8, name, "%&")) {
                    self.uses_rest = true;
                } else if (std.fmt.parseUnsigned(u32, name[1..], 10)) |n| {
                    if (n == 0 or n > 1000) return ctx.fail(form.origin, "#(): no parameter {s}", .{name});
                    self.max_positional = @max(self.max_positional, n);
                } else |_| {}
            },
            .anon_fn => return ctx.fail(form.origin, "#() cannot nest", .{}),
            .quote => {},
            else => return try mapChildren(ctx, form, self),
        }
        return mutCast(form);
    }
};

/// `form` with `visitor.visit(ctx, child)` in place of each child
/// (the items of a list, vector, map or set; the target and map of
/// `^meta`; the payload of `@`, syntax-quote and the unquotes),
/// sharing `form` when no child changed. A leaf, `quote` and `#()`
/// come back as they are.
fn mapChildren(ctx: *ExpandContext, form: *const Form, visitor: anytype) ExpandError!*Form {
    try checkStack();
    switch (form.datum) {
        inline .list, .vector, .map, .set => |items, tag| {
            var out: ?[]*Form = null;
            for (items, 0..) |item, i| {
                const new = try visitor.visit(ctx, item);
                if (out) |o| {
                    o[i] = new;
                } else if (new != item) {
                    const o = try ctx.allocator.alloc(*Form, items.len);
                    for (items[0..i], 0..) |earlier, j| o[j] = mutCast(earlier);
                    o[i] = new;
                    out = o;
                }
            }
            const o = out orelse return mutCast(form);
            return try makeForm(ctx, @unionInit(Datum, @tagName(tag), o), form.origin);
        },
        inline .deref, .syntax_quote, .unquote, .unquote_splicing => |inner, tag| {
            const new = try visitor.visit(ctx, inner);
            if (new == inner) return mutCast(form);
            return try makeForm(ctx, @unionInit(Datum, @tagName(tag), new), form.origin);
        },
        .with_meta => |wm| {
            const target = try visitor.visit(ctx, wm.target);
            const meta = try visitor.visit(ctx, wm.meta);
            if (target == wm.target and meta == wm.meta) return mutCast(form);
            return try makeForm(ctx, .{ .with_meta = .{ .target = target, .meta = meta } }, form.origin);
        },
        else => return mutCast(form),
    }
}

/// The visitor `mapChildren` expands each child with: the sub-forms
/// of calls, `do`, `if`, `recur` and collection literals, all under
/// one env.
const Walk = struct {
    env: ?*const ExpandEnv,

    fn visit(self: Walk, ctx: *ExpandContext, form: *const Form) ExpandError!*Form {
        return expandForm(ctx, self.env, form);
    }
};

// =============================================================================
// Namespaces, require, set!, defmacro and user-macro calls
// =============================================================================
//
// `ns`, `require` and `defmacro` take effect at expansion time, so
// the forms after them in the same file see the namespace, the
// loaded code and the macro. A user macro runs in a sub-VM on its
// arguments as data (`formToValue`), and its result becomes a form
// again (`valueToForm`) that is expanded in its place.

/// `(ns NAME docstring? attr-map? clause*)` switches the registry's
/// current namespace to NAME at expansion time, creating it (with
/// `nexis.core` referred) if needed, then runs each
/// `(:require spec*)` clause as `require` runs its specs, in the new
/// namespace. `(:refer-clojure :exclude [names])` interns each name
/// that `nexis.core` or the host macro table holds as an unbound Var
/// of the namespace, so the name is the namespace's own from then
/// on; `:only` and `:rename` are refused. `(:gen-class ...)` is
/// accepted and does nothing (there is no class to generate). The
/// docstring and attribute map are accepted and not kept. The form
/// is replaced by nil.
fn expandNs(ctx: *ExpandContext, _: ?*const ExpandEnv, list_form: *const Form, items: []const *Form) ExpandError!*Form {
    const origin = list_form.origin;
    if (items.len < 2) return ctx.fail(origin, "ns: expected a namespace name", .{});
    const name_form = stripMeta(items[1]);
    if (name_form.datum != .symbol or name_form.datum.symbol.ns != null) return ctx.fail(name_form.origin, "ns: the name must be an unqualified symbol, not {s}", .{describeForm(name_form)});
    const reg = ctx.registry orelse return ctx.fail(origin, "ns: namespaces cannot be switched here", .{});
    reg.switchTo(name_form.datum.symbol.name) catch return ExpandError.OutOfMemory;
    var clauses = items[2..];
    if (clauses.len > 0 and clauses[0].datum == .string) clauses = clauses[1..];
    if (clauses.len > 0 and clauses[0].datum == .map) clauses = clauses[1..];
    for (clauses) |clause| {
        const clause_items: []const *Form = if (clause.datum == .list) clause.datum.list else &.{};
        if (clause_items.len == 0 or clause_items[0].datum != .keyword) return ctx.fail(clause.origin, "ns: expected a clause like (:require ...), not {s}", .{describeForm(clause)});
        const kind = clause_items[0].datum.keyword.name;
        if (std.mem.eql(u8, kind, "require")) {
            for (clause_items[1..]) |spec| try requireSpec(ctx, spec);
        } else if (std.mem.eql(u8, kind, "refer-clojure")) {
            try referClojure(ctx, reg, clause_items[1..]);
        } else if (!std.mem.eql(u8, kind, "gen-class")) {
            return ctx.fail(clause.origin, "ns: (:{s} ...) is not supported", .{kind});
        }
    }
    return try makeNil(ctx, origin);
}

/// The options of `(:refer-clojure ...)`: `:exclude [names]` makes
/// each name the current namespace's own (an unbound Var until the
/// namespace defines it), so it neither resolves to nor inlines nor
/// expands as `nexis.core`'s; `nexis.core/name` still reaches it.
fn referClojure(ctx: *ExpandContext, reg: *vm_mod.NamespaceRegistry, opts: []const *Form) ExpandError!void {
    if (opts.len % 2 != 0) return ctx.fail(opts[opts.len - 1].origin, "ns: :refer-clojure options come in pairs", .{});
    var i: usize = 0;
    while (i < opts.len) : (i += 2) {
        const key = opts[i];
        const k = if (key.datum == .keyword and key.datum.keyword.ns == null) key.datum.keyword.name else "";
        if (k.len == 0) return ctx.fail(key.origin, "ns: expected a :refer-clojure option, not {s}", .{describeForm(key)});
        if (!std.mem.eql(u8, k, "exclude")) return ctx.fail(key.origin, "ns: (:refer-clojure :{s} ...) is not supported; :exclude is", .{k});
        const names = opts[i + 1];
        if (names.datum != .vector) return ctx.fail(names.origin, "ns: :exclude takes a vector of symbols, not {s}", .{describeForm(names)});
        for (names.datum.vector) |name_form| {
            const name = try plainName(ctx, name_form, "ns: an excluded name");
            if (reg.core.lookupLocal(name) == null and ctx.host_macros.get(name) == null) continue;
            if (reg.current.lookupLocal(name) != null) continue;
            _ = reg.current.intern(name) catch return ExpandError.OutOfMemory;
        }
    }
}

/// `(require spec*)` loads and refers at expansion time, through
/// `ctx.load_callback`, and is replaced by nil. Each spec, quoted or
/// not, is a namespace symbol or `[ns-name option*]`:
///
///   :as alias          `alias/x` names `ns-name/x`
///   :as-alias alias    the alias alone; nothing is loaded
///   :refer [x y]       `x` and `y` name those Vars here
///   :refer :all        so does every public Var of the namespace
///   :rename {x z}      a referred `x` is named `z` here
///
/// A prefix list, `[prefix suffix...]` or `(prefix suffix...)`,
/// requires each suffix spec under `prefix.` (`requirePrefixList`).
/// A keyword spec (`:reload`, `:reload-all`, `:verbose`) is a flag
/// and changes nothing. What a namespace name loads, including the
/// Clojure library names that stand for nexis namespaces, is the
/// loader's (`loader.zig`).
fn expandRequire(ctx: *ExpandContext, _: ?*const ExpandEnv, list_form: *const Form, items: []const *Form) ExpandError!*Form {
    if (items.len < 2) return ctx.fail(list_form.origin, "require: expected a namespace", .{});
    for (items[1..]) |spec| try requireSpec(ctx, spec);
    return try makeNil(ctx, list_form.origin);
}

/// Load and refer one `require` spec (see `expandRequire`).
fn requireSpec(ctx: *ExpandContext, quoted: *const Form) ExpandError!void {
    const spec = unwrapQuote(quoted);
    if (prefixList(spec)) |items| return requirePrefixList(ctx, items);
    const opts: []const *Form = switch (spec.datum) {
        .keyword => return,
        .symbol => &.{},
        .vector => |v| if (v.len > 0) v[1..] else return ctx.fail(spec.origin, "require: an empty spec", .{}),
        else => return ctx.fail(spec.origin, "require: expected a namespace symbol or [name options...], not {s}", .{describeForm(spec)}),
    };
    const name_form = if (spec.datum == .vector) spec.datum.vector[0] else spec;
    if (name_form.datum != .symbol or name_form.datum.symbol.ns != null) return ctx.fail(name_form.origin, "require: the namespace must be an unqualified symbol, not {s}", .{describeForm(name_form)});
    const ns_name = name_form.datum.symbol.name;
    if (opts.len % 2 != 0) return ctx.fail(spec.origin, "require: options come in pairs", .{});
    var as_alias: ?[]const u8 = null;
    var load = true;
    var refer: ?*const Form = null;
    var rename: []const *Form = &.{};
    var i: usize = 0;
    while (i < opts.len) : (i += 2) {
        const key = opts[i];
        const val = opts[i + 1];
        const k = if (key.datum == .keyword and key.datum.keyword.ns == null) key.datum.keyword.name else "";
        if (std.mem.eql(u8, k, "as") or std.mem.eql(u8, k, "as-alias")) {
            if (val.datum != .symbol or val.datum.symbol.ns != null) return ctx.fail(val.origin, "require: :{s} takes a symbol, not {s}", .{ k, describeForm(val) });
            as_alias = val.datum.symbol.name;
            if (std.mem.eql(u8, k, "as-alias")) load = false;
        } else if (std.mem.eql(u8, k, "refer")) {
            const all = val.datum == .keyword and std.mem.eql(u8, val.datum.keyword.name, "all");
            if (val.datum != .vector and !all) return ctx.fail(val.origin, "require: :refer takes a vector of names or :all, not {s}", .{describeForm(val)});
            refer = val;
        } else if (std.mem.eql(u8, k, "rename")) {
            if (val.datum != .map) return ctx.fail(val.origin, "require: :rename takes a map, not {s}", .{describeForm(val)});
            rename = val.datum.map;
        } else {
            return ctx.fail(key.origin, "require: unknown option {s}", .{if (k.len > 0) k else describeForm(key)});
        }
    }

    const reg = ctx.registry orelse return ctx.fail(spec.origin, "require: namespaces cannot be loaded here", .{});
    if (load) {
        const cb = ctx.load_callback orelse return ctx.fail(spec.origin, "require: namespaces cannot be loaded here", .{});
        cb.load(cb.user_data, ns_name) catch |err| return switch (err) {
            error.OutOfMemory => ExpandError.OutOfMemory,
            // A file that ran and failed: the VM carries the failure.
            error.RunFailed => ExpandError.RequiredFileFailed,
            error.ControlTransferred => ExpandError.ControlTransferred,
            // The loader has its own account of why, located in the
            // file that failed when there is one.
            else => ctx.fail(name_form.origin, "require: {s} did not load", .{ns_name}),
        };
    }
    const cur = reg.current;
    if (as_alias) |a| cur.putAlias(a, ns_name) catch return ExpandError.OutOfMemory;
    const r = refer orelse return;
    const target = reg.lookupNs(ns_name) orelse return ctx.fail(name_form.origin, "require: no namespace {s} to refer from", .{ns_name});
    if (r.datum == .keyword) {
        var it = target.vars.iterator();
        while (it.next()) |entry| {
            const v = entry.value_ptr.*;
            if (isOwnVar(entry) and !isPrivate(ctx, v)) try referVar(ctx, cur, v, renamed(rename, v.name), r.origin);
        }
        return;
    }
    for (r.datum.vector) |sym| {
        if (sym.datum != .symbol or sym.datum.symbol.ns != null) return ctx.fail(sym.origin, "require: :refer names symbols, not {s}", .{describeForm(sym)});
        const name = sym.datum.symbol.name;
        const v = target.lookupLocal(name) orelse return ctx.fail(sym.origin, "require: {s}/{s} does not exist", .{ ns_name, name });
        try referVar(ctx, cur, v, renamed(rename, name), sym.origin);
    }
}

/// The items of a prefix list, `(prefix suffix...)` or a vector
/// whose second element is not an option keyword: `[app c [d :as
/// dd]]` names `app.c` and `[app.d :as dd]`, as Clojure's `require`
/// reads it. null for any other spec.
fn prefixList(spec: *const Form) ?[]const *Form {
    return switch (spec.datum) {
        .list => |l| if (l.len > 0) l else null,
        .vector => |v| if (v.len >= 2 and v[1].datum != .keyword) v else null,
        else => null,
    };
}

/// Require each suffix of a prefix list under its prefix. As in
/// Clojure, a name under a prefix has no period and a suffix is not
/// itself a prefix list.
fn requirePrefixList(ctx: *ExpandContext, items: []const *Form) ExpandError!void {
    const prefix = items[0];
    if (prefix.datum != .symbol or prefix.datum.symbol.ns != null) return ctx.fail(prefix.origin, "require: a prefix must be an unqualified symbol, not {s}", .{describeForm(prefix)});
    for (items[1..]) |suffix| {
        const name_form = switch (suffix.datum) {
            .symbol => suffix,
            .vector => |v| if (v.len == 0) suffix else v[0],
            else => return ctx.fail(suffix.origin, "require: a prefix list holds symbols and vectors, not {s}", .{describeForm(suffix)}),
        };
        if (prefixList(suffix) != null) return ctx.fail(suffix.origin, "require: a prefix list cannot hold another", .{});
        if (name_form.datum != .symbol or name_form.datum.symbol.ns != null) return ctx.fail(name_form.origin, "require: the namespace must be an unqualified symbol, not {s}", .{describeForm(name_form)});
        const name = name_form.datum.symbol.name;
        if (std.mem.indexOfScalar(u8, name, '.') != null) return ctx.fail(name_form.origin, "require: {s} is under the prefix {s}, so it cannot contain a period", .{ name, prefix.datum.symbol.name });
        const full = try makeSymbol(ctx, try std.fmt.allocPrint(ctx.allocator, "{s}.{s}", .{ prefix.datum.symbol.name, name }), name_form.origin);
        if (suffix.datum == .symbol) {
            try requireSpec(ctx, full);
        } else {
            const v = try ctx.allocator.dupe(*Form, suffix.datum.vector);
            v[0] = full;
            try requireSpec(ctx, try makeVector(ctx, v, suffix.origin));
        }
    }
}

/// The name `:rename {from to ...}` gives `name`, else `name`.
fn renamed(rename: []const *Form, name: []const u8) []const u8 {
    var i: usize = 0;
    while (i + 1 < rename.len) : (i += 2) {
        const from = rename[i];
        const to = rename[i + 1];
        if (from.datum == .symbol and to.datum == .symbol and std.mem.eql(u8, from.datum.symbol.name, name)) return to.datum.symbol.name;
    }
    return name;
}

/// Map `name` in `ns` to the Var `v` of another namespace. A name
/// that already maps to a Var of `ns` itself is a conflict, as in
/// Clojure; one that already refers to `v` stays.
fn referVar(ctx: *ExpandContext, ns: *vm_mod.Namespace, v: *vm_mod.Var, name: []const u8, span: SrcSpan) ExpandError!void {
    if (ns.vars.getEntry(name)) |existing| {
        if (existing.value_ptr.* == v) return;
        if (isOwnVar(existing)) return ctx.fail(span, "require: {s} is already defined in {s}", .{ name, ns.name });
    }
    const owned = try ns.var_allocator.dupe(u8, name);
    try ns.vars.put(ns.map_allocator, owned, v);
}

/// Whether a namespace's entry is its own Var rather than one it
/// refers to: `Namespace.intern` keys the map with the Var's own
/// name storage, and a referral is keyed with a copy.
fn isOwnVar(entry: anytype) bool {
    return entry.key_ptr.*.ptr == entry.value_ptr.*.name.ptr;
}

/// Whether `v`'s metadata marks it `:private`.
fn isPrivate(ctx: *ExpandContext, v: *const vm_mod.Var) bool {
    if (v.meta.kind() != .persistent_map) return false;
    const key = ctx.interner.internKeywordValue("private") catch return false;
    return switch (champ_mod.mapGet(v.meta, key, &dispatch.hashValue, &dispatch.equal)) {
        .present => |flag| flag.isTruthy(),
        .absent => false,
    };
}

/// The form under one level of quoting: the reader's `'x` datum or
/// the written-out `(quote x)`; any other form is itself.
fn unwrapQuote(form: *const Form) *const Form {
    return switch (form.datum) {
        .quote => |inner| inner,
        .list => |items| if (items.len == 2 and items[0].datum == .symbol and items[0].datum.symbol.ns == null and std.mem.eql(u8, items[0].datum.symbol.name, "quote")) items[1] else form,
        else => form,
    };
}

/// `(set! target v)` rebinds the innermost thread binding of the
/// dynamic Var `target` names: it expands to
/// `(nexis.core/var-set (var target) v)`. A target that is a
/// lexical name is refused here, at compile time, because a local
/// has no binding to rebind (VM.md §6.5).
fn expandSetBang(
    ctx: *ExpandContext,
    env: ?*const ExpandEnv,
    list_form: *const Form,
    items: []const *Form,
) ExpandError!*Form {
    if (items.len != 3) return ctx.fail(list_form.origin, "set!: expected a Var name and a value", .{});
    const target = items[1];
    if (target.datum != .symbol) return ctx.fail(target.origin, "set!: expected a Var name, not {s}", .{describeForm(target)});
    if (target.datum.symbol.ns == null) if (env) |e| if (e.contains(target.datum.symbol.name)) {
        return ctx.fail(target.origin, "set!: {s} is a local, not a Var", .{target.datum.symbol.name});
    };
    const b = Builder{ .ctx = ctx, .origin = list_form.origin };
    return b.list(.{ "nexis.core/var-set", try b.list(.{ "var", target }), try expandForm(ctx, env, items[2]) });
}

/// `(defmacro NAME ...)`, spelled like `defn` (docstring, attribute
/// map, destructuring, overload clauses), runs at expansion time:
/// `(def NAME (fn NAME ...))`, fully expanded, is compiled and run
/// through `ctx.compile_eval`, and the Var it yields is marked a
/// macro. The form is replaced by `(var NAME)`.
fn expandDefmacro(
    ctx: *ExpandContext,
    env: ?*const ExpandEnv,
    list_form: *const Form,
    items: []const *Form,
) ExpandError!*Form {
    const origin = list_form.origin;
    const parts = try defnParts(ctx, list_form, items[1..], false);
    const name = parts.name.datum.symbol.name;
    const ceval = ctx.compile_eval orelse return ctx.fail(origin, "defmacro {s}: macros cannot be defined here", .{name});
    const b = Builder{ .ctx = ctx, .origin = origin };
    const fn_form = try fnStar(ctx, list_form, try b.items(.{ parts.name, parts.fn_tail }));
    const def_form = try b.list(.{ "def", parts.name, fn_form });
    const expanded = try expandForm(ctx, env, try withVarMeta(ctx, def_form, parts.meta, origin));

    // The sub-VM is not released: the macro's closure lives in its
    // allocator (the persistent one the compiler gives), which the
    // calling VM frees at teardown.
    var sub_vm: vm_mod.VM = undefined;
    const result = ceval.eval(ceval.user_data, expanded, &sub_vm) catch |err| {
        if (err == error.OutOfMemory) return ExpandError.OutOfMemory;
        return ctx.fail(origin, "defmacro {s}: the macro function did not compile: {s}", .{ name, @errorName(err) });
    };
    if (result.kind() != .var_) return ctx.fail(origin, "defmacro {s}: the definition yielded no Var", .{name});
    vm_mod.VM.asVar(result).macro = true;
    return b.list(.{ "var", parts.name });
}

/// Call the user macro `macro_var` on the unevaluated args of
/// `call_form` and return its output as a Form, unexpanded.
fn callUserMacro(
    ctx: *ExpandContext,
    macro_var: *vm_mod.Var,
    call_form: *const Form,
    items: []const *Form,
) ExpandError!*Form {
    const args = items[1..];
    const name = macro_var.name;
    const span = call_form.origin;
    if (macro_var.root.kind() != .function) return ctx.fail(span, "macro {s} is not a function", .{name});
    const routine = vm_mod.VM.asClosure(macro_var.root).routine;
    if (if (routine.variadic) args.len < routine.fixed_arity else args.len != routine.fixed_arity) {
        return ctx.fail(span, "macro {s} takes {d}{s} argument{s}, got {d}", .{
            name,
            routine.fixed_arity,
            if (routine.variadic) " or more" else "",
            if (routine.fixed_arity == 1 and !routine.variadic) "" else "s",
            args.len,
        });
    }

    // Each argument as data, unevaluated.
    const arg_values = try ctx.allocator.alloc(value_mod.Value, args.len);
    defer ctx.allocator.free(arg_values);
    for (args, 0..) |a, i| arg_values[i] = try formToValue(ctx, a);

    // A fresh sub-VM that never collects, on the calling VM's heap
    // when the context has it, so a value the macro stores into a
    // Var outlives the call; the result becomes a Form in
    // `ctx.allocator` before the sub-VM goes, and so does the
    // message of a throw it did not catch.
    var sub_vm = vm_mod.VM.init(ctx.allocator, &vm_mod.VM.idle_routine) catch return ExpandError.OutOfMemory;
    defer sub_vm.deinit();
    sub_vm.borrowed_interner = ctx.interner;
    sub_vm.borrowed_heap = ctx.value_heap;
    sub_vm.gc_enabled = false;
    sub_vm.io = ctx.io;
    const result_value = sub_vm.callValue(macro_var.root, arg_values) catch |err| {
        if (err == error.OutOfMemory) return ExpandError.OutOfMemory;
        if (err == error.UncaughtThrow) if (sub_vm.unhandled_throw) |thrown| {
            return ctx.fail(span, "macro {s} threw {s}", .{ name, try describeThrown(ctx, thrown) });
        };
        if (sub_vm.error_detail.len > 0) return ctx.fail(span, "macro {s} failed: {s}: {s}", .{ name, @errorName(err), sub_vm.error_detail });
        return ctx.fail(span, "macro {s} failed: {s}", .{ name, @errorName(err) });
    };
    return try valueToForm(ctx, result_value, span);
}

/// A thrown value in a failure message: a string as itself, a
/// keyword as `:name`, a map by its `:message` string or `:error`
/// keyword, anything else by its kind.
fn describeThrown(ctx: *ExpandContext, thrown: value_mod.Value) ExpandError![]const u8 {
    switch (thrown.kind()) {
        .string => return string_mod.asBytes(thrown),
        .keyword => return std.fmt.allocPrint(ctx.allocator, ":{s}", .{ctx.interner.keywordName(thrown.asKeywordId())}),
        .persistent_map => for ([_][]const u8{ "message", "error" }) |key_name| {
            const key = ctx.interner.internKeywordValue(key_name) catch return ExpandError.OutOfMemory;
            switch (champ_mod.mapGet(thrown, key, &dispatch.hashValue, &dispatch.equal)) {
                .present => |v| if (v.kind() == .string or v.kind() == .keyword) return describeThrown(ctx, v),
                .absent => {},
            }
        },
        else => {},
    }
    return std.fmt.allocPrint(ctx.allocator, "a {s}", .{@tagName(thrown.kind())});
}

/// A form as the data a macro receives (MACROEXPAND.md §1.2): each
/// literal as its value, a symbol or keyword interned (qualified
/// ones by their full `ns/name`), a list, vector, map or set as that
/// collection, `'x` as `(quote x)`, `@x` as `(deref x)`, `#()` as
/// the `fn*` form it stands for and `^m x` as `x`. A syntax-quote or
/// an unquote is not data.
pub fn formToValue(ctx: *ExpandContext, form: *const Form) ExpandError!value_mod.Value {
    try checkStack();
    const heap = try ctx.heapForArgs();
    const oom = ExpandError.OutOfMemory;
    return switch (form.datum) {
        .nil => value_mod.nilValue(),
        .bool_ => |b| value_mod.fromBool(b),
        .int => |n| value_mod.fromFixnum(n) orelse (bignum_mod.fromI64(heap, n) catch return oom),
        .bigint => |text| (bignum_mod.parseDecimal(heap, text) catch return oom) orelse ctx.fail(form.origin, "malformed integer {s}", .{text}),
        .real => |f| value_mod.fromFloat(f),
        .char => |c| value_mod.fromChar(c) orelse ctx.fail(form.origin, "no char U+{X}", .{c}),
        .string => |bytes| string_mod.fromBytes(heap, bytes) catch return oom,
        .symbol => |name| ctx.interner.internQualifiedSymbol(name.ns, name.name) catch return oom,
        .keyword => |name| ctx.interner.internQualifiedKeyword(name.ns, name.name) catch return oom,
        .list, .vector, .set, .map => |items| blk: {
            const values = try ctx.allocator.alloc(value_mod.Value, items.len);
            defer ctx.allocator.free(values);
            for (items, values) |item, *v| v.* = try formToValue(ctx, item);
            break :blk switch (form.datum) {
                .list => list_mod.fromSlice(heap, values),
                .vector => vector_mod.fromSlice(heap, values),
                .set => setOf(heap, values),
                else => mapOf(heap, values),
            } catch return oom;
        },
        .quote => |inner| try callForm(ctx, "quote", inner),
        .deref => |inner| try callForm(ctx, "nexis.core/deref", inner),
        .anon_fn => |items| try formToValue(ctx, try anonFnForm(ctx, form, items)),
        .with_meta => |wm| try formToValue(ctx, wm.target),
        .syntax_quote, .unquote, .unquote_splicing => ctx.fail(form.origin, "{s} is not data a macro can take", .{describeForm(form)}),
    };
}

/// The list `(head x)` as data, `x` converted by `formToValue`.
fn callForm(ctx: *ExpandContext, head: []const u8, x: *const Form) ExpandError!value_mod.Value {
    const items = [_]value_mod.Value{
        ctx.interner.internSymbolValue(head) catch return ExpandError.OutOfMemory,
        try formToValue(ctx, x),
    };
    return list_mod.fromSlice(try ctx.heapForArgs(), &items) catch ExpandError.OutOfMemory;
}

fn setOf(heap: *heap_mod.Heap, values: []const value_mod.Value) !value_mod.Value {
    var s = try champ_mod.setEmpty(heap);
    for (values) |v| s = try champ_mod.setConj(heap, s, v, &dispatch.hashValue, &dispatch.equal);
    return s;
}

/// The map of `kvs`, keys and values alternating (the reader
/// guarantees an even count).
fn mapOf(heap: *heap_mod.Heap, kvs: []const value_mod.Value) !value_mod.Value {
    var m = try champ_mod.mapEmpty(heap);
    var i: usize = 0;
    while (i + 1 < kvs.len) : (i += 2) m = try champ_mod.mapAssoc(heap, m, kvs[i], kvs[i + 1], &dispatch.hashValue, &dispatch.equal);
    return m;
}

/// A macro's result as a form, every form at `origin` (the call's
/// span) in `ctx.allocator`: the inverse of `formToValue`, a bignum
/// within i64 an `int` and beyond it a `bigint`. The list
/// `(nexis.internal/#%meta x m)` becomes `^m x`, and so does a list,
/// vector, map or set carrying the metadata `m` (§5). A function, a
/// Var or any other kind is not a form.
pub fn valueToForm(ctx: *ExpandContext, v: value_mod.Value, origin: SrcSpan) ExpandError!*Form {
    try checkStack();
    const datum: Datum = switch (v.kind()) {
        .nil => .nil,
        .true_, .false_ => .{ .bool_ = v.kind() == .true_ },
        .fixnum => .{ .int = v.asFixnum() },
        .bignum => if (bignum_mod.toI64(v)) |n| .{ .int = n } else blk: {
            var w = std.Io.Writer.Allocating.init(ctx.allocator);
            bignum_mod.formatDecimal(v, &w.writer) catch return ExpandError.OutOfMemory;
            break :blk .{ .bigint = try w.toOwnedSlice() };
        },
        .float => .{ .real = v.asFloat() },
        .char => .{ .char = v.asChar() },
        .string => .{ .string = try ctx.allocator.dupe(u8, string_mod.asBytes(v)) },
        .symbol => .{ .symbol = nameOf(ctx.interner.symbolName(v.asSymbolId())) },
        .keyword => .{ .keyword = nameOf(ctx.interner.keywordName(v.asKeywordId())) },
        .list => blk: {
            var items: std.ArrayList(*Form) = .empty;
            var node = v;
            while (node.kind() == .list and !list_mod.isEmpty(node)) : (node = list_mod.tail(node)) {
                try items.append(ctx.allocator, try valueToForm(ctx, list_mod.head(node), origin));
            }
            if (isMetaMarker(items.items)) break :blk .{ .with_meta = .{ .target = items.items[1], .meta = items.items[2] } };
            break :blk .{ .list = items.items };
        },
        .persistent_vector => blk: {
            const items = try ctx.allocator.alloc(*Form, vector_mod.count(v));
            for (items, 0..) |*item, i| item.* = try valueToForm(ctx, vector_mod.nth(v, i), origin);
            break :blk .{ .vector = items };
        },
        .persistent_map => blk: {
            var items: std.ArrayList(*Form) = .empty;
            var it = champ_mod.mapIter(v);
            while (it.next()) |e| try items.appendSlice(ctx.allocator, &.{ try valueToForm(ctx, e.key, origin), try valueToForm(ctx, e.value, origin) });
            break :blk .{ .map = items.items };
        },
        .persistent_set => blk: {
            var items: std.ArrayList(*Form) = .empty;
            var it = champ_mod.setIter(v);
            while (it.next()) |e| try items.append(ctx.allocator, try valueToForm(ctx, e, origin));
            break :blk .{ .set = items.items };
        },
        else => return ctx.fail(origin, "a macro returned a {s}, which is not a form", .{@tagName(v.kind())}),
    };
    const form = try makeForm(ctx, datum, origin);
    const carries_meta = switch (v.kind()) {
        .list, .persistent_vector, .persistent_map, .persistent_set => datum != .with_meta,
        else => false,
    };
    if (carries_meta) if (heap_mod.Heap.asHeapHeader(v).getMeta()) |m| {
        const meta = try valueToForm(ctx, champ_mod.valueFromMapHeader(m), origin);
        return makeForm(ctx, .{ .with_meta = .{ .target = form, .meta = meta } }, origin);
    };
    return form;
}

/// An interned `ns/name` text as a qualified name.
fn nameOf(full: []const u8) reader_mod.Name {
    const parts = intern_mod.Interner.splitQualified(full);
    return .{ .ns = parts.ns, .name = parts.name };
}

/// Helper: is `form` a list whose head is the unqualified
/// symbol `name`? Used by `expandTry` to detect catch/finally
/// clauses.
fn isClauseHead(form: *const Form, name: []const u8) bool {
    if (form.datum != .list) return false;
    const items = form.datum.list;
    if (items.len == 0) return false;
    const head = items[0];
    if (head.datum != .symbol) return false;
    if (head.datum.symbol.ns != null) return false;
    return std.mem.eql(u8, head.datum.symbol.name, name);
}

// =============================================================================
// Form construction (MACROEXPAND.md §10b)
// =============================================================================
//
// Every synthetic form carries the span of the macro call it came
// from (§4b) and lives in `ctx.allocator`.

fn makeForm(ctx: *ExpandContext, datum: Datum, origin: SrcSpan) ExpandError!*Form {
    const form = try ctx.allocator.create(Form);
    form.* = .{ .datum = datum, .origin = origin };
    return form;
}

fn makeList(ctx: *ExpandContext, items: []const *Form, origin: SrcSpan) ExpandError!*Form {
    return makeForm(ctx, .{ .list = items }, origin);
}

fn makeVector(ctx: *ExpandContext, items: []const *Form, origin: SrcSpan) ExpandError!*Form {
    return makeForm(ctx, .{ .vector = items }, origin);
}

fn makeSymbol(ctx: *ExpandContext, name: []const u8, origin: SrcSpan) ExpandError!*Form {
    return makeForm(ctx, .{ .symbol = .{ .ns = null, .name = name } }, origin);
}

fn makeQualifiedSymbol(ctx: *ExpandContext, ns_name: []const u8, sym_name: []const u8, origin: SrcSpan) ExpandError!*Form {
    return makeForm(ctx, .{ .symbol = .{ .ns = ns_name, .name = sym_name } }, origin);
}

fn makeKeyword(ctx: *ExpandContext, name: []const u8, origin: SrcSpan) ExpandError!*Form {
    return makeForm(ctx, .{ .keyword = .{ .ns = null, .name = name } }, origin);
}

fn makeNil(ctx: *ExpandContext, origin: SrcSpan) ExpandError!*Form {
    return makeForm(ctx, .nil, origin);
}

fn makeBool(ctx: *ExpandContext, value: bool, origin: SrcSpan) ExpandError!*Form {
    return makeForm(ctx, .{ .bool_ = value }, origin);
}

/// Builds a host macro's output at one call's span. `list`, `vec`
/// and `map` take a tuple whose elements may be forms, slices of
/// forms (spliced in place), integers, booleans, `null` (nil) or
/// strings: `":k"` is a keyword, `"ns/name"` a qualified symbol and
/// any other string a symbol.
const Builder = struct {
    ctx: *ExpandContext,
    origin: SrcSpan,

    fn list(b: Builder, parts: anytype) ExpandError!*Form {
        return makeList(b.ctx, try b.items(parts), b.origin);
    }

    fn vec(b: Builder, parts: anytype) ExpandError!*Form {
        return makeVector(b.ctx, try b.items(parts), b.origin);
    }

    fn map(b: Builder, parts: anytype) ExpandError!*Form {
        return makeForm(b.ctx, .{ .map = try b.items(parts) }, b.origin);
    }

    /// `name` as a keyword.
    fn kw(b: Builder, name: []const u8) ExpandError!*Form {
        return makeKeyword(b.ctx, name, b.origin);
    }

    /// A fresh symbol `<base>__N__auto__`.
    fn gensym(b: Builder, base: []const u8) ExpandError!*Form {
        return makeSymbol(b.ctx, try b.ctx.gensym(base), b.origin);
    }

    fn items(b: Builder, parts: anytype) ExpandError![]*Form {
        var n: usize = 0;
        inline for (parts) |part| n += if (comptime isFormSlice(@TypeOf(part))) part.len else 1;
        const out = try b.ctx.allocator.alloc(*Form, n);
        var i: usize = 0;
        inline for (parts) |part| {
            if (comptime isFormSlice(@TypeOf(part))) {
                for (part) |f| {
                    out[i] = mutCast(f);
                    i += 1;
                }
            } else {
                out[i] = try b.item(part);
                i += 1;
            }
        }
        return out;
    }

    fn item(b: Builder, x: anytype) ExpandError!*Form {
        const T = @TypeOf(x);
        if (T == *Form or T == *const Form) return mutCast(x);
        if (T == @TypeOf(null)) return makeNil(b.ctx, b.origin);
        if (T == bool) return makeBool(b.ctx, x, b.origin);
        if (comptime isString(T)) return b.named(x);
        return makeForm(b.ctx, .{ .int = @intCast(x) }, b.origin);
    }

    fn named(b: Builder, text: []const u8) ExpandError!*Form {
        const is_kw = text.len > 1 and text[0] == ':';
        const body = if (is_kw) text[1..] else text;
        const slash = if (body.len > 1) std.mem.indexOfScalar(u8, body, '/') else null;
        const name: reader_mod.Name = if (slash) |at| .{ .ns = body[0..at], .name = body[at + 1 ..] } else .{ .ns = null, .name = body };
        return makeForm(b.ctx, if (is_kw) .{ .keyword = name } else .{ .symbol = name }, b.origin);
    }

    fn isFormSlice(comptime T: type) bool {
        return T == []*Form or T == []const *Form;
    }

    fn isString(comptime T: type) bool {
        if (T == []const u8 or T == []u8) return true;
        const info = @typeInfo(T);
        return info == .pointer and info.pointer.size == .one and @typeInfo(info.pointer.child) == .array and @typeInfo(info.pointer.child).array.child == u8;
    }
};

// =============================================================================
// Host core macros (MACROEXPAND.md §10)
// =============================================================================
//
// Each macro fn matches `MacroFn`:
//   fn(ctx, call_form, args) ExpandError!*Form
//
// Conventions:
//   - The macro's NAME is registered in `defaultMacros()` and
//     resolved by the expander; the fn itself never sees the
//     head symbol — only the args.
//   - All synthetic Forms use `call_form.origin` per
//     MACROEXPAND.md §4b.
//   - Malformed shapes raise `MalformedMacroCall` which the
//     compile layer buckets as `MacroExpansionFailure`.
//   - Output forms are re-fed to the expander (see
//     `expandList`), so a macro may expand to another macro
//     call.

// ---- let / fn / loop and destructuring --------------------------
//
// The user-facing `let`, `fn` and `loop` are macros over the
// compiler primitives `let*`, `fn*` and `loop*` (CLOJURE-REVIEW.md
// §1.1) that rewrite destructuring patterns into plain bindings.

/// `(let [pattern expr ...] body...)` → `(let* [name expr ...]
/// body...)`, each pattern destructured into plain bindings by
/// `destructurePair`.
fn expandLetRename(ctx: *ExpandContext, call_form: *const Form, args: []const *Form) ExpandError!*Form {
    const pairs = try bindingVector(ctx, call_form, call_form.datum.list);
    const b = Builder{ .ctx = ctx, .origin = call_form.origin };
    var out: std.ArrayList(*Form) = .empty;
    var i: usize = 0;
    while (i < pairs.len) : (i += 2) try destructurePair(b, pairs[i], pairs[i + 1], &out);
    return b.list(.{ "let*", try makeVector(ctx, out.items, args[0].origin), args[1..] });
}

/// `(fn name? [params] body...)` → `(fn* name? [params'] body...)`:
/// a pattern parameter becomes a gensym that `(let [pattern gensym
/// ...] body...)` destructures, and a map pattern after `&` takes
/// keyword arguments. Overload clauses `(fn name? ([p] b) ...)` go
/// through `multiArityFn`.
fn expandFnRename(ctx: *ExpandContext, call_form: *const Form, args: []const *Form) ExpandError!*Form {
    const b = Builder{ .ctx = ctx, .origin = call_form.origin };
    const named = args.len > 0 and args[0].datum == .symbol;
    const name: []const *Form = if (named) args[0..1] else &.{};
    const tail = args[name.len..];
    if (tail.len == 0) return ctx.fail(call_form.origin, "fn: expected a parameter vector", .{});
    const params_form = try stripParams(ctx, tail[0]);
    if (params_form.datum == .list) return multiArityFn(b, name, tail);
    if (params_form.datum != .vector) return ctx.fail(params_form.origin, "fn: expected a parameter vector, got {s}", .{describeForm(params_form)});

    const params = try ctx.allocator.dupe(*Form, params_form.datum.vector);
    var patterns: std.ArrayList(*Form) = .empty;
    var after_amp = false;
    for (params) |*p| {
        if (isAmpersand(p.*)) {
            after_amp = true;
        } else if (p.*.datum != .symbol) {
            const g = try b.gensym("nx");
            try patterns.appendSlice(ctx.allocator, &.{ p.*, if (after_amp) try restSource(b, p.*, g) else g });
            p.* = g;
        }
    }
    const new_params = try makeVector(ctx, params, params_form.origin);
    const body = try conditionedBody(b, tail[1..]);
    if (patterns.items.len == 0) return b.list(.{ "fn*", name, new_params, body });
    return b.list(.{ "fn*", name, new_params, try b.list(.{ "nexis.core/let", try b.vec(.{patterns.items}), body }) });
}

/// A fn body whose first form is a condition map `{:pre [c...]
/// :post [c...]}` followed by more forms, as the checks around the
/// rest: each `:pre` condition before it, each `:post` condition
/// after it with `%` bound to its value. A failed check throws
/// `{:error :assertion-failed :message "Assert failed: <c>"}`. Any
/// other body is itself.
fn conditionedBody(b: Builder, body: []const *Form) ExpandError![]const *Form {
    if (body.len < 2 or body[0].datum != .map) return body;
    const pre = conditions(body[0], "pre");
    const post = conditions(body[0], "post");
    if (pre == null and post == null) return body;
    var out: std.ArrayList(*Form) = .empty;
    for (pre orelse &.{}) |c| try out.append(b.ctx.allocator, try assertion(b, c));
    const rest = body[1..];
    if (post) |checks| {
        var after: std.ArrayList(*Form) = .empty;
        for (checks) |c| try after.append(b.ctx.allocator, try assertion(b, c));
        try out.append(b.ctx.allocator, try b.list(.{ "let*", try b.vec(.{ "%", try b.list(.{ "do", rest }) }), after.items, "%" }));
    } else {
        try out.appendSlice(b.ctx.allocator, rest);
    }
    return out.items;
}

/// The conditions under `:key` in a condition map, if it has them.
fn conditions(map: *const Form, key: []const u8) ?[]const *Form {
    const entries = map.datum.map;
    var i: usize = 0;
    while (i + 1 < entries.len) : (i += 2) {
        const k = entries[i];
        if (k.datum == .keyword and k.datum.keyword.ns == null and std.mem.eql(u8, k.datum.keyword.name, key) and entries[i + 1].datum == .vector) return entries[i + 1].datum.vector;
    }
    return null;
}

/// `(if c nil (throw {:error :assertion-failed :message ...}))`.
fn assertion(b: Builder, c: *const Form) ExpandError!*Form {
    const prefix = try makeForm(b.ctx, .{ .string = "Assert failed: " }, b.origin);
    const message = try b.list(.{ "nexis.core/str", prefix, try b.list(.{ "quote", c }) });
    return b.list(.{ "if", c, null, try b.list(.{ "throw", try b.map(.{ ":error", ":assertion-failed", ":message", message }) }) });
}

fn isAmpersand(form: *const Form) bool {
    return form.datum == .symbol and form.datum.symbol.ns == null and std.mem.eql(u8, form.datum.symbol.name, "&");
}

/// `(loop [pattern init ...] body...)` → `(loop* [g init ...] (let
/// [pattern g ...] body...))`: each pattern binds a gensym in the
/// loop and destructures it again on every iteration, so `recur`
/// rebinds the gensyms. A loop of plain names is `loop*` itself.
fn expandLoopRename(ctx: *ExpandContext, call_form: *const Form, args: []const *Form) ExpandError!*Form {
    const pairs = try bindingVector(ctx, call_form, call_form.datum.list);
    const b = Builder{ .ctx = ctx, .origin = call_form.origin };
    const loop_bindings = try ctx.allocator.dupe(*Form, pairs);
    var patterns: std.ArrayList(*Form) = .empty;
    var i: usize = 0;
    while (i < pairs.len) : (i += 2) {
        if (stripMeta(pairs[i]).datum == .symbol) continue;
        const g = try b.gensym("nx");
        try patterns.appendSlice(ctx.allocator, &.{ pairs[i], g });
        loop_bindings[i] = g;
    }
    // `loop*` drops the hints of hinted names.
    if (patterns.items.len == 0) return renameHead(ctx, call_form, args, "loop*");
    return b.list(.{ "loop*", try b.vec(.{loop_bindings}), try b.list(.{ "nexis.core/let", try b.vec(.{patterns.items}), args[1..] }) });
}

/// `(NEW_HEAD args...)`, the args expanded later by the walker for
/// the new head.
fn renameHead(ctx: *ExpandContext, call_form: *const Form, args: []const *Form, new_head: []const u8) ExpandError!*Form {
    return (Builder{ .ctx = ctx, .origin = call_form.origin }).list(.{ new_head, args });
}

/// Overload clauses `([params] body...)+` of `fn`, `defn` or a
/// `letfn` binding lowered to one variadic function dispatching on
/// argument count:
///
///   (fn name? [& args#]
///     (let* [n# (count args#)]
///       (if (== n# 1) (loop [p1 (first args#)] b1)
///       (if (== n# 2) (loop [p1 (first args#) p2 (nth args# 1)] b2)
///       (if (>= n# k) (loop [... r (next ... args#)] bv)
///       (throw :arity-mismatch))))))
///
/// `n#` is a count, so the tests are the inlined fixnum compares, and
/// every `nth` is in range once its clause's test has passed.
/// Fixed arities are tested in source order and the variadic clause
/// last, so an exact arity wins over the variadic one. At most one
/// clause is variadic, its fixed count is not below any fixed
/// arity, and no fixed arity repeats (Clojure's rules). Each clause
/// binds through `loop`, so its params destructure and a `recur` in
/// the clause's tail re-enters that clause with the clause's own
/// arity (a variadic clause's rest parameter receives one seq); a
/// `recur` inside a nested `loop` targets that loop.
fn multiArityFn(b: Builder, name: []const *Form, clauses: []const *Form) ExpandError!*Form {
    const ctx = b.ctx;
    const Arity = struct { fixed: usize, variadic: bool, params: []const *Form, body: []const *Form };
    var fixed_arities: std.ArrayList(Arity) = .empty;
    var variadic: ?Arity = null;
    for (clauses) |clause| {
        if (clause.datum != .list or clause.datum.list.len == 0) return ctx.fail(clause.origin, "fn: expected an overload clause ([params] body...), not {s}", .{describeForm(clause)});
        const params_form = try stripParams(ctx, clause.datum.list[0]);
        if (params_form.datum != .vector) return ctx.fail(params_form.origin, "fn: expected a parameter vector, got {s}", .{describeForm(params_form)});
        const params = params_form.datum.vector;
        const fixed = for (params, 0..) |p, i| {
            if (isAmpersand(p)) break i;
        } else params.len;
        const arity: Arity = .{ .fixed = fixed, .variadic = fixed < params.len, .params = params, .body = clause.datum.list[1..] };
        if (arity.variadic) {
            if (variadic != null) return ctx.fail(clause.origin, "fn: at most one overload clause may be variadic", .{});
            if (fixed + 2 != params.len) return ctx.fail(params_form.origin, "fn: & takes exactly one parameter after it", .{});
            variadic = arity;
        } else {
            for (fixed_arities.items) |a| if (a.fixed == fixed) return ctx.fail(clause.origin, "fn: two overload clauses take {d} arguments", .{fixed});
            try fixed_arities.append(ctx.allocator, arity);
        }
    }
    if (variadic) |v| for (fixed_arities.items) |a| {
        if (a.fixed > v.fixed) return ctx.fail(b.origin, "fn: a fixed arity of {d} is above the variadic clause's {d}", .{ a.fixed, v.fixed });
    };

    const args = try b.gensym("nx");
    const n = try b.gensym("nx");
    var chain = try b.list(.{ "throw", ":arity-mismatch" });
    var i = fixed_arities.items.len + @intFromBool(variadic != null);
    while (i > 0) {
        i -= 1;
        const a = if (i == fixed_arities.items.len) variadic.? else fixed_arities.items[i];
        var bindings: std.ArrayList(*Form) = .empty;
        for (a.params[0..a.fixed], 0..) |p, k| {
            const arg = if (k == 0) try b.list(.{ "nexis.core/first", args }) else try b.list(.{ "nexis.core/nth", args, k });
            try bindings.appendSlice(ctx.allocator, &.{ p, arg });
        }
        if (a.variadic) {
            // `next`, as `nthnext`: an empty rest is nil, as the VM
            // binds a single-arity fn's (VM.md §6).
            var rest = args;
            for (0..a.fixed) |_| rest = try b.list(.{ "nexis.core/next", rest });
            const pattern = a.params[a.fixed + 1];
            try bindings.appendSlice(ctx.allocator, &.{ pattern, try restSource(b, pattern, rest) });
        }
        const test_form = try b.list(.{ if (a.variadic) "nexis.core/>=" else "nexis.core/==", n, a.fixed });
        // `loop`, not `loop*`, so a pattern parameter destructures
        // on entry and after every `recur`.
        chain = try b.list(.{ "if", test_form, try b.list(.{ "nexis.core/loop", try b.vec(.{bindings.items}), try conditionedBody(b, a.body) }), chain });
    }
    return b.list(.{ "nexis.core/fn", name, try b.vec(.{ "&", args }), try b.list(.{ "let*", try b.vec(.{ n, try b.list(.{ "nexis.core/count", args }) }), chain }) });
}

/// Append the plain bindings that destructure `pattern` over `expr`
/// to `out`: a symbol binds directly; a vector or map pattern binds
/// a gensym to `expr` and destructures that.
fn destructurePair(b: Builder, hinted_pattern: *const Form, expr: *const Form, out: *std.ArrayList(*Form)) ExpandError!void {
    try checkStack();
    const ctx = b.ctx;
    const pattern = stripMeta(hinted_pattern);
    switch (pattern.datum) {
        .symbol => |sym| {
            if (sym.ns != null) return ctx.fail(pattern.origin, "cannot bind the qualified symbol {s}/{s}", .{ sym.ns.?, sym.name });
            try out.appendSlice(ctx.allocator, &.{ pattern, mutCast(expr) });
        },
        .vector, .map => {
            const g = try b.gensym("nx");
            try out.appendSlice(ctx.allocator, &.{ g, mutCast(expr) });
            if (pattern.datum == .vector) try destructureVector(b, pattern.datum.vector, g, out) else try destructureMap(b, pattern.datum.map, g, out);
        },
        else => return ctx.fail(pattern.origin, "cannot bind {s}", .{describeForm(pattern)}),
    }
}

/// A vector pattern over `src`: element `i` binds `(nth src i nil)`,
/// `& r` binds `r` to `next` applied once per element before it (so
/// an exhausted rest is nil, as `nthnext` gives), `:as name` binds
/// `src` itself.
fn destructureVector(b: Builder, elems: []const *Form, src: *Form, out: *std.ArrayList(*Form)) ExpandError!void {
    var i: usize = 0;
    while (i < elems.len) : (i += 1) {
        const e = elems[i];
        const is_as = e.datum == .keyword and e.datum.keyword.ns == null and std.mem.eql(u8, e.datum.keyword.name, "as");
        if (is_as or isAmpersand(e)) {
            if (i + 1 >= elems.len) return b.ctx.fail(e.origin, "destructuring: {s} needs a name after it", .{if (is_as) ":as" else "&"});
            const target = elems[i + 1];
            if (is_as) {
                try destructurePair(b, target, src, out);
            } else {
                var rest = src;
                for (0..i) |_| rest = try b.list(.{ "nexis.core/next", rest });
                try destructurePair(b, target, try restSource(b, target, rest), out);
            }
            i += 1;
        } else {
            try destructurePair(b, e, try b.list(.{ "nexis.core/nth", src, i, null }), out);
        }
    }
}

/// A map pattern over `src`:
///
///   {:keys [a b]}      a (get src :a), b (get src :b)
///   {:keys [p/a :b]}   a (get src :p/a), b (get src :b)
///   {:p/keys [a]}      a (get src :p/a)
///   {:strs [a]}        a (get src "a")
///   {:syms [a]}        a (get src 'a); {:p/syms [a]} (get src 'p/a)
///   {a :a-key}         a (get src :a-key)
///   {... :or {a 10}}   a (get src ... 10), the default when absent
///   {... :as name}     name src
fn destructureMap(b: Builder, entries: []const *Form, src: *Form, out: *std.ArrayList(*Form)) ExpandError!void {
    const ctx = b.ctx;
    if (entries.len % 2 != 0) return ctx.fail(b.origin, "destructuring: a map pattern needs pairs", .{});
    var defaults: []const *Form = &.{};
    var as_name: ?*const Form = null;
    var i: usize = 0;
    while (i < entries.len) : (i += 2) {
        const k = entries[i];
        const v = entries[i + 1];
        if (k.datum != .keyword or k.datum.keyword.ns != null) continue;
        if (std.mem.eql(u8, k.datum.keyword.name, "or")) {
            if (v.datum != .map) return ctx.fail(v.origin, "destructuring: :or takes a map, not {s}", .{describeForm(v)});
            defaults = v.datum.map;
        } else if (std.mem.eql(u8, k.datum.keyword.name, "as")) {
            if (v.datum != .symbol) return ctx.fail(v.origin, "destructuring: :as takes a symbol, not {s}", .{describeForm(v)});
            as_name = v;
        }
    }
    i = 0;
    while (i < entries.len) : (i += 2) {
        const k = entries[i];
        const v = entries[i + 1];
        if (k.datum == .keyword) {
            const kw = k.datum.keyword;
            if (kw.ns == null and (std.mem.eql(u8, kw.name, "or") or std.mem.eql(u8, kw.name, "as"))) continue;
            const group: ?KeyGroup = if (std.mem.eql(u8, kw.name, "keys"))
                .keys
            else if (std.mem.eql(u8, kw.name, "syms"))
                .syms
            else if (kw.ns == null and std.mem.eql(u8, kw.name, "strs"))
                .strs
            else
                null;
            if (group) |g| {
                if (v.datum != .vector) return ctx.fail(v.origin, ":{s} takes a vector of names, not {s}", .{ kw.name, describeForm(v) });
                for (v.datum.vector) |entry| try destructureKeyEntry(b, g, kw.ns, entry, src, defaults, out);
                continue;
            }
        }
        // `{pattern key}`: the pattern destructures the key's value.
        const default = if (k.datum == .symbol) lookupDefault(defaults, k.datum.symbol.name) else null;
        try destructurePair(b, k, try getCall(b, src, v, default), out);
    }
    if (as_name) |n| try out.appendSlice(ctx.allocator, &.{ mutCast(n), src });
}

const KeyGroup = enum { keys, strs, syms };

/// One entry of a `:keys` / `:strs` / `:syms` vector: the local is
/// the entry's name part; the key is that name as a keyword, string
/// or symbol, qualified by the entry's own namespace or by the
/// group's (`:p/keys`). A keyword entry in `:keys` is itself the key.
fn destructureKeyEntry(b: Builder, group: KeyGroup, group_ns: ?[]const u8, entry: *const Form, src: *Form, defaults: []const *Form, out: *std.ArrayList(*Form)) ExpandError!void {
    const parts: reader_mod.Name = switch (stripMeta(entry).datum) {
        .symbol => |sym| sym,
        .keyword => |kw| if (group == .keys) kw else return b.ctx.fail(entry.origin, "destructuring: :{s} takes names, not {s}", .{ @tagName(group), describeForm(entry) }),
        else => return b.ctx.fail(entry.origin, "destructuring: :{s} takes names, not {s}", .{ @tagName(group), describeForm(entry) }),
    };
    const key_name: reader_mod.Name = .{ .ns = parts.ns orelse group_ns, .name = parts.name };
    const key: *Form = switch (group) {
        .keys => try makeForm(b.ctx, .{ .keyword = key_name }, b.origin),
        .strs => try makeForm(b.ctx, .{ .string = parts.name }, b.origin),
        .syms => try b.list(.{ "quote", try makeForm(b.ctx, .{ .symbol = key_name }, b.origin) }),
    };
    try out.appendSlice(b.ctx.allocator, &.{ try makeSymbol(b.ctx, parts.name, b.origin), try getCall(b, src, key, lookupDefault(defaults, parts.name)) });
}

/// `(nexis.core/get src key default?)`.
fn getCall(b: Builder, src: *Form, key: *const Form, default: ?*const Form) ExpandError!*Form {
    if (default) |d| return b.list(.{ "nexis.core/get", src, key, d });
    return b.list(.{ "nexis.core/get", src, key });
}

/// The source a rest pattern destructures: a map pattern after `&`
/// takes keyword arguments, so the rest seq becomes the map
/// `nexis.internal/#%kwargs` builds from it (`k v k v ...`, or one
/// trailing map); any other pattern takes the seq itself.
fn restSource(b: Builder, rest_pattern: *const Form, rest: *Form) ExpandError!*Form {
    if (stripMeta(rest_pattern).datum != .map) return rest;
    return b.list(.{ "nexis.internal/#%kwargs", rest });
}

/// The `:or` default for the local `name`, if any.
fn lookupDefault(defaults: []const *Form, name: []const u8) ?*const Form {
    var i: usize = 0;
    while (i + 1 < defaults.len) : (i += 2) {
        const k = defaults[i];
        if (k.datum == .symbol and std.mem.eql(u8, k.datum.symbol.name, name)) return defaults[i + 1];
    }
    return null;
}

/// `(defn name ...)` → `(def name (fn name ...))`, so params
/// destructure and overload clauses work as for `fn`, wrapped by
/// `withVarMeta` when the definition carries metadata.
fn expandDefnMacro(ctx: *ExpandContext, call_form: *const Form, args: []const *Form) ExpandError!*Form {
    return defnForm(ctx, call_form, args, false);
}

/// `(defn- name ...)`: `defn` with `:private true` on the Var.
fn expandDefnPrivate(ctx: *ExpandContext, call_form: *const Form, args: []const *Form) ExpandError!*Form {
    return defnForm(ctx, call_form, args, true);
}

fn defnForm(ctx: *ExpandContext, call_form: *const Form, args: []const *Form, private: bool) ExpandError!*Form {
    const parts = try defnParts(ctx, call_form, args, private);
    const origin = call_form.origin;
    const b = Builder{ .ctx = ctx, .origin = origin };
    const def_form = try b.list(.{ "def", parts.name, try b.list(.{ "nexis.core/fn", parts.name, parts.fn_tail }) });
    return try withVarMeta(ctx, def_form, parts.meta, origin);
}

/// The parts of `(defn NAME "doc"? {attrs}? tail)` and of `defmacro`
/// spelled the same way: the name, the fn tail (a parameter vector
/// and body, or overload clauses) and the Var metadata, from `^meta`
/// on the name, `:private true` when `private` (`defn-`), the
/// docstring and the attribute map, with `:arglists` (quoted) added
/// when there is any.
const DefnParts = struct {
    name: *const Form,
    fn_tail: []const *Form,
    meta: []const *Form,
};

fn defnParts(ctx: *ExpandContext, call_form: *const Form, args: []const *Form, private: bool) ExpandError!DefnParts {
    const what = call_form.datum.list[0].datum.symbol.name;
    const origin = call_form.origin;
    if (args.len < 2) return ctx.fail(origin, "{s}: expected a name and a parameter vector", .{what});
    const named = try splitMetaName(ctx, args[0]);
    var meta: std.ArrayList(*Form) = .empty;
    if (private) try meta.appendSlice(ctx.allocator, &.{ try makeKeyword(ctx, "private", origin), try makeBool(ctx, true, origin) });
    if (named.meta) |m| try meta.appendSlice(ctx.allocator, m);
    var rest: usize = 1;
    if (rest < args.len and args[rest].datum == .string) {
        try meta.appendSlice(ctx.allocator, &.{ try makeKeyword(ctx, "doc", args[rest].origin), mutCast(args[rest]) });
        rest += 1;
    }
    if (rest < args.len and args[rest].datum == .map) {
        try meta.appendSlice(ctx.allocator, args[rest].datum.map);
        rest += 1;
    }
    if (rest >= args.len) return ctx.fail(origin, "{s}: expected a parameter vector", .{what});
    const tail = args[rest..];
    if (meta.items.len > 0) {
        var lists: std.ArrayList(*Form) = .empty;
        if (stripMeta(tail[0]).datum == .vector) {
            try lists.append(ctx.allocator, try stripParams(ctx, tail[0]));
        } else for (tail) |clause| {
            if (clause.datum != .list or clause.datum.list.len == 0) return ctx.fail(clause.origin, "{s}: expected ([params] body...), not {s}", .{ what, describeForm(clause) });
            try lists.append(ctx.allocator, try stripParams(ctx, clause.datum.list[0]));
        }
        try meta.appendSlice(ctx.allocator, &.{
            try makeKeyword(ctx, "arglists", origin),
            try (Builder{ .ctx = ctx, .origin = origin }).list(.{ "quote", try makeList(ctx, lists.items, origin) }),
        });
    }
    return .{ .name = named.name, .fn_tail = tail, .meta = meta.items };
}

// ---- when / when-not / and / or / cond ------------------------
//
//   (when t body...)      => (if t (do body...) nil)
//   (when-not t body...)  => (if t nil (do body...))
//   (and) => true   (and x) => x   (and x y ...) => (let* [g x] (if g (and y ...) g))
//   (or)  => nil    (or x)  => x   (or x y ...)  => (let* [g x] (if g g (or y ...)))
//   (cond t1 e1 t2 e2 ...) => (if t1 e1 (if t2 e2 ... nil))
//
// `and` and `or` return the deciding value itself and bind the
// first operand to a gensym so it is evaluated once. `cond` has no
// `:else` case: a keyword test is truthy.

fn expandWhen(ctx: *ExpandContext, call_form: *const Form, args: []const *Form) ExpandError!*Form {
    if (args.len < 1) return ctx.fail(call_form.origin, "when: expected a test", .{});
    const b = Builder{ .ctx = ctx, .origin = call_form.origin };
    return b.list(.{ "if", args[0], try b.list(.{ "do", args[1..] }), null });
}

fn expandWhenNot(ctx: *ExpandContext, call_form: *const Form, args: []const *Form) ExpandError!*Form {
    if (args.len < 1) return ctx.fail(call_form.origin, "when-not: expected a test", .{});
    const b = Builder{ .ctx = ctx, .origin = call_form.origin };
    return b.list(.{ "if", args[0], null, try b.list(.{ "do", args[1..] }) });
}

fn expandAnd(ctx: *ExpandContext, call_form: *const Form, args: []const *Form) ExpandError!*Form {
    return andOr(ctx, call_form, args, .and_);
}

fn expandOr(ctx: *ExpandContext, call_form: *const Form, args: []const *Form) ExpandError!*Form {
    return andOr(ctx, call_form, args, .or_);
}

fn andOr(ctx: *ExpandContext, call_form: *const Form, args: []const *Form, comptime op: enum { and_, or_ }) ExpandError!*Form {
    const b = Builder{ .ctx = ctx, .origin = call_form.origin };
    const name = if (op == .and_) "and" else "or";
    if (args.len == 0) return if (op == .and_) b.item(true) else b.item(null);
    if (args.len == 1) return mutCast(args[0]);
    const rest = if (args.len == 2) mutCast(args[1]) else try b.list(.{ name, args[1..] });
    const g = try b.gensym(name);
    const test_form = if (op == .and_) try b.list(.{ "if", g, rest, g }) else try b.list(.{ "if", g, g, rest });
    return b.list(.{ "let*", try b.vec(.{ g, args[0] }), test_form });
}

fn expandCond(ctx: *ExpandContext, call_form: *const Form, args: []const *Form) ExpandError!*Form {
    if (args.len % 2 != 0) return ctx.fail(call_form.origin, "cond: needs an even number of forms", .{});
    const b = Builder{ .ctx = ctx, .origin = call_form.origin };
    var chain = try b.item(null);
    var i = args.len;
    // A last test that is a truthy literal (`:else`) is no test.
    if (i >= 2 and isTruthyLiteral(args[i - 2])) {
        chain = mutCast(args[i - 1]);
        i -= 2;
    }
    while (i >= 2) : (i -= 2) chain = try b.list(.{ "if", args[i - 2], args[i - 1], chain });
    return chain;
}

/// A form whose value is known truthy without running code: a
/// keyword, `true`, a number, a string or a char.
fn isTruthyLiteral(form: *const Form) bool {
    return switch (form.datum) {
        .keyword, .int, .bigint, .real, .string, .char => true,
        .bool_ => |v| v,
        else => false,
    };
}

// ---- case / condp ------------------------------------------------
//
//   (case e k1 v1 k2 v2 ... default?), fewer than three constants
//     => (let* [g e] (if (= g 'k1) v1 (if (= g 'k2) v2 ... terminal)))
//   three or more, no two of which could be `=` while spelled
//   differently: one hashed lookup of the clause's index in a
//   constant map, then fixnum compares, each one instruction
//     => (let* [g e i (get '{k1 0 k2 1 ...} g -1)]
//          (if (== i 0) v1 (if (== i 1) v2 ... terminal)))
//     (without `g` when there is a default: e goes straight to get)
//   (condp pred e c1 v1 ... default?)
//     => (let* [p pred g e] (if (p c1 g) v1 ... terminal))
//   a clause `c :>> f` calls `f` on the predicate's truthy result.
//
// A `case` key is a constant, never evaluated: a symbol key is that
// symbol, a vector or map key that literal, and a list key `(k1 k2)`
// groups alternatives. The terminal is the trailing odd form when
// there is one, else the throw of `{:error :no-matching-clause
// :message "No matching clause: <e>" :value e}` (Clojure's
// IllegalArgumentException carries the same message). The dispatch
// value, and condp's predicate, are evaluated once. The map's lookup
// is `=`'s equality (dispatch.equal and its hash). Two constants
// that are `=` but spelled differently (`[1]` and a grouped `(1)`)
// would be one key of the map, where the chain lets the first clause
// win, so a case with two compound constants (or two bignums) keeps
// the chain. The map lists the constants in clause order, so they
// are interned in source order.

fn expandCase(ctx: *ExpandContext, call_form: *const Form, args: []const *Form) ExpandError!*Form {
    if (args.len == 0) return ctx.fail(call_form.origin, "case: expected an expression", .{});
    const b = Builder{ .ctx = ctx, .origin = call_form.origin };
    const g = try b.gensym("case");
    const clauses = args[1..];
    var keys: std.ArrayList(*const Form) = .empty;
    var k: usize = 0;
    while (k + 1 < clauses.len) : (k += 2) {
        const key = clauses[k];
        const alternatives: []const *Form = if (key.datum == .list) key.datum.list else &.{key};
        for (alternatives) |alt| {
            for (keys.items) |seen| if (try sameConstant(seen, alt)) return ctx.fail(alt.origin, "case: duplicate test constant", .{});
            try keys.append(ctx.allocator, alt);
        }
    }
    const has_default = clauses.len % 2 == 1;
    var chain = if (has_default) mutCast(clauses[clauses.len - 1]) else try noMatchThrow(b, g);
    if (keys.items.len < 3 or mayShareKey(keys.items)) {
        var i = clauses.len / 2;
        while (i > 0) {
            i -= 1;
            chain = try b.list(.{ "if", try caseTest(b, g, clauses[2 * i]), clauses[2 * i + 1], chain });
        }
        return b.list(.{ "let*", try b.vec(.{ g, args[0] }), chain });
    }
    const index = try b.gensym("case");
    var table: std.ArrayList(*Form) = .empty;
    for (0..clauses.len / 2) |c| {
        const key = clauses[2 * c];
        const alternatives: []const *Form = if (key.datum == .list) key.datum.list else &.{key};
        for (alternatives) |alt| try table.appendSlice(ctx.allocator, &.{ mutCast(alt), try b.item(c) });
    }
    var i = clauses.len / 2;
    while (i > 0) {
        i -= 1;
        const key = clauses[2 * i];
        if (key.datum == .list and key.datum.list.len == 0) continue;
        chain = try b.list(.{ "if", try b.list(.{ "nexis.core/==", index, i }), clauses[2 * i + 1], chain });
    }
    const lookup = try b.list(.{ "nexis.core/get", try b.list(.{ "quote", try makeForm(ctx, .{ .map = table.items }, b.origin) }), if (has_default) args[0] else g, -1 });
    const bindings = if (has_default) try b.vec(.{ index, lookup }) else try b.vec(.{ g, args[0], index, lookup });
    return b.list(.{ "let*", bindings, chain });
}

/// Whether two of the `case` constants `keys`, none the same datum
/// as another, could still be `=`: two compound constants (a list is
/// `=` to a vector of the same items, a map to one listing its
/// entries in another order) or two bignums.
fn mayShareKey(keys: []const *const Form) bool {
    var compounds: usize = 0;
    var bignums: usize = 0;
    for (keys) |k| switch (k.datum) {
        .int, .real, .char, .string, .keyword, .symbol, .nil, .bool_ => {},
        .bigint => bignums += 1,
        else => compounds += 1,
    };
    return compounds > 1 or bignums > 1;
}

/// Whether the `case` constants `a` and `b` are one datum: the same
/// literal atom, or collections of one kind whose items are, in order.
fn sameConstant(a: *const Form, b: *const Form) ExpandError!bool {
    try checkStack();
    switch (a.datum) {
        .list, .vector, .map, .set => |items| {
            if (std.meta.activeTag(a.datum) != std.meta.activeTag(b.datum)) return false;
            const other = switch (b.datum) {
                .list, .vector, .map, .set => |x| x,
                else => unreachable,
            };
            if (items.len != other.len) return false;
            for (items, other) |x, y| if (!try sameConstant(x, y)) return false;
            return true;
        },
        else => return reader_mod.formLiteralEq(a, b),
    }
}

/// The test for one `case` key: `(= g 'k)`, or for a group of
/// alternatives `(if (= g 'k1) true (if (= g 'k2) true ... false))`.
fn caseTest(b: Builder, g: *Form, key: *const Form) ExpandError!*Form {
    const quoted = struct {
        fn eq(bb: Builder, gg: *Form, k: *const Form) ExpandError!*Form {
            return bb.list(.{ "nexis.core/=", gg, try bb.list(.{ "quote", k }) });
        }
    };
    if (key.datum != .list) return quoted.eq(b, g, key);
    const alternatives = key.datum.list;
    var test_form = try b.item(false);
    var i = alternatives.len;
    while (i > 0) {
        i -= 1;
        test_form = if (i == alternatives.len - 1)
            try quoted.eq(b, g, alternatives[i])
        else
            try b.list(.{ "if", try quoted.eq(b, g, alternatives[i]), true, test_form });
    }
    return test_form;
}

fn expandCondp(ctx: *ExpandContext, call_form: *const Form, args: []const *Form) ExpandError!*Form {
    if (args.len < 2) return ctx.fail(call_form.origin, "condp: expected a predicate and an expression", .{});
    const b = Builder{ .ctx = ctx, .origin = call_form.origin };
    const p = try b.gensym("condp-pred");
    const g = try b.gensym("condp-expr");
    // Clauses `test result` or `test :>> f`, then an optional default.
    const Clause = struct { test_form: *const Form, result: *const Form, thread: bool };
    var clauses: std.ArrayList(Clause) = .empty;
    var rest = args[2..];
    while (rest.len >= 2) {
        const threads = rest.len >= 3 and rest[1].datum == .keyword and rest[1].datum.keyword.ns == null and std.mem.eql(u8, rest[1].datum.keyword.name, ">>");
        try clauses.append(ctx.allocator, .{ .test_form = rest[0], .result = rest[if (threads) 2 else 1], .thread = threads });
        rest = rest[if (threads) 3 else 2..];
    }
    var chain = if (rest.len == 1) mutCast(rest[0]) else try noMatchThrow(b, g);
    var i = clauses.items.len;
    while (i > 0) {
        i -= 1;
        const c = clauses.items[i];
        const test_call = try b.list(.{ p, c.test_form, g });
        chain = if (c.thread) blk: {
            const r = try b.gensym("condp-result");
            break :blk try b.list(.{ "let*", try b.vec(.{ r, test_call }), try b.list(.{ "if", r, try b.list(.{ c.result, r }), chain }) });
        } else try b.list(.{ "if", test_call, c.result, chain });
    }
    return b.list(.{ "let*", try b.vec(.{ p, args[0], g, args[1] }), chain });
}

/// The no-match fallthrough of `case` and `condp` for the dispatch
/// value bound to `g`.
fn noMatchThrow(b: Builder, g: *Form) ExpandError!*Form {
    const message = try makeForm(b.ctx, .{ .string = "No matching clause: " }, b.origin);
    return b.list(.{ "throw", try b.map(.{ ":error", ":no-matching-clause", ":message", try b.list(.{ "nexis.core/str", message, g }), ":value", g }) });
}

// ---- for ----------------------------------------------------
//
// Eager `for`: `(for [pattern src modifiers... ...] body)` fills a
// vector and returns it as a seq (a list; `()` when empty), as
// Clojure's lazy `for` prints. Each binding pair may be followed by `:let [bindings]`,
// `:when test` and `:while test`, in any number and order; a
// pattern destructures through `let`. One loop per binding pair,
// nested, carrying the vector as its accumulator:
//
//   (loop* [s# (seq src) acc# <outer acc or []>]
//     (if s#
//       (let [pattern (first s#)]
//         <modifiers, innermost first:
//            :let [b]  → (let [b] inner)
//            :when t   → (if t inner (recur (next s#) acc#))
//            :while t  → (if t inner acc#)
//          where inner is (recur (next s#) <next loop over acc#>)
//          or, at the last pair, (recur (next s#) (conj acc# body))>)
//       acc#))
//
// `:while` ends the loop it modifies (its accumulator is returned
// as is), `:when` skips the element, and both see the pattern and
// any earlier `:let`.

fn expandFor(ctx: *ExpandContext, call_form: *const Form, args: []const *Form) ExpandError!*Form {
    if (args.len != 2 or args[0].datum != .vector) return ctx.fail(call_form.origin, "for: expected a binding vector and one body form", .{});
    const bindings = args[0].datum.vector;
    if (bindings.len == 0 or bindings.len % 2 != 0) return ctx.fail(args[0].origin, "for: the binding vector needs pairs", .{});
    if (bindings[0].datum == .keyword) return ctx.fail(bindings[0].origin, "for: a modifier needs a binding before it", .{});
    const b = Builder{ .ctx = ctx, .origin = call_form.origin };
    // The vector the loops fill, as a seq; `()` when empty.
    const s = try b.gensym("nx");
    return b.list(.{ "let*", try b.vec(.{ s, try b.list(.{ "nexis.core/seq", try forLevel(b, bindings, try b.vec(.{}), args[1]) }) }), try b.list(.{ "if", s, s, try b.list(.{}) }) });
}

/// The loop for the binding pair at the head of `bindings` (with
/// the modifiers after it), accumulating onto `outer_acc`.
fn forLevel(b: Builder, bindings: []const *Form, outer_acc: *Form, body: *const Form) ExpandError!*Form {
    var end: usize = 2;
    while (end < bindings.len and bindings[end].datum == .keyword) end += 2;
    const s = try b.gensym("nx");
    const acc = try b.gensym("nx");
    const next_s = try b.list(.{ "nexis.core/next", s });

    var inner = try b.list(.{ "recur", next_s, if (end < bindings.len)
        try forLevel(b, bindings[end..], acc, body)
    else
        try b.list(.{ "nexis.core/conj", acc, body }) });
    var m = end;
    while (m > 2) {
        m -= 2;
        const key = bindings[m].datum.keyword;
        const value = bindings[m + 1];
        if (key.ns != null) return b.ctx.fail(bindings[m].origin, "for: unknown modifier :{s}/{s}", .{ key.ns.?, key.name });
        inner = if (std.mem.eql(u8, key.name, "let"))
            try b.list(.{ "nexis.core/let", value, inner })
        else if (std.mem.eql(u8, key.name, "when"))
            try b.list(.{ "if", value, inner, try b.list(.{ "recur", next_s, acc }) })
        else if (std.mem.eql(u8, key.name, "while"))
            try b.list(.{ "if", value, inner, acc })
        else
            return b.ctx.fail(bindings[m].origin, "for: unknown modifier :{s}", .{key.name});
    }
    const with_elem = try b.list(.{ "nexis.core/let", try b.vec(.{ bindings[0], try b.list(.{ "nexis.core/first", s }) }), inner });
    return b.list(.{
        "loop*",
        try b.vec(.{ s, try b.list(.{ "nexis.core/seq", bindings[1] }), acc, outer_acc }),
        try b.list(.{ "if", s, with_elem, acc }),
    });
}

// ---- defrecord / defprotocol / extend-type / extend-protocol ----
//
// PROTOCOLS.md §4.
//
//   (defrecord Counter [n] IFoo (bar [this y] ...) IBar (baz [this] ...))
//   → (do
//       (def Counter-type-id (nexis.internal/#%register-record-type "<ns>/Counter" [:n]))
//       (defn ->Counter [n] (nexis.internal/#%make-record Counter-type-id (assoc {} :n n)))
//       (defn map->Counter [m] (nexis.internal/#%make-record Counter-type-id m))
//       (defn Counter? [x] (and (nexis.internal/#%record? x)
//                               (= Counter-type-id (nexis.internal/#%record-type-id x))))
//       (nexis.internal/#%extend-record-impl IFoo :bar Counter-type-id (fn [this y] ...))
//       (nexis.internal/#%extend-record-impl IBar :baz Counter-type-id (fn [this] ...)))
//
// After the field vector, a bare symbol names the protocol the method
// clauses `(name [params] body...)` that follow implement.

/// The Vars `(defrecord T [...])` defines besides `T` itself. The
/// compiler's `DeclaredNames` reads the same table, so a form may
/// refer to `->T` before the `defrecord` that produces it.
pub const RecordNames = struct {
    type_id: []u8,
    ctor: []u8,
    map_ctor: []u8,
    pred: []u8,

    pub fn typeId(allocator: std.mem.Allocator, rec_name: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}-type-id", .{rec_name});
    }

    pub fn init(allocator: std.mem.Allocator, rec_name: []const u8) !RecordNames {
        const type_id = try typeId(allocator, rec_name);
        errdefer allocator.free(type_id);
        const ctor = try std.fmt.allocPrint(allocator, "->{s}", .{rec_name});
        errdefer allocator.free(ctor);
        const map_ctor = try std.fmt.allocPrint(allocator, "map->{s}", .{rec_name});
        errdefer allocator.free(map_ctor);
        const pred = try std.fmt.allocPrint(allocator, "{s}?", .{rec_name});
        return .{ .type_id = type_id, .ctor = ctor, .map_ctor = map_ctor, .pred = pred };
    }

    pub fn deinit(self: *RecordNames, allocator: std.mem.Allocator) void {
        for (self.all()) |name| allocator.free(name);
    }

    pub fn all(self: *const RecordNames) [4][]const u8 {
        return .{ self.type_id, self.ctor, self.map_ctor, self.pred };
    }
};

/// An unqualified symbol's name, or a failure naming `what`.
fn plainName(ctx: *ExpandContext, form: *const Form, comptime what: []const u8) ExpandError![]const u8 {
    if (form.datum != .symbol or form.datum.symbol.ns != null) return ctx.fail(form.origin, what ++ " must be an unqualified symbol, not {s}", .{describeForm(form)});
    return form.datum.symbol.name;
}

/// The name `name` qualified by the current namespace, as a string
/// form: the registry key of a record type or protocol.
fn qualifiedNameString(b: Builder, name: []const u8) ExpandError!*Form {
    const ns_name: []const u8 = if (b.ctx.namespace) |ns| ns.name else "";
    return makeForm(b.ctx, .{ .string = try std.fmt.allocPrint(b.ctx.allocator, "{s}/{s}", .{ ns_name, name }) }, b.origin);
}

fn expandDefrecord(ctx: *ExpandContext, call_form: *const Form, args: []const *Form) ExpandError!*Form {
    if (args.len < 2 or stripMeta(args[1]).datum != .vector) return ctx.fail(call_form.origin, "defrecord: expected a name and a field vector", .{});
    const b = Builder{ .ctx = ctx, .origin = call_form.origin };
    const rec_name = try plainName(ctx, args[0], "defrecord: the name");
    const fields = (try stripParams(ctx, args[1])).datum.vector;
    const keys = try ctx.allocator.alloc(*Form, fields.len);
    for (fields, keys) |field, *key| key.* = try b.kw(try plainName(ctx, field, "defrecord: a field"));
    const names = try RecordNames.init(ctx.allocator, rec_name);
    const type_id = try b.item(names.type_id);

    const entries = try ctx.allocator.alloc(*Form, 2 * fields.len);
    for (fields, keys, 0..) |field, key, i| {
        entries[2 * i] = key;
        entries[2 * i + 1] = field;
    }
    const field_map = try b.map(.{entries});

    var out: std.ArrayList(*Form) = .empty;
    try out.appendSlice(ctx.allocator, &.{
        try b.item("do"),
        try b.list(.{ "def", type_id, try b.list(.{ "nexis.internal/#%register-record-type", try qualifiedNameString(b, rec_name), try b.vec(.{keys}) }) }),
        try b.list(.{ "nexis.core/defn", names.ctor, try b.vec(.{fields}), try b.list(.{ "nexis.internal/#%make-record", type_id, field_map }) }),
        try b.list(.{ "nexis.core/defn", names.map_ctor, try b.vec(.{"m"}), try b.list(.{ "nexis.internal/#%make-record", type_id, "m" }) }),
        try b.list(.{ "nexis.core/defn", names.pred, try b.vec(.{"x"}), try b.list(.{
            "nexis.core/and",
            try b.list(.{ "nexis.internal/#%record?", "x" }),
            try b.list(.{ "nexis.core/=", type_id, try b.list(.{ "nexis.internal/#%record-type-id", "x" }) }),
        }) }),
    });
    try extendClauses(b, args[2..], .{ .record = .{ .name = args[0], .fields = fields } }, &out);
    // The name is the record's type, as Clojure's class: the symbol
    // `ns.Name` that `type` returns, so `(instance? P x)` reads as in
    // Clojure; the form's value is that type.
    const ns_name: []const u8 = if (ctx.namespace) |ns| ns.name else "user";
    const type_sym = try b.item(try std.fmt.allocPrint(ctx.allocator, "{s}.{s}", .{ ns_name, rec_name }));
    try out.append(ctx.allocator, try b.list(.{ "def", try b.item(rec_name), try b.list(.{ "quote", type_sym }) }));
    try out.append(ctx.allocator, try b.item(rec_name));
    return makeList(ctx, out.items, b.origin);
}

/// One arity `([this p...] body...)` of an inline `defrecord` method
/// with the record's fields in scope, as in Clojure: `([g p...]
/// (let* [f (nexis.core/get g :f) ...] (let [this g] body...)))`. A
/// field named anywhere in the parameters is left out, so a
/// parameter shadows it; a field assoc'd onto the record is what the
/// method sees.
fn recordArity(b: Builder, fields: []const *Form, arity: *const Form) ExpandError!*Form {
    const items = arity.datum.list;
    const params = (try stripParams(b.ctx, items[0])).datum.vector;
    if (params.len == 0) return b.ctx.fail(items[0].origin, "a record method takes the record as its first parameter", .{});
    const g = try b.gensym("this");
    var bindings: std.ArrayList(*Form) = .empty;
    for (fields) |field| {
        if (try namesSymbol(items[0], field.datum.symbol.name)) continue;
        try bindings.appendSlice(b.ctx.allocator, &.{ field, try b.list(.{ "nexis.core/get", g, try b.kw(field.datum.symbol.name) }) });
    }
    const body = try b.list(.{ "nexis.core/let", try b.vec(.{ params[0], g }), items[1..] });
    return b.list(.{ try b.vec(.{ g, params[1..] }), try b.list(.{ "let*", try b.vec(.{bindings.items}), body }) });
}

/// Whether the symbol `name` appears anywhere in `form`.
fn namesSymbol(form: *const Form, name: []const u8) ExpandError!bool {
    try checkStack();
    switch (form.datum) {
        .symbol => |sym| return sym.ns == null and std.mem.eql(u8, sym.name, name),
        .list, .vector, .map, .set => |items| {
            for (items) |item| if (try namesSymbol(item, name)) return true;
            return false;
        },
        .with_meta => |wm| return namesSymbol(wm.target, name),
        else => return false,
    }
}

fn expandDefprotocol(ctx: *ExpandContext, call_form: *const Form, args: []const *Form) ExpandError!*Form {
    if (args.len < 1) return ctx.fail(call_form.origin, "defprotocol: expected a name", .{});
    const b = Builder{ .ctx = ctx, .origin = call_form.origin };
    const proto_name = try plainName(ctx, args[0], "defprotocol: the name");
    // A docstring and `:option value` pairs may precede the methods.
    var specs = args[1..];
    if (specs.len > 0 and specs[0].datum == .string) specs = specs[1..];
    while (specs.len >= 2 and specs[0].datum == .keyword) specs = specs[2..];
    const method_keys = try ctx.allocator.alloc(*Form, specs.len);
    const defs = try ctx.allocator.alloc(*Form, specs.len);
    for (specs, method_keys, defs) |spec, *key, *def| {
        if (spec.datum != .list or spec.datum.list.len == 0) return ctx.fail(spec.origin, "defprotocol: expected a method signature (name [params]...), not {s}", .{describeForm(spec)});
        const method = try plainName(ctx, spec.datum.list[0], "defprotocol: a method name");
        key.* = try b.kw(method);
        def.* = try b.list(.{ "def", method, try b.list(.{ "nexis.internal/#%protocol-fn", proto_name, key.* }) });
    }
    return b.list(.{
        "do",
        try b.list(.{ "def", proto_name, try b.list(.{ "nexis.internal/#%register-protocol", try qualifiedNameString(b, proto_name), try b.vec(.{method_keys}) }) }),
        defs,
    });
}

/// What the method clauses of `extend-type`, `extend-protocol` and
/// `defrecord` extend: a fixed type (a record symbol or a kind
/// keyword such as `:string`, `:any` for the default impl) whose
/// clauses name protocols, a fixed protocol whose clauses name
/// types, or the record `defrecord` defines.
const ExtendAnchor = union(enum) {
    type_: *const Form,
    protocol: *const Form,
    record: struct { name: *const Form, fields: []const *Form },
};

fn expandExtendType(ctx: *ExpandContext, call_form: *const Form, args: []const *Form) ExpandError!*Form {
    if (args.len < 1 or (args[0].datum != .symbol and args[0].datum != .keyword)) return ctx.fail(call_form.origin, "extend-type: expected a type", .{});
    return extendForm(ctx, call_form, args[1..], .{ .type_ = args[0] });
}

fn expandExtendProtocol(ctx: *ExpandContext, call_form: *const Form, args: []const *Form) ExpandError!*Form {
    if (args.len < 1 or args[0].datum != .symbol) return ctx.fail(call_form.origin, "extend-protocol: expected a protocol", .{});
    return extendForm(ctx, call_form, args[1..], .{ .protocol = args[0] });
}

fn extendForm(ctx: *ExpandContext, call_form: *const Form, clauses: []const *Form, anchor: ExtendAnchor) ExpandError!*Form {
    const b = Builder{ .ctx = ctx, .origin = call_form.origin };
    var out: std.ArrayList(*Form) = .empty;
    try out.append(ctx.allocator, try b.item("do"));
    try extendClauses(b, clauses, anchor, &out);
    return makeList(ctx, out.items, b.origin);
}

/// One extend call per method in `clauses` onto `out`; a symbol or
/// keyword clause switches the protocol (or, for `extend-protocol`,
/// the type) the following methods belong to. A method's arities are
/// every clause of its name under that header, each `(name [params]
/// body...)` or `(name ([params] body...) ...)`, and its impl one
/// `fn` over them all, so the call's argument count picks the arity.
fn extendClauses(b: Builder, clauses: []const *Form, anchor: ExtendAnchor, out: *std.ArrayList(*Form)) ExpandError!void {
    var current: ?*const Form = null;
    var start: usize = 0;
    while (start < clauses.len) {
        const clause = clauses[start];
        if (isExtendHeader(clause, anchor)) {
            current = clause;
            start += 1;
            continue;
        }
        const other = current orelse return b.ctx.fail(clause.origin, "a method needs a protocol name before it", .{});
        var end = start;
        while (end < clauses.len and !isExtendHeader(clauses[end], anchor)) : (end += 1) {
            const c = clauses[end];
            if (c.datum != .list or c.datum.list.len < 2) return b.ctx.fail(c.origin, "expected a protocol name or a method (name [params] body...), not {s}", .{describeForm(c)});
            _ = try plainName(b.ctx, c.datum.list[0], "a method name");
        }
        const run = clauses[start..end];
        for (run, 0..) |method, i| {
            const name = method.datum.list[0].datum.symbol.name;
            if (methodIndex(run[0..i], name) != null) continue;
            var arities: std.ArrayList(*Form) = .empty;
            for (run[i..]) |same| {
                if (!std.mem.eql(u8, same.datum.list[0].datum.symbol.name, name)) continue;
                try methodArities(b.ctx, same, &arities);
            }
            var clauses_out: std.ArrayList(*Form) = .empty;
            for (arities.items) |arity| {
                try clauses_out.append(b.ctx.allocator, if (anchor == .record) try recordArity(.{ .ctx = b.ctx, .origin = arity.origin }, anchor.record.fields, arity) else arity);
            }
            const impl = if (clauses_out.items.len == 1)
                try b.list(.{ "nexis.core/fn", clauses_out.items[0].datum.list })
            else
                try b.list(.{ "nexis.core/fn", clauses_out.items });
            const protocol, const type_form = switch (anchor) {
                .type_ => |t| .{ other, t },
                .protocol => |p| .{ p, other },
                .record => |r| .{ other, r.name },
            };
            try out.append(b.ctx.allocator, try extendCall(b, protocol, type_form, try b.kw(name), impl));
        }
        start = end;
    }
}

/// Whether `clause` names the protocol (or, for `extend-protocol`,
/// the type) the methods after it belong to.
fn isExtendHeader(clause: *const Form, anchor: ExtendAnchor) bool {
    return clause.datum == .symbol or (clause.datum == .keyword and anchor == .protocol);
}

/// The position in `methods` of the first clause named `name`.
fn methodIndex(methods: []const *Form, name: []const u8) ?usize {
    for (methods, 0..) |m, i| if (std.mem.eql(u8, m.datum.list[0].datum.symbol.name, name)) return i;
    return null;
}

/// The arities `([params] body...)` of one method clause onto `out`:
/// `(name [params] body...)` has one, at the clause's span, and
/// `(name ([params] body...) ...)` lists its own.
fn methodArities(ctx: *ExpandContext, method: *const Form, out: *std.ArrayList(*Form)) ExpandError!void {
    const items = method.datum.list;
    if (stripMeta(items[1]).datum == .vector) return out.append(ctx.allocator, try makeList(ctx, items[1..], method.origin));
    for (items[1..]) |arity| {
        if (arity.datum != .list or arity.datum.list.len == 0 or stripMeta(arity.datum.list[0]).datum != .vector)
            return ctx.fail(arity.origin, "expected the method's parameter vector or its arities ([params] body...), not {s}", .{describeForm(arity)});
        try out.append(ctx.allocator, mutCast(arity));
    }
}

/// The call installing `impl` as `protocol`'s method for a type: a
/// kind keyword (`:string`), `:any` (the default impl) or a record
/// symbol (through its `<Name>-type-id`).
fn extendCall(b: Builder, protocol: *const Form, type_form: *const Form, method_key: *Form, impl: *Form) ExpandError!*Form {
    switch (type_form.datum) {
        .keyword => |kw| {
            if (std.mem.eql(u8, kw.name, "any")) return b.list(.{ "nexis.internal/#%extend-default-impl", protocol, method_key, impl });
            return b.list(.{ "nexis.internal/#%extend-builtin-impl", protocol, method_key, try b.kw(kw.name), impl });
        },
        .symbol => |sym| {
            const type_id = try RecordNames.typeId(b.ctx.allocator, sym.name);
            return b.list(.{ "nexis.internal/#%extend-record-impl", protocol, method_key, type_id, impl });
        },
        else => return b.ctx.fail(type_form.origin, "expected a record name or a kind keyword, not {s}", .{describeForm(type_form)}),
    }
}

/// The `nexis.core` function `name` as a qualified symbol: what a
/// host macro emits wherever its output calls a core function, so a
/// user local or Var of the same name cannot capture the call
/// (MACROEXPAND.md §5). Heads that are themselves host macros or
/// special forms stay bare.
fn coreSym(ctx: *ExpandContext, name: []const u8, origin: reader_mod.SrcSpan) ExpandError!*Form {
    return try makeQualifiedSymbol(ctx, "nexis.core", name, origin);
}

// ---- -> / ->> ------------------------------------------------
//
//   (-> x (f a) g)   => (g (f x a))       thread-first
//   (->> x (f a) g)  => (g (f a x))       thread-last
//
// A step that is not a list (a symbol, a keyword) is called with the
// threaded value alone.

fn expandThreadFirst(ctx: *ExpandContext, call_form: *const Form, args: []const *Form) ExpandError!*Form {
    return thread(ctx, call_form, args, .first);
}

fn expandThreadLast(ctx: *ExpandContext, call_form: *const Form, args: []const *Form) ExpandError!*Form {
    return thread(ctx, call_form, args, .last);
}

fn thread(ctx: *ExpandContext, call_form: *const Form, args: []const *Form, comptime pos: enum { first, last }) ExpandError!*Form {
    const name = if (pos == .first) "->" else "->>";
    if (args.len == 0) return ctx.fail(call_form.origin, name ++ ": expected a value to thread", .{});
    const b = Builder{ .ctx = ctx, .origin = call_form.origin };
    var acc = mutCast(args[0]);
    for (args[1..]) |step| {
        if (step.datum != .list) {
            acc = try b.list(.{ step, acc });
            continue;
        }
        const items = step.datum.list;
        if (items.len == 0) return ctx.fail(step.origin, name ++ ": a step cannot be ()", .{});
        acc = if (pos == .first) try b.list(.{ items[0], acc, items[1..] }) else try b.list(.{ items, acc });
    }
    return acc;
}

// =============================================================================
// Syntax-quote (MACROEXPAND.md §5)
// =============================================================================
//
// `` `payload `` becomes a form that constructs the quoted shape at
// run time through the `#%list` / `#%concat` / `#%vector` / `#%map`
// / `#%set` primitives. Each syntax-quote has its own auto-gensym
// scope; the counter behind it is process-wide, so two scopes never
// produce the same name.

/// One syntax-quote's auto-gensyms: every `x#` in it names the same
/// fresh `x__N__auto__`, and another syntax-quote gets another.
pub const GensymScope = struct {
    mappings: std.StringHashMapUnmanaged([]const u8) = .{},

    pub fn deinit(self: *GensymScope, allocator: Allocator) void {
        self.mappings.deinit(allocator);
    }

    /// The gensym for `name` (which ends in `#`), made on first use.
    fn lookupOrAllocate(self: *GensymScope, ctx: *ExpandContext, name: []const u8) ExpandError![]const u8 {
        const entry = try self.mappings.getOrPut(ctx.allocator, name);
        if (!entry.found_existing) entry.value_ptr.* = try ctx.gensym(name[0 .. name.len - 1]);
        return entry.value_ptr.*;
    }
};

/// The construction form of a syntax-quoted `payload`. Symbols
/// qualify as in Clojure (PLAN §23 #29): an unqualified symbol
/// becomes `ns/name` for the namespace that holds its Var (the
/// current namespace, one it refers to, or `nexis.core` for a host
/// macro), or `<current-ns>/name` when nothing holds it. `name#` is
/// an auto-gensym and stays bare; so do the special forms, `&`, the
/// catch matcher `any`, `#%` internals and the `%` parameters of
/// `#()`. A qualified symbol keeps its prefix, with an alias
/// resolved to the namespace it names. Without a named namespace (a
/// bare `Namespace` in tests) nothing qualifies.
fn syntaxQuote(ctx: *ExpandContext, scope: *GensymScope, payload: *const Form) ExpandError!*Form {
    try checkStack();
    const b = Builder{ .ctx = ctx, .origin = payload.origin };
    return switch (payload.datum) {
        // Self-evaluating: no quote needed.
        .nil, .bool_, .int, .bigint, .real, .char, .string, .keyword => mutCast(payload),
        .symbol => |name| b.list(.{ "quote", if (name.ns) |ns_prefix| blk: {
            const target = aliasTarget(ctx, ns_prefix);
            break :blk if (target.ptr == ns_prefix.ptr) mutCast(payload) else try makeQualifiedSymbol(ctx, target, name.name, payload.origin);
        } else if (name.name.len > 1 and name.name[name.name.len - 1] == '#')
            try makeSymbol(ctx, try scope.lookupOrAllocate(ctx, name.name), payload.origin)
        else if (syntaxQuoteNamespace(ctx, name.name)) |ns_name|
            try makeQualifiedSymbol(ctx, ns_name, name.name, payload.origin)
        else
            mutCast(payload) }),
        // Evaluated where the construction form runs.
        .unquote => |inner| mutCast(inner),
        .unquote_splicing => ctx.fail(payload.origin, "~@ splices only into a list, vector, map or set", .{}),
        inline .list, .vector, .map, .set => |items, tag| try syntaxQuoteColl(b, scope, items, tag),
        // `'x` is the list `(quote x)`, `x` walked like any payload:
        // `` `'a `` is `(quote ns/a)`, `` `'~x `` is `(quote <x>)`.
        .quote => |inner| b.list(.{ "#%list", try b.list(.{ "quote", "quote" }), try syntaxQuote(ctx, scope, inner) }),
        .deref => |inner| b.list(.{ "#%list", try b.list(.{ "quote", "nexis.core/deref" }), try syntaxQuote(ctx, scope, inner) }),
        // The `fn*` form a `#()` stands for; its `%` parameters stay
        // bare (see the symbol arm).
        .anon_fn => |items| try syntaxQuote(ctx, scope, try anonFnForm(ctx, payload, items)),
        // `^m coll` is the collection carrying `m`, as in Clojure.
        // Any other `^m x` builds the list `(nexis.internal/#%meta x
        // m)`, which a macro's result turns back into `^m x`: a symbol
        // value cannot carry the metadata itself (`(def ^:private
        // ~name ...)`).
        .with_meta => |wm| switch (wm.target.datum) {
            .list, .vector, .map, .set => b.list(.{ "nexis.core/with-meta", try syntaxQuote(ctx, scope, wm.target), try syntaxQuote(ctx, scope, wm.meta) }),
            else => b.list(.{
                "#%list",
                try b.list(.{ "quote", "nexis.internal/#%meta" }),
                try syntaxQuote(ctx, scope, wm.target),
                try syntaxQuote(ctx, scope, wm.meta),
            }),
        },
        // Clojure's rule: the inner syntax-quote becomes its
        // construction form first, in its own gensym scope, and the
        // outer one quotes that, so `~~x` is unquoted by the outer.
        .syntax_quote => |inner| blk: {
            var inner_scope = GensymScope{};
            defer inner_scope.deinit(ctx.allocator);
            break :blk try syntaxQuote(ctx, scope, try syntaxQuote(ctx, &inner_scope, inner));
        },
    };
}

/// Whether `items` is `(nexis.internal/#%meta target {meta})`, the
/// list a syntax-quoted `^meta` builds.
fn isMetaMarker(items: []const *Form) bool {
    if (items.len != 3 or items[2].datum != .map or items[0].datum != .symbol) return false;
    const head = items[0].datum.symbol;
    return head.ns != null and std.mem.eql(u8, head.ns.?, "nexis.internal") and std.mem.eql(u8, head.name, "#%meta");
}

/// Symbols syntax-quote leaves unqualified besides auto-gensyms:
/// the special forms, the `try` clause heads, `&` in a parameter
/// vector, the catch matcher `any`, the `#%` internals and the `%`
/// parameters of `#()`.
fn isSyntaxQuoteBare(name: []const u8) bool {
    const others = std.StaticStringMap(void).initComptime(.{ .{"catch"}, .{"finally"}, .{"&"}, .{"any"} });
    return isSpecialFormName(name) or others.has(name) or std.mem.startsWith(u8, name, "%");
}

/// The namespace an unqualified symbol qualifies to inside
/// syntax-quote, or null to leave it bare: the namespace in the
/// current namespace's refer chain whose own Var it names,
/// `nexis.core` for a host macro, otherwise the current namespace.
/// Null without a named namespace.
fn syntaxQuoteNamespace(ctx: *ExpandContext, name: []const u8) ?[]const u8 {
    if (isSyntaxQuoteBare(name)) return null;
    const ns = ctx.namespace orelse return null;
    if (ns.name.len == 0) return null;
    var cur: ?*const vm_mod.Namespace = ns;
    while (cur) |n| : (cur = n.parent) {
        if (n.lookupLocal(name) != null) return n.name;
    }
    if (ctx.host_macros.get(name) != null) return "nexis.core";
    return ns.name;
}

/// The construction form of a syntax-quoted collection. Without a
/// splice its items build it directly (`#%list` / `#%vector` /
/// `#%map` / `#%set`). With one, runs of ordinary items become
/// `(#%list ...)` segments, each `~@x` is a segment of its own, the
/// segments are concatenated at run time, and a vector, map or set
/// is rebuilt from the list through `nexis.core/vec`,
/// `nexis.core/hash-map` or `nexis.core/hash-set`.
fn syntaxQuoteColl(b: Builder, scope: *GensymScope, items: []const *Form, comptime kind: std.meta.Tag(Datum)) ExpandError!*Form {
    const ctx = b.ctx;
    var segments: std.ArrayList(*Form) = .empty;
    var run: std.ArrayList(*Form) = .empty;
    var spliced = false;
    for (items) |item| {
        if (item.datum == .unquote_splicing) {
            spliced = true;
            if (run.items.len > 0) try segments.append(ctx.allocator, try b.list(.{ "#%list", try run.toOwnedSlice(ctx.allocator) }));
            try segments.append(ctx.allocator, item.datum.unquote_splicing);
        } else {
            try run.append(ctx.allocator, try syntaxQuote(ctx, scope, item));
        }
    }
    const head = switch (kind) {
        .list => "#%list",
        .vector => "#%vector",
        .map => "#%map",
        .set => "#%set",
        else => unreachable,
    };
    if (!spliced) return b.list(.{ head, run.items });
    if (run.items.len > 0) try segments.append(ctx.allocator, try b.list(.{ "#%list", run.items }));
    const concat = try b.list(.{ "#%concat", segments.items });
    return switch (kind) {
        .list => concat,
        .vector => b.list(.{ "nexis.core/vec", concat }),
        .map => b.list(.{ "nexis.core/apply", "nexis.core/hash-map", concat }),
        .set => b.list(.{ "nexis.core/apply", "nexis.core/hash-set", concat }),
        else => unreachable,
    };
}

// ---- Default macro table -------------------------------------

/// Build the standard host-macro table the runtime compiles with
/// (`CompileOptions.host_macros`). The caller owns the table and
/// calls `table.deinit(allocator)`.
pub fn defaultMacros(allocator: Allocator) ExpandError!HostMacroTable {
    var table: HostMacroTable = .{};
    errdefer table.deinit(allocator);
    try table.put(allocator, "let", expandLetRename);
    try table.put(allocator, "fn", expandFnRename);
    try table.put(allocator, "defn", expandDefnMacro);
    try table.put(allocator, "defn-", expandDefnPrivate);
    try table.put(allocator, "loop", expandLoopRename);
    try table.put(allocator, "when", expandWhen);
    try table.put(allocator, "when-not", expandWhenNot);
    try table.put(allocator, "and", expandAnd);
    try table.put(allocator, "or", expandOr);
    try table.put(allocator, "cond", expandCond);
    try table.put(allocator, "->", expandThreadFirst);
    try table.put(allocator, "->>", expandThreadLast);
    try table.put(allocator, "case", expandCase);
    try table.put(allocator, "condp", expandCondp);
    try table.put(allocator, "for", expandFor);
    // defrecord (records + inline protocol clauses).
    try table.put(allocator, "defrecord", expandDefrecord);
    try table.put(allocator, "defprotocol", expandDefprotocol);
    try table.put(allocator, "extend-type", expandExtendType);
    try table.put(allocator, "extend-protocol", expandExtendProtocol);
    return table;
}

// =============================================================================
// Inline tests
// =============================================================================

const testing = std.testing;

/// Build a tiny test harness: parse `src`, run through the
/// expander with the given macro table, return the resulting
/// Form for caller inspection. Allocator is the arena owning
/// the parsed form (caller must keep it alive).
fn expandSourceForTest(
    arena: Allocator,
    src: []const u8,
    host_macros: *const HostMacroTable,
) !*Form {
    var p = try reader_mod.parser.parseForm(arena, src);
    defer p.parser.deinit();
    var rdr = reader_mod.Reader.init(arena, src);
    defer rdr.deinit();
    const form = try rdr.readOneForm(p.sexp);

    var interner = intern_mod.Interner.init(arena);
    // NOTE: interner is in the arena, so deinit not strictly
    // necessary, but explicit cleanup is good hygiene.
    defer interner.deinit();
    var ctx = ExpandContext{
        .allocator = arena,
        .interner = &interner,
        .host_macros = host_macros,
    };
    return try expandForm(&ctx, null, form);
}

/// Expand `src` with the default host macros and expect `expected`,
/// with `message` recorded against the source text `at`.
fn expectFailure(src: []const u8, expected: ExpandError, message: []const u8, at: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const table = try defaultMacros(arena);
    var p = try reader_mod.parser.parseForm(arena, src);
    defer p.parser.deinit();
    var rdr = reader_mod.Reader.init(arena, src);
    defer rdr.deinit();
    const form = try rdr.readOneForm(p.sexp);
    var interner = intern_mod.Interner.init(arena);
    defer interner.deinit();
    var ctx = ExpandContext{ .allocator = arena, .interner = &interner, .host_macros = &table };
    try testing.expectError(expected, expandForm(&ctx, null, form));
    const failure = ctx.failure orelse return error.TestExpectedFailure;
    try testing.expectEqualStrings(message, failure.message);
    try testing.expectEqualStrings(at, src[failure.span.pos..][0..failure.span.len]);
}

test "failure: a malformed form records a message at the innermost form" {
    const M = ExpandError.MalformedMacroCall;
    try expectFailure("(let [a] a)", M, "let: the binding vector needs an even number of forms", "[a]");
    try expectFailure("(let* [a 1] (loop [b] b))", M, "loop: the binding vector needs an even number of forms", "[b]");
    try expectFailure("(let [1 2] 3)", M, "cannot bind an integer", "1");
    try expectFailure("(let [{:keys k} {}] k)", M, ":keys takes a vector of names, not a symbol", "k");
    try expectFailure("(defn f)", M, "defn: expected a name and a parameter vector", "(defn f)");
    try expectFailure("(defn \"f\" [] 1)", M, "the name defined must be an unqualified symbol, not a string", "\"f\"");
    try expectFailure("(fn x)", M, "fn: expected a parameter vector", "(fn x)");
    try expectFailure("(do 1 (+ 2 (cond 1)))", M, "cond: needs an even number of forms", "(cond 1)");
    try expectFailure("(do 1 (+ 2 (when)))", M, "when: expected a test", "(when)");
    try expectFailure("(let [x 1] (set! x 2))", M, "set!: x is a local, not a Var", "x");
}

test "failure: a macro that fails without a message is named at its call" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Wrap = struct {
        fn refuse(_: *ExpandContext, _: *const Form, _: []const *Form) ExpandError!*Form {
            return ExpandError.MalformedMacroCall;
        }
    };
    var table: HostMacroTable = .{};
    try table.put(arena, "refuse", Wrap.refuse);
    const src = "(do 1 (+ 2 (refuse 3)))";
    var p = try reader_mod.parser.parseForm(arena, src);
    defer p.parser.deinit();
    var rdr = reader_mod.Reader.init(arena, src);
    defer rdr.deinit();
    const form = try rdr.readOneForm(p.sexp);
    var interner = intern_mod.Interner.init(arena);
    defer interner.deinit();
    var ctx = ExpandContext{ .allocator = arena, .interner = &interner, .host_macros = &table };
    try testing.expectError(ExpandError.MalformedMacroCall, expandForm(&ctx, null, form));
    try testing.expectEqualStrings("malformed (refuse ...)", ctx.failure.?.message);
    try testing.expectEqualStrings("(refuse 3)", src[ctx.failure.?.span.pos..][0..ctx.failure.?.span.len]);
}

test "unwrapQuote: the reader's quote datum and a written-out (quote x) both unwrap" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{ "'x", "(quote x)" }) |src| {
        var p = try reader_mod.parser.parseForm(arena, src);
        defer p.parser.deinit();
        var rdr = reader_mod.Reader.init(arena, src);
        defer rdr.deinit();
        const form = try rdr.readOneForm(p.sexp);
        const inner = unwrapQuote(form);
        try testing.expect(inner.datum == .symbol);
        try testing.expectEqualStrings("x", inner.datum.symbol.name);
    }
    for ([_][]const u8{ "x", "(quote x y)", "(other x)" }) |src| {
        var p = try reader_mod.parser.parseForm(arena, src);
        defer p.parser.deinit();
        var rdr = reader_mod.Reader.init(arena, src);
        defer rdr.deinit();
        const form = try rdr.readOneForm(p.sexp);
        try testing.expect(unwrapQuote(form) == form);
    }
}

test "set!: expands to var-set on the Var; a lexical target is refused at expansion" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const empty: HostMacroTable = .{};
    const out = try expandSourceForTest(arena, "(set! *x* (+ 1 2))", &empty);
    try testing.expect(out.datum == .list);
    const items = out.datum.list;
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqualStrings("nexis.core", items[0].datum.symbol.ns.?);
    try testing.expectEqualStrings("var-set", items[0].datum.symbol.name);
    const var_form = items[1].datum.list;
    try testing.expectEqual(@as(usize, 2), var_form.len);
    try testing.expectEqualStrings("var", var_form[0].datum.symbol.name);
    try testing.expectEqualStrings("*x*", var_form[1].datum.symbol.name);
    try testing.expect(items[2].datum == .list);
    try testing.expectError(ExpandError.MalformedMacroCall, expandSourceForTest(arena, "(let* [x 1] (set! x 2))", &empty));
    try testing.expectError(ExpandError.MalformedMacroCall, expandSourceForTest(arena, "(fn* [x] (set! x 2))", &empty));
    try testing.expectError(ExpandError.MalformedMacroCall, expandSourceForTest(arena, "(set! 1 2)", &empty));
    try testing.expectError(ExpandError.MalformedMacroCall, expandSourceForTest(arena, "(set! *x*)", &empty));
}

test "macroexpand: no-op walks return input unchanged (empty table)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const empty: HostMacroTable = .{};
    // A variety of forms — all should pass through with no
    // macro fires. We compare pretty-printed output against
    // round-trip via the reader for stability.
    const fixtures = [_][]const u8{
        "42",
        "true",
        "nil",
        ":kw",
        "x",
        "(+ 1 2)",
        "(if (< x 10) :small :big)",
        "(do (def y 1) y)",
        "(let* [a 1 b 2] (+ a b))",
        "(loop* [i 0] (if (< i 10) (recur (+ i 1)) i))",
        "(fn* [x y] (+ x y))",
        "(fn* fact [n] (if (< n 2) n (recur (+ n -1))))",
        "(letfn* [(f [x] (g x)) (g [x] x)] (f 7))",
        "(defn add [x y] (+ x y))",
        "(quote foo)",
        "'foo",
        "(quote (when x y))", // critical: quote opaque, when NOT expanded
    };
    for (fixtures) |src| {
        // With an empty macro table, the expander never fires
        // a macro. Top-level Datum tag must be preserved (the
        // expander never mutates a form's tag, only rebuilds
        // list/vector subtrees when binding-form helpers run).
        const original_tag: std.meta.Tag(Datum) = blk: {
            var p = try reader_mod.parser.parseForm(arena, src);
            defer p.parser.deinit();
            var rdr = reader_mod.Reader.init(arena, src);
            defer rdr.deinit();
            const f = try rdr.readOneForm(p.sexp);
            break :blk std.meta.activeTag(f.datum);
        };
        const expanded = try expandSourceForTest(arena, src, &empty);
        try testing.expectEqual(original_tag, std.meta.activeTag(expanded.datum));
    }
}

test "macroexpand: empty list passes through" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const empty: HostMacroTable = .{};
    // `()` — expander returns the empty list; lowerForm will
    // catch the empty-call malformation.
    const result = try expandSourceForTest(arena, "()", &empty);
    try testing.expect(result.datum == .list);
    try testing.expectEqual(@as(usize, 0), result.datum.list.len);
}

test "macroexpand: depth limit caught for infinite macro loop" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A pathological macro that returns the same call form
    // it received — infinite loop.
    const Wrap = struct {
        fn loopForever(
            _: *ExpandContext,
            call_form: *const Form,
            _: []const *Form,
        ) ExpandError!*Form {
            return mutCast(call_form);
        }
    };
    var table: HostMacroTable = .{};
    defer table.deinit(arena);
    try table.put(arena, "boom", Wrap.loopForever);

    var p = try reader_mod.parser.parseForm(arena, "(boom)");
    defer p.parser.deinit();
    var rdr = reader_mod.Reader.init(arena, "(boom)");
    defer rdr.deinit();
    const form = try rdr.readOneForm(p.sexp);

    var interner = intern_mod.Interner.init(arena);
    defer interner.deinit();
    var ctx = ExpandContext{
        .allocator = arena,
        .interner = &interner,
        .host_macros = &table,
    };
    try testing.expectError(ExpandError.ExpansionDepthExceeded, expandForm(&ctx, null, form));
}

test "macroexpand: nesting past the stack budget is ExpansionDepthExceeded, not a fault" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    stack.arm(64 * 1024);
    defer stack.arm(stack.main_thread_budget);
    // (do (do ... (do 1) ...)) nested far deeper than 64 KiB of frames.
    var form = try arena.create(Form);
    form.* = .{ .datum = .{ .int = 1 }, .origin = .{ .pos = 0, .len = 0 } };
    const do_sym = try arena.create(Form);
    do_sym.* = .{ .datum = .{ .symbol = .{ .ns = null, .name = "do" } }, .origin = .{ .pos = 0, .len = 0 } };
    for (0..20_000) |_| {
        const items = try arena.alloc(*Form, 2);
        items[0] = do_sym;
        items[1] = form;
        const outer = try arena.create(Form);
        outer.* = .{ .datum = .{ .list = items }, .origin = .{ .pos = 0, .len = 0 } };
        form = outer;
    }
    var interner = intern_mod.Interner.init(arena);
    defer interner.deinit();
    const empty: HostMacroTable = .{};
    var ctx = ExpandContext{ .allocator = arena, .interner = &interner, .host_macros = &empty };
    try testing.expectError(ExpandError.ExpansionDepthExceeded, expandForm(&ctx, null, form));
}

test "macroexpand: lexical shadowing blocks macro expansion" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A macro that, if fired, would replace `(my-macro)` with
    // `:fired`. Inside a let* binding `my-macro` to anything,
    // the macro MUST NOT fire.
    const Wrap = struct {
        fn fireIt(
            ctx: *ExpandContext,
            call_form: *const Form,
            _: []const *Form,
        ) ExpandError!*Form {
            const kw_id = ctx.interner.internKeyword("fired") catch return ExpandError.OutOfMemory;
            const form = try ctx.allocator.create(Form);
            form.* = .{
                .datum = .{ .keyword = .{ .ns = null, .name = ctx.interner.keywordName(kw_id) } },
                .origin = call_form.origin,
            };
            return form;
        }
    };
    var table: HostMacroTable = .{};
    defer table.deinit(arena);
    try table.put(arena, "my-macro", Wrap.fireIt);

    // (let* [my-macro 0] (my-macro)) — macro is shadowed.
    var p = try reader_mod.parser.parseForm(arena, "(let* [my-macro 0] (my-macro))");
    defer p.parser.deinit();
    var rdr = reader_mod.Reader.init(arena, "(let* [my-macro 0] (my-macro))");
    defer rdr.deinit();
    const form = try rdr.readOneForm(p.sexp);

    var interner = intern_mod.Interner.init(arena);
    defer interner.deinit();
    var ctx = ExpandContext{
        .allocator = arena,
        .interner = &interner,
        .host_macros = &table,
    };
    const expanded = try expandForm(&ctx, null, form);
    // The expanded form should still be a let* with an inner
    // (my-macro) call — NOT a :fired keyword.
    try testing.expect(expanded.datum == .list);
    const outer = expanded.datum.list;
    try testing.expect(outer.len == 3);
    // outer[2] is the body — should be a list (my-macro), NOT
    // a keyword :fired.
    try testing.expect(outer[2].datum == .list);
}

test "macroexpand: macro fires at top level when not shadowed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Wrap = struct {
        fn fireIt(
            ctx: *ExpandContext,
            call_form: *const Form,
            _: []const *Form,
        ) ExpandError!*Form {
            const kw_id = ctx.interner.internKeyword("fired") catch return ExpandError.OutOfMemory;
            const form = try ctx.allocator.create(Form);
            form.* = .{
                .datum = .{ .keyword = .{ .ns = null, .name = ctx.interner.keywordName(kw_id) } },
                .origin = call_form.origin,
            };
            return form;
        }
    };
    var table: HostMacroTable = .{};
    defer table.deinit(arena);
    try table.put(arena, "my-macro", Wrap.fireIt);

    var p = try reader_mod.parser.parseForm(arena, "(my-macro)");
    defer p.parser.deinit();
    var rdr = reader_mod.Reader.init(arena, "(my-macro)");
    defer rdr.deinit();
    const form = try rdr.readOneForm(p.sexp);

    var interner = intern_mod.Interner.init(arena);
    defer interner.deinit();
    var ctx = ExpandContext{
        .allocator = arena,
        .interner = &interner,
        .host_macros = &table,
    };
    const expanded = try expandForm(&ctx, null, form);
    try testing.expect(expanded.datum == .keyword);
    try testing.expectEqualStrings("fired", expanded.datum.keyword.name);
}

test "macroexpand: quote is opaque — macro inside quote does NOT fire" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Wrap = struct {
        fn fireIt(_: *ExpandContext, call_form: *const Form, _: []const *Form) ExpandError!*Form {
            // If ever called, return nil so the failure is obvious.
            const form = std.heap.page_allocator.create(Form) catch unreachable;
            form.* = .{ .datum = .nil, .origin = call_form.origin };
            return form;
        }
    };
    var table: HostMacroTable = .{};
    defer table.deinit(arena);
    try table.put(arena, "my-macro", Wrap.fireIt);

    var p = try reader_mod.parser.parseForm(arena, "(quote (my-macro))");
    defer p.parser.deinit();
    var rdr = reader_mod.Reader.init(arena, "(quote (my-macro))");
    defer rdr.deinit();
    const form = try rdr.readOneForm(p.sexp);

    var interner = intern_mod.Interner.init(arena);
    defer interner.deinit();
    var ctx = ExpandContext{
        .allocator = arena,
        .interner = &interner,
        .host_macros = &table,
    };
    const expanded = try expandForm(&ctx, null, form);
    // Should still be (quote (my-macro)), NOT nil.
    try testing.expect(expanded.datum == .list);
}
