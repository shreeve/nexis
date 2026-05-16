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
    /// `(fn* [params...] body)` per PLAN §6.1.
    /// Step 5a1: empty-capture closures only. Bodies must NOT
    /// reference free variables (anything not in `params`);
    /// such references raise `UnresolvedSymbol` at compile time
    /// (per peer-AI turn 42 — capture/parent-scope walk lands
    /// in 5b). Named `fn*` deferred to 5c per turn 42 — for
    /// now, no self-name is allowed.
    fn_star: struct {
        params: []const []const u8,
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
    slot_count: u16,
    /// Top-level Compiled has arity 0; child routines built by
    /// `compileFn` set this to their parameter count.
    arity: u16 = 0,

    pub fn toRoutine(self: Compiled, name: []const u8) Routine {
        return .{
            .code = self.code,
            .consts = self.consts,
            .capture_descs = self.capture_descs,
            .slot_count = self.slot_count,
            .arity = self.arity,
            .upvalue_count = 0, // 5a1: no captures
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
        return .{
            .code = code,
            .consts = consts,
            .capture_descs = caps,
            .slot_count = if (self.slot_count == 0) 1 else self.slot_count,
            .arity = 0, // top-level only; compileFn sets this for child routines via Routine struct
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
    var emitter = Emitter.init(allocator);
    errdefer emitter.deinit();

    // Top-level form compiles into slot 0; routine returns slot 0.
    const dst = try emitter.allocSlot();
    try compileExpr(&emitter, form, dst);
    try emitter.emit(vm.asm_.returnSlot(dst));

    return try emitter.finish();
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
            // fn body's env = outer env + params. Names referenced
            // in fn body not bound by either are "free" — they
            // escape ALL bound scopes (including outer's), so
            // they bubble up here too.
            var fn_env: NameSet = .{};
            defer fn_env.deinit(allocator);
            try fn_env.unionWith(allocator, env);
            for (f.params) |p| try fn_env.put(allocator, p);
            try freeVars(allocator, f.body, &fn_env, out);
        },
        .call => |c| {
            try freeVars(allocator, c.callee, env, out);
            for (c.args) |a| try freeVars(allocator, a, env, out);
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
            // This fn body has its own params as initial env.
            // The fn's free vars (against params + inner
            // bindings) are the names it actually captures from
            // OUR scope. We want only those that match `env`.
            //
            // freeVars already recurses through nested fn_stars
            // (with appropriate inner envs), so descendant fns'
            // captures bubble up here correctly. No additional
            // capturedByDescendantFns recursion needed (peer-AI
            // turn 45 simplification — was redundant).
            var params_env: NameSet = .{};
            defer params_env.deinit(allocator);
            for (f.params) |p| try params_env.put(allocator, p);
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
/// form's result in `slot[dst]`.
fn compileExpr(e: *Emitter, form: *const Tiny, dst: u12) CompileError!void {
    switch (form.*) {
        .nil => try e.emit(vm.asm_.loadNil(dst)),
        .bool => |b| try e.emit(if (b) vm.asm_.loadTrue(dst) else vm.asm_.loadFalse(dst)),
        .int => |n| try compileIntLiteral(e, n, dst),
        .symbol => |name| try compileSymbol(e, name, dst),
        .add => |a| try compileAdd(e, a.lhs, a.rhs, dst),
        .if_ => |i| try compileIf(e, i.test_, i.then, i.else_, dst),
        .let_star => |l| try compileLetStar(e, l.bindings, l.body, dst),
        .do_ => |exprs| try compileDo(e, exprs, dst),
        .fn_star => |f| try compileFn(e, f.params, f.body, dst),
        .call => |c| try compileCall(e, c.callee, c.args, dst),
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
    // Non-literal operands: stage into temp slots first.
    const t_lhs = try e.allocSlot();
    try compileExpr(e, lhs, t_lhs);
    const t_rhs = try e.allocSlot();
    try compileExpr(e, rhs, t_rhs);
    try e.emit(vm.asm_.mathAdd(dst, Operand.slot(t_lhs), Operand.slot(t_rhs)));
}

fn compileSymbol(e: *Emitter, name: []const u8, dst: u12) CompileError!void {
    // Step 5b (peer-AI turn 40 lazy-boxing): resolution walks
    // self first, then parents. A parent-scope hit triggers
    // capture (lazy box-local in parent, push as upvalue in
    // self). Step #7 (vars) extends this fall-through:
    //   1. local (this routine) → dispatch on BindingRef
    //   2. captured upvalue (parent chain) → resolve.upvalue + capture
    //   3. namespace var → var:load-var
    //   4. error → :unresolved-symbol
    const ref = try e.resolveOrCapture(name);
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

fn compileLetStar(
    e: *Emitter,
    bindings: []const Binding,
    body: *const Tiny,
    dst: u12,
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
        try compileExpr(e, b.value, slot);

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

    try compileExpr(e, body, dst);
}

fn compileDo(e: *Emitter, exprs: []const *const Tiny, dst: u12) CompileError!void {
    // Empty do is nil.
    if (exprs.len == 0) {
        try e.emit(vm.asm_.loadNil(dst));
        return;
    }
    // Single-expression do compiles directly into dst.
    if (exprs.len == 1) {
        try compileExpr(e, exprs[0], dst);
        return;
    }
    // Multi-expression: ALL non-last go to a SHARED discard
    // slot (peer-AI turn 38: avoids the 999-slot blowup that
    // `(do e1 e2 ... e1000)` would cause with fresh-per-expr
    // allocation). Reusing one discard slot for all ignored
    // results is the natural meaning of "compile this for its
    // effect only" — not asymmetric liveness analysis.
    const discard = try e.allocSlot();
    for (exprs[0 .. exprs.len - 1]) |expr| {
        try compileExpr(e, expr, discard);
    }
    try compileExpr(e, exprs[exprs.len - 1], dst);
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
    params: []const []const u8,
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
    // Per peer-AI turn 43: argc encodes in a 12-bit operand
    // (max 4095), AND a fresh result slot must fit above the
    // params (so max practical arity is 4095). Reject > 4095.
    if (params.len > 4095) return CompileError.SlotOverflow;

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
    defer child.deinit();

    // Pre-analyze body to find captured params (peer-AI turn 44,
    // env-aware per turn 45): pass the param set as `env` so
    // the analyzer only reports captures matching one of OUR
    // params (and not, e.g., a same-named binding shadowed
    // inside an inner let_star).
    var params_env: NameSet = .{};
    defer params_env.deinit(parent.allocator);
    for (params) |p| try params_env.put(parent.allocator, p);
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

    // Allocate a fresh result slot for the body so a self-move
    // pattern (compiling a symbol whose binding lives in the
    // result slot) is naturally a no-op (compileSymbol guard).
    const result_slot = try child.allocSlot();
    try compileExpr(&child, body, result_slot);
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
        .slot_count = child_compiled.slot_count,
        .arity = @intCast(params.len),
        .upvalue_count = upvalue_count,
        .name = "<anon-fn>",
    };

    // Register the routine + the (possibly non-empty) capture
    // descriptor in the PARENT's pools.
    const proto_idx = try parent.addRoutineConst(child_routine);
    const cap_desc_idx = try parent.addCaptureDescriptor(.{ .sources = sources });

    // Emit closure:make in parent.
    try parent.emit(vm.asm_.closureMake(proto_idx, cap_desc_idx, dst));
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
    try compileExpr(e, callee, call_base);
    // Compile each arg into its predetermined slot in the block.
    for (args, 0..) |arg, i| {
        const arg_slot: u12 = @intCast(@as(u32, call_base) + 1 + @as(u32, @intCast(i)));
        try compileExpr(e, arg, arg_slot);
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
) CompileError!void {
    // Lower the test into a fresh temp slot; we can't reuse `dst`
    // because the test value would be overwritten by either arm.
    const t_test = try e.allocSlot();
    try compileExpr(e, test_form, t_test);

    // Emit `jump:if-false PLACEHOLDER, t_test`. Remember its PC
    // for back-patching once the else-label is known.
    const if_false_pc = try e.emitJumpIfFalsePlaceholder(Operand.slot(t_test));

    // Then-arm: compile into dst.
    try compileExpr(e, then_form, dst);

    // Emit `jump:jmp PLACEHOLDER` to skip past the else-arm.
    // Remember its PC for back-patching to end-label.
    const end_jmp_pc = try e.emitJumpPlaceholder();

    // Else-label is at the current PC.
    const else_label = try e.checkJumpTarget(e.currentPc());
    e.patchJumpAt(if_false_pc, else_label);

    // Else-arm: compile into dst (or synthesize nil if absent).
    if (else_form) |ef| {
        try compileExpr(e, ef, dst);
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
