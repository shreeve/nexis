//! compile.zig — the compiler: `reader.Form` → `Tiny` IR → bytecode.
//!
//! Authoritative spec: `docs/COMPILER.md`.
//!
//! **Pipeline**: `compileSourceWith` / `compileFormWith` macroexpand
//! the form (`expand.zig`), lower it to a `Tiny` tree (`lowerForm`),
//! and compile that tree with `compileTinyWithNamespace`. `Tiny` is
//! the only IR; there is no separate Form → bytecode path.
//!
//! **Forms lowered**:
//!
//!   - nil / bool / int literals →  `mov:load-nil` / `mov:load-true` /
//!                                  `mov:load-false` / `mov:load-const`
//!   - keywords, strings, floats, chars, quoted symbols
//!                               →  `Tiny.literal` (a const-pool Value;
//!                                  keywords and symbols need an
//!                                  Interner, strings a Heap)
//!   - `(+ a b)` / `(< a b)`     →  `math:add` / `cmp:lt`; a literal-
//!                                  pair peephole emits constant
//!                                  operands directly. These are the
//!                                  only inlined intrinsics, and only
//!                                  when not lexically shadowed
//!   - `(if <test> <then> <else?>)` → `jump:if-false` over then,
//!                                  unconditional `jump:jmp` past else,
//!                                  with PC back-patching; an absent
//!                                  else branch synthesizes nil
//!   - `<symbol>`                →  lexical local, captured upvalue, or
//!                                  namespace Var, in that order
//!                                  (COMPILER.md §4.3)
//!   - `ns/name`                 →  exact lookup through the namespace
//!                                  registry (aliases honored)
//!   - `(let* [n1 v1, ...] body)` → strict left-of-self-visibility
//!                                  per COMPILER.md §4.3 (binding-i's
//!                                  RHS sees bindings 1..i-1 only);
//!                                  `defer scope.shrinkRetainingCapacity(mark)`
//!                                  pops bindings on let-body exit
//!   - `(do e1 e2 ... eN)`       →  empty → nil; one-expr → compile
//!                                  to dst; multi-expr → all non-last
//!                                  to a SHARED discard slot, last
//!                                  to dst
//!   - `(fn* name? [params & rest?] body)` → child routine +
//!                                  `closure:make`; captures are
//!                                  pre-analyzed and boxed in
//!                                  straight-line prelude code
//!   - `(letfn* ...)`, `(loop* ...)`, `(recur ...)`, `(def ...)`,
//!     `(defn ...)`, `(var name)`
//!   - `(try body (catch any e handler) (finally ...)?)`, `(throw v)`
//!   - `#%list` / `#%concat` / `#%vector` / `#%map` / `#%set` and bare
//!     `[...]` / `{...}` / `#{...}` literals → `coll:*` opcodes
//!
//! **Architecture**: destination-driven lowering. An `Emitter`
//! accumulates code + consts + slot_count, and each form's
//! `compileExpr(emitter, form, dst, recur_target)` writes its result
//! into the caller-chosen destination slot, so `if`-arms target a
//! shared dst.
//!
//! **Limits**:
//!   - The slot allocator is monotonic: each fresh result slot bumps
//!     `slot_count`; branch-local temps are not reclaimed across the
//!     merge point. Constants are not deduplicated.
//!   - The primitive `try` takes one `(catch any binding ...)`; the
//!     expander lowers several catch clauses and keyword matchers
//!     onto it (MACROEXPAND.md §8b). A catch binding captured by an
//!     inner fn raises `UnsupportedFeature`.
//!   - Var-level shadowing of `+` / `<` does not defeat inlining;
//!     only lexical shadowing does.

const std = @import("std");
const vm = @import("vm");
const value_mod = @import("value");
/// Tests only: inspect rest-list results in variadic fn tests.
/// The compiler itself doesn't depend on list — the VM
/// constructs rest lists at call time per VM.md §6.
const list_mod = @import("list");
/// Compiler input. `lowerForm` translates a reader.Form tree
/// into `Tiny`; the backend compiles `Tiny` only (there is no
/// parallel Form → bytecode path).
const reader_mod = @import("reader");
/// Interner for quoted symbols/keywords during Form lowering.
/// `lowerQuotePayload` interns symbols/keywords through the
/// VM's shared Interner so identity is stable across compile,
/// runtime and macroexpand.
const intern_mod = @import("intern");
/// Form → Form expander: macros, syntax-quote, anon-fn, and the
/// #%list/#%concat/#%vector dispatch all live there. Expansion
/// runs BEFORE lowering whenever `compileFormWith` is given an
/// Interner; without one, no expansion fires.
const expand_mod = @import("expand");
/// Form lowering allocates string-literal Values into a stable
/// Heap so `Tiny.literal` can carry them across compile → run.
/// `LowerCtx.heap` is the optional heap; when null, `.string`
/// Forms raise `UnsupportedFeature`.
const heap_mod = @import("heap");
const string_mod = @import("string");
const bignum_mod = @import("bignum");

pub const Inst = vm.Inst;
pub const Routine = vm.Routine;
pub const Operand = vm.Operand;
pub const Value = value_mod.Value;

// =============================================================================
// Tiny — the compiler's IR.
//
// Recursive shape: sub-expressions are pointers (the compile-time
// arena owns them). Hand-construction in tests uses `&Tiny{ ... }`
// literals.
// =============================================================================

pub const Tiny = union(enum) {
    /// nil literal.
    nil,
    /// boolean literal (true / false).
    bool: bool,
    /// Integer literal in the i48 fixnum range. Form lowering puts a
    /// wider integer literal into `literal` as a bignum.
    int: i64,
    /// Reference to a lexically-bound local, a captured upvalue,
    /// or a namespace Var. Resolution walks the Emitter's scope
    /// stack innermost-first, then the parent chain (capture),
    /// then the namespace, per the COMPILER.md §4.3 priority
    /// list; unresolved names raise `CompileError.UnresolvedSymbol`.
    symbol: []const u8,
    /// Namespace-qualified symbol `prefix/name`. Resolves DIRECTLY through the namespace
    /// registry — lexical scope is NOT consulted. The compiler
    /// looks up `prefix` as a registered namespace name, then
    /// fetches `name` from that namespace's local vars (NOT
    /// walking the parent chain — qualified lookup is exact).
    /// Missing ns / missing var both surface as UnresolvedSymbol
    /// at compile time.
    qualified_symbol: struct { ns: []const u8, name: []const u8 },
    /// Generic literal Value constant. Used by `lowerQuotePayload`
    /// for quoted symbols/keywords (which become symbol/keyword
    /// Values via the VM's Interner) and by Form lowering for
    /// keywords, strings, floats and chars.
    ///
    /// Quoted nil/bool/int go through the plain Tiny variants —
    /// they're cheaper than const-pool entries.
    ///
    /// **Lifetime constraint**: the Value must be stable for the
    /// lifetime of the Compiled artifact. Interned symbols/
    /// keywords satisfy this (the Interner outlives compile +
    /// VM run). Heap-backed Values from arbitrary sources do NOT
    /// — only use `Tiny.literal` for Values with stable identity.
    literal: value_mod.Value,
    /// Runtime list construction from N evaluated subexpressions.
    /// The IR representation of the internal `#%list` special
    /// form emitted by the syntax-quote walker AND by `lowerQuotePayload`
    /// when the quoted payload is a compound list. Each item
    /// is recursively compiled into a contiguous slot block;
    /// the backend emits a single `coll:list` opcode.
    list_construct: []const *const Tiny,
    /// Runtime list concatenation. The IR
    /// representation of `#%concat`. Each arg must evaluate
    /// to a list at runtime (KindMismatch trap otherwise);
    /// result is the left-to-right concatenation.
    concat: []const *const Tiny,
    /// Runtime vector construction. IR for the
    /// `#%vector` special form emitted by syntax-quote and by
    /// `lowerQuotePayload` for vector payloads. Same block-
    /// allocation pattern as `list_construct`; backend emits
    /// `coll:vector`.
    vector_construct: []const *const Tiny,
    /// Runtime map construction. IR for the
    /// `#%map` special form + bare `{...}` literals. Items
    /// are flat k,v,k,v,... pairs (length MUST be even at
    /// build time — compiler guarantees this). Backend emits
    /// `coll:map`; duplicate keys overwrite earlier (Clojure
    /// semantics).
    map_construct: []const *const Tiny,
    /// Runtime set construction. IR for `#%set`
    /// + bare `#{...}` literals. Duplicates collapse at
    /// runtime via `champ.setConj`.
    set_construct: []const *const Tiny,
    /// `try` / `catch` / `finally`. The only catch matcher is
    /// `any` and the catch clause is mandatory; `finally` is
    /// optional. body, handler and finally are each implicit-do;
    /// binding is the catch's name.
    try_: struct {
        body: *const Tiny,
        /// catch binding name. Always present since catch is
        /// mandatory.
        binding: []const u8,
        handler: *const Tiny,
        /// Optional finally body; sees the OUTER lexical scope,
        /// not the catch binding.
        finally_: ?*const Tiny = null,
    },
    /// `(throw value)`. Compiles the value to a
    /// slot then emits `ctrl:throw <slot>`. Backend never
    /// returns from this opcode (it either jumps to a catch
    /// PC or raises VmError.UncaughtThrow).
    throw_: *const Tiny,
    /// `(+ lhs rhs)`. Sub-expressions are recursive.
    add: struct {
        lhs: *const Tiny,
        rhs: *const Tiny,
    },
    /// `(< lhs rhs)` — fixnum less-than. Lowers to `cmp:lt` per
    /// VM.md §10.
    lt: struct {
        lhs: *const Tiny,
        rhs: *const Tiny,
    },
    /// `(if test then else?)`. else_ is optional; absent else
    /// synthesizes nil per PLAN §6.1.
    /// Field name `test_` (with trailing underscore) avoids
    /// collision with Zig's `test` keyword. Same trick as `else_`.
    if_: struct {
        test_: *const Tiny,
        then: *const Tiny,
        else_: ?*const Tiny,
    },
    /// `(let* [n1 v1, n2 v2, ...] body)` per PLAN §6.1.
    /// Strict left-of-self visibility per COMPILER.md §4.3:
    /// each binding's RHS sees previous bindings only, NOT
    /// itself. Body sees all bindings. Bindings exit scope at
    /// the end of `body`.
    let_star: struct {
        bindings: []const Binding,
        body: *const Tiny,
    },
    /// `(do e1 e2 ... eN)` per PLAN §6.1.
    /// Sequential evaluation; yields the value of `eN`. Empty
    /// `(do)` yields nil. Each let_star / fn_star / loop_star
    /// body that needs multiple expressions wraps them in `do_`.
    do_: []const *const Tiny,
    /// `(fn* name? [params...] body)` per PLAN §6.1.
    /// `name` is the optional self-name; when present,
    /// the body can reference itself recursively (e.g.,
    /// `(fn* fact [n] ... (fact ...))`). Implementation uses
    /// the placeholder-cell pattern: parent emits
    /// `closure:new-cell` + `closure:make` (capturing the
    /// placeholder) + `closure:init-cell` (filling the cell
    /// with the constructed closure). The body's references
    /// to `name` resolve to the captured upvalue.
    fn_star: struct {
        name: ?[]const u8 = null,
        params: []const []const u8,
        /// `(fn* [a b & r] body)` has `params = ["a","b"]` and
        /// `rest_param = "r"`. `rest_param` is bound at slot
        /// `params.len`. At call time, the VM packs excess args
        /// into a list and installs it in that slot. `null` means
        /// fixed-arity. Tiny avoids encoding `&` as a fake symbol;
        /// `parseParams` parses `[a b & r]` into this explicit
        /// shape.
        rest_param: ?[]const u8 = null,
        body: *const Tiny,
    },
    /// `(callee args...)` — function invocation. Lowers to the
    /// range-call ABI per VM.md §6: stage callee + args in a
    /// contiguous call block, emit `call:call`. The callee may be
    /// any expression evaluating to a closure.
    call: struct {
        callee: *const Tiny,
        args: []const *const Tiny,
    },
    /// `(loop* [name1 v1 name2 v2 ...] body)` per PLAN §6.1 +
    /// COMPILER.md §5.7.
    /// Same as `let*` for binding setup (sequential RHS
    /// visibility, captured-binding cells); the loop body
    /// installs a `RecurTarget` so `(recur args...)` inside the
    /// body rebinds and jumps to the entry label.
    loop_star: struct {
        bindings: []const Binding,
        body: *const Tiny,
    },
    /// `(recur arg1 arg2 ...)` per PLAN §6.1 + COMPILER.md §5.6.
    /// Re-enters the nearest enclosing `loop*` or `fn*` with the
    /// given arguments. Must be in tail
    /// position; arity must match the target's binding count.
    /// Lowers to a parallel-assignment move (via temp slots)
    /// into the target's binding slots + `jump:jmp` to the
    /// target's entry label. NO call opcode is emitted (per
    /// VM.md §11 — recur is not a call).
    recur: struct {
        args: []const *const Tiny,
    },
    /// `(def name value?)` per PLAN §6.1.
    /// Interns a Var in the namespace (or finds the existing
    /// one), sets its root + bound, returns the Var object
    /// (Clojure semantics: `(def x 5)` evaluates to `#'x`, not
    /// to 5). If `value` is null, the Var is "declared" — root
    /// unchanged; only the intern happens (matches Clojure's
    /// arity-1 `def`, used for forward declarations).
    ///
    /// Compile-time requirement: a Namespace must be passed to
    /// `compileTiny` for `def` to compile. Without one, this
    /// raises `UnresolvedSymbol` (no namespace to put the Var
    /// in). Tests that exercise `def` build a Namespace and
    /// pass it explicitly.
    def: struct {
        name: []const u8,
        value: ?*const Tiny = null,
    },
    /// `(var name)` per PLAN §6.1. Loads the Var
    /// object itself (not its value) — Clojure's `#'name`
    /// reader form. Does NOT trap on unbound; taking a
    /// reference to a declared-but-unbound Var is legal.
    var_ref: struct {
        name: []const u8,
    },
    /// `(defn name [params...] body)` per PLAN §6.1.
    /// Sugar for `(def name (fn* name [params...] body))` —
    /// the function carries its own name as the self-name (so
    /// the body can recurse via the lexical name without going
    /// through the Var, just like a named `fn*`). The
    /// Var binding makes the function reachable from outside
    /// the form. Together: forward references between defns
    /// work because each `defn` interns its Var (possibly
    /// unbound at compile time), and call-time resolution via
    /// the Var-table picks up whatever's bound by then.
    defn: struct {
        name: []const u8,
        params: []const []const u8,
        rest_param: ?[]const u8 = null,
        body: *const Tiny,
    },
    /// `(letfn* [(name1 params1 body1) (name2 params2 body2) ...] body)`
    /// per PLAN §6.1 + COMPILER.md §5.6b.
    /// Mutually-recursive function bindings: each fn body can
    /// reference any other letfn* binding, including itself.
    /// Implementation uses placeholder cells (one per binding),
    /// constructed BEFORE any closure is built so each closure
    /// can capture the others' cells; the cells are then
    /// initialized with the constructed closure values.
    letfn_star: struct {
        bindings: []const FnBinding,
        body: *const Tiny,
    },
};

/// One binding in a `letfn*` form. Each is a function
/// definition (mutually visible across the binding group).
pub const FnBinding = struct {
    name: []const u8,
    params: []const []const u8,
    /// `& rest` binding name, when the fn is variadic.
    rest_param: ?[]const u8 = null,
    body: *const Tiny,
};

/// One binding in a `let*` form.
pub const Binding = struct {
    name: []const u8,
    value: *const Tiny,
};

/// How a lexical binding is realized in the current routine's
/// frame. A binding that capture pre-analysis marks as captured
/// is boxed in prelude code and pushed as `.cell_slot`; every
/// other binding is `.direct_slot`.
///
/// Same-frame read dispatch (in `compileSymbol`):
///   .direct_slot(s)  → emit `mov:move dst, slot(s)`
///   .cell_slot(s)    → emit `closure:get-cell dst, slot(s)`
///   .upvalue(u)      → emit `mov:move dst, u:u` (resolve(u)
///                      deref's the cell at runtime)
pub const BindingRef = union(enum) {
    /// Ordinary slot; binding's value lives directly in
    /// `slot[s]`. Most bindings stay here.
    direct_slot: u12,
    /// Slot holds a `*UpvalCell` (boxed); binding's value lives
    /// inside the cell. Chosen at binding time when pre-analysis
    /// finds a descendant fn capturing the name (COMPILER.md §6.1).
    cell_slot: u12,
    /// Binding is an inherited upvalue of the current routine,
    /// at the given index in `frame.upvalues`. Reads via U
    /// operand kind.
    upvalue: u12,
};

/// One entry in the Emitter's lexical scope stack.
pub const LocalBinding = struct {
    name: []const u8,
    ref: BindingRef,
};

/// Routine-level capture cache entry. Maps a captured name to its upvalue index, so repeat references
/// to the same outer name from different lexical scopes share
/// a single upvalue/descriptor entry.
pub const CapturedName = struct {
    name: []const u8,
    upvalue: u12,
};

/// Where `(recur args...)` should jump and which slots it
/// rebinds. Threaded through `compileExpr` in tail position.
///
/// Lifetime: the struct (and the slices it points to) is owned
/// by whichever compile* function established the target —
/// `compileLoopStar` or `compileFn`. Body compilation must
/// complete before the owning function returns.
///
/// Tail-position propagation rules (per COMPILER.md §4.4):
///   - `if` then/else: propagate the outer target
///   - `do` last expr, `let*` body, `letfn*` body: propagate
///   - `fn*` body: RESET to a new fn target (NEVER propagate
///     across function boundaries — `recur` inside a nested fn
///     must NOT escape to the outer loop/fn)
///   - `loop*` body: REPLACE with new loop target
///   - all other positions: pass `null` (recur invalid here)
pub const RecurTarget = struct {
    entry_pc: u12,
    /// The slots `recur` rebinds, in argument order: a loop's
    /// bindings, or a fn's fixed params followed by its rest
    /// slot when it has one (the rest slot takes the seq `recur`
    /// passes, exactly as it would take any value).
    binding_slots: []const u12,
    /// Per-binding flag: true iff binding's slot holds a
    /// `*UpvalCell` (pre-analysis found a descendant fn
    /// capturing it). `compileRecur` reads this to decide
    /// between fresh-cell-install (captured) and plain
    /// `mov:move` (direct) for each binding (per VM.md §11
    /// + COMPILER.md §5.6 captured-recur semantics).
    captured_mask: []const bool,
    kind: RecurTargetKind,
};

pub const RecurTargetKind = enum { loop_star, fn_star };

// =============================================================================
// Errors
// =============================================================================

pub const CompileError = error{
    /// Compiler encountered a `Tiny` variant it doesn't know how to
    /// lower. No `Tiny` variant raises it; `compileExpr` handles
    /// every variant.
    UnsupportedForm,

    /// A hand-built `Tiny.int` outside the i48 fixnum range. Form
    /// lowering never produces one: a wider literal lowers to a
    /// bignum `Tiny.literal`.
    IntegerOutOfFixnumRange,

    /// Routine has more constants than the 12-bit constant-pool
    /// operand can address (4096). Hard error; there are no
    /// extension instructions.
    ConstantPoolOverflow,

    /// Routine has more bytecode than the 12-bit jump target
    /// operand can address (4096). Hard error.
    JumpTargetOutOfRange,

    /// Routine has more slots than the 12-bit slot operand can
    /// address (4096).
    SlotOverflow,

    /// Symbol reference resolves to NONE of (local, upvalue,
    /// var, special-form, core-mapping) — per COMPILER.md §4.3.
    /// Without a namespace, anything that is not a local or an
    /// upvalue raises this.
    UnresolvedSymbol,

    /// Two parameter slots in the same `fn*` carry the same
    /// name. Clojure semantics: not allowed (unlike `let*` where
    /// sequential bindings can shadow within the same form per
    /// COMPILER.md §4.3).
    DuplicateParam,

    /// Two bindings in the same `letfn*` group carry the same
    /// name. Unlike `let*` (sequential shadowing allowed),
    /// `letfn*` names are mutually visible — duplicates
    /// create resolution ambiguity. Matches Clojure
    /// (`letfn` rejects duplicate names).
    DuplicateBinding,

    /// `(recur ...)` appears in a position that is not a tail
    /// position of an enclosing `loop*` or `fn*` body. Per
    /// PLAN §11.3 + VM.md §11 + COMPILER.md §5.6: `recur` MUST
    /// be in tail position to preserve the constant-stack
    /// guarantee.
    RecurOutsideTail,

    /// `(recur ...)` has a different argument count than the
    /// target's binding count. Per VM.md §11 + COMPILER.md
    /// §5.6. Caught at compile time (no runtime arity
    /// revalidation — recur is not a call opcode).
    RecurArityMismatch,

    /// A feature is recognized but not lowered. Raised for a
    /// non-`any` catch matcher, a catch binding captured by an inner fn, a
    /// `letfn*` binding with a rest param, quoted symbols /
    /// keywords / strings without an Interner or Heap, and
    /// `reader.Form` datums that only the expander consumes
    /// (syntax-quote, unquote, `#(...)`, `@x`, `^{...}`
    /// metadata) reaching the lowerer. Trapping loudly is better
    /// than emitting subtly-wrong code.
    UnsupportedFeature,

    /// The parser or reader rejected the source string while
    /// compiling via `compileSource` / `compileSourceWithNamespace`.
    /// Bucketed error wrapping any error from `parser.parseForm`
    /// / `reader.readOneForm`; the reader's own ErrorKind is not
    /// carried through.
    ReaderFailure,

    /// A list form (call or special form) has the wrong shape.
    /// Emitted for malformed `(if)`, `(quote)`,
    /// `(let* ...)` without a binding vector, etc. Covers
    /// arity and structural errors that the reader accepted
    /// as syntactically valid lists but the compiler rejects
    /// as semantically malformed.
    MalformedForm,

    /// Macroexpansion exceeded the depth limit (256 per
    /// MACROEXPAND.md §6). Almost always an infinite macro
    /// loop. Distinct from `MacroExpansionFailure` because
    /// users debugging macros want this signaled clearly.
    MacroDepthExceeded,

    /// Bucket for all other macroexpand errors — malformed
    /// macro call, macro returned a non-Form, etc. The original
    /// variant is not carried through; `out_span` carries the
    /// form's span.
    MacroExpansionFailure,

    /// A position required a symbol but got something else
    /// (e.g., `(let* [1 2] body)` — binding name `1` is not
    /// a symbol; `(def 42 ...)` — def name `42` is not a
    /// symbol).
    ExpectedSymbol,

    /// A position required a vector but got something else
    /// (e.g., `(let* (x 1) body)` — binding spec is a list,
    /// not a vector; `(fn* (x) body)` — param spec is a
    /// list, not a vector).
    ExpectedVector,

    /// A compiler invariant was violated. Distinct from a
    /// user-error like `UnresolvedSymbol`: this indicates the
    /// compiler reached a state it believes impossible (e.g.,
    /// `resolveOrCapture` got back `.direct_slot` for a name
    /// that pre-analysis should have boxed). Surfaces in
    /// release builds as a clean error rather than panicking;
    /// debug builds also assert.
    InternalCompilerBug,

    OutOfMemory,
};

// =============================================================================
// Output
// =============================================================================

/// The compiler's product. Wrap with `toRoutine(name)` to get a
/// `vm.Routine` ready for `vm.VM.init`. `capture_descs` supports
/// `closure:make` lowering and `fixed_arity` call-site validation.
///
/// **Ownership**: `code` and `consts` are slices allocated through
/// the allocator passed to `compileTiny()` and remain valid until
/// that allocator is reset or destroyed. There is no `deinit`
/// method — the model is "compile-time arena, drop wholesale after
/// execution." Callers using a non-arena allocator must free
/// `code` and `consts` individually.
pub const Compiled = struct {
    code: []const Inst,
    consts: []const vm.Const,
    capture_descs: []const vm.CaptureDescriptor = &.{},
    /// Per-routine Var table. The V operand index
    /// resolves through this table at runtime. Lifetime: same
    /// as the rest of the Compiled (compile-arena-owned).
    var_table: []const *vm.Var = &.{},
    slot_count: u16,
    /// Top-level Compiled has fixed_arity 0; child routines built
    /// by `compileFn` set this to their fixed parameter count.
    fixed_arity: u16 = 0,
    /// True for `(fn* [a b & r] ...)`. The VM packs
    /// excess args into a list at call time.
    variadic: bool = false,
    /// PC → source span table (VM.md §5); empty when the form was
    /// lowered without a `SpanMap`.
    spans: []const vm.SpanEntry = &.{},
    /// The span of the form this routine was lowered from.
    origin: ?vm.SourceSpan = null,
    /// The source the spans index into.
    source: ?*const vm.SourceInfo = null,

    pub fn toRoutine(self: Compiled, name: []const u8) Routine {
        return .{
            .code = self.code,
            .consts = self.consts,
            .capture_descs = self.capture_descs,
            .var_table = self.var_table,
            .slot_count = self.slot_count,
            .fixed_arity = self.fixed_arity,
            .variadic = self.variadic,
            .upvalue_count = 0, // top-level routines have no upvalues
            .name = name,
            .spans = self.spans,
            .origin = self.origin,
            .source = self.source,
        };
    }
};

/// What lowering allocates for every Tiny node: the node and the
/// span of the Form it came from. A node lowering synthesizes
/// without a Form (the `do` around a body) has no span and inherits
/// the span of the form that encloses it. The Emitter recovers the
/// node from the `Tiny` pointer with `@fieldParentPtr`, so a tree
/// compiled with spans must consist of these nodes only; hand-built
/// `&Tiny{...}` trees compile without spans.
pub const TinyNode = struct {
    span: ?reader_mod.SrcSpan = null,
    tiny: Tiny,
};

fn toSourceSpan(span: reader_mod.SrcSpan) vm.SourceSpan {
    return .{ .pos = span.pos, .len = span.len };
}

// =============================================================================
// Emitter — internal mutable accumulator
// =============================================================================

/// `Emitter` accumulates a routine's bytecode, constants, slot
/// count, and active lexical scope as a tree of `compileExpr`
/// calls runs. It's allocator-owned and turned into a `Compiled`
/// at the end via `finish()`.
///
/// **Slot allocation**: monotonic — each `allocSlot()` call returns
/// `slot_count` and bumps it. No reuse across branches; there is
/// no liveness analysis.
///
/// **Constant pool**: simple append; constants are not
/// deduplicated (COMPILER.md §4.5).
///
/// **Lexical scope**: a stack of `LocalBinding{name, ref}` pairs.
/// Resolution walks innermost-first (newest entries shadow older).
/// Bindings push at let* binding-time (after the RHS is compiled,
/// per COMPILER.md §4.3's strict left-of-self rule) and pop at
/// let-body exit via `defer scope.shrinkRetainingCapacity(mark)` —
/// `defer` rather than success-path restore so an error mid-body
/// doesn't leak scope into a recovering caller. Nested function
/// compilation resolves free names through the `parent` chain
/// (capture analysis at function boundaries).
const Emitter = struct {
    allocator: std.mem.Allocator,
    code: std.ArrayList(Inst) = .empty,
    consts: std.ArrayList(vm.Const) = .empty,
    capture_descs: std.ArrayList(vm.CaptureDescriptor) = .empty,
    scope: std.ArrayList(LocalBinding) = .empty,
    slot_count: u16 = 0,
    /// Pointer to the enclosing routine's Emitter, or null for the
    /// top-level routine. Capture discovery walks the parent
    /// chain in `resolveOrCapture`. Synchronous compilation
    /// guarantees the parent pointer remains valid throughout
    /// child compilation (parent is blocked in its
    /// `compileFn` call).
    parent: ?*Emitter = null,
    /// Captures THIS routine has registered (in
    /// upvalue-index order). Each entry is a `CaptureSource`
    /// describing how to source the cell from the PARENT
    /// frame when the parent's `closure:make` runs. The
    /// list grows in `resolveOrCapture` as inner functions
    /// discover free-variable references. At `compileFn`
    /// finalization, the parent builds a `CaptureDescriptor`
    /// from `child.captures` and registers it in its own
    /// `capture_descs` table.
    captures: std.ArrayList(vm.CaptureSource) = .empty,
    /// Routine-level cache of captured names → upvalue-index.
    /// Separate from
    /// `scope` so inner `let_star` scope restoration cannot
    /// pop a captured-binding entry. Without this, the same
    /// outer name referenced in two unrelated inner scopes
    /// would be captured twice (two upvalue indices, two
    /// descriptor sources, double-allocated cell pointer in
    /// the closure). Lexical locals take precedence (resolved
    /// via `scope` first), so shadowing is preserved.
    captured_names: std.ArrayList(CapturedName) = .empty,
    /// Per-routine Var table. The compiler appends
    /// to this when it sees a `def`, a `(var x)`, or a
    /// symbol-fall-through-to-Var resolution. Index in this
    /// list becomes the V operand index in emitted bytecode.
    /// Routines built from a child Emitter (compileFn) carry
    /// their own table independent of the parent's; Vars are
    /// global per-namespace and only the index encoding is
    /// per-routine.
    var_table: std.ArrayList(*vm.Var) = .empty,
    /// Namespace used for `def` / `var` / symbol fall-through.
    /// `null` means no namespace was passed to `compileTiny`;
    /// in that case `def`/`var_ref` raise `UnresolvedSymbol`
    /// and unresolved symbols stay unresolved. Child Emitters
    /// inherit the parent's namespace pointer.
    namespace: ?*vm.Namespace = null,
    /// Whether every Tiny node is the `tiny` field of a `TinyNode`
    /// (a tree `lowerForm` built), so its span can be read; false
    /// for a hand-built tree, which compiles without a span table.
    spanned: bool = false,
    /// The span the next emitted instruction is attributed to:
    /// that of the innermost form being compiled, set on entry to
    /// `compileExpr` and restored on exit, so an instruction a
    /// parent emits after its children carries the parent's span.
    current_span: ?reader_mod.SrcSpan = null,
    /// The run-length table `emit` grows: a new entry whenever
    /// `current_span` differs from the last entry's.
    span_table: std.ArrayList(vm.SpanEntry) = .empty,
    /// The source every span of this routine indexes into.
    source: ?*const vm.SourceInfo = null,

    fn init(allocator: std.mem.Allocator) Emitter {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *Emitter) void {
        self.span_table.deinit(self.allocator);
        self.code.deinit(self.allocator);
        self.consts.deinit(self.allocator);
        self.capture_descs.deinit(self.allocator);
        self.scope.deinit(self.allocator);
        self.captures.deinit(self.allocator);
        self.captured_names.deinit(self.allocator);
        self.var_table.deinit(self.allocator);
    }

    /// Look up a name in the routine-level capture cache.
    /// Returns the existing upvalue index if this routine has
    /// already captured `name`; null otherwise.
    fn lookupCapturedName(self: *const Emitter, name: []const u8) ?u12 {
        for (self.captured_names.items) |c| {
            if (std.mem.eql(u8, c.name, name)) return c.upvalue;
        }
        return null;
    }

    /// Push a direct-slot binding onto the lexical scope. Does
    /// NOT allocate a slot — the caller already has one
    /// (typically the slot the binding's RHS was just compiled
    /// into). Bindings that pre-analysis marks as captured are
    /// pushed as `.cell_slot` by the caller instead.
    fn pushBinding(self: *Emitter, name: []const u8, slot: u12) CompileError!void {
        try self.scope.append(self.allocator, .{ .name = name, .ref = .{ .direct_slot = slot } });
    }

    /// Resolve `name` to a `BindingRef` via innermost-shadow
    /// lookup of ONLY the current Emitter's scope. Returns null
    /// if no binding matches; callers walk the parent chain via
    /// `resolveOrCapture` if appropriate. Returns the full
    /// BindingRef so callers can dispatch on direct/cell/upvalue
    /// at emit time.
    fn resolveLocalRef(self: *const Emitter, name: []const u8) ?BindingRef {
        var i = self.scope.items.len;
        while (i > 0) {
            i -= 1;
            const b = self.scope.items[i];
            if (std.mem.eql(u8, b.name, name)) return b.ref;
        }
        return null;
    }

    /// Walk self, then parents, to resolve `name` into a
    /// `BindingRef` suitable for emit-time dispatch in
    /// `compileSymbol`. If found in self.scope, returns the
    /// ref directly. If found in a parent, performs the capture
    /// dance per COMPILER.md §6.1: registers `self.captures`
    /// (recording how to source the cell from parent), pushes
    /// the binding into self.scope as `.upvalue(u)` so
    /// subsequent references in the same routine resolve
    /// directly, returns `.upvalue(u)`. Recurses transitively
    /// for grandparent-and-beyond captures (each level
    /// captures from its own parent so the chain delivers a
    /// cell pointer to the innermost level).
    ///
    /// **Pre-analysis invariant**: captured bindings are
    /// guaranteed `.cell_slot` (or `.upvalue`, transitively) by
    /// the time `resolveOrCapture` walks the parent chain. A
    /// parent returning `.direct_slot` for a captured name
    /// indicates pre-analysis missed the capture — that's a
    /// compiler bug, caught by the assertion below. Nothing
    /// boxes a binding mid-codegen.
    ///
    /// Returns `UnresolvedSymbol` if no enclosing scope (up
    /// the entire parent chain) has the name.
    fn resolveOrCapture(self: *Emitter, name: []const u8) CompileError!BindingRef {
        // 1. Lexical scope, innermost-first. Lexical locals
        // (params, let_star bindings) shadow any captures with
        // the same name, preserving lexical scope semantics.
        if (self.resolveLocalRef(name)) |ref| return ref;
        // 2. Routine-level capture cache. If THIS routine has
        // already captured `name` (from a sibling scope, or
        // earlier in the body), reuse the existing upvalue index
        // instead of registering a new one. This avoids the
        // "synthetic upvalue popped by inner let_star scope
        // restoration" hazard.
        if (self.lookupCapturedName(name)) |u| return .{ .upvalue = u };
        // 3. Walk the parent chain.
        const parent = self.parent orelse return CompileError.UnresolvedSymbol;
        const parent_ref = try parent.resolveOrCapture(name);
        // 4. Convert parent's ref into a CaptureSource for
        // self.captures. Pre-analysis guarantees a captured
        // name's parent binding is .cell_slot (or .upvalue);
        // a .direct_slot return here means pre-analysis missed
        // a capture — compiler bug.
        const source: vm.CaptureSource = switch (parent_ref) {
            .cell_slot => |s| .{ .local_cell_slot = s },
            .upvalue => |u| .{ .inherited_upvalue = u },
            .direct_slot => {
                // Pre-analysis boxes every captured binding at
                // let_star binding time or fn_star param entry.
                // Reaching here is a compiler bug, reported as
                // such rather than as UnresolvedSymbol (the
                // symbol DID resolve; the box is what's missing).
                std.debug.assert(false);
                return CompileError.InternalCompilerBug;
            },
        };
        // 5. Register the capture. Append the source to
        // self.captures (in upvalue-index order) AND record
        // the name → upvalue mapping in captured_names so
        // subsequent lookups dedupe. NOT pushed into self.scope
        // because scope is for lexical bindings only — a
        // capture there could be popped by inner let_star
        // scope restoration.
        const u_idx_usize = self.captures.items.len;
        if (u_idx_usize >= 4096) return CompileError.SlotOverflow;
        const u_idx: u12 = @intCast(u_idx_usize);
        try self.captures.append(self.allocator, source);
        try self.captured_names.append(self.allocator, .{ .name = name, .upvalue = u_idx });
        return .{ .upvalue = u_idx };
    }

    /// Allocate a fresh result slot. Slots are monotonic; there
    /// is no reclamation.
    fn allocSlot(self: *Emitter) CompileError!u12 {
        if (self.slot_count >= 4096) return CompileError.SlotOverflow;
        const s = self.slot_count;
        self.slot_count += 1;
        return @intCast(s);
    }

    /// Allocate a contiguous run of `count` fresh slots, return the
    /// base index. Required by `compileCall` to reserve the call
    /// block BEFORE compiling sub-expressions: per-arg `allocSlot`
    /// interleaved with sub-expression compilation would be
    /// incorrect — sub-expressions allocate their own temps and
    /// the next "arg slot" would not be adjacent to the previous,
    /// breaking the range-call ABI invariant.
    fn allocSlotBlock(self: *Emitter, count: u32) CompileError!u12 {
        const base: u32 = self.slot_count;
        const end: u32 = base + count;
        if (end > 4096) return CompileError.SlotOverflow;
        self.slot_count = @intCast(end);
        return @intCast(base);
    }

    /// Add a constant to the pool, return its index. Constants are
    /// not deduplicated. Most callers want `addValueConst(v)` for
    /// an ordinary `Value` or `addRoutineConst(*const Routine)`
    /// for `closure:make` lowering.
    fn addConst(self: *Emitter, c: vm.Const) CompileError!u12 {
        const idx = self.consts.items.len;
        if (idx >= 4096) return CompileError.ConstantPoolOverflow;
        try self.consts.append(self.allocator, c);
        return @intCast(idx);
    }

    /// Convenience: add a `Value` constant (the common case).
    fn addValueConst(self: *Emitter, v: Value) CompileError!u12 {
        return self.addConst(.{ .value = v });
    }

    /// Convenience: add a `*const Routine` constant. Used by
    /// `compileFn` when registering a child routine in the
    /// parent's pool for `closure:make`.
    fn addRoutineConst(self: *Emitter, r: *const vm.Routine) CompileError!u12 {
        return self.addConst(.{ .routine = r });
    }

    /// Add a capture descriptor to the emitter's table; return
    /// the descriptor's index for use as `closure:make`'s B
    /// operand. Sources are `local_cell_slot` /
    /// `inherited_upvalue` entries, or none for a capture-free fn.
    fn addCaptureDescriptor(self: *Emitter, desc: vm.CaptureDescriptor) CompileError!u12 {
        const idx = self.capture_descs.items.len;
        if (idx >= 4096) return CompileError.ConstantPoolOverflow;
        try self.capture_descs.append(self.allocator, desc);
        return @intCast(idx);
    }

    /// Get-or-create a V operand index for `name` in
    /// the current routine's var_table. Interns the Var in the
    /// namespace (creating an unbound Var if absent), then
    /// dedup-appends to var_table. Returns the V operand index.
    /// Requires `self.namespace != null`; callers should check
    /// first and surface `UnresolvedSymbol` otherwise.
    ///
    /// Dedup: a routine that references `x` twice gets ONE
    /// var_table entry (same V index). Matches the const-pool
    /// dedup pattern.
    fn addVarRef(self: *Emitter, name: []const u8) CompileError!u12 {
        const ns = self.namespace orelse return CompileError.InternalCompilerBug;
        // Lookup walks the parent chain (auto-refer fallback to
        // `nexis.core` etc.). If found there, use
        // that Var directly. Only fall through to `intern` (which
        // creates a NEW unbound Var in `ns` itself, supporting
        // forward references) when no existing Var resolves.
        const v = if (ns.lookup(name)) |existing_v|
            existing_v
        else
            ns.intern(name) catch return CompileError.OutOfMemory;
        return self.addVarTableEntry(v);
    }

    /// The V operand index of the current namespace's OWN Var
    /// named `name`, created unbound when absent and never a
    /// referred one: what `def` binds, and what a symbol qualified
    /// with the current namespace's name means. A definition
    /// therefore shadows a referred Var of the same name for this
    /// namespace and leaves the referred Var as it was.
    fn addVarLocal(self: *Emitter, name: []const u8) CompileError!u12 {
        const ns = self.namespace orelse return CompileError.InternalCompilerBug;
        const v = ns.intern(name) catch return CompileError.OutOfMemory;
        return self.addVarTableEntry(v);
    }

    /// Dedup-append `v` to the routine's var table: a routine that
    /// references one Var twice carries one entry.
    fn addVarTableEntry(self: *Emitter, v: *vm.Var) CompileError!u12 {
        for (self.var_table.items, 0..) |existing, i| {
            if (existing == v) return @intCast(i);
        }
        const idx = self.var_table.items.len;
        if (idx >= 4096) return CompileError.SlotOverflow;
        try self.var_table.append(self.allocator, v);
        return @intCast(idx);
    }

    /// Append an instruction to the code stream, opening a new
    /// span-table run when its span differs from the last one.
    fn emit(self: *Emitter, inst: Inst) CompileError!void {
        if (self.current_span) |span| {
            const n = self.span_table.items.len;
            const same = n > 0 and self.span_table.items[n - 1].span.pos == span.pos and self.span_table.items[n - 1].span.len == span.len;
            if (!same) {
                try self.span_table.append(self.allocator, .{
                    .pc = @intCast(self.code.items.len),
                    .span = toSourceSpan(span),
                });
            }
        }
        try self.code.append(self.allocator, inst);
    }

    /// Current PC = next instruction offset. Used as jump targets
    /// for forward back-patching.
    fn currentPc(self: *const Emitter) u12 {
        const pc = self.code.items.len;
        return @intCast(pc);
    }

    /// Patch a previously-emitted jump's target operand. The
    /// caller must have remembered the jump's PC index.
    fn patchJumpAt(self: *Emitter, jump_pc: usize, target_pc: u12) void {
        vm.asm_.patchJumpTarget(&self.code.items[jump_pc], target_pc);
    }

    /// Emit `jump:if-false A=PLACEHOLDER B=test`. Returns the PC
    /// of the emitted instruction so the caller can back-patch
    /// the target later.
    fn emitJumpIfFalsePlaceholder(self: *Emitter, test_op: Operand) CompileError!usize {
        const pc = self.code.items.len;
        try self.emit(vm.asm_.jumpIfFalse(0, test_op));
        return pc;
    }

    /// Emit `jump:jmp A=PLACEHOLDER`. Returns the PC of the
    /// emitted instruction for back-patching.
    fn emitJumpPlaceholder(self: *Emitter) CompileError!usize {
        const pc = self.code.items.len;
        try self.emit(vm.asm_.jumpJmp(0));
        return pc;
    }

    /// Range-check `target_pc` fits in the 12-bit operand and
    /// return the typed value.
    fn checkJumpTarget(self: *const Emitter, target_pc: usize) CompileError!u12 {
        _ = self;
        if (target_pc >= 4096) return CompileError.JumpTargetOutOfRange;
        return @intCast(target_pc);
    }

    /// Convert the accumulated state into an owned `Compiled`.
    ///
    /// Ownership transfer is errdefer-safe: if
    /// any `toOwnedSlice` fails after a previous one succeeded,
    /// the earlier slice would leak under a non-arena allocator.
    /// The chained errdefers guard against that.
    fn finish(self: *Emitter) CompileError!Compiled {
        const code = try self.code.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(code);
        const consts = try self.consts.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(consts);
        const caps = try self.capture_descs.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(caps);
        const vt = try self.var_table.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(vt);
        const spans = try self.span_table.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(spans);
        return .{
            .code = code,
            .consts = consts,
            .capture_descs = caps,
            .var_table = vt,
            .slot_count = if (self.slot_count == 0) 1 else self.slot_count,
            .fixed_arity = 0, // top-level only; compileFn sets this for child routines via Routine struct
            .variadic = false, // top-level routine never variadic
            .spans = spans,
            .source = self.source,
        };
    }
};

// =============================================================================
// Public API
// =============================================================================

/// Compile a `Tiny` form to a `Compiled` artifact. Named
/// `compileTiny` rather than `compile` to make it loud that this
/// entry point accepts the `Tiny` IR directly; source and Form
/// callers use `compileSourceWith` / `compileFormWith`.
pub fn compileTiny(allocator: std.mem.Allocator, form: *const Tiny) CompileError!Compiled {
    return compileTinyWithNamespace(allocator, form, null);
}

/// Compile with a Namespace for `def` / `(var x)` /
/// symbol-fall-through-to-Var resolution. Call sites that don't
/// use vars call `compileTiny` (namespace=null), and unresolved
/// symbols raise `UnresolvedSymbol`. Tests that exercise `def` build a
/// Namespace (typically `VM.ensureNamespace()`'s) and pass it
/// here.
pub fn compileTinyWithNamespace(
    allocator: std.mem.Allocator,
    form: *const Tiny,
    namespace: ?*vm.Namespace,
) CompileError!Compiled {
    return compileTinyWithSpans(allocator, form, namespace, false, null, null);
}

/// `compileTinyWithNamespace` for a tree `lowerForm` built
/// (`spanned`), with the span of the top-level form and the source
/// it came from, so the routine and every routine nested in it
/// carry a span table.
pub fn compileTinyWithSpans(
    allocator: std.mem.Allocator,
    form: *const Tiny,
    namespace: ?*vm.Namespace,
    spanned: bool,
    origin: ?reader_mod.SrcSpan,
    source: ?*const vm.SourceInfo,
) CompileError!Compiled {
    var emitter = Emitter.init(allocator);
    emitter.namespace = namespace;
    emitter.spanned = spanned;
    emitter.current_span = origin;
    emitter.source = source;
    errdefer emitter.deinit();

    // Top-level form compiles into slot 0; routine returns slot 0.
    // Top-level position has NO enclosing loop/fn → recur_target is null.
    // A top-level `(recur)` correctly raises RecurOutsideTail.
    const dst = try emitter.allocSlot();
    try compileExpr(&emitter, form, dst, null);
    try emitter.emit(vm.asm_.returnSlot(dst));

    var compiled = try emitter.finish();
    compiled.origin = if (origin) |o| toSourceSpan(o) else null;
    return compiled;
}

// =============================================================================
// Form → Tiny lowering
// =============================================================================
//
// `lowerForm` converts a `reader.Form` tree into a `Tiny` IR tree on the
// passed allocator. The Tiny tree is then compiled via the backend
// (`compileTinyWithNamespace`), so the entire codegen pipeline (capture
// pre-analysis, RecurTarget threading, variadic rest, Var fall-through,
// etc.) runs on the one Tiny path. There is no parallel "compile Form
// directly to bytecode" path.
//
// Lowering covers literals, symbols, list dispatch (ordinary calls,
// special forms, the `+` / `<` intrinsics when not lexically shadowed),
// binding/fn forms (let*, fn*, letfn*, loop*, recur), var forms
// (def, defn, var), try/throw, quote, and collection literals. The
// lowering env (`LowerEnv`) tracks lexical-name shadowing for
// intrinsic dispatch.

/// Allocate and initialize a Tiny node on the given allocator.
/// Used by `lowerForm` to build the IR tree. The arena passed to
/// `compileForm`/`compileSource` owns these allocations. Every node
/// is a `TinyNode` so `lowerFormEnv` can attach the Form's span.
fn allocTiny(allocator: std.mem.Allocator, value: Tiny) CompileError!*Tiny {
    const node = try allocator.create(TinyNode);
    node.* = .{ .tiny = value };
    return &node.tiny;
}

/// Form-lowering context bundle. Passes both the lexical environment (for intrinsic shadowing)
/// and the Interner (for quoted-symbol/quoted-keyword Value
/// construction) through every `lower*` helper. Small (2
/// pointers); copied by value at each level — child contexts
/// override `env` while inheriting `interner`.
///
/// Why a bundle: every helper that recurses into `lowerFormEnv`
/// needs to pass BOTH. Threading two parallel parameters through
/// ~15 helpers is mechanical churn that this struct collapses to
/// one parameter.
pub const LowerCtx = struct {
    env: ?*const LowerEnv = null,
    interner: ?*intern_mod.Interner = null,
    /// Heap for allocating string-literal Values during Form →
    /// Tiny lowering. Strings reach the lowerer as `Datum.string`
    /// ([]const u8 in the reader's arena) and need a stable Heap
    /// so the resulting Value can live in `Tiny.literal` for the
    /// artifact's lifetime. When null, `.string` Forms lower to
    /// `UnsupportedFeature`.
    heap: ?*heap_mod.Heap = null,
    /// The namespace symbols resolve in. With `declared` set, a
    /// symbol that is neither lexically bound, resolvable here
    /// (including referred namespaces) nor declared is a compile
    /// error instead of an unbound Var.
    namespace: ?*vm.Namespace = null,
    declared: ?*const DeclaredNames = null,
    diag: ?*LowerDiag = null,

    /// Create a child context with a new env; everything else
    /// carries over.
    pub fn withEnv(self: LowerCtx, env: ?*const LowerEnv) LowerCtx {
        var copy = self;
        copy.env = env;
        return copy;
    }
};

/// Where lowering failed, when it can say more precisely than
/// "somewhere in this top-level form".
pub const LowerDiag = struct {
    span: ?reader_mod.SrcSpan = null,
};

/// Names a file or REPL line defines at top level, collected before
/// any of its forms compile, so a form may refer to a Var that a
/// later form defines. Keys are owned copies.
pub const DeclaredNames = struct {
    allocator: std.mem.Allocator,
    names: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(allocator: std.mem.Allocator) DeclaredNames {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DeclaredNames) void {
        var it = self.names.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.names.deinit(self.allocator);
    }

    pub fn contains(self: *const DeclaredNames, name: []const u8) bool {
        return self.names.contains(name);
    }

    pub fn declare(self: *DeclaredNames, name: []const u8) !void {
        if (self.names.contains(name)) return;
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        try self.names.put(self.allocator, owned, {});
    }

    /// Record every name `form` defines, at any depth: `def`,
    /// `defn`, `defmacro`, `defrecord` (the type id, `->T`,
    /// `map->T`, `T?`) and `defprotocol` (the protocol and each
    /// method). A definition inside a `let`, a `when` or a call
    /// interns its Var when it runs, exactly like one at top level,
    /// so it is declared wherever it appears; quoted data is not
    /// walked.
    pub fn declareForm(self: *DeclaredNames, form: *const reader_mod.Form) !void {
        const items: []const *reader_mod.Form = switch (form.datum) {
            .list => |items| items,
            .vector, .map, .set => |items| {
                for (items) |item| try self.declareForm(item);
                return;
            },
            else => return,
        };
        for (items) |item| try self.declareForm(item);
        if (items.len < 2 or items[0].datum != .symbol or items[0].datum.symbol.ns != null) return;
        const head = items[0].datum.symbol.name;
        // `^meta` on the name wraps it in with_meta.
        const name_form = if (items[1].datum == .with_meta) items[1].datum.with_meta.target else items[1];
        if (name_form.datum != .symbol or name_form.datum.symbol.ns != null) return;
        const name = name_form.datum.symbol.name;
        if (std.mem.eql(u8, head, "def") or std.mem.eql(u8, head, "defn") or std.mem.eql(u8, head, "defmacro")) {
            try self.declare(name);
        } else if (std.mem.eql(u8, head, "defrecord")) {
            try self.declare(name);
            var derived = try expand_mod.RecordNames.init(self.allocator, name);
            defer derived.deinit(self.allocator);
            for (derived.all()) |derived_name| try self.declare(derived_name);
        } else if (std.mem.eql(u8, head, "defprotocol")) {
            try self.declare(name);
            for (items[2..]) |sig| {
                if (sig.datum != .list or sig.datum.list.len == 0) continue;
                const m = sig.datum.list[0];
                if (m.datum == .symbol and m.datum.symbol.ns == null) try self.declare(m.datum.symbol.name);
            }
        }
    }
};

/// Form-lowering lexical environment. Tracks lexical names that are visible in operator position so
/// the dispatcher can decide whether to inline intrinsics like
/// `+` and `<` or fall through to ordinary call lowering.
///
/// This is NOT slot resolution — that happens in the backend via
/// `resolveOrCapture`. LowerEnv ONLY exists to make the
/// shadowing rule for inlineable core fns work correctly:
///
///   (let* [+ (fn* [a b] 42)] (+ 1 2))   ;; ordinary call, not Tiny.add
///   (let* [if 1] (if true 2 3))          ;; STILL special form `if`
///
/// Special forms (`if`, `do`, `let*`, `fn*`, `letfn*`, `loop*`,
/// `recur`, `quote`, `def`, `defn`, `var`) are RESERVED in operator
/// position — they're recognized regardless of lexical bindings.
/// Only the inlineable core fns (`+`, `<`) check the env.
///
/// Limit: the shadowing check is lexical-only. Namespace-level
/// Var shadowing — `(do (def + f) (+ 1 2))` — inlines `+` to
/// `Tiny.add` because the lowerer doesn't track Vars (see
/// CLOJURE-REVIEW.md §1.7's "core inlining" discussion).
pub const LowerEnv = struct {
    /// Names bound at THIS scope level. The full visibility set
    /// is the union of this set with the parent's set,
    /// transitively. Linear-lookup string set (matches the
    /// backend's NameSet pattern).
    lexical_names: NameSet = .{},
    parent: ?*const LowerEnv = null,

    /// Innermost-first lookup walks the parent chain.
    fn contains(self: *const LowerEnv, name: []const u8) bool {
        if (self.lexical_names.contains(name)) return true;
        if (self.parent) |p| return p.contains(name);
        return false;
    }

    fn deinit(self: *LowerEnv, allocator: std.mem.Allocator) void {
        self.lexical_names.deinit(allocator);
    }
};

/// Whether an unqualified symbol names something: a lexical
/// binding, a Var visible from the namespace (its own or a
/// referred one), or a name the enclosing file declares.
fn symbolResolves(ctx: LowerCtx, declared: *const DeclaredNames, name: []const u8) bool {
    if (ctx.env) |env| {
        if (env.contains(name)) return true;
    }
    if (ctx.namespace) |ns| {
        if (ns.lookup(name) != null) return true;
    }
    return declared.contains(name);
}

/// The namespace a qualified symbol's prefix names from `ns`: an
/// alias registered there resolves to its target, any other
/// prefix is a namespace name. Null when nothing is registered
/// under it.
fn qualifiedTarget(ns: *const vm.Namespace, ns_prefix: []const u8) ?*vm.Namespace {
    const registry = ns.registry orelse return null;
    const effective = if (ns.aliases_initialized) (ns.lookupAlias(ns_prefix) orelse ns_prefix) else ns_prefix;
    return registry.lookupNs(effective);
}

/// Helper used by `lowerList` to test whether a head symbol is a
/// shadowable intrinsic. Special forms are NOT shadowable; they
/// have their own switch arm.
fn isIntrinsicShadowed(env: ?*const LowerEnv, name: []const u8) bool {
    const e = env orelse return false;
    return e.contains(name);
}

/// Translate a `reader.Form` tree into a `Tiny` IR tree on the
/// passed allocator. Public entry; passes a null `LowerEnv` so
/// top-level forms see no lexical bindings (correct — the
/// top-level operator-position is the outermost scope). Internal
/// recursion goes through `lowerFormEnv` which threads the env.
///
/// Symbol names are NOT duped — they're borrowed from the
/// reader's source string. The caller must keep that source
/// alive for the lifetime of the Compiled artifact.
pub fn lowerForm(
    allocator: std.mem.Allocator,
    form: *const reader_mod.Form,
) CompileError!*Tiny {
    return lowerFormEnv(allocator, form, .{});
}

/// `lowerForm` with the lexical environment threaded through
/// `ctx`. The env is consulted only when classifying list-head
/// symbols as intrinsics vs ordinary calls. Recursion into
/// sub-expressions passes the env through unchanged; binding
/// forms (let*, fn*, loop*, letfn*) construct a child env that
/// adds their bindings.
fn lowerFormEnv(
    allocator: std.mem.Allocator,
    form: *const reader_mod.Form,
    ctx: LowerCtx,
) CompileError!*Tiny {
    const tiny = try lowerDatum(allocator, form, ctx);
    // A node lowering passes through unchanged (`(do x)` is `x`)
    // keeps the innermost form's span, the one set first.
    const node: *TinyNode = @fieldParentPtr("tiny", tiny);
    if (node.span == null) node.span = form.origin;
    return tiny;
}

fn lowerDatum(
    allocator: std.mem.Allocator,
    form: *const reader_mod.Form,
    ctx: LowerCtx,
) CompileError!*Tiny {
    return switch (form.datum) {
        .nil => try allocTiny(allocator, .nil),
        .bool_ => |b| try allocTiny(allocator, .{ .bool = b }),
        .int => |n| try lowerInt(allocator, n, ctx),
        .bigint => |text| try lowerBigInt(allocator, text, ctx),
        .symbol => |name| blk: {
            // Qualified symbols `ns/name` lower to
            // `Tiny.qualified_symbol`; compileSymbol handles
            // dispatch through the namespace registry. One that
            // names the current namespace is checked like a bare
            // symbol, so a forward reference a macro qualified
            // still resolves through the file's declarations.
            if (name.ns) |ns_prefix| {
                if (ctx.declared) |declared| {
                    if (ctx.namespace) |ns| {
                        if (qualifiedTarget(ns, ns_prefix) == ns and ns.lookupLocal(name.name) == null and !declared.contains(name.name)) {
                            if (ctx.diag) |d| d.span = form.origin;
                            return CompileError.UnresolvedSymbol;
                        }
                    }
                }
                break :blk try allocTiny(allocator, .{ .qualified_symbol = .{ .ns = ns_prefix, .name = name.name } });
            }
            if (ctx.declared) |declared| {
                if (!symbolResolves(ctx, declared, name.name)) {
                    if (ctx.diag) |d| d.span = form.origin;
                    return CompileError.UnresolvedSymbol;
                }
            }
            break :blk try allocTiny(allocator, .{ .symbol = name.name });
        },
        .list => |items| try lowerList(allocator, items, ctx),
        // Bare keywords are self-evaluating per Clojure
        // semantics. Lowers to Tiny.literal via the Interner.
        // Without an Interner, falls back to UnsupportedFeature.
        // A qualified keyword interns its full `ns/name` text, the
        // same way qualified symbols do.
        .keyword => |name| blk: {
            const interner = ctx.interner orelse return CompileError.UnsupportedFeature;
            const v = interner.internQualifiedKeyword(name.ns, name.name) catch return CompileError.OutOfMemory;
            break :blk try allocTiny(allocator, .{ .literal = v });
        },
        // Floats and chars are immediates: they lower straight
        // to `Tiny.literal` with no interner or heap involved.
        .real => |f| try allocTiny(allocator, .{ .literal = value_mod.fromFloat(f) }),
        .char => |c| try allocTiny(allocator, .{
            .literal = value_mod.fromChar(c) orelse return CompileError.MalformedForm,
        }),
        // String literals lower through the heap plumbed into
        // LowerCtx. The Value goes into `Tiny.literal`; the heap
        // is the same one routines and closures use, so the
        // string lifetime tracks the artifact. Without a heap the
        // form raises UnsupportedFeature.
        .string => |bytes| blk: {
            const h = ctx.heap orelse return CompileError.UnsupportedFeature;
            const v = string_mod.fromBytes(h, bytes) catch return CompileError.OutOfMemory;
            break :blk try allocTiny(allocator, .{ .literal = v });
        },
        // `{k1 v1 k2 v2 ...}` as an expression → each key +
        // value is a normal expression, evaluated
        // left-to-right. The runtime
        // map-builder fires after all are evaluated; duplicate
        // keys keep the LATER value.
        .map => |items| blk: {
            if (items.len % 2 != 0) return CompileError.MalformedForm;
            const tiny_items = try allocator.alloc(*const Tiny, items.len);
            for (items, 0..) |item, i| {
                tiny_items[i] = try lowerFormEnv(allocator, item, ctx);
            }
            break :blk try allocTiny(allocator, .{ .map_construct = tiny_items });
        },
        // `#{a b c}` as an expression. Each element
        // is a normal expression; duplicates collapse at
        // runtime via `champ.setConj`.
        .set => |items| blk: {
            const tiny_items = try allocator.alloc(*const Tiny, items.len);
            for (items, 0..) |item, i| {
                tiny_items[i] = try lowerFormEnv(allocator, item, ctx);
            }
            break :blk try allocTiny(allocator, .{ .set_construct = tiny_items });
        },
        // `[a b c]` as an expression: same shape as maps/sets.
        .vector => |items| blk: {
            const tiny_items = try allocator.alloc(*const Tiny, items.len);
            for (items, 0..) |item, i| {
                tiny_items[i] = try lowerFormEnv(allocator, item, ctx);
            }
            break :blk try allocTiny(allocator, .{ .vector_construct = tiny_items });
        },
        // Reader macros / meta.
        .quote => |inner| try lowerQuotePayload(allocator, inner, ctx),
        .syntax_quote, .unquote, .unquote_splicing => return CompileError.UnsupportedFeature,
        // `@x`, `#(...)` and `^{...}` are rewritten by the
        // expander; the lowerer rejects the raw reader forms.
        .deref => return CompileError.UnsupportedFeature,
        .anon_fn => return CompileError.UnsupportedFeature,
        .with_meta => return CompileError.UnsupportedFeature,
    };
}

// =============================================================================
// Form list dispatch: special forms + intrinsics + calls
// =============================================================================
//
// Operator-position head-symbol dispatch. Special forms are
// RESERVED (recognized regardless of lexical bindings). Inlineable
// core fns are checked against the LowerEnv — if the name is
// lexically shadowed, fall through to ordinary call lowering.
// Everything else lowers to `Tiny.call`.

/// Lower a list form. The list represents either a call (head is
/// any expression evaluating to a closure) or a special form
/// (head is a reserved symbol like `if`, `do`, `let*`, etc.).
///
/// The literal `()` is the empty list, as in Clojure.
fn lowerList(
    allocator: std.mem.Allocator,
    items: []const *reader_mod.Form,
    ctx: LowerCtx,
) CompileError!*Tiny {
    if (items.len == 0) return try allocTiny(allocator, .{ .list_construct = &.{} });
    // Head-symbol dispatch only fires when head is an unqualified
    // symbol. Qualified symbols (`foo/x`) and non-symbol heads
    // (calls of computed values) fall through to ordinary call.
    if (items[0].datum == .symbol and items[0].datum.symbol.ns == null) {
        const name = items[0].datum.symbol.name;
        // -- Special forms (NOT shadowable) --
        if (std.mem.eql(u8, name, "do")) return try lowerDo(allocator, items[1..], ctx);
        if (std.mem.eql(u8, name, "if")) return try lowerIf(allocator, items[1..], ctx);
        if (std.mem.eql(u8, name, "quote")) return try lowerQuote(allocator, items[1..], ctx);
        // Internal compiler primitives for collection construction.
        // NOT user-shadowable (recognized as special forms in the
        // dispatcher, never checked against the macro table or
        // lexical env). Per MACROEXPAND.md §5 this is the
        // unshadowable substrate that syntax-quote emits.
        if (std.mem.eql(u8, name, "#%list")) return try lowerInternalList(allocator, items[1..], ctx);
        if (std.mem.eql(u8, name, "#%concat")) return try lowerInternalConcat(allocator, items[1..], ctx);
        if (std.mem.eql(u8, name, "#%vector")) return try lowerInternalVector(allocator, items[1..], ctx);
        if (std.mem.eql(u8, name, "#%map")) return try lowerInternalMap(allocator, items[1..], ctx);
        if (std.mem.eql(u8, name, "#%set")) return try lowerInternalSet(allocator, items[1..], ctx);
        // Binding forms.
        if (std.mem.eql(u8, name, "let*")) return try lowerLetStar(allocator, items[1..], ctx);
        if (std.mem.eql(u8, name, "loop*")) return try lowerLoopStar(allocator, items[1..], ctx);
        if (std.mem.eql(u8, name, "recur")) return try lowerRecur(allocator, items[1..], ctx);
        if (std.mem.eql(u8, name, "fn*")) return try lowerFnStar(allocator, items[1..], ctx);
        if (std.mem.eql(u8, name, "letfn*")) return try lowerLetFnStar(allocator, items[1..], ctx);
        // Var forms.
        if (std.mem.eql(u8, name, "def")) return try lowerDef(allocator, items[1..], ctx);
        if (std.mem.eql(u8, name, "defn")) return try lowerDefn(allocator, items[1..], ctx);
        if (std.mem.eql(u8, name, "var")) return try lowerVarRef(allocator, items[1..]);
        if (std.mem.eql(u8, name, "try")) return try lowerTry(allocator, items[1..], ctx);
        if (std.mem.eql(u8, name, "throw")) return try lowerThrow(allocator, items[1..], ctx);
        // -- Inlineable intrinsics (shadowable) --
        if (std.mem.eql(u8, name, "+") and items.len == 3 and !isIntrinsicShadowed(ctx.env, name)) {
            return try lowerAdd(allocator, items[1], items[2], ctx);
        }
        if (std.mem.eql(u8, name, "<") and items.len == 3 and !isIntrinsicShadowed(ctx.env, name)) {
            return try lowerLt(allocator, items[1], items[2], ctx);
        }
    }
    // Ordinary call: lower head as callee, rest as args.
    return try lowerCall(allocator, items, ctx);
}

/// `(do exprs...)`. Empty `(do)` lowers to `Tiny.do_` with an
/// empty slice (backend synthesizes nil). Multi-expression do
/// passes through as `Tiny.do_` (backend evaluates non-last for
/// effect, returns last).
fn lowerDo(
    allocator: std.mem.Allocator,
    body_items: []const *reader_mod.Form,
    ctx: LowerCtx,
) CompileError!*Tiny {
    const exprs = try allocator.alloc(*const Tiny, body_items.len);
    for (body_items, 0..) |item, i| {
        exprs[i] = try lowerFormEnv(allocator, item, ctx);
    }
    return try allocTiny(allocator, .{ .do_ = exprs });
}

/// `(if test then)` or `(if test then else)`. Missing else
/// synthesizes nil (matches Tiny semantics).
fn lowerIf(
    allocator: std.mem.Allocator,
    args: []const *reader_mod.Form,
    ctx: LowerCtx,
) CompileError!*Tiny {
    if (args.len != 2 and args.len != 3) return CompileError.MalformedForm;
    const test_ = try lowerFormEnv(allocator, args[0], ctx);
    const then = try lowerFormEnv(allocator, args[1], ctx);
    const else_: ?*const Tiny = if (args.len == 3)
        try lowerFormEnv(allocator, args[2], ctx)
    else
        null;
    return try allocTiny(allocator, .{ .if_ = .{
        .test_ = test_,
        .then = then,
        .else_ = else_,
    } });
}

/// `(quote x)`. Scalars that already map to Tiny variants are
/// lowered to those variants directly (saves const-pool entries
/// for fixnums/bools/nil). Quoted symbols, keywords and compound
/// collections become `Tiny.literal` through the Interner (see
/// `lowerQuotePayload`).
fn lowerQuote(
    allocator: std.mem.Allocator,
    args: []const *reader_mod.Form,
    ctx: LowerCtx,
) CompileError!*Tiny {
    if (args.len != 1) return CompileError.MalformedForm;
    return lowerQuotePayload(allocator, args[0], ctx);
}

/// Lower `(#%list a b c)` — recursively lower each
/// arg as a normal evaluable expression, then build a
/// Tiny.list_construct with those subtrees. The args ARE
/// evaluated (this is NOT quote-like opacity); macros nested
/// in args do expand.
fn lowerInternalList(
    allocator: std.mem.Allocator,
    args: []const *reader_mod.Form,
    ctx: LowerCtx,
) CompileError!*Tiny {
    const tiny_items = try allocator.alloc(*const Tiny, args.len);
    for (args, 0..) |a, i| tiny_items[i] = try lowerFormEnv(allocator, a, ctx);
    return try allocTiny(allocator, .{ .list_construct = tiny_items });
}

/// Lower `(#%concat a b c)` — same shape as
/// `#%list`. Each arg must evaluate to a list value at runtime
/// (KindMismatch trap otherwise — enforced by the VM, not the
/// compiler, since we can't statically know an expression's
/// kind in general).
fn lowerInternalConcat(
    allocator: std.mem.Allocator,
    args: []const *reader_mod.Form,
    ctx: LowerCtx,
) CompileError!*Tiny {
    const tiny_items = try allocator.alloc(*const Tiny, args.len);
    for (args, 0..) |a, i| tiny_items[i] = try lowerFormEnv(allocator, a, ctx);
    return try allocTiny(allocator, .{ .concat = tiny_items });
}

/// Lower `(#%vector a b c)` — same pattern as
/// `#%list` but emits Tiny.vector_construct (backend: coll:vector).
fn lowerInternalVector(
    allocator: std.mem.Allocator,
    args: []const *reader_mod.Form,
    ctx: LowerCtx,
) CompileError!*Tiny {
    const tiny_items = try allocator.alloc(*const Tiny, args.len);
    for (args, 0..) |a, i| tiny_items[i] = try lowerFormEnv(allocator, a, ctx);
    return try allocTiny(allocator, .{ .vector_construct = tiny_items });
}

/// Lower `(#%map k1 v1 k2 v2 ...)`. Args MUST be
/// even (compiler raises MalformedForm otherwise; the runtime
/// also enforces). Backend: coll:map → champ.mapAssoc per pair.
fn lowerInternalMap(
    allocator: std.mem.Allocator,
    args: []const *reader_mod.Form,
    ctx: LowerCtx,
) CompileError!*Tiny {
    if (args.len % 2 != 0) return CompileError.MalformedForm;
    const tiny_items = try allocator.alloc(*const Tiny, args.len);
    for (args, 0..) |a, i| tiny_items[i] = try lowerFormEnv(allocator, a, ctx);
    return try allocTiny(allocator, .{ .map_construct = tiny_items });
}

/// Lower `(#%set a b c)`. Duplicates collapse at
/// runtime via `champ.setConj`. Backend: coll:set.
fn lowerInternalSet(
    allocator: std.mem.Allocator,
    args: []const *reader_mod.Form,
    ctx: LowerCtx,
) CompileError!*Tiny {
    const tiny_items = try allocator.alloc(*const Tiny, args.len);
    for (args, 0..) |a, i| tiny_items[i] = try lowerFormEnv(allocator, a, ctx);
    return try allocTiny(allocator, .{ .set_construct = tiny_items });
}

/// Shared implementation for `(quote x)` and the reader-macro
/// `'x` (which the reader emits as `Datum.quote`).
///
/// Quoted symbols/keywords use the Interner from
/// `ctx.interner` to produce stable symbol/keyword Values
/// emitted via `Tiny.literal`. Without an Interner
/// (`ctx.interner == null`), quoted symbols/keywords raise
/// `UnsupportedFeature` — the caller is expected to use
/// `compileSourceWith` / `compileFormWith` to pass an Interner.
/// Quoted nil/bool/int never need the Interner.
///
/// Quoted compound collections (lists/vectors/maps/sets) lower
/// to the matching `*_construct` node whose elements are
/// themselves quote-lowered; quoted strings need `ctx.heap`. A
/// quote inside the payload is the 2-list `(quote x)`, as
/// `formToValue` renders it. Quoted reader macros (`'@x`,
/// `'#(...)`, `'^{...}`, syntax-quote) raise `UnsupportedFeature`.
fn lowerQuotePayload(
    allocator: std.mem.Allocator,
    payload: *const reader_mod.Form,
    ctx: LowerCtx,
) CompileError!*Tiny {
    return switch (payload.datum) {
        .nil => try allocTiny(allocator, .nil),
        .bool_ => |b| try allocTiny(allocator, .{ .bool = b }),
        .int => |n| try lowerInt(allocator, n, ctx),
        .bigint => |text| try lowerBigInt(allocator, text, ctx),
        .symbol => |name| blk: {
            // Qualified symbols intern the full
            // `ns/name` string; valueToForm splits it back into
            // ns + name on the way out. This lets macros emit
            // qualified-symbol literals like `(quote db/begin-write)`.
            const interner = ctx.interner orelse return CompileError.UnsupportedFeature;
            if (name.ns) |ns_prefix| {
                const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ ns_prefix, name.name });
                defer allocator.free(full);
                const v = interner.internSymbolValue(full) catch return CompileError.OutOfMemory;
                break :blk try allocTiny(allocator, .{ .literal = v });
            }
            const v = interner.internSymbolValue(name.name) catch return CompileError.OutOfMemory;
            break :blk try allocTiny(allocator, .{ .literal = v });
        },
        .keyword => |name| blk: {
            const interner = ctx.interner orelse return CompileError.UnsupportedFeature;
            const v = interner.internQualifiedKeyword(name.ns, name.name) catch return CompileError.OutOfMemory;
            break :blk try allocTiny(allocator, .{ .literal = v });
        },
        // Quoted compound list, `(quote (1 2 3))`. Each element
        // is recursively quote-lowered (so a
        // nested `(quote (foo (bar baz)))` builds nested lists
        // of interned symbols). Lowers to `Tiny.list_construct`
        // with each element being a literal/recursive quote
        // payload — NOT a normal evaluation (per the quote
        // contract: elements are data, not source forms).
        .list => |items| blk: {
            const tiny_items = try allocator.alloc(*const Tiny, items.len);
            for (items, 0..) |item, i| {
                tiny_items[i] = try lowerQuotePayload(allocator, item, ctx);
            }
            break :blk try allocTiny(allocator, .{ .list_construct = tiny_items });
        },
        // Quoted compound vector. Same pattern as
        // quoted list — elements are recursively quote-lowered.
        .vector => |items| blk: {
            const tiny_items = try allocator.alloc(*const Tiny, items.len);
            for (items, 0..) |item, i| {
                tiny_items[i] = try lowerQuotePayload(allocator, item, ctx);
            }
            break :blk try allocTiny(allocator, .{ .vector_construct = tiny_items });
        },
        // Quoted compound map. Items are k,v,k,v...
        // recursively quote-lowered. The reader ensures even
        // arity for `{...}` source syntax; defensive check
        // here in case a synthesized map form sneaks in.
        .map => |items| blk: {
            if (items.len % 2 != 0) return CompileError.MalformedForm;
            const tiny_items = try allocator.alloc(*const Tiny, items.len);
            for (items, 0..) |item, i| {
                tiny_items[i] = try lowerQuotePayload(allocator, item, ctx);
            }
            break :blk try allocTiny(allocator, .{ .map_construct = tiny_items });
        },
        // Quoted compound set. Duplicate elements
        // collapse via runtime `champ.setConj`.
        .set => |items| blk: {
            const tiny_items = try allocator.alloc(*const Tiny, items.len);
            for (items, 0..) |item, i| {
                tiny_items[i] = try lowerQuotePayload(allocator, item, ctx);
            }
            break :blk try allocTiny(allocator, .{ .set_construct = tiny_items });
        },
        // Quoting a self-evaluating literal yields the literal.
        .real => |f| try allocTiny(allocator, .{ .literal = value_mod.fromFloat(f) }),
        .char => |c| try allocTiny(allocator, .{
            .literal = value_mod.fromChar(c) orelse return CompileError.MalformedForm,
        }),
        .string => |bytes| blk: {
            const h = ctx.heap orelse return CompileError.UnsupportedFeature;
            const v = string_mod.fromBytes(h, bytes) catch return CompileError.OutOfMemory;
            break :blk try allocTiny(allocator, .{ .literal = v });
        },
        // `'(a 'b)` is `(a (quote b))`: the inner quote is data, the
        // 2-list `formToValue` renders it as.
        .quote => |inner| blk: {
            const interner = ctx.interner orelse return CompileError.UnsupportedFeature;
            const quote_sym = interner.internSymbolValue("quote") catch return CompileError.OutOfMemory;
            const tiny_items = try allocator.alloc(*const Tiny, 2);
            tiny_items[0] = try allocTiny(allocator, .{ .literal = quote_sym });
            tiny_items[1] = try lowerQuotePayload(allocator, inner, ctx);
            break :blk try allocTiny(allocator, .{ .list_construct = tiny_items });
        },
        else => return CompileError.UnsupportedFeature,
    };
}

/// An integer literal: `Tiny.int` in the fixnum range, otherwise a
/// bignum `Tiny.literal` on the heap plumbed into `LowerCtx`
/// (without a heap the literal is `UnsupportedFeature`, as a string
/// literal is).
fn lowerInt(allocator: std.mem.Allocator, n: i64, ctx: LowerCtx) CompileError!*Tiny {
    if (value_mod.isFixnumRange(n)) return allocTiny(allocator, .{ .int = n });
    const h = ctx.heap orelse return CompileError.UnsupportedFeature;
    const v = bignum_mod.fromI64(h, n) catch return CompileError.OutOfMemory;
    return allocTiny(allocator, .{ .literal = v });
}

/// A `bigint` literal (the reader's canonical decimal text) as a
/// bignum `Tiny.literal`.
fn lowerBigInt(allocator: std.mem.Allocator, text: []const u8, ctx: LowerCtx) CompileError!*Tiny {
    const h = ctx.heap orelse return CompileError.UnsupportedFeature;
    const parsed = bignum_mod.parseDecimal(h, text) catch return CompileError.OutOfMemory;
    const v = parsed orelse return CompileError.MalformedForm;
    return allocTiny(allocator, .{ .literal = v });
}

/// `(+ a b)`. Caller has already verified arity (3 list items)
/// and unshadowed status.
fn lowerAdd(
    allocator: std.mem.Allocator,
    lhs: *const reader_mod.Form,
    rhs: *const reader_mod.Form,
    ctx: LowerCtx,
) CompileError!*Tiny {
    const t_lhs = try lowerFormEnv(allocator, lhs, ctx);
    const t_rhs = try lowerFormEnv(allocator, rhs, ctx);
    return try allocTiny(allocator, .{ .add = .{ .lhs = t_lhs, .rhs = t_rhs } });
}

/// `(< a b)`. Caller has already verified arity and unshadowed.
fn lowerLt(
    allocator: std.mem.Allocator,
    lhs: *const reader_mod.Form,
    rhs: *const reader_mod.Form,
    ctx: LowerCtx,
) CompileError!*Tiny {
    const t_lhs = try lowerFormEnv(allocator, lhs, ctx);
    const t_rhs = try lowerFormEnv(allocator, rhs, ctx);
    return try allocTiny(allocator, .{ .lt = .{ .lhs = t_lhs, .rhs = t_rhs } });
}

/// Ordinary function call `(callee args...)`. Lowers head as
/// callee (any expression), rest as args.
fn lowerCall(
    allocator: std.mem.Allocator,
    items: []const *reader_mod.Form,
    ctx: LowerCtx,
) CompileError!*Tiny {
    std.debug.assert(items.len >= 1);
    const callee = try lowerFormEnv(allocator, items[0], ctx);
    const args = try allocator.alloc(*const Tiny, items.len - 1);
    for (items[1..], 0..) |item, i| {
        args[i] = try lowerFormEnv(allocator, item, ctx);
    }
    return try allocTiny(allocator, .{ .call = .{ .callee = callee, .args = args } });
}

// =============================================================================
// Form binding-form lowering
// =============================================================================
//
// `let*`, `fn*`, `letfn*`, `loop*`, `recur`. All share the same
// structural-validation primitives + the implicit-do helper
// (multi-form bodies synthesize Tiny.do_).
//
// LowerEnv must mirror lexical visibility for intrinsic
// shadowing. Each binding
// form constructs a child env that adds its bound names, then
// passes it through body lowering.

/// Lower a sequence of body forms into a single Tiny expression.
/// Multi-form bodies wrap in `Tiny.do_`; single-form bodies pass
/// through; an empty body is nil, as `(do)` is.
fn lowerBody(
    allocator: std.mem.Allocator,
    body_items: []const *reader_mod.Form,
    ctx: LowerCtx,
) CompileError!*Tiny {
    if (body_items.len == 0) return try allocTiny(allocator, .nil);
    if (body_items.len == 1) return try lowerFormEnv(allocator, body_items[0], ctx);
    const exprs = try allocator.alloc(*const Tiny, body_items.len);
    for (body_items, 0..) |item, i| {
        exprs[i] = try lowerFormEnv(allocator, item, ctx);
    }
    return try allocTiny(allocator, .{ .do_ = exprs });
}

/// Helper: assert a Form is an unqualified symbol and return its
/// name. Used for binding names, param names, def names.
fn expectUnqualifiedSymbol(form: *const reader_mod.Form) CompileError![]const u8 {
    return switch (form.datum) {
        .symbol => |name| blk: {
            if (name.ns != null) return CompileError.ExpectedSymbol;
            break :blk name.name;
        },
        else => CompileError.ExpectedSymbol,
    };
}

/// Helper: assert a Form is a vector and return its items.
fn expectVector(form: *const reader_mod.Form) CompileError![]const *reader_mod.Form {
    return switch (form.datum) {
        .vector => |items| items,
        else => CompileError.ExpectedVector,
    };
}

/// Parsed param vector for `fn*`/`defn`: split fixed params from
/// optional `& rest`.
const ParsedParams = struct {
    params: []const []const u8,
    rest_param: ?[]const u8,
};

fn parseParams(
    allocator: std.mem.Allocator,
    param_vector_items: []const *reader_mod.Form,
) CompileError!ParsedParams {
    // Scan for the `&` separator. Validation:
    //   - at most one `&`
    //   - `&` followed by exactly one symbol
    //   - no symbols after the rest param
    var amp_pos: ?usize = null;
    for (param_vector_items, 0..) |item, i| {
        if (item.datum == .symbol and
            item.datum.symbol.ns == null and
            std.mem.eql(u8, item.datum.symbol.name, "&"))
        {
            if (amp_pos != null) return CompileError.MalformedForm;
            amp_pos = i;
        }
    }
    if (amp_pos) |pos| {
        // `& rest` form. Expect exactly `pos + 2` items
        // (the `&` itself + one rest symbol).
        if (pos + 2 != param_vector_items.len) return CompileError.MalformedForm;
        const rest_name = try expectUnqualifiedSymbol(param_vector_items[pos + 1]);
        const params = try allocator.alloc([]const u8, pos);
        for (param_vector_items[0..pos], 0..) |item, i| {
            params[i] = try expectUnqualifiedSymbol(item);
        }
        return .{ .params = params, .rest_param = rest_name };
    }
    // No rest. Each item is a fixed param symbol.
    const params = try allocator.alloc([]const u8, param_vector_items.len);
    for (param_vector_items, 0..) |item, i| {
        params[i] = try expectUnqualifiedSymbol(item);
    }
    return .{ .params = params, .rest_param = null };
}

/// `(let* [name1 expr1 name2 expr2 ...] body...)`. Sequential
/// binding semantics per Tiny.let_star: binding-i's RHS sees
/// bindings 1..i-1 in scope (LowerEnv); body sees all bindings.
fn lowerLetStar(
    allocator: std.mem.Allocator,
    args: []const *reader_mod.Form,
    ctx: LowerCtx,
) CompileError!*Tiny {
    if (args.len < 1) return CompileError.MalformedForm;
    const binding_vec = try expectVector(args[0]);
    if (binding_vec.len % 2 != 0) return CompileError.MalformedForm;
    const n_bindings = binding_vec.len / 2;
    const bindings = try allocator.alloc(Binding, n_bindings);

    // Sequential env extension: each RHS sees
    // prior bindings only. We allocate one child env and grow its
    // name set as we go.
    var local = LowerEnv{ .parent = ctx.env };
    defer local.deinit(allocator);

    var i: usize = 0;
    while (i < n_bindings) : (i += 1) {
        const name = try expectUnqualifiedSymbol(binding_vec[i * 2]);
        const value = try lowerFormEnv(allocator, binding_vec[i * 2 + 1], ctx.withEnv(&local));
        bindings[i] = .{ .name = name, .value = value };
        try local.lexical_names.put(allocator, name);
    }

    const body = try lowerBody(allocator, args[1..], ctx.withEnv(&local));
    return try allocTiny(allocator, .{ .let_star = .{ .bindings = bindings, .body = body } });
}

/// `(loop* [name1 expr1 ...] body...)`. Same shape as let*.
fn lowerLoopStar(
    allocator: std.mem.Allocator,
    args: []const *reader_mod.Form,
    ctx: LowerCtx,
) CompileError!*Tiny {
    if (args.len < 1) return CompileError.MalformedForm;
    const binding_vec = try expectVector(args[0]);
    if (binding_vec.len % 2 != 0) return CompileError.MalformedForm;
    const n_bindings = binding_vec.len / 2;
    const bindings = try allocator.alloc(Binding, n_bindings);

    var local = LowerEnv{ .parent = ctx.env };
    defer local.deinit(allocator);

    var i: usize = 0;
    while (i < n_bindings) : (i += 1) {
        const name = try expectUnqualifiedSymbol(binding_vec[i * 2]);
        const value = try lowerFormEnv(allocator, binding_vec[i * 2 + 1], ctx.withEnv(&local));
        bindings[i] = .{ .name = name, .value = value };
        try local.lexical_names.put(allocator, name);
    }

    const body = try lowerBody(allocator, args[1..], ctx.withEnv(&local));
    return try allocTiny(allocator, .{ .loop_star = .{ .bindings = bindings, .body = body } });
}

/// `(recur args...)`. No binding form; just lowers args and
/// wraps in `Tiny.recur`. Backend handles tail-position
/// validation + arity match against the active RecurTarget.
fn lowerRecur(
    allocator: std.mem.Allocator,
    args: []const *reader_mod.Form,
    ctx: LowerCtx,
) CompileError!*Tiny {
    const recur_args = try allocator.alloc(*const Tiny, args.len);
    for (args, 0..) |item, i| {
        recur_args[i] = try lowerFormEnv(allocator, item, ctx);
    }
    return try allocTiny(allocator, .{ .recur = .{ .args = recur_args } });
}

/// `(fn* name? [params... & rest?] body...)`. Optional self-name
/// detected by checking whether the FIRST arg after `fn*` is a
/// symbol (vs the param vector).
fn lowerFnStar(
    allocator: std.mem.Allocator,
    args: []const *reader_mod.Form,
    ctx: LowerCtx,
) CompileError!*Tiny {
    if (args.len < 1) return CompileError.MalformedForm;
    // Optional self-name: first arg is a symbol, the param vector
    // follows it; the body may be empty.
    var pos: usize = 0;
    var self_name: ?[]const u8 = null;
    if (args[0].datum == .symbol and args.len >= 2) {
        self_name = try expectUnqualifiedSymbol(args[0]);
        pos = 1;
    }
    const param_vec = try expectVector(args[pos]);
    const parsed = try parseParams(allocator, param_vec);

    // Body env: outer env + params + rest + self-name.
    // Each name is added so an inner
    // intrinsic-name reference is correctly shadowed.
    var body_env = LowerEnv{ .parent = ctx.env };
    defer body_env.deinit(allocator);
    for (parsed.params) |p| try body_env.lexical_names.put(allocator, p);
    if (parsed.rest_param) |rp| try body_env.lexical_names.put(allocator, rp);
    if (self_name) |n| try body_env.lexical_names.put(allocator, n);

    const body = try lowerBody(allocator, args[pos + 1 ..], ctx.withEnv(&body_env));
    return try allocTiny(allocator, .{ .fn_star = .{
        .name = self_name,
        .params = parsed.params,
        .rest_param = parsed.rest_param,
        .body = body,
    } });
}

/// `(letfn* [(name [params] body...) ...] body...)`. Each
/// binding entry is itself a list of (name param-vector body...).
/// All binding names are mutually visible across all fn bodies
/// AND across the letfn body.
fn lowerLetFnStar(
    allocator: std.mem.Allocator,
    args: []const *reader_mod.Form,
    ctx: LowerCtx,
) CompileError!*Tiny {
    if (args.len < 1) return CompileError.MalformedForm;
    const binding_vec = try expectVector(args[0]);
    const bindings = try allocator.alloc(FnBinding, binding_vec.len);

    // 1. Extract all binding names into a shared env BEFORE
    // lowering any fn body (mutual visibility per Tiny semantics).
    var local = LowerEnv{ .parent = ctx.env };
    defer local.deinit(allocator);
    for (binding_vec, 0..) |entry, i| {
        const entry_items = switch (entry.datum) {
            .list => |items| items,
            else => return CompileError.MalformedForm,
        };
        if (entry_items.len < 2) return CompileError.MalformedForm;
        const name = try expectUnqualifiedSymbol(entry_items[0]);
        const param_vec = try expectVector(entry_items[1]);
        const parsed = try parseParams(allocator, param_vec);
        bindings[i] = .{
            .name = name,
            .params = parsed.params,
            .rest_param = parsed.rest_param,
            .body = undefined, // patched in 2. below
        };
        try local.lexical_names.put(allocator, name);
    }

    // 2. Lower each fn body with local env (includes all
    // letfn names) + that fn's params.
    for (binding_vec, 0..) |entry, i| {
        const entry_items = entry.datum.list;
        var body_env = LowerEnv{ .parent = &local };
        defer body_env.deinit(allocator);
        for (bindings[i].params) |p| try body_env.lexical_names.put(allocator, p);
        if (bindings[i].rest_param) |rp| try body_env.lexical_names.put(allocator, rp);
        bindings[i].body = try lowerBody(allocator, entry_items[2..], ctx.withEnv(&body_env));
    }

    // 3. Lower the letfn body with local env.
    const body = try lowerBody(allocator, args[1..], ctx.withEnv(&local));
    return try allocTiny(allocator, .{ .letfn_star = .{ .bindings = bindings, .body = body } });
}

// =============================================================================
// Form var-form lowering
// =============================================================================
//
// `def`, `defn`, `(var x)`. The backend (Tiny.def, Tiny.defn,
// Tiny.var_ref) handles forward references, identity-stable
// rebind, and the named-fn placeholder pattern. This layer is
// purely Form-side dispatch + structural validation.
//
// LowerEnv does NOT add def/defn names — Vars don't shadow
// intrinsic inlining. `(do (def + f) (+ 1 2))` inlines to 3.
// See the LowerEnv doc comment.

/// `(def name)` or `(def name value)`. Per Tiny.def shape, the
/// value is optional (declare-only).
fn lowerDef(
    allocator: std.mem.Allocator,
    args: []const *reader_mod.Form,
    ctx: LowerCtx,
) CompileError!*Tiny {
    if (args.len != 1 and args.len != 2) return CompileError.MalformedForm;
    const name = try expectUnqualifiedSymbol(args[0]);
    const value: ?*const Tiny = if (args.len == 2)
        try lowerFormEnv(allocator, args[1], ctx)
    else
        null;
    return try allocTiny(allocator, .{ .def = .{ .name = name, .value = value } });
}

/// `(defn name [params... & rest?] body...)`. Sugar for
/// `(def name (fn* name [params...] body))`, but we lower
/// directly to `Tiny.defn` which has the same compileDefn path.
fn lowerDefn(
    allocator: std.mem.Allocator,
    args: []const *reader_mod.Form,
    ctx: LowerCtx,
) CompileError!*Tiny {
    if (args.len < 2) return CompileError.MalformedForm;
    const name = try expectUnqualifiedSymbol(args[0]);
    const param_vec = try expectVector(args[1]);
    const parsed = try parseParams(allocator, param_vec);

    // Body env: outer env + params + rest + self-name (defn's
    // name IS its self-name per Tiny.defn lowering).
    var body_env = LowerEnv{ .parent = ctx.env };
    defer body_env.deinit(allocator);
    for (parsed.params) |p| try body_env.lexical_names.put(allocator, p);
    if (parsed.rest_param) |rp| try body_env.lexical_names.put(allocator, rp);
    try body_env.lexical_names.put(allocator, name);

    const body = try lowerBody(allocator, args[2..], ctx.withEnv(&body_env));
    return try allocTiny(allocator, .{ .defn = .{
        .name = name,
        .params = parsed.params,
        .rest_param = parsed.rest_param,
        .body = body,
    } });
}

/// `(var name)` → returns the Var object (NOT its value). Does
/// not trap on unbound. Maps to Tiny.var_ref.
fn lowerVarRef(
    allocator: std.mem.Allocator,
    args: []const *reader_mod.Form,
) CompileError!*Tiny {
    if (args.len != 1) return CompileError.MalformedForm;
    const name = try expectUnqualifiedSymbol(args[0]);
    return try allocTiny(allocator, .{ .var_ref = .{ .name = name } });
}

/// Lower `(try body+ (catch any binding handler+) (finally ...)?)`.
/// The only catch matcher at this level is `any`; the expander
/// lowers keyword matchers and several clauses onto it.
///
/// Form syntax:
///   (try body... (catch any binding handler...))
///   (try body... (catch any binding handler...) (finally ...))
///
/// Enforcement:
///   - Exactly one body+catch+optional-finally shape.
///   - catch matcher MUST be the unqualified symbol `any`;
///     anything else is UnsupportedFeature.
///   - catch binding MUST be an unqualified symbol.
fn lowerTry(
    allocator: std.mem.Allocator,
    args: []const *reader_mod.Form,
    ctx: LowerCtx,
) CompileError!*Tiny {
    if (args.len < 1) return CompileError.MalformedForm;

    // Last arg should be the catch (or finally).
    // Partition by walking from the end: optional finally
    // (last), then required catch, then body.
    var end = args.len;
    var finally_form: ?*reader_mod.Form = null;

    // Check for finally as last clause.
    {
        const last = args[end - 1];
        if (last.datum == .list and last.datum.list.len >= 1) {
            const head = last.datum.list[0];
            if (head.datum == .symbol and
                head.datum.symbol.ns == null and
                std.mem.eql(u8, head.datum.symbol.name, "finally"))
            {
                finally_form = last;
                end -= 1;
            }
        }
    }

    if (end < 1) return CompileError.MalformedForm;
    const catch_form = args[end - 1];
    if (catch_form.datum != .list or catch_form.datum.list.len < 3) {
        return CompileError.MalformedForm;
    }
    const catch_items = catch_form.datum.list;
    const catch_head = catch_items[0];
    if (catch_head.datum != .symbol or
        catch_head.datum.symbol.ns != null or
        !std.mem.eql(u8, catch_head.datum.symbol.name, "catch"))
    {
        return CompileError.MalformedForm;
    }
    // (catch MATCHER BINDING handler+) — matcher must be `any`.
    const matcher_form = catch_items[1];
    if (matcher_form.datum != .symbol or
        matcher_form.datum.symbol.ns != null or
        !std.mem.eql(u8, matcher_form.datum.symbol.name, "any"))
    {
        return CompileError.UnsupportedFeature;
    }
    const binding = try expectUnqualifiedSymbol(catch_items[2]);
    const handler_items = catch_items[3..];

    // Body = args[0..end-1] (implicit do over multiple forms).
    const body_items = args[0 .. end - 1];
    const body = try lowerBody(allocator, body_items, ctx);

    // Handler env: outer env + binding name. The binding is
    // visible in operator position for intrinsic-shadowing
    // (matches the LowerEnv discipline elsewhere).
    var handler_env: LowerEnv = .{ .parent = ctx.env };
    defer handler_env.deinit(allocator);
    try handler_env.lexical_names.put(allocator, binding);
    const handler_body = try lowerBody(allocator, handler_items, ctx.withEnv(&handler_env));

    // Lower the finally body if present. It sees
    // the OUTER lexical env (NOT the catch binding).
    var finally_tiny: ?*const Tiny = null;
    if (finally_form) |ff| {
        if (ff.datum != .list or ff.datum.list.len < 1) return CompileError.MalformedForm;
        const fitems = ff.datum.list;
        // (finally body...) — body forms.
        finally_tiny = try lowerBody(allocator, fitems[1..], ctx);
    }

    return try allocTiny(allocator, .{
        .try_ = .{
            .body = body,
            .binding = binding,
            .handler = handler_body,
            .finally_ = finally_tiny,
        },
    });
}

/// Lower `(throw value)` — single arg.
fn lowerThrow(
    allocator: std.mem.Allocator,
    args: []const *reader_mod.Form,
    ctx: LowerCtx,
) CompileError!*Tiny {
    if (args.len != 1) return CompileError.MalformedForm;
    const value = try lowerFormEnv(allocator, args[0], ctx);
    return try allocTiny(allocator, .{ .throw_ = value });
}

/// Compile a `reader.Form` tree into a `Compiled` artifact, no
/// namespace. Equivalent to `compileTiny(allocator, lowerForm(form))`.
/// Symbols that don't resolve lexically raise `UnresolvedSymbol`
/// (no Var fall-through without a namespace).
pub fn compileForm(
    allocator: std.mem.Allocator,
    form: *const reader_mod.Form,
) CompileError!Compiled {
    return compileFormWithNamespace(allocator, form, null);
}

/// Compile a `reader.Form` tree into a `Compiled` artifact, with
/// namespace access for `def` / `(var x)` / symbol fall-through.
/// Equivalent to `compileTinyWithNamespace(allocator, lowerForm(form), ns)`.
pub fn compileFormWithNamespace(
    allocator: std.mem.Allocator,
    form: *const reader_mod.Form,
    namespace: ?*vm.Namespace,
) CompileError!Compiled {
    return compileFormFull(allocator, form, namespace, null);
}

/// user_data for the
/// CompileEvalContext callback. The `persistent_allocator` is
/// CRITICAL — defmacro Closures must outlive the per-form
/// compile arena (REPL uses a fresh arena per input line; the
/// macro Closure has to survive into the next form's
/// invocation). Typically wired to `vm.runtime_arena.allocator()`.
const CompileEvalData = struct {
    /// Used by the callback for synthetic Routine + Compiled
    /// artifact storage. Must outlive ALL subsequent forms
    /// that might invoke the macro.
    persistent_allocator: std.mem.Allocator,
    namespace: ?*vm.Namespace,
    interner: *intern_mod.Interner,
    /// The user VM's heap through its namespace registry; the
    /// sub-VM allocates on it.
    registry_heap: ?*heap_mod.Heap,
};

/// Compile-time eval callback. Compiles `form`
/// WITHOUT a macro table (the body has already been expanded by
/// the expander before this is called) and runs it via a fresh
/// sub-VM written through `out_vm`.
///
/// **Lifetime contract** (per expand.CompileEvalContext): the
/// returned Value may reference `out_vm.runtime_arena`. The
/// caller MUST extract whatever it needs from the result + call
/// `out_vm.deinit()` to release the arena. The synthetic
/// Routine itself lives in `data.allocator` (the compile
/// arena), so it outlives the sub-VM.
fn compileEvalCallback(
    user_data: *anyopaque,
    form: *const reader_mod.Form,
    out_vm: *vm.VM,
) anyerror!value_mod.Value {
    const data: *CompileEvalData = @ptrCast(@alignCast(user_data));
    var dummy_span: ?reader_mod.SrcSpan = null;
    // Compile into the PERSISTENT allocator (typically the
    // user VM's runtime_arena). The macro fn's Closure +
    // Routine + capture_descs all live there and outlive
    // any per-form compile arena.
    const compiled = try compileFormFullWithMacrosSpan(
        data.persistent_allocator,
        form,
        data.namespace,
        data.interner,
        null,
        &dummy_span,
    );
    const routine_storage = try data.persistent_allocator.create(vm.Routine);
    routine_storage.* = compiled.toRoutine("defmacro-eval");
    out_vm.* = try vm.VM.init(data.persistent_allocator, routine_storage);
    out_vm.borrowed_interner = data.interner;
    // The macro closure lands on the user VM's heap, where the Var
    // that roots it lives; a sub-VM never collects.
    out_vm.borrowed_heap = data.registry_heap;
    out_vm.gc_enabled = false;
    return try out_vm.run();
}

/// The compiler as `macroexpand-1`, `read-string` and `eval` reach
/// it at run time (`vm.CompilerHooks`). The runtime that boots a VM
/// owns one of these for as long as the VM lives and calls `install`.
pub const RuntimeHooks = struct {
    host_macros: *const expand_mod.HostMacroTable,
    registry: *vm.NamespaceRegistry,
    interner: *intern_mod.Interner,
    load_callback: ?expand_mod.LoadCallback = null,

    pub fn install(self: *RuntimeHooks, v: *vm.VM) void {
        v.compiler_hooks = .{
            .user_data = @ptrCast(self),
            .expand_once = &expandOnceHook,
            .read_string = &readStringHook,
            .eval = &evalHook,
        };
    }

    /// An expander over the current namespace that builds its
    /// values on the VM's heap; Forms live in `arena`.
    fn context(self: *RuntimeHooks, arena: std.mem.Allocator, v: *vm.VM) expand_mod.ExpandContext {
        return .{
            .allocator = arena,
            .interner = self.interner,
            .host_macros = self.host_macros,
            .namespace = self.registry.current,
            .registry = self.registry,
            .load_callback = self.load_callback,
            .value_heap = v.ensureHeap(),
        };
    }

    fn expandOnceHook(user_data: *anyopaque, v: *vm.VM, form_value: value_mod.Value) vm.VmError!?value_mod.Value {
        const self: *RuntimeHooks = @ptrCast(@alignCast(user_data));
        var arena = std.heap.ArenaAllocator.init(v.allocator);
        defer arena.deinit();
        var ctx = self.context(arena.allocator(), v);
        const origin = reader_mod.SrcSpan{ .pos = 0, .len = 0 };
        const form = expand_mod.valueToForm(&ctx, form_value, origin) catch |err|
            return failure(v, err, "macro-expansion-failure");
        const expanded = expand_mod.expandOnce(&ctx, form) catch |err|
            return failure(v, err, "macro-expansion-failure");
        const out = expanded orelse return null;
        return expand_mod.formToValue(&ctx, out) catch |err|
            return failure(v, err, "macro-expansion-failure");
    }

    /// The first form of `source`; the rest is ignored, as in
    /// Clojure. Syntax-quote, unquote and `^meta` do not read as
    /// data and are reader errors here.
    fn readStringHook(user_data: *anyopaque, v: *vm.VM, source: []const u8) vm.VmError!value_mod.Value {
        const self: *RuntimeHooks = @ptrCast(@alignCast(user_data));
        var arena = std.heap.ArenaAllocator.init(v.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var p = reader_mod.parser.parseProgram(a, source) catch |err|
            return failure(v, err, "reader-error");
        defer p.parser.deinit();
        var reader = reader_mod.Reader.init(a, source);
        defer reader.deinit();
        const forms = reader.readProgram(p.sexp) catch |err|
            return failure(v, err, "reader-error");
        if (forms.len == 0) return v.throwKeyword("reader-error");
        var ctx = self.context(a, v);
        return expand_mod.formToValue(&ctx, forms[0]) catch |err|
            return failure(v, err, "reader-error");
    }

    /// `(eval form)`: `form_value` as a Form, compiled the way the
    /// REPL compiles a line (the current namespace, this registry,
    /// interner, host macro table and loader, a fresh set of
    /// declared names) and run on `v` as a nested call. The Form
    /// tree, the routine, its constants and every closure prototype
    /// live in the VM's runtime arena: a closure the form returns, a
    /// Var it defines and the frame an escaping throw leaves in
    /// place all outlive the call. During the run the routine is a
    /// frame, so its constants are roots. A value that is not a
    /// form and a form that does not compile both throw the map
    /// `compileFailure` builds.
    fn evalHook(user_data: *anyopaque, v: *vm.VM, form_value: value_mod.Value) vm.VmError!value_mod.Value {
        const self: *RuntimeHooks = @ptrCast(@alignCast(user_data));
        const persistent = v.runtime_arena.allocator();
        var ctx = self.context(persistent, v);
        const origin = reader_mod.SrcSpan{ .pos = 0, .len = 0 };
        const form = expand_mod.valueToForm(&ctx, form_value, origin) catch |err|
            return compileFailure(v, err, "UnsupportedForm", form_value);
        var declared = DeclaredNames.init(v.allocator);
        defer declared.deinit();
        const compiled = compileFormWith(persistent, form, .{
            .namespace = self.registry.current,
            .interner = self.interner,
            .host_macros = self.host_macros,
            .persistent_allocator = persistent,
            .registry = self.registry,
            .load_callback = self.load_callback,
            .declared = &declared,
        }) catch |err| return compileFailure(v, err, @errorName(err), form_value);
        const routine = persistent.create(vm.Routine) catch return vm.VmError.OutOfMemory;
        routine.* = compiled.toRoutine("<eval>");
        return v.runRoutine(routine);
    }

    /// Out of memory stays an error; anything else the hook could
    /// not do throws `tag`.
    fn failure(v: *vm.VM, err: anyerror, tag: []const u8) vm.VmError {
        if (err == error.OutOfMemory) return vm.VmError.OutOfMemory;
        return v.throwKeyword(tag);
    }

    /// Out of memory stays an error; anything else `eval` could not
    /// compile throws `{:error :compile-error :message name :form
    /// form}`, where `name` is the `CompileError` variant.
    fn compileFailure(v: *vm.VM, err: anyerror, name: []const u8, form: value_mod.Value) vm.VmError {
        if (err == error.OutOfMemory) return vm.VmError.OutOfMemory;
        const champ = @import("champ");
        const dispatch = @import("dispatch");
        const heap = v.ensureHeap();
        const interner = v.ensureInterner();
        const message = string_mod.fromBytes(heap, name) catch return vm.VmError.OutOfMemory;
        const tag = interner.internKeywordValue("compile-error") catch return vm.VmError.OutOfMemory;
        var m = champ.mapEmpty(heap) catch return vm.VmError.OutOfMemory;
        const entries = [_]struct { key: []const u8, value: value_mod.Value }{
            .{ .key = "error", .value = tag },
            .{ .key = "message", .value = message },
            .{ .key = "form", .value = form },
        };
        for (entries) |e| {
            const key = interner.internKeywordValue(e.key) catch return vm.VmError.OutOfMemory;
            m = champ.mapAssoc(heap, m, key, e.value, &dispatch.hashValue, &dispatch.equal) catch return vm.VmError.OutOfMemory;
        }
        return v.throwValue(m);
    }
};

/// Full form-compile with both namespace AND interner.
/// Without an Interner, quoted symbols/keywords raise
/// `UnsupportedFeature`. With one (typically `VM.ensureInterner()`),
/// `(quote foo)` / `'foo` / `(quote :bar)` / `':bar` all work
/// end-to-end and produce stable interned symbol/keyword Values.
///
/// Lifetime: the returned Compiled holds Values that reference
/// the Interner's name storage. The Interner must outlive the
/// Compiled + any VM that runs it (typically by living on the
/// VM itself).
pub fn compileFormFull(
    allocator: std.mem.Allocator,
    form: *const reader_mod.Form,
    namespace: ?*vm.Namespace,
    interner: ?*intern_mod.Interner,
) CompileError!Compiled {
    return compileFormFullWithMacros(allocator, form, namespace, interner, null);
}

/// Full form-compile with optional macroexpansion.
///
/// If `host_macros` is non-null AND `interner` is non-null,
/// the form is run through the macroexpander BEFORE lowering.
/// Macro errors are bucketed per `ExpandError`:
///   ExpansionDepthExceeded → CompileError.MacroDepthExceeded
///   everything else        → CompileError.MacroExpansionFailure
///
/// Without either, behavior is identical to `compileFormFull`
/// (no expansion). The `host_macros` table can be empty, in
/// which case the expander walks the tree but never fires a
/// macro — still slightly more expensive than null, but
/// useful for testing the scaffold.
pub fn compileFormFullWithMacros(
    allocator: std.mem.Allocator,
    form: *const reader_mod.Form,
    namespace: ?*vm.Namespace,
    interner: ?*intern_mod.Interner,
    host_macros: ?*const expand_mod.HostMacroTable,
) CompileError!Compiled {
    return compileFormFullWithMacrosSpan(allocator, form, namespace, interner, host_macros, null);
}

/// Variant of `compileFormFullWithMacros` that surfaces the
/// source span associated with any error raised. `out_span`,
/// when non-null, is written with the span of the last Form
/// walked before the error (a best-effort pointer, not a
/// per-variant span). Callers ignoring spans pass null.
pub fn compileFormFullWithMacrosSpan(
    allocator: std.mem.Allocator,
    form: *const reader_mod.Form,
    namespace: ?*vm.Namespace,
    interner: ?*intern_mod.Interner,
    host_macros: ?*const expand_mod.HostMacroTable,
    out_span: ?*?reader_mod.SrcSpan,
) CompileError!Compiled {
    return compileFormFullWithMacrosSpanPersistent(
        allocator,
        form,
        namespace,
        interner,
        host_macros,
        out_span,
        null,
    );
}

/// Variant that accepts a `persistent_allocator`
/// for defmacro Closure storage. When non-null, the synthetic
/// `(def name (fn* ...))` form produced by `defmacro` is
/// compiled into this allocator, so the resulting macro fn
/// Closure outlives the per-form compile arena.
///
/// CLI's REPL passes `vm.runtime_arena.allocator()` so
/// defmacros defined in one REPL line are usable in
/// subsequent lines. The file runner also passes a persistent
/// arena (runFile shares one arena across the file).
///
/// If null, defmacro Closures use the regular `allocator`
/// (the per-form arena). That's fine when ALL macro uses
/// fall within the same arena lifetime (e.g., one-shot
/// source compilation).
///
/// `registry` (optional) enables `(ns NAME)` expansion to
/// switch the current namespace. If null, `(ns ...)` is a hard
/// error.
pub fn compileFormFullWithMacrosSpanPersistent(
    allocator: std.mem.Allocator,
    form: *const reader_mod.Form,
    namespace: ?*vm.Namespace,
    interner: ?*intern_mod.Interner,
    host_macros: ?*const expand_mod.HostMacroTable,
    out_span: ?*?reader_mod.SrcSpan,
    persistent_allocator: ?std.mem.Allocator,
) CompileError!Compiled {
    return compileFormFullWithMacrosSpanPersistentRegistry(
        allocator,
        form,
        namespace,
        interner,
        host_macros,
        out_span,
        persistent_allocator,
        null,
    );
}

/// Same as `compileFormFullWithMacrosSpanPersistent`
/// but also accepts a `*NamespaceRegistry` for `(ns NAME)`
/// expansion support.
pub fn compileFormFullWithMacrosSpanPersistentRegistry(
    allocator: std.mem.Allocator,
    form: *const reader_mod.Form,
    namespace: ?*vm.Namespace,
    interner: ?*intern_mod.Interner,
    host_macros: ?*const expand_mod.HostMacroTable,
    out_span: ?*?reader_mod.SrcSpan,
    persistent_allocator: ?std.mem.Allocator,
    registry: ?*vm.NamespaceRegistry,
) CompileError!Compiled {
    return compileFormFullWithMacrosSpanPersistentRegistryLoader(
        allocator,
        form,
        namespace,
        interner,
        host_macros,
        out_span,
        persistent_allocator,
        registry,
        null,
        null,
    );
}

/// Everything a full compile may be given beyond the form and its
/// allocator. Every field is optional; the short-name entry points
/// (`compileForm`, `compileFormFull`, ...) are spellings of
/// particular subsets.
pub const CompileOptions = struct {
    /// Namespace for `def`, `(var x)` and symbol fall-through.
    /// Without one, symbols must resolve lexically.
    namespace: ?*vm.Namespace = null,
    /// Interner for quoted symbols and keywords, and the
    /// precondition for macroexpansion. Without one, `'foo`
    /// raises `UnsupportedFeature` and no macro fires.
    interner: ?*intern_mod.Interner = null,
    /// Host macro table consulted before lowering; an absent
    /// table still expands user `defmacro`s when an interner is
    /// present.
    host_macros: ?*const expand_mod.HostMacroTable = null,
    /// Receives the source span of an error: the symbol's own
    /// span when lowering can locate it, otherwise the
    /// macroexpanded form's.
    out_span: ?*?reader_mod.SrcSpan = null,
    /// Where `defmacro` closures are stored, so they outlive a
    /// per-form compile arena. The REPL and file runner pass
    /// `vm.runtime_arena.allocator()`; null uses `allocator`.
    persistent_allocator: ?std.mem.Allocator = null,
    /// Registry that `(ns NAME)` switches; without it `(ns ...)`
    /// is an error.
    registry: ?*vm.NamespaceRegistry = null,
    /// Loader that `(require ...)` dispatches to.
    load_callback: ?expand_mod.LoadCallback = null,
    /// The names the enclosing file or REPL line defines; with it,
    /// a symbol that resolves to nothing is `UnresolvedSymbol` at
    /// its span.
    declared: ?*DeclaredNames = null,
    /// The text `form` was read from and the path it is reported
    /// under; every routine compiled here points at it. Must
    /// outlive the routines. Without it a runtime error still
    /// carries spans but nothing to resolve them against.
    source: ?*const vm.SourceInfo = null,
};

/// Full form-compile entry: macroexpand, lower and emit `form`
/// under `opts`.
pub fn compileFormWith(
    allocator: std.mem.Allocator,
    form: *const reader_mod.Form,
    opts: CompileOptions,
) CompileError!Compiled {
    const namespace = opts.namespace;
    const interner = opts.interner;
    const out_span = opts.out_span;
    const declared = opts.declared;
    var working_form: *const reader_mod.Form = form;
    if (interner != null) {
        const empty_table: expand_mod.HostMacroTable = .{};
        const table_to_use: *const expand_mod.HostMacroTable =
            opts.host_macros orelse &empty_table;
        // The compile-eval callback lets the defmacro handler in
        // expand.zig compile and run the synthetic
        // `(def name (fn* ...))` form in a sub-VM; the macro fn
        // is stored in the persistent allocator so it outlives
        // the per-form arena.
        const registry_heap: ?*heap_mod.Heap = if (namespace) |n| (if (n.registry) |r| r.heap else null) else null;
        var ceval_data = CompileEvalData{
            .persistent_allocator = opts.persistent_allocator orelse allocator,
            .namespace = namespace,
            .interner = interner.?,
            .registry_heap = registry_heap,
        };
        var mctx = expand_mod.ExpandContext{
            .allocator = allocator,
            .interner = interner.?,
            .host_macros = table_to_use,
            .namespace = namespace,
            .compile_eval = .{
                .user_data = @ptrCast(&ceval_data),
                .eval = compileEvalCallback,
            },
            .registry = opts.registry,
            .load_callback = opts.load_callback,
            .value_heap = registry_heap,
        };
        working_form = expand_mod.expandForm(&mctx, null, form) catch |err| switch (err) {
            error.ExpansionDepthExceeded => {
                if (out_span) |s| s.* = form.origin;
                return CompileError.MacroDepthExceeded;
            },
            error.MalformedMacroCall => {
                if (out_span) |s| s.* = form.origin;
                return CompileError.MacroExpansionFailure;
            },
            error.MacroReturnedNull => {
                if (out_span) |s| s.* = form.origin;
                return CompileError.MacroExpansionFailure;
            },
            error.OutOfMemory => return CompileError.OutOfMemory,
        };
    }
    // `.string` Form datums lower to `Tiny.literal` on the
    // registry's heap. Without a namespace or a registry there is
    // no heap and a string literal is `UnsupportedFeature`.
    const lower_heap: ?*heap_mod.Heap = if (namespace) |n|
        (if (n.registry) |r| r.heap else null)
    else
        null;
    // Whatever this form defines (including definitions a macro
    // expanded into it) may be referred to anywhere inside it.
    if (declared) |d| d.declareForm(working_form) catch return CompileError.OutOfMemory;
    var diag = LowerDiag{};
    const ctx = LowerCtx{
        .env = null,
        .interner = interner,
        .heap = lower_heap,
        .namespace = namespace,
        .declared = declared,
        .diag = &diag,
    };
    const tiny = lowerFormEnv(allocator, working_form, ctx) catch |err| {
        // An error that located itself reports that span; the
        // rest carry the macroexpanded form's span.
        if (out_span) |s| s.* = diag.span orelse working_form.origin;
        return err;
    };
    return compileTinyWithSpans(allocator, tiny, namespace, true, working_form.origin, opts.source) catch |err| {
        if (out_span) |s| s.* = working_form.origin;
        return err;
    };
}

/// `compileFormWith` with every option positional.
pub fn compileFormFullWithMacrosSpanPersistentRegistryLoader(
    allocator: std.mem.Allocator,
    form: *const reader_mod.Form,
    namespace: ?*vm.Namespace,
    interner: ?*intern_mod.Interner,
    host_macros: ?*const expand_mod.HostMacroTable,
    out_span: ?*?reader_mod.SrcSpan,
    persistent_allocator: ?std.mem.Allocator,
    registry: ?*vm.NamespaceRegistry,
    load_callback: ?expand_mod.LoadCallback,
    declared: ?*DeclaredNames,
) CompileError!Compiled {
    return compileFormWith(allocator, form, .{
        .namespace = namespace,
        .interner = interner,
        .host_macros = host_macros,
        .out_span = out_span,
        .persistent_allocator = persistent_allocator,
        .registry = registry,
        .load_callback = load_callback,
        .declared = declared,
    });
}

/// End-to-end: parse + read + lower + compile a source string.
/// Convenience wrapper around `parser.parseForm` + `Reader.readOneForm`
/// + `compileFormWithNamespace`. No namespace; symbols must
/// resolve lexically.
pub fn compileSource(
    allocator: std.mem.Allocator,
    source: []const u8,
) CompileError!Compiled {
    return compileSourceWithNamespace(allocator, source, null);
}

/// End-to-end with namespace access for `def` / `(var x)` /
/// symbol fall-through.
///
/// Lifetime: the returned `Compiled` references strings borrowed
/// from `source` (via Tiny.symbol → routine.var_table[*].name).
/// The caller MUST keep `source` alive for the lifetime of the
/// `Compiled` artifact and any VM that runs it. Tests typically
/// achieve this by storing source as a string literal (program
/// lifetime) or by holding it in the same arena as the
/// `Compiled`.
///
/// Reader/parser errors are bucketed as `CompileError.ReaderFailure`;
/// the `*Span` entry points surface a SrcSpan alongside the error.
pub fn compileSourceWithNamespace(
    allocator: std.mem.Allocator,
    source: []const u8,
    namespace: ?*vm.Namespace,
) CompileError!Compiled {
    return compileSourceFull(allocator, source, namespace, null);
}

/// End-to-end source compile with namespace AND interner.
/// Pass `VM.ensureInterner()` to enable quoted-symbol / quoted-
/// keyword support via real source syntax.
pub fn compileSourceFull(
    allocator: std.mem.Allocator,
    source: []const u8,
    namespace: ?*vm.Namespace,
    interner: ?*intern_mod.Interner,
) CompileError!Compiled {
    return compileSourceFullWithMacros(allocator, source, namespace, interner, null);
}

/// End-to-end source compile with optional macroexpansion.
/// See `compileFormFullWithMacros` for macro semantics.
pub fn compileSourceFullWithMacros(
    allocator: std.mem.Allocator,
    source: []const u8,
    namespace: ?*vm.Namespace,
    interner: ?*intern_mod.Interner,
    host_macros: ?*const expand_mod.HostMacroTable,
) CompileError!Compiled {
    return compileSourceFullWithMacrosSpan(
        allocator,
        source,
        namespace,
        interner,
        host_macros,
        null,
    );
}

/// End-to-end source compile with span surfacing.
/// Mirrors `compileFormFullWithMacrosSpan`. Reader errors set
/// span to `null` (the reader's own error machinery owns that
/// surface — see `reader.readOneForm`'s ErrorKind for spans
/// from the reader layer).
pub fn compileSourceFullWithMacrosSpan(
    allocator: std.mem.Allocator,
    source: []const u8,
    namespace: ?*vm.Namespace,
    interner: ?*intern_mod.Interner,
    host_macros: ?*const expand_mod.HostMacroTable,
    out_span: ?*?reader_mod.SrcSpan,
) CompileError!Compiled {
    return compileSourceFullWithMacrosSpanPersistent(
        allocator,
        source,
        namespace,
        interner,
        host_macros,
        out_span,
        null,
    );
}

/// Source-string entry with `persistent_allocator`.
/// Callers that want defmacros to survive beyond the per-form
/// arena (REPL, file runner) pass `vm.runtime_arena.allocator()`.
pub fn compileSourceFullWithMacrosSpanPersistent(
    allocator: std.mem.Allocator,
    source: []const u8,
    namespace: ?*vm.Namespace,
    interner: ?*intern_mod.Interner,
    host_macros: ?*const expand_mod.HostMacroTable,
    out_span: ?*?reader_mod.SrcSpan,
    persistent_allocator: ?std.mem.Allocator,
) CompileError!Compiled {
    return compileSourceFullWithMacrosSpanPersistentRegistry(
        allocator,
        source,
        namespace,
        interner,
        host_macros,
        out_span,
        persistent_allocator,
        null,
    );
}

/// Parse and read one form from `source`, then `compileFormWith`.
pub fn compileSourceWith(
    allocator: std.mem.Allocator,
    source: []const u8,
    opts: CompileOptions,
) CompileError!Compiled {
    var p = reader_mod.parser.parseForm(allocator, source) catch {
        return CompileError.ReaderFailure;
    };
    defer p.parser.deinit();
    var reader = reader_mod.Reader.init(allocator, source);
    defer reader.deinit();
    const form = reader.readOneForm(p.sexp) catch
        return CompileError.ReaderFailure;
    return compileFormWith(allocator, form, opts);
}

/// `compileSourceWith` with every option positional.
pub fn compileSourceFullWithMacrosSpanPersistentRegistryLoader(
    allocator: std.mem.Allocator,
    source: []const u8,
    namespace: ?*vm.Namespace,
    interner: ?*intern_mod.Interner,
    host_macros: ?*const expand_mod.HostMacroTable,
    out_span: ?*?reader_mod.SrcSpan,
    persistent_allocator: ?std.mem.Allocator,
    registry: ?*vm.NamespaceRegistry,
    load_callback: ?expand_mod.LoadCallback,
    declared: ?*DeclaredNames,
) CompileError!Compiled {
    return compileSourceWith(allocator, source, .{
        .namespace = namespace,
        .interner = interner,
        .host_macros = host_macros,
        .out_span = out_span,
        .persistent_allocator = persistent_allocator,
        .registry = registry,
        .load_callback = load_callback,
        .declared = declared,
    });
}

/// Source-string entry with both persistent
/// allocator AND namespace registry. CLI's REPL + runFile call
/// this so `(ns NAME)` switches affect subsequent forms in the
/// session/file.
pub fn compileSourceFullWithMacrosSpanPersistentRegistry(
    allocator: std.mem.Allocator,
    source: []const u8,
    namespace: ?*vm.Namespace,
    interner: ?*intern_mod.Interner,
    host_macros: ?*const expand_mod.HostMacroTable,
    out_span: ?*?reader_mod.SrcSpan,
    persistent_allocator: ?std.mem.Allocator,
    registry: ?*vm.NamespaceRegistry,
) CompileError!Compiled {
    return compileSourceWith(allocator, source, .{
        .namespace = namespace,
        .interner = interner,
        .host_macros = host_macros,
        .out_span = out_span,
        .persistent_allocator = persistent_allocator,
        .registry = registry,
    });
}

// =============================================================================
// Internal lowering — destination-driven
// =============================================================================

// =============================================================================
// Capture pre-analysis
//
// The analyzer answers: "given a `Tiny` subtree, which names are
// referenced by some `fn*` body inside the subtree?" The compiler
// uses this at `let*` binding time and `fn*` parameter time to
// decide whether to emit `closure:box-local` UNCONDITIONALLY in
// straight-line prelude code (so the boxing dominates every
// reachable use, including reads inside or after branches).
//
// **Why not lazy-box**: lazy boxing would emit
// `closure:box-local` at the moment capture is discovered
// during inner-fn compilation. If the inner fn is inside a
// branch (e.g., `(if false (fn* [] x) 0)`), the box-local lived
// in the unreachable branch while the compiler's BindingRef
// scope-state thinks x is boxed. Subsequent same-frame reads
// emit `closure:get-cell` against an unboxed slot at runtime
// → `:expected-cell` trap on a perfectly valid program.
//
// Pre-analysis avoids this by computing the capture set BEFORE
// codegen and emitting box-local in straight-line prelude code
// that every reachable path traverses.
//
// **Soundness**: a binding is `.cell_slot` iff its
// `closure:box-local` is in straight-line let-binding prelude
// (or fn-entry prelude) that dominates every reachable use. The
// analyzer over-reports captures in the presence of shadowing
// (e.g., `(let [x 1] (let [x 2] (fn [] x)))` boxes both x's even
// though only the inner is captured by the inner fn) — this is
// a small wasted instruction, never a correctness issue.
// =============================================================================

/// Linear-lookup string set. Sufficient for the small name sets
/// a Tiny tree produces.
const NameSet = struct {
    items: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *NameSet, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
    }

    fn contains(self: *const NameSet, name: []const u8) bool {
        for (self.items.items) |n| if (std.mem.eql(u8, n, name)) return true;
        return false;
    }

    fn put(self: *NameSet, allocator: std.mem.Allocator, name: []const u8) CompileError!void {
        if (self.contains(name)) return;
        try self.items.append(allocator, name);
    }

    /// Append every name from `other` not already in self.
    fn unionWith(self: *NameSet, allocator: std.mem.Allocator, other: *const NameSet) CompileError!void {
        for (other.items.items) |n| try self.put(allocator, n);
    }
};

/// Standard free-variable analysis. Returns names referenced in
/// `form` that are not bound by `env` (or by any binding inside
/// `form` as we descend). Used internally by
/// `capturedByDescendantFns` for `fn_star` boundaries.
fn freeVars(allocator: std.mem.Allocator, form: *const Tiny, env: *const NameSet, out: *NameSet) CompileError!void {
    switch (form.*) {
        .nil, .bool, .int => {},
        .symbol => |name| if (!env.contains(name)) try out.put(allocator, name),
        // Qualified symbols resolve through the
        // namespace registry — never lexically captured.
        .qualified_symbol => {},
        .add => |a| {
            try freeVars(allocator, a.lhs, env, out);
            try freeVars(allocator, a.rhs, env, out);
        },
        .lt => |a| {
            try freeVars(allocator, a.lhs, env, out);
            try freeVars(allocator, a.rhs, env, out);
        },
        .if_ => |i| {
            try freeVars(allocator, i.test_, env, out);
            try freeVars(allocator, i.then, env, out);
            if (i.else_) |e| try freeVars(allocator, e, env, out);
        },
        .let_star => |l| {
            // Build incrementally-extended env to honor sequential
            // bindings (binding-i's RHS sees bindings 1..i-1).
            var local_env: NameSet = .{};
            defer local_env.deinit(allocator);
            try local_env.unionWith(allocator, env);
            for (l.bindings) |b| {
                try freeVars(allocator, b.value, &local_env, out);
                try local_env.put(allocator, b.name);
            }
            try freeVars(allocator, l.body, &local_env, out);
        },
        .do_ => |exprs| {
            for (exprs) |expr| try freeVars(allocator, expr, env, out);
        },
        .fn_star => |f| {
            // fn body's env = outer env + params + rest_param +
            // self-name (if any). Names referenced in fn body
            // not bound by any of those are "free" and bubble
            // up here.
            var fn_env: NameSet = .{};
            defer fn_env.deinit(allocator);
            try fn_env.unionWith(allocator, env);
            for (f.params) |p| try fn_env.put(allocator, p);
            if (f.rest_param) |rp| try fn_env.put(allocator, rp);
            if (f.name) |n| try fn_env.put(allocator, n);
            try freeVars(allocator, f.body, &fn_env, out);
        },
        .call => |c| {
            try freeVars(allocator, c.callee, env, out);
            for (c.args) |a| try freeVars(allocator, a, env, out);
        },
        .letfn_star => |l| {
            // All letfn binding names are mutually visible
            // (each fn body sees all letfn names as bindings).
            // Body sees the same bindings.
            var local_env: NameSet = .{};
            defer local_env.deinit(allocator);
            try local_env.unionWith(allocator, env);
            for (l.bindings) |b| try local_env.put(allocator, b.name);
            for (l.bindings) |b| {
                // Each fn's body env = local_env + params.
                var fn_env: NameSet = .{};
                defer fn_env.deinit(allocator);
                try fn_env.unionWith(allocator, &local_env);
                for (b.params) |p| try fn_env.put(allocator, p);
                if (b.rest_param) |rp| try fn_env.put(allocator, rp);
                try freeVars(allocator, b.body, &fn_env, out);
            }
            try freeVars(allocator, l.body, &local_env, out);
        },
        .loop_star => |l| {
            // Same as let*: sequential binding visibility (RHS
            // i sees bindings 1..i-1; body sees all).
            var local_env: NameSet = .{};
            defer local_env.deinit(allocator);
            try local_env.unionWith(allocator, env);
            for (l.bindings) |b| {
                try freeVars(allocator, b.value, &local_env, out);
                try local_env.put(allocator, b.name);
            }
            try freeVars(allocator, l.body, &local_env, out);
        },
        .recur => |r| {
            // Recur args may contain nested fn_stars referencing
            // outer bindings. Recurse into each arg with the
            // current env.
            for (r.args) |a| try freeVars(allocator, a, env, out);
        },
        .literal => {}, // leaf — Value constants have no free vars
        .list_construct => |items| for (items) |it| try freeVars(allocator, it, env, out),
        .concat => |items| for (items) |it| try freeVars(allocator, it, env, out),
        .vector_construct => |items| for (items) |it| try freeVars(allocator, it, env, out),
        .map_construct => |items| for (items) |it| try freeVars(allocator, it, env, out),
        .set_construct => |items| for (items) |it| try freeVars(allocator, it, env, out),
        .try_ => |t| {
            try freeVars(allocator, t.body, env, out);
            var handler_env: NameSet = .{};
            defer handler_env.deinit(allocator);
            try handler_env.unionWith(allocator, env);
            try handler_env.put(allocator, t.binding);
            try freeVars(allocator, t.handler, &handler_env, out);
            if (t.finally_) |fin| try freeVars(allocator, fin, env, out);
        },
        .throw_ => |value| try freeVars(allocator, value, env, out),
        .def => |d| {
            // def's RHS is the only sub-expression that can carry
            // free vars; the name itself is a NAMESPACE-LEVEL
            // binding, not a local, so it doesn't affect this
            // routine's lexical env.
            if (d.value) |val| try freeVars(allocator, val, env, out);
        },
        .var_ref => {}, // leaf: no sub-expressions, no free vars
        .defn => |d| {
            // defn lowers to (def name (fn* name ...)).
            // For free-var analysis, treat the body's env as
            // outer env + params + rest_param + name (the
            // self-name is bound inside the fn body).
            var fn_env: NameSet = .{};
            defer fn_env.deinit(allocator);
            try fn_env.unionWith(allocator, env);
            for (d.params) |p| try fn_env.put(allocator, p);
            if (d.rest_param) |rp| try fn_env.put(allocator, rp);
            try fn_env.put(allocator, d.name);
            try freeVars(allocator, d.body, &fn_env, out);
        },
    }
}

/// Returns the set of names from `env` (names visible at
/// "this" outer level) that are captured by SOME `fn_star`
/// within `form`. A name is "captured" if it's referenced
/// inside a fn body and not bound by that fn's params, any
/// inner binding, OR any binding between us and the fn that
/// shadows the name.
///
/// **Shadowing-aware**: the `env` parameter tracks names
/// visible at our level. As the walk descends into
/// binding-forms (`let_star`, `fn_star` params), shadowed names
/// are removed from the live env so they don't pollute the
/// captured set; an inner shadow never causes the outer binding
/// to be boxed.
///
/// `freeVars` against the descendant fn's own env (params +
/// inner bindings) gives the names the fn captures. We
/// intersect with `env` to keep only those bound at our level
/// (or higher, but for our boxing decision we care about
/// matches with our specific bindings).
fn capturedByDescendantFns(
    allocator: std.mem.Allocator,
    form: *const Tiny,
    env: *const NameSet,
    out: *NameSet,
) CompileError!void {
    switch (form.*) {
        .nil, .bool, .int, .symbol, .qualified_symbol => {},
        .add => |a| {
            try capturedByDescendantFns(allocator, a.lhs, env, out);
            try capturedByDescendantFns(allocator, a.rhs, env, out);
        },
        .lt => |a| {
            try capturedByDescendantFns(allocator, a.lhs, env, out);
            try capturedByDescendantFns(allocator, a.rhs, env, out);
        },
        .if_ => |i| {
            try capturedByDescendantFns(allocator, i.test_, env, out);
            try capturedByDescendantFns(allocator, i.then, env, out);
            if (i.else_) |e| try capturedByDescendantFns(allocator, e, env, out);
        },
        .let_star => |l| {
            // As bindings shadow, names with the same name as
            // a binding fall out of `env`. Build an env-without-
            // shadowed-names for each position.
            // RHS-i sees env shadowed by bindings 1..i-1; body
            // sees env shadowed by all bindings.
            var local_env: NameSet = .{};
            defer local_env.deinit(allocator);
            try local_env.unionWith(allocator, env);
            for (l.bindings) |b| {
                try capturedByDescendantFns(allocator, b.value, &local_env, out);
                // Remove shadowed name from local_env so subsequent
                // RHSs / body don't see captures matching it.
                removeFromSet(&local_env, b.name);
            }
            try capturedByDescendantFns(allocator, l.body, &local_env, out);
        },
        .do_ => |exprs| {
            for (exprs) |expr| try capturedByDescendantFns(allocator, expr, env, out);
        },
        .fn_star => |f| {
            // This fn body has its own params + rest_param +
            // optional self-name as initial env. The fn's free
            // vars are the names it actually captures from OUR
            // scope. We want only those that match `env`.
            //
            // freeVars already recurses through nested fn_stars
            // (with appropriate inner envs), so descendant fns'
            // captures bubble up here correctly. No additional
            // capturedByDescendantFns recursion is needed.
            var params_env: NameSet = .{};
            defer params_env.deinit(allocator);
            for (f.params) |p| try params_env.put(allocator, p);
            if (f.rest_param) |rp| try params_env.put(allocator, rp);
            if (f.name) |n| try params_env.put(allocator, n);
            var fn_free: NameSet = .{};
            defer fn_free.deinit(allocator);
            try freeVars(allocator, f.body, &params_env, &fn_free);
            // Filter: only names visible at our level matter
            // for our boxing decision.
            for (fn_free.items.items) |name| {
                if (env.contains(name)) try out.put(allocator, name);
            }
        },
        .call => |c| {
            try capturedByDescendantFns(allocator, c.callee, env, out);
            for (c.args) |a| try capturedByDescendantFns(allocator, a, env, out);
        },
        .letfn_star => |l| {
            // letfn* bindings shadow `env` for all fn bodies and
            // for the let body. Build a local_env with bindings
            // removed from `env`, then walk each fn body and
            // the body.
            var local_env: NameSet = .{};
            defer local_env.deinit(allocator);
            try local_env.unionWith(allocator, env);
            for (l.bindings) |b| removeFromSet(&local_env, b.name);
            for (l.bindings) |b| {
                // Each fn's body's free vars (against
                // params + letfn binding names + self-name)
                // captured at our level = (free vars) ∩ env.
                var fn_env: NameSet = .{};
                defer fn_env.deinit(allocator);
                for (b.params) |p| try fn_env.put(allocator, p);
                if (b.rest_param) |rp| try fn_env.put(allocator, rp);
                for (l.bindings) |b2| try fn_env.put(allocator, b2.name);
                var fn_free: NameSet = .{};
                defer fn_free.deinit(allocator);
                try freeVars(allocator, b.body, &fn_env, &fn_free);
                for (fn_free.items.items) |name| {
                    if (env.contains(name)) try out.put(allocator, name);
                }
            }
            try capturedByDescendantFns(allocator, l.body, &local_env, out);
        },
        .loop_star => |l| {
            // Same as let*: sequential RHS visibility. Each
            // binding shadows `env` for subsequent positions.
            // Recurse with progressively shadowed env.
            var local_env: NameSet = .{};
            defer local_env.deinit(allocator);
            try local_env.unionWith(allocator, env);
            for (l.bindings) |b| {
                try capturedByDescendantFns(allocator, b.value, &local_env, out);
                // Shadow: remove from env so later positions
                // don't see the outer same-named binding.
                removeFromSet(&local_env, b.name);
            }
            try capturedByDescendantFns(allocator, l.body, &local_env, out);
        },
        .recur => |r| {
            // Recur args may contain nested fn_stars. Recurse
            // into each.
            for (r.args) |a| try capturedByDescendantFns(allocator, a, env, out);
        },
        .literal => {}, // leaf — Value constants have no descendant fns
        .list_construct => |items| for (items) |it| try capturedByDescendantFns(allocator, it, env, out),
        .concat => |items| for (items) |it| try capturedByDescendantFns(allocator, it, env, out),
        .vector_construct => |items| for (items) |it| try capturedByDescendantFns(allocator, it, env, out),
        .map_construct => |items| for (items) |it| try capturedByDescendantFns(allocator, it, env, out),
        .set_construct => |items| for (items) |it| try capturedByDescendantFns(allocator, it, env, out),
        .try_ => |t| {
            try capturedByDescendantFns(allocator, t.body, env, out);
            var handler_env: NameSet = .{};
            defer handler_env.deinit(allocator);
            try handler_env.unionWith(allocator, env);
            try handler_env.put(allocator, t.binding);
            try capturedByDescendantFns(allocator, t.handler, &handler_env, out);
            if (t.finally_) |fin| try capturedByDescendantFns(allocator, fin, env, out);
        },
        .throw_ => |value| try capturedByDescendantFns(allocator, value, env, out),
        .def => |d| {
            // RHS may contain inner fns; analyze.
            if (d.value) |val| try capturedByDescendantFns(allocator, val, env, out);
        },
        .var_ref => {}, // leaf
        .defn => |d| {
            // Mirror the fn_star arm: body env = params +
            // rest_param + self-name; report names in `env`
            // that the body actually references.
            var params_env: NameSet = .{};
            defer params_env.deinit(allocator);
            for (d.params) |p| try params_env.put(allocator, p);
            if (d.rest_param) |rp| try params_env.put(allocator, rp);
            try params_env.put(allocator, d.name);
            var fn_free: NameSet = .{};
            defer fn_free.deinit(allocator);
            try freeVars(allocator, d.body, &params_env, &fn_free);
            for (fn_free.items.items) |fname| {
                if (env.contains(fname)) try out.put(allocator, fname);
            }
        },
    }
}

/// Remove a name from a NameSet (mutates in place). Used by
/// `capturedByDescendantFns` to model shadowing during the
/// env-aware walk.
fn removeFromSet(set: *NameSet, name: []const u8) void {
    for (set.items.items, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) {
            _ = set.items.orderedRemove(i);
            return;
        }
    }
}

/// Lower `form` into bytecode that, when executed, leaves the
/// form's result in `slot[dst]`. `recur_target` carries the
/// nearest enclosing `loop*` / `fn*` body target, or `null` if
/// `form` is in a non-tail position relative to any such target
/// Propagation is form-specific; see the per-arm handlers.
fn compileExpr(
    e: *Emitter,
    form: *const Tiny,
    dst: u12,
    recur_target: ?*const RecurTarget,
) CompileError!void {
    // Instructions this node emits carry its own span; whatever the
    // parent emits after this call carries the parent's again.
    const saved_span = e.current_span;
    defer e.current_span = saved_span;
    if (e.spanned) {
        const node: *const TinyNode = @fieldParentPtr("tiny", form);
        if (node.span) |span| e.current_span = span;
    }
    switch (form.*) {
        .nil => try e.emit(vm.asm_.loadNil(dst)),
        .bool => |b| try e.emit(if (b) vm.asm_.loadTrue(dst) else vm.asm_.loadFalse(dst)),
        .int => |n| try compileIntLiteral(e, n, dst),
        .literal => |v| try compileLiteral(e, v, dst),
        .symbol => |name| try compileSymbol(e, name, dst),
        .qualified_symbol => |qs| try compileQualifiedSymbol(e, qs.ns, qs.name, dst),
        .list_construct => |items| try compileListConstruct(e, items, dst),
        .concat => |items| try compileConcat(e, items, dst),
        .vector_construct => |items| try compileVectorConstruct(e, items, dst),
        .map_construct => |items| try compileMapConstruct(e, items, dst),
        .set_construct => |items| try compileSetConstruct(e, items, dst),
        .try_ => |t| try compileTry(e, t.body, t.binding, t.handler, t.finally_, dst),
        .throw_ => |value| try compileThrow(e, value, dst),
        .add => |a| try compileAdd(e, a.lhs, a.rhs, dst),
        .lt => |a| try compileLt(e, a.lhs, a.rhs, dst),
        .if_ => |i| try compileIf(e, i.test_, i.then, i.else_, dst, recur_target),
        .let_star => |l| try compileLetStar(e, l.bindings, l.body, dst, recur_target),
        .do_ => |exprs| try compileDo(e, exprs, dst, recur_target),
        .fn_star => |f| try compileFn(e, f.name, f.params, f.rest_param, f.body, dst),
        .call => |c| try compileCall(e, c.callee, c.args, dst),
        .letfn_star => |l| try compileLetFnStar(e, l.bindings, l.body, dst, recur_target),
        .loop_star => |l| try compileLoopStar(e, l.bindings, l.body, dst),
        .recur => |r| try compileRecur(e, r.args, recur_target),
        .def => |d| try compileDef(e, d.name, d.value, dst),
        .var_ref => |v| try compileVarRef(e, v.name, dst),
        .defn => |d| try compileDefn(e, d.name, d.params, d.rest_param, d.body, dst),
    }
}

fn compileIntLiteral(e: *Emitter, n: i64, dst: u12) CompileError!void {
    const v = value_mod.fromFixnum(n) orelse
        return CompileError.IntegerOutOfFixnumRange;
    const c = try e.addValueConst(v);
    try e.emit(vm.asm_.loadConst(dst, c));
}

/// Emit a generic Value constant. The Value must have
/// stable identity (interned symbols/keywords, immediates,
/// strings owned by the Interner). See `Tiny.literal` doc for
/// the lifetime contract.
fn compileLiteral(e: *Emitter, v: value_mod.Value, dst: u12) CompileError!void {
    const c = try e.addValueConst(v);
    try e.emit(vm.asm_.loadConst(dst, c));
}

/// Compile `#%list` — allocate a contiguous slot
/// block for argc items, compile each arg into its slot, then
/// emit `coll:list arg_base argc dst`. Empty list is a degenerate
/// case: emit with argc=0 (the VM handles it specially via
/// `list_mod.empty`).
///
/// Block-allocation strategy mirrors `compileCall`:
/// reserve the entire block upfront so internal
/// temporaries from sub-expression compilation don't fragment
/// the arg slots.
fn compileListConstruct(e: *Emitter, items: []const *const Tiny, dst: u12) CompileError!void {
    if (items.len == 0) {
        try e.emit(vm.asm_.collList(dst, 0, dst));
        return;
    }
    const argc: u12 = if (items.len <= std.math.maxInt(u12))
        @intCast(items.len)
    else
        return CompileError.SlotOverflow;
    const arg_base = try e.allocSlotBlock(argc);
    for (items, 0..) |item, i| {
        const slot: u12 = @intCast(@as(u32, arg_base) + @as(u32, @intCast(i)));
        // Non-tail position: top-level expressions in a list
        // construction never tail-call.
        try compileExpr(e, item, slot, null);
    }
    try e.emit(vm.asm_.collList(arg_base, argc, dst));
}

/// Compile `#%concat`. Same block-allocation
/// strategy as `compileListConstruct`; backend emits a
/// single `coll:concat` opcode that does the runtime
/// traverse-collect-rebuild.
fn compileConcat(e: *Emitter, items: []const *const Tiny, dst: u12) CompileError!void {
    if (items.len == 0) {
        try e.emit(vm.asm_.collConcat(dst, 0, dst));
        return;
    }
    const argc: u12 = if (items.len <= std.math.maxInt(u12))
        @intCast(items.len)
    else
        return CompileError.SlotOverflow;
    const arg_base = try e.allocSlotBlock(argc);
    for (items, 0..) |item, i| {
        const slot: u12 = @intCast(@as(u32, arg_base) + @as(u32, @intCast(i)));
        try compileExpr(e, item, slot, null);
    }
    try e.emit(vm.asm_.collConcat(arg_base, argc, dst));
}

/// Compile `#%vector`. Same pattern as `#%list`;
/// backend emits `coll:vector` which routes through
/// `vector_mod.fromSlice` (RRB persistent vector).
fn compileVectorConstruct(e: *Emitter, items: []const *const Tiny, dst: u12) CompileError!void {
    if (items.len == 0) {
        try e.emit(vm.asm_.collVector(dst, 0, dst));
        return;
    }
    const argc: u12 = if (items.len <= std.math.maxInt(u12))
        @intCast(items.len)
    else
        return CompileError.SlotOverflow;
    const arg_base = try e.allocSlotBlock(argc);
    for (items, 0..) |item, i| {
        const slot: u12 = @intCast(@as(u32, arg_base) + @as(u32, @intCast(i)));
        try compileExpr(e, item, slot, null);
    }
    try e.emit(vm.asm_.collVector(arg_base, argc, dst));
}

/// Compile `#%map`. Items are flat k,v,k,v,... so
/// length MUST be even (compiler enforces; runtime would
/// reject as BytecodeCorruption otherwise). Backend emits
/// `coll:map` which iterates pairs through `champ.mapAssoc`.
fn compileMapConstruct(e: *Emitter, items: []const *const Tiny, dst: u12) CompileError!void {
    if (items.len % 2 != 0) return CompileError.MalformedForm;
    if (items.len == 0) {
        try e.emit(vm.asm_.collMap(dst, 0, dst));
        return;
    }
    const argc: u12 = if (items.len <= std.math.maxInt(u12))
        @intCast(items.len)
    else
        return CompileError.SlotOverflow;
    const arg_base = try e.allocSlotBlock(argc);
    for (items, 0..) |item, i| {
        const slot: u12 = @intCast(@as(u32, arg_base) + @as(u32, @intCast(i)));
        try compileExpr(e, item, slot, null);
    }
    try e.emit(vm.asm_.collMap(arg_base, argc, dst));
}

/// Compile `#%set`. Same shape as `#%list`; backend
/// emits `coll:set` which de-duplicates via `champ.setConj`.
fn compileSetConstruct(e: *Emitter, items: []const *const Tiny, dst: u12) CompileError!void {
    if (items.len == 0) {
        try e.emit(vm.asm_.collSet(dst, 0, dst));
        return;
    }
    const argc: u12 = if (items.len <= std.math.maxInt(u12))
        @intCast(items.len)
    else
        return CompileError.SlotOverflow;
    const arg_base = try e.allocSlotBlock(argc);
    for (items, 0..) |item, i| {
        const slot: u12 = @intCast(@as(u32, arg_base) + @as(u32, @intCast(i)));
        try compileExpr(e, item, slot, null);
    }
    try e.emit(vm.asm_.collSet(arg_base, argc, dst));
}

fn compileAdd(e: *Emitter, lhs: *const Tiny, rhs: *const Tiny, dst: u12) CompileError!void {
    // Literal-pair peephole: if both
    // operands are integer literals, emit math:add with constant
    // operands directly — no prelude moves, two instructions
    // total (math:add + the eventual return). For non-literal
    // operands, fall back to prelude-style: compile each into a
    // fresh temp slot, then math:add slot/slot/slot.
    if (lhs.* == .int and rhs.* == .int) {
        const v_lhs = value_mod.fromFixnum(lhs.int) orelse
            return CompileError.IntegerOutOfFixnumRange;
        const v_rhs = value_mod.fromFixnum(rhs.int) orelse
            return CompileError.IntegerOutOfFixnumRange;
        const c_lhs = try e.addValueConst(v_lhs);
        const c_rhs = try e.addValueConst(v_rhs);
        try e.emit(vm.asm_.mathAdd(dst, Operand.constant(c_lhs), Operand.constant(c_rhs)));
        return;
    }
    // Non-literal operands: stage into temp slots first. Operands
    // are non-tail (recur invalid inside arithmetic args).
    const t_lhs = try e.allocSlot();
    try compileExpr(e, lhs, t_lhs, null);
    const t_rhs = try e.allocSlot();
    try compileExpr(e, rhs, t_rhs, null);
    try e.emit(vm.asm_.mathAdd(dst, Operand.slot(t_lhs), Operand.slot(t_rhs)));
}

/// Lower `(< lhs rhs)` to `cmp:lt`. Same literal-pair peephole
/// shape as `compileAdd`.
fn compileLt(e: *Emitter, lhs: *const Tiny, rhs: *const Tiny, dst: u12) CompileError!void {
    if (lhs.* == .int and rhs.* == .int) {
        const v_lhs = value_mod.fromFixnum(lhs.int) orelse
            return CompileError.IntegerOutOfFixnumRange;
        const v_rhs = value_mod.fromFixnum(rhs.int) orelse
            return CompileError.IntegerOutOfFixnumRange;
        const c_lhs = try e.addValueConst(v_lhs);
        const c_rhs = try e.addValueConst(v_rhs);
        try e.emit(vm.asm_.cmpLt(dst, Operand.constant(c_lhs), Operand.constant(c_rhs)));
        return;
    }
    // Operands are non-tail (recur invalid inside comparison args).
    const t_lhs = try e.allocSlot();
    try compileExpr(e, lhs, t_lhs, null);
    const t_rhs = try e.allocSlot();
    try compileExpr(e, rhs, t_rhs, null);
    try e.emit(vm.asm_.cmpLt(dst, Operand.slot(t_lhs), Operand.slot(t_rhs)));
}

/// Resolve `prefix/name` through the namespace
/// registry attached to the current namespace's parent chain.
/// Lexical bindings are NOT consulted (qualified symbols
/// always go through namespaces).
///
/// Resolution shape:
///   1. Locate the prefix namespace via the registry.
///   2. Look up `name` in that namespace's LOCAL vars only
///      (no auto-refer fallback — qualified means exact).
///   3. Emit `var:load-var`.
///
/// Missing ns or missing var surface as UnresolvedSymbol.
fn compileQualifiedSymbol(
    e: *Emitter,
    ns_prefix: []const u8,
    name: []const u8,
    dst: u12,
) CompileError!void {
    const current_ns = e.namespace orelse return CompileError.UnresolvedSymbol;
    // Alias resolution: a prefix the current namespace registered
    // via `(require '[real.name :as ns_prefix])` names its target;
    // any other prefix is a namespace name.
    const target_ns = qualifiedTarget(current_ns, ns_prefix) orelse return CompileError.UnresolvedSymbol;
    // A symbol qualified with the current namespace's own name is
    // its own Var, interned unbound when the definition is still
    // to come (a forward reference syntax-quote qualified).
    if (target_ns == current_ns) {
        const idx = try e.addVarLocal(name);
        try e.emit(vm.asm_.varLoadVar(dst, idx));
        return;
    }
    const v = target_ns.lookupLocal(name) orelse return CompileError.UnresolvedSymbol;
    const idx = try e.addVarTableEntry(v);
    try e.emit(vm.asm_.varLoadVar(dst, idx));
}

fn compileSymbol(e: *Emitter, name: []const u8, dst: u12) CompileError!void {
    // Symbol resolution order for the Tiny backend (the Form
    // frontend sits ABOVE this; resolution itself lives here):
    //   1. local (this routine) → dispatch on BindingRef
    //      (.direct_slot / .cell_slot / .upvalue per the
    //       capture pre-analysis model)
    //   2. captured upvalue (parent chain) → resolve.upvalue
    //      + capture (also pre-analyzed; bindings are pre-
    //      boxed at binding time so BindingRef is stable
    //      across all control-flow paths)
    //   3. namespace Var (if namespace exists) → var:load-var
    //      (lazy-interns unbound Vars so forward references
    //      work)
    //   4. error → :unresolved-symbol
    //
    // Form lowering does NOT resolve symbols to slots
    // — it preserves names and dispatches operator-position
    // special forms / intrinsics. Slot resolution happens here.
    const ref = e.resolveOrCapture(name) catch |err| switch (err) {
        // Lexical resolution failed; try the
        // namespace before giving up. Critical that this is
        // ONLY done for UnresolvedSymbol — other errors
        // (SlotOverflow, OutOfMemory, InternalCompilerBug)
        // are real bugs and must propagate untouched.
        CompileError.UnresolvedSymbol => {
            if (e.namespace) |_| {
                // Intern (or get existing) Var, add to var_table,
                // emit var:load-var. The Var may be unbound at
                // compile time; runtime traps :unbound-var if so.
                const idx = try e.addVarRef(name);
                try e.emit(vm.asm_.varLoadVar(dst, idx));
                return;
            }
            return err; // no namespace; propagate UnresolvedSymbol
        },
        else => return err,
    };
    switch (ref) {
        .direct_slot => |s| {
            // Skip the no-op self-move.
            if (s == dst) return;
            try e.emit(vm.asm_.move(dst, s));
        },
        .cell_slot => |s| {
            // Same-frame read of a boxed local: closure:get-cell
            // dereferences slot[s]'s cell pointer and writes
            // contents to dst.
            try e.emit(vm.asm_.closureGetCell(dst, s));
        },
        .upvalue => |u| {
            // Captured upvalue: U-operand source via mov:move.
            // resolve(u:N) deref's the cell at runtime per
            // VM.md §6.
            try e.emit(vm.asm_.moveFrom(dst, vm.Operand.upvalue(u)));
        },
    }
}

/// Lower `(def name value?)`. Interns the Var in the current
/// namespace itself (creating an unbound Var if absent; a referred
/// Var of the same name is shadowed, never rebound), compiles
/// `value` into a temp slot, emits `var:store-var` to update
/// the Var's root and write the Var object into `dst`.
///
/// Without a Namespace (`e.namespace == null`), `def` raises
/// `UnresolvedSymbol`. Tests that exercise `def` must pass
/// a Namespace to `compileTinyWithNamespace`.
///
/// `(def x)` (no value) is a forward-declaration: intern the
/// Var, but don't emit any store-var. `dst` gets the Var
/// object (load via `var:var-object`).
fn compileDef(
    e: *Emitter,
    name: []const u8,
    value: ?*const Tiny,
    dst: u12,
) CompileError!void {
    if (e.namespace == null) return CompileError.UnresolvedSymbol;
    const idx = try e.addVarLocal(name);
    if (value) |val| {
        const t = try e.allocSlot();
        try compileExpr(e, val, t, null); // RHS is non-tail
        try e.emit(vm.asm_.varStoreVar(dst, idx, vm.Operand.slot(t)));
    } else {
        // Declare-only: emit var:var-object so dst gets the
        // Var object. Bound state unchanged (still unbound on
        // first declare).
        try e.emit(vm.asm_.varVarObject(dst, idx));
    }
}

/// Lower `(var name)`. Interns the Var if absent,
/// emits `var:var-object` to load the Var object itself (NOT
/// its value). Does not trap on unbound; users can take a
/// reference to a forward-declared Var.
fn compileVarRef(e: *Emitter, name: []const u8, dst: u12) CompileError!void {
    if (e.namespace == null) return CompileError.UnresolvedSymbol;
    const idx = try e.addVarRef(name);
    try e.emit(vm.asm_.varVarObject(dst, idx));
}

/// Lower `(defn name [params...] body)` as sugar for
/// `(def name (fn* name [params...] body))`. The fn* carries
/// `name` as its self-name so the body can self-recurse via
/// the lexical name (handled by the named-fn placeholder
/// pattern, no Var indirection). The outer `def` binds the
/// Var so the function is callable from outside.
///
/// Forward references work because compileDef interns the Var
/// possibly unbound; a sibling `defn` referencing this name
/// emits `var:load-var` against the same Var. The trap fires
/// only if the function is INVOKED before the Var is bound.
///
/// Requires a Namespace (inherits the constraint from compileDef).
fn compileDefn(
    e: *Emitter,
    name: []const u8,
    params: []const []const u8,
    rest_param: ?[]const u8,
    body: *const Tiny,
    dst: u12,
) CompileError!void {
    // Build the equivalent `(fn* name [params...] body)` and
    // dispatch through compileDef. The node lives on the Zig
    // stack frame; compileDef and compileFn complete
    // synchronously, so the pointer remains valid. It is a
    // `TinyNode` without a span so a spanned compile reads the
    // enclosing `defn`'s span for it.
    var fn_node: TinyNode = .{ .tiny = .{ .fn_star = .{
        .name = name,
        .params = params,
        .rest_param = rest_param,
        .body = body,
    } } };
    try compileDef(e, name, &fn_node.tiny, dst);
}

fn compileLetStar(
    e: *Emitter,
    bindings: []const Binding,
    body: *const Tiny,
    dst: u12,
    recur_target: ?*const RecurTarget,
) CompileError!void {
    // Strict left-of-self visibility per COMPILER.md §4.3:
    // each binding's RHS sees bindings 1..i-1 only, not its
    // own LHS. The loop pushes each binding to scope AFTER its
    // RHS has been compiled.
    //
    // Pre-analysis capture: for each binding, walk the rest of
    // the let
    // (subsequent binding RHSs + body) to determine if any
    // descendant `fn_star` body captures this binding's name.
    // If yes, emit `closure:box-local` UNCONDITIONALLY in the
    // let_star prelude (straight-line code that every
    // reachable path traverses), and push the binding as
    // `.cell_slot`. Otherwise push as `.direct_slot`. This
    // makes the runtime cell-vs-direct status of each slot
    // provably stable across all control-flow paths.
    //
    // Scope is restored via `defer` so an error mid-body
    // doesn't leave scope state polluted for a recovering
    // caller.
    const mark = e.scope.items.len;
    defer e.scope.shrinkRetainingCapacity(mark);

    for (bindings, 0..) |b, i| {
        const slot = try e.allocSlot();
        // RHS is non-tail (recur invalid in let-binding RHS).
        try compileExpr(e, b.value, slot, null);

        // Pre-analyze (env-aware): is
        // this binding captured by any inner fn_star in the
        // REMAINING bindings or the body? `env` is just this
        // single name — the analyzer's shadowing handling
        // ensures we don't spuriously match a same-named
        // shadow further inside.
        var env: NameSet = .{};
        defer env.deinit(e.allocator);
        try env.put(e.allocator, b.name);
        var captured: NameSet = .{};
        defer captured.deinit(e.allocator);
        for (bindings[i + 1 ..]) |later| {
            try capturedByDescendantFns(e.allocator, later.value, &env, &captured);
        }
        try capturedByDescendantFns(e.allocator, body, &env, &captured);

        if (captured.contains(b.name)) {
            // Emit box-local in straight-line prelude code.
            try e.emit(vm.asm_.closureBoxLocal(slot));
            try e.scope.append(e.allocator, .{
                .name = b.name,
                .ref = .{ .cell_slot = slot },
            });
        } else {
            try e.pushBinding(b.name, slot);
        }
    }

    // Body inherits recur target (let* body is tail position
    // relative to the enclosing form).
    try compileExpr(e, body, dst, recur_target);
}

/// Lower `(try body (catch any binding handler) (finally body))`.
///
/// Layout WITHOUT finally:
///   try-enter catch_pc binding_slot _
///   <body → dst>
///   try-exit post_pc
/// catch_pc:
///   <handler → dst, binding in scope>
///   try-exit post_pc
/// post_pc:
///
/// Layout WITH finally:
///   try-enter catch_pc binding_slot finally_pc
///   <body → dst>
///   try-exit post_pc          ; VM pushes .normal(post_pc),
///                              ; jumps to finally_pc
/// catch_pc:
///   <handler → dst, binding in scope>
///   try-exit post_pc          ; same: VM pushes .normal,
///                              ; runs finally, resumes post_pc
/// finally_pc:
///   <finally body → scratch_slot>  ; result discarded
///   finally-exit               ; VM pops continuation,
///                              ; dispatches (.normal → post,
///                              ;             .throwing → unwind)
/// post_pc:
///
/// The finally body sees the OUTER lexical scope, NOT the
/// catch binding (which is only in scope inside the handler).
fn compileTry(
    e: *Emitter,
    body: *const Tiny,
    binding: []const u8,
    handler: *const Tiny,
    finally_: ?*const Tiny,
    dst: u12,
) CompileError!void {
    // A catch binding captured by an inner fn is unsupported.
    {
        var env: NameSet = .{};
        defer env.deinit(e.allocator);
        try env.put(e.allocator, binding);
        var captured: NameSet = .{};
        defer captured.deinit(e.allocator);
        try capturedByDescendantFns(e.allocator, handler, &env, &captured);
        if (captured.contains(binding)) return CompileError.UnsupportedFeature;
    }

    const binding_slot = try e.allocSlot();
    // Scratch slot for finally body's result (discarded). Even
    // when finally is absent we allocate to keep dst-slot
    // ownership clean.
    const finally_scratch: u12 = if (finally_ != null) try e.allocSlot() else 0;

    // Emit try-enter with placeholder catch_pc (and
    // finally_pc when present). Patch after we know both PCs.
    const try_enter_pc: u32 = @intCast(e.code.items.len);
    if (finally_ != null) {
        try e.emit(vm.asm_.tryEnterFinally(0, binding_slot, 0));
    } else {
        try e.emit(vm.asm_.tryEnter(0, binding_slot));
    }

    // Body → dst.
    try compileExpr(e, body, dst, null);

    // Body-exit try-exit (post_pc placeholder).
    const body_exit_pc: u32 = @intCast(e.code.items.len);
    try e.emit(vm.asm_.tryExit(0));

    // Catch entry.
    const catch_pc: u32 = @intCast(e.code.items.len);
    {
        const enter_inst = &e.code.items[try_enter_pc];
        enter_inst.a = vm.Operand.jump(@intCast(catch_pc));
    }

    const scope_mark = e.scope.items.len;
    defer e.scope.shrinkRetainingCapacity(scope_mark);
    try e.pushBinding(binding, binding_slot);
    try compileExpr(e, handler, dst, null);
    e.scope.shrinkRetainingCapacity(scope_mark);

    // Catch-exit try-exit (post_pc placeholder).
    const catch_exit_pc: u32 = @intCast(e.code.items.len);
    try e.emit(vm.asm_.tryExit(0));

    // Optional finally block + finally-exit.
    var finally_pc: u32 = 0;
    if (finally_) |fin_body| {
        finally_pc = @intCast(e.code.items.len);
        // Finally body sees OUTER scope (binding is out of
        // scope here — we already popped it). Result discarded
        // into finally_scratch slot.
        try compileExpr(e, fin_body, finally_scratch, null);
        try e.emit(vm.asm_.finallyExit());
        // Patch try-enter's finally_pc operand.
        const enter_inst = &e.code.items[try_enter_pc];
        enter_inst.c = vm.Operand.jump(@intCast(finally_pc));
    }

    // post_pc = end of code. Patch both try-exits.
    const post_pc: u32 = @intCast(e.code.items.len);
    {
        const body_exit = &e.code.items[body_exit_pc];
        body_exit.a = vm.Operand.jump(@intCast(post_pc));
        const catch_exit = &e.code.items[catch_exit_pc];
        catch_exit.a = vm.Operand.jump(@intCast(post_pc));
    }
}

/// Compile `(throw value)`. Compile value into a
/// fresh slot (we use `dst` since the throw never returns
/// normally — the dst slot's prior contents don't matter),
/// then emit `ctrl:throw <dst>`.
fn compileThrow(e: *Emitter, value: *const Tiny, dst: u12) CompileError!void {
    try compileExpr(e, value, dst, null);
    try e.emit(vm.asm_.throwOp(vm.Operand.slot(dst)));
}

/// Lower `(loop* [b1 v1 b2 v2 ...] body)` per COMPILER.md §5.7
/// + VM.md §11.
///
/// Same as `let*` for binding setup (sequential RHS visibility +
/// captured-binding cells via pre-analysis). After the bindings
/// are set up, mark the entry PC and compile the body with a
/// loop `RecurTarget` so any `(recur ...)` in tail position
/// rebinds the loop slots and jumps back to entry.
///
/// Entry-PC placement: AFTER the
/// binding setup + captured-binding boxing prelude. Jumping
/// back must NOT re-evaluate initial RHSs and must NOT re-box
/// the binding slots — the recur path handles cell installation
/// directly.
fn compileLoopStar(
    e: *Emitter,
    bindings: []const Binding,
    body: *const Tiny,
    dst: u12,
) CompileError!void {
    const mark = e.scope.items.len;
    defer e.scope.shrinkRetainingCapacity(mark);

    // 1-3. Bind values, box captured bindings, push scope
    // entries (mirrors compileLetStar logic exactly).
    const binding_slots = try e.allocator.alloc(u12, bindings.len);
    defer e.allocator.free(binding_slots);
    const captured_mask = try e.allocator.alloc(bool, bindings.len);
    defer e.allocator.free(captured_mask);

    for (bindings, 0..) |b, i| {
        const slot = try e.allocSlot();
        binding_slots[i] = slot;
        try compileExpr(e, b.value, slot, null);

        // Pre-analyze (same as let*): is this binding captured
        // by any descendant fn in later bindings or body? `env`
        // is the single binding name; analyzer's shadowing
        // handling avoids spurious matches on inner same-named
        // shadows.
        var env: NameSet = .{};
        defer env.deinit(e.allocator);
        try env.put(e.allocator, b.name);
        var captured: NameSet = .{};
        defer captured.deinit(e.allocator);
        for (bindings[i + 1 ..]) |later| {
            try capturedByDescendantFns(e.allocator, later.value, &env, &captured);
        }
        try capturedByDescendantFns(e.allocator, body, &env, &captured);

        const is_captured = captured.contains(b.name);
        captured_mask[i] = is_captured;

        if (is_captured) {
            try e.emit(vm.asm_.closureBoxLocal(slot));
            try e.scope.append(e.allocator, .{
                .name = b.name,
                .ref = .{ .cell_slot = slot },
            });
        } else {
            try e.pushBinding(b.name, slot);
        }
    }

    // 4. Mark entry PC (AFTER box-local prelude).
    const entry_pc = try e.checkJumpTarget(e.currentPc());
    const loop_target = RecurTarget{
        .entry_pc = entry_pc,
        .binding_slots = binding_slots,
        .captured_mask = captured_mask,
        .kind = .loop_star,
    };

    // 5. Compile body with the loop target installed. The
    // body REPLACES (not propagates) any outer recur target —
    // a recur inside the body always targets THIS loop, not an
    // enclosing one (nested-loop rule).
    try compileExpr(e, body, dst, &loop_target);
}

/// Lower `(recur args...)` per COMPILER.md §5.6 + VM.md §11.
///
/// `recur_target` is the nearest enclosing `loop*` or `fn*`'s
/// target, threaded from compileExpr. If `null`, the `recur`
/// is in non-tail position and we raise `RecurOutsideTail`.
/// Arity is checked against `target.binding_slots.len` before
/// any code is emitted.
///
/// Lowering (parallel-assignment via fresh temps, then move +
/// optional fresh-cell install per captured_mask):
///   compile each arg into a fresh temp slot (non-tail)
///   for each binding i in order:
///     if captured_mask[i]:
///       closure:box-local temp[i]              ; temp[i] := fresh cell
///       mov:move binding_slot[i], temp[i]       ; install fresh cell
///     else:
///       mov:move binding_slot[i], temp[i]
///   jump:jmp entry_pc
///
/// `dst` is never written: `recur` jumps unconditionally before
/// reaching any code that would consume dst. Surrounding control
/// flow (e.g., `if`'s end-jmp) may emit unreachable code after
/// the recur — harmless dead code.
fn compileRecur(
    e: *Emitter,
    args: []const *const Tiny,
    recur_target: ?*const RecurTarget,
) CompileError!void {
    const target = recur_target orelse return CompileError.RecurOutsideTail;
    if (args.len != target.binding_slots.len) return CompileError.RecurArityMismatch;

    // Evaluate each arg into a fresh temp slot. Using temps
    // (not the target slots directly) makes parallel-assignment
    // correct for aliasing cases like `(loop* [a 1 b 2] (recur b a))`.
    const temps = try e.allocator.alloc(u12, args.len);
    defer e.allocator.free(temps);
    for (args, 0..) |arg, i| {
        temps[i] = try e.allocSlot();
        // Recur args are non-tail (any nested recur would target
        // the wrong scope; PLAN §11.3).
        try compileExpr(e, arg, temps[i], null);
    }

    // Install into target slots. For captured bindings, allocate
    // a fresh cell per iteration (per VM.md §11 — mutating the
    // shared cell would break immutable lexical binding
    // semantics; canonical hazard documented in COMPILER.md
    // §5.6 captured-recur).
    for (target.binding_slots, 0..) |target_slot, i| {
        if (target.captured_mask[i]) {
            try e.emit(vm.asm_.closureBoxLocal(temps[i]));
            try e.emit(vm.asm_.move(target_slot, temps[i]));
        } else {
            try e.emit(vm.asm_.move(target_slot, temps[i]));
        }
    }

    try e.emit(vm.asm_.jumpJmp(target.entry_pc));
}

fn compileDo(
    e: *Emitter,
    exprs: []const *const Tiny,
    dst: u12,
    recur_target: ?*const RecurTarget,
) CompileError!void {
    // Empty do is nil.
    if (exprs.len == 0) {
        try e.emit(vm.asm_.loadNil(dst));
        return;
    }
    // Single-expression do compiles directly into dst, inheriting
    // tail position from the enclosing form.
    if (exprs.len == 1) {
        try compileExpr(e, exprs[0], dst, recur_target);
        return;
    }
    // Multi-expression: ALL non-last go to a SHARED discard
    // slot (avoids the 999-slot blowup that
    // `(do e1 e2 ... e1000)` would cause with fresh-per-expr
    // allocation). Reusing one discard slot for all ignored
    // results is the natural meaning of "compile this for its
    // effect only" — not asymmetric liveness analysis.
    // Non-last expressions are NOT in tail position.
    const discard = try e.allocSlot();
    for (exprs[0 .. exprs.len - 1]) |expr| {
        try compileExpr(e, expr, discard, null);
    }
    // Last expression IS tail position; inherit recur target.
    try compileExpr(e, exprs[exprs.len - 1], dst, recur_target);
}

/// Lower a `fn*` literal: spawn a child Emitter, compile body
/// in it, register the resulting Routine in the parent's const
/// pool, register an empty capture descriptor in the parent's
/// capture table, emit `closure:make` in the parent.
///
/// The child Emitter is linked to the parent, so free variable
/// references in the body resolve to captures through the
/// parent chain. A named `fn*` whose body references its own
/// name uses the placeholder-cell pattern for self-reference.
fn compileFn(
    parent: *Emitter,
    name: ?[]const u8,
    params: []const []const u8,
    rest_param: ?[]const u8,
    body: *const Tiny,
    dst: u12,
) CompileError!void {
    // Reject duplicate parameter names. O(N²); nexis fns are
    // rarely high-arity.
    for (params, 0..) |p, i| {
        for (params[0..i]) |q| {
            if (std.mem.eql(u8, p, q)) return CompileError.DuplicateParam;
        }
    }
    // The rest param can't shadow any fixed param.
    if (rest_param) |rp| {
        for (params) |p| {
            if (std.mem.eql(u8, rp, p)) return CompileError.DuplicateParam;
        }
    }
    // argc encodes in a 12-bit operand
    // (max 4095), AND a fresh result slot must fit above the
    // params (so max practical arity is 4095). Reject > 4095.
    if (params.len > 4095) return CompileError.SlotOverflow;

    // Named fn* self-reference: if the fn has a
    // self-name AND the body references it, use the placeholder-
    // cell pattern (per COMPILER.md §5.5 + §6 + §6.1). Allocate
    // a cell in PARENT's frame BEFORE compiling the child body
    // so the child can capture it; emit `closure:init-cell`
    // AFTER `closure:make` so the cell's contents become the
    // just-constructed closure value.
    //
    // If the body doesn't reference the self-name, skip the
    // placeholder entirely (one freeVars walk decides).
    var self_referenced = false;
    if (name) |n| {
        var params_env: NameSet = .{};
        defer params_env.deinit(parent.allocator);
        for (params) |p| try params_env.put(parent.allocator, p);
        var body_free: NameSet = .{};
        defer body_free.deinit(parent.allocator);
        try freeVars(parent.allocator, body, &params_env, &body_free);
        self_referenced = body_free.contains(n);
    }

    // If self-referenced, allocate the placeholder cell in
    // PARENT's frame and emit closure:new-cell (in straight-
    // line code, before the child's closure:make).
    var self_cell_slot: u12 = 0; // unused if !self_referenced
    if (self_referenced) {
        self_cell_slot = try parent.allocSlot();
        try parent.emit(vm.asm_.closureNewCell(self_cell_slot));
    }

    // Spawn child Emitter linked to parent (the parent pointer
    // enables capture discovery).
    //
    // Use `defer` (not `errdefer`): after a
    // successful `child.finish()`, the transferred ArrayLists
    // (code/consts/capture_descs) are emptied via `toOwnedSlice`,
    // but `child.scope` and `child.captures` retain their
    // capacity. `errdefer` would skip cleanup on the success
    // path and leak. `defer` always fires; `Emitter.deinit` on
    // emptied ArrayLists is a no-op so the transfer remains
    // correct.
    var child = Emitter.init(parent.allocator);
    child.parent = parent;
    child.namespace = parent.namespace; // inherit ns for def/var resolution
    child.spanned = parent.spanned;
    child.source = parent.source;
    // The prelude (parameter boxing) carries the fn form's span.
    child.current_span = parent.current_span;
    defer child.deinit();

    // Inject self-name as a pre-existing capture so
    // the body's references resolve to upvalue 0 (sourced from
    // the placeholder cell allocated above). The capture
    // descriptor's local_cell_slot source for upvalue 0 will
    // be set up below.
    if (self_referenced) {
        try child.captures.append(child.allocator, .{ .local_cell_slot = self_cell_slot });
        try child.captured_names.append(child.allocator, .{ .name = name.?, .upvalue = 0 });
    }

    // Pre-analyze body to find captured params (env-aware):
    // pass the param set as `env` so
    // the analyzer only reports captures matching one of OUR
    // params (and not, e.g., a same-named binding shadowed
    // inside an inner let_star).
    var params_env: NameSet = .{};
    defer params_env.deinit(parent.allocator);
    for (params) |p| try params_env.put(parent.allocator, p);
    if (rest_param) |rp| try params_env.put(parent.allocator, rp);
    var captured_in_body: NameSet = .{};
    defer captured_in_body.deinit(parent.allocator);
    try capturedByDescendantFns(parent.allocator, body, &params_env, &captured_in_body);

    for (params, 0..) |p, i| {
        const slot = try child.allocSlot();
        std.debug.assert(slot == @as(u12, @intCast(i))); // monotonic invariant
        if (captured_in_body.contains(p)) {
            // Captured param: box at function entry. The
            // box-local sits in straight-line prelude code so
            // it always executes before any inner closure could
            // possibly construct against this slot.
            try child.emit(vm.asm_.closureBoxLocal(slot));
            try child.scope.append(child.allocator, .{
                .name = p,
                .ref = .{ .cell_slot = slot },
            });
        } else {
            try child.pushBinding(p, slot);
        }
    }

    // The rest parameter lives at slot `params.len`. The VM
    // packs excess args into a list and installs it there at
    // call time (before any of the fn body runs). Treat the
    // rest binding like any other param for capture/scope.
    if (rest_param) |rp| {
        const slot = try child.allocSlot();
        std.debug.assert(slot == @as(u12, @intCast(params.len)));
        if (captured_in_body.contains(rp)) {
            try child.emit(vm.asm_.closureBoxLocal(slot));
            try child.scope.append(child.allocator, .{
                .name = rp,
                .ref = .{ .cell_slot = slot },
            });
        } else {
            try child.pushBinding(rp, slot);
        }
    }

    // Set up fn RecurTarget so `(recur ...)` inside
    // the body (with no enclosing `loop*`) rebinds the params
    // and jumps back to the entry point. Captured params get
    // fresh cells per iteration (per VM.md §11 + COMPILER.md
    // §5.6); non-captured get plain mov:move.
    //
    // entry_pc placement: AFTER the box-local prelude. Jumping
    // back must NOT re-box params (would lose the previous
    // iteration's mutated cell pointer); it must land where the
    // body begins reading.
    // The target covers the fixed params and, for a variadic fn,
    // the rest slot as one more binding: `(recur a b s)` into
    // `(fn* [a b & r] ...)` installs `s` in `r`'s slot as it is,
    // so the rest param receives whatever seq the recur passes
    // (COMPILER.md §5.6).
    const binding_count = params.len + @as(usize, if (rest_param != null) 1 else 0);
    const param_slots = try parent.allocator.alloc(u12, binding_count);
    defer parent.allocator.free(param_slots);
    const captured_mask = try parent.allocator.alloc(bool, binding_count);
    defer parent.allocator.free(captured_mask);
    for (params, 0..) |p, i| {
        param_slots[i] = @intCast(i); // fixed params live at slots 0..fixed_arity-1
        captured_mask[i] = captured_in_body.contains(p);
    }
    if (rest_param) |rp| {
        param_slots[params.len] = @intCast(params.len);
        captured_mask[params.len] = captured_in_body.contains(rp);
    }
    const fn_entry_pc = try child.checkJumpTarget(child.currentPc());
    const fn_target = RecurTarget{
        .entry_pc = fn_entry_pc,
        .binding_slots = param_slots,
        .captured_mask = captured_mask,
        .kind = .fn_star,
    };

    // Allocate a fresh result slot for the body so a self-move
    // pattern (compiling a symbol whose binding lives in the
    // result slot) is naturally a no-op (compileSymbol guard).
    const result_slot = try child.allocSlot();
    try compileExpr(&child, body, result_slot, &fn_target);
    try child.emit(vm.asm_.returnSlot(result_slot));

    // Capture descriptor sources come from
    // `child.captures` (accumulated by `resolveOrCapture`
    // during child body compilation). Snapshot them before
    // `child.finish()` clears them, then register the
    // descriptor in the PARENT's table.
    const sources = if (child.captures.items.len == 0)
        &[_]vm.CaptureSource{}
    else
        try parent.allocator.dupe(vm.CaptureSource, child.captures.items);
    const upvalue_count: u16 = @intCast(child.captures.items.len);

    // Finalize child Compiled (transfers ownership of code,
    // consts, capture_descs slices to the result).
    const child_compiled = try child.finish();

    // Allocate the Routine on the parent's compile arena so its
    // pointer outlives both Compiled artifacts
    // (compile-arena-owned routine tree).
    const child_routine = try parent.allocator.create(vm.Routine);
    child_routine.* = .{
        .code = child_compiled.code,
        .consts = child_compiled.consts,
        .capture_descs = child_compiled.capture_descs,
        .var_table = child_compiled.var_table,
        .slot_count = child_compiled.slot_count,
        .fixed_arity = @intCast(params.len),
        .variadic = rest_param != null,
        .upvalue_count = upvalue_count,
        // The name is copied: a `defn` name borrows from source
        // text that need not outlive the routine.
        .name = if (name) |n| try parent.allocator.dupe(u8, n) else "fn",
        .spans = child_compiled.spans,
        .origin = if (parent.current_span) |sp| toSourceSpan(sp) else null,
        .source = parent.source,
    };

    // Register the routine + the (possibly non-empty) capture
    // descriptor in the PARENT's pools.
    const proto_idx = try parent.addRoutineConst(child_routine);
    const cap_desc_idx = try parent.addCaptureDescriptor(.{ .sources = sources });

    // Emit closure:make in parent.
    try parent.emit(vm.asm_.closureMake(proto_idx, cap_desc_idx, dst));

    // If self-referenced, finalize the placeholder
    // cell with the just-constructed closure. The cell now
    // holds the closure; subsequent invocations of the
    // closure deref upvalue 0 to find itself.
    if (self_referenced) {
        try parent.emit(vm.asm_.closureInitCell(self_cell_slot, vm.Operand.slot(dst)));
    }
}

/// Lower `letfn*` per COMPILER.md §5.6b: mutually-recursive
/// function bindings via the placeholder-cell pattern.
///
/// Sequence (COMPILER.md §5.6b):
///   1. Allocate placeholder cells: `closure:new-cell` for
///      each binding's name. Push each into scope as
///      `.cell_slot`.
///   2. For each binding, compile its fn body (constructing
///      a closure via `closure:make`). Each fn body is
///      compiled in a child Emitter, so references to letfn*
///      names are captured from the parent's `.cell_slot`s
///      and read at runtime as upvalues (cell deref via the
///      U-operand). The letfn* body itself sees the
///      bindings as same-frame `.cell_slot` reads
///      (`closure:get-cell`).
///   3. For each binding, init the cell with the
///      constructed closure: `closure:init-cell s_cell, s_closure`.
///   4. Compile body (with all letfn* bindings still in
///      scope).
fn compileLetFnStar(
    e: *Emitter,
    bindings: []const FnBinding,
    body: *const Tiny,
    dst: u12,
    recur_target: ?*const RecurTarget,
) CompileError!void {
    // Reject duplicate binding names. Unlike let* (sequential
    // shadowing OK), letfn* names are mutually visible — two
    // with the same name create resolution ambiguity.
    for (bindings, 0..) |b, i| {
        for (bindings[0..i]) |b2| {
            if (std.mem.eql(u8, b.name, b2.name)) return CompileError.DuplicateBinding;
        }
    }

    const scope_mark = e.scope.items.len;
    defer e.scope.shrinkRetainingCapacity(scope_mark);

    // 1. Allocate placeholder cells for each binding;
    // push each into scope as .cell_slot. Cells must exist
    // BEFORE any closure:make so the cap_desc local_cell_slot
    // sources can reference them.
    const cell_slots = try e.allocator.alloc(u12, bindings.len);
    defer e.allocator.free(cell_slots);
    for (bindings, 0..) |b, i| {
        const s = try e.allocSlot();
        cell_slots[i] = s;
        try e.emit(vm.asm_.closureNewCell(s));
        try e.scope.append(e.allocator, .{
            .name = b.name,
            .ref = .{ .cell_slot = s },
        });
    }

    // 2. Compile each fn (constructing closures). We
    // allocate a fresh result slot for each closure value.
    // The fn bodies see all letfn* names in scope (as
    // .cell_slot via the entries we just pushed).
    const closure_slots = try e.allocator.alloc(u12, bindings.len);
    defer e.allocator.free(closure_slots);
    for (bindings, 0..) |b, i| {
        const cs = try e.allocSlot();
        closure_slots[i] = cs;
        // compileFn handles the named case via the
        // placeholder pattern when the body references its
        // own name. For letfn*, we don't pass `b.name` as
        // the fn's self-name because the binding-name's cell
        // is already in scope (so the fn body's references
        // resolve via parent-chain capture); using the
        // self-name machinery here would double-allocate.
        try compileFn(e, null, b.params, b.rest_param, b.body, cs);
    }

    // 3. Init each cell with its closure.
    for (bindings, 0..) |_, i| {
        try e.emit(vm.asm_.closureInitCell(cell_slots[i], vm.Operand.slot(closure_slots[i])));
    }

    // 4. Compile body in the now-fully-bound scope. Body
    // is in tail position relative to the enclosing form; inherit
    // recur target.
    try compileExpr(e, body, dst, recur_target);
}

/// Lower a function-call form: stage callee + args in a
/// contiguous call block per VM.md §6 range-call ABI, emit
/// `call:call`. The result lands in `dst`.
///
/// **Critical**: the entire `1 + args.len`
/// contiguous call block MUST be reserved BEFORE compiling
/// any sub-expression. A per-arg allocSlot pattern breaks
/// silently when the callee or any arg's compilation
/// allocates its own temp slots — the next arg's allocated
/// slot is then not adjacent to the previous one,
/// violating the range-call ABI invariant. Reserve up front;
/// each sub-expression then targets its predetermined slot.
///
/// Slot-allocation correctness for "live across the call":
/// `dst` was allocated by the caller before we entered, and
/// the call block is allocated after `dst` (so `dst < call_base`).
/// Per VM.md §6 the call-clobbered region is `[call_base ..
/// call_base + slot_count)` — `dst` sits below this region
/// and survives the call.
fn compileCall(
    e: *Emitter,
    callee: *const Tiny,
    args: []const *const Tiny,
    dst: u12,
) CompileError!void {
    // 12-bit operand encoding: argc + 1 (closure slot) + 1 (room
    // for the result slot peeking at most one beyond) must fit;
    // 4095 max args is more than nexis will ever exercise.
    if (args.len > 4095) return CompileError.SlotOverflow;

    // Reserve the entire contiguous call block up front:
    //   slot[call_base]                = closure
    //   slot[call_base + 1 + i]        = arg i
    const block_count: u32 = 1 + @as(u32, @intCast(args.len));
    const call_base = try e.allocSlotBlock(block_count);

    // Compile callee into call_base. Sub-expression may itself
    // allocate temps; those land above the reserved block, which
    // is correct (they're free-to-use by the time the call fires).
    // Callee + args are non-tail (recur invalid inside call sites).
    try compileExpr(e, callee, call_base, null);
    // Compile each arg into its predetermined slot in the block.
    for (args, 0..) |arg, i| {
        const arg_slot: u12 = @intCast(@as(u32, call_base) + 1 + @as(u32, @intCast(i)));
        try compileExpr(e, arg, arg_slot, null);
    }

    // Emit the call.
    try e.emit(vm.asm_.callCall(call_base, @intCast(args.len), dst));
}

fn compileIf(
    e: *Emitter,
    test_form: *const Tiny,
    then_form: *const Tiny,
    else_form: ?*const Tiny,
    dst: u12,
    recur_target: ?*const RecurTarget,
) CompileError!void {
    // Lower the test into a fresh temp slot; we can't reuse `dst`
    // because the test value would be overwritten by either arm.
    // Test is NON-tail.
    const t_test = try e.allocSlot();
    try compileExpr(e, test_form, t_test, null);

    // Emit `jump:if-false PLACEHOLDER, t_test`. Remember its PC
    // for back-patching once the else-label is known.
    const if_false_pc = try e.emitJumpIfFalsePlaceholder(Operand.slot(t_test));

    // Then-arm: compile into dst. Tail position INHERITED.
    try compileExpr(e, then_form, dst, recur_target);

    // Emit `jump:jmp PLACEHOLDER` to skip past the else-arm.
    // Remember its PC for back-patching to end-label.
    // (If then_form was a recur, this jump is unreachable but
    // harmless dead code.)
    const end_jmp_pc = try e.emitJumpPlaceholder();

    // Else-label is at the current PC.
    const else_label = try e.checkJumpTarget(e.currentPc());
    e.patchJumpAt(if_false_pc, else_label);

    // Else-arm: compile into dst (or synthesize nil if absent).
    // Tail position INHERITED.
    if (else_form) |ef| {
        try compileExpr(e, ef, dst, recur_target);
    } else {
        try e.emit(vm.asm_.loadNil(dst));
    }

    // End-label is at the current PC; patch the unconditional
    // jump from the end of the then-arm.
    const end_label = try e.checkJumpTarget(e.currentPc());
    e.patchJumpAt(end_jmp_pc, end_label);
}

// =============================================================================
// Inline tests
// =============================================================================

const testing = std.testing;

/// Helper: run a Tiny program and return the resulting Value.
/// Compile and run `form` on a VM whose memory the test arena owns,
/// so the result value outlives the VM and the arena frees it.
fn runTiny(arena: *std.heap.ArenaAllocator, form: *const Tiny) !Value {
    const compiled = try compileTiny(arena.allocator(), form);
    const routine = compiled.toRoutine("test");
    var v = try vm.VM.init(arena.allocator(), &routine);
    defer detachHeapAndDeinit(&v);
    return try v.run();
}

/// Tear `v` down without freeing its heap blocks: they came from the
/// test arena, which frees them, and the returned value points at
/// them.
fn detachHeapAndDeinit(v: *vm.VM) void {
    v.heap = null;
    v.deinit();
}

test "compile: integer literal evaluates to itself" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try runTiny(&arena, &.{ .int = 42 });
    try testing.expect(result.kind() == .fixnum);
    try testing.expectEqual(@as(i64, 42), result.asFixnum());
}

test "compile: nil literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try runTiny(&arena, &.{ .nil = {} });
    try testing.expect(result.kind() == .nil);
}

test "compile: bool literals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r_true = try runTiny(&arena, &.{ .bool = true });
    try testing.expect(r_true.kind() == .true_);
    const r_false = try runTiny(&arena, &.{ .bool = false });
    try testing.expect(r_false.kind() == .false_);
}

test "compile: (+ 1 2) = 3 — literal-pair peephole" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try runTiny(
        &arena,
        &.{ .add = .{ .lhs = &.{ .int = 1 }, .rhs = &.{ .int = 2 } } },
    );
    try testing.expectEqual(@as(i64, 3), result.asFixnum());
}

test "compile: (+ -7 -5) = -12 — negative operands" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try runTiny(
        &arena,
        &.{ .add = .{ .lhs = &.{ .int = -7 }, .rhs = &.{ .int = -5 } } },
    );
    try testing.expectEqual(@as(i64, -12), result.asFixnum());
}

test "compile: nested (+ (+ 1 2) (+ 3 4)) = 10 — recursive non-literal operands" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const inner_l: Tiny = .{ .add = .{ .lhs = &.{ .int = 1 }, .rhs = &.{ .int = 2 } } };
    const inner_r: Tiny = .{ .add = .{ .lhs = &.{ .int = 3 }, .rhs = &.{ .int = 4 } } };
    const outer: Tiny = .{ .add = .{ .lhs = &inner_l, .rhs = &inner_r } };
    const result = try runTiny(&arena, &outer);
    try testing.expectEqual(@as(i64, 10), result.asFixnum());
}

test "compile: integer literal beyond i48 range rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const res = compileTiny(arena.allocator(), &.{ .int = value_mod.fixnum_max + 1 });
    try testing.expectError(CompileError.IntegerOutOfFixnumRange, res);
}

test "compile + run: (+ fixnum_max 1) compiles and the VM promotes the sum to a bignum" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const compiled = try compileTiny(
        arena.allocator(),
        &.{ .add = .{ .lhs = &.{ .int = value_mod.fixnum_max }, .rhs = &.{ .int = 1 } } },
    );
    const routine = compiled.toRoutine("(+ fixnum_max 1)");
    var v = try vm.VM.init(testing.allocator, &routine);
    defer v.deinit();
    const res = try v.run();
    try testing.expect(res.kind() == .bignum);
}

// ---- cmp:lt tests ----

test "compile lt: (< 1 2) = true" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try runTiny(&arena, &.{ .lt = .{ .lhs = &.{ .int = 1 }, .rhs = &.{ .int = 2 } } });
    try testing.expect(result.isBool());
    try testing.expectEqual(true, result.asBool());
}

test "compile lt: (< 2 1) = false" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try runTiny(&arena, &.{ .lt = .{ .lhs = &.{ .int = 2 }, .rhs = &.{ .int = 1 } } });
    try testing.expectEqual(false, result.asBool());
}

test "compile lt: (< 3 3) = false — strict less-than" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try runTiny(&arena, &.{ .lt = .{ .lhs = &.{ .int = 3 }, .rhs = &.{ .int = 3 } } });
    try testing.expectEqual(false, result.asBool());
}

test "compile lt: (if (< x 5) 'lt' 'ge') threads through if" {
    // (let* [x 3] (if (< x 5) 1 0)) = 1
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cond: Tiny = .{ .lt = .{ .lhs = &.{ .symbol = "x" }, .rhs = &.{ .int = 5 } } };
    const if_form: Tiny = .{ .if_ = .{
        .test_ = &cond,
        .then = &.{ .int = 1 },
        .else_ = &.{ .int = 0 },
    } };
    const let_form: Tiny = .{ .let_star = .{
        .bindings = &.{.{ .name = "x", .value = &.{ .int = 3 } }},
        .body = &if_form,
    } };
    const result = try runTiny(&arena, &let_form);
    try testing.expectEqual(@as(i64, 1), result.asFixnum());
}

test "compile lt: nested (< (+ a b) c) — operands are sub-expressions" {
    // (let* [a 1 b 2 c 4] (< (+ a b) c)) = true (3 < 4)
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const add_form: Tiny = .{ .add = .{ .lhs = &.{ .symbol = "a" }, .rhs = &.{ .symbol = "b" } } };
    const lt_form: Tiny = .{ .lt = .{ .lhs = &add_form, .rhs = &.{ .symbol = "c" } } };
    const let_form: Tiny = .{ .let_star = .{
        .bindings = &.{
            .{ .name = "a", .value = &.{ .int = 1 } },
            .{ .name = "b", .value = &.{ .int = 2 } },
            .{ .name = "c", .value = &.{ .int = 4 } },
        },
        .body = &lt_form,
    } };
    const result = try runTiny(&arena, &let_form);
    try testing.expectEqual(true, result.asBool());
}

// ---- loop* + recur tests ----

test "compile loop: (loop* [i 0] i) — degenerate loop, body returns binding" {
    // No recur — just a single-iteration "loop".
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const form: Tiny = .{ .loop_star = .{
        .bindings = &.{.{ .name = "i", .value = &.{ .int = 7 } }},
        .body = &.{ .symbol = "i" },
    } };
    const result = try runTiny(&arena, &form);
    try testing.expectEqual(@as(i64, 7), result.asFixnum());
}

test "compile loop: (loop* [i 0] (if (< i 1) (recur (+ i 1)) i)) = 1 — one iteration" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const recur_arg: Tiny = .{ .add = .{ .lhs = &.{ .symbol = "i" }, .rhs = &.{ .int = 1 } } };
    const recur_form: Tiny = .{ .recur = .{ .args = &.{&recur_arg} } };
    const cond: Tiny = .{ .lt = .{ .lhs = &.{ .symbol = "i" }, .rhs = &.{ .int = 1 } } };
    const body: Tiny = .{ .if_ = .{
        .test_ = &cond,
        .then = &recur_form,
        .else_ = &.{ .symbol = "i" },
    } };
    const form: Tiny = .{ .loop_star = .{
        .bindings = &.{.{ .name = "i", .value = &.{ .int = 0 } }},
        .body = &body,
    } };
    const result = try runTiny(&arena, &form);
    try testing.expectEqual(@as(i64, 1), result.asFixnum());
}

test "compile loop: (loop* [i 0 acc 0] (if (< i 10) (recur (+ i 1) (+ acc i)) acc)) = 45" {
    // Sum 0..9 via two-binding loop.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const i_plus_1: Tiny = .{ .add = .{ .lhs = &.{ .symbol = "i" }, .rhs = &.{ .int = 1 } } };
    const acc_plus_i: Tiny = .{ .add = .{ .lhs = &.{ .symbol = "acc" }, .rhs = &.{ .symbol = "i" } } };
    const recur_form: Tiny = .{ .recur = .{ .args = &.{ &i_plus_1, &acc_plus_i } } };
    const cond: Tiny = .{ .lt = .{ .lhs = &.{ .symbol = "i" }, .rhs = &.{ .int = 10 } } };
    const body: Tiny = .{ .if_ = .{
        .test_ = &cond,
        .then = &recur_form,
        .else_ = &.{ .symbol = "acc" },
    } };
    const form: Tiny = .{ .loop_star = .{
        .bindings = &.{
            .{ .name = "i", .value = &.{ .int = 0 } },
            .{ .name = "acc", .value = &.{ .int = 0 } },
        },
        .body = &body,
    } };
    const result = try runTiny(&arena, &form);
    try testing.expectEqual(@as(i64, 45), result.asFixnum());
}

test "compile loop: 10k iteration loop runs in CONSTANT stack space" {
    // Assert stack_high_water doesn't
    // grow with iteration count. Final-length check is
    // insufficient (buggy impl could grow + shrink to land at
    // the same final value); we check the high-water mark
    // explicitly.
    //
    // (loop* [i 0] (if (< i 10000) (recur (+ i 1)) i)) = 10000
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const recur_arg: Tiny = .{ .add = .{ .lhs = &.{ .symbol = "i" }, .rhs = &.{ .int = 1 } } };
    const recur_form: Tiny = .{ .recur = .{ .args = &.{&recur_arg} } };
    const cond: Tiny = .{ .lt = .{ .lhs = &.{ .symbol = "i" }, .rhs = &.{ .int = 10000 } } };
    const body: Tiny = .{ .if_ = .{
        .test_ = &cond,
        .then = &recur_form,
        .else_ = &.{ .symbol = "i" },
    } };
    const form: Tiny = .{ .loop_star = .{
        .bindings = &.{.{ .name = "i", .value = &.{ .int = 0 } }},
        .body = &body,
    } };
    const compiled = try compileTiny(arena.allocator(), &form);
    const routine = compiled.toRoutine("10k-loop");
    var v = try vm.VM.init(testing.allocator, &routine);
    defer v.deinit();
    const stack_before = v.stack_high_water;
    const frames_before = v.frame_high_water;
    const result = try v.run();
    try testing.expectEqual(@as(i64, 10000), result.asFixnum());
    // 10k iterations must not have grown either high-water.
    try testing.expectEqual(stack_before, v.stack_high_water);
    try testing.expectEqual(frames_before, v.frame_high_water);
}

test "compile loop: (loop* [a 1 b 2] (if false (recur b a) (+ a b))) = 3 — aliasing recur (untaken)" {
    // Aliasing pattern `(recur b a)` would corrupt without
    // parallel-assignment temps. Branch untaken, but compiles +
    // verifies no analyzer/codegen error.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const recur_form: Tiny = .{ .recur = .{ .args = &.{
        &.{ .symbol = "b" },
        &.{ .symbol = "a" },
    } } };
    const body: Tiny = .{ .if_ = .{
        .test_ = &.{ .bool = false },
        .then = &recur_form,
        .else_ = &.{ .add = .{ .lhs = &.{ .symbol = "a" }, .rhs = &.{ .symbol = "b" } } },
    } };
    const form: Tiny = .{ .loop_star = .{
        .bindings = &.{
            .{ .name = "a", .value = &.{ .int = 1 } },
            .{ .name = "b", .value = &.{ .int = 2 } },
        },
        .body = &body,
    } };
    const result = try runTiny(&arena, &form);
    try testing.expectEqual(@as(i64, 3), result.asFixnum());
}

test "compile loop: (loop* [a 1 b 2] (if true (recur b a) (+ a b))) — recur b a swaps then if continued" {
    // Same as above but recur IS taken once. Use a counter to
    // limit. Verify parallel-assignment actually swapped:
    //   (loop* [a 1 b 2 c 0]
    //     (if (< c 1) (recur b a (+ c 1)) (+ a b)))
    //  iteration 0: a=1 b=2 c=0 → recur(b=2, a=1, 1) → a=2 b=1 c=1
    //  iteration 1: a=2 b=1 c=1 → else: a+b = 3
    // (Verifies the swap actually happens — without temps,
    // the second assignment would see the just-written a=2.)
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const c_plus_1: Tiny = .{ .add = .{ .lhs = &.{ .symbol = "c" }, .rhs = &.{ .int = 1 } } };
    const recur_form: Tiny = .{ .recur = .{ .args = &.{
        &.{ .symbol = "b" },
        &.{ .symbol = "a" },
        &c_plus_1,
    } } };
    const cond: Tiny = .{ .lt = .{ .lhs = &.{ .symbol = "c" }, .rhs = &.{ .int = 1 } } };
    const body: Tiny = .{ .if_ = .{
        .test_ = &cond,
        .then = &recur_form,
        .else_ = &.{ .add = .{ .lhs = &.{ .symbol = "a" }, .rhs = &.{ .symbol = "b" } } },
    } };
    const form: Tiny = .{ .loop_star = .{
        .bindings = &.{
            .{ .name = "a", .value = &.{ .int = 1 } },
            .{ .name = "b", .value = &.{ .int = 2 } },
            .{ .name = "c", .value = &.{ .int = 0 } },
        },
        .body = &body,
    } };
    const result = try runTiny(&arena, &form);
    try testing.expectEqual(@as(i64, 3), result.asFixnum());
}

test "compile: captured loop binding gets fresh cell per iteration" {
    // (loop* [i 0 f (fn* [] 999)]
    //   (if (< i 1)
    //     (recur (+ i 1) (fn* [] i))
    //     (f))) = 0
    //
    // Iteration 0: i=0, f=999-fn. Branch taken: build new fn
    //   capturing i=0, recur with i=1 and new fn.
    // Iteration 1: i=1, f=(fn [] i_from_iter0). Branch NOT
    //   taken: return (f).
    //
    // If recur mutated a single shared cell for i, (f) would
    // return 1. With fresh cells per iteration, (f) returns
    // the value of i AT CAPTURE TIME (= 0).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const i_plus_1: Tiny = .{ .add = .{ .lhs = &.{ .symbol = "i" }, .rhs = &.{ .int = 1 } } };
    const capture_fn: Tiny = .{ .fn_star = .{ .params = &.{}, .body = &.{ .symbol = "i" } } };
    const recur_form: Tiny = .{ .recur = .{ .args = &.{ &i_plus_1, &capture_fn } } };
    const cond: Tiny = .{ .lt = .{ .lhs = &.{ .symbol = "i" }, .rhs = &.{ .int = 1 } } };
    const f_call: Tiny = .{ .call = .{ .callee = &.{ .symbol = "f" }, .args = &.{} } };
    const body: Tiny = .{ .if_ = .{
        .test_ = &cond,
        .then = &recur_form,
        .else_ = &f_call,
    } };
    const initial_fn: Tiny = .{ .fn_star = .{ .params = &.{}, .body = &.{ .int = 999 } } };
    const form: Tiny = .{ .loop_star = .{
        .bindings = &.{
            .{ .name = "i", .value = &.{ .int = 0 } },
            .{ .name = "f", .value = &initial_fn },
        },
        .body = &body,
    } };
    const result = try runTiny(&arena, &form);
    try testing.expectEqual(@as(i64, 0), result.asFixnum());
}

test "compile fn-recur: fn* recur self-call — (fn* [n] (if (< n 5) (recur (+ n 1)) n)) called with 0 = 5" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const n_plus_1: Tiny = .{ .add = .{ .lhs = &.{ .symbol = "n" }, .rhs = &.{ .int = 1 } } };
    const recur_form: Tiny = .{ .recur = .{ .args = &.{&n_plus_1} } };
    const cond: Tiny = .{ .lt = .{ .lhs = &.{ .symbol = "n" }, .rhs = &.{ .int = 5 } } };
    const body: Tiny = .{ .if_ = .{
        .test_ = &cond,
        .then = &recur_form,
        .else_ = &.{ .symbol = "n" },
    } };
    const fn_form: Tiny = .{ .fn_star = .{ .params = &.{"n"}, .body = &body } };
    const call_form: Tiny = .{ .call = .{ .callee = &fn_form, .args = &.{&.{ .int = 0 }} } };
    const result = try runTiny(&arena, &call_form);
    try testing.expectEqual(@as(i64, 5), result.asFixnum());
}

test "compile fn-recur: nested fn* RESETS recur target (recur in inner fn targets inner, not outer loop)" {
    // (loop* [i 0]
    //   ((fn* [j] (if (< j 1) (recur (+ j 1)) (+ i j)))
    //    0))
    //  Inner fn: j=0 → recur(1) → j=1 → else → i+j = 0+1 = 1
    //  Outer loop never recurs (the inner recur targets the
    //  fn, not the loop). Result: 1.
    //
    // Critical correctness: if recur leaked outward to the
    // outer loop, this would loop forever (recur'ing i with
    // (+ j 1), then loop again).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const j_plus_1: Tiny = .{ .add = .{ .lhs = &.{ .symbol = "j" }, .rhs = &.{ .int = 1 } } };
    const recur_form: Tiny = .{ .recur = .{ .args = &.{&j_plus_1} } };
    const cond: Tiny = .{ .lt = .{ .lhs = &.{ .symbol = "j" }, .rhs = &.{ .int = 1 } } };
    const i_plus_j: Tiny = .{ .add = .{ .lhs = &.{ .symbol = "i" }, .rhs = &.{ .symbol = "j" } } };
    const inner_body: Tiny = .{ .if_ = .{
        .test_ = &cond,
        .then = &recur_form,
        .else_ = &i_plus_j,
    } };
    const inner_fn: Tiny = .{ .fn_star = .{ .params = &.{"j"}, .body = &inner_body } };
    const inner_call: Tiny = .{ .call = .{ .callee = &inner_fn, .args = &.{&.{ .int = 0 }} } };
    const outer: Tiny = .{ .loop_star = .{
        .bindings = &.{.{ .name = "i", .value = &.{ .int = 0 } }},
        .body = &inner_call,
    } };
    const result = try runTiny(&arena, &outer);
    try testing.expectEqual(@as(i64, 1), result.asFixnum());
}

test "compile loop: recur outside tail (in let RHS) → RecurOutsideTail" {
    // (loop* [i 0] (let* [x (recur 1)] x))
    // recur is in let-binding RHS, which is NON-tail.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const recur_form: Tiny = .{ .recur = .{ .args = &.{&.{ .int = 1 }} } };
    const inner_let: Tiny = .{ .let_star = .{
        .bindings = &.{.{ .name = "x", .value = &recur_form }},
        .body = &.{ .symbol = "x" },
    } };
    const loop_form: Tiny = .{ .loop_star = .{
        .bindings = &.{.{ .name = "i", .value = &.{ .int = 0 } }},
        .body = &inner_let,
    } };
    try testing.expectError(CompileError.RecurOutsideTail, compileTiny(arena.allocator(), &loop_form));
}

test "compile loop: recur outside any loop/fn → RecurOutsideTail" {
    // Top-level recur with no enclosing target.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const form: Tiny = .{ .recur = .{ .args = &.{} } };
    try testing.expectError(CompileError.RecurOutsideTail, compileTiny(arena.allocator(), &form));
}

test "compile loop: recur arity mismatch → RecurArityMismatch" {
    // (loop* [i 0] (recur 1 2)) — loop has 1 binding, recur gives 2 args.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const recur_form: Tiny = .{ .recur = .{ .args = &.{ &.{ .int = 1 }, &.{ .int = 2 } } } };
    const form: Tiny = .{ .loop_star = .{
        .bindings = &.{.{ .name = "i", .value = &.{ .int = 0 } }},
        .body = &recur_form,
    } };
    try testing.expectError(CompileError.RecurArityMismatch, compileTiny(arena.allocator(), &form));
}

test "compile fn-recur: fn* recur arity mismatch → RecurArityMismatch" {
    // (fn* [a b] (recur 1)) — fn has 2 params, recur gives 1 arg.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const recur_form: Tiny = .{ .recur = .{ .args = &.{&.{ .int = 1 }} } };
    const fn_form: Tiny = .{ .fn_star = .{ .params = &.{ "a", "b" }, .body = &recur_form } };
    try testing.expectError(CompileError.RecurArityMismatch, compileTiny(arena.allocator(), &fn_form));
}

test "compile loop: recur in (do non-last) is non-tail → RecurOutsideTail" {
    // (loop* [i 0] (do (recur 1) i))
    // recur is non-last in do → non-tail.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const recur_form: Tiny = .{ .recur = .{ .args = &.{&.{ .int = 1 }} } };
    const do_form: Tiny = .{ .do_ = &.{ &recur_form, &.{ .symbol = "i" } } };
    const form: Tiny = .{ .loop_star = .{
        .bindings = &.{.{ .name = "i", .value = &.{ .int = 0 } }},
        .body = &do_form,
    } };
    try testing.expectError(CompileError.RecurOutsideTail, compileTiny(arena.allocator(), &form));
}

test "compile loop: recur in (do last) IS tail position" {
    // (loop* [i 0] (do (if (< i 1) (recur (+ i 1)) i))) = 1
    // recur is inside (do (if ...)) — last of do, then-arm of
    // if, tail of loop body. All tail-inheriting → works.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const i_plus_1: Tiny = .{ .add = .{ .lhs = &.{ .symbol = "i" }, .rhs = &.{ .int = 1 } } };
    const recur_form: Tiny = .{ .recur = .{ .args = &.{&i_plus_1} } };
    const cond: Tiny = .{ .lt = .{ .lhs = &.{ .symbol = "i" }, .rhs = &.{ .int = 1 } } };
    const if_form: Tiny = .{ .if_ = .{
        .test_ = &cond,
        .then = &recur_form,
        .else_ = &.{ .symbol = "i" },
    } };
    const do_form: Tiny = .{ .do_ = &.{&if_form} };
    const form: Tiny = .{ .loop_star = .{
        .bindings = &.{.{ .name = "i", .value = &.{ .int = 0 } }},
        .body = &do_form,
    } };
    const result = try runTiny(&arena, &form);
    try testing.expectEqual(@as(i64, 1), result.asFixnum());
}

test "compile loop: loop* body can read outer let binding (lexical reference, not a closure capture)" {
    // (let* [x 100] (loop* [i 0] (if (< i 1) (recur (+ i x)) i))) = 100
    // No closure involved; just a
    // same-routine lexical reference to outer x from inside the
    // loop body. (Actual cross-routine capture goes through fn*.)
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const i_plus_x: Tiny = .{ .add = .{ .lhs = &.{ .symbol = "i" }, .rhs = &.{ .symbol = "x" } } };
    const recur_form: Tiny = .{ .recur = .{ .args = &.{&i_plus_x} } };
    const cond: Tiny = .{ .lt = .{ .lhs = &.{ .symbol = "i" }, .rhs = &.{ .int = 1 } } };
    const body: Tiny = .{ .if_ = .{
        .test_ = &cond,
        .then = &recur_form,
        .else_ = &.{ .symbol = "i" },
    } };
    const loop_form: Tiny = .{ .loop_star = .{
        .bindings = &.{.{ .name = "i", .value = &.{ .int = 0 } }},
        .body = &body,
    } };
    const outer: Tiny = .{ .let_star = .{
        .bindings = &.{.{ .name = "x", .value = &.{ .int = 100 } }},
        .body = &loop_form,
    } };
    const result = try runTiny(&arena, &outer);
    try testing.expectEqual(@as(i64, 100), result.asFixnum());
}

test "compile fn-recur: captured fn* param gets fresh cell across recur" {
    // ((fn* [i f]
    //    (if (< i 1)
    //      (recur (+ i 1) (fn* [] i))
    //      (f)))
    //  0
    //  (fn* [] 999)) = 0
    //
    // Symmetric to the loop* canonical fresh-cell test but for
    // fn* params. Validates compileFn's
    //   captured_mask[i] = captured_in_body.contains(p)
    // and that recur's fresh-cell pattern works against fn-target
    // bindings as well as loop-target bindings.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const i_plus_1: Tiny = .{ .add = .{ .lhs = &.{ .symbol = "i" }, .rhs = &.{ .int = 1 } } };
    const capture_fn: Tiny = .{ .fn_star = .{ .params = &.{}, .body = &.{ .symbol = "i" } } };
    const recur_form: Tiny = .{ .recur = .{ .args = &.{ &i_plus_1, &capture_fn } } };
    const cond: Tiny = .{ .lt = .{ .lhs = &.{ .symbol = "i" }, .rhs = &.{ .int = 1 } } };
    const f_call: Tiny = .{ .call = .{ .callee = &.{ .symbol = "f" }, .args = &.{} } };
    const body: Tiny = .{ .if_ = .{
        .test_ = &cond,
        .then = &recur_form,
        .else_ = &f_call,
    } };
    const fn_form: Tiny = .{ .fn_star = .{ .params = &.{ "i", "f" }, .body = &body } };
    const initial_fn: Tiny = .{ .fn_star = .{ .params = &.{}, .body = &.{ .int = 999 } } };
    const call_form: Tiny = .{ .call = .{ .callee = &fn_form, .args = &.{ &.{ .int = 0 }, &initial_fn } } };
    const result = try runTiny(&arena, &call_form);
    try testing.expectEqual(@as(i64, 0), result.asFixnum());
}

test "compile loop: letfn* body inherits enclosing loop's recur target" {
    // (loop* [i 0]
    //   (letfn* [(f [] 1)]
    //     (if (< i 1)
    //       (recur (+ i 1))
    //       i))) = 1
    // The recur sits inside letfn* body's if-then. letfn body
    // must propagate the outer loop's recur target so recur
    // can find it (letfn body inherits the target).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const i_plus_1: Tiny = .{ .add = .{ .lhs = &.{ .symbol = "i" }, .rhs = &.{ .int = 1 } } };
    const recur_form: Tiny = .{ .recur = .{ .args = &.{&i_plus_1} } };
    const cond: Tiny = .{ .lt = .{ .lhs = &.{ .symbol = "i" }, .rhs = &.{ .int = 1 } } };
    const inner_if: Tiny = .{ .if_ = .{
        .test_ = &cond,
        .then = &recur_form,
        .else_ = &.{ .symbol = "i" },
    } };
    const letfn: Tiny = .{ .letfn_star = .{
        .bindings = &.{.{ .name = "f", .params = &.{}, .body = &.{ .int = 1 } }},
        .body = &inner_if,
    } };
    const form: Tiny = .{ .loop_star = .{
        .bindings = &.{.{ .name = "i", .value = &.{ .int = 0 } }},
        .body = &letfn,
    } };
    const result = try runTiny(&arena, &form);
    try testing.expectEqual(@as(i64, 1), result.asFixnum());
}

test "compile fn-recur: recur inside letfn* fn body targets that fn (RESET at fn boundary)" {
    // (letfn* [(f [n] (if (< n 3) (recur (+ n 1)) n))] (f 0)) = 3
    // The recur inside f targets f's params (fresh fn RecurTarget
    // set up by compileFn called from compileLetFnStar), NOT any
    // outer target. f recurs 3 times then returns n=3.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const n_plus_1: Tiny = .{ .add = .{ .lhs = &.{ .symbol = "n" }, .rhs = &.{ .int = 1 } } };
    const recur_form: Tiny = .{ .recur = .{ .args = &.{&n_plus_1} } };
    const cond: Tiny = .{ .lt = .{ .lhs = &.{ .symbol = "n" }, .rhs = &.{ .int = 3 } } };
    const f_body: Tiny = .{ .if_ = .{
        .test_ = &cond,
        .then = &recur_form,
        .else_ = &.{ .symbol = "n" },
    } };
    const f_call: Tiny = .{ .call = .{ .callee = &.{ .symbol = "f" }, .args = &.{&.{ .int = 0 }} } };
    const form: Tiny = .{ .letfn_star = .{
        .bindings = &.{.{ .name = "f", .params = &.{"n"}, .body = &f_body }},
        .body = &f_call,
    } };
    const result = try runTiny(&arena, &form);
    try testing.expectEqual(@as(i64, 3), result.asFixnum());
}

test "compile loop: recur in if-test position → RecurOutsideTail" {
    // (loop* [i 0] (if (recur 1) i i))
    // recur is in if's TEST, which is non-tail.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const recur_form: Tiny = .{ .recur = .{ .args = &.{&.{ .int = 1 }} } };
    const if_form: Tiny = .{ .if_ = .{
        .test_ = &recur_form,
        .then = &.{ .symbol = "i" },
        .else_ = &.{ .symbol = "i" },
    } };
    const form: Tiny = .{ .loop_star = .{
        .bindings = &.{.{ .name = "i", .value = &.{ .int = 0 } }},
        .body = &if_form,
    } };
    try testing.expectError(CompileError.RecurOutsideTail, compileTiny(arena.allocator(), &form));
}

test "compile loop: recur in call-arg position → RecurOutsideTail" {
    // (loop* [i 0] ((fn* [x] x) (recur 1)))
    // recur is a call argument, which is non-tail.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const recur_form: Tiny = .{ .recur = .{ .args = &.{&.{ .int = 1 }} } };
    const id_fn: Tiny = .{ .fn_star = .{ .params = &.{"x"}, .body = &.{ .symbol = "x" } } };
    const call_form: Tiny = .{ .call = .{ .callee = &id_fn, .args = &.{&recur_form} } };
    const form: Tiny = .{ .loop_star = .{
        .bindings = &.{.{ .name = "i", .value = &.{ .int = 0 } }},
        .body = &call_form,
    } };
    try testing.expectError(CompileError.RecurOutsideTail, compileTiny(arena.allocator(), &form));
}

test "compile loop: nested loop* — inner recur targets inner loop only" {
    // (loop* [i 0]
    //   (loop* [j 0]
    //     (if (< j 1) (recur (+ j 1)) (+ i j))))
    // Inner recur rebinds j only. Inner loop iterates once,
    // exits with (+ i j) = 0+1 = 1. Outer loop never recurs.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const j_plus_1: Tiny = .{ .add = .{ .lhs = &.{ .symbol = "j" }, .rhs = &.{ .int = 1 } } };
    const recur_form: Tiny = .{ .recur = .{ .args = &.{&j_plus_1} } };
    const cond: Tiny = .{ .lt = .{ .lhs = &.{ .symbol = "j" }, .rhs = &.{ .int = 1 } } };
    const i_plus_j: Tiny = .{ .add = .{ .lhs = &.{ .symbol = "i" }, .rhs = &.{ .symbol = "j" } } };
    const inner_body: Tiny = .{ .if_ = .{
        .test_ = &cond,
        .then = &recur_form,
        .else_ = &i_plus_j,
    } };
    const inner: Tiny = .{ .loop_star = .{
        .bindings = &.{.{ .name = "j", .value = &.{ .int = 0 } }},
        .body = &inner_body,
    } };
    const outer: Tiny = .{ .loop_star = .{
        .bindings = &.{.{ .name = "i", .value = &.{ .int = 0 } }},
        .body = &inner,
    } };
    const result = try runTiny(&arena, &outer);
    try testing.expectEqual(@as(i64, 1), result.asFixnum());
}

// ---- variadic params (& rest) tests ----

test "compile variadic: ((fn* [a & r] a) 1 2 3) = 1 — rest collected but unused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fn_form: Tiny = .{ .fn_star = .{
        .params = &.{"a"},
        .rest_param = "r",
        .body = &.{ .symbol = "a" },
    } };
    const call_form: Tiny = .{ .call = .{
        .callee = &fn_form,
        .args = &.{ &.{ .int = 1 }, &.{ .int = 2 }, &.{ .int = 3 } },
    } };
    const result = try runTiny(&arena, &call_form);
    try testing.expectEqual(@as(i64, 1), result.asFixnum());
}

test "compile variadic: ((fn* [a & r] r) 1 2 3) returns list (2 3)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fn_form: Tiny = .{ .fn_star = .{
        .params = &.{"a"},
        .rest_param = "r",
        .body = &.{ .symbol = "r" },
    } };
    const call_form: Tiny = .{ .call = .{
        .callee = &fn_form,
        .args = &.{ &.{ .int = 1 }, &.{ .int = 2 }, &.{ .int = 3 } },
    } };
    const result = try runTiny(&arena, &call_form);
    try testing.expect(result.kind() == .list);
    try testing.expect(!list_mod.isEmpty(result));
    try testing.expectEqual(@as(usize, 2), list_mod.count(result));
    try testing.expectEqual(@as(i64, 2), list_mod.head(result).asFixnum());
    const tail = list_mod.tail(result);
    try testing.expectEqual(@as(i64, 3), list_mod.head(tail).asFixnum());
}

test "compile variadic: ((fn* [a & r] r) 1) returns empty list — argc == fixed_arity" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fn_form: Tiny = .{ .fn_star = .{
        .params = &.{"a"},
        .rest_param = "r",
        .body = &.{ .symbol = "r" },
    } };
    const call_form: Tiny = .{ .call = .{
        .callee = &fn_form,
        .args = &.{&.{ .int = 1 }},
    } };
    const result = try runTiny(&arena, &call_form);
    try testing.expect(result.kind() == .list);
    try testing.expect(list_mod.isEmpty(result));
    try testing.expectEqual(@as(usize, 0), list_mod.count(result));
}

test "compile variadic: ((fn* [& r] r) 1 2 3 4) — fixed_arity 0 variadic, all args to rest" {
    // Verifies element ORDER and contents, not just count:
    // list should be (1 2 3 4), not e.g.
    // reversed or with stale values.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fn_form: Tiny = .{ .fn_star = .{
        .params = &.{},
        .rest_param = "r",
        .body = &.{ .symbol = "r" },
    } };
    const call_form: Tiny = .{ .call = .{
        .callee = &fn_form,
        .args = &.{ &.{ .int = 1 }, &.{ .int = 2 }, &.{ .int = 3 }, &.{ .int = 4 } },
    } };
    const result = try runTiny(&arena, &call_form);
    try testing.expectEqual(@as(usize, 4), list_mod.count(result));
    var cur = result;
    var expected: i64 = 1;
    while (!list_mod.isEmpty(cur)) : (expected += 1) {
        try testing.expectEqual(expected, list_mod.head(cur).asFixnum());
        cur = list_mod.tail(cur);
    }
}

test "compile variadic: ((fn* [& r] r)) — fixed_arity 0 variadic, no args" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fn_form: Tiny = .{ .fn_star = .{
        .params = &.{},
        .rest_param = "r",
        .body = &.{ .symbol = "r" },
    } };
    const call_form: Tiny = .{ .call = .{ .callee = &fn_form, .args = &.{} } };
    const result = try runTiny(&arena, &call_form);
    try testing.expect(list_mod.isEmpty(result));
}

test "compile variadic: variadic with too few args traps :arity-mismatch at runtime" {
    // (fn* [a b & r] ...) requires >= 2 args; calling with 1
    // must trap.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fn_form: Tiny = .{ .fn_star = .{
        .params = &.{ "a", "b" },
        .rest_param = "r",
        .body = &.{ .symbol = "a" },
    } };
    const call_form: Tiny = .{ .call = .{
        .callee = &fn_form,
        .args = &.{&.{ .int = 1 }},
    } };
    const compiled = try compileTiny(arena.allocator(), &call_form);
    const routine = compiled.toRoutine("variadic-too-few");
    var v = try vm.VM.init(testing.allocator, &routine);
    defer v.deinit();
    try testing.expectError(vm.VmError.ArityMismatch, v.run());
}

test "compile variadic: variadic captured rest param survives across fn returns" {
    // (((fn* [a & r] (fn* [] r)) 1 2 3))
    // Outer fn captures r as upvalue of inner fn; inner returns
    // r. Result should be list (2 3) — verify CONTENTS, not
    // just count (a count check wouldn't catch
    // the "list of nils" hazard if it regressed).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const inner_fn: Tiny = .{ .fn_star = .{ .params = &.{}, .body = &.{ .symbol = "r" } } };
    const outer_fn: Tiny = .{ .fn_star = .{
        .params = &.{"a"},
        .rest_param = "r",
        .body = &inner_fn,
    } };
    const outer_call: Tiny = .{ .call = .{
        .callee = &outer_fn,
        .args = &.{ &.{ .int = 1 }, &.{ .int = 2 }, &.{ .int = 3 } },
    } };
    const inner_call: Tiny = .{ .call = .{ .callee = &outer_call, .args = &.{} } };
    const result = try runTiny(&arena, &inner_call);
    try testing.expect(result.kind() == .list);
    try testing.expectEqual(@as(usize, 2), list_mod.count(result));
    try testing.expectEqual(@as(i64, 2), list_mod.head(result).asFixnum());
    try testing.expectEqual(@as(i64, 3), list_mod.head(list_mod.tail(result)).asFixnum());
}

test "compile variadic: duplicate rest+fixed name → DuplicateParam" {
    // (fn* [a & a] a) — rest name shadows fixed param.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fn_form: Tiny = .{ .fn_star = .{
        .params = &.{"a"},
        .rest_param = "a",
        .body = &.{ .symbol = "a" },
    } };
    try testing.expectError(CompileError.DuplicateParam, compileTiny(arena.allocator(), &fn_form));
}

test "compile variadic: recur into a variadic fn rebinds the rest slot with its last argument" {
    // ((fn* [a & r] (if (< a 1) (recur (+ a 1) 42) r)) 0 7) → 42:
    // the recur count is fixed params + 1 and the last argument
    // lands in the rest slot as it is (COMPILER.md §5.6).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a_plus_1: Tiny = .{ .add = .{ .lhs = &.{ .symbol = "a" }, .rhs = &.{ .int = 1 } } };
    const recur_form: Tiny = .{ .recur = .{ .args = &.{ &a_plus_1, &.{ .int = 42 } } } };
    const cond: Tiny = .{ .lt = .{ .lhs = &.{ .symbol = "a" }, .rhs = &.{ .int = 1 } } };
    const body: Tiny = .{ .if_ = .{
        .test_ = &cond,
        .then = &recur_form,
        .else_ = &.{ .symbol = "r" },
    } };
    const fn_form: Tiny = .{ .fn_star = .{
        .params = &.{"a"},
        .rest_param = "r",
        .body = &body,
    } };
    const call_form: Tiny = .{ .call = .{ .callee = &fn_form, .args = &.{ &.{ .int = 0 }, &.{ .int = 7 } } } };
    const result = try runTiny(&arena, &call_form);
    try testing.expectEqual(@as(i64, 42), result.asFixnum());
}

test "compile variadic: a recur into a variadic fn that omits the rest argument is RecurArityMismatch" {
    // (fn* [a & r] (recur 1)) — the target has two bindings.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const recur_form: Tiny = .{ .recur = .{ .args = &.{&.{ .int = 1 }} } };
    const fn_form: Tiny = .{ .fn_star = .{
        .params = &.{"a"},
        .rest_param = "r",
        .body = &recur_form,
    } };
    try testing.expectError(CompileError.RecurArityMismatch, compileTiny(arena.allocator(), &fn_form));
}

test "compile variadic: recur in a non-variadic fn body rebinds the fixed params" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const n_plus_1: Tiny = .{ .add = .{ .lhs = &.{ .symbol = "n" }, .rhs = &.{ .int = 1 } } };
    const recur_form: Tiny = .{ .recur = .{ .args = &.{&n_plus_1} } };
    const cond: Tiny = .{ .lt = .{ .lhs = &.{ .symbol = "n" }, .rhs = &.{ .int = 3 } } };
    const body: Tiny = .{ .if_ = .{
        .test_ = &cond,
        .then = &recur_form,
        .else_ = &.{ .symbol = "n" },
    } };
    const fn_form: Tiny = .{ .fn_star = .{ .params = &.{"n"}, .body = &body } };
    const call_form: Tiny = .{ .call = .{ .callee = &fn_form, .args = &.{&.{ .int = 0 }} } };
    const result = try runTiny(&arena, &call_form);
    try testing.expectEqual(@as(i64, 3), result.asFixnum());
}

// ---- def + var + symbol fall-through tests ----

/// Helper: compile + run with a namespace owned by a VM.
/// Builds a stub VM (just to own the namespace), gets the
/// namespace, compiles with it, then patches the VM's top
/// frame to the real routine.
fn runTinyWithNs(
    arena: *std.heap.ArenaAllocator,
    form: *const Tiny,
) !value_mod.Value {
    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(arena.allocator(), &stub);
    defer detachHeapAndDeinit(&v);
    const ns = v.ensureNamespace();
    const compiled = try compileTinyWithNamespace(arena.allocator(), form, ns);
    const routine = compiled.toRoutine("test-with-ns");
    try v.retargetTop(&routine);
    return try v.run();
}

test "compile def: (def x 5) returns the Var object" {
    // Manage VM lifetime explicitly — the returned Var pointer
    // lives in vm.runtime_arena, so the VM must outlive the
    // Var-kind result inspection. (The runTinyWithNs helper
    // returns scalars after VM teardown, so it can't be used
    // for Var-kind results.)
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const form: Tiny = .{ .def = .{ .name = "x", .value = &.{ .int = 5 } } };

    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(testing.allocator, &stub);
    defer v.deinit();
    const ns = v.ensureNamespace();
    const compiled = try compileTinyWithNamespace(arena.allocator(), &form, ns);
    const routine = compiled.toRoutine("def-test");
    try v.retargetTop(&routine);
    const result = try v.run();

    try testing.expect(result.kind() == .var_);
    const var_obj = vm.VM.asVar(result);
    try testing.expect(var_obj.bound);
    try testing.expectEqual(@as(i64, 5), var_obj.root.asFixnum());
    try testing.expectEqualStrings("x", var_obj.name);
}

test "compile def: (do (def x 5) x) reads root via symbol fall-through" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const def_form: Tiny = .{ .def = .{ .name = "x", .value = &.{ .int = 5 } } };
    const form: Tiny = .{ .do_ = &.{ &def_form, &.{ .symbol = "x" } } };
    const result = try runTinyWithNs(&arena, &form);
    try testing.expect(result.isFixnum());
    try testing.expectEqual(@as(i64, 5), result.asFixnum());
}

test "compile def: (do (def x 5) (def x 10) x) — rebind preserves identity" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const def1: Tiny = .{ .def = .{ .name = "x", .value = &.{ .int = 5 } } };
    const def2: Tiny = .{ .def = .{ .name = "x", .value = &.{ .int = 10 } } };
    const form: Tiny = .{ .do_ = &.{ &def1, &def2, &.{ .symbol = "x" } } };
    const result = try runTinyWithNs(&arena, &form);
    try testing.expectEqual(@as(i64, 10), result.asFixnum());
}

test "compile def: (var x) returns the Var object (unbound OK)" {
    // Same lifetime pattern as the def test above.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const form: Tiny = .{ .var_ref = .{ .name = "unbound-yet" } };

    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(testing.allocator, &stub);
    defer v.deinit();
    const ns = v.ensureNamespace();
    const compiled = try compileTinyWithNamespace(arena.allocator(), &form, ns);
    const routine = compiled.toRoutine("var-ref-test");
    try v.retargetTop(&routine);
    const result = try v.run();

    try testing.expect(result.kind() == .var_);
    const var_obj = vm.VM.asVar(result);
    try testing.expect(!var_obj.bound);
    try testing.expectEqualStrings("unbound-yet", var_obj.name);
}

test "compile def: reading an unbound Var traps :unbound-var at runtime" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // No def; just reference unresolved symbol — compileSymbol
    // creates an unbound Var, var:load-var traps at runtime.
    const form: Tiny = .{ .symbol = "never-bound" };
    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(testing.allocator, &stub);
    defer v.deinit();
    const ns = v.ensureNamespace();
    const compiled = try compileTinyWithNamespace(arena.allocator(), &form, ns);
    const routine = compiled.toRoutine("unbound");
    try v.retargetTop(&routine);
    try testing.expectError(vm.VmError.UnboundVar, v.run());
}

test "compile def: without a namespace, unresolved symbol still raises UnresolvedSymbol" {
    // compileTiny (no namespace) keeps the lexical-only error
    // semantics.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const form: Tiny = .{ .symbol = "x" };
    try testing.expectError(CompileError.UnresolvedSymbol, compileTiny(arena.allocator(), &form));
}

test "compile def: without a namespace, def raises UnresolvedSymbol" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const form: Tiny = .{ .def = .{ .name = "x", .value = &.{ .int = 5 } } };
    try testing.expectError(CompileError.UnresolvedSymbol, compileTiny(arena.allocator(), &form));
}

test "compile def: lexical local shadows namespace Var" {
    // (def x 100)
    // (let* [x 5] x) = 5 — not 100
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const def_form: Tiny = .{ .def = .{ .name = "x", .value = &.{ .int = 100 } } };
    const let_form: Tiny = .{ .let_star = .{
        .bindings = &.{.{ .name = "x", .value = &.{ .int = 5 } }},
        .body = &.{ .symbol = "x" },
    } };
    const form: Tiny = .{ .do_ = &.{ &def_form, &let_form } };
    const result = try runTinyWithNs(&arena, &form);
    try testing.expectEqual(@as(i64, 5), result.asFixnum());
}

test "compile def: same Var referenced multiple times shares one var_table index (dedup)" {
    // (do (def x 5) (+ x x)) should produce only ONE
    // var_table entry. Hard to assert directly without
    // inspecting Compiled.var_table.len, but easy via the
    // helper compileTinyWithNamespace.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(testing.allocator, &stub);
    defer v.deinit();
    const ns = v.ensureNamespace();
    const def_form: Tiny = .{ .def = .{ .name = "x", .value = &.{ .int = 5 } } };
    const add_form: Tiny = .{ .add = .{ .lhs = &.{ .symbol = "x" }, .rhs = &.{ .symbol = "x" } } };
    const form: Tiny = .{ .do_ = &.{ &def_form, &add_form } };
    const compiled = try compileTinyWithNamespace(arena.allocator(), &form, ns);
    // x appears in def + 2 symbol refs = same Var, 1 var_table entry.
    try testing.expectEqual(@as(usize, 1), compiled.var_table.len);
}

// ---- defn + forward references tests ----

test "compile defn: (do (defn add1 [n] (+ n 1)) (add1 5)) = 6" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body: Tiny = .{ .add = .{ .lhs = &.{ .symbol = "n" }, .rhs = &.{ .int = 1 } } };
    const defn_form: Tiny = .{ .defn = .{
        .name = "add1",
        .params = &.{"n"},
        .body = &body,
    } };
    const call_form: Tiny = .{ .call = .{
        .callee = &.{ .symbol = "add1" },
        .args = &.{&.{ .int = 5 }},
    } };
    const form: Tiny = .{ .do_ = &.{ &defn_form, &call_form } };
    const result = try runTinyWithNs(&arena, &form);
    try testing.expectEqual(@as(i64, 6), result.asFixnum());
}

test "compile defn: (do (defn zero [] 0) (zero)) = 0 — nullary defn" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const defn_form: Tiny = .{ .defn = .{
        .name = "zero",
        .params = &.{},
        .body = &.{ .int = 0 },
    } };
    const call_form: Tiny = .{ .call = .{ .callee = &.{ .symbol = "zero" }, .args = &.{} } };
    const form: Tiny = .{ .do_ = &.{ &defn_form, &call_form } };
    const result = try runTinyWithNs(&arena, &form);
    try testing.expectEqual(@as(i64, 0), result.asFixnum());
}

test "compile defn: defn supports recur for self-call (named fn* under the hood)" {
    // (do (defn loop-down [n]
    //       (if (< n 1) n (recur (+ n -1))))
    //     (loop-down 5)) = 0
    // Verifies that defn's lowering correctly threads the named-
    // fn* path so recur in the body targets the function.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const neg1: Tiny = .{ .add = .{ .lhs = &.{ .symbol = "n" }, .rhs = &.{ .int = -1 } } };
    const recur_form: Tiny = .{ .recur = .{ .args = &.{&neg1} } };
    const cond: Tiny = .{ .lt = .{ .lhs = &.{ .symbol = "n" }, .rhs = &.{ .int = 1 } } };
    const body: Tiny = .{ .if_ = .{
        .test_ = &cond,
        .then = &.{ .symbol = "n" },
        .else_ = &recur_form,
    } };
    const defn_form: Tiny = .{ .defn = .{
        .name = "loop-down",
        .params = &.{"n"},
        .body = &body,
    } };
    const call_form: Tiny = .{ .call = .{
        .callee = &.{ .symbol = "loop-down" },
        .args = &.{&.{ .int = 5 }},
    } };
    const form: Tiny = .{ .do_ = &.{ &defn_form, &call_form } };
    const result = try runTinyWithNs(&arena, &form);
    try testing.expectEqual(@as(i64, 0), result.asFixnum());
}

test "compile defn: forward reference — defn f calls g defined later" {
    // (do (defn f [] (g))
    //     (defn g [] 42)
    //     (f)) = 42
    // f compiles when g is still unbound (Var interned by
    // symbol fall-through). At call time g is bound; load-var
    // returns the closure; call succeeds.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f_body: Tiny = .{ .call = .{ .callee = &.{ .symbol = "g" }, .args = &.{} } };
    const f_defn: Tiny = .{ .defn = .{ .name = "f", .params = &.{}, .body = &f_body } };
    const g_defn: Tiny = .{ .defn = .{ .name = "g", .params = &.{}, .body = &.{ .int = 42 } } };
    const f_call: Tiny = .{ .call = .{ .callee = &.{ .symbol = "f" }, .args = &.{} } };
    const form: Tiny = .{ .do_ = &.{ &f_defn, &g_defn, &f_call } };
    const result = try runTinyWithNs(&arena, &form);
    try testing.expectEqual(@as(i64, 42), result.asFixnum());
}

test "compile defn: forward reference + call before bind → UnboundVar trap" {
    // (do (defn f [] (g))
    //     (f))                ;; g never defined
    // f compiles (g's Var interned unbound), but invoking f
    // tries to load g's root → :unbound-var.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f_body: Tiny = .{ .call = .{ .callee = &.{ .symbol = "g" }, .args = &.{} } };
    const f_defn: Tiny = .{ .defn = .{ .name = "f", .params = &.{}, .body = &f_body } };
    const f_call: Tiny = .{ .call = .{ .callee = &.{ .symbol = "f" }, .args = &.{} } };
    const form: Tiny = .{ .do_ = &.{ &f_defn, &f_call } };

    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(testing.allocator, &stub);
    defer v.deinit();
    const ns = v.ensureNamespace();
    const compiled = try compileTinyWithNamespace(arena.allocator(), &form, ns);
    const routine = compiled.toRoutine("unbound-fwd");
    try v.retargetTop(&routine);
    try testing.expectError(vm.VmError.UnboundVar, v.run());
}

test "compile defn: defn rebinding preserves Var identity" {
    // (do (defn f [] 1)
    //     (defn f [] 2)
    //     (f)) = 2
    // Like (def x 5) (def x 10) but via defn — same Var
    // rebound, callers see the new value.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f1: Tiny = .{ .defn = .{ .name = "f", .params = &.{}, .body = &.{ .int = 1 } } };
    const f2: Tiny = .{ .defn = .{ .name = "f", .params = &.{}, .body = &.{ .int = 2 } } };
    const f_call: Tiny = .{ .call = .{ .callee = &.{ .symbol = "f" }, .args = &.{} } };
    const form: Tiny = .{ .do_ = &.{ &f1, &f2, &f_call } };
    const result = try runTinyWithNs(&arena, &form);
    try testing.expectEqual(@as(i64, 2), result.asFixnum());
}

test "compile defn: defn with rest param works end-to-end" {
    // (do (defn first-of [a & r] a)
    //     (first-of 7 99 100)) = 7
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const defn_form: Tiny = .{ .defn = .{
        .name = "first-of",
        .params = &.{"a"},
        .rest_param = "r",
        .body = &.{ .symbol = "a" },
    } };
    const call_form: Tiny = .{ .call = .{
        .callee = &.{ .symbol = "first-of" },
        .args = &.{ &.{ .int = 7 }, &.{ .int = 99 }, &.{ .int = 100 } },
    } };
    const form: Tiny = .{ .do_ = &.{ &defn_form, &call_form } };
    const result = try runTinyWithNs(&arena, &form);
    try testing.expectEqual(@as(i64, 7), result.asFixnum());
}

// ---- if-form tests ----

test "compile: (if true 1 2) = 1" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try runTiny(&arena, &.{ .if_ = .{
        .test_ = &.{ .bool = true },
        .then = &.{ .int = 1 },
        .else_ = &.{ .int = 2 },
    } });
    try testing.expectEqual(@as(i64, 1), result.asFixnum());
}

test "compile: (if false 1 2) = 2" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try runTiny(&arena, &.{ .if_ = .{
        .test_ = &.{ .bool = false },
        .then = &.{ .int = 1 },
        .else_ = &.{ .int = 2 },
    } });
    try testing.expectEqual(@as(i64, 2), result.asFixnum());
}

test "compile: (if nil 1 2) = 2" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try runTiny(&arena, &.{ .if_ = .{
        .test_ = &.{ .nil = {} },
        .then = &.{ .int = 1 },
        .else_ = &.{ .int = 2 },
    } });
    try testing.expectEqual(@as(i64, 2), result.asFixnum());
}

test "compile: (if 0 1 2) = 1 — PLAN §6.2 surprise: 0 is truthy" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try runTiny(&arena, &.{ .if_ = .{
        .test_ = &.{ .int = 0 },
        .then = &.{ .int = 1 },
        .else_ = &.{ .int = 2 },
    } });
    try testing.expectEqual(@as(i64, 1), result.asFixnum());
}

test "compile: (if false 1) — absent else returns nil" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try runTiny(&arena, &.{ .if_ = .{
        .test_ = &.{ .bool = false },
        .then = &.{ .int = 1 },
        .else_ = null,
    } });
    try testing.expect(result.kind() == .nil);
}

test "compile: (if true 1) — absent else, then-branch taken" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try runTiny(&arena, &.{ .if_ = .{
        .test_ = &.{ .bool = true },
        .then = &.{ .int = 1 },
        .else_ = null,
    } });
    try testing.expectEqual(@as(i64, 1), result.asFixnum());
}

test "compile: (if true (+ 1 2) (+ 3 4)) = 3 — arms with sub-expressions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try runTiny(&arena, &.{ .if_ = .{
        .test_ = &.{ .bool = true },
        .then = &.{ .add = .{ .lhs = &.{ .int = 1 }, .rhs = &.{ .int = 2 } } },
        .else_ = &.{ .add = .{ .lhs = &.{ .int = 3 }, .rhs = &.{ .int = 4 } } },
    } });
    try testing.expectEqual(@as(i64, 3), result.asFixnum());
}

test "compile: (if false (+ 1 2) (+ 3 4)) = 7" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try runTiny(&arena, &.{ .if_ = .{
        .test_ = &.{ .bool = false },
        .then = &.{ .add = .{ .lhs = &.{ .int = 1 }, .rhs = &.{ .int = 2 } } },
        .else_ = &.{ .add = .{ .lhs = &.{ .int = 3 }, .rhs = &.{ .int = 4 } } },
    } });
    try testing.expectEqual(@as(i64, 7), result.asFixnum());
}

test "compile: nested if (if true (if false 1 2) 3) = 2" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const inner: Tiny = .{ .if_ = .{
        .test_ = &.{ .bool = false },
        .then = &.{ .int = 1 },
        .else_ = &.{ .int = 2 },
    } };
    const outer: Tiny = .{ .if_ = .{
        .test_ = &.{ .bool = true },
        .then = &inner,
        .else_ = &.{ .int = 3 },
    } };
    const result = try runTiny(&arena, &outer);
    try testing.expectEqual(@as(i64, 2), result.asFixnum());
}

test "compile: (if (+ 1 2) 'truthy 'falsy) — test is a non-trivial expression" {
    // The result of (+ 1 2) is fixnum 3, which is truthy → return
    // a marker that's distinguishable from the alt branch.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try runTiny(&arena, &.{ .if_ = .{
        .test_ = &.{ .add = .{ .lhs = &.{ .int = 1 }, .rhs = &.{ .int = 2 } } },
        .then = &.{ .int = 99 },
        .else_ = &.{ .int = -1 },
    } });
    try testing.expectEqual(@as(i64, 99), result.asFixnum());
}

// ---- symbol / let* / do tests ----

test "compile: bare unresolved symbol surfaces UnresolvedSymbol" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const res = compileTiny(arena.allocator(), &.{ .symbol = "x" });
    try testing.expectError(CompileError.UnresolvedSymbol, res);
}

test "compile: (let* [x 1] x) = 1" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try runTiny(&arena, &.{ .let_star = .{
        .bindings = &.{.{ .name = "x", .value = &.{ .int = 1 } }},
        .body = &.{ .symbol = "x" },
    } });
    try testing.expectEqual(@as(i64, 1), result.asFixnum());
}

test "compile: (let* [x 1 y 2] (+ x y)) = 3" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try runTiny(&arena, &.{ .let_star = .{
        .bindings = &.{
            .{ .name = "x", .value = &.{ .int = 1 } },
            .{ .name = "y", .value = &.{ .int = 2 } },
        },
        .body = &.{ .add = .{ .lhs = &.{ .symbol = "x" }, .rhs = &.{ .symbol = "y" } } },
    } });
    try testing.expectEqual(@as(i64, 3), result.asFixnum());
}

test "compile: (let* [x 1 y x] y) = 1 — sequential RHS sees prior binding" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try runTiny(&arena, &.{ .let_star = .{
        .bindings = &.{
            .{ .name = "x", .value = &.{ .int = 1 } },
            .{ .name = "y", .value = &.{ .symbol = "x" } },
        },
        .body = &.{ .symbol = "y" },
    } });
    try testing.expectEqual(@as(i64, 1), result.asFixnum());
}

test "compile: (let* [x x] x) — RHS does NOT see own LHS, no outer x → UnresolvedSymbol" {
    // Per COMPILER.md §4.3 amendment: binding-i's RHS sees
    // bindings 1..i-1 only, not its own LHS. Without an outer
    // x in scope, the RHS reference is unresolved.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const res = compileTiny(arena.allocator(), &.{ .let_star = .{
        .bindings = &.{.{ .name = "x", .value = &.{ .symbol = "x" } }},
        .body = &.{ .symbol = "x" },
    } });
    try testing.expectError(CompileError.UnresolvedSymbol, res);
}

test "compile: (let* [x 7] (let* [x x] x)) = 7 — self-shadow sees outer" {
    // The inner [x x] reads outer-x for its RHS, then shadows.
    // The body x reads the inner binding.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const inner: Tiny = .{ .let_star = .{
        .bindings = &.{.{ .name = "x", .value = &.{ .symbol = "x" } }},
        .body = &.{ .symbol = "x" },
    } };
    const outer: Tiny = .{ .let_star = .{
        .bindings = &.{.{ .name = "x", .value = &.{ .int = 7 } }},
        .body = &inner,
    } };
    const result = try runTiny(&arena, &outer);
    try testing.expectEqual(@as(i64, 7), result.asFixnum());
}

test "compile: (let* [x 1 x 2] x) = 2 — duplicate name shadows in same let*" {
    // Per COMPILER.md §4.3: NOT a :duplicate-binding (that's
    // for parameter lists only). The second binding shadows
    // the first from binding-2 onward + body.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try runTiny(&arena, &.{ .let_star = .{
        .bindings = &.{
            .{ .name = "x", .value = &.{ .int = 1 } },
            .{ .name = "x", .value = &.{ .int = 2 } },
        },
        .body = &.{ .symbol = "x" },
    } });
    try testing.expectEqual(@as(i64, 2), result.asFixnum());
}

test "compile: nested let — inner shadow doesn't pollute outer scope after exit" {
    // (let* [x 1] (do (let* [x 2] x) x)) → outer let-body's
    // last form `x` resolves to outer x = 1, NOT inner-x = 2.
    // Tests that the `defer scope.shrinkRetainingCapacity` pop
    // correctly restores scope after the inner let exits.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const inner_let: Tiny = .{ .let_star = .{
        .bindings = &.{.{ .name = "x", .value = &.{ .int = 2 } }},
        .body = &.{ .symbol = "x" },
    } };
    const body: Tiny = .{ .do_ = &.{ &inner_let, &.{ .symbol = "x" } } };
    const outer: Tiny = .{ .let_star = .{
        .bindings = &.{.{ .name = "x", .value = &.{ .int = 1 } }},
        .body = &body,
    } };
    const result = try runTiny(&arena, &outer);
    try testing.expectEqual(@as(i64, 1), result.asFixnum());
}

test "compile: empty (do) = nil" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try runTiny(&arena, &.{ .do_ = &.{} });
    try testing.expect(result.kind() == .nil);
}

test "compile: single-expression (do x) = x" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try runTiny(&arena, &.{ .do_ = &.{&.{ .int = 42 }} });
    try testing.expectEqual(@as(i64, 42), result.asFixnum());
}

test "compile: (do 1 2 3) = 3 — yields last expression" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try runTiny(&arena, &.{ .do_ = &.{
        &.{ .int = 1 },
        &.{ .int = 2 },
        &.{ .int = 3 },
    } });
    try testing.expectEqual(@as(i64, 3), result.asFixnum());
}

test "compile: do sees enclosing let bindings" {
    // (let* [x 4] (do 1 x)) → 4
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body: Tiny = .{ .do_ = &.{ &.{ .int = 1 }, &.{ .symbol = "x" } } };
    const form: Tiny = .{ .let_star = .{
        .bindings = &.{.{ .name = "x", .value = &.{ .int = 4 } }},
        .body = &body,
    } };
    const result = try runTiny(&arena, &form);
    try testing.expectEqual(@as(i64, 4), result.asFixnum());
}

test "compile: let inside if-arm: (if true (let* [x 1] x) 2) = 1" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const then_arm: Tiny = .{ .let_star = .{
        .bindings = &.{.{ .name = "x", .value = &.{ .int = 1 } }},
        .body = &.{ .symbol = "x" },
    } };
    const result = try runTiny(&arena, &.{ .if_ = .{
        .test_ = &.{ .bool = true },
        .then = &then_arm,
        .else_ = &.{ .int = 2 },
    } });
    try testing.expectEqual(@as(i64, 1), result.asFixnum());
}

test "compile: if inside let RHS: (let* [x (if false 1 2)] x) = 2" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rhs: Tiny = .{ .if_ = .{
        .test_ = &.{ .bool = false },
        .then = &.{ .int = 1 },
        .else_ = &.{ .int = 2 },
    } };
    const result = try runTiny(&arena, &.{ .let_star = .{
        .bindings = &.{.{ .name = "x", .value = &rhs }},
        .body = &.{ .symbol = "x" },
    } });
    try testing.expectEqual(@as(i64, 2), result.asFixnum());
}

test "compile: (do unresolved 1) — non-last expressions still compile" {
    // Pins that non-last do expressions are compiled even
    // though their values are discarded.
    // Discarded value ≠ discarded compilation:
    // the side effects of compiling/executing must still occur.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const res = compileTiny(arena.allocator(), &.{ .do_ = &.{
        &.{ .symbol = "missing" },
        &.{ .int = 1 },
    } });
    try testing.expectError(CompileError.UnresolvedSymbol, res);
}

test "compile: nested let with sequential RHS sees inner shadow, not outer" {
    // (let* [x 1] (let* [x 2, y x] y)) → 2
    // Composition of: outer x = 1, inner-let shadows with x = 2,
    // inner-let-binding y's RHS sees the SHADOWED x = 2 (not
    // the outer x = 1). Test pins the interaction of nested
    // scope + sequential RHS visibility.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const inner: Tiny = .{ .let_star = .{
        .bindings = &.{
            .{ .name = "x", .value = &.{ .int = 2 } },
            .{ .name = "y", .value = &.{ .symbol = "x" } },
        },
        .body = &.{ .symbol = "y" },
    } };
    const outer: Tiny = .{ .let_star = .{
        .bindings = &.{.{ .name = "x", .value = &.{ .int = 1 } }},
        .body = &inner,
    } };
    const result = try runTiny(&arena, &outer);
    try testing.expectEqual(@as(i64, 2), result.asFixnum());
}

test "compile: scope restored after compile error" {
    // Compile a let* whose body is unresolvable. Then compile
    // another (different) form that should NOT see leaked
    // scope from the failed compile.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const failing: Tiny = .{
        .let_star = .{
            .bindings = &.{.{ .name = "x", .value = &.{ .int = 1 } }},
            .body = &.{ .symbol = "y" }, // y is unbound → error
        },
    };
    const res1 = compileTiny(arena.allocator(), &failing);
    try testing.expectError(CompileError.UnresolvedSymbol, res1);
    // The scope should not have leaked `x`. A fresh compile
    // referencing `x` should still fail.
    const res2 = compileTiny(arena.allocator(), &.{ .symbol = "x" });
    try testing.expectError(CompileError.UnresolvedSymbol, res2);
}

// ---- fn* + call tests ----

test "compile fn*: ((fn* [] 42)) = 42" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fn_form: Tiny = .{ .fn_star = .{ .params = &.{}, .body = &.{ .int = 42 } } };
    const result = try runTiny(&arena, &.{ .call = .{ .callee = &fn_form, .args = &.{} } });
    try testing.expectEqual(@as(i64, 42), result.asFixnum());
}

test "compile fn*: ((fn* [x] (+ x 1)) 5) = 6" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body: Tiny = .{ .add = .{ .lhs = &.{ .symbol = "x" }, .rhs = &.{ .int = 1 } } };
    const fn_form: Tiny = .{ .fn_star = .{ .params = &.{"x"}, .body = &body } };
    const call_form: Tiny = .{ .call = .{ .callee = &fn_form, .args = &.{&.{ .int = 5 }} } };
    const result = try runTiny(&arena, &call_form);
    try testing.expectEqual(@as(i64, 6), result.asFixnum());
}

test "compile fn*: ((fn* [x y] (+ x y)) 3 4) = 7" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body: Tiny = .{ .add = .{ .lhs = &.{ .symbol = "x" }, .rhs = &.{ .symbol = "y" } } };
    const fn_form: Tiny = .{ .fn_star = .{ .params = &.{ "x", "y" }, .body = &body } };
    const call_form: Tiny = .{ .call = .{
        .callee = &fn_form,
        .args = &.{ &.{ .int = 3 }, &.{ .int = 4 } },
    } };
    const result = try runTiny(&arena, &call_form);
    try testing.expectEqual(@as(i64, 7), result.asFixnum());
}

test "compile fn*: (let* [f (fn* [x] (+ x 1))] (f 5)) = 6 — fn bound in let" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body: Tiny = .{ .add = .{ .lhs = &.{ .symbol = "x" }, .rhs = &.{ .int = 1 } } };
    const fn_form: Tiny = .{ .fn_star = .{ .params = &.{"x"}, .body = &body } };
    const call_form: Tiny = .{ .call = .{
        .callee = &.{ .symbol = "f" },
        .args = &.{&.{ .int = 5 }},
    } };
    const let_form: Tiny = .{ .let_star = .{
        .bindings = &.{.{ .name = "f", .value = &fn_form }},
        .body = &call_form,
    } };
    const result = try runTiny(&arena, &let_form);
    try testing.expectEqual(@as(i64, 6), result.asFixnum());
}

test "compile capture: (let* [x 5] ((fn* [y] x) 3)) = 5 — single capture" {
    // The canonical hand-trace example. Outer x = 5 is
    // captured by the inner fn body: pre-analysis boxes x in
    // the let* prelude; compileSymbol for `x` inside the fn
    // body walks to the parent, registers the capture source,
    // and returns BindingRef.upvalue(0). The fn body emits
    // `mov:move dst, u:0` which deref's the cell at runtime.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const inner_body: Tiny = .{ .symbol = "x" };
    const inner_fn: Tiny = .{ .fn_star = .{ .params = &.{"y"}, .body = &inner_body } };
    const call_form: Tiny = .{ .call = .{ .callee = &inner_fn, .args = &.{&.{ .int = 3 }} } };
    const let_form: Tiny = .{ .let_star = .{
        .bindings = &.{.{ .name = "x", .value = &.{ .int = 5 } }},
        .body = &call_form,
    } };
    const result = try runTiny(&arena, &let_form);
    try testing.expectEqual(@as(i64, 5), result.asFixnum());
}

test "compile fn*: nested call ((fn* [x] x) ((fn* [y] (+ y 1)) 4)) = 5" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const inner_body: Tiny = .{ .add = .{ .lhs = &.{ .symbol = "y" }, .rhs = &.{ .int = 1 } } };
    const inner_fn: Tiny = .{ .fn_star = .{ .params = &.{"y"}, .body = &inner_body } };
    const inner_call: Tiny = .{ .call = .{ .callee = &inner_fn, .args = &.{&.{ .int = 4 }} } };
    const outer_fn: Tiny = .{ .fn_star = .{ .params = &.{"x"}, .body = &.{ .symbol = "x" } } };
    const outer_call: Tiny = .{ .call = .{ .callee = &outer_fn, .args = &.{&inner_call} } };
    const result = try runTiny(&arena, &outer_call);
    try testing.expectEqual(@as(i64, 5), result.asFixnum());
}

test "compile fn*: duplicate param (fn* [x x] x) → DuplicateParam" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fn_form: Tiny = .{ .fn_star = .{
        .params = &.{ "x", "x" },
        .body = &.{ .symbol = "x" },
    } };
    const res = compileTiny(arena.allocator(), &fn_form);
    try testing.expectError(CompileError.DuplicateParam, res);
}

test "compile fn*: arity mismatch — call with too few args traps :arity-mismatch at runtime" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fn_form: Tiny = .{ .fn_star = .{
        .params = &.{ "x", "y" },
        .body = &.{ .symbol = "x" },
    } };
    const call_form: Tiny = .{
        .call = .{
            .callee = &fn_form,
            .args = &.{&.{ .int = 1 }}, // only 1 arg, fn expects 2
        },
    };
    const compiled = try compileTiny(arena.allocator(), &call_form);
    const routine = compiled.toRoutine("arity-test");
    var v = try vm.VM.init(testing.allocator, &routine);
    defer v.deinit();
    const res = v.run();
    try testing.expectError(vm.VmError.ArityMismatch, res);
}

test "compile fn*: same closure called twice — both invocations succeed" {
    // (let* [f (fn* [x] (+ x 1))] (+ (f 5) (f 10))) = 6 + 11 = 17
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body: Tiny = .{ .add = .{ .lhs = &.{ .symbol = "x" }, .rhs = &.{ .int = 1 } } };
    const fn_form: Tiny = .{ .fn_star = .{ .params = &.{"x"}, .body = &body } };
    const call1: Tiny = .{ .call = .{ .callee = &.{ .symbol = "f" }, .args = &.{&.{ .int = 5 }} } };
    const call2: Tiny = .{ .call = .{ .callee = &.{ .symbol = "f" }, .args = &.{&.{ .int = 10 }} } };
    const sum: Tiny = .{ .add = .{ .lhs = &call1, .rhs = &call2 } };
    const let_form: Tiny = .{ .let_star = .{
        .bindings = &.{.{ .name = "f", .value = &fn_form }},
        .body = &sum,
    } };
    const result = try runTiny(&arena, &let_form);
    try testing.expectEqual(@as(i64, 17), result.asFixnum());
}

test "compile fn*: fn body uses if + symbol — no captures needed" {
    // ((fn* [x] (if true x 0)) 7) = 7
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body: Tiny = .{ .if_ = .{
        .test_ = &.{ .bool = true },
        .then = &.{ .symbol = "x" },
        .else_ = &.{ .int = 0 },
    } };
    const fn_form: Tiny = .{ .fn_star = .{ .params = &.{"x"}, .body = &body } };
    const call_form: Tiny = .{ .call = .{ .callee = &fn_form, .args = &.{&.{ .int = 7 }} } };
    const result = try runTiny(&arena, &call_form);
    try testing.expectEqual(@as(i64, 7), result.asFixnum());
}

// ---- capture machinery tests ----

test "compile capture: (let* [x 5] ((fn* [y] (+ x y)) 3)) = 8 — capture + use" {
    // x is captured, y is a param, body adds them.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body: Tiny = .{ .add = .{ .lhs = &.{ .symbol = "x" }, .rhs = &.{ .symbol = "y" } } };
    const fn_form: Tiny = .{ .fn_star = .{ .params = &.{"y"}, .body = &body } };
    const call_form: Tiny = .{ .call = .{ .callee = &fn_form, .args = &.{&.{ .int = 3 }} } };
    const let_form: Tiny = .{ .let_star = .{
        .bindings = &.{.{ .name = "x", .value = &.{ .int = 5 } }},
        .body = &call_form,
    } };
    const result = try runTiny(&arena, &let_form);
    try testing.expectEqual(@as(i64, 8), result.asFixnum());
}

test "compile capture: (let* [x 5 y 10] ((fn* [] (+ x y)))) = 15 — multi-capture" {
    // Two bindings, both captured by the inner fn body.
    // Each goes through ensureBoxed independently; child's
    // capture descriptor gets two local_cell_slot sources.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body: Tiny = .{ .add = .{ .lhs = &.{ .symbol = "x" }, .rhs = &.{ .symbol = "y" } } };
    const fn_form: Tiny = .{ .fn_star = .{ .params = &.{}, .body = &body } };
    const call_form: Tiny = .{ .call = .{ .callee = &fn_form, .args = &.{} } };
    const let_form: Tiny = .{ .let_star = .{
        .bindings = &.{
            .{ .name = "x", .value = &.{ .int = 5 } },
            .{ .name = "y", .value = &.{ .int = 10 } },
        },
        .body = &call_form,
    } };
    const result = try runTiny(&arena, &let_form);
    try testing.expectEqual(@as(i64, 15), result.asFixnum());
}

test "compile capture: (let* [x 5] (let* [f (fn* [] x)] (f))) = 5 — let-bound captured fn" {
    // Captured fn stored in a let binding, then called by name.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fn_form: Tiny = .{ .fn_star = .{ .params = &.{}, .body = &.{ .symbol = "x" } } };
    const inner_call: Tiny = .{ .call = .{ .callee = &.{ .symbol = "f" }, .args = &.{} } };
    const inner_let: Tiny = .{ .let_star = .{
        .bindings = &.{.{ .name = "f", .value = &fn_form }},
        .body = &inner_call,
    } };
    const outer_let: Tiny = .{ .let_star = .{
        .bindings = &.{.{ .name = "x", .value = &.{ .int = 5 } }},
        .body = &inner_let,
    } };
    const result = try runTiny(&arena, &outer_let);
    try testing.expectEqual(@as(i64, 5), result.asFixnum());
}

test "compile capture: (let* [x 5] ((fn* [] ((fn* [] x))))) = 5 — transitive capture" {
    // Inner-inner fn captures x. Middle fn doesn't reference
    // x directly but MUST capture it so that the closure:make
    // for the inner-inner fn (which runs inside middle fn's
    // frame) has a cell for x.
    //
    // Resolution chain:
    //   inner-inner-fn sees x → walk to middle
    //   middle has no x in local scope → walk to outer
    //   outer has x as direct_slot → ensureBoxed on outer, mutate
    //                                 to cell_slot
    //   middle registers a capture (source = local_cell_slot in
    //                                outer's frame)
    //   middle pushes x as upvalue(0) into its own scope
    //   inner-inner registers a capture (source =
    //                                inherited_upvalue(0))
    //   inner-inner pushes x as upvalue(0) into its own scope
    //   inner-inner body emits mov:move dst, u:0
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const innermost_fn: Tiny = .{ .fn_star = .{ .params = &.{}, .body = &.{ .symbol = "x" } } };
    const innermost_call: Tiny = .{ .call = .{ .callee = &innermost_fn, .args = &.{} } };
    const middle_fn: Tiny = .{ .fn_star = .{ .params = &.{}, .body = &innermost_call } };
    const middle_call: Tiny = .{ .call = .{ .callee = &middle_fn, .args = &.{} } };
    const outer_let: Tiny = .{ .let_star = .{
        .bindings = &.{.{ .name = "x", .value = &.{ .int = 5 } }},
        .body = &middle_call,
    } };
    const result = try runTiny(&arena, &outer_let);
    try testing.expectEqual(@as(i64, 5), result.asFixnum());
}

test "compile capture: same binding captured twice — second capture re-uses existing cell" {
    // (let* [x 5] ((fn* [] x)) ((fn* [] x))) — both fns
    // capture x. After the first fn's compileFn finishes, x
    // is .cell_slot in outer scope. The second fn's compileFn
    // sees x as .cell_slot already, doesn't re-emit
    // closure:box-local, and just references local_cell_slot
    // for the same slot.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fn1: Tiny = .{ .fn_star = .{ .params = &.{}, .body = &.{ .symbol = "x" } } };
    const fn2: Tiny = .{ .fn_star = .{ .params = &.{}, .body = &.{ .symbol = "x" } } };
    const call1: Tiny = .{ .call = .{ .callee = &fn1, .args = &.{} } };
    const call2: Tiny = .{ .call = .{ .callee = &fn2, .args = &.{} } };
    // Use the second call as the result so we exercise both.
    const body: Tiny = .{ .do_ = &.{ &call1, &call2 } };
    const let_form: Tiny = .{ .let_star = .{
        .bindings = &.{.{ .name = "x", .value = &.{ .int = 5 } }},
        .body = &body,
    } };
    const result = try runTiny(&arena, &let_form);
    try testing.expectEqual(@as(i64, 5), result.asFixnum());
}

test "compile capture: captured + non-captured params mix" {
    // (let* [x 10] ((fn* [y] (+ x y)) 7)) = 17
    // x is captured (becomes upvalue), y is a normal param
    // (direct_slot). The fn body's `+` reads both via the
    // appropriate BindingRef dispatch.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body: Tiny = .{ .add = .{ .lhs = &.{ .symbol = "x" }, .rhs = &.{ .symbol = "y" } } };
    const fn_form: Tiny = .{ .fn_star = .{ .params = &.{"y"}, .body = &body } };
    const call_form: Tiny = .{ .call = .{ .callee = &fn_form, .args = &.{&.{ .int = 7 }} } };
    const let_form: Tiny = .{ .let_star = .{
        .bindings = &.{.{ .name = "x", .value = &.{ .int = 10 } }},
        .body = &call_form,
    } };
    const result = try runTiny(&arena, &let_form);
    try testing.expectEqual(@as(i64, 17), result.asFixnum());
}

test "compile capture: still-unresolved symbol traps UnresolvedSymbol" {
    // (let* [x 5] ((fn* [] z))) — z is not in any enclosing
    // scope. The parent-chain walk bottoms out at the
    // top-level Emitter with no parent →
    // UnresolvedSymbol.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fn_form: Tiny = .{ .fn_star = .{ .params = &.{}, .body = &.{ .symbol = "z" } } };
    const call_form: Tiny = .{ .call = .{ .callee = &fn_form, .args = &.{} } };
    const let_form: Tiny = .{ .let_star = .{
        .bindings = &.{.{ .name = "x", .value = &.{ .int = 5 } }},
        .body = &call_form,
    } };
    const res = compileTiny(arena.allocator(), &let_form);
    try testing.expectError(CompileError.UnresolvedSymbol, res);
}

test "compile capture: captured fn used after let binding scope (closure outlives binding)" {
    // Demonstrates the central reason for boxing-via-cell:
    // when the closure is returned out of the let* and called
    // from elsewhere, the captured x must still work even
    // though the outer let* frame has long since exited.
    //
    // (let* [add5 (let* [x 5] (fn* [y] (+ x y)))] (add5 3)) = 8
    //
    // The inner let* exits before add5 is called; if x weren't
    // boxed into a heap cell, the captured slot would be
    // stale memory.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fn_body: Tiny = .{ .add = .{ .lhs = &.{ .symbol = "x" }, .rhs = &.{ .symbol = "y" } } };
    const fn_form: Tiny = .{ .fn_star = .{ .params = &.{"y"}, .body = &fn_body } };
    const inner_let: Tiny = .{ .let_star = .{
        .bindings = &.{.{ .name = "x", .value = &.{ .int = 5 } }},
        .body = &fn_form,
    } };
    const outer_call: Tiny = .{ .call = .{
        .callee = &.{ .symbol = "add5" },
        .args = &.{&.{ .int = 3 }},
    } };
    const outer_let: Tiny = .{ .let_star = .{
        .bindings = &.{.{ .name = "add5", .value = &inner_let }},
        .body = &outer_call,
    } };
    const result = try runTiny(&arena, &outer_let);
    try testing.expectEqual(@as(i64, 8), result.asFixnum());
}

test "compile capture: same-frame read of a captured binding after capture" {
    // (let* [x 5] (do ((fn* [] x)) x)) — outer let body's
    // second expression reads `x` AFTER the inner fn captured
    // it. x is .cell_slot in the outer scope (pre-analysis
    // boxed it in the let* prelude); the second read emits
    // closure:get-cell instead of mov:move.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const inner_fn: Tiny = .{ .fn_star = .{ .params = &.{}, .body = &.{ .symbol = "x" } } };
    const inner_call: Tiny = .{ .call = .{ .callee = &inner_fn, .args = &.{} } };
    const body: Tiny = .{ .do_ = &.{ &inner_call, &.{ .symbol = "x" } } };
    const let_form: Tiny = .{ .let_star = .{
        .bindings = &.{.{ .name = "x", .value = &.{ .int = 5 } }},
        .body = &body,
    } };
    const result = try runTiny(&arena, &let_form);
    try testing.expectEqual(@as(i64, 5), result.asFixnum());
}

// ---- capture control-flow safety tests ----

test "compile capture: capture in unreachable branch — same-frame read works" {
    // (let* [x 5] (do (if false (fn* [] x) 0) x)) = 5
    //
    // The hazard the lazy-boxing model failed: if the closure
    // creation is skipped at runtime, but the compiler still
    // thinks x is boxed, same-frame reads emit closure:get-cell
    // against an unboxed slot → ExpectedCell trap.
    //
    // Pre-analysis fixes this: x is captured by the inner fn,
    // so closure:box-local s_x is emitted in the let* prelude
    // (always executed), regardless of whether the if-branch
    // actually constructs the closure.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fn_form: Tiny = .{ .fn_star = .{ .params = &.{}, .body = &.{ .symbol = "x" } } };
    const if_form: Tiny = .{ .if_ = .{
        .test_ = &.{ .bool = false },
        .then = &fn_form,
        .else_ = &.{ .int = 0 },
    } };
    const body: Tiny = .{ .do_ = &.{ &if_form, &.{ .symbol = "x" } } };
    const let_form: Tiny = .{ .let_star = .{
        .bindings = &.{.{ .name = "x", .value = &.{ .int = 5 } }},
        .body = &body,
    } };
    const result = try runTiny(&arena, &let_form);
    try testing.expectEqual(@as(i64, 5), result.asFixnum());
}

test "compile capture: capture in unreachable branch — second closure construction works" {
    // (let* [x 5] (do (if false (fn* [] x) 0) ((fn* [] x)))) = 5
    //
    // Variant of the above: the second occurrence is itself a
    // closure construction. Under lazy boxing the second fn*
    // may compile assuming x is already boxed (skip box-local),
    // but at runtime the first branch was skipped and slot[s_x]
    // is a direct fixnum, so closure:make's local_cell_slot
    // source traps :expected-cell.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fn1: Tiny = .{ .fn_star = .{ .params = &.{}, .body = &.{ .symbol = "x" } } };
    const fn2: Tiny = .{ .fn_star = .{ .params = &.{}, .body = &.{ .symbol = "x" } } };
    const if_form: Tiny = .{ .if_ = .{
        .test_ = &.{ .bool = false },
        .then = &fn1,
        .else_ = &.{ .int = 0 },
    } };
    const second_call: Tiny = .{ .call = .{ .callee = &fn2, .args = &.{} } };
    const body: Tiny = .{ .do_ = &.{ &if_form, &second_call } };
    const let_form: Tiny = .{ .let_star = .{
        .bindings = &.{.{ .name = "x", .value = &.{ .int = 5 } }},
        .body = &body,
    } };
    const result = try runTiny(&arena, &let_form);
    try testing.expectEqual(@as(i64, 5), result.asFixnum());
}

test "compile capture: capture in taken branch" {
    // (let* [x 5] (do (if true (fn* [] x) 0) x)) = 5
    //
    // Sanity: a capture in a taken branch works the same as
    // one in straight-line code.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fn_form: Tiny = .{ .fn_star = .{ .params = &.{}, .body = &.{ .symbol = "x" } } };
    const if_form: Tiny = .{ .if_ = .{
        .test_ = &.{ .bool = true },
        .then = &fn_form,
        .else_ = &.{ .int = 0 },
    } };
    const body: Tiny = .{ .do_ = &.{ &if_form, &.{ .symbol = "x" } } };
    const let_form: Tiny = .{ .let_star = .{
        .bindings = &.{.{ .name = "x", .value = &.{ .int = 5 } }},
        .body = &body,
    } };
    const result = try runTiny(&arena, &let_form);
    try testing.expectEqual(@as(i64, 5), result.asFixnum());
}

test "compile capture: three-level transitive capture (let [x] ((fn () ((fn () ((fn () x))))))) = 5" {
    // Pin the recursive resolveOrCapture invariant at deeper
    // nesting.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const innermost_fn: Tiny = .{ .fn_star = .{ .params = &.{}, .body = &.{ .symbol = "x" } } };
    const innermost_call: Tiny = .{ .call = .{ .callee = &innermost_fn, .args = &.{} } };
    const middle_fn: Tiny = .{ .fn_star = .{ .params = &.{}, .body = &innermost_call } };
    const middle_call: Tiny = .{ .call = .{ .callee = &middle_fn, .args = &.{} } };
    const outer_fn: Tiny = .{ .fn_star = .{ .params = &.{}, .body = &middle_call } };
    const outer_call: Tiny = .{ .call = .{ .callee = &outer_fn, .args = &.{} } };
    const let_form: Tiny = .{ .let_star = .{
        .bindings = &.{.{ .name = "x", .value = &.{ .int = 5 } }},
        .body = &outer_call,
    } };
    const result = try runTiny(&arena, &let_form);
    try testing.expectEqual(@as(i64, 5), result.asFixnum());
}

test "compile capture: shadowing capture — inner let-bound x shadows outer for inner fn" {
    // (let* [x 1] (let* [f (let* [x 2] (fn* [] x))] (f))) = 2
    //
    // Inner let binds x to 2, then creates fn capturing x = 2.
    // Outer fn binding f captures the closure. Calling f
    // returns 2 (NOT 1 from the outermost x).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fn_form: Tiny = .{ .fn_star = .{ .params = &.{}, .body = &.{ .symbol = "x" } } };
    const inner_let: Tiny = .{ .let_star = .{
        .bindings = &.{.{ .name = "x", .value = &.{ .int = 2 } }},
        .body = &fn_form,
    } };
    const f_call: Tiny = .{ .call = .{ .callee = &.{ .symbol = "f" }, .args = &.{} } };
    const middle_let: Tiny = .{ .let_star = .{
        .bindings = &.{.{ .name = "f", .value = &inner_let }},
        .body = &f_call,
    } };
    const outer_let: Tiny = .{ .let_star = .{
        .bindings = &.{.{ .name = "x", .value = &.{ .int = 1 } }},
        .body = &middle_let,
    } };
    const result = try runTiny(&arena, &outer_let);
    try testing.expectEqual(@as(i64, 2), result.asFixnum());
}

test "compile capture: outer x captured by f, inner x shadows for body but not f's captured value" {
    // (let* [x 1, f (fn* [] x)] (let* [x 2] (f))) = 1
    //
    // f captures the OUTER x = 1 at construction time.
    // Inner let* shadows x with 2 for its body, but f's captured
    // cell still references the outer x = 1.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fn_form: Tiny = .{ .fn_star = .{ .params = &.{}, .body = &.{ .symbol = "x" } } };
    const f_call: Tiny = .{ .call = .{ .callee = &.{ .symbol = "f" }, .args = &.{} } };
    const inner_let: Tiny = .{ .let_star = .{
        .bindings = &.{.{ .name = "x", .value = &.{ .int = 2 } }},
        .body = &f_call,
    } };
    const outer_let: Tiny = .{ .let_star = .{
        .bindings = &.{
            .{ .name = "x", .value = &.{ .int = 1 } },
            .{ .name = "f", .value = &fn_form },
        },
        .body = &inner_let,
    } };
    const result = try runTiny(&arena, &outer_let);
    try testing.expectEqual(@as(i64, 1), result.asFixnum());
}

test "compile capture: param shadowed by inner let — only inner is captured" {
    // (((fn* [x] (let* [x 2] (fn* [] x))) 1)) = 2
    //
    // Outer fn's param x is shadowed by inner let's x = 2.
    // The innermost fn captures the SHADOWED inner x. Outer
    // param x should NOT be boxed (the env-aware analyzer
    // should detect the shadow and skip).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const innermost_fn: Tiny = .{ .fn_star = .{ .params = &.{}, .body = &.{ .symbol = "x" } } };
    const inner_let: Tiny = .{ .let_star = .{
        .bindings = &.{.{ .name = "x", .value = &.{ .int = 2 } }},
        .body = &innermost_fn,
    } };
    const outer_fn: Tiny = .{ .fn_star = .{ .params = &.{"x"}, .body = &inner_let } };
    const outer_call: Tiny = .{ .call = .{
        .callee = &outer_fn,
        .args = &.{&.{ .int = 1 }},
    } };
    // outer_call returns the closure; we then call it with no args.
    const final_call: Tiny = .{ .call = .{ .callee = &outer_call, .args = &.{} } };
    const result = try runTiny(&arena, &final_call);
    try testing.expectEqual(@as(i64, 2), result.asFixnum());
}

test "compile capture: captured param + branch — param boxed at fn entry" {
    // ((fn* [x] (do (if false (fn* [] x) 0) x)) 5) = 5
    //
    // Param x is captured by the inner fn (in unreachable
    // branch). Pre-analysis must box x at function entry, so
    // the same-frame read of x at the end of the do works
    // regardless of whether the branch executes.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const inner_fn: Tiny = .{ .fn_star = .{ .params = &.{}, .body = &.{ .symbol = "x" } } };
    const if_form: Tiny = .{ .if_ = .{
        .test_ = &.{ .bool = false },
        .then = &inner_fn,
        .else_ = &.{ .int = 0 },
    } };
    const body: Tiny = .{ .do_ = &.{ &if_form, &.{ .symbol = "x" } } };
    const outer_fn: Tiny = .{ .fn_star = .{ .params = &.{"x"}, .body = &body } };
    const call: Tiny = .{ .call = .{ .callee = &outer_fn, .args = &.{&.{ .int = 5 }} } };
    const result = try runTiny(&arena, &call);
    try testing.expectEqual(@as(i64, 5), result.asFixnum());
}

// ---- call-block contiguity ----

test "compile fn*: ((fn* [x y] (+ x y)) ((fn* [a] a) 1) 2) = 3 — call-block contiguity regression" {
    // If compileCall allocated arg slots one-at-a-time, a
    // non-trivial first arg (which itself allocates temps for
    // its own call block) would push the second arg's slot
    // past the predetermined position, breaking
    // the range-call ABI. Fixed by reserving the entire
    // contiguous block via allocSlotBlock BEFORE compiling
    // sub-expressions. This test pins the fix.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Inner: (fn* [a] a) called with 1 → 1
    const inner_fn: Tiny = .{ .fn_star = .{ .params = &.{"a"}, .body = &.{ .symbol = "a" } } };
    const inner_call: Tiny = .{ .call = .{ .callee = &inner_fn, .args = &.{&.{ .int = 1 }} } };
    // Outer: (fn* [x y] (+ x y))
    const outer_body: Tiny = .{ .add = .{ .lhs = &.{ .symbol = "x" }, .rhs = &.{ .symbol = "y" } } };
    const outer_fn: Tiny = .{ .fn_star = .{ .params = &.{ "x", "y" }, .body = &outer_body } };
    // Outer call: outer_fn(inner_call, 2)
    const outer_call: Tiny = .{ .call = .{
        .callee = &outer_fn,
        .args = &.{ &inner_call, &.{ .int = 2 } },
    } };
    const result = try runTiny(&arena, &outer_call);
    try testing.expectEqual(@as(i64, 3), result.asFixnum());
}

test "compile fn*: fn body uses inner let* — no captures of outer needed" {
    // ((fn* [x] (let* [y x] y)) 5) = 5
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const inner_let: Tiny = .{ .let_star = .{
        .bindings = &.{.{ .name = "y", .value = &.{ .symbol = "x" } }},
        .body = &.{ .symbol = "y" },
    } };
    const fn_form: Tiny = .{ .fn_star = .{ .params = &.{"x"}, .body = &inner_let } };
    const call_form: Tiny = .{ .call = .{ .callee = &fn_form, .args = &.{&.{ .int = 5 }} } };
    const result = try runTiny(&arena, &call_form);
    try testing.expectEqual(@as(i64, 5), result.asFixnum());
}

// ---- named fn* + letfn* tests ----

test "compile named-fn: named fn* without self-reference compiles as anonymous" {
    // ((fn* foo [x] x) 5) = 5 — body doesn't reference `foo`,
    // so no placeholder cell allocated, no init-cell emitted.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fn_form: Tiny = .{ .fn_star = .{
        .name = "foo",
        .params = &.{"x"},
        .body = &.{ .symbol = "x" },
    } };
    const call_form: Tiny = .{ .call = .{ .callee = &fn_form, .args = &.{&.{ .int = 5 }} } };
    const result = try runTiny(&arena, &call_form);
    try testing.expectEqual(@as(i64, 5), result.asFixnum());
}

test "compile named-fn: named fn* with self-ref in dead branch — placeholder allocated, no infinite recursion" {
    // ((fn* foo [x] (if true x (foo (+ x 1)))) 7) = 7
    // Body references `foo` but only under the (always-false)
    // else branch. Compiler must STILL emit the placeholder
    // cell (pre-analysis is control-flow agnostic), but at
    // runtime the recursive call never happens.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const inc_x: Tiny = .{ .add = .{ .lhs = &.{ .symbol = "x" }, .rhs = &.{ .int = 1 } } };
    const recursive_call: Tiny = .{ .call = .{
        .callee = &.{ .symbol = "foo" },
        .args = &.{&inc_x},
    } };
    const body: Tiny = .{ .if_ = .{
        .test_ = &.{ .bool = true },
        .then = &.{ .symbol = "x" },
        .else_ = &recursive_call,
    } };
    const fn_form: Tiny = .{ .fn_star = .{
        .name = "foo",
        .params = &.{"x"},
        .body = &body,
    } };
    const call_form: Tiny = .{ .call = .{ .callee = &fn_form, .args = &.{&.{ .int = 7 }} } };
    const result = try runTiny(&arena, &call_form);
    try testing.expectEqual(@as(i64, 7), result.asFixnum());
}

test "compile named-fn: named fn* with recursive ref in untaken branch — placeholder allocated, base branch executes" {
    // ((fn* foo [x] (if true (+ x 1) (foo x))) 7) = 8
    // The recursive call exists in code (forces placeholder
    // allocation per pre-analysis) but lives in the untaken
    // branch, so runtime executes only the base case.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const inc_x: Tiny = .{ .add = .{ .lhs = &.{ .symbol = "x" }, .rhs = &.{ .int = 1 } } };
    const rec_call: Tiny = .{ .call = .{ .callee = &.{ .symbol = "foo" }, .args = &.{&.{ .symbol = "x" }} } };
    const body: Tiny = .{ .if_ = .{
        .test_ = &.{ .bool = true },
        .then = &inc_x,
        .else_ = &rec_call,
    } };
    const fn_form: Tiny = .{ .fn_star = .{ .name = "foo", .params = &.{"x"}, .body = &body } };
    const call_form: Tiny = .{ .call = .{ .callee = &fn_form, .args = &.{&.{ .int = 7 }} } };
    const result = try runTiny(&arena, &call_form);
    try testing.expectEqual(@as(i64, 8), result.asFixnum());
}

test "compile named-fn: named fn* in let — recursive reference works after let-binding scope" {
    // (let* [f (fn* fact [n] (if true n (fact (+ n 1))))] (f 5)) = 5
    // The named self-ref creates a cell that's INSIDE the
    // fn-creating expression (not in let-binding's slot), so
    // the closure remains callable after the let binding's
    // value is consumed.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const inc_n: Tiny = .{ .add = .{ .lhs = &.{ .symbol = "n" }, .rhs = &.{ .int = 1 } } };
    const rec_call: Tiny = .{ .call = .{ .callee = &.{ .symbol = "fact" }, .args = &.{&inc_n} } };
    const body: Tiny = .{ .if_ = .{
        .test_ = &.{ .bool = true },
        .then = &.{ .symbol = "n" },
        .else_ = &rec_call,
    } };
    const fn_form: Tiny = .{ .fn_star = .{ .name = "fact", .params = &.{"n"}, .body = &body } };
    const f_call: Tiny = .{ .call = .{ .callee = &.{ .symbol = "f" }, .args = &.{&.{ .int = 5 }} } };
    const let_form: Tiny = .{ .let_star = .{
        .bindings = &.{.{ .name = "f", .value = &fn_form }},
        .body = &f_call,
    } };
    const result = try runTiny(&arena, &let_form);
    try testing.expectEqual(@as(i64, 5), result.asFixnum());
}

test "compile named-fn: (letfn* [(f [x] (+ x 1))] (f 10)) = 11 — single binding" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f_body: Tiny = .{ .add = .{ .lhs = &.{ .symbol = "x" }, .rhs = &.{ .int = 1 } } };
    const f_call: Tiny = .{ .call = .{ .callee = &.{ .symbol = "f" }, .args = &.{&.{ .int = 10 }} } };
    const form: Tiny = .{ .letfn_star = .{
        .bindings = &.{.{ .name = "f", .params = &.{"x"}, .body = &f_body }},
        .body = &f_call,
    } };
    const result = try runTiny(&arena, &form);
    try testing.expectEqual(@as(i64, 11), result.asFixnum());
}

test "compile named-fn: (letfn* [(f [] (g)) (g [] 42)] (f)) = 42 — f calls g (forward ref)" {
    // Demonstrates true forward reference: f's body references
    // g, which is defined later in the binding group. The
    // placeholder-cell pattern makes this work — g's cell
    // exists before f's closure is constructed, so f can
    // capture it.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f_body: Tiny = .{ .call = .{ .callee = &.{ .symbol = "g" }, .args = &.{} } };
    const g_body: Tiny = .{ .int = 42 };
    const body: Tiny = .{ .call = .{ .callee = &.{ .symbol = "f" }, .args = &.{} } };
    const form: Tiny = .{ .letfn_star = .{
        .bindings = &.{
            .{ .name = "f", .params = &.{}, .body = &f_body },
            .{ .name = "g", .params = &.{}, .body = &g_body },
        },
        .body = &body,
    } };
    const result = try runTiny(&arena, &form);
    try testing.expectEqual(@as(i64, 42), result.asFixnum());
}

test "compile named-fn: letfn* mutual recursion (dead branches only)" {
    // (letfn* [(f [n] (if true n (g n)))
    //          (g [n] (if true (+ n 10) (f n)))]
    //   (g 5)) = 15
    // Both bindings reference each other; both refs are in
    // dead branches. Compiler must allocate cells for both,
    // capture appropriately.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f_call_n: Tiny = .{ .call = .{ .callee = &.{ .symbol = "f" }, .args = &.{&.{ .symbol = "n" }} } };
    const g_call_n: Tiny = .{ .call = .{ .callee = &.{ .symbol = "g" }, .args = &.{&.{ .symbol = "n" }} } };
    const f_body: Tiny = .{ .if_ = .{
        .test_ = &.{ .bool = true },
        .then = &.{ .symbol = "n" },
        .else_ = &g_call_n,
    } };
    const g_body_then: Tiny = .{ .add = .{ .lhs = &.{ .symbol = "n" }, .rhs = &.{ .int = 10 } } };
    const g_body: Tiny = .{ .if_ = .{
        .test_ = &.{ .bool = true },
        .then = &g_body_then,
        .else_ = &f_call_n,
    } };
    const body: Tiny = .{ .call = .{ .callee = &.{ .symbol = "g" }, .args = &.{&.{ .int = 5 }} } };
    const form: Tiny = .{ .letfn_star = .{
        .bindings = &.{
            .{ .name = "f", .params = &.{"n"}, .body = &f_body },
            .{ .name = "g", .params = &.{"n"}, .body = &g_body },
        },
        .body = &body,
    } };
    const result = try runTiny(&arena, &form);
    try testing.expectEqual(@as(i64, 15), result.asFixnum());
}

test "compile named-fn: named self shadowed by inner let — no placeholder, returns let value" {
    // ((fn* foo [x] (let* [foo 5] foo)) 0) = 5
    // The body's only reference to `foo` is inside a `let*`
    // that rebinds it. Pre-analysis sees `foo` is NOT a free
    // var of the body (because the inner let* binds it), so
    // no placeholder cell is allocated, and `foo` inside the
    // body resolves to the inner let* binding (= 5).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const inner_let: Tiny = .{ .let_star = .{
        .bindings = &.{.{ .name = "foo", .value = &.{ .int = 5 } }},
        .body = &.{ .symbol = "foo" },
    } };
    const fn_form: Tiny = .{ .fn_star = .{ .name = "foo", .params = &.{"x"}, .body = &inner_let } };
    const call_form: Tiny = .{ .call = .{ .callee = &fn_form, .args = &.{&.{ .int = 0 }} } };
    const result = try runTiny(&arena, &call_form);
    try testing.expectEqual(@as(i64, 5), result.asFixnum());
}

test "compile named-fn: named self shadows outer binding — body sees the closure, not outer foo" {
    // (let* [foo 123] ((fn* foo [] foo)))
    // Inside the fn body, `foo` resolves to the self-name
    // (= the closure itself), NOT the outer let-bound 123.
    // Calling the fn returns the closure value (kind .function).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fn_form: Tiny = .{ .fn_star = .{ .name = "foo", .params = &.{}, .body = &.{ .symbol = "foo" } } };
    const call_form: Tiny = .{ .call = .{ .callee = &fn_form, .args = &.{} } };
    const outer: Tiny = .{ .let_star = .{
        .bindings = &.{.{ .name = "foo", .value = &.{ .int = 123 } }},
        .body = &call_form,
    } };
    const result = try runTiny(&arena, &outer);
    try testing.expect(result.kind() == .function);
}

test "compile named-fn: named fn* param shadows self-name (intentional Tiny semantics)" {
    // ((fn* foo [foo] foo) 7) = 7
    // The param `foo` shadows the self-name. Pre-analysis
    // sees `foo` is NOT a free var of the body (because the
    // param binds it), so no placeholder is allocated, and
    // the body's `foo` resolves to the param (= 7).
    // (Pinned by this explicit test.)
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fn_form: Tiny = .{ .fn_star = .{ .name = "foo", .params = &.{"foo"}, .body = &.{ .symbol = "foo" } } };
    const call_form: Tiny = .{ .call = .{ .callee = &fn_form, .args = &.{&.{ .int = 7 }} } };
    const result = try runTiny(&arena, &call_form);
    try testing.expectEqual(@as(i64, 7), result.asFixnum());
}

test "compile named-fn: letfn binding captures both another letfn binding and outer let binding" {
    // (let* [x 10]
    //   (letfn* [(f [] (+ x (g)))
    //            (g [] 5)]
    //     (f))) = 15
    // f's closure capture descriptor has two sources: one for
    // the outer let's x (cell_slot in outer frame) and one
    // for g (cell_slot in letfn frame). Validates mixed-source
    // capture descriptors compose correctly.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const g_call: Tiny = .{ .call = .{ .callee = &.{ .symbol = "g" }, .args = &.{} } };
    const f_body: Tiny = .{ .add = .{ .lhs = &.{ .symbol = "x" }, .rhs = &g_call } };
    const g_body: Tiny = .{ .int = 5 };
    const f_call: Tiny = .{ .call = .{ .callee = &.{ .symbol = "f" }, .args = &.{} } };
    const letfn: Tiny = .{ .letfn_star = .{
        .bindings = &.{
            .{ .name = "f", .params = &.{}, .body = &f_body },
            .{ .name = "g", .params = &.{}, .body = &g_body },
        },
        .body = &f_call,
    } };
    const outer: Tiny = .{ .let_star = .{
        .bindings = &.{.{ .name = "x", .value = &.{ .int = 10 } }},
        .body = &letfn,
    } };
    const result = try runTiny(&arena, &outer);
    try testing.expectEqual(@as(i64, 15), result.asFixnum());
}

test "compile named-fn: letfn* with three bindings, chained calls" {
    // (letfn* [(a [] (b))
    //          (b [] (c))
    //          (c [] 7)]
    //   (a)) = 7
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a_body: Tiny = .{ .call = .{ .callee = &.{ .symbol = "b" }, .args = &.{} } };
    const b_body: Tiny = .{ .call = .{ .callee = &.{ .symbol = "c" }, .args = &.{} } };
    const c_body: Tiny = .{ .int = 7 };
    const body: Tiny = .{ .call = .{ .callee = &.{ .symbol = "a" }, .args = &.{} } };
    const form: Tiny = .{ .letfn_star = .{
        .bindings = &.{
            .{ .name = "a", .params = &.{}, .body = &a_body },
            .{ .name = "b", .params = &.{}, .body = &b_body },
            .{ .name = "c", .params = &.{}, .body = &c_body },
        },
        .body = &body,
    } };
    const result = try runTiny(&arena, &form);
    try testing.expectEqual(@as(i64, 7), result.asFixnum());
}

test "compile named-fn: letfn* shadows outer let binding" {
    // (let* [f 10] (letfn* [(f [] 5)] (f))) = 5
    // Inner letfn* `f` shadows outer let* `f`.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f_body: Tiny = .{ .int = 5 };
    const f_call: Tiny = .{ .call = .{ .callee = &.{ .symbol = "f" }, .args = &.{} } };
    const inner: Tiny = .{ .letfn_star = .{
        .bindings = &.{.{ .name = "f", .params = &.{}, .body = &f_body }},
        .body = &f_call,
    } };
    const outer: Tiny = .{ .let_star = .{
        .bindings = &.{.{ .name = "f", .value = &.{ .int = 10 } }},
        .body = &inner,
    } };
    const result = try runTiny(&arena, &outer);
    try testing.expectEqual(@as(i64, 5), result.asFixnum());
}

test "compile named-fn: letfn* binding captures outer let binding" {
    // (let* [x 100]
    //   (letfn* [(f [] x)]
    //     (f))) = 100
    // letfn binding f captures outer x.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f_body: Tiny = .{ .symbol = "x" };
    const f_call: Tiny = .{ .call = .{ .callee = &.{ .symbol = "f" }, .args = &.{} } };
    const inner: Tiny = .{ .letfn_star = .{
        .bindings = &.{.{ .name = "f", .params = &.{}, .body = &f_body }},
        .body = &f_call,
    } };
    const outer: Tiny = .{ .let_star = .{
        .bindings = &.{.{ .name = "x", .value = &.{ .int = 100 } }},
        .body = &inner,
    } };
    const result = try runTiny(&arena, &outer);
    try testing.expectEqual(@as(i64, 100), result.asFixnum());
}

test "compile named-fn: letfn* — body sees bindings (calls one of them)" {
    // (letfn* [(f [] 99) (g [] 0)] (f)) = 99
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const form: Tiny = .{ .letfn_star = .{
        .bindings = &.{
            .{ .name = "f", .params = &.{}, .body = &.{ .int = 99 } },
            .{ .name = "g", .params = &.{}, .body = &.{ .int = 0 } },
        },
        .body = &.{ .call = .{ .callee = &.{ .symbol = "f" }, .args = &.{} } },
    } };
    const result = try runTiny(&arena, &form);
    try testing.expectEqual(@as(i64, 99), result.asFixnum());
}

test "compile named-fn: letfn* duplicate name → DuplicateBinding" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const form: Tiny = .{ .letfn_star = .{
        .bindings = &.{
            .{ .name = "f", .params = &.{}, .body = &.{ .int = 1 } },
            .{ .name = "f", .params = &.{}, .body = &.{ .int = 2 } },
        },
        .body = &.{ .symbol = "f" },
    } };
    try testing.expectError(CompileError.DuplicateBinding, compileTiny(arena.allocator(), &form));
}

test "compile named-fn: letfn* body scope properly restored after letfn*" {
    // (let* [x 1]
    //   (letfn* [(x [] 99)]  ; shadow x as a fn
    //     (x))
    //   ;; outer x scope must still see x as 1 (but we test
    //   ;; via a do form to chain two reads)
    //   ) — Since we don't have do here at the top level
    //   yet, use:
    // (let* [x 1
    //        a (letfn* [(x [] 99)] (x))
    //        b x]
    //   (+ a b)) = 99 + 1 = 100
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fn_body: Tiny = .{ .int = 99 };
    const fn_call: Tiny = .{ .call = .{ .callee = &.{ .symbol = "x" }, .args = &.{} } };
    const letfn: Tiny = .{ .letfn_star = .{
        .bindings = &.{.{ .name = "x", .params = &.{}, .body = &fn_body }},
        .body = &fn_call,
    } };
    const add_form: Tiny = .{ .add = .{ .lhs = &.{ .symbol = "a" }, .rhs = &.{ .symbol = "b" } } };
    const let_form: Tiny = .{ .let_star = .{
        .bindings = &.{
            .{ .name = "x", .value = &.{ .int = 1 } },
            .{ .name = "a", .value = &letfn },
            .{ .name = "b", .value = &.{ .symbol = "x" } },
        },
        .body = &add_form,
    } };
    const result = try runTiny(&arena, &let_form);
    try testing.expectEqual(@as(i64, 100), result.asFixnum());
}

// ---- Form → Tiny lowering + compileSource tests ----

test "compile lowerForm: lowerForm of nil → run → nil" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const form = reader_mod.Form{ .datum = .nil, .origin = .{ .pos = 0, .len = 0 } };
    const compiled = try compileForm(arena.allocator(), &form);
    const routine = compiled.toRoutine("nil-form");
    var v = try vm.VM.init(testing.allocator, &routine);
    defer v.deinit();
    const result = try v.run();
    try testing.expect(result.isNil());
}

test "compile lowerForm: lowerForm of bool true → run → true" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const form = reader_mod.Form{ .datum = .{ .bool_ = true }, .origin = .{ .pos = 0, .len = 0 } };
    const compiled = try compileForm(arena.allocator(), &form);
    const routine = compiled.toRoutine("true-form");
    var v = try vm.VM.init(testing.allocator, &routine);
    defer v.deinit();
    const result = try v.run();
    try testing.expectEqual(true, result.asBool());
}

test "compile lowerForm: lowerForm of int 42 → run → 42" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const form = reader_mod.Form{ .datum = .{ .int = 42 }, .origin = .{ .pos = 0, .len = 0 } };
    const compiled = try compileForm(arena.allocator(), &form);
    const routine = compiled.toRoutine("int-form");
    var v = try vm.VM.init(testing.allocator, &routine);
    defer v.deinit();
    const result = try v.run();
    try testing.expectEqual(@as(i64, 42), result.asFixnum());
}

test "compile lowerForm: compileSource \"nil\" → nil" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const compiled = try compileSource(arena.allocator(), "nil");
    const routine = compiled.toRoutine("src-nil");
    var v = try vm.VM.init(testing.allocator, &routine);
    defer v.deinit();
    const result = try v.run();
    try testing.expect(result.isNil());
}

test "compile lowerForm: compileSource \"true\" → true" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const compiled = try compileSource(arena.allocator(), "true");
    const routine = compiled.toRoutine("src-true");
    var v = try vm.VM.init(testing.allocator, &routine);
    defer v.deinit();
    const result = try v.run();
    try testing.expectEqual(true, result.asBool());
}

test "compile lowerForm: compileSource \"false\" → false" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const compiled = try compileSource(arena.allocator(), "false");
    const routine = compiled.toRoutine("src-false");
    var v = try vm.VM.init(testing.allocator, &routine);
    defer v.deinit();
    const result = try v.run();
    try testing.expectEqual(false, result.asBool());
}

test "compile lowerForm: compileSource \"42\" → 42" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const compiled = try compileSource(arena.allocator(), "42");
    const routine = compiled.toRoutine("src-42");
    var v = try vm.VM.init(testing.allocator, &routine);
    defer v.deinit();
    const result = try v.run();
    try testing.expectEqual(@as(i64, 42), result.asFixnum());
}

test "compile lowerForm: compileSource \"-7\" → -7" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const compiled = try compileSource(arena.allocator(), "-7");
    const routine = compiled.toRoutine("src-neg7");
    var v = try vm.VM.init(testing.allocator, &routine);
    defer v.deinit();
    const result = try v.run();
    try testing.expectEqual(@as(i64, -7), result.asFixnum());
}

test "compile lowerForm: compileSource of unqualified symbol with no namespace → UnresolvedSymbol" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(
        CompileError.UnresolvedSymbol,
        compileSource(arena.allocator(), "x"),
    );
}

test "compile lowerForm: compileSource of symbol resolves via namespace fall-through" {
    // Prove the symbol fall-through path works end-to-end via
    // real source syntax: source "x" with x pre-bound in the
    // namespace returns the bound value.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(testing.allocator, &stub);
    defer v.deinit();
    const ns = v.ensureNamespace();
    const x = try ns.intern("x");
    x.root = value_mod.fromFixnum(99).?;
    x.bound = true;

    const compiled = try compileSourceWithNamespace(arena.allocator(), "x", ns);
    const routine = compiled.toRoutine("src-symbol");
    try v.retargetTop(&routine);
    const result = try v.run();
    try testing.expectEqual(@as(i64, 99), result.asFixnum());
}

test "compile lowerForm: lowerForm of string literal without a heap → UnsupportedFeature" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const form = reader_mod.Form{ .datum = .{ .string = "hello" }, .origin = .{ .pos = 0, .len = 0 } };
    try testing.expectError(CompileError.UnsupportedFeature, lowerForm(arena.allocator(), &form));
}

test "compile lowerForm: lowerForm of keyword without an interner → UnsupportedFeature" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const form = reader_mod.Form{
        .datum = .{ .keyword = .{ .ns = null, .name = "foo" } },
        .origin = .{ .pos = 0, .len = 0 },
    };
    try testing.expectError(CompileError.UnsupportedFeature, lowerForm(arena.allocator(), &form));
}

test "compile lowerForm: the empty list lowers to an empty list construction" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const empty: []const *reader_mod.Form = &.{};
    const form = reader_mod.Form{ .datum = .{ .list = empty }, .origin = .{ .pos = 0, .len = 0 } };
    const t = try lowerForm(arena.allocator(), &form);
    try testing.expect(t.* == .list_construct);
    try testing.expectEqual(@as(usize, 0), t.list_construct.len);
}

test "compile qualified: lowerForm of qualified symbol → Tiny.qualified_symbol" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const form = reader_mod.Form{
        .datum = .{ .symbol = .{ .ns = "foo", .name = "x" } },
        .origin = .{ .pos = 0, .len = 0 },
    };
    const tiny = try lowerForm(arena.allocator(), &form);
    try testing.expect(tiny.* == .qualified_symbol);
    try testing.expectEqualStrings("foo", tiny.qualified_symbol.ns);
    try testing.expectEqualStrings("x", tiny.qualified_symbol.name);
}

test "compile lowerForm: compileSource of malformed input → ReaderFailure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Unmatched paren — reader rejects.
    try testing.expectError(
        CompileError.ReaderFailure,
        compileSource(arena.allocator(), "(foo"),
    );
}

// ---- list dispatch — calls + special forms + intrinsics ----

/// Helper: run a source string and assert the result is a fixnum
/// equal to `expected`. Builds a fresh VM, manages lifetime
/// explicitly so the result outlives the arena teardown is
/// not an issue (the asserted value is read before defers fire).
fn expectSourceFixnum(src: []const u8, expected: i64) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const compiled = try compileSource(arena.allocator(), src);
    const routine = compiled.toRoutine("src");
    var v = try vm.VM.init(testing.allocator, &routine);
    defer v.deinit();
    const result = try v.run();
    try testing.expectEqual(expected, result.asFixnum());
}

fn expectSourceBool(src: []const u8, expected: bool) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const compiled = try compileSource(arena.allocator(), src);
    const routine = compiled.toRoutine("src");
    var v = try vm.VM.init(testing.allocator, &routine);
    defer v.deinit();
    const result = try v.run();
    try testing.expectEqual(expected, result.asBool());
}

fn expectSourceNil(src: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const compiled = try compileSource(arena.allocator(), src);
    const routine = compiled.toRoutine("src");
    var v = try vm.VM.init(testing.allocator, &routine);
    defer v.deinit();
    const result = try v.run();
    try testing.expect(result.isNil());
}

test "compile source: (+ 1 2) = 3" {
    try expectSourceFixnum("(+ 1 2)", 3);
}

test "compile source: (+ -7 -5) = -12" {
    try expectSourceFixnum("(+ -7 -5)", -12);
}

test "compile source: (< 1 2) = true" {
    try expectSourceBool("(< 1 2)", true);
}

test "compile source: (< 2 1) = false" {
    try expectSourceBool("(< 2 1)", false);
}

test "compile source: (if true 1 2) = 1" {
    try expectSourceFixnum("(if true 1 2)", 1);
}

test "compile source: (if false 1 2) = 2" {
    try expectSourceFixnum("(if false 1 2)", 2);
}

test "compile source: (if true 7) = 7 — no else arm" {
    try expectSourceFixnum("(if true 7)", 7);
}

test "compile source: (if false 7) — no else, falsy test → nil" {
    try expectSourceNil("(if false 7)");
}

test "compile source: (do) → nil" {
    try expectSourceNil("(do)");
}

test "compile source: (do 1) → 1" {
    try expectSourceFixnum("(do 1)", 1);
}

test "compile source: (do 1 2 3) → 3" {
    try expectSourceFixnum("(do 1 2 3)", 3);
}

test "compile source: (quote 42) → 42" {
    try expectSourceFixnum("(quote 42)", 42);
}

test "compile source: (quote nil) → nil" {
    try expectSourceNil("(quote nil)");
}

test "compile source: (quote true) → true" {
    try expectSourceBool("(quote true)", true);
}

test "compile source: 'true (reader-macro form) → true" {
    // `'x` lowers to Datum.quote(x); lowerFormEnv handles it
    // via the .quote arm.
    try expectSourceBool("'true", true);
}

test "compile source: nested (if (< 1 2) (+ 10 20) (+ 100 200)) = 30" {
    try expectSourceFixnum("(if (< 1 2) (+ 10 20) (+ 100 200))", 30);
}

test "compile source: (if) malformed → MalformedForm" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(CompileError.MalformedForm, compileSource(arena.allocator(), "(if)"));
}

test "compile source: (if 1) malformed → MalformedForm" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(CompileError.MalformedForm, compileSource(arena.allocator(), "(if 1)"));
}

test "compile source: (if a b c d) too many args → MalformedForm" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(CompileError.MalformedForm, compileSource(arena.allocator(), "(if true 1 2 3)"));
}

test "compile source: (quote) malformed → MalformedForm" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(CompileError.MalformedForm, compileSource(arena.allocator(), "(quote)"));
}

test "compile source: (quote a b) too many args → MalformedForm" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(CompileError.MalformedForm, compileSource(arena.allocator(), "(quote 1 2)"));
}

test "compile source: (quote foo) symbol via compileSource (no interner) → UnsupportedFeature" {
    // Without an Interner, quoted symbols still raise
    // UnsupportedFeature. Use `compileSourceFull` to enable
    // quoted-symbol support; see the quote symbol tests below.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(CompileError.UnsupportedFeature, compileSource(arena.allocator(), "(quote foo)"));
}

test "compile source: () is the empty list" {
    var r = try runSourceFull("()");
    defer r.vm_owned.deinit();
    try testing.expect(r.result.kind() == .list);
    try testing.expect(list_mod.isEmpty(r.result));
}

test "compile source: empty bodies are nil" {
    try expectSourceNil("((fn* []))");
    try expectSourceNil("((fn* f []))");
    try expectSourceNil("((fn* [x]) 1)");
    try expectSourceNil("(let* [x 1])");
    try expectSourceNil("(loop* [x 1])");
    try expectSourceNil("(letfn* [(f [])] (f))");
    try expectSourceNil("(try (throw 1) (catch any e))");
    try expectSourceNil("(try (catch any e 1))");
}

// Ordinary-call tests with fn* callees are in the binding-form
// section below. Resolving a top-level symbol requires either a
// lexical binding or a namespace lookup. A simple smoke test of
// that path:

test "compile source: non-special-form head falls through to ordinary-call dispatch" {
    // Confirms the dispatcher routes `(inc 5)` through lowerCall
    // (treating `inc` as a symbol to resolve), NOT a special form.
    // Without a namespace, the symbol can't resolve → UnresolvedSymbol.
    // (End-to-end calls with fn* callees / namespace-bound fns are
    // tested in the binding-form and var-form sections.)
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(
        CompileError.UnresolvedSymbol,
        compileSource(arena.allocator(), "(inc 5)"),
    );
}

// ---- binding forms via Form (let*/fn*/letfn*/loop*/recur) ----

test "compile source let: (let* [x 5] x) → 5" {
    try expectSourceFixnum("(let* [x 5] x)", 5);
}

test "compile source let: (let* [x 1 y 2] (+ x y)) → 3" {
    try expectSourceFixnum("(let* [x 1 y 2] (+ x y))", 3);
}

test "compile source let: (let* [x 5 y x] y) → 5 — sequential RHS sees prior" {
    try expectSourceFixnum("(let* [x 5 y x] y)", 5);
}

test "compile source let: nested let — inner shadows outer" {
    try expectSourceFixnum("(let* [x 1] (let* [x 99] x))", 99);
}

test "compile source let: (let* [] 42) → 42 — empty binding vector" {
    try expectSourceFixnum("(let* [] 42)", 42);
}

test "compile source let: let* multi-form body (implicit do) — (let* [x 1] x x x) → 1" {
    // Body is treated as (do x x x); last form is the result.
    try expectSourceFixnum("(let* [x 1] 99 88 x)", 1);
}

test "compile source let: ((fn* [x] (+ x 1)) 5) → 6" {
    try expectSourceFixnum("((fn* [x] (+ x 1)) 5)", 6);
}

test "compile source let: ((fn* [] 42)) → 42 — nullary fn" {
    try expectSourceFixnum("((fn* [] 42))", 42);
}

test "compile source let: ((fn* [x y] (+ x y)) 3 4) → 7" {
    try expectSourceFixnum("((fn* [x y] (+ x y)) 3 4)", 7);
}

test "compile source let: closure captures outer let binding" {
    try expectSourceFixnum("(let* [x 10] ((fn* [y] (+ x y)) 5))", 15);
}

test "compile source let: named fn* — ((fn* foo [n] (if (< n 3) (recur (+ n 1)) n)) 0) → 3" {
    try expectSourceFixnum("((fn* foo [n] (if (< n 3) (recur (+ n 1)) n)) 0)", 3);
}

test "compile source let: (loop* [i 0] (if (< i 5) (recur (+ i 1)) i)) → 5" {
    try expectSourceFixnum("(loop* [i 0] (if (< i 5) (recur (+ i 1)) i))", 5);
}

test "compile source let: (loop* [i 0 acc 0] (if (< i 10) (recur (+ i 1) (+ acc i)) acc)) → 45" {
    try expectSourceFixnum("(loop* [i 0 acc 0] (if (< i 10) (recur (+ i 1) (+ acc i)) acc))", 45);
}

test "compile source let: (letfn* [(f [] 42)] (f)) → 42" {
    try expectSourceFixnum("(letfn* [(f [] 42)] (f))", 42);
}

test "compile source let: (letfn* [(f [] (g)) (g [] 99)] (f)) → 99 — forward ref via letfn*" {
    try expectSourceFixnum("(letfn* [(f [] (g)) (g [] 99)] (f))", 99);
}

// -- INTRINSIC SHADOWING --

test "compile source let: (let* [+ (fn* [a b] 42)] (+ 1 2)) → 42 — lexical shadow defeats inline" {
    // The LowerEnv must mark `+` as bound inside the let* body
    // so the dispatcher falls through to ordinary call rather
    // than emitting Tiny.add. Result: 42 (the fn returns 42),
    // not 3 (Tiny.add of 1 and 2).
    try expectSourceFixnum("(let* [+ (fn* [a b] 42)] (+ 1 2))", 42);
}

test "compile source let: (let* [< (fn* [a b] 999)] (if (< 1 2) 1 0)) → 0 — < shadowed" {
    // Same idea for <. The fn always returns 999 (truthy), so
    // `if` takes the then-branch... wait, no — the shadowed `<`
    // returns 999, which IS truthy. Hmm let me reconsider.
    // 999 is truthy → if takes then-branch → returns 1.
    // Without shadowing, `(< 1 2)` would be true → also 1.
    // So this test doesn't distinguish.
    //
    // Better: shadow `<` with a fn that returns FALSE; then
    // the if takes else-branch (0). With Tiny.lt unshadowed,
    // (< 1 2) = true → then-branch (1). So distinct results.
    try expectSourceFixnum("(let* [< (fn* [a b] false)] (if (< 1 2) 1 0))", 0);
}

test "compile source let: special form `if` is NOT shadowable" {
    // (let* [if 1] (if true 2 3)) — `if` in operator position
    // remains the special form. Result: 2 (then-branch of true).
    // (If `if` were shadowable, the inner `if` would try to call
    // the integer 1, which would fail with NotCallable.)
    try expectSourceFixnum("(let* [if 1] (if true 2 3))", 2);
}

// -- Variadic params via Form --

test "compile source let: ((fn* [a & r] a) 1 2 3) → 1 — rest collected but unused" {
    try expectSourceFixnum("((fn* [a & r] a) 1 2 3)", 1);
}

test "compile source let: ((fn* [& r] 42)) → 42 — variadic with no args" {
    try expectSourceFixnum("((fn* [& r] 42))", 42);
}

// -- Malformed forms --

test "compile source let: (let*) → MalformedForm" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(CompileError.MalformedForm, compileSource(arena.allocator(), "(let*)"));
}

test "compile source let: (let* [x] x) odd binding count → MalformedForm" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(CompileError.MalformedForm, compileSource(arena.allocator(), "(let* [x] x)"));
}

test "compile source let: (let* (x 1) x) binding spec is list not vector → ExpectedVector" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(CompileError.ExpectedVector, compileSource(arena.allocator(), "(let* (x 1) x)"));
}

test "compile source let: (let* [1 2] body) binding name is int → ExpectedSymbol" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(CompileError.ExpectedSymbol, compileSource(arena.allocator(), "(let* [1 2] 3)"));
}

test "compile source let: (fn* [x &]) trailing & → MalformedForm" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(CompileError.MalformedForm, compileSource(arena.allocator(), "(fn* [x &] x)"));
}

test "compile source let: (fn* [x & r y] body) extra after rest → MalformedForm" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(CompileError.MalformedForm, compileSource(arena.allocator(), "(fn* [x & r y] x)"));
}

test "compile source let: (fn* (x) body) param spec is list not vector → ExpectedVector" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(CompileError.ExpectedVector, compileSource(arena.allocator(), "(fn* (x) x)"));
}

// ---- var forms via Form (def/defn/var) ----

/// Helper: run a source string against a fresh VM with its own
/// namespace, assert the result is a fixnum equal to `expected`.
fn expectSourceFixnumWithNs(src: []const u8, expected: i64) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(testing.allocator, &stub);
    defer v.deinit();
    const ns = v.ensureNamespace();
    const compiled = try compileSourceWithNamespace(arena.allocator(), src, ns);
    const routine = compiled.toRoutine("src-ns");
    try v.retargetTop(&routine);
    const result = try v.run();
    try testing.expectEqual(expected, result.asFixnum());
}

test "compile source def: (do (def x 5) x) → 5" {
    try expectSourceFixnumWithNs("(do (def x 5) x)", 5);
}

test "compile source def: (do (def x 5) (def x 10) x) → 10 — rebind preserves identity" {
    try expectSourceFixnumWithNs("(do (def x 5) (def x 10) x)", 10);
}

test "compile source def: (do (defn add1 [n] (+ n 1)) (add1 5)) → 6" {
    try expectSourceFixnumWithNs("(do (defn add1 [n] (+ n 1)) (add1 5))", 6);
}

test "compile source def: (do (defn id [x] x) (id 42)) → 42" {
    try expectSourceFixnumWithNs("(do (defn id [x] x) (id 42))", 42);
}

test "compile source def: defn with recur — (do (defn loop-down [n] (if (< n 1) n (recur (+ n -1)))) (loop-down 5)) → 0" {
    try expectSourceFixnumWithNs(
        "(do (defn loop-down [n] (if (< n 1) n (recur (+ n -1)))) (loop-down 5))",
        0,
    );
}

test "compile source def: defn with rest param — (do (defn first-of [a & r] a) (first-of 7 99 100)) → 7" {
    try expectSourceFixnumWithNs("(do (defn first-of [a & r] a) (first-of 7 99 100))", 7);
}

test "compile source def: canonical forward reference — (do (defn f [] (g)) (defn g [] 42) (f)) → 42" {
    // The big payoff: real source syntax for the forward-reference
    // pattern. f compiles when g is unbound (Var interned lazily
    // via compileSymbol's fall-through); after g is bound, f's
    // call resolves to g's closure.
    try expectSourceFixnumWithNs("(do (defn f [] (g)) (defn g [] 42) (f))", 42);
}

test "compile source def: (do (def x 5) (let* [x 99] x)) → 99 — lexical local shadows Var" {
    try expectSourceFixnumWithNs("(do (def x 5) (let* [x 99] x))", 99);
}

test "compile source def: forward reference + call before bind → UnboundVar at runtime" {
    // (do (defn f [] (g)) (f)) — g never defined; f's call to
    // g traps :unbound-var when invoked.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(testing.allocator, &stub);
    defer v.deinit();
    const ns = v.ensureNamespace();
    const compiled = try compileSourceWithNamespace(
        arena.allocator(),
        "(do (defn f [] (g)) (f))",
        ns,
    );
    const routine = compiled.toRoutine("fwd-unbound");
    try v.retargetTop(&routine);
    try testing.expectError(vm.VmError.UnboundVar, v.run());
}

test "compile source def: (var x) returns the Var object" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(testing.allocator, &stub);
    defer v.deinit();
    const ns = v.ensureNamespace();
    const compiled = try compileSourceWithNamespace(arena.allocator(), "(var some-name)", ns);
    const routine = compiled.toRoutine("var-ref");
    try v.retargetTop(&routine);
    const result = try v.run();
    try testing.expect(result.kind() == .var_);
    const var_obj = vm.VM.asVar(result);
    try testing.expectEqualStrings("some-name", var_obj.name);
    try testing.expect(!var_obj.bound);
}

test "compile source def: (def) → MalformedForm" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(CompileError.MalformedForm, compileSource(arena.allocator(), "(def)"));
}

test "compile source def: (def 42 5) → ExpectedSymbol" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(CompileError.ExpectedSymbol, compileSource(arena.allocator(), "(def 42 5)"));
}

test "compile source def: (defn name) without params → MalformedForm" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(CompileError.MalformedForm, compileSource(arena.allocator(), "(defn f)"));
}

test "compile source def: (var) → MalformedForm" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(CompileError.MalformedForm, compileSource(arena.allocator(), "(var)"));
}

test "compile source def: without namespace, def → UnresolvedSymbol (regression)" {
    // def needs a namespace to live in.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(
        CompileError.UnresolvedSymbol,
        compileSource(arena.allocator(), "(def x 5)"),
    );
}

// ---- intrinsic shadowing edge cases ----

test "compile shadowing: (let* [+ (+ 1 2)] +) → 3 — let* RHS does NOT see own binding" {
    // Sequential RHS visibility: binding-i's RHS sees only
    // 1..i-1. So `(+ 1 2)` inside the RHS of the `+` binding
    // inlines to Tiny.add → 3. Body's `+` returns the function
    // value (the integer 3 itself, since the binding's value
    // IS 3).
    try expectSourceFixnum("(let* [+ (+ 1 2)] +)", 3);
}

test "compile shadowing: ((fn* [+] (+ 1 2)) (fn* [a b] 42)) → 42 — fn param shadows intrinsic" {
    try expectSourceFixnum("((fn* [+] (+ 1 2)) (fn* [a b] 42))", 42);
}

test "compile shadowing: (letfn* [(+ [a b] 42)] (+ 1 2)) → 42 — letfn name shadows intrinsic" {
    try expectSourceFixnum("(letfn* [(+ [a b] 42)] (+ 1 2))", 42);
}

test "compile shadowing: (do (def + (fn* [a b] 42)) (+ 1 2)) → 3 — Vars do not defeat inlining" {
    // Pins the documented limitation: Var-level shadowing
    // does NOT defeat intrinsic inlining (LowerEnv only tracks
    // lexical names, not namespace Vars).
    try expectSourceFixnumWithNs("(do (def + (fn* [a b] 42)) (+ 1 2))", 3);
}

test "compile letfn*: a binding takes a rest param" {
    try expectSourceFixnum("(letfn* [(f [a & r] a)] (f 1 2))", 1);
    try expectSourceFixnum("(letfn* [(f [& r] 7)] (f))", 7);
    try expectSourceFixnum("(letfn* [(f [& r] 7) (g [a & r] (+ a (f)))] (g 1 2 3))", 8);
}

test "compile shadowing: 'foo via compileSource (no interner) → UnsupportedFeature" {
    // Without an Interner, both `'foo` and `(quote foo)` raise
    // UnsupportedFeature symmetrically. compileSourceFull
    // passes an Interner — see the quote symbol tests below.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(
        CompileError.UnsupportedFeature,
        compileSource(arena.allocator(), "'foo"),
    );
}

// ---- Tiny.literal + Interner via compileSourceFull ----

/// Helper: run a source string with both namespace AND interner
/// from a freshly-built VM, return the result. Caller inspects
/// the result; the helper does NOT defer-deinit the VM so the
/// caller controls lifetime (Var-kind / symbol-kind results
/// reference VM-owned storage).
fn runSourceFull(src: []const u8) !struct { result: value_mod.Value, vm_owned: vm.VM } {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(testing.allocator, &stub);
    errdefer v.deinit();
    const ns = v.ensureNamespace();
    const interner = v.ensureInterner();
    const compiled = try compileSourceFull(arena.allocator(), src, ns, interner);
    const routine = compiled.toRoutine("src-full");
    try v.retargetTop(&routine);
    const result = try v.run();
    return .{ .result = result, .vm_owned = v };
}

test "compile quote symbol: (quote foo) with interner returns interned symbol Value" {
    var r = try runSourceFull("(quote foo)");
    defer r.vm_owned.deinit();
    try testing.expect(r.result.kind() == .symbol);
}

test "compile quote symbol: 'foo (reader-macro) with interner returns interned symbol Value" {
    var r = try runSourceFull("'foo");
    defer r.vm_owned.deinit();
    try testing.expect(r.result.kind() == .symbol);
}

test "compile quote symbol: (quote :bar) with interner returns interned keyword Value" {
    var r = try runSourceFull("(quote :bar)");
    defer r.vm_owned.deinit();
    try testing.expect(r.result.kind() == .keyword);
}

test "compile quote symbol: ':bar (reader-macro) with interner returns interned keyword Value" {
    var r = try runSourceFull("':bar");
    defer r.vm_owned.deinit();
    try testing.expect(r.result.kind() == .keyword);
}

test "compile quote symbol: 'foo and 'foo intern to the SAME symbol Value (identity stable)" {
    // Compile two separate programs in the same VM; both intern
    // `foo` through the same Interner; the resulting Values
    // must be identical.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(testing.allocator, &stub);
    defer v.deinit();
    const ns = v.ensureNamespace();
    const interner = v.ensureInterner();

    // First program.
    const c1 = try compileSourceFull(arena.allocator(), "'foo", ns, interner);
    const r1 = c1.toRoutine("p1");
    try v.retargetTop(&r1);
    const v1 = try v.run();

    // Second program — fresh frame, same VM/interner.
    const c2 = try compileSourceFull(arena.allocator(), "'foo", ns, interner);
    const r2 = c2.toRoutine("p2");
    try v.retargetTop(&r2);
    const v2 = try v.run();

    try testing.expect(v1.kind() == .symbol);
    try testing.expect(v2.kind() == .symbol);
    // Interned identity: same tag, same payload.
    try testing.expectEqual(v1.tag, v2.tag);
    try testing.expectEqual(v1.payload, v2.payload);
}

test "compile quote symbol: (quote 42) still uses Tiny.int (no const-pool waste)" {
    // Quoted scalars (nil/bool/int) lower to existing Tiny
    // variants directly. Tiny.literal
    // only fires for quoted symbols/keywords. We verify behavior
    // here by checking that compileSourceFull succeeds and
    // returns the integer.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(testing.allocator, &stub);
    defer v.deinit();
    const interner = v.ensureInterner();
    const compiled = try compileSourceFull(arena.allocator(), "(quote 42)", null, interner);
    const routine = compiled.toRoutine("scalar-quote");
    try v.retargetTop(&routine);
    const result = try v.run();
    try testing.expectEqual(@as(i64, 42), result.asFixnum());
}

test "compile quote symbol: bare :keyword self-evaluates with interner" {
    var r = try runSourceFull(":hello");
    defer r.vm_owned.deinit();
    try testing.expect(r.result.kind() == .keyword);
}

test "compile quote symbol: (if true :yes :no) — bare keywords in if arms" {
    var r = try runSourceFull("(if true :yes :no)");
    defer r.vm_owned.deinit();
    try testing.expect(r.result.kind() == .keyword);
    const id: u32 = @intCast(r.result.payload);
    try testing.expectEqualStrings("yes", r.vm_owned.ensureInterner().keywordName(id));
}

test "compile quote symbol: bare keyword without interner → UnsupportedFeature" {
    // compileSource (no interner) preserves the prior behavior.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(
        CompileError.UnsupportedFeature,
        compileSource(arena.allocator(), ":hello"),
    );
}

// ---- macroexpand integration ---------------------

test "compile macros: empty macro table passes through (sanity)" {
    // compileSourceFullWithMacros with an empty macro table
    // should produce the same result as compileSourceFull.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(testing.allocator, &stub);
    defer v.deinit();
    const interner = v.ensureInterner();
    var host_macros: expand_mod.HostMacroTable = .{};
    defer host_macros.deinit(arena.allocator());
    const compiled = try compileSourceFullWithMacros(
        arena.allocator(),
        "(+ 1 2)",
        null,
        interner,
        &host_macros,
    );
    const routine = compiled.toRoutine("p");
    try v.retargetTop(&routine);
    const result = try v.run();
    try testing.expectEqual(@as(i64, 3), result.asFixnum());
}

test "compile macros: infinite macro loop → MacroDepthExceeded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(testing.allocator, &stub);
    defer v.deinit();
    const interner = v.ensureInterner();

    const Wrap = struct {
        fn loopForever(
            _: *expand_mod.ExpandContext,
            call_form: *const reader_mod.Form,
            _: []const *reader_mod.Form,
        ) expand_mod.ExpandError!*reader_mod.Form {
            return @constCast(call_form);
        }
    };
    var host_macros: expand_mod.HostMacroTable = .{};
    defer host_macros.deinit(arena.allocator());
    try host_macros.put(arena.allocator(), "boom", Wrap.loopForever);

    try testing.expectError(
        CompileError.MacroDepthExceeded,
        compileSourceFullWithMacros(
            arena.allocator(),
            "(boom)",
            null,
            interner,
            &host_macros,
        ),
    );
}

// ---- host core macros end-to-end ------------------

/// Run a source string with default macros + interner + ns.
/// Returns the result Value via the helper VM setup. The VM
/// must outlive any post-call use of the result (interned
/// symbols/keywords reference VM-owned storage).
fn runSourceWithDefaultMacros(src: []const u8) !struct { result: value_mod.Value, vm_owned: vm.VM } {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(testing.allocator, &stub);
    errdefer v.deinit();
    const ns = v.ensureNamespace();
    const interner = v.ensureInterner();
    var host_macros = try expand_mod.defaultMacros(testing.allocator);
    defer host_macros.deinit(testing.allocator);
    const compiled = try compileSourceFullWithMacros(arena.allocator(), src, ns, interner, &host_macros);
    const routine = compiled.toRoutine("p");
    try v.retargetTop(&routine);
    const result = try v.run();
    return .{ .result = result, .vm_owned = v };
}

fn expectFixnumDefaultMacros(src: []const u8, expected: i64) !void {
    var r = try runSourceWithDefaultMacros(src);
    defer r.vm_owned.deinit();
    try testing.expectEqual(expected, r.result.asFixnum());
}

fn expectNilDefaultMacros(src: []const u8) !void {
    var r = try runSourceWithDefaultMacros(src);
    defer r.vm_owned.deinit();
    try testing.expect(r.result.kind() == .nil);
}

fn expectBoolDefaultMacros(src: []const u8, expected: bool) !void {
    var r = try runSourceWithDefaultMacros(src);
    defer r.vm_owned.deinit();
    try testing.expect(r.result.isBool());
    try testing.expectEqual(expected, r.result.asBool());
}

fn expectKeywordDefaultMacros(src: []const u8, expected: []const u8) !void {
    var r = try runSourceWithDefaultMacros(src);
    defer r.vm_owned.deinit();
    try testing.expect(r.result.kind() == .keyword);
    const id: u32 = @intCast(r.result.payload);
    try testing.expectEqualStrings(expected, r.vm_owned.ensureInterner().keywordName(id));
}

// ---- rename macros ----

test "compile core macros: (let [x 1 y 2] (+ x y)) → 3" {
    try expectFixnumDefaultMacros("(let [x 1 y 2] (+ x y))", 3);
}

test "compile core macros: (fn [x] (+ x 1)) renamed to fn*" {
    try expectFixnumDefaultMacros("((fn [x] (+ x 1)) 41)", 42);
}

test "compile core macros: (loop [i 0] ...) renamed to loop*" {
    try expectFixnumDefaultMacros(
        "(loop [i 0 acc 0] (if (< i 5) (recur (+ i 1) (+ acc i)) acc))",
        10,
    );
}

// ---- when / when-not ----

test "compile core macros: (when true 42) → 42" {
    try expectFixnumDefaultMacros("(when true 42)", 42);
}

test "compile core macros: (when false 42) → nil" {
    try expectNilDefaultMacros("(when false 42)");
}

test "compile core macros: (when true 1 2 3) returns last body form" {
    try expectFixnumDefaultMacros("(when true 1 2 3)", 3);
}

test "compile core macros: (when-not false 99) → 99" {
    try expectFixnumDefaultMacros("(when-not false 99)", 99);
}

test "compile core macros: (when-not true 99) → nil" {
    try expectNilDefaultMacros("(when-not true 99)");
}

test "compile core macros: (when) malformed → MacroExpansionFailure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(testing.allocator, &stub);
    defer v.deinit();
    const interner = v.ensureInterner();
    var host_macros = try expand_mod.defaultMacros(testing.allocator);
    defer host_macros.deinit(testing.allocator);
    try testing.expectError(
        CompileError.MacroExpansionFailure,
        compileSourceFullWithMacros(arena.allocator(), "(when)", null, interner, &host_macros),
    );
}

// ---- and ----

test "compile core macros: (and) → true" {
    try expectBoolDefaultMacros("(and)", true);
}

test "compile core macros: (and 42) → 42" {
    try expectFixnumDefaultMacros("(and 42)", 42);
}

test "compile core macros: (and 1 2 3) → 3 (last truthy)" {
    try expectFixnumDefaultMacros("(and 1 2 3)", 3);
}

test "compile core macros: (and 1 false 3) → false (short-circuit)" {
    try expectBoolDefaultMacros("(and 1 false 3)", false);
}

test "compile core macros: (and nil 99) → nil (returns falsy value, not literal false)" {
    // Clojure-style: and returns the FIRST FALSY value, not
    // literal false. Confirms expandAnd uses the let*+gensym
    // shape, not the simpler-but-wrong (if x y false).
    try expectNilDefaultMacros("(and nil 99)");
}

test "compile core macros: (and falsy ...) uses gensym (no double-eval on falsy)" {
    // The classic bad `and` expansion is
    // `(if x y x)`. That double-evals x ONLY when x is falsy
    // (test branch + else branch both evaluate x). So the
    // single-eval test for `and` MUST use a FALSY-returning
    // side effect to catch the bug. (A truthy version would be
    // sound for `or` but would not exercise the right branch
    // for `and`.)
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(testing.allocator, &stub);
    defer v.deinit();
    const ns = v.ensureNamespace();
    const interner = v.ensureInterner();
    var host_macros = try expand_mod.defaultMacros(testing.allocator);
    defer host_macros.deinit(testing.allocator);

    const src =
        \\(do
        \\  (def step-count 0)
        \\  (defn step [] (do (def step-count (+ step-count 1)) nil))
        \\  (and (step) 99)
        \\  step-count)
    ;
    const compiled = try compileSourceFullWithMacros(arena.allocator(), src, ns, interner, &host_macros);
    const routine = compiled.toRoutine("and-gensym-falsy");
    try v.retargetTop(&routine);
    const result = try v.run();
    // step was invoked exactly once even though `and` short-
    // circuited on falsy. The bad `(if x y x)` expansion would
    // produce step-count = 2.
    try testing.expectEqual(@as(i64, 1), result.asFixnum());
}

// ---- Value-semantics pins: catch the
// `and`/`or` bug variants more directly than gensym tests
// alone.

test "compile core macros: (and false 99) → false (returns the FALSE value, not nil)" {
    try expectBoolDefaultMacros("(and false 99)", false);
}

test "compile core macros: (or 0 7) → 0 (zero is truthy in Lisp)" {
    // Only nil and false are falsy in nexis (matches Clojure).
    // A regression that treated 0 as falsy would return 7.
    try expectFixnumDefaultMacros("(or 0 7)", 0);
}

test "compile core macros: (and 0 1) → 1 (zero is truthy → continues)" {
    try expectFixnumDefaultMacros("(and 0 1)", 1);
}

test "compile core macros: (or false nil) → nil (returns LAST falsy when all falsy)" {
    try expectNilDefaultMacros("(or false nil)");
}

// ---- or ----

test "compile core macros: (or) → nil" {
    try expectNilDefaultMacros("(or)");
}

test "compile core macros: (or 42) → 42" {
    try expectFixnumDefaultMacros("(or 42)", 42);
}

test "compile core macros: (or false nil 42) → 42" {
    try expectFixnumDefaultMacros("(or false nil 42)", 42);
}

test "compile core macros: (or 1 2 3) → 1 (first truthy)" {
    try expectFixnumDefaultMacros("(or 1 2 3)", 1);
}

test "compile core macros: (or false false false) → false" {
    try expectBoolDefaultMacros("(or false false false)", false);
}

test "compile core macros: (or expr ...) uses gensym (no double-eval)" {
    // The classic gensym test: a stateful expression that
    // would yield different results if evaluated twice. We
    // model statelessness here via a defn'd Var that counts
    // invocations; `or` should call `step` exactly ONCE per
    // operand position even though the macro expansion
    // structurally references the value twice.
    //
    // (defn step [] (do (def step-count (+ step-count 1)) step-count))
    // (def step-count 0)
    // (or (step) 99)            ; step fires once; step-count = 1
    // step-count                ; → 1, NOT 2
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(testing.allocator, &stub);
    defer v.deinit();
    const ns = v.ensureNamespace();
    const interner = v.ensureInterner();
    var host_macros = try expand_mod.defaultMacros(testing.allocator);
    defer host_macros.deinit(testing.allocator);

    const src =
        \\(do
        \\  (def step-count 0)
        \\  (defn step [] (do (def step-count (+ step-count 1)) step-count))
        \\  (or (step) 99)
        \\  step-count)
    ;
    const compiled = try compileSourceFullWithMacros(arena.allocator(), src, ns, interner, &host_macros);
    const routine = compiled.toRoutine("or-gensym");
    try v.retargetTop(&routine);
    const result = try v.run();
    // step was invoked exactly once, so step-count = 1.
    try testing.expectEqual(@as(i64, 1), result.asFixnum());
}

// ---- cond ----

test "compile core macros: (cond) → nil" {
    try expectNilDefaultMacros("(cond)");
}

test "compile core macros: (cond true 42) → 42" {
    try expectFixnumDefaultMacros("(cond true 42)", 42);
}

test "compile core macros: (cond false 1 true 2 false 3) → 2" {
    try expectFixnumDefaultMacros("(cond false 1 true 2 false 3)", 2);
}

test "compile core macros: (cond false 1 false 2) → nil (no match)" {
    try expectNilDefaultMacros("(cond false 1 false 2)");
}

test "compile core macros: cond with :else convention (truthy keyword)" {
    try expectKeywordDefaultMacros(
        "(cond false :a false :b :else :c)",
        "c",
    );
}

test "compile core macros: (cond odd-args) → MacroExpansionFailure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(testing.allocator, &stub);
    defer v.deinit();
    const interner = v.ensureInterner();
    var host_macros = try expand_mod.defaultMacros(testing.allocator);
    defer host_macros.deinit(testing.allocator);
    try testing.expectError(
        CompileError.MacroExpansionFailure,
        compileSourceFullWithMacros(arena.allocator(), "(cond true)", null, interner, &host_macros),
    );
}

// ---- thread-first / thread-last ----

test "compile core macros: (-> 10) → 10 (single-arg)" {
    try expectFixnumDefaultMacros("(-> 10)", 10);
}

test "compile core macros: (-> 1 (+ 2)) → 3 (thread-first)" {
    try expectFixnumDefaultMacros("(-> 1 (+ 2))", 3);
}

test "compile core macros: (-> 1 (+ 2) (+ 3)) chained → 6" {
    try expectFixnumDefaultMacros("(-> 1 (+ 2) (+ 3))", 6);
}

test "compile core macros: (->> 1 (+ 2) (+ 3)) thread-last → 6" {
    // (+ x y) is commutative so first/last give same result here;
    // semantic difference is tested in the asymmetric arg case
    // below.
    try expectFixnumDefaultMacros("(->> 1 (+ 2) (+ 3))", 6);
}

test "compile core macros: -> with symbol step treats it as (step)" {
    // (-> 41 inc) where inc is a fn — symbol step inserts the
    // threaded value as the sole arg. The compile tests run
    // without the stdlib installed, so `inc` is defined inline.
    try expectFixnumDefaultMacros(
        "(do (defn inc [x] (+ x 1)) (-> 41 inc))",
        42,
    );
}

// ---- shadowing ----

test "compile core macros: macros are lexically shadowable" {
    // (let [when 99] when) — `when` is shadowed by a let binding,
    // so the inner `when` resolves to the local, NOT the macro.
    try expectFixnumDefaultMacros("(let [when 99] when)", 99);
}

test "compile core macros: nested macros expand correctly" {
    try expectKeywordDefaultMacros(
        "(when (and 1 2) (or false :yes))",
        "yes",
    );
}

// ---- quoted compound + #%list / #%concat ----

test "compile quote list: (quote (1 2 3)) returns list [1 2 3]" {
    var r = try runSourceFull("(quote (1 2 3))");
    defer r.vm_owned.deinit();
    try testing.expect(r.result.kind() == .list);
    try testing.expect(!list_mod.isEmpty(r.result));
    try testing.expectEqual(@as(i64, 1), list_mod.head(r.result).asFixnum());
    const t1 = list_mod.tail(r.result);
    try testing.expectEqual(@as(i64, 2), list_mod.head(t1).asFixnum());
    const t2 = list_mod.tail(t1);
    try testing.expectEqual(@as(i64, 3), list_mod.head(t2).asFixnum());
    try testing.expect(list_mod.isEmpty(list_mod.tail(t2)));
}

test "compile quote list: (quote ()) returns the empty list" {
    var r = try runSourceFull("(quote ())");
    defer r.vm_owned.deinit();
    try testing.expect(r.result.kind() == .list);
    try testing.expect(list_mod.isEmpty(r.result));
}

test "compile quote list: '(1 2 3) reader-macro form works same as (quote (1 2 3))" {
    var r = try runSourceFull("'(1 2 3)");
    defer r.vm_owned.deinit();
    try testing.expect(r.result.kind() == .list);
    try testing.expectEqual(@as(i64, 1), list_mod.head(r.result).asFixnum());
}

test "compile quote list: (quote (foo)) — interned symbol inside list" {
    var r = try runSourceFull("(quote (foo))");
    defer r.vm_owned.deinit();
    try testing.expect(r.result.kind() == .list);
    const h = list_mod.head(r.result);
    try testing.expect(h.kind() == .symbol);
}

test "compile quote list: (quote (:a :b)) — keywords inside list" {
    var r = try runSourceFull("(quote (:a :b))");
    defer r.vm_owned.deinit();
    try testing.expect(r.result.kind() == .list);
    const h = list_mod.head(r.result);
    try testing.expect(h.kind() == .keyword);
}

test "compile quote list: (quote (1 (2 3) 4)) — nested lists" {
    var r = try runSourceFull("(quote (1 (2 3) 4))");
    defer r.vm_owned.deinit();
    try testing.expect(r.result.kind() == .list);
    // First element is 1.
    try testing.expectEqual(@as(i64, 1), list_mod.head(r.result).asFixnum());
    // Second element is the nested list (2 3).
    const inner = list_mod.head(list_mod.tail(r.result));
    try testing.expect(inner.kind() == .list);
    try testing.expectEqual(@as(i64, 2), list_mod.head(inner).asFixnum());
    try testing.expectEqual(@as(i64, 3), list_mod.head(list_mod.tail(inner)).asFixnum());
    // Third element is 4.
    const fourth = list_mod.head(list_mod.tail(list_mod.tail(r.result)));
    try testing.expectEqual(@as(i64, 4), fourth.asFixnum());
}

// ---- syntax-quote / unquote / splice / gensym ----

test "compile syntax-quote: `(1 2 3) builds (1 2 3)" {
    var r = try runSourceFull("`(1 2 3)");
    defer r.vm_owned.deinit();
    try testing.expect(r.result.kind() == .list);
    try testing.expectEqual(@as(i64, 1), list_mod.head(r.result).asFixnum());
    try testing.expectEqual(@as(i64, 2), list_mod.head(list_mod.tail(r.result)).asFixnum());
    try testing.expectEqual(@as(i64, 3), list_mod.head(list_mod.tail(list_mod.tail(r.result))).asFixnum());
}

test "compile syntax-quote: `() builds empty list" {
    var r = try runSourceFull("`()");
    defer r.vm_owned.deinit();
    try testing.expect(r.result.kind() == .list);
    try testing.expect(list_mod.isEmpty(r.result));
}

test "compile syntax-quote: `foo → interned symbol via (quote foo)" {
    var r = try runSourceFull("`foo");
    defer r.vm_owned.deinit();
    try testing.expect(r.result.kind() == .symbol);
}

test "compile syntax-quote: `:bar self-evaluates" {
    var r = try runSourceFull("`:bar");
    defer r.vm_owned.deinit();
    try testing.expect(r.result.kind() == .keyword);
}

test "compile syntax-quote: `(value ~x) — simple unquote" {
    // Walk the resulting list directly (the compile tests run
    // without the stdlib installed).
    // Source: (let [x 42] `(value ~x)) → (value 42)
    var r = try runSourceFull(
        \\(let* [x 42] `(value ~x))
    );
    defer r.vm_owned.deinit();
    try testing.expect(r.result.kind() == .list);
    const sym = list_mod.head(r.result);
    try testing.expect(sym.kind() == .symbol);
    const tail = list_mod.tail(r.result);
    try testing.expectEqual(@as(i64, 42), list_mod.head(tail).asFixnum());
    try testing.expect(list_mod.isEmpty(list_mod.tail(tail)));
}

test "compile syntax-quote: ~@xs splices a list" {
    // `(a ~@xs b) → list with xs's elements between a and b.
    var r = try runSourceFull(
        \\(let* [xs (quote (1 2 3))]
        \\  `(start ~@xs end))
    );
    defer r.vm_owned.deinit();
    try testing.expect(r.result.kind() == .list);
    // Result: (start 1 2 3 end) — 5 elements.
    const h = list_mod.head(r.result);
    try testing.expect(h.kind() == .symbol);
    var node = list_mod.tail(r.result);
    try testing.expectEqual(@as(i64, 1), list_mod.head(node).asFixnum());
    node = list_mod.tail(node);
    try testing.expectEqual(@as(i64, 2), list_mod.head(node).asFixnum());
    node = list_mod.tail(node);
    try testing.expectEqual(@as(i64, 3), list_mod.head(node).asFixnum());
    node = list_mod.tail(node);
    try testing.expect(list_mod.head(node).kind() == .symbol);
    try testing.expect(list_mod.isEmpty(list_mod.tail(node)));
}

test "compile syntax-quote: auto-gensym — `(g# g#) — both refs share same gensym" {
    // Output list should be (g__N__auto__ g__N__auto__) for the
    // same N. We assert the two symbols are IDENTITY-EQUAL.
    var r = try runSourceFull("`(g# g#)");
    defer r.vm_owned.deinit();
    try testing.expect(r.result.kind() == .list);
    const s1 = list_mod.head(r.result);
    const s2 = list_mod.head(list_mod.tail(r.result));
    try testing.expect(s1.kind() == .symbol);
    try testing.expect(s2.kind() == .symbol);
    // Interned symbols have identical (tag, payload) for equal names.
    try testing.expectEqual(s1.tag, s2.tag);
    try testing.expectEqual(s1.payload, s2.payload);
}

test "compile syntax-quote: two separate syntax-quotes get DIFFERENT gensyms" {
    // Two adjacent `g# in DIFFERENT syntax-quote scopes must
    // produce different gensyms. Walk both via #%list to compare.
    var r = try runSourceFull("`(~`g# ~`g#)");
    defer r.vm_owned.deinit();
    try testing.expect(r.result.kind() == .list);
    const s1 = list_mod.head(r.result);
    const s2 = list_mod.head(list_mod.tail(r.result));
    // Different gensym → different payload (different InternId).
    try testing.expect(s1.payload != s2.payload);
}

test "compile syntax-quote: unquote outside syntax-quote → MacroExpansionFailure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(testing.allocator, &stub);
    defer v.deinit();
    const interner = v.ensureInterner();
    // Reader actually catches this at parse time; we get
    // ReaderFailure not MacroExpansionFailure. Document that
    // the macroexpand-time defense is a belt-and-suspenders
    // check for macro-host fns that might synthesize forms.
    try testing.expectError(
        CompileError.ReaderFailure,
        compileSourceFull(arena.allocator(), "~x", null, interner),
    );
}

// ---- vector support (coll:vector + #%vector) ----

test "compile quote vector: (quote [1 2 3]) builds a persistent vector" {
    var r = try runSourceFull("(quote [1 2 3])");
    defer r.vm_owned.deinit();
    try testing.expect(r.result.kind() == .persistent_vector);
    const vec_mod = @import("vector");
    try testing.expectEqual(@as(usize, 3), vec_mod.count(r.result));
    try testing.expectEqual(@as(i64, 1), vec_mod.nth(r.result, 0).asFixnum());
    try testing.expectEqual(@as(i64, 2), vec_mod.nth(r.result, 1).asFixnum());
    try testing.expectEqual(@as(i64, 3), vec_mod.nth(r.result, 2).asFixnum());
}

test "compile quote vector: (quote []) builds empty vector" {
    var r = try runSourceFull("(quote [])");
    defer r.vm_owned.deinit();
    try testing.expect(r.result.kind() == .persistent_vector);
    const vec_mod = @import("vector");
    try testing.expectEqual(@as(usize, 0), vec_mod.count(r.result));
}

test "compile quote vector: `[~x ~y] syntax-quote with unquote" {
    var r = try runSourceFull(
        \\(let* [x 10 y 20] `[~x ~y])
    );
    defer r.vm_owned.deinit();
    try testing.expect(r.result.kind() == .persistent_vector);
    const vec_mod = @import("vector");
    try testing.expectEqual(@as(usize, 2), vec_mod.count(r.result));
    try testing.expectEqual(@as(i64, 10), vec_mod.nth(r.result, 0).asFixnum());
    try testing.expectEqual(@as(i64, 20), vec_mod.nth(r.result, 1).asFixnum());
}

test "compile quote vector: nested vector in quoted list" {
    var r = try runSourceFull("(quote (a [1 2] b))");
    defer r.vm_owned.deinit();
    try testing.expect(r.result.kind() == .list);
    // First element: symbol a
    try testing.expect(list_mod.head(r.result).kind() == .symbol);
    // Second element: vector [1 2]
    const second = list_mod.head(list_mod.tail(r.result));
    try testing.expect(second.kind() == .persistent_vector);
    const vec_mod = @import("vector");
    try testing.expectEqual(@as(usize, 2), vec_mod.count(second));
}

// ---- maps/sets as runtime values ----------------

test "compile map/set literals: (quote {}) builds the empty persistent map" {
    var r = try runSourceFull("(quote {})");
    defer r.vm_owned.deinit();
    try testing.expect(r.result.kind() == .persistent_map);
    const cm = @import("champ");
    try testing.expectEqual(@as(usize, 0), cm.mapCount(r.result));
}

test "compile map/set literals: (quote {:a 1 :b 2}) builds 2-entry map" {
    var r = try runSourceFull("(quote {:a 1 :b 2})");
    defer r.vm_owned.deinit();
    try testing.expect(r.result.kind() == .persistent_map);
    const cm = @import("champ");
    try testing.expectEqual(@as(usize, 2), cm.mapCount(r.result));
}

test "compile map/set literals: runtime-computed duplicate key — later wins (Clojure semantics)" {
    // Two map keys both evaluate to :a at runtime; the second
    // value (2) wins. The reader catches STATIC duplicates
    // (`{:a 1 :a 2}` → ReaderFailure) but lets computed
    // duplicates through to runtime.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(testing.allocator, &stub);
    defer v.deinit();
    const interner = v.ensureInterner();
    const src = "(let* [k :a k2 :a] {k 1 k2 2})";
    const compiled = try compileSourceFull(arena.allocator(), src, null, interner);
    const routine = compiled.toRoutine("dup-key-runtime");
    try v.retargetTop(&routine);
    const result = try v.run();
    try testing.expect(result.kind() == .persistent_map);
    const cm = @import("champ");
    try testing.expectEqual(@as(usize, 1), cm.mapCount(result));
    const dispatch = @import("dispatch");
    const kw_id = try interner.internKeyword("a");
    const kw_val = value_mod.fromKeywordId(kw_id);
    const looked_up = cm.mapGet(result, kw_val, &dispatch.hashValue, &dispatch.equal);
    try testing.expect(looked_up == .present);
    try testing.expectEqual(@as(i64, 2), looked_up.present.asFixnum());
}

test "compile map/set literals: static duplicate key {:a 1 :a 2} → ReaderFailure" {
    // The READER catches static duplicate keys with
    // `duplicate_literal_key`. Runtime never sees this case
    // via source literals; the "later wins" semantics applies
    // only to runtime-computed keys.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(testing.allocator, &stub);
    defer v.deinit();
    const interner = v.ensureInterner();
    try testing.expectError(
        CompileError.ReaderFailure,
        compileSourceFull(arena.allocator(), "{:a 1 :a 2}", null, interner),
    );
}

test "compile map/set literals: (quote #{}) builds the empty persistent set" {
    var r = try runSourceFull("(quote #{})");
    defer r.vm_owned.deinit();
    try testing.expect(r.result.kind() == .persistent_set);
    const cm = @import("champ");
    try testing.expectEqual(@as(usize, 0), cm.setCount(r.result));
}

test "compile map/set literals: (quote #{1 2 3}) builds 3-element set" {
    var r = try runSourceFull("(quote #{1 2 3})");
    defer r.vm_owned.deinit();
    try testing.expect(r.result.kind() == .persistent_set);
    const cm = @import("champ");
    try testing.expectEqual(@as(usize, 3), cm.setCount(r.result));
}

test "compile map/set literals: runtime-computed duplicate elem — set collapses" {
    // The reader catches static `#{1 1 2}` as
    // duplicate_literal_element. Runtime sees this only via
    // computed elements; here both elements evaluate to 1.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(testing.allocator, &stub);
    defer v.deinit();
    const interner = v.ensureInterner();
    const src = "(let* [a 1 b 1] #{a b 2})";
    const compiled = try compileSourceFull(arena.allocator(), src, null, interner);
    const routine = compiled.toRoutine("dup-elem-runtime");
    try v.retargetTop(&routine);
    const result = try v.run();
    try testing.expect(result.kind() == .persistent_set);
    const cm = @import("champ");
    try testing.expectEqual(@as(usize, 2), cm.setCount(result));
}

test "compile map/set literals: static duplicate set elem #{1 1 2} → ReaderFailure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(testing.allocator, &stub);
    defer v.deinit();
    const interner = v.ensureInterner();
    try testing.expectError(
        CompileError.ReaderFailure,
        compileSourceFull(arena.allocator(), "#{1 1 2}", null, interner),
    );
}

test "compile map/set literals: runtime map literal {k1 v1} — value expressions evaluated" {
    // Demonstrate that map values can be arbitrary expressions
    // (here: (+ 1 2)), not just literals.
    var r = try runSourceFull("(let* [n 42] {:answer n})");
    defer r.vm_owned.deinit();
    try testing.expect(r.result.kind() == .persistent_map);
    const cm = @import("champ");
    try testing.expectEqual(@as(usize, 1), cm.mapCount(r.result));
    const dispatch = @import("dispatch");
    const kw_id = try r.vm_owned.ensureInterner().internKeyword("answer");
    const kw_val = value_mod.fromKeywordId(kw_id);
    const got = cm.mapGet(r.result, kw_val, &dispatch.hashValue, &dispatch.equal);
    try testing.expect(got == .present);
    try testing.expectEqual(@as(i64, 42), got.present.asFixnum());
}

test "compile map/set literals: (quote {k {:nested :map}}) — nested quoted maps" {
    var r = try runSourceFull("(quote {:outer {:inner 1}})");
    defer r.vm_owned.deinit();
    try testing.expect(r.result.kind() == .persistent_map);
    const cm = @import("champ");
    const dispatch = @import("dispatch");
    const interner = r.vm_owned.ensureInterner();
    const outer_id = try interner.internKeyword("outer");
    const inner_map = cm.mapGet(r.result, value_mod.fromKeywordId(outer_id), &dispatch.hashValue, &dispatch.equal);
    try testing.expect(inner_map == .present);
    try testing.expect(inner_map.present.kind() == .persistent_map);
}
// ---- try / catch / throw end-to-end ----------

test "compile try: (try 42 (catch any e e)) → 42" {
    try expectFixnumDefaultMacros("(try 42 (catch any e e))", 42);
}

test "compile try: (try (throw 7) (catch any e e)) → 7" {
    try expectFixnumDefaultMacros("(try (throw 7) (catch any e e))", 7);
}

test "compile try: throw propagates a keyword value" {
    try expectKeywordDefaultMacros("(try (throw :boom) (catch any e e))", "boom");
}

test "compile try: cross-frame throw (callee throws, caller catches)" {
    try expectFixnumDefaultMacros(
        \\(do
        \\  (defn f [] (throw 99))
        \\  (try (f) (catch any e e)))
    ,
        99,
    );
}

test "compile try: catch body's own throw NOT re-caught by same handler" {
    // The classic trap: (try (throw :a) (catch any e (throw :b))) must
    // propagate :b as uncaught — the inner throw cannot loop
    // back to the same catch handler.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(testing.allocator, &stub);
    defer v.deinit();
    const ns = v.ensureNamespace();
    const interner = v.ensureInterner();
    var host_macros = try expand_mod.defaultMacros(testing.allocator);
    defer host_macros.deinit(testing.allocator);
    const compiled = try compileSourceFullWithMacros(
        arena.allocator(),
        "(try (throw :a) (catch any e (throw :b)))",
        ns,
        interner,
        &host_macros,
    );
    const routine = compiled.toRoutine("p");
    try v.retargetTop(&routine);
    try testing.expectError(vm.VmError.UncaughtThrow, v.run());
    // The unhandled value is :b, not :a.
    try testing.expect(v.unhandled_throw != null);
    try testing.expect(v.unhandled_throw.?.kind() == .keyword);
}

test "compile try: unhandled top-level throw → UncaughtThrow" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(testing.allocator, &stub);
    defer v.deinit();
    const interner = v.ensureInterner();
    var host_macros = try expand_mod.defaultMacros(testing.allocator);
    defer host_macros.deinit(testing.allocator);
    const compiled = try compileSourceFullWithMacros(
        arena.allocator(),
        "(throw 13)",
        null,
        interner,
        &host_macros,
    );
    const routine = compiled.toRoutine("p");
    try v.retargetTop(&routine);
    try testing.expectError(vm.VmError.UncaughtThrow, v.run());
    try testing.expectEqual(@as(i64, 13), v.unhandled_throw.?.asFixnum());
}

test "compile try: handler binding visible in handler body" {
    // The catch body adds 1 to the thrown value.
    try expectFixnumDefaultMacros(
        \\(try (throw 41) (catch any e (+ e 1)))
    ,
        42,
    );
}

test "compile try: try without catch or finally is its body" {
    var r = try runSourceWithDefaultMacros("(try 1)");
    defer r.vm_owned.deinit();
    try testing.expectEqual(@as(i64, 1), r.result.asFixnum());
}

test "compile try: the primitive accepts only the any matcher" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(CompileError.UnsupportedFeature, compileSource(arena.allocator(), "(try 1 (catch :my-error e e))"));
}

test "compile try: a symbol matcher other than any is a macro error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(testing.allocator, &stub);
    defer v.deinit();
    const interner = v.ensureInterner();
    var host_macros = try expand_mod.defaultMacros(testing.allocator);
    defer host_macros.deinit(testing.allocator);
    try testing.expectError(
        CompileError.MacroExpansionFailure,
        compileSourceFullWithMacros(arena.allocator(), "(try 1 (catch Exception e e))", null, interner, &host_macros),
    );
}

test "compile try: nested try — outer catches what inner doesn't" {
    try expectFixnumDefaultMacros(
        \\(try
        \\  (try (throw 100) (catch any e (throw e)))
        \\  (catch any e e))
    ,
        100,
    );
}

test "compile try: handler stack doesn't leak across normal exits" {
    // (do (try 1 (catch any e 2)) (throw :x)) — the second
    // throw must NOT be caught by the popped try handler.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(testing.allocator, &stub);
    defer v.deinit();
    const interner = v.ensureInterner();
    var host_macros = try expand_mod.defaultMacros(testing.allocator);
    defer host_macros.deinit(testing.allocator);
    const compiled = try compileSourceFullWithMacros(
        arena.allocator(),
        "(do (try 1 (catch any e 2)) (throw :x))",
        null,
        interner,
        &host_macros,
    );
    const routine = compiled.toRoutine("p");
    try v.retargetTop(&routine);
    try testing.expectError(vm.VmError.UncaughtThrow, v.run());
}

// ---- SrcSpan in compile error reports ----------

test "compile span: out_span set on macro expansion failure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(testing.allocator, &stub);
    defer v.deinit();
    const interner = v.ensureInterner();
    var host_macros = try expand_mod.defaultMacros(testing.allocator);
    defer host_macros.deinit(testing.allocator);

    var span: ?reader_mod.SrcSpan = null;
    const result = compileSourceFullWithMacrosSpan(
        arena.allocator(),
        "(when)", // malformed: when needs a test
        null,
        interner,
        &host_macros,
        &span,
    );
    try testing.expectError(CompileError.MacroExpansionFailure, result);
    // Span surfaced — pointing at or near the offending form.
    // Exact pos byte depends on reader's origin convention; we
    // just confirm it's set and within source bounds.
    try testing.expect(span != null);
    try testing.expect(span.?.pos < 10);
}

test "compile span: out_span on malformed if" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(testing.allocator, &stub);
    defer v.deinit();
    const interner = v.ensureInterner();
    var host_macros = try expand_mod.defaultMacros(testing.allocator);
    defer host_macros.deinit(testing.allocator);
    var span: ?reader_mod.SrcSpan = null;
    const result = compileSourceFullWithMacrosSpan(
        arena.allocator(),
        "(if)",
        null,
        interner,
        &host_macros,
        &span,
    );
    try testing.expectError(CompileError.MacroExpansionFailure, result);
    try testing.expect(span != null);
}

test "compile span: compileSourceFullWithMacros compiles a source string" {
    // The entry point without out_span delegates to the Span
    // variant with null out_span.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(testing.allocator, &stub);
    defer v.deinit();
    const interner = v.ensureInterner();
    var host_macros = try expand_mod.defaultMacros(testing.allocator);
    defer host_macros.deinit(testing.allocator);
    const result = compileSourceFullWithMacros(
        arena.allocator(),
        "(when)",
        null,
        interner,
        &host_macros,
    );
    try testing.expectError(CompileError.MacroExpansionFailure, result);
}

test "compile qualified: qualified symbol in quote interns full ns/name" {
    // Qualified symbols round-trip through the
    // interner as the full `ns/name` string. valueToForm splits
    // them back into ns + name on the way out.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(testing.allocator, &stub);
    defer v.deinit();
    const interner = v.ensureInterner();
    const compiled = try compileSourceFull(arena.allocator(), "'foo/bar", null, interner);
    const routine = compiled.toRoutine("test");
    try v.retargetTop(&routine);
    const result = try v.run();
    try testing.expectEqual(value_mod.Kind.symbol, result.kind());
    const id: u32 = @intCast(result.payload);
    try testing.expectEqualStrings("foo/bar", interner.symbolName(id));
}

test "compile: arena cleanup releases code+consts atomically" {
    // End-to-end allocation discipline check — multiple programs
    // through one arena, all run before the arena drops.
    // `std.testing.allocator` (the GPA backing the arena) screams
    // on leak.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const cases = [_]struct { form: Tiny, expected: i64 }{
        .{ .form = .{ .int = 42 }, .expected = 42 },
        .{ .form = .{ .add = .{ .lhs = &.{ .int = 100 }, .rhs = &.{ .int = 200 } } }, .expected = 300 },
        .{ .form = .{ .if_ = .{ .test_ = &.{ .bool = true }, .then = &.{ .int = 7 }, .else_ = &.{ .int = 13 } } }, .expected = 7 },
        .{ .form = .{ .if_ = .{ .test_ = &.{ .nil = {} }, .then = &.{ .int = 7 }, .else_ = &.{ .int = 13 } } }, .expected = 13 },
    };

    for (cases) |tc| {
        const compiled = try compileTiny(arena.allocator(), &tc.form);
        const routine = compiled.toRoutine("batch");
        var v = try vm.VM.init(testing.allocator, &routine);
        defer v.deinit();
        const result = try v.run();
        try testing.expectEqual(tc.expected, result.asFixnum());
    }
}

// ---- declared-name checking ----

/// Compile `src` with `declared` in force in the VM's bare namespace
/// (no core installed), so a symbol resolves only lexically, by
/// declaration, or by a `def` the program itself ran.
fn compileChecked(arena: std.mem.Allocator, v: *vm.VM, src: []const u8, declared: *DeclaredNames, span: *?reader_mod.SrcSpan) anyerror!Compiled {
    var host_macros = try expand_mod.defaultMacros(testing.allocator);
    defer host_macros.deinit(testing.allocator);
    return compileSourceFullWithMacrosSpanPersistentRegistryLoader(
        arena,
        src,
        v.ensureNamespace(),
        v.ensureInterner(),
        &host_macros,
        span,
        null,
        null,
        null,
        declared,
    );
}

test "declared names: an unresolved symbol is reported at its own span" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(testing.allocator, &stub);
    defer v.deinit();
    var declared = DeclaredNames.init(testing.allocator);
    defer declared.deinit();

    const src = "(fn* [x] (let* [z 1] (+ x (< z y))))";
    var span: ?reader_mod.SrcSpan = null;
    try testing.expectError(CompileError.UnresolvedSymbol, compileChecked(arena.allocator(), &v, src, &declared, &span));
    const sp = span orelse return error.TestFailed;
    try testing.expectEqualStrings("y", src[sp.pos .. sp.pos + sp.len]);

    // Declaring it makes the same source compile.
    try declared.declare("y");
    _ = try compileChecked(arena.allocator(), &v, src, &declared, &span);
}

test "declared names: lexical bindings, quoted data and same-form definitions resolve" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(testing.allocator, &stub);
    defer v.deinit();
    var span: ?reader_mod.SrcSpan = null;

    const ok_sources = [_][]const u8{
        "(let* [g 1] g)",
        "(fn* [a & more] more)",
        "(loop* [i 0] (if i i (recur i)))",
        "(letfn* [(a [n] (b n)) (b [n] n)] (a 1))",
        "(try 1 (catch any e e))",
        "(quote (a b c))",
        "(do (def a (fn* [] (b))) (def b 1))",
        "(do (defn c [] (d)) (defn d [] 1))",
        "(fn* self [n] (self n))",
    };
    for (ok_sources) |src| {
        var declared = DeclaredNames.init(testing.allocator);
        defer declared.deinit();
        _ = compileChecked(arena.allocator(), &v, src, &declared, &span) catch |err| {
            std.debug.print("\n  source: {s}\n  error: {s}\n", .{ src, @errorName(err) });
            return err;
        };
    }
}

test "declared names: declareForm collects def/defn/defmacro/defrecord/defprotocol through do" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "(do (def a 1) (defn b [] 2) (defmacro c [] 3) (defrecord R [x]) (defprotocol P (m [s]) (n [s])) (println z))";
    var p = try reader_mod.parser.parseForm(arena.allocator(), src);
    defer p.parser.deinit();
    var reader = reader_mod.Reader.init(arena.allocator(), src);
    defer reader.deinit();
    const form = try reader.readOneForm(p.sexp);

    var declared = DeclaredNames.init(testing.allocator);
    defer declared.deinit();
    try declared.declareForm(form);
    for ([_][]const u8{ "a", "b", "c", "R", "R-type-id", "->R", "map->R", "R?", "P", "m", "n" }) |name| {
        try testing.expect(declared.contains(name));
    }
    try testing.expect(!declared.contains("z"));
    try testing.expect(!declared.contains("println"));
}

// ---- PC → span table ----------

test "span table: entries ascend from pc 0, cover the source and carry the form's span" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "(if true (+ 1 2) 3)";
    const info = vm.SourceInfo{ .path = "t.nx", .text = src };
    const compiled = try compileSourceWith(arena.allocator(), src, .{ .source = &info });
    try testing.expect(compiled.spans.len > 0);
    try testing.expectEqual(@as(u32, 0), compiled.spans[0].pc);
    var prev: u32 = 0;
    for (compiled.spans, 0..) |entry, i| {
        if (i > 0) try testing.expect(entry.pc > prev);
        prev = entry.pc;
        try testing.expect(entry.span.pos + entry.span.len <= src.len);
    }
    const origin = compiled.origin orelse return error.TestFailed;
    try testing.expectEqualStrings("(if true (+ 1 2) 3)", src[origin.pos .. origin.pos + origin.len]);
    try testing.expect(compiled.source == &info);
    // Every instruction resolves, and the inlined `math:add` carries
    // the span of `(+ 1 2)`.
    const routine = compiled.toRoutine("t");
    var saw_add = false;
    for (routine.code, 0..) |inst, pc| {
        const span = routine.spanAt(@intCast(pc)) orelse return error.TestFailed;
        if (inst.groupOf() == .math) {
            try testing.expectEqualStrings("(+ 1 2)", src[span.pos .. span.pos + span.len]);
            saw_add = true;
        }
    }
    try testing.expect(saw_add);
    try testing.expect(routine.spanAt(@intCast(routine.code.len + 10)) != null);
}

test "span table: a nested routine carries its own table, origin and name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var v = try vm.VM.init(testing.allocator, &stub_routine_for_spans);
    defer v.deinit();
    const ns = v.ensureNamespace();
    const src = "(defn sq [x]\n  (* x x))";
    const compiled = try compileSourceWith(arena.allocator(), src, .{ .namespace = ns, .interner = v.ensureInterner() });
    var child: ?*const vm.Routine = null;
    for (compiled.consts) |c| if (c == .routine) {
        child = c.routine;
    };
    const r = child orelse return error.TestFailed;
    try testing.expectEqualStrings("sq", r.name);
    try testing.expect(r.spans.len > 0);
    const origin = r.origin orelse return error.TestFailed;
    try testing.expectEqualStrings("(defn sq [x]\n  (* x x))", src[origin.pos .. origin.pos + origin.len]);
    // The body's call carries the span of `(* x x)`; the return
    // after it carries the fn's.
    const last = r.spanAt(@intCast(r.code.len - 2)) orelse return error.TestFailed;
    try testing.expectEqualStrings("(* x x)", src[last.pos .. last.pos + last.len]);
}

test "span table: a hand-built Tiny compiles with no table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const form = Tiny{ .int = 7 };
    const compiled = try compileTiny(arena.allocator(), &form);
    try testing.expectEqual(@as(usize, 0), compiled.spans.len);
    try testing.expect(compiled.toRoutine("t").spanAt(0) == null);
}

const stub_code_for_spans = [_]vm.Inst{vm.asm_.returnNil()};
const stub_routine_for_spans = vm.Routine{ .code = &stub_code_for_spans, .consts = &.{}, .slot_count = 1 };
