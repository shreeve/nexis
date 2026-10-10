//! The macroexpander: Form → Form, between the reader and the
//! compiler (docs/MACROEXPAND.md). It walks a form by each special
//! form's traversal rule, expands macro calls (a user `defmacro` run
//! in a sub-VM, or a host macro of `defaultMacros`) until the head is
//! no macro, rewrites syntax-quote, `#()`, `@x` and `^meta` away, and
//! records why and where an expansion failed.

const std = @import("std");
const reader_mod = @import("reader.zig");
const intern_mod = @import("intern.zig");
const seq_mod = @import("seq.zig");
const lazy_mod = @import("coll/lazy.zig");
const vm_mod = @import("vm.zig");
const value_mod = @import("value.zig");
const list_mod = @import("coll/list.zig");
const vector_mod = @import("coll/vector.zig");
const champ_mod = @import("coll/champ.zig");
const sorted_mod = @import("coll/sorted.zig");
const heap_mod = @import("heap.zig");
const bignum_mod = @import("bignum.zig");
const stack = @import("stack.zig");
const string_mod = @import("string.zig");
const regex_mod = @import("regex.zig");
const dispatch = @import("dispatch.zig");

const Form = reader_mod.Form;
const Datum = reader_mod.Datum;
const SrcSpan = reader_mod.SrcSpan;
const Allocator = std.mem.Allocator;

// =============================================================================
// Types
// =============================================================================

/// Errors of macroexpansion; the compiler maps each to a
/// `CompileError` (COMPILER.md §7).
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

/// How `defmacro` compiles and runs the `(def name (fn* ...))` it
/// builds, already expanded (`compile.zig`, so the expander does not
/// depend on the compiler): `eval` returns the value of running
/// `form` in a sub-VM. A form that does not compile sets `failure`
/// when the compiler located it, with what it said (empty when it
/// said nothing).
pub const CompileEvalContext = struct {
    user_data: *anyopaque,
    eval: *const fn (user_data: *anyopaque, form: *const Form, failure: *?Failure) anyerror!value_mod.Value,
};

/// How `require` loads a namespace: the loader's, which finds,
/// reads, compiles and runs its file once.
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
    host_macros: *const HostMacroTable,
    /// Where user macros and Vars are looked up; null, in a test,
    /// for none.
    namespace: ?*vm_mod.Namespace = null,
    /// How `defmacro` runs its definition; null refuses `defmacro`.
    compile_eval: ?CompileEvalContext = null,
    /// What `ns` switches and `require` refers into; null refuses
    /// both.
    registry: ?*vm_mod.NamespaceRegistry = null,
    /// How `require` loads a namespace; null refuses loading.
    load_callback: ?LoadCallback = null,
    /// The VM heap macro arguments and quoted data are built on, so
    /// the values a macro's sub-VM makes live where Vars can hold
    /// them; null only in a test that turns no form into data.
    value_heap: ?*heap_mod.Heap = null,
    /// The calling VM's `io`, given to a user macro's sub-VM so the
    /// macro body can print; null leaves the sub-VM without one.
    io: ?std.Io = null,
    /// Set by the first (innermost) failure of an expansion that
    /// returns an error; the message lives in `allocator`.
    failure: ?Failure = null,
    /// The lexical names in scope where the walk is, each with how
    /// many enclosing binding forms bind it (`Scope`); empty at the
    /// top of a form.
    lexical: std.StringHashMapUnmanaged(u32) = .empty,
    /// While a user macro's call converts its arguments to data and
    /// its result back (`callUserMacro`): the span of each argument
    /// collection by its heap address, so a form of the result that is
    /// one of them keeps its own place and an error in it is reported
    /// there, not at the macro call.
    arg_spans: ?*std.AutoHashMapUnmanaged(u64, SrcSpan) = null,

    /// Whether `name` is bound by a binding form around the walk.
    fn isLexical(self: *const ExpandContext, name: []const u8) bool {
        return (self.lexical.get(name) orelse 0) > 0;
    }

    /// Record why expanding the form at `span` failed, unless an
    /// inner form already did, and return `err`.
    pub fn failWith(self: *ExpandContext, err: ExpandError, span: SrcSpan, comptime fmt: []const u8, args: anytype) ExpandError {
        if (self.failure == null) {
            const message = self.allocator.print(fmt, args) catch return ExpandError.OutOfMemory;
            self.failure = .{ .span = span, .message = message };
        }
        return err;
    }

    /// `failWith` for a malformed form.
    pub fn fail(self: *ExpandContext, span: SrcSpan, comptime fmt: []const u8, args: anytype) ExpandError {
        return self.failWith(ExpandError.MalformedMacroCall, span, fmt, args);
    }

    /// `value_heap`; a form cannot become data without one.
    fn heapForArgs(self: *ExpandContext) ExpandError!*heap_mod.Heap {
        return self.value_heap orelse ExpandError.MalformedMacroCall;
    }

    /// A fresh name `<base>__<N>__auto__` (MACROEXPAND.md §4) in
    /// `ctx.allocator`.
    pub fn gensym(self: *ExpandContext, base: []const u8) ExpandError![]const u8 {
        gensym_counter += 1;
        return self.allocator.print("{s}__{d}__auto__", .{ base, gensym_counter });
    }
};

/// The auto-gensym counter. A context lives for one top-level form,
/// but a name it generates may be defined as a Var that later forms
/// see, so the counter is process-wide (one isolate, one thread). A
/// boot from the stdlib image advances it as booting the sources
/// does (docs/STDLIB.md §1).
pub var gensym_counter: u64 = 0;

/// A host macro: the call form and its arguments to the form it
/// expands to, which is expanded again.
pub const MacroFn = *const fn (
    ctx: *ExpandContext,
    call_form: *const Form,
    args: []const *Form,
) ExpandError!*Form;

/// The host macros by name (`defaultMacros`); empty in a test of
/// expansion without them.
pub const HostMacroTable = std.StringHashMapUnmanaged(MacroFn);

/// The names one binding form (`let*`, `loop*`, `fn*`, `letfn*`, a
/// `catch`) puts in scope for the forms inside it (§3): it adds them
/// to `ExpandContext.lexical` and takes them out again when it
/// closes, so whether a name is lexical is one lookup however deep
/// the forms nest.
const Scope = struct {
    ctx: *ExpandContext,
    added: std.ArrayList([]const u8) = .empty,

    fn bind(self: *Scope, name: []const u8) ExpandError!void {
        try self.added.ensureUnusedCapacity(self.ctx.allocator, 1);
        const entry = try self.ctx.lexical.getOrPut(self.ctx.allocator, name);
        entry.value_ptr.* = if (entry.found_existing) entry.value_ptr.* + 1 else 1;
        self.added.appendAssumeCapacity(name);
    }

    fn close(self: *Scope) void {
        for (self.added.items) |name| self.ctx.lexical.getPtr(name).?.* -= 1;
        self.added.deinit(self.ctx.allocator);
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

/// `form` with every macro call in it expanded (§2), sharing the
/// subtrees that did not change.
pub fn expandForm(ctx: *ExpandContext, form: *const Form) ExpandError!*Form {
    return expandFormDepth(ctx, form, 0);
}

/// One macro step, the way `macroexpand-1` sees it: when `form` is
/// a call whose head names a user or host macro (special forms and
/// the `#%` primitives are not macros), the macro's raw output;
/// otherwise null. Nothing inside the result is expanded and no
/// lexical environment applies: the form is top-level data.
pub fn expandOnce(ctx: *ExpandContext, form: *const Form) ExpandError!?*Form {
    if (form.datum != .list) return null;
    const items = form.datum.list;
    const macro = findMacro(ctx, items) orelse return null;
    return try callMacro(ctx, macro, form, items);
}

/// `form` expanded by `expandOnce` until its head names no macro: a
/// top-level form as a loader or `eval` takes it (§2b, the loader).
pub fn expandHead(ctx: *ExpandContext, form: *const Form) ExpandError!*Form {
    var f = mutCast(form);
    var depth: u32 = 0;
    while (try expandOnce(ctx, f)) |next| : (depth += 1) {
        if (depth == MAX_EXPANSION_DEPTH) return ctx.failWith(ExpandError.ExpansionDepthExceeded, form.origin, "macro expansion did not finish after {d} expansions in a row", .{MAX_EXPANSION_DEPTH});
        f = next;
    }
    return f;
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
fn findMacro(ctx: *ExpandContext, items: []const *Form) ?Macro {
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
    if (ctx.isLexical(head.name)) return null;
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

const SpecialForm = *const fn (ctx: *ExpandContext, list_form: *const Form, items: []const *Form) ExpandError!*Form;

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
fn expandFormDepth(ctx: *ExpandContext, form: *const Form, depth: u32) ExpandError!*Form {
    if (depth > MAX_EXPANSION_DEPTH) return ctx.failWith(ExpandError.ExpansionDepthExceeded, form.origin, "macro expansion did not finish after {d} expansions in a row", .{MAX_EXPANSION_DEPTH});
    try checkStack();
    const b = Builder{ .ctx = ctx, .origin = form.origin };
    return switch (form.datum) {
        .nil, .bool_, .int, .bigint, .real, .char, .string, .regex, .keyword, .symbol => mutCast(form),
        .list => |items| try expandList(ctx, form, items, depth),
        // Collection literals are expressions: their items expand.
        .vector, .map, .set => try mapChildren(ctx, form, Walk{}),
        // Opaque (§7): `(quote (when x y))` does not expand `when`.
        .quote => mutCast(form),
        // §5: the construction form, then expanded like any form so
        // macros in the unquoted parts fire.
        .syntax_quote => |payload| blk: {
            var scope = GensymScope{};
            defer scope.deinit(ctx.allocator);
            break :blk try expandFormDepth(ctx, try syntaxQuote(ctx, &scope, payload), depth);
        },
        // The reader refuses these outside syntax-quote; a macro
        // could still produce one.
        .unquote, .unquote_splicing => ctx.fail(form.origin, "{s} outside syntax-quote", .{describeForm(form)}),
        .anon_fn => |items| try expandFormDepth(ctx, try anonFnForm(ctx, form, items), depth),
        // `^meta` on a collection literal attaches to the value, as
        // `with-meta` does; on anything else (a symbol, a call) it
        // is a hint and is dropped.
        .with_meta => |wm| switch (wm.target.datum) {
            .vector, .map, .set => try b.list(.{
                "nexis.core/with-meta",
                try expandForm(ctx, wm.target),
                try expandForm(ctx, try metaMapExpr(ctx, wm.meta.datum.map, wm.meta.origin)),
            }),
            else => try expandFormDepth(ctx, wm.target, depth),
        },
        // `@x` is `(nexis.core/deref x)`, qualified so that neither a
        // local nor a Var named `deref` captures it.
        .deref => |inner| try b.list(.{ "nexis.core/deref", try expandForm(ctx, inner) }),
    };
}

/// A form passed through unchanged: no stage writes a Form once
/// it is built.
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
fn expandList(ctx: *ExpandContext, list_form: *const Form, items: []const *Form, depth: u32) ExpandError!*Form {
    return dispatchList(ctx, list_form, items, depth) catch |err| {
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
fn dispatchList(ctx: *ExpandContext, list_form: *const Form, items: []const *Form, depth: u32) ExpandError!*Form {
    if (items.len > 0 and items[0].datum == .symbol and items[0].datum.symbol.ns == null) {
        if (special_forms.get(items[0].datum.symbol.name)) |walk| return walk(ctx, list_form, items);
    }
    if (findMacro(ctx, items)) |macro| {
        return expandFormDepth(ctx, try callMacro(ctx, macro, list_form, items), depth + 1);
    }
    return mapChildren(ctx, list_form, Walk{});
}

/// The namespace name `ns_prefix` stands for: the target of an
/// alias registered in the current namespace, else itself, either
/// one through `canonicalNs`.
fn aliasTarget(ctx: *ExpandContext, ns_prefix: []const u8) []const u8 {
    const cur = ctx.namespace orelse return canonicalNs(ns_prefix);
    return canonicalNs(cur.lookupAlias(ns_prefix) orelse ns_prefix);
}

/// The namespace `name` names: `clojure.core` is a permanent name for
/// `nexis.core` (STDLIB.md §1), any other name is itself.
pub fn canonicalNs(name: []const u8) []const u8 {
    return if (std.mem.eql(u8, name, "clojure.core")) "nexis.core" else name;
}

// =============================================================================
// Per-special-form walkers (MACROEXPAND.md §2b)
// =============================================================================

/// `quote` and `var`: nothing inside is expanded.
fn opaqueForm(_: *ExpandContext, list_form: *const Form, _: []const *Form) ExpandError!*Form {
    return mutCast(list_form);
}

/// `do`, `recur`, `throw` and a call: every sub-form expands in the
/// same scope.
fn walkCall(ctx: *ExpandContext, list_form: *const Form, _: []const *Form) ExpandError!*Form {
    return mapChildren(ctx, list_form, Walk{});
}

fn expandIf(ctx: *ExpandContext, list_form: *const Form, items: []const *Form) ExpandError!*Form {
    if (items.len < 3 or items.len > 4) return ctx.fail(list_form.origin, "if: expected a test, a then and an optional else", .{});
    return mapChildren(ctx, list_form, Walk{});
}

/// `let*` / `loop*`: each value expands with the names bound before
/// it in scope, the body with all of them; the names do not expand,
/// and lose any `^hint`.
fn expandLetStar(ctx: *ExpandContext, list_form: *const Form, items: []const *Form) ExpandError!*Form {
    const head = items[0].datum.symbol.name;
    const bindings = try ctx.allocator.dupe(*Form, try bindingVector(ctx, list_form, items));
    var scope: Scope = .{ .ctx = ctx };
    defer scope.close();
    var i: usize = 0;
    while (i < bindings.len) : (i += 2) {
        const name = stripMeta(bindings[i]);
        if (name.datum != .symbol or name.datum.symbol.ns != null) return ctx.fail(name.origin, "{s}: cannot bind {s}", .{ head, describeForm(name) });
        bindings[i] = name;
        bindings[i + 1] = try expandForm(ctx, bindings[i + 1]);
        try scope.bind(name.datum.symbol.name);
    }
    return (Builder{ .ctx = ctx, .origin = list_form.origin }).list(.{
        items[0],
        try makeVector(ctx, bindings, items[1].origin),
        try expandAll(ctx, items[2..]),
    });
}

/// The binding vector of a `(let [n v ...] ...)`-shaped form: a
/// vector of name/value pairs, any `^meta` on it dropped.
fn bindingVector(ctx: *ExpandContext, list_form: *const Form, items: []const *Form) ExpandError![]const *Form {
    const head = if (items[0].datum == .symbol) items[0].datum.symbol.name else "";
    if (items.len < 2 or stripMeta(items[1]).datum != .vector) return ctx.fail(list_form.origin, "{s}: expected a binding vector", .{head});
    const bindings = stripMeta(items[1]).datum.vector;
    if (bindings.len % 2 != 0) return ctx.fail(items[1].origin, "{s}: the binding vector needs an even number of forms", .{head});
    return bindings;
}

/// Put the plain names of a parameter vector (not `&`) in `scope`.
fn bindParams(scope: *Scope, params: []const *Form) ExpandError!void {
    for (params) |p| {
        if (p.datum != .symbol or p.datum.symbol.ns != null or isSym(p, "&")) continue;
        try scope.bind(p.datum.symbol.name);
    }
}

/// `(fn* name? [params] body...)` or `(fn* name? ([params] body...)+)`:
/// each body expands with the name and its clause's parameters in
/// scope; a parameter vector does not expand and loses its hints.
fn expandFnStar(ctx: *ExpandContext, list_form: *const Form, items: []const *Form) ExpandError!*Form {
    const name: []const *Form = if (items.len > 1 and items[1].datum == .symbol) items[1..2] else &.{};
    const rest = items[1 + name.len ..];
    if (rest.len == 0) return ctx.fail(list_form.origin, "fn*: expected a parameter vector", .{});
    const b = Builder{ .ctx = ctx, .origin = list_form.origin };
    if (rest[0].datum != .list) return b.list(.{ items[0], name, try fnStarClause(ctx, name, rest) });
    const clauses = try ctx.allocator.alloc(*Form, rest.len);
    for (rest, clauses) |clause, *out| {
        if (clause.datum != .list or clause.datum.list.len == 0) return ctx.fail(clause.origin, "fn*: expected a clause ([params] body...), not {s}", .{describeForm(clause)});
        out.* = try makeList(ctx, try fnStarClause(ctx, name, clause.datum.list), clause.origin);
    }
    return b.list(.{ items[0], name, clauses });
}

/// `[params] body...` of a `fn*` with `body` expanded.
fn fnStarClause(ctx: *ExpandContext, name: []const *Form, forms: []const *Form) ExpandError![]*Form {
    const params = try stripParams(ctx, forms[0]);
    if (params.datum != .vector) return ctx.fail(params.origin, "fn*: expected a parameter vector, not {s}", .{describeForm(params)});
    var scope: Scope = .{ .ctx = ctx };
    defer scope.close();
    try bindParams(&scope, name);
    try bindParams(&scope, params.datum.vector);
    return (Builder{ .ctx = ctx, .origin = forms[0].origin }).items(.{ params, try expandAll(ctx, forms[1..]) });
}

/// `(letfn* [(name params-or-clauses body...) ...] body...)`: every
/// name is in scope in every fn body and in the letfn body; an entry
/// goes through the `fn` expansion first, so overload clauses and
/// destructuring work as for `fn`.
fn expandLetFnStar(ctx: *ExpandContext, list_form: *const Form, items: []const *Form) ExpandError!*Form {
    if (items.len < 2 or items[1].datum != .vector) return ctx.fail(list_form.origin, "letfn*: expected a vector of fn bindings", .{});
    const entries = items[1].datum.vector;
    var scope: Scope = .{ .ctx = ctx };
    defer scope.close();
    for (entries) |entry| {
        if (entry.datum != .list or entry.datum.list.len < 2) return ctx.fail(entry.origin, "letfn*: expected (name [params] body...), not {s}", .{describeForm(entry)});
        _ = try plainName(ctx, entry.datum.list[0], "letfn*: a name");
        try bindParams(&scope, entry.datum.list[0..1]);
    }
    const new_entries = try ctx.allocator.alloc(*Form, entries.len);
    for (entries, new_entries) |entry, *out| {
        // The entry as `(fn* name [params] body...)`, expanded with
        // every name in scope, is `(name [params] body...)` behind its
        // head.
        const fn_form = try expandFnStar(ctx, entry, (try expandFnRename(ctx, entry, entry.datum.list)).datum.list);
        out.* = try makeList(ctx, fn_form.datum.list[1..], entry.origin);
    }
    return (Builder{ .ctx = ctx, .origin = list_form.origin }).list(.{
        items[0],
        try makeVector(ctx, new_entries, items[1].origin),
        try expandAll(ctx, items[2..]),
    });
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
        .regex => "a regex",
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

fn expandDef(ctx: *ExpandContext, list_form: *const Form, items: []const *Form) ExpandError!*Form {
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
    const value = try expandAll(ctx, if (items.len == 2) &.{} else items[items.len - 1 ..]);
    const def_form = try b.list(.{ items[0], named.name, value });
    var meta: std.ArrayList(*Form) = .empty;
    if (named.meta) |m| try meta.appendSlice(ctx.allocator, m);
    if (items.len == 4) try meta.appendSlice(ctx.allocator, &.{ try b.kw("doc"), items[2] });
    // Every Var knows its name and namespace, as in Clojure.
    if (ctx.namespace) |ns| if (ns.name.len > 0) try meta.appendSlice(ctx.allocator, &.{
        try b.kw("name"),
        try b.list(.{ "quote", named.name }),
        try b.kw("ns"),
        try b.list(.{ "quote", try makeSymbol(ctx, ns.name, b.origin) }),
    });
    return withVarMeta(ctx, def_form, meta.items, list_form.origin);
}

/// Each of `forms` expanded.
fn expandAll(ctx: *ExpandContext, forms: []const *Form) ExpandError![]*Form {
    const out = try ctx.allocator.alloc(*Form, forms.len);
    for (forms, out) |f, *o| o.* = try expandForm(ctx, f);
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
    // `user/x` in `user` is `x`, as Clojure takes it.
    if (target.datum == .symbol) if (target.datum.symbol.ns) |prefix| if (ctx.namespace) |ns| if (std.mem.eql(u8, prefix, ns.name))
        return .{ .name = try makeSymbol(ctx, target.datum.symbol.name, target.origin), .meta = meta };
    if (target.datum != .symbol or target.datum.symbol.ns != null) return ctx.fail(form.origin, "the name defined must be an unqualified symbol, not {s}", .{describeForm(target)});
    return .{ .name = target, .meta = meta };
}

/// `name` carrying the map of `meta_items` as `^meta`, which `def`
/// puts on the Var; `name` itself without any.
fn withMetaMap(b: Builder, name: *const Form, meta_items: []const *Form) ExpandError!*Form {
    if (meta_items.len == 0) return mutCast(name);
    return makeForm(b.ctx, .{ .with_meta = .{ .target = mutCast(name), .meta = try b.map(.{meta_items}) } }, b.origin);
}

/// The map literal `{k v ...}` of `meta_items` as an expression: a
/// symbol under `:tag` (a type hint, `^String x`) and the vector under
/// `:param-tags` (`^[long] f`) are quoted, since they name classes
/// nexis does not have.
fn metaMapExpr(ctx: *ExpandContext, meta_items: []const *Form, origin: SrcSpan) ExpandError!*Form {
    const b = Builder{ .ctx = ctx, .origin = origin };
    const items = try ctx.allocator.dupe(*Form, meta_items);
    var i: usize = 1;
    while (i < items.len) : (i += 2) {
        const hint = (isKw(items[i - 1], "tag") and items[i].datum == .symbol) or
            (isKw(items[i - 1], "param-tags") and items[i].datum == .vector);
        if (hint) items[i] = try b.list(.{ "quote", items[i] });
    }
    return b.map(.{items});
}

/// `def_form` (a `def`, which yields its Var) wrapped so the Var then
/// carries the map built from `meta_items` (flat k v ...), expanded
/// here:
///   (let* [v# def_form] (nexis.core/reset-meta! v# {k v ...}) v#)
/// No items: `def_form` itself.
fn withVarMeta(ctx: *ExpandContext, def_form: *Form, meta_items: []const *Form, origin: SrcSpan) ExpandError!*Form {
    if (meta_items.len == 0) return def_form;
    const b = Builder{ .ctx = ctx, .origin = origin };
    const v = try b.gensym("nx");
    const meta = try expandForm(ctx, try metaMapExpr(ctx, meta_items, origin));
    return b.list(.{ "let*", try b.vec(.{ v, def_form }), try b.list(.{ "nexis.core/reset-meta!", v, meta }), v });
}

/// `(try body* (catch MATCHER BINDING handler*)* (finally body*)?)`
/// onto the compiler's primitive, which takes exactly one `(catch any
/// g ...)` whose handler tries the clauses in order and rethrows a
/// value none takes (§2b, `try`). The body, each handler and the
/// finally body expand; matchers and bindings do not.
fn expandTry(ctx: *ExpandContext, list_form: *const Form, items: []const *Form) ExpandError!*Form {
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
    const new_body = try expandAll(ctx, body);
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
        var scope: Scope = .{ .ctx = ctx };
        defer scope.close();
        try scope.bind(binding.datum.symbol.name);
        const clause_body = try b.list(.{ "let*", try b.vec(.{ binding, g }), try expandAll(ctx, clause[3..]) });
        const test_form = switch (matcher.datum) {
            .keyword => if (isKw(matcher, "default")) null else try catchTest(b, g, matcher),
            // `(if (#%catch-matches? g t1) true ... (#%catch-matches? g tn))`
            .symbol => |sym| if ((if (sym.ns == null) catchTags(sym.name) else null)) |tags| blk: {
                var chain = try catchTest(b, g, try b.kw(tags[tags.len - 1]));
                var t = tags.len - 1;
                while (t > 0) {
                    t -= 1;
                    chain = try b.list(.{ "if", try catchTest(b, g, try b.kw(tags[t])), true, chain });
                }
                break :blk chain;
            } else null,
            else => return ctx.fail(matcher.origin, "catch: expected any, a class name or a keyword tag, not {s}", .{describeForm(matcher)}),
        };
        handler = if (test_form) |tf| try b.list(.{ "if", tf, clause_body, handler }) else clause_body;
    }
    const catch_form = try b.list(.{ "catch", "any", g, handler });
    if (finally_form) |ff| {
        const fin = ff.datum.list;
        return b.list(.{ items[0], new_body, catch_form, try makeList(ctx, try b.items(.{ fin[0], try expandAll(ctx, fin[1..]) }), ff.origin) });
    }
    return b.list(.{ items[0], new_body, catch_form });
}

/// `(nexis.internal/#%catch-matches? g tag)`.
fn catchTest(b: Builder, g: *Form, tag: *const Form) ExpandError!*Form {
    return b.list(.{ "nexis.internal/#%catch-matches?", g, tag });
}

/// The error tags a Clojure exception class stands for, so a clause
/// written for Clojure takes the nexis errors that class names (an
/// arithmetic error is `:divide-by-zero`); null for any other class,
/// which takes every value.
fn catchTags(name: []const u8) ?[]const []const u8 {
    const classes = std.StaticStringMap([]const []const u8).initComptime(.{
        .{ "ArithmeticException", &[_][]const u8{ "divide-by-zero", "arithmetic-overflow" } },
        .{ "IndexOutOfBoundsException", &[_][]const u8{"index-out-of-bounds"} },
        .{ "ArrayIndexOutOfBoundsException", &[_][]const u8{"index-out-of-bounds"} },
        .{ "StringIndexOutOfBoundsException", &[_][]const u8{"index-out-of-bounds"} },
        .{ "ClassCastException", &[_][]const u8{ "kind-mismatch", "not-callable" } },
        .{ "IllegalArgumentException", &[_][]const u8{ "invalid-argument", "no-matching-clause", "arity-mismatch", "no-method", "ambiguous-method" } },
        .{ "IllegalStateException", &[_][]const u8{"preference-conflict"} },
        .{ "ArityException", &[_][]const u8{"arity-mismatch"} },
        .{ "AssertionError", &[_][]const u8{"assertion-failed"} },
        .{ "StackOverflowError", &[_][]const u8{"stack-overflow"} },
    });
    return classEntry([]const []const u8, classes, name);
}

/// The entry of `classes` for a Clojure class name, bare or under
/// `java.lang.`, `java.util.` or `clojure.lang.`.
fn classEntry(comptime V: type, classes: std.StaticStringMap(V), name: []const u8) ?V {
    for ([_][]const u8{ "java.lang.", "java.util.", "clojure.lang." }) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) return classes.get(name[prefix.len..]);
    }
    return classes.get(name);
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
    for (params[0..anon.max_positional], 1..) |*p, n| p.* = try makeSymbol(ctx, try ctx.allocator.print("%{d}", .{n}), origin);
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
                } else if (for (name[1..]) |c| {
                    if (!std.ascii.isDigit(c)) break false;
                } else true) {
                    const n = std.fmt.parseUnsigned(u32, name[1..], 10) catch std.math.maxInt(u32);
                    if (n == 0 or n > 1000) return ctx.fail(form.origin, "#(): no parameter {s}", .{name});
                    self.max_positional = @max(self.max_positional, n);
                }
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
/// of calls, `do`, `if`, `recur` and collection literals, all in one
/// scope.
const Walk = struct {
    fn visit(_: Walk, ctx: *ExpandContext, form: *const Form) ExpandError!*Form {
        return expandForm(ctx, form);
    }
};

// =============================================================================
// Namespaces, require, set!, defmacro and user-macro calls
// =============================================================================
//
// `ns`, `require` and `defmacro` take effect at expansion time, so
// the forms after them in the same file see them (§2b).

/// `(ns NAME docstring? attr-map? clause*)`, at expansion time, and
/// replaced by nil (§2b).
fn expandNs(ctx: *ExpandContext, list_form: *const Form, items: []const *Form) ExpandError!*Form {
    const origin = list_form.origin;
    if (items.len < 2) return ctx.fail(origin, "ns: expected a namespace name", .{});
    const name_form = stripMeta(items[1]);
    if (name_form.datum != .symbol or name_form.datum.symbol.ns != null) return ctx.fail(name_form.origin, "ns: the name must be an unqualified symbol, not {s}", .{describeForm(name_form)});
    const reg = ctx.registry orelse return ctx.fail(origin, "ns: namespaces cannot be switched here", .{});
    var clauses = items[2..];
    if (clauses.len > 0 and clauses[0].datum == .string) clauses = clauses[1..];
    if (clauses.len > 0 and clauses[0].datum == .map) clauses = clauses[1..];
    // Every clause is checked, its options and specs included, before
    // the namespace switches, so a bad one leaves the program where it
    // was. A namespace that does not load fails after the switch, as
    // Clojure's `ns` fails after its `in-ns`.
    try nsClauses(ctx, reg, clauses, .check);
    reg.switchTo(name_form.datum.symbol.name) catch return ExpandError.OutOfMemory;
    try nsClauses(ctx, reg, clauses, .apply);
    return try makeNil(ctx, origin);
}

/// Check or carry out the clauses of an `ns`.
fn nsClauses(ctx: *ExpandContext, reg: *vm_mod.NamespaceRegistry, clauses: []const *Form, step: Step) ExpandError!void {
    for (clauses) |clause| {
        const clause_items: []const *Form = if (clause.datum == .list) clause.datum.list else &.{};
        if (clause_items.len == 0 or clause_items[0].datum != .keyword) return ctx.fail(clause.origin, "ns: expected a clause like (:require ...), not {s}", .{describeForm(clause)});
        const kind = clause_items[0].datum.keyword.name;
        if (std.mem.eql(u8, kind, "require")) {
            for (clause_items[1..]) |spec| try requireSpec(ctx, spec, step);
        } else if (std.mem.eql(u8, kind, "refer-clojure")) {
            try referClojure(ctx, reg, clause_items[1..], step);
        } else if (!std.mem.eql(u8, kind, "gen-class")) {
            return ctx.fail(clause.origin, "ns: (:{s} ...) is not supported", .{kind});
        }
    }
}

/// The options of `(:refer-clojure ...)`: `:exclude [names]` makes
/// each name the current namespace's own (an unbound Var until the
/// namespace defines it), so it neither resolves to nor inlines nor
/// expands as `nexis.core`'s; `nexis.core/name` still reaches it.
fn referClojure(ctx: *ExpandContext, reg: *vm_mod.NamespaceRegistry, opts: []const *Form, step: Step) ExpandError!void {
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
            if (step == .check) continue;
            if (!shadowsCore(ctx, reg, name) or reg.current.lookupLocal(name) != null) continue;
            _ = reg.current.intern(name) catch return ExpandError.OutOfMemory;
        }
    }
}

/// `(require spec*)` loads and refers at expansion time, through
/// `ctx.load_callback`, and is replaced by nil (§2b). What a
/// namespace name loads is the loader's.
fn expandRequire(ctx: *ExpandContext, list_form: *const Form, items: []const *Form) ExpandError!*Form {
    if (items.len < 2) return ctx.fail(list_form.origin, "require: expected a namespace", .{});
    for (items[1..]) |spec| try requireSpec(ctx, spec, .apply);
    return try makeNil(ctx, list_form.origin);
}

/// Whether a `require` spec or an `ns` clause is only checked, its
/// shape and options, or carried out.
const Step = enum { check, apply };

/// Load and refer one `require` spec (see `expandRequire`), or only
/// check it.
fn requireSpec(ctx: *ExpandContext, quoted: *const Form, step: Step) ExpandError!void {
    const spec = unwrapQuote(quoted);
    if (prefixList(spec)) |items| return requirePrefixList(ctx, items, step);
    const opts: []const *Form = switch (spec.datum) {
        .keyword => return,
        .symbol => &.{},
        .vector => |v| if (v.len > 0) v[1..] else return ctx.fail(spec.origin, "require: an empty spec", .{}),
        else => return ctx.fail(spec.origin, "require: expected a namespace symbol or [name options...], not {s}", .{describeForm(spec)}),
    };
    const name_form = if (spec.datum == .vector) spec.datum.vector[0] else spec;
    if (name_form.datum != .symbol or name_form.datum.symbol.ns != null) return ctx.fail(name_form.origin, "require: the namespace must be an unqualified symbol, not {s}", .{describeForm(name_form)});
    const ns_name = canonicalNs(name_form.datum.symbol.name);
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
            const all = isKw(val, "all");
            if (val.datum != .vector and !all) return ctx.fail(val.origin, "require: :refer takes a vector of names or :all, not {s}", .{describeForm(val)});
            if (!all) for (val.datum.vector) |sym| {
                if (sym.datum != .symbol or sym.datum.symbol.ns != null) return ctx.fail(sym.origin, "require: :refer names symbols, not {s}", .{describeForm(sym)});
            };
            refer = val;
        } else if (std.mem.eql(u8, k, "rename")) {
            if (val.datum != .map) return ctx.fail(val.origin, "require: :rename takes a map, not {s}", .{describeForm(val)});
            rename = val.datum.map;
        } else {
            return ctx.fail(key.origin, "require: unknown option {s}", .{if (k.len > 0) k else describeForm(key)});
        }
    }
    if (step == .check) return;

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
fn requirePrefixList(ctx: *ExpandContext, items: []const *Form, step: Step) ExpandError!void {
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
        if (std.mem.findScalar(u8, name, '.') != null) return ctx.fail(name_form.origin, "require: {s} is under the prefix {s}, so it cannot contain a period", .{ name, prefix.datum.symbol.name });
        const full = try makeSymbol(ctx, try ctx.allocator.print("{s}.{s}", .{ prefix.datum.symbol.name, name }), name_form.origin);
        if (suffix.datum == .symbol) {
            try requireSpec(ctx, full, step);
        } else {
            const v = try ctx.allocator.dupe(*Form, suffix.datum.vector);
            v[0] = full;
            try requireSpec(ctx, try makeVector(ctx, v, suffix.origin), step);
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

/// Whether `name` is one `nexis.core` or the host macro table holds:
/// one `(:refer-clojure :exclude ...)` makes the namespace's own.
fn shadowsCore(ctx: *ExpandContext, reg: *vm_mod.NamespaceRegistry, name: []const u8) bool {
    return reg.core.lookupLocal(name) != null or ctx.host_macros.get(name) != null;
}

/// Map `name` in `ns` to the Var `v` of another namespace. A name
/// that already maps to a Var of `ns` itself is a conflict, as in
/// Clojure, unless that Var is what `:exclude` interned for a core
/// name and nothing has bound it since: Clojure maps an excluded name
/// to nothing, so its referral is the standard way to replace a core
/// name. One that already refers to `v` stays.
fn referVar(ctx: *ExpandContext, ns: *vm_mod.Namespace, v: *vm_mod.Var, name: []const u8, span: SrcSpan) ExpandError!void {
    if (ns.vars.getEntry(name)) |existing| {
        if (existing.value_ptr.* == v) return;
        if (isOwnVar(existing)) {
            const own = existing.value_ptr.*;
            const excluded = !own.bound and !own.macro and if (ctx.registry) |reg| shadowsCore(ctx, reg, name) else false;
            if (!excluded) return ctx.fail(span, "require: {s} is already defined in {s}", .{ name, ns.name });
            existing.value_ptr.* = v;
            return;
        }
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
        .list => |items| if (items.len == 2 and isSym(items[0], "quote")) items[1] else form,
        else => form,
    };
}

/// `(set! target v)` rebinds the innermost thread binding of the
/// dynamic Var `target` names: it expands to
/// `(nexis.core/var-set (var target) v)`. A target that is a
/// lexical name is refused here, at compile time, because a local
/// has no binding to rebind (VM.md §6.5).
fn expandSetBang(ctx: *ExpandContext, list_form: *const Form, items: []const *Form) ExpandError!*Form {
    if (items.len != 3) return ctx.fail(list_form.origin, "set!: expected a Var name and a value", .{});
    const target = items[1];
    if (target.datum != .symbol) return ctx.fail(target.origin, "set!: expected a Var name, not {s}", .{describeForm(target)});
    if (target.datum.symbol.ns == null and ctx.isLexical(target.datum.symbol.name)) {
        return ctx.fail(target.origin, "set!: {s} is a local, not a Var", .{target.datum.symbol.name});
    }
    const b = Builder{ .ctx = ctx, .origin = list_form.origin };
    return b.list(.{ "nexis.core/var-set", try b.list(.{ "var", target }), try expandForm(ctx, items[2]) });
}

/// `(defmacro NAME ...)`, spelled like `defn` (docstring, attribute
/// map, destructuring, overload clauses), runs at expansion time:
/// `(def NAME (fn NAME ...))`, fully expanded, is compiled and run
/// through `ctx.compile_eval`, and the Var it yields is marked a
/// macro. The form is replaced by `(var NAME)`.
fn expandDefmacro(ctx: *ExpandContext, list_form: *const Form, items: []const *Form) ExpandError!*Form {
    const origin = list_form.origin;
    const parts = try defnParts(ctx, list_form, items[1..], false);
    const name = parts.name.datum.symbol.name;
    const ceval = ctx.compile_eval orelse return ctx.fail(origin, "defmacro {s}: macros cannot be defined here", .{name});
    const b = Builder{ .ctx = ctx, .origin = origin };
    // The Var's metadata says it is a macro, as Clojure's does.
    const meta = try std.mem.concat(ctx.allocator, *Form, &.{ parts.meta, &.{ try b.kw("macro"), try b.item(true) } });
    const expanded = try expandForm(ctx, try defnDef(b, parts, meta));

    var why: ?Failure = null;
    const result = ceval.eval(ceval.user_data, expanded, &why) catch |err| {
        if (err == error.OutOfMemory) return ExpandError.OutOfMemory;
        const at = if (why) |w| w.span else origin;
        if (why) |w| if (w.message.len > 0) return ctx.fail(at, "defmacro {s}: {s}", .{ name, w.message });
        return ctx.fail(at, "defmacro {s}: the macro function did not compile: {s}", .{ name, @errorName(err) });
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
    // The closure's routine, or a member of its arity table, takes
    // the count (docs/VM.md §6).
    const routine = vm_mod.VM.asClosure(macro_var.root).routine;
    if (routine.entryFor(args.len) == null) return ctx.fail(span, "macro {s} takes {f}, got {d}", .{ name, routine.arityPhrase(), args.len });

    // Each argument as data, unevaluated, its collections' places
    // kept for the result.
    var spans: std.AutoHashMapUnmanaged(u64, SrcSpan) = .empty;
    defer spans.deinit(ctx.allocator);
    const outer_spans = ctx.arg_spans;
    ctx.arg_spans = &spans;
    defer ctx.arg_spans = outer_spans;
    const arg_values = try ctx.allocator.alloc(value_mod.Value, args.len);
    defer ctx.allocator.free(arg_values);
    for (args, 0..) |a, i| arg_values[i] = try formToValue(ctx, a);

    // A fresh sub-VM that never collects, on the calling VM's heap
    // and registries when the context has them, so a value the macro
    // stores into a Var outlives the call and a type id it makes
    // means the same to the caller; the result becomes a Form in
    // `ctx.allocator` before the sub-VM goes, and so does the
    // message of a throw it did not catch.
    var sub_vm = vm_mod.VM.init(ctx.allocator, &vm_mod.VM.idle_routine) catch return ExpandError.OutOfMemory;
    defer sub_vm.deinit();
    sub_vm.borrowed_interner = ctx.interner;
    sub_vm.borrowed_heap = ctx.value_heap;
    sub_vm.gc_enabled = false;
    sub_vm.io = ctx.io;
    if (ctx.namespace) |ns| if (ns.registry) |reg| if (reg.vm) |owner| sub_vm.borrowRegistries(owner);
    const result_value = sub_vm.callValue(macro_var.root, arg_values) catch |err| return macroFailure(ctx, &sub_vm, name, span, err);
    // The form is data: every lazy seq in it is realized, on the
    // sub-VM, and made a list (docs/LAZY.md §8).
    const saved = sub_vm.installLazyHost();
    defer lazy_mod.host = saved;
    const listed = seq_mod.asLists(&sub_vm, result_value) catch |err| return macroFailure(ctx, &sub_vm, name, span, err);
    return try valueToForm(ctx, listed, span);
}

/// The failure of the macro `name`, whose sub-VM failed with `err`
/// while it ran or while its result was realized: what it threw, or
/// the error and what the VM said of it.
fn macroFailure(ctx: *ExpandContext, sub_vm: *const vm_mod.VM, name: []const u8, span: SrcSpan, err: anyerror) ExpandError {
    if (err == error.OutOfMemory) return ExpandError.OutOfMemory;
    if (err == error.UncaughtThrow) if (sub_vm.unhandled_throw) |thrown| {
        return ctx.fail(span, "macro {s} threw {s}", .{ name, try describeThrown(ctx, thrown) });
    };
    if (sub_vm.error_detail.len > 0) return ctx.fail(span, "macro {s} failed: {s}: {s}", .{ name, @errorName(err), sub_vm.error_detail });
    return ctx.fail(span, "macro {s} failed: {s}", .{ name, @errorName(err) });
}

/// A thrown value in a failure message: a string as itself, a
/// keyword as `:name`, an error map as its `:error` keyword and its
/// `:message` string (`:kind-mismatch: + expects numbers, got nil`),
/// either alone when it has only one, anything else by its kind.
fn describeThrown(ctx: *ExpandContext, thrown: value_mod.Value) ExpandError![]const u8 {
    switch (thrown.kind()) {
        .string => return string_mod.asBytes(thrown),
        .keyword => return ctx.allocator.print(":{s}", .{ctx.interner.keywordName(thrown.asKeywordId())}),
        .persistent_map => {
            var parts: [2]?[]const u8 = .{ null, null };
            for ([_][]const u8{ "error", "message" }, &parts) |key_name, *part| {
                const key = ctx.interner.internKeywordValue(key_name) catch return ExpandError.OutOfMemory;
                switch (champ_mod.mapGet(thrown, key, &dispatch.hashValue, &dispatch.equal)) {
                    .present => |v| if (v.kind() == .string or v.kind() == .keyword) {
                        part.* = try describeThrown(ctx, v);
                    },
                    .absent => {},
                }
            }
            if (parts[0] != null and parts[1] != null) return ctx.allocator.print("{s}: {s}", .{ parts[0].?, parts[1].? });
            if (parts[0] orelse parts[1]) |one| return one;
        },
        else => {},
    }
    return ctx.allocator.print("a {s}", .{@tagName(thrown.kind())});
}

/// A form as data (MACROEXPAND.md §1.2): what a macro receives as an
/// argument, `quote` makes a constant of and `read-string` returns.
/// Each literal is its value, a symbol or keyword interned (qualified
/// ones by their full `ns/name`), a list, vector, map or set that
/// collection, `'x` the list `(quote x)`, `@x` `(nexis.core/deref x)`,
/// `#()` the `fn*` form it stands for, `^m coll` the collection
/// carrying `m` (on anything else the metadata is dropped), and the
/// marker list a sorted collection travels as (`valueToForm`) the
/// collection itself. A syntax-quote or an unquote is not data.
pub fn formToValue(ctx: *ExpandContext, form: *const Form) ExpandError!value_mod.Value {
    const v = try formValue(ctx, form);
    if (ctx.arg_spans) |spans| if (spanKey(v)) |k| {
        spans.put(ctx.allocator, k, form.origin) catch return ExpandError.OutOfMemory;
    };
    return v;
}

/// What `arg_spans` knows a value by: the address of a non-empty
/// list, vector, map or set, which no other value shares while the
/// expansion runs (its heap does not collect).
fn spanKey(v: value_mod.Value) ?u64 {
    return switch (v.kind()) {
        .list => if (list_mod.isEmpty(v)) null else v.payload,
        .persistent_vector => if (vector_mod.count(v) == 0) null else v.payload,
        .persistent_map => if (champ_mod.mapCount(v) == 0) null else v.payload,
        .persistent_set => if (champ_mod.setCount(v) == 0) null else v.payload,
        else => null,
    };
}

fn formValue(ctx: *ExpandContext, form: *const Form) ExpandError!value_mod.Value {
    try checkStack();
    const heap = try ctx.heapForArgs();
    const oom = ExpandError.OutOfMemory;
    if (scalarValue(heap, ctx.interner, ctx.allocator, form.datum)) |scalar| {
        if (scalar) |v| return v;
    } else |err| return switch (err) {
        error.OutOfMemory => oom,
        error.StackOverflow => ExpandError.ExpansionDepthExceeded,
        error.Unsupported => unreachable,
        error.Malformed => ctx.fail(form.origin, "{s} that makes no value", .{describeForm(form)}),
    };
    return switch (form.datum) {
        .nil, .bool_, .int, .bigint, .real, .char, .string, .regex, .symbol, .keyword => unreachable,
        .list, .vector, .set, .map => |items| blk: {
            if (form.datum == .list) if (sortedMarker(items)) |set| break :blk try sortedValue(ctx, form, set, items[1..]);
            const values = try ctx.allocator.alloc(value_mod.Value, items.len);
            defer ctx.allocator.free(values);
            for (items, values) |item, *v| v.* = try formToValue(ctx, item);
            break :blk collOf(heap, switch (form.datum) {
                .list => .list,
                .vector => .vector,
                .set => .set,
                else => .map,
            }, values) catch return oom;
        },
        .quote => |inner| try callForm(ctx, "quote", inner),
        .deref => |inner| try callForm(ctx, "nexis.core/deref", inner),
        .anon_fn => |items| try formToValue(ctx, try anonFnForm(ctx, form, items)),
        .with_meta => |wm| blk: {
            const target = try formToValue(ctx, wm.target);
            switch (target.kind()) {
                // A collection this call made: no one else holds it.
                .list, .persistent_vector, .persistent_map, .persistent_set => {
                    const meta = try formToValue(ctx, wm.meta);
                    heap_mod.Heap.asHeapHeader(target).setMeta(heap_mod.Heap.asHeapHeader(meta));
                },
                else => {},
            }
            break :blk target;
        },
        .syntax_quote, .unquote, .unquote_splicing => ctx.fail(form.origin, "{s} is not data a macro can take", .{describeForm(form)}),
    };
}

pub const ScalarError = error{ OutOfMemory, StackOverflow, Unsupported, Malformed };

/// The value of a scalar datum, as `formToValue` and the compiler's
/// literals make it, a string, bignum or regex on `heap` and a symbol
/// or keyword interned; null for any other datum. Without a heap or an
/// interner a datum that needs one is `Unsupported`; a datum that names
/// no value (a char past Unicode, a regex that does not compile), which
/// the reader never makes, is `Malformed`.
pub fn scalarValue(heap: ?*heap_mod.Heap, interner: ?*intern_mod.Interner, scratch: Allocator, datum: Datum) ScalarError!?value_mod.Value {
    return switch (datum) {
        .nil => value_mod.nilValue(),
        .bool_ => |b| value_mod.fromBool(b),
        .int => |n| value_mod.fromFixnum(n) orelse bignum_mod.fromI64(heap orelse return error.Unsupported, n) catch error.OutOfMemory,
        .bigint => |text| (bignum_mod.parseDecimal(heap orelse return error.Unsupported, text) catch return error.OutOfMemory) orelse error.Malformed,
        .real => |f| value_mod.fromFloat(f),
        .char => |c| value_mod.fromChar(c) orelse error.Malformed,
        .string => |bytes| string_mod.fromBytes(heap orelse return error.Unsupported, bytes) catch error.OutOfMemory,
        .regex => |text| switch (try regex_mod.make(heap orelse return error.Unsupported, scratch, text)) {
            .ok => |p| p,
            .err => error.Malformed,
        },
        .symbol => |name| (interner orelse return error.Unsupported).internQualifiedSymbol(name.ns, name.name) catch error.OutOfMemory,
        .keyword => |name| (interner orelse return error.Unsupported).internQualifiedKeyword(name.ns, name.name) catch error.OutOfMemory,
        else => null,
    };
}

/// Whether `items` is the marker list a sorted collection travels as
/// in a form (`valueToForm`): `(nexis.internal/#%sorted-set x ...)`
/// true, `(nexis.internal/#%sorted-map k v ...)` false, any other
/// list null.
fn sortedMarker(items: []const *const Form) ?bool {
    if (items.len == 0 or items[0].datum != .symbol) return null;
    const sym = items[0].datum.symbol;
    if (!std.mem.eql(u8, sym.ns orelse return null, "nexis.internal")) return null;
    if (std.mem.eql(u8, sym.name, "#%sorted-set")) return true;
    if (std.mem.eql(u8, sym.name, "#%sorted-map")) return false;
    return null;
}

/// The sorted set or map, in the natural order, that the marker
/// list `form`, whose items after the head are `items`, stands for.
fn sortedValue(ctx: *ExpandContext, form: *const Form, set: bool, items: []const *const Form) ExpandError!value_mod.Value {
    if (!set and items.len % 2 != 0) return ctx.fail(form.origin, "a sorted map needs pairs", .{});
    const heap = try ctx.heapForArgs();
    const order = sorted_mod.Natural{ .interner = ctx.interner };
    var acc = sorted_mod.empty(heap, if (set) .sorted_set else .sorted_map, value_mod.nilValue()) catch return ExpandError.OutOfMemory;
    var i: usize = 0;
    while (i < items.len) : (i += if (set) 1 else 2) {
        const k = try formToValue(ctx, items[i]);
        const next = if (set) sorted_mod.conj(heap, acc, k, order) else sorted_mod.assoc(heap, acc, k, try formToValue(ctx, items[i + 1]), order);
        acc = next catch |err| switch (err) {
            error.OutOfMemory => return ExpandError.OutOfMemory,
            else => return ctx.fail(items[i].origin, "the keys of a sorted collection must compare", .{}),
        };
    }
    return acc;
}

/// The list `(head x)` as data, `x` converted by `formToValue`.
fn callForm(ctx: *ExpandContext, head: []const u8, x: *const Form) ExpandError!value_mod.Value {
    const items = [_]value_mod.Value{
        ctx.interner.internSymbolValue(head) catch return ExpandError.OutOfMemory,
        try formToValue(ctx, x),
    };
    return list_mod.fromSlice(try ctx.heapForArgs(), &items) catch ExpandError.OutOfMemory;
}

/// The list, vector, set or map (`values` alternating keys and
/// values) of `values`, built at once as the VM's `coll:` instructions
/// build one: a form as data and the compiler's constant collections.
pub fn collOf(heap: *heap_mod.Heap, op: vm_mod.CollOp, values: []const value_mod.Value) !value_mod.Value {
    return switch (op) {
        .list => list_mod.fromSlice(heap, values),
        .vector => vector_mod.fromSlice(heap, values),
        .set => champ_mod.setFromElements(heap, values, &dispatch.hashValue, &dispatch.equal),
        // Flat key, value pairs are `Entry`s laid end to end.
        .map => champ_mod.mapFromEntries(heap, @as([*]const champ_mod.Entry, @ptrCast(values.ptr))[0 .. values.len / 2], &dispatch.hashValue, &dispatch.equal),
        else => unreachable,
    };
}

/// A macro's result as a form in `ctx.allocator`, each one the macro
/// was given at its own place (`arg_spans`) and every other at
/// `call_origin`: the inverse of `formToValue`, a bignum
/// within i64 an `int` and beyond it a `bigint`. The list
/// `(nexis.internal/#%meta x m)` becomes `^m x`, and so does a list,
/// vector, map or set carrying the metadata `m` (§5). A function, a
/// Var or any other kind is not a form.
pub fn valueToForm(ctx: *ExpandContext, v: value_mod.Value, call_origin: SrcSpan) ExpandError!*Form {
    try checkStack();
    // A form the macro was given, at its own place, and its parts.
    const origin = if (ctx.arg_spans) |spans| (if (spanKey(v)) |k| spans.get(k) orelse call_origin else call_origin) else call_origin;
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
        // A macro may return a pattern, as Clojure's may: the literal
        // of its source, a new pattern where it is evaluated.
        .regex => .{ .regex = try ctx.allocator.dupe(u8, regex_mod.sourceOf(v)) },
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
        // A sorted collection in the natural order travels as
        // `(nexis.internal/#%sorted-map k v ...)`, which builds it and
        // which `quote` folds to the collection itself; one with a
        // comparator of its own carries code, which no form holds.
        .sorted_map, .sorted_set => blk: {
            const set = v.kind() == .sorted_set;
            if (!sorted_mod.comparatorOf(v).isNil()) return ctx.fail(origin, "a macro returned a sorted {s} with a comparator of its own, which is not a form", .{if (set) "set" else "map"});
            var items: std.ArrayList(*Form) = .empty;
            try items.append(ctx.allocator, try makeForm(ctx, .{ .symbol = .{ .ns = "nexis.internal", .name = if (set) "#%sorted-set" else "#%sorted-map" } }, origin));
            var c = sorted_mod.Cursor.init(v);
            while (c.next()) |e| {
                try items.append(ctx.allocator, try valueToForm(ctx, e.key, origin));
                if (!set) try items.append(ctx.allocator, try valueToForm(ctx, e.value, origin));
            }
            break :blk .{ .list = items.items };
        },
        else => return ctx.fail(origin, "a macro returned {s}, which is not a form", .{vm_mod.kindPhrase(v.kind())}),
    };
    const form = try makeForm(ctx, datum, origin);
    const carries_meta = switch (v.kind()) {
        .list, .persistent_vector, .persistent_map, .persistent_set => datum != .with_meta,
        else => false,
    };
    if (carries_meta) {
        const meta_v = dispatch.metaOf(heap_mod.Heap.asHeapHeader(v));
        if (!meta_v.isNil()) return makeForm(ctx, .{ .with_meta = .{ .target = form, .meta = try valueToForm(ctx, meta_v, origin) } }, origin);
    }
    return form;
}

/// An interned `ns/name` text as a qualified name.
fn nameOf(full: []const u8) reader_mod.Name {
    const parts = intern_mod.Interner.splitQualified(full);
    return .{ .ns = parts.ns, .name = parts.name };
}

/// Whether `form` is the unqualified symbol `name`.
fn isSym(form: *const Form, name: []const u8) bool {
    return form.datum == .symbol and form.datum.symbol.ns == null and std.mem.eql(u8, form.datum.symbol.name, name);
}

/// Whether `form` is the unqualified keyword `:name`.
fn isKw(form: *const Form, name: []const u8) bool {
    return form.datum == .keyword and form.datum.keyword.ns == null and std.mem.eql(u8, form.datum.keyword.name, name);
}

/// Whether `form` is a list headed by the unqualified symbol `name`:
/// a `catch` or `finally` clause of `try`.
fn isClauseHead(form: *const Form, name: []const u8) bool {
    return form.datum == .list and form.datum.list.len > 0 and isSym(form.datum.list[0], name);
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

fn makeNil(ctx: *ExpandContext, origin: SrcSpan) ExpandError!*Form {
    return makeForm(ctx, .nil, origin);
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
        return makeForm(b.ctx, .{ .keyword = .{ .ns = null, .name = name } }, b.origin);
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
        if (T == bool) return makeForm(b.ctx, .{ .bool_ = x }, b.origin);
        if (comptime isString(T)) return b.named(x);
        return makeForm(b.ctx, .{ .int = @intCast(x) }, b.origin);
    }

    fn named(b: Builder, text: []const u8) ExpandError!*Form {
        const is_kw = text.len > 1 and text[0] == ':';
        const body = if (is_kw) text[1..] else text;
        const slash = if (body.len > 1) std.mem.findScalar(u8, body, '/') else null;
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
// Each builds its output at the call's span (§4b) and the expander
// expands that output again.

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

/// `(fn name? [params] body...)` → `(fn* name? [params'] body...)`,
/// and overload clauses `(fn name? ([p] b) ...)` → `(fn* name? ([p']
/// b') ...)` (`multiArityFn`): a pattern parameter becomes a gensym
/// that `(let [pattern gensym ...] body...)` destructures, so a map
/// pattern after `&` takes keyword arguments.
fn expandFnRename(ctx: *ExpandContext, call_form: *const Form, args: []const *Form) ExpandError!*Form {
    const b = Builder{ .ctx = ctx, .origin = call_form.origin };
    const named = args.len > 0 and args[0].datum == .symbol;
    const name: []const *Form = if (named) args[0..1] else &.{};
    const tail = args[name.len..];
    if (tail.len == 0) return ctx.fail(call_form.origin, "fn: expected a parameter vector", .{});
    const params_form = try stripParams(ctx, tail[0]);
    if (params_form.datum == .list) return multiArityFn(b, name, tail);
    if (params_form.datum != .vector) return ctx.fail(params_form.origin, "fn: expected a parameter vector, got {s}", .{describeForm(params_form)});
    return b.list(.{ "fn*", name, try fnClause(b, params_form, tail[1..]) });
}

/// `[params'] body'` for the parameter vector `params_form` and the
/// forms of `body`: the pattern parameters made gensyms that a `let`
/// around the body destructures, the body conditioned.
fn fnClause(b: Builder, params_form: *const Form, forms: []const *Form) ExpandError![]*Form {
    const ctx = b.ctx;
    const params = try ctx.allocator.dupe(*Form, params_form.datum.vector);
    var patterns: std.ArrayList(*Form) = .empty;
    for (params) |*p| {
        if (p.*.datum != .symbol) {
            const g = try b.gensym("nx");
            try patterns.appendSlice(ctx.allocator, &.{ p.*, g });
            p.* = g;
        }
    }
    const new_params = try makeVector(ctx, params, params_form.origin);
    const body = try conditionedBody(b, forms);
    if (patterns.items.len == 0) return b.items(.{ new_params, body });
    return b.items(.{ new_params, try b.list(.{ "nexis.core/let", try b.vec(.{patterns.items}), body }) });
}

/// A fn body whose first form is a condition map `{:pre [c...]
/// :post [c...]}` followed by more forms, as the checks around the
/// rest: each `:pre` condition before it, each `:post` condition
/// after it with `%` bound to its value. A failed check raises
/// `:assertion-failed`, "Assert failed: <c>", placed at the condition
/// as a runtime error is. Any other body is itself.
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
        if (isKw(entries[i], key) and entries[i + 1].datum == .vector) return entries[i + 1].datum.vector;
    }
    return null;
}

/// `(if c nil (nexis.internal/#%raise :assertion-failed message))`.
fn assertion(b: Builder, c: *const Form) ExpandError!*Form {
    const at = Builder{ .ctx = b.ctx, .origin = c.origin };
    const prefix = try makeForm(b.ctx, .{ .string = "Assert failed: " }, c.origin);
    const message = try at.list(.{ "nexis.core/str", prefix, try at.list(.{ "quote", c }) });
    return at.list(.{ "if", c, null, try at.list(.{ "nexis.internal/#%raise", ":assertion-failed", message }) });
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
/// `letfn` binding as `fn*`'s own clauses, each through `fnClause`
/// (COMPILER.md §5.5). Clojure's clause rules are checked here, so a
/// failure names the clause at fault.
fn multiArityFn(b: Builder, name: []const *Form, clauses: []const *Form) ExpandError!*Form {
    const ctx = b.ctx;
    var fixed_arities: std.ArrayList(usize) = .empty;
    var variadic: ?usize = null;
    const out = try ctx.allocator.alloc(*Form, clauses.len);
    for (clauses, out) |clause, *o| {
        if (clause.datum != .list or clause.datum.list.len == 0) return ctx.fail(clause.origin, "fn: expected an overload clause ([params] body...), not {s}", .{describeForm(clause)});
        const params_form = try stripParams(ctx, clause.datum.list[0]);
        if (params_form.datum != .vector) return ctx.fail(params_form.origin, "fn: expected a parameter vector, got {s}", .{describeForm(params_form)});
        const params = params_form.datum.vector;
        const fixed = for (params, 0..) |p, i| {
            if (isSym(p, "&")) break i;
        } else params.len;
        if (fixed < params.len) {
            if (variadic != null) return ctx.fail(clause.origin, "fn: at most one overload clause may be variadic", .{});
            if (fixed + 2 != params.len) return ctx.fail(params_form.origin, "fn: & takes exactly one parameter after it", .{});
            variadic = fixed;
        } else {
            for (fixed_arities.items) |a| if (a == fixed) return ctx.fail(clause.origin, "fn: two overload clauses take {d} arguments", .{fixed});
            try fixed_arities.append(ctx.allocator, fixed);
        }
        o.* = try makeList(ctx, try fnClause(b, params_form, clause.datum.list[1..]), clause.origin);
    }
    if (variadic) |v| for (fixed_arities.items) |a| {
        if (a > v) return ctx.fail(b.origin, "fn: a fixed arity of {d} is above the variadic clause's {d}", .{ a, v });
    };
    return b.list(.{ "fn*", name, out });
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
        .vector => {
            const g = try b.gensym("nx");
            try out.appendSlice(ctx.allocator, &.{ g, mutCast(expr) });
            try destructureVector(b, pattern.datum.vector, g, out);
        },
        // A seq is keyword arguments, as in Clojure: `k v ...`, or one
        // trailing map, is the map `nexis.internal/#%kwargs` builds.
        .map => {
            const g = try b.gensym("nx");
            const as_map = try b.list(.{ "if", try b.list(.{ "nexis.core/seq?", g }), try b.list(.{ "nexis.internal/#%kwargs", g }), g });
            try out.appendSlice(ctx.allocator, &.{ g, mutCast(expr), g, as_map });
            try destructureMap(b, pattern.datum.map, g, out);
        },
        else => return ctx.fail(pattern.origin, "cannot bind {s}", .{describeForm(pattern)}),
    }
}

/// A vector pattern over `src`: element `i` binds `(nth src i nil)`,
/// `& r` binds `r` to `(nthnext src i)`, the seq after the `i`
/// elements before it (nil once exhausted), `:as name` binds `src`
/// itself.
fn destructureVector(b: Builder, elems: []const *Form, src: *Form, out: *std.ArrayList(*Form)) ExpandError!void {
    var i: usize = 0;
    while (i < elems.len) : (i += 1) {
        const e = elems[i];
        const is_as = isKw(e, "as");
        if (is_as or isSym(e, "&")) {
            if (i + 1 >= elems.len) return b.ctx.fail(e.origin, "destructuring: {s} needs a name after it", .{if (is_as) ":as" else "&"});
            const target = elems[i + 1];
            if (is_as) {
                try destructurePair(b, target, src, out);
            } else {
                const rest = try b.list(.{ "nexis.core/nthnext", src, i });
                try destructurePair(b, target, rest, out);
            }
            i += 1;
        } else {
            try destructurePair(b, e, try b.list(.{ "nexis.core/nth", src, i, null }), out);
        }
    }
}

/// A map pattern over `src`, a map (`destructurePair` turns a seq
/// into one):
///
///   {... :as name}     name src, before the keys
///   {:keys [a b]}      a (:a src), b (:b src)
///   {:keys [p/a :b]}   a (:p/a src), b (:b src)
///   {:p/keys [a]}      a (:p/a src)
///   {:strs [a]}        a (get src "a")
///   {:syms [a]}        a ('a src); {:p/syms [a]} ('p/a src)
///   {a :a-key}         a (:a-key src); {a k} (get src k)
///   {... :or {a 10}}   a (:a src 10), the default when absent
fn destructureMap(b: Builder, entries: []const *Form, src: *Form, out: *std.ArrayList(*Form)) ExpandError!void {
    const ctx = b.ctx;
    if (entries.len % 2 != 0) return ctx.fail(b.origin, "destructuring: a map pattern needs pairs", .{});
    var defaults: []const *Form = &.{};
    var as_name: ?*const Form = null;
    var i: usize = 0;
    while (i < entries.len) : (i += 2) {
        const k = entries[i];
        const v = entries[i + 1];
        if (isKw(k, "or")) {
            if (v.datum != .map) return ctx.fail(v.origin, "destructuring: :or takes a map, not {s}", .{describeForm(v)});
            defaults = v.datum.map;
        } else if (isKw(k, "as")) {
            if (v.datum != .symbol) return ctx.fail(v.origin, "destructuring: :as takes a symbol, not {s}", .{describeForm(v)});
            as_name = v;
        }
    }
    // `:as` binds before the keys, so an `:or` default may read it.
    if (as_name) |n| try out.appendSlice(ctx.allocator, &.{ mutCast(n), src });
    i = 0;
    while (i < entries.len) : (i += 2) {
        const k = entries[i];
        const v = entries[i + 1];
        if (k.datum == .keyword) {
            const kw = k.datum.keyword;
            if (isKw(k, "or") or isKw(k, "as")) continue;
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

/// `(key src default?)` for a keyword or quoted symbol key, which is
/// `get`'s lookup in one instruction (COMPILER.md §4.3), else
/// `(nexis.core/get src key default?)`.
fn getCall(b: Builder, src: *Form, key: *const Form, default: ?*const Form) ExpandError!*Form {
    // `'s` as read, or `(quote s)` as `:syms` builds it.
    const quoted = unwrapQuote(key) != key and unwrapQuote(key).datum == .symbol;
    if (key.datum == .keyword or quoted) {
        if (default) |d| return b.list(.{ key, src, d });
        return b.list(.{ key, src });
    }
    if (default) |d| return b.list(.{ "nexis.core/get", src, key, d });
    return b.list(.{ "nexis.core/get", src, key });
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
/// destructure and overload clauses work as for `fn`, the name
/// carrying the Var's metadata; `defn-` adds `:private true`.
fn defn(comptime private: bool) MacroFn {
    return struct {
        fn expand(ctx: *ExpandContext, call_form: *const Form, args: []const *Form) ExpandError!*Form {
            const parts = try defnParts(ctx, call_form, args, private);
            return defnDef(.{ .ctx = ctx, .origin = call_form.origin }, parts, parts.meta);
        }
    }.expand;
}

/// `(def ^meta name (nexis.core/fn name tail))` of `parts`.
fn defnDef(b: Builder, parts: DefnParts, meta: []const *Form) ExpandError!*Form {
    return b.list(.{ "def", try withMetaMap(b, parts.name, meta), try b.list(.{ "nexis.core/fn", parts.name, parts.fn_tail }) });
}

/// The parts of `(defn NAME "doc"? {attrs}? tail)` and of `defmacro`
/// spelled the same way: the name, the fn tail (a parameter vector
/// and body, or overload clauses) and the Var metadata, from `^meta`
/// on the name, `:private true` when `private` (`defn-`), the
/// docstring and the attribute map, and `:arglists` (quoted).
const DefnParts = struct {
    name: *const Form,
    fn_tail: []const *Form,
    meta: []const *Form,
};

fn defnParts(ctx: *ExpandContext, call_form: *const Form, args: []const *Form, private: bool) ExpandError!DefnParts {
    const what = call_form.datum.list[0].datum.symbol.name;
    const origin = call_form.origin;
    const b = Builder{ .ctx = ctx, .origin = origin };
    if (args.len < 2) return ctx.fail(origin, "{s}: expected a name and a parameter vector", .{what});
    const named = try splitMetaName(ctx, args[0]);
    var meta: std.ArrayList(*Form) = .empty;
    if (private) try meta.appendSlice(ctx.allocator, &.{ try b.kw("private"), try b.item(true) });
    if (named.meta) |m| try meta.appendSlice(ctx.allocator, m);
    var rest: usize = 1;
    if (rest < args.len and args[rest].datum == .string) {
        try meta.appendSlice(ctx.allocator, &.{ try b.kw("doc"), mutCast(args[rest]) });
        rest += 1;
    }
    if (rest < args.len and args[rest].datum == .map) {
        try meta.appendSlice(ctx.allocator, args[rest].datum.map);
        rest += 1;
    }
    if (rest >= args.len) return ctx.fail(origin, "{s}: expected a parameter vector", .{what});
    const tail = args[rest..];
    var lists: std.ArrayList(*Form) = .empty;
    if (stripMeta(tail[0]).datum == .vector) {
        try lists.append(ctx.allocator, try stripParams(ctx, tail[0]));
    } else for (tail) |clause| {
        if (clause.datum != .list or clause.datum.list.len == 0) return ctx.fail(clause.origin, "{s}: expected ([params] body...), not {s}", .{ what, describeForm(clause) });
        try lists.append(ctx.allocator, try stripParams(ctx, clause.datum.list[0]));
    }
    try meta.appendSlice(ctx.allocator, &.{ try b.kw("arglists"), try b.list(.{ "quote", try b.list(.{lists.items}) }) });
    return .{ .name = named.name, .fn_tail = tail, .meta = meta.items };
}

// ---- when / when-not / and / or / cond (§10) ------------------------

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

/// `and` or `or`: the whole chain at once, from the last operand
/// back, so `n` operands cost O(n), as `cond` does.
fn andOr(comptime op: enum { @"and", @"or" }) MacroFn {
    return struct {
        fn expand(ctx: *ExpandContext, call_form: *const Form, args: []const *Form) ExpandError!*Form {
            const b = Builder{ .ctx = ctx, .origin = call_form.origin };
            if (args.len == 0) return if (op == .@"and") b.item(true) else b.item(null);
            var chain = mutCast(args[args.len - 1]);
            var i = args.len - 1;
            while (i > 0) {
                i -= 1;
                const g = try b.gensym(@tagName(op));
                const test_form = if (op == .@"and") try b.list(.{ "if", g, chain, g }) else try b.list(.{ "if", g, g, chain });
                chain = try b.list(.{ "let*", try b.vec(.{ g, args[i] }), test_form });
            }
            return chain;
        }
    }.expand;
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
        .keyword, .int, .bigint, .real, .string, .regex, .char => true,
        .bool_ => |v| v,
        else => false,
    };
}

// ---- case / condp (§10) ------------------------------------------------
//
// Fewer than three constants, or two that could be `=` while spelled
// differently, make a chain of `=` tests; otherwise one hashed lookup
// of the clause's index in a constant map, then fixnum compares.

fn expandCase(ctx: *ExpandContext, call_form: *const Form, args: []const *Form) ExpandError!*Form {
    if (args.len == 0) return ctx.fail(call_form.origin, "case: expected an expression", .{});
    const b = Builder{ .ctx = ctx, .origin = call_form.origin };
    const g = try b.gensym("case");
    const clauses = args[1..];
    var keys: std.ArrayList(*const Form) = .empty;
    // Atoms are found again by hash; compound constants, which are
    // rare, by comparing them pairwise.
    var atoms: reader_mod.LiteralSet = .empty;
    var compounds: std.ArrayList(*const Form) = .empty;
    var k: usize = 0;
    while (k + 1 < clauses.len) : (k += 2) {
        const key = clauses[k];
        const alternatives: []const *Form = if (key.datum == .list) key.datum.list else &.{key};
        for (alternatives) |alt| {
            const seen = if (reader_mod.isLiteralKey(alt)) (try atoms.getOrPut(ctx.allocator, alt)).found_existing else for (compounds.items) |c| {
                if (try sameConstant(c, alt)) break true;
            } else false;
            if (seen) return ctx.fail(alt.origin, "case: duplicate test constant", .{});
            if (!reader_mod.isLiteralKey(alt)) try compounds.append(ctx.allocator, alt);
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
        const threads = rest.len >= 3 and isKw(rest[1], ">>");
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

// ---- defrecord / defprotocol / extend-type / extend-protocol ----
//
// PROTOCOLS.md §4.

/// The Vars `(defrecord T [...])` defines besides `T` itself. The
/// compiler's `DeclaredNames` reads the same table, so a form may
/// refer to `->T` before the `defrecord` that produces it.
pub const RecordNames = struct {
    type_id: []u8,
    ctor: []u8,
    map_ctor: []u8,
    pred: []u8,

    pub fn typeId(allocator: std.mem.Allocator, rec_name: []const u8) ![]u8 {
        return allocator.print("{s}-type-id", .{rec_name});
    }

    pub fn init(allocator: std.mem.Allocator, rec_name: []const u8) !RecordNames {
        const type_id = try typeId(allocator, rec_name);
        errdefer allocator.free(type_id);
        const ctor = try allocator.print("->{s}", .{rec_name});
        errdefer allocator.free(ctor);
        const map_ctor = try allocator.print("map->{s}", .{rec_name});
        errdefer allocator.free(map_ctor);
        const pred = try allocator.print("{s}?", .{rec_name});
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
    return makeForm(b.ctx, .{ .string = try b.ctx.allocator.print("{s}/{s}", .{ currentNsName(b.ctx), name }) }, b.origin);
}

/// The current namespace's name; `user` with none, in a test.
fn currentNsName(ctx: *const ExpandContext) []const u8 {
    return if (ctx.namespace) |ns| ns.name else "user";
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
        try b.list(.{ "nexis.core/defn", names.map_ctor, try b.vec(.{"m"}), try b.list(.{ "nexis.internal/#%make-record", type_id, "m", try b.vec(.{keys}) }) }),
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
    const type_sym = try b.item(try ctx.allocator.print("{s}.{s}", .{ currentNsName(ctx), rec_name }));
    try out.append(ctx.allocator, try b.list(.{ "def", try b.item(rec_name), try b.list(.{ "quote", type_sym }) }));
    try out.append(ctx.allocator, try b.item(rec_name));
    return makeList(ctx, out.items, b.origin);
}

/// One arity `([this p...] body...)` of an inline `defrecord` method
/// with the record's fields in scope, as in Clojure: `([g p...]
/// (let* [f (:f g) ...] (let [this g] body...)))`. A
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
        try bindings.appendSlice(b.ctx.allocator, &.{ field, try getCall(b, g, try b.kw(field.datum.symbol.name), null) });
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
    // A docstring, which lands on the protocol's Var, and `:option
    // value` pairs may precede the methods.
    var specs = args[1..];
    var doc_meta: [2]*Form = undefined;
    var doc: []const *Form = &.{};
    if (specs.len > 0 and specs[0].datum == .string) {
        doc_meta = .{ try b.kw("doc"), mutCast(specs[0]) };
        doc = &doc_meta;
        specs = specs[1..];
    }
    while (specs.len >= 2 and specs[0].datum == .keyword) specs = specs[2..];
    const method_keys = try ctx.allocator.alloc(*Form, specs.len);
    const defs = try ctx.allocator.alloc(*Form, specs.len);
    for (specs, method_keys, defs) |spec, *key, *def| {
        if (spec.datum != .list or spec.datum.list.len == 0) return ctx.fail(spec.origin, "defprotocol: expected a method signature (name [params]...), not {s}", .{describeForm(spec)});
        const method = try plainName(ctx, spec.datum.list[0], "defprotocol: a method name");
        key.* = try b.kw(method);
        // `(m [this] [this x] "doc")`: the arities and the docstring
        // land on the method's Var.
        var lists: std.ArrayList(*Form) = .empty;
        var meta: std.ArrayList(*Form) = .empty;
        for (spec.datum.list[1..]) |part| switch (part.datum) {
            .vector => try lists.append(ctx.allocator, mutCast(part)),
            .string => try meta.appendSlice(ctx.allocator, &.{ try b.kw("doc"), mutCast(part) }),
            else => {},
        };
        try meta.appendSlice(ctx.allocator, &.{ try b.kw("arglists"), try b.list(.{ "quote", try makeList(ctx, lists.items, b.origin) }) });
        def.* = try b.list(.{ "def", try withMetaMap(b, spec.datum.list[0], meta.items), try b.list(.{ "nexis.internal/#%protocol-fn", proto_name, key.* }) });
    }
    // The form's value is the protocol's name, as Clojure's.
    return b.list(.{
        "do",
        try b.list(.{ "def", try withMetaMap(b, args[0], doc), try b.list(.{ "nexis.internal/#%register-protocol", try qualifiedNameString(b, proto_name), try b.vec(.{method_keys}) }) }),
        defs,
        try b.list(.{ "quote", args[0] }),
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
    if (args.len < 1 or (args[0].datum != .symbol and args[0].datum != .keyword and args[0].datum != .nil)) return ctx.fail(call_form.origin, "extend-type: expected a type", .{});
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
        const other = current orelse return b.ctx.fail(clause.origin, "a method needs {s} before it", .{if (anchor == .protocol) "a type" else "a protocol name"});
        if (anchor == .record and isSym(other, "Object"))
            return b.ctx.fail(other.origin, "defrecord: Object methods (toString, equals, hashCode) have no meaning here: nexis has no classes", .{});
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
    return clause.datum == .symbol or (anchor == .protocol and (clause.datum == .keyword or clause.datum == .nil));
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

/// The call installing `impl` as `protocol`'s method for a type
/// (PROTOCOLS.md §4.3): a kind keyword (`:string`), `:any` (the
/// default impl), nil, a Clojure class name nexis has a kind for
/// (`classKinds`), or a record (through its `<Name>-type-id`). A
/// class that stands for several kinds installs the impl for each.
fn extendCall(b: Builder, protocol: *const Form, type_form: *const Form, method_key: *Form, impl: *Form) ExpandError!*Form {
    const kinds: []const []const u8 = switch (type_form.datum) {
        .nil => &[_][]const u8{"nil"},
        .keyword => |kw| try b.ctx.allocator.dupe([]const u8, &[_][]const u8{kw.name}),
        .symbol => |sym| (if (sym.ns == null and !try namesRecord(b.ctx, sym.name)) classKinds(sym.name) else null) orelse
            return b.list(.{ "nexis.internal/#%extend-record-impl", protocol, method_key, try recordTypeId(b, type_form), impl }),
        else => return b.ctx.fail(type_form.origin, "expected a record name, a class or a kind keyword, not {s}", .{describeForm(type_form)}),
    };
    if (kinds.len == 1) return extendKind(b, protocol, method_key, kinds[0], impl);
    const f = try b.gensym("impl");
    var calls: std.ArrayList(*Form) = .empty;
    for (kinds) |k| try calls.append(b.ctx.allocator, try extendKind(b, protocol, method_key, k, f));
    return b.list(.{ "let*", try b.vec(.{ f, impl }), calls.items });
}

/// The call installing `impl` for the kind keyword `kind`, `any` the
/// default impl.
fn extendKind(b: Builder, protocol: *const Form, method_key: *Form, kind: []const u8, impl: *Form) ExpandError!*Form {
    if (std.mem.eql(u8, kind, "any")) return b.list(.{ "nexis.internal/#%extend-default-impl", protocol, method_key, impl });
    return b.list(.{ "nexis.internal/#%extend-builtin-impl", protocol, method_key, try b.kw(kind), impl });
}

/// Whether `name` resolves to a record's name in the current
/// namespace, its own or referred: a record the program defines wins
/// over a class of the same name, which Clojure does not import.
fn namesRecord(ctx: *ExpandContext, name: []const u8) ExpandError!bool {
    const ns = ctx.namespace orelse return false;
    const v = ns.lookup(name) orelse return false;
    const home = if (v.ns.len == 0 or std.mem.eql(u8, v.ns, ns.name)) ns else blk: {
        const reg = ctx.registry orelse return false;
        break :blk reg.lookupNs(v.ns) orelse return false;
    };
    return home.lookupLocal(try RecordNames.typeId(ctx.allocator, v.name)) != null;
}

/// The kinds a Clojure class name stands for, so protocol code
/// written for Clojure extends the same values (`Object` is every
/// value: the default impl); null for a name that is no such class.
fn classKinds(name: []const u8) ?[]const []const u8 {
    const classes = std.StaticStringMap([]const []const u8).initComptime(.{
        .{ "Object", &[_][]const u8{"any"} },
        .{ "String", &[_][]const u8{"string"} },
        .{ "CharSequence", &[_][]const u8{"string"} },
        .{ "Long", &[_][]const u8{"fixnum"} },
        .{ "Integer", &[_][]const u8{"fixnum"} },
        .{ "Short", &[_][]const u8{"fixnum"} },
        .{ "Byte", &[_][]const u8{"fixnum"} },
        .{ "BigInteger", &[_][]const u8{"fixnum"} },
        .{ "BigInt", &[_][]const u8{"fixnum"} },
        .{ "Double", &[_][]const u8{"float"} },
        .{ "Float", &[_][]const u8{"float"} },
        .{ "Number", &[_][]const u8{ "fixnum", "float" } },
        .{ "Boolean", &[_][]const u8{ "true_", "false_" } },
        .{ "Character", &[_][]const u8{"char"} },
        .{ "Keyword", &[_][]const u8{"keyword"} },
        .{ "Symbol", &[_][]const u8{"symbol"} },
        .{ "IPersistentVector", &[_][]const u8{"vector"} },
        .{ "PersistentVector", &[_][]const u8{"vector"} },
        .{ "IPersistentMap", &[_][]const u8{ "map", "sorted_map" } },
        .{ "PersistentHashMap", &[_][]const u8{"map"} },
        .{ "PersistentArrayMap", &[_][]const u8{"map"} },
        .{ "Map", &[_][]const u8{ "map", "sorted_map" } },
        .{ "IPersistentSet", &[_][]const u8{ "set", "sorted_set" } },
        .{ "PersistentHashSet", &[_][]const u8{"set"} },
        .{ "Set", &[_][]const u8{ "set", "sorted_set" } },
        .{ "ISeq", &[_][]const u8{ "list", "lazy_seq" } },
        .{ "IPersistentList", &[_][]const u8{"list"} },
        .{ "PersistentList", &[_][]const u8{"list"} },
        .{ "IFn", &[_][]const u8{ "function", "native_fn" } },
        .{ "Fn", &[_][]const u8{ "function", "native_fn" } },
        .{ "Atom", &[_][]const u8{"atom"} },
        .{ "Var", &[_][]const u8{"var_"} },
    });
    return classEntry([]const []const u8, classes, name);
}

/// The `<Name>-type-id` symbol of the record `type_form` names: `R`
/// in the namespace that defines it (the current one, or the home of
/// a Var `R` this namespace refers to), `alias/R` in the namespace
/// the alias names, or `ns.R`, the type symbol `type` returns, in
/// `ns`. A dotted name whose prefix is no namespace names a class
/// nexis does not have.
fn recordTypeId(b: Builder, type_form: *const Form) ExpandError!*Form {
    const ctx = b.ctx;
    const sym = type_form.datum.symbol;
    var home = sym.ns;
    var name = sym.name;
    if (home == null) if (std.mem.findScalarLast(u8, name, '.')) |dot| {
        home = name[0..dot];
        name = name[dot + 1 ..];
        if (ctx.registry) |reg| if (reg.lookupNs(home.?) == null)
            return ctx.fail(type_form.origin, "{s} names no record and no class nexis has; extend a kind keyword such as :string", .{sym.name});
    };
    if (home == null) if (ctx.namespace) |ns| if (ns.lookup(name)) |v| if (v.ns.len > 0 and !std.mem.eql(u8, v.ns, ns.name)) {
        home = v.ns;
        name = v.name;
    };
    const id = try RecordNames.typeId(ctx.allocator, name);
    return makeForm(ctx, .{ .symbol = .{ .ns = home, .name = id } }, b.origin);
}

// ---- -> / ->> ------------------------------------------------
//
//   (-> x (f a) g)   => (g (f x a))       thread-first
//   (->> x (f a) g)  => (g (f a x))       thread-last
//
// A step that is not a list (a symbol, a keyword) is called with the
// threaded value alone.

fn thread(comptime pos: enum { first, last }) MacroFn {
    return struct {
        fn expand(ctx: *ExpandContext, call_form: *const Form, args: []const *Form) ExpandError!*Form {
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
    }.expand;
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
    mappings: std.StringHashMapUnmanaged([]const u8) = .empty,

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
/// becomes `ns/name` for the namespace that owns the Var it resolves
/// to (`nexis.core` for a host macro), or `<current-ns>/name` when it
/// resolves to nothing. `name#` is
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
        .nil, .bool_, .int, .bigint, .real, .char, .string, .regex, .keyword => mutCast(payload),
        .symbol => |name| b.list(.{ "quote", if (name.ns) |ns_prefix| blk: {
            const target = aliasTarget(ctx, ns_prefix);
            break :blk if (target.ptr == ns_prefix.ptr) mutCast(payload) else try makeQualifiedSymbol(ctx, target, name.name, payload.origin);
        } else if (name.name.len > 1 and name.name[name.name.len - 1] == '#')
            try makeSymbol(ctx, try scope.lookupOrAllocate(ctx, name.name), payload.origin)
        else if (syntaxQuoteName(ctx, name.name)) |qualified|
            try makeForm(ctx, .{ .symbol = qualified }, payload.origin)
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

/// What an unqualified symbol qualifies to inside syntax-quote, or
/// null to leave it bare: the Var the name resolves to, by its home
/// namespace and its own name (a referred or `:rename`d Var's, not
/// the current namespace's name for it), as Clojure qualifies it;
/// `nexis.core/name` for a host macro; otherwise the name in the
/// current namespace. Null without a named namespace.
fn syntaxQuoteName(ctx: *ExpandContext, name: []const u8) ?reader_mod.Name {
    if (isSyntaxQuoteBare(name)) return null;
    const ns = ctx.namespace orelse return null;
    if (ns.name.len == 0) return null;
    if (ns.lookup(name)) |v| if (v.ns.len > 0) return .{ .ns = v.ns, .name = v.name };
    if (ctx.host_macros.get(name) != null) return .{ .ns = "nexis.core", .name = name };
    return .{ .ns = ns.name, .name = name };
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
    var table: HostMacroTable = .empty;
    errdefer table.deinit(allocator);
    try table.put(allocator, "let", expandLetRename);
    try table.put(allocator, "fn", expandFnRename);
    try table.put(allocator, "defn", defn(false));
    try table.put(allocator, "defn-", defn(true));
    try table.put(allocator, "loop", expandLoopRename);
    try table.put(allocator, "when", expandWhen);
    try table.put(allocator, "when-not", expandWhenNot);
    try table.put(allocator, "and", andOr(.@"and"));
    try table.put(allocator, "or", andOr(.@"or"));
    try table.put(allocator, "cond", expandCond);
    try table.put(allocator, "->", thread(.first));
    try table.put(allocator, "->>", thread(.last));
    try table.put(allocator, "case", expandCase);
    try table.put(allocator, "condp", expandCondp);
    try table.put(allocator, "defrecord", expandDefrecord);
    try table.put(allocator, "defprotocol", expandDefprotocol);
    try table.put(allocator, "extend-type", expandExtendType);
    try table.put(allocator, "extend-protocol", expandExtendProtocol);
    return table;
}

// =============================================================================
// Clojure idioms nexis lacks (TOOLING.md §1)
// =============================================================================

/// What to write instead of a Clojure name nexis lacks, for the report
/// of a symbol that resolves to nothing: Java interop (`Exception.`,
/// `.toUpperCase`, `Math/sqrt`, `System/getenv`) and the JVM's
/// threads (`future`, `pmap`, `agent`); null for any other name. One
/// clause, in `allocator`.
pub fn idiomHint(allocator: Allocator, ns: ?[]const u8, name: []const u8) Allocator.Error!?[]const u8 {
    if (ns) |n| return classMemberHint(allocator, n, name);
    if (name.len > 1 and name[name.len - 1] == '.' and !std.mem.eql(u8, name, "..")) {
        const class = name[(if (std.mem.findScalarLast(u8, name[0 .. name.len - 1], '.')) |i| i + 1 else 0) .. name.len - 1];
        if (std.mem.endsWith(u8, class, "Exception") or std.mem.endsWith(u8, class, "Error") or std.mem.eql(u8, class, "Throwable"))
            return "nexis has no Java classes: throw (ex-info \"message\" {:key value}), or any value";
        return no_constructors;
    }
    if (name.len > 1 and name[0] == '.' and name[1] != '.') {
        const method = name[1..];
        for (method_hints) |pair| if (std.mem.eql(u8, method, pair[0]))
            return try allocator.print("nexis has no Java interop, so no .method calls: use {s}", .{pair[1]});
        return "nexis has no Java interop, so no .method calls: call a function (nexis.string has the string ones)";
    }
    if (std.mem.eql(u8, name, "new")) return no_constructors;
    for (thread_hints) |pair| for (pair[0]) |n| if (std.mem.eql(u8, name, n)) return pair[1];
    return null;
}

const no_constructors = "nexis has no Java interop, so no constructors: functions build values";

/// Whether `name` is under the `java.` or `javax.` packages.
fn isJavaPackage(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "java.") or std.mem.startsWith(u8, name, "javax.");
}

/// `ns/name` where `ns` is a Java class (`Math/sqrt`, `System/getenv`,
/// `java.util.UUID/randomUUID`): the nexis function, or what it is.
fn classMemberHint(allocator: Allocator, ns: []const u8, name: []const u8) Allocator.Error!?[]const u8 {
    if (std.mem.eql(u8, ns, "Math") or std.mem.eql(u8, ns, "StrictMath")) {
        for ([_][2][]const u8{ .{ "abs", "abs" }, .{ "max", "max" }, .{ "min", "min" }, .{ "random", "rand" } }) |pair| {
            if (std.mem.eql(u8, name, pair[0])) return try allocator.print("nexis has no Java interop: use {s}", .{pair[1]});
        }
        // Java's camelCase is clojure.math's kebab-case: `toRadians`
        // is `to-radians`.
        const camel = name.len > 0 and std.ascii.isLower(name[0]);
        var kebab: std.ArrayList(u8) = .empty;
        for (name) |c| {
            if (camel and std.ascii.isUpper(c)) {
                try kebab.appendSlice(allocator, &.{ '-', std.ascii.toLower(c) });
            } else try kebab.append(allocator, c);
        }
        for (math_names) |m| if (std.mem.eql(u8, kebab.items, m))
            return try allocator.print("nexis has no Java interop: use nexis.math/{s} (clojure.math/{s})", .{ m, m });
        return "nexis has no Java interop: nexis.math (clojure.math) has the math functions";
    }
    for (member_hints) |h| if (std.mem.eql(u8, ns, h[0]) and std.mem.eql(u8, name, h[1]))
        return try allocator.print("nexis has no Java interop: use {s}", .{h[2]});
    if (std.mem.eql(u8, ns, "clojure.java.io")) return namespaceHint("clojure.java.io");
    const java_package = isJavaPackage(ns);
    const class = ns[(if (std.mem.findScalarLast(u8, ns, '.')) |i| i + 1 else 0)..];
    const class_name = class.len > 0 and std.ascii.isUpper(class[0]);
    if (java_package or class_name) return try allocator.print("nexis has no Java interop: {s} is a Java class", .{ns});
    return null;
}

/// What to require instead of a library namespace nexis lacks, for
/// the report of a `require` that finds no file; null for any other.
pub fn namespaceHint(name: []const u8) ?[]const u8 {
    for ([_][2][]const u8{
        .{ "clojure.java.io", "nexis has no clojure.java.io: slurp and spit read and write a file, read-line reads stdin" },
        .{ "clojure.core.async", "nexis runs one thread and has no core.async: call functions in order" },
    }) |pair| if (std.mem.eql(u8, name, pair[0])) return pair[1];
    if (isJavaPackage(name)) return "nexis has no Java interop";
    return null;
}

/// A Java method and the nexis function that does its work.
const method_hints = [_][2][]const u8{
    .{ "toUpperCase", "nexis.string/upper-case" },
    .{ "toLowerCase", "nexis.string/lower-case" },
    .{ "trim", "nexis.string/trim" },
    .{ "length", "count" },
    .{ "size", "count" },
    .{ "substring", "subs" },
    .{ "startsWith", "nexis.string/starts-with?" },
    .{ "endsWith", "nexis.string/ends-with?" },
    .{ "contains", "nexis.string/includes? for a string, contains? for a collection" },
    .{ "indexOf", "nexis.string/index-of" },
    .{ "split", "nexis.string/split" },
    .{ "replace", "nexis.string/replace" },
    .{ "isEmpty", "empty?" },
    .{ "charAt", "nth" },
    .{ "equals", "=" },
    .{ "toString", "str" },
    .{ "getMessage", "ex-message" },
    .{ "getData", "ex-data" },
    .{ "getCause", "ex-cause" },
};

/// A static member of a Java class and the nexis function for it.
const member_hints = [_][3][]const u8{
    .{ "System", "getenv", "nexis.sys/getenv" },
    .{ "System", "exit", "exit" },
    .{ "System", "nanoTime", "nano-time" },
    .{ "System", "currentTimeMillis", "(nexis.time/inst-ms (nexis.time/now))" },
    .{ "Integer", "parseInt", "parse-long" },
    .{ "Long", "parseLong", "parse-long" },
    .{ "Double", "parseDouble", "parse-double" },
    .{ "Boolean", "parseBoolean", "parse-boolean" },
    .{ "String", "valueOf", "str" },
    .{ "String", "join", "nexis.string/join" },
    .{ "UUID", "randomUUID", "random-uuid" },
    .{ "java.util.UUID", "randomUUID", "random-uuid" },
};

/// `nexis.math`'s names (clojure.math's).
const math_names = [_][]const u8{ "PI", "E", "sqrt", "cbrt", "pow", "exp", "expm1", "log", "log10", "log1p", "floor", "ceil", "round", "signum", "hypot", "sin", "cos", "tan", "asin", "acos", "atan", "atan2", "sinh", "cosh", "tanh", "to-radians", "to-degrees", "floor-div", "floor-mod" };

/// Clojure's concurrency names, which a nexis of one isolate and one
/// thread has none of.
const thread_hints = [_]struct { []const []const u8, []const u8 }{
    .{ &.{ "future", "future-call" }, "nexis runs one thread, so no future: call the function and use its value" },
    .{ &.{"pmap"}, "nexis runs one thread, so no pmap: use map" },
    .{ &.{ "pcalls", "pvalues" }, "nexis runs one thread: call the functions in order" },
    .{ &.{ "agent", "send", "send-off", "await" }, "nexis has no agents: an atom holds state that changes" },
    .{ &.{ "promise", "deliver" }, "nexis runs one thread, so no promise: use the value, or an atom" },
    .{ &.{"thread"}, "nexis runs one thread, so no thread: call the function" },
    .{ &.{"locking"}, "nexis runs one thread, so nothing to lock: run the body" },
    .{ &.{ "dosync", "ref", "ref-set", "alter", "commute" }, "nexis has no STM: an atom holds shared state, db/ref a durable one" },
};

// =============================================================================
// Inline tests
// =============================================================================

const testing = std.testing;

/// `src`, read as one form into `arena`.
fn readForTest(arena: Allocator, src: []const u8) !*Form {
    var p = try reader_mod.parser.parseForm(arena, src);
    defer p.parser.deinit();
    var rdr = reader_mod.Reader.init(arena, src);
    return rdr.readOneForm(p.sexp);
}

/// `src` read and expanded with `host_macros` and no namespace, in
/// `arena`, with the context's failure, if any.
fn expandForTest(arena: Allocator, src: []const u8, host_macros: *const HostMacroTable) !struct { form: ExpandError!*Form, failure: ?Failure } {
    const form = try readForTest(arena, src);
    const interner = try arena.create(intern_mod.Interner);
    interner.* = intern_mod.Interner.init(arena);
    var ctx = ExpandContext{ .allocator = arena, .interner = interner, .host_macros = host_macros };
    const out = expandForm(&ctx, form);
    return .{ .form = out, .failure = ctx.failure };
}

/// Expand `src` with `host_macros` (the default macros when null) and
/// expect `expected`, with `message` recorded against the source text
/// `at`.
fn expectFailure(src: []const u8, host_macros: ?*const HostMacroTable, expected: ExpandError, message: []const u8, at: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const defaults = try defaultMacros(arena);
    const r = try expandForTest(arena, src, host_macros orelse &defaults);
    try testing.expectError(expected, r.form);
    const failure = r.failure orelse return error.TestExpectedFailure;
    try testing.expectEqualStrings(message, failure.message);
    try testing.expectEqualStrings(at, src[failure.span.pos..][0..failure.span.len]);
}

test "failure: a malformed form records a message at the innermost form" {
    const M = ExpandError.MalformedMacroCall;
    try expectFailure("(let [a] a)", null, M, "let: the binding vector needs an even number of forms", "[a]");
    try expectFailure("(let* [a 1] (loop [b] b))", null, M, "loop: the binding vector needs an even number of forms", "[b]");
    try expectFailure("(let [1 2] 3)", null, M, "cannot bind an integer", "1");
    try expectFailure("(let [{:keys k} {}] k)", null, M, ":keys takes a vector of names, not a symbol", "k");
    try expectFailure("(defn f)", null, M, "defn: expected a name and a parameter vector", "(defn f)");
    try expectFailure("(defn \"f\" [] 1)", null, M, "the name defined must be an unqualified symbol, not a string", "\"f\"");
    try expectFailure("(fn x)", null, M, "fn: expected a parameter vector", "(fn x)");
    try expectFailure("(do 1 (+ 2 (cond 1)))", null, M, "cond: needs an even number of forms", "(cond 1)");
    try expectFailure("(do 1 (+ 2 (when)))", null, M, "when: expected a test", "(when)");
    try expectFailure("(let [x 1] (set! x 2))", null, M, "set!: x is a local, not a Var", "x");
}

test "failure: a macro that fails without a message is named at its call" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const Wrap = struct {
        fn refuse(_: *ExpandContext, _: *const Form, _: []const *Form) ExpandError!*Form {
            return ExpandError.MalformedMacroCall;
        }
    };
    var table: HostMacroTable = .empty;
    try table.put(arena_state.allocator(), "refuse", Wrap.refuse);
    try expectFailure("(do 1 (+ 2 (refuse 3)))", &table, ExpandError.MalformedMacroCall, "malformed (refuse ...)", "(refuse 3)");
}

test "unwrapQuote: the reader's quote datum and a written-out (quote x) both unwrap" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{ "'x", "(quote x)" }) |src| {
        const inner = unwrapQuote(try readForTest(arena, src));
        try testing.expectEqualStrings("x", inner.datum.symbol.name);
    }
    for ([_][]const u8{ "x", "(quote x y)", "(other x)" }) |src| {
        const form = try readForTest(arena, src);
        try testing.expect(unwrapQuote(form) == form);
    }
}

test "set!: expands to var-set on the Var; a lexical target is refused at expansion" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const empty: HostMacroTable = .empty;
    const items = (try (try expandForTest(arena, "(set! *x* (+ 1 2))", &empty)).form).datum.list;
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqualStrings("nexis.core", items[0].datum.symbol.ns.?);
    try testing.expectEqualStrings("var-set", items[0].datum.symbol.name);
    const var_form = items[1].datum.list;
    try testing.expectEqualStrings("var", var_form[0].datum.symbol.name);
    try testing.expectEqualStrings("*x*", var_form[1].datum.symbol.name);
    try testing.expect(items[2].datum == .list);
    for ([_][]const u8{ "(let* [x 1] (set! x 2))", "(fn* [x] (set! x 2))", "(set! 1 2)", "(set! *x*)" }) |src| {
        try testing.expectError(ExpandError.MalformedMacroCall, (try expandForTest(arena, src, &empty)).form);
    }
}

test "macroexpand: with no macros a form comes back as it was read" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const empty: HostMacroTable = .empty;
    for ([_][]const u8{
        "42",                                             "true",                       "nil",                ":kw",                "x",
        "(+ 1 2)",                                        "(if (< x 10) :small :big)",  "(do (def y 1) y)",   "(let* [a 1] a)",     "(loop* [i 0] (if (< i 10) (recur (+ i 1)) i))",
        "(fn* fact [n] (if (< n 2) n (recur (+ n -1))))", "(letfn* [(f [x] x)] (f 7))", "(defn add [x y] x)", "(quote (when x y))", "'foo",
        "()",
    }) |src| {
        const read = try readForTest(arena, src);
        const expanded = try (try expandForTest(arena, src, &empty)).form;
        try testing.expectEqual(std.meta.activeTag(read.datum), std.meta.activeTag(expanded.datum));
    }
}

test "macroexpand: a macro that expands to itself stops at the depth limit" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Wrap = struct {
        fn loopForever(_: *ExpandContext, call_form: *const Form, _: []const *Form) ExpandError!*Form {
            return mutCast(call_form);
        }
    };
    var table: HostMacroTable = .empty;
    try table.put(arena, "boom", Wrap.loopForever);
    try testing.expectError(ExpandError.ExpansionDepthExceeded, (try expandForTest(arena, "(boom)", &table)).form);
}

test "macroexpand: nesting past the stack budget is ExpansionDepthExceeded, not a fault" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    stack.arm(64 * 1024);
    defer stack.arm(stack.main_thread_budget);
    // (do (do ... (do 1) ...)) nested far deeper than 64 KiB of frames.
    const origin: SrcSpan = .{ .pos = 0, .len = 0 };
    var form = try arena.create(Form);
    form.* = .{ .datum = .{ .int = 1 }, .origin = origin };
    const do_sym = try arena.create(Form);
    do_sym.* = .{ .datum = .{ .symbol = .{ .ns = null, .name = "do" } }, .origin = origin };
    for (0..20_000) |_| {
        const outer = try arena.create(Form);
        outer.* = .{ .datum = .{ .list = try arena.dupe(*Form, &.{ do_sym, form }) }, .origin = origin };
        form = outer;
    }
    var interner = intern_mod.Interner.init(arena);
    const empty: HostMacroTable = .empty;
    var ctx = ExpandContext{ .allocator = arena, .interner = &interner, .host_macros = &empty };
    try testing.expectError(ExpandError.ExpansionDepthExceeded, expandForm(&ctx, form));
}

test "macroexpand: a macro fires unless a lexical binding shadows its name or a quote holds it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Wrap = struct {
        fn fireIt(ctx: *ExpandContext, call_form: *const Form, _: []const *Form) ExpandError!*Form {
            return (Builder{ .ctx = ctx, .origin = call_form.origin }).kw("fired");
        }
    };
    var table: HostMacroTable = .empty;
    try table.put(arena, "my-macro", Wrap.fireIt);
    const fired = try (try expandForTest(arena, "(my-macro)", &table)).form;
    try testing.expectEqualStrings("fired", fired.datum.keyword.name);
    // `(let* [my-macro 0] (my-macro))`: the body is still the call.
    const shadowed = try (try expandForTest(arena, "(let* [my-macro 0] (my-macro))", &table)).form;
    try testing.expect(shadowed.datum.list[2].datum == .list);
    // `(quote (my-macro))` stays a quote of the list.
    const quoted = try (try expandForTest(arena, "(quote (my-macro))", &table)).form;
    try testing.expect(quoted.datum == .list and quoted.datum.list[1].datum == .list);
}
