//! Macroexpander.
//!
//! See `docs/MACROEXPAND.md` for the full design contract;
//! this file implements §1 (execution model), §2b (per-form
//! traversal rules), §5 (syntax-quote), §6 (depth limit) and
//! §8 (error model).
//!
//! What this file does:
//!   - Defines `ExpandContext`, `MacroFn`, `HostMacroTable`,
//!     `ExpandEnv`, `ExpandError`.
//!   - Implements `expandForm`: per-form-rule walker that
//!     recognizes every special form, threads ExpandEnv
//!     through binding forms, and dispatches macro calls
//!     through the lexical env, the namespace's user macros
//!     and the host table (in that order). With an empty table
//!     and no namespace, the output is structurally identical
//!     to the input.
//!   - Provides the host core macros (`let`, `fn`, `defn`,
//!     `loop`, `when`, `and`, `or`, `cond`, `case`, `condp`,
//!     `for`, `->`, `->>`, `defrecord`, `defprotocol`,
//!     `extend-type`, `extend-protocol`) via `defaultMacros`.
//!   - Transforms syntax_quote / unquote / unquote_splicing into
//!     `#%list` / `#%concat` / `#%vector` / `#%map` / `#%set`
//!     construction forms with per-form auto-gensym scopes and
//!     Clojure-style symbol qualification.
//!   - Handles user `defmacro` through a compile-time eval
//!     callback and dispatches user-macro calls through a
//!     sub-VM.
//!   - Treats `quote` as OPAQUE (does not recurse into it).
//!   - Enforces a depth limit (256) and reports
//!     `MacroDepthExceeded` distinctly from
//!     `MacroExpansionFailure`.

const std = @import("std");
const reader_mod = @import("reader");
const intern_mod = @import("intern");
/// Needed for Namespace + Var lookup (user-defmacro dispatch),
/// Value construction (Form→Value conversion for macro args),
/// and the VM type referenced by the compile-eval callback type
/// signature. Importing vm pulls in champ + dispatch + vector +
/// heap + list transitively. No cycle: compile.zig imports
/// expand AND vm; vm doesn't import expand.
const vm_mod = @import("vm");
const value_mod = @import("value");
const list_mod = @import("list");
const vector_mod = @import("vector");
const champ_mod = @import("champ");
const heap_mod = @import("heap");
const bignum_mod = @import("bignum");

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

/// Per-spec MACROEXPAND.md §1: bundles every cross-cutting
/// resource a host MacroFn might need. Lives FOR THE LIFETIME
/// of a single compilation unit (typically one CLI invocation
/// or one test). Reusing across forms is how auto-gensym stays
/// monotonic within a unit.
pub const ExpandContext = struct {
    allocator: Allocator,
    interner: *intern_mod.Interner,
    /// Monotonic auto-gensym counter (MACROEXPAND.md §5: lives
    /// on the context, NOT the VM). Used by host macros that
    /// need to avoid double-evaluation (e.g. `or`).
    gensym_next: u64 = 0,
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

    /// Allocate a fresh gensym name in the context's arena.
    /// Format: `<base>__<counter>__auto__` per MACROEXPAND.md §4.
    /// The `__auto__` suffix marks auto-gensym.
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

/// One macro step, the way `macroexpand-1` sees it: when `form` is
/// a call whose head names a user or host macro (special forms and
/// the `#%` primitives are not macros), the macro's raw output;
/// otherwise null. Nothing inside the result is expanded and no
/// lexical environment applies: the form is top-level data.
pub fn expandOnce(ctx: *ExpandContext, form: *const Form) ExpandError!?*Form {
    if (form.datum != .list) return null;
    const items = form.datum.list;
    if (items.len == 0 or items[0].datum != .symbol) return null;
    const head = items[0].datum.symbol;
    if (head.ns) |ns_prefix| {
        if (qualifiedMacro(ctx, ns_prefix, head.name)) |user_var| {
            return try callUserMacro(ctx, user_var, form, items);
        }
        if (qualifiedHostMacro(ctx, ns_prefix, head.name)) |macro_fn| {
            return try macro_fn(ctx, form, items[1..]);
        }
        return null;
    }
    if (isSpecialFormName(head.name)) return null;
    if (ctx.namespace) |ns| {
        if (ns.lookup(head.name)) |user_var| {
            if (user_var.macro and user_var.bound) {
                return try callUserMacro(ctx, user_var, form, items);
            }
        }
    }
    if (ctx.host_macros.get(head.name)) |macro_fn| {
        return try macro_fn(ctx, form, items[1..]);
    }
    return null;
}

/// The heads `expandList` treats as special forms or internal
/// primitives: never macros, never shadowable.
fn isSpecialFormName(name: []const u8) bool {
    const names = [_][]const u8{
        "quote", "if", "do", "let*", "loop*", "recur", "fn*", "letfn*", "def", "var", "set!", "try", "throw", "defmacro", "ns", "require",
    };
    for (names) |n| if (std.mem.eql(u8, name, n)) return true;
    return std.mem.startsWith(u8, name, "#%");
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
        .nil, .bool_, .int, .bigint, .real, .char, .string, .keyword, .symbol => mutCast(form),
        // ---- Lists — special-form recognition + macro dispatch. --
        .list => |items| try expandList(ctx, env, form, items, depth),
        // Vector/map/set literals are expressions (lowerForm
        // builds runtime values via coll:vector / coll:map /
        // coll:set). Walk into each item so macros inside
        // collection literals expand.
        // NB: let*/loop*/fn*/letfn* binding vectors are handled
        // by their dedicated walkers (which do their own
        // per-form traversal); this arm catches top-level
        // collection-literal expressions.
        .vector => |items| try expandCollKind(ctx, env, form, items, depth, .vector_),
        .map => |items| try expandCollKind(ctx, env, form, items, depth, .map_),
        .set => |items| try expandCollKind(ctx, env, form, items, depth, .set_),
        // ---- Quote — OPAQUE per MACROEXPAND.md §2b. ----------
        // The expander does NOT recurse into the payload of a
        // quote form. `(quote (when x y))` MUST NOT expand
        // `when` — it's a literal symbol/list value.
        .quote => mutCast(form),
        // ---- Syntax-quote — transform per MACROEXPAND.md §5. --
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
        // Defensive error. The reader catches the source-syntax
        // case, but a macro host fn could synthesize one.
        .unquote, .unquote_splicing => return ExpandError.MalformedMacroCall,
        // ---- Reader macros / metadata. -----------------------
        // `#(...)` shorthand expands here. Reader emits
        // Datum.anon_fn carrying
        // the body forms; macroexpand scans for `%`, `%N`,
        // `%&` references, computes arity, and generates the
        // equivalent `(fn* [params] body...)` form. The
        // result is recursively re-expanded so macros nested
        // in the body still fire.
        .anon_fn => |items| try expandAnonFn(ctx, env, form, items, depth),
        // with_meta is metadata attached to a target form; it
        // passes through and the expander does not descend into
        // the target.
        .with_meta => mutCast(form),
        // deref `@x`: rewrite to QUALIFIED `(nexis.core/deref x)`.
        // The native `deref` is installed in `nexis.core` and
        // dispatches over `{durable_ref, var_, atom, …}` per
        // ATOM.md §5.
        //
        // The call is qualified through the auto-referred core
        // ns so that reader sugar cannot be captured by a
        // lexical binding (`(let [deref (fn [_] 42)] @a)` still
        // derefs `a`) or by a user-namespace `def deref ...`.
        // `db/deref` is also installed for explicit qualified
        // user code.
        .deref => |inner| blk: {
            const items = try ctx.allocator.alloc(*Form, 2);
            const deref_sym = try ctx.allocator.create(Form);
            deref_sym.* = .{
                .datum = .{ .symbol = .{ .ns = "nexis.core", .name = "deref" } },
                .origin = form.origin,
            };
            items[0] = deref_sym;
            items[1] = try expandFormDepth(ctx, env, inner, depth);
            const call = try makeList(ctx, items, form.origin);
            break :blk call;
        },
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

    // Qualified head (`alias/name` or `ns/name`): a macro Var in
    // that namespace expands; anything else is an ordinary call
    // resolved through the registry at compile time.
    if (head_sym.ns) |ns_prefix| {
        if (qualifiedMacro(ctx, ns_prefix, head_sym.name)) |user_var| {
            return try invokeUserMacro(ctx, env, user_var, list_form, items, depth);
        }
        if (qualifiedHostMacro(ctx, ns_prefix, head_sym.name)) |macro_fn| {
            return try invokeMacro(ctx, env, macro_fn, list_form, items, depth);
        }
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
    // `defn` is a HOST MACRO (expandDefnMacro) that rewrites to
    // `(def name (fn name ...))`. The host macro lives in the
    // macros table; dispatching here would bypass the macro
    // path.
    if (std.mem.eql(u8, name, "var")) return mutCast(list_form); // (var X) — X is just a name, don't expand
    if (std.mem.eql(u8, name, "set!")) return try expandSetBang(ctx, env, list_form, items, depth);
    if (std.mem.eql(u8, name, "try")) return try expandTry(ctx, env, list_form, items, depth);
    if (std.mem.eql(u8, name, "throw")) return try expandOrdinaryCall(ctx, env, list_form, items, depth);
    if (std.mem.eql(u8, name, "defmacro")) return try expandDefmacro(ctx, env, list_form, items, depth);
    if (std.mem.eql(u8, name, "ns")) return try expandNs(ctx, list_form, items);
    if (std.mem.eql(u8, name, "require")) return try expandRequire(ctx, list_form, items);
    // Internal compiler primitives (#%list / #%concat / ...).
    // Recognized as special forms — NOT user-shadowable, NOT
    // looked up in the macro table. Args ARE recursively
    // macroexpanded: a `(#%list (when x y))` expands `(when x y)`.
    if (std.mem.eql(u8, name, "#%list") or
        std.mem.eql(u8, name, "#%concat") or
        std.mem.eql(u8, name, "#%vector") or
        std.mem.eql(u8, name, "#%map") or
        std.mem.eql(u8, name, "#%set"))
    {
        return try expandOrdinaryCall(ctx, env, list_form, items, depth);
    }

    // ---- Macro dispatch (shadowable by lexical bindings). -----
    // Lookup order:
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

/// The macro Var a qualified head `ns/name` names, with `ns` an
/// alias of the current namespace or a namespace name; null when
/// the namespace is unknown or the Var is not a macro.
fn qualifiedMacro(ctx: *ExpandContext, ns_prefix: []const u8, name: []const u8) ?*vm_mod.Var {
    const reg = ctx.registry orelse return null;
    const target = reg.lookupNs(aliasTarget(ctx, ns_prefix)) orelse return null;
    const user_var = target.lookupLocal(name) orelse return null;
    return if (user_var.macro and user_var.bound) user_var else null;
}

/// The host macro a qualified head `nexis.core/name` names (the
/// prefix may be an alias of it); syntax-quote qualifies host
/// macros this way. Null for any other prefix or name.
fn qualifiedHostMacro(ctx: *ExpandContext, ns_prefix: []const u8, name: []const u8) ?MacroFn {
    if (!std.mem.eql(u8, aliasTarget(ctx, ns_prefix), "nexis.core")) return null;
    return ctx.host_macros.get(name);
}

/// The namespace name `ns_prefix` stands for: the target of an
/// alias registered in the current namespace, else itself.
fn aliasTarget(ctx: *ExpandContext, ns_prefix: []const u8) []const u8 {
    const cur = ctx.namespace orelse return ns_prefix;
    if (!cur.aliases_initialized) return ns_prefix;
    return cur.lookupAlias(ns_prefix) orelse ns_prefix;
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
    // The loop above only records changed items, so items that
    // came back unchanged after the first divergence are not in
    // `new_items`. Once ANY item changed, do a second pass that
    // copies every expansion.
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
            // Non-symbol params add nothing to the env; the `fn`
            // host macro replaces destructuring patterns with
            // gensyms before `fn*` is reached.
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
    // params). An entry is first put through the `fn` expander,
    // so overload clauses become one dispatching function and
    // destructuring patterns become plain params.
    const new_entries = try ctx.allocator.alloc(*Form, fn_entries.len);
    for (fn_entries, 0..) |entry, idx| {
        const entry_items = try normalizeLetFnEntry(ctx, entry);
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

/// A `letfn*` entry `(name params-or-clauses body...)` as `(name
/// [params] body...)`: `expandFnRename` on `(fn name ...)` lowers
/// overload clauses and destructuring, and the entry keeps its
/// name with the resulting param vector and body.
fn normalizeLetFnEntry(ctx: *ExpandContext, entry: *const Form) ExpandError![]const *Form {
    const entry_items = entry.datum.list;
    var fn_form = try expandFnRename(ctx, entry, entry_items);
    // Overload clauses come back as `(fn name [& args] body)`;
    // one more pass renames that to `fn*`.
    if (std.mem.eql(u8, fn_form.datum.list[0].datum.symbol.name, "fn")) {
        fn_form = try expandFnRename(ctx, entry, fn_form.datum.list[1..]);
    }
    return fn_form.datum.list[1..];
}

// ---- def / defn -----------------------------------------------------------

fn expandDef(
    ctx: *ExpandContext,
    env: ?*const ExpandEnv,
    list_form: *const Form,
    items: []const *Form,
    depth: u32,
) ExpandError!*Form {
    // (def name) | (def name value) | (def name "doc" value); the
    // name may carry `^meta`, which lands on the Var.
    if (items.len < 2 or items.len > 4) return ExpandError.MalformedMacroCall;
    const head = items[0];
    const named = try splitMetaName(items[1]);
    const name_form = named.name;
    var meta_items: std.ArrayList(*Form) = .empty;
    defer meta_items.deinit(ctx.allocator);
    if (named.meta) |m| try meta_items.appendSlice(ctx.allocator, m);
    var value_idx: usize = 2;
    if (items.len == 4) {
        if (items[2].datum != .string) return ExpandError.MalformedMacroCall;
        try meta_items.append(ctx.allocator, try makeKeyword(ctx, "doc", items[2].origin));
        try meta_items.append(ctx.allocator, mutCast(items[2]));
        value_idx = 3;
    }
    if (meta_items.items.len == 0 and named.meta == null and items.len < 4) {
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
    var def_items: std.ArrayList(*Form) = .empty;
    defer def_items.deinit(ctx.allocator);
    try def_items.append(ctx.allocator, mutCast(head));
    try def_items.append(ctx.allocator, mutCast(name_form));
    if (value_idx < items.len) try def_items.append(ctx.allocator, try expandFormDepth(ctx, env, items[value_idx], depth));
    const def_form = try makeListInline(ctx, list_form.origin, def_items.items);
    return try withVarMeta(ctx, def_form, meta_items.items, list_form.origin);
}

/// A definition's name form split into the symbol and the entries
/// of any `^meta` it carries (`^:private f` reads as `{:private
/// true}`); a name that is neither is malformed.
fn splitMetaName(form: *const Form) ExpandError!struct { name: *const Form, meta: ?[]const *Form } {
    switch (form.datum) {
        .symbol => |sym| {
            if (sym.ns != null) return ExpandError.MalformedMacroCall;
            return .{ .name = form, .meta = null };
        },
        .with_meta => |wm| {
            if (wm.target.datum != .symbol or wm.target.datum.symbol.ns != null) return ExpandError.MalformedMacroCall;
            if (wm.meta.datum != .map) return ExpandError.MalformedMacroCall;
            return .{ .name = wm.target, .meta = wm.meta.datum.map };
        },
        else => return ExpandError.MalformedMacroCall,
    }
}

/// `def_form` (a `def`, which yields its Var) wrapped so the Var
/// then carries the map built from `meta_items` (flat k v ...):
///   (let* [v# def_form] (nexis.core/reset-meta! v# {k v ...}) v#)
/// No items: `def_form` itself.
fn withVarMeta(ctx: *ExpandContext, def_form: *Form, meta_items: []const *Form, origin: reader_mod.SrcSpan) ExpandError!*Form {
    if (meta_items.len == 0) return def_form;
    const v_sym = try genTempSym(ctx, origin);
    const map_form = try ctx.allocator.create(Form);
    const map_items = try ctx.allocator.alloc(*Form, meta_items.len);
    for (meta_items, 0..) |it, i| map_items[i] = mutCast(it);
    map_form.* = .{ .datum = .{ .map = @as([]const *Form, map_items) }, .origin = origin };
    const reset_call = try makeListInline(ctx, origin, &.{ try makeQualifiedSymbol(ctx, "nexis.core", "reset-meta!", origin), v_sym, map_form });
    const bindings = try ctx.allocator.alloc(*Form, 2);
    bindings[0] = v_sym;
    bindings[1] = def_form;
    return try makeListInline(ctx, origin, &.{ try makeSymbol(ctx, "let*", origin), try makeVector(ctx, bindings, origin), reset_call, v_sym });
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
/// A MATCHER is `any` (every value, no test) or a keyword TAG,
/// which matches a thrown value equal to TAG or a map whose
/// `:error` entry is TAG: the shape Nextomic's error maps and the
/// no-matching-clause map already have. Clauses are tried in
/// order; a value no clause matches is rethrown, so it unwinds
/// through the `finally` to the enclosing `try`. With no clause at
/// all the handler is the rethrow, which is finally-only `try`;
/// with neither catch nor finally the form is `(do body...)`.
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
    const head = items[0];
    const origin = list_form.origin;

    // Partition: body forms, then catch clauses, then an optional
    // finally. Clojure's order; anything else is malformed.
    var end = items.len;
    var finally_form: ?*Form = null;
    if (end > 1 and isClauseHead(items[end - 1], "finally")) {
        finally_form = mutCast(items[end - 1]);
        end -= 1;
    }
    var catch_start = end;
    while (catch_start > 1 and isClauseHead(items[catch_start - 1], "catch")) catch_start -= 1;
    const body = items[1..catch_start];
    const catches = items[catch_start..end];
    for (body) |b| if (isClauseHead(b, "catch") or isClauseHead(b, "finally")) return ExpandError.MalformedMacroCall;

    var out_items: std.ArrayList(*Form) = .empty;
    defer out_items.deinit(ctx.allocator);

    if (catches.len == 0 and finally_form == null) {
        try out_items.append(ctx.allocator, try makeSymbol(ctx, "do", origin));
        for (body) |b| try out_items.append(ctx.allocator, try expandFormDepth(ctx, env, b, depth));
        return try makeListInline(ctx, origin, out_items.items);
    }

    try out_items.append(ctx.allocator, mutCast(head));
    for (body) |b| try out_items.append(ctx.allocator, try expandFormDepth(ctx, env, b, depth));

    // The single primitive catch binds g; its handler is the
    // clause chain ending in a rethrow.
    const g_name = try ctx.gensym("caught");
    var handler: *Form = try makeListInline(ctx, origin, &.{ try makeSymbol(ctx, "throw", origin), try makeSymbol(ctx, g_name, origin) });
    var i: usize = catches.len;
    while (i > 0) {
        i -= 1;
        const ci = catches[i].datum.list;
        if (ci.len < 3) return ExpandError.MalformedMacroCall;
        const matcher = ci[1];
        const binding = ci[2];
        if (binding.datum != .symbol or binding.datum.symbol.ns != null) return ExpandError.MalformedMacroCall;

        var handler_env: ExpandEnv = .{ .parent = env };
        defer handler_env.deinit(ctx.allocator);
        _ = try handler_env.lexical_names.getOrPut(ctx.allocator, binding.datum.symbol.name);
        // (let* [binding g] handler...)
        var let_items: std.ArrayList(*Form) = .empty;
        defer let_items.deinit(ctx.allocator);
        try let_items.append(ctx.allocator, try makeSymbol(ctx, "let*", origin));
        const bind_items = try ctx.allocator.alloc(*Form, 2);
        bind_items[0] = mutCast(binding);
        bind_items[1] = try makeSymbol(ctx, g_name, origin);
        try let_items.append(ctx.allocator, try makeVector(ctx, bind_items, origin));
        for (ci[3..]) |h| try let_items.append(ctx.allocator, try expandFormDepth(ctx, &handler_env, h, depth));
        const clause_body = try makeListInline(ctx, origin, let_items.items);

        const is_any = matcher.datum == .symbol and matcher.datum.symbol.ns == null and std.mem.eql(u8, matcher.datum.symbol.name, "any");
        if (is_any) {
            handler = clause_body;
            continue;
        }
        if (matcher.datum != .keyword) return ExpandError.MalformedMacroCall;
        const test_form = try makeListInline(ctx, origin, &.{
            try makeQualifiedSymbol(ctx, "nexis.internal", "#%catch-matches?", origin),
            try makeSymbol(ctx, g_name, origin),
            mutCast(matcher),
        });
        handler = try makeListInline(ctx, origin, &.{ try makeSymbol(ctx, "if", origin), test_form, clause_body, handler });
    }
    try out_items.append(ctx.allocator, try makeListInline(ctx, origin, &.{
        try makeSymbol(ctx, "catch", origin),
        try makeSymbol(ctx, "any", origin),
        try makeSymbol(ctx, g_name, origin),
        handler,
    }));

    if (finally_form) |ff| {
        const fi = ff.datum.list;
        var new_finally_items: std.ArrayList(*Form) = .empty;
        defer new_finally_items.deinit(ctx.allocator);
        try new_finally_items.append(ctx.allocator, mutCast(fi[0]));
        for (fi[1..]) |f| try new_finally_items.append(ctx.allocator, try expandFormDepth(ctx, env, f, depth));
        try out_items.append(ctx.allocator, try makeListInline(ctx, ff.origin, new_finally_items.items));
    }
    return try makeListInline(ctx, origin, out_items.items);
}

/// Expand `#(body...)` shorthand.
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
    const fn_form = try anonFnForm(ctx, call_form, items);
    // Recursively re-expand so any macros nested in body fire.
    return try expandFormDepth(ctx, env, fn_form, depth);
}

/// The `(fn* [%1 ...] (body...))` form a `#(body...)` literal
/// stands for, built syntactically and not yet expanded. Shared by
/// the expander and by macro-argument conversion, so a `#()` inside
/// a user macro's body reaches the macro as an ordinary `fn*` form.
fn anonFnForm(
    ctx: *ExpandContext,
    call_form: *const Form,
    items: []const *Form,
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
    return try makeList(ctx, out_items, call_form.origin);
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

/// Discriminator for `expandCollKind`.
const CollKind = enum { vector_, map_, set_ };

/// Walk a vector/map/set literal's items + rebuild
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
// User-defined defmacro
// =============================================================================
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
// User-macro INVOCATION:
//   1. Convert each arg Form → Value via `formToValue`.
//   2. Call `VM.evalClosure(var.root, arg_values, &sub_vm, interner,
//      heap)`; the sub-VM borrows the compile-time interner so names
//      in its arguments resolve, and the calling VM's heap when the
//      context has one.
//   3. Convert returned Value → Form via `valueToForm` in
//      `ctx.allocator` (the compile arena).
//   4. Deinit the sub-VM.
//   5. Recursively re-expand the resulting Form (so macros
//      in the macro output expand).
//
// Macro args are UNEVALUATED Forms-as-Values; the macro body
// inspects them as data (lists, symbols, etc.) with natives
// such as `first`/`rest`/`cons` and builds output via
// syntax-quote.

/// Expand `(ns NAME)`. Switches
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

/// Expand `(require ...)`. Supported forms:
///
///   (require 'my.ns)              ; load my.ns; no alias
///   (require '[my.ns :as alias])  ; load my.ns + alias `alias` → my.ns
///
/// The side effect (file load + registry update + alias entry)
/// happens at EXPANSION TIME via `ctx.load_callback`. The
/// replacement form is `nil` (there is no runtime work left).
/// Both forms accept `:as` only — `:refer` / `:rename` /
/// `:exclude` are unsupported and raise MalformedMacroCall.
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
                cb.load(cb.user_data, sym.name) catch |err| return loadFailure(err);
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
                        // :refer / :rename / :exclude are unsupported.
                        return ExpandError.MalformedMacroCall;
                    }
                }
                cb.load(cb.user_data, ns_name) catch |err| return loadFailure(err);
                if (alias_name) |an| {
                    reg.current.putAlias(an, ns_name) catch return ExpandError.OutOfMemory;
                }
            },
            else => return ExpandError.MalformedMacroCall,
        }
    }
    return try makeNil(ctx, list_form.origin);
}

/// What a load callback's failure means to the expander: the two
/// signals of a file that ran and failed pass through under their
/// own names; a file that could not be found, read or compiled is
/// a malformed `require`.
fn loadFailure(err: anyerror) ExpandError {
    return switch (err) {
        error.OutOfMemory => ExpandError.OutOfMemory,
        error.RunFailed => ExpandError.RequiredFileFailed,
        error.ControlTransferred => ExpandError.ControlTransferred,
        else => ExpandError.MalformedMacroCall,
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
    depth: u32,
) ExpandError!*Form {
    if (items.len != 3) return ExpandError.MalformedMacroCall;
    const target = items[1];
    if (target.datum != .symbol) return ExpandError.MalformedMacroCall;
    if (target.datum.symbol.ns == null) {
        if (env) |e| if (e.contains(target.datum.symbol.name)) return ExpandError.MalformedMacroCall;
    }
    const origin = list_form.origin;
    const var_items = try ctx.allocator.alloc(*Form, 2);
    var_items[0] = try makeSymbol(ctx, "var", origin);
    var_items[1] = mutCast(target);
    const out_items = try ctx.allocator.alloc(*Form, 3);
    out_items[0] = try makeQualifiedSymbol(ctx, "nexis.core", "var-set", origin);
    out_items[1] = try makeList(ctx, var_items, origin);
    out_items[2] = try expandFormDepth(ctx, env, items[2], depth + 1);
    return try makeList(ctx, out_items, origin);
}

/// Expand `(defmacro name [params] body)`.
fn expandDefmacro(
    ctx: *ExpandContext,
    env: ?*const ExpandEnv,
    list_form: *const Form,
    items: []const *Form,
    depth: u32,
) ExpandError!*Form {
    // (defmacro NAME "doc"? [PARAMS] BODY...); `^meta` on NAME and
    // the docstring land on the Var like defn's.
    if (items.len < 3) return ExpandError.MalformedMacroCall;
    const named = try splitMetaName(items[1]);
    const name_form = named.name;
    var meta_items: std.ArrayList(*Form) = .empty;
    defer meta_items.deinit(ctx.allocator);
    if (named.meta) |m| try meta_items.appendSlice(ctx.allocator, m);
    var params_idx: usize = 2;
    if (items[2].datum == .string) {
        try meta_items.append(ctx.allocator, try makeKeyword(ctx, "doc", items[2].origin));
        try meta_items.append(ctx.allocator, mutCast(items[2]));
        params_idx = 3;
    }
    if (params_idx >= items.len) return ExpandError.MalformedMacroCall;
    const params_form = items[params_idx];
    if (params_form.datum != .vector) return ExpandError.MalformedMacroCall;
    const body_forms = items[params_idx + 1 ..];

    // Need both a namespace (to mark the Var) and a compile-
    // eval callback (to compile+run the synthetic def form).
    const ns = ctx.namespace orelse return ExpandError.MalformedMacroCall;
    const ceval = ctx.compile_eval orelse return ExpandError.MalformedMacroCall;

    // First: macroexpand the body BEFORE compiling it. Body
    // env includes the self-name + params.
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
    // CRITICAL: we INTENTIONALLY LEAK the sub-VM here. The
    // macro fn's Closure is allocated in the sub-VM's
    // `runtime_arena`, which is backed by the caller's
    // persistent allocator. `ArenaAllocator.free` RECLAIMS the
    // most-recent allocation, so `sub_vm.deinit()` would
    // invalidate the Closure pointer stored in `Var.root`
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
    if (meta_items.items.len > 0) {
        target_var.meta = formToValue(ctx, blk: {
            const map_form = try ctx.allocator.create(Form);
            const map_items = try ctx.allocator.alloc(*Form, meta_items.items.len);
            for (meta_items.items, 0..) |it, i| map_items[i] = it;
            map_form.* = .{ .datum = .{ .map = @as([]const *Form, map_items) }, .origin = list_form.origin };
            break :blk map_form;
        }) catch return ExpandError.MalformedMacroCall;
    }

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

/// Invoke a user-defined macro.
fn invokeUserMacro(
    ctx: *ExpandContext,
    env: ?*const ExpandEnv,
    macro_var: *vm_mod.Var,
    call_form: *const Form,
    items: []const *Form,
    depth: u32,
) ExpandError!*Form {
    const result_form = try callUserMacro(ctx, macro_var, call_form, items);
    // Recursively re-expand the result (macros in the macro
    // output get expanded).
    return try expandFormDepth(ctx, env, result_form, depth + 1);
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

    // Convert each arg Form → Value (unevaluated, as data).
    const arg_values = ctx.allocator.alloc(value_mod.Value, args.len) catch return ExpandError.OutOfMemory;
    defer ctx.allocator.free(arg_values);
    for (args, 0..) |a, i| {
        arg_values[i] = formToValue(ctx, a) catch return ExpandError.MalformedMacroCall;
    }

    // Invoke in a fresh sub-VM that allocates on the calling VM's
    // heap when the context knows it (`heapForArgs`), so a value
    // the macro stores into a Var outlives the call; otherwise the
    // sub-VM's own heap holds the macro fn's runtime state and the
    // result is converted to a Form (in ctx.allocator) BEFORE
    // deinit.
    var sub_vm: vm_mod.VM = undefined;
    var sub_vm_ready = false;
    defer if (sub_vm_ready) sub_vm.deinit();
    const result_value = vm_mod.VM.evalClosure(
        ctx.allocator,
        macro_var.root,
        arg_values,
        &sub_vm,
        ctx.interner,
        ctx.value_heap,
    ) catch {
        return ExpandError.MalformedMacroCall;
    };
    sub_vm_ready = true;

    // Convert result Value → Form.
    return valueToForm(ctx, result_value, call_form.origin) catch return ExpandError.MalformedMacroCall;
}

/// Convert a `Form` to its runtime Value representation. Used
/// to pass macro args as unevaluated data. Supports the data
/// shapes a macro typically inspects.
///
/// Mapping:
///   nil/bool/int/real/char → corresponding immediate
///   string         → heap string
///   keyword/symbol → interned Value
///   list           → cons list of recursively-converted items
///   vector         → persistent vector
///   map            → persistent map (flat k,v,k,v items)
///   set            → persistent set
///   quote          → `(quote payload-value)` as a 2-element list
///   deref          → `(deref payload-value)` as a 2-element list
///   anon_fn        → the `fn*` form it stands for
/// syntax_quote, unquote, unquote_splicing and with_meta raise
/// `MalformedMacroCall`.
pub fn formToValue(ctx: *ExpandContext, form: *const Form) !value_mod.Value {
    return switch (form.datum) {
        .nil => value_mod.nilValue(),
        .bool_ => |b| value_mod.fromBool(b),
        .int => |n| value_mod.fromFixnum(n) orelse
            (bignum_mod.fromI64(try ctx.heapForArgs(), n) catch return ExpandError.OutOfMemory),
        .bigint => |text| blk: {
            const parsed = bignum_mod.parseDecimal(try ctx.heapForArgs(), text) catch return ExpandError.OutOfMemory;
            break :blk parsed orelse return ExpandError.MalformedMacroCall;
        },
        .symbol => |name| blk: {
            // Qualified symbols intern the full `ns/name`
            // string; valueToForm splits it back into
            // ns + name on the way out. Required for macros that
            // receive a body containing qualified calls (e.g.,
            // `(with-tx [tx conn] (db/put! tx ref v))`).
            if (name.ns) |ns_prefix| {
                const full = std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ ns_prefix, name.name }) catch return ExpandError.OutOfMemory;
                defer ctx.allocator.free(full);
                const id = ctx.interner.internSymbol(full) catch return ExpandError.OutOfMemory;
                break :blk value_mod.fromSymbolId(id);
            }
            const id = ctx.interner.internSymbol(name.name) catch return ExpandError.OutOfMemory;
            break :blk value_mod.fromSymbolId(id);
        },
        .keyword => |name| ctx.interner.internQualifiedKeyword(name.ns, name.name) catch return ExpandError.OutOfMemory,
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
        // String literals reach the macro layer via
        // syntax-quote payloads and direct
        // arguments to host macros (e.g. `with-tx`'s body forms
        // can be arbitrary Forms containing `(db/put! tx r "x")`).
        // Allocate the heap string in the same arena
        // (`ctx.heapForArgs()`) the rest of formToValue uses for
        // collections.
        .string => |bytes| blk: {
            const string_mod_local = @import("string");
            const heap = try ctx.heapForArgs();
            break :blk string_mod_local.fromBytes(heap, bytes) catch return ExpandError.OutOfMemory;
        },
        .real => |f| value_mod.fromFloat(f),
        .char => |c| value_mod.fromChar(c) orelse return ExpandError.MalformedMacroCall,
        // `@x` reaches a macro as the call `(deref x)`.
        .deref => |inner| blk: {
            const deref_id = ctx.interner.internSymbol("deref") catch return ExpandError.OutOfMemory;
            const inner_v = try formToValue(ctx, inner);
            const heap = try ctx.heapForArgs();
            var lst = list_mod.empty(heap) catch return ExpandError.OutOfMemory;
            lst = list_mod.cons(heap, inner_v, lst) catch return ExpandError.OutOfMemory;
            lst = list_mod.cons(heap, value_mod.fromSymbolId(deref_id), lst) catch return ExpandError.OutOfMemory;
            break :blk lst;
        },
        // `#(...)` reaches a macro as the `fn*` form it stands for.
        .anon_fn => |items| try formToValue(ctx, try anonFnForm(ctx, form, items)),
        // syntax_quote, unquote, unquote_splicing, with_meta →
        // MalformedMacroCall.
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
/// span — typically the macro call site (generated forms use
/// the macro call origin).
pub fn valueToForm(ctx: *ExpandContext, v: value_mod.Value, origin: reader_mod.SrcSpan) !*Form {
    return switch (v.kind()) {
        .nil => try makeNil(ctx, origin),
        .true_ => try makeBool(ctx, true, origin),
        .false_ => try makeBool(ctx, false, origin),
        .fixnum => blk: {
            const form = try ctx.allocator.create(Form);
            form.* = .{ .datum = .{ .int = v.asFixnum() }, .origin = origin };
            break :blk form;
        },
        // A bignum within i64 is an `int` like any other integer of
        // that size; beyond i64 it is a `bigint` in decimal.
        .bignum => blk: {
            const form = try ctx.allocator.create(Form);
            if (bignum_mod.toI64(v)) |n| {
                form.* = .{ .datum = .{ .int = n }, .origin = origin };
            } else {
                var w = std.Io.Writer.Allocating.init(ctx.allocator);
                defer w.deinit();
                bignum_mod.formatDecimal(v, &w.writer) catch return ExpandError.OutOfMemory;
                form.* = .{ .datum = .{ .bigint = try ctx.allocator.dupe(u8, w.written()) }, .origin = origin };
            }
            break :blk form;
        },
        .float => blk: {
            const form = try ctx.allocator.create(Form);
            form.* = .{ .datum = .{ .real = v.asFloat() }, .origin = origin };
            break :blk form;
        },
        .char => blk: {
            const form = try ctx.allocator.create(Form);
            form.* = .{ .datum = .{ .char = v.asChar() }, .origin = origin };
            break :blk form;
        },
        .symbol => blk: {
            // The interner stores the full `ns/name` text.
            const id: u32 = @intCast(v.payload);
            const parts = intern_mod.Interner.splitQualified(ctx.interner.symbolName(id));
            const form = try ctx.allocator.create(Form);
            form.* = .{
                .datum = .{ .symbol = .{ .ns = parts.ns, .name = parts.name } },
                .origin = origin,
            };
            break :blk form;
        },
        .keyword => blk: {
            const id: u32 = @intCast(v.payload);
            const parts = intern_mod.Interner.splitQualified(ctx.interner.keywordName(id));
            const form = try ctx.allocator.create(Form);
            form.* = .{
                .datum = .{ .keyword = .{ .ns = parts.ns, .name = parts.name } },
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
        // Macro-returned string Values surface as
        // `Form.datum.string` byte slices. The
        // reader produces string Forms with already-decoded bytes
        // (escapes resolved); macro round-trip mirrors that
        // shape. The byte slice is copied into the macro arena
        // (`ctx.allocator`) so it outlives the source Value.
        .string => blk: {
            const string_mod_local = @import("string");
            const src_bytes = string_mod_local.asBytes(v);
            const owned = try ctx.allocator.dupe(u8, src_bytes);
            const form = try ctx.allocator.create(Form);
            form.* = .{ .datum = .{ .string = owned }, .origin = origin };
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
// Every helper takes an `origin: SrcSpan` parameter. Per §4b,
// synthetic forms get the macro CALL site's origin so that
// error messages can say "in macro expansion of WHEN at line
// 5". Macros typically pass
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
/// resulting Form's). Always unqualified; `makeQualifiedSymbol`
/// builds `ns/name` forms.
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
//     `invokeMacro`), so macro-of-macros termination is
//     automatic.

// ---- Rename macros (CLOJURE-REVIEW.md §1.1 primitive `*`) ----
//
// These exist because user-facing `let`/`fn`/`loop` are
// macros over the compiler primitives `let*`/`fn*`/`loop*`.
// `let` and `fn` also rewrite destructuring patterns; `loop`
// is a bare rename.

/// Expand `(let bindings body...)` with destructuring support. The bindings vector may contain
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

/// Expand `(fn ...)` with destructuring in params.
/// Supports `(fn [params] body)`, `(fn name [params] body)` and
/// the overload form `(fn name? ([p1] b1) ([p1 p2] b2) ...)`, which
/// lowers through `buildMultiArityFn` to one variadic function
/// dispatching on argument count. Destructured params are
/// replaced with gensyms; the body is wrapped in a `(let [pattern
/// gensym ...] body)` that itself expands via destructuring.
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
    if (params_form.datum == .list) {
        return try buildMultiArityFn(ctx, call_form, if (name_form) |n| n else null, args[params_idx..]);
    }
    if (params_form.datum != .vector) return ExpandError.MalformedMacroCall;
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
            // After `&` — the rest param. If pattern, destructure;
            // a map pattern takes keyword arguments.
            if (p.datum == .symbol) {
                try new_params.append(ctx.allocator, @constCast(p));
            } else {
                const tmp = try genTempSym(ctx, call_form.origin);
                try new_params.append(ctx.allocator, tmp);
                try destruct_bindings.append(ctx.allocator, @constCast(p));
                try destruct_bindings.append(ctx.allocator, try restSourceFor(ctx, p, tmp, call_form.origin));
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

/// `(defn name [params] body...)` → `(def name
/// (fn name [params] body...))`. Routing defn through `fn`
/// gives us destructured params for free. The overload form
/// `(defn name ([p1] b1) ([p1 p2] b2))` is `(def name <fn>)` with
/// the dispatcher `buildMultiArityFn` builds.
fn expandDefnMacro(
    ctx: *ExpandContext,
    call_form: *const Form,
    args: []const *Form,
) ExpandError!*Form {
    if (args.len < 2) return ExpandError.MalformedMacroCall;
    const named = try splitMetaName(args[0]);
    const name_form = named.name;
    const origin = call_form.origin;

    // Optional docstring, then optional attribute map, before the
    // params or clauses. Together with `^meta` on the name they
    // become the Var's metadata, with `:arglists` added.
    var meta_items: std.ArrayList(*Form) = .empty;
    defer meta_items.deinit(ctx.allocator);
    if (named.meta) |m| try meta_items.appendSlice(ctx.allocator, m);
    var rest: usize = 1;
    if (rest < args.len and args[rest].datum == .string) {
        try meta_items.append(ctx.allocator, try makeKeyword(ctx, "doc", args[rest].origin));
        try meta_items.append(ctx.allocator, mutCast(args[rest]));
        rest += 1;
    }
    if (rest < args.len and args[rest].datum == .map) {
        try meta_items.appendSlice(ctx.allocator, args[rest].datum.map);
        rest += 1;
    }
    if (rest >= args.len) return ExpandError.MalformedMacroCall;
    const fn_args = args[rest..];

    // Detect single-arity vs multi-arity:
    //   single: fn_args[0] is vector (params)
    //   multi:  fn_args are lists each shaped (params body...)
    const def_form = if (fn_args[0].datum == .vector)
        try buildDefSingleFn(ctx, call_form, name_form, fn_args)
    else
        try buildDefMultiFn(ctx, call_form, name_form, fn_args);
    if (meta_items.items.len == 0) return def_form;

    // :arglists (quote ([params] ...))
    var lists: std.ArrayList(*Form) = .empty;
    defer lists.deinit(ctx.allocator);
    if (fn_args[0].datum == .vector) {
        try lists.append(ctx.allocator, mutCast(fn_args[0]));
    } else for (fn_args) |clause| {
        if (clause.datum != .list or clause.datum.list.len == 0) return ExpandError.MalformedMacroCall;
        try lists.append(ctx.allocator, mutCast(clause.datum.list[0]));
    }
    try meta_items.append(ctx.allocator, try makeKeyword(ctx, "arglists", origin));
    try meta_items.append(ctx.allocator, try makeListInline(ctx, origin, &.{ try makeSymbol(ctx, "quote", origin), try makeListInline(ctx, origin, lists.items) }));
    return try withVarMeta(ctx, def_form, meta_items.items, origin);
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

fn buildDefMultiFn(
    ctx: *ExpandContext,
    call_form: *const Form,
    name_form: *const Form,
    arity_forms: []const *Form,
) ExpandError!*Form {
    const fn_form = try buildMultiArityFn(ctx, call_form, name_form, arity_forms);
    return try buildDefForm(ctx, call_form, name_form, fn_form);
}

/// Overload clauses `([params] body...)+` of `fn`, `defn` or a
/// `letfn` binding lowered to one variadic function dispatching
/// on argument count:
///   (fn name? [& args__auto__]
///     (let* [n__auto__ (count args__auto__)]
///       (if (= n__auto__ 1) (loop [p1 (nth args__auto__ 0)] b1)
///       (if (= n__auto__ 2) (loop [p1 (nth args__auto__ 0)
///                                  p2 (nth args__auto__ 1)] b2)
///       (if (not (< n__auto__ k)) (loop [... rest (rest ...)] bv)
///       (throw :arity-mismatch))))))
/// Fixed arities are tested in source order and the variadic
/// clause last, so an exact arity always wins over the variadic
/// one. At most one variadic clause; its fixed count must not be
/// below any fixed arity, and no fixed arity repeats (Clojure's
/// rules). Each clause binds through `loop`, so its params
/// destructure and a `recur` in the clause's tail re-enters that
/// clause with the clause's own arity (a variadic clause's rest
/// parameter receives one seq), without touching the dispatch.
fn buildMultiArityFn(
    ctx: *ExpandContext,
    call_form: *const Form,
    name_form: ?*const Form,
    arity_forms: []const *Form,
) ExpandError!*Form {
    const ArityInfo = struct {
        fixed: usize,
        variadic: bool,
        params: *const Form,
        body: []const *Form,
    };
    var arities: std.ArrayList(ArityInfo) = .empty;
    defer arities.deinit(ctx.allocator);
    var variadic: ?ArityInfo = null;
    var max_fixed: usize = 0;

    if (arity_forms.len == 0) return ExpandError.MalformedMacroCall;
    for (arity_forms) |af| {
        if (af.datum != .list) return ExpandError.MalformedMacroCall;
        const items = af.datum.list;
        if (items.len < 1) return ExpandError.MalformedMacroCall;
        const params_form = items[0];
        if (params_form.datum != .vector) return ExpandError.MalformedMacroCall;
        const params = params_form.datum.vector;
        var fixed_count: usize = 0;
        var is_variadic = false;
        for (params) |p| {
            if (p.datum == .symbol and p.datum.symbol.ns == null and std.mem.eql(u8, p.datum.symbol.name, "&")) {
                is_variadic = true;
                break;
            }
            fixed_count += 1;
        }
        const info: ArityInfo = .{
            .fixed = fixed_count,
            .variadic = is_variadic,
            .params = params_form,
            .body = items[1..],
        };
        if (is_variadic) {
            if (variadic != null) return ExpandError.MalformedMacroCall;
            variadic = info;
        } else {
            for (arities.items) |a| {
                if (a.fixed == fixed_count) return ExpandError.MalformedMacroCall;
            }
            if (fixed_count > max_fixed) max_fixed = fixed_count;
            try arities.append(ctx.allocator, info);
        }
    }
    if (variadic) |v| {
        if (v.fixed < max_fixed) return ExpandError.MalformedMacroCall;
    }

    const args_sym = try genTempSym(ctx, call_form.origin);
    const n_sym = try genTempSym(ctx, call_form.origin);

    // Innermost: the variadic clause when present, else the throw;
    // then the fixed clauses wrap it in reverse so source order
    // is tested first.
    var current_else: *Form = try buildThrowArity(ctx, call_form.origin);
    if (variadic) |v| {
        current_else = try buildArityBranch(ctx, call_form.origin, args_sym, n_sym, v.params.datum.vector, v.fixed, true, v.body, current_else);
    }
    var i: usize = arities.items.len;
    while (i > 0) {
        i -= 1;
        const a = arities.items[i];
        current_else = try buildArityBranch(ctx, call_form.origin, args_sym, n_sym, a.params.datum.vector, a.fixed, false, a.body, current_else);
    }

    // (let* [n_sym (count args_sym)] current_else)
    const count_items = try ctx.allocator.alloc(*Form, 2);
    count_items[0] = try coreSym(ctx, "count", call_form.origin);
    count_items[1] = args_sym;
    const let_bindings = try ctx.allocator.alloc(*Form, 2);
    let_bindings[0] = n_sym;
    let_bindings[1] = try makeList(ctx, count_items, call_form.origin);
    const let_items = try ctx.allocator.alloc(*Form, 3);
    let_items[0] = try makeSymbol(ctx, "let*", call_form.origin);
    let_items[1] = try makeVector(ctx, let_bindings, call_form.origin);
    let_items[2] = current_else;
    const let_form = try makeList(ctx, let_items, call_form.origin);

    // (fn name? [& args_sym] let_form)
    const fn_params_items = try ctx.allocator.alloc(*Form, 2);
    fn_params_items[0] = try makeSymbol(ctx, "&", call_form.origin);
    fn_params_items[1] = args_sym;
    const fn_params_vec = try makeVector(ctx, fn_params_items, call_form.origin);
    const fn_len: usize = if (name_form != null) 4 else 3;
    const fn_items = try ctx.allocator.alloc(*Form, fn_len);
    fn_items[0] = try makeSymbol(ctx, "fn", call_form.origin);
    var idx: usize = 1;
    if (name_form) |n| {
        fn_items[idx] = @constCast(n);
        idx += 1;
    }
    fn_items[idx] = fn_params_vec;
    fn_items[idx + 1] = let_form;
    return try makeList(ctx, fn_items, call_form.origin);
}

/// `(if <argc test> <clause body over its params> else_form)` for
/// one overload clause.
fn buildArityBranch(
    ctx: *ExpandContext,
    origin: reader_mod.SrcSpan,
    args_sym: *Form,
    n_sym: *Form,
    params: []const *Form,
    fixed: usize,
    variadic: bool,
    body: []const *Form,
    else_form: *Form,
) ExpandError!*Form {
    const then_form = try buildArityThen(ctx, origin, args_sym, params, fixed, variadic, body);
    const cond_form = if (variadic)
        try buildVariadicCondition(ctx, origin, n_sym, fixed)
    else
        try buildFixedCondition(ctx, origin, n_sym, fixed);
    const if_items = try ctx.allocator.alloc(*Form, 4);
    if_items[0] = try makeSymbol(ctx, "if", origin);
    if_items[1] = cond_form;
    if_items[2] = then_form;
    if_items[3] = else_form;
    return try makeList(ctx, if_items, origin);
}

fn buildThrowArity(ctx: *ExpandContext, origin: reader_mod.SrcSpan) ExpandError!*Form {
    const items = try ctx.allocator.alloc(*Form, 2);
    items[0] = try makeSymbol(ctx, "throw", origin);
    items[1] = try makeKeyword(ctx, "arity-mismatch", origin);
    return try makeList(ctx, items, origin);
}

fn buildFixedCondition(ctx: *ExpandContext, origin: reader_mod.SrcSpan, n_sym: *Form, k: usize) ExpandError!*Form {
    const items = try ctx.allocator.alloc(*Form, 3);
    items[0] = try coreSym(ctx, "=", origin);
    items[1] = n_sym;
    const k_form = try ctx.allocator.create(Form);
    k_form.* = .{ .datum = .{ .int = @intCast(k) }, .origin = origin };
    items[2] = k_form;
    return try makeList(ctx, items, origin);
}

/// The test for a variadic clause with `fixed_count` params before
/// `&`: `(not (< n fixed_count))`, true when argc >= fixed_count.
fn buildVariadicCondition(ctx: *ExpandContext, origin: reader_mod.SrcSpan, n_sym: *Form, fixed_count: usize) ExpandError!*Form {
    const lt_items = try ctx.allocator.alloc(*Form, 3);
    lt_items[0] = try coreSym(ctx, "<", origin);
    lt_items[1] = n_sym;
    const k_form = try ctx.allocator.create(Form);
    k_form.* = .{ .datum = .{ .int = @intCast(fixed_count) }, .origin = origin };
    lt_items[2] = k_form;
    const lt_call = try makeList(ctx, lt_items, origin);
    const not_items = try ctx.allocator.alloc(*Form, 2);
    not_items[0] = try coreSym(ctx, "not", origin);
    not_items[1] = lt_call;
    return try makeList(ctx, not_items, origin);
}

/// The body of an arity branch: `(loop [params...] body...)` over
/// `args_sym`, the packed argument list. Param `i` binds
/// `(nth args_sym i nil)`; a variadic clause's rest param binds
/// `rest` applied `fixed` times to `args_sym`. The clause's
/// parameters are loop locals, so a `recur` in the clause's tail
/// rebinds exactly them and jumps to the clause body: Clojure's
/// rule that `recur` re-enters the clause with the clause's own
/// arity. A `recur` inside a nested `loop` in the clause targets
/// that inner loop, as everywhere else.
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
        const rest_expr = try restSourceFor(ctx, rest_pat, try buildNestedRest(ctx, args_sym, fixed, .rest, origin), origin);
        try bindings.append(ctx.allocator, @constCast(rest_pat));
        try bindings.append(ctx.allocator, rest_expr);
    }
    const bindings_slice = try ctx.allocator.alloc(*Form, bindings.items.len);
    for (bindings.items, 0..) |b, j| bindings_slice[j] = b;
    const binds_vec = try makeVector(ctx, bindings_slice, origin);
    // `loop` (not `loop*`) so a param pattern destructures on
    // entry and again after every `recur` (e.g., (defn f ([[x y]]
    // (+ x y)))): `expandLoopRename` binds the pattern's gensym.
    const loop_items = try ctx.allocator.alloc(*Form, 2 + body.len);
    loop_items[0] = try makeSymbol(ctx, "loop", origin);
    loop_items[1] = binds_vec;
    for (body, 0..) |b, j| loop_items[2 + j] = @constCast(b);
    return try makeList(ctx, loop_items, origin);
}

/// Destructure a single binding pair `pattern = expr`.
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
/// Pattern elements: symbols bind to (nth src i nil); `& r` binds
/// `r` to `next` applied once per preceding element, so an
/// exhausted rest is nil; `:as name` binds name to src.
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
            // `(next (next ... src))` applied `i` times skips the
            // first `i` elements.
            const rest_expr = try restSourceFor(ctx, rest_pat, try buildNestedRest(ctx, src, i, .next, origin), origin);
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
///   {:keys [a b]}      → a (get src :a)  b (get src :b)
///   {:keys [p/a :b]}   → a (get src :p/a)  b (get src :b)
///   {:p/keys [a]}      → a (get src :p/a)
///   {:strs [a]}        → a (get src "a")
///   {:syms [a]}        → a (get src 'a);  {:p/syms [a]} → (get src 'p/a)
///   {a :a-key}         → a (get src :a-key)
///   {... :or {a 10}}   → a (get src ... 10) when the key is absent
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
                if (v.datum != .vector) return ExpandError.MalformedMacroCall;
                for (v.datum.vector) |entry| try destructureKeyEntry(ctx, g, kw.ns, entry, src, defaults, out, origin);
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

const KeyGroup = enum { keys, strs, syms };

/// One entry of a `:keys` / `:strs` / `:syms` vector: the local is
/// the entry's name part; the key is that name as a keyword, string
/// or symbol, qualified by the entry's own namespace or by the
/// group's (`:p/keys`). A keyword entry in `:keys` is itself the key.
fn destructureKeyEntry(
    ctx: *ExpandContext,
    group: KeyGroup,
    group_ns: ?[]const u8,
    entry: *const Form,
    src: *Form,
    defaults: ?[]const *Form,
    out: *std.ArrayList(*Form),
    origin: reader_mod.SrcSpan,
) ExpandError!void {
    const parts: reader_mod.Name = switch (entry.datum) {
        .symbol => |sym| sym,
        .keyword => |kw| if (group == .keys) kw else return ExpandError.MalformedMacroCall,
        else => return ExpandError.MalformedMacroCall,
    };
    const key_ns = parts.ns orelse group_ns;
    const key_form: *Form = switch (group) {
        .keys => blk: {
            const f = try ctx.allocator.create(Form);
            f.* = .{ .datum = .{ .keyword = .{ .ns = key_ns, .name = parts.name } }, .origin = origin };
            break :blk f;
        },
        .strs => blk: {
            const f = try ctx.allocator.create(Form);
            f.* = .{ .datum = .{ .string = parts.name }, .origin = origin };
            break :blk f;
        },
        .syms => blk: {
            const sym = if (key_ns) |ns| try makeQualifiedSymbol(ctx, ns, parts.name, origin) else try makeSymbol(ctx, parts.name, origin);
            break :blk try makeListInline(ctx, origin, &.{ try makeSymbol(ctx, "quote", origin), sym });
        },
    };
    const local = try makeSymbol(ctx, parts.name, origin);
    const get_expr = try buildGetCall(ctx, src, key_form, lookupDefault(defaults, parts.name), origin);
    try destructurePair(ctx, local, get_expr, out, origin);
}

/// The source a rest pattern destructures: a map pattern after `&`
/// takes keyword arguments, so the rest seq becomes the map
/// `nexis.internal/#%kwargs` builds from it (`k v k v ...`, or one
/// trailing map); any other pattern takes the seq itself.
fn restSourceFor(ctx: *ExpandContext, rest_pat: *const Form, rest_expr: *Form, origin: reader_mod.SrcSpan) ExpandError!*Form {
    if (rest_pat.datum != .map) return rest_expr;
    return try makeListInline(ctx, origin, &.{ try makeQualifiedSymbol(ctx, "nexis.internal", "#%kwargs", origin), rest_expr });
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
    items[0] = try coreSym(ctx, "nth", origin);
    items[1] = src;
    const idx_form = try ctx.allocator.create(Form);
    idx_form.* = .{ .datum = .{ .int = @intCast(idx) }, .origin = origin };
    items[2] = idx_form;
    items[3] = try makeNil(ctx, origin);
    return try makeList(ctx, items, origin);
}

/// How a rest binding drops the elements before it: `next` yields
/// nil once the source is exhausted (a vector pattern's `& r`,
/// Clojure's `nthnext`); `rest` yields the empty list (an overload
/// clause's rest over the list the VM packs, `VM.md` §6).
const RestOp = enum { rest, next };

/// `(op (op ... (op src) ...))` applied `n` times.
fn buildNestedRest(ctx: *ExpandContext, src: *Form, n: usize, op: RestOp, origin: reader_mod.SrcSpan) ExpandError!*Form {
    var expr: *Form = src;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const items = try ctx.allocator.alloc(*Form, 2);
        items[0] = try coreSym(ctx, @tagName(op), origin);
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
    items[0] = try coreSym(ctx, "get", origin);
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

/// `(loop [pattern init ...] body...)` → `(loop* [g init ...] (let
/// [pattern g ...] body...))`: each non-symbol pattern binds a
/// gensym in the loop and destructures it again on every
/// iteration, so `recur` rebinds the gensyms. Symbol bindings and
/// a pattern-free loop rename to `loop*` unchanged.
fn expandLoopRename(
    ctx: *ExpandContext,
    call_form: *const Form,
    args: []const *Form,
) ExpandError!*Form {
    if (args.len < 1 or args[0].datum != .vector) return ExpandError.MalformedMacroCall;
    const pairs = args[0].datum.vector;
    if (pairs.len % 2 != 0) return ExpandError.MalformedMacroCall;
    var has_pattern = false;
    for (pairs, 0..) |p, i| {
        if (i % 2 == 0 and p.datum != .symbol) has_pattern = true;
    }
    if (!has_pattern) return renameHead(ctx, call_form, args, "loop*");

    const origin = call_form.origin;
    const loop_bindings = try ctx.allocator.alloc(*Form, pairs.len);
    var let_bindings: std.ArrayList(*Form) = .empty;
    defer let_bindings.deinit(ctx.allocator);
    var i: usize = 0;
    while (i < pairs.len) : (i += 2) {
        loop_bindings[i + 1] = @constCast(pairs[i + 1]);
        if (pairs[i].datum == .symbol) {
            loop_bindings[i] = @constCast(pairs[i]);
        } else {
            const g = try genTempSym(ctx, origin);
            loop_bindings[i] = g;
            try let_bindings.append(ctx.allocator, @constCast(pairs[i]));
            try let_bindings.append(ctx.allocator, g);
        }
    }
    var let_items: std.ArrayList(*Form) = .empty;
    defer let_items.deinit(ctx.allocator);
    try let_items.append(ctx.allocator, try makeSymbol(ctx, "let", origin));
    try let_items.append(ctx.allocator, try makeVector(ctx, try ctx.allocator.dupe(*Form, let_bindings.items), origin));
    for (args[1..]) |b| try let_items.append(ctx.allocator, @constCast(b));
    return try makeListInline(ctx, origin, &.{
        try makeSymbol(ctx, "loop*", origin),
        try makeVector(ctx, loop_bindings, origin),
        try makeListInline(ctx, origin, let_items.items),
    });
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
// the first operand (per MACROEXPAND.md §10.G/H).

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
// Odd-count args raise MalformedMacroCall. There is no special
// case for `:else` — any truthy test works as a default; users
// can write `(cond ... :else default)` and the keyword's
// truthiness makes it pass.

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

// ---- case ----------------------------------------------------
//
//   (case expr)                  => (throw {:error :no-matching-clause ...})
//   (case expr default)          => (let* [g# expr] default)
//   (case expr k1 v1 k2 v2 ...)  => chained `(if (= g# 'k_i) v_i ...)`
//                                   with the no-match throw as the
//                                   terminal branch when the clause
//                                   count is even (no default).
//   (case expr k1 v1 ... default) => same, with `default` as the
//                                    terminal else branch when the
//                                    clause count is odd.
//
// Each key is a constant, never evaluated: a symbol key is the
// symbol itself, a vector or map key is that literal, and a list
// key `(k1 k2 ...)` groups alternatives, any of which matches. The
// test for a key is `(= g# (quote k))`; a group nests the tests as
// `(if (= g# 'k1) true (= g# 'k2))`.
//
// No-match with no default THROWS `{:error :no-matching-clause
// :message "No matching clause: <expr>" :value expr}`, not
// returns nil (Clojure's IllegalArgumentException carries the same
// message). Forces users to be explicit about exhaustion.
// Mirrors Clojure semantics modulo the perf shape (Clojure uses
// hash dispatch; we chain `if`).
//
// `expr` is evaluated EXACTLY ONCE via gensym.

fn expandCase(
    ctx: *ExpandContext,
    call_form: *const Form,
    args: []const *Form,
) ExpandError!*Form {
    if (args.len == 0) return ExpandError.MalformedMacroCall;
    const expr_form = args[0];
    const clauses = args[1..];

    // gensym the test expression so it's evaluated exactly once.
    const g_name = try ctx.gensym("case");

    // Terminal default branch: the no-match throw OR the
    // odd-arity terminal form.
    const has_default = (clauses.len % 2 == 1);
    var terminal: *Form = if (has_default)
        @constCast(clauses[clauses.len - 1])
    else
        try makeNoMatchThrow(ctx, g_name, call_form.origin);

    // Walk pairs right-to-left, wrapping in `(if <test> v rest)`.
    const pair_count = clauses.len / 2;
    var i: usize = pair_count;
    while (i > 0) {
        i -= 1;
        const key = clauses[i * 2];
        const value = clauses[i * 2 + 1];

        const test_form = try buildCaseTest(ctx, g_name, key, call_form.origin);

        const if_items = try ctx.allocator.alloc(*Form, 4);
        if_items[0] = try makeSymbol(ctx, "if", call_form.origin);
        if_items[1] = test_form;
        if_items[2] = @constCast(value);
        if_items[3] = terminal;
        terminal = try makeList(ctx, if_items, call_form.origin);
    }

    // Wrap in (let* [g# expr] <chained-if>).
    const binding_items = try ctx.allocator.alloc(*Form, 2);
    binding_items[0] = try makeSymbol(ctx, g_name, call_form.origin);
    binding_items[1] = @constCast(expr_form);
    const binding_vec = try makeVector(ctx, binding_items, call_form.origin);

    const let_items = try ctx.allocator.alloc(*Form, 3);
    let_items[0] = try makeSymbol(ctx, "let*", call_form.origin);
    let_items[1] = binding_vec;
    let_items[2] = terminal;
    return try makeList(ctx, let_items, call_form.origin);
}

/// The test for one `case` key: `(= g 'k)` for a single constant;
/// for a list of alternatives, `(if (= g 'k1) true <rest>)` nested
/// over the group so any alternative matches. An empty group never
/// matches.
fn buildCaseTest(ctx: *ExpandContext, g_name: []const u8, key: *const Form, origin: reader_mod.SrcSpan) ExpandError!*Form {
    const alternatives: []const *Form = if (key.datum == .list) key.datum.list else &.{@constCast(key)};
    if (alternatives.len == 0) return try makeBool(ctx, false, origin);
    var test_form: *Form = try buildCaseEq(ctx, g_name, alternatives[alternatives.len - 1], origin);
    var i: usize = alternatives.len - 1;
    while (i > 0) {
        i -= 1;
        const if_items = try ctx.allocator.alloc(*Form, 4);
        if_items[0] = try makeSymbol(ctx, "if", origin);
        if_items[1] = try buildCaseEq(ctx, g_name, alternatives[i], origin);
        if_items[2] = try makeBool(ctx, true, origin);
        if_items[3] = test_form;
        test_form = try makeList(ctx, if_items, origin);
    }
    return test_form;
}

/// `(= g (quote k))`: the key is data, so a symbol compares as a
/// symbol and a compound literal as that literal.
fn buildCaseEq(ctx: *ExpandContext, g_name: []const u8, key: *const Form, origin: reader_mod.SrcSpan) ExpandError!*Form {
    const quote_items = try ctx.allocator.alloc(*Form, 2);
    quote_items[0] = try makeSymbol(ctx, "quote", origin);
    quote_items[1] = @constCast(key);
    const eq_items = try ctx.allocator.alloc(*Form, 3);
    eq_items[0] = try coreSym(ctx, "=", origin);
    eq_items[1] = try makeSymbol(ctx, g_name, origin);
    eq_items[2] = try makeList(ctx, quote_items, origin);
    return try makeList(ctx, eq_items, origin);
}

// ---- condp ---------------------------------------------------
//
//   (condp pred expr)                       => (throw {:error :no-matching-clause ...})
//   (condp pred expr default)               => default
//   (condp pred expr c1 v1 c2 v2 ...)       => chained `(if (p# c_i e#) v_i ...)`
//                                              with the no-match throw
//                                              when the clause count is even.
//   (condp pred expr c1 v1 ... default)     => terminal default.
//
// Same throw-on-no-match policy as case. `pred` and `expr` each
// evaluated exactly ONCE via gensyms. Predicate call order:
// `(p# clause expr)` (matches Clojure). There is no `:>>`
// thread-result-through-fn syntax.

fn expandCondp(
    ctx: *ExpandContext,
    call_form: *const Form,
    args: []const *Form,
) ExpandError!*Form {
    if (args.len < 2) return ExpandError.MalformedMacroCall;
    const pred_form = args[0];
    const expr_form = args[1];
    const clauses = args[2..];

    const p_name = try ctx.gensym("condp-pred");
    const e_name = try ctx.gensym("condp-expr");

    const has_default = (clauses.len % 2 == 1);
    var terminal: *Form = if (has_default)
        @constCast(clauses[clauses.len - 1])
    else
        try makeNoMatchThrow(ctx, e_name, call_form.origin);

    const pair_count = clauses.len / 2;
    var i: usize = pair_count;
    while (i > 0) {
        i -= 1;
        const clause = clauses[i * 2];
        const value = clauses[i * 2 + 1];

        const call_items = try ctx.allocator.alloc(*Form, 3);
        call_items[0] = try makeSymbol(ctx, p_name, call_form.origin);
        call_items[1] = @constCast(clause);
        call_items[2] = try makeSymbol(ctx, e_name, call_form.origin);
        const call = try makeList(ctx, call_items, call_form.origin);

        const if_items = try ctx.allocator.alloc(*Form, 4);
        if_items[0] = try makeSymbol(ctx, "if", call_form.origin);
        if_items[1] = call;
        if_items[2] = @constCast(value);
        if_items[3] = terminal;
        terminal = try makeList(ctx, if_items, call_form.origin);
    }

    // Wrap in (let* [p# pred e# expr] <chained-if>).
    const binding_items = try ctx.allocator.alloc(*Form, 4);
    binding_items[0] = try makeSymbol(ctx, p_name, call_form.origin);
    binding_items[1] = @constCast(pred_form);
    binding_items[2] = try makeSymbol(ctx, e_name, call_form.origin);
    binding_items[3] = @constCast(expr_form);
    const binding_vec = try makeVector(ctx, binding_items, call_form.origin);

    const let_items = try ctx.allocator.alloc(*Form, 3);
    let_items[0] = try makeSymbol(ctx, "let*", call_form.origin);
    let_items[1] = binding_vec;
    let_items[2] = terminal;
    return try makeList(ctx, let_items, call_form.origin);
}

// ---- for ----------------------------------------------------
//
// Eager `for`: `(for [pattern src modifiers... ...] body)` builds a
// vector. Each binding pair may be followed by `:let [bindings]`,
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
// any earlier `:let`. Modifiers before the first pair, an odd
// vector or a body count other than one are MalformedMacroCall.

const ForModifier = union(enum) {
    let_bindings: *Form,
    when_test: *Form,
    while_test: *Form,
};

const ForLevel = struct {
    pattern: *Form,
    src: *Form,
    modifiers: std.ArrayList(ForModifier) = .empty,
};

fn expandFor(
    ctx: *ExpandContext,
    call_form: *const Form,
    args: []const *Form,
) ExpandError!*Form {
    if (args.len != 2) return ExpandError.MalformedMacroCall;
    const bindings_form = args[0];
    if (bindings_form.datum != .vector) return ExpandError.MalformedMacroCall;
    const bindings = bindings_form.datum.vector;
    const body = args[1];
    if (bindings.len == 0) return ExpandError.MalformedMacroCall;

    var levels: std.ArrayList(ForLevel) = .empty;
    defer {
        for (levels.items) |*l| l.modifiers.deinit(ctx.allocator);
        levels.deinit(ctx.allocator);
    }
    var i: usize = 0;
    while (i + 1 < bindings.len) : (i += 2) {
        const item = bindings[i];
        const value = @constCast(bindings[i + 1]);
        if (item.datum == .keyword) {
            const kw = item.datum.keyword;
            if (kw.ns != null or levels.items.len == 0) return ExpandError.MalformedMacroCall;
            const level = &levels.items[levels.items.len - 1];
            const modifier: ForModifier = if (std.mem.eql(u8, kw.name, "let")) blk: {
                if (value.datum != .vector) return ExpandError.MalformedMacroCall;
                break :blk .{ .let_bindings = value };
            } else if (std.mem.eql(u8, kw.name, "when"))
                .{ .when_test = value }
            else if (std.mem.eql(u8, kw.name, "while"))
                .{ .while_test = value }
            else
                return ExpandError.MalformedMacroCall;
            try level.modifiers.append(ctx.allocator, modifier);
        } else {
            try levels.append(ctx.allocator, .{ .pattern = @constCast(item), .src = value });
        }
    }
    if (i != bindings.len) return ExpandError.MalformedMacroCall;

    const empty_items = try ctx.allocator.alloc(*Form, 0);
    return try buildForLevel(ctx, levels.items, 0, try makeVector(ctx, empty_items, call_form.origin), body, call_form.origin);
}

/// The loop for `levels[idx]` accumulating onto `outer_acc`.
fn buildForLevel(
    ctx: *ExpandContext,
    levels: []const ForLevel,
    idx: usize,
    outer_acc: *Form,
    body: *const Form,
    origin: reader_mod.SrcSpan,
) ExpandError!*Form {
    const level = levels[idx];
    const s_sym = try genTempSym(ctx, origin);
    const acc_sym = try genTempSym(ctx, origin);
    const next_s = try makeListInline(ctx, origin, &.{ try coreSym(ctx, "next", origin), s_sym });

    // What the element contributes: the nested loop or the body.
    const contribution: *Form = if (idx + 1 < levels.len)
        try buildForLevel(ctx, levels, idx + 1, acc_sym, body, origin)
    else
        try makeListInline(ctx, origin, &.{ try coreSym(ctx, "conj", origin), acc_sym, @constCast(body) });
    var inner: *Form = try makeListInline(ctx, origin, &.{ try makeSymbol(ctx, "recur", origin), next_s, contribution });

    var m: usize = level.modifiers.items.len;
    while (m > 0) {
        m -= 1;
        inner = switch (level.modifiers.items[m]) {
            .let_bindings => |lb| try makeListInline(ctx, origin, &.{ try makeSymbol(ctx, "let", origin), lb, inner }),
            .when_test => |t| try makeListInline(ctx, origin, &.{
                try makeSymbol(ctx, "if", origin),
                t,
                inner,
                try makeListInline(ctx, origin, &.{ try makeSymbol(ctx, "recur", origin), next_s, acc_sym }),
            }),
            .while_test => |t| try makeListInline(ctx, origin, &.{ try makeSymbol(ctx, "if", origin), t, inner, acc_sym }),
        };
    }

    const first_s = try makeListInline(ctx, origin, &.{ try coreSym(ctx, "first", origin), s_sym });
    const elem_bindings = try ctx.allocator.alloc(*Form, 2);
    elem_bindings[0] = level.pattern;
    elem_bindings[1] = first_s;
    const with_elem = try makeListInline(ctx, origin, &.{ try makeSymbol(ctx, "let", origin), try makeVector(ctx, elem_bindings, origin), inner });

    const loop_bindings = try ctx.allocator.alloc(*Form, 4);
    loop_bindings[0] = s_sym;
    loop_bindings[1] = try makeListInline(ctx, origin, &.{ try coreSym(ctx, "seq", origin), level.src });
    loop_bindings[2] = acc_sym;
    loop_bindings[3] = outer_acc;
    return try makeListInline(ctx, origin, &.{
        try makeSymbol(ctx, "loop*", origin),
        try makeVector(ctx, loop_bindings, origin),
        try makeListInline(ctx, origin, &.{ try makeSymbol(ctx, "if", origin), s_sym, with_elem, acc_sym }),
    });
}

// ---- defrecord (records + inline protocol impls) ----
//
// Spec: PROTOCOLS.md §4.2.
//
//   (defrecord Counter [n]
//     IFoo
//     (bar [this y] (+ (:n this) y))
//     IBar
//     (baz [this] (:n this)))
//   →
//   (do
//     (def Counter-type-id (nexis.internal/#%register-record-type
//                            "<ns>/Counter" [:n]))
//     (defn ->Counter [n] ...)
//     (defn map->Counter [m] ...)
//     (defn Counter? [x] ...)
//     ;; one extend call per method impl:
//     (nexis.internal/#%extend-record-impl
//       IFoo :bar Counter-type-id
//       (fn [this y] (+ (:n this) y)))
//     (nexis.internal/#%extend-record-impl
//       IBar :baz Counter-type-id
//       (fn [this] (:n this))))
//
// Clauses after the field-vector are parsed in order:
//   - A bare symbol → switch "current protocol" to that symbol.
//   - A list `(method-name [params] body...)` → emit one
//     extend-record-impl call against the current protocol.
// Same shape Clojure uses.

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

fn expandDefrecord(
    ctx: *ExpandContext,
    call_form: *const Form,
    args: []const *Form,
) ExpandError!*Form {
    // Minimum: (defrecord Name [fields])
    if (args.len < 2) return ExpandError.MalformedMacroCall;
    const name_form = args[0];
    if (name_form.datum != .symbol) return ExpandError.MalformedMacroCall;
    if (name_form.datum.symbol.ns != null) return ExpandError.MalformedMacroCall;
    const fields_form = args[1];
    if (fields_form.datum != .vector) return ExpandError.MalformedMacroCall;

    const rec_name = name_form.datum.symbol.name;
    const origin = call_form.origin;

    // Build the fully-qualified record-type name string. Use
    // the macroexpand context's current namespace if available;
    // otherwise emit just the bare name (the registry treats
    // empty ns as "no qualifier", and re-registration safety
    // is per-name).
    const ns_name: []const u8 = if (ctx.namespace) |ns| ns.name else "";
    const full_name = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ ns_name, rec_name });

    // Helper: build the keyword-vector of field names (verifies
    // each field is an unqualified symbol; emits `:fieldname`
    // keywords).
    const field_count = fields_form.datum.vector.len;
    var keyword_items = try ctx.allocator.alloc(*Form, field_count);
    for (fields_form.datum.vector, 0..) |fld, i| {
        if (fld.datum != .symbol) return ExpandError.MalformedMacroCall;
        if (fld.datum.symbol.ns != null) return ExpandError.MalformedMacroCall;
        const kw = try ctx.allocator.create(Form);
        kw.* = .{
            .datum = .{ .keyword = .{ .ns = null, .name = fld.datum.symbol.name } },
            .origin = origin,
        };
        keyword_items[i] = kw;
    }
    const fields_kw_vec = try makeVector(ctx, keyword_items, origin);

    // Names we synthesize (the arena keeps them).
    const names = try RecordNames.init(ctx.allocator, rec_name);
    const type_id_name = names.type_id;
    const ctor_name = names.ctor;
    const map_ctor_name = names.map_ctor;
    const pred_name = names.pred;

    // Qualified internal-helper Forms.
    const register_sym = try makeQualifiedSymbol(ctx, "nexis.internal", "#%register-record-type", origin);
    const make_sym = try makeQualifiedSymbol(ctx, "nexis.internal", "#%make-record", origin);
    const record_q_sym = try makeQualifiedSymbol(ctx, "nexis.internal", "#%record?", origin);
    const record_type_id_sym = try makeQualifiedSymbol(ctx, "nexis.internal", "#%record-type-id", origin);

    // String literal for the full record-type name.
    const full_name_str = try ctx.allocator.create(Form);
    full_name_str.* = .{
        .datum = .{ .string = full_name },
        .origin = origin,
    };

    // ---- Form 1: (def Counter-type-id
    //                 (nexis.internal/#%register-record-type
    //                   "ns/Counter" [:n]))
    const reg_call = try makeListInline(ctx, origin, &.{
        register_sym,
        full_name_str,
        fields_kw_vec,
    });
    const def_type_id = try makeListInline(ctx, origin, &.{
        try makeSymbol(ctx, "def", origin),
        try makeSymbol(ctx, type_id_name, origin),
        reg_call,
    });

    // ---- Form 2: (defn ->Counter [n] (#%make-record id (assoc {} :n n)))
    // Build the field-map construction: (assoc (assoc ... {} :f0 f0) :f1 f1 ...)
    // Easier: start from `{}` literal map, then `assoc` each field.
    const ctor_body_inner: *Form = blk: {
        const empty_map = try makeEmptyMap(ctx, origin);
        var acc = empty_map;
        for (fields_form.datum.vector) |fld| {
            const sym_name = fld.datum.symbol.name;
            const kw = try ctx.allocator.create(Form);
            kw.* = .{
                .datum = .{ .keyword = .{ .ns = null, .name = sym_name } },
                .origin = origin,
            };
            const sym_form = try makeSymbol(ctx, sym_name, origin);
            acc = try makeListInline(ctx, origin, &.{
                try coreSym(ctx, "assoc", origin),
                acc,
                kw,
                sym_form,
            });
        }
        break :blk acc;
    };
    const ctor_make_call = try makeListInline(ctx, origin, &.{
        make_sym,
        try makeSymbol(ctx, type_id_name, origin),
        ctor_body_inner,
    });
    // Build parameter vector [n m ...] for the constructor.
    const ctor_params = try ctx.allocator.alloc(*Form, field_count);
    for (fields_form.datum.vector, 0..) |fld, i| {
        ctor_params[i] = try makeSymbol(ctx, fld.datum.symbol.name, origin);
    }
    const ctor_param_vec = try makeVector(ctx, ctor_params, origin);
    const defn_ctor = try makeListInline(ctx, origin, &.{
        try makeSymbol(ctx, "defn", origin),
        try makeSymbol(ctx, ctor_name, origin),
        ctor_param_vec,
        ctor_make_call,
    });

    // ---- Form 3: (defn map->Counter [m] (#%make-record id m))
    const map_ctor_call = try makeListInline(ctx, origin, &.{
        make_sym,
        try makeSymbol(ctx, type_id_name, origin),
        try makeSymbol(ctx, "m", origin),
    });
    const map_ctor_params = try ctx.allocator.alloc(*Form, 1);
    map_ctor_params[0] = try makeSymbol(ctx, "m", origin);
    const defn_map_ctor = try makeListInline(ctx, origin, &.{
        try makeSymbol(ctx, "defn", origin),
        try makeSymbol(ctx, map_ctor_name, origin),
        try makeVector(ctx, map_ctor_params, origin),
        map_ctor_call,
    });

    // ---- Form 4: (defn Counter? [x]
    //                (and (#%record? x)
    //                     (= Counter-type-id (#%record-type-id x))))
    const pred_body = try makeListInline(ctx, origin, &.{
        try makeSymbol(ctx, "and", origin),
        try makeListInline(ctx, origin, &.{
            record_q_sym,
            try makeSymbol(ctx, "x", origin),
        }),
        try makeListInline(ctx, origin, &.{
            try coreSym(ctx, "=", origin),
            try makeSymbol(ctx, type_id_name, origin),
            try makeListInline(ctx, origin, &.{
                record_type_id_sym,
                try makeSymbol(ctx, "x", origin),
            }),
        }),
    });
    const pred_params = try ctx.allocator.alloc(*Form, 1);
    pred_params[0] = try makeSymbol(ctx, "x", origin);
    const defn_pred = try makeListInline(ctx, origin, &.{
        try makeSymbol(ctx, "defn", origin),
        try makeSymbol(ctx, pred_name, origin),
        try makeVector(ctx, pred_params, origin),
        pred_body,
    });

    // ---- Parse inline protocol clauses (args[2..]).
    // Walk clauses tracking a "current protocol symbol". Bare
    // symbol → switch; list → emit one #%extend-record-impl call.
    const extend_sym = try makeQualifiedSymbol(ctx, "nexis.internal", "#%extend-record-impl", origin);
    var extend_calls: std.ArrayList(*Form) = .empty;
    defer extend_calls.deinit(ctx.allocator);

    if (args.len > 2) {
        var current_protocol: ?*const Form = null;
        for (args[2..]) |clause| {
            if (clause.datum == .symbol) {
                // Protocol-name switch.
                current_protocol = clause;
                continue;
            }
            if (clause.datum != .list) return ExpandError.MalformedMacroCall;
            if (clause.datum.list.len < 2) return ExpandError.MalformedMacroCall;
            const proto = current_protocol orelse return ExpandError.MalformedMacroCall;
            const method_head = clause.datum.list[0];
            if (method_head.datum != .symbol) return ExpandError.MalformedMacroCall;
            if (method_head.datum.symbol.ns != null) return ExpandError.MalformedMacroCall;
            const method_name = method_head.datum.symbol.name;
            const params_form = clause.datum.list[1];
            if (params_form.datum != .vector) return ExpandError.MalformedMacroCall;
            const body_slice = clause.datum.list[2..];

            // Build `(fn params body...)`.
            var fn_items = try ctx.allocator.alloc(*Form, 2 + body_slice.len);
            fn_items[0] = try makeSymbol(ctx, "fn", origin);
            fn_items[1] = params_form;
            for (body_slice, 0..) |b, i| fn_items[2 + i] = b;
            const fn_form = try makeList(ctx, fn_items, origin);

            // Method-name keyword.
            const method_kw = try ctx.allocator.create(Form);
            method_kw.* = .{
                .datum = .{ .keyword = .{ .ns = null, .name = method_name } },
                .origin = origin,
            };

            // Build the qualified protocol symbol reference (just
            // pass the user-typed symbol verbatim — runtime resolves
            // it via the namespace binding from defprotocol).
            const proto_ref = try ctx.allocator.create(Form);
            proto_ref.* = proto.*;

            const call_form_x = try makeListInline(ctx, origin, &.{
                extend_sym,
                proto_ref,
                method_kw,
                try makeSymbol(ctx, type_id_name, origin),
                fn_form,
            });
            try extend_calls.append(ctx.allocator, call_form_x);
        }
    }

    // ---- Wrap everything in (do ...).
    var top_items = try ctx.allocator.alloc(*Form, 5 + extend_calls.items.len);
    top_items[0] = try makeSymbol(ctx, "do", origin);
    top_items[1] = def_type_id;
    top_items[2] = defn_ctor;
    top_items[3] = defn_map_ctor;
    top_items[4] = defn_pred;
    for (extend_calls.items, 0..) |c, i| top_items[5 + i] = c;
    return try makeList(ctx, top_items, origin);
}

// ---- defprotocol ----
//
// Spec: PROTOCOLS.md §4.1.
//
//   (defprotocol IFoo
//     (bar [this y])
//     (baz [this]))
//   →
//   (do
//     (def IFoo (nexis.internal/#%register-protocol
//                  "<ns>/IFoo" [:bar :baz]))
//     (def bar (nexis.internal/#%protocol-fn IFoo :bar))
//     (def baz (nexis.internal/#%protocol-fn IFoo :baz)))
//
// Method signatures (arity, doc strings) are not verified.
// The dispatch path raises `:no-protocol-impl` at call time
// when no impl matches the receiver.

fn expandDefprotocol(
    ctx: *ExpandContext,
    call_form: *const Form,
    args: []const *Form,
) ExpandError!*Form {
    // Minimum: (defprotocol Name <method-spec>+)
    if (args.len < 1) return ExpandError.MalformedMacroCall;
    const name_form = args[0];
    if (name_form.datum != .symbol) return ExpandError.MalformedMacroCall;
    if (name_form.datum.symbol.ns != null) return ExpandError.MalformedMacroCall;
    const proto_name = name_form.datum.symbol.name;
    const origin = call_form.origin;

    // Parse method specs: each must be a list whose head is a
    // symbol (the method name). The arg-vector after the name
    // is ignored.
    var method_kw_items = try ctx.allocator.alloc(*Form, args.len - 1);
    var method_names = try ctx.allocator.alloc([]const u8, args.len - 1);
    for (args[1..], 0..) |spec, i| {
        if (spec.datum != .list) return ExpandError.MalformedMacroCall;
        if (spec.datum.list.len == 0) return ExpandError.MalformedMacroCall;
        const head = spec.datum.list[0];
        if (head.datum != .symbol) return ExpandError.MalformedMacroCall;
        if (head.datum.symbol.ns != null) return ExpandError.MalformedMacroCall;
        method_names[i] = head.datum.symbol.name;
        const kw = try ctx.allocator.create(Form);
        kw.* = .{
            .datum = .{ .keyword = .{ .ns = null, .name = head.datum.symbol.name } },
            .origin = origin,
        };
        method_kw_items[i] = kw;
    }
    const methods_kw_vec = try makeVector(ctx, method_kw_items, origin);

    // Build the protocol full-name string.
    const ns_name: []const u8 = if (ctx.namespace) |ns| ns.name else "";
    const full_name = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ ns_name, proto_name });
    const full_name_str = try ctx.allocator.create(Form);
    full_name_str.* = .{
        .datum = .{ .string = full_name },
        .origin = origin,
    };

    // Qualified helpers.
    const register_sym = try makeQualifiedSymbol(ctx, "nexis.internal", "#%register-protocol", origin);
    const protocol_fn_sym = try makeQualifiedSymbol(ctx, "nexis.internal", "#%protocol-fn", origin);

    // (def IFoo (#%register-protocol "ns/IFoo" [:bar :baz]))
    const reg_call = try makeListInline(ctx, origin, &.{
        register_sym,
        full_name_str,
        methods_kw_vec,
    });
    const def_proto = try makeListInline(ctx, origin, &.{
        try makeSymbol(ctx, "def", origin),
        try makeSymbol(ctx, proto_name, origin),
        reg_call,
    });

    // Build the (def method-name (#%protocol-fn IFoo :method-name))
    // for every method.
    var top_items = try ctx.allocator.alloc(*Form, args.len + 1);
    top_items[0] = try makeSymbol(ctx, "do", origin);
    top_items[1] = def_proto;
    for (method_names, 0..) |mname, i| {
        const kw = try ctx.allocator.create(Form);
        kw.* = .{
            .datum = .{ .keyword = .{ .ns = null, .name = mname } },
            .origin = origin,
        };
        const pf_call = try makeListInline(ctx, origin, &.{
            protocol_fn_sym,
            try makeSymbol(ctx, proto_name, origin),
            kw,
        });
        top_items[2 + i] = try makeListInline(ctx, origin, &.{
            try makeSymbol(ctx, "def", origin),
            try makeSymbol(ctx, mname, origin),
            pf_call,
        });
    }
    return try makeList(ctx, top_items, origin);
}

// ---- extend-type / extend-protocol ----
//
// Spec: PROTOCOLS.md §4.3.
//
// `extend-type` shape:
//   (extend-type Type
//     Protocol1
//     (method1 [params] body)
//     (method2 [params] body)
//     Protocol2
//     (method3 [params] body))
//
// `extend-protocol` shape:
//   (extend-protocol Protocol
//     Type1
//     (method1 [params] body)
//     Type2
//     (method2 [params] body))
//
// Type forms:
//   - Keyword `:string` / `:vector` / `:map` / `:nil` / etc. →
//     dispatches via the built-in Kind enum.
//   - Keyword `:any` → installs as the default-impl fallback.
//   - Symbol `Counter` → dispatches via the record's type_id
//     (must be a defrecord-defined name; the macro emits a
//     reference to `Counter-type-id`).

fn emitExtendCall(
    ctx: *ExpandContext,
    type_form: *const Form,
    protocol_form: *const Form,
    method_name: []const u8,
    params: *Form,
    body_slice: []const *Form,
    origin: reader_mod.SrcSpan,
) ExpandError!*Form {
    // Build (fn params body...).
    var fn_items = try ctx.allocator.alloc(*Form, 2 + body_slice.len);
    fn_items[0] = try makeSymbol(ctx, "fn", origin);
    fn_items[1] = params;
    for (body_slice, 0..) |b, i| fn_items[2 + i] = b;
    const fn_form = try makeList(ctx, fn_items, origin);

    // Method-name keyword.
    const method_kw = try ctx.allocator.create(Form);
    method_kw.* = .{
        .datum = .{ .keyword = .{ .ns = null, .name = method_name } },
        .origin = origin,
    };

    // Pass the protocol form verbatim (resolved at runtime).
    const proto_ref = try ctx.allocator.create(Form);
    proto_ref.* = protocol_form.*;

    if (type_form.datum == .keyword) {
        const tag = type_form.datum.keyword.name;
        if (std.mem.eql(u8, tag, "any")) {
            // #%extend-default-impl
            const ext_sym = try makeQualifiedSymbol(ctx, "nexis.internal", "#%extend-default-impl", origin);
            return try makeListInline(ctx, origin, &.{
                ext_sym,
                proto_ref,
                method_kw,
                fn_form,
            });
        }
        // #%extend-builtin-impl
        const ext_sym = try makeQualifiedSymbol(ctx, "nexis.internal", "#%extend-builtin-impl", origin);
        const type_kw = try ctx.allocator.create(Form);
        type_kw.* = .{
            .datum = .{ .keyword = .{ .ns = null, .name = tag } },
            .origin = origin,
        };
        return try makeListInline(ctx, origin, &.{
            ext_sym,
            proto_ref,
            method_kw,
            type_kw,
            fn_form,
        });
    }
    if (type_form.datum == .symbol) {
        // Record type: refer to `<RecName>-type-id`. The macro
        // emits the symbol; the user is responsible for
        // ensuring it's defined (defrecord generates it).
        const rec_name = type_form.datum.symbol.name;
        const type_id_name = try RecordNames.typeId(ctx.allocator, rec_name);
        const ext_sym = try makeQualifiedSymbol(ctx, "nexis.internal", "#%extend-record-impl", origin);
        return try makeListInline(ctx, origin, &.{
            ext_sym,
            proto_ref,
            method_kw,
            try makeSymbol(ctx, type_id_name, origin),
            fn_form,
        });
    }
    return ExpandError.MalformedMacroCall;
}

/// Walk `clauses` looking for protocol-name / type / method-list
/// sequences and emit one extend call per method. The walk
/// alternates between "expect protocol or type" and "expect
/// method impls until next protocol/type", letting it support
/// both `extend-type` (one type, many (protocol-symbol, methods)
/// groups) and `extend-protocol` (one protocol, many (type,
/// methods) groups) with the same parser by swapping which
/// position is iterated.
fn walkExtendClauses(
    ctx: *ExpandContext,
    fixed_anchor_is_protocol: bool,
    anchor_form: *const Form,
    clauses: []const *Form,
    origin: reader_mod.SrcSpan,
    out_calls: *std.ArrayList(*Form),
) ExpandError!void {
    var current_other: ?*const Form = null;
    for (clauses) |clause| {
        if (clause.datum == .symbol or clause.datum == .keyword) {
            current_other = clause;
            continue;
        }
        if (clause.datum != .list) return ExpandError.MalformedMacroCall;
        if (clause.datum.list.len < 2) return ExpandError.MalformedMacroCall;
        const other = current_other orelse return ExpandError.MalformedMacroCall;
        const method_head = clause.datum.list[0];
        if (method_head.datum != .symbol) return ExpandError.MalformedMacroCall;
        if (method_head.datum.symbol.ns != null) return ExpandError.MalformedMacroCall;
        const method_name = method_head.datum.symbol.name;
        const params = clause.datum.list[1];
        if (params.datum != .vector) return ExpandError.MalformedMacroCall;
        const body_slice = clause.datum.list[2..];

        const protocol_form: *const Form = if (fixed_anchor_is_protocol) anchor_form else other;
        const type_form: *const Form = if (fixed_anchor_is_protocol) other else anchor_form;
        const call_form = try emitExtendCall(
            ctx,
            type_form,
            protocol_form,
            method_name,
            params,
            body_slice,
            origin,
        );
        try out_calls.append(ctx.allocator, call_form);
    }
}

fn expandExtendType(
    ctx: *ExpandContext,
    call_form: *const Form,
    args: []const *Form,
) ExpandError!*Form {
    if (args.len < 1) return ExpandError.MalformedMacroCall;
    const type_form = args[0];
    if (type_form.datum != .symbol and type_form.datum != .keyword) {
        return ExpandError.MalformedMacroCall;
    }
    const origin = call_form.origin;
    var calls: std.ArrayList(*Form) = .empty;
    defer calls.deinit(ctx.allocator);
    try walkExtendClauses(ctx, false, type_form, args[1..], origin, &calls);
    var top_items = try ctx.allocator.alloc(*Form, 1 + calls.items.len);
    top_items[0] = try makeSymbol(ctx, "do", origin);
    for (calls.items, 0..) |c, i| top_items[1 + i] = c;
    return try makeList(ctx, top_items, origin);
}

fn expandExtendProtocol(
    ctx: *ExpandContext,
    call_form: *const Form,
    args: []const *Form,
) ExpandError!*Form {
    if (args.len < 1) return ExpandError.MalformedMacroCall;
    const proto_form = args[0];
    if (proto_form.datum != .symbol) return ExpandError.MalformedMacroCall;
    const origin = call_form.origin;
    var calls: std.ArrayList(*Form) = .empty;
    defer calls.deinit(ctx.allocator);
    try walkExtendClauses(ctx, true, proto_form, args[1..], origin, &calls);
    var top_items = try ctx.allocator.alloc(*Form, 1 + calls.items.len);
    top_items[0] = try makeSymbol(ctx, "do", origin);
    for (calls.items, 0..) |c, i| top_items[1 + i] = c;
    return try makeList(ctx, top_items, origin);
}

/// The `nexis.core` function `name` as a qualified symbol: what a
/// host macro emits wherever its output calls a core function, so a
/// user local or Var of the same name cannot capture the call
/// (MACROEXPAND.md §5). Heads that are themselves host macros or
/// special forms stay bare.
fn coreSym(ctx: *ExpandContext, name: []const u8, origin: reader_mod.SrcSpan) ExpandError!*Form {
    return try makeQualifiedSymbol(ctx, "nexis.core", name, origin);
}

/// Helper: make a qualified symbol form (`ns/name`).
fn makeQualifiedSymbol(ctx: *ExpandContext, ns_name: []const u8, sym_name: []const u8, origin: reader_mod.SrcSpan) ExpandError!*Form {
    const f = try ctx.allocator.create(Form);
    f.* = .{
        .datum = .{ .symbol = .{ .ns = ns_name, .name = sym_name } },
        .origin = origin,
    };
    return f;
}

/// Helper: make an empty map literal `{}` Form.
fn makeEmptyMap(ctx: *ExpandContext, origin: reader_mod.SrcSpan) ExpandError!*Form {
    const f = try ctx.allocator.create(Form);
    const items = try ctx.allocator.alloc(*Form, 0);
    f.* = .{
        .datum = .{ .map = items },
        .origin = origin,
    };
    return f;
}

/// Helper: make a list from inline slice (allocates the items
/// array, copies the inputs, returns the list Form). Convenience
/// for the long sequence of `try ctx.allocator.alloc(*Form, N); items[0] = ...`
/// patterns this file would otherwise need.
fn makeListInline(ctx: *ExpandContext, origin: reader_mod.SrcSpan, items: []const *Form) ExpandError!*Form {
    const buf = try ctx.allocator.alloc(*Form, items.len);
    for (items, 0..) |it, i| buf[i] = it;
    return try makeList(ctx, buf, origin);
}

/// The no-match fallthrough of `case` and `condp`:
/// `(throw {:error :no-matching-clause :message (nexis.core/str
/// "No matching clause: " g) :value g})`, `g` being the symbol the
/// dispatch value is bound to. `str` is qualified so a lexical
/// `str` cannot capture it.
fn makeNoMatchThrow(ctx: *ExpandContext, g_name: []const u8, origin: reader_mod.SrcSpan) ExpandError!*Form {
    const str_items = try ctx.allocator.alloc(*Form, 3);
    str_items[0] = try makeQualifiedSymbol(ctx, "nexis.core", "str", origin);
    const prefix = try ctx.allocator.create(Form);
    prefix.* = .{ .datum = .{ .string = "No matching clause: " }, .origin = origin };
    str_items[1] = prefix;
    str_items[2] = try makeSymbol(ctx, g_name, origin);

    const map_items = try ctx.allocator.alloc(*Form, 6);
    map_items[0] = try makeKeyword(ctx, "error", origin);
    map_items[1] = try makeKeyword(ctx, "no-matching-clause", origin);
    map_items[2] = try makeKeyword(ctx, "message", origin);
    map_items[3] = try makeList(ctx, str_items, origin);
    map_items[4] = try makeKeyword(ctx, "value", origin);
    map_items[5] = try makeSymbol(ctx, g_name, origin);
    const map_form = try ctx.allocator.create(Form);
    map_form.* = .{ .datum = .{ .map = @as([]const *Form, map_items) }, .origin = origin };

    const items = try ctx.allocator.alloc(*Form, 2);
    items[0] = try makeSymbol(ctx, "throw", origin);
    items[1] = map_form;
    return try makeList(ctx, items, origin);
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
    // A non-list step `f` → (f acc): a symbol, or a keyword /
    // other invocable value (`(-> m :a :b)`).
    if (step.datum != .list) {
        const items = try ctx.allocator.alloc(*Form, 2);
        items[0] = @constCast(step);
        items[1] = acc;
        return try makeList(ctx, items, call_form.origin);
    }
    // List step (f a b) → thread-first: (f acc a b)
    //                      thread-last:  (f a b acc)
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

// =============================================================================
// Syntax-quote / unquote / unquote-splicing
// =============================================================================
//
// Per MACROEXPAND.md §5.
//
// `` `payload `` walks the payload, producing a Form that
// CONSTRUCTS the quoted shape at runtime via #%list / #%concat
// / #%vector.
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
//   vector         → expandSyntaxQuoteVector (`(#%vector ...)`,
//                    no splices)
//   map / set / quote / nested syntax-quote / anon_fn /
//   with_meta / deref → MalformedMacroCall (unsupported; a
//                    nested syntax-quote would need scope
//                    stacking)
//
// Auto-gensym scope lifecycle:
//   - Fresh GensymScope opened at every `Datum.syntax_quote`
//     entry: ONE scope per syntax-quote form. A nested
//     syntax-quote raises MalformedMacroCall before any inner
//     scope would open.
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
///
/// Symbols qualify as in Clojure (PLAN §23 #29): an unqualified
/// symbol becomes `ns/name` for the namespace that holds its Var
/// (the current namespace, one it refers to, or `nexis.core` for
/// a host macro), or `<current-ns>/name` when nothing holds it.
/// `name#` is an auto-gensym and stays bare; so do the special
/// forms, `&`, the catch matcher `any`, `#%` internals and the
/// `%` parameters of `#()`. A qualified symbol keeps its prefix,
/// with an alias resolved to the namespace it names. Without a
/// named namespace (a bare `Namespace` in tests) nothing qualifies.
fn expandSyntaxQuotePayload(
    ctx: *ExpandContext,
    scope: *GensymScope,
    call_form: *const Form,
    payload: *const Form,
) ExpandError!*Form {
    return switch (payload.datum) {
        // Self-evaluating leaves: pass through. Lowered as
        // existing Tiny variants — no quote wrap needed.
        .nil, .bool_, .int, .bigint, .real, .char, .string, .keyword => mutCast(payload),
        .symbol => |name| blk: {
            const sym_form = if (name.ns) |ns_prefix| lbl: {
                // An alias of the current namespace resolves to
                // the namespace it names, as `(require '[x :as
                // a])` intends; anything else passes through.
                const target = aliasTarget(ctx, ns_prefix);
                if (target.ptr == ns_prefix.ptr) break :lbl mutCast(payload);
                break :lbl try makeQualifiedSymbol(ctx, target, name.name, payload.origin);
            } else if (name.name.len > 1 and name.name[name.name.len - 1] == '#')
                try makeSymbol(ctx, try scope.lookupOrAllocate(ctx, name.name), payload.origin)
            else if (syntaxQuoteNamespace(ctx, name.name)) |ns_name|
                try makeQualifiedSymbol(ctx, ns_name, name.name, payload.origin)
            else
                mutCast(payload);
            // Emit (quote <sym>).
            const items = try ctx.allocator.alloc(*Form, 2);
            items[0] = try makeSymbol(ctx, "quote", call_form.origin);
            items[1] = sym_form;
            break :blk try makeList(ctx, items, call_form.origin);
        },
        // Unquote: return the payload directly; it goes through
        // normal expansion + evaluation on the outer walk.
        .unquote => |inner| mutCast(inner),
        // Splice outside a collection is illegal.
        .unquote_splicing => return ExpandError.MalformedMacroCall,
        .list => |items| try expandSyntaxQuoteColl(ctx, scope, call_form, items, payload.origin, .list_),
        .vector => |items| try expandSyntaxQuoteColl(ctx, scope, call_form, items, payload.origin, .vector_),
        .map => |items| try expandSyntaxQuoteColl(ctx, scope, call_form, items, payload.origin, .map_),
        .set => |items| try expandSyntaxQuoteColl(ctx, scope, call_form, items, payload.origin, .set_),
        // `'x` inside syntax-quote is the list `(quote x)` with
        // `x` walked like any payload, so `` `'a `` is
        // `(quote ns/a)` and `` `'~x `` is `(quote <x>)`.
        .quote => |inner| blk: {
            const quote_items = try ctx.allocator.alloc(*Form, 2);
            quote_items[0] = try makeSymbol(ctx, "quote", call_form.origin);
            quote_items[1] = try makeSymbol(ctx, "quote", call_form.origin);
            const seg_items = try ctx.allocator.alloc(*Form, 3);
            seg_items[0] = try makeSymbol(ctx, "#%list", payload.origin);
            seg_items[1] = try makeList(ctx, quote_items, call_form.origin);
            seg_items[2] = try expandSyntaxQuotePayload(ctx, scope, call_form, inner);
            break :blk try makeList(ctx, seg_items, payload.origin);
        },
        // `@x` inside syntax-quote is `(nexis.core/deref x)`.
        .deref => |inner| blk: {
            const quote_items = try ctx.allocator.alloc(*Form, 2);
            quote_items[0] = try makeSymbol(ctx, "quote", call_form.origin);
            quote_items[1] = try makeQualifiedSymbol(ctx, "nexis.core", "deref", call_form.origin);
            const seg_items = try ctx.allocator.alloc(*Form, 3);
            seg_items[0] = try makeSymbol(ctx, "#%list", payload.origin);
            seg_items[1] = try makeList(ctx, quote_items, call_form.origin);
            seg_items[2] = try expandSyntaxQuotePayload(ctx, scope, call_form, inner);
            break :blk try makeList(ctx, seg_items, payload.origin);
        },
        // `#(...)` inside syntax-quote is the `fn*` form it stands
        // for; its `%` parameters stay bare (see the symbol arm).
        .anon_fn => |items| try expandSyntaxQuotePayload(ctx, scope, call_form, try anonFnForm(ctx, payload, items)),
        // Nested syntax-quote and metadata are unsupported:
        // MalformedMacroCall, which the compile layer buckets as
        // MacroExpansionFailure.
        else => return ExpandError.MalformedMacroCall,
    };
}

/// Symbols syntax-quote leaves unqualified besides auto-gensyms:
/// the special forms the expander and compiler recognise by
/// name, `&` in a parameter vector, the catch matcher `any`, the
/// `#%` internals and the `%` parameters of `#()`.
fn isSyntaxQuoteBare(name: []const u8) bool {
    const bare = [_][]const u8{
        "quote", "if", "do", "let*", "loop*", "recur", "fn*", "letfn*", "def", "var", "set!", "try", "catch", "finally", "throw", "defmacro", "ns", "require", "&", "any",
    };
    for (bare) |b| if (std.mem.eql(u8, name, b)) return true;
    return std.mem.startsWith(u8, name, "#%") or std.mem.startsWith(u8, name, "%");
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

const SyntaxQuoteColl = enum { list_, vector_, map_, set_ };

/// Walk the items of a syntax-quoted collection. Runs of ordinary
/// elements become `(#%list ...)` segments and each `~@x` is its
/// own segment; with no splice the items build the collection
/// directly (`#%list` / `#%vector` / `#%map` / `#%set`), with a
/// splice they are concatenated at run time and a vector, map or
/// set is rebuilt from the resulting list through `nexis.core/vec`,
/// `nexis.core/hash-map` and `nexis.core/hash-set`.
fn expandSyntaxQuoteColl(
    ctx: *ExpandContext,
    scope: *GensymScope,
    call_form: *const Form,
    items: []const *Form,
    origin: reader_mod.SrcSpan,
    kind: SyntaxQuoteColl,
) ExpandError!*Form {
    var segments: std.ArrayList(*Form) = .empty;
    defer segments.deinit(ctx.allocator);
    var current: std.ArrayList(*Form) = .empty;
    defer current.deinit(ctx.allocator);
    var has_splice = false;

    for (items) |item| {
        if (item.datum == .unquote_splicing) {
            has_splice = true;
            try flushSyntaxQuoteSegment(ctx, &current, &segments, origin);
            try segments.append(ctx.allocator, mutCast(item.datum.unquote_splicing));
        } else {
            try current.append(ctx.allocator, try expandSyntaxQuotePayload(ctx, scope, call_form, item));
        }
    }

    if (!has_splice) {
        const head: []const u8 = switch (kind) {
            .list_ => "#%list",
            .vector_ => "#%vector",
            .map_ => "#%map",
            .set_ => "#%set",
        };
        const seg_items = try ctx.allocator.alloc(*Form, current.items.len + 1);
        seg_items[0] = try makeSymbol(ctx, head, origin);
        for (current.items, 0..) |it, i| seg_items[1 + i] = it;
        return try makeList(ctx, seg_items, origin);
    }

    try flushSyntaxQuoteSegment(ctx, &current, &segments, origin);
    const concat_items = try ctx.allocator.alloc(*Form, segments.items.len + 1);
    concat_items[0] = try makeSymbol(ctx, "#%concat", origin);
    for (segments.items, 0..) |seg, i| concat_items[1 + i] = seg;
    const concat = try makeList(ctx, concat_items, origin);
    return switch (kind) {
        .list_ => concat,
        .vector_ => try makeListInline(ctx, origin, &.{ try makeQualifiedSymbol(ctx, "nexis.core", "vec", origin), concat }),
        .map_ => try makeListInline(ctx, origin, &.{
            try makeQualifiedSymbol(ctx, "nexis.core", "apply", origin),
            try makeQualifiedSymbol(ctx, "nexis.core", "hash-map", origin),
            concat,
        }),
        .set_ => try makeListInline(ctx, origin, &.{
            try makeQualifiedSymbol(ctx, "nexis.core", "apply", origin),
            try makeQualifiedSymbol(ctx, "nexis.core", "hash-set", origin),
            concat,
        }),
    };
}

/// Move the pending ordinary elements into one `(#%list ...)`
/// segment; nothing pending, nothing emitted.
fn flushSyntaxQuoteSegment(ctx: *ExpandContext, current: *std.ArrayList(*Form), segments: *std.ArrayList(*Form), origin: reader_mod.SrcSpan) ExpandError!void {
    if (current.items.len == 0) return;
    const seg_items = try ctx.allocator.alloc(*Form, current.items.len + 1);
    seg_items[0] = try makeSymbol(ctx, "#%list", origin);
    for (current.items, 0..) |it, i| seg_items[1 + i] = it;
    try segments.append(ctx.allocator, try makeList(ctx, seg_items, origin));
    current.clearRetainingCapacity();
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
