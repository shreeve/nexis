//! compile.zig — Phase 2 tiny compiler (steps #2 + #3 + #4).
//!
//! Authoritative spec: `docs/COMPILER.md` §10 #2-#4.
//!
//! **Currently implemented**:
//!
//!   - integer literal           →  `mov:load-const + call:return`
//!   - boolean literal           →  `mov:load-true / mov:load-false + call:return`
//!   - nil literal               →  `mov:load-nil + call:return`
//!   - `(+ <expr> <expr>)`       →  recursive sub-expression lowering;
//!                                  literal-pair peephole emits direct
//!                                  `math:add c, c` per peer-AI turn 33
//!   - `(if <test> <then> <else?>)` → `jump:if-false` over then,
//!                                  unconditional `jump:jmp` past else,
//!                                  with simple PC back-patching per
//!                                  peer-AI turn 36; absent else branch
//!                                  synthesizes nil
//!   - **`<symbol>`**             →  resolves to a lexical local in the
//!                                  Emitter's scope stack; emits
//!                                  `mov:move dst, slot[N]` (no-op when
//!                                  source slot already equals dst)
//!   - **`(let* [n1 v1, ...] body)`** → strict left-of-self-visibility
//!                                  per COMPILER.md §4.3 (binding-i's
//!                                  RHS sees bindings 1..i-1 only);
//!                                  `defer scope.shrinkRetainingCapacity(mark)`
//!                                  pops bindings on let-body exit
//!   - **`(do e1 e2 ... eN)`**    →  empty → nil; one-expr → compile
//!                                  to dst; multi-expr → all non-last
//!                                  to a SHARED discard slot (peer-AI
//!                                  turn 38: avoids 999-slot blowup
//!                                  for `(do e1 ... e1000)`), last
//!                                  to dst
//!
//! **Architecture**: destination-driven internal lowering per peer-AI
//! turn 36. The public entry point `compileTiny()` returns a
//! `Compiled` artifact ready for `vm.VM.init`. Internally, an
//! `Emitter` accumulates code + consts + slot_count, and each form's
//! `compileExpr(emitter, form, dst)` lowers to write its result into
//! the caller-chosen destination slot. This is the right shape for
//! `if`-arms targeting a shared dst, and it's what step #4 (`let*`)
//! will continue building on.
//!
//! **What's deferred**:
//!   - Real `reader.Form` input. `Tiny` is the bootstrap shape;
//!     replacement happens with the macroexpander commit (step #8)
//!     or the resolver commit (step #7), whichever exposes the
//!     analyzer-output IR first.
//!   - Variadic `+` (`(+ a b c d)` reducing to chained adds).
//!   - Other arithmetic primitives (`-`, `*`, `/`, etc.).
//!   - Slot lifetime analysis / liveness-based reuse. The current
//!     allocator is monotonic: each fresh result slot bumps
//!     `slot_count`. Branch-local temps are not reclaimed across
//!     the merge point (acceptable per peer-AI turn 36).
//!   - Conditionals, function definitions, closures, `recur`,
//!     namespaces, macros — all per `COMPILER.md` §10 #4-#11.

const std = @import("std");
const vm = @import("vm");
const value_mod = @import("value");
/// Step 5e (tests only): inspect rest-list results in variadic
/// fn tests. The compiler itself doesn't depend on list — the
/// VM constructs rest lists at call time per VM.md §6.
const list_mod = @import("list");
/// Step #7a: consume reader.Form trees as compiler input. The
/// `lowerForm` function translates Form → Tiny (the existing IR);
/// the backend stays unchanged (peer-AI turn 51 — Tiny is the IR,
/// not a parallel codegen path).
const reader_mod = @import("reader");

pub const Inst = vm.Inst;
pub const Routine = vm.Routine;
pub const Operand = vm.Operand;
pub const Value = value_mod.Value;

// =============================================================================
// Tiny — the input AST for this commit's compiler.
//
// Recursive shape per peer-AI turn 36. Step #3 added `nil`, `bool`,
// `if_`, and made `add`'s operands recursive. Sub-expressions are
// pointers (the compile-time arena owns them). Hand-construction in
// tests uses `&Tiny{ ... }` literals.
// =============================================================================

pub const Tiny = union(enum) {
    /// nil literal.
    nil,
    /// boolean literal (true / false).
    bool: bool,
    /// Integer literal. Must fit in i48 fixnum range; otherwise
    /// `IntegerOutOfFixnumRange` (bignum literal lifting lands
    /// with bignum Scope B).
    int: i64,
    /// Reference to a lexically-bound local (step #4). Resolution
    /// walks the Emitter's scope stack innermost-first; unresolved
    /// names raise `CompileError.UnresolvedSymbol`. When step #5
    /// adds closures + step #7 adds vars, this lookup falls
    /// through to capture analysis / Var resolution per
    /// COMPILER.md §4.3 priority list. For step #4, locals are
    /// the only resolution category that exists.
    symbol: []const u8,
    /// `(+ lhs rhs)`. Sub-expressions are recursive.
    add: struct {
        lhs: *const Tiny,
        rhs: *const Tiny,
    },
    /// `(< lhs rhs)` — fixnum less-than. Step 5d0: needed to write
    /// terminating loop tests for `recur` / `loop*`. Lowers to
    /// `cmp:lt` per VM.md §10 group #1.
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
    /// `name` is the optional self-name (step 5c); when present,
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
        /// Step 5e (peer-AI turn 49): `(fn* [a b & r] body)`
        /// has `params = ["a","b"]` and `rest_param = "r"`.
        /// `rest_param` is bound at slot `params.len`. At call
        /// time, the VM packs excess args into a list and
        /// installs it in that slot. `null` means fixed-arity.
        /// Tiny avoids encoding `&` as a fake symbol; reader-
        /// form integration (step #7) parses `[a b & r]` into
        /// this explicit shape.
        rest_param: ?[]const u8 = null,
        body: *const Tiny,
    },
    /// `(callee args...)` — function invocation. Lowers to the
    /// range-call ABI per VM.md §6: stage callee + args in a
    /// contiguous call block, emit `call:call`. Step 5a1 calls
    /// any closure value (no captures yet).
    call: struct {
        callee: *const Tiny,
        args: []const *const Tiny,
    },
    /// `(loop* [name1 v1 name2 v2 ...] body)` per PLAN §6.1 +
    /// COMPILER.md §5.7. Step 5d1.
    /// Same as `let*` for binding setup (sequential RHS
    /// visibility, captured-binding cells); the loop body
    /// installs a `RecurTarget` so `(recur args...)` inside the
    /// body rebinds and jumps to the entry label.
    loop_star: struct {
        bindings: []const Binding,
        body: *const Tiny,
    },
    /// `(recur arg1 arg2 ...)` per PLAN §6.1 + COMPILER.md §5.6.
    /// Step 5d1. Re-enters the nearest enclosing `loop*` or
    /// `fn*` (5d2) with the given arguments. Must be in tail
    /// position; arity must match the target's binding count.
    /// Lowers to a parallel-assignment move (via temp slots)
    /// into the target's binding slots + `jump:jmp` to the
    /// target's entry label. NO call opcode is emitted (per
    /// VM.md §11 — recur is not a call).
    recur: struct {
        args: []const *const Tiny,
    },
    /// `(def name value?)` per PLAN §6.1. Step #6b.
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
    /// `(var name)` per PLAN §6.1. Step #6b. Loads the Var
    /// object itself (not its value) — Clojure's `#'name`
    /// reader form. Does NOT trap on unbound; taking a
    /// reference to a declared-but-unbound Var is legal.
    var_ref: struct {
        name: []const u8,
    },
    /// `(defn name [params...] body)` per PLAN §6.1. Step #6c.
    /// Sugar for `(def name (fn* name [params...] body))` —
    /// the function carries its own name as the self-name (so
    /// the body can recurse via the lexical name without going
    /// through the Var, just like step 5c's named-fn*). The
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
    /// per PLAN §6.1 + COMPILER.md §5.6b. Step 5c.
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
    body: *const Tiny,
};

/// One binding in a `let*` form.
pub const Binding = struct {
    name: []const u8,
    value: *const Tiny,
};

/// How a lexical binding is realized in the current routine's
/// frame (peer-AI turn 40 / 42 lazy-boxing). Step 5b widens
/// `LocalBinding.ref` from a bare `u12` slot to this union so
/// that captured bindings can mutate from `.direct_slot` to
/// `.cell_slot` mid-compilation when an inner closure first
/// captures them.
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
    /// inside the cell. Transitions from `direct_slot` happen
    /// lazily on first capture per COMPILER.md §6.1.
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

/// Routine-level capture cache entry (peer-AI turn 45). Maps
/// a captured name to its upvalue index, so repeat references
/// to the same outer name from different lexical scopes share
/// a single upvalue/descriptor entry.
pub const CapturedName = struct {
    name: []const u8,
    upvalue: u12,
};

/// Where `(recur args...)` should jump and which slots it
/// rebinds. Threaded through `compileExpr` in tail position
/// (peer-AI turn 47).
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
    binding_slots: []const u12,
    /// Per-binding flag: true iff binding's slot holds a
    /// `*UpvalCell` (was pre-analyzed as captured by a
    /// descendant fn). `compileRecur` reads this to decide
    /// between fresh-cell-install (captured) and plain
    /// `mov:move` (direct) for each binding (per VM.md §11
    /// + COMPILER.md §5.6 captured-recur semantics).
    captured_mask: []const bool,
    kind: RecurTargetKind,
    /// Step 5e: true iff this fn target belongs to a variadic
    /// fn. `compileRecur` rejects any recur targeting a
    /// variadic fn with `UnsupportedFeature` for v1 — proper
    /// variadic recur (rebuild rest list per iteration) is a
    /// separate sub-step (peer-AI turn 49: "decide before
    /// coding; implement explicitly or reject explicitly").
    /// Always false for loop targets (loops never variadic).
    variadic: bool = false,
};

pub const RecurTargetKind = enum { loop_star, fn_star };

// =============================================================================
// Errors
// =============================================================================

pub const CompileError = error{
    /// Compiler encountered a `Tiny` variant it doesn't know how to
    /// lower. Reserved for when `Tiny` is replaced by `reader.Form`
    /// in a later step, where arbitrary forms can arrive.
    UnsupportedForm,

    /// Integer literal exceeds i48 fixnum range. Until bignum
    /// arithmetic Scope B lands and the codegen learns to lift
    /// out-of-range literals into bignum heap values, this is a
    /// hard compile-time error.
    IntegerOutOfFixnumRange,

    /// Routine has more constants than the 12-bit constant-pool
    /// operand can address (4096). Extension instructions can
    /// resolve this in a later commit; until then, it's a hard
    /// error.
    ConstantPoolOverflow,

    /// Routine has more bytecode than the 12-bit jump target
    /// operand can address (4096). Extension instructions can
    /// resolve this; until then, hard error.
    JumpTargetOutOfRange,

    /// Routine has more slots than the 12-bit slot operand can
    /// address (4096).
    SlotOverflow,

    /// Symbol reference doesn't resolve to a lexical local in
    /// the current scope. Step #4: the only resolution category
    /// is locals; once vars (step #7) and captured upvalues
    /// (step #5) land, this error indicates the symbol resolves
    /// to NONE of (local, upvalue, var, special-form, core-mapping)
    /// — per COMPILER.md §4.3 rule #8.
    UnresolvedSymbol,

    /// Two parameter slots in the same `fn*` carry the same
    /// name. Per peer-AI turn 40 / Clojure semantics: not
    /// allowed (unlike `let*` where sequential bindings can
    /// shadow within the same form per COMPILER.md §4.3).
    DuplicateParam,

    /// Two bindings in the same `letfn*` group carry the same
    /// name. Step 5c: unlike `let*` (sequential shadowing
    /// allowed), `letfn*` names are mutually visible — duplicates
    /// create resolution ambiguity. Matches Clojure
    /// (`letfn` rejects duplicate names).
    DuplicateBinding,

    /// `(recur ...)` appears in a position that is not a tail
    /// position of an enclosing `loop*` or `fn*` body. Per
    /// PLAN §11.3 + VM.md §11 + COMPILER.md §5.6: `recur` MUST
    /// be in tail position to preserve the constant-stack
    /// guarantee. Step 5d1.
    RecurOutsideTail,

    /// `(recur ...)` has a different argument count than the
    /// target's binding count. Per VM.md §11 + COMPILER.md
    /// §5.6. Caught at compile time (no runtime arity
    /// revalidation — recur is not a call opcode). Step 5d1.
    RecurArityMismatch,

    /// A feature is recognized but intentionally not wired in
    /// the current step. Step 5e: emitted for `(recur ...)`
    /// targeting a variadic fn (per peer-AI turn 49 — proper
    /// variadic recur requires rebuilding the rest list per
    /// iteration; deferred to a separate sub-step). Step #7a:
    /// also used for `reader.Form` datums that lower in later
    /// step-#7 sub-steps (lists, vectors, maps, sets, quote,
    /// syntax-quote, `#(...)`, `^{...}` metadata, qualified
    /// symbols). Trapping loudly is better than emitting
    /// subtly-wrong code.
    UnsupportedFeature,

    /// The parser or reader rejected the source string while
    /// compiling via `compileSource` / `compileSourceWithNamespace`.
    /// Step #7a: bucketed error wrapping any inferred error from
    /// `parser.parseForm` / `reader.readOneForm`. Step #10
    /// (error reporting hardening) will replace this with
    /// structured errors carrying SrcSpan + the original reader
    /// ErrorKind.
    ReaderFailure,

    /// A compiler invariant was violated. Distinct from a
    /// user-error like `UnresolvedSymbol`: this indicates the
    /// compiler reached a state it believes impossible (e.g.,
    /// `resolveOrCapture` got back `.direct_slot` for a name
    /// that pre-analysis should have boxed). Surfaces in
    /// release builds as a clean error rather than panicking;
    /// debug builds also assert (peer-AI turn 45).
    InternalCompilerBug,

    OutOfMemory,
};

// =============================================================================
// Output
// =============================================================================

/// The compiler's product. Wrap with `toRoutine(name)` to get a
/// `vm.Routine` ready for `vm.VM.init`. Step 5a1 added
/// `capture_descs` to support `closure:make` lowering and
/// `arity` for call-site validation.
///
/// **Ownership**: `code` and `consts` are slices allocated through
/// the allocator passed to `compileTiny()` and remain valid until
/// that allocator is reset or destroyed. There is no `deinit`
/// method — the model is "compile-time arena, drop wholesale after
/// execution." Callers using a non-arena allocator must free
/// `code` and `consts` individually. (When step #5's runtime
/// function heap kind lands, the lifecycle target is `Compiled` →
/// heap-Value-of-kind-function via deep-copy; that conversion is
/// deferred until the heap fn-kind is real.)
pub const Compiled = struct {
    code: []const Inst,
    consts: []const vm.Const,
    capture_descs: []const vm.CaptureDescriptor = &.{},
    /// Step #6b: per-routine Var table. The V operand index
    /// resolves through this table at runtime. Lifetime: same
    /// as the rest of the Compiled (compile-arena-owned).
    var_table: []const *vm.Var = &.{},
    slot_count: u16,
    /// Top-level Compiled has fixed_arity 0; child routines built
    /// by `compileFn` set this to their fixed parameter count.
    /// (Renamed from `arity` in step 5e0.)
    fixed_arity: u16 = 0,
    /// Step 5e: true for `(fn* [a b & r] ...)`. The VM packs
    /// excess args into a list at call time.
    variadic: bool = false,

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
        };
    }
};

// =============================================================================
// Emitter — internal mutable accumulator (peer-AI turn 36)
// =============================================================================

/// `Emitter` accumulates a routine's bytecode, constants, slot
/// count, and active lexical scope as a tree of `compileExpr`
/// calls runs. It's allocator-owned and turned into a `Compiled`
/// at the end via `finish()`.
///
/// **Slot allocation**: monotonic — each `allocSlot()` call returns
/// `slot_count` and bumps it. No reuse across branches (step #6
/// liveness analysis is a future-Phase-6 concern; correctness comes
/// first per peer-AI turn 36).
///
/// **Constant pool**: simple append. Future dedup is an obvious
/// optimization but doesn't affect correctness; deferred per
/// COMPILER.md §4.5 deduplication note.
///
/// **Lexical scope** (step #4, per peer-AI turn 38): a stack of
/// `LocalBinding{name, slot}` pairs. Resolution walks innermost-
/// first (newest entries shadow older). Bindings push at let*
/// binding-time (after the RHS is compiled, per COMPILER.md §4.3's
/// strict left-of-self rule) and pop at let-body exit via
/// `defer scope.shrinkRetainingCapacity(mark)` — `defer` rather
/// than success-path restore so an error mid-body doesn't leak
/// scope into a recovering caller.
///
/// **Future evolution** (peer-AI turn 38 caveat): `LocalBinding`
/// is going to grow into a `BindingRef` union once step #5
/// closures and step #7 vars land — `local_value_slot |
/// local_cell_slot | upvalue | var_ref`. The flat name→slot
/// resolution we use today is correct only across the single
/// current routine; nested function compilation (step #5) needs
/// capture analysis at function boundaries.
const Emitter = struct {
    allocator: std.mem.Allocator,
    code: std.ArrayList(Inst) = .empty,
    consts: std.ArrayList(vm.Const) = .empty,
    capture_descs: std.ArrayList(vm.CaptureDescriptor) = .empty,
    scope: std.ArrayList(LocalBinding) = .empty,
    slot_count: u16 = 0,
    /// Step 5b (peer-AI turn 42 linked-Emitter design): pointer
    /// to the enclosing routine's Emitter, or null for the
    /// top-level routine. Capture discovery walks the parent
    /// chain in `resolveOrCapture`. Synchronous compilation
    /// guarantees the parent pointer remains valid throughout
    /// child compilation (parent is blocked in its
    /// `compileFn` call).
    parent: ?*Emitter = null,
    /// Step 5b: captures THIS routine has registered (in
    /// upvalue-index order). Each entry is a `CaptureSource`
    /// describing how to source the cell from the PARENT
    /// frame when the parent's `closure:make` runs. The
    /// list grows in `resolveOrCapture` as inner functions
    /// discover free-variable references. At `compileFn`
    /// finalization, the parent builds a `CaptureDescriptor`
    /// from `child.captures` and registers it in its own
    /// `capture_descs` table.
    captures: std.ArrayList(vm.CaptureSource) = .empty,
    /// Step 5b (peer-AI turn 45): routine-level cache of
    /// captured names → upvalue-index. Separate from
    /// `scope` so inner `let_star` scope restoration cannot
    /// pop a captured-binding entry. Without this, the same
    /// outer name referenced in two unrelated inner scopes
    /// would be captured twice (two upvalue indices, two
    /// descriptor sources, double-allocated cell pointer in
    /// the closure). Lexical locals still take precedence
    /// (resolved via `scope` first), so shadowing is
    /// preserved.
    captured_names: std.ArrayList(CapturedName) = .empty,
    /// Step #6b: per-routine Var table. The compiler appends
    /// to this when it sees a `def`, a `(var x)`, or a
    /// symbol-fall-through-to-Var resolution. Index in this
    /// list becomes the V operand index in emitted bytecode.
    /// Routines built from a child Emitter (compileFn) carry
    /// their own table independent of the parent's; Vars are
    /// global per-namespace and only the index encoding is
    /// per-routine.
    var_table: std.ArrayList(*vm.Var) = .empty,
    /// Step #6b: Namespace used for `def` / `var` / symbol
    /// fall-through. `null` means no namespace was passed to
    /// `compileTiny`; in that case `def`/`var_ref` raise
    /// `UnresolvedSymbol` and unresolved symbols stay
    /// unresolved (existing behavior). Child Emitters inherit
    /// the parent's namespace pointer.
    namespace: ?*vm.Namespace = null,

    fn init(allocator: std.mem.Allocator) Emitter {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *Emitter) void {
        self.code.deinit(self.allocator);
        self.consts.deinit(self.allocator);
        self.capture_descs.deinit(self.allocator);
        self.scope.deinit(self.allocator);
        self.captures.deinit(self.allocator);
        self.captured_names.deinit(self.allocator);
        self.var_table.deinit(self.allocator);
    }

    /// Look up a name in the routine-level capture cache.
    /// Returns the existing upvalue index if previously
    /// captured (peer-AI turn 45 dedup); null otherwise.
    fn lookupCapturedName(self: *const Emitter, name: []const u8) ?u12 {
        for (self.captured_names.items) |c| {
            if (std.mem.eql(u8, c.name, name)) return c.upvalue;
        }
        return null;
    }

    /// Push a direct-slot binding onto the lexical scope. Does
    /// NOT allocate a slot — the caller already has one
    /// (typically the slot the binding's RHS was just compiled
    /// into). Subsequent capture by an inner closure may
    /// mutate the binding to `.cell_slot` via `ensureBoxed`.
    fn pushBinding(self: *Emitter, name: []const u8, slot: u12) CompileError!void {
        try self.scope.append(self.allocator, .{ .name = name, .ref = .{ .direct_slot = slot } });
    }

    /// Resolve `name` to a `BindingRef` via innermost-shadow
    /// lookup of ONLY the current Emitter's scope. Returns null
    /// if no binding matches; callers walk the parent chain via
    /// `resolveOrCapture` if appropriate.
    ///
    /// Step 5b: returns the full BindingRef so callers can
    /// dispatch on direct/cell/upvalue at emit time.
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
    /// **Pre-analysis invariant** (peer-AI turn 44): captured
    /// bindings are guaranteed `.cell_slot` (or `.upvalue`,
    /// transitively) by the time `resolveOrCapture` walks the
    /// parent chain. A parent returning `.direct_slot` for a
    /// captured name indicates pre-analysis missed the capture
    /// — that's a compiler bug, caught by the assertion below.
    /// `ensureBoxed` (the lazy-boxing mid-codegen mutation
    /// helper) was removed in the turn-44 rewrite.
    ///
    /// Returns `UnresolvedSymbol` if no enclosing scope (up
    /// the entire parent chain) has the name.
    fn resolveOrCapture(self: *Emitter, name: []const u8) CompileError!BindingRef {
        // Step 1: lexical scope, innermost-first. Lexical
        // locals (params, let_star bindings) shadow any
        // captures with the same name, preserving lexical
        // scope semantics.
        if (self.resolveLocalRef(name)) |ref| return ref;
        // Step 2: routine-level capture cache (peer-AI turn 45).
        // If THIS routine previously captured `name` (from a
        // sibling scope, or earlier in the body), reuse the
        // existing upvalue index instead of registering a new
        // one. This avoids the "synthetic upvalue popped by
        // inner let_star scope restoration" hazard.
        if (self.lookupCapturedName(name)) |u| return .{ .upvalue = u };
        // Step 3: walk parent chain.
        const parent = self.parent orelse return CompileError.UnresolvedSymbol;
        const parent_ref = try parent.resolveOrCapture(name);
        // Step 3: convert parent's ref into a CaptureSource for
        // self.captures. Pre-analysis guarantees a captured
        // name's parent binding is .cell_slot (or .upvalue);
        // a .direct_slot return here means pre-analysis missed
        // a capture — compiler bug.
        const source: vm.CaptureSource = switch (parent_ref) {
            .cell_slot => |s| .{ .local_cell_slot = s },
            .upvalue => |u| .{ .inherited_upvalue = u },
            .direct_slot => {
                // Pre-analysis should have boxed this binding
                // at let_star binding time or fn_star param
                // entry. Reaching here is a compiler bug
                // (peer-AI turn 45 — was UnresolvedSymbol
                // pre-revision; that error was misleading
                // because the symbol DID resolve, the box just
                // wasn't emitted).
                std.debug.assert(false);
                return CompileError.InternalCompilerBug;
            },
        };
        // Step 4: register the capture. Append the source to
        // self.captures (in upvalue-index order) AND record
        // the name → upvalue mapping in captured_names so
        // future lookups dedupe (peer-AI turn 45). NOT pushed
        // into self.scope because scope is for lexical
        // bindings only — putting captures there meant
        // inner let_star scope restoration could pop them.
        const u_idx_usize = self.captures.items.len;
        if (u_idx_usize >= 4096) return CompileError.SlotOverflow;
        const u_idx: u12 = @intCast(u_idx_usize);
        try self.captures.append(self.allocator, source);
        try self.captured_names.append(self.allocator, .{ .name = name, .upvalue = u_idx });
        return .{ .upvalue = u_idx };
    }

    /// Allocate a fresh result slot. Slots are monotonic; no
    /// reclamation in step #3.
    fn allocSlot(self: *Emitter) CompileError!u12 {
        if (self.slot_count >= 4096) return CompileError.SlotOverflow;
        const s = self.slot_count;
        self.slot_count += 1;
        return @intCast(s);
    }

    /// Allocate a contiguous run of `count` fresh slots, return the
    /// base index. Required by `compileCall` to reserve the call
    /// block BEFORE compiling sub-expressions (peer-AI turn 43
    /// catch: per-arg `allocSlot` interleaved with sub-expression
    /// compilation is incorrect — sub-expressions allocate their
    /// own temps and the next "arg slot" is no longer adjacent
    /// to the previous, breaking the range-call ABI invariant).
    fn allocSlotBlock(self: *Emitter, count: u32) CompileError!u12 {
        const base: u32 = self.slot_count;
        const end: u32 = base + count;
        if (end > 4096) return CompileError.SlotOverflow;
        self.slot_count = @intCast(end);
        return @intCast(base);
    }

    /// Add a constant to the pool, return its index. Constants are
    /// not deduplicated in step #3 (correctness over polish).
    /// Step 5a0.5 widens to typed `Const` per peer-AI turn 40
    /// — most callers want `addValueConst(v)` for an ordinary
    /// `Value`; step 5a1 will add `addRoutineConst(*const Routine)`
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
    /// parent's pool for later `closure:make` (peer-AI turn 42).
    fn addRoutineConst(self: *Emitter, r: *const vm.Routine) CompileError!u12 {
        return self.addConst(.{ .routine = r });
    }

    /// Add a capture descriptor to the emitter's table; return
    /// the descriptor's index for use as `closure:make`'s B
    /// operand. Step 5a1: only empty descriptors. 5b populates
    /// `local_cell_slot` / `inherited_upvalue` sources.
    fn addCaptureDescriptor(self: *Emitter, desc: vm.CaptureDescriptor) CompileError!u12 {
        const idx = self.capture_descs.items.len;
        if (idx >= 4096) return CompileError.ConstantPoolOverflow;
        try self.capture_descs.append(self.allocator, desc);
        return @intCast(idx);
    }

    /// Step #6b: get-or-create a V operand index for `name` in
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
        const v = ns.intern(name) catch return CompileError.OutOfMemory;
        // Dedup: linear scan is fine for v1 routines (var_table
        // length expected to stay small; rarely > a few dozen).
        for (self.var_table.items, 0..) |existing, i| {
            if (existing == v) return @intCast(i);
        }
        const idx = self.var_table.items.len;
        if (idx >= 4096) return CompileError.SlotOverflow;
        try self.var_table.append(self.allocator, v);
        return @intCast(idx);
    }

    /// Append an instruction to the code stream.
    fn emit(self: *Emitter, inst: Inst) CompileError!void {
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
    /// Ownership transfer is errdefer-safe (peer-AI turn 37): if
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
        return .{
            .code = code,
            .consts = consts,
            .capture_descs = caps,
            .var_table = vt,
            .slot_count = if (self.slot_count == 0) 1 else self.slot_count,
            .fixed_arity = 0, // top-level only; compileFn sets this for child routines via Routine struct
            .variadic = false, // top-level routine never variadic
        };
    }
};

// =============================================================================
// Public API
// =============================================================================

/// Compile a `Tiny` form to a `Compiled` artifact.
///
/// **Provisional name** (peer-AI turn 35): `compileTiny` rather than
/// `compile` to make it loud that this is the bootstrap-only entry
/// point that accepts the local `Tiny` representation. When step
/// #3+ replaces `Tiny` with `reader.Form`, the public compile
/// surface evolves; tooling/tests that built against `compileTiny`
/// get a clean rename signal.
pub fn compileTiny(allocator: std.mem.Allocator, form: *const Tiny) CompileError!Compiled {
    return compileTinyWithNamespace(allocator, form, null);
}

/// Step #6b: compile with a Namespace for `def` / `(var x)` /
/// symbol-fall-through-to-Var resolution. Existing call sites
/// that don't use vars can keep calling `compileTiny`
/// (namespace=null), and unresolved symbols continue to raise
/// `UnresolvedSymbol`. Tests that exercise `def` build a
/// Namespace (typically `VM.ensureNamespace()`'s) and pass it
/// here.
pub fn compileTinyWithNamespace(
    allocator: std.mem.Allocator,
    form: *const Tiny,
    namespace: ?*vm.Namespace,
) CompileError!Compiled {
    var emitter = Emitter.init(allocator);
    emitter.namespace = namespace;
    errdefer emitter.deinit();

    // Top-level form compiles into slot 0; routine returns slot 0.
    // Top-level position has NO enclosing loop/fn → recur_target is null.
    // A top-level `(recur)` correctly raises RecurOutsideTail.
    const dst = try emitter.allocSlot();
    try compileExpr(&emitter, form, dst, null);
    try emitter.emit(vm.asm_.returnSlot(dst));

    return try emitter.finish();
}

// =============================================================================
// Form → Tiny lowering (step #7a, peer-AI turn 51 architecture)
// =============================================================================
//
// `lowerForm` converts a `reader.Form` tree into a `Tiny` IR tree on the
// passed allocator. The Tiny tree is then compiled via the existing
// backend (`compileTinyWithNamespace`), so the entire Phase 2 codegen
// pipeline (capture pre-analysis, RecurTarget threading, variadic rest,
// Var fall-through, etc.) reuses the proven Tiny path. There is no
// parallel "compile Form directly to bytecode" path; that would
// duplicate ~5000 LOC of backend logic and lose 135 regression tests.
//
// Step #7a scope (deliberately narrow): literals + symbols only.
// All compound Form datums (lists, vectors, maps, sets, quote,
// syntax-quote, etc.) raise `UnsupportedFeature`. The expansion plan:
//
//   #7b: list dispatch — ordinary calls + special forms (do, if,
//        quote-of-scalar) + arithmetic intrinsics (+, < when not
//        lexically shadowed)
//   #7c: binding/fn forms (let*, fn*, letfn*, loop*, recur)
//   #7d: vars/def/defn via Form
//   #7e: full source-string end-to-end tests
//
// The lowering env (`LowerEnv`, peer-AI turn 51 §"load-bearing
// issue") that tracks lexical-name shadowing for intrinsic
// dispatch lands in #7b — #7a has no intrinsics and no special
// forms, so no env is needed yet.

/// Allocate and initialize a Tiny node on the given allocator.
/// Used by `lowerForm` to build the IR tree. The arena passed to
/// `compileForm`/`compileSource` owns these allocations.
fn allocTiny(allocator: std.mem.Allocator, value: Tiny) CompileError!*Tiny {
    const t = try allocator.create(Tiny);
    t.* = value;
    return t;
}

/// Translate a `reader.Form` tree into a `Tiny` IR tree on the
/// passed allocator. Step #7a supports literals (`nil`, `bool_`,
/// `int`) and unqualified symbols only; all other Form datums
/// raise `CompileError.UnsupportedFeature` (compound forms land
/// in #7b through #7d).
///
/// Symbol names are NOT duped — they're borrowed from the
/// reader's source string. The caller must keep that source
/// alive for the lifetime of the Compiled artifact.
pub fn lowerForm(
    allocator: std.mem.Allocator,
    form: *const reader_mod.Form,
) CompileError!*Tiny {
    return switch (form.datum) {
        .nil => try allocTiny(allocator, .nil),
        .bool_ => |b| try allocTiny(allocator, .{ .bool = b }),
        .int => |n| try allocTiny(allocator, .{ .int = n }),
        .symbol => |name| blk: {
            // Step #7a: only unqualified symbols. Qualified
            // (namespace/name) symbols require multi-ns
            // machinery (post-v1).
            if (name.ns != null) return CompileError.UnsupportedFeature;
            break :blk try allocTiny(allocator, .{ .symbol = name.name });
        },
        // -- Compound datums: land in later #7 sub-steps. --
        // Phase 1 numeric literals beyond fixnum.
        .real, .char, .string, .keyword => return CompileError.UnsupportedFeature,
        // Sequential collections + special-form dispatch (#7b/#7c).
        .list, .vector, .map, .set => return CompileError.UnsupportedFeature,
        // Reader macros / meta (#7b for quote-of-scalar, deferred
        // to step #8 macroexpander for the rest).
        .quote, .syntax_quote, .unquote, .unquote_splicing => return CompileError.UnsupportedFeature,
        // Atoms aren't a Phase 2 feature.
        .deref => return CompileError.UnsupportedFeature,
        // #(...) anon-fn shorthand — deferred (likely to step #8
        // macroexpander; see strategy turn 51 §Q4).
        .anon_fn => return CompileError.UnsupportedFeature,
        // ^{...} metadata — deferred (Phase 3+).
        .with_meta => return CompileError.UnsupportedFeature,
    };
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
    const tiny = try lowerForm(allocator, form);
    return compileTinyWithNamespace(allocator, tiny, namespace);
}

/// End-to-end: parse + read + lower + compile a source string.
/// Convenience wrapper around `parser.parseForm` + `Reader.readOneForm`
/// + `compileFormWithNamespace`. Step #7a. No namespace; symbols
/// must resolve lexically.
pub fn compileSource(
    allocator: std.mem.Allocator,
    source: []const u8,
) CompileError!Compiled {
    return compileSourceWithNamespace(allocator, source, null);
}

/// End-to-end with namespace access for `def` / `(var x)` /
/// symbol fall-through. Step #7a.
///
/// Lifetime: the returned `Compiled` references strings borrowed
/// from `source` (via Tiny.symbol → routine.var_table[*].name).
/// The caller MUST keep `source` alive for the lifetime of the
/// `Compiled` artifact and any VM that runs it. Tests typically
/// achieve this by storing source as a string literal (program
/// lifetime) or by holding it in the same arena as the
/// `Compiled`.
///
/// Reader/parser errors are bucketed as `CompileError.ReaderFailure`
/// for step #7a; structured errors with SrcSpans land in step #10.
pub fn compileSourceWithNamespace(
    allocator: std.mem.Allocator,
    source: []const u8,
    namespace: ?*vm.Namespace,
) CompileError!Compiled {
    var p = reader_mod.parser.parseForm(allocator, source) catch
        return CompileError.ReaderFailure;
    defer p.parser.deinit();
    var reader = reader_mod.Reader.init(allocator, source);
    defer reader.deinit();
    const form = reader.readOneForm(p.sexp) catch
        return CompileError.ReaderFailure;
    return compileFormWithNamespace(allocator, form, namespace);
}

// =============================================================================
// Internal lowering — destination-driven (peer-AI turn 36)
// =============================================================================

// =============================================================================
// Capture pre-analysis (peer-AI turn 44 — supersedes lazy boxing)
//
// The analyzer answers: "given a `Tiny` subtree, which names are
// referenced by some `fn*` body inside the subtree?" The compiler
// uses this at `let*` binding time and `fn*` parameter time to
// decide whether to emit `closure:box-local` UNCONDITIONALLY in
// straight-line prelude code (so the boxing dominates every
// reachable use, including reads inside or after branches).
//
// **Why not lazy-box** (peer-AI turn 44 catch): lazy boxing
// emitted `closure:box-local` at the moment capture was discovered
// during inner-fn compilation. If the inner fn was inside a
// branch (e.g., `(if false (fn* [] x) 0)`), the box-local lived
// in the unreachable branch while the compiler's BindingRef
// scope-state thought x was boxed. Subsequent same-frame reads
// emitted `closure:get-cell` against an unboxed slot at runtime
// → `:expected-cell` trap on a perfectly valid program.
//
// Pre-analysis fixes this by computing the capture set BEFORE
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

/// Linear-lookup string set. Sufficient at v1's small Tiny
/// surface; HashMap is overkill until measured otherwise.
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
            // outer bindings (peer-AI turn 47 §7 catch). Recurse
            // into each arg with the current env.
            for (r.args) |a| try freeVars(allocator, a, env, out);
        },
        .def => |d| {
            // def's RHS is the only sub-expression that can carry
            // free vars; the name itself is a NAMESPACE-LEVEL
            // binding, not a local, so it doesn't affect this
            // routine's lexical env. Step #6b.
            if (d.value) |val| try freeVars(allocator, val, env, out);
        },
        .var_ref => {}, // leaf: no sub-expressions, no free vars
        .defn => |d| {
            // Step #6c: defn lowers to (def name (fn* name ...)).
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
/// **Shadowing-aware** (peer-AI turn 45 fix): the `env`
/// parameter tracks names visible at our level. As the walk
/// descends into binding-forms (`let_star`, `fn_star` params),
/// shadowed names are removed from the live env so they don't
/// pollute the captured set. This avoids the false positive
/// from turn 44 where an inner shadow caused the outer binding
/// to be unnecessarily boxed.
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
        .nil, .bool, .int, .symbol => {},
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
            // shadowed-names for each phase.
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
            // capturedByDescendantFns recursion needed (peer-AI
            // turn 45 simplification — was redundant).
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
            // Recur args may contain nested fn_stars (peer-AI
            // turn 47 §7 catch). Recurse into each.
            for (r.args) |a| try capturedByDescendantFns(allocator, a, env, out);
        },
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
/// (peer-AI turn 47). Propagation is form-specific; see the
/// per-arm handlers.
fn compileExpr(
    e: *Emitter,
    form: *const Tiny,
    dst: u12,
    recur_target: ?*const RecurTarget,
) CompileError!void {
    switch (form.*) {
        .nil => try e.emit(vm.asm_.loadNil(dst)),
        .bool => |b| try e.emit(if (b) vm.asm_.loadTrue(dst) else vm.asm_.loadFalse(dst)),
        .int => |n| try compileIntLiteral(e, n, dst),
        .symbol => |name| try compileSymbol(e, name, dst),
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

fn compileAdd(e: *Emitter, lhs: *const Tiny, rhs: *const Tiny, dst: u12) CompileError!void {
    // Literal-pair peephole (per turn 33 + turn 36): if both
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
/// shape as `compileAdd`. Step 5d0 (peer-AI turn 47).
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

fn compileSymbol(e: *Emitter, name: []const u8, dst: u12) CompileError!void {
    // Step 5b/5c (peer-AI turns 44/45 pre-analysis model,
    // SUPERSEDES the turn-40 lazy-boxing approach): capture-aware
    // resolution walks self first, then parent emitters. Captured
    // locals are pre-boxed at binding time (let*/loop*) or
    // function entry (fn* params) so their BindingRef is stable
    // across all control-flow paths. Step #6b (peer-AI turn 49)
    // adds Var fall-through:
    //   1. local (this routine) → dispatch on BindingRef
    //   2. captured upvalue (parent chain) → resolve.upvalue + capture
    //   3. namespace var (if namespace exists) → var:load-var
    //   4. error → :unresolved-symbol
    const ref = e.resolveOrCapture(name) catch |err| switch (err) {
        // Step #6b: lexical resolution failed; try the
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
            // Skip the no-op self-move (peer-AI turn 38).
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
            // VM.md §6 amendment (peer-AI turn 34).
            try e.emit(vm.asm_.moveFrom(dst, vm.Operand.upvalue(u)));
        },
    }
}

/// Step #6b: lower `(def name value?)`. Interns the Var in the
/// namespace (creating an unbound Var if absent), compiles
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
    const idx = try e.addVarRef(name);
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

/// Step #6b: lower `(var name)`. Interns the Var if absent,
/// emits `var:var-object` to load the Var object itself (NOT
/// its value). Does not trap on unbound; users can take a
/// reference to a forward-declared Var.
fn compileVarRef(e: *Emitter, name: []const u8, dst: u12) CompileError!void {
    if (e.namespace == null) return CompileError.UnresolvedSymbol;
    const idx = try e.addVarRef(name);
    try e.emit(vm.asm_.varVarObject(dst, idx));
}

/// Step #6c: lower `(defn name [params...] body)` as sugar for
/// `(def name (fn* name [params...] body))`. The fn* carries
/// `name` as its self-name so the body can self-recurse via
/// the lexical name (handled by step 5c's named-fn placeholder
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
    // dispatch through compileDef. The fn_star value lives on
    // the Zig stack frame; compileDef and compileFn complete
    // synchronously, so the pointer remains valid.
    const fn_form: Tiny = .{ .fn_star = .{
        .name = name,
        .params = params,
        .rest_param = rest_param,
        .body = body,
    } };
    try compileDef(e, name, &fn_form, dst);
}

fn compileLetStar(
    e: *Emitter,
    bindings: []const Binding,
    body: *const Tiny,
    dst: u12,
    recur_target: ?*const RecurTarget,
) CompileError!void {
    // Strict left-of-self visibility per COMPILER.md §4.3
    // (peer-AI turn 35 + 38): each binding's RHS sees bindings
    // 1..i-1 only, not its own LHS. The loop pushes each
    // binding to scope AFTER its RHS has been compiled.
    //
    // Pre-analysis capture (peer-AI turn 44, supersedes lazy
    // boxing): for each binding, walk the rest of the let
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
    // caller (peer-AI turn 38).
    const mark = e.scope.items.len;
    defer e.scope.shrinkRetainingCapacity(mark);

    for (bindings, 0..) |b, i| {
        const slot = try e.allocSlot();
        // RHS is non-tail (recur invalid in let-binding RHS).
        try compileExpr(e, b.value, slot, null);

        // Pre-analyze (peer-AI turn 45 env-aware variant): is
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

/// Lower `(loop* [b1 v1 b2 v2 ...] body)` per COMPILER.md §5.7
/// + VM.md §11 (peer-AI turn 47).
///
/// Same as `let*` for binding setup (sequential RHS visibility +
/// captured-binding cells via pre-analysis). After the bindings
/// are set up, mark the entry PC and compile the body with a
/// loop `RecurTarget` so any `(recur ...)` in tail position
/// rebinds the loop slots and jumps back to entry.
///
/// Entry-PC placement (peer-AI turn 47 §7 catch): AFTER the
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

    // Step 1-3: bind values, box captured bindings, push scope
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

    // Step 4: mark entry PC (AFTER box-local prelude).
    const entry_pc = try e.checkJumpTarget(e.currentPc());
    const loop_target = RecurTarget{
        .entry_pc = entry_pc,
        .binding_slots = binding_slots,
        .captured_mask = captured_mask,
        .kind = .loop_star,
    };

    // Step 5: compile body with the loop target installed. The
    // body REPLACES (not propagates) any outer recur target —
    // a recur inside the body always targets THIS loop, not an
    // enclosing one (peer-AI turn 47 §Q1 / nested-loop rule).
    try compileExpr(e, body, dst, &loop_target);
}

/// Lower `(recur args...)` per COMPILER.md §5.6 + VM.md §11
/// (peer-AI turn 47).
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
/// the recur — harmless, per peer-AI turn 47 §7 dead-code note.
fn compileRecur(
    e: *Emitter,
    args: []const *const Tiny,
    recur_target: ?*const RecurTarget,
) CompileError!void {
    const target = recur_target orelse return CompileError.RecurOutsideTail;
    // Step 5e: variadic-fn-target recur is deliberately
    // rejected for v1 (peer-AI turn 49). Proper lowering
    // requires rebuilding the rest list per iteration; lands
    // in a separate sub-step.
    if (target.variadic) return CompileError.UnsupportedFeature;
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
    // slot (peer-AI turn 38: avoids the 999-slot blowup that
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
/// **Step 5a1 restriction** (peer-AI turn 42): only empty-capture
/// closures. The child Emitter has NO parent pointer; any free
/// variable reference in the body raises `UnresolvedSymbol`.
/// Capture support lands in 5b.
///
/// Named `fn*` (self-name) is deferred to 5c per turn 42 — for
/// step 5a1, `Tiny.fn_star` carries no name field. When 5c lands,
/// the name extends `Tiny.fn_star` and a placeholder-cell
/// pattern handles self-reference.
fn compileFn(
    parent: *Emitter,
    name: ?[]const u8,
    params: []const []const u8,
    rest_param: ?[]const u8,
    body: *const Tiny,
    dst: u12,
) CompileError!void {
    // Reject duplicate parameter names (peer-AI turn 40).
    // O(N²) is fine for v1; nexis fns are rarely high-arity.
    for (params, 0..) |p, i| {
        for (params[0..i]) |q| {
            if (std.mem.eql(u8, p, q)) return CompileError.DuplicateParam;
        }
    }
    // Step 5e: rest param can't shadow any fixed param.
    if (rest_param) |rp| {
        for (params) |p| {
            if (std.mem.eql(u8, rp, p)) return CompileError.DuplicateParam;
        }
    }
    // Per peer-AI turn 43: argc encodes in a 12-bit operand
    // (max 4095), AND a fresh result slot must fit above the
    // params (so max practical arity is 4095). Reject > 4095.
    if (params.len > 4095) return CompileError.SlotOverflow;

    // Step 5c (named fn* self-reference): if the fn has a
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

    // Spawn child Emitter linked to parent (step 5b: parent
    // pointer enables capture discovery; was null in 5a1).
    //
    // Use `defer` (not `errdefer`) per peer-AI turn 43: after a
    // successful `child.finish()`, the transferred ArrayLists
    // (code/consts/capture_descs) are emptied via `toOwnedSlice`,
    // but `child.scope` and `child.captures` retain their
    // capacity. `errdefer` would skip cleanup on the success
    // path and leak. `defer` always fires; `Emitter.deinit` on
    // emptied ArrayLists is a no-op so the transfer remains
    // correct.
    var child = Emitter.init(parent.allocator);
    child.parent = parent;
    child.namespace = parent.namespace; // step #6b: inherit ns for def/var resolution
    defer child.deinit();

    // Step 5c: inject self-name as a pre-existing capture so
    // the body's references resolve to upvalue 0 (sourced from
    // the placeholder cell allocated above). The capture
    // descriptor's local_cell_slot source for upvalue 0 will
    // be set up below.
    if (self_referenced) {
        try child.captures.append(child.allocator, .{ .local_cell_slot = self_cell_slot });
        try child.captured_names.append(child.allocator, .{ .name = name.?, .upvalue = 0 });
    }

    // Pre-analyze body to find captured params (peer-AI turn 44,
    // env-aware per turn 45): pass the param set as `env` so
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

    // Step 5e: rest parameter lives at slot `params.len`. The VM
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

    // Step 5d2: set up fn RecurTarget so `(recur ...)` inside
    // the body (with no enclosing `loop*`) rebinds the params
    // and jumps back to the entry point. Captured params get
    // fresh cells per iteration (per VM.md §11 + COMPILER.md
    // §5.6); non-captured get plain mov:move.
    //
    // entry_pc placement: AFTER the box-local prelude. Jumping
    // back must NOT re-box params (would lose the previous
    // iteration's mutated cell pointer); it must land where the
    // body begins reading.
    // RecurTarget covers only FIXED params (step 5e). For
    // variadic fns the `variadic` flag is true; compileRecur
    // traps `UnsupportedFeature` rather than emit subtly-wrong
    // code that rebinds fixed params but leaves the rest list
    // stale (peer-AI turn 49 — proper variadic recur lands
    // later).
    const param_slots = try parent.allocator.alloc(u12, params.len);
    defer parent.allocator.free(param_slots);
    const captured_mask = try parent.allocator.alloc(bool, params.len);
    defer parent.allocator.free(captured_mask);
    for (params, 0..) |p, i| {
        param_slots[i] = @intCast(i); // fixed params live at slots 0..fixed_arity-1
        captured_mask[i] = captured_in_body.contains(p);
    }
    const fn_entry_pc = try child.checkJumpTarget(child.currentPc());
    const fn_target = RecurTarget{
        .entry_pc = fn_entry_pc,
        .binding_slots = param_slots,
        .captured_mask = captured_mask,
        .kind = .fn_star,
        .variadic = rest_param != null,
    };

    // Allocate a fresh result slot for the body so a self-move
    // pattern (compiling a symbol whose binding lives in the
    // result slot) is naturally a no-op (compileSymbol guard).
    const result_slot = try child.allocSlot();
    try compileExpr(&child, body, result_slot, &fn_target);
    try child.emit(vm.asm_.returnSlot(result_slot));

    // Step 5b: capture descriptor sources come from
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
    // pointer outlives both Compiled artifacts (peer-AI turn 42:
    // compile-arena-owned routine tree).
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
        .name = "<anon-fn>",
    };

    // Register the routine + the (possibly non-empty) capture
    // descriptor in the PARENT's pools.
    const proto_idx = try parent.addRoutineConst(child_routine);
    const cap_desc_idx = try parent.addCaptureDescriptor(.{ .sources = sources });

    // Emit closure:make in parent.
    try parent.emit(vm.asm_.closureMake(proto_idx, cap_desc_idx, dst));

    // Step 5c: if self-referenced, finalize the placeholder
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
/// Sequence (peer-AI turn 34 + COMPILER.md §5.6b):
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

    // Step 1: allocate placeholder cells for each binding;
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

    // Step 2: compile each fn (constructing closures). We
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
        // letfn* bindings are always fixed-arity (no rest param
        // syntax in (letfn* [(name [params] body) ...]) form).
        try compileFn(e, null, b.params, null, b.body, cs);
    }

    // Step 3: init each cell with its closure.
    for (bindings, 0..) |_, i| {
        try e.emit(vm.asm_.closureInitCell(cell_slots[i], vm.Operand.slot(closure_slots[i])));
    }

    // Step 4: compile body in the now-fully-bound scope. Body
    // is in tail position relative to the enclosing form; inherit
    // recur target.
    try compileExpr(e, body, dst, recur_target);
}

/// Lower a function-call form: stage callee + args in a
/// contiguous call block per VM.md §6 range-call ABI, emit
/// `call:call`. The result lands in `dst`.
///
/// **Critical** (peer-AI turn 43): the entire `1 + args.len`
/// contiguous call block MUST be reserved BEFORE compiling
/// any sub-expression. An earlier per-arg allocSlot pattern
/// silently broke when the callee or any arg's compilation
/// allocated its own temp slots — the next arg's allocated
/// slot would no longer be adjacent to the previous one,
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
    // Test is NON-tail (peer-AI turn 47).
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
    // harmless — see peer-AI turn 47 §7 dead-code note.)
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
fn runTiny(arena: *std.heap.ArenaAllocator, form: *const Tiny) !Value {
    const compiled = try compileTiny(arena.allocator(), form);
    const routine = compiled.toRoutine("test");
    var v = try vm.VM.init(testing.allocator, &routine);
    defer v.deinit();
    return try v.run();
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

test "compile + run: (+ fixnum_max 1) compiles but VM traps overflow" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const compiled = try compileTiny(
        arena.allocator(),
        &.{ .add = .{ .lhs = &.{ .int = value_mod.fixnum_max }, .rhs = &.{ .int = 1 } } },
    );
    const routine = compiled.toRoutine("(+ fixnum_max 1)");
    var v = try vm.VM.init(testing.allocator, &routine);
    defer v.deinit();
    const res = v.run();
    try testing.expectError(vm.VmError.IntegerOverflow, res);
}

// ---- step 5d0: cmp:lt tests ----

test "compile 5d0: (< 1 2) = true" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try runTiny(&arena, &.{ .lt = .{ .lhs = &.{ .int = 1 }, .rhs = &.{ .int = 2 } } });
    try testing.expect(result.isBool());
    try testing.expectEqual(true, result.asBool());
}

test "compile 5d0: (< 2 1) = false" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try runTiny(&arena, &.{ .lt = .{ .lhs = &.{ .int = 2 }, .rhs = &.{ .int = 1 } } });
    try testing.expectEqual(false, result.asBool());
}

test "compile 5d0: (< 3 3) = false — strict less-than" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try runTiny(&arena, &.{ .lt = .{ .lhs = &.{ .int = 3 }, .rhs = &.{ .int = 3 } } });
    try testing.expectEqual(false, result.asBool());
}

test "compile 5d0: (if (< x 5) 'lt' 'ge') threads through if" {
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

test "compile 5d0: nested (< (+ a b) c) — operands are sub-expressions" {
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

// ---- step 5d1 / 5d2: loop* + recur tests ----

test "compile 5d1: (loop* [i 0] i) — degenerate loop, body returns binding" {
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

test "compile 5d1: (loop* [i 0] (if (< i 1) (recur (+ i 1)) i)) = 1 — one iteration" {
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

test "compile 5d1: (loop* [i 0 acc 0] (if (< i 10) (recur (+ i 1) (+ acc i)) acc)) = 45" {
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

test "compile 5d1: 10k iteration loop runs in CONSTANT stack space" {
    // Per peer-AI turn 47 §Q5: assert stack_high_water doesn't
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

test "compile 5d1: (loop* [a 1 b 2] (if false (recur b a) (+ a b))) = 3 — aliasing recur (untaken)" {
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

test "compile 5d1: (loop* [a 1 b 2] (if true (recur b a) (+ a b))) — recur b a swaps then if continued" {
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

test "compile 5d1: captured loop binding gets fresh cell per iteration (peer-AI turn 47 canonical test)" {
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

test "compile 5d2: fn* recur self-call — (fn* [n] (if (< n 5) (recur (+ n 1)) n)) called with 0 = 5" {
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

test "compile 5d2: nested fn* RESETS recur target (recur in inner fn targets inner, not outer loop)" {
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

test "compile 5d1: recur outside tail (in let RHS) → RecurOutsideTail" {
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

test "compile 5d1: recur outside any loop/fn → RecurOutsideTail" {
    // Top-level recur with no enclosing target.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const form: Tiny = .{ .recur = .{ .args = &.{} } };
    try testing.expectError(CompileError.RecurOutsideTail, compileTiny(arena.allocator(), &form));
}

test "compile 5d1: recur arity mismatch → RecurArityMismatch" {
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

test "compile 5d2: fn* recur arity mismatch → RecurArityMismatch" {
    // (fn* [a b] (recur 1)) — fn has 2 params, recur gives 1 arg.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const recur_form: Tiny = .{ .recur = .{ .args = &.{&.{ .int = 1 }} } };
    const fn_form: Tiny = .{ .fn_star = .{ .params = &.{ "a", "b" }, .body = &recur_form } };
    try testing.expectError(CompileError.RecurArityMismatch, compileTiny(arena.allocator(), &fn_form));
}

test "compile 5d1: recur in (do non-last) is non-tail → RecurOutsideTail" {
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

test "compile 5d1: recur in (do last) IS tail position" {
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

test "compile 5d1: loop* body can read outer let binding (lexical reference, not a closure capture)" {
    // (let* [x 100] (loop* [i 0] (if (< i 1) (recur (+ i x)) i))) = 100
    // Renamed per peer-AI turn 48: no closure involved; just a
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

test "compile 5d2: captured fn* param gets fresh cell across recur (peer-AI turn 48 analog)" {
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

test "compile 5d1: letfn* body inherits enclosing loop's recur target" {
    // (loop* [i 0]
    //   (letfn* [(f [] 1)]
    //     (if (< i 1)
    //       (recur (+ i 1))
    //       i))) = 1
    // The recur sits inside letfn* body's if-then. letfn body
    // must propagate the outer loop's recur target so recur
    // can find it (peer-AI turn 47: letfn body inherits target).
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

test "compile 5d2: recur inside letfn* fn body targets that fn (RESET at fn boundary)" {
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

test "compile 5d1: recur in if-test position → RecurOutsideTail" {
    // (loop* [i 0] (if (recur 1) i i))
    // recur is in if's TEST, which is non-tail (peer-AI turn 48).
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

test "compile 5d1: recur in call-arg position → RecurOutsideTail" {
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

test "compile 5d1: nested loop* — inner recur targets inner loop only" {
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

// ---- step 5e: variadic params (& rest) tests ----

test "compile 5e: ((fn* [a & r] a) 1 2 3) = 1 — rest collected but unused" {
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

test "compile 5e: ((fn* [a & r] r) 1 2 3) returns list (2 3)" {
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

test "compile 5e: ((fn* [a & r] r) 1) returns empty list — argc == fixed_arity" {
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

test "compile 5e: ((fn* [& r] r) 1 2 3 4) — fixed_arity 0 variadic, all args to rest" {
    // Verifies element ORDER and contents, not just count
    // (peer-AI turn 50): list should be (1 2 3 4), not e.g.
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

test "compile 5e: ((fn* [& r] r)) — fixed_arity 0 variadic, no args" {
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

test "compile 5e: variadic with too few args traps :arity-mismatch at runtime" {
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

test "compile 5e: variadic captured rest param survives across fn returns" {
    // (((fn* [a & r] (fn* [] r)) 1 2 3))
    // Outer fn captures r as upvalue of inner fn; inner returns
    // r. Result should be list (2 3) — verify CONTENTS, not
    // just count (peer-AI turn 50: count check wouldn't catch
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

test "compile 5e: duplicate rest+fixed name → DuplicateParam" {
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

test "compile 5e: recur in variadic fn body → UnsupportedFeature" {
    // (fn* [a & r] (recur 1)) — variadic recur deferred per
    // peer-AI turn 49.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const recur_form: Tiny = .{ .recur = .{ .args = &.{&.{ .int = 1 }} } };
    const fn_form: Tiny = .{ .fn_star = .{
        .params = &.{"a"},
        .rest_param = "r",
        .body = &recur_form,
    } };
    try testing.expectError(CompileError.UnsupportedFeature, compileTiny(arena.allocator(), &fn_form));
}

test "compile 5e: recur in NON-variadic fn body still works (regression check for 5d2)" {
    // Make sure my variadic-recur rejection didn't break
    // ordinary fn-recur from 5d2.
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

// ---- step #6b: def + var + symbol fall-through tests ----

/// Helper: compile + run with a namespace owned by a VM.
/// Builds a stub VM (just to own the namespace), gets the
/// namespace, compiles with it, then patches the VM's top
/// frame to the real routine. Same pattern as the #6a tests.
fn runTinyWithNs(
    arena: *std.heap.ArenaAllocator,
    form: *const Tiny,
) !value_mod.Value {
    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(testing.allocator, &stub);
    defer v.deinit();
    const ns = v.ensureNamespace();
    const compiled = try compileTinyWithNamespace(arena.allocator(), form, ns);
    const routine = compiled.toRoutine("test-with-ns");
    v.frames.items[0].routine = &routine;
    v.frames.items[0].pc = 0;
    v.frames.items[0].slot_count = routine.slot_count;
    // Make sure stack is large enough for the new routine.
    if (v.stack.items.len < routine.slot_count) {
        try v.stack.appendNTimes(
            v.allocator,
            value_mod.nilValue(),
            routine.slot_count - v.stack.items.len,
        );
    }
    return try v.run();
}

test "compile #6b: (def x 5) returns the Var object" {
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
    v.frames.items[0].routine = &routine;
    v.frames.items[0].pc = 0;
    v.frames.items[0].slot_count = routine.slot_count;
    if (v.stack.items.len < routine.slot_count) {
        try v.stack.appendNTimes(v.allocator, value_mod.nilValue(), routine.slot_count - v.stack.items.len);
    }
    const result = try v.run();

    try testing.expect(result.kind() == .var_);
    const var_obj = vm.VM.asVar(result);
    try testing.expect(var_obj.bound);
    try testing.expectEqual(@as(i64, 5), var_obj.root.asFixnum());
    try testing.expectEqualStrings("x", var_obj.name);
}

test "compile #6b: (do (def x 5) x) reads root via symbol fall-through" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const def_form: Tiny = .{ .def = .{ .name = "x", .value = &.{ .int = 5 } } };
    const form: Tiny = .{ .do_ = &.{ &def_form, &.{ .symbol = "x" } } };
    const result = try runTinyWithNs(&arena, &form);
    try testing.expect(result.isFixnum());
    try testing.expectEqual(@as(i64, 5), result.asFixnum());
}

test "compile #6b: (do (def x 5) (def x 10) x) — rebind preserves identity" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const def1: Tiny = .{ .def = .{ .name = "x", .value = &.{ .int = 5 } } };
    const def2: Tiny = .{ .def = .{ .name = "x", .value = &.{ .int = 10 } } };
    const form: Tiny = .{ .do_ = &.{ &def1, &def2, &.{ .symbol = "x" } } };
    const result = try runTinyWithNs(&arena, &form);
    try testing.expectEqual(@as(i64, 10), result.asFixnum());
}

test "compile #6b: (var x) returns the Var object (unbound OK)" {
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
    v.frames.items[0].routine = &routine;
    v.frames.items[0].pc = 0;
    v.frames.items[0].slot_count = routine.slot_count;
    if (v.stack.items.len < routine.slot_count) {
        try v.stack.appendNTimes(v.allocator, value_mod.nilValue(), routine.slot_count - v.stack.items.len);
    }
    const result = try v.run();

    try testing.expect(result.kind() == .var_);
    const var_obj = vm.VM.asVar(result);
    try testing.expect(!var_obj.bound);
    try testing.expectEqualStrings("unbound-yet", var_obj.name);
}

test "compile #6b: reading an unbound Var traps :unbound-var at runtime" {
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
    v.frames.items[0].routine = &routine;
    v.frames.items[0].pc = 0;
    v.frames.items[0].slot_count = routine.slot_count;
    try testing.expectError(vm.VmError.UnboundVar, v.run());
}

test "compile #6b: without a namespace, unresolved symbol still raises UnresolvedSymbol" {
    // Regression: compileTiny (no namespace) must keep the
    // pre-#6b error semantics.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const form: Tiny = .{ .symbol = "x" };
    try testing.expectError(CompileError.UnresolvedSymbol, compileTiny(arena.allocator(), &form));
}

test "compile #6b: without a namespace, def raises UnresolvedSymbol" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const form: Tiny = .{ .def = .{ .name = "x", .value = &.{ .int = 5 } } };
    try testing.expectError(CompileError.UnresolvedSymbol, compileTiny(arena.allocator(), &form));
}

test "compile #6b: lexical local shadows namespace Var" {
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

test "compile #6b: same Var referenced multiple times shares one var_table index (dedup)" {
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

// ---- step #6c: defn + forward references tests ----

test "compile #6c: (do (defn add1 [n] (+ n 1)) (add1 5)) = 6" {
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

test "compile #6c: (do (defn zero [] 0) (zero)) = 0 — nullary defn" {
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

test "compile #6c: defn supports recur for self-call (named fn* under the hood)" {
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

test "compile #6c: forward reference — defn f calls g defined later" {
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

test "compile #6c: forward reference + call before bind → UnboundVar trap" {
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
    v.frames.items[0].routine = &routine;
    v.frames.items[0].pc = 0;
    v.frames.items[0].slot_count = routine.slot_count;
    if (v.stack.items.len < routine.slot_count) {
        try v.stack.appendNTimes(v.allocator, value_mod.nilValue(), routine.slot_count - v.stack.items.len);
    }
    try testing.expectError(vm.VmError.UnboundVar, v.run());
}

test "compile #6c: defn rebinding preserves Var identity" {
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

test "compile #6c: defn with rest param works end-to-end" {
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

// ---- if-form tests (peer-AI turn 36 checklist) ----

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

// ---- step #4: symbol / let* / do tests (peer-AI turn 38 checklist) ----

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
    // Pre-empts a future optimization that might skip non-last
    // do expressions because their values are discarded
    // (peer-AI turn 39). Discarded value ≠ discarded compilation:
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
    // scope + sequential RHS visibility (peer-AI turn 39).
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
    const failing: Tiny = .{ .let_star = .{
        .bindings = &.{.{ .name = "x", .value = &.{ .int = 1 } }},
        .body = &.{ .symbol = "y" }, // y is unbound → error
    } };
    const res1 = compileTiny(arena.allocator(), &failing);
    try testing.expectError(CompileError.UnresolvedSymbol, res1);
    // The scope should not have leaked `x`. A fresh compile
    // referencing `x` should still fail.
    const res2 = compileTiny(arena.allocator(), &.{ .symbol = "x" });
    try testing.expectError(CompileError.UnresolvedSymbol, res2);
}

// ---- step 5a1: fn* + call tests (peer-AI turn 42 checklist) ----

test "compile 5a1: ((fn* [] 42)) = 42" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fn_form: Tiny = .{ .fn_star = .{ .params = &.{}, .body = &.{ .int = 42 } } };
    const result = try runTiny(&arena, &.{ .call = .{ .callee = &fn_form, .args = &.{} } });
    try testing.expectEqual(@as(i64, 42), result.asFixnum());
}

test "compile 5a1: ((fn* [x] (+ x 1)) 5) = 6" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body: Tiny = .{ .add = .{ .lhs = &.{ .symbol = "x" }, .rhs = &.{ .int = 1 } } };
    const fn_form: Tiny = .{ .fn_star = .{ .params = &.{"x"}, .body = &body } };
    const call_form: Tiny = .{ .call = .{ .callee = &fn_form, .args = &.{&.{ .int = 5 }} } };
    const result = try runTiny(&arena, &call_form);
    try testing.expectEqual(@as(i64, 6), result.asFixnum());
}

test "compile 5a1: ((fn* [x y] (+ x y)) 3 4) = 7" {
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

test "compile 5a1: (let* [f (fn* [x] (+ x 1))] (f 5)) = 6 — fn bound in let" {
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

test "compile 5b: (let* [x 5] ((fn* [y] x) 3)) = 5 — single capture" {
    // Step 5b: this is the canonical hand-trace example
    // (lazy-boxing capture). Outer x = 5 is captured by inner
    // fn body. compileSymbol for `x` inside the fn body walks
    // to parent, triggers lazy box-local on outer's x, registers
    // the capture source, returns BindingRef.upvalue(0).
    // The fn body emits `mov:move dst, u:0` which deref's the
    // cell at runtime.
    //
    // (In 5a1 this raised UnresolvedSymbol because child
    // Emitter had no parent pointer. 5b's resolveOrCapture
    // resolves it correctly.)
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

test "compile 5a1: nested call ((fn* [x] x) ((fn* [y] (+ y 1)) 4)) = 5" {
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

test "compile 5a1: duplicate param (fn* [x x] x) → DuplicateParam" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fn_form: Tiny = .{ .fn_star = .{
        .params = &.{ "x", "x" },
        .body = &.{ .symbol = "x" },
    } };
    const res = compileTiny(arena.allocator(), &fn_form);
    try testing.expectError(CompileError.DuplicateParam, res);
}

test "compile 5a1: arity mismatch — call with too few args traps :arity-mismatch at runtime" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fn_form: Tiny = .{ .fn_star = .{
        .params = &.{ "x", "y" },
        .body = &.{ .symbol = "x" },
    } };
    const call_form: Tiny = .{ .call = .{
        .callee = &fn_form,
        .args = &.{&.{ .int = 1 }}, // only 1 arg, fn expects 2
    } };
    const compiled = try compileTiny(arena.allocator(), &call_form);
    const routine = compiled.toRoutine("arity-test");
    var v = try vm.VM.init(testing.allocator, &routine);
    defer v.deinit();
    const res = v.run();
    try testing.expectError(vm.VmError.ArityMismatch, res);
}

test "compile 5a1: same closure called twice — both invocations succeed" {
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

test "compile 5a1: fn body uses if + symbol — no captures needed" {
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

// ---- step 5b: capture machinery tests ----

test "compile 5b: (let* [x 5] ((fn* [y] (+ x y)) 3)) = 8 — capture + use" {
    // The canonical hand-trace from before 5b implementation.
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

test "compile 5b: (let* [x 5 y 10] ((fn* [] (+ x y)))) = 15 — multi-capture" {
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

test "compile 5b: (let* [x 5] (let* [f (fn* [] x)] (f))) = 5 — let-bound captured fn" {
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

test "compile 5b: (let* [x 5] ((fn* [] ((fn* [] x))))) = 5 — transitive capture" {
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

test "compile 5b: same binding captured twice — second capture re-uses existing cell" {
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

test "compile 5b: captured + non-captured params mix" {
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

test "compile 5b: still-unresolved symbol traps UnresolvedSymbol" {
    // (let* [x 5] ((fn* [] z))) — z is not in any enclosing
    // scope. With 5b's parent-chain walk, the chain still
    // bottoms out at top-level Emitter with no parent →
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

test "compile 5b: captured fn used after let binding scope (closure outlives binding)" {
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

test "compile 5b: same-frame read of a captured binding after capture" {
    // (let* [x 5] (do ((fn* [] x)) x)) — outer let body's
    // second expression reads `x` AFTER the inner fn captured
    // it. By 5b lazy-boxing, x is now .cell_slot in outer
    // scope; the second read emits closure:get-cell instead of
    // mov:move.
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

// ---- step 5b control-flow safety tests (peer-AI turn 44) ----

test "compile 5b: capture in unreachable branch — same-frame read works" {
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

test "compile 5b: capture in unreachable branch — second closure construction works" {
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

test "compile 5b: capture in taken branch still works" {
    // (let* [x 5] (do (if true (fn* [] x) 0) x)) = 5
    //
    // Sanity: the case the lazy-boxing model did handle
    // correctly should still work after the pre-analysis fix.
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

test "compile 5b: three-level transitive capture (let [x] ((fn () ((fn () ((fn () x))))))) = 5" {
    // Pin the recursive resolveOrCapture invariant at deeper
    // nesting (peer-AI turn 44 sanity check).
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

test "compile 5b: shadowing capture — inner let-bound x shadows outer for inner fn" {
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

test "compile 5b: outer x captured by f, inner x shadows for body but not f's captured value" {
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

test "compile 5b: param shadowed by inner let — only inner is captured (peer-AI turn 45)" {
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

test "compile 5b: captured param + branch — param boxed at fn entry (peer-AI turn 45)" {
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

// ---- regression: 5a1 tests continue to work in 5b ----

test "compile 5a1: ((fn* [x y] (+ x y)) ((fn* [a] a) 1) 2) = 3 — call-block contiguity regression" {
    // Peer-AI turn 43 catch: prior compileCall allocated arg slots
    // one-at-a-time, so a non-trivial first arg (which itself
    // allocates temps for its own call block) would push the
    // second arg's slot past the predetermined position, breaking
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

test "compile 5a1: fn body uses inner let* — no captures of outer needed" {
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

// ---- step 5c: named fn* + letfn* tests ----

test "compile 5c: named fn* without self-reference compiles as anonymous" {
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

test "compile 5c: named fn* with self-ref in dead branch — placeholder allocated, no infinite recursion" {
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

test "compile 5c: named fn* with recursive ref in untaken branch — placeholder allocated, base branch executes" {
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

test "compile 5c: named fn* in let — recursive reference works after let-binding scope" {
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

test "compile 5c: (letfn* [(f [x] (+ x 1))] (f 10)) = 11 — single binding" {
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

test "compile 5c: (letfn* [(f [] (g)) (g [] 42)] (f)) = 42 — f calls g (forward ref)" {
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

test "compile 5c: letfn* mutual recursion (dead branches only)" {
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

test "compile 5c: named self shadowed by inner let — no placeholder, returns let value" {
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

test "compile 5c: named self shadows outer binding — body sees the closure, not outer foo" {
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

test "compile 5c: named fn* param shadows self-name (intentional Tiny semantics)" {
    // ((fn* foo [foo] foo) 7) = 7
    // The param `foo` shadows the self-name. Pre-analysis
    // sees `foo` is NOT a free var of the body (because the
    // param binds it), so no placeholder is allocated, and
    // the body's `foo` resolves to the param (= 7).
    // (Peer-AI turn 46: pin behavior with explicit test.)
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fn_form: Tiny = .{ .fn_star = .{ .name = "foo", .params = &.{"foo"}, .body = &.{ .symbol = "foo" } } };
    const call_form: Tiny = .{ .call = .{ .callee = &fn_form, .args = &.{&.{ .int = 7 }} } };
    const result = try runTiny(&arena, &call_form);
    try testing.expectEqual(@as(i64, 7), result.asFixnum());
}

test "compile 5c: letfn binding captures both another letfn binding and outer let binding" {
    // (let* [x 10]
    //   (letfn* [(f [] (+ x (g)))
    //            (g [] 5)]
    //     (f))) = 15
    // f's closure capture descriptor has two sources: one for
    // the outer let's x (cell_slot in outer frame) and one
    // for g (cell_slot in letfn frame). Validates mixed-source
    // capture descriptors compose correctly (peer-AI turn 46).
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

test "compile 5c: letfn* with three bindings, chained calls" {
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

test "compile 5c: letfn* shadows outer let binding" {
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

test "compile 5c: letfn* binding captures outer let binding" {
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

test "compile 5c: letfn* — body sees bindings (calls one of them)" {
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

test "compile 5c: letfn* duplicate name → DuplicateBinding" {
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

test "compile 5c: letfn* body scope properly restored after letfn*" {
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

// ---- step #7a: Form → Tiny lowering + compileSource tests ----

test "compile #7a: lowerForm of nil → run → nil" {
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

test "compile #7a: lowerForm of bool true → run → true" {
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

test "compile #7a: lowerForm of int 42 → run → 42" {
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

test "compile #7a: compileSource \"nil\" → nil" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const compiled = try compileSource(arena.allocator(), "nil");
    const routine = compiled.toRoutine("src-nil");
    var v = try vm.VM.init(testing.allocator, &routine);
    defer v.deinit();
    const result = try v.run();
    try testing.expect(result.isNil());
}

test "compile #7a: compileSource \"true\" → true" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const compiled = try compileSource(arena.allocator(), "true");
    const routine = compiled.toRoutine("src-true");
    var v = try vm.VM.init(testing.allocator, &routine);
    defer v.deinit();
    const result = try v.run();
    try testing.expectEqual(true, result.asBool());
}

test "compile #7a: compileSource \"false\" → false" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const compiled = try compileSource(arena.allocator(), "false");
    const routine = compiled.toRoutine("src-false");
    var v = try vm.VM.init(testing.allocator, &routine);
    defer v.deinit();
    const result = try v.run();
    try testing.expectEqual(false, result.asBool());
}

test "compile #7a: compileSource \"42\" → 42" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const compiled = try compileSource(arena.allocator(), "42");
    const routine = compiled.toRoutine("src-42");
    var v = try vm.VM.init(testing.allocator, &routine);
    defer v.deinit();
    const result = try v.run();
    try testing.expectEqual(@as(i64, 42), result.asFixnum());
}

test "compile #7a: compileSource \"-7\" → -7" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const compiled = try compileSource(arena.allocator(), "-7");
    const routine = compiled.toRoutine("src-neg7");
    var v = try vm.VM.init(testing.allocator, &routine);
    defer v.deinit();
    const result = try v.run();
    try testing.expectEqual(@as(i64, -7), result.asFixnum());
}

test "compile #7a: compileSource of unqualified symbol with no namespace → UnresolvedSymbol" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(
        CompileError.UnresolvedSymbol,
        compileSource(arena.allocator(), "x"),
    );
}

test "compile #7a: compileSource of symbol resolves via namespace fall-through" {
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
    v.frames.items[0].routine = &routine;
    v.frames.items[0].pc = 0;
    v.frames.items[0].slot_count = routine.slot_count;
    if (v.stack.items.len < routine.slot_count) {
        try v.stack.appendNTimes(v.allocator, value_mod.nilValue(), routine.slot_count - v.stack.items.len);
    }
    const result = try v.run();
    try testing.expectEqual(@as(i64, 99), result.asFixnum());
}

test "compile #7a: lowerForm of string literal → UnsupportedFeature (deferred)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const form = reader_mod.Form{ .datum = .{ .string = "hello" }, .origin = .{ .pos = 0, .len = 0 } };
    try testing.expectError(CompileError.UnsupportedFeature, lowerForm(arena.allocator(), &form));
}

test "compile #7a: lowerForm of keyword → UnsupportedFeature (deferred)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const form = reader_mod.Form{
        .datum = .{ .keyword = .{ .ns = null, .name = "foo" } },
        .origin = .{ .pos = 0, .len = 0 },
    };
    try testing.expectError(CompileError.UnsupportedFeature, lowerForm(arena.allocator(), &form));
}

test "compile #7a: lowerForm of list → UnsupportedFeature (lands in #7b)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const empty: []const *reader_mod.Form = &.{};
    const form = reader_mod.Form{ .datum = .{ .list = empty }, .origin = .{ .pos = 0, .len = 0 } };
    try testing.expectError(CompileError.UnsupportedFeature, lowerForm(arena.allocator(), &form));
}

test "compile #7a: lowerForm of quote → UnsupportedFeature (lands in #7b)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var inner = reader_mod.Form{ .datum = .{ .int = 42 }, .origin = .{ .pos = 0, .len = 0 } };
    const form = reader_mod.Form{ .datum = .{ .quote = &inner }, .origin = .{ .pos = 0, .len = 0 } };
    try testing.expectError(CompileError.UnsupportedFeature, lowerForm(arena.allocator(), &form));
}

test "compile #7a: lowerForm of qualified symbol → UnsupportedFeature (post-v1 multi-ns)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const form = reader_mod.Form{
        .datum = .{ .symbol = .{ .ns = "foo", .name = "x" } },
        .origin = .{ .pos = 0, .len = 0 },
    };
    try testing.expectError(CompileError.UnsupportedFeature, lowerForm(arena.allocator(), &form));
}

test "compile #7a: compileSource of malformed input → ReaderFailure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Unmatched paren — reader rejects.
    try testing.expectError(
        CompileError.ReaderFailure,
        compileSource(arena.allocator(), "(foo"),
    );
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
