//! compile.zig — the compiler: `reader.Form` → `Tiny` IR → bytecode.
//!
//! Authoritative spec: `docs/COMPILER.md`.
//!
//! **Pipeline**: `compileSourceWith` / `compileFormWith` macroexpand
//! the form (`expand.zig`), lower it to a `Tiny` tree (`lowerForm`),
//! and compile that tree with `emitRoutine`. `Tiny` is
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
//!   - `(+ a b)`, `(< a b)`, `(inc a)` and the other core numeric
//!     fns at the arity they inline at (`inlined_ops`)
//!                               →  one `math` / `cmp` instruction
//!                                  when the operator names
//!                                  `nexis.core`'s Var, operands read
//!                                  in place where they can be
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
//!                                  `closure:make`; lowering marks
//!                                  the bindings closures capture, and
//!                                  they are boxed where they are bound
//!   - `(letfn* ...)`, `(loop* ...)`, `(recur ...)`, `(def ...)`,
//!     `(var name)`
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
//! **Limits**: the primitive `try` takes one `(catch any binding
//! ...)`; the expander lowers several catch clauses and keyword
//! matchers onto it (MACROEXPAND.md §10).

const std = @import("std");
const vm = @import("vm.zig");
const value_mod = @import("value.zig");
/// Compiler input. `lowerForm` translates a reader.Form tree
/// into `Tiny`; the backend compiles `Tiny` only (there is no
/// parallel Form → bytecode path).
const reader_mod = @import("reader.zig");
/// Interner for quoted symbols/keywords during Form lowering.
/// `lowerQuotePayload` interns symbols/keywords through the
/// VM's shared Interner so identity is stable across compile,
/// runtime and macroexpand.
const intern_mod = @import("intern.zig");
/// Form → Form expander: macros, syntax-quote, anon-fn, and the
/// #%list/#%concat/#%vector dispatch all live there. Expansion
/// runs BEFORE lowering whenever `compileFormWith` is given an
/// Interner; without one, no expansion fires.
const expand_mod = @import("expand.zig");
/// Form lowering allocates string-literal Values into a stable
/// Heap so `Tiny.literal` can carry them across compile → run.
/// `LowerCtx.heap` is the optional heap; when null, `.string`
/// Forms raise `UnsupportedFeature`.
const heap_mod = @import("heap.zig");
const string_mod = @import("string.zig");
const bignum_mod = @import("bignum.zig");
const stack = @import("stack.zig");
const list_mod = @import("coll/list.zig");
const vector_mod = @import("coll/vector.zig");
const champ_mod = @import("coll/champ.zig");
const dispatch_mod = @import("dispatch.zig");

pub const Inst = vm.Inst;
pub const Routine = vm.Routine;
pub const Operand = vm.Operand;
pub const Value = value_mod.Value;

// =============================================================================
// Tiny — the compiler's IR: the special forms, with every symbol
// reference still a name. Sub-expressions are pointers into the
// compile allocator (tests build small trees as `&Tiny{ ... }`).
// =============================================================================

pub const Tiny = union(enum) {
    nil,
    bool: bool,
    /// An integer in the i48 fixnum range; lowering makes a wider
    /// literal a bignum `literal`.
    int: i64,
    /// A lexical local, a captured upvalue or a namespace Var, tried
    /// in that order (COMPILER.md §4.3).
    symbol: []const u8,
    /// `prefix/name`: a Var of the namespace `prefix` names, never a
    /// lexical binding; exact, with no parent-chain walk.
    qualified_symbol: struct { ns: []const u8, name: []const u8 },
    /// A constant Value: a keyword, string, float, char, bignum, quoted
    /// symbol, or a collection of constants built at lowering. It
    /// lives in the routine's constant pool, which keeps a heap
    /// Value alive for as long as the routine can run.
    literal: value_mod.Value,
    /// A collection built from its evaluated items: the internal
    /// `#%list`, `#%concat`, `#%vector`, `#%map` and `#%set` forms
    /// syntax-quote emits, `[...]`, `{...}` and `#{...}` literals,
    /// and quoted compound data. Map items are flat key, value pairs.
    /// Emits one `coll:<op>` over a slot block (VM.md §10): a later
    /// duplicate map key wins, set duplicates collapse, and each
    /// `concat` item must be seqable.
    coll: struct {
        op: vm.CollOp,
        items: []const *const Tiny,
    },
    /// `(try body (catch any binding handler) (finally ...)?)`.
    try_: struct {
        body: *const Tiny,
        binding: []const u8,
        handler: *const Tiny,
        /// Sees the enclosing scope, not the catch binding.
        finally_: ?*const Tiny = null,
        /// Whether a closure in the handler captures `binding`.
        binding_captured: bool = false,
    },
    /// `(throw value)`.
    throw_: *const Tiny,
    /// A call of a core arithmetic or comparison fn that the VM
    /// runs as one `math` or `cmp` instruction (COMPILER.md §4.3
    /// rule 2); `rhs` is null for the unary ops.
    prim: struct {
        op: PrimOp,
        lhs: *const Tiny,
        rhs: ?*const Tiny = null,
    },
    /// `(if test then else?)`; a missing else is nil.
    if_: struct {
        test_: *const Tiny,
        then: *const Tiny,
        else_: ?*const Tiny,
    },
    let_star: Scope,
    /// `(do e...)`: the value of the last, nil when empty.
    do_: []const *const Tiny,
    /// `(fn* name? [params... & rest?] body)`.
    fn_star: struct {
        /// The self-name the body may refer to (COMPILER.md §5.5).
        name: ?[]const u8 = null,
        params: []const []const u8,
        /// Bound at slot `params.len`, to the list of the arguments
        /// past the fixed ones (VM.md §6).
        rest_param: ?[]const u8 = null,
        body: *const Tiny,
        /// Per parameter (the rest parameter last): whether a
        /// closure in the body captures it, so it is boxed on entry.
        captured: []const bool = &.{},
        /// Whether the body refers to `name`, which then needs a
        /// placeholder cell (COMPILER.md §5.5).
        self_referenced: bool = false,
    },
    /// `(callee args...)` through the range-call ABI (VM.md §6).
    call: struct {
        callee: *const Tiny,
        args: []const *const Tiny,
    },
    /// Bound like `let*`; `recur` in the body re-enters it.
    loop_star: Scope,
    /// `(recur args...)`: rebind the nearest `loop*` or `fn*`'s
    /// bindings and jump to its entry; valid only in tail position
    /// (COMPILER.md §5.6).
    recur: struct {
        args: []const *const Tiny,
    },
    /// `(def name value?)`: intern `name` in the current namespace
    /// and, with a value, bind it; either way the result is the Var.
    def: struct {
        name: []const u8,
        value: ?*const Tiny = null,
    },
    /// `(var name)` or `(var ns/name)`: the Var itself, bound or not.
    var_ref: struct {
        ns: ?[]const u8 = null,
        name: []const u8,
    },
    /// `(letfn* [(name [params] body...) ...] body)`: every name is
    /// visible to every function and the body (COMPILER.md §5.6b).
    letfn_star: struct {
        bindings: []const FnBinding,
        body: *const Tiny,
    },
};

/// The operation of a `Tiny.prim`: the VM's `math` and `cmp`
/// variants that run the same numeric-tower helpers as the core
/// fns they stand for (VM.md §10).
pub const PrimOp = enum {
    add,
    sub,
    mul,
    div,
    quot,
    mod,
    neg,
    abs,
    lt,
    lte,
    gt,
    gte,
    num_eq,

    fn inst(op: PrimOp, dst: u12, lhs: Operand, rhs: Operand) Inst {
        const d = Operand.slot(dst);
        return switch (op) {
            .add => Inst.primary(.math, vm.Math.add, d, lhs, rhs),
            .sub => Inst.primary(.math, vm.Math.sub, d, lhs, rhs),
            .mul => Inst.primary(.math, vm.Math.mul, d, lhs, rhs),
            .div => Inst.primary(.math, vm.Math.div, d, lhs, rhs),
            .quot => Inst.primary(.math, vm.Math.idiv, d, lhs, rhs),
            .mod => Inst.primary(.math, vm.Math.mod, d, lhs, rhs),
            .neg => Inst.primary(.math, vm.Math.neg, d, lhs, rhs),
            .abs => Inst.primary(.math, vm.Math.abs, d, lhs, rhs),
            .lt => Inst.primary(.cmp, vm.Cmp.lt, d, lhs, rhs),
            .lte => Inst.primary(.cmp, vm.Cmp.lte, d, lhs, rhs),
            .gt => Inst.primary(.cmp, vm.Cmp.gt, d, lhs, rhs),
            .gte => Inst.primary(.cmp, vm.Cmp.gte, d, lhs, rhs),
            .num_eq => Inst.primary(.cmp, vm.Cmp.eq_num, d, lhs, rhs),
        };
    }
};

/// The core fns inlined as a `Tiny.prim`, at the one arity each
/// inlines at; `inc` and `dec` are `+` and `-` with a constant 1.
/// Every other arity is an ordinary call.
const Inlined = struct { name: []const u8, argc: usize, op: PrimOp, one: bool = false };
const inlined_ops = [_]Inlined{
    .{ .name = "+", .argc = 2, .op = .add },
    .{ .name = "-", .argc = 2, .op = .sub },
    .{ .name = "*", .argc = 2, .op = .mul },
    .{ .name = "/", .argc = 2, .op = .div },
    .{ .name = "quot", .argc = 2, .op = .quot },
    .{ .name = "mod", .argc = 2, .op = .mod },
    .{ .name = "<", .argc = 2, .op = .lt },
    .{ .name = "<=", .argc = 2, .op = .lte },
    .{ .name = ">", .argc = 2, .op = .gt },
    .{ .name = ">=", .argc = 2, .op = .gte },
    .{ .name = "==", .argc = 2, .op = .num_eq },
    .{ .name = "-", .argc = 1, .op = .neg },
    .{ .name = "abs", .argc = 1, .op = .abs },
    .{ .name = "inc", .argc = 1, .op = .add, .one = true },
    .{ .name = "dec", .argc = 1, .op = .sub, .one = true },
};

/// One binding in a `letfn*` form. Each is a function
/// definition (mutually visible across the binding group).
pub const FnBinding = struct {
    name: []const u8,
    params: []const []const u8,
    /// `& rest` binding name, when the fn is variadic.
    rest_param: ?[]const u8 = null,
    body: *const Tiny,
    /// As `Tiny.fn_star.captured`.
    captured: []const bool = &.{},
};

/// The sequential bindings and body of a `let*` or `loop*`.
pub const Scope = struct {
    bindings: []const Binding,
    body: *const Tiny,
};

/// One binding in a `let*` form.
pub const Binding = struct {
    name: []const u8,
    value: *const Tiny,
    /// Whether a closure in the binding's scope captures it
    /// (COMPILER.md §6.1).
    captured: bool = false,
};

/// How a lexical binding is realized in the current routine's
/// frame. A binding lowering marks as captured is boxed where it
/// is bound and is a `.cell_slot`; every other binding is a
/// `.direct_slot`.
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
    /// inside the cell: a closure captures the binding
    /// (COMPILER.md §6.1).
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
    /// Per binding: whether its slot holds a `*UpvalCell`, so
    /// `recur` installs a fresh cell instead of moving a value
    /// (VM.md §11, COMPILER.md §5.6).
    captured_mask: []const bool,
    /// The bindings' names, so `recur` can tell which arguments
    /// read which bindings.
    names: []const []const u8,
};

// =============================================================================
// Errors
// =============================================================================

pub const CompileError = error{
    /// `eval` was given a value that is not a form, such as a list
    /// holding a function (MACROEXPAND.md §1.2); the compiler itself
    /// never raises it.
    UnsupportedForm,

    /// A hand-built `Tiny.int` outside the i48 fixnum range. Form
    /// lowering never produces one: a wider literal lowers to a
    /// bignum `Tiny.literal`.
    IntegerOutOfFixnumRange,

    /// A routine needs more than 4096 constants or capture
    /// descriptors: the 12-bit operands that index them cannot
    /// address more, and there are no extension instructions.
    ConstantPoolOverflow,

    /// A jump targets a pc past 4095, which the 12-bit jump
    /// operand cannot address. Code past pc 4095 that nothing jumps
    /// to runs.
    JumpTargetOutOfRange,

    /// A routine needs more than 4096 slots live at once, upvalues
    /// or Var-table entries: the 12-bit operands that index them
    /// cannot address more.
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
    /// non-`any` catch matcher, quoted symbols /
    /// keywords / strings without an Interner or Heap, and
    /// `reader.Form` datums that only the expander consumes
    /// (syntax-quote, unquote, `#(...)`, `@x`, `^{...}`
    /// metadata) reaching the lowerer. Trapping loudly is better
    /// than emitting subtly-wrong code.
    UnsupportedFeature,

    /// The parser or reader rejected the source string given to
    /// `compileSourceWith`.
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

    /// A `require` in the form ran a file whose form failed at run
    /// time with no handler in force. The failure is a runtime
    /// error, not a compile error: the VM's `traced_error` names
    /// it and `error_trace` locates it (TOOLING.md §1).
    RequiredFileFailed,

    /// A `require` in the form ran a file whose form threw, and a
    /// handler in the running program took the throw: the VM has
    /// already unwound to that handler. Reaches only `eval`, which
    /// returns it as the VM signal of the same name.
    ControlTransferred,

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

    /// A compiler invariant was violated: the compiler reached a
    /// state it believes impossible, such as a closure capturing a
    /// binding lowering did not mark captured. Reported as an
    /// error rather than miscompiled.
    InternalCompilerBug,

    /// The form nests deeper than the native stack's budget allows
    /// lowering or emitting it (`stack.check`, VM.md §13.1).
    StackOverflow,

    OutOfMemory,
};

// =============================================================================
// Output
// =============================================================================

/// The compiler's product. Wrap with `toRoutine(name)` to get a
/// `vm.Routine` ready for `vm.VM.init`. `capture_descs` supports
/// `closure:make` lowering and `fixed_arity` call-site validation.
///
/// **Ownership**: the slices live on the routine allocator
/// (`CompileOptions.routine_allocator`, else the compile allocator)
/// until it is reset or destroyed; there is no `deinit`.
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
    /// PC → source span table (VM.md §5); empty for a hand-built
    /// tree.
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
/// **Slot allocation**: a stack (`slot_top`); `compileExpr` frees
/// what a node allocated once the node is compiled.
///
/// **Constant pool**: one entry per identical Value (COMPILER.md
/// §4.5).
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
    /// Scratch: what compiling needs and nothing after it.
    allocator: std.mem.Allocator,
    /// Where the routines go: their code, pools, span tables, names
    /// and nested routines, which live as long as the caller needs.
    out: std.mem.Allocator,
    code: std.ArrayList(Inst) = .empty,
    consts: std.ArrayList(vm.Const) = .empty,
    /// Where each Value constant sits in `consts`.
    value_consts: std.AutoHashMapUnmanaged([2]u64, u12) = .empty,
    capture_descs: std.ArrayList(vm.CaptureDescriptor) = .empty,
    scope: std.ArrayList(LocalBinding) = .empty,
    /// The next free slot. Slots are a stack: `compileExpr` frees
    /// every slot a node allocated once the node is compiled, so a
    /// slot lives as long as the value in it is needed (bindings to
    /// the end of their scope, temporaries until their consumer is
    /// emitted), and a call block always lies above every live slot
    /// (§4.4's capture-cell rule).
    slot_top: u16 = 0,
    /// The most slots live at once: the routine's frame size.
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
    /// Receives the span of the innermost form being compiled when
    /// an error is raised; nested routines share their parent's.
    diag: ?*LowerDiag = null,

    fn init(allocator: std.mem.Allocator, out: std.mem.Allocator) Emitter {
        return .{ .allocator = allocator, .out = out };
    }

    fn deinit(self: *Emitter) void {
        self.span_table.deinit(self.allocator);
        self.code.deinit(self.allocator);
        self.consts.deinit(self.allocator);
        self.value_consts.deinit(self.allocator);
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

    /// Bring `name`, held in `slot`, into scope. A captured binding
    /// is boxed now, so the slot holds its cell on every path that
    /// reaches a closure over it (COMPILER.md §6.1).
    fn bindLocal(self: *Emitter, name: []const u8, slot: u12, captured: bool) CompileError!void {
        if (captured) try self.emit(vm.asm_.closureBoxLocal(slot));
        try self.scope.append(self.allocator, .{
            .name = name,
            .ref = if (captured) .{ .cell_slot = slot } else .{ .direct_slot = slot },
        });
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
    /// Lowering marked every binding a closure captures, so it is
    /// a `.cell_slot` (or, further out, an `.upvalue`) by the time
    /// a child resolves it here; a `.direct_slot` would be a
    /// compiler bug. Nothing boxes a binding mid-codegen.
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
        // 4. How the parent's frame supplies the cell.
        const source: vm.CaptureSource = switch (parent_ref) {
            .cell_slot => |s| .{ .local_cell_slot = s },
            .upvalue => |u| .{ .inherited_upvalue = u },
            .direct_slot => return CompileError.InternalCompilerBug,
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

    /// Allocate a fresh slot on top of the live ones.
    fn allocSlot(self: *Emitter) CompileError!u12 {
        return self.allocSlotBlock(1);
    }

    /// Allocate a contiguous run of `count` fresh slots, return the
    /// base index. Required by `compileCall` to reserve the call
    /// block BEFORE compiling sub-expressions: per-arg `allocSlot`
    /// interleaved with sub-expression compilation would be
    /// incorrect — sub-expressions allocate their own temps and
    /// the next "arg slot" would not be adjacent to the previous,
    /// breaking the range-call ABI invariant.
    fn allocSlotBlock(self: *Emitter, count: u32) CompileError!u12 {
        const base: u32 = self.slot_top;
        const end: u32 = base + count;
        if (end > 4096) return CompileError.SlotOverflow;
        self.slot_top = @intCast(end);
        self.slot_count = @max(self.slot_count, self.slot_top);
        return @intCast(base);
    }

    /// Add a constant to the pool, return its index. Most callers
    /// want `addValueConst(v)` for an ordinary `Value` or
    /// `addRoutineConst(*const Routine)` for `closure:make` lowering.
    fn addConst(self: *Emitter, c: vm.Const) CompileError!u12 {
        const idx = self.consts.items.len;
        if (idx >= 4096) return CompileError.ConstantPoolOverflow;
        try self.consts.append(self.allocator, c);
        return @intCast(idx);
    }

    /// The pool index of `v`, one entry per identical Value (same
    /// bits: the same immediate, or the same heap object).
    fn addValueConst(self: *Emitter, v: Value) CompileError!u12 {
        const key = [2]u64{ v.tag, v.payload };
        if (self.value_consts.get(key)) |idx| return idx;
        const idx = try self.addConst(.{ .value = v });
        try self.value_consts.put(self.allocator, key, idx);
        return idx;
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

    /// The pc of the next instruction, as a jump operand: jump
    /// targets are 12-bit indexes (VM.md §4), so a target past 4095
    /// is `JumpTargetOutOfRange` at the form that needs the jump.
    fn nextPc(self: *const Emitter) CompileError!u12 {
        const pc = self.code.items.len;
        if (pc > std.math.maxInt(u12)) return CompileError.JumpTargetOutOfRange;
        return @intCast(pc);
    }

    /// Point the jump emitted at `jump_pc` at the next instruction.
    fn patchJumpHere(self: *Emitter, jump_pc: usize) CompileError!void {
        vm.asm_.patchJumpTarget(&self.code.items[jump_pc], try self.nextPc());
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

    /// The routine's code, pools and span table, copied onto `out`.
    ///
    /// Ownership transfer is errdefer-safe: if
    /// any `toOwnedSlice` fails after a previous one succeeded,
    /// the earlier slice would leak under a non-arena allocator.
    /// The chained errdefers guard against that.
    fn finish(self: *Emitter) CompileError!Compiled {
        const code = try self.out.dupe(Inst, self.code.items);
        errdefer self.out.free(code);
        const consts = try self.out.dupe(vm.Const, self.consts.items);
        errdefer self.out.free(consts);
        const caps = try self.out.dupe(vm.CaptureDescriptor, self.capture_descs.items);
        errdefer self.out.free(caps);
        const vt = try self.out.dupe(*vm.Var, self.var_table.items);
        errdefer self.out.free(vt);
        const spans = try self.out.dupe(vm.SpanEntry, self.span_table.items);
        errdefer self.out.free(spans);
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

/// Compile a `Tiny` tree built by hand: no namespace (every symbol
/// must be lexical) and no span table. Source and Form callers use
/// `compileSourceWith` / `compileFormWith`.
pub fn compileTiny(allocator: std.mem.Allocator, form: *const Tiny) CompileError!Compiled {
    return emitRoutine(allocator, form, .{});
}

/// What `emitRoutine` compiles a top-level `Tiny` tree with.
const EmitOptions = struct {
    /// Where the routines go; the scratch allocator when null.
    out: ?std.mem.Allocator = null,
    namespace: ?*vm.Namespace = null,
    /// Whether every node is a `TinyNode` (a tree `lowerForm`
    /// built), so the routines carry span tables.
    spanned: bool = false,
    /// The span of the form the tree was lowered from.
    origin: ?reader_mod.SrcSpan = null,
    source: ?*const vm.SourceInfo = null,
    diag: ?*LowerDiag = null,
};

/// The top-level routine for `form`: its value in slot 0, returned.
/// There is no enclosing `recur` target, so a top-level `(recur)`
/// is `RecurOutsideTail`.
fn emitRoutine(allocator: std.mem.Allocator, form: *const Tiny, opts: EmitOptions) CompileError!Compiled {
    var emitter = Emitter.init(allocator, opts.out orelse allocator);
    defer emitter.deinit();
    emitter.namespace = opts.namespace;
    emitter.spanned = opts.spanned;
    emitter.current_span = opts.origin;
    emitter.source = opts.source;
    emitter.diag = opts.diag;
    const dst = try emitter.allocSlot();
    try compileExpr(&emitter, form, dst, null);
    try emitter.emit(vm.asm_.returnSlot(dst));
    var compiled = try emitter.finish();
    compiled.origin = if (opts.origin) |o| toSourceSpan(o) else null;
    return compiled;
}

// =============================================================================
// Form → Tiny lowering
// =============================================================================
//
// `lowerForm` converts a `reader.Form` tree into a `Tiny` IR tree on the
// passed allocator. The Tiny tree is then compiled via the backend
// (`emitRoutine`), so the entire codegen pipeline
// (RecurTarget threading, variadic rest, Var fall-through, etc.) runs
// on the one Tiny path. Lowering also marks every binding a closure
// captures (`LowerEnv`).
//
// Lowering covers literals, symbols, list dispatch (ordinary calls,
// special forms, the inlined core fns when not shadowed),
// binding/fn forms (let*, fn*, letfn*, loop*, recur), var forms
// (def, var), try/throw, quote, and collection literals. The
// lowering env (`LowerEnv`) tracks lexical-name shadowing for
// intrinsic dispatch.

/// Allocate and initialize a Tiny node on the given allocator.
/// Used by `lowerForm` to build the IR tree. The arena passed to
/// `compileFormWith` / `compileSourceWith` owns these allocations. Every node
/// is a `TinyNode` so `lowerForm` can attach the Form's span.
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
/// Why a bundle: every helper that recurses into `lowerForm`
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
    /// How many `fn*` bodies enclose the form being lowered.
    fn_depth: u32 = 0,

    /// Create a child context with a new env; everything else
    /// carries over.
    pub fn withEnv(self: LowerCtx, env: ?*const LowerEnv) LowerCtx {
        var copy = self;
        copy.env = env;
        return copy;
    }

    /// The context of a `fn*` body whose parameters `env` binds.
    fn inFnBody(self: LowerCtx, env: *const LowerEnv) LowerCtx {
        var copy = self;
        copy.env = env;
        copy.fn_depth += 1;
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
    /// `defn`, `defonce`, `defmacro`, `defrecord` (the type id, `->T`,
    /// `map->T`, `T?`) and `defprotocol` (the protocol and each
    /// method). A definition inside a `let`, a `when` or a call
    /// interns its Var when it runs, exactly like one at top level,
    /// so it is declared wherever it appears; quoted data is not
    /// walked. A form nested past the stack budget is walked as deep
    /// as the budget allows: compiling it fails with StackOverflow
    /// anyway.
    pub fn declareForm(self: *DeclaredNames, form: *const reader_mod.Form) error{OutOfMemory}!void {
        stack.check() catch return;
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
        const plain = [_][]const u8{ "def", "defn", "defonce", "defmacro" };
        if (for (plain) |h| {
            if (std.mem.eql(u8, head, h)) break true;
        } else false) {
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

/// The lexical scopes lowering is inside, innermost first: every
/// binding a `let*`, `loop*`, `fn*` (parameters and self-name),
/// `letfn*` or `catch` makes, mirroring the Emitter's scope exactly.
/// Lowering resolves each symbol against it for two reasons: a
/// lexical name is not a Var, so it shadows an inlined core fn and
/// the declared-name check (special forms stay reserved:
/// `(let* [if 1] (if true 2 3))` is still `if`); and a reference
/// from inside a `fn*` to a binding made outside it is a capture,
/// which sets the binding's `captured` flag in its Tiny node, so the
/// Emitter boxes it when it is bound (COMPILER.md §6.1).
pub const LowerEnv = struct {
    parent: ?*const LowerEnv = null,
    /// The `fn*` nesting depth these bindings are made at.
    fn_depth: u32 = 0,
    /// Bindings made at this level, in order; later ones shadow.
    locals: std.ArrayList(Local) = .empty,

    const Local = struct {
        name: []const u8,
        /// Where the binding's Tiny node records a capture.
        captured: *bool,
    };

    fn bind(self: *LowerEnv, allocator: std.mem.Allocator, name: []const u8, captured: *bool) CompileError!void {
        try self.locals.append(allocator, .{ .name = name, .captured = captured });
    }

    /// The innermost binding of `name` and the depth it was made at.
    fn lookup(self: *const LowerEnv, name: []const u8) ?struct { local: Local, fn_depth: u32 } {
        var env: ?*const LowerEnv = self;
        while (env) |e| : (env = e.parent) {
            var i = e.locals.items.len;
            while (i > 0) {
                i -= 1;
                if (std.mem.eql(u8, e.locals.items[i].name, name)) return .{ .local = e.locals.items[i], .fn_depth = e.fn_depth };
            }
        }
        return null;
    }

    fn deinit(self: *LowerEnv, allocator: std.mem.Allocator) void {
        self.locals.deinit(allocator);
    }
};

/// Whether `name` is lexically bound here; a binding made outside
/// the innermost `fn*` is marked captured.
fn resolveLexical(ctx: LowerCtx, name: []const u8) bool {
    const env = ctx.env orelse return false;
    const hit = env.lookup(name) orelse return false;
    if (hit.fn_depth < ctx.fn_depth) hit.local.captured.* = true;
    return true;
}

/// Whether an unqualified symbol that is not lexically bound names
/// something: a Var visible from the namespace (its own or a
/// referred one), or a name the enclosing file declares.
fn symbolResolves(ctx: LowerCtx, declared: *const DeclaredNames, name: []const u8) bool {
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

/// Whether a bare operator `name` means `nexis.core`'s Var of that
/// name, so its call may be inlined (COMPILER.md §4.3 rule 2): not a
/// lexical binding, not a Var the namespace defines or refers to
/// instead, and not a name this file or line defines outside
/// `nexis.core` (a definition earlier in the same form interns its
/// Var only when the form is emitted). Without a namespace registry
/// there is nothing to shadow it.
fn namesCore(ctx: LowerCtx, name: []const u8) bool {
    if (ctx.env) |env| {
        if (env.lookup(name) != null) return false;
    }
    const ns = ctx.namespace orelse return true;
    const registry = ns.registry orelse return true;
    const core_var = registry.core.lookupLocal(name) orelse return false;
    if (ns.lookup(name) != core_var) return false;
    if (ns == registry.core) return true;
    const declared = ctx.declared orelse return true;
    return !declared.contains(name);
}

/// Translate a `reader.Form` into a `Tiny` node on `allocator`,
/// with the lexical environment threaded through `ctx`; binding
/// forms extend it for their bodies. Symbol names are borrowed from
/// the reader's source, which must outlive the compiled routine.
fn lowerForm(
    allocator: std.mem.Allocator,
    form: *const reader_mod.Form,
    ctx: LowerCtx,
) CompileError!*Tiny {
    // The innermost form reports the error, unless a symbol
    // already located it more precisely.
    errdefer if (ctx.diag) |d| {
        if (d.span == null) d.span = form.origin;
    };
    try stack.check();
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
            if (!resolveLexical(ctx, name.name)) {
                if (ctx.declared) |declared| {
                    if (!symbolResolves(ctx, declared, name.name)) {
                        if (ctx.diag) |d| d.span = form.origin;
                        return CompileError.UnresolvedSymbol;
                    }
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
        // `{k1 v1 ...}`, `#{a b}` and `[a b]` as expressions: each
        // item is an expression, evaluated left to right.
        .map => |items| try lowerColl(allocator, .map, items, ctx, false),
        .set => |items| try lowerColl(allocator, .set, items, ctx, false),
        .vector => |items| try lowerColl(allocator, .vector, items, ctx, false),
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
    if (items.len == 0) return try lowerColl(allocator, .list, &.{}, ctx, false);
    // Head-symbol dispatch only fires when head is an unqualified
    // symbol. Qualified symbols (`foo/x`) and non-symbol heads
    // (calls of computed values) fall through to ordinary call.
    if (items[0].datum == .symbol and items[0].datum.symbol.ns == null) {
        const name = items[0].datum.symbol.name;
        // Special forms are reserved: no binding shadows them.
        if (lowerings.get(name)) |lower| return lower(allocator, items[1..], ctx);
        // -- Inlineable core fns (shadowable) --
        if (inlinedOp(name, items.len - 1)) |in| {
            if (namesCore(ctx, name)) return try lowerPrim(allocator, in, items[1..], ctx);
        }
    } else if (items[0].datum == .symbol and std.mem.eql(u8, items[0].datum.symbol.ns.?, "nexis.core")) {
        // A qualified head is never a lexical local, so `nexis.core/+`
        // inlines unconditionally. Host macros emit these
        // (MACROEXPAND.md §5).
        if (inlinedOp(items[0].datum.symbol.name, items.len - 1)) |in| return try lowerPrim(allocator, in, items[1..], ctx);
    }
    // Ordinary call: lower head as callee, rest as args.
    return try lowerCall(allocator, items, ctx);
}

/// How each special form lowers: the expander's `special_forms`
/// (MACROEXPAND.md §5), less the four it rewrites away (`ns`,
/// `require`, `defmacro`, `set!`), and the `#%` collection
/// constructors syntax-quote emits.
const lowerings = std.StaticStringMap(*const fn (std.mem.Allocator, []const *reader_mod.Form, LowerCtx) CompileError!*Tiny).initComptime(.{
    .{ "do", &lowerDo },
    .{ "if", &lowerIf },
    .{ "quote", &lowerQuote },
    .{ "let*", &lowerLetStar },
    .{ "loop*", &lowerLoopStar },
    .{ "recur", &lowerRecur },
    .{ "fn*", &lowerFnStar },
    .{ "letfn*", &lowerLetFnStar },
    .{ "def", &lowerDef },
    .{ "var", &lowerVarRef },
    .{ "try", &lowerTry },
    .{ "throw", &lowerThrow },
    .{ "#%list", &lowerCollForm(.list) },
    .{ "#%concat", &lowerCollForm(.concat) },
    .{ "#%vector", &lowerCollForm(.vector) },
    .{ "#%map", &lowerCollForm(.map) },
    .{ "#%set", &lowerCollForm(.set) },
});

/// The special forms the expander rewrites before lowering.
const expanded_away = [_][]const u8{ "ns", "require", "defmacro", "set!" };

fn lowerLetStar(allocator: std.mem.Allocator, args: []const *reader_mod.Form, ctx: LowerCtx) CompileError!*Tiny {
    return allocTiny(allocator, .{ .let_star = try lowerScope(allocator, args, ctx) });
}

fn lowerLoopStar(allocator: std.mem.Allocator, args: []const *reader_mod.Form, ctx: LowerCtx) CompileError!*Tiny {
    return allocTiny(allocator, .{ .loop_star = try lowerScope(allocator, args, ctx) });
}

fn lowerCollForm(comptime op: vm.CollOp) fn (std.mem.Allocator, []const *reader_mod.Form, LowerCtx) CompileError!*Tiny {
    return struct {
        fn lower(allocator: std.mem.Allocator, args: []const *reader_mod.Form, ctx: LowerCtx) CompileError!*Tiny {
            return lowerColl(allocator, op, args, ctx, false);
        }
    }.lower;
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
        exprs[i] = try lowerForm(allocator, item, ctx);
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
    const test_ = try lowerForm(allocator, args[0], ctx);
    const then = try lowerForm(allocator, args[1], ctx);
    const else_: ?*const Tiny = if (args.len == 3)
        try lowerForm(allocator, args[2], ctx)
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

/// A `Tiny.coll` of `op` over `forms`: each lowered as an
/// expression, or as quoted data when `quoted`.
fn lowerColl(
    allocator: std.mem.Allocator,
    op: vm.CollOp,
    forms: []const *reader_mod.Form,
    ctx: LowerCtx,
    quoted: bool,
) CompileError!*Tiny {
    if (op == .map and forms.len % 2 != 0) return CompileError.MalformedForm;
    const items = try allocator.alloc(*const Tiny, forms.len);
    for (forms, items) |form, *item| {
        item.* = if (quoted) try lowerQuotePayload(allocator, form, ctx) else try lowerForm(allocator, form, ctx);
    }
    if (try constantColl(allocator, op, items, ctx)) |v| return try allocTiny(allocator, .{ .literal = v });
    return try allocTiny(allocator, .{ .coll = .{ .op = op, .items = items } });
}

/// The collection `items` build, made now when every item is a
/// constant (PLAN §11.4): the literal is then one constant, however
/// large, instead of a slot and an instruction per item. It is built
/// on the lowering heap, as the VM builds it at run time, and lives
/// as long as a routine holding it can run, which marks it
/// (`markRoutineConsts`). Null without a heap, for `concat`, or when
/// an item is computed.
fn constantColl(allocator: std.mem.Allocator, op: vm.CollOp, items: []const *const Tiny, ctx: LowerCtx) CompileError!?Value {
    const heap = ctx.heap orelse return null;
    if (op == .concat) return null;
    const values = try allocator.alloc(Value, items.len);
    defer allocator.free(values);
    for (items, values) |item, *v| {
        v.* = switch (item.*) {
            .nil => value_mod.nilValue(),
            .bool => |b| value_mod.fromBool(b),
            .int => |n| value_mod.fromFixnum(n) orelse return null,
            .literal => |l| l,
            else => return null,
        };
    }
    return buildColl(heap, op, values) catch CompileError.OutOfMemory;
}

fn buildColl(heap: *heap_mod.Heap, op: vm.CollOp, values: []const Value) !Value {
    switch (op) {
        .list => return list_mod.fromSlice(heap, values),
        .vector => return if (values.len == 0) vector_mod.empty(heap) else vector_mod.fromSlice(heap, values),
        .map => {
            var m = try champ_mod.mapEmpty(heap);
            var i: usize = 0;
            while (i < values.len) : (i += 2) {
                m = try champ_mod.mapAssoc(heap, m, values[i], values[i + 1], &dispatch_mod.hashValue, &dispatch_mod.equal);
            }
            return m;
        },
        .set => {
            var set = try champ_mod.setEmpty(heap);
            for (values) |v| set = try champ_mod.setConj(heap, set, v, &dispatch_mod.hashValue, &dispatch_mod.equal);
            return set;
        },
        else => unreachable,
    }
}

/// `(quote x)` and `'x`: `x` as data. Symbols and keywords are
/// interned (`UnsupportedFeature` without an interner), strings and
/// bignums built on the heap; a compound collection quotes each
/// element and so becomes one constant (`lowerColl`). A quote inside
/// the payload is the 2-list `(quote x)`, as `formToValue` renders
/// it. Quoted reader macros (`'@x`, `'#(...)`, `'^{...}`,
/// syntax-quote) are `UnsupportedFeature`.
fn lowerQuotePayload(
    allocator: std.mem.Allocator,
    payload: *const reader_mod.Form,
    ctx: LowerCtx,
) CompileError!*Tiny {
    try stack.check();
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
        // Quoted compound data: each element is quoted data too.
        .list => |items| try lowerColl(allocator, .list, items, ctx, true),
        .vector => |items| try lowerColl(allocator, .vector, items, ctx, true),
        .map => |items| try lowerColl(allocator, .map, items, ctx, true),
        .set => |items| try lowerColl(allocator, .set, items, ctx, true),
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
            break :blk try allocTiny(allocator, .{ .coll = .{ .op = .list, .items = tiny_items } });
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

/// The inlined core fn `name` is at `argc` arguments, if any.
fn inlinedOp(name: []const u8, argc: usize) ?Inlined {
    for (inlined_ops) |in| {
        if (in.argc == argc and std.mem.eql(u8, in.name, name)) return in;
    }
    return null;
}

/// A call of the inlined core fn `in` as a `Tiny.prim`.
fn lowerPrim(
    allocator: std.mem.Allocator,
    in: Inlined,
    args: []const *reader_mod.Form,
    ctx: LowerCtx,
) CompileError!*Tiny {
    const lhs = try lowerForm(allocator, args[0], ctx);
    const rhs: ?*const Tiny = if (in.one)
        try allocTiny(allocator, .{ .int = 1 })
    else if (args.len == 2)
        try lowerForm(allocator, args[1], ctx)
    else
        null;
    return try allocTiny(allocator, .{ .prim = .{ .op = in.op, .lhs = lhs, .rhs = rhs } });
}

/// Ordinary function call `(callee args...)`. Lowers head as
/// callee (any expression), rest as args.
fn lowerCall(
    allocator: std.mem.Allocator,
    items: []const *reader_mod.Form,
    ctx: LowerCtx,
) CompileError!*Tiny {
    std.debug.assert(items.len >= 1);
    const callee = try lowerForm(allocator, items[0], ctx);
    const args = try allocator.alloc(*const Tiny, items.len - 1);
    for (items[1..], 0..) |item, i| {
        args[i] = try lowerForm(allocator, item, ctx);
    }
    return try allocTiny(allocator, .{ .call = .{ .callee = callee, .args = args } });
}

// =============================================================================
// Form binding-form lowering
// =============================================================================
//
// `let*`, `fn*`, `letfn*`, `loop*`, `recur`. Each binding form
// lowers its body in a child `LowerEnv` holding its names, which
// mirrors the Emitter's scope (see `LowerEnv`).

/// Lower a sequence of body forms into a single Tiny expression.
/// Multi-form bodies wrap in `Tiny.do_`; single-form bodies pass
/// through; an empty body is nil, as `(do)` is.
fn lowerBody(
    allocator: std.mem.Allocator,
    body_items: []const *reader_mod.Form,
    ctx: LowerCtx,
) CompileError!*Tiny {
    if (body_items.len == 0) return try allocTiny(allocator, .nil);
    if (body_items.len == 1) return try lowerForm(allocator, body_items[0], ctx);
    const exprs = try allocator.alloc(*const Tiny, body_items.len);
    for (body_items, 0..) |item, i| {
        exprs[i] = try lowerForm(allocator, item, ctx);
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

/// Parsed param vector for `fn*`: split fixed params from
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

/// `(let* [name1 expr1 ...] body...)` and `(loop* ...)`: each RHS
/// sees the bindings before it, the body sees them all.
fn lowerScope(
    allocator: std.mem.Allocator,
    args: []const *reader_mod.Form,
    ctx: LowerCtx,
) CompileError!Scope {
    if (args.len < 1) return CompileError.MalformedForm;
    const binding_vec = try expectVector(args[0]);
    if (binding_vec.len % 2 != 0) return CompileError.MalformedForm;
    const bindings = try allocator.alloc(Binding, binding_vec.len / 2);
    var local = LowerEnv{ .parent = ctx.env, .fn_depth = ctx.fn_depth };
    defer local.deinit(allocator);
    for (bindings, 0..) |*b, i| {
        b.* = .{
            .name = try expectUnqualifiedSymbol(binding_vec[i * 2]),
            .value = try lowerForm(allocator, binding_vec[i * 2 + 1], ctx.withEnv(&local)),
        };
        try local.bind(allocator, b.name, &b.captured);
    }
    return .{ .bindings = bindings, .body = try lowerBody(allocator, args[1..], ctx.withEnv(&local)) };
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
        recur_args[i] = try lowerForm(allocator, item, ctx);
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

    // The self-name belongs to the enclosing scope, so the body's
    // references to it are captures of a placeholder cell.
    var self_referenced = false;
    var self_env = LowerEnv{ .parent = ctx.env, .fn_depth = ctx.fn_depth };
    defer self_env.deinit(allocator);
    if (self_name) |n| try self_env.bind(allocator, n, &self_referenced);
    const fn_body = try lowerFnBody(allocator, parsed, args[pos + 1 ..], ctx.withEnv(&self_env));
    return try allocTiny(allocator, .{ .fn_star = .{
        .name = self_name,
        .params = parsed.params,
        .rest_param = parsed.rest_param,
        .body = fn_body.body,
        .captured = fn_body.captured,
        .self_referenced = self_referenced,
    } });
}

/// A `fn*` body over `params`, and which parameters closures in it
/// capture (the rest parameter last).
fn lowerFnBody(
    allocator: std.mem.Allocator,
    params: ParsedParams,
    body: []const *reader_mod.Form,
    ctx: LowerCtx,
) CompileError!struct { body: *const Tiny, captured: []const bool } {
    const count = params.params.len + @intFromBool(params.rest_param != null);
    const captured = try allocator.alloc(bool, count);
    @memset(captured, false);
    var env = LowerEnv{ .parent = ctx.env, .fn_depth = ctx.fn_depth + 1 };
    defer env.deinit(allocator);
    for (params.params, 0..) |p, i| try env.bind(allocator, p, &captured[i]);
    if (params.rest_param) |rp| try env.bind(allocator, rp, &captured[count - 1]);
    return .{ .body = try lowerBody(allocator, body, ctx.inFnBody(&env)), .captured = captured };
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

    // Every name is in scope for every fn body and the body. Their
    // cells always exist (COMPILER.md §5.6b), so no flag is needed.
    var names_captured = false;
    var local = LowerEnv{ .parent = ctx.env, .fn_depth = ctx.fn_depth };
    defer local.deinit(allocator);
    const parsed = try allocator.alloc(ParsedParams, binding_vec.len);
    for (binding_vec, 0..) |entry, i| {
        const entry_items = switch (entry.datum) {
            .list => |items| items,
            else => return CompileError.MalformedForm,
        };
        if (entry_items.len < 2) return CompileError.MalformedForm;
        const name = try expectUnqualifiedSymbol(entry_items[0]);
        parsed[i] = try parseParams(allocator, try expectVector(entry_items[1]));
        try local.bind(allocator, name, &names_captured);
        bindings[i] = .{ .name = name, .params = parsed[i].params, .rest_param = parsed[i].rest_param, .body = undefined };
    }
    for (binding_vec, bindings, parsed) |entry, *b, params| {
        const fn_body = try lowerFnBody(allocator, params, entry.datum.list[2..], ctx.withEnv(&local));
        b.body = fn_body.body;
        b.captured = fn_body.captured;
    }
    const body = try lowerBody(allocator, args[1..], ctx.withEnv(&local));
    return try allocTiny(allocator, .{ .letfn_star = .{ .bindings = bindings, .body = body } });
}

// =============================================================================
// Form var-form lowering
// =============================================================================
//
// `def`, `(var x)`. The backend (Tiny.def,
// Tiny.var_ref) handles forward references, identity-stable
// rebind, and the named-fn placeholder pattern. This layer is
// purely Form-side dispatch + structural validation.
//
// LowerEnv does NOT add def names: a Var is not lexical.
// `namesCore` consults the namespace and the declared names instead.

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
        try lowerForm(allocator, args[1], ctx)
    else
        null;
    return try allocTiny(allocator, .{ .def = .{ .name = name, .value = value } });
}

/// `(var name)` → returns the Var object (NOT its value). Does
/// not trap on unbound. Maps to Tiny.var_ref.
fn lowerVarRef(
    allocator: std.mem.Allocator,
    args: []const *reader_mod.Form,
    _: LowerCtx,
) CompileError!*Tiny {
    if (args.len != 1) return CompileError.MalformedForm;
    if (args[0].datum != .symbol) return CompileError.ExpectedSymbol;
    const sym = args[0].datum.symbol;
    return try allocTiny(allocator, .{ .var_ref = .{ .ns = sym.ns, .name = sym.name } });
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
    var binding_captured = false;
    var handler_env: LowerEnv = .{ .parent = ctx.env, .fn_depth = ctx.fn_depth };
    defer handler_env.deinit(allocator);
    try handler_env.bind(allocator, binding, &binding_captured);
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
            .binding_captured = binding_captured,
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
    const value = try lowerForm(allocator, args[0], ctx);
    return try allocTiny(allocator, .{ .throw_ = value });
}

/// What `compileEvalCallback` compiles a `defmacro`'s function with.
const CompileEvalData = struct {
    /// Where the macro's routines go: they must outlive every later
    /// form that expands the macro (typically the VM's runtime
    /// arena).
    persistent_allocator: std.mem.Allocator,
    namespace: ?*vm.Namespace,
    interner: *intern_mod.Interner,
    /// The user VM's heap through its namespace registry; the
    /// sub-VM allocates on it.
    registry_heap: ?*heap_mod.Heap,
};

/// The expander's compile-eval callback (`defmacro`): compile `form`,
/// the already-expanded `(def name (fn* ...))`, with no macro table,
/// and run it on a fresh sub-VM written through `out_vm`. It compiles
/// on the persistent allocator, so the macro's closure outlives the
/// per-form compile arena. The result may reference
/// `out_vm.runtime_arena`: the caller takes what it needs and deinits
/// `out_vm` (`expand.CompileEvalContext`).
fn compileEvalCallback(
    user_data: *anyopaque,
    form: *const reader_mod.Form,
    out_vm: *vm.VM,
) anyerror!value_mod.Value {
    const data: *CompileEvalData = @ptrCast(@alignCast(user_data));
    const compiled = try compileFormWith(data.persistent_allocator, form, .{
        .namespace = data.namespace,
        .interner = data.interner,
    });
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
            .io = v.io,
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

    /// The first form of `source`; whatever follows it is ignored,
    /// as in Clojure, even text that does not read. Syntax-quote,
    /// unquote and `^meta` do not read as data and are reader
    /// errors here.
    fn readStringHook(user_data: *anyopaque, v: *vm.VM, source: []const u8) vm.VmError!value_mod.Value {
        const self: *RuntimeHooks = @ptrCast(@alignCast(user_data));
        var arena = std.heap.ArenaAllocator.init(v.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const form = readFirstForm(a, source) catch |err|
            return failure(v, err, "reader-error");
        var ctx = self.context(a, v);
        return expand_mod.formToValue(&ctx, form) catch |err|
            return failure(v, err, "reader-error");
    }

    /// The first form of `source`. When the whole text does not read
    /// as a program, the prefixes that could end one form (at depth
    /// 0, before a delimiter) are tried in order, the reader deciding.
    fn readFirstForm(a: std.mem.Allocator, source: []const u8) !*reader_mod.Form {
        if (readForms(a, source)) |forms| {
            if (forms.len == 0) return error.ReaderFailure;
            return forms[0];
        } else |err| if (err == error.OutOfMemory) return err;
        var cuts = FormEnds{ .text = source };
        while (cuts.next()) |end| {
            const forms = readForms(a, source[0..end]) catch |err| {
                if (err == error.OutOfMemory) return err;
                continue;
            };
            if (forms.len == 1) return forms[0];
        }
        return error.ReaderFailure;
    }

    /// The forms `text` reads as. The reader's arena, which holds
    /// them, and the parser's live on `a` and go when `a` does.
    fn readForms(a: std.mem.Allocator, text: []const u8) ![]const *reader_mod.Form {
        var p = try reader_mod.parser.parseProgram(a, text);
        var reader = reader_mod.Reader.init(a, text);
        const forms = reader.readProgram(p.sexp) catch |err| {
            reader.deinit();
            p.parser.deinit();
            return err;
        };
        return forms;
    }

    /// Where a top-level form could end in `text`: after an atom or
    /// a closing bracket that brings the nesting back to 0, skipping
    /// strings, comments and character literals. Only candidates;
    /// the reader decides.
    const FormEnds = struct {
        text: []const u8,
        pos: usize = 0,
        depth: usize = 0,

        fn next(self: *FormEnds) ?usize {
            const t = self.text;
            while (self.pos < t.len) {
                const c = t[self.pos];
                self.pos += 1;
                switch (c) {
                    ';' => while (self.pos < t.len and t[self.pos] != '\n') : (self.pos += 1) {},
                    '"' => {
                        while (self.pos < t.len and t[self.pos] != '"') : (self.pos += 1) {
                            if (t[self.pos] == '\\') self.pos += 1;
                        }
                        self.pos = @min(self.pos + 1, t.len);
                        if (self.depth == 0) return self.pos;
                    },
                    '(', '[', '{' => self.depth += 1,
                    ')', ']', '}' => {
                        if (self.depth == 0) return null;
                        self.depth -= 1;
                        if (self.depth == 0) return self.pos;
                    },
                    ' ', '\t', '\n', '\r', ',' => {},
                    else => {
                        if (c == '\\' and self.pos < t.len) self.pos += 1;
                        while (self.pos < t.len and !isDelimiter(t[self.pos])) : (self.pos += 1) {}
                        if (self.depth == 0) return self.pos;
                    },
                }
            }
            return null;
        }

        fn isDelimiter(c: u8) bool {
            return switch (c) {
                ' ', '\t', '\n', '\r', ',', '(', ')', '[', ']', '{', '}', '"', ';' => true,
                else => false,
            };
        }
    };

    /// `(eval form)`: `form_value` as a Form, compiled the way the
    /// REPL compiles a line (the current namespace, this registry,
    /// interner, host macro table and loader, a fresh set of
    /// declared names) and run on `v` as a nested call. The Form
    /// and Tiny trees live in a scratch arena freed on return; the
    /// routine, its constants and every closure prototype live in
    /// the VM's runtime arena, because a closure the form returns, a
    /// Var it defines and the frame an escaping throw leaves in
    /// place all outlive the call. During the run the routine is a
    /// frame, so its constants are roots. A value that is not a
    /// form and a form that does not compile both throw the map
    /// `compileFailure` builds.
    fn evalHook(user_data: *anyopaque, v: *vm.VM, form_value: value_mod.Value) vm.VmError!value_mod.Value {
        const self: *RuntimeHooks = @ptrCast(@alignCast(user_data));
        const persistent = v.runtime_arena.allocator();
        // The Form and Tiny trees are garbage once the routine is
        // compiled; only the routine outlives the call.
        var scratch = std.heap.ArenaAllocator.init(v.allocator);
        defer scratch.deinit();
        var ctx = self.context(scratch.allocator(), v);
        const origin = reader_mod.SrcSpan{ .pos = 0, .len = 0 };
        const form = expand_mod.valueToForm(&ctx, form_value, origin) catch |err|
            return compileFailure(v, err, "UnsupportedForm", form_value, null);
        var declared = DeclaredNames.init(v.allocator);
        defer declared.deinit();
        var detail: ?[]const u8 = null;
        const compiled = compileFormWith(scratch.allocator(), form, .{
            .out_detail = &detail,
            .io = v.io,
            .namespace = self.registry.current,
            .interner = self.interner,
            .host_macros = self.host_macros,
            .persistent_allocator = persistent,
            .routine_allocator = persistent,
            .registry = self.registry,
            .load_callback = self.load_callback,
            .declared = &declared,
        }) catch |err| switch (err) {
            // A required file's throw that the caller's handler took:
            // the VM is already at the handler.
            error.ControlTransferred => return vm.VmError.ControlTransferred,
            // A required file's form failed with no handler anywhere;
            // its frames are still in place above this call, so the
            // error leaves through the run loop with the full chain.
            error.RequiredFileFailed => return v.traced_error orelse vm.VmError.UncaughtThrow,
            else => return compileFailure(v, err, @errorName(err), form_value, detail),
        };
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
    /// form}`, where `name` is the `CompileError` variant, with
    /// `:detail` the expander's reason when it gave one.
    fn compileFailure(v: *vm.VM, err: anyerror, name: []const u8, form: value_mod.Value, detail: ?[]const u8) vm.VmError {
        if (err == error.OutOfMemory) return vm.VmError.OutOfMemory;
        return v.throwValue(failureMap(v, name, form, detail) catch return vm.VmError.OutOfMemory);
    }

    fn failureMap(v: *vm.VM, name: []const u8, form: value_mod.Value, detail: ?[]const u8) !value_mod.Value {
        const heap = v.ensureHeap();
        const interner = v.ensureInterner();
        var m = try champ_mod.mapEmpty(heap);
        const entries = [_]struct { key: []const u8, value: ?value_mod.Value }{
            .{ .key = "error", .value = try interner.internKeywordValue("compile-error") },
            .{ .key = "message", .value = try string_mod.fromBytes(heap, name) },
            .{ .key = "form", .value = form },
            .{ .key = "detail", .value = if (detail) |d| try string_mod.fromBytes(heap, d) else null },
        };
        for (entries) |e| {
            const value = e.value orelse continue;
            m = try champ_mod.mapAssoc(heap, m, try interner.internKeywordValue(e.key), value, &dispatch_mod.hashValue, &dispatch_mod.equal);
        }
        return m;
    }
};

/// Everything a full compile may be given beyond the form and its
/// allocator. Every field is optional.
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
    /// Receives the source span of an error: the innermost form it
    /// was raised at, or the symbol's own span.
    out_span: ?*?reader_mod.SrcSpan = null,
    /// Receives why macro expansion failed, when the expander said
    /// (`ExpandContext.failure`); the text lives on `allocator`.
    out_detail: ?*?[]const u8 = null,
    /// The `std.Io` a user macro's sub-VM prints through.
    io: ?std.Io = null,
    /// Where `defmacro` closures are stored, so they outlive a
    /// per-form compile arena. The REPL and file runner pass
    /// `vm.runtime_arena.allocator()`; null uses `allocator`.
    persistent_allocator: ?std.mem.Allocator = null,
    /// Where the compiled routines go (their code, constant pools,
    /// span tables and nested routines); null uses `allocator`.
    /// With it, `allocator` is scratch the caller may free as soon
    /// as the call returns: the Form and Tiny trees and the
    /// Emitter's working storage.
    routine_allocator: ?std.mem.Allocator = null,
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
            .io = opts.io,
        };
        working_form = expand_mod.expandForm(&mctx, null, form) catch |err| {
            // The expander records the innermost form it failed at
            // and why (MACROEXPAND.md §6).
            if (out_span) |s| s.* = if (mctx.failure) |f| f.span else form.origin;
            if (opts.out_detail) |d| d.* = if (mctx.failure) |f| f.message else null;
            return switch (err) {
                error.ExpansionDepthExceeded => CompileError.MacroDepthExceeded,
                error.RequiredFileFailed => CompileError.RequiredFileFailed,
                error.ControlTransferred => CompileError.ControlTransferred,
                error.OutOfMemory => CompileError.OutOfMemory,
                else => CompileError.MacroExpansionFailure,
            };
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
    if (declared) |d| try d.declareForm(working_form);
    var diag = LowerDiag{};
    const ctx = LowerCtx{
        .env = null,
        .interner = interner,
        .heap = lower_heap,
        .namespace = namespace,
        .declared = declared,
        .diag = &diag,
    };
    const tiny = lowerForm(allocator, working_form, ctx) catch |err| {
        // An error that located itself reports that span; the
        // rest carry the macroexpanded form's span.
        if (out_span) |s| s.* = diag.span orelse working_form.origin;
        return err;
    };
    diag.span = null;
    return emitRoutine(allocator, tiny, .{
        .out = opts.routine_allocator,
        .namespace = namespace,
        .spanned = true,
        .origin = working_form.origin,
        .source = opts.source,
        .diag = &diag,
    }) catch |err| {
        if (out_span) |s| s.* = diag.span orelse working_form.origin;
        return err;
    };
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

// =============================================================================
// Internal lowering — destination-driven
// =============================================================================

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
    // The innermost form reports the error.
    errdefer if (e.diag) |d| {
        if (d.span == null) d.span = e.current_span;
    };
    try stack.check();
    // What this node allocates is dead once it is compiled.
    const slot_mark = e.slot_top;
    defer e.slot_top = slot_mark;
    switch (form.*) {
        .nil => try e.emit(vm.asm_.loadNil(dst)),
        .bool => |b| try e.emit(if (b) vm.asm_.loadTrue(dst) else vm.asm_.loadFalse(dst)),
        .int => |n| try e.emit(vm.asm_.loadConst(dst, try e.addValueConst(value_mod.fromFixnum(n) orelse return CompileError.IntegerOutOfFixnumRange))),
        .literal => |v| try e.emit(vm.asm_.loadConst(dst, try e.addValueConst(v))),
        .symbol => |name| try compileSymbol(e, name, dst),
        .qualified_symbol => |qs| try compileQualifiedSymbol(e, qs.ns, qs.name, dst),
        .coll => |c| try compileColl(e, c.op, c.items, dst),
        .try_ => |t| try compileTry(e, t.body, t.binding, t.handler, t.finally_, t.binding_captured, dst),
        .throw_ => |value| try compileThrow(e, value),
        .prim => |p| try compilePrim(e, p.op, p.lhs, p.rhs, dst),
        .if_ => |i| try compileIf(e, i.test_, i.then, i.else_, dst, recur_target),
        .let_star => |l| try compileLetStar(e, l.bindings, l.body, dst, recur_target),
        .do_ => |exprs| try compileDo(e, exprs, dst, recur_target),
        .fn_star => |f| try compileFn(e, .{
            .self_name = f.name,
            .display_name = f.name,
            .params = f.params,
            .rest_param = f.rest_param,
            .body = f.body,
            .captured = f.captured,
            .self_referenced = f.self_referenced,
        }, dst),
        .call => |c| try compileCall(e, c.callee, c.args, dst),
        .letfn_star => |l| try compileLetFnStar(e, l.bindings, l.body, dst, recur_target),
        .loop_star => |l| try compileLoopStar(e, l.bindings, l.body, dst),
        .recur => |r| try compileRecur(e, r.args, recur_target),
        .def => |d| try compileDef(e, d.name, d.value, dst),
        .var_ref => |v| try compileVarRef(e, v.ns, v.name, dst),
    }
}

/// `coll:<op>` over the items, each compiled into its slot of one
/// block reserved up front: a per-item allocation would interleave
/// with the items' own temporaries and break the block's contiguity.
fn compileColl(e: *Emitter, op: vm.CollOp, items: []const *const Tiny, dst: u12) CompileError!void {
    if (items.len > std.math.maxInt(u12)) return CompileError.SlotOverflow;
    const argc: u12 = @intCast(items.len);
    const base = if (argc == 0) dst else try e.allocSlotBlock(argc);
    for (items, 0..) |item, i| try compileExpr(e, item, base + @as(u12, @intCast(i)), null);
    try e.emit(Inst.primary(.coll, op, Operand.slot(base), .{ .kind = .unused, .index = argc }, Operand.slot(dst)));
}

/// `op` over its operands, read in place where they allow it
/// (`compileOperand`). The left operand is evaluated first, as a
/// call's arguments are; it reads a Var in place only when computing
/// the right one runs no code that could change the Var.
fn compilePrim(e: *Emitter, op: PrimOp, lhs: *const Tiny, rhs: ?*const Tiny, dst: u12) CompileError!void {
    const a = try compileOperand(e, lhs, rhs == null or isLeaf(rhs.?));
    const b = if (rhs) |r| try compileOperand(e, r, true) else Operand.none;
    try e.emit(op.inst(dst, a, b));
}

/// A node that evaluates without running code: a literal or a
/// symbol.
fn isLeaf(t: *const Tiny) bool {
    return switch (t.*) {
        .nil, .bool, .int, .literal, .symbol, .qualified_symbol => true,
        else => false,
    };
}

/// The operand an instruction reads `t` through: a constant, a local
/// held directly in its slot, an upvalue, or (when `allow_var`) a
/// Var, each read in place; anything else is computed into a fresh
/// slot first.
fn compileOperand(e: *Emitter, t: *const Tiny, allow_var: bool) CompileError!Operand {
    if (try directOperand(e, t, allow_var)) |op| return op;
    const tmp = try e.allocSlot();
    try compileExpr(e, t, tmp, null);
    return Operand.slot(tmp);
}

/// `t` as an operand read in place, or null when it needs code.
fn directOperand(e: *Emitter, t: *const Tiny, allow_var: bool) CompileError!?Operand {
    switch (t.*) {
        .nil => return Operand.constant(try e.addValueConst(value_mod.nilValue())),
        .bool => |b| return Operand.constant(try e.addValueConst(value_mod.fromBool(b))),
        .int => |n| {
            const v = value_mod.fromFixnum(n) orelse return CompileError.IntegerOutOfFixnumRange;
            return Operand.constant(try e.addValueConst(v));
        },
        .literal => |v| return Operand.constant(try e.addValueConst(v)),
        .qualified_symbol => |q| {
            if (!allow_var) return null;
            return Operand.varRef(try qualifiedVarIndex(e, q.ns, q.name));
        },
        .symbol => |name| {
            const ref = e.resolveOrCapture(name) catch |err| switch (err) {
                CompileError.UnresolvedSymbol => {
                    if (!allow_var or e.namespace == null) return null;
                    return Operand.varRef(try e.addVarRef(name));
                },
                else => return err,
            };
            return switch (ref) {
                .direct_slot => |slot| Operand.slot(slot),
                .upvalue => |u| Operand.upvalue(u),
                .cell_slot => null,
            };
        },
        else => return null,
    }
}

/// `ns/name`: its Var's root, never a lexical binding
/// (`qualifiedVarIndex`).
fn compileQualifiedSymbol(e: *Emitter, ns_prefix: []const u8, name: []const u8, dst: u12) CompileError!void {
    try e.emit(vm.asm_.varLoadVar(dst, try qualifiedVarIndex(e, ns_prefix, name)));
}

/// The V operand index of `ns_prefix/name`: an alias the current
/// namespace registered (`(require '[real.name :as ns_prefix])`)
/// names its target, any other prefix a namespace, whose own Var
/// `name` must be (no parent chain: qualified means exact). The
/// current namespace's own name is its own Var, interned unbound
/// when the definition is still to come (a forward reference
/// syntax-quote qualified).
fn qualifiedVarIndex(e: *Emitter, ns_prefix: []const u8, name: []const u8) CompileError!u12 {
    const current_ns = e.namespace orelse return CompileError.UnresolvedSymbol;
    const target_ns = qualifiedTarget(current_ns, ns_prefix) orelse return CompileError.UnresolvedSymbol;
    if (target_ns == current_ns) return e.addVarLocal(name);
    const v = target_ns.lookupLocal(name) orelse return CompileError.UnresolvedSymbol;
    return e.addVarTableEntry(v);
}

fn compileSymbol(e: *Emitter, name: []const u8, dst: u12) CompileError!void {
    // Symbol resolution order for the Tiny backend (the Form
    // frontend sits ABOVE this; resolution itself lives here):
    //   1. local (this routine) → dispatch on BindingRef
    //      (.direct_slot / .cell_slot / .upvalue)
    //   2. captured upvalue (parent chain) → resolve.upvalue
    //      + capture (bindings are boxed where they are bound,
    //      so BindingRef is stable across all control-flow paths)
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
/// `UnresolvedSymbol`.
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
        // RHS is non-tail.
        try e.emit(vm.asm_.varStoreVar(dst, idx, try compileOperand(e, val, true)));
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
fn compileVarRef(e: *Emitter, ns: ?[]const u8, name: []const u8, dst: u12) CompileError!void {
    if (e.namespace == null) return CompileError.UnresolvedSymbol;
    const idx = if (ns) |prefix| try qualifiedVarIndex(e, prefix, name) else try e.addVarRef(name);
    try e.emit(vm.asm_.varVarObject(dst, idx));
}

/// Bind `bindings` in order, each RHS compiled into its binding's
/// fresh slot while only the bindings before it are in scope
/// (COMPILER.md §4.3); a binding a closure captures is boxed as it
/// is bound, in code every path through the scope runs (§6.1). The
/// slots go into `slots` when it is given.
fn bindSequential(e: *Emitter, bindings: []const Binding, slots: ?[]u12) CompileError!void {
    for (bindings, 0..) |b, i| {
        const slot = try e.allocSlot();
        // RHS is non-tail (recur invalid in a binding's RHS).
        try compileExpr(e, b.value, slot, null);
        try e.bindLocal(b.name, slot, b.captured);
        if (slots) |out| out[i] = slot;
    }
}

fn compileLetStar(
    e: *Emitter,
    bindings: []const Binding,
    body: *const Tiny,
    dst: u12,
    recur_target: ?*const RecurTarget,
) CompileError!void {
    // Restored by `defer` so an error mid-body leaves no scope
    // behind for a recovering caller.
    const mark = e.scope.items.len;
    defer e.scope.shrinkRetainingCapacity(mark);
    try bindSequential(e, bindings, null);
    // The body is in the let's own tail position.
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
///   <body → result>
///   try-exit post_pc          ; VM pushes .normal(post_pc),
///                              ; jumps to finally_pc
/// catch_pc:
///   <handler → result, binding in scope>
///   try-exit post_pc          ; same: VM pushes .normal,
///                              ; runs finally, resumes post_pc
/// finally_pc:
///   <finally body → scratch_slot>  ; result discarded
///   finally-exit               ; VM pops continuation,
///                              ; dispatches (.normal → post,
///                              ;             .throwing → unwind)
/// post_pc:
///   mov result → dst
///
/// A node writes `dst` as its last act (§4.4), so `dst` may be a
/// live binding's slot (a recur argument's): with a finally, the
/// value waits in `result` until the finally has completed, since a
/// finally that throws must leave `dst`, which an enclosing handler
/// may read, untouched.
///
/// The finally body sees the OUTER lexical scope, NOT the
/// catch binding (which is only in scope inside the handler).
fn compileTry(
    e: *Emitter,
    body: *const Tiny,
    binding: []const u8,
    handler: *const Tiny,
    finally_: ?*const Tiny,
    binding_captured: bool,
    dst: u12,
) CompileError!void {
    const binding_slot = try e.allocSlot();
    const result: u12 = if (finally_ != null) try e.allocSlot() else dst;

    // Emit try-enter with placeholder catch_pc (and
    // finally_pc when present). Patch after we know both PCs.
    const try_enter_pc = e.code.items.len;
    if (finally_ != null) {
        try e.emit(vm.asm_.tryEnterFinally(0, binding_slot, 0));
    } else {
        try e.emit(vm.asm_.tryEnter(0, binding_slot));
    }

    try compileExpr(e, body, result, null);

    // Body-exit try-exit (post_pc placeholder).
    const body_exit_pc = e.code.items.len;
    try e.emit(vm.asm_.tryExit(0));

    // Catch entry.
    e.code.items[try_enter_pc].a = vm.Operand.jump(try e.nextPc());

    // The VM stores the thrown value in the binding's slot and jumps
    // here; a captured binding is boxed first thing.
    const scope_mark = e.scope.items.len;
    defer e.scope.shrinkRetainingCapacity(scope_mark);
    try e.bindLocal(binding, binding_slot, binding_captured);
    try compileExpr(e, handler, result, null);
    e.scope.shrinkRetainingCapacity(scope_mark);

    // Catch-exit try-exit (post_pc placeholder).
    const catch_exit_pc = e.code.items.len;
    try e.emit(vm.asm_.tryExit(0));

    // Optional finally block + finally-exit.
    if (finally_) |fin_body| {
        e.code.items[try_enter_pc].c = vm.Operand.jump(try e.nextPc());
        // The binding is out of scope here; the value is discarded.
        try compileExpr(e, fin_body, try e.allocSlot(), null);
        try e.emit(vm.asm_.finallyExit());
    }

    const post_pc = try e.nextPc();
    e.code.items[body_exit_pc].a = vm.Operand.jump(post_pc);
    e.code.items[catch_exit_pc].a = vm.Operand.jump(post_pc);
    if (result != dst) try e.emit(vm.asm_.move(dst, result));
}

/// Compile `(throw value)`: `ctrl:throw` of the value, read in
/// place where it can be (`compileOperand`). A throw never writes a
/// destination.
fn compileThrow(e: *Emitter, value: *const Tiny) CompileError!void {
    try e.emit(vm.asm_.throwOp(try compileOperand(e, value, true)));
}

/// Lower `(loop* [b1 v1 b2 v2 ...] body)` per COMPILER.md §5.7
/// + VM.md §11.
///
/// Same as `let*` for binding setup (sequential RHS visibility,
/// captured bindings boxed as they are bound). After the bindings
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

    const binding_slots = try e.allocator.alloc(u12, bindings.len);
    defer e.allocator.free(binding_slots);
    const captured_mask = try e.allocator.alloc(bool, bindings.len);
    defer e.allocator.free(captured_mask);
    for (bindings, captured_mask) |b, *c| c.* = b.captured;
    try bindSequential(e, bindings, binding_slots);

    // 4. Mark entry PC (AFTER box-local prelude).
    const entry_pc = try e.nextPc();
    const names = try e.allocator.alloc([]const u8, bindings.len);
    defer e.allocator.free(names);
    for (bindings, names) |b, *n| n.* = b.name;
    const loop_target = RecurTarget{
        .entry_pc = entry_pc,
        .binding_slots = binding_slots,
        .captured_mask = captured_mask,
        .names = names,
    };

    // 5. Compile body with the loop target installed. The
    // body REPLACES (not propagates) any outer recur target —
    // a recur inside the body always targets THIS loop, not an
    // enclosing one (nested-loop rule).
    try compileExpr(e, body, dst, &loop_target);
}

/// Lower `(recur args...)` per COMPILER.md §5.6 + VM.md §11:
/// rebind the target's bindings to the arguments as one parallel
/// assignment, then `jump:jmp` to the target's entry. No `call` is
/// emitted and `dst` is never written.
///
/// An argument no other argument reads the binding of, for a
/// binding no closure captures, is computed straight into the
/// binding's slot: nothing evaluated after it can observe the
/// change. Every other argument is read in place when it is a
/// constant, an upvalue or a slot no rebinding overwrites, and is
/// computed into a fresh slot otherwise; the moves into the
/// bindings follow, a captured binding getting a fresh cell per
/// iteration (the value is boxed in its fresh slot, then
/// installed), since mutating the shared cell would change what
/// earlier closures see.
fn compileRecur(
    e: *Emitter,
    args: []const *const Tiny,
    recur_target: ?*const RecurTarget,
) CompileError!void {
    const target = recur_target orelse return CompileError.RecurOutsideTail;
    if (args.len != target.binding_slots.len) return CompileError.RecurArityMismatch;

    const pending = try e.allocator.alloc(?Operand, args.len);
    defer e.allocator.free(pending);
    for (args, 0..) |arg, i| {
        const slot = target.binding_slots[i];
        var read_elsewhere = false;
        for (args, 0..) |other, j| {
            if (j != i and try readsName(other, target.names[i])) read_elsewhere = true;
        }
        // Recur args are non-tail (any nested recur would target
        // the wrong scope; PLAN §11.3).
        if (!read_elsewhere and !target.captured_mask[i]) {
            try compileExpr(e, arg, slot, null);
            pending[i] = null;
            continue;
        }
        const direct = try directOperand(e, arg, false);
        const in_place = if (direct) |op|
            !target.captured_mask[i] and !(op.kind == .slot and isRecurSlot(target, op.index))
        else
            false;
        if (in_place) {
            pending[i] = direct;
        } else {
            const tmp = try e.allocSlot();
            try compileExpr(e, arg, tmp, null);
            pending[i] = Operand.slot(tmp);
        }
    }
    for (pending, 0..) |maybe_op, i| {
        const op = maybe_op orelse continue;
        const slot = target.binding_slots[i];
        if (target.captured_mask[i]) try e.emit(vm.asm_.closureBoxLocal(op.index));
        if (op.kind == .slot and op.index == slot) continue;
        try e.emit(vm.asm_.moveFrom(slot, op));
    }
    try e.emit(vm.asm_.jumpJmp(target.entry_pc));
}

fn isRecurSlot(target: *const RecurTarget, slot: u12) bool {
    return std.mem.indexOfScalar(u12, target.binding_slots, slot) != null;
}

/// Whether `t` mentions the symbol `name` anywhere, closures and
/// shadowing bindings included: a conservative "might read it".
fn readsName(t: *const Tiny, name: []const u8) CompileError!bool {
    try stack.check();
    const any = struct {
        fn of(items: []const *const Tiny, n: []const u8) CompileError!bool {
            for (items) |item| if (try readsName(item, n)) return true;
            return false;
        }
    }.of;
    return switch (t.*) {
        .nil, .bool, .int, .literal, .qualified_symbol, .var_ref => false,
        .symbol => |sym| std.mem.eql(u8, sym, name),
        .coll => |c| any(c.items, name),
        .do_ => |items| any(items, name),
        .recur => |r| any(r.args, name),
        .prim => |p| try readsName(p.lhs, name) or (if (p.rhs) |r| try readsName(r, name) else false),
        .if_ => |i| try readsName(i.test_, name) or try readsName(i.then, name) or (if (i.else_) |x| try readsName(x, name) else false),
        .let_star, .loop_star => |l| blk: {
            for (l.bindings) |b| if (try readsName(b.value, name)) break :blk true;
            break :blk try readsName(l.body, name);
        },
        .letfn_star => |l| blk: {
            for (l.bindings) |b| if (try readsName(b.body, name)) break :blk true;
            break :blk try readsName(l.body, name);
        },
        .fn_star => |f| try readsName(f.body, name),
        .call => |c| try readsName(c.callee, name) or try any(c.args, name),
        .try_ => |x| try readsName(x.body, name) or try readsName(x.handler, name) or (if (x.finally_) |f| try readsName(f, name) else false),
        .throw_ => |v| try readsName(v, name),
        .def => |d| if (d.value) |v| try readsName(v, name) else false,
    };
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
    // The forms before the last run for effect, into one discard
    // slot, and are not in tail position.
    const discard = try e.allocSlot();
    for (exprs[0 .. exprs.len - 1]) |expr| {
        try compileExpr(e, expr, discard, null);
    }
    // Last expression IS tail position; inherit recur target.
    try compileExpr(e, exprs[exprs.len - 1], dst, recur_target);
}

/// What `compileFn` builds a routine from: a `fn*`, or a `letfn*`
/// binding, which has no self-name (its name's cell is in scope).
const FnSpec = struct {
    /// The self-name the body may refer to.
    self_name: ?[]const u8 = null,
    /// What traces and the disassembler call the routine.
    display_name: ?[]const u8 = null,
    params: []const []const u8,
    rest_param: ?[]const u8,
    body: *const Tiny,
    /// Per parameter, the rest parameter last: captured by a
    /// closure in the body.
    captured: []const bool,
    self_referenced: bool = false,
};

/// Lower a `fn*` (COMPILER.md §5.5): compile the body as a child
/// routine whose free names resolve through this Emitter as
/// captures, register it and its capture descriptor here, and emit
/// `closure:make`. A body that refers to its self-name gets a
/// placeholder cell, allocated before the child is compiled so the
/// child can capture it, and filled with the closure after
/// `closure:make`.
fn compileFn(parent: *Emitter, f: FnSpec, dst: u12) CompileError!void {
    const count = f.params.len + @intFromBool(f.rest_param != null);
    const names = try parent.allocator.alloc([]const u8, count);
    defer parent.allocator.free(names);
    @memcpy(names[0..f.params.len], f.params);
    if (f.rest_param) |rp| names[count - 1] = rp;
    // A name twice in one parameter list is an error, the rest
    // parameter included.
    for (names, 0..) |p, i| {
        for (names[0..i]) |q| if (std.mem.eql(u8, p, q)) return CompileError.DuplicateParam;
    }

    var self_cell_slot: u12 = 0;
    if (f.self_referenced) {
        self_cell_slot = try parent.allocSlot();
        try parent.emit(vm.asm_.closureNewCell(self_cell_slot));
    }

    // `defer`, not `errdefer`: `finish` hands the code and pools
    // over, but the scope and capture lists keep their capacity.
    var child = Emitter.init(parent.allocator, parent.out);
    child.parent = parent;
    child.namespace = parent.namespace;
    child.spanned = parent.spanned;
    child.source = parent.source;
    // The prelude (parameter boxing) carries the fn form's span.
    child.current_span = parent.current_span;
    child.diag = parent.diag;
    defer child.deinit();

    // The self-name is upvalue 0, sourced from the placeholder cell.
    if (f.self_referenced) {
        try child.captures.append(child.allocator, .{ .local_cell_slot = self_cell_slot });
        try child.captured_names.append(child.allocator, .{ .name = f.self_name.?, .upvalue = 0 });
    }

    // Parameters take slots 0.., the rest parameter last, where the
    // VM puts the arguments; a captured one is boxed on entry.
    const captured = try parent.allocator.alloc(bool, count);
    defer parent.allocator.free(captured);
    const slots = try parent.allocator.alloc(u12, count);
    defer parent.allocator.free(slots);
    for (names, 0..) |p, i| {
        captured[i] = i < f.captured.len and f.captured[i];
        slots[i] = try child.allocSlot();
        try child.bindLocal(p, slots[i], captured[i]);
    }

    // `recur` with no enclosing `loop*` rebinds the parameters and
    // re-enters after the boxing prelude; a rest parameter takes
    // the seq `recur` passes as it is (COMPILER.md §5.6).
    const fn_target = RecurTarget{
        .entry_pc = try child.nextPc(),
        .binding_slots = slots,
        .captured_mask = captured,
        .names = names,
    };
    const result_slot = try child.allocSlot();
    try compileExpr(&child, f.body, result_slot, &fn_target);
    try child.emit(vm.asm_.returnSlot(result_slot));

    const sources = try parent.out.dupe(vm.CaptureSource, child.captures.items);
    const upvalue_count: u16 = @intCast(child.captures.items.len);
    const child_compiled = try child.finish();
    // The routine lives on the compile allocator with the tree it
    // belongs to; its name is copied because it borrows from source
    // text that need not outlive the routine.
    const child_routine = try parent.out.create(vm.Routine);
    child_routine.* = .{
        .code = child_compiled.code,
        .consts = child_compiled.consts,
        .capture_descs = child_compiled.capture_descs,
        .var_table = child_compiled.var_table,
        .slot_count = child_compiled.slot_count,
        .fixed_arity = @intCast(f.params.len),
        .variadic = f.rest_param != null,
        .upvalue_count = upvalue_count,
        .name = if (f.display_name) |n| try parent.out.dupe(u8, n) else "fn",
        .spans = child_compiled.spans,
        .origin = if (parent.current_span) |sp| toSourceSpan(sp) else null,
        .source = parent.source,
    };
    const proto_idx = try parent.addRoutineConst(child_routine);
    const cap_desc_idx = try parent.addCaptureDescriptor(.{ .sources = sources });
    try parent.emit(vm.asm_.closureMake(proto_idx, cap_desc_idx, dst));
    if (f.self_referenced) {
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
    for (bindings, cell_slots) |b, *s| {
        s.* = try e.allocSlot();
        try e.emit(vm.asm_.closureNewCell(s.*));
        try e.scope.append(e.allocator, .{ .name = b.name, .ref = .{ .cell_slot = s.* } });
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
        try compileFn(e, .{
            .display_name = b.name,
            .params = b.params,
            .rest_param = b.rest_param,
            .body = b.body,
            .captured = b.captured,
        }, cs);
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

/// A call through the range-call ABI (VM.md §6): the callee and
/// the arguments in one contiguous block, then `call:call` writes the
/// result to `dst`. The block is reserved before any sub-expression
/// is compiled, so their temporaries land above it instead of
/// breaking its contiguity; `dst`, allocated earlier, lies below the
/// block and the callee's frame, so the call cannot clobber it.
fn compileCall(
    e: *Emitter,
    callee: *const Tiny,
    args: []const *const Tiny,
    dst: u12,
) CompileError!void {
    if (args.len >= std.math.maxInt(u12)) return CompileError.SlotOverflow;
    const call_base = try e.allocSlotBlock(1 + @as(u32, @intCast(args.len)));
    // The callee and the arguments are not in tail position.
    try compileExpr(e, callee, call_base, null);
    for (args, 1..) |arg, i| try compileExpr(e, arg, call_base + @as(u12, @intCast(i)), null);
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
    // The test is non-tail and read in place where it can be; a
    // slot it needed is free again once the jump has read it.
    const slot_mark = e.slot_top;
    const test_op = try compileOperand(e, test_form, true);
    const if_false_pc = try e.emitJumpIfFalsePlaceholder(test_op);
    e.slot_top = slot_mark;
    // Both arms inherit tail position.
    try compileExpr(e, then_form, dst, recur_target);
    // An arm that always jumps away (recur, throw) needs no jump
    // past the else arm.
    const end_jmp_pc: ?usize = if (neverFallsThrough(then_form)) null else try e.emitJumpPlaceholder();
    try e.patchJumpHere(if_false_pc);
    if (else_form) |ef| {
        try compileExpr(e, ef, dst, recur_target);
    } else {
        try e.emit(vm.asm_.loadNil(dst));
    }
    if (end_jmp_pc) |pc| try e.patchJumpHere(pc);
}

/// Whether control never reaches the end of `t`'s code: every path
/// through it ends in `recur` or `throw`.
fn neverFallsThrough(t: *const Tiny) bool {
    return switch (t.*) {
        .recur, .throw_ => true,
        .if_ => |i| neverFallsThrough(i.then) and (if (i.else_) |x| neverFallsThrough(x) else false),
        .do_ => |items| items.len > 0 and neverFallsThrough(items[items.len - 1]),
        .let_star => |l| neverFallsThrough(l.body),
        .letfn_star => |l| neverFallsThrough(l.body),
        else => false,
    };
}

// =============================================================================
// Inline tests
//
// What only the compiler can see: the error taxonomy with spans, the
// shape of the bytecode, routine limits, the span table and the stack
// guard. What programs evaluate to is pinned by the case tables in
// test/prop/compile.zig.
// =============================================================================

const testing = std.testing;

/// A routine that returns nil: the top frame a VM boots with before
/// a compiled routine is retargeted onto it.
const stub_code = [_]vm.Inst{vm.asm_.returnNil()};
const stub_routine = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };

/// Compile `src` in a VM's bare namespace (no core installed) and
/// run it; the result outlives the call while `v` lives.
fn runBare(arena: std.mem.Allocator, v: *vm.VM, src: []const u8) !Value {
    const compiled = try compileSourceWith(arena, src, .{ .namespace = v.ensureNamespace(), .interner = v.ensureInterner() });
    const routine = try arena.create(vm.Routine);
    routine.* = compiled.toRoutine("test");
    try v.retargetTop(routine);
    return v.run();
}

test "special forms: the compiler lowers every one the expander passes on" {
    for (expand_mod.special_forms.keys()) |name| {
        const rewritten = for (expanded_away) |away| {
            if (std.mem.eql(u8, name, away)) break true;
        } else false;
        testing.expect(rewritten != lowerings.has(name)) catch |err| {
            std.debug.print("\n  special form {s}\n", .{name});
            return err;
        };
    }
    for (lowerings.keys()) |name| {
        try testing.expect(expand_mod.special_forms.has(name) or std.mem.startsWith(u8, name, "#%"));
    }
}

test "compile errors: each malformed program fails with its variant" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Compiled without an interner, so no macro rewrites the forms:
    // these are the lowering's and the Emitter's own checks.
    const cases = [_]struct { src: []const u8, err: CompileError }{
        .{ .src = "(if)", .err = CompileError.MalformedForm },
        .{ .src = "(if 1)", .err = CompileError.MalformedForm },
        .{ .src = "(if true 1 2 3)", .err = CompileError.MalformedForm },
        .{ .src = "(quote)", .err = CompileError.MalformedForm },
        .{ .src = "(quote 1 2)", .err = CompileError.MalformedForm },
        .{ .src = "(let*)", .err = CompileError.MalformedForm },
        .{ .src = "(let* [x] x)", .err = CompileError.MalformedForm },
        .{ .src = "(let* (x 1) x)", .err = CompileError.ExpectedVector },
        .{ .src = "(let* [1 2] 3)", .err = CompileError.ExpectedSymbol },
        .{ .src = "(fn* [x &] x)", .err = CompileError.MalformedForm },
        .{ .src = "(fn* [x & r y] x)", .err = CompileError.MalformedForm },
        .{ .src = "(fn* (x) x)", .err = CompileError.ExpectedVector },
        .{ .src = "(def)", .err = CompileError.MalformedForm },
        .{ .src = "(def 42 5)", .err = CompileError.ExpectedSymbol },
        .{ .src = "(var)", .err = CompileError.MalformedForm },
        .{ .src = "(fn* [x x] x)", .err = CompileError.DuplicateParam },
        .{ .src = "(fn* [a & a] a)", .err = CompileError.DuplicateParam },
        .{ .src = "(letfn* [(f [] 1) (f [] 2)] (f))", .err = CompileError.DuplicateBinding },
        .{ .src = "(recur)", .err = CompileError.RecurOutsideTail },
        .{ .src = "(loop* [i 0] (let* [x (recur 1)] x))", .err = CompileError.RecurOutsideTail },
        .{ .src = "(loop* [i 0] (do (recur 1) i))", .err = CompileError.RecurOutsideTail },
        .{ .src = "(loop* [i 0] (if (recur 1) i i))", .err = CompileError.RecurOutsideTail },
        .{ .src = "(loop* [i 0] ((fn* [x] x) (recur 1)))", .err = CompileError.RecurOutsideTail },
        .{ .src = "(loop* [i 0] (recur 1 2))", .err = CompileError.RecurArityMismatch },
        .{ .src = "(fn* [a b] (recur 1))", .err = CompileError.RecurArityMismatch },
        .{ .src = "(fn* [a & r] (recur 1))", .err = CompileError.RecurArityMismatch },
        .{ .src = "x", .err = CompileError.UnresolvedSymbol },
        .{ .src = "(let* [x x] x)", .err = CompileError.UnresolvedSymbol },
        .{ .src = "(do missing 1)", .err = CompileError.UnresolvedSymbol },
        .{ .src = "(let* [x 5] ((fn* [] z)))", .err = CompileError.UnresolvedSymbol },
        .{ .src = "(foo 5)", .err = CompileError.UnresolvedSymbol },
        .{ .src = "(def x 5)", .err = CompileError.UnresolvedSymbol },
        .{ .src = "(quote foo)", .err = CompileError.UnsupportedFeature },
        .{ .src = "'foo", .err = CompileError.UnsupportedFeature },
        .{ .src = ":kw", .err = CompileError.UnsupportedFeature },
        .{ .src = "\"s\"", .err = CompileError.UnsupportedFeature },
        .{ .src = "`(a)", .err = CompileError.UnsupportedFeature },
        .{ .src = "(try 1 (catch :my-error e e))", .err = CompileError.UnsupportedFeature },
        .{ .src = "(", .err = CompileError.ReaderFailure },
        .{ .src = "{:a 1 :a 2}", .err = CompileError.ReaderFailure },
        .{ .src = "#{1 1 2}", .err = CompileError.ReaderFailure },
    };
    for (cases) |c| {
        _ = compileSourceWith(a, c.src, .{}) catch |err| {
            if (err != c.err) {
                std.debug.print("\n  source: {s}\n  expected {s}, got {s}\n", .{ c.src, @errorName(c.err), @errorName(err) });
                return error.TestUnexpectedError;
            }
            continue;
        };
        std.debug.print("\n  source: {s} compiled\n", .{c.src});
        return error.TestExpectedError;
    }
    // Only a hand-built tree can carry an integer past the fixnum
    // range: lowering makes a wider literal a bignum.
    try testing.expectError(CompileError.IntegerOutOfFixnumRange, compileTiny(a, &.{ .int = value_mod.fixnum_max + 1 }));
}

test "compile errors: a macro failure is reported at the innermost form, with the expander's message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var v = try vm.VM.init(testing.allocator, &stub_routine);
    defer v.deinit();
    var host_macros = try expand_mod.defaultMacros(testing.allocator);
    defer host_macros.deinit(testing.allocator);
    const src = "(do 1 (let [x] x))";
    var span: ?reader_mod.SrcSpan = null;
    var detail: ?[]const u8 = null;
    try testing.expectError(CompileError.MacroExpansionFailure, compileSourceWith(arena.allocator(), src, .{
        .interner = v.ensureInterner(),
        .host_macros = &host_macros,
        .out_span = &span,
        .out_detail = &detail,
    }));
    try testing.expect(span.?.pos > 0);
    try testing.expect(detail.?.len > 0);
}

test "compile errors: a macro that never stops expanding is MacroDepthExceeded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var v = try vm.VM.init(testing.allocator, &stub_routine);
    defer v.deinit();
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
    var span: ?reader_mod.SrcSpan = null;
    try testing.expectError(CompileError.MacroDepthExceeded, compileSourceWith(arena.allocator(), "(boom)", .{
        .interner = v.ensureInterner(),
        .host_macros = &host_macros,
        .out_span = &span,
    }));
    try testing.expect(span != null);
    try testing.expectError(CompileError.MacroExpansionFailure, compileSourceWith(arena.allocator(), "(if)", .{
        .interner = v.ensureInterner(),
        .host_macros = &host_macros,
    }));
}

test "bytecode: a routine references each Var and each captured name once" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var v = try vm.VM.init(testing.allocator, &stub_routine);
    defer v.deinit();
    const opts: CompileOptions = .{ .namespace = v.ensureNamespace(), .interner = v.ensureInterner() };
    const vars = try compileSourceWith(arena.allocator(), "(do (def x 5) (+ x x))", opts);
    try testing.expectEqual(@as(usize, 1), vars.var_table.len);
    // Two closures over one binding share its cell; one closure
    // naming it twice captures it once.
    const caps = try compileSourceWith(arena.allocator(), "(let* [x 5] ((fn* [] (+ x x))) ((fn* [] x)))", opts);
    try testing.expectEqual(@as(usize, 2), caps.capture_descs.len);
    for (caps.capture_descs) |d| try testing.expectEqual(@as(usize, 1), d.sources.len);
    var boxes: usize = 0;
    for (caps.code) |inst| {
        if (inst.groupOf() == .closure and inst.variant == @intFromEnum(vm.Closure_.box_local)) boxes += 1;
    }
    try testing.expectEqual(@as(usize, 1), boxes);
}

test "bytecode: only a captured binding is boxed, and on every path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { src: []const u8, boxes: usize }{
        .{ .src = "(let* [x 1 y 2] (+ x y))", .boxes = 0 },
        .{ .src = "(let* [x 1 y 2] (if false (fn* [] x) y))", .boxes = 1 },
        .{ .src = "(fn* [x y] (do (if false (fn* [] x) 0) y))", .boxes = 1 },
        // The inner x shadows the outer for the closure.
        .{ .src = "(fn* [x] (let* [x 2] (fn* [] x)))", .boxes = 1 },
        .{ .src = "(loop* [i 0] (if i (fn* [] i) (recur 1)))", .boxes = 2 },
        .{ .src = "(try 1 (catch any e (fn* [] e)))", .boxes = 1 },
        .{ .src = "(fn* f [x] (let* [f 1] (fn* [] f)))", .boxes = 1 },
    };
    for (cases) |c| {
        const compiled = try compileSourceWith(arena.allocator(), c.src, .{});
        var boxes: usize = 0;
        var routines: std.ArrayList(*const vm.Routine) = .empty;
        const top = try arena.allocator().create(vm.Routine);
        top.* = compiled.toRoutine("t");
        try routines.append(arena.allocator(), top);
        while (routines.pop()) |r| {
            for (r.code) |inst| {
                if (inst.groupOf() == .closure and inst.variant == @intFromEnum(vm.Closure_.box_local)) boxes += 1;
            }
            for (r.consts) |k| if (k == .routine) try routines.append(arena.allocator(), k.routine);
        }
        testing.expectEqual(c.boxes, boxes) catch |err| {
            std.debug.print("\n  source: {s}\n", .{c.src});
            return err;
        };
    }
}

test "bytecode: a quoted scalar needs no Value constant beyond itself" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "(quote nil)", "(quote true)" }) |src| {
        const compiled = try compileSourceWith(arena.allocator(), src, .{});
        try testing.expectEqual(@as(usize, 0), compiled.consts.len);
    }
}

test "bytecode: recur runs a 10k-iteration loop in constant stack space" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const compiled = try compileSourceWith(arena.allocator(), "(loop* [i 0] (if (< i 10000) (recur (+ i 1)) i))", .{});
    const routine = compiled.toRoutine("10k-loop");
    var v = try vm.VM.init(testing.allocator, &routine);
    defer v.deinit();
    const stack_before = v.stack_high_water;
    const frames_before = v.frame_high_water;
    try testing.expectEqual(@as(i64, 10000), (try v.run()).asFixnum());
    try testing.expectEqual(stack_before, v.stack_high_water);
    try testing.expectEqual(frames_before, v.frame_high_water);
}

test "bytecode: forms compile and run in a bare namespace" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var v = try vm.VM.init(testing.allocator, &stub_routine);
    defer v.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(i64, 6), (try runBare(a, &v, "(do (def add1 (fn* [n] (+ n 1))) (add1 5))")).asFixnum());
    try testing.expectEqual(@as(i64, 0), (try runBare(a, &v, "(do (def down (fn* down [n] (if (< n 1) n (recur (+ n -1))))) (down 5))")).asFixnum());
    try testing.expectEqual(@as(i64, 42), (try runBare(a, &v, "(do (def f (fn* [] (g))) (def g (fn* [] 42)) (f))")).asFixnum());
    const var_obj = try runBare(a, &v, "(var unbound-yet)");
    try testing.expect(var_obj.kind() == .var_);
    try testing.expect(!vm.VM.asVar(var_obj).bound);
    try testing.expectError(vm.VmError.UnboundVar, runBare(a, &v, "never-bound"));
    try testing.expectError(vm.VmError.ArityMismatch, runBare(a, &v, "((fn* [x y] x) 1)"));
    // A closure over the catch binding sees the thrown value.
    const caught = try compileSourceWith(a, "((try (throw 7) (catch any e (fn* [] e))))", .{});
    const routine = caught.toRoutine("t");
    try v.retargetTop(&routine);
    try testing.expectEqual(@as(i64, 7), (try v.run()).asFixnum());
}

/// `(do nil nil ... tail)`: `pad` nils, each one instruction, ahead
/// of `tail`, so the code `tail` emits starts at pc `pad`.
fn paddedSource(allocator: std.mem.Allocator, pad: usize, tail: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, "(do");
    for (0..pad) |_| try out.appendSlice(allocator, " nil");
    try out.print(allocator, " {s})", .{tail});
    return out.toOwnedSlice(allocator);
}

test "routine limits: a jump past the 12-bit range is JumpTargetOutOfRange at the form that needs it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "(if true 1 2)", "(try 1 (catch any e 2))", "(try 1 (catch any e 2) (finally 3))", "(loop* [i 1] (if i (recur nil) 2))" }) |tail| {
        const ok = try paddedSource(a, 4000, tail);
        _ = try compileSourceWith(a, ok, .{});
        const src = try paddedSource(a, 4100, tail);
        var span: ?reader_mod.SrcSpan = null;
        try testing.expectError(CompileError.JumpTargetOutOfRange, compileSourceWith(a, src, .{ .out_span = &span }));
        try testing.expectEqual(src.len - 1 - tail.len, span.?.pos);
    }
}

test "routine limits: at most 4096 slots are live at once" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]struct { n: usize, ok: bool }{ .{ .n = 4000, .ok = true }, .{ .n = 4100, .ok = false } }) |c| {
        var src: std.ArrayList(u8) = .empty;
        try src.appendSlice(a, "(let* [");
        for (0..c.n) |i| try src.print(a, "a{d} {d} ", .{ i, i });
        try src.appendSlice(a, "] a0)");
        if (c.ok) {
            _ = try compileSourceWith(a, src.items, .{});
        } else {
            var span: ?reader_mod.SrcSpan = null;
            try testing.expectError(CompileError.SlotOverflow, compileSourceWith(a, src.items, .{ .out_span = &span }));
            // Reported at the form whose binding did not fit.
            try testing.expectEqual(@as(usize, 0), span.?.pos);
        }
    }
}

test "routine limits: at most 4096 constants" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]struct { n: usize, ok: bool }{ .{ .n = 4096, .ok = true }, .{ .n = 4097, .ok = false } }) |c| {
        var src: std.ArrayList(u8) = .empty;
        try src.appendSlice(a, "(do");
        for (0..c.n) |i| try src.print(a, " {d}", .{i});
        try src.appendSlice(a, ")");
        if (c.ok) {
            _ = try compileSourceWith(a, src.items, .{});
        } else {
            try testing.expectError(CompileError.ConstantPoolOverflow, compileSourceWith(a, src.items, .{}));
        }
    }
}

test "compile span: an error is reported at the innermost form that raised it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { src: []const u8, at: []const u8, err: CompileError }{
        .{ .src = "(fn* [x] (let* [y 1] (+ 1 (recur 2))))", .at = "(recur 2)", .err = CompileError.RecurOutsideTail },
        .{ .src = "(fn* [x] (do 1 (recur 1 2)))", .at = "(recur 1 2)", .err = CompileError.RecurArityMismatch },
        .{ .src = "(do 1 (let* [x 1] (if)))", .at = "(if)", .err = CompileError.MalformedForm },
        .{ .src = "(let* [f (fn* [a a] a)] f)", .at = "(fn* [a a] a)", .err = CompileError.DuplicateParam },
    };
    for (cases) |c| {
        var span: ?reader_mod.SrcSpan = null;
        try testing.expectError(c.err, compileSourceWith(arena.allocator(), c.src, .{ .out_span = &span }));
        try testing.expectEqual(std.mem.indexOf(u8, c.src, c.at).?, span.?.pos);
        try testing.expectEqual(c.at.len, span.?.len);
    }
}

/// `depth` vectors nested around `1`, built without the reader,
/// quoted when `quoted`.
fn nestedVectorForm(allocator: std.mem.Allocator, depth: usize, quoted: bool) !*reader_mod.Form {
    const origin: reader_mod.SrcSpan = .{ .pos = 0, .len = 1 };
    var form = try allocator.create(reader_mod.Form);
    form.* = .{ .datum = .{ .int = 1 }, .origin = origin };
    for (0..depth) |_| {
        const items = try allocator.alloc(*reader_mod.Form, 1);
        items[0] = form;
        form = try allocator.create(reader_mod.Form);
        form.* = .{ .datum = .{ .vector = items }, .origin = origin };
    }
    if (!quoted) return form;
    const q = try allocator.create(reader_mod.Form);
    q.* = .{ .datum = .{ .quote = form }, .origin = origin };
    return q;
}

test "stack guard: a form nested past the stack budget is StackOverflow, not a crash" {
    stack.armIfUnarmed(stack.main_thread_budget);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]bool{ false, true }) |quoted| {
        const deep = try nestedVectorForm(a, 100_000, quoted);
        var declared = DeclaredNames.init(testing.allocator);
        defer declared.deinit();
        try testing.expectError(CompileError.StackOverflow, compileFormWith(a, deep, .{ .declared = &declared }));
        const shallow = try nestedVectorForm(a, 100, quoted);
        _ = try compileFormWith(a, shallow, .{ .declared = &declared });
    }
    // A hand-built Tiny tree reaches the Emitter without lowering;
    // a one-form `do` allocates no slot, so only depth can fail it.
    var tiny: *const Tiny = &.{ .int = 1 };
    for (0..100_000) |_| {
        const node = try a.create(Tiny);
        const items = try a.alloc(*const Tiny, 1);
        items[0] = tiny;
        node.* = .{ .do_ = items };
        tiny = node;
    }
    try testing.expectError(CompileError.StackOverflow, compileTiny(a, tiny));
}

test "declared names: an unresolved symbol is reported at its own span" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var v = try vm.VM.init(testing.allocator, &stub_routine);
    defer v.deinit();
    var declared = DeclaredNames.init(testing.allocator);
    defer declared.deinit();
    var span: ?reader_mod.SrcSpan = null;
    const opts: CompileOptions = .{
        .namespace = v.ensureNamespace(),
        .interner = v.ensureInterner(),
        .declared = &declared,
        .out_span = &span,
    };
    const src = "(fn* [x] (let* [z 1] (+ x (< z y))))";
    try testing.expectError(CompileError.UnresolvedSymbol, compileSourceWith(arena.allocator(), src, opts));
    const sp = span orelse return error.TestFailed;
    try testing.expectEqualStrings("y", src[sp.pos .. sp.pos + sp.len]);
    // Declaring it makes the same source compile.
    try declared.declare("y");
    _ = try compileSourceWith(arena.allocator(), src, opts);
}

test "declared names: lexical bindings, quoted data and same-form definitions resolve" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var v = try vm.VM.init(testing.allocator, &stub_routine);
    defer v.deinit();
    var host_macros = try expand_mod.defaultMacros(testing.allocator);
    defer host_macros.deinit(testing.allocator);
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
        _ = compileSourceWith(arena.allocator(), src, .{
            .namespace = v.ensureNamespace(),
            .interner = v.ensureInterner(),
            .host_macros = &host_macros,
            .declared = &declared,
        }) catch |err| {
            std.debug.print("\n  source: {s}\n  error: {s}\n", .{ src, @errorName(err) });
            return err;
        };
    }
}

test "declared names: declareForm collects def/defn/defonce/defmacro/defrecord/defprotocol through do" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "(do (def a 1) (defn b [] 2) (defmacro c [] 3) (defonce d 4) (defrecord R [x]) (defprotocol P (m [s]) (n [s])) (println z))";
    var p = try reader_mod.parser.parseForm(arena.allocator(), src);
    defer p.parser.deinit();
    var reader = reader_mod.Reader.init(arena.allocator(), src);
    defer reader.deinit();
    const form = try reader.readOneForm(p.sexp);

    var declared = DeclaredNames.init(testing.allocator);
    defer declared.deinit();
    try declared.declareForm(form);
    for ([_][]const u8{ "a", "b", "c", "d", "R", "R-type-id", "->R", "map->R", "R?", "P", "m", "n" }) |name| {
        try testing.expect(declared.contains(name));
    }
    try testing.expect(!declared.contains("z"));
    try testing.expect(!declared.contains("println"));
}

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
    var v = try vm.VM.init(testing.allocator, &stub_routine);
    defer v.deinit();
    const ns = v.ensureNamespace();
    const src = "(def sq (fn* sq [x]\n  (* x x)))";
    const compiled = try compileSourceWith(arena.allocator(), src, .{ .namespace = ns, .interner = v.ensureInterner() });
    var child: ?*const vm.Routine = null;
    for (compiled.consts) |c| if (c == .routine) {
        child = c.routine;
    };
    const r = child orelse return error.TestFailed;
    try testing.expectEqualStrings("sq", r.name);
    try testing.expect(r.spans.len > 0);
    const origin = r.origin orelse return error.TestFailed;
    try testing.expectEqualStrings("(fn* sq [x]\n  (* x x))", src[origin.pos .. origin.pos + origin.len]);
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
