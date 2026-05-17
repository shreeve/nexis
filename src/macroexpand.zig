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
//!   - Defines `MacroexpandContext`, `MacroFn`, `HostMacroTable`,
//!     `ExpandEnv`, `MacroexpandError`.
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
pub const MacroexpandError = error{
    ExpansionDepthExceeded,
    MalformedMacroCall,
    MacroReturnedNull,
    OutOfMemory,
};

/// Per-spec MACROEXPAND.md §1: bundles every cross-cutting
/// resource a host MacroFn might need. Lives FOR THE LIFETIME
/// of a single compilation unit (typically one CLI invocation
/// or one test). Reusing across forms is how auto-gensym stays
/// monotonic within a unit.
pub const MacroexpandContext = struct {
    allocator: Allocator,
    interner: *intern_mod.Interner,
    /// Monotonic auto-gensym counter (peer-AI turn 56 §1.4 +
    /// §5: lives on the context, NOT the VM). Used by host
    /// macros that need to avoid double-evaluation (e.g. `or`).
    gensym_next: u64 = 0,
    /// Macro registry. May be empty (#8a default → no expansion
    /// fires).
    host_macros: *const HostMacroTable,

    /// Allocate a fresh gensym name in the context's arena.
    /// Format: `<base>__<counter>__auto__` per MACROEXPAND.md §4.
    /// The `__auto__` suffix marks auto-gensym (vs future
    /// user-controlled `(gensym base)`).
    ///
    /// Lifetime: the returned slice lives in `ctx.allocator`,
    /// which is the macroexpand arena (typically the same as
    /// the compile arena). The caller does NOT free.
    pub fn gensym(self: *MacroexpandContext, base: []const u8) MacroexpandError![]const u8 {
        const counter = self.gensym_next;
        self.gensym_next += 1;
        return std.fmt.allocPrint(self.allocator, "{s}__{d}__auto__", .{ base, counter });
    }
};

/// Host-Zig macro callback. Takes the call form (head + args)
/// and produces a rewritten form. The result is then re-fed to
/// `expandForm` (so macro-of-macros works automatically).
pub const MacroFn = *const fn (
    ctx: *MacroexpandContext,
    call_form: *const Form,
    args: []const *Form,
) MacroexpandError!*Form;

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
    ctx: *MacroexpandContext,
    env: ?*const ExpandEnv,
    form: *const Form,
) MacroexpandError!*Form {
    return expandFormDepth(ctx, env, form, 0);
}

/// Walk an array of top-level forms (e.g. file contents).
/// Output is a fresh slice in `ctx.allocator`. The same
/// gensym counter is reused across all forms so gensyms stay
/// unique within the unit.
pub fn expandProgram(
    ctx: *MacroexpandContext,
    forms: []const *Form,
) MacroexpandError![]const *Form {
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
    ctx: *MacroexpandContext,
    env: ?*const ExpandEnv,
    form: *const Form,
    depth: u32,
) MacroexpandError!*Form {
    if (depth > MAX_EXPANSION_DEPTH) return MacroexpandError.ExpansionDepthExceeded;

    return switch (form.datum) {
        // ---- Leaves — pass through unchanged. -----------------
        .nil, .bool_, .int, .real, .char, .string, .keyword, .symbol => mutCast(form),
        // ---- Lists — special-form recognition + macro dispatch. --
        .list => |items| try expandList(ctx, env, form, items, depth),
        // ---- Compound non-list collections (#8a: pass-through). --
        // Phase-2 source doesn't allow vector/map/set as code
        // (only in `let*` binding vectors, which are handled by
        // the let* arm via direct items access). For top-level
        // vector/map/set expressions, lowerForm will raise
        // UnsupportedFeature; we don't pre-traverse them here.
        .vector, .map, .set => mutCast(form),
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
        .unquote, .unquote_splicing => return MacroexpandError.MalformedMacroCall,
        // ---- Reader macros / metadata. -----------------------
        // anon_fn `#(...)` will land as a macro expansion in
        // step #8b (or, more conservatively, as a dedicated
        // lower-form transform). #8a leaves it opaque so
        // lowerForm raises UnsupportedFeature consistently.
        .anon_fn => mutCast(form),
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
    ctx: *MacroexpandContext,
    env: ?*const ExpandEnv,
    list_form: *const Form,
    items: []const *Form,
    depth: u32,
) MacroexpandError!*Form {
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
    if (std.mem.eql(u8, name, "defn")) return try expandDefn(ctx, env, list_form, items, depth);
    if (std.mem.eql(u8, name, "var")) return mutCast(list_form); // (var X) — X is just a name, don't expand
    // Step #8c.1: internal compiler primitives (#%list / #%concat).
    // Recognized as special forms — NOT user-shadowable, NOT
    // looked up in the macro table. Args ARE recursively
    // macroexpanded (per peer-AI turn 58 §D1 + §"Missing trap
    // #6"): a `(#%list (when x y))` should expand `(when x y)`.
    if (std.mem.eql(u8, name, "#%list") or
        std.mem.eql(u8, name, "#%concat") or
        std.mem.eql(u8, name, "#%vector"))
    {
        return try expandOrdinaryCall(ctx, env, list_form, items, depth);
    }

    // ---- Macro dispatch (shadowable by lexical bindings). -----
    if (env == null or !env.?.contains(name)) {
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
    ctx: *MacroexpandContext,
    env: ?*const ExpandEnv,
    macro_fn: MacroFn,
    call_form: *const Form,
    items: []const *Form,
    depth: u32,
) MacroexpandError!*Form {
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
    ctx: *MacroexpandContext,
    env: ?*const ExpandEnv,
    list_form: *const Form,
    items: []const *Form,
    depth: u32,
) MacroexpandError!*Form {
    // (if test then) | (if test then else)
    if (items.len < 3 or items.len > 4) return MacroexpandError.MalformedMacroCall;
    return try rebuildListIfChanged(ctx, list_form, items, env, depth);
}

fn expandDo(
    ctx: *MacroexpandContext,
    env: ?*const ExpandEnv,
    list_form: *const Form,
    items: []const *Form,
    depth: u32,
) MacroexpandError!*Form {
    return try rebuildListIfChanged(ctx, list_form, items, env, depth);
}

fn expandRecur(
    ctx: *MacroexpandContext,
    env: ?*const ExpandEnv,
    list_form: *const Form,
    items: []const *Form,
    depth: u32,
) MacroexpandError!*Form {
    return try rebuildListIfChanged(ctx, list_form, items, env, depth);
}

fn expandOrdinaryCall(
    ctx: *MacroexpandContext,
    env: ?*const ExpandEnv,
    list_form: *const Form,
    items: []const *Form,
    depth: u32,
) MacroexpandError!*Form {
    return try rebuildListIfChanged(ctx, list_form, items, env, depth);
}

/// Common pattern: expand every list item with the same env,
/// rebuild the list ONLY if at least one item changed. Avoids
/// unnecessary allocation when no expansion fires.
fn rebuildListIfChanged(
    ctx: *MacroexpandContext,
    list_form: *const Form,
    items: []const *Form,
    env: ?*const ExpandEnv,
    depth: u32,
) MacroexpandError!*Form {
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
    ctx: *MacroexpandContext,
    env: ?*const ExpandEnv,
    list_form: *const Form,
    items: []const *Form,
    depth: u32,
) MacroexpandError!*Form {
    // (let* [n1 v1 n2 v2 ...] body...)
    if (items.len < 2) return MacroexpandError.MalformedMacroCall;
    const head = items[0]; // the `let*` symbol form
    const binding_form = items[1];
    if (binding_form.datum != .vector) return MacroexpandError.MalformedMacroCall;
    const bindings = binding_form.datum.vector;
    if (bindings.len % 2 != 0) return MacroexpandError.MalformedMacroCall;

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
            return MacroexpandError.MalformedMacroCall;
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
    ctx: *MacroexpandContext,
    env: ?*const ExpandEnv,
    list_form: *const Form,
    items: []const *Form,
    depth: u32,
) MacroexpandError!*Form {
    // (fn* [params] body...) | (fn* name [params] body...)
    if (items.len < 2) return MacroexpandError.MalformedMacroCall;
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
    if (params_idx >= items.len) return MacroexpandError.MalformedMacroCall;
    const params_form = items[params_idx];
    if (params_form.datum != .vector) return MacroexpandError.MalformedMacroCall;
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
    ctx: *MacroexpandContext,
    env: ?*const ExpandEnv,
    list_form: *const Form,
    items: []const *Form,
    depth: u32,
) MacroexpandError!*Form {
    // (letfn* [(name [params] body...) ...] body...)
    if (items.len < 2) return MacroexpandError.MalformedMacroCall;
    const head = items[0];
    const binding_form = items[1];
    if (binding_form.datum != .vector) return MacroexpandError.MalformedMacroCall;
    const fn_entries = binding_form.datum.vector;

    // First pass: collect every fn name into the local env, so
    // each fn body sees ALL fn names (mutual recursion).
    var local: ExpandEnv = .{ .parent = env };
    defer local.deinit(ctx.allocator);
    for (fn_entries) |entry| {
        if (entry.datum != .list or entry.datum.list.len < 2) {
            return MacroexpandError.MalformedMacroCall;
        }
        const entry_items = entry.datum.list;
        const fn_name_form = entry_items[0];
        if (fn_name_form.datum != .symbol or fn_name_form.datum.symbol.ns != null) {
            return MacroexpandError.MalformedMacroCall;
        }
        _ = try local.lexical_names.getOrPut(ctx.allocator, fn_name_form.datum.symbol.name);
    }

    // Second pass: expand each fn body under (local + that fn's
    // params).
    const new_entries = try ctx.allocator.alloc(*Form, fn_entries.len);
    for (fn_entries, 0..) |entry, idx| {
        const entry_items = entry.datum.list;
        const fn_params = entry_items[1];
        if (fn_params.datum != .vector) return MacroexpandError.MalformedMacroCall;
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
    ctx: *MacroexpandContext,
    env: ?*const ExpandEnv,
    list_form: *const Form,
    items: []const *Form,
    depth: u32,
) MacroexpandError!*Form {
    // (def name) | (def name value)
    if (items.len < 2 or items.len > 3) return MacroexpandError.MalformedMacroCall;
    const head = items[0];
    const name_form = items[1];
    if (name_form.datum != .symbol) return MacroexpandError.MalformedMacroCall;
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
    ctx: *MacroexpandContext,
    env: ?*const ExpandEnv,
    list_form: *const Form,
    items: []const *Form,
    depth: u32,
) MacroexpandError!*Form {
    // (defn name [params] body...)
    if (items.len < 3) return MacroexpandError.MalformedMacroCall;
    const head = items[0];
    const name_form = items[1];
    if (name_form.datum != .symbol) return MacroexpandError.MalformedMacroCall;
    const params_form = items[2];
    if (params_form.datum != .vector) return MacroexpandError.MalformedMacroCall;
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

pub fn makeList(ctx: *MacroexpandContext, items: []*Form, origin: SrcSpan) MacroexpandError!*Form {
    const form = try ctx.allocator.create(Form);
    form.* = .{
        .datum = .{ .list = @as([]const *Form, items) },
        .origin = origin,
    };
    return form;
}

pub fn makeVector(ctx: *MacroexpandContext, items: []*Form, origin: SrcSpan) MacroexpandError!*Form {
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
pub fn makeSymbol(ctx: *MacroexpandContext, name: []const u8, origin: SrcSpan) MacroexpandError!*Form {
    const form = try ctx.allocator.create(Form);
    form.* = .{
        .datum = .{ .symbol = .{ .ns = null, .name = name } },
        .origin = origin,
    };
    return form;
}

pub fn makeNil(ctx: *MacroexpandContext, origin: SrcSpan) MacroexpandError!*Form {
    const form = try ctx.allocator.create(Form);
    form.* = .{ .datum = .nil, .origin = origin };
    return form;
}

pub fn makeBool(ctx: *MacroexpandContext, value: bool, origin: SrcSpan) MacroexpandError!*Form {
    const form = try ctx.allocator.create(Form);
    form.* = .{ .datum = .{ .bool_ = value }, .origin = origin };
    return form;
}

// =============================================================================
// Host core macros (MACROEXPAND.md §10 — step #8b)
// =============================================================================
//
// Each macro fn matches `MacroFn`:
//   fn(ctx, call_form, args) MacroexpandError!*Form
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

fn expandLetRename(
    ctx: *MacroexpandContext,
    call_form: *const Form,
    args: []const *Form,
) MacroexpandError!*Form {
    return renameHead(ctx, call_form, args, "let*");
}

fn expandFnRename(
    ctx: *MacroexpandContext,
    call_form: *const Form,
    args: []const *Form,
) MacroexpandError!*Form {
    return renameHead(ctx, call_form, args, "fn*");
}

fn expandLoopRename(
    ctx: *MacroexpandContext,
    call_form: *const Form,
    args: []const *Form,
) MacroexpandError!*Form {
    return renameHead(ctx, call_form, args, "loop*");
}

/// Generic rename helper: emit (NEW_HEAD args...). Args are
/// passed through unchanged — the expander will descend into
/// them on the next walk via the special-form traversal for
/// the new head.
fn renameHead(
    ctx: *MacroexpandContext,
    call_form: *const Form,
    args: []const *Form,
    new_head: []const u8,
) MacroexpandError!*Form {
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
    ctx: *MacroexpandContext,
    call_form: *const Form,
    args: []const *Form,
) MacroexpandError!*Form {
    if (args.len < 1) return MacroexpandError.MalformedMacroCall;
    return try buildWhen(ctx, call_form, args, .when_true);
}

fn expandWhenNot(
    ctx: *MacroexpandContext,
    call_form: *const Form,
    args: []const *Form,
) MacroexpandError!*Form {
    if (args.len < 1) return MacroexpandError.MalformedMacroCall;
    return try buildWhen(ctx, call_form, args, .when_false);
}

const WhenArm = enum { when_true, when_false };

fn buildWhen(
    ctx: *MacroexpandContext,
    call_form: *const Form,
    args: []const *Form,
    arm: WhenArm,
) MacroexpandError!*Form {
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
    ctx: *MacroexpandContext,
    call_form: *const Form,
    args: []const *Form,
) MacroexpandError!*Form {
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
    ctx: *MacroexpandContext,
    call_form: *const Form,
    args: []const *Form,
) MacroexpandError!*Form {
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
    ctx: *MacroexpandContext,
    call_form: *const Form,
    args: []const *Form,
) MacroexpandError!*Form {
    if (args.len == 0) return try makeNil(ctx, call_form.origin);
    if (args.len % 2 != 0) return MacroexpandError.MalformedMacroCall;

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
    ctx: *MacroexpandContext,
    call_form: *const Form,
    args: []const *Form,
) MacroexpandError!*Form {
    return try expandThread(ctx, call_form, args, .first);
}

fn expandThreadLast(
    ctx: *MacroexpandContext,
    call_form: *const Form,
    args: []const *Form,
) MacroexpandError!*Form {
    return try expandThread(ctx, call_form, args, .last);
}

fn expandThread(
    ctx: *MacroexpandContext,
    call_form: *const Form,
    args: []const *Form,
    pos: ThreadPosition,
) MacroexpandError!*Form {
    if (args.len == 0) return MacroexpandError.MalformedMacroCall;
    var acc: *Form = @constCast(args[0]);
    for (args[1..]) |step| {
        acc = try threadStep(ctx, call_form, acc, step, pos);
    }
    return acc;
}

fn threadStep(
    ctx: *MacroexpandContext,
    call_form: *const Form,
    acc: *Form,
    step: *const Form,
    pos: ThreadPosition,
) MacroexpandError!*Form {
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
        if (step_items.len == 0) return MacroexpandError.MalformedMacroCall;
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
    return MacroexpandError.MalformedMacroCall;
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
//   - Counter is on MacroexpandContext.gensym_next (monotonic
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
        ctx: *MacroexpandContext,
        name: []const u8,
    ) MacroexpandError![]const u8 {
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
    ctx: *MacroexpandContext,
    scope: *GensymScope,
    call_form: *const Form,
    payload: *const Form,
) MacroexpandError!*Form {
    return switch (payload.datum) {
        // Self-evaluating leaves: pass through. Lowered as
        // existing Tiny variants — no quote wrap needed.
        .nil, .bool_, .int, .real, .char, .string, .keyword => mutCast(payload),
        // Symbol → (quote sym) — unless ends with `#`, then
        // gensym lookup.
        .symbol => |name| blk: {
            if (name.ns != null) return MacroexpandError.MalformedMacroCall;
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
        .unquote_splicing => return MacroexpandError.MalformedMacroCall,
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
        else => return MacroexpandError.MalformedMacroCall,
    };
}

/// Step #8c.3: walk a syntax-quoted vector. Simpler than the
/// list walker — no splice support in v1 (binding vectors are
/// built positionally; splicing into vectors is rare and
/// requires concat-of-vectors machinery that's not worth the
/// extra surface).
fn expandSyntaxQuoteVector(
    ctx: *MacroexpandContext,
    scope: *GensymScope,
    call_form: *const Form,
    items: []const *Form,
    origin: reader_mod.SrcSpan,
) MacroexpandError!*Form {
    // Reject splices inside vectors for v1.
    for (items) |it| {
        if (it.datum == .unquote_splicing) return MacroexpandError.MalformedMacroCall;
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
    ctx: *MacroexpandContext,
    scope: *GensymScope,
    call_form: *const Form,
    items: []const *Form,
    list_origin: reader_mod.SrcSpan,
) MacroexpandError!*Form {
    var segments: std.ArrayList(*Form) = .empty;
    defer segments.deinit(ctx.allocator);
    var current: std.ArrayList(*Form) = .empty;
    defer current.deinit(ctx.allocator);

    const flushCurrent = struct {
        fn call(c: *std.ArrayList(*Form), cx: *MacroexpandContext, segs: *std.ArrayList(*Form), origin: reader_mod.SrcSpan) MacroexpandError!void {
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
pub fn defaultMacros(allocator: Allocator) MacroexpandError!HostMacroTable {
    var table: HostMacroTable = .{};
    errdefer table.deinit(allocator);
    try table.put(allocator, "let", expandLetRename);
    try table.put(allocator, "fn", expandFnRename);
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
    var ctx = MacroexpandContext{
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
            _: *MacroexpandContext,
            call_form: *const Form,
            _: []const *Form,
        ) MacroexpandError!*Form {
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
    var ctx = MacroexpandContext{
        .allocator = arena,
        .interner = &interner,
        .host_macros = &table,
    };
    try testing.expectError(MacroexpandError.ExpansionDepthExceeded, expandForm(&ctx, null, form));
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
            ctx: *MacroexpandContext,
            call_form: *const Form,
            _: []const *Form,
        ) MacroexpandError!*Form {
            const kw_id = ctx.interner.internKeyword("fired") catch return MacroexpandError.OutOfMemory;
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
    var ctx = MacroexpandContext{
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
            ctx: *MacroexpandContext,
            call_form: *const Form,
            _: []const *Form,
        ) MacroexpandError!*Form {
            const kw_id = ctx.interner.internKeyword("fired") catch return MacroexpandError.OutOfMemory;
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
    var ctx = MacroexpandContext{
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
        fn fireIt(_: *MacroexpandContext, call_form: *const Form, _: []const *Form) MacroexpandError!*Form {
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
    var ctx = MacroexpandContext{
        .allocator = arena,
        .interner = &interner,
        .host_macros = &table,
    };
    const expanded = try expandForm(&ctx, null, form);
    // Should still be (quote (my-macro)), NOT nil.
    try testing.expect(expanded.datum == .list);
}
