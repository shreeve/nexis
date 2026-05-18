//! Phase 2 step #8a — macroexpander scaffold.
//!
//! See `docs/MACROEXPAND.md` for the full design contract;
//! this file implements §1 (execution model) + §2b (per-form
//! traversal rules) + §6 (depth limit) + §8 (error model) for
//! the no-op-traversal initial commit. Steps #8b (host core
//! macros) and #8c (syntax-quote + auto-gensym + native list/
//! concat) build on this scaffold.
//!
//! What this file DOES (#8a):
//!   - Defines `ExpandContext`, `MacroFn`, `HostMacroTable`,
//!     `ExpandEnv`, `ExpandError`.
//!   - Implements `expandForm`: per-form-rule walker that
//!     recognizes every Phase-2 special form, threads ExpandEnv
//!     correctly through binding forms, and dispatches macro
//!     calls through the host table. With an empty table, the
//!     output is structurally identical to the input.
//!   - Treats `quote` and `syntax_quote` as OPAQUE (does not
//!     recurse into them). syntax_quote will become a transform
//!     rule in step #8c.
//!   - Enforces a depth limit (256) and reports
//!     `MacroDepthExceeded` distinctly from
//!     `MacroExpansionFailure`.
//!
//! What this file does NOT do yet:
//!   - Provide any host macros (`#8b`).
//!   - Handle syntax_quote / unquote / unquote_splicing
//!     transformation (`#8c`).
//!   - User `defmacro` (deferred to Phase 3 with compile-time
//!     VM eval).

const std = @import("std");
const reader_mod = @import("reader");
const intern_mod = @import("intern");
/// Phase 3.2: needed for Namespace + Var lookup (user-defmacro
/// dispatch), Value construction (Form→Value conversion for
/// macro args), and the VM type referenced by the compile-eval
/// callback type signature. expand.zig was reader+intern only
/// before this; adding vm here pulls in champ + dispatch +
/// vector + heap + list transitively. No cycle: compile.zig
/// imports expand AND vm; vm doesn't import expand.
const vm_mod = @import("vm");
const value_mod = @import("value");
const list_mod = @import("list");
const vector_mod = @import("vector");
const champ_mod = @import("champ");
const heap_mod = @import("heap");

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
    MacroReturnedNull,
    OutOfMemory,
};

/// Phase 3.2 (peer-AI turn 66): callback for compile-time
/// evaluation of arbitrary Form trees. Used by `defmacro` to
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

/// Phase 3.6 (peer-AI turn 71): callback used by `(require ...)`
/// to load a namespace from disk. Set by the CLI / test harness.
/// The callback is responsible for ALL file-loading concerns
/// (path resolution, parsing, compilation, evaluation, registry
/// updates, cycle detection). The expander just decodes the
/// `(require ...)` arg and dispatches.
pub const LoadCallback = struct {
    user_data: *anyopaque,
    load: *const fn (user_data: *anyopaque, ns_name: []const u8) anyerror!void,
};

/// Per-spec MACROEXPAND.md §1: bundles every cross-cutting
/// resource a host MacroFn might need. Lives FOR THE LIFETIME
/// of a single compilation unit (typically one CLI invocation
/// or one test). Reusing across forms is how auto-gensym stays
/// monotonic within a unit.
pub const ExpandContext = struct {
    allocator: Allocator,
    interner: *intern_mod.Interner,
    /// Monotonic auto-gensym counter (peer-AI turn 56 §1.4 +
    /// §5: lives on the context, NOT the VM). Used by host
    /// macros that need to avoid double-evaluation (e.g. `or`).
    gensym_next: u64 = 0,
    /// Macro registry. May be empty (#8a default → no expansion
    /// fires).
    host_macros: *const HostMacroTable,
    /// Phase 3.2: namespace for user-defmacro lookup. When
    /// expanding `(my-fn ...)`, if `my-fn` resolves to a Var
    /// whose `.macro = true`, dispatch as a user macro instead
    /// of an ordinary call. Null = no namespace = no user
    /// macros (useful for tests that exercise host-macro-only
    /// expansion).
    namespace: ?*vm_mod.Namespace = null,
    /// Phase 3.2: compile-time eval callback. Set by
    /// `compile.zig` when building the ExpandContext. The
    /// `defmacro` handler uses this to compile + evaluate the
    /// macro fn's body via a fresh sub-VM. Null = `defmacro`
    /// raises MacroExpansionFailure.
    compile_eval: ?CompileEvalContext = null,
    /// Phase 3.4: when set, `(ns NAME)` special form switches
    /// the current namespace via `registry.switchTo(NAME)`. The
    /// CLI sets this; ad-hoc tests can leave it null (in which
    /// case `(ns NAME)` raises MalformedMacroCall).
    registry: ?*vm_mod.NamespaceRegistry = null,
    /// Phase 3.6: when set, `(require ...)` special form calls
    /// through this callback to load a namespace from disk.
    /// Null = `(require ...)` raises MalformedMacroCall (useful
    /// for tests that compile in-memory only).
    load_callback: ?LoadCallback = null,
    /// Phase 3.2: lazy-init heap for arg Value construction.
    /// Macro args that are vectors/maps/sets need a heap for
    /// their backing nodes. We use ExpandContext.allocator
    /// (the compile arena) so the nodes outlive the fresh
    /// sub-VM (which has its OWN heap for the macro fn's
    /// runtime allocations). Reuse across macro invocations
    /// — cheap because allocator is an arena.
    _arg_heap: ?heap_mod.Heap = null,

    /// Lazy-init the arg-construction heap. Returns a pointer
    /// good for the lifetime of the ExpandContext.
    pub fn heapForArgs(self: *ExpandContext) ExpandError!*heap_mod.Heap {
        if (self._arg_heap == null) {
            self._arg_heap = heap_mod.Heap.init(self.allocator);
        }
        return &self._arg_heap.?;
    }

    /// Allocate a fresh gensym name in the context's arena.
    /// Format: `<base>__<counter>__auto__` per MACROEXPAND.md §4.
    /// The `__auto__` suffix marks auto-gensym (vs future
    /// user-controlled `(gensym base)`).
    ///
    /// Lifetime: the returned slice lives in `ctx.allocator`,
    /// which is the macroexpand arena (typically the same as
    /// the compile arena). The caller does NOT free.
    pub fn gensym(self: *ExpandContext, base: []const u8) ExpandError![]const u8 {
        const counter = self.gensym_next;
        self.gensym_next += 1;
        return std.fmt.allocPrint(self.allocator, "{s}__{d}__auto__", .{ base, counter });
    }
};

/// Host-Zig macro callback. Takes the call form (head + args)
/// and produces a rewritten form. The result is then re-fed to
/// `expandForm` (so macro-of-macros works automatically).
pub const MacroFn = *const fn (
    ctx: *ExpandContext,
    call_form: *const Form,
    args: []const *Form,
) ExpandError!*Form;

/// Maps unqualified symbol name → MacroFn. v1 uses an empty
/// table by default; #8b populates with when/cond/and/or/etc.
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

/// MACROEXPAND.md §6 — matches Clojure's default. The expander
/// increments depth on EACH macro expansion (not on tree-walk
/// recursion). Catches infinite macro loops without limiting
/// legitimate deep source.
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

/// Walk an array of top-level forms (e.g. file contents).
/// Output is a fresh slice in `ctx.allocator`. The same
/// gensym counter is reused across all forms so gensyms stay
/// unique within the unit.
pub fn expandProgram(
    ctx: *ExpandContext,
    forms: []const *Form,
) ExpandError![]const *Form {
    const out = try ctx.allocator.alloc(*Form, forms.len);
    for (forms, 0..) |form, i| {
        out[i] = try expandForm(ctx, null, form);
    }
    return out;
}

// =============================================================================
// Internal walker
// =============================================================================

fn expandFormDepth(
    ctx: *ExpandContext,
    env: ?*const ExpandEnv,
    form: *const Form,
    depth: u32,
) ExpandError!*Form {
    if (depth > MAX_EXPANSION_DEPTH) return ExpandError.ExpansionDepthExceeded;

    return switch (form.datum) {
        // ---- Leaves — pass through unchanged. -----------------
        .nil, .bool_, .int, .real, .char, .string, .keyword, .symbol => mutCast(form),
        // ---- Lists — special-form recognition + macro dispatch. --
        .list => |items| try expandList(ctx, env, form, items, depth),
        // Phase 3.1: vector/map/set are now real expressions
        // (lowerForm builds runtime values via coll:vector /
        // coll:map / coll:set). Walk into each item so macros
        // inside collection literals expand.
        // NB: let*/loop*/fn*/letfn* binding vectors are still
        // handled by their dedicated walkers (which do their
        // own per-form traversal); this arm catches top-level
        // collection-literal expressions.
        .vector => |items| try expandCollKind(ctx, env, form, items, depth, .vector_),
        .map => |items| try expandCollKind(ctx, env, form, items, depth, .map_),
        .set => |items| try expandCollKind(ctx, env, form, items, depth, .set_),
        // ---- Quote — OPAQUE per MACROEXPAND.md §2b. ----------
        // The expander does NOT recurse into the payload of a
        // quote form. `(quote (when x y))` MUST NOT expand
        // `when` — it's a literal symbol/list value.
        .quote => mutCast(form),
        // ---- Syntax-quote — transform per #8c.2. ----------
        // Open a fresh GensymScope, walk the payload, return
        // the (#%list ...) / (#%concat ...) structure.
        .syntax_quote => |payload| blk: {
            var scope = GensymScope{};
            defer scope.deinit(ctx.allocator);
            const expanded = try expandSyntaxQuotePayload(ctx, &scope, form, payload);
            // Recursively expand the result so that any macros
            // present in unquote payloads expand normally.
            break :blk try expandFormDepth(ctx, env, expanded, depth);
        },
        // ---- Unquote / unquote-splicing OUTSIDE syntax-quote. --
        // Per peer-AI turn 58 §D9 + §"Missing trap 1": defensive
        // error. The reader catches the source-syntax case, but a
        // macro host fn could synthesize one.
        .unquote, .unquote_splicing => return ExpandError.MalformedMacroCall,
        // ---- Reader macros / metadata. -----------------------
        // Phase 3.0b (peer-AI turn 62): `#(...)` shorthand
        // expands here. Reader emits Datum.anon_fn carrying
        // the body forms; macroexpand scans for `%`, `%N`,
        // `%&` references, computes arity, and generates the
        // equivalent `(fn* [params] body...)` form. The
        // result is recursively re-expanded so macros nested
        // in the body still fire.
        .anon_fn => |items| try expandAnonFn(ctx, env, form, items, depth),
        // with_meta is metadata attached to a target form;
        // #8a passes through. Step #10+ may want to expand
        // through the target.
        .with_meta => mutCast(form),
        // deref `@x`: Phase-2 doesn't support atoms, so this
        // is opaque at expansion time. lowerForm raises
        // UnsupportedFeature.
        .deref => mutCast(form),
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

/// Dispatch a list form: check for special form / macro / call.
fn expandList(
    ctx: *ExpandContext,
    env: ?*const ExpandEnv,
    list_form: *const Form,
    items: []const *Form,
    depth: u32,
) ExpandError!*Form {
    // Empty list `()` — pass through (lowerForm catches this
    // and raises MalformedForm).
    if (items.len == 0) return mutCast(list_form);

    // Non-symbol head → ordinary call; expand head + all args.
    const head_form = items[0];
    if (head_form.datum != .symbol) {
        return try expandOrdinaryCall(ctx, env, list_form, items, depth);
    }
    const head_sym = head_form.datum.symbol;

    // Qualified symbols (foo/bar): not Phase-2 surface. Pass
    // through; lowerForm catches and raises UnsupportedFeature.
    if (head_sym.ns != null) {
        return try expandOrdinaryCall(ctx, env, list_form, items, depth);
    }
    const name = head_sym.name;

    // ---- Special forms (NOT shadowable, NOT macro-replaceable). --
    if (std.mem.eql(u8, name, "quote")) return mutCast(list_form);
    if (std.mem.eql(u8, name, "if")) return try expandIf(ctx, env, list_form, items, depth);
    if (std.mem.eql(u8, name, "do")) return try expandDo(ctx, env, list_form, items, depth);
    if (std.mem.eql(u8, name, "let*")) return try expandLetStar(ctx, env, list_form, items, depth);
    if (std.mem.eql(u8, name, "loop*")) return try expandLetStar(ctx, env, list_form, items, depth); // same shape as let*
    if (std.mem.eql(u8, name, "recur")) return try expandRecur(ctx, env, list_form, items, depth);
    if (std.mem.eql(u8, name, "fn*")) return try expandFnStar(ctx, env, list_form, items, depth);
    if (std.mem.eql(u8, name, "letfn*")) return try expandLetFnStar(ctx, env, list_form, items, depth);
    if (std.mem.eql(u8, name, "def")) return try expandDef(ctx, env, list_form, items, depth);
    // Phase 3.5a: `defn` is now a HOST MACRO (expandDefnMacro)
    // that rewrites to `(def name (fn name ...))`. The host
    // macro lives in the macros table; dispatching here would
    // bypass the macro path.
    if (std.mem.eql(u8, name, "var")) return mutCast(list_form); // (var X) — X is just a name, don't expand
    if (std.mem.eql(u8, name, "try")) return try expandTry(ctx, env, list_form, items, depth);
    if (std.mem.eql(u8, name, "throw")) return try expandOrdinaryCall(ctx, env, list_form, items, depth);
    if (std.mem.eql(u8, name, "defmacro")) return try expandDefmacro(ctx, env, list_form, items, depth);
    if (std.mem.eql(u8, name, "ns")) return try expandNs(ctx, list_form, items);
    if (std.mem.eql(u8, name, "require")) return try expandRequire(ctx, list_form, items);
    // Step #8c.1: internal compiler primitives (#%list / #%concat).
    // Recognized as special forms — NOT user-shadowable, NOT
    // looked up in the macro table. Args ARE recursively
    // macroexpanded (per peer-AI turn 58 §D1 + §"Missing trap
    // #6"): a `(#%list (when x y))` should expand `(when x y)`.
    if (std.mem.eql(u8, name, "#%list") or
        std.mem.eql(u8, name, "#%concat") or
        std.mem.eql(u8, name, "#%vector") or
        std.mem.eql(u8, name, "#%map") or
        std.mem.eql(u8, name, "#%set"))
    {
        return try expandOrdinaryCall(ctx, env, list_form, items, depth);
    }

    // ---- Macro dispatch (shadowable by lexical bindings). -----
    // Lookup order (peer-AI turn 66):
    //   1. lexical env (shadowing) — bail to ordinary call.
    //   2. user macros in the namespace (Var.macro = true).
    //   3. host macros table.
    //   4. ordinary call.
    if (env == null or !env.?.contains(name)) {
        // (2) User macro: namespace Var with .macro = true.
        if (ctx.namespace) |ns| {
            if (ns.lookup(name)) |user_var| {
                if (user_var.macro and user_var.bound) {
                    return try invokeUserMacro(ctx, env, user_var, list_form, items, depth);
                }
            }
        }
        // (3) Host macro.
        if (ctx.host_macros.get(name)) |macro_fn| {
            return try invokeMacro(ctx, env, macro_fn, list_form, items, depth);
        }
    }

    // ---- Ordinary call. ---------------------------------------
    return try expandOrdinaryCall(ctx, env, list_form, items, depth);
}

/// Macro fires: call the host fn, then recursively expand the
/// result (macro-of-macros termination per MACROEXPAND.md §6).
fn invokeMacro(
    ctx: *ExpandContext,
    env: ?*const ExpandEnv,
    macro_fn: MacroFn,
    call_form: *const Form,
    items: []const *Form,
    depth: u32,
) ExpandError!*Form {
    const args = items[1..];
    const result = try macro_fn(ctx, call_form, args);
    // Re-feed the macro output through the expander. Depth
    // increments here (per MACROEXPAND.md §6 — depth gates
    // macro applications, not tree-walk recursion).
    return try expandFormDepth(ctx, env, result, depth + 1);
}

// =============================================================================
// Per-special-form walkers (per MACROEXPAND.md §2b table)
// =============================================================================

fn expandIf(
    ctx: *ExpandContext,
    env: ?*const ExpandEnv,
    list_form: *const Form,
    items: []const *Form,
    depth: u32,
) ExpandError!*Form {
    // (if test then) | (if test then else)
    if (items.len < 3 or items.len > 4) return ExpandError.MalformedMacroCall;
    return try rebuildListIfChanged(ctx, list_form, items, env, depth);
}

fn expandDo(
    ctx: *ExpandContext,
    env: ?*const ExpandEnv,
    list_form: *const Form,
    items: []const *Form,
    depth: u32,
) ExpandError!*Form {
    return try rebuildListIfChanged(ctx, list_form, items, env, depth);
}

fn expandRecur(
    ctx: *ExpandContext,
    env: ?*const ExpandEnv,
    list_form: *const Form,
    items: []const *Form,
    depth: u32,
) ExpandError!*Form {
    return try rebuildListIfChanged(ctx, list_form, items, env, depth);
}

fn expandOrdinaryCall(
    ctx: *ExpandContext,
    env: ?*const ExpandEnv,
    list_form: *const Form,
    items: []const *Form,
    depth: u32,
) ExpandError!*Form {
    return try rebuildListIfChanged(ctx, list_form, items, env, depth);
}

/// Common pattern: expand every list item with the same env,
/// rebuild the list ONLY if at least one item changed. Avoids
/// unnecessary allocation when no expansion fires.
fn rebuildListIfChanged(
    ctx: *ExpandContext,
    list_form: *const Form,
    items: []const *Form,
    env: ?*const ExpandEnv,
    depth: u32,
) ExpandError!*Form {
    var new_items: ?[]*Form = null;
    for (items, 0..) |item, i| {
        const expanded = try expandFormDepth(ctx, env, item, depth);
        if (expanded == item) continue;
        // First divergence: clone the slice up to here.
        if (new_items == null) {
            new_items = try ctx.allocator.alloc(*Form, items.len);
            for (items[0..i], 0..) |earlier, j| new_items.?[j] = mutCast(earlier);
        }
        new_items.?[i] = expanded;
    }
    if (new_items == null) return mutCast(list_form);
    // Items past the divergence haven't been visited yet — wait,
    // YES they have (the loop continues), but we only assigned
    // into new_items on divergence. Need to copy/track post-
    // divergence items too.
    //
    // Simpler model: if ANY item changed, do a second pass
    // copying every expansion. Cheap because at #8a the macro
    // table is empty and we never reach this branch.
    const final = try ctx.allocator.alloc(*Form, items.len);
    for (items, 0..) |item, i| {
        final[i] = try expandFormDepth(ctx, env, item, depth);
    }
    return try makeList(ctx, final, list_form.origin);
}

// ---- let* / loop* — sequential binding scope ------------------------------

fn expandLetStar(
    ctx: *ExpandContext,
    env: ?*const ExpandEnv,
    list_form: *const Form,
    items: []const *Form,
    depth: u32,
) ExpandError!*Form {
    // (let* [n1 v1 n2 v2 ...] body...)
    if (items.len < 2) return ExpandError.MalformedMacroCall;
    const head = items[0]; // the `let*` symbol form
    const binding_form = items[1];
    if (binding_form.datum != .vector) return ExpandError.MalformedMacroCall;
    const bindings = binding_form.datum.vector;
    if (bindings.len % 2 != 0) return ExpandError.MalformedMacroCall;

    // Walk bindings with a sequential env. Each binding's RHS
    // sees prior names (and ONLY prior, per COMPILER.md §4.3
    // amendment). Names themselves are NOT expanded.
    var local: ExpandEnv = .{ .parent = env };
    defer local.deinit(ctx.allocator);

    // Output binding vector.
    const new_bindings = try ctx.allocator.alloc(*Form, bindings.len);
    var i: usize = 0;
    while (i < bindings.len) : (i += 2) {
        const name_form = bindings[i];
        if (name_form.datum != .symbol or name_form.datum.symbol.ns != null) {
            return ExpandError.MalformedMacroCall;
        }
        // RHS expanded under env-so-far (BEFORE name added).
        new_bindings[i] = mutCast(name_form);
        new_bindings[i + 1] = try expandFormDepth(ctx, &local, bindings[i + 1], depth);
        // NOW add the binding name to the local env (sequential).
        _ = try local.lexical_names.getOrPut(ctx.allocator, name_form.datum.symbol.name);
    }
    const new_binding_vec = try makeVector(ctx, new_bindings, binding_form.origin);

    // Body: every form expanded under the FULL local env.
    const body = items[2..];
    const new_body = try ctx.allocator.alloc(*Form, body.len);
    for (body, 0..) |b, j| {
        new_body[j] = try expandFormDepth(ctx, &local, b, depth);
    }

    // Reassemble: [let*/loop*, bindings, body...]
    const total = 2 + body.len;
    const out_items = try ctx.allocator.alloc(*Form, total);
    out_items[0] = mutCast(head);
    out_items[1] = new_binding_vec;
    for (new_body, 0..) |b, k| out_items[2 + k] = b;
    return try makeList(ctx, out_items, list_form.origin);
}

// ---- fn* — optional self-name + param vector + body -----------------------

fn expandFnStar(
    ctx: *ExpandContext,
    env: ?*const ExpandEnv,
    list_form: *const Form,
    items: []const *Form,
    depth: u32,
) ExpandError!*Form {
    // (fn* [params] body...) | (fn* name [params] body...)
    if (items.len < 2) return ExpandError.MalformedMacroCall;
    const head = items[0];

    // Detect optional self-name. If items[1] is a symbol, it's
    // the name; items[2] is the param vector. Otherwise items[1]
    // is the param vector.
    var has_name: bool = false;
    var name_form: ?*const Form = null;
    var params_idx: usize = 1;
    if (items[1].datum == .symbol) {
        has_name = true;
        name_form = items[1];
        params_idx = 2;
    }
    if (params_idx >= items.len) return ExpandError.MalformedMacroCall;
    const params_form = items[params_idx];
    if (params_form.datum != .vector) return ExpandError.MalformedMacroCall;
    const body = items[params_idx + 1 ..];

    // Build a child env with the self-name (if any) + param
    // names. Per MACROEXPAND.md §2b: param vector is NOT
    // expanded; only the body is.
    var local: ExpandEnv = .{ .parent = env };
    defer local.deinit(ctx.allocator);
    if (has_name) {
        _ = try local.lexical_names.getOrPut(ctx.allocator, name_form.?.datum.symbol.name);
    }
    for (params_form.datum.vector) |p| {
        if (p.datum != .symbol or p.datum.symbol.ns != null) {
            // Skip `&` rest marker and any non-symbol param
            // shapes. Don't add `&` to env (it's not a binding).
            // For non-symbol params (destructuring), v1 simply
            // doesn't add anything to env (destructuring is
            // post-v1).
            continue;
        }
        if (std.mem.eql(u8, p.datum.symbol.name, "&")) continue;
        _ = try local.lexical_names.getOrPut(ctx.allocator, p.datum.symbol.name);
    }

    // Expand body.
    const new_body = try ctx.allocator.alloc(*Form, body.len);
    for (body, 0..) |b, j| {
        new_body[j] = try expandFormDepth(ctx, &local, b, depth);
    }

    // Reassemble.
    const total = params_idx + 1 + body.len;
    const out_items = try ctx.allocator.alloc(*Form, total);
    out_items[0] = mutCast(head);
    if (has_name) out_items[1] = mutCast(name_form.?);
    out_items[params_idx] = mutCast(params_form);
    for (new_body, 0..) |b, k| out_items[params_idx + 1 + k] = b;
    return try makeList(ctx, out_items, list_form.origin);
}

// ---- letfn* — mutually recursive named fns --------------------------------

fn expandLetFnStar(
    ctx: *ExpandContext,
    env: ?*const ExpandEnv,
    list_form: *const Form,
    items: []const *Form,
    depth: u32,
) ExpandError!*Form {
    // (letfn* [(name [params] body...) ...] body...)
    if (items.len < 2) return ExpandError.MalformedMacroCall;
    const head = items[0];
    const binding_form = items[1];
    if (binding_form.datum != .vector) return ExpandError.MalformedMacroCall;
    const fn_entries = binding_form.datum.vector;

    // First pass: collect every fn name into the local env, so
    // each fn body sees ALL fn names (mutual recursion).
    var local: ExpandEnv = .{ .parent = env };
    defer local.deinit(ctx.allocator);
    for (fn_entries) |entry| {
        if (entry.datum != .list or entry.datum.list.len < 2) {
            return ExpandError.MalformedMacroCall;
        }
        const entry_items = entry.datum.list;
        const fn_name_form = entry_items[0];
        if (fn_name_form.datum != .symbol or fn_name_form.datum.symbol.ns != null) {
            return ExpandError.MalformedMacroCall;
        }
        _ = try local.lexical_names.getOrPut(ctx.allocator, fn_name_form.datum.symbol.name);
    }

    // Second pass: expand each fn body under (local + that fn's
    // params).
    const new_entries = try ctx.allocator.alloc(*Form, fn_entries.len);
    for (fn_entries, 0..) |entry, idx| {
        const entry_items = entry.datum.list;
        const fn_params = entry_items[1];
        if (fn_params.datum != .vector) return ExpandError.MalformedMacroCall;
        const fn_body = entry_items[2..];

        var fn_env: ExpandEnv = .{ .parent = &local };
        defer fn_env.deinit(ctx.allocator);
        for (fn_params.datum.vector) |p| {
            if (p.datum != .symbol or p.datum.symbol.ns != null) continue;
            if (std.mem.eql(u8, p.datum.symbol.name, "&")) continue;
            _ = try fn_env.lexical_names.getOrPut(ctx.allocator, p.datum.symbol.name);
        }
        const new_fn_body = try ctx.allocator.alloc(*Form, fn_body.len);
        for (fn_body, 0..) |b, j| {
            new_fn_body[j] = try expandFormDepth(ctx, &fn_env, b, depth);
        }
        const new_entry_items = try ctx.allocator.alloc(*Form, 2 + fn_body.len);
        new_entry_items[0] = mutCast(entry_items[0]);
        new_entry_items[1] = mutCast(fn_params);
        for (new_fn_body, 0..) |b, k| new_entry_items[2 + k] = b;
        new_entries[idx] = try makeList(ctx, new_entry_items, entry.origin);
    }
    const new_binding_vec = try makeVector(ctx, new_entries, binding_form.origin);

    // letfn body expanded under local env.
    const body = items[2..];
    const new_body = try ctx.allocator.alloc(*Form, body.len);
    for (body, 0..) |b, j| {
        new_body[j] = try expandFormDepth(ctx, &local, b, depth);
    }

    const total = 2 + body.len;
    const out_items = try ctx.allocator.alloc(*Form, total);
    out_items[0] = mutCast(head);
    out_items[1] = new_binding_vec;
    for (new_body, 0..) |b, k| out_items[2 + k] = b;
    return try makeList(ctx, out_items, list_form.origin);
}

// ---- def / defn -----------------------------------------------------------

fn expandDef(
    ctx: *ExpandContext,
    env: ?*const ExpandEnv,
    list_form: *const Form,
    items: []const *Form,
    depth: u32,
) ExpandError!*Form {
    // (def name) | (def name value)
    if (items.len < 2 or items.len > 3) return ExpandError.MalformedMacroCall;
    const head = items[0];
    const name_form = items[1];
    if (name_form.datum != .symbol) return ExpandError.MalformedMacroCall;
    if (items.len == 2) return mutCast(list_form);
    // Expand value only.
    const new_value = try expandFormDepth(ctx, env, items[2], depth);
    if (new_value == items[2]) return mutCast(list_form);
    const out_items = try ctx.allocator.alloc(*Form, 3);
    out_items[0] = mutCast(head);
    out_items[1] = mutCast(name_form);
    out_items[2] = new_value;
    return try makeList(ctx, out_items, list_form.origin);
}

fn expandDefn(
    ctx: *ExpandContext,
    env: ?*const ExpandEnv,
    list_form: *const Form,
    items: []const *Form,
    depth: u32,
) ExpandError!*Form {
    // (defn name [params] body...)
    if (items.len < 3) return ExpandError.MalformedMacroCall;
    const head = items[0];
    const name_form = items[1];
    if (name_form.datum != .symbol) return ExpandError.MalformedMacroCall;
    const params_form = items[2];
    if (params_form.datum != .vector) return ExpandError.MalformedMacroCall;
    const body = items[3..];

    // Body env = self-name + params.
    var local: ExpandEnv = .{ .parent = env };
    defer local.deinit(ctx.allocator);
    _ = try local.lexical_names.getOrPut(ctx.allocator, name_form.datum.symbol.name);
    for (params_form.datum.vector) |p| {
        if (p.datum != .symbol or p.datum.symbol.ns != null) continue;
        if (std.mem.eql(u8, p.datum.symbol.name, "&")) continue;
        _ = try local.lexical_names.getOrPut(ctx.allocator, p.datum.symbol.name);
    }
    const new_body = try ctx.allocator.alloc(*Form, body.len);
    for (body, 0..) |b, j| {
        new_body[j] = try expandFormDepth(ctx, &local, b, depth);
    }
    const total = 3 + body.len;
    const out_items = try ctx.allocator.alloc(*Form, total);
    out_items[0] = mutCast(head);
    out_items[1] = mutCast(name_form);
    out_items[2] = mutCast(params_form);
    for (new_body, 0..) |b, k| out_items[3 + k] = b;
    return try makeList(ctx, out_items, list_form.origin);
}

/// Step #9.1 (peer-AI turn 59 §D4): expand `(try body+
/// (catch MATCHER BINDING handler+) (finally body+)?)`.
///
/// Traversal rule (per MACROEXPAND.md §2b — each special form
/// has its own walker):
///   - body forms expanded with outer env
///   - catch's MATCHER + BINDING NOT expanded (literal symbols)
///   - catch's handler body expanded with outer env + BINDING
///   - finally body expanded with outer env (no new bindings)
fn expandTry(
    ctx: *ExpandContext,
    env: ?*const ExpandEnv,
    list_form: *const Form,
    items: []const *Form,
    depth: u32,
) ExpandError!*Form {
    if (items.len < 2) return ExpandError.MalformedMacroCall;
    const head = items[0];

    // Partition the args into body + clauses. Walk from the end
    // detecting `(catch ...)` and `(finally ...)` lists.
    var end = items.len;
    var finally_form: ?*Form = null;
    var catch_form: ?*Form = null;

    // Detect optional finally as last clause.
    if (end > 1) {
        const last = items[end - 1];
        if (isClauseHead(last, "finally")) {
            finally_form = mutCast(last);
            end -= 1;
        }
    }
    // Detect catch as next-to-last (or last if no finally).
    if (end > 1) {
        const cl = items[end - 1];
        if (isClauseHead(cl, "catch")) {
            catch_form = mutCast(cl);
            end -= 1;
        }
    }
    // At least one of catch / finally must be present.
    if (catch_form == null and finally_form == null) {
        return ExpandError.MalformedMacroCall;
    }

    // Body (items[1..end]) expanded with outer env.
    const body_count = end - 1;
    var out_items: std.ArrayList(*Form) = .empty;
    defer out_items.deinit(ctx.allocator);
    try out_items.append(ctx.allocator, mutCast(head));

    var i: usize = 1;
    while (i < end) : (i += 1) {
        const expanded = try expandFormDepth(ctx, env, items[i], depth);
        try out_items.append(ctx.allocator, expanded);
    }
    _ = body_count; // (unused; structural reference)

    // Expand catch clause. catch_items = [catch MATCHER BINDING handler...]
    // MATCHER and BINDING are literal symbols — pass through.
    if (catch_form) |cf| {
        if (cf.datum.list.len < 4) return ExpandError.MalformedMacroCall;
        const ci = cf.datum.list;
        const cf_head = ci[0];
        const matcher = ci[1];
        const binding = ci[2];
        if (binding.datum != .symbol or binding.datum.symbol.ns != null) {
            return ExpandError.MalformedMacroCall;
        }
        // Build env for handler body.
        var handler_env: ExpandEnv = .{ .parent = env };
        defer handler_env.deinit(ctx.allocator);
        _ = try handler_env.lexical_names.getOrPut(ctx.allocator, binding.datum.symbol.name);
        // Expand handler body.
        var new_catch_items: std.ArrayList(*Form) = .empty;
        defer new_catch_items.deinit(ctx.allocator);
        try new_catch_items.append(ctx.allocator, mutCast(cf_head));
        try new_catch_items.append(ctx.allocator, mutCast(matcher));
        try new_catch_items.append(ctx.allocator, mutCast(binding));
        for (ci[3..]) |h| {
            const ex = try expandFormDepth(ctx, &handler_env, h, depth);
            try new_catch_items.append(ctx.allocator, ex);
        }
        const new_catch_slice = try ctx.allocator.alloc(*Form, new_catch_items.items.len);
        for (new_catch_items.items, 0..) |item, j| new_catch_slice[j] = item;
        const new_catch = try makeList(ctx, new_catch_slice, cf.origin);
        try out_items.append(ctx.allocator, new_catch);
    }

    // Expand finally clause if present.
    if (finally_form) |ff| {
        if (ff.datum.list.len < 1) return ExpandError.MalformedMacroCall;
        const fi = ff.datum.list;
        var new_finally_items: std.ArrayList(*Form) = .empty;
        defer new_finally_items.deinit(ctx.allocator);
        try new_finally_items.append(ctx.allocator, mutCast(fi[0]));
        for (fi[1..]) |f| {
            const ex = try expandFormDepth(ctx, env, f, depth);
            try new_finally_items.append(ctx.allocator, ex);
        }
        const new_finally_slice = try ctx.allocator.alloc(*Form, new_finally_items.items.len);
        for (new_finally_items.items, 0..) |item, j| new_finally_slice[j] = item;
        const new_finally = try makeList(ctx, new_finally_slice, ff.origin);
        try out_items.append(ctx.allocator, new_finally);
    }

    const out_slice = try ctx.allocator.alloc(*Form, out_items.items.len);
    for (out_items.items, 0..) |item, j| out_slice[j] = item;
    return try makeList(ctx, out_slice, list_form.origin);
}

/// Phase 3.0b (peer-AI turn 62): expand `#(body...)` shorthand.
///
/// Examples:
///   #(+ % %2)   → (fn* [%1 %2] (+ %1 %2))
///   #(+ %1 %2)  → same
///   #(inc %)    → (fn* [%1] (inc %1))
///   #(apply f %&) → (fn* [& %&] (apply f %&))
///
/// Algorithm:
///   1. Scan body recursively for placeholder symbols:
///        `%`  → records positional 1
///        `%N` → records positional N (N >= 1)
///        `%&` → marks rest used
///   2. Param count = max positional N found (0 if none).
///   3. Generate params `[%1 %2 ... %N]` plus `[& %&]` if rest.
///   4. Rewrite `%` occurrences in body to `%1`.
///   5. Build `(fn* params body...)`.
///   6. Reject nested `#()` (Clojure compatibility).
fn expandAnonFn(
    ctx: *ExpandContext,
    env: ?*const ExpandEnv,
    call_form: *const Form,
    items: []const *Form,
    depth: u32,
) ExpandError!*Form {
    // First pass: scan to determine arity. Also rejects nested
    // #() during the walk.
    var max_positional: u32 = 0;
    var uses_rest: bool = false;
    for (items) |it| {
        try anonScanForm(it, &max_positional, &uses_rest);
    }

    // Second pass: rewrite `%` → `%1`. The other patterns
    // (`%1`, `%2`, ..., `%&`) are already valid symbols and
    // need no rewriting.
    var rewritten_body: std.ArrayList(*Form) = .empty;
    defer rewritten_body.deinit(ctx.allocator);
    try rewritten_body.ensureTotalCapacity(ctx.allocator, items.len);
    for (items) |it| {
        try rewritten_body.append(ctx.allocator, try anonRewriteForm(ctx, it));
    }

    // Build param vector.
    // Layout: [%1 %2 ... %N] OR [%1 ... %N & %&] when rest.
    const param_count: usize = max_positional + (if (uses_rest) @as(usize, 2) else 0);
    var param_items: std.ArrayList(*Form) = .empty;
    defer param_items.deinit(ctx.allocator);
    try param_items.ensureTotalCapacity(ctx.allocator, param_count);
    var i: u32 = 1;
    while (i <= max_positional) : (i += 1) {
        // Allocate the name string in the arena so it lives
        // alongside the synthesized Form.
        const name = try std.fmt.allocPrint(ctx.allocator, "%{d}", .{i});
        try param_items.append(ctx.allocator, try makeSymbol(ctx, name, call_form.origin));
    }
    if (uses_rest) {
        try param_items.append(ctx.allocator, try makeSymbol(ctx, "&", call_form.origin));
        try param_items.append(ctx.allocator, try makeSymbol(ctx, "%&", call_form.origin));
    }
    const params_slice = try ctx.allocator.alloc(*Form, param_items.items.len);
    for (param_items.items, 0..) |p, j| params_slice[j] = p;
    const params_vec = try makeVector(ctx, params_slice, call_form.origin);

    // Build the body call: `#(+ 1 2)` means the body IS the
    // single call `(+ 1 2)`. The reader emits the body items
    // ([+, 1, 2]) as the items of that synthetic call form,
    // so we wrap them in a list here.
    const body_call_items = try ctx.allocator.alloc(*Form, rewritten_body.items.len);
    for (rewritten_body.items, 0..) |b, j| body_call_items[j] = b;
    const body_call = try makeList(ctx, body_call_items, call_form.origin);

    // Build (fn* params body_call).
    const out_items = try ctx.allocator.alloc(*Form, 3);
    out_items[0] = try makeSymbol(ctx, "fn*", call_form.origin);
    out_items[1] = params_vec;
    out_items[2] = body_call;
    const fn_form = try makeList(ctx, out_items, call_form.origin);

    // Recursively re-expand so any macros nested in body fire.
    return try expandFormDepth(ctx, env, fn_form, depth);
}

/// Recursively walk a Form looking for anon-fn placeholders.
/// Errors:
///   - nested #(...) is rejected (MalformedMacroCall)
///   - `%N` where N parses as 0 is rejected
fn anonScanForm(form: *const Form, max_pos: *u32, uses_rest: *bool) ExpandError!void {
    switch (form.datum) {
        .symbol => |name| {
            if (name.ns != null) return;
            try anonClassifySymbol(name.name, max_pos, uses_rest);
        },
        .list => |items| for (items) |it| try anonScanForm(it, max_pos, uses_rest),
        .vector => |items| for (items) |it| try anonScanForm(it, max_pos, uses_rest),
        // Nested #() rejection.
        .anon_fn => return ExpandError.MalformedMacroCall,
        // Quote payload is OPAQUE — placeholders inside (quote ...)
        // are literal data, not body references.
        .quote, .syntax_quote, .unquote, .unquote_splicing => {},
        else => {},
    }
}

/// Inspect a symbol name for `%`, `%N`, or `%&` patterns and
/// update the scan state. Anything else (including `%foo`)
/// is left as an ordinary symbol — Clojure semantics.
fn anonClassifySymbol(name: []const u8, max_pos: *u32, uses_rest: *bool) ExpandError!void {
    if (name.len == 0 or name[0] != '%') return;
    if (name.len == 1) {
        // bare `%` → positional 1
        if (max_pos.* < 1) max_pos.* = 1;
        return;
    }
    if (name.len == 2 and name[1] == '&') {
        uses_rest.* = true;
        return;
    }
    // %N where N is a positive integer.
    var n: u32 = 0;
    for (name[1..]) |c| {
        if (c < '0' or c > '9') return; // ordinary symbol like %foo
        const d: u32 = c - '0';
        n = n * 10 + d;
        if (n > 1000) return ExpandError.MalformedMacroCall; // sanity bound
    }
    if (n == 0) return ExpandError.MalformedMacroCall;
    if (max_pos.* < n) max_pos.* = n;
}

/// Recursively rewrite `%` symbols to `%1`. Other forms pass
/// through unchanged. For lists/vectors, we only allocate a
/// new node when at least one element changed (best-effort
/// pointer-equality fast path).
fn anonRewriteForm(ctx: *ExpandContext, form: *const Form) ExpandError!*Form {
    return switch (form.datum) {
        .symbol => |name| blk: {
            if (name.ns == null and name.name.len == 1 and name.name[0] == '%') {
                break :blk try makeSymbol(ctx, "%1", form.origin);
            }
            break :blk mutCast(form);
        },
        .list => |items| try anonRewriteList(ctx, form, items, false),
        .vector => |items| try anonRewriteList(ctx, form, items, true),
        // Quote payload preserved literally.
        .quote, .syntax_quote, .unquote, .unquote_splicing => mutCast(form),
        else => mutCast(form),
    };
}

fn anonRewriteList(
    ctx: *ExpandContext,
    list_form: *const Form,
    items: []const *Form,
    is_vector: bool,
) ExpandError!*Form {
    var changed = false;
    var rewritten: std.ArrayList(*Form) = .empty;
    defer rewritten.deinit(ctx.allocator);
    try rewritten.ensureTotalCapacity(ctx.allocator, items.len);
    for (items) |it| {
        const new_it = try anonRewriteForm(ctx, it);
        if (new_it != it) changed = true;
        try rewritten.append(ctx.allocator, new_it);
    }
    if (!changed) return mutCast(list_form);
    const slice = try ctx.allocator.alloc(*Form, rewritten.items.len);
    for (rewritten.items, 0..) |it, i| slice[i] = it;
    if (is_vector) return try makeVector(ctx, slice, list_form.origin);
    return try makeList(ctx, slice, list_form.origin);
}

/// Phase 3.1: discriminator for `expandCollKind`.
const CollKind = enum { vector_, map_, set_ };

/// Phase 3.1: walk a vector/map/set literal's items + rebuild
/// the collection Form. Each item is expanded with the current
/// env (collection literals don't introduce bindings). Re-uses
/// the input form if no item changed (cheap fast path).
fn expandCollKind(
    ctx: *ExpandContext,
    env: ?*const ExpandEnv,
    coll_form: *const Form,
    items: []const *Form,
    depth: u32,
    kind: CollKind,
) ExpandError!*Form {
    var changed = false;
    var rewritten: std.ArrayList(*Form) = .empty;
    defer rewritten.deinit(ctx.allocator);
    try rewritten.ensureTotalCapacity(ctx.allocator, items.len);
    for (items) |it| {
        const new_it = try expandFormDepth(ctx, env, it, depth);
        if (new_it != it) changed = true;
        try rewritten.append(ctx.allocator, new_it);
    }
    if (!changed) return mutCast(coll_form);
    const slice = try ctx.allocator.alloc(*Form, rewritten.items.len);
    for (rewritten.items, 0..) |it, i| slice[i] = it;
    const new_form = try ctx.allocator.create(Form);
    new_form.* = .{
        .datum = switch (kind) {
            .vector_ => .{ .vector = @as([]const *Form, slice) },
            .map_ => .{ .map = @as([]const *Form, slice) },
            .set_ => .{ .set = @as([]const *Form, slice) },
        },
        .origin = coll_form.origin,
    };
    return new_form;
}

// =============================================================================
// Phase 3.2 — user-defined defmacro
// =============================================================================
//
// Per peer-AI turn 66:
//
//   1. `(defmacro name [params] body)` is recognized by the
//      EXPANDER (not Tiny/backend). Must execute at expansion
//      time so subsequent forms in the SAME compile unit see
//      the macro.
//   2. Defmacro lowers internally to:
//        (def name (fn* name [params] body))
//      compile-time-evaluated via `ctx.compile_eval`. The
//      callback compiles + runs the form in a fresh sub-VM
//      and returns the resulting Var Value.
//   3. The expander sets `Var.macro = true` on the returned
//      Var pointer (the namespace owns the Var; mutating the
//      flag here is correct).
//   4. The defmacro form's REPLACEMENT (what the rest of the
//      pipeline sees) is `(var name)` — that lowers to a
//      Var-object load, so REPL/eval print the Var like
//      `#'name`.
//
// User-macro INVOCATION (peer-AI turn 66 §D9):
//   1. Convert each arg Form → Value via `formToValue`.
//   2. Call `VM.evalClosure(var.root, arg_values, &sub_vm)`.
//   3. Convert returned Value → Form via `valueToForm` in
//      `ctx.allocator` (the compile arena).
//   4. Deinit the sub-VM.
//   5. Recursively re-expand the resulting Form (so macros
//      in the macro output expand).
//
// Macro args are UNEVALUATED Forms-as-Values; the macro body
// inspects them as data (lists, symbols, etc.) and builds
// output via syntax-quote. v1 ships syntax-quote-only macros;
// `cons`/`first`/`rest`/etc. native fns are a future commit
// (peer-AI turn 66 §D4).

/// Phase 3.4 (peer-AI turn 69): expand `(ns NAME)`. Switches
/// `ctx.registry.current` to the named namespace, creating it
/// (with `nexis.core` as auto-referred parent) if not already
/// registered. Returns nil; the runtime effect already happened
/// at expansion time, so subsequent forms see the new current
/// namespace.
fn expandNs(
    ctx: *ExpandContext,
    list_form: *const Form,
    items: []const *Form,
) ExpandError!*Form {
    if (items.len != 2) return ExpandError.MalformedMacroCall;
    const name_form = items[1];
    if (name_form.datum != .symbol or name_form.datum.symbol.ns != null) {
        return ExpandError.MalformedMacroCall;
    }
    const reg = ctx.registry orelse return ExpandError.MalformedMacroCall;
    reg.switchTo(name_form.datum.symbol.name) catch return ExpandError.OutOfMemory;
    // Replace `(ns NAME)` with `nil` in the form tree — the
    // side effect already happened; nothing else to do at
    // runtime.
    return try makeNil(ctx, list_form.origin);
}

/// Phase 3.6 (peer-AI turn 71): expand `(require ...)`. Supported
/// forms:
///
///   (require 'my.ns)              ; load my.ns; no alias
///   (require '[my.ns :as alias])  ; load my.ns + alias `alias` → my.ns
///
/// The side effect (file load + registry update + alias entry)
/// happens at EXPANSION TIME via `ctx.load_callback`. The
/// replacement form is `nil` (the runtime no longer has work to
/// do). Both forms accept `:as` only — `:refer` / `:rename` /
/// `:exclude` are deferred.
///
/// Multiple specs in one require call (Clojure-style
/// `(require '[a] '[b])`) supported.
fn expandRequire(
    ctx: *ExpandContext,
    list_form: *const Form,
    items: []const *Form,
) ExpandError!*Form {
    if (items.len < 2) return ExpandError.MalformedMacroCall;
    const cb = ctx.load_callback orelse return ExpandError.MalformedMacroCall;
    const reg = ctx.registry orelse return ExpandError.MalformedMacroCall;

    // Each item after the head is a require spec. The reader
    // sees `'X` as a `Datum.quote{X}` form; we unwrap one level.
    for (items[1..]) |spec_form| {
        const spec = unwrapQuote(spec_form);
        switch (spec.datum) {
            .symbol => |sym| {
                if (sym.ns != null) return ExpandError.MalformedMacroCall;
                cb.load(cb.user_data, sym.name) catch return ExpandError.MalformedMacroCall;
            },
            .vector => |elems| {
                if (elems.len < 1) return ExpandError.MalformedMacroCall;
                const ns_form = elems[0];
                if (ns_form.datum != .symbol or ns_form.datum.symbol.ns != null) {
                    return ExpandError.MalformedMacroCall;
                }
                const ns_name = ns_form.datum.symbol.name;
                // Optional `:as alias` clause.
                var alias_name: ?[]const u8 = null;
                var i: usize = 1;
                while (i < elems.len) : (i += 2) {
                    const k = elems[i];
                    if (k.datum != .keyword or k.datum.keyword.ns != null) {
                        return ExpandError.MalformedMacroCall;
                    }
                    if (std.mem.eql(u8, k.datum.keyword.name, "as")) {
                        if (i + 1 >= elems.len) return ExpandError.MalformedMacroCall;
                        const alias_form = elems[i + 1];
                        if (alias_form.datum != .symbol or alias_form.datum.symbol.ns != null) {
                            return ExpandError.MalformedMacroCall;
                        }
                        alias_name = alias_form.datum.symbol.name;
                    } else {
                        // :refer / :rename / :exclude deferred.
                        return ExpandError.MalformedMacroCall;
                    }
                }
                cb.load(cb.user_data, ns_name) catch return ExpandError.MalformedMacroCall;
                if (alias_name) |an| {
                    reg.current.putAlias(an, ns_name) catch return ExpandError.OutOfMemory;
                }
            },
            else => return ExpandError.MalformedMacroCall,
        }
    }
    return try makeNil(ctx, list_form.origin);
}

/// Unwrap one level of `(quote X)` from a Form. Returns X if
/// the form is a quote; else returns the form unchanged.
fn unwrapQuote(form: *const Form) *const Form {
    return switch (form.datum) {
        .quote => |inner| inner,
        else => form,
    };
}

/// Phase 3.2: expand `(defmacro name [params] body)`.
fn expandDefmacro(
    ctx: *ExpandContext,
    env: ?*const ExpandEnv,
    list_form: *const Form,
    items: []const *Form,
    depth: u32,
) ExpandError!*Form {
    // (defmacro NAME [PARAMS] BODY...)
    if (items.len < 4) return ExpandError.MalformedMacroCall;
    const name_form = items[1];
    const params_form = items[2];
    if (name_form.datum != .symbol or name_form.datum.symbol.ns != null) {
        return ExpandError.MalformedMacroCall;
    }
    if (params_form.datum != .vector) return ExpandError.MalformedMacroCall;
    const body_forms = items[3..];

    // Need both a namespace (to mark the Var) and a compile-
    // eval callback (to compile+run the synthetic def form).
    const ns = ctx.namespace orelse return ExpandError.MalformedMacroCall;
    const ceval = ctx.compile_eval orelse return ExpandError.MalformedMacroCall;

    // First: macroexpand the body BEFORE compiling it. Body
    // env includes the self-name + params (matches expandDefn
    // semantics).
    var local: ExpandEnv = .{ .parent = env };
    defer local.deinit(ctx.allocator);
    _ = try local.lexical_names.getOrPut(ctx.allocator, name_form.datum.symbol.name);
    for (params_form.datum.vector) |p| {
        if (p.datum != .symbol or p.datum.symbol.ns != null) continue;
        if (std.mem.eql(u8, p.datum.symbol.name, "&")) continue;
        _ = try local.lexical_names.getOrPut(ctx.allocator, p.datum.symbol.name);
    }
    const expanded_body = try ctx.allocator.alloc(*Form, body_forms.len);
    for (body_forms, 0..) |b, i| {
        expanded_body[i] = try expandFormDepth(ctx, &local, b, depth);
    }

    // Build the synthetic form: (def NAME (fn* NAME [PARAMS] body...))
    const fn_items = try ctx.allocator.alloc(*Form, 3 + expanded_body.len);
    fn_items[0] = try makeSymbol(ctx, "fn*", list_form.origin);
    fn_items[1] = mutCast(name_form);
    fn_items[2] = mutCast(params_form);
    for (expanded_body, 0..) |b, i| fn_items[3 + i] = b;
    const fn_form = try makeList(ctx, fn_items, list_form.origin);

    const def_items = try ctx.allocator.alloc(*Form, 3);
    def_items[0] = try makeSymbol(ctx, "def", list_form.origin);
    def_items[1] = mutCast(name_form);
    def_items[2] = fn_form;
    const def_form = try makeList(ctx, def_items, list_form.origin);

    // Compile-time-eval the def form. Returns the Var Value.
    //
    // CRITICAL (Phase 3.4 bugfix): we INTENTIONALLY LEAK the
    // sub-VM here. The macro fn's Closure is allocated in the
    // sub-VM's `runtime_arena`, which is backed by the
    // caller's persistent allocator. `ArenaAllocator.free`
    // RECLAIMS the most-recent allocation (peer-AI turn 69
    // discovery during 3.4 integration), so `sub_vm.deinit()`
    // would invalidate the Closure pointer stored in `Var.root`
    // \u2014 and the next defmacro's allocations would land on the
    // exact bytes. Leaking the sub-VM here is safe: every
    // allocation it made was from the persistent allocator
    // (typically `vm.runtime_arena`), which is freed wholesale
    // at VM teardown. The sub-VM struct itself is on the Zig
    // stack and dies normally.
    var sub_vm: vm_mod.VM = undefined;
    const result_value = ceval.eval(ceval.user_data, def_form, &sub_vm) catch {
        return ExpandError.MalformedMacroCall;
    };

    // Sanity: result should be a Var value. Mark it as macro.
    if (result_value.kind() != .var_) return ExpandError.MalformedMacroCall;
    const target_var = vm_mod.VM.asVar(result_value);
    target_var.macro = true;

    // Replacement form: (var name) — evaluates to the same Var
    // at runtime so the REPL prints `#'name`.
    const var_items = try ctx.allocator.alloc(*Form, 2);
    var_items[0] = try makeSymbol(ctx, "var", list_form.origin);
    var_items[1] = mutCast(name_form);

    // Also intern the Var in the caller's namespace explicitly,
    // to be safe (the compile-eval should have done this, but
    // the macro flag is on a pointer — make sure the namespace
    // sees the SAME pointer). The compile-eval already created
    // the Var via def; our `lookup` and `intern` ought to return
    // it. Double-check:
    if (ns.lookup(name_form.datum.symbol.name)) |looked| {
        if (looked != target_var) {
            // Should not happen — compile-eval used the same
            // namespace. If pointer identity mismatches, the
            // macro flag is on the wrong Var.
            return ExpandError.MalformedMacroCall;
        }
    }

    return try makeList(ctx, var_items, list_form.origin);
}

/// Phase 3.2: invoke a user-defined macro.
fn invokeUserMacro(
    ctx: *ExpandContext,
    env: ?*const ExpandEnv,
    macro_var: *vm_mod.Var,
    call_form: *const Form,
    items: []const *Form,
    depth: u32,
) ExpandError!*Form {
    const args = items[1..];

    // Convert each arg Form → Value (unevaluated, as data).
    const arg_values = ctx.allocator.alloc(value_mod.Value, args.len) catch return ExpandError.OutOfMemory;
    defer ctx.allocator.free(arg_values);
    for (args, 0..) |a, i| {
        arg_values[i] = formToValue(ctx, a) catch return ExpandError.MalformedMacroCall;
    }

    // Invoke in a fresh sub-VM. The sub-VM's heap holds the
    // macro fn's runtime state; we must convert the result back
    // to a Form (in ctx.allocator) BEFORE deinit.
    var sub_vm: vm_mod.VM = undefined;
    var sub_vm_ready = false;
    defer if (sub_vm_ready) sub_vm.deinit();
    const result_value = vm_mod.VM.evalClosure(
        ctx.allocator,
        macro_var.root,
        arg_values,
        &sub_vm,
    ) catch {
        return ExpandError.MalformedMacroCall;
    };
    sub_vm_ready = true;

    // Convert result Value → Form.
    const result_form = valueToForm(ctx, result_value, call_form.origin) catch return ExpandError.MalformedMacroCall;

    // Recursively re-expand the result (macros in the macro
    // output get expanded).
    return try expandFormDepth(ctx, env, result_form, depth + 1);
}

/// Convert a `Form` to its runtime Value representation. Used
/// to pass macro args as unevaluated data. Supports the data
/// shapes a macro typically inspects.
///
/// Mapping (peer-AI turn 66 §D3):
///   nil/bool/int   → corresponding immediate
///   keyword/symbol → interned Value
///   list           → cons list of recursively-converted items
///   vector         → persistent vector
///   map            → persistent map (flat k,v,k,v items)
///   set            → persistent set
///   quote          → `(quote payload-value)` as a 2-element list
/// Other Form datums (real, char, string, syntax_quote, unquote,
/// unquote_splicing, anon_fn, with_meta, deref) are deferred for
/// v1 — `MalformedMacroCall` if encountered.
fn formToValue(ctx: *ExpandContext, form: *const Form) !value_mod.Value {
    return switch (form.datum) {
        .nil => value_mod.nilValue(),
        .bool_ => |b| value_mod.fromBool(b),
        .int => |n| value_mod.fromFixnum(n) orelse return ExpandError.MalformedMacroCall,
        .symbol => |name| blk: {
            if (name.ns != null) return ExpandError.MalformedMacroCall;
            const id = ctx.interner.internSymbol(name.name) catch return ExpandError.OutOfMemory;
            break :blk value_mod.fromSymbolId(id);
        },
        .keyword => |name| blk: {
            if (name.ns != null) return ExpandError.MalformedMacroCall;
            const id = ctx.interner.internKeyword(name.name) catch return ExpandError.OutOfMemory;
            break :blk value_mod.fromKeywordId(id);
        },
        .list => |items| try formItemsToList(ctx, items),
        .vector => |items| blk: {
            // Construct vector via fromSlice. We need a heap; the
            // ctx doesn't own one, so we make a tiny temporary
            // heap backed by ctx.allocator (arena). The vector's
            // backing storage lives in ctx.allocator, so the
            // resulting Value is valid for the macro call duration.
            const elems = try ctx.allocator.alloc(value_mod.Value, items.len);
            for (items, 0..) |it, i| elems[i] = try formToValue(ctx, it);
            const heap = try ctx.heapForArgs();
            break :blk vector_mod.fromSlice(heap, elems) catch return ExpandError.OutOfMemory;
        },
        .map => |items| blk: {
            if (items.len % 2 != 0) return ExpandError.MalformedMacroCall;
            const heap = try ctx.heapForArgs();
            var m = champ_mod.mapEmpty(heap) catch return ExpandError.OutOfMemory;
            const dispatch = @import("dispatch");
            var i: usize = 0;
            while (i < items.len) : (i += 2) {
                const k = try formToValue(ctx, items[i]);
                const v = try formToValue(ctx, items[i + 1]);
                m = champ_mod.mapAssoc(heap, m, k, v, &dispatch.hashValue, &dispatch.equal) catch return ExpandError.OutOfMemory;
            }
            break :blk m;
        },
        .set => |items| blk: {
            const heap = try ctx.heapForArgs();
            var s = champ_mod.setEmpty(heap) catch return ExpandError.OutOfMemory;
            const dispatch = @import("dispatch");
            for (items) |it| {
                const v = try formToValue(ctx, it);
                s = champ_mod.setConj(heap, s, v, &dispatch.hashValue, &dispatch.equal) catch return ExpandError.OutOfMemory;
            }
            break :blk s;
        },
        .quote => |payload| blk: {
            // Normalize `'x` → (quote <payload-value>) as a 2-list.
            const quote_id = ctx.interner.internSymbol("quote") catch return ExpandError.OutOfMemory;
            const quote_sym = value_mod.fromSymbolId(quote_id);
            const payload_val = try formToValue(ctx, payload);
            const heap = try ctx.heapForArgs();
            var lst = list_mod.empty(heap) catch return ExpandError.OutOfMemory;
            lst = list_mod.cons(heap, payload_val, lst) catch return ExpandError.OutOfMemory;
            lst = list_mod.cons(heap, quote_sym, lst) catch return ExpandError.OutOfMemory;
            break :blk lst;
        },
        // syntax_quote, unquote, unquote_splicing, anon_fn,
        // with_meta, deref, real, char, string → defer.
        else => return ExpandError.MalformedMacroCall,
    };
}

fn formItemsToList(ctx: *ExpandContext, items: []const *Form) ExpandError!value_mod.Value {
    const heap = try ctx.heapForArgs();
    var lst = list_mod.empty(heap) catch return ExpandError.OutOfMemory;
    var i: usize = items.len;
    while (i > 0) {
        i -= 1;
        const item_v = try formToValue(ctx, items[i]);
        lst = list_mod.cons(heap, item_v, lst) catch return ExpandError.OutOfMemory;
    }
    return lst;
}

/// Convert a runtime Value back into a Form (for the macro
/// return path). Lifetime: Forms allocated in `ctx.allocator`
/// (the compile arena), so the result outlives the macro
/// sub-VM. Each constructed Form gets `origin` as its source
/// span — typically the macro call site (peer-AI turn 66 §D3
/// "Span/origin": generated forms use the macro call origin).
fn valueToForm(ctx: *ExpandContext, v: value_mod.Value, origin: reader_mod.SrcSpan) !*Form {
    return switch (v.kind()) {
        .nil => try makeNil(ctx, origin),
        .true_ => try makeBool(ctx, true, origin),
        .false_ => try makeBool(ctx, false, origin),
        .fixnum => blk: {
            const form = try ctx.allocator.create(Form);
            form.* = .{ .datum = .{ .int = v.asFixnum() }, .origin = origin };
            break :blk form;
        },
        .symbol => blk: {
            const id: u32 = @intCast(v.payload);
            const name = ctx.interner.symbolName(id);
            // Owned-by-interner name is stable for the
            // compilation unit; safe to borrow into the Form.
            break :blk try makeSymbol(ctx, name, origin);
        },
        .keyword => blk: {
            const id: u32 = @intCast(v.payload);
            const name = ctx.interner.keywordName(id);
            const form = try ctx.allocator.create(Form);
            form.* = .{
                .datum = .{ .keyword = .{ .ns = null, .name = name } },
                .origin = origin,
            };
            break :blk form;
        },
        .list => blk: {
            var items: std.ArrayList(*Form) = .empty;
            defer items.deinit(ctx.allocator);
            var node = v;
            while (node.kind() == .list and !list_mod.isEmpty(node)) {
                const head_f = try valueToForm(ctx, list_mod.head(node), origin);
                try items.append(ctx.allocator, head_f);
                node = list_mod.tail(node);
            }
            const slice = try ctx.allocator.alloc(*Form, items.items.len);
            for (items.items, 0..) |it, i| slice[i] = it;
            break :blk try makeList(ctx, slice, origin);
        },
        .persistent_vector => blk: {
            const n = vector_mod.count(v);
            const slice = try ctx.allocator.alloc(*Form, n);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                slice[i] = try valueToForm(ctx, vector_mod.nth(v, i), origin);
            }
            break :blk try makeVector(ctx, slice, origin);
        },
        .persistent_map => blk: {
            var entries: std.ArrayList(*Form) = .empty;
            defer entries.deinit(ctx.allocator);
            var it = champ_mod.mapIter(v);
            while (it.next()) |e| {
                try entries.append(ctx.allocator, try valueToForm(ctx, e.key, origin));
                try entries.append(ctx.allocator, try valueToForm(ctx, e.value, origin));
            }
            const slice = try ctx.allocator.alloc(*Form, entries.items.len);
            for (entries.items, 0..) |item, i| slice[i] = item;
            const form = try ctx.allocator.create(Form);
            form.* = .{ .datum = .{ .map = @as([]const *Form, slice) }, .origin = origin };
            break :blk form;
        },
        .persistent_set => blk: {
            var elems: std.ArrayList(*Form) = .empty;
            defer elems.deinit(ctx.allocator);
            var it = champ_mod.setIter(v);
            while (it.next()) |e| {
                try elems.append(ctx.allocator, try valueToForm(ctx, e, origin));
            }
            const slice = try ctx.allocator.alloc(*Form, elems.items.len);
            for (elems.items, 0..) |item, i| slice[i] = item;
            const form = try ctx.allocator.create(Form);
            form.* = .{ .datum = .{ .set = @as([]const *Form, slice) }, .origin = origin };
            break :blk form;
        },
        // Macro returned a kind we don't know how to surface
        // as a Form (function, var, etc.). Most macros return
        // shapes built via syntax-quote, so this is rare.
        else => return ExpandError.MalformedMacroCall,
    };
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
// Form construction helpers (MACROEXPAND.md §10b — the
// FormBuilder pattern, with origin carried through per §4b)
// =============================================================================
//
// Every helper takes an `origin: SrcSpan` parameter. Per §4b
// (peer-AI turn 56), synthetic forms get the macro CALL site's
// origin so that future error messages can say "in macro
// expansion of WHEN at line 5". Macros typically pass
// `call_form.origin` to every helper.
//
// Lifetime: every constructed Form lives in `ctx.allocator`
// (the macroexpand arena, same as the compile arena). The
// caller does NOT free.

pub fn makeList(ctx: *ExpandContext, items: []*Form, origin: SrcSpan) ExpandError!*Form {
    const form = try ctx.allocator.create(Form);
    form.* = .{
        .datum = .{ .list = @as([]const *Form, items) },
        .origin = origin,
    };
    return form;
}

pub fn makeVector(ctx: *ExpandContext, items: []*Form, origin: SrcSpan) ExpandError!*Form {
    const form = try ctx.allocator.create(Form);
    form.* = .{
        .datum = .{ .vector = @as([]const *Form, items) },
        .origin = origin,
    };
    return form;
}

/// Construct a symbol form. `name` is borrowed (typically a
/// string literal from the macro fn or a gensym output —
/// either way the lifetime is at least as long as the
/// resulting Form's). Always unqualified for host macros;
/// qualified-symbol construction lands in #8c.
pub fn makeSymbol(ctx: *ExpandContext, name: []const u8, origin: SrcSpan) ExpandError!*Form {
    const form = try ctx.allocator.create(Form);
    form.* = .{
        .datum = .{ .symbol = .{ .ns = null, .name = name } },
        .origin = origin,
    };
    return form;
}

pub fn makeNil(ctx: *ExpandContext, origin: SrcSpan) ExpandError!*Form {
    const form = try ctx.allocator.create(Form);
    form.* = .{ .datum = .nil, .origin = origin };
    return form;
}

pub fn makeBool(ctx: *ExpandContext, value: bool, origin: SrcSpan) ExpandError!*Form {
    const form = try ctx.allocator.create(Form);
    form.* = .{ .datum = .{ .bool_ = value }, .origin = origin };
    return form;
}

// =============================================================================
// Host core macros (MACROEXPAND.md §10 — step #8b)
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
//     `invokeMacro`), so macro-of-macros termination is
//     automatic.

// ---- Rename macros (CLOJURE-REVIEW.md §1.1 primitive `*`) ----
//
// These exist because user-facing `let`/`fn`/`loop` are
// macros that just rename to the compiler primitives
// `let*`/`fn*`/`loop*`. Phase 3 will redefine `let` to add
// destructuring; for v1 step #8b, the trivial rename is
// the entire job.

/// Phase 3.5a (peer-AI turn 70): expand `(let bindings body...)`
/// with destructuring support. The bindings vector may contain
/// non-symbol PATTERNS (sequential `[a b c]`, associative
/// `{:keys [...] :or {...} :as name}`); these expand to extra
/// `(let* ...)` bindings that destructure via `nth`/`get`/`rest`.
///
/// Plain symbol bindings pass through unchanged. Non-symbol
/// patterns are recognized via `destructurePair` and recursively
/// destructure any nested patterns.
fn expandLetRename(
    ctx: *ExpandContext,
    call_form: *const Form,
    args: []const *Form,
) ExpandError!*Form {
    if (args.len < 1) return ExpandError.MalformedMacroCall;
    const bindings_form = args[0];
    if (bindings_form.datum != .vector) return ExpandError.MalformedMacroCall;
    const src_pairs = bindings_form.datum.vector;
    if (src_pairs.len % 2 != 0) return ExpandError.MalformedMacroCall;

    // Expand into a flat list of [pattern expr] pairs.
    var expanded: std.ArrayList(*Form) = .empty;
    defer expanded.deinit(ctx.allocator);
    var i: usize = 0;
    while (i < src_pairs.len) : (i += 2) {
        try destructurePair(ctx, src_pairs[i], src_pairs[i + 1], &expanded, call_form.origin);
    }

    const new_bindings_items = try ctx.allocator.alloc(*Form, expanded.items.len);
    for (expanded.items, 0..) |it, j| new_bindings_items[j] = it;
    const new_bindings = try makeVector(ctx, new_bindings_items, bindings_form.origin);

    const new_args = try ctx.allocator.alloc(*Form, args.len);
    new_args[0] = new_bindings;
    for (args[1..], 1..) |a, j| new_args[j] = @constCast(a);
    return renameHead(ctx, call_form, new_args, "let*");
}

/// Phase 3.5a: expand `(fn ...)` with destructuring in params.
/// Supports `(fn [params] body)`, `(fn name [params] body)`.
/// Destructured params are replaced with gensyms; the body is
/// wrapped in a `(let [pattern gensym ...] body)` that itself
/// expands via destructuring.
///
/// Multi-arity `(fn ([p1] b1) ([p1 p2] b2))` ships with `defn`
/// in 3.5b.
fn expandFnRename(
    ctx: *ExpandContext,
    call_form: *const Form,
    args: []const *Form,
) ExpandError!*Form {
    if (args.len < 1) return ExpandError.MalformedMacroCall;
    // Detect (fn name [params] body) vs (fn [params] body).
    var name_form: ?*Form = null;
    var params_idx: usize = 0;
    if (args[0].datum == .symbol) {
        name_form = @constCast(args[0]);
        params_idx = 1;
    }
    if (params_idx >= args.len) return ExpandError.MalformedMacroCall;
    const params_form = args[params_idx];
    if (params_form.datum != .vector) {
        // Multi-arity form: (fn ([p1] b1) ([p1 p2] b2)). Defer
        // to 3.5b — for now, pass through unchanged (will likely
        // raise MalformedForm at lowering).
        return renameHead(ctx, call_form, args, "fn*");
    }
    const params = params_form.datum.vector;
    const body = args[params_idx + 1 ..];

    // Walk params; for each non-symbol or non-& destructure, gen
    // a fresh param symbol + collect a destructure binding.
    var new_params: std.ArrayList(*Form) = .empty;
    defer new_params.deinit(ctx.allocator);
    var destruct_bindings: std.ArrayList(*Form) = .empty;
    defer destruct_bindings.deinit(ctx.allocator);
    var saw_rest = false;
    for (params) |p| {
        if (saw_rest) {
            // After `&` — the rest param. If pattern, destructure.
            if (p.datum == .symbol) {
                try new_params.append(ctx.allocator, @constCast(p));
            } else {
                const tmp = try genTempSym(ctx, call_form.origin);
                try new_params.append(ctx.allocator, tmp);
                try destruct_bindings.append(ctx.allocator, @constCast(p));
                try destruct_bindings.append(ctx.allocator, tmp);
            }
            continue;
        }
        if (p.datum == .symbol and std.mem.eql(u8, p.datum.symbol.name, "&")) {
            try new_params.append(ctx.allocator, @constCast(p));
            saw_rest = true;
            continue;
        }
        if (p.datum == .symbol) {
            try new_params.append(ctx.allocator, @constCast(p));
        } else {
            // Vector/map pattern → gensym param + destructure binding.
            const tmp = try genTempSym(ctx, call_form.origin);
            try new_params.append(ctx.allocator, tmp);
            try destruct_bindings.append(ctx.allocator, @constCast(p));
            try destruct_bindings.append(ctx.allocator, tmp);
        }
    }

    const new_params_slice = try ctx.allocator.alloc(*Form, new_params.items.len);
    for (new_params.items, 0..) |p, j| new_params_slice[j] = p;
    const new_params_vec = try makeVector(ctx, new_params_slice, params_form.origin);

    // Build the body. If we have destructure bindings, wrap in a
    // (let [bindings...] body...). Else pass body through.
    var final_body: std.ArrayList(*Form) = .empty;
    defer final_body.deinit(ctx.allocator);
    if (destruct_bindings.items.len > 0) {
        const dbinds_slice = try ctx.allocator.alloc(*Form, destruct_bindings.items.len);
        for (destruct_bindings.items, 0..) |b, j| dbinds_slice[j] = b;
        const dbinds_vec = try makeVector(ctx, dbinds_slice, params_form.origin);
        const let_items = try ctx.allocator.alloc(*Form, 2 + body.len);
        let_items[0] = try makeSymbol(ctx, "let", call_form.origin);
        let_items[1] = dbinds_vec;
        for (body, 0..) |b, j| let_items[2 + j] = @constCast(b);
        const let_form = try makeList(ctx, let_items, call_form.origin);
        try final_body.append(ctx.allocator, let_form);
    } else {
        for (body) |b| try final_body.append(ctx.allocator, @constCast(b));
    }

    // Reconstruct: [name?] new_params_vec body...
    const fn_args_len: usize = (if (name_form != null) @as(usize, 1) else 0) + 1 + final_body.items.len;
    const fn_args = try ctx.allocator.alloc(*Form, fn_args_len);
    var idx: usize = 0;
    if (name_form) |n| {
        fn_args[idx] = n;
        idx += 1;
    }
    fn_args[idx] = new_params_vec;
    idx += 1;
    for (final_body.items) |b| {
        fn_args[idx] = b;
        idx += 1;
    }
    return renameHead(ctx, call_form, fn_args, "fn*");
}

/// Phase 3.5a: `(defn name [params] body...)` → `(def name
/// (fn name [params] body...))`. Routing defn through `fn`
/// gives us destructured params for free.
///
/// Phase 3.5b: multi-arity form `(defn name ([p1] b1) ([p1 p2] b2))`
/// expands to a variadic dispatcher:
///   (def name
///     (fn name [& args__auto__]
///       (let* [n__auto__ (count args__auto__)]
///         (if (= n__auto__ 1) (let* [p1 (nth args__auto__ 0)] b1)
///         (if (= n__auto__ 2) (let* [p1 (nth args__auto__ 0)
///                                    p2 (nth args__auto__ 1)] b2)
///         (throw :arity-mismatch))))))
///
/// At-most-one variadic overload allowed; its fixed-count must
/// exceed every fixed-arity overload's count (Clojure rule).
fn expandDefnMacro(
    ctx: *ExpandContext,
    call_form: *const Form,
    args: []const *Form,
) ExpandError!*Form {
    if (args.len < 2) return ExpandError.MalformedMacroCall;
    const name_form = args[0];
    if (name_form.datum != .symbol or name_form.datum.symbol.ns != null) {
        return ExpandError.MalformedMacroCall;
    }
    // Detect single-arity vs multi-arity:
    //   single: args[1] is vector (params)
    //   multi:  args[1..] are lists each shaped (params body...)
    const single_arity = args[1].datum == .vector;
    if (single_arity) {
        return try buildDefSingleFn(ctx, call_form, name_form, args[1..]);
    }
    return try buildDefMultiFn(ctx, call_form, name_form, args[1..]);
}

fn buildDefSingleFn(
    ctx: *ExpandContext,
    call_form: *const Form,
    name_form: *const Form,
    fn_args: []const *Form,
) ExpandError!*Form {
    // Build (fn name params body...).
    const fn_items = try ctx.allocator.alloc(*Form, 2 + fn_args.len);
    fn_items[0] = try makeSymbol(ctx, "fn", call_form.origin);
    fn_items[1] = @constCast(name_form);
    for (fn_args, 0..) |a, i| fn_items[2 + i] = @constCast(a);
    const fn_form = try makeList(ctx, fn_items, call_form.origin);
    return try buildDefForm(ctx, call_form, name_form, fn_form);
}

fn buildDefForm(
    ctx: *ExpandContext,
    call_form: *const Form,
    name_form: *const Form,
    fn_form: *Form,
) ExpandError!*Form {
    const def_items = try ctx.allocator.alloc(*Form, 3);
    def_items[0] = try makeSymbol(ctx, "def", call_form.origin);
    def_items[1] = @constCast(name_form);
    def_items[2] = fn_form;
    return try makeList(ctx, def_items, call_form.origin);
}

/// Phase 3.5b: build the multi-arity dispatcher.
fn buildDefMultiFn(
    ctx: *ExpandContext,
    call_form: *const Form,
    name_form: *const Form,
    arity_forms: []const *Form,
) ExpandError!*Form {
    // Each arity_form should be `(params body...)`.
    // Collect (fixed_count, is_variadic, params_form, body_forms) per overload.
    const ArityInfo = struct {
        fixed: usize,
        variadic: bool,
        params: *const Form,
        body: []const *Form,
    };
    var arities: std.ArrayList(ArityInfo) = .empty;
    defer arities.deinit(ctx.allocator);
    var variadic_seen: ?usize = null; // index into arities
    var max_fixed: usize = 0;

    for (arity_forms) |af| {
        if (af.datum != .list) return ExpandError.MalformedMacroCall;
        const items = af.datum.list;
        if (items.len < 1) return ExpandError.MalformedMacroCall;
        const params_form = items[0];
        if (params_form.datum != .vector) return ExpandError.MalformedMacroCall;
        const params = params_form.datum.vector;
        // Detect & rest position.
        var fixed_count: usize = 0;
        var is_variadic = false;
        for (params) |p| {
            if (p.datum == .symbol and p.datum.symbol.ns == null and std.mem.eql(u8, p.datum.symbol.name, "&")) {
                is_variadic = true;
                break;
            }
            fixed_count += 1;
        }
        if (is_variadic) {
            if (variadic_seen != null) return ExpandError.MalformedMacroCall;
            variadic_seen = arities.items.len;
        } else {
            // Reject duplicate fixed arities.
            for (arities.items) |a| {
                if (!a.variadic and a.fixed == fixed_count) return ExpandError.MalformedMacroCall;
            }
            if (fixed_count > max_fixed) max_fixed = fixed_count;
        }
        try arities.append(ctx.allocator, .{
            .fixed = fixed_count,
            .variadic = is_variadic,
            .params = params_form,
            .body = items[1..],
        });
    }
    // Variadic overload must take MORE args than any fixed overload.
    if (variadic_seen) |i| {
        if (arities.items[i].fixed < max_fixed) return ExpandError.MalformedMacroCall;
    }

    // Build the dispatcher body. Synthesize symbols.
    const args_sym = try genTempSym(ctx, call_form.origin);
    const n_sym = try genTempSym(ctx, call_form.origin);

    // Innermost else: (throw :arity-mismatch).
    var current_else: *Form = try buildThrowArity(ctx, call_form.origin);

    // Walk overloads in REVERSE so the first one becomes outermost.
    // Variadic goes innermost-after-fixed for correctness (its
    // condition is "argc >= variadic.fixed").
    // Strategy: emit fixed clauses first (in reverse), then wrap
    // variadic clause as the outermost so it catches argc >=
    // variadic.fixed when no fixed clause matched. Actually
    // simplest: emit ALL clauses outermost-to-innermost in
    // user-declared order. Build by walking REVERSE order, each
    // step wrapping current_else in `(if cond then current_else)`.
    var i: usize = arities.items.len;
    while (i > 0) {
        i -= 1;
        const a = arities.items[i];
        const params = a.params.datum.vector;
        // Build the let* with param bindings.
        const then_form = try buildArityThen(ctx, call_form.origin, args_sym, params, a.fixed, a.variadic, a.body);
        // Build the condition: fixed → (= n K); variadic → (< (- K 1) n) for "at least K-1 args".
        const cond_form = if (a.variadic)
            try buildVariadicCondition(ctx, call_form.origin, n_sym, a.fixed)
        else
            try buildFixedCondition(ctx, call_form.origin, n_sym, a.fixed);
        // Wrap: (if cond then current_else).
        const if_items = try ctx.allocator.alloc(*Form, 4);
        if_items[0] = try makeSymbol(ctx, "if", call_form.origin);
        if_items[1] = cond_form;
        if_items[2] = then_form;
        if_items[3] = current_else;
        current_else = try makeList(ctx, if_items, call_form.origin);
    }

    // Build (let* [n_sym (count args_sym)] current_else).
    const let_bindings = try ctx.allocator.alloc(*Form, 4);
    let_bindings[0] = n_sym;
    const count_items = try ctx.allocator.alloc(*Form, 2);
    count_items[0] = try makeSymbol(ctx, "count", call_form.origin);
    count_items[1] = args_sym;
    let_bindings[1] = try makeList(ctx, count_items, call_form.origin);
    const let_binds_vec = try makeVector(ctx, let_bindings[0..2], call_form.origin);
    const let_items = try ctx.allocator.alloc(*Form, 3);
    let_items[0] = try makeSymbol(ctx, "let*", call_form.origin);
    let_items[1] = let_binds_vec;
    let_items[2] = current_else;
    const let_form = try makeList(ctx, let_items, call_form.origin);

    // Build outer (fn name [& args_sym] let_form).
    const fn_params_items = try ctx.allocator.alloc(*Form, 2);
    fn_params_items[0] = try makeSymbol(ctx, "&", call_form.origin);
    fn_params_items[1] = args_sym;
    const fn_params_vec = try makeVector(ctx, fn_params_items, call_form.origin);
    const fn_items = try ctx.allocator.alloc(*Form, 4);
    fn_items[0] = try makeSymbol(ctx, "fn", call_form.origin);
    fn_items[1] = @constCast(name_form);
    fn_items[2] = fn_params_vec;
    fn_items[3] = let_form;
    const fn_form = try makeList(ctx, fn_items, call_form.origin);

    return try buildDefForm(ctx, call_form, name_form, fn_form);
}

fn buildThrowArity(ctx: *ExpandContext, origin: reader_mod.SrcSpan) ExpandError!*Form {
    const items = try ctx.allocator.alloc(*Form, 2);
    items[0] = try makeSymbol(ctx, "throw", origin);
    items[1] = try makeKeyword(ctx, "arity-mismatch", origin);
    return try makeList(ctx, items, origin);
}

fn buildFixedCondition(ctx: *ExpandContext, origin: reader_mod.SrcSpan, n_sym: *Form, k: usize) ExpandError!*Form {
    const items = try ctx.allocator.alloc(*Form, 3);
    items[0] = try makeSymbol(ctx, "=", origin);
    items[1] = n_sym;
    const k_form = try ctx.allocator.create(Form);
    k_form.* = .{ .datum = .{ .int = @intCast(k) }, .origin = origin };
    items[2] = k_form;
    return try makeList(ctx, items, origin);
}

/// Variadic with `fixed_count` args before `&`: matches when
/// argc >= fixed_count. Built as `(not (< n fixed_count))` which
/// avoids needing `<=`.
fn buildVariadicCondition(ctx: *ExpandContext, origin: reader_mod.SrcSpan, n_sym: *Form, fixed_count: usize) ExpandError!*Form {
    const lt_items = try ctx.allocator.alloc(*Form, 3);
    lt_items[0] = try makeSymbol(ctx, "<", origin);
    lt_items[1] = n_sym;
    const k_form = try ctx.allocator.create(Form);
    k_form.* = .{ .datum = .{ .int = @intCast(fixed_count) }, .origin = origin };
    lt_items[2] = k_form;
    const lt_call = try makeList(ctx, lt_items, origin);
    const not_items = try ctx.allocator.alloc(*Form, 2);
    not_items[0] = try makeSymbol(ctx, "not", origin);
    not_items[1] = lt_call;
    return try makeList(ctx, not_items, origin);
}

/// Build the body of an arity branch: `(let* [params... from args_sym] body...)`.
/// For fixed arity, each param i gets `(nth args_sym i)`. For
/// variadic, the rest param gets a list built from
/// `args_sym`'s suffix (here, we already passed args as a list,
/// so the rest is `(drop fixed_count args_sym)` — but we don't
/// have `drop` as a native fn. Use repeated `rest` instead.
fn buildArityThen(
    ctx: *ExpandContext,
    origin: reader_mod.SrcSpan,
    args_sym: *Form,
    params: []const *Form,
    fixed: usize,
    variadic: bool,
    body: []const *Form,
) ExpandError!*Form {
    var bindings: std.ArrayList(*Form) = .empty;
    defer bindings.deinit(ctx.allocator);
    var i: usize = 0;
    while (i < fixed) : (i += 1) {
        try bindings.append(ctx.allocator, @constCast(params[i]));
        try bindings.append(ctx.allocator, try buildNthCall(ctx, args_sym, i, origin));
    }
    if (variadic) {
        // params[fixed] is `&`; params[fixed+1] is the rest binding.
        if (fixed + 1 >= params.len) return ExpandError.MalformedMacroCall;
        const rest_pat = params[fixed + 1];
        const rest_expr = try buildNestedRest(ctx, args_sym, fixed, origin);
        try bindings.append(ctx.allocator, @constCast(rest_pat));
        try bindings.append(ctx.allocator, rest_expr);
    }
    const bindings_slice = try ctx.allocator.alloc(*Form, bindings.items.len);
    for (bindings.items, 0..) |b, j| bindings_slice[j] = b;
    const binds_vec = try makeVector(ctx, bindings_slice, origin);
    // Use `let` (not `let*`) so param patterns themselves can be
    // destructured (e.g., (defn f ([[x y]] (+ x y)))).
    const let_items = try ctx.allocator.alloc(*Form, 2 + body.len);
    let_items[0] = try makeSymbol(ctx, "let", origin);
    let_items[1] = binds_vec;
    for (body, 0..) |b, j| let_items[2 + j] = @constCast(b);
    return try makeList(ctx, let_items, origin);
}

/// Phase 3.5a: destructure a single binding pair `pattern = expr`.
/// Appends one or more `[name expr]` pairs to `out`.
fn destructurePair(
    ctx: *ExpandContext,
    pattern: *const Form,
    expr: *const Form,
    out: *std.ArrayList(*Form),
    origin: reader_mod.SrcSpan,
) ExpandError!void {
    switch (pattern.datum) {
        .symbol => |sym| {
            if (sym.ns != null) return ExpandError.MalformedMacroCall;
            try out.append(ctx.allocator, @constCast(pattern));
            try out.append(ctx.allocator, @constCast(expr));
        },
        .vector => |items| {
            // [a b & rest :as v] pattern over expr.
            // Bind a fresh tmp to expr, then walk elements.
            const tmp = try genTempSym(ctx, origin);
            try out.append(ctx.allocator, tmp);
            try out.append(ctx.allocator, @constCast(expr));
            try destructureVector(ctx, items, tmp, out, origin);
        },
        .map => |items| {
            const tmp = try genTempSym(ctx, origin);
            try out.append(ctx.allocator, tmp);
            try out.append(ctx.allocator, @constCast(expr));
            try destructureMap(ctx, items, tmp, out, origin);
        },
        else => return ExpandError.MalformedMacroCall,
    }
}

/// Destructure a vector pattern over a source expression that's
/// already bound to `src` (a symbol form).
///
/// Pattern elements: symbols bind to (nth src i nil); `&` rest
/// binds to repeated rest; `:as name` binds name to src.
fn destructureVector(
    ctx: *ExpandContext,
    elems: []const *Form,
    src: *Form,
    out: *std.ArrayList(*Form),
    origin: reader_mod.SrcSpan,
) ExpandError!void {
    var i: usize = 0;
    while (i < elems.len) : (i += 1) {
        const e = elems[i];
        // :as name
        if (e.datum == .keyword and e.datum.keyword.ns == null and std.mem.eql(u8, e.datum.keyword.name, "as")) {
            if (i + 1 >= elems.len) return ExpandError.MalformedMacroCall;
            const as_name = elems[i + 1];
            if (as_name.datum != .symbol) return ExpandError.MalformedMacroCall;
            try out.append(ctx.allocator, @constCast(as_name));
            try out.append(ctx.allocator, src);
            i += 1;
            continue;
        }
        // & rest
        if (e.datum == .symbol and e.datum.symbol.ns == null and std.mem.eql(u8, e.datum.symbol.name, "&")) {
            if (i + 1 >= elems.len) return ExpandError.MalformedMacroCall;
            const rest_pat = elems[i + 1];
            // Build expression: (rest (rest ... (rest src) ...))
            // applied `i` times to skip the first `i` elements.
            const rest_expr = try buildNestedRest(ctx, src, i, origin);
            try destructurePair(ctx, rest_pat, rest_expr, out, origin);
            i += 1;
            continue;
        }
        // Normal element: (nth src i nil)
        const nth_expr = try buildNthCall(ctx, src, i, origin);
        try destructurePair(ctx, e, nth_expr, out, origin);
    }
}

/// Destructure a map pattern.
///
/// Recognizes:
///   {:keys [a b]}      → a (get src :a nil)  b (get src :b nil)
///   {a :a-key}         → a (get src :a-key nil)
///   {... :or {a 10}}   → a (get src :a 10) (overrides default)
///   {... :as name}     → name src
fn destructureMap(
    ctx: *ExpandContext,
    entries: []const *Form,
    src: *Form,
    out: *std.ArrayList(*Form),
    origin: reader_mod.SrcSpan,
) ExpandError!void {
    if (entries.len % 2 != 0) return ExpandError.MalformedMacroCall;
    // First pass: find :or defaults + :as name.
    var defaults: ?[]const *Form = null;
    var as_name: ?*Form = null;
    var i: usize = 0;
    while (i < entries.len) : (i += 2) {
        const k = entries[i];
        const v = entries[i + 1];
        if (k.datum == .keyword and k.datum.keyword.ns == null) {
            if (std.mem.eql(u8, k.datum.keyword.name, "or")) {
                if (v.datum != .map) return ExpandError.MalformedMacroCall;
                defaults = v.datum.map;
            } else if (std.mem.eql(u8, k.datum.keyword.name, "as")) {
                if (v.datum != .symbol) return ExpandError.MalformedMacroCall;
                as_name = @constCast(v);
            }
        }
    }
    // Second pass: emit bindings.
    i = 0;
    while (i < entries.len) : (i += 2) {
        const k = entries[i];
        const v = entries[i + 1];
        // Skip :or / :as (handled above).
        if (k.datum == .keyword and k.datum.keyword.ns == null) {
            if (std.mem.eql(u8, k.datum.keyword.name, "or") or
                std.mem.eql(u8, k.datum.keyword.name, "as"))
            {
                continue;
            }
            if (std.mem.eql(u8, k.datum.keyword.name, "keys")) {
                if (v.datum != .vector) return ExpandError.MalformedMacroCall;
                for (v.datum.vector) |name_sym| {
                    if (name_sym.datum != .symbol) return ExpandError.MalformedMacroCall;
                    const sym_name = name_sym.datum.symbol.name;
                    const key_form = try makeKeyword(ctx, sym_name, origin);
                    const default_expr = lookupDefault(defaults, sym_name);
                    const get_expr = try buildGetCall(ctx, src, key_form, default_expr, origin);
                    try destructurePair(ctx, name_sym, get_expr, out, origin);
                }
                continue;
            }
        }
        // Explicit binding: pattern -> key-expr.
        const default_expr = if (k.datum == .symbol)
            lookupDefault(defaults, k.datum.symbol.name)
        else
            null;
        const get_expr = try buildGetCall(ctx, src, @constCast(v), default_expr, origin);
        try destructurePair(ctx, k, get_expr, out, origin);
    }
    if (as_name) |n| {
        try out.append(ctx.allocator, n);
        try out.append(ctx.allocator, src);
    }
}

fn lookupDefault(defaults: ?[]const *Form, name: []const u8) ?*Form {
    if (defaults) |d| {
        var i: usize = 0;
        while (i < d.len) : (i += 2) {
            const k = d[i];
            if (k.datum == .symbol and std.mem.eql(u8, k.datum.symbol.name, name)) {
                return @constCast(d[i + 1]);
            }
        }
    }
    return null;
}

/// Generate a fresh auto-gensym symbol like `nx__N__auto__`.
fn genTempSym(ctx: *ExpandContext, origin: reader_mod.SrcSpan) ExpandError!*Form {
    ctx.gensym_next += 1;
    const name = try std.fmt.allocPrint(ctx.allocator, "nx__{d}__auto__", .{ctx.gensym_next});
    return try makeSymbol(ctx, name, origin);
}

/// Build `(nth src idx nil)` as a Form.
fn buildNthCall(ctx: *ExpandContext, src: *Form, idx: usize, origin: reader_mod.SrcSpan) ExpandError!*Form {
    const items = try ctx.allocator.alloc(*Form, 4);
    items[0] = try makeSymbol(ctx, "nth", origin);
    items[1] = src;
    const idx_form = try ctx.allocator.create(Form);
    idx_form.* = .{ .datum = .{ .int = @intCast(idx) }, .origin = origin };
    items[2] = idx_form;
    items[3] = try makeNil(ctx, origin);
    return try makeList(ctx, items, origin);
}

/// Build `(rest (rest ... (rest src) ...))` applied `n` times.
fn buildNestedRest(ctx: *ExpandContext, src: *Form, n: usize, origin: reader_mod.SrcSpan) ExpandError!*Form {
    var expr: *Form = src;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const items = try ctx.allocator.alloc(*Form, 2);
        items[0] = try makeSymbol(ctx, "rest", origin);
        items[1] = expr;
        expr = try makeList(ctx, items, origin);
    }
    return expr;
}

/// Build `(get src key default?)` as a Form. If default is null,
/// emits the 2-arg form.
fn buildGetCall(ctx: *ExpandContext, src: *Form, key: *Form, default: ?*Form, origin: reader_mod.SrcSpan) ExpandError!*Form {
    const argc: usize = if (default != null) 4 else 3;
    const items = try ctx.allocator.alloc(*Form, argc);
    items[0] = try makeSymbol(ctx, "get", origin);
    items[1] = src;
    items[2] = key;
    if (default) |d| items[3] = d;
    return try makeList(ctx, items, origin);
}

fn makeKeyword(ctx: *ExpandContext, name: []const u8, origin: reader_mod.SrcSpan) ExpandError!*Form {
    const form = try ctx.allocator.create(Form);
    form.* = .{ .datum = .{ .keyword = .{ .ns = null, .name = name } }, .origin = origin };
    return form;
}

fn expandLoopRename(
    ctx: *ExpandContext,
    call_form: *const Form,
    args: []const *Form,
) ExpandError!*Form {
    return renameHead(ctx, call_form, args, "loop*");
}

/// Generic rename helper: emit (NEW_HEAD args...). Args are
/// passed through unchanged — the expander will descend into
/// them on the next walk via the special-form traversal for
/// the new head.
fn renameHead(
    ctx: *ExpandContext,
    call_form: *const Form,
    args: []const *Form,
    new_head: []const u8,
) ExpandError!*Form {
    const items = try ctx.allocator.alloc(*Form, args.len + 1);
    items[0] = try makeSymbol(ctx, new_head, call_form.origin);
    for (args, 0..) |a, i| items[1 + i] = @constCast(a);
    return try makeList(ctx, items, call_form.origin);
}

// ---- when / when-not -----------------------------------------
//
//   (when test body...)     => (if test (do body...) nil)
//   (when-not test body...) => (if test nil (do body...))

fn expandWhen(
    ctx: *ExpandContext,
    call_form: *const Form,
    args: []const *Form,
) ExpandError!*Form {
    if (args.len < 1) return ExpandError.MalformedMacroCall;
    return try buildWhen(ctx, call_form, args, .when_true);
}

fn expandWhenNot(
    ctx: *ExpandContext,
    call_form: *const Form,
    args: []const *Form,
) ExpandError!*Form {
    if (args.len < 1) return ExpandError.MalformedMacroCall;
    return try buildWhen(ctx, call_form, args, .when_false);
}

const WhenArm = enum { when_true, when_false };

fn buildWhen(
    ctx: *ExpandContext,
    call_form: *const Form,
    args: []const *Form,
    arm: WhenArm,
) ExpandError!*Form {
    const test_form = args[0];
    const body = args[1..];
    // Build (do body...) — empty body yields just (do).
    const do_items = try ctx.allocator.alloc(*Form, 1 + body.len);
    do_items[0] = try makeSymbol(ctx, "do", call_form.origin);
    for (body, 0..) |b, i| do_items[1 + i] = @constCast(b);
    const do_form = try makeList(ctx, do_items, call_form.origin);

    const nil_form = try makeNil(ctx, call_form.origin);
    const if_items = try ctx.allocator.alloc(*Form, 4);
    if_items[0] = try makeSymbol(ctx, "if", call_form.origin);
    if_items[1] = @constCast(test_form);
    switch (arm) {
        .when_true => {
            if_items[2] = do_form;
            if_items[3] = nil_form;
        },
        .when_false => {
            if_items[2] = nil_form;
            if_items[3] = do_form;
        },
    }
    return try makeList(ctx, if_items, call_form.origin);
}

// ---- and / or ------------------------------------------------
//
// Clojure semantics: `and` returns the FIRST FALSY value or
// the last value if all truthy; `or` returns the FIRST TRUTHY
// value or the last value if all falsy. Crucially, both
// return the actual value (not literal true/false).
//
//   (and)        => true
//   (and x)      => x
//   (and x y)    => (let* [g x] (if g y g))
//   (and x y z)  => (let* [g x] (if g (and y z) g))
//
//   (or)         => nil
//   (or x)       => x
//   (or x y)     => (let* [g x] (if g g y))
//   (or x y z)   => (let* [g x] (if g g (or y z)))
//
// BOTH `and` and `or` MUST gensym to avoid double-evaluating
// the first operand (per MACROEXPAND.md §10.G/H — peer-AI
// turn 56 §2.G).

fn expandAnd(
    ctx: *ExpandContext,
    call_form: *const Form,
    args: []const *Form,
) ExpandError!*Form {
    if (args.len == 0) return try makeBool(ctx, true, call_form.origin);
    if (args.len == 1) return @constCast(args[0]);

    // Build the "rest" — either args[1] alone (2-arg case)
    // or a recursive (and ...) call.
    const rest_form: *Form = if (args.len == 2)
        @constCast(args[1])
    else blk: {
        const rest_items = try ctx.allocator.alloc(*Form, args.len);
        rest_items[0] = try makeSymbol(ctx, "and", call_form.origin);
        for (args[1..], 0..) |a, i| rest_items[1 + i] = @constCast(a);
        break :blk try makeList(ctx, rest_items, call_form.origin);
    };

    // (let* [g args[0]] (if g rest g))
    const g_name = try ctx.gensym("and");
    const g_sym1 = try makeSymbol(ctx, g_name, call_form.origin);
    const g_sym2 = try makeSymbol(ctx, g_name, call_form.origin);
    const g_sym3 = try makeSymbol(ctx, g_name, call_form.origin);

    const binding_items = try ctx.allocator.alloc(*Form, 2);
    binding_items[0] = g_sym1;
    binding_items[1] = @constCast(args[0]);
    const binding_vec = try makeVector(ctx, binding_items, call_form.origin);

    const if_items = try ctx.allocator.alloc(*Form, 4);
    if_items[0] = try makeSymbol(ctx, "if", call_form.origin);
    if_items[1] = g_sym2;
    if_items[2] = rest_form;
    if_items[3] = g_sym3;
    const if_form = try makeList(ctx, if_items, call_form.origin);

    const let_items = try ctx.allocator.alloc(*Form, 3);
    let_items[0] = try makeSymbol(ctx, "let*", call_form.origin);
    let_items[1] = binding_vec;
    let_items[2] = if_form;
    return try makeList(ctx, let_items, call_form.origin);
}

fn expandOr(
    ctx: *ExpandContext,
    call_form: *const Form,
    args: []const *Form,
) ExpandError!*Form {
    if (args.len == 0) return try makeNil(ctx, call_form.origin);
    if (args.len == 1) return @constCast(args[0]);

    // Build the "rest" — either the single second arg or
    // a recursive (or ...) call.
    const rest_form: *Form = if (args.len == 2)
        @constCast(args[1])
    else blk: {
        const rest_items = try ctx.allocator.alloc(*Form, args.len);
        rest_items[0] = try makeSymbol(ctx, "or", call_form.origin);
        for (args[1..], 0..) |a, i| rest_items[1 + i] = @constCast(a);
        break :blk try makeList(ctx, rest_items, call_form.origin);
    };

    // (let* [g args[0]] (if g g rest_form))
    const g_name = try ctx.gensym("or");
    const g_sym1 = try makeSymbol(ctx, g_name, call_form.origin);
    const g_sym2 = try makeSymbol(ctx, g_name, call_form.origin);
    const g_sym3 = try makeSymbol(ctx, g_name, call_form.origin);

    const binding_items = try ctx.allocator.alloc(*Form, 2);
    binding_items[0] = g_sym1;
    binding_items[1] = @constCast(args[0]);
    const binding_vec = try makeVector(ctx, binding_items, call_form.origin);

    const if_items = try ctx.allocator.alloc(*Form, 4);
    if_items[0] = try makeSymbol(ctx, "if", call_form.origin);
    if_items[1] = g_sym2;
    if_items[2] = g_sym3;
    if_items[3] = rest_form;
    const if_form = try makeList(ctx, if_items, call_form.origin);

    const let_items = try ctx.allocator.alloc(*Form, 3);
    let_items[0] = try makeSymbol(ctx, "let*", call_form.origin);
    let_items[1] = binding_vec;
    let_items[2] = if_form;
    return try makeList(ctx, let_items, call_form.origin);
}

// ---- cond ----------------------------------------------------
//
//   (cond)              => nil
//   (cond t1 e1)        => (if t1 e1 nil)
//   (cond t1 e1 t2 e2)  => (if t1 e1 (if t2 e2 nil))
//
// Odd-count args raise MalformedMacroCall. No special-case for
// `:else` in v1 — any truthy test works as a default; users can
// write `(cond ... :else default)` and the keyword's truthiness
// makes it pass.

fn expandCond(
    ctx: *ExpandContext,
    call_form: *const Form,
    args: []const *Form,
) ExpandError!*Form {
    if (args.len == 0) return try makeNil(ctx, call_form.origin);
    if (args.len % 2 != 0) return ExpandError.MalformedMacroCall;

    // Build right-to-left: start from nil, wrap each pair.
    var current: *Form = try makeNil(ctx, call_form.origin);
    var i: usize = args.len;
    while (i >= 2) : (i -= 2) {
        const test_form = args[i - 2];
        const expr_form = args[i - 1];
        const if_items = try ctx.allocator.alloc(*Form, 4);
        if_items[0] = try makeSymbol(ctx, "if", call_form.origin);
        if_items[1] = @constCast(test_form);
        if_items[2] = @constCast(expr_form);
        if_items[3] = current;
        current = try makeList(ctx, if_items, call_form.origin);
    }
    return current;
}

// ---- ->  /  ->>  (threading macros) --------------------------
//
//   (-> x)             => x
//   (-> x f)           => (f x)
//   (-> x (f a b))     => (f x a b)            ; thread-first
//   (-> x f (g a))     => (g (f x) a)          ; chained
//
//   (->> x f)          => (f x)
//   (->> x (f a b))    => (f a b x)            ; thread-last
//
// Symbol step `f` is treated as `(f)` — equivalent to inserting
// the threaded value as the sole arg. Non-symbol non-list steps
// raise MalformedMacroCall.

const ThreadPosition = enum { first, last };

fn expandThreadFirst(
    ctx: *ExpandContext,
    call_form: *const Form,
    args: []const *Form,
) ExpandError!*Form {
    return try expandThread(ctx, call_form, args, .first);
}

fn expandThreadLast(
    ctx: *ExpandContext,
    call_form: *const Form,
    args: []const *Form,
) ExpandError!*Form {
    return try expandThread(ctx, call_form, args, .last);
}

fn expandThread(
    ctx: *ExpandContext,
    call_form: *const Form,
    args: []const *Form,
    pos: ThreadPosition,
) ExpandError!*Form {
    if (args.len == 0) return ExpandError.MalformedMacroCall;
    var acc: *Form = @constCast(args[0]);
    for (args[1..]) |step| {
        acc = try threadStep(ctx, call_form, acc, step, pos);
    }
    return acc;
}

fn threadStep(
    ctx: *ExpandContext,
    call_form: *const Form,
    acc: *Form,
    step: *const Form,
    pos: ThreadPosition,
) ExpandError!*Form {
    // Symbol step `f` → (f acc).
    if (step.datum == .symbol) {
        const items = try ctx.allocator.alloc(*Form, 2);
        items[0] = @constCast(step);
        items[1] = acc;
        return try makeList(ctx, items, call_form.origin);
    }
    // List step (f a b) → thread-first: (f acc a b)
    //                      thread-last:  (f a b acc)
    if (step.datum == .list) {
        const step_items = step.datum.list;
        if (step_items.len == 0) return ExpandError.MalformedMacroCall;
        const new_items = try ctx.allocator.alloc(*Form, step_items.len + 1);
        switch (pos) {
            .first => {
                // (head acc rest...)
                new_items[0] = @constCast(step_items[0]);
                new_items[1] = acc;
                for (step_items[1..], 0..) |it, i| new_items[2 + i] = @constCast(it);
            },
            .last => {
                // (head rest... acc)
                for (step_items, 0..) |it, i| new_items[i] = @constCast(it);
                new_items[step_items.len] = acc;
            },
        }
        return try makeList(ctx, new_items, call_form.origin);
    }
    return ExpandError.MalformedMacroCall;
}

// =============================================================================
// Syntax-quote / unquote / unquote-splicing (step #8c.2)
// =============================================================================
//
// Per MACROEXPAND.md §5 + peer-AI turn 58 §D4/D7/D10.
//
// `` `payload `` walks the payload, producing a Form that
// CONSTRUCTS the quoted shape at runtime via #%list / #%concat
// (the substrate landed in #8c.1).
//
// Element rules:
//   nil / bool / int / real / char / string / keyword
//     → return as-is (self-evaluating in nexis, no quote wrap
//       needed). Equivalent to `(quote X)` but cheaper.
//   symbol
//     ends with `#` → gensym-lookup in current scope; emit
//                     `(quote <name__N__auto__>)`
//     else          → emit `(quote sym)`
//   unquote        → return payload as-is (caller will re-walk
//                    via normal expansion path; macros in
//                    the unquote payload expand normally; the
//                    payload is evaluated at runtime).
//   unquote-splice → ILLEGAL outside list-element position.
//                    The list walker handles splice; reaching
//                    one here raises MalformedMacroCall.
//   list           → expandSyntaxQuoteList (segment-and-concat)
//   vector/map/set → UnsupportedFeature (deferred per §D10)
//   quote / syntax-quote / anon_fn / with_meta / deref / nested
//   syntax_quote   → UnsupportedFeature (deferred per §D7;
//                    nested syntax-quote needs scope stacking)
//
// Auto-gensym scope lifecycle:
//   - Fresh GensymScope opened at every `Datum.syntax_quote`
//     entry. Per peer-AI turn 56 §1.4: ONE scope per syntax-
//     quote form. Nested syntax-quote opens another scope but
//     v1 raises UnsupportedFeature first, so this never fires.
//   - Counter is on ExpandContext.gensym_next (monotonic
//     across the entire compilation unit), so two separate
//     syntax-quotes never collide even though their scopes
//     are independent.

/// Per-syntax-quote auto-gensym scope. Maps source name (with
/// the `#` suffix) to the generated `name__N__auto__` string.
/// Multiple references to the same `x#` within ONE syntax-
/// quote scope return the same gensym; another syntax-quote
/// at the same source position with the same `x#` returns a
/// DIFFERENT gensym (the per-syntax-quote scope is fresh).
pub const GensymScope = struct {
    mappings: std.StringHashMapUnmanaged([]const u8) = .{},

    pub fn deinit(self: *GensymScope, allocator: Allocator) void {
        self.mappings.deinit(allocator);
    }

    /// Look up `name#` in the scope; allocate a fresh gensym
    /// (via ctx.gensym(base)) if absent. `name` MUST end in
    /// `#` (caller checks).
    fn lookupOrAllocate(
        self: *GensymScope,
        ctx: *ExpandContext,
        name: []const u8,
    ) ExpandError![]const u8 {
        if (self.mappings.get(name)) |existing| return existing;
        // Strip the trailing `#` for the gensym base.
        const base = name[0 .. name.len - 1];
        const generated = try ctx.gensym(base);
        try self.mappings.put(ctx.allocator, name, generated);
        return generated;
    }
};

/// Walk a syntax-quoted form. Returns a Form that, when
/// compiled and run, produces the quoted shape.
fn expandSyntaxQuotePayload(
    ctx: *ExpandContext,
    scope: *GensymScope,
    call_form: *const Form,
    payload: *const Form,
) ExpandError!*Form {
    return switch (payload.datum) {
        // Self-evaluating leaves: pass through. Lowered as
        // existing Tiny variants — no quote wrap needed.
        .nil, .bool_, .int, .real, .char, .string, .keyword => mutCast(payload),
        // Symbol → (quote sym) — unless ends with `#`, then
        // gensym lookup.
        .symbol => |name| blk: {
            if (name.ns != null) return ExpandError.MalformedMacroCall;
            const sym_name: []const u8 = if (name.name.len > 1 and name.name[name.name.len - 1] == '#')
                try scope.lookupOrAllocate(ctx, name.name)
            else
                name.name;
            const sym_form = try makeSymbol(ctx, sym_name, payload.origin);
            // Emit (quote <sym>).
            const items = try ctx.allocator.alloc(*Form, 2);
            items[0] = try makeSymbol(ctx, "quote", call_form.origin);
            items[1] = sym_form;
            break :blk try makeList(ctx, items, call_form.origin);
        },
        // Unquote: return the payload directly; it goes through
        // normal expansion + evaluation on the outer walk.
        .unquote => |inner| mutCast(inner),
        // Splice in non-list context is illegal.
        .unquote_splicing => return ExpandError.MalformedMacroCall,
        // List: build the segment-and-concat structure.
        .list => |items| try expandSyntaxQuoteList(ctx, scope, call_form, items, payload.origin),
        // Step #8c.3: Vector — same pattern as list. The
        // result wraps in `(#%vector ...)` instead of
        // `(#%list ...)`. Splices inside a vector are also
        // supported via concat + apply, but for v1 simplicity
        // we delegate vector-with-splice via concat of vectors
        // and a final apply: but easier path — we just don't
        // support splice inside vector for v1, since vector-
        // valued macros rarely splice (binding vectors are
        // built positionally). UnsupportedFeature if splice
        // appears inside a syntax-quoted vector.
        .vector => |items| try expandSyntaxQuoteVector(ctx, scope, call_form, items, payload.origin),
        // Deferred: map/set/nested-syntax-quote and other
        // reader macros need explicit support (peer-AI turn 58
        // §D7/D10). v1 raises MalformedMacroCall via the
        // MacroExpansionFailure bucket.
        else => return ExpandError.MalformedMacroCall,
    };
}

/// Step #8c.3: walk a syntax-quoted vector. Simpler than the
/// list walker — no splice support in v1 (binding vectors are
/// built positionally; splicing into vectors is rare and
/// requires concat-of-vectors machinery that's not worth the
/// extra surface).
fn expandSyntaxQuoteVector(
    ctx: *ExpandContext,
    scope: *GensymScope,
    call_form: *const Form,
    items: []const *Form,
    origin: reader_mod.SrcSpan,
) ExpandError!*Form {
    // Reject splices inside vectors for v1.
    for (items) |it| {
        if (it.datum == .unquote_splicing) return ExpandError.MalformedMacroCall;
    }
    const seg_items = try ctx.allocator.alloc(*Form, items.len + 1);
    seg_items[0] = try makeSymbol(ctx, "#%vector", origin);
    for (items, 0..) |item, i| {
        seg_items[1 + i] = try expandSyntaxQuotePayload(ctx, scope, call_form, item);
    }
    return try makeList(ctx, seg_items, origin);
}

/// Walk the items of a syntax-quoted list. Groups runs of
/// non-splice elements into `(#%list ...)` segments; splices
/// interleave as separate concat arguments. Returns either
/// a bare `(#%list ...)` (no splices found) or a
/// `(#%concat ...)` wrapping multiple segments.
fn expandSyntaxQuoteList(
    ctx: *ExpandContext,
    scope: *GensymScope,
    call_form: *const Form,
    items: []const *Form,
    list_origin: reader_mod.SrcSpan,
) ExpandError!*Form {
    var segments: std.ArrayList(*Form) = .empty;
    defer segments.deinit(ctx.allocator);
    var current: std.ArrayList(*Form) = .empty;
    defer current.deinit(ctx.allocator);

    const flushCurrent = struct {
        fn call(c: *std.ArrayList(*Form), cx: *ExpandContext, segs: *std.ArrayList(*Form), origin: reader_mod.SrcSpan) ExpandError!void {
            if (c.items.len == 0) return;
            // Build (#%list ...) from the current segment.
            const seg_items = try cx.allocator.alloc(*Form, c.items.len + 1);
            seg_items[0] = try makeSymbol(cx, "#%list", origin);
            for (c.items, 0..) |it, i| seg_items[1 + i] = it;
            const seg_form = try makeList(cx, seg_items, origin);
            try segs.append(cx.allocator, seg_form);
            c.clearRetainingCapacity();
        }
    }.call;

    for (items) |item| {
        if (item.datum == .unquote_splicing) {
            // Flush the current segment, then add the spliced
            // payload as its own concat segment.
            try flushCurrent(&current, ctx, &segments, list_origin);
            try segments.append(ctx.allocator, mutCast(item.datum.unquote_splicing));
        } else {
            try current.append(ctx.allocator, try expandSyntaxQuotePayload(ctx, scope, call_form, item));
        }
    }
    try flushCurrent(&current, ctx, &segments, list_origin);

    // 0 segments → empty list: `(#%list)`.
    if (segments.items.len == 0) {
        const empty_items = try ctx.allocator.alloc(*Form, 1);
        empty_items[0] = try makeSymbol(ctx, "#%list", list_origin);
        return try makeList(ctx, empty_items, list_origin);
    }
    // 1 segment → return it directly. If it's a single
    // segment, no concat needed. The segment is already
    // either a `(#%list ...)` (if it came from a flush)
    // or a spliced expression (which evaluates to a list
    // at runtime — return it as-is and trust the caller).
    if (segments.items.len == 1) return segments.items[0];

    // 2+ segments → wrap in (#%concat seg1 seg2 ...).
    const concat_items = try ctx.allocator.alloc(*Form, segments.items.len + 1);
    concat_items[0] = try makeSymbol(ctx, "#%concat", list_origin);
    for (segments.items, 0..) |seg, i| concat_items[1 + i] = seg;
    return try makeList(ctx, concat_items, list_origin);
}

// ---- Default macro table -------------------------------------

/// Build the standard host-macro table for `nexis run`. Pass
/// the result via `compileSourceFullWithMacros` (the CLI does
/// this automatically). Caller owns the returned table and is
/// responsible for `table.deinit(allocator)`.
pub fn defaultMacros(allocator: Allocator) ExpandError!HostMacroTable {
    var table: HostMacroTable = .{};
    errdefer table.deinit(allocator);
    try table.put(allocator, "let", expandLetRename);
    try table.put(allocator, "fn", expandFnRename);
    try table.put(allocator, "defn", expandDefnMacro);
    try table.put(allocator, "loop", expandLoopRename);
    try table.put(allocator, "when", expandWhen);
    try table.put(allocator, "when-not", expandWhenNot);
    try table.put(allocator, "and", expandAnd);
    try table.put(allocator, "or", expandOr);
    try table.put(allocator, "cond", expandCond);
    try table.put(allocator, "->", expandThreadFirst);
    try table.put(allocator, "->>", expandThreadLast);
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

test "macroexpand #8a: no-op walks return input unchanged (empty table)" {
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

test "macroexpand #8a: empty list passes through" {
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

test "macroexpand #8a: depth limit caught for infinite macro loop" {
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

test "macroexpand #8a: lexical shadowing blocks macro expansion" {
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

test "macroexpand #8a: macro fires at top level when not shadowed" {
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

test "macroexpand #8a: quote is opaque — macro inside quote does NOT fire" {
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
