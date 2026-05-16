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
};

/// One binding in a `let*` form.
pub const Binding = struct {
    name: []const u8,
    value: *const Tiny,
};

/// One entry in the Emitter's lexical scope stack. `slot` is the
/// frame slot the binding's value lives in. (Step #5 will widen
/// this to a `BindingRef` union once captured upvalues exist; for
/// step #4, all bindings are direct value slots.)
pub const LocalBinding = struct {
    name: []const u8,
    slot: u12,
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

    OutOfMemory,
};

// =============================================================================
// Output
// =============================================================================

/// The compiler's product. Wrap with `toRoutine(name)` to get a
/// `vm.Routine` ready for `vm.VM.init`.
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
    slot_count: u16,

    pub fn toRoutine(self: Compiled, name: []const u8) Routine {
        return vm.makeRoutine(self.code, self.consts, self.slot_count, name);
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
    scope: std.ArrayList(LocalBinding) = .empty,
    slot_count: u16 = 0,

    fn init(allocator: std.mem.Allocator) Emitter {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *Emitter) void {
        self.code.deinit(self.allocator);
        self.consts.deinit(self.allocator);
        self.scope.deinit(self.allocator);
    }

    /// Push a binding onto the lexical scope. Does NOT allocate
    /// a slot — the caller already has one (typically the slot
    /// the binding's RHS was just compiled into).
    fn pushBinding(self: *Emitter, name: []const u8, slot: u12) CompileError!void {
        try self.scope.append(self.allocator, .{ .name = name, .slot = slot });
    }

    /// Resolve `name` to its slot via innermost-shadow lookup.
    /// Returns null if no binding matches; callers turn that into
    /// `CompileError.UnresolvedSymbol` (the resolution-priority
    /// fall-through to vars / core happens in later steps).
    ///
    /// **Step #4 local-only resolver.** Nested function bodies
    /// (step #5) MUST NOT use this flat lookup across routine
    /// boundaries — outer-routine locals must become captured
    /// upvalues, not direct slot references. Step #5 replaces or
    /// extends this with capture-aware resolution; the most likely
    /// shape is a `LexicalEnv { locals, parent: ?*LexicalEnv,
    /// captures }` chain plus per-binding `BindingRef` records
    /// (peer-AI turn 39).
    fn resolveLocal(self: *const Emitter, name: []const u8) ?u12 {
        var i = self.scope.items.len;
        while (i > 0) {
            i -= 1;
            const b = self.scope.items[i];
            if (std.mem.eql(u8, b.name, name)) return b.slot;
        }
        return null;
    }

    /// Allocate a fresh result slot. Slots are monotonic; no
    /// reclamation in step #3.
    fn allocSlot(self: *Emitter) CompileError!u12 {
        if (self.slot_count >= 4096) return CompileError.SlotOverflow;
        const s = self.slot_count;
        self.slot_count += 1;
        return @intCast(s);
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
    /// `consts.toOwnedSlice` fails after `code.toOwnedSlice`
    /// succeeded, `code` would leak under a non-arena allocator.
    /// The errdefer guards against that.
    fn finish(self: *Emitter) CompileError!Compiled {
        const code = try self.code.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(code);
        const consts = try self.consts.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(consts);
        return .{
            .code = code,
            .consts = consts,
            .slot_count = if (self.slot_count == 0) 1 else self.slot_count,
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
    // Step #4: lexical locals are the only resolution category.
    // When step #7 (vars) lands, this fall-through becomes:
    //   1. local → mov:move dst, slot
    //   2. captured upvalue → resolve(u:N) read (step #5)
    //   3. namespace var → var:load-var dst, var (step #7)
    //   4. error → :unresolved-symbol
    const source_slot = e.resolveLocal(name) orelse
        return CompileError.UnresolvedSymbol;
    // Skip the no-op self-move (peer-AI turn 38). For step #4
    // this case can't actually arise because dst is always
    // caller-allocated and binding slots are Emitter-owned
    // distinct ranges, but the guard preempts a future bug if
    // those allocators ever overlap.
    if (source_slot == dst) return;
    try e.emit(vm.asm_.move(dst, source_slot));
}

fn compileLetStar(
    e: *Emitter,
    bindings: []const Binding,
    body: *const Tiny,
    dst: u12,
) CompileError!void {
    // Strict left-of-self visibility per COMPILER.md §4.3
    // (peer-AI turn 35 + 38): the loop body pushes each
    // binding to scope AFTER its RHS has been compiled. The
    // RHS therefore sees bindings 1..i-1 only, not its own
    // LHS. `(let* [n n] body)` reads outer n for the RHS;
    // `(let* [x 1 y x] body)` binds y to 1.
    //
    // Scope is restored via `defer` (peer-AI turn 38) so an
    // error mid-body doesn't leave scope state polluted for a
    // recovering caller.
    const mark = e.scope.items.len;
    defer e.scope.shrinkRetainingCapacity(mark);

    for (bindings) |b| {
        const slot = try e.allocSlot();
        try compileExpr(e, b.value, slot);
        try e.pushBinding(b.name, slot);
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
