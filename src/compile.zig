//! compile.zig — the compiler: `reader.Form` → `Tiny` IR → bytecode
//! (docs/COMPILER.md, which owns the lowering of every form).
//!
//! `compileFormWith` macroexpands a form (`expand.zig`), lowers it to a
//! `Tiny` tree (`lowerForm`), and emits that tree with `emitRoutine`:
//! destination-driven, each node's `compileExpr(emitter, node, dst,
//! recur_target)` writing its value into the slot its parent chose.
//! `Tiny` is the only IR. `RuntimeHooks` is the compiler as `eval`,
//! `read-string` and `macroexpand-1` reach it at run time.

const std = @import("std");
const vm = @import("vm.zig");
const value_mod = @import("value.zig");
const reader_mod = @import("reader.zig");
const intern_mod = @import("intern.zig");
const seq_mod = @import("seq.zig");
const expand_mod = @import("expand.zig");
const heap_mod = @import("heap.zig");
const string_mod = @import("string.zig");
const regex_mod = @import("regex.zig");
const bignum_mod = @import("bignum.zig");
const stack = @import("stack.zig");
const list_mod = @import("coll/list.zig");
const vector_mod = @import("coll/vector.zig");
const champ_mod = @import("coll/champ.zig");
const dispatch_mod = @import("dispatch.zig");

const Inst = vm.Inst;
const Routine = vm.Routine;
const Operand = vm.Operand;
const Value = value_mod.Value;

// =============================================================================
// Tiny — the compiler's IR: the special forms, with every symbol
// reference still a name. Sub-expressions are pointers into the
// compile allocator (tests build small trees as `&Tiny{ ... }`).
// =============================================================================

const Tiny = union(enum) {
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
    /// data, or a collection of constants built at lowering. It
    /// lives in the routine's constant pool, which keeps a heap
    /// Value alive for as long as the routine can run.
    literal: value_mod.Value,
    /// A collection built from its evaluated items: the internal
    /// `#%list`, `#%concat`, `#%vector`, `#%map` and `#%set` forms
    /// syntax-quote emits and `[...]`, `{...}` and `#{...}` literals.
    /// Map items are flat key, value pairs.
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
    /// rule 2); `rhs` is null for the unary ops. `more` are the
    /// arguments past two of `+`, `*` or `-`, folded left once every
    /// argument is computed, one instruction each.
    prim: struct {
        op: PrimOp,
        lhs: *const Tiny,
        rhs: ?*const Tiny = null,
        more: []const *const Tiny = &.{},
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
    /// `(fn* name? [params... & rest?] body)`, or `(fn* name?
    /// ([params...] body)+)` with a clause per arity.
    fn_star: struct {
        /// The self-name the bodies may refer to (COMPILER.md §5.5).
        name: ?[]const u8 = null,
        /// In source order; more than one compile to a routine each
        /// over one arity table (VM.md §5).
        clauses: []const Clause,
        /// Whether a body refers to `name`, which then needs a
        /// placeholder cell (COMPILER.md §5.5).
        self_referenced: bool = false,
    },
    /// `(callee args...)` through the range-call ABI (VM.md §6).
    call: struct {
        callee: *const Tiny,
        args: []const *const Tiny,
    },
    /// A call of the enclosing `fn*`'s self-name with a fixed arity of
    /// one of its clauses, from a body of its own: `call:self`
    /// (COMPILER.md §5.5).
    self_call: []const *const Tiny,
    /// `(k target)` or `(k target default)`, `k` a keyword or symbol
    /// literal: `call:lookup` or `call:lookup-or` (COMPILER.md §4.3).
    lookup: struct {
        key: *const Tiny,
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
    /// `(letfn* [(name [params] body...) ...] body)`, an entry with a
    /// clause per arity as `fn*` takes them: every name is visible to
    /// every function and the body (COMPILER.md §5.6b).
    letfn_star: struct {
        bindings: []const FnBinding,
        body: *const Tiny,
    },
};

/// The operation of a `Tiny.prim`: the VM's `math` and `cmp`
/// variants that run the same numeric-tower helpers as the core
/// fns they stand for (VM.md §10).
const PrimOp = enum {
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

/// The core fns inlined as a `Tiny.prim`, at the arity each inlines
/// at, or at any arity from it when `fold`; `inc` and `dec` are `+`
/// and `-` with a constant 1. Every other arity is an ordinary call.
const Inlined = struct { name: []const u8, argc: usize, op: PrimOp, one: bool = false, fold: bool = false };
const inlined_ops = [_]Inlined{
    .{ .name = "+", .argc = 2, .op = .add, .fold = true },
    .{ .name = "-", .argc = 2, .op = .sub, .fold = true },
    .{ .name = "*", .argc = 2, .op = .mul, .fold = true },
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

/// One arity of a `fn*` or a `letfn*` binding.
const Clause = struct {
    params: []const []const u8,
    /// Bound at slot `params.len`, to the list of the arguments past
    /// the fixed ones (VM.md §6).
    rest_param: ?[]const u8 = null,
    body: *const Tiny,
    /// Per parameter (the rest parameter last): whether a closure in
    /// the body captures it, so it is boxed on entry.
    captured: []const bool = &.{},
};

/// One binding in a `letfn*` form. Each is a function
/// definition (mutually visible across the binding group).
const FnBinding = struct {
    name: []const u8,
    clauses: []const Clause,
};

/// The sequential bindings and body of a `let*` or `loop*`.
const Scope = struct {
    bindings: []const Binding,
    body: *const Tiny,
};

/// One binding in a `let*` form.
const Binding = struct {
    name: []const u8,
    value: *const Tiny,
    /// Whether a closure in the binding's scope captures it
    /// (COMPILER.md §6.1).
    captured: bool = false,
    /// How many symbols in the binding's scope read it, as lowering
    /// resolved them (`and`/`or` shapes, §5.2).
    refs: u32 = 0,
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
const BindingRef = union(enum) {
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

/// The lexical names in force where lowering or emitting is, each
/// holding a `T`: every name maps to its innermost binding, which
/// records the one it shadows, so a lookup is one probe however deep
/// the scopes nest, and `restore` unbinds exactly what was bound since
/// a `mark` (COMPILER.md §4.3).
fn ScopeTable(comptime T: type) type {
    return struct {
        entries: std.ArrayList(Entry) = .empty,
        innermost: std.StringHashMapUnmanaged(u32) = .empty,

        const Self = @This();
        const Entry = struct { name: []const u8, value: T, shadows: ?u32 };

        fn bind(self: *Self, allocator: std.mem.Allocator, name: []const u8, value: T) CompileError!void {
            try self.entries.ensureUnusedCapacity(allocator, 1);
            const slot = try self.innermost.getOrPut(allocator, name);
            const shadows: ?u32 = if (slot.found_existing) slot.value_ptr.* else null;
            slot.value_ptr.* = @intCast(self.entries.items.len);
            self.entries.appendAssumeCapacity(.{ .name = name, .value = value, .shadows = shadows });
        }

        fn lookup(self: *const Self, name: []const u8) ?T {
            return self.entries.items[self.innermost.get(name) orelse return null].value;
        }

        fn mark(self: *const Self) usize {
            return self.entries.items.len;
        }

        fn restore(self: *Self, to: usize) void {
            while (self.entries.items.len > to) {
                const e = self.entries.pop().?;
                if (e.shadows) |i| self.innermost.getPtr(e.name).?.* = i else _ = self.innermost.remove(e.name);
            }
        }

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.entries.deinit(allocator);
            self.innermost.deinit(allocator);
        }
    };
}

/// Routine-level capture cache entry. Maps a captured name to its upvalue index, so repeat references
/// to the same outer name from different lexical scopes share
/// a single upvalue/descriptor entry.
const CapturedName = struct {
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
const RecurTarget = struct {
    entry_pc: u32,
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
    /// Whether a tail position of this target is a tail of the
    /// function: a form there ends by returning its value itself
    /// (`call:return`) instead of writing the destination and
    /// falling through to the return after the body (COMPILER.md
    /// §5.5). True for a `fn*`'s target and a `loop*` in its tail.
    returns: bool = false,
    /// Per binding: whether it holds a number on every iteration
    /// (`numericBindings`), so arithmetic on it cannot fail.
    numeric: []const bool = &.{},
    /// The test at the entry, which a `recur` in an arm of the
    /// entry's `if` repeats instead of jumping back to it.
    bottom: ?BottomTest = null,
};

/// A target's entry test, `(if test then else)` at its entry pc, as
/// a `recur` repeats it at the loop's bottom (COMPILER.md §5.7): the
/// `len` instructions from the entry, the jump to the else arm last,
/// with their spans, so the iteration branches back once instead of
/// jumping to the entry and testing there. The then arm starts right
/// after them.
const BottomTest = struct {
    entry_pc: u32,
    len: u32,
    /// Where the `recur` is. In the then arm it branches back to the
    /// then arm when the test would not jump, and jumps to the else
    /// arm (patched from the list) when it would; in the else arm,
    /// at its pc, the other way round.
    arm: union(enum) { then: *Jumps, else_: u32 },
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

    /// A routine needs more than 4096 slots live at once or more
    /// than 4096 upvalues, the two limits the 12-bit slot and
    /// upvalue operands leave (COMPILER.md §4.4); `LowerDiag.detail`
    /// names the routine and the limit.
    SlotOverflow,

    /// A symbol resolves to nothing COMPILER.md §4.3 classifies: no
    /// local, upvalue, namespace Var or name the file or line
    /// defines. Without a namespace, anything that is not a local
    /// or an upvalue raises this.
    UnresolvedSymbol,

    /// Two bindings in the same `letfn*` group carry the same
    /// name. Unlike `let*` (sequential shadowing allowed),
    /// `letfn*` names are mutually visible — duplicates
    /// create resolution ambiguity. Matches Clojure
    /// (`letfn` rejects duplicate names).
    DuplicateBinding,

    /// `(recur ...)` appears in a position that is not a tail
    /// position of an enclosing `loop*` or `fn*` body. Per
    /// COMPILER.md §4.4, §5.6 + VM.md §11: `recur` MUST
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
    consts: []const Value,
    capture_descs: []const vm.CaptureDescriptor = &.{},
    /// The routine's `try` forms, which `ctrl:try-enter` names.
    tries: []const vm.Try = &.{},
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
            .tries = self.tries,
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
const TinyNode = struct {
    span: ?reader_mod.SrcSpan = null,
    tiny: Tiny,
};

fn toSourceSpan(span: reader_mod.SrcSpan) vm.SourceSpan {
    return .{ .pos = span.pos, .len = span.len };
}

// =============================================================================
// Emitter — internal mutable accumulator
// =============================================================================

/// How many slots, upvalues, and in-place constants and Vars an
/// operand's 12-bit index addresses (VM.md §3).
const max_operands = 1 << 12;

/// A pc, or a constant, Var, try or capture-descriptor index, which
/// the VM reads from an instruction's 32-bit wide field; a table that
/// outgrows it cannot have been allocated.
fn tableIndex(n: usize) CompileError!u32 {
    return std.math.cast(u32, n) orelse CompileError.OutOfMemory;
}

/// The target a jump or handler instruction carries until it is
/// patched: past any routine's code, so a missed patch fails in the
/// VM instead of jumping.
const unpatched = std.math.maxInt(u32);

/// A value computed into `dst` that nothing reads until its last
/// instruction writes it, with the slots from `lo` below it dead too:
/// the items of `dst`'s block still to be written. The value's own
/// evaluation may use `lo` and up as working space (COMPILER.md §4.4).
const Scratch = struct { lo: u12, dst: u12 };

/// A Var's value in force, read into `slot` by a block item. Until
/// another instruction runs, a read of the same Var yields the same
/// value, so a later item copies the slot instead of holding a read
/// of its own while its neighbours run (COMPILER.md §4.4).
const HeldVar = struct { var_: *vm.Var, slot: u12 };

/// `Emitter` accumulates a routine's bytecode, constants, slot
/// count, and active lexical scope as a tree of `compileExpr`
/// calls runs. It's allocator-owned and turned into a `Compiled`
/// at the end via `finish()`.
///
/// **Slot allocation**: a stack (`slot_top`); `compileExpr` frees
/// what a node allocated once the node is compiled.
///
/// **Constant pool**: one entry per identical Value (COMPILER.md
/// §4.4).
///
/// **Lexical scope**: a `ScopeTable` of each local's `BindingRef`.
/// Bindings are made at let* binding-time (after the RHS is compiled,
/// per COMPILER.md §4.3's strict left-of-self rule) and unmade at
/// let-body exit via `defer scope.restore(mark)`, `defer` so an error
/// mid-body leaves no scope behind for a recovering caller. Nested
/// function compilation resolves free names through the `parent`
/// chain (capture analysis at function boundaries).
const Emitter = struct {
    /// Scratch: what compiling needs and nothing after it.
    allocator: std.mem.Allocator,
    /// Where the routines go: their code, pools, span tables, names
    /// and nested routines, which live as long as the caller needs.
    out: std.mem.Allocator,
    code: std.ArrayList(Inst) = .empty,
    consts: std.ArrayList(Value) = .empty,
    /// Where each constant sits in `consts`.
    value_consts: std.AutoHashMapUnmanaged([2]u64, u32) = .empty,
    capture_descs: std.ArrayList(vm.CaptureDescriptor) = .empty,
    tries: std.ArrayList(vm.Try) = .empty,
    /// Where each of `tries` lies in the code, for `clearDeadMoves`.
    try_extents: std.ArrayList(TryExtent) = .empty,
    /// Whether `finish` clears each local at its last move (§4.9).
    clear_locals: bool = false,
    scope: ScopeTable(BindingRef) = .{},
    /// The next free slot. Slots are a stack: `compileExpr` frees
    /// every slot a node allocated once the node is compiled, so a
    /// slot lives as long as the value in it is needed (bindings to
    /// the end of their scope, temporaries until their consumer is
    /// emitted), and a block always lies above every live slot
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
    /// The slot a value is being computed into when nothing reads it
    /// until the value's last instruction writes it (`Scratch`).
    scratch: ?Scratch = null,
    /// Vars a block item read into a slot, all at pc `held_pc`
    /// (`HeldVar`); none once code grows past it.
    held: [8]HeldVar = undefined,
    held_len: u8 = 0,
    held_pc: usize = 0,
    /// Whether control can reach the next instruction: false after a
    /// jump, return, throw or `try` exit until the next label
    /// (`nextPc`), so a form that never falls through needs no jump
    /// past what follows it.
    reachable: bool = true,
    /// Whether this routine is a `fn*`'s, and its name when it has
    /// one: what a limit error names.
    is_fn: bool = false,
    fn_name: ?[]const u8 = null,

    fn init(allocator: std.mem.Allocator, out: std.mem.Allocator) Emitter {
        return .{ .allocator = allocator, .out = out };
    }

    fn deinit(self: *Emitter) void {
        self.span_table.deinit(self.allocator);
        self.code.deinit(self.allocator);
        self.consts.deinit(self.allocator);
        self.value_consts.deinit(self.allocator);
        self.capture_descs.deinit(self.allocator);
        self.tries.deinit(self.allocator);
        self.try_extents.deinit(self.allocator);
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
        try self.scope.bind(self.allocator, name, if (captured) .{ .cell_slot = slot } else .{ .direct_slot = slot });
    }

    /// Resolve `name` to a `BindingRef` via innermost-shadow
    /// lookup of ONLY the current Emitter's scope. Returns null
    /// if no binding matches; callers walk the parent chain via
    /// `resolveOrCapture` if appropriate. Returns the full
    /// BindingRef so callers can dispatch on direct/cell/upvalue
    /// at emit time.
    fn resolveLocalRef(self: *const Emitter, name: []const u8) ?BindingRef {
        return self.scope.lookup(name);
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
        if (u_idx_usize >= max_operands) return self.limit("captured locals");
        const u_idx: u12 = @intCast(u_idx_usize);
        try self.captures.append(self.allocator, source);
        try self.captured_names.append(self.allocator, .{ .name = name, .upvalue = u_idx });
        return .{ .upvalue = u_idx };
    }

    /// Allocate a fresh slot on top of the live ones.
    fn allocSlot(self: *Emitter) CompileError!u12 {
        return self.allocSlotBlock(1);
    }

    /// Allocate a contiguous run of `count` fresh slots on top of
    /// the live ones; return the first.
    fn allocSlotBlock(self: *Emitter, count: usize) CompileError!u12 {
        return self.claimSlots(self.slot_top, count) orelse self.limit("local slots");
    }

    /// The base of a block of `count` slots for the instruction that
    /// writes `dst`: the lowest dead slot of `dst`'s scratch, else on
    /// top of every live slot; null when it would pass slot 4095.
    fn reserveBlock(self: *Emitter, dst: u12, count: usize) ?u12 {
        return self.claimSlots(self.scratchFrom(dst) orelse self.slot_top, count);
    }

    /// Slots `base` up to `base + count` in use, when they fit.
    fn claimSlots(self: *Emitter, base: u16, count: usize) ?u12 {
        if (base + count > max_operands) return null;
        self.slot_top = @max(self.slot_top, base + @as(u16, @intCast(count)));
        self.slot_count = @max(self.slot_count, self.slot_top);
        return @intCast(base);
    }

    /// The lowest slot a value computed into `dst` may build in:
    /// `scratch`'s dead slots while nothing is live above `dst`.
    fn scratchFrom(self: *const Emitter, dst: u12) ?u16 {
        const s = self.scratch orelse return null;
        return if (s.dst == dst and self.slot_top == @as(u16, dst) + 1) s.lo else null;
    }

    /// `SlotOverflow`, with `LowerDiag.detail` naming this routine
    /// and the limit it reached, `what` (COMPILER.md §7).
    fn limit(self: *const Emitter, comptime what: []const u8) CompileError {
        const d = self.diag orelse return CompileError.SlotOverflow;
        if (d.detail != null) return CompileError.SlotOverflow;
        const tail = ": more than " ++ std.fmt.comptimePrint("{d}", .{max_operands}) ++ " " ++ what;
        d.detail = (if (!self.is_fn)
            self.allocator.print("top-level form" ++ tail, .{})
        else if (self.fn_name) |name|
            self.allocator.print("fn {s}" ++ tail, .{name})
        else
            self.allocator.print("anonymous fn" ++ tail, .{})) catch return CompileError.OutOfMemory;
        return CompileError.SlotOverflow;
    }

    /// The pool index of `v`, one entry per identical Value (same
    /// bits: the same immediate, or the same heap object).
    fn addValueConst(self: *Emitter, v: Value) CompileError!u32 {
        const key = [2]u64{ v.tag, v.payload };
        if (self.value_consts.get(key)) |idx| return idx;
        const idx = try tableIndex(self.consts.items.len);
        try self.consts.append(self.allocator, v);
        try self.value_consts.put(self.allocator, key, idx);
        return idx;
    }

    /// `v` as a `c` operand, or null when its index lies past what
    /// an operand addresses and it must be loaded into a slot.
    fn constOperand(self: *Emitter, v: Value) CompileError!?Operand {
        const idx = try self.addValueConst(v);
        return if (idx < max_operands) Operand.constant(@intCast(idx)) else null;
    }

    /// Add a capture descriptor to the emitter's table; return
    /// its index for `closure:make`'s wide field.
    fn addCaptureDescriptor(self: *Emitter, desc: vm.CaptureDescriptor) CompileError!u32 {
        const idx = try tableIndex(self.capture_descs.items.len);
        try self.capture_descs.append(self.allocator, desc);
        return idx;
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
    fn addVarRef(self: *Emitter, name: []const u8) CompileError!u32 {
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
    fn addVarLocal(self: *Emitter, name: []const u8) CompileError!u32 {
        const ns = self.namespace orelse return CompileError.InternalCompilerBug;
        const v = ns.intern(name) catch return CompileError.OutOfMemory;
        return self.addVarTableEntry(v);
    }

    /// Dedup-append `v` to the routine's var table: a routine that
    /// references one Var twice carries one entry.
    fn addVarTableEntry(self: *Emitter, v: *vm.Var) CompileError!u32 {
        for (self.var_table.items, 0..) |existing, i| {
            if (existing == v) return @intCast(i);
        }
        const idx = try tableIndex(self.var_table.items.len);
        try self.var_table.append(self.allocator, v);
        return idx;
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
        if (transfersAway(inst)) self.reachable = false;
    }

    /// The pc of the next instruction, a jump or handler target.
    /// Control reaches a target from elsewhere too, so a Var read
    /// before it is not what a read there sees on every path.
    fn nextPc(self: *Emitter) CompileError!u32 {
        self.held_len = 0;
        self.reachable = true;
        return tableIndex(self.code.items.len);
    }

    /// Whether `name` is a local of this routine or of one it is
    /// nested in, never a Var.
    fn isLexical(self: *const Emitter, name: []const u8) bool {
        var e: ?*const Emitter = self;
        while (e) |r| : (e = r.parent) {
            if (r.resolveLocalRef(name) != null or r.lookupCapturedName(name) != null) return true;
        }
        return false;
    }

    /// The slot holding `v` as read at this pc, if a block item
    /// read it there.
    fn heldSlot(self: *const Emitter, v: *vm.Var) ?u12 {
        if (self.held_pc != self.code.items.len) return null;
        for (self.held[0..self.held_len]) |h| {
            if (h.var_ == v) return h.slot;
        }
        return null;
    }

    /// Record that the instruction just emitted, at `pc`, read `v`
    /// into `slot`: a Var read is no code, so what was held before
    /// it still is.
    fn hold(self: *Emitter, v: *vm.Var, slot: u12, pc: usize) void {
        if (self.held_pc != pc) self.held_len = 0;
        self.held_pc = self.code.items.len;
        if (self.held_len == self.held.len) return;
        self.held[self.held_len] = .{ .var_ = v, .slot = slot };
        self.held_len += 1;
    }

    /// Point the jump or handler instruction emitted at `at` at the
    /// next instruction.
    fn patchJumpHere(self: *Emitter, at: usize) CompileError!void {
        self.code.items[at].setWide(try self.nextPc());
    }

    /// The span the instruction at `pc` carries.
    fn spanAt(self: *const Emitter, pc: usize) ?reader_mod.SrcSpan {
        var i = self.span_table.items.len;
        while (i > 0) {
            i -= 1;
            const entry = self.span_table.items[i];
            if (entry.pc <= pc) return .{ .pos = entry.span.pos, .len = entry.span.len };
        }
        return null;
    }

    /// Remove the last instruction, which nothing targets.
    fn dropLast(self: *Emitter) void {
        _ = self.code.pop();
        const spans = &self.span_table.items;
        if (spans.len > 0 and spans.*[spans.len - 1].pc == self.code.items.len) _ = self.span_table.pop();
    }

    /// Emit `inst`, whose target is still to be patched; return its
    /// pc for `patchJumpHere`.
    fn emitPlaceholder(self: *Emitter, inst: Inst) CompileError!usize {
        const pc = self.code.items.len;
        try self.emit(inst);
        return pc;
    }

    /// The routine's code, pools and span table, copied onto `out`,
    /// each local cleared at its last move when `clear_locals` (§4.9)
    /// and then the code quickened (VM.md §10.10).
    ///
    /// Ownership transfer is errdefer-safe: if
    /// any `toOwnedSlice` fails after a previous one succeeded,
    /// the earlier slice would leak under a non-arena allocator.
    /// The chained errdefers guard against that.
    fn finish(self: *Emitter) CompileError!Compiled {
        const code = try self.out.dupe(Inst, self.code.items);
        errdefer self.out.free(code);
        const consts = try self.out.dupe(Value, self.consts.items);
        errdefer self.out.free(consts);
        const slot_count: u16 = if (self.slot_count == 0) 1 else self.slot_count;
        if (self.clear_locals) _ = try clearDeadMoves(self.allocator, code, slot_count, self.capture_descs.items, self.tries.items, self.try_extents.items);
        vm.quicken(code, consts);
        const caps = try self.out.dupe(vm.CaptureDescriptor, self.capture_descs.items);
        errdefer self.out.free(caps);
        const tries = try self.out.dupe(vm.Try, self.tries.items);
        errdefer self.out.free(tries);
        const vt = try self.out.dupe(*vm.Var, self.var_table.items);
        errdefer self.out.free(vt);
        const spans = try self.out.dupe(vm.SpanEntry, self.span_table.items);
        errdefer self.out.free(spans);
        return .{
            .code = code,
            .consts = consts,
            .capture_descs = caps,
            .tries = tries,
            .var_table = vt,
            .slot_count = slot_count,
            .fixed_arity = 0, // top-level only; compileFn sets this for child routines via Routine struct
            .variadic = false, // top-level routine never variadic
            .spans = spans,
            .source = self.source,
        };
    }
};

/// Whether control never passes from `inst` to the instruction after
/// it: a jump, a return, a throw, or a `try` or `finally` exit.
fn transfersAway(inst: Inst) bool {
    if (inst.kind != .primary) return false;
    const is = struct {
        fn op(i: Inst, g: vm.Group, v: anytype) bool {
            return i.group == @backingInt(g) and i.variant == @backingInt(v);
        }
    }.op;
    return is(inst, .jump, vm.Jump.jmp) or is(inst, .call, vm.Call.@"return") or is(inst, .call, vm.Call.return_nil) or
        is(inst, .ctrl, vm.CtrlOp.throw_) or is(inst, .ctrl, vm.CtrlOp.try_exit) or is(inst, .ctrl, vm.CtrlOp.finally_exit);
}

// =============================================================================
// Locals clearing (COMPILER.md §4.9)
// =============================================================================

/// Where a `try` form's code lies, beside its `vm.Try`: the pc of its
/// `ctrl:try-enter`, and `end`, the pc its exits continue at, past
/// its handler and its finally.
const TryExtent = struct { enter: u32, end: u32 };

/// The slots one instruction reads and the one it writes, by the
/// operand roles `Routine.verify` proves (`effectsOf`).
const Effects = struct {
    def: ?u12 = null,
    uses: [3]u12 = undefined,
    n_uses: u8 = 0,
    /// A call or collection block, or a lookup's two slots.
    block_lo: u32 = 0,
    block_len: u32 = 0,
    /// The cells a `closure:make` reads.
    sources: []const vm.CaptureSource = &.{},

    fn use(fx: *Effects, slot: u12) void {
        fx.uses[fx.n_uses] = slot;
        fx.n_uses += 1;
    }

    /// `live`, the slots live after the instruction, made the slots
    /// live before it.
    fn backward(fx: *const Effects, live: []u64) void {
        if (fx.def) |d| bitClear(live, d);
        fx.reads(live);
    }

    /// Add every slot the instruction reads to `set`.
    fn reads(fx: *const Effects, set: []u64) void {
        for (fx.uses[0..fx.n_uses]) |u| bitSet(set, u);
        for (fx.block_lo..fx.block_lo + fx.block_len) |s| bitSet(set, s);
        for (fx.sources) |s| switch (s) {
            .local_cell_slot => |c| bitSet(set, c),
            .inherited_upvalue => {},
        };
    }

    /// Whether the instruction reads a slot in `set`.
    fn readsAny(fx: *const Effects, set: []const u64) bool {
        for (fx.uses[0..fx.n_uses]) |u| if (bitHas(set, u)) return true;
        for (fx.block_lo..fx.block_lo + fx.block_len) |s| if (bitHas(set, s)) return true;
        for (fx.sources) |s| switch (s) {
            .local_cell_slot => |c| if (bitHas(set, c)) return true,
            .inherited_upvalue => {},
        };
        return false;
    }
};

fn bitSet(set: []u64, i: usize) void {
    set[i >> 6] |= @as(u64, 1) << @as(u6, @truncate(i));
}

fn bitClear(set: []u64, i: usize) void {
    set[i >> 6] &= ~(@as(u64, 1) << @as(u6, @truncate(i)));
}

fn bitHas(set: []const u64, i: usize) bool {
    return set[i >> 6] & (@as(u64, 1) << @as(u6, @truncate(i))) != 0;
}

fn bitOr(dst: []u64, src: []const u64) void {
    for (dst, src) |*d, s| d.* |= s;
}

/// The slots `inst` reads and writes, or null for an operand the
/// analysis cannot place inside the frame, which leaves the routine
/// as it is. A slot read as such is a read, but for the cell
/// `closure:new-cell` writes, the one `closure:box-local` reads and
/// writes, and a `try`'s binding slot, which the VM writes only as it
/// takes a throw (the edge to the handler, `clearDeadMoves`).
fn effectsOf(inst: Inst, caps: []const vm.CaptureDescriptor, slot_count: u16) ?Effects {
    var fx: Effects = .{};
    if (inst.kind != .primary) return null;
    const shape = Routine.shapeOf(vm.VM.opIndex(inst)) orelse return fx;
    const group = inst.groupOf();
    const is = struct {
        fn op(i: Inst, g: vm.Group, v: anytype) bool {
            return i.group == @backingInt(g) and i.variant == @backingInt(v);
        }
    }.op;
    const wide = shape.wide != null;
    const operands = [3]Operand{ inst.a, inst.b, inst.c };
    const roles = [3]Routine.Role{ shape.a, if (wide) .none else shape.b, if (wide) .none else shape.c };
    for (operands, roles, 0..) |op, role, i| switch (role) {
        .dst => {
            if (op.kind != .slot) return null;
            fx.def = op.index;
        },
        .src => if (op.kind == .slot) fx.use(op.index),
        .slot => {
            if (op.kind != .slot) return null;
            if (shape.block and i == 0) {
                fx.block_lo = op.index;
                fx.block_len = @as(u32, inst.b.index) + @intFromBool(is(inst, .call, vm.Call.call));
            } else if (shape.pair and i == 1) {
                fx.block_lo = op.index;
                fx.block_len = 2;
            } else if (is(inst, .closure, vm.Closure_.new_cell)) {
                fx.def = op.index;
            } else if (is(inst, .closure, vm.Closure_.box_local)) {
                fx.def = op.index;
                fx.use(op.index);
            } else if (group != .ctrl) {
                fx.use(op.index);
            }
        },
        .none, .raw, .key, .fixnum, .upvalue => {},
    };
    if (shape.wide == .capture) {
        const w = inst.wide();
        if (w >= caps.len) return null;
        fx.sources = caps[w].sources;
    }
    if (fx.def) |d| if (d >= slot_count) return null;
    for (fx.uses[0..fx.n_uses]) |u| if (u >= slot_count) return null;
    if (fx.block_lo + fx.block_len > slot_count) return null;
    for (fx.sources) |s| switch (s) {
        .local_cell_slot => |c| if (c >= slot_count) return null,
        .inherited_upvalue => {},
    };
    return fx;
}

/// The most words of sets, the words a set of the routine's slots
/// takes times its blocks and the blocks' regions, and the most
/// passes, that `clearDeadMoves` spends on a routine before it leaves
/// the routine as it is.
const clear_budget_words = 1 << 20;
const clear_max_passes = 64;

/// The basic blocks of a routine's code and the edges between them,
/// normal and exceptional (COMPILER.md §4.9).
const Flow = struct {
    /// Each block's first pc, and `code.len` after the last.
    starts: []u32,
    /// The block each pc lies in, `code.len` mapping past the last.
    block_of: []u32,
    /// Up to two successors a block, `none` for no more.
    succ: [][2]u32,
    /// The `try` regions each block lies in: `refs[ref_start[b]..ref_start[b + 1]]`.
    ref_start: []u32,
    refs: []Region,

    const none = std.math.maxInt(u32);
    /// A try's body, whose throws its handler takes, or its handler
    /// when it has a finally, which then runs on a throw.
    const Region = struct { t: u32, handler: bool };

    fn blocks(f: *const Flow) usize {
        return f.starts.len - 1;
    }

    /// The flow graph, or null for code the analysis does not model or
    /// whose sets of `words` words would pass the budget.
    fn build(arena: std.mem.Allocator, code: []const Inst, tries: []const vm.Try, extents: []const TryExtent, words: usize) error{OutOfMemory}!?Flow {
        const n = code.len;
        const is = struct {
            fn op(i: Inst, g: vm.Group, v: anytype) bool {
                return i.group == @backingInt(g) and i.variant == @backingInt(v);
            }
        }.op;
        const leader = try arena.alloc(bool, n + 1);
        @memset(leader, false);
        leader[0] = true;
        leader[n] = true;
        for (code, 0..) |inst, pc| {
            const jumps = inst.groupOf() == .jump or is(inst, .ctrl, vm.CtrlOp.try_exit);
            if (jumps) {
                if (inst.wide() >= n) return null;
                leader[inst.wide()] = true;
            }
            if (jumps or transfersAway(inst)) leader[pc + 1] = true;
        }
        if (tries.len != extents.len) return null;
        // The innermost try whose exits continue at each pc.
        const exit_try = try arena.alloc(u32, n + 1);
        @memset(exit_try, none);
        for (tries, extents, 0..) |t, x, i| {
            const fin = t.finally_pc orelse t.catch_pc;
            if (!(x.enter < t.catch_pc and t.catch_pc <= fin and fin < x.end and x.end <= n)) return null;
            if (!is(code[x.enter], .ctrl, vm.CtrlOp.try_enter) or code[x.enter].wide() != i) return null;
            leader[x.enter + 1] = true;
            leader[t.catch_pc] = true;
            leader[fin] = true;
            leader[x.end] = true;
            if (exit_try[x.end] == none or extents[exit_try[x.end]].enter < x.enter) exit_try[x.end] = @intCast(i);
        }

        var count: usize = 0;
        for (leader[0..n]) |l| count += @intFromBool(l);
        if (count * words > clear_budget_words) return null;
        const starts = try arena.alloc(u32, count + 1);
        const block_of = try arena.alloc(u32, n + 1);
        var b: u32 = 0;
        for (0..n) |pc| {
            if (leader[pc]) {
                starts[b] = @intCast(pc);
                b += 1;
            }
            block_of[pc] = b - 1;
        }
        starts[count] = @intCast(n);
        block_of[n] = @intCast(count);

        const succ = try arena.alloc([2]u32, count);
        for (succ, 0..) |*s, blk| {
            s.* = .{ none, none };
            const last = starts[blk + 1] - 1;
            const inst = code[last];
            const next: u32 = if (last + 1 < n) block_of[last + 1] else none;
            if (inst.groupOf() == .jump) {
                s[0] = block_of[inst.wide()];
                if (!is(inst, .jump, vm.Jump.jmp)) s[1] = next;
            } else if (is(inst, .ctrl, vm.CtrlOp.try_exit)) {
                // The exit of the try ending where it jumps, from its
                // body or its handler.
                const i = exit_try[inst.wide()];
                if (i == none or last <= extents[i].enter or last >= (tries[i].finally_pc orelse extents[i].end)) return null;
                s[0] = block_of[tries[i].finally_pc orelse extents[i].end];
            } else if (is(inst, .ctrl, vm.CtrlOp.finally_exit)) {
                // The last instruction of a finally, which goes on
                // past its try; a throw it resumes is its enclosing
                // region's.
                const i = exit_try[last + 1];
                if (i == none or tries[i].finally_pc == null or next == none) return null;
                s[0] = next;
            } else if (!transfersAway(inst)) {
                if (next == none) return null;
                s[0] = next;
            }
        }

        // Each block's count of regions, from where each region's
        // blocks start and end; then where each block's refs start.
        const depth = try arena.alloc(i64, count + 1);
        @memset(depth, 0);
        for (tries, extents) |t, x| {
            depth[block_of[x.enter + 1]] += 1;
            depth[block_of[t.catch_pc]] -= 1;
            if (t.finally_pc) |f| {
                depth[block_of[t.catch_pc]] += 1;
                depth[block_of[f]] -= 1;
            }
        }
        const ref_start = try arena.alloc(u32, count + 1);
        ref_start[0] = 0;
        var d: i64 = 0;
        var total: usize = 0;
        for (0..count) |blk| {
            d += depth[blk];
            total += @intCast(d);
            if ((count + total) * words > clear_budget_words) return null;
            ref_start[blk + 1] = @intCast(total);
        }
        const refs = try arena.alloc(Region, ref_start[count]);
        const fill = try arena.dupe(u32, ref_start[0..count]);
        for (tries, extents, 0..) |t, x, i| {
            for (block_of[x.enter + 1]..block_of[t.catch_pc]) |blk| {
                refs[fill[blk]] = .{ .t = @intCast(i), .handler = false };
                fill[blk] += 1;
            }
            if (t.finally_pc) |f| for (block_of[t.catch_pc]..block_of[f]) |blk| {
                refs[fill[blk]] = .{ .t = @intCast(i), .handler = true };
                fill[blk] += 1;
            };
        }
        return .{ .starts = starts, .block_of = block_of, .succ = succ, .ref_start = ref_start, .refs = refs };
    }

    fn regions(f: *const Flow, b: usize) []const Region {
        return f.refs[f.ref_start[b]..f.ref_start[b + 1]];
    }
};

/// Rewrite each `mov:move` of a slot no instruction reads before the
/// slot is written again, on any path, into `mov:move-clear`, so the
/// slot stops rooting what it held (COMPILER.md §4.9). The code is the
/// Emitter's, every jump patched and nothing quickened; only variants
/// change. Liveness is over slots, backward to a fixed point, with
/// every slot a `try`'s handler or finally reads live throughout what
/// can throw to it. Returns whether the analysis ran: false leaves the
/// code as it is, for a routine past the budget or one holding what
/// the analysis does not model.
fn clearDeadMoves(
    gpa: std.mem.Allocator,
    code: []Inst,
    slot_count: u16,
    caps: []const vm.CaptureDescriptor,
    tries: []const vm.Try,
    extents: []const TryExtent,
) CompileError!bool {
    const words = (@as(usize, slot_count) + 63) / 64;
    if (code.len == 0 or words == 0) return false;
    // Many routines have no move to clear; most of the rest fit the
    // stack buffer, the sets of a larger one going to an arena, all
    // freed together.
    for (code) |inst| {
        if (isSlotMove(inst)) break;
    } else return true;
    var overflow = std.heap.ArenaAllocator.init(gpa);
    defer overflow.deinit();
    var buffer: [8192]u8 align(16) = undefined;
    var first = std.heap.BufferFirstAllocator.init(&buffer, overflow.allocator());
    const arena = first.allocator();
    const effects = try arena.alloc(Effects, code.len);
    for (code, effects) |inst, *fx| fx.* = effectsOf(inst, caps, slot_count) orelse return false;
    const flow = (try Flow.build(arena, code, tries, extents, words)) orelse return false;
    const nb = flow.blocks();

    // Each block's upward-exposed reads and its writes.
    const use = try arena.alloc(u64, nb * words);
    const def = try arena.alloc(u64, nb * words);
    const live_in = try arena.alloc(u64, nb * words);
    @memset(use, 0);
    @memset(def, 0);
    @memset(live_in, 0);
    for (0..nb) |b| {
        const u = use[b * words ..][0..words];
        var pc = flow.starts[b + 1];
        while (pc > flow.starts[b]) {
            pc -= 1;
            effects[pc].backward(u);
            if (effects[pc].def) |d| bitSet(def[b * words ..][0..words], d);
        }
    }

    // What a throw from a try's body, or from its handler when it has
    // a finally, finds live where it lands: the handler's entry but its
    // binding slot, which the throw writes, and the finally's entry.
    const h_body = try arena.alloc(u64, tries.len * words);
    const h_handler = try arena.alloc(u64, tries.len * words);
    const out = try arena.alloc(u64, words);
    const at = struct {
        fn set(sets: []u64, i: usize, w: usize) []u64 {
            return sets[i * w ..][0..w];
        }
    }.set;
    var passes: usize = 0;
    while (true) : (passes += 1) {
        if (passes == clear_max_passes) return false;
        for (tries, extents, 0..) |t, x, i| {
            const hb = at(h_body, i, words);
            const hh = at(h_handler, i, words);
            @memcpy(hb, at(live_in, flow.block_of[t.catch_pc], words));
            bitClear(hb, code[x.enter].a.index);
            @memset(hh, 0);
            if (t.finally_pc) |f| {
                @memcpy(hh, at(live_in, flow.block_of[f], words));
                bitOr(hb, hh);
            }
        }
        var changed = false;
        var b = nb;
        while (b > 0) {
            b -= 1;
            @memset(out, 0);
            for (flow.succ[b]) |s| if (s != Flow.none) bitOr(out, at(live_in, s, words));
            for (out, at(use, b, words), at(def, b, words)) |*o, u, d| o.* = u | (o.* & ~d);
            for (flow.regions(b)) |r| bitOr(out, at(if (r.handler) h_handler else h_body, r.t, words));
            const in = at(live_in, b, words);
            if (!std.mem.eql(u64, in, out)) {
                @memcpy(in, out);
                changed = true;
            }
        }
        if (!changed) break;
    }

    // A slot is live after an instruction when the walk back from the
    // block's successors finds it, or the block's regions hold it.
    const live = try arena.alloc(u64, words);
    const held = try arena.alloc(u64, words);
    var cleared = false;
    for (0..nb) |b| {
        @memset(live, 0);
        @memset(held, 0);
        for (flow.succ[b]) |s| if (s != Flow.none) bitOr(live, at(live_in, s, words));
        for (flow.regions(b)) |r| bitOr(held, at(if (r.handler) h_handler else h_body, r.t, words));
        var pc = flow.starts[b + 1];
        while (pc > flow.starts[b]) {
            pc -= 1;
            const inst = &code[pc];
            if (isSlotMove(inst.*) and !bitHas(live, inst.b.index) and !bitHas(held, inst.b.index)) {
                inst.variant = @backingInt(vm.Mov.move_clear);
                cleared = true;
            }
            effects[pc].backward(live);
        }
    }
    if (std.debug.runtime_safety and cleared) try checkClears(arena, code, effects, &flow, tries, extents, words);
    return true;
}

/// Whether `inst` is a `mov:move` of one slot to another, which
/// clears its source where the source is dead after it.
fn isSlotMove(inst: Inst) bool {
    return inst.group == @backingInt(vm.Group.mov) and inst.variant == @backingInt(vm.Mov.move) and
        inst.b.kind == .slot and inst.a.kind == .slot and inst.b.index != inst.a.index;
}

/// The check that no instruction reads a slot a `mov:move-clear`
/// cleared on some path to it with no write since: forward over the
/// rewritten code, with a throw from a try's body or handler carrying
/// what it cleared to where the throw lands. A read of one is the
/// analysis' bug, `InternalCompilerBug` at compile time rather than a
/// nil read at run time. Debug and safe builds run it on every routine
/// they clear in.
fn checkClears(
    arena: std.mem.Allocator,
    code: []const Inst,
    effects: []const Effects,
    flow: *const Flow,
    tries: []const vm.Try,
    extents: []const TryExtent,
    words: usize,
) CompileError!void {
    const nb = flow.blocks();
    const in = try arena.alloc(u64, nb * words);
    const seen = try arena.alloc(u64, nb * words);
    const thrown = try arena.alloc(u64, 2 * tries.len * words);
    const state = try arena.alloc(u64, words);
    @memset(in, 0);
    @memset(seen, 0);
    const at = struct {
        fn set(sets: []u64, i: usize, w: usize) []u64 {
            return sets[i * w ..][0..w];
        }
    }.set;
    var changed = true;
    while (changed) {
        changed = false;
        // What a throw from each try's body (2t) and handler (2t + 1)
        // carries.
        @memset(thrown, 0);
        for (0..nb) |b| for (flow.regions(b)) |r| {
            bitOr(at(thrown, 2 * r.t + @intFromBool(r.handler), words), at(seen, b, words));
        };
        for (tries, extents, 0..) |t, x, i| {
            const body = at(thrown, 2 * i, words);
            bitClear(body, code[x.enter].a.index);
            changed = orChanged(at(in, flow.block_of[t.catch_pc], words), body) or changed;
            if (t.finally_pc) |f| changed = orChanged(at(in, flow.block_of[f], words), at(thrown, 2 * i + 1, words)) or changed;
        }
        for (0..nb) |b| {
            @memcpy(state, at(in, b, words));
            const s = at(seen, b, words);
            changed = orChanged(s, state) or changed;
            for (flow.starts[b]..flow.starts[b + 1]) |pc| {
                const fx = &effects[pc];
                if (fx.readsAny(state)) return CompileError.InternalCompilerBug;
                const inst = code[pc];
                if (inst.group == @backingInt(vm.Group.mov) and inst.variant == @backingInt(vm.Mov.move_clear)) bitSet(state, inst.b.index);
                if (fx.def) |d| bitClear(state, d);
                changed = orChanged(s, state) or changed;
            }
            for (flow.succ[b]) |succ| if (succ != Flow.none) {
                changed = orChanged(at(in, succ, words), state) or changed;
            };
        }
    }
}

/// `dst |= src`, and whether that added anything.
fn orChanged(dst: []u64, src: []const u64) bool {
    var added: u64 = 0;
    for (dst, src) |*d, x| {
        added |= x & ~d.*;
        d.* |= x;
    }
    return added != 0;
}

// =============================================================================
// Public API
// =============================================================================

/// Compile a `Tiny` tree built by hand: no namespace (every symbol
/// must be lexical) and no span table. Source and Form callers use
/// `compileSourceWith` / `compileFormWith`.
fn compileTiny(allocator: std.mem.Allocator, form: *const Tiny) CompileError!Compiled {
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
    clear_locals: bool = true,
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
    emitter.clear_locals = opts.clear_locals;
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
// captures (`Lexical`).
//
// Lowering covers literals, symbols, list dispatch (ordinary calls,
// special forms, the inlined core fns when not shadowed),
// binding/fn forms (let*, fn*, letfn*, loop*, recur), var forms
// (def, var), try/throw, quote, and collection literals. The
// lexical bindings in force (`LowerCtx.lexicals`) decide shadowing
// for intrinsic dispatch.

/// Allocate and initialize a Tiny node on the given allocator.
/// Used by `lowerForm` to build the IR tree. The arena passed to
/// `compileFormWith` / `compileSourceWith` owns these allocations. Every node
/// is a `TinyNode` so `lowerForm` can attach the Form's span.
fn allocTiny(allocator: std.mem.Allocator, value: Tiny) CompileError!*Tiny {
    const node = try allocator.create(TinyNode);
    node.* = .{ .tiny = value };
    return &node.tiny;
}

/// What every `lower*` helper is given, copied by value at each
/// level: the lexical bindings in force, the interner and heap that
/// constants are made with, and how names that are not lexical
/// resolve.
const LowerCtx = struct {
    lexicals: *ScopeTable(Lexical),
    interner: ?*intern_mod.Interner = null,
    /// The heap string, bignum and collection constants are built
    /// on, where the routine's constant pool keeps them alive; null
    /// makes them `UnsupportedFeature`.
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

    /// Bring `name` into scope at this context's `fn*` depth, its
    /// captures recorded in `captured` and, for a `let*` or `loop*`
    /// binding, its reads counted in `refs`.
    fn bind(self: LowerCtx, allocator: std.mem.Allocator, name: []const u8, captured: *bool, refs: ?*u32) CompileError!void {
        try self.lexicals.bind(allocator, name, .{ .captured = captured, .refs = refs, .fn_depth = self.fn_depth });
    }

    /// The context of a `fn*` body.
    fn inFnBody(self: LowerCtx) LowerCtx {
        var copy = self;
        copy.fn_depth += 1;
        return copy;
    }
};

/// Where lowering failed, when it can say more precisely than
/// "somewhere in this top-level form".
const LowerDiag = struct {
    span: ?reader_mod.SrcSpan = null,
    /// Why, when a routine limit was reached: the routine and the
    /// limit, on the compile allocator.
    detail: ?[]const u8 = null,
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
    /// `defn`, `defn-`, `defonce`, `defmacro`, `defrecord` (the type id, `->T`,
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
        if (items.len < 2 or items[0].datum != .symbol or items[0].datum.symbol.ns != null) {
            for (items) |item| try self.declareForm(item);
            return;
        }
        const head = items[0].datum.symbol.name;
        // Quoted data defines nothing.
        if (std.mem.eql(u8, head, "quote")) return;
        for (items) |item| try self.declareForm(item);
        // `^meta` on the name wraps it in with_meta.
        const name_form = if (items[1].datum == .with_meta) items[1].datum.with_meta.target else items[1];
        if (name_form.datum != .symbol or name_form.datum.symbol.ns != null) return;
        const name = name_form.datum.symbol.name;
        const plain = [_][]const u8{ "def", "defn", "defn-", "defonce", "defmacro" };
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

/// A binding lowering is inside of: one a `let*`, `loop*`, `fn*`
/// (parameters and self-name), `letfn*` or `catch` makes, mirroring
/// the Emitter's scope exactly. Lowering resolves each symbol against
/// them for two reasons: a lexical name is not a Var, so it shadows an
/// inlined core fn and the declared-name check (special forms stay
/// reserved: `(let* [if 1] (if true 2 3))` is still `if`); and a
/// reference from inside a `fn*` to a binding made outside it is a
/// capture, which sets the binding's `captured` flag in its Tiny node,
/// so the Emitter boxes it when it is bound (COMPILER.md §6.1).
const Lexical = struct {
    /// Where the binding's Tiny node records a capture.
    captured: *bool,
    /// Where a `let*` or `loop*` binding counts its readers.
    refs: ?*u32,
    /// The `fn*` nesting depth the binding is made at.
    fn_depth: u32,
    /// For a `fn*` self-name, the fixed arity of each clause without a
    /// rest parameter: a call of the name with that many arguments,
    /// directly in a body of the fn, is a self-call and no capture
    /// (COMPILER.md §5.5).
    self_arities: []const usize = &.{},
};

/// Whether `name` is lexically bound here; a binding made outside
/// the innermost `fn*` is marked captured.
fn resolveLexical(ctx: LowerCtx, name: []const u8) bool {
    const hit = ctx.lexicals.lookup(name) orelse return false;
    if (hit.fn_depth < ctx.fn_depth) hit.captured.* = true;
    if (hit.refs) |n| n.* += 1;
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
/// prefix is a namespace name (`expand.canonicalNs`). Null when
/// nothing is registered under it.
fn qualifiedTarget(ns: *const vm.Namespace, ns_prefix: []const u8) ?*vm.Namespace {
    const registry = ns.registry orelse return null;
    return registry.lookupNs(expand_mod.canonicalNs(ns.lookupAlias(ns_prefix) orelse ns_prefix));
}

/// Whether a bare operator `name` means `nexis.core`'s Var of that
/// name, so its call may be inlined (COMPILER.md §4.3 rule 2): not a
/// lexical binding, not a Var the namespace defines or refers to
/// instead, and not a name this file or line defines outside
/// `nexis.core` (a definition earlier in the same form interns its
/// Var only when the form is emitted). Without a namespace registry
/// there is nothing to shadow it.
fn namesCore(ctx: LowerCtx, name: []const u8) bool {
    if (ctx.lexicals.lookup(name) != null) return false;
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

/// `UnresolvedSymbol` for `ns/name` (or `name`), located at `span`
/// and saying which symbol (COMPILER.md §7).
fn unresolved(allocator: std.mem.Allocator, diag: ?*LowerDiag, span: ?reader_mod.SrcSpan, ns: ?[]const u8, name: []const u8) CompileError {
    const d = diag orelse return CompileError.UnresolvedSymbol;
    if (span) |sp| d.span = sp;
    if (d.detail == null) {
        // A Clojure name nexis lacks says what to use instead.
        const hint = expand_mod.idiomHint(allocator, ns, name) catch return CompileError.OutOfMemory;
        const sep: []const u8 = if (hint != null) "; " else "";
        d.detail = (if (ns) |n|
            allocator.print("unable to resolve symbol: {s}/{s}{s}{s}", .{ n, name, sep, hint orelse "" })
        else
            allocator.print("unable to resolve symbol: {s}{s}{s}", .{ name, sep, hint orelse "" })) catch return CompileError.OutOfMemory;
    }
    return CompileError.UnresolvedSymbol;
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
                        if (qualifiedTarget(ns, ns_prefix) == ns and ns.lookupLocal(name.name) == null and !declared.contains(name.name))
                            return unresolved(allocator, ctx.diag, form.origin, ns_prefix, name.name);
                    }
                }
                break :blk try allocTiny(allocator, .{ .qualified_symbol = .{ .ns = ns_prefix, .name = name.name } });
            }
            if (!resolveLexical(ctx, name.name)) {
                if (ctx.declared) |declared| {
                    if (!symbolResolves(ctx, declared, name.name))
                        return unresolved(allocator, ctx.diag, form.origin, null, name.name);
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
        // A regex literal is a pattern constant of the routine, as a
        // string is, so each evaluation of one `#"..."` gives the same
        // pattern, as Clojure's constant does (docs/REGEX.md §10).
        .regex => |text| blk: {
            const h = ctx.heap orelse return CompileError.UnsupportedFeature;
            const made = regex_mod.make(h, allocator, text) catch |err| return switch (err) {
                error.OutOfMemory => CompileError.OutOfMemory,
                error.StackOverflow => CompileError.StackOverflow,
            };
            break :blk try allocTiny(allocator, .{ .literal = switch (made) {
                .ok => |p| p,
                .err => return CompileError.MalformedForm,
            } });
        },
        // `{k1 v1 ...}`, `#{a b}` and `[a b]` as expressions: each
        // item is an expression, evaluated left to right.
        .map => |items| try lowerColl(allocator, .map, items, ctx),
        .set => |items| try lowerColl(allocator, .set, items, ctx),
        .vector => |items| try lowerColl(allocator, .vector, items, ctx),
        // Reader macros / meta.
        .quote => |inner| try lowerQuoted(allocator, inner, ctx),
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
// core fns are checked against the lexical bindings: if the name
// is lexically shadowed, fall through to ordinary call lowering.
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
    if (items.len == 0) return try lowerColl(allocator, .list, &.{}, ctx);
    // Head-symbol dispatch only fires when head is an unqualified
    // symbol. Qualified symbols (`foo/x`) and non-symbol heads
    // (calls of computed values) fall through to ordinary call.
    if (items[0].datum == .symbol and items[0].datum.symbol.ns == null) {
        const name = items[0].datum.symbol.name;
        // Special forms are reserved: no binding shadows them.
        if (lowerings.get(name)) |lower| return lower(allocator, items[1..], ctx);
        if (ctx.lexicals.lookup(name)) |hit| if (std.mem.findScalar(usize, hit.self_arities, items.len - 1) != null and hit.fn_depth + 1 == ctx.fn_depth) {
            const args = try allocator.alloc(*const Tiny, items.len - 1);
            for (items[1..], args) |item, *arg| arg.* = try lowerForm(allocator, item, ctx);
            return try allocTiny(allocator, .{ .self_call = args });
        };
        // -- Inlineable core fns (shadowable) --
        if (inlinedOp(name, items.len - 1)) |in| {
            if (namesCore(ctx, name)) return try lowerPrim(allocator, in, items[1..], ctx);
        }
        if (items.len == 2 and std.mem.eql(u8, name, "not") and namesCore(ctx, name)) return try lowerNot(allocator, items[1], ctx);
    } else if (items[0].datum == .symbol and std.mem.eql(u8, expand_mod.canonicalNs(items[0].datum.symbol.ns.?), "nexis.core")) {
        // A qualified head is never a lexical local, so `nexis.core/+`
        // inlines unconditionally. Host macros emit these
        // (MACROEXPAND.md §5).
        const name = items[0].datum.symbol.name;
        if (inlinedOp(name, items.len - 1)) |in| return try lowerPrim(allocator, in, items[1..], ctx);
        if (items.len == 2 and std.mem.eql(u8, name, "not")) return try lowerNot(allocator, items[1], ctx);
    }
    // Ordinary call: lower head as callee, rest as args.
    return try lowerCall(allocator, items, ctx);
}

/// How each special form lowers: the expander's `special_forms`
/// (MACROEXPAND.md §1.1), less the four it rewrites away (`ns`,
/// `require`, `defmacro`, `set!`), and the `#%` collection
/// constructors syntax-quote emits.
const lowerings = std.StaticStringMap(*const fn (std.mem.Allocator, []const *reader_mod.Form, LowerCtx) CompileError!*Tiny).initComptime(.{
    .{ "do", &lowerBody },
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
            return lowerColl(allocator, op, args, ctx);
        }
    }.lower;
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

/// `(not x)` as `(if x false true)`, which is what `nexis.core/not`
/// computes: an `if` testing it branches on `x` (§4.3 rule 2).
fn lowerNot(allocator: std.mem.Allocator, arg: *const reader_mod.Form, ctx: LowerCtx) CompileError!*Tiny {
    return try allocTiny(allocator, .{ .if_ = .{
        .test_ = try lowerForm(allocator, arg, ctx),
        .then = try allocTiny(allocator, .{ .bool = false }),
        .else_ = try allocTiny(allocator, .{ .bool = true }),
    } });
}

fn lowerQuote(
    allocator: std.mem.Allocator,
    args: []const *reader_mod.Form,
    ctx: LowerCtx,
) CompileError!*Tiny {
    if (args.len != 1) return CompileError.MalformedForm;
    return lowerQuoted(allocator, args[0], ctx);
}

/// A `Tiny.coll` of `op` over `forms`, each lowered as an expression.
fn lowerColl(
    allocator: std.mem.Allocator,
    op: vm.CollOp,
    forms: []const *reader_mod.Form,
    ctx: LowerCtx,
) CompileError!*Tiny {
    if (op == .map and forms.len % 2 != 0) return CompileError.MalformedForm;
    const items = try allocator.alloc(*const Tiny, forms.len);
    for (forms, items) |form, *item| item.* = try lowerForm(allocator, form, ctx);
    if (try constantColl(allocator, op, items, ctx)) |v| return try allocTiny(allocator, .{ .literal = v });
    return try allocTiny(allocator, .{ .coll = .{ .op = op, .items = items } });
}

/// The collection `items` build, made now when every item is a
/// constant (COMPILER.md §4.4): the literal is then one constant, however
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
    for (items, values) |item, *v| v.* = try constValue(item) orelse return null;
    return buildColl(heap, op, values) catch CompileError.OutOfMemory;
}

/// The constant `t` is, if it is one.
fn constValue(t: *const Tiny) CompileError!?Value {
    return switch (t.*) {
        .nil => value_mod.nilValue(),
        .bool => |b| value_mod.fromBool(b),
        .int => |n| value_mod.fromFixnum(n) orelse CompileError.IntegerOutOfFixnumRange,
        .literal => |v| v,
        else => null,
    };
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

/// `(quote x)` and `'x`: `x` as data. A self-evaluating scalar lowers
/// as itself and a symbol as the interned symbol; anything else is
/// one constant, the value `expand.formToValue` makes of it, exactly
/// what a macro receives as an argument (MACROEXPAND.md §1.2): `'x`
/// inside it is `(quote x)`, `@x` is `(nexis.core/deref x)`, `#()` the
/// `fn*` form it stands for, `^m coll` the collection carrying `m`,
/// and the marker list a sorted collection travels as the collection
/// itself. It is built on the lowering heap, so a quoted compound
/// without one, and a syntax-quote or unquote inside, is
/// `UnsupportedFeature`.
fn lowerQuoted(allocator: std.mem.Allocator, payload: *const reader_mod.Form, ctx: LowerCtx) CompileError!*Tiny {
    try stack.check();
    switch (payload.datum) {
        .nil, .bool_, .int, .bigint, .real, .char, .string, .regex, .keyword => return lowerDatum(allocator, payload, ctx),
        .symbol => |name| {
            const interner = ctx.interner orelse return CompileError.UnsupportedFeature;
            const v = interner.internQualifiedSymbol(name.ns, name.name) catch return CompileError.OutOfMemory;
            return allocTiny(allocator, .{ .literal = v });
        },
        else => {},
    }
    var expander = expand_mod.ExpandContext{
        .allocator = allocator,
        .interner = ctx.interner orelse return CompileError.UnsupportedFeature,
        .host_macros = &no_macros,
        .value_heap = ctx.heap orelse return CompileError.UnsupportedFeature,
    };
    const v = expand_mod.formToValue(&expander, payload) catch |err| return switch (err) {
        error.OutOfMemory => CompileError.OutOfMemory,
        error.ExpansionDepthExceeded => CompileError.StackOverflow,
        else => CompileError.UnsupportedFeature,
    };
    return allocTiny(allocator, .{ .literal = v });
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
        const fits = in.argc == argc or (in.fold and argc > in.argc);
        if (fits and std.mem.eql(u8, in.name, name)) return in;
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
    else if (args.len >= 2)
        try lowerForm(allocator, args[1], ctx)
    else
        null;
    const more = try allocator.alloc(*const Tiny, if (args.len > 2) args.len - 2 else 0);
    for (more, 2..) |*m, i| m.* = try lowerForm(allocator, args[i], ctx);
    return try allocTiny(allocator, .{ .prim = .{ .op = in.op, .lhs = lhs, .rhs = rhs, .more = more } });
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
    if (callee.* == .literal and (args.len == 1 or args.len == 2)) switch (callee.literal.kind()) {
        .keyword, .symbol => return try allocTiny(allocator, .{ .lookup = .{ .key = callee, .args = args } }),
        else => {},
    };
    return try allocTiny(allocator, .{ .call = .{ .callee = callee, .args = args } });
}

// =============================================================================
// Form binding-form lowering
// =============================================================================
//
// `let*`, `fn*`, `letfn*`, `loop*`, `recur`. Each binding form
// lowers its body with its names bound in `LowerCtx.lexicals`, which
// mirrors the Emitter's scope (see `Lexical`).

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
    const mark = ctx.lexicals.mark();
    defer ctx.lexicals.restore(mark);
    for (bindings, 0..) |*b, i| {
        b.* = .{
            .name = try expectUnqualifiedSymbol(binding_vec[i * 2]),
            .value = try lowerForm(allocator, binding_vec[i * 2 + 1], ctx),
        };
        try ctx.bind(allocator, b.name, &b.captured, &b.refs);
    }
    return .{ .bindings = bindings, .body = try lowerBody(allocator, args[1..], ctx) };
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

/// `(fn* name? [params... & rest?] body...)` or `(fn* name? ([params...
/// & rest?] body...)+)`. Optional self-name detected by checking
/// whether the FIRST arg after `fn*` is a symbol (vs the parameter
/// vector or the first clause).
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
    const parsed = try parseClauses(allocator, args[pos..]);

    // The self-name belongs to the enclosing scope, so the bodies'
    // references to it are captures of a placeholder cell.
    var self_referenced = false;
    const mark = ctx.lexicals.mark();
    defer ctx.lexicals.restore(mark);
    if (self_name) |n| try ctx.lexicals.bind(allocator, n, .{
        .captured = &self_referenced,
        .refs = null,
        .fn_depth = ctx.fn_depth,
        .self_arities = try selfArities(allocator, parsed),
    });
    return try allocTiny(allocator, .{ .fn_star = .{
        .name = self_name,
        .clauses = try lowerClauses(allocator, parsed, ctx),
        .self_referenced = self_referenced,
    } });
}

/// One arity of a `fn*` as read: its parameters and its body forms.
const ParsedClause = struct {
    params: ParsedParams,
    body: []const *reader_mod.Form,
};

/// What follows a `fn*`'s name, or a `letfn*` entry's: a parameter
/// vector and a body, or one or more clauses `([params...] body...)`.
/// The clauses keep Clojure's rules (COMPILER.md §5.5): no two take
/// the same fixed count, at most one has a rest parameter, and its
/// fixed count is at least every other clause's.
fn parseClauses(allocator: std.mem.Allocator, forms: []const *reader_mod.Form) CompileError![]const ParsedClause {
    if (forms.len == 0) return CompileError.ExpectedVector;
    if (forms[0].datum != .list) {
        const one = try allocator.alloc(ParsedClause, 1);
        one[0] = .{ .params = try parseParams(allocator, try expectVector(forms[0])), .body = forms[1..] };
        return one;
    }
    const clauses = try allocator.alloc(ParsedClause, forms.len);
    var rest_fixed: ?usize = null;
    for (forms, clauses, 0..) |form, *c, i| {
        const items = switch (form.datum) {
            .list => |items| items,
            else => return CompileError.MalformedForm,
        };
        if (items.len == 0) return CompileError.MalformedForm;
        c.* = .{ .params = try parseParams(allocator, try expectVector(items[0])), .body = items[1..] };
        const fixed = c.params.params.len;
        if (c.params.rest_param != null) {
            if (rest_fixed != null) return CompileError.MalformedForm;
            rest_fixed = fixed;
        }
        for (clauses[0..i]) |before| {
            if (before.params.rest_param == null and c.params.rest_param == null and before.params.params.len == fixed) return CompileError.MalformedForm;
        }
    }
    if (rest_fixed) |r| for (clauses) |c| {
        if (c.params.rest_param == null and c.params.params.len > r) return CompileError.MalformedForm;
    };
    return clauses;
}

/// The fixed arities a self-call may name (COMPILER.md §5.5): every
/// clause's without a rest parameter, at most `chunk_items`, since a
/// longer block may need the chunked call, which needs the callee in
/// a slot.
fn selfArities(allocator: std.mem.Allocator, clauses: []const ParsedClause) CompileError![]const usize {
    var arities: std.ArrayList(usize) = .empty;
    for (clauses) |c| {
        if (c.params.rest_param == null and c.params.params.len <= chunk_items) try arities.append(allocator, c.params.params.len);
    }
    return arities.items;
}

/// Each clause's body over its parameters.
fn lowerClauses(allocator: std.mem.Allocator, parsed: []const ParsedClause, ctx: LowerCtx) CompileError![]const Clause {
    const clauses = try allocator.alloc(Clause, parsed.len);
    for (parsed, clauses) |p, *c| {
        const fn_body = try lowerFnBody(allocator, p.params, p.body, ctx);
        c.* = .{ .params = p.params.params, .rest_param = p.params.rest_param, .body = fn_body.body, .captured = fn_body.captured };
    }
    return clauses;
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
    const body_ctx = ctx.inFnBody();
    const mark = ctx.lexicals.mark();
    defer ctx.lexicals.restore(mark);
    for (params.params, 0..) |p, i| try body_ctx.bind(allocator, p, &captured[i], null);
    if (params.rest_param) |rp| try body_ctx.bind(allocator, rp, &captured[count - 1], null);
    return .{ .body = try lowerBody(allocator, body, body_ctx), .captured = captured };
}

/// `(letfn* [(name [params] body...) ...] body...)`. Each
/// binding entry is itself a list of (name param-vector body...), or
/// of (name clause...) with clauses as `fn*` takes them.
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
    const mark = ctx.lexicals.mark();
    defer ctx.lexicals.restore(mark);
    const parsed = try allocator.alloc([]const ParsedClause, binding_vec.len);
    for (binding_vec, 0..) |entry, i| {
        const entry_items = switch (entry.datum) {
            .list => |items| items,
            else => return CompileError.MalformedForm,
        };
        if (entry_items.len < 2) return CompileError.MalformedForm;
        const name = try expectUnqualifiedSymbol(entry_items[0]);
        parsed[i] = try parseClauses(allocator, entry_items[1..]);
        try ctx.bind(allocator, name, &names_captured, null);
        bindings[i] = .{ .name = name, .clauses = &.{} };
    }
    for (bindings, parsed) |*b, clauses| b.clauses = try lowerClauses(allocator, clauses, ctx);
    const body = try lowerBody(allocator, args[1..], ctx);
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
// A `def` binds no lexical name: a Var is not lexical.
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

/// `(var name)`: the Var itself, bound or not (COMPILER.md §5.9).
/// With `declared`, a name that resolves to no Var and that the file
/// does not define is `UnresolvedSymbol`; a local is no Var, as in
/// Clojure.
fn lowerVarRef(
    allocator: std.mem.Allocator,
    args: []const *reader_mod.Form,
    ctx: LowerCtx,
) CompileError!*Tiny {
    if (args.len != 1) return CompileError.MalformedForm;
    if (args[0].datum != .symbol) return CompileError.ExpectedSymbol;
    const sym = args[0].datum.symbol;
    if (ctx.declared) |declared| if (ctx.namespace) |ns| {
        const known = if (sym.ns) |prefix|
            qualifiedTarget(ns, prefix) != ns or ns.lookupLocal(sym.name) != null or declared.contains(sym.name)
        else
            symbolResolves(ctx, declared, sym.name);
        if (!known) return unresolved(allocator, ctx.diag, args[0].origin, sym.ns, sym.name);
    };
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

    // The handler sees the binding, in operator position too; the
    // finally does not.
    var binding_captured = false;
    const handler_body = blk: {
        const mark = ctx.lexicals.mark();
        defer ctx.lexicals.restore(mark);
        try ctx.bind(allocator, binding, &binding_captured, null);
        break :blk try lowerBody(allocator, handler_items, ctx);
    };

    // Lower the finally body if present. It sees
    // the OUTER lexical env (NOT the catch binding).
    var finally_tiny: ?*const Tiny = null;
    if (finally_form) |ff| {
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

/// What `compileEvalCallback` compiles a `defmacro`'s function with:
/// the options of the form the `defmacro` is in.
const CompileEvalData = struct {
    /// The enclosing form's compile allocator: the trees and the
    /// sub-VM's working storage.
    allocator: std.mem.Allocator,
    opts: CompileOptions,
};

/// The expander's compile-eval callback (`defmacro`): compile `form`,
/// the already-expanded `(def name (fn* ...))`, and run it on a fresh
/// sub-VM over the user VM's heap and registries (`docs/VM.md` §9.1).
/// The routines go to the persistent allocator, so the macro outlives
/// the form; the closure lands on the user VM's heap, where the Var
/// that roots it lives, and the sub-VM, which never collects, goes
/// once it has run. Without that heap the closure is the sub-VM's
/// own, which then stays.
fn compileEvalCallback(user_data: *anyopaque, form: *const reader_mod.Form, failure: *?expand_mod.Failure) anyerror!value_mod.Value {
    const data: *CompileEvalData = @ptrCast(@alignCast(user_data));
    const persistent = data.opts.persistent_allocator orelse data.allocator;
    var span: ?reader_mod.SrcSpan = null;
    var detail: ?[]const u8 = null;
    var opts = data.opts;
    opts.routine_allocator = persistent;
    opts.out_span = &span;
    opts.out_detail = &detail;
    const compiled = compileExpanded(data.allocator, form, opts) catch |err| {
        failure.* = .{ .span = span orelse form.origin, .message = detail orelse "" };
        return err;
    };
    const routine = try persistent.create(vm.Routine);
    routine.* = compiled.toRoutine("defmacro-eval");
    const heap = registryHeap(opts.namespace);
    var sub = try vm.VM.init(if (heap != null) data.allocator else persistent, routine);
    defer if (heap != null) sub.deinit();
    sub.borrowed_interner = opts.interner;
    sub.borrowed_heap = heap;
    sub.gc_enabled = false;
    if (opts.namespace) |n| if (n.registry) |r| if (r.vm) |owner| sub.borrowRegistries(owner);
    return sub.run();
}

/// The compiler as `macroexpand-1`, `read-string`, `eval` and
/// `load-string` reach it at run time (`vm.CompilerHooks`). The
/// runtime that boots a VM owns one of these for as long as the VM
/// lives and calls `install`.
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
            .load = &loadHook,
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
        // A form is data: its lazy seqs are realized and made lists.
        const form = expand_mod.valueToForm(&ctx, try seq_mod.asLists(v, form_value), origin) catch |err|
            return expansionFailure(v, &ctx, err);
        const expanded = expand_mod.expandOnce(&ctx, form) catch |err|
            return expansionFailure(v, &ctx, err);
        const out = expanded orelse return null;
        return expand_mod.formToValue(&ctx, out) catch |err|
            return expansionFailure(v, &ctx, err);
    }

    /// Out of memory stays an error; any other failure of `macroexpand-1`
    /// throws `:macro-expansion-failure`, its message the expander's
    /// sentence (what the macro threw, or why the form is malformed)
    /// when there is one, placed as a runtime error is (VM.md §13).
    fn expansionFailure(v: *vm.VM, ctx: *const expand_mod.ExpandContext, err: anyerror) vm.VmError {
        if (err == error.OutOfMemory) return vm.VmError.OutOfMemory;
        const tag = v.ensureInterner().internKeywordValue("macro-expansion-failure") catch return vm.VmError.OutOfMemory;
        return v.throwErrorMap(v.errorValue(tag, if (ctx.failure) |f| f.message else "", null));
    }

    /// The first form of `source`, as data; null when it holds none.
    fn readStringHook(user_data: *anyopaque, v: *vm.VM, source: []const u8) vm.VmError!?value_mod.Value {
        const self: *RuntimeHooks = @ptrCast(@alignCast(user_data));
        var arena = std.heap.ArenaAllocator.init(v.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const first = (try readFirst(v, a, source)) orelse return null;
        var ctx = self.context(a, v);
        return expand_mod.formToValue(&ctx, first.form) catch |err|
            return failure(v, err, "reader-error");
    }

    /// `(load-string s)`'s step: the first form of `source` compiled
    /// as read and run, never made a value first, since a syntax-quote
    /// has no value form (the reader leaves a marker the expander
    /// expands).
    fn loadHook(user_data: *anyopaque, v: *vm.VM, source: []const u8) vm.VmError!?vm.CompilerHooks.Loaded {
        const self: *RuntimeHooks = @ptrCast(@alignCast(user_data));
        var scratch = std.heap.ArenaAllocator.init(v.allocator);
        defer scratch.deinit();
        const first = (try readFirst(v, scratch.allocator(), source)) orelse return null;
        return .{ .value = try self.run(v, &scratch, first.form, null), .end = first.end };
    }

    const First = struct { form: *reader_mod.Form, end: usize };

    /// The first form of `source` and the byte its text ends at; null
    /// when `source` holds none, `:reader-error` when it does not
    /// read. Only the text up to the form's end is scanned and read
    /// (`reader.firstFormEnd`), so whatever follows it is ignored, as
    /// in Clojure, even text that does not read, and the cost is the
    /// first form's.
    fn readFirst(v: *vm.VM, a: std.mem.Allocator, source: []const u8) vm.VmError!?First {
        const text = source[0..@min(source.len, reader_mod.max_source_len)];
        const end = reader_mod.firstFormEnd(text) orelse {
            const none = holdsNoForm(a, text) catch return vm.VmError.OutOfMemory;
            return if (none) null else v.throwKeyword("reader-error");
        };
        const p = reader_mod.parser.parseForm(a, text[0..end]) catch |err| return failure(v, err, "reader-error");
        var reader = reader_mod.Reader.init(a, text[0..end]);
        const form = reader.readOneForm(p.sexp) catch |err| return failure(v, err, "reader-error");
        return .{ .form = form, .end = end };
    }

    /// Whether `text`, which has no first form, holds no form at all:
    /// it reads as a program of none (whitespace, comments and whole
    /// discards), rather than ending inside one.
    fn holdsNoForm(a: std.mem.Allocator, text: []const u8) !bool {
        const p = reader_mod.parser.parseProgram(a, text) catch |err| return if (err == error.OutOfMemory) err else false;
        var reader = reader_mod.Reader.init(a, text);
        const forms = reader.readProgram(p.sexp) catch |err| return if (err == error.OutOfMemory) err else false;
        return forms.len == 0;
    }

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
        // The Form and Tiny trees are garbage once the routine is
        // compiled; only the routine outlives the call.
        var scratch = std.heap.ArenaAllocator.init(v.allocator);
        defer scratch.deinit();
        var ctx = self.context(scratch.allocator(), v);
        const origin = reader_mod.SrcSpan{ .pos = 0, .len = 0 };
        // A form is data: its lazy seqs are realized and made lists.
        const form = expand_mod.valueToForm(&ctx, try seq_mod.asLists(v, form_value), origin) catch |err|
            return compileFailure(v, err, "UnsupportedForm", form_value, null);
        return self.run(v, &scratch, form, form_value);
    }

    /// `form` compiled and run as `eval` runs it, its trees on
    /// `scratch`; `form_value` is the form a failure names, null for
    /// one `load` read, made a value only when it fails.
    fn run(self: *RuntimeHooks, v: *vm.VM, scratch: *std.heap.ArenaAllocator, form: *const reader_mod.Form, form_value: ?value_mod.Value) vm.VmError!value_mod.Value {
        const persistent = v.runtime_arena.allocator();
        var declared = DeclaredNames.init(v.allocator);
        defer declared.deinit();
        // A `do` runs its forms one at a time, as a loaded file's
        // top-level `do` does (MACROEXPAND.md §2b).
        var pending: std.ArrayList(*const reader_mod.Form) = .empty;
        defer pending.deinit(v.allocator);
        pending.append(v.allocator, form) catch return vm.VmError.OutOfMemory;
        var last = value_mod.nilValue();
        while (pending.pop()) |next| {
            var detail: ?[]const u8 = null;
            const opts: CompileOptions = .{
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
            };
            const top = expandTopLevel(scratch.allocator(), next, opts) catch |err| return self.evalFailure(v, scratch, err, form, form_value, detail);
            if (doForms(top)) |body| {
                last = value_mod.nilValue();
                var i = body.len;
                while (i > 0) {
                    i -= 1;
                    pending.append(v.allocator, body[i]) catch return vm.VmError.OutOfMemory;
                }
                continue;
            }
            const compiled = compileFormWith(scratch.allocator(), top, opts) catch |err| return self.evalFailure(v, scratch, err, form, form_value, detail);
            const routine = persistent.create(vm.Routine) catch return vm.VmError.OutOfMemory;
            routine.* = compiled.toRoutine("<eval>");
            last = try v.runRoutine(routine);
        }
        return last;
    }

    /// What `eval` does when `err` stops it compiling `form`, which
    /// the failure names as `form_value` or, for a form `load` read,
    /// as its value, nil when it has none (a syntax-quote).
    fn evalFailure(self: *RuntimeHooks, v: *vm.VM, scratch: *std.heap.ArenaAllocator, err: CompileError, form: *const reader_mod.Form, form_value: ?value_mod.Value, detail: ?[]const u8) vm.VmError {
        return switch (err) {
            // A required file's throw that the caller's handler took:
            // the VM is already at the handler.
            error.ControlTransferred => vm.VmError.ControlTransferred,
            // A required file's form failed with no handler anywhere;
            // its frames are still in place above this call, so the
            // error leaves through the run loop with the full chain.
            error.RequiredFileFailed => v.traced_error orelse vm.VmError.UncaughtThrow,
            else => compileFailure(v, err, @errorName(err), form_value orelse blk: {
                var ctx = self.context(scratch.allocator(), v);
                break :blk expand_mod.formToValue(&ctx, form) catch |e|
                    if (e == error.OutOfMemory) return vm.VmError.OutOfMemory else value_mod.nilValue();
            }, detail),
        };
    }

    /// Out of memory stays an error; anything else the hook could
    /// not do throws `tag`.
    fn failure(v: *vm.VM, err: anyerror, tag: []const u8) vm.VmError {
        if (err == error.OutOfMemory) return vm.VmError.OutOfMemory;
        return v.throwKeyword(tag);
    }

    /// Out of memory stays an error; anything else `eval` could not
    /// compile throws `{:error :compile-error :message m :form form
    /// :kind name}`: `m` the compiler's sentence (`detail`), or with
    /// none `name`, the `CompileError` variant, in words; placed as a
    /// runtime error is when a handler is in force (VM.md §13).
    fn compileFailure(v: *vm.VM, err: anyerror, name: []const u8, form: value_mod.Value, detail: ?[]const u8) vm.VmError {
        if (err == error.OutOfMemory) return vm.VmError.OutOfMemory;
        return v.throwErrorMap(failureMap(v, name, form, detail) catch return vm.VmError.OutOfMemory);
    }

    fn failureMap(v: *vm.VM, name: []const u8, form: value_mod.Value, detail: ?[]const u8) !value_mod.Value {
        const heap = v.ensureHeap();
        const interner = v.ensureInterner();
        // `UnresolvedSymbol` says "unresolved symbol".
        var words: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&words);
        for (name, 0..) |c, i| {
            if (std.ascii.isUpper(c) and i > 0) w.writeByte(' ') catch break;
            w.writeByte(std.ascii.toLower(c)) catch break;
        }
        const message = detail orelse w.buffered();
        var m = try champ_mod.mapEmpty(heap);
        const entries = [_]struct { key: []const u8, value: value_mod.Value }{
            .{ .key = "error", .value = try interner.internKeywordValue("compile-error") },
            .{ .key = "message", .value = try string_mod.fromBytes(heap, message) },
            .{ .key = "form", .value = form },
            .{ .key = "kind", .value = try string_mod.fromBytes(heap, name) },
        };
        for (entries) |e| {
            m = try champ_mod.mapAssoc(heap, m, try interner.internKeywordValue(e.key), e.value, &dispatch_mod.hashValue, &dispatch_mod.equal);
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
    /// (`ExpandContext.failure`), or which routine limit a form
    /// reached (`LowerDiag.detail`); the text lives on `allocator`.
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
    /// Whether each local is cleared at its last move, so it roots
    /// nothing past its last use (COMPILER.md §4.9); off, every slot
    /// holds its value until written again, as a debugger showing
    /// locals needs.
    clear_locals: bool = true,
};

const no_macros: expand_mod.HostMacroTable = .{};

/// The heap of `namespace`'s registry, where constants and macro
/// values live; null without one.
fn registryHeap(namespace: ?*vm.Namespace) ?*heap_mod.Heap {
    const registry = (namespace orelse return null).registry orelse return null;
    return registry.heap;
}

/// The expander over `opts` (MACROEXPAND.md §1), `defmacro`
/// compiling through `ceval` when it is given.
fn expandContext(allocator: std.mem.Allocator, interner: *intern_mod.Interner, opts: CompileOptions, ceval: ?*CompileEvalData) expand_mod.ExpandContext {
    return .{
        .allocator = allocator,
        .interner = interner,
        .host_macros = opts.host_macros orelse &no_macros,
        .namespace = opts.namespace,
        .compile_eval = if (ceval) |data| .{ .user_data = @ptrCast(data), .eval = compileEvalCallback } else null,
        .registry = opts.registry,
        .load_callback = opts.load_callback,
        .value_heap = registryHeap(opts.namespace),
        .io = opts.io,
    };
}

/// An expansion failure as the compile error it is, with the span
/// and message the expander recorded (MACROEXPAND.md §8).
fn expandFailure(err: expand_mod.ExpandError, ctx: *const expand_mod.ExpandContext, form: *const reader_mod.Form, opts: CompileOptions) CompileError {
    if (opts.out_span) |s| s.* = if (ctx.failure) |f| f.span else form.origin;
    if (opts.out_detail) |d| d.* = if (ctx.failure) |f| f.message else null;
    return switch (err) {
        error.ExpansionDepthExceeded => CompileError.MacroDepthExceeded,
        error.RequiredFileFailed => CompileError.RequiredFileFailed,
        error.ControlTransferred => CompileError.ControlTransferred,
        error.OutOfMemory => CompileError.OutOfMemory,
        else => CompileError.MacroExpansionFailure,
    };
}

/// `form` with its head expanded until it names no macro: a
/// top-level form as a loader or `eval` takes it before compiling it
/// (MACROEXPAND.md §2b, the loader). A `do` it comes to runs its
/// forms one at a time (`doForms`), each taken the same way, as
/// Clojure's `eval` runs them. Without an interner nothing expands.
pub fn expandTopLevel(allocator: std.mem.Allocator, form: *const reader_mod.Form, opts: CompileOptions) CompileError!*const reader_mod.Form {
    const interner = opts.interner orelse return form;
    try publishNamespace(opts, interner);
    var ctx = expandContext(allocator, interner, opts, null);
    return expand_mod.expandHead(&ctx, form) catch |err| expandFailure(err, &ctx, form, opts);
}

/// `*ns*` names the namespace a form is expanded in
/// (`NamespaceRegistry.publishCurrent`).
fn publishNamespace(opts: CompileOptions, interner: *intern_mod.Interner) CompileError!void {
    const registry = opts.registry orelse return;
    registry.publishCurrent(interner) catch return CompileError.OutOfMemory;
}

/// The forms of `(do ...)`; null for any other form.
pub fn doForms(form: *const reader_mod.Form) ?[]const *reader_mod.Form {
    if (form.datum != .list) return null;
    const items = form.datum.list;
    if (items.len == 0 or items[0].datum != .symbol) return null;
    const head = items[0].datum.symbol;
    if (head.ns != null or !std.mem.eql(u8, head.name, "do")) return null;
    return items[1..];
}

/// Full form-compile entry: macroexpand, lower and emit `form`
/// under `opts`.
pub fn compileFormWith(
    allocator: std.mem.Allocator,
    form: *const reader_mod.Form,
    opts: CompileOptions,
) CompileError!Compiled {
    const interner = opts.interner orelse return compileExpanded(allocator, form, opts);
    try publishNamespace(opts, interner);
    var ceval_data = CompileEvalData{ .allocator = allocator, .opts = opts };
    var mctx = expandContext(allocator, interner, opts, &ceval_data);
    const expanded = expand_mod.expandForm(&mctx, form) catch |err| return expandFailure(err, &mctx, form, opts);
    return compileExpanded(allocator, expanded, opts);
}

/// Lower and emit `working_form`, already expanded, under `opts`.
fn compileExpanded(
    allocator: std.mem.Allocator,
    working_form: *const reader_mod.Form,
    opts: CompileOptions,
) CompileError!Compiled {
    const namespace = opts.namespace;
    const out_span = opts.out_span;
    const declared = opts.declared;
    // `.string` Form datums lower to `Tiny.literal` on the
    // registry's heap. Without a namespace or a registry there is
    // no heap and a string literal is `UnsupportedFeature`.
    const lower_heap = registryHeap(namespace);
    // Whatever this form defines (including definitions a macro
    // expanded into it) may be referred to anywhere inside it.
    if (declared) |d| try d.declareForm(working_form);
    var diag = LowerDiag{};
    var lexicals: ScopeTable(Lexical) = .{};
    defer lexicals.deinit(allocator);
    const ctx = LowerCtx{
        .lexicals = &lexicals,
        .interner = opts.interner,
        .heap = lower_heap,
        .namespace = namespace,
        .declared = declared,
        .diag = &diag,
    };
    const tiny = lowerForm(allocator, working_form, ctx) catch |err| {
        // An error that located itself reports that span; the
        // rest carry the macroexpanded form's span.
        if (out_span) |s| s.* = diag.span orelse working_form.origin;
        if (opts.out_detail) |d| d.* = diag.detail;
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
        .clear_locals = opts.clear_locals,
    }) catch |err| {
        if (out_span) |s| s.* = diag.span orelse working_form.origin;
        if (opts.out_detail) |d| d.* = diag.detail;
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
    // In a tail of the function a form returns its value itself: in
    // place when it is a literal, a local or a Var, else from `dst`
    // once computed. The forms that pass the tail on to their parts
    // return through them.
    const returns = if (recur_target) |t| t.returns else false;
    const returns_here = returns and !passesTail(form);
    if (returns_here) {
        if (form.* == .nil or form.* == .do_) return e.emit(vm.asm_.returnNil());
        if (try directOperand(e, form, true)) |op| return e.emit(Inst.primary(.call, vm.Call.@"return", op, Operand.none, Operand.none));
    }
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
        .prim => |p| if (p.more.len == 0) try compilePrim(e, p.op, p.lhs, p.rhs, dst) else try compileFold(e, p.op, p.lhs, p.rhs.?, p.more, dst),
        .if_ => |i| try compileIf(e, i.test_, i.then, i.else_, dst, recur_target),
        .let_star => |l| try compileLetStar(e, l.bindings, l.body, dst, recur_target),
        .do_ => |exprs| try compileDo(e, exprs, dst, recur_target),
        .fn_star => |f| try compileFn(e, .{
            .self_name = f.name,
            .display_name = f.name,
            .clauses = f.clauses,
            .self_referenced = f.self_referenced,
        }, dst),
        .call => |c| try compileCall(e, c.callee, c.args, dst),
        .self_call => |args| try compileSelfCall(e, args, dst),
        .lookup => |l| try compileLookup(e, l.key, l.args, dst),
        .letfn_star => |l| try compileLetFnStar(e, l.bindings, l.body, dst, recur_target),
        .loop_star => |l| try compileLoopStar(e, l.bindings, l.body, dst, returns),
        .recur => |r| try compileRecur(e, r.args, recur_target),
        .def => |d| try compileDef(e, d.name, d.value, dst),
        .var_ref => |v| try compileVarRef(e, v.ns, v.name, dst),
    }
    if (returns_here) try e.emit(vm.asm_.returnSlot(dst));
}

/// Whether `form` passes a tail position on to its parts, which then
/// return (or recur, or throw) on every path.
fn passesTail(form: *const Tiny) bool {
    return switch (form.*) {
        .if_, .let_star, .letfn_star, .loop_star, .recur, .throw_ => true,
        .do_ => |items| items.len > 0,
        else => false,
    };
}

/// `coll:<op>` over the items, compiled into one block (`fillBlock`).
/// Items too many for one block are built in chunks.
fn compileColl(e: *Emitter, op: vm.CollOp, items: []const *const Tiny, dst: u12) CompileError!void {
    const base = if (items.len == 0) dst else e.reserveBlock(dst, items.len) orelse return compileChunkedColl(e, op, items, dst);
    try fillBlock(e, base, null, items);
    try e.emit(Inst.primary(.coll, op, Operand.slot(base), .{ .kind = .unused, .index = @intCast(items.len) }, Operand.slot(dst)));
}

/// Compile a block's items into `base` and up, the callee first when
/// there is one: what the instruction consuming the block reads
/// (VM.md §6). The block is reserved before any item compiles, so the
/// items' own temporaries land above the slot being computed instead
/// of breaking its contiguity.
///
/// Items evaluate left to right, but one whose evaluation has no
/// effect, cannot fail and reads nothing that can change (a literal,
/// a local: `isTimeless`), or a Var an item before it read with no
/// instruction since (`HeldVar`), is written after the items that run
/// code, just before the consuming instruction, so no slot holds it
/// while they run. Each item that runs code is computed with its own
/// slot and every unwritten one below it as scratch (`Scratch`): a
/// block it builds starts at the lowest of them, and its result
/// lands in the item's slot. A call nested in an argument thus reuses
/// its consumer's slots, and nesting costs a slot per level only for
/// a value some level holds while the next one runs (COMPILER.md
/// §4.4).
fn fillBlock(e: *Emitter, base: u12, callee: ?*const Tiny, args: []const *const Tiny) CompileError!void {
    const first = @intFromBool(callee != null);
    const count = first + args.len;
    const top = e.slot_top;
    const saved = e.scratch;
    defer e.scratch = saved;
    // Items that copy a held Var's slot; past its capacity an item
    // reads its Var itself.
    var copies: [16]struct { slot: u12, from: u12 } = undefined;
    var n_copies: usize = 0;
    var lo: u16 = base;
    for (0..count) |k| {
        const item = if (k < first) callee.? else args[k - first];
        const slot = base + @as(u12, @intCast(k));
        if (isTimeless(e, item)) {
            // Resolved now, so a captured name's upvalue is numbered
            // in the order the source reads it.
            if (item.* == .symbol) _ = try e.resolveOrCapture(item.symbol);
            continue;
        }
        const read = varOf(e, item);
        if (read) |v| if (n_copies < copies.len) if (e.heldSlot(v)) |from| {
            copies[n_copies] = .{ .slot = slot, .from = from };
            n_copies += 1;
            continue;
        };
        e.slot_top = @as(u16, slot) + 1;
        e.scratch = .{ .lo = @intCast(lo), .dst = slot };
        const pc = e.code.items.len;
        try compileExpr(e, item, slot, null);
        e.slot_top = top;
        lo = @as(u16, slot) + 1;
        if (read) |v| if (e.code.items.len == pc + 1) e.hold(v, slot, pc);
    }
    e.scratch = saved;
    var c: usize = 0;
    for (0..count) |k| {
        const item = if (k < first) callee.? else args[k - first];
        const slot = base + @as(u12, @intCast(k));
        if (isTimeless(e, item)) {
            try compileExpr(e, item, slot, null);
        } else if (c < n_copies and copies[c].slot == slot) {
            try e.emit(vm.asm_.move(slot, copies[c].from));
            c += 1;
        }
    }
}

/// A node whose value is the same whenever the enclosing form reads
/// it, which has no effect and cannot fail: a literal, or a local of
/// this routine or of one it is nested in (a captured local's cell
/// is written once, before any code can read it).
fn isTimeless(e: *const Emitter, t: *const Tiny) bool {
    return switch (t.*) {
        .symbol => |name| e.isLexical(name),
        else => isInert(e, t),
    };
}

/// The Var a symbol reads, when it names one that exists.
fn varOf(e: *const Emitter, t: *const Tiny) ?*vm.Var {
    const ns = e.namespace orelse return null;
    return switch (t.*) {
        .symbol => |name| if (e.isLexical(name)) null else ns.lookup(name),
        .qualified_symbol => |q| (qualifiedTarget(ns, q.ns) orelse return null).lookupLocal(q.name),
        else => null,
    };
}

/// Items per chunk of a call or collection too large for one slot
/// block (COMPILER.md §4.4); even, so a map's pairs stay whole.
const chunk_items = 256;

/// A collection of more items than fit in one slot block: the items
/// in order, `chunk_items` at a time, each chunk built by `coll:*`
/// and poured into an accumulator with `nexis.core/into`; a list
/// comes out of `(apply list acc)`.
fn compileChunkedColl(e: *Emitter, op: vm.CollOp, items: []const *const Tiny, dst: u12) CompileError!void {
    const acc = switch (op) {
        .vector => try accumulate(e, .vector, .vector, items),
        .map => try accumulate(e, .map, .map, items),
        .set => try accumulate(e, .set, .set, items),
        .list => try accumulate(e, .vector, .vector, items),
        .concat => try accumulate(e, .vector, .concat, items),
        _ => return CompileError.InternalCompilerBug,
    };
    switch (op) {
        .list, .concat => try callCore(e, "apply", &.{ .{ .core = "list" }, .{ .slot = acc } }, dst),
        else => try e.emit(vm.asm_.move(dst, acc)),
    }
}

/// A call of more arguments than fit in one slot block:
/// `(apply callee args)`, the callee evaluated first and the
/// arguments gathered into a vector in chunks.
fn compileChunkedCall(e: *Emitter, callee: *const Tiny, args: []const *const Tiny, dst: u12) CompileError!void {
    const f = try e.allocSlot();
    try compileExpr(e, callee, f, null);
    const acc = try accumulate(e, .vector, .vector, args);
    try callCore(e, "apply", &.{ .{ .slot = f }, .{ .slot = acc } }, dst);
}

/// A fresh slot holding the `acc_op` collection of `items`: an empty
/// one, then `(into acc chunk)` for each `chunk_op` chunk in order.
fn accumulate(e: *Emitter, acc_op: vm.CollOp, chunk_op: vm.CollOp, items: []const *const Tiny) CompileError!u12 {
    const acc = try e.allocSlot();
    try e.emit(Inst.primary(.coll, acc_op, Operand.slot(acc), .{ .kind = .unused, .index = 0 }, Operand.slot(acc)));
    var start: usize = 0;
    while (start < items.len) : (start += chunk_items) {
        const mark = e.slot_top;
        defer e.slot_top = mark;
        const chunk = try e.allocSlot();
        try compileColl(e, chunk_op, items[start..@min(start + chunk_items, items.len)], chunk);
        try callCore(e, "into", &.{ .{ .slot = acc }, .{ .slot = chunk } }, acc);
    }
    return acc;
}

/// An argument of `callCore`: a slot's value, or a core Var's.
const CoreArg = union(enum) { slot: u12, core: []const u8 };

/// `(nexis.core/<name> args...)` into `dst`. Without the core
/// namespace there is no way to build what does not fit in slots.
fn callCore(e: *Emitter, name: []const u8, args: []const CoreArg, dst: u12) CompileError!void {
    const base = try e.allocSlotBlock(1 + args.len);
    try loadCore(e, name, base);
    for (args, 1..) |arg, i| {
        const slot = base + @as(u12, @intCast(i));
        switch (arg) {
            .slot => |s| try e.emit(vm.asm_.move(slot, s)),
            .core => |n| try loadCore(e, n, slot),
        }
    }
    try e.emit(vm.asm_.callCall(base, @intCast(args.len), dst));
}

fn loadCore(e: *Emitter, name: []const u8, dst: u12) CompileError!void {
    const registry = if (e.namespace) |ns| ns.registry else null;
    const v = (if (registry) |r| r.core.lookupLocal(name) else null) orelse return unresolved(e.allocator, e.diag, null, "nexis.core", name);
    try e.emit(vm.asm_.varLoadVar(dst, try e.addVarTableEntry(v)));
}

/// `op` over its operands, read in place where they allow it
/// (`compileOperand`). The left operand is evaluated first, as a
/// call's arguments are; it reads a Var in place only when computing
/// the right one runs no code that could change the Var.
fn compilePrim(e: *Emitter, op: PrimOp, lhs: *const Tiny, rhs: ?*const Tiny, dst: u12) CompileError!void {
    // A scratch destination holds nothing anyone reads until this
    // instruction writes it, so the first operand that needs code is
    // computed there: nested arithmetic reuses one slot instead of
    // taking one per level.
    var free_dst = if (e.scratch) |s| s.dst == dst else false;
    const a = try primOperand(e, lhs, rhs == null or isLeaf(rhs.?), dst, &free_dst);
    const b = if (rhs) |r| try primOperand(e, r, true, dst, &free_dst) else Operand.none;
    try e.emit(op.inst(dst, a, b));
}

/// `(+ a b c ...)`, `*` or `-` likewise: every argument computed in
/// order (`compileOperand`), as the fn's call would compute them,
/// then a left fold over their values, the running value in a slot
/// nothing reads and the last instruction writing `dst`
/// (COMPILER.md §4.3). An argument reads a Var in place only when no
/// later argument runs code that could change it.
fn compileFold(e: *Emitter, op: PrimOp, first: *const Tiny, second: *const Tiny, more: []const *const Tiny, dst: u12) CompileError!void {
    const args = try e.allocator.alloc(*const Tiny, 2 + more.len);
    defer e.allocator.free(args);
    args[0] = first;
    args[1] = second;
    @memcpy(args[2..], more);
    const ops = try e.allocator.alloc(Operand, args.len);
    defer e.allocator.free(ops);
    for (args, ops, 1..) |arg, *o, i| {
        const leaves_after = for (args[i..]) |later| {
            if (!isLeaf(later)) break false;
        } else true;
        o.* = try compileOperand(e, arg, leaves_after);
    }
    const free_dst = if (e.scratch) |s| s.dst == dst else false;
    const acc = if (free_dst) dst else try e.allocSlot();
    try e.emit(op.inst(acc, ops[0], ops[1]));
    for (ops[2 .. ops.len - 1]) |o| try e.emit(op.inst(acc, Operand.slot(acc), o));
    try e.emit(op.inst(dst, Operand.slot(acc), ops[ops.len - 1]));
}

/// `compileOperand`, or `t` computed into `dst` when `free_dst` says
/// no operand holds it yet.
fn primOperand(e: *Emitter, t: *const Tiny, allow_var: bool, dst: u12, free_dst: *bool) CompileError!Operand {
    if (try directOperand(e, t, allow_var)) |op| return op;
    if (!free_dst.*) return compileOperand(e, t, allow_var);
    free_dst.* = false;
    try compileExpr(e, t, dst, null);
    return Operand.slot(dst);
}

/// A node whose evaluation has no effect and cannot fail: a literal
/// or a local of this routine. (A Var's read fails while it is
/// unbound.)
fn isInert(e: *const Emitter, t: *const Tiny) bool {
    return switch (t.*) {
        .nil, .bool, .literal => true,
        .int => |n| value_mod.isFixnumRange(n),
        .symbol => |name| e.resolveLocalRef(name) != null,
        else => false,
    };
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
    const saved = e.scratch;
    defer e.scratch = saved;
    e.scratch = .{ .lo = tmp, .dst = tmp };
    try compileExpr(e, t, tmp, null);
    return Operand.slot(tmp);
}

/// `t` as an operand read in place, or null when it needs code.
fn directOperand(e: *Emitter, t: *const Tiny, allow_var: bool) CompileError!?Operand {
    if (try constValue(t)) |v| return e.constOperand(v);
    switch (t.*) {
        .qualified_symbol => |q| {
            if (!allow_var) return null;
            return varOperand(try qualifiedVarIndex(e, q.ns, q.name));
        },
        .symbol => |name| {
            const ref = e.resolveOrCapture(name) catch |err| switch (err) {
                CompileError.UnresolvedSymbol => {
                    if (!allow_var or e.namespace == null) return null;
                    return varOperand(try e.addVarRef(name));
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

/// Var-table entry `idx` as a `v` operand, or null when it lies past
/// what an operand addresses and must be loaded into a slot.
fn varOperand(idx: u32) ?Operand {
    return if (idx < max_operands) Operand.varRef(@intCast(idx)) else null;
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
fn qualifiedVarIndex(e: *Emitter, ns_prefix: []const u8, name: []const u8) CompileError!u32 {
    const current_ns = e.namespace orelse return unresolved(e.allocator, e.diag, null, ns_prefix, name);
    const target_ns = qualifiedTarget(current_ns, ns_prefix) orelse return unresolved(e.allocator, e.diag, null, ns_prefix, name);
    if (target_ns == current_ns) return e.addVarLocal(name);
    const v = target_ns.lookupLocal(name) orelse return unresolved(e.allocator, e.diag, null, ns_prefix, name);
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
    //   4. otherwise `UnresolvedSymbol`
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
            return unresolved(e.allocator, e.diag, null, null, name); // no namespace
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
/// Var of the same name is shadowed, never rebound), stores the
/// value, read in place where it can be, as its root
/// (`var:store-var`), and yields the Var object (`var:var-object`).
///
/// Without a Namespace (`e.namespace == null`), `def` raises
/// `UnresolvedSymbol`.
///
/// `(def x)` (no value) is a forward-declaration: the Var is
/// interned and stays as it was.
fn compileDef(
    e: *Emitter,
    name: []const u8,
    value: ?*const Tiny,
    dst: u12,
) CompileError!void {
    if (e.namespace == null) return CompileError.UnresolvedSymbol;
    const idx = try e.addVarLocal(name);
    // RHS is non-tail.
    if (value) |val| try e.emit(vm.asm_.varStoreVar(idx, try compileOperand(e, val, true)));
    try e.emit(vm.asm_.varVarObject(dst, idx));
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

/// `let*` binds as `bindSequential`, except that a binding whose
/// value is a local already held in a slot names that slot instead
/// of copying it (`aliasSlot`).
fn compileLetStar(
    e: *Emitter,
    bindings: []const Binding,
    body: *const Tiny,
    dst: u12,
    recur_target: ?*const RecurTarget,
) CompileError!void {
    // Restored by `defer` so an error mid-body leaves no scope
    // behind for a recovering caller.
    const mark = e.scope.mark();
    defer e.scope.restore(mark);
    for (bindings) |b| {
        if (try aliasSlot(e, b, body, recur_target)) |slot| {
            try e.scope.bind(e.allocator, b.name, .{ .direct_slot = slot });
            continue;
        }
        const slot = try e.allocSlot();
        try compileExpr(e, b.value, slot, null);
        try e.bindLocal(b.name, slot, b.captured);
    }
    // The body is in the let's own tail position.
    try compileExpr(e, body, dst, recur_target);
}

/// The slot a `let*` binding can share instead of taking its own
/// (COMPILER.md §4.4, aliasing): its value is a symbol naming an
/// uncaptured local of this routine, the binding is not captured
/// (a cell would box the shared slot), and nothing rewrites the
/// slot while the binding is in scope. The only instruction that
/// rewrites a bound slot is a `recur` rebinding its target's
/// bindings, and a `recur` inside the scope can only target the
/// `let*`'s own target, from the body's tail.
fn aliasSlot(e: *Emitter, b: Binding, body: *const Tiny, recur_target: ?*const RecurTarget) CompileError!?u12 {
    if (b.captured) return null;
    const name = switch (b.value.*) {
        .symbol => |n| n,
        else => return null,
    };
    const slot = switch (e.resolveLocalRef(name) orelse return null) {
        .direct_slot => |s| s,
        else => return null,
    };
    if (recur_target) |t| {
        if (isRecurSlot(t, slot) and try mayRecur(body)) return null;
    }
    return slot;
}

/// Whether a tail position of `t` is a `recur`: the positions a
/// `recur` of the enclosing target can take (COMPILER.md §4.4).
fn mayRecur(t: *const Tiny) CompileError!bool {
    try stack.check();
    return switch (t.*) {
        .recur => true,
        .if_ => |i| try mayRecur(i.then) or (if (i.else_) |x| try mayRecur(x) else false),
        .do_ => |items| items.len > 0 and try mayRecur(items[items.len - 1]),
        .let_star => |l| try mayRecur(l.body),
        .letfn_star => |l| try mayRecur(l.body),
        else => false,
    };
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
    const result: u12 = if (finally_ != null) try e.allocSlot() else dst;
    // The binding's slot is the one above every slot live here. The VM
    // writes it only once the body is abandoned, when the body's
    // temporaries are dead, so the body may use it too, and a nested
    // `try` takes the same one; the handler claims it.
    const binding_slot = e.claimSlots(e.slot_top, 1) orelse return e.limit("local slots");
    e.slot_top -= 1;

    // The try's catch and finally pcs are filled in once placed.
    const t = try tableIndex(e.tries.items.len);
    try e.tries.append(e.allocator, .{ .catch_pc = unpatched });
    try e.try_extents.append(e.allocator, .{ .enter = try tableIndex(e.code.items.len), .end = unpatched });
    try e.emit(vm.asm_.tryEnter(t, binding_slot));

    // A finally's temporary holds nothing anyone reads until the body
    // writes it: scratch, as an operand's is.
    const saved_scratch = e.scratch;
    if (result != dst) e.scratch = .{ .lo = result, .dst = result };
    try compileExpr(e, body, result, null);
    e.scratch = saved_scratch;

    // A body or handler that always throws or recurs never reaches
    // its try-exit, so it has none.
    const body_exit_pc: ?usize = if (!e.reachable) null else try e.emitPlaceholder(vm.asm_.tryExit(unpatched));

    // Catch entry.
    e.tries.items[t].catch_pc = try e.nextPc();

    // The VM stores the thrown value in the binding's slot and jumps
    // here; a captured binding is boxed first thing.
    if (try e.allocSlot() != binding_slot) return CompileError.InternalCompilerBug;
    const scope_mark = e.scope.mark();
    defer e.scope.restore(scope_mark);
    try e.bindLocal(binding, binding_slot, binding_captured);
    try compileExpr(e, handler, result, null);
    e.scope.restore(scope_mark);

    const catch_exit_pc: ?usize = if (!e.reachable) null else try e.emitPlaceholder(vm.asm_.tryExit(unpatched));

    // Optional finally block + finally-exit.
    if (finally_) |fin_body| {
        e.tries.items[t].finally_pc = try e.nextPc();
        // The binding is out of scope here; the value is discarded.
        try compileEffect(e, fin_body);
        try e.emit(vm.asm_.finallyExit());
    }
    e.try_extents.items[t].end = try tableIndex(e.code.items.len);

    if (body_exit_pc) |pc| try e.patchJumpHere(pc);
    if (catch_exit_pc) |pc| try e.patchJumpHere(pc);
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
    returns: bool,
) CompileError!void {
    const mark = e.scope.mark();
    defer e.scope.restore(mark);

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
    const numeric = try e.allocator.alloc(bool, bindings.len);
    defer e.allocator.free(numeric);
    try numericBindings(e.allocator, bindings, names, body, numeric);
    const loop_target = RecurTarget{
        .entry_pc = entry_pc,
        .binding_slots = binding_slots,
        .captured_mask = captured_mask,
        .names = names,
        .returns = returns,
        .numeric = numeric,
    };

    // 5. Compile body with the loop target installed. The
    // body REPLACES (not propagates) any outer recur target —
    // a recur inside the body always targets THIS loop, not an
    // enclosing one (nested-loop rule).
    try compileExpr(e, body, dst, &loop_target);
}

/// Lower `(recur args...)` per COMPILER.md §5.6 + VM.md §11:
/// rebind the target's bindings to the arguments as one parallel
/// assignment, then go back to the target's entry, or repeat its test
/// (`BottomTest`). No `call` is emitted and `dst` is never written.
///
/// An argument for a binding no closure captures is computed straight
/// into the binding's slot once every other argument that reads the
/// binding is computed (`nextRecurArg`). Every other argument is read
/// in place when it is a constant, an upvalue or a slot no rebinding
/// overwrites, and is computed into a fresh slot otherwise; the moves
/// into the bindings follow, a captured binding getting a fresh cell
/// per iteration (the value is boxed in its fresh slot, then
/// installed), since mutating the shared cell would change what
/// earlier closures see.
fn compileRecur(
    e: *Emitter,
    args: []const *const Tiny,
    recur_target: ?*const RecurTarget,
) CompileError!void {
    const target = recur_target orelse return CompileError.RecurOutsideTail;
    if (args.len != target.binding_slots.len) return CompileError.RecurArityMismatch;

    const n = args.len;
    const reads = try e.allocator.alloc(bool, n * n);
    defer e.allocator.free(reads);
    for (args, 0..) |arg, j| {
        for (target.names, 0..) |name, m| reads[j * n + m] = j != m and try readsName(arg, name);
    }
    const state = try e.allocator.alloc(RecurArg, n);
    defer e.allocator.free(state);
    for (args, target.captured_mask, state) |arg, captured, *s| {
        s.* = .{ .temp = captured, .safe = try cannotFail(e, arg, target) };
    }
    const pending = try e.allocator.alloc(?Operand, n);
    defer e.allocator.free(pending);
    for (0..n) |_| {
        const i = nextRecurArg(state, reads) orelse first: {
            // Every argument left waits for another: the first takes a
            // fresh slot, so nothing waits for it.
            const first = for (state, 0..) |s, k| {
                if (!s.done) break k;
            } else unreachable;
            state[first].temp = true;
            break :first first;
        };
        state[i].done = true;
        const arg = args[i];
        const slot = target.binding_slots[i];
        // Recur args are non-tail (any nested recur would target
        // the wrong scope; COMPILER.md §4.4).
        if (!state[i].temp) {
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
    if (target.bottom) |b| return repeatTest(e, b);
    try e.emit(vm.asm_.jumpJmp(target.entry_pc));
}

/// Where a `recur` argument stands: computed yet, going through a
/// fresh slot (a captured binding's, or one that breaks a cycle of
/// arguments reading each other's bindings), and whether computing
/// it can fail or do anything else another argument could observe.
const RecurArg = struct { done: bool = false, temp: bool, safe: bool };

/// The first argument still to compute that may be computed now: when
/// it goes into its binding's slot, every other argument reading that
/// binding is computed; and when an argument before it is still to
/// compute, one of the two cannot fail, so computing them out of
/// order changes nothing a program can see (COMPILER.md §5.6).
fn nextRecurArg(state: []const RecurArg, reads: []const bool) ?usize {
    const n = state.len;
    next: for (state, 0..) |s, k| {
        if (s.done) continue;
        if (!s.temp) for (state, 0..) |other, j| {
            if (!other.done and reads[j * n + k]) continue :next;
        };
        if (!s.safe) for (state[0..k]) |before| {
            if (!before.done and !before.safe) continue :next;
        };
        return k;
    }
    return null;
}

/// Whether evaluating `t` can neither fail nor do anything else: a
/// literal, a local, or `+`, `-`, `*`, negation or `abs` of numbers,
/// or a quotient or modulus of a number by a nonzero integer
/// literal. Arithmetic on numbers fails only when memory runs out.
fn cannotFail(e: *const Emitter, t: *const Tiny, target: *const RecurTarget) CompileError!bool {
    try stack.check();
    if (isInert(e, t)) return true;
    const p = switch (t.*) {
        .prim => |p| p,
        else => return false,
    };
    switch (p.op) {
        .add, .sub, .mul, .neg, .abs => {},
        .quot, .mod => if (p.rhs.?.* != .int or p.rhs.?.int == 0) return false,
        else => return false,
    }
    if (!try holdsNumber(e, p.lhs, target)) return false;
    if (p.rhs) |r| if (!try holdsNumber(e, r, target)) return false;
    for (p.more) |m| if (!try holdsNumber(e, m, target)) return false;
    return true;
}

/// Whether `t` evaluates to a number without failing: a number
/// literal, a binding of `target` that holds a number on every
/// iteration, or arithmetic that `cannotFail`.
fn holdsNumber(e: *const Emitter, t: *const Tiny, target: *const RecurTarget) CompileError!bool {
    return switch (t.*) {
        .int => true,
        .literal => |v| vm.isNumber(v),
        .prim => try cannotFail(e, t, target),
        .symbol => |name| switch (e.resolveLocalRef(name) orelse return false) {
            .direct_slot, .cell_slot => |slot| for (target.binding_slots, 0..) |s, k| {
                if (s == slot) break k < target.numeric.len and target.numeric[k];
            } else false,
            .upvalue => false,
        },
        else => false,
    };
}

/// Per binding of a `loop*`: whether it holds a number on every
/// iteration, because its initial value and its every `recur`
/// argument is a number (`makesNumber`). The largest such set: start
/// from the bindings whose initial value is one and drop a binding
/// while some `recur` can give it anything else.
fn numericBindings(allocator: std.mem.Allocator, bindings: []const Binding, names: []const []const u8, body: *const Tiny, numeric: []bool) CompileError!void {
    for (bindings, numeric) |b, *n| n.* = try makesNumber(b.value, &.{}, &.{}, &.{});
    var shadowed: std.ArrayList([]const u8) = .empty;
    defer shadowed.deinit(allocator);
    while (try dropNonNumeric(allocator, body, names, numeric, &shadowed)) {}
}

/// Clear `numeric` for each binding a `recur` in a tail of `t` can
/// rebind to anything but a number; whether any was cleared.
/// `shadowed` holds the names bound between the loop and `t`.
fn dropNonNumeric(allocator: std.mem.Allocator, t: *const Tiny, names: []const []const u8, numeric: []bool, shadowed: *std.ArrayList([]const u8)) CompileError!bool {
    try stack.check();
    switch (t.*) {
        .recur => |r| {
            if (r.args.len != names.len) return false;
            var dropped = false;
            for (r.args, numeric) |arg, *n| {
                if (n.* and !try makesNumber(arg, names, numeric, shadowed.items)) {
                    n.* = false;
                    dropped = true;
                }
            }
            return dropped;
        },
        .if_ => |i| {
            const then = try dropNonNumeric(allocator, i.then, names, numeric, shadowed);
            const other = if (i.else_) |x| try dropNonNumeric(allocator, x, names, numeric, shadowed) else false;
            return then or other;
        },
        .do_ => |items| return items.len > 0 and try dropNonNumeric(allocator, items[items.len - 1], names, numeric, shadowed),
        inline .let_star, .letfn_star => |l| {
            const mark = shadowed.items.len;
            defer shadowed.shrinkRetainingCapacity(mark);
            for (l.bindings) |b| try shadowed.append(allocator, b.name);
            return dropNonNumeric(allocator, l.body, names, numeric, shadowed);
        },
        else => return false,
    }
}

/// Whether `t`, wherever it returns, returns a number: a number
/// literal, arithmetic (whose result is a number whenever it has
/// one), a binding in `names` marked `numeric` and not `shadowed`, or
/// an `if` whose arms both are.
fn makesNumber(t: *const Tiny, names: []const []const u8, numeric: []const bool, shadowed: []const []const u8) CompileError!bool {
    try stack.check();
    return switch (t.*) {
        .int => true,
        .literal => |v| vm.isNumber(v),
        .prim => |p| switch (p.op) {
            .lt, .lte, .gt, .gte, .num_eq => false,
            else => true,
        },
        .symbol => |name| for (shadowed) |s| {
            if (std.mem.eql(u8, s, name)) break false;
        } else for (0..names.len) |i| {
            const k = names.len - 1 - i;
            if (std.mem.eql(u8, names[k], name)) break numeric[k];
        } else false,
        .if_ => |i| if (i.else_) |x| try makesNumber(i.then, names, numeric, shadowed) and try makesNumber(x, names, numeric, shadowed) else false,
        else => false,
    };
}

/// The target's test, repeated at a `recur` (`BottomTest`).
fn repeatTest(e: *Emitter, b: BottomTest) CompileError!void {
    const saved_span = e.current_span;
    const then_pc = b.entry_pc + b.len;
    for (b.entry_pc..then_pc) |pc| {
        var copy = e.code.items[pc];
        if (pc == then_pc - 1) switch (b.arm) {
            .then => {
                const if_false = copy.variant == @backingInt(vm.Jump.if_false);
                copy.variant = @backingInt(if (if_false) vm.Jump.if_true else vm.Jump.if_false);
                copy.setWide(then_pc);
            },
            .else_ => |else_pc| copy.setWide(else_pc),
        };
        e.current_span = e.spanAt(pc) orelse saved_span;
        try e.emit(copy);
    }
    e.current_span = saved_span;
    switch (b.arm) {
        .then => |exits| try exits.append(e.allocator, try e.emitPlaceholder(vm.asm_.jumpJmp(unpatched))),
        .else_ => try e.emit(vm.asm_.jumpJmp(then_pc)),
    }
}

/// The test of the `if` starting at `entry_pc`, just emitted with its
/// one jump to the else arm in `jumps`, as a `recur` can repeat it:
/// a jump on an operand read in place, or a comparison into a slot
/// and a jump on that slot (the pair the VM runs as one dispatch).
fn bottomTest(e: *Emitter, entry_pc: u32, jumps: []const usize) CompileError!?BottomTest {
    const code = e.code.items[entry_pc..];
    if (jumps.len != 1 or code.len > 2 or jumps[0] != e.code.items.len - 1) return null;
    if (code.len == 2 and (code[0].groupOf() != .cmp or @as(u16, @bitCast(code[0].a)) != @as(u16, @bitCast(code[1].a)))) return null;
    // The then arm starts here, a target of every repeated test.
    _ = try e.nextPc();
    return .{ .entry_pc = entry_pc, .len = @intCast(code.len), .arm = undefined };
}

fn isRecurSlot(target: *const RecurTarget, slot: u12) bool {
    return std.mem.findScalar(u12, target.binding_slots, slot) != null;
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
        .prim => |p| try readsName(p.lhs, name) or (if (p.rhs) |r| try readsName(r, name) else false) or try any(p.more, name),
        .if_ => |i| try readsName(i.test_, name) or try readsName(i.then, name) or (if (i.else_) |x| try readsName(x, name) else false),
        .let_star, .loop_star => |l| blk: {
            for (l.bindings) |b| if (try readsName(b.value, name)) break :blk true;
            break :blk try readsName(l.body, name);
        },
        .letfn_star => |l| blk: {
            for (l.bindings) |b| for (b.clauses) |c| if (try readsName(c.body, name)) break :blk true;
            break :blk try readsName(l.body, name);
        },
        .fn_star => |f| blk: {
            for (f.clauses) |c| if (try readsName(c.body, name)) break :blk true;
            break :blk false;
        },
        .call => |c| try readsName(c.callee, name) or try any(c.args, name),
        .self_call => |args| any(args, name),
        .lookup => |l| any(l.args, name),
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
    // The forms before the last run for effect and are not in tail
    // position.
    for (exprs[0 .. exprs.len - 1]) |expr| try compileEffect(e, expr);
    // Last expression IS tail position; inherit recur target.
    try compileExpr(e, exprs[exprs.len - 1], dst, recur_target);
}

/// Compile `t` for its effect alone (COMPILER.md §5.3): a form that
/// runs no code and cannot fail is dropped, a `do` is its forms for
/// effect, and an `if` runs its arms for effect, so an arm that is
/// dropped costs no jump and no nil. Anything else computes into a
/// slot freed at once.
fn compileEffect(e: *Emitter, t: *const Tiny) CompileError!void {
    if (isInert(e, t)) return;
    const saved_span = e.current_span;
    defer e.current_span = saved_span;
    if (e.spanned) {
        const node: *const TinyNode = @fieldParentPtr("tiny", t);
        if (node.span) |span| e.current_span = span;
    }
    errdefer if (e.diag) |d| {
        if (d.span == null) d.span = e.current_span;
    };
    try stack.check();
    const slot_mark = e.slot_top;
    defer e.slot_top = slot_mark;
    switch (t.*) {
        .do_ => |items| for (items) |item| try compileEffect(e, item),
        .if_ => |i| {
            const else_inert = i.else_ == null or isInert(e, i.else_.?);
            if (isInert(e, i.then) and else_inert) return compileEffect(e, i.test_);
            var skip: Jumps = .empty;
            defer skip.deinit(e.allocator);
            if (isInert(e, i.then)) {
                // Only the else arm runs code: skip it when the test holds.
                try compileBranch(e, i.test_, true, &skip);
                try compileEffect(e, i.else_.?);
                return patchJumpsHere(e, skip.items);
            }
            try compileBranch(e, i.test_, false, &skip);
            try compileEffect(e, i.then);
            if (else_inert) return patchJumpsHere(e, skip.items);
            const end_jmp_pc: ?usize = if (!e.reachable) null else try e.emitPlaceholder(vm.asm_.jumpJmp(unpatched));
            try patchJumpsHere(e, skip.items);
            try compileEffect(e, i.else_.?);
            if (end_jmp_pc) |pc| try e.patchJumpHere(pc);
        },
        else => try compileExpr(e, t, try e.allocSlot(), null),
    }
}

/// What `compileFn` builds a routine from: a `fn*`, or a `letfn*`
/// binding, which has no self-name (its name's cell is in scope).
const FnSpec = struct {
    /// The self-name the bodies may refer to.
    self_name: ?[]const u8 = null,
    /// What traces and the disassembler call the routine.
    display_name: ?[]const u8 = null,
    clauses: []const Clause,
    self_referenced: bool = false,
};

/// Lower a `fn*` (COMPILER.md §5.5): compile each clause's body as a
/// child routine whose free names resolve through this Emitter as
/// captures, register the first and its capture descriptor here, and
/// emit `closure:make`. Two clauses or more share one arity table
/// (VM.md §5), and every clause's child starts from the captures the
/// clauses before it made, so a name keeps its upvalue in every
/// clause and one closure's cells serve them all. A body that refers
/// to its self-name gets a placeholder cell, allocated before the
/// children are compiled so they can capture it, and filled with the
/// closure after `closure:make`.
fn compileFn(parent: *Emitter, f: FnSpec, dst: u12) CompileError!void {
    var self_cell_slot: u12 = 0;
    if (f.self_referenced) {
        self_cell_slot = try parent.allocSlot();
        try parent.emit(vm.asm_.closureNewCell(self_cell_slot));
    }

    var shared: Captures = .{};
    defer shared.deinit(parent.allocator);
    // The self-name is upvalue 0, sourced from the placeholder cell.
    if (f.self_referenced) {
        try shared.sources.append(parent.allocator, .{ .local_cell_slot = self_cell_slot });
        try shared.names.append(parent.allocator, .{ .name = f.self_name.?, .upvalue = 0 });
    }
    const routines = try parent.out.alloc(vm.Routine, f.clauses.len);
    for (f.clauses, routines) |clause, *r| r.* = try compileClause(parent, f, clause, &shared);

    const upvalue_count: u16 = @intCast(shared.sources.items.len);
    for (routines) |*r| r.upvalue_count = upvalue_count;
    if (routines.len > 1) {
        // `parseClauses` kept Clojure's rules, so the table is one
        // `verify` takes: each fixed clause at its count, the rest
        // clause at or past every one.
        var len: usize = 0;
        for (routines) |r| if (!r.variadic) {
            len = @max(len, @as(usize, r.fixed_arity) + 1);
        };
        const fixed = try parent.out.alloc(?*const vm.Routine, len);
        @memset(fixed, null);
        const table = try parent.out.create(vm.Arities);
        table.* = .{ .fixed = fixed };
        for (routines) |*r| {
            if (r.variadic) table.rest = r else fixed[r.fixed_arity] = r;
            r.arities = table;
        }
    }
    const sources = try parent.out.dupe(vm.CaptureSource, shared.sources.items);
    const cap_desc_idx = try parent.addCaptureDescriptor(.{ .routine = &routines[0], .sources = sources });
    try parent.emit(vm.asm_.closureMake(cap_desc_idx, dst));
    if (f.self_referenced) {
        try parent.emit(vm.asm_.closureInitCell(self_cell_slot, vm.Operand.slot(dst)));
    }
}

/// The captures every clause of one `fn*` shares, in upvalue order.
const Captures = struct {
    sources: std.ArrayList(vm.CaptureSource) = .empty,
    names: std.ArrayList(CapturedName) = .empty,

    fn deinit(self: *Captures, allocator: std.mem.Allocator) void {
        self.sources.deinit(allocator);
        self.names.deinit(allocator);
    }
};

/// One clause of `f` as a routine of its own, its upvalue count left
/// for `compileFn`: a child Emitter that starts from `shared` and
/// leaves there every capture it adds.
fn compileClause(parent: *Emitter, f: FnSpec, clause: Clause, shared: *Captures) CompileError!vm.Routine {
    const count = clause.params.len + @intFromBool(clause.rest_param != null);
    const names = try parent.allocator.alloc([]const u8, count);
    defer parent.allocator.free(names);
    @memcpy(names[0..clause.params.len], clause.params);
    if (clause.rest_param) |rp| names[count - 1] = rp;

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
    child.clear_locals = parent.clear_locals;
    child.is_fn = true;
    child.fn_name = f.display_name;
    defer child.deinit();
    try child.captures.appendSlice(child.allocator, shared.sources.items);
    try child.captured_names.appendSlice(child.allocator, shared.names.items);

    // Parameters take slots 0.., the rest parameter last, where the
    // VM puts the arguments; a captured one is boxed on entry.
    const captured = try parent.allocator.alloc(bool, count);
    defer parent.allocator.free(captured);
    const slots = try parent.allocator.alloc(u12, count);
    defer parent.allocator.free(slots);
    for (names, 0..) |p, i| {
        captured[i] = i < clause.captured.len and clause.captured[i];
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
        .returns = true,
    };
    // The body returns on every path that does not recur or throw.
    const result_slot = try child.allocSlot();
    try compileExpr(&child, clause.body, result_slot, &fn_target);

    shared.sources.clearRetainingCapacity();
    try shared.sources.appendSlice(parent.allocator, child.captures.items);
    shared.names.clearRetainingCapacity();
    try shared.names.appendSlice(parent.allocator, child.captured_names.items);
    const child_compiled = try child.finish();
    // The routine lives on the compile allocator with the tree it
    // belongs to; its name is copied because it borrows from source
    // text that need not outlive the routine.
    return .{
        .code = child_compiled.code,
        .consts = child_compiled.consts,
        .capture_descs = child_compiled.capture_descs,
        .tries = child_compiled.tries,
        .var_table = child_compiled.var_table,
        .slot_count = child_compiled.slot_count,
        .fixed_arity = @intCast(clause.params.len),
        .variadic = clause.rest_param != null,
        .name = if (f.display_name) |n| try parent.out.dupe(u8, n) else "fn",
        .spans = child_compiled.spans,
        .origin = if (parent.current_span) |sp| toSourceSpan(sp) else null,
        .source = parent.source,
    };
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

    const scope_mark = e.scope.mark();
    defer e.scope.restore(scope_mark);

    // 1. Allocate placeholder cells for each binding;
    // push each into scope as .cell_slot. Cells must exist
    // BEFORE any closure:make so the cap_desc local_cell_slot
    // sources can reference them.
    const cell_slots = try e.allocator.alloc(u12, bindings.len);
    defer e.allocator.free(cell_slots);
    for (bindings, cell_slots) |b, *s| {
        s.* = try e.allocSlot();
        try e.emit(vm.asm_.closureNewCell(s.*));
        try e.scope.bind(e.allocator, b.name, .{ .cell_slot = s.* });
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
        try compileFn(e, .{ .display_name = b.name, .clauses = b.clauses }, cs);
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
/// the arguments in one contiguous block (`fillBlock`), then
/// `call:call` writes the result to `dst`. `dst` is either live below
/// the block or dead until the call writes it, so the callee's frame
/// cannot clobber what it holds.
fn compileCall(
    e: *Emitter,
    callee: *const Tiny,
    args: []const *const Tiny,
    dst: u12,
) CompileError!void {
    const base = e.reserveBlock(dst, 1 + args.len) orelse return compileChunkedCall(e, callee, args, dst);
    try fillBlock(e, base, callee, args);
    try e.emit(vm.asm_.callCall(base, @intCast(args.len), dst));
}

/// A self-call (COMPILER.md §5.5): the arguments in a block, which
/// is the callee's window, then `call:self`, which calls the frame's
/// own closure. With at most `chunk_items` arguments, a block that
/// does not fit leaves no room for a chunked call either.
fn compileSelfCall(e: *Emitter, args: []const *const Tiny, dst: u12) CompileError!void {
    const base = e.reserveBlock(dst, args.len) orelse return e.limit("local slots");
    try fillBlock(e, base, null, args);
    try e.emit(vm.asm_.callSelf(base, @intCast(args.len), dst));
}

/// A keyword or symbol called on a target, with a default or not: one
/// `call:lookup` reading the target in place where it can, as a
/// `math` instruction reads an operand, or one `call:lookup-or` over
/// the target and the default in a block. A key past the first 4096
/// constants is an ordinary call.
fn compileLookup(e: *Emitter, key: *const Tiny, args: []const *const Tiny, dst: u12) CompileError!void {
    const k = try e.constOperand(key.literal) orelse return compileCall(e, key, args, dst);
    if (args.len == 1) {
        var free_dst = if (e.scratch) |s| s.dst == dst else false;
        const target = try primOperand(e, args[0], true, dst, &free_dst);
        return e.emit(vm.asm_.callLookup(dst, target, k.index));
    }
    const base = e.reserveBlock(dst, 2) orelse return compileCall(e, key, args, dst);
    try fillBlock(e, base, null, args);
    try e.emit(vm.asm_.callLookupOr(dst, base, k.index));
}

fn compileIf(
    e: *Emitter,
    test_form: *const Tiny,
    then_form: *const Tiny,
    else_form: ?*const Tiny,
    dst: u12,
    recur_target: ?*const RecurTarget,
) CompileError!void {
    // The test is non-tail and branched on (`compileBranch`).
    var if_false: Jumps = .empty;
    defer if_false.deinit(e.allocator);
    const at_entry = if (recur_target) |t| t.bottom == null and e.code.items.len == t.entry_pc else false;
    try compileBranch(e, test_form, false, &if_false);
    // An if at a target's entry: a recur in either arm repeats its
    // test (COMPILER.md §5.7).
    var exits: Jumps = .empty;
    defer exits.deinit(e.allocator);
    const bottom = if (at_entry) try bottomTest(e, recur_target.?.entry_pc, if_false.items) else null;
    var then_target: RecurTarget = undefined;
    if (bottom) |b| {
        then_target = recur_target.?.*;
        then_target.bottom = b;
        then_target.bottom.?.arm = .{ .then = &exits };
    }
    // Both arms inherit tail position.
    try compileExpr(e, then_form, dst, if (bottom != null) &then_target else recur_target);
    // An arm that always jumps away (recur, throw) or returns needs
    // no jump past the else arm, nor does an else arm that is `dst`
    // itself (`(if c (+ acc 1) acc)` into acc's slot), which emits
    // nothing.
    const returns = if (recur_target) |t| t.returns else false;
    const else_empty = if (else_form) |ef| isSlot(e, ef, dst) else false;
    const end_jmp_pc: ?usize = if (!e.reachable or else_empty) null else try e.emitPlaceholder(vm.asm_.jumpJmp(unpatched));
    // A recur last in the then arm falls through to the else arm.
    if (exits.items.len > 0 and exits.items[exits.items.len - 1] == e.code.items.len - 1) {
        _ = exits.pop();
        e.dropLast();
    }
    try patchJumpsHere(e, if_false.items);
    try patchJumpsHere(e, exits.items);
    var else_target: RecurTarget = undefined;
    if (bottom) |b| {
        else_target = recur_target.?.*;
        else_target.bottom = b;
        else_target.bottom.?.arm = .{ .else_ = try e.nextPc() };
    }
    if (else_form) |ef| {
        try compileExpr(e, ef, dst, if (bottom != null) &else_target else recur_target);
    } else {
        try e.emit(if (returns) vm.asm_.returnNil() else vm.asm_.loadNil(dst));
    }
    if (end_jmp_pc) |pc| try e.patchJumpHere(pc);
}

/// Whether `t` is the local held directly in `slot`, whose value is
/// already there.
fn isSlot(e: *const Emitter, t: *const Tiny, slot: u12) bool {
    if (t.* != .symbol) return false;
    const ref = e.resolveLocalRef(t.symbol) orelse return false;
    return ref == .direct_slot and ref.direct_slot == slot;
}

/// The pcs of jumps a caller points at one target.
const Jumps = std.ArrayList(usize);

fn patchJumpsHere(e: *Emitter, pcs: []const usize) CompileError!void {
    for (pcs) |pc| try e.patchJumpHere(pc);
}

/// Emit `t` as a branch: control jumps (from a pc added to `jumps`)
/// when `t`'s truthiness is `jump_when` and falls through otherwise;
/// the test is read in place where it can be, and a slot it needed
/// is free again after the jump. An `and` or an `or` branches on
/// each operand in turn and a `not` on its operand, so their values
/// are never made (COMPILER.md §5.2).
fn compileBranch(e: *Emitter, t: *const Tiny, jump_when: bool, jumps: *Jumps) CompileError!void {
    try stack.check();
    // `(if x true false)` is x's truthiness, `(if x false true)`
    // (a `not`) its negation.
    if (t.* == .if_ and t.if_.else_ != null and t.if_.then.* == .bool and t.if_.else_.?.* == .bool and t.if_.then.bool != t.if_.else_.?.bool) {
        return compileBranch(e, t.if_.test_, if (t.if_.then.bool) jump_when else !jump_when, jumps);
    }
    if (andOr(t)) |ao| {
        if (ao.is_and != jump_when) {
            // Either operand alone decides a jump: an and that is
            // false, an or that is true.
            try compileBranch(e, ao.first, jump_when, jumps);
            try compileBranch(e, ao.rest, jump_when, jumps);
        } else {
            // The first operand can only decide the fall-through.
            var decided: Jumps = .empty;
            defer decided.deinit(e.allocator);
            try compileBranch(e, ao.first, !jump_when, &decided);
            try compileBranch(e, ao.rest, jump_when, jumps);
            try patchJumpsHere(e, decided.items);
        }
        return;
    }
    const slot_mark = e.slot_top;
    defer e.slot_top = slot_mark;
    const op = try compileOperand(e, t, true);
    try jumps.append(e.allocator, try e.emitPlaceholder(if (jump_when) vm.asm_.jumpIfTrue(unpatched, op) else vm.asm_.jumpIfFalse(unpatched, op)));
}

const AndOr = struct { is_and: bool, first: *const Tiny, rest: *const Tiny };

/// `t` as the operands of an `and` or an `or`, when it has the shape
/// the expander gives them (MACROEXPAND.md §10): `(let* [g x] (if g
/// rest g))` or `(let* [g x] (if g g rest))`, `rest` not reading `g`:
/// lowering counted two reads of `g`, the test and the arm that is
/// `g` itself.
fn andOr(t: *const Tiny) ?AndOr {
    const l = switch (t.*) {
        .let_star => |l| l,
        else => return null,
    };
    if (l.bindings.len != 1 or l.bindings[0].refs != 2) return null;
    const g = l.bindings[0].name;
    const i = switch (l.body.*) {
        .if_ => |i| i,
        else => return null,
    };
    const else_form = i.else_ orelse return null;
    if (!namesSymbol(i.test_, g)) return null;
    if (namesSymbol(else_form, g)) return .{ .is_and = true, .first = l.bindings[0].value, .rest = i.then };
    if (namesSymbol(i.then, g)) return .{ .is_and = false, .first = l.bindings[0].value, .rest = else_form };
    return null;
}

fn namesSymbol(t: *const Tiny, name: []const u8) bool {
    return t.* == .symbol and std.mem.eql(u8, t.symbol, name);
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
        if (inst.groupOf() == .closure and inst.variant == @backingInt(vm.Closure_.box_local)) boxes += 1;
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
                if (inst.groupOf() == .closure and inst.variant == @backingInt(vm.Closure_.box_local)) boxes += 1;
            }
            for (r.capture_descs) |d| try routines.append(arena.allocator(), d.routine);
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

test "bytecode: a try body or handler that always throws has no try-exit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var v = try vm.VM.init(testing.allocator, &stub_routine);
    defer v.deinit();
    const cases = [_]struct { src: []const u8, exits: usize, want: i64 }{
        .{ .src = "(try 1 (catch any e 2))", .exits = 2, .want = 1 },
        .{ .src = "(try (throw 1) (catch any e 2))", .exits = 1, .want = 2 },
        .{ .src = "(try (try 3 (catch any e (throw e))) (catch any e 4))", .exits = 3, .want = 3 },
        .{ .src = "(try (try (throw 3) (catch any e (throw e)) (finally nil)) (catch any e e))", .exits = 1, .want = 3 },
    };
    for (cases) |c| {
        const compiled = try compileSourceWith(arena.allocator(), c.src, .{ .namespace = v.ensureNamespace(), .interner = v.ensureInterner() });
        var exits: usize = 0;
        for (compiled.code) |inst| {
            if (inst.groupOf() == .ctrl and inst.variant == @backingInt(vm.CtrlOp.try_exit)) exits += 1;
        }
        try testing.expectEqual(c.exits, exits);
        try testing.expectEqual(c.want, (try runBare(arena.allocator(), &v, c.src)).asFixnum());
    }
}

test "bytecode: no jump lands on the instruction after it" {
    // An else arm that is its destination's own local emits nothing,
    // so the then arm needs no jump past it.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var v = try vm.VM.init(testing.allocator, &stub_routine);
    defer v.deinit();
    const src = "(loop* [i 5 acc 0] (if i (recur nil (if (if i nil true) (quote x) acc)) acc))";
    const compiled = try compileSourceWith(arena.allocator(), src, .{ .namespace = v.ensureNamespace(), .interner = v.ensureInterner() });
    for (compiled.code, 0..) |inst, pc| {
        if (inst.groupOf() == .jump) try testing.expect(inst.wide() != pc + 1);
    }
    try testing.expectEqual(@as(i64, 0), (try runBare(arena.allocator(), &v, src)).asFixnum());
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

test "locals clearing: a move clears its source where no path reads it again" {
    const a = vm.asm_;
    const move = @backingInt(vm.Mov.move);
    const clear = @backingInt(vm.Mov.move_clear);
    // s0 read again by the second move, which reads it last.
    var straight = [_]Inst{ a.move(1, 0), a.move(2, 0), a.collVector(1, 2, 3), a.returnSlot(3) };
    try testing.expect(try clearDeadMoves(testing.allocator, &straight, 4, &.{}, &.{}, &.{}));
    try testing.expectEqual(move, straight[0].variant);
    try testing.expectEqual(clear, straight[1].variant);
    // A body's move of s0, which the handler reads, stays; the
    // handler's own clears.
    var guarded = [_]Inst{
        a.tryEnter(0, 3),
        a.move(1, 0),
        a.callCall(1, 0, 2),
        a.tryExit(6),
        a.move(2, 0),
        a.tryExit(6),
        a.returnSlot(2),
    };
    const tries = [_]vm.Try{.{ .catch_pc = 4 }};
    const extents = [_]TryExtent{.{ .enter = 0, .end = 6 }};
    try testing.expect(try clearDeadMoves(testing.allocator, &guarded, 4, &.{}, &tries, &extents));
    try testing.expectEqual(move, guarded[1].variant);
    try testing.expectEqual(clear, guarded[4].variant);
    // Past the budget, a routine is left as it is.
    const n = 1 << 15;
    const big = try testing.allocator.alloc(Inst, n + 2);
    defer testing.allocator.free(big);
    for (big[0..n], 0..) |*inst, pc| inst.* = a.jumpIfTrue(@intCast(pc + 1), vm.Operand.slot(0));
    big[n] = a.move(1, 0);
    big[n + 1] = a.returnSlot(1);
    try testing.expect(!try clearDeadMoves(testing.allocator, big, 4096, &.{}, &.{}, &.{}));
    try testing.expectEqual(move, big[n].variant);
}

test "locals clearing: the check refuses a read of a slot a move cleared" {
    const a = vm.asm_;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tries = [_]vm.Try{.{ .catch_pc = 4 }};
    const extents = [_]TryExtent{.{ .enter = 0, .end = 6 }};
    const Case = struct { code: []const Inst, tries: []const vm.Try = &.{}, extents: []const TryExtent = &.{} };
    for ([_]Case{
        // Read on the path that follows.
        .{ .code = &.{ a.moveClear(1, 0), a.move(2, 0), a.returnSlot(2) } },
        // Read on one arm of a branch.
        .{ .code = &.{ a.moveClear(1, 0), a.jumpIfTrue(3, vm.Operand.slot(1)), a.returnSlot(0), a.returnSlot(1) } },
        // Read by the handler of a throw after the clear.
        .{ .code = &.{ a.tryEnter(0, 3), a.moveClear(1, 0), a.callCall(1, 0, 2), a.tryExit(6), a.move(2, 0), a.tryExit(6), a.returnSlot(2) }, .tries = &tries, .extents = &extents },
    }) |case| {
        const effects = try arena.allocator().alloc(Effects, case.code.len);
        for (case.code, effects) |inst, *fx| fx.* = effectsOf(inst, &.{}, 4).?;
        const flow = (try Flow.build(arena.allocator(), case.code, case.tries, case.extents, 1)).?;
        try testing.expectError(CompileError.InternalCompilerBug, checkClears(arena.allocator(), case.code, effects, &flow, case.tries, case.extents, 1));
    }
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

/// `open`, then `item` n times with every `{d}` in it replaced by
/// the item's index, then `close`.
fn generatedSource(allocator: std.mem.Allocator, open: []const u8, item: []const u8, n: usize, close: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, open);
    for (0..n) |i| {
        var parts = std.mem.splitSequence(u8, item, "{d}");
        try out.appendSlice(allocator, parts.first());
        while (parts.next()) |part| {
            try out.print(allocator, "{d}", .{i});
            try out.appendSlice(allocator, part);
        }
    }
    try out.appendSlice(allocator, close);
    return out.toOwnedSlice(allocator);
}

test "wide targets: a routine of more than 100,000 instructions branches, loops and catches past pc 65,536" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v = try vm.VM.init(testing.allocator, &stub_routine);
    defer v.deinit();
    // Each (var pad) is one instruction ahead of the tail.
    const src = try generatedSource(a, "((fn* big [n] (do", " (var pad)", 100_000,
        \\ (loop* [i n acc nil]
        \\   (if i (recur nil (try (throw i) (catch any e e) (finally nil))) acc)))) 7)
    );
    try testing.expectEqual(@as(i64, 7), (try runBare(a, &v, src)).asFixnum());

    const compiled = try compileSourceWith(a, src, .{ .namespace = v.ensureNamespace(), .interner = v.ensureInterner() });
    const big = compiled.capture_descs[0].routine;
    try testing.expect(big.code.len > 100_000);
    // Every branch, handler and exit targets a pc past 65,536.
    try testing.expectEqual(@as(usize, 1), big.tries.len);
    try testing.expect(big.tries[0].catch_pc > 65_536 and big.tries[0].finally_pc.? > 65_536);
    var targets: usize = 0;
    for (big.code) |inst| {
        const wide_target = switch (inst.groupOf()) {
            .jump => true,
            .ctrl => switch (@as(vm.CtrlOp, @fromBackingInt(@intCast(inst.variant)))) {
                .try_exit => true,
                else => false,
            },
            else => false,
        };
        if (!wide_target) continue;
        try testing.expect(inst.wide() > 65_536);
        targets += 1;
    }
    // if-false, recur's jump and the handler's try-exit (the body
    // always throws, so it has none).
    try testing.expectEqual(@as(usize, 3), targets);
}

test "routine limits: constants past the operand range load through the wide index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v = try vm.VM.init(testing.allocator, &stub_routine);
    defer v.deinit();
    const src = try generatedSource(a, "(do", " (let* [x {d}] x)", 5000, " (if 4999 4998 nil))");
    try testing.expectEqual(@as(i64, 4998), (try runBare(a, &v, src)).asFixnum());
    const compiled = try compileSourceWith(a, src, .{ .namespace = v.ensureNamespace(), .interner = v.ensureInterner() });
    try testing.expectEqual(@as(usize, 5000), compiled.consts.len);
}

test "routine limits: more than 4096 live slots or captures is SlotOverflow, naming the fn and the limit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const let_4000 = try generatedSource(a, "(let* [", "a{d} {d} ", 4000, "] a0)");
    _ = try compileSourceWith(a, let_4000, .{});
    const let_4100 = try generatedSource(a, "(let* [", "a{d} {d} ", 4100, "] a0)");
    const captures = try generatedSource(a, "(let* [", "a{d} {d} ", 2100, try generatedSource(a, "] (fn* [] (let* [", "b{d} {d} ", 2100, try generatedSource(a, "] (fn* inner [] (do", " a{d} b{d}", 2100, ")))))")));
    const cases = [_]struct { src: []const u8, detail: []const u8, at: usize }{
        .{ .src = let_4100, .detail = "top-level form: more than 4096 local slots", .at = 0 },
        .{ .src = try a.print("(fn* many [] {s})", .{let_4100}), .detail = "fn many: more than 4096 local slots", .at = 13 },
        .{ .src = try a.print("(fn* [] {s})", .{let_4100}), .detail = "anonymous fn: more than 4096 local slots", .at = 8 },
        .{ .src = captures, .detail = "fn inner: more than 4096 captured locals", .at = std.mem.find(u8, captures, " a2048 b2048").? + 1 },
    };
    for (cases) |c| {
        var span: ?reader_mod.SrcSpan = null;
        var detail: ?[]const u8 = null;
        try testing.expectError(CompileError.SlotOverflow, compileSourceWith(a, c.src, .{ .out_span = &span, .out_detail = &detail }));
        try testing.expectEqualStrings(c.detail, detail.?);
        try testing.expectEqual(c.at, span.?.pos);
    }
}

test "compile span: an error is reported at the innermost form that raised it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { src: []const u8, at: []const u8, err: CompileError }{
        .{ .src = "(fn* [x] (let* [y 1] (+ 1 (recur 2))))", .at = "(recur 2)", .err = CompileError.RecurOutsideTail },
        .{ .src = "(fn* [x] (do 1 (recur 1 2)))", .at = "(recur 1 2)", .err = CompileError.RecurArityMismatch },
        .{ .src = "(do 1 (let* [x 1] (if)))", .at = "(if)", .err = CompileError.MalformedForm },
    };
    for (cases) |c| {
        var span: ?reader_mod.SrcSpan = null;
        try testing.expectError(c.err, compileSourceWith(arena.allocator(), c.src, .{ .out_span = &span }));
        try testing.expectEqual(std.mem.find(u8, c.src, c.at).?, span.?.pos);
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
    var v = try vm.VM.init(testing.allocator, &stub_routine);
    defer v.deinit();
    const registry = try v.ensureRegistry();
    for ([_]bool{ false, true }) |quoted| {
        const deep = try nestedVectorForm(a, 100_000, quoted);
        var declared = DeclaredNames.init(testing.allocator);
        defer declared.deinit();
        // Quoted data is a constant built on the heap; the expander,
        // which an interner brings in, passes a quote through.
        const opts: CompileOptions = if (quoted) .{ .declared = &declared, .namespace = registry.current, .interner = v.ensureInterner() } else .{ .declared = &declared };
        try testing.expectError(CompileError.StackOverflow, compileFormWith(a, deep, opts));
        const shallow = try nestedVectorForm(a, 100, quoted);
        _ = try compileFormWith(a, shallow, opts);
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
    var detail: ?[]const u8 = null;
    const opts: CompileOptions = .{
        .namespace = v.ensureNamespace(),
        .interner = v.ensureInterner(),
        .declared = &declared,
        .out_span = &span,
        .out_detail = &detail,
    };
    const src = "(fn* [x] (let* [z 1] (+ x (< z y))))";
    try testing.expectError(CompileError.UnresolvedSymbol, compileSourceWith(arena.allocator(), src, opts));
    const sp = span orelse return error.TestFailed;
    try testing.expectEqualStrings("y", src[sp.pos .. sp.pos + sp.len]);
    try testing.expectEqualStrings("unable to resolve symbol: y", detail.?);
    // So is a qualified one naming no namespace, and, compiled
    // without declared names or a namespace, a bare one.
    try testing.expectError(CompileError.UnresolvedSymbol, compileSourceWith(arena.allocator(), "(+ 1 nope/w)", opts));
    try testing.expectEqualStrings("unable to resolve symbol: nope/w", detail.?);
    try testing.expectError(CompileError.UnresolvedSymbol, compileSourceWith(arena.allocator(), "(let* [a 1] b)", .{ .out_detail = &detail }));
    try testing.expectEqualStrings("unable to resolve symbol: b", detail.?);
    // Declaring it makes the same source compile.
    try declared.declare("y");
    _ = try compileSourceWith(arena.allocator(), src, opts);
}

test "declared names: lexical bindings, quoted data and same-form definitions resolve" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var v = try vm.VM.init(testing.allocator, &stub_routine);
    defer v.deinit();
    // A registry brings the heap quoted data is built on; a `def`
    // sets its Var's metadata through `nexis.core/reset-meta!`.
    _ = try (try v.ensureRegistry()).core.intern("reset-meta!");
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
    if (compiled.capture_descs.len != 1) return error.TestFailed;
    const r = compiled.capture_descs[0].routine;
    try testing.expectEqualStrings("sq", r.name);
    try testing.expect(r.spans.len > 0);
    const origin = r.origin orelse return error.TestFailed;
    try testing.expectEqualStrings("(fn* sq [x]\n  (* x x))", src[origin.pos .. origin.pos + origin.len]);
    // The body's call carries the span of `(* x x)`; the return
    // after it carries the fn's.
    const last = r.spanAt(@intCast(r.code.len - 2)) orelse return error.TestFailed;
    try testing.expectEqualStrings("(* x x)", src[last.pos .. last.pos + last.len]);
}

test "span table: a loop's test repeated at its recur carries the test's spans" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "(loop* [i 0] (if (< i 3) (recur (inc i)) i))";
    const info = vm.SourceInfo{ .path = "t.nx", .text = src };
    const routine = (try compileSourceWith(arena.allocator(), src, .{ .source = &info })).toRoutine("t");
    // Each instruction of the test, at the entry and at the recur,
    // names `(< i 3)` or the `if` it branches for.
    var seen: [2][2][]const u8 = undefined;
    var n: usize = 0;
    for (routine.code, 0..) |inst, pc| {
        if (inst.groupOf() != .cmp) continue;
        for (0..2) |k| {
            const span = routine.spanAt(@intCast(pc + k)) orelse return error.TestFailed;
            seen[n][k] = src[span.pos .. span.pos + span.len];
        }
        n += 1;
    }
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("(< i 3)", seen[0][0]);
    try testing.expectEqualStrings(src[13 .. src.len - 1], seen[0][1]);
    for (0..2) |k| try testing.expectEqualStrings(seen[0][k], seen[1][k]);
}

test "span table: a hand-built Tiny compiles with no table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const form = Tiny{ .int = 7 };
    const compiled = try compileTiny(arena.allocator(), &form);
    try testing.expectEqual(@as(usize, 0), compiled.spans.len);
    try testing.expect(compiled.toRoutine("t").spanAt(0) == null);
}
